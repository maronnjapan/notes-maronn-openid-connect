# Experimental機能仕様書: OAuth 2.0 Dynamic Client Registration（RFC 7591）

- **機能名**: Dynamic Client Registration（動的クライアント登録エンドポイント）
- **feature-id**: `dynamic-client-registration`
- **準拠仕様**: RFC 7591（OAuth 2.0 Dynamic Client Registration Protocol）、OpenID Connect Dynamic Client Registration 1.0（incorporating errata set 2）のサブセット
- **作成日**: 2026-09-30
- **ステータス**: `state.yaml` を参照

## 概要

生成 OP に**クライアント登録エンドポイント**（`POST /register`）を追加し、クライアントが実行時に JSON メタデータを送って `client_id` と `client_secret` の払い出しを受けられるようにする。
登録されたクライアントは、静的登録クライアントと同じクライアント解決の経路に載り、そのまま Authorization Code Flow を実行できる。
discovery には `registration_endpoint` を有効時のみ追記する。

追加されるのは次の 3 面で、いずれも実装済み experimental 機能で実証済みのパターンに載る:

1. **新規エンドポイント**: `POST /register`。PAR の `POST /par` が同型の「機械可読 JSON を受ける未認証（または軽量認証）エンドポイント」を実証済み
2. **discovery への追記**: `registration_endpoint`。PAR / Device / CIBA / JARM / ID-JAG / jwt-introspection-response / rp-initiated-logout が実証済みのスプレッドマージ 1 箇所（`packages/cli/src/frameworks/hono/templates.ts` の 7601 行周辺）
3. **生成コード側の専用ストアと resolver 合成**: 動的登録クライアントの in-memory ストアを生成コードに置き、既存の `createInMemoryClientResolver`（静的 Map）と合成した `findClient` を提供する。Token Exchange の `tokenExchangeConfig.allowedTargets` が「experimental 機能専用の設定・状態を生成コードに置く」パターンを、Device / CIBA が「experimental 機能専用ストアを生成コードに置く」パターンを実証済み

メタデータの検証と登録レコードの構築は experimental の純関数群に置き、HTTP の受け口とストアへの書き込みは生成コードの責務とする。
`redirect_uris` の妥当性検査は core 公開の `validateRegisteredRedirectUris`（`packages/core/src/index.ts:12` でエクスポート済み）をそのまま使い、静的クライアントと同じ登録基準を適用する。

## 採用理由（候補評価）

rp-initiated-logout サイクル（2026-09-09 作成、2026-09-23 承認）までの候補評価で見送られてきた候補の状況は変わっていない。
RAR（RFC 9396）は認可リクエスト受理からトークン応答と introspection までを横断し、core の型拡張（`AuthTransaction` / `AuthorizationCodeData` / `AccessTokenInfo` など）なしに隔離できない評価（`study-material/ext-rich-authorization-requests-rfc9396.md` の「導入難易度 中〜高」）が変わらない。
DPoP は `tasks/T-019-dpop.md` が core 変更前提の別タスクとして存在する。
Back-Channel Logout 1.0 は rp-initiated-logout の非目標として保留中であり、RP への配送（アウトバウンド HTTP）とセッションからクライアントへの追跡という新しい面を 2 つ同時に開く。
今回は、クライアント登録が静的設定の編集でしかできないという運用面の空白（`study-material/ext-dynamic-client-registration.md` が Conformance Suite 連携と PoC 体験の両面で評価済み）を埋められ、既存エンドポイントの挙動を一切変えない Dynamic Client Registration を選定した。

