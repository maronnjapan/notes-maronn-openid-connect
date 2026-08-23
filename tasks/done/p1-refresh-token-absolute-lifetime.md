# [P1] Refresh Token に absolute lifetime を設ける

## ステータス

🟡 Major / 未着手

## 背景

現状のローテーション実装は新 RT の `expiresAt` を `issuedAt + config.refreshTokenExpiresIn` で毎回リセットする。利用者が継続的にリフレッシュし続ける限り RT は無期限に延び続け、漏洩した RT が長期間 abuse されるリスクがある。OAuth 2.1 §6.1 はセキュリティベストプラクティスとして absolute lifetime（初回発行から絶対的な有効期限）を推奨している。

## 対象ファイル

- `packages/core/src/token-request.ts`（`RefreshTokenInfo` 型）
- `packages/cli/src/frameworks/hono/templates.ts`（refresh token 保存・ローテーション処理）

## 仕様参照

- OAuth 2.1 §6.1: Security of Refresh Tokens — absolute lifetime recommendation

## 現状の実装

```ts
// packages/cli/src/frameworks/hono/templates.ts:1047
expiresAt: issuedAt + config.refreshTokenExpiresIn,
```

ローテーションするたびに有効期限がリセットされる。初回発行日時の情報は RT に保存されていない。

## 修正方針

- [ ] `RefreshTokenInfo` に `originalIssuedAt?: number`（初回発行 Unix epoch 秒）を追加する
  - ローテーション時は元 RT の `originalIssuedAt` を引き継ぐ
  - 初回発行時（authorization_code grant）は `issuedAt` をそのまま設定する
- [ ] `defaultProviderConfig` に `refreshTokenAbsoluteLifetime?: number`（秒）を追加する
  - 設定例: 90 日（7,776,000 秒）
  - 未設定時は後方互換のため既存動作（リセット方式）を維持する
- [ ] template の RT 保存箇所で expiresAt を計算する際に absolute lifetime を適用する

```ts
// 計算例
const slidingExpiry = issuedAt + config.refreshTokenExpiresIn;
const absoluteExpiry = originalIssuedAt + (config.refreshTokenAbsoluteLifetime ?? Infinity);
const expiresAt = Math.min(slidingExpiry, absoluteExpiry);
```

- [ ] ローテーション後の RT 検証（expiresAt チェック）は既存コードのままで対応可能

## テスト要件

- [ ] `refreshTokenAbsoluteLifetime` が設定された場合、RT の expiresAt が absolute lifetime を超えないこと
- [ ] ローテーションで `originalIssuedAt` が初回発行時刻から変わらないこと
- [ ] absolute lifetime を超えた RT は `invalid_grant` になること
- [ ] `refreshTokenAbsoluteLifetime` 未設定時は既存の sliding expiry 動作を維持すること

## 完了条件

`pnpm --filter @maronn-openid-connect/core test` および `pnpm --filter @maronn-openid-connect/cli test` がパスすること
