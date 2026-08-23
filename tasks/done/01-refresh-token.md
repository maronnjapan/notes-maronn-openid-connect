# タスク: Refresh Token の実装

## 概要

`grant_type=refresh_token` に対応する Refresh Token の発行・検証・ローテーション機能を実装する。

現状、`validateTokenRequest` は `authorization_code` グラントのみ対応しており、`TokenResponse` にも `refresh_token` フィールドが存在しない。アクセストークンの有効期限が切れると再認証が必要になる。

## 影響度

**高** — 多くの RP がアクセストークン更新のために Refresh Token を要求する。

## 実装箇所

- `packages/core/src/token-request.ts` — `grant_type=refresh_token` のバリデーション追加
- `packages/core/src/token-response.ts` — `refresh_token` フィールドをレスポンスに追加
- `packages/core/src/index.ts` — 新たに追加した型・関数のエクスポート

## 実装内容

### 1. `TokenResponse` に `refresh_token` を追加

```typescript
export interface TokenResponse {
  access_token: string;
  token_type: 'Bearer';
  expires_in: number;
  id_token: string;
  scope?: string;
  refresh_token?: string; // 追加
}
```

### 2. `TokenResponseOptions` に Refresh Token オプションを追加

```typescript
export interface TokenResponseOptions {
  // ...既存フィールド
  issueRefreshToken?: boolean;
  refreshTokenExpiresIn?: number;
}
```

### 3. `validateTokenRequest` に `refresh_token` グラントを追加

- `grant_type=refresh_token` を受け付ける
- `refresh_token` パラメータの存在チェック
- Refresh Token の有効性・有効期限・クライアント一致チェック
- OAuth 2.1 Section 4.3 に従いトークンローテーション（使用済みトークンを無効化し新規発行）

### 4. `RefreshTokenInfo` インターフェース定義

```typescript
export interface RefreshTokenInfo {
  subject: string;
  clientId: string;
  scope: string[];
  expiresAt: number;
  used: boolean;
}

export interface RefreshTokenResolver {
  resolve(token: string): Promise<RefreshTokenInfo | null>;
}
```

## 受け入れ条件

- [ ] `authorization_code` グラント成功時に `refresh_token` が発行される
- [ ] `grant_type=refresh_token` で新しい `access_token` と `id_token` が返却される
- [ ] 使用済みの Refresh Token で再度リクエストすると `invalid_grant` エラーになる（ローテーション）
- [ ] 有効期限切れの Refresh Token で `invalid_grant` エラーになる
- [ ] クライアント不一致の Refresh Token で `invalid_grant` エラーになる
- [ ] 各ケースに対するユニットテストが追加されている

## 参照仕様

- OAuth 2.1 Section 4.3 (Refresh Token Grant)
- OAuth 2.1 Section 4.3.1 (Refresh Token Rotation)