| 観点 | 評価 |
|---|---|
| プロジェクト関連性 | Fidelity 軸に直結する。OIDF Conformance Suite の多くのテストプランはクライアントの動的登録を前提に組まれており、DCR が無い現状は静的クライアント設定のプランに限定される（`study-material/extension-dynamic-client-registration.md` で確認済み）。また MCP（Model Context Protocol）の authorization 仕様が DCR による接続を推奨しており、「最新仕様を検証できる OP」の入口として需要が再拡大している（`study-material/ext-mcp-authorization-op-readiness.md`） |
| Experimental隔離の妥当性 | 新規エンドポイントの追加のみで、既存エンドポイントの挙動を一切変えない。機能無効時は `/register` が存在せず（404）、discovery にも `registration_endpoint` が出ない。rp-initiated-logout と同じ最も強い隔離になる |
| core無変更 | 可能。`redirect_uris` の検査は core 公開の `validateRegisteredRedirectUris` を、乱数生成は core 公開の `generateRandomString`（`index.ts:157`）を使う。登録レコードは生成コードの `RegisteredClient` 型（`ClientInfo & TokenClientInfo`。core の型をそのまま合成した生成コード側の型）に適合する値を experimental が組み立てるだけで、core の型拡張は不要。クライアント解決は resolver 抽象（`ClientResolver.findClient`）の生成コード側実装を合成するだけでよい |
| CLI `--enable` 提供 | 可能。`EXPERIMENTAL_FEATURES` の末尾（現在の末尾は `'rp-initiated-logout'`、`features.ts:85`）に `'dynamic-client-registration'` を追加する。他機能への依存はない（クライアント解決の基盤は常に生成される） |
| 一次資料の成熟度 | RFC 7591 は 2015 年の Proposed Standard、OIDC Dynamic Client Registration 1.0 は Final（errata set 2）。どちらも 10 年の実装実績があり、主要 IDaaS と Conformance Suite が広く実装済み |
| セキュリティ影響 | 新規に増える面は「未認証で叩ける登録エンドポイント」の 1 つ。RFC 7591 §5 が名指しする DoS（無制限登録）とリダイレクト URI の不正登録が主脅威で、前者は登録上限とボディ長制限、後者は静的クライアントと同一の `validateRegisteredRedirectUris` 適用で塞ぐ（セキュリティ要件の節）。URL 参照系メタデータ（`jwks_uri` / `logo_uri` など）を v1 で受理しないため、SSRF の面はそもそも開かない |
| テスト可能性 | HTTP レベルで完結する。検証マトリクス（必須欠落・不正値・未知フィールド無視）は experimental の単体テストで、「登録した client でフローが成立する」ことは conformance.test.ts と E2E で固定できる。外部サービス依存はない |
| 実装規模 | 小〜中（PAR と同程度）。experimental 新規モジュール 1 + 新規ルートテンプレート 1 + 専用ストア + resolver 合成 + discovery 追記 + conformance。ユーザー向け画面はない |
| 将来の昇格 | `study-material/ext-dynamic-client-registration.md` の方針 A（core に「メタデータ検証と発行値算出」の純関数を置き、永続化を `ClientRegistrationStore` 注入にする）がそのまま昇格先の形になる。experimental の各関数は純関数として設計するため移植は機械的 |
| 既存機能との重複 | なし。実装済み 8 機能はいずれもトークン発行系またはセッション終了系で、クライアント管理系は初。`tasks/*.md` の既存タスクにもクライアント登録エンドポイントを作るものはない |
| 利用者の検証価値 | 「DCR で登録した client がそのままログインまで通るか」「`token_endpoint_auth_method` の既定（client_secret_basic）がどう効くか」「不正な redirect_uri の登録がどのエラーで弾かれるか」を手元で検証できる。Conformance Suite の動的登録プランや MCP クライアントの接続検証をこの OP で試す入口になる |

## Experimentalにする理由

- 受理するメタデータの集合（v1 は 5 フィールド）は意図的に最小であり、利用者のフィードバックで広げる前提。広げるたびに検証面が増えるため、API が安定と言える状態にない
- 登録の認可モデル（オープン登録を既定とし、任意で initial access token を要求する）は PoC 用途に合わせた選択であり、本番運用の要件（審査付き登録、RFC 7592 の管理）とはギャップがある
- 動的登録クライアントの永続化は in-memory ストアのみで、プロセス再起動で消える。永続化契約の形（`ClientRegistrationStore` として core に置くか）は昇格時の再設計対象

## 非目標（Non-goals）

