# [P1] `id_token_hint` を全 prompt 経路で検証し、subject 不一致の SSO 再利用を止める

## ステータス

🟠 High / 未着手

## 背景

生成 OP は `id_token_hint` の検証（署名・`iss`・`aud`・`exp`・`iat`）と subject 突合を、`prompt=none` の分岐の内側でのみ行っている。`prompt` 無し／`prompt=login` 等の対話フローでは `id_token_hint` は `AuthTransaction` に保存されるだけで**一度も参照されない**。

このため次のアカウント取り違えが成立する。

1. ブラウザに User B の OP セッションがある。
2. RP が User A を指す `id_token_hint` を付け、`prompt` を付けずに認可リクエストを送る。
3. SSO 高速経路が `existingSession.subject = B` を採用し、B の同意記録があればそのまま **B の認可コードを発行**する。
4. RP は A のつもりで B のセッションを確立する。エラーも警告も出ない。

加えて、対話フローでは hint の署名検証すら走らないため、壊れた hint・期限切れ hint・別 OP が発行した hint も黙って無視される（「検証されない入力が保存され後続へ流れる」構造が残る）。

OIDC Core §3.1.2.1 の `id_token_hint` の規定は `prompt=none` に限定されていない。詳細な検討・方針比較は `study-material/done/id-token-hint-honored-only-under-prompt-none.md` を参照。

