# 生成コード差分: token-exchange — express / fastify

> 機械生成物です。手で編集しないでください。[パケットの説明に戻る](../README.md)

比較しているもの:

- `a/default-op/...`: `maronn-oidc generate <framework>`（experimental 機能なしのデフォルト構成）
- `b/with-token-exchange/...`: `maronn-oidc generate <framework> --enable token-exchange`

この差分が「`--enable token-exchange` が生成コードに足すものすべて」です。

express / fastify の生成コード差分は完全に同一のため、まとめて表示しています。

## サマリ

| 種別 | ファイル |
|---|---|
| 追加 | （なし） |
| 変更 | config.ts, conformance.test.ts, routes/discovery.ts, routes/token.ts |
| 削除 | （なし） |

## 差分

````diff
diff --git a/default-op/config.ts b/with-token-exchange/config.ts
index 17faa4d..1aaa160 100644
--- a/default-op/config.ts
+++ b/with-token-exchange/config.ts
@@ -157,7 +157,10 @@ export const defaultRegisteredClients: ReadonlyMap<string, RegisteredClient> = n
       // tokens at all: an online refresh token (bound to the login session) on every
       // authorization, and an offline one (usable after logout) when offline_access
       // is granted per OIDC Core 1.0 §11. Remove it and neither is issued.
-      grantTypes: ['authorization_code', 'refresh_token'],
+      // EXPERIMENTAL (RFC 8693): registering the token-exchange URN is what lets
+      // this confidential client exchange its access tokens. Remove it to forbid
+      // exchanges for this client; public clients are rejected either way.
+      grantTypes: ['authorization_code', 'refresh_token', 'urn:ietf:params:oauth:grant-type:token-exchange'],
       // RFC 7591 §2: token_endpoint_auth_method default is client_secret_basic.
       // The sample client authenticates with client_secret_post, so register it explicitly.
       tokenEndpointAuthMethod: 'client_secret_post',
diff --git a/default-op/conformance.test.ts b/with-token-exchange/conformance.test.ts
index 75a5580..733e04f 100644
--- a/default-op/conformance.test.ts
+++ b/with-token-exchange/conformance.test.ts
@@ -7,6 +7,7 @@ import { accessTokenStore, authSessionStore, consentStore, createJsonProviderSto
 import { consentResolver } from './resolvers.js';
 import { defaultViews } from './views.js';
 import { renderView } from './views.js';
+import { tokenExchangeConfig } from './routes/token.js';
 import { writeWebResponse } from './node-adapter.js';
 
 
@@ -122,6 +123,26 @@ const testClients = new Map<string, RegisteredClient>([
     grantTypes: ['authorization_code'],
     tokenEndpointAuthMethod: 'client_secret_post',
   }],
+  // EXPERIMENTAL (RFC 8693): a confidential client registered for the exchange
+  // grant, and a public one registered for it as well — the latter pins that a
+  // public client is rejected even when the URN is registered.
+  ['c-exchange', {
+    clientId: 'c-exchange',
+    clientSecret: 's',
+    redirectUris: [REDIRECT_URI],
+    clientType: 'confidential' as const,
+    responseTypes: ['code'],
+    grantTypes: ['authorization_code', 'urn:ietf:params:oauth:grant-type:token-exchange'],
+    tokenEndpointAuthMethod: 'client_secret_post',
+  }],
+  ['c-public-exchange', {
+    clientId: 'c-public-exchange',
+    redirectUris: [REDIRECT_URI],
+    clientType: 'public' as const,
+    responseTypes: ['code'],
+    grantTypes: ['authorization_code', 'urn:ietf:params:oauth:grant-type:token-exchange'],
+    tokenEndpointAuthMethod: 'none',
+  }],
 ]);
 
 // OIDC Core 1.0 §6.1: a signed RS256 Request Object for the conformance flow,
@@ -2459,6 +2480,690 @@ describe('generated provider HTTP conformance', () => {
   });
 
 
