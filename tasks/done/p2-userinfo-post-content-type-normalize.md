# [P2] UserInfo Endpoint POST の Content-Type 判定を正規化する

## ステータス

✅ 完了（2026-07-21）

## 背景

UserInfo Endpoint の POST body から access_token を抽出する際、Content-Type ヘッダーを `includes('application/x-www-form-urlencoded')` で判定している。RFC 7231 §3.1.1.1 では media-type 名は case-insensitive であるため、`Application/x-www-form-urlencoded` のように大文字を含む場合に body token を取り逃がす。Authorization Endpoint POST の判定（`contentType.toLowerCase().split(';')[0].trim()` を使用）と実装が統一されていない。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`（`userinfoRouteTemplate` 内の `extractAccessToken` 関数）

## 仕様参照

- RFC 7231 §3.1.1.1: Media Type — case-insensitive
- RFC 6750 §2.2: Form-Encoded Body Parameter

## 現状の実装

```ts
// packages/cli/src/frameworks/hono/templates.ts:1128-1129
const contentType = c.req.header('Content-Type') ?? '';
if (contentType.includes('application/x-www-form-urlencoded')) {
```

大文字小文字を正規化せずに `includes` で比較している。

## 修正方針

- [ ] Authorization Endpoint POST と同様に `contentType.toLowerCase().split(';')[0].trim()` で正規化してから比較する

```ts
const contentTypeRaw = c.req.header('Content-Type') ?? '';
const mediaType = contentTypeRaw.toLowerCase().split(';')[0].trim();
if (mediaType === 'application/x-www-form-urlencoded') {
```

## テスト要件

- [ ] `Content-Type: application/x-www-form-urlencoded` で POST body から access_token を取得できること
- [ ] `Content-Type: Application/x-www-form-urlencoded` （大文字）でも取得できること
- [ ] `Content-Type: application/x-www-form-urlencoded; charset=utf-8` でも取得できること

## 完了条件

`pnpm --filter @maronn-openid-connect/cli test` がパスすること
