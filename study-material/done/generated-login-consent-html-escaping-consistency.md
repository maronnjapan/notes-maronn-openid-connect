# 生成ビューの HTML エスケープ一貫性（ログイン／同意ページの未エスケープ sink）

## ステータス

🟠 High（潜在 XSS / defense-in-depth）/ 未着手

## 1. タイトル

CLI 生成 OP の `defaultLoginPage` / `defaultConsentPage` が、ハードコードされた HTML テンプレートに `transactionId` / `csrfToken` / `error` を**エスケープせず**埋め込んでおり、同一ファイル内の `clientId` / `scope` / `error_description` はエスケープしているという**非一貫性**を是正する。

> 注: CSP / `X-Frame-Options` / クリックジャッキング / `Referrer-Policy` / UI ページの `Cache-Control` といった **HTTP ヘッダ層**の防御は `study-material/http-security-headers-and-tls.md` が扱う（Login/Consent のクリックジャッキング、`frame-ancestors 'none'` 等を明記済み）。本ファイルはヘッダ層ではなく**出力エンコーディング（HTML エスケープ）層**という直交する論点のみを扱い、ヘッダ層の説明は繰り返さない。

## 2. このトピックで確認したいこと

- `packages/cli` が生成する `views.ts` の `defaultLoginPage` / `defaultConsentPage` / `defaultErrorPage` のうち、どのテンプレートがどの値をエスケープしているかを棚卸しする
- ログインページの `error` / `transactionId` / `csrfToken`、同意ページの `transactionId` / `csrfToken` が**未エスケープのまま HTML へ反映**されている点を確認する
- 既定ストアではこれらが server 生成のランダム値（store キー）であり直接悪用しにくいが、(a) 利用者がストアやビューをカスタマイズした場合、(b) `login_hint` プレフィル（`study-material/done/login-hint-ui-prefill.md`）を追加した場合に、未エスケープ sink が顕在化するリスクを確認する

## 3. 関連する仕様・基準

- **OAuth 2.0 Security Best Current Practice（RFC 9700）**: 認可サーバの UI（ログイン／同意画面）は、その origin に注入されたスクリプトがセッション Cookie・CSRF トークン・実行中の認可トランザクションを読み取れるため、XSS の高価値ターゲットとして扱うべきとされる。出力エンコーディングはその基本対策。
- **OWASP XSS Prevention Cheat Sheet / ASVS V5.3（Output Encoding）**: HTML レスポンスへ反映する信頼できないデータは、出力コンテキスト（要素本文／属性値）に応じて文脈別エスケープすること。属性値コンテキストでは少なくとも `"`（`&quot;`）のエスケープが必須。
- **本リポジトリ内の既定契約**: 同一ファイル `views.ts` が `escapeHtml()` ヘルパーを持ち、同意ページの `clientId` / `scope`、エラーページの `error` / `errorDescription` に明示的に適用している。エラーページには「crafted error_description が markup を注入できないようにエスケープする（XSS）」というコメントもある。つまり**この OSS 自身がエスケープを契約として確立済み**であり、ログイン／同意の一部 sink だけがその契約から漏れている。

## 4. 参照資料

- OAuth 2.0 Security BCP（RFC 9700）§2 / §4 — https://www.rfc-editor.org/rfc/rfc9700 （AS UI への XSS リスク）
- OWASP Cross Site Scripting Prevention Cheat Sheet — https://cheatsheetseries.owasp.org/cheatsheets/Cross_Site_Scripting_Prevention_Cheat_Sheet.html
- OWASP ASVS v4 V5.3 Output Encoding and Injection Prevention — https://owasp.org/www-project-application-security-verification-standard/
- 関連既存ファイル（ヘッダ層 / CSP）: `study-material/http-security-headers-and-tls.md`
- 関連既存ファイル（login_hint プレフィルで新フィールドを追加する計画）: `study-material/done/login-hint-ui-prefill.md` / `tasks/p3-login-hint-ui-prefill.md`

## 5. 現在の実装確認

