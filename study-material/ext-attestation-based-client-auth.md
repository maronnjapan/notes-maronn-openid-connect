# 拡張機能検討: OAuth 2.0 Attestation-Based Client Authentication（attest_jwt_client_auth）

## 1. タイトル

OAuth 2.0 Attestation-Based Client Authentication（`draft-ietf-oauth-attestation-based-client-auth`）の導入検討。
パブリッククライアント（ネイティブアプリ・ウォレット・SPA）が、`client_secret` を埋め込むことなく、バックエンド（Client Backend / Attester）が発行した **Client Attestation JWT** と、クライアントインスタンスが鍵で署名した **Client Attestation PoP JWT** によって Token Endpoint で「クライアント認証」を成立させるための拡張。

## 2. このトピックで確認したいこと

- 本リポジトリは現状 `client_secret_basic` / `client_secret_post` / `none`（パブリッククライアント）のみをサポートしており、パブリッククライアントは**実質的にクライアント認証を持たない**（`client_id` のみで識別）。この構造的弱点を、秘密値の配布なしに補強できる方式として attestation-based client auth が使えるかを確認する。
- `client-auth.ts` の `authenticateClient` に新しい認証方式を**プラグイン的に**追加できるか、現在の判別構造（登録方式 `tokenEndpointAuthMethod` との一致検証）にどう接続するかを確認する。
- 本トピックは「クライアント認証の拡張」であり、既存の以下とは**別の差分**であることを確認する:
  - 秘密鍵 JWT 方式（`private_key_jwt`）: 📌 `study-material/ext-private-key-jwt-client-auth.md`
  - mTLS によるクライアント認証 / sender-constrained: 📌 `study-material/ext-mtls-rfc8705.md`
  - パブリッククライアントの Token Endpoint 利用と RT rotation 強制: 📌 `study-material/done/p1-public-client-token-endpoint.md` 系・`study-material/refresh-token-public-client-rotation-enforcement.md`
  - ネイティブアプリ BCP（RFC 8252）: 📌 `study-material/ext-native-apps-rfc8252.md` / `study-material/done/oauth-native-apps-rfc8252.md`
  - ウォレット文脈（OpenID4VCI / HAIP の attestation 言及）: 📌 `study-material/ext-openid4vci-credential-issuance.md`

## 3. 関連する仕様・基準

> 共通仕様（Token Endpoint・クライアント認証の基礎）は `study-material/basic-op-requirement-traceability.md` の §3 索引を参照。ここでは attestation 固有の差分のみ記載する。

OAuth 2.0 Attestation-Based Client Authentication は、IETF OAuth WG で策定中のドラフト（本ファイル作成時点の最新は **draft-09**、直前安定版 -08）。中核は「2 つの JWT を 2 つの HTTP ヘッダで提示する」モデル:

- **Client Attestation JWT**（ヘッダ `OAuth-Client-Attestation`）
  - Client Backend（= Attester。アプリ提供者が運用する信頼済みコンポーネント）が発行する。
  - クライアントインスタンスが生成した**非対称鍵ペアの公開鍵**を `cnf`（confirmation、典型的には `cnf.jwk`）として封入する。これにより「この attestation はこの公開鍵を持つインスタンスのもの」と束縛する。
  - 代表的クレーム: `iss`（Attester）、`sub`（`client_id`）、`exp`、`cnf`（公開鍵）。
  - 署名は Attester の鍵で行われ、AS は Attester を信頼の起点（trust anchor）として検証する。
- **Client Attestation PoP JWT**（ヘッダ `OAuth-Client-Attestation-PoP`）
  - クライアントインスタンスが、上記 `cnf` に対応する**秘密鍵**で署名する Proof of Possession。
  - 代表的クレーム: `iss`（`client_id`）、`aud`（**AS の issuer 識別子 URL**、RFC 8414 の issuer）、`exp`、`jti`（リプレイ防止）、必要に応じて `nonce`。
- 両ヘッダ値は `token68` 構文（英数 + `-._~+/` と末尾 `=`）。
- **クライアント認証方式としての登録値**: `token_endpoint_auth_methods_supported` に **`attest_jwt_client_auth`**（IANA「OAuth Token Endpoint Authentication Methods」レジストリに登録）。
- **AS メタデータ要件**: `token_endpoint_auth_methods_supported` に `attest_jwt_client_auth` を含めるなら、対応アルゴリズムを
  `client_attestation_signing_alg_values_supported` および
  `client_attestation_pop_signing_alg_values_supported`
  として公開しなければならない（MUST）。
