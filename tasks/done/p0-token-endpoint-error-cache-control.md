# [P0] Token Endpoint エラーレスポンスに `Cache-Control: no-store` を付与する

## ステータス

🔴 Critical / 未着手

## 背景

Token Endpoint の成功レスポンス（line 1070）には `Cache-Control: no-store` / `Pragma: no-cache` が設定されているが、catch ブロックのエラーレスポンスには設定されていない。RFC 6749 §5.2 はエラーレスポンスにも同ヘッダーを要求しており、`invalid_client` 等のエラー JSON がキャッシュされる可能性がある。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`（`tokenRouteTemplate` 内の catch ブロック）

## 仕様参照

- RFC 6749 §5.2: Error Response — キャッシュ禁止

## 現状の実装

```ts
// packages/cli/src/frameworks/hono/templates.ts（catch ブロック）
if (error instanceof TokenError) {
  const status = error.statusCode as 400 | 401;
  if (error.wwwAuthenticate) {
    c.header('WWW-Authenticate', error.wwwAuthenticate);
  }
  return c.json(
    { error: error.error, error_description: error.errorDescription },
    status,
  );
}
return c.json({ error: 'server_error' }, 500);
```

`c.json(...)` の前に `Cache-Control` / `Pragma` の設定がない。

## 修正方針

- [ ] `TokenError` catch ブロックで `c.json(...)` の前に両ヘッダーを付与する
- [ ] server_error（500）応答にも同ヘッダーを付与する

```ts
if (error instanceof TokenError) {
  const status = error.statusCode as 400 | 401;
  if (error.wwwAuthenticate) {
    c.header('WWW-Authenticate', error.wwwAuthenticate);
  }
  c.header('Cache-Control', 'no-store');
  c.header('Pragma', 'no-cache');
  return c.json(..., status);
}
c.header('Cache-Control', 'no-store');
c.header('Pragma', 'no-cache');
return c.json({ error: 'server_error' }, 500);
```

## テスト要件

- [ ] `invalid_request` エラーレスポンスに `Cache-Control: no-store` が含まれること
- [ ] `invalid_client` エラーレスポンス（401）に `Cache-Control: no-store` が含まれること
- [ ] server_error（500）レスポンスに `Cache-Control: no-store` が含まれること

## 完了条件

`pnpm --filter @maronn-openid-connect/cli test` がパスすること
