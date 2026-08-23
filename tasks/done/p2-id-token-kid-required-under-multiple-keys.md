# [P2] 複数署名鍵を公開する場合、発行する署名付き JWT に JWKS と整合する `kid` を必須化する

## ステータス

🟡 Medium / 未着手

## 背景

OP が JWKS に **2 つ以上の署名鍵**を同時公開している（鍵ローテーション中・RS256/ES256 併存）とき、
発行する署名付き JWT（ID Token / 署名付き UserInfo / JWT Access Token）の JOSE Header に
`kid` が無いと、検証側（RP）が JWK Set の中から正しい鍵を一意に選べない。
RFC 7517 §4.5 が定義するとおり `kid` は「JWK Set 内の複数鍵から該当鍵を選ぶ」ための識別子であり、
複数鍵公開時に `kid` が欠けると RP の鍵選択が曖昧になって**サイレントに ID Token 検証が壊れる / 相互運用性が落ちる**。
OIDF Basic OP の `OP-IDToken-kid` 相当の観点でも、複数鍵を公開する OP は `kid` を載せることが期待される。

現状、`kid` は全署名経路で **optional**（`if (keyId) header.kid = keyId;`）で、
「JWKS に複数鍵があるのに発行 JWT に `kid` が無い／JWKS に存在しない `kid`」という不整合をライブラリが**検知していない**。
T-022 の複数 alg 鍵選択経路（`selectSigningKeyByAlg()` → `SigningKey.keyId`）を通る限り `kid` は載るが、
単一鍵 sample で `c.get('keyId')` が未設定の経路、および core を低レベルで直叩きするユースケースでは `kid` 無し発行が起こり得る。

このタスクの**目標は確定している**（複数鍵公開時は発行 JWT に JWKS と整合する `kid` を必須化する）。
採る手段（起動時アサーション / 発行時ガード / テンプレ修正）は下記から選択する。

根拠ファイル: `study-material/done/id-token-kid-presence-under-multiple-keys.md`
関連（重複回避）: `study-material/signing-key-rotation-operations.md`（運用フロー）、`study-material/jwks-endpoint-comprehensive.md`（JWKS 構造）、`tasks/done/T-022-add-sign-keys.md`（複数鍵対応）

## 対象ファイル

- `packages/core/src/signing-key.ts`（起動時アサーション追加）
- `packages/core/src/id-token.ts` / `packages/core/src/userinfo.ts` / `packages/core/src/access-token.ts`（発行時ガード: 任意）
- `packages/sample/src/oidc-provider/routes/token.ts` / `routes/userinfo.ts`（`keyId` を常に渡す）
- `packages/cli/src/frameworks/hono/templates.ts`（同上）
- 各対応する `*.test.ts`

## 仕様参照

- RFC 7517 (JWK) §4.5 `kid`：JWK Set 内の複数鍵から該当鍵を選ぶための識別子。Set 内で distinct な値を持つべき（SHOULD）。
  https://datatracker.ietf.org/doc/html/rfc7517#section-4.5
- RFC 7515 (JWS) §4.1.4 `kid`：どの鍵で署名したかのヒント。JWS 単体では OPTIONAL。
  https://datatracker.ietf.org/doc/html/rfc7515#section-4.1.4
- OpenID Connect Core 1.0 §10.1 / §10.1.1：署名鍵公開とローテーション。`kid` による鍵選択が前提（SHOULD）。
  https://openid.net/specs/openid-connect-core-1_0.html#RotateSigKeys
- OpenID Connect Conformance Profiles（Basic OP）：複数鍵公開時の `kid` 検証観点。
  https://openid.net/certification/conformance-testing-for-openid-connect/

> 一次資料の逐語と Basic OP テスト名・条件は実装前に再確認すること（本環境では spec サイトへのアクセスが 403 だった）。

## 現状の実装

```ts
// packages/core/src/id-token.ts (generateIdToken)
const header: Record<string, string> = { alg: getJwaAlgorithm(privateKey), typ: 'JWT' };
if (keyId) {
  header.kid = keyId;          // keyId 未指定なら kid 無しで発行される
}
```

```ts
// packages/sample/src/oidc-provider/routes/token.ts
const keyId = c.get('keyId'); // 未設定だと undefined → アクセストークン等に kid が載らない経路
```

- `SigningKey.keyId: string` は必須型だが、`generateIdToken` 等の発行関数は `keyId?: string`（optional）。
- 「JWKS の鍵数 > 1」と「発行 JWT の `kid` 有無・整合」を突き合わせるガードが存在しない。
- `assertHasRs256Key()` は RS256 の存在は見るが `kid` 整合は見ない。

## 修正方針

採用範囲は人間が選択する（目標は共通）。推奨は **A + C**（起動 fail-fast ＋ テンプレで常に kid 付与）、core 直叩き利用者も守るなら **B** も追加。

- [ ] **方針A（起動時アサーション・推奨）**: `signing-key.ts` に `assertKidStrategyConsistent(keys: SigningKey[])` を追加
  - 鍵が 2 件以上のとき、各 `keyId` が非空かつ JWK Set 内で distinct であることを検証し、違反なら throw
  - 鍵初期化経路 / `buildProviderMetadata` 呼び出し経路から呼ぶ
- [ ] **方針C（テンプレ修正・推奨）**: sample / CLI テンプレで発行関数へ `keyId` を**常に**渡す
  - `selectSigningKeyByAlg()` の戻り `SigningKey.keyId` を使い、`c.get('keyId')` が `undefined` になる経路を排除
- [ ] **方針B（発行時ガード・任意）**: `generateIdToken` / `generateUserInfoJwt` / JWT Access Token 発行に
  `requireKid?: boolean`（既定 false で後方互換）を追加し、true かつ `keyId` 未指定なら throw

実装例（方針A）:

```ts
export function assertKidStrategyConsistent(keys: readonly SigningKey[]): void {
  if (keys.length <= 1) return; // 単一鍵は kid 無しでも一意に決まる
  const seen = new Set<string>();
  for (const k of keys) {
    if (!k.keyId) {
      throw new Error('Multiple signing keys are published but a key has an empty kid');
    }
    if (seen.has(k.keyId)) {
      throw new Error(`Duplicate kid in signing key set: ${k.keyId}`);
    }
    seen.add(k.keyId);
  }
}
```

## テスト要件

- [ ] 複数鍵で `keyId` が空のものを含む鍵集合 → `assertKidStrategyConsistent` が throw する
- [ ] 複数鍵で `keyId` が重複する鍵集合 → throw する
- [ ] 単一鍵（`keyId` 空でも）→ 通過する（後方互換）
- [ ] 複数鍵で distinct な `keyId` → 通過する
- [ ] （方針B採用時）`requireKid=true` かつ `keyId` 未指定で `generateIdToken` → throw、指定あり → Header に `kid` が載る
- [ ] 結合テスト: JWKS に複数鍵を公開した状態で発行した ID Token の Header `kid` が JWKS のいずれかの鍵に一致する
- [ ] （テンプレ）CLI 生成コードで全署名 JWT 発行に `keyId` が渡る

## 完了条件

- 上記テストがすべて通る
- `pnpm --filter @maronn-openid-connect/core test` がパスする
- `pnpm --filter @maronn-openid-connect/cli test` がパスする
- 単一鍵の既定運用にリグレッションが無い（既存テストがパス）
