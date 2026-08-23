# [P3] Discovery メタデータの Basic OP 自己整合ガードを追加する（`code` / `openid` の広告保証）

## ステータス

🟢 Low / 未着手

## 背景

`buildProviderMetadata` は、署名鍵に RS256 が含まれることは `assertHasRs256Key` でビルド時強制しているが、
Basic OP の中核である以下の広告整合を保証していない。

1. `response_types_supported` に `"code"` が含まれること（Basic OP は Authorization Code Flow が必須）。
2. `scopes_supported` を広告する場合に `"openid"` が含まれること（OIDC Discovery §3: OP は `openid` scope を MUST support）。

現状は「非空チェック」しか無いため、利用者が生成コードを改変して `response_types_supported` から `code` を外す／
`scopes_supported` から `openid` を落とすと、Basic OP 非対応の Discovery を無自覚に公開できてしまい、テストでも固定されない。
これは既存の `assertHasRs256Key`（Basic OP 不変条件の fail-fast ガード）と同じ設計思想の自然な拡張。

検討の詳細は `study-material/done/discovery-metadata-basic-op-self-consistency-guard.md` を参照。

## 対象ファイル

- `packages/core/src/discovery.ts`（`buildProviderMetadata` の必須フィールド検査 L161-169、`scopes_supported` 出力 L203-205）
- `packages/core/src/discovery.test.ts`
- 必要に応じて各 sample の `conformance.test.ts`（Discovery 検査）と `packages/cli` のテンプレート生成側テスト

## 仕様参照

- OIDC Discovery 1.0 §3 — `response_types_supported`（"MUST support the `code` ..."）／`scopes_supported`（"The server MUST support the `openid` scope value."）: https://openid.net/specs/openid-connect-discovery-1_0.html#ProviderMetadata
- OIDC Core 1.0 §3.1.2（Authorization Code Flow — `response_type=code`）
- RFC 8414 §2（AS Metadata の `response_types_supported` / `scopes_supported`）: https://www.rfc-editor.org/rfc/rfc8414#section-2
- 先例: `packages/core/src/discovery.ts:171` の `assertHasRs256Key`（OIDC Core §15.1 のビルド時ガード）

## 現状の実装

```ts
// packages/core/src/discovery.ts:161-166 — 非空チェックのみ。code 包含は未検査
if (!config.responseTypesSupported || config.responseTypesSupported.length === 0) {
  throw new Error('responseTypesSupported must not be empty');
}

// packages/core/src/discovery.ts:203-205 — 渡された配列をそのまま出力。openid 包含は未検査
if (config.scopesSupported && config.scopesSupported.length > 0) {
  metadata.scopes_supported = config.scopesSupported;
}
```

## 修正方針

まず方針を決定する（study-material の「7. 実装方針の候補」参照）。

- [ ] 方針決定: A（常時強制／推奨）/ B（`allowNonBasicOpMetadata` 等の opt-out 付き）/ C（テンプレートテストのみ）
- [ ] 方針A/B の場合、`buildProviderMetadata` に以下のガードを `assertHasRs256Key` と同じ throw スタイルで追加:
  - [ ] `response_types_supported` に `"code"` が含まれなければ `Error` を throw
  - [ ] `scopes_supported` が渡され、かつ `"openid"` を含まなければ `Error` を throw
- [ ] エラーメッセージに根拠（Basic OP / OIDC Discovery §3）を明記する
- [ ] 方針B の場合のみ、opt-out フラグを `ProviderMetadataConfig` に追加し、既定は「強制」にする

## テスト要件

- [ ] `response_types_supported` に `code` を含まない設定でビルドが throw する（方針A/B）
- [ ] `scopes_supported` を渡し `openid` を含まない設定でビルドが throw する（方針A/B）
- [ ] `code` を含む `response_types_supported` かつ `openid` を含む `scopes_supported` は正常にビルドできる（回帰固定）
- [ ] `scopes_supported` を渡さない（省略する）場合はガードが発火しない（RECOMMENDED フィールドの省略は許容）
- [ ] 生成 OP の Discovery 出力（`code` / `openid` を広告）が変わらないことを sample の `conformance.test.ts` で確認する

## 完了条件

- [ ] 上記テストが追加され通過する
- [ ] `pnpm --filter @maronn-openid-connect/core test` がパス
