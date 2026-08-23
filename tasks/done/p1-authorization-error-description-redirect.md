# [P1] Authorization Endpoint の redirect error に `error_description` を含める

## ステータス

🟡 Major / 未着手

## 背景

Authorization Endpoint の redirect エラーでは `error` だけでなく `error_description` も付与できる。現状のテンプレートは `buildErrorRedirect()` が `error` と `state` のみを扱うため、`prompt` / `id_token_hint` / セッション系の失敗理由がクライアント側へ伝わらない。

Conformance や実運用のデバッグでは、redirect ベースのエラーでも説明文がある方が望ましい。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`
- `packages/cli/src/__tests__/hono-generator.test.ts`

## 仕様参照

- OIDC Core 1.0 §3.1.2.6: Authentication Error Response
- RFC 6749 §4.1.2.1: Error Response

## 現状の実装

- `buildErrorRedirect()` は `error` / `state` のみ設定する
- `prompt=none` 失敗、`id_token_hint` 検証失敗、`max_age` 超過などの redirect エラーで `error_description` が落ちる
- `AuthorizationError` の catch 節では `error_description` を付与するが、`buildErrorRedirect()` 経由の分岐では揃っていない

## 修正方針

- [ ] `buildErrorRedirect()` に `errorDescription?: string` 引数を追加する
- [ ] 付与する値は RFC 6749 の許容文字に収まるよう sanitize する
- [ ] `AuthorizationError` / `IdTokenHintError` / route 内の静的エラー文を redirect に反映する
- [ ] success redirect には影響させない

## テスト要件

- [ ] `buildErrorRedirect()` に `error_description` 付与ロジックが生成されること
- [ ] `prompt=none` の `login_required` / `consent_required` で `error_description` が含まれること
- [ ] `id_token_hint` 検証失敗で `error_description` が含まれること
- [ ] 不正文字が sanitize されること

## 完了条件

`pnpm --filter @maronn-openid-connect/cli test` がパスすること
