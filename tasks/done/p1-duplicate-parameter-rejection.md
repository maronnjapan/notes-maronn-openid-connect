# [P1] Authorization / Token Endpoint の重複パラメータ拒否

## ステータス

🟡 Major / 未着手

## 背景

OAuth / OIDC では、エンドポイントの request / response parameters は重複してはならない。現状の authorize / token ルートは `Object.fromEntries(...)` で単純にオブジェクト化しており、重複キーが silent に後勝ちになる。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`
- `packages/cli/src/__tests__/hono-generator.test.ts`

## 仕様参照

- OIDC Core 1.0 §3.1.2.1: Authentication Request
- RFC 6749 §3.1 / §3.2

## 現状の実装

- Authorization Endpoint: `Object.fromEntries(new URL(c.req.url).searchParams)`
- Token Endpoint: `parseBody()` 結果を `Object.entries(...).map(...)` してオブジェクト化

この実装では、例えば `response_type=code&response_type=token` や `grant_type=authorization_code&grant_type=refresh_token` を検出できない。

## 修正方針

- [ ] query / form-urlencoded の生パラメータから重複キーを検出するヘルパーを追加する
- [ ] 重複があれば `invalid_request` を返す
- [ ] Token Endpoint は raw form body を `URLSearchParams` で解釈する方式へ寄せ、重複検出と型変換を同時に行う
- [ ] authorize / token の両方で同じポリシーになるよう揃える

## テスト要件

- [ ] Authorization Endpoint で重複 `response_type` を拒否すること
- [ ] Authorization Endpoint で重複 `scope` を拒否すること
- [ ] Token Endpoint で重複 `grant_type` を拒否すること
- [ ] Token Endpoint で重複 `client_id` / `code_verifier` なども拒否すること

## 完了条件

`pnpm --filter @maronn-openid-connect/cli test` がパスすること
