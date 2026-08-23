# [P3] 認可トランザクションの TTL 二重ハードコードを解消し、設定可能にする

## ステータス

🟡 Medium / 未着手

## 背景

認可トランザクション（`AuthTransaction`）の寿命が **2 箇所で独立にハードコード**されている。

1. `packages/core/src/auth-transaction.ts:179` — `DEFAULT_TTL_MS = 600_000`
   （`createAuthTransaction` が `transaction.expiresAt` を計算する）
2. 生成コードの `routes/authorize.ts:271` — `10 * 60`
   （`transactionStore.put(key, transaction, ttlSeconds)` に渡すストア側の TTL）

両者は「同じ 10 分」を前提にしているが、型でも設定でも結び付いていない。片方だけ変えると
`expiresAt` とストアの実効寿命が食い違い、**どちらの方向のカスタマイズでも静かに壊れる**。
しかも単位が異なる（ms / 秒）ため取り違えも起きやすい。

さらに、`handleLoginFailure`（`:342-344`）はストアの TTL を **`expiresAt` から再計算した残り時間**で
書き戻す。つまり実質的な真実の情報源は `expiresAt`（core 由来）であり、authorize 時の `10 * 60`
（テンプレート由来）は最初の 1 回だけ効く別系統の値になっている。

加えて、認可コードの TTL は `ProviderConfig.authorizationCodeTtl` として設定可能
（`tasks/done/p2-auth-code-ttl-configurable.md`）なのに対し、認可トランザクションの TTL は設定できず、
**同じ「短命な中間状態の寿命」の扱いが非対称**。PoC で「トランザクション期限切れの挙動を試したい」
利用者は生成コードを直接書き換えるしかなく、本リポジトリのコンセプト（素早く仕様を検証する）と噛み合わない。

検討の詳細・方針比較は
`study-material/done/auth-transaction-ttl-configuration-and-lifecycle.md` を参照（本タスクは実装に絞る）。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`
  - `routes/authorize.ts` テンプレート（`:1823` 付近の `10 * 60`）
  - `config.ts` テンプレート（`ProviderConfig` / `defaultProviderConfig`）
- `packages/cli/src/frameworks/web-standard/templates.ts`（同等箇所）
- `packages/core/src/auth-transaction.ts`（`createAuthTransaction` の `ttlMs` 引数、`DEFAULT_TTL_MS`）
- `packages/core/src/auth-transaction.test.ts`（TDD）
- `packages/cli` の `conformance.test.ts` 生成コード
- `study-material/resolver-and-store-contract.md`（TTL 表への追記）
- 再生成される sample 4 種:
  - `samples/hono-cloudflare/src/oidc-provider/routes/authorize.ts:263-272` / `config.ts`
  - `samples/express-flyio/src/oidc-provider/routes/authorize.ts:268-272` / `config.ts`
  - `samples/fastify-flyio/src/oidc-provider/routes/authorize.ts:268-272` / `config.ts`
  - `samples/nextjs-vercel/src/app/_oidc-provider/routes/authorize.ts:268-272` / `config.ts`

> CLAUDE.md のルールに従い、`samples/*/src/oidc-provider` は直接編集せず `packages/cli` のテンプレートを
> 修正して再生成すること。

## 仕様参照

- **認可トランザクションは仕様上の概念ではない**。OIDC Core 1.0 / OAuth 2.1 は authorize → login →
  consent の中間状態を定義しておらず、**TTL の値そのものを規定する一次仕様は存在しない**。
  本タスクは仕様準拠ではなく、設定可能性と定数の整合性の問題である。
- ただし寿命の上下限には仕様由来の制約がある:
  - 上限側: OIDC Core 1.0 §3.1.3.1 が認可コードに求める "short-lived" の思想、および
    RFC 6749 §4.1.2 の推奨上限 10 分。前段の認可トランザクションにも同じ論法が当てはまり、
    長すぎる TTL は攻撃面（`tasks/p1-auth-transaction-user-agent-binding.md` が扱う横取り）を広げる。
    https://www.rfc-editor.org/rfc/rfc6749#section-4.1.2
  - 下限側: 人間がログイン画面・パスワードマネージャ・MFA を操作する時間を跨ぐ必要があるため、
    **認可コード TTL（既定 300 秒）より短くしてはならない**。
- `max_age` はトランザクション寿命とは別軸（認証の鮮度）。混同して一方から他方を導出しないこと。

## 現状の実装

`packages/core/src/auth-transaction.ts`:

```ts
/** デフォルトのTTL（ミリ秒）: 10分 */
const DEFAULT_TTL_MS = 600_000;                       // L179

