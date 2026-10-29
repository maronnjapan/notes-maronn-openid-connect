# Dynamic Client Registration (RFC 7591) Implementation Guide

- **feature-id**: `dynamic-client-registration`
- **Specifications**: a subset of [RFC 7591: OAuth 2.0 Dynamic Client Registration Protocol](https://datatracker.ietf.org/doc/html/rfc7591) and [OpenID Connect Dynamic Client Registration 1.0](https://openid.net/specs/openid-connect-registration-1_0.html)
- **Enable with**: `maronn-oidc generate <framework> --enable dynamic-client-registration`
- **User documentation**: `docs/library-document/src/content/docs/experimental/dynamic-client-registration.md`

[日本語版](./dynamic-client-registration.ja.md)

## What the feature does

Out of the box, the only way to add a client to this OP is to edit its static registry: write start-up code that calls `registerClient()` of `db/`, build, restart.
That friction shows up in two places.
The OIDF Conformance Suite assumes, for most of its test plans, that a client can be registered dynamically when a test starts.
And ecosystems such as MCP (Model Context Protocol) clients register themselves at connection time.

**Dynamic Client Registration** (DCR) defines a client registration endpoint that a client POSTs its metadata to at run time and receives a registration from.
An OP generated with `--enable dynamic-client-registration` serves `POST /register` and advertises `registration_endpoint` in discovery.

```text
Client                                 OP (generated code + experimental/dynamic-client-registration + core)
 |                                       |
 |-- POST /register -------------------->| (1) may the request register? with verifyInitialAccessToken in the config,
 |   Content-Type: application/json      |     a Bearer token is required and handed to it; a refusal is 401. Open otherwise
 |   {"redirect_uris": [...],            | (2) Content-Type, body size and JSON shape (400 on a violation);
 |    "software_statement": "...", ...}  |     the software_statement is split from the plain metadata
 |                                       | (3) with verifySoftwareStatement in the config, a statement is required and
 |                                       |     handed to it; its claims go over the plain values. Ignored otherwise
 |                                       | (4) allowlist-pick of the understood fields, value checks, defaults,
 |                                       |     grant_types / response_types consistency, custom metadata
 |                                       | (5) mint client_id (and client_secret for secret-based auth methods)
 |                                       | (6) inventory cap, then store (secret as its hash, jwks by purpose)
 |<- 201 Created ------------------------|(7) issued values + every registered metadata value (Cache-Control: no-store)
 |                                       |
 |-- GET /authorize?client_id=dcr-... -->| the existing flows run unchanged (code, implicit, hybrid)
 |                                       | (client and key resolution: configured resolver first, then the dynamic store)
```

The issued `client_id` and `client_secret` work on `/authorize` and `/token` right away.
Everything that validates a registered client (PKCE, exact `redirect_uri` match, client authentication, the registered scope) is identical to a statically registered client; the only difference is one more lookup at the end of client resolution.

### Use cases

- Run the dynamic-registration test plans of the OIDF Conformance Suite (Implicit OP and Hybrid OP beside Basic OP) against this OP
- Receive clients that register themselves at connection time, such as MCP clients, on a local OP
- Connect several test applications quickly, without editing and deploying static configuration
- Observe the raw behavior of RFC 7591: the defaults of `token_endpoint_auth_method` and `grant_types`, or how a software statement's metadata takes precedence over the plain values

### Scope and non-goals

Implemented:

- `POST /register` (RFC 7591 §3), open by default; whether an initial access token is required depends on whether the config holds a verifier function
- Validation and defaults for the metadata of RFC 7591 §2 and OIDC Dynamic Client Registration 1.0 §2 that the OP interprets or keeps for display: `redirect_uris`, `token_endpoint_auth_method`, `grant_types`, `response_types`, `scope`, `client_name`, `client_uri`, `logo_uri`, `tos_uri`, `policy_uri`, `contacts`, `software_id`, `software_version`, `application_type`, `default_max_age`, `id_token_signed_response_alg`, `userinfo_signed_response_alg`, `jwks`
- The consistency of `grant_types` and `response_types` (RFC 7591 §2.1); every response type this OP answers, Implicit Flow and Hybrid Flow included, is registrable
- Software statements (RFC 7591 §2.3 / §3.1.1): the claims a configured verifier function returns are applied over the plain values, and the `invalid_software_statement` / `unapproved_software_statement` it throws are answered (§3.2.2); without a function the statement is ignored
- Custom metadata beyond the standard fields, validated by functions supplied from outside the package
- The issued values (`dcr-`-prefixed `client_id`, 256-bit `client_secret`) and the §3.2.1 201 response
- An in-memory store of dynamic registrations, composed into the configured client resolution and key resolution
- `registration_endpoint` in discovery (OIDC Discovery 1.0 §3)

Non-goals:

- RFC 7592 (reading, updating and deleting a registration). OIDC Dynamic Client Registration 1.0 §3.2 requires `registration_access_token` and `registration_client_uri` to be returned both or neither; this feature returns neither
- Issuing or verifying initial access tokens and software statements; both are the job of functions supplied through the OP's config, and the feature only reads the Bearer token and applies the asserted claims
- Metadata the OP would have to fetch: `jwks_uri`, `sector_identifier_uri`, `request_uris` and the like are ignored as metadata the OP does not understand, because fetching opens an SSRF surface (only `jwks` next to `jwks_uri` is refused, per the §2 MUST NOT)
- Per-IP rate limiting (a MAY of RFC 7591 §5); the feature only has the inventory cap and the body size cap, and leaves flow control to the deployment layer

## Design approach

The implementation separates decision from execution.
The experimental package holds pure functions that touch neither HTTP nor a store: parsing the registration request, applying a software statement, validating the metadata and applying defaults, building the registration record and the 201 response, and reading the Bearer token of the Authorization header.
The HTTP entry point, the store, the inventory cap, and the decision of *what this OP lets a client register* belong to the generated code; the experimental functions always receive the allowed values as options.
That split keeps OP-specific facts (the response types and grants it answers, the algorithms of its signing keys) out of the experimental package.

Core is unchanged.
The feature uses only its public API: `validateRegisteredRedirectUris`, `normalizeResponseType`, `responseTypeIncludes` and `generateRandomString`.
`validateRegisteredRedirectUris` applies the same `redirect_uris` rules as for static clients.
Verifying an initial access token or a software statement is not part of the feature.
RFC 7591 defines the trust criteria of neither (§2.3: "beyond the scope of this specification"), so both are the job of functions supplied through the OP's config.

The threat model is one fact: an endpoint anyone can write to without authentication.
Most design decisions follow from it.

- **Understood fields are allowlist-picked, and prototype-path keys stay inert.** The RFC 7591 §2 MUST ("ignore metadata it does not understand") is met by picking the known fields into a new object, never by spreading the parsed body. Wherever an object is built from request-supplied names (reading the body, applying a software statement, registering custom metadata) the value is defined as an own property with `Object.defineProperty`, so a `__proto__` key cannot swap the prototype
- **Only values this OP answers are registrable.** `response_types` is bounded to what discovery advertises as `response_types_supported`, `grant_types` to the configured list filtered by what the OP answers (`authorization_code`, the grants of the generated features, `implicit` while a feature answers an implicit response type), and `*_signed_response_alg` to the algs of the signing keys. A client that registers but cannot use what it registered is never created, and the RFC 7591 §2.1 SHOULD (do not let a client register an inconsistent state) is enforced as `invalid_client_metadata` for the same reason
- **An initial access token and a software statement are required only when the config holds a function for them, and that function alone verifies them.** RFC 7591 §3.1 recommends open registration by default, and §3.1.1 lets an OP that does not support statements ignore them. Without a function, that plain behavior is what the OP does; with one, a request lacking the corresponding value (the Bearer token, the `software_statement`) is refused, and the function decides whether the presented value is acceptable. RFC 7591 requires nothing inside a statement but `iss` (§2.3), and the feature examines its content not at all. No default verifier is generated because the trust criteria differ per deployment: a fixed-string comparison or a publisher list can never be the production shape
- **`client_id` is a `dcr-`-prefixed random value the request cannot choose.** Static client ids are named by people (`example-client` in the samples), so the fixed prefix separates the namespaces and an existing client can never be overwritten
- **`scope` is registered and becomes the client's allow list.** Core rejects, with `invalid_scope`, any scope outside `ClientInfo.scope` of a client that has one; validating and storing the registered scope gives dynamic registrations the same least privilege as static clients. When custom scopes are declared with `--scope`, a value outside the standard and declared scopes is refused, so the 201 response never promises what discovery does not advertise
- **A `client_secret` is minted for secret-based methods only.** `none` is a public client with no secret, and a key-based method such as `private_key_jwt` is confidential without one. The list of methods that get a secret (`client_secret_basic`, `client_secret_post`, `client_secret_jwt` by default) is an option
- **The inventory cap answers 429, not `invalid_client_metadata`.** The RFC 7591 §3.2.2 vocabulary describes faulty metadata. A 400 for a full inventory would tell the client "fix the metadata and retry", and the retry loop would amplify the very DoS surface the cap closes. No `Retry-After` either: the cap is a stock ceiling, not a rate, so no recovery time can be promised
- **401 follows the two shapes of RFC 6750 §3.1.** A request without a Bearer token gets a bare challenge (the SHOULD NOT of §3.1), one whose token the function refused gets `error="invalid_token"`. What matters is that nothing about the expected token (its length, a partial match) reaches the response
- **`error_description` is fixed ASCII.** No request URI, metadata value or JWT header value is ever reflected, so a validation failure gives an attacker nothing to probe with. The messages that list allowed values (`token_endpoint_auth_method must be one of ...`) only contain configuration

The registration decisions live in the generated `config.ts` as three settings.
`verifyInitialAccessToken` and `verifySoftwareStatement` are optional functions, `undefined` as generated.
A project writes them in `config.ts`, or passes functions of the same shape through the `dynamicClientRegistration` option of `applyOidc` (`extendDynamicClientRegistrationConfig()` of `config.ts` in Next.js).
`customClientMetadata` is the table of validators for metadata beyond the standard fields.
A configuration object holding functions that an option can replace follows the precedent of ID-JAG's `actorTokenResolver`.
`extendDynamicClientRegistrationConfig` applies the option: the lists (auth methods, grants, `jwks` purposes) and the custom metadata table gain the given values, while the numeric settings and the verifier functions are replaced.
A deployment therefore only adds what it allows instead of repeating what the generated code allows; taking a value out of a generated list stays an edit of the generated file.

The store follows precedent too.
Like the experimental stores of PAR, Device and CIBA, the dynamic registration store is a `globalThis` singleton in the generated code regardless of `--db`, and is not added to core's `ProviderStores` (which `--db` swaps for a database backend).
Registrations vanish on restart, which is fine for the unit of a Conformance Suite run.
The record the store keeps has the shape `registerClient()` of `db/` takes (`ClientRegistration`): the keys of a `jwks` go in as public keys by purpose (`request_object`, `private_key_jwt`, `dpop`), and every registered metadata value stays available as `registrationMetadata`.

Client resolution asks the generated base resolver first (the static Map without `--db`, the client table or key with `--db sql` / `--db kv`) and the dynamic store only when that finds nothing.
Key resolution (`ClientKeyResolver`) is composed the same way, so a dynamically registered client's `jwks` verifies its signed Request Objects.
A static registration always wins, and the `dcr-` prefix already rules out a collision: two independent walls.

## Implementation, file by file

Every file under `packages/experimental/src/dynamic-client-registration/`.

### registration-error.ts (the error type)

The four RFC 7591 §3.2.2 error codes as a discriminated union.
The contract that `errorDescription` is fixed ASCII lives in this type's JSDoc.

```typescript
/**
 * OAuth 2.0 Dynamic Client Registration (RFC 7591) — 登録エンドポイントのエラー。
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 */

/**
 * RFC 7591 §3.2.2 のエラーコード。
 *
 * - invalid_redirect_uri: redirect_uris の欠落か、いずれかの値の規則違反
 * - invalid_client_metadata: それ以外のメタデータの不正値（grant と response の
 *   不整合、ボディの形式違反を含む）
 * - invalid_software_statement: software_statement が検証できない（JWS の形式違反、
 *   署名不一致、期限切れ、iss 欠落）
 * - unapproved_software_statement: software_statement の発行者をこの OP が
 *   承認していない
 */
export type ClientRegistrationErrorCode =
  | 'invalid_redirect_uri'
  | 'invalid_client_metadata'
  | 'invalid_software_statement'
  | 'unapproved_software_statement';

/**
 * 検証エラー。HTTP 応答では 400 の JSON ボディ（error / error_description）になる。
 *
 * errorDescription は固定の ASCII 文言に限り、リクエスト由来の値（URI や
 * メタデータ値、JWT のヘッダ値）を決して埋め込まない。検証失敗の詳細を攻撃者の
 * 探索に使わせないため（仕様書のセキュリティ要件）。
 */
export class ClientRegistrationError extends Error {
  readonly error: ClientRegistrationErrorCode;
  readonly errorDescription: string;

  constructor(error: ClientRegistrationErrorCode, errorDescription: string) {
    super(errorDescription);
    this.name = 'ClientRegistrationError';
    this.error = error;
    this.errorDescription = errorDescription;
  }
}

/**
 * error が ClientRegistrationError か（形で判定する）。
 *
 * instanceof は、生成コードがこのパッケージを 2 度読み込む構成で偽になる。
 * Next.js の本番ビルドは instrumentation と Route Handler を別のバンドルにするため、
 * instrumentation 側で組んだ登録ポリシーが投げたエラーのクラスは、Route Handler
 * が import したクラスと別のオブジェクトになる。応答の振り分けはこの関数で行い、
 * クラスの同一性に依存しない。
 */
export function isClientRegistrationError(error: unknown): error is ClientRegistrationError {
  return (
    typeof error === 'object' &&
    error !== null &&
    (error as { name?: unknown }).name === 'ClientRegistrationError' &&
    typeof (error as { error?: unknown }).error === 'string' &&
    typeof (error as { errorDescription?: unknown }).errorDescription === 'string'
  );
}
```

### metadata-values.ts (checks of the individual metadata values)

One function per understood field: control and invisible characters in display strings, the syntax of the informational URLs, the contacts array, the scope syntax (RFC 6749 §3.3), the `redirect_uris` constraints per `application_type` (OIDC Dynamic Client Registration 1.0 §2), `default_max_age`, the signing algorithms, and the shape of `jwks`.
The `jwks` check admits only the RSA / EC signature public keys core can read and refuses any key carrying a private parameter.
A key without `alg` or `use` gets a default, and the completed value appears in the response as registered metadata (RFC 7591 §3.1 lets the server replace values).
`defineOwnProperty` is what every place that builds an object from request-supplied names uses.

```typescript
/**
 * OAuth 2.0 Dynamic Client Registration (RFC 7591) — 個々のメタデータ値の検査。
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * registration-request.ts の validateClientMetadata が、理解するフィールドごとに
 * ここの関数を呼ぶ。どの関数も値の形だけを見る純関数で、違反は
 * ClientRegistrationError（invalid_client_metadata）として投げる。
 * error_description は固定の ASCII 文言に限り、リクエスト由来の値を埋め込まない。
 */

import type { Jwk, JwkSet } from '@maronn-openid-connect/core';
import { ClientRegistrationError } from './registration-error.js';

/**
 * 表示名や連絡先に登録させない文字。C0 / C1 制御文字と DEL、bidi 制御文字
 * （U+200E–U+200F / U+202A–U+202E / U+2066–U+2069）、ゼロ幅文字
 * （U+200B–U+200D / U+FEFF）。改行やエスケープでログや画面を汚す値に加え、
 * 表示順の反転や見えない文字で表示名を偽装する値も登録させない。
 */
// eslint-disable-next-line no-control-regex
const INVISIBLE_CHARACTERS = /[\u0000-\u001f\u007f-\u009f​-‏‪-‮⁦-⁩﻿]/;

/** JSON オブジェクト（配列と null を除く）か。 */
export function isJsonObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/**
 * 自身のデータプロパティとして値を置く。`target[name] = value` は name が
 * `__proto__` のときプロトタイプを差し替えてしまうので、リクエスト由来の名前で
 * オブジェクトを組み立てるときはこちらを使う。
 */
export function defineOwnProperty(target: Record<string, unknown>, name: string, value: unknown): void {
  Object.defineProperty(target, name, { value, enumerable: true, writable: true, configurable: true });
}

function invalidMetadata(description: string): ClientRegistrationError {
  return new ClientRegistrationError('invalid_client_metadata', description);
}

/**
 * 人間が読む文字列のメタデータ（client_name / software_id / software_version /
 * contacts の各要素）。長さの上限と、制御文字や見えない文字の不在だけを検査する。
 */
export function validateDisplayString(value: unknown, name: string, maxLength: number): string {
  if (typeof value !== 'string') {
    throw invalidMetadata(`${name} must be a string`);
  }
  if (value.length > maxLength) {
    throw invalidMetadata(`${name} must be at most ${maxLength} characters`);
  }
  if (INVISIBLE_CHARACTERS.test(value)) {
    throw invalidMetadata(`${name} must not contain control or invisible formatting characters`);
  }
  return value;
}

const URL_MAX_LENGTH = 2048;

/**
 * 利用者へ示す URL のメタデータ（client_uri / logo_uri / tos_uri / policy_uri。
 * RFC 7591 §2）。OP はこれらを取得しに行かず、保持して応答に返すだけなので、
 * 検査は絶対 URL であることと http / https スキームに限る。`javascript:` などの
 * スキームは、将来この値を画面へ出すときのために登録段階で拒否する。
 */
export function validateHttpUrl(value: unknown, name: string): string {
  if (typeof value !== 'string' || value.length === 0 || value.length > URL_MAX_LENGTH) {
    throw invalidMetadata(`${name} must be an absolute http or https URL`);
  }
  if (INVISIBLE_CHARACTERS.test(value)) {
    throw invalidMetadata(`${name} must be an absolute http or https URL`);
  }
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw invalidMetadata(`${name} must be an absolute http or https URL`);
  }
  if (url.protocol !== 'https:' && url.protocol !== 'http:') {
    throw invalidMetadata(`${name} must be an absolute http or https URL`);
  }
  return value;
}

const CONTACTS_MAX_ENTRIES = 32;
const CONTACT_MAX_LENGTH = 256;

/**
 * contacts: 責任者への連絡手段（通常はメールアドレス）の配列（RFC 7591 §2）。
 * メールアドレスの構文は検査しない（RFC 7591 は形式を定めず、OP は送信しない）。
 */
export function validateContacts(value: unknown): string[] {
  if (!Array.isArray(value) || value.length === 0 || value.length > CONTACTS_MAX_ENTRIES) {
    throw invalidMetadata(`contacts must be an array of 1 to ${CONTACTS_MAX_ENTRIES} strings`);
  }
  return value.map((contact) => validateDisplayString(contact, 'each contact', CONTACT_MAX_LENGTH));
}

/**
 * RFC 6749 §3.3: scope = scope-token *( SP scope-token )、
 * scope-token = 1*( %x21 / %x23-5B / %x5D-7E )。二重引用符とバックスラッシュ、
 * 空白、制御文字は使えない。
 */
const SCOPE_SYNTAX = /^[\x21\x23-\x5b\x5d-\x7e]+( [\x21\x23-\x5b\x5d-\x7e]+)*$/;

/**
 * scope: クライアントが要求してよい scope 値のスペース区切り文字列（RFC 7591 §2）。
 * 構文（RFC 6749 §3.3）を検査し、重複を 1 つに正規化した配列で返す。
 * supportedScopes があれば、一覧に無い値は拒否する。
 */
export function validateScope(value: unknown, supportedScopes: readonly string[] | undefined): string[] {
  if (typeof value !== 'string') {
    throw invalidMetadata('scope must be a space-delimited string of scope values');
  }
  if (!SCOPE_SYNTAX.test(value)) {
    throw invalidMetadata('scope must be a space-delimited string of scope values');
  }
  const scopes = [...new Set(value.split(' '))];
  if (supportedScopes !== undefined && scopes.some((scope) => !supportedScopes.includes(scope))) {
    throw invalidMetadata('scope must contain only scope values this provider supports');
  }
  return scopes;
}

/**
 * application_type: web または native（OIDC Dynamic Client Registration 1.0 §2）。
 */
export function validateApplicationType(value: unknown): 'web' | 'native' {
  if (value !== 'web' && value !== 'native') {
    throw invalidMetadata('application_type must be web or native');
  }
  return value;
}

const LOOPBACK_HOSTS = ['localhost', '127.0.0.1', '[::1]'];

/**
 * OIDC Dynamic Client Registration 1.0 §2 が application_type ごとに redirect_uris へ
 * 課す制約。
 *
 * - native: カスタム URI スキームか、http スキームのループバック URL
 *   （localhost / 127.0.0.1 / [::1]）だけを登録できる
 * - web かつ implicit grant を使う: https スキームだけを登録でき、ホスト名に
 *   localhost を使えない
 *
 * application_type を省略した登録には、core の規則（validateRegisteredRedirectUris）
 * だけが掛かる。
 */
export function validateRedirectUrisForApplicationType(
  redirectUris: readonly string[],
  applicationType: 'web' | 'native',
  grantTypes: readonly string[],
): void {
  if (applicationType === 'native') {
    for (const uri of redirectUris) {
      const url = new URL(uri);
      if (url.protocol === 'https:' || (url.protocol === 'http:' && !LOOPBACK_HOSTS.includes(url.hostname))) {
        throw invalidMetadata(
          'a native client must register custom scheme or loopback http redirect_uris only',
        );
      }
    }
    return;
  }
  if (grantTypes.includes('implicit')) {
    for (const uri of redirectUris) {
      const url = new URL(uri);
      if (url.protocol !== 'https:' || url.hostname === 'localhost') {
        throw invalidMetadata(
          'a web client using the implicit grant must register https redirect_uris that do not use localhost',
        );
      }
    }
  }
}

/**
 * default_max_age: 秒数を表す非負整数（OIDC Dynamic Client Registration 1.0 §2）。
 * core の validateDefaultMaxAge と同じ規則で、登録段階で拒否する。
 */
export function validateDefaultMaxAge(value: unknown): number {
  if (typeof value !== 'number' || !Number.isInteger(value) || value < 0) {
    throw invalidMetadata('default_max_age must be a non-negative integer');
  }
  return value;
}

/**
 * id_token_signed_response_alg / userinfo_signed_response_alg: OP が署名できる
 * アルゴリズムの一覧（通常は登録済み鍵から導いた値）に含まれる値だけを受理する。
 * none は受理しない（OIDC Dynamic Client Registration 1.0 §2）。
 */
export function validateSigningAlg(value: unknown, name: string, supported: readonly string[]): string {
  if (typeof value !== 'string' || value === 'none' || !supported.includes(value)) {
    throw invalidMetadata(`${name} must be one of ${supported.join(', ')}`);
  }
  return value;
}

const JWKS_MAX_KEYS = 16;
const KID_MAX_LENGTH = 128;
/** JWK の秘密鍵パラメータ（RFC 7518 §6.2.2 / §6.3.2 / §6.4）。公開鍵の登録には現れない。 */
const PRIVATE_JWK_MEMBERS = ['d', 'p', 'q', 'dp', 'dq', 'qi', 'oth', 'k'];
const RSA_ALGORITHMS = ['RS256', 'RS384', 'RS512'];
const EC_CURVE_ALGORITHMS: Record<string, string> = { 'P-256': 'ES256', 'P-384': 'ES384', 'P-521': 'ES512' };
const JWKS_DESCRIPTION =
  'jwks must be a JWK Set of 1 to 16 public RSA (RS256, RS384, RS512) or EC (P-256, P-384, P-521) signature keys';

/**
 * jwks: クライアントの公開鍵の JWK Set（RFC 7591 §2）。OP は署名検証にだけ使うので、
 * core が読める RSA / EC の署名用公開鍵に限る。秘密鍵パラメータを持つ鍵は拒否する。
 *
 * 返す鍵は理解するメンバーだけを選び取った新しいオブジェクトで、alg と use が無い
 * 鍵には既定（RSA は RS256、EC は曲線に対応する ES*、use は sig）を補う。
 * 補った値は登録メタデータとして応答に現れる（RFC 7591 §3.1 の「置換してよい」）。
 */
export function validateJwks(value: unknown): JwkSet {
  if (!isJsonObject(value) || !Array.isArray(value['keys'])) {
    throw invalidMetadata(JWKS_DESCRIPTION);
  }
  const keys = value['keys'];
  if (keys.length === 0 || keys.length > JWKS_MAX_KEYS) {
    throw invalidMetadata(JWKS_DESCRIPTION);
  }
  return { keys: keys.map((key) => validateJwk(key)) };
}

function validateJwk(value: unknown): Jwk {
  if (!isJsonObject(value) || (value['kty'] !== 'RSA' && value['kty'] !== 'EC')) {
    throw invalidMetadata(JWKS_DESCRIPTION);
  }
  if (PRIVATE_JWK_MEMBERS.some((member) => member in value)) {
    throw invalidMetadata('jwks must contain public keys only');
  }
  const use = value['use'];
  if (use !== undefined && use !== 'sig') {
    throw invalidMetadata(JWKS_DESCRIPTION);
  }
  const kid = value['kid'];
  if (kid !== undefined) {
    validateDisplayString(kid, 'kid of a jwks key', KID_MAX_LENGTH);
  }
  const alg = value['alg'];
  if (alg !== undefined && typeof alg !== 'string') {
    throw invalidMetadata(JWKS_DESCRIPTION);
  }
  const common = { ...(kid === undefined ? {} : { kid: kid as string }), use: 'sig' };

  if (value['kty'] === 'RSA') {
    const n = value['n'];
    const e = value['e'];
    if (typeof n !== 'string' || typeof e !== 'string') {
      throw invalidMetadata(JWKS_DESCRIPTION);
    }
    const rsaAlg = alg ?? 'RS256';
    if (!RSA_ALGORITHMS.includes(rsaAlg)) {
      throw invalidMetadata(JWKS_DESCRIPTION);
    }
    return { kty: 'RSA', ...common, alg: rsaAlg, n, e };
  }

  if (value['kty'] === 'EC') {
    const crv = value['crv'];
    const x = value['x'];
    const y = value['y'];
    if (typeof crv !== 'string' || typeof x !== 'string' || typeof y !== 'string') {
      throw invalidMetadata(JWKS_DESCRIPTION);
    }
    const curveAlg = EC_CURVE_ALGORITHMS[crv];
    if (curveAlg === undefined || (alg !== undefined && alg !== curveAlg)) {
      throw invalidMetadata(JWKS_DESCRIPTION);
    }
    return { kty: 'EC', ...common, alg: curveAlg, crv, x, y };
  }

  throw invalidMetadata(JWKS_DESCRIPTION);
}
```

### registration-request.ts (request parsing and metadata validation)

Three functions.
`parseClientRegistrationBody` checks the body size, the JSON syntax and the object shape, and splits `software_statement` from the plain metadata.
`validateClientMetadata` validates the understood fields, applies the defaults, checks the consistency of `grant_types` and `response_types`, runs the custom validators, and returns both the values the OP interprets (camelCase) and the wire form of every registered value (`metadata`).
`validateClientRegistrationRequest` chains the two and ignores software statements.
Every list of allowed values is an option; the defaults are the three auth methods core verifies, `authorization_code` with `refresh_token`, `code`, and RS256.

The defaults of omitted fields are written into the registered metadata: `token_endpoint_auth_method`, `grant_types` and `response_types` of RFC 7591 §2, and `application_type` (`web`) and `id_token_signed_response_alg` (`RS256`) of OIDC Dynamic Client Registration 1.0 §2.
Its §3.2 requires the AS to include the defaults it applied in the response.
The `redirect_uris` constraints per `application_type` are checked for an omitted type as `web` too.
Its §2 requires the AS to verify that every registered `redirect_uris` value conforms, so a web client using the implicit grant can register only https URIs that are not `localhost`.

```typescript
/**
 * OAuth 2.0 Dynamic Client Registration (RFC 7591) — 登録リクエストの解析と
 * メタデータの検証。
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * §3.1: 登録リクエストのボディは application/json の JSON オブジェクト。
 * Content-Type の検査は HTTP を知る生成コード側の責務で、ここはパース前の
 * ボディ文字列を受け取る。処理は責務ごとの関数に分かれている。
 *
 * 1. parseClientRegistrationBody: ボディ長・JSON・オブジェクト形式の検査。
 *    software_statement（RFC 7591 §2.3）を平文のメタデータから切り離す
 * 2. （software-statement.ts）OP の設定に渡した検証関数で statement を検証し、
 *    applySoftwareStatement で主張されたメタデータを平文の値へ優先して重ねる
 * 3. validateClientMetadata: 理解するフィールドの値検査と既定値の適用、
 *    grant_types と response_types の整合検査、カスタムメタデータの検証
 *
 * validateClientRegistrationRequest は 1 と 3 を直結した短縮形で、
 * software_statement は検証せず無視する（RFC 7591 §3.1.1 は対応しない AS が
 * 無視することを許す）。
 */

import {
  normalizeResponseType,
  responseTypeIncludes,
  validateRegisteredRedirectUris,
  type JwkSet,
} from '@maronn-openid-connect/core';
import {
  defineOwnProperty,
  isJsonObject,
  validateApplicationType,
  validateContacts,
  validateDefaultMaxAge,
  validateDisplayString,
  validateHttpUrl,
  validateJwks,
  validateRedirectUrisForApplicationType,
  validateScope,
  validateSigningAlg,
} from './metadata-values.js';
import { ClientRegistrationError } from './registration-error.js';

/** parseClientRegistrationBody が読み取った登録リクエスト。 */
export interface ParsedClientRegistration {
  /** 平文の JSON メタデータ。software_statement は含まない。 */
  metadata: Record<string, unknown>;
  /** リクエストが software_statement メンバーを持っていたときの、その JWT 文字列。 */
  softwareStatement?: string;
}

export interface ParseClientRegistrationBodyOptions {
  /**
   * ボディ（パース前の文字列）の UTF-8 バイト長の上限。既定 16384。
   * 文字列長（UTF-16 コード単位数）ではなく TextEncoder で得たバイト長で
   * 判定し、多バイト文字を含む境界値テストを決定的にする。
   */
  maxBodyBytes?: number;
}

const DEFAULT_MAX_BODY_BYTES = 16384;

/**
 * 登録リクエストボディ（文字列）を読み取る。
 *
 * ボディ長、JSON 構文、オブジェクト形式を検査し、software_statement メンバー
 * （RFC 7591 §3.1.1 は JWT の文字列と定める。文字列でなければ
 * invalid_software_statement）を平文のメタデータから切り離して返す。文字列の
 * 中身は見ない。検証は OP の設定に渡した関数の責務である。返す metadata は
 * パース結果そのものではなく、software_statement 以外の自身のプロパティを
 * 選び取った新しいオブジェクトである。
 */
export function parseClientRegistrationBody(
  rawBody: string,
  options?: ParseClientRegistrationBodyOptions,
): ParsedClientRegistration {
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
    throw new ClientRegistrationError('invalid_client_metadata', 'request body must be valid JSON');
  }
  if (!isJsonObject(parsed)) {
    throw new ClientRegistrationError('invalid_client_metadata', 'request body must be a JSON object');
  }

  const metadata: Record<string, unknown> = {};
  for (const [name, value] of Object.entries(parsed)) {
    if (name === 'software_statement') continue;
    defineOwnProperty(metadata, name, value);
  }
  const softwareStatement = parsed['software_statement'];
  if (softwareStatement === undefined) {
    return { metadata };
  }
  if (typeof softwareStatement !== 'string') {
    throw new ClientRegistrationError('invalid_software_statement', 'software_statement must be a string');
  }
  return { metadata, softwareStatement };
}

/**
 * カスタムメタデータ 1 項目の検証関数。
 *
 * リクエストの値（無ければ undefined）とリクエストの全メタデータを受け取り、
 * 登録する値を返す。undefined を返した項目は登録しない（省略時の既定値を
 * 返せば、既定値として登録される）。拒否するときは ClientRegistrationError を
 * 投げる。返した値は登録メタデータとして 201 応答に現れる。
 */
export type CustomClientMetadataValidator = (
  value: unknown,
  metadata: Readonly<Record<string, unknown>>,
) => unknown;

export interface ValidateClientMetadataOptions {
  /**
   * 登録できる token_endpoint_auth_method（RFC 7591 §2）。既定は core が検証
   * できる client_secret_basic / client_secret_post / none。private_key_jwt の
   * ように OP 側で認証手段を足した方式は、ここに加えて登録できるようにする。
   */
  tokenEndpointAuthMethods?: readonly string[];
  /**
   * 登録できる grant_type。既定は authorization_code と refresh_token。OP が
   * 答える grant（implicit、experimental grant の URN）はここで広げる。
   */
  grantTypes?: readonly string[];
  /**
   * 登録できる response_type（normalizeResponseType の形）。既定は code のみ。
   * Implicit Flow / Hybrid Flow を持つ OP は、discovery の response_types_supported
   * と同じ一覧を渡す。
   */
  responseTypes?: readonly string[];
  /**
   * 登録できる scope 値。省略時は構文（RFC 6749 §3.3）だけを検査し、どの値も
   * 受理する。
   */
  scopes?: readonly string[];
  /**
   * id_token_signed_response_alg に受理する alg。既定は RS256 のみ。省略時の
   * 既定値 RS256（OIDC Dynamic Client Registration 1.0 §2）もこの一覧に照合する
   * ので、RS256 で署名できない OP は省略した登録を拒否する。
   */
  idTokenSigningAlgValuesSupported?: readonly string[];
  /** userinfo_signed_response_alg に受理する alg。既定は RS256 のみ。 */
  userinfoSigningAlgValuesSupported?: readonly string[];
  /**
   * カスタムメタデータ。キーがメタデータ名、値がその検証関数。標準フィールド
   * （本モジュールが理解する名前）と同じ名前は設定の誤りとして TypeError になる。
   */
  customMetadata?: Readonly<Record<string, CustomClientMetadataValidator>>;
}

/**
 * 検証済み登録メタデータ（RFC 7591 §2 / OIDC Dynamic Client Registration 1.0 §2
 * の既定値適用後）。
 */
export interface ValidatedClientRegistration {
  redirectUris: string[];
  tokenEndpointAuthMethod: string;
  grantTypes: string[];
  responseTypes: string[];
  /** OIDC Dynamic Client Registration 1.0 §2 の application_type。省略時の既定は web。 */
  applicationType: 'web' | 'native';
  /** RFC 7591 §2 の scope。登録したときだけ持つ（core の ClientInfo.scope と同じ意味）。 */
  scope?: string[];
  /** OIDC Dynamic Client Registration 1.0 §2 の default_max_age。登録したときだけ持つ。 */
  defaultMaxAge?: number;
  /** OIDC Dynamic Client Registration 1.0 §2 の id_token_signed_response_alg。省略時の既定は RS256。 */
  idTokenSignedResponseAlg: string;
  /** userinfo_signed_response_alg。登録したときだけ持つ（無ければ UserInfo は署名しない JSON）。 */
  userinfoSignedResponseAlg?: string;
  /** RFC 7591 §2 の jwks（正規化済み）。登録したときだけ持つ。 */
  jwks?: JwkSet;
  /**
   * 登録した全メタデータの RFC 7591 のワイヤ形式（スネークケース）。既定値の
   * 適用後の値、software_statement、カスタムメタデータを含み、201 応答の
   * 発行値以外のメンバーそのものになる。
   */
  metadata: Record<string, unknown>;
}

/** 本機能の既定で理解する auth method（RFC 7591 §2 のうち core が検証する secret 系と none）。 */
export const DEFAULT_TOKEN_ENDPOINT_AUTH_METHODS: readonly string[] = [
  'client_secret_basic',
  'client_secret_post',
  'none',
];

/** 既定で登録できる grant_type。 */
export const DEFAULT_GRANT_TYPES: readonly string[] = ['authorization_code', 'refresh_token'];

/** 既定で登録できる response_type。 */
export const DEFAULT_RESPONSE_TYPES: readonly string[] = ['code'];

const DEFAULT_SIGNING_ALGS: readonly string[] = ['RS256'];

/**
 * 本モジュールが理解するメタデータ名。カスタムメタデータの名前は、ここと
 * 重ならないことを validateClientMetadata が確かめる。
 */
export const STANDARD_CLIENT_METADATA_NAMES: readonly string[] = [
  'redirect_uris',
  'token_endpoint_auth_method',
  'grant_types',
  'response_types',
  'client_name',
  'client_uri',
  'logo_uri',
  'tos_uri',
  'policy_uri',
  'contacts',
  'scope',
  'software_id',
  'software_version',
  'application_type',
  'jwks',
  'jwks_uri',
  'default_max_age',
  'id_token_signed_response_alg',
  'userinfo_signed_response_alg',
  'software_statement',
];

const CLIENT_NAME_MAX_LENGTH = 128;
const SOFTWARE_ID_MAX_LENGTH = 128;
const SOFTWARE_VERSION_MAX_LENGTH = 64;

/**
 * 登録メタデータを検証し、既定値を適用して返す。
 *
 * 既定値は RFC 7591 §2（token_endpoint_auth_method、grant_types、response_types）と
 * OIDC Dynamic Client Registration 1.0 §2（application_type、
 * id_token_signed_response_alg）のもので、AS が適用した既定値は応答に含めなければ
 * ならない（同 §3.2 MUST）ため、どれも登録メタデータ（metadata）に書き込む。
 *
 * 未知フィールドは黙って捨てる（RFC 7591 §2 MUST ignore）。実装は「理解する
 * フィールドだけを新しいオブジェクトへ選び取る」allowlist-pick 方式で、
 * パース結果のスプレッドや Object.assign によるコピーをしない。`__proto__`
 * などプロトタイプ経路のキーを持つ入力は、読まれないまま不活性に落ちる。
 *
 * metadata に software_statement があれば、それは検証済みの JWT として扱い
 * （applySoftwareStatement が置く）、応答へそのまま返す。
 *
 * 失敗時は ClientRegistrationError を投げる。
 */
export function validateClientMetadata(
  metadata: Readonly<Record<string, unknown>>,
  options?: ValidateClientMetadataOptions,
): ValidatedClientRegistration {
  const tokenEndpointAuthMethods = options?.tokenEndpointAuthMethods ?? DEFAULT_TOKEN_ENDPOINT_AUTH_METHODS;
  const grantTypesSupported = options?.grantTypes ?? DEFAULT_GRANT_TYPES;
  const responseTypesSupported = options?.responseTypes ?? DEFAULT_RESPONSE_TYPES;

  const redirectUris = validateRedirectUris(metadata['redirect_uris']);
  const tokenEndpointAuthMethod = validateTokenEndpointAuthMethod(
    metadata['token_endpoint_auth_method'],
    tokenEndpointAuthMethods,
  );
  const grantTypes = validateGrantTypes(metadata['grant_types'], grantTypesSupported);
  const responseTypes = validateResponseTypes(metadata['response_types'], responseTypesSupported);
  validateGrantAndResponseTypeConsistency(grantTypes, responseTypes);
  // OIDC Dynamic Client Registration 1.0 §2: application_type は省略時 web。
  // AS は登録するすべての redirect_uris がその種別の制約（web で implicit grant を
  // 使うなら https かつ localhost 以外、native ならカスタムスキームかループバックの
  // http）に従うことを確かめなければならない（MUST）ので、省略時も web として検査する。
  const applicationType = validateApplicationType(
    metadata['application_type'] === undefined ? 'web' : metadata['application_type'],
  );
  validateRedirectUrisForApplicationType(redirectUris, applicationType, grantTypes);
  // OIDC Dynamic Client Registration 1.0 §2: id_token_signed_response_alg は省略時
  // RS256。既定値も OP が署名できる alg の一覧に照合する。
  const idTokenSignedResponseAlg = validateSigningAlg(
    metadata['id_token_signed_response_alg'] === undefined ? 'RS256' : metadata['id_token_signed_response_alg'],
    'id_token_signed_response_alg',
    options?.idTokenSigningAlgValuesSupported ?? DEFAULT_SIGNING_ALGS,
  );

  const registered: Record<string, unknown> = {
    redirect_uris: [...redirectUris],
    token_endpoint_auth_method: tokenEndpointAuthMethod,
    grant_types: [...grantTypes],
    response_types: [...responseTypes],
    application_type: applicationType,
  };
  const validated: ValidatedClientRegistration = {
    redirectUris,
    tokenEndpointAuthMethod,
    grantTypes,
    responseTypes,
    applicationType,
    idTokenSignedResponseAlg,
    metadata: registered,
  };

  if (metadata['client_name'] !== undefined) {
    registered['client_name'] = validateDisplayString(metadata['client_name'], 'client_name', CLIENT_NAME_MAX_LENGTH);
  }
  for (const name of ['client_uri', 'logo_uri', 'tos_uri', 'policy_uri']) {
    if (metadata[name] !== undefined) {
      registered[name] = validateHttpUrl(metadata[name], name);
    }
  }
  if (metadata['contacts'] !== undefined) {
    registered['contacts'] = validateContacts(metadata['contacts']);
  }
  if (metadata['scope'] !== undefined) {
    const scope = validateScope(metadata['scope'], options?.scopes);
    validated.scope = scope;
    registered['scope'] = scope.join(' ');
  }
  if (metadata['software_id'] !== undefined) {
    registered['software_id'] = validateDisplayString(metadata['software_id'], 'software_id', SOFTWARE_ID_MAX_LENGTH);
  }
  if (metadata['software_version'] !== undefined) {
    registered['software_version'] = validateDisplayString(
      metadata['software_version'],
      'software_version',
      SOFTWARE_VERSION_MAX_LENGTH,
    );
  }
  if (metadata['jwks'] !== undefined && metadata['jwks_uri'] !== undefined) {
    // RFC 7591 §2: jwks_uri と jwks を同時に使ってはならない。jwks_uri 単独は
    // この OP が取得しに行かない（理解しない）メタデータとして無視する。
    throw new ClientRegistrationError('invalid_client_metadata', 'jwks and jwks_uri must not both be present');
  }
  if (metadata['jwks'] !== undefined) {
    const jwks = validateJwks(metadata['jwks']);
    validated.jwks = jwks;
    registered['jwks'] = { keys: jwks.keys.map((key) => ({ ...key })) };
  }
  if (metadata['default_max_age'] !== undefined) {
    const defaultMaxAge = validateDefaultMaxAge(metadata['default_max_age']);
    validated.defaultMaxAge = defaultMaxAge;
    registered['default_max_age'] = defaultMaxAge;
  }
  registered['id_token_signed_response_alg'] = idTokenSignedResponseAlg;
  if (metadata['userinfo_signed_response_alg'] !== undefined) {
    const alg = validateSigningAlg(
      metadata['userinfo_signed_response_alg'],
      'userinfo_signed_response_alg',
      options?.userinfoSigningAlgValuesSupported ?? DEFAULT_SIGNING_ALGS,
    );
    validated.userinfoSignedResponseAlg = alg;
    registered['userinfo_signed_response_alg'] = alg;
  }
  if (metadata['software_statement'] !== undefined) {
    // RFC 7591 §3.2.1: 登録に使った software_statement は、そのまま応答に返す。
    const softwareStatement = metadata['software_statement'];
    if (typeof softwareStatement !== 'string') {
      throw new ClientRegistrationError('invalid_software_statement', 'software_statement must be a string');
    }
    registered['software_statement'] = softwareStatement;
  }

  for (const [name, validate] of Object.entries(options?.customMetadata ?? {})) {
    if (STANDARD_CLIENT_METADATA_NAMES.includes(name)) {
      throw new TypeError(`custom client metadata must not redefine the standard field ${name}`);
    }
    const value = validate(metadata[name], metadata);
    if (value !== undefined) {
      defineOwnProperty(registered, name, value);
    }
  }

  return validated;
}

export interface ValidateClientRegistrationOptions
  extends ParseClientRegistrationBodyOptions,
    ValidateClientMetadataOptions {}

/**
 * 登録リクエストボディ（文字列）を検証し、既定値を適用して返す短縮形。
 *
 * parseClientRegistrationBody と validateClientMetadata を直結し、
 * software_statement は検証せずに無視する（RFC 7591 §3.1.1）。software statement
 * を受け付ける OP は、両関数の間に設定の検証関数と applySoftwareStatement
 * （software-statement.ts）を挟む。
 */
export function validateClientRegistrationRequest(
  rawBody: string,
  options?: ValidateClientRegistrationOptions,
): ValidatedClientRegistration {
  const { metadata } = parseClientRegistrationBody(rawBody, options);
  return validateClientMetadata(metadata, options);
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
  if (!Array.isArray(value) || value.length === 0 || !value.every((uri) => typeof uri === 'string')) {
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
function validateTokenEndpointAuthMethod(value: unknown, supported: readonly string[]): string {
  if (value === undefined) {
    return 'client_secret_basic';
  }
  if (typeof value !== 'string' || !supported.includes(value)) {
    throw new ClientRegistrationError(
      'invalid_client_metadata',
      `token_endpoint_auth_method must be one of ${supported.join(', ')}`,
    );
  }
  return value;
}

/**
 * grant_types: OPTIONAL、既定 ["authorization_code"]（RFC 7591 §2）。
 * supported に無い値は拒否する。重複は 1 つに正規化し、出現順を保つ。
 */
function validateGrantTypes(value: unknown, supported: readonly string[]): string[] {
  if (value === undefined) {
    return ['authorization_code'];
  }
  if (!Array.isArray(value) || !value.every((grantType) => typeof grantType === 'string' && supported.includes(grantType))) {
    throw new ClientRegistrationError(
      'invalid_client_metadata',
      `grant_types must be an array containing only ${supported.join(', ')}`,
    );
  }
  return [...new Set(value as string[])];
}

/**
 * response_types: OPTIONAL、既定 ["code"]（RFC 7591 §2）。値は空白区切りで
 * 順序を問わないので（OAuth 2.0 Multiple Response Type Encoding Practices §1.2）、
 * core の normalizeResponseType で並べ直してから supported と照合し、重複を
 * 1 つに正規化する。
 */
function validateResponseTypes(value: unknown, supported: readonly string[]): string[] {
  if (value === undefined) {
    return ['code'];
  }
  const normalizedSupported = supported.map((responseType) => normalizeResponseType(responseType));
  if (
    !Array.isArray(value) ||
    value.length === 0 ||
    !value.every(
      (responseType) =>
        typeof responseType === 'string' && normalizedSupported.includes(normalizeResponseType(responseType)),
    )
  ) {
    throw new ClientRegistrationError(
      'invalid_client_metadata',
      `response_types must be a non-empty array containing only ${normalizedSupported.join(', ')}`,
    );
  }
  return [...new Set((value as string[]).map((responseType) => normalizeResponseType(responseType)))];
}

/**
 * RFC 7591 §2.1 / OIDC Dynamic Client Registration 1.0 §2: grant_types と
 * response_types の対応。code を含む response_type は authorization_code grant を、
 * token か id_token を含む response_type は implicit grant を要し、逆に登録した
 * これらの grant には対応する response_type が要る。矛盾した登録は
 * invalid_client_metadata で拒否し、使えない組み合わせを登録させない（§2.1 SHOULD）。
 */
function validateGrantAndResponseTypeConsistency(grantTypes: readonly string[], responseTypes: readonly string[]): void {
  const usesCode = responseTypes.some((responseType) => responseTypeIncludes(responseType, 'code'));
  const usesImplicit = responseTypes.some(
    (responseType) => responseTypeIncludes(responseType, 'token') || responseTypeIncludes(responseType, 'id_token'),
  );
  const consistent =
    usesCode === grantTypes.includes('authorization_code') && usesImplicit === grantTypes.includes('implicit');
  if (!consistent) {
    throw new ClientRegistrationError(
      'invalid_client_metadata',
      'grant_types and response_types must be consistent: code requires authorization_code, token and id_token require implicit',
    );
  }
}
```

### software-statement.ts (application of software statements)

The feature verifies no statement.
`VerifiedSoftwareStatement` is the return type of the verifier function supplied through the OP's config; it holds only the metadata the statement asserts.
`applySoftwareStatement` lays those claims over the plain metadata and keeps the statement as the `software_statement` member (RFC 7591 §3.1.1 / §3.2.1).
Any JWT claim left among them is ignored by `validateClientMetadata` as metadata it does not understand.

```typescript
/**
 * OAuth 2.0 Dynamic Client Registration (RFC 7591) — software statement
 * （§2.3 / §3.1.1）の適用。
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * software statement は、ソフトウェアの発行者が署名した JWT で、クライアント
 * メタデータの集合をひとまとめに主張する。どの発行者を信頼し、どう署名を
 * 確かめるかは RFC 7591 の対象外で（§2.3「信頼の基準は本仕様の範囲外」）、
 * 本機能は検証を持たない。検証は OP の設定に渡した関数の責務で、その関数が
 * 返した主張（VerifiedSoftwareStatement）を applySoftwareStatement が平文の
 * メタデータへ優先して重ねる（§3.1.1 MUST）。検証関数が無い OP は statement
 * を無視する（§3.1.1 は対応しない AS が無視することを許す）。
 */

import { defineOwnProperty } from './metadata-values.js';

/**
 * 検証に成功した software statement。OP の設定に渡した検証関数が返す。
 *
 * metadata は、statement が主張するクライアントメタデータ。ここに残した
 * JWT の標準クレーム（iss / exp など）は validateClientMetadata が理解しない
 * メタデータとして無視するので、取り除く必要はない。RFC 7591 が statement
 * の中身に定める必須項目は無く、本機能も中身を検査しない。
 */
export interface VerifiedSoftwareStatement {
  metadata: Record<string, unknown>;
}

/**
 * 検証済み software statement のメタデータを、平文のメタデータへ適用する。
 *
 * RFC 7591 §3.1.1: software statement のメタデータは平文の同名メタデータに優先する。
 * 返すオブジェクトは software_statement メンバーに元の JWT 文字列を持ち、
 * validateClientMetadata がそれを応答へ返す（§3.2.1 の MUST）。statement の
 * 中に software_statement という名のクレームがあっても、外側の JWT 文字列が勝つ。
 */
export function applySoftwareStatement(
  metadata: Readonly<Record<string, unknown>>,
  softwareStatement: string,
  verified: VerifiedSoftwareStatement,
): Record<string, unknown> {
  const merged: Record<string, unknown> = {};
  for (const [name, value] of Object.entries(metadata)) {
    if (name === 'software_statement') continue;
    defineOwnProperty(merged, name, value);
  }
  for (const [name, value] of Object.entries(verified.metadata)) {
    defineOwnProperty(merged, name, value);
  }
  merged['software_statement'] = softwareStatement;
  return merged;
}
```

### registered-client.ts (record and 201 response building)

Pure functions for the issued values and the shape of the §3.2.1 response.
`DynamicallyRegisteredClient` carries the fields core interprets under the names of the generated `RegisteredClient`, plus `metadata`, the wire form of every registered value.
A `client_secret` is minted only for the methods of `clientSecretAuthMethods` (the three secret-based ones by default).
The response is the issued values followed by `metadata` as it is.

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

import { generateRandomString, type JwkSet } from '@maronn-openid-connect/core';
import type { ValidatedClientRegistration } from './registration-request.js';

/**
 * 発行値を含む登録レコード。
 *
 * core が解釈するフィールド（clientId / clientSecret / clientType / redirectUris /
 * grantTypes / responseTypes / tokenEndpointAuthMethods / scope / defaultMaxAge /
 * idTokenSignedResponseAlg / userinfoSignedResponseAlg）は生成コードの
 * RegisteredClient 型（core の ClientInfo & TokenClientInfo を合成した型）と同じ
 * 名前で持つ。jwks は生成コードが ClientKeyResolver の用途別の鍵へ写す。
 * metadata は登録した全メタデータのワイヤ形式で、201 応答の組み立てと、
 * client_name や logo_uri、カスタムメタデータを後から読むために保持する。
 *
 * tokenEndpointAuthMethods は、登録した token_endpoint_auth_method（RFC 7591 §2 は 1 つ）を
 * core の TokenClientInfo.tokenEndpointAuthMethods と同じ一覧の形で持つ。
 */
export interface DynamicallyRegisteredClient {
  clientId: string;
  clientSecret?: string;
  clientType: 'confidential' | 'public';
  redirectUris: string[];
  grantTypes: string[];
  responseTypes: string[];
  tokenEndpointAuthMethods: [string];
  scope?: string[];
  defaultMaxAge?: number;
  /**
   * 登録した id_token_signed_response_alg。buildRegisteredClient は省略時の既定
   * RS256（OIDC Dynamic Client Registration 1.0 §2）を含めて必ず持たせる。
   * ほかで組み立てたレコードが欠くときも、core は RS256 として扱う。
   */
  idTokenSignedResponseAlg?: string;
  userinfoSignedResponseAlg?: string;
  jwks?: JwkSet;
  clientIdIssuedAt: number;
  metadata: Record<string, unknown>;
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
  /**
   * client_secret で認証する token_endpoint_auth_method。これらを登録した
   * クライアントにだけ client_secret を発行する。既定は client_secret_basic /
   * client_secret_post / client_secret_jwt。
   */
  clientSecretAuthMethods?: readonly string[];
}

/**
 * client_id の固定プレフィックス。静的クライアントの client_id は人間が
 * 命名する（例: example-client）ため、このプレフィックスで名前空間が分かれ、
 * 既存クライアントとの衝突・上書きが構造的に起きない。client_id は秘密情報
 * ではないので、動的登録由来であることを明かしても失うものはない。
 */
const CLIENT_ID_PREFIX = 'dcr-';

/** RFC 7591 §2 のうち client_secret を使う認証方式。 */
export const CLIENT_SECRET_AUTH_METHODS: readonly string[] = [
  'client_secret_basic',
  'client_secret_post',
  'client_secret_jwt',
];

/**
 * 検証済みメタデータから登録レコードを組み立てる。
 *
 * token_endpoint_auth_method が none のクライアントはシークレットを持てない
 * （RFC 6749 §2.1 の public client）ため、clientType: 'public' とする。それ以外は
 * confidential で、client_secret で認証する方式（clientSecretAuthMethods）にだけ
 * 256 ビットのシークレットを発行する。private_key_jwt のように鍵で認証する方式は
 * confidential だがシークレットを持たない。
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
  const clientSecretAuthMethods = options?.clientSecretAuthMethods ?? CLIENT_SECRET_AUTH_METHODS;

  const isPublic = metadata.tokenEndpointAuthMethod === 'none';
  const issuesSecret = clientSecretAuthMethods.includes(metadata.tokenEndpointAuthMethod);
  return {
    clientId: generateClientId(),
    ...(issuesSecret ? { clientSecret: generateClientSecret() } : {}),
    clientType: isPublic ? 'public' : 'confidential',
    redirectUris: [...metadata.redirectUris],
    grantTypes: [...metadata.grantTypes],
    responseTypes: [...metadata.responseTypes],
    tokenEndpointAuthMethods: [metadata.tokenEndpointAuthMethod],
    ...(metadata.scope === undefined ? {} : { scope: [...metadata.scope] }),
    ...(metadata.defaultMaxAge === undefined ? {} : { defaultMaxAge: metadata.defaultMaxAge }),
    idTokenSignedResponseAlg: metadata.idTokenSignedResponseAlg,
    ...(metadata.userinfoSignedResponseAlg === undefined
      ? {}
      : { userinfoSignedResponseAlg: metadata.userinfoSignedResponseAlg }),
    ...(metadata.jwks === undefined ? {} : { jwks: { keys: metadata.jwks.keys.map((key) => ({ ...key })) } }),
    clientIdIssuedAt: Math.floor(now() / 1000),
    metadata: { ...metadata.metadata },
  };
}

/**
 * 201 応答ボディ（RFC 7591 §3.2.1。スネークケースの JSON オブジェクト）を
 * 組み立てる。§3.2.1 は「登録済みの全メタデータを返す MUST」なので、発行値の
 * 後に登録メタデータ（既定値適用後の値、software_statement、カスタム
 * メタデータを含む）をすべて載せる。client_secret_expires_at は client_secret を
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
    ...client.metadata,
  };
}
```

### bearer-token.ts (reading the Bearer token)

Reads the token of an RFC 6750 §2.1 Bearer header.
A missing header, another scheme or a malformed value yields `undefined`, which the generated code answers with the bare 401 challenge ("no token presented").
Whether the token is acceptable is for the configured function to decide.

```typescript
/**
 * OAuth 2.0 Bearer Token Usage (RFC 6750) — Authorization ヘッダの読み取り。
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * 登録エンドポイントの initial access token（OIDC Dynamic Client Registration
 * 1.0 §3）は Bearer トークンとして送られる。本機能はトークンの検証を持たず、
 * ヘッダからトークンを読み取ることだけを提供する。トークンが正しいかの判定は
 * OP の設定に渡した関数の責務で、この関数の返り値がその入力になる。
 */

/**
 * RFC 6750 §2.1: `credentials = "Bearer" 1*SP b64token`。
 * b64token は ALPHA / DIGIT / "-" / "." / "_" / "~" / "+" / "/" と末尾の "="。
 * スキーム名は HTTP の認証スキームとして大文字小文字を区別しない（RFC 9110 §11.1）。
 */
const BEARER_HEADER = /^Bearer +([A-Za-z0-9\-._~+/]+=*)$/i;

/**
 * Authorization ヘッダの Bearer トークンを返す。
 *
 * ヘッダが無い（undefined / null）、Bearer 以外のスキーム、形式不正のときは
 * undefined を返し、「トークンの提示なし」として扱う（RFC 6750 §3.1 は、認証
 * 情報を持たない要求にエラーコードを付けないことを求める）。
 */
export function readBearerToken(authorizationHeader: string | null | undefined): string | undefined {
  if (authorizationHeader === undefined || authorizationHeader === null) {
    return undefined;
  }
  const match = BEARER_HEADER.exec(authorizationHeader);
  return match ? (match[1] as string) : undefined;
}
```

### index.ts (public API)

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
 * このモジュールは「登録リクエストの解析・software statement の適用・
 * 登録メタデータの検証と既定値適用・登録レコードと 201 応答の組み立て・
 * Authorization ヘッダの Bearer トークンの読み取り」だけを持つ純関数群で、
 * HTTP にもストアにも触れない。`redirect_uris` の検査規則、response_type の
 * 正規化、乱数生成は core 公開 API（validateRegisteredRedirectUris /
 * normalizeResponseType / generateRandomString）を使い、クライアントの保存・
 * 総数上限・Content-Type 検査・登録できる値の一覧の決定は生成コード側の
 * 責務のまま変えない。
 *
 * initial access token と software statement の検証は持たない。どちらも
 * RFC 7591 が検証の基準を定めないもので、OP の設定に渡した関数の責務である。
 * 生成コードは、関数が設定されているときだけ対応する値（Bearer トークン、
 * software_statement）の提示を要求し、無ければ要求しない。
 *
 * スコープ外（非目標）: RFC 7592（登録後の参照・更新・削除、
 * registration_access_token / registration_client_uri はどちらも返さない）、
 * initial access token と software statement の発行と検証、URL 参照系
 * メタデータ（jwks_uri / sector_identifier_uri など）の取得。
 */
export {
  ClientRegistrationError,
  isClientRegistrationError,
  type ClientRegistrationErrorCode,
} from './registration-error.js';

export {
  parseClientRegistrationBody,
  validateClientMetadata,
  validateClientRegistrationRequest,
  DEFAULT_TOKEN_ENDPOINT_AUTH_METHODS,
  DEFAULT_GRANT_TYPES,
  DEFAULT_RESPONSE_TYPES,
  STANDARD_CLIENT_METADATA_NAMES,
  type CustomClientMetadataValidator,
  type ParseClientRegistrationBodyOptions,
  type ParsedClientRegistration,
  type ValidateClientMetadataOptions,
  type ValidateClientRegistrationOptions,
  type ValidatedClientRegistration,
} from './registration-request.js';

export { applySoftwareStatement, type VerifiedSoftwareStatement } from './software-statement.js';

export {
  buildRegisteredClient,
  buildClientRegistrationResponse,
  CLIENT_SECRET_AUTH_METHODS,
  type BuildRegisteredClientOptions,
  type DynamicallyRegisteredClient,
} from './registered-client.js';

export { readBearerToken } from './bearer-token.js';
```

## Unit tests, in full

The tests were written first, TDD style.
The `jwks` tests build an RSA key pair with the test-only fixture (`test-helpers.ts`) and register its public key as metadata.

### registration-request.test.ts

```typescript
import { describe, expect, it } from 'vitest';
import { ClientRegistrationError, isClientRegistrationError } from './registration-error.js';
import {
  parseClientRegistrationBody,
  validateClientMetadata,
  validateClientRegistrationRequest,
} from './registration-request.js';
import { generateTestRs256Key } from './test-helpers.js';

function body(metadata: Record<string, unknown>): string {
  return JSON.stringify(metadata);
}

const MINIMAL = { redirect_uris: ['https://app.example.com/cb'] };

/**
 * 既定値だけが適用された最小登録の検証結果。RFC 7591 §2 の 3 つの既定値と、
 * OIDC Dynamic Client Registration 1.0 §2 の application_type（web）と
 * id_token_signed_response_alg（RS256）は、登録メタデータとして応答に現れる。
 */
const MINIMAL_VALIDATED = {
  redirectUris: ['https://app.example.com/cb'],
  tokenEndpointAuthMethod: 'client_secret_basic',
  grantTypes: ['authorization_code'],
  responseTypes: ['code'],
  applicationType: 'web',
  idTokenSignedResponseAlg: 'RS256',
  metadata: {
    redirect_uris: ['https://app.example.com/cb'],
    token_endpoint_auth_method: 'client_secret_basic',
    grant_types: ['authorization_code'],
    response_types: ['code'],
    application_type: 'web',
    id_token_signed_response_alg: 'RS256',
  },
};

describe('parseClientRegistrationBody', () => {
  describe('request body shape', () => {
    it('should return the metadata of a JSON object body', () => {
      expect(parseClientRegistrationBody(body(MINIMAL))).toEqual({ metadata: MINIMAL });
    });

    it('should reject a body that is not valid JSON', () => {
      expect(() => parseClientRegistrationBody('not json')).toThrowError(
        new ClientRegistrationError('invalid_client_metadata', 'request body must be valid JSON'),
      );
    });

    it('should reject a JSON array body', () => {
      expect(() => parseClientRegistrationBody('[]')).toThrowError(
        new ClientRegistrationError('invalid_client_metadata', 'request body must be a JSON object'),
      );
    });

    it('should reject a JSON primitive body', () => {
      expect(() => parseClientRegistrationBody('"redirect_uris"')).toThrowError(
        new ClientRegistrationError('invalid_client_metadata', 'request body must be a JSON object'),
      );
    });

    it('should reject a JSON null body', () => {
      expect(() => parseClientRegistrationBody('null')).toThrowError(
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
      const { metadata } = parseClientRegistrationBody(rawBody, { maxBodyBytes: limit });
      expect(metadata['client_name']).toBe('あ'.repeat(multiByteChars));
    });

    it('should reject a body one byte over the limit', () => {
      const fixedBytes = new TextEncoder().encode(base + suffix).length;
      const multiByteChars = 8;
      const limit = fixedBytes + multiByteChars * 3 - 1;
      const rawBody = base + 'あ'.repeat(multiByteChars) + suffix;
      expect(() => parseClientRegistrationBody(rawBody, { maxBodyBytes: limit })).toThrowError(
        new ClientRegistrationError(
          'invalid_client_metadata',
          'request body must not exceed the configured maximum size',
        ),
      );
    });
  });

  describe('software_statement (RFC 7591 Section 2.3)', () => {
    it('should split the software_statement from the plain metadata', () => {
      const parsed = parseClientRegistrationBody(
        body({ ...MINIMAL, software_statement: 'eyJhbGciOiJSUzI1NiJ9.e30.sig' }),
      );
      expect(parsed).toEqual({
        metadata: MINIMAL,
        softwareStatement: 'eyJhbGciOiJSUzI1NiJ9.e30.sig',
      });
    });

    // RFC 7591 §3.1.1 defines the member as a JWT string; its content is for the verifier of the OP.
    it('should reject a software_statement that is not a string with invalid_software_statement', () => {
      expect(() => parseClientRegistrationBody(body({ ...MINIMAL, software_statement: { iss: 'x' } }))).toThrowError(
        new ClientRegistrationError('invalid_software_statement', 'software_statement must be a string'),
      );
    });

    it('should hand any string through unexamined, an empty one included', () => {
      expect(parseClientRegistrationBody(body({ ...MINIMAL, software_statement: '' }))).toEqual({
        metadata: MINIMAL,
        softwareStatement: '',
      });
      expect(parseClientRegistrationBody(body({ ...MINIMAL, software_statement: 'not-a-jwt' }))).toEqual({
        metadata: MINIMAL,
        softwareStatement: 'not-a-jwt',
      });
    });
  });

  it('should copy the own properties of the body instead of returning the parsed object', () => {
    const parsed = parseClientRegistrationBody(
      '{"redirect_uris":["https://app.example.com/cb"],"__proto__":{"polluted":true}}',
    );
    expect(Object.getPrototypeOf(parsed.metadata)).toBe(Object.prototype);
    expect(({} as Record<string, unknown>)['polluted']).toBe(undefined);
  });
});

describe('validateClientMetadata', () => {
  describe('defaults (RFC 7591 Section 2)', () => {
    it('should apply every default to a minimal registration', () => {
      expect(validateClientMetadata(MINIMAL)).toEqual(MINIMAL_VALIDATED);
    });

    it('should keep every explicitly registered value and echo it in the metadata', () => {
      const validated = validateClientMetadata({
        redirect_uris: ['https://app.example.com/cb', 'http://127.0.0.1:8080/cb'],
        token_endpoint_auth_method: 'client_secret_post',
        grant_types: ['authorization_code', 'refresh_token'],
        response_types: ['code'],
        client_name: 'My Test App',
      });
      expect(validated).toEqual({
        redirectUris: ['https://app.example.com/cb', 'http://127.0.0.1:8080/cb'],
        tokenEndpointAuthMethod: 'client_secret_post',
        grantTypes: ['authorization_code', 'refresh_token'],
        responseTypes: ['code'],
        applicationType: 'web',
        idTokenSignedResponseAlg: 'RS256',
        metadata: {
          redirect_uris: ['https://app.example.com/cb', 'http://127.0.0.1:8080/cb'],
          token_endpoint_auth_method: 'client_secret_post',
          grant_types: ['authorization_code', 'refresh_token'],
          response_types: ['code'],
          application_type: 'web',
          client_name: 'My Test App',
          id_token_signed_response_alg: 'RS256',
        },
      });
    });

    it('should normalize duplicated grant_types values to one entry, keeping their order', () => {
      const validated = validateClientMetadata({
        ...MINIMAL,
        grant_types: ['refresh_token', 'authorization_code', 'refresh_token'],
      });
      expect(validated.grantTypes).toEqual(['refresh_token', 'authorization_code']);
    });
  });

  describe('unknown metadata (RFC 7591 Section 2 MUST ignore)', () => {
    it('should silently drop metadata this provider does not understand', () => {
      const validated = validateClientMetadata({
        ...MINIMAL,
        jwks_uri: 'https://app.example.com/jwks.json',
        sector_identifier_uri: 'https://app.example.com/redirect_uris.json',
        require_auth_time: true,
      });
      expect(validated).toEqual(MINIMAL_VALIDATED);
    });

    it('should drop __proto__ and constructor keys as unknown metadata without polluting the result', () => {
      const validated = validateClientMetadata(
        JSON.parse(
          '{"redirect_uris":["https://app.example.com/cb"],"__proto__":{"polluted":true},"constructor":{"prototype":{"polluted":true}}}',
        ) as Record<string, unknown>,
      );
      expect(validated).toEqual(MINIMAL_VALIDATED);
      expect(Object.getPrototypeOf(validated)).toBe(Object.prototype);
      expect(Object.getPrototypeOf(validated.metadata)).toBe(Object.prototype);
      expect(({} as Record<string, unknown>)['polluted']).toBe(undefined);
    });
  });

  describe('redirect_uris (OIDC Dynamic Client Registration 1.0 Section 2 REQUIRED)', () => {
    it('should reject a registration without redirect_uris', () => {
      expect(() => validateClientMetadata({})).toThrowError(
        new ClientRegistrationError('invalid_redirect_uri', 'redirect_uris must be a non-empty array of strings'),
      );
    });

    it('should reject an empty redirect_uris array', () => {
      expect(() => validateClientMetadata({ redirect_uris: [] })).toThrowError(
        new ClientRegistrationError('invalid_redirect_uri', 'redirect_uris must be a non-empty array of strings'),
      );
    });

    it('should reject a redirect_uris array with a non-string element', () => {
      expect(() => validateClientMetadata({ redirect_uris: ['https://a.example', 1] })).toThrowError(
        new ClientRegistrationError('invalid_redirect_uri', 'redirect_uris must be a non-empty array of strings'),
      );
    });

    it.each([
      ['a fragment component', 'https://app.example.com/cb#fragment'],
      ['a javascript: scheme', 'javascript:alert(1)'],
      ['a non-loopback plain http scheme', 'http://app.example.com/cb'],
    ])('should reject a redirect_uri with %s without reflecting it', (_label, uri) => {
      expect(() => validateClientMetadata({ redirect_uris: [uri] })).toThrowError(
        new ClientRegistrationError(
          'invalid_redirect_uri',
          'each redirect_uri must be an absolute URI without a fragment and must not use a dangerous scheme or non-loopback http',
        ),
      );
    });

    it('should accept mixed loopback http and https redirect_uris', () => {
      const validated = validateClientMetadata({
        redirect_uris: [
          'http://localhost:3000/cb',
          'http://127.0.0.1/cb',
          'http://[::1]:8080/cb',
          'https://app.example.com/cb',
        ],
      });
      expect(validated.redirectUris).toEqual([
        'http://localhost:3000/cb',
        'http://127.0.0.1/cb',
        'http://[::1]:8080/cb',
        'https://app.example.com/cb',
      ]);
    });

    // RFC 8252 §7.1: native apps register private-use (custom) URI schemes.
    it('should accept a private-use scheme redirect_uri', () => {
      const validated = validateClientMetadata({ redirect_uris: ['com.example.app:/oauth2redirect'] });
      expect(validated.redirectUris).toEqual(['com.example.app:/oauth2redirect']);
    });
  });

  describe('token_endpoint_auth_method', () => {
    it('should accept none and keep it', () => {
      const validated = validateClientMetadata({ ...MINIMAL, token_endpoint_auth_method: 'none' });
      expect(validated.tokenEndpointAuthMethod).toBe('none');
    });

    it('should reject a method outside the default three, such as private_key_jwt', () => {
      expect(() =>
        validateClientMetadata({ ...MINIMAL, token_endpoint_auth_method: 'private_key_jwt' }),
      ).toThrowError(
        new ClientRegistrationError(
          'invalid_client_metadata',
          'token_endpoint_auth_method must be one of client_secret_basic, client_secret_post, none',
        ),
      );
    });

    it('should reject a non-string token_endpoint_auth_method', () => {
      expect(() =>
        validateClientMetadata({ ...MINIMAL, token_endpoint_auth_method: ['client_secret_basic'] }),
      ).toThrowError(
        new ClientRegistrationError(
          'invalid_client_metadata',
          'token_endpoint_auth_method must be one of client_secret_basic, client_secret_post, none',
        ),
      );
    });

    it('should accept a method the tokenEndpointAuthMethods option adds', () => {
      const validated = validateClientMetadata(
        { ...MINIMAL, token_endpoint_auth_method: 'private_key_jwt' },
        { tokenEndpointAuthMethods: ['client_secret_basic', 'private_key_jwt'] },
      );
      expect(validated.tokenEndpointAuthMethod).toBe('private_key_jwt');
      expect(validated.metadata['token_endpoint_auth_method']).toBe('private_key_jwt');
    });

    it('should list the configured methods in the error of a method the option leaves out', () => {
      expect(() =>
        validateClientMetadata(
          { ...MINIMAL, token_endpoint_auth_method: 'none' },
          { tokenEndpointAuthMethods: ['client_secret_basic'] },
        ),
      ).toThrowError(
        new ClientRegistrationError(
          'invalid_client_metadata',
          'token_endpoint_auth_method must be one of client_secret_basic',
        ),
      );
    });
  });

  describe('grant_types', () => {
    it('should reject a grant type outside the default authorization_code and refresh_token', () => {
      expect(() =>
        validateClientMetadata({
          ...MINIMAL,
          grant_types: ['authorization_code', 'urn:ietf:params:oauth:grant-type:token-exchange'],
        }),
      ).toThrowError(
        new ClientRegistrationError(
          'invalid_client_metadata',
          'grant_types must be an array containing only authorization_code, refresh_token',
        ),
      );
    });

    it('should reject a non-array grant_types', () => {
      expect(() => validateClientMetadata({ ...MINIMAL, grant_types: 'authorization_code' })).toThrowError(
        new ClientRegistrationError(
          'invalid_client_metadata',
          'grant_types must be an array containing only authorization_code, refresh_token',
        ),
      );
    });

    it('should accept a grant type the grantTypes option adds', () => {
      const validated = validateClientMetadata(
        { ...MINIMAL, grant_types: ['authorization_code', 'urn:ietf:params:oauth:grant-type:device_code'] },
        { grantTypes: ['authorization_code', 'urn:ietf:params:oauth:grant-type:device_code'] },
      );
      expect(validated.grantTypes).toEqual(['authorization_code', 'urn:ietf:params:oauth:grant-type:device_code']);
    });
  });

  describe('response_types', () => {
    it('should reject a response type this provider does not support', () => {
      expect(() => validateClientMetadata({ ...MINIMAL, response_types: ['token'] })).toThrowError(
        new ClientRegistrationError(
          'invalid_client_metadata',
          'response_types must be a non-empty array containing only code',
        ),
      );
    });

    it('should reject an empty response_types array', () => {
      expect(() => validateClientMetadata({ ...MINIMAL, response_types: [] })).toThrowError(
        new ClientRegistrationError(
          'invalid_client_metadata',
          'response_types must be a non-empty array containing only code',
        ),
      );
    });

    it('should normalize duplicated response_types values to one entry', () => {
      const validated = validateClientMetadata({ ...MINIMAL, response_types: ['code', 'code'] });
      expect(validated.responseTypes).toEqual(['code']);
    });

    // OAuth 2.0 Multiple Response Type Encoding Practices §1.2: the order of the
    // values of a response_type does not matter.
    it('should accept the response types of the responseTypes option in any value order and normalize them', () => {
      const validated = validateClientMetadata(
        {
          ...MINIMAL,
          grant_types: ['authorization_code', 'implicit'],
          response_types: ['code', 'token id_token', 'code id_token'],
        },
        { grantTypes: ['authorization_code', 'implicit'], responseTypes: ['code', 'id_token token', 'code id_token'] },
      );
      expect(validated.responseTypes).toEqual(['code', 'id_token token', 'code id_token']);
      expect(validated.metadata['response_types']).toEqual(['code', 'id_token token', 'code id_token']);
    });
  });

  // RFC 7591 §2.1 / OIDC Dynamic Client Registration 1.0 §2: code pairs with
  // authorization_code, token and id_token pair with implicit.
  describe('consistency of grant_types and response_types (RFC 7591 Section 2.1)', () => {
    const inconsistent = new ClientRegistrationError(
      'invalid_client_metadata',
      'grant_types and response_types must be consistent: code requires authorization_code, token and id_token require implicit',
    );
    const implicitOptions = { grantTypes: ['authorization_code', 'refresh_token', 'implicit'], responseTypes: ['code', 'id_token', 'id_token token', 'code id_token'] };

    it('should reject refresh_token without authorization_code while response_types defaults to code', () => {
      expect(() => validateClientMetadata({ ...MINIMAL, grant_types: ['refresh_token'] })).toThrowError(inconsistent);
    });

    it('should reject an empty grant_types array', () => {
      expect(() => validateClientMetadata({ ...MINIMAL, grant_types: [] })).toThrowError(inconsistent);
    });

    it('should reject an implicit response type while grant_types defaults to authorization_code', () => {
      expect(() =>
        validateClientMetadata({ ...MINIMAL, response_types: ['id_token'] }, implicitOptions),
      ).toThrowError(inconsistent);
    });

    it('should reject the implicit grant without a token or id_token response type', () => {
      expect(() =>
        validateClientMetadata({ ...MINIMAL, grant_types: ['authorization_code', 'implicit'] }, implicitOptions),
      ).toThrowError(inconsistent);
    });

    it('should accept an implicit client registering implicit with id_token token', () => {
      const validated = validateClientMetadata(
        { ...MINIMAL, grant_types: ['implicit'], response_types: ['id_token token'] },
        implicitOptions,
      );
      expect(validated.grantTypes).toEqual(['implicit']);
      expect(validated.responseTypes).toEqual(['id_token token']);
    });

    it('should accept a hybrid client registering authorization_code and implicit with code id_token', () => {
      const validated = validateClientMetadata(
        { ...MINIMAL, grant_types: ['authorization_code', 'implicit'], response_types: ['code id_token'] },
        implicitOptions,
      );
      expect(validated.responseTypes).toEqual(['code id_token']);
    });
  });

  describe('client_name', () => {
    it('should accept a client_name of exactly 128 characters', () => {
      const name = 'a'.repeat(128);
      expect(validateClientMetadata({ ...MINIMAL, client_name: name }).metadata['client_name']).toBe(name);
    });

    it('should reject a client_name of 129 characters', () => {
      expect(() => validateClientMetadata({ ...MINIMAL, client_name: 'a'.repeat(129) })).toThrowError(
        new ClientRegistrationError('invalid_client_metadata', 'client_name must be at most 128 characters'),
      );
    });

    it('should reject a non-string client_name', () => {
      expect(() => validateClientMetadata({ ...MINIMAL, client_name: 42 })).toThrowError(
        new ClientRegistrationError('invalid_client_metadata', 'client_name must be a string'),
      );
    });

    it.each([
      ['a control character', 'bad\nname'],
      ['a C1 control character', 'bad\u0085name'],
      // U+202E (RIGHT-TO-LEFT OVERRIDE) can reverse the rendered order of a
      // display name and disguise what the user approves.
      ['a bidi override character', 'bad‮name'],
      ['a zero-width character', 'bad​name'],
    ])('should reject a client_name containing %s', (_label, name) => {
      expect(() => validateClientMetadata({ ...MINIMAL, client_name: name })).toThrowError(
        new ClientRegistrationError(
          'invalid_client_metadata',
          'client_name must not contain control or invisible formatting characters',
        ),
      );
    });
  });

  describe('informational URLs (client_uri, logo_uri, tos_uri, policy_uri)', () => {
    it('should register absolute http and https URLs and echo them', () => {
      const validated = validateClientMetadata({
        ...MINIMAL,
        client_uri: 'https://app.example.com/',
        logo_uri: 'https://cdn.example.com/logo.png',
        tos_uri: 'https://app.example.com/tos',
        policy_uri: 'http://localhost:3000/privacy',
      });
      expect(validated.metadata).toMatchObject({
        client_uri: 'https://app.example.com/',
        logo_uri: 'https://cdn.example.com/logo.png',
        tos_uri: 'https://app.example.com/tos',
        policy_uri: 'http://localhost:3000/privacy',
      });
    });

    it.each([
      ['a relative URL', '/logo.png'],
      ['a javascript: URL', 'javascript:alert(1)'],
      ['a data: URL', 'data:image/png;base64,AAAA'],
      ['a non-string value', 42],
      ['a URL with a control character', 'https://app.example.com/\u0000'],
    ])('should reject logo_uri that is %s without reflecting it', (_label, value) => {
      expect(() => validateClientMetadata({ ...MINIMAL, logo_uri: value })).toThrowError(
        new ClientRegistrationError('invalid_client_metadata', 'logo_uri must be an absolute http or https URL'),
      );
    });
  });

  describe('contacts', () => {
    it('should register an array of contact strings', () => {
      const validated = validateClientMetadata({ ...MINIMAL, contacts: ['ops@example.com', 'dev@example.com'] });
      expect(validated.metadata['contacts']).toEqual(['ops@example.com', 'dev@example.com']);
    });

    it.each([
      ['a string instead of an array', 'ops@example.com'],
      ['an empty array', []],
    ])('should reject contacts that is %s', (_label, value) => {
      expect(() => validateClientMetadata({ ...MINIMAL, contacts: value })).toThrowError(
        new ClientRegistrationError('invalid_client_metadata', 'contacts must be an array of 1 to 32 strings'),
      );
    });

    it('should reject a contact containing a control character', () => {
      expect(() => validateClientMetadata({ ...MINIMAL, contacts: ['ops@example.com\n'] })).toThrowError(
        new ClientRegistrationError(
          'invalid_client_metadata',
          'each contact must not contain control or invisible formatting characters',
        ),
      );
    });
  });

  describe('scope (RFC 7591 Section 2 / RFC 6749 Section 3.3)', () => {
    it('should register the scope values from a space-delimited scope string', () => {
      const validated = validateClientMetadata({ ...MINIMAL, scope: 'openid profile' });
      expect(validated.scope).toEqual(['openid', 'profile']);
      expect(validated.metadata['scope']).toBe('openid profile');
    });

    it('should omit the scope key when scope is not provided', () => {
      const validated = validateClientMetadata(MINIMAL);
      expect(Object.hasOwn(validated, 'scope')).toBe(false);
      expect(Object.hasOwn(validated.metadata, 'scope')).toBe(false);
    });

    it('should deduplicate repeated scope values', () => {
      const validated = validateClientMetadata({ ...MINIMAL, scope: 'openid openid profile' });
      expect(validated.scope).toEqual(['openid', 'profile']);
      expect(validated.metadata['scope']).toBe('openid profile');
    });

    it.each([
      ['a non-string value', ['openid']],
      ['an empty string', ''],
      ['two spaces in a row', 'openid  profile'],
      ['a double quote', 'open"id'],
      ['a backslash', 'open\\id'],
      ['a control character', 'openid\tprofile'],
    ])('should reject scope that is %s with invalid_client_metadata', (_label, value) => {
      expect(() => validateClientMetadata({ ...MINIMAL, scope: value })).toThrowError(
        new ClientRegistrationError(
          'invalid_client_metadata',
          'scope must be a space-delimited string of scope values',
        ),
      );
    });

    it('should accept any syntactically valid scope when the scopes option is not provided', () => {
      const validated = validateClientMetadata({ ...MINIMAL, scope: 'openid reports.read' });
      expect(validated.scope).toEqual(['openid', 'reports.read']);
    });

    it('should reject a scope value outside the scopes option', () => {
      expect(() =>
        validateClientMetadata({ ...MINIMAL, scope: 'openid reports.read' }, { scopes: ['openid', 'profile'] }),
      ).toThrowError(
        new ClientRegistrationError(
          'invalid_client_metadata',
          'scope must contain only scope values this provider supports',
        ),
      );
    });
  });

  describe('software_id and software_version', () => {
    it('should register both strings', () => {
      const validated = validateClientMetadata({
        ...MINIMAL,
        software_id: '4NRB1-0XZABZI9E6-5SM3R',
        software_version: '2.0.1',
      });
      expect(validated.metadata).toMatchObject({ software_id: '4NRB1-0XZABZI9E6-5SM3R', software_version: '2.0.1' });
    });

    it('should reject a software_version over 64 characters', () => {
      expect(() => validateClientMetadata({ ...MINIMAL, software_version: 'v'.repeat(65) })).toThrowError(
        new ClientRegistrationError('invalid_client_metadata', 'software_version must be at most 64 characters'),
      );
    });

    it('should reject a non-string software_id', () => {
      expect(() => validateClientMetadata({ ...MINIMAL, software_id: 1 })).toThrowError(
        new ClientRegistrationError('invalid_client_metadata', 'software_id must be a string'),
      );
    });
  });

  describe('application_type (OIDC Dynamic Client Registration 1.0 Section 2)', () => {
    // §2: the default, if omitted, is web; §3.2: a default the AS applied is
    // part of the registered metadata it returns.
    it('should default application_type to web and register the default', () => {
      const validated = validateClientMetadata(MINIMAL);
      expect(validated.applicationType).toBe('web');
      expect(validated.metadata['application_type']).toBe('web');
    });

    it('should reject a null application_type instead of treating it as omitted', () => {
      expect(() => validateClientMetadata({ ...MINIMAL, application_type: null })).toThrowError(
        new ClientRegistrationError('invalid_client_metadata', 'application_type must be web or native'),
      );
    });

    it('should register web and native', () => {
      expect(validateClientMetadata({ ...MINIMAL, application_type: 'web' }).metadata['application_type']).toBe('web');
      expect(
        validateClientMetadata({ redirect_uris: ['com.example.app:/cb'], application_type: 'native' }).metadata[
          'application_type'
        ],
      ).toBe('native');
    });

    it('should reject another value', () => {
      expect(() => validateClientMetadata({ ...MINIMAL, application_type: 'desktop' })).toThrowError(
        new ClientRegistrationError('invalid_client_metadata', 'application_type must be web or native'),
      );
    });

    it('should let a native client register custom scheme and loopback http redirect_uris', () => {
      const validated = validateClientMetadata({
        redirect_uris: ['com.example.app:/cb', 'http://127.0.0.1:8080/cb', 'http://localhost/cb', 'http://[::1]/cb'],
        application_type: 'native',
      });
      expect(validated.redirectUris).toEqual([
        'com.example.app:/cb',
        'http://127.0.0.1:8080/cb',
        'http://localhost/cb',
        'http://[::1]/cb',
      ]);
    });

    it('should reject an https redirect_uri of a native client', () => {
      expect(() =>
        validateClientMetadata({ redirect_uris: ['https://app.example.com/cb'], application_type: 'native' }),
      ).toThrowError(
        new ClientRegistrationError(
          'invalid_client_metadata',
          'a native client must register custom scheme or loopback http redirect_uris only',
        ),
      );
    });

    it('should let a web client without the implicit grant register a loopback http redirect_uri', () => {
      const validated = validateClientMetadata({ redirect_uris: ['http://localhost:3000/cb'], application_type: 'web' });
      expect(validated.redirectUris).toEqual(['http://localhost:3000/cb']);
    });

    // §2: the AS MUST verify that all registered redirect_uris conform to the
    // constraints of the application type, so the omitted type is checked as web.
    it('should apply the web constraints to a registration that omits application_type and uses the implicit grant', () => {
      const options = { grantTypes: ['authorization_code', 'implicit'], responseTypes: ['code', 'id_token'] };
      const implicitClient = { grant_types: ['implicit'], response_types: ['id_token'] };

      const registered = validateClientMetadata(
        { redirect_uris: ['https://app.example.com/cb'], ...implicitClient },
        options,
      );
      expect(registered.metadata['application_type']).toBe('web');
      expect(() =>
        validateClientMetadata({ redirect_uris: ['http://127.0.0.1:8080/cb'], ...implicitClient }, options),
      ).toThrowError(
        new ClientRegistrationError(
          'invalid_client_metadata',
          'a web client using the implicit grant must register https redirect_uris that do not use localhost',
        ),
      );
    });

    it('should reject a localhost redirect_uri of a web client using the implicit grant', () => {
      expect(() =>
        validateClientMetadata(
          {
            redirect_uris: ['http://localhost:3000/cb'],
            application_type: 'web',
            grant_types: ['implicit'],
            response_types: ['id_token'],
          },
          { grantTypes: ['authorization_code', 'implicit'], responseTypes: ['code', 'id_token'] },
        ),
      ).toThrowError(
        new ClientRegistrationError(
          'invalid_client_metadata',
          'a web client using the implicit grant must register https redirect_uris that do not use localhost',
        ),
      );
    });
  });

  describe('default_max_age', () => {
    it('should register a non-negative integer', () => {
      const validated = validateClientMetadata({ ...MINIMAL, default_max_age: 3600 });
      expect(validated.defaultMaxAge).toBe(3600);
      expect(validated.metadata['default_max_age']).toBe(3600);
    });

    it.each([
      ['a string', '3600'],
      ['a negative number', -1],
      ['a fraction', 1.5],
    ])('should reject default_max_age that is %s', (_label, value) => {
      expect(() => validateClientMetadata({ ...MINIMAL, default_max_age: value })).toThrowError(
        new ClientRegistrationError('invalid_client_metadata', 'default_max_age must be a non-negative integer'),
      );
    });
  });

  describe('id_token_signed_response_alg and userinfo_signed_response_alg', () => {
    // OIDC Dynamic Client Registration 1.0 §2: the default, if omitted, is
    // RS256; §3.2: the AS returns the defaults it applied. userinfo has no
    // default alg: an omitted value means an unsigned JSON response.
    it('should default id_token_signed_response_alg to RS256 and register the default', () => {
      const validated = validateClientMetadata(MINIMAL);
      expect(validated.idTokenSignedResponseAlg).toBe('RS256');
      expect(validated.metadata['id_token_signed_response_alg']).toBe('RS256');
      expect(validated.userinfoSignedResponseAlg).toBeUndefined();
      expect(Object.hasOwn(validated.metadata, 'userinfo_signed_response_alg')).toBe(false);
    });

    it('should reject the omitted id_token_signed_response_alg when the OP cannot sign RS256', () => {
      expect(() => validateClientMetadata(MINIMAL, { idTokenSigningAlgValuesSupported: ['ES256'] })).toThrowError(
        new ClientRegistrationError('invalid_client_metadata', 'id_token_signed_response_alg must be one of ES256'),
      );
    });

    it('should accept RS256 by default and echo it', () => {
      const validated = validateClientMetadata({
        ...MINIMAL,
        id_token_signed_response_alg: 'RS256',
        userinfo_signed_response_alg: 'RS256',
      });
      expect(validated.idTokenSignedResponseAlg).toBe('RS256');
      expect(validated.userinfoSignedResponseAlg).toBe('RS256');
      expect(validated.metadata).toMatchObject({
        id_token_signed_response_alg: 'RS256',
        userinfo_signed_response_alg: 'RS256',
      });
    });

    it('should reject an alg outside the supported values', () => {
      expect(() => validateClientMetadata({ ...MINIMAL, id_token_signed_response_alg: 'ES256' })).toThrowError(
        new ClientRegistrationError('invalid_client_metadata', 'id_token_signed_response_alg must be one of RS256'),
      );
    });

    it('should accept an alg the option adds', () => {
      const validated = validateClientMetadata(
        { ...MINIMAL, userinfo_signed_response_alg: 'ES256' },
        { userinfoSigningAlgValuesSupported: ['RS256', 'ES256'] },
      );
      expect(validated.userinfoSignedResponseAlg).toBe('ES256');
    });

    // OIDC Dynamic Client Registration 1.0 §2: none is not an ID Token alg this OP issues.
    it('should reject none even when the option lists it', () => {
      expect(() =>
        validateClientMetadata(
          { ...MINIMAL, id_token_signed_response_alg: 'none' },
          { idTokenSigningAlgValuesSupported: ['RS256', 'none'] },
        ),
      ).toThrowError(
        new ClientRegistrationError(
          'invalid_client_metadata',
          'id_token_signed_response_alg must be one of RS256, none',
        ),
      );
    });
  });

  describe('jwks (RFC 7591 Section 2)', () => {
    const jwksDescription =
      'jwks must be a JWK Set of 1 to 16 public RSA (RS256, RS384, RS512) or EC (P-256, P-384, P-521) signature keys';

    it('should register the public keys of a JWK Set and echo the normalized set', async () => {
      const key = await generateTestRs256Key('client-key-1');
      const validated = validateClientMetadata({ ...MINIMAL, jwks: key.jwks });
      expect(validated.jwks).toEqual({
        keys: [{ kty: 'RSA', kid: 'client-key-1', use: 'sig', alg: 'RS256', n: key.jwk.n, e: key.jwk.e }],
      });
      expect(validated.metadata['jwks']).toEqual(validated.jwks);
    });

    it('should default alg to RS256 for an RSA key and to the curve alg and use sig for an EC key', () => {
      const validated = validateClientMetadata({
        ...MINIMAL,
        jwks: {
          keys: [
            { kty: 'RSA', n: 'AQAB', e: 'AQAB', x5c: ['ignored'] },
            { kty: 'EC', crv: 'P-256', x: 'x', y: 'y' },
          ],
        },
      });
      expect(validated.jwks).toEqual({
        keys: [
          { kty: 'RSA', use: 'sig', alg: 'RS256', n: 'AQAB', e: 'AQAB' },
          { kty: 'EC', use: 'sig', alg: 'ES256', crv: 'P-256', x: 'x', y: 'y' },
        ],
      });
    });

    it('should reject a JWK Set carrying a private key parameter', () => {
      expect(() =>
        validateClientMetadata({ ...MINIMAL, jwks: { keys: [{ kty: 'RSA', n: 'AQAB', e: 'AQAB', d: 'secret' }] } }),
      ).toThrowError(new ClientRegistrationError('invalid_client_metadata', 'jwks must contain public keys only'));
    });

    it.each([
      ['not an object', 'keys'],
      ['without a keys array', { keys: 'none' }],
      ['with an empty keys array', { keys: [] }],
      ['with an unsupported key type', { keys: [{ kty: 'oct', k: 'x' }] }],
      ['with an RSA key of an unsupported alg', { keys: [{ kty: 'RSA', n: 'AQAB', e: 'AQAB', alg: 'PS256' }] }],
      ['with an EC key on an unsupported curve', { keys: [{ kty: 'EC', crv: 'secp256k1', x: 'x', y: 'y' }] }],
      ['with an EC key whose alg does not match its curve', { keys: [{ kty: 'EC', crv: 'P-256', x: 'x', y: 'y', alg: 'ES384' }] }],
      ['with an encryption key', { keys: [{ kty: 'RSA', n: 'AQAB', e: 'AQAB', use: 'enc' }] }],
    ])('should reject jwks %s', (_label, jwks) => {
      expect(() => validateClientMetadata({ ...MINIMAL, jwks })).toThrowError(
        new ClientRegistrationError('invalid_client_metadata', jwksDescription),
      );
    });

    it('should reject a key whose kid contains a control character', () => {
      expect(() =>
        validateClientMetadata({ ...MINIMAL, jwks: { keys: [{ kty: 'RSA', n: 'AQAB', e: 'AQAB', kid: 'k\nid' }] } }),
      ).toThrowError(
        new ClientRegistrationError(
          'invalid_client_metadata',
          'kid of a jwks key must not contain control or invisible formatting characters',
        ),
      );
    });

    // RFC 7591 §2: jwks_uri and jwks MUST NOT both be present.
    it('should reject jwks together with jwks_uri', () => {
      expect(() =>
        validateClientMetadata({
          ...MINIMAL,
          jwks: { keys: [{ kty: 'RSA', n: 'AQAB', e: 'AQAB' }] },
          jwks_uri: 'https://app.example.com/jwks.json',
        }),
      ).toThrowError(
        new ClientRegistrationError('invalid_client_metadata', 'jwks and jwks_uri must not both be present'),
      );
    });
  });

  describe('software_statement echo (RFC 7591 Section 3.2.1)', () => {
    it('should return a software_statement string the caller placed as registered metadata', () => {
      const validated = validateClientMetadata({ ...MINIMAL, software_statement: 'eyJhbGciOiJSUzI1NiJ9.e30.sig' });
      expect(validated.metadata['software_statement']).toBe('eyJhbGciOiJSUzI1NiJ9.e30.sig');
    });

    it('should reject a software_statement that is not a string', () => {
      expect(() => validateClientMetadata({ ...MINIMAL, software_statement: 1 })).toThrowError(
        new ClientRegistrationError('invalid_software_statement', 'software_statement must be a string'),
      );
    });
  });

  describe('custom metadata', () => {
    it('should register the value a custom validator returns and echo it', () => {
      const validated = validateClientMetadata(
        { ...MINIMAL, tenant_id: 'acme' },
        { customMetadata: { tenant_id: (value) => (typeof value === 'string' ? value.toUpperCase() : undefined) } },
      );
      expect(validated.metadata['tenant_id']).toBe('ACME');
    });

    it('should leave a custom field out when its validator returns undefined', () => {
      const validated = validateClientMetadata(MINIMAL, {
        customMetadata: { tenant_id: (value) => value },
      });
      expect(Object.hasOwn(validated.metadata, 'tenant_id')).toBe(false);
    });

    it('should register the default a custom validator returns for an absent field', () => {
      const validated = validateClientMetadata(MINIMAL, {
        customMetadata: { tier: (value) => value ?? 'free' },
      });
      expect(validated.metadata['tier']).toBe('free');
    });

    it('should hand the validator the whole request metadata', () => {
      const seen: unknown[] = [];
      validateClientMetadata(
        { ...MINIMAL, tenant_id: 'acme' },
        { customMetadata: { tenant_id: (value, metadata) => void seen.push(value, metadata) } },
      );
      expect(seen).toEqual(['acme', { ...MINIMAL, tenant_id: 'acme' }]);
    });

    it('should propagate the ClientRegistrationError a validator throws', () => {
      expect(() =>
        validateClientMetadata(
          { ...MINIMAL, tenant_id: 42 },
          {
            customMetadata: {
              tenant_id: () => {
                throw new ClientRegistrationError('invalid_client_metadata', 'tenant_id must be a string');
              },
            },
          },
        ),
      ).toThrowError(new ClientRegistrationError('invalid_client_metadata', 'tenant_id must be a string'));
    });

    it('should refuse a custom validator that redefines a standard field', () => {
      expect(() =>
        validateClientMetadata(MINIMAL, { customMetadata: { redirect_uris: (value) => value } }),
      ).toThrowError(new TypeError('custom client metadata must not redefine the standard field redirect_uris'));
    });
  });
});

describe('validateClientRegistrationRequest', () => {
  it('should parse and validate a body in one step', () => {
    expect(validateClientRegistrationRequest(body(MINIMAL))).toEqual(MINIMAL_VALIDATED);
  });

  it('should pass the body size limit through', () => {
    expect(() => validateClientRegistrationRequest(body(MINIMAL), { maxBodyBytes: 8 })).toThrowError(
      new ClientRegistrationError(
        'invalid_client_metadata',
        'request body must not exceed the configured maximum size',
      ),
    );
  });

  // RFC 7591 §3.1.1: an authorization server that does not support software
  // statements may ignore the member.
  it('should ignore a software_statement instead of echoing or verifying it', () => {
    const validated = validateClientRegistrationRequest(
      body({ ...MINIMAL, software_statement: 'eyJhbGciOiJSUzI1NiJ9.e30.sig' }),
    );
    expect(validated).toEqual(MINIMAL_VALIDATED);
  });
});

describe('ClientRegistrationError', () => {
  it('should carry the RFC 7591 error code and description as properties', () => {
    const error = new ClientRegistrationError('unapproved_software_statement', 'fixed description');
    expect(error.error).toBe('unapproved_software_statement');
    expect(error.errorDescription).toBe('fixed description');
    expect(error.message).toBe('fixed description');
    expect(error.name).toBe('ClientRegistrationError');
  });
});

describe('isClientRegistrationError', () => {
  it('should recognize an instance of the class', () => {
    expect(isClientRegistrationError(new ClientRegistrationError('invalid_client_metadata', 'd'))).toBe(true);
  });

  // A second copy of this package (another bundle of the generated code) builds
  // the same shape from another class; the response code must still be read.
  it('should recognize an error of the same shape from another copy of the package', () => {
    const error = Object.assign(new Error('d'), {
      name: 'ClientRegistrationError',
      error: 'invalid_software_statement',
      errorDescription: 'd',
    });
    expect(isClientRegistrationError(error)).toBe(true);
  });

  it.each([
    ['a plain Error', new Error('boom')],
    ['an error with the name but without the code', Object.assign(new Error('d'), { name: 'ClientRegistrationError' })],
    ['null', null],
    ['a string', 'ClientRegistrationError'],
  ])('should reject %s', (_label, value) => {
    expect(isClientRegistrationError(value)).toBe(false);
  });
});
```

### software-statement.test.ts

```typescript
import { describe, expect, it } from 'vitest';
import { applySoftwareStatement } from './software-statement.js';

const STATEMENT = 'eyJhbGciOiJSUzI1NiJ9.e30.sig';

describe('applySoftwareStatement', () => {
  // RFC 7591 §3.1.1: the asserted values win; §3.2.1: the statement is kept for the response.
  it('should let the asserted metadata take precedence over the plain metadata and keep the statement', () => {
    const merged = applySoftwareStatement(
      { redirect_uris: ['https://app.example.com/cb'], client_name: 'Plain Name', scope: 'openid' },
      STATEMENT,
      { metadata: { client_name: 'Asserted Name', software_id: 'sw-1' } },
    );
    expect(merged).toEqual({
      redirect_uris: ['https://app.example.com/cb'],
      client_name: 'Asserted Name',
      scope: 'openid',
      software_id: 'sw-1',
      software_statement: STATEMENT,
    });
  });

  // RFC 7591 defines no required claim inside a statement: whatever the verifier returns is applied as is.
  it('should apply every asserted claim without requiring or dropping any', () => {
    const merged = applySoftwareStatement({ redirect_uris: ['https://app.example.com/cb'] }, STATEMENT, {
      metadata: { iss: 'https://publisher.example.com', exp: 1_790_812_800, tenant_id: 'acme' },
    });
    expect(merged).toEqual({
      redirect_uris: ['https://app.example.com/cb'],
      iss: 'https://publisher.example.com',
      exp: 1_790_812_800,
      tenant_id: 'acme',
      software_statement: STATEMENT,
    });
  });

  it('should keep the outer statement when the asserted claims carry a software_statement of their own', () => {
    const merged = applySoftwareStatement({ redirect_uris: [] }, STATEMENT, {
      metadata: { software_statement: 'inner.statement.sig' },
    });
    expect(merged['software_statement']).toBe(STATEMENT);
  });

  it('should build a new object with the Object prototype', () => {
    const plain = JSON.parse('{"redirect_uris":["https://app.example.com/cb"],"__proto__":{"polluted":true}}') as Record<
      string,
      unknown
    >;
    const merged = applySoftwareStatement(plain, STATEMENT, { metadata: {} });
    expect(Object.getPrototypeOf(merged)).toBe(Object.prototype);
    // The key stays an inert own data property that validateClientMetadata ignores as unknown metadata.
    expect(Object.getOwnPropertyDescriptor(merged, '__proto__')?.value).toEqual({ polluted: true });
    expect(({} as Record<string, unknown>)['polluted']).toBe(undefined);
  });
});
```

### registered-client.test.ts

```typescript
import { describe, expect, it } from 'vitest';
import {
  buildClientRegistrationResponse,
  buildRegisteredClient,
  type DynamicallyRegisteredClient,
} from './registered-client.js';
import type { ValidatedClientRegistration } from './registration-request.js';

const CONFIDENTIAL: ValidatedClientRegistration = {
  redirectUris: ['https://app.example.com/cb'],
  tokenEndpointAuthMethod: 'client_secret_basic',
  grantTypes: ['authorization_code'],
  responseTypes: ['code'],
  applicationType: 'web',
  idTokenSignedResponseAlg: 'RS256',
  metadata: {
    redirect_uris: ['https://app.example.com/cb'],
    token_endpoint_auth_method: 'client_secret_basic',
    grant_types: ['authorization_code'],
    response_types: ['code'],
    application_type: 'web',
    id_token_signed_response_alg: 'RS256',
  },
};

const PUBLIC: ValidatedClientRegistration = {
  ...CONFIDENTIAL,
  tokenEndpointAuthMethod: 'none',
  metadata: { ...CONFIDENTIAL.metadata, token_endpoint_auth_method: 'none' },
};

const FIXED = { generateClientId: () => 'dcr-fixed', generateClientSecret: () => 'fixed-secret', now: () => 1_790_812_800_123 };

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
      expect(buildRegisteredClient(CONFIDENTIAL, FIXED)).toEqual({
        clientId: 'dcr-fixed',
        clientSecret: 'fixed-secret',
        clientType: 'confidential',
        redirectUris: ['https://app.example.com/cb'],
        grantTypes: ['authorization_code'],
        responseTypes: ['code'],
        tokenEndpointAuthMethods: ['client_secret_basic'],
        idTokenSignedResponseAlg: 'RS256',
        clientIdIssuedAt: 1_790_812_800,
        metadata: CONFIDENTIAL.metadata,
      });
    });
  });

  describe('public clients (token_endpoint_auth_method none)', () => {
    it('should mark the client public and issue no client_secret', () => {
      const client = buildRegisteredClient(PUBLIC, FIXED);
      expect(client).toEqual({
        clientId: 'dcr-fixed',
        clientType: 'public',
        redirectUris: ['https://app.example.com/cb'],
        grantTypes: ['authorization_code'],
        responseTypes: ['code'],
        tokenEndpointAuthMethods: ['none'],
        idTokenSignedResponseAlg: 'RS256',
        clientIdIssuedAt: 1_790_812_800,
        metadata: PUBLIC.metadata,
      });
      expect(Object.hasOwn(client, 'clientSecret')).toBe(false);
    });
  });

  // RFC 7591 §2: a key-based method such as private_key_jwt authenticates
  // without a client_secret, so none is minted; the client stays confidential.
  describe('confidential clients without a secret', () => {
    it('should issue no client_secret for private_key_jwt', () => {
      const client = buildRegisteredClient(
        { ...CONFIDENTIAL, tokenEndpointAuthMethod: 'private_key_jwt' },
        FIXED,
      );
      expect(client.clientType).toBe('confidential');
      expect(Object.hasOwn(client, 'clientSecret')).toBe(false);
      expect(client.tokenEndpointAuthMethods).toEqual(['private_key_jwt']);
    });

    it('should issue a client_secret for a method the clientSecretAuthMethods option names', () => {
      const client = buildRegisteredClient(
        { ...CONFIDENTIAL, tokenEndpointAuthMethod: 'custom_secret_method' },
        { ...FIXED, clientSecretAuthMethods: ['custom_secret_method'] },
      );
      expect(client.clientSecret).toBe('fixed-secret');
    });
  });

  describe('registered metadata', () => {
    it('should carry scope, default_max_age, the signed response algs and jwks into the record', () => {
      const client = buildRegisteredClient(
        {
          ...CONFIDENTIAL,
          scope: ['openid', 'profile'],
          defaultMaxAge: 3600,
          idTokenSignedResponseAlg: 'RS256',
          userinfoSignedResponseAlg: 'ES256',
          jwks: { keys: [{ kty: 'RSA', use: 'sig', alg: 'RS256', n: 'AQAB', e: 'AQAB' }] },
        },
        FIXED,
      );
      expect(client).toMatchObject({
        scope: ['openid', 'profile'],
        defaultMaxAge: 3600,
        idTokenSignedResponseAlg: 'RS256',
        userinfoSignedResponseAlg: 'ES256',
        jwks: { keys: [{ kty: 'RSA', use: 'sig', alg: 'RS256', n: 'AQAB', e: 'AQAB' }] },
      });
    });

    // id_token_signed_response_alg is never left out: it always carries at
    // least its default (OIDC Dynamic Client Registration 1.0 §2).
    it('should leave the optional record fields out when they were not registered', () => {
      const client = buildRegisteredClient(CONFIDENTIAL, FIXED);
      expect(Object.keys(client)).toEqual([
        'clientId',
        'clientSecret',
        'clientType',
        'redirectUris',
        'grantTypes',
        'responseTypes',
        'tokenEndpointAuthMethods',
        'idTokenSignedResponseAlg',
        'clientIdIssuedAt',
        'metadata',
      ]);
    });

    it('should copy the metadata arrays and objects instead of sharing them', () => {
      const metadata: ValidatedClientRegistration = {
        ...CONFIDENTIAL,
        redirectUris: ['https://app.example.com/cb'],
        scope: ['openid'],
        jwks: { keys: [{ kty: 'RSA', use: 'sig', alg: 'RS256', n: 'AQAB', e: 'AQAB' }] },
        metadata: { ...CONFIDENTIAL.metadata, client_name: 'My Test App' },
      };
      const client = buildRegisteredClient(metadata);
      metadata.redirectUris.push('https://evil.example.com/cb');
      metadata.scope?.push('admin');
      metadata.jwks?.keys.push({ kty: 'RSA', use: 'sig', alg: 'RS256', n: 'evil', e: 'AQAB' });
      metadata.metadata['client_name'] = 'Renamed';
      expect(client.redirectUris).toEqual(['https://app.example.com/cb']);
      expect(client.scope).toEqual(['openid']);
      expect(client.jwks?.keys).toHaveLength(1);
      expect(client.metadata['client_name']).toBe('My Test App');
    });
  });
});

describe('buildClientRegistrationResponse', () => {
  const confidentialClient: DynamicallyRegisteredClient = {
    clientId: 'dcr-fixed',
    clientSecret: 'fixed-secret',
    clientType: 'confidential',
    redirectUris: ['https://app.example.com/cb'],
    grantTypes: ['authorization_code'],
    responseTypes: ['code'],
    tokenEndpointAuthMethods: ['client_secret_basic'],
    scope: ['openid', 'profile'],
    clientIdIssuedAt: 1_790_812_800,
    metadata: {
      redirect_uris: ['https://app.example.com/cb'],
      token_endpoint_auth_method: 'client_secret_basic',
      grant_types: ['authorization_code'],
      response_types: ['code'],
      client_name: 'My Test App',
      scope: 'openid profile',
      software_statement: 'eyJhbGciOiJSUzI1NiJ9.e30.sig',
      tenant_id: 'acme',
    },
  };

  it('should return the issued values followed by every registered metadata value (RFC 7591 Section 3.2.1)', () => {
    expect(buildClientRegistrationResponse(confidentialClient)).toEqual({
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
      scope: 'openid profile',
      software_statement: 'eyJhbGciOiJSUzI1NiJ9.e30.sig',
      tenant_id: 'acme',
    });
  });

  it('should omit client_secret and client_secret_expires_at for a client without a secret', () => {
    const { clientSecret: _secret, ...withoutSecret } = confidentialClient;
    const response = buildClientRegistrationResponse({
      ...withoutSecret,
      clientType: 'public',
      tokenEndpointAuthMethods: ['none'],
      metadata: { ...confidentialClient.metadata, token_endpoint_auth_method: 'none' },
    });
    expect(Object.keys(response)).toEqual([
      'client_id',
      'client_id_issued_at',
      'redirect_uris',
      'token_endpoint_auth_method',
      'grant_types',
      'response_types',
      'client_name',
      'scope',
      'software_statement',
      'tenant_id',
    ]);
    expect(response['token_endpoint_auth_method']).toBe('none');
  });
});
```

### bearer-token.test.ts

```typescript
import { describe, expect, it } from 'vitest';
import { readBearerToken } from './bearer-token.js';

describe('readBearerToken', () => {
  // RFC 6750 §2.1: credentials = "Bearer" 1*SP b64token.
  it('should return the token of a Bearer header', () => {
    expect(readBearerToken('Bearer abc.DEF-ghi_jkl~mno+pqr/stu')).toBe('abc.DEF-ghi_jkl~mno+pqr/stu');
  });

  it('should keep the trailing padding of the token', () => {
    expect(readBearerToken('Bearer dG9rZW4==')).toBe('dG9rZW4==');
  });

  // RFC 9110 §11.1: the scheme name is case-insensitive.
  it('should accept the scheme name in any case', () => {
    expect(readBearerToken('bearer token-1')).toBe('token-1');
    expect(readBearerToken('BEARER token-1')).toBe('token-1');
  });

  it('should accept more than one space between the scheme and the token', () => {
    expect(readBearerToken('Bearer    token-1')).toBe('token-1');
  });

  it('should return undefined for a missing header', () => {
    expect(readBearerToken(undefined)).toBeUndefined();
    expect(readBearerToken(null)).toBeUndefined();
  });

  it('should return undefined for another authentication scheme', () => {
    expect(readBearerToken('Basic dXNlcjpwYXNz')).toBeUndefined();
  });

  it('should return undefined for a Bearer header without a token', () => {
    expect(readBearerToken('Bearer')).toBeUndefined();
    expect(readBearerToken('Bearer ')).toBeUndefined();
  });

  it('should return undefined for a token outside the b64token syntax', () => {
    expect(readBearerToken('Bearer two tokens')).toBeUndefined();
    expect(readBearerToken('Bearer token!')).toBeUndefined();
    expect(readBearerToken('Bearer =token')).toBeUndefined();
  });
});
```

### test-helpers.ts (test-only fixture)

Excluded by the tsconfig; never reaches `dist`.

```typescript
/**
 * dynamic-client-registration テスト専用フィクスチャ。
 *
 * tsconfig の exclude 対象なので dist へは出ない（公開 package に載らない）。
 * jwks メタデータの検査に使う公開鍵の生成を Web Crypto API だけで行い、
 * edge-runtime 環境のテストでそのまま動くようにしている。
 */
import type { Jwk, JwkSet } from '@maronn-openid-connect/core';

export interface TestSigningKey {
  privateKey: CryptoKey;
  jwk: Jwk;
  jwks: JwkSet;
}

/** RS256 の鍵ペアを生成し、秘密鍵と公開 JWK セットを返す。 */
export async function generateTestRs256Key(keyId: string): Promise<TestSigningKey> {
  const keyPair = await crypto.subtle.generateKey(
    {
      name: 'RSASSA-PKCS1-v1_5',
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: 'SHA-256',
    },
    true,
    ['sign', 'verify'],
  );
  return exportTestKey(keyPair, keyId, 'RS256');
}

async function exportTestKey(keyPair: CryptoKeyPair, keyId: string, alg: string): Promise<TestSigningKey> {
  const exported = (await crypto.subtle.exportKey('jwk', keyPair.publicKey)) as Record<string, unknown>;
  const jwk = {
    kty: exported['kty'],
    ...(exported['kty'] === 'RSA' ? { n: exported['n'], e: exported['e'] } : { crv: exported['crv'], x: exported['x'], y: exported['y'] }),
    alg,
    use: 'sig',
    kid: keyId,
  } as Jwk;
  return { privateKey: keyPair.privateKey, jwk, jwks: { keys: [jwk] } };
}
```

## CLI integration and the generated code

The CLI extracts the generated code from `apps/hono/src/oidc-provider` (Hono, Express, Fastify) and `apps/nextjs/src/app` (Next.js).
The feature's code is confined to the `features/dynamic-client-registration/` directory, and this one line of `packages/cli/src/registry.ts` ties it to `--enable dynamic-client-registration`:

```typescript
{ id: 'dynamic-client-registration', tier: 'experimental', requires: [], packages: EXPERIMENTAL, frameworks: ALL_FRAMEWORKS, runtimes: ALL_RUNTIMES, summary: 'Dynamic Client Registration (RFC 7591)' },
```

Disabled by default; the directory below is copied into the output only with `--enable dynamic-client-registration`, and the output without the flag is unchanged.

```text
features/dynamic-client-registration/
  feature.ts                                 # route, discovery, context (client and key resolution composed)
  config.ts                                  # settings object, the applyOidc option, the RegisteredClient extension
  store.ts                                   # in-memory store, the stored record, the resolver wrappers
  endpoints/register/
    endpoint.ts                              # the steps (the boxes maronn-oidc graph draws)
    pipeline.ts                              # POST /register itself, calling the steps in order
    response.ts                              # the response shape and the fixed-response error
    steps/verify-initial-access-token.ts
    steps/parse-request.ts
    steps/verify-software-statement.ts
    steps/validate-metadata.ts
    steps/store-client.ts
    steps/respond.ts
    steps/respond-error.ts
```

### feature.ts

Declares the `/register` route, the `registration_endpoint` member and the per-request context.
The context merges the `applyOidc` option over the settings and wraps the base client and key resolution with the dynamic store.

```typescript
import { defineFeature } from '../feature.js';
import { dynamicClientRegistrationConfig, extendDynamicClientRegistrationConfig } from './config.js';
import { registerApp } from './endpoints/register/pipeline.js';
import {
  dynamicClientStore,
  withDynamicallyRegisteredClientKeys,
  withDynamicallyRegisteredClients,
} from './store.js';

/**
 * EXPERIMENTAL — OAuth 2.0 Dynamic Client Registration (RFC 7591): POST
 * /register. The clients it issues are kept in an in-memory store
 * (store.ts) and resolved after the configured clients, so a static
 * registration always wins; the public keys a registration carried (jwks)
 * are handed out by the ClientKeyResolver the same way. Registration
 * management (RFC 7592) is not implemented. The settings, the optional
 * verifier functions (initial access token, software statement) and the
 * custom metadata are in config.ts.
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
    dynamicClientRegistrationConfig: extendDynamicClientRegistrationConfig(dynamicClientRegistrationConfig, options.dynamicClientRegistration),
    // Dynamically registered clients, and their keys, resolve after the configured clients.
    clientResolver: withDynamicallyRegisteredClients(c.get('clientResolver')),
    tokenClientResolver: withDynamicallyRegisteredClients(c.get('tokenClientResolver')),
    clientKeyResolver: withDynamicallyRegisteredClientKeys(c.get('clientKeyResolver')),
  }),
});
```

### config.ts

The defaults of the settings object, the `dynamicClientRegistration` option of `createApp` / `applyOidc`, and the `RegisteredClient.registrationMetadata` declaration.
The registration decisions live in the same settings as two optional functions (`verifyInitialAccessToken`, `verifySoftwareStatement`) and the custom metadata table; both functions are `undefined` as generated.

```typescript
import type {
  CustomClientMetadataValidator,
  VerifiedSoftwareStatement,
} from '@maronn-openid-connect/experimental/dynamic-client-registration';

/**
 * Decides whether a registration request may register, from the Bearer token
 * of its Authorization header (OIDC Dynamic Client Registration 1.0 §3; RFC
 * 6750 §2.1). true accepts the request; false answers 401 with
 * error="invalid_token" (RFC 6750 §3.1). A request without a Bearer token is
 * answered 401 with a bare challenge before this function runs.
 */
export type InitialAccessTokenVerifier = (
  token: string,
  config: DynamicClientRegistrationConfig,
) => Promise<boolean> | boolean;

/**
 * Verifies a software_statement (RFC 7591 §2.3) and returns the metadata it
 * asserts, which the register endpoint applies over the plain JSON values
 * (RFC 7591 §3.1.1). Throw ClientRegistrationError with
 * invalid_software_statement or unapproved_software_statement to reject it
 * (§3.2.2). RFC 7591 leaves the trust criteria to the server, so this function
 * alone decides them: which issuers it accepts, how it verifies the signature,
 * which claims it reads. Nothing in the generated code examines the statement.
 */
export type SoftwareStatementVerifier = (
  softwareStatement: string,
  config: DynamicClientRegistrationConfig,
) => Promise<VerifiedSoftwareStatement> | VerifiedSoftwareStatement;

/**
 * Dynamic client registration settings. The dynamicClientRegistration option of
 * createApp() / applyOidc() extends these defaults (feature.ts,
 * extendDynamicClientRegistrationConfig below), so change them here or per
 * deployment there — the verifier functions included.
 *
 * - maxRegisteredClients: inventory cap on dynamic registrations
 *   (RFC 7591 §5 DoS consideration). The cap answers 429, not
 *   invalid_client_metadata: nothing about the metadata is wrong, so a
 *   metadata-retry loop must not be invited.
 * - maxRegistrationBodyBytes: request body limit in UTF-8 bytes.
 * - tokenEndpointAuthMethods: the token_endpoint_auth_method values a client may
 *   register (RFC 7591 §2). The three of core as generated; add private_key_jwt
 *   or another method here once the authenticate-client step of endpoints/token/
 *   verifies it. A method outside client_secret_basic / client_secret_post /
 *   client_secret_jwt registers a confidential client without a client_secret.
 * - grantTypes: the grant_type values a client may register, among those this
 *   provider answers (authorization_code, the grants of the generated features,
 *   implicit while a feature answers a token or id_token response type). A
 *   grant the provider does not answer is never registrable, whatever is listed
 *   here. Add the URN of an experimental grant (token exchange, device code,
 *   CIBA) to let dynamically registered clients use it.
 * - jwksPurposes: the ClientKeyResolver purposes the jwks of a registration
 *   serves — a registered key verifies signed Request Objects (request_object),
 *   and stands ready for private_key_jwt and DPoP once a project adds them.
 * - verifyInitialAccessToken: undefined as generated, which leaves registration
 *   open (RFC 7591 §3.1 SHOULD). Set a function to require an initial access
 *   token (OIDC Dynamic Client Registration 1.0 §3): POST /register then answers
 *   401 to a request without a Bearer token, and the function decides whether
 *   the presented token may register. The generated code verifies no token of
 *   its own — the token format, its issuance and its lookup are the function's.
 * - verifySoftwareStatement: undefined as generated, which ignores a
 *   software_statement (RFC 7591 §3.1.1 lets a server that does not support
 *   them do so). Set a function to accept software statements: POST /register
 *   then requires one (invalid_client_metadata without it), and the function
 *   verifies it and returns the metadata it asserts. The generated code
 *   verifies no statement of its own.
 * - customClientMetadata: metadata beyond the standard fields that a
 *   registration may carry (RFC 7591 §2 lets a provider understand more). Each
 *   entry names one field and validates its value: return the value to register
 *   (it is echoed in the 201 response and kept in
 *   RegisteredClient.registrationMetadata), return undefined to leave the field
 *   out, or throw ClientRegistrationError with invalid_client_metadata to reject
 *   the registration. The validator also runs when the field is absent, so it
 *   can return a default. Empty as generated: every field outside the standard
 *   ones is ignored (RFC 7591 §2 MUST). Example — a tenant identifier of at
 *   most 64 characters:
 *
 *     tenant_id: (value) => {
 *       if (value === undefined) return undefined;
 *       if (typeof value !== 'string' || !/^[a-z0-9-]{1,64}$/.test(value)) {
 *         throw new ClientRegistrationError('invalid_client_metadata', 'tenant_id must be a lowercase identifier');
 *       }
 *       return value;
 *     },
 */
export interface DynamicClientRegistrationConfig {
  maxRegisteredClients: number;
  maxRegistrationBodyBytes: number;
  tokenEndpointAuthMethods: readonly string[];
  grantTypes: readonly string[];
  jwksPurposes: readonly string[];
  verifyInitialAccessToken: InitialAccessTokenVerifier | undefined;
  verifySoftwareStatement: SoftwareStatementVerifier | undefined;
  customClientMetadata: Readonly<Record<string, CustomClientMetadataValidator>>;
}

export const dynamicClientRegistrationConfig: DynamicClientRegistrationConfig = {
  maxRegisteredClients: 100,
  maxRegistrationBodyBytes: 16384,
  tokenEndpointAuthMethods: ['client_secret_basic', 'client_secret_post', 'none'],
  grantTypes: ['authorization_code', 'refresh_token', 'implicit'],
  jwksPurposes: ['request_object', 'private_key_jwt', 'dpop'],
  verifyInitialAccessToken: undefined,
  verifySoftwareStatement: undefined,
  customClientMetadata: {},
};

/**
 * The settings of a deployment: the generated defaults with the
 * dynamicClientRegistration option of createApp() / applyOidc() applied.
 *
 * The option adds to the lists and the table instead of replacing them, so a
 * deployment extends what the generated code allows without repeating it:
 * tokenEndpointAuthMethods, grantTypes and jwksPurposes gain the given values
 * (each once), and customClientMetadata gains the given validators (one with
 * the name of a generated validator replaces it). The scalar settings and the
 * verifier functions replace the defaults; a field left out or undefined keeps
 * them. To take a value out of a generated list, or to drop a verifier set
 * above, edit it in config.ts.
 */
export function extendDynamicClientRegistrationConfig(
  base: DynamicClientRegistrationConfig,
  additions: Partial<DynamicClientRegistrationConfig> = {},
): DynamicClientRegistrationConfig {
  const { tokenEndpointAuthMethods, grantTypes, jwksPurposes, customClientMetadata: customMetadata, ...replaced } = additions;
  const config: DynamicClientRegistrationConfig = { ...base };
  for (const [name, value] of Object.entries(replaced)) {
    if (value !== undefined) (config as unknown as Record<string, unknown>)[name] = value;
  }
  config.tokenEndpointAuthMethods = [...new Set([...base.tokenEndpointAuthMethods, ...(tokenEndpointAuthMethods ?? [])])];
  config.grantTypes = [...new Set([...base.grantTypes, ...(grantTypes ?? [])])];
  config.jwksPurposes = [...new Set([...base.jwksPurposes, ...(jwksPurposes ?? [])])];
  config.customClientMetadata = { ...base.customClientMetadata, ...customMetadata };
  return config;
}

declare module '../../app.js' {
  interface OidcProviderOptions {
    /**
     * EXPERIMENTAL (RFC 7591): extend the dynamic client registration
     * settings (dynamicClientRegistrationConfig in
     * features/dynamic-client-registration/config.ts) per deployment — for
     * example from environment variables — without editing the generated
     * file (extendDynamicClientRegistrationConfig). The lists and the custom
     * metadata table gain the given values, the scalar settings and the
     * verifier functions (verifyInitialAccessToken, verifySoftwareStatement)
     * replace the generated ones, and an unset field keeps them.
     */
    dynamicClientRegistration?: Partial<DynamicClientRegistrationConfig>;
  }
}

declare module '../../config.js' {
  interface RegisteredClient {
    /**
     * EXPERIMENTAL (RFC 7591): every metadata value a dynamic registration
     * registered, in the wire form of the registration response (defaults
     * applied, custom metadata included), so a project's own code can read
     * client_name, logo_uri or a custom field of the client. Absent for the
     * clients of db/.
     */
    registrationMetadata?: Readonly<Record<string, unknown>>;
  }
}
```

### store.ts

The store contract has four methods, `get` / `save` / `count` / `delete`, and its record is the `ClientRegistration` that `registerClient()` of `db/` takes.
`toClientRegistration` maps the experimental record into that shape; `withDynamicallyRegisteredClients` and `withDynamicallyRegisteredClientKeys` wrap the base resolvers.

```typescript
import type { ClientKeyResolver, ClientKeysByPurpose, JwkSet } from '@maronn-openid-connect/core';
import type { DynamicallyRegisteredClient } from '@maronn-openid-connect/experimental/dynamic-client-registration';
import type { ClientRegistration, RegisteredClient } from '../../config.js';

/**
 * EXPERIMENTAL — store contract for dynamically registered clients (RFC 7591).
 *
 * - get(clientId): return the registration, or undefined when unknown.
 * - save(registration): persist it under registration.clientId. The record is
 *   a ClientRegistration as registerClient() of db/ takes it: the client and
 *   its public keys by purpose (keys), the client_secret as its hash.
 * - count(): how many dynamic registrations exist, for the
 *   maxRegisteredClients inventory cap (RFC 7591 §5 DoS consideration).
 * - delete(clientId): remove one registration — the register endpoint
 *   withdraws its own save when concurrent requests overshot the cap.
 */
export interface DynamicallyRegisteredClientStore {
  get(clientId: string): Promise<ClientRegistration | undefined>;
  save(registration: ClientRegistration): Promise<void>;
  count(): Promise<number>;
  delete(clientId: string): Promise<void>;
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
  private clients = new Map<string, ClientRegistration>();

  async get(clientId: string): Promise<ClientRegistration | undefined> {
    return this.clients.get(clientId);
  }

  async save(registration: ClientRegistration): Promise<void> {
    this.clients.set(registration.clientId, registration);
  }

  async count(): Promise<number> {
    return this.clients.size;
  }

  async delete(clientId: string): Promise<void> {
    this.clients.delete(clientId);
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
 * EXPERIMENTAL — the record the store keeps for a client the register endpoint
 * built (RFC 7591): the fields the provider reads (what registerClient() of db/
 * takes), the public keys of its jwks under every purpose of jwksPurposes, and
 * the registered metadata for a project's own code (RegisteredClient.registrationMetadata).
 *
 * The experimental package types the auth method and the signed response algs
 * as strings, because it does not know the methods and algs of this provider.
 * The register endpoint validated them against the registration config and the
 * signing keys of this provider, so the record narrows them to the values
 * RegisteredClient takes without another check.
 */
export function toClientRegistration(
  client: DynamicallyRegisteredClient,
  options: { clientSecretHash?: string; jwksPurposes: readonly string[] },
): ClientRegistration {
  const tokenEndpointAuthMethods: readonly string[] = client.tokenEndpointAuthMethods;
  return {
    clientId: client.clientId,
    clientType: client.clientType,
    redirectUris: [...client.redirectUris],
    grantTypes: [...client.grantTypes],
    responseTypes: [...client.responseTypes],
    tokenEndpointAuthMethods: tokenEndpointAuthMethods as RegisteredClient['tokenEndpointAuthMethods'],
    ...(client.scope === undefined ? {} : { scope: [...client.scope] }),
    ...(client.defaultMaxAge === undefined ? {} : { defaultMaxAge: client.defaultMaxAge }),
    ...(client.idTokenSignedResponseAlg === undefined
      ? {}
      : { idTokenSignedResponseAlg: client.idTokenSignedResponseAlg as RegisteredClient['idTokenSignedResponseAlg'] }),
    ...(client.userinfoSignedResponseAlg === undefined
      ? {}
      : { userinfoSignedResponseAlg: client.userinfoSignedResponseAlg as RegisteredClient['userinfoSignedResponseAlg'] }),
    ...(options.clientSecretHash === undefined ? {} : { clientSecretHash: options.clientSecretHash }),
    ...(client.jwks === undefined ? {} : { keys: keysByPurpose(client.jwks, options.jwksPurposes) }),
    registrationMetadata: { ...client.metadata },
  };
}

function keysByPurpose(jwks: JwkSet, purposes: readonly string[]): ClientKeysByPurpose {
  const keys: ClientKeysByPurpose = {};
  for (const purpose of purposes) {
    keys[purpose] = { keys: jwks.keys.map((key) => ({ ...key })) };
  }
  return keys;
}

/**
 * EXPERIMENTAL — consult the dynamically registered clients (RFC 7591) after
 * the configured resolver, so a statically registered client can never be
 * shadowed by a dynamic registration (ids minted at /register carry the dcr-
 * prefix and cannot collide with human-named static ids anyway).
 *
 * The wrapper keeps the base resolver's own type: a value serving as both
 * ClientResolver and TokenClientResolver stays usable as both, and the
 * RegisteredClient records the store adds satisfy either view. The keys of
 * the registration stay out of the client, as in db/ (the ClientKeyResolver
 * hands them out by purpose).
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
      const registration = await dynamicClientStore.get(clientId);
      if (!registration) {
        return null;
      }
      const { keys: _keys, ...client } = registration;
      return client;
    },
  } as Resolver;
}

/**
 * EXPERIMENTAL — hand out the public keys a dynamic registration carried in its
 * jwks (RFC 7591 §2) by purpose, after the keys of the configured resolver: a
 * client db/ knows keeps its own keys, and a dynamically registered one gets
 * those of its registration (under the purposes of jwksPurposes). A client
 * neither knows, or a purpose without keys, resolves to an empty key set, as
 * core's ClientKeyResolver contract asks.
 */
export function withDynamicallyRegisteredClientKeys(base: ClientKeyResolver): ClientKeyResolver {
  return {
    ...base,
    async findClientKeys(clientId, purpose): Promise<JwkSet> {
      const registered = await base.findClientKeys(clientId, purpose);
      if (registered.keys.length > 0) {
        return registered;
      }
      const registration = await dynamicClientStore.get(clientId);
      return { keys: [...(registration?.keys?.[purpose]?.keys ?? [])] };
    },
  };
}
```

### endpoints/register/endpoint.ts

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
    'verify-software-statement',
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

### endpoints/register/pipeline.ts

The order is: registration policy, Content-Type and Content-Length pre-checks and the body read, software statement verification and application, metadata validation and defaults, cap and store, 201; the first failing stage answers.
The policy runs before the body is read, so an unauthorized request never gets its body interpreted.

```typescript
import { Hono } from 'hono';
import { parseRegistrationRequest } from './steps/parse-request.js';
import { respondRegistrationError } from './steps/respond-error.js';
import { respondRegistration } from './steps/respond.js';
import { storeRegisteredClient } from './steps/store-client.js';
import { validateRegistrationMetadata } from './steps/validate-metadata.js';
import { verifyRegistrationAccess } from './steps/verify-initial-access-token.js';
import { resolveRegistrationMetadata } from './steps/verify-software-statement.js';

/**
 * EXPERIMENTAL — Dynamic Client Registration (RFC 7591).
 *
 * This endpoint was generated because the OP was created with
 * `--enable dynamic-client-registration`.
 * It is backed by @maronn-openid-connect/experimental, whose API is NOT stable: it may
 * change in a breaking way between releases. Do not build production code on it
 * without pinning the version.
 *
 * The client POSTs its metadata here as JSON — optionally bundled in a signed
 * software statement of a publisher this OP trusts — and receives a freshly
 * minted client_id (and, for confidential clients, a client_secret) that works
 * on /authorize and /token right away. Registration is open by default
 * (RFC 7591 §3.1 SHOULD) and a software_statement is ignored (§3.1.1); set
 * verifyInitialAccessToken / verifySoftwareStatement of ../../config.ts to
 * require them and verify them with functions of your own — this code
 * verifies neither. Metadata beyond the standard fields is accepted through
 * customClientMetadata of the same config.
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
    // [verify-initial-access-token] Check that the request may register — OIDC Dynamic Client Registration 1.0 §3 / RFC 6750 §3.1
    await verifyRegistrationAccess(c);

    // [parse-request] Read the JSON metadata — RFC 7591 §3.1
    const registration = await parseRegistrationRequest(c);

    // [verify-software-statement] Verify the software statement and apply the metadata it asserts — RFC 7591 §2.3 / §3.1.1
    const metadata = await resolveRegistrationMetadata(c, registration);

    // [validate-metadata] Validate the metadata and build the client — RFC 7591 §2 / §2.1
    const client = validateRegistrationMetadata(c, metadata);

    // [store-client] Enforce the inventory cap and store the client — RFC 7591 §5
    await storeRegisteredClient(c, client);

    // [respond] Respond 201 with the registration response — RFC 7591 §3.2.1
    return respondRegistration(c, client);
  } catch (error) {
    return respondRegistrationError(c, error);
  }
});
```

### endpoints/register/response.ts

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

### steps/verify-initial-access-token.ts

Does nothing without `verifyInitialAccessToken` in the config.
With one, the presence of a Bearer token picks the 401 shape, and the token is handed to the function.

```typescript
import { readBearerToken } from '@maronn-openid-connect/experimental/dynamic-client-registration';
import { RegistrationEndpointError } from '../response.js';
import { step } from '../../../../../endpoints/step.js';

export const meta = step({
  id: 'verify-initial-access-token',
  endpoint: 'register',
  feature: 'dynamic-client-registration',
  kind: 'validate',
  label: 'Check that the request may register',
  spec: 'OIDC Dynamic Client Registration 1.0 §3 / RFC 6750 §3.1',
  function: 'verifyRegistrationAccess',
  calls: ['readBearerToken', 'verifyInitialAccessToken'],
  consumes: [],
  produces: [],
  removable: false,
});

/**
 * Ask the verifyInitialAccessToken of the config whether the request may
 * register, before the body is read (OIDC Dynamic Client Registration 1.0 §3).
 *
 * No function configured means open registration (RFC 7591 §3.1 SHOULD): every
 * request passes. With one, the request must carry a Bearer token (RFC 6750
 * §2.1) — 401 with a bare challenge without one, as RFC 6750 §3.1 asks for a
 * request without credentials — and the function decides whether that token
 * may register: 401 error="invalid_token" when it says no. Nothing here
 * verifies the token itself, and neither response reflects anything about
 * the expected token.
 */
export async function verifyRegistrationAccess(c: any): Promise<void> {
  const config = c.get('dynamicClientRegistrationConfig');
  if (config.verifyInitialAccessToken === undefined) return;
  const token = readBearerToken(c.req.header('Authorization'));
  if (token === undefined) {
    throw new RegistrationEndpointError({ status: 401, body: null, headers: { 'WWW-Authenticate': 'Bearer' } });
  }
  if (await config.verifyInitialAccessToken(token, config)) return;
  throw new RegistrationEndpointError({
    status: 401,
    body: null,
    headers: { 'WWW-Authenticate': 'Bearer error="invalid_token"' },
  });
}
```

### steps/parse-request.ts

Beside conforming to RFC 7591 §3.1, the `Content-Type` check closes the cross-origin `text/plain` POST that can synthesize a JSON-shaped body without a CORS preflight.

```typescript
import {
  parseClientRegistrationBody,
  type ParsedClientRegistration,
} from '@maronn-openid-connect/experimental/dynamic-client-registration';
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
  calls: ['parseClientRegistrationBody'],
  consumes: [],
  produces: ['registration'],
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
 *
 * A Content-Length that already declares more than maxRegistrationBodyBytes is
 * refused before the body is read, so an oversized request is not buffered
 * first. The header can lie, so the authoritative check stays the UTF-8 byte
 * count on the body itself (parseClientRegistrationBody), which also checks
 * the JSON shape and splits a software_statement (RFC 7591 §2.3) from the
 * plain metadata for the next step.
 */
export async function parseRegistrationRequest(c: any): Promise<ParsedClientRegistration> {
  if (!isJson(c.req.header('Content-Type') ?? '')) {
    throw new RegistrationEndpointError({
      status: 400,
      body: { error: 'invalid_client_metadata', error_description: 'registration requests must use application/json' },
    });
  }
  const config = c.get('dynamicClientRegistrationConfig');
  const declaredLength = Number(c.req.header('Content-Length') ?? '0');
  if (Number.isFinite(declaredLength) && declaredLength > config.maxRegistrationBodyBytes) {
    throw new RegistrationEndpointError({
      status: 400,
      body: { error: 'invalid_client_metadata', error_description: 'request body must not exceed the configured maximum size' },
    });
  }
  const rawBody = await c.req.text();
  return parseClientRegistrationBody(rawBody, { maxBodyBytes: config.maxRegistrationBodyBytes });
}
```

### steps/verify-software-statement.ts

Without `verifySoftwareStatement` in the config the statement is ignored and the plain values pass through.
With one, a statement is required and the claims the function returns are applied.

```typescript
import {
  applySoftwareStatement,
  ClientRegistrationError,
  type ParsedClientRegistration,
} from '@maronn-openid-connect/experimental/dynamic-client-registration';
import { step } from '../../../../../endpoints/step.js';

export const meta = step({
  id: 'verify-software-statement',
  endpoint: 'register',
  feature: 'dynamic-client-registration',
  kind: 'validate',
  label: 'Verify the software statement and apply the metadata it asserts',
  spec: 'RFC 7591 §2.3 / §3.1.1',
  function: 'resolveRegistrationMetadata',
  calls: ['verifySoftwareStatement', 'applySoftwareStatement'],
  consumes: ['registration'],
  produces: ['metadata'],
  removable: false,
});

/**
 * The metadata to register: the plain JSON values, with those a verified
 * software statement asserts taking precedence (RFC 7591 §3.1.1).
 *
 * No verifySoftwareStatement in the config means this provider does not
 * support software statements: a software_statement in the request is
 * ignored, as §3.1.1 allows, and the plain values register. With one, every
 * registration must carry a software_statement (invalid_client_metadata
 * without it); the function verifies it — RFC 7591 leaves the trust criteria
 * to the server, so nothing here examines the statement — and rejects it with
 * ClientRegistrationError (invalid_software_statement or
 * unapproved_software_statement; §3.2.2). The metadata it returns is applied
 * over the plain values, and the statement itself is kept so the 201 response
 * returns it unmodified (§3.2.1).
 */
export async function resolveRegistrationMetadata(
  c: any,
  registration: ParsedClientRegistration,
): Promise<Record<string, unknown>> {
  const config = c.get('dynamicClientRegistrationConfig');
  if (config.verifySoftwareStatement === undefined) {
    return registration.metadata;
  }
  if (registration.softwareStatement === undefined) {
    throw new ClientRegistrationError('invalid_client_metadata', 'software_statement is required');
  }
  const verified = await config.verifySoftwareStatement(registration.softwareStatement, config);
  return applySoftwareStatement(registration.metadata, registration.softwareStatement, verified);
}
```

### steps/validate-metadata.ts

Where what the OP answers meets the experimental validation: the response types come from `supportedResponseTypes()` of the authorization endpoint, the grants from `tokenGrantsOf(features)`, the scopes from `scopes.ts`, the signing algorithms from the signing keys in the context.

```typescript
import { getJwaAlgorithm, responseTypeIncludes, type SigningKey } from '@maronn-openid-connect/core';
import {
  buildRegisteredClient,
  validateClientMetadata,
  type DynamicallyRegisteredClient,
} from '@maronn-openid-connect/experimental/dynamic-client-registration';
import { supportedResponseTypes } from '../../../../../endpoints/authorize/response-type.js';
import { step } from '../../../../../endpoints/step.js';
import { CUSTOM_SCOPES, STANDARD_SCOPES } from '../../../../../scopes.js';
import { features } from '../../../../enabled.js';
import { tokenGrantsOf } from '../../../../feature.js';
import type { DynamicClientRegistrationConfig } from '../../../config.js';

export const meta = step({
  id: 'validate-metadata',
  endpoint: 'register',
  feature: 'dynamic-client-registration',
  kind: 'validate',
  label: 'Validate the metadata and build the client',
  spec: 'RFC 7591 §2 / §2.1',
  function: 'validateRegistrationMetadata',
  calls: ['supportedResponseTypes', 'tokenGrantsOf', 'getJwaAlgorithm', 'validateClientMetadata', 'buildRegisteredClient'],
  consumes: ['metadata'],
  produces: ['client'],
  removable: false,
});

/**
 * Allowlist-pick of the understood fields, value checks, the RFC 7591 §2 and
 * OIDC Dynamic Client Registration 1.0 §2 defaults (application_type web,
 * id_token_signed_response_alg RS256 — registered and returned, §3.2), the
 * redirect_uris constraints of the application type and the §2.1 consistency
 * of grant_types and response_types — pure functions from the experimental
 * package, bounded to what this provider answers:
 *
 * - token_endpoint_auth_method: the methods of the registration config
 * - grant_types: the grants of the config that this provider answers
 *   (authorization_code, the token grants of the generated features, implicit
 *   while a feature answers a token or id_token response type)
 * - response_types: code and the response types of the generated features,
 *   as discovery advertises them
 * - scope: any value until a custom scope is declared (scopes.ts), then the
 *   standard and the declared ones
 * - id_token_signed_response_alg / userinfo_signed_response_alg: the algs of
 *   the registered signing keys, as discovery advertises them
 * - the custom metadata of the registration config (config.ts)
 *
 * Unknown metadata is silently ignored (§2 MUST), and every error_description
 * is a fixed ASCII string that never reflects request values.
 */
export function validateRegistrationMetadata(
  c: any,
  metadata: Record<string, unknown>,
): DynamicallyRegisteredClient {
  const config: DynamicClientRegistrationConfig = c.get('dynamicClientRegistrationConfig');
  const responseTypes = supportedResponseTypes();
  const validated = validateClientMetadata(metadata, {
    tokenEndpointAuthMethods: config.tokenEndpointAuthMethods,
    grantTypes: registrableGrantTypes(config.grantTypes, responseTypes),
    responseTypes,
    scopes: registrableScopes(),
    idTokenSigningAlgValuesSupported: signingAlgsOf(c.get('idTokenSigningKeys')),
    userinfoSigningAlgValuesSupported: signingAlgsOf(c.get('userinfoSigningKeys')),
    customMetadata: config.customClientMetadata,
  });
  return buildRegisteredClient(validated);
}

/**
 * The grant_type values of the registration config that this provider answers
 * (RFC 7591 §2): authorization_code always, the grants the generated features
 * answer at the token endpoint, and implicit while a feature answers a token or
 * id_token response type at /authorize (OIDC Dynamic Client Registration 1.0 §2
 * pairs them). A grant the provider does not answer is never registrable: a
 * client registered for it could not use it.
 */
export function registrableGrantTypes(configured: readonly string[], responseTypes: readonly string[]): string[] {
  const offered = ['authorization_code', ...tokenGrantsOf(features)];
  const answersImplicit = responseTypes.some(
    (responseType) => responseTypeIncludes(responseType, 'token') || responseTypeIncludes(responseType, 'id_token'),
  );
  if (answersImplicit) offered.push('implicit');
  return configured.filter((grantType) => offered.includes(grantType));
}

/**
 * scopes.ts: once a custom scope is declared, a registration may name only the
 * standard and the declared scopes (what findUnsupportedScopes() accepts at
 * /authorize); without one there is no list, and any syntactically valid value
 * registers.
 */
export function registrableScopes(): readonly string[] | undefined {
  return CUSTOM_SCOPES.length === 0 ? undefined : [...STANDARD_SCOPES, ...CUSTOM_SCOPES];
}

/** The JWA algs of a registered signing key set, each once (what discovery advertises for it). */
function signingAlgsOf(keys: SigningKey[] | undefined): string[] {
  return [...new Set((keys ?? []).map((key) => getJwaAlgorithm(key.privateKey)))];
}
```

### steps/store-client.ts

```typescript
import { hashClientSecret } from '@maronn-openid-connect/core';
import type { DynamicallyRegisteredClient } from '@maronn-openid-connect/experimental/dynamic-client-registration';
import { RegistrationEndpointError } from '../response.js';
import { step } from '../../../../../endpoints/step.js';
import { toClientRegistration } from '../../../store.js';

export const meta = step({
  id: 'store-client',
  endpoint: 'register',
  feature: 'dynamic-client-registration',
  kind: 'persist',
  label: 'Enforce the inventory cap and store the client',
  spec: 'RFC 7591 §5',
  function: 'storeRegisteredClient',
  calls: ['hashClientSecret', 'toClientRegistration'],
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
 *
 * The stored record (toClientRegistration) keeps the client_secret only as its
 * hash, like the statically registered clients (db/memory/clients.ts
 * registerClient), and the keys of the jwks under the purposes of the config:
 * the 201 response is built from the in-memory record this step receives, so
 * the plaintext never needs to rest in the store.
 */
export async function storeRegisteredClient(c: any, client: DynamicallyRegisteredClient): Promise<void> {
  const config = c.get('dynamicClientRegistrationConfig');
  const store = c.get('dynamicClientStore');
  if ((await store.count()) >= config.maxRegisteredClients) {
    throw inventoryCapError();
  }
  const clientSecretHash = client.clientSecret === undefined ? undefined : await hashClientSecret(client.clientSecret);
  await store.save(toClientRegistration(client, { clientSecretHash, jwksPurposes: config.jwksPurposes }));
  // Concurrent requests can pass the cap check together (the awaits above let
  // them interleave), so re-check after saving and withdraw this registration
  // when the save overshot the cap: the cap is never exceeded, only approached.
  if ((await store.count()) > config.maxRegisteredClients) {
    await store.delete(client.clientId);
    throw inventoryCapError();
  }
  // Never log the registration metadata or the issued client_secret.
}

function inventoryCapError(): RegistrationEndpointError {
  return new RegistrationEndpointError({
    status: 429,
    body: { error: 'too_many_registrations', error_description: 'registration limit reached' },
  });
}
```

### steps/respond.ts

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

### steps/respond-error.ts

```typescript
import { isClientRegistrationError } from '@maronn-openid-connect/experimental/dynamic-client-registration';
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
 * metadata (invalid_redirect_uri, invalid_client_metadata) and for a software
 * statement that is not accepted (invalid_software_statement,
 * unapproved_software_statement); the fixed responses of the earlier steps
 * (401, 429) as they are. The registration errors are told apart by shape
 * (isClientRegistrationError), not by class: a verifier function of the
 * dynamicClientRegistration option may come from another copy of the
 * experimental package.
 */
export function respondRegistrationError(c: any, error: unknown): Response {
  if (error instanceof RegistrationEndpointError) {
    return sendRegistrationResponse(c, error.response);
  }
  if (isClientRegistrationError(error)) {
    return sendRegistrationResponse(c, {
      status: 400,
      body: { error: error.error, error_description: error.errorDescription },
    });
  }
  return sendRegistrationResponse(c, { status: 500, body: { error: 'server_error' } });
}
```

### The other frameworks

- **Express / Fastify**: extracted from the same `apps/hono/src/oidc-provider`, so the files above are generated as they are; only `apply.ts` and the web-standard router layer differ, and the feature's code is identical
- **Next.js (App Router)**: `(dynamic-client-registration)/register/route.ts` is the Route Handler, with the same order of operations as the Hono version. Settings, policy and store live in `_oidc-provider/features/dynamic-client-registration/` as `config.ts`, `store.ts` and `feature.ts`, with the Hono content in Next.js import style (`config.ts` uses `shared()` for one object per process). So that the feature can wrap key resolution, `ProviderContext` of `_oidc-provider/feature.ts` gained `clientKeyResolver`, and `clientKeyResolver` of `provider.ts` now passes through the context hooks of the features

The Next.js Route Handler, in full:

```typescript
/**
 * EXPERIMENTAL — Client Registration Endpoint (RFC 7591 §3).
 *
 * Generated because the OP was created with
 * `--enable dynamic-client-registration`. Backed by @maronn-openid-connect/experimental,
 * whose API is NOT stable: it may change in a breaking way between releases.
 * Do not build production code on it without pinning the version.
 *
 * The client POSTs its metadata here as JSON — optionally bundled in a signed
 * software statement of a publisher this OP trusts — and receives a freshly
 * minted client_id (and, for confidential clients, a client_secret) that works
 * on /authorize and /token right away. Registration is open by default
 * (RFC 7591 §3.1 SHOULD) and a software_statement is ignored (§3.1.1); set
 * verifyInitialAccessToken / verifySoftwareStatement of
 * dynamicClientRegistrationConfig
 * (_oidc-provider/features/dynamic-client-registration/config.ts) to require
 * them and verify them with functions of your own — this code verifies
 * neither. Metadata beyond the standard fields is accepted through
 * customClientMetadata of the same config.
 *
 * NOTE (RFC 7591 §5): per-IP rate limiting is deliberately left to the
 * deployment layer (reverse proxy / platform); this endpoint only enforces the
 * inventory and body-size caps of that config.ts. Open registration grants no
 * trust: what an issued client can do stays bounded by the same validation as
 * a static client (PKCE, exact redirect_uri match, client authentication).
 */
import { getJwaAlgorithm, hashClientSecret, responseTypeIncludes, type SigningKey } from '@maronn-openid-connect/core';
import {
  applySoftwareStatement,
  buildClientRegistrationResponse,
  buildRegisteredClient,
  ClientRegistrationError,
  isClientRegistrationError,
  parseClientRegistrationBody,
  readBearerToken,
  validateClientMetadata,
  type ParsedClientRegistration,
} from '@maronn-openid-connect/experimental/dynamic-client-registration';
import { responseTypesOf, tokenGrantsOf } from '../../_oidc-provider/feature';
import { features } from '../../_oidc-provider/features';
import {
  dynamicClientRegistrationConfig,
  type DynamicClientRegistrationConfig,
} from '../../_oidc-provider/features/dynamic-client-registration/config';
import {
  dynamicClientStore,
  toClientRegistration,
} from '../../_oidc-provider/features/dynamic-client-registration/store';
import { clientCors, corsPreflight, signingKeysUnavailable, withCors } from '../../_oidc-provider/http';
import { loadSigningKeys } from '../../_oidc-provider/provider';
import { CUSTOM_SCOPES, STANDARD_SCOPES } from '../../_oidc-provider/scopes';

export const dynamic = 'force-dynamic';
export const runtime = 'nodejs';

export async function POST(request: Request): Promise<Response> {
  return withCors(request, clientCors, await registerClient(request));
}

export function OPTIONS(request: Request): Response {
  return corsPreflight(request, clientCors);
}

async function registerClient(request: Request): Promise<Response> {
  const config = dynamicClientRegistrationConfig;

  // (1) May the request register? Open registration while the config sets no
  // verifyInitialAccessToken (RFC 7591 §3.1 SHOULD). With one, the request
  // must carry a Bearer token (RFC 6750 §2.1) — a bare 401 challenge without
  // one, as RFC 6750 §3.1 asks for a request without credentials — and the
  // configured function decides whether that token may register (401
  // error="invalid_token" when it says no). Nothing here verifies the token
  // itself, and neither response reflects anything about the expected token.
  if (config.verifyInitialAccessToken !== undefined) {
    const token = readBearerToken(request.headers.get('Authorization'));
    if (token === undefined) return registration401('Bearer');
    if (!(await config.verifyInitialAccessToken(token, config))) {
      return registration401('Bearer error="invalid_token"');
    }
  }

  // (2) RFC 7591 §3.1: application/json only (parameters such as charset are
  // fine). Enforcing the media type also closes the cross-origin text/plain
  // form post that can synthesize a JSON-shaped body without a CORS preflight.
  if (!isJson(request.headers.get('Content-Type') ?? '')) {
    return registrationJson(
      { error: 'invalid_client_metadata', error_description: 'registration requests must use application/json' },
      400,
    );
  }

  // A Content-Length that already declares more than maxRegistrationBodyBytes
  // is refused before the body is read, so an oversized request is not
  // buffered first. The header can lie, so the authoritative check stays the
  // UTF-8 byte count on the body itself (parseClientRegistrationBody).
  const declaredLength = Number(request.headers.get('Content-Length') ?? '0');
  if (Number.isFinite(declaredLength) && declaredLength > config.maxRegistrationBodyBytes) {
    return registrationJson(
      { error: 'invalid_client_metadata', error_description: 'request body must not exceed the configured maximum size' },
      400,
    );
  }

  // The signed response algs a client may register are those of the signing
  // keys, as discovery advertises them.
  const keys = await loadSigningKeys().catch(() => null);
  if (!keys) return signingKeysUnavailable();

  try {
    // The body read sits inside the try so that an aborted or malformed
    // transfer still gets the fixed server_error JSON with no-store, like the
    // hono pipeline, instead of the framework's default 500.
    const rawBody = await request.text();

    // (3) Body size, JSON shape; a software_statement (RFC 7591 §2.3) is split
    // from the plain metadata.
    const registration = parseClientRegistrationBody(rawBody, { maxBodyBytes: config.maxRegistrationBodyBytes });

    // (4) RFC 7591 §3.1.1: without a verifySoftwareStatement in the config this
    // provider does not support software statements and ignores the member, as
    // §3.1.1 allows. With one, every registration must carry a
    // software_statement (invalid_client_metadata without it); the function
    // verifies it — RFC 7591 leaves the trust criteria to the server, so
    // nothing here examines the statement — and rejects with
    // invalid_software_statement or unapproved_software_statement (§3.2.2).
    // The metadata it returns is applied over the plain values, and the
    // statement comes back unmodified in the response (§3.2.1).
    const metadata = await resolveRegistrationMetadata(config, registration);

    // (5) Allowlist-pick of the understood fields, value checks, the RFC 7591
    // §2 and OIDC Dynamic Client Registration 1.0 §2 defaults (application_type
    // web, id_token_signed_response_alg RS256 — registered and returned, §3.2),
    // the redirect_uris constraints of the application type and the §2.1
    // consistency of grant_types and response_types — pure functions from
    // @maronn-openid-connect/experimental/dynamic-client-registration, bounded
    // to what this provider answers: the methods and grants of the config, the
    // response types of the features, the scopes of scopes.ts, the algs of the
    // signing keys and the custom metadata of the config. Unknown metadata is
    // silently ignored (§2 MUST), and every error_description is a fixed ASCII
    // string that never reflects request values.
    const responseTypes = ['code', ...responseTypesOf(features)];
    const validated = validateClientMetadata(metadata, {
      tokenEndpointAuthMethods: config.tokenEndpointAuthMethods,
      grantTypes: registrableGrantTypes(config.grantTypes, responseTypes),
      responseTypes,
      scopes: registrableScopes(),
      idTokenSigningAlgValuesSupported: signingAlgsOf(keys.idToken),
      userinfoSigningAlgValuesSupported: signingAlgsOf(keys.userinfo),
      customMetadata: config.customClientMetadata,
    });
    const client = buildRegisteredClient(validated);

    // (6) Inventory cap (RFC 7591 §5). 429 with a fixed body: the metadata is
    // fine, so answering invalid_client_metadata would invite a retry loop that
    // amplifies the very DoS surface the cap is here to close. No Retry-After —
    // the cap is a stock ceiling, not a rate, so no recovery time is promised.
    if ((await dynamicClientStore.count()) >= config.maxRegisteredClients) {
      return registrationJson(
        { error: 'too_many_registrations', error_description: 'registration limit reached' },
        429,
      );
    }

    // The stored record (toClientRegistration) keeps the client_secret only as
    // its hash, like the statically registered clients (_oidc-provider/db
    // registerClient), and the keys of the jwks under the purposes of the
    // config: the 201 response below is built from the in-memory record, so the
    // plaintext never needs to rest in the store.
    const clientSecretHash = client.clientSecret === undefined ? undefined : await hashClientSecret(client.clientSecret);
    await dynamicClientStore.save(toClientRegistration(client, { clientSecretHash, jwksPurposes: config.jwksPurposes }));
    // Concurrent requests can pass the cap check together (the awaits above let
    // them interleave), so re-check after saving and withdraw this registration
    // when the save overshot the cap: the cap is never exceeded, only approached.
    if ((await dynamicClientStore.count()) > config.maxRegisteredClients) {
      await dynamicClientStore.delete(client.clientId);
      return registrationJson(
        { error: 'too_many_registrations', error_description: 'registration limit reached' },
        429,
      );
    }

    // Never log the registration metadata or the issued client_secret.

    // RFC 7591 §3.2.1: 201 Created with the issued values and every registered
    // metadata value (defaults applied). client_secret_expires_at: 0 means the
    // secret does not expire.
    return registrationJson(buildClientRegistrationResponse(client), 201);
  } catch (error) {
    // RFC 7591 §3.2.2: 400 with error / error_description JSON. The error is
    // told apart by shape, not by class: the verifier functions of config.ts
    // may be set where the app starts (instrumentation.ts), which Next.js
    // bundles apart from this Route Handler, so their ClientRegistrationError
    // is another copy of the class.
    if (isClientRegistrationError(error)) {
      return registrationJson({ error: error.error, error_description: error.errorDescription }, 400);
    }
    return registrationJson({ error: 'server_error' }, 500);
  }
}

/**
 * The metadata to register: the plain values, with those a verified software
 * statement asserts taking precedence (RFC 7591 §3.1.1). Without a verifier the
 * provider does not support software statements and ignores the member; with
 * one the statement is required and the verifier alone judges it.
 */
async function resolveRegistrationMetadata(
  config: DynamicClientRegistrationConfig,
  registration: ParsedClientRegistration,
): Promise<Record<string, unknown>> {
  if (config.verifySoftwareStatement === undefined) {
    return registration.metadata;
  }
  if (registration.softwareStatement === undefined) {
    throw new ClientRegistrationError('invalid_client_metadata', 'software_statement is required');
  }
  const verified = await config.verifySoftwareStatement(registration.softwareStatement, config);
  return applySoftwareStatement(registration.metadata, registration.softwareStatement, verified);
}

/**
 * The grant_type values of the registration config that this provider answers
 * (RFC 7591 §2): authorization_code always, the grants the generated features
 * answer at the token endpoint, and implicit while a feature answers a token or
 * id_token response type at /authorize (OIDC Dynamic Client Registration 1.0 §2
 * pairs them). A grant the provider does not answer is never registrable: a
 * client registered for it could not use it.
 */
export function registrableGrantTypes(configured: readonly string[], responseTypes: readonly string[]): string[] {
  const offered = ['authorization_code', ...tokenGrantsOf(features)];
  const answersImplicit = responseTypes.some(
    (responseType) => responseTypeIncludes(responseType, 'token') || responseTypeIncludes(responseType, 'id_token'),
  );
  if (answersImplicit) offered.push('implicit');
  return configured.filter((grantType) => offered.includes(grantType));
}

/**
 * scopes.ts: once a custom scope is declared, a registration may name only the
 * standard and the declared scopes (what findUnsupportedScopes() accepts at
 * /authorize); without one there is no list, and any syntactically valid value
 * registers.
 */
export function registrableScopes(): readonly string[] | undefined {
  return CUSTOM_SCOPES.length === 0 ? undefined : [...STANDARD_SCOPES, ...CUSTOM_SCOPES];
}

/** The JWA algs of a registered signing key set, each once (what discovery advertises for it). */
function signingAlgsOf(keys: readonly SigningKey[]): string[] {
  return [...new Set(keys.map((key) => getJwaAlgorithm(key.privateKey)))];
}

/** RFC 7591 §3.1: the registration request body MUST be application/json. */
function isJson(contentType: string): boolean {
  const [mediaType = ''] = contentType.toLowerCase().split(';');
  return mediaType.trim() === 'application/json';
}

/** The 201 body carries the client_secret, so no registration response may be cached. */
function registrationJson(body: unknown, status: number): Response {
  return Response.json(body, {
    status,
    headers: { 'Cache-Control': 'no-store', Pragma: 'no-cache' },
  });
}

/** RFC 6750 §3.1: a 401 challenge with an empty body. */
function registration401(wwwAuthenticate: string): Response {
  return new Response(null, {
    status: 401,
    headers: {
      'WWW-Authenticate': wwwAuthenticate,
      'Cache-Control': 'no-store',
      Pragma: 'no-cache',
    },
  });
}
```

### Samples and the E2E wiring

`samples/hono-cloudflare` (every feature enabled) and `samples/express-flyio` (the Web-standard path with `--db sql`) are generated with `--enable dynamic-client-registration`.
Their hand-written `app.ts`, and the `apps/hono/src/settings.ts` and `apps/nextjs/src/settings.ts` the E2E suite runs against, read the inventory cap from the environment variable `OIDC_DCR_MAX_CLIENTS`.
The verifier functions are code, not environment, so the samples read none.

```typescript
// EXPERIMENTAL (RFC 7591): the E2E suite starts a second instance of this
// sample with a small inventory cap, so the 429 path can be exercised over
// real HTTP. With the var unset the generated default stays (cap 100). The
// verifier functions of the registration config (initial access token,
// software statement) are code, not environment: pass them here as
// verifyInitialAccessToken / verifySoftwareStatement when a deployment needs
// them; the generated code verifies neither on its own.
const dynamicClientRegistration = {
  ...(bindings.OIDC_DCR_MAX_CLIENTS
    ? { maxRegisteredClients: Number(bindings.OIDC_DCR_MAX_CLIENTS) }
    : {}),
};
```

`playwright.config.ts` starts a capped instance (3 registrations) beside the open-registration one, so the 429 path runs over real HTTP.
The initial access token and software statement paths are covered by the pipeline tests and the Route Handler tests of the apps, where a function can be passed.

```typescript
// EXPERIMENTAL (RFC 7591): the capped-registration OP instance. It caps
// the dynamic registrations at 3, so the 429 path of the
// dynamic-client-registration spec runs against real HTTP without filling
// the main instance. The cap is mirrored as a constant in
// specs/dynamic-client-registration.spec.ts. The verifier functions of the
// registration config are code, not environment, so the 401 and software
// statement paths are covered by the in-process tests of the apps.
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
          OIDC_DCR_MAX_CLIENTS: '3',
          // ...
        },
      },
    ]
  : []),
```

## The E2E spec, in full

```typescript
import { createHash, generateKeyPairSync, randomBytes } from 'node:crypto';
import { expect, test, type APIRequestContext, type Page } from '@playwright/test';

const host = process.env.E2E_HOST ?? '127.0.0.1';
const clientPort = Number(process.env.E2E_CLIENT_PORT ?? '3020');
const clientBaseURL =
  process.env.E2E_CLIENT_BASE_URL ?? `http://${host}:${clientPort}`;
// EXPERIMENTAL (RFC 7591): a second OP instance started by playwright.config.ts
// with a small inventory cap, so the 429 path can be exercised without filling
// the open registration the other tests rely on. The verifier functions of the
// registration config (initial access token, software statement) are code, not
// environment, so their paths are covered by the in-process tests of the apps.
const dcrOpPort = Number(process.env.E2E_DCR_OP_PORT ?? '3050');
const restrictedIssuer = process.env.E2E_DCR_ISSUER ?? `http://${host}:${dcrOpPort}`;
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
    // OIDC Dynamic Client Registration 1.0 §2 defaults the OP applied, returned
    // as registered metadata (§3.2).
    expect(registered.application_type).toBe('web');
    expect(registered.id_token_signed_response_alg).toBe('RS256');
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

  // OIDC Dynamic Client Registration 1.0 §2: the response types the OP
  // advertises are registrable, and the implicit grant pairs with them. The
  // loopback http redirect target of this suite is what a native client may
  // register (a web client using the implicit grant is held to https).
  test('should register an implicit client and return its ID Token in the fragment (OIDC Core 1.0 §3.2)', async ({
    page,
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const endpoint = await registrationEndpoint(request, issuer);
    test.skip(endpoint === undefined, SKIP_REASON);
    const metadata = await discoveryMetadata(request, issuer);
    test.skip(
      !(metadata.response_types_supported as string[] | undefined)?.includes('id_token token'),
      'This sample OP was generated without implicit-flow',
    );

    const registered = await registerClient(request, issuer, {
      redirect_uris: [registeredRedirectUri],
      application_type: 'native',
      token_endpoint_auth_method: 'none',
      grant_types: ['implicit'],
      response_types: ['token id_token'],
      client_name: 'E2E Implicit Client',
    });
    const clientId = requireString(registered.client_id, 'client_id');
    // The response type comes back normalized (OAuth 2.0 Multiple Response Type Encoding Practices §1.2).
    expect(registered.response_types).toEqual(['id_token token']);
    expect(registered.grant_types).toEqual(['implicit']);
    expect(registered.application_type).toBe('native');

    const { fragment, nonce } = await authorizeImplicitInBrowser(page, issuer, clientId);

    expect(fragment['token_type']).toBe('Bearer');
    const idToken = decodeJwtPayload(requireString(fragment['id_token'], 'id_token'));
    expect(idToken.aud).toBe(clientId);
    expect(idToken.nonce).toBe(nonce);
  });

  // OIDC Dynamic Client Registration 1.0 §2: application_type defaults to web,
  // and the OP MUST verify that every registered redirect_uri conforms to the
  // constraints of that type — for a web client using the implicit grant,
  // https only and never localhost — so the omitted type is checked too.
  test('should default application_type to web and hold an implicit client to https redirect_uris (OIDC Registration 1.0 §2)', async ({
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const endpoint = await registrationEndpoint(request, issuer);
    test.skip(endpoint === undefined, SKIP_REASON);
    const metadata = await discoveryMetadata(request, issuer);
    test.skip(
      !(metadata.response_types_supported as string[] | undefined)?.includes('id_token'),
      'This sample OP was generated without implicit-flow',
    );
    const implicitClient = {
      token_endpoint_auth_method: 'none',
      grant_types: ['implicit'],
      response_types: ['id_token'],
    };

    const refused = await request.post(`${issuer}/register`, {
      headers: { 'Content-Type': 'application/json' },
      data: { ...implicitClient, redirect_uris: [registeredRedirectUri] },
    });
    const registered = await registerClient(request, issuer, {
      ...implicitClient,
      redirect_uris: ['https://implicit-client.e2e.example.com/cb'],
    });

    expect(refused.status()).toBe(400);
    expect(await refused.json()).toEqual({
      error: 'invalid_client_metadata',
      error_description: 'a web client using the implicit grant must register https redirect_uris that do not use localhost',
    });
    expect(registered.application_type).toBe('web');
    expect(registered.redirect_uris).toEqual(['https://implicit-client.e2e.example.com/cb']);
  });

  // RFC 7591 §2: the scope metadata becomes the client's scope list, so a
  // request for any other scope is invalid_scope at /authorize.
  test('should register the scope and refuse an authorization request outside it with invalid_scope', async ({
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const endpoint = await registrationEndpoint(request, issuer);
    test.skip(endpoint === undefined, SKIP_REASON);

    const registered = await registerClient(request, issuer, {
      redirect_uris: [registeredRedirectUri],
      scope: 'openid profile openid',
    });
    expect(registered.scope).toBe('openid profile');
    const clientId = requireString(registered.client_id, 'client_id');

    const url = new URL('/authorize', issuer);
    url.searchParams.set('client_id', clientId);
    url.searchParams.set('redirect_uri', registeredRedirectUri);
    url.searchParams.set('response_type', 'code');
    url.searchParams.set('scope', 'openid email');
    url.searchParams.set('state', 'e2e-scope-state');
    url.searchParams.set('code_challenge', base64Url(createHash('sha256').update('e2e-verifier-e2e-verifier-e2e-verifier-e2e-verifier').digest()));
    url.searchParams.set('code_challenge_method', 'S256');
    const response = await request.get(url.toString(), { maxRedirects: 0 });

    expect(response.status()).toBe(302);
    const location = new URL(requireHeader(response.headers(), 'location'));
    expect(`${location.origin}${location.pathname}`).toBe(registeredRedirectUri);
    expect(location.searchParams.get('error')).toBe('invalid_scope');
    expect(location.searchParams.get('state')).toBe('e2e-scope-state');
  });

  // RFC 7591 §2 / OIDC Dynamic Client Registration 1.0 §2: the metadata the OP
  // keeps for display and policy comes back with the registration (§3.2.1).
  test('should register the informational metadata of RFC 7591 §2 and return it', async ({
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const endpoint = await registrationEndpoint(request, issuer);
    test.skip(endpoint === undefined, SKIP_REASON);

    const registered = await registerClient(request, issuer, {
      redirect_uris: [registeredRedirectUri],
      application_type: 'web',
      client_name: 'E2E Described Client',
      client_uri: 'https://app.example.com/',
      logo_uri: 'https://app.example.com/logo.png',
      tos_uri: 'https://app.example.com/tos',
      policy_uri: 'https://app.example.com/privacy',
      contacts: ['ops@example.com', 'dev@example.com'],
      software_id: '4NRB1-0XZABZI9E6-5SM3R',
      software_version: '2.0.1',
      default_max_age: 3600,
      id_token_signed_response_alg: 'RS256',
    });

    expect(registered).toMatchObject({
      application_type: 'web',
      client_name: 'E2E Described Client',
      client_uri: 'https://app.example.com/',
      logo_uri: 'https://app.example.com/logo.png',
      tos_uri: 'https://app.example.com/tos',
      policy_uri: 'https://app.example.com/privacy',
      contacts: ['ops@example.com', 'dev@example.com'],
      software_id: '4NRB1-0XZABZI9E6-5SM3R',
      software_version: '2.0.1',
      default_max_age: 3600,
      id_token_signed_response_alg: 'RS256',
    });
  });

  // RFC 7591 §2 jwks: the public keys register with the client; the OP fills
  // in the alg and use it will verify with.
  test('should register the public keys of jwks and return the normalized key set', async ({
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const endpoint = await registrationEndpoint(request, issuer);
    test.skip(endpoint === undefined, SKIP_REASON);
    const { publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
    const { n, e } = publicKey.export({ format: 'jwk' }) as { n: string; e: string };

    const registered = await registerClient(request, issuer, {
      redirect_uris: [registeredRedirectUri],
      jwks: { keys: [{ kty: 'RSA', kid: 'e2e-client-key', n, e }] },
    });

    expect(registered.jwks).toEqual({
      keys: [{ kty: 'RSA', kid: 'e2e-client-key', use: 'sig', alg: 'RS256', n, e }],
    });
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
    // §4.1.2.1), so no Location header carries a code anywhere. The Next.js OP
    // shows a browser its error page; asking for JSON gets the error itself.
    const url = new URL('/authorize', issuer);
    url.searchParams.set('client_id', 'dcr-0000000000000000000000');
    url.searchParams.set('redirect_uri', registeredRedirectUri);
    url.searchParams.set('response_type', 'code');
    url.searchParams.set('scope', 'openid');
    const response = await request.get(url.toString(), {
      maxRedirects: 0,
      headers: { Accept: 'application/json' },
    });
    expect(response.status()).toBe(400);
    expect(response.headers()['location']).toBe(undefined);
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

  // RFC 7591 §2.1: a registration whose grant_types and response_types do not
  // pair is refused instead of landing the client in an inconsistent state.
  test('should answer invalid_client_metadata for grant_types inconsistent with response_types (RFC 7591 §2.1)', async ({
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const endpoint = await registrationEndpoint(request, issuer);
    test.skip(endpoint === undefined, SKIP_REASON);

    const response = await request.post(`${issuer}/register`, {
      headers: { 'Content-Type': 'application/json' },
      data: { redirect_uris: [registeredRedirectUri], grant_types: ['refresh_token'] },
    });
    expect(response.status()).toBe(400);
    expect(await response.json()).toEqual({
      error: 'invalid_client_metadata',
      error_description:
        'grant_types and response_types must be consistent: code requires authorization_code, token and id_token require implicit',
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
        jwks_uri: 'https://app.example.com/jwks.json',
        sector_identifier_uri: 'https://app.example.com/redirect_uris.json',
        require_auth_time: true,
      },
    });
    expect(response.status()).toBe(201);
    const registered = await response.json() as Record<string, unknown>;
    expect(Object.hasOwn(registered, 'jwks_uri')).toBe(false);
    expect(Object.hasOwn(registered, 'sector_identifier_uri')).toBe(false);
    expect(Object.hasOwn(registered, 'require_auth_time')).toBe(false);
  });

  // RFC 7591 §3.1.1: a provider without a verifySoftwareStatement in its config
  // does not support software statements and ignores the member — the plain
  // values register, and nothing comes back as software_statement. Nothing in
  // the OP examines the statement, so any string is ignored the same way.
  test('should ignore a software_statement when the provider has no verifier for it (RFC 7591 §3.1.1)', async ({
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const endpoint = await registrationEndpoint(request, issuer);
    test.skip(endpoint === undefined, SKIP_REASON);

    const registered = await registerClient(request, issuer, {
      redirect_uris: [registeredRedirectUri],
      client_name: 'E2E Plain Name',
      software_statement: 'not-a-jws',
    });

    expect(registered.client_name).toBe('E2E Plain Name');
    expect(Object.hasOwn(registered, 'software_statement')).toBe(false);
  });

  // RFC 7591 §3.1.1 defines the member as a JWT string: another JSON type is a
  // malformed request, whether or not the provider supports statements.
  test('should answer invalid_software_statement for a software_statement that is not a string', async ({
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const endpoint = await registrationEndpoint(request, issuer);
    test.skip(endpoint === undefined, SKIP_REASON);

    const response = await request.post(`${issuer}/register`, {
      headers: { 'Content-Type': 'application/json' },
      data: { redirect_uris: [registeredRedirectUri], software_statement: { iss: 'https://publisher.example.com' } },
    });
    expect(response.status()).toBe(400);
    expect(await response.json()).toEqual({
      error: 'invalid_software_statement',
      error_description: 'software_statement must be a string',
    });
  });

  // --- The capped instance: the inventory cap ---

  test('should answer 429 once the inventory cap is reached', async ({
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
        headers: { 'Content-Type': 'application/json' },
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
  'The capped-registration OP instance is not running for this sample';

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
  page: Page,
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
  await loginAndApprove(page, issuer, clientId);

  await expect(page).toHaveURL(new RegExp(`^${escapeRegExp(registeredRedirectUri)}\\?`));
  const callbackUrl = new URL(page.url());
  expect(callbackUrl.searchParams.get('state')).toBe(requestState);
  expect(callbackUrl.searchParams.get('iss')).toBe(issuer);
  const code = callbackUrl.searchParams.get('code');
  expect(code).not.toBe(null);
  return { code: code as string, state: { codeVerifier } };
}

/**
 * Drive an Implicit Flow request (response_type=id_token token) in the real
 * browser with the issued client_id and return the fragment of the redirect
 * the browser landed on, with the nonce the request used.
 */
async function authorizeImplicitInBrowser(
  page: Page,
  issuer: string,
  clientId: string,
): Promise<{ fragment: Record<string, string>; nonce: string }> {
  const requestState = base64Url(randomBytes(16));
  const nonce = base64Url(randomBytes(16));

  const authorizeUrl = new URL('/authorize', issuer);
  authorizeUrl.searchParams.set('client_id', clientId);
  authorizeUrl.searchParams.set('redirect_uri', registeredRedirectUri);
  authorizeUrl.searchParams.set('response_type', 'id_token token');
  authorizeUrl.searchParams.set('scope', 'openid');
  authorizeUrl.searchParams.set('state', requestState);
  authorizeUrl.searchParams.set('nonce', nonce);

  await page.goto(authorizeUrl.toString());
  await loginAndApprove(page, issuer, clientId);

  // OIDC Core 1.0 §3.2.2.5: the tokens ride in the fragment, never in the query.
  await page.waitForURL((url) => url.href.startsWith(registeredRedirectUri));
  const callbackUrl = new URL(page.url());
  expect(callbackUrl.search).toBe('');
  const fragment = Object.fromEntries(new URLSearchParams(callbackUrl.hash.slice(1)));
  expect(fragment['state']).toBe(requestState);
  return { fragment, nonce };
}

/** Log in as testuser and approve the consent screen, which names the registered client. */
async function loginAndApprove(page: Page, issuer: string, clientId: string): Promise<void> {
  await expect(page).toHaveURL(new RegExp(`^${escapeRegExp(issuer)}/login$`));
  await page.getByLabel('Username:').fill('testuser');
  await page.getByLabel('Password:').fill('password');
  await page.getByRole('button', { name: 'Login' }).click();

  await expect(page).toHaveURL(new RegExp(`^${escapeRegExp(issuer)}/consent$`));
  // The consent screen names the dynamically registered client.
  await expect(page.locator('strong')).toHaveText(clientId);
  await page.getByRole('button', { name: 'Approve' }).click();
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
    const metadata = await discoveryMetadata(request, issuer);
    return metadata.registration_endpoint as string | undefined;
  } catch {
    return undefined;
  }
}

async function discoveryMetadata(request: APIRequestContext, issuer: string): Promise<Record<string, unknown>> {
  const response = await request.get(`${issuer}/.well-known/openid-configuration`);
  expect(response.status()).toBe(200);
  return await response.json() as Record<string, unknown>;
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

- Specification documents: `tasks/experimental/done/dynamic-client-registration/` (`specification.md`, `sources.md`, `understanding-guide.md`, `review-log.md`); the decisions this revision changed are summarized in the addendum of `specification.md`
- Study material: `study-material/ext-dynamic-client-registration.md`, `study-material/extension-dynamic-client-registration.md`, `study-material/done/dcr-scope-metadata-registration-and-least-privilege.md`
- User documentation: `docs/library-document/src/content/docs/experimental/dynamic-client-registration.md` (OSS repository)
- RFC 7591 / OpenID Connect Dynamic Client Registration 1.0 / OpenID Connect Discovery 1.0 §3 / RFC 6750 §3.1 / RFC 7515