+  // EXPERIMENTAL — OAuth 2.0 Token Exchange (RFC 8693). Generated because this
+  // provider was created with --enable token-exchange. These tests pin the
+  // contract the repository guarantees for the generated exchange grant: change
+  // the behavior and they fail, which is how a customized OP learns it drifted.
+  describe('Token Exchange (RFC 8693)', () => {
+    // RFC 7636 Appendix B example PKCE pair (verifier -> its S256 challenge).
+    const PKCE_VERIFIER = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
+    const PKCE_CHALLENGE_S256 = 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM';
+    const EXCHANGE_GRANT_TYPE = 'urn:ietf:params:oauth:grant-type:token-exchange';
+    const ACCESS_TOKEN_TYPE = 'urn:ietf:params:oauth:token-type:access_token';
+    // The exchange rejects every kind of unusable subject_token / actor_token
+    // with one description each, so the response cannot be used as an existence
+    // oracle.
+    const SUBJECT_INVALID_DESCRIPTION = 'The provided subject_token is not valid';
+    const ACTOR_INVALID_DESCRIPTION = 'The provided actor_token is not valid';
+    const TARGET_REJECTED_DESCRIPTION =
+      'The requested target is not allowed for token exchange';
+
+    // Pure helpers: they fetch and parse only. Every assertion lives in an it().
+    function relativeFrom(location: string | null): string {
+      const url = new URL(location ?? '', 'http://localhost');
+      return url.pathname + url.search;
+    }
+
+    function csrfFrom(html: string): string {
+      return html.match(/name="csrf_token" value="([^"]+)"/)?.[1] ?? '';
+    }
+
+    function postToken(fields: Record<string, string>): Promise<Response> {
+      return app.request('/token', {
+        method: 'POST',
+        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
+        body: new URLSearchParams(fields).toString(),
+      });
+    }
+
+    function exchangeRequest(overrides: Record<string, string> = {}): Promise<Response> {
+      return postToken({
+        client_id: 'c-exchange',
+        client_secret: 's',
+        grant_type: EXCHANGE_GRANT_TYPE,
+        subject_token_type: ACCESS_TOKEN_TYPE,
+        ...overrides,
+      });
+    }
+
+    // Decode a JWT access token's payload (base64url, RFC 7515 §2) so the act
+    // claim of a delegated token can be pinned. The generated default issues
+    // JWT access tokens (config.accessTokenFormat: 'jwt').
+    function decodeJwtPayload(token: string): Record<string, unknown> {
+      const segment = token.split('.')[1] ?? '';
+      const base64 = segment.replace(/-/g, '+').replace(/_/g, '/');
+      const padded = base64 + '='.repeat((4 - (base64.length % 4)) % 4);
+      return JSON.parse(atob(padded)) as Record<string, unknown>;
+    }
+
+    // Drive authorize -> login -> consent over HTTP and hand back the code. No
+    // assertions and no branching here: the flow contract lives in the it()s.
+    async function authorizeFlow(
+      clientId: string,
+      scope: string,
+      claims?: string,
+      username = 'testuser',
+    ): Promise<string> {
+      const authorizeUrl =
+        '/authorize?response_type=code&client_id=' + clientId +
+        '&redirect_uri=' + encodeURIComponent(REDIRECT_URI) +
+        '&scope=' + encodeURIComponent(scope) +
+        '&state=tx-state&nonce=tx-nonce' +
+        (claims === undefined ? '' : '&claims=' + encodeURIComponent(claims)) +
+        '&code_challenge=' + PKCE_CHALLENGE_S256 + '&code_challenge_method=S256';
+
+      const authorizeRes = await app.request(authorizeUrl);
+      const loginPath = relativeFrom(authorizeRes.headers.get('Location'));
+      // Carry forward whatever cookie /authorize set, exactly as a browser would.
+      // With --enable transaction-binding this is the per-transaction binding
+      // secret the later steps require; without it this is '' and the OP ignores
+      // it, so the same flow works in both builds.
+      const bindingCookie = (authorizeRes.headers.get('Set-Cookie') ?? '').split(';')[0] ?? '';
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
+          username,
+          password: 'password',
+        }).toString(),
+      });
+      const consentPath = relativeFrom(loginRes.headers.get('Location'));
+
+      const consentGet = await app.request(consentPath, { headers: { Cookie: bindingCookie } });
+      const consentRes = await app.request('/consent', {
+        method: 'POST',
+        headers: { 'Content-Type': 'application/x-www-form-urlencoded', Cookie: bindingCookie },
+        body: new URLSearchParams({
+          transaction_id: transactionId,
+          csrf_token: csrfFrom(await consentGet.text()),
+          action: 'approve',
+        }).toString(),
+      });
+      const callback = new URL(consentRes.headers.get('Location') ?? '', 'http://localhost');
+      return callback.searchParams.get('code') ?? '';
+    }
+
+    // A subject_token obtained through the ordinary Authorization Code Flow.
+    async function subjectTokenFor(
+      scope: string,
+      clientId = 'c-exchange',
+      claims?: string,
+      username = 'testuser',
+    ): Promise<string> {
+      const code = await authorizeFlow(clientId, scope, claims, username);
+      const res = await postToken({
+        client_id: clientId,
+        ...(clientId === 'c-public-exchange' ? {} : { client_secret: 's' }),
+        grant_type: 'authorization_code',
+        code,
+        redirect_uri: REDIRECT_URI,
+        code_verifier: PKCE_VERIFIER,
+      });
+      return ((await res.json()) as Record<string, string>).access_token;
+    }
+
+    // An actor_token with a sub distinct from the subject: the second seeded
+    // user runs the same flow, so delegation tests can tell subject and actor
+    // apart in the act claim.
+    function actorTokenFor(scope: string): Promise<string> {
+      return subjectTokenFor(scope, 'c-exchange', undefined, 'otheruser');
+    }
+
+    describe('Successful exchange', () => {
+      it('should return every RFC 8693 §2.2.1 response member for a scope-narrowing exchange', async () => {
+        const subjectToken = await subjectTokenFor('openid profile email');
+        const res = await exchangeRequest({ subject_token: subjectToken, scope: 'openid profile' });
+        const body = await res.json();
+
+        expect(res.status).toBe(200);
+        expect(res.headers.get('Cache-Control')).toBe('no-store');
+        expect(res.headers.get('Pragma')).toBe('no-cache');
+        expect(Object.keys(body).sort()).toEqual([
+          'access_token',
+          'expires_in',
+          'issued_token_type',
+          'scope',
+          'token_type',
+        ]);
+        expect(body.issued_token_type).toBe(ACCESS_TOKEN_TYPE);
+        expect(body.token_type).toBe('Bearer');
+        expect(body.scope).toBe('openid profile');
+        expect(body.expires_in).toBe(3600);
+      });
+
+      it('should inherit the subject scope when scope is omitted', async () => {
+        const subjectToken = await subjectTokenFor('openid profile');
+        const res = await exchangeRequest({ subject_token: subjectToken });
+
+        expect(res.status).toBe(200);
+        expect((await res.json()).scope).toBe('openid profile');
+      });
+
+      // RFC 8693 §2.2.1: token exchange does not issue a refresh token here.
+      it('should not issue a refresh token from an exchange', async () => {
+        const subjectToken = await subjectTokenFor('openid');
+        const res = await exchangeRequest({ subject_token: subjectToken });
+
+        expect((await res.json()).refresh_token).toBe(undefined);
+      });
+
+      // The exchanged token is an ordinary access token in the store, so every
+      // existing endpoint keeps working with it.
+      it('should return a token that the UserInfo endpoint accepts', async () => {
+        const subjectToken = await subjectTokenFor('openid profile');
+        const exchanged = (await (await exchangeRequest({ subject_token: subjectToken })).json())
+          .access_token as string;
+        const res = await app.request('/userinfo', {
+          headers: { Authorization: 'Bearer ' + exchanged },
+        });
+
+        expect(res.status).toBe(200);
+        expect((await res.json()).sub).toBe('testuser');
+      });
+
+      // RFC 8693 §1.1 impersonation: sub is inherited, client_id is the caller.
+      it('should bind the exchanged token to the requesting client and the original subject', async () => {
+        const subjectToken = await subjectTokenFor('openid');
+        const exchanged = (await (await exchangeRequest({ subject_token: subjectToken })).json())
+          .access_token as string;
+        const res = await app.request('/introspect', {
+          method: 'POST',
+          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
+          body: new URLSearchParams({
+            client_id: 'c-exchange',
+            client_secret: 's',
+            token: exchanged,
+          }).toString(),
+        });
+        const body = await res.json();
+
+        expect(body.active).toBe(true);
+        expect(body.sub).toBe('testuser');
+        expect(body.client_id).toBe('c-exchange');
+        expect(body.aud).toEqual(['http://localhost:3000/userinfo']);
+      });
+
+      // The subject token stays usable: RFC 8693 does not make it single use.
+      it('should leave the subject token valid after an exchange', async () => {
+        const subjectToken = await subjectTokenFor('openid');
+        await exchangeRequest({ subject_token: subjectToken });
+        const res = await app.request('/userinfo', {
+          headers: { Authorization: 'Bearer ' + subjectToken },
+        });
+
+        expect(res.status).toBe(200);
+      });
+
+      // The exchanged token never outlives the subject token, so a chain of
+      // exchanges cannot launder a token into a longer lifetime.
+      it('should not extend the lifetime beyond the subject token', async () => {
+        const subjectToken = await subjectTokenFor('openid');
+        const first = (await (await exchangeRequest({ subject_token: subjectToken })).json()) as
+          Record<string, number | string>;
+        const second = (await (
+          await exchangeRequest({ subject_token: first.access_token as string })
+        ).json()) as Record<string, number | string>;
+
+        expect((second.expires_in as number) <= (first.expires_in as number)).toBe(true);
+      });
+
+      // OIDC Core 1.0 §5.5: the consented claims request is NOT carried over, so
+      // an exchanged token yields scope-based claims only.
+      it('should not inherit the claims parameter of the subject token', async () => {
+        const claims = JSON.stringify({ userinfo: { name: { essential: true } } });
+        const subjectToken = await subjectTokenFor('openid', 'c-exchange', claims);
+        const subjectUserInfo = await (
+          await app.request('/userinfo', { headers: { Authorization: 'Bearer ' + subjectToken } })
+        ).json();
+        const exchanged = (await (await exchangeRequest({ subject_token: subjectToken })).json())
+          .access_token as string;
+        const exchangedUserInfo = await (
+          await app.request('/userinfo', { headers: { Authorization: 'Bearer ' + exchanged } })
+        ).json();
+
+        expect(subjectUserInfo.name).toBe('Test User');
+        expect(exchangedUserInfo.name).toBe(undefined);
+      });
+
+      // RFC 9068 §2.2 / RFC 7519 §4.1.7: each exchanged token gets its own jti.
+      // Two exchanges of the same subject_token land in the same wall-clock second
+      // with identical claims; without jti the deterministic RS256 signature
+      // (RFC 8017 §8.2) would make them one string and one store record, so
+      // revoking one would revoke the other.
+      it('should issue a distinct token for each exchange of the same subject token', async () => {
+        const subjectToken = await subjectTokenFor('openid');
+        const first = (await (await exchangeRequest({ subject_token: subjectToken })).json())
+          .access_token as string;
+        const second = (await (await exchangeRequest({ subject_token: subjectToken })).json())
+          .access_token as string;
+
+        const firstUserInfo = await app.request('/userinfo', { headers: { Authorization: 'Bearer ' + first } });
+        const secondUserInfo = await app.request('/userinfo', { headers: { Authorization: 'Bearer ' + second } });
+
+        expect(first === second).toBe(false);
+        expect(firstUserInfo.status).toBe(200);
+        expect(secondUserInfo.status).toBe(200);
+      });
+    });
+
+    describe('Client authorization', () => {
+      it('should reject an unauthenticated exchange with 401 invalid_client', async () => {
+        const subjectToken = await subjectTokenFor('openid');
+        const res = await postToken({
+          client_id: 'c-exchange',
+          grant_type: EXCHANGE_GRANT_TYPE,
+          subject_token: subjectToken,
+          subject_token_type: ACCESS_TOKEN_TYPE,
+        });
+
+        expect(res.status).toBe(401);
+        expect((await res.json()).error).toBe('invalid_client');
+      });
+
+      // RFC 6749 §5.2: the exchange URN must be registered on the client.
+      it('should reject a client that has not registered the exchange grant', async () => {
+        const subjectToken = await subjectTokenFor('openid');
+        const res = await postToken({
+          client_id: 'c-conf',
+          client_secret: 's',
+          grant_type: EXCHANGE_GRANT_TYPE,
+          subject_token: subjectToken,
+          subject_token_type: ACCESS_TOKEN_TYPE,
+        });
+
+        expect(res.status).toBe(400);
+        expect(await res.json()).toEqual({
+          error: 'unauthorized_client',
+          error_description: 'The client is not authorized to use the token-exchange grant type',
+        });
+      });
+
+      // RFC 8693 §2.1 notes that skipping client authentication lets a stolen
+      // token be amplified through the STS, so public clients are refused.
+      it('should reject a public client even when it registered the exchange grant', async () => {
+        const subjectToken = await subjectTokenFor('openid', 'c-public-exchange');
+        const res = await postToken({
+          client_id: 'c-public-exchange',
+          grant_type: EXCHANGE_GRANT_TYPE,
+          subject_token: subjectToken,
+          subject_token_type: ACCESS_TOKEN_TYPE,
+        });
+
+        expect(res.status).toBe(400);
+        expect(await res.json()).toEqual({
+          error: 'unauthorized_client',
+          error_description: 'Public clients are not allowed to use the token-exchange grant type',
+        });
+      });
+    });
+
+    describe('Parameter validation', () => {
+      it('should reject a missing subject_token with invalid_request', async () => {
+        const res = await exchangeRequest({});
+
+        expect(res.status).toBe(400);
+        expect(await res.json()).toEqual({
+          error: 'invalid_request',
+          error_description: 'subject_token is required',
+        });
+      });
+
+      it('should reject an unsupported subject_token_type with invalid_request', async () => {
+        const subjectToken = await subjectTokenFor('openid');
+        const res = await exchangeRequest({
+          subject_token: subjectToken,
+          subject_token_type: 'urn:ietf:params:oauth:token-type:id_token',
+        });
+
+        expect(res.status).toBe(400);
+        expect(await res.json()).toEqual({
+          error: 'invalid_request',
+          error_description:
+            'Unsupported subject_token_type. Only urn:ietf:params:oauth:token-type:access_token is supported.',
+        });
+      });
+
+      it('should reject an unsupported requested_token_type with invalid_request', async () => {
+        const subjectToken = await subjectTokenFor('openid');
+        const res = await exchangeRequest({
+          subject_token: subjectToken,
+          requested_token_type: 'urn:ietf:params:oauth:token-type:refresh_token',
+        });
+
+        expect(res.status).toBe(400);
+        expect(await res.json()).toEqual({
+          error: 'invalid_request',
+          error_description:
+            'Unsupported requested_token_type. Only urn:ietf:params:oauth:token-type:access_token is supported.',
+        });
+      });
+
+      // RFC 8693 §2.1: actor_token_type is REQUIRED when actor_token is present.
+      it('should reject actor_token without actor_token_type', async () => {
+        const subjectToken = await subjectTokenFor('openid');
+        const res = await exchangeRequest({
+          subject_token: subjectToken,
+          actor_token: subjectToken,
+        });
+
+        expect(res.status).toBe(400);
+        expect(await res.json()).toEqual({
+          error: 'invalid_request',
+          error_description: 'actor_token_type is required when actor_token is present',
+        });
+      });
+
+      // RFC 8693 §2.1: actor_token_type MUST NOT be included without actor_token.
+      it('should reject actor_token_type without actor_token', async () => {
+        const subjectToken = await subjectTokenFor('openid');
+        const res = await exchangeRequest({
+          subject_token: subjectToken,
+          actor_token_type: ACCESS_TOKEN_TYPE,
+        });
+
+        expect(res.status).toBe(400);
+        expect(await res.json()).toEqual({
+          error: 'invalid_request',
+          error_description: 'actor_token_type must not be present without actor_token',
+        });
+      });
+
+      it('should reject an unsupported actor_token_type with invalid_request', async () => {
+        const subjectToken = await subjectTokenFor('openid');
+        const res = await exchangeRequest({
+          subject_token: subjectToken,
+          actor_token: subjectToken,
+          actor_token_type: 'urn:ietf:params:oauth:token-type:id_token',
+        });
+
+        expect(res.status).toBe(400);
+        expect(await res.json()).toEqual({
+          error: 'invalid_request',
+          error_description:
+            'Unsupported actor_token_type. Only urn:ietf:params:oauth:token-type:access_token is supported.',
+        });
+      });
+
+      // The actor_token failure description is fixed for the same oracle-
+      // elimination reason as the subject_token one.
+      it('should reject an unknown actor_token with the fixed description', async () => {
+        const subjectToken = await subjectTokenFor('openid');
+        const res = await exchangeRequest({
+          subject_token: subjectToken,
+          actor_token: 'not-a-real-token',
+          actor_token_type: ACCESS_TOKEN_TYPE,
+        });
+
+        expect(res.status).toBe(400);
+        expect(await res.json()).toEqual({
+          error: 'invalid_request',
+          error_description: ACTOR_INVALID_DESCRIPTION,
+        });
+      });
+
+      // RFC 8693 §2.1: resource MUST be an absolute URI without a fragment.
+      it('should reject a relative resource with invalid_request', async () => {
+        const subjectToken = await subjectTokenFor('openid');
+        const res = await exchangeRequest({ subject_token: subjectToken, resource: '/api' });
+
+        expect(res.status).toBe(400);
+        expect(await res.json()).toEqual({
+          error: 'invalid_request',
+          error_description: 'resource must be an absolute URI without a fragment component',
+        });
+      });
+
+      it('should reject a resource carrying a fragment with invalid_request', async () => {
+        const subjectToken = await subjectTokenFor('openid');
+        const res = await exchangeRequest({
+          subject_token: subjectToken,
+          resource: 'https://api.example.com/x#frag',
+        });
+
+        expect(res.status).toBe(400);
+        expect(await res.json()).toEqual({
+          error: 'invalid_request',
+          error_description: 'resource must be an absolute URI without a fragment component',
+        });
+      });
+
+      // RFC 6749 §3.2: repeated token endpoint parameters are refused, which is
+      // why this OP supports only a single audience / resource value.
+      it('should reject a repeated resource parameter', async () => {
+        const subjectToken = await subjectTokenFor('openid');
+        const res = await app.request('/token', {
+          method: 'POST',
+          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
+          body:
+            'client_id=c-exchange&client_secret=s&grant_type=' +
+            encodeURIComponent(EXCHANGE_GRANT_TYPE) +
+            '&subject_token=' + encodeURIComponent(subjectToken) +
+            '&subject_token_type=' + encodeURIComponent(ACCESS_TOKEN_TYPE) +
+            '&resource=https%3A%2F%2Fa.example.com&resource=https%3A%2F%2Fb.example.com',
+        });
+
+        expect(res.status).toBe(400);
+        expect(await res.json()).toEqual({
+          error: 'invalid_request',
+          error_description: 'Parameter "resource" must not be repeated',
+        });
+      });
+
+      // RFC 8693 §2.2.2 sends invalid subject tokens to invalid_request, NOT to
+      // invalid_grant as the authorization_code / refresh_token grants would.
+      it('should reject an unknown subject_token with invalid_request', async () => {
+        const res = await exchangeRequest({ subject_token: 'not-a-real-token' });
+
+        expect(res.status).toBe(400);
+        expect(await res.json()).toEqual({
+          error: 'invalid_request',
+          error_description: SUBJECT_INVALID_DESCRIPTION,
+        });
+      });
+
+      it('should report a revoked subject_token exactly like an unknown one', async () => {
+        const subjectToken = await subjectTokenFor('openid');
+        await app.request('/revoke', {
+          method: 'POST',
+          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
+          body: new URLSearchParams({
+            client_id: 'c-exchange',
+            client_secret: 's',
+            token: subjectToken,
+          }).toString(),
+        });
+        const revoked = await exchangeRequest({ subject_token: subjectToken });
+        const unknown = await exchangeRequest({ subject_token: 'not-a-real-token' });
+
+        expect(revoked.status).toBe(400);
+        expect(await revoked.json()).toEqual(await unknown.json());
+      });
+    });
+
+    describe('Scope narrowing', () => {
+      it('should reject a scope that exceeds the subject token scope', async () => {
+        const subjectToken = await subjectTokenFor('openid');
+        const res = await exchangeRequest({ subject_token: subjectToken, scope: 'openid profile' });
+
+        expect(res.status).toBe(400);
+        expect(await res.json()).toEqual({
+          error: 'invalid_scope',
+          error_description: 'The requested scope exceeds the scope of the subject_token',
+        });
+      });
+
+      it('should grant exactly the requested subset', async () => {
+        const subjectToken = await subjectTokenFor('openid profile email');
+        const res = await exchangeRequest({ subject_token: subjectToken, scope: 'email' });
+
+        expect(res.status).toBe(200);
+        expect((await res.json()).scope).toBe('email');
+      });
+    });
+
+    describe('Delegation (RFC 8693 §4.1)', () => {
+      // sub stays the subject; the actor appears only in the act claim.
+      it('should record the actor in the act claim of the issued token', async () => {
+        const subjectToken = await subjectTokenFor('openid profile');
+        const actorToken = await actorTokenFor('openid');
+        const res = await exchangeRequest({
+          subject_token: subjectToken,
+          actor_token: actorToken,
+          actor_token_type: ACCESS_TOKEN_TYPE,
+        });
+        const body = await res.json();
+        const payload = decodeJwtPayload(body.access_token as string);
+
+        expect(res.status).toBe(200);
+        expect(payload.sub).toBe('testuser');
+        expect(payload.act).toEqual({ sub: 'otheruser' });
+      });
+
+      it('should not add an act claim to an impersonation exchange', async () => {
+        const subjectToken = await subjectTokenFor('openid');
+        const body = await (await exchangeRequest({ subject_token: subjectToken })).json();
+        const payload = decodeJwtPayload(body.access_token as string);
+
+        expect(payload.act).toBe(undefined);
+      });
+
+      // RFC 8693 §4.1: exchanging a delegated token again pushes the prior
+      // actor one level down; the outermost act names the current actor.
+      it('should nest the prior actor when a delegated token is exchanged again', async () => {
+        const subjectToken = await subjectTokenFor('openid');
+        const firstActor = await actorTokenFor('openid');
+        const delegated = (await (
+          await exchangeRequest({
+            subject_token: subjectToken,
+            actor_token: firstActor,
+            actor_token_type: ACCESS_TOKEN_TYPE,
+          })
+        ).json()).access_token as string;
+        const secondActor = await actorTokenFor('openid');
+        const res = await exchangeRequest({
+          subject_token: delegated,
+          actor_token: secondActor,
+          actor_token_type: ACCESS_TOKEN_TYPE,
+        });
+        const payload = decodeJwtPayload((await res.json()).access_token as string);
+
+        expect(res.status).toBe(200);
+        expect(payload.act).toEqual({ sub: 'otheruser', act: { sub: 'otheruser' } });
+      });
+
+      // A delegated token is an ordinary access token of the subject: the
+      // UserInfo endpoint answers for the subject, not the actor.
+      it('should answer UserInfo for the subject of a delegated token', async () => {
+        const subjectToken = await subjectTokenFor('openid profile');
+        const actorToken = await actorTokenFor('openid');
+        const delegated = (await (
+          await exchangeRequest({
+            subject_token: subjectToken,
+            actor_token: actorToken,
+            actor_token_type: ACCESS_TOKEN_TYPE,
+          })
+        ).json()).access_token as string;
+        const res = await app.request('/userinfo', {
+          headers: { Authorization: 'Bearer ' + delegated },
+        });
+
+        expect(res.status).toBe(200);
+        expect((await res.json()).sub).toBe('testuser');
+      });
+    });
+
+    describe('Target policy (allowedTargets)', () => {
+      // The generated default is an empty list, so any named target is refused
+      // until the operator opts in. The list is restored after each test.
+      it('should reject an audience that is not in allowedTargets', async () => {
+        const subjectToken = await subjectTokenFor('openid');
+        const res = await exchangeRequest({
+          subject_token: subjectToken,
+          audience: 'https://internal.example.com',
+        });
+
+        expect(res.status).toBe(400);
+        expect(await res.json()).toEqual({
+          error: 'invalid_target',
+          error_description: TARGET_REJECTED_DESCRIPTION,
+        });
+      });
+
+      it('should reject a resource that is not in allowedTargets', async () => {
+        const subjectToken = await subjectTokenFor('openid');
+        const res = await exchangeRequest({
+          subject_token: subjectToken,
+          resource: 'https://internal.example.com/api',
+        });
+
+        expect(res.status).toBe(400);
+        expect(await res.json()).toEqual({
+          error: 'invalid_target',
+          error_description: TARGET_REJECTED_DESCRIPTION,
+        });
+      });
+
+      it('should issue a token for an allowed audience', async () => {
+        const subjectToken = await subjectTokenFor('openid');
+        tokenExchangeConfig.allowedTargets = ['https://internal.example.com'];
+        const res = await exchangeRequest({
+          subject_token: subjectToken,
+          audience: 'https://internal.example.com',
+        });
+        const body = await res.json();
+        tokenExchangeConfig.allowedTargets = [];
+
+        expect(res.status).toBe(200);
+        expect(body.token_type).toBe('Bearer');
+      });
+
+      // The UserInfo endpoint stays a permanent aud member (RFC 9068 §3), so an
+      // exchanged token keeps working against this OP as well as the new target.
+      it('should add the allowed audience alongside the UserInfo endpoint', async () => {
+        const subjectToken = await subjectTokenFor('openid');
+        tokenExchangeConfig.allowedTargets = ['https://internal.example.com'];
+        const exchanged = (await (
+          await exchangeRequest({
+            subject_token: subjectToken,
+            audience: 'https://internal.example.com',
+          })
+        ).json()).access_token as string;
+        tokenExchangeConfig.allowedTargets = [];
+        const introspection = await (
+          await app.request('/introspect', {
+            method: 'POST',
+            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
+            body: new URLSearchParams({
+              client_id: 'c-exchange',
+              client_secret: 's',
+              token: exchanged,
+            }).toString(),
+          })
+        ).json();
+
+        expect(introspection.aud).toEqual([
+          'http://localhost:3000/userinfo',
+          'https://internal.example.com',
+        ]);
+      });
+    });
+
+    describe('Discovery', () => {
+      it('should advertise the exchange grant in grant_types_supported', async () => {
+        const metadata = await (await app.request('/.well-known/openid-configuration')).json();
+
+        expect(metadata.grant_types_supported.includes(EXCHANGE_GRANT_TYPE)).toBe(true);
+      });
+    });
+  });
+
+
   // The device authorization grant is disabled in this generated provider: no
   // endpoint, no metadata, and the URN stays an unsupported grant. These pin the
   // default-off contract so enabling the feature by accident is visible.
