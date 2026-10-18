# JARM (JWT Secured Authorization Response Mode): Implementation Guide

This document explains what was implemented for **JARM** (JWT Secured Authorization Response Mode for OAuth 2.0, OpenID Foundation Final Specification of 2022-11-09) in `packages/experimental`, and how, together with the complete source code involved.

The following code is embedded in full:

- all three implementation files and both test files under `packages/experimental/src/jarm/`
- the complete code that `--enable jarm` adds to the CLI-generated output (hono)
- the complete JARM E2E test spec

The core package itself, the shared E2E harness, and the other frameworks' generated code are infrastructure shared by all features, so they are linked rather than embedded.
The embedded sources carry Japanese comments; the prose here conveys the same information.

## What the feature does

In a plain Authorization Code Flow, the authorization response returns `code` and `state` as bare query parameters on the redirect URL.
The response carries no issuer signature, so from the response alone a client cannot confirm that it really came from the intended OP, or that nothing was rewritten along the way.
The corresponding attacks are mix-up attacks (responses smuggled in from a different OP) and response-parameter tampering.

JARM wraps the entire authorization response in one signed JWT.
`code` and `state` become claims, joined by the issuer (`iss`), the audience (`aud`), and an expiry (`exp`), all signed with the OP's key.
The client verifies the signature against the JWKS before extracting the claims, giving it cryptographic assurance of the response's integrity, authenticity, addressee, and freshness.

The request-side entry point is the `response_mode` parameter, to which JARM adds four values: `query.jwt`, `fragment.jwt`, `form_post.jwt`, and `jwt`.
This OP implements `response_type=code` only, so it supports just `query.jwt` (and the shorthand `jwt`, which for the code flow is an alias of `query.jwt`).

```text
Client                                     OP
    │  GET /authorize?response_mode=query.jwt&…  │
    │ ─────────────────────────────────────────> │ authentication & consent as usual
    │                                            │ sign the response params into a JWT
    │  302 redirect_uri?response=<signed JWT>    │
    │ <───────────────────────────────────────── │
    │  (verify via JWKS → read code from claims)
```

### Use cases

- Verifying the response-integrity protection that FAPI-class profiles require, with your own client configuration
- Working out how a client should implement mix-up defenses (issuer verification of responses)
- Measuring the adoption cost and behavior of JARM where tamper-evident authorization responses are a requirement

### Scope and non-goals

The implementation covers:

- `response_mode` classification (`query.jwt` / `jwt` interpreted as JARM; other `.jwt` values reported as unsupported)
- response JWT generation with the JARM §2.1 claim structure (both success and error responses) and redirect URL assembly per §2.3.1
- a configurable response JWT lifetime, validated at startup against §2.1's recommended maximum (10 minutes)

The non-goals:

- `fragment.jwt` / `form_post.jwt` (§2.3.2 / §2.3.3): out of scope because this OP is code-flow-only
- response JWT encryption (JWE, §2.2)
- per-client `authorization_signed_response_alg` (§3): this OP has no per-client algorithm registry, so it is fixed to RS256, the §3 default

## Design approach

The feature consists of two implementation files plus the public API.

| File | Role |
|---|---|
| `response-mode.ts` | `response_mode` classification |
| `response-jwt.ts` | response JWT generation and redirect URL assembly |
| `index.ts` | public API re-exports, and the piggyback type for the auth transaction |

There are three load-bearing decisions.

First, classification returns a discriminated union rather than throwing.
The point where `unsupported-jwt-mode` can be detected (while interpreting parameters) and the point where it can become a redirectable error (once `redirect_uri` is settled) differ in the caller, so the timing of error conversion is left to generated code.
Ignoring non-`.jwt` values (`query`, `form_post`, and the rest) is equally deliberate: JARM is an extension that adds meaning only to `.jwt` values, so enabling it must not change how this OP has always ignored `response_mode` otherwise.

Second, signing is a self-contained compact JWS built on the Web Crypto API (`crypto.subtle.sign`).
Core contains code of the same kind, but as private low-level helpers, and the core-stays-untouched rule keeps them off limits.
Experimental features prefer independence over deduplication, so the duplication is accepted and the implementation stays inside the feature.

Third, the fact that "this transaction must be answered in JARM mode" is **piggybacked** onto core's `AuthTransaction`.
Core's interface is closed, so the experimental package defines the intersection type `JarmAuthTransactionFields` (a `jarmResponseMode` field).
The current generated code does not use that type: its `create-transaction` step records the response mode's name `query.jwt` in the `responseMode` field of `ResponseModeTransaction`, which the base `endpoints/authorize/response-mode.ts` defines.
This imposes a contract requirement on auth transaction store implementations: unknown fields must be persisted transparently.
A store that serializes the whole object as JSON satisfies it naturally; a store that copies an explicit field list would drop the marker and silently answer a JARM-requesting client with a plain query response.

## The implementation, file by file

### response-mode.ts (response_mode classification)

`resolveJarmResponseMode` takes the effective authorization request parameters (after Request Object merging) and returns a three-way discriminated union:

- `{ kind: 'jarm', mode: 'query.jwt' }` for `query.jwt` or `jwt` (§2.3.4 makes `jwt` synonymous with `query.jwt` in the code flow)
- `{ kind: 'plain' }` for absence, `query`, `form_post`, and any other non-`.jwt` value; behavior stays exactly as before
- `{ kind: 'unsupported-jwt-mode', requested: … }` for `.jwt`-suffixed values this OP does not support, such as `fragment.jwt`; the caller turns this into `invalid_request`

Comparison is case-sensitive (response_mode values are case-sensitive per OAuth 2.0 Multiple Response Type Encoding Practices §2.1).
The parameter is typed `object` so both core's `AuthorizationRequestParams` (an interface without an index signature) and a plain `Record<string, string>` can be passed as-is; non-string values (a framework query parser returning an array, say) are not interpreted and fall back to plain.

```typescript
/**
 * JWT Secured Authorization Response Mode (JARM) — response_mode interpretation.
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * JARM §2.3 は `query.jwt` / `fragment.jwt` / `form_post.jwt` / `jwt` の 4 値を
 * `response_mode` に追加する。この OP は `response_type=code` 専用なので
 * `query.jwt`（と §2.3.4 でその別名になる `jwt`）だけを実装する。
 */

/** JARM モードとして解釈するリクエスト値（JARM §2.3.1 / §2.3.4）。 */
export const JARM_SUPPORTED_RESPONSE_MODES = ['query.jwt', 'jwt'] as const;

/** 応答 JWT を運ぶクエリパラメータ名（JARM §2.3.1）。他の名前は使わない。 */
export const JARM_RESPONSE_PARAM = 'response';

/**
 * `response_mode` の分類結果。
 *
 * 例外ではなく判別共用体を返すのは、`unsupported-jwt-mode` を検出できる時点
 * （パラメータ解釈時）と、それをリダイレクト可能エラーにできる時点
 * （redirect_uri 確定後）が呼び出し側で異なるため。エラー化は生成コードが
 * core の `AuthorizationError('invalid_request', ...)` で行う。
 */
export type JarmResponseModeResolution =
  /** JARM モード。応答を JWT 化し `response` パラメータで返す。 */
  | { kind: 'jarm'; mode: 'query.jwt' }
  /** 従来どおりの平文クエリ応答。挙動は一切変わらない。 */
  | { kind: 'plain' }
  /** 本 OP が対応しない `.jwt` 系モード。呼び出し側が invalid_request にする。 */
  | { kind: 'unsupported-jwt-mode'; requested: string };

/**
 * 認可リクエストの `response_mode` を JARM の観点で分類する。
 *
 * - `query.jwt` / `jwt` → JARM モード（§2.3.4: `response_type=code` の既定運搬は
 *   `query.jwt` なので、省略形 `jwt` は `query.jwt` と同義）
 * - 未指定 / `query` / `form_post` / `fragment` / その他の非 `.jwt` 値 → 従来どおり
 *   無視する（隔離原則。JARM は `.jwt` 系にだけ意味を足す拡張であり、この OP が
 *   今まで response_mode を無視してきた挙動を JARM 有効化で変えない）
 * - `fragment.jwt` / `form_post.jwt` / その他の `.jwt` 終端値 → 非対応として報告
 *
 * 値の比較は大文字小文字を区別する（OAuth 2.0 Multiple Response Type Encoding
 * Practices §2.1 の response_mode 値は case-sensitive）。
 *
 * @param params 認可リクエストの実効パラメータ（Request Object マージ後）。
 *   `response_mode` 以外のキーは参照しない。
 */
export function resolveJarmResponseMode(params: object): JarmResponseModeResolution {
  // 引数を `object` で受けるのは、core の `AuthorizationRequestParams`（index
  // signature を持たない interface）と素の `Record<string, string>` の双方を
  // そのまま渡せるようにするため。値が文字列でない場合（フレームワークの
  // クエリパーサが配列を返す等）は解釈せず plain として扱う。
  const responseMode = (params as { response_mode?: unknown })['response_mode'];
  if (typeof responseMode !== 'string') {
    return { kind: 'plain' };
  }
  if ((JARM_SUPPORTED_RESPONSE_MODES as readonly string[]).includes(responseMode)) {
    return { kind: 'jarm', mode: 'query.jwt' };
  }
  if (responseMode.endsWith('.jwt')) {
    return { kind: 'unsupported-jwt-mode', requested: responseMode };
  }
  return { kind: 'plain' };
}
```

