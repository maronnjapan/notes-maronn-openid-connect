# Current Implementation Documentation Backlog

現状の実装を読んだうえで、公式ドキュメントに追加・修正した方がよい内容の棚卸し。
対象は `packages/core`、`packages/cli`、`packages/sample`、既存の `packages/docs`。

## 結論

既存 docs はコンセプト説明としては有効だが、現在の実装が持っている重要な利用者向け情報をほとんど説明できていない。
特に `quick-start.md` には現実の API / CLI と一致しない記述があるため、まず修正が必要。

最優先で必要なのは以下。

- CLI 入口の正しい使い方と生成ファイルの責務
- `core` が提供する純関数 / helper と、利用者が実装する resolver / store の契約
- Authorization Code Flow の実装詳細: PKCE、redirect URI、prompt、offline_access、claims、issuer response parameter
- Token Endpoint の実装詳細: client authentication、authorization code、refresh token rotation、scope shrink、ID Token 再発行
- Signing key / JWKS / Discovery の運用: RS256 必須、複数鍵、用途別鍵、key rotation
- UserInfo / Introspection / Revocation の挙動と HTTP 配線
- Cloudflare Workers sample のセットアップ、KV/D1/secret 構成、デモ用途の制限
- 実装済み機能と未対応・制限事項の明示

## 既存ドキュメントの即時修正が必要な点

### Quick Start の CLI コマンドが実装と違う

`packages/docs/src/content/docs/quick-start.md` は次のように書いている。

```bash
pnpm dlx @maronn-openid-connect/cli init
```

実装されている CLI コマンドは `init` ではなく、以下。

```bash
maronn-oidc generate hono --output ./oidc-provider
maronn-oidc setup hono --output ./src/oidc-provider --entry ./src/index.ts
```

`setup` は entry file 内の placeholder を置換する実装。

- `// <!-- OIDC_IMPORT_PLACEHOLDER -->`
- `// <!-- OIDC_SETUP_PLACEHOLDER -->`

この placeholder 方式はドキュメント化すべき。

### Quick Start の manual setup が存在しない API を参照している

`quick-start.md` は `createOidcProvider` を `@maronn-openid-connect/core` から import する例を載せている。
現在 `packages/core/src/index.ts` に `createOidcProvider` は export されていない。

手動セットアップの説明は、現実の API に合わせて以下の方向に直す必要がある。

- `validateAuthorizationRequest`
- `createAuthTransaction`
- `completeAuthTransaction`
- `createAuthorizationCode`
- `authenticateClient`
- `validateTokenRequest`
- `generateTokenResponse`
- `handleUserInfoRequest`
- `buildProviderMetadata`
- `exportJwks`
- `handleIntrospectionRequest`
- `handleRevocationRequest`

ただし、利用者の主入口は CLI 生成コードなので、手動セットアップは「高度な組み込み用途」として別ページに分離した方がよい。

### ID Token ドキュメントの alg 説明が狭い

現在の docs は `alg` を `RS256` 固定のように説明している。
実装は RS256 を必須サポートとして要求しつつ、RS384 / RS512 / ES256 / ES384 / ES512 も扱える。

ドキュメントでは以下のように整理する。

- OP として少なくとも RS256 鍵を登録する必要がある
- クライアントの `idTokenSignedResponseAlg` に応じて ID Token 署名鍵を選択できる
- 未指定時は OIDC の既定として RS256
- Discovery の `id_token_signing_alg_values_supported` は実際の登録鍵から導出される

### Authorization Code Flow のレスポンス例に `iss` が不足している

実装は RFC 9207 の Authorization Response Issuer Parameter を成功・エラーの両方に付ける。
既存 docs の例は `code` と `state` のみ。

成功例は以下を含めるべき。

```text
https://client.example.com/callback?code=AUTH_CODE&state=STATE&iss=https%3A%2F%2Fprovider.example.com
```

Discovery でも `authorization_response_iss_parameter_supported: true` を広告している。

## 推奨する docs 構成

### Getting Started

- `Introduction`: コンセプト、対象ユーザー、Keycloak/Auth0 との位置づけ
- `Quick Start with CLI`: Hono 生成コードを動かす最短手順
- `Generated Code Overview`: 生成される 15 ファイルの責務
- `Cloudflare Workers Sample`: sample の KV/D1/secret セットアップ
- `Manual Core Integration`: `core` を直接組み込む高度な利用者向け

### Core Concepts

- Authorization Code Flow
- PKCE
- Client Authentication
- Redirect URI Validation
- Auth Transaction / Login / Consent
- Prompt Parameter
- Offline Access and Refresh Tokens
- ID Token
- Access Token Formats
- UserInfo
- Discovery and JWKS
- Token Introspection
- Token Revocation
- Claims Parameter
- Signing Keys and Rotation
- Resolver and Store Contracts
- Error Handling and Cache Headers