修正の正本（CLAUDE.md に従い generator を直す）: `packages/cli/src/frameworks/hono/templates.ts` の `viewsTemplate()`。
生成結果（同一内容）: `samples/hono/src/oidc-provider/views.ts`、`samples/express/.../views.ts`、`samples/fastify/.../views.ts`。

`samples/hono/src/oidc-provider/views.ts` での実態:

- `escapeHtml()` ヘルパーは定義済み（行 65-72、`& < > " '` を実体参照化）。
- **ログインページ `defaultLoginPage`（行 74-104）— 未エスケープ**:
  ```ts
  const errorHtml = params.error
    ? `<p style="color: red;">${params.error}${ /* params.error 未エスケープ（要素本文） */
        params.remainingAttempts !== undefined
          ? `. Attempts remaining: ${params.remainingAttempts}` : ''
      }</p>` : '';
  // ...
  <input type="hidden" name="transaction_id" value="${params.transactionId}" /> // 未エスケープ（属性値）
  <input type="hidden" name="csrf_token" value="${params.csrfToken}" />        // 未エスケープ（属性値）
  ```
- **同意ページ `defaultConsentPage`（行 106-130）— 一部エスケープ漏れ**:
  ```ts
  .map((s) => `    <li>${escapeHtml(s)}</li>`)  // scope はエスケープ済み
  const escapedClientId = escapeHtml(params.clientId); // clientId はエスケープ済み
  // しかし hidden field は未エスケープ:
  <input type="hidden" name="transaction_id" value="${params.transactionId}" /> // 未エスケープ
  <input type="hidden" name="csrf_token" value="${params.csrfToken}" />        // 未エスケープ
  ```
- **エラーページ `defaultErrorPage`（行 132-147）— エスケープ済み**: `error` / `errorDescription` ともに `escapeHtml`。

既定ストアでの直接悪用可否（確認済み）:

- `transaction_id` は GET 時に store キーとして使われ、`getAuthTransaction()` が server 生成の `generateRandomString(32)` と一致しない値で `TransactionNotFound` を throw する（`packages/core/src/auth-transaction.ts`）。よって攻撃者が markup を含む `transaction_id` を送っても render 前に弾かれる。
- `csrfToken` も server 生成・検証対象。
- 生成サンプルの `params.error` はハードコード文字列 `'Invalid credentials'`。
- したがって**既定構成では直接の reflected XSS は成立しにくい**＝現状は潜在 / defense-in-depth の欠落。

## 6. 現在の実装との差分

満たしていること:

- `escapeHtml` の存在と、同意（clientId / scope）・エラー（error / error_description）への適用。
- React を使う Next.js サンプルは JSX 自動エスケープで安全（`dangerouslySetInnerHTML` 不使用）。
- ログイン／同意の POST に CSRF トークン（hidden field + `validateCsrfToken`）あり。

不足・改善余地:

- 🟠 **エスケープの非一貫性**: 同一モジュール内で「エスケープするフィールド」と「しないフィールド」が混在。`transactionId` / `csrfToken`（属性値）と ログイン `error`（要素本文）が未エスケープ。
- 🟠 **カスタマイズで顕在化**: CLAUDE.md / views.ts のコメントは利用者にストア・ビューの差し替えを明示的に推奨している。予測可能 / クライアント echo な transaction ID を使うストアや、`error` により豊富な値を渡すカスタムログインを書いた瞬間、これらの sink は stored/reflected XSS になる。
- 🟠 **login_hint プレフィル計画との不整合**: `done/login-hint-ui-prefill.md` は新フィールド `loginHint` に `escapeHtml(loginHint)` を求めているが、同じ関数内の既存 `transactionId` / `csrfToken` / `error` が未エスケープである点には触れていない。このままだと「新フィールドはエスケープ、既存フィールドは未エスケープ」という歪な状態で出荷される。
- 🟡 **属性値コンテキストの最低限**: hidden field は二重引用符属性なので、少なくとも `"` のエスケープが無いと属性ブレイクアウトが可能。`escapeHtml` は `"` を含むため適用すれば解決する。