### response-jwt.ts (response JWT generation)

`createJarmResponseJwt` builds the signed JWT with the JARM §2.1 claim structure.

- The JOSE header is `{ alg: 'RS256', kid }`. JARM does not specify a `typ` for the response JWT and §2.3.1's example header has none, so none is added
- The payload is the response parameters (`code` / `state`, or the error family) plus the §2.1-required `iss` / `aud` / `exp`
- Parameters whose value is `undefined` never become claims; a request without `state` produces a JWT without a `state` claim, exactly as §2.1 requires

Note the single line where `iss` / `aud` / `exp` are assigned after the response parameters.
These are the OP's own assertions, and the assignment order is what guarantees a same-named parameter from upstream can never restate them.

The signing algorithm is fixed to RS256 because §3 makes RS256 the default for a client that registered no `authorization_signed_response_alg`, and this OP has no per-client algorithm registry.
The flip side of fixing it: the `signingKey` passed in must be an RS256 key.
RFC 7515 §4.1.1 defines `alg` as the assertion of which algorithm signed this JWS, so stamping `alg: RS256` on a JWS signed with a different key type is not permitted.
In practice, Web Crypto throws on a key/algorithm mismatch, so such a JWS can never be produced; what fails is the signing operation itself, not the verifier.
Generated code selects the key with `selectSigningKeyByAlg(keys, 'RS256')` from the registered key set (the active key carries no guarantee of satisfying this contract).

`buildJarmRedirectUrl` attaches only the `response` parameter (§2.3.1) to the redirect URL.
Bare `code` / `state` / `iss` are never attached; issuer identification is the JWT's `iss` claim's job.

`assertJarmLifetimeSeconds` validates the lifetime setting (an integer between 5 and 600 seconds) at startup; generated code calls it right after declaring `jarmConfig`.

```typescript
/**
 * JWT Secured Authorization Response Mode (JARM) — response JWT generation.
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * JARM §2.1 のクレーム構造で認可レスポンスを署名付き JWT にする。署名は Web
 * Crypto API（`crypto.subtle.sign`）で compact JWS を組み立てる自前実装であり、
 * core の非公開な低レベル署名ヘルパーには依存しない（core 無変更の維持）。
 * core 内部と同種のコードになるが、Experimental 機能は独立性を優先して重複を
 * 許容する方針に従う。
 */
import type { SigningKey } from '@maronn-openid-connect/core';

/** 応答 JWT の寿命の下限（秒）。 */
const MIN_LIFETIME_SECONDS = 5;

/**
 * 応答 JWT の寿命の上限（秒）。
 *
 * JARM §2.1: "The JWT MUST have an expiration time ... A maximum lifetime of 10
 * minutes is RECOMMENDED."
 */
const MAX_LIFETIME_SECONDS = 600;

/** 設定が省略されたときの寿命（秒）。 */
const DEFAULT_LIFETIME_SECONDS = 60;

/**
 * 応答 JWT の署名アルゴリズム。
 *
 * JARM §3: クライアントが `authorization_signed_response_alg` を登録していない
 * 場合の既定は RS256。この OP はクライアント別 alg を持たないため RS256 固定と
 * する。設定で変更できないので、クライアントが §2.4 で拒否する `alg: none` を
 * この OP が生成することはない。
 *
 * 固定であることの裏返しとして、{@link createJarmResponseJwt} に渡す `signingKey`
 * は **RS256 鍵でなければならない**。RFC 7515 §4.1.1 の `alg` は「この JWS が
 * どのアルゴリズムで署名されたか」の表明であり、別種の鍵で署名した JWS に
 * `alg: RS256` を付けることは許されない。実際には Web Crypto が鍵と
 * アルゴリズムの不一致で例外を投げるため、そのような JWS が生成されることは
 * ない（署名偽造の余地は無く、失敗するのは署名処理そのもの）。
 */
const RESPONSE_SIGNING_ALG = 'RS256';

/** RS256 に対応する Web Crypto のアルゴリズム名。 */
const WEB_CRYPTO_ALGORITHM = 'RSASSA-PKCS1-v1_5';

function base64UrlFromBytes(bytes: Uint8Array): string {
  let binary = '';
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function base64UrlFromJson(value: Record<string, unknown>): string {
  return base64UrlFromBytes(new TextEncoder().encode(JSON.stringify(value)));
}

/**
 * 応答 JWT の寿命設定を起動時に検証する（JARM §2.1）。
 *
 * 生成コードは `jarmConfig` の宣言直後にこれを呼び、範囲外の設定を持つ OP が
 * 起動できないようにする。
 *
 * @throws {Error} 5〜600 秒の整数でない場合
 */
export function assertJarmLifetimeSeconds(value: number): void {
  if (
    !Number.isInteger(value) ||
    value < MIN_LIFETIME_SECONDS ||
    value > MAX_LIFETIME_SECONDS
  ) {
    throw new Error(
      `jarmConfig.jarmResponseLifetimeSeconds must be an integer between ${MIN_LIFETIME_SECONDS} and ${MAX_LIFETIME_SECONDS} seconds (JARM Section 2.1), got ${value}`,
    );
  }
}

/**
 * 認可レスポンスパラメータを JARM §2.1 のクレーム構造で署名付き JWT にする。
 *
 * - JOSE ヘッダー: `{ alg: 'RS256', kid: signingKey.keyId }`。JARM は応答 JWT の
 *   `typ` を規定しておらず §2.3.1 の実例ヘッダーにも無いため付けない。
 * - ペイロード: `iss` / `aud` / `exp`（いずれも §2.1 で REQUIRED）＋ 応答パラメータ。
 *   値が `undefined` のパラメータはクレームに含めない（`state` が無いリクエスト
 *   では `state` クレーム自体が存在しない、という §2.1 の要求の実現）。
 * - `iss` / `aud` / `exp` は `parameters` から上書きできない。これらは OP 自身の
 *   表明であり、上流から渡った値で書き換えられてはならない。
 *
 * `error_description` を渡す場合は、呼び出し側が core の
 * `sanitizeErrorDescription` を通した文字列を渡すこと。
 *
 * @param options.issuer `iss` クレーム（OP の issuer）
 * @param options.clientId `aud` クレーム（応答先クライアント）
 * @param options.parameters 認可レスポンスパラメータ（code/state または error 系）
 * @param options.signingKey 応答 JWT の署名鍵。**RS256 鍵であること**（JOSE ヘッダの
 *   `alg` は常に RS256 固定なので、他の alg の鍵を渡すと Web Crypto が署名を拒否して
 *   例外になる）。生成コードは登録鍵セットから `selectSigningKeyByAlg(keys, 'RS256')`
 *   で選ぶこと。active key はこの契約を満たす保証がない。
 * @param options.lifetimeSeconds `exp` までの秒数（既定 60）
 * @param options.now 発行時刻（テスト用の注入点。既定は現在時刻）
 */
export async function createJarmResponseJwt(options: {
  issuer: string;
  clientId: string;
  parameters: Record<string, string | undefined>;
  signingKey: SigningKey;
  lifetimeSeconds?: number;
  now?: Date;
}): Promise<string> {
  const lifetimeSeconds = options.lifetimeSeconds ?? DEFAULT_LIFETIME_SECONDS;
  const issuedAtSeconds = Math.floor((options.now ?? new Date()).getTime() / 1000);

  const claims: Record<string, string | number> = {};
  for (const [name, value] of Object.entries(options.parameters)) {
    if (value !== undefined) {
      claims[name] = value;
    }
  }
  // JARM §2.1: iss / aud / exp are REQUIRED. Assigned after the response
  // parameters so a parameter of the same name can never restate them.
  claims['iss'] = options.issuer;
  claims['aud'] = options.clientId;
  claims['exp'] = issuedAtSeconds + lifetimeSeconds;

  const encodedHeader = base64UrlFromJson({
    alg: RESPONSE_SIGNING_ALG,
    kid: options.signingKey.keyId,
  });
  const encodedPayload = base64UrlFromJson(claims);
  const signingInput = `${encodedHeader}.${encodedPayload}`;

  const signature = await crypto.subtle.sign(
    WEB_CRYPTO_ALGORITHM,
    options.signingKey.privateKey,
    new TextEncoder().encode(signingInput),
  );

  return `${signingInput}.${base64UrlFromBytes(new Uint8Array(signature))}`;
}

/**
 * JARM モードのリダイレクト URL を組み立てる（JARM §2.3.1）。
 *
 * 付与するのは `response` パラメータのみ。素の `code` / `state` / `iss` は付けない
 * （issuer 識別は JWT の `iss` クレームが担う）。
 */
export function buildJarmRedirectUrl(redirectUri: string, responseJwt: string): string {
  const url = new URL(redirectUri);
  url.searchParams.set('response', responseJwt);
  return url.toString();
}
```

