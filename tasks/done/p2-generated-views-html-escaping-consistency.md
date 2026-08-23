# [P2] 生成ビューのログイン／同意ページで全反映値を `escapeHtml` し XSS sink を解消する

## ステータス

✅ 完了（2026-07-21）

## 背景

CLI 生成 OP の `defaultLoginPage` / `defaultConsentPage` は、HTML テンプレートに `transactionId` / `csrfToken` /（ログインの）`error` を**エスケープせず**埋め込んでいる。一方、同一ファイル `views.ts` 内の同意ページ `clientId` / `scope`、エラーページ `error` / `errorDescription` は `escapeHtml()` を適用しており、**同一モジュール内でエスケープ方針が非一貫**になっている。

既定ストアではこれらは server 生成のランダム値（store キー）であり、`getAuthTransaction()` が不一致値を render 前に弾くため**直接の reflected XSS は成立しにくい**。しかし、

- 利用者がストア／ビューを差し替える（CLAUDE.md / views.ts コメントが明示的に推奨）
- `login_hint` プレフィル（`tasks/done/p3-login-hint-ui-prefill.md`）で新フィールドを追加する

と、未エスケープ sink が stored/reflected XSS に転じる。認可サーバ origin での XSS は CSRF トークン・セッション・認可コード窃取に直結するため、secure-by-default の観点で是正する。

CSP / `X-Frame-Options` 等の**ヘッダ層**防御は別タスク（`study-material/http-security-headers-and-tls.md`）が扱う。本タスクは**出力エンコーディング層**のみを対象とする。詳細な検討は `study-material/done/generated-login-consent-html-escaping-consistency.md` を参照。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`（`viewsTemplate()` — 修正の正本）
- `samples/hono/src/oidc-provider/views.ts`（再生成）
- `samples/express/src/oidc-provider/views.ts`（再生成）
- `samples/fastify/src/oidc-provider/views.ts`（再生成）
- `samples/*/conformance.test.ts`（生成元 `packages/cli` 経由でエスケープ契約テストを追加）

※ Next.js サンプルは JSX 自動エスケープのため対象外（`dangerouslySetInnerHTML` 不使用を確認済み）。

## 仕様参照

- OAuth 2.0 Security Best Current Practice（RFC 9700）§2 / §4 — 認可サーバ UI（ログイン／同意）は XSS 高価値ターゲット
- OWASP Cross Site Scripting Prevention Cheat Sheet — HTML 要素本文／属性値コンテキストの文脈別出力エンコーディング
- OWASP ASVS v4 V5.3 Output Encoding and Injection Prevention

## 現状の実装

```ts
// samples/hono/src/oidc-provider/views.ts
function defaultLoginPage(params: LoginPageParams): string {
  const errorHtml = params.error
    ? `<p style="color: red;">${params.error}${          // ← error 未エスケープ（要素本文）
        params.remainingAttempts !== undefined
          ? `. Attempts remaining: ${params.remainingAttempts}` : ''
      }</p>` : '';
  return `...
    <input type="hidden" name="transaction_id" value="${params.transactionId}" /> // ← 未エスケープ（属性値）
    <input type="hidden" name="csrf_token" value="${params.csrfToken}" />          // ← 未エスケープ（属性値）
  ...`;
}

function defaultConsentPage(params: ConsentPageParams): string {
  // scope / clientId はエスケープ済み
  .map((s) => `    <li>${escapeHtml(s)}</li>`)
  const escapedClientId = escapeHtml(params.clientId);
  return `...
    <input type="hidden" name="transaction_id" value="${params.transactionId}" /> // ← 未エスケープ
    <input type="hidden" name="csrf_token" value="${params.csrfToken}" />          // ← 未エスケープ
  ...`;
}
```

`escapeHtml()`（`& < > " '` を実体参照化）は同ファイルに定義済みで、属性値の `"` も含むため適用するだけで属性ブレイクアウトも防げる。

## 修正方針

- [ ] `packages/cli/src/frameworks/hono/templates.ts` の `viewsTemplate()` で:
  - ログイン: `params.error` → `escapeHtml(params.error)`
  - ログイン: `transaction_id` / `csrf_token` の value → `escapeHtml(params.transactionId)` / `escapeHtml(params.csrfToken)`
  - 同意: `transaction_id` / `csrf_token` の value → `escapeHtml(...)`
- [ ] 「テンプレートへ渡る文字列は例外なく `escapeHtml` を通す」方針を関数冒頭コメントで明文化
- [ ] `samples/hono` / `samples/express` / `samples/fastify` の `views.ts` を再生成し、差分が上記のみであることを確認
- [ ] `remainingAttempts` は数値だが、テンプレートに文字列補間されるため必要なら `String()` 経由で扱いを明示

## テスト要件

- [ ] `defaultLoginPage` に `transactionId: '"><script>alert(1)</script>'` を渡すと、出力に生の `<script>` / 属性ブレイクアウトが含まれない（`&lt;script&gt;` / `&quot;` にエスケープ）
- [ ] `defaultLoginPage` に `error: '<img src=x onerror=alert(1)>'` を渡すと出力がエスケープされる
- [ ] `defaultLoginPage` の `csrfToken` に `"` を含む値を渡すと `&quot;` にエスケープされる
- [ ] `defaultConsentPage` の `transactionId` / `csrfToken` も同様にエスケープされる
- [ ] 正常なランダム値（英数字）はエスケープ後も同一表現で出力される（リグレッション無し）
- [ ] `samples/*/conformance.test.ts` にログインビューのエスケープ契約テストを追加し、利用者改変時に検知できる

## 完了条件

- `pnpm --filter @maronn-openid-connect/cli test` がパスすること
- 各 sample の `conformance.test.ts` がパスすること
- 再生成した `samples/*/views.ts` の差分がエスケープ適用のみであること
