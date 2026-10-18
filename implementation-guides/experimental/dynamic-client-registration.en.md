# Dynamic Client Registration (RFC 7591) Implementation Guide

- **feature-id**: `dynamic-client-registration`
- **Specifications**: a subset of [RFC 7591: OAuth 2.0 Dynamic Client Registration Protocol](https://datatracker.ietf.org/doc/html/rfc7591) and [OpenID Connect Dynamic Client Registration 1.0](https://openid.net/specs/openid-connect-registration-1_0.html)
- **Enable with**: `maronn-oidc generate <framework> --enable dynamic-client-registration`
- **User-facing documentation**: `docs/library-document/src/content/docs/experimental/dynamic-client-registration.md`

[日本語版](./dynamic-client-registration.ja.md)

## What the feature does

Out of the box, the only way to add a client to this OP is to edit the static registry: the startup code registers each client with `registerClient()` of `db/`, so a new client only becomes usable after that code is changed, rebuilt and restarted. That friction shows up in two places. Many OIDF Conformance Suite test plans assume the suite can register a client against the OP when the test starts, and ecosystems such as MCP (Model Context Protocol) clients expect to register themselves at connection time.

**Dynamic Client Registration** (DCR) defines a client registration endpoint where a client submits its metadata at runtime and receives a registration. An OP generated with `--enable dynamic-client-registration` serves `POST /register` and advertises `registration_endpoint` in discovery.

```text
Client                                 OP (generated code + experimental/dynamic-client-registration + core)
 |                                       |
 |-- POST /register -------------------->| (1) (only when configured) compare Authorization: Bearer against the
 |   Content-Type: application/json      |     initial access token in constant time; missing/wrong -> 401
 |   {"redirect_uris": [...], ...}       | (2) check Content-Type, body size and JSON shape (400 on violation)
 |                                       | (3) pick exactly the six understood fields, validate, apply defaults
 |                                       | (4) mint client_id (and, for confidential clients, client_secret)
 |                                       | (5) check the inventory cap and save to the store
 |<- 201 Created ------------------------|(6) issued values + all registered metadata as JSON (Cache-Control: no-store)
 |                                       |
 |-- GET /authorize?client_id=dcr-... -->| the existing Authorization Code Flow just works from here
 |                                       | (client resolution consults the configured resolver, then the dynamic store)
```

The issued `client_id` and `client_secret` work on `/authorize` and `/token` right away. Everything that constrains a statically registered client (PKCE, exact `redirect_uri` match, client authentication) applies to a dynamically registered one identically; the only difference is one extra step at the end of client resolution.

### Use cases

- Run the OIDF Conformance Suite test plans that assume dynamic registration against this OP
- Receive and verify clients that register themselves at connection time, such as MCP clients
- Wire up several test applications quickly, without editing static configuration and redeploying
- Observe the plain RFC 7591 behavior, such as how the `token_endpoint_auth_method` and `grant_types` defaults apply

### Scope and non-goals

Implemented:

- `POST /register` (RFC 7591 §3; open registration by default, optionally guarded by an initial access token)
- Validation of the six accepted metadata fields (`redirect_uris` / `token_endpoint_auth_method` / `grant_types` / `response_types` / `client_name` / `scope`) with the RFC 7591 §2 defaults
- Minting of the issued values (a `dcr-`-prefixed `client_id`, a 256-bit `client_secret`) and the §3.2.1 201 response
- An in-memory store for dynamically registered clients, composed with the configured client resolution
- Advertising `registration_endpoint` in discovery (OIDC Discovery 1.0 §3)

Non-goals:

- RFC 7592 (reading, updating and deleting a registration). OIDC Dynamic Client Registration 1.0 §3.2 requires `registration_access_token` and `registration_client_uri` to be returned either both or neither, so this feature returns neither
- `software_statement` (RFC 7591 §2.3): ignored as unknown metadata; there is no `invalid_software_statement` path
- Issuing or managing initial access tokens; only the comparison against one fixed string in the generated configuration is provided
- Interpreting OIDC-specific metadata. URL-dereferencing fields in particular (`jwks_uri`, `logo_uri`, ...) would open an SSRF surface, so they are not accepted
- Registering experimental grants: `grant_types` only accepts `authorization_code` and `refresh_token`, so the Token Exchange and CIBA URNs are rejected and no coupling between experimental features is created
- Per-IP rate limiting (a MAY in RFC 7591 §5): the feature carries an inventory cap and a body-size cap, and leaves flow control to the deployment layer

## Design approach

The implementation separates deciding from doing. The experimental package holds only pure functions — request validation with default application, record and response building, initial access token comparison — that touch neither HTTP nor a store. Receiving HTTP, saving to the store and checking the inventory cap belong to the generated code. This is exactly the split the study material sketched as the future promotion path (pure validation/minting functions in core, persistence injected through a store contract), so a promotion is a mechanical move.

Core is unchanged. The only core APIs used are the public `validateRegisteredRedirectUris` and `generateRandomString`; the former applies the same `redirect_uris` rules to dynamic registrations as to static clients (no fragments, dangerous schemes rejected, non-loopback plain http rejected). The constant-time comparison duplicates the approach of core's internal `timingSafeEqual`, because core does not export it and no dependency on non-public API may be created — in line with the policy of tolerating code duplication between experimental features (promoting it to a public core API is recorded in the task's future considerations).

The threat model boils down to one fact: this is an endpoint anyone can write to without authentication. Most design decisions follow from it.