### Reference

- CLI Reference
- Core API Reference
- Generated Hono Route Reference
- Supported Specifications
- Current Limitations
- Conformance Traceability

## CLI ドキュメントに必要な内容

### コマンド体系

実装済みコマンドは以下。

```bash
maronn-oidc generate <framework> [--output <dir>]
maronn-oidc setup <framework> [--output <dir>] [--entry <file>]
```

現在サポートする framework は `hono` のみ。

`generate` は指定ディレクトリに OIDC Provider コードを生成する。
`setup` は生成に加えて entry file を patch する。

### 生成ファイル一覧

Hono generator は 15 ファイルを生成する。

- `app.ts`: 新しい Hono app として OIDC Provider を作る
- `apply.ts`: 既存 Hono app に OIDC routes / middleware を適用する
- `config.ts`: ProviderConfig、登録クライアント、in-memory resolver
- `store.ts`: in-memory stores
- `resolvers.ts`: core interface に合わせた resolver adapters
- `views.ts`: login / consent / error の HTML view
- `routes/authorize.ts`: Authorization Endpoint
- `routes/token.ts`: Token Endpoint
- `routes/userinfo.ts`: UserInfo Endpoint
- `routes/introspection.ts`: RFC 7662 Introspection Endpoint
- `routes/revocation.ts`: RFC 7009 Revocation Endpoint
- `routes/jwks.ts`: JWKS Endpoint
- `routes/discovery.ts`: OpenID Provider Metadata
- `routes/login.ts`: login UI / authentication handling
- `routes/consent.ts`: consent UI / authorization code issuance

### `createApp` と `applyOidc` の使い分け

`app.ts` の `createApp()` は OIDC Provider だけの Hono app を作る。
`apply.ts` の `applyOidc()` は既存 Hono app に route を追加する。

ドキュメントでは `applyOidc()` を主経路にするのがよい。
理由は以下。

- 既存アプリに組み込みやすい
- 用途別 signing key provider を指定できる
- CORS 設定を受け取れる
- `acrResolver` / `jwksProvider` など拡張点を注入できる

### CORS

`applyOidc()` は Hono の CORS middleware を設定する。

- `/token`
- `/userinfo`
- `/introspect`
- `/revoke`

上記 protected endpoints は `corsOrigins` option を使う。
未指定なら `'*'`。

Discovery / JWKS は公開 metadata なので常に `'*'`。

- `/.well-known/openid-configuration`
- `/.well-known/jwks.json`

ドキュメントでは、browser-based client から Token / UserInfo を呼ぶ場合は CORS 設定が必要であることを説明する。

### 生成コードで利用者が差し替えるべき箇所

ドキュメントに「ここを置き換える」と明示すべき。

- `config.ts`
  - `defaultProviderConfig` は local testing 用
  - issuer / token lifetime / access token format は runtime config から作る
  - `defaultRegisteredClients` は local testing 用
  - 実運用では DB / KV / env backed resolver に置き換える
- `store.ts`
  - in-memory store は local testing 用
  - serverless / multi-process 環境では永続 store に置き換える
- `resolvers.ts`
  - clients / auth codes / access tokens / refresh tokens / users の resolver を実装する
- `views.ts`
  - login / consent / error の UI をアプリに合わせて置き換える
- `routes/login.ts`
  - `authenticateUser` を実アプリの認証処理に置き換える
- `routes/authorize.ts`
  - `sessionResolver` / `consentResolver` を注入すると `prompt=none` が動く
  - `jwksProvider` を注入すると `id_token_hint` 検証が動く
- `routes/token.ts`
  - access token format、signing keys、refresh token 永続化を運用要件に合わせる

## `core` API ドキュメントに必要な内容

### Core の設計境界

`core` は HTTP framework を持たない。
主に以下を提供する。

- spec-sensitive な validation
- token / code / JWT / JWKS 生成
- endpoint 処理の純関数
- resolver / store の interface
- framework 依存のない Web Crypto API ベースの helper

HTTP request の parse、response header、cookie、session、DB/KV 永続化は呼び出し側または生成コードの責務。

### Web 標準 API 前提

実装は `crypto.subtle`、`crypto.getRandomValues`、`Request`、`URL`、`URLSearchParams`、`TextEncoder` / `TextDecoder`、`atob` / `btoa` を使う。
Node 固有 API に依存する core runtime ではなく、JavaScript runtime の Web 標準 API を前提にする。

`crypto-utils.ts` は `node:crypto` の型を import しているが、実行時の暗号処理は Web Crypto API。

## Authorization Endpoint ドキュメントに必要な内容

### GET / POST の両対応

生成 Hono route は `/authorize` で GET と POST をサポートする。
POST の場合は `application/x-www-form-urlencoded` のみ受け付ける。

### 重複パラメータ拒否

