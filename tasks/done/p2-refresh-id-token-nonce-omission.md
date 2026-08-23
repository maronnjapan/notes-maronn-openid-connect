# [P2] Refresh 再発行 ID Token から nonce を省略し、誤った仕様コメントを是正する

## ステータス

🟡 Medium / 未着手

## 背景

`refresh_token` グラントで ID Token を再発行する際、core は初回認可リクエストの `nonce`
を引き継いで ID Token に格納している。型コメントは「OIDC Core 1.0 Section 12.1: refresh で
発行する ID Token は同じ nonce を持つ **MUST**」と記載しているが、この MUST 主張を裏付ける
条文は §12.1 にも §12.2 にも存在しない。

`nonce` は「Authentication Request ↔ ID Token」をワンタイムで束縛しリプレイを防ぐ値であり
（OIDC Core §2）、認可リクエストが存在しない refresh では古い nonce を詰め続けても
リプレイ防止に寄与しない。主要 OP（Google / Auth0 等）も refresh 再発行 ID Token に
nonce を含めないのが一般的。

影響範囲:
- Fidelity（忠実性）: 条文に無い MUST をコメントに記載しており、ライブラリの信頼性
  シグナルを損なう。
- 相互運用性: 厳格な RP / 検証ツールが想定外の nonce を警告・拒否し得る（実害は限定的）。
- 学習用途: 利用者が「refresh ID Token に nonce 保持は必須」と誤学習する。

詳細な仕様分析は `study-material/done/refresh-id-token-nonce-omission.md` を参照。

## 対象ファイル

- `packages/core/src/token-request.ts`（`RefreshTokenInfo.nonce` /
  `ValidatedRefreshTokenRequest.nonce` のコメントと引き継ぎ）
- `packages/core/src/token-response.ts`（`generateTokenResponse` の nonce 出力）
- `packages/cli/src/frameworks/hono/templates.ts`（Token エンドポイント refresh 分岐で
  refresh 由来 nonce を渡している箇所）
- 各対応テストファイル（`token-response.test.ts` 等）

## 仕様参照

- OIDC Core 1.0 §2 ID Token: nonce は「passed through unmodified from the
  **Authentication Request** to the ID Token」。
- OIDC Core 1.0 §3.1.3.7 step 11: nonce 検証は「認可リクエストで nonce を送った場合」のみ。
- OIDC Core 1.0 §12.2 Refresh Response: 再発行 ID Token の保持対象は
  iss / sub / iat / aud / exp / auth_time / azp / acr / amr。**nonce は列挙されない**。

> 注: 「nonce を含めてはならない（MUST NOT）」と断言する明文も §12.2 には無い。本タスクは
> ①誤った MUST コメントの是正 と ②既定で省略する設計判断 の 2 点を扱う。

## 現状の実装

`packages/core/src/token-request.ts`:
```ts
/**
 * 初回認可リクエストの nonce。
 * OIDC Core 1.0 Section 12.1: refresh で発行する ID Token は同じ nonce を持つ MUST。  // ← 誤り
 */
nonce?: string;
```
`validateTokenRequest()` の refresh 分岐で `nonce: refreshTokenInfo.nonce` を返し、
`generateTokenResponse()` の `if (nonce !== undefined) idTokenPayload.nonce = nonce;`
で再発行 ID Token に格納される。

## 修正方針

- [ ] `RefreshTokenInfo.nonce` / `ValidatedRefreshTokenRequest.nonce` のコメントを
      訂正する（「§12.2 は nonce 保持を要求しない」と明記。誤った「§12.1 ... MUST」を削除）。
- [ ] 既定挙動を「refresh 再発行 ID Token では nonce を出力しない」に変更する。
      - 案A（推奨）: CLI テンプレートの refresh 分岐で `generateTokenResponse` に
        nonce を渡さない。core の引き継ぎフィールド自体は将来用途のため残してもよいが、
        ID Token への出力はしない。
      - 案B（互換重視）: `generateTokenResponse` に `preserveNonceOnRefresh?: boolean`
        （既定 false）を追加し、明示オプトイン時のみ従来動作。
      - どちらを採用するかは設計協議（`/design-discussion`）で確定する。
- [ ] `auth_time` / `acr` / `amr` / `azp` の保持ロジック（§12.2 準拠で正しい）は
      変更しない。nonce のみを対象にする。

## テスト要件

- [ ] should not include nonce in ID Token issued via refresh_token grant（既定動作）
- [ ] should preserve auth_time on refresh-issued ID Token（回帰防止）
- [ ] should preserve acr / amr / azp on refresh-issued ID Token（回帰防止）
- [ ] should include nonce in ID Token issued via authorization_code grant（初回は不変）
- [ ]（案B採用時）should include original nonce on refresh only when
      preserveNonceOnRefresh is true

## 完了条件

- 上記テストが全て通過する。
- 誤った仕様コメントが除去され、§12.2 に基づく正しい説明へ更新されている。
- `pnpm --filter @maronn-openid-connect/core test` および
  `pnpm --filter @maronn-openid-connect/cli test` がパスする。