diff --git a/default-op/routes/discovery.ts b/with-token-exchange/routes/discovery.ts
index 3208501..1dbed28 100644
--- a/default-op/routes/discovery.ts
+++ b/with-token-exchange/routes/discovery.ts
@@ -92,7 +92,7 @@ discoveryApp.get('/', (c) => {
       'phone_number',
       'phone_number_verified',
     ],
-    grantTypesSupported: ['authorization_code', 'refresh_token'],
+    grantTypesSupported: ['authorization_code', 'refresh_token', 'urn:ietf:params:oauth:grant-type:token-exchange'],
     // RFC 6749 §2.1 / OAuth 2.1 §2.4: 'none' advertises that public clients
     // (no client_secret) are accepted at the token endpoint.
     tokenEndpointAuthMethodsSupported: [
diff --git a/default-op/routes/token.ts b/with-token-exchange/routes/token.ts
index a0d0f5c..4a530d3 100644
--- a/default-op/routes/token.ts
+++ b/with-token-exchange/routes/token.ts
@@ -46,6 +46,7 @@ import {
   authorizationCodeResolver as defaultAuthorizationCodeResolver,
   refreshTokenResolver as defaultRefreshTokenResolver,
   authenticationSessionResolver as defaultAuthenticationSessionResolver,
+  accessTokenResolver as defaultAccessTokenResolver,
 } from '../resolvers.js';
 import {
   accessTokenStore as defaultAccessTokenStore,
@@ -53,6 +54,26 @@ import {
   refreshTokenStore as defaultRefreshTokenStore,
 } from '../store.js';
 import type { RegisteredClient } from '../config.js';
+import {
+  TOKEN_EXCHANGE_GRANT_TYPE,
+  TokenExchangeError,
+  buildTokenExchangeResponse,
+  processTokenExchangeRequest,
+  type ExchangedAccessTokenInfo,
+} from '@maronn-openid-connect/experimental/token-exchange';
+
+/**
+ * EXPERIMENTAL — OAuth 2.0 Token Exchange settings (RFC 8693).
+ *
+ * - allowedTargets: the audience / resource values a client may ask an
+ *   exchanged token to be issued for. Empty by default (fail safe): with an
+ *   empty list every exchange that names a target is rejected with
+ *   invalid_target, and only scope-narrowing / lifetime-shortening exchanges
+ *   succeed. Add the identifiers of your downstream services here.
+ */
+export const tokenExchangeConfig = {
+  allowedTargets: [] as string[],
+};
 
 export const tokenApp = new WebRouter();
 
@@ -171,6 +192,111 @@ tokenApp.post('/', async (c) => {
 
     const authenticatedClientId = presentedCredentials.clientId;
 
+    // --- EXPERIMENTAL: OAuth 2.0 Token Exchange (RFC 8693 §2.1) ------------
+    // Dispatched right after client authentication and BEFORE core's
+    // validateGrantTypeSupported, which does not know the URN and would reject
+    // it with unsupported_grant_type. The branch answers the request itself and
+    // never falls through to the standard grants.
+    //
+    // Backed by @maronn-openid-connect/experimental, whose API is NOT stable: it may change
+    // in a breaking way between releases. Do not build production code on it
+    // without pinning the version.
+    //
+    // Known limitation: RFC 8693 §2.1 permits repeated `resource` / `audience`
+    // parameters, but this endpoint rejects any repeated parameter (RFC 6749
+    // §3.2), so only a single value of each is supported.
+    if (params.grant_type === TOKEN_EXCHANGE_GRANT_TYPE) {
+      const accessTokenResolver = c.get('accessTokenResolver') ?? defaultAccessTokenResolver;
+      // config / privateKey / keyId are bound further down for the standard
+      // grants. This branch reads them on its own so the generated output is
+      // unchanged when the feature is off; it returns, so nothing runs twice.
+      const exchangeConfig = c.get('config');
+      const exchangeIssuer: AccessTokenIssuer =
+        exchangeConfig.accessTokenFormat === 'opaque'
+          ? createOpaqueAccessTokenIssuer()
+          : createJwtAccessTokenIssuer();
+
+      // Validate the request and derive the issuing material. Each check inside
+      // is also exported as its own step function, so you can call them one by
+      // one instead and drop or replace individual rules.
+      const grant = await processTokenExchangeRequest({
+        params,
+        client: tokenClient,
+        accessTokenResolver,
+        allowedTargets: tokenExchangeConfig.allowedTargets,
+        configuredExpiresIn: exchangeConfig.accessTokenExpiresIn,
+      });
+
+      // Same aud policy as the standard token route: the UserInfo endpoint stays
+      // a permanent member (RFC 9068 §3), so an exchanged token still passes the
+      // UserInfo endpoint's audience check.
+      const exchangeAudience = buildAccessTokenAudience({
+        userInfoEndpoint: `${exchangeConfig.issuer}/userinfo`,
+        requested: grant.requestedAudience,
+        issuer: exchangeConfig.issuer,
+      });
+
+      const exchangeIssuedAt = Math.floor(Date.now() / 1000);
+      const exchangePayload = buildAccessTokenPayload({
+        issuer: exchangeConfig.issuer,
+        subject: grant.subject,
+        clientId: grant.clientId,
+        scope: grant.scope,
+        audience: exchangeAudience,
+        expiresIn: grant.expiresIn,
+        issuedAt: exchangeIssuedAt,
+      });
+      const exchangedToken = await exchangeIssuer.issue({
+        payload: {
+          ...exchangePayload,
+          // RFC 8693 §4.1: a delegation exchange records the current actor in
+          // the act claim (chains already nested by processTokenExchangeRequest).
+          // Impersonation exchanges carry no act claim.
+          ...(grant.actor === undefined ? {} : { act: grant.actor }),
+        },
+        privateKey: c.get('privateKey'),
+        keyId: c.get('keyId'),
+      });
+
+      const exchangeMetadata: ExchangedAccessTokenInfo = {
+        // RFC 8693 §1.1: the exchanged token acts as the same subject, but is
+        // bound to the client that requested the exchange.
+        sub: grant.subject,
+        clientId: grant.clientId,
+        scope: grant.scope,
+        expiresAt: exchangeIssuedAt + grant.expiresIn,
+        // Inherit the subject token's grant so revoking the grant (e.g. on code
+        // reuse detection) also kills every token exchanged from it.
+        grantId: grant.grantId,
+        iat: exchangeIssuedAt,
+        nbf: exchangeIssuedAt,
+        audience: exchangeAudience,
+        issuer: exchangeConfig.issuer,
+        // RFC 9068 §2.2 / RFC 7662 §2.2: the exchanged token gets its own jti,
+        // so it is a distinct store record even when it is exchanged twice from
+        // the same subject_token within one second.
+        jti: exchangePayload.jti,
+        // Persisting act lets a later exchange that presents THIS token as its
+        // subject_token pick up the chain (RFC 8693 §4.1 nesting).
+        ...(grant.actor === undefined ? {} : { act: grant.actor }),
+        // The subject token's stored claims parameter (OIDC Core 1.0 §5.5) is
+        // deliberately NOT inherited: an exchanged token yields scope-based
+        // claims only at the UserInfo endpoint.
+      };
+      await accessTokenStore.set(exchangedToken, exchangeMetadata);
+
+      // RFC 6749 §5.1: token responses MUST NOT be cached.
+      c.header('Cache-Control', 'no-store');
+      c.header('Pragma', 'no-cache');
+      // RFC 8693 §2.2.1: access_token / issued_token_type / token_type are
+      // REQUIRED; expires_in and scope are always included here.
+      return c.json(buildTokenExchangeResponse({
+        accessToken: exchangedToken,
+        expiresIn: grant.expiresIn,
+        scope: grant.scope,
+      }));
+    }
+
     // --- Token request validation pipeline --------------------------------
     // Each step below is an independent core function, called in the same order
     // as core's validateTokenRequest(). Delete a call to drop that validation,
@@ -591,6 +717,17 @@ tokenApp.post('/', async (c) => {
     c.header('Pragma', 'no-cache');
     return c.json(tokenResponse);
   } catch (error) {
+    if (error instanceof TokenExchangeError) {
+      // RFC 8693 §2.2.2: the exchange errors use the RFC 6749 §5.2 shape. They
+      // are always 400 — a 401 can only come from client authentication, which
+      // runs before the branch and throws core's TokenError.
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

````
