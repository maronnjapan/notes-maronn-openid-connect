# [P0] `claims` パラメータの `id_token` メンバー対応

## ステータス

🟡 Critical / 未着手

## 背景

OIDC Core 1.0 §5.5 は、`claims` Authentication Request Parameter が `userinfo` と `id_token` の両方のトップレベルメンバーを持てることを定義している。現状の core は `ClaimsParameter` を UserInfo 用にのみ定義しており、認可リクエスト側でも `claims` 自体を受け取っていない。

この状態で Discovery に `claims_parameter_supported: true` を出すと、`id_token` 向け個別クレーム要求や `acr` の individual claims request を処理できず、実装と advertise 内容が矛盾する。

## 対象ファイル

- `packages/core/src/authorization-request.ts`
- `packages/core/src/authorization-code.ts`
- `packages/core/src/token-response.ts`
- `packages/core/src/userinfo.ts`
- `packages/core/src/index.ts`
- `packages/cli/src/frameworks/hono/templates.ts`
- `tasks/T-021-discovery-metadata.md`（依存関係の見直し）

## 仕様参照

- OIDC Core 1.0 §5.5: Requesting Claims using the `claims` Request Parameter
- OIDC Core 1.0 §5.5.1.1: Requesting the `acr` Claim

## 現状の実装

- `AuthorizationRequestParams` に `claims` が存在しない
- `ValidatedAuthorizationRequest` / 認可コード / token 発行コンテキストに `claims` 情報が引き継がれない
- `ClaimsParameter` 型は `userinfo?: ...` のみで、`id_token` を表現できない
- `generateTokenResponse()` は individual claims request を考慮せず、scope ベースの既定クレームのみを ID Token に含める

## 修正方針

- [ ] 認可リクエストで `claims` パラメータを受け取れるようにする
- [ ] `ClaimsParameter` を `userinfo` / `id_token` の両方に対応させる
- [ ] individual claim request の値型は少なくとも `essential?: boolean`、`value?: unknown`、`values?: unknown[]` を表現できるようにする
- [ ] 認可コード保存時に `claims` リクエストを保持し、Token Endpoint で ID Token 生成時に参照できるようにする
- [ ] `id_token` member に対して、少なくとも `acr` を含む標準 claim 要求を処理できるようにする
- [ ] 本タスク完了までは `claims_parameter_supported` を advertise しない、または `false` のままにする

## テスト要件

- [ ] `claims` に `id_token` メンバーを含む認可リクエストを受理し、認可コード経由で Token Endpoint まで伝播すること
- [ ] `claims.id_token.acr.values=[...]` を要求した場合、満たせるときは ID Token に `acr` が含まれること
- [ ] `claims.id_token` に unknown member があっても無視されること
- [ ] `claims.userinfo` の既存挙動が壊れないこと
- [ ] Discovery の `claims_parameter_supported` を `true` にするのは、上記の end-to-end 対応が揃った後であること

## 完了条件

`pnpm --filter @maronn-openid-connect/core test` および `pnpm --filter @maronn-openid-connect/cli test` がパスすること
