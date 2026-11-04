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

The entry point `parseAuthorizationDetailsInput()` takes `unknown` because the shape depends on the route: query and PAR deliver a URL-encoded string, while a Request Object delivers an already-parsed array (core JSON-decodes the JWT payload).
A string has its raw UTF-8 byte length checked before parsing; a parsed value is measured through `JSON.stringify`, so the same cap applies on both routes.
Checking bytes before parsing stops the parse of a huge JSON document at the door (the DoS guard; §11.4 points large requests to PAR).
Detail objects are treated as opaque JSON values — kept and copied, never deep-merged or written through dynamic keys — so a `__proto__` key travels as an own property and never reaches a prototype (§12's sanitize requirement, pinned by a unit test).

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

The exception `describeAuthorizationDetails()` throws for an unknown type is the approval-stage fail-closed: if the operator removed a type definition after validation, the display line for that entry cannot be built, and dropping it silently would mean the end user "approved" rights they never saw.
Failing the page render is the safer outcome.

### store.ts (keeping the details)

The store contract is just `set` / `get` / `delete`, with the requirement that an entry past its `expiresAt` (epoch milliseconds) is never returned.
The in-memory implementation evicts expired entries on every `set` (lazy eviction on writes, the same approach as the CIBA store), so an idle store cannot grow without bound and no resident timer is needed.

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
The suite pins the UTF-8 byte-length boundary (on / over, with multi-byte characters), the entry-count boundary, that `__proto__` / `constructor` keys stay own properties without polluting prototypes, and that error messages never contain input values (probed with an IBAN-like string).

The two test files are identical to the ones embedded in the Japanese guide, section [単体テストの全文 in rar.ja.md](./rar.ja.md#単体テストの全文); both are reproduced below.

### authorization-details.test.ts

```typescript
import { describe, expect, it } from 'vitest';
import {
  AUTHORIZATION_DETAILS_PARAM,
  RarError,
  describeAuthorizationDetails,
  parseAuthorizationDetailsInput,
  validateAuthorizationDetails,
  type AuthorizationDetail,
  type AuthorizationDetailTypeDefinition,
} from './authorization-details.js';

const LIMITS = { maxBytes: 16384, maxEntries: 16 };

// RFC 9396 §2.1 Figure 1 の payment_initiation の例をテスト入力に使う。
const PAYMENT_DETAIL = {
  type: 'payment_initiation',
  actions: ['initiate'],
  locations: ['https://example.com/payments'],
  instructedAmount: { currency: 'EUR', amount: '123.50' },
};

// 型固有検証と表示のデモ型定義（RFC 9396 §2.1 の例の形）。
const PAYMENT_TYPE: AuthorizationDetailTypeDefinition = {
  type: 'payment_initiation',
  validate(detail: AuthorizationDetail): void {
    if (!Array.isArray(detail.actions) || detail.actions.length === 0) {
      throw new RarError('payment_initiation requires actions');
    }
  },
  describe(detail: AuthorizationDetail): readonly string[] {
    const amount = detail['instructedAmount'] as { currency: string; amount: string };
    return [`Initiate a payment of ${amount.currency} ${amount.amount}`];
  },
};

describe('AUTHORIZATION_DETAILS_PARAM', () => {
  it('should name the RFC 9396 request parameter', () => {
    expect(AUTHORIZATION_DETAILS_PARAM).toBe('authorization_details');
  });
});

describe('parseAuthorizationDetailsInput', () => {
  describe('string input (query / PAR)', () => {
    it('should parse a single-entry JSON array string', () => {
      const details = parseAuthorizationDetailsInput(JSON.stringify([PAYMENT_DETAIL]), LIMITS);
      expect(details).toEqual([PAYMENT_DETAIL]);
    });

    it('should parse multiple entries and keep duplicated types', () => {
      // RFC 9396 §2: 同じ type の要素が複数あってよい（MAY）。
      const details = parseAuthorizationDetailsInput(
        JSON.stringify([PAYMENT_DETAIL, PAYMENT_DETAIL]),
        LIMITS,
      );
      expect(details).toEqual([PAYMENT_DETAIL, PAYMENT_DETAIL]);
    });

    it('should reject a string that is not valid JSON', () => {
      expect(() => parseAuthorizationDetailsInput('{not json', LIMITS)).toThrow(RarError);
    });

    it('should reject JSON that is not an array', () => {
      expect(() => parseAuthorizationDetailsInput(JSON.stringify(PAYMENT_DETAIL), LIMITS)).toThrow(
        'authorization_details must be a JSON array',
      );
    });

    it('should reject a raw string over maxBytes measured as UTF-8', () => {
      // 多バイト文字（3 バイトの「あ」）で、文字数でなくバイト数が検査されることを確かめる。
      const padding = 'あ'.repeat(40);
      const raw = JSON.stringify([{ ...PAYMENT_DETAIL, note: padding }]);
      const onLimit = new TextEncoder().encode(raw).length;
      expect(() => parseAuthorizationDetailsInput(raw, { maxBytes: onLimit, maxEntries: 16 })).not.toThrow();
      expect(() => parseAuthorizationDetailsInput(raw, { maxBytes: onLimit - 1, maxEntries: 16 })).toThrow(
        'authorization_details is too large',
      );
    });
  });

  describe('parsed JSON input (Request Object)', () => {
    it('should accept an already-parsed array', () => {
      const details = parseAuthorizationDetailsInput([PAYMENT_DETAIL], LIMITS);
      expect(details).toEqual([PAYMENT_DETAIL]);
    });

    it('should reject a parsed value that is neither string nor array', () => {
      expect(() => parseAuthorizationDetailsInput(PAYMENT_DETAIL, LIMITS)).toThrow(
        'authorization_details must be a JSON array',
      );
      expect(() => parseAuthorizationDetailsInput(42, LIMITS)).toThrow(
        'authorization_details must be a JSON array',
      );
    });

    it('should reject undefined input', () => {
      expect(() => parseAuthorizationDetailsInput(undefined, LIMITS)).toThrow(
        'authorization_details must be a JSON value',
      );
    });

    it('should reject a parsed array whose JSON serialization is over maxBytes', () => {
      const value = [{ ...PAYMENT_DETAIL, note: 'x'.repeat(50) }];
      const onLimit = new TextEncoder().encode(JSON.stringify(value)).length;
      expect(() => parseAuthorizationDetailsInput(value, { maxBytes: onLimit, maxEntries: 16 })).not.toThrow();
      expect(() => parseAuthorizationDetailsInput(value, { maxBytes: onLimit - 1, maxEntries: 16 })).toThrow(
        'authorization_details is too large',
      );
    });
  });

  describe('array shape', () => {
    it('should reject an empty array', () => {
      expect(() => parseAuthorizationDetailsInput('[]', LIMITS)).toThrow(
        'authorization_details must not be empty',
      );
    });

    it('should reject more entries than maxEntries', () => {
      const entries = Array.from({ length: 3 }, () => PAYMENT_DETAIL);
      expect(() =>
        parseAuthorizationDetailsInput(JSON.stringify(entries), { maxBytes: 16384, maxEntries: 2 }),
      ).toThrow('authorization_details has too many entries');
    });

    it('should accept exactly maxEntries entries', () => {
      const entries = Array.from({ length: 2 }, () => PAYMENT_DETAIL);
      expect(
        parseAuthorizationDetailsInput(JSON.stringify(entries), { maxBytes: 16384, maxEntries: 2 }),
      ).toEqual(entries);
    });

    it('should reject entries that are not plain objects', () => {
      for (const entry of ['payment_initiation', ['nested'], null, 42]) {
        expect(() => parseAuthorizationDetailsInput(JSON.stringify([entry]), LIMITS)).toThrow(
          'authorization_details entries must be JSON objects',
        );
      }
    });
  });

  describe('type field (RFC 9396 §2 REQUIRED)', () => {
    it('should reject an entry without type', () => {
      expect(() => parseAuthorizationDetailsInput(JSON.stringify([{ actions: ['initiate'] }]), LIMITS)).toThrow(
        'authorization_details entries must have a non-empty type',
      );
    });

    it('should reject an empty-string type', () => {
      expect(() => parseAuthorizationDetailsInput(JSON.stringify([{ type: '' }]), LIMITS)).toThrow(
        'authorization_details entries must have a non-empty type',
      );
    });

    it('should reject a non-string type', () => {
      expect(() => parseAuthorizationDetailsInput(JSON.stringify([{ type: 7 }]), LIMITS)).toThrow(
        'authorization_details entries must have a non-empty type',
      );
    });
  });

  describe('common fields (RFC 9396 §2.2)', () => {
    it('should reject a locations value that is not an array', () => {
      expect(() =>
        parseAuthorizationDetailsInput(JSON.stringify([{ type: 'payment_initiation', locations: 'https://example.com' }]), LIMITS),
      ).toThrow('authorization_details common fields must have the RFC 9396 types');
    });

    it('should reject an identifier value that is not a string', () => {
      expect(() =>
        parseAuthorizationDetailsInput(JSON.stringify([{ type: 'payment_initiation', identifier: ['account-14'] }]), LIMITS),
      ).toThrow('authorization_details common fields must have the RFC 9396 types');
    });

    it('should reject a string-array field holding a non-string item', () => {
      expect(() =>
        parseAuthorizationDetailsInput(JSON.stringify([{ type: 'payment_initiation', actions: ['initiate', 7] }]), LIMITS),
      ).toThrow('authorization_details common fields must have the RFC 9396 types');
    });

    it('should accept all common fields with their RFC 9396 types', () => {
      const entry = {
        type: 'payment_initiation',
        locations: ['https://example.com/payments'],
        actions: ['initiate'],
        datatypes: ['transactions'],
        identifier: 'account-14',
        privileges: ['admin'],
      };
      expect(parseAuthorizationDetailsInput(JSON.stringify([entry]), LIMITS)).toEqual([entry]);
    });
  });

  describe('prototype safety (RFC 9396 §12 sanitize)', () => {
    it('should keep a __proto__ key as an own property without polluting prototypes', () => {
      const raw = '[{"type":"payment_initiation","__proto__":{"polluted":true}}]';
      const [detail] = parseAuthorizationDetailsInput(raw, LIMITS);
      expect(Object.getOwnPropertyNames(detail)).toEqual(['type', '__proto__']);
      expect(({} as Record<string, unknown>)['polluted']).toBe(undefined);
      expect(Object.getPrototypeOf(detail)).toBe(Object.prototype);
    });

    it('should keep a constructor key as data without replacing the real constructor behavior', () => {
      const raw = '[{"type":"payment_initiation","constructor":"overridden"}]';
      const [detail] = parseAuthorizationDetailsInput(raw, LIMITS);
      expect(detail['constructor']).toBe('overridden');
      expect(({} as Record<string, unknown>)['constructor']).toBe(Object);
    });
  });

  describe('error hygiene (RFC 9396 §13)', () => {
    it('should keep the input value out of the error message', () => {
      const secret = 'IBAN-DE75512108001245126199';
      let caught: unknown;
      try {
        parseAuthorizationDetailsInput(JSON.stringify([{ type: 7, account: secret }]), LIMITS);
      } catch (error) {
        caught = error;
      }
      expect(caught).toBeInstanceOf(RarError);
      expect((caught as RarError).message).toBe('authorization_details entries must have a non-empty type');
      expect((caught as RarError).message.includes(secret)).toBe(false);
    });
  });
});

describe('validateAuthorizationDetails', () => {
  it('should accept entries whose type definition validates', () => {
    expect(() => validateAuthorizationDetails([PAYMENT_DETAIL], [PAYMENT_TYPE])).not.toThrow();
  });

  it('should reject every entry when no type definitions are registered', () => {
    // fail-closed: 型定義が空なら全拒否（RFC 9396 §5）。
    expect(() => validateAuthorizationDetails([PAYMENT_DETAIL], [])).toThrow(
      'authorization_details contains an unsupported type',
    );
  });

  it('should reject an entry whose type has no definition', () => {
    const unknownDetail = { type: 'account_information' };
    expect(() => validateAuthorizationDetails([PAYMENT_DETAIL, unknownDetail], [PAYMENT_TYPE])).toThrow(
      'authorization_details contains an unsupported type',
    );
  });

  it('should propagate a RarError thrown by the type definition validate', () => {
    const invalid = { type: 'payment_initiation', actions: [] };
    expect(() => validateAuthorizationDetails([invalid], [PAYMENT_TYPE])).toThrow(
      'payment_initiation requires actions',
    );
  });

  it('should propagate a non-RarError thrown by the type definition validate', () => {
    const throwingType: AuthorizationDetailTypeDefinition = {
      type: 'payment_initiation',
      validate(): void {
        throw new TypeError('validator bug');
      },
      describe(): readonly string[] {
        return [];
      },
    };
    expect(() => validateAuthorizationDetails([PAYMENT_DETAIL], [throwingType])).toThrow(TypeError);
  });
});

describe('describeAuthorizationDetails', () => {
  it('should build the display lines in entry order', () => {
    const second = {
      ...PAYMENT_DETAIL,
      instructedAmount: { currency: 'USD', amount: '9.99' },
    };
    expect(describeAuthorizationDetails([PAYMENT_DETAIL, second], [PAYMENT_TYPE])).toEqual([
      'Initiate a payment of EUR 123.50',
      'Initiate a payment of USD 9.99',
    ]);
  });

  it('should reject an entry whose type has no definition', () => {
    expect(() => describeAuthorizationDetails([{ type: 'account_information' }], [PAYMENT_TYPE])).toThrow(
      'authorization_details contains an unsupported type',
    );
  });
});
```

### store.test.ts

```typescript
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createInMemoryRarDetailsStore } from './store.js';

const DETAILS = [{ type: 'payment_initiation', actions: ['initiate'] }] as const;

describe('createInMemoryRarDetailsStore', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-11-04T00:00:00Z'));
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('should return stored details for a key', async () => {
    const store = createInMemoryRarDetailsStore();
    await store.set('txn-1', DETAILS);
    expect(await store.get('txn-1')).toEqual(DETAILS);
  });

  it('should return undefined for an unknown key', async () => {
    const store = createInMemoryRarDetailsStore();
    expect(await store.get('missing')).toBe(undefined);
  });

  it('should return undefined after delete', async () => {
    const store = createInMemoryRarDetailsStore();
    await store.set('txn-1', DETAILS);
    await store.delete('txn-1');
    expect(await store.get('txn-1')).toBe(undefined);
  });

  it('should return undefined once expiresAt has passed', async () => {
    const store = createInMemoryRarDetailsStore();
    await store.set('grant-1', DETAILS, Date.now() + 1000);
    expect(await store.get('grant-1')).toEqual(DETAILS);
    vi.advanceTimersByTime(1000);
    expect(await store.get('grant-1')).toBe(undefined);
  });

  it('should keep an entry without expiresAt alive', async () => {
    const store = createInMemoryRarDetailsStore();
    await store.set('txn-1', DETAILS);
    vi.advanceTimersByTime(10 * 24 * 60 * 60 * 1000);
    expect(await store.get('txn-1')).toEqual(DETAILS);
  });

  it('should evict expired entries on the next set', async () => {
    const store = createInMemoryRarDetailsStore();
    await store.set('grant-1', DETAILS, Date.now() + 1000);
    vi.advanceTimersByTime(2000);
    // 書き込み時の lazy eviction で、失効済みの grant-1 が掃除される。
    await store.set('grant-2', DETAILS, Date.now() + 1000);
    expect(await store.get('grant-1')).toBe(undefined);
    expect(await store.get('grant-2')).toEqual(DETAILS);
  });
});
```

## CLI integration and the generated-code contribution

`packages/cli/src/registry.ts` gained the `rar` entry in `FEATURE_REGISTRY` and `EXPERIMENTAL_FEATURES`.
The feature is disabled by default (`DEFAULT_FEATURES`), requires no other feature, and the introspection block lives inside the introspection pipeline, so it disappears together with that feature when introspection is disabled.

```typescript
{ id: 'rar', tier: 'experimental', requires: [], packages: EXPERIMENTAL, frameworks: ALL_FRAMEWORKS, runtimes: ALL_RUNTIMES, summary: 'OAuth 2.0 Rich Authorization Requests (RFC 9396)' },
```

What follows is the complete code the hono output receives.
The Express and Fastify outputs share the same feature directory and blocks; the Next.js differences are described at the end of this section.

### features/rar/config.ts (new file, in full)

The byte / entry caps with fail-fast range checks, plus the `declare module` extension that puts `rarTypes` on `ProviderConfig` (the google-login config pattern).

```typescript
/**
 * EXPERIMENTAL — Rich Authorization Requests settings (RFC 9396).
 *
 * Read by the validate-authorization-details step of the authorization
 * endpoint. The type definitions themselves (`rarTypes`) live on
 * ProviderConfig, so an application injects them next to its other provider
 * settings.
 *
 * - maxAuthorizationDetailsBytes: UTF-8 byte cap of the whole parameter
 *   (range 1024–65536). RFC 9396 §11.4 points large requests to PAR; this cap
 *   is the DoS guard for everything the endpoint still parses.
 * - maxAuthorizationDetailsEntries: entries allowed in the array (range 1–64).
 */
import type { AuthorizationDetailTypeDefinition } from '@maronn-openid-connect/experimental/rar';

export const rarConfig = {
  maxAuthorizationDetailsBytes: 16384,
  maxAuthorizationDetailsEntries: 16,
};

// Fail fast on a config edit that leaves the documented ranges: a typo here
// either re-opens the DoS surface or rejects every request.
if (rarConfig.maxAuthorizationDetailsBytes < 1024 || rarConfig.maxAuthorizationDetailsBytes > 65536) {
  throw new Error('rarConfig.maxAuthorizationDetailsBytes must be between 1024 and 65536');
}
if (rarConfig.maxAuthorizationDetailsEntries < 1 || rarConfig.maxAuthorizationDetailsEntries > 64) {
  throw new Error('rarConfig.maxAuthorizationDetailsEntries must be between 1 and 64');
}

declare module '../../config.js' {
  interface ProviderConfig {
    /**
     * EXPERIMENTAL (RFC 9396 §5): 受理する authorization details 型の定義。
     * 登録した type だけが受理され、空（未設定）なら `authorization_details`
     * 付きのリクエストはすべて `invalid_authorization_details` になる
     * （fail-closed）。discovery はこの一覧の type 値を
     * `authorization_details_types_supported` として広告する（§10）。
     */
    rarTypes?: readonly AuthorizationDetailTypeDefinition[];
  }
}
```

### features/rar/store.ts (new file, in full)

Two instances of the experimental store contract, shared through a `globalThis` registry (the PAR store pattern).

```typescript
import {
  createInMemoryRarDetailsStore,
  type RarDetailsStore,
} from '@maronn-openid-connect/experimental/rar';

/**
 * EXPERIMENTAL — in-memory stores of the requested and granted
 * authorization details (RFC 9396).
 *
 * Two instances of the same contract:
 *
 * - rarTransactionStore: keyed by transactionId, holds the validated details
 *   between the authorization request and the consent decision. Entries live
 *   as long as the authorization transaction.
 * - rarGrantStore: keyed by grantId, holds the approved details for the token
 *   response (§7) and introspection (§9.2). Entries live as long as the
 *   refresh token absolute lifetime, evicted lazily on writes.
 *
 * Replace with persistent stores (Redis, KV, database) in production. Keys
 * are opaque identifiers minted by this provider: never interpolate them into
 * a query, always bind them as parameters.
 */

// Kept on globalThis so every module that asks for the stores gets the same
// ones, also where a framework loads a module more than once (dev-mode hot
// reloads, separate module layers).
const rarStoreRegistry = globalThis as typeof globalThis & {
  __oidcRarTransactionStore?: RarDetailsStore;
  __oidcRarGrantStore?: RarDetailsStore;
};

export const rarTransactionStore: RarDetailsStore =
  (rarStoreRegistry.__oidcRarTransactionStore ??= createInMemoryRarDetailsStore());

export const rarGrantStore: RarDetailsStore =
  (rarStoreRegistry.__oidcRarGrantStore ??= createInMemoryRarDetailsStore());
```

### features/rar/feature.ts (new file, in full)

The discovery hook advertises `authorization_details_types_supported` only while type definitions are registered, and the context hook hands both stores to the steps.

```typescript
import { defineFeature } from '../feature.js';
import { rarGrantStore, rarTransactionStore } from './store.js';

/**
 * EXPERIMENTAL — Rich Authorization Requests (RFC 9396): the
 * authorization_details parameter of the authorization endpoint, its rows on
 * the consent screen, and the approved details on the token response and
 * introspection. Settings are in config.ts; the accepted types are injected
 * through ProviderConfig.rarTypes.
 *
 * Backed by @maronn-openid-connect/experimental, whose API is NOT stable: it
 * may change in a breaking way between releases.
 */
export const rar = defineFeature({
  id: 'rar',
  // RFC 9396 §10 metadata. Only advertised while type definitions are
  // registered: a client must not send RAR to an OP that does not advertise
  // the member, and this OP rejects every request while the list is empty.
  discovery: (_issuer, config) =>
    config.rarTypes !== undefined && config.rarTypes.length > 0
      ? { authorization_details_types_supported: config.rarTypes.map((definition) => definition.type) }
      : {},
  context: { rarTransactionStore, rarGrantStore },
});
```

### features/rar/steps/validate-authorization-details.ts (new file, in full)

Reads the value (the Request Object claim supersedes the query per OIDC Core 1.0 §6.1), validates it, and applies the prompt control.

```typescript
import {
  AuthorizationError,
  type AuthorizationErrorCode,
  type ValidatedAuthorizationRequest,
} from '@maronn-openid-connect/core';
import {
  AUTHORIZATION_DETAILS_PARAM,
  RarError,
  parseAuthorizationDetailsInput,
  validateAuthorizationDetails,
  type AuthorizationDetail,
} from '@maronn-openid-connect/experimental/rar';
import type { AuthorizationRequestInput } from '../../../endpoints/authorize/outcome.js';
import { step } from '../../../endpoints/step.js';
import { rarConfig } from '../config.js';

export const meta = step({
  id: 'validate-authorization-details',
  endpoint: 'authorize',
  feature: 'rar',
  kind: 'validate',
  label: 'authorization_details を検証し、同意を必須にする',
  spec: 'RFC 9396 §3 / §5',
  function: 'validateAuthorizationDetailsRequest',
  consumes: ['params', 'requestObjectClaims', 'validatedRequest'],
  optional: ['requestObjectClaims'],
  produces: ['authorizationDetails'],
  removable: false,
});

/**
 * `authorization_details` を検証して返し、details があるリクエストには同意画面を必須にする。
 *
 * パラメータは、Request Object の claim（あればクエリより優先。OIDC Core 1.0 §6.1 の
 * supersede 規則）、無ければクエリ / PAR 由来の `params` から読む。無ければ何もせず
 * `undefined` を返す。あれば構造（RFC 9396 §2 / §2.2）と上限（`rarConfig`）を検査し、
 * `config.rarTypes` の型定義と突き合わせる（§5。型定義が空ならすべて拒否）。
 *
 * details があるリクエストはエンドユーザーの同意を毎回要する（SSO の同意スキップは
 * scope 単位の記録しか持たず details を知らない）ので、`prompt=none` 単独なら
 * `consent_required` で拒否し、それ以外なら `validatedRequest.prompt` へ `consent` を
 * 加えて、silent / SSO の両経路を同意画面へ向ける。`none` が他の値と組む不正な
 * リクエストには手を出さず、base の `[validate-prompt-combination]` に委ねる。
 *
 * エラーの `error_description` は固定の ASCII 文言で、details の内容を反映しない
 * （RFC 9396 §13）。
 *
 * 実験的な機能である。
 *
 * @spec RFC 9396 §3
 * @spec RFC 9396 §5
 * @throws {AuthorizationError} `invalid_authorization_details`: 構造違反、上限超過、未知の type、型定義の検証違反のとき
 * @throws {AuthorizationError} `consent_required`: details 付きのリクエストが `prompt=none` 単独のとき
 */
export function validateAuthorizationDetailsRequest(
  c: any,
  input: {
    params: AuthorizationRequestInput;
    requestObjectClaims?: Record<string, unknown>;
    validatedRequest: ValidatedAuthorizationRequest;
  },
): AuthorizationDetail[] | undefined {
  const { params, requestObjectClaims, validatedRequest } = input;
  const raw = requestObjectClaims?.[AUTHORIZATION_DETAILS_PARAM] ?? params[AUTHORIZATION_DETAILS_PARAM];
  if (raw === undefined) return undefined;

  const config = c.get('config');
  let details: AuthorizationDetail[];
  try {
    details = parseAuthorizationDetailsInput(raw, {
      maxBytes: rarConfig.maxAuthorizationDetailsBytes,
      maxEntries: rarConfig.maxAuthorizationDetailsEntries,
    });
    validateAuthorizationDetails(details, config.rarTypes ?? []);
  } catch (error) {
    // 失敗の種類（構造、上限、未知 type、型定義の違反）によらず同じ固定文言にし、
    // details の値（金額、口座、type 名）をエラー経由で漏らさない（RFC 9396 §13）。
    if (error instanceof RarError) {
      throw new AuthorizationError(
        error.code as AuthorizationErrorCode,
        'The authorization_details parameter is invalid',
        validatedRequest.redirectUri,
        validatedRequest.state,
      );
    }
    throw error;
  }

  const promptValues = validatedRequest.prompt ?? [];
  if (promptValues.includes('none')) {
    // `none` 単独は、画面を出せないのに新規同意が要るので `consent_required`（OIDC Core 1.0 §3.1.2.1 の意味論）。
    // `none` と他の値の組み合わせは本機能の管轄外で、base の検査が `invalid_request` にする。
    if (promptValues.length === 1) {
      throw new AuthorizationError(
        'consent_required' as AuthorizationErrorCode,
        'authorization_details requires user consent',
        validatedRequest.redirectUri,
        validatedRequest.state,
      );
    }
    return details;
  }

  // details は毎回ユーザーに見せて承認させる。`prompt=consent` は OIDC Core 1.0
  // §3.1.2.1 の「consent MUST re-display」にそのまま乗り、silent / SSO の同意
  // スキップ（authenticate-silently / reuse-session）の両方がこの値で止まる。
  if (!promptValues.includes('consent')) {
    validatedRequest.prompt = [...promptValues, 'consent'];
  }
  return details;
}
```

### features/rar/steps/record-authorization-details.ts (new file, in full)

Persists the validated details under the transactionId with the transaction TTL.

```typescript
import type { AuthorizationDetail } from '@maronn-openid-connect/experimental/rar';
import { step } from '../../../endpoints/step.js';

export const meta = step({
  id: 'record-authorization-details',
  endpoint: 'authorize',
  feature: 'rar',
  kind: 'persist',
  label: 'authorization details をトランザクションへ保持する',
  spec: 'RFC 9396 §3',
  function: 'recordAuthorizationDetails',
  calls: ['rarTransactionStore.set'],
  consumes: ['transactionId', 'transactionTtlSeconds', 'authorizationDetails'],
  optional: ['authorizationDetails'],
  produces: [],
  removable: false,
});

/**
 * 検証済みの authorization details を、トランザクション ID をキーに保存する。
 *
 * details の無いリクエスト（`authorizationDetails` が `undefined`）では何もしない。
 * 保存の寿命は認可トランザクションと同じ（`transactionTtlSeconds`）で、同意まで
 * 進まなかったトランザクションの details はストアの失効で消える。
 *
 * 実験的な機能である。
 *
 * @spec RFC 9396 §3
 */
export async function recordAuthorizationDetails(
  c: any,
  input: {
    transactionId: string;
    transactionTtlSeconds: number;
    authorizationDetails: AuthorizationDetail[] | undefined;
  },
): Promise<void> {
  const { transactionId, transactionTtlSeconds, authorizationDetails } = input;
  if (authorizationDetails === undefined) return;
  const rarTransactionStore = c.get('rarTransactionStore');
  await rarTransactionStore.set(
    transactionId,
    authorizationDetails,
    Date.now() + transactionTtlSeconds * 1000,
  );
}
```

### features/rar/steps/describe-authorization-details.ts (new file, in full)

Builds the consent display rows from the stored details; throws when a stored type no longer has a definition, so nothing is approved unseen.

```typescript
import { describeAuthorizationDetails } from '@maronn-openid-connect/experimental/rar';
import { step } from '../../../endpoints/step.js';

export const meta = step({
  id: 'describe-authorization-details',
  endpoint: 'consent',
  feature: 'rar',
  kind: 'transform',
  label: '同意画面に出す authorization details の表示行を作る',
  spec: 'RFC 9396 §3.1',
  function: 'describeTransactionAuthorizationDetails',
  calls: ['rarTransactionStore.get'],
  consumes: ['transactionId'],
  produces: ['authorizationDetails'],
  removable: false,
});

/**
 * トランザクションに保持した authorization details の表示行を返す。
 *
 * details の無いトランザクションでは `undefined` を返し、同意画面は従来どおりに
 * なる。あれば、`config.rarTypes` の型定義の `describe` が作るプレーン文字列の行を
 * 返し、同意画面が scope の一覧と併記する（RFC 9396 §3.1 の merged set）。
 * 行のエスケープは view 層（JSX）に委ねる。
 *
 * 保持した details の type に対応する型定義が無くなっていたら例外を投げる
 * （表示できない要素を黙って落とすと、見ていない権限が承認されてしまう）。
 *
 * 実験的な機能である。
 *
 * @spec RFC 9396 §3.1
 * @throws {RarError} 保持した details の type に対応する型定義が設定から消えているとき
 */
export async function describeTransactionAuthorizationDetails(
  c: any,
  transactionId: string,
): Promise<readonly string[] | undefined> {
  const rarTransactionStore = c.get('rarTransactionStore');
  const details = await rarTransactionStore.get(transactionId);
  if (details === undefined) return undefined;
  const config = c.get('config');
  return describeAuthorizationDetails(details, config.rarTypes ?? []);
}
```

### features/rar/steps/record-granted-details.ts (new file, in full)

At the consent confirmation point, moves the details from the transactionId key to the grantId key with the refresh-token absolute lifetime.

```typescript
import type { AuthorizationCodeData } from '@maronn-openid-connect/core';
import { step } from '../../../endpoints/step.js';

export const meta = step({
  id: 'record-granted-details',
  endpoint: 'consent',
  feature: 'rar',
  kind: 'persist',
  label: '承認された authorization details をグラントへ紐付ける',
  spec: 'RFC 9396 §7',
  function: 'recordGrantedAuthorizationDetails',
  calls: ['rarTransactionStore.get', 'rarTransactionStore.delete', 'rarGrantStore.set'],
  consumes: ['transactionId', 'authCodeData'],
  produces: [],
  removable: false,
});

/**
 * 承認されたトランザクションの authorization details を grantId へ付け替える。
 *
 * details の無いトランザクションでは何もしない。あれば grantId をキーに保存し、
 * transactionId 側のエントリを削除する。grantId は authorization_code と
 * refresh_token の両グラントを貫通するので、トークン応答（RFC 9396 §7）と
 * introspection（§9.2）はこのキーで details を引ける。
 *
 * 保存の寿命は `発行時刻 + config.refreshTokenAbsoluteLifetime`。ローテーションは
 * 絶対寿命を初回発行時刻起点で固定するため、有効なリフレッシュトークンが存在する
 * 間にエントリが先に消えることはない。リフレッシュトークンを発行しないグラントでは
 * 寿命まで過剰保持になるが、in-memory の experimental として許容している。
 *
 * 実験的な機能である。
 *
 * @spec RFC 9396 §7
 */
export async function recordGrantedAuthorizationDetails(
  c: any,
  transactionId: string,
  authCodeData: AuthorizationCodeData,
): Promise<void> {
  const rarTransactionStore = c.get('rarTransactionStore');
  const details = await rarTransactionStore.get(transactionId);
  if (details === undefined) return;
  const config = c.get('config');
  const rarGrantStore = c.get('rarGrantStore');
  await rarGrantStore.set(
    authCodeData.grantId,
    details,
    Date.now() + config.refreshTokenAbsoluteLifetime * 1000,
  );
  await rarTransactionStore.delete(transactionId);
}
```

### features/rar/steps/reject-token-request-details.ts (new file, in full)

Rejects `authorization_details` on the token request with 400 `invalid_authorization_details`, ahead of every side effect.

```typescript
import { AUTHORIZATION_DETAILS_PARAM } from '@maronn-openid-connect/experimental/rar';
import { TokenEndpointError } from '../../../endpoints/token/response.js';
import { step } from '../../../endpoints/step.js';

export const meta = step({
  id: 'reject-token-request-details',
  endpoint: 'token',
  feature: 'rar',
  kind: 'validate',
  label: 'トークンリクエストの authorization_details を拒否する',
  spec: 'RFC 9396 §6',
  function: 'rejectTokenRequestAuthorizationDetails',
  consumes: ['params'],
  produces: [],
  removable: false,
});

/**
 * トークンリクエストに `authorization_details` があれば、400 の `invalid_authorization_details` で拒否する。
 *
 * RFC 9396 §6 のトークンリクエストでの再指定（narrowing）には対応しない。黙って
 * 無視すると「絞り込まれた」とクライアントに誤認させるので、明示的に拒否する。
 * このステップは feature grant の dispatch 群の直後・`[validate-grant-type]` の前に
 * 置き、トークンの発行・保存・提示リフレッシュトークンのローテーション失効という
 * どの副作用よりも前に拒否を確定させる（応答組み立て時の拒否は、拒否済み
 * リクエストの副作用を残すため禁止している）。
 *
 * 実験的な機能である。
 *
 * @spec RFC 9396 §6
 * @throws {TokenEndpointError} 400 `invalid_authorization_details`: リクエストに `authorization_details` パラメータがあるとき
 */
export function rejectTokenRequestAuthorizationDetails(params: Record<string, string>): void {
  if (params[AUTHORIZATION_DETAILS_PARAM] === undefined) return;
  throw new TokenEndpointError({
    status: 400,
    body: {
      error: 'invalid_authorization_details',
      error_description: 'authorization_details is not accepted at the token endpoint',
    },
  });
}
```

### features/rar/steps/append-token-response-details.ts (new file, in full)

Appends the approved array to the token response body (§7 MUST, no §7.1 enrichment).

```typescript
import type { ValidatedTokenRequest } from '@maronn-openid-connect/core';
import type { TokenEndpointResponse } from '../../../endpoints/token/response.js';
import { step } from '../../../endpoints/step.js';

export const meta = step({
  id: 'append-token-response-details',
  endpoint: 'token',
  feature: 'rar',
  kind: 'transform',
  label: '承認済みの authorization details を応答へ含める',
  spec: 'RFC 9396 §7',
  function: 'appendAuthorizationDetailsToTokenResponse',
  calls: ['rarGrantStore.get'],
  consumes: ['tokenResponse', 'validatedRequest'],
  produces: ['tokenResponse'],
  removable: false,
});

/**
 * グラントに紐づく authorization details があれば、トークンレスポンスのボディへ加えて返す。
 *
 * `validatedRequest.grantId`（authorization_code / refresh_token の両グラントを
 * 貫通する）で grant ストアを引き、あれば承認された配列をそのまま
 * `authorization_details` メンバーとして加える（RFC 9396 §7 の MUST。§7.1 の
 * enrichment はしない）。無ければ応答を変えずに返すので、details を持たない
 * グラントの応答は従来とバイト単位で同じである。
 *
 * 実験的な機能である。
 *
 * @spec RFC 9396 §7
 */
export async function appendAuthorizationDetailsToTokenResponse(
  c: any,
  tokenResponse: TokenEndpointResponse,
  validatedRequest: ValidatedTokenRequest,
): Promise<TokenEndpointResponse> {
  const rarGrantStore = c.get('rarGrantStore');
  const details = await rarGrantStore.get(validatedRequest.grantId);
  if (details === undefined) return tokenResponse;
  return {
    ...tokenResponse,
    body: { ...tokenResponse.body, authorization_details: details },
  };
}
```

### features/rar/steps/append-introspection-details.ts (new file, in full)

Appends the member to an `active: true` introspection answer (§9.2), before the optional RFC 9701 signing.

```typescript
import type {
  IntrospectionResponse,
  ResolvedIntrospectionToken,
} from '@maronn-openid-connect/core';
import { step } from '../../../endpoints/step.js';

export const meta = step({
  id: 'append-introspection-details',
  endpoint: 'introspection',
  feature: 'rar',
  kind: 'transform',
  label: 'authorization details を introspection 応答へ含める',
  spec: 'RFC 9396 §9.2',
  function: 'appendAuthorizationDetailsToIntrospection',
  calls: ['rarGrantStore.get'],
  consumes: ['introspection', 'resolved'],
  produces: ['introspection'],
  removable: false,
});

/**
 * 有効なトークンのグラントに authorization details があれば、introspection 応答へ加えて返す。
 *
 * `active: true` の応答に限り、解決済みトークンの `grantId` で grant ストアを引き、
 * あれば `authorization_details` を top-level member として加える（RFC 9396 §9.2 の
 * 構造要件。資源サーバー別のフィルタリングはしない）。`active: false` の応答と
 * details を持たないトークンの応答は変えずに返す。jwt-introspection-response
 * 併用時は、このステップの後に署名されるので member は署名対象に含まれる。
 *
 * 実験的な機能である。
 *
 * @spec RFC 9396 §9.2
 */
export async function appendAuthorizationDetailsToIntrospection(
  c: any,
  introspection: IntrospectionResponse,
  resolved: ResolvedIntrospectionToken | null,
): Promise<IntrospectionResponse> {
  if (!introspection.active || resolved === null) return introspection;
  const grantId =
    resolved.tokenType === 'access_token'
      ? resolved.accessToken.grantId
      : resolved.refreshToken.grantId;
  const rarGrantStore = c.get('rarGrantStore');
  const details = await rarGrantStore.get(grantId);
  if (details === undefined) return introspection;
  // RFC 9396 §9.2 の拡張 member。core の IntrospectionResponse 型は閉じた union
  // なので、member を足した応答は型表明で IntrospectionResponse に戻す。
  return { ...introspection, authorization_details: details } as IntrospectionResponse;
}
```

### Where the pipeline blocks land

On `endpoints/authorize/pipeline.ts`, validation sits between `[validate-hybrid-request]` and `[create-transaction]` — before the transaction is created, so the `consent` added to `validatedRequest.prompt` is what gets stored — and recording sits right after `[create-transaction]`:

```typescript
    // [validate-authorization-details] (feature: rar) authorization_details を検証し、同意を必須にする — RFC 9396 §3 / §5
    const authorizationDetails = validateAuthorizationDetailsRequest(c, { params, requestObjectClaims, validatedRequest });
```

```typescript
    // [record-authorization-details] (feature: rar) authorization details をトランザクションへ保持する — RFC 9396 §3
    await recordAuthorizationDetails(c, { transactionId, transactionTtlSeconds, authorizationDetails });
```

One hono-specific wrinkle shaped the consent GET path.
A feature-owned block in a hono pipeline extends from its marker to the next marker or the end of the handler, so a rar block placed last in `prepareConsent()` would swallow the `return` statement when the feature is removed.
The rar block therefore sits **before** `[describe-consent-screen]`, producing `authorizationDetails`, and the base `return` reads it; with rar disabled, the generator replaces the binding with `const authorizationDetails = undefined;` and the screen renders exactly as before:

```typescript
  // [describe-authorization-details] (feature: rar) 同意画面に出す authorization details の表示行を作る — RFC 9396 §3.1
  const authorizationDetails = await describeTransactionAuthorizationDetails(c, transactionId);

  // [describe-consent-screen] 同意画面の表示内容を組み立てる
  const screen = await describeConsentScreen(c, transactionId, transaction);
  return { ...screen, authorizationDetails };
```

In `submitConsent()`, the hand-over block runs at the consent confirmation point, between the authorization-code issuance and the consent record:

```typescript
  // [record-granted-details] (feature: rar) 承認された authorization details をグラントへ紐付ける — RFC 9396 §7
  await recordGrantedAuthorizationDetails(c, transactionId, authCodeData);
```

On `endpoints/token/pipeline.ts`, the reject block follows `[dispatch-ciba]` and precedes `[validate-grant-type]`, and the append block follows `[build-token-response]`, whose `const tokenResponse` became `let` (the same pattern as PAR's reassigned `let params`):

```typescript
    // [reject-token-request-details] (feature: rar) トークンリクエストの authorization_details を拒否する — RFC 9396 §6
    rejectTokenRequestAuthorizationDetails(params);
```

```typescript
    // [build-token-response] トークンレスポンスのボディを組み立てる — OIDC Core 1.0 §3.1.3.3 / RFC 6749 §5.1
    let tokenResponse = buildTokenResponse(c, { accessToken, idToken, refreshToken, validatedRequest });

    // [append-token-response-details] (feature: rar) 承認済みの authorization details を応答へ含める — RFC 9396 §7
    tokenResponse = await appendAuthorizationDetailsToTokenResponse(c, tokenResponse, validatedRequest);
```

On the introspection pipeline of the introspection feature, the append block sits between `[build-response]` (now `let introspection`) and `[sign-response]`:

```typescript
    // [build-response] トークンの情報をまとめる（有効かどうか） — RFC 7662 §2.2
    let introspection = describeIntrospectedToken(resolved);

    // [append-introspection-details] (feature: rar) authorization details を introspection 応答へ含める — RFC 9396 §9.2
    introspection = await appendAuthorizationDetailsToIntrospection(c, introspection, resolved);
```

### The consent-screen base change

`ConsentScreen` (the consent logic layer) and `ConsentPageParams` (the view layer) gained an optional field, the default view lists it only when present, and `page.tsx` passes it through — so the disabled output renders the same markup as before:

```typescript
  /**
   * Display lines of the requested authorization details (RFC 9396 §3.1),
   * shown next to the scopes. Set by the rar feature; absent without it or
   * when the request carried no authorization_details.
   */
  authorizationDetails?: readonly string[];
```

```tsx
      {params.authorizationDetails && params.authorizationDetails.length > 0 ? (
        <>
          <p>The client also requests the following authorization details:</p>
          <ul>
            {params.authorizationDetails.map((line) => (
              <li>{line}</li>
            ))}
          </ul>
        </>
      ) : null}
```

Each endpoint's `endpoint.ts` lists the new feature-tagged steps (authorize: `validate-authorization-details` / `record-authorization-details`; consent: `describe-authorization-details` / `record-granted-details` with GET and approval edges; token: `reject-token-request-details` / `append-token-response-details`; introspection: `append-introspection-details`), and `features/enabled.ts` gains the import and list entry:

```typescript
import { rar } from './rar/feature.js';
```

```typescript
  rar,
```

### The Next.js output

Next.js implements the same flow with `_oidc-provider/features/rar/` (config / store / feature / authorize / consent / token / introspect) and same-named owner blocks on the authorize, consent-decision, token and introspect Route Handlers ([apps/nextjs/src/app/_oidc-provider/features/rar/](https://github.com/maronnjapan/maronn-openid-connect/tree/main/apps/nextjs/src/app/_oidc-provider/features/rar)).
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

```typescript
/**
 * 機能が同意画面に加える表示行を、機能の順に集めて返す。
 *
 * 各機能の `consent.describeTransaction` をトランザクション ID と設定で呼び、
 * 返った行をつなげる。表示する内容を持たない機能は空配列を返すので、
 * どの機能も無ければ結果も空配列になる。
 */
export async function consentRowsOf(
  features: readonly Feature[],
  transactionId: string,
  config: ProviderConfig,
): Promise<string[]> {
  const rows: string[] = [];
  for (const feature of features) {
    const describe = feature.consent?.describeTransaction;
    if (describe === undefined) continue;
    rows.push(...(await describe(transactionId, config)));
  }
  return rows;
}
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

```typescript
    // [validate-authorization-details] (feature: rar) authorization_details を検証し、同意を必須にする — RFC 9396 §3 / §5
    const rarRequest = validateAuthorizationDetailsRequest({ params, requestObjectClaims, prompt, redirectUri, state, rarTypes: resolveRarTypes(config) });
    const authorizationDetails = rarRequest.authorizationDetails;
    prompt = rarRequest.prompt;
```

### The demo type (outside the generated code)

So the E2E suite can exercise the feature over the protocol, the repository's development apps (apps/hono through `app.ts`, apps/nextjs through `dev-data.ts`) register a demo `payment_initiation` type shaped after RFC 9396 §2.1 Figure 1.
Both registration points sit outside the CLI extraction roots, so a generated provider starts with zero types.

```typescript
/**
 * EXPERIMENTAL (RFC 9396): the demo authorization-details type of this app.
 *
 * A payment_initiation type shaped after the example of RFC 9396 §2.1
 * Figure 1, registered by app.ts so tests/e2e can exercise the rar feature
 * over the protocol. It is this app's own development data — the CLI never
 * copies this file into generated code, and a generated provider accepts no
 * type until its operator injects definitions through config.rarTypes.
 */
import {
  RarError,
  type AuthorizationDetail,
  type AuthorizationDetailTypeDefinition,
} from '@maronn-openid-connect/experimental/rar';

/** The actions the demo type accepts (RFC 9396 §2.1 uses "initiate"). */
const PAYMENT_ACTIONS = ['initiate', 'status', 'cancel'] as const;

/** The display verb of each accepted action on the consent screen. */
const ACTION_VERBS: Record<(typeof PAYMENT_ACTIONS)[number], string> = {
  initiate: 'Initiate a payment of',
  status: 'Check the status of a payment of',
  cancel: 'Cancel a payment of',
};

/**
 * payment_initiation の要素を検証し、`actions` の値域と `instructedAmount` の構造に違反があれば `RarError` を投げる。
 *
 * `actions` は `initiate` / `status` / `cancel` だけからなる非空の配列、
 * `instructedAmount` は `{ currency: 大文字 3 文字, amount: 小数 2 桁の文字列 }` の
 * オブジェクトでなければならない（RFC 9396 §2.1 の例の形）。
 * message は固定の ASCII 文言で、入力値を含めない。
 *
 * @spec RFC 9396 §2.1
 * @throws {RarError} `actions` か `instructedAmount` が上の形でないとき
 */
function validatePaymentInitiation(detail: AuthorizationDetail): void {
  const actions = detail.actions;
  if (
    !Array.isArray(actions) ||
    actions.length === 0 ||
    actions.some((action) => !(PAYMENT_ACTIONS as readonly string[]).includes(action))
  ) {
    throw new RarError('payment_initiation requires actions out of initiate, status, cancel');
  }
  const instructedAmount = detail['instructedAmount'];
  if (typeof instructedAmount !== 'object' || instructedAmount === null || Array.isArray(instructedAmount)) {
    throw new RarError('payment_initiation requires an instructedAmount object');
  }
  const { currency, amount } = instructedAmount as Record<string, unknown>;
  if (typeof currency !== 'string' || !/^[A-Z]{3}$/.test(currency)) {
    throw new RarError('payment_initiation requires an uppercase three-letter currency');
  }
  if (typeof amount !== 'string' || !/^\d+\.\d{2}$/.test(amount)) {
    throw new RarError('payment_initiation requires a decimal amount string');
  }
}

/**
 * payment_initiation の要素から、同意画面に出す固定書式の表示行（アクションごとに 1 行）を返す。
 *
 * `validatePaymentInitiation()` を通った要素だけを受ける前提で、
 * `Initiate a payment of EUR 123.50` のようなプレーン文字列を組み立てる。
 *
 * @spec RFC 9396 §3.1
 */
function describePaymentInitiation(detail: AuthorizationDetail): readonly string[] {
  const { currency, amount } = detail['instructedAmount'] as { currency: string; amount: string };
  const actions = (detail.actions ?? []) as readonly (typeof PAYMENT_ACTIONS)[number][];
  return actions.map((action) => `${ACTION_VERBS[action]} ${currency} ${amount}`);
}

/** The demo type definitions app.ts passes to applyOidc as config.rarTypes. */
export const demoRarTypes: readonly AuthorizationDetailTypeDefinition[] = [
  {
    type: 'payment_initiation',
    validate: validatePaymentInitiation,
    describe: describePaymentInitiation,
  },
];
```

## The E2E spec, in full

The E2E client gained a `/start-rar` route that runs the ordinary code flow with the demo `authorization_details` attached, then observes the details on all three channels (token response, refresh, introspection) and prints them as JSON, plus the rotated refresh token.
The spec skips itself through discovery's `authorization_details_types_supported`, so sample OPs generated without `--enable rar` only run the one test that shows the parameter is still ignored as before.
The token-endpoint rejection test verifies the before-side-effects property over the protocol: after a refresh request carrying `authorization_details` is rejected with 400, a retry with the **same refresh token** succeeds — which is only possible if the rejection happened before the rotation revoked the presented token.

### specs/rar.spec.ts

```typescript
import { expect, test } from '@playwright/test';

const host = process.env.E2E_HOST ?? '127.0.0.1';
const clientPort = Number(process.env.E2E_CLIENT_PORT ?? '3020');
const clientBaseURL =
  process.env.E2E_CLIENT_BASE_URL ?? `http://${host}:${clientPort}`;
const clientId = 'e2e-client';
const clientSecret = 'e2e-client-secret';

// The demo type the app OPs register (apps/*/src/rar-demo.ts): the
// payment_initiation example of RFC 9396 §2.1 Figure 1.
const PAYMENT_DETAIL = {
  type: 'payment_initiation',
  actions: ['initiate'],
  locations: ['https://example.com/payments'],
  instructedAmount: { currency: 'EUR', amount: '123.50' },
};

/**
 * EXPERIMENTAL — Rich Authorization Requests (RFC 9396).
 *
 * Only an OP generated with `--enable rar` (and with type definitions
 * registered) advertises authorization_details_types_supported, so most tests
 * here skip when discovery does not advertise the demo type. That keeps the
 * shared spec suite green across all sample OPs; the one test that runs
 * without the feature shows the parameter is ignored as before.
 */
test.describe('Rich Authorization Requests (RAR)', () => {
  test('should carry the approved details to the token response, the refresh and introspection', async ({
    page,
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    test.skip(!(await rarAdvertised(request, issuer)), 'This OP was generated without --enable rar');

    await page.goto(`${clientBaseURL}/start-rar`);
    await page.getByLabel('Username:').fill('testuser');
    await page.getByLabel('Password:').fill('password');
    await page.getByRole('button', { name: 'Login' }).click();
    await expect(page).toHaveURL(new RegExp(`^${escapeRegExp(issuer)}/consent$`));

    // RFC 9396 §3.1: the consent screen lists the requested details next to
    // the scopes, with the display line the type definition built.
    await expect(page.getByText('Initiate a payment of EUR 123.50')).toBeVisible();

    await page.getByRole('button', { name: 'Approve' }).click();

    // §7: the token response of the code grant carries the approved details,
    // and a refresh of the same grant carries them unchanged.
    await expect(page.getByTestId('token-type')).toHaveText('Bearer');
    await expect(page.getByTestId('rar-token-details')).toHaveText(JSON.stringify([PAYMENT_DETAIL]));
    await expect(page.getByTestId('rar-refresh-details')).toHaveText(JSON.stringify([PAYMENT_DETAIL]));

    // §9.2: introspection reports them as a top-level member.
    await expect(page.getByTestId('rar-introspection-active')).toHaveText('true');
    await expect(page.getByTestId('rar-introspection-details')).toHaveText(JSON.stringify([PAYMENT_DETAIL]));
  });

  test('should advertise the registered types in discovery', async ({ request, baseURL }) => {
    const issuer = requireBaseUrl(baseURL);
    const types = await advertisedTypes(request, issuer);
    test.skip(types === undefined, 'This OP was generated without --enable rar');

    // RFC 9396 §10: exactly the registered demo type.
    expect(types).toEqual(['payment_initiation']);
  });

  test('should reject an unknown type with an invalid_authorization_details redirect', async ({
    page,
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    test.skip(!(await rarAdvertised(request, issuer)), 'This OP was generated without --enable rar');

    // RFC 9396 §5: a request with a type the OP does not understand MUST be
    // refused. The error redirects to the client with the registered code.
    await page.goto(`${clientBaseURL}/start-rar?type=account_information`);
    await expect(page.getByTestId('authorization-error')).toHaveText('invalid_authorization_details');
    // The fixed description carries no detail values (RFC 9396 §13).
    await expect(page.getByTestId('authorization-error-description')).toHaveText(
      'The authorization_details parameter is invalid',
    );
  });

  test('should answer prompt=none with consent_required', async ({ page, request, baseURL }) => {
    const issuer = requireBaseUrl(baseURL);
    test.skip(!(await rarAdvertised(request, issuer)), 'This OP was generated without --enable rar');

    // Details always need fresh consent, and prompt=none forbids showing the
    // consent screen (OIDC Core 1.0 §3.1.2.1), so the request fails up front.
    await page.goto(`${clientBaseURL}/start-rar?prompt=none`);
    await expect(page.getByTestId('authorization-error')).toHaveText('consent_required');
  });

  test('should reject authorization_details at the token endpoint before any side effect', async ({
    page,
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    test.skip(!(await rarAdvertised(request, issuer)), 'This OP was generated without --enable rar');

    await page.goto(`${clientBaseURL}/start-rar`);
    await page.getByLabel('Username:').fill('testuser');
    await page.getByLabel('Password:').fill('password');
    await page.getByRole('button', { name: 'Login' }).click();
    await page.getByRole('button', { name: 'Approve' }).click();
    await expect(page.getByTestId('token-type')).toHaveText('Bearer');
    const refreshToken = await page.getByTestId('rar-refresh-token').textContent();
    expect(refreshToken).not.toBe('');

    // RFC 9396 §6 narrowing is not supported: the request is refused with the
    // registered error code instead of being silently ignored.
    const rejected = await request.post(`${issuer}/token`, {
      form: {
        grant_type: 'refresh_token',
        refresh_token: refreshToken ?? '',
        client_id: clientId,
        client_secret: clientSecret,
        authorization_details: JSON.stringify([PAYMENT_DETAIL]),
      },
    });
    expect(rejected.status()).toBe(400);
    expect(await rejected.json()).toEqual({
      error: 'invalid_authorization_details',
      error_description: 'authorization_details is not accepted at the token endpoint',
    });

    // The rejection happened before any side effect: the presented refresh
    // token was neither rotated nor revoked, so the same token still works.
    const retried = await request.post(`${issuer}/token`, {
      form: {
        grant_type: 'refresh_token',
        refresh_token: refreshToken ?? '',
        client_id: clientId,
        client_secret: clientSecret,
      },
    });
    expect(retried.status()).toBe(200);
    const retriedBody = (await retried.json()) as { token_type: string; authorization_details?: unknown };
    expect(retriedBody.token_type).toBe('Bearer');
    expect(retriedBody.authorization_details).toEqual([PAYMENT_DETAIL]);
  });

  test('should complete the flow as before when the OP was generated without rar', async ({
    page,
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    test.skip(await rarAdvertised(request, issuer), 'This OP answers authorization_details');

    // Without the feature the parameter is an unknown request parameter: the
    // flow completes and no channel carries authorization_details.
    await page.goto(`${clientBaseURL}/start-rar`);
    await page.getByLabel('Username:').fill('testuser');
    await page.getByLabel('Password:').fill('password');
    await page.getByRole('button', { name: 'Login' }).click();
    await expect(page).toHaveURL(new RegExp(`^${escapeRegExp(issuer)}/consent$`));
    await page.getByRole('button', { name: 'Approve' }).click();

    await expect(page.getByTestId('token-type')).toHaveText('Bearer');
    await expect(page.getByTestId('rar-token-details')).toHaveText('null');
    await expect(page.getByTestId('rar-refresh-details')).toHaveText('null');
    await expect(page.getByTestId('rar-introspection-details')).toHaveText('null');
  });
});

interface DiscoveryMetadata {
  authorization_details_types_supported?: string[];
}

async function advertisedTypes(
  request: { get(url: string): Promise<{ json(): Promise<unknown> }> },
  issuer: string,
): Promise<string[] | undefined> {
  const response = await request.get(`${issuer}/.well-known/openid-configuration`);
  const metadata = (await response.json()) as DiscoveryMetadata;
  return metadata.authorization_details_types_supported;
}

async function rarAdvertised(
  request: { get(url: string): Promise<{ json(): Promise<unknown> }> },
  issuer: string,
): Promise<boolean> {
  return ((await advertisedTypes(request, issuer)) ?? []).includes('payment_initiation');
}

function requireBaseUrl(baseURL: string | undefined): string {
  if (baseURL === undefined) {
    throw new Error('baseURL is not configured');
  }
  return baseURL;
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}
```

### The E2E client additions

The `/start-rar` route, the `authorization_details` attachment on the authorization URL, and the three-channel observation after the callback:

```javascript
    // EXPERIMENTAL (RFC 9396): run the ordinary code flow with an
    // authorization_details parameter (the payment_initiation example of
    // §2.1), then refresh and introspect to see the approved details come
    // back on every channel.
    if (req.method === 'GET' && url.pathname === '/start-rar') {
      await startAuthorization(url, res, { rar: true });
      return;
    }
```

```javascript
  // EXPERIMENTAL (RFC 9396 §3): the authorization_details parameter, a
  // URL-encoded JSON array shaped after the payment_initiation example of
  // §2.1. A spec overrides the type (?type=...) to drive the unknown-type
  // rejection of §5.
  if (options.rar === true) {
    authorizationUrl.searchParams.set('authorization_details', JSON.stringify([
      {
        type: requestUrl.searchParams.get('type') ?? 'payment_initiation',
        actions: ['initiate'],
        locations: ['https://example.com/payments'],
        instructedAmount: { currency: 'EUR', amount: '123.50' },
      },
    ]));
  }
```

```javascript
/**
 * EXPERIMENTAL — Rich Authorization Requests (RFC 9396 §7 / §9.2).
 *
 * Follows the approved details over every channel they travel on: the token
 * response of the code grant, the token response of a refresh (same grant),
 * and the introspection answer a resource server would get. The page prints
 * each one as JSON ('null' when the member is absent), plus the rotated
 * refresh token so a spec can drive the token-endpoint rejection of §6 with
 * it.
 */
async function completeRarInspection(res, tokens) {
  const refreshed = tokens.refresh_token === undefined
    ? null
    : await formPost(new URL('/token', issuer), {
      grant_type: 'refresh_token',
      refresh_token: tokens.refresh_token,
      client_id: clientId,
      client_secret: clientSecret,
    });
  const introspected = await formPost(new URL('/introspect', issuer), {
    token: (refreshed ?? tokens).access_token,
    client_id: clientId,
    client_secret: clientSecret,
  });
  sendHtml(res, 200, `<!doctype html>
<html>
  <head><title>RAR Complete</title></head>
  <body>
    <main>
      <h1>RAR Complete</h1>
      <dl>
        <dt>token type</dt><dd data-testid="token-type">${escapeHtml(tokens.token_type)}</dd>
        <dt>token details</dt><dd data-testid="rar-token-details">${escapeHtml(JSON.stringify(tokens.authorization_details ?? null))}</dd>
        <dt>refreshed details</dt><dd data-testid="rar-refresh-details">${escapeHtml(JSON.stringify(refreshed?.authorization_details ?? null))}</dd>
        <dt>refresh token</dt><dd data-testid="rar-refresh-token">${escapeHtml(refreshed?.refresh_token ?? '')}</dd>
        <dt>introspection active</dt><dd data-testid="rar-introspection-active">${escapeHtml(String(introspected.active))}</dd>
        <dt>introspection details</dt><dd data-testid="rar-introspection-details">${escapeHtml(JSON.stringify(introspected.authorization_details ?? null))}</dd>
      </dl>
    </main>
  </body>
</html>`);
}
```

## References

- [RFC 9396: OAuth 2.0 Rich Authorization Requests](https://datatracker.ietf.org/doc/html/rfc9396)
- the specification task set (specification / understanding-guide / sources / review-log): `tasks/experimental/done/rar/`
- the user-facing documentation in the OSS repository: `docs/library-document/src/content/docs/experimental/rar.md`
- the change memo in the OSS repository: `apps/map/changes/rar.md`
- Japanese version: [rar.ja.md](./rar.ja.md)
