# [P2] `id_token_hint` + `prompt=none` の成功・失敗条件を E2E で固定する

## ステータス

✅ 完了（2026-07-21）

## 背景

生成 Provider / samples には既定 `jwksProvider` が配線済みで、OP 自身が発行した ID Token を `id_token_hint` として検証できる。Conformance 実行でも `jwksProvider is not configured` 起因の失敗は解消している。

ただし、実ブラウザの cookie / session を使った `prompt=none + id_token_hint` の成功条件は `tests/e2e` ではまだ固定していない。`id_token_hint` は session の代替認証手段ではないため、成功条件と失敗条件を実 HTTP / 実ブラウザフローで明示する。

## 対象ファイル

- `tests/e2e/specs/*.spec.ts`
- `tests/e2e/apps/client.mjs`
- 必要に応じて `packages/cli/src/frameworks/hono/templates.ts`
- 必要に応じて `samples/*/src/oidc-provider/conformance.test.ts`

E2E で使う OpenID Provider は `samples/*` 配下の CLI 生成アプリを対象にし、E2E 専用クライアントは `tests/e2e/apps` に置く。

## 修正方針

- [ ] 通常の Authorization Code Flow で ID Token を取得する。
- [ ] 同じブラウザセッションを維持したまま `prompt=none` と取得済み `id_token_hint` を付けて再認可し、認可コードが返ることを確認する。
- [ ] ブラウザセッションが無い状態では、有効な `id_token_hint` があっても `prompt=none` が `login_required` になることを確認する。
- [ ] session subject と `id_token_hint` subject が一致しない場合は成功応答にならないことを確認する。
- [ ] `id_token_hint` 検証成功と session 一致を別条件としてテスト名・コメントで明示する。

## テスト要件

- [ ] Playwright E2E で `prompt=none + id_token_hint` の成功フローが通ること。
- [ ] session なしの `prompt=none + id_token_hint` が `login_required` になること。
- [ ] subject 不一致時に認可コードを返さないこと。
- [ ] `pnpm --filter @maronn-openid-connect/e2e test` または既存の E2E 実行コマンドがパスすること。

## 完了条件

実ブラウザフローで、`id_token_hint` が「既存 session の subject 確認」にだけ使われ、session 代替にならないことが固定されていること。
