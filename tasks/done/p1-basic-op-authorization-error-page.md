# [P1] Authorization Endpoint の非リダイレクトエラーをブラウザ向け error page で返す

## ステータス

🟢 High / 既存 `errorPage` view を用いた HTML error page＋content negotiation 実装済み（`ViewResult`/`renderView` 抽象は別タスクへ繰り越し）

## 背景

`tests/conformance` の直近実行で `oidcc-ensure-registered-redirect-uri` が interrupted になっている。

対象結果:

- `tests/conformance/results/oidcc-basic-certification-test-plan-discovery-static_client-5XeV397bGW050-17-Jun-2026.zip`
- module: `oidcc-ensure-registered-redirect-uri`
- request: 登録されていない `redirect_uri` を付けた Authorization Request
- 現状: OP は unregistered `redirect_uri` へ redirect せず HTTP 400 を返している
- 問題: レスポンスは JSON error で、Conformance Suite は「invalid redirect URI error page」の screenshot 提出を待つため WebRunner timeout になる

redirect URI が無効な場合に redirect しない挙動は正しい。一方、ブラウザ経由の Authorization Endpoint では、利用者に表示できる error page を返す必要がある。Basic OP Certification の manual review でも、この画面を screenshot として提出する前提になっている。

## 調査根拠

- OIDC Core 1.0 §3.1.2.2: Authorization Request は OAuth 2.0 parameter validation を行い、エラー時は §3.1.2.6 に従う。
- OAuth 2.0 / OIDC の redirect URI 検証では、未登録 redirect URI へエラー redirect してはいけない。
- OIDF Conformance Suite `OIDCCEnsureRegisteredRedirectUri`: unregistered redirect URI の場合、OP が invalid redirect URI error page を表示し、その screenshot を提出することを期待している。
- 現行実装: `authorize.ts` の `AuthorizationError` catch で `error.redirectUri` が無い場合は `c.json(..., 400)` を返す。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`
- `packages/cli/src/__tests__/hono-generator.test.ts`
- `samples/hono/src/oidc-provider/routes/authorize.ts`
- `samples/express/src/oidc-provider/routes/authorize.ts`
- `samples/fastify/src/oidc-provider/routes/authorize.ts`
- `samples/nextjs/src/app/_oidc-provider/routes/authorize.ts`
- `samples/*/src/oidc-provider/views.ts`
- `samples/nextjs/src/app/_oidc-provider/views.ts`
- 必要に応じて `packages/cli/src/frameworks/web-standard/templates.ts`

`samples/*/src/oidc-provider` は CLI 生成物なので、修正元は必ず `packages/cli` に置く。

## 修正方針

> 実装メモ: 既存 `Views.errorPage(params)` が既に「login/consent と同じ view 差し替え面」を提供しているため、新規 `authorizationErrorPage` を増やさず `errorPage` を再利用した。`ErrorPageParams` に `errorDescription?` を追加し、default view で `error` / `error_description` を HTML エスケープ表示する。`ViewResult` / `renderView` というレンダリング抽象の刷新は、4 framework に跨る大きなリファクタで本タスクの完了条件（ブラウザで確認できる error page）に必須ではないため別タスクへ繰り越す。

- [x] Authorization Endpoint の非リダイレクト `AuthorizationError` を HTML error page として返す。
- [x] 対象は `Unknown client_id`, `redirect_uri not registered`, `redirect_uri must not contain fragment`, `redirect_uri is required when multiple redirect URIs are registered` など、`error.redirectUri` が無いエラー。
- [x] HTTP status は 400 を維持する。
- [x] `Content-Type` は `text/html; charset=utf-8` とする（Hono / web-standard とも `text/html; charset=UTF-8`）。
- [x] 画面には sanitized `error` / `error_description` を表示する（`escapeHtml` で XSS 回避）。
- [x] request の `redirect_uri` にはリンクしない。未登録 URI への誘導を避ける。
- [x] JSON が必要な programmatic caller 向けに挙動を分ける場合は、`Accept: application/json` のときだけ JSON を返すなど明示ルールをテストで固定する。
- [x] authorize route 内の ad-hoc HTML helper にはせず、既存 `Views`（`errorPage`）を使う。Authorization Endpoint も login / consent と同じ view 差し替え面を使う。
- [~] `authorizationErrorPage` 専用 view ではなく既存 `errorPage` を再利用（params は `error`, `errorDescription?`, `statusCode`）。`redirectUri` は view params に渡さない。
- [ ] 既存 `Views` の戻り値を `string` 固定から `ViewResult` に拡張する。→ 別タスクへ繰り越し。
- [ ] route 側を `renderView` helper 経由にする。→ 別タスクへ繰り越し。
- [ ] default `renderView` で `string` / `Response` を扱う。→ 別タスクへ繰り越し。
- [ ] Hono JSX / Express / Fastify の framework-native renderer 対応。→ 別タスクへ繰り越し。
- [x] Next.js は `login/page.tsx` / `consent/page.tsx` を RSC のまま維持し、`/authorize` の非リダイレクトエラーのみ Route Handler の error response（web-standard 共有 route の `c.html`）で返す。JSX を `views.ts` に押し込まない。
- [ ] `p1-basic-op-conformance-manual-review-runner.md` と連携し、manual screenshot 提出手順でこの page を使う。→ runner タスクで対応。

## テスト要件

- [ ] 登録されていない `redirect_uri` 付き `/authorize` が 400 HTML を返すこと。
- [ ] レスポンス本文に `invalid_request` と `redirect_uri not registered` が含まれること。
- [ ] 未登録 `redirect_uri` へ redirect しないこと。
- [ ] `error_description` が HTML エスケープされ、XSS にならないこと。
- [ ] redirectable な authorization error は従来どおり登録済み redirect URI へ `error`, `state`, `iss` を付けて redirect すること。
- [ ] `views.ts` に `authorizationErrorPage` と `ViewResult` / `renderView` の拡張点が生成されること。
- [ ] custom `authorizationErrorPage` が HTML string を返した場合に各 framework でその本文が返ること。
- [ ] custom renderer を使うケースをテンプレートテストで固定し、view の戻り値が string 固定へ戻らないことを検出できること。
- [ ] Next.js 生成物では `login/page.tsx` / `consent/page.tsx` の React Server Component 方針を崩さず、`/authorize` Route Handler の非リダイレクトエラーだけが error response を返すこと。
- [ ] `pnpm --filter @maronn-openid-connect/cli test` がパスすること。
- [ ] `pnpm run conformance:basic-op` で `oidcc-ensure-registered-redirect-uri` が HTTP 400 JSON 由来の timeout ではなく、manual review 可能な error page として扱われること。

## 完了条件

- Authorization Endpoint の非リダイレクトエラーがブラウザで確認可能な error page になる。
- 未登録 redirect URI へ redirect しないセキュリティ要件を維持する。
- `oidcc-ensure-registered-redirect-uri` の screenshot review に使える画面がある。
