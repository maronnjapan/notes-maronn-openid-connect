# Discovery `claim_types_supported`：クレームタイプの広告とディスカバリ正直性

## ステータス

🟢 Low / 未着手（検討中）

## 1. このトピックで確認したいこと

OpenID Provider Metadata（`/.well-known/openid-configuration`）に、本 OP が
サポートする **Claim Type** を示す `claim_types_supported` フィールドを出すべきか、
出す場合に何を出すべきかを確認する。

具体的な論点は次の 2 点に絞る。

1. **正確性の補正**: `study-material/distributed-aggregated-claims.md` は
   「Discovery に専用フィールドは無い」と記述しているが、これは事実誤認である。
   OIDC Discovery 1.0 §3 は **`claim_types_supported`** という専用フィールドを定義している。
   本ファイルでこの点を一次情報で確定し、関連ファイルの記述を補正する。
2. **広告すべき値**: 本 OP は Normal Claims のみをサポートし、Aggregated /
   Distributed Claims（OIDC Core §5.6.2）は未実装である。この実態を Discovery で
   `claim_types_supported: ["normal"]` として明示するか、省略（＝デフォルト挙動に委ねる）
   するかを判断する。

※ クレーム値そのもの（`claims_supported`）や Aggregated/Distributed Claims の
実装可否は別トピックで扱う。本ファイルは **「クレームタイプの広告フィールド」** に限定する。

## 2. 関連する仕様・基準

共通の仕様索引は `study-material/basic-op-requirement-traceability.md` を参照。
他の Discovery 推奨/オプションフィールドの扱いは以下で既出のため、ここでは繰り返さない。

- `study-material/discovery-optional-metadata-fields.md`
  （`ui_locales_supported` / `claims_locales_supported` / `acr_values_supported` /
  `display_values_supported`）
- `tasks/T-021-discovery-metadata.md`
  （`grant_types_supported` / `token_endpoint_auth_methods_supported` /
  `claims_parameter_supported` / `request_parameter_supported` /
  `request_uri_parameter_supported` / `scopes_supported` / `claims_supported`）
- `study-material/discovery-code-challenge-methods-supported.md`
  （`code_challenge_methods_supported`）
- `study-material/distributed-aggregated-claims.md`
  （Aggregated/Distributed Claims 本体の実装可否。本ファイルとは「広告フィールド」 vs
  「クレーム提供機構」で役割が分かれる）

本トピック固有の仕様ポイント：

### 2.1 OIDC Discovery 1.0 §3 — `claim_types_supported`

OpenID Provider Metadata の定義（OpenID Connect Discovery 1.0, Section 3,
"OpenID Provider Metadata"）に次のフィールドがある。

> `claim_types_supported`
> OPTIONAL. JSON array containing a list of the Claim Types that the OpenID
> Provider supports. These Claim Types are described in Section 5.6 of OpenID
> Connect Core 1.0. Values defined by this specification are `normal`,
> `aggregated`, and `distributed`. If omitted, the implementation supports only
> `normal` Claims.

ポイント：

- **OPTIONAL** フィールドである。Basic OP として必須ではない。
- 値は `normal` / `aggregated` / `distributed` の 3 種（OIDC Core §5.6 で定義）。
- **省略時のデフォルトは `normal` のみサポート**と解釈される。
  → つまり本 OP の実態（Normal のみ）は、省略していても仕様上は正しく伝わる。

### 2.2 OIDC Core 1.0 §5.6 — Claim Types

- **§5.6.1 Normal Claims**: Claim 値が UserInfo / ID Token の中に直接含まれる通常形式。
  本 OP の `filterClaimsByScope`（`packages/core/src/userinfo.ts`）が返すのはこれ。
- **§5.6.2 Aggregated Claims / Distributed Claims**: 第三者（Claim Provider）が発行した
  クレームを集約（`_claim_sources` に JWT を埋め込む）または分散参照（エンドポイント＋
  アクセストークンで後から取得）する形式。本 OP は未対応
  （`study-material/distributed-aggregated-claims.md` 参照）。

