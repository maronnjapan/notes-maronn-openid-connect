# 拡張: OAuth 2.0 Identity and Authorization Chaining Across Domains（ドメイン間 ID 連鎖）

## ステータス

🟢 拡張機能 / 未着手

## 1. このトピックで確認したいこと

`draft-ietf-oauth-identity-chaining`（RFC Editor queue 入り、Proposed Standard 予定）は、**複数の信頼ドメイン（それぞれ別の Authorization Server を持つ）をまたいでエンドユーザーの ID と認可コンテキストを引き継ぐ**ための「合成プロファイル」である。新しい grant type を定義するのではなく、**既存の RFC 8693（Token Exchange）と RFC 7523（JWT Bearer Authorization Grant）を 2 段で連結する**ことで実現する。

このファイルで確認したいのは:

- 本リポジトリが RFC 8693 / RFC 7523 を **まだ実装していない**という前提の再確認（= identity chaining は「その 2 つを入れた先」の応用トピック）
- どちらの AS 役割（発行側 AS-A / 受領側 AS-B）を本 OP が担うかで実装差分が大きく変わる点の整理
- Token Endpoint の grant type ディスパッチ（現状 `authorization_code` / `refresh_token` のみ）への接続点

> RFC 8693 と RFC 7523 それぞれの詳細仕様は既存ファイルで扱う。重複させない。
> - Token Exchange: `study-material/ext-token-exchange-rfc8693.md`
> - JWT Bearer Authorization Grant: `study-material/ext-jwt-bearer-authorization-grant-rfc7523.md`
> 本ファイルは **2 つを連結する identity chaining 固有の差分**に絞る。

## 2. 関連する仕様・基準

### 2.1 解決する問題

クラウド/ハイブリッド環境で、サービスが**別々の AS を持つ複数ドメインをまたいで**下流 API を呼ぶとき、エンドユーザーの identity と認可を安全に伝播したい。素朴に AS-A のアクセストークンを AS-B に渡しても、AS-B はそれを検証・受容できない（信頼境界が違う）。

### 2.2 2 段フロー（draft の中核）

**Phase 1 — AS-A で Token Exchange（RFC 8693）**
- クライアントは AS-A のトークンエンドポイントへ:
  - `grant_type=urn:ietf:params:oauth:grant-type:token-exchange`
  - `resource` または `audience`（**REQUIRED**、対象 AS-B を識別）
  - `scope`（OPTIONAL、transcribe されるクレームを制御）
- 受け取るのは **`aud` を AS-B に限定した JWT authorization grant**（アクセストークンではなく「AS-B へ提示するための授権 JWT」）。

**Phase 2 — AS-B で JWT Bearer Grant（RFC 7523）**
- クライアントは AS-B のトークンエンドポイントへ:
  - `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer`
  - `assertion=<Phase 1 の JWT>`（**REQUIRED**）
  - `scope` または `resource`（RFC 8707 準拠）
- 受け取るのは **AS-B のリソース向けアクセストークン**。

### 2.3 メタデータ / セキュリティ（本トピック固有）

- 新メタデータ: `identity_chaining_requested_token_types_supported`（サポートする要求トークンタイプの列挙）。
- セキュリティ考慮:
  - クライアント認証は OAuth 2.0 Security BCP §2.5 に従う。
  - JWT authorization grant は **短命**にし、可能なら **単回使用**に制限。
  - **クロスドメインの refresh token は非推奨**（期限切れ時はクライアントが再度 exchange する）。
  - クレーム transcription は両ドメイン間で意味論の合意が必要。

## 3. 参照資料

- draft-ietf-oauth-identity-chaining-17（Identity and Authorization Chaining Across Domains、RFC Editor queue）:
  https://datatracker.ietf.org/doc/draft-ietf-oauth-identity-chaining/
  - 2 段フロー（AS-A で token-exchange → AS-B で jwt-bearer）
  - `resource`/`audience` 必須、`assertion` 必須
  - `identity_chaining_requested_token_types_supported` メタデータ
  - Security: 短命・単回・クロスドメイン refresh 非推奨・claims transcription の合意
- RFC 8693（OAuth 2.0 Token Exchange）: https://www.rfc-editor.org/rfc/rfc8693
- RFC 7523（JWT Profile for OAuth 2.0 Client Authentication and Authorization Grants）: https://www.rfc-editor.org/rfc/rfc7523
- RFC 8707（Resource Indicators）: https://www.rfc-editor.org/rfc/rfc8707
  （本リポジトリ内: `study-material/ext-resource-indicators-rfc8707.md`）
- OAuth 2.0 Security BCP（RFC 9700）§2.5: https://www.rfc-editor.org/rfc/rfc9700

## 4. 現在の実装確認

- Token Endpoint の grant ディスパッチは `validateTokenRequest`（`packages/core/src/token-request.ts:367-431`）にあり、
  **提供 grant は `authorization_code` と `refresh_token` のみ**（`DEFAULT_SUPPORTED_GRANT_TYPES`、`token-request.ts:254`）。
  - 未サポート grant は RFC 6749 §5.2 の `unsupported_grant_type` で拒否（`ext-oauth-client-credentials-grant.md` 等と同じ拒否経路）。
- **`urn:ietf:params:oauth:grant-type:token-exchange` / `:jwt-bearer` は未実装**。
- JWT の署名/検証基盤は既にある（`id-token.ts`, `jwks.ts`, `request-object.ts` の JWS 検証、`inbound-jws-verification-crit-and-alg-binding.md`）ため、assertion 検証の下地は流用可能。
- Discovery メタデータ生成は `discovery.ts` の `buildProviderMetadata`（`identity_chaining_*` フィールドは未定義）。

