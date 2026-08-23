# RFC 8414 OAuth 2.0 Authorization Server Metadata と `/.well-known/oauth-authorization-server`

## ステータス

🟡 Minor（相互運用性）/ 未着手

## 1. このトピックで確認したいこと

本リポジトリは OIDC Discovery 1.0 の `/.well-known/openid-configuration` を実装している。一方、RFC 8414 で標準化された **OAuth 2.0 Authorization Server Metadata** は `/.well-known/oauth-authorization-server` で配信される、OAuth 2.0/2.1 のメタデータ仕様（OIDC を前提としない）。

両者は **メタデータ項目が大きく重複するが、配信パスとフィールド集合が微妙に異なる**:

- `/.well-known/openid-configuration`: OIDC 関連項目（`subject_types_supported`、`id_token_signing_alg_values_supported`、`userinfo_endpoint` 等）を含む。
- `/.well-known/oauth-authorization-server`: OAuth 2.0 の Authorization Server Metadata。OIDC 固有項目は無いが、`introspection_endpoint`、`revocation_endpoint`、`code_challenge_methods_supported` などは元々こちらが本籍。

ここでは:

- 両者の関係（特に `code_challenge_methods_supported` の本籍が RFC 8414）
- 本リポジトリで両エンドポイントを提供する価値
- 既存タスク（`tasks/T-021-discovery-metadata.md`、`study-material/discovery-code-challenge-methods-supported.md`）との接続

を整理する。

## 2. 関連する仕様・基準

共通の仕様索引は `study-material/basic-op-requirement-traceability.md` を参照。本トピック固有のポイント:

- **RFC 8414**:
  - メタデータパス: `https://<issuer>/.well-known/oauth-authorization-server`（issuer に path がある場合のパス挿入規則は §3 参照）。
  - メタデータ項目: `issuer`、`authorization_endpoint`、`token_endpoint`、`jwks_uri`、`registration_endpoint`、`scopes_supported`、`response_types_supported`、`response_modes_supported`、`grant_types_supported`、`token_endpoint_auth_methods_supported`、`token_endpoint_auth_signing_alg_values_supported`、`service_documentation`、`ui_locales_supported`、`op_policy_uri`、`op_tos_uri`、`revocation_endpoint`、`revocation_endpoint_auth_methods_supported`、`revocation_endpoint_auth_signing_alg_values_supported`、`introspection_endpoint`、`introspection_endpoint_auth_methods_supported`、`introspection_endpoint_auth_signing_alg_values_supported`、`code_challenge_methods_supported`。
  - メタデータの **署名付き提供（Signed Metadata, §2.1）**: 任意。
- **OIDC Discovery 1.0 §3**:
  - パスは `/.well-known/openid-configuration`。
  - RFC 8414 のフィールドの **大半は重複**しているが、OIDC 固有（`subject_types_supported`、`id_token_*`、`userinfo_*`、`acr_values_supported` 等）が追加されている。
- **`code_challenge_methods_supported` の本籍**:
  - もともと RFC 7636（PKCE）→ RFC 8414 で正式に AS Metadata 化。OIDC Discovery 1.0 には**載っていない**（OIDC Discovery 1.0 は 2014 発行で PKCE は 2015）。多くの実装は OIDC Discovery の `/.well-known/openid-configuration` にも入れて返している（事実上のデファクト）。
  - 既存 `study-material/discovery-code-challenge-methods-supported.md` を参照。
- **OAuth 2.1 §3.1**: OAuth 2.1 では AS Metadata（RFC 8414）に従う旨を明示。`code_challenge_methods_supported` を必須項目として扱う立場。

## 3. 参照資料

- RFC 8414 OAuth 2.0 Authorization Server Metadata: https://www.rfc-editor.org/rfc/rfc8414
- RFC 8414 §3.1（well-known URI 構築規則）: https://www.rfc-editor.org/rfc/rfc8414#section-3.1
- OIDC Discovery 1.0: https://openid.net/specs/openid-connect-discovery-1_0.html
- OAuth 2.1 §3.1: https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1

## 4. 現在の実装確認

- `/.well-known/openid-configuration` のみ実装（`packages/sample/src/oidc-provider/routes/discovery.ts`）。
- `/.well-known/oauth-authorization-server` ルートは無い。
- `buildProviderMetadata`（`packages/core/src/discovery.ts:135`）は OIDC Discovery 1.0 用の出力フォーマット。RFC 8414 専用の出力は無い。
- ただし RFC 8414 固有のフィールド（`introspection_endpoint`、`revocation_endpoint`、`introspection_endpoint_auth_methods_supported`、`revocation_endpoint_auth_methods_supported`）は `ProviderMetadataConfig` に既に追加されている（`discovery.ts:53-59`）。

## 5. 現在の実装との差分

満たしていること:

