# Experimental機能仕様書: Identity Assertion Authorization Grant (ID-JAG) / Cross-App Access (XAA)

- **機能名**: Identity Assertion JWT Authorization Grant（ID-JAG）による Cross-App Access（XAA）
- **feature-id**: `id-jag`
- **準拠仕様**: draft-ietf-oauth-identity-assertion-authz-grant-04（2026-05 版。以下「ID-JAG draft」）、RFC 8693（Token Exchange）、RFC 7521 / RFC 7523（Assertion Framework / JWT Profile for Authorization Grants）、RFC 8414（AS Metadata）
- **作成日**: 2026-08-30
- **ステータス**: `state.yaml` を参照

## 概要

**Cross-App Access（XAA）** は、SSO で同じ IdP を信頼している 2 つのアプリケーションの間の API アクセスを、その IdP が仲介するパターンである。
通常の OAuth では、アプリ A がアプリ B の API を呼ぶには、ユーザーをアプリ B の認可エンドポイントへリダイレクトして同意を取る必要があり、この接続は IdP から見えない。
XAA では、アプリ A は手元の **Identity Assertion**（本機能では OpenID Connect の ID トークン）を IdP のトークンエンドポイントで **ID-JAG（Identity Assertion JWT Authorization Grant）** という署名付き JWT に交換し、それをアプリ B 側の認可サーバーのトークンエンドポイントへ JWT Bearer Grant（RFC 7523）として提示してアクセストークンを得る。
ユーザーの追加同意は発生せず、どのアプリ間アクセスを許すかの判断は IdP の管理者ポリシーに集約される。

本機能は、CLI 生成 OP に次の 2 つの役割を同時に追加する。

1. **IdP 側（発行）**: 既存トークンエンドポイントの Token Exchange grant で `requested_token_type=urn:ietf:params:oauth:token-type:id-jag` を受け付け、自 OP 発行の ID トークンを検証して ID-JAG を発行する
2. **リソースアプリの AS 側（受領）**: 既存トークンエンドポイントに `urn:ietf:params:oauth:grant-type:jwt-bearer` grant を追加し、信頼設定済みの外部 IdP が発行した ID-JAG を検証してアクセストークンを発行する

1 つの生成 OP が両方の役割を持つため、生成 OP を 2 インスタンス起動して信頼関係を設定すれば、XAA の 4 ステップ（SSO → Token Exchange → ID-JAG 提示 → API アクセス）を完結して再現できる。

### 既存 Token Exchange 機能との関係

既存の `token-exchange` 機能（RFC 8693、アクセストークン同士の交換）は本機能の前提ではない。
Token Exchange の grant_type URN は共有するが、ディスパッチ順序で分離する（`requested_token_type=id-jag` のときだけ本機能の分岐に入り、それ以外は既存 token-exchange 分岐か `unsupported_grant_type` に落ちる）。
`--enable id-jag` 単独でも、`--enable token-exchange --enable id-jag` の併用でも動作し、experimental 機能同士でコードを共有しない方針（重複許容）を守る。

## 採用理由（候補評価）

| 観点 | 評価 |
|---|---|
| プロジェクト関連性 | XAA は Okta が主導し 2025 年以降注目されるエンタープライズ SSO の拡張パターンで、IETF OAuth WG の adopted draft（draft-ietf-oauth-identity-assertion-authz-grant）として標準化が進行中。AI エージェントの外部ツールアクセス（draft Appendix A.4）にも適用される。「最新仕様を誰よりも早く検証できる」という本リポジトリのコンセプトに合致する |
| Experimental隔離の妥当性 | トークンエンドポイントへの grant 分岐 2 つ（Token Exchange 内の requested_token_type 分岐、jwt-bearer grant 分岐）と discovery のメタデータ追加のみ。既存 grant のデフォルト挙動は一切変えない |
| core無変更 | 可能。分岐は core の `validateGrantTypeSupported` より前に挿入する（token-exchange / device-authorization-grant で実証済みのパターン）。ID トークンの検証は core 公開 API の `validateIdTokenHint` を再利用する |
| CLI `--enable` 提供 | 可能。`EXPERIMENTAL_FEATURES` へ `id-jag` を追加する |
| 一次資料の成熟度 | draft-04（IETF OAuth WG adopted、2026-05）。Okta の XAA 実装、複数の相互運用実験（IETF hackathon）が存在する。draft 段階なので破壊的変更があり得る点は experimental 隔離の理由そのもの |
| セキュリティ影響 | 新規エンドポイントを追加しない。バックチャネル専用で Cookie / ブラウザ UI を使わない。発行は audience 許可リスト（デフォルト空）で fail-safe、受領は信頼 IdP リスト（デフォルト空）で fail-safe |
| テスト可能性 | 単体、結合（conformance.test.ts）、E2E すべて HTTP レベルで検証可能。E2E は生成 OP を 2 インスタンス起動して実際のクロスドメイン構成を再現する |
| 実装規模 | 中規模。JWS の生成と検証は JARM / core で確立済みのパターンを踏襲する |
| 既存機能との重複 | なし。`token-exchange` はアクセストークンの交換（同一ドメイン内の権限縮小）、本機能は ID トークンからのクロスドメイン認可 grant の発行と受領で、入力と出力の種別が異なる |

## Experimentalにする理由

- 準拠先が IETF draft（-04）であり、クレーム名や必須性が改版で変わり得る
- 信頼設定（`trustedIdentityProviders` / `allowedAudiences`）の設定形状が実運用フィードバックで変わり得る
- IdP とリソース AS のクライアント ID の対応付け（draft §5）をどこまで設定可能にするかが未収束（初期実装は同一 client_id 前提）

## 非目標（Non-goals）

