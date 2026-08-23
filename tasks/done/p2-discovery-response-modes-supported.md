# [P2] Discovery に `response_modes_supported` を明示する

## ステータス

🟡 Minor / 未着手

## 背景

core の Discovery builder は `response_modes_supported` を出力できるが、CLI テンプレート側で値を設定していない。現状の実装は authorization code flow のみで、認可レスポンスは query で返すため、`["query"]` を明示しておく方がクライアントの誤解を防ぎやすい。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`
- `packages/cli/src/__tests__/hono-generator.test.ts`

## 仕様参照

- OpenID Connect Discovery 1.0 §3
- OAuth 2.0 Multiple Response Type Encoding Practices §2

## 現状の実装

- `buildProviderMetadata()` は `responseModesSupported` を受け取れる
- Discovery route template は `responseTypesSupported: ['code']` を設定しているが、`responseModesSupported` を渡していない

## 修正方針

- [ ] CLI Discovery template で `responseModesSupported: ['query']` を設定する
- [ ] code flow のみを提供する現状実装と advertise 内容を一致させる
- [ ] 将来 `form_post` 等を追加する場合はここを拡張する

## テスト要件

- [ ] 生成コードに `responseModesSupported: ['query']` が含まれること
- [ ] Discovery response に `response_modes_supported: ['query']` が含まれること

## 完了条件

`pnpm --filter @maronn-openid-connect/cli test` がパスすること
