# [P2] クライアント登録の `default_max_age` を `max_age` 不在時のフォールバックに適用する

## ステータス

🟡 Medium / 未着手

## 背景

クライアント登録メタデータ `default_max_age`（OIDC Dynamic Client Registration 1.0 §2）は、認可リクエストに `max_age` が無くても OP 側で再認証鮮度を担保するための既定値である。現状 `ClientInfo` にこのフィールドが無く、`validateAuthorizationRequest` はリクエストの `max_age` のみを参照するため、`default_max_age` を登録した RP の期待（古い認証なら再認証されるはず）が満たされない。

検討の経緯と論点は `study-material/done/client-default-max-age-and-require-auth-time.md` を参照。`require_auth_time` の core guard 化（方針 B）は API 設計合意が必要なため本タスクの対象外とし、ここでは挙動として欠落している `default_max_age` フォールバックに絞る。

## 対象ファイル

- `packages/core/src/authorization-request.ts`（`ClientInfo` / `validateAuthorizationRequest`）
- `packages/core/src/authorization-request.test.ts`
- `packages/sample/src/oidc-provider/config.ts`（`RegisteredClient` への透過と設定例）

## 仕様参照

- OpenID Connect Dynamic Client Registration 1.0 §2 — `default_max_age`:
  「End-User MUST be actively authenticated if the End-User was authenticated longer ago than the specified number of seconds. The `max_age` request parameter overrides this default value.」
- OpenID Connect Core 1.0 §3.1.2.1 — `max_age` が `default_max_age` を上書きし、有効時は ID Token の `auth_time` が MUST present。

## 現状の実装

- `ClientInfo`（`authorization-request.ts` L70-81）に `defaultMaxAge` 相当のフィールドが無い。
- `max_age` はリクエストパラメータからのみ解析され（`validateMaxAge` / L604-608）、不在時にクライアント既定値へフォールバックする経路が無い。
- grep 上、`default_max_age` / `defaultMaxAge` はコード・study-material・tasks のいずれにも存在しない（完全未対応）。

## 修正方針

- [ ] `ClientInfo` に `defaultMaxAge?: number`（非負整数）を追加し、JSDoc に DCR §2 由来・`max_age` が来た場合は上書き優先であることを明記する。
- [ ] `validateAuthorizationRequest` で、リクエスト `max_age` が `undefined` かつ `client.defaultMaxAge` が定義済みの場合に `maxAge = client.defaultMaxAge` を採用する分岐を追加する。
- [ ] `max_age` が明示された場合は従来どおりリクエスト値を優先する（上書き規則）。
- [ ] `defaultMaxAge` が負値など不正な場合の扱いを決める（呼び出し側責務とするか、core で軽く検証するか）。
- [ ] `RegisteredClient` に同フィールドを透過し、`default_max_age` を設定した例を 1 つ用意する。

実装イメージ:

```ts
// validateAuthorizationRequest 内、max_age 解析の箇所
let maxAge: number | undefined;
if (params.max_age !== undefined) {
  maxAge = validateMaxAge(params.max_age, redirectUri, state);
} else if (client.defaultMaxAge !== undefined) {
  // OIDC DCR 1.0 §2 / Core §3.1.2.1: request max_age が無い場合は
  // クライアント登録の default_max_age を既定値として採用する。
  maxAge = client.defaultMaxAge;
}
```

## テスト要件

- [ ] `max_age` 不在 + `client.defaultMaxAge=600` のとき `validated.maxAge === 600` になること。
- [ ] `max_age='120'` 明示 + `client.defaultMaxAge=600` のとき `validated.maxAge === 120`（リクエスト優先）になること。
- [ ] `max_age` も `defaultMaxAge` も無いとき `validated.maxAge === undefined` になること。
- [ ] `defaultMaxAge` 採用時も、後続の再認証強制ロジック（既存 `04-max-age-enforcement` 動線）が `maxAge` を一貫して扱えること。

## 完了条件

`pnpm --filter @maronn-openid-connect/core test` がパスし、上記テストが追加されていること。