- **Unknown fields are dropped by allowlist-pick.** RFC 7591 §2's "MUST ignore" could also be satisfied by spreading the parsed object and overriding known fields, but that leaves the handling of prototype-path keys such as `__proto__` to chance. Picking exactly the six understood fields into a fresh object means unknown keys are never even read
- **`client_id` is a `dcr-`-prefixed random value and cannot be chosen by the request.** Static client ids are human-named (`example-client` in the samples), so the fixed prefix separates the namespaces and overwriting an existing client is structurally impossible. A `client_id` is not a secret, so revealing its dynamic origin costs nothing and makes logs easier to read
- **`scope` is registered and becomes the per-client allow list.** A client whose core `ClientInfo.scope` is set has every request for a scope outside it rejected with `invalid_scope`, but the initial implementation dropped the registration `scope` metadata (RFC 7591 §2) like an unknown field, so this restriction could never reach a dynamically registered client. Validating the value and carrying it into the record gives dynamic registrations the same least-privilege control as static ones. Where `--scope` declared custom scopes, a value outside the advertised list (`SUPPORTED_SCOPES`) is rejected with `invalid_client_metadata`, so a 201 never promises something the provider advertises differently. Omitting `scope` registers the client unrestricted, exactly like omitting it on a static client
- **Hitting the cap answers 429, not `invalid_client_metadata`.** The RFC 7591 §3.2.2 error vocabulary describes metadata problems. Answering 400 would tell the client "fix your metadata and retry", and that retry loop amplifies the very DoS surface the cap is there to close. No `Retry-After` either: the cap is a stock ceiling, not a rate, so no recovery time can be promised
- **The 401 comes in the two RFC 6750 §3.1 shapes.** A request without an `Authorization` header gets no error code (the §3.1 SHOULD NOT); a presented-but-wrong token gets `error="invalid_token"`. Distinguishing the two gives an attacker nothing (the requester knows what it sent); what actually matters is that nothing about the expected token — length, partial matches — is reflected in any response
- **`error_description` is a fixed ASCII string.** Request-derived values (URIs, metadata) never appear in it, so validation failures cannot be used to probe the server

The store placement follows precedent. Like the PAR / Device / CIBA experimental stores, the dynamic client store is an in-memory globalThis singleton in the generated code regardless of `--db`, and is not added to the core store set (`ProviderStores`) that `--db` swaps to a backend. The same trade-off applies: dynamic registrations do not survive a restart, which is fine for a Conformance Suite run.

Client resolution composes the configured base resolver first (the static Map without `--db`, the client tables/keys with `--db sql` / `--db kv`) and consults the dynamic store only when the base finds nothing. A static registration therefore always wins — a second wall on top of the `dcr-` prefix making collisions impossible in the first place.

Discovery takes the same route as the other experimental features. Core's `DiscoveryConfig` has had a conditional field for `registration_endpoint` all along, but the generated code does not use it: the base discovery merges the members that the `discovery` hook of `features/dynamic-client-registration/feature.ts` returns. The base `build-metadata` step only reads the hooks and imports no feature, so the metadata of every feature is added this way.

## Implementation, file by file

Every file under `packages/experimental/src/dynamic-client-registration/` follows in full.

### registration-request.ts (request validation and defaults)

The validation core. It takes the raw body string and checks the byte-size cap, the JSON shape and each field's value in order, returning a `ValidatedClientRegistration` with the defaults applied. The size check uses the UTF-8 byte length from `TextEncoder`, not the string length in UTF-16 code units, which keeps boundary tests with multi-byte characters deterministic.

One design decision sits in the `redirect_uris` check. Core's `validateRegisteredRedirectUris` is a configuration-mistake detector: it throws a `server_error` `AuthorizationError` whose message embeds the offending URI. Used as-is it would violate both this feature's error policy (no request-derived values in descriptions) and the RFC 7591 §3.2.2 error code (`invalid_redirect_uri`). So the exception is caught and re-thrown with the registration endpoint's contract — same rules, different error surface.

`grant_types` accepts only subsets of `authorization_code` and `refresh_token`, and additionally requires `authorization_code` to be present: with `response_types` pinned to `["code"]`, a registration without the matching grant is the inconsistent state RFC 7591 §2.1 says not to register.

