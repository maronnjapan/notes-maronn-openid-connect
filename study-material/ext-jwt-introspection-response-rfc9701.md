# 拡張: JWT Response for OAuth Token Introspection（RFC 9701）

## 1. タイトル

Token Introspection エンドポイント（RFC 7662、本リポジトリ実装済み）のレスポンスを、署名付き JWT（`application/token-introspection+jwt`）として返せるようにする RFC 9701 への対応検討。Resource Server がイントロスペクション結果の出所と完全性を暗号的に検証できるようにする拡張。

## 2. このトピックで確認したいこと

- 既存の RFC 7662 イントロスペクション（`packages/core/src/introspection.ts`、JSON レスポンスのみ）に対し、RFC 9701 が追加する「JWT 形式のイントロスペクションレスポンス」を本リポジトリで提供する価値・導入容易性。
- これは Basic OP の要件**ではない**（純粋な拡張）。go/no-go の判断材料を整理することが目的であり、本ファイル時点ではタスク化しない。
- 既存の署名インフラ（`generateUserInfoJwt` / `generateIdToken` / 署名鍵プロバイダー / JWKS 公開）をどこまで再利用できるか。
- 重複回避: イントロスペクションの基本仕様（RFC 7662、active 判定、クライアント認証必須など）は `tasks/done/p1-token-introspection.md` と `packages/core/src/introspection.ts` で確定済み。本ファイルは「**JSON を JWT で包む差分**」にのみ絞る。

## 3. 関連する仕様・基準

イントロスペクション本体の仕様（RFC 7662 §2.1/§2.2、active レスポンス、クライアント認証）は既存実装で確定済みのため繰り返さない。本トピック固有の差分は以下。

### 3.1 RFC 9701 — JWT Response for OAuth Token Introspection

- **要求方法**: Resource Server が introspection リクエストの `Accept` ヘッダに `application/token-introspection+jwt` を指定する（または client metadata `introspection_signed_response_alg` 等で事前合意）。
- **レスポンス**: `Content-Type: application/token-introspection+jwt` で、**署名付き JWT** を返す。
  - JOSE Header の `typ` は **`token-introspection+jwt`**（明示必須。cross-JWT confusion 防止のため、ID Token/UserInfo/Access Token と型を分ける）。
  - JWT claims:
    - `iss`: OP の issuer。
    - `aud`: イントロスペクションを要求したクライアント（Resource Server）の識別子。
    - `iat`: 発行時刻。
    - **`token_introspection`**: 値は RFC 7662 §2.2 のイントロスペクションレスポンス（`active` と各属性）をそのまま入れた JSON オブジェクト。
  - つまり「RFC 7662 のボディを `token_introspection` クレームの中に丸ごと収め、JWT で署名して返す」構造。
- **暗号化（任意）**: `introspection_encrypted_response_alg` / `enc` を使い、署名 JWT をさらに JWE でネストできる（Nested JWT）。これは `study-material/id-token-and-userinfo-encryption-jwe.md` と同じ JWE 基盤を要するため、暗号化は本対応の対象外（署名のみを第一段階とするのが妥当）。
- **クライアントメタデータ**: `introspection_signed_response_alg`（署名 alg。省略時のデフォルトは実装/プロファイル依存だが RS256 が無難）、`introspection_encrypted_response_alg` / `introspection_encrypted_response_enc`。
- **Discovery メタデータ**: `introspection_signing_alg_values_supported`（および暗号化対応時 `introspection_encryption_alg_values_supported` / `introspection_encryption_enc_values_supported`）を AS Metadata（RFC 8414）に追加可能。

### 3.2 関連既存ファイル（重複回避のための参照先）

- `tasks/done/p1-token-introspection.md` / `packages/core/src/introspection.ts`: RFC 7662 本体（active 判定、token_type_hint 検索順、クライアント認証）。本拡張はこの出力を JWT で包むだけ。
- `study-material/jwt-bcp-rfc8725.md`: `typ` 明示・alg ホワイトリスト・`kid` などの JWT 発行ベストプラクティス（`token-introspection+jwt` の `typ` 設定はここに従う）。
- `study-material/jws-algorithm-policy-and-alg-none-defense.md`: 署名 alg ポリシー（cross-JWT confusion 防止）。
- `study-material/oauth-authorization-server-metadata-rfc8414.md`: `introspection_signing_alg_values_supported` の広告先。
- `study-material/id-token-and-userinfo-encryption-jwe.md`: 暗号化（JWE ネスト）を将来やる場合の共通基盤。
- `study-material/ext-mtls-rfc8705.md` / FAPI 系: 署名付きイントロスペクションが要求される典型シナリオ（高保証 API）。

