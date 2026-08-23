# 生成コード差分: device-authorization-grant — express

> 機械生成物です。手で編集しないでください。[パケットの説明に戻る](../README.md)

比較しているもの:

- `a/default-op/...`: `maronn-oidc generate <framework>`（experimental 機能なしのデフォルト構成）
- `b/with-device-authorization-grant/...`: `maronn-oidc generate <framework> --enable device-authorization-grant`

この差分が「`--enable device-authorization-grant` が生成コードに足すものすべて」です。

## サマリ

| 種別 | ファイル |
|---|---|
| 追加 | routes/device-authorization.ts, routes/device.ts |
| 変更 | app.ts, apply.ts, conformance.test.ts, routes/discovery.ts, routes/token.ts, store.ts, views.ts |
| 削除 | （なし） |

## 差分

````diff
diff --git a/default-op/app.ts b/with-device-authorization-grant/app.ts
index 430b0f1..3d9f1da 100644
--- a/default-op/app.ts
+++ b/with-device-authorization-grant/app.ts
@@ -4,6 +4,8 @@ import { tokenApp } from './routes/token.js';
 import { userinfoApp } from './routes/userinfo.js';
 import { introspectionApp } from './routes/introspection.js';
 import { revocationApp } from './routes/revocation.js';
+import { deviceAuthorizationApp } from './routes/device-authorization.js';
+import { deviceApp } from './routes/device.js';
 import { jwksApp } from './routes/jwks.js';
 import { discoveryApp } from './routes/discovery.js';
 import { loginApp } from './routes/login.js';
@@ -18,6 +20,7 @@ import {
 } from './resolvers.js';
 import {
   defaultProviderStores,
+  deviceAuthorizationStore,
   type ProviderStores,
 } from './store.js';
 import { createViews, type Views } from './views.js';