### index.ts (public API and the transaction piggyback type)

The substance of the subpath export `@maronn-openid-connect/experimental/jarm`.
The JSDoc of `JarmAuthTransactionFields` records the contract requirement on auth transaction stores (transparent persistence of unknown fields).

```typescript
/**
 * JWT Secured Authorization Response Mode (JARM) — OpenID Foundation Final
 * Specification (2022-11-09)
 *
 * **Experimental**: この機能の API は安定していない。マイナーリリースでも
 * 破壊的に変更されることがある。本番運用の前に
 * `docs/library-document` の Experimental セクションを確認すること。
 *
 * `@maronn-openid-connect/core` とは別 package であり、CLI で `--enable jarm` を
 * 明示したときのみ生成コードから利用される。
 *
 * 初期スコープは `query.jwt`（と省略形 `jwt`）の**署名のみ**に限定する。
 * `fragment.jwt` / `form_post.jwt`（§2.3.2 / §2.3.3）・応答 JWT の暗号化（JWE,
 * §2.2）・クライアント別 `authorization_signed_response_alg`（§3）は非対応。
 */
export {
  JARM_RESPONSE_PARAM,
  JARM_SUPPORTED_RESPONSE_MODES,
  resolveJarmResponseMode,
  type JarmResponseModeResolution,
} from './response-mode.js';

export {
  assertJarmLifetimeSeconds,
  buildJarmRedirectUrl,
  createJarmResponseJwt,
} from './response-jwt.js';

/**
 * core の `AuthTransaction`（closed interface）に JARM モードを相乗りさせるための
 * 交差型。
 *
 * 生成コードは transaction を store へ put するときに
 * `{ ...transaction, jarmResponseMode: 'query.jwt' }` を保存し、get 後にこの型
 * として読む。**auth transaction store の実装は未知フィールドを透過的に保存する
 * 必要がある**（契約要件。オブジェクトを丸ごと JSON 化する通常の実装なら自然に
 * 満たされる。フィールドを列挙してコピーする実装ではこの記録が失われ、JARM を
 * 要求したクライアントへ静かに平文クエリで応答してしまう）。
 */
export type JarmAuthTransactionFields = {
  /** JARM モードで応答すべきトランザクションであることの記録。無指定は平文応答。 */
  jarmResponseMode?: 'query.jwt';
};
```

## The unit tests, in full

`response-mode.test.ts` pins down every classification path:

- `query.jwt` and `jwt` classified as JARM mode
- absence, `query`, `form_post`, `fragment`, other non-`.jwt` values, and non-string values classified as plain
- case variants like `QUERY.JWT` not classified as JARM (case sensitivity)
- `.jwt`-suffixed values like `fragment.jwt` / `form_post.jwt` reported as `unsupported-jwt-mode`

```typescript
import { describe, expect, it } from 'vitest';
import { JARM_SUPPORTED_RESPONSE_MODES, resolveJarmResponseMode } from './response-mode.js';

describe('resolveJarmResponseMode', () => {
  // JARM §2.3.1 / §2.3.4: query.jwt is the only mode this OP implements, and the
  // shorthand `jwt` resolves to it for response_type=code.
  describe('JARM modes', () => {
    it('should resolve response_mode=query.jwt to the query.jwt JARM mode', () => {
      expect(resolveJarmResponseMode({ response_mode: 'query.jwt' })).toEqual({
        kind: 'jarm',
        mode: 'query.jwt',
      });
    });

    it('should resolve the shorthand response_mode=jwt to the query.jwt JARM mode', () => {
      expect(resolveJarmResponseMode({ response_mode: 'jwt' })).toEqual({
        kind: 'jarm',
        mode: 'query.jwt',
      });
    });
  });

  // The generated OP does not interpret response_mode at all today. JARM only
  // adds meaning to the `.jwt` family; every other value keeps the current
  // (ignore it) behavior so enabling the feature changes nothing else.
  describe('Plain (unchanged) modes', () => {
    it('should resolve an absent response_mode to plain', () => {
      expect(resolveJarmResponseMode({})).toEqual({ kind: 'plain' });
    });

    it('should resolve an explicitly undefined response_mode to plain', () => {
      expect(resolveJarmResponseMode({ response_mode: undefined })).toEqual({ kind: 'plain' });
    });

    it('should resolve response_mode=query to plain', () => {
      expect(resolveJarmResponseMode({ response_mode: 'query' })).toEqual({ kind: 'plain' });
    });

    it('should resolve response_mode=form_post to plain', () => {
      expect(resolveJarmResponseMode({ response_mode: 'form_post' })).toEqual({ kind: 'plain' });
    });

    it('should resolve response_mode=fragment to plain', () => {
      expect(resolveJarmResponseMode({ response_mode: 'fragment' })).toEqual({ kind: 'plain' });
    });

    // フレームワークのクエリパーサが文字列以外（配列など）を返す場合でも、
    // JARM モードとして解釈しない。
    it('should resolve a non-string response_mode to plain', () => {
      expect(resolveJarmResponseMode({ response_mode: 42 } as object)).toEqual({ kind: 'plain' });
    });

    it('should resolve an empty response_mode to plain', () => {
      expect(resolveJarmResponseMode({ response_mode: '' })).toEqual({ kind: 'plain' });
    });

    // response_mode values are case-sensitive (OAuth 2.0 Multiple Response Type
    // Encoding Practices §2.1), so QUERY.JWT is not the JARM mode.
    it('should resolve an uppercase QUERY.JWT to plain', () => {
      expect(resolveJarmResponseMode({ response_mode: 'QUERY.JWT' })).toEqual({ kind: 'plain' });
    });
  });

  // JARM §2.3.2 / §2.3.3: fragment.jwt and form_post.jwt exist in the spec but
  // are non-goals here, so they are reported to the caller which turns them into
  // a redirectable invalid_request.
  describe('Unsupported JWT modes', () => {
    it('should report fragment.jwt as an unsupported JWT mode', () => {
      expect(resolveJarmResponseMode({ response_mode: 'fragment.jwt' })).toEqual({
        kind: 'unsupported-jwt-mode',
        requested: 'fragment.jwt',
      });
    });

    it('should report form_post.jwt as an unsupported JWT mode', () => {
      expect(resolveJarmResponseMode({ response_mode: 'form_post.jwt' })).toEqual({
        kind: 'unsupported-jwt-mode',
        requested: 'form_post.jwt',
      });
    });

    it('should report an unknown .jwt value as an unsupported JWT mode', () => {
      expect(resolveJarmResponseMode({ response_mode: 'foo.jwt' })).toEqual({
        kind: 'unsupported-jwt-mode',
        requested: 'foo.jwt',
      });
    });

    it('should report a bare .jwt value as an unsupported JWT mode', () => {
      expect(resolveJarmResponseMode({ response_mode: '.jwt' })).toEqual({
        kind: 'unsupported-jwt-mode',
        requested: '.jwt',
      });
    });
  });
});

describe('JARM_SUPPORTED_RESPONSE_MODES', () => {
  it('should list exactly the request values that select JARM', () => {
    expect(JARM_SUPPORTED_RESPONSE_MODES).toEqual(['query.jwt', 'jwt']);
  });
});
```