Authorization request parameter は重複不可。
生成コードは `URLSearchParams` を直接走査し、最初に見つかった重複 key を `invalid_request` にする。

この挙動は `Object.fromEntries()` や framework の body parser が最後の値で上書きしてしまう問題を避けるため。

### 必須パラメータ

現在の authorization validation が要求するもの。

- `client_id`
- `response_type=code`
- `scope` に `openid` を含む
- `code_challenge`
- `code_challenge_method=S256`

`redirect_uri` は登録 URI が 1 件なら省略可能。
複数登録時は必須。

### redirect_uri の検証

記載すべきルール。

- 登録済み URI と RFC 3986 simple string comparison で照合する
- request の `redirect_uri` に fragment がある場合は拒否する
- 登録済み `redirect_uri` に fragment がある場合は server error として設定ミスを検出する
- public client の loopback redirect URI だけ、port 差異を許可する
- confidential client または `clientType` 未指定では厳格一致
- `ClientResolver.findClient(clientId)` が別の `clientId` を返した場合は server error

### PKCE

Authorization Endpoint の `code_challenge` ルール。

- OAuth 2.1 として PKCE 必須
- `code_challenge_method` は `S256` のみ
- `plain` は拒否
- S256 `code_challenge` は 43 文字固定
- 文字種は base64url no-padding の `[A-Za-z0-9-_]`

Token Endpoint の `code_verifier` ルール。

- 必須
- 43〜128 文字
- 文字種は `[A-Za-z0-9\-._~]`
- SHA-256 + base64url で保存済み challenge と比較

### prompt

対応値。

- `none`
- `login`
- `consent`
- `select_account`

ドキュメントに必要な補足。

- `prompt=none` は他の値と併用不可
- 値はスペース区切り
- `prompt=none` は UI を出せないため、session と consent を resolver で確認する
- `prompt=none` で session が無ければ `login_required`
- `prompt=none` で consent が無ければ `consent_required`
- `prompt=login` は再認証を強制する
- CLI template では `prompt=select_account` を Phase 1 として `prompt=login` 相当に扱う

注意: `packages/cli` の template は `select_account` を max_age session reuse から除外し、login route でも既存 session を捨てる。
一方で `packages/sample/src/oidc-provider` の生成済みコードはこの変更をまだ反映していないように見える。
sample の説明では「generated code は CLI 由来であり、差分が出たら再生成が必要」と明記した方がよい。

### max_age

`requiresReauthentication(maxAge, authTime)` は `now - authTime > maxAge` で再認証要否を判定する。

ドキュメントに書くべきこと。

- `max_age=0` は常に再認証を要求する
- `prompt=none` では再認証 UI を出せないため、期限切れ session は `login_required`
- 通常フローでは fresh session があれば login を skip して consent に進む
- `prompt=login` と `prompt=select_account` は session reuse しない

### id_token_hint

実装済みの検証。

- compact JWS 形式であること
- JOSE header / payload が base64url JSON として parse 可能
- `alg` が存在し、`none` でないこと
- `kid` があれば kid で鍵候補を選ぶ
- `kid` がなければ `alg` が一致する鍵候補を順に試す
- JWK の `alg` と header `alg` が一致しない鍵は使わない
- signature を検証する
- `iss` が expected issuer と一致する
- `aud` が expected client_id と一致する
- `exp` が 60 秒 clock skew 許容内で有効
- `sub` が非空 string

`prompt=none` では `jwksProvider` が未設定だと `id_token_hint` を検証できないため `login_required`。
検証済み subject と active session subject が違う場合も `login_required`。

### offline_access

`validateAuthorizationRequest()` は `offline_access` を要求されたとき、デフォルトでは `prompt=consent` が無ければ granted scope から削除する。

ドキュメントに必要な内容。

- `offline_access` は error にせず無視される
- デフォルト許可条件は `prompt=consent`
- 独自条件は `isOfflineAccessGranted` callback で注入できる
- 生成コードの consent / prompt=none 成功 branch は、さらに client の `offlineAccessAllowed` を見る
- `offlineAccessAllowed` が false なら `offline_access` は削除される
- Token Endpoint は最終 granted scope に `offline_access` が含まれる場合だけ refresh token を発行する

### claims parameter

Authorization Request の `claims` は JSON string として受け取る。
現在の実装は以下。

- top-level の `userinfo` と `id_token` だけ認識する
- unknown top-level member は無視する
- claim entry は `null` または object のみ採用する
- string / number / array など不正形は silently dropped
- JSON parse 失敗または top-level が object でない場合は `invalid_request`

利用者向けには「現時点では values / essential の厳密 enforcement ではなく、要求の伝搬と一部利用に留まる」と明示する。

実装済みの利用。

