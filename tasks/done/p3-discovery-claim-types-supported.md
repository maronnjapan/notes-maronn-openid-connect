# [P3] Discovery `claim_types_supported` の明示とドキュメント補正

## ステータス

🟢 Low / 未着手

## 背景

OpenID Connect Discovery 1.0 §3 は、OP がサポートする Claim Type を示す
`claim_types_supported`（値: `normal` / `aggregated` / `distributed`、OPTIONAL、
省略時は `normal` のみと解釈）を定義している。本 OP は Normal Claims のみを
サポートする（`packages/core/src/userinfo.ts` の `filterClaimsByScope` が
`_claim_names` / `_claim_sources` を生成しない）。

2 つの問題がある。

1. **ドキュメントの事実誤認**: `study-material/distributed-aggregated-claims.md` に
   「Discovery に専用フィールドは無い」という誤った記述があった（本タスク起票時点で補正済み）。
   `discovery.ts` 側に `claim_types_supported` を出力する手段が無いことと併せ、
   「クレームタイプの広告」という観点が実装にもテストにも存在しない。
2. **ディスカバリ正直性の不統一**: 本リポジトリは `request_parameter_supported: false`
   等で「未対応の明示」を重視している。`claim_types_supported` は省略でも仕様準拠だが、
   `["normal"]` を明示すれば実態と広告が機械的に一致し、Aggregated/Distributed 未対応が明確になる。

検討の詳細は `study-material/done/discovery-claim-types-supported.md` を参照。
本タスクは「任意フィールドの実装」部分のみを切り出したもの（必須ではなく、相互運用性・透明性の向上が目的）。

## 対象ファイル

- `packages/core/src/discovery.ts`
- `packages/core/src/discovery.test.ts`（または該当するテストファイル）
- `packages/cli/src/frameworks/hono/templates.ts`（Discovery route の `buildProviderMetadata` 呼び出し L1785 付近）
- `packages/cli/src/__tests__/hono-generator.test.ts`

## 仕様参照

- OpenID Connect Discovery 1.0 §3 "OpenID Provider Metadata"
  — `claim_types_supported`: OPTIONAL。値は `normal` / `aggregated` / `distributed`。
    省略時は `normal` のみサポートと解釈される。
  https://openid.net/specs/openid-connect-discovery-1_0.html#ProviderMetadata
- OpenID Connect Core 1.0 §5.6 "Claim Types"（Normal / Aggregated / Distributed の定義）
  https://openid.net/specs/openid-connect-core-1_0.html#ClaimTypes

## 現状の実装

- `packages/core/src/discovery.ts`
  - `ProviderMetadataConfig` / `ProviderMetadata` に `claimTypesSupported` /
    `claim_types_supported` が無い。
  - `buildProviderMetadata()` は `scopes_supported` 等を「配列が空なら省略」で出力する
    パターンを持つ（L196-201 等）。同型の分岐を追加すれば対応できる。
- `packages/cli/src/frameworks/hono/templates.ts`
  - L1785 付近の `buildProviderMetadata({ ... })` 呼び出しに `claimTypesSupported` を渡していない。

## 修正方針

- [ ] `ProviderMetadataConfig` に `claimTypesSupported?: string[]` を追加する。
- [ ] `ProviderMetadata` に `claim_types_supported?: string[]` を追加する。
- [ ] `buildProviderMetadata()` で「`claimTypesSupported` が空でなければ `claim_types_supported`
      として出力する」分岐を、既存の `scopes_supported` 等と同型で追加する。
- [ ] 値検証ポリシーを決める：本 OP は Normal のみ実装のため、`["normal"]` 以外
      （`aggregated` / `distributed`）が渡された場合は、実態に反する広告を防ぐために拒否する方針を推奨。
      最終判断は実装者に委ねる（拒否 or 通過を選択し、コメントで根拠を明記）。
- [ ] CLI Discovery template の `buildProviderMetadata` 呼び出しに
      `claimTypesSupported: ['normal']` を追加する。

```ts
// packages/core/src/discovery.ts （イメージ）
if (config.claimTypesSupported && config.claimTypesSupported.length > 0) {
  metadata.claim_types_supported = config.claimTypesSupported;
}
```

## テスト要件

- [ ] `claimTypesSupported` 未指定のとき、出力に `claim_types_supported` が **含まれない**こと。
- [ ] `claimTypesSupported: ['normal']` 指定で、出力が `claim_types_supported: ['normal']`
      に **一意に固定**されること（`toEqual(['normal'])`）。
- [ ] （拒否方針を採る場合）`['distributed']` 等を渡すと例外を送出すること。
- [ ] CLI 生成コードの Discovery レスポンスに `claim_types_supported: ['normal']` が含まれること。

## 完了条件

- `pnpm --filter @maronn-openid-connect/core test` がパスすること
- `pnpm --filter @maronn-openid-connect/cli test` がパスすること
