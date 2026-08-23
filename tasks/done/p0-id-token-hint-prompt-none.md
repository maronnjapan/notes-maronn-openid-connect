# [P0] id_token_hint を prompt=none で利用する

## 背景

OIDC Core 1.0 Section 3.1.2.1：
> id_token_hint: ID Token previously issued by the OP being passed as a hint about the End-User's current or past authenticated session with the Client. (...) If the End-User identified by the ID Token is logged in or is logged in by the request, then the Authorization Server returns a positive response; otherwise, it SHOULD return an error, such as `login_required`.

Basic OP 認定の `prompt=none` テスト群（`OP-prompt-none-NotLoggedIn` など）で `id_token_hint` が併用されることがあり、無視すると挙動不定で失敗しうる。

## 現状の問題

`packages/core/src/authorization-request.ts` は `id_token_hint` パラメータをパース済み（`ValidatedAuthorizationRequest.idTokenHint`）。
しかし `packages/core/src/auth-transaction.ts` の `checkPromptNone()` はセッションの存在確認しかしておらず、hint と subject の一致確認を行っていない。

別アカウントでログイン中なのに `id_token_hint` が他人を指している場合、本来は `login_required` を返すべきだが、現状は普通に通ってしまう。

## 準拠仕様

- OIDC Core 1.0 Section 3.1.2.1 (Authentication Request - id_token_hint)
- OIDC Core 1.0 Section 3.1.2.6 (Authentication Error Response - login_required)

## 実装方針（責務分離）

Codex との協議結果（2026-04-30）：core 側に ID Token 検証ロジックは混ぜない。「検証済みの hint subject」だけ受け取る API にする。署名・iss・aud・exp の検証は呼び出し側が責任を持つ。

### `packages/core/src/auth-transaction.ts`

`checkPromptNone()` のシグネチャに optional 引数を追加：

```ts
export interface PromptNoneOptions {
  /**
   * id_token_hint を呼び出し側が事前検証して取り出した subject。
   * 渡された場合、解決したセッションの subject と一致しなければ login_required。
   * 未指定なら hint 検証は行わない。
   */
  verifiedHintSubject?: string;
}

export async function checkPromptNone(
  transaction: AuthTransaction,
  sessionResolver: SessionResolver,
  request: Request,
  consentResolver?: ConsentResolver,
  options?: PromptNoneOptions,
): Promise<SessionInfo>
```

実装内に追加：

```ts
if (options?.verifiedHintSubject !== undefined &&
    options.verifiedHintSubject !== session.subject) {
  throw new AuthorizationError(
    AuthorizationErrorCode.LoginRequired,
    'id_token_hint subject does not match the active session',
    transaction.redirectUri,
    transaction.state,
  );
}
```

### `packages/core/src/index.ts`

`PromptNoneOptions` をエクスポート。

### `packages/sample/src/oidc-provider/routes/authorize.ts`

`prompt=none` パスの中で `id_token_hint` が存在する場合、`verifyIdToken()` ヘルパーで JWT を検証してから sub を取り出し、`checkPromptNone` に渡す。

ID Token 検証ヘルパーを `packages/sample/src/oidc-provider/id-token-verify.ts` として新規追加：
- 公開鍵は `c.get('publicJwk')` または `c.get('idTokenPublicJwk')` から取得
- `iss` が自プロバイダの issuer と一致するか
- `aud` が transaction.clientId と一致するか
- `exp` が現在時刻より後か（ただし期限切れ hint は許容する判断もあるので、別 PR で TODO）

検証失敗時は `login_required` で redirect。

### `packages/cli/src/generator.ts`

cli が生成するコードに `id-token-verify.ts` ヘルパーを含める。

## テストケース

`packages/core/src/auth-transaction.test.ts` に追記（TDD）：

`describe('checkPromptNone', () => describe('id_token_hint', () =>`
- `should pass when verifiedHintSubject matches session subject`
- `should throw login_required when verifiedHintSubject differs from session subject`
- `should ignore hint when verifiedHintSubject is undefined`
- `should still throw login_required when no session even if hint is provided`

統合テスト（sample 側）は時間があれば：
- `should redirect with login_required when id_token_hint subject does not match logged-in user`

## 完了条件

- [ ] `checkPromptNone` が hint subject 不一致を検知できる
- [ ] sample 側で id_token_hint の検証 → 渡し が動作する
- [ ] テストが全て通る
- [ ] core が「未検証 hint」を受け取らない API になっている

## 備考

- 期限切れ hint の扱いは仕様上「SHOULD return error」なので保留。今回は exp チェックを実装するが、緩和の議論は別タスクで。
- ID Token 検証コードは将来 RP 実装でも再利用できるよう、純粋関数として分離する。