`response-jwt.test.ts` pins down JWT generation while actually verifying signatures:

- the JOSE header shape (`alg: RS256`, `kid`, no `typ`)
- success-response claims (`code` / `state` / `iss` / `aud` / `exp`, absence of `undefined` parameters, `iss` / `aud` / `exp` not overridable from parameters, the `exp` computation)
- error-response claims (`error` / `error_description`, no `code` claim)
- signature verifiability with the public key, and failure with a different key
- redirect URL assembly (only the `response` parameter added; existing query preserved)
- lifetime boundary values (5 and 600 accepted; out-of-range and non-integers rejected)

```typescript
import type { SigningKey } from '@maronn-openid-connect/core';
import { beforeAll, describe, expect, it } from 'vitest';
import {
  assertJarmLifetimeSeconds,
  buildJarmRedirectUrl,
  createJarmResponseJwt,
} from './response-jwt.js';

function decodeSegment(segment: string): Record<string, unknown> {
  const base64 = segment.replace(/-/g, '+').replace(/_/g, '/');
  const padded = base64.padEnd(base64.length + ((4 - (base64.length % 4)) % 4), '=');
  const bytes = Uint8Array.from(atob(padded), (char) => char.charCodeAt(0));
  return JSON.parse(new TextDecoder().decode(bytes)) as Record<string, unknown>;
}

function header(jwt: string): Record<string, unknown> {
  return decodeSegment(jwt.split('.')[0] ?? '');
}

function payload(jwt: string): Record<string, unknown> {
  return decodeSegment(jwt.split('.')[1] ?? '');
}

function signatureBytes(jwt: string): Uint8Array {
  const segment = jwt.split('.')[2] ?? '';
  const base64 = segment.replace(/-/g, '+').replace(/_/g, '/');
  const padded = base64.padEnd(base64.length + ((4 - (base64.length % 4)) % 4), '=');
  return Uint8Array.from(atob(padded), (char) => char.charCodeAt(0));
}

// 2026-08-04T00:00:00Z. Injected so every exp assertion is a fixed value.
const NOW = new Date('2026-08-04T00:00:00.000Z');
const NOW_SECONDS = 1785801600;

let signingKey: SigningKey;
let publicKey: CryptoKey;

beforeAll(async () => {
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
  const publicJwk = await crypto.subtle.exportKey('jwk', keyPair.publicKey);
  signingKey = { privateKey: keyPair.privateKey, publicJwk, keyId: 'jarm-key-1' };
  publicKey = keyPair.publicKey;
});

describe('createJarmResponseJwt', () => {
  describe('JOSE Header', () => {
    // JARM §2.2 / §3: the OP signs with RS256 (the default when the client
    // registered no authorization_signed_response_alg). alg is not configurable,
    // so `none` (rejected by clients per §2.4) can never be produced.
    it('should set alg to RS256 and kid to the signing key id without a typ header', async () => {
      const jwt = await createJarmResponseJwt({
        issuer: 'http://localhost:3000',
        clientId: 'my-client',
        parameters: { code: 'auth-code-1' },
        signingKey,
        now: NOW,
      });

      expect(header(jwt)).toEqual({ alg: 'RS256', kid: 'jarm-key-1' });
    });
  });

  describe('Success response claims', () => {
    // JARM §2.1: iss / aud / exp are REQUIRED, and the authorization response
    // parameters travel as claims of the same JWT.
    it('should carry iss, aud, exp, code and state as claims', async () => {
      const jwt = await createJarmResponseJwt({
        issuer: 'http://localhost:3000',
        clientId: 'my-client',
        parameters: { code: 'auth-code-1', state: 'S8NJ7' },
        signingKey,
        now: NOW,
      });

      expect(payload(jwt)).toEqual({
        iss: 'http://localhost:3000',
        aud: 'my-client',
        exp: NOW_SECONDS + 60,
        code: 'auth-code-1',
        state: 'S8NJ7',
      });
    });

    // JARM §2.1: state is present in the response only when the request had one.
    it('should omit the state claim entirely when state is undefined', async () => {
      const jwt = await createJarmResponseJwt({
        issuer: 'http://localhost:3000',
        clientId: 'my-client',
        parameters: { code: 'auth-code-1', state: undefined },
        signingKey,
        now: NOW,
      });

      expect(payload(jwt)).toEqual({
        iss: 'http://localhost:3000',
        aud: 'my-client',
        exp: NOW_SECONDS + 60,
        code: 'auth-code-1',
      });
    });

    it('should default the response JWT lifetime to 60 seconds', async () => {
      const jwt = await createJarmResponseJwt({
        issuer: 'http://localhost:3000',
        clientId: 'my-client',
        parameters: { code: 'auth-code-1' },
        signingKey,
        now: NOW,
      });

      expect(payload(jwt)['exp']).toBe(NOW_SECONDS + 60);
    });

    it('should set exp to now plus the requested lifetime', async () => {
      const jwt = await createJarmResponseJwt({
        issuer: 'http://localhost:3000',
        clientId: 'my-client',
        parameters: { code: 'auth-code-1' },
        signingKey,
        lifetimeSeconds: 600,
        now: NOW,
      });

      expect(payload(jwt)['exp']).toBe(NOW_SECONDS + 600);
    });

    // Sub-second precision must not leak into exp: JWT NumericDate is seconds.
    it('should floor exp to whole seconds', async () => {
      const jwt = await createJarmResponseJwt({
        issuer: 'http://localhost:3000',
        clientId: 'my-client',
        parameters: { code: 'auth-code-1' },
        signingKey,
        now: new Date(NOW.getTime() + 999),
      });

      expect(payload(jwt)['exp']).toBe(NOW_SECONDS + 60);
    });

    // The protocol claims are the OP's own statement about the response. A
    // caller-supplied parameter of the same name must not be able to restate it.
    it('should keep iss, aud and exp non-overridable by response parameters', async () => {
      const jwt = await createJarmResponseJwt({
        issuer: 'http://localhost:3000',
        clientId: 'my-client',
        parameters: {
          code: 'auth-code-1',
          iss: 'https://evil.example',
          aud: 'other-client',
          exp: '9999999999',
        },
        signingKey,
        now: NOW,
      });

      expect(payload(jwt)).toEqual({
        iss: 'http://localhost:3000',
        aud: 'my-client',
        exp: NOW_SECONDS + 60,
        code: 'auth-code-1',
      });
    });
  });

  describe('Error response claims', () => {
    // JARM §2.1 error example: the error response is the same JWT shape with
    // error / error_description / state instead of code.
    it('should carry error, error_description and state as claims', async () => {
      const jwt = await createJarmResponseJwt({
        issuer: 'http://localhost:3000',
        clientId: 'my-client',
        parameters: {
          error: 'access_denied',
          error_description: 'User denied the request',
          state: 'S8NJ7',
        },
        signingKey,
        now: NOW,
      });

      expect(payload(jwt)).toEqual({
        iss: 'http://localhost:3000',
        aud: 'my-client',
        exp: NOW_SECONDS + 60,
        error: 'access_denied',
        error_description: 'User denied the request',
        state: 'S8NJ7',
      });
    });

    it('should omit error_description when it is undefined', async () => {
      const jwt = await createJarmResponseJwt({
        issuer: 'http://localhost:3000',
        clientId: 'my-client',
        parameters: {
          error: 'access_denied',
          error_description: undefined,
          state: 'S8NJ7',
        },
        signingKey,
        now: NOW,
      });

      expect(payload(jwt)).toEqual({
        iss: 'http://localhost:3000',
        aud: 'my-client',
        exp: NOW_SECONDS + 60,
        error: 'access_denied',
        state: 'S8NJ7',
      });
    });
  });

  describe('Signature', () => {
    // JARM §2.4: the client verifies the JWS with a key resolved from the OP's
    // jwks_uri via kid. The compact serialization must therefore verify against
    // the public half of the signing key.
    it('should produce a compact JWS that verifies with the signing key public half', async () => {
      const jwt = await createJarmResponseJwt({
        issuer: 'http://localhost:3000',
        clientId: 'my-client',
        parameters: { code: 'auth-code-1', state: 'S8NJ7' },
        signingKey,
        now: NOW,
      });
      const [encodedHeader, encodedPayload] = jwt.split('.');
      const verified = await crypto.subtle.verify(
        'RSASSA-PKCS1-v1_5',
        publicKey,
        signatureBytes(jwt),
        new TextEncoder().encode(`${encodedHeader}.${encodedPayload}`),
      );

      expect(verified).toBe(true);
    });

    it('should produce exactly three base64url segments', async () => {
      const jwt = await createJarmResponseJwt({
        issuer: 'http://localhost:3000',
        clientId: 'my-client',
        parameters: { code: 'auth-code-1' },
        signingKey,
        now: NOW,
      });

      expect(jwt.split('.')).toHaveLength(3);
      expect(/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(jwt)).toBe(true);
    });

    // JARM §3 / RFC 7515 §4.1.1: this function always declares `alg: RS256`, so
    // the JOSE header would lie about the signature if it accepted another key
    // type. Web Crypto refuses to sign with a mismatched key, which is what pins
    // the contract "signingKey MUST be an RS256 key" — the caller (the CLI
    // generated code) is responsible for selecting one.
    it('should reject an ES256 signing key instead of signing under the RS256 header', async () => {
      const ecdsaKeyPair = await crypto.subtle.generateKey(
        { name: 'ECDSA', namedCurve: 'P-256' },
        true,
        ['sign', 'verify'],
      );
      const ecdsaPublicJwk = await crypto.subtle.exportKey('jwk', ecdsaKeyPair.publicKey);

      await expect(
        createJarmResponseJwt({
          issuer: 'http://localhost:3000',
          clientId: 'my-client',
          parameters: { code: 'auth-code-1' },
          signingKey: {
            privateKey: ecdsaKeyPair.privateKey,
            publicJwk: ecdsaPublicJwk,
            keyId: 'es256-key',
          },
          now: NOW,
        }),
      ).rejects.toThrow();
    });

    // Non-ASCII claim values must survive as UTF-8 before base64url encoding.
    it('should encode non-ASCII claim values as UTF-8', async () => {
      const jwt = await createJarmResponseJwt({
        issuer: 'http://localhost:3000',
        clientId: 'クライアント',
        parameters: { code: 'auth-code-1' },
        signingKey,
        now: NOW,
      });

      expect(payload(jwt)['aud']).toBe('クライアント');
    });
  });
});

describe('buildJarmRedirectUrl', () => {
  // JARM §2.3.1: the response is delivered as the single `response` query
  // parameter. No plain code / state / iss parameter is added.
  it('should append only the response parameter to the redirect URI', () => {
    expect(buildJarmRedirectUrl('https://client.example.com/cb', 'header.payload.signature')).toBe(
      'https://client.example.com/cb?response=header.payload.signature',
    );
  });

  it('should preserve query parameters already present on the redirect URI', () => {
    expect(buildJarmRedirectUrl('https://client.example.com/cb?tenant=a', 'a.b.c')).toBe(
      'https://client.example.com/cb?tenant=a&response=a.b.c',
    );
  });

  it('should replace an existing response parameter instead of appending a second one', () => {
    expect(buildJarmRedirectUrl('https://client.example.com/cb?response=stale', 'a.b.c')).toBe(
      'https://client.example.com/cb?response=a.b.c',
    );
  });
});

describe('assertJarmLifetimeSeconds', () => {
  // JARM §2.1: "The JWT MUST have an expiration time (exp) ... a maximum
  // lifetime of 10 minutes is RECOMMENDED."
  describe('Accepted values', () => {
    it('should accept the lower bound of 5 seconds', () => {
      expect(() => assertJarmLifetimeSeconds(5)).not.toThrow();
    });

    it('should accept the upper bound of 600 seconds', () => {
      expect(() => assertJarmLifetimeSeconds(600)).not.toThrow();
    });

    it('should accept the default of 60 seconds', () => {
      expect(() => assertJarmLifetimeSeconds(60)).not.toThrow();
    });
  });

  describe('Rejected values', () => {
    it('should reject 4 seconds as below the lower bound', () => {
      expect(() => assertJarmLifetimeSeconds(4)).toThrow(
        'jarmConfig.jarmResponseLifetimeSeconds must be an integer between 5 and 600 seconds (JARM Section 2.1), got 4',
      );
    });

    it('should reject 601 seconds as above the upper bound', () => {
      expect(() => assertJarmLifetimeSeconds(601)).toThrow(
        'jarmConfig.jarmResponseLifetimeSeconds must be an integer between 5 and 600 seconds (JARM Section 2.1), got 601',
      );
    });

    it('should reject a non-integer lifetime', () => {
      expect(() => assertJarmLifetimeSeconds(60.5)).toThrow(
        'jarmConfig.jarmResponseLifetimeSeconds must be an integer between 5 and 600 seconds (JARM Section 2.1), got 60.5',
      );
    });

    it('should reject NaN', () => {
      expect(() => assertJarmLifetimeSeconds(Number.NaN)).toThrow(
        'jarmConfig.jarmResponseLifetimeSeconds must be an integer between 5 and 600 seconds (JARM Section 2.1), got NaN',
      );
    });
  });
});
```

