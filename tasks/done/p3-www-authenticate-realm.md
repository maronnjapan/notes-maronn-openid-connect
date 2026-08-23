# [P3] UserInfo Endpoint エラーの `WWW-Authenticate` ヘッダーに `realm` を追加する

## ステータス

✅ 完了（2026-07-21）

## 背景

UserInfo Endpoint のエラーレスポンス（401/403）で返す `WWW-Authenticate: Bearer error="..."` に `realm` パラメータが含まれていない。RFC 6750 §3 では `realm` は OPTIONAL だが、多くの RP 実装が Bearer challenge をパースする際に `realm` の存在を前提とするケースがある。Token Endpoint の Basic 認証チャレンジ（`Basic realm="Client Authentication"`）には設定済みであり、UserInfo 側との一貫性が欠ける。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`（`userinfoRouteTemplate` 内の WWW-Authenticate ヘッダー設定箇所）

## 仕様参照

- RFC 6750 §3: The WWW-Authenticate Response Header Field
- RFC 7235 §2.1: WWW-Authenticate Header

## 現状の実装

```ts
// packages/cli/src/frameworks/hono/templates.ts:1207-1209（methodCount > 1 エラー）
c.header('WWW-Authenticate', 'Bearer error="invalid_request"');

// packages/cli/src/frameworks/hono/templates.ts:1207-1210（UserInfoError）
c.header('WWW-Authenticate', `Bearer error="${error.error}", error_description="${error.errorDescription}"`);
```

`realm` パラメータがない。

## 修正方針

- [ ] UserInfo Endpoint のすべての `WWW-Authenticate: Bearer` 付与箇所に `realm="UserInfo"` を追加する

```ts
// 例: no token の場合
c.header('WWW-Authenticate', 'Bearer realm="UserInfo"');

// 例: invalid_token の場合
c.header(
  'WWW-Authenticate',
  `Bearer realm="UserInfo", error="${error.error}", error_description="${error.errorDescription}"`,
);
```

- [ ] アクセストークンが未提供（methodCount === 0）の場合は `error` なしの `realm` のみを返す（RFC 6750 §3.1 に従い token がない場合は error を含めない）

## テスト要件

- [ ] 401 レスポンスの `WWW-Authenticate` に `realm="UserInfo"` が含まれること
- [ ] `invalid_token` エラー時は `realm` + `error` + `error_description` が含まれること
- [ ] アクセストークン未提供時は `realm` のみで `error` が含まれないこと

## 完了条件

`pnpm --filter @maronn-openid-connect/cli test` がパスすること
