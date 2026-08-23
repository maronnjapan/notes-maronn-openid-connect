# [P1] CLI 生成プロバイダにブラウザセッション（Cookie ベース）を導入し `prompt=none` / `max_age` / SSO を実機能させる

## ステータス

🟠 High / 未着手

## 背景

OIDF Conformance Suite および利用者が実際に動かすのは CLI が生成したプロバイダである。しかし生成コードの「セッション」は `transaction_id` をキーにし、同意完了直後に削除されるため、**ブラウザに紐づく永続的な OP セッションが存在しない**。

その結果:

- SSO（別クライアント／2 回目リクエストの silent 認証）が成立しない
- `prompt=none` が実質常に `login_required`（既定で `sessionResolver` 未設定、かつ Cookie 等のブラウザ識別子がないため「誰のセッションか」を解決できない）
- `max_age` の silent 再認証が機能しない（比較対象の既存セッションが残らない）

`prompt`（none/login/consent/select_account）と `max_age` は Basic OP の必須機能であり、core 側のロジック（`checkPromptNone` / `requiresReauthentication` / `SessionResolver`）は正しい。問題は **生成コードがそれらを実ブラウザセッションに接続していない**点にある。

詳細な分析は `study-material/done/cli-generated-provider-browser-session-and-sso.md` を参照。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`（`AuthSessionStore`、login / consent / authorize ルート、`SessionResolver` 既定実装）
- `packages/sample/src/oidc-provider/store.ts`（生成済みミラーの `AuthSessionStore`）
- `packages/sample/src/oidc-provider/routes/login.ts` / `routes/consent.ts` / `routes/authorize.ts`
- `packages/sample/src/oidc-provider/resolvers.ts`（既定 `SessionResolver` の追加）
- `packages/cli/src/__tests__/hono-generator.test.ts`（生成内容の回帰）
- `packages/sample/src/oidc-provider/**/*.test.ts`（挙動テスト）

## 仕様参照

- OpenID Connect Core 1.0 §3.1.2.1: `prompt=none` は UI を出さず、未認証なら `login_required` / 未同意なら `consent_required`。`max_age` は経過時に再認証を要求（既存 `auth_time` を持つセッションが前提）。
- OpenID Connect Core 1.0 §3.1.2.3: End-User 認証は「session cookie or other mechanism」で維持され、SSO はこの OP セッションの存続で成立する。
- OpenID Connect Core 1.0 §3.1.2.6: `login_required` / `consent_required` / `interaction_required` / `account_selection_required`。
- OIDF Basic OP Certification Profile（Conformance Profiles v3.0）: `prompt` / `max_age` 系テスト。
- Cookie 属性指針: `study-material/http-security-headers-and-tls.md`（`HttpOnly` / `Secure` / `SameSite=Lax`、`Strict` だと認可リダイレクト復帰で Cookie 不送となりフロー破綻）。

## 現状の実装

- `AuthSessionStore` は `Map<transactionId, { subject, authTime }>`（`templates.ts` / `packages/sample/src/oidc-provider/store.ts:157`）。
- login POST で `authSessionStore.set(transactionId, ...)` → consent POST で `authSessionStore.delete(transactionId)`。セッションはトランザクション 1 回限り。
- authorize ルートの `prompt=none` 経路は `sessionResolver = c.get('sessionResolver')`。既定では未設定で、未設定なら `login_required` を返す。
- 生成コード全体で `Set-Cookie` / `HttpOnly` / `SameSite` の使用なし（ブラウザセッション Cookie が存在しない）。

## 修正方針

- [ ] `AuthSessionStore` を `session_id`（Cookie 値）キーへ変更し、`set/get/delete(session_id)` にする
- [ ] login 成功時に CSPRNG で `session_id` を発行し、`Set-Cookie: session_id=...; HttpOnly; Secure; SameSite=Lax; Path=/` を返す（`generateRandomString` を利用）
- [ ] 同意完了時はトランザクションのみ削除し、**セッションは存続**させる（ログアウト or 期限で破棄）
- [ ] Cookie の `session_id` を参照して `{ subject, authTime }` を返す既定 `SessionResolver` をテンプレート／`resolvers.ts` に追加し、authorize ルートへ配線する
- [ ] `prompt=login` / `prompt=select_account` 時は既存セッションを破棄して再認証を強制する既存挙動を維持する
- [ ] 生成済みミラー（`packages/sample/src/oidc-provider/`）を CLI テンプレートと同期して更新する（CLAUDE.md: 生成物は CLI 経由で修正）
- [ ] セッションの有効期限／`auth_time` の保持方法を決め、`max_age` 判定に使えるようにする

## テスト要件

- [ ] ログイン後にセッション Cookie（`HttpOnly` / `Secure` / `SameSite=Lax`）が発行されること
- [ ] 同一ブラウザ（Cookie 付き）の 2 回目認可リクエスト `prompt=none` が `login_required` ではなく silent に認可コードを返すこと
- [ ] 別クライアントの認可リクエストでも同一セッションで SSO が成立すること（再ログイン不要）
- [ ] `max_age` を超えた既存セッションでは `prompt=none` が `login_required`、対話フローでは再認証へ誘導されること
- [ ] Cookie なし（新規ブラウザ）の `prompt=none` は `login_required` を返すこと
- [ ] `prompt=login` / `prompt=select_account` が既存セッションを破棄して再認証を強制すること
- [ ] 同意完了後もセッションが存続し、トランザクションのみ削除されること

## 完了条件

`pnpm --filter @maronn-openid-connect/cli test` および `pnpm --filter @maronn-openid-connect/sample test`（存在する場合）がパスし、上記テスト要件を満たすこと。`pnpm typecheck` が通ること。
