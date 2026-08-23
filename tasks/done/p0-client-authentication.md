# [P0] クライアント認証ロジックのcore化

## 背景

現状、`client_secret_basic`（HTTP Basic Auth）と `client_secret_post`（リクエストボディ）の
クライアント認証処理が `packages/sample/src/oidc-provider/routes/token.ts` に実装されている。

cliでコード生成した利用者が自前でこのロジックを実装しなければならず、
Basic OP認定においてもmandatoryな要件のため、coreに移動する必要がある。

## 準拠仕様

- OAuth 2.1 Section 2.3 (Client Authentication)
- OIDC Core 1.0 Section 9 (Client Authentication)

## 実装内容

### `packages/core/src/client-auth.ts`（新規）

```ts
// 入力
interface ClientAuthContext {
  params: Record<string, string>;      // リクエストボディのパラメータ
  authorizationHeader: string;         // Authorization ヘッダーの値（なければ空文字）
  clientResolver: TokenClientResolver; // クライアント情報の取得
}

// 出力
// 認証成功時: 認証済みクライアントID（string）を返す
// 認証失敗時: TokenError (invalid_client) をスロー

export async function authenticateClient(context: ClientAuthContext): Promise<string>
```

### 対応する認証方式

1. `client_secret_basic`: `Authorization: Basic base64(clientId:clientSecret)`
2. `client_secret_post`: リクエストボディの `client_id` + `client_secret`

両方が同時に存在した場合はエラー（OAuth 2.1 Section 2.3）。

### エクスポート

`packages/core/src/index.ts` から export する。

## テスト

`packages/core/src/client-auth.test.ts` を先に書く（TDD）。

主なテストケース:
- should authenticate client via client_secret_basic
- should authenticate client via client_secret_post
- should throw invalid_client when credentials are missing
- should throw invalid_client when client is not found
- should throw invalid_client when secret does not match
- should throw invalid_request when both basic and post credentials are provided

## 完了条件

- [ ] テストが全て通る
- [ ] `packages/sample/src/oidc-provider/routes/token.ts` の `parseBasicAuth` / `authenticateClient` をcoreの関数に置き換える
- [ ] core の index.ts からエクスポートされている
