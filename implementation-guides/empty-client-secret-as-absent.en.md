# Treating an Empty `client_secret` as Absent: Implementation Guide

This guide covers the client authentication in `@maronn-openid-connect/core` and the contract tests the CLI generates.
The change was implemented from the OSS repository task `tasks/done/p2-client-auth-empty-client-secret-as-absent.md`.

## What this change does

Token Endpoint client authentication now treats a valueless form field (`client_secret=`) as "no credential presented".
RFC 6749 §3.2 states that "Parameters sent without a value MUST be treated as if they were omitted from the request", so an empty `client_secret` must behave the same as an omitted one.

Before this change, `extractClientCredentials` decided presence with `params.client_secret !== undefined`, which counted the empty string as a client_secret_post credential.
That caused two misbehaviors:

1. A public client registered with `token_endpoint_auth_method: none` sending `client_id=x&client_secret=` was classified as method `client_secret_post` and rejected with `invalid_client` for a method mismatch.
2. A request combining `Authorization: Basic` with an empty `client_secret` body field was rejected with `invalid_request` as "multiple authentication methods".

The later steps in the same module (`validateClientAuthMethod` / `verifyClientSecret`) already used falsy checks, treating an empty secret as absent, so the extraction step was the only place with diverging semantics.
This change normalizes the empty string to undefined at the top of extraction, closing that gap.

## Use cases

Client implementations that serialize a whole configuration object into the form body can emit an unset secret as an empty-string field.
Before the change, such a public client could not obtain a token from this OP at all.
Likewise, when a Basic-authenticating client's HTTP stack left an empty `client_secret` field in the body, the request was rejected as multi-method even though only one method was actually used.
In both cases the error messages pointed at method mismatch or multiple methods, which hid the real cause (a stray empty field).

The fix does not weaken security.
When a confidential client sends only an empty `client_secret`, `validateClientAuthMethod` still rejects it with `invalid_client`.
What changes is the rejection reason (method mismatch → authentication required) and that public clients now pass correctly.

## Design decisions

The normalization happens in exactly one place, at the top of `extractClientCredentials`.
The study material also considered switching each individual check to truthy comparisons; the result would be identical, but the spec-level semantics ("no value means omitted") would be invisible in the code, so the single normalization point was chosen.
The multi-method check, the method classification, and the extracted result all read the normalized value, which together with the falsy checks downstream aligns the whole module.

Two things are intentionally out of scope.
First, an empty `client_id` is not normalized: it already falls into the "authentication required" rejection via `!clientId`, so behavior is unchanged and there is no reason to touch it.
Second, an empty secret inside the Basic header (`base64(client:)`) keeps its behavior: §3.2 applies to request parameters, and the Basic header is not a parameter.
That path is still rejected by the constant-time comparison in `verifyClientSecret`.

Both core and cli are patch releases.
Core is a conformance bug fix with no API additions or changes; cli only changes the generated contract tests.
The repository's release contract does not allow the peer range lower bound to stay below the next core version (0.4.1) even for a patch, so the core peer range lower bounds of `experimental` and `google-login` were raised to `>=0.4.1`, each with a patch changeset.

## Changed code in core

### packages/core/src/client-auth.ts: extractClientCredentials

The full function after the change follows.
The `postSecret` constant at the top is the new normalization; every later check reads it.

