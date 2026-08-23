# 生成コード差分: par — nextjs

> 機械生成物です。手で編集しないでください。[パケットの説明に戻る](../README.md)

比較しているもの:

- `a/default-op/...`: `maronn-oidc generate <framework>`（experimental 機能なしのデフォルト構成）
- `b/with-par/...`: `maronn-oidc generate <framework> --enable par`

この差分が「`--enable par` が生成コードに足すものすべて」です。

## サマリ

| 種別 | ファイル |
|---|---|
| 追加 | _oidc-provider/routes/par.ts, par/route.ts |
| 変更 | _oidc-provider/app.ts, _oidc-provider/conformance.test.ts, _oidc-provider/routes/authorize.ts, _oidc-provider/routes/discovery.ts, _oidc-provider/store.ts |
| 削除 | （なし） |

## 差分

````diff
diff --git a/default-op/_oidc-provider/app.ts b/with-par/_oidc-provider/app.ts
index 1bfc18d..b9a2ff8 100644
--- a/default-op/_oidc-provider/app.ts
+++ b/with-par/_oidc-provider/app.ts
@@ -4,6 +4,7 @@ import { tokenApp } from './routes/token';
 import { userinfoApp } from './routes/userinfo';
 import { introspectionApp } from './routes/introspection';
 import { revocationApp } from './routes/revocation';
+import { parApp } from './routes/par';
 import { jwksApp } from './routes/jwks';
 import { discoveryApp } from './routes/discovery';
 import { loginApp } from './routes/login';
@@ -18,6 +19,7 @@ import {
 } from './resolvers';
 import {
   defaultProviderStores,
+  parStore,
   type ProviderStores,
 } from './store';
 import { createViews, type Views } from './views';