本タスクは方針A（ログイン画面への hint 伝播・対象ユーザー固定）と方針B（不一致は常に `login_required`）の**共通部分だけ**を対象とする。すなわち「全経路で検証する」「不一致なら SSO を再利用しない」までを行い、不一致時に**ログイン画面へ落とす**（`login_required` を即返さない）。ログイン画面での hint 提示・対象ユーザー固定は後続判断とする。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`（`authorizeRouteTemplate` / `loginRouteTemplate`）
  — **単一の修正点**。`web-standard/templates.ts` が `authorizeRouteTemplate` などを再エクスポートし、express / fastify / nextjs はいずれも `webGeneratedFiles` 経由で同じ生成物を使うため、ここを直せば全フレームワークに反映される
- `packages/cli/src/frameworks/web-standard/templates.ts`（`nextJsLoginPageTemplate` / `nextJsLoginActionTemplate` — Next.js のログイン画面だけは別テンプレート）
- `packages/cli/src/__tests__/hono-generator.test.ts` / `web-framework-generators.test.ts` ほか生成コードのテスト
- `packages/cli` 内の `conformance.test.ts` 生成コード（`samples/*/conformance.test.ts` の生成元）
- `tests/e2e`（実ブラウザシナリオ）
- `study-material/basic-op-requirement-traceability.md`（`OP-Req-id_token_hint` の適用範囲注記）

## 仕様参照

- **OpenID Connect Core 1.0 §3.1.2.1 Authentication Request（`id_token_hint`）**
  > ID Token previously issued by the Authorization Server being passed as a hint about the End-User's current or past authenticated session with the Client. **If the End-User identified by the ID Token is logged in or is logged in by the request, then the Authorization Server returns a positive response; otherwise, it SHOULD return an error, such as `login_required`.**
  - この前段は `prompt` の値に条件付けられていない。`prompt=none` は続く文で「hint があることが望ましい」と述べられるだけ。
- **OpenID Connect Core 1.0 §3.1.2.3 Authorization Server Authenticates End-User** — 既存セッションによる SSO の扱い。
- **OpenID Connect Core 1.0 §3.1.2.6 Authentication Error Response** — `login_required`。
- **RFC 8174 / RFC 2119** — SHOULD の解釈（外す場合は相応の理由が要る）。

## 現状の実装

`packages/cli/src/frameworks/hono/templates.ts`

```ts
// 1836 行: prompt=none の分岐
if (promptValues.includes('none')) {
  ...
  // 1854-1881 行: hint の検証はこのブロック内のローカル変数
  let verifiedHintSubject: string | undefined;
  if (transaction.idTokenHint !== undefined) {
    const jwksProvider = c.get('jwksProvider') ...;
    const verified = await validateIdTokenHint(transaction.idTokenHint, {
      expectedIss: issuer, expectedAud: transaction.clientId, jwks,
    });
    verifiedHintSubject = verified.sub;
  }
  ...
  validatePromptNoneIdTokenHint(transaction, session, verifiedHintSubject); // 1895 行
}

// 1959-2020 行: SSO 高速経路 — transaction.idTokenHint を参照しない
if (!promptValues.includes('login') && !promptValues.includes('select_account')) {
  const existingSession = await sessionResolver.resolve(c.req.raw);
  const sessionIsFresh = existingSession !== null &&
    (transaction.maxAge === undefined ||
     !requiresReauthentication(transaction.maxAge, existingSession.authTime));
  if (existingSession && sessionIsFresh) {
    const consentAlreadyGranted = ... hasConsent(existingSession.subject, ...);
    if (consentAlreadyGranted) { /* existingSession.subject で認可コード発行 */ }
    /* 同意画面へ（authSessionStore に existingSession.subject を書き込む） */
  }
}
```

`loginRouteTemplate`（3300 行以降）も `transaction.idTokenHint` を参照しない。

core 側の `validateIdTokenHint`（`packages/core/src/id-token.ts:276-391`）は prompt 非依存の汎用関数なので、**呼び出し位置を変えるだけで再利用できる**。`validatePromptNoneIdTokenHint`（`packages/core/src/auth-transaction.ts:414-427`）は prompt=none 専用のまま残す。

## 修正方針

- [ ] `id_token_hint` の検証ブロック（`jwksProvider` 取得 → `validateIdTokenHint` → `verifiedHintSubject` 代入）を `if (promptValues.includes('none'))` の**前**へ引き上げ、`verifiedHintSubject` を authorize ハンドラのスコープ変数にする
  ```ts
  // OIDC Core 1.0 §3.1.2.1: id_token_hint は prompt に依存せず検証する。
  let verifiedHintSubject: string | undefined;
  if (transaction.idTokenHint !== undefined) {
    const jwksProvider = c.get('jwksProvider') as undefined | (() => Promise<JwkSet> | JwkSet);
    if (!jwksProvider) {
      await transactionStore.delete('auth_txn:' + transactionId);
      return c.redirect(buildErrorRedirect(transaction.redirectUri, 'login_required', transaction.state, 'jwksProvider is not configured; cannot verify id_token_hint', issuer));
    }
    try {
      const jwks = await jwksProvider();
      const verified = await validateIdTokenHint(transaction.idTokenHint, {
        expectedIss: issuer,
        expectedAud: transaction.clientId,
        jwks,
      });
      verifiedHintSubject = verified.sub;
    } catch (hintError) {
      await transactionStore.delete('auth_txn:' + transactionId);
      const code = hintError instanceof IdTokenHintError ? hintError.error : 'login_required';
      return c.redirect(buildErrorRedirect(transaction.redirectUri, code, transaction.state, hintError instanceof Error && hintError.message ? hintError.message : 'id_token_hint verification failed', issuer));
    }
  }
  ```
- [ ] `prompt=none` 分岐からは検証コードを削除し、引き上げた `verifiedHintSubject` を `validatePromptNoneIdTokenHint` にそのまま渡す（**prompt=none の挙動は不変**）
- [ ] SSO 高速経路のセッション採用条件に hint 一致を追加する
  ```ts
  // OIDC Core 1.0 §3.1.2.1: hint が指す End-User でなければ既存セッションを再利用しない。
  const hintMatchesSession =
    verifiedHintSubject === undefined ||
    verifiedHintSubject === existingSession.subject;
  if (existingSession && sessionIsFresh && hintMatchesSession) {
    ...
  }
  ```
- [ ] 不一致時はエラーを返さずログイン画面へ落とす（本タスクの範囲）。`login_required` を即返すか、ログイン画面で対象ユーザーを固定するかは `study-material/done/id-token-hint-honored-only-under-prompt-none.md` の方針A/B 判断に委ねる
- [ ] `hono/templates.ts` の修正が web-standard 経由で express / fastify / nextjs にも反映されることを、生成コードのテストで確認する（Next.js のログイン画面テンプレートのみ別ファイルなので個別に確認する）
- [ ] 生成コードのコメントに「hint は prompt に依存せず検証される」ことを明記する
- [ ] `study-material/basic-op-requirement-traceability.md` の `OP-Req-id_token_hint` の判定に適用範囲（全 prompt 経路）を反映する

## テスト要件

- [ ] hint 無し・既存セッションあり → 従来どおり SSO で認可コードが発行される（リグレッション無し）
- [ ] hint 有り・hint subject == セッション subject → SSO で認可コードが発行され、`sub` が hint の subject と一致する
- [ ] hint 有り・hint subject != セッション subject → 認可コードが**発行されず**、ログイン画面へリダイレクトされる
- [ ] hint 有り・署名不正 → prompt 無しでも `login_required` でリダイレクトされる（従来は無視されていた）
- [ ] hint 有り・`exp` 切れ → prompt 無しでも `login_required` でリダイレクトされる
- [ ] hint 有り・`aud` が別クライアント → prompt 無しでも `login_required` でリダイレクトされる
- [ ] `prompt=none` + hint の成功／不一致／不正の挙動が従来と完全に同一である（`validatePromptNoneIdTokenHint` 経由）
- [ ] `prompt=login` + hint 不一致 → 従来どおりログイン画面へ遷移する（hint による追加拒否が起きない）
- [ ] `jwksProvider` 未設定 + hint 有り → prompt に関係なく `login_required`
- [ ] `samples/*/conformance.test.ts` に「hint 一致 / 不一致 / 不正 hint」の契約テストを追加する（生成元は `packages/cli`）
- [ ] `tests/e2e` に実ブラウザの「セッション User B + hint User A」シナリオを追加し、B の認可コードが返らないことを固定する

## 完了条件

- `pnpm --filter @maronn-openid-connect/core test` がパスすること
- `pnpm --filter @maronn-openid-connect/cli test` がパスすること
- 各 sample の `conformance.test.ts` がパスすること
- `pnpm test` および `tests/e2e` の Playwright テストがパスすること
- 全フレームワークの生成 OP で、対話フローの `id_token_hint` subject 不一致時に SSO 再利用が起きないこと
