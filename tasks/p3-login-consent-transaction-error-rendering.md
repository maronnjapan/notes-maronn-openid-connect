# [P3] /login と /consent で `AuthTransactionError` を捕捉し、期限切れ・CSRF 不一致を 400 / 403 のエラーページで返す

## ステータス

🟡 Medium / 未着手

## 背景

core の `AuthTransactionError` は種別ごとの HTTP ステータス（TransactionNotFound / TransactionExpired → 400、InvalidCsrfToken → 403）と利用者向けメッセージを持つが、生成 OP の `/login` と `/consent`（GET / POST の 4 ハンドラ）は `getAuthTransaction` と `validateCsrfToken` を捕捉していない。
ログインフォームをトランザクション TTL より長く開いたまま送信する、古い `/consent` URL を開き直す、といった日常操作がフレームワーク既定の 500 になる。
CSRF 不一致（本来 403 のセキュリティシグナル）もサーバ障害と区別できない。

`httpStatusCode` を参照して `views.errorPage` で描画する形は、transaction-binding ガード（`rejectUnboundTransaction`）が既に実装している。
検討詳細は `study-material/done/auth-transaction-error-http-rendering.md` を参照。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`（login / consent ルートテンプレート。4 テンプレート共通のルート生成）
- 生成 conformance テスト（生成元 `packages/cli`）
- 生成物（直接編集しない・確認用）: `samples/*/src/oidc-provider/routes/login.ts` / `consent.ts`
- Next.js の login / consent Server Action（`packages/cli/src/frameworks/web-standard/templates.ts`）にも同じ例外経路があるかを確認する

## 仕様参照

- **RFC 9110 §15.5** — https://www.rfc-editor.org/rfc/rfc9110#section-15.5
  4xx はクライアント起因、5xx はサーバ障害
- 本リポジトリの設計: `packages/core/src/auth-transaction.ts:78-105`（`AuthTransactionError.httpStatusCode`）

## 現状の実装

- login / consent の各ハンドラは `const transaction = await getAuthTransaction(transactionId, transactionStore);` を裸で呼ぶ（生成物 login.ts:69, 109 ほか）
- try/catch は transaction-binding の `rejectUnboundTransaction` 内部の 1 箇所のみ。そこでは捕捉して `views.errorPage` を `httpStatusCode` で描画している
- hono は `app.onError` を生成せず、web-standard の dispatch にも例外処理が無いため、未捕捉例外は 500 系になる

## 修正方針

- [ ] `AuthTransactionError` を捕捉して `renderView(views.errorPage({ error: error.message, statusCode: error.httpStatusCode }), { status: error.httpStatusCode })` で描画する処理を、login / consent の GET / POST 4 ハンドラへ追加する
- [ ] 4 ハンドラで重複しないよう共通ヘルパーに切り出すか、各ハンドラで捕捉するかを決める（binding ガードの既存描画との整合も確認する）
- [ ] `AuthTransactionError` 以外の例外は従来どおり流す（サーバ障害を 4xx で偽装しない）
- [ ] Next.js の Server Action 経路での同種の例外の扱いを確認し、必要なら揃える
- [ ] 生成コードは直接編集せず `packages/cli` テンプレートを修正する

## テスト要件

生成 OP の `conformance.test.ts`（生成元 `packages/cli`）に追加する。

- [ ] `should render a 400 error page for an unknown transaction id on the login form`
- [ ] `should render a 400 error page when the auth transaction has expired`（TTL を短くした構成、またはストアからの削除で再現）
- [ ] `should render a 403 error page for a CSRF token mismatch on login submission`
- [ ] `should render a 403 error page for a CSRF token mismatch on consent submission`
- [ ] 正常フロー（login → consent → code 発行）が回帰しないこと

## 完了条件

- `pnpm --filter @maronn-openid-connect/cli test` がパスする
- `samples/*` を再生成し、各 `conformance.test.ts` が通る
- `pnpm typecheck` がパスする
- 期限切れ・不存在・CSRF 不一致が 500 になる経路が login / consent に残っていない
