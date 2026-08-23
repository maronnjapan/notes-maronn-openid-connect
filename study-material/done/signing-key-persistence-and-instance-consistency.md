# 署名鍵の永続化とインスタンス間・再起動間の鍵一貫性（サンプル OP のエフェメラル鍵生成）

## 1. タイトル

全サンプル OP（hono-cloudflare / express-flyio / fastify-flyio / nextjs-vercel）が
**プロセス／アイソレート起動ごとにその場で RSA 鍵ペアを生成**しており、
複数インスタンス構成・再起動・再デプロイをまたぐと JWKS と発行済み JWT の署名が一致しなくなる問題。

## 2. このトピックで確認したいこと

- 各サンプルの `createEphemeralRs256KeyProvider()` が、実デプロイ環境
  （Cloudflare Workers のアイソレート、Fly.io の複数マシン、Vercel のサーバレスインスタンス）で
  「同一 `kid` に対して異なる鍵素材」を生じさせないか
- 生じる場合、RP 側の ID Token 検証・`id_token_hint` 検証・JWT アクセストークン検証が
  どのように壊れるか（決定的な失敗か、非決定的な間欠失敗か）
- `SigningKeyProvider` 抽象は既にあるのに、**永続鍵を読み込む実装例が 1 つも無い**ことの是非
- CLI 生成コードとサンプルのどちらを直すべきか（責務の切り分け）

> 既存ファイルで扱っている内容は繰り返さない:
> - 鍵ローテーションの運用手順・`kid` 戦略・キャッシュ TTL: `study-material/signing-key-rotation-operations.md`
> - 鍵強度・曲線・`use`/`key_ops` の検証: `study-material/done/signing-key-strength-and-parameter-validation.md`
> - 生成 OP で鍵検証が未配線だった件: `study-material/done/generated-provider-signing-key-validation-unwired.md`
> - 複数鍵公開時の `kid` 必須化: `study-material/done/id-token-kid-presence-under-multiple-keys.md`
> - JWKS エンドポイント全般: `study-material/jwks-endpoint-comprehensive.md`
>
> 本ファイルは「**鍵素材そのものがどこから来るか（永続化）**」という、上記いずれも扱っていない
> 前段の論点に限定する。ローテーション手順は鍵が永続化されて初めて意味を持つため、
> 本トピックは `signing-key-rotation-operations.md` の前提条件にあたる。

## 3. 関連する仕様・基準（本トピック固有の差分）

### 3.1 OIDC Core 1.0 §10.1 Signing — JWKS と `kid` による鍵の同定

§10.1 は署名鍵のローテーション方式として次を示している。

- 署名者は自身の鍵を `jwks_uri` の JWK Set で公開する
- 各メッセージの JOSE Header に `kid` を含め、どの鍵で署名したかを示す
- 受信者は JWK Set をキャッシュしてよく、未知の `kid` を見たときに再取得する

この方式が成立する前提は「**`kid` → 鍵素材の対応が、OP 全体で一意かつ安定していること**」である。
同じ `kid` が時刻やインスタンスによって別の鍵素材を指す状態は、この方式の前提を壊す。

### 3.2 RFC 7517 §4.5 `kid` — JWK Set 内で `kid` は区別されるべき

RFC 7517 §4.5 は「JWK Set 内で異なる鍵は異なる `kid` 値を使う **SHOULD**」と規定する。
本件は「1 つの JWK Set 内の重複」ではなく「**インスタンス間で同一 `kid` に別鍵素材**」なので、
文言そのものの違反ではないが、`kid` を鍵の同定子として使う運用の意図には明確に反する。

### 3.3 RFC 7515 §4.1.4 `kid` ヘッダ — 検証鍵の絞り込みヒント

`kid` は「署名に使った鍵を示すヒント」であり、受信者はこれで検証鍵を 1 つに絞る。
JWKS 側の `kid` に該当する鍵で検証が失敗した場合、多くの JWT ライブラリは
**他の鍵にフォールバックせずそのまま失敗**する（`kid` 一致を強い制約として扱う実装が一般的）。
したがって「JWKS を引き直せば直る」性質の障害ではない。

### 3.4 実行環境の事実（推測ではなく環境仕様として確認すべき点）

