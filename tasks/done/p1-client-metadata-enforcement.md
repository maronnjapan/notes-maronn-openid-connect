# [P1] クライアント登録メタデータの強制（grant_types / response_types / token_endpoint_auth_method）

## ステータス

🟠 High / 未着手

## 背景

OAuth 2.0 / OIDC では、クライアントは登録時に使用できる grant type（`grant_types`）・response type（`response_types`）・クライアント認証方式（`token_endpoint_auth_method`）を登録（または OP 既定）し、**認可サーバは登録外の使い方を拒否しなければならない**。

本リポジトリは「このクライアントがその grant / response_type / 認証方式を使ってよいか」というクライアント単位の認可判定を一切していない。影響:

- **refresh_token を発行・利用すべきでないクライアントでも `grant_type=refresh_token` が通る**（最小権限違反、Refresh Token フローの入口の穴）。
- `client_secret_basic` 限定で登録したクライアントが `client_secret_post` でも認証できる（認証方式ダウングレードを防げない）。
- `AuthorizationErrorCode.UnauthorizedClient` / `TokenErrorCode.UnauthorizedClient` が定義のみで未使用（dead code）。

検討の詳細・仕様根拠・方針比較は `study-material/done/client-metadata-enforcement.md` を参照（本タスクは実装に絞る）。per-client scope 強制は scope ポリシーの未決事項（`study-material/scope-handling-validation-and-granted-scope.md`）に依存するため本タスクの対象外とする。

## 対象ファイル

- `packages/core/src/authorization-request.ts`（`ClientInfo`、`validateAuthorizationRequest`）
- `packages/core/src/token-request.ts`（`TokenClientInfo`、`validateTokenRequest`）
- `packages/core/src/client-auth.ts`（`authenticateClient`）
- `packages/core/src/index.ts`（型 export）
- `packages/core/src/authorization-request.test.ts`
- `packages/core/src/token-request.test.ts`
- `packages/core/src/client-auth.test.ts`
- `packages/sample/src/op/d1-resolver.ts`（`FullClientInfo`）
- `packages/sample/src/oidc-provider/config.ts`（登録クライアント定義）
- `packages/cli/src/frameworks/hono/templates.ts`（生成テンプレートの client モデル）

## 仕様参照

- RFC 6749 §5.2: `unauthorized_client` = 「The authenticated client is not authorized to use this authorization grant type.」（トークンエンドポイント）
- RFC 6749 §4.1.2.1 / OAuth 2.1 §4.1.2.1: `unauthorized_client` = 「The client is not authorized to request an authorization code using this method.」（認可エンドポイント）
- OAuth 2.1 §3.2.3: トークンエンドポイントのエラーコード
- OpenID Connect Dynamic Client Registration 1.0 §2 / RFC 7591 §2: クライアントメタデータ `grant_types`（既定 `["authorization_code"]`）/ `response_types`（既定 `["code"]`）/ `token_endpoint_auth_method`（既定 `client_secret_basic`）
- OIDC Core 1.0 §9: Client Authentication 方式

## 現状の実装

- `ClientInfo`（`authorization-request.ts`）: `clientId` / `redirectUris` / `clientType?` のみ。grant/response_type/auth_method を保持しない。
- `validateAuthorizationRequest`（510-528 行）: `response_type === 'code'` をグローバル判定するだけで、クライアント単位の許可を見ない。
- `TokenClientInfo`（`token-request.ts`）: `clientId` / `clientSecret` のみ。
- `validateTokenRequest`（316-329 行）: `grant_type` がサポート値かをグローバル判定するだけで、クライアントの `grant_types` を見ない。
- `authenticateClient`（`client-auth.ts`）: 送られてきた認証方式（Basic / post）をそのまま受理し、登録方式と照合しない。
- `UnauthorizedClient` エラーコードは両 enum に定義されているが参照ゼロ。

## 修正方針

- [ ] `ClientInfo` に optional 追加: `responseTypes?: string[]`（既定 `["code"]`）
- [ ] `TokenClientInfo` に optional 追加: `grantTypes?: string[]`（既定 `["authorization_code"]`）/ `tokenEndpointAuthMethod?: 'client_secret_basic' | 'client_secret_post' | 'none'`（既定 `client_secret_basic`）
- [ ] `validateAuthorizationRequest`: `response_type` が `client.responseTypes`（既定込み）に含まれなければ `AuthorizationErrorCode.UnauthorizedClient`（redirect 可能エラー：`redirectUri` / `state` 付き）を throw する
- [ ] `validateTokenRequest`: `grant_type` が `client.grantTypes`（既定込み）に含まれなければ `TokenErrorCode.UnauthorizedClient` を throw する（grant_type 検証・クライアント解決の後）
- [ ] `authenticateClient`: 実際に使われた認証方式が `client.tokenEndpointAuthMethod` と一致しなければ `TokenErrorCode.InvalidClient` を throw する（方式不一致は認証失敗扱い）
- [ ] 未指定クライアントは既定値で従来どおり動作すること（後方互換）
- [ ] sample / CLI の client モデルに新フィールドを反映。refresh を使うサンプルクライアントは `grantTypes` に `refresh_token` を含める
- [ ] Discovery の `grant_types_supported` / `token_endpoint_auth_methods_supported`（`tasks/T-021-discovery-metadata.md`）と矛盾しないことを確認

実装例（トークンエンドポイント）:

```typescript
// validateTokenRequest 内、grant_type 検証 + client 解決の後
const allowedGrantTypes = client.grantTypes ?? ['authorization_code'];
if (!allowedGrantTypes.includes(params.grant_type)) {
  throw new TokenError(
    TokenErrorCode.UnauthorizedClient,
    `Client is not authorized to use grant_type: ${params.grant_type}`,
  );
}
```

## テスト要件

- [ ] `grantTypes` に `refresh_token` を含まないクライアントが `grant_type=refresh_token` を送ると `unauthorized_client` になること
- [ ] `grantTypes` に `authorization_code` を含むクライアントは従来どおり code 交換できること
- [ ] `grantTypes` 未指定クライアントは `authorization_code` のみ許可（既定）され、refresh は `unauthorized_client` になること
- [ ] `responseTypes` に `code` を含まないクライアントが `response_type=code` を送ると `unauthorized_client`（redirect 可能、`state` 保持）になること
- [ ] `responseTypes` 未指定クライアントは `code` を許可（既定）すること
- [ ] `tokenEndpointAuthMethod=client_secret_basic` のクライアントが `client_secret_post` で認証すると `invalid_client` になること（逆方向も）
- [ ] `tokenEndpointAuthMethod` 未指定クライアントは `client_secret_basic` 既定で従来どおり動くこと
- [ ] `unsupported_grant_type` / `unsupported_response_type`（OP 全体未サポート）と `unauthorized_client`（クライアント未許可）が正しく区別されること

## 完了条件

- 上記テストが TDD（Red → Green）で追加され、`pnpm --filter @maronn-openid-connect/core test` がパスすること
- `pnpm --filter @maronn-openid-connect/cli test` がパスすること
- 既存テストが後方互換で全てパスすること
