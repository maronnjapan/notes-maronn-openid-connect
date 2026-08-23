# [P1] 認可コード発行ヘルパーの追加

## 背景

認証・コンセント成功後に認可コードを発行する処理が、
サンプルの複数箇所（authorize.ts・consent.ts・login.ts）に直書きされており、
coreにヘルパーがない。

cliでコード生成する際に、正しいフィールド構造を持ったコードデータを
coreから提供できないと、利用者が仕様を読んで自前実装しなければならない。

## 準拠仕様

- OAuth 2.1 Section 4.1.2 (Authorization Response)
- OIDC Core 1.0 Section 3.1.3.1 (Token Request Validation)
  - 認可コードはワンタイムで、有効期限は短くすること (SHOULD be short-lived)

## 実装内容

### `packages/core/src/authorization-code.ts`（新規）

認可コードデータの構造体を作るファクトリ関数を提供する。
ストレージへの保存は利用者責務のため、関数はデータオブジェクトを返すのみ。

```ts
export interface AuthorizationCodeData {
  code: string;
  clientId: string;
  redirectUri: string;
  scope: string[];
  subject: string;
  codeChallenge: string;
  codeChallengeMethod: 'S256';
  used: boolean;
  expiresAt: number;       // Unix timestamp (秒)
  nonce?: string;
  authTime?: number;       // Unix timestamp (秒)
  audience?: string[];
}

export interface CreateAuthorizationCodeOptions {
  authorizationResponse: AuthorizationResponseParams;  // completeAuthTransaction の戻り値
  subject: string;
  authTime: number;
  ttlSeconds?: number;     // デフォルト: 300 (OIDC Core SHOULD be short-lived)
}

export async function createAuthorizationCode(
  options: CreateAuthorizationCodeOptions
): Promise<AuthorizationCodeData>
```

`code` は内部で `generateRandomString(32)` を使って生成する。

### エクスポート

`packages/core/src/index.ts` から export する。

## テスト

`packages/core/src/authorization-code.test.ts` を先に書く（TDD）。

主なテストケース:
- should generate a random code
- should set used to false
- should set expiresAt based on ttlSeconds
- should use default ttlSeconds of 300 when not specified
- should include nonce when provided
- should include authTime
- should include audience when provided

## 完了条件

- [ ] テストが全て通る
- [ ] `AuthorizationCodeData` と `createAuthorizationCode` が core の index.ts からエクスポートされている
- [ ] `packages/sample` の認可コード発行箇所でこの関数を使うように置き換える