### 2.3 ディスカバリ正直性の原則（既出パターンの再利用）

「OP は実際に対応している挙動のみを広告し、未対応を広告しない／未対応を明示する」
という方針は、本リポジトリで既に確立されている。

- `study-material/request-object-rejection-and-discovery-honesty.md`
  （`request_parameter_supported: false` を出して未対応を明示）
- `study-material/done/oauth21-removed-grants-explicit-rejection.md`
  （削除済み grant を `grant_types_supported` に出さない）

`claim_types_supported` も同じ原則の適用対象である。「`["normal"]` を明示する」か
「省略してデフォルト（normal のみ）に委ねる」かのどちらでも仕様準拠だが、
**実態と広告の一貫性**という観点では、明示しておくとクライアント／適合性テストにとって
判断が容易になる。

## 3. 参照資料

- OpenID Connect Discovery 1.0 §3 "OpenID Provider Metadata"（`claim_types_supported` の定義、OPTIONAL、省略時 `normal`）
  https://openid.net/specs/openid-connect-discovery-1_0.html#ProviderMetadata
- OpenID Connect Core 1.0 §5.6 "Claim Types"（Normal / Aggregated / Distributed の定義）
  https://openid.net/specs/openid-connect-core-1_0.html#ClaimTypes
- OpenID Connect Core 1.0 §5.6.1 "Normal Claims"
  https://openid.net/specs/openid-connect-core-1_0.html#NormalClaims
- OpenID Connect Core 1.0 §5.6.2 "Aggregated and Distributed Claims"
  https://openid.net/specs/openid-connect-core-1_0.html#AggregatedDistributedClaims

## 4. 現在の実装確認

- `packages/core/src/discovery.ts`
  - `ProviderMetadataConfig` / `ProviderMetadata` インターフェースに
    `claim_types_supported`（および入力側 `claimTypesSupported`）は **存在しない**。
  - `buildProviderMetadata()` は `claims_supported` までは扱うが、`claim_types_supported`
    は出力しない（L37, L83, L199-201 が `claims_supported`。claim_types は未定義）。
- `packages/core/src/userinfo.ts`
  - `filterClaimsByScope()` は Normal Claims のみを返す。`_claim_names` / `_claim_sources`
    を生成する経路は無い → 実態は **Normal のみ**で確定。
- 既存ドキュメントの記述誤り
  - `study-material/distributed-aggregated-claims.md` L24:
    「**Discovery**: 専用フィールドは無いが、`claims_supported` の運用上 …」
    → §2.1 の通り `claim_types_supported` が専用フィールドとして存在するため、この記述は誤り。

## 5. 現在の実装との差分

- **満たしていること**
  - 実態（Normal Claims のみ）は、`claim_types_supported` を省略したときの仕様上の
    デフォルト解釈（`normal` のみ）と **一致している**。したがって現状でも仕様違反ではない。
- **不足している可能性があること**
  - `claim_types_supported` を能動的に広告する手段が無い。クライアントや適合性テストが
    「この OP は Aggregated/Distributed をサポートしないと明示しているか」を読み取りたい場合、
    現状は省略により暗黙に伝わるのみ。
- **相互運用性の観点**
  - 🟢 多くのクライアントライブラリは `claim_types_supported` 省略時に `normal` を仮定する
    ため、相互運用上の実害は小さい。明示は「分かりやすさ」のための追加であり、必須ではない。
- **正確性の観点（ドキュメント）**
  - 🟡 `distributed-aggregated-claims.md` の事実誤認は、将来 Aggregated/Distributed を
    検討する際の前提を誤らせる可能性があるため補正すべき。
- **Basic OP として提供する上で確認すべきこと**
  - OIDF Basic OP Certification は `claim_types_supported` を必須要件としていない
    （Basic OP は Normal Claims を前提とする）。したがって本項目は **任意（拡張的正直性）**
    であり、Basic OP 適合性の合否には影響しない見込み。

## 6. 改善・追加を検討する理由