- **RFC 7592（Dynamic Client Registration Management）**: 登録後の参照・更新・削除は対象外。OIDC Dynamic Client Registration 1.0 §3.2 は「`registration_access_token` と `registration_client_uri` は両方返すか両方返さないかのどちらかでなければならない（MUST）」と定めるため、本機能はどちらも返さない
- **`software_statement`（RFC 7591 §2.3）**: 受理しない。未知フィールドとして無視する（`invalid_software_statement` エラーを返す経路は作らない）
- **initial access token の発行・管理**: 要求側の検証のみ提供する。トークンの発行 API や複数トークンの管理は作らず、生成コードの設定に置いた固定文字列 1 つと照合する
- **OIDC 固有メタデータの解釈**: `application_type` / `sector_identifier_uri` / `subject_type` / `jwks` / `jwks_uri` / `id_token_signed_response_alg` / `default_max_age` / `logo_uri` などは受理せず、未知フィールドとして無視する（RFC 7591 §2 の MUST ignore に適合。バリデーションの節）。とくに URL 参照系（`jwks_uri` / `sector_identifier_uri` / `logo_uri`）は取得処理が SSRF の面を開くため、受理する場合は昇格時に個別のセキュリティレビューを要する
- **`registration_endpoint` の認可ポリシーの多様化**: Bearer 以外の認証方式（mTLS、private_key_jwt での登録認証）は対象外
- **動的登録クライアントへの experimental grant の許可**: `grant_types` に登録できるのは `authorization_code` と `refresh_token` のみ。token-exchange / CIBA / device などの URN は `invalid_client_metadata` で拒否し、experimental 機能間の結合を作らない
- **レート制限**: RFC 7591 §5 の rate-limit は MAY であり、IP 単位などの流量制御はデプロイ環境（リバースプロキシや PaaS）の責務とする。本機能は総数上限（`maxRegisteredClients`）とボディ長制限のみ持つ

## ユースケース / 想定利用者

- OIDF Conformance Suite の動的登録前提プランをこの OP に向けて実行したい検証担当者
- MCP サーバーなど「接続時に DCR でクライアント登録する」エコシステムのクライアント実装を、手元の OP で受け止めて検証したい開発者
- 複数のテストアプリを素早く繋ぎたい PoC 開発者（静的設定の編集とデプロイなしにクライアントを増やす）
- `token_endpoint_auth_method` や `grant_types` の既定値がどう適用されるかなど、RFC 7591 の素の挙動を確認したい開発者

## 関連標準仕様

- RFC 7591 §2（クライアントメタデータと既定値）、§3.1（登録リクエスト）、§3.2.1（成功応答）、§3.2.2（エラー応答）、§5（セキュリティ考慮）
- OpenID Connect Dynamic Client Registration 1.0 §2（`redirect_uris` REQUIRED などの OIDC 側制約）、§3.1〜§3.3（エンドポイント仕様）
- OpenID Connect Discovery 1.0 §3（`registration_endpoint` メタデータ）
- RFC 6750（initial access token を要求する構成での Bearer トークンの提示方法と 401 応答）

## プロトコルフロー

```text
Client                                 OP (生成コード + experimental/dynamic-client-registration + core)
 |                                       |
 |-- POST /register -------------------->| (1) （設定時のみ）Authorization: Bearer を initial access token と
 |   Content-Type: application/json      |     定数時間比較。不一致・欠落は 401（何も登録しない）
 |   {                                   | (2) ボディ長と JSON 形式の検査（上限超過・非オブジェクトは 400）
 |     "redirect_uris": [...],           | (3) メタデータ検証: 未知フィールドを無視し、理解するフィールドの
 |     "token_endpoint_auth_method":...  |     値を検証（invalid_redirect_uri / invalid_client_metadata）
 |     ...                               | (4) 既定値の適用（grant_types=["authorization_code"] など）
 |   }                                   | (5) client_id と（confidential なら）client_secret を乱数生成
 |                                       | (6) 登録上限を確認してストアへ保存
 |<- 201 Created ------------------------|(7) 登録済み全メタデータ + 発行値を JSON で返す
 |   { "client_id": ...,                 |     （Cache-Control: no-store）
 |     "client_secret": ...,             |
 |     "client_id_issued_at": ...,       |
 |     "client_secret_expires_at": 0,    |
 |     ... }                             |
 |                                       |
 |-- GET /authorize?client_id=... ------>| 以降は既存の Authorization Code Flow がそのまま動く
 |                                       | （findClient が静的 Map → 動的ストアの順に解決する）
```

## 入出力

### リクエスト（RFC 7591 §3.1） — `POST /register`

`application/json` のボディで登録メタデータを受ける（§3.1 MUST）。
本機能が理解する（= 検証して登録に使う）フィールドは次の 5 つで、それ以外のフィールドは黙って無視する（§2「The authorization server MUST ignore any client metadata sent by the client that it does not understand」）。