## CLI integration and the generated-code contribution

The experimental package is the logic layer; it is CLI-generated code that actually answers an authorization request with a response JWT.
That code is extracted by the CLI from `src/oidc-provider/` of [apps/hono](../../../apps/hono), an app that runs with every feature enabled.
Running `maronn-oidc generate <framework> --enable jarm` adds three things to the generated code:

- **the directory `features/jarm/`**: every file JARM owns. Its `feature.ts` declares the feature with `defineFeature()`: the `authorize.responseModes` hook lets `/consent` restore the `query.jwt` response mode, and the `discovery` hook adds `query.jwt` and `jwt` to `response_modes_supported` and `RS256` to `authorization_signing_alg_values_supported`. It has no `routes`, so no HTTP route appears; JARM changes how the response travels, not which endpoints exist
- **two lines of `features/enabled.ts`**: the import of `jarm` and its entry in the list `features`
- **one owner block in `endpoints/authorize/pipeline.ts`**: the `[resolve-jarm-response-mode]` block interprets `response_mode` between the base `[resolve-redirect-uri]` and `[validate-request]` blocks, and sets the response mode `responseMode` for a request that asks for a JWT response. The import of the step it calls is added at the top of that file

Hooks carry declarative values that the base reads at fixed places: routes, metadata, response-mode handlers.
Logic that runs in the middle of a base pipeline is not a hook; it sits in that pipeline as a block that starts with a marker comment naming the feature.
The marker comment starts with `// [step-id] (feature: <feature-id>)`, and the block runs to the line before the next marker.
Such a block is called an **owner block**.
When the provider is generated without `--enable jarm`, the CLI deletes the JARM block and the imports only that block used.
The base declares `responseMode` with `let` outside the `try`, so without the block it stays `undefined` (the plain query response), and the later steps and the `catch` can still read it.

