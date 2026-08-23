# [P3] クライアント登録の `default_acr_values` を `acr_values` 不在時のフォールバックに適用する

## ステータス

🟢 Low / 未着手

## 背景

クライアント登録メタデータ `default_acr_values`（OIDC Dynamic Client Registration 1.0 §2）は、認可リクエストに `acr_values` が無くても OP 側でクライアント既定の要求 ACR を適用するためのものである。兄弟メタデータの `default_max_age` は既にフォールバック実装済み（`tasks/done/p2-client-default-max-age-fallback.md`）だが、`default_acr_values` は未対応で、`ClientInfo` にフィールドが無く、`validateAuthorizationRequest` はリクエストの `acr_values` のみを参照する。この非対称により、`default_acr_values` を登録した RP の期待（毎回 `acr_values` を明示しなくても既定 ACR が要求される）が満たされない。

検討の経緯と論点は `study-material/done/client-default-acr-values-fallback.md` を参照。Basic OP certification の必須要件ではない（ACR は任意）ため優先度は低いが、`default_max_age` と同型で差分が小さく、DCR メタデータ honoring の一貫性を上げる。

## 対象ファイル

- `packages/core/src/authorization-request.ts`（`ClientInfo` / `validateAuthorizationRequest`、L983 の `acr_values` 採用箇所）
- `packages/core/src/authorization-request.test.ts`
- `packages/cli/src/frameworks/hono/templates.ts`（`RegisteredClient` への透過と設定例）
- `packages/cli` の `conformance.test.ts` 生成コード（生成 OP の契約更新用）

## 仕様参照

- OpenID Connect Dynamic Client Registration 1.0 §2 — `default_acr_values`:
  「Default requested Authentication Context Class Reference values. … The `acr_values` request parameter or an individual `acr` Claim request via the `claims` request parameter supersedes these default values.」
- OpenID Connect Core 1.0 §3.1.2.1 — `acr_values`（要求 ACR の順序付き優先リスト）。
- OpenID Connect Core 1.0 §5.5.1.1 — `claims.id_token.acr.values` は `acr_values` と等価に扱える。

## 現状の実装

- `packages/core/src/authorization-request.ts` L983: `const acrValues = effective.acr_values;` — リクエスト値をそのまま採用し、`client.defaultAcrValues` へのフォールバックが無い。
- 対照的に L967-976 では `max_age` 不在時に `client.defaultMaxAge` へフォールバックしている（同じ分岐が `acr_values` には無い）。
- `ClientInfo` は `defaultMaxAge` を持つが `defaultAcrValues` を持たない。
- `token-response.ts` L299-311 の `effectiveRequestedAcrValues` もリクエスト・`claims` のみを見ており、クライアント既定は参照しない。
- grep 上、`default_acr_values` / `defaultAcrValues` はコード・study-material・tasks・samples のいずれにも存在しない（完全未対応）。

## 修正方針

- [ ] `ClientInfo` に `defaultAcrValues?: string[]` を追加し、JSDoc に DCR §2 由来・リクエストの `acr_values`／`claims.id_token.acr` が supersede することを明記する。
- [ ] `validateAuthorizationRequest` で、リクエスト `acr_values` が `undefined` かつ `client.defaultAcrValues` が定義済み（非空）の場合に、当該値（空白区切り文字列に正規化）を `acrValues` として採用する分岐を追加する。
- [ ] `acr_values` が明示された場合は従来どおりリクエスト値を優先する（上書き規則）。
- [ ] `default_acr_values` の各要素が非空文字列であることを軽く検証し、空配列は「未指定」と同義に正規化する。
- [ ] `RegisteredClient` に同フィールドを透過し、`default_acr_values` を設定した例を 1 つ用意する。
- [ ] `claims.id_token.acr.values` が存在する場合は、そちらが `default_acr_values` より優先されること（§5.5.1.1）を確認する。

実装イメージ:

```ts
// validateAuthorizationRequest 内、acr_values 採用の箇所（現状 L983）
let acrValues = effective.acr_values;
if (acrValues === undefined && client.defaultAcrValues && client.defaultAcrValues.length > 0) {
  // OIDC DCR 1.0 §2 / Core §3.1.2.1: request acr_values が無い場合は
  // クライアント登録の default_acr_values を既定として採用する。
  // request の acr_values / claims.id_token.acr がある場合はそちらが優先（supersede）。
  acrValues = client.defaultAcrValues.join(' ');
}
```

## テスト要件

- [ ] `acr_values` 不在 + `client.defaultAcrValues=['urn:loa:2']` のとき `validated.acrValues === 'urn:loa:2'` になること。
- [ ] `acr_values` 明示 + `client.defaultAcrValues` 設定時、リクエスト値が優先されること。
- [ ] `acr_values` も `defaultAcrValues` も無いとき `validated.acrValues === undefined` になること。
- [ ] `claims.id_token.acr.values` が指定されているとき、`default_acr_values` より優先されて `AcrResolver` に渡ること。
- [ ] `defaultAcrValues` 採用時、`AcrResolver` の `requestedAcrValues` に伝播し、ID Token `acr` の解決へ一貫して流れること。

## 完了条件

`pnpm --filter @maronn-openid-connect/core test` がパスし、上記テストが追加されていること。`conformance.test.ts` 生成元を更新した場合は、生成 OP の該当テストも整合していること。
