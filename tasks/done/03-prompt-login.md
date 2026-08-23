# タスク: `prompt=login` の強制再認証実装

## 概要

`prompt=login` が指定された場合、既存セッションが存在していても必ずログイン画面を表示し、ユーザーに再認証を強制する機能を実装する。

現状、`validateAuthorizationRequest` でパラメータの構文チェックは通るが、フレームワーク層の `/login` ルートは既存セッションの有無に関わらず同じ挙動をするため、`prompt=login` の強制再認証が機能していない。

## 影響度

**中** — セキュリティ上重要。機密操作（パスワード変更、決済等）の前に再認証を強制したい RP が利用する。

## 実装箇所

- `packages/cli/src/frameworks/hono/templates.ts` — `/authorize` および `/login` ルートの修正

## 実装内容

### 1. `/authorize` ルートの修正

`prompt=login` の場合、既存のセッションクッキー等を無視（またはクリア）してログイン画面に進む。

```
prompt=login の場合:
  └── 既存セッションを無視し、強制的にログイン画面へリダイレクト
```

### 2. `/login` ルートの修正

Auth Transaction の `prompt` フィールドを参照し、`prompt=login` の場合は既存セッションを使い回さず、新たにログイン成功した認証情報のみを使う。

```typescript
// ログイン成功後
if (transaction.prompt === 'login') {
  // 既存セッションを破棄して新しい auth_time で更新
  authSession.delete(existingSessionKey);
}
authSession.set(txnId, { subject, authTime: Math.floor(Date.now() / 1000) });
```

### 3. `prompt=select_account` との整理

`prompt=select_account` も現状未実装。`prompt=login` と合わせて、prompt の各値に対する挙動を整理してドキュメント化する。

| prompt 値 | 挙動 |
|---|---|
| `none` | セッションあり→自動承認、なし→`login_required` |
| `login` | セッション有無に関わらずログイン画面を強制表示 |
| `consent` | セッションあり→同意画面を強制表示 |
| `select_account` | アカウント選択画面を表示（未実装） |

## 受け入れ条件

- [ ] `prompt=login` で既存セッションがある場合でもログイン画面が表示される
- [ ] `prompt=login` でログイン後は新しい `auth_time` が設定される
- [ ] `prompt` 未指定の場合、既存セッションがあればスキップできる（既存挙動を壊さない）
- [ ] `prompt=consent` で既存セッションがある場合でも同意画面が表示される
- [ ] 各ケースに対するユニットテストが追加されている

## 参照仕様

- OIDC Core 1.0 Section 3.1.2.1 (Authentication Request — prompt parameter)
