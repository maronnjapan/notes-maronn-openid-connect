# Implementation Guide: Client Identification on the Consent Screen

This guide covers the client registration metadata added to `@maronn-openid-connect/core` and the consent screens the CLI generates for all four frameworks (hono / express / fastify / Next.js).
The work was implemented from the OSS repository task `tasks/done/p2-consent-screen-client-identification.md`.

## What the feature does

The generated OP's consent screen can now render the display metadata a client registered.
The fields are the five that OIDC Dynamic Client Registration 1.0 §2 / RFC 7591 §2 define: `client_name`, `client_uri`, `logo_uri`, `policy_uri` and `tos_uri`.

Before this change, the consent screen showed nothing but the raw `client_id` and the raw scope names:

```html
<p>Client <strong>example-client</strong> is requesting access to the following scopes:</p>
<ul><li>openid</li><li>profile</li><li>email</li></ul>
```

OIDC Core 1.0 §3.1.2.4 requires the Authorization Server to obtain an authorization decision before releasing information to the Relying Party, which presumes a screen the End-User can actually decide on.
RFC 6749 §10.2 frames the defense against client impersonation as client authentication plus the resource owner's active involvement — and the latter works only while the End-User can identify the client.
A screen showing only an internal identifier left the End-User guessing who they were about to authorize.

After the change, a client that registered a `client_name` gets this screen:

```html
<p>Client <strong>Example Client</strong> (<code>example-client</code>) is requesting access to the following scopes:</p>
<ul><li>openid</li><li>profile</li><li>email</li></ul>
<ul>
  <li><a href="..." target="_blank" rel="noopener noreferrer">Privacy Policy</a></li>
  <li><a href="..." target="_blank" rel="noopener noreferrer">Terms of Service</a></li>
</ul>
```

A client that registered nothing keeps the plain `client_id` display, so nothing breaks backward.

## Use cases

When a PoC hangs several clients off one OP, the identifier alone makes it hard to explain to demo participants which app is being authorized; a registered `client_name` turns the screen itself into the explanation.

For developers heading to production, privacy-policy and terms links are a standard element of a consent screen.
Carrying `policy_uri` / `tos_uri` as registration metadata lets the default screen provide that without a custom view.

When Dynamic Client Registration (RFC 7591 / OIDC Registration 1.0) is implemented later, the registration request JSON will carry these fields in the same vocabulary.
The `ClientInfo` field names map one-to-one onto the spec's snake_case names, so a registration endpoint can feed its parsed payload straight in.

## Design decisions

### Display URIs are allow-listed

core already has a dangerous-scheme check for redirect URIs (the `DANGEROUS_SCHEMES` deny list), but the display URIs got a new `isSafeDisplayUri()` that allows only `http:` / `https:` instead of reusing it.
The two validations protect different things.
redirect_uri legitimately uses RFC 8252 §7.1 custom schemes (`com.example.app:/callback`), so it can only deny the schemes known to be dangerous.
A consent-screen link, however, is a document URL the End-User clicks, and there is no reason to allow custom schemes there.
Allowing exactly the two schemes that mean a web document is safer than maintaining a list of executable schemes (`javascript:`, `data:`, …) that could miss one — and shorter to implement.

### The scheme check lives in the logic layer, not the view

The check runs in the generated `routes/consent.ts` (for Next.js, a helper inside `consent/page.tsx`), and a URI that fails it reaches the view as undefined.
The check was kept out of the views because views are replaceable: users inject their own through `createViews()`, and demanding that every custom view re-validate schemes before rendering a link is not realistic.
Filtering in the logic layer means every view — default or custom — only ever receives URIs that are safe to render.

### logo_uri is passed through but never rendered by the default view

`logo_uri` travels as far as `ConsentPageParams`, but the default view emits no `<img>`.
Embedding an image from a client-chosen URL in the OP's own screen opens three problems by default.
First, a client spoofing a well-known service's logo lends the consent screen false trust (a phishing surface).
Second, it presumes a CSP whose `img-src` spans arbitrary hosts.
Third, every consent view sends the End-User's IP address to a third-party server.
Whether to accept those is an operator's decision, so rendering a logo is left to a custom view, with the reasoning preserved as comments in the generated code.

### client_name never replaces the client_id

