# 拡張: OpenID for Verifiable Credential Issuance (OID4VCI) 1.0

## ステータス

🟢 拡張機能 / 未着手（検討段階：方針未確定のためタスク化しない）

## 1. このトピックで確認したいこと

本リポジトリは「Authorization Code Flow + PKCE + Token/UserInfo を持つ OAuth 2.0 / OIDC Provider」である。
**OpenID for Verifiable Credential Issuance (OID4VCI) 1.0** は、まさにこの OAuth 2.0 Authorization Server を土台に、
**「アクセストークンと引き換えに Verifiable Credential（検証可能クレデンシャル）を発行する」** ためのエンドポイント群を継ぎ足す仕様である。

このファイルでは以下を整理する。

- OID4VCI 1.0 が **既存の認可・トークンエンドポイントをどう拡張するか**（＝本リポジトリの資産をどこまで再利用できるか）
- Basic OP として必須なのか、それとも純粋な拡張機能なのか
- 本リポジトリの「Web 標準のみ・外部依存なし・CLI でコード生成」というアーキテクチャに、どこが乗りやすく/乗りにくいか
- 検討すべき設計判断ポイントと、最初に着手するなら何から始めるべきか

このトピックは **発行（Issuance）側** に限定する。提示（Presentation, OID4VP）と自己発行（SIOPv2）は
`study-material/ext-openid4vp-siopv2-credential-presentation.md` で扱う（重複を避ける）。

## 2. 関連する仕様・基準

> 共通の OAuth 2.0 / OIDC / JWS の基礎説明（署名アルゴリズムポリシー、JWKS、PKCE、Discovery など）は
> 既存ファイルに譲り、ここでは **OID4VCI 固有の差分** に絞る。
> - 署名・alg ポリシー: `study-material/jws-algorithm-policy-and-alg-none-defense.md`
> - JWT BCP: `study-material/jwt-bcp-rfc8725.md`
> - JWKS / 鍵公開: `study-material/jwks-endpoint-comprehensive.md`, `study-material/signing-key-rotation-operations.md`
> - JWT アクセストークン: `study-material/jwt-access-token-rfc9068.md`
> - クライアント認証の拡張（private_key_jwt 等）: `study-material/ext-private-key-jwt-client-auth.md`
> - 認可リクエストの拡張（PAR / JAR / RAR）: `study-material/ext-pushed-authorization-requests-rfc9126.md`, `study-material/ext-jar-request-object-rfc9101.md`, `study-material/ext-rich-authorization-requests-rfc9396.md`

### 2.1 OID4VCI 1.0 の位置づけ（一次情報の確認結果）

- **ステータス**: OID4VCI **1.0 Final**。OpenID Foundation により **2025-09-16 に最終版として公開**された（その前段で 2 度の Implementer's Draft を経ている）。
- OID4VCI は OAuth 2.0（RFC 6749 / OAuth 2.1 系）の **拡張**として定義され、Authorization Server / Token Endpoint をそのまま利用しつつ、新しいエンドポイントとメタデータを追加する。
- 関連プロファイル **OpenID4VC High Assurance Interoperability Profile (HAIP) 1.0**（Final）が、OID4VCI / OID4VP の相互運用の具体的な暗号・フォーマット選択（例: SD-JWT VC、`ES256`、PKCE 必須、attestation など）を固めている。本リポジトリが将来 Conformance を狙うなら HAIP がデファクト基準になる。

### 2.2 OID4VCI が追加する主な構成要素

> ⚠️ 以下はエンドポイント名・grant type 名など構造の要約。**正確なセクション番号と必須/任意（MUST/SHOULD）の別は、実装着手前に最終仕様本文で必ず再確認すること**（このファイルでは断定を避け、構造の把握に留める）。