@@ -94,6 +97,7 @@ export function createApp(options: OidcProviderOptions): WebRouter {
   app.use('/userinfo', protectedCors);
   app.use('/introspect', protectedCors);
   app.use('/revoke', protectedCors);
+  app.use('/device_authorization', protectedCors);
   app.use('/.well-known/openid-configuration', publicCors);
   app.use('/.well-known/jwks.json', publicCors);
 
@@ -157,6 +161,7 @@ export function createApp(options: OidcProviderOptions): WebRouter {
     c.set('introspectionAccessTokenResolver', storeResolvers.introspectionAccessTokenResolver);
     c.set('introspectionRefreshTokenResolver', storeResolvers.introspectionRefreshTokenResolver);
     c.set('revocationResolvers', storeResolvers.revocationResolvers);
+    c.set('deviceAuthorizationStore', deviceAuthorizationStore);
 
     if (options.acrResolver) {
       c.set('acrResolver', options.acrResolver);
@@ -177,6 +182,8 @@ export function createApp(options: OidcProviderOptions): WebRouter {
   app.route('/userinfo', userinfoApp);
   app.route('/introspect', introspectionApp);
   app.route('/revoke', revocationApp);
+  app.route('/device_authorization', deviceAuthorizationApp);
+  app.route('/device', deviceApp);
   app.route('/.well-known/jwks.json', jwksApp);
   app.route('/.well-known/openid-configuration', discoveryApp);
   app.route('/login', loginApp);
diff --git a/default-op/apply.ts b/with-device-authorization-grant/apply.ts
index 24030b2..0d99280 100644
--- a/default-op/apply.ts
+++ b/with-device-authorization-grant/apply.ts
@@ -11,6 +11,8 @@ const OIDC_ENDPOINTS = [
   '/userinfo',
   '/introspect',
   '/revoke',
+  '/device_authorization',
+  '/device',
   '/.well-known/jwks.json',
   '/.well-known/openid-configuration',
   '/login',
diff --git a/default-op/conformance.test.ts b/with-device-authorization-grant/conformance.test.ts
index 75a5580..9161200 100644
--- a/default-op/conformance.test.ts
+++ b/with-device-authorization-grant/conformance.test.ts
@@ -122,6 +122,40 @@ const testClients = new Map<string, RegisteredClient>([
     grantTypes: ['authorization_code'],
     tokenEndpointAuthMethod: 'client_secret_post',
   }],
+  // EXPERIMENTAL (RFC 8628): a client registered for the device grant, plus a
+  // second one so the contract test can prove a device_code is refused when it is
+  // presented by a client other than the one it was issued to (§3.4).
+  ['c-device', {
+    clientId: 'c-device',
+    clientSecret: 's',
+    redirectUris: [REDIRECT_URI],
+    clientType: 'confidential' as const,
+    responseTypes: ['code'],
+    grantTypes: ['urn:ietf:params:oauth:grant-type:device_code', 'refresh_token'],
+    tokenEndpointAuthMethod: 'client_secret_post',
+  }],
+  ['c-device-other', {
+    clientId: 'c-device-other',
+    clientSecret: 's',
+    redirectUris: [REDIRECT_URI],
+    clientType: 'confidential' as const,
+    responseTypes: ['code'],
+    grantTypes: ['urn:ietf:params:oauth:grant-type:device_code'],
+    tokenEndpointAuthMethod: 'client_secret_post',
+  }],
+  // A third device client that registered id_token_signed_response_alg, so the
+  // contract test can prove the device grant honors it just like the standard
+  // grants (OIDC Dynamic Client Registration 1.0 §2).
+  ['c-device-es256', {
+    clientId: 'c-device-es256',
+    clientSecret: 's',
+    redirectUris: [REDIRECT_URI],
+    clientType: 'confidential' as const,
+    responseTypes: ['code'],
+    grantTypes: ['urn:ietf:params:oauth:grant-type:device_code'],
+    tokenEndpointAuthMethod: 'client_secret_post',
+    idTokenSignedResponseAlg: 'ES256' as const,
+  }],
 ]);
 
 // OIDC Core 1.0 §6.1: a signed RS256 Request Object for the conformance flow,
@@ -968,6 +1002,10 @@ describe('generated provider HTTP conformance', () => {
         { path: '/userinfo', method: 'PUT', allow: 'GET, POST' },
       { path: '/introspect', method: 'GET', allow: 'POST' },
       { path: '/revoke', method: 'GET', allow: 'POST' },
+      { path: '/device_authorization', method: 'GET', allow: 'POST' },
+      { path: '/device', method: 'PUT', allow: 'GET, POST' },
+      { path: '/device/login', method: 'GET', allow: 'POST' },
+      { path: '/device/approve', method: 'GET', allow: 'POST' },
         { path: '/.well-known/openid-configuration', method: 'POST', allow: 'GET' },
         { path: '/.well-known/jwks.json', method: 'POST', allow: 'GET' },
       ];
@@ -2459,58 +2497,723 @@ describe('generated provider HTTP conformance', () => {
   });
 
 
-  // The device authorization grant is disabled in this generated provider: no
-  // endpoint, no metadata, and the URN stays an unsupported grant. These pin the
-  // default-off contract so enabling the feature by accident is visible.
-  describe('Device Authorization Grant disabled (RFC 8628)', () => {
-    it('should not serve a device authorization endpoint', async () => {
-      const res = await app.request('/device_authorization', {
+  // EXPERIMENTAL — OAuth 2.0 Device Authorization Grant (RFC 8628). Generated
+  // because this provider was created with --enable device-authorization-grant.
+  describe('Device Authorization Grant (RFC 8628)', () => {
+    const DEVICE_GRANT_TYPE = 'urn:ietf:params:oauth:grant-type:device_code';
+
+    /**
+     * The app under test. Defaults to the shared one; the ID Token signing key
+     * selection test passes an app built on a mixed RS256 + ES256 key set.
+     */
+    type DeviceTargetApp = { request: (path: string, init?: RequestInit) => Promise<Response> };
+
+    // Pure helpers: they fetch and parse only. Every assertion lives in an it().
+    function requestDeviceAuthorization(
+      overrides: Record<string, string> = {},
+      target: DeviceTargetApp = app,
+    ): Promise<Response> {
+      return target.request('/device_authorization', {
         method: 'POST',
         headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
-        body: new URLSearchParams({ client_id: 'c-conf', scope: 'openid' }).toString(),
+        body: new URLSearchParams({
+          client_id: 'c-device',
+          client_secret: 's',
+          scope: 'openid',
+          ...overrides,
+        }).toString(),
       });
+    }
 
-      expect(res.status).toBe(404);
-    });
-
-    it('should not serve the device verification UI', async () => {
-      const res = await app.request('/device');
-
-      expect(res.status).toBe(404);
-    });
-
-    it('should reject the device_code grant with unsupported_grant_type', async () => {
-      const res = await app.request('/token', {
+    function pollToken(
+      deviceCode: string,
+      overrides: Record<string, string> = {},
+      target: DeviceTargetApp = app,
+    ): Promise<Response> {
+      return target.request('/token', {
         method: 'POST',
         headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
         body: new URLSearchParams({
-          grant_type: 'urn:ietf:params:oauth:grant-type:device_code',
-          device_code: 'anything',
-          client_id: 'c-conf',
+          grant_type: DEVICE_GRANT_TYPE,
+          device_code: deviceCode,
+          client_id: 'c-device',
           client_secret: 's',
+          ...overrides,
         }).toString(),
       });
+    }
 
-      expect(res.status).toBe(400);
-      expect((await res.json()).error).toBe('unsupported_grant_type');
+    function csrfFrom(html: string): string {
+      return html.match(/name="csrf_token" value="([^"]+)"/)?.[1] ?? '';
+    }
+
+    /** All Set-Cookie name=value pairs of a response, joined for a Cookie header. */
+    function cookieJar(...responses: Response[]): string {
+      return responses
+        .flatMap((res) => res.headers.getSetCookie())
+        .map((cookie) => cookie.split(';')[0] ?? '')
+        .filter((pair) => pair.length > 0 && !pair.endsWith('='))
+        .join('; ');
+    }
+
+    function submitUserCode(
+      userCode: string,
+      cookie = '',
+      target: DeviceTargetApp = app,
+    ): Promise<Response> {
+      return target.request('/device', {
+        method: 'POST',
+        headers: {
+          'Content-Type': 'application/x-www-form-urlencoded',
+          ...(cookie ? { Cookie: cookie } : {}),
+        },
+        body: new URLSearchParams({ user_code: userCode }).toString(),
+      });
+    }
+
+    function deviceLogin(
+      body: Record<string, string>,
+      cookie: string,
+      target: DeviceTargetApp = app,
+    ): Promise<Response> {
+      return target.request('/device/login', {
+        method: 'POST',
+        headers: {
+          'Content-Type': 'application/x-www-form-urlencoded',
+          ...(cookie ? { Cookie: cookie } : {}),
+        },
+        body: new URLSearchParams(body).toString(),
+      });
+    }
+
+    function deviceApprove(
+      body: Record<string, string>,
+      cookie: string,
+      target: DeviceTargetApp = app,
+    ): Promise<Response> {
+      return target.request('/device/approve', {
+        method: 'POST',
+        headers: {
+          'Content-Type': 'application/x-www-form-urlencoded',
+          ...(cookie ? { Cookie: cookie } : {}),
+        },
+        body: new URLSearchParams(body).toString(),
+      });
+    }
+
+    /**
+     * Drive the whole browser side of the flow: user_code -> login -> decision.
+     * The binding cookie is carried forward at every step, exactly as a browser
+     * would; without it the OP answers 403.
+     */
+    async function runDeviceFlow(
+      overrides: Record<string, string> = {},
+      decision: 'approve' | 'deny' = 'approve',
+      target: DeviceTargetApp = app,
+    ): Promise<{ device_code: string; user_code: string; completed: Response }> {
+      const authorization = await (await requestDeviceAuthorization(overrides, target)).json();
+      const submitted = await submitUserCode(authorization.user_code, '', target);
+      const bindingCookie = cookieJar(submitted);
+      const loginRes = await deviceLogin(
+        {
+          user_code: authorization.user_code,
+          csrf_token: csrfFrom(await submitted.text()),
+          username: 'testuser',
+          password: 'password',
+        },
+        bindingCookie,
+        target,
+      );
+      const sessionCookie = cookieJar(submitted, loginRes);
+      const completed = await deviceApprove(
+        {
+          user_code: authorization.user_code,
+          csrf_token: csrfFrom(await loginRes.text()),
+          decision,
+        },
+        sessionCookie,
+        target,
+      );
+      return {
+        device_code: authorization.device_code,
+        user_code: authorization.user_code,
+        completed,
+      };
+    }
+
+    describe('Device authorization endpoint (RFC 8628 §3.1 / §3.2)', () => {
+      it('should return the six response fields with a non-cacheable body', async () => {
+        const res = await requestDeviceAuthorization();
+        const body = await res.json();
+
+        expect(res.status).toBe(200);
+        expect(res.headers.get('Cache-Control')).toBe('no-store');
+        expect(res.headers.get('Pragma')).toBe('no-cache');
+        expect(Object.keys(body).sort()).toEqual([
+          'device_code',
+          'expires_in',
+          'interval',
+          'user_code',
+          'verification_uri',
+          'verification_uri_complete',
+        ]);
+      });
+
+      it('should return the configured lifetime and poll interval', async () => {
+        const body = await (await requestDeviceAuthorization()).json();
+
+        expect([body.expires_in, body.interval]).toEqual([600, 5]);
+      });
+
+      it('should build verification_uri and verification_uri_complete from the issuer', async () => {
+        const body = await (await requestDeviceAuthorization()).json();
+
+        expect(body.verification_uri).toBe('http://localhost:3000/device');
+        expect(body.verification_uri_complete).toBe(
+          'http://localhost:3000/device?user_code=' + body.user_code,
+        );
+      });
+
+      it('should mint a base-20 user_code in XXXX-XXXX form (RFC 8628 §6.1)', async () => {
+        const body = await (await requestDeviceAuthorization()).json();
+
+        expect(/^[BCDFGHJKLMNPQRSTVWXZ]{4}-[BCDFGHJKLMNPQRSTVWXZ]{4}$/.test(body.user_code)).toBe(true);
+      });
+
+      it('should mint a 256-bit device_code (RFC 8628 §5.2)', async () => {
+        const body = await (await requestDeviceAuthorization()).json();
+
+        expect((body.device_code as string).length).toBe(43);
+      });
+
+      it('should issue a distinct device_code for every request', async () => {
+        const first = await (await requestDeviceAuthorization()).json();
+        const second = await (await requestDeviceAuthorization()).json();
+
+        expect(first.device_code === second.device_code).toBe(false);
+      });
+
+      it('should reject a body that is not form-urlencoded', async () => {
+        const res = await app.request('/device_authorization', {
+          method: 'POST',
+          headers: { 'Content-Type': 'application/json' },
+          body: JSON.stringify({ client_id: 'c-device', scope: 'openid' }),
+        });
+
+        expect(res.status).toBe(400);
+        expect(await res.json()).toEqual({
+          error: 'invalid_request',
+          error_description: 'Device authorization requests must use application/x-www-form-urlencoded',
+        });
+      });
+
+      it('should reject an unauthenticated request with 401 invalid_client', async () => {
+        const res = await app.request('/device_authorization', {
+          method: 'POST',
+          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
+          body: new URLSearchParams({ client_id: 'c-device', scope: 'openid' }).toString(),
+        });
+
+        expect(res.status).toBe(401);
+        expect((await res.json()).error).toBe('invalid_client');
+      });
+
+      it('should reject a client that is not registered for the device grant', async () => {
+        const res = await requestDeviceAuthorization({ client_id: 'c-conf' });
+
+        expect(res.status).toBe(400);
+        expect(await res.json()).toEqual({
+          error: 'unauthorized_client',
+          error_description: 'The client is not authorized to use the device_code grant',
+        });
+      });
+
+      it('should reject a request with no scope', async () => {
+        // RFC 8628 §3.1 makes scope OPTIONAL; this OP requires it (and openid)
+        // everywhere, which is a documented profile restriction.
+        const res = await app.request('/device_authorization', {
+          method: 'POST',
+          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
+          body: new URLSearchParams({ client_id: 'c-device', client_secret: 's' }).toString(),
+        });
+
+        expect(res.status).toBe(400);
+        expect(await res.json()).toEqual({
+          error: 'invalid_request',
+          error_description: 'Missing required parameter: scope',
+        });
+      });
+
+      it('should reject a scope without openid', async () => {
+        const res = await requestDeviceAuthorization({ scope: 'profile' });
+
+        expect(res.status).toBe(400);
+        expect(await res.json()).toEqual({
+          error: 'invalid_scope',
+          error_description: 'The openid scope is required',
+        });
+      });
     });
 
-    it('should not advertise device authorization metadata', async () => {
-      const res = await app.request('/.well-known/openid-configuration');
-      const metadata = await res.json();
+    describe('Discovery metadata (RFC 8628 §4)', () => {
+      it('should advertise the device authorization endpoint', async () => {
+        const metadata = await (await app.request('/.well-known/openid-configuration')).json();
+
+        expect(metadata.device_authorization_endpoint).toBe(
+          'http://localhost:3000/device_authorization',
+        );
+      });
+
+      it('should advertise the device_code grant type', async () => {
+        const metadata = await (await app.request('/.well-known/openid-configuration')).json();
 
-      expect(metadata.device_authorization_endpoint).toBeUndefined();
+        expect((metadata.grant_types_supported as string[]).includes(DEVICE_GRANT_TYPE)).toBe(true);
+      });
     });
 
-    it('should not advertise the device_code grant type', async () => {
-      const res = await app.request('/.well-known/openid-configuration');
-      const metadata = await res.json();
+    describe('Verification UI (RFC 8628 §3.3)', () => {
+      it('should serve the code entry form without authentication', async () => {
+        const res = await app.request('/device');
+
+        expect(res.status).toBe(200);
+        expect(res.headers.get('Content-Type')).toBe('text/html; charset=UTF-8');
+      });
+
+      it('should pre-fill the form from verification_uri_complete (§3.3.1)', async () => {
+        const body = await (await requestDeviceAuthorization()).json();
+        const url = new URL(body.verification_uri_complete);
+        const html = await (await app.request(url.pathname + url.search)).text();
+
+        expect(html.includes('value="' + body.user_code + '"')).toBe(true);
+      });
+
+      it('should not expose a csrf_token before a code has matched', async () => {
+        // The csrf_token only appears on a response that also mints the binding
+        // cookie, so it is never readable by someone who only knows a user_code.
+        const html = await (await app.request('/device')).text();
+
+        expect(csrfFrom(html)).toBe('');
+      });
+
+      it('should answer an unknown user_code with the same reason-free message', async () => {
+        const res = await submitUserCode('BCDF-GHJK');
+
+        expect(res.status).toBe(400);
+        expect((await res.text()).includes('The code is invalid or has expired')).toBe(true);
+      });
+
+      it('should not set a binding cookie for an unknown user_code', async () => {
+        const res = await submitUserCode('BCDF-GHJK');
+
+        expect(res.headers.getSetCookie()).toEqual([]);
+      });
+
+      it('should accept the user_code with its hyphen stripped and lower-cased', async () => {
+        const body = await (await requestDeviceAuthorization()).json();
+        const res = await submitUserCode((body.user_code as string).replace('-', '').toLowerCase());
+
+        expect(res.status).toBe(200);
+      });
+
+      it('should set the binding cookie with the exact hardening attributes', async () => {
+        const body = await (await requestDeviceAuthorization()).json();
+        const res = await submitUserCode(body.user_code);
+        const cookie = res.headers.getSetCookie()[0] ?? '';
+
+        expect(cookie.startsWith('oidc_device_' + (body.user_code as string).replace('-', '') + '=')).toBe(true);
+        expect(cookie.endsWith('; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=600')).toBe(true);
+      });
+
+      it('should show the login form when no OP session exists', async () => {
+        const body = await (await requestDeviceAuthorization()).json();
+        const html = await (await submitUserCode(body.user_code)).text();
+
+        expect(html.includes('action="/device/login"')).toBe(true);
+      });
+
+      it('should embed a csrf_token once the code matched', async () => {
+        const body = await (await requestDeviceAuthorization()).json();
+        const html = await (await submitUserCode(body.user_code)).text();
+
+        expect(csrfFrom(html).length > 0).toBe(true);
+      });
+    });
+
+    describe('Browser binding enforcement (RFC 8628 §5.4)', () => {
+      it('should reject /device/login without the binding cookie even with a valid csrf_token', async () => {
+        // The whole point: a valid csrf_token is obtainable by anyone who knows
+        // the user_code, so it must NOT be sufficient on its own.
+        const body = await (await requestDeviceAuthorization()).json();
+        const submitted = await submitUserCode(body.user_code);
+        const csrfToken = csrfFrom(await submitted.text());
+
+        const res = await deviceLogin(
+          { user_code: body.user_code, csrf_token: csrfToken, username: 'testuser', password: 'password' },
+          '',
+        );
+
+        expect(res.status).toBe(403);
+      });
+
+      it('should not establish a session when /device/login is unbound', async () => {
+        const body = await (await requestDeviceAuthorization()).json();
+        const submitted = await submitUserCode(body.user_code);
+        const csrfToken = csrfFrom(await submitted.text());
+
+        const res = await deviceLogin(
+          { user_code: body.user_code, csrf_token: csrfToken, username: 'testuser', password: 'password' },
+          '',
+        );
+
+        expect(res.headers.getSetCookie()).toEqual([]);
+      });
+
+      it('should reject /device/approve without the binding cookie', async () => {
+        const body = await (await requestDeviceAuthorization()).json();
+        const submitted = await submitUserCode(body.user_code);
+        const bindingCookie = cookieJar(submitted);
+        const loginRes = await deviceLogin(
+          {
+            user_code: body.user_code,
+            csrf_token: csrfFrom(await submitted.text()),
+            username: 'testuser',
+            password: 'password',
+          },
+          bindingCookie,
+        );
+        // Session cookie only: the forged request cannot carry the binding.
+        const sessionOnly = cookieJar(loginRes);
+
+        const res = await deviceApprove(
+          {
+            user_code: body.user_code,
+            csrf_token: csrfFrom(await loginRes.text()),
+            decision: 'approve',
+          },
+          sessionOnly,
+        );
+
+        expect(res.status).toBe(403);
+      });
+
+      it('should leave the record unapproved after an unbound approve attempt', async () => {
+        const body = await (await requestDeviceAuthorization()).json();
+        const submitted = await submitUserCode(body.user_code);
+        const bindingCookie = cookieJar(submitted);
+        const loginRes = await deviceLogin(
+          {
+            user_code: body.user_code,
+            csrf_token: csrfFrom(await submitted.text()),
+            username: 'testuser',
+            password: 'password',
+          },
+          bindingCookie,
+        );
+        await deviceApprove(
+          {
+            user_code: body.user_code,
+            csrf_token: csrfFrom(await loginRes.text()),
+            decision: 'approve',
+          },
+          cookieJar(loginRes),
+        );
+        const res = await pollToken(body.device_code);
+
+        expect((await res.json()).error).toBe('authorization_pending');
+      });
+
+      it('should reject a wrong csrf_token even with a valid binding cookie', async () => {
+        const body = await (await requestDeviceAuthorization()).json();
+        const submitted = await submitUserCode(body.user_code);
+
+        const res = await deviceLogin(
+          { user_code: body.user_code, csrf_token: 'forged', username: 'testuser', password: 'password' },
+          cookieJar(submitted),
+        );
+
+        expect(res.status).toBe(403);
+      });
+
+      it('should invalidate the previous binding when the code is submitted again', async () => {
+        const body = await (await requestDeviceAuthorization()).json();
+        const first = await submitUserCode(body.user_code);
+        const firstCsrf = csrfFrom(await first.text());
+        const firstCookie = cookieJar(first);
+        await submitUserCode(body.user_code);
+
+        const res = await deviceLogin(
+          { user_code: body.user_code, csrf_token: firstCsrf, username: 'testuser', password: 'password' },
+          firstCookie,
+        );
+
+        expect(res.status).toBe(403);
+      });
+
+      it('should clear the binding cookie once the decision is recorded', async () => {
+        const flow = await runDeviceFlow();
+        const cleared = flow.completed.headers.getSetCookie()[0] ?? '';
+
+        expect(cleared.startsWith('oidc_device_' + flow.user_code.replace('-', '') + '=;')).toBe(true);
+        expect(cleared.endsWith('; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=0')).toBe(true);
+      });
+    });
+
+    describe('Token polling (RFC 8628 §3.5)', () => {
+      it('should answer authorization_pending before the user decides', async () => {
+        const body = await (await requestDeviceAuthorization()).json();
+        const res = await pollToken(body.device_code);
+
+        expect(res.status).toBe(400);
+        expect(res.headers.get('Cache-Control')).toBe('no-store');
+        expect(await res.json()).toEqual({
+          error: 'authorization_pending',
+          error_description: 'The authorization request is still pending',
+        });
+      });
+
+      it('should answer slow_down when polled again inside the interval', async () => {
+        const body = await (await requestDeviceAuthorization()).json();
+        await pollToken(body.device_code);
+        const res = await pollToken(body.device_code);
 
-      expect(
-        (metadata.grant_types_supported as string[]).includes(
-          'urn:ietf:params:oauth:grant-type:device_code',
-        ),
-      ).toBe(false);
+        expect(res.status).toBe(400);
+        expect(await res.json()).toEqual({
+          error: 'slow_down',
+          error_description: 'Polling too frequently. Increase the interval by 5 seconds.',
+        });
+      });
+
+      it('should reject a missing device_code with invalid_request', async () => {
+        const res = await app.request('/token', {
+          method: 'POST',
+          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
+          body: new URLSearchParams({
+            grant_type: DEVICE_GRANT_TYPE,
+            client_id: 'c-device',
+            client_secret: 's',
+          }).toString(),
+        });
+
+        expect(await res.json()).toEqual({
+          error: 'invalid_request',
+          error_description: 'Missing required parameter: device_code',
+        });
+      });
+
+      it('should reject an unknown device_code with invalid_grant', async () => {
+        const res = await pollToken('not-a-real-device-code');
+
+        expect(await res.json()).toEqual({
+          error: 'invalid_grant',
+          error_description: 'The device_code is invalid, expired, or was issued to another client',
+        });
+      });
+
+      it('should reject a device_code presented by another client with the same wording', async () => {
+        // RFC 8628 §3.4: the code belongs to the client it was issued to. The
+        // wording matches the unknown-code case so existence is not leaked.
+        const body = await (await requestDeviceAuthorization()).json();
+        const res = await app.request('/token', {
+          method: 'POST',
+          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
+          body: new URLSearchParams({
+            grant_type: DEVICE_GRANT_TYPE,
+            device_code: body.device_code,
+            client_id: 'c-device-other',
+            client_secret: 's',
+          }).toString(),
+        });
+
+        expect(await res.json()).toEqual({
+          error: 'invalid_grant',
+          error_description: 'The device_code is invalid, expired, or was issued to another client',
+        });
+      });
+
+      it('should reject a client that is not registered for the device grant', async () => {
+        const res = await app.request('/token', {
+          method: 'POST',
+          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
+          body: new URLSearchParams({
+            grant_type: DEVICE_GRANT_TYPE,
+            device_code: 'anything',
+            client_id: 'c-conf',
+            client_secret: 's',
+          }).toString(),
+        });
+
+        expect(await res.json()).toEqual({
+          error: 'unauthorized_client',
+          error_description: 'The client is not authorized to use the device_code grant',
+        });
+      });
+
+      it('should answer access_denied after the user denies', async () => {
+        const flow = await runDeviceFlow({}, 'deny');
+        const res = await pollToken(flow.device_code);
+
+        expect(await res.json()).toEqual({
+          error: 'access_denied',
+          error_description: 'The end-user denied the authorization request',
+        });
+      });
+    });
+
+    describe('Token issuance (RFC 8628 §3.5 → OIDC Core 1.0 §3.1.3.3)', () => {
+      it('should issue an access token and an ID Token after approval', async () => {
+        const flow = await runDeviceFlow();
+        const res = await pollToken(flow.device_code);
+        const body = await res.json();
+
+        expect(res.status).toBe(200);
+        expect(res.headers.get('Cache-Control')).toBe('no-store');
+        expect(body.token_type).toBe('Bearer');
+        expect(body.scope).toBe('openid');
+        expect(typeof body.access_token).toBe('string');
+        expect(typeof body.id_token).toBe('string');
+      });
+
+      it('should omit nonce and c_hash from the ID Token', async () => {
+        // RFC 8628 defines no nonce parameter, and there is no authorization code,
+        // so neither claim has a value to carry (OIDC Core 1.0 §2).
+        const flow = await runDeviceFlow();
+        const body = await (await pollToken(flow.device_code)).json();
+        const payload = idTokenPayload(body.id_token);
+
+        expect(payload.nonce).toBeUndefined();
+        expect(payload.c_hash).toBeUndefined();
+      });
+
+      it('should carry the auth_time recorded at approval', async () => {
+        const flow = await runDeviceFlow();
+        const body = await (await pollToken(flow.device_code)).json();
+        const payload = idTokenPayload(body.id_token);
+
+        expect(typeof payload.auth_time).toBe('number');
+        expect(payload.aud).toBe('c-device');
+      });
+
+      it('should let the issued access token reach the UserInfo endpoint', async () => {
+        const flow = await runDeviceFlow();
+        const body = await (await pollToken(flow.device_code)).json();
+        const res = await app.request('/userinfo', {
+          headers: { Authorization: 'Bearer ' + body.access_token },
+        });
+
+        expect(res.status).toBe(200);
+        expect((await res.json()).sub).toBe('testuser');
+      });
+
+      it('should refuse to redeem the same device_code twice', async () => {
+        const flow = await runDeviceFlow();
+        await pollToken(flow.device_code);
+        const res = await pollToken(flow.device_code);
+
+        expect(await res.json()).toEqual({
+          error: 'invalid_grant',
+          error_description: 'The device_code is invalid, expired, or was issued to another client',
+        });
+      });
+
+    it('should issue a refresh token when offline_access was approved', async () => {
+      // OIDC Core 1.0 §11: the approval screen IS the explicit consent, and
+      // c-device is registered for the refresh_token grant.
+      const flow = await runDeviceFlow({ scope: 'openid offline_access' });
+      const res = await pollToken(flow.device_code);
+      const body = await res.json();
+
+      expect(typeof body.refresh_token).toBe('string');
+    });
+    });
+
+    describe('ID Token signing key selection (OIDC Dynamic Client Registration 1.0 §4.2)', () => {
+      /** JOSE header of a compact JWS, decoded. */
+      function joseHeader(jwt: string): Record<string, unknown> {
+        const segment = jwt.split('.')[0] ?? '';
+        return JSON.parse(
+          new TextDecoder().decode(
+            Uint8Array.from(atob(segment.replace(/-/g, '+').replace(/_/g, '/')), (char) => char.charCodeAt(0)),
+          ),
+        );
+      }
+
+      // A client may register id_token_signed_response_alg, and the standard
+      // grants pick a registered key matching it. The device grant MUST NOT
+      // diverge: signing this client's ID Token with whichever key happens to be
+      // ACTIVE would hand it an RS256 token it rejects, and would compute at_hash
+      // with the wrong hash function (OIDC Core 1.0 Section 3.1.3.6).
+      it('should sign the device grant ID Token with the alg the client registered', async () => {
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
+        const mixedProvider: SigningKeyProvider = {
+          // Active key is RS256; the registered set also holds an ES256 key.
+          async getSigningKey(): Promise<SigningKey> {
+            return {
+              privateKey: rs256Pair.privateKey,
+              publicJwk: await crypto.subtle.exportKey('jwk', rs256Pair.publicKey),
+              keyId: 'device-rs256',
+            };
+          },
+          async getSigningKeys(): Promise<SigningKey[]> {
+            return [
+              {
+                privateKey: rs256Pair.privateKey,
+                publicJwk: await crypto.subtle.exportKey('jwk', rs256Pair.publicKey),
+                keyId: 'device-rs256',
+              },
+              {
+                privateKey: es256Pair.privateKey,
+                publicJwk: await crypto.subtle.exportKey('jwk', es256Pair.publicKey),
+                keyId: 'device-es256',
+              },
+            ];
+          },
+        };
+        const mixedApp = createApp({
+          signingKeyProvider: mixedProvider,
+          clientResolver: createInMemoryClientResolver(testClients),
+        });
+        const client = { client_id: 'c-device-es256', client_secret: 's' };
+
+        const flow = await runDeviceFlow(client, 'approve', mixedApp);
+        const body = await (await pollToken(flow.device_code, client, mixedApp)).json();
+        const [encodedHeader = '', encodedPayload = '', encodedSignature = ''] =
+          (body.id_token as string).split('.');
+        const base64 = encodedSignature.replace(/-/g, '+').replace(/_/g, '/');
+        const padded = base64.padEnd(base64.length + ((4 - (base64.length % 4)) % 4), '=');
+        const signatureValid = await crypto.subtle.verify(
+          { name: 'ECDSA', hash: 'SHA-256' },
+          es256Pair.publicKey,
+          Uint8Array.from(atob(padded), (char) => char.charCodeAt(0)),
+          new TextEncoder().encode(encodedHeader + '.' + encodedPayload),
+        );
+
+        expect(joseHeader(body.id_token)).toEqual({
+          alg: 'ES256',
+          typ: 'JWT',
+          kid: 'device-es256',
+        });
+        expect(signatureValid).toBe(true);
+      });
+
+      it('should keep signing with RS256 for a client that registered no alg', async () => {
+        const flow = await runDeviceFlow();
+        const body = await (await pollToken(flow.device_code)).json();
+
+        expect(joseHeader(body.id_token)).toEqual({
+          alg: 'RS256',
+          typ: 'JWT',
+          kid: 'test-key',
+        });
+      });
     });
   });
 
diff --git a/with-device-authorization-grant/routes/device-authorization.ts b/with-device-authorization-grant/routes/device-authorization.ts
new file mode 100644
index 0000000..380c423
--- /dev/null
+++ b/with-device-authorization-grant/routes/device-authorization.ts
@@ -0,0 +1,187 @@
+/**
+ * EXPERIMENTAL — OAuth 2.0 Device Authorization Grant (RFC 8628).
+ *
+ * This route was generated because the OP was created with
+ * `--enable device-authorization-grant`. It is backed by
+ * @maronn-openid-connect/experimental, whose API is NOT stable: it may change in a breaking
+ * way between releases. Do not build production code on it without pinning the
+ * version.
+ *
+ * The device (a TV app, a CLI, an IoT box) POSTs here — back channel,
+ * client-authenticated — and receives a device_code it polls the token endpoint
+ * with, plus a short user_code the end user types into /device on another
+ * device's browser.
+ *
+ * NOTE (RFC 8628 §5.1): rate limiting the user_code guess surface is deliberately
+ * left to the deployment layer (reverse proxy / platform), not implemented here.
+ * An in-process counter cannot work on runtimes without shared memory between
+ * instances (Cloudflare Workers and friends), so putting one here would give a
+ * false sense of protection. The in-band defenses are the 20^8 user_code
+ * entropy, the short TTL, and answering every failed match identically.
+ */
+import { WebRouter } from '../web-router.js';
+import {
+  DeviceAuthorizationError,
+  applyOfflineAccessPolicy,
+  buildDeviceAuthorizationResponse,
+  createDeviceAuthorizationRecord,
+  validateDeviceAuthorizationScope,
+  validateDeviceGrantAllowed,
+} from '@maronn-openid-connect/experimental/device-authorization-grant';
+import {
+  TokenError,
+  extractClientCredentials,
+  resolveAuthenticatedTokenClient,
+  sanitizeErrorDescription,
+  validateClientAuthMethod,
+  verifyClientSecret,
+} from '@maronn-openid-connect/core';
+import { tokenClientResolver as defaultTokenClientResolver } from '../resolvers.js';
+import { deviceAuthorizationStore as defaultDeviceAuthorizationStore } from '../store.js';
+
+/**
+ * EXPERIMENTAL — Device Authorization Grant settings (RFC 8628).
+ *
+ * Imported by the verification UI and the discovery route, so keep all three in
+ * sync when changing them.
+ *
+ * - deviceCodeExpiresIn: §3.2 expires_in, in seconds. Keep it short: it is the
+ *   window in which a user_code can be guessed (§5.1) or phished (§5.4).
+ * - pollInterval: §3.2 interval, in seconds. The token endpoint raises a
+ *   record's own interval by 5 every time it answers slow_down.
+ * - maxLoginAttempts: failed device logins allowed per record before it is
+ *   denied. Per-record only — see the security notes in the verification route.
+ *
+ * Not configurable: the user_code charset (RFC 8628 §6.1 base-20) and length (8).
+ * They carry the entropy claim, so they are constants in the experimental
+ * package rather than something a config typo can weaken.
+ */
+export const deviceAuthorizationConfig = {
+  deviceCodeExpiresIn: 600,
+  pollInterval: 5,
+  maxLoginAttempts: 5,
+};
+
+export const deviceAuthorizationApp = new WebRouter();
+
+/**
+ * RFC 8628 §3.1: the device authorization request body MUST be
+ * application/x-www-form-urlencoded (it follows RFC 6749 §3.2.1).
+ */
+function isFormUrlEncoded(contentType: string): boolean {
+  const [mediaType = ''] = contentType.toLowerCase().split(';');
+  return mediaType.trim() === 'application/x-www-form-urlencoded';
+}
+
+function noStore(c: any): void {
+  // RFC 8628 §3.2 has no explicit rule, but device_code is a credential, so the
+  // response follows the token response rules of RFC 6749 §5.1.
+  c.header('Cache-Control', 'no-store');
+  c.header('Pragma', 'no-cache');
+}
+
+/**
+ * Device Authorization Endpoint
+ * RFC 8628 §3.1 / §3.2
+ */
+deviceAuthorizationApp.post('/', async (c) => {
+  const contentType = c.req.header('Content-Type') ?? '';
+  if (!isFormUrlEncoded(contentType)) {
+    noStore(c);
+    return c.json({ error: 'invalid_request', error_description: 'Device authorization requests must use application/x-www-form-urlencoded' }, 400);
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
+    noStore(c);
+    return c.json({ error: 'invalid_request', error_description: `Parameter "${sanitizeErrorDescription(duplicateKey)}" must not be repeated` }, 400);
+  }
+
+  const authorization = c.req.header('Authorization') ?? '';
+
+  try {
+    const tokenClientResolver = c.get('tokenClientResolver') ?? defaultTokenClientResolver;
+    const deviceStore = c.get('deviceAuthorizationStore') ?? defaultDeviceAuthorizationStore;
+    const config = c.get('config');
+
+    // --- Client authentication pipeline -------------------------------------
+    // RFC 8628 §3.1: "The client authentication requirements of Section 3.2.1 of
+    // [RFC6749] apply" — so this is the same pipeline the token endpoint runs,
+    // step function for step function. Public clients present only client_id.
+    const presentedCredentials = extractClientCredentials({
+      params,
+      authorizationHeader: authorization,
+    });
+    const client = await resolveAuthenticatedTokenClient(
+      presentedCredentials.clientId,
+      tokenClientResolver,
+    );
+    validateClientAuthMethod(client, presentedCredentials);
+    await verifyClientSecret(client, presentedCredentials.clientSecret);
+
+    // --- Device authorization pipeline --------------------------------------
+    // Each step below is an independent function from
+    // @maronn-openid-connect/experimental/device-authorization-grant, called in RFC 8628 §3.1
+    // order. Delete a call to drop that validation, or insert your own logic
+    // between steps.
+
+    // RFC 6749 §5.2: the client must be registered for the device_code grant.
+    validateDeviceGrantAllowed(client);
+
+    // RFC 8628 §3.1 leaves scope OPTIONAL, but this OP requires scope and openid
+    // everywhere (same rule as /authorize). Requests that omit scope — legal per
+    // RFC 8628 — are therefore rejected: a known, deliberate profile restriction.
+    const requestedScope = validateDeviceAuthorizationScope(params['scope']);
+
+    // OIDC Core 1.0 §11: drop offline_access when it could never be granted.
+    const scope = applyOfflineAccessPolicy(requestedScope, {
+      client,
+      refreshTokenFeatureEnabled: true,
+    });
+
+    // RFC 8628 §3.2 / §5.2: mint a 256-bit device_code and a collision-checked
+    // base-20 user_code, then store the pending record under both.
+    const record = await createDeviceAuthorizationRecord({
+      clientId: client.clientId,
+      scope,
+      store: deviceStore,
+      expiresIn: deviceAuthorizationConfig.deviceCodeExpiresIn,
+      interval: deviceAuthorizationConfig.pollInterval,
+    });
+
+    // Never log device_code or user_code: both are live credentials for the
+    // lifetime of the record (RFC 8628 §5.1 / §5.2).
+
+    noStore(c);
+    return c.json(buildDeviceAuthorizationResponse(record, config.issuer));
+  } catch (error) {
+    noStore(c);
+    if (error instanceof DeviceAuthorizationError) {
+      // RFC 6749 §5.2 error shape. Authentication failures never reach here —
+      // they are core TokenErrors, handled below with their 401.
+      return c.json({ error: error.code, error_description: error.errorDescription }, error.statusCode);
+    }
+    if (error instanceof TokenError) {
+      const status = error.statusCode as 400 | 401;
+      if (error.wwwAuthenticate) {
+        c.header('WWW-Authenticate', error.wwwAuthenticate);
+      }
+      return c.json({ error: error.error, error_description: error.errorDescription }, status);
+    }
+    return c.json({ error: 'server_error' }, 500);
+  }
+});
diff --git a/with-device-authorization-grant/routes/device.ts b/with-device-authorization-grant/routes/device.ts
new file mode 100644
index 0000000..69f5b30
--- /dev/null
+++ b/with-device-authorization-grant/routes/device.ts
@@ -0,0 +1,325 @@
+/**
+ * EXPERIMENTAL — OAuth 2.0 Device Authorization Grant, verification UI
+ * (RFC 8628 §3.3).
+ *
+ * This route was generated because the OP was created with
+ * `--enable device-authorization-grant`. It is backed by
+ * @maronn-openid-connect/experimental, whose API is NOT stable: it may change in a breaking
+ * way between releases. Do not build production code on it without pinning the
+ * version.
+ *
+ * The end user opens /device on a second device, types the user_code the first
+ * device is showing, signs in, and approves or denies. The device learns the
+ * outcome only by polling the token endpoint — there is no push channel.
+ *
+ * ## Why every POST here demands a binding cookie
+ *
+ * The user_code is known to whoever started the flow, and that party can be the
+ * attacker. A CSRF token stored on the record is therefore not a defense: the
+ * attacker can fetch a valid one by POSTing /device with their own code. What
+ * stops both consent coercion (a forged /device/approve that ships the victim's
+ * tokens to the attacker's device) and login CSRF (a forged /device/login that
+ * plants the attacker's session in the victim's browser) is the binding cookie
+ * minted below — see buildDeviceBindingCookie() in store.ts for the full model.
+ * The hidden csrf_token is kept as defense in depth, never as the only check.
+ */
+import { WebRouter } from '../web-router.js';
+import {
+  DeviceAuthorizationError,
+  DeviceVerificationError,
+  INVALID_USER_CODE_MESSAGE,
+  approveDeviceAuthorization,
+  denyDeviceAuthorization,
+  findPendingRecordByUserCode,
+  issueVerificationBinding,
+  recordDeviceLoginFailure,
+  validateVerificationBinding,
+  validateVerificationCsrfToken,
+  type DeviceAuthorizationRecord,
+} from '@maronn-openid-connect/experimental/device-authorization-grant';
+import { generateRandomString } from '@maronn-openid-connect/core';
+import {
+  browserSessionStore as defaultBrowserSessionStore,
+  buildClearedDeviceBindingCookie,
+  buildDeviceBindingCookie,
+  buildSessionCookie,
+  parseDeviceBindingSecret,
+  parseSessionId,
+  userStore,
+} from '../store.js';
+import { defaultViews, renderView } from '../views.js';
+import { deviceAuthorizationConfig } from './device-authorization.js';
+
+export const deviceApp = new WebRouter();
+
+/**
+ * Attach a Set-Cookie to a Response a view already produced.
+ *
+ * renderView() builds its own Response, so headers staged on the framework
+ * context never reach it. Rebuilding the Response is the framework-neutral way
+ * to add the cookie without making views cookie-aware.
+ */
+function withCookie(response: Response, cookie: string): Response {
+  const headers = new Headers(response.headers);
+  headers.append('Set-Cookie', cookie);
+  return new Response(response.body, {
+    status: response.status,
+    statusText: response.statusText,
+    headers,
+  });
+}
+
+/**
+ * Remaining lifetime of a record, in whole seconds, never negative.
+ *
+ * Rounded up so the cookie always outlives the record it binds: a cookie that
+ * expired first would turn a still-valid verification into an unexplained 403.
+ */
+function remainingTtlSeconds(record: DeviceAuthorizationRecord): number {
+  return Math.max(0, Math.ceil((record.expiresAt.getTime() - Date.now()) / 1000));
+}
+
+/**
+ * Re-render the code entry form with the single, reason-free failure message.
+ *
+ * RFC 8628 §5.1: unknown, expired and already-used codes must be
+ * indistinguishable, otherwise the response itself confirms which codes exist.
+ */
+function renderInvalidUserCode(views: typeof defaultViews, userCode: string): Response {
+  return renderView(
+    views.deviceVerificationPage({ userCode, error: INVALID_USER_CODE_MESSAGE }),
+    { status: 400 },
+  );
+}
+
+/** Map a verification failure to its error page; anything else is re-thrown. */
+function renderVerificationError(views: typeof defaultViews, error: unknown): Response {
+  if (error instanceof DeviceVerificationError) {
+    return renderView(
+      views.errorPage({ error: error.message, statusCode: error.statusCode }),
+      { status: error.statusCode },
+    );
+  }
+  if (error instanceof DeviceAuthorizationError) {
+    return renderView(
+      views.errorPage({ error: error.errorDescription, statusCode: 400 }),
+      { status: 400 },
+    );
+  }
+  throw error;
+}
+
+/**
+ * User code entry form - GET
+ * RFC 8628 §3.3 / §3.3.1
+ *
+ * Unauthenticated and side-effect free. A user_code in the query string
+ * (verification_uri_complete) only pre-fills the field: nothing is looked up or
+ * mutated until the form is submitted, so following the complete URI never
+ * consumes or reveals anything.
+ */
+deviceApp.get('/', (c) => {
+  const views = c.get('views') ?? defaultViews;
+  return renderView(views.deviceVerificationPage({ userCode: c.req.query('user_code') ?? '' }));
+});
+
+/**
+ * User code submission - POST
+ * RFC 8628 §3.3
+ *
+ * On a match this is where the browser binding is minted, so this is also the
+ * first response that may carry a csrf_token. Everything downstream requires the
+ * cookie this response sets.
+ */
+deviceApp.post('/', async (c) => {
+  const body = await c.req.parseBody();
+  const submittedUserCode = String(body['user_code'] ?? '');
+
+  const views = c.get('views') ?? defaultViews;
+  const deviceStore = c.get('deviceAuthorizationStore');
+  const browserSessionStore = c.get('browserSessionStore') ?? defaultBrowserSessionStore;
+
+  const record = await findPendingRecordByUserCode(submittedUserCode, deviceStore);
+  if (!record) {
+    return renderInvalidUserCode(views, submittedUserCode);
+  }
+
+  // Rotate the binding secret and the csrf token together. A second browser
+  // submitting the same user_code takes the binding over (last writer wins);
+  // that is inherent to a flow whose identifier is shareable by design.
+  const { bindingSecret, csrfToken } = await issueVerificationBinding(record, deviceStore);
+  const cookie = buildDeviceBindingCookie(
+    record.userCode,
+    bindingSecret,
+    remainingTtlSeconds(record),
+  );
+
+  const sessionId = parseSessionId(c.req.header('Cookie') ?? null);
+  const session = sessionId ? await browserSessionStore.get(sessionId) : undefined;
+  if (session) {
+    return withCookie(renderView(views.deviceApprovalPage({
+      userCode: record.userCodeDisplay,
+      csrfToken,
+      clientId: record.clientId,
+      scopes: record.scope,
+    })), cookie);
+  }
+
+  return withCookie(renderView(views.deviceLoginPage({
+    userCode: record.userCodeDisplay,
+    csrfToken,
+  })), cookie);
+});
+
+/**
+ * Device login - POST
+ * RFC 8628 §3.3
+ *
+ * Binding first, then CSRF, then credentials: the binding is what proves this is
+ * the browser that submitted the user_code, and it must gate the step that would
+ * otherwise let a forged POST establish an OP session in the victim's browser.
+ */
+deviceApp.post('/login', async (c) => {
+  const body = await c.req.parseBody();
+  const submittedUserCode = String(body['user_code'] ?? '');
+  const csrfToken = String(body['csrf_token'] ?? '');
+  const username = String(body['username'] ?? '');
+  const password = String(body['password'] ?? '');
+
+  const views = c.get('views') ?? defaultViews;
+  const deviceStore = c.get('deviceAuthorizationStore');
+  const browserSessionStore = c.get('browserSessionStore') ?? defaultBrowserSessionStore;
+  const authenticateUser =
+    c.get('authenticateUser') ??
+    ((u: string, p: string) => userStore.authenticate(u, p));
+
+  const record = await findPendingRecordByUserCode(submittedUserCode, deviceStore);
+  if (!record) {
+    return renderInvalidUserCode(views, submittedUserCode);
+  }
+
+  try {
+    await validateVerificationBinding(
+      record,
+      parseDeviceBindingSecret(c.req.header('Cookie') ?? null, record.userCode),
+    );
+    validateVerificationCsrfToken(record, csrfToken);
+  } catch (error) {
+    return renderVerificationError(views, error);
+  }
+
+  // Swap point: replace this with your own credential check (LDAP, WebAuthn, an
+  // upstream IdP) without touching anything above or below it.
+  const user = await authenticateUser(username, password);
+  if (!user) {
+    // Per-record throttling only. An attacker holding a device-grant client can
+    // mint unlimited records, so the aggregate password-guess budget is the same
+    // as the one on /login — subject-scoped throttling is tracked separately in
+    // tasks/p2-login-attempt-throttling-subject-scope.md.
+    const failure = await recordDeviceLoginFailure(
+      record,
+      deviceStore,
+      deviceAuthorizationConfig.maxLoginAttempts,
+    );
+    if (!failure.canRetry) {
+      // The record is now denied: the device gets access_denied on its next poll.
+      return renderView(views.errorPage({
+        error: 'Too many login attempts',
+        statusCode: 429,
+      }), { status: 429 });
+    }
+    return renderView(views.deviceLoginPage({
+      userCode: record.userCodeDisplay,
+      csrfToken,
+      error: 'Invalid credentials',
+      remainingAttempts: failure.remainingAttempts,
+    }));
+  }
+
+  const authTime = Math.floor(Date.now() / 1000);
+  const sessionId = generateRandomString(32);
+  await browserSessionStore.set(sessionId, { subject: user.sub, authTime });
+
+  // Two cookies on one response: the new OP session, and the binding cookie the
+  // approval POST will have to present again.
+  const withSession = withCookie(renderView(views.deviceApprovalPage({
+    userCode: record.userCodeDisplay,
+    csrfToken,
+    clientId: record.clientId,
+    scopes: record.scope,
+  })), buildSessionCookie(sessionId));
+  return withSession;
+});
+
+/**
+ * Approve or deny - POST
+ * RFC 8628 §3.3
+ *
+ * The only state-changing step of the UI, so it demands all three: an OP
+ * session, the binding cookie, and the csrf_token.
+ */
+deviceApp.post('/approve', async (c) => {
+  const body = await c.req.parseBody();
+  const submittedUserCode = String(body['user_code'] ?? '');
+  const csrfToken = String(body['csrf_token'] ?? '');
+  const decision = String(body['decision'] ?? '');
+
+  const views = c.get('views') ?? defaultViews;
+  const deviceStore = c.get('deviceAuthorizationStore');
+  const browserSessionStore = c.get('browserSessionStore') ?? defaultBrowserSessionStore;
+  const consentResolver = c.get('consentResolver');
+
+  const record = await findPendingRecordByUserCode(submittedUserCode, deviceStore);
+  if (!record) {
+    return renderInvalidUserCode(views, submittedUserCode);
+  }
+
+  const sessionId = parseSessionId(c.req.header('Cookie') ?? null);
+  const session = sessionId ? await browserSessionStore.get(sessionId) : undefined;
+  if (!session) {
+    return renderView(views.errorPage({
+      error: 'Sign in again to approve this device',
+      statusCode: 401,
+    }), { status: 401 });
+  }
+
+  const clearCookie = buildClearedDeviceBindingCookie(record.userCode);
+  try {
+    await validateVerificationBinding(
+      record,
+      parseDeviceBindingSecret(c.req.header('Cookie') ?? null, record.userCode),
+    );
+
+    if (decision === 'approve') {
+      // csrf_token is validated inside; the record moves to approved with the
+      // subject, auth_time, scope and a fresh grantId the token endpoint reads.
+      const approved = await approveDeviceAuthorization({
+        record,
+        store: deviceStore,
+        csrfToken,
+        subject: session.subject,
+        authTime: session.authTime,
+      });
+      // Record the consent the same way /consent does, so a later Authorization
+      // Code Flow for this client skips the consent screen (OIDC Core 1.0 §3.1.2.4).
+      await consentResolver?.recordConsent?.(
+        approved.subject,
+        approved.clientId,
+        approved.approvedScope ?? approved.scope,
+      );
+      await consentResolver?.recordGrant?.(approved.subject, approved.clientId, approved.grantId);
+      return withCookie(renderView(views.deviceCompletedPage({
+        approved: true,
+        clientId: approved.clientId,
+      })), clearCookie);
+    }
+
+    await denyDeviceAuthorization({ record, store: deviceStore, csrfToken });
+    return withCookie(renderView(views.deviceCompletedPage({
+      approved: false,
+      clientId: record.clientId,
+    })), clearCookie);
+  } catch (error) {
+    return renderVerificationError(views, error);
+  }
+});
diff --git a/default-op/routes/discovery.ts b/with-device-authorization-grant/routes/discovery.ts
index 3208501..b6487be 100644
--- a/default-op/routes/discovery.ts
+++ b/with-device-authorization-grant/routes/discovery.ts
@@ -92,7 +92,7 @@ discoveryApp.get('/', (c) => {
       'phone_number',
       'phone_number_verified',
     ],
-    grantTypesSupported: ['authorization_code', 'refresh_token'],
+    grantTypesSupported: ['authorization_code', 'refresh_token', 'urn:ietf:params:oauth:grant-type:device_code'],
     // RFC 6749 §2.1 / OAuth 2.1 §2.4: 'none' advertises that public clients
     // (no client_secret) are accepted at the token endpoint.
     tokenEndpointAuthMethodsSupported: [
@@ -144,5 +144,7 @@ discoveryApp.get('/', (c) => {
   return c.json({
     ...metadata,
     code_challenge_methods_supported: ['S256'],
+    // EXPERIMENTAL — RFC 8628 §4 metadata.
+    device_authorization_endpoint: `${issuer}/device_authorization`,
   });
 });
diff --git a/default-op/routes/token.ts b/with-device-authorization-grant/routes/token.ts
index a0d0f5c..b7c4758 100644
--- a/default-op/routes/token.ts
+++ b/with-device-authorization-grant/routes/token.ts
@@ -53,6 +53,12 @@ import {
   refreshTokenStore as defaultRefreshTokenStore,
 } from '../store.js';
 import type { RegisteredClient } from '../config.js';
+import {
+  DEVICE_CODE_GRANT_TYPE,
+  DeviceAuthorizationError,
+  processDeviceCodeGrant,
+} from '@maronn-openid-connect/experimental/device-authorization-grant';
+import { deviceAuthorizationStore as defaultDeviceAuthorizationStore } from '../store.js';
 
 export const tokenApp = new WebRouter();
 
@@ -171,6 +177,194 @@ tokenApp.post('/', async (c) => {
 
     const authenticatedClientId = presentedCredentials.clientId;
 
+    // --- EXPERIMENTAL: OAuth 2.0 Device Authorization Grant (RFC 8628 §3.4) ---
+    // Dispatched right after client authentication and BEFORE core's
+    // validateGrantTypeSupported, which does not know the URN and would reject it
+    // with unsupported_grant_type. The branch answers the request itself and
+    // never falls through to the standard grants.
+    //
+    // Backed by @maronn-openid-connect/experimental, whose API is NOT stable: it may change
+    // in a breaking way between releases. Do not build production code on it
+    // without pinning the version.
+    if (params.grant_type === DEVICE_CODE_GRANT_TYPE) {
+      const deviceStore = c.get('deviceAuthorizationStore') ?? defaultDeviceAuthorizationStore;
+
+      // RFC 8628 §3.5 state machine. Everything except "approved" throws:
+      // authorization_pending / slow_down / access_denied / expired_token, plus
+      // invalid_request / invalid_grant / unauthorized_client from §3.4.
+      const deviceGrant = await processDeviceCodeGrant({
+        params,
+        client: tokenClient,
+        store: deviceStore,
+      });
+
+      // config / privateKey / keyId are bound further down for the standard
+      // grants. This branch reads them on its own so the generated output is
+      // unchanged when the feature is off; it returns, so nothing runs twice.
+      const deviceConfig = c.get('config');
+      const devicePrivateKey = c.get('privateKey');
+      const deviceKeyId = c.get('keyId');
+      // T-022: the ID Token this grant issues follows the SAME key-selection rule
+      // as the standard grants — pick a registered ID Token key whose alg matches
+      // the client's id_token_signed_response_alg (OIDC Dynamic Client
+      // Registration 1.0 §2), not the general-purpose ACTIVE key. Using the
+      // active key would hand an ES256-registered client an RS256 ID Token, which
+      // it rejects, and would hash at_hash with the wrong algorithm.
+      const deviceIdTokenSigningKeys = (c.get('idTokenSigningKeys') as SigningKey[] | undefined) ?? [];
+      const deviceFallbackIdKey: SigningKey | undefined =
+        c.get('idTokenPrivateKey') !== undefined
+          ? {
+              privateKey: c.get('idTokenPrivateKey'),
+              publicJwk: c.get('idTokenPublicJwk'),
+              keyId: c.get('idTokenKeyId') ?? deviceKeyId,
+            }
+          : undefined;
+      const deviceRegisteredClient = (await tokenClientResolver.findClient(
+        authenticatedClientId,
+      )) as RegisteredClient | null;
+      const deviceRequestedIdTokenAlg = deviceRegisteredClient?.idTokenSignedResponseAlg;
+      let deviceSelectedIdTokenKey: SigningKey;
+      if (deviceIdTokenSigningKeys.length > 0) {
+        try {
+          deviceSelectedIdTokenKey = selectSigningKeyByAlg(deviceIdTokenSigningKeys, deviceRequestedIdTokenAlg);
+        } catch {
+          c.header('Cache-Control', 'no-store');
+          c.header('Pragma', 'no-cache');
+          return c.json(
+            {
+              error: 'server_error',
+              error_description: `No ID Token signing key registered for alg "${deviceRequestedIdTokenAlg ?? 'RS256'}"`,
+            },
+            500,
+          );
+        }
+      } else if (deviceFallbackIdKey) {
+        deviceSelectedIdTokenKey = deviceFallbackIdKey;
+      } else {
+        c.header('Cache-Control', 'no-store');
+        c.header('Pragma', 'no-cache');
+        return c.json({ error: 'server_error', error_description: 'No ID Token signing key registered' }, 500);
+      }
+      const deviceIdTokenPrivateKey = deviceSelectedIdTokenKey.privateKey;
+      const deviceIdTokenKeyId = deviceSelectedIdTokenKey.keyId;
+      const deviceIssuer: AccessTokenIssuer =
+        deviceConfig.accessTokenFormat === 'opaque'
+          ? createOpaqueAccessTokenIssuer()
+          : createJwtAccessTokenIssuer();
+
+      // Same aud policy as the standard token route: the UserInfo endpoint stays
+      // a permanent member (RFC 9068 §3). RFC 8628 has no resource parameter, so
+      // nothing else is requested.
+      const deviceAudience = buildAccessTokenAudience({
+        userInfoEndpoint: `${deviceConfig.issuer}/userinfo`,
+        issuer: deviceConfig.issuer,
+      });
+
+      const deviceIssuedAt = Math.floor(Date.now() / 1000);
+      const deviceAccessTokenPayload = buildAccessTokenPayload({
+        issuer: deviceConfig.issuer,
+        subject: deviceGrant.subject,
+        clientId: deviceGrant.clientId,
+        scope: deviceGrant.scope,
+        audience: deviceAudience,
+        expiresIn: deviceConfig.accessTokenExpiresIn,
+        issuedAt: deviceIssuedAt,
+      });
+      const deviceAccessToken = await deviceIssuer.issue({
+        payload: deviceAccessTokenPayload,
+        privateKey: devicePrivateKey,
+        keyId: deviceKeyId,
+      });
+
+      // The device authorization endpoint requires the openid scope, so an ID
+      // Token is always issued. It carries no nonce (RFC 8628 defines no such
+      // parameter, and OIDC Core 1.0 §2 only requires nonce when the
+      // authentication request carried one) and no c_hash (there is no code).
+      const deviceAtHash = await computeAtHash(deviceAccessToken, deviceIdTokenPrivateKey);
+      const deviceAcrResolver = c.get('acrResolver') as AcrResolver | undefined;
+      const { acr: deviceAcr, amr: deviceAmr } = await resolveAcrAmr({
+        subject: deviceGrant.subject,
+        clientId: deviceGrant.clientId,
+        acrResolver: deviceAcrResolver,
+      });
+      const deviceIdTokenPayload = buildIdTokenPayload({
+        issuer: deviceConfig.issuer,
+        subject: deviceGrant.subject,
+        clientId: deviceGrant.clientId,
+        scope: deviceGrant.scope,
+        expiresIn: deviceConfig.idTokenExpiresIn,
+        issuedAt: deviceIssuedAt,
+        atHash: deviceAtHash,
+        authTime: deviceGrant.authTime,
+        acr: deviceAcr,
+        amr: deviceAmr,
+      });
+      const deviceIdToken = await generateIdToken({
+        payload: deviceIdTokenPayload,
+        privateKey: deviceIdTokenPrivateKey,
+        keyId: deviceIdTokenKeyId,
+      });
+
+      await accessTokenStore.set(deviceAccessToken, {
+        sub: deviceGrant.subject,
+        clientId: deviceGrant.clientId,
+        scope: deviceGrant.scope,
+        expiresAt: deviceIssuedAt + deviceConfig.accessTokenExpiresIn,
+        // Inherit the grantId minted at approval so revoking the grant kills
+        // every token issued from this device authorization.
+        grantId: deviceGrant.grantId,
+        iat: deviceIssuedAt,
+        nbf: deviceIssuedAt,
+        audience: deviceAudience,
+        issuer: deviceConfig.issuer,
+        jti: deviceAccessTokenPayload.jti,
+      });
+
+      // OIDC Core 1.0 §11: offline_access survived the device authorization
+      // endpoint's policy check only if this client may hold refresh tokens, and
+      // the approval screen the user just went through IS the explicit consent
+      // that §11 asks for. Nothing further to gate on here.
+      const deviceRefreshToken = deviceGrant.scope.includes('offline_access')
+        ? generateRandomString(32)
+        : undefined;
+      if (deviceRefreshToken) {
+        const deviceRefreshTokenStore = c.get('refreshTokenStore') ?? defaultRefreshTokenStore;
+        await deviceRefreshTokenStore.set(deviceRefreshToken, {
+          subject: deviceGrant.subject,
+          clientId: deviceGrant.clientId,
+          scope: deviceGrant.scope,
+          // OAuth 2.1 §6.1: absolute lifetime from initial issuance; rotations
+          // inherit originalIssuedAt so the deadline never slides forward.
+          expiresAt: deviceIssuedAt + deviceConfig.refreshTokenAbsoluteLifetime,
+          originalIssuedAt: deviceIssuedAt,
+          used: false,
+          grantId: deviceGrant.grantId,
+          iat: deviceIssuedAt,
+          issuer: deviceConfig.issuer,
+          audience: deviceAudience,
+          authTime: deviceGrant.authTime,
+          // RFC 8628 has no nonce parameter, so the re-issued ID Token has none
+          // to preserve either.
+          nonce: undefined,
+          acr: deviceAcr,
+          amr: deviceAmr,
+          azp: undefined,
+        });
+      }
+
+      // RFC 6749 §5.1: token responses MUST NOT be cached.
+      c.header('Cache-Control', 'no-store');
+      c.header('Pragma', 'no-cache');
+      return c.json({
+        access_token: deviceAccessToken,
+        token_type: 'Bearer' as const,
+        expires_in: deviceConfig.accessTokenExpiresIn,
+        id_token: deviceIdToken,
+        scope: deviceGrant.scope.join(' '),
+        refresh_token: deviceRefreshToken,
+      });
+    }
+
     // --- Token request validation pipeline --------------------------------
     // Each step below is an independent core function, called in the same order
     // as core's validateTokenRequest(). Delete a call to drop that validation,
@@ -591,6 +785,18 @@ tokenApp.post('/', async (c) => {
     c.header('Pragma', 'no-cache');
     return c.json(tokenResponse);
   } catch (error) {
+    if (error instanceof DeviceAuthorizationError) {
+      // RFC 8628 §3.5: authorization_pending / slow_down / access_denied /
+      // expired_token use the RFC 6749 §5.2 shape and are always 400. A 401 can
+      // only come from client authentication, which runs before the branch and
+      // throws core's TokenError.
+      c.header('Cache-Control', 'no-store');
+      c.header('Pragma', 'no-cache');
+      return c.json(
+        { error: error.code, error_description: error.errorDescription },
+        error.statusCode,
+      );
+    }
     if (error instanceof TokenError) {
       const status = error.statusCode as 400 | 401;
       // RFC 6750 Section 3 / OAuth 2.1 Section 5.2: 401 responses include WWW-Authenticate
diff --git a/default-op/store.ts b/with-device-authorization-grant/store.ts
index e530896..7412bab 100644
--- a/default-op/store.ts
+++ b/with-device-authorization-grant/store.ts
@@ -6,6 +6,10 @@ import type {
   RefreshTokenInfo,
   UserClaims,
 } from '@maronn-openid-connect/core';
+import type {
+  DeviceAuthorizationRecord,
+  DeviceAuthorizationStore,
+} from '@maronn-openid-connect/experimental/device-authorization-grant';
 
 /**
  * In-memory Authorization Transaction Store.
@@ -823,3 +827,163 @@ export const authSessionStore = defaultProviderStores.authSessionStore;
 export const browserSessionStore = defaultProviderStores.browserSessionStore;
 export const consentStore = defaultProviderStores.consentStore;
 export const userStore = defaultProviderStores.userStore;
+
+/**
+ * EXPERIMENTAL — device verification binding cookie (RFC 8628 §5.4 / §3.3).
+ *
+ * Why this exists: the user_code is, by design, known to whoever started the
+ * device flow — and that party can be the attacker. A CSRF token that hangs off
+ * the record is therefore worthless on its own: the attacker POSTs /device with
+ * their own code, reads the token, and can then forge `POST /device/approve`
+ * (consent coercion: the victim's tokens land on the attacker's device) or
+ * `POST /device/login` (login CSRF: the victim's browser gets the attacker's
+ * OP session). Neither is stopped by keeping the token secret.
+ *
+ * The binding is what stops them. On a successful user_code match the OP mints a
+ * bindingSecret, hands the raw value to that one browser in an HttpOnly cookie,
+ * and stores only its SHA-256 hash on the record. /device/login and
+ * /device/approve refuse to run unless the presented cookie hashes to the stored
+ * value, so a forged cross-site POST — which cannot carry the victim's cookie
+ * (SameSite=Lax), and whose victim never held this record's cookie anyway — is
+ * rejected without relying on any secret staying secret.
+ *
+ * Unlike the optional transaction-binding feature this is ALWAYS on: for the
+ * authorize flow the transaction_id is normally confidential, so binding is
+ * extra hardening, while here the identifier is public to the attacker by
+ * construction. The cost is that driving the verification UI by hand with curl
+ * needs a cookie jar (-c / -b).
+ *
+ * The cookie name embeds the normalized user_code so two device flows can run in
+ * the same browser without overwriting each other's secret.
+ */
+export const DEVICE_BINDING_COOKIE_PREFIX = 'oidc_device_';
+
+/**
+ * Build the Set-Cookie value binding one device verification to this browser.
+ * Same attributes as the session cookie: HttpOnly (no JS access), Secure (HTTPS
+ * only; http://localhost is treated as trustworthy by browsers) and
+ * SameSite=Lax. Max-Age matches the remaining record TTL so an abandoned
+ * verification does not leave a cookie behind.
+ */
+export function buildDeviceBindingCookie(
+  userCode: string,
+  bindingSecret: string,
+  ttlSeconds: number,
+): string {
+  return (
+    DEVICE_BINDING_COOKIE_PREFIX + userCode + '=' + bindingSecret +
+    '; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=' + String(ttlSeconds)
+  );
+}
+
+/**
+ * Build the Set-Cookie value that clears the binding cookie once the user has
+ * approved or denied, so the browser does not accumulate one cookie per flow.
+ */
+export function buildClearedDeviceBindingCookie(userCode: string): string {
+  return (
+    DEVICE_BINDING_COOKIE_PREFIX + userCode +
+    '=; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=0'
+  );
+}
+
+/**
+ * Extract the binding secret for one device verification from a Cookie header.
+ * Returns null when the header is missing or this record's cookie is absent,
+ * which validateVerificationBinding() rejects with 403.
+ */
+export function parseDeviceBindingSecret(
+  cookieHeader: string | null,
+  userCode: string,
+): string | null {
+  if (!cookieHeader) return null;
+  const name = DEVICE_BINDING_COOKIE_PREFIX + userCode;
+  for (const part of cookieHeader.split(';')) {
+    const trimmed = part.trim();
+    const eq = trimmed.indexOf('=');
+    if (eq === -1) continue;
+    if (trimmed.slice(0, eq) === name) {
+      return trimmed.slice(eq + 1);
+    }
+  }
+  return null;
+}
+
+/**
+ * EXPERIMENTAL — in-memory device authorization store (RFC 8628).
+ *
+ * Replace with a persistent store (Redis, KV, database) in production. Treat
+ * deviceCode and userCode as opaque external values: never interpolate them into
+ * a query, always bind them as parameters.
+ *
+ * - save / update: persist the record, ideally with a TTL derived from
+ *   record.expiresAt so entries cannot pile up.
+ * - consume(deviceCode): fetch AND delete in one atomic operation. A non-atomic
+ *   implementation lets the same device_code be redeemed concurrently.
+ * - Expired records whose device stopped polling are never reclaimed by the
+ *   token endpoint. A persistent implementation MAY drop them on its own after a
+ *   grace period (roughly one TTL); polling after that answers invalid_grant
+ *   instead of expired_token, which ends the client's flow just the same.
+ */
+export class InMemoryDeviceAuthorizationStore implements DeviceAuthorizationStore {
+  private records = new Map<string, DeviceAuthorizationRecord>();
+
+  async save(record: DeviceAuthorizationRecord): Promise<void> {
+    this.evictExpired();
+    this.records.set(record.deviceCode, record);
+  }
+
+  async findByDeviceCode(deviceCode: string): Promise<DeviceAuthorizationRecord | null> {
+    return this.records.get(deviceCode) ?? null;
+  }
+
+  async findByUserCode(userCode: string): Promise<DeviceAuthorizationRecord | null> {
+    for (const record of this.records.values()) {
+      if (record.userCode === userCode) return record;
+    }
+    return null;
+  }
+
+  async update(record: DeviceAuthorizationRecord): Promise<void> {
+    this.records.set(record.deviceCode, record);
+  }
+
+  async delete(deviceCode: string): Promise<void> {
+    this.records.delete(deviceCode);
+  }
+
+  async consume(deviceCode: string): Promise<DeviceAuthorizationRecord | null> {
+    const record = this.records.get(deviceCode) ?? null;
+    // Single use (RFC 8628 §3.5): delete on read so a replay of the same
+    // device_code can never mint a second token.
+    this.records.delete(deviceCode);
+    return record;
+  }
+
+  /**
+   * Drop records whose lifetime passed long enough ago that no device is still
+   * polling them, so an idle store cannot grow unbounded. The grace period keeps
+   * expired_token answerable for one more TTL after expiry.
+   */
+  private evictExpired(): void {
+    const cutoff = Date.now() - DEVICE_RECORD_EVICTION_GRACE_MS;
+    for (const [deviceCode, record] of this.records) {
+      if (record.expiresAt.getTime() < cutoff) {
+        this.records.delete(deviceCode);
+      }
+    }
+  }
+}
+
+/** Grace period before an expired record is reclaimed (one default TTL). */
+const DEVICE_RECORD_EVICTION_GRACE_MS = 600 * 1000;
+
+// Kept on globalThis for the same reason as the provider stores above: Next.js
+// instantiates route handlers and server actions in separate module layers.
+const deviceStoreRegistry = globalThis as typeof globalThis & {
+  __oidcDeviceAuthorizationStore?: DeviceAuthorizationStore;
+};
+
+export const deviceAuthorizationStore: DeviceAuthorizationStore =
+  (deviceStoreRegistry.__oidcDeviceAuthorizationStore ??=
+    new InMemoryDeviceAuthorizationStore());
diff --git a/default-op/views.ts b/with-device-authorization-grant/views.ts
index b084077..6dc42f5 100644
--- a/default-op/views.ts
+++ b/with-device-authorization-grant/views.ts
@@ -52,6 +52,55 @@ export interface ErrorPageParams {
   statusCode: number;
 }
 
+export interface DeviceVerificationPageParams {
+  /**
+   * user_code to pre-fill the input with. Comes from the query string of
+   * verification_uri_complete (RFC 8628 §3.3.1) or from the user's own previous
+   * submission, so it is untrusted input and MUST be escaped before rendering.
+   */
+  userCode?: string;
+  /**
+   * Failure message for a code that did not match. RFC 8628 §5.1: the same text
+   * is used for unknown, expired and already-used codes, so do not add detail
+   * here — it would tell an attacker which codes exist.
+   */
+  error?: string;
+}
+
+export interface DeviceLoginPageParams {
+  /** user_code in display form; carried through as a hidden field. */
+  userCode: string;
+  /** CSRF token (must be included as hidden form field) */
+  csrfToken: string;
+  /** Error message from a previous failed attempt */
+  error?: string;
+  /** Number of remaining login attempts for this device authorization */
+  remainingAttempts?: number;
+}
+
+export interface DeviceApprovalPageParams {
+  /**
+   * user_code in display form. RFC 8628 §5.4: show it so the user can compare it
+   * with the code on the device screen — that comparison is the only defense
+   * against a remote phishing attempt that lured them to approve someone else's
+   * device.
+   */
+  userCode: string;
+  /** CSRF token (must be included as hidden form field) */
+  csrfToken: string;
+  /** Client the device authorization was requested by */
+  clientId: string;
+  /** Scopes the device asked for */
+  scopes: string[];
+}
+
+export interface DeviceCompletedPageParams {
+  /** true when the user approved, false when they denied */
+  approved: boolean;
+  /** Client the decision applied to */
+  clientId: string;
+}
+
 // ============================================================
 // Views Interface
 // ============================================================
@@ -70,6 +119,14 @@ export interface Views {
   consentPage(params: ConsentPageParams): ViewResult;
   /** Render a generic error page */
   errorPage(params: ErrorPageParams): ViewResult;
+  /** EXPERIMENTAL (RFC 8628 §3.3): render the user_code entry form */
+  deviceVerificationPage(params: DeviceVerificationPageParams): ViewResult;
+  /** EXPERIMENTAL (RFC 8628 §3.3): render the sign-in form for a device flow */
+  deviceLoginPage(params: DeviceLoginPageParams): ViewResult;
+  /** EXPERIMENTAL (RFC 8628 §3.3): render the approve / deny screen */
+  deviceApprovalPage(params: DeviceApprovalPageParams): ViewResult;
+  /** EXPERIMENTAL (RFC 8628 §3.3): render the "go back to your device" screen */
+  deviceCompletedPage(params: DeviceCompletedPageParams): ViewResult;
 }
 
 /** Options applied when renderView wraps an HTML string into a Response. */
@@ -200,6 +257,106 @@ ${descriptionHtml}</body>
 </html>`;
 }
 
+function defaultDeviceVerificationPage(params: DeviceVerificationPageParams): string {
+  const errorHtml = params.error
+    ? `<p style="color: red;">${escapeHtml(params.error)}</p>`
+    : '';
+
+  return `<!DOCTYPE html>
+<html>
+<head><title>Device Activation</title></head>
+<body>
+  <h1>Device Activation</h1>
+  <p>Enter the code shown on your device.</p>
+  ${errorHtml}
+  <form method="POST" action="/device">
+    <div>
+      <label for="user_code">Code:</label>
+      <input type="text" id="user_code" name="user_code" value="${escapeHtml(params.userCode ?? '')}" required />
+    </div>
+    <button type="submit">Continue</button>
+  </form>
+</body>
+</html>`;
+}
+
+function defaultDeviceLoginPage(params: DeviceLoginPageParams): string {
+  const errorHtml = params.error
+    ? `<p style="color: red;">${escapeHtml(params.error)}${
+        params.remainingAttempts !== undefined
+          ? `. Attempts remaining: ${params.remainingAttempts}`
+          : ''
+      }</p>`
+    : '';
+
+  return `<!DOCTYPE html>
+<html>
+<head><title>Login</title></head>
+<body>
+  <h1>Login</h1>
+  <p>Activating device code <strong>${escapeHtml(params.userCode)}</strong></p>
+  ${errorHtml}
+  <form method="POST" action="/device/login">
+    <input type="hidden" name="user_code" value="${escapeHtml(params.userCode)}" />
+    <input type="hidden" name="csrf_token" value="${escapeHtml(params.csrfToken)}" />
+    <div>
+      <label for="username">Username:</label>
+      <input type="text" id="username" name="username" required />
+    </div>
+    <div>
+      <label for="password">Password:</label>
+      <input type="password" id="password" name="password" required />
+    </div>
+    <button type="submit">Login</button>
+  </form>
+</body>
+</html>`;
+}
+
+function defaultDeviceApprovalPage(params: DeviceApprovalPageParams): string {
+  const scopeListHtml = params.scopes
+    .map((s) => `    <li>${escapeHtml(s)}</li>`)
+    .join('\n');
+
+  // RFC 8628 §5.4: the code is repeated here on purpose. Ask the user to check it
+  // against the device in front of them before approving.
+  return `<!DOCTYPE html>
+<html>
+<head><title>Authorize Device</title></head>
+<body>
+  <h1>Authorize Device</h1>
+  <p>Confirm that your device is showing this code: <strong>${escapeHtml(params.userCode)}</strong></p>
+  <p>Do not continue if the code does not match.</p>
+  <p>Client <strong>${escapeHtml(params.clientId)}</strong> is requesting access to the following scopes:</p>
+  <ul>
+${scopeListHtml}
+  </ul>
+  <form method="POST" action="/device/approve">
+    <input type="hidden" name="user_code" value="${escapeHtml(params.userCode)}" />
+    <input type="hidden" name="csrf_token" value="${escapeHtml(params.csrfToken)}" />
+    <button type="submit" name="decision" value="approve">Approve</button>
+    <button type="submit" name="decision" value="deny">Deny</button>
+  </form>
+</body>
+</html>`;
+}
+
+function defaultDeviceCompletedPage(params: DeviceCompletedPageParams): string {
+  const outcome = params.approved
+    ? `<p>You approved <strong>${escapeHtml(params.clientId)}</strong>.</p>`
+    : `<p>You denied <strong>${escapeHtml(params.clientId)}</strong>.</p>`;
+
+  return `<!DOCTYPE html>
+<html>
+<head><title>Device Activation</title></head>
+<body>
+  <h1>Device Activation</h1>
+${outcome}
+  <p>You can close this page and go back to your device.</p>
+</body>
+</html>`;
+}
+
 /**
  * Default Views used when no custom views are injected.
  * These render minimal, unstyled HTML so the flow works out of the box.
@@ -208,6 +365,10 @@ export const defaultViews: Views = {
   loginPage: defaultLoginPage,
   consentPage: defaultConsentPage,
   errorPage: defaultErrorPage,
+  deviceVerificationPage: defaultDeviceVerificationPage,
+  deviceLoginPage: defaultDeviceLoginPage,
+  deviceApprovalPage: defaultDeviceApprovalPage,
+  deviceCompletedPage: defaultDeviceCompletedPage,
 };
 
 /**

````
