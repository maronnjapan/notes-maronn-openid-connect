# タスク: 認証コードの TTL 管理実装

## 概要

発行した認可コード（Authorization Code）に有効期限を設け、期限切れのコードで `/token` にアクセスした場合に `invalid_grant` を返す機能を実装する。

現状、生成される `AuthorizationCodeStore` は `used` フラグによるシングルユース制御は行っているが、時間経過による自動無効化（TTL）が実装されていない。OAuth 2.1 では認可コードの有効期間を短命（推奨: 数分以内）にすることが求められる。

## 影響度

**中** — セキュリティ要件。長命な認可コードはリプレイ攻撃のリスクを高める。

## 実装箇所

- `packages/core/src/token-request.ts` — `AuthorizationCodeInfo` に `expiresAt` フィールド追加、有効期限チェック追加
- `packages/cli/src/frameworks/hono/templates.ts` — `AuthorizationCodeStore` の TTL 対応

## 実装内容

### 1. `AuthorizationCodeInfo` に `expiresAt` を追加

`token-request.ts` で定義されている `AuthorizationCodeInfo` を拡張する。

```typescript
export interface AuthorizationCodeInfo {
  clientId: string;
  redirectUri?: string;
  scope: string[];
  subject: string;
  codeChallenge: string;
  codeChallengeMethod: string;
  nonce?: string;
  audience?: string[];
  used: boolean;
  expiresAt: number; // 追加: Unix timestamp (秒)
}
```

### 2. `validateTokenRequest` に有効期限チェックを追加

```typescript
// 認可コードの有効期限チェック
const now = Math.floor(Date.now() / 1000);
if (codeInfo.expiresAt <= now) {
  throw new TokenError(
    TokenErrorCode.InvalidGrant,
    'Authorization code has expired.'
  );
}
```

### 3. `AuthorizationCodeStore` の TTL 対応

生成される `AuthorizationCodeStore` に有効期限チェックを追加する。

```typescript
export class AuthorizationCodeStore {
  private codes = new Map<string, AuthorizationCodeInfo>();

  set(code: string, info: AuthorizationCodeInfo): void {
    this.codes.set(code, info);
  }

  get(code: string): AuthorizationCodeInfo | undefined {
    const entry = this.codes.get(code);
    if (!entry) return undefined;
    // 有効期限チェック
    const now = Math.floor(Date.now() / 1000);
    if (entry.expiresAt <= now) {
      this.codes.delete(code);
      return undefined;
    }
    return entry;
  }
  // ...
}
```

### 4. 認可コード発行時の有効期限設定

同意完了後（consent ルート）に認可コードを発行する際、`expiresAt` を設定する。
デフォルトは5分(300秒)にする。明示的に値が指定されれば、その値を使用する

```typescript
// 推奨: 5分（300秒）
const CODE_EXPIRES_IN = 300;
const expiresAt = Math.floor(Date.now() / 1000) + CODE_EXPIRES_IN;
```

## 受け入れ条件

- [ ] 有効期限内の認可コードはトークンと正常に交換できる
- [ ] 有効期限切れの認可コードで `/token` にアクセスすると `invalid_grant` が返る
- [ ] 使用済みの認可コードで再度アクセスすると `invalid_grant` が返る（既存動作）
- [ ] 認可コード発行時に `expiresAt` が設定される
- [ ] 各ケースに対するユニットテストが追加されている

## 参照仕様

- OAuth 2.1 Section 4.1.2 (Authorization Code — short lifetime requirement)
- OAuth 2.1 Section 4.1.3 (Token Request — code validation)