1. **Credential Issuer Metadata**
   - `.well-known/openid-credential-issuer` で公開する。発行可能なクレデンシャルの種類・フォーマット（`vc+sd-jwt` / mso_mdoc 等）・必要な proof type・暗号 alg などを広告する。
   - 既存の `/.well-known/openid-configuration`（`discovery.ts`）とは **別ドキュメント**であり、認可サーバメタデータ（`authorization_servers`）へのリンクを含む。

2. **Credential Offer**
   - Issuer が Wallet に「このクレデンシャルを受け取れます」と提示する入口。`credential_offer`（URL 埋め込み JSON）または `credential_offer_uri`（参照）で渡す。
   - 2 つの **grant** を内包しうる:
     - `authorization_code`（通常の認可コードフロー。要求するクレデンシャルは `scope` もしくは `authorization_details`(RAR) で指定）
     - **Pre-Authorized Code Grant**: `grant_type=urn:ietf:params:oauth:grant-type:pre-authorized_code`。ユーザー操作の認可ステップを省き、事前に発行された code（＋任意の tx_code/PIN）でトークンを取得する。

3. **Token Endpoint の拡張**
   - 既存トークンエンドポイントに pre-authorized_code grant を追加し、発行された access token は後続の Credential Endpoint で使われる。
   - proof of possession 用の **nonce**（旧称 c_nonce）は、1.0 では独立した **Nonce Endpoint** から取得するモデルが導入されている。

4. **Credential Endpoint**
   - access token（＋鍵所有証明 proof、例: `jwt` proof）と引き換えに実際のクレデンシャルを返す。Bearer トークン保護リソースである点は UserInfo と同型。

5. **付随エンドポイント（任意）**
   - **Nonce Endpoint**（proof 用 nonce の取得）
   - **Deferred Credential Endpoint**（即時発行できない場合の遅延取得）
   - **Notification Endpoint**（Wallet が発行結果を Issuer に通知）

### 2.3 本リポジトリとの接点（差分の核心）

OID4VCI は **「OAuth 2.0 AS はそのまま、その上に credential 発行層を載せる」** 設計なので、本リポジトリの

- 認可エンドポイント（PKCE 必須、`authorization-request.ts`）
- トークンエンドポイント（`token-request.ts` / `token-response.ts`、grant の判別共用体）
- 署名鍵プロバイダ・JWKS（`signing-key.ts` / `jwks.ts`）
- Bearer トークン保護リソースの型（`userinfo.ts` のアクセストークン検証）

がそのまま土台になる。**新規に必要なのは「credential フォーマットの署名（SD-JWT VC 等）」「proof of possession 検証」「Credential Issuer Metadata」** であり、認可基盤の作り直しは不要。

## 3. 参照資料

- OpenID for Verifiable Credential Issuance 1.0（Final, 2025-09-16）
  https://openid.net/specs/openid-4-verifiable-credential-issuance-1_0.html
  - 根拠にしている内容: Credential Issuer Metadata（`.well-known/openid-credential-issuer`）、Credential Offer（`credential_offer` / `credential_offer_uri`）、`authorization_code` と Pre-Authorized Code Grant（`urn:ietf:params:oauth:grant-type:pre-authorized_code`）、Credential / Nonce / Deferred / Notification Endpoint の存在。
- OpenID4VC High Assurance Interoperability Profile (HAIP) 1.0（Final）
  https://openid.net/specs/openid4vc-high-assurance-interoperability-profile-1_0-final.html
  - 根拠にしている内容: OID4VCI/OID4VP の相互運用で要求される暗号・フォーマット選択（SD-JWT VC, ES256, PKCE 等）の基準。
- OIDF interop 結果（HAIP 1.0 × OID4VP 1.0 × OID4VCI 1.0）
  https://openid.net/haip-1-0-openid4vp-1-0-achieve-98-in-oidf-interop-testing/
  - 根拠にしている内容: 1.0 群が実装間相互運用テスト済みで成熟していること。