```typescript
/**
 * ステップ 1: リクエストからクライアント資格情報を抽出する
 * OAuth 2.1 Section 2.3 / OIDC Core 1.0 Section 9
 *
 * - `Authorization: Basic` → client_secret_basic
 * - ボディの client_id + client_secret → client_secret_post
 * - ボディの client_id のみ → none（public client の識別）
 *
 * OAuth 2.1 §2.3: 1リクエストにつき1つの認証方式のみ使用しなければならない。
 * RFC 6749 §4.1.3: 未認証クライアントも client_id を送らなければならない。
 *
 * @throws {TokenError} invalid_request（複数方式）/ invalid_client（形式不正・client_id 欠落）
 */
export function extractClientCredentials(
  context: Pick<ClientAuthContext, 'params' | 'authorizationHeader'>,
): PresentedClientCredentials {
  const { params, authorizationHeader } = context;

  // RFC 6749 §3.2: "Parameters sent without a value MUST be treated as if they
  // were omitted from the request." 空文字列の client_secret はここで「未提示」に
  // 正規化し、多重方式判定・method 判定・後段検証の意味論を一箇所で揃える。
  const postSecret =
    params.client_secret === '' ? undefined : params.client_secret;

  const hasBasicHeader = hasAuthScheme(authorizationHeader, 'Basic');
  const hasPostCredential =
    params.client_id !== undefined || postSecret !== undefined;

  // RFC 6749 §2.3 / OAuth 2.1 §2.3: 1リクエストで複数の「認証方式」を併用してはいけない。
  // ただし §3.2.1 の client_id 単独送信は自身を識別するための「識別子」であって認証方式ではない。
  // よって多重認証方式の判定はボディの client_secret（client_secret_post の資格情報）の有無のみで行い、
  // Basic ヘッダ + ボディ client_id（secret なし）という多くのクライアントライブラリの実装を拒否しない。
  // 空値の client_secret は資格情報を運ばないため「もう一つの認証方式」に数えない（RFC 6749 §2.3）。
  const hasPostSecret = postSecret !== undefined;
  if (hasBasicHeader && hasPostSecret) {
    throw new TokenError(
      TokenErrorCode.InvalidRequest,
      'Multiple client authentication methods provided. Use either Authorization header or request body, not both.',
    );
  }

  let clientId: string | undefined;
  let clientSecret: string | undefined;

  if (hasBasicHeader) {
    const basic = parseBasicAuth(authorizationHeader);
    if (!basic) {
      throw new TokenError(
        TokenErrorCode.InvalidClient,
        'Invalid Authorization header format',
      );
    }
    // RFC 6749 §3.2.1: Basic と併送された client_id は識別子として許容するが、
    // Basic 側の client_id と食い違う場合は矛盾（クライアント設定ミス／混同）として拒否する。
    if (
      params.client_id !== undefined &&
      params.client_id !== basic.clientId
    ) {
      throw new TokenError(
        TokenErrorCode.InvalidRequest,
        'client_id in request body does not match the Authorization header',
      );
    }
    clientId = basic.clientId;
    clientSecret = basic.clientSecret;
  } else if (hasPostCredential) {
    clientId = params.client_id;
    clientSecret = postSecret;
  }

  // client_id は public / confidential を問わず必須。
  // RFC 6749 §4.1.3: 未認証クライアントは client_id を送らなければならない。
  if (!clientId) {
    throw new TokenError(
      TokenErrorCode.InvalidClient,
      'Client authentication required',
    );
  }

  const method: PresentedClientCredentials['method'] = hasBasicHeader
    ? 'client_secret_basic'
    : clientSecret !== undefined
      ? 'client_secret_post'
      : 'none';

  return { clientId, clientSecret, method };
}
```

Following the normalized value through the function shows the behavior change.
For `client_id=x&client_secret=`, `postSecret` is undefined, so `hasPostSecret` is false, the extracted `clientSecret` is undefined, and the method resolves to `'none'`.
When a Basic header coexists with `client_secret=`, `hasPostSecret` is again false, so the multi-method throw is skipped and the Basic credentials are extracted as usual.

## Tests in core

### packages/core/src/client-auth-steps.test.ts: the four added cases

The following four cases were added to the `extractClientCredentials` describe block.
`basicHeader` and `captureError` are existing helpers in the same file; `confidentialClient` is the existing fixture registered with client_secret_basic.

