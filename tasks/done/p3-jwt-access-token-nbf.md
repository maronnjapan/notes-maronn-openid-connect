# [P3] JWT Access Token に `nbf` クレームを追加する

## ステータス

🟢 Minor / 未着手

## 背景

RFC 9068 §2.2 では JWT Access Token の `nbf`（Not Before）クレームは OPTIONAL だが、時計ずれ（clock skew）耐性を高めるために標準的に付与される。`iat` と同一の値を設定することで "このトークンは今より前には有効でない" ことを明示できる。主要 IdP（Auth0、Keycloak 等）は `nbf` を標準出力しており、RP 側のバリデータが `nbf` を期待するケースがある。

## 対象ファイル

- `packages/core/src/access-token-issuer.ts`
- `packages/core/src/access-token.ts`（型定義があれば）
- `packages/core/src/access-token-issuer.test.ts`

## 仕様参照

- RFC 9068 §2.2: JWT Profile for OAuth 2.0 Access Tokens — Claims
- RFC 7519 §4.1.5: "nbf" (Not Before) Claim

## 現状の実装

JWT Access Token のペイロードに `iss` / `sub` / `aud` / `exp` / `iat` / `scope` / `client_id` は含まれるが `nbf` がない。

## 修正方針

- [ ] `createJwtAccessTokenIssuer()` でトークン生成時に `nbf: iat` を追加する
  - `nbf` の値は `iat` と同一で問題ない（clock skew が心配な場合は `iat - leeway` も可）
- [ ] Opaque access token には不要（JWT 専用の対応）

```ts
// access-token-issuer.ts の issuePayload
{
  iss, sub, aud, exp,
  iat: now,
  nbf: now,  // 追加
  scope, client_id,
}
```

## テスト要件

- [ ] JWT access token のペイロードに `nbf` クレームが含まれること
- [ ] `nbf` の値が `iat` と等しいこと
- [ ] Opaque token には `nbf` が含まれないこと

## 完了条件

`pnpm --filter @maronn-openid-connect/core test` がパスすること
