# [P2] Authorization Code TTL を CLI テンプレートから設定できるようにする

## ステータス

🟡 Minor / 未着手

## 背景

`createAuthorizationCode()` は `ttlSeconds` オプションを受け付けるが、CLI が生成する authorize/consent ルートでは未指定のため、常に core のデフォルト値（300 秒）が使われる。PoC 開発者が認証コードの有効期間を変えたい場合（短縮してタイムアウト挙動を確認するなど）、テンプレートコードを直接書き換える必要がある。本ライブラリのコンセプト「素早く検証」に反する。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`（`configTemplate` / `authorizeRouteTemplate` / `consentRouteTemplate`）

## 仕様参照

- OIDC Core 1.0 §3.1.3.1: Authorization Code は short-lived であるべき

## 現状の実装

```ts
// authorizeRouteTemplate / consentRouteTemplate の createAuthorizationCode 呼び出し
const authCodeData = await createAuthorizationCode({
  authorizationResponse: { ... },
  subject: session.subject,
  authTime: session.authTime,
  // ttlSeconds が渡されていない → core のデフォルト 300 秒
});
```

`defaultProviderConfig` に `authorizationCodeTtl` が存在しない。

## 修正方針

- [ ] `defaultProviderConfig` に `authorizationCodeTtl: number` を追加する（デフォルト: 300）
- [ ] `authorizeRouteTemplate`（prompt=none ルート）の `createAuthorizationCode` 呼び出しに `ttlSeconds: config.authorizationCodeTtl` を渡す
- [ ] `consentRouteTemplate` の `createAuthorizationCode` 呼び出しにも同様に渡す

## テスト要件

- [ ] `authorizationCodeTtl` を設定した場合、発行される auth code の expiresAt が設定値に従うこと
- [ ] `authorizationCodeTtl` 未設定の場合、デフォルト 300 秒が使われること

## 完了条件

`pnpm --filter @maronn-openid-connect/cli test` がパスすること