- **Refresh Token との関係**: attestation 機構でトークンリクエストした結果として RT を発行する場合、AS は RT を**クライアントインスタンスとその公開鍵に束縛**しなければならず（MUST）、クライアントは RT リフレッシュ時にも attestation 機構を使わなければならない。これは sender-constrained RT に相当し、本リポジトリの「パブリッククライアントは RT rotation 必須」方針（上記参照）を、より強い「鍵束縛」へ引き上げる位置づけ。

`private_key_jwt`（`client_assertion` ベース）との違い: `private_key_jwt` は「クライアント自身が事前登録済みの鍵で自己署名する」モデルで、AS がクライアントごとの公開鍵（または JWKS）を**事前に保持**している必要がある。attestation-based は「クライアントインスタンスが動的に生成した鍵を、信頼済み Attester が裏書きする」モデルで、AS は**個々のインスタンス鍵を事前登録せず Attester だけを信頼**すればよい。配布数が膨大で鍵が動的なネイティブ／ウォレットに適する。

## 4. 参照資料

- IETF OAuth WG, "OAuth 2.0 Attestation-Based Client Authentication", `draft-ietf-oauth-attestation-based-client-auth`（最新 -09 / 安定 -08）
  - データトラッカー: https://datatracker.ietf.org/doc/draft-ietf-oauth-attestation-based-client-auth/
  - 根拠とした内容: 2 ヘッダ（`OAuth-Client-Attestation` / `OAuth-Client-Attestation-PoP`）、`token68` 構文、`attest_jwt_client_auth`（IANA 登録）、メタデータ `client_attestation_signing_alg_values_supported` / `client_attestation_pop_signing_alg_values_supported`、PoP の `aud` = AS issuer URL、Attester が公開鍵を `cnf` に封入、RT のインスタンス束縛要件。
- RFC 8414 OAuth 2.0 Authorization Server Metadata — https://www.rfc-editor.org/rfc/rfc8414 （`token_endpoint_auth_methods_supported`、issuer 識別子の定義）
- RFC 7591 OAuth 2.0 Dynamic Client Registration — https://www.rfc-editor.org/rfc/rfc7591 （`token_endpoint_auth_method` レジストリの根拠）
- RFC 7800 Proof-of-Possession Key Semantics for JWTs — https://www.rfc-editor.org/rfc/rfc7800 （`cnf` / `cnf.jwk` の意味論）
- RFC 9449 DPoP — https://www.rfc-editor.org/rfc/rfc9449 （PoP 機構の比較対象。本リポジトリでは 📌 `tasks/T-019-dpop.md` で別途追跡）
- OpenID4VC High Assurance Interoperability Profile (HAIP) — ウォレット文脈で attestation を要求する側のプロファイル（本リポジトリ内 `study-material/ext-openid4vci-credential-issuance.md` で言及）

> 注: 本仕様は RFC 化前のドラフトであり、クレーム名・メタデータ名・ヘッダ仕様はバージョン間で変動しうる。実装着手時は採用バージョンを固定し、当該バージョンの本文を一次情報として再確認すること（このファイルは draft-08/09 時点のスナップショット）。

## 5. 現在の実装確認

- クライアント認証の実体: `packages/core/src/client-auth.ts` の `authenticateClient`。
  - サポート方式: `client_secret_basic`（`Authorization: Basic`）/ `client_secret_post`（body）/ `none`（パブリッククライアント）。
  - 登録方式 `client.tokenEndpointAuthMethod`（既定 `client_secret_basic`）と**実際に使われた方式の一致**を検証し、方式ダウングレードを拒否する構造を持つ（L158-192）。
  - 秘密比較は `timingSafeEqual`（`crypto-utils.ts`）で timing 安全。
