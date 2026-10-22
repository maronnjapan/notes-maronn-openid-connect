# Dynamic Client Registration（RFC 7591）実装解説

- **feature-id**: `dynamic-client-registration`
- **準拠仕様**: [RFC 7591: OAuth 2.0 Dynamic Client Registration Protocol](https://datatracker.ietf.org/doc/html/rfc7591)、[OpenID Connect Dynamic Client Registration 1.0](https://openid.net/specs/openid-connect-registration-1_0.html) のサブセット
- **有効化**: `maronn-oidc generate <framework> --enable dynamic-client-registration`
- **利用者向けドキュメント**: `docs/library-document/src/content/docs/experimental/dynamic-client-registration.md`

[English version](./dynamic-client-registration.en.md)

## 機能の概要

この OP でクライアントを増やす方法は、既定の生成物では静的な登録簿の編集しかない。
`config.ts` の Map へエントリを書き足すか、`--db` で生成した場合はクライアント表へ `registerClient()` で投入する起動時処理を書き、いずれもビルドと再起動を経てはじめて新しいクライアントが使える。
この運用は二つの場面で摩擦になる。
一つは OIDF Conformance Suite の実行で、多くのテストプランは「テスト開始時に OP へクライアントを動的登録できる」前提で組まれている。
もう一つは、MCP（Model Context Protocol）クライアントのように接続時の動的登録を前提とするエコシステムのクライアント検証である。

**Dynamic Client Registration**（以下 DCR）は、クライアントが実行時に自分のメタデータを送って登録を受けるクライアント登録エンドポイントを定義する仕様である。
`--enable dynamic-client-registration` で生成した OP は `POST /register` を提供し、discovery に `registration_endpoint` を広告する。

```text
Client                                 OP（生成コード + experimental/dynamic-client-registration + core）
 |                                       |
 |-- POST /register -------------------->| (1) （設定時のみ）Authorization: Bearer を initial access token と
 |   Content-Type: application/json      |     定数時間比較。不一致・欠落は 401（何も登録しない）
 |   {"redirect_uris": [...], ...}       | (2) Content-Type・ボディ長・JSON 形式の検査（違反は 400）
 |                                       | (3) 理解する 6 フィールドだけを選び取り、値を検証して既定値を適用
 |                                       | (4) client_id と（confidential なら）client_secret を乱数生成
 |                                       | (5) 登録上限を確認してストアへ保存
 |<- 201 Created ------------------------|(6) 発行値 + 登録済み全メタデータを JSON で返す（Cache-Control: no-store）
 |                                       |
 |-- GET /authorize?client_id=dcr-... -->| 以降は既存の Authorization Code Flow がそのまま動く
 |                                       | （クライアント解決が「設定済みの解決 → 動的ストア」の順に引く）
```

発行された `client_id` と `client_secret` はそのまま `/authorize` と `/token` で使える。
登録されたクライアントへの検証（PKCE、`redirect_uri` の完全一致、クライアント認証）は静的登録のクライアントと完全に同一で、違うのはクライアント解決の最後に動的ストアがもう一段あることだけである。

### ユースケース

- OIDF Conformance Suite の動的登録前提プランを、この OP に向けて実行する
- MCP クライアントのように接続時に DCR で自分を登録するクライアント実装を、手元の OP で受け止めて検証する
- 複数のテストアプリを、静的設定の編集とデプロイなしに素早く繋ぐ
- `token_endpoint_auth_method` や `grant_types` の既定値がどう適用されるかなど、RFC 7591 の素の挙動を確認する

### 実装スコープと非目標

実装したのは次の範囲である。

- `POST /register`（RFC 7591 §3。オープン登録が既定で、任意で initial access token を要求できる）
- 受理するメタデータ 6 フィールド（`redirect_uris` / `token_endpoint_auth_method` / `grant_types` / `response_types` / `client_name` / `scope`）の検証と、RFC 7591 §2 の既定値適用
- 発行値（`dcr-` プレフィックス付き `client_id`、256 ビットの `client_secret`）の生成と §3.2.1 の 201 応答
- 動的登録クライアントの in-memory ストアと、設定済みクライアント解決への合成
- discovery への `registration_endpoint` の広告（OIDC Discovery 1.0 §3）

非目標は次のとおりである。

- RFC 7592（登録後の参照・更新・削除）。OIDC Dynamic Client Registration 1.0 §3.2 は `registration_access_token` と `registration_client_uri` を「両方返すか両方返さないか」の MUST で縛るため、どちらも返さない
- `software_statement`（RFC 7591 §2.3）。未知フィールドとして無視し、`invalid_software_statement` を返す経路は作らない
- initial access token の発行・管理。生成コードの設定に置いた固定文字列 1 つとの照合だけを提供する
- OIDC 固有メタデータの解釈。とくに URL 参照系（`jwks_uri` / `logo_uri` など）は取得処理が SSRF の面を開くため、受理しない
- 動的登録クライアントへの experimental grant の許可。`grant_types` に登録できるのは `authorization_code` と `refresh_token` だけで、Token Exchange や CIBA の URN は拒否して機能間の結合を作らない
- IP 単位のレート制限（RFC 7591 §5 の MAY）。本機能は総数上限とボディ長上限だけを持ち、流量制御はデプロイ層の責務とする

## 実装の設計方針

実装は判定と実行を分けている。
experimental パッケージ側は、HTTP にもストアにも触れない純関数群（登録リクエストの検証と既定値適用、登録レコードと 201 応答の組み立て、initial access token の照合）だけを持つ。
HTTP の受け口、ストアへの保存、総数上限の検査は生成コードの責務で、調査資料が昇格先として整理した「core に検証と発行値算出の純関数を置き、永続化をストア契約の注入にする」形へそのまま移植できる分担にしてある。

core への変更は無い。
core から使うのは公開 API の `validateRegisteredRedirectUris` と `generateRandomString` だけで、前者によって動的登録の `redirect_uris` には静的クライアントと同一の検査規則（フラグメント禁止、危険スキーム拒否、非ループバックの平文 http 拒否）が掛かる。
定数時間比較は core 内部の `timingSafeEqual` と同じ方式を本機能内に持つ。
core は同関数を公開しておらず、公開 API 以外への依存は作れないためで、experimental 機能間でコードの重複を許容する方針どおりの判断である（core の公開 API へ昇格させる案はタスクの「将来の昇格考慮」に記録した）。

脅威モデルの中心は「未認証で書き込めるエンドポイント」であることに尽きる。
設計判断の多くはこの一点から導かれている。

- **未知フィールドは allowlist-pick で捨てる**。RFC 7591 §2 の「理解しないメタデータは無視しなければならない（MUST）」は、パース結果をスプレッドでコピーして known フィールドを上書きする実装でも満たせるが、それでは `__proto__` のようなプロトタイプ経路のキーを持つ入力の扱いが実装任せになる。理解する 6 フィールドだけを新しいオブジェクトへ選び取る方式なら、未知のキーはそもそも読まれない
- **`client_id` は `dcr-` プレフィックス付きの乱数で、リクエストから指定させない**。静的クライアントの `client_id` は人間が命名する（サンプルでは `example-client`）ため、固定プレフィックスで名前空間が分かれ、既存クライアントの上書きが構造的に起きない。`client_id` は秘密情報ではないので、動的登録由来だと明かしても失うものはなく、ログの調査性はむしろ上がる
- **`scope` は登録して、クライアント単位の許可一覧にする**。core の `ClientInfo.scope` を設定したクライアントは一覧外の scope 要求を `invalid_scope` で拒否されるが、当初の実装は登録リクエストの `scope`（RFC 7591 §2）を未知フィールドと同じ扱いで捨てていたため、この制限を動的登録クライアントに掛ける手段が無かった。検証して登録レコードへ積むことで、静的クライアントと同じ最小権限が動的登録にも届く。`--scope` でカスタムスコープを宣言した構成では、OP が広告する一覧（`SUPPORTED_SCOPES`）に無い値の登録を `invalid_client_metadata` で拒否し、201 応答が広告と矛盾する約束をしないようにする。省略時は静的クライアントの省略時と同じく、制限を掛けずに登録する
- **上限超過は 429 で答え、`invalid_client_metadata` を流用しない**。RFC 7591 §3.2.2 のエラー語彙はメタデータの不備を表すものである。総数上限の超過に 400 を返すとクライアントに「メタデータを直せば通る」と誤認させ、変更再試行のループが、上限が守るはずの DoS の面を逆に増幅する。`Retry-After` も付けない。上限は流量ではなく在庫の天井で、回復時期を約束できないためである
- **401 は RFC 6750 §3.1 の 2 形に分ける**。`Authorization` ヘッダが無いリクエストにはエラーコードを付けず（§3.1 SHOULD NOT）、提示して失敗したリクエストには `error="invalid_token"` を返す。欠落と不一致を区別しても攻撃者への追加情報は無い（要求者は自分が何を送ったかを知っている）。守るべき本質は、期待トークンの情報（長さ、部分一致）を応答へ反映しないことである
- **`error_description` は固定の ASCII 文言に限る**。送られた URI やメタデータの値を文言に埋め込まず、検証失敗の詳細を攻撃者の探索に使わせない

ストアの置き場所にも先例がある。
動的登録クライアントの in-memory ストアは、PAR / Device / CIBA の experimental ストアと同じく `--db` の有無に関わらず生成コード内の globalThis シングルトンとし、`--db` でバックエンドへ差し替わる core ストア群（`ProviderStores`）へは加えない。
動的登録はプロセス再起動で消えるという割り切りも同じで、Conformance Suite の実行単位では問題にならない。

クライアント解決の合成は、生成コードの基底 resolver（`--db` なしは静的 Map、`--db sql` / `--db kv` はクライアント表・キー）を先に引き、無ければ動的ストアを引く順にした。
静的登録が常に勝つ順序であり、`dcr-` プレフィックスにより衝突自体が起きないことと合わせて二重の防壁になる。

discovery だけは他の experimental 機能と違う経路を使った。
PAR 以降の 8 機能は「core の `DiscoveryConfig` に対応フィールドが無いメタデータをスプレッドマージで足す」パターンだったが、`registration_endpoint` は core が最初から条件付き出力のフィールドとして持っている。
core を変えずに使える正規の経路があるので、`buildProviderMetadata` へ `registrationEndpoint` を渡す形にした。

## 実装コードの全文と解説

`packages/experimental/src/dynamic-client-registration/` の全ファイルを載せる。

### registration-request.ts（登録リクエストの検証と既定値適用）

検証の中心となるモジュールである。
パース前のボディ文字列を受け取り、バイト長上限、JSON 形式、各フィールドの値を順に検査して、既定値適用後の `ValidatedClientRegistration` を返す。
ボディ長の判定は文字列長（UTF-16 コード単位数）ではなく `TextEncoder` で得た UTF-8 バイト長で行い、多バイト文字を含む境界値テストを決定的にしている。

`redirect_uris` の検査には設計判断が一つある。
core の `validateRegisteredRedirectUris` は設定ミス検知用の関数で、違反 URI をメッセージへ埋め込んだ `server_error` の `AuthorizationError` を投げる。
そのまま流用すると「リクエスト由来の値を文言に反映しない」という本機能のエラー方針と、RFC 7591 §3.2.2 のエラーコード（`invalid_redirect_uri`）の両方に反する。
そこで core の例外を捕捉し、検査規則は同一のまま、コードと文言だけを登録エンドポイントの契約へ差し替えて投げ直している。

`grant_types` は `authorization_code` と `refresh_token` の部分集合だけを受理し、さらに `authorization_code` を含むことを要求する。
`response_types` を `["code"]` に固定する本機能では、`code` に対応する grant を持たない登録は RFC 7591 §2.1 が避けるべきとする不整合な状態（inconsistent state）に当たるためである。

`scope` はスペース区切り文字列として受け取り、RFC 6749 §3.3 の構文（scope-token の文字集合、スペース 1 つ区切り）で検査する。
受理可能な一覧はオプション `supportedScopes` の注入で渡し、純関数が生成コード側のスコープポリシーを知らないままで済むようにした。
未指定なら構文検証だけで受理する。
scope ポリシーモジュールを生成しない構成では OP 自体が受理一覧を持たず、登録された一覧は「クライアントが自分に課す制限」として機能するためである。
重複は最初の出現だけを残して 1 つに正規化し、エラー文言は他のフィールドと同じく固定の ASCII に限る。
省略時は `client_name` と同じくキー自体を出さない。

```typescript
/**
 * OAuth 2.0 Dynamic Client Registration (RFC 7591) — 登録リクエストの検証。
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * §3.1: 登録リクエストのボディは application/json の JSON オブジェクト。
 * Content-Type の検査は HTTP を知る生成コード側の責務で、ここはパース前の
 * ボディ文字列を受け取り、検証済みメタデータ（既定値適用後）を返す。
 */

import { validateRegisteredRedirectUris } from '@maronn-openid-connect/core';

/**
 * 検証エラー。error は RFC 7591 §3.2.2 のエラーコードで、HTTP 応答では
 * 400 の JSON ボディ（error / error_description）になる。
 *
 * errorDescription は固定の ASCII 文言に限り、リクエスト由来の値（URI や
 * メタデータ値）を決して埋め込まない。検証失敗の詳細を攻撃者の探索に
 * 使わせないため（仕様書のセキュリティ要件）。
 */
export class ClientRegistrationError extends Error {
  readonly error: 'invalid_redirect_uri' | 'invalid_client_metadata';
  readonly errorDescription: string;

  constructor(
    error: 'invalid_redirect_uri' | 'invalid_client_metadata',
    errorDescription: string,
  ) {
    super(errorDescription);
    this.name = 'ClientRegistrationError';
    this.error = error;
    this.errorDescription = errorDescription;
  }
}

/** 検証済み登録メタデータ（RFC 7591 §2 の既定値適用後）。 */
export interface ValidatedClientRegistration {
  redirectUris: string[];
  tokenEndpointAuthMethod: 'client_secret_basic' | 'client_secret_post' | 'none';
  grantTypes: string[];
  responseTypes: string[];
  clientName?: string;
  /**
   * RFC 7591 §2 `scope`: このクライアントが要求してよい scope 値の一覧。
   * 省略時はキー自体が無く、クライアント単位の制限を掛けずに登録される。
   */
  scope?: string[];
}

export interface ValidateClientRegistrationOptions {
  /**
   * ボディ（パース前の文字列）の UTF-8 バイト長の上限。既定 16384。
   * 文字列長（UTF-16 コード単位数）ではなく TextEncoder で得たバイト長で
   * 判定し、多バイト文字を含む境界値テストを決定的にする。
   */
  maxBodyBytes?: number;
  /**
   * この OP が受理する scope 値の一覧。指定すると、`scope` メタデータに
   * 一覧外の値を含む登録を invalid_client_metadata で拒否する。未指定なら
   * 構文検証のみ行う（OP 自体が受理一覧を持たない構成向け）。
   */
  supportedScopes?: readonly string[];
}

const DEFAULT_MAX_BODY_BYTES = 16384;

/** 本機能が理解する auth method（RFC 7591 §2 のうち secret 系と none）。 */
const SUPPORTED_TOKEN_ENDPOINT_AUTH_METHODS = [
  'client_secret_basic',
  'client_secret_post',
  'none',
] as const;

/**
 * 動的登録で許す grant_type。experimental grant の URN（token-exchange /
 * device / CIBA など）は登録させず、機能間の結合を作らない（仕様書の非目標）。
 */
const SUPPORTED_GRANT_TYPES = ['authorization_code', 'refresh_token'] as const;

/**
 * 登録リクエストボディ（文字列）を検証し、既定値を適用して返す。
 *
 * 未知フィールドは黙って捨てる（RFC 7591 §2 MUST ignore）。実装は「理解する
 * 6 フィールドだけを新しいオブジェクトへ選び取る」allowlist-pick 方式で、
 * パース結果のスプレッドや Object.assign によるコピーをしない。`__proto__`
 * などプロトタイプ経路のキーを持つ入力は、読まれないまま不活性に落ちる。
 *
 * 失敗時は ClientRegistrationError を投げる。
 */
export function validateClientRegistrationRequest(
  rawBody: string,
  options?: ValidateClientRegistrationOptions,
): ValidatedClientRegistration {
  const maxBodyBytes = options?.maxBodyBytes ?? DEFAULT_MAX_BODY_BYTES;
  if (new TextEncoder().encode(rawBody).length > maxBodyBytes) {
    throw new ClientRegistrationError(
      'invalid_client_metadata',
      'request body must not exceed the configured maximum size',
    );
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(rawBody);
  } catch {
    throw new ClientRegistrationError(
      'invalid_client_metadata',
      'request body must be valid JSON',
    );
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    throw new ClientRegistrationError(
      'invalid_client_metadata',
      'request body must be a JSON object',
    );
  }
  const metadata = parsed as Record<string, unknown>;

  return {
    redirectUris: validateRedirectUris(metadata['redirect_uris']),
    tokenEndpointAuthMethod: validateTokenEndpointAuthMethod(
      metadata['token_endpoint_auth_method'],
    ),
    grantTypes: validateGrantTypes(metadata['grant_types']),
    responseTypes: validateResponseTypes(metadata['response_types']),
    ...pickClientName(metadata['client_name']),
    ...pickScope(metadata['scope'], options?.supportedScopes),
  };
}

/**
 * redirect_uris は REQUIRED（OIDC Dynamic Client Registration 1.0 §2）。
 * URI の規則そのもの（フラグメント禁止・危険スキーム拒否・非ループバック
 * 平文 http 拒否。ネイティブアプリ向けのカスタムスキームは通る）は core の
 * validateRegisteredRedirectUris に委ね、静的クライアントと同一の登録基準を
 * 適用する。core の例外は違反 URI をメッセージへ埋め込んだ server_error
 * なので、コードを invalid_redirect_uri（RFC 7591 §3.2.2）へ、文言を URI を
 * 含まない固定 ASCII へ差し替える。
 */
function validateRedirectUris(value: unknown): string[] {
  if (
    !Array.isArray(value) ||
    value.length === 0 ||
    !value.every((uri) => typeof uri === 'string')
  ) {
    throw new ClientRegistrationError(
      'invalid_redirect_uri',
      'redirect_uris must be a non-empty array of strings',
    );
  }
  try {
    validateRegisteredRedirectUris(value);
  } catch {
    throw new ClientRegistrationError(
      'invalid_redirect_uri',
      'each redirect_uri must be an absolute URI without a fragment and must not use a dangerous scheme or non-loopback http',
    );
  }
  return [...value];
}

/** token_endpoint_auth_method: OPTIONAL、既定 client_secret_basic（RFC 7591 §2）。 */
function validateTokenEndpointAuthMethod(
  value: unknown,
): 'client_secret_basic' | 'client_secret_post' | 'none' {
  if (value === undefined) {
    return 'client_secret_basic';
  }
  const supported = SUPPORTED_TOKEN_ENDPOINT_AUTH_METHODS.find(
    (method) => method === value,
  );
  if (!supported) {
    throw new ClientRegistrationError(
      'invalid_client_metadata',
      'token_endpoint_auth_method must be one of client_secret_basic, client_secret_post, none',
    );
  }
  return supported;
}

/**
 * grant_types: OPTIONAL、既定 ["authorization_code"]（RFC 7591 §2）。
 * response_types を ["code"] に固定する本機能では、code に対応する
 * authorization_code を含まない登録は §2.1 の inconsistent state に当たる
 * ため、refresh_token 単独は拒否する。重複は正規化して 1 つにする。
 */
function validateGrantTypes(value: unknown): string[] {
  if (value === undefined) {
    return ['authorization_code'];
  }
  if (
    !Array.isArray(value) ||
    !value.every((grantType) =>
      (SUPPORTED_GRANT_TYPES as readonly string[]).includes(grantType as string),
    )
  ) {
    throw new ClientRegistrationError(
      'invalid_client_metadata',
      'grant_types must be an array containing only authorization_code and refresh_token',
    );
  }
  const requested = new Set(value as string[]);
  if (!requested.has('authorization_code')) {
    throw new ClientRegistrationError(
      'invalid_client_metadata',
      'grant_types must include authorization_code',
    );
  }
  return SUPPORTED_GRANT_TYPES.filter((grantType) => requested.has(grantType));
}

/** response_types: OPTIONAL、既定 ["code"]（RFC 7591 §2）。code 以外は受理しない。 */
function validateResponseTypes(value: unknown): string[] {
  if (value === undefined) {
    return ['code'];
  }
  if (!Array.isArray(value) || value.length !== 1 || value[0] !== 'code') {
    throw new ClientRegistrationError(
      'invalid_client_metadata',
      'response_types must be exactly ["code"]',
    );
  }
  return ['code'];
}

/**
 * RFC 6749 §3.3: scope-token = 1*( %x21 / %x23-5B / %x5D-7E )。
 * `"`（%x22）と `\`（%x5C）を除く可視 ASCII。
 */
const SCOPE_TOKEN = /^[\x21\x23-\x5b\x5d-\x7e]+$/;

/**
 * scope: OPTIONAL（RFC 7591 §2）。要求時に使ってよい scope 値のスペース
 * 区切り文字列。登録した値は生成コード側で ClientInfo.scope（クライアント
 * 単位の許可一覧）になり、一覧外の scope 要求は invalid_scope で拒否される。
 *
 * 構文は RFC 6749 §3.3（scope = scope-token *( SP scope-token )）で検査し、
 * 空文字列・連続スペース・scope-token 外の文字は拒否する。supportedScopes が
 * 与えられた場合は一覧外の値も拒否する。エラー文言は固定の ASCII に限り、
 * リクエスト由来の値を埋め込まない（redirect_uris と同じ方針）。
 * 重複は最初の出現だけを残して 1 つに正規化する。省略時はキー自体を出さない
 * （exactOptionalPropertyTypes 互換）。
 */
function pickScope(
  value: unknown,
  supportedScopes: readonly string[] | undefined,
): { scope?: string[] } {
  if (value === undefined) {
    return {};
  }
  if (typeof value !== 'string') {
    throw new ClientRegistrationError('invalid_client_metadata', 'scope must be a string');
  }
  const tokens = value.split(' ');
  if (tokens.some((token) => !SCOPE_TOKEN.test(token))) {
    throw new ClientRegistrationError(
      'invalid_client_metadata',
      'scope must be a space-delimited list of scope values',
    );
  }
  if (
    supportedScopes !== undefined &&
    tokens.some((token) => !supportedScopes.includes(token))
  ) {
    throw new ClientRegistrationError(
      'invalid_client_metadata',
      'scope must only contain scope values this provider supports',
    );
  }
  return { scope: [...new Set(tokens)] };
}

const CLIENT_NAME_MAX_LENGTH = 128;

/**
 * client_name: OPTIONAL（RFC 7591 §2）。表示名なので長さと制御文字だけを
 * 検査する。省略時はキー自体を出さない（exactOptionalPropertyTypes 互換）。
 */
function pickClientName(value: unknown): { clientName?: string } {
  if (value === undefined) {
    return {};
  }
  if (typeof value !== 'string') {
    throw new ClientRegistrationError(
      'invalid_client_metadata',
      'client_name must be a string',
    );
  }
  if (value.length > CLIENT_NAME_MAX_LENGTH) {
    throw new ClientRegistrationError(
      'invalid_client_metadata',
      'client_name must be at most 128 characters',
    );
  }
  // C0 / C1 制御文字と DEL、bidi 制御文字（U+200E–U+200F / U+202A–U+202E /
  // U+2066–U+2069）、ゼロ幅文字（U+200B–U+200D / U+FEFF）。改行やエスケープで
  // ログ・画面を汚す値に加え、表示順の反転や見えない文字で表示名を偽装する
  // 値も登録させない。
  // eslint-disable-next-line no-control-regex
  if (/[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u202a-\u202e\u2066-\u2069\ufeff]/.test(value)) {
    throw new ClientRegistrationError(
      'invalid_client_metadata',
      'client_name must not contain control or invisible formatting characters',
    );
  }
  return { clientName: value };
}
```

### registered-client.ts（登録レコードと 201 応答の組み立て）

発行値の生成と応答の形だけを持つモジュールである。
`buildRegisteredClient` は `token_endpoint_auth_method` が `none` のクライアントを public として扱い、`client_secret` を発行しない（RFC 6749 §2.1 の public client はシークレットを持てない）。
乱数生成の関数と時計はオプションから注入でき、テストで発行値を固定できる。

返すレコードは生成コードの `RegisteredClient` 型（core の `ClientInfo & TokenClientInfo` を合成した型）へそのまま適合する。
core の型拡張が要らないのは、受理するメタデータを「core が既に解釈できる軸」に限定しているからで、`clientName` と `clientIdIssuedAt` は core が解釈しない付加情報として応答の組み立てだけに使われる。
登録された `scope` は配列のまま `RegisteredClient` の `scope`（core の `ClientInfo.scope`、クライアント単位の許可一覧）になり、201 応答ではスペース区切り文字列へ戻す（RFC 6749 §3.3 の表現）。

`buildClientRegistrationResponse` は §3.2.1 の「登録済みの全メタデータを返す MUST」に従い、既定値適用後の値もすべて載せる。
`client_secret_expires_at` は `client_secret` を発行した場合だけの REQUIRED で、`0` は「無期限」を意味する。

```typescript
/**
 * OAuth 2.0 Dynamic Client Registration (RFC 7591) — 登録レコードと 201 応答の
 * 組み立て。
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * ここはストアに触れない純関数で、発行値（client_id / client_secret）の生成と
 * §3.2.1 応答の形だけを持つ。保存と上限検査は生成コードの責務。
 */

import { generateRandomString } from '@maronn-openid-connect/core';
import type { ValidatedClientRegistration } from './registration-request.js';

/**
 * 発行値を含む登録レコード。生成コードの RegisteredClient 型
 * （core の ClientInfo & TokenClientInfo を合成した型）へそのまま適合する。
 * clientName と clientIdIssuedAt は core が解釈しない付加情報で、応答の
 * 組み立てだけに使われる。
 */
export interface DynamicallyRegisteredClient {
  clientId: string;
  clientSecret?: string;
  clientType: 'confidential' | 'public';
  redirectUris: string[];
  grantTypes: string[];
  responseTypes: string[];
  tokenEndpointAuthMethod: 'client_secret_basic' | 'client_secret_post' | 'none';
  clientName?: string;
  /**
   * RFC 7591 §2 `scope`: 登録時に許可した scope 一覧。core の ClientInfo.scope
   * としてそのまま解釈され、一覧外の scope 要求は invalid_scope で拒否される。
   * 省略時はクライアント単位の制限を掛けない。
   */
  scope?: string[];
  clientIdIssuedAt: number;
}

export interface BuildRegisteredClientOptions {
  /**
   * テスト用の注入点。省略時の既定は
   * generateClientId: () => `dcr-${generateRandomString(16)}`（128 ビット乱数）、
   * generateClientSecret: () => generateRandomString(32)（256 ビット乱数、43 文字）。
   */
  generateClientId?: () => string;
  generateClientSecret?: () => string;
  /** 現在時刻（ミリ秒）。省略時は Date.now。 */
  now?: () => number;
}

/**
 * client_id の固定プレフィックス。静的クライアントの client_id は人間が
 * 命名する（例: example-client）ため、このプレフィックスで名前空間が分かれ、
 * 既存クライアントとの衝突・上書きが構造的に起きない。client_id は秘密情報
 * ではないので、動的登録由来であることを明かしても失うものはない。
 */
const CLIENT_ID_PREFIX = 'dcr-';

/**
 * 検証済みメタデータから登録レコードを組み立てる。
 *
 * token_endpoint_auth_method が none のクライアントはシークレットを持てない
 * （RFC 6749 §2.1 の public client）ため、clientType: 'public' とし
 * client_secret を発行しない。それ以外は confidential として 256 ビットの
 * シークレットを発行する。
 */
export function buildRegisteredClient(
  metadata: ValidatedClientRegistration,
  options?: BuildRegisteredClientOptions,
): DynamicallyRegisteredClient {
  const generateClientId =
    options?.generateClientId ?? (() => `${CLIENT_ID_PREFIX}${generateRandomString(16)}`);
  const generateClientSecret =
    options?.generateClientSecret ?? (() => generateRandomString(32));
  const now = options?.now ?? Date.now;

  const isPublic = metadata.tokenEndpointAuthMethod === 'none';
  return {
    clientId: generateClientId(),
    ...(isPublic ? {} : { clientSecret: generateClientSecret() }),
    clientType: isPublic ? 'public' : 'confidential',
    redirectUris: [...metadata.redirectUris],
    grantTypes: [...metadata.grantTypes],
    responseTypes: [...metadata.responseTypes],
    tokenEndpointAuthMethod: metadata.tokenEndpointAuthMethod,
    ...(metadata.clientName === undefined ? {} : { clientName: metadata.clientName }),
    ...(metadata.scope === undefined ? {} : { scope: [...metadata.scope] }),
    clientIdIssuedAt: Math.floor(now() / 1000),
  };
}

/**
 * 201 応答ボディ（RFC 7591 §3.2.1。スネークケースの JSON オブジェクト）を
 * 組み立てる。§3.2.1 は「登録済みの全メタデータを返す MUST」なので、既定値
 * 適用後の値もすべて載せる。client_secret_expires_at は client_secret を
 * 発行した場合のみの REQUIRED で、0 は「無期限」を意味する。
 *
 * registration_access_token / registration_client_uri は返さない（RFC 7592 は
 * 非目標。OIDC Dynamic Client Registration 1.0 §3.2 の「両方返すか両方返さ
 * ないか」の MUST に従い、両方返さない側を選ぶ）。
 */
export function buildClientRegistrationResponse(
  client: DynamicallyRegisteredClient,
): Record<string, unknown> {
  return {
    client_id: client.clientId,
    ...(client.clientSecret === undefined
      ? {}
      : { client_secret: client.clientSecret, client_secret_expires_at: 0 }),
    client_id_issued_at: client.clientIdIssuedAt,
    redirect_uris: [...client.redirectUris],
    token_endpoint_auth_method: client.tokenEndpointAuthMethod,
    grant_types: [...client.grantTypes],
    response_types: [...client.responseTypes],
    ...(client.clientName === undefined ? {} : { client_name: client.clientName }),
    // scope は RFC 6749 §3.3 の表現（スペース区切り文字列）へ戻して返す。
    ...(client.scope === undefined ? {} : { scope: client.scope.join(' ') }),
  };
}
```

### initial-access-token.ts（initial access token の照合）

登録に事前資格を要求する構成のための照合関数である。
ヘッダは RFC 6750 §2.1 の形式（`Bearer` と b64token）で読み、スキーム名は RFC 9110 §11.1 のとおり大文字小文字を区別しない。
比較はこの呼び出し限りのランダム鍵で HMAC-SHA256 をかけて固定長ダイジェスト同士を XOR で比べる定数時間比較で、`===` のように一致した長さに応じて応答時間が変わることがない。

ヘッダが無い場合の扱い（エラーコード無しの 401）はここに無い。
ヘッダの有無を知るのは HTTP を受ける生成コードなので、分岐は生成ルートに置き、この関数は「提示された値が期待値と一致するか」だけに答える。

```typescript
/**
 * OAuth 2.0 Dynamic Client Registration (RFC 7591) — initial access token の照合。
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * RFC 7591 §3.1 はオープン登録（認可なし）を既定の推奨としつつ、登録に事前
 * 資格を要求する OP のために initial access token（OIDC Dynamic Client
 * Registration 1.0 §3）を定義する。本機能は生成コードの設定に置いた固定
 * 文字列 1 つとの照合だけを提供し、トークンの発行や複数トークンの管理は
 * 持たない（仕様書の非目標）。
 */

/**
 * Authorization ヘッダの Bearer トークンを期待値と定数時間比較する。
 *
 * ヘッダは RFC 6750 §2.1 の形式（`Bearer` 1 つの SP、b64token）で読む。
 * スキーム名は HTTP の認証スキームとして大文字小文字を区別しない
 * （RFC 9110 §11.1）。形式不正・Bearer 以外のスキーム・空トークンは
 * 不一致として false を返す。ヘッダが無い場合の扱い（エラーコード無しの
 * 401。RFC 6750 §3.1）はヘッダの有無を知る生成コード側の責務。
 *
 * 比較は Web Crypto の HMAC を使った定数時間比較（core 内部の
 * timingSafeEqual と同じ方式。core は同関数を公開していないため本機能内に
 * 持つ。experimental 機能間でコードの重複を許容する方針どおり）。期待
 * トークンの情報（長さ・部分一致）は返り値以外に漏れない。
 */
export async function verifyInitialAccessToken(
  authorizationHeader: string,
  expectedToken: string,
): Promise<boolean> {
  if (expectedToken === '') {
    return false;
  }
  const presented = parseBearerToken(authorizationHeader);
  if (presented === null) {
    return false;
  }
  return timingSafeEqual(presented, expectedToken);
}

/**
 * RFC 6750 §2.1: `credentials = "Bearer" 1*SP b64token`。
 * b64token は ALPHA / DIGIT / "-" / "." / "_" / "~" / "+" / "/" と末尾の "="。
 */
const BEARER_HEADER = /^Bearer +([A-Za-z0-9\-._~+/]+=*)$/i;

function parseBearerToken(authorizationHeader: string): string | null {
  const match = BEARER_HEADER.exec(authorizationHeader);
  return match ? (match[1] as string) : null;
}

/**
 * 2 つの文字列を constant-time で比較する（core の timingSafeEqual の複製）。
 *
 * 通常の `===` は先頭から一致した長さに応じて応答時間が変わるため、timing
 * attack で 1 文字ずつトークンを漸進的に推測される恐れがある。Web Crypto
 * には timingSafeEqual が無いので、この呼び出し限りのランダム鍵で
 * HMAC-SHA256 をかけ、固定長ダイジェスト同士を XOR ベースで比較する。
 */
async function timingSafeEqual(a: string, b: string): Promise<boolean> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.generateKey(
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const [sigA, sigB] = await Promise.all([
    crypto.subtle.sign('HMAC', key, encoder.encode(a)),
    crypto.subtle.sign('HMAC', key, encoder.encode(b)),
  ]);
  const bytesA = new Uint8Array(sigA);
  const bytesB = new Uint8Array(sigB);
  if (bytesA.length !== bytesB.length) {
    return false;
  }
  let diff = 0;
  for (let i = 0; i < bytesA.length; i++) {
    diff |= bytesA[i]! ^ bytesB[i]!;
  }
  return diff === 0;
}
```

### index.ts（公開 API）

subpath export `@maronn-openid-connect/experimental/dynamic-client-registration` の入口である。
モジュール冒頭のコメントで、Experimental であること、スコープ外（RFC 7592 ほか）、生成コードとの責務分担を宣言している。

```typescript
/**
 * OAuth 2.0 Dynamic Client Registration Protocol (RFC 7591) /
 * OpenID Connect Dynamic Client Registration 1.0 のサブセット
 *
 * **Experimental**: この機能の API は安定していない。マイナーリリースでも
 * 破壊的に変更されることがある。本番運用の前に
 * `docs/library-document` の Experimental セクションを確認すること。
 *
 * `@maronn-openid-connect/core` とは別 package であり、CLI で
 * `--enable dynamic-client-registration` を明示したときのみ生成コードから
 * 利用される。
 *
 * このモジュールは「登録メタデータの検証・既定値適用・登録レコードと 201
 * 応答の組み立て・initial access token の照合」だけを持つ純関数群で、HTTP
 * にもストアにも触れない。`redirect_uris` の検査規則と乱数生成は core 公開
 * API（validateRegisteredRedirectUris / generateRandomString）を使い、
 * クライアントの保存・総数上限・Content-Type 検査は生成コード側の責務の
 * まま変えない。
 *
 * スコープ外（非目標）: RFC 7592（登録後の参照・更新・削除、
 * registration_access_token / registration_client_uri はどちらも返さない）、
 * software_statement（未知フィールドとして無視）、initial access token の
 * 発行・管理、OIDC 固有メタデータ（jwks_uri など URL 参照系を含む）の解釈。
 */
export {
  ClientRegistrationError,
  validateClientRegistrationRequest,
  type ValidateClientRegistrationOptions,
  type ValidatedClientRegistration,
} from './registration-request.js';

export {
  buildRegisteredClient,
  buildClientRegistrationResponse,
  type BuildRegisteredClientOptions,
  type DynamicallyRegisteredClient,
} from './registered-client.js';

export { verifyInitialAccessToken } from './initial-access-token.js';
```

## 単体テストの全文

t_wada 式 TDD で、テストを先に書いてから実装した。
仕様書のテスト計画（正常系、異常系、境界値、プロトタイプ汚染、エラー文言の固定）をそのまま写した構成である。

### registration-request.test.ts

```typescript
import { describe, expect, it } from 'vitest';
import {
  ClientRegistrationError,
  validateClientRegistrationRequest,
} from './registration-request.js';

function body(metadata: Record<string, unknown>): string {
  return JSON.stringify(metadata);
}

const MINIMAL = { redirect_uris: ['https://app.example.com/cb'] };

describe('validateClientRegistrationRequest', () => {
  describe('defaults (RFC 7591 Section 2)', () => {
    it('should apply every default to a minimal registration', () => {
      const validated = validateClientRegistrationRequest(body(MINIMAL));
      expect(validated).toEqual({
        redirectUris: ['https://app.example.com/cb'],
        tokenEndpointAuthMethod: 'client_secret_basic',
        grantTypes: ['authorization_code'],
        responseTypes: ['code'],
      });
    });

    it('should keep every explicitly registered value', () => {
      const validated = validateClientRegistrationRequest(
        body({
          redirect_uris: ['https://app.example.com/cb', 'http://127.0.0.1:8080/cb'],
          token_endpoint_auth_method: 'client_secret_post',
          grant_types: ['authorization_code', 'refresh_token'],
          response_types: ['code'],
          client_name: 'My Test App',
        }),
      );
      expect(validated).toEqual({
        redirectUris: ['https://app.example.com/cb', 'http://127.0.0.1:8080/cb'],
        tokenEndpointAuthMethod: 'client_secret_post',
        grantTypes: ['authorization_code', 'refresh_token'],
        responseTypes: ['code'],
        clientName: 'My Test App',
      });
    });

    it('should normalize duplicated grant_types values to one entry', () => {
      const validated = validateClientRegistrationRequest(
        body({ ...MINIMAL, grant_types: ['authorization_code', 'authorization_code'] }),
      );
      expect(validated.grantTypes).toEqual(['authorization_code']);
    });
  });

  describe('unknown metadata (RFC 7591 Section 2 MUST ignore)', () => {
    it('should silently drop metadata this provider does not understand', () => {
      const validated = validateClientRegistrationRequest(
        body({
          ...MINIMAL,
          logo_uri: 'https://app.example.com/logo.png',
          jwks_uri: 'https://app.example.com/jwks.json',
          software_statement: 'eyJhbGciOiJSUzI1NiJ9.e30.sig',
        }),
      );
      expect(validated).toEqual({
        redirectUris: ['https://app.example.com/cb'],
        tokenEndpointAuthMethod: 'client_secret_basic',
        grantTypes: ['authorization_code'],
        responseTypes: ['code'],
      });
    });

    it('should drop __proto__ and constructor keys as unknown metadata without polluting the result', () => {
      const validated = validateClientRegistrationRequest(
        '{"redirect_uris":["https://app.example.com/cb"],"__proto__":{"polluted":true},"constructor":{"prototype":{"polluted":true}}}',
      );
      expect(validated).toEqual({
        redirectUris: ['https://app.example.com/cb'],
        tokenEndpointAuthMethod: 'client_secret_basic',
        grantTypes: ['authorization_code'],
        responseTypes: ['code'],
      });
      expect(Object.getPrototypeOf(validated)).toBe(Object.prototype);
      expect(({} as Record<string, unknown>)['polluted']).toBe(undefined);
    });
  });

  describe('request body shape', () => {
    it('should reject a body that is not valid JSON', () => {
      expect(() => validateClientRegistrationRequest('not json')).toThrowError(
        new ClientRegistrationError('invalid_client_metadata', 'request body must be valid JSON'),
      );
    });

    it('should reject a JSON array body', () => {
      expect(() => validateClientRegistrationRequest('[]')).toThrowError(
        new ClientRegistrationError('invalid_client_metadata', 'request body must be a JSON object'),
      );
    });

    it('should reject a JSON primitive body', () => {
      expect(() => validateClientRegistrationRequest('"redirect_uris"')).toThrowError(
        new ClientRegistrationError('invalid_client_metadata', 'request body must be a JSON object'),
      );
    });

    it('should reject a JSON null body', () => {
      expect(() => validateClientRegistrationRequest('null')).toThrowError(
        new ClientRegistrationError('invalid_client_metadata', 'request body must be a JSON object'),
      );
    });
  });

  describe('body size limit (UTF-8 bytes)', () => {
    // 多バイト文字を含むボディで、判定が文字数ではなくバイト長であることを固定する。
    // 'あ' は UTF-8 で 3 バイト。
    const base = '{"redirect_uris":["https://app.example.com/cb"],"client_name":"';
    const suffix = '"}';

    it('should accept a body exactly at the byte limit', () => {
      const fixedBytes = new TextEncoder().encode(base + suffix).length;
      const multiByteChars = 8;
      const limit = fixedBytes + multiByteChars * 3;
      const rawBody = base + 'あ'.repeat(multiByteChars) + suffix;
      expect(new TextEncoder().encode(rawBody).length).toBe(limit);
      const validated = validateClientRegistrationRequest(rawBody, { maxBodyBytes: limit });
      expect(validated.clientName).toBe('あ'.repeat(multiByteChars));
    });

    it('should reject a body one byte over the limit', () => {
      const fixedBytes = new TextEncoder().encode(base + suffix).length;
      const multiByteChars = 8;
      const limit = fixedBytes + multiByteChars * 3 - 1;
      const rawBody = base + 'あ'.repeat(multiByteChars) + suffix;
      expect(() => validateClientRegistrationRequest(rawBody, { maxBodyBytes: limit })).toThrowError(
        new ClientRegistrationError(
          'invalid_client_metadata',
          'request body must not exceed the configured maximum size',
        ),
      );
    });
  });

  describe('redirect_uris (OIDC Dynamic Client Registration 1.0 Section 2 REQUIRED)', () => {
    it('should reject a registration without redirect_uris', () => {
      expect(() => validateClientRegistrationRequest(body({}))).toThrowError(
        new ClientRegistrationError(
          'invalid_redirect_uri',
          'redirect_uris must be a non-empty array of strings',
        ),
      );
    });

    it('should reject an empty redirect_uris array', () => {
      expect(() =>
        validateClientRegistrationRequest(body({ redirect_uris: [] })),
      ).toThrowError(
        new ClientRegistrationError(
          'invalid_redirect_uri',
          'redirect_uris must be a non-empty array of strings',
        ),
      );
    });

    it('should reject a redirect_uris array with a non-string element', () => {
      expect(() =>
        validateClientRegistrationRequest(body({ redirect_uris: ['https://a.example', 1] })),
      ).toThrowError(
        new ClientRegistrationError(
          'invalid_redirect_uri',
          'redirect_uris must be a non-empty array of strings',
        ),
      );
    });

    it('should reject a redirect_uri with a fragment component', () => {
      expect(() =>
        validateClientRegistrationRequest(
          body({ redirect_uris: ['https://app.example.com/cb#fragment'] }),
        ),
      ).toThrowError(
        new ClientRegistrationError(
          'invalid_redirect_uri',
          'each redirect_uri must be an absolute URI without a fragment and must not use a dangerous scheme or non-loopback http',
        ),
      );
    });

    it('should reject a javascript: scheme redirect_uri', () => {
      expect(() =>
        validateClientRegistrationRequest(body({ redirect_uris: ['javascript:alert(1)'] })),
      ).toThrowError(
        new ClientRegistrationError(
          'invalid_redirect_uri',
          'each redirect_uri must be an absolute URI without a fragment and must not use a dangerous scheme or non-loopback http',
        ),
      );
    });

    it('should reject a non-loopback plain http redirect_uri', () => {
      expect(() =>
        validateClientRegistrationRequest(body({ redirect_uris: ['http://app.example.com/cb'] })),
      ).toThrowError(
        new ClientRegistrationError(
          'invalid_redirect_uri',
          'each redirect_uri must be an absolute URI without a fragment and must not use a dangerous scheme or non-loopback http',
        ),
      );
    });

    it('should not reflect the offending URI in error_description', () => {
      const secretUri = 'javascript:alert("secret-marker")';
      expect(() =>
        validateClientRegistrationRequest(body({ redirect_uris: [secretUri] })),
      ).toThrowError(
        new ClientRegistrationError(
          'invalid_redirect_uri',
          'each redirect_uri must be an absolute URI without a fragment and must not use a dangerous scheme or non-loopback http',
        ),
      );
    });

    it('should accept mixed loopback http and https redirect_uris', () => {
      const validated = validateClientRegistrationRequest(
        body({
          redirect_uris: [
            'http://localhost:3000/cb',
            'http://127.0.0.1/cb',
            'http://[::1]:8080/cb',
            'https://app.example.com/cb',
          ],
        }),
      );
      expect(validated.redirectUris).toEqual([
        'http://localhost:3000/cb',
        'http://127.0.0.1/cb',
        'http://[::1]:8080/cb',
        'https://app.example.com/cb',
      ]);
    });

    // RFC 8252 §7.1: native apps register private-use (custom) URI schemes.
    // The registration rule equals the static one (core
    // validateRegisteredRedirectUris), which accepts any scheme outside its
    // dangerous-scheme list.
    it('should accept a private-use scheme redirect_uri', () => {
      const validated = validateClientRegistrationRequest(
        body({ redirect_uris: ['com.example.app:/oauth2redirect'] }),
      );
      expect(validated.redirectUris).toEqual(['com.example.app:/oauth2redirect']);
    });
  });

  describe('token_endpoint_auth_method', () => {
    it('should accept none and keep it', () => {
      const validated = validateClientRegistrationRequest(
        body({ ...MINIMAL, token_endpoint_auth_method: 'none' }),
      );
      expect(validated.tokenEndpointAuthMethod).toBe('none');
    });

    it('should reject an unsupported method such as private_key_jwt', () => {
      expect(() =>
        validateClientRegistrationRequest(
          body({ ...MINIMAL, token_endpoint_auth_method: 'private_key_jwt' }),
        ),
      ).toThrowError(
        new ClientRegistrationError(
          'invalid_client_metadata',
          'token_endpoint_auth_method must be one of client_secret_basic, client_secret_post, none',
        ),
      );
    });

    it('should reject a non-string token_endpoint_auth_method', () => {
      expect(() =>
        validateClientRegistrationRequest(
          body({ ...MINIMAL, token_endpoint_auth_method: ['client_secret_basic'] }),
        ),
      ).toThrowError(
        new ClientRegistrationError(
          'invalid_client_metadata',
          'token_endpoint_auth_method must be one of client_secret_basic, client_secret_post, none',
        ),
      );
    });
  });

  describe('grant_types', () => {
    it('should reject a grant type outside authorization_code and refresh_token', () => {
      expect(() =>
        validateClientRegistrationRequest(
          body({
            ...MINIMAL,
            grant_types: ['authorization_code', 'urn:ietf:params:oauth:grant-type:token-exchange'],
          }),
        ),
      ).toThrowError(
        new ClientRegistrationError(
          'invalid_client_metadata',
          'grant_types must be an array containing only authorization_code and refresh_token',
        ),
      );
    });

    it('should reject a non-array grant_types', () => {
      expect(() =>
        validateClientRegistrationRequest(body({ ...MINIMAL, grant_types: 'authorization_code' })),
      ).toThrowError(
        new ClientRegistrationError(
          'invalid_client_metadata',
          'grant_types must be an array containing only authorization_code and refresh_token',
        ),
      );
    });

    it('should reject refresh_token without authorization_code (RFC 7591 Section 2.1 consistency)', () => {
      expect(() =>
        validateClientRegistrationRequest(body({ ...MINIMAL, grant_types: ['refresh_token'] })),
      ).toThrowError(
        new ClientRegistrationError(
          'invalid_client_metadata',
          'grant_types must include authorization_code',
        ),
      );
    });

    it('should reject an empty grant_types array', () => {
      expect(() =>
        validateClientRegistrationRequest(body({ ...MINIMAL, grant_types: [] })),
      ).toThrowError(
        new ClientRegistrationError(
          'invalid_client_metadata',
          'grant_types must include authorization_code',
        ),
      );
    });
  });

  describe('response_types', () => {
    it('should reject a response type other than code', () => {
      expect(() =>
        validateClientRegistrationRequest(body({ ...MINIMAL, response_types: ['token'] })),
      ).toThrowError(
        new ClientRegistrationError(
          'invalid_client_metadata',
          'response_types must be exactly ["code"]',
        ),
      );
    });

    it('should reject response_types with more than one entry', () => {
      expect(() =>
        validateClientRegistrationRequest(body({ ...MINIMAL, response_types: ['code', 'code'] })),
      ).toThrowError(
        new ClientRegistrationError(
          'invalid_client_metadata',
          'response_types must be exactly ["code"]',
        ),
      );
    });
  });

  // scope (RFC 7591 Section 2): space-delimited list of scope values the client
  // may use. Registered values become the client's per-client scope allow list.
  describe('scope', () => {
    it('should register the scope values from a space-delimited scope string', () => {
      const validated = validateClientRegistrationRequest(
        body({ ...MINIMAL, scope: 'openid profile' }),
      );
      expect(validated.scope).toEqual(['openid', 'profile']);
    });

    it('should omit the scope key when scope is not provided', () => {
      const validated = validateClientRegistrationRequest(body(MINIMAL));
      expect(Object.hasOwn(validated, 'scope')).toBe(false);
    });

    it('should reject a non-string scope with invalid_client_metadata', () => {
      expect(() =>
        validateClientRegistrationRequest(body({ ...MINIMAL, scope: ['openid'] })),
      ).toThrowError(
        new ClientRegistrationError('invalid_client_metadata', 'scope must be a string'),
      );
    });

    it('should reject an empty scope string with invalid_client_metadata', () => {
      expect(() =>
        validateClientRegistrationRequest(body({ ...MINIMAL, scope: '' })),
      ).toThrowError(
        new ClientRegistrationError(
          'invalid_client_metadata',
          'scope must be a space-delimited list of scope values',
        ),
      );
    });

    it('should reject a scope string with consecutive spaces with invalid_client_metadata', () => {
      // RFC 6749 §3.3: scope = scope-token *( SP scope-token ) — one SP between tokens.
      expect(() =>
        validateClientRegistrationRequest(body({ ...MINIMAL, scope: 'openid  profile' })),
      ).toThrowError(
        new ClientRegistrationError(
          'invalid_client_metadata',
          'scope must be a space-delimited list of scope values',
        ),
      );
    });

    it('should reject a scope value with a character outside the scope-token set', () => {
      // RFC 6749 §3.3: scope-token = 1*( %x21 / %x23-5B / %x5D-7E ) — no '"' or '\'.
      expect(() =>
        validateClientRegistrationRequest(body({ ...MINIMAL, scope: 'open"id' })),
      ).toThrowError(
        new ClientRegistrationError(
          'invalid_client_metadata',
          'scope must be a space-delimited list of scope values',
        ),
      );
    });

    it('should reject a scope value outside supportedScopes with invalid_client_metadata', () => {
      expect(() =>
        validateClientRegistrationRequest(body({ ...MINIMAL, scope: 'openid reports.read' }), {
          supportedScopes: ['openid', 'profile'],
        }),
      ).toThrowError(
        new ClientRegistrationError(
          'invalid_client_metadata',
          'scope must only contain scope values this provider supports',
        ),
      );
    });

    it('should accept any syntactically valid scope when supportedScopes is not provided', () => {
      const validated = validateClientRegistrationRequest(
        body({ ...MINIMAL, scope: 'reports.read reports.write' }),
      );
      expect(validated.scope).toEqual(['reports.read', 'reports.write']);
    });

    it('should deduplicate repeated scope values', () => {
      const validated = validateClientRegistrationRequest(
        body({ ...MINIMAL, scope: 'openid openid profile' }),
      );
      expect(validated.scope).toEqual(['openid', 'profile']);
    });
  });

  describe('client_name', () => {
    it('should accept a client_name of exactly 128 characters', () => {
      const name = 'a'.repeat(128);
      const validated = validateClientRegistrationRequest(
        body({ ...MINIMAL, client_name: name }),
      );
      expect(validated.clientName).toBe(name);
    });

    it('should reject a client_name of 129 characters', () => {
      expect(() =>
        validateClientRegistrationRequest(body({ ...MINIMAL, client_name: 'a'.repeat(129) })),
      ).toThrowError(
        new ClientRegistrationError(
          'invalid_client_metadata',
          'client_name must be at most 128 characters',
        ),
      );
    });

    it('should reject a non-string client_name', () => {
      expect(() =>
        validateClientRegistrationRequest(body({ ...MINIMAL, client_name: 42 })),
      ).toThrowError(
        new ClientRegistrationError('invalid_client_metadata', 'client_name must be a string'),
      );
    });

    it('should reject a client_name containing a control character', () => {
      expect(() =>
        validateClientRegistrationRequest(body({ ...MINIMAL, client_name: 'bad\nname' })),
      ).toThrowError(
        new ClientRegistrationError(
          'invalid_client_metadata',
          'client_name must not contain control or invisible formatting characters',
        ),
      );
    });

    it('should reject a client_name containing a C1 control character', () => {
      expect(() =>
        validateClientRegistrationRequest(body({ ...MINIMAL, client_name: 'bad\u0085name' })),
      ).toThrowError(
        new ClientRegistrationError(
          'invalid_client_metadata',
          'client_name must not contain control or invisible formatting characters',
        ),
      );
    });

    // U+202E (RIGHT-TO-LEFT OVERRIDE) can reverse the rendered order of a
    // display name and disguise what the user approves.
    it('should reject a client_name containing a bidi override character', () => {
      expect(() =>
        validateClientRegistrationRequest(body({ ...MINIMAL, client_name: 'bad\u202ename' })),
      ).toThrowError(
        new ClientRegistrationError(
          'invalid_client_metadata',
          'client_name must not contain control or invisible formatting characters',
        ),
      );
    });

    it('should reject a client_name containing a zero-width character', () => {
      expect(() =>
        validateClientRegistrationRequest(body({ ...MINIMAL, client_name: 'bad\u200bname' })),
      ).toThrowError(
        new ClientRegistrationError(
          'invalid_client_metadata',
          'client_name must not contain control or invisible formatting characters',
        ),
      );
    });
  });
});

describe('ClientRegistrationError', () => {
  it('should carry the RFC 7591 error code and description as properties', () => {
    const error = new ClientRegistrationError('invalid_redirect_uri', 'fixed description');
    expect(error.error).toBe('invalid_redirect_uri');
    expect(error.errorDescription).toBe('fixed description');
    expect(error.message).toBe('fixed description');
    expect(error.name).toBe('ClientRegistrationError');
  });
});
```

### registered-client.test.ts

```typescript
import { describe, expect, it } from 'vitest';
import {
  buildClientRegistrationResponse,
  buildRegisteredClient,
} from './registered-client.js';
import type { ValidatedClientRegistration } from './registration-request.js';

const CONFIDENTIAL: ValidatedClientRegistration = {
  redirectUris: ['https://app.example.com/cb'],
  tokenEndpointAuthMethod: 'client_secret_basic',
  grantTypes: ['authorization_code'],
  responseTypes: ['code'],
};

const PUBLIC: ValidatedClientRegistration = {
  redirectUris: ['https://app.example.com/cb'],
  tokenEndpointAuthMethod: 'none',
  grantTypes: ['authorization_code'],
  responseTypes: ['code'],
};

describe('buildRegisteredClient', () => {
  describe('issued values', () => {
    it('should mint a client_id with the dcr- prefix and a 22-character random part', () => {
      const client = buildRegisteredClient(CONFIDENTIAL);
      // 16 バイトの base64url は 22 文字（パディング無し）。
      expect(client.clientId).toMatch(/^dcr-[A-Za-z0-9_-]{22}$/);
    });

    it('should mint a 43-character base64url client_secret for a confidential client', () => {
      const client = buildRegisteredClient(CONFIDENTIAL);
      // 32 バイト（256 ビット）の base64url は 43 文字（パディング無し）。
      expect(client.clientSecret).toMatch(/^[A-Za-z0-9_-]{43}$/);
      expect(client.clientType).toBe('confidential');
    });

    it('should mint a different client_id and client_secret on every call', () => {
      const first = buildRegisteredClient(CONFIDENTIAL);
      const second = buildRegisteredClient(CONFIDENTIAL);
      expect(first.clientId).not.toBe(second.clientId);
      expect(first.clientSecret).not.toBe(second.clientSecret);
    });

    it('should use the injected generators and clock', () => {
      const client = buildRegisteredClient(CONFIDENTIAL, {
        generateClientId: () => 'dcr-fixed',
        generateClientSecret: () => 'fixed-secret',
        now: () => 1_790_812_800_123,
      });
      expect(client).toEqual({
        clientId: 'dcr-fixed',
        clientSecret: 'fixed-secret',
        clientType: 'confidential',
        redirectUris: ['https://app.example.com/cb'],
        grantTypes: ['authorization_code'],
        responseTypes: ['code'],
        tokenEndpointAuthMethod: 'client_secret_basic',
        clientIdIssuedAt: 1_790_812_800,
      });
    });
  });

  describe('public clients (token_endpoint_auth_method none)', () => {
    it('should mark the client public and issue no client_secret', () => {
      const client = buildRegisteredClient(PUBLIC, {
        generateClientId: () => 'dcr-public',
        now: () => 1_790_812_800_000,
      });
      expect(client).toEqual({
        clientId: 'dcr-public',
        clientType: 'public',
        redirectUris: ['https://app.example.com/cb'],
        grantTypes: ['authorization_code'],
        responseTypes: ['code'],
        tokenEndpointAuthMethod: 'none',
        clientIdIssuedAt: 1_790_812_800,
      });
      expect(Object.hasOwn(client, 'clientSecret')).toBe(false);
    });
  });

  describe('metadata copy', () => {
    it('should copy the metadata arrays instead of sharing them', () => {
      const metadata: ValidatedClientRegistration = {
        ...CONFIDENTIAL,
        redirectUris: ['https://app.example.com/cb'],
      };
      const client = buildRegisteredClient(metadata);
      metadata.redirectUris.push('https://evil.example.com/cb');
      expect(client.redirectUris).toEqual(['https://app.example.com/cb']);
    });

    it('should keep the registered client_name', () => {
      const client = buildRegisteredClient(
        { ...CONFIDENTIAL, clientName: 'My Test App' },
        { generateClientId: () => 'dcr-x', generateClientSecret: () => 's', now: () => 0 },
      );
      expect(client.clientName).toBe('My Test App');
    });

    // scope (RFC 7591 Section 2): the registered per-client scope allow list.
    it('should carry the registered scope values into the client record', () => {
      const client = buildRegisteredClient(
        { ...CONFIDENTIAL, scope: ['openid', 'profile'] },
        { generateClientId: () => 'dcr-x', generateClientSecret: () => 's', now: () => 0 },
      );
      expect(client.scope).toEqual(['openid', 'profile']);
    });

    it('should omit the scope key from the client record when none was registered', () => {
      const client = buildRegisteredClient(CONFIDENTIAL);
      expect(Object.hasOwn(client, 'scope')).toBe(false);
    });

    it('should copy the scope array instead of sharing it', () => {
      const metadata: ValidatedClientRegistration = {
        ...CONFIDENTIAL,
        scope: ['openid'],
      };
      const client = buildRegisteredClient(metadata);
      metadata.scope!.push('profile');
      expect(client.scope).toEqual(['openid']);
    });
  });
});

describe('buildClientRegistrationResponse', () => {
  it('should return the issued values and all registered metadata for a confidential client (RFC 7591 Section 3.2.1)', () => {
    const response = buildClientRegistrationResponse({
      clientId: 'dcr-fixed',
      clientSecret: 'fixed-secret',
      clientType: 'confidential',
      redirectUris: ['https://app.example.com/cb'],
      grantTypes: ['authorization_code'],
      responseTypes: ['code'],
      tokenEndpointAuthMethod: 'client_secret_basic',
      clientName: 'My Test App',
      clientIdIssuedAt: 1_790_812_800,
    });
    expect(response).toEqual({
      client_id: 'dcr-fixed',
      client_secret: 'fixed-secret',
      // 0 は「無期限」（RFC 7591 §3.2.1）。即時失効ではない。
      client_secret_expires_at: 0,
      client_id_issued_at: 1_790_812_800,
      redirect_uris: ['https://app.example.com/cb'],
      token_endpoint_auth_method: 'client_secret_basic',
      grant_types: ['authorization_code'],
      response_types: ['code'],
      client_name: 'My Test App',
    });
  });

  it('should omit client_secret and client_secret_expires_at for a public client', () => {
    const response = buildClientRegistrationResponse({
      clientId: 'dcr-public',
      clientType: 'public',
      redirectUris: ['https://app.example.com/cb'],
      grantTypes: ['authorization_code'],
      responseTypes: ['code'],
      tokenEndpointAuthMethod: 'none',
      clientIdIssuedAt: 1_790_812_800,
    });
    expect(response).toEqual({
      client_id: 'dcr-public',
      client_id_issued_at: 1_790_812_800,
      redirect_uris: ['https://app.example.com/cb'],
      token_endpoint_auth_method: 'none',
      grant_types: ['authorization_code'],
      response_types: ['code'],
    });
    expect(Object.hasOwn(response, 'client_secret')).toBe(false);
    expect(Object.hasOwn(response, 'client_secret_expires_at')).toBe(false);
  });

  // RFC 7591 §3.2.1: the response carries all registered metadata, so a
  // registered scope list comes back as the space-delimited `scope` string.
  it('should include scope as a space-delimited string in the registration response when registered', () => {
    const response = buildClientRegistrationResponse({
      clientId: 'dcr-fixed',
      clientSecret: 'fixed-secret',
      clientType: 'confidential',
      redirectUris: ['https://app.example.com/cb'],
      grantTypes: ['authorization_code'],
      responseTypes: ['code'],
      tokenEndpointAuthMethod: 'client_secret_basic',
      scope: ['openid', 'profile'],
      clientIdIssuedAt: 1_790_812_800,
    });
    expect(response).toEqual({
      client_id: 'dcr-fixed',
      client_secret: 'fixed-secret',
      client_secret_expires_at: 0,
      client_id_issued_at: 1_790_812_800,
      redirect_uris: ['https://app.example.com/cb'],
      token_endpoint_auth_method: 'client_secret_basic',
      grant_types: ['authorization_code'],
      response_types: ['code'],
      scope: 'openid profile',
    });
  });

  it('should omit scope from the registration response when not registered', () => {
    const response = buildClientRegistrationResponse({
      clientId: 'dcr-x',
      clientSecret: 's',
      clientType: 'confidential',
      redirectUris: ['https://app.example.com/cb'],
      grantTypes: ['authorization_code'],
      responseTypes: ['code'],
      tokenEndpointAuthMethod: 'client_secret_basic',
      clientIdIssuedAt: 0,
    });
    expect(Object.hasOwn(response, 'scope')).toBe(false);
  });

  it('should omit client_name when none was registered', () => {
    const response = buildClientRegistrationResponse({
      clientId: 'dcr-x',
      clientSecret: 's',
      clientType: 'confidential',
      redirectUris: ['https://app.example.com/cb'],
      grantTypes: ['authorization_code'],
      responseTypes: ['code'],
      tokenEndpointAuthMethod: 'client_secret_basic',
      clientIdIssuedAt: 0,
    });
    expect(Object.hasOwn(response, 'client_name')).toBe(false);
  });
});
```

### initial-access-token.test.ts

```typescript
import { describe, expect, it } from 'vitest';
import { verifyInitialAccessToken } from './initial-access-token.js';

const EXPECTED = 'conformance-suite-token-1';

describe('verifyInitialAccessToken', () => {
  describe('matching', () => {
    it('should accept the expected token', async () => {
      await expect(verifyInitialAccessToken(`Bearer ${EXPECTED}`, EXPECTED)).resolves.toBe(true);
    });

    it('should reject a different token', async () => {
      await expect(verifyInitialAccessToken('Bearer wrong-token', EXPECTED)).resolves.toBe(false);
    });

    it('should reject a token that is a prefix of the expected one', async () => {
      await expect(
        verifyInitialAccessToken('Bearer conformance-suite-token-', EXPECTED),
      ).resolves.toBe(false);
    });

    it('should reject a token that extends the expected one', async () => {
      await expect(
        verifyInitialAccessToken(`Bearer ${EXPECTED}1`, EXPECTED),
      ).resolves.toBe(false);
    });
  });

  describe('header shape (RFC 6750 Section 2.1)', () => {
    it('should accept a lowercase bearer scheme (RFC 9110 Section 11.1 case-insensitivity)', async () => {
      await expect(verifyInitialAccessToken(`bearer ${EXPECTED}`, EXPECTED)).resolves.toBe(true);
    });

    it('should accept multiple spaces between scheme and token', async () => {
      await expect(verifyInitialAccessToken(`Bearer   ${EXPECTED}`, EXPECTED)).resolves.toBe(true);
    });

    it('should reject a Basic scheme header', async () => {
      await expect(
        verifyInitialAccessToken('Basic dXNlcjpwYXNz', EXPECTED),
      ).resolves.toBe(false);
    });

    it('should reject a Bearer header without a token', async () => {
      await expect(verifyInitialAccessToken('Bearer ', EXPECTED)).resolves.toBe(false);
    });

    it('should reject an empty header value', async () => {
      await expect(verifyInitialAccessToken('', EXPECTED)).resolves.toBe(false);
    });

    it('should reject a token with characters outside b64token', async () => {
      await expect(verifyInitialAccessToken('Bearer bad token', EXPECTED)).resolves.toBe(false);
    });
  });

  describe('configuration guard', () => {
    it('should reject everything when the expected token is empty', async () => {
      await expect(verifyInitialAccessToken('Bearer ', '')).resolves.toBe(false);
      await expect(verifyInitialAccessToken('Bearer x', '')).resolves.toBe(false);
    });
  });
});
```

## CLI 統合と生成コードへの寄与

`packages/cli/src/features.ts` の `EXPERIMENTAL_FEATURES` 末尾に `dynamic-client-registration` を追加した。
既定では無効で、`--enable dynamic-client-registration` を付けたときだけ以下のコードが生成される。
未指定時の生成物はバイト同一である（各 sample の `check:generated` で固定）。

```typescript
export const EXPERIMENTAL_FEATURES = [
  'par',
  'token-exchange',
  'jarm',
  'device-authorization-grant',
  'id-jag',
  'ciba',
  'jwt-introspection-response',
  'rp-initiated-logout',
  'dynamic-client-registration',
] as const;
```

`packages/cli/src/index.ts` の `withExperimentalPackage` と setup コマンドの案内にも feature チェックを足し、選択時だけ install コマンドへ `@maronn-openid-connect/experimental` が入る。

### routes/register.ts（新規ファイル全文）

登録エンドポイントの本体である。
検証は「initial access token → Content-Type → Content-Length の事前検査 → 純関数（ボディ長・形式・値・既定値）→ 上限 → 保存（client_secret はハッシュ化して保存し、保存後に上限を再検査する）」の順で、最初に失敗した段階のエラーを返す。
initial access token はボディを読む前に検査し、資格の無いリクエストにボディの解釈を一切与えない。
`Content-Type` の検査は RFC 7591 §3.1 への適合に加え、CORS プリフライトが発生しない `text/plain` のクロスオリジン POST で JSON 形のボディを合成する手口を閉じる。

設定オブジェクト `dynamicClientRegistrationConfig` はこのファイルが持ち、apply.ts が `applyOidc` のオプションをこの既定へマージする。
Token Exchange の `tokenExchangeConfig` と同じ「experimental 機能専用の設定を生成コードに置く」パターンである。

検証の呼び出しには、`--scope` でカスタムスコープを宣言した構成でだけ `supportedScopes: SUPPORTED_SCOPES`（`../scopes.js` から import）が渡る。
デバイス認可ルートの `findUnsupportedScopes` と同じ条件付き生成の形で、掲載したのは宣言なしの hono サンプルの生成結果なので、このオプションは現れない。

```typescript
/**
 * EXPERIMENTAL — Dynamic Client Registration (RFC 7591).
 *
 * This route was generated because the OP was created with
 * `--enable dynamic-client-registration`. It is backed by
 * @maronn-openid-connect/experimental, whose API is NOT stable: it may change in a breaking
 * way between releases. Do not build production code on it without pinning the
 * version.
 *
 * The client POSTs its metadata here as JSON and receives a freshly minted
 * client_id (and, for confidential clients, a client_secret) that works on
 * /authorize and /token right away. Registration is open by default
 * (RFC 7591 §3.1 SHOULD); set initialAccessToken to require a Bearer token.
 */
import { Hono } from 'hono';
import { hashClientSecret } from '@maronn-openid-connect/core';
import {
  ClientRegistrationError,
  buildClientRegistrationResponse,
  buildRegisteredClient,
  validateClientRegistrationRequest,
  verifyInitialAccessToken,
} from '@maronn-openid-connect/experimental/dynamic-client-registration';
import { dynamicClientStore as defaultDynamicClientStore } from '../store.js';

/**
 * Dynamic client registration settings. apply.ts merges the applyOidc option
 * override over these defaults, so change them here or per deployment there.
 *
 * - initialAccessToken: when set, POST /register requires
 *   `Authorization: Bearer <value>` (OIDC Dynamic Client Registration 1.0 §3).
 *   Unset means open registration (RFC 7591 §3.1 SHOULD). This is one static
 *   secret for PoC use — there is no issuance or rotation.
 * - maxRegisteredClients: inventory cap on dynamic registrations
 *   (RFC 7591 §5 DoS consideration). The cap answers 429, not
 *   invalid_client_metadata: nothing about the metadata is wrong, so a
 *   metadata-retry loop must not be invited.
 * - maxRegistrationBodyBytes: request body limit in UTF-8 bytes.
 */
export const dynamicClientRegistrationConfig = {
  initialAccessToken: undefined as string | undefined,
  maxRegisteredClients: 100,
  maxRegistrationBodyBytes: 16384,
};

export const registerApp = new Hono<{ Variables: Record<string, any> }>();

/**
 * RFC 7591 §3.1: the registration request body MUST be application/json.
 * Enforcing the media type also closes the cross-origin text/plain form post
 * that can synthesize a JSON-shaped body without a CORS preflight.
 */
function isJson(contentType: string): boolean {
  const [mediaType = ''] = contentType.toLowerCase().split(';');
  return mediaType.trim() === 'application/json';
}

/**
 * Client Registration Endpoint
 * RFC 7591 §3
 *
 * NOTE (RFC 7591 §5): per-IP rate limiting is deliberately left to the
 * deployment layer (reverse proxy / platform); this endpoint only enforces the
 * inventory and body-size caps above. Open registration grants no trust: what
 * an issued client can do stays bounded by the same validation as a static
 * client (PKCE, exact redirect_uri match, client authentication).
 */
registerApp.post('/', async (c) => {
  // The 201 body carries the client_secret, so it must never be cached.
  c.header('Cache-Control', 'no-store');
  c.header('Pragma', 'no-cache');

  const config = c.get('dynamicClientRegistrationConfig') ?? dynamicClientRegistrationConfig;
  const store = c.get('dynamicClientStore') ?? defaultDynamicClientStore;

  // (1) Initial access token, checked before the body is read. The two 401
  // shapes follow RFC 6750 §3.1: no error code without credentials, and
  // error="invalid_token" for presented-but-wrong ones. Neither reflects
  // anything about the expected token.
  if (config.initialAccessToken !== undefined) {
    const authorization = c.req.header('Authorization');
    if (authorization === undefined) {
      c.header('WWW-Authenticate', 'Bearer');
      return c.body(null, 401);
    }
    const accepted = await verifyInitialAccessToken(authorization, config.initialAccessToken);
    if (!accepted) {
      c.header('WWW-Authenticate', 'Bearer error="invalid_token"');
      return c.body(null, 401);
    }
  }

  // (2) RFC 7591 §3.1: application/json only (parameters such as charset are fine).
  if (!isJson(c.req.header('Content-Type') ?? '')) {
    return c.json(
      { error: 'invalid_client_metadata', error_description: 'registration requests must use application/json' },
      400,
    );
  }

  // A Content-Length that already declares more than maxRegistrationBodyBytes
  // is refused before the body is read, so an oversized request is not
  // buffered first. The header can lie, so the authoritative check stays the
  // UTF-8 byte count on the body itself (validateClientRegistrationRequest).
  const declaredLength = Number(c.req.header('Content-Length') ?? '0');
  if (Number.isFinite(declaredLength) && declaredLength > config.maxRegistrationBodyBytes) {
    return c.json(
      { error: 'invalid_client_metadata', error_description: 'request body must not exceed the configured maximum size' },
      400,
    );
  }

  try {
    // The body read sits inside the try so that an aborted or malformed
    // transfer still gets the fixed server_error JSON with no-store instead of
    // the framework's default 500.
    const rawBody = await c.req.text();

    // (3)–(8) Body size, JSON shape, allowlist-pick of the understood fields,
    // value checks and RFC 7591 §2 defaults — pure functions from
    // @maronn-openid-connect/experimental/dynamic-client-registration. Unknown metadata is
    // silently ignored (§2 MUST), and every error_description is a fixed ASCII
    // string that never reflects request values. A registered `scope`
    // (RFC 7591 §2) becomes the client's per-client allow list: requests for
    // any other scope fail with invalid_scope, like a static client's.
    const metadata = validateClientRegistrationRequest(rawBody, {
      maxBodyBytes: config.maxRegistrationBodyBytes,
    });
    const client = buildRegisteredClient(metadata);

    // (9) Inventory cap (RFC 7591 §5). 429 with a fixed body: the metadata is
    // fine, so answering invalid_client_metadata would invite a retry loop that
    // amplifies the very DoS surface the cap is here to close. No Retry-After —
    // the cap is a stock ceiling, not a rate, so no recovery time is promised.
    if ((await store.count()) >= config.maxRegisteredClients) {
      return c.json(
        { error: 'too_many_registrations', error_description: 'registration limit reached' },
        429,
      );
    }
    // The stored record keeps the client_secret only as its hash, like the
    // statically registered clients: the 201 response below is built from the
    // in-memory record, so the plaintext never needs to rest in the store.
    const { clientSecret, ...registration } = client;
    await store.save({
      ...registration,
      ...(clientSecret === undefined ? {} : { clientSecretHash: await hashClientSecret(clientSecret) }),
    });
    // Concurrent requests can pass the cap check together (the awaits above let
    // them interleave), so re-check after saving and withdraw this registration
    // when the save overshot the cap: the cap is never exceeded, only approached.
    if ((await store.count()) > config.maxRegisteredClients) {
      await store.delete(client.clientId);
      return c.json(
        { error: 'too_many_registrations', error_description: 'registration limit reached' },
        429,
      );
    }

    // Never log the registration metadata or the issued client_secret.

    // RFC 7591 §3.2.1: 201 Created with the issued values and every registered
    // metadata value (defaults applied). client_secret_expires_at: 0 means the
    // secret does not expire.
    return c.json(buildClientRegistrationResponse(client), 201);
  } catch (error) {
    if (error instanceof ClientRegistrationError) {
      // RFC 7591 §3.2.2: 400 with error / error_description JSON.
      return c.json({ error: error.error, error_description: error.errorDescription }, 400);
    }
    return c.json({ error: 'server_error' }, 500);
  }
});
```

### store.ts に入るコード

ファイル先頭の型 import に次の 1 行が加わる。

```typescript
import type { RegisteredClient } from './config.js';
```

末尾には、ストア契約・in-memory 実装・globalThis シングルトン・resolver 合成が加わる。
ストア契約は `get` / `save` / `count` / `delete` の 4 メソッドで、`count` は総数上限（RFC 7591 §5 の DoS 考慮）の検査に、`delete` は並行リクエストが上限を越えて保存してしまったときに自分の登録を取り下げる再検査に使う。
`withDynamicallyRegisteredClients` は generic で基底 resolver の型をそのまま保つ。
生成コードのクライアント resolver は `ClientResolver` と `TokenClientResolver` の両方を一つの値で担うことがあり、型を潰すと Next.js のように resolver を型付きで公開する生成物がコンパイルできなくなるためである。

```typescript
/**
 * EXPERIMENTAL — store contract for dynamically registered clients (RFC 7591).
 *
 * - get(clientId): return the registered client, or undefined when unknown.
 * - save(client): persist the registration under client.clientId.
 * - count(): how many dynamic registrations exist, for the
 *   maxRegisteredClients inventory cap (RFC 7591 §5 DoS consideration).
 * - delete(clientId): remove one registration — the register endpoint
 *   withdraws its own save when concurrent requests overshot the cap.
 */
export interface DynamicallyRegisteredClientStore {
  get(clientId: string): Promise<RegisteredClient | undefined>;
  save(client: RegisteredClient): Promise<void>;
  count(): Promise<number>;
}

/**
 * EXPERIMENTAL — in-memory store for dynamically registered clients (RFC 7591).
 *
 * Dynamic registrations live only in this process: they survive neither a
 * restart nor a second instance (the statically registered clients do), so a
 * long-running deployment needs a persistent implementation of the contract
 * above. There is no expiry: RFC 7592 (deregistration) is not implemented, so
 * the inventory cap and a restart are the only ways a registration goes away.
 */
export class InMemoryDynamicallyRegisteredClientStore
  implements DynamicallyRegisteredClientStore
{
  private clients = new Map<string, RegisteredClient>();

  async get(clientId: string): Promise<RegisteredClient | undefined> {
    return this.clients.get(clientId);
  }

  async save(client: RegisteredClient): Promise<void> {
    this.clients.set(client.clientId, client);
  }

  async count(): Promise<number> {
    return this.clients.size;
  }
}

// Kept on globalThis for the same reason as the provider stores above: Next.js
// instantiates route handlers and server actions in separate module layers.
const dynamicClientStoreRegistry = globalThis as typeof globalThis & {
  __oidcDynamicallyRegisteredClientStore?: DynamicallyRegisteredClientStore;
};

export const dynamicClientStore: DynamicallyRegisteredClientStore =
  (dynamicClientStoreRegistry.__oidcDynamicallyRegisteredClientStore ??=
    new InMemoryDynamicallyRegisteredClientStore());

/**
 * EXPERIMENTAL — consult the dynamically registered clients (RFC 7591) after
 * the configured resolver, so a statically registered client can never be
 * shadowed by a dynamic registration (ids minted at /register carry the dcr-
 * prefix and cannot collide with human-named static ids anyway).
 *
 * The wrapper keeps the base resolver's own type: a value serving as both
 * ClientResolver and TokenClientResolver stays usable as both, and the
 * RegisteredClient records the store adds satisfy either view.
 */
export function withDynamicallyRegisteredClients<
  Resolver extends { findClient(clientId: string): Promise<any> },
>(base: Resolver): Resolver {
  return {
    ...base,
    async findClient(clientId: string): Promise<RegisteredClient | null> {
      const registered = (await base.findClient(clientId)) as RegisteredClient | null;
      if (registered) {
        return registered;
      }
      return (await dynamicClientStore.get(clientId)) ?? null;
    },
  } as Resolver;
}
```

### apply.ts / app.ts に入るコード

クライアント解決の合成は、リクエストごとの依存注入ミドルウェアで基底 resolver を包む形で入る（`--db sql` の生成例）。

```typescript
// EXPERIMENTAL (RFC 7591): dynamically registered clients resolve after the
// configured clients, so a static registration always wins.
const clientResolver = withDynamicallyRegisteredClients(
  options.clientResolver ?? createSqlClientResolver(createDatabase(c)),
);
```

トークンエンドポイント用の resolver も同じ合成を受け、設定と動的ストアがコンテキストへ載る。

```typescript
c.set('tokenClientResolver', options.tokenClientResolver
  ? withDynamicallyRegisteredClients(options.tokenClientResolver)
  : clientResolver);
// ...
c.set('dynamicClientStore', dynamicClientStore);
c.set('dynamicClientRegistrationConfig', { ...dynamicClientRegistrationConfig, ...options.dynamicClientRegistration });
```

`ApplyOidcOptions`（Hono）/ `OidcProviderOptions`（web-standard）にはデプロイごとの上書き口が加わる。
sample の手書き `app.ts` が環境変数を読んでここへ渡す配線は後述する。

```typescript
/**
 * EXPERIMENTAL (RFC 7591): override the generated dynamic client registration
 * settings (routes/register.ts) per deployment — for example from environment
 * variables — without editing the generated file. Unset fields keep the
 * generated defaults.
 */
dynamicClientRegistration?: {
  initialAccessToken?: string;
  maxRegisteredClients?: number;
  maxRegistrationBodyBytes?: number;
};
```

ルートのマウントは他のバックチャネル系エンドポイントと同じで、`/register` には `/token` と同じ CORS ポリシーが掛かる。

```typescript
import { registerApp, dynamicClientRegistrationConfig } from './routes/register.js';
// ...
app.use('/register', protectedCors);
// ...
app.route('/register', registerApp);
```

メソッド制限の表には `/register` が POST 専用として加わる。

```typescript
const OIDC_ENDPOINT_METHODS: Readonly<Record<string, readonly string[]>> = {
  // ...
  '/register': ['POST'],
  // ...
};
```

### routes/discovery.ts に入るコード

`buildProviderMetadata` の引数に `registrationEndpoint` が条件付きで加わる。
実装済みの他機能が使うスプレッドマージではなく core の既存フィールドを使う理由は、設計方針の節で述べたとおりである。

```typescript
const metadata = buildProviderMetadata({
  // ...
  // EXPERIMENTAL — OIDC Discovery 1.0 §3: the client registration endpoint
  // (RFC 7591) is advertised only because this OP was generated with
  // --enable dynamic-client-registration.
  registrationEndpoint: `${issuer}/register`,
});
```

### 他フレームワークの生成結果

- **web-standard（Express / Fastify が共有）**: hono のルートテンプレートを `WebRouter` 向けに変換して同じ `routes/register.ts` を生成する。Express は `OIDC_ENDPOINTS` へ、Fastify はルート登録へ `/register` が加わる
- **Next.js（App Router）**: `register/route.ts`（Route Handler）と `register/config.ts`（設定）を生成する。処理の並びは hono 版と同一で、ストアと resolver 合成は `_oidc-provider/provider.ts` が `export const clientResolver = withDynamicallyRegisteredClients(...)` の形で受ける

### サンプルと E2E の配線

全機能有効の `samples/hono-cloudflare` と、`--db sql` の web-standard 経路を代表する `samples/express-flyio` の generate スクリプトへ `--enable dynamic-client-registration` を追加した。
両 sample の手書き `app.ts` には、E2E が制限付き構成（initial access token と小さい上限）を注入するための環境変数の配線を足した（`XAA_ALLOWED_AUDIENCES` と同じ型の配線である）。

```typescript
// EXPERIMENTAL (RFC 7591): the E2E suite starts a second instance of this
// sample with an initial access token and a small inventory cap, so the
// restricted-registration paths (401 / 429) can be exercised over real HTTP.
// With the vars unset the generated defaults stay: open registration, cap 100.
const dynamicClientRegistration = {
  ...(bindings.OIDC_DCR_INITIAL_ACCESS_TOKEN
    ? { initialAccessToken: bindings.OIDC_DCR_INITIAL_ACCESS_TOKEN }
    : {}),
  ...(bindings.OIDC_DCR_MAX_CLIENTS
    ? { maxRegisteredClients: Number(bindings.OIDC_DCR_MAX_CLIENTS) }
    : {}),
};
```

E2E の `playwright.config.ts` は、オープン登録の本体インスタンスとは別に、制限付き構成の 3 つ目の OP インスタンスを起動する。
オープン登録の検証と initial access token の検証は同じ OP では両立しないためである。

```typescript
// EXPERIMENTAL (RFC 7591): the restricted-registration OP instance. It
// requires the initial access token below on POST /register and caps the
// dynamic registrations at 3, so the 401 and 429 paths of the
// dynamic-client-registration spec run against real HTTP. The values are
// mirrored as constants in specs/dynamic-client-registration.spec.ts.
...(startDcrOp
  ? [
      {
        command: `pnpm --filter ${opPackage} start`,
        url: `${dcrIssuer}/.well-known/openid-configuration`,
        reuseExistingServer: !process.env.CI,
        timeout: 30_000,
        env: {
          HOST: host,
          PORT: String(dcrOpPort),
          ISSUER: dcrIssuer,
          OIDC_SIGNING_KEY_ID: 'e2e-dcr-rs256-key',
          OIDC_DCR_INITIAL_ACCESS_TOKEN: 'e2e-dcr-initial-access-token',
          OIDC_DCR_MAX_CLIENTS: '3',
          OIDC_D1_PERSIST_PATH: process.env.OIDC_D1_PERSIST_PATH
            ? `${process.env.OIDC_D1_PERSIST_PATH}-dcr`
            : '.wrangler/state-dcr',
          ...(process.env.OIDC_SQLITE_PATH
            ? { OIDC_SQLITE_PATH: `${process.env.OIDC_SQLITE_PATH}-dcr` }
            : {}),
        },
      },
    ]
  : []),
```

## E2E テストの全文

`tests/e2e/specs/dynamic-client-registration.spec.ts` の全文を載せる。
旧 conformance.test.ts 層は 2026-10-07 に廃止されたため、HTTP レベルの検証マトリクス（400 の使い分け、Content-Type、未知フィールド無視、401 の 2 形、429）もこのスペックに置いた。
discovery に `registration_endpoint` が無い sample では全テストがスキップされ、広告と実装の整合（無効な sample には現れない）の確認を兼ねる。

全周テストは、`request` フィクスチャで登録したクライアントの `client_id` を使って実ブラウザで `/authorize` → ログイン → 同意を進め、リダイレクト先 URL から取り出した認可コードを発行値の資格情報でトークンに引き換え、UserInfo まで到達する。
リダイレクト先にはクライアントアプリの静的ページを使い、コード交換はテスト自身が行う。
クライアントアプリの `/callback` は自分の固定クレデンシャルで交換を試みるため、動的クライアント宛てのコードを向けられないからである。

429 の検証は実行順に依存しない形にした。
上限（3）より 1 回多く登録を試み、先行テストが在庫をいくつ消費していても最後の試行が決定的に 429 になることを使っている。

`scope` の検証は三つの観点で行う。
登録した `scope` が 201 応答へそのまま返ること、登録した範囲内の認可リクエストがログイン画面へ進むこと、範囲外を含む要求が静的クライアント（`client-scope.spec.ts`）と同じ `invalid_scope` のリダイレクトで拒否されることである。

```typescript
import { createHash, randomBytes } from 'node:crypto';
import { expect, test, type APIRequestContext } from '@playwright/test';

const host = process.env.E2E_HOST ?? '127.0.0.1';
const clientPort = Number(process.env.E2E_CLIENT_PORT ?? '3020');
const clientBaseURL =
  process.env.E2E_CLIENT_BASE_URL ?? `http://${host}:${clientPort}`;
// EXPERIMENTAL (RFC 7591): a second OP instance started by playwright.config.ts
// with an initial access token and a small inventory cap, so the restricted
// registration paths (401 / 429) can be exercised without touching the open
// registration the other tests rely on.
const dcrOpPort = Number(process.env.E2E_DCR_OP_PORT ?? '3050');
const restrictedIssuer = process.env.E2E_DCR_ISSUER ?? `http://${host}:${dcrOpPort}`;
const initialAccessToken = 'e2e-dcr-initial-access-token';
const restrictedMaxClients = 3;

// The registered redirect target only has to be a page the browser can land on
// so the spec can read code and state from the URL; the token exchange itself
// is done with the request fixture and the issued credentials. The client
// app's static /logged-out page serves exactly that.
const registeredRedirectUri = `${clientBaseURL}/logged-out`;

/**
 * EXPERIMENTAL — Dynamic Client Registration (RFC 7591).
 *
 * Only the samples generated with `--enable dynamic-client-registration`
 * expose the endpoint, so every test here skips when discovery does not
 * advertise registration_endpoint — which is also the advertised/implemented
 * consistency check: a sample without the feature never shows the field and
 * this whole file stays skipped. That keeps the shared spec suite green
 * across all sample OPs.
 */
test.describe('Dynamic Client Registration (RFC 7591)', () => {
  test('should advertise registration_endpoint only through discovery and serve it', async ({
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const endpoint = await registrationEndpoint(request, issuer);
    test.skip(endpoint === undefined, SKIP_REASON);
    expect(endpoint).toBe(`${issuer}/register`);
  });

  test('should register with defaults applied and return the issued values (RFC 7591 §3.2.1)', async ({
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const endpoint = await registrationEndpoint(request, issuer);
    test.skip(endpoint === undefined, SKIP_REASON);

    const response = await request.post(`${issuer}/register`, {
      headers: { 'Content-Type': 'application/json' },
      data: { redirect_uris: [registeredRedirectUri], client_name: 'E2E Minimal Client' },
    });

    expect(response.status()).toBe(201);
    // The body carries the client_secret, so it must never be cached.
    expect(requireHeader(response.headers(), 'cache-control')).toBe('no-store');
    const registered = await response.json() as Record<string, unknown>;
    // dcr- prefix + 16 random bytes in base64url (22 characters).
    expect(registered.client_id).toMatch(/^dcr-[A-Za-z0-9_-]{22}$/);
    // 32 random bytes in base64url (43 characters).
    expect(registered.client_secret).toMatch(/^[A-Za-z0-9_-]{43}$/);
    // 0 means "does not expire" (RFC 7591 §3.2.1), not "already expired".
    expect(registered.client_secret_expires_at).toBe(0);
    expect(typeof registered.client_id_issued_at).toBe('number');
    expect(registered.redirect_uris).toEqual([registeredRedirectUri]);
    // RFC 7591 §2 defaults.
    expect(registered.token_endpoint_auth_method).toBe('client_secret_basic');
    expect(registered.grant_types).toEqual(['authorization_code']);
    expect(registered.response_types).toEqual(['code']);
    expect(registered.client_name).toBe('E2E Minimal Client');
  });

  test('should complete the Authorization Code Flow with the issued confidential client', async ({
    page,
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const endpoint = await registrationEndpoint(request, issuer);
    test.skip(endpoint === undefined, SKIP_REASON);

    const registered = await registerClient(request, issuer, {
      redirect_uris: [registeredRedirectUri],
      token_endpoint_auth_method: 'client_secret_post',
      client_name: 'E2E Confidential Client',
    });
    const clientId = requireString(registered.client_id, 'client_id');
    const clientSecret = requireString(registered.client_secret, 'client_secret');

    const { code, state } = await authorizeInBrowser(page, issuer, clientId);

    const tokenResponse = await request.post(`${issuer}/token`, {
      form: {
        grant_type: 'authorization_code',
        code,
        redirect_uri: registeredRedirectUri,
        client_id: clientId,
        client_secret: clientSecret,
        code_verifier: state.codeVerifier,
      },
    });
    expect(tokenResponse.status()).toBe(200);
    const tokens = await tokenResponse.json() as Record<string, unknown>;
    expect(tokens.token_type).toBe('Bearer');
    const accessToken = requireString(tokens.access_token, 'access_token');
    const idToken = requireString(tokens.id_token, 'id_token');
    // The ID Token is issued to the dynamically registered client.
    expect(decodeJwtPayload(idToken).aud).toBe(clientId);

    const userinfoResponse = await request.get(`${issuer}/userinfo`, {
      headers: { Authorization: `Bearer ${accessToken}` },
    });
    expect(userinfoResponse.status()).toBe(200);
    const claims = await userinfoResponse.json() as Record<string, unknown>;
    expect(claims.sub).toBe('testuser');
  });

  test('should complete the flow without a secret for a public client registered with none', async ({
    page,
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const endpoint = await registrationEndpoint(request, issuer);
    test.skip(endpoint === undefined, SKIP_REASON);

    const registered = await registerClient(request, issuer, {
      redirect_uris: [registeredRedirectUri],
      token_endpoint_auth_method: 'none',
      client_name: 'E2E Public Client',
    });
    const clientId = requireString(registered.client_id, 'client_id');
    // RFC 6749 §2.1: a public client holds no secret, so none is issued.
    expect(Object.hasOwn(registered, 'client_secret')).toBe(false);
    expect(Object.hasOwn(registered, 'client_secret_expires_at')).toBe(false);

    const { code, state } = await authorizeInBrowser(page, issuer, clientId);

    const tokenResponse = await request.post(`${issuer}/token`, {
      form: {
        grant_type: 'authorization_code',
        code,
        redirect_uri: registeredRedirectUri,
        client_id: clientId,
        code_verifier: state.codeVerifier,
      },
    });
    expect(tokenResponse.status()).toBe(200);
    const tokens = await tokenResponse.json() as Record<string, unknown>;
    expect(tokens.token_type).toBe('Bearer');
  });

  test('should reject an unregistered dcr- client_id at the authorization endpoint', async ({
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const endpoint = await registrationEndpoint(request, issuer);
    test.skip(endpoint === undefined, SKIP_REASON);

    // The contrast to the flows above: a client_id nobody registered must not
    // start a flow. An unknown client is a non-redirectable error (OAuth 2.1
    // §4.1.2.1), so no Location header carries a code anywhere.
    const url = new URL('/authorize', issuer);
    url.searchParams.set('client_id', 'dcr-0000000000000000000000');
    url.searchParams.set('redirect_uri', registeredRedirectUri);
    url.searchParams.set('response_type', 'code');
    url.searchParams.set('scope', 'openid');
    const response = await request.get(url.toString(), { maxRedirects: 0 });
    expect(response.status()).toBe(400);
  });

  test('should answer invalid_redirect_uri without reflecting the offending URI (RFC 7591 §3.2.2)', async ({
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const endpoint = await registrationEndpoint(request, issuer);
    test.skip(endpoint === undefined, SKIP_REASON);

    const response = await request.post(`${issuer}/register`, {
      headers: { 'Content-Type': 'application/json' },
      data: { redirect_uris: ['https://app.example.com/cb#e2e-marker'] },
    });
    expect(response.status()).toBe(400);
    expect(await response.json()).toEqual({
      error: 'invalid_redirect_uri',
      error_description:
        'each redirect_uri must be an absolute URI without a fragment and must not use a dangerous scheme or non-loopback http',
    });
  });

  test('should answer invalid_client_metadata for an unsupported token_endpoint_auth_method', async ({
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const endpoint = await registrationEndpoint(request, issuer);
    test.skip(endpoint === undefined, SKIP_REASON);

    const response = await request.post(`${issuer}/register`, {
      headers: { 'Content-Type': 'application/json' },
      data: { redirect_uris: [registeredRedirectUri], token_endpoint_auth_method: 'private_key_jwt' },
    });
    expect(response.status()).toBe(400);
    expect(await response.json()).toEqual({
      error: 'invalid_client_metadata',
      error_description:
        'token_endpoint_auth_method must be one of client_secret_basic, client_secret_post, none',
    });
  });

  test('should reject a request body that is not application/json (RFC 7591 §3.1)', async ({
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const endpoint = await registrationEndpoint(request, issuer);
    test.skip(endpoint === undefined, SKIP_REASON);

    // A text/plain POST can be sent cross-origin without a CORS preflight, so
    // the media type check also closes that form-post trick.
    const response = await request.post(`${issuer}/register`, {
      headers: { 'Content-Type': 'text/plain' },
      data: JSON.stringify({ redirect_uris: [registeredRedirectUri] }),
    });
    expect(response.status()).toBe(400);
    expect(await response.json()).toEqual({
      error: 'invalid_client_metadata',
      error_description: 'registration requests must use application/json',
    });
  });

  test('should ignore metadata this provider does not understand (RFC 7591 §2 MUST)', async ({
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const endpoint = await registrationEndpoint(request, issuer);
    test.skip(endpoint === undefined, SKIP_REASON);

    const response = await request.post(`${issuer}/register`, {
      headers: { 'Content-Type': 'application/json' },
      data: {
        redirect_uris: [registeredRedirectUri],
        logo_uri: 'https://app.example.com/logo.png',
        software_statement: 'eyJhbGciOiJSUzI1NiJ9.e30.sig',
      },
    });
    expect(response.status()).toBe(201);
    const registered = await response.json() as Record<string, unknown>;
    expect(Object.hasOwn(registered, 'logo_uri')).toBe(false);
    expect(Object.hasOwn(registered, 'software_statement')).toBe(false);
  });

  // --- scope (RFC 7591 §2): the registered per-client scope allow list ---

  test('should echo the registered scope in the 201 response (RFC 7591 §3.2.1)', async ({
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const endpoint = await registrationEndpoint(request, issuer);
    test.skip(endpoint === undefined, SKIP_REASON);

    const registered = await registerClient(request, issuer, {
      redirect_uris: [registeredRedirectUri],
      scope: 'openid profile',
    });
    // The response carries all registered metadata (RFC 7591 §3.2.1), so the
    // client can see which scope restriction its registration ended up with.
    expect(registered.scope).toBe('openid profile');
  });

  test('should continue to the login screen for a scope the registration allows', async ({
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const endpoint = await registrationEndpoint(request, issuer);
    test.skip(endpoint === undefined, SKIP_REASON);

    const registered = await registerClient(request, issuer, {
      redirect_uris: [registeredRedirectUri],
      scope: 'openid',
    });
    const clientId = requireString(registered.client_id, 'client_id');

    const response = await request.get(scopeAuthorizeUrl(issuer, clientId, 'openid'), {
      maxRedirects: 0,
    });
    expect(response.status()).toBe(302);
    expect(requireHeader(response.headers(), 'location')).toBe(`${issuer}/login`);
  });

  test('should redirect invalid_scope for a scope outside the registered scope (RFC 6749 §4.1.2.1)', async ({
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const endpoint = await registrationEndpoint(request, issuer);
    test.skip(endpoint === undefined, SKIP_REASON);

    const registered = await registerClient(request, issuer, {
      redirect_uris: [registeredRedirectUri],
      scope: 'openid',
    });
    const clientId = requireString(registered.client_id, 'client_id');

    // The dynamically registered scope is enforced exactly like a static
    // client's: a request outside it is a redirectable invalid_scope error.
    const response = await request.get(scopeAuthorizeUrl(issuer, clientId, 'openid profile'), {
      maxRedirects: 0,
    });
    expect(response.status()).toBe(302);
    const location = new URL(requireHeader(response.headers(), 'location'));
    expect(`${location.origin}${location.pathname}`).toBe(registeredRedirectUri);
    expect(location.searchParams.get('error')).toBe('invalid_scope');
    expect(location.searchParams.get('error_description')).toBe(
      'Client is not registered for scope: profile',
    );
    expect(location.searchParams.get('state')).toBe('dcr-scope-state');
    expect(location.searchParams.get('code')).toBe(null);
  });

  // --- The restricted instance: initial access token and the inventory cap ---

  test('should answer 401 without an error code when no credentials accompany the request (RFC 6750 §3.1)', async ({
    request,
  }) => {
    const endpoint = await registrationEndpoint(request, restrictedIssuer);
    test.skip(endpoint === undefined, RESTRICTED_SKIP_REASON);

    const response = await request.post(`${restrictedIssuer}/register`, {
      headers: { 'Content-Type': 'application/json' },
      data: { redirect_uris: [registeredRedirectUri] },
    });
    expect(response.status()).toBe(401);
    expect(requireHeader(response.headers(), 'www-authenticate')).toBe('Bearer');
  });

  test('should answer 401 invalid_token for a presented but wrong initial access token', async ({
    request,
  }) => {
    const endpoint = await registrationEndpoint(request, restrictedIssuer);
    test.skip(endpoint === undefined, RESTRICTED_SKIP_REASON);

    const response = await request.post(`${restrictedIssuer}/register`, {
      headers: {
        'Content-Type': 'application/json',
        Authorization: 'Bearer not-the-registered-token',
      },
      data: { redirect_uris: [registeredRedirectUri] },
    });
    expect(response.status()).toBe(401);
    expect(requireHeader(response.headers(), 'www-authenticate')).toBe(
      'Bearer error="invalid_token"',
    );
  });

  test('should register with the initial access token and answer 429 once the inventory cap is reached', async ({
    request,
  }) => {
    const endpoint = await registrationEndpoint(request, restrictedIssuer);
    test.skip(endpoint === undefined, RESTRICTED_SKIP_REASON);

    // The instance is started with maxRegisteredClients = 3. Whatever earlier
    // tests consumed, cap + 1 attempts end at the ceiling, so the last attempt
    // is deterministically 429.
    const statuses: number[] = [];
    let lastResponse;
    for (let attempt = 0; attempt < restrictedMaxClients + 1; attempt++) {
      lastResponse = await request.post(`${restrictedIssuer}/register`, {
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${initialAccessToken}`,
        },
        data: { redirect_uris: [registeredRedirectUri] },
      });
      statuses.push(lastResponse.status());
    }

    expect(statuses[0]).toBe(201);
    expect(statuses[statuses.length - 1]).toBe(429);
    const body = await requireResponse(lastResponse).json() as Record<string, unknown>;
    // Fixed wording: the metadata is fine, so invalid_client_metadata would
    // invite a retry loop; and no Retry-After, because the cap is a stock
    // ceiling with no recovery time to promise.
    expect(body).toEqual({
      error: 'too_many_registrations',
      error_description: 'registration limit reached',
    });
    expect(requireResponse(lastResponse).headers()['retry-after']).toBe(undefined);
  });
});

const SKIP_REASON =
  'This sample OP was generated without --enable dynamic-client-registration';
const RESTRICTED_SKIP_REASON =
  'The restricted-registration OP instance is not running for this sample';

interface AuthorizeState {
  codeVerifier: string;
}

/** Register a client and return the parsed 201 body. */
async function registerClient(
  request: APIRequestContext,
  issuer: string,
  metadata: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  const response = await request.post(`${issuer}/register`, {
    headers: { 'Content-Type': 'application/json' },
    data: metadata,
  });
  expect(response.status()).toBe(201);
  return await response.json() as Record<string, unknown>;
}

/**
 * Drive /authorize → login → consent in the real browser with the issued
 * client_id and return the code (plus the PKCE verifier the request used).
 */
async function authorizeInBrowser(
  page: import('@playwright/test').Page,
  issuer: string,
  clientId: string,
): Promise<{ code: string; state: AuthorizeState }> {
  const codeVerifier = base64Url(randomBytes(32));
  const codeChallenge = base64Url(createHash('sha256').update(codeVerifier).digest());
  const requestState = base64Url(randomBytes(16));

  const authorizeUrl = new URL('/authorize', issuer);
  authorizeUrl.searchParams.set('client_id', clientId);
  authorizeUrl.searchParams.set('redirect_uri', registeredRedirectUri);
  authorizeUrl.searchParams.set('response_type', 'code');
  authorizeUrl.searchParams.set('scope', 'openid');
  authorizeUrl.searchParams.set('state', requestState);
  authorizeUrl.searchParams.set('nonce', base64Url(randomBytes(16)));
  authorizeUrl.searchParams.set('code_challenge', codeChallenge);
  authorizeUrl.searchParams.set('code_challenge_method', 'S256');

  await page.goto(authorizeUrl.toString());
  await expect(page).toHaveURL(new RegExp(`^${escapeRegExp(issuer)}/login$`));
  await page.getByLabel('Username:').fill('testuser');
  await page.getByLabel('Password:').fill('password');
  await page.getByRole('button', { name: 'Login' }).click();

  await expect(page).toHaveURL(new RegExp(`^${escapeRegExp(issuer)}/consent$`));
  // The consent screen names the dynamically registered client.
  await expect(page.locator('strong')).toHaveText(clientId);
  await page.getByRole('button', { name: 'Approve' }).click();

  await expect(page).toHaveURL(new RegExp(`^${escapeRegExp(registeredRedirectUri)}\\?`));
  const callbackUrl = new URL(page.url());
  expect(callbackUrl.searchParams.get('state')).toBe(requestState);
  expect(callbackUrl.searchParams.get('iss')).toBe(issuer);
  const code = callbackUrl.searchParams.get('code');
  expect(code).not.toBe(null);
  return { code: code as string, state: { codeVerifier } };
}

/**
 * An /authorize URL for the scope tests: a fixed state and the RFC 7636
 * Appendix B S256 challenge, with only client_id and scope varying.
 */
function scopeAuthorizeUrl(issuer: string, clientId: string, scope: string): string {
  const url = new URL('/authorize', issuer);
  url.searchParams.set('response_type', 'code');
  url.searchParams.set('client_id', clientId);
  url.searchParams.set('redirect_uri', registeredRedirectUri);
  url.searchParams.set('scope', scope);
  url.searchParams.set('state', 'dcr-scope-state');
  url.searchParams.set('nonce', 'dcr-scope-nonce');
  url.searchParams.set('code_challenge', 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
  url.searchParams.set('code_challenge_method', 'S256');
  return url.toString();
}

/**
 * registration_endpoint from discovery, or undefined when the OP does not
 * advertise it — or, for the restricted instance, is not running at all.
 */
async function registrationEndpoint(
  request: APIRequestContext,
  issuer: string,
): Promise<string | undefined> {
  try {
    const response = await request.get(`${issuer}/.well-known/openid-configuration`);
    expect(response.status()).toBe(200);
    const metadata = await response.json() as Record<string, string | undefined>;
    return metadata.registration_endpoint;
  } catch {
    return undefined;
  }
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function base64Url(bytes: Buffer): string {
  return bytes.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function decodeJwtPayload(jwt: string): Record<string, unknown> {
  const segments = jwt.split('.');
  expect(segments).toHaveLength(3);
  return JSON.parse(Buffer.from(segments[1] as string, 'base64url').toString('utf8')) as Record<
    string,
    unknown
  >;
}

function requireBaseUrl(baseURL: string | undefined): string {
  expect(baseURL).toBeTruthy();
  return (baseURL as string).replace(/\/$/, '');
}

function requireHeader(headers: Record<string, string>, name: string): string {
  const value = headers[name];
  expect(value, `missing response header: ${name}`).toBeTruthy();
  return value as string;
}

function requireString(value: unknown, label: string): string {
  expect(typeof value, `${label} should be a string`).toBe('string');
  return value as string;
}

function requireResponse<T>(value: T | undefined): T {
  expect(value).toBeTruthy();
  return value as T;
}
```

## 関連資料

- 仕様書・理解資料・レビュー記録: `tasks/experimental/done/dynamic-client-registration/`
- 利用者向けドキュメント: OSS リポジトリ `docs/library-document/src/content/docs/experimental/dynamic-client-registration.md`
- [RFC 7591: OAuth 2.0 Dynamic Client Registration Protocol](https://datatracker.ietf.org/doc/html/rfc7591)
- [OpenID Connect Dynamic Client Registration 1.0](https://openid.net/specs/openid-connect-registration-1_0.html)
- [OpenID Connect Discovery 1.0 §3](https://openid.net/specs/openid-connect-discovery-1_0.html#ProviderMetadata)
- [RFC 6750 §3.1](https://datatracker.ietf.org/doc/html/rfc6750#section-3.1)（401 応答の 2 形の根拠）
- [RFC 6585 §4](https://datatracker.ietf.org/doc/html/rfc6585#section-4)（429 Too Many Requests）
