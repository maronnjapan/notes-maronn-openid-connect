# [P0] authorization_code で解決した `acr` / `amr` の Refresh Token 永続化

## ステータス

🟡 Critical / 未着手

## 背景

`AcrResolver` により authorization_code grant 時の ID Token には `acr` / `amr` を載せられるようになった。一方で refresh_token grant 側は、初回認証時の `acr` / `amr` を `RefreshTokenInfo` から引き継ぐ設計になっている。

しかし現状は authorization_code grant で resolver が解決した `acr` / `amr` が `generateTokenResponse()` のローカル変数で消費されるだけで、refresh token store に保存されない。そのため後続の refresh では `acr` / `amr` が欠落する。

## 対象ファイル

- `packages/core/src/token-response.ts`
- `packages/core/src/token-response.test.ts`
- `packages/cli/src/frameworks/hono/templates.ts`
- `packages/cli/src/__tests__/hono-generator.test.ts`

## 仕様参照

- OIDC Core 1.0 §2: `acr` / `amr`
- OIDC Core 1.0 §12.2: Successful Refresh Response

## 現状の実装

- `generateTokenResponse()` は `resolvedAcr` / `resolvedAmr` を ID Token payload にのみ反映する
- 戻り値 `TokenResponse` には `acr` / `amr` が含まれない
- CLI テンプレートの `refreshTokenStore.set()` は `grantType === 'refresh_token'` のときだけ `validatedRequest.acr` / `validatedRequest.amr` を保存している
- そのため、初回 authorization_code grant で resolver が返した `acr` / `amr` は refresh token に永続化されない

## 修正方針

- [ ] `generateTokenResponse()` が解決した `acr` / `amr` を呼び出し側へ返せるようにする
- [ ] authorization_code grant 時の `refreshTokenStore.set()` に、その resolved 値を保存する
- [ ] refresh_token grant 時は既存どおり保存済み `acr` / `amr` を再利用する
- [ ] 既存の「refresh では direct 値を優先し resolver を呼ばない」挙動を維持する

## テスト要件

- [ ] authorization_code grant で resolver が返した `acr` / `amr` が refresh token 保存データに含まれること
- [ ] refresh_token grant で再発行される ID Token に同じ `acr` / `amr` が含まれること
- [ ] resolver が `undefined` を返した場合は従来どおり未保存であること
- [ ] refresh 時に resolver を再実行しないこと

## 完了条件

`pnpm --filter @maronn-openid-connect/core test` および `pnpm --filter @maronn-openid-connect/cli test` がパスすること
