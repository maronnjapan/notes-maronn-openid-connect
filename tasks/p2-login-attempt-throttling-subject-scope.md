# [P2] ログイン失敗回数の上限をアカウント単位にする（トランザクション再作成による回避を塞ぐ）

## ステータス

🟠 High / 未着手

## 背景

`handleLoginFailure`（`packages/core/src/auth-transaction.ts:324-351`）は、ログイン失敗回数を
`AuthTransaction.failedAttempts` に加算し、既定 5 回でトランザクションを削除して打ち切る。
しかし **カウンタは認可トランザクション単位**であり、username / subject / 送信元のいずれとも
紐づいていない。

認可エンドポイントは認証不要で、`client_id` と登録済み `redirect_uri` があれば誰でも叩ける。したがって
攻撃者は「4 回失敗 → 新しい認可リクエストで `transaction_id` を取り直す → また 4 回」を繰り返すだけで、
**同一アカウントへのパスワード総当たりを事実上無制限に実行できる**。上限が上限として機能していない。

より悪いのは、`failedAttempts` / `maxAttempts` / `remainingAttempts`（画面表示）というコードが存在する
ために、**利用者もレビュアーも「試行回数制限は実装されている」と誤認しやすい**ことである。実効性のない
防御が「ある」ことは、防御が「ない」ことより危険。

副次的な問題:

- 上限到達時に `store.delete(key)` でトランザクションごと消すため、正当ユーザーが 5 回打ち間違えると
  **フローが復旧不能になり、クライアントは `redirect_uri` への応答を永久に受け取れない**（429 の HTML で
  行き止まり）
- 429 に `Retry-After` が付かない（RFC 6585 §4）ため、再試行可能時刻を判断できない

なお、失敗メッセージは `Invalid credentials` に統一されており、ユーザー存在の有無で文言が変わらない点は
現状で正しい（ユーザー列挙耐性）。

検討の詳細・仕様根拠・方針比較は
`study-material/done/login-attempt-throttling-scope-and-reset-bypass.md` を参照（本タスクは実装に絞る）。
横断的な攻撃面の棚卸しは `study-material/rate-limiting-and-brute-force.md`。

## 対象ファイル

- `packages/core/src/auth-transaction.ts`
  - `handleLoginFailure`（`:324-351`）
  - `DEFAULT_MAX_ATTEMPTS`（`:182`）
  - 新規 `LoginAttemptResolver` インターフェース
- `packages/core/src/auth-transaction.test.ts`（TDD）
- `packages/cli/src/frameworks/hono/templates.ts`（login ハンドラ `:3333` 付近、`store.ts` テンプレート）
- `packages/cli/src/frameworks/web-standard/templates.ts`（login ハンドラ `:1358` 付近、同上）
- `packages/cli/src/frameworks/web-standard/templates.ts` の Next.js Server Action 版
  （login action `:1315` 付近。生成物: `src/app/login/actions.ts`）
- `packages/cli` の `conformance.test.ts` 生成コード
- `tests/e2e`
- `study-material/rate-limiting-and-brute-force.md`（§4 の記述訂正）
- 再生成される sample 4 種の `routes/login.ts` / `store.ts`

> CLAUDE.md のルールに従い、`samples/*/src/oidc-provider` は直接編集せず `packages/cli` のテンプレートを
> 修正して再生成すること。

## 仕様参照

- **NIST SP 800-63B §5.2.2 Rate Limiting (Throttling)**: verifier は
  **単一アカウント（single account）に対する連続した認証失敗の回数**を制限しなければならない。
  本質は「制限の単位がアカウント（および／または送信元）であること」と
  「攻撃者がカウンタをリセットできないこと」。
  https://pages.nist.gov/800-63-3/sp800-63b.html#throttle
  - 具体的な閾値（例: 100 回 / 30 日）は AAL と追加緩和策の有無で変わるため、
    **本リポジトリのポリシーとして別途決める**。
- **RFC 6585 §4 429 Too Many Requests**: レート制限到達時のステータス。`Retry-After` を含めてよい（MAY）。
  https://www.rfc-editor.org/rfc/rfc6585#section-4
- **本件は OIDC 仕様違反ではない**: エンドユーザー認証（ログイン画面）のレート制限は OAuth/OIDC の
  仕様範囲外であり、OIDC Core は認証方式を規定しない。OP を名乗る以上必要な**認証基盤側の要件**として
  扱うのが正確。Basic OP 認定テストにも該当 module は無く、認定可否には影響しない。
- 参考: RFC 9700（OAuth 2.0 Security BCP）/ RFC 6819（OAuth 2.0 Threat Model）

## 現状の実装

`packages/core/src/auth-transaction.ts`:

```ts
const DEFAULT_MAX_ATTEMPTS = 5;                                  // L182

export async function handleLoginFailure(
  txnId: string,
  transaction: AuthTransaction,
  store: AuthTransactionStore,
  maxAttempts: number = DEFAULT_MAX_ATTEMPTS
): Promise<LoginFailureResult> {
  const key = `${STORE_KEY_PREFIX}${txnId}`;
  transaction.failedAttempts++;                                  // L331: トランザクション上のカウンタ

  if (transaction.failedAttempts >= maxAttempts) {
    await store.delete(key);                                     // L334: トランザクションごと削除
    return { canRetry: false, failedAttempts: ..., maxAttempts };
  }

  const remainingTtlMs = transaction.expiresAt - Date.now();
  const remainingTtlSeconds = Math.max(1, Math.ceil(remainingTtlMs / 1000));
  await store.put(key, transaction, remainingTtlSeconds);        // L344
  return { canRetry: true, failedAttempts: ..., maxAttempts };
}
```