`scope` arrives as a space-delimited string and is checked against the RFC 6749 §3.3 syntax (the scope-token character set, single-space delimiters). The accepted list is injected through the `supportedScopes` option, so the pure function stays ignorant of the generated code's scope policy. Without the option only the syntax is checked: a build that generates no scope policy module has no declared list to check against, and the registered list then works as a restriction the client imposes on itself. Duplicates collapse to the first occurrence, error strings stay fixed ASCII like every other field's, and an omitted `scope` produces no key at all, mirroring `client_name`.

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
 * 平文 http 拒否）は core の validateRegisteredRedirectUris に委ね、静的
 * クライアントと同一の登録基準を適用する。core の例外は違反 URI を
 * メッセージへ埋め込んだ server_error なので、コードを invalid_redirect_uri
 * （RFC 7591 §3.2.2）へ、文言を URI を含まない固定 ASCII へ差し替える。
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
      'redirect_uris must only contain https or loopback http URIs without fragments',
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
  // C0 制御文字と DEL。改行やエスケープでログ・画面を汚す値を登録させない。
  // eslint-disable-next-line no-control-regex
  if (/[\u0000-\u001f\u007f]/.test(value)) {
    throw new ClientRegistrationError(
      'invalid_client_metadata',
      'client_name must not contain control characters',
    );
  }
  return { clientName: value };
}
```

### registered-client.ts (record and 201 response building)

This module only mints the issued values and shapes the response. `buildRegisteredClient` treats a client registered with `token_endpoint_auth_method: "none"` as public and issues no `client_secret` (an RFC 6749 §2.1 public client holds none). The generators and the clock are injectable, so tests can pin the issued values.

The returned record structurally satisfies the generated `RegisteredClient` type (core's `ClientInfo & TokenClientInfo`). No core type extension is needed because the accepted metadata is deliberately limited to axes core already interprets; `clientName` and `clientIdIssuedAt` are extra information core never reads, used only for the response. A registered `scope` stays an array and becomes the record's `scope` (core's `ClientInfo.scope`, the per-client allow list); the 201 response turns it back into the space-delimited string of RFC 6749 §3.3.

`buildClientRegistrationResponse` follows §3.2.1's "MUST return all registered metadata", including the applied defaults. `client_secret_expires_at` is REQUIRED only when a secret was issued, and `0` means "does not expire".

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

### initial-access-token.ts (initial access token comparison)

The comparison function for deployments that require a credential to register. The header is parsed in the RFC 6750 §2.1 shape (`Bearer` plus a b64token), with the scheme name case-insensitive per RFC 9110 §11.1. The comparison HMAC-SHA256s both values with a per-call random key and XOR-compares the fixed-length digests, so unlike `===` the response time does not depend on how long a prefix matches.

The missing-header case (the 401 without an error code) is deliberately not here: only the HTTP-facing generated code knows whether a header was present, so that branch lives in the generated `verify-initial-access-token` step and this function answers one question — does the presented value match.

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

### index.ts (public API)

The entry point of the subpath export `@maronn-openid-connect/experimental/dynamic-client-registration`. The module comment declares the experimental status, the non-goals (RFC 7592 and friends) and the split of responsibilities with the generated code.

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

## Unit tests, in full

The tests were written first, TDD-style, and mirror the specification's test plan: happy paths, error paths, boundary values, prototype pollution, and the fixed error wording.

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
          'redirect_uris must only contain https or loopback http URIs without fragments',
        ),
      );
    });

    it('should reject a javascript: scheme redirect_uri', () => {
      expect(() =>
        validateClientRegistrationRequest(body({ redirect_uris: ['javascript:alert(1)'] })),
      ).toThrowError(
        new ClientRegistrationError(
          'invalid_redirect_uri',
          'redirect_uris must only contain https or loopback http URIs without fragments',
        ),
      );
    });

    it('should reject a non-loopback plain http redirect_uri', () => {
      expect(() =>
        validateClientRegistrationRequest(body({ redirect_uris: ['http://app.example.com/cb'] })),
      ).toThrowError(
        new ClientRegistrationError(
          'invalid_redirect_uri',
          'redirect_uris must only contain https or loopback http URIs without fragments',
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
          'redirect_uris must only contain https or loopback http URIs without fragments',
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
          'client_name must not contain control characters',
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

## CLI integration and the generated code

The experimental package is only the logic layer: validating the registration request and applying defaults, building the registration record and the 201 response, and comparing the initial access token.
Receiving HTTP, the store of dynamically registered clients, the inventory cap and the composition into client resolution all live in the code `maronn-oidc generate` writes.
`--enable dynamic-client-registration` adds two things to the generated code:

- **`features/dynamic-client-registration/`**: `feature.ts`, which describes the feature, `config.ts` with the settings, `store.ts` with the store of dynamically registered clients and the resolver composition, and the endpoint itself under `endpoints/register/` (`pipeline.ts`, `endpoint.ts`, `response.ts` and the six steps of `steps/`)
- **`features/enabled.ts`**: one import of `dynamicClientRegistration` and one entry in the `features` list

In the generated code, logic a feature runs inside a base pipeline sits in that endpoint's `pipeline.ts` as a block that starts with a marker comment containing `(feature: <feature-id>)`; this guide calls it an **owner block**.
dynamic-client-registration has no owner block in any base pipeline: everything it contributes to the base goes through the hooks of `feature.ts`.
Registration is complete within its own endpoint, and its effect on the other endpoints (that they find the issued clients) only needs the `context` hook described below.

`feature.ts` uses three hooks, `routes`, `discovery` and `context`.
`routes` declares `POST /register`; `app.ts` mounts it and answers any other method with 405.
It sets `cors: 'protected'`, so `/register` gets the same CORS policy as `/token` (the origins of `corsOrigins`).
`discovery` returns `registration_endpoint`, which the base discovery merges into its own metadata.

The `context` hook puts into the request context the store, the settings with the deployment's overrides merged in, and `clientResolver` and `tokenClientResolver` wrapped so that they also find dynamically registered clients.
The steps that look up a client (at the authorization, token, UserInfo, introspection and revocation endpoints) use the resolvers of the request context, and a value a context hook returns under a name the base already set replaces that value.
Wrapping the resolvers in this one place therefore makes a `client_id` issued at `/register` work at every endpoint, without adding a block to any pipeline.
The hooks apply in the order of `features/enabled.ts`, and what gets wrapped is the resolver in the context at that moment (the base one, or the one passed with the `clientResolver` or `tokenClientResolver` option of `createApp()`).

A registration request flows like this.
When a client POSTs its metadata as JSON to `/register`, it passes the CORS and method checks of `app.ts`, and the shared middleware (`setRequestContext()`) sets the base values and this feature's context values.
`endpoints/register/pipeline.ts` runs its blocks in order: the initial access token check, the Content-Type check and reading the body, validating the metadata and building the record, the inventory cap check and saving, and the 201 response; every failure is answered by `respondRegistrationError()` in the catch clause.
From the next request on, the issued `client_id` is resolved at `/authorize` and `/token` through the wrapped resolvers.

When the OP is generated without `--enable dynamic-client-registration`, only `features/dynamic-client-registration/` and the two lines of `features/enabled.ts` are missing; no other file changes.

### The generated code in full (hono)

Everything below is quoted from the output of `maronn-oidc generate hono --enable dynamic-client-registration` (the default features plus dynamic-client-registration).

#### The lines added to `features/enabled.ts`

`features/enabled.ts` lists the enabled features in the order their hooks apply.
dynamic-client-registration adds one import of its `feature.ts` and one entry of the `features` array.

```typescript
import { dynamicClientRegistration } from './dynamic-client-registration/feature.js';
```

```typescript
  dynamicClientRegistration,