The response travels as follows.
At `GET /authorize`, the JARM block sets `responseMode` right after the base `endpoints/authorize/pipeline.ts` has settled `redirect_uri`.
`[create-transaction]` records its name (`query.jwt`) on the transaction, and the steps that answer on the spot (prompt=none, SSO, errors) build the response JWT with `responseMode.redirect()`.
A response that goes through login and consent is sent by another request, so the `[build-authorization-response]` step of `/consent` restores the response mode from the transaction's record with `restoreResponseMode()` of `endpoints/authorize/response-mode.ts`, and answers success and denial alike as a JWT.
At discovery, `discoveryOf()` of `features/feature.ts` merges the arrays of the JARM `discovery` hook into those of the base, so `response_modes_supported` becomes `query`, `query.jwt`, `jwt`.

Three design decisions shape this layout.

First, interpreting `response_mode` is an owner block because the specification decides where it must run.
Rejecting an unsupported `.jwt` mode (`fragment.jwt`, `form_post.jwt`) is an error returned by redirect, so it must come after `redirect_uri` is settled.
It must also come before `[create-transaction]`, or nothing is recorded, and placing it before `[validate-request]` makes validation errors travel as a JWT too.
The rejection thrown inside the block itself goes back as a plain query response, because `responseMode` is not set yet (the OP cannot answer in a response mode it does not implement).

Second, restoring the mode at `/consent` is a hook because a response that goes through the consent screen is sent by another request.
Local variables of the authorization pipeline never reach `/consent`, so the mode is handed over as a name recorded on the transaction plus a handler that rebuilds the mode from the name.
`restoreResponseMode()` looks among the handlers of the enabled features for one that knows the recorded name and throws when none does, so `/consent` fails with a 500 error.
An OP from which JARM was removed after the transaction was created therefore never answers a client that asked for a JWT with a silent plain query response.

Third, the signing key is not the first key of `signingKeys`; `selectJarmSigningKey()` picks the RS256 key.
The response JWT always declares `alg` RS256 (the JARM §3 default), and discovery advertises only that, so `alg` and key agree even in a key set whose first key is ES256.
When no RS256 key is registered, `selectSigningKeyByAlg` throws, and the answer is a 500 error rather than an unverifiable JWT.

Among the samples, only [samples/hono-cloudflare](../../../samples/hono-cloudflare) enables this feature.
Its `src/oidc-provider/` shows the generated code combined with the other features.
The sample's `src/app.ts` leaves the JARM settings alone and runs with the generated defaults.

### The generated code in full (hono)

The following is everything JARM adds to the hono output generated with the default features plus `--enable jarm`.
For `features/enabled.ts` and the authorization endpoint's pipeline it shows the lines and the block that are added; for `features/jarm/` it shows every file in full, copied as generated.

#### The lines added to `features/enabled.ts`

`features/enabled.ts` lists the features of the OP.
The CLI writes one import and one entry of the array `features` for each enabled feature.
The order of the array is the order in which the hooks apply; JARM comes after the default features (`pkce` through `request-object`).

```typescript
import { jarm } from './jarm/feature.js';
```

```typescript
  jarm,
```

#### The `(feature: jarm)` block of `endpoints/authorize/pipeline.ts`

The authorization endpoint's pipeline imports the JARM step the block calls at the top of the file.

```typescript
import { resolveJarmResponseContext } from '../../features/jarm/steps/resolve-jarm-response-mode.js';
```

The block runs right after the `[resolve-redirect-uri]` block and right before the `[validate-request]` block.
It passes the parameters with any Request Object overlaid (`effectiveParams ?? params`), the settled `redirectUri` and `state`, and the issuer to `resolveJarmResponseContext()`, and assigns the returned mode to the base `responseMode`.
For a request that asks for no JWT response it returns `undefined`, and the response stays the plain query response.

```typescript
    // [resolve-jarm-response-mode] (feature: jarm) Interpret response_mode=query.jwt — JARM §2.3 / §3
    responseMode = resolveJarmResponseContext(c, effectiveParams ?? params, client, redirectUri, state, issuer);
```

#### `features/jarm/feature.ts`

This file declares what JARM plugs into the base, and it is the file `features/enabled.ts` imports.
`jarmResponseModeHandler`, listed in `authorize.responseModes`, rebuilds the response mode at `/consent` for a transaction that recorded `query.jwt`.
`discovery` returns the JARM §4 metadata; its `response_modes_supported` array is merged with the base `['query']`.
`authorization_signing_alg_values_supported` lists only `RS256` because the response JWT is always signed with RS256.
It has neither `routes` nor `context`.

```typescript
import { JARM_SUPPORTED_RESPONSE_MODES } from '@maronn-openid-connect/experimental/jarm';
import { defineFeature } from '../feature.js';
import { jarmResponseModeHandler } from './response-mode.js';

/**
 * EXPERIMENTAL — JWT Secured Authorization Response Mode (JARM, OpenID
 * Foundation Final 2022-11-09): response_mode=query.jwt (and its `jwt`
 * shorthand) returns the authorization response as one signed JWT. The
 * resolve-jarm-response-mode block of endpoints/authorize/pipeline.ts reads
 * the request, and /consent answers in the same mode through
 * authorize.responseModes. A request that does not ask for a JWT response
 * mode is answered exactly as before. Settings are in config.ts.
 *
 * Backed by @maronn-openid-connect/experimental, whose API is NOT stable: it
 * may change in a breaking way between releases.
 */
export const jarm = defineFeature({
  id: 'jarm',
  authorize: { responseModes: [jarmResponseModeHandler] },
  discovery: () => ({
    // JARM §4: the JWT-secured query modes are advertised alongside query.
    response_modes_supported: [...JARM_SUPPORTED_RESPONSE_MODES],
    // JARM §4 metadata. The response JWT is always signed with RS256 (JARM §3:
    // the default for a client that registered no
    // authorization_signed_response_alg), so exactly one alg is advertised.
    authorization_signing_alg_values_supported: ['RS256'],
  }),
});
```

#### `features/jarm/config.ts`

The JARM settings, which `response-mode.ts` reads for the lifetime of the response JWT.
`jarmResponseLifetimeSeconds` is the number of seconds until `exp`; the `assertJarmLifetimeSeconds` call at the end rejects a value outside 5 to 600 seconds at module load (JARM §2.1 recommends at most 10 minutes).
The JWT rides in a URL and only has to survive one browser redirect, so the default is 60 seconds.
The signing algorithm, the response parameter name and the supported response modes are not settings; the header comment states why each is fixed.

```typescript
/**
 * EXPERIMENTAL — JWT Secured Authorization Response Mode (JARM).
 *
 * This feature was generated because the OP was created with `--enable jarm`.
 * It is backed by @maronn-openid-connect/experimental, whose API is NOT stable: it may
 * change in a breaking way between releases. Do not build production code on it
 * without pinning the version.
 *
 * Read by the response mode of this feature (response-mode.ts), which the
 * authorize and consent endpoints answer in.
 *
 * - jarmResponseLifetimeSeconds: how long the response JWT stays valid (its
 *   `exp` claim). JARM Section 2.1 RECOMMENDs a maximum lifetime of 10 minutes,
 *   so values outside 5-600 seconds fail fast at module load. Keep it short: the
 *   JWT rides in a URL and only needs to survive one browser redirect.
 *
 * Not configurable: the signing algorithm (RS256, JARM Section 3's default for a
 * client with no registered authorization_signed_response_alg), the response
 * parameter name (`response`, JARM Section 2.3.1) and the supported response
 * modes (`query.jwt` / `jwt` — this OP implements response_type=code only, so
 * `fragment.jwt` and `form_post.jwt` are rejected with invalid_request).
 */
import { assertJarmLifetimeSeconds } from '@maronn-openid-connect/experimental/jarm';

export const jarmConfig = {
  jarmResponseLifetimeSeconds: 60,
};

assertJarmLifetimeSeconds(jarmConfig.jarmResponseLifetimeSeconds);
```

#### `features/jarm/response-mode.ts`

The JARM response mode itself.
`jarmResponseMode()` implements the base `AuthorizationResponseMode` by signing the authorization response parameters (`code` and `state`, or the error members) into one JWT carried in the `response` query parameter (JARM §2.3.1).
The JWT's `iss` claim identifies the issuer, so no plain `iss` parameter is added.
`selectJarmSigningKey()` picks the RS256 key from the registered key set, and `jarmResponseModeHandler` rebuilds this mode at `/consent` from the transaction's record.
`contribution` is meta that tells `maronn-oidc graph` that JARM also contributes to the `build-authorization-response` step of `/consent`, whose box then lists JARM §2.3.1.

