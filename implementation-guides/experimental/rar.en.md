# Rich Authorization Requests (RFC 9396) Implementation Guide

This document is the implementation guide for the `rar` feature (OAuth 2.0 Rich Authorization Requests, RFC 9396) of `@maronn-openid-connect/experimental`.
It explains what the feature does and which use cases it serves, embeds in full every file under `packages/experimental/src/rar/`, the code the CLI's `--enable rar` adds to the generated output, and the E2E spec, and walks through the design decisions.

The code was implemented in PR [maronnjapan/maronn-openid-connect#179](https://github.com/maronnjapan/maronn-openid-connect/pull/179).
The specification work and its three-day review live in this notes repository under `tasks/experimental/done/rar/`.

## What the feature does

`scope` is a set of space-separated strings, so its granularity stops at "the whole API" or "a kind of operation".
A request like "transfer exactly EUR 123.50 from account X, once" can only be expressed by inventing a private convention that packs structure into scope values, which never interoperates.

**Rich Authorization Requests (RAR)** standardizes that structure as the `authorization_details` parameter, a JSON array.
Each entry is an object that declares its meaning with a `type` field and may carry type-specific fields such as amounts, accounts and actions.

An OP generated with `--enable rar` does the following on the authorization code flow:

1. validates `authorization_details` on the authorization request (structural checks, plus the type-specific checks of the **type definitions** registered in the configuration)
2. lists the display rows of the requested details next to the scopes on the consent screen (RFC 9396 §3.1)
3. binds the approved details to the grant
4. returns `authorization_details` on the token response (refresh included, §7) and on introspection (§9.2)
5. advertises `authorization_details_types_supported` in discovery (§10)

A request without `authorization_details` is processed exactly as before, with or without the feature.

### Use cases

- financial PoCs that try account- and amount-specific authorization (a `payment_initiation` type, for instance)
- API providers who want to refine the coarse granularity of `scope` and validate their type-definition design (required fields, consent wording)
- combining the FAPI 2.0 recommended setup (PAR + RAR). The PAR parameter validation keeps unknown parameters, so `authorization_details` sent to `/par` is accepted as is

### Scope and non-goals

Out of RFC 9396, the following are not implemented:

- **re-specification on the token request (§6 narrowing)**: not accepted. The parameter is rejected explicitly with `invalid_authorization_details`, because ignoring it silently would let the client believe the details were narrowed
- **enriched authorization details (§7.1)**: the AS returns the approved content as is
- **the JWT access token claim (§9.1, RECOMMENDED)**: resource servers learn the details through introspection only; the access-token issuing steps belong to the base, and touching them is left to a future promotion into core
- **other flows**: the device authorization grant and CIBA endpoints keep ignoring the parameter
- **partial consent (the MAY of the §3 Note)**: consent is approve-or-deny for the requested details as a whole
- **the `authorization_details_types` client metadata (§10)**: no per-client type restriction

## Design decisions

RFC 9396 delegates the semantics of each type to per-API profiles, so no OP alone can implement them "correctly".
This feature therefore delegates type interpretation to operator-injected **type definitions** (a validator and a consent-line builder per type), and the experimental package holds only the structural validation and the plumbing.
With no type definitions registered (the default), every request that carries `authorization_details` is rejected with `invalid_authorization_details` — fail-closed, applying §5's "MUST refuse types it does not understand" to the empty set as well.

The details are kept in **side stores keyed by transactionId / grantId**, without widening the core types.
The core builders for transactions, authorization codes and token info copy fixed fields only, so the details cannot ride along from the request to the token response.
Adding an `authorizationDetails` field to core would be the proper path, but that is a promotion-time change; at the experimental stage this feature takes the same in-memory trade-off as PAR and CIBA.
There are two store instances — before approval (transactionId key, same lifetime as the authorization transaction) and after approval (grantId key, the refresh-token absolute lifetime) — and the entry moves between them at the moment consent is confirmed.
The grantId spans both the authorization_code and the refresh_token grant, so a refresh finds the same details.

Consent bypasses are closed with **prompt control**.
The stored consent record (`consentResolver.hasConsent`) only knows subject / client / scope and nothing about details, so riding the SSO consent skip would bind amounts and accounts the end user never saw.
A request with details therefore answers `consent_required` when `prompt=none` stands alone, and otherwise gets `consent` added to its `prompt`, which stops both the silent path and the SSO session-reuse path in front of the consent screen.
The meaning of `prompt=consent` is exactly OIDC Core 1.0 §3.1.2.1's "re-display consent".
An invalid combination of `none` with other values is left alone; the base check keeps rejecting it with `invalid_request` as before.

The token-endpoint rejection of `authorization_details` runs in a step **ahead of every side effect**.
The token pipeline proceeds dispatches → grant validation → token issuance and persistence → rotation revocation of the presented refresh token → response building; rejecting at response-building time would leave the side effects of a rejected request behind (stored tokens, a revoked refresh token).
The reject step sits right after the feature-grant dispatches and before grant_type validation, so the existing rejections of grants other features answer (id-jag, token-exchange) keep firing first.

Errors ride the existing carriers: `AuthorizationError` on the authorization endpoint, `TokenEndpointError` on the token endpoint.
`invalid_authorization_details` is not in core's error-code enums, but the enums are string-valued and PAR already throws an out-of-enum code with a cast, so core stays untouched.
`error_description` is a fixed ASCII sentence that never reflects detail values (amounts, accounts, type names; §13): the client can reproduce which entry failed from what it sent, and keeping values out removes a leak surface through logs and referrers.

## The implementation, in full

`packages/experimental/src/rar/` holds five files; the public API is imported from the subpath `@maronn-openid-connect/experimental/rar`.
Everything is pure functions plus a plain in-memory store, using only web-standard APIs (TextEncoder, JSON).

### authorization-details.ts (structural validation and type-definition matching)

The entry point `parseAuthorizationDetailsInput()` takes `unknown` because the shape depends on the route: query and PAR deliver a URL-encoded string, while a Request Object delivers an already-parsed array (the JWT payload is JSON-decoded by core).
A string has its raw UTF-8 byte length checked before parsing; a parsed value is measured through `JSON.stringify`, so the same cap applies on both routes.
Checking bytes before parsing stops the parse of a huge JSON document at the door (the DoS guard; §11.4 points large requests to PAR).

Detail objects are treated as opaque JSON values — kept and copied, never deep-merged or written through dynamic keys.
An input with a `__proto__` key travels as the own property `JSON.parse` creates and never reaches a prototype (the answer to §12's sanitize requirement, pinned by a unit test).

The full file is embedded in the Japanese guide ([rar.ja.md](./rar.ja.md#authorization-detailsts構造検証と型定義の突き合わせ)) and reproduced here:

```typescript
/**
 * Rich Authorization Requests (RAR) — RFC 9396
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * `authorization_details` パラメータの構造検証と、OP 運用者が注入する型定義
 * （type ごとの validator と同意表示文の生成関数）との突き合わせ。
 * ここにあるのは純関数だけで、HTTP やストアには触れない。
 */

/** RFC 9396 §3: 認可リクエストのパラメータ名。 */
export const AUTHORIZATION_DETAILS_PARAM = 'authorization_details';

/**
 * RFC 9396 §2 の authorization details オブジェクト。
 *
 * `type` だけが必須で（§2）、共通フィールド（§2.2）はすべて任意である。
 * 型固有フィールドはインデックスシグネチャで不透明に保持し、解釈は型定義へ委ねる。
 */
export interface AuthorizationDetail {
  readonly type: string;
  readonly locations?: readonly string[];
  readonly actions?: readonly string[];
  readonly datatypes?: readonly string[];
  readonly identifier?: string;
  readonly privileges?: readonly string[];
  readonly [key: string]: unknown;
}

/**
 * OP 運用者が type ごとに注入する定義。
 *
 * RFC 9396 §5 は「理解しない type を含むリクエストを拒否しなければならない」とし、
 * 「理解する」の中身を OP に委ねている。この定義を登録した type だけが受理される。
 */
export interface AuthorizationDetailTypeDefinition {
  /** この定義が受け持つ `type` の値。 */
  readonly type: string;
  /**
   * 型固有の検証。違反したら `RarError('invalid_authorization_details')` を投げる。
   * message は固定の ASCII 文言とし、入力値を含めないこと（RFC 9396 §13）。
   */
  validate(detail: AuthorizationDetail): void;
  /**
   * 同意画面に出す表示行。プレーン文字列だけを返し、HTML を組み立てない
   * （エスケープは view 層に委ねる）。金額や宛先など安全上重要なフィールドは
   * すべて文言に含める責任を持つ（RFC 9396 §3.1 / §13）。
   */
  describe(detail: AuthorizationDetail): readonly string[];
}

/** RFC 9396 §5 / §14.6 のエラーコード。authorization / token 両エンドポイントで使う。 */
export type RarErrorCode = 'invalid_authorization_details';

/**
 * `authorization_details` の検証失敗。
 *
 * message は呼び出し側が固定 ASCII 文言で渡す契約で、details の内容
 * （type 名を含む）を反映してはならない（RFC 9396 §13 の機微データ考慮）。
 */
export class RarError extends Error {
  readonly code: RarErrorCode = 'invalid_authorization_details';

  constructor(message: string) {
    super(message);
    this.name = 'RarError';
  }
}

/** `parseAuthorizationDetailsInput` の上限値。DoS 対策（RFC 9396 §11.4 参照）。 */
export interface AuthorizationDetailsLimits {
  /** パラメータの UTF-8 バイト長の上限（TextEncoder 基準）。 */
  readonly maxBytes: number;
  /** 配列の要素数の上限。 */
  readonly maxEntries: number;
}

/** 共通フィールド（RFC 9396 §2.2）のうち、文字列配列でなければならないもの。 */
const STRING_ARRAY_COMMON_FIELDS = ['locations', 'actions', 'datatypes', 'privileges'] as const;

/**
 * `authorization_details` の入力を検証して、パース済みの配列を返す。失敗は `RarError` で投げる。
 *
 * クエリ / PAR 経由の文字列と、Request Object 経由のパース済み JSON 値の両方を受ける。
 * - 文字列: 生文字列の UTF-8 バイト長を検査してから `JSON.parse` する。
 * - それ以外: `JSON.stringify` した文字列でバイト長を測り、配列であることを検査する
 *   （stringify できない値、文字列でも配列でもない値は拒否する）。
 *
 * 検査は、バイト長 → 配列であること → 空でなく要素数が上限以下 → 各要素が
 * プレーンなオブジェクト → `type` が非空文字列（§2 REQUIRED）→ 共通フィールドの型
 * （§2.2）の順に行う。型定義との突き合わせ（§5）は `validateAuthorizationDetails()` が行う。
 *
 * @spec RFC 9396 §2
 * @spec RFC 9396 §2.2
 * @spec RFC 9396 §3
 * @throws {RarError} 入力がどれかの検査に違反したとき。message は固定 ASCII 文言で、入力値を含まない。
 */
export function parseAuthorizationDetailsInput(
  input: unknown,
  limits: AuthorizationDetailsLimits,
): AuthorizationDetail[] {
  const parsed = typeof input === 'string'
    ? parseFromString(input, limits)
    : measureParsedInput(input, limits);
  if (!Array.isArray(parsed)) {
    throw new RarError('authorization_details must be a JSON array');
  }
  if (parsed.length === 0) {
    throw new RarError('authorization_details must not be empty');
  }
  if (parsed.length > limits.maxEntries) {
    throw new RarError('authorization_details has too many entries');
  }
  for (const entry of parsed) {
    assertAuthorizationDetailShape(entry);
  }
  return parsed as AuthorizationDetail[];
}

/**
 * 文字列の入力をバイト長検査のうえ JSON としてパースして返す。失敗は `RarError` で投げる。
 *
 * バイト長は生文字列の UTF-8 表現（TextEncoder 基準）で測る。
 *
 * @spec RFC 9396 §3
 * @throws {RarError} バイト長が上限を超えるか、JSON としてパースできないとき。
 */
function parseFromString(input: string, limits: AuthorizationDetailsLimits): unknown {
  if (new TextEncoder().encode(input).length > limits.maxBytes) {
    throw new RarError('authorization_details is too large');
  }
  try {
    return JSON.parse(input);
  } catch {
    throw new RarError('authorization_details must be valid JSON');
  }
}

/**
 * パース済みの入力（Request Object 経由）のバイト長を JSON 表現で測り、そのまま返す。失敗は `RarError` で投げる。
 *
 * `JSON.stringify` できない値（undefined、関数、循環参照を含む値）は拒否する。
 *
 * @spec RFC 9396 §3
 * @throws {RarError} JSON にできない値か、バイト長が上限を超えるとき。
 */
function measureParsedInput(input: unknown, limits: AuthorizationDetailsLimits): unknown {
  let serialized: string | undefined;
  try {
    serialized = JSON.stringify(input);
  } catch {
    throw new RarError('authorization_details must be a JSON value');
  }
  if (typeof serialized !== 'string') {
    throw new RarError('authorization_details must be a JSON value');
  }
  if (new TextEncoder().encode(serialized).length > limits.maxBytes) {
    throw new RarError('authorization_details is too large');
  }
  return input;
}

/**
 * 配列の 1 要素が authorization details オブジェクトの形であることを確かめる。違反は `RarError` で投げる。
 *
 * プレーンなオブジェクトであること、`type` が非空文字列であること（§2 REQUIRED）、
 * 共通フィールドが存在するなら §2.2 の型（`locations` / `actions` / `datatypes` /
 * `privileges` は文字列配列、`identifier` は文字列）であることを検査する。
 * 同じ `type` の要素が複数あってもよい（§2 MAY）。
 *
 * @spec RFC 9396 §2
 * @spec RFC 9396 §2.2
 * @throws {RarError} 要素がオブジェクトでない、`type` が欠落・空・非文字列、共通フィールドの型が違うとき。
 */
function assertAuthorizationDetailShape(entry: unknown): asserts entry is AuthorizationDetail {
  if (typeof entry !== 'object' || entry === null || Array.isArray(entry)) {
    throw new RarError('authorization_details entries must be JSON objects');
  }
  const detail = entry as Record<string, unknown>;
  if (typeof detail['type'] !== 'string' || detail['type'].length === 0) {
    throw new RarError('authorization_details entries must have a non-empty type');
  }
  for (const field of STRING_ARRAY_COMMON_FIELDS) {
    const value = detail[field];
    if (value === undefined) continue;
    if (!Array.isArray(value) || value.some((item) => typeof item !== 'string')) {
      throw new RarError('authorization_details common fields must have the RFC 9396 types');
    }
  }
  if (detail['identifier'] !== undefined && typeof detail['identifier'] !== 'string') {
    throw new RarError('authorization_details common fields must have the RFC 9396 types');
  }
}

/**
 * すべての要素を登録済みの型定義と突き合わせ、未知の type と型固有の違反を `RarError` で拒否する。
 *
 * 型定義が一つも無ければ、どの要素も未知 type として拒否される（fail-closed。§5 の
 * MUST refuse）。型定義の `validate` が投げた `RarError` はそのまま伝え、それ以外の
 * 例外は握りつぶさずそのまま伝える（呼び出し側が `server_error` として扱う）。
 *
 * @spec RFC 9396 §5
 * @throws {RarError} 要素の `type` に対応する型定義が無いか、型定義の `validate` が違反を見つけたとき。
 */
export function validateAuthorizationDetails(
  details: readonly AuthorizationDetail[],
  types: readonly AuthorizationDetailTypeDefinition[],
): void {
  for (const detail of details) {
    const definition = types.find((candidate) => candidate.type === detail.type);
    if (definition === undefined) {
      throw new RarError('authorization_details contains an unsupported type');
    }
    definition.validate(detail);
  }
}

/**
 * 同意画面向けの表示行を、要素の順に型定義の `describe` で組み立てて返す。
 *
 * 対応する型定義が無い要素があれば `RarError` を投げる（表示できない要素を黙って
 * 落とすと、エンドユーザーが見ていない権限が承認されてしまうため）。
 * 返す値はプレーン文字列の配列で、エスケープは呼び出し側の view 層に委ねる。
 *
 * @spec RFC 9396 §3.1
 * @throws {RarError} 要素の `type` に対応する型定義が無いとき。
 */
export function describeAuthorizationDetails(
  details: readonly AuthorizationDetail[],
  types: readonly AuthorizationDetailTypeDefinition[],
): readonly string[] {
  const lines: string[] = [];
  for (const detail of details) {
    const definition = types.find((candidate) => candidate.type === detail.type);
    if (definition === undefined) {
      throw new RarError('authorization_details contains an unsupported type');
    }
    lines.push(...definition.describe(detail));
  }
  return lines;
}
```

The exception thrown by `describeAuthorizationDetails()` for an unknown type is the approval-stage fail-closed: if the operator removed a type definition after validation, the display line for that entry cannot be built, and silently dropping it would mean the end user "approved" rights they never saw.
Failing the page render is the safer outcome.

### store.ts (keeping the details)

The store contract is just `set` / `get` / `delete`, with the requirement that an entry past its `expiresAt` (epoch milliseconds) is never returned.
The in-memory implementation evicts expired entries on every `set` (lazy eviction on writes, the same approach as the CIBA store) so an idle store cannot grow without bound, without a resident timer.

```typescript
/**
 * Rich Authorization Requests (RAR) — RFC 9396
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * 承認前（transactionId キー）と承認後（grantId キー）の authorization details を
 * 保持するストア契約と、動作確認用の in-memory 実装。
 */

import type { AuthorizationDetail } from './authorization-details.js';

/**
 * 利用者が実装するストア契約。
 *
 * キーは transactionId か grantId で、どちらも外部へ出ない不透明な識別子である。
 * 永続ストア実装では、キーをクエリ文字列へ埋め込まず、必ずパラメータ化した
 * 問い合わせを使うこと。`expiresAt`（UNIX エポックミリ秒）を渡されたら、その時刻を
 * 過ぎたエントリを返してはならない。
 */
export interface RarDetailsStore {
  /** details をキーに紐付けて保存する。`expiresAt` はエポックミリ秒の失効時刻。 */
  set(key: string, details: readonly AuthorizationDetail[], expiresAt?: number): Promise<void>;
  /** キーに紐づく details を返す。無いか失効していれば `undefined` を返す。 */
  get(key: string): Promise<readonly AuthorizationDetail[] | undefined>;
  /** キーに紐づく details を削除する。 */
  delete(key: string): Promise<void>;
}

/**
 * details をメモリに置くストアを作って返す。
 *
 * 動作確認のためのもので、本番では永続的なストア（Redis、KV、データベースなど）に
 * 置き換える。`set` を呼ぶたびに失効したエントリを削除する（書き込み時の lazy
 * eviction）ので、放置されたストアが際限なく大きくならない。`get` は失効した
 * エントリを削除してから `undefined` を返す。
 */
export function createInMemoryRarDetailsStore(): RarDetailsStore {
  const records = new Map<string, { details: readonly AuthorizationDetail[]; expiresAt?: number }>();
  const evictExpired = (): void => {
    const now = Date.now();
    for (const [key, record] of records) {
      if (record.expiresAt !== undefined && record.expiresAt <= now) {
        records.delete(key);
      }
    }
  };
  return {
    async set(key, details, expiresAt): Promise<void> {
      evictExpired();
      records.set(key, { details, expiresAt });
    },
    async get(key): Promise<readonly AuthorizationDetail[] | undefined> {
      const record = records.get(key);
      if (record === undefined) return undefined;
      if (record.expiresAt !== undefined && record.expiresAt <= Date.now()) {
        records.delete(key);
        return undefined;
      }
      return record.details;
    },
    async delete(key): Promise<void> {
      records.delete(key);
    },
  };
}
```

### index.ts (the public API)

```typescript
/**
 * Rich Authorization Requests (RAR) — RFC 9396
 *
 * **Experimental**: この機能の API は安定していない。マイナーリリースでも
 * 破壊的に変更されることがある。本番運用の前に
 * `docs/library-document` の Experimental セクションを確認すること。
 *
 * `@maronn-openid-connect/core` とは別 package であり、CLI で `--enable rar` を明示した
 * ときのみ生成コードから利用される。
 */
export {
  AUTHORIZATION_DETAILS_PARAM,
  RarError,
  describeAuthorizationDetails,
  parseAuthorizationDetailsInput,
  validateAuthorizationDetails,
  type AuthorizationDetail,
  type AuthorizationDetailTypeDefinition,
  type AuthorizationDetailsLimits,
  type RarErrorCode,
} from './authorization-details.js';

export { createInMemoryRarDetailsStore, type RarDetailsStore } from './store.js';
```

The `package.json` exports gained the `"./rar"` subpath; as for every feature of this package, nothing is re-exported from the root.

```json
"./rar": {
  "types": "./dist/rar/index.d.ts",
  "import": "./dist/rar/index.js"
},
```

## The unit tests, in full

The test inputs reuse the `payment_initiation` example of RFC 9396 §2.1 Figure 1 (EUR 123.50) verbatim.
The suite pins the byte-length boundary in UTF-8 (on / over, with multi-byte characters), the entry-count boundary, that `__proto__` / `constructor` keys stay own properties without polluting prototypes, and that error messages never contain input values (probed with an IBAN-like string).
Both test files are embedded in full in the Japanese guide ([rar.ja.md](./rar.ja.md#単体テストの全文)); the code is identical, so this guide does not repeat the two test files.

## CLI integration and the generated-code contribution

`packages/cli/src/registry.ts` gained the `rar` entry in `FEATURE_REGISTRY` and `EXPERIMENTAL_FEATURES`.
The feature is disabled by default (`DEFAULT_FEATURES`), requires no other feature, and the introspection block lives inside the introspection pipeline, so it disappears together with that feature when introspection is disabled.

```typescript
{ id: 'rar', tier: 'experimental', requires: [], packages: EXPERIMENTAL, frameworks: ALL_FRAMEWORKS, runtimes: ALL_RUNTIMES, summary: 'OAuth 2.0 Rich Authorization Requests (RFC 9396)' },
```

The hono output receives the feature directory `features/rar/` (config.ts, store.ts, feature.ts and seven step files) plus owner blocks on four pipelines and small base changes that leave the disabled output behaviorally unchanged.
All of these files and blocks are embedded in full, with the surrounding prose stating where each block lands, in the Japanese guide ([rar.ja.md](./rar.ja.md#cli-統合と生成コードへの寄与)); the code is byte-identical between the two guides' subject, so this guide summarizes where each piece goes and embeds the blocks that carry a design decision.

- `features/rar/config.ts`: the byte / entry caps with fail-fast range checks, and the `declare module` extension that puts `rarTypes` on `ProviderConfig`
- `features/rar/store.ts`: the two store instances (`rarTransactionStore`, `rarGrantStore`) shared through a `globalThis` registry
- `features/rar/feature.ts`: the discovery hook (advertises only while types are registered) and the context hook that hands both stores to the steps
- `steps/validate-authorization-details.ts`: reads the value (Request Object claim first, per OIDC Core 1.0 §6.1 supersede, since core's Request Object merge copies fixed keys only), validates, and applies the prompt control
- `steps/record-authorization-details.ts`: persists the validated details under the transactionId with the transaction TTL
- `steps/describe-authorization-details.ts`: builds the consent display rows from the stored details
- `steps/record-granted-details.ts`: at the consent confirmation point, moves the details from the transactionId key to the grantId key with the refresh-token absolute lifetime
- `steps/reject-token-request-details.ts`: rejects `authorization_details` on the token request with 400 `invalid_authorization_details`, ahead of every side effect
- `steps/append-token-response-details.ts`: appends the approved details to the token response body (§7 MUST, no enrichment)
- `steps/append-introspection-details.ts`: appends them as a top-level member of an `active: true` introspection answer (§9.2), before the optional RFC 9701 signing

The pipeline blocks land as follows.
On `endpoints/authorize/pipeline.ts`, validation sits between `[validate-hybrid-request]` and `[create-transaction]` — before the transaction is created, so the `consent` added to `validatedRequest.prompt` is what gets stored — and recording sits right after `[create-transaction]`.
On `endpoints/token/pipeline.ts`, the reject block follows `[dispatch-ciba]` and precedes `[validate-grant-type]`, and the append block follows `[build-token-response]`, whose `const tokenResponse` became `let` (the same pattern as PAR's reassigned `let params`).
On the introspection pipeline, the append block sits between `[build-response]` (now `let introspection`) and `[sign-response]`, so a signed introspection JWT covers the member.

One hono-specific wrinkle shaped the consent GET path.
A feature-owned block in a hono pipeline extends from its marker to the next marker or the end of the handler; a rar block placed last in `prepareConsent()` would swallow the `return` statement when the feature is removed.
The rar block therefore sits **before** `[describe-consent-screen]`, producing `authorizationDetails`, and the base `return { ...screen, authorizationDetails }` reads it; with rar disabled the generator replaces the binding with `const authorizationDetails = undefined;`, and the screen renders exactly as before:

```typescript
  // [describe-authorization-details] (feature: rar) 同意画面に出す authorization details の表示行を作る — RFC 9396 §3.1
  const authorizationDetails = await describeTransactionAuthorizationDetails(c, transactionId);

  // [describe-consent-screen] 同意画面の表示内容を組み立てる
  const screen = await describeConsentScreen(c, transactionId, transaction);
  return { ...screen, authorizationDetails };
```

The consent screen types (`ConsentScreen`, `ConsentPageParams`) gained an optional `authorizationDetails?: readonly string[]`, and the default view lists it only when present, so the disabled output renders the same markup as before.

### The Next.js output

Next.js implements the same flow with `_oidc-provider/features/rar/` (config / store / feature / authorize / consent / token / introspect) and same-named owner blocks on the authorize, consent-decision, token and introspect Route Handlers; the code is equivalent to hono and linked rather than embedded ([apps/nextjs/src/app/_oidc-provider/features/rar/](https://github.com/maronnjapan/maronn-openid-connect/tree/main/apps/nextjs/src/app/_oidc-provider/features/rar)).
Two structural differences are worth explaining.

First, the consent screen is a React Server Component page, not a Route Handler, so it cannot carry owner blocks.
The Next.js `Feature` interface gained a consent hook, and the page simply lists the rows of the enabled features — the same mechanism the login page uses for the `loginMethods` hook.
With rar disabled the features list has no rar and the rows are empty.

```typescript
  readonly consent?: {
    /**
     * Extra display rows the consent page lists next to the scopes of a
     * transaction (plain strings; the page escapes them as JSX). A feature
     * returns [] for a transaction it has nothing to show for.
     */
    readonly describeTransaction?: (
      transactionId: string,
      config: ProviderConfig,
    ) => Promise<readonly string[]>;
  };
```

Second, the type-definition injection has two doors.
Next.js loads modules once per layer (Route Handlers; pages and Server Actions; `instrumentation.ts`), so assigning `config.rarTypes` from a startup hook would never reach the Route Handler layer.
`resolveRarTypes()` therefore prefers `config.rarTypes` (set in `provider.ts`, which is code and thus identical in every layer) and falls back to `rarConfig.types`, a `shared()` object a startup hook can assign; the repository's own dev app assigns the demo type there from `dev-data.ts`.

```typescript
/**
 * この OP が受理する authorization details の型定義を返す。
 *
 * `config.rarTypes`（provider.ts の設定）があればそれを、無ければ
 * `rarConfig.types`（起動フックからの注入）を返す。どちらも無ければ
 * `undefined` で、`authorization_details` 付きのリクエストはすべて拒否される
 * （fail-closed）。
 *
 * @spec RFC 9396 §5
 */
export function resolveRarTypes(
  config: ProviderConfig,
): readonly AuthorizationDetailTypeDefinition[] | undefined {
  return config.rarTypes ?? rarConfig.types;
}
```

The authorize Route Handler also turned `const prompt` into `let prompt`: the validation block runs before `validatedRequest` exists there, so the updated prompt comes back as a return value and is reassigned.

### The demo type (outside the generated code)

So the E2E suite can exercise the feature over the protocol, the repository's development apps (apps/hono through `app.ts`, apps/nextjs through `dev-data.ts`) register a demo `payment_initiation` type shaped after RFC 9396 §2.1 Figure 1 — `actions` restricted to `initiate` / `status` / `cancel`, `instructedAmount` checked as `{ currency: three uppercase letters, amount: a two-decimal string }`, and one fixed-format display line per action (`Initiate a payment of EUR 123.50`).
Both files sit outside the CLI extraction roots, so a generated provider starts with zero types.
The full demo file is embedded in the Japanese guide ([rar.ja.md](./rar.ja.md#デモ型定義生成コードの外)).

## The E2E spec

The E2E client gained a `/start-rar` route that runs the ordinary code flow with the demo `authorization_details` attached, then observes the details on all three channels (token response, refresh, introspection) and prints them as JSON, plus the rotated refresh token.
The spec skips itself through discovery's `authorization_details_types_supported`, so sample OPs generated without `--enable rar` only run the one test that shows the parameter is still ignored as before.

The token-endpoint rejection test verifies the before-side-effects property over the protocol: after a refresh request carrying `authorization_details` is rejected with 400, a retry with the **same refresh token** succeeds — which is only possible if the rejection happened before the rotation revoked the presented token.

The spec file `tests/e2e/specs/rar.spec.ts` and the client additions are embedded in full in the Japanese guide ([rar.ja.md](./rar.ja.md#e2e-テストの全文)); the code is identical in both repositories' views, so this guide links instead of repeating the roughly 250 lines.

## References

- [RFC 9396: OAuth 2.0 Rich Authorization Requests](https://datatracker.ietf.org/doc/html/rfc9396)
- the specification task set (specification / understanding-guide / sources / review-log): `tasks/experimental/done/rar/`
- the user-facing documentation in the OSS repository: `docs/library-document/src/content/docs/experimental/rar.md`
- the change memo in the OSS repository: `apps/map/changes/rar.md`
- Japanese version: [rar.ja.md](./rar.ja.md)
