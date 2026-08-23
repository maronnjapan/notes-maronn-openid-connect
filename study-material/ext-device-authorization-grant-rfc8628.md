# 拡張: OAuth 2.0 Device Authorization Grant（RFC 8628）

## ステータス

🟢 拡張機能 / 未着手

## 1. このトピックで確認したいこと

入力デバイスに制約のある環境（スマート TV、CLI、IoT 機器）向けに、ユーザーは別デバイスのブラウザで認可し、デバイス側はバックチャネルで Token Endpoint をポーリングする **Device Authorization Grant**（RFC 8628）を本リポジトリに導入するかを整理する。

OIDC Basic OP の必須範囲ではないが、CLI 経由で動かせる検証ツールという本リポジトリの差別化軸と、CLI / IoT ユースケースの相性が良いため別ファイルで扱う。

> 🔐 実装する場合は、クロスデバイス・フローへの **Cross-Device Consent Phishing** 攻撃と
> その緩和策（短命・推測不能な `user_code`、レート制限、同意画面のコンテキスト提示等）を
> 前提とすること。攻撃モデルと緩和策は `study-material/ext-cross-device-flows-security-bcp.md`
> （`draft-ietf-oauth-cross-device-security`）で扱う。

## 2. 関連する仕様・基準

共通の仕様索引は `study-material/basic-op-requirement-traceability.md` を参照。本トピック固有のポイント:

- **RFC 8628**:
  - 新規エンドポイント: **Device Authorization Endpoint**（クライアントが `device_code` と `user_code` を取得）。
  - **Token Endpoint** に `grant_type=urn:ietf:params:oauth:grant-type:device_code` を追加。
  - **Verification URI**（`verification_uri` / `verification_uri_complete`）でユーザーがブラウザ認可。
  - エラーコード `authorization_pending` / `slow_down` / `access_denied` / `expired_token` をポーリング応答に追加。
  - `user_code` は表示しやすい形（例: 8 文字程度、`ABCD-EFGH`）。
- **OpenID Connect Core**: Device Flow 自体は OIDC Core に独立した記述は無い。`scope=openid` を含めて Device Flow を回せば ID Token も発行可能（実運用 IdP は OIDC Device Flow と呼ぶ）。
- **Discovery 関連**:
  - `device_authorization_endpoint`（RFC 8628 §4 推奨）。
  - `grant_types_supported` に `urn:ietf:params:oauth:grant-type:device_code` を追加。
- **OAuth 2.1**: Device Flow は OAuth 2.1 でも維持される（draft-ietf-oauth-v2-1 が RFC 8628 を参照）。Public Client は PKCE 適用が議論されているが、Device Flow は **`user_code` 経由のアクティベーションがあるため PKCE は適用されない**（OAuth 2.1 のセキュリティ Considerations を参照）。
- **セキュリティ Considerations（RFC 8628 §5）**:
  - `user_code` は推測困難なエントロピーを持たせる（推奨 21 bits 以上）。
  - User Interaction の間、Verification URI に CSRF / clickjacking 防御。
  - Polling interval を OP が制御（`slow_down` で広げる）。

## 3. 参照資料

- RFC 8628 OAuth 2.0 Device Authorization Grant: https://www.rfc-editor.org/rfc/rfc8628
- RFC 8628 §5（Security Considerations）: https://www.rfc-editor.org/rfc/rfc8628#section-5
- OAuth 2.1 draft（`draft-ietf-oauth-v2-1`）の Device Flow 言及: https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1
- OAuth 2.0 Security Best Current Practice（RFC 9700）: https://www.rfc-editor.org/rfc/rfc9700.html

## 4. 現在の実装確認

- Device Authorization Endpoint は無い（`packages/sample/src/oidc-provider/routes/` に該当ルート無し）。
- `Token Endpoint`（`packages/core/src/token-request.ts`）は `authorization_code` / `refresh_token` のみ。`urn:ietf:params:oauth:grant-type:device_code` はサポート外。
- `ProviderMetadataConfig` に `device_authorization_endpoint` フィールドは無い。
- Discovery 広告の `grant_types_supported`（T-021 で追加予定）にも device_code は入っていない。

## 5. 現在の実装との差分