## 4. 参照資料

- RFC 9701 *JWT Response for OAuth Token Introspection* — https://datatracker.ietf.org/doc/html/rfc9701
  - 根拠箇所: §4（Requesting a JWT Response、`Accept: application/token-introspection+jwt`）、§5（JWT Response — `typ: token-introspection+jwt`、`iss`/`aud`/`iat`/`token_introspection` クレーム）、§6（暗号化レスポンス）、§7（Client/AS メタデータ `introspection_signed_response_alg` 等）。
- RFC 7662 *OAuth 2.0 Token Introspection* §2.2 — https://datatracker.ietf.org/doc/html/rfc7662#section-2.2 （`token_introspection` クレームに格納する基本レスポンス）。
- RFC 8414 *OAuth 2.0 Authorization Server Metadata* — https://datatracker.ietf.org/doc/html/rfc8414 （`introspection_signing_alg_values_supported` の広告）。
- RFC 8725 *JWT Best Current Practices* — https://datatracker.ietf.org/doc/html/rfc8725 （`typ` 明示・alg 制限）。
- 本リポジトリ該当箇所: `packages/core/src/introspection.ts`（現状 JSON のみ）、`packages/core/src/userinfo.ts` の `generateUserInfoJwt`（JWT 署名の既存実装パターン）。

## 5. 現在の実装確認

- `packages/core/src/introspection.ts`: `handleIntrospectionRequest()` が `IntrospectionResponse`（`{ active: false }` または `active: true` + 推奨クレーム）を返す純関数。**JSON 専用**で、JWT 化や `Accept` ヘッダ分岐は持たない。
- サンプルの配線 `packages/sample/src/oidc-provider/routes/introspection.ts`: `c.json(...)` で JSON を返す（`Accept` を見ていない）。
- 署名基盤は既存: `generateUserInfoJwt`（`userinfo.ts`）が「ヘッダ alg=`getJwaAlgorithm`、`typ:'JWT'`、payload に iss/aud/iat/exp を付けて `sign()`」というまさに必要なパターンを実装済み。署名鍵は `signing-key.ts` の provider 経由、公開鍵は JWKS で配布済み。
- Discovery: `introspection_endpoint` / `introspection_endpoint_auth_methods_supported` は `discovery.ts` で広告可能だが、`introspection_signing_alg_values_supported` フィールドは未定義。

## 6. 現在の実装との差分

満たしていること:
- ✅ RFC 7662 の基本イントロスペクション（active 判定・クライアント認証・属性返却）が実装済み。JWT 化はこの上に**薄く重ねるだけ**で済む。
- ✅ JWT 署名・鍵管理・JWKS 公開の基盤が既にある（`generateUserInfoJwt` と同型）。

不足していること（=本拡張で追加する差分）:
- ❌ `Accept: application/token-introspection+jwt` の判定と分岐。
- ❌ `IntrospectionResponse` を `token_introspection` クレームに格納し、`iss`/`aud`/`iat` を付けて `typ: token-introspection+jwt` で署名する関数（例: `generateIntrospectionJwt`）。
- ❌ `Content-Type: application/token-introspection+jwt` での返却（サンプル route）。
- ❌ Discovery への `introspection_signing_alg_values_supported`。
- ❌（任意）暗号化レスポンス（JWE）。本対応では対象外とし、署名のみを推奨。

相互運用性／セキュリティ:
- ⚠️ `aud` は「イントロスペクションを要求したクライアント（RS）」に設定する必要がある。現状の `handleIntrospectionRequest` は `authenticatedClientId` を持つので、それを `aud` に使える。
- ⚠️ `typ` を `token-introspection+jwt` に固定し、ID Token/UserInfo JWT と取り違えられないようにする（cross-JWT confusion 対策。`jws-algorithm-policy-and-alg-none-defense.md` 準拠）。

