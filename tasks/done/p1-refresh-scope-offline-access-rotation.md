# [P1] refresh 時の scope 縮小で `offline_access` を落としても refresh token rotation を維持する

## ステータス

🟡 Major / 未着手

## 背景

現状の refresh token grant は scope の縮小を許可しているが、新しい refresh token を発行するかどうかを「縮小後 scope に `offline_access` が含まれるか」で判定している。そのため、元の grant では offline access が許可されていても、refresh 時に `scope=openid email` のように `offline_access` を落とすと新 refresh token が発行されない。

さらに現実装は新トークン保存後に旧 refresh token を失効するため、レスポンス自体は成功しても、その後 refresh 継続不能になる。

## 対象ファイル

- `packages/core/src/token-request.ts`
- `packages/cli/src/frameworks/hono/templates.ts`
- `packages/core/src/token-request.test.ts`
- `packages/cli/src/__tests__/hono-generator.test.ts`

## 仕様参照

- RFC 6749 §6: Refreshing an Access Token
- OAuth 2.1 refresh token rotation の整合性要件

## 現状の実装

- `validateTokenRequest()` は元 scope のサブセットへの縮小を許可する
- Token Endpoint は `issueRefreshToken: validatedRequest.scope.includes('offline_access')`
- refresh_token grant 成功後に旧 refresh token を revoke する

## 修正方針

- [ ] refresh token 再発行可否を「元 refresh token が offline access を持っていたか」で判断できるようにする
- [ ] そのためのフラグを `ValidatedRefreshTokenRequest` に持たせる、または同等の情報を伝播させる
- [ ] scope 縮小は access token / ID Token の権限縮小として扱い、refresh token rotation 可否とは切り離す
- [ ] 代替案として `offline_access` を落とす refresh 要求を `invalid_scope` にする方針も比較し、どちらを採るか明示する

## テスト要件

- [ ] 元 scope に `offline_access` を持つ refresh token で、縮小 scope から `offline_access` を落としても新 refresh token が返ること
- [ ] 元 scope に `offline_access` が無い場合は新 refresh token が返らないこと
- [ ] 既存の revoke 順序が壊れず、保存成功後に旧 token が失効されること

## 完了条件

`pnpm --filter @maronn-openid-connect/core test` および `pnpm --filter @maronn-openid-connect/cli test` がパスすること
