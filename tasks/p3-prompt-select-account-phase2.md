# [P3] `prompt=select_account` Phase 2: アカウント選択 UI への誘導

## ステータス

⏸️ Minor / core 前提待ち（2026-07-22 監査済み）

> `packages/core` の変更を伴わずに実装できる状態ではない。現行の `SessionResolver` は
> `resolve(request): Promise<SessionInfo | null>` のみを公開し、生成 OP も単一の
> `session_id` Cookie から1セッションだけを解決する。Phase 2 の実装を開始するには、
> 下記の前提条件を先に core 側で満たす必要がある。

## 背景

`prompt=select_account` の Phase 1（`tasks/done/p1-prompt-select-account.md`）では、既存セッションを破棄して login ページへリダイレクトする最小対応を実装した。
Phase 2 では `sessionResolver` が複数セッションを返せるようになった場合に備え、アカウント選択専用の UI（select_account ページ）へ誘導する経路を template に追加する。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`（`authorizeRouteTemplate`・`loginRouteTemplate`）
- `packages/cli/src/__tests__/hono-generator.test.ts`

## 仕様参照

- OIDC Core 1.0 §3.1.2.1: Authentication Request — `prompt` parameter
  > "The Authorization Server SHOULD prompt the End-User to select a user account."

## 前提条件

以下が整ってから実装に進むこと:
- `sessionResolver` が複数セッションを返す API（例: `resolveAll()` や `resolveMany()`）が `packages/core` に追加されている
- アカウント選択 UI のルート（`/select-account`）を利用者が実装できる仕組みが確認されている

## 前提監査（2026-07-22）

- `packages/core/src/auth-transaction.ts` の `SessionResolver` は単一セッションを返す `resolve()` だけを定義しており、`resolveAll()` / `resolveMany()` 相当は存在しない。
- `packages/cli/src/frameworks/hono/templates.ts` の既定 `BrowserSessionStore` は `session_id` を1件の `BrowserSessionInfo` に対応付け、既定 resolver もその1件だけを返す。
- CLI だけに独自の複数セッション API を追加すると core の公開契約と利用者差し替え用 `sessionResolver` の型から外れるため、対象範囲を守った実装にはならない。
- Phase 1 の再認証フォールバックは実装・テスト済みであり、前提が整うまではその挙動を維持する。

## 修正方針

### authorizeRouteTemplate

- `prompt=select_account` のとき、`sessionResolver.resolveAll(req)` 等で複数セッションを取得する
- セッションが 0 件 → login ページへリダイレクト（Phase 1 と同じ）
- セッションが 1 件以上 → `/select-account?transaction_id=...` へリダイレクト
- リダイレクト先 URL はオプション設定（デフォルト `/select-account`）でカスタマイズ可能にする

### 新規ルート: select_account ページ (テンプレート追加)

- `selectAccountRouteTemplate` を新規作成する
- GET: セッション一覧を表示するページを返す（利用者が views を差し替えられる形）
- POST: 選択されたセッションを `authSessionStore` に保存し、consent ページへ遷移する
- template は利用者責務の UI を差し込めるようにし、組み込み views は最低限のスケルトンとする

## テスト要件

- [ ] `sessionResolver` が複数セッションを返す場合に `/select-account` へリダイレクトすること
- [ ] `sessionResolver` がセッションを返さない場合は login ページへリダイレクトすること
- [ ] `selectAccountRouteTemplate` が生成されること
- [ ] `/select-account` POST でセッションを選択すると consent ページへ遷移すること
- [ ] Phase 1 の挙動（`prompt=login` セッション破棄）が壊れないこと

## 完了条件

`pnpm --filter @maronn-openid-connect/cli test` がパスすること
