# JWT Introspection Response (RFC 9701) Implementation Guide

This document explains **JWT Response for OAuth Token Introspection** (RFC 9701, Proposed Standard, published January 2025) as implemented in `packages/experimental`: what was implemented, how it was implemented, and the complete source code involved.

The document embeds, verbatim and in full:

- all four implementation files and all three test files under `packages/experimental/src/jwt-introspection-response/`
- the complete code that `--enable jwt-introspection-response` adds to the CLI-generated output (hono)
- the complete E2E test spec for this feature

The core package itself, the shared E2E harness, and the other frameworks' generated output are infrastructure shared by every feature, so they are referenced by links.

## What the feature does

Token introspection (RFC 7662) lets a resource server ask the Authorization Server about a token's state, and the answer comes back as plain JSON.
On a path where TLS has already been terminated (multi-hop gateways, a service mesh), the resource server cannot detect a tampered response, nor can it tell from the response alone which AS produced it.

RFC 9701 returns the introspection response as a JWT signed by the AS.
The RFC 7662 response members travel inside a `token_introspection` claim, joined by the issuer (`iss`), the addressee (`aud`) and the issuance time (`iat`), and the JOSE header carries a dedicated `typ` (`token-introspection+jwt`) before the whole thing is signed.
The resource server verifies the signature against the JWKS and checks `typ`, `iss` and `aud` before using the content, so both integrity and provenance are cryptographically established.

The entry point is the request's `Accept` header: the response becomes a JWT only when the caller explicitly names `application/token-introspection+jwt`.
Without it, the classic RFC 7662 JSON comes back unchanged.

```text
Resource Server (registered as a client)             OP
  |-- POST /introspect ------------------------------->|
  |   Accept: application/token-introspection+jwt      | client auth + token resolution (as before)
  |   token=...                                        | Accept check -> audience restriction -> RS256 signing
  |<- 200 application/token-introspection+jwt ---------|
  |   <compact JWS>                                    |
  |  (verify JWS via JWKS -> check typ / iss / aud -> use token_introspection)
```

### Use cases

- PoC work on architectures (microservices, multi-hop TLS termination) that require tamper evidence and provenance for introspection results
- studying the resource-server verification chain (JWKS resolution, signature verification, `typ` check, claim usage) required by FAPI-adjacent, high-assurance API profiles
- reproducing how cross-JWT confusion (replaying the introspection JWT as an access token) is stopped, and which check stops it, against an RS that skips the `typ` check

### Scope and non-goals

Implemented:

- `Accept` header negotiation (§4, explicit media-type match only)
- caller audience restriction (§3 / §5: any caller that is neither the issuee nor listed in `aud` receives `{"active": false}`)
- response JWT generation (§5: `typ: token-introspection+jwt`, top-level `iss` / `aud` / `iat`, the response wrapped in `token_introspection`, RS256 pinned)
- the discovery advertisement `introspection_signing_alg_values_supported: ["RS256"]` (§7)

Non-goals:

