# 理解資料: Dynamic Client Registration（dynamic-client-registration）

この資料は、プロジェクト所有者が Dynamic Client Registration（以下 DCR）を正確に理解し、仕様書（`specification.md`）の判断を検証できるようにするためのものである。
仕様の要約ではなく、このリポジトリの実装と運用への対応付けを説明する。

## 解決する問題

この OP でクライアントを増やす方法は、現状では静的設定の編集しかない。
生成コードの `config.ts` にある `defaultRegisteredClients`（in-memory の Map）へエントリを書き足し、ビルドと再起動を経てはじめて新しいクライアントが使える。
この運用は 2 つの場面で摩擦になる。

1 つめは OIDF Conformance Suite の実行である。
Suite の多くのテストプランは「テスト開始時に OP へクライアントを動的登録できる」前提で組まれており、DCR の無い OP は静的クライアント設定のプランに限定される。
2 つめは、接続時に DCR を前提とするエコシステムのクライアント検証である。
MCP（Model Context Protocol）の authorization 仕様が典型で、クライアントは接続先の OP に対して実行時に自分を登録しにくる。

DCR はこの両方を「`POST /register` に JSON を送ると `client_id` が返り、そのままフローが動く」という 1 本の API で解決する。

## 背景標準

DCR の標準は 2 層になっている。

- **RFC 7591**（OAuth 2.0 Dynamic Client Registration Protocol、2015）: OAuth 一般のクライアント登録。メタデータの語彙と既定値、リクエストとレスポンスの形式、エラーコードを定める
- **OpenID Connect Dynamic Client Registration 1.0**: RFC 7591 の OIDC 版。OIDC 固有メタデータ（`id_token_signed_response_alg` など）を足し、`redirect_uris` を REQUIRED に格上げする

両者は同じエンドポイントの仕様であり、対立しない。
本機能は RFC 7591 を基礎に、OIDC 版の制約（`redirect_uris` REQUIRED）を重ねたサブセットを実装する。
登録後の参照・更新・削除を定める **RFC 7592**（Management Protocol）は別仕様であり、本機能では実装しない。

## 基礎概念

**クライアントメタデータ**は、クライアントの属性を表す JSON のフィールド群である（`redirect_uris`、`token_endpoint_auth_method`、`grant_types` など）。
重要なのは、各フィールドに仕様上の既定値が定義されていることで、省略された登録は「既定値で登録した」ことになる。
`token_endpoint_auth_method` を省略すると `client_secret_basic`、`grant_types` を省略すると `["authorization_code"]`、`response_types` を省略すると `["code"]` になる。

**未知フィールドの扱い**は DCR の相互運用性の要である。
RFC 7591 §2 は「理解しないメタデータは無視しなければならない（MUST ignore）」と定める。
クライアントが送った `logo_uri` を OP が理解しなくても、登録はエラーにならず、単にそのフィールドが登録されないだけである。
この規則があるため、機能の少ない OP に多機能なクライアントを向けても登録自体は通る。

**オープン登録**は、認可なしで登録を受け付ける運用である。
RFC 7591 §3.1 は「相互運用性のため、認可なしの登録を許すべき（SHOULD）」とし、同時に §5 で DoS への考慮（rate-limit MAY）を求める。
登録に事前資格を要求したい OP のために、**initial access token**（登録リクエストに載せる Bearer トークン）という仕組みも定義されている。

## 登場人物

- **登録するクライアント**: `POST /register` にメタデータを送るソフトウェア。Conformance Suite、MCP クライアント、PoC のテストアプリなど
- **OP（このリポジトリの生成コード + experimental + core）**: メタデータを検証し、`client_id` と `client_secret` を払い出し、以降のフローで解決できるよう保持する
- **エンドユーザー**: 登録の場面には登場しない。登録されたクライアントが認可リクエストを投げた時点から、通常のフローの登場人物になる

## 通常フロー

1. クライアントが `POST /register` に `{"redirect_uris": ["https://app.example.com/cb"]}` を送る
2. OP はメタデータを検証し、既定値を適用する（`token_endpoint_auth_method: client_secret_basic`、`grant_types: ["authorization_code"]`、`response_types: ["code"]`）
3. OP は `client_id`（乱数）と `client_secret`（32 バイト乱数）を生成し、登録レコードをストアへ保存する
4. OP は 201 で発行値と登録済み全メタデータを返す
5. クライアントは受け取った `client_id` で `/authorize` から通常の Authorization Code Flow を実行する

このリポジトリでは、手順 2〜4 の判断部分（検証・既定値・レコードと応答の組み立て）が experimental の純関数、HTTP の受け口とストア保存が CLI 生成コード、`redirect_uris` の検査規則と乱数生成が core 公開 API という分担になる。

