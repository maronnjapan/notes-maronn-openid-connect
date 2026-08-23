# 拡張: OpenID Connect Client-Initiated Backchannel Authentication（CIBA）

## ステータス

🟢 拡張機能 / 未着手

## 1. このトピックで確認したいこと

CIBA（Client-Initiated Backchannel Authentication）は、**RP（典型はコールセンター、店舗 POS、Banking 等のサーバーサイドアプリ）が ユーザーの代わりに OP に認証開始リクエストを送る**フロー。OP はユーザーのスマートフォン等（Authentication Device）にプッシュ通知を送り、承認後に OP がトークンを返す。Decoupled Flow としても知られ、金融グレード（FAPI-CIBA）の標準フローとして欧州・日本の銀行で採用が進んでいる。

本リポジトリには CIBA の実装は無い。Basic OP の必須範囲ではないが、FAPI 関連の検証 PoC では必須となるため、導入是非を整理する。

> 🔐 CIBA もクロスデバイス・フローであり、**Cross-Device Consent / Session Phishing** の対象になりうる。
> 実装する場合の攻撃モデルと緩和策は `study-material/ext-cross-device-flows-security-bcp.md`
> （`draft-ietf-oauth-cross-device-security`）を前提とすること。

## 2. 関連する仕様・基準

共通の仕様索引は `study-material/basic-op-requirement-traceability.md` を参照。本トピック固有のポイント:

- **OpenID Connect Client-Initiated Backchannel Authentication Flow 1.0**:
  - 新規エンドポイント: **Backchannel Authentication Endpoint**（クライアントがユーザー識別子と要求 scope を POST）。
  - 3 つの配信モード:
    - **Poll**: クライアントが Token Endpoint を `grant_type=urn:openid:params:grant-type:ciba` で繰り返しポーリング。
    - **Ping**: OP が `client_notification_endpoint` に通知し、クライアントが Token Endpoint で受け取る。
    - **Push**: OP が `client_notification_endpoint` に **トークン本体**を直接 POST。
  - クライアントメタデータ拡張: `backchannel_token_delivery_mode`、`backchannel_client_notification_endpoint`、`backchannel_authentication_request_signing_alg`、`backchannel_user_code_parameter`。
  - リクエストにはユーザー識別子として `login_hint` / `login_hint_token` / `id_token_hint` のいずれか。
  - リクエスト署名（JWT 化）が CIBA Signed Request では必須。
- **FAPI-CIBA**: 上記に mTLS / DPoP / 署名済みリクエストを必須化したプロファイル。
- **Discovery 関連**:
  - `backchannel_authentication_endpoint`
  - `backchannel_token_delivery_modes_supported`（`["poll","ping","push"]`）
  - `backchannel_user_code_parameter_supported`
  - `backchannel_authentication_request_signing_alg_values_supported`
- **セキュリティ**:
  - User-to-OP 認証は OP が独自に行う（Authentication Device 連携は OP 実装依存）。
  - リクエスト署名（Signed Request）が無いと中間者が任意の `login_hint` でユーザーを巻き込める。
  - `auth_req_id` のエントロピー、期限管理。

## 3. 参照資料

- OpenID Connect CIBA 1.0: https://openid.net/specs/openid-client-initiated-backchannel-authentication-core-1_0.html
- FAPI-CIBA Profile: https://openid.net/specs/openid-financial-api-ciba.html
- 解説（IdP 実装視点）: https://openid.net/wg/fapi/specifications/

## 4. 現在の実装確認

- CIBA 関連の実装は無い。
- Authentication Device 連携 / プッシュ通知は無い。
- `ProviderMetadataConfig` に backchannel 系フィールド無し。
- `Token Endpoint` は `authorization_code` / `refresh_token` のみ。

## 5. 現在の実装との差分

- 🟢 **Basic OP プロファイル要件ではない**: 仕様違反ではない。
- 🟢 **広告の整合性**: 対応していないため広告無し（誤広告なし）。
- 🟡 **金融系 PoC ターゲット**: コンセプト「自分の要件がこの仕様で実現できるか」の中で「FAPI-CIBA の試行」ニーズが強い層がある。