- **Cloudflare Workers**: モジュールスコープのコードは**アイソレート単位**で評価される。
  1 つの Worker に対して複数のアイソレートが同時に存在し得（コロケーション拠点ごと、負荷ごと）、
  アイソレートは随時破棄・再作成される。したがってモジュールスコープで生成した鍵は
  **アイソレートごとに別物**になる。
- **Fly.io（express / fastify）**: 既定は 1 マシンでも、スケールアウトやローリング再起動で
  複数プロセスが同時に走る。プロセス再起動で鍵は必ず変わる。
- **Vercel（Next.js）**: サーバレス関数インスタンスごとにモジュール評価が走る。
  複数インスタンスが同時に稼働するのが通常。

いずれも「単一プロセスが常駐し続ける」前提を置けない環境である。
なお本リポジトリの `storeTemplate` は `globalThis` シングルトンでストアを共有しているが、
これは**同一アイソレート／プロセス内**の共有であり、インスタンス間の共有ではない。

## 4. 参照資料

- OpenID Connect Core 1.0 §10.1 Signing（JWKS 公開・`kid` によるローテーション）—
  https://openid.net/specs/openid-connect-core-1_0.html#SigEnc
- OpenID Connect Discovery 1.0 §3（`jwks_uri`）—
  https://openid.net/specs/openid-connect-discovery-1_0.html#ProviderMetadata
- RFC 7517 JSON Web Key §4.5 `kid` — https://www.rfc-editor.org/rfc/rfc7517#section-4.5
- RFC 7515 JSON Web Signature §4.1.4 `kid` Header Parameter —
  https://www.rfc-editor.org/rfc/rfc7515#section-4.1.4
- Cloudflare Workers — Runtime / Isolates のライフサイクル:
  https://developers.cloudflare.com/workers/reference/how-workers-works/
  （「モジュールスコープの状態はアイソレート単位」であることの一次資料。**採用前に最新の記述を確認すること**）
- 本リポジトリ内: `study-material/signing-key-rotation-operations.md`（本ファイルの後続にあたる運用手順）

## 5. 現在の実装確認

### 5.1 core が提供している抽象（十分に用意されている）

- `packages/core/src/signing-key.ts`: `SigningKey` / `SigningKeyProvider` /
  `createCachedSigningKeyProvider(base, ttlMs)` / `getRegisteredSigningKeys()` /
  `assertHasRs256Key()` / `assertKeyStrength()` / `assertKidStrategyConsistent()` /
  `selectSigningKeyByAlg()`
- 抽象としては「外部の secret store から鍵をロードして返す」ことを想定した設計になっている。

### 5.2 サンプル側の実装（すべてエフェメラル）

| サンプル | 該当箇所 | 内容 |
|---|---|---|
| hono-cloudflare | `samples/hono-cloudflare/src/app.ts:55,67-99` | `createEphemeralRs256KeyProvider(bindings.OIDC_SIGNING_KEY_ID)`。`kid` 既定値 `'hono-cloudflare-rs256-key'` |
| express-flyio | `samples/express-flyio/src/app.ts:74,82-` | 同型（`kid` はプロバイダ実装依存） |
| fastify-flyio | `samples/fastify-flyio/src/app.ts:74,82-` | 同型 |
| nextjs-vercel | `samples/nextjs-vercel/src/app/_oidc-provider/runtime.ts:14-17` | モジュールスコープで `createEphemeralRs256KeyProvider()` |

共通する形（hono-cloudflare の例）:

```ts
function createEphemeralRs256KeyProvider(keyId = 'hono-cloudflare-rs256-key'): SigningKeyProvider {
  const keyPromise = generateSigningKey(keyId);          // モジュール評価時に1回だけ生成
  return { async getSigningKey() { return keyPromise; }, ... };
}

async function generateSigningKey(keyId: string): Promise<SigningKey> {
  const keyPair = await crypto.subtle.generateKey(
    { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1,0,1]), hash: 'SHA-256' },
    true, ['sign', 'verify'],
  );
  publicJwk.kid = keyId;                                  // ← 鍵素材は毎回違うが kid は固定
  return { privateKey: keyPair.privateKey, publicJwk, keyId };
}
```