- 主要な OAuth AS メタデータフィールドは `/.well-known/openid-configuration` 経由で広告可能（事実上のデファクト経路）。
- `introspection_endpoint` / `revocation_endpoint` 関連の RFC 8414 由来フィールドは `ProviderMetadataConfig` に存在。

不足／要確認:

- 🟡 **`/.well-known/oauth-authorization-server` パスが無い**: 厳密に RFC 8414 だけを期待するクライアント（OAuth 2.0 / 2.1 だが OIDC を使わない）は **このパスにフェッチに来る**。404 を返す現状だと、クライアントは自力で AS Metadata を組まないと相互運用できない。
- 🟡 **OAuth 2.1 準拠を掲げる本リポジトリの姿勢**: CLAUDE.md は「OAuth 2.1 準拠（PKCE 必須）」を明示している。OAuth 2.1 は RFC 8414 を参照しているため、`/.well-known/oauth-authorization-server` を提供することが筋。
- 🟡 **issuer 値に path が含まれる場合の RFC 8414 §3.1 挙動**: well-known パスを issuer 末尾に追加するか、issuer の host 直下に置くかの規則がある。実装する場合はこれを正しく組み込む必要がある。
- 🟢 **既存 OIDC Discovery 経路は OIDC RP に対して充足**: OIDC を使うクライアントは既に問題なく動作。

## 6. 改善・追加を検討する理由

価値:

- OAuth 2.1 準拠を掲げるなら **両エンドポイント提供がより正確**。OIDC を必要としない純粋な OAuth 2.0/2.1 検証 PoC で動作する。
- 商用 IdP（Auth0、Okta、Keycloak 等）は両方のパスを提供することが多く、互換性体験が揃う。
- 実装コストは小さい: `buildProviderMetadata` の **OIDC 固有フィールドを取り除いた版**を返すルートを追加するだけ。

導入難易度:

- 🟢 **極小**: 既存 `buildProviderMetadata` 出力から OIDC 専用フィールドを抜く / RFC 8414 専用フィールドだけを並べるバリアントを追加。
- 🟡 **issuer に path がある場合の well-known パス計算**は注意（`https://example.com/tenant1` → `https://example.com/.well-known/oauth-authorization-server/tenant1`）。

実装しない場合:

- OAuth 2.1 検証 PoC で OIDC を使わない場合の互換性が落ちる（致命的ではない）。
- 本リポジトリの「OAuth 2.1 準拠」表明と Discovery 提供の整合性が弱い。

## 7. 実装方針の候補

### 方針A（OIDC Discovery 経路のみで通す）

- `/.well-known/openid-configuration` 1 本に統一し、OAuth-only クライアント向けには「このパスを参照してください」とドキュメントで案内。
- `RELEASE-v0.x-scope.md` に「RFC 8414 well-known 経路は v0.x スコープ外」と明記。

### 方針B（両エンドポイントを提供 / 最小）

- `buildAuthorizationServerMetadata(config)` を `packages/core/src/discovery.ts` に追加（OIDC 専用フィールドを除外）。
- `/.well-known/oauth-authorization-server` ルートを CLI テンプレに追加。
- issuer に path がある場合の well-known パス挿入規則（RFC 8414 §3.1）を実装。
- 既存の OIDC Discovery 経路はそのまま。

### 方針C（同一実装で両方を返す / シンプル）

- 同じメタデータを両パスから返す。技術的には合法（OIDC Discovery のフィールドが追加されているだけで矛盾はしない）。
- パス追加だけで済み、ロジックは共通。

判断材料:

- 方針 C はコスト最小だが、厳密な RFC 8414 クライアントが OIDC 固有フィールドを見て困惑する可能性は小さい（RFC 8414 §2 は追加メタデータの存在を許容している）。
- 方針 B は正確だが「2 つのメタデータ表現が乖離する」運用負荷が出る。
- 方針 A は割り切り。OAuth 2.1 準拠を強調するなら採用しづらい。

## 8. タスク案

- [ ] 方針 A / B / C のどれを採用するかを人間が判断
- [ ] 方針 B / C 採用時:
  - [ ] `/.well-known/oauth-authorization-server` ルートを CLI テンプレに追加
  - [ ] issuer に path がある場合の well-known URI 規則を `buildProviderMetadata` 共通化、または専用ヘルパーで実装
  - [ ] テスト: OIDC 経路と OAuth 経路で `issuer` 等の重複フィールドが一致すること
  - [ ] テスト: 方針 B の場合、OIDC 固有フィールド（`subject_types_supported` 等）が OAuth 経路には含まれないこと
  - [ ] テスト: `code_challenge_methods_supported` が両経路で同値であること（既存 `discovery-code-challenge-methods-supported.md` と整合）
- [ ] 方針 A 採用時: `RELEASE-v0.x-scope.md` に非スコープ記載、README に「OAuth-only クライアントは `/.well-known/openid-configuration` 参照」と案内
