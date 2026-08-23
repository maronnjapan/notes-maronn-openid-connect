# 拡張: OpenID for Verifiable Presentations (OID4VP) 1.0 と Self-Issued OP v2 (SIOPv2)

## ステータス

🟢 拡張機能 / 未着手（検討段階：方針未確定のためタスク化しない）

## 1. このトピックで確認したいこと

`study-material/ext-openid4vci-credential-issuance.md` が **「OP がクレデンシャルを発行する」発行側**を扱うのに対し、
本ファイルはその対になる **「クレデンシャルを提示・検証する」側** を扱う。具体的には次の 2 仕様。

- **OpenID for Verifiable Presentations (OID4VP) 1.0**: Verifier（検証者）が Wallet に Verifiable Presentation を要求し、`vp_token` として受け取るフロー。
- **Self-Issued OpenID Provider v2 (SIOPv2)**: ユーザーのウォレット自身が「OP」として振る舞い、自己発行の ID Token を返すモデル。

このファイルでは、本リポジトリ（= 既存の OIDC Provider / RP 基盤を持つ OSS）から見て、

- これらが **発行側 (OID4VCI) とどう役割分担するか**（重複させない）
- 本リポジトリが取りうる立場（Verifier として実装する／参考実装に留める）
- 既存の認可リクエスト処理・JWS 検証資産をどこまで流用できるか

を整理する。OID4VCI と共通する VC エコシステムの基礎説明は繰り返さず、本ファイルは **提示・自己発行に固有の差分**に絞る。

## 2. 関連する仕様・基準

> 共通の基礎（JWS/alg ポリシー、nonce バインディング、認可リクエスト拡張）は既存ファイル参照。
> - 認可レスポンスの `response_mode` / form_post: `study-material/response-mode-form-post.md`
> - JARM（署名付き認可レスポンス）: `study-material/ext-jarm-jwt-secured-authorization-response.md`
> - JAR / request object: `study-material/ext-jar-request-object-rfc9101.md`
> - nonce/リプレイ対策: `study-material/id-token-nonce-binding-and-replay.md`
> - 署名検証・alg none 防御: `study-material/jws-algorithm-policy-and-alg-none-defense.md`
> - 発行側（対になる仕様）: `study-material/ext-openid4vci-credential-issuance.md`

### 2.1 OID4VP 1.0 の位置づけ（一次情報の確認結果）

- **ステータス**: OID4VP **1.0 Final**。OpenID Foundation により **2025-07-09 に最終版として公開**された。
- 技術的な核:
  - 新しい **`response_type=vp_token`** を定義し、Verifier が Verifiable Presentation を「VP Token」というコンテナで受け取る。
  - **DCQL（Digital Credentials Query Language）** によって、要求するクレデンシャル/クレームを宣言的に問い合わせる（旧来の Presentation Exchange の `presentation_definition` も後方互換的に扱われる文脈がある）。
  - 2 つの伝送経路: **(a) OAuth 2.0 の HTTPS リダイレクト**（従来型 redirect/`response_mode`）と、**(b) ブラウザの Digital Credentials API (DC API)** 経由。後者はブラウザがウォレット選択を仲介する新しいモデル。
- OID4VP は OAuth 2.0 の認可リクエスト/レスポンスの語彙（`client_id`, `nonce`, `response_mode`, `state`, request object 等）を流用するため、本リポジトリの認可リクエスト処理と語彙が重なる。

### 2.2 SIOPv2 の位置づけ（一次情報の確認結果）

- **ステータス**: **Implementer's Draft（最終版ではない）**。OID4VP/OID4VCI が 1.0 Final に到達したのに対し、SIOPv2 は **まだ draft 段階**である点に注意（公開日・最終化時期は本ファイル作成時点で確定情報として断定しない＝不明点として明記）。
- 概要: 通常の OIDC では「OP = サーバー」だが、SIOPv2 では **ユーザーのウォレットがローカルで OP として ID Token を自己発行**する。`client_id` のスキーム（例: redirect/DID 系）や、自己発行 ID Token の `sub` を鍵から導出する点が通常 OIDC と異なる。
- OID4VP と SIOPv2 は **組み合わせて使われる**ことが多い（自己発行 ID Token と VP Token を同時に返す）。

