# [P2] パブリッククライアントの Token Revocation 対応

## ステータス

✅ 完了（2026-07-21）

## 背景

Token Revocation エンドポイント（RFC 7009）の HTTP 配線が **confidential client 認証を必須**としており、`client_secret` を持たない public client（SPA / ネイティブアプリ）が自身のトークンを revoke できない。sample の `routes/revocation.ts` は冒頭で `Confidential client only — public clients are out of scope for this template.` と明示している。

OAuth 2.1 では public client が認可コード＋PKCE フローの主役であり、refresh token を保持し得る（rotation 強制）。ログアウト時にサーバ側 refresh/access token を確実に失効させる手段が無いと、漏洩トークンの自発的無効化ができない。RFC 7009 §2.1 は public client による revocation（`client_secret` 検証は confidential のときのみ、public は `client_id` 一致で判定）を想定している。

検討の詳細は `study-material/done/public-client-token-revocation-rfc7009.md` を参照。Introspection（RFC 7662）は resource server 向けのため、本タスクの対象外（revocation に限定）。

Basic OP 必須要件ではない（OAuth 拡張の機能網羅）。

## 対象ファイル

- `packages/core/src/client-auth.ts`（public 認証解決。`p1-public-client-token-endpoint` と共通化）
- `packages/sample/src/oidc-provider/routes/revocation.ts`（public 経路の配線・コメント更新）
- `packages/cli/src/frameworks/hono/templates.ts`（revocation テンプレートの public 対応）
- 必要に応じて統合テスト（`packages/sample` 側）/ `packages/core/src/revocation.test.ts`

> core の `packages/core/src/revocation.ts`（`handleRevocationRequest`）は `authenticatedClientId` ベースで既に機能するため、**原則変更しない**（public の `client_id` を `authenticatedClientId` として渡すだけ）。

## 仕様参照

- RFC 7009 §2.1 Revocation Request — https://www.rfc-editor.org/rfc/rfc7009#section-2.1
  （"validates the client credentials (in case of a confidential client)" → public は client_id 一致のみ検証 / 他クライアント発行トークンは拒否）
- RFC 7009 §2.2 Revocation Response — https://www.rfc-editor.org/rfc/rfc7009#section-2.2
  （成功・未発見とも 200 OK）
- OAuth 2.1 draft（public client / PKCE） — https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1

## 現状の実装

```ts
// packages/core/src/client-auth.ts:141-146
if (!clientId || !clientSecret) {
  throw new TokenError(TokenErrorCode.InvalidClient, 'Client authentication required');
}
// → client_secret 不在の public client を受理できない。token_endpoint_auth_method=none 経路が無い。

// packages/sample/src/oidc-provider/routes/revocation.ts:18-19
// Confidential client only — public clients are out of scope for this template.
```

- `handleRevocationRequest`（`revocation.ts:124-151`）と `tryRevokeRefresh`/`tryRevokeAccess` は `info.clientId !== authenticatedClientId` を `invalid_grant` で拒否するロジックを既に持つ。

## 修正方針

- [ ] **前提タスクの確認**: `tasks/done/p1-public-client-token-endpoint.md` で `authenticateClient`（またはクライアント認証解決層）が confidential/public 両対応になっていること。未完了ならそちらを先行。
- [ ] その共通認証解決を revocation ルートでも再利用し、登録上 public（`token_endpoint_auth_method=none`）かつ `client_secret` 不在のクライアントは `client_id` のみで認証扱いとする。
- [ ] core の `handleRevocationRequest` は変更しない（`authenticatedClientId` に public の `client_id` を渡す）。
- [ ] sample/CLI テンプレートの `Confidential client only` コメントを更新し、public 経路を追加。
- [ ] 認証ロジックの二重化を避ける（revocation 専用の最小実装＝方針B は非推奨。共通化を優先）。

## テスト要件

- [ ] public client が `client_id` のみで自身の refresh token を revoke でき、200 OK が返る
- [ ] public client が自身の access token を revoke でき、関連 refresh の cascade（既存挙動）が壊れない
- [ ] public client が **他クライアント発行**トークンを指定した場合に `invalid_grant`
- [ ] confidential client の既存 revocation 挙動が回帰しない
- [ ] `client_id` 欠落の public リクエストは適切にエラー（`invalid_client` 等）

## 完了条件

`pnpm --filter @maronn-openid-connect/core test` および `pnpm --filter @maronn-openid-connect/cli test` がパスすること。
