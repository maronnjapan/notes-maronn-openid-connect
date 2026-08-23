# 拡張: OpenID Connect for Identity Assurance 1.0（検証済みクレーム / eKYC）

## ステータス

🟢 拡張機能 / 未着手

## 1. このトピックで確認したいこと

「身分証で本人確認を済ませた eKYC ベンダー OP」「銀行 OP」「政府 OP」が、検証済み属性を RP に渡すための仕様 **OpenID Connect for Identity Assurance 1.0（eKYC-IDA）**。

- 標準クレームではない「検証済み」コンテキスト（誰が・いつ・どんなプロセスで・どんな証拠で検証したか）を `verified_claims` クレームで表現する。
- 関連仕様:
  - OpenID Connect for Identity Assurance 1.0（プロトコル本体）
  - OpenID Connect for Identity Assurance Claims（追加標準クレーム）
  - OpenID Connect Advanced Syntax for Claims（ASC）— claims request の表現力を拡張

本リポジトリは標準クレーム（OIDC Core §5.1）と `claims` パラメータ（OIDC Core §5.5）対応済みだが、**`verified_claims` の取り扱いは未実装**。

本ファイルは「本ライブラリが eKYC PoC として使えるようにするか」「拡張機能としてどこまでスコープするか」の判断材料を整理する。

## 2. 関連する仕様・基準

### 2.1 OIDC for Identity Assurance 1.0 概要

- 新しいクレーム種 **`verified_claims`** を ID Token / UserInfo に含める。構造:
  ```json
  {
    "verified_claims": {
      "verification": {
        "trust_framework": "jp_aml",
        "time": "2025-03-15T12:00:00Z",
        "verification_process": "...",
        "evidence": [{...}]
      },
      "claims": {
        "given_name": "Taro",
        "family_name": "Yamada",
        "birthdate": "1990-01-01"
      }
    }
  }
  ```
- `trust_framework`（jp_aml / de_aml / eidas_ial_high 等）が業界・国別で定義される。
- `evidence` は身分証画像のハッシュ、立会人検証、第三者検証 API ID 等の構造化記録。
- `claims` パラメータ拡張: `verified_claims` メンバーで「どの trust_framework のどのクレームを返してほしいか」を細かく要求できる（OIDC Core §5.5 の拡張）。

### 2.2 関連 OIDC 拡張

- **Advanced Syntax for Claims (ASC)**: `claims` パラメータの `essential`/`value`/`values` に加えて、Identity Assurance 用の追加修飾子（`max_age`、`purpose` 等）を導入。
- **Identity Assurance Claims**: 追加標準クレーム（`place_of_birth`、`nationalities`、`birth_family_name` 等）。
- **OpenID for Verifiable Credentials**（OID4VCI / OID4VP）: より新しい VC 連携仕様。eKYC-IDA とは別系統だが、検証済み属性の配信という目的は近い。

### 2.3 業界ユースケース

- 銀行口座開設、不動産契約、保険契約、医療記録、未成年保護、年齢確認（飲酒・喫煙）など。
- 日本では eKYC（犯収法改正に伴う本人確認）プロセスとの結合が中心。

## 3. 参照資料

- OpenID Connect for Identity Assurance 1.0: https://openid.net/specs/openid-connect-4-identity-assurance-1_0.html
- OpenID Connect for Identity Assurance Claims 1.0: https://openid.net/specs/openid-connect-4-identity-assurance-claims-1_0.html
- OpenID Connect Advanced Syntax for Claims 1.0: https://openid.net/specs/openid-connect-advanced-syntax-for-claims-1_0.html
- OpenID Foundation IDA Working Group: https://openid.net/wg/ekyc-ida/
- 関連: `tasks/done/p0-claims-id-token-support.md`（`claims` パラメータの基本実装）、`study-material/userinfo-endpoint-comprehensive.md`

## 4. 現在の実装確認

- `claims` パラメータの JSON parse + ID Token / UserInfo 反映: `packages/core/src/userinfo.ts`、`tasks/done/p0-claims-id-token-support.md`。
- 標準クレーム（OIDC Core §5.1）の scope ベース反映: `SCOPE_CLAIMS_MAP`（`packages/core/src/userinfo.ts`）。
- **`verified_claims` クレームは未実装**:
  - `UserClaims` 型（`packages/core/src/userinfo.ts`）に `verified_claims` フィールド無し。
  - `ClaimRequestEntry`（`claims` パラメータ要素型）に Identity Assurance の修飾子（`purpose` 等）無し。
  - ID Token / UserInfo 出力時、`verified_claims` のネスト構造に対応するフィルタリングロジック無し。
