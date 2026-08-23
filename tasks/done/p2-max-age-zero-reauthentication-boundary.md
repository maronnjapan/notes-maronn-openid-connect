# [P2] `max_age=0` が同一秒境界で再認証を強制しない `requiresReauthentication` のバグを修正する

## ステータス

🟠 High / 未着手

## 背景

OIDC Core §3.1.2.1 の `max_age=0` は「End-User を必ずアクティブに再認証させる」を意味する。
現在の `requiresReauthentication(maxAge, authTime)` は `now - authTime > maxAge`（strict greater-than）で判定するため、
`maxAge=0` かつ `authTime === now`（ログイン直後、同一の壁時計秒内での認可）では `0 > 0 === false` となり、
**再認証が要求されない**。実装のドキュメントコメントは「0 は常に再認証を強制」と書いており、コードと矛盾している。

`max_age=0` は高保証を求める RP が「今この瞬間の新鮮な認証」を要求する用途で使うため、ここが破れると
RP が要求したフレッシュネス保証を OP が満たさないまま既存セッションを流用しうる。
検討詳細は `study-material/done/max-age-zero-reauthentication-boundary.md` を参照。

## 対象ファイル

- `packages/core/src/auth-transaction.ts`（`requiresReauthentication`）
- `packages/core/src/auth-transaction.test.ts`

## 仕様参照

- OpenID Connect Core 1.0 §3.1.2.1「Authentication Request」（`max_age`）:
  「経過時間が `max_age` を超えたら OP は MUST 再認証」。`max_age=0` は実質「必ず再認証」。
- OpenID Connect Core 1.0 §2（`auth_time` は秒精度の NumericDate）

## 現状の実装

```ts
// packages/core/src/auth-transaction.ts
/**
 * @param maxAge 最大認証経過秒数（0 は常に再認証を強制）  ← コメントは「常に強制」
 */
export function requiresReauthentication(maxAge: number, authTime: number): boolean {
  const now = Math.floor(Date.now() / 1000);
  return now - authTime > maxAge;   // maxAge=0, authTime===now → 0 > 0 === false（再認証されない）
}
```

## 修正方針

- [ ] `maxAge <= 0` のとき常に `true` を返す特別扱いを追加する（`max_age=0` を確実に再認証へ写像。負値も安全側へ）
  ```ts
  export function requiresReauthentication(maxAge: number, authTime: number): boolean {
    if (maxAge <= 0) return true; // OIDC Core §3.1.2.1: max_age=0 は必ず再認証
    const now = Math.floor(Date.now() / 1000);
    return now - authTime > maxAge;
  }
  ```
- [ ] `max_age > 0` の既存挙動（"greater than" 比較）は変更しない
- [ ] ドキュメントコメントと実装の整合を取る

## テスト要件

- [ ] `max_age=0`・`authTime===now` で `true` を返すこと
- [ ] `max_age=0`・`authTime < now` でも `true` を返すこと
- [ ] `max_age=10`・経過 5 秒で `false`、経過 11 秒で `true`（既存挙動の回帰固定）
- [ ] （任意）`tests/e2e` に「`max_age=0` で必ず再認証画面へ遷移する」E2E を CLI 生成 OP に対して追加

## 完了条件

- `pnpm --filter @maronn-openid-connect/core test` がパスすること
