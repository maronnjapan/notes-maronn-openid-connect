# 生成コード差分: jarm — hono

> 機械生成物です。手で編集しないでください。[パケットの説明に戻る](../README.md)

比較しているもの:

- `a/default-op/...`: `maronn-oidc generate <framework>`（experimental 機能なしのデフォルト構成）
- `b/with-jarm/...`: `maronn-oidc generate <framework> --enable jarm`

この差分が「`--enable jarm` が生成コードに足すものすべて」です。

## サマリ

| 種別 | ファイル |
|---|---|
| 追加 | routes/jarm.ts |
| 変更 | conformance.test.ts, routes/authorize.ts, routes/consent.ts, routes/discovery.ts |
| 削除 | （なし） |

## 差分

````diff
diff --git a/default-op/conformance.test.ts b/with-jarm/conformance.test.ts
index 58258e6..9d521b3 100644
--- a/default-op/conformance.test.ts
+++ b/with-jarm/conformance.test.ts
@@ -415,10 +415,11 @@ describe('generated provider HTTP conformance', () => {
         jwks_uri: 'http://localhost:3000/.well-known/jwks.json',
         userinfo_endpoint: 'http://localhost:3000/userinfo',
         response_types_supported: ['code'],
-        // OAuth 2.0 Multiple Response Type Encoding Practices §2: the code flow
-        // returns the authorization response via query, so the OP advertises
-        // response_modes_supported as exactly ['query'].
-        response_modes_supported: ['query'],
+        // OAuth 2.0 Multiple Response Type Encoding Practices §2 + JARM §4: the
+        // code flow returns the authorization response via query, and this OP was
+        // generated with --enable jarm, so the JWT-secured query modes are
+        // advertised alongside it.
+        response_modes_supported: ['query', 'query.jwt', 'jwt'],
       });
     });
 
@@ -2529,6 +2530,407 @@ describe('generated provider HTTP conformance', () => {
     });
   });
 