- Discovery 関連メタデータ未広告:
  - `verified_claims_supported`、`trust_frameworks_supported`、`evidence_supported`、`documents_supported`、`claims_in_verified_claims_supported`、`attachments_supported` など。
- 仕様の本体は **属性配送の表現拡張**であり、本ライブラリのコア（トークン発行）と独立した「クレーム整形層」の拡張で実現できる。

## 5. 現在の実装との差分

- **満たしていること**: `claims` パラメータ全般の I/F、標準クレーム反映パス、scope フィルタ。これらは Identity Assurance の **claims 配送のベース**として活用できる。
- **不足している可能性があること**
  - `UserClaims` 型に `verified_claims` を追加し、`filterClaimsByScope` / `applyClaimsParameter` 系で **ネスト構造のフィルタ**を扱えるよう拡張。
  - `claims` パラメータの top-level `verified_claims` メンバー解釈（`{ verification: {...}, claims: {...} }` 構造の要求）。
  - `purpose` 修飾子の同意画面表示（CLAIMS 取得の目的を End-User に提示する仕様）。
  - Discovery メタデータの追加（`verified_claims_supported: true` ほか）。
  - UserInfo Endpoint の `verified_claims` 反映パス。
  - 検証エビデンスの保存と取り出しは **resolver 側責務**（`UserClaimsResolver` の戻り値構造を拡張可能にしておく）。
- **設計観点**
  - `verified_claims` を core が「ネスト型」として丸ごと通す設計が筋。`UserClaims` 型を `Record<string, unknown>` ベースにしているなら無修正で済む。型安全性を上げるなら専用型を import 可能にする。
  - フル準拠は規模大（trust_framework のレジストリ参照、evidence の構造検証）。**「core は素通しのみ、検証は resolver」** が最小スコープ。

## 6. 改善・追加を検討する理由

- 金融・行政・医療系の PoC では **eKYC-IDA の動作確認**が要件化されつつある（日本含む）。本ライブラリの「OSS で素早く検証」というコンセプトに直結。
- 既存 `claims` パラメータ実装の延長で **「素通しレベルの対応」は低コスト**で達成可能。
- フル対応（trust_framework 検証、evidence 構造検証）は重い。スコープ分割が現実的。
- 実装しない場合の制約: eKYC / VC 系 PoC のシナリオ検証ができず、本ライブラリの対象ユースケースから金融系が抜け落ちる。

## 7. 実装方針の候補

### 方針A（推奨・段階導入）: 素通しレベルから

- `UserClaims` 型を `Record<string, unknown>` 互換のまま `verified_claims?: unknown` を許容する形に拡張。
- `claims` パラメータの top-level `verified_claims` 要求も受理し、`UserClaimsResolver` に「要求されたかどうか」を渡す。検証の中身は resolver 責務。
- ID Token / UserInfo 出力時、`verified_claims` をネスト構造のまま素通し。`filterClaimsByScope` の対象外（scope と verified_claims は直交）。
- Discovery: `verified_claims_supported: true` を core builder で設定可能に。
- ドキュメント: `UserClaimsResolver` 実装ガイドに「`verified_claims` を返す方法」「`trust_framework` の選定」を明記。

### 方針B（拡張）: 標準値検証ヘルパー

- 主要 `trust_framework`（jp_aml、de_aml、eidas_ial_high など）の許可リスト、`evidence` の最小構造（`type` 必須等）をバリデートするヘルパーを提供。
- 強制ではなく診断目的。

### 方針C（フル準拠）: ASC 全機能 + Documents/Attachments

- `purpose` 修飾子の同意画面連携、`documents` 添付の Base64 配送、`attachments` の外部 URL 参照などまで含む。
- 規模大。FAPI-eKYC プロファイル前提のときに検討。

### 方針D（非対応の明文化）

- ロードマップ記載のみ。

## 8. タスク案

- [ ] 方針A/B/C/D を選択する（ユーザー判断）。`tasks/done/p0-claims-id-token-support.md` の延長として方針A が現実解
- [ ] テスト先行: `claims.verified_claims = { verification: {...}, claims: {...} }` を含むリクエストを受理して resolver に渡すフローを検証
- [ ] テスト先行: `UserClaimsResolver` が `verified_claims` を返した場合、ID Token / UserInfo にそのまま出力されること
- [ ] `UserClaims` 型と `applyClaimsParameter` 系の拡張
- [ ] Discovery: `verified_claims_supported` 等メタデータの core builder 対応
- [ ] `UserClaimsResolver` 実装ガイド更新（`resolver-and-store-contract.md` に追記）
- [ ] 方針B 採用時: `trust_framework` 許可リスト / `evidence` 構造検証のヘルパー
- [ ] 完了条件: core / cli テストパス、`verified_claims` が UserInfo 応答にネスト構造のまま出力されること