```typescript
  // RFC 6749 §3.2: Parameters sent without a value MUST be treated as if they
  // were omitted from the request. 空文字列の client_secret は未提示として扱う。
  it('should treat an empty client_secret field as absent for a public client', () => {
    const result = extractClientCredentials({
      params: { client_id: 'public-client', client_secret: '' },
      authorizationHeader: '',
    });

    expect(result).toEqual({
      clientId: 'public-client',
      clientSecret: undefined,
      method: 'none',
    });
  });

  // RFC 6749 §2.3: 空の client_secret は資格情報を運ばないため
  // 「もう一つの認証方式」に当たらず、多重方式の invalid_request にしない。
  it('should not reject Basic authentication combined with an empty client_secret field', () => {
    const result = extractClientCredentials({
      params: { client_secret: '' },
      authorizationHeader: basicHeader('client123', 'secret'),
    });

    expect(result).toEqual({
      clientId: 'client123',
      clientSecret: 'secret',
      method: 'client_secret_basic',
    });
  });

  // 空文字列の client_secret 単独（client_id なし）は何も提示していないのと同じ。
  // RFC 6749 §4.1.3: 未認証クライアントも client_id を送らなければならない。
  it('should require a client identifier when only an empty client_secret is sent', () => {
    const error = captureError(() =>
      extractClientCredentials({
        params: { client_secret: '' },
        authorizationHeader: '',
      }),
    );

    expect(error).toBeInstanceOf(TokenError);
    expect(error?.error).toBe(TokenErrorCode.InvalidClient);
    expect(error?.errorDescription).toBe('Client authentication required');
  });

  // confidential client が空の client_secret を送った場合は method 'none' の未提示となり、
  // 後段 validateClientAuthMethod が「方式不一致」ではなく「認証必須」で拒否する。
  it('should still require authentication when a confidential client sends an empty client_secret', () => {
    const presented = extractClientCredentials({
      params: { client_id: 'client123', client_secret: '' },
      authorizationHeader: '',
    });

    expect(presented).toEqual({
      clientId: 'client123',
      clientSecret: undefined,
      method: 'none',
    });

    const error = captureError(() =>
      validateClientAuthMethod(confidentialClient, presented),
    );

    expect(error).toBeInstanceOf(TokenError);
    expect(error?.error).toBe(TokenErrorCode.InvalidClient);
    expect(error?.errorDescription).toBe('Client authentication required');
  });
```

The third case (no client_id) already passed before the change, but the normalization gives the interpretation "a lone empty secret presents nothing" real meaning, so it is pinned as a regression guard.
The fourth case chains the extraction and validation steps and pins, via error_description, that the rejection reason changed from method mismatch to authentication required.
The existing multi-method rejection (Basic plus a non-empty `client_secret`) remains covered by the pre-existing case `should reject combining the Basic header with body credentials`.

## Code the CLI injects into generated projects

### packages/cli/src/frameworks/hono/templates.ts: tokenEndpointAuthMethodsConformanceBlock

Three cases were added to the "Token Endpoint client authentication methods" describe block of the generated `conformance.test.ts`.
The hono template exports this block and the web-standard template (express / fastify / nextjs) imports it, so a single addition reaches the generated output of all four frameworks.
The code below is the generated test code itself, exactly as it appears in each sample's `conformance.test.ts`; see the Japanese guide for the full listing of all three cases.

The first two cases drive the full authorization code flow (`/authorize` → `/login` → `/consent` → `/token`), mirroring the existing cases in the same block, with only the final token request carrying the shape under test: a public client sending `client_secret=` gets a 200 token response as method `none`, and a Basic-authenticated request with a stray `client_secret=` body field is not rejected as multi-method.

The third case posts directly to `/token` without a flow:

```typescript
    // A confidential client sending only an empty client_secret presents no
    // credential at all, so the rejection reason is 'authentication required',
    // not a method mismatch. Client authentication runs before code validation,
    // so no authorization code flow is needed here.
    it('should still require authentication when a confidential client sends an empty client_secret', async () => {
      const tokenRes = await app.request('/token', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({
          grant_type: 'authorization_code',
          code: 'irrelevant-code',
          redirect_uri: REDIRECT_URI,
          client_id: 'c-conf-basic',
          client_secret: '',
        }).toString(),
      });

      expect(tokenRes.status).toBe(401);
      const tokenBody = await tokenRes.json();
      expect(tokenBody.error).toBe('invalid_client');
      expect(tokenBody.error_description).toBe('Client authentication required');
    });
```

Skipping the flow is possible because the generated token route runs client authentication (steps 1–4) before resolving the authorization code, so a nonexistent code still yields the authentication failure first and the rejection reason can be pinned directly.

The test clients are existing fixtures: `c-public` is registered with `token_endpoint_auth_method: none`, and `c-conf-basic` is a client_secret_basic client with secret `s`.

## Verification

- `pnpm --filter @maronn-openid-connect/core test`: 1179 passed (4 new; 3 of them verified failing before the implementation)
- `pnpm --filter @maronn-openid-connect/cli test`: 1414 passed
- `pnpm --filter ./samples/hono-cloudflare test:conformance`: 318 passed (3 new)
- `pnpm run typecheck` / `pnpm run build` / `pnpm run test:ci` (ci-gate, supply-chain, release-contract, package tests, conformance) all pass
- All four samples regenerated; the diff consists only of the added contract tests and the cliVersion metadata update

The express / fastify / nextjs contract tests are not executed because main has no test runner wired for them yet (the wiring is under review in separate PRs).
The generated test code itself is the same shared block across all four frameworks.
