# Discovery における `claims` 機能の広告整合性（`claims_supported` の内容 / `claims_parameter_supported`）

## ステータス

🟠 High / 未着手

## 1. このトピックで確認したいこと

CLI 生成 Provider の Discovery ドキュメント（`/.well-known/openid-configuration`）が、
**この OP が実際にサポートしている `claims` 関連機能を正直に広告できているか**を確認する。

具体的には次の 2 点を扱う。

1. `claims_supported` の **内容**が、OP が実際に発行するクレームと一致しているか。
   現状は ID Token のプロトコルクレーム（`auth_time` / `nonce` / `acr` / `amr` / `azp` / `at_hash`）が
   配列から漏れており、OP が発行できるのに「供給できない」と広告している。
2. `claims_parameter_supported` が広告されていない（= 既定値 `false`）にもかかわらず、
   `claims` リクエストパラメータは ID Token / UserInfo の両経路で実装済みである、という不整合。

> 関連既存ファイル：
> - `study-material/done/discovery-claim-types-supported.md` は **`claim_types_supported`**（別フィールド）を扱う。本ファイルは扱わない。
> - `tasks/done/p1-basic-op-conformance-standard-user-claims.md` は UserInfo **fixture** の整備で、Discovery の広告内容は扱っていない。
> - `tasks/done/p0-claims-id-token-support.md` は `claims` パラメータの `id_token` 対応を実装した「ゲート」タスクで、
>   「`claims` を `id_token`/`acr` に対応させるまで `claims_parameter_supported` を広告しない」と明記していた。
>   そのゲート条件は既に満たされている。
> - `tasks/T-021-discovery-metadata.md` は本件のフィールドを計画として列挙しているが「未着手」表記のまま陳腐化しており、
>   実際には大半のフィールドが実装済み。残課題は本ファイルが扱う 2 点に集約される。
>   よって仕様の一般説明は繰り返さず、**差分（実装と広告のズレ）**のみを扱う。

## 2. 関連する仕様・基準

- **OpenID Connect Discovery 1.0 §3（OpenID Provider Metadata）**
  - `claims_supported`: *RECOMMENDED*。「OP が値を供給できる（MAY be able to supply）クレーム名の JSON 配列」。
    あくまで広告であり MUST not の網羅義務はないが、**実際に供給できるものを過少申告すると相互運用性を損なう**。
  - `claims_parameter_supported`: Boolean。「OP が `claims` パラメータをサポートするかどうか。
    省略時の既定値は `false`」。`true` を出さない限り、仕様準拠の RP は `claims` を送ってこない。
- **OpenID Connect Core 1.0 §2 / §3.1.3.6**: `auth_time` / `nonce` / `acr` / `amr` / `azp` / `at_hash` は
  ID Token のクレームとして定義される。これらは「クレーム」であり、`claims_supported` に載せる候補。
- **OpenID Connect Core 1.0 §5.5（Requesting Claims using the "claims" Request Parameter）**: `claims` パラメータの定義。

## 3. 参照資料

- OpenID Connect Discovery 1.0 §3:
  https://openid.net/specs/openid-connect-discovery-1_0.html#ProviderMetadata
  - `claims_supported` の定義（「MAY be able to supply」）
  - `claims_parameter_supported` の定義（省略時 `false`）
- OpenID Connect Core 1.0 §2（ID Token）/ §3.1.3.6（ID Token, `at_hash`）/ §5.5（claims parameter）:
  https://openid.net/specs/openid-connect-core-1_0.html

## 4. 現在の実装確認

- Discovery メタデータは全フレームワーク共通の単一テンプレート `discoveryRouteTemplate` で生成される
  （`packages/cli/src/frameworks/hono/templates.ts` 内、web-standard 系も同テンプレートを共有）。
- `claims_supported` の生成: `packages/cli/src/frameworks/hono/templates.ts:1992-2017`
  - 出力は `sub, iss, aud, exp, iat` ＋ profile/email/address/phone スコープ系クレームのみ。
  - `auth_time` / `nonce` / `acr` / `amr` / `azp` / `at_hash` は**含まれていない**。
- 一方 core の ID Token はこれらを発行する:
  - `packages/core/src/id-token.ts:21-25`（`auth_time` / `nonce` / `acr` / `amr` を宣言）
  - `packages/core/src/id-token.ts:122-130`（`azp` の付与処理）
  - `at_hash` は ID Token に付与される（`id-token` 系の既存タスク `id-token-at-hash-algorithm-agility` 参照）。
