# Discovery: `grant_types_supported` を省略すると既定値で `implicit` を暗黙広告してしまう

## 1. このトピックで確認したいこと

`buildProviderMetadata` は `grant_types_supported` を「呼び出し側が非空配列を渡したときだけ」出力し、既定値やガードを持たない。OpenID Connect Discovery 1.0 §3 は、このフィールドを省略した場合の既定値を `["authorization_code", "implicit"]` と定めている。したがって Basic OP がこのフィールドを省略すると、**実装していない implicit フローをサポートしていると RP に暗黙広告**してしまう。

本ファイルは、この「省略時の既定値トラップ」という差分に限定する（`response_types_supported` 等の自己整合ガードや、`token_endpoint_auth_methods_supported` の既定は別トピックで扱い済み）。

## 2. 関連する仕様・基準

Discovery メタデータの共通説明・自己整合の方針は `study-material/done/discovery-metadata-basic-op-self-consistency-guard.md` および `study-material/discovery-optional-metadata-fields.md` を参照し繰り返さない。

- **OpenID Connect Discovery 1.0 §3（OpenID Provider Metadata）**:
  > "grant_types_supported OPTIONAL. JSON array containing a list of the OAuth 2.0 Grant Type values that this OP supports. ... If omitted, the default value is `["authorization_code", "implicit"]`."

  つまり**省略＝`authorization_code` と `implicit` の両方をサポートと宣言したのと同義**。Basic OP は Authorization Code Flow のみを提供し implicit は提供しないため、省略は不正確な広告になる。
- **OpenID Connect Discovery 1.0 §3（`response_types_supported`）**: このフィールドは REQUIRED。Basic OP では `["code"]` になるはずで、`grant_types_supported` を明示するなら `["authorization_code"]`（および必要なら `refresh_token`）と整合させるべき。
- **OAuth 2.1**: implicit グラントは削除されている。OAuth 2.1 準拠を掲げるなら、implicit を暗黙広告するのは方針と矛盾する。

## 3. 参照資料

- OpenID Connect Discovery 1.0 §3 Provider Metadata — https://openid.net/specs/openid-connect-discovery-1_0.html#ProviderMetadata
- OAuth 2.1 draft（implicit グラント削除） — https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1
- 既存の関連記述（重複回避）: `study-material/done/discovery-metadata-basic-op-self-consistency-guard.md`（`response_types_supported` 等の整合）、`study-material/done/discovery-token-endpoint-auth-methods-default-fidelity.md`（auth methods の既定）

## 4. 現在の実装確認

`packages/core/src/discovery.ts`（`buildProviderMetadata`）:

```ts
// Optional fields
if (config.grantTypesSupported && config.grantTypesSupported.length > 0) {   // L218
  metadata.grant_types_supported = config.grantTypesSupported;               // L219
}
```

- 呼び出し側が `grantTypesSupported` を渡さない（または空配列）と、**フィールドごと省略される**。
- 省略された場合、Discovery §3 の既定 `["authorization_code", "implicit"]` が適用されると RP は解釈する。
- テスト（`discovery.test.ts:244-247` 付近）は「渡したときにパススルーされる」ケースのみで、省略時の暗黙 implicit 広告は検証されていない。

一方 `id_token_signing_alg_values_supported` は実鍵から導出（L175-183）され、`response_types_supported` は自己整合ガードの対象（別トピック）である。`grant_types_supported` だけがこの「省略トラップ」に対して無防備。

## 5. 現在の実装との差分

- **満たしていること**: 呼び出し側が明示すればそのまま広告する。値の受け渡し自体は正しい。
- **不足している可能性があること**: 省略時に既定で implicit を含んでしまう問題への防御・既定値の明示がない。
- **セキュリティ上の観点**: implicit を広告すると、implicit を試みる RP を誘発し得る。OP が実際には implicit を受け付けないため機能はしないが、「広告と実挙動の乖離」はセキュリティレビューで指摘されやすい。
- **相互運用性の観点**: RP が Discovery を信頼して implicit を選ぶと、認可リクエストが `unsupported_response_type` 等で失敗する。最初から `["authorization_code"]`（+`refresh_token`）を広告すれば齟齬を避けられる。
- **Basic OP として確認すべきこと**: 認定テストが `grant_types_supported` の省略/内容を検査するかは要確認。ただし OAuth 2.1 準拠・Fidelity の観点で implicit の暗黙広告は望ましくない。

## 6. 改善・追加を検討する理由

- **なぜ検討するか**: 「省略＝implicit 広告」という直感に反する既定値の存在。Basic OP / OAuth 2.1 の方針（implicit 非提供）と真っ向から食い違う。
- **Basic OP 必須か拡張か**: 認定必須とまでは言い切れないが、実挙動と広告の一致という Fidelity ハードニング。
- **導入しやすさ**: `buildProviderMetadata` の該当分岐に「未指定なら既定で `['authorization_code']`（refresh_token 提供時は併記）を出力」という最小ガードを足すだけ。自己整合ガード（別トピック）と同じ場所で扱える。
- **既存実装との接続**: `id_token_signing_alg_values_supported` を鍵から導出しているのと同じ「広告は実挙動から導く」思想を `grant_types_supported` にも適用する。
- **実装しない場合のリスク**: 生成 OP が `grant_types_supported` を渡さない構成だと、implicit を暗黙広告し続ける。RP との相互運用ノイズと、セキュリティレビュー指摘が残る。

## 7. 実装方針の候補（判断材料）

最終判断は人間が行う。

- 方針A（既定値を明示出力, 推奨）: `grantTypesSupported` 未指定時は `['authorization_code']` を出力。`refresh_token` を提供する構成では `['authorization_code', 'refresh_token']` を既定にするか要判断（refresh_token の提供有無を config から判定できるか確認が必要）。
- 方針B（自己整合ガードに統合）: `study-material/done/discovery-metadata-basic-op-self-consistency-guard.md` のガードに「`grant_types_supported` に `implicit` が含まれていたら（または省略で implicit が既定適用されるなら）警告/拒否」を足す。省略対策と内容整合を一体で扱える。
- 方針C（呼び出し側で必ず指定させる）: core は現状維持とし、`packages/cli` の生成テンプレートが必ず `grant_types_supported` を渡すようにする。core の API は変えないが、生成 OP の広告のみ是正できる。実装は CLI 側。

## 8. タスク案

- [ ] `discovery.test.ts` に先行テスト（Red）:
  - [ ] `grantTypesSupported` 未指定時、出力メタデータが implicit を暗黙広告しない（既定で `authorization_code` を明示、または implicit を含まないことを固定）
  - [ ] refresh_token 提供構成での既定値の期待を固定
- [ ] 方針（A / B / C）を決定
- [ ] `buildProviderMetadata`（方針 A/B）または `packages/cli` テンプレート（方針 C）を修正
- [ ] 生成 OP の Discovery 出力が変わるため、`samples/*/conformance.test.ts`（生成元 `packages/cli`）の Discovery 検証を更新
- [ ] 完了条件: `pnpm --filter @maronn-openid-connect/core test` と各 sample の `conformance.test.ts` がパス

## 関連トピック

- `study-material/done/discovery-metadata-basic-op-self-consistency-guard.md` — `response_types_supported` / `subject_types_supported` / RS256 の自己整合。本ファイルは `grant_types_supported` の省略時既定という別軸。
- `study-material/done/discovery-token-endpoint-auth-methods-default-fidelity.md` — auth methods の既定 fidelity。
