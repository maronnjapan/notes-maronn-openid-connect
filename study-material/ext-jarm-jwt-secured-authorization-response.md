# 拡張: JWT Secured Authorization Response Mode（JARM, OpenID FAPI）

## ステータス

🟢 拡張機能 / 未着手

## 1. このトピックで確認したいこと

JARM（JWT Secured Authorization Response Mode）は、OpenID Foundation FAPI WG が定義する仕様で、
**Authorization Response（認可エンドポイントから RP に返るレスポンス）の全パラメータを JWT に包んで返す**
モード。`response_mode=query.jwt` / `fragment.jwt` / `form_post.jwt` の 3 種類を導入する。

通常のフローでは、認可コード（`code`）と `state` がブラウザの URL（query/fragment）に **平文**で返るが、
JARM では `response={JWT}` の 1 パラメータに集約され、JWT は AS の鍵で署名（必要なら暗号化）される。
これにより:

- AS から RP への応答の **真正性・完全性**を保証（中間者改ざん検知）
- ブラウザ履歴・ログ・リファラに残るパラメータの **可読性低下**（特に暗号化時）
- mix-up 攻撃や session fixation の追加防御

JAR（RFC 9101、Request Object）は **リクエスト側を JWT で守る**仕様で、本リポジトリでは
`study-material/ext-jar-request-object-rfc9101.md` で扱う。JARM は **レスポンス側**の対の関係。

## 2. 関連する仕様・基準

共通の仕様索引は `study-material/basic-op-requirement-traceability.md` を参照。本トピック固有のポイント:

- **OpenID Connect Financial-grade API: JWT Secured Authorization Response Mode for OAuth 2.0（JARM）**:
  - 新 `response_mode` 値: `query.jwt`、`fragment.jwt`、`form_post.jwt`
  - レスポンスは `response=<JWT>` の 1 パラメータに集約
  - JWT クレーム:
    - `iss`（AS の issuer）
    - `aud`（RP の client_id）
    - `exp`（有効期限、短期）
    - `code` / `state` / `error` 等の認可レスポンスパラメータ
  - 署名は AS の通常の ID Token 署名鍵で署名（暗号化は任意）
- **Discovery メタデータ**:
  - `authorization_signing_alg_values_supported`: JARM 用 JWT 署名 alg
  - `authorization_encryption_alg_values_supported` / `authorization_encryption_enc_values_supported`: 暗号化対応時
  - `response_modes_supported` に `query.jwt` / `fragment.jwt` / `form_post.jwt` を追加
- **クライアントメタデータ**:
  - `authorization_signed_response_alg`、`authorization_encrypted_response_alg`、`authorization_encrypted_response_enc`
- **FAPI 2.0 Security Profile**:
  - PAR + RAR + JARM の組み合わせが FAPI 2.0 推奨。OAuth 2.1 と直交。
- **OAuth 2.0 Authorization Server Issuer Identification（RFC 9207）との関係**:
  - RFC 9207 は `iss` パラメータを認可レスポンスに付ける軽量対策（既存タスク `tasks/p1-authorization-response-iss.md`）。
  - JARM は同じ目的（mix-up 攻撃対策）の **完全版**。両方実装することも可能だが、JARM が動けば RFC 9207 は冗長。

## 3. 参照資料

- JARM（OpenID FAPI）: https://openid.net/specs/openid-financial-api-jarm.html
- OpenID FAPI 2.0 Security Profile: https://openid.net/specs/fapi-2_0-security-profile.html
- 関連 study-material: `ext-jar-request-object-rfc9101.md`（JAR、リクエスト側 JWT）
- 関連タスク: `tasks/p1-authorization-response-iss.md`（RFC 9207、軽量版の同目的）
- 関連 study-material: `response-mode-form-post.md`（form_post.jwt の前段として form_post を扱う）

## 4. 現在の実装確認

- `packages/core/src/authorization-request.ts`: `response_mode` パラメータの **明示的な受理経路は無い**。CLAUDE.md は `response_type=code` の Code Flow のみ前提。
- 認可エンドポイントのレスポンス生成は `auth-transaction.ts` の `completeAuthTransaction` / sample の `routes/authorize.ts` 側で行われ、`code` + `state` を query で返す（OIDC Core 1.0 §3.1.2.5）。`form_post` は 📌 `study-material/response-mode-form-post.md` で別途検討中。
- JARM の JWT 包み込み機構は **皆無**。
- Discovery に `authorization_signing_alg_values_supported` 等のフィールド無し。
- ID Token 署名インフラ（`signing-key.ts` + JWT 署名ヘルパー）は流用可能。

## 5. 現在の実装との差分

満たしていること:

- ID Token / UserInfo JWT 署名インフラ（RS256 等）は完備。JARM 用の `response` JWT 生成にそのまま流用可能。
- `state` echo / `code` 発行のロジックは実装済み。

不足／要確認:

