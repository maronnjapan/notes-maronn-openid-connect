# [P3] Auth Transaction の CSRF トークン比較を定数時間化する

## ステータス

🟢 Low / 未着手

## 背景

`validateCsrfToken` はログイン/同意 POST の CSRF トークンを平文 `!==` で比較している。本リポジトリは `client_secret` について「秘密値の比較はタイミング攻撃を防ぐため定数時間で行う」方針を明文化し `timingSafeEqual` を実装・適用済み（`tasks/done/p0-client-secret-timing-safe-comparison.md`）。CSRF トークンは per-transaction のランダムな秘密ベアラ値であり、「秘密値なのに非定数時間比較で残っている最後の 1 箇所」でプロジェクト方針と非対称。短命ランダム値へのタイミング攻撃の実効性は低いため Basic OP 必須ではなく、セキュリティ姿勢の一貫性を目的とするハードニング。

詳細な検討は `study-material/done/csrf-token-constant-time-comparison.md` を参照。

## 対象ファイル

- `packages/core/src/auth-transaction.ts`（`validateCsrfToken`）
- `packages/core/src/crypto-utils.ts`（同期の定数時間比較を新設する場合）
- `packages/core/src/auth-transaction.test.ts`（テスト）
- 各 sample の login/consent ルート（`validateCsrfToken` を `async` 化する場合の波及先）

## 仕様参照

- RFC 9700 (OAuth 2.0 Security BCP) §2.1 CSRF
- 先例: `packages/core/src/crypto-utils.ts`（`timingSafeEqual`）、`packages/core/src/client-auth.ts:194-195`（`client_secret` への適用）

## 現状の実装

```ts
// packages/core/src/auth-transaction.ts（L290-300 付近）
export function validateCsrfToken(transaction: AuthTransaction, csrfToken: string): void {
  if (!csrfToken || csrfToken !== transaction.csrfToken) {   // L294: 非定数時間
    throw new AuthTransactionError(
      AuthTransactionErrorCode.InvalidCsrfToken,
      'Invalid CSRF token.'
    );
  }
}
```

`client-auth.ts:195` は `await timingSafeEqual(...)` を使っており、秘密値比較の作法がモジュール間で不揃い。

## 修正方針

- [ ] まず `validateCsrfToken` の呼び出し箇所（core + 各 sample のルート）を洗い出し、`async` 化の波及範囲を確認する
- [ ] 方針を選ぶ:
  - 方針A（`timingSafeEqual` 流用・`async` 化）: `validateCsrfToken` を `async` にし `await timingSafeEqual(transaction.csrfToken, csrfToken)` を使う。呼び出し側の `await` 対応が必要
  - 方針B（同期の定数時間比較を追加）: 長さに依存しない同期比較を `crypto-utils` に追加し、シグネチャを同期のまま保つ
- [ ] 空値ガード（`!csrfToken`）による早期 return がタイミング漏れを作らないよう実装する
- [ ] `client_secret` と同じ「秘密値は定数時間比較」方針に揃ったことをコメントに明記

## テスト要件

- [ ] 正しい CSRF トークン → 通過（例外なし）
- [ ] 不一致トークン → `InvalidCsrfToken`
- [ ] 空文字列トークン → `InvalidCsrfToken`
- [ ] 長さの異なるトークン → `InvalidCsrfToken`（早期 return による分岐差を作らない）
- [ ] 既存のログイン/同意フローのテストが回帰しないこと

## 完了条件

- `pnpm --filter @maronn-openid-connect/core test` と sample のテストがパスすること
- CSRF トークン比較が定数時間で行われ、`client_secret` と同じ秘密値比較方針に統一されていること