`samples/hono-cloudflare/src/oidc-provider/routes/login.ts:64-82`:

```ts
const user = await authenticateUser(username, password);
if (!user) {
  const failureResult = await handleLoginFailure(transactionId, transaction, transactionStore);
  if (!failureResult.canRetry) {
    return renderView(views.errorPage({
      error: 'Too many login attempts',
      statusCode: 429,
    }), { status: 429 });          // Retry-After なし
  }
  return renderView(views.loginPage({ ..., error: 'Invalid credentials', ... }));
}
```

`AuthTransaction.failedAttempts`（`:130`）は username / subject / IP のいずれとも紐づかない。

## 修正方針

2 段構えで進める（先に可用性と `Retry-After`、次にカウンタの単位）。

### ステップ 1: 上限到達時の挙動と `Retry-After`（低リスク・先行）

- [ ] 上限到達時にトランザクションを物理削除する挙動を見直す
  - 案 a: トランザクションは残し `lockedUntil` を書いてロック状態として扱う
  - 案 b: `redirect_uri` へ `access_denied`（+ `state` + `iss`）で戻し、クライアントにフロー終了を伝える
  - どちらを採るか決める（`redirect_uri` へ戻す場合、`error_description` で理由を伝えられる）
- [ ] 429 応答に `Retry-After` を付与する（テンプレート側）

### ステップ 2: カウンタの単位を正す（本命）

- [ ] core に resolver を追加し、カウンタの保存先と単位を利用者へ委ねる

```ts
// packages/core/src/auth-transaction.ts
/**
 * ログイン失敗カウンタの保存先を抽象化する resolver。
 *
 * NIST SP 800-63B §5.2.2: 連続した認証失敗の制限は「単一アカウント」単位で課す。
 * 認可トランザクション単位のカウンタは、攻撃者が認可エンドポイントを叩き直すだけで
 * リセットできるため、スロットリングとして機能しない。
 *
 * identifier には正規化済みの username（必要なら送信元との複合キー）を渡す。
 */
export interface LoginAttemptResolver {
  getFailedAttempts(identifier: string): Promise<number>;
  recordFailure(identifier: string): Promise<number>;
  clearFailures(identifier: string): Promise<void>;
  /** 任意: ロック解除までの秒数（Retry-After に使う） */
  getRetryAfterSeconds?(identifier: string): Promise<number | undefined>;
}
```

- [ ] `handleLoginFailure` を optional 引数で resolver を受け取る形に拡張する。
      **未指定なら従来のトランザクション単位（後方互換）**とし、その場合は
      「このカウンタは総当たり対策として不十分である」旨を JSDoc に明記する
- [ ] `packages/cli` の `store.ts` テンプレートに `LoginAttemptStore` の既定実装を追加し、
      `resolvers.ts` テンプレートで `LoginAttemptResolver` として配線する
- [ ] `login.ts` テンプレートで
  - [ ] 失敗時に `recordFailure(normalizedUsername)` を呼ぶ
  - [ ] **認証成功時に `clearFailures(normalizedUsername)` を呼ぶ**（これが無いと正当ユーザーが
        いずれロックされる）
  - [ ] 上限判定を resolver の値で行い、`Retry-After` を `getRetryAfterSeconds` から導出する
- [ ] username の正規化規則（trim / 小文字化 / Unicode 正規化）を 1 箇所に定義し、
      カウンタキーと認証で同じ規則を使う（別々だとカウンタを迂回できる）
- [ ] 閾値ポリシー（何回 / どの単位 / どれだけロック）を config で設定可能にするか決める
- [ ] `study-material/rate-limiting-and-brute-force.md` §4 の
      「失敗試行のカウント / レート制限 / アカウントロックは実装されていない」という記述を、
      `handleLoginFailure` の実装状況に合わせて訂正し、本タスクへの参照を張る

## テスト要件

core（`packages/core/src/auth-transaction.test.ts`）:

- [ ] `should keep counting failures across different transactions for the same identifier`
- [ ] `should reject authentication once the identifier reaches maxAttempts`
- [ ] `should clear the failure counter after a successful authentication`
- [ ] `should fall back to per-transaction counting when no LoginAttemptResolver is provided`
- [ ] `should keep the remaining transaction lifetime when a login failure is recorded`（既存挙動の回帰）
- [ ] `should not delete the transaction when the attempt limit is reached`（ステップ 1 案 a を採る場合）

`packages/cli` の conformance.test.ts 生成コード:

- [ ] `should keep the failed attempt count for the same username across a new authorization transaction`
- [ ] `should respond with 429 and a Retry-After header once the attempt limit is reached`
- [ ] `should return the same error message for an unknown user and a wrong password`（ユーザー列挙耐性の回帰）
- [ ] `should reset the failed attempt count after a successful login`

`tests/e2e`:

- [ ] 5 回失敗後に新しい認可リクエストを開始しても、即座に再試行できないこと
- [ ] 正常なログイン→同意→コード受領の E2E が回帰しないこと

## 完了条件

- `pnpm --filter @maronn-openid-connect/core test` と `pnpm --filter @maronn-openid-connect/cli test` がパスすること
- 4 sample を再生成し `pnpm test` と `tests/e2e` がパスすること
- 生成 OP で、認可トランザクションを作り直しても同一アカウントの失敗回数が引き継がれること
- `study-material/rate-limiting-and-brute-force.md` §4 の記述が実装と一致していること