- **SAML 2.0 assertion の subject_token（`urn:ietf:params:oauth:token-type:saml2`、draft §3.2 / §4.5）**: 本 OP は OIDC OP であり SAML を発行しない。他の値は `invalid_request`
- **Refresh Token の subject_token（`urn:ietf:params:oauth:token-type:refresh_token`、draft §4.3）**: draft 上は MAY。ID トークン再取得の省略という利便機能であり初期スコープから外す。`invalid_request` で拒否する
- **`sub_id` クレーム（SAML NameID Subject Identifier、draft §3.2）**: SAML 連携前提の機能のため発行も検証もしない
- **`authorization_details`（RAR、RFC 9396）**: リクエストパラメータとして受けた場合は `invalid_request` で明示拒否。クレームとしても発行しない
- **`actor_token` / `act` クレーム**: draft §4.3 は actor_token の処理規則を定義していない（future extension）。存在すれば `invalid_request` で明示拒否する（draft §9.7 の委譲リスクへの fail-safe）
- **DPoP / `cnf` による sender-constraining（draft §9.8）**: 本リポジトリに DPoP 基盤が無いため見送る。将来 DPoP タスクと合流して検討する
- **step-up authentication（`insufficient_user_authentication`、draft §9.2 / RFC 9470）**: acr ポリシー評価基盤が無いため見送る
- **`tenant` / `aud_tenant` / `aud_sub` / `email` クレーム**: 本 OP はシングルテナントで、subject 解決は `sub` の一致に限る（draft §9.6 のクレーム最小化にも沿う）
- **クライアント ID の対応付け設定（draft §5）**: ID-JAG の `client_id` クレームは IdP で認証したクライアントの client_id をそのまま入れる。要求側アプリが両 AS で同じ client_id を使う前提（Client ID Metadata Document 型の共有名前空間を想定した簡略化）とし、対応表の設定は将来拡張とする
- **ID-JAG 以外の JWT Bearer Grant（素の RFC 7523 assertion）**: jwt-bearer grant は `typ: oauth-id-jag+jwt` の assertion だけを受ける。他の typ は `invalid_grant`
- **`jti` によるリプレイ拒否ストア**: draft §4.4.3 は「アクセストークン失効後に同じ ID-JAG を再提示してよい（ID-JAG がリフレッシュトークンの代替になる）」と定めており、有効期間内の再提示は仕様上の正当な利用形態である。単回使用化はしない（セキュリティ要件の節で根拠を詳述）
- **`audience` / `resource` パラメータの複数指定**: 生成 OP のトークンエンドポイントは重複パラメータを 400 で拒否する（RFC 6749 §3.2）。単一値のみ
- **JIT プロビジョニング フック**: リソース AS 側の subject 解決は「ID-JAG の `sub` をそのままローカル subject として使う」に固定。アカウント作成やマッピングのフックは将来拡張

## ユースケース / 想定利用者

- 「Slack のようなリソースアプリに、Google Drive のような別アプリのデータを、ユーザーの再同意なしで安全に読み込ませたい」というエンタープライズ SSO 構成を、IdaaS 契約前に手元で再現したい開発者
- AI エージェント（クライアント）が、企業 IdP の仲介で外部ツールの API トークンを取得する構成（draft Appendix A.4）の検証
- Token Exchange（RFC 8693）と JWT Bearer Grant（RFC 7523）の組み合わせがどう連鎖するかをプロトコルレベルで確認したい学習目的の PoC

## プロトコルフロー

```text
Requesting App                IdP OP (--enable id-jag)          Resource App AS (--enable id-jag)
(confidential client)         [発行側の役割]                      [受領側の役割]
  |                              |                                  |
  |-- (1) SSO: Authorization --->|                                  |
  |    Code Flow                 |                                  |
  |<-- ID Token -----------------|                                  |
  |                              |                                  |
  |-- (2) POST /token ---------->|                                  |
  |    grant_type=token-exchange |  subject_token(ID Token) を検証   |
  |    requested_token_type=     |  aud が認証クライアントと一致       |
  |      ...token-type:id-jag    |  audience を許可リストで検証        |
  |    subject_token=<ID Token>  |  ID-JAG (typ=oauth-id-jag+jwt)   |
  |    subject_token_type=       |  を RS256 で署名                  |
  |      ...token-type:id_token  |                                  |
  |    audience=<Resource AS の  |                                  |
  |      issuer URL>             |                                  |
  |<-- ID-JAG (token_type=N_A) --|                                  |
  |                              |                                  |
  |-- (3) POST /token ------------------------------------------->|
  |    grant_type=...jwt-bearer  |         assertion の署名を IdP の |
  |    assertion=<ID-JAG>        |         JWKS で検証。iss が信頼    |
  |    ＋クライアント認証           |         リスト内、aud が自 issuer、 |
  |                              |         client_id が認証クライアント|
  |                              |         と一致することを検証         |
  |<-- Access Token（Resource AS 発行）----------------------------|
  |                              |                                  |
  |-- (4) Resource Server へ API リクエスト（Access Token 添付）------>
```

## 入出力

### 発行側リクエスト（IdP、draft §4.3）

- メソッド: `POST /token`（既存トークンエンドポイント。Content-Type 検証、重複パラメータ拒否、クライアント認証の共有パイプラインを分岐より前にそのまま通過する）
- ディスパッチ条件: `grant_type=urn:ietf:params:oauth:grant-type:token-exchange` かつ `requested_token_type=urn:ietf:params:oauth:token-type:id-jag`。この分岐は既存 token-exchange 分岐より**前**に置く

| パラメータ | draft 上 | 本機能 |
|---|---|---|
| `requested_token_type` | REQUIRED | `urn:ietf:params:oauth:token-type:id-jag`（ディスパッチ条件そのもの） |
| `audience` | REQUIRED | 必須。リソース AS の issuer identifier（RFC 8414 §2）。欠落は `invalid_request`。`allowedAudiences` に含まれない値は `invalid_target`。自 OP の issuer と同一の値は `invalid_target`（draft §9.3 のクロスドメイン限定） |
| `subject_token` | REQUIRED | 必須。本 OP が発行した ID トークン。欠落は `invalid_request` |
| `subject_token_type` | REQUIRED | 必須。`urn:ietf:params:oauth:token-type:id_token` のみ受理。欠落と他の値（saml2 / refresh_token を含む）は `invalid_request` |
| `scope` | OPTIONAL | 任意。空白区切り。`allowedScopes` が設定されている場合はその部分集合であること（超過は `invalid_scope`）。未設定時は要求値をそのまま許可（ポリシー判断はリソース AS 側にもあるため。設計判断） |
| `resource` | OPTIONAL | 任意。単一値。絶対 URI で fragment を含まないこと（RFC 8707 §2）。違反は `invalid_request`。検証後そのまま ID-JAG の `resource` クレームに入れる |
| `authorization_details` | OPTIONAL | 非目標。存在すれば `invalid_request` |
| `actor_token` / `actor_token_type` | OPTIONAL | 非目標。存在すれば `invalid_request` |