| フィールド | 位置づけ | 本機能の扱い |
|---|---|---|
| `redirect_uris` | REQUIRED（OIDC Registration 1.0 §2。RFC 7591 §2 もリダイレクト系 grant を使うクライアントに登録を MUST とする） | 空でない文字列配列であること。各要素を core の `validateRegisteredRedirectUris`（`authorization-request.ts:422`）で検査し、投げられた `AuthorizationError` を捕捉して `invalid_redirect_uri` の `ClientRegistrationError` へ変換する（変換の理由はバリデーションの節） |
| `token_endpoint_auth_method` | OPTIONAL。既定 `client_secret_basic`（RFC 7591 §2） | `client_secret_basic` / `client_secret_post` / `none` のみ受理。それ以外の値（`private_key_jwt` など）は `invalid_client_metadata` |
| `grant_types` | OPTIONAL。既定 `["authorization_code"]`（RFC 7591 §2） | `authorization_code` と `refresh_token` の部分集合のみ受理。`refresh_token` 単独（`authorization_code` を含まない）と、それ以外の値は `invalid_client_metadata` |
| `response_types` | OPTIONAL。既定 `["code"]`（RFC 7591 §2） | `["code"]` のみ受理。それ以外は `invalid_client_metadata`（grant と response の整合は §2.1 の SHOULD「inconsistent state に登録させない」に従う） |
| `client_name` | OPTIONAL | 文字列であること。上限 128 文字、制御文字を含む値は拒否（`invalid_client_metadata`）。登録レコードに保持し応答に返すが、既存の生成 UI への表示統合はしない |

initial access token を要求する構成（設定値の節）では、`Authorization: Bearer <token>` ヘッダを RFC 6750 §2.1 の形式で読む。
RFC 7591 §3.1 は「オープンな登録を許すべき（SHOULD allow registration requests with no authorization）」とするため、既定は認可なしで受け付ける。

### 応答

#### 成功（RFC 7591 §3.2.1） — `201 Created`

`application/json` で、発行値と登録済みの全メタデータを返す（§3.2.1「the authorization server MUST return all registered metadata about this client」）。

| フィールド | 値 |
|---|---|
| `client_id` | 乱数生成した一意識別子（未解決事項 U2 の形式） |
| `client_secret` | `token_endpoint_auth_method` が `client_secret_basic` / `client_secret_post` の場合のみ。32 バイト乱数の base64url（43 文字） |
| `client_id_issued_at` | 発行時刻（UNIX 秒） |
| `client_secret_expires_at` | `client_secret` を発行した場合のみ `0`（無期限。§3.2.1「REQUIRED if client_secret is issued」） |
| `redirect_uris` / `token_endpoint_auth_method` / `grant_types` / `response_types` | 既定値適用後の登録値 |
| `client_name` | 登録した場合のみ |

`registration_access_token` と `registration_client_uri` は返さない（非目標の節。両方返すか両方返さないかの MUST に従い「両方返さない」を選ぶ）。
応答には `Cache-Control: no-store` を付ける（`client_secret` を含むため。セキュリティ要件の節）。

#### エラー（RFC 7591 §3.2.2） — `400 Bad Request`

`application/json` で `error` と `error_description` を返す。

| error | 条件 |
|---|---|
| `invalid_redirect_uri` | `redirect_uris` の欠落・空配列・非文字列要素・URI 規則違反 |
| `invalid_client_metadata` | 上記以外の検証失敗（非 JSON ボディ・非オブジェクト・ボディ長超過・理解するフィールドの不正値・grant/response の不整合） |

`error_description` は ASCII の固定文言に上限を課し、リクエストのメタデータ値（URI 文字列を含む）を反映しない（セキュリティ要件の節）。
initial access token を要求する構成でトークンが欠落・不一致の場合は `401 Unauthorized` と `WWW-Authenticate: Bearer error="invalid_token"` を返し（RFC 6750 §3）、ボディの検証には進まない。
登録上限超過時の応答は未解決事項 U1。

## 公開API案（`@maronn-openid-connect/experimental/dynamic-client-registration`）

HTTP にもストアにも触れない純関数群として設計する（rp-initiated-logout と同じ方針）。
乱数は core 公開の `generateRandomString` を使い、テストでは注入して固定できる。

