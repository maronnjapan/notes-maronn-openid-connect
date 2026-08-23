# [P0] UserInfo Endpoint レスポンスに `Cache-Control: no-store` を付与する

## ステータス

🔴 Critical / 未着手

## 背景

UserInfo Endpoint はユーザの個人情報（name, email 等）を返すが、レスポンスに `Cache-Control: no-store` が設定されていない。中間プロキシやブラウザキャッシュが PII を保持するリスクがある。Token Endpoint 成功レスポンス（line 1070）では設定済みだが、UserInfo は未対応で一貫性を欠いている。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`（`userinfoRouteTemplate` 内の handler）

## 仕様参照

- RFC 6750 §5.2: Security Considerations — Bearer Token
- OIDC Core 1.0 §16.4: Sensitive Information

## 現状の実装

`userinfoRouteTemplate` の `handler` が `c.json(response)` / `c.body(jwt)` を返すだけで `Cache-Control` ヘッダーを設定していない。

## 修正方針

- [ ] 成功レスポンス（JSON・JWT 双方）の直前に `Cache-Control: no-store` / `Pragma: no-cache` を付与する
- [ ] エラーレスポンス（401 / 403）にも同ヘッダーを付与する

```ts
// 成功時（JSON）
c.header('Cache-Control', 'no-store');
c.header('Pragma', 'no-cache');
return c.json(response);

// 成功時（JWT）
c.header('Cache-Control', 'no-store');
c.header('Pragma', 'no-cache');
c.header('Content-Type', 'application/jwt');
return c.body(jwt);

// エラー時
c.header('Cache-Control', 'no-store');
c.header('Pragma', 'no-cache');
c.header('WWW-Authenticate', ...);
return c.json({ error: ... }, status);
```

## テスト要件

- [ ] 成功レスポンスに `Cache-Control: no-store` が含まれること
- [ ] 成功レスポンスに `Pragma: no-cache` が含まれること
- [ ] エラーレスポンス（401/403）にも同ヘッダーが含まれること

## 完了条件

`pnpm --filter @maronn-openid-connect/cli test` がパスすること