- `claims.userinfo` は UserInfo で追加 claim の要求として扱われる
- `claims.id_token.acr.values` は `acrResolver` の `requestedAcrValues` に反映される
- authorization code に claims を保存し、token endpoint へ伝搬する

### audience / resource indicator 相当

Authorization Request に `audience` パラメータがあり、スペース区切りで配列化される。
これは RFC 8707 の `resource` パラメータ名そのものではなく、この実装の audience 入力であることを明示する。

CLI template では access token audience を以下で合成する。

- UserInfo endpoint を恒久 member として含める
- request audience を後ろに追加する
- 重複除去
- 空なら issuer

`packages/sample/src/oidc-provider/routes/token.ts` は現時点で template の `buildAccessTokenAudience()` 呼び出しを反映していないように見えるため、sample の再生成または差分説明が必要。

## Auth Transaction / Login / Consent ドキュメントに必要な内容

### Auth Transaction の役割

Authorization Request から login / consent / code issuance までの間、server-side store に request context を保存する。
URL には transaction ID だけを載せ、request context は store から復元する。

保存される主な値。

- `clientId`
- `redirectUri`
- `redirectUriExplicit`
- `responseType`
- `scope`
- `state`
- `nonce`
- `codeChallenge`
- `codeChallengeMethod`
- `prompt`
- `maxAge`
- `acrValues`
- `loginHint`
- `idTokenHint`
- `audience`
- `claims`
- `csrfToken`
- `createdAt`
- `expiresAt`
- `failedAttempts`

デフォルト TTL は 10 分。

### CSRF と login failure

生成 view は hidden input として `transaction_id` と `csrf_token` を持つ。
`validateCsrfToken()` は token 欠損または不一致で 403 相当の `invalid_csrf_token`。

`handleLoginFailure()` は失敗回数を増やし、デフォルト 5 回で transaction を削除する。
最大試行到達時は 429 相当。

### completeAuthTransaction の重要な順序

`completeAuthTransaction()` は authorization code を発行する前に transaction を削除する。
これは transaction の one-time 性を守るため。

この順序は generated code を改造する利用者向けに明示した方がよい。

### Login session と Auth Transaction は分離されている

生成コードは login 成功後の subject / authTime を `AuthSessionStore` に保存する。
`AuthTransaction` そのものには subject / authTime を持たせない。

この分離をドキュメント化しないと、利用者が transaction に認証済み user context を混ぜてしまいやすい。

## Token Endpoint ドキュメントに必要な内容

### Content-Type と body parse

Token route は raw body を `URLSearchParams` で parse し、重複パラメータを拒否する。
現在の token route は `Content-Type` 自体の厳密チェックはまだドキュメント上で注意が必要。
`tasks/p1-token-endpoint-content-type.md` が未完了として存在する。

### grant_type

現在受け付ける grant type。

- `authorization_code`
- `refresh_token`

それ以外は `unsupported_grant_type`。
OAuth 2.1 で removed / 非推奨の grant（implicit、password、client_credentials など）はこの OP の主要フロー外として拒否される。

### client authentication

対応方式。

- `client_secret_basic`
- `client_secret_post`

ルール。

- 1 request で複数方式を同時に使うと `invalid_request`
- Basic auth scheme は case-insensitive
- Basic credentials は `client_id:client_secret` を base64 し、その後 form-url-decode する
- `+` は space として扱う
- secret 比較は Web Crypto HMAC ベースの timing-safe comparison
- `invalid_client` は 401
- 401 では `WWW-Authenticate: Basic realm="Client Authentication"` を返す

Public client の Token Endpoint 対応はまだ未実装領域として `tasks/p1-public-client-token-endpoint.md` が残っている。

### authorization_code grant

検証内容。

- `grant_type=authorization_code`
- client authentication 済み
- `code` 必須
- authorization code が存在する
- code は未使用
- code の `clientId` と authenticated client が一致する
- code は期限内
- authorization request に `redirect_uri` が明示されていた場合、token request でも必須かつ一致
- authorization request で省略されていた場合、token request 側も省略可能。ただし送られたら一致を要求
- PKCE `code_verifier` を検証
- 成功時に authorization code を used にする

Code reuse を検知した場合、`revokeTokensByGrantId` が実装されていれば同じ grant の access token / refresh token をまとめて失効する。

### refresh_token grant

実装済みの挙動。

- `grant_type=refresh_token`
- `refresh_token` 必須
- `RefreshTokenResolver` 必須
- token が存在する
- 未使用
- client が一致する
- 期限内
- requested scope は元の scope の subset のみ許可
- 空 scope 指定は `invalid_scope`
- scope 重複は除去
- 元 scope を超える要求は `invalid_scope`
- audience は元 token から引き継ぐ
- `authTime` / `nonce` / `acr` / `amr` / `azp` は元 token から引き継ぐ