```typescript
/** 検証エラー。error は RFC 7591 §3.2.2 のエラーコード */
export class ClientRegistrationError extends Error {
  readonly error: 'invalid_redirect_uri' | 'invalid_client_metadata';
  readonly errorDescription: string;
}

/** 検証済み登録メタデータ（既定値適用後） */
export interface ValidatedClientRegistration {
  redirectUris: string[];
  tokenEndpointAuthMethod: 'client_secret_basic' | 'client_secret_post' | 'none';
  grantTypes: string[];
  responseTypes: string[];
  clientName?: string;
}

export interface ValidateClientRegistrationOptions {
  /** ボディ（パース前の文字列）の最大長。既定 16384 */
  maxBodyBytes?: number;
}

/**
 * 登録リクエストボディ（文字列）を検証し、既定値を適用して返す。
 * 未知フィールドは黙って捨てる（RFC 7591 §2 MUST ignore）。
 * 失敗時は ClientRegistrationError を投げる。
 */
export function validateClientRegistrationRequest(
  rawBody: string,
  options?: ValidateClientRegistrationOptions,
): ValidatedClientRegistration;

/** 発行値を含む登録レコード。生成コードの RegisteredClient 型に適合する */
export interface DynamicallyRegisteredClient {
  clientId: string;
  clientSecret?: string;
  clientType: 'confidential' | 'public';
  redirectUris: string[];
  grantTypes: string[];
  responseTypes: string[];
  tokenEndpointAuthMethod: 'client_secret_basic' | 'client_secret_post' | 'none';
  clientName?: string;
  clientIdIssuedAt: number;
}

export interface BuildRegisteredClientOptions {
  /** テスト用の注入点。省略時は core generateRandomString による乱数生成 */
  generateClientId?: () => string;
  generateClientSecret?: () => string;
  now?: () => number;
}

/**
 * 検証済みメタデータから登録レコードを組み立てる。
 * token_endpoint_auth_method が none なら clientType: 'public' とし client_secret を発行しない。
 */
export function buildRegisteredClient(
  metadata: ValidatedClientRegistration,
  options?: BuildRegisteredClientOptions,
): DynamicallyRegisteredClient;

/** 201 応答ボディ（RFC 7591 §3.2.1。スネークケースの JSON オブジェクト）を組み立てる */
export function buildClientRegistrationResponse(
  client: DynamicallyRegisteredClient,
): Record<string, unknown>;

/**
 * Authorization ヘッダの Bearer トークンを期待値と定数時間比較する。
 * initial access token を要求する構成の生成コードが使う。
 * 比較は Web Crypto の HMAC を使った定数時間比較（core 内部の timingSafeEqual と同じ方式。
 * core は同関数を公開していないため本機能内に持つ。機能間の重複許容の方針どおり）。
 */
export function verifyInitialAccessToken(
  authorizationHeader: string,
  expectedToken: string,
): Promise<boolean>;
```

## CLIオプション案

- `maronn-oidc generate <framework> --enable dynamic-client-registration`
- `EXPERIMENTAL_FEATURES` の末尾（`'rp-initiated-logout'` の後）に `'dynamic-client-registration'` を追加し、`OidcFeatureConfig` に `dynamicClientRegistration: boolean` を追加する（既定 `false`）
- `packages/cli/src/index.ts:32` の `withExperimentalPackage` の feature チェック列挙に `features.dynamicClientRegistration` を追加し、選択時のみ install コマンド案内に `@maronn-openid-connect/experimental` が入るようにする
- 機能の説明文（`features.ts` の JSDoc と unknown-feature メッセージ）で Experimental であることを明示する
- 他機能との依存・競合はない（`jwt-introspection-response` の introspection 依存のような検証は不要）

## 設定値とデフォルト

生成コードに experimental 機能専用の設定オブジェクト `dynamicClientRegistrationConfig` を置く（Token Exchange の `tokenExchangeConfig` と同じパターン）。

| 設定 | 既定値 | 意味 |
|---|---|---|
| `initialAccessToken` | `undefined` | 設定すると `POST /register` に `Authorization: Bearer` での提示を要求する。未設定ならオープン登録（RFC 7591 §3.1 SHOULD） |
| `maxRegisteredClients` | `100` | 動的登録クライアントの総数上限。超過時の応答は U1 |
| `maxRegistrationBodyBytes` | `16384` | リクエストボディの最大長（DoS 対策） |

エンドポイントのパスは `/register` 固定とする（最終確定は U3）。

## バリデーション / エラー処理

検証は次の順序で行い、最初に失敗した段階のエラーを返す。

1. （設定時のみ）initial access token の検証。失敗は 401（ボディを読む前に返す）
2. ボディ長の上限検査。超過は `invalid_client_metadata`
3. JSON パースとオブジェクト形式の検査。非 JSON と非オブジェクト（配列・プリミティブ）は `invalid_client_metadata`
4. 未知フィールドの除去（エラーにしない。RFC 7591 §2 MUST ignore）
5. `redirect_uris` の検査（欠落・空・非文字列要素・URI 規則違反は `invalid_redirect_uri`）
6. `token_endpoint_auth_method` / `grant_types` / `response_types` / `client_name` の値検査と整合検査（違反は `invalid_client_metadata`）
7. 既定値の適用と登録レコードの構築
8. 登録上限の検査とストア保存（生成コード側。超過時の応答は U1）