- HTTP 配線: `packages/sample/src/oidc-provider/routes/token.ts` が `authenticateClient` を呼び、`authenticatedClientId` を `validateTokenRequest` に渡す。Authorization ヘッダと body のみを参照し、`OAuth-Client-Attestation*` ヘッダは読んでいない。
- Discovery: `packages/core/src/discovery.ts` の `buildProviderMetadata` は `tokenEndpointAuthMethodsSupported` を任意配列として受け取り出力するが、`client_attestation_signing_alg_values_supported` 等の attestation 用メタデータフィールドは型に存在しない。
- 鍵検証の素地: `crypto-utils.ts` に Web Crypto ベースの JWS 検証（`verify`）や JWK 取り回し（`extractAlgorithmParamsFromJwk`）があり、JWT 署名検証の部品は既にある（ID Token 署名等で使用）。

## 6. 現在の実装との差分

満たしていること:
- クライアント認証を**抽象された 1 関数**（`authenticateClient`）に集約しており、新方式の追加点が 1 箇所で済む構造。
- 登録方式との一致検証・ダウングレード拒否という、複数方式併存に必要な土台が既にある。
- JWS 検証・JWK 取り回しの暗号部品が core に存在する。

不足している可能性があること:
- 🔴 `OAuth-Client-Attestation` / `OAuth-Client-Attestation-PoP` ヘッダの受理・パースが**無い**（`ClientAuthContext` は `authorizationHeader` と body params のみ）。
- 🔴 Attester を信頼の起点とする検証（Attester 公開鍵／JWKS の解決、`cnf` 束縛検証、PoP の `aud`=issuer / `jti` リプレイ防止 / `exp` 検証）が**無い**。
- 🔴 Discovery メタデータに `attest_jwt_client_auth` および `client_attestation_*_signing_alg_values_supported` を広告する型・配線が**無い**（広告の honesty を欠く）。
- 🟡 RT のインスタンス鍵束縛（sender-constrained RT）の概念が `RefreshTokenInfo` に無い。attestation 経由発行 RT を「鍵束縛」として永続化・リフレッシュ時に再検証する経路が無い。

セキュリティ上の含意:
- パブリッククライアントは現状 `client_id` のみで識別されるため、漏えいした `client_id` を騙ったトークンリクエスト（特に RT リフレッシュ）に対する**クライアント真正性の防御が弱い**。attestation はこの隙を、秘密配布なしに塞ぐ手段になりうる。

相互運用性の含意:
- ウォレット（OpenID4VCI / HAIP）やネイティブアプリのエコシステムでは attestation 前提の AS が増えつつあり、「最新仕様を最速で試せる」という本リポジトリの価値提案に直結する検証対象。

## 7. 改善・追加を検討する理由

- なぜ価値があるか: パブリッククライアントに対する**秘密値非配布のクライアント認証**は、OAuth 2.1 / Security BCP が課題視する「パブリッククライアントの真正性」を実用的に解決する数少ない手段。RT を鍵束縛できるため、RT 漏えい時の被害も限定できる。
- Basic OP として必要か: **不要（拡張）**。Basic OP は `response_type=code` + 既定のクライアント認証方式が対象で、attestation は範囲外。本リポジトリの差別化軸「Speed（最新仕様の追随）」に資する拡張という位置づけ。
- 導入しやすさ: `authenticateClient` という単一の拡張点があり、JWS 検証部品も揃うため、**追加は局所的**。一方で「Attester の信頼設定（公開鍵／許可リスト）」「PoP のリプレイ防止ストア（`jti`）」という新しい運用要素が要るため、ゼロコストではない。
- 既存実装との接続: 登録方式一致検証の分岐に `attest_jwt_client_auth` を 1 ケース追加し、ヘッダ 2 本を `ClientAuthContext` に通すことで接続できる。Attester 鍵解決は既存の resolver 注入思想（`ClientResolver` 等）に合わせて外部注入にできる。
- 利用者メリット: PoC 開発者がウォレット／ネイティブの最新クライアント認証を、外部 IdaaS を立てずに手元で体感できる。運用者は秘密ローテーションの負荷なくクライアント真正性を得られる。
- 実装しない場合の制約: パブリッククライアント真正性の弱さが残置。ウォレット系プロファイル（HAIP）への将来対応時に、クライアント認証層を後付けで作り直す必要が出る。

## 8. 実装方針の候補

> AI は最終決定しない。以下は判断材料。

- 方針A（core に検証関数を追加 + 注入で Attester 信頼を外出し）
  - `verifyClientAttestation({ attestationJwt, popJwt, expectedAudience, attesterKeyResolver, replayStore })` を core に新設し、`authenticateClient` から `registeredMethod === 'attest_jwt_client_auth'` のときに呼ぶ。
  - Attester 公開鍵の解決・`jti` リプレイストアは resolver / store として注入（既存の resolver/store 契約と整合）。