- 🟢 **Basic OP プロファイル必須要件ではない**: 仕様違反ではない。
- 🟢 **広告の整合性**: 対応していないため広告もしていない。
- 🟡 **CLI ベースの利用者層**: 本リポジトリは CLI ツールでフロー実装コードを生成する性質上、CLI / TV / IoT 系で Device Flow を試したい利用者と相性が良い。

## 6. 改善・追加を検討する理由

価値:

- 「自分の要件がこの仕様で実現できるか」を検証したい層のうち、**Device Flow は試したい IdP 機能の上位**（スマート TV、ゲーム機、Apple TV、AWS CLI、`gcloud auth login` などで実体験している人が多い）。
- 既存実装（`authorization_code` + `refresh_token`）と独立度が高く、影響範囲が限定的。
- Refresh Token Rotation（既実装）と Device Flow は自然に組み合わせ可能。
- OAuth 2.1 でも維持され仕様の安定度が高い。

導入難易度:

- 🟢 **コアロジックは比較的小さい**: device_code / user_code の生成、ポーリング状態管理、`slow_down` 制御。
- 🟡 **ストレージ I/F の追加が必要**: `DeviceCodeStore` のような新規 resolver/store。既存の `AuthorizationCodeResolver` のパターンに沿わせやすい。
- 🟡 **CLI テンプレート追加**: `packages/cli/src/frameworks/hono/templates.ts` に Device Endpoint と Token Endpoint 拡張を追加。
- 🟢 **既存の verification UI を流用可能**: ログイン／同意のサンプル UI（`routes/login.ts`、`routes/consent.ts`）をそのまま `verification_uri` のフローに再利用できる。

実装しない場合:

- CLI / IoT ユースケースの PoC は不可。

## 7. 実装方針の候補

### 方針A（非対応の明文化）

- `RELEASE-v0.x-scope.md` に「v0.x 非スコープ」明記。後続で検討。

### 方針B（最小: OAuth 2.0 Device Flow のみ）

- `Device Authorization Endpoint`（`/device_authorization`）を追加。
- `Token Endpoint` に `device_code` grant を追加。
- `user_code` は 8 文字英数字（衝突しないよう一意性を担保）。
- Polling interval は固定 5 秒、`slow_down` で +5 秒。
- ID Token も発行（`scope=openid` を含む場合）。

### 方針C（フルセット: + Verification URI Complete + QR コード生成例）

- `verification_uri_complete`（`user_code` 埋め込み）対応。
- CLI テンプレートにスマート TV 風サンプル UI を追加。
- QR コード生成は CLI 生成コード側でオプション提供（外部依存ライブラリ無しで Web 標準 SVG を生成）。

判断材料:

- 方針 B でも OSS 体験としては十分に強い。CLI ベース利用者には「初めて Device Flow を回せた」という体験価値が大きい。
- 方針 C は機能としては魅力的だが、QR 生成等は本来のスコープ外。CLI テンプレ提供の範囲に留めれば core を膨らませずに済む。

## 8. タスク案

- [ ] 方針 A / B / C のどれを採用するかを人間が判断
- [ ] 方針 B 採用時:
  - [ ] `packages/core/src/device-code.ts`（新規）: device_code / user_code 生成、状態遷移（pending → approved/denied、期限切れ）
  - [ ] `DeviceCodeStore` I/F を `token-request.ts` の resolver パターンに沿わせる
  - [ ] `Token Endpoint`（`token-request.ts`）に `device_code` grant 分岐を追加（既存 PKCE 分岐とは独立、PKCE は適用しない）
  - [ ] `Discovery` の `ProviderMetadataConfig` に `deviceAuthorizationEndpoint` 追加
  - [ ] CLI テンプレートに `/device_authorization` ルート、`verification_uri` ページを追加
  - [ ] テスト: device_code 発行 → user_code 入力 → token endpoint で `authorization_pending` → 承認 → `access_token` + ID Token 発行 までを通すフローテスト
- [ ] セキュリティ Considerations (RFC 8628 §5) のうち少なくとも以下をテストで固定:
  - [ ] `user_code` のエントロピー（衝突しないこと）
  - [ ] `slow_down` 応答後のポーリング間隔が広がること
  - [ ] device_code の期限切れ後は `expired_token` を返すこと