## 5. 現在の実装との差分

- **満たしていること / 流用できる点**:
  - JWS 署名・検証、`aud`/`iss`/`exp` 検証、鍵解決（`jwks`/`jwks_uri`）の基盤があり、Phase 2 の `assertion` 検証や Phase 1 の JWT 発行に再利用できる。
  - grant type トグル（`supportedGrantTypes`）機構があるので、新 grant の追加口は用意されている。
- **不足していること**:
  - RFC 8693 / RFC 7523 自体が未実装（前提ブロッカー）。identity chaining はこの 2 つの**上に載る**ため、単独では着手できない。
  - AS-A 役割: `resource`/`audience` を受けて **AS-B 限定 `aud` の短命 JWT grant** を発行するロジックが無い。
  - AS-B 役割: `jwt-bearer` assertion の検証（発行元 AS-A の信頼、`aud` == 自分、`exp` 短命、単回使用の replay 防止）が無い。
  - `identity_chaining_requested_token_types_supported` を Discovery で advertise できない。
- **セキュリティ上の要確認**:
  - JWT grant の **単回使用（replay 防止）**は、本リポジトリの authorization code / refresh token の「used マーク」機構（`store` 契約）と同型で実装できるが、grant の `jti` 管理が要る。
  - クロスドメイン信頼（AS-A をどう信頼するか）は設定/ポリシー領域で、OSS としては「信頼する issuer/JWKS を利用者が明示設定」する形が安全。
- **相互運用性**: マルチテナント/マルチドメイン検証（`study-material/issuer-multitenancy-and-subpath.md` と関連）で有用。
- **Basic OP として**: 対象外の純拡張。

## 6. 改善・追加を検討する理由

- **価値**: マイクロサービス/マルチクラウドで「ドメインをまたぐ委譲」を検証したい PoC 開発者に刺さる。本ライブラリの「最新仕様を最速で試す」コンセプトに沿い、RFC Editor queue 入りの成熟ドラフトなので追随価値が高い。
- **Basic OP 必須か拡張か**: 拡張。
- **導入しやすさ**: 中〜高難度。**RFC 8693 と RFC 7523 の実装が前提**で、それ単体でも大きい。identity chaining はその薄い連結レイヤ（`resource`→`aud` 限定 JWT 発行、`assertion` 受領）にすぎないので、2 つが入れば追加コストは比較的小さい。
- **既存実装との接続**: grant トグル + JWS 基盤 + store の used マーク（単回使用）に自然に接続。
- **メリット**: 利用者はクロスドメイン委譲の設計（信頼境界・claims transcription・トークン寿命）を、実 HTTP フローで検証できる。
- **実装しない場合のリスク/制約**: クロスドメイン委譲ユースケースを検証できない。ただし前提 2 仕様が未実装のため、**まず RFC 8693 / RFC 7523 の優先度判断が先**。

## 7. 実装方針の候補

（最終判断は人間。ここでは前提依存と選択肢を整理）

### 前提: RFC 8693 / RFC 7523 の実装順
- **Step 0**: `ext-token-exchange-rfc8693.md` と `ext-jwt-bearer-authorization-grant-rfc7523.md` の優先度を決める。identity chaining はこの 2 つが揃うまで着手不可。

### 方針A: 受領側（AS-B）から実装（`jwt-bearer` assertion 受領）
- 他 OP が発行した JWT grant を受け取れるようにする。信頼 issuer/JWKS は利用者設定。replay 防止（`jti` + store）を入れる。
- 「本 OP を下流ドメインとして使う」検証が先に回る。

### 方針B: 発行側（AS-A）から実装（`token-exchange` で AS-B 限定 JWT grant を発行）
- `resource`/`audience` を受けて短命・単回の JWT grant を発行。
- 「本 OP を上流ドメインとして使う」検証が回る。

### 方針C: 見送り（前提が重いため）
- RFC 8693 / RFC 7523 の需要が固まるまで identity chaining はドラフト追随メモに留める。

Discovery は `identity_chaining_requested_token_types_supported` を core builder（`discovery.ts`）に足す前提で、`study-material/discovery-optional-metadata-fields.md` の追加フィールド方針と整合させる。

## 8. タスク案

- [ ] 前提 2 仕様（RFC 8693 / RFC 7523）の実装優先度を確定（identity chaining のブロッカー）
- [ ] 本 OP が担う役割（AS-A 発行側 / AS-B 受領側 / 両方）の決定
- [ ] （AS-B）`jwt-bearer` assertion 検証: 信頼 issuer/JWKS 設定・`aud`==自分・`exp` 短命・`jti` 単回使用（store の used マーク流用）
- [ ] （AS-A）`token-exchange`: `resource`/`audience` 必須検証・AS-B 限定 `aud` の短命 JWT grant 発行・単回使用制約
- [ ] `identity_chaining_requested_token_types_supported` を `buildProviderMetadata` で表現可能にする
- [ ] クロスドメイン refresh token を発行しない方針をコード/ドキュメントで明示
- [ ] 2 段フロー（AS-A→AS-B）の結合テスト or E2E（`tests/e2e`、両ドメインを立てる）
- [ ] Basic OP conformance に影響しないこと（既存 `conformance.test.ts` が緑）を確認
- [ ] 完了条件: 前提仕様実装後、`pnpm test` がパスし、単回使用・`aud` 限定・短命検証の単体テストが緑