**`kid` は固定文字列、鍵素材はインスタンスごとにランダム**という組み合わせになっている。

### 5.3 鍵が使われる場所

- `routes/token.ts`: ID Token / JWT アクセストークンの署名（`selectSigningKeyByAlg` で選択）
- `routes/userinfo.ts`: `userinfo_signed_response_alg` 指定時の署名付き UserInfo
- `routes/jwks.ts`: `exportJwks()` で公開鍵を JWKS として配信
- `routes/authorize.ts`: `jwksProvider` 経由で `id_token_hint` の署名検証（自分が発行した ID Token）

### 5.4 デプロイスクリプトの位置づけ

`samples/hono-cloudflare/scripts/deploy-cloudflare.sh` の冒頭コメントは
「これはリポジトリ保守者向けの検証ツールであり、ライブラリ利用者向けの本番デプロイガイドではない」
と明記している。したがって本トピックは「サンプルが本番手順を騙っている」問題ではなく、
**保守者自身の検証（OIDF Conformance Suite の実行を含む）が非決定的に壊れ得る**問題として扱うのが正確。

## 6. 現在の実装との差分

満たしていること:

- ✅ `SigningKeyProvider` 抽象と TTL キャッシュラッパが core にあり、永続鍵への差し替え口は存在する
- ✅ 単一プロセス・単一アイソレートで完結するローカル開発と、リポジトリ内の
  `conformance.test.ts` / E2E（同一プロセス内で OP を起動）では問題が顕在化しない
- ✅ `kid` は JWT と JWKS の両方に出ており、鍵が安定していればローテーションの土台は整っている

不足している可能性があること:

- 🔴 **同一 `kid` に対して複数の鍵素材が存在し得る**: Workers の別アイソレート、Fly の別マシン、
  Vercel の別インスタンスがそれぞれ別の鍵で署名する。RP が JWKS を引いたインスタンスと
  ID Token を発行したインスタンスが異なると、`kid` は一致するのに**署名検証が失敗**する。
  失敗は負荷とルーティングに依存するため**間欠的**で、原因特定が非常に難しい。
- 🔴 **再起動・再デプロイで既発行 JWT がすべて検証不能になる**: ID Token の有効期間は 1 時間、
  JWT アクセストークンも 1 時間。デプロイのたびにその窓の中のトークンが無効化される。
  `id_token_hint`（`prompt=none` 経路）も自分が発行した ID Token を検証できなくなり、
  `login_required` に落ちる。
- 🟠 **永続鍵プロバイダの実装例が 1 つも無い**: `SigningKeyProvider` の実装として提示されているのが
  エフェメラル版だけなので、利用者は「これが標準的な使い方」と読み取り得る。
  env に JWK を置く / D1・KV から読む、といった最小の実装例が無い。
- 🟠 **エフェメラル鍵であることの警告が無い**: 起動時ログにも生成コードのコメントにも
  「この鍵はプロセス／アイソレートごとに変わる」という注意書きが無い（関数名からしか読み取れない）。
- 🟡 **JWKS の `Cache-Control: public, max-age=3600` と相性が悪い**: 鍵が変わるのに RP 側は
  最大 1 時間 JWKS をキャッシュする。鍵が安定していれば妥当な設定だが、
  エフェメラル鍵と組み合わせると失敗窓を最大 1 時間に広げる。

セキュリティ上、改善した方がよいこと:

- エフェメラル鍵そのものは「鍵が漏れても寿命が短い」という意味では安全側だが、
  **可用性（availability）を損なう**。認証基盤における可用性の毀損はセキュリティ問題として扱うべき。
- 逆に永続化を導入する場合、**秘密鍵をどこに置くか**が新たな論点になる
  （Workers Secret / Fly secrets / Vercel Environment Variables / D1・KV に暗号化保存）。
  平文の環境変数に PKCS#8 を置くことの是非は方針判断が必要。

相互運用性の観点で改善した方がよいこと:

- OIDF Conformance Suite は Discovery → JWKS 取得 → 複数フロー実行という順序で動く。
  実デプロイに対して Suite を回すとき、鍵が途中で変わると **原因不明の署名検証 FAIL** として現れ、
  「Fidelity（Conformance 準拠を信頼性のシグナルとして維持する）」という本リポジトリの差別化軸を直接損なう。