- per-client `introspection_signed_response_alg` (§6). This OP has no per-client algorithms, so the response is pinned to RS256, which matches §6's default when nothing is registered (the same decision JARM made)
- encrypted responses (§6's Nested JWT / JWE). The repository has no JWE infrastructure
- authenticating the introspection call with an access token (§4). The call keeps requiring client authentication, and a resource server registers as a client
- any change to the JSON response path. A request that does not ask for the JWT — audience restriction included — is answered exactly as before

## Design approach

The module consists of three implementation files plus the public API.

| File | Role |
|---|---|
| `accept.ts` | `Accept` header negotiation |
| `audience.ts` | caller audience restriction |
| `response-jwt.ts` | response JWT generation |
| `index.ts` | public API re-exports |

There are five design decisions.

First, the `Accept` check only honors an explicit media-type match.
Each comma-separated element is truncated at `;`, trimmed, lowercased and compared for equality; the wildcards `*/*` and `application/*` are not treated as a JWT request.
Generic HTTP clients send `Accept: */*` by default, so honoring wildcards would flip the response format of classic requests and break RFC 7662 backward compatibility.
q-values are not resolved either (§4 says nothing about them, and an RS that wants JSON simply does not send the media type).

Second, the audience restriction is fail-closed and creates no oracle.
Disclosure happens only when the caller's client_id matches the token's issuee (`client_id` member) or its `aud` member; otherwise core's `INACTIVE_INTROSPECTION_RESPONSE` itself is returned.
Returning the shared singleton rather than building a new object makes a withheld response byte-identical to the response for a genuinely inactive token, so the fact that the restriction fired leaks nowhere.

Third, signing is a self-contained compact-JWS implementation on the Web Crypto API (`crypto.subtle.sign`).
Core contains signing code of the same kind, but as private helpers that the no-core-changes constraint rules out.
The code resembles JARM's `response-jwt.ts`; following the policy that experimental features prefer independence and tolerate duplication, the implementation stays inside this feature.

Fourth, there is no configuration and no error class.
The signing algorithm is pinned to RS256 (matching §6's default) and the response JWT carries no `exp` (§5 SHOULD NOT), so nothing corresponding to JARM's lifetime setting exists.
Every function succeeds as long as its inputs meet the public API contract; a key mismatch propagates as the Web Crypto exception into the generated route's existing `server_error` branch.

Fifth, the generated-code branch sits only at the response exit, after client authentication and token resolution have fully completed.
That structurally prevents the `Accept` header from bypassing either step (§8.2 downgrade prevention), the same shape as JARM joining the authorize route at its response exit.
The response is returned with hono's `c.body`.
The specification's open item U2 had planned `c.text`, but the conformance tests during implementation showed that hono's `c.text` overwrites a pre-set `Content-Type` with `text/plain`, so the implementation switched to `c.body`, which preserves prepared headers (as does `WebContext.body`, which takes its place in the Express and Fastify output).

## Implementation source, in full

### accept.ts (Accept header negotiation)

```typescript
/**
 * JWT Response for OAuth Token Introspection (RFC 9701) — Accept ヘッダ判定。
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * RFC 9701 §4: リソースサーバーは Accept ヘッダを
 * `application/token-introspection+jwt` に設定して署名付き JWT の応答を要求する。
 * 本 OP はメディアタイプが明示された場合のみ JWT で応答し、ワイルドカード
 * （star-slash-star や `application/star`）は JWT 応答の要求と解釈しない。
 * ワイルドカードを JWT と解釈すると、汎用 HTTP クライアントが既定で送る
 * ワイルドカード Accept を持つ従来型リクエストの応答形式まで変わり、
 * RFC 7662 の後方互換が壊れるためである。
 */

/** RFC 9701 §4 / §5: 署名付きイントロスペクション応答のメディアタイプ。 */
export const TOKEN_INTROSPECTION_JWT_MEDIA_TYPE = 'application/token-introspection+jwt';

/**
 * Accept ヘッダが署名付き JWT のイントロスペクション応答を要求しているかを返す。
 *
 * カンマ区切りの各要素からメディアタイプ部分（`;` より前）を取り出し、
 * 前後空白を除いて小文字化した値が {@link TOKEN_INTROSPECTION_JWT_MEDIA_TYPE}
 * と完全一致する要素が 1 つでもあれば true。q 値による選好順位は解決しない
 * （`;q=0` の明示的拒否も JWT 要求として扱う。§4 に q 値の規定はなく、拒否
 * したい RS はメディアタイプ自体を送らなければよい）。
 */
export function acceptsIntrospectionJwt(acceptHeader: string | null | undefined): boolean {
  if (acceptHeader === null || acceptHeader === undefined || acceptHeader === '') {
    return false;
  }
  return acceptHeader.split(',').some((element) => {
    const mediaType = element.split(';')[0]?.trim().toLowerCase();
    return mediaType === TOKEN_INTROSPECTION_JWT_MEDIA_TYPE;
  });
}
```

The check is a single pipeline: split on commas, take each element up to `;`, trim, lowercase, compare for equality.
`null` / `undefined` / the empty string are rejected up front because the generated code's `c.req.header('Accept')` yields `undefined` when the header is absent, and callers should not need preprocessing.

### audience.ts (caller audience restriction)

```typescript
/**
 * JWT Response for OAuth Token Introspection (RFC 9701) — 呼び出し元 audience 制限。
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * RFC 9701 §3: AS は「リソースサーバーがそのアクセストークンの audience で
 * あるか」を判定できなければならない（MUST）。§5: トークンが呼び出し元 RS
 * 宛でない場合、`token_introspection.active` を false にし、他のメンバーを
 * 含めてはならない（MUST NOT）。
 *
 * この制限は JWT 応答経路にのみ適用する。Accept で JWT を要求しない従来の
 * RFC 7662 JSON 応答には適用せず、既存利用者のイントロスペクション挙動を
 * 変えない（JSON 経路の呼び出し元認可は core 側の将来フックの責務）。
 */
import {
  INACTIVE_INTROSPECTION_RESPONSE,
  type IntrospectionResponse,
} from '@maronn-openid-connect/core';

/**
 * イントロスペクション応答を、認証済み呼び出し元へ開示できる形に制限する。
 *
 * `active: true` の応答をそのまま返すのは、呼び出し元の client_id が
 * 「トークンの発行先（`client_id` メンバー）」または「トークンの `aud`
 * メンバー（文字列または配列）」に一致する場合のみ。どちらにも該当しない
 * 場合は `{ active: false }` に置き換え、制限が働いたことを応答から区別
 * させない（RFC 7662 §2.2 の「存在しないトークンと区別させない」原則と
 * 同じオラクル防止）。`active: false` の応答は常にそのまま返す。
 *
 * 入力オブジェクトは変更しない（純関数）。
 */
export function restrictIntrospectionResponseToCaller(
  response: IntrospectionResponse,
  callerClientId: string,
): IntrospectionResponse {
  if (!response.active) {
    return response;
  }
  if (response.client_id === callerClientId) {
    return response;
  }
  if (response.aud === callerClientId) {
    return response;
  }
  if (Array.isArray(response.aud) && response.aud.includes(callerClientId)) {
    return response;
  }
  return INACTIVE_INTROSPECTION_RESPONSE;
}
```

Everything the decision needs is on the response object itself.
The response built by core's `buildIntrospectionResponse` carries the issuee (`client_id`) and, when stored, the `aud`, so no extra store access and no core change is required.
An `active: false` response passes straight through at the top because an inactive token's response has no attributes left to restrict.

### response-jwt.ts (response JWT generation)

```typescript
/**
 * JWT Response for OAuth Token Introspection (RFC 9701) — 応答 JWT 生成。
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * RFC 9701 §5 のクレーム構造でイントロスペクション応答を署名付き JWT にする。
 * 署名は Web Crypto API（`crypto.subtle.sign`）で compact JWS を組み立てる
 * 自前実装であり、core の非公開な低レベル署名ヘルパーには依存しない
 * （core 無変更の維持）。JARM の response-jwt と同種のコードになるが、
 * Experimental 機能は独立性を優先して重複を許容する方針に従う。
 */
import type { IntrospectionResponse, SigningKey } from '@maronn-openid-connect/core';

/**
 * RFC 9701 §5 REQUIRED: 応答 JWT の `typ` JOSE ヘッダ。
 *
 * cross-JWT confusion（§8.1: イントロスペクション JWT をアクセストークンや
 * ID トークンとして流用する攻撃）対策の要であり、RS は検証時にこの値を
 * 確認しなければならない。
 */
export const TOKEN_INTROSPECTION_JWT_TYP = 'token-introspection+jwt';

/**
 * 応答 JWT の署名アルゴリズム。
 *
 * RFC 9701 §6: クライアントが `introspection_signed_response_alg` を登録して
 * いない場合の既定は RS256。この OP はクライアント別 alg を持たないため
 * RS256 固定とする（JARM と同じ固定方針）。固定であることの裏返しとして、
 * {@link createIntrospectionResponseJwt} に渡す `signingKey` は RS256 鍵で
 * なければならない。別種の鍵では Web Crypto が署名を拒否して例外になるため、
 * `alg: RS256` を偽って表明する JWS が生成されることはない。
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
 * イントロスペクション応答を RFC 9701 §5 のクレーム構造で署名付き JWT にする。
 *
 * - JOSE ヘッダー: `{ typ: 'token-introspection+jwt', alg: 'RS256', kid }`。
 *   `typ` は §5 REQUIRED、`kid` は JWKS で検証鍵を特定させる（RFC 8725 §3.10
 *   の実践。JARM と同じ）。
 * - ペイロード: `iss` / `aud` / `iat`（いずれも §5 MUST）と、RFC 7662 の応答
 *   メンバーをそのまま収めた `token_introspection` クレーム。トップレベルに
 *   `sub` / `exp` は含めない（§5 SHOULD NOT — アクセストークンとしての悪用
 *   防止。§8.1）。
 * - `token_introspection` の中身は渡された応答オブジェクトそのもので、
 *   メンバーの追加・削除・改変はしない。active でない応答も同じ構造で
 *   JWT 化する（§5: active を false にし他のメンバーを含めない —
 *   `INACTIVE_INTROSPECTION_RESPONSE` がその形そのもの）。
 *
 * @param options.issuer `iss` クレーム（OP の issuer）
 * @param options.audience `aud` クレーム。認証済み呼び出し元の client_id
 *   （§5 MUST: 「introspection response を受け取る RS を識別」。この OP は RS
 *   をクライアントとして登録するため client_id が識別子になる）
 * @param options.introspection `token_introspection` クレームに封入する応答。
 *   呼び出し側で {@link restrictIntrospectionResponseToCaller} を通した値を
 *   渡すこと
 * @param options.signingKey 応答 JWT の署名鍵。**RS256 鍵であること**（JOSE
 *   ヘッダの `alg` は常に RS256 固定なので、他の alg の鍵を渡すと Web Crypto
 *   が署名を拒否して例外になる）。生成コードは登録鍵セットから
 *   `selectSigningKeyByAlg(keys, 'RS256')` で選ぶこと
 * @param options.now `iat` の発行時刻（テスト用の注入点。既定は現在時刻）
 */
export async function createIntrospectionResponseJwt(options: {
  issuer: string;
  audience: string;
  introspection: IntrospectionResponse;
  signingKey: SigningKey;
  now?: Date;
}): Promise<string> {
  const issuedAtSeconds = Math.floor((options.now ?? new Date()).getTime() / 1000);

  // RFC 9701 §5: iss / aud / iat are MUST; the RFC 7662 members travel inside
  // token_introspection and are never spread onto the top level (§8.1).
  const claims: Record<string, unknown> = {
    iss: options.issuer,
    aud: options.audience,
    iat: issuedAtSeconds,
    token_introspection: options.introspection,
  };

  const encodedHeader = base64UrlFromJson({
    typ: TOKEN_INTROSPECTION_JWT_TYP,
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
```

The claim set is exactly §5's MUSTs (`iss` / `aud` / `iat` / `token_introspection`), with no top-level `sub` or `exp`.
That removes, structurally, the room for the response JWT to pass as an access token (§8.1); together with the pinned `typ` it is where the cross-JWT confusion defense is implemented.
The response object is placed into `token_introspection` verbatim, with no members added or removed.
What the response contains is the business of core and `restrictIntrospectionResponseToCaller`; the signing layer deliberately stays out of the content.

### index.ts (public API)

```typescript
/**
 * JWT Response for OAuth Token Introspection — RFC 9701 (Proposed Standard,
 * 2025-01)
 *
 * **Experimental**: この機能の API は安定していない。マイナーリリースでも
 * 破壊的に変更されることがある。本番運用の前に
 * `docs/library-document` の Experimental セクションを確認すること。
 *
 * `@maronn-openid-connect/core` とは別 package であり、CLI で
 * `--enable jwt-introspection-response` を明示したときのみ生成コードから利用される。
 *
 * スコープは**署名付き応答（RS256 固定）のみ**に限定する。暗号化応答
 * （§6 の Nested JWT）・クライアント別 `introspection_signed_response_alg`
 * （§6）・アクセストークンによる RS 認証（§4）は非対応。Accept で JWT を
 * 要求しない従来の RFC 7662 JSON 応答は一切変えない。
 */
export {
  TOKEN_INTROSPECTION_JWT_MEDIA_TYPE,
  acceptsIntrospectionJwt,
} from './accept.js';

export { restrictIntrospectionResponseToCaller } from './audience.js';

export {
  TOKEN_INTROSPECTION_JWT_TYP,
  createIntrospectionResponseJwt,
} from './response-jwt.js';
```

## Unit tests, in full

The tests were written TDD-style (t_wada school), red to green, in the order `accept` → `audience` → `response-jwt`.
Following the repository rule that assertions pin a single passing value, the JOSE header and the payload are pinned whole with `toEqual`.

### accept.test.ts

```typescript
import { describe, expect, it } from 'vitest';
import { TOKEN_INTROSPECTION_JWT_MEDIA_TYPE, acceptsIntrospectionJwt } from './accept.js';

describe('acceptsIntrospectionJwt', () => {
  describe('Explicit media type (RFC 9701 §4)', () => {
    it('should return true for the exact media type', () => {
      expect(acceptsIntrospectionJwt('application/token-introspection+jwt')).toBe(true);
    });

    it('should match the media type case-insensitively', () => {
      expect(acceptsIntrospectionJwt('Application/Token-Introspection+JWT')).toBe(true);
    });

    it('should match the media type inside a multi-element Accept header', () => {
      expect(
        acceptsIntrospectionJwt('application/json, application/token-introspection+jwt'),
      ).toBe(true);
    });

    it('should ignore media type parameters such as a q value', () => {
      expect(acceptsIntrospectionJwt('application/token-introspection+jwt;q=0.9')).toBe(true);
    });

    it('should tolerate surrounding whitespace around list elements', () => {
      expect(
        acceptsIntrospectionJwt('application/json ,  application/token-introspection+jwt '),
      ).toBe(true);
    });
  });

  describe('Requests that stay on the RFC 7662 JSON path', () => {
    it('should return false for a missing header', () => {
      expect(acceptsIntrospectionJwt(undefined)).toBe(false);
    });

    it('should return false for a null header', () => {
      expect(acceptsIntrospectionJwt(null)).toBe(false);
    });

    it('should return false for an empty header', () => {
      expect(acceptsIntrospectionJwt('')).toBe(false);
    });

    it('should return false for application/json', () => {
      expect(acceptsIntrospectionJwt('application/json')).toBe(false);
    });

    // A generic HTTP client's default Accept must not flip the response format:
    // only the explicitly named RFC 9701 media type requests the JWT.
    it('should return false for the full wildcard', () => {
      expect(acceptsIntrospectionJwt('*/*')).toBe(false);
    });

    it('should return false for the application type wildcard', () => {
      expect(acceptsIntrospectionJwt('application/*')).toBe(false);
    });

    it('should return false for an unrelated jwt-suffixed media type', () => {
      expect(acceptsIntrospectionJwt('application/jwt')).toBe(false);
    });
  });

  describe('Media type constant', () => {
    it('should expose the RFC 9701 media type verbatim', () => {
      expect(TOKEN_INTROSPECTION_JWT_MEDIA_TYPE).toBe('application/token-introspection+jwt');
    });
  });
});
```

### audience.test.ts

```typescript
import { INACTIVE_INTROSPECTION_RESPONSE, type IntrospectionResponse } from '@maronn-openid-connect/core';
import { describe, expect, it } from 'vitest';
import { restrictIntrospectionResponseToCaller } from './audience.js';

function activeResponse(overrides: Partial<Extract<IntrospectionResponse, { active: true }>> = {}): IntrospectionResponse {
  return {
    active: true,
    scope: 'openid',
    client_id: 'issued-to-client',
    token_type: 'Bearer',
    sub: 'testuser',
    exp: 1785801600,
    ...overrides,
  };
}

describe('restrictIntrospectionResponseToCaller', () => {
  describe('Responses disclosed to the caller (RFC 9701 §3)', () => {
    it('should return the response unchanged for the client the token was issued to', () => {
      const response = activeResponse();

      expect(restrictIntrospectionResponseToCaller(response, 'issued-to-client')).toEqual({
        active: true,
        scope: 'openid',
        client_id: 'issued-to-client',
        token_type: 'Bearer',
        sub: 'testuser',
        exp: 1785801600,
      });
    });

    it('should return the response unchanged for a caller listed in a string aud', () => {
      const response = activeResponse({ aud: 'rs-client' });

      expect(restrictIntrospectionResponseToCaller(response, 'rs-client')).toEqual({
        active: true,
        scope: 'openid',
        client_id: 'issued-to-client',
        token_type: 'Bearer',
        sub: 'testuser',
        exp: 1785801600,
        aud: 'rs-client',
      });
    });

    it('should return the response unchanged for a caller listed in an array aud', () => {
      const response = activeResponse({ aud: ['http://localhost:3000/userinfo', 'rs-client'] });

      expect(restrictIntrospectionResponseToCaller(response, 'rs-client')).toEqual({
        active: true,
        scope: 'openid',
        client_id: 'issued-to-client',
        token_type: 'Bearer',
        sub: 'testuser',
        exp: 1785801600,
        aud: ['http://localhost:3000/userinfo', 'rs-client'],
      });
    });
  });

  describe('Responses withheld from the caller (RFC 9701 §5 MUST NOT)', () => {
    it('should replace the response with active false only for a caller that is neither issuee nor audience', () => {
      const response = activeResponse({ aud: ['http://localhost:3000/userinfo'] });

      expect(restrictIntrospectionResponseToCaller(response, 'other-client')).toEqual({
        active: false,
      });
    });

    it('should withhold a response without an aud member from every caller but the issuee', () => {
      const response = activeResponse();

      expect(restrictIntrospectionResponseToCaller(response, 'other-client')).toEqual({
        active: false,
      });
    });

    // The withheld shape must be the shared inactive singleton so a restricted
    // response is byte-identical to a genuinely inactive one (no oracle).
    it('should return the shared inactive response object when withholding', () => {
      const restricted = restrictIntrospectionResponseToCaller(activeResponse(), 'other-client');

      expect(restricted).toBe(INACTIVE_INTROSPECTION_RESPONSE);
    });
  });

  describe('Inactive responses', () => {
    it('should pass an inactive response through unchanged', () => {
      const response: IntrospectionResponse = { active: false };

      expect(restrictIntrospectionResponseToCaller(response, 'any-client')).toBe(response);
    });
  });

  describe('Purity', () => {
    it('should not mutate the input response when withholding', () => {
      const response = activeResponse({ aud: 'someone-else' });

      restrictIntrospectionResponseToCaller(response, 'other-client');

      expect(response).toEqual({
        active: true,
        scope: 'openid',
        client_id: 'issued-to-client',
        token_type: 'Bearer',
        sub: 'testuser',
        exp: 1785801600,
        aud: 'someone-else',
      });
    });
  });
});
```

The test that pins, with `toBe`, that withholding returns the shared singleton is the regression guard for the no-oracle design decision.

### response-jwt.test.ts

```typescript
import type { IntrospectionResponse, SigningKey } from '@maronn-openid-connect/core';
import { beforeAll, describe, expect, it } from 'vitest';
import { TOKEN_INTROSPECTION_JWT_TYP, createIntrospectionResponseJwt } from './response-jwt.js';

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

// 2026-08-24T00:00:00Z. Injected so every iat assertion is a fixed value.
const NOW = new Date('2026-08-24T00:00:00.000Z');
const NOW_SECONDS = 1787529600;

const ACTIVE_INTROSPECTION: IntrospectionResponse = {
  active: true,
  scope: 'openid',
  client_id: 'rs-client',
  token_type: 'Bearer',
  sub: 'testuser',
  exp: NOW_SECONDS + 3600,
};

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
  signingKey = { privateKey: keyPair.privateKey, publicJwk, keyId: 'introspection-key-1' };
  publicKey = keyPair.publicKey;
});

describe('createIntrospectionResponseJwt', () => {
  describe('JOSE Header', () => {
    // RFC 9701 §5 REQUIRED typ + §8.1: the typ header is what stops the response
    // JWT from being replayed as an access token or ID token.
    it('should set typ to token-introspection+jwt, alg to RS256 and kid to the signing key id', async () => {
      const jwt = await createIntrospectionResponseJwt({
        issuer: 'http://localhost:3000',
        audience: 'rs-client',
        introspection: ACTIVE_INTROSPECTION,
        signingKey,
        now: NOW,
      });

      expect(header(jwt)).toEqual({
        typ: 'token-introspection+jwt',
        alg: 'RS256',
        kid: 'introspection-key-1',
      });
    });
  });

  describe('Payload claims (RFC 9701 §5)', () => {
    it('should carry iss, aud, iat and the token_introspection claim with the response verbatim', async () => {
      const jwt = await createIntrospectionResponseJwt({
        issuer: 'http://localhost:3000',
        audience: 'rs-client',
        introspection: ACTIVE_INTROSPECTION,
        signingKey,
        now: NOW,
      });

      expect(payload(jwt)).toEqual({
        iss: 'http://localhost:3000',
        aud: 'rs-client',
        iat: NOW_SECONDS,
        token_introspection: {
          active: true,
          scope: 'openid',
          client_id: 'rs-client',
          token_type: 'Bearer',
          sub: 'testuser',
          exp: NOW_SECONDS + 3600,
        },
      });
    });

    // RFC 9701 §5 SHOULD NOT: top-level sub / exp would let the JWT pass for an
    // access token; the member set is pinned so neither can appear.
    it('should not put sub or exp on the top level', async () => {
      const jwt = await createIntrospectionResponseJwt({
        issuer: 'http://localhost:3000',
        audience: 'rs-client',
        introspection: ACTIVE_INTROSPECTION,
        signingKey,
        now: NOW,
      });

      expect(Object.keys(payload(jwt))).toEqual(['iss', 'aud', 'iat', 'token_introspection']);
    });

    // RFC 9701 §5: an unknown or expired token is answered with the same JWT
    // structure whose token_introspection carries only active: false.
    it('should wrap an inactive response as token_introspection with active false only', async () => {
      const jwt = await createIntrospectionResponseJwt({
        issuer: 'http://localhost:3000',
        audience: 'rs-client',
        introspection: { active: false },
        signingKey,
        now: NOW,
      });

      expect(payload(jwt)).toEqual({
        iss: 'http://localhost:3000',
        aud: 'rs-client',
        iat: NOW_SECONDS,
        token_introspection: { active: false },
      });
    });

    it('should derive iat deterministically from the injected now', async () => {
      const jwt = await createIntrospectionResponseJwt({
        issuer: 'http://localhost:3000',
        audience: 'rs-client',
        introspection: { active: false },
        signingKey,
        now: new Date('2026-08-24T00:00:59.999Z'),
      });

      expect(payload(jwt).iat).toBe(NOW_SECONDS + 59);
    });
  });

  describe('Signature', () => {
    it('should produce a compact JWS whose signature verifies with the public key', async () => {
      const jwt = await createIntrospectionResponseJwt({
        issuer: 'http://localhost:3000',
        audience: 'rs-client',
        introspection: ACTIVE_INTROSPECTION,
        signingKey,
        now: NOW,
      });

      const [encodedHeader = '', encodedPayload = ''] = jwt.split('.');
      const verified = await crypto.subtle.verify(
        'RSASSA-PKCS1-v1_5',
        publicKey,
        signatureBytes(jwt),
        new TextEncoder().encode(`${encodedHeader}.${encodedPayload}`),
      );

      expect(jwt.split('.').length).toBe(3);
      expect(verified).toBe(true);
    });
  });

  describe('typ constant', () => {
    it('should expose the RFC 9701 typ value verbatim', () => {
      expect(TOKEN_INTROSPECTION_JWT_TYP).toBe('token-introspection+jwt');
    });
  });
});
```

Pinning `Object.keys(payload(jwt))` is the check that no top-level `sub` / `exp` exists; a single added claim fails it.

## CLI integration and the generated-code contribution

The experimental package is the logic layer (the `Accept` check, the audience restriction and the response JWT); the HTTP side, receiving the request and building the response, is generated code.
`maronn-oidc generate <framework> --enable jwt-introspection-response` takes the code this feature owns out of a running app, `apps/hono/src/oidc-provider/`, and adds it to the generated output.
What is taken and how is defined by [packages/cli/extract.json](../../../packages/cli/extract.json) and carried out by [packages/cli/src/generate.ts](../../../packages/cli/src/generate.ts).
The feature adds three things:

- **`features/jwt-introspection-response/`**: the two files the feature owns. The `defineFeature()` of `feature.ts` declares only the discovery member `introspection_signing_alg_values_supported: ['RS256']`; it has no routes, so no HTTP endpoint is added
- **one import and one list entry in `features/enabled.ts`**
- **one `(feature: jwt-introspection-response)` block in `features/introspection/endpoints/introspection/pipeline.ts`**: between the `build-response` and `respond` steps, it answers with the signed response when, and only when, the `Accept` header asks for the JWT

The request flow is as follows.
The resource server's `POST /introspect` reaches `features/introspection/endpoints/introspection/pipeline.ts`, which the introspection feature's `feature.ts` declares and `app.ts` mounts.
The pipeline parses the request, authenticates the confidential client, resolves the token and builds the response members, and only then enters the sign-response block.
The `signIntrospectionResponse()` the block calls returns the JWT response when `Accept` names `application/token-introspection+jwt`, and `undefined` otherwise.
On `undefined` the following `respond` step answers with JSON exactly as before.

The contribution is a block rather than a hook because the logic runs in the middle of the introspection pipeline and reads what authentication and token resolution produced (`introspection` and `authenticatedClientId`).
The fixed hooks (`routes`, `discovery`, `context`, and so on) have no way to insert logic into a pipeline.
With the block pinned after authentication and token resolution, the `Accept` header structurally cannot bypass either (§8.2 downgrade prevention).
When the feature is disabled, the generator deletes the block and the import only the block uses.
No later block reads the `signed` value it defines, so no `const signed = undefined;` stand-in is left either.

The pipeline that hosts the block belongs to the stable introspection feature, so this feature depends on introspection.
The dependency is written as `requires` in the feature list of [packages/cli/src/registry.ts](../../../packages/cli/src/registry.ts).

```typescript
  { id: 'jwt-introspection-response', tier: 'experimental', requires: ['introspection'], packages: EXPERIMENTAL, frameworks: ALL_FRAMEWORKS, runtimes: ALL_RUNTIMES, summary: 'JWT Response for Token Introspection (RFC 9701)', requiresReason: 'the RFC 9701 JWT response is returned by the RFC 7662 introspection endpoint, which is not generated when introspection is disabled' },
```

`--enable jwt-introspection-response --disable introspection` is rejected by `assertFeatureDependencies()`, which runs after feature resolution and adds `requiresReason` to the error.

```typescript
export function assertFeatureDependencies(features: OidcFeatureConfig): void {
  for (const entry of FEATURE_REGISTRY) {
    if (!features[featureKeyOf(entry.id)]) continue;
    for (const required of entry.requires) {
      if (features[featureKeyOf(required)]) continue;
      throw new Error(
        `Feature "${entry.id}" requires the ${required} feature` +
          (entry.requiresReason === undefined ? '' : `: ${entry.requiresReason}`),
      );
    }
  }
}
```

The import-boundary lint reads the same `requires`: `features/<a>/` may import `features/<b>/` only when the entry of `a` lists `b`.
That declaration is what lets `steps/sign-response.ts` import the introspection feature's `respondIntrospection()`.

The generated output contains no tests.
In `apps/hono`, the source of the extraction, tests placed next to the feature's files (the `*.test.ts` of [apps/hono/src/oidc-provider/features/jwt-introspection-response](../../../apps/hono/src/oidc-provider/features/jwt-introspection-response)) pin the behavior, and the extraction leaves them out.

### The generated code in full (hono)

The code below is what this feature adds to the hono output generated with the default features plus `--enable jwt-introspection-response`.

#### The lines added to `features/enabled.ts`

`features/enabled.ts` lists the enabled features, with one import and one list entry per feature.
The hooks apply in the order of that array.

```typescript
import { jwtIntrospectionResponse } from './jwt-introspection-response/feature.js';
```

```typescript
  jwtIntrospectionResponse,
```

#### The lines added to `features/introspection/endpoints/introspection/endpoint.ts`

`features/introspection/endpoints/introspection/endpoint.ts` describes the steps of the introspection endpoint and the edges between them; `maronn-oidc graph` draws its diagram and `--flow` checks a flow document from this description.
Its `steps` hold the line of the `jwt-introspection-response` step, and its `edges.extra` the line of the edge that leaves that step.
When the provider is generated without `jwt-introspection-response`, the CLI removes these lines, so the output's `endpoint.ts` lists only the steps the output has.

```typescript
    'sign-response',
```

```typescript
      { from: 'sign-response', to: 'respond', label: 'application/token-introspection+jwt', kind: 'branch' },
```

#### The `(feature: jwt-introspection-response)` block of `features/introspection/endpoints/introspection/pipeline.ts`

The import of the step the block calls joins the top of the pipeline.

```typescript
import { signIntrospectionResponse } from '../../../jwt-introspection-response/steps/sign-response.js';
```

The block runs right after the `build-response` step (which builds the response members) and right before the `respond` step.
The pipeline returns there only when the step returns a `Response`; on `undefined` it goes on to `respond`.

```typescript
    // [sign-response] (feature: jwt-introspection-response) Answer as a signed JWT when asked for one — RFC 9701 §4 / §5
    const signed = await signIntrospectionResponse(c, introspection, authenticatedClientId);
    if (signed) return signed;
```

#### `features/jwt-introspection-response/feature.ts`

The declaration of the feature.
Its only hook is `discovery`, which advertises exactly `RS256` in the RFC 9701 §7 metadata member `introspection_signing_alg_values_supported`.
The response JWT's alg is pinned to RS256 (the §6 default; there is no per-client `introspection_signed_response_alg`), so exactly one value is advertised.
The feature has no routes, no context and no settings, so enabling it changes neither the HTTP paths nor the shape of the configuration.

```typescript
import { defineFeature } from '../feature.js';

/**
 * EXPERIMENTAL — JWT Response for OAuth Token Introspection (RFC 9701): the
 * introspection endpoint answers a request whose Accept header names
 * application/token-introspection+jwt with a signed JWT, in the
 * sign-response block of the introspection pipeline. It needs the
 * introspection feature, whose endpoint carries the response. A request
 * that does not name that media type is answered exactly as before.
 *
 * Backed by @maronn-openid-connect/experimental, whose API is NOT stable: it
 * may change in a breaking way between releases.
 */
export const jwtIntrospectionResponse = defineFeature({
  id: 'jwt-introspection-response',
  // RFC 9701 §7 metadata. The introspection response JWT is always signed with
  // RS256 (§6: the default for a client that registered no
  // introspection_signed_response_alg), so exactly one alg is advertised.
  discovery: () => ({ introspection_signing_alg_values_supported: ['RS256'] }),
});
```

#### `features/jwt-introspection-response/steps/sign-response.ts`

The step the sign-response block calls.
Its `meta` describes the step as a box of the `maronn-oidc graph` diagram, and `after: ['build-response']` declares that a `--flow` reordering can never move it before the response members are built.

The step works in four stages.
First, `acceptsIntrospectionJwt()` checks `Accept`; when the JWT is not named explicitly the step returns `undefined` and the request goes the classic way.
Next, `restrictIntrospectionResponseToCaller()` replaces the response with `{ "active": false }` when the caller is neither the client the token was issued to nor listed in its `aud`.
Then `selectSigningKeyByAlg()` picks the RS256 key from the registered key set (`c.get('signingKeys')`), and `createIntrospectionResponseJwt()` signs.
Finally, the introspection feature's `respondIntrospection()` builds the response from the JWT string (`text`) and the dedicated `Content-Type`.

The key is chosen by alg rather than taken from the front of the set because, under the `SigningKeyProvider` contract, an RS256 + ES256 set with the ES256 key first is legitimate, and a JWT that declares `alg: RS256` must be signed with the RS256 key.
With no RS256 key registered, `selectSigningKeyByAlg()` throws and the pipeline's `respond-error` step answers 500 `server_error`.
An unverifiable JWT with a misdeclared `alg` is never returned.
`setRequestContext()` in `app.ts` stops the request with 503 when a key set is empty, so the `signingKeys` that reach the step are never empty.

The way the response is sent reflects a finding made during implementation: hono's `c.text` overwrites a pre-set `Content-Type` with `text/plain`.
[`respondIntrospection()`](../../../apps/hono/src/oidc-provider/features/introspection/endpoints/introspection/steps/respond.ts) sends a `text` with `c.body`, which keeps the `Content-Type` of `headers` and the `Cache-Control: no-store` as they are.
The `text` member of the introspection feature's response type (`IntrospectionEndpointResponse`) exists for this JWT response.

```typescript
import {
  type IntrospectionResponse,
  selectSigningKeyByAlg,
  type SigningKey,
} from '@maronn-openid-connect/core';
import {
  TOKEN_INTROSPECTION_JWT_MEDIA_TYPE,
  acceptsIntrospectionJwt,
  createIntrospectionResponseJwt,
  restrictIntrospectionResponseToCaller,
} from '@maronn-openid-connect/experimental/jwt-introspection-response';
import { respondIntrospection } from '../../introspection/endpoints/introspection/steps/respond.js';
import { step } from '../../../endpoints/step.js';

export const meta = step({
  id: 'sign-response',
  endpoint: 'introspection',
  feature: 'jwt-introspection-response',
  kind: 'dispatch',
  label: 'Answer as a signed JWT when asked for one',
  spec: 'RFC 9701 §4 / §5',
  function: 'signIntrospectionResponse',
  calls: ['acceptsIntrospectionJwt', 'restrictIntrospectionResponseToCaller', 'selectSigningKeyByAlg', 'createIntrospectionResponseJwt'],
  consumes: ['introspection', 'authenticatedClientId'],
  produces: [],
  removable: false,
  after: ['build-response'],
});

/**
 * EXPERIMENTAL — RFC 9701 §4 / §5: a caller whose Accept header names
 * application/token-introspection+jwt receives the introspection response as
 * a signed JWT. Any other request (no Accept, application/json, a wildcard)
 * returns undefined and is answered as before. The step sits AFTER client
 * authentication and token resolution so the Accept header can never bypass
 * either (§8.2 downgrade prevention).
 */
export async function signIntrospectionResponse(
  c: any,
  introspection: IntrospectionResponse,
  authenticatedClientId: string,
): Promise<Response | undefined> {
  if (!acceptsIntrospectionJwt(c.req.header('Accept'))) return undefined;

  // RFC 9701 §3 / §5: before the response leaves as a signed assertion its
  // members are restricted to what the authenticated caller may see — a
  // caller that is neither the client the token was issued to nor listed in
  // its aud gets { active: false }, indistinguishable from an unknown token.
  const restrictedResponse = restrictIntrospectionResponseToCaller(
    introspection,
    authenticatedClientId,
  );
  // RFC 9701 §6: alg is pinned to RS256 (the default for a client that
  // registered no introspection_signed_response_alg). The first key of the
  // general-purpose set is not guaranteed to be RS256 — a SigningKeyProvider
  // may legitimately put an ES256 key first in an RS256 + ES256 set — so the
  // key is picked by alg from the set. Its public half is published at
  // /.well-known/jwks.json under the same kid. selectSigningKeyByAlg throws
  // when no RS256 key is registered, which surfaces as a server_error
  // (a configuration mistake) rather than as an unverifiable introspection
  // response.
  const introspectionSigningKeys = (c.get('signingKeys') as SigningKey[] | undefined) ?? [];
  const introspectionSigningKey = selectSigningKeyByAlg(introspectionSigningKeys, 'RS256');
  const responseJwt = await createIntrospectionResponseJwt({
    issuer: c.get('config').issuer,
    audience: authenticatedClientId,
    introspection: restrictedResponse,
    signingKey: introspectionSigningKey,
  });
  // RFC 9701 §5: the success response is the compact JWS itself under its
  // own media type.
  return respondIntrospection(c, {
    status: 200,
    text: responseJwt,
    headers: { 'Content-Type': TOKEN_INTROSPECTION_JWT_MEDIA_TYPE },
  });
}
```

### The other frameworks

The Express and Fastify output has the same files.
The generator replaces the `hono` imports of the endpoints with `WebRouter` / `WebContext` of `web-router.ts` (a small router on the Fetch API) and adds an `apply.ts` for the framework, `web-router.ts` and `node-adapter.ts`.
What is replaced and which files are added is defined in [packages/cli/extract.json](../../../packages/cli/extract.json); the router and the adapters live in [apps/hono/src/web/](../../../apps/hono/src/web/).
The screens stay hono/jsx, so these outputs still need `hono` as the JSX runtime.
`WebContext.body` keeps the prepared headers too, so the JWT response's `Content-Type` is the same under Express and Fastify.

The Next.js output is extracted from [apps/nextjs](../../../apps/nextjs), a Next.js App Router app.
A feature's route files live in the route group `app/(<feature-id>)/` and its code in `app/_oidc-provider/features/<feature-id>/`.
This feature has no routes, so its code goes to `app/_oidc-provider/features/jwt-introspection-response/`.

The only sample that enables this feature is [samples/hono-cloudflare](../../../samples/hono-cloudflare).

## E2E test spec, in full

The E2E test completes the authorization code flow in a real browser, introspects the resulting access token over real HTTP, and pins:

- that when the issuing client requests the JWT via `Accept`, the `Content-Type` is the dedicated media type, the signature verifies against the JWKS, and `typ` / `iss` / `aud` / the claim set match the specification
- that a registered client which is neither the issuee nor in `aud` (the E2E resource-server role) receives `token_introspection` as `{"active": false}` — and that the very same caller without the `Accept` header still gets the full classic JSON (field evidence that the JSON path is unchanged)
- that discovery advertises the signing algorithm

On sample OPs generated without the feature, every test skips on the missing discovery advertisement, keeping the shared spec suite green across all samples.

```typescript
import { expect, test, type Locator } from '@playwright/test';

const host = process.env.E2E_HOST ?? '127.0.0.1';
const clientPort = Number(process.env.E2E_CLIENT_PORT ?? '3020');
const resourceServerPort = Number(process.env.E2E_RESOURCE_SERVER_PORT ?? '3030');
const clientBaseURL =
  process.env.E2E_CLIENT_BASE_URL ?? `http://${host}:${clientPort}`;
const resourceServerURL =
  process.env.E2E_RESOURCE_SERVER_URL ?? `http://${host}:${resourceServerPort}`;
const clientId = 'e2e-client';
const clientSecret = 'e2e-client-secret';
const resourceServerClientId = 'e2e-resource-server';
const resourceServerClientSecret = 'e2e-resource-server-secret';

const INTROSPECTION_JWT_MEDIA_TYPE = 'application/token-introspection+jwt';

/**
 * EXPERIMENTAL — JWT Response for OAuth Token Introspection (RFC 9701).
 *
 * Only the samples generated with `--enable jwt-introspection-response` answer
 * the RFC 9701 Accept header with a signed JWT, so every test here skips when
 * discovery does not advertise introspection_signing_alg_values_supported. That
 * keeps the shared spec suite green across all sample OPs.
 *
 * The verification chain a resource server must run (resolve the key from
 * jwks_uri, verify the JWS, check typ / iss / aud, then read
 * token_introspection) is performed inside this spec, over real HTTP.
 */
test.describe('JWT introspection response (RFC 9701)', () => {
  test('should answer the issuing client with a verifiable signed introspection JWT', async ({
    page,
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const algs = await introspectionSigningAlgs(request, issuer);
    test.skip(
      !algs.includes('RS256'),
      'This sample OP was generated without --enable jwt-introspection-response',
    );

    const accessToken = await completeAuthorizationCodeFlow(page, issuer);

    // The issuing client itself introspects the token and asks for the signed
    // response (RFC 9701 §4).
    const response = await request.post(`${issuer}/introspect`, {
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        Accept: INTROSPECTION_JWT_MEDIA_TYPE,
      },
      data: new URLSearchParams({
        client_id: clientId,
        client_secret: clientSecret,
        token: accessToken,
        token_type_hint: 'access_token',
      }).toString(),
    });

    expect(response.status()).toBe(200);
    expect(response.headers()['content-type']).toBe(INTROSPECTION_JWT_MEDIA_TYPE);

    const jwt = await response.text();
    const parsed = parseJwt(jwt);
    // RFC 9701 §5 REQUIRED typ — the §8.1 cross-JWT confusion defense — plus
    // the §6 default alg and the kid that resolves the key in jwks_uri.
    expect(parsed.header).toEqual({
      typ: 'token-introspection+jwt',
      alg: 'RS256',
      kid: 'e2e-rs256-key',
    });

    const jwks = (await (await request.get(`${issuer}/.well-known/jwks.json`)).json()) as JwkSet;
    expect(await verifyJwtSignature(jwt, jwks)).toBe(true);

    // RFC 9701 §5: iss / aud / iat at the top level and the RFC 7662 members
    // inside token_introspection — nothing else (no top-level sub / exp).
    expect(Object.keys(parsed.payload).sort()).toEqual(['aud', 'iat', 'iss', 'token_introspection']);
    expect(parsed.payload.iss).toBe(issuer);
    expect(parsed.payload.aud).toBe(clientId);
    expect(parsed.payload.token_introspection).toMatchObject({
      active: true,
      client_id: clientId,
      token_type: 'Bearer',
      sub: 'testuser',
      scope: 'openid profile email',
      aud: [`${issuer}/userinfo`, resourceServerURL],
    });
  });

  test('should withhold the signed response from a caller that is not an audience', async ({
    page,
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const algs = await introspectionSigningAlgs(request, issuer);
    test.skip(
      !algs.includes('RS256'),
      'This sample OP was generated without --enable jwt-introspection-response',
    );

    const accessToken = await completeAuthorizationCodeFlow(page, issuer);

    // The e2e resource server is registered as its own client, but the token's
    // aud carries the resource server URL, not that client_id — so on the JWT
    // path RFC 9701 §3 / §5 requires { active: false }, indistinguishable from
    // an unknown token. (To disclose to a third-party RS, the token must be
    // issued with that RS's client_id as an audience value.)
    const jwtResponse = await request.post(`${issuer}/introspect`, {
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        Accept: INTROSPECTION_JWT_MEDIA_TYPE,
        Authorization: `Basic ${basicCredentials(resourceServerClientId, resourceServerClientSecret)}`,
      },
      data: new URLSearchParams({ token: accessToken, token_type_hint: 'access_token' }).toString(),
    });

    expect(jwtResponse.status()).toBe(200);
    expect(jwtResponse.headers()['content-type']).toBe(INTROSPECTION_JWT_MEDIA_TYPE);
    const parsed = parseJwt(await jwtResponse.text());
    expect(parsed.payload.aud).toBe(resourceServerClientId);
    expect(parsed.payload.token_introspection).toEqual({ active: false });

    // The RFC 7662 JSON path is deliberately unchanged: the same caller without
    // the Accept header keeps seeing the full response, which is what the e2e
    // resource server's /profile check relies on.
    const jsonResponse = await request.post(`${issuer}/introspect`, {
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        Authorization: `Basic ${basicCredentials(resourceServerClientId, resourceServerClientSecret)}`,
      },
      data: new URLSearchParams({ token: accessToken, token_type_hint: 'access_token' }).toString(),
    });

    expect(jsonResponse.status()).toBe(200);
    expect((await jsonResponse.json()) as Record<string, unknown>).toMatchObject({
      active: true,
      client_id: clientId,
      sub: 'testuser',
    });
  });

  test('should advertise the introspection response signing algorithm in discovery', async ({
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const algs = await introspectionSigningAlgs(request, issuer);
    test.skip(
      !algs.includes('RS256'),
      'This sample OP was generated without --enable jwt-introspection-response',
    );

    // RFC 9701 §7: the one AS metadata member this implementation emits.
    expect(algs).toEqual(['RS256']);
  });
});

/**
 * Drives the browser through authorize -> login -> consent on the shared e2e
 * client app and returns the access token its result page shows.
 */
async function completeAuthorizationCodeFlow(
  page: import('@playwright/test').Page,
  issuer: string,
): Promise<string> {
  await page.goto(`${clientBaseURL}/start`);
  await expect(page).toHaveURL(new RegExp(`^${escapeRegExp(issuer)}/login\\?transaction_id=`));

  await page.getByLabel('Username:').fill('testuser');
  await page.getByLabel('Password:').fill('password');
  await page.getByRole('button', { name: 'Login' }).click();
  await expect(page).toHaveURL(new RegExp(`^${escapeRegExp(issuer)}/consent\\?transaction_id=`));

  await page.getByRole('button', { name: 'Approve' }).click();
  await expect(page).toHaveURL(new RegExp(`^${escapeRegExp(clientBaseURL)}/callback\\?`));

  return locatorText(page.getByTestId('token-access-token'), 'access token');
}

interface DiscoveryMetadata {
  introspection_signing_alg_values_supported?: string[];
}

async function introspectionSigningAlgs(
  request: { get(url: string): Promise<{ json(): Promise<unknown> }> },
  issuer: string,
): Promise<string[]> {
  const response = await request.get(`${issuer}/.well-known/openid-configuration`);
  const metadata = (await response.json()) as DiscoveryMetadata;
  return metadata.introspection_signing_alg_values_supported ?? [];
}

interface JwkSet {
  keys: Array<Record<string, unknown> & { kid?: string }>;
}

interface ParsedJwt {
  header: Record<string, unknown>;
  payload: Record<string, unknown>;
  signingInput: string;
  signature: ArrayBuffer;
}

function parseJwt(jwt: string): ParsedJwt {
  const parts = jwt.split('.');
  if (parts.length !== 3) {
    throw new Error('JWT must have three compact serialization segments');
  }
  const [headerSegment, payloadSegment, signatureSegment] = parts as [string, string, string];
  return {
    header: JSON.parse(base64UrlDecode(headerSegment)),
    payload: JSON.parse(base64UrlDecode(payloadSegment)),
    signingInput: `${headerSegment}.${payloadSegment}`,
    signature: base64UrlToBytes(signatureSegment),
  };
}

async function verifyJwtSignature(jwt: string, jwks: JwkSet): Promise<boolean> {
  const parsed = parseJwt(jwt);
  const kid = requireString(parsed.header.kid, 'introspection JWT kid is required');
  const jwk = requireJwk(jwks, kid);
  const key = await crypto.subtle.importKey(
    'jwk',
    jwk,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['verify'],
  );
  return crypto.subtle.verify(
    'RSASSA-PKCS1-v1_5',
    key,
    parsed.signature,
    new TextEncoder().encode(parsed.signingInput),
  );
}

function requireJwk(jwks: JwkSet, kid: string): Record<string, unknown> {
  const jwk = jwks.keys.find((candidate) => candidate.kid === kid);
  if (jwk === undefined) {
    throw new Error(`No JWK published under kid ${kid}`);
  }
  return jwk;
}

function requireString(value: unknown, message: string): string {
  if (typeof value !== 'string' || value.length === 0) {
    throw new Error(message);
  }
  return value;
}

async function locatorText(locator: Locator, label: string): Promise<string> {
  const value = await locator.textContent();
  if (value === null || value.length === 0) {
    throw new Error(`${label} text is required`);
  }
  return value;
}

function base64UrlDecode(segment: string): string {
  return new TextDecoder().decode(base64UrlToBytes(segment));
}

function base64UrlToBytes(segment: string): ArrayBuffer {
  const bytes = Buffer.from(segment, 'base64url');
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
}

function basicCredentials(id: string, secret: string): string {
  return Buffer.from(`${id}:${secret}`).toString('base64');
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

## References

- [RFC 9701: JWT Response for OAuth Token Introspection](https://www.rfc-editor.org/rfc/rfc9701)
- [RFC 7662: OAuth 2.0 Token Introspection](https://www.rfc-editor.org/rfc/rfc7662)
- [RFC 8725: JSON Web Token Best Current Practices](https://www.rfc-editor.org/rfc/rfc8725)
- Specification task bundle: [tasks/experimental/done/jwt-introspection-response](../../../tasks/experimental/done/jwt-introspection-response)
- User-facing documentation: [the experimental page in docs/library-document](../../../docs/library-document/src/content/docs/experimental/jwt-introspection-response.md)