subject_token（ID トークン）の検証は core の `validateIdTokenHint` を再利用し、次を確認する（draft §4.3.3）。

- 署名が自 OP の ID トークン署名鍵セット（JWKS）で検証できること
- `iss` が自 OP の issuer と一致すること
- `aud` に**認証済みクライアントの client_id が含まれる**こと（draft §4.3.3 の MUST。他クライアント宛て ID トークンの流用を防ぐ）
- `exp` が leeway（60 秒）内で未失効、`iat` が leeway 内で未来でないこと
- `alg=none` と外部鍵取得ヘッダ（jku / jwk / x5u / x5c）の拒否（core 実装の RFC 8725 対策をそのまま享受する）

### 発行側レスポンス（draft §4.3.4）

- ステータス: `200 OK`、`Content-Type: application/json`、`Cache-Control: no-store` / `Pragma: no-cache`

```json
{
  "issued_token_type": "urn:ietf:params:oauth:token-type:id-jag",
  "access_token": "<ID-JAG（署名付き JWT）>",
  "token_type": "N_A",
  "expires_in": 300,
  "scope": "openid profile"
}
```

- `access_token`: ID-JAG 本体。アクセストークンではないが、RFC 8693 §2.2.1 の歴史的経緯でこのフィールド名を使う（draft §4.3.4 の注記どおり）
- `token_type`: 常に `N_A`（アクセストークンではないため。draft REQUIRED）
- `expires_in`: 常に含める（draft RECOMMENDED）。値は `idJagLifetimeSeconds`（デフォルト 300）
- `scope`: draft は「要求と同一なら OPTIONAL」だが判定分岐を避けるため常に含める（token-exchange 機能と同じ設計判断）。scope 要求なしの場合は空文字列
- `refresh_token`: 発行しない（draft SHOULD NOT）

### 発行される ID-JAG（draft §3.1）

JOSE ヘッダー: `{ "alg": "RS256", "typ": "oauth-id-jag+jwt", "kid": "<署名鍵の kid>" }`。
署名鍵は登録鍵セットから RS256 の鍵を選ぶ（JARM と同じ `selectSigningKeyByAlg(keys, 'RS256')`。JWKS エンドポイントで公開される鍵であること）。
`typ` の検証は受領側の必須処理なので、発行側も必ず付ける（RFC 8725 §3.11）。

| クレーム | draft 上 | 本機能の値 |
|---|---|---|
| `iss` | REQUIRED | 自 OP（IdP）の issuer |
| `sub` | REQUIRED | subject_token（ID トークン）の `sub` をそのまま |
| `aud` | REQUIRED | `audience` パラメータの値（リソース AS の issuer）。単一文字列 |
| `client_id` | REQUIRED | 交換を要求した認証済みクライアントの client_id（非目標の節の同一 client_id 前提） |
| `jti` | REQUIRED | 256bit ランダム値（core の `generateRandomString(32)`） |
| `exp` / `iat` | REQUIRED | `iat` = 発行時刻、`exp` = `iat + idJagLifetimeSeconds` |
| `scope` | OPTIONAL | 許可された scope の空白区切り。scope 要求なしなら**クレーム自体を含めない** |
| `resource` | OPTIONAL | `resource` パラメータの値。指定なしなら含めない |
| `auth_time` / `acr` / `amr` | OPTIONAL | subject_token に存在する場合のみ同じ値を引き継ぐ（リソース AS の認証コンテキスト評価材料。draft §3.1） |

`sub_id` / `tenant` / `aud_tenant` / `aud_sub` / `email` / `act` / `authorization_details` は発行しない（非目標）。

### 受領側リクエスト（リソース AS、draft §4.4）