### 2.3 本リポジトリとの接点（役割の整理）

重要な前提: 本リポジトリは **OP（Issuer 寄り）** である。OID4VP の **Verifier** と SIOPv2 の **自己発行 OP（ウォレット）** は、本来この OSS の主役割とは異なる。したがって:

- **OID4VP の Verifier 機能**: 「本リポジトリが利用者の RP 実装で VP を検証する」ユースケースなら、認可リクエスト生成・`vp_token` 受領・VP/クレデンシャル署名検証として **部分的に流用可能**。
- **SIOPv2 のウォレット側**: 本リポジトリの主目的（サーバー型 OP の検証）とは方向が異なるため、**参考実装/検証の優先度は低い**。ただし「自己発行 ID Token の検証側（Verifier）」としてなら接点がある。

## 3. 参照資料

- OpenID for Verifiable Presentations 1.0（Final, 2025-07-09）
  https://openid.net/specs/openid-4-verifiable-presentations-1_0.html
  （Final 版: https://openid.net/specs/openid-4-verifiable-presentations-1_0-final.html ）
  - 根拠にしている内容: `response_type=vp_token` / VP Token、DCQL、HTTPS redirect と Digital Credentials API の 2 経路。
- GitHub: openid/OpenID4VP（仕様の編集・issue 追跡）
  https://github.com/openid/OpenID4VP
- Self-Issued OpenID Provider v2（Implementer's Draft）
  https://openid.net/specs/openid-connect-self-issued-v2-1_0.html
  - 根拠にしている内容: 自己発行 OP・自己発行 ID Token の概念。**ステータスが draft である点は着手前に再確認すること。**
- OpenID4VC High Assurance Interoperability Profile (HAIP) 1.0（Final）
  https://openid.net/specs/openid4vc-high-assurance-interoperability-profile-1_0-final.html
  - 根拠にしている内容: OID4VP の相互運用に要求される暗号・フォーマット・クエリ選択。
- OIDF interop 結果
  https://openid.net/haip-1-0-openid4vp-1-0-achieve-98-in-oidf-interop-testing/

> 注意: OID4VP の `vp_token`/DCQL の **正確なパラメータ名・必須/任意区分**、SIOPv2 の `client_id` スキームの詳細は、実装着手前に一次情報で確定すること。本ファイルは構造把握に留める。

## 4. 現在の実装確認

OID4VP / SIOPv2 に対応する実装は **存在しない**（`vp_token`, `presentation`, `dcql`, `self-issued` のいずれも未検出）。
土台として流用しうる既存資産:

- `packages/core/src/authorization-request.ts`: 認可リクエスト語彙（`nonce`, `state`, `response_type`, `redirect_uri` 検証）。OID4VP は同じ語彙を多く共有する。
- `packages/core/src/crypto-utils.ts`（`verify`）/ `jwks.ts`: JWS 検証基盤。VP/クレデンシャル/自己発行 ID Token の署名検証に流用可能。
- `study-material/ext-jarm-jwt-secured-authorization-response.md` / `response-mode-form-post.md`: OID4VP が使う応答モードの議論と接続。

## 5. 現在の実装との差分

### 満たしていること（Verifier 視点で流用可能）
- 認可リクエストの語彙・`nonce`/`state` 処理
- JWS 署名検証（alg none 防御込み）

### 不足していること
- `response_type=vp_token` の生成/受領経路
- **DCQL** クエリの組み立て・解釈
- VP Token / Verifiable Presentation の **構造検証**（埋め込みクレデンシャルの署名・有効期限・holder binding）
- **Digital Credentials API (DC API)** 経由の応答取得（ブラウザ統合は本リポジトリの Web 標準方針と相性はよいが、ブラウザ依存）
- SIOPv2 の **自己発行 ID Token 検証**（`sub` の鍵導出・`client_id` スキーム）