Refresh token reuse を検知した場合、`revokeTokensByGrantId` が実装されていれば同じ grant の access token / refresh token をまとめて失効する。

### Refresh Token Rotation の保存順序

重要な運用ルールとして明記する。

1. 新しい access token / refresh token を生成する
2. 新しい token metadata を store に保存する
3. 保存成功後に古い refresh token を revoke / consume する

先に古い refresh token を失効すると、保存失敗時にユーザーが再ログイン必須になる。
core の `validateTokenRequest()` は旧 refresh token を即 revoke しない。
これは呼び出し側が正しい順序で処理するため。

### Token response

実装は token response に常に `scope` を含める。
OAuth 上は要求 scope と同一なら optional だが、conformance 互換のため常に含める。

`Cache-Control: no-store` と `Pragma: no-cache` を成功・エラー双方で返す。

## Token Generation / Claims ドキュメントに必要な内容

### Access Token

JWT access token の header。

- `alg`: signing key から導出
- `typ: at+jwt`
- `kid`: 指定時

JWT access token payload。

- `iss`
- `sub`
- `aud`
- `exp`
- `iat`
- `scope`
- `client_id`

`aud` は非空配列必須。
空なら issuer fallback、CLI template では UserInfo endpoint を必ず含める。

Opaque access token も対応している。

- `accessTokenFormat: 'jwt' | 'opaque'`
- opaque は CSPRNG 文字列
- token payload は token 自体に含まれない
- store / introspection で検証する前提
- immediate revocation が必要なケースに向く

### ID Token

ID Token header。

- `alg`: signing key から導出
- `typ: JWT`
- `kid`: 指定時

Payload required claims。

- `iss`
- `sub`
- `aud`
- `exp`
- `iat`

実装上の validation。

- issuer は URL
- localhost / 127.0.0.1 以外は https 必須
- issuer に query / fragment 不可
- `sub` は必須で 255 文字以下
- `aud` は必須で、array の場合は空配列不可
- `exp` は 60 秒 clock skew まで過去を許容
- `iat` は必須
- `aud` が複数なら `azp` 必須
- `azp` は audience のいずれかであること

Token response で生成される ID Token には以下も入り得る。

- `nonce`
- `auth_time`
- `at_hash`
- `acr`
- `amr`
- scope に応じた user claims

`at_hash` は ID Token 署名 alg に対応する hash を使う。
RS256 / ES256 は SHA-256、RS384 / ES384 は SHA-384、RS512 / ES512 は SHA-512。

### User claims の scope filter

`filterClaimsByScope()` の対応。

- `profile`
  - `name`
  - `family_name`
  - `given_name`
  - `middle_name`
  - `nickname`
  - `preferred_username`
  - `profile`
  - `picture`
  - `website`
  - `gender`
  - `birthdate`
  - `zoneinfo`
  - `locale`
  - `updated_at`
- `email`
  - `email`
  - `email_verified`
- `address`
  - `address`
- `phone`
  - `phone_number`
  - `phone_number_verified`

ID Token に user claims を入れる場合も scope で filter される。
必須 claims は user claims によって上書きされない。

Refresh grant で scope が縮小された場合、ID Token claims も縮小後 scope に合わせる。

### acr / amr

core は認証ポリシーを知らないため、`acrResolver` で外部注入する。

`AcrResolver` の入力。

- `userId`
- `clientId`
- `requestedAcrValues`

戻り値。

- `{ acr: string; amr: string[] }`
- または `undefined`

優先順位。

1. caller supplied `acr` / `amr`
2. `acrResolver`
3. omit

Refresh grant では初回認証時の `acr` / `amr` を保存値から直接渡し、resolver は呼ばない。

## UserInfo ドキュメントに必要な内容

### Access token extraction

生成 route は以下をサポート。

- `Authorization: Bearer <token>`
- POST body の `access_token` form parameter

ルール。

- Bearer scheme は case-insensitive
- 複数方式を同時に使うと `invalid_request`
- query parameter の access token はサポートしない
- GET / POST の両方を route として持つ

### UserInfo validation

core の `handleUserInfoRequest()`。

- access token 必須
- resolver で token metadata を取得
- token 期限切れは `invalid_token`
- `openid` scope が無い場合は `insufficient_scope`
- user claims が見つからない場合は `invalid_token`
- scope に応じて claim filter
- `claims.userinfo` があれば追加 claim を返す

### Signed UserInfo

client metadata 相当の `userinfoSignedResponseAlg` が `RS256` の場合、UserInfo response を signed JWT として返す。

- Content-Type は `application/jwt`
- payload には UserInfo claims に加えて `iss` / `aud` / `iat` / `exp`
- デフォルト有効期限は 3600 秒
- `userinfo_signing_alg_values_supported` は Discovery に広告される

現在の generated config の型は `userinfoSignedResponseAlg?: 'RS256'` のみ。
将来 ES 系に広げる場合は docs も更新する。

