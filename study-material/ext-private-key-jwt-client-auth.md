# 拡張: `private_key_jwt` / `client_secret_jwt` クライアント認証

## ステータス

🟢 拡張機能 / 未着手

## 1. このトピックで確認したいこと

Token Endpoint のクライアント認証として、JWT ベースの
`private_key_jwt`（非対称鍵）／`client_secret_jwt`（HMAC）を拡張提供すべきかを確認する。
Basic OP では `client_secret_basic`/`post` で足りるが、秘密の at-rest 露出を減らし
セキュアプロファイル検証を可能にする。

> client_secret の比較・保存の堅牢化（既存方式の強化）は
> `tasks/security-client-secret-handling.md` で扱う。本ファイルは **重複を避け**、
> 「非対称/JWT 認証メソッドの追加」という別軸に絞る。
> `token_endpoint_auth_methods_supported` の Discovery 拡張は
> 既存 `tasks/T-021-discovery-metadata.md` と整合させる（値の追加のみ差分）。

## 2. 関連する仕様・基準

- **OIDC Core 1.0 §9（Client Authentication）**:
  `client_secret_jwt`（HS256, secret を鍵）/ `private_key_jwt`（クライアント登録公開鍵で検証）。
  Client Assertion: `client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer`、
  `client_assertion`=JWT（`iss`/`sub`=client_id, `aud`=Token Endpoint or issuer, `jti`, `exp`）。
- **RFC 7523（JWT Profile for Client Authentication）**: assertion 検証要件、
  `jti` リプレイ防止、`aud` 検証、有効期限。
- **RFC 8414 §2 / OIDC Discovery §3**: `token_endpoint_auth_methods_supported`,
  `token_endpoint_auth_signing_alg_values_supported`。
- Basic OP 必須ではない（拡張）。Basic OP 定義は `tasks/basic-op-requirements-baseline.md` 参照。

## 3. 参照資料

- OIDC Core 1.0 §9: https://openid.net/specs/openid-connect-core-1_0.html#ClientAuthentication
- RFC 7523: https://www.rfc-editor.org/rfc/rfc7523
- RFC 7521（Assertion Framework）: https://www.rfc-editor.org/rfc/rfc7521
- RFC 8414 §2: https://www.rfc-editor.org/rfc/rfc8414#section-2

## 4. 現在の実装確認

- `client-auth.ts`: `client_secret_basic` / `client_secret_post` のみ。
  二重指定禁止（OAuth 2.1 §2.3）は実装済み（`client-auth.ts:115-120`）。
- `TokenClientInfo`（`token-request.ts:81-84`）は `clientId`/`clientSecret`（平文）のみ。
  クライアント登録公開鍵（`jwks`/`jwks_uri`）の表現が無い。
- JWT 検証基盤は存在: `crypto-utils.ts`（sign/verify, alg 抽出）、
  `id-token.ts:198` の JWKS 鍵選択＋署名検証ロジックが**参考実装として再利用可能**。
- `client_assertion` / `client_assertion_type` は `TokenRequestParams` に無し。
- Discovery に `token_endpoint_auth_methods_supported` を出す口は T-021 で計画
  （現状 CLI/sample は `['client_secret_basic','client_secret_post']`）。

## 5. 現在の実装との差分

- **満たしていること**: JWT 署名検証・JWKS 鍵選択・`jti` 的ストア（DPoP T-019 で計画の
  jti ストアと同型）の基盤があり、assertion 検証に流用しやすい。
- **不足している可能性があること**
  - `client_assertion`/`client_assertion_type` の受理と検証
    （`iss`/`sub`/`aud`/`exp`/`jti` リプレイ、署名）。
  - `private_key_jwt` 用にクライアント登録鍵（`jwks`/`jwks_uri`）の型・解決手段。
  - 認証メソッドの相互排他（basic/post/JWT を同時指定したら `invalid_request`）。
  - Discovery の `token_endpoint_auth_methods_supported` 拡張（T-021 と整合）。
- **セキュリティ**: `private_key_jwt` は secret を AS に保存しないため
  `tasks/security-client-secret-handling.md` の at-rest 露出問題を構造的に回避できる。

## 6. 改善・追加を検討する理由

- 「本番導入を見据える開発者」向けに、秘密を AS に置かない認証
  （`private_key_jwt`）はセキュアプロファイル（FAPI 等）の前提として頻出。
- 署名検証・JWKS 選択・jti ストアの基盤が既にある／計画済みで **導入しやすい**。
- 実装しない場合の制約: JWT クライアント認証前提の IdP 移行・要件検証ができない。

## 7. 実装方針の候補

### 方針A（両メソッド + assertion 検証ヘルパー）

- core に Client Assertion 検証純関数:
  type=`...jwt-bearer` を判定 → JWT デコード →
  `client_secret_jwt`(HS) は登録 secret を鍵に検証 /
  `private_key_jwt` は登録 JWKS から鍵選択し検証 →
  `iss==sub==client_id`、`aud` ∈ {Token Endpoint URL, issuer}、`exp`、`jti` リプレイ防止。
- `jti` ストアは注入（DPoP T-019 の jti ストア型と統一できれば一貫性が高い）。
- `authenticateClient` を「basic/post/JWT を解決し相互排他チェック」へ拡張。
- `TokenClientInfo` にクライアント登録鍵（JWK セット）を追加。
- Discovery に認証メソッド/署名 alg を追加（T-021 と整合）。

### 方針B（`private_key_jwt` のみ）

- セキュリティ価値が高い `private_key_jwt` を先行。`client_secret_jwt` は後続。

### 方針C（非対応の明文化）

- Basic OP 範囲（basic/post）に留め、ロードマップ化。

## 8. タスク案

- [ ] 方針A/B/C を選択（ユーザー判断）。`jti` ストアを T-019 と共通化するか決定
- [ ] Client Assertion 検証（署名・iss/sub/aud/exp・jti リプレイ・メソッド相互排他）のテストを先行作成
- [ ] core: assertion 検証ヘルパー実装（`id-token.ts` の JWKS 検証パターン流用）
- [ ] `TokenClientInfo` 拡張（登録鍵 JWKS）と既存型の整合（/design-discussion で確定設計を記録）
- [ ] `authenticateClient` を JWT 認証対応へ拡張（既存 basic/post を壊さない）
- [ ] Discovery `token_endpoint_auth_methods_supported` 拡張（T-021 と統合 or 後追い）
- [ ] CLI/sample テンプレート同期
- [ ] 完了条件: core / cli テストがパス