+  // EXPERIMENTAL — JWT Secured Authorization Response Mode (JARM). Generated
+  // because this provider was created with --enable jarm. These tests pin the
+  // contract the repository guarantees for the generated JARM responses: change
+  // the behavior and they fail, which is how a customized OP learns it drifted.
+  describe('JWT Secured Authorization Response Mode (JARM)', () => {
+    // RFC 7636 Appendix B example PKCE pair (verifier -> its S256 challenge).
+    const PKCE_VERIFIER = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
+    const PKCE_CHALLENGE_S256 = 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM';
+
+    // Pure helpers: they fetch, parse and verify only. Every assertion lives in
+    // an it(), and none of them branches on the OP's behavior.
+    function relativeFrom(location: string | null): string {
+      const url = new URL(location ?? '', 'http://localhost');
+      return url.pathname + url.search;
+    }
+
+    function csrfFrom(html: string): string {
+      return html.match(/name="csrf_token" value="([^"]+)"/)?.[1] ?? '';
+    }
+
+    function firstCookie(res: Response): string {
+      return (res.headers.get('Set-Cookie') ?? '').split(';')[0] ?? '';
+    }
+
+    function decodeSegment(segment: string): Record<string, unknown> {
+      const base64 = segment.replace(/-/g, '+').replace(/_/g, '/');
+      const padded = base64.padEnd(base64.length + ((4 - (base64.length % 4)) % 4), '=');
+      const bytes = Uint8Array.from(atob(padded), (char) => char.charCodeAt(0));
+      return JSON.parse(new TextDecoder().decode(bytes));
+    }
+
+    function authorizeUrl(overrides: Record<string, string> = {}): string {
+      return '/authorize?' + new URLSearchParams({
+        response_type: 'code',
+        client_id: 'c-conf',
+        redirect_uri: REDIRECT_URI,
+        scope: 'openid',
+        state: 'jarm-state',
+        nonce: 'jarm-nonce',
+        code_challenge: PKCE_CHALLENGE_S256,
+        code_challenge_method: 'S256',
+        ...overrides,
+      }).toString();
+    }
+
+    /**
+     * Drives authorize -> login -> consent and returns the final Location plus
+     * the browser session cookie login handed out (used by the SSO / prompt=none
+     * cases below). The transaction cookie is carried forward exactly as a
+     * browser would, so this works with or without --enable transaction-binding.
+     */
+    async function interactiveFlow(
+      url: string,
+      action: 'approve' | 'deny' = 'approve',
+    ): Promise<{ location: string; sessionCookie: string }> {
+      const authorizeRes = await app.request(url);
+      const loginPath = relativeFrom(authorizeRes.headers.get('Location'));
+      const bindingCookie = firstCookie(authorizeRes);
+      const transactionId =
+        new URL(loginPath, 'http://localhost').searchParams.get('transaction_id') ?? '';
+
+      const loginGet = await app.request(loginPath, { headers: { Cookie: bindingCookie } });
+      const loginRes = await app.request('/login', {
+        method: 'POST',
+        headers: { 'Content-Type': 'application/x-www-form-urlencoded', Cookie: bindingCookie },
+        body: new URLSearchParams({
+          transaction_id: transactionId,
+          csrf_token: csrfFrom(await loginGet.text()),
+          username: 'testuser',
+          password: 'password',
+        }).toString(),
+      });
+      const sessionCookie = firstCookie(loginRes);
+
+      const consentPath = relativeFrom(loginRes.headers.get('Location'));
+      const consentGet = await app.request(consentPath, { headers: { Cookie: bindingCookie } });
+      const consentRes = await app.request('/consent', {
+        method: 'POST',
+        headers: { 'Content-Type': 'application/x-www-form-urlencoded', Cookie: bindingCookie },
+        body: new URLSearchParams({
+          transaction_id: transactionId,
+          csrf_token: csrfFrom(await consentGet.text()),
+          action,
+        }).toString(),
+      });
+
+      return {
+        location: consentRes.headers.get('Location') ?? '',
+        sessionCookie,
+      };
+    }
+
+    function queryOf(location: string): URLSearchParams {
+      return new URL(location, 'http://localhost').searchParams;
+    }
+
+    /**
+     * JARM Section 2.4 / Section 5.1, from the client's side: resolve the key
+     * from the OP's jwks_uri by kid and verify the RS256 signature before any
+     * claim is trusted.
+     */
+    async function inspectJarmJwt(jwt: string): Promise<{
+      header: Record<string, unknown>;
+      payload: Record<string, unknown>;
+      signatureValid: boolean;
+    }> {
+      const [encodedHeader = '', encodedPayload = '', encodedSignature = ''] = jwt.split('.');
+      const header = decodeSegment(encodedHeader);
+      const jwks = await (await app.request('/.well-known/jwks.json')).json();
+      const jwk = (jwks.keys as Array<Record<string, unknown>>).find(
+        (candidate) => candidate.kid === header.kid,
+      );
+      const key = await crypto.subtle.importKey(
+        'jwk',
+        { kty: 'RSA', n: jwk?.n as string, e: jwk?.e as string },
+        { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
+        false,
+        ['verify'],
+      );
+      const base64 = encodedSignature.replace(/-/g, '+').replace(/_/g, '/');
+      const padded = base64.padEnd(base64.length + ((4 - (base64.length % 4)) % 4), '=');
+      const signatureValid = await crypto.subtle.verify(
+        'RSASSA-PKCS1-v1_5',
+        key,
+        Uint8Array.from(atob(padded), (char) => char.charCodeAt(0)),
+        new TextEncoder().encode(encodedHeader + '.' + encodedPayload),
+      );
+      return { header, payload: decodeSegment(encodedPayload), signatureValid };
+    }
+
+    describe('Signing key selection (JARM Section 3)', () => {
+      // A SigningKeyProvider may legitimately return an ES256 active key next to
+      // a registered set that also holds RS256 — packages/core's
+      // SigningKeyProvider contract documents alternate-alg key sets, and only
+      // the SET is required to contain RS256 (OIDC Core 1.0 Section 15.1). The
+      // JARM response JWT always declares alg RS256, so it must be signed with
+      // the RS256 key from that set: signing it with whichever key happens to be
+      // active would make Web Crypto refuse and break the authorization response
+      // delivery path for every client that asked for a JWT response mode.
+      it('should sign with the registered RS256 key when the active key is ES256', async () => {
+        const rs256Pair = await crypto.subtle.generateKey(
+          { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
+          true,
+          ['sign', 'verify'],
+        );
+        const es256Pair = await crypto.subtle.generateKey(
+          { name: 'ECDSA', namedCurve: 'P-256' },
+          true,
+          ['sign', 'verify'],
+        );
+        const rs256Key: SigningKey = {
+          privateKey: rs256Pair.privateKey,
+          publicJwk: await crypto.subtle.exportKey('jwk', rs256Pair.publicKey),
+          keyId: 'mixed-rs256',
+        };
+        const es256Key: SigningKey = {
+          privateKey: es256Pair.privateKey,
+          publicJwk: await crypto.subtle.exportKey('jwk', es256Pair.publicKey),
+          keyId: 'mixed-es256',
+        };
+        const mixedProvider: SigningKeyProvider = {
+          // Active key is the ES256 one; the registered set holds both.
+          async getSigningKey(): Promise<SigningKey> {
+            return es256Key;
+          },
+          async getSigningKeys(): Promise<SigningKey[]> {
+            return [rs256Key, es256Key];
+          },
+        };
+        const mixedApp = createApp({
+          signingKeyProvider: mixedProvider,
+          clientResolver: createInMemoryClientResolver(testClients),
+        });
+
+        // OIDC Core 1.0 Section 3.1.2.1: prompt=none with no session is
+        // login_required — a redirectable error, so it is answered in JARM mode
+        // straight from the authorize route, with no interaction to drive.
+        const res = await mixedApp.request(
+          authorizeUrl({ response_mode: 'query.jwt', prompt: 'none' }),
+        );
+        const location = res.headers.get('Location') ?? '';
+        const jwt = queryOf(location).get('response') ?? '';
+        const [encodedHeader = '', encodedPayload = '', encodedSignature = ''] = jwt.split('.');
+        const base64 = encodedSignature.replace(/-/g, '+').replace(/_/g, '/');
+        const padded = base64.padEnd(base64.length + ((4 - (base64.length % 4)) % 4), '=');
+        const signatureValid = await crypto.subtle.verify(
+          'RSASSA-PKCS1-v1_5',
+          rs256Pair.publicKey,
+          Uint8Array.from(atob(padded), (char) => char.charCodeAt(0)),
+          new TextEncoder().encode(encodedHeader + '.' + encodedPayload),
+        );
+
+        expect([...queryOf(location).keys()]).toEqual(['response']);
+        expect(decodeSegment(encodedHeader)).toEqual({ alg: 'RS256', kid: 'mixed-rs256' });
+        expect(signatureValid).toBe(true);
+        expect(decodeSegment(encodedPayload).error).toBe('login_required');
+      });
+    });
+
+    describe('Success response (JARM Section 2.3.1)', () => {
+      it('should deliver the authorization response as the only response query parameter', async () => {
+        const { location } = await interactiveFlow(authorizeUrl({ response_mode: 'query.jwt' }));
+
+        // JARM Section 2.3.1: the response is carried by a single `response`
+        // parameter. The plain code / state / iss parameters MUST NOT be added —
+        // the JWT's iss claim replaces RFC 9207's iss parameter.
+        expect([...queryOf(location).keys()]).toEqual(['response']);
+      });
+
+      it('should sign the response JWT with RS256 under a kid published in JWKS', async () => {
+        const { location } = await interactiveFlow(authorizeUrl({ response_mode: 'query.jwt' }));
+        const inspected = await inspectJarmJwt(queryOf(location).get('response') ?? '');
+
+        // JARM Section 3: RS256 is the default (and here the only) algorithm.
+        // No typ header: JARM does not define one and its Section 2.3.1 example
+        // header carries only kid and alg.
+        expect(inspected.header).toEqual({ alg: 'RS256', kid: 'test-key' });
+        expect(inspected.signatureValid).toBe(true);
+      });
+
+      it('should carry exactly iss, aud, exp, code and state as claims', async () => {
+        const { location } = await interactiveFlow(authorizeUrl({ response_mode: 'query.jwt' }));
+        const { payload } = await inspectJarmJwt(queryOf(location).get('response') ?? '');
+
+        // JARM Section 2.1: iss / aud / exp are REQUIRED and the authorization
+        // response parameters travel as claims of the same JWT. The claim set is
+        // pinned whole so an added claim (a PII leak, for instance) fails here.
+        expect(Object.keys(payload).sort()).toEqual(['aud', 'code', 'exp', 'iss', 'state']);
+        expect(payload.iss).toBe('http://localhost:3000');
+        expect(payload.aud).toBe('c-conf');
+        expect(payload.state).toBe('jarm-state');
+      });
+
+      it('should exchange the code carried by the response JWT for tokens', async () => {
+        const { location } = await interactiveFlow(authorizeUrl({ response_mode: 'query.jwt' }));
+        const { payload } = await inspectJarmJwt(queryOf(location).get('response') ?? '');
+        const res = await app.request('/token', {
+          method: 'POST',
+          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
+          body: new URLSearchParams({
+            grant_type: 'authorization_code',
+            code: String(payload.code ?? ''),
+            redirect_uri: REDIRECT_URI,
+            client_id: 'c-conf',
+            client_secret: 's',
+            code_verifier: PKCE_VERIFIER,
+          }).toString(),
+        });
+
+        // JARM changes only how the response is delivered; the code itself is an
+        // ordinary authorization code and the token endpoint is untouched.
+        expect(res.status).toBe(200);
+        expect((await res.json()).token_type).toBe('Bearer');
+      });
+
+      it('should treat the jwt shorthand as query.jwt', async () => {
+        // JARM Section 2.3.4: for response_type=code the default JWT delivery
+        // mode is query.jwt, so the `jwt` shorthand means exactly that.
+        const { location } = await interactiveFlow(authorizeUrl({ response_mode: 'jwt' }));
+        const { payload, signatureValid } = await inspectJarmJwt(
+          queryOf(location).get('response') ?? '',
+        );
+
+        expect([...queryOf(location).keys()]).toEqual(['response']);
+        expect(signatureValid).toBe(true);
+        expect(Object.keys(payload).sort()).toEqual(['aud', 'code', 'exp', 'iss', 'state']);
+      });
+    });
+
+    describe('Error response (JARM Section 2.1)', () => {
+      it('should return a signed error JWT when the End-User denies consent', async () => {
+        const { location } = await interactiveFlow(
+          authorizeUrl({ response_mode: 'query.jwt' }),
+          'deny',
+        );
+        const { payload, signatureValid } = await inspectJarmJwt(
+          queryOf(location).get('response') ?? '',
+        );
+
+        expect([...queryOf(location).keys()]).toEqual(['response']);
+        expect(signatureValid).toBe(true);
+        expect(Object.keys(payload).sort()).toEqual(['aud', 'error', 'exp', 'iss', 'state']);
+        expect(payload.error).toBe('access_denied');
+        expect(payload.state).toBe('jarm-state');
+      });
+
+      it('should return a signed error JWT for a prompt=none request with no session', async () => {
+        // OIDC Core 1.0 Section 3.1.2.1: prompt=none without a session is
+        // login_required. It is a redirectable error, so JARM applies to it.
+        const res = await app.request(
+          authorizeUrl({ response_mode: 'query.jwt', prompt: 'none' }),
+        );
+        const { payload, signatureValid } = await inspectJarmJwt(
+          queryOf(res.headers.get('Location') ?? '').get('response') ?? '',
+        );
+
+        expect([...queryOf(res.headers.get('Location') ?? '').keys()]).toEqual(['response']);
+        expect(signatureValid).toBe(true);
+        expect(payload.error).toBe('login_required');
+        expect(payload.state).toBe('jarm-state');
+      });
+    });
+
+    describe('Unsupported JWT response modes', () => {
+      // JARM Section 2.3.2 / Section 2.3.3 exist in the specification but are not
+      // implemented by this OP (response_type=code only, no auto-submitting form).
+      // The rejection itself is a PLAIN query error: the OP cannot answer in a
+      // response mode it does not implement.
+      it('should reject fragment.jwt with a plain invalid_request redirect', async () => {
+        const res = await app.request(authorizeUrl({ response_mode: 'fragment.jwt' }));
+        const query = queryOf(res.headers.get('Location') ?? '');
+
+        expect(res.status).toBe(302);
+        expect([...query.keys()].sort()).toEqual(['error', 'error_description', 'iss', 'state']);
+        expect(query.get('error')).toBe('invalid_request');
+        expect(query.get('error_description')).toBe('response_mode fragment.jwt is not supported');
+        expect(query.get('state')).toBe('jarm-state');
+      });
+
+      it('should reject form_post.jwt with a plain invalid_request redirect', async () => {
+        const res = await app.request(authorizeUrl({ response_mode: 'form_post.jwt' }));
+        const query = queryOf(res.headers.get('Location') ?? '');
+
+        expect(query.get('error')).toBe('invalid_request');
+        expect(query.get('error_description')).toBe('response_mode form_post.jwt is not supported');
+      });
+    });
+
+    describe('Unchanged behavior without a JWT response mode', () => {
+      it('should return the plain query response when response_mode is absent', async () => {
+        const { location } = await interactiveFlow(authorizeUrl());
+
+        // The whole point of the isolation: enabling JARM must not change the
+        // response for a client that did not ask for it.
+        expect([...queryOf(location).keys()].sort()).toEqual(['code', 'iss', 'state']);
+        expect(queryOf(location).get('iss')).toBe('http://localhost:3000');
+      });
+
+      it('should keep ignoring a non-JWT response_mode value', async () => {
+        // form_post is not implemented and never was; JARM only adds meaning to
+        // the .jwt family, so this request is answered exactly as before.
+        const { location } = await interactiveFlow(authorizeUrl({ response_mode: 'form_post' }));
+
+        expect([...queryOf(location).keys()].sort()).toEqual(['code', 'iss', 'state']);
+      });
+    });
+
+    describe('Transaction store round trip', () => {
+      // The authorize route records the mode on the transaction and the consent
+      // route reads it back, so a store that drops unknown fields would answer in
+      // plain query. These paths, by contrast, answer inside the authorize route
+      // itself and never touch the store round trip.
+      it('should answer the SSO fast path with a signed JWT', async () => {
+        const first = await interactiveFlow(
+          authorizeUrl({ response_mode: 'query.jwt', prompt: 'consent' }),
+        );
+        const res = await app.request(authorizeUrl({ response_mode: 'query.jwt' }), {
+          headers: { Cookie: first.sessionCookie },
+        });
+        const { header, payload, signatureValid } = await inspectJarmJwt(
+          queryOf(res.headers.get('Location') ?? '').get('response') ?? '',
+        );
+
+        expect([...queryOf(res.headers.get('Location') ?? '').keys()]).toEqual(['response']);
+        // JARM Section 3: the authorize route signs with the RS256 key selected
+        // from the registered key set, not with whichever key happens to be
+        // active, so the alg header always matches the key that produced it.
+        expect(header).toEqual({ alg: 'RS256', kid: 'test-key' });
+        expect(signatureValid).toBe(true);
+        expect(Object.keys(payload).sort()).toEqual(['aud', 'code', 'exp', 'iss', 'state']);
+      });
+
+      it('should answer a prompt=none success with a signed JWT', async () => {
+        const first = await interactiveFlow(
+          authorizeUrl({ response_mode: 'query.jwt', prompt: 'consent' }),
+        );
+        const res = await app.request(
+          authorizeUrl({ response_mode: 'query.jwt', prompt: 'none' }),
+          { headers: { Cookie: first.sessionCookie } },
+        );
+        const { header, payload, signatureValid } = await inspectJarmJwt(
+          queryOf(res.headers.get('Location') ?? '').get('response') ?? '',
+        );
+
+        expect([...queryOf(res.headers.get('Location') ?? '').keys()]).toEqual(['response']);
+        expect(header).toEqual({ alg: 'RS256', kid: 'test-key' });
+        expect(signatureValid).toBe(true);
+        expect(Object.keys(payload).sort()).toEqual(['aud', 'code', 'exp', 'iss', 'state']);
+      });
+    });
+
+    describe('Discovery metadata (JARM Section 4)', () => {
+      it('should advertise the JWT response modes and the response signing algorithm', async () => {
+        const metadata = await (await app.request('/.well-known/openid-configuration')).json();
+
+        expect(metadata.response_modes_supported).toEqual(['query', 'query.jwt', 'jwt']);
+        expect(metadata.authorization_signing_alg_values_supported).toEqual(['RS256']);
+      });
+    });
+  });
+
   describe('Consent decision value (OIDC Core 1.0 §3.1.2.4)', () => {
     const DECISION_PKCE_CHALLENGE = 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM';
 
diff --git a/default-op/routes/authorize.ts b/with-jarm/routes/authorize.ts
index a3ffab2..c9be0d0 100644
--- a/default-op/routes/authorize.ts
+++ b/with-jarm/routes/authorize.ts
@@ -29,6 +29,9 @@ import {
   IdTokenHintError,
   type AuthorizationRequestParams,
   type JwkSet,
+  AuthorizationErrorCode,
+  selectSigningKeyByAlg,
+  type SigningKey,
 } from '@maronn-openid-connect/core';
 import { clientResolver as defaultClientResolver } from '../resolvers.js';
 import {
@@ -37,6 +40,12 @@ import {
   authSessionStore as defaultAuthSessionStore,
 } from '../store.js';
 import { defaultViews, renderView } from '../views.js';
+import {
+  buildJarmRedirectUrl,
+  createJarmResponseJwt,
+  resolveJarmResponseMode,
+} from '@maronn-openid-connect/experimental/jarm';
+import { jarmConfig } from './jarm.js';
 
 export const authorizeApp = new Hono<{ Variables: Record<string, any> }>();
 
@@ -53,6 +62,19 @@ function isAuthorizationRequestParams(
   return typeof p['client_id'] === 'string';
 }
 
+/**
+ * EXPERIMENTAL — JARM response context (JARM Section 2.1).
+ *
+ * Present only for a request that asked for response_mode=query.jwt (or its
+ * `jwt` shorthand). undefined means the plain query response this OP has always
+ * produced, so a client that does not ask for JARM sees no change at all.
+ */
+type JarmResponseContext = {
+  issuer: string;
+  clientId: string;
+  signingKey: SigningKey;
+};
+
 /**
  * Builds a redirect URL with an OAuth error response.
  * OIDC Core 1.0 Section 3.1.2.6 / RFC 6749 Section 4.1.2.1.
@@ -61,26 +83,84 @@ function isAuthorizationRequestParams(
  * Section 5.2 allowed character set before being appended so user-controlled
  * fragments cannot smuggle control bytes into the redirect URL.
  *
- * RFC 9207 §2: when issuer is provided, the iss parameter is appended so the
- * client can pin the issuer that produced this authorization response.
+ * RFC 9207 Section 2: when issuer is provided, the iss parameter is appended so
+ * the client can pin the issuer that produced this authorization response.
+ *
+ * EXPERIMENTAL (JARM Section 2.1 / 2.3.1): when jarm is present the very same
+ * parameters travel as claims of one signed JWT in the `response` query
+ * parameter instead, and no plain error / error_description / state / iss
+ * parameter is added — the JWT's iss claim identifies the issuer (RFC 9700
+ * Section 2.1 accepts JARM as the issuer-identification mechanism).
  */
-function buildErrorRedirect(
+async function buildErrorRedirect(
+  jarm: JarmResponseContext | undefined,
   redirectUri: string,
   error: string,
   state?: string,
   errorDescription?: string,
   issuer?: string,
-): string {
+): Promise<string> {
+  // RFC 6749 Section 5.2: sanitize once, for both response shapes.
+  const description = errorDescription
+    ? sanitizeErrorDescription(errorDescription)
+    : undefined;
+  if (jarm) {
+    return buildJarmRedirectUrl(
+      redirectUri,
+      await createJarmResponseJwt({
+        issuer: jarm.issuer,
+        clientId: jarm.clientId,
+        parameters: { error, error_description: description, state },
+        signingKey: jarm.signingKey,
+        lifetimeSeconds: jarmConfig.jarmResponseLifetimeSeconds,
+      }),
+    );
+  }
   const url = new URL(redirectUri);
   url.searchParams.set('error', error);
-  if (errorDescription) {
-    url.searchParams.set('error_description', sanitizeErrorDescription(errorDescription));
+  if (description) {
+    url.searchParams.set('error_description', description);
   }
   if (state) url.searchParams.set('state', state);
   if (issuer) url.searchParams.set('iss', issuer);
   return url.toString();
 }
 
+/**
+ * Builds the success redirect URL carrying the authorization code.
+ * OIDC Core 1.0 Section 3.1.2.5 / RFC 9207 Section 2 (iss).
+ *
+ * EXPERIMENTAL (JARM Section 2.3.1): when jarm is present the code and state
+ * become claims of a signed JWT delivered as the single `response` parameter;
+ * no plain code / state / iss parameter is added.
+ */
+async function buildSuccessRedirect(
+  jarm: JarmResponseContext | undefined,
+  redirectUri: string,
+  code: string,
+  state: string | undefined,
+  issuer: string,
+): Promise<string> {
+  if (jarm) {
+    return buildJarmRedirectUrl(
+      redirectUri,
+      await createJarmResponseJwt({
+        issuer: jarm.issuer,
+        clientId: jarm.clientId,
+        parameters: { code, state },
+        signingKey: jarm.signingKey,
+        lifetimeSeconds: jarmConfig.jarmResponseLifetimeSeconds,
+      }),
+    );
+  }
+  const url = new URL(redirectUri);
+  url.searchParams.set('code', code);
+  if (state) url.searchParams.set('state', state);
+  // RFC 9207 Section 2: include iss in success responses.
+  url.searchParams.set('iss', issuer);
+  return url.toString();
+}
+
 /**
  * Iterates URLSearchParams and reports the first repeated key, if any.
  * OIDC Core 1.0 §3.1.2.1 / RFC 6749 §3.1: authorization request parameters
@@ -148,6 +228,10 @@ const handleAuthorizationRequest = async (c: any) => {
   }
 
   const params = rawParams;
+  // EXPERIMENTAL — JARM §2.3. Set once redirect_uri is verified; undefined means
+  // the plain query response. Every authorize-route response site below reads
+  // this local, so none of them depends on the transaction store round-trip.
+  let jarmResponse: JarmResponseContext | undefined;
 
   try {
     const clientResolver = c.get('clientResolver') ?? defaultClientResolver;
@@ -189,6 +273,49 @@ const handleAuthorizationRequest = async (c: any) => {
     // RFC 6749 §4.1.2.1: state is echoed only on redirectable errors from here on.
     const state = effectiveParams.state;
 
+    // EXPERIMENTAL — JARM §2.3: interpret response_mode now that redirect_uri is
+    // verified, so an unsupported JWT mode can be reported as a redirectable
+    // error. Values outside the `.jwt` family stay ignored exactly as before.
+    const jarmResolution = resolveJarmResponseMode(effectiveParams);
+    if (jarmResolution.kind === 'unsupported-jwt-mode') {
+      // JARM §2.3.2 / §2.3.3 (fragment.jwt / form_post.jwt) are not implemented
+      // here. The rejection itself goes back as a PLAIN query error: the OP
+      // cannot answer in a response mode it does not implement.
+      throw new AuthorizationError(
+        AuthorizationErrorCode.InvalidRequest,
+        'response_mode ' + jarmResolution.requested + ' is not supported',
+        redirectUri,
+        state,
+      );
+    }
+    if (jarmResolution.kind === 'jarm') {
+      // JARM §3: this OP declares alg RS256 on every response JWT (the default
+      // for a client that registered no authorization_signed_response_alg), and
+      // discovery advertises authorization_signing_alg_values_supported:
+      // ['RS256']. The general-purpose ACTIVE key is not guaranteed to be RS256 —
+      // SigningKeyProvider may legitimately return ES256 as active alongside an
+      // RS256 + ES256 registered set — so the key is picked by alg from the
+      // registered set. Its public half is published at /.well-known/jwks.json
+      // under the same kid. selectSigningKeyByAlg throws when no RS256 key is
+      // registered, which surfaces as a server_error here (a configuration
+      // mistake) rather than as an unverifiable authorization response.
+      const jarmSigningKeys = (c.get('signingKeys') as SigningKey[] | undefined) ?? [];
+      jarmResponse = {
+        issuer,
+        clientId: client.clientId,
+        // Falls back to the single-key context so a hand-wired provider that
+        // never populated the key set keeps working; on the default single
+        // RS256 key both branches resolve the same key.
+        signingKey: jarmSigningKeys.length > 0
+          ? selectSigningKeyByAlg(jarmSigningKeys, 'RS256')
+          : {
+              privateKey: c.get('privateKey'),
+              publicJwk: c.get('publicJwk'),
+              keyId: c.get('keyId'),
+            },
+      };
+    }
+
     // OIDC Core 1.0 §6.3: request_uri / registration are not supported here.
     rejectUnsupportedRequestParams(params, redirectUri, state);
 
@@ -270,7 +397,7 @@ const handleAuthorizationRequest = async (c: any) => {
     const transactionTtlSeconds = 10 * 60; // 10 minutes TTL
     await transactionStore.put(
       'auth_txn:' + transactionId,
-      transaction,
+      jarmResponse ? { ...transaction, jarmResponseMode: 'query.jwt' } : transaction,
       transactionTtlSeconds,
     );
 
@@ -280,7 +407,7 @@ const handleAuthorizationRequest = async (c: any) => {
     // prompt=none must not be combined with other values (OIDC Core 1.0 Section 3.1.2.1)
     if (promptValues.includes('none') && promptValues.length > 1) {
       await transactionStore.delete('auth_txn:' + transactionId);
-      return c.redirect(buildErrorRedirect(transaction.redirectUri, 'invalid_request', transaction.state, 'prompt=none must not be combined with other prompt values', issuer));
+      return c.redirect(await buildErrorRedirect(jarmResponse, transaction.redirectUri, 'invalid_request', transaction.state, 'prompt=none must not be combined with other prompt values', issuer));
     }
 
     // OIDC Core 1.0 §3.1.2.1: the id_token_hint rule ("if the End-User identified
@@ -296,7 +423,7 @@ const handleAuthorizationRequest = async (c: any) => {
       if (!jwksProvider) {
         // jwksProvider 未提供では hint を検証できない → login_required で拒否
         await transactionStore.delete('auth_txn:' + transactionId);
-        return c.redirect(buildErrorRedirect(transaction.redirectUri, 'login_required', transaction.state, 'jwksProvider is not configured; cannot verify id_token_hint', issuer));
+        return c.redirect(await buildErrorRedirect(jarmResponse, transaction.redirectUri, 'login_required', transaction.state, 'jwksProvider is not configured; cannot verify id_token_hint', issuer));
       }
       try {
         const jwks = await jwksProvider();
@@ -309,7 +436,7 @@ const handleAuthorizationRequest = async (c: any) => {
       } catch (hintError) {
         await transactionStore.delete('auth_txn:' + transactionId);
         const code = hintError instanceof IdTokenHintError ? hintError.error : 'login_required';
-        return c.redirect(buildErrorRedirect(transaction.redirectUri, code, transaction.state, hintError instanceof Error && hintError.message ? hintError.message : 'id_token_hint verification failed', issuer));
+        return c.redirect(await buildErrorRedirect(jarmResponse, transaction.redirectUri, code, transaction.state, hintError instanceof Error && hintError.message ? hintError.message : 'id_token_hint verification failed', issuer));
       }
     }
 
@@ -322,14 +449,14 @@ const handleAuthorizationRequest = async (c: any) => {
       // No sessionResolver configured → cannot verify session → login_required
       if (!sessionResolver) {
         await transactionStore.delete('auth_txn:' + transactionId);
-        return c.redirect(buildErrorRedirect(transaction.redirectUri, 'login_required', transaction.state, 'sessionResolver is not configured; cannot satisfy prompt=none', issuer));
+        return c.redirect(await buildErrorRedirect(jarmResponse, transaction.redirectUri, 'login_required', transaction.state, 'sessionResolver is not configured; cannot satisfy prompt=none', issuer));
       }
 
       // No consentResolver configured → cannot confirm consent → consent_required
       // (OIDC Core 1.0 Section 3.1.2.1: prompt=none must not display consent screen)
       if (!consentResolver) {
         await transactionStore.delete('auth_txn:' + transactionId);
-        return c.redirect(buildErrorRedirect(transaction.redirectUri, 'consent_required', transaction.state, 'consentResolver is not configured; cannot satisfy prompt=none', issuer));
+        return c.redirect(await buildErrorRedirect(jarmResponse, transaction.redirectUri, 'consent_required', transaction.state, 'consentResolver is not configured; cannot satisfy prompt=none', issuer));
       }
 
       let session;
@@ -356,20 +483,20 @@ const handleAuthorizationRequest = async (c: any) => {
       } catch (promptError) {
         await transactionStore.delete('auth_txn:' + transactionId);
         if (promptError instanceof AuthorizationError) {
-          return c.redirect(buildErrorRedirect(transaction.redirectUri, promptError.error, transaction.state, promptError.errorDescription, issuer));
+          return c.redirect(await buildErrorRedirect(jarmResponse, transaction.redirectUri, promptError.error, transaction.state, promptError.errorDescription, issuer));
         }
         const serverDescription =
           promptError instanceof Error && promptError.message
             ? promptError.message
             : 'Unexpected error while evaluating prompt=none';
-        return c.redirect(buildErrorRedirect(transaction.redirectUri, 'server_error', transaction.state, serverDescription, issuer));
+        return c.redirect(await buildErrorRedirect(jarmResponse, transaction.redirectUri, 'server_error', transaction.state, serverDescription, issuer));
       }
 
       // Check max_age: if session is too old, prompt=none cannot trigger re-authentication
       // OIDC Core 1.0 Section 3.1.2.1
       if (transaction.maxAge !== undefined && requiresReauthentication(transaction.maxAge, session.authTime)) {
         await transactionStore.delete('auth_txn:' + transactionId);
-        return c.redirect(buildErrorRedirect(transaction.redirectUri, 'login_required', transaction.state, 'Session exceeds the requested max_age; re-authentication required', issuer));
+        return c.redirect(await buildErrorRedirect(jarmResponse, transaction.redirectUri, 'login_required', transaction.state, 'Session exceeds the requested max_age; re-authentication required', issuer));
       }
 
       // transaction.scope は認可リクエスト検証時に applyOfflineAccessPolicy を通した
@@ -401,12 +528,15 @@ const handleAuthorizationRequest = async (c: any) => {
         authCodeData.grantId,
       );
 
-      const redirectUrl = new URL(transaction.redirectUri);
-      redirectUrl.searchParams.set('code', authCodeData.code);
-      if (transaction.state) redirectUrl.searchParams.set('state', transaction.state);
-      // RFC 9207 §2: include iss in success responses too.
-      redirectUrl.searchParams.set('iss', issuer);
-      return c.redirect(redirectUrl.toString());
+      return c.redirect(
+        await buildSuccessRedirect(
+          jarmResponse,
+          transaction.redirectUri,
+          authCodeData.code,
+          transaction.state,
+          issuer,
+        ),
+      );
     }
 
     // OIDC Core 1.0 Section 3.1.2.3: an active OP session enables Single Sign-On.
@@ -473,12 +603,15 @@ const handleAuthorizationRequest = async (c: any) => {
               authCodeData.grantId,
             );
 
-            const redirectUrl = new URL(transaction.redirectUri);
-            redirectUrl.searchParams.set('code', authCodeData.code);
-            if (transaction.state) redirectUrl.searchParams.set('state', transaction.state);
-            // RFC 9207 §2: include iss in success responses.
-            redirectUrl.searchParams.set('iss', issuer);
-            return c.redirect(redirectUrl.toString());
+            return c.redirect(
+              await buildSuccessRedirect(
+                jarmResponse,
+                transaction.redirectUri,
+                authCodeData.code,
+                transaction.state,
+                issuer,
+              ),
+            );
           }
 
           const authSessionStore = c.get('authSessionStore') ?? defaultAuthSessionStore;
@@ -503,20 +636,24 @@ const handleAuthorizationRequest = async (c: any) => {
   } catch (error) {
     if (error instanceof AuthorizationError) {
       if (error.redirectUri) {
-        const redirectUrl = new URL(error.redirectUri);
-        redirectUrl.searchParams.set('error', error.error);
-        if (error.errorDescription) {
-          redirectUrl.searchParams.set('error_description', error.errorDescription);
-        }
-        if (error.state) {
-          redirectUrl.searchParams.set('state', error.state);
-        }
         // RFC 9207 §2: include iss on error redirects so the client can
         // pin the issuer. config has already been read into context by
         // middleware; reread it here because the early-bound issuer is
-        // scoped to the try block.
-        redirectUrl.searchParams.set('iss', c.get('config').issuer);
-        return c.redirect(redirectUrl.toString());
+        // scoped to the try block. EXPERIMENTAL (JARM §2.1): when this request
+        // asked for a JWT response mode, the same members become claims of a
+        // signed JWT and no plain parameter is added. jarmResponse is undefined
+        // for errors thrown before response_mode was interpreted (unknown
+        // client, unsupported JWT mode), which is why those stay plain.
+        return c.redirect(
+          await buildErrorRedirect(
+            jarmResponse,
+            error.redirectUri,
+            error.error,
+            error.state,
+            error.errorDescription,
+            c.get('config').issuer,
+          ),
+        );
       }
       // OIDC Core 1.0 §3.1.2.2: errors that cannot be redirected (unknown
       // client_id, unregistered redirect_uri, redirect_uri with a fragment) MUST
diff --git a/default-op/routes/consent.ts b/with-jarm/routes/consent.ts
index 41d7d41..83b82e2 100644
--- a/default-op/routes/consent.ts
+++ b/with-jarm/routes/consent.ts
@@ -4,6 +4,9 @@ import {
   validateCsrfToken,
   completeAuthTransaction,
   createAuthorizationCode,
+  selectSigningKeyByAlg,
+  type AuthTransaction,
+  type SigningKey,
 } from '@maronn-openid-connect/core';
 import {
   consentResolver as defaultConsentResolver,
@@ -14,9 +17,89 @@ import {
   authSessionStore as defaultAuthSessionStore,
 } from '../store.js';
 import { defaultViews, renderView } from '../views.js';
+import {
+  buildJarmRedirectUrl,
+  createJarmResponseJwt,
+  type JarmAuthTransactionFields,
+} from '@maronn-openid-connect/experimental/jarm';
+import { jarmConfig } from './jarm.js';
 
 export const consentApp = new Hono<{ Variables: Record<string, any> }>();
 
+/**
+ * EXPERIMENTAL — JARM (JWT Secured Authorization Response Mode).
+ *
+ * The authorize route recorded the requested response mode on the transaction
+ * (jarmResponseMode). This route only ever sees the transaction it read back
+ * from the store, so the auth transaction store MUST persist fields it does not
+ * know about — otherwise a client that asked for a JWT response silently gets a
+ * plain query response instead. conformance.test.ts pins that round trip.
+ */
+function resolveJarmResponse(
+  c: any,
+  transaction: AuthTransaction & JarmAuthTransactionFields,
+): JarmResponseContext | undefined {
+  if (transaction.jarmResponseMode !== 'query.jwt') return undefined;
+  // JARM Section 3: the response JWT always declares alg RS256, so the key is
+  // picked by alg from the registered key set rather than taken from the
+  // general-purpose ACTIVE key, which the SigningKeyProvider contract does not
+  // guarantee to be RS256. Its public half is published at
+  // /.well-known/jwks.json under the same kid. The single-key context is kept as
+  // a fallback for providers that never populated the key set; on the default
+  // single RS256 key both branches resolve the same key.
+  const jarmSigningKeys = (c.get('signingKeys') as SigningKey[] | undefined) ?? [];
+  return {
+    issuer: c.get('config').issuer,
+    clientId: transaction.clientId,
+    signingKey: jarmSigningKeys.length > 0
+      ? selectSigningKeyByAlg(jarmSigningKeys, 'RS256')
+      : {
+          privateKey: c.get('privateKey'),
+          publicJwk: c.get('publicJwk'),
+          keyId: c.get('keyId'),
+        },
+  };
+}
+
+type JarmResponseContext = {
+  issuer: string;
+  clientId: string;
+  signingKey: SigningKey;
+};
+
+/**
+ * EXPERIMENTAL — JARM Section 2.3.1: deliver the authorization response as the
+ * single `response` query parameter holding a signed JWT. Without a JARM
+ * transaction this is the plain query response the OP has always produced
+ * (RFC 9207 Section 2 appends iss; in JARM mode the JWT's iss claim carries the
+ * same statement, so no plain iss parameter is added).
+ */
+async function buildConsentRedirect(
+  jarm: JarmResponseContext | undefined,
+  redirectUri: string,
+  parameters: Record<string, string | undefined>,
+  issuer: string,
+): Promise<string> {
+  if (jarm) {
+    return buildJarmRedirectUrl(
+      redirectUri,
+      await createJarmResponseJwt({
+        issuer: jarm.issuer,
+        clientId: jarm.clientId,
+        parameters,
+        signingKey: jarm.signingKey,
+        lifetimeSeconds: jarmConfig.jarmResponseLifetimeSeconds,
+      }),
+    );
+  }
+  const url = new URL(redirectUri);
+  for (const [name, value] of Object.entries(parameters)) {
+    if (value !== undefined) url.searchParams.set(name, value);
+  }
+  url.searchParams.set('iss', issuer);
+  return url.toString();
+}
+
 /**
  * Consent Page - GET
  * Displays the consent form for scope authorization.
@@ -63,15 +146,17 @@ consentApp.post('/', async (c) => {
   const issuer = config.issuer;
 
   if (action === 'deny') {
-    const redirectUrl = new URL(transaction.redirectUri);
-    redirectUrl.searchParams.set('error', 'access_denied');
-    if (transaction.state) {
-      redirectUrl.searchParams.set('state', transaction.state);
-    }
-    redirectUrl.searchParams.set('iss', issuer);
     await transactionStore.delete('auth_txn:' + transactionId);
     await authSessionStore.delete(transactionId);
-    return c.redirect(redirectUrl.toString());
+    // EXPERIMENTAL (JARM §2.1): a request that asked for response_mode=query.jwt
+    // gets its error as a signed JWT too, so the client can verify that the OP
+    // it trusts is the one that denied the request.
+    return c.redirect(
+      await buildConsentRedirect(resolveJarmResponse(c, transaction), transaction.redirectUri, {
+        error: 'access_denied',
+        state: transaction.state,
+      }, issuer),
+    );
   }
 
   // OIDC Core 1.0 Section 3.1.2.4: "the Authorization Server MUST obtain an
@@ -144,11 +229,10 @@ consentApp.post('/', async (c) => {
   await authSessionStore.delete(transactionId);
 
   // Redirect back to client with authorization code
-  const redirectUrl = new URL(responseParams.redirectUri);
-  redirectUrl.searchParams.set('code', authCodeData.code);
-  if (responseParams.state) {
-    redirectUrl.searchParams.set('state', responseParams.state);
-  }
-  redirectUrl.searchParams.set('iss', issuer);
-  return c.redirect(redirectUrl.toString());
+  return c.redirect(
+    await buildConsentRedirect(resolveJarmResponse(c, transaction), responseParams.redirectUri, {
+      code: authCodeData.code,
+      state: responseParams.state,
+    }, issuer),
+  );
 });
diff --git a/default-op/routes/discovery.ts b/with-jarm/routes/discovery.ts
index 72c0758..3eb0040 100644
--- a/default-op/routes/discovery.ts
+++ b/with-jarm/routes/discovery.ts
@@ -40,9 +40,10 @@ discoveryApp.get('/', (c) => {
     responseTypesSupported: ['code'],
     // OAuth 2.0 Multiple Response Type Encoding Practices §2 / OIDC Discovery 1.0 §3:
     // the OP only implements the authorization code flow, whose authorization
-    // response is returned via query, so response_modes_supported is pinned to
-    // ['query']. Extend this list when form_post (or other modes) are added.
-    responseModesSupported: ['query'],
+    // response is returned via query. EXPERIMENTAL (JARM §4): this provider was
+    // generated with --enable jarm, so the JWT-secured query modes are advertised
+    // alongside it. Extend this list when form_post (or other modes) are added.
+    responseModesSupported: ['query', 'query.jwt', 'jwt'],
     subjectTypesSupported: ['public'],
     idTokenSigningKeys,
     userinfoEndpoint: `${issuer}/userinfo`,
@@ -144,5 +145,9 @@ discoveryApp.get('/', (c) => {
   return c.json({
     ...metadata,
     code_challenge_methods_supported: ['S256'],
+    // EXPERIMENTAL — JARM §4 metadata. The response JWT is always signed with
+    // RS256 (JARM §3: the default for a client that registered no
+    // authorization_signed_response_alg), so exactly one alg is advertised.
+    authorization_signing_alg_values_supported: ['RS256'],
   });
 });
diff --git a/with-jarm/routes/jarm.ts b/with-jarm/routes/jarm.ts
new file mode 100644
index 0000000..303064e
--- /dev/null
+++ b/with-jarm/routes/jarm.ts
@@ -0,0 +1,29 @@
+/**
+ * EXPERIMENTAL — JWT Secured Authorization Response Mode (JARM).
+ *
+ * This module was generated because the OP was created with `--enable jarm`.
+ * It is backed by @maronn-openid-connect/experimental, whose API is NOT stable: it may
+ * change in a breaking way between releases. Do not build production code on it
+ * without pinning the version.
+ *
+ * Imported by the authorize and consent routes, so keep all three in sync when
+ * changing these settings.
+ *
+ * - jarmResponseLifetimeSeconds: how long the response JWT stays valid (its
+ *   `exp` claim). JARM Section 2.1 RECOMMENDs a maximum lifetime of 10 minutes,
+ *   so values outside 5-600 seconds fail fast at module load. Keep it short: the
+ *   JWT rides in a URL and only needs to survive one browser redirect.
+ *
+ * Not configurable: the signing algorithm (RS256, JARM Section 3's default for a
+ * client with no registered authorization_signed_response_alg), the response
+ * parameter name (`response`, JARM Section 2.3.1) and the supported response
+ * modes (`query.jwt` / `jwt` — this OP implements response_type=code only, so
+ * `fragment.jwt` and `form_post.jwt` are rejected with invalid_request).
+ */
+import { assertJarmLifetimeSeconds } from '@maronn-openid-connect/experimental/jarm';
+
+export const jarmConfig = {
+  jarmResponseLifetimeSeconds: 60,
+};
+
+assertJarmLifetimeSeconds(jarmConfig.jarmResponseLifetimeSeconds);

````
