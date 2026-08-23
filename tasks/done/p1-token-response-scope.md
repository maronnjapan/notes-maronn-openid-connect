# [P1] TokenResponseへのscope追加

## 背景

`generateTokenResponse()` の戻り値 `TokenResponse` に `scope` フィールドが含まれていない。

OAuth 2.1 Section 3.2.3 では、発行されたスコープがリクエストと異なる場合に
`scope` をレスポンスに含めることをMUST としている。
また、conformanceテストがscopeフィールドを確認するケースがある。

## 準拠仕様

- OAuth 2.1 Section 3.2.3 (Token Response)
  > If the scope of the access token is identical to the scope requested by the client,
  > this parameter is OPTIONAL; otherwise, this parameter is REQUIRED.

## 実装内容

### `packages/core/src/token-response.ts` の変更

```ts
// 変更前
export interface TokenResponse {
  access_token: string;
  token_type: 'Bearer';
  expires_in: number;
  id_token: string;
  scope?: string;
  refresh_token?: string;
}

// 変更後: scope を常に含める
export interface TokenResponse {
  access_token: string;
  token_type: 'Bearer';
  expires_in: number;
  id_token: string;
  scope: string;            // optional → required（常に含める）
  refresh_token?: string;
}
```

`generateTokenResponse()` の実装で `scope: scope.join(' ')` を常にセットする。

## テスト

`packages/core/src/token-response.test.ts` に追記する（TDD）。

追加するテストケース:
- should include scope in the token response
- should include scope as space-delimited string

## 完了条件

- [ ] テストが全て通る
- [ ] `TokenResponse.scope` が `string`（常に存在）になっている
- [ ] サンプルのtoken endpoint側でcompile errorがないことを確認