- **なぜ価値があるか**: ディスカバリ正直性の一貫性。本リポジトリは
  `request_parameter_supported: false` 等で「未対応の明示」を既に重視しており、
  `claim_types_supported: ["normal"]` を出すことはその方針と整合する。
- **Basic OP 必須か拡張か**: **拡張（任意）**。Basic OP の合否には影響しない。
  実装の透明性・相互運用性を高める「あると良い」レベル。
- **導入しやすさ**: 非常に容易。`discovery.ts` の `buildProviderMetadata()` は既に
  「配列が空なら省略する」パターンを多数持つため（`scopes_supported` 等）、同型の
  オプションフィールドを 1 つ追加するだけで済む。新しい依存も状態も不要。
- **既存実装との接続**: `ProviderMetadataConfig` にオプション入力
  `claimTypesSupported?: string[]` を足し、空でなければ出力に写すだけ。
  CLI 生成コード（`samples/*/.well-known/openid-configuration`）はデフォルトで
  `["normal"]` を渡す構成にできる。
- **利用者メリット**: PoC 利用者が「このライブラリは Normal Claims のみ」という前提を
  Discovery から機械的に確認でき、Aggregated/Distributed を試したい場合に
  「未対応である」ことが明示される。
- **実装しない場合のリスク/制約**: 実害は小さい（省略でデフォルト解釈される）。
  ただしドキュメントの事実誤認を残すと、将来の設計判断を誤らせるリスクがある。
  → このリスクは「ドキュメント補正」だけでも解消できる（実装は任意）。

## 7. 実装方針の候補

最終判断は人間が行う。以下は判断材料の整理。

### 方針A（ドキュメント補正のみ・実装は見送り）
- `distributed-aggregated-claims.md` の事実誤認を補正し、本ファイルへの参照を追加する。
- `discovery.ts` には手を入れない（省略によりデフォルト `normal` 解釈で十分とみなす）。
- メリット: 最小コスト。仕様準拠は維持。
- デメリット: 「未対応の明示」を能動的には行わない。

### 方針B（`claim_types_supported` を任意フィールドとして実装）
- `ProviderMetadataConfig.claimTypesSupported?: string[]` を追加し、空でなければ
  `claim_types_supported` として出力（既存の `scopes_supported` 等と同型の分岐）。
- CLI 生成コードのデフォルトを `["normal"]` にする（利用者が上書き可能）。
- メリット: ディスカバリ正直性の一貫性。将来 Aggregated/Distributed を足すときの
  広告口が用意される。
- デメリット: 実装・テスト・CLI 生成側の追従が必要（小規模）。

### 方針C（discovery オプションフィールド一括対応に合流）
- 本項目を単独実装せず、`study-material/discovery-optional-metadata-fields.md`
  の「方針A（全フィールド一括追加）」に `claim_types_supported` も含めて一緒に実装する。
- メリット: discovery オプションフィールドの追加を 1 回の変更で集約できる。
- デメリット: 一括対応の着手時期に引きずられる。

## 8. タスク案

- [ ] **（必須・小）** `study-material/distributed-aggregated-claims.md` の
      「専用フィールドは無い」記述を補正し、`claim_types_supported`（OIDC Discovery §3）の
      存在と本ファイルへの参照を追記する。
- [ ] **（任意）** `discovery.ts` の `ProviderMetadataConfig` / `ProviderMetadata` に
      `claimTypesSupported` / `claim_types_supported` を追加し、空配列なら省略する分岐を実装。
- [ ] **（任意）** 値検証：`normal` / `aggregated` / `distributed` 以外の値が渡された場合の
      扱い（拒否 or 通過）を決める。本 OP の実装上は `["normal"]` のみを許容するのが安全。
- [ ] **（任意）** CLI 生成コードの Discovery レスポンスに `claim_types_supported: ["normal"]`
      を出力し、生成後コードのテストで固定値を検証する。
- [ ] **（任意）** `discovery.test.ts` に「`claimTypesSupported` 未指定なら出力に含まれない」
      「`["normal"]` 指定で `claim_types_supported: ["normal"]` を出力する」を追加。