## 失敗フロー

- `redirect_uris` が無い、または `javascript:` スキームやフラグメント付きを含む → `400` + `invalid_redirect_uri`。登録は何も起きない
- `token_endpoint_auth_method: "private_key_jwt"` のような未対応値 → `400` + `invalid_client_metadata`。「未知フィールドは無視」と「理解するフィールドの不正値は拒否」は別の規則であることに注意（誤解しやすい点の節）
- initial access token を要求する構成でトークンが無い・違う → `401` + `WWW-Authenticate: Bearer`。ボディは検証されない
- 登録上限（既定 100 クライアント）超過 → 登録拒否（応答形式は仕様書の未解決事項 U1）

## セキュリティモデルと脅威対策

DCR の脅威モデルの中心は「未認証で書き込めるエンドポイント」であることに尽きる。

- **在庫を無限に増やされる**（DoS）: 総数上限とボディ長上限で、メモリ消費に天井を付ける。IP 単位の流量制御はリバースプロキシや PaaS の責務とし、OP 本体では持たない
- **不正な redirect_uri を登録される**: 登録時に静的クライアントと同一の検査（core の `validateRegisteredRedirectUris`）を通す。フローの実行時ではなく登録時に弾くことで、不正 URI のクライアントはそもそも存在できない
- **client_secret の漏洩**: シークレットは 201 応答の 1 回だけ返り、`Cache-Control: no-store` を付け、ログに出さない
- **initial access token の突破**: 定数時間比較で照合し、欠落と不一致を応答で区別しない
- **SSRF**: v1 は URL を参照しにいくメタデータ（`jwks_uri` など）を受理しないため、登録処理から外部へのリクエストは発生しない

逆に、DCR が**守らないもの**も明確にしておく。
オープン登録では「登録できたこと」に何の信頼も置けない。
登録されたクライアントは、正規の未知アプリかもしれないし、攻撃者のスクリプトかもしれない。
DCR の安全性は「登録されたクライアントができることが、静的登録クライアントと同じ検証（PKCE、redirect_uri 完全一致、client 認証）で制約されていること」に依存する。
本機能が `grant_types` を `authorization_code` と `refresh_token` に限定し、experimental grant の URN を登録させないのも、この制約面を狭く保つためである。

## リクエスト・レスポンス実例

登録（最小構成）:

```http
POST /register HTTP/1.1
Host: op.example.com
Content-Type: application/json

{
  "redirect_uris": ["https://app.example.com/cb"],
  "client_name": "My Test App"
}
```

成功応答:

```http
HTTP/1.1 201 Created
Content-Type: application/json
Cache-Control: no-store

{
  "client_id": "dcr-Xm3f...",
  "client_secret": "kJ9d...（43 文字）",
  "client_id_issued_at": 1790812800,
  "client_secret_expires_at": 0,
  "redirect_uris": ["https://app.example.com/cb"],
  "token_endpoint_auth_method": "client_secret_basic",
  "grant_types": ["authorization_code"],
  "response_types": ["code"],
  "client_name": "My Test App"
}
```

エラー応答（redirect_uri 不正）:

```http
HTTP/1.1 400 Bad Request
Content-Type: application/json

{
  "error": "invalid_redirect_uri",
  "error_description": "redirect_uris must not contain a fragment component"
}
```

`client_secret_expires_at: 0` は「無期限」を意味する仕様上の値である（RFC 7591 §3.2.1）。

## データ構造

experimental が組み立てる登録レコード（`DynamicallyRegisteredClient`）は、生成コードが既に持つ `RegisteredClient` 型（`ClientInfo & TokenClientInfo` の合成。`samples/hono-cloudflare/src/oidc-provider/config.ts`）へそのまま適合する。
core の型を拡張する必要がないのは、DCR で登録できるメタデータを「core が既に解釈できる軸」（`redirectUris` / `grantTypes` / `tokenEndpointAuthMethod` / `clientType` / `responseTypes`）に限定しているからである。
`clientName` と `clientIdIssuedAt` は core が解釈しない付加情報であり、生成コード側の型に足しても core の挙動に影響しない。

## 用語集

- **DCR**: Dynamic Client Registration。クライアント登録の実行時 API
- **クライアントメタデータ**: 登録時に送る JSON のフィールド群（RFC 7591 §2）
- **オープン登録**: 認可なしで登録を受け付ける運用（RFC 7591 §3.1 の SHOULD）
- **initial access token**: 登録リクエストの認可に使う Bearer トークン。発行方法は仕様の範囲外
- **registration_endpoint**: discovery で広告する登録エンドポイントの URL（OIDC Discovery 1.0 §3）
- **registration_access_token / registration_client_uri**: RFC 7592 の管理用資格情報と URL。本機能は返さない