Basic OP 認定との関係:

- 認定の直接対象ではない。**セキュリティ / OSS 利用者の安全な既定（secure-by-default）**の論点。本リポジトリは「セキュリティ面と利用者の使いやすさを第一に」を掲げているため優先度は高め。

## 7. 改善・追加を検討する理由

- **secure-by-default**: 生成コードは利用者がそのまま改造して使う「入口」。未エスケープ sink を出荷すると、利用者のカスタマイズが容易に XSS を生む。OSS としての信頼性に直結。
- **一貫性 = 監査容易性**: 「全反映値を必ず `escapeHtml` する」という単純不変条件にすれば、レビュー・自動テストで担保しやすい。現状の「一部だけエスケープ」は監査が難しく、抜けを生みやすい。
- **導入容易性**: 🟢 極小。テンプレートの 3 箇所に `escapeHtml(...)` を適用するだけ。`escapeHtml` は既存。後方互換（ASCII / ランダム値はエスケープ後も同一表現）。
- **実装しない場合のリスク**: login_hint 等の今後のフィールド追加や利用者カスタマイズで XSS が顕在化。認可サーバ origin での XSS は CSRF トークン・セッション・認可コード窃取に直結し被害が大きい。

## 8. 実装方針の候補

### 方針A（全反映値を `escapeHtml` で統一, 推奨筆頭）

- `viewsTemplate()`（generator）で:
  - ログイン: `params.error` → `escapeHtml(params.error)`、`transaction_id` / `csrf_token` の value → `escapeHtml(...)`
  - 同意: `transaction_id` / `csrf_token` の value → `escapeHtml(...)`
- 「テンプレートに渡る文字列は例外なくエスケープ」を関数冒頭コメントで契約化。
- `samples/*` を再生成。

### 方針B（属性値だけ専用エンコーダを足す）

- 要素本文用と属性値用を分け、`escapeHtmlAttr`（`"` `'` を確実に）を追加。
- 過剰になりがち。`escapeHtml` が既に `"`/`'` を含むため方針 A で十分。非推奨寄り。

### 方針C（テンプレートエンジン導入）

- 自動エスケープするテンプレートエンジンへ置換。
- 「外部依存なし / Web 標準のみ」という本リポジトリ方針と相性が悪く、生成コードの簡潔さも損なう。非推奨。

判断材料:

- 方針 A は最小差分かつ既存契約（escapeHtml）に整合。
- `conformance.test.ts` で「`transactionId` に `"><script>` を含めて render → 出力に生 `<script>` が現れない」を回帰固定すれば、将来のカスタマイズ・フィールド追加でも抜けを検知できる（CLAUDE.md の conformance 契約方針に合致）。

## 9. タスク案

- [ ] 方針（A/B/C）を決定（人間が判断、A 推奨）
- [ ] （TDD）`packages/cli` のビュー生成テスト or 各 sample の `conformance.test.ts` に以下を先に追加:
  - `defaultLoginPage` に `transactionId: '"><script>alert(1)</script>'` を渡すと、出力に生の `<script>` が含まれない（`&lt;script&gt;` 等にエスケープ）
  - `defaultLoginPage` に `error: '<img src=x onerror=alert(1)>'` を渡すと同様にエスケープ
  - `defaultConsentPage` の `transactionId` / `csrfToken` も同様
- [ ] `packages/cli/src/frameworks/hono/templates.ts` の `viewsTemplate()` でログイン／同意の `transactionId` / `csrfToken` / `error` を `escapeHtml` 適用に修正
- [ ] `samples/hono` / `samples/express` / `samples/fastify` の `views.ts` を再生成し差分確認
- [ ] `study-material/done/login-hint-ui-prefill.md` / `tasks/p3-login-hint-ui-prefill.md` に「既存 sink も同時にエスケープする」旨を相互参照として追記
- [ ] `study-material/http-security-headers-and-tls.md` の CSP（ヘッダ層）と本タスク（出力エンコーディング層）が二層防御である旨を相互参照
