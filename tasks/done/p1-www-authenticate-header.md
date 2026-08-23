# [P1] WWW-Authenticateヘッダーサポート

## 背景

Token Endpointで `invalid_client`（401）を返す場合、
`WWW-Authenticate` ヘッダーを含めることが必要。

現状、`TokenError` は `statusCode` を返すが、
ヘッダー情報を提供する仕組みがなく、サンプル側でも設定されていない。

## 準拠仕様

- RFC 6750 Section 3 (The WWW-Authenticate Response Header Field)
- OAuth 2.1 Section 5.2 (Error Response)

`invalid_client` で 401 を返す場合のヘッダー例:
```
WWW-Authenticate: Basic realm="Client Authentication"
```

または Bearer トークン認証と合わせる場合:
```
WWW-Authenticate: Bearer error="invalid_client"
```

## 実装内容

### `packages/core/src/token-request.ts` の変更

`TokenError` クラスに `wwwAuthenticate` ゲッターを追加する。

```ts
export class TokenError extends Error {
  // 既存
  public readonly error: TokenErrorCode;
  public readonly errorDescription: string;

  // 追加
  /**
   * 401 レスポンス時に設定すべき WWW-Authenticate ヘッダー値。
   * invalid_client のみ返す（他のエラーは undefined）。
   */
  get wwwAuthenticate(): string | undefined {
    if (this.error === TokenErrorCode.InvalidClient) {
      return 'Basic realm="Client Authentication"';
    }
    return undefined;
  }
}
```

## テスト

`packages/core/src/token-request.test.ts` に追記する（TDD）。

追加するテストケース:
- should return WWW-Authenticate value for invalid_client error
- should return undefined WWW-Authenticate for other errors

## 完了条件

- [ ] テストが全て通る
- [ ] `packages/sample/src/oidc-provider/routes/token.ts` で `invalid_client` 時に `WWW-Authenticate` ヘッダーを設定するよう修正