### Cache headers

UserInfo は PII を含むため成功・エラーとも `Cache-Control: no-store`、`Pragma: no-cache`。

## Discovery / JWKS ドキュメントに必要な内容

### Discovery metadata

生成 route が返す主要 metadata。

- `issuer`
- `authorization_endpoint`
- `token_endpoint`
- `jwks_uri`
- `response_types_supported: ['code']`
- `subject_types_supported: ['public']`
- `id_token_signing_alg_values_supported`
- `userinfo_endpoint`
- `scopes_supported`
- `claims_supported`
- `grant_types_supported: ['authorization_code', 'refresh_token']`
- `token_endpoint_auth_methods_supported`
- `userinfo_signing_alg_values_supported`
- `authorization_response_iss_parameter_supported: true`
- `introspection_endpoint`
- `introspection_endpoint_auth_methods_supported`
- `revocation_endpoint`
- `revocation_endpoint_auth_methods_supported`
- `code_challenge_methods_supported: ['S256']`

`id_token_signing_alg_values_supported` は手書き配列ではなく、実際の signing key から導出される。
RS256 key が 1 つも無い場合は `buildProviderMetadata()` が error。

現時点の generated Discovery route は explicit な `Cache-Control` / `ETag` を設定していない。
`tasks/p2-discovery-cache-control-header.md` が残っているため、公開 docs では「現在の挙動」と「今後の予定」を分ける。

### Issuer validation

Discovery と ID Token で issuer validation がある。

- valid URL
- localhost / 127.0.0.1 以外は https
- query 不可
- fragment 不可

`http://localhost` は local development 用に許可される。

### JWKS

JWKS route は用途別 key set を flatten して公開する。

- primary signing keys
- ID Token signing keys
- UserInfo signing keys

挙動。

- rotated-out keys を token 有効期間中に公開できる
- alternate-alg keys も公開できる
- `kid` がある鍵は `kid` で重複排除
- `kid` がない鍵は最後に投入された 1 件だけ採用
- JWK から alg params を動的に解決する
- private key material は公開しない
- `Cache-Control: public, max-age=3600`

### SigningKeyProvider

重要な契約。

- `getSigningKey()` は新規署名に使う active key
- `getSigningKeys()` は JWKS / Discovery に広告する全 registered keys
- key array order は oldest -> newest
- `selectSigningKeyByAlg()` は同じ alg の複数 key から最後のものを選ぶ
- `getSigningKeys()` 未実装 provider は `[getSigningKey()]` に fallback
- `createCachedSigningKeyProvider()` は TTL cache を提供する

ドキュメントには key rotation の推奨運用を入れる。

1. 新しい key を key ring の末尾に追加する
2. `getSigningKey()` が新 key を返すようにする
3. `getSigningKeys()` は旧 key と新 key を返し続ける
4. 旧 key で署名された token が全て expire してから旧 key を JWKS から外す

## Introspection ドキュメントに必要な内容

RFC 7662 endpoint として `/introspect` を生成する。

実装方針。

- confidential client authentication 必須
- token owner と caller client の一致は要求しない
- protected resource が他 client 発行 token を introspect するユースケースを許可する
- `token` parameter 必須
- `token_type_hint=refresh_token` なら refresh -> access の順で検索
- それ以外は access -> refresh
- unknown / expired / used token は `{ "active": false }`
- inactive response は最小限で `active` のみ
- active access token は `scope` / `client_id` / `token_type` / `sub` / `exp` / optional `iat` / `aud` / `iss` / `jti`
- active refresh token は `scope` / `client_id` / `token_type: refresh_token` / `sub` / `exp` / optional `iat` / `iss`
- response は no-store / no-cache

`invalid_client` は 401 + Basic challenge。

## Revocation ドキュメントに必要な内容

RFC 7009 endpoint として `/revoke` を生成する。

実装方針。

- confidential client authentication 必須
- `token` parameter 必須
- token が見つからない場合も 200 OK empty body
- requesting client 以外に発行された token は `invalid_grant`
- `token_type_hint=refresh_token` なら refresh -> access の順
- それ以外は access -> refresh の順
- refresh token revoke 時は同じ `grantId` の access token も revoke する
- access token revoke 時は related refresh token は revoke しない
- success は 200 empty body
- response は no-store / no-cache

## Resolver / Store 契約ドキュメントに必要な内容

### ClientResolver

`findClient(clientId)` は同じ clientId の情報を返す必要がある。
異なる clientId を返すと server error。

Authorization 側に必要な情報。

- `clientId`
- `redirectUris`
- `clientType`

Token 側に必要な情報。

- `clientId`
- `clientSecret`

生成 config の `RegisteredClient` は両方を満たす。

### AuthorizationCodeResolver

必要メソッド。