```

#### `features/dynamic-client-registration/feature.ts`

The file that describes the feature: it passes `id`, `routes`, `discovery` and `context` to `defineFeature()`.
`/register` is an API that clients call, not a screen the browser opens, so `cors: 'protected'` gives it the CORS policy of the token endpoint.
`context` is a function: on every request it merges the `dynamicClientRegistration` option of `createApp()` or `applyOidc()` over the defaults of `config.ts`.
The store is the same singleton of `store.ts` on every request.

```typescript
import { defineFeature } from '../feature.js';
import { dynamicClientRegistrationConfig } from './config.js';
import { registerApp } from './endpoints/register/pipeline.js';
import { dynamicClientStore, withDynamicallyRegisteredClients } from './store.js';

/**
 * EXPERIMENTAL — OAuth 2.0 Dynamic Client Registration (RFC 7591): POST
 * /register. The clients it issues are kept in an in-memory store
 * (store.ts) and resolved after the configured clients, so a static
 * registration always wins. Registration management (RFC 7592) is not
 * implemented. Settings are in config.ts.
 *
 * Backed by @maronn-openid-connect/experimental, whose API is NOT stable: it
 * may change in a breaking way between releases.
 */
export const dynamicClientRegistration = defineFeature({
  id: 'dynamic-client-registration',
  routes: [{ path: '/register', app: registerApp, methods: ['POST'], cors: 'protected' }],
  // OIDC Discovery 1.0 §3: registration_endpoint.
  discovery: (issuer) => ({ registration_endpoint: `${issuer}/register` }),
  context: ({ c, options }) => ({
    dynamicClientStore,
    dynamicClientRegistrationConfig: { ...dynamicClientRegistrationConfig, ...options.dynamicClientRegistration },
    // Dynamically registered clients resolve after the configured clients.
    clientResolver: withDynamicallyRegisteredClients(c.get('clientResolver')),
    tokenClientResolver: withDynamicallyRegisteredClients(c.get('tokenClientResolver')),
  }),
});
```

#### `features/dynamic-client-registration/config.ts`

This file holds `dynamicClientRegistrationConfig`, the default settings of dynamic registration, and the type of the option that overrides them.
With `initialAccessToken` unset, registration is open (the RFC 7591 §3.1 SHOULD); once it is set, `Authorization: Bearer <value>` is required.
`maxRegisteredClients` is the inventory cap on dynamic registrations (the RFC 7591 §5 DoS consideration), and `maxRegistrationBodyBytes` the limit on the request body in UTF-8 bytes.

The settings are an object in this file rather than a `config` hook because the `config` hook only supplies defaults of the base settings (`ProviderConfig`), and these settings are not part of them.
The per-deployment override is `dynamicClientRegistration`, which the module augmentation (`declare module '../../app.js'`) adds to the base `OidcProviderOptions`, so values from environment variables and the like can be passed without editing a generated file.
The steps do not read this object directly; they read the merged value the `context` hook puts under `dynamicClientRegistrationConfig` in the request context.

```typescript
/**
 * Dynamic client registration settings. The dynamicClientRegistration option of
 * createApp() / applyOidc() is merged over these defaults (feature.ts), so change
 * them here or per deployment there.
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

declare module '../../app.js' {
  interface OidcProviderOptions {
    /**
     * EXPERIMENTAL (RFC 7591): override the dynamic client registration
     * settings (dynamicClientRegistrationConfig in
     * features/dynamic-client-registration/config.ts) per deployment — for
     * example from environment variables — without editing the generated
     * file. Unset fields keep the generated defaults.
     */
    dynamicClientRegistration?: Partial<typeof dynamicClientRegistrationConfig>;
  }
}
```

#### `features/dynamic-client-registration/store.ts`

This file holds the store contract for dynamically registered clients, its in-memory implementation, the singleton, and the resolver composition.
The contract has three methods, `get`, `save` and `count`; `count` serves the inventory cap.
The store is not added to the base `ProviderStores` (the stores whose backend `--db` swaps), so even an OP generated with `--db sql` keeps its dynamic registrations in this in-memory store.
Dynamic registrations therefore do not survive a restart and are not visible to another instance (a long-running deployment needs a persistent implementation of the contract).
The singleton lives on `globalThis` so that every module sees the same store even where a framework loads a module more than once (dev-mode hot reloads, separate module layers).

`withDynamicallyRegisteredClients()` asks the base resolver first and the dynamic store only when the base finds nothing.
A statically registered client therefore always wins, and since the `client_id` values `/register` issues carry the `dcr-` prefix, a collision cannot even happen.
The function is generic and returns the base resolver's own type.
The base `createClientResolver()` serves as both `ClientResolver` and `TokenClientResolver` in one value, and collapsing the type would leave it usable as only one of them.

```typescript
import type { RegisteredClient } from '../../config.js';