- メソッド: `POST /token`（同上。クライアント認証パイプライン通過後）
- ディスパッチ条件: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer`

| パラメータ | 本機能 |
|---|---|
| `assertion` | 必須。ID-JAG（compact JWS）。欠落は `invalid_request` |
| `scope` | 任意。指定時は ID-JAG の `scope` クレームの部分集合であること（超過は `invalid_scope`）。省略時は ID-JAG の scope を継承 |
| `authorization_details` | 非目標。存在すれば `invalid_request` |

assertion の検証（RFC 7521 §5.2 / RFC 7523 §3 / draft §4.4.1）:

1. compact JWS として 3 パートに分解できること
2. JOSE ヘッダーの `typ` が `oauth-id-jag+jwt` であること（draft MUST / RFC 8725 §3.11）
3. `alg` が存在し `none` でないこと。外部鍵取得ヘッダ（jku / jwk / x5u / x5c）が無いこと
4. ペイロードの `iss` が `trustedIdentityProviders` のいずれかの issuer と一致すること。**かつ自 OP の issuer と異なること**（draft §9.3: IdP は自分が発行した ID-JAG に対して同一ドメイン内でアクセストークンを発行してはならない）
5. 署名がその IdP の JWKS で検証できること（kid 一致を優先し、無ければ alg 一致の鍵を順次試行。鍵ごとの alg ピン留めは core の `validateIdTokenHint` と同じ規則）
6. `aud` が自 OP の issuer と一致すること。文字列、または**要素数 1 の配列**のみ許す（draft §4.4.1 の MUST。要素数 2 以上の配列は不一致として拒否）
7. `exp` が数値で、leeway（60 秒）を考慮して未失効であること
8. `iat` が数値で、leeway を超えて未来でないこと。`nbf` が存在する場合は leeway を考慮して到来済みであること
9. `jti` が非空文字列であること（draft REQUIRED。リプレイ拒否には使わないが構造要件として検証する）
10. `sub` が非空文字列であること
11. `client_id` が**リクエストを認証したクライアントの client_id と一致する**こと（draft §4.4.1 の MUST。ID-JAG の横流しを防ぐクライアント継続性）

### 受領側レスポンス（draft §4.4.2）

自 OP（リソース AS）発行の通常のアクセストークン応答。
発行は core の既存パイプライン（`buildAccessTokenAudience` → `buildAccessTokenPayload` → `AccessTokenIssuer` → `accessTokenStore.set`）を生成コード側で組み合わせる。

```json
{
  "access_token": "<リソース AS 発行のアクセストークン>",
  "token_type": "Bearer",
  "expires_in": 3600,
  "scope": "openid profile"
}
```

- `sub` は ID-JAG の `sub` をそのままローカル subject として使う（非目標の節の JIT 非対応）
- 実効 scope は「ID-JAG の `scope` クレーム（無ければ空）から `offline_access` を除去し、`scope` パラメータがあればその部分集合に縮小」した値
- `expires_in` は `config.accessTokenExpiresIn`。**ID-JAG の残存期間で cap しない**（draft §4.4.3: アクセストークンは grant より長く生きてよく、失効後は同じ ID-JAG を再提示して再取得する設計。token-exchange 機能の寿命 cap とは意図的に異なる）
- `id_token` は発行しない（jwt-bearer は OIDC の認証フローではない。`openid` scope は UserInfo アクセス権としてだけ機能する。設計判断）
- `refresh_token` は発行しない（draft §4.4.3 SHOULD NOT。ID-JAG の再提示が代替）
- アクセストークンの `aud` は既存トークンルートと同じ合成（UserInfo エンドポイントを恒久メンバとして含み、ID-JAG の `resource` クレームがあれば要求対象として追加）

### エラーレスポンス

既存トークンエンドポイントと同一形式の JSON（`Cache-Control: no-store` / `Pragma: no-cache` 付き）。

発行側（IdP）:

| 条件 | HTTP | error |
|---|---|---|
| クライアント認証失敗 | 401 | `invalid_client`（共有パイプライン。分岐より前） |
| クライアントの `grantTypes` に token-exchange URN が未登録 | 400 | `unauthorized_client` |
| public client からの要求 | 400 | `unauthorized_client`（draft §9.1 SHOULD を MUST に強めた設計判断。token-exchange 機能と同じ） |
| `subject_token` / `subject_token_type` / `audience` の欠落 | 400 | `invalid_request` |
| `subject_token_type` が id_token 以外 | 400 | `invalid_request`（error_description で id_token のみ対応と明示） |
| `actor_token` / `authorization_details` の存在 | 400 | `invalid_request`（未対応を明示） |
| `resource` が絶対 URI でない、または fragment を含む | 400 | `invalid_request` |
| subject_token（ID トークン）の検証失敗（署名、iss、aud、exp、iat、構造） | 400 | `invalid_request`。**固定文言**（失敗種別を区別しないオラクル排除。token-exchange 機能の方針を踏襲） |
| `audience` が `allowedAudiences` 外 | 400 | `invalid_target`。固定文言（許可リスト内容を露出しない） |
| `audience` が自 OP の issuer と同一 | 400 | `invalid_target`（クロスドメイン限定違反を error_description で明示。利用者が自力で直せる設定間違いであり、オラクルにはならない） |
| 要求 scope が `allowedScopes` を超過 | 400 | `invalid_scope` |

受領側（リソース AS）:

| 条件 | HTTP | error |
|---|---|---|
| クライアント認証失敗 | 401 | `invalid_client`（共有パイプライン） |
| クライアントの `grantTypes` に jwt-bearer URN が未登録 | 400 | `unauthorized_client` |
| public client からの要求 | 400 | `unauthorized_client` |
| `assertion` 欠落 | 400 | `invalid_request` |
| `authorization_details` の存在 | 400 | `invalid_request` |
| assertion が JWS として不正、`typ` 不一致、必須クレーム欠落 | 400 | `invalid_grant`（RFC 7521 §4.1: assertion の不備は invalid_grant） |
| `iss` が信頼リスト外、または署名検証失敗 | 400 | `invalid_grant`。**両者を区別しない固定文言**（信頼済み IdP リストの構成を探索させない。draft §9.4 の情報開示制限と同じ趣旨） |
| `iss` が自 OP の issuer と同一 | 400 | `invalid_grant`（同一ドメイン内利用の禁止を error_description で明示） |
| `aud` 不一致（複数要素配列を含む） | 400 | `invalid_grant` |
| `exp` 失効 / `iat` 未来 / `nbf` 未到来 | 400 | `invalid_grant` |
| `client_id` クレームが認証クライアントと不一致 | 400 | `invalid_grant` |
| 要求 scope が ID-JAG の scope を超過 | 400 | `invalid_scope` |

draft §4.3.4.3 のエラー例は `invalid_grant` を示すが、これは非規範の例示である。
発行側の subject_token 検証失敗を `invalid_request` に写像するのは、同じ grant_type を共有する既存 token-exchange 機能（RFC 8693 §2.2.2 の解釈）とエラー契約を揃えるための設計判断であり、理解資料に明記する。

## 公開API案（`@maronn-openid-connect/experimental/id-jag`）

subpath export で提供する。
core / 既存 experimental と同じ「合成関数＋ステップ関数」の二層構成とし、他の experimental 機能とコードを共有しない（token-exchange と grant_type URN 定数が重複するが、独立性優先の方針どおり重複を許容する）。
トークンの発行と保存のうち、ID-JAG の署名は本モジュール内で行い（JARM の応答 JWT と同じ自前 compact JWS）、受領側のアクセストークン発行は core の既存部品を生成コード側で組み合わせる。

```typescript
// ---- 定数 ----

export const TOKEN_EXCHANGE_GRANT_TYPE =
  'urn:ietf:params:oauth:grant-type:token-exchange';
export const JWT_BEARER_GRANT_TYPE =
  'urn:ietf:params:oauth:grant-type:jwt-bearer';
