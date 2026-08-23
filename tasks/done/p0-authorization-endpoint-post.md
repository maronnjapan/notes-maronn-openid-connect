# [P0] Authorization Endpoint の HTTP POST 対応

## ステータス

🟡 Critical / 未着手

## 背景

OIDC Core 1.0 は Authorization Endpoint で HTTP `GET` と `POST` の両方をサポートすることを要求している。`POST` の場合、認可リクエストは `application/x-www-form-urlencoded` の Form Serialization で送られる。

現状の Hono テンプレートは `authorizeApp.get('/')` のみを定義しており、Form Serialization を使うクライアントや Basic OP Conformance の POST パスを処理できない。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`
- `packages/cli/src/__tests__/hono-generator.test.ts`

## 仕様参照

- OIDC Core 1.0 §3.1.2.1: Authentication Request
- OIDC Core 1.0 §13.2: Form Serialization

## 現状の実装

- Authorization Endpoint は `authorizeApp.get('/', ...)` のみ
- GET 用の query-string パースとハンドリングが route 本体に埋め込まれている
- POST 用の route も、GET / POST 共通の認可リクエスト処理関数も存在しない

## 修正方針

- [ ] `authorizeApp.post('/', ...)` を追加する
- [ ] GET / POST で共通利用する認可リクエストハンドラを抽出する
- [ ] POST では `application/x-www-form-urlencoded` の body を解釈し、GET と同じ `AuthorizationRequestParams` に変換する
- [ ] POST での `Content-Type` も検証し、仕様外フォーマットは `invalid_request` とする
- [ ] 既存の `prompt=none`、`id_token_hint`、`max_age`、offline_access フィルタなどの分岐が GET / POST で同一挙動になるようにする

## テスト要件

- [ ] 生成コードに `authorizeApp.post('/')` が含まれること
- [ ] GET / POST が同一の認可リクエスト処理ロジックを使うこと
- [ ] POST で `application/x-www-form-urlencoded` を受理すること
- [ ] POST で `application/json` や `multipart/form-data` を拒否すること
- [ ] `prompt=none` 等の既存フローが POST 経由でも利用できること

## 完了条件

`pnpm --filter @maronn-openid-connect/cli test` がパスすること
