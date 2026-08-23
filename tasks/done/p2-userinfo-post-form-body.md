# [P2] UserInfo エンドポイントの POST form body 対応

## 背景

RFC 6750 Section 2.2：
> The HTTP request entity-body parameter `access_token` MAY be used to send the access token. (...) The client makes an authenticated request to the resource server using the HTTP "POST" method.

Basic OP 認定の `OP-UserInfo-Body` は **Warning** レベルだが、対応すれば認定スコアが上がる。

## 現状の問題

`packages/sample/src/oidc-provider/routes/userinfo.ts` は GET / POST いずれも `Authorization: Bearer ...` ヘッダーからのみアクセストークンを取り出す。POST の form-encoded body に `access_token=...` が乗っていても無視される。

## 準拠仕様

- RFC 6750 Section 2 (Authenticated Requests)
  - 2.1 Authorization Request Header Field（必須）
  - 2.2 Form-Encoded Body Parameter（任意・サポートすべき場合あり）
  - 2.3 URI Query Parameter（OAuth 2.1 で禁止 — 実装してはならない）

## 実装方針

### `packages/sample/src/oidc-provider/routes/userinfo.ts`

POST ハンドラのみ拡張：

```ts
async function extractAccessToken(c): Promise<string> {
  const authHeader = c.req.header('Authorization') ?? '';
  if (authHeader.startsWith('Bearer ')) {
    return authHeader.slice(7);
  }

  // POST form body fallback (RFC 6750 Section 2.2)
  if (c.req.method === 'POST') {
    const contentType = c.req.header('Content-Type') ?? '';
    if (contentType.includes('application/x-www-form-urlencoded')) {
      const body = await c.req.parseBody();
      const token = body['access_token'];
      if (typeof token === 'string') return token;
    }
  }
  return '';
}
```

GET は body 抽出をスキップ（RFC 6750 Section 2.2 は POST 専用）。

### 重複検知（RFC 6750 Section 2）

> Clients MUST NOT use more than one method to transmit the token in each request.

ヘッダーと body の両方が存在する場合は `invalid_request` を返す。

```ts
if (authHeader.startsWith('Bearer ') && body['access_token']) {
  throw new UserInfoError(
    UserInfoErrorCode.InvalidToken,
    'Multiple access token methods are not allowed',
  );
}
```

### `packages/cli/src/generator.ts`

cli が生成するコードに同じヘルパーを含める。

## テストケース

### `packages/sample/src/__tests__/userinfo-post-body.test.ts`（新規）

- `should accept access_token in POST form body`
- `should accept access_token in Authorization header (existing)`
- `should reject when both header and body provide access tokens`
- `should ignore body for GET requests`
- `should ignore body when Content-Type is not application/x-www-form-urlencoded`

## 完了条件

- [ ] POST form body 経由のトークンが受理される
- [ ] 重複指定が `invalid_request` で拒否される
- [ ] テストが全て通る

## 備考

- Query parameter（URL の `?access_token=`）は OAuth 2.1 で禁止されているので**絶対に対応しない**。
- core 側に汎用ヘルパーを置くかは要検討（RFC 6750 はリソースサーバ全般の話なので、UserInfo 専用に置くのは違和感あり）。今回は sample に閉じる。
