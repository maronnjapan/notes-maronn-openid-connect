# Next.js ログイン画面だけ `login_hint` を事前入力しない非対称

## ステータス

🟢 Low / タスク化済み（`tasks/p3-nextjs-login-hint-prefill.md`）

## 1. このトピックで確認したいこと

認可リクエストの `login_hint` をログイン画面のユーザー名欄へ事前入力する挙動が、4 フレームワークで揃っているかを確認する。

## 2. 関連する仕様・基準

- OIDC Core 1.0 §3.1.2.1：`login_hint` は OP がログイン UI のヒントとして使ってよい（MAY）。
  セキュリティ要件ではなく、挙動差はユーザー体験とフレームワーク間パリティの問題になる。

## 3. 参照資料

- OIDC Core 1.0 §3.1.2.1
- `tasks/done/p3-login-hint-ui-prefill.md`（「4 フレームワークで挙動を統一する」を目標に掲げた完了済みタスク）

## 4. 現在の実装確認

- hono と web-standard（express / fastify）のログインページは、トランザクションに保存した `loginHint` をユーザー名欄の初期値として描画する。
- Next.js の `nextJsLoginPageTemplate` は、username の `<input>` に `defaultValue` がなく、`transaction.loginHint` は Google ログイン用の属性にしか使われていない。
- 完了済みタスク `p3-login-hint-ui-prefill.md` は統一を掲げているが、Next.js は別テンプレートのため取りこぼしている。

## 5. 現在の実装との差分

- Next.js 生成物だけ `login_hint` が事前入力されず、フレームワーク間で挙動が割れている。
- 完了済みタスクの記述（統一済み）と実態が一致していない。

## 6. 改善・追加を検討する理由

MAY の機能だが、「どのフレームワークでも同じ生成 OP の挙動になる」というパリティは本リポジトリの方針そのものである。
修正は `defaultValue` の 1 属性追加に収まり、導入は容易である。

## 7. 実装方針の候補

`nextJsLoginPageTemplate` の username 入力に `defaultValue={transaction.loginHint ?? ''}` を追加し、他フレームワークと同じ HTML エスケープ経路（JSX の属性描画）に乗せる。

## 8. タスク案

`tasks/p3-nextjs-login-hint-prefill.md` としてタスク化済み。
