# [P1] Authorization Response への `iss` パラメータ付与

## ステータス

🟡 Major / 未着手

## 背景

RFC 9207 をサポートする Authorization Server は、成功・エラーを含む authorization response に `iss` パラメータを含める必要がある。現状のテンプレートは `code` / `state` や `error` / `state` のみを付与しており、issuer identification を返していない。

## 対象ファイル

- `packages/core/src/discovery.ts`
- `packages/core/src/discovery.test.ts`
- `packages/cli/src/frameworks/hono/templates.ts`
- `packages/cli/src/__tests__/hono-generator.test.ts`

## 仕様参照

- RFC 9207 §2: Response Parameter `iss`
- RFC 9207 §3: `authorization_response_iss_parameter_supported`

## 現状の実装

- authorize 成功 redirect で `iss` を付与していない
- authorize エラー redirect で `iss` を付与していない
- consent deny / consent success redirect でも `iss` を付与していない
- Discovery に `authorization_response_iss_parameter_supported` を出せない

## 修正方針

- [ ] 認可レスポンスの成功・エラー両方に `iss=config.issuer` を付与する
- [ ] `buildErrorRedirect()` に issuer を渡せるようにする
- [ ] 手組みしている redirect 分岐も漏れなく `iss` を含める
- [ ] Discovery metadata に `authorization_response_iss_parameter_supported: true` を追加する

## テスト要件

- [ ] 成功時 redirect URL に `iss` が含まれること
- [ ] エラー時 redirect URL に `iss` が含まれること
- [ ] consent deny の redirect にも `iss` が含まれること
- [ ] Discovery に `authorization_response_iss_parameter_supported: true` が含まれること

## 完了条件

`pnpm --filter @maronn-openid-connect/core test` および `pnpm --filter @maronn-openid-connect/cli test` がパスすること
