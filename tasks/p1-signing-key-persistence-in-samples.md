# [P1] サンプル OP の署名鍵を永続化し、インスタンス間・再起動間で一貫させる

## ステータス

🟠 High / 未着手

## 背景

4 サンプル（hono-cloudflare / express-flyio / fastify-flyio / nextjs-vercel）はすべて
`createEphemeralRs256KeyProvider()` により、**モジュール評価時にその場で RSA 鍵ペアを生成**している。
`kid` は固定文字列なのに鍵素材はインスタンスごとにランダムなので、

- Cloudflare Workers の別アイソレート、Fly の別マシン、Vercel の別インスタンスがそれぞれ別の鍵で署名する
- RP が JWKS を取得したインスタンスと ID Token を発行したインスタンスが異なると、
  `kid` は一致するのに**署名検証が失敗**する（`kid` 一致を強い制約として扱う JWT ライブラリが多いため、
  他鍵へのフォールバックは期待できない）
- 再起動・再デプロイのたびに、有効期間内（既定 1 時間）の ID Token / JWT アクセストークンが検証不能になる。
  `prompt=none` の `id_token_hint` 検証も自分が発行したトークンを検証できず `login_required` に落ちる

という問題がある。失敗はルーティングと負荷に依存するため**間欠的**で、原因特定が非常に難しい。

影響範囲は「実デプロイに対する検証」全般。特に OIDF Conformance Suite を実デプロイに対して回す計画
（`study-material/basic-op-conformance-verification-plan.md`）では、原因不明の署名検証 FAIL として現れ、
本リポジトリの差別化軸である Fidelity（Conformance 準拠を信頼性のシグナルとして維持する）を直接損なう。

同一プロセス内で完結するローカル起動（`pnpm sample:*`）、リポジトリ内の `conformance.test.ts`、
`tests/e2e` では顕在化しないため、CI では検出できない。

検討詳細は `study-material/done/signing-key-persistence-and-instance-consistency.md` を参照。

> 関連：鍵ローテーションの手順・`kid` 戦略・キャッシュ TTL は
> `study-material/signing-key-rotation-operations.md`。本タスクはその**前提条件**
> （鍵が永続していなければローテーション手順そのものが実行できない）にあたる。
> 鍵強度・パラメータ検証は `study-material/done/signing-key-strength-and-parameter-validation.md`。

## 対象ファイル

- `samples/hono-cloudflare/src/app.ts`（`createEphemeralRs256KeyProvider` / `generateSigningKey`）
- `samples/express-flyio/src/app.ts`
- `samples/fastify-flyio/src/app.ts`
- `samples/nextjs-vercel/src/app/_oidc-provider/runtime.ts`
- `packages/core/src/signing-key.ts`（core にローダを置く方針を採る場合のみ）
- `scripts/`（署名鍵生成スクリプトを追加する場合）
- `samples/*/scripts/deploy-*.sh`（secret 設定手順をガイドに組み込む場合）
- `samples/*/README.md`（環境変数の説明）

## 仕様参照

- **OIDC Core 1.0 §10.1 Signing**: 署名者は鍵を `jwks_uri` の JWK Set で公開し、
  JOSE Header の `kid` でどの鍵を使ったかを示す。受信者は JWK Set をキャッシュしてよい。
  この方式は「`kid` → 鍵素材の対応が OP 全体で一意かつ安定」であることを前提とする。
- **RFC 7517 §4.5 `kid`**: JWK Set 内で異なる鍵は異なる `kid` を使う SHOULD。
  `kid` は鍵の同定子として使われる。
- **RFC 7515 §4.1.4 `kid` Header Parameter**: 署名に使った鍵を示すヒント。
  受信者はこれで検証鍵を絞り込む。
- Basic OP 認定の要件は「RS256 で署名し JWKS で公開する」ことであり、鍵の永続化は要件外。
  本タスクは**仕様準拠ではなく実デプロイでの検証可能性**の問題として扱う。

## 現状の実装

```ts
// samples/hono-cloudflare/src/app.ts:67-99（他 3 サンプルも同型）
function createEphemeralRs256KeyProvider(keyId = 'hono-cloudflare-rs256-key'): SigningKeyProvider {
  const keyPromise = generateSigningKey(keyId);   // モジュール評価時に 1 回だけ生成
  return {
    async getSigningKey(): Promise<SigningKey> { return keyPromise; },
    async getSigningKeys(): Promise<SigningKey[]> { return [await keyPromise]; },
  };
}

async function generateSigningKey(keyId: string): Promise<SigningKey> {
  const keyPair = await crypto.subtle.generateKey(
    { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1,0,1]), hash: 'SHA-256' },
    true, ['sign', 'verify'],
  );
  publicJwk.alg = 'RS256'; publicJwk.use = 'sig'; publicJwk.kid = keyId;  // ← kid は固定
  return { privateKey: keyPair.privateKey, publicJwk, keyId };
}
```

`SigningKeyProvider` 抽象と `createCachedSigningKeyProvider` は core に既にあり、
外部 secret store から鍵をロードする実装を差し込む口は用意されている。
**にもかかわらず、永続鍵をロードする実装例がリポジトリ内に 1 つも無い。**

## 修正方針