- 方針B（独立ミドルウェア）
  - core は検証関数のみ提供し、ヘッダ抽出と方式選択は CLI 生成テンプレート側のミドルウェアで行う。core の `authenticateClient` には手を入れず疎結合に保つ。
- 方針C（段階導入: まず「広告のみ／検証は後続」）
  - 先に Discovery メタデータ型（`attest_jwt_client_auth` と alg 値配列）だけ追加し、実検証は次フェーズ。ただし「広告したら実装が伴う」honesty 原則（本リポジトリの request-object 系で確立）に反するため、**広告は検証実装が揃うまで出さない**のが安全。→ 実質、検証実装とセットで進める。
- 方針D（RT 鍵束縛まで含めるか分離するか）
  - 最小スコープ: Token Endpoint でのクライアント認証成立まで。
  - 拡張スコープ: 発行 RT を `cnf` 束縛し、リフレッシュ時に PoP 再検証（sender-constrained RT）。DPoP（📌 `tasks/T-019-dpop.md`）と設計を揃えられるか要検討。

決定すべき点（人間判断）: v0.x に入れるか後続ロードマップ送りか（`study-material/RELEASE-v0.x-scope.md` の Tier 定義と突き合わせ）、採用ドラフトバージョンの固定、RT 鍵束縛を含めるか、Attester 信頼モデル（静的許可リスト or 動的メタデータ）。

## 9. タスク案

> 本トピックは RFC 化前ドラフトの拡張であり、実装着手は方針確定後。現時点では「検討段階」として `tasks/` 化しない（既存 `ext-*` 拡張トピックと同じ扱い）。着手判断が出た場合の作業候補:

- [ ] 採用するドラフトバージョン（-08 か -09 か以降）を固定し、当該本文でクレーム名・メタデータ名・ヘッダ仕様を一次確認する
- [ ] `ClientAuthContext` に `oauthClientAttestation` / `oauthClientAttestationPop`（生ヘッダ値）を追加する設計可否を確認
- [ ] （TDD）`client-auth.test.ts` に attestation 検証の Red ケースを先に追加: 正当な attestation+PoP で認証成立 / Attester 署名不正で拒否 / PoP の `aud` 不一致で拒否 / `jti` リプレイで拒否 / `cnf` と PoP 署名鍵不一致で拒否 / 登録方式が `attest_jwt_client_auth` でないクライアントが提示したら拒否
- [ ] core に `verifyClientAttestation` を実装（JWS 検証は既存 `crypto-utils` を再利用）
- [ ] Attester 公開鍵 resolver と `jti` リプレイ防止 store の契約を定義（resolver/store 契約ドキュメントと整合）
- [ ] Discovery メタデータ型に `attest_jwt_client_auth` と `client_attestation_signing_alg_values_supported` / `client_attestation_pop_signing_alg_values_supported` を追加（検証実装が揃ってから広告する honesty を守る）
- [ ] （拡張スコープ採用時）発行 RT の `cnf` 束縛とリフレッシュ時 PoP 再検証を `RefreshTokenInfo` 拡張として設計（DPoP タスクと整合確認）
- [ ] `study-material/basic-op-requirement-traceability.md` には影響なし（Basic OP 範囲外）だが、クライアント認証拡張の一覧として参照リンクを追記するか検討

## 関連トピック

- 📌 `study-material/ext-private-key-jwt-client-auth.md` — 事前登録鍵での自己署名（`private_key_jwt`）。attestation は「Attester 裏書き + 動的インスタンス鍵」で、鍵の事前登録不要な点が差分。
- 📌 `study-material/ext-mtls-rfc8705.md` — TLS レイヤでのクライアント認証 / sender-constrained。attestation はアプリ層 JWT での等価機能。
- 📌 `study-material/refresh-token-public-client-rotation-enforcement.md` — パブリッククライアント RT の rotation 強制。attestation の RT 鍵束縛は、これを「鍵束縛」へ強化する上位互換。
- 📌 `tasks/T-019-dpop.md` — PoP 機構（DPoP）。PoP の設計（`jti` リプレイ防止・`aud`/鍵束縛）を揃えられるか要検討。
