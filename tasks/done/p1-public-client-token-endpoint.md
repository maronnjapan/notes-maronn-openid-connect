# [P1] Public Client の Token Endpoint 利用対応

## ステータス

🟡 Major / 未着手

## 背景

OAuth 2.0 / 2.1 では、confidential client は Token Endpoint で認証が必要だが、public client は `client_secret` を持たない形が許容される。authorization_code grant では未認証クライアントが `client_id` を送ることが想定され、refresh token grant でも「認証可能な場合に」クライアントと refresh token の binding を検証する。

現状実装は `authenticateClient()` が `client_secret` を必須としており、public client を Token Endpoint で扱えない。

## 対象ファイル

- `packages/core/src/client-auth.ts`
- `packages/core/src/token-request.ts`
- `packages/core/src/index.ts`
- `packages/core/src/discovery.ts`
- `packages/core/src/client-auth.test.ts`
- `packages/core/src/token-request.test.ts`
- `packages/cli/src/frameworks/hono/templates.ts`

## 仕様参照

- RFC 6749 §2.3 / §3.2.1: Client Authentication
- RFC 6749 §4.1.3: Authorization Code Access Token Request
- RFC 6749 §6: Refreshing an Access Token

## 現状の実装

- `TokenClientInfo.clientSecret` が required
- `authenticateClient()` は `client_id` と `client_secret` の両方が揃わないと `invalid_client`
- `validateTokenRequest()` は「認証済み clientId」を前提にしている
- Discovery の `token_endpoint_auth_methods_supported` も `none` を advertise できない

## 修正方針

- [ ] public client を表現できるよう、token client の型を見直す
- [ ] `authenticateClient()` は confidential / public を解決して分岐し、public client では `client_secret` を要求しない
- [ ] `authorization_code` grant で未認証 public client は `client_id` 必須とする
- [ ] `refresh_token` grant でも、public client は `client_id` で refresh token の発行先クライアントと一致確認できるようにする
- [ ] confidential client の既存要件は維持する
- [ ] Discovery で `token_endpoint_auth_methods_supported` に `none` を含められるようにする

## テスト要件

- [ ] public client が `client_id` のみで authorization code を token 交換できること
- [ ] public client が `client_id` のみで refresh token を使えること
- [ ] public client で `client_id` が欠落した場合はエラーになること
- [ ] confidential client は引き続き client authentication 必須であること
- [ ] `Authorization` ヘッダーと body の二重指定禁止が壊れないこと

## 完了条件

`pnpm --filter @maronn-openid-connect/core test` および `pnpm --filter @maronn-openid-connect/cli test` がパスすること
