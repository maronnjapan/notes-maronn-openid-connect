# クライアント登録メタデータ `default_acr_values` のフォールバック honoring

## このトピックで確認したいこと

認可リクエストが `acr_values` を省略したとき、そのクライアントが登録した **`default_acr_values`**（既定の要求 ACR）をフォールバックとして適用できているかを確認する。

現状は認可リクエストの `acr_values`（および `claims.id_token.acr.values`）だけが `AcrResolver` に伝播し、クライアント登録の既定値は一切参照されない。兄弟メタデータである `default_max_age` は既にフォールバック実装済み（`study-material/done/client-default-max-age-and-require-auth-time.md` / `tasks/done/p2-client-default-max-age-fallback.md`）であり、同じパターンが `default_acr_values` には拡張されていない、という差分を扱う。

ACR 解決ロジック・`acr_values` の ID Token への伝播そのものは既存ファイルで扱い済みのため、本ファイルは **「クライアント既定値フォールバック」の差分のみ** を扱う。

## 関連する仕様・基準

- **OpenID Connect Dynamic Client Registration 1.0 §2**（Client Metadata）
  `default_acr_values`:
  > Default requested Authentication Context Class Reference values. Array of strings that specifies the default `acr` values that the OP is being requested to use for processing requests from this Client, with the values appearing in order of preference. … The `acr_values` request parameter or an individual `acr` Claim request via the `claims` request parameter **supersedes these default values**.

  すなわち、リクエストに `acr_values`（または `claims.id_token.acr`）が無いとき、OP はクライアント登録の `default_acr_values` を「要求された ACR」として扱う。リクエスト値があればそちらが優先。

- **OpenID Connect Core 1.0 §3.1.2.1 / §5.5.1.1**
  `acr_values` は要求された ACR の順序付き優先リスト（Voluntary Claim）。`claims.id_token.acr.values` と等価に扱える（§5.5.1.1）。本リポジトリは後者を既に seed 済み（`token-response.ts` L299-311）だが、クライアント既定値は未 seed。

### 既存ファイルとの関係（重複回避）

- `study-material/done/acr-values-request-propagation-to-id-token.md` / `tasks/done/p2-acr-values-request-propagation.md` — **リクエストの** `acr_values` を ID Token `acr` に伝播する話。`default_acr_values`（クライアント既定）は対象外（grep 済みで該当なし）。
- `tasks/done/T-015-acr-amr-resolver.md` / `study-material/amr-values-guidance-rfc8176.md` — `AcrResolver` 機構と amr ガイド。クライアント既定フォールバックは無い。
- `study-material/done/client-default-max-age-and-require-auth-time.md` — 兄弟メタデータ `default_max_age` / `require_auth_time` の honoring（**実装済み**）。本ファイルは同パターンの `acr` 版という位置づけ。
- `study-material/done/client-metadata-enforcement.md` — grant/response/auth-method/scope のみ。

## 参照資料

- OpenID Connect Dynamic Client Registration 1.0, §2 "Client Metadata"（`default_acr_values` の定義と "supersedes these default values"）
  https://openid.net/specs/openid-connect-registration-1_0.html#ClientMetadata
- OpenID Connect Core 1.0, §3.1.2.1 "Authentication Request"（`acr_values`）
  https://openid.net/specs/openid-connect-core-1_0.html#AuthRequest
- OpenID Connect Core 1.0, §5.5.1.1 "Requesting the acr Claim"
  https://openid.net/specs/openid-connect-core-1_0.html#acrSemantics

## 現在の実装確認

- `packages/core/src/authorization-request.ts`
  - **L983: `const acrValues = effective.acr_values;`** — リクエストの `acr_values` をそのまま採用。`client.defaultAcrValues` へのフォールバックは無い。
  - 対照的に L967-976 では `max_age` が無いとき `client.defaultMaxAge` にフォールバック（`validateDefaultMaxAge`）している。**同じ分岐が `acr_values` には存在しない。**
  - `ClientInfo`（L124 付近）は `defaultMaxAge` を持つが `defaultAcrValues` を持たない。
- `packages/core/src/token-response.ts`
  - L299-311: `effectiveRequestedAcrValues` は `requestedAcrValues` と `claims.id_token.acr.values` からのみ導出。クライアント既定へのフォールバックは無く、`AcrResolver` コンテキスト（`{ userId, clientId, requestedAcrValues }`）にも渡らない。
- CLI テンプレート
  - `packages/cli/src/frameworks/hono/templates.ts` `RegisteredClient`（L433-437）／`defaultRegisteredClients`（L443-460）に `defaultAcrValues` フィールドは無い（`defaultMaxAge: 3600` はある）。
  - L2346 付近: `requestedAcrValues` は `validatedRequest.acrValues`（= 認可リクエスト由来）のみを渡す。
