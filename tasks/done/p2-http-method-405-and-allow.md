# [P2] 許可外 HTTP メソッドに 405 + `Allow` を返し、UserInfo の GET/POST 両対応を回帰固定する

## ステータス

✅ 完了（2026-07-21）

## 背景

各エンドポイントは正しいメソッドでは正しく動くが、**許可されないメソッドが来たときの挙動が未整備**。`/token`・`/revoke`・`/introspect` は `app.post('/')` のみ、`/.well-known/*` は `get` のみで登録されており、Hono の既定では「パス一致・メソッド不一致」のリクエストが `404 Not Found` にフォールバックし `Allow` ヘッダも付かない可能性が高い。RFC 9110 §15.5.6 は許可外メソッドに `405 Method Not Allowed` を、§10.2.1 は 405 応答に `Allow` ヘッダ生成を MUST とする。404 だとクライアント/プロキシ/監視から「エンドポイント不在」と「メソッド違い」が区別できない。

加えて、OIDC Core §5.3.1 は **UserInfo が GET と POST の両方をサポートすることを MUST** とする。現状 `userinfoApp.get('/')` と `userinfoApp.post('/')` の両方が登録され実装済みだが、これを保証する回帰テストが薄い。

エラー本文・ステータスの横断方針は `study-material/error-response-cross-endpoint.md`、検討の経緯は `study-material/done/http-method-enforcement-and-allow-header.md` を参照。`OPTIONS`（CORS プリフライト）は既存 CORS ミドルウェア（`apply.ts`）の責務で、本タスクでは扱わない。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`（生成コードのルート登録部。CLAUDE.md 方針により生成物の修正は cli を直す）
- `packages/sample/src/oidc-provider/apply.ts`（sample のルート mount 部）
- 各ルートテンプレート / `packages/sample/src/oidc-provider/routes/*.ts`（方針B採用時）
- 対応するテストファイル（`*.test.ts`）

## 仕様参照

- OIDC Core 1.0 §5.3.1 — UserInfo は GET/POST の両方を MUST サポート。
- RFC 6749 §3.2 — Token Endpoint は POST。
- RFC 7009 §2.1 / RFC 7662 §2.1 — Revocation / Introspection は POST。
- RFC 9110 §15.5.6（405 Method Not Allowed）/ §10.2.1（405 応答は `Allow` を生成 MUST）。

## 現状の実装

| エンドポイント | 登録メソッド | 箇所 |
|---|---|---|
| `/authorize` | get + post | `routes/authorize.ts:379-380` |
| `/userinfo` | get + post | `routes/userinfo.ts:136-137` |
| `/token` | post のみ | `routes/token.ts:58` |
| `/revoke` | post のみ | `routes/revocation.ts:26` |
| `/introspect` | post のみ | `routes/introspection.ts:23` |
| `/.well-known/jwks.json` | get のみ | `routes/jwks.ts:15` |
| `/.well-known/openid-configuration` | get のみ | `routes/discovery.ts:11` |

許可外メソッド時に 405 + `Allow` を保証するミドルウェア/テストは存在しない。

## 修正方針

着手前にまず、現行 Hono バージョンでの「パス一致・メソッド不一致」時の実応答（404 か 405 か、`Allow` の有無）を実機テストで確定する。そのうえで:

- [ ] 許可メソッド表（`/token:[POST]`、`/userinfo:[GET,POST]`、`/revoke:[POST]`、`/introspect:[POST]`、`/.well-known/*:[GET]` 等）に基づき、メソッド不一致時に `405` + `Allow: <許可メソッド,カンマ区切り>` を返すようにする（方針A: 共通ミドルウェア / 方針B: 各ルートで `app.all` フォールバック）。
- [ ] UserInfo の GET/POST 両対応（OIDC §5.3.1 MUST）を回帰テストで固定する。
- [ ] CORS プリフライト（`OPTIONS`）が 405 ミドルウェアより先に処理され、競合しないことを確認する（ミドルウェア順序）。
- [ ] sample と CLI テンプレートの両方に同型で反映する（生成コードは cli を修正）。

## テスト要件

- [ ] `GET /token` が `405` を返し、`Allow: POST` を含むこと。
- [ ] `GET /revoke` / `GET /introspect` が `405` + `Allow: POST` を返すこと。
- [ ] `POST /.well-known/openid-configuration` / `POST /.well-known/jwks.json` が `405` + `Allow: GET` を返すこと。
- [ ] `GET /userinfo`（Bearer 付き）と `POST /userinfo`（form body）の両方が成功すること（OIDC §5.3.1 の回帰固定）。
- [ ] 正しいメソッド（`POST /token` 等）の既存挙動が回帰しないこと。
- [ ] `OPTIONS`（CORS プリフライト）が 405 にならず CORS ミドルウェアで処理されること。

## 完了条件

`pnpm --filter @maronn-openid-connect/cli test`（および sample のテスト）がパスし、上記テストが追加されていること。許可外メソッドが 405 + `Allow` を返し、UserInfo の GET/POST 両対応が回帰テストで固定されていること。