export const ID_JAG_TOKEN_TYPE = 'urn:ietf:params:oauth:token-type:id-jag';
export const TOKEN_TYPE_ID_TOKEN = 'urn:ietf:params:oauth:token-type:id_token';
export const ID_JAG_JWT_TYP = 'oauth-id-jag+jwt';
export const ID_JAG_GRANT_PROFILE = 'urn:ietf:params:oauth:grant-profile:id-jag';

// ---- エラー ----

export type IdJagErrorCode =
  | 'invalid_request'
  | 'invalid_grant'
  | 'unauthorized_client'
  | 'invalid_scope'
  | 'invalid_target';

export class IdJagError extends Error {
  readonly code: IdJagErrorCode;
  readonly errorDescription: string;
  readonly statusCode: 400;
}

// ---- 発行側（IdP） ----

/** grant_type と requested_token_type が ID-JAG 発行要求かを判定（生成コードのディスパッチ用） */
export function matchesIdJagIssuanceRequest(params: Record<string, string>): boolean;

/** クライアント認可: grantTypes に token-exchange URN 登録済みか、confidential か */
export function authorizeIdJagIssuanceClient(client: TokenClientInfo): void;

/** 必須・非対応パラメータの検証と型付け */
export function parseIdJagIssuanceParams(params: Record<string, string>): ParsedIdJagIssuanceParams;

/** subject_token（ID トークン）を core の validateIdTokenHint で検証し payload を返す */
export async function resolveIdJagSubject(options: {
  subjectToken: string;
  issuer: string;          // 自 OP の issuer（期待 iss）
  clientId: string;        // 認証済みクライアント（期待 aud）
  jwks: JwkSet;            // 自 OP の ID トークン署名鍵
}): Promise<IdJagSubject>;

/** audience を許可リストと自 issuer 除外で検証する */
export function validateIdJagAudience(options: {
  audience: string;
  issuer: string;
  allowedAudiences: string[];
}): void;

/** scope を allowedScopes（未設定なら素通し）で検証し実効 scope を返す */
export function validateIdJagScope(
  requestedScope: string | undefined,
  allowedScopes: string[] | undefined,
): string[];

/** ID-JAG のクレームセットを組み立てる */
export function buildIdJagClaims(options: { ... }): IdJagClaims;

/** typ=oauth-id-jag+jwt / RS256 で compact JWS を生成する */
export async function createIdJagJwt(options: {
  claims: IdJagClaims;
  signingKey: SigningKey;  // RS256 鍵であること（JARM と同じ契約）
}): Promise<string>;

/** RFC 8693 §2.2.1 形式の応答（token_type: 'N_A'）を組み立てる */
export function buildIdJagIssuanceResponse(options: {
  idJag: string;
  expiresIn: number;
  scope: string[];
}): IdJagIssuanceResponse;

/** 合成関数: 検証から応答生成まで */
export async function processIdJagIssuanceRequest(
  context: IdJagIssuanceContext,
): Promise<IdJagIssuanceResponse>;

// ---- 受領側（リソース AS） ----

/** クライアント認可: grantTypes に jwt-bearer URN 登録済みか、confidential か */
export function authorizeIdJagRedemptionClient(client: TokenClientInfo): void;

/** assertion / scope パラメータの検証と型付け */
export function parseIdJagRedemptionParams(params: Record<string, string>): ParsedIdJagRedemptionParams;

/** assertion（ID-JAG）を信頼 IdP の JWKS で検証し payload を返す */
export async function verifyIdJagAssertion(options: {
  assertion: string;
  issuer: string;                                   // 自 OP の issuer（期待 aud、自己発行拒否）
  clientId: string;                                 // 認証済みクライアント（client_id 一致）
  identityProviders: IdJagTrustedIdentityProvider[]; // { issuer, jwks } の解決済みリスト
  now?: Date;
}): Promise<IdJagAssertionPayload>;

/** scope パラメータと ID-JAG scope クレームから実効 scope を導出（offline_access 除去を含む） */
export function resolveIdJagGrantScope(
  requestedScope: string | undefined,
  assertionScope: string | undefined,
): string[];