方針の選択（A: env の JWK / B: デプロイ先ネイティブのストア / D: core にローダを追加）は
`study-material/done/signing-key-persistence-and-instance-consistency.md` §8 の判断材料を踏まえて決める。
下記は**どの方針でも共通で実施する項目**と、方針別項目に分ける。

### 共通（方針によらず実施）

- [ ] エフェメラル生成関数に「この鍵はプロセス／アイソレートごとに変わる。
      複数インスタンス構成では署名検証が間欠的に失敗する」旨の JSDoc を追加する
- [ ] 永続鍵が設定されておらずエフェメラルにフォールバックした場合、起動時に警告を出す
- [ ] 事実確認: Cloudflare Workers のアイソレート・ライフサイクルに関する一次資料を確認し、
      study-material 側の記述を確定させる

### 方針A（環境変数に JWK を置く）を採る場合

- [ ] 署名鍵生成スクリプト（RS256 の秘密鍵を JWK JSON として標準出力する）を `scripts/` に追加
- [ ] 各サンプルに `OIDC_SIGNING_KEY_JWK` / `OIDC_SIGNING_KEY_ID` を読む
      `SigningKeyProvider` 実装を追加し、未設定時のみ現行のエフェメラル生成へフォールバック
- [ ] `crypto.subtle.importKey('jwk', ...)` の algorithm パラメータ導出は
      core の `extractAlgorithmParamsFromJwk` を再利用する
- [ ] ロードした鍵に `assertKeyStrength` を適用する（弱い鍵を secret に置いた事故を検出）
- [ ] `pnpm deploy:*` のガイドに secret 設定手順
      （`wrangler secret put` / `fly secrets set` / `vercel env add`）を組み込む

### 方針B（デプロイ先ネイティブのストア）を採る場合

- [ ] hono-cloudflare: D1 の `oidc_store`（または KV）に鍵を保存する provider を実装し、
      `createCachedSigningKeyProvider` でラップする
- [ ] 初回起動時の鍵生成が複数インスタンスで競合しないようにする（条件付き INSERT 等）
- [ ] express/fastify（Fly Volume）と nextjs（外部 KV）の保存先を決めて実装する

### 方針D（core にローダヘルパを追加）を採る場合

- [ ] `createJwkSigningKeyProvider(jwk, keyId?)` を `packages/core/src/signing-key.ts` に追加し、
      `index.ts` からエクスポートする
- [ ] 内部で `assertKeyStrength` を呼び、`kid` の整合も検証する
- [ ] `RELEASE-v0.x-scope.md` と照らして core の API 面積を増やす是非を確認する

### 実装例（方針A の最小形）

```ts
function createEnvJwkSigningKeyProvider(jwkJson: string, keyId?: string): SigningKeyProvider {
  const keyPromise = (async (): Promise<SigningKey> => {
    const privateJwk = JSON.parse(jwkJson) as JsonWebKey & { kid?: string };
    const algParams = extractAlgorithmParamsFromJwk(privateJwk);
    const privateKey = await crypto.subtle.importKey('jwk', privateJwk, algParams, false, ['sign']);
    // 公開鍵側は秘密パラメータ（d/p/q/dp/dq/qi）を落として構成する
    const { d: _d, p: _p, q: _q, dp: _dp, dq: _dq, qi: _qi, ...publicJwk } = privateJwk;
    const resolvedKid = keyId ?? privateJwk.kid;
    return { privateKey, publicJwk: { ...publicJwk, alg: 'RS256', use: 'sig', kid: resolvedKid }, keyId: resolvedKid };
  })();
  return {
    async getSigningKey() { return keyPromise; },
    async getSigningKeys() { return [await keyPromise]; },
  };
}
```

## テスト要件

- [ ] 「同一 `kid` で異なる鍵素材」を持つ 2 つの provider を用意し、
      片方が発行した ID Token を他方の JWKS で検証すると**失敗する**ことを回帰テストで固定する
      （エフェメラル方式の危険性を実証するテスト。修正の必要性を機械的に示す）
- [ ] 永続鍵プロバイダを 2 回インスタンス化しても、同じ `kid` に対して**同じ公開 JWK** が返ることを検証
- [ ] 永続鍵プロバイダが返した鍵で署名した ID Token が、同じ provider の JWKS で検証できることを検証
- [ ] 不正な JWK JSON / `kid` 不一致 / 弱い鍵（modulusLength 不足）を渡した場合に
      起動時エラーになることを検証
- [ ] 環境変数未設定時にエフェメラルへフォールバックし、警告が出ることを検証
      （ローカル起動 `pnpm sample:*` の体験が壊れないこと）
- [ ] 既存の `conformance.test.ts` / `tests/e2e` が回帰しないこと

## 完了条件

- 選択した方針の実装が入り、`pnpm --filter "./packages/*" test` と
  `pnpm run test:conformance`、`pnpm run test:e2e` がすべてパスすること
- `pnpm typecheck` がパスすること
- 永続鍵を設定した状態で `pnpm deploy:hono-cloudflare` を実行し、
  再デプロイ前に発行した ID Token が再デプロイ後の JWKS でも検証できることを手動で確認すること
- 生成コード（`samples/*/src/oidc-provider/**`）を直接編集していないこと
  （サンプルの `src/app.ts` / `runtime.ts` は CLI 生成対象外なので直接編集してよい）
- `study-material/signing-key-rotation-operations.md` に本タスクとの前後関係を追記すること
