# タスク: `prompt=none` の挙動実装

## 概要

`prompt=none` が指定された認可リクエストに対して、ユーザーインタラクションなしにサイレント認証を行う機能を実装する。

現状、`validateAuthorizationRequest` でパラメータの構文チェックは通るが、フレームワーク層（Hono テンプレート）には「既存セッションがあれば自動承認 / なければ `login_required` を返す」という動作が実装されていない。`prompt=none` を受け取っても通常のログイン画面にリダイレクトしてしまう。

## 影響度

**高** — SSO・バックグラウンドでのトークン更新（サイレント認証）に必須。

## 実装箇所

- `packages/core/src/auth-transaction.ts` — `prompt=none` の検査ロジック追加
- `packages/cli/src/frameworks/hono/templates.ts` — `/authorize` ルートの `prompt=none` ハンドリング追加

## 実装内容

### 1. Core 層: `checkPromptNone` 関数の追加

既存セッションの有無に基づき `prompt=none` を処理するインターフェースを定義する。

```typescript
export interface SessionInfo {
  subject: string;
  authTime: number;
}

export interface SessionResolver {
  resolve(request: Request): Promise<SessionInfo | null>;
}

/**
 * prompt=none 時のセッション確認
 * - セッションなし → login_required エラーをスロー
 * - セッションあり → セッション情報を返却（後続フローへ）
 */
export async function checkPromptNone(
  transaction: AuthTransaction,
  sessionResolver: SessionResolver
): Promise<SessionInfo>
```

### 2. フレームワーク層: `/authorize` ルートの修正

`GET /authorize` 受信後、`prompt` が `none` の場合は以下の分岐を実装する。

```
prompt=none の場合:
  ├── 既存セッションあり → ログイン・同意画面をスキップして認可コードを発行し redirect
  └── 既存セッションなし → error=login_required で redirect_uri にリダイレクト
```

### 3. エラーレスポンス

`prompt=none` でセッションがない場合のエラーレスポンスは `redirect_uri` へのリダイレクトで返す。

```
HTTP 302
Location: {redirect_uri}?error=login_required&state={state}
```

`consent_required` エラー（セッションはあるが同意が必要な場合）も考慮する。

## 受け入れ条件

- [ ] `prompt=none` + 有効セッションあり → 認可コードが発行されリダイレクトされる
- [ ] `prompt=none` + セッションなし → `login_required` エラーで `redirect_uri` にリダイレクトされる
- [ ] `prompt=none` + セッションはあるが未同意スコープあり → `consent_required` エラーで `redirect_uri` にリダイレクトされる
- [ ] `prompt=none` でもログイン画面・同意画面が表示されない
- [ ] 各ケースに対するユニットテストが追加されている

## 参照仕様

- OIDC Core 1.0 Section 3.1.2.1 (Authentication Request — prompt parameter)
- OIDC Core 1.0 Section 3.1.2.6 (Authentication Error Response)
