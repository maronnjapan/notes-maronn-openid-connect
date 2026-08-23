# [P3] JWT 入力パースの厳格化と ID Token 発行時クレーム型検証（検証側との非対称解消）

## ステータス

🟡 Medium / 未着手

## 背景

ID Token / JWT 周りで、検証経路（`validateIdTokenHint`）は厳格なのに、発行経路と低レベルデコードが緩い、
という非対称がある。RFC 8725（JWT BCP）の strict parsing 観点で、発行・パースの厳格化が望ましい。

1. base64url デコード（`base64UrlToArrayBuffer`）が `atob` 依存で、非 base64url 文字・非正規入力を黙って受理。
2. `validateIssuer` が不正 `iss` で生の `TypeError: Invalid URL` を投げ、ライブラリの明確なエラーにならない。
3. `validatePayload`（発行時）が `exp`/`iat` の型や `aud` 空文字要素を検査せず、構造不正な ID Token を発行しうる。
   検証側 `validateIdTokenHint` は `typeof === 'number'` を課しているのに発行側は緩い。

検討の詳細は `study-material/done/jwt-input-parsing-strictness.md` を参照。

## 対象ファイル

- `packages/core/src/crypto-utils.ts`（`base64UrlToArrayBuffer` L147-165）
- `packages/core/src/crypto-utils.test.ts`
- `packages/core/src/id-token.ts`（`validateIssuer` L43-60、`validatePayload` L79-133、`validateIdTokenHint` の型検査 L307/L319 付近）
- `packages/core/src/id-token.test.ts`

## 仕様参照

- RFC 8725 §3.11（strict parsing）: https://www.rfc-editor.org/rfc/rfc8725#section-3.11
- RFC 7515 §2 / Appendix C（base64url は無パディング・正規）: https://www.rfc-editor.org/rfc/rfc7515
- RFC 7519 §2, §4.1（NumericDate / StringOrURI / 登録クレーム）: https://www.rfc-editor.org/rfc/rfc7519
- OpenID Connect Core 1.0 §2（ID Token のクレーム型）: https://openid.net/specs/openid-connect-core-1_0.html#IDToken

## 現状の実装

- `base64UrlToArrayBuffer`（`crypto-utils.ts:147-165`）: 入力文字種・長さの検証なし。`atob` は空白等を無視し非正規入力を受理しうる。
  `byte === undefined` 分岐は `charCodeAt` の仕様上到達しない実質デッドコード。
- `validateIssuer`（`id-token.ts:44`）: `const url = new URL(iss);` が不正 `iss` で生の `TypeError` を送出。
- `validatePayload`（`id-token.ts:79-133`）: `exp` は `undefined`/`null` と `< now-leeway` のみ、`iat` は存在のみ、
  `aud` は配列長 0 のみ拒否（空文字要素は通る）。型チェック無し。
- 対比: `validateIdTokenHint` は `typeof exp === 'number'` / `typeof iat === 'number'` を課す（`id-token.ts:307, 319` 付近）。

## 修正方針

- [ ] base64url の strict デコード（`[A-Za-z0-9_-]` 以外、`len % 4 === 1` を拒否）を追加し、
      `validateIdTokenHint` のヘッダ/ペイロードデコード経路に適用する。実質デッドコードの `byte === undefined` 分岐は削除。
- [ ] `validateIssuer` の `new URL(iss)` を try-catch し `Error('Issuer must be a valid URL')` に正規化する。
- [ ] `validatePayload` に `typeof exp === 'number'` / `typeof iat === 'number'` の必須化と、
      `aud` 配列の空文字・非文字列要素の拒否を追加し、`validateIdTokenHint` の厳格チェックと整合させる。

## テスト要件

- [ ] base64url: 非 base64url 文字（`+` `/` `=` 空白）を含む入力でデコードが**拒否**されること。
- [ ] base64url: 不正長（`len % 4 === 1`）の入力が**拒否**されること。
- [ ] `validateIssuer`: `iss = "not a url"` で `Error('Issuer must be a valid URL')`（具体メッセージ）が投げられること。
- [ ] `validatePayload`: `exp` / `iat` が非 number（例 `"abc"`）のとき発行が**拒否**されること。
- [ ] `validatePayload`: `aud` に空文字要素を含む配列（例 `['clientA', '']`）が**拒否**されること。
- [ ] 発行側と検証側で時刻クレームの型チェックが一致していること。

## 完了条件

- `pnpm --filter @maronn-openid-connect/core test` がパスすること
