# T-020 [Major] Refresh Token grant でのスコープ削減時 ID Token クレームフィルタ

## ステータス

🟡 Major / 未着手

## 背景

refresh_token grant でスコープ削減（初回 scope より小さい scope を要求）は `validateTokenRequest` で許可しているが、削減後の scope に対応するクレームセットが ID Token に反映されていない。

例: 初回 `openid profile email` で取得 → refresh 時 `openid email` で要求した場合でも、発行される ID Token が `name` 等の profile クレームを含む可能性がある。

## 対象ファイル

- `packages/core/src/token-request.ts`
- `packages/core/src/token-response.ts`

## 仕様参照

- OIDC Core 1.0 §12: refresh で発行される ID Token のクレームセットは、削減後の scope に準拠すること
- OIDC Core 1.0 §5.4: scope に基づくクレームの返却ルール

## 現状の実装

`token-request.ts` では refresh 時の scope 削減を許可し `ValidatedRefreshTokenRequest.scope` に削減後の scope を格納している。しかし `generateTokenResponse` で ID Token を生成する際は scope による claims フィルタが行われていない。

UserInfo endpoint 側は `filterUserInfoClaims(claims, scope)` によってスコープベースのフィルタが実装済み（`userinfo.ts`）。ID Token 側の同等処理が不足している。

## 修正方針

- [ ] `ValidatedRefreshTokenRequest` に `effectiveScope: string` を確認し、削減後の scope が確実に伝播していることを確認する（既に `scope` フィールドで保持しているはずだが、伝播経路を追う）

- [ ] `generateTokenResponse` で ID Token を生成する際に `effectiveScope` を使用し、scope に応じてクレームを絞り込む

  - `profile` scope なし → `name`, `family_name`, `given_name`, `middle_name`, `nickname`, `preferred_username`, `profile`, `picture`, `website`, `gender`, `birthdate`, `zoneinfo`, `locale`, `updated_at` を除外
  - `email` scope なし → `email`, `email_verified` を除外
  - `address` scope なし → `address` を除外
  - `phone` scope なし → `phone_number`, `phone_number_verified` を除外

- [ ] `filterUserInfoClaims`（`userinfo.ts`）と同じロジックを共通ヘルパーとして `token-response.ts` または新規ファイルに切り出し、ID Token / UserInfo 両方から呼び出せるようにする

## テスト要件

- [ ] 初回 `openid profile email` で取得 → refresh 時 `openid email` で要求 → 発行 ID Token に `name` 等 profile クレームが含まれないこと
- [ ] 初回 `openid profile email` で取得 → refresh 時 `openid profile email`（削減なし）→ 発行 ID Token に全クレームが含まれること
- [ ] scope 削減しても `sub`・`iss`・`aud`・`exp`・`iat` などの必須クレームは常に含まれること

## 完了条件

`pnpm --filter @maronn-openid-connect/core test` がパスすること