エラー処理の原則:

- `error_description` は固定の ASCII 文言とし、リクエスト由来の値（URI・メタデータ値）を埋め込まない。どのフィールドが不正かはフィールド名だけで示す（例: `redirect_uris must be a non-empty array of strings`）
- core の `validateRegisteredRedirectUris` は設定ミス検知用の関数であり、違反 URI をメッセージへ埋め込んだ `server_error` の `AuthorizationError` を投げる（`authorization-request.ts:426` ほか）。本機能はこの例外を捕捉し、コードを `invalid_redirect_uri`（RFC 7591 §3.2.2）へ、文言を URI を含まない固定 ASCII へ差し替えた `ClientRegistrationError` として投げ直す。検査規則そのもの（フラグメント禁止、危険スキーム拒否、非ループバック平文 http 拒否）は core と同一に保たれ、エラー表現だけを登録エンドポイントの契約へ合わせる
- 検証途中で例外を握りつぶさない。`ClientRegistrationError` 以外の例外は生成コードのルートで 500 に落とす（他ルートと同じ扱い）
- 401 経路（initial access token 不一致）では、トークンが「欠落」か「不一致」かを応答で区別しない

## セキュリティ要件

| 脅威 / 論点 | 対策 |
|---|---|
| 無制限登録による DoS（RFC 7591 §5） | 総数上限 `maxRegisteredClients`（既定 100）とボディ長上限 `maxRegistrationBodyBytes`（既定 16384）。IP 単位の流量制御はデプロイ環境の責務と README に明記する |
| 不正な redirect_uri の登録（オープンリダイレクタの持ち込み） | 静的クライアントと同一の core `validateRegisteredRedirectUris` 規則を登録時に適用する。フラグメント付き・`javascript:` 等の危険スキーム・非ループバック平文 http は登録段階で `invalid_redirect_uri` になる |
| `client_secret` の強度と露出 | 32 バイト（256 ビット）を `crypto.getRandomValues` で生成する。応答は `Cache-Control: no-store` を付け、シークレットをログに出さない。エラー応答にメタデータ値を反映しないため、シークレットが応答以外の経路に乗ることはない |
| initial access token の照合 | 定数時間比較（Web Crypto HMAC 方式）。欠落と不一致を応答で区別せず、トークン値をログに出さない |
| 既存クライアントの上書き | `client_id` は乱数生成のみで、リクエストから指定させない。ストア保存は「既存キーが無いこと」を前提とし、静的 Map の client_id と衝突しない形式（U2）にする |
| SSRF | v1 は URL 参照系メタデータ（`jwks_uri` / `sector_identifier_uri` / `logo_uri` など）を受理しないため、登録処理が外部へリクエストを発行する経路がない |
| エラー情報の露出 | `error_description` は固定 ASCII 文言。検証失敗の詳細（どの URI が・なぜ）を攻撃者の探索に使わせない |
| 生成コードの安全性 | 機能無効時は `/register` ルートもストアも resolver 合成も生成されず、生成物はバイト同一（完了条件） |

## プライバシー考慮

- 登録メタデータはクライアント（アプリケーション）の属性であり、エンドユーザーの個人データを含まない
- `client_name` は利用者入力の表示名であり、ログへ出力しない（表示統合も v1 ではしない）
- 動的登録クライアントの一覧を外部へ公開するエンドポイントは作らない

## 配置案 / CLI生成コードからの利用方法 / coreとの境界

```text
packages/experimental/
  src/
    dynamic-client-registration/
      index.ts                           # 公開 API の再エクスポート
      registration-request.ts            # validateClientRegistrationRequest
      registration-request.test.ts
      registered-client.ts               # buildRegisteredClient / buildClientRegistrationResponse
      registered-client.test.ts
      initial-access-token.ts            # verifyInitialAccessToken（定数時間比較を含む）
      initial-access-token.test.ts
```