Basic OP として提供する上で確認すべきこと:

- Basic OP の要件そのものは「RS256 で署名し、JWKS で公開する」ことであり、鍵の永続化は要件外。
  したがって本トピックは**仕様準拠の問題ではなく、実デプロイでの検証可能性の問題**である。
  ただし実デプロイに対する Conformance 実行を計画している
  （`study-material/basic-op-conformance-verification-plan.md`）以上、実務上は前提条件になる。

## 7. 改善・追加を検討する理由

- **なぜ価値があるか**: 本リポジトリのコンセプトは「どこでも動く形で検証できる」ことであり、
  `pnpm deploy:*` で実環境に上げて確かめる導線を用意している。その導線の先で
  間欠的な署名検証失敗が起きると、検証結果そのものが信用できなくなる。
- **Basic OP として必要か、拡張か**: 認定要件ではない。**実デプロイ検証の前提条件**として扱う。
- **導入しやすさ**: 高い。`SigningKeyProvider` インタフェースはすでに存在し、
  サンプルの 1 関数を差し替えるだけで済む。core の API 変更は不要。
  ただし「鍵をどこに置くか」はデプロイ先ごとに異なるため、サンプルごとに実装が分かれる。
- **既存実装との接続**:
  - env に JWK(JSON) を置く方式なら `JSON.parse` → `crypto.subtle.importKey('jwk', ...)` で
    `SigningKey` を組み立てるだけ。`extractAlgorithmParamsFromJwk` が core にあるので再利用できる。
  - D1 / KV に置く方式なら `createCachedSigningKeyProvider` でラップして TTL キャッシュを効かせる。
    この TTL 設定の指針は `signing-key-rotation-operations.md` の論点と直結する。
- **利用者・保守者メリット**: 再デプロイしてもトークンが生き残る。Conformance Suite を
  実デプロイに対して安定して回せる。鍵ローテーションの手順を実地で試せるようになる。
- **実装しない場合のリスク**:
  - 実デプロイに対する Conformance 実行結果が非決定的になり、`Fidelity` の主張が弱くなる
  - 利用者がエフェメラル生成をそのまま踏襲し、本番寄り環境で間欠的な認証失敗を踏む
  - `signing-key-rotation-operations.md` のローテーション手順が、そもそも鍵が永続していないため実行できない

## 8. 実装方針の候補

判断材料の整理（最終判断は人間が行う）。

### 方針A（env に JWK を置く永続プロバイダをサンプルに追加）

- `OIDC_SIGNING_KEY_JWK`（秘密鍵を含む JWK JSON）と `OIDC_SIGNING_KEY_ID` を読み、
  `crypto.subtle.importKey('jwk', ...)` で `SigningKey` を構築する `createEnvJwkSigningKeyProvider()` を各サンプルに追加。
- 未設定時は現行のエフェメラル生成にフォールバックし、**起動時に警告を出す**。
- 鍵生成用のワンショットスクリプト（`scripts/generate-signing-key.mjs` 等）を用意し、
  出力を各プラットフォームの secret 設定コマンド（`wrangler secret put` / `fly secrets set` /
  `vercel env add`）に流し込む手順をデプロイスクリプトのガイドに組み込む。
- 長所: 全サンプルで同じ形にできる。デプロイ先固有の API に依存しない。
- 短所: 秘密鍵が環境変数に平文で載る。ローテーションは secret 差し替え＋再デプロイになる。

### 方針B（デプロイ先ネイティブのストアに置く）

- hono-cloudflare は D1（既に `oidc_store` テーブルがある）または KV、
  Fly は Volume 上のファイル、Vercel は外部 KV。
- `createCachedSigningKeyProvider` でラップして読み出し回数を抑える。
- 長所: 複数鍵の保持・ローテーションを実地で試せる（`signing-key-rotation-operations.md` と直結）。
  再デプロイ非依存で鍵を差し替えられる。
- 短所: サンプルごとに実装が分かれ、保守コストが上がる。初回起動時の鍵生成・保存に
  複数インスタンスの競合（同時に生成して片方が上書き）を防ぐ工夫が要る。

