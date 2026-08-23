# [P3] 同意取り消し時に grant（grantId）系列のトークンを失効する配線を追加する

## ステータス

✅ 完了（2026-07-21）

## 背景

ユーザーが「このアプリのアクセスを解除」（同意取り消し）を行っても、現状は**すでに発行済みのリフレッシュトークン／アクセストークンが満了まで生き続ける**。core にはコード再利用検知のために grant 単位でトークン系列を一括失効する `revokeTokensByGrantId(grantId)` が**既に実装されている**が、「同意取り消し」イベントからこのプリミティブを呼ぶ動線が無い。

offline_access（refresh token）を発行できる OP において、取り消し後もトークンが有効なままなのは権限管理・侵害封じ込めの観点で欠落であり、主要 IdP（Google「サードパーティ アクセス削除」等）の挙動とも乖離する。既存機構の再利用で低コストに閉ループ化できる。

検討の詳細は `study-material/done/consent-withdrawal-grant-token-revocation.md` を参照。隣接レイヤとの分担:

- 同意の記録・取り消し UI/API 全体: `study-material/done/consent-grant-persistence-and-management.md`
- subject 全体のウォーターマーク失効（全デバイスログアウト・資格情報変更）: `study-material/subject-wide-token-invalidation-on-credential-change.md`
- `revokeTokensByGrantId` の cascade 契約: `study-material/done/authorization-code-reuse-cascade-store-semantics.md`

## 対象ファイル

- `packages/cli/src/frameworks/*/templates.ts`（consent resolver / store の生成元。`revokeConsent` 動線とトークン失効呼び出しの配線）
- 確認用: `samples/{express,hono,fastify,nextjs}/src/oidc-provider/resolvers.ts` / `store.ts`（consent store の具象）
- 確認用（変更不要）: `packages/core/src/token-request.ts`（`revokeTokensByGrantId` の既存定義 L177 / L279 付近）

## 仕様参照

- **OpenID Connect Core 1.0 §11 Offline Access** — `offline_access`（Refresh Token 発行）は同意に基づく。同意消失後のトークン生存は不整合。
  https://openid.net/specs/openid-connect-core-1_0.html#OfflineAccess
- **RFC 9700 OAuth 2.0 Security BCP** — 長命なリフレッシュトークンには失効手段の提供が推奨される。
  https://www.rfc-editor.org/rfc/rfc9700
- **RFC 7009 OAuth 2.0 Token Revocation** — クライアント主導の失効 API（`revocation.ts` 実装済み）。本タスクは**ユーザー主導**の失効であり主体が異なる。
  https://www.rfc-editor.org/rfc/rfc7009

## 現状の実装

- 既存プリミティブ（再利用対象、`packages/core/src/token-request.ts`）:
  - `RefreshTokenResolver.revokeTokensByGrantId?(grantId)` / `AuthorizationCodeResolver.revokeTokensByGrantId?(grantId)`。
  - 現状の呼び出し元は再利用検知のみ（refresh token 再提示 L477-479、auth code 再利用 L575-577 付近）。
- `grantId` はコード→AT→RT→ローテーション後 RT を貫通して連結されており、1 つの `grantId` で grant 由来トークンを全特定できる。
- **欠落**: 同意取り消し（`ConsentResolver.revokeConsent` 想定）から `revokeTokensByGrantId` を呼ぶ動線が無い。また consent レコードが、その同意で発行された `grantId`（複数あり得る）を索引していない。

## 修正方針

> まず索引方針を決定する（既存の `consent-grant-persistence-and-management.md` が `recordConsent`/`revokeConsent` を方針 A で採用済みの前提に乗る）。

- [ ] **方針決定**: consent ↔ `grantId` の対応付けをどこで持つか:
  - 方針 A（推奨候補）: consent store に `(subject, clientId) → grantId[]` を索引し、`revokeConsent` で各 `grantId` に `revokeTokensByGrantId` を適用
  - 方針 B: `subject-wide-token-invalidation-on-credential-change.md` のウォーターマークを `(subject, clientId)` 単位に拡張
  - 方針 C: Grant Management 拡張（`ext-grant-management-api.md`）に委譲（最小閉ループには過剰）
- [ ] 採用方針に基づき、認可コード／トークン発行時に consent ↔ `grantId` の対応を記録する（方針 A の場合）。
- [ ] `revokeConsent`（または同等の取り消し動線）内で、対応する `grantId` 群に対し既存 `revokeTokensByGrantId` を呼ぶ配線を CLI 生成テンプレに追加する。
- [ ] CLI 生成 store の参照実装に「アクセス解除」例を追加する（生成コードは cli 側を修正）。
- [ ] store の失効反映は `resolver-and-store-contract.md` の契約に従わせる（KV の結果整合性で失効が遅延し silent 認可・トークン生存が残らないよう注意）。

## テスト要件

- [ ] 同意取り消し後、当該 grant のリフレッシュトークンで token endpoint を叩くと `invalid_grant` になること。
- [ ] 同意取り消し後、当該 grant のアクセストークンが introspection で `active: false` になること。
- [ ] **隔離**: 別 client への同 subject の同意・トークンが影響を受けないこと（grant 粒度の失効であること）。
- [ ] 取り消し後の `prompt=none` が `interaction_required`（または `consent_required`）になること（同意レコードの失効反映、既存挙動との整合）。
- [ ] `conformance.test.ts` 生成元への影響有無を確認し、OP の対外挙動が変わる場合は cli 側テンプレと各 sample を更新すること。

## 完了条件

- `pnpm --filter @maronn-openid-connect/cli test` がパスすること。
- 採用した索引方針で、同意取り消し→当該 grant の RT/AT 失効が成立し、他 grant に波及しないことがテストで固定されていること。
- 生成 store の参照実装に「アクセス解除」動線が含まれること。