- `packages/experimental/package.json` の `exports` に `"./dynamic-client-registration"` を追加する（ルート `.` からの再エクスポートはしない）
- 生成コード（CLI テンプレート）側の責務:
  - `POST /register` ルート: ボディ読み取り → （設定時）`verifyInitialAccessToken` → `validateClientRegistrationRequest` → `buildRegisteredClient` → 上限検査とストア保存 → `buildClientRegistrationResponse` を 201 で返す
  - 動的登録クライアントの in-memory ストア（既存 `ProviderStores` 群と同じ配置。`samples/hono-cloudflare/src/oidc-provider/store.ts:648` の `ProviderStores` / 985 行の `defaultProviderStores` パターン）
  - `findClient` の合成: 静的 `createInMemoryClientResolver`（`config.ts:184`）を先に引き、無ければ動的ストアを引く
  - discovery スプレッドマージへ `registration_endpoint: \`${issuer}/register\`` を追加（`templates.ts:7601` 周辺の既存パターン）
- 依存方向は既存どおり:

```text
packages/core ──X──> packages/experimental（import禁止・coreの必須機能にしない）
packages/cli  ─────> @maronn-openid-connect/experimental（許可・生成コードの依存として明示）
@maronn-openid-connect/experimental ─────> @maronn-openid-connect/core（peerDependencies として許可）
```

- core から使うのは公開 API（`validateRegisteredRedirectUris` / `generateRandomString`）のみで、core の変更はしない
- 本機能は他の experimental 機能のコードを import しない（機能間の独立性優先。定数時間比較は本機能内に持つ）

## テスト計画

### 単体テスト（`packages/experimental/src/dynamic-client-registration/*.test.ts`、t_wada 流 TDD）

- 正常系: 最小リクエスト（`redirect_uris` のみ）で既定値が適用される / 全フィールド指定 / `none` で public client になり secret が出ない / 未知フィールドが黙って落ちる / 応答 JSON のフィールドと具体値（`client_secret_expires_at: 0` を含む）
- 異常系: 非 JSON / 非オブジェクト / ボディ長超過 / `redirect_uris` の欠落・空配列・非文字列要素・フラグメント付き・`javascript:`・非ループバック http / `token_endpoint_auth_method` の未対応値 / `grant_types` の未対応値と `refresh_token` 単独 / `response_types` の `code` 以外 / `client_name` の非文字列・長さ超過・制御文字
- 境界値: ボディ長ちょうど / `client_name` 128 文字ちょうど / `redirect_uris` がループバック http と https の混在
- initial access token: 一致 / 不一致 / ヘッダ形式不正 / Bearer 以外のスキーム
- エラー内容: `error` コードの対応（`invalid_redirect_uri` と `invalid_client_metadata` の区別）と `error_description` にリクエスト値が含まれないこと

### CLIテスト（`packages/cli/src/__tests__`）

- `--enable dynamic-client-registration` で `/register` ルート・ストア・resolver 合成・discovery 追記が生成され、`@maronn-openid-connect/experimental/dynamic-client-registration` からの import があること
- 未指定時に上記が一切生成されず、install コマンド案内にも experimental package が現れないこと（既存スナップショットのバイト同一）
- 他機能（全機能有効の hono-cloudflare 構成）との共存で生成物がビルド・型検査を通ること

### conformance.test.ts（CLI 生成コードで追加。`--enable dynamic-client-registration` 生成 OP への結合テスト）

- `POST /register`（最小メタデータ）が 201 と必須フィールドを返す
- 発行された `client_id` / `client_secret` で Authorization Code Flow（PKCE 付き）が完了し、トークンが取れる
- `token_endpoint_auth_method: "none"` で登録した public client がシークレットなしでフローを完了できる
- 不正メタデータの 400（`invalid_redirect_uri` / `invalid_client_metadata` の使い分け）
- discovery に `registration_endpoint` が含まれる
- 未知フィールドを含む登録が成功し、応答に未知フィールドが現れない

### E2E（`tests/e2e`、Playwright）

- fetch で `POST /register` → 発行されたクライアントで実ブラウザのログイン・同意・コールバックまで完了する全周
- 登録前の `client_id` では `/authorize` が未知クライアントとして拒否されることの対比

## ドキュメント要件

- **利用者向けドキュメント**（OSS リポジトリ。Phase 2 の PR に含める）: `docs/library-document/src/content/docs/experimental/` に `dynamic-client-registration` ページを追加し、index の機能一覧を更新する。Experimental 警告 / 対応仕様 / `--enable` での有効化 / オープン登録の既定と initial access token の設定 / 登録例（curl） / 発行クライアントでのフロー実行例 / エラー処理 / セキュリティ注意（在庫上限・永続化なし・本番非推奨） / 既知の制約（RFC 7592 なし・メタデータ 5 フィールド） / core の静的登録との違い
- **実装解説**（notes リポジトリ。`implementation-guides/experimental/` に日本語版と英語版）: `.notes/CLAUDE.md` の「実装解説」の規約に従い、全ファイル・CLI 注入コード・E2E スペックを全文掲載する

