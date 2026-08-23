# Distributed Claims / Aggregated Claims（OIDC Core §5.6.2）

## ステータス

🟢 拡張機能 / 未着手

## 1. このトピックで確認したいこと

OIDC Core 1.0 §5.6.2 は、UserInfo / ID Token のクレームを **OP が直接持たず、第三者発行のクレームを参照／封入する**仕組みを定義する:

- **Aggregated Claims**: OP が他クレーム発行元（Claim Provider）の **JWT をクレームに封入**して返す。
- **Distributed Claims**: OP が他クレーム発行元の **エンドポイントとアクセストークンを返し**、RP が後でフェッチする。

この機構は、認証 OP（identity）とクレーム発行 OP（属性プロバイダ）の分離、複合 ID Provider、ID 連携の高度な検証で重要。本リポジトリには未実装。Basic OP プロファイルの必須範囲ではないが、Conformance Suite には distributed/aggregated claims のテストが含まれており、OIDC を網羅する OSS としては「対応するか／非対応を明示するか」が問われる。

## 2. 関連する仕様・基準

共通の仕様索引は `study-material/basic-op-requirement-traceability.md` を参照。本トピック固有のポイント:

- **OIDC Core 1.0 §5.6.2 Normal, Aggregated, and Distributed Claims**:
  - Normal Claim: クレーム値を JSON にそのまま入れる（既実装）。
  - **Aggregated Claim**: UserInfo / ID Token に `_claim_names` / `_claim_sources` メタ構造を作り、`_claim_sources.<source>.JWT` として **発行元 OP が署名した JWT**を埋め込む。
  - **Distributed Claim**: `_claim_sources.<source>.endpoint` と `_claim_sources.<source>.access_token` を埋め込み、RP が後で fetch。
- **Discovery**: OIDC Discovery 1.0 §3 は **クレームタイプ専用フィールド `claim_types_supported`** を定義している（値: `normal` / `aggregated` / `distributed`、OPTIONAL、省略時は `normal` のみサポートと解釈）。本 OP は Normal Claims のみ対応のため、省略（＝デフォルト `normal`）でも、`["normal"]` 明示でも仕様準拠となる。広告フィールドそのものの扱いは `study-material/discovery-claim-types-supported.md` を参照。`claims_supported` の運用上「集約／分散で提供される可能性のあるクレーム」も列挙してよい。
- **セキュリティ Considerations（OIDC Core §5.6.2.3）**:
  - 集約 JWT は signed であること（RFC 7515）、`iss` がクレーム発行元、`sub` が end-user の subject。
  - 分散の `access_token` は短命で限定スコープ。
  - フェッチ先 endpoint への RP からのアクセスは別 TLS 経路。

## 3. 参照資料

- OIDC Core 1.0 §5.6.2: https://openid.net/specs/openid-connect-core-1_0.html#AggregatedDistributedClaims
- OIDC Core 1.0 §5.6.2.3 Claim Stability and Uniqueness: https://openid.net/specs/openid-connect-core-1_0.html#ClaimStability

## 4. 現在の実装確認

- `packages/core/src/userinfo.ts`:
  - クレームの「scope ベース絞り込み」「`claims` リクエストパラメータ対応」は実装済み。
  - Distributed / Aggregated claims の構造（`_claim_names` / `_claim_sources`）を組み立てる経路は無い。
- ID Token（`token-response.ts` / `id-token.ts`）も同様、`_claim_names` を出力する経路は無い。
- 外部クレーム発行元の信頼関係（Claim Provider の JWKS / signing key 検証）も無い。

## 5. 現在の実装との差分

- 🟢 **Basic OP プロファイル必須要件ではない**: 仕様違反ではない。
- 🟢 **広告整合性**: 対応していないため Aggregated/Distributed の広告は無し。`claim_types_supported` を明示する場合は `["normal"]` に限定する（`study-material/discovery-claim-types-supported.md`）。
- 🟡 **`claims_supported` の意味**: Discovery で広告するクレーム一覧（既存タスク T-021 が扱う）に、Distributed/Aggregated 由来のクレームを含めるかは別議論。
- 🟡 **検証 PoC としての価値**: 複合 ID 環境（KYC 業者 + 認証 OP の組合せ）の検証は不可。

## 6. 改善・追加を検討する理由

価値:

- KYC / eKYC 連携、政府発行属性（マイナンバー、運転免許など）の取り扱い PoC で必要になりうる。
- 商用 IdP では Auth0 / Keycloak は限定的サポート、Connect2id は対応している。OSS としての特色になる。
- 実装規模は限定的（メタ構造 + 注入 I/F）で、コア設計を壊さない。

導入難易度:

- 🟢 **アーキ的に小さい**: クレーム resolver から特別な戻り値（`{ _aggregated: { JWT } }` 形式）を返せば core が組み立て可能。
- 🟡 **Aggregated の JWT 検証は呼び出し側**: OP は受け取った JWT を「そのまま埋める」のが普通。事前検証ポリシーは利用者判断。

実装しない場合:

- 複合 ID PoC は不可。一般 OIDC ユースケースには影響なし。

## 7. 実装方針の候補

### 方針A（非対応の明文化）

- `RELEASE-v0.x-scope.md` に「v0.x スコープ外、後続候補」と記載。

### 方針B（クレーム resolver 拡張・最小）

- `UserClaimsResolver` の戻り値型に `_claim_names` / `_claim_sources` を直接含められる形を許容（あるいは別 resolver `getAggregatedClaims` / `getDistributedClaims` を追加）。
- core 側は受け取った構造をそのまま `userinfo` / `id_token` に注入。
- 集約 JWT の検証 / 分散 endpoint の整合性は利用者責務。

### 方針C（フルセット）

- 上記 + 集約 JWT の事前検証ヘルパー（signing alg 制約・期限チェック）、`Claim Provider Resolver` I/F。
- Discovery `claims_supported` の運用拡張。

判断材料:

- 方針 B は手数少なく、需要に応じてオプトイン。
- 方針 C は OSS 体験として強いが、ユースケースの絶対数が少ない。
- まず方針 A で v0.x を出し、ユーザー要望が来たら方針 B → C の順が現実的。

## 8. タスク案

- [ ] 方針 A / B / C のどれを採用するかを人間が判断
- [ ] 方針 B 採用時:
  - [ ] `UserClaimsResolver` 拡張 or 別 resolver の I/F 設計（`_claim_names` / `_claim_sources` を返せるようにする）
  - [ ] `userinfo.ts` / `token-response.ts` で構造を埋め込む実装
  - [ ] テスト: aggregated（JWT 埋め込み）/ distributed（endpoint + access_token）の出力構造、Normal claim と並列に出るケース
- [ ] 方針 C 採用時: 上記 + 集約 JWT の signing 検証ヘルパー、Claim Provider Resolver I/F、Discovery 整合
- [ ] 既存 `study-material/userinfo-endpoint-comprehensive.md` から本ファイルへ「§5.6.2 は別ファイル」とリンク
