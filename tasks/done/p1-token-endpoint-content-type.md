# [P1] Token Endpoint の `Content-Type` 検証追加

## ステータス

🟡 Major / 未着手

## 背景

OAuth の Token Request は `application/x-www-form-urlencoded` の entity-body を前提としている。現状の Hono テンプレートは `c.req.parseBody()` を直接呼んでおり、`multipart/form-data` など仕様外のフォーマットも受理しうる。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`
- `packages/cli/src/__tests__/hono-generator.test.ts`

## 仕様参照

- RFC 6749 §4.1.3: Access Token Request
- RFC 6749 Appendix B: `application/x-www-form-urlencoded`
- OIDC Core 1.0 §3.1.3.1: Token Request

## 現状の実装

- Token Endpoint 先頭で `Content-Type` を検証していない
- `parseBody()` の結果をそのまま `TokenRequestParams` 化している

そのため、仕様外のリクエスト形式を `invalid_request` にせず処理してしまう可能性がある。

## 修正方針

- [ ] Token Endpoint の先頭で `Content-Type` を検証する
- [ ] `application/x-www-form-urlencoded` 以外は `invalid_request` を返す
- [ ] `; charset=UTF-8` 付きは許容する
- [ ] 今後 introspection / revocation にも使い回せるよう、フォームボディ検証ヘルパー化を検討する

## テスト要件

- [ ] 生成コードに `Content-Type` チェックが含まれること
- [ ] `application/x-www-form-urlencoded` を受理すること
- [ ] `multipart/form-data` を `invalid_request` で拒否すること
- [ ] `application/json` を `invalid_request` で拒否すること

## 完了条件

`pnpm --filter @maronn-openid-connect/cli test` がパスすること