### Basic OP として必須か
- **必須ではない（純粋な拡張）。** OID4VP/SIOPv2 は Basic OpenID Provider certification の範囲外。さらに本リポジトリの主役割（サーバー型 OP）とは **担当アクターが異なる**（Verifier / Wallet 側）ため、OID4VCI（発行側）よりも導入の自然さは低い。

### セキュリティ上の注意
- VP の **holder binding**（提示者が本当にクレデンシャルの所有者か）検証を欠くと、クレデンシャル横取りが成立する。これは ID Token の nonce バインディング（`id-token-nonce-binding-and-replay.md`）と同型かつより厳格な検証が要る。
- DC API 経路は origin バインディングなどブラウザ固有のセキュリティ前提があり、redirect 経路とは脅威モデルが異なる。

## 6. 改善・追加を検討する理由

- **なぜ価値があるか**: OID4VP は 2025-07 に 1.0 Final となり、EUDI Wallet 等の提示フローで採用が進む。本リポジトリの利用者が「VC を発行できたら、それをどう検証するか」を一気通貫で試せると、OID4VCI とセットで検証価値が高い。
- **Basic OP には不要だが拡張として有用**: 発行（OID4VCI）と提示（OID4VP）はペアで意味を持つため、片方だけだと「動くデモ」になりにくい。
- **導入しやすい点**: 認可リクエスト語彙と JWS 検証が既にある。
- **導入しにくい点**:
  - 役割が Verifier / Wallet 側にずれるため、本リポジトリの「OP を試す」という主目的から外れる。スコープ判断が必要。
  - SIOPv2 が **まだ draft** であり、「最新仕様に忠実」を掲げる以上、最終化前に深入りすると追随コストが発生する。
- **実装しない場合のリスク**: OID4VCI のみ対応だと提示フローを別ツールに委ねる必要があり、一気通貫の検証体験が作れない。

## 7. 実装方針の候補（最終判断は人間）

- **方針A: スコープ外と判断し「参照ドキュメント」に留める**
  本リポジトリは発行側 (OID4VCI) に集中し、提示は外部ツール（既存ウォレット/Verifier）に委ねる。本ファイルはロードマップ上の認識合わせに使う。
  - 長所: 主目的（サーバー型 OP の検証）に集中できる。draft の SIOPv2 に振り回されない。
  - 短所: 一気通貫デモが作れない。

- **方針B: OID4VP Verifier の最小受領のみ**
  `vp_token` を受け取り、埋め込み SD-JWT VC の署名・有効期限・nonce/holder binding を検証する **検証ライブラリ**として `core` に薄く足す（DCQL は最小サブセット、DC API は後回し）。
  - 長所: 既存 JWS 検証資産の延長。OID4VCI とペアで一気通貫検証が可能になる。
  - 短所: Verifier 役割の追加で OSS の立ち位置が広がる。

- **SIOPv2 の扱い**
  Final 化されるまでは **検証側（自己発行 ID Token の verify）だけ**を様子見対象とし、ウォレット側の自己発行実装は着手しない。

## 8. タスク案（※検討段階のため現時点ではタスク化しない）

> OID4VCI（発行側）の方針が固まる前に提示側へ進むべきではない。方針A/B が未確定なのでタスク化しない。

1. スコープ判断タスク: 「本 OSS は OID4VP の Verifier 機能を持つべきか／発行側に集中すべきか」を、利用者ユースケース（一気通貫デモの需要）と照らして決める。
2. 一次情報精読タスク: OID4VP 1.0 の `vp_token`/DCQL の必須パラメータと、DC API 経路 vs redirect 経路の差分を抽出（`/tech-research`）。
3. SIOPv2 のステータス追跡タスク: Implementer's Draft → Final の進捗を定点観測し、Final 化時に再評価する。
4. （方針B 採用時）SD-JWT VC を埋めた VP Token の署名・有効期限・holder binding を Web Crypto のみで検証する PoC タスク。
