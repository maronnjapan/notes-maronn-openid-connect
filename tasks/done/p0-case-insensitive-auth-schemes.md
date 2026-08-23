# [P0] `Basic` / `Bearer` 認証スキームの大文字小文字非依存化

## ステータス

🟡 Critical / 未着手

## 背景

HTTP の認証スキーム名は case-insensitive である。したがって `basic ...`、`BASIC ...`、`bearer ...` のような表記も、スキームとしては `Basic` / `Bearer` と同等に扱う必要がある。

現状実装は `startsWith('Basic ')` と `startsWith('Bearer ')` で判定しており、スキームの大文字小文字が違うだけで認証に失敗する。

## 対象ファイル

- `packages/core/src/client-auth.ts`
- `packages/core/src/client-auth.test.ts`
- `packages/cli/src/frameworks/hono/templates.ts`
- `packages/cli/src/__tests__/hono-generator.test.ts`

## 仕様参照

- RFC 7235 §2.1: HTTP authentication scheme は case-insensitive
- RFC 7617 §2: Basic Authentication Scheme
- RFC 6750 §2.1: Bearer Token Usage

## 現状の実装

- `parseBasicAuth()` が `authHeader.startsWith('Basic ')`
- `authenticateClient()` が `authorizationHeader.startsWith('Basic ')`
- UserInfo route の `extractAccessToken()` が `authHeader.startsWith('Bearer ')`

このため、ヘッダー値が `basic ...` や `bearer ...` の場合に本来受理すべきリクエストを拒否する。

## 修正方針

- [ ] スキーム部のみを ASCII 小文字化して比較する
- [ ] 認証情報本体の base64 token / bearer token 値は大小変換しない
- [ ] `Basic` と `Bearer` の両方で同じ比較方針を適用する
- [ ] 既存の「非 Basic Authorization header は無視して body credential にフォールバック」挙動を壊さない

## テスト要件

- [ ] `basic ...` / `BASIC ...` でも client authentication が通ること
- [ ] `bearer ...` / `BEARER ...` でも UserInfo access token 抽出が通ること
- [ ] token 値そのものの大文字小文字は保持されること
- [ ] 未知のスキームは引き続き非対応であること

## 完了条件

`pnpm --filter @maronn-openid-connect/core test` および `pnpm --filter @maronn-openid-connect/cli test` がパスすること