```typescript
/**
 * EXPERIMENTAL — the JWT Secured Authorization Response Mode, as the
 * authorization endpoint answers in it.
 *
 * The authorization response parameters (code and state, or the error
 * members) become claims of one signed JWT, delivered as the single `response`
 * query parameter (JARM §2.3.1). The JWT's iss claim identifies the issuer, so
 * no plain iss parameter is added.
 */
import { selectSigningKeyByAlg, type SigningKey } from '@maronn-openid-connect/core';
import { buildJarmRedirectUrl, createJarmResponseJwt } from '@maronn-openid-connect/experimental/jarm';
import type {
  AuthorizationResponseMode,
  AuthorizationResponseModeHandler,
} from '../../endpoints/authorize/response-mode.js';
import { contribute } from '../../endpoints/step.js';
import { jarmConfig } from './config.js';

/**
 * What JARM adds to the build-authorization-response box of the consent
 * endpoint: the response it restores can be the signed JWT of JARM §2.3.1.
 */
export const contribution = contribute({
  endpoint: 'consent',
  step: 'build-authorization-response',
  feature: 'jarm',
  spec: 'JARM §2.3.1',
});

/** The name the transaction stores: the query.jwt mode (its `jwt` shorthand is answered the same way). */
export const JARM_RESPONSE_MODE_NAME = 'query.jwt';

/** The JARM response mode for a client, signed with signingKey (RS256, JARM §3). */
export function jarmResponseMode(input: {
  issuer: string;
  clientId: string;
  signingKey: SigningKey;
}): AuthorizationResponseMode {
  return {
    name: JARM_RESPONSE_MODE_NAME,
    async redirect(redirectUri, parameters) {
      return buildJarmRedirectUrl(
        redirectUri,
        await createJarmResponseJwt({
          issuer: input.issuer,
          clientId: input.clientId,
          parameters,
          signingKey: input.signingKey,
          lifetimeSeconds: jarmConfig.jarmResponseLifetimeSeconds,
        }),
      );
    },
  };
}

/**
 * JARM §3: this OP declares alg RS256 on every response JWT (the default for
 * a client that registered no authorization_signed_response_alg), and
 * discovery advertises authorization_signing_alg_values_supported: ['RS256'].
 * The first key of the general-purpose set is not guaranteed to be RS256 — a
 * SigningKeyProvider may legitimately put an ES256 key first in an RS256 +
 * ES256 set — so the key is picked by alg from the set. Its public half is
 * published at /.well-known/jwks.json under the same kid.
 * selectSigningKeyByAlg throws when no RS256 key is registered, which surfaces
 * as a server_error (a configuration mistake) rather than as an unverifiable
 * authorization response.
 */
export function selectJarmSigningKey(c: any): SigningKey {
  const jarmSigningKeys = (c.get('signingKeys') as SigningKey[] | undefined) ?? [];
  return selectSigningKeyByAlg(jarmSigningKeys, 'RS256');
}

/**
 * The JARM response mode of a stored transaction: /consent answers in it when
 * the authorization request asked for response_mode=query.jwt (JARM §2.3).
 */
export const jarmResponseModeHandler: AuthorizationResponseModeHandler = {
  names: [JARM_RESPONSE_MODE_NAME],
  restore(c, { clientId, issuer }) {
    return jarmResponseMode({ issuer, clientId, signingKey: selectJarmSigningKey(c) });
  },
};
```

#### `features/jarm/steps/resolve-jarm-response-mode.ts`

The step the owner block of the authorization endpoint calls.
`endpoint: 'authorize'` and `feature: 'jarm'` in its `meta` say which endpoint runs it and which feature owns it, and `produces: ['responseMode']` names the value it hands to the later steps.
It turns the classification that the experimental `resolveJarmResponseMode` returns as a discriminated union into an error at this point, where `redirect_uri` is settled.
`unsupported-jwt-mode` becomes an `invalid_request` `AuthorizationError` that carries the settled `redirectUri` and `state`, and reaches the client as a plain query response.
For any classification other than `jarm` it returns `undefined`, so `response_mode` values outside the `.jwt` family stay ignored as before.

```typescript
import {
  AuthorizationError,
  AuthorizationErrorCode,
  type AuthorizationRequestParams,
  type ClientInfo,
} from '@maronn-openid-connect/core';
import { resolveJarmResponseMode } from '@maronn-openid-connect/experimental/jarm';
import type { AuthorizationResponseMode } from '../../../endpoints/authorize/response-mode.js';
import { step } from '../../../endpoints/step.js';
import { jarmResponseMode, selectJarmSigningKey } from '../response-mode.js';

export const meta = step({
  id: 'resolve-jarm-response-mode',
  endpoint: 'authorize',
  feature: 'jarm',
  kind: 'resolve',
  label: 'Interpret response_mode=query.jwt',
  spec: 'JARM §2.3 / §3',
  function: 'resolveJarmResponseContext',
  calls: ['resolveJarmResponseMode', 'selectSigningKeyByAlg'],
  consumes: ['params', 'effectiveParams', 'client', 'redirectUri', 'state', 'issuer'],
  produces: ['responseMode'],
  removable: false,
});

/**
 * EXPERIMENTAL — JARM §2.3: interpret response_mode now that redirect_uri is
 * verified, so an unsupported JWT mode can be reported as a redirectable
 * error. Values outside the `.jwt` family stay ignored exactly as before, and
 * the result is undefined: the plain query response.
 */
export function resolveJarmResponseContext(
  c: any,
  params: AuthorizationRequestParams,
  client: ClientInfo,
  redirectUri: string,
  state: string | undefined,
  issuer: string,
): AuthorizationResponseMode | undefined {
  const jarmResolution = resolveJarmResponseMode(params);
  if (jarmResolution.kind === 'unsupported-jwt-mode') {
    // JARM §2.3.2 / §2.3.3 (fragment.jwt / form_post.jwt) are not implemented
    // here. The rejection itself goes back as a PLAIN query error: the OP
    // cannot answer in a response mode it does not implement.
    throw new AuthorizationError(
      AuthorizationErrorCode.InvalidRequest,
      'response_mode ' + jarmResolution.requested + ' is not supported',
      redirectUri,
      state,
    );
  }
  if (jarmResolution.kind !== 'jarm') return undefined;
  return jarmResponseMode({ issuer, clientId: client.clientId, signingKey: selectJarmSigningKey(c) });
}
```

### The other frameworks

The express and fastify outputs consist of the same files as hono.
The CLI replaces the `hono` router the endpoints import with `web-router.ts`, a small Fetch-API router (`WebRouter` and `WebContext`), and adds the framework's `apply.ts`, `web-router.ts` and `node-adapter.ts`.
The added files come from [apps/hono/src/web/](../../../apps/hono/src/web), and [packages/cli/extract.json](../../../packages/cli/extract.json) defines which file goes where.
The screens stay hono/jsx, so those outputs need `hono` as their JSX runtime.
The files of `features/jarm/` import nothing from `hono`, so they are the same for express and fastify as for hono.

The Next.js output is extracted from [apps/nextjs](../../../apps/nextjs), a Next.js App Router app.
A feature's route files live in the route group `app/(<feature-id>)/` and the rest of its code in `app/_oidc-provider/features/<feature-id>/`; the JARM code is in `app/_oidc-provider/features/jarm/`.
Neither is embedded in this guide; the directory is linked instead.

## The E2E test, in full

The E2E test completes real browser flows and pins down:

- the authorization response arriving as a verifiable signed JWT (verified against the JWKS, with the claimed `code` carrying through to token issuance)
- a signed error JWT when the user denies consent
- rejection of an unsupported `.jwt` mode with a plain error
- discovery advertising the JWT response modes and the signing algorithm
- a request without `response_mode` still receiving the plain query response (the isolation principle, verified in the field)

```typescript
import { expect, test } from '@playwright/test';

const host = process.env.E2E_HOST ?? '127.0.0.1';
const clientPort = Number(process.env.E2E_CLIENT_PORT ?? '3020');
const clientBaseURL =
  process.env.E2E_CLIENT_BASE_URL ?? `http://${host}:${clientPort}`;
