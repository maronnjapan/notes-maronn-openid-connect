# /login と /consent が期限切れトランザクションや CSRF 不一致を 500 で返す（`AuthTransactionError.httpStatusCode` が未接続）

## 1. タイトル

core の `AuthTransactionError` は種別ごとに HTTP ステータス（TransactionNotFound / TransactionExpired → 400、InvalidCsrfToken → 403）と利用者向けメッセージを持つ。
しかし生成 OP の `/login` と `/consent`（GET / POST の 4 ハンドラ）は `getAuthTransaction` と `validateCsrfToken` を try/catch で囲んでおらず、これらの例外はフレームワーク既定の 500 になる。
`httpStatusCode` を参照しているのは transaction-binding 有効時のガードだけで、主要経路では dead code である。

## 2. このトピックで確認したいこと

- ログインフォームをトランザクション TTL（既定 10 分）より長く開いたまま送信する、古い `/consent?transaction_id=...` を開き直す、といった日常的な操作が 500 になっている現状の確認
- `AuthTransactionError` を捕捉して `views.errorPage` で 400 / 403 として描画する設計（binding ガードが既にやっている形）を主要経路へ広げるか
- CSRF 不一致（本来 403 のセキュリティシグナル）がサーバ障害と区別できないままエラーモニタリングに混ざる問題

## 3. 関連する仕様・基準

OIDC Core にこれらの画面遷移のステータスコードを定める MUST は無い。
準拠先は本リポジトリ自身の設計である。

- `AuthTransactionError.httpStatusCode` と各エラーメッセージ（"Auth transaction has expired. Please restart the authorization flow." 相当）は、この描画のために用意されている
- transaction-binding ガード（`rejectUnboundTransaction`）は同じ例外系を捕捉して `views.errorPage` で描画しており、揃えるべき先例になっている

TTL の設定可能化は `study-material/done/auth-transaction-ttl-configuration-and-lifecycle.md` / `tasks/p3-auth-transaction-ttl-configurable.md`、CSRF 比較の定数時間化は `tasks/p3-csrf-token-constant-time-comparison.md` が扱う。
本トピックは例外の HTTP 描画だけを扱う。

## 4. 参照資料

- RFC 9110 HTTP Semantics §15.5（4xx はクライアント起因、5xx はサーバ障害）— https://www.rfc-editor.org/rfc/rfc9110#section-15.5
- 本リポジトリ内: `packages/core/src/auth-transaction.ts:78-105`（`AuthTransactionError` と `httpStatusCode`）

## 5. 現在の実装確認

- `packages/core/src/auth-transaction.ts:78`（`AuthTransactionError`）: `code` から 400 / 403 を導出する `httpStatusCode` getter を持つ
- 生成物 `samples/hono-cloudflare/src/oidc-provider/routes/login.ts` / `consent.ts`: try/catch は各 1 箇所（transaction-binding の `rejectUnboundTransaction` 内部）のみ。`getAuthTransaction`（login.ts:69, 109 ほか）と `validateCsrfToken` は裸で呼ばれる
- 生成元は `packages/cli/src/frameworks/hono/templates.ts` の login / consent ルートテンプレート（web-standard 系も同じルートを派生させる）
- hono は `app.onError` を生成しないため既定の 500、web-standard の dispatch と express / fastify アダプタも例外をそのまま 500 系へ流す。Next.js はフレームワークのエラーページになる（/login /consent 用の error.tsx は生成していない）
- 期限切れ・不存在・CSRF 不一致を検証する conformance テストは無い（現状の 500 を固定しているテストも無い）

## 6. 現在の実装との差分

満たしていること:

- 例外の種別・メッセージ・ステータス対応は core に定義済みで、テストもある
- transaction-binding 有効時のガード経路は捕捉して 400 を描画する

不足している可能性があること:

- 🟡 **主要経路の未接続**: 期限切れトランザクションの送信・古い URL の再訪・CSRF 不一致が、設計済みの「有効期限切れです。最初からやり直してください」画面ではなく 500 になる
- 🟡 **監視の汚染**: CSRF 不一致（攻撃シグナルでありうる 403）とサーバ障害が同じ 500 に混ざる

## 7. 改善・追加を検討する理由

利用者にとっては日常操作で 500 が出る UX の問題であり、運用者にとっては 5xx 監視が偽アラートで汚れる問題である。
描画機構（`views.errorPage`）と例外の設計は揃っているため、4 ハンドラへ捕捉を足すだけで完結する。

## 8. 実装方針の候補

- **方針 A**: `/login` / `/consent` の GET / POST 各ハンドラで `AuthTransactionError` を捕捉し、`renderView(views.errorPage({ error: error.message, statusCode: error.httpStatusCode }), { status: error.httpStatusCode })` で描画する（binding ガードと同型）
- **方針 B**: 方針 A を共通ヘルパー（例: `renderAuthTransactionError`）に切り出して 4 ハンドラで共有する
- `AuthTransactionError` 以外の例外は従来どおり 500 に流す（サーバ障害の隠蔽を避ける）

## 9. タスク案

- `tasks/p3-login-consent-transaction-error-rendering.md` として切り出す
  - login / consent ルートテンプレートへ捕捉を追加（4 テンプレート共通のルート生成に対して行う）
  - conformance テスト: 不存在の transaction_id で 400、期限切れで 400、CSRF 不一致で 403 と、それぞれのエラーページ描画を固定
  - 既存の binding ガードの描画と重複しないことを確認