- 関連 IETF: SD-JWT（Selective Disclosure for JWTs）, SD-JWT VC（IETF OAuth WG draft）
  - クレデンシャルフォーマットの一次情報。OID4VCI 本文から参照される。**着手時に最新 RFC/draft 番号を確認すること。**
- OAuth 2.0 Rich Authorization Requests (RFC 9396)
  https://www.rfc-editor.org/rfc/rfc9396
  - 根拠にしている内容: `authorization_details` でクレデンシャル要求を表現する仕組み（既存 `study-material/ext-rich-authorization-requests-rfc9396.md` と接続）。

> 注意: 個別エンドポイントの **正確なセクション番号・MUST/SHOULD 区分**はこのファイルでは断定していない。実装タスク化の際に上記一次情報で確定すること。

## 4. 現在の実装確認

OID4VCI に直接対応する実装は **存在しない**（grep で `credential` 系エンドポイント・`pre-authorized_code`・`openid-credential-issuer` のいずれも未検出）。
ただし土台となる以下は既に存在する。

- `packages/core/src/token-request.ts`: grant の判別共用体（`authorization_code` / `refresh_token`）。新 grant 追加の拡張点が既にある。
- `packages/core/src/token-response.ts`: トークン発行と JWS 署名（`generateTokenResponse`）。
- `packages/core/src/signing-key.ts`, `jwks.ts`: 署名鍵プロバイダ・alg 選択（`selectSigningKeyByAlg`）。SD-JWT VC 署名にも流用可能。
- `packages/core/src/userinfo.ts`: Bearer アクセストークン検証付き保護リソースの実装パターン（Credential Endpoint の雛形になる）。
- `packages/core/src/discovery.ts`: メタデータ生成（別ドキュメントとして `openid-credential-issuer` を足す参考になる）。

## 5. 現在の実装との差分

### 満たしていること（土台として再利用可能）
- 認可コードフロー + PKCE（OID4VCI の `authorization_code` グラントの前提）
- JWS 署名基盤（RS256 必須、ES256 等の alg 選択）
- Bearer トークン保護リソースの検証パターン

### 不足していること
- **Credential Issuer Metadata** エンドポイント（`.well-known/openid-credential-issuer`）
- **Pre-Authorized Code Grant**（`token-request.ts` の grant 判別への追加と、事前発行 code ストアの契約）
- **Credential Endpoint**（proof 検証 → credential 署名・返却）
- **proof of possession 検証**（`jwt` proof の署名検証・`nonce`/`aud` バインディング）
- **クレデンシャルフォーマット署名**（SD-JWT VC など。selective disclosure のハッシュ化・開示構造）
- **Nonce / Deferred / Notification Endpoint**（任意だが HAIP 等で要求されうる）

### Basic OP として必須か
- **必須ではない。** OID4VCI は OIDF の Conformance では **Basic OP とは別カテゴリ**（Verifiable Credentials）であり、Basic OpenID Provider certification の要件には含まれない。よって本トピックは **純粋な拡張機能**。

### セキュリティ上の注意（着手するなら）
- proof の `nonce`/`aud`/`iat` バインディングを厳格化しないと、credential のリプレイ・横取りに繋がる（`study-material/id-token-nonce-binding-and-replay.md` と同型の注意）。
- Pre-Authorized Code は「ユーザー認可ステップを省く」ため、code の **短命・単回使用・tx_code（PIN）バインディング**が認可コード以上に重要。既存の単回使用・TTL ポリシー（`token-lifetime-security-policy.md`）を流用する。
- credential 署名鍵は ID Token 署名鍵と **用途分離**するのが望ましい（鍵ローテーション運用は `signing-key-rotation-operations.md` 参照）。

## 6. 改善・追加を検討する理由