- `findAuthorizationCode(code)`
- `revokeAuthorizationCode(code)`
- optional `revokeTokensByGrantId(grantId)`

`revokeAuthorizationCode` は実装上「削除」ではなく「used にする」方が code reuse detection に向いている。
sample の KV store も consume 後に短い TTL で used code を残す。

### RefreshTokenResolver

必要メソッド。

- `resolve(token)`
- `revokeRefreshToken(token)`
- optional `revokeTokensByGrantId(grantId)`

`revokeRefreshToken` は rotation 時に used mark する。
token reuse detection のため、即削除だけにすると再利用検知できない可能性がある。

### AccessTokenResolver / UserClaimsResolver

UserInfo / Introspection / Revocation で使う。

`AccessTokenInfo` は optional metadata を含む。

- `grantId`
- `iat`
- `audience`
- `issuer`
- `jti`

Introspection で返す必要があるなら store に保存する。

### Grant index

grantId は以下をつなぐ重要なキー。

- authorization code
- access tokens
- refresh tokens

使い道。

- authorization code reuse detection 時の sibling token revocation
- refresh token reuse detection 時の sibling token revocation
- refresh token revocation 時の access token cascade revocation

Cloudflare KV sample は `grant:{grantId}:at` / `grant:{grantId}:rt` の secondary index を持つ。

## Cloudflare Workers sample ドキュメントに必要な内容

### Sample の目的

`packages/sample` は利用者が直接変更して使う本番 starter ではなく、内部動作確認と Cloudflare Workers 実装例。
`packages/sample/src/oidc-provider` は CLI 生成物なので、修正が必要な場合は `packages/cli` を修正し再生成する方針。

### Binding 構成

必要 bindings。

- `OIDC_KV`: OP server-side state
- `CLIENT_KV`: demo client state
- `DB`: D1 database
- `ISSUER`: issuer URL
- `KEY_ID`: fallback kid
- `ACCESS_TOKEN_FORMAT`: optional `jwt` / `opaque`
- `PRIVATE_JWK`: secret
- `CLIENT_ID`: demo client id
- `CLIENT_SECRET`: demo client secret

### wrangler setup 手順

`wrangler.toml` のコメントにある手順を docs 化する。

1. `pnpm install`
2. KV namespace 作成
3. D1 database 作成
4. migration 適用
5. signing key 生成
6. `wrangler secret put PRIVATE_JWK`
7. local dev
8. deploy

### D1 schema

`clients` table。

- `client_id`
- `client_secret`
- `redirect_uris` JSON array
- `client_type`
- `offline_access_allowed`

`users` table。

- `subject`
- `username`
- `password`
- `name`
- `given_name`
- `family_name`
- `email`
- `email_verified`
- `phone_number`

重要: sample の password は plaintext demo only。
本番では Argon2 / bcrypt / scrypt などを利用することを明記する。

### KV store の security note

Access token / refresh token は raw token を key にせず、SHA-256 digest を base64url 化して storage key にする。
これは KV key から token 値が直接露出しないようにするため。

### Signing key providers

sample には以下がある。

- `EnvSigningKeyProvider`
- `KVSigningKeyProvider`
- `D1SigningKeyProvider`

docs に使い分けを書く。

- env secret: simple / Cloudflare secret rotation
- KV: key management を KV に寄せたい場合
- D1: admin workflow / audit / scheduled rotation と合わせたい場合

### Demo client の制限

`packages/sample/src/client/app.ts` の demo client は ID Token payload を decode しているだけで signature verification はしていない。
コメントにも production では JWKS で署名検証すべきとある。

docs では demo であることを明確にし、RP 実装の本番ガイドとは分ける。

## Error Handling / HTTP Headers ドキュメントに必要な内容

### error_description sanitization

`sanitizeErrorDescription()` により OAuth error response に入れる `error_description` は RFC 6749 Section 5.2 の安全な文字集合に制限される。
Authorization redirect、JSON body、WWW-Authenticate header へ user-controlled value が混ざるため。

### Token Endpoint

成功・エラーとも以下。

- `Cache-Control: no-store`
- `Pragma: no-cache`

`invalid_client` では `WWW-Authenticate`。

### UserInfo

成功・エラーとも no-store / no-cache。
Bearer error は `WWW-Authenticate` に入る。

### Introspection / Revocation

no-store / no-cache。
`invalid_client` は Basic challenge。

### Authorization Endpoint

redirectable error は `redirect_uri` に `error` / `error_description` / `state` / `iss` を付ける。
redirect できない段階の error は JSON 400。

## Security / Operational ドキュメントに必要な内容

### Localhost exception

Issuer は原則 https。
ただし local development のため `localhost` / `127.0.0.1` は http を許可する。

### Production dependency policy

`@maronn-openid-connect/core` と `@maronn-openid-connect/cli` は production dependencies なし。
sample は Hono / Cloudflare Workers を使う実装例。