## Changeset要件

- `packages/experimental` の変更に changeset は手で書かない（main への push で CI が patch を自動生成する。`RELEASE.md`）
- `packages/cli` の変更には手書きの changeset（minor）を含める（rp-initiated-logout の先例どおり）

## 実装順序

1. experimental 単体: `registration-request.ts` → `registered-client.ts` → `initial-access-token.ts` の順に TDD で実装し、`package.json` の `exports` に subpath を追加する
2. `packages/cli/src/features.ts` に feature 追加（`EXPERIMENTAL_FEATURES` 末尾、`OidcFeatureConfig`、`EXPERIMENTAL_FEATURE_KEYS`、`DEFAULT_FEATURES`）
3. `packages/cli/src/index.ts` の `withExperimentalPackage` に feature チェックを追加
4. hono テンプレート: ルート・ストア・resolver 合成・discovery 追記・設定オブジェクト
5. web-standard（express / fastify / nextjs が共有）テンプレートへ同じ変更を展開
6. CLI テストと conformance テンプレートの更新、`samples/hono-cloudflare/package.json` の generate スクリプトへ `--enable dynamic-client-registration` を追加して再生成
7. E2E スペック追加、利用者向け Docs、実装解説（ja / en）

## 完了条件

1. experimental / cli の単体テストがすべて通る
2. `--enable dynamic-client-registration` で生成した OP への conformance テスト（登録 → フロー成立まで）が通る
3. 未指定時の生成物がバイト同一（`check:generated` が通る）
4. discovery の `registration_endpoint` が有効時のみ出力される（conformance テストの具体値で固定）
5. E2E（登録 → 実ブラウザでのフロー完了）が通る
6. 利用者向け Docs と実装解説（ja / en）が作成済み
7. core への experimental import が無く、experimental の core 依存が peerDependencies のみ

## 未解決事項

| ID | 論点 | 選択肢 | 確定に使う資料 | 確定予定 |
|---|---|---|---|---|
| U1 | 登録上限（`maxRegisteredClients`）超過時の応答 | (a) `429 Too Many Requests` + 素の JSON（RFC 6585。ただし RFC 7591 のエラー語彙の外） / (b) `400` + `invalid_client_metadata`（語彙内だが意味がずれる） | RFC 7591 §3.2.2 の「unless otherwise specified」の射程、RFC 6585、生成ルートの既存エラー実装パターン | Review 2（セキュリティ観点） |
| U2 | `client_id` の形式（`dcr-` プレフィックスの有無と乱数長） | (a) `dcr-` + `generateRandomString(16)`（由来が判別でき静的 ID と衝突しない） / (b) 素の `generateRandomString(16)` | 生成コードの既存ストアのキー形式、静的クライアント ID の命名、`generateRandomString` の既存利用箇所 | Review 2 |
| U3 | エンドポイントのパス名（`/register` か `/registration`） | 本仕様書は `/register` を仮置き | OIDC Discovery の `registration_endpoint` の一般的な対応パス、生成テンプレートの既存ルート命名（`/par` など短い動詞・名詞） | Review 3（テンプレート一貫性確認時） |

## 将来の昇格考慮

- core へ「メタデータ検証と発行値算出」の純関数を移し、永続化を `ClientRegistrationStore` インタフェース注入にする（`study-material/ext-dynamic-client-registration.md` の方針 A がそのまま昇格先）
- `client_secret` のストア保存をハッシュ化（検証時は提示値をハッシュして比較）に切り替えるかを、core の静的クライアント（平文保持）と合わせて再設計する
- RFC 7592 の管理（`registration_access_token` / `registration_client_uri` / GET・PUT・DELETE）を足すかは、利用者の要望が出た時点で別提案として起こす
- OIDC 固有メタデータ（`jwks` / `id_token_signed_response_alg` / `default_max_age` など。生成コードの `RegisteredClient` が既に持つ軸）の受理は、フィールドごとに検証とセキュリティ面（とくに URL 参照系の SSRF）を評価して段階的に広げる
- 定数時間比較（`timingSafeEqual`）を core の公開 API へ昇格させ、本機能内の重複実装を解消する