export function createAuthTransaction(
  request: ...,
  csrfToken: string,
  ttlMs: number = DEFAULT_TTL_MS                      // L200: 引数で上書きできるが…
): AuthTransaction { ... }
```

`samples/hono-cloudflare/src/oidc-provider/routes/authorize.ts:263-272`:

```ts
const transaction = createAuthTransaction(validatedRequest, csrfToken);   // ttlMs 未指定 → 600_000 ms
const transactionId = await generateRandomString(32);
await transactionStore.put(
  'auth_txn:' + transactionId,
  transaction,
  10 * 60,                                        // 秒。core の 600_000 ms と別 literal
);
```

`handleLoginFailure`（`:342-344`）— 以降は `expiresAt` から導出:

```ts
const remainingTtlMs = transaction.expiresAt - Date.now();
const remainingTtlSeconds = Math.max(1, Math.ceil(remainingTtlMs / 1000));
await store.put(key, transaction, remainingTtlSeconds);
```

## 修正方針

段階的に進める（先に二重管理の解消、次に設定化）。

### ステップ 1: 二重管理の解消（低リスク）

- [ ] テンプレートの `10 * 60` 直書きを除去し、`transaction.expiresAt` から導出する
      （`handleLoginFailure` と同じ導出式にすることで `expiresAt` を唯一の真実にする）

```ts
const transaction = createAuthTransaction(validatedRequest, csrfToken);
// TTL は core が transaction.expiresAt に確定させた寿命から導出する。
// 2 箇所に別々の定数を置くと、片方だけ変えたときに静かにずれるため直書きしない。
const transactionTtlSeconds = Math.max(1, Math.ceil((transaction.expiresAt - Date.now()) / 1000));
await transactionStore.put('auth_txn:' + transactionId, transaction, transactionTtlSeconds);
```

### ステップ 2: 設定化（`authorizationCodeTtl` との対称性）

- [ ] `ProviderConfig` に `authTransactionTtl`（秒、既定 600）を追加する

```ts
/**
 * 認可トランザクション（login / consent 画面を跨ぐ中間状態）の有効期間（秒）。
 * 人間の画面操作を跨ぐため、authorizationCodeTtl（既定 300 秒）より長く設定すること。
 * 長すぎるとトランザクション横取りの攻撃面が広がる（OIDC Core 1.0 §3.1.3.1 の short-lived の思想）。
 * 既定 600 秒（10 分）。
 */
authTransactionTtl: number;
```

- [ ] `routes/authorize.ts` テンプレートで `createAuthTransaction(..., config.authTransactionTtl * 1000)`
      を渡す（core は ms、config は秒。変換箇所にコメントを付ける）
- [ ] `authTransactionTtl < authorizationCodeTtl` の設定を起動時に検証して弾くか、
      コメントでの注意喚起に留めるかを決める
- [ ] `study-material/resolver-and-store-contract.md` の TTL 表に、認可トランザクションの
      「authorize 時の匿名書き込み（認証不要で誰でも発生させられる）」と保持期間の推奨を追記する

## テスト要件

core（`packages/core/src/auth-transaction.test.ts`）:

- [ ] `should set expiresAt from the provided ttlMs instead of the default`
- [ ] `should set expiresAt from the default ttl when no ttlMs is given`
- [ ] `should keep the remaining lifetime when a login failure is recorded`（既存挙動の回帰）

`packages/cli` の conformance.test.ts 生成コード（生成物は直接編集しない）:

- [ ] `should reject a transaction_id that is older than the configured auth transaction ttl`
- [ ] `should derive the transaction store ttl from the same value as expiresAt`
      （authorize 直後の store TTL と `expiresAt` が同一の設定値から導かれていること）

`packages/cli` の generator テスト:

- [ ] 生成された `routes/authorize.ts` に `10 * 60` の直書きが残っていないこと
- [ ] 生成された `config.ts` に `authTransactionTtl` が含まれ、既定値が 600 であること

## 完了条件

- `pnpm --filter @maronn-openid-connect/core test` と `pnpm --filter @maronn-openid-connect/cli test` がパスすること
- 4 sample を再生成し `pnpm test` がパスすること
- 認可トランザクションの寿命が 1 箇所の設定値から決まり、`expiresAt` とストア TTL が常に一致すること
