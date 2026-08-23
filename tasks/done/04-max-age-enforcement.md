# タスク: `max_age` の強制チェック実装

## 概要

認可リクエストで `max_age` が指定された場合、ユーザーの最終認証時刻（`auth_time`）と比較し、指定秒数を超えていれば再認証を強制する機能を実装する。

現状、`max_age` は `ValidatedAuthorizationRequest` および `AuthTransaction` に保存されるが、ログインフロー中に `auth_time` と比較するロジックが存在しない。

## 影響度

**中** — 認証の新鮮さを保証するために必要。`max_age=0` は常に再認証を強制する用途で使われる。

## 実装箇所

- `packages/core/src/auth-transaction.ts` — `max_age` チェック関数の追加
- `packages/cli/src/frameworks/hono/templates.ts` — `/authorize` または `/login` ルートでの `max_age` チェック呼び出し

## 実装内容

### 1. Core 層: `checkMaxAge` 関数の追加

```typescript
/**
 * max_age チェック
 * auth_time が max_age 秒以内かを検証する
 *
 * @param maxAge 最大認証経過秒数（0 は常に再認証を強制）
 * @param authTime 最終認証時刻（Unix timestamp 秒）
 * @returns 再認証が必要な場合 true
 */
export function requiresReauthentication(maxAge: number, authTime: number): boolean {
  const now = Math.floor(Date.now() / 1000);
  return now - authTime > maxAge;
}
```

### 2. フレームワーク層: `/authorize` ルートの修正

既存セッションがある場合に `max_age` をチェックし、超過していればログイン画面に誘導する。

```
既存セッションあり && max_age 指定あり:
  ├── (now - auth_time) <= max_age → セッション有効、スキップ可
  └── (now - auth_time) > max_age  → 再認証強制（ログイン画面へ）
```

### 3. `max_age=0` の特別処理

`max_age=0` は「今すぐ認証せよ」を意味するため、常にログイン画面を表示する。

### 4. ID Token の `auth_time` クレーム

`max_age` が指定された場合、ID Token には `auth_time` クレームの含有が REQUIRED になる。
`generateTokenResponse` 呼び出し時に `authTime` が渡されることを確認する。

## 受け入れ条件

- [ ] `max_age` 未超過 → 既存セッションを使ってスキップ（ログイン画面なし）
- [ ] `max_age` 超過 → ログイン画面が表示され再認証が求められる
- [ ] `max_age=0` → 常にログイン画面が表示される
- [ ] `max_age` 指定時、発行される ID Token に `auth_time` クレームが含まれる
- [ ] `requiresReauthentication` 関数に対するユニットテストが追加されている

## 参照仕様

- OIDC Core 1.0 Section 3.1.2.1 (Authentication Request — max_age parameter)
- OIDC Core 1.0 Section 2 (auth_time claim in ID Token)
