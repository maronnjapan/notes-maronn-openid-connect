# [P3] CORS `Access-Control-Expose-Headers` を設定し `WWW-Authenticate` を SPA から読めるようにする

## ステータス

🟢 Low / 未着手

## 背景

生成コードの CORS ミドルウェアは `origin` / `allowMethods` / `allowHeaders` / `maxAge` のみを設定し、
`exposeHeaders`（= `Access-Control-Expose-Headers`）を設定していない。CORS の既定では、レスポンスのうち
JavaScript から読めるのは「CORS セーフリストレスポンスヘッダ」＋ Expose-Headers に列挙したヘッダのみで、
`WWW-Authenticate` は含まれない。そのため別オリジンの SPA は UserInfo/Token の Bearer チャレンジを
`response.headers.get('WWW-Authenticate')` から読めず、`null` になる。

エラー本文（JSON の `error`/`error_description`）はボディで読めるため致命的ではないが、
サンプルの想定デプロイ（Workers/Vercel/Fly + 別オリジン SPA）で相互運用の摩擦になる。
Basic OP 認証の MUST ではない相互運用 hardening。

検討詳細は `study-material/done/cors-expose-response-headers.md` を参照。

> 関連：リクエスト側 CORS（プリフライト・`Allow-Origin`・`Authorization` 許可）は `study-material/cors-cross-origin-support.md`。
> 本タスクはレスポンス読み取り側（Expose-Headers）に限定する。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`（`protectedCors` / `publicCors`）
- `packages/cli/src/frameworks/web-standard/templates.ts`（自前 CORS ヘルパ、`Access-Control-*` 出力箇所）
- 他フレームワークテンプレートの CORS 設定（要棚卸し）
- 各 sample の `conformance.test.ts` を生成する `packages/cli` 側コード（挙動変更が関わる場合）

## 仕様参照

- Fetch Standard（WHATWG）: JS から読めるレスポンスヘッダは CORS セーフリスト＋`Access-Control-Expose-Headers` 列挙分のみ。
- RFC 6750 §3: Bearer のエラーは `WWW-Authenticate` ヘッダで機械可読に返る。
- OIDC Core 1.0 §5.3.3: UserInfo のエラーは RFC 6750 の Bearer エラー方式で返す。

## 現状の実装

```ts
// packages/cli/src/frameworks/hono/templates.ts:181-187
const protectedCors = cors({
  origin: corsOrigins,
  allowMethods: ['POST', 'GET', 'OPTIONS'],
  allowHeaders: ['Authorization', 'Content-Type'],
  maxAge: 600,
  // exposeHeaders なし → WWW-Authenticate が読めない
});
```

web-standard も `templates.ts:567-579` の自前 CORS ヘルパで `Access-Control-Expose-Headers` を出力しない。

## 修正方針

- [ ] `protectedCors`（UserInfo/Token/introspection/revocation 用）に `exposeHeaders: ['WWW-Authenticate']` を追加
- [ ] web-standard の自前 CORS ヘルパに `Access-Control-Expose-Headers` の出力を追加
- [ ] （任意）`createApp` の options に `exposeHeaders?: string[]` を追加して既定 `['WWW-Authenticate']`・利用者上書き可にするか判断
- [ ] 生成コードは直接編集せず `packages/cli` テンプレートを修正する

## テスト要件

- [ ] （conformance / 生成 OP）UserInfo/Token の CORS 応答に `Access-Control-Expose-Headers: WWW-Authenticate` が含まれる
- [ ] （任意）`tests/e2e` の別オリジン SPA から UserInfo の `insufficient_scope` チャレンジをヘッダ経由で読めることを検証
- [ ] 既存の CORS プリフライト/`Allow-Origin` 挙動が回帰しない

## 完了条件

- `packages/cli` テンプレート修正後、`pnpm test` がパスすること
- 挙動変更が `conformance.test.ts` の想定に関わる場合、生成コード側を更新