- `claims_parameter_supported`: `discoveryRouteTemplate`（同ファイル 1977-2054 付近）で **一度も設定されていない**
  → Discovery 既定で `false` 扱い。
- ただし `claims` パラメータ自体は実装・配線済み:
  - `templates.ts:1539-1541`（ID Token へ `claims` 伝播）
  - `templates.ts:1559-1562`（UserInfo 用に永続化）
  - `templates.ts:1749-1757`（UserInfo で `claimsParameter` を利用）
- core 側はフィールドを既にサポート: `packages/core/src/discovery.ts:49, 227-229`
  （`claimsParameterSupported` 設定を受理しメタデータに反映）。**テンプレートの配線だけが欠落**している。

## 5. 現在の実装との差分

- **満たしていること**
  - `claims` パラメータの機能本体（ID Token / UserInfo 両経路）は実装済み。
  - core の `buildProviderMetadata` は両フィールドを表現可能。
- **不足している可能性があること（過少広告）**
  - `claims_supported` に、OP が実発行する `auth_time` / `nonce` / `acr` / `amr` / `azp` / `at_hash` が欠落。
  - `claims_parameter_supported: true` が出ておらず、既定 `false` のまま。
- **相互運用性の観点**
  - メタデータ駆動の RP が `claims_supported` をフィルタに使うと、`acr`/`amr`/`auth_time` を
    「供給不可」と誤認しうる。
  - 仕様準拠 RP は `claims_parameter_supported` が `false`（既定）だと `claims` を送らない。
    本リポジトリが `p0-claims-id-token-support` で投資した機能が、広告不足で使われない。
- **Basic OP として確認すべきこと**
  - `claims_supported` / `claims_parameter_supported` は Basic OP の必須テスト対象ではない（RECOMMENDED / 任意）。
    ただし「Fidelity（仕様忠実）」を差別化軸とする本リポジトリでは、実装と広告の不一致は説明責任上きれいでない。

## 6. 改善・追加を検討する理由

- **Fidelity の観点**: 実装しているのに広告しない／発行するのに供給不可と申告する、という不整合は
  本リポジトリの中核的価値（仕様忠実）を直接損なう。
- **導入しやすさ**: core はフィールドを既にサポート済み。修正は `discoveryRouteTemplate` の文字列追加と
  `claimsParameterSupported: true` の 1 行追加に限定され、影響範囲が狭い。
- **既存実装との接続**: `claims` パラメータ機能は配線済みのため、広告を実態に合わせるだけ。
- **利用者メリット**: PoC 開発者が Discovery を見て `claims`/`acr`/`amr` の検証可否を判断できる。
- **実装しない場合のリスク**: `claims` 機能が「あるのに使われない」死蔵状態が続き、
  メタデータ駆動 RP との相互運用検証ができない。

## 7. 実装方針の候補

判断材料の整理（最終判断は人間）。

### `claims_supported` の内容

- 方針A（推奨）: ID Token プロトコルクレーム `auth_time`, `nonce`, `acr`, `amr`, `azp`, `at_hash` を追加する。
  （`c_hash` は Hybrid Flow 未対応のため現時点では含めない。導入時に追加。）
- 方針B: 「`claims_supported` は OP が必ず供給できるものに限定する」という解釈を採り、
  `acr`/`amr` のように resolver 依存で供給されないことがあるクレームは敢えて出さない。
  → ただし「MAY be able to supply」の文言からは方針A の方が自然。

### `claims_parameter_supported`

- 方針A（推奨）: `claimsParameterSupported: true` を `discoveryRouteTemplate` に追加。
- 方針B: あえて広告しない（= 機能を隠す）。`p0-claims-id-token-support` のゲート条件は満たしているため、
  隠す積極的理由は乏しい。

### 共通

- conformance テスト（`samples/*/conformance.test.ts` を生成する CLI 側）に Discovery のアサーションを追加し、
  リグレッションを固定する。`CLAUDE.md` の方針どおり、conformance.test.ts は直接編集せず生成元 CLI を変更する。

## 8. タスク案

- [ ] `claims_supported` に `auth_time`, `nonce`, `acr`, `amr`, `azp`, `at_hash` を追加（CLI テンプレート）
- [ ] `claims_parameter_supported: true` を `discoveryRouteTemplate` に追加
- [ ] conformance テスト生成元に Discovery のアサーション（両フィールド）を追加し、4 フレームワークで固定
- [ ] `tasks/T-021-discovery-metadata.md` のステータスを実態に合わせて整理（残課題が本 2 件であることを明記）
- [ ] 完了条件: `pnpm --filter @maronn-openid-connect/cli test` と各 sample の conformance テストがパス
