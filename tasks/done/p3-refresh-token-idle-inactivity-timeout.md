# [P3] Refresh Token のアイドル（無操作）タイムアウトを任意・オプトインで提供する

## ステータス

🟢 Low / 完了（PR #127 レビューで仕様参照を訂正）

> **訂正（PR #127 レビュー反映）**: 当初「RFC 9700 §4.14.2 が absolute / inactivity の二軸を明示している」と記載していたが、これは不正確。§4.14.2 は refresh token 保護として rotation・sender-constraining・限定的な有効期限による露出時間の短縮を推奨しているものの、「一定期間未使用なら失効」という inactivity/idle timeout そのものを規定する文言は無い。idle timeout は Auth0 の "inactivity lifetime" 等 IdP で一般的な運用機構であり、本機能は RFC の「露出を抑える」方針を具体化する追加オプションとして位置づける（RFC が命じる要件ではない）。コード側コメントも同旨に修正済み。

## 背景

現在の Refresh Token（RT）は **絶対有効期限のみ**で失効する（`originalIssuedAt + 絶対有効期限`）。
RFC 9700 §4.14.2 は RT 保護の手段として「最大寿命（absolute）」と「最後の利用からの非活動期間（inactivity）」の**二軸**を挙げているが、本リポジトリは inactivity 側を意図的に未提供としている（`packages/cli/src/frameworks/hono/templates.ts` 133 行付近のコメント「sliding expiry を持たず…」）。

その結果、**絶対期限内だが長期間放置された RT** は、放置後（漏洩していれば）一度は使えてしまい、露出窓が絶対期限まで残る。利用者が「絶対90日／14日無操作で失効」のような inactivity ポリシーを検証する手段が無い。

本タスクは、**既定 OFF・後方互換**なオプトイン機能として core にアイドル判定を追加する。検討の詳細は `study-material/done/refresh-token-idle-inactivity-timeout.md` を参照。

## 対象ファイル

- `packages/core/src/token-request.ts`（`RefreshTokenInfo` フィールド追加・`validateTokenRequest` のアイドル判定）
- `packages/core/src/token-request.test.ts`
- `packages/cli/src/frameworks/hono/templates.ts`（任意 config・store への `lastUsedAt` 保存）
- `packages/cli/src/__tests__/hono-generator.test.ts`

## 仕様参照

- RFC 9700 §4.14.2「Refresh Token Protection」: rotation・sender-constraining・限定的な有効期限で RT の露出時間を抑えることを推奨（inactivity timeout そのものは規定していない。上記「訂正」を参照）。
- OAuth 2.1 §4.3 / §6.1: RT ローテーションと有効期限の限定。
- RFC 6749 §10.4: RT のセキュリティ考慮（露出時間の最小化）。

## 現状の実装

- `RefreshTokenInfo`（`token-request.ts:166-221`）の時間系は `expiresAt` / `iat?` / `originalIssuedAt` のみ。`lastUsedAt` を持たない。
- `validateTokenRequest()` の失効判定（`token-request.ts:438-443`）は `refreshTokenInfo.expiresAt < now` の絶対期限のみ。
- テンプレートは `refreshTokenExpiresAt = originalIssuedAt + config.refreshTokenAbsoluteLifetime` で固定（sliding 無し）。

## 修正方針

- [ ] `RefreshTokenInfo` に任意フィールド `lastUsedAt?: number`（Unix epoch 秒）を追加する。意味は「この RT が発行された＝直近にトークン化された時刻」。
- [ ] `validateTokenRequest()` のコンテキストに任意の `refreshTokenIdleTimeoutSeconds?: number` を渡せるようにする（未指定／0 はアイドル失効なし＝従来挙動）。
- [ ] アイドル判定を絶対期限チェックの直後に追加する。`lastUsedAt` が存在し、かつ `idleTimeout > 0` のときのみ:
  ```ts
  if (
    refreshTokenIdleTimeoutSeconds &&
    refreshTokenIdleTimeoutSeconds > 0 &&
    refreshTokenInfo.lastUsedAt !== undefined &&
    nowForRefresh - refreshTokenInfo.lastUsedAt > refreshTokenIdleTimeoutSeconds
  ) {
    throw new TokenError(TokenErrorCode.InvalidGrant, 'Refresh token expired due to inactivity');
  }
  ```
- [ ] ローテーション時、新 RT の `lastUsedAt` を「今」に更新する（スライディング）。`originalIssuedAt` は据え置き（絶対期限は不変）。テンプレートの store.set に `lastUsedAt: issuedAt` を保存。
- [ ] 既定 OFF を保証する（`refreshTokenIdleTimeoutSeconds` 未設定時は `lastUsedAt` の有無に関わらず従来どおり動作）。
- [ ] CLI テンプレートに `refreshTokenIdleTimeout`（任意 config・既定 0）を追加し、core へ伝播。

## テスト要件

- [ ] `refreshTokenIdleTimeoutSeconds` 未設定なら、古い `lastUsedAt` を持つ RT でも失効しない（後方互換）
- [ ] `idleTimeout` 設定時、`now - lastUsedAt > idleTimeout` の RT は `invalid_grant`（`Refresh token expired due to inactivity`）で拒否される
- [ ] `idleTimeout` 設定時、`now - lastUsedAt <= idleTimeout` の RT は正常にローテーションされる
- [ ] ローテーション後の新 RT の `lastUsedAt` が更新され、`originalIssuedAt`（＝絶対期限の基準）は引き継がれて不変であること
- [ ] アイドルと絶対期限が同時設定でも、いずれか早い方で失効すること

## 完了条件

`pnpm --filter @maronn-openid-connect/core test` および `pnpm --filter @maronn-openid-connect/cli test` がパスすること