/**
 * EXPERIMENTAL — store contract for dynamically registered clients (RFC 7591).
 *
 * - get(clientId): return the registered client, or undefined when unknown.
 * - save(client): persist the registration under client.clientId.
 * - count(): how many dynamic registrations exist, for the
 *   maxRegisteredClients inventory cap (RFC 7591 §5 DoS consideration).
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

// Kept on globalThis so every module that asks for the store gets the same one,
// also where a framework loads a module more than once (dev-mode hot reloads,
// separate module layers).
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

#### `features/dynamic-client-registration/endpoints/register/pipeline.ts`

The Hono app `registerApp`, mounted at `/register`; each block calls one step.
The checks run in the order "initial access token → Content-Type → pure functions (size, shape, values, defaults) → inventory cap → save", answering with the first failing stage.
The initial access token is checked before the body is read, so an uncredentialed request gets no body interpretation at all.
Per-IP rate limiting (RFC 7591 §5) is left to the deployment layer; this endpoint only has the inventory cap and the body-size limit of `config.ts`.

```typescript
import { Hono } from 'hono';
import { parseRegistrationRequest } from './steps/parse-request.js';
import { respondRegistrationError } from './steps/respond-error.js';
import { respondRegistration } from './steps/respond.js';
import { storeRegisteredClient } from './steps/store-client.js';
import { validateRegistrationMetadata } from './steps/validate-metadata.js';
import { verifyRegistrationAccess } from './steps/verify-initial-access-token.js';

/**
 * EXPERIMENTAL — Dynamic Client Registration (RFC 7591).
 *
 * This endpoint was generated because the OP was created with
 * `--enable dynamic-client-registration`.
 * It is backed by @maronn-openid-connect/experimental, whose API is NOT stable: it may
 * change in a breaking way between releases. Do not build production code on it
 * without pinning the version.
 *
 * The client POSTs its metadata here as JSON and receives a freshly minted
 * client_id (and, for confidential clients, a client_secret) that works on
 * /authorize and /token right away. Registration is open by default
 * (RFC 7591 §3.1 SHOULD); set initialAccessToken to require a Bearer token.
 * Each block below calls one step (one box of
 * `maronn-oidc graph --detail steps --endpoint register`).
 *
 * NOTE (RFC 7591 §5): per-IP rate limiting is deliberately left to the
 * deployment layer (reverse proxy / platform); this endpoint only enforces the
 * inventory and body-size caps of config.ts. Open registration grants no trust:
 * what an issued client can do stays bounded by the same validation as a static
 * client (PKCE, exact redirect_uri match, client authentication).
 */
export const registerApp = new Hono<{ Variables: Record<string, any> }>();

registerApp.post('/', async (c) => {
  try {
    // [verify-initial-access-token] Check the initial access token, if one is required — OIDC Dynamic Client Registration 1.0 §3 / RFC 6750 §3.1
    await verifyRegistrationAccess(c);

    // [parse-request] Read the JSON metadata — RFC 7591 §3.1
    const rawBody = await parseRegistrationRequest(c);

    // [validate-metadata] Validate the metadata and build the client — RFC 7591 §2 / §3.1
    const client = validateRegistrationMetadata(c, rawBody);

    // [store-client] Enforce the inventory cap and store the client — RFC 7591 §5
    await storeRegisteredClient(c, client);

    // [respond] Respond 201 with the registration response — RFC 7591 §3.2.1
    return respondRegistration(c, client);
  } catch (error) {
    return respondRegistrationError(c, error);
  }
});
```

#### `features/dynamic-client-registration/endpoints/register/endpoint.ts`

The description `maronn-oidc graph` draws the endpoint from.
It is a `layer: 'api'` endpoint whose steps are chained in the order of `steps` (`chain: true`), with failures going to `respond-error`.
It is `rearrangeable: true`, so `--flow` may reorder it, but every step is `removable: false` and cannot be left out.
`journeys` puts on the diagram how a client goes on to the authorization endpoint with the `client_id` issued here.

```typescript
import { defineEndpoint } from '../../../../endpoints/step.js';

/** EXPERIMENTAL — the client registration endpoint. RFC 7591 §3 */
export const endpoint = defineEndpoint({
  id: 'register',
  order: 120,
  label: 'Client registration endpoint',
  path: '/register',
  methods: ['POST'],
  layer: 'api',
  group: { id: 'client-registration', label: 'Dynamic Client Registration (RFC 7591)' },
  spec: 'RFC 7591 §3',
  feature: 'dynamic-client-registration',
  rearrangeable: true,
  steps: [
    'verify-initial-access-token',
    'parse-request',
    'validate-metadata',
    'store-client',
    'respond',
    'respond-error',
  ],
  errorStep: 'respond-error',
  edges: {
    chain: true,
  },
  journeys: [
    { from: 'register', to: 'authorize', label: 'client_id', kind: 'flow', order: 20 },
  ],
});
```

#### `features/dynamic-client-registration/endpoints/register/response.ts`

This file holds the shape of the registration endpoint's answer, `RegistrationEndpointResponse`, the `RegistrationEndpointError` a step throws to fail with a fixed response, and `sendRegistrationResponse()`, which turns the answer into HTTP.
The body of a registration response carries the `client_secret`, so success and failure alike are sent with `Cache-Control: no-store`.
An answer without a body (`body: null`, such as the 401) is sent with an empty body.

```typescript
/**
 * What the client registration endpoint answers, and the failure a step
 * answers with a fixed response.
 */