@@ -94,6 +96,7 @@ export function createApp(options: OidcProviderOptions): WebRouter {
   app.use('/userinfo', protectedCors);
   app.use('/introspect', protectedCors);
   app.use('/revoke', protectedCors);
+  app.use('/par', protectedCors);
   app.use('/.well-known/openid-configuration', publicCors);
   app.use('/.well-known/jwks.json', publicCors);
 
@@ -157,6 +160,7 @@ export function createApp(options: OidcProviderOptions): WebRouter {
     c.set('introspectionAccessTokenResolver', storeResolvers.introspectionAccessTokenResolver);
     c.set('introspectionRefreshTokenResolver', storeResolvers.introspectionRefreshTokenResolver);
     c.set('revocationResolvers', storeResolvers.revocationResolvers);
+    c.set('parStore', parStore);
 
     if (options.acrResolver) {
       c.set('acrResolver', options.acrResolver);
@@ -177,6 +181,7 @@ export function createApp(options: OidcProviderOptions): WebRouter {
   app.route('/userinfo', userinfoApp);
   app.route('/introspect', introspectionApp);
   app.route('/revoke', revocationApp);
+  app.route('/par', parApp);
   app.route('/.well-known/jwks.json', jwksApp);
   app.route('/.well-known/openid-configuration', discoveryApp);
   app.route('/login', loginApp);
diff --git a/default-op/_oidc-provider/conformance.test.ts b/with-par/_oidc-provider/conformance.test.ts
index 57e9e5c..c66db8c 100644
--- a/default-op/_oidc-provider/conformance.test.ts
+++ b/with-par/_oidc-provider/conformance.test.ts
@@ -7,6 +7,8 @@ import { accessTokenStore, authSessionStore, consentStore, createJsonProviderSto
 import { consentResolver } from './resolvers';
 import { defaultViews } from './views';
 import { renderView } from './views';
+import { parStore } from './store';
+import { parConfig } from './routes/par';
 
 
 const REDIRECT_URI = 'http://localhost:3000/callback';
@@ -2403,6 +2405,416 @@ describe('generated provider HTTP conformance', () => {
   });
 
 
+  // EXPERIMENTAL — Pushed Authorization Requests (RFC 9126). Generated because
+  // this provider was created with --enable par. These tests pin the contract the
+  // repository guarantees for the generated PAR endpoint: change the behavior and
+  // they fail, which is how a customized OP learns it has drifted.
+  describe('Pushed Authorization Requests (RFC 9126)', () => {
+    // RFC 7636 Appendix B example PKCE pair (verifier -> its S256 challenge).
+    const PKCE_VERIFIER = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
+    const PKCE_CHALLENGE_S256 = 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM';
+    const REQUEST_URI_PREFIX = 'urn:ietf:params:oauth:request_uri:';
+    const OPAQUE_FAILURE_DESCRIPTION =
+      'The request_uri is invalid, expired, or has already been used';
+
+    // Pure helpers: they fetch and parse only. Every assertion lives in an it().
+    function pushedRequestBody(overrides: Record<string, string> = {}): Record<string, string> {
+      return {
+        response_type: 'code',
+        client_id: 'c-conf',
+        client_secret: 's',
+        redirect_uri: REDIRECT_URI,
+        scope: 'openid',
+        state: 'par-state',
+        nonce: 'par-nonce',
+        code_challenge: PKCE_CHALLENGE_S256,
+        code_challenge_method: 'S256',
+        ...overrides,
+      };
+    }
+
+    function pushRequest(body: Record<string, string>): Promise<Response> {
+      return app.request('/par', {
+        method: 'POST',
+        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
+        body: new URLSearchParams(body).toString(),
+      });
+    }
+
+    async function pushAndGetRequestUri(overrides: Record<string, string> = {}): Promise<string> {
+      const res = await pushRequest(pushedRequestBody(overrides));
+      const body = await res.json();
+      return body.request_uri as string;
+    }
+
+    function authorizeWithRequestUri(requestUri: string, clientId = 'c-conf'): Promise<Response> {
+      return app.request(
+        '/authorize?client_id=' + clientId + '&request_uri=' + encodeURIComponent(requestUri),
+        { headers: { Accept: 'application/json' } },
+      );
+    }
+
+    function relativeFrom(location: string | null): string {
+      const url = new URL(location ?? '', 'http://localhost');
+      return url.pathname + url.search;
+    }
+
+    function csrfFrom(html: string): string {
+      return html.match(/name="csrf_token" value="([^"]+)"/)?.[1] ?? '';
+    }
+
+    describe('Endpoint response', () => {
+      it('should return 201 with a URN request_uri and the configured lifetime', async () => {
+        // RFC 9126 §2.2: 201 Created, application/json, Cache-Control: no-cache, no-store.
+        const res = await pushRequest(pushedRequestBody());
+        const body = await res.json();
+
+        expect(res.status).toBe(201);
+        expect(res.headers.get('Content-Type')).toBe('application/json');
+        expect(res.headers.get('Cache-Control')).toBe('no-cache, no-store');
+        expect(Object.keys(body).sort()).toEqual(['expires_in', 'request_uri']);
+        expect(body.expires_in).toBe(60);
+        expect((body.request_uri as string).startsWith(REQUEST_URI_PREFIX)).toBe(true);
+        expect((body.request_uri as string).slice(REQUEST_URI_PREFIX.length)).toHaveLength(43);
+      });
+
+      it('should issue a different request_uri for every pushed request', async () => {
+        const first = await pushAndGetRequestUri();
+        const second = await pushAndGetRequestUri();
+
+        expect(first === second).toBe(false);
+      });
+
+      it('should reject a request that is not form-urlencoded', async () => {
+        const res = await app.request('/par', {
+          method: 'POST',
+          headers: { 'Content-Type': 'application/json' },
+          body: JSON.stringify(pushedRequestBody()),
+        });
+
+        expect(res.status).toBe(400);
+        expect(await res.json()).toEqual({
+          error: 'invalid_request',
+          error_description: 'Pushed authorization requests must use application/x-www-form-urlencoded',
+        });
+      });
+
+      it('should reject a GET on the PAR endpoint with 405', async () => {
+        // RFC 9126 §2.3 lists 405 among the responses the endpoint may return.
+        const res = await app.request('/par');
+
+        expect(res.status).toBe(405);
+        expect(res.headers.get('Allow')).toBe('POST');
+      });
+    });
+
+    describe('Client authentication', () => {
+      it('should reject an unauthenticated pushed request with 401 invalid_client', async () => {
+        const body = pushedRequestBody();
+        delete body.client_secret;
+        const res = await pushRequest(body);
+
+        expect(res.status).toBe(401);
+        expect(res.headers.get('WWW-Authenticate')).toBe('Basic realm="Client Authentication"');
+        expect((await res.json()).error).toBe('invalid_client');
+      });
+
+      it('should reject a wrong client_secret with 401 invalid_client', async () => {
+        const res = await pushRequest(pushedRequestBody({ client_secret: 'wrong' }));
+
+        expect(res.status).toBe(401);
+        expect((await res.json()).error).toBe('invalid_client');
+      });
+    });
+
+    describe('Pushed parameter validation', () => {
+      it('should reject a request_uri inside the pushed body', async () => {
+        // RFC 9126 §2.1: request_uri MUST NOT be provided in a pushed request.
+        const res = await pushRequest(
+          pushedRequestBody({ request_uri: REQUEST_URI_PREFIX + 'anything' }),
+        );
+
+        expect(res.status).toBe(400);
+        expect(await res.json()).toEqual({
+          error: 'invalid_request',
+          error_description: 'request_uri MUST NOT be included in a pushed authorization request',
+        });
+      });
+
+      it('should reject a request parameter because PAR with a Request Object is unsupported', async () => {
+        const res = await pushRequest(pushedRequestBody({ request: 'eyJhbGciOiJSUzI1NiJ9.e30.s' }));
+
+        expect(res.status).toBe(400);
+        expect(await res.json()).toEqual({
+          error: 'invalid_request',
+          error_description: 'The request parameter (Request Object) is not supported by this pushed authorization request endpoint',
+        });
+      });
+
+      it('should reject an unregistered redirect_uri before the user sees anything', async () => {
+        // RFC 9126 §2.1: the pushed request is validated as an authorization request
+        // would be — so this fails on the back channel, with no redirect.
+        const res = await pushRequest(
+          pushedRequestBody({ redirect_uri: 'http://attacker.example/cb' }),
+        );
+
+        expect(res.status).toBe(400);
+        expect(res.headers.get('Location')).toBe(null);
+        expect((await res.json()).error).toBe('invalid_request');
+      });
+
+      it('should reject a scope without openid as invalid_scope', async () => {
+        const res = await pushRequest(pushedRequestBody({ scope: 'profile' }));
+
+        expect(res.status).toBe(400);
+        expect((await res.json()).error).toBe('invalid_scope');
+      });
+    });
+
+    describe('Authorization endpoint resolution', () => {
+      it('should complete the full PAR to token flow', async () => {
+        const requestUri = await pushAndGetRequestUri();
+
+        const authorizeRes = await app.request(
+          '/authorize?client_id=c-conf&request_uri=' + encodeURIComponent(requestUri),
+        );
+        const loginPath = relativeFrom(authorizeRes.headers.get('Location'));
+        // Carry forward whatever cookie /authorize set, exactly as a browser would.
+        // With --enable transaction-binding this is the per-transaction binding
+        // secret the later steps require; without it this is '' and the OP ignores
+        // it, so the same flow works in both builds.
+        const bindingCookie = (authorizeRes.headers.get('Set-Cookie') ?? '').split(';')[0] ?? '';
+        const transactionId =
+          new URL(loginPath, 'http://localhost').searchParams.get('transaction_id') ?? '';
+        const loginGet = await app.request(loginPath, { headers: { Cookie: bindingCookie } });
+        const loginRes = await app.request('/login', {
+          method: 'POST',
+          headers: { 'Content-Type': 'application/x-www-form-urlencoded', Cookie: bindingCookie },
+          body: new URLSearchParams({
+            transaction_id: transactionId,
+            csrf_token: csrfFrom(await loginGet.text()),
+            username: 'testuser',
+            password: 'password',
+          }).toString(),
+        });
+        const consentPath = relativeFrom(loginRes.headers.get('Location'));
+        const consentGet = await app.request(consentPath, { headers: { Cookie: bindingCookie } });
+        const consentRes = await app.request('/consent', {
+          method: 'POST',
+          headers: { 'Content-Type': 'application/x-www-form-urlencoded', Cookie: bindingCookie },
+          body: new URLSearchParams({
+            transaction_id: transactionId,
+            csrf_token: csrfFrom(await consentGet.text()),
+            action: 'approve',
+          }).toString(),
+        });
+        const callback = new URL(consentRes.headers.get('Location') ?? '', 'http://localhost');
+
+        expect(authorizeRes.status).toBe(302);
+        expect(loginPath.startsWith('/login?')).toBe(true);
+        expect(consentPath.startsWith('/consent?')).toBe(true);
+        // The pushed state is what comes back, proving the stored parameters were used.
+        expect(callback.searchParams.get('state')).toBe('par-state');
+
+        const tokenRes = await app.request('/token', {
+          method: 'POST',
+          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
+          body: new URLSearchParams({
+            grant_type: 'authorization_code',
+            client_id: 'c-conf',
+            client_secret: 's',
+            code: callback.searchParams.get('code') ?? '',
+            redirect_uri: REDIRECT_URI,
+            code_verifier: PKCE_VERIFIER,
+          }).toString(),
+        });
+        const tokenBody = await tokenRes.json();
+
+        expect(tokenRes.status).toBe(200);
+        // The nonce pushed to /par is the one bound into the ID Token (OIDC Core §2).
+        expect(idTokenPayload(tokenBody.id_token as string).nonce).toBe('par-nonce');
+      });
+
+      it('should keep the pushed parameters authoritative over the query string', async () => {
+        // RFC 9126 §4: the client sends only client_id and request_uri; anything else
+        // in the query is ignored so it cannot tamper with the pushed request.
+        const requestUri = await pushAndGetRequestUri();
+
+        const authorizeRes = await app.request(
+          '/authorize?client_id=c-conf&scope=openid+admin&state=tampered&request_uri=' +
+            encodeURIComponent(requestUri),
+        );
+        const loginPath = relativeFrom(authorizeRes.headers.get('Location'));
+        // Carry forward whatever cookie /authorize set, exactly as a browser would.
+        // With --enable transaction-binding this is the per-transaction binding
+        // secret the later steps require; without it this is '' and the OP ignores
+        // it, so the same flow works in both builds.
+        const bindingCookie = (authorizeRes.headers.get('Set-Cookie') ?? '').split(';')[0] ?? '';
+        const transactionId =
+          new URL(loginPath, 'http://localhost').searchParams.get('transaction_id') ?? '';
+        const loginGet = await app.request(loginPath, { headers: { Cookie: bindingCookie } });
+        const loginRes = await app.request('/login', {
+          method: 'POST',
+          headers: { 'Content-Type': 'application/x-www-form-urlencoded', Cookie: bindingCookie },
+          body: new URLSearchParams({
+            transaction_id: transactionId,
+            csrf_token: csrfFrom(await loginGet.text()),
+            username: 'testuser',
+            password: 'password',
+          }).toString(),
+        });
+        const consentPath = relativeFrom(loginRes.headers.get('Location'));
+        const consentHtml = await (await app.request(consentPath, { headers: { Cookie: bindingCookie } })).text();
+
+        expect(authorizeRes.status).toBe(302);
+        // The consent screen lists the pushed scope, not the tampered one.
+        expect(consentHtml.includes('<li>admin</li>')).toBe(false);
+      });
+
+      it('should reject the second use of the same request_uri', async () => {
+        // RFC 9126 §7.3: single use. A browser reload of the authorize URL fails too;
+        // that is the intended trade-off of not allowing the §4 duplicate-use MAY.
+        const requestUri = await pushAndGetRequestUri();
+        const first = await app.request(
+          '/authorize?client_id=c-conf&request_uri=' + encodeURIComponent(requestUri),
+        );
+        const second = await authorizeWithRequestUri(requestUri);
+
+        expect(first.status).toBe(302);
+        expect(second.status).toBe(400);
+        expect(await second.json()).toEqual({
+          error: 'invalid_request_uri',
+          error_description: OPAQUE_FAILURE_DESCRIPTION,
+        });
+      });
+
+      it('should reject an expired request_uri', async () => {
+        // RFC 9126 §4: "An expired request_uri MUST be rejected as invalid."
+        const requestUri = REQUEST_URI_PREFIX + 'expired-conformance-reference';
+        await parStore.save({
+          requestUri,
+          clientId: 'c-conf',
+          params: pushedRequestBody({ client_secret: '' }),
+          createdAt: new Date(Date.now() - 120_000),
+          expiresAt: new Date(Date.now() - 60_000),
+        });
+
+        const res = await authorizeWithRequestUri(requestUri);
+
+        expect(res.status).toBe(400);
+        expect((await res.json()).error).toBe('invalid_request_uri');
+      });
+
+      it('should reject a request_uri presented by a different client', async () => {
+        // RFC 9126 §2.2: the request_uri MUST be bound to the client that pushed it.
+        const requestUri = await pushAndGetRequestUri();
+
+        const res = await authorizeWithRequestUri(requestUri, 'c-public');
+
+        expect(res.status).toBe(400);
+        expect((await res.json()).error).toBe('invalid_request_uri');
+      });
+
+      it('should return the identical response for every resolution failure', async () => {
+        // The response must not reveal whether a given request_uri ever existed.
+        const consumed = await pushAndGetRequestUri();
+        await app.request('/authorize?client_id=c-conf&request_uri=' + encodeURIComponent(consumed));
+        const reused = await authorizeWithRequestUri(consumed);
+        const unknown = await authorizeWithRequestUri(REQUEST_URI_PREFIX + 'never-issued');
+        const stolen = await pushAndGetRequestUri();
+        const mismatched = await authorizeWithRequestUri(stolen, 'c-public');
+
+        expect([reused.status, unknown.status, mismatched.status]).toEqual([400, 400, 400]);
+        expect([await reused.json(), await unknown.json(), await mismatched.json()]).toEqual([
+          { error: 'invalid_request_uri', error_description: OPAQUE_FAILURE_DESCRIPTION },
+          { error: 'invalid_request_uri', error_description: OPAQUE_FAILURE_DESCRIPTION },
+          { error: 'invalid_request_uri', error_description: OPAQUE_FAILURE_DESCRIPTION },
+        ]);
+      });
+
+      it('should never redirect a resolution failure to the client', async () => {
+        // RFC 6749 §4.1.2.1: without a verified redirect_uri the OP MUST NOT redirect.
+        const res = await authorizeWithRequestUri(REQUEST_URI_PREFIX + 'never-issued');
+
+        expect(res.status).toBe(400);
+        expect(res.headers.get('Location')).toBe(null);
+      });
+
+      it('should leave a URL-form request_uri to the core request_uri_not_supported path', async () => {
+        // OIDC Core 1.0 §6.2 by-reference request objects stay unsupported.
+        const res = await app.request(
+          '/authorize?response_type=code&client_id=c-conf' +
+            '&redirect_uri=' + encodeURIComponent(REDIRECT_URI) +
+            '&scope=openid&state=url-form' +
+            '&code_challenge=' + PKCE_CHALLENGE_S256 + '&code_challenge_method=S256' +
+            '&request_uri=' + encodeURIComponent('https://client.example/request.jwt'),
+        );
+        const location = new URL(res.headers.get('Location') ?? '', 'http://localhost');
+
+        expect(res.status).toBe(302);
+        expect(location.searchParams.get('error')).toBe('request_uri_not_supported');
+      });
+    });
+
+    describe('Provider metadata and PAR enforcement', () => {
+      it('should advertise the pushed_authorization_request_endpoint', async () => {
+        // RFC 9126 §5.
+        const res = await app.request('/.well-known/openid-configuration');
+        const metadata = await res.json();
+
+        expect(metadata.pushed_authorization_request_endpoint).toBe(
+          'http://localhost:3000/par',
+        );
+      });
+
+      it('should not advertise require_pushed_authorization_requests while PAR is optional', async () => {
+        const metadata = await (await app.request('/.well-known/openid-configuration')).json();
+
+        expect(metadata.require_pushed_authorization_requests).toBe(undefined);
+      });
+
+      it('should advertise require_pushed_authorization_requests when PAR is enforced', async () => {
+        parConfig.requirePushedAuthorizationRequests = true;
+        const metadata = await (await app.request('/.well-known/openid-configuration')).json();
+        parConfig.requirePushedAuthorizationRequests = false;
+
+        expect(metadata.require_pushed_authorization_requests).toBe(true);
+      });
+
+      it('should reject a non-pushed authorization request when PAR is enforced', async () => {
+        // RFC 9126 §5. The rejection is non-redirect, like every other PAR failure.
+        parConfig.requirePushedAuthorizationRequests = true;
+        const res = await app.request(
+          '/authorize?response_type=code&client_id=c-conf' +
+            '&redirect_uri=' + encodeURIComponent(REDIRECT_URI) +
+            '&scope=openid&state=no-par' +
+            '&code_challenge=' + PKCE_CHALLENGE_S256 + '&code_challenge_method=S256',
+          { headers: { Accept: 'application/json' } },
+        );
+        const body = await res.json();
+        parConfig.requirePushedAuthorizationRequests = false;
+
+        expect(res.status).toBe(400);
+        expect(res.headers.get('Location')).toBe(null);
+        expect(body).toEqual({
+          error: 'invalid_request',
+          error_description: 'Pushed authorization requests are required by this authorization server',
+        });
+      });
+
+      it('should still accept a pushed request while PAR is enforced', async () => {
+        parConfig.requirePushedAuthorizationRequests = true;
+        const requestUri = await pushAndGetRequestUri();
+        const res = await app.request(
+          '/authorize?client_id=c-conf&request_uri=' + encodeURIComponent(requestUri),
+        );
+        parConfig.requirePushedAuthorizationRequests = false;
+
+        expect(res.status).toBe(302);
+      });
+    });
+  });
+
   // The device authorization grant is disabled in this generated provider: no
   // endpoint, no metadata, and the URN stays an unsupported grant. These pin the
   // default-off contract so enabling the feature by accident is visible.
diff --git a/default-op/_oidc-provider/routes/authorize.ts b/with-par/_oidc-provider/routes/authorize.ts
index dc9fbe0..60d67fb 100644
--- a/default-op/_oidc-provider/routes/authorize.ts
+++ b/with-par/_oidc-provider/routes/authorize.ts
@@ -37,6 +37,13 @@ import {
   authSessionStore as defaultAuthSessionStore,
 } from '../store';
 import { defaultViews, renderView } from '../views';
+import {
+  PushedRequestUriError,
+  assertPushedRequestUsed,
+  resolvePushedRequestUri,
+} from '@maronn-openid-connect/experimental/par';
+import { parConfig } from './par';
+import { parStore as defaultParStore } from '../store';
 
 export const authorizeApp = new WebRouter();
 
@@ -147,9 +154,31 @@ const handleAuthorizationRequest = async (c: any) => {
     return c.json({ error: 'invalid_request', error_description: 'Missing required parameter: client_id' }, 400);
   }
 
-  const params = rawParams;
+  let params = rawParams;
 
   try {
+    // EXPERIMENTAL — Pushed Authorization Requests (RFC 9126 §4).
+    const parStore = c.get('parStore') ?? defaultParStore;
+    // RFC 9126 §5: when require_pushed_authorization_requests is on, an
+    // authorization request that did not go through /par is rejected outright.
+    if (parConfig.requirePushedAuthorizationRequests) {
+      assertPushedRequestUsed(rawParams);
+    }
+    // Expand a request_uri of the form urn:ietf:params:oauth:request_uri:<ref> into
+    // the parameters pushed to /par. The reference is single use and short lived,
+    // so a reload of this URL fails with invalid_request_uri by design.
+    // Anything that is not a URN (absent, or an OIDC Core §6.2 URL) returns null
+    // and is left to the normal pipeline, which rejects it with
+    // request_uri_not_supported.
+    const pushedParams = await resolvePushedRequestUri({ params: rawParams, store: parStore });
+    if (pushedParams !== null) {
+      if (!isAuthorizationRequestParams(pushedParams)) {
+        // Defensive: client_id was validated when the request was pushed.
+        throw new PushedRequestUriError('invalid_request_uri', 'The request_uri is invalid, expired, or has already been used');
+      }
+      params = pushedParams;
+    }
+
     const clientResolver = c.get('clientResolver') ?? defaultClientResolver;
     const transactionStore = c.get('transactionStore') ?? defaultTransactionStore;
     const authCodeStore = c.get('authCodeStore') ?? defaultAuthCodeStore;
@@ -501,6 +530,35 @@ const handleAuthorizationRequest = async (c: any) => {
     loginUrl.searchParams.set('transaction_id', transactionId);
     return c.redirect(loginUrl.toString());
   } catch (error) {
+    if (error instanceof PushedRequestUriError) {
+      // RFC 9126 §4 / OIDC Core 1.0 §3.1.2.6: a request_uri that cannot be
+      // resolved leaves us without a verified redirect_uri, so this error is
+      // NEVER redirected (RFC 6749 §4.1.2.1). It is rendered through the same
+      // non-redirect path as AuthorizationError below. Every failure kind
+      // (unknown / used / expired / wrong client) returns the identical code and
+      // description so the response cannot be used as an existence oracle.
+      const acceptsJson = (c.req.header('Accept') ?? '').includes('application/json');
+      if (acceptsJson) {
+        return c.json({ error: error.code, error_description: error.errorDescription }, 400);
+      }
+      const parErrorPagePath = c.get('config').authorizationErrorRedirectPath;
+      if (parErrorPagePath && parErrorPagePath.startsWith('/') && !parErrorPagePath.startsWith('//')) {
+        const parErrorParams = new URLSearchParams({
+          error: error.code,
+          error_description: error.errorDescription,
+        });
+        return c.redirect(`${parErrorPagePath}?${parErrorParams.toString()}`, 303);
+      }
+      const parViews = c.get('views') ?? defaultViews;
+      return renderView(
+        parViews.errorPage({
+          error: error.code,
+          errorDescription: error.errorDescription,
+          statusCode: 400,
+        }),
+        { status: 400 },
+      );
+    }
     if (error instanceof AuthorizationError) {
       if (error.redirectUri) {
         const redirectUrl = new URL(error.redirectUri);
diff --git a/default-op/_oidc-provider/routes/discovery.ts b/with-par/_oidc-provider/routes/discovery.ts
index 6561812..dff59c6 100644
--- a/default-op/_oidc-provider/routes/discovery.ts
+++ b/with-par/_oidc-provider/routes/discovery.ts
@@ -1,6 +1,7 @@
 import { WebRouter } from '../web-router';
 import { buildProviderMetadata, getJwaAlgorithm, type SigningKey } from '@maronn-openid-connect/core';
 import { defaultProviderConfig } from '../config';
+import { parConfig } from './par';
 
 export const discoveryApp = new WebRouter();
 
@@ -144,5 +145,11 @@ discoveryApp.get('/', (c) => {
   return c.json({
     ...metadata,
     code_challenge_methods_supported: ['S256'],
+    // EXPERIMENTAL — RFC 9126 §5 metadata. require_pushed_authorization_requests
+    // is only advertised when PAR is actually enforced (its default is false).
+    pushed_authorization_request_endpoint: `${issuer}/par`,
+    ...(parConfig.requirePushedAuthorizationRequests
+      ? { require_pushed_authorization_requests: true }
+      : {}),
   });
 });
diff --git a/with-par/_oidc-provider/routes/par.ts b/with-par/_oidc-provider/routes/par.ts
new file mode 100644
index 0000000..d803a4f
--- /dev/null
+++ b/with-par/_oidc-provider/routes/par.ts
@@ -0,0 +1,157 @@
+/**
+ * EXPERIMENTAL — Pushed Authorization Requests (RFC 9126).
+ *
+ * This route was generated because the OP was created with `--enable par`.
+ * It is backed by @maronn-openid-connect/experimental, whose API is NOT stable: it may
+ * change in a breaking way between releases. Do not build production code on it
+ * without pinning the version.
+ *
+ * The client POSTs the authorization request parameters here (back channel,
+ * authenticated) and receives a short-lived `request_uri` reference that it
+ * then passes to /authorize.
+ */
+import { WebRouter } from '../web-router';
+import {
+  ParError,
+  assertParExpiresInSeconds,
+  authenticateParClient,
+  buildPushedAuthorizationResponse,
+  createPushedAuthorizationRecord,
+  rejectForbiddenParParams,
+  validatePushedAuthorizationParams,
+} from '@maronn-openid-connect/experimental/par';
+import { sanitizeErrorDescription } from '@maronn-openid-connect/core';
+import { clientResolver as defaultClientResolver } from '../resolvers';
+import { parStore as defaultParStore } from '../store';
+
+/**
+ * PAR settings. Imported by the authorize route, so keep both files in sync when
+ * changing them.
+ *
+ * - expiresInSeconds: request_uri lifetime. RFC 9126 §2.2 recommends 5–600
+ *   seconds; values outside that range fail fast at module load.
+ * - requirePushedAuthorizationRequests: RFC 9126 §5. When true, /authorize
+ *   rejects any request that did not go through this endpoint, and discovery
+ *   advertises require_pushed_authorization_requests: true.
+ */
+export const parConfig = {
+  expiresInSeconds: 60,
+  requirePushedAuthorizationRequests: false,
+};
+
+assertParExpiresInSeconds(parConfig.expiresInSeconds);
+
+export const parApp = new WebRouter();
+
+/**
+ * RFC 9126 §2.1: the pushed authorization request body MUST be
+ * application/x-www-form-urlencoded.
+ */
+function isFormUrlEncoded(contentType: string): boolean {
+  const [mediaType = ''] = contentType.toLowerCase().split(';');
+  return mediaType.trim() === 'application/x-www-form-urlencoded';
+}
+
+/**
+ * Pushed Authorization Request Endpoint
+ * RFC 9126 §2
+ *
+ * NOTE (RFC 9126 §2.3): request size limits (413) and rate limiting (429) are
+ * deliberately left to the deployment layer (reverse proxy / platform), not
+ * implemented here. This endpoint is unauthenticated until the client
+ * credentials are checked, so put a rate limit in front of it in production.
+ */
+parApp.post('/', async (c) => {
+  const contentType = c.req.header('Content-Type') ?? '';
+  if (!isFormUrlEncoded(contentType)) {
+    c.header('Cache-Control', 'no-cache, no-store');
+    c.header('Pragma', 'no-cache');
+    return c.json({ error: 'invalid_request', error_description: 'Pushed authorization requests must use application/x-www-form-urlencoded' }, 400);
+  }
+
+  // RFC 6749 §3.1: request parameters MUST NOT be repeated. Read the raw body so
+  // URLSearchParams iteration exposes duplicates instead of silently keeping the last.
+  const rawBody = await c.req.text();
+  const params: Record<string, string> = {};
+  const seen = new Set<string>();
+  let duplicateKey: string | undefined;
+  for (const [key, value] of new URLSearchParams(rawBody)) {
+    if (seen.has(key)) {
+      duplicateKey = key;
+      break;
+    }
+    seen.add(key);
+    params[key] = value;
+  }
+
+  if (duplicateKey !== undefined) {
+    c.header('Cache-Control', 'no-cache, no-store');
+    c.header('Pragma', 'no-cache');
+    return c.json({ error: 'invalid_request', error_description: `Parameter "${sanitizeErrorDescription(duplicateKey)}" must not be repeated` }, 400);
+  }
+
+  const authorization = c.req.header('Authorization') ?? '';
+
+  try {
+    const clientResolver = c.get('clientResolver') ?? defaultClientResolver;
+    const parStore = c.get('parStore') ?? defaultParStore;
+    const config = c.get('config');
+
+    // --- Pushed authorization request pipeline ------------------------------
+    // Each step below is an independent function from @maronn-openid-connect/experimental/par,
+    // called in RFC 9126 §2.1 order. Delete a call to drop that validation, or
+    // insert your own logic between steps.
+
+    // RFC 9126 §2.1: request_uri MUST NOT be pushed. The request parameter
+    // (PAR + JAR, §3) is not supported by this generated provider.
+    rejectForbiddenParParams(params);
+
+    // RFC 9126 §2.1: authenticate exactly like the token endpoint does.
+    // Public clients present only client_id (no credentials).
+    const clientId = await authenticateParClient({
+      params,
+      authorizationHeader: authorization,
+      clientResolver,
+    });
+
+    // client_id is a required authorization request parameter (RFC 9126 §2.1),
+    // so pin it to the authenticated client before validating and storing.
+    const pushedParams = { ...params, client_id: clientId };
+
+    // RFC 9126 §2.1: "validate the request the same way the authorization
+    // endpoint would" — an unregistered redirect_uri or a bad scope fails here,
+    // before the user ever sees a screen.
+    await validatePushedAuthorizationParams(pushedParams, clientResolver, {
+      allowNonPkceAuthorizationCodeFlow: config.allowNonPkceAuthorizationCodeFlow,
+    });
+
+    // RFC 9126 §2.2 / §7.1: mint a cryptographically random reference value and
+    // store the request under it. Client credentials are never persisted.
+    const record = await createPushedAuthorizationRecord({
+      clientId,
+      params: pushedParams,
+      store: parStore,
+      expiresInSeconds: parConfig.expiresInSeconds,
+    });
+    const response = buildPushedAuthorizationResponse(record);
+
+    // Never log the pushed parameters themselves: they can carry PII such as
+    // login_hint, and the Authorization header carries the client_secret.
+
+    // RFC 9126 §2.2: 201 Created with a non-cacheable JSON body.
+    c.header('Cache-Control', 'no-cache, no-store');
+    c.header('Pragma', 'no-cache');
+    return c.json({ request_uri: response.requestUri, expires_in: response.expiresIn }, 201);
+  } catch (error) {
+    c.header('Cache-Control', 'no-cache, no-store');
+    c.header('Pragma', 'no-cache');
+    if (error instanceof ParError) {
+      // RFC 9126 §2.3: token-endpoint style JSON errors. This endpoint never redirects.
+      if (error.wwwAuthenticate) {
+        c.header('WWW-Authenticate', error.wwwAuthenticate);
+      }
+      return c.json({ error: error.code, error_description: error.errorDescription }, error.statusCode);
+    }
+    return c.json({ error: 'server_error' }, 500);
+  }
+});
diff --git a/default-op/_oidc-provider/store.ts b/with-par/_oidc-provider/store.ts
index e530896..ef42ec2 100644
--- a/default-op/_oidc-provider/store.ts
+++ b/with-par/_oidc-provider/store.ts
@@ -6,6 +6,10 @@ import type {
   RefreshTokenInfo,
   UserClaims,
 } from '@maronn-openid-connect/core';
+import type {
+  PushedAuthorizationRecord,
+  PushedAuthorizationRequestStore,
+} from '@maronn-openid-connect/experimental/par';
 
 /**
  * In-memory Authorization Transaction Store.
@@ -823,3 +827,58 @@ export const authSessionStore = defaultProviderStores.authSessionStore;
 export const browserSessionStore = defaultProviderStores.browserSessionStore;
 export const consentStore = defaultProviderStores.consentStore;
 export const userStore = defaultProviderStores.userStore;
+
+/**
+ * EXPERIMENTAL — in-memory Pushed Authorization Request store (RFC 9126).
+ *
+ * Replace with a persistent store (Redis, KV, database) in production. The
+ * contract is only two methods:
+ *
+ * - save(record): persist the pushed request, ideally with a TTL matching
+ *   record.expiresAt so entries cannot pile up (RFC 9126 §7.3).
+ * - consume(requestUri): fetch AND delete in one atomic operation. A
+ *   non-atomic implementation lets the same request_uri be replayed
+ *   concurrently. Treat requestUri as an opaque external value: never
+ *   interpolate it into a query, always bind it as a parameter.
+ */
+export class InMemoryPushedAuthorizationRequestStore
+  implements PushedAuthorizationRequestStore
+{
+  private records = new Map<string, PushedAuthorizationRecord>();
+
+  async save(record: PushedAuthorizationRecord): Promise<void> {
+    this.records.set(record.requestUri, record);
+  }
+
+  async consume(requestUri: string): Promise<PushedAuthorizationRecord | null> {
+    const record = this.records.get(requestUri);
+    // Single use (RFC 9126 §7.3): delete on read, expired or not, so a replay of
+    // the same reference can never succeed.
+    this.records.delete(requestUri);
+    if (!record) {
+      this.evictExpired();
+      return null;
+    }
+    return record;
+  }
+
+  /** Drop entries whose lifetime has passed so an idle store cannot grow unbounded. */
+  private evictExpired(): void {
+    const now = Date.now();
+    for (const [requestUri, record] of this.records) {
+      if (record.expiresAt.getTime() < now) {
+        this.records.delete(requestUri);
+      }
+    }
+  }
+}
+
+// Kept on globalThis for the same reason as the provider stores above: Next.js
+// instantiates route handlers and server actions in separate module layers.
+const parStoreRegistry = globalThis as typeof globalThis & {
+  __oidcPushedAuthorizationRequestStore?: PushedAuthorizationRequestStore;
+};
+
+export const parStore: PushedAuthorizationRequestStore =
+  (parStoreRegistry.__oidcPushedAuthorizationRequestStore ??=
+    new InMemoryPushedAuthorizationRequestStore());
diff --git a/with-par/par/route.ts b/with-par/par/route.ts
new file mode 100644
index 0000000..312e3b8
--- /dev/null
+++ b/with-par/par/route.ts
@@ -0,0 +1,7 @@
+import { oidcHandlers } from '../_oidc-provider/runtime';
+
+export const dynamic = 'force-dynamic';
+export const runtime = 'nodejs';
+
+export const POST = oidcHandlers.POST;
+export const OPTIONS = oidcHandlers.OPTIONS;

````