When `client_name` is shown, the `client_id` stays visible in a `<code>` element beside it.
The name is self-asserted — nothing stops another client from registering the name `Example Client` — so a name-only display would be cover for impersonation.
With the identifier always visible, the End-User (and an operator's screenshot audit) can notice a spoofed name.

### An unresolved client degrades the display instead of failing

The display-metadata resolution in `prepareConsent` maps both a resolver failure and a missing client to "no metadata".
By the time the browser reaches this screen, `/authorize` has already validated the client, so a lookup failure here warrants a degraded display, not a 500 that kills the consent flow.

### Semver: minor for both core and cli

core gains interface fields and a newly exported function — an API addition.
cli gains a feature in its generated consent screen.
The repository's release contract requires `experimental` and `google-login` to ship alongside a core minor, so both received patch changesets and their core peer range lower bound was raised to `>=0.7.0`.

## Changes in core

### packages/core/src/authorization-request.ts: new ClientInfo fields

Five OPTIONAL display fields were appended to `ClientInfo`.
The added part in full (JSDoc in Japanese, as the file's convention):

```typescript
  /**
   * クライアント登録メタデータ `client_name`
   * （OIDC Dynamic Client Registration 1.0 §2 / RFC 7591 §2）。
   * 同意画面でエンドユーザーに提示するクライアントの名称。
   * 名称は登録者の自己申告であり詐称し得るため、表示する側は `clientId` を併記して
   * 名称単独で識別させない（RFC 6749 §10.2 のクライアントなりすまし防御は、
   * エンドユーザーがクライアントを識別できて初めて機能する）。
   */
  clientName?: string;
  /**
   * クライアント登録メタデータ `client_uri`
   * （OIDC Dynamic Client Registration 1.0 §2 / RFC 7591 §2）。
   * クライアントのホームページ URL。リンクとして描画する前に
   * {@link isSafeDisplayUri} でスキームを検査する。
   */
  clientUri?: string;
  /**
   * クライアント登録メタデータ `logo_uri`
   * （OIDC Dynamic Client Registration 1.0 §2 / RFC 7591 §2）。
   * エンドユーザーに提示するロゴ画像の URL。生成コードの既定ビューは描画しない
   * （ロゴ詐称によるフィッシング面が既定で開くため。自前ビューで明示的に選択する）。
   */
  logoUri?: string;
  /**
   * クライアント登録メタデータ `policy_uri`
   * （OIDC Dynamic Client Registration 1.0 §2 / RFC 7591 §2）。
   * クライアントがプロファイルデータをどう扱うかをエンドユーザーが読むための URL。
   * リンクとして描画する前に {@link isSafeDisplayUri} でスキームを検査する。
   */
  policyUri?: string;
  /**
   * クライアント登録メタデータ `tos_uri`
   * （OIDC Dynamic Client Registration 1.0 §2 / RFC 7591 §2）。
   * 利用規約の URL。リンクとして描画する前に {@link isSafeDisplayUri} で
   * スキームを検査する。
   */
  tosUri?: string;
```

### packages/core/src/authorization-request.ts: isSafeDisplayUri

Added right after `validateRegisteredRedirectUris`.
The function in full:

```typescript
/**
 * 表示用クライアントメタデータ URI（`client_uri` / `policy_uri` / `tos_uri`）を
 * リンクとして描画してよいかを判定する。
 *
 * OIDC Dynamic Client Registration 1.0 §2 / RFC 7591 §2 が定義するこれらの URI は
 * 同意画面でエンドユーザーがクリックする文書リンクになるため、redirect_uri の
 * 危険スキーム拒否（DANGEROUS_SCHEMES のデナイリスト。RFC 8252 §7.1 のカスタム
 * スキームは許す）とは逆に、http: / https: だけのアロウリストで判定する。
 * それ以外のスキーム（javascript: / data: / blob: / カスタムスキーム等）は
 * エンドユーザーのブラウザ文脈で実行・遷移し得るため、リンクにしない。
 *
 * URL として解析できない値（相対パス、スキーム無し文字列を含む）も false を返す。
 */
export function isSafeDisplayUri(uri: string): boolean {
  let parsed: URL;
  try {
    parsed = new URL(uri);
  } catch {
    return false;
  }
  // URL.protocol は ASCII 小文字に正規化された「スキーム + ':'」を返す
  return parsed.protocol === 'https:' || parsed.protocol === 'http:';
}
```

`packages/core/src/index.ts` adds `isSafeDisplayUri` to its export list.

### packages/core/src/authorization-request.test.ts: the added tests in full

```typescript
// OIDC Dynamic Client Registration 1.0 §2 / RFC 7591 §2: client_uri / policy_uri /
// tos_uri are End-User-facing documents the consent screen may render as links.
// Unlike redirect_uri (deny-listed schemes, custom schemes allowed for native
// apps), a clickable link on an OP page is allow-listed to http(s) only: any
// other scheme executes or navigates in the End-User's browser context.
describe('isSafeDisplayUri', () => {
  describe('allowed schemes', () => {
    it('should accept an https URI', () => {
      expect(isSafeDisplayUri('https://client.example.com/policy')).toBe(true);
    });

    it('should accept an https URI with query and fragment', () => {
      expect(isSafeDisplayUri('https://client.example.com/tos?lang=ja#section-2')).toBe(true);
    });

    it('should accept an http URI', () => {
      // Display links are informational; unlike redirect_uri, plaintext http is
      // not a code-interception channel, so it stays renderable.
      expect(isSafeDisplayUri('http://client.example.com/policy')).toBe(true);
    });
  });

  describe('rejected values', () => {
    it('should reject a javascript URI', () => {
      expect(isSafeDisplayUri('javascript:alert(1)')).toBe(false);
    });

    it('should reject an uppercase-scheme javascript URI', () => {
      expect(isSafeDisplayUri('JAVASCRIPT:alert(1)')).toBe(false);
    });

    it('should reject a data URI', () => {
      expect(isSafeDisplayUri('data:text/html,<script>alert(1)</script>')).toBe(false);
    });

    it('should reject a vbscript URI', () => {
      expect(isSafeDisplayUri('vbscript:msgbox(1)')).toBe(false);
    });

    it('should reject a blob URI', () => {
      expect(isSafeDisplayUri('blob:https://example.com/uuid')).toBe(false);
    });

    it('should reject a file URI', () => {
      expect(isSafeDisplayUri('file:///etc/passwd')).toBe(false);
    });

    it('should reject a custom scheme URI', () => {
      // Allowed for redirect_uri (RFC 8252 §7.1) but meaningless as a document
      // link on the consent screen.
      expect(isSafeDisplayUri('com.example.app:/policy')).toBe(false);
    });

    it('should reject a scheme-relative URI', () => {
      expect(isSafeDisplayUri('//client.example.com/policy')).toBe(false);
    });

    it('should reject a relative path', () => {
      expect(isSafeDisplayUri('/policy')).toBe(false);
    });

    it('should reject an empty string', () => {
      expect(isSafeDisplayUri('')).toBe(false);
    });

    it('should reject a string that is not a URI', () => {
      expect(isSafeDisplayUri('not a uri')).toBe(false);
    });
  });
});
```

## What the CLI adds to the generated code

The template sources are `packages/cli/src/frameworks/hono/templates.ts` (view parameter types, consent route, config; shared with express / fastify through web-standard), `packages/cli/src/frameworks/hono/views.ts` (hono's JSX views), `packages/cli/src/frameworks/hono/pages.ts` (the screen-routing layer) and `packages/cli/src/frameworks/nextjs/interaction.ts` (the Next.js consent page).
The generated result is shown file by file below.

### Generated routes/consent.ts: the new ConsentScreen fields

The generated result shared by hono / express / fastify:

```typescript
/** What the consent form needs, prepared for GET /consent. */
export interface ConsentScreen {
  kind: 'screen';
  /**
   * Must be posted back as the csrf_token field. It is the only value the form
   * carries about the transaction: the transaction itself travels in the
   * transaction cookie, and POST /consent accepts the token only for that one.
   */
  csrfToken: string;
  /** Scopes this End-User is asked to grant (already narrowed by the scope policy). */
  scopes: string[];
  /** Client requesting the authorization. */
  clientId: string;
  /**
   * Registered client_name (OIDC Dynamic Client Registration 1.0 §2 / RFC 7591
   * §2), when one is registered. Self-asserted: a view that shows it must keep
   * clientId visible next to it (RFC 6749 §10.2).
   */
  clientName?: string;
  /** Registered client_uri, present only when it passed the http(s) scheme check. */
  clientUri?: string;
  /**
   * Registered logo_uri, present only when it passed the http(s) scheme check.
   * The default view does not render it (see ConsentPageParams in views.ts).
   */
  logoUri?: string;
  /** Registered policy_uri, present only when it passed the http(s) scheme check. */
  policyUri?: string;
  /** Registered tos_uri, present only when it passed the http(s) scheme check. */
  tosUri?: string;
}
```

### Generated routes/consent.ts: loadClientDisplay and prepareConsent

The file's imports gain core's `isSafeDisplayUri` and `clientResolver as defaultClientResolver` from `resolvers.js`.
The GET path:

```typescript
/**
 * Display metadata of the requesting client for the consent screen
 * (OIDC Dynamic Client Registration 1.0 §2 / RFC 7591 §2: client_name /
 * client_uri / logo_uri / policy_uri / tos_uri).
 *
 * The screen renders without it, so an unknown client or a resolver failure
 * falls back to the clientId-only display instead of failing the GET: by the
 * time the browser is here, /authorize has already validated the client, and
 * the End-User is better served by a degraded screen than by a 500.
 *
 * Each URI is kept only when isSafeDisplayUri() (core) accepts its scheme
 * (http/https): these values become links (logo_uri an image URL) in the
 * End-User's browser, where javascript:/data:/custom schemes execute or
 * navigate. The check runs here in the logic layer, so every view — default
 * or custom — receives only renderable URIs.
 */
async function loadClientDisplay(
  c: any,
  clientId: string,
): Promise<Pick<ConsentScreen, 'clientName' | 'clientUri' | 'logoUri' | 'policyUri' | 'tosUri'>> {
  const clientResolver = c.get('clientResolver') ?? defaultClientResolver;
  const safeUri = (uri: string | undefined) =>
    uri !== undefined && isSafeDisplayUri(uri) ? uri : undefined;
  try {
    const client = await clientResolver.findClient(clientId);
    if (!client) return {};
    return {
      clientName: client.clientName,
      clientUri: safeUri(client.clientUri),
      logoUri: safeUri(client.logoUri),
      policyUri: safeUri(client.policyUri),
      tosUri: safeUri(client.tosUri),
    };
  } catch {
    return {};
  }
}

/**
 * GET /consent: load the transaction this browser's cookie names and describe
 * the form, or the error to show instead when there is none.
 */
export async function prepareConsent(c: any): Promise<ConsentScreen | ConsentError> {
  const loaded = await loadTransaction(c);
  if ('kind' in loaded) return loaded;
  const { transaction } = loaded;
  return {
    kind: 'screen',
    csrfToken: transaction.csrfToken,
    scopes: transaction.scope.split(' ').filter(Boolean),
    clientId: transaction.clientId,
    ...(await loadClientDisplay(c, transaction.clientId)),
  };
}
```

With custom scopes declared at generation time, only the destructuring and scope resolution change as before; the `loadClientDisplay` spread is composed the same way.

### Generated views.ts: the new ConsentPageParams fields

The view input type gains the same five fields.
The JSDoc doubles as the decision record for custom-view authors:

```typescript
export interface ConsentPageParams {
  /**
   * CSRF token (must be included as the hidden csrf_token form field). The form
   * carries nothing else about the transaction: the browser's transaction cookie
   * says which one this is, and the token has to belong to it.
   */
  csrfToken: string;
  /** Scopes requested by the client */
  scopes: string[];
  /** Client ID requesting authorization */
  clientId: string;
  /**
   * Registered client_name (OIDC Dynamic Client Registration 1.0 §2 / RFC 7591 §2),
   * when the client registered one. The name is self-asserted and spoofable, so a
   * view that shows it must keep the clientId visible next to it: RFC 6749 §10.2's
   * client-impersonation defense works only while the End-User can identify the
   * client.
   */
  clientName?: string;
  /**
   * Registered client_uri (client home page). Already scheme-checked by
   * routes/consent.ts (http/https only, isSafeDisplayUri in the core package),
   * so a view may render it as a link as-is — HTML-escaping still applies.
   */
  clientUri?: string;
  /**
   * Registered logo_uri. Passed through for custom views, but the default view
   * deliberately does NOT render it: an <img> whose URL the client chose opens a
   * default phishing surface (a spoofed well-known logo lends the consent screen
   * false trust), widens CSP img-src to arbitrary hosts, and leaks the End-User's
   * IP to a third-party server on every consent view. Render it only from a
   * custom view (createViews()) after weighing those.
   */
  logoUri?: string;
  /**
   * Registered policy_uri (how the client uses profile data). Scheme-checked like
   * clientUri; the default view renders it as a link when present.
   */
  policyUri?: string;
  /**
   * Registered tos_uri (terms of service). Scheme-checked like clientUri; the
   * default view renders it as a link when present.
   */
  tosUri?: string;
}
```

### Generated views.ts: defaultConsentPage (string views for express / fastify)

```typescript
function defaultConsentPage(params: ConsentPageParams): string {
  // Every string interpolated into HTML is escaped, including values that are
  // server-generated by the default stores: users may replace stores/views.
  const scopeListHtml = params.scopes
    .map((s) => `    <li>${escapeHtml(s)}</li>`)
    .join('\n');

  const escapedClientId = escapeHtml(params.clientId);

  // OIDC Dynamic Client Registration 1.0 §2: client_name identifies the client
  // to the End-User. The name is self-asserted, so the clientId stays visible
  // next to it — a spoofed display name alone must not pass as identification
  // (RFC 6749 §10.2). The URIs below were scheme-checked (http/https only) in
  // routes/consent.ts before they reached this view; escaping still applies.
  const clientDisplayHtml = params.clientName
    ? `<strong>${escapeHtml(params.clientName)}</strong> (<code>${escapedClientId}</code>)`
    : `<strong>${escapedClientId}</strong>`;

  // params.logoUri is deliberately not rendered here: an <img> whose URL the
  // client registered opens a default phishing surface (a spoofed well-known
  // logo lends this screen false trust), widens CSP img-src to arbitrary hosts,
  // and leaks the End-User's IP to a third-party server on every consent view.
  // Render a logo only from a custom view (createViews()) after weighing those.
  const clientLinkItems = [
    params.clientUri ? `    <li><a href="${escapeHtml(params.clientUri)}" target="_blank" rel="noopener noreferrer">Website</a></li>` : '',
    params.policyUri ? `    <li><a href="${escapeHtml(params.policyUri)}" target="_blank" rel="noopener noreferrer">Privacy Policy</a></li>` : '',
    params.tosUri ? `    <li><a href="${escapeHtml(params.tosUri)}" target="_blank" rel="noopener noreferrer">Terms of Service</a></li>` : '',
  ].filter((item) => item !== '');
  const clientLinksHtml = clientLinkItems.length > 0
    ? `  <ul>\n${clientLinkItems.join('\n')}\n  </ul>\n`
    : '';

  return `<!DOCTYPE html>
<html>
<head><title>Consent</title></head>
<body>
  <h1>Authorize Application</h1>
  <p>Client ${clientDisplayHtml} is requesting access to the following scopes:</p>
  <ul>
${scopeListHtml}
  </ul>
${clientLinksHtml}  <form method="POST" action="/consent">
    <input type="hidden" name="csrf_token" value="${escapeHtml(params.csrfToken)}" />
    <button type="submit" name="action" value="approve">Approve</button>
    <button type="submit" name="action" value="deny">Deny</button>
  </form>
</body>
</html>`;
}
```

### Generated views.tsx: defaultConsentPage (hono's JSX view)

hono's views are JSX; interpolated values are escaped by JSX itself.

```tsx
function defaultConsentPage(params: ConsentPageParams): JSX.Element {
  // OIDC Dynamic Client Registration 1.0 §2: client_name identifies the client
  // to the End-User. The name is self-asserted, so the clientId stays visible
  // next to it — a spoofed display name alone must not pass as identification
  // (RFC 6749 §10.2). The URIs below were scheme-checked (http/https only) in
  // routes/consent.ts before they reached this view.
  //
  // params.logoUri is deliberately not rendered here: an <img> whose URL the
  // client registered opens a default phishing surface (a spoofed well-known
  // logo lends this screen false trust), widens CSP img-src to arbitrary hosts,
  // and leaks the End-User's IP to a third-party server on every consent view.
  // Render a logo only from a custom view (createViews()) after weighing those.
  const clientLinks = [
    params.clientUri ? { href: params.clientUri, label: 'Website' } : undefined,
    params.policyUri ? { href: params.policyUri, label: 'Privacy Policy' } : undefined,
    params.tosUri ? { href: params.tosUri, label: 'Terms of Service' } : undefined,
  ].filter((link): link is { href: string; label: string } => link !== undefined);
  return (
    <Layout title="Consent">
      <h1>Authorize Application</h1>
      <p>
        Client{' '}
        {params.clientName ? (
          <>
            <strong>{params.clientName}</strong> (<code>{params.clientId}</code>)
          </>
        ) : (
          <strong>{params.clientId}</strong>
        )}{' '}
        is requesting access to the following scopes:
      </p>
      <ScopeList scopes={params.scopes} />
      {clientLinks.length > 0 ? (
        <ul>
          {clientLinks.map((link) => (
            <li>
              <a href={link.href} target="_blank" rel="noopener noreferrer">{link.label}</a>
            </li>
          ))}
        </ul>
      ) : null}
      <form method="post" action="/consent">
        <input type="hidden" name="csrf_token" value={params.csrfToken} />
        <button type="submit" name="action" value="approve">Approve</button>
        <button type="submit" name="action" value="deny">Deny</button>
      </form>
    </Layout>
  );
}
```

### Generated pages/consent.ts: the GET handler pass-through

The screen-routing layer only moves the result of `prepareConsent` into the view input; the new fields join that pass-through.

```typescript
consentPage.get('/', async (c) => {
  const screen = await prepareConsent(c);
  if (screen.kind === 'error') return renderErrorPage(c, screen);
  return renderConsentPage(c, {
    csrfToken: screen.csrfToken,
    scopes: screen.scopes,
    clientId: screen.clientId,
    // Registered display metadata (OIDC Dynamic Client Registration 1.0 §2);
    // each field is undefined when unregistered, and the URIs were already
    // scheme-checked in routes/consent.ts.
    clientName: screen.clientName,
    clientUri: screen.clientUri,
    logoUri: screen.logoUri,
    policyUri: screen.policyUri,
    tosUri: screen.tosUri,
  });
});
```

### Generated consent/page.tsx (Next.js)

Next.js fuses route and view into one React Server Component, so the metadata-resolution helper is generated inside the page.
`clientResolver` is a named export of `_oidc-provider/provider`.
The page in full:

```tsx
import { isSafeDisplayUri } from '@maronn-openid-connect/core';
import { clientResolver } from '../_oidc-provider/provider';
import { requireTransaction } from '../_oidc-provider/transaction';
import { consentAction } from './actions';

// The page renders the transaction named by this browser's transaction cookie,
// so it must always render dynamically (never from a static cache).
export const dynamic = 'force-dynamic';

/** Display metadata the consent screen shows about the requesting client. */
interface ClientDisplay {
  clientName?: string;
  clientUri?: string;
  policyUri?: string;
  tosUri?: string;
}

/**
 * Display metadata of the requesting client
 * (OIDC Dynamic Client Registration 1.0 §2 / RFC 7591 §2: client_name /
 * client_uri / policy_uri / tos_uri).
 *
 * The screen renders without it, so an unknown client or a resolver failure
 * falls back to the clientId-only display instead of failing the page: by the
 * time the browser is here, /authorize has already validated the client, and
 * the End-User is better served by a degraded screen than by an error page.
 *
 * Each URI is kept only when isSafeDisplayUri() (core) accepts its scheme
 * (http/https): these values become links in the End-User's browser, where
 * javascript:/data:/custom schemes execute or navigate.
 *
 * The registered logo_uri is deliberately not loaded: an <img> whose URL the
 * client registered opens a default phishing surface (a spoofed well-known
 * logo lends this screen false trust), widens CSP img-src to arbitrary hosts,
 * and leaks the End-User's IP to a third-party server on every consent view.
 * Render a logo only from a customized page after weighing those.
 */
async function loadClientDisplay(clientId: string): Promise<ClientDisplay> {
  const safeUri = (uri: string | undefined) =>
    uri !== undefined && isSafeDisplayUri(uri) ? uri : undefined;
  try {
    const client = await clientResolver.findClient(clientId);
    if (!client) return {};
    return {
      clientName: client.clientName,
      clientUri: safeUri(client.clientUri),
      policyUri: safeUri(client.policyUri),
      tosUri: safeUri(client.tosUri),
    };
  } catch {
    return {};
  }
}

/**
 * Consent page (React Server Component).
 *
 * A real Next.js page, so the consent UI can be built with JSX and React
 * components. The form posts to the consentAction Server Action (actions.ts).
 * Keep the hidden csrf_token field when customizing it: neither the URL nor the
 * form names the transaction — the browser's transaction cookie does — and the
 * action accepts the token only for that transaction.
 *
 * A browser with no live transaction renders not-found.tsx (see
 * requireTransaction() in _oidc-provider/transaction.ts).
 */
export default async function ConsentPage() {
  const { transaction } = await requireTransaction();

  const scopes = transaction.scope.split(' ').filter(Boolean);

  // OIDC Dynamic Client Registration 1.0 §2: client_name identifies the client
  // to the End-User. The name is self-asserted, so the clientId stays visible
  // next to it — a spoofed display name alone must not pass as identification
  // (RFC 6749 §10.2).
  const display = await loadClientDisplay(transaction.clientId);
  const clientLinks = [
    display.clientUri ? { href: display.clientUri, label: 'Website' } : undefined,
    display.policyUri ? { href: display.policyUri, label: 'Privacy Policy' } : undefined,
    display.tosUri ? { href: display.tosUri, label: 'Terms of Service' } : undefined,
  ].filter((link): link is { href: string; label: string } => link !== undefined);
  return (
    <main>
      <h1>Authorize Application</h1>
      <p>
        Client{' '}
        {display.clientName ? (
          <>
            <strong>{display.clientName}</strong> (<code>{transaction.clientId}</code>)
          </>
        ) : (
          <strong>{transaction.clientId}</strong>
        )}{' '}
        is requesting access to the following scopes:
      </p>
      <ul>
        {scopes.map((scope) => (
          <li key={scope}>{scope}</li>
        ))}
      </ul>
      {clientLinks.length > 0 ? (
        <ul>
          {clientLinks.map((link) => (
            <li key={link.label}>
              <a href={link.href} target="_blank" rel="noopener noreferrer">
                {link.label}
              </a>
            </li>
          ))}
        </ul>
      ) : null}
      {/*
        The submit buttons carry the authorization decision (OIDC Core 1.0
        §3.1.2.4). consentAction accepts exactly 'approve' and 'deny' and rejects
        everything else, so keep both values when customizing this markup:
        renaming 'approve' makes every approval fail with an error page.
      */}
      <form action={consentAction}>
        <input type="hidden" name="csrf_token" value={transaction.csrfToken} />
        <button type="submit" name="action" value="approve">
          Approve
        </button>
        <button type="submit" name="action" value="deny">
          Deny
        </button>
      </form>
    </main>
  );
}
```

The Next.js `ClientDisplay` has no `logoUri`, and that is deliberate.
With page and view fused, the "pass it but do not render it" split cannot exist, so the helper does not load it at all; a customized page replaces the helper along with the markup.

### Generated config.ts: display metadata on example-client

The sample's default client gains example values, so a local run shows the new display out of the box.

```typescript
      clientId: 'example-client',
      clientSecret: 'example-secret',
      redirectUris: ['http://localhost:3000/callback'],
      clientType: 'confidential' as const,
      // OIDC Dynamic Client Registration 1.0 §2 / RFC 7591 §2: End-User-facing
      // metadata the consent screen renders. client_name is shown next to the
      // client_id (never instead of it: the name is self-asserted and spoofable);
      // policy_uri / tos_uri become links after an http(s)-only scheme check
      // (isSafeDisplayUri in routes/consent.ts).
      clientName: 'Example Client',
      policyUri: 'http://localhost:3000/privacy-policy',
      tosUri: 'http://localhost:3000/terms-of-service',
```

## E2E tests

### tests/e2e/specs/consent-client-identification.spec.ts (new, in full)

The E2E OP registers its clients through `OIDC_CLIENTS_JSON`, so `tests/e2e/playwright.config.ts` adds `clientName` / `clientUri` / `logoUri` / `policyUri` / `tosUri` to `e2e-client`.
`logo_uri` is registered precisely so the spec can pin that the default view still emits no `<img>`.

```typescript
import { expect, test, type Page } from '@playwright/test';

const host = process.env.E2E_HOST ?? '127.0.0.1';
const clientPort = Number(process.env.E2E_CLIENT_PORT ?? '3020');
const clientBaseURL = process.env.E2E_CLIENT_BASE_URL ?? `http://${host}:${clientPort}`;
const resourceServerPort = Number(process.env.E2E_RESOURCE_SERVER_PORT ?? '3030');
const resourceServerURL =
  process.env.E2E_RESOURCE_SERVER_URL ?? `http://${host}:${resourceServerPort}`;

/**
 * Consent screen client identification (OIDC Dynamic Client Registration 1.0
 * §2 / RFC 7591 §2: client_name / client_uri / policy_uri / tos_uri).
 *
 * RFC 6749 §10.2 counts on the resource owner's active involvement against
 * client impersonation, which works only while the End-User can identify the
 * client on the consent screen (OIDC Core 1.0 §3.1.2.4 requires an
 * authorization decision before information is released). The generated
 * consent screen therefore renders the registered client_name NEXT TO the
 * client_id (the name is self-asserted and spoofable, so it must not replace
 * the identifier) and the registered document URIs as links, while a client
 * that registered nothing keeps the plain client_id display.
 *
 * logo_uri is registered for the e2e client on purpose: the default view must
 * NOT render it (a client-chosen <img> URL is a default phishing surface), and
 * the <img>-free markup is pinned here.
 */
test.describe('Consent screen client identification', () => {
  test('should display the registered client_name with the client_id and document links', async ({
    page,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    await page.goto(`${clientBaseURL}/start`);
    await login(page);
    await expect(page).toHaveURL(new RegExp(`^${escapeRegExp(issuer)}/consent$`));

    // client_name is rendered, and the client_id stays visible beside it.
    await expect(page.locator('strong', { hasText: 'E2E Test Client' })).toBeVisible();
    await expect(page.locator('code', { hasText: 'e2e-client' })).toBeVisible();

    // The registered document URIs become links (scheme-checked http/https).
    await expect(page.getByRole('link', { name: 'Website' })).toHaveAttribute(
      'href',
      `${clientBaseURL}/`,
    );
    await expect(page.getByRole('link', { name: 'Privacy Policy' })).toHaveAttribute(
      'href',
      `${clientBaseURL}/privacy-policy`,
    );
    await expect(page.getByRole('link', { name: 'Terms of Service' })).toHaveAttribute(
      'href',
      `${clientBaseURL}/terms-of-service`,
    );

    // The registered logo_uri is NOT rendered by the default view.
    await expect(page.locator('img')).toHaveCount(0);

    // The enriched screen still completes the flow.
    await page.getByRole('button', { name: 'Approve' }).click();
    await expect(page).toHaveURL(new RegExp(`^${escapeRegExp(clientBaseURL)}/callback\\?`));
    expect(new URL(page.url()).searchParams.get('error')).toBe(null);
  });

  test('should fall back to the client_id when the client registered no display metadata', async ({
    page,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    // e2e-resource-server registers no client_name / policy_uri / tos_uri, and
    // no client app drives it through a browser, so the authorization request
    // is built directly. The code is never redeemed; only the consent screen
    // matters, so the static S256 test vector of RFC 7636 Appendix B suffices.
    const authorizeUrl = new URL(`${issuer}/authorize`);
    authorizeUrl.searchParams.set('response_type', 'code');
    authorizeUrl.searchParams.set('client_id', 'e2e-resource-server');
    authorizeUrl.searchParams.set('redirect_uri', `${resourceServerURL}/unused-callback`);
    authorizeUrl.searchParams.set('scope', 'openid');
    authorizeUrl.searchParams.set('state', 'consent-display-fallback');
    authorizeUrl.searchParams.set(
      'code_challenge',
      'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
    );
    authorizeUrl.searchParams.set('code_challenge_method', 'S256');

    await page.goto(authorizeUrl.toString());
    await login(page);
    await expect(page).toHaveURL(new RegExp(`^${escapeRegExp(issuer)}/consent$`));

    // Unregistered metadata degrades to the plain client_id display: no name,
    // no document links.
    await expect(page.locator('strong', { hasText: 'e2e-resource-server' })).toBeVisible();
    await expect(page.getByRole('link', { name: 'Privacy Policy' })).toHaveCount(0);
    await expect(page.getByRole('link', { name: 'Terms of Service' })).toHaveCount(0);
    await expect(page.getByRole('link', { name: 'Website' })).toHaveCount(0);
  });
});

async function login(page: Page): Promise<void> {
  await page.getByLabel('Username:').fill('testuser');
  await page.getByLabel('Password:').fill('password');
  await page.getByRole('button', { name: 'Login' }).click();
}

function requireBaseUrl(baseURL: string | undefined): string {
  if (!baseURL) {
    throw new Error('Playwright baseURL must be configured for the OP under test');
  }
  return baseURL;
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}
```

### Updates to existing specs

`auth-code-flow.spec.ts` and `pushed-authorization-requests.spec.ts` pinned the consent screen's `<strong>` to the raw `client_id`.
With `e2e-client` now registering a `client_name`, both expectations became `E2E Test Client` in `<strong>` plus `e2e-client` in `<code>`, and the scope-list assertion was narrowed to the first `<ul>` (the second one now holds the document links):

```typescript
    // OIDC Dynamic Client Registration 1.0 §2: the registered client_name is
    // shown, with the client_id kept visible beside it (RFC 6749 §10.2).
    await expect(page.locator('strong')).toHaveText('E2E Test Client');
    await expect(page.locator('code')).toHaveText(clientId);
    // The first list is the requested scopes; the second holds the registered
    // document links (consent-client-identification.spec.ts pins those).
    await expect(page.locator('ul').first().locator('li')).toHaveText([
      'openid',
      'profile',
      'email',
    ]);
```

## Verification

All of the following were confirmed to succeed:

```bash
pnpm run build
pnpm run typecheck
pnpm --filter "./packages/*" test   # core 1173 / cli 53 / google-login 130 / experimental 624
pnpm run test:conformance
pnpm run test:release-contract
pnpm run test:e2e                   # all four samples: hono / express / fastify / nextjs
```

Malicious-input checks (scheme filtering, HTML escaping) live in core's unit tests for `isSafeDisplayUri` and in the existing escape-everything machinery, rather than in E2E: the samples deliberately register no malicious client.