### 方針C（エフェメラルのままにして、警告と文書だけ足す）

- `createEphemeralRs256KeyProvider` を `createEphemeralRs256KeyProvider_DEV_ONLY` にリネームし、
  起動時に「この鍵はインスタンス／再起動ごとに変わる。複数インスタンス構成では
  署名検証が間欠的に失敗する」と警告を出す。
- サンプル README とデプロイスクリプトのガイドに、単一インスタンスに固定する方法
  （Fly の `min_machines_running=1` 等）を書く。
- 長所: コスト最小。短所: Workers ではそもそも単一アイソレートに固定できないため、
  hono-cloudflare の問題は解決しない。

### 方針D（core に永続プロバイダのヘルパを追加）

- `createJwkSigningKeyProvider(jwkJson: string | object, keyId?: string): Promise<SigningKeyProvider>`
  を core に追加し、各サンプルはそれを呼ぶだけにする。
- 長所: 実装が 1 箇所に集約され、`assertKeyStrength` / `assertKidStrategyConsistent` との
  組み合わせも core 側で保証できる。CLI 生成コードからも使える。
- 短所: core の公開 API が増える（`RELEASE-v0.x-scope.md` のスコープ判断が要る）。
  「core はロジック層」という責務境界に、鍵ロードが入るかの線引きが必要。

判断のポイント:

- 方針A＋D の組み合わせ（core にヘルパ、サンプルは env から読む）が最もコスト対効果が高いと考えられるが、
  core の API 面積を増やすことの是非は `RELEASE-v0.x-scope.md` と突き合わせて判断する必要がある。
- 方針C 単独では hono-cloudflare（＝ Workers）で解決しないため、他方針との併用が前提になる。
- どの方針でも「未設定時にエフェメラルへフォールバックして警告する」挙動は共通で入れられる。
  ローカル開発の体験（`pnpm sample:*` が引数ゼロで動く）を壊さないために重要。

## 9. タスク案

- [ ] 方針 A〜D のどれを採るか（および core にヘルパを置くか）を人間が決定する
- [ ] 事実確認: Cloudflare Workers のアイソレート・ライフサイクルに関する一次資料を確認し、
      「モジュールスコープ状態はアイソレート単位」であることを本ファイルに追記する
- [ ] 共通（どの方針でも実施）:
  - [ ] エフェメラル鍵生成関数に「インスタンス／再起動ごとに鍵が変わる」ことを明記した
        JSDoc コメントを各サンプルに追加する
  - [ ] エフェメラル鍵にフォールバックした場合、起動時に警告を出す
- [ ] 方針A採用時:
  - [ ] 署名鍵生成スクリプト（JWK を標準出力する）を `scripts/` に追加
  - [ ] 各サンプルに `OIDC_SIGNING_KEY_JWK` を読む永続プロバイダを追加し、未設定時のみエフェメラルへフォールバック
  - [ ] `pnpm deploy:*` のガイドに secret 設定手順（`wrangler secret put` 等）を追加
- [ ] 方針B採用時:
  - [ ] hono-cloudflare: D1 の `oidc_store` に鍵を保存する `SigningKeyProvider` を実装し、
        初回生成時の競合（同時 INSERT）の扱いを決める
  - [ ] Fly / Vercel それぞれの保存先を決めて実装する
- [ ] 方針D採用時:
  - [ ] `createJwkSigningKeyProvider` を core に追加し、`assertKeyStrength` を内部で呼ぶ
  - [ ] TDD で単体テスト（正常な JWK / `kid` 不一致 / 弱い鍵 / 不正 JSON）を追加
  - [ ] `packages/cli` の生成テンプレートのコメントに使用例を追加
- [ ] 検証: 同一 `kid` で異なる鍵素材を持つ 2 インスタンスを立て、
      片方の JWKS で他方の ID Token を検証すると失敗することを回帰テストで固定する
      （エフェメラル方式の危険性を実証し、修正後に成功へ反転させる）
- [ ] `study-material/signing-key-rotation-operations.md` に「本ファイルが前提条件である」旨の相互参照を追記する