/** 合成関数: 検証〜発行素材（subject / scope / resource）の導出。発行は呼び出し側 */
export async function processIdJagRedemptionRequest(
  context: IdJagRedemptionContext,
): Promise<IdJagRedemptionGrant>;
```

依存する core API（公開済みであることを確認済み）: `TokenClientInfo` / `JwkSet` / `SigningKey` / `validateIdTokenHint` / `IdTokenHintError` / `generateRandomString` / `extractAlgorithmParamsFromJwk` / `sanitizeErrorDescription`。
生成コード側でさらに `selectSigningKeyByAlg` / `buildAccessTokenAudience` / `buildAccessTokenPayload` / `createJwtAccessTokenIssuer` / `createOpaqueAccessTokenIssuer` を使う。

`IdJagError` を core の `TokenError` と別クラスにする理由は token-exchange と同じ（`invalid_target` が core の closed enum に無い。生成コードの catch 節に専用分岐を追加する）。

## CLIオプション案

- `maronn-oidc generate <framework> --enable id-jag` で有効化。**デフォルト無効**
- `packages/cli/src/features.ts`: `EXPERIMENTAL_FEATURES` に `'id-jag'`、`OidcFeatureConfig` に `idJag: boolean`、`EXPERIMENTAL_FEATURE_KEYS` に `'id-jag': 'idJag'` を追加
- `packages/cli/src/index.ts` の `withExperimentalPackage` に `features.idJag` を追加
- 生成コードへの追加（**新規ルートファイルは作らない**。すべて条件付き補間で、無効時の生成物を現行とバイト同一に保つ）:
  - `routes/token.ts`（共有 `tokenRouteTemplate`）: `idJagConfig` 定数の export、信頼 IdP の JWKS 解決ヘルパ（`jwksUri` の fetch と TTL キャッシュ）、発行分岐（既存 token-exchange 分岐より前）、受領分岐、catch 節の `IdJagError` 分岐
  - discovery テンプレート: `grantTypesSupported` へ token-exchange URN（未含有時）と jwt-bearer URN を追加。応答へ `identity_chaining_requested_token_types_supported`（draft §7.1）と `authorization_grant_profiles_supported`（draft §7.2）を追加。**信頼 IdP や許可 audience の内容はメタデータに出さない**（draft §9.4 MUST NOT）
  - `config.ts` のサンプルクライアント: `grantTypes` へ両 URN を条件付きで追加し、XAA の両役割を試せるコメントを付す
  - conformance テンプレート: `idJagConformanceBlock(features)` / `idJagConformanceClients(features)` を hono と web-standard の両方に並置
- サンプル側:
  - `samples/*/package.json` の `generate` スクリプトに `--enable id-jag` を追加して再生成
  - `samples/*` の手書きエントリ（`app.ts` など）で、環境変数から `idJagConfig` を上書きする（`XAA_ALLOWED_AUDIENCES` / `XAA_TRUSTED_IDP_ISSUER` / `XAA_TRUSTED_IDP_JWKS_URI`）。E2E の 2 インスタンス構成が env だけで組めるようにするため

## 設定値とデフォルト

`routes/token.ts` が export する `idJagConfig`（conformance テストと手書きエントリが書き換える。既存 `tokenExchangeConfig` と同じ形態）。

| 設定 | デフォルト | 説明 |
|---|---|---|
| `allowedAudiences` | `[]` | 発行側: ID-JAG を発行してよいリソース AS の issuer の許可リスト。空のとき発行要求はすべて `invalid_target`（fail-safe） |
| `idJagLifetimeSeconds` | `300` | ID-JAG の有効期間（秒）。draft の例示値。短命にして再発行で回す運用が前提 |
| `allowedScopes` | `undefined` | 発行側: 許可する scope の上限リスト。`undefined` は素通し（リソース AS 側ポリシーに委ねる） |
| `trustedIdentityProviders` | `[]` | 受領側: 信頼する IdP のリスト。`{ issuer, jwksUri?, jwks? }`。空のとき jwt-bearer はすべて `invalid_grant`（fail-safe）。`jwks` はインライン JWK セット、`jwksUri` は生成コードのヘルパが fetch して 300 秒キャッシュする。両方あれば `jwks` を優先 |
| アクセストークン有効期間（受領側） | `config.accessTokenExpiresIn` | 専用設定は持たない |

## バリデーション

発行側（順序どおり。1〜2 は既存共通処理）:

1. Content-Type / 重複パラメータ / grant_type 欠落の検証（既存共通処理）
2. クライアント認証（既存共有パイプライン。失敗は 401 `invalid_client`）
3. `matchesIdJagIssuanceRequest` が真のとき本機能へ分岐（既存 token-exchange 分岐より前）
4. `authorizeIdJagIssuanceClient`: grantTypes 未登録 / public client → `unauthorized_client`
5. `parseIdJagIssuanceParams`: 必須欠落、非対応 subject_token_type、actor_token / authorization_details の存在、resource の構文違反 → `invalid_request`
6. `resolveIdJagSubject`: ID トークンの署名 / iss / aud（=認証クライアント）/ exp / iat 検証。失敗は固定文言の `invalid_request`
7. `validateIdJagAudience`: 自 issuer と同一 → `invalid_target`（明示文言）。許可リスト外 → `invalid_target`（固定文言）
8. `validateIdJagScope`: `allowedScopes` 超過 → `invalid_scope`
9. `buildIdJagClaims` → `createIdJagJwt`（RS256 / typ / kid）→ `buildIdJagIssuanceResponse`

受領側:

1. （既存共通処理とクライアント認証。同上）
2. `params.grant_type === JWT_BEARER_GRANT_TYPE` のとき本機能へ分岐
3. `authorizeIdJagRedemptionClient`: grantTypes 未登録 / public client → `unauthorized_client`
4. `parseIdJagRedemptionParams`: assertion 欠落 / authorization_details の存在 → `invalid_request`
5. 生成コード: `idJagConfig.trustedIdentityProviders` の各エントリの JWKS を解決（インライン優先、`jwksUri` は fetch + キャッシュ）
6. `verifyIdJagAssertion`: 入出力の節の 11 項目。失敗は `invalid_grant`
7. `resolveIdJagGrantScope`: scope パラメータ超過 → `invalid_scope`。`offline_access` は常に除去
8. 生成コード: core `buildAccessTokenAudience`（`resource` クレームがあれば要求対象に渡す）→ `buildAccessTokenPayload` → issuer → `accessTokenStore.set`（`sub` は ID-JAG の `sub`、`grantId` は新規採番）→ 通常のトークン応答（id_token / refresh_token なし）

## エラー処理

- すべて JSON（既存トークンエンドポイント形式）。リダイレクトは存在しない
- `IdJagError` は生成コードの catch 節の専用分岐で処理する（既存 `TokenExchangeError` 分岐と同型）
- 発行側の subject_token 検証失敗は固定 error_description（失敗種別を区別しない）
- 受領側の「iss が信頼リスト外」と「署名検証失敗」は同一の固定 error_description（信頼 IdP 構成の探索防止）。それ以外の assertion 検証失敗（typ / aud / exp / client_id など）は、クライアントが自分の持つ assertion から自力で確認できる情報のみを述べる個別文言でよい
- error_description は `sanitizeErrorDescription` を通す

## セキュリティ要件

| 脅威 | 対策 | 検証方法 |
|---|---|---|
| 盗まれた ID トークンからの ID-JAG 取得 | 発行はクライアント認証必須＋public client 拒否＋ID トークンの `aud` が認証クライアントと一致することの検証（draft §4.3.3 MUST）。他クライアント宛て ID トークンでは交換できない | 単体＋結合: aud 不一致 ID トークンの拒否 |
| 盗まれた ID-JAG の横流し（別クライアントによる redemption） | 受領はクライアント認証必須＋`client_id` クレームと認証クライアントの一致検証（draft §4.4.1 MUST）。ID-JAG 単体ではアクセストークンを取れない | 単体＋結合＋E2E: 別クライアント認証での redemption 拒否 |
| audience 差し替え（別の AS 向け grant の流用） | `aud` は自 issuer 完全一致（配列は要素数 1 のみ）。発行側は `allowedAudiences` 許可リスト（デフォルト空） | 単体＋結合: aud 不一致 / 複数要素配列 / リスト外 audience の拒否 |
| 同一ドメイン内での権限拡大（draft §9.3） | 発行側は `audience == 自 issuer` を拒否し、受領側は `iss == 自 issuer` を拒否する二重ガード | 単体＋結合: 自分自身への発行と自己発行 ID-JAG の redemption の拒否 |
| 偽造 ID-JAG | 信頼 IdP の事前登録 JWKS のみで署名検証。`alg: none` 拒否、外部鍵取得ヘッダ（jku / jwk / x5u / x5c）拒否、鍵ごとの alg ピン留め（RFC 8725） | 単体: 改ざん署名 / alg none / jku 付きヘッダの拒否 |
| ID-JAG のリプレイ | 有効期間内の再提示は draft §4.4.3 が意図する正当な利用形態（リフレッシュトークンの代替）なので単回使用化しない。束縛はクライアント認証＋`client_id` 一致＋`exp`（デフォルト 300 秒）で行い、盗んだ第三者は資格情報なしでは使えない。`jti` は構造検証のみ | 仕様レビュー（理解資料に設計判断として明記）＋結合: exp 失効後の拒否 |
| 信頼 IdP リストの探索（オラクル） | iss 非信頼と署名失敗の error_description を同一固定文言にする。discovery にも信頼リストを出さない（draft §9.4 MUST NOT） | 結合: 両ケースの応答同一性の固定検証 |
| subject_token の存在 / 有効性オラクル | 発行側の ID トークン検証失敗は失敗種別を区別しない固定文言 | 結合: 各失敗ケースの応答同一性 |
| SSRF（JWKS 取得） | `jwksUri` は静的設定からのみ読む。assertion の内容（iss や jku）から取得先 URL を導出する経路を作らない。fetch は生成コード側にあり、利用者が確認と差し替えをできる | 単体（モジュールは JwkSet を受け取るだけで fetch しない構造の確認）＋仕様レビュー |
| scope による権限拡大 | 発行側は `allowedScopes`（設定時）の部分集合、受領側は ID-JAG の scope クレームの部分集合のみ許可。`offline_access` は受領側で常に除去し refresh_token も発行しない | 単体＋結合: 超過 scope の拒否、offline_access 除去の固定検証 |
| 鍵の取り違え | ID-JAG 署名は RS256 固定で `selectSigningKeyByAlg` により RS256 鍵を選ぶ（JARM と同じ契約）。kid をヘッダに含め、JWKS で公開される鍵のみ使う | 単体: ヘッダの alg / typ / kid の固定検証 |

**ログ禁止情報**: `subject_token`（ID トークン）、発行した ID-JAG、受領した `assertion`、発行したアクセストークン、`client_secret`、Authorization ヘッダ。
ログに出してよいのは client_id、ID-JAG の `jti`、エラーコードのみ。

## プライバシー考慮

- ID-JAG は要求クライアントが中継する JWT であり、クライアントから中身が見える。含めるクレームを `sub` と認証コンテキスト（auth_time / acr / amr）に最小化し、`email` などの属性クレームは含めない（draft §9.6 の最小化方針）
- 受領側が UserInfo で返す属性は、リソース AS 自身のユーザーストアと scope に従う。ID-JAG 経由で IdP 側の属性がリソース AS に流れることはない
- 受領側ストアに保存されるアクセストークンのメタデータは既存アクセストークンと同一項目で、新たな保持情報はない

## パッケージ配置と境界

```text
packages/experimental/
  package.json          # exports["./id-jag"] を追加
  src/id-jag/
    index.ts             # 公開API
    issue-id-jag.ts      # 発行側（IdP）: parse / authorize / subject 検証 / audience / scope / claims / JWS / response
    issue-id-jag.test.ts
    redeem-id-jag.ts     # 受領側（リソース AS）: parse / authorize / assertion 検証 / scope 導出
    redeem-id-jag.test.ts
```

### 依存方向（必須遵守）

```text
packages/core ──X──> packages/experimental（import禁止）
packages/cli  ─────> @maronn-openid-connect/experimental（生成コードの依存として明示）
@maronn-openid-connect/experimental ─────> @maronn-openid-connect/core（許可）
```

- core には一切手を入れない。`id-jag` 無効時の生成コードは現行とバイト同一
- 既存 experimental 機能（token-exchange を含む）とコードを共有しない。grant_type URN 定数の重複は許容する
- モジュールは fetch を行わない（`jwksUri` の解決は生成コードの責務）

## テスト計画

### 単体テスト（packages/experimental/src/id-jag/*.test.ts）

- **発行側 正常系**: パラメータ型付けの固定検証 / ID トークン検証通過時の subject 導出 / audience 許可 / scope 素通しと許可リスト部分集合 / クレームセット（iss / sub / aud / client_id / jti / exp / iat / scope / resource / auth_time / acr / amr）の固定検証 / JWS ヘッダー（alg RS256 / typ oauth-id-jag+jwt / kid）の固定検証 / 応答（issued_token_type / token_type N_A / expires_in / scope）の固定検証 / scope 要求なしのとき scope クレームが存在しないこと
- **発行側 異常系**: 必須欠落 / 非対応 subject_token_type（saml2 / refresh_token / access_token）/ actor_token / authorization_details / resource 構文違反 / 署名不正 / iss 不一致 / aud（クライアント）不一致 / exp 失効の各 ID トークン → 固定文言 `invalid_request` の応答同一性 / audience リスト外と自 issuer → `invalid_target` / allowedScopes 超過 → `invalid_scope` / grantTypes 未登録と public client → `unauthorized_client`
- **受領側 正常系**: 正しい ID-JAG の検証通過と payload 導出 / kid 一致鍵の選択 / aud が単一要素配列の受理 / scope 継承と縮小 / offline_access 除去 / 複数 IdP 設定時の iss による選択
- **受領側 異常系**: assertion 欠落 → `invalid_request` / 非 JWS / typ 不一致 / alg none / jku 付き / iss 非信頼 / 署名改ざん（iss 非信頼と同一文言の固定検証）/ iss 自己 / aud 不一致と複数要素配列 / exp 失効 / iat 未来 / nbf 未到来 / jti 欠落 / sub 欠落 / client_id 欠落と不一致 → `invalid_grant` / scope 超過 → `invalid_scope` / grantTypes 未登録と public client → `unauthorized_client`
- CLAUDE.md の規約（should + 動詞、合格値一意固定、it 内条件分岐なし）に従う。JWS の生成には Web Crypto でテスト内生成した鍵を使う

### 結合テスト（conformance.test.ts テンプレート追加、`id-jag` 有効時のみ生成）

- Authorization Code Flow で ID トークン取得 → `idJagConfig.allowedAudiences` を一時設定して ID-JAG 発行 → 応答フィールドと ID-JAG のヘッダー / クレームをデコードして固定検証（テスト後に設定を復元。PAR / token-exchange の conformance と同じ書き換えパターン）
- テスト内生成の鍵で署名した ID-JAG を `trustedIdentityProviders`（インライン jwks）で受領し、アクセストークン発行 → UserInfo / introspection で sub / client_id / scope を固定検証
- 同じ ID-JAG の再提示で 2 本目のアクセストークンが取れること（draft §4.4.3 の契約固定）
- 自 OP 発行の ID-JAG を自 OP へ提示 → `invalid_grant`（同一ドメイン拒否）
- 発行側 / 受領側の主要エラーケース（前節の表を網羅）
- discovery: `grant_types_supported` に両 URN、`identity_chaining_requested_token_types_supported` と `authorization_grant_profiles_supported` の値を固定検証。無効時はいずれも出ず jwt-bearer が `unsupported_grant_type` になること

### E2Eテスト（tests/e2e）

- `playwright.config.ts` の webServer にサンプル OP の 2 インスタンス目（リソース AS 役、別ポート、別 issuer、別永続化パス）を追加する。1 インスタンス目（IdP 役）には `XAA_ALLOWED_AUDIENCES` で 2 インスタンス目の issuer を許可させ、2 インスタンス目には `XAA_TRUSTED_IDP_ISSUER` / `XAA_TRUSTED_IDP_JWKS_URI` で 1 インスタンス目を信頼させる（サンプルの手書きエントリが env から `idJagConfig` を設定する）
- spec は実ブラウザで IdP にログインして ID トークンを取得し（既存 `/start` ルートと testid を再利用）、バックチャネルで発行（IdP）と redemption（リソース AS）を行い、リソース AS の UserInfo で subject を固定検証する（token-exchange の delegation spec と同じ「ブラウザ＋バックチャネル」パターン）
- 負の検証: 自 OP（IdP）への redemption 提示 → `invalid_grant` / 別クライアント資格情報での redemption → `invalid_grant` / discovery のメタデータ検証
- 両 OP が discovery で ID-JAG 対応を広告していない場合は `test.skip`（共有 spec suite を全サンプルで green に保つ）

### 相互運用性

- draft §4.3.1 / §4.3.4 / §4.4 の実例と生成 OP の要求 / 応答をフィールド単位で突き合わせる検証を結合テストに含める

## ドキュメント要件

- notes リポジトリの `implementation-guides/experimental/` に `id-jag.ja.md` / `id-jag.en.md` を追加（実装コード全文、CLI 注入コード、E2E spec を掲載）
- `packages/experimental/README.md` の提供機能表に `id-jag` 行を追加
- 生成コード内コメントに draft のセクション番号と Experimental である旨を明記

## Changeset要件

- `@maronn-openid-connect/experimental`: **手で書かない**（CI が patch を自動生成する）
- `@maronn-openid-connect/cli`: minor（`--enable id-jag` の追加。既存デフォルト挙動は不変）
- core: 変更なし（changeset 不要）

## 実装順序

1. `src/id-jag/` の実装と単体テスト、`package.json` への subpath export 追加（完了条件 1）
2. `packages/cli` の feature フラグ追加（features.ts / index.ts）と既存 CLI テストの feature オブジェクト更新
3. テンプレート変更: `tokenRouteTemplate` の 2 分岐＋`idJagConfig`＋JWKS 解決ヘルパ＋catch 分岐、discovery、config.ts のサンプルクライアント、conformance テンプレート（hono と web-standard 両方）（完了条件 2、4、6）
4. `--enable id-jag` なし生成のバイト同一確認（完了条件 3）
5. サンプル 4 種の generate スクリプト更新と再生成、手書きエントリへの env 読み込み追加
6. E2E（playwright.config.ts の 2 インスタンス化と spec 追加）（完了条件 5）
7. ドキュメントと changeset（完了条件 7）

## 完了条件

1. `pnpm --filter @maronn-openid-connect/experimental test` で単体テストが全て通る
2. `maronn-oidc generate hono --enable id-jag` の生成コードで conformance.test.ts（ID-JAG ケース含む）が通る
3. `--enable id-jag` なしの生成コードが現行とバイト単位で同一
4. 4 フレームワーク＋web-standard で両分岐入りの token ルートが生成される
5. tests/e2e に 2 OP 構成の XAA フロー Playwright テストが追加され通過する
6. discovery / エラー応答が本仕様の表と一致する
7. changeset（cli）とドキュメントが追加されている

## 未解決事項

- **U1（クライアント ID 対応付け）**: draft §5 は IdP がクライアントとリソース AS 間の client_id 対応表を持つことを想定するが、初期実装は同一 client_id 前提とした。対応表を `idJagConfig` に足すかは利用フィードバック待ち（非目標に記録済み。ブロッカーではない）
- **U2（draft の改版追随）**: draft-05 以降でクレームや必須性が変わった場合は本仕様を改版する。`sources.md` に -04 の取得日を記録した

## 将来の昇格考慮

- 昇格条件の目安: (1) draft が RFC になる、または WG last call に到達する (2) conformance テストが 2 サイクル以上安定 (3) 信頼設定の形状への変更要望が収束
- 昇格時の作業: core の grant ディスパッチへの統合、`TokenErrorCode` への `invalid_target` 追加、`ProviderMetadata` への新メタデータ統合
- 拡張候補: refresh_token subject_token 対応、RAR（authorization_details）、DPoP による sender-constraining（draft §9.8）、client_id 対応表、step-up（RFC 9470）