- リポジトリ全体で `default_acr_values` / `defaultAcrValues` の出現は **0 件**（コード・テスト・サンプル・docs）。

## 現在の実装との差分

- **満たしていること**
  - リクエスト `acr_values` / `claims.id_token.acr.values` の伝播と ID Token `acr` 発行は正しく動く。
  - 兄弟の `default_max_age` フォールバックは実装済みで、拡張のためのパターンが既にある。
- **不足している可能性があること**
  - クライアントが `default_acr_values` を登録しても無視される。DCR §2 の「リクエスト省略時は既定値を要求 ACR とする」を満たさない。
- **相互運用性の観点**
  - `default_max_age` は尊重するのに `default_acr_values` は尊重しない、という非対称は、DCR メタデータを一貫して扱う RP から見て予測を裏切る。
- **Basic OP として提供する上で確認すべきこと**
  - `default_acr_values` は Basic OP certification の**必須要件ではない**（Basic は Code Flow / PKCE / RS256 / UserInfo / `prompt` が中核で、ACR は任意）。よって Basic OP 合否には直接影響しない。ただし ACR/step-up を扱う場合の仕様忠実性・一貫性の向上として有用。

## 改善・追加を検討する理由

- **なぜ価値があるか**：`default_max_age` を既に honor している以上、対になる `default_acr_values` を欠くのは一貫性の穴。ACR ベースのポリシー（step-up・保証レベル）を検証したい利用者が、クライアント単位の既定 ACR を宣言できるようになる。
- **Basic OP 必須か拡張か**：必須ではない。DCR メタデータ honoring の完成度を上げる拡張寄りの整合改善。ただし実装コストが小さく、既存パターンの延長で入るため費用対効果は高い。
- **導入しやすさ**：`default_max_age` と完全に同型。`authorization-request.ts` L983 に「リクエスト値が無ければ `client.defaultAcrValues` を採用」する 1 分岐を足し、`ClientInfo`／`RegisteredClient` にフィールドを追加するだけ。`AcrResolver` の入力は既存の `requestedAcrValues` チャネルにそのまま乗る。
- **利用者メリット**：クライアントごとに「このクライアントは常に LoA2 を要求」といった既定を宣言でき、毎リクエストで `acr_values` を付けずに済む。
- **実装しない場合のリスク**：ACR 既定をクライアント側で表現できず、RP が全リクエストに `acr_values` を明示せざるを得ない。DCR §2 準拠を謳えない。

## 実装方針の候補

> 最終判断は人間が行う。以下は判断材料。

1. **`default_max_age` と同型のフォールバック（推奨）**
   - `ClientInfo`／`RegisteredClient` に `defaultAcrValues?: string[]`（または空白区切り `string`）を追加。
   - `authorization-request.ts` L983 で `effective.acr_values ?? client.defaultAcrValues?.join(' ')` に変更。DCR §2 のとおりリクエスト値が優先。
   - 検証：`default_acr_values` の各要素が非空文字列であること（形式検証）。空配列は「未指定」と同義に正規化。
2. **`token-response.ts` 側で seed する案**
   - `effectiveRequestedAcrValues` の導出（L302-311）に、リクエスト・`claims` の両方が無いときのクライアント既定フォールバックを追加。ただし `token-response` は `clientId` は持つが client オブジェクト全体を持たないため、呼び出し側（テンプレート）で解決して渡す必要があり、方針 1 より配線が増える。
3. **保留**：ACR/step-up の方向性が固まるまで据え置き、`ext-step-up-authentication-rfc9470.md` や Discovery `acr_values_supported`（`discovery-optional-metadata-fields.md`）と合流させる。

方針 1 が既存パターンと最も整合し、差分が最小。

## タスク案

- [ ] `ClientInfo`（core）と `RegisteredClient`（CLI テンプレート）に `defaultAcrValues` を追加し、resolver 契約に反映する。
- [ ] `authorization-request.ts` で `acr_values` 省略時に `client.defaultAcrValues` へフォールバックする（リクエスト値優先）。要素の非空検証を入れる。
- [ ] 単体テスト（`default_max_age` テストを踏襲）：
  - [ ] リクエストに `acr_values` が無く `defaultAcrValues` がある → その値が `AcrResolver` の `requestedAcrValues` に渡る。
  - [ ] リクエストの `acr_values` は `defaultAcrValues` より優先される。
  - [ ] 両方無ければ `acrValues` は `undefined` のまま。
  - [ ] `claims.id_token.acr.values` があるときはそれが `defaultAcrValues` より優先される（§5.5.1.1）。
- [ ] `conformance.test.ts` 生成元（`packages/cli`）を更新し、CLI 生成 OP でも本契約を検証する。
- [ ] README／コメントに、生成コードをカスタマイズする利用者向けに `default_acr_values` の意味論（リクエスト値が supersede する）を明記する。
