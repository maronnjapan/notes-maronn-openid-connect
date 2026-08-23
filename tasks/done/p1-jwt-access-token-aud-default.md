# [P1] JWT Access Token の空 `aud` 防止

## ステータス

🟡 Major / 未着手

## 背景

RFC 9068 では JWT access token の `aud` に resource indicator を入れることが要求される。`resource` 指定が無い場合でも Authorization Server はデフォルトの resource indicator を `aud` に入れなければならない。

現状の `generateTokenResponse()` は `audience` 未指定時に `[]` を入れるため、JWT access token として不正な `aud` を生成しうる。

## 対象ファイル

- `packages/core/src/access-token.ts`
- `packages/core/src/token-response.ts`
- `packages/core/src/token-response.test.ts`
- `packages/cli/src/frameworks/hono/templates.ts`

## 仕様参照

- RFC 9068 §3: Requesting a JWT Access Token
- RFC 9068 §4: Validating JWT Access Tokens

## 現状の実装

- `generateTokenResponse()` は `const accessTokenAud = audience ?? [];`
- `validatePayload()` は `aud` の空配列を拒否しない
- authorization_code grant で `audience` 未指定の通常ケースでは `aud: []` の JWT が発行されうる

## 修正方針

- [ ] `aud` 空配列を `validatePayload()` で拒否する
- [ ] Token 発行時には必ず空でない `aud` を与える
- [ ] 当面のデフォルト resource indicator として `clientId` を使う、または明示的なデフォルト audience 解決手段を導入する
- [ ] refresh_token grant でも同じ `aud` が維持される既存仕様を壊さない

## テスト要件

- [ ] `audience` 未指定でも JWT access token の `aud` が空配列にならないこと
- [ ] `audience` 明示時はその値が優先されること
- [ ] refresh_token grant 後も `aud` が維持されること
- [ ] `aud: []` を生成しようとすると失敗すること

## 完了条件

`pnpm --filter @maronn-openid-connect/core test` および `pnpm --filter @maronn-openid-connect/cli test` がパスすること