- 🔴 **`response_mode` パラメータの受理経路無し**: まず `response_mode` を解釈する基盤が必要（`form_post` study-material と統合的に進めるのが自然）。
- 🔴 **JARM 用 JWT 生成関数無し**: `generateAuthorizationResponseJwt({ iss, aud, exp, code, state, ... })` のような純関数を core に新設する必要がある。
- 🔴 **レスポンス配信モード**: `query.jwt`（GET redirect with `?response=<JWT>`）、`fragment.jwt`（`#response=<JWT>`）、`form_post.jwt`（HTML 自動 POST）の 3 種類の HTTP 応答機構が必要。
- 🔴 **Discovery 拡張**: `response_modes_supported` に JARM 値、`authorization_signing_alg_values_supported` を追加。
- 🔴 **クライアントメタデータ拡張**: `ClientInfo` に `authorizationSignedResponseAlg?` 等を追加（後方互換: optional）。
- 🟡 **エラー応答も JARM で包む**: JARM は成功・エラー両方を JWT で包む。エラー時の挙動も実装が必要。
- 🟡 **`exp` の短さ**: 認可レスポンスの JWT は寿命が極短（数十秒）で発行する。リプレイ防止の意味で。

セキュリティ観点:

- 🟢 **mix-up 攻撃の堅牢な防御**: `iss` を JWT 内に含めるため RP は AS の偽装を検知可能（RFC 9207 と同じ目的をより強固に達成）。
- 🟡 **暗号化（JWE）対応の判断**: 平文の `code` がブラウザ履歴に残るのを完全に隠すには JWE 必須。FAPI 2.0 では推奨されるが、本リポジトリの PoC 範囲では署名のみで十分という判断もあり得る。
- 🟡 **`form_post.jwt` の CSP**: HTML 自動 POST は `script-src 'self' 'nonce-...'` 等の CSP 設計が必要（`study-material/http-security-headers-and-tls.md` 参照）。

相互運用性観点:

- 🟡 **FAPI 系 RP / クライアントライブラリとの相互運用**: FAPI 2.0 認定を取りに行く場合 JARM ほぼ必須。一般的な OIDC RP は JARM 未対応のことが多い。**クライアントごとに JARM 有効/無効を切り替え**できる設計が望ましい。

## 6. 改善・追加を検討する理由

- **FAPI 2.0 / 高セキュリティ要件**: 金融 / 医療 / 公共系 PoC で必要。`Speed` 軸の差別化シグナル。
- **mix-up 攻撃対策の本筋**: RFC 9207（`iss`）は軽量対策、JARM は本格対策。両方理解できる利用者が増えれば OSS の教育的価値も上がる。
- **実装規模は中**: JWT 生成は既存インフラ流用、配信モードは 3 つ、Discovery / ClientInfo / Request 受理が新設。FAPI 2.0 を狙うなら必須セット。
- **実装しない場合のリスク**: FAPI 系 PoC は不可。RFC 9207 が代替になる範囲は限定的。
- **`response_mode=form_post` study-material との統合**: JARM は `response_mode` の拡張なので、`form_post` 実装と JARM 実装は **同じ基盤**を必要とする。先に `form_post` を入れ、その上で JARM の 3 値を追加する順序が現実的。

## 7. 実装方針の候補

### 方針A（`form_post` 完了後の段階導入）

- まず `study-material/response-mode-form-post.md` の方針で `response_mode` 基盤を入れる。
- その上で JARM 値（`query.jwt` / `fragment.jwt` / `form_post.jwt`）を **同じ `response_mode` ディスパッチ**に追加。
- JWT 生成は ID Token 用ヘルパーを流用。
- 暗号化（JWE）は後送り（オプション）。

### 方針B（小・JARM 用 JWT 関数だけ先行）

- `generateAuthorizationResponseJwt` 関数とテストだけを先に core に追加。
- 配信モード（query.jwt / fragment.jwt / form_post.jwt）は CLI/sample 側で実装。
- Conformance Suite の JARM テストの一部だけ通る形に分割。

### 方針C（後送り）

- v0.x スコープ外。FAPI 2.0 を本格化する段階で着手。

最終判断は人間。FAPI を狙うなら方針A。

## 8. タスク案

- [ ] `study-material/response-mode-form-post.md` の `response_mode` 基盤の進捗確認と、JARM 値拡張の依存関係を明記
- [ ] `generateAuthorizationResponseJwt` の TDD テスト先行（必須クレーム iss/aud/exp、code/state の透過、エラー応答パターン）
- [ ] `AuthorizationRequestParams` に `response_mode?` を追加（後方互換: optional）し、デフォルトは `query`
- [ ] `ProviderMetadataConfig` に `authorizationSigningAlgValuesSupported?` を追加し Discovery で広告
- [ ] `ClientInfo` に `authorizationSignedResponseAlg?` を追加
- [ ] sample の認可レスポンス処理に JARM 配信モード分岐を追加
- [ ] JARM 採用時の Conformance Suite テスト計画を `basic-op-conformance-verification-plan.md` に追記
- [ ] `tasks/p1-authorization-response-iss.md` との関係（軽量 vs 完全）をドキュメント化し、JARM 有効クライアントでは RFC 9207 `iss` を省略可能とするか判断