## core機能・類似機能との違い

- **静的登録（現状の `defaultRegisteredClients`）との違い**: 静的登録は設定ファイルの編集と再起動を要し、動的登録は API 呼び出し 1 回で済む。登録後のクライアントに対する検証（PKCE、redirect_uri 照合、client 認証）は完全に同一で、`findClient` が静的 Map の次に動的ストアを引くだけの差である
- **PAR（実装済み experimental）との類似**: どちらも「未認証または軽量認証で機械可読 JSON を受けるエンドポイント」であり、ルートテンプレートの形が近い。違いは、PAR が認可リクエスト 1 回分の短命な保存であるのに対し、DCR はクライアントという長命なレコードを作ること
- **google-login（extension）との違い**: google-login はエンドユーザーのログイン手段の追加であり、クライアント管理には触れない

## Experimentalにする理由

受理メタデータの集合と認可モデル（オープン登録既定）が PoC 向けの意図的な最小構成であり、フィードバックで広げる前提だからである。
とくにメタデータを 1 つ広げるごとに検証面とセキュリティ面（URL 参照系なら SSRF）が増えるため、安定 API として固定するのは時期尚早と判断した。
in-memory 限定の永続化も、昇格時に `ClientRegistrationStore` 契約として再設計する対象である。

## 誤解しやすい点

- **「未知フィールドは無視」と「不正値は拒否」は別の規則**: `logo_uri`（理解しないフィールド）は黙って捨てるが、`token_endpoint_auth_method: "private_key_jwt"`（理解するフィールドの未対応値）は `invalid_client_metadata` で拒否する。前者は RFC 7591 §2 の MUST、後者は同 §3.2.2 のエラー定義と §2.1 の整合性 SHOULD に基づく
- **登録できたことは信頼ではない**: オープン登録の 201 は「メタデータが形式的に妥当」以上の意味を持たない。認可判断はすべて以降のフローの検証が担う
- **`client_secret_expires_at: 0` は「即時失効」ではない**: 0 は無期限の意味である
- **プロセス再起動で消える**: 動的登録クライアントは in-memory ストアにしか無いため、再起動後は再登録が要る。Conformance Suite の実行単位では問題にならないが、長期の検証では注意が要る
- **`registration_endpoint` が discovery に出るのは有効時のみ**: 未有効の OP に登録を試みるクライアントは、discovery に `registration_endpoint` が無いことで非対応を判定できる（広告と実装の整合）

## 実装後の利用方法

```bash
# 生成
maronn-oidc generate hono --enable dynamic-client-registration --output ./src/oidc-provider

# 登録
curl -X POST http://localhost:3000/register \
  -H 'Content-Type: application/json' \
  -d '{"redirect_uris": ["http://localhost:8080/cb"]}'

# 返ってきた client_id / client_secret でそのまま Authorization Code Flow を実行する
```

initial access token を要求したい場合は、生成された `dynamicClientRegistrationConfig` の `initialAccessToken` に値を設定し、登録リクエストへ `Authorization: Bearer <値>` を付ける。

## 一次資料の読み方ガイド

- RFC 7591 は §2（メタデータと既定値）→ §3（プロトコル）→ §5（セキュリティ）の順に読む。§2 の各フィールド定義にある「If omitted, the default is ...」が既定値適用の根拠で、§3.2.1 の「MUST return all registered metadata」が応答へ全メタデータを返す根拠である
- OpenID Connect Dynamic Client Registration 1.0 は §2 の冒頭（`redirect_uris` REQUIRED）と §3.2 の `registration_access_token` / `registration_client_uri` の「両方か、どちらも返さないか」の MUST だけ押さえれば、残りは RFC 7591 と同型である
- RFC 7592 は読まなくても本機能は理解できる。非目標の境界（更新・削除が無いこと）を確認したいときだけ参照する

## 昇格判断の観点

- 利用者が「登録の永続化」を要求し始めたか（in-memory で足りている間は experimental のままでよい）
- 受理メタデータを広げる要望が、どのフィールドに集中しているか（`jwks` 系なら SSRF 評価込みの再設計、表示系なら軽い）
- Conformance Suite の動的登録プランを実運用に組み込んだか（組み込んだ時点で DCR は Fidelity 軸の基盤になり、core 昇格の動機が立つ）
- RFC 7592 の要望が出たか（出た場合は登録レコードのライフサイクル管理ごと core で設計し直すのが自然）