/** What the client registration endpoint answers; respondRegistration() turns it into HTTP. */
export interface RegistrationEndpointResponse {
  status: number;
  body: object | null;
  headers?: Record<string, string>;
}

/** A failure a step answers with a fixed response (a malformed request). */
export class RegistrationEndpointError extends Error {
  constructor(readonly response: RegistrationEndpointResponse) {
    const details = (response.body ?? {}) as { error?: unknown; error_description?: unknown };
    super(String(details.error_description ?? details.error ?? 'client registration endpoint error'));
    this.name = 'RegistrationEndpointError';
  }
}

export function sendRegistrationResponse(c: any, response: RegistrationEndpointResponse): Response {
  c.header('Cache-Control', 'no-store');
  c.header('Pragma', 'no-cache');
  for (const [name, value] of Object.entries(response.headers ?? {})) {
    c.header(name, value);
  }
  if (response.body === null) {
    return c.body(null, response.status);
  }
  return c.json(response.body, response.status);
}
```

#### `features/dynamic-client-registration/endpoints/register/steps/verify-initial-access-token.ts`

The step that checks the `Authorization` header before the body is read, only when `initialAccessToken` is set.
The 401 comes in the two RFC 6750 §3.1 shapes: a request without the header gets no error code (`WWW-Authenticate: Bearer`), and a presented-but-wrong token gets `error="invalid_token"`.
Neither response reveals anything about the expected token.
Only this HTTP-facing step knows whether a header was present, so the branch lives here, and the experimental `verifyInitialAccessToken()` answers one question: does the presented value match.

```typescript
import { verifyInitialAccessToken } from '@maronn-openid-connect/experimental/dynamic-client-registration';
import { RegistrationEndpointError } from '../response.js';
import { step } from '../../../../../endpoints/step.js';

export const meta = step({
  id: 'verify-initial-access-token',
  endpoint: 'register',
  feature: 'dynamic-client-registration',
  kind: 'validate',
  label: 'Check the initial access token, if one is required',
  spec: 'OIDC Dynamic Client Registration 1.0 §3 / RFC 6750 §3.1',
  function: 'verifyRegistrationAccess',
  calls: ['verifyInitialAccessToken'],
  consumes: [],
  produces: [],
  removable: false,
});

/**
 * Check the initial access token when one is configured, before the body is
 * read. OIDC Dynamic Client Registration 1.0 §3 / RFC 6750 §3.1
 *
 * The two 401 shapes follow RFC 6750 §3.1: no error code without credentials,
 * and error="invalid_token" for presented-but-wrong ones. Neither reflects
 * anything about the expected token.
 */
export async function verifyRegistrationAccess(c: any): Promise<void> {
  const config = c.get('dynamicClientRegistrationConfig');
  if (config.initialAccessToken === undefined) return;
  const authorization = c.req.header('Authorization');
  if (authorization === undefined) {
    throw new RegistrationEndpointError({ status: 401, body: null, headers: { 'WWW-Authenticate': 'Bearer' } });
  }
  const accepted = await verifyInitialAccessToken(authorization, config.initialAccessToken);
  if (!accepted) {
    throw new RegistrationEndpointError({
      status: 401,
      body: null,
      headers: { 'WWW-Authenticate': 'Bearer error="invalid_token"' },
    });
  }
}
```

#### `features/dynamic-client-registration/endpoints/register/steps/parse-request.ts`

The step that checks that `Content-Type` is `application/json` and then reads the body as a string.
Parameters such as `charset` are fine.
Besides satisfying RFC 7591 §3.1, the media-type check closes the cross-origin `text/plain` form post that can synthesize a JSON-shaped body without a CORS preflight.

```typescript
import { RegistrationEndpointError } from '../response.js';
import { step } from '../../../../../endpoints/step.js';

export const meta = step({
  id: 'parse-request',
  endpoint: 'register',
  feature: 'dynamic-client-registration',
  kind: 'parse',
  label: 'Read the JSON metadata',
  spec: 'RFC 7591 §3.1',
  function: 'parseRegistrationRequest',
  consumes: [],
  produces: ['rawBody'],
  removable: false,
});

/**
 * RFC 7591 §3.1: the registration request body MUST be application/json.
 */
function isJson(contentType: string): boolean {
  const [mediaType = ''] = contentType.toLowerCase().split(';');
  return mediaType.trim() === 'application/json';
}

/**
 * RFC 7591 §3.1: the registration request body MUST be application/json
 * (parameters such as charset are fine). Enforcing the media type also closes
 * the cross-origin text/plain form post that can synthesize a JSON-shaped body
 * without a CORS preflight.
 */
export async function parseRegistrationRequest(c: any): Promise<string> {
  if (!isJson(c.req.header('Content-Type') ?? '')) {
    throw new RegistrationEndpointError({
      status: 400,
      body: { error: 'invalid_client_metadata', error_description: 'registration requests must use application/json' },
    });
  }
  return c.req.text();
}
```

#### `features/dynamic-client-registration/endpoints/register/steps/validate-metadata.ts`

The step that leaves body size, JSON shape, the allowlist-pick of the understood fields, the value checks and the RFC 7591 §2 defaults to the experimental pure functions `validateClientRegistrationRequest()` and `buildRegisteredClient()`.
The only option it passes is `maxBodyBytes`; `supportedScopes` is not passed.
So even where `--scope` declared custom scopes, a registered `scope` is checked only against the RFC 6749 §3.3 syntax.

```typescript
import {
  buildRegisteredClient,
  validateClientRegistrationRequest,
  type DynamicallyRegisteredClient,
} from '@maronn-openid-connect/experimental/dynamic-client-registration';
import { step } from '../../../../../endpoints/step.js';

