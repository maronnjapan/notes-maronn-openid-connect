# [P2] トークン発行時に有効期間の正当性（`expires_in` 正整数性 / `exp > iat`）を検証する

## ステータス

🟠 High / 未着手

## 背景

トークン発行時、有効期間（`expires_in` / `exp`）が「正の秒数」「`exp > iat`」であることを保証する検証が無い。
設定ミス（`accessTokenExpiresIn = 0` や負値・小数）で、`exp === iat`（実質即時失効）や非整数 `expires_in`、
`exp < iat` のトークンがそのまま発行されうる。`validatePayload`（id-token / access-token）は
「`exp` が過去すぎない（clock skew 内）」ことは見るが、「有効期間が正である」「`exp > iat`」という
内部整合は検証していない。

即時失効トークンを配ると RP/RS 側で全リクエストが失敗し、原因特定が難しい運用障害になる。
OSS の実行利用者が設定値を触る前提のため、発行時に明確なエラーで弾けることが望ましい。
検討詳細は `study-material/done/token-issuance-lifetime-positivity-and-exp-iat-consistency.md` を参照。

> 関連：`study-material/done/token-expiry-boundary-and-opaque-lifetime-binding.md` は失効判定の境界演算子と
> opaque トークンの `expires_in`/`expiresAt` バインドを扱う。本タスクは**有効期間そのものの正当性**に絞る。

## 対象ファイル

- `packages/core/src/token-response.ts`（`generateTokenResponse` 入口の正整数ガード）
- `packages/core/src/id-token.ts`（`validatePayload` に `exp > iat` チェック）
- `packages/core/src/access-token.ts`（`validatePayload` に `exp > iat` チェック）
- 対応する `*.test.ts`

## 仕様参照

- RFC 6749 §5.1: `expires_in` は「秒単位の有効期間」。ゼロ・負・小数は意味を成さない
- RFC 9068 §2.2: JWT Access Token の `iat`/`exp` は整合的（`exp > iat`）である前提
- RFC 7519 §4.1.4 / §4.1.6: `exp` / `iat` は NumericDate
- OpenID Connect Core 1.0 §2: `exp` を過ぎた ID Token は RP に拒否される

## 現状の実装

```ts
// packages/core/src/token-response.ts
const now = Math.floor(Date.now() / 1000);
// exp = now + accessTokenExpiresIn（正当性チェックなし）
// ...
return {
  response: {
    ...
    expires_in: accessTokenExpiresIn, // ← 0/負/小数がそのまま出る
  },
  ...
};

// id-token.ts / access-token.ts の validatePayload:
// exp が数値であること・過去すぎないことは見るが、exp > iat は見ない
```

## 修正方針

- [ ] `generateTokenResponse` の入口で `accessTokenExpiresIn` / `idTokenExpiresIn` が
  **正の整数**であることを検証し、違反時は明確なエラーを throw する
- [ ] `id-token.ts` / `access-token.ts` の `validatePayload` に `exp > iat` チェックを追加する
- [ ] 小数を許容しない（`Number.isInteger` 必須）方針とし、相互運用性を優先する
- [ ] 既存の clock skew 検証（`exp < now - skew`）とは独立した「発行時整合」チェックとして位置づける

## テスト要件

- [ ] `accessTokenExpiresIn = 0` / 負値 / 小数で `generateTokenResponse` がエラーになること
- [ ] `idTokenExpiresIn = 0` / 負値 / 小数でも同様にエラーになること
- [ ] 正の整数では従来どおり成功し、`expires_in` がその値と一致すること
- [ ] `exp <= iat` の payload を `validatePayload`（id-token / access-token）が拒否すること
- [ ] 既存の正常系テストが引き続きパスすること

## 完了条件

- `pnpm --filter @maronn-openid-connect/core test` がパスすること
