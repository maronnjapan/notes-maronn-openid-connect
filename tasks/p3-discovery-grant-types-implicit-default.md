# [P3] Discovery で `grant_types_supported` を省略時の implicit 暗黙広告を防ぐ

## ステータス

🟡 Medium / 未着手

## 背景

`buildProviderMetadata` は `grant_types_supported` を「非空配列が渡されたときだけ」出力する。OIDC Discovery §3 は、このフィールドを省略した場合の既定値を `["authorization_code", "implicit"]` と定める。したがって Basic OP がこのフィールドを省略すると、**実装していない implicit フローをサポートと暗黙広告**してしまう。OAuth 2.1 では implicit グラントは削除されており、方針と矛盾する。

詳細な検討は `study-material/done/discovery-grant-types-supported-implicit-default.md` を参照。`response_types_supported` 等の自己整合ガード（`study-material/done/discovery-metadata-basic-op-self-consistency-guard.md`）や auth methods 既定（`study-material/done/discovery-token-endpoint-auth-methods-default-fidelity.md`）とは別軸。

## 対象ファイル

- `packages/core/src/discovery.ts`（`buildProviderMetadata`）
- `packages/core/src/discovery.test.ts`（テスト追加）
- `packages/cli`（生成 OP が `grant_types_supported` を渡す構成なら生成元の確認）
- `samples/*/conformance.test.ts`（生成元 `packages/cli`）

## 仕様参照

- OpenID Connect Discovery 1.0 §3（`grant_types_supported` の既定は `["authorization_code", "implicit"]`）: https://openid.net/specs/openid-connect-discovery-1_0.html#ProviderMetadata
- OAuth 2.1 draft（implicit グラント削除）: https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1

## 現状の実装

```ts
// packages/core/src/discovery.ts
if (config.grantTypesSupported && config.grantTypesSupported.length > 0) {   // L218
  metadata.grant_types_supported = config.grantTypesSupported;
}
// 未指定なら省略 → Discovery §3 既定で implicit が暗黙適用される
```

テスト（`discovery.test.ts:244-247` 付近）は「渡したときにパススルー」のみで、省略時の暗黙 implicit 広告を検証していない。

## 修正方針

- [ ] `grantTypesSupported` 未指定時に implicit を暗黙広告しないようにする（study-material 方針A: 既定値を明示出力）
  ```ts
  metadata.grant_types_supported =
    config.grantTypesSupported && config.grantTypesSupported.length > 0
      ? config.grantTypesSupported
      : ['authorization_code'];   // refresh_token 提供構成なら ['authorization_code', 'refresh_token']
  ```
- [ ] refresh_token を提供する構成で既定に `refresh_token` を含めるべきか（config から判定できるか）を確認する
- [ ] 自己整合ガード（`study-material/done/discovery-metadata-basic-op-self-consistency-guard.md`）に「`implicit` を含む `grant_types_supported` を拒否/警告」を足すか検討する（study-material 方針B）

## テスト要件

- [ ] `grantTypesSupported` 未指定時、出力メタデータが `implicit` を暗黙広告しない（`authorization_code` を明示、implicit を含まない）
- [ ] `refresh_token` 提供構成での既定値の期待を固定
- [ ] 明示指定時のパススルーがリグレッションしない
- [ ] 生成 OP の Discovery 出力が変わるため、`samples/*/conformance.test.ts`（生成元 `packages/cli`）の Discovery 検証を更新

## 完了条件

- `pnpm --filter @maronn-openid-connect/core test` がパスすること
- 各 sample の `conformance.test.ts` がパスすること