export const meta = step({
  id: 'validate-metadata',
  endpoint: 'register',
  feature: 'dynamic-client-registration',
  kind: 'validate',
  label: 'Validate the metadata and build the client',
  spec: 'RFC 7591 §2 / §3.1',
  function: 'validateRegistrationMetadata',
  calls: ['validateClientRegistrationRequest', 'buildRegisteredClient'],
  consumes: ['rawBody'],
  produces: ['client'],
  removable: false,
});

/**
 * Body size, JSON shape, allowlist-pick of the understood fields, value checks
 * and RFC 7591 §2 defaults — pure functions from the experimental package.
 * Unknown metadata is silently ignored (§2 MUST), and every error_description
 * is a fixed ASCII string that never reflects request values.
 */
export function validateRegistrationMetadata(c: any, rawBody: string): DynamicallyRegisteredClient {
  const config = c.get('dynamicClientRegistrationConfig');
  const metadata = validateClientRegistrationRequest(rawBody, {
    maxBodyBytes: config.maxRegistrationBodyBytes,
  });
  return buildRegisteredClient(metadata);
}
```

#### `features/dynamic-client-registration/endpoints/register/steps/store-client.ts`

The step that checks the inventory cap and then saves the built record in the store.
At the cap it answers 429 and does not reuse `invalid_client_metadata`.
Nothing is wrong with the metadata, so a 400 would invite a fix-and-retry loop that widens the very DoS surface the cap is there to close.
No `Retry-After` either: the cap is a stock ceiling, not a rate, so no recovery time can be promised.
Neither the registration metadata nor the issued `client_secret` is logged.

```typescript
import type { DynamicallyRegisteredClient } from '@maronn-openid-connect/experimental/dynamic-client-registration';
import { RegistrationEndpointError } from '../response.js';
import { step } from '../../../../../endpoints/step.js';

export const meta = step({
  id: 'store-client',
  endpoint: 'register',
  feature: 'dynamic-client-registration',
  kind: 'persist',
  label: 'Enforce the inventory cap and store the client',
  spec: 'RFC 7591 §5',
  function: 'storeRegisteredClient',
  consumes: ['client'],
  produces: [],
  removable: false,
});

/**
 * Enforce the inventory cap (RFC 7591 §5) and store the client. 429 with a
 * fixed body: the metadata is fine, so answering invalid_client_metadata would
 * invite a retry loop that amplifies the very DoS surface the cap is here to
 * close. No Retry-After — the cap is a stock ceiling, not a rate, so no
 * recovery time is promised.
 */
export async function storeRegisteredClient(c: any, client: DynamicallyRegisteredClient): Promise<void> {
  const config = c.get('dynamicClientRegistrationConfig');
  const store = c.get('dynamicClientStore');
  if ((await store.count()) >= config.maxRegisteredClients) {
    throw new RegistrationEndpointError({
      status: 429,
      body: { error: 'too_many_registrations', error_description: 'registration limit reached' },
    });
  }
  await store.save(client);
  // Never log the registration metadata or the issued client_secret.
}
```

#### `features/dynamic-client-registration/endpoints/register/steps/respond.ts`

The step that answers 201 with the RFC 7591 §3.2.1 response built by `buildClientRegistrationResponse()`.
The response carries the issued values and every registered metadata value with the defaults applied; `client_secret_expires_at: 0` means the secret does not expire.

```typescript
import {
  type DynamicallyRegisteredClient,
  buildClientRegistrationResponse,
} from '@maronn-openid-connect/experimental/dynamic-client-registration';
import { sendRegistrationResponse } from '../response.js';
import { step } from '../../../../../endpoints/step.js';

export const meta = step({
  id: 'respond',
  endpoint: 'register',
  feature: 'dynamic-client-registration',
  kind: 'respond',
  label: 'Respond 201 with the registration response',
  spec: 'RFC 7591 §3.2.1',
  function: 'respondRegistration',
  calls: ['buildClientRegistrationResponse'],
  consumes: ['client'],
  produces: [],
  removable: false,
});

/**
 * RFC 7591 §3.2.1: 201 Created with the issued values and every registered
 * metadata value (defaults applied). client_secret_expires_at: 0 means the
 * secret does not expire. The body carries the client_secret, so it is never
 * cached.
 */
export function respondRegistration(c: any, client: DynamicallyRegisteredClient): Response {
  return sendRegistrationResponse(c, { status: 201, body: buildClientRegistrationResponse(client) });
}
```

#### `features/dynamic-client-registration/endpoints/register/steps/respond-error.ts`

The step the pipeline's catch clause calls.
A `RegistrationEndpointError` thrown by an earlier step (the 401, the 429, the Content-Type 400) is sent as its response, and the experimental `ClientRegistrationError` becomes the RFC 7591 §3.2.2 400.
Any other exception is a 500 `server_error` that discloses nothing.

```typescript
import { ClientRegistrationError } from '@maronn-openid-connect/experimental/dynamic-client-registration';
import { RegistrationEndpointError, sendRegistrationResponse } from '../response.js';
import { step } from '../../../../../endpoints/step.js';

