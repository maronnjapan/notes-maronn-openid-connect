# [P3] Next.js ログイン画面にも `login_hint` を事前入力する

## ステータス

🟢 Low / 未着手

## 背景

hono と web-standard（express / fastify）のログインページは、認可リクエストの `login_hint` をユーザー名欄へ事前入力する。
Next.js の `nextJsLoginPageTemplate` だけは username の `<input>` に初期値がなく、`transaction.loginHint` は Google ログイン用の属性にしか使われていない。
完了済みタスク `tasks/done/p3-login-hint-ui-prefill.md` が掲げた「4 フレームワークで挙動を統一」から Next.js が取りこぼされている。

詳細は `study-material/done/nextjs-login-hint-prefill-parity.md` を参照。

## 対象ファイル

- `packages/cli/src/frameworks/web-standard/templates.ts`（`nextJsLoginPageTemplate`）
- `packages/cli/src/__tests__/`（Next.js の login_hint 事前入力を固定する generator テスト）
- `samples/nextjs-vercel`（再生成）

## 仕様参照

- OIDC Core 1.0 §3.1.2.1：`login_hint` は OP がログイン UI のヒントとして使ってよい（MAY）

## 現状の実装

- Next.js のログインフォームの username 入力：`<input type="text" id="username" name="username" required />`
- 他フレームワークはトランザクションの `loginHint` を初期値として描画する

## 修正方針

- [ ] `nextJsLoginPageTemplate` の username 入力に `defaultValue={transaction.loginHint ?? ''}` を追加する
- [ ] JSX の属性描画によるエスケープに乗せ、独自の文字列連結を増やさない
- [ ] `samples/nextjs-vercel` を再生成する

## テスト要件

- [ ] `should prefill the username input with login_hint in the nextjs login page`
- [ ] `should render an empty username input when login_hint is absent`

## 完了条件

```bash
pnpm --filter @maronn-openid-connect/cli test
pnpm --filter ./samples/nextjs-vercel check:generated
```

- 追加テストがすべて緑であること
