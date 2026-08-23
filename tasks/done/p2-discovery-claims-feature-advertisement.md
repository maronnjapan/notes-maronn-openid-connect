# [P2] Discovery の `claims` 機能広告を実態に合わせる（`claims_supported` 内容 / `claims_parameter_supported`）

## ステータス

🟠 High / 未着手

## 背景

CLI 生成 Provider の Discovery（`/.well-known/openid-configuration`）が、実装済みの `claims` 機能を
過少広告している。Fidelity（仕様忠実）を差別化軸とする本リポジトリにとって、実装と広告の不一致は説明責任上の穴。

1. **`claims_supported` の内容欠落**: OP は ID Token に `auth_time` / `nonce` / `acr` / `amr` / `azp` / `at_hash` を
   発行できるのに、`claims_supported` 配列に含めていない。メタデータ駆動の RP がこれらを「供給不可」と誤認しうる。
2. **`claims_parameter_supported` 未広告**: `claims` リクエストパラメータは ID Token / UserInfo 両経路で実装済み
   （`p0-claims-id-token-support` で対応）だが、Discovery で広告しておらず既定 `false`。
   仕様準拠 RP は `false` だと `claims` を送らないため、投資した機能が死蔵される。

検討の詳細は `study-material/done/discovery-claims-feature-advertisement.md` を参照。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`（全フレームワーク共通の `discoveryRouteTemplate`、`claimsSupported` は L1992-2017 付近）
- `packages/cli/src/__tests__/*generator*.test.ts`（Discovery 出力のアサーション）
- conformance テスト生成元（`packages/cli` 内、各 sample の `conformance.test.ts` を生成するコード）
- 必要に応じて `packages/core/src/discovery.ts`（`claimsParameterSupported` は既にサポート済み L49, L227-229）

## 仕様参照

- OpenID Connect Discovery 1.0 §3 "OpenID Provider Metadata"
  - `claims_supported`: RECOMMENDED。「OP が値を供給できる（MAY be able to supply）Claim 名の JSON 配列」。
  - `claims_parameter_supported`: Boolean。省略時の既定は `false`。`true` でないと準拠 RP は `claims` を送らない。
  https://openid.net/specs/openid-connect-discovery-1_0.html#ProviderMetadata
- OpenID Connect Core 1.0 §2 / §3.1.3.6（`auth_time` / `nonce` / `acr` / `amr` / `azp` / `at_hash` の定義）/ §5.5（`claims` パラメータ）
  https://openid.net/specs/openid-connect-core-1_0.html

## 現状の実装

- `claimsSupported`（`hono/templates.ts:1992-2017`）は `sub, iss, aud, exp, iat` ＋ profile/email/address/phone 系のみ。
  `auth_time` / `nonce` / `acr` / `amr` / `azp` / `at_hash` を含まない。
  - core ID Token はこれらを発行: `packages/core/src/id-token.ts:21-25`（`auth_time`/`nonce`/`acr`/`amr`）, `:122-130`（`azp`）。
- `discoveryRouteTemplate` は `claimsParameterSupported` を一度も設定していない（既定 `false`）。
  - `claims` パラメータ自体は配線済み: `hono/templates.ts:1539-1541`（ID Token）, `:1559-1562`（UserInfo 永続化）, `:1749-1757`（UserInfo 利用）。
- core 側 `buildProviderMetadata` は両フィールドを表現可能（`discovery.ts:49, 227-229`）。テンプレートの配線のみ欠落。

## 修正方針

- [ ] `discoveryRouteTemplate` の `claimsSupported` に `auth_time`, `nonce`, `acr`, `amr`, `azp`, `at_hash` を追加する
      （`c_hash` は Hybrid 未対応のため現時点では含めない）。
- [ ] `discoveryRouteTemplate` に `claimsParameterSupported: true` を追加する。
- [ ] CLI ジェネレータのテストで、生成 Discovery 出力に上記が含まれることを一意に固定する。
- [ ] conformance テスト生成元に Discovery のアサーションを追加し、4 フレームワークで固定する
      （`CLAUDE.md` 方針どおり、`conformance.test.ts` は直接編集せず生成元 CLI を変更）。
- [ ] `tasks/T-021-discovery-metadata.md` の残課題が本 2 件であることを反映（ステータス整理）。

## テスト要件

- [ ] 生成 Discovery レスポンスの `claims_supported` が `auth_time`/`nonce`/`acr`/`amr`/`azp`/`at_hash` を含むこと（具体値で固定）。
- [ ] 生成 Discovery レスポンスの `claims_parameter_supported` が `true` であること（`toBe(true)`）。
- [ ] 4 フレームワーク（express/hono/fastify/nextjs）で同一の広告内容になること。
- [ ] 既存の Discovery テスト（`scopes_supported` 等）が壊れないこと。

## 完了条件

- `pnpm --filter @maronn-openid-connect/cli test` がパスすること
- 各 sample の `conformance.test.ts`（生成物）がパスすること
