# T-021 [Major] Discovery メタデータの不足フィールド追加

## ステータス

🟡 Major / 未着手

## 背景

必須フィールドは揃っているが、Basic OP Conformance テストおよびクライアントライブラリが参照する推奨フィールドが一部不足している。`grant_types_supported` や `token_endpoint_auth_methods_supported` はクライアントが動的にサポート内容を把握するために重要。

## 対象ファイル

- `packages/core/src/discovery.ts`
- `packages/cli/src/frameworks/hono/templates.ts`（Discovery config のデフォルト値）

## 仕様参照

- OIDC Discovery 1.0 §3: Provider Metadata
- RFC 8414 §2: Authorization Server Metadata

## 追加すべきフィールド

| フィールド | 値 | 仕様 |
|---|---|---|
| `grant_types_supported` | `["authorization_code", "refresh_token"]` | RFC 8414 §2 |
| `token_endpoint_auth_methods_supported` | `["client_secret_basic", "client_secret_post"]` | OIDC Discovery §3 |
| `claims_parameter_supported` | `true` | OIDC Core §5.5 対応済みのため |
| `request_parameter_supported` | `false` | OIDC Core §6（T-018 で追加） |
| `request_uri_parameter_supported` | `false` | OIDC Core §6（T-018 で追加） |
| `scopes_supported` | `["openid", "profile", "email", "address", "phone", "offline_access"]` | OIDC Discovery §3 推奨 |
| `claims_supported` | 標準クレーム一覧（下記参照） | OIDC Discovery §3 推奨 |

**`claims_supported` のデフォルト値**:

```json
[
  "sub", "iss", "aud", "exp", "iat", "auth_time", "nonce", "acr", "amr", "azp",
  "at_hash", "name", "given_name", "family_name", "middle_name", "nickname",
  "preferred_username", "profile", "picture", "website", "email", "email_verified",
  "gender", "birthdate", "zoneinfo", "locale", "phone_number", "phone_number_verified",
  "address", "updated_at"
]
```

**注意**: `request_parameter_supported` と `request_uri_parameter_supported` は T-018 とセットで追加。T-018 が先行しても後行してもよい。

## 修正方針

- [ ] `ProviderMetadataConfig` に以下のオプションプロパティを追加する

  ```typescript
  grantTypesSupported?: string[];
  tokenEndpointAuthMethodsSupported?: string[];
  claimsParameterSupported?: boolean;
  scopesSupported?: string[];
  claimsSupported?: string[];
  ```

- [ ] `buildProviderMetadata` で各フィールドを出力する
  - `grantTypesSupported` のデフォルト: `["authorization_code", "refresh_token"]`
  - `tokenEndpointAuthMethodsSupported` のデフォルト: `["client_secret_basic", "client_secret_post"]`
  - `claimsParameterSupported` のデフォルト: `true`
  - `scopesSupported` のデフォルト: 上記リスト
  - `claimsSupported` のデフォルト: 上記リスト

- [ ] `scopes_supported` / `claims_supported` はデフォルト値を持つが config で上書き可能にする

- [ ] CLI テンプレートの Discovery config にデフォルト値を設定する箇所を追加する

## テスト要件

- [ ] Discovery レスポンスに `grant_types_supported` が含まれること
- [ ] Discovery レスポンスに `token_endpoint_auth_methods_supported` が含まれること
- [x] Discovery レスポンスに `claims_parameter_supported: true` が含まれること（`p2-discovery-claims-feature-advertisement` で対応済み）
- [ ] Discovery レスポンスに `scopes_supported` が含まれること
- [x] Discovery レスポンスに `claims_supported` が含まれること（ID Token プロトコルクレーム含む。`p2-discovery-claims-feature-advertisement` で対応済み）
- [ ] config で `scopesSupported` を上書きした場合、Discovery に反映されること

## 完了条件

`pnpm --filter @maronn-openid-connect/core test` および `pnpm --filter @maronn-openid-connect/cli test` がパスすること