const clientId = 'e2e-client';

/**
 * EXPERIMENTAL — JWT Secured Authorization Response Mode (JARM).
 *
 * Only the samples generated with `--enable jarm` interpret the JWT response
 * modes, so every test here skips when discovery does not advertise them. That
 * keeps the shared spec suite green across all sample OPs.
 *
 * The client half of the contract (JARM §2.4: verify the JWS with a key from the
 * OP's jwks_uri, check iss / aud / exp, reject alg=none) lives in
 * tests/e2e/apps/client.mjs and throws on any violation — so a rendered result
 * page is itself evidence that verification passed.
 */
test.describe('JWT Secured Authorization Response Mode (JARM)', () => {
  test('should return the authorization response as a verifiable signed JWT', async ({
    page,
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const responseModes = await supportedResponseModes(request, issuer);
    test.skip(
      !responseModes.includes('query.jwt'),
      'This sample OP was generated without --enable jarm',
    );

    const redirectUri = `${clientBaseURL}/callback`;

    await page.goto(`${clientBaseURL}/start-jarm`);
    await expect(page).toHaveURL(new RegExp(`^${escapeRegExp(issuer)}/login\\?transaction_id=`));

    await page.getByLabel('Username:').fill('testuser');
    await page.getByLabel('Password:').fill('password');
    await page.getByRole('button', { name: 'Login' }).click();
    await expect(page).toHaveURL(new RegExp(`^${escapeRegExp(issuer)}/consent\\?transaction_id=`));

    await page.getByRole('button', { name: 'Approve' }).click();
    await expect(page).toHaveURL(new RegExp(`^${escapeRegExp(redirectUri)}\\?response=`));

    // JARM §2.3.1: `response` is the only query parameter. The plain code /
    // state / iss parameters are gone — the JWT's iss claim replaces RFC 9207's
    // iss parameter (RFC 9700 §2.1 accepts JARM for issuer identification).
    const callbackUrl = new URL(page.url());
    expect([...callbackUrl.searchParams.keys()]).toEqual(['response']);

    // JARM §2.1 / §2.4, checked by the client before it used the code.
    await expect(page.getByTestId('jarm-alg')).toHaveText('RS256');
    await expect(page.getByTestId('jarm-iss')).toHaveText(issuer);
    await expect(page.getByTestId('jarm-aud')).toHaveText(clientId);
    await expect(page.getByTestId('jarm-signature-valid')).toHaveText('true');
    await expect(page.getByTestId('jarm-claim-names')).toHaveText('aud code exp iss state');

    // The code carried by the JWT is an ordinary authorization code: the token
    // endpoint and UserInfo are untouched by JARM.
    await expect(page.getByTestId('token-type')).toHaveText('Bearer');
    await expect(page.getByTestId('userinfo-sub')).toHaveText('testuser');
  });

  test('should return a signed error JWT when the End-User denies consent', async ({
    page,
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const responseModes = await supportedResponseModes(request, issuer);
    test.skip(
      !responseModes.includes('query.jwt'),
      'This sample OP was generated without --enable jarm',
    );

    const redirectUri = `${clientBaseURL}/callback`;

    await page.goto(`${clientBaseURL}/start-jarm`);
    await page.getByLabel('Username:').fill('testuser');
    await page.getByLabel('Password:').fill('password');
    await page.getByRole('button', { name: 'Login' }).click();
    await expect(page).toHaveURL(new RegExp(`^${escapeRegExp(issuer)}/consent\\?transaction_id=`));

    await page.getByRole('button', { name: 'Deny' }).click();
    await expect(page).toHaveURL(new RegExp(`^${escapeRegExp(redirectUri)}\\?response=`));

    const callbackUrl = new URL(page.url());
    expect([...callbackUrl.searchParams.keys()]).toEqual(['response']);

    // JARM §2.1 error example: an error response is the same signed JWT shape,
    // so the client can verify that the OP it trusts is the one that refused.
    await expect(page.getByTestId('authorization-error')).toHaveText('access_denied');
    await expect(page.getByTestId('jarm-alg')).toHaveText('RS256');
    await expect(page.getByTestId('jarm-signature-valid')).toHaveText('true');
    await expect(page.getByTestId('jarm-claim-names')).toHaveText('aud error exp iss state');
  });

  test('should reject an unsupported JWT response mode with a plain error', async ({
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const responseModes = await supportedResponseModes(request, issuer);
    test.skip(
      !responseModes.includes('query.jwt'),
      'This sample OP was generated without --enable jarm',
    );

    // JARM §2.3.2: fragment.jwt is for response types that return tokens in the
    // fragment, which this OP does not implement. The rejection cannot itself be
    // delivered in that mode, so it comes back as a plain query error.
    const response = await request.get(
      `${issuer}/authorize?response_type=code&client_id=${clientId}` +
        `&redirect_uri=${encodeURIComponent(`${clientBaseURL}/callback`)}` +
        '&scope=openid&state=e2e-jarm-state&response_mode=fragment.jwt' +
        '&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256',
      { maxRedirects: 0 },
    );

    expect(response.status()).toBe(302);
    const location = new URL(response.headers()['location'] ?? '');
    expect(location.searchParams.get('error')).toBe('invalid_request');
    expect(location.searchParams.get('error_description')).toBe(
      'response_mode fragment.jwt is not supported',
    );
    expect(location.searchParams.get('state')).toBe('e2e-jarm-state');
    expect(location.searchParams.get('response')).toBe(null);
  });

  test('should advertise the JWT response modes and signing algorithm in discovery', async ({
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const metadata = await discoveryMetadata(request, issuer);
    test.skip(
      !(metadata.response_modes_supported ?? []).includes('query.jwt'),
      'This sample OP was generated without --enable jarm',
    );

    // JARM §4: both AS metadata members the specification defines for JARM.
    expect(metadata.response_modes_supported).toEqual(['query', 'query.jwt', 'jwt']);
    expect(metadata.authorization_signing_alg_values_supported).toEqual(['RS256']);
  });

  test('should keep the plain query response for a request without response_mode', async ({
    page,
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const responseModes = await supportedResponseModes(request, issuer);
    test.skip(
      !responseModes.includes('query.jwt'),
      'This sample OP was generated without --enable jarm',
    );

    // Enabling JARM must not change anything for a client that did not ask for
    // it: the default response is still the plain query one.
    await page.goto(`${clientBaseURL}/start`);
    await page.getByLabel('Username:').fill('testuser');
    await page.getByLabel('Password:').fill('password');
    await page.getByRole('button', { name: 'Login' }).click();
    await page.getByRole('button', { name: 'Approve' }).click();

    const callbackUrl = new URL(page.url());
    expect([...callbackUrl.searchParams.keys()].sort()).toEqual(['code', 'iss', 'state']);
    expect(callbackUrl.searchParams.get('iss')).toBe(issuer);
  });
});

interface DiscoveryMetadata {
  response_modes_supported?: string[];
  authorization_signing_alg_values_supported?: string[];
}

async function discoveryMetadata(
  request: { get(url: string): Promise<{ json(): Promise<unknown> }> },
  issuer: string,
): Promise<DiscoveryMetadata> {
  const response = await request.get(`${issuer}/.well-known/openid-configuration`);
  return (await response.json()) as DiscoveryMetadata;
}

async function supportedResponseModes(
  request: { get(url: string): Promise<{ json(): Promise<unknown> }> },
  issuer: string,
): Promise<string[]> {
  return (await discoveryMetadata(request, issuer)).response_modes_supported ?? [];
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

## Related material

- User-facing documentation: [docs/library-document experimental/jarm.md](../../library-document/src/content/docs/experimental/jarm.md)
- Specification study documents: [tasks/experimental/done/jarm/](../../../tasks/experimental/done/jarm/)
- Promotion-review packet: [tasks/experimental/done/jarm/promotion-review/](../../../tasks/experimental/done/jarm/promotion-review/README.md)
- Package-wide conventions: [package-overview.en.md](./package-overview.en.md)
- 日本語版: [jarm.ja.md](./jarm.ja.md)
