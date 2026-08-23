# 拡張: Dynamic Client Registration（OIDC DCR 1.0 / RFC 7591）

## ステータス

🟢 拡張機能 / 未着手

## 1. このトピックで確認したいこと

`registration_endpoint` はメタデータ型に存在するが**実装が無い**。
動的クライアント登録（OIDC DCR 1.0 / RFC 7591）を提供すべきか、
特に **OpenID 認定テストの利便性**と PoC 体験の観点で確認する。

## 2. 関連する仕様・基準

- **OpenID Connect Dynamic Client Registration 1.0**
  - `registration_endpoint` に Client Metadata（`redirect_uris`,
    `token_endpoint_auth_method`, `grant_types`, `response_types`,
    `post_logout_redirect_uris`, `jwks`/`jwks_uri`, `subject_type` 等）を POST。
  - レスポンスに `client_id`/`client_secret`/`client_id_issued_at`/
    `client_secret_expires_at`/`registration_access_token`/`registration_client_uri`。
  - エラー: `invalid_redirect_uri` / `invalid_client_metadata`。
- **RFC 7591（OAuth 2.0 Dynamic Client Registration）** / **RFC 7592（管理プロトコル）**。
- **OpenID 認定（OP テスト手順）**: Basic/Implicit/Hybrid 認定時、DCR をサポートしていれば
  テストで利用できる（無ければ手動登録）。**Basic OP の必須要件ではない**
  （`tasks/basic-op-requirements-baseline.md` 参照、Basic OP 定義は重複記載しない）。

## 3. 参照資料

- OIDC Dynamic Client Registration 1.0:
  https://openid.net/specs/openid-connect-registration-1_0.html
- RFC 7591: https://www.rfc-editor.org/rfc/rfc7591
- RFC 7592: https://www.rfc-editor.org/rfc/rfc7592
- OpenID 認定（OP テスト手順）: https://openid.net/certification/connect_op_testing/

## 4. 現在の実装確認

- メタデータ型に `registrationEndpoint?` / `registration_endpoint?` は **定義済み**
  （`discovery.ts:35,77` 周辺）が、出力するだけで**登録エンドポイント本体は無し**。
- クライアントは静的登録前提: `ClientResolver.findClient`（`authorization-request.ts:95-97`）、
  sample の `resolvers.ts` / `config.ts` に固定登録。
- `ClientInfo` は `clientId` / `redirectUris` / `clientType` のみ。
  動的登録に必要な `token_endpoint_auth_method` 等のメタデータ表現が薄い。

## 5. 現在の実装との差分

- **満たしていること**: Discovery 出力に `registration_endpoint` を載せる口はある。
  クライアント解決は resolver 抽象なので、登録の永続化先は利用者が差し替えやすい。
- **不足している可能性があること**
  - 登録エンドポイント本体（メタデータ検証・`client_id`/`client_secret` 発行・
    `redirect_uris` 検証・エラーコード）。
  - クライアントメタデータの型（現状 `ClientInfo` が最小限）。
  - 登録アクセストークン／RFC 7592 の更新・削除（任意）。
- **相互運用性**: DCR があると OpenID Conformance Suite が自動でクライアントを作れ、
  **認定テストの反復が大幅に楽になる**（Fidelity 軸の運用効率に直結）。

## 6. 改善・追加を検討する理由

- 「Conformance 準拠を信頼性シグナルとして維持」する運用で、DCR は
  認定テスト自動化の生産性を上げる（手動 3 クライアント登録が不要）。
- PoC 体験として「CLI 生成 → 起動 → クライアント自動登録」は強力な導線。
- resolver 抽象があるため**永続化は利用者責務に切り出せる**＝ core 責務を肥大化させずに導入可。
- 実装しない場合の制約: 認定テストごとに手動クライアント登録が必要。
  動的登録前提のクライアント／IdP 移行検証ができない。

## 7. 実装方針の候補

### 方針A（core 検証 + 永続化注入）

- core に「Client Metadata 検証 → 正規化 → 発行値（client_id/secret/issued_at 等）算出」
  の純関数を追加（`redirect_uris` の構文・`token_endpoint_auth_method` 妥当性・
  `invalid_redirect_uri`/`invalid_client_metadata` 判定）。
- 登録の永続化は `ClientRegistrationStore` 的 I/F を注入（既存 resolver 思想と一貫）。
- Discovery に `registration_endpoint`（既に出力可。CLI/sample で URL を config）。
- CLI/sample に `/register` ルートと in-memory store スタブ生成。
- 認証付き登録（Initial Access Token）は任意・config。

### 方針B（最小・オープン登録）

- 認証なしのオープン登録 + in-memory のみ（PoC 専用）。RFC 7592 管理は対象外。

### 方針C（非対応の明文化）

- 当面手動登録前提を明記。Discovery から `registration_endpoint` を出さない。

## 8. タスク案

- [ ] 方針A/B/C を選択（ユーザー判断）。Initial Access Token 必須化の既定も決定
- [ ] Client Metadata 検証・発行値算出・エラーコードのテストを先行作成
- [ ] core: 登録検証ヘルパー + `ClientRegistrationStore` I/F
- [ ] クライアントメタデータ型の拡張（`token_endpoint_auth_method` 等）と
      既存 `ClientInfo`/`TokenClientInfo` との整合設計（/design-discussion で協議し確定設計を記録）
- [ ] Discovery `registration_endpoint` を CLI/sample config から出力
- [ ] CLI/sample に `/register` ルート生成
- [ ] 完了条件: core / cli テストがパス