- **なぜ価値があるか**: VC/ウォレット（EUDI Wallet 等）は 2025 年に 1.0 が出揃い、PoC 需要が急増している領域。本リポジトリのコンセプト「最新の OIDC/OAuth 仕様を誰よりも早く検証できる」に最も合致する“次の検証対象”であり、Keycloak / Auth0 でも実装が始まったばかりで「気軽に試せるツール」の空白が大きい。
- **Basic OP には不要だが拡張として有用**: 既存の OAuth 基盤の上に薄く載るため、本リポジトリの差別化（Speed / Portability）を活かしやすい。
- **導入しやすい理由**: grant 判別共用体・署名鍵プロバイダ・Bearer 保護リソースという拡張点が既に揃っている。認可基盤の再設計が不要。
- **導入しにくい理由**: クレデンシャルフォーマット（SD-JWT VC / mdoc）の署名・selective disclosure は **新規の暗号処理**であり、Web Crypto だけで完結するか（特に mdoc の COSE/CBOR）を要検証。外部依存なし方針との緊張がある。
- **利用者メリット**: 「自分の要件が VC 発行で実現できるか」を、IdaaS 契約なしにローカルで試せる。
- **実装しない場合のリスク**: 競合 OSS が VC 対応する中で「最新仕様追随」の看板に対する空白が残る。

## 7. 実装方針の候補（最終判断は人間）

判断材料として方針を列挙する。AI 側で確定しない。

- **方針A: メタデータ + Pre-Authorized Code の最小スライスから**
  まず `.well-known/openid-credential-issuer` と Pre-Authorized Code Grant + Credential Endpoint（フォーマットは SD-JWT VC 一択）だけを実装し、ウォレットとの疎通を最優先で取る。
  - 長所: 最小で「動くものを早く出す」方針に合致。認可ステップ省略で UI 依存が少ない。
  - 短所: authorization_code 経路・proof の網羅は後回しになる。

- **方針B: 既存 authorization_code フローの延長から**
  `authorization_details`(RAR) でクレデンシャル要求を表現し、既存認可コードフローをそのまま使って Credential Endpoint を足す。
  - 長所: 既存資産の再利用が最大。RAR タスク（`ext-rich-authorization-requests-rfc9396.md`）と連動。
  - 短所: RAR 未実装なら依存が増える。

- **クレデンシャルフォーマットの選択**
  - SD-JWT VC（JWS ベース）: Web Crypto で完結しやすく、本リポジトリの Portability と相性が良い → **第一候補**。
  - mdoc/mDL（COSE/CBOR）: Web 標準だけで実装可能か要調査。初期スコープ外を推奨。

- **CLI コード生成との接続**
  `packages/cli` のフレームワークテンプレートに「VCI 発行ルート」を追加生成する形にすると、利用者の入口（CLI でフロー生成）に乗る。`core` は proof 検証・credential 署名ロジックを提供する。

## 8. タスク案（※検討段階のため現時点ではタスク化しない）

> 方針（A/B、フォーマット選択）が未確定なので `tasks/` には落とさない。方針確定後に分割する想定の粒度だけ示す。

1. 一次情報の精読タスク: OID4VCI 1.0 本文で「Credential Issuer Metadata の必須項目」「Pre-Authorized Code Grant のトークンレスポンス」「Credential Endpoint の proof 検証要件」の MUST/SHOULD を抽出し、対応表を作る（`/tech-research` で Gemini に補助させる）。
2. SD-JWT VC 署名/開示を Web Crypto のみで実装可能かの技術検証（PoC）タスク。
3. `.well-known/openid-credential-issuer` メタデータ生成関数の設計タスク（`discovery.ts` と分離する前提）。
4. `token-request.ts` への Pre-Authorized Code Grant 追加の設計タスク（事前発行 code ストア契約 = `resolver-and-store-contract.md` 流用）。
5. Credential Endpoint（proof 検証 + credential 署名）の設計タスク（`userinfo.ts` の Bearer 検証パターン流用）。
6. HAIP 1.0 のどの暗号/フォーマット選択を初期サポートにするかの方針決定タスク。