export const meta = step({
  id: 'respond-error',
  endpoint: 'register',
  feature: 'dynamic-client-registration',
  kind: 'respond',
  label: 'Respond with the registration error',
  spec: 'RFC 7591 §3.2.2',
  function: 'respondRegistrationError',
  consumes: [],
  produces: [],
  removable: false,
});

/**
 * RFC 7591 §3.2.2: 400 with error / error_description JSON for invalid
 * metadata; the fixed responses of the earlier steps (401, 429) as they are.
 */
export function respondRegistrationError(c: any, error: unknown): Response {
  if (error instanceof RegistrationEndpointError) {
    return sendRegistrationResponse(c, error.response);
  }
  if (error instanceof ClientRegistrationError) {
    return sendRegistrationResponse(c, {
      status: 400,
      body: { error: error.error, error_description: error.errorDescription },
    });
  }
  return sendRegistrationResponse(c, { status: 500, body: { error: 'server_error' } });
}
```

### The other frameworks

The Express and Fastify output has the same files.
The generator replaces the `hono` imports of the endpoints with `web-router.ts` (a small router on the Fetch API, with `WebRouter` and `WebContext`) and adds the framework's `apply.ts`, `web-router.ts` and `node-adapter.ts`.
Their source is `apps/hono/src/web/` in the OSS repository, and `packages/cli/extract.json` defines which file goes where.
In this feature only the router of `endpoints/register/pipeline.ts` is replaced (`new Hono<...>()` becomes `new WebRouter()`); no other file imports `hono`.
The screens stay hono/jsx, so the Express and Fastify output still needs `hono` as its JSX runtime (this feature itself has no screen).

The Next.js output is extracted from `apps/nextjs` in the OSS repository (a Next.js App Router app).
The feature's route files go into the route group `app/(dynamic-client-registration)/` and its code into `app/_oidc-provider/features/dynamic-client-registration/`.
The code of Express, Fastify and Next.js is not embedded in this guide.

### Samples and the E2E wiring

`samples/hono-cloudflare` (all features, on D1) and the Express sample `samples/express-flyio` (on node:sqlite) pass `--enable dynamic-client-registration` in their generate scripts.
Both are generated with `--db sql`, but as described above, dynamic registrations go into the in-memory store.
The hand-written `src/app.ts` of both samples reads environment variables through which the E2E suite injects a restricted configuration (an initial access token and a small cap), and passes them to the `dynamicClientRegistration` option of `applyOidc()`.
This is the hono-cloudflare wiring; express-flyio reads `process.env` in the same shape:

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

The E2E `tests/e2e/playwright.config.ts` starts an OP instance with the restricted configuration next to the open-registration main instance, because open registration and the initial access token cannot be exercised on the same OP:

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
              // Always a path of its own: the node:sqlite samples default to
              // .data/oidc.sqlite, and two OP processes writing one SQLite file
              // (this instance seeding its sample data, the main one handling
              // flows) fail each other's writes.
              OIDC_SQLITE_PATH: process.env.OIDC_SQLITE_PATH
                ? `${process.env.OIDC_SQLITE_PATH}-dcr`
                : '.data/oidc-e2e-dcr.sqlite',
            },
          },
        ]
      : []),
```

## The E2E spec, in full

`tests/e2e/specs/dynamic-client-registration.spec.ts` follows in full. Since the generated contract-test layer (conformance.test.ts) was retired on 2026-10-07, the HTTP-level verification matrix (the 400 split, Content-Type, unknown-field tolerance, the two 401 shapes, 429) lives in this spec as well. Every test skips on a sample whose discovery does not advertise `registration_endpoint`, which doubles as the advertised/implemented consistency check.

The full-circle test registers a client through the `request` fixture, drives `/authorize` → login → consent in the real browser with the issued `client_id`, extracts the authorization code from the redirect URL and exchanges it with the issued credentials, reaching UserInfo. The redirect target is a static page of the client app, and the exchange is done by the test itself — the client app's `/callback` would try the exchange with its own fixed credentials, which cannot redeem a code bound to the dynamic client.

The 429 test is order-independent: it attempts one registration more than the cap (3), so the final attempt is deterministically 429 no matter how much inventory earlier tests consumed.

The `scope` tests cover three angles: the registered `scope` comes back verbatim in the 201 response, an authorization request within the registered list proceeds to the login screen, and a request outside it is rejected with the same `invalid_scope` redirect a static client gets (`client-scope.spec.ts`).

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
        'redirect_uris must only contain https or loopback http URIs without fragments',
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

## Related material

- Specification, understanding guide and review log: `tasks/experimental/done/dynamic-client-registration/`
- User-facing documentation: `docs/library-document/src/content/docs/experimental/dynamic-client-registration.md` in the OSS repository
- [RFC 7591: OAuth 2.0 Dynamic Client Registration Protocol](https://datatracker.ietf.org/doc/html/rfc7591)
- [OpenID Connect Dynamic Client Registration 1.0](https://openid.net/specs/openid-connect-registration-1_0.html)
- [OpenID Connect Discovery 1.0 §3](https://openid.net/specs/openid-connect-discovery-1_0.html#ProviderMetadata)
- [RFC 6750 §3.1](https://datatracker.ietf.org/doc/html/rfc6750#section-3.1) (the two 401 shapes)
- [RFC 6585 §4](https://datatracker.ietf.org/doc/html/rfc6585#section-4) (429 Too Many Requests)