### External libraries policy

このプロジェクトの方針として production dependencies に外部ライブラリを増やさないことを docs の contributor / architecture に書くとよい。

### Secret handling

client secret は timing-safe comparison。
sample D1 の `client_secret` は plaintext だが、これは PoC / sample 用。
本番導入を見据える開発者には secret hashing / encrypted storage の検討を案内する。

### Token lifetime

default。

- access token: 3600 秒
- ID token: 3600 秒
- refresh token: 2592000 秒
- authorization code: 300 秒
- auth transaction: 600 秒
- auth session handoff: 600 秒

これらは config / helper option / store TTL で調整可能。
未完了 task として auth code TTL configurable などが残るため、どこまで runtime config 化済みかは明示する。

## Current Limitations として明示すべき内容

現在の実装から見える制限。

- CLI framework は Hono のみ
- Token Endpoint の public client 対応は未完了 task がある
- `claims` parameter の `essential` / `value` / `values` enforcement は限定的
- `request` / `request_uri` / PAR / JAR / JARM は未実装
- DPoP は未実装
- mTLS / private_key_jwt client authentication は未実装
- Dynamic Client Registration は未実装
- Backchannel / RP-Initiated Logout など logout 系 extension は未実装
- Pairwise subject identifier は未実装
- encrypted ID Token / UserInfo JWE は未実装
- sample client は ID Token 署名検証を省略している
- generated in-memory stores は local testing 用で、multi-process / serverless 本番には不向き
- sample の `src/oidc-provider` が CLI template と一部差分を持っているように見えるため、docs か保守手順で再生成方針を明示する

## 実装と docs の対応表

| ドキュメント候補 | 主な実装ファイル |
|---|---|
| CLI Reference | `packages/cli/src/index.ts`, `packages/cli/src/generator.ts` |
| Hono Generated Files | `packages/cli/src/frameworks/hono/index.ts`, `packages/cli/src/frameworks/hono/templates.ts` |
| Authorization Endpoint | `packages/core/src/authorization-request.ts`, `packages/core/src/auth-transaction.ts`, `routes/authorize.ts` |
| Token Endpoint | `packages/core/src/token-request.ts`, `packages/core/src/token-response.ts`, `routes/token.ts` |
| Client Authentication | `packages/core/src/client-auth.ts` |
| ID Token | `packages/core/src/id-token.ts`, `packages/core/src/token-response.ts` |
| Access Token | `packages/core/src/access-token.ts`, `packages/core/src/access-token-issuer.ts` |
| PKCE | `packages/core/src/authorization-request.ts`, `packages/core/src/token-request.ts`, `packages/sample/src/client/pkce.ts` |
| UserInfo | `packages/core/src/userinfo.ts`, `routes/userinfo.ts` |
| Discovery | `packages/core/src/discovery.ts`, `routes/discovery.ts` |
| JWKS / signing keys | `packages/core/src/jwks.ts`, `packages/core/src/signing-key.ts`, `routes/jwks.ts`, `sample/src/op/key-provider.ts` |
| Introspection | `packages/core/src/introspection.ts`, `routes/introspection.ts` |
| Revocation | `packages/core/src/revocation.ts`, `routes/revocation.ts` |
| Resolver / Store Contracts | `packages/core/src/*.ts`, `packages/sample/src/oidc-provider/resolvers.ts`, `packages/sample/src/op/kv-store.ts` |
| Cloudflare Sample | `packages/sample/src/op/*`, `packages/sample/wrangler.toml`, `packages/sample/migrations/0001_init.sql` |

## ドキュメント作成時の優先順位

### P0

- Quick Start の誤り修正
- CLI generate / setup の正しい説明
- Generated Hono Provider の使い方
- Resolver / Store 契約
- Authorization Code + PKCE + Token Endpoint の実装詳細
- Signing key provider / JWKS / Discovery
- Current Limitations

### P1

- prompt / max_age / id_token_hint / offline_access
- refresh token rotation と reuse detection
- UserInfo / signed UserInfo
- Introspection / Revocation
- Cloudflare Workers sample setup
- Error handling / headers

### P2

- acr / amr resolver
- claims parameter
- opaque access token
- key rotation operations
- conformance traceability
- extension roadmap

## 最終的な docs 化の注意

このファイルは「載せるべき内容の棚卸し」であり、そのまま公開 docs に貼るものではない。
公開 docs では以下の分割を推奨する。

- 利用者が最短で動かす手順
- 生成コードを改造するための guide
- core を直接使う API reference
- 仕様準拠挙動の reference
- sample / Cloudflare 固有の guide
- 制限事項と roadmap

特に PoC 開発者向けの製品コンセプト上、単なる概念説明よりも「どのファイルを、なぜ、どう差し替えるか」を前面に出す方が有用。