## 7. 改善・追加を検討する理由

- **なぜ価値があるか**: 署名付きイントロスペクションは、Resource Server が「この結果は確かにこの OP が出したもの」を**ネットワーク上で改ざんされていないことまで含めて**検証できるようにする。マイクロサービス間や、TLS 終端が複数あるゲートウェイ構成で有用。
- **Basic OP に必要か / 拡張か**: **完全な拡張**。Basic OP には不要。ただし FAPI / 高保証 API・金融系 PoC を見据える利用者には需要がある。
- **導入しやすさ（高い）**: 既存の `generateUserInfoJwt` とほぼ同型の関数を 1 つ足し、route で `Accept` を見て分岐するだけ。core の純関数設計（`handleIntrospectionRequest` が値を返す）と相性が良い。
- **既存実装との接続**: `handleIntrospectionRequest()` の戻り値をそのまま `token_introspection` に入れればよく、本体ロジックは無改変で済む（薄いラッパー）。
- **利用者メリット**: 「署名付きイントロスペクションを試したい」という FAPI 系 PoC をこのライブラリ内で完結できる。RFC 9701 は比較的新しい（2024 RFC 化）ため、"Speed（最新仕様に最速追随）" の実績にもなる。
- **実装しない場合のリスク**: 高保証ユースケースの検証ができず、FAPI 方面の PoC で他ツールへ離脱する動機になる。機能未提供自体はセキュリティリスクではない（あくまで任意拡張）。

## 8. 実装方針の候補

> 最終判断は人間が行う。以下は判断材料。

### 候補 A: 署名のみ対応（推奨度: 高、第一段階）
- core に `generateIntrospectionJwt(response, { issuer, audience, privateKey, keyId })` を追加（`generateUserInfoJwt` を踏襲、`typ: 'token-introspection+jwt'`、payload = `{ iss, aud, iat, token_introspection: response }`）。
- サンプル route で `Accept` に `application/token-introspection+jwt` が含まれるとき JWT を返す（それ以外は従来どおり JSON）。
- Discovery に `introspection_signing_alg_values_supported` を追加。

### 候補 B: 署名 + 暗号化（JWE ネスト）対応
- 候補 A に加え `study-material/id-token-and-userinfo-encryption-jwe.md` の JWE 基盤と統合。実装量・依存（暗号化鍵管理）が増えるため、JWE 全体の方針が決まってから。

### 候補 C: 採用しない（現状の JSON のみ）
- Basic OP に不要なため v0.x では見送り。README に「RFC 9701 は未対応、必要なら issue」と明記。

### 共通の設計上の注意
- `aud` は要求元クライアント（`authenticatedClientId`）。
- `typ` を `token-introspection+jwt` に固定（cross-JWT confusion 防止）。
- 署名鍵・kid・alg は ID Token/UserInfo と同じ鍵集合を再利用可能（別鍵にしたい利用者向けに optional 引数）。
- `active=false` の場合も JWT で包んで返す（RFC 9701 は active に関わらず JWT 応答）。

## 9. タスク案

> 本トピックは「拡張の go/no-go 検討段階」のため、現時点ではタスク化しない（方針確定後に切り出す）。確定した場合に切り出せる候補のみ列挙する。

- （候補 A 採用時）core に `generateIntrospectionJwt()` を追加（`generateUserInfoJwt` を雛形に、`typ`/`token_introspection` クレーム対応）。
- （候補 A 採用時）サンプル `introspection.ts` route の `Accept` 分岐と `Content-Type: application/token-introspection+jwt` 返却。
- （候補 A 採用時）`discovery.ts` に `introspection_signing_alg_values_supported` を追加し、実際に署名可能な alg のみ広告（嘘広告防止。`id_token_signing_alg_values_supported` の導出ロジックと同じ方針）。
- （候補 A 採用時）テスト: JWT の `typ`/`iss`/`aud`/`iat`/`token_introspection` 検証、active=true/false 双方の JWT 化、JSON フォールバック（Accept 無指定）の回帰。
- （候補 B 採用時）JWE ネストは `id-token-and-userinfo-encryption-jwe.md` の方針確定後に別タスク化。