## 6. 改善・追加を検討する理由

価値:

- CIBA は FAPI 2.0 系で重視される仕様。本リポジトリが将来 FAPI 系の検証ブリッジとして展開する場合、CIBA は中核要素。
- 既存の OSS で動く CIBA OP は限定的（Keycloak が一部対応、Authlete は商用）。OSS の選択肢として希少価値が高い。

導入難易度:

- 🔴 **影響大**:
  - 「OP が能動的にユーザーに連絡する」モデルは既存設計（HTTP 受動型）と異質。Push/Ping モードは OP からのアウトバウンド HTTP が必要。
  - Authentication Device の取り扱い（プッシュ通知サービス、Webhook、メール、SMS 等）は OP 実装に大きく依存する。
  - リクエスト署名（JWT 検証）は既存の `id_token_hint` 検証ロジックを応用できるが新規実装が増える。
- 🟡 **Cloudflare Workers との相性**:
  - サンプル環境（Workers）はアウトバウンド `fetch` 可能なので Push/Ping は技術的には可能。ただし長期ポーリングを伴う Poll は短時間応答前提の Workers と相性が中程度。

実装しない場合:

- FAPI-CIBA の検証は不可。一般的な OIDC / OAuth 2.1 検証には影響しない。

## 7. 実装方針の候補

### 方針A（非対応の明文化）

- `RELEASE-v0.x-scope.md` に「CIBA は v1.x 以降のロードマップ候補」と記載。

### 方針B（最小: Poll モードのみ）

- `Backchannel Authentication Endpoint` を追加し、`auth_req_id` を発行。
- `Token Endpoint` で `grant_type=urn:openid:params:grant-type:ciba` をサポート。
- 認可完了は OP の管理画面（または CLI）で手動承認できるサンプル UI を提供。
- Push / Ping は実装しない。
- リクエスト署名は **OPTIONAL**（後追いで追加）。

### 方針C（フルセット）

- Poll / Ping / Push を実装。Push は OP からクライアントの notification_endpoint へ ID Token + Access Token を POST。
- 署名済みリクエスト必須化を opt-in 化。
- Authentication Device 連携を抽象化した `AuthenticationDeviceResolver` を導入。

### 方針D（FAPI-CIBA 視点）

- Poll + mTLS + 署名済みリクエストの組合せで FAPI-CIBA Conformance を狙う。導入は方針 B → C → FAPI 拡張の段階。

判断材料:

- 「Speed（最新仕様に最速で追随）」軸で見れば優先度高い。
- 設計影響が大きいので、まずは方針 A で v0.x スコープ外を明示するのが現実的。需要が見えてきたら方針 B から段階導入。

## 8. タスク案

- [ ] 方針 A / B / C / D のどれを採用するかを人間が判断
- [ ] 方針 A 採用時: `RELEASE-v0.x-scope.md` への非スコープ記載のみ
- [ ] 方針 B 採用時:
  - [ ] `Backchannel Authentication Endpoint` ルートを CLI テンプレに追加
  - [ ] `auth_req_id` ストア（TTL 管理、状態遷移 pending → approved/denied/expired）
  - [ ] `Token Endpoint` に `grant_type=urn:openid:params:grant-type:ciba` 分岐
  - [ ] サンプル UI: 認可者が `auth_req_id` を承認/拒否できる管理画面
  - [ ] Discovery に `backchannel_authentication_endpoint` / `backchannel_token_delivery_modes_supported: ["poll"]` を広告
  - [ ] テスト: ユーザー識別子 → `auth_req_id` 発行 → 承認 → Token Endpoint Poll で `access_token` + ID Token 受領
- [ ] 方針 C 採用時: 上記 + Push/Ping 配信 + 署名済みリクエスト検証
- [ ] FAPI-CIBA 視点を入れるなら mTLS（`tasks/ext-mtls-rfc8705.md`）と署名リクエスト（`tasks/ext-jar-request-object-rfc9101.md`）が前提
