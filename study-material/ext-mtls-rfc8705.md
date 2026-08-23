# 拡張: mTLS クライアント認証・証明書バウンドトークン（RFC 8705）

## ステータス

🟢 拡張機能 / 未着手

## 1. このトピックで確認したいこと

相互 TLS（mTLS）による **クライアント認証**（`tls_client_auth` /
`self_signed_tls_client_auth`）と **証明書バウンドアクセストークン**（`cnf.x5t#S256`）を
拡張として提供すべきかを確認する。DPoP（送信者制約）と並ぶ sender-constraining の選択肢。

> sender-constrained トークンのもう一方の手段 DPoP は既存 `tasks/T-019-dpop.md` で扱う。
> 本ファイルは **重複を避け**、mTLS 固有の差分（TLS 層連携・`cnf.x5t#S256`・
> mTLS クライアント認証メソッド）に絞る。共通概念（`cnf` による所持証明）は
> T-019 を参照し再説明しない。

## 2. 関連する仕様・基準

- **RFC 8705（OAuth 2.0 Mutual-TLS Client Authentication and Certificate-Bound Access Tokens）**
  - §2: クライアント認証 `tls_client_auth`（PKI 検証）/ `self_signed_tls_client_auth`。
  - §3: 証明書バウンドトークン。AT/Introspection に `cnf` の `x5t#S256`
    （クライアント証明書 SHA-256 サムプリント, base64url）。
  - §3.1: RS は提示証明書のサムプリントとトークンの `cnf.x5t#S256` 一致を検証。
  - §6: Discovery `tls_client_certificate_bound_access_tokens`、
    `token_endpoint_auth_methods_supported` に mTLS メソッド、`mtls_endpoint_aliases`。
- Basic OP 必須ではない（拡張）。位置づけは `tasks/basic-op-requirements-baseline.md` 参照。

## 3. 参照資料

- RFC 8705: https://www.rfc-editor.org/rfc/rfc8705
  - §2 mTLS Client Auth / §3 Certificate-Bound Tokens / §6 Metadata
- RFC 7638（JWK Thumbprint, DPoP と共有概念）: https://www.rfc-editor.org/rfc/rfc7638
- RFC 8414 §2: https://www.rfc-editor.org/rfc/rfc8414#section-2

## 4. 現在の実装確認

- クライアント認証は `client_secret_basic`/`client_secret_post` のみ
  （`client-auth.ts`）。mTLS メソッドは未対応。
- アクセストークン `cnf` クレームは DPoP 用に T-019 で計画（`tasks/T-019-dpop.md`）。
  mTLS 用 `cnf.x5t#S256` は別途。
- Web 標準のみ方針（CLAUDE.md）。**クライアント証明書情報の取得は TLS 終端
  （リバースプロキシ/エッジ）依存**で、ランタイムの Web 標準 API では直接取れない。
  → ヘッダ（例: `X-Client-Cert` / プラットフォーム提供値）からの注入前提になる。
- Discovery（`discovery.ts`）に mTLS 関連フィールド無し。

## 5. 現在の実装との差分

- **満たしていること**: `cnf` を AT に載せる設計が T-019 で計画済み。
  サムプリント計算（RFC 7638/SHA-256 base64url）は T-019 の thumbprint ヘルパーと
  実装基盤を共有できる。
- **不足している可能性があること**
  - mTLS クライアント認証メソッド（証明書 Subject/SAN or self-signed JWK 照合）。
  - 証明書情報の注入 I/F（TLS 終端からの証明書をどう core に渡すか）。
  - `cnf.x5t#S256` 付与と RS 側照合。
  - Discovery メタデータ（`tls_client_certificate_bound_access_tokens` 等）。
- **相互運用性/移植性**: 純粋な Web 標準ランタイムでは mTLS 終端情報を取得できないため、
  「証明書は外部から注入」という前提を明示する必要（移植性軸との整合確認が要る）。

## 6. 改善・追加を検討する理由

- FAPI 等のセキュアプロファイル検証では mTLS が標準的選択肢。DPoP（T-019）と
  二者択一で検証したい利用者がいる。
- thumbprint/`cnf` の実装基盤を T-019 と共有でき、**T-019 実装後なら導入しやすい**。
- 実装しない場合の制約: 証明書バウンド／mTLS 前提の要件検証ができない。
- 注意: 移植性軸（どこでも動く）と TLS 終端依存はトレードオフ。証明書注入抽象で吸収する。

## 7. 実装方針の候補

### 方針A（注入抽象 + T-019 基盤共有）

- 証明書情報を `ClientCertificateResolver`（提示証明書 → DER/PEM or サムプリント）として注入。
- core に mTLS クライアント認証（`tls_client_auth` の Subject DN/SAN 照合、
  `self_signed_tls_client_auth` の登録 JWK 照合）を追加。
- `cnf.x5t#S256` 付与は T-019 の `cnf` 機構に相乗り（thumbprint ヘルパー共有）。
- Discovery（core builder）に mTLS メタデータ追加（他 Discovery タスクと整合）。
- T-019（DPoP）実装後の着手を推奨（基盤再利用）。

### 方針B（証明書バウンドのみ / 認証は据え置き）

- mTLS クライアント認証は入れず、外部で確立した証明書サムプリントを受け取り
  `cnf.x5t#S256` を付与する最小対応のみ。

### 方針C（非対応の明文化）

- DPoP（T-019）を sender-constraining の唯一手段とし、mTLS 非対応をロードマップ化。

## 8. タスク案

- [ ] 方針A/B/C を選択（ユーザー判断）。T-019 との実装順序（後行推奨）を確認
- [ ] 証明書注入 I/F と Web 標準ランタイム前提（外部注入）の設計を /design-discussion で協議
- [ ] mTLS 認証・`cnf.x5t#S256` 付与・RS 照合のテストを先行作成
- [ ] core 実装（T-019 の thumbprint/`cnf` 基盤と共有）
- [ ] Discovery メタデータ追加（core builder へ）
- [ ] CLI/sample テンプレート同期（証明書注入スタブ）
- [ ] 完了条件: core / cli テストがパス
