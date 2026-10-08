# 同意画面のクライアント識別情報表示の実装解説

対象は `@maronn-openid-connect/core` のクライアント登録メタデータと、CLI が生成する同意画面（hono / express / fastify / Next.js の 4 フレームワーク）である。
OSS リポジトリのタスク `tasks/done/p2-consent-screen-client-identification.md` から実装した。

## この機能は何をするのか

生成 OP の同意画面に、クライアントが登録した表示用メタデータを描画できるようにする。
対象は OIDC Dynamic Client Registration 1.0 §2 / RFC 7591 §2 が定義する `client_name` / `client_uri` / `logo_uri` / `policy_uri` / `tos_uri` の 5 フィールドである。

変更前の同意画面は、`client_id` の生文字列とスコープ名の生文字列しか表示していなかった。

```html
<p>Client <strong>example-client</strong> is requesting access to the following scopes:</p>
<ul><li>openid</li><li>profile</li><li>email</li></ul>
```

OIDC Core 1.0 §3.1.2.4 は「情報を RP へ渡す前に authorization decision を得なければならない」と定めており、判断できる状態での同意が前提になっている。
また RFC 6749 §10.2 は、クライアントなりすましへの防御を「クライアント認証」と「リソースオーナーの能動的な関与」の二本立てで語るが、後者はエンドユーザーがクライアントを識別できて初めて機能する。
内部識別子しか出ない画面では、エンドユーザーは「誰に」「何を」許可しようとしているのかを識別子から推測するしかなかった。

変更後は、`client_name` を登録したクライアントの同意画面が次のようになる。

```html
<p>Client <strong>Example Client</strong> (<code>example-client</code>) is requesting access to the following scopes:</p>
<ul><li>openid</li><li>profile</li><li>email</li></ul>
<ul>
  <li><a href="..." target="_blank" rel="noopener noreferrer">Privacy Policy</a></li>
  <li><a href="..." target="_blank" rel="noopener noreferrer">Terms of Service</a></li>
</ul>
```

何も登録していないクライアントは従来どおり `client_id` のみで表示される。
後方互換の破壊はない。

## ユースケース

PoC で複数のクライアントを 1 つの OP にぶら下げると、同意画面に出る識別子だけでは「いまどのアプリに許可しようとしているのか」をデモ参加者に説明しにくい。
`client_name` を登録すれば、画面がそのまま説明になる。

本番導入を見据える開発者にとっては、プライバシーポリシーと利用規約への導線が同意画面の標準的な要素になっている。
`policy_uri` / `tos_uri` を登録メタデータとして持てることで、ビューを自作しなくても既定画面がこの導線を出せる。

将来 Dynamic Client Registration（RFC 7591 / OIDC Registration 1.0）を実装するときは、登録リクエストの JSON が同じ語彙でこれらのフィールドを運んでくる。
`ClientInfo` のフィールド名を仕様の snake_case と 1 対 1 に対応させてあるため、登録エンドポイントはパース結果をそのまま流し込める。

## 設計判断

### 表示用 URI はアロウリストで判定する

core には redirect_uri 用の危険スキーム判定（`DANGEROUS_SCHEMES` のデナイリスト）が既にあるが、表示用 URI には再利用せず、`http:` / `https:` だけを許す `isSafeDisplayUri()` を新設した。
二つの検証は守るものが違うからである。
redirect_uri は RFC 8252 §7.1 のカスタムスキーム（`com.example.app:/callback`）を正当に使うため、危険と分かっているスキームだけを拒否するデナイリストになっている。
一方、同意画面のリンクはエンドユーザーがクリックする文書 URL であり、カスタムスキームを許す理由がない。
`javascript:` / `data:` のような実行系スキームを列挙し漏らすリスクを負うより、Web 文書として意味のある 2 スキームだけを許す方が安全で、実装も短い。

### スキーム検査はビューではなくロジック層で行う

検査は生成コードの `routes/consent.ts`（Next.js は `consent/page.tsx` のヘルパー）で行い、検査を通らなかった URI は undefined としてビューへ渡す。
ビュー側に検査を置かなかったのは、ビューが差し替え可能だからである。
生成コードの利用者は `createViews()` で自前のビューを注入できるが、その全員に「リンクにする前にスキームを確かめる」規律を要求するのは現実的でない。
ロジック層で落としておけば、既定ビューも自作ビューも描画してよい URI しか受け取らない。

### logo_uri は渡すが、既定ビューでは描画しない

`logo_uri` は `ConsentPageParams` までは運ぶが、既定ビューは `<img>` を出さない。
クライアントが選んだ URL の画像を OP の画面に既定で埋め込むと、三つの問題が開くからである。
第一に、著名サービスのロゴを詐称したクライアントが、同意画面に偽の信頼感をまとえる（フィッシング面）。
第二に、CSP の `img-src` を任意ホストへ広げる前提になる。
第三に、同意画面を開くたびにエンドユーザーの IP アドレスが第三者のサーバーへ送られる。
これらを引き受けるかどうかは運用者の判断であるべきなので、自前ビューで明示的に選択させ、判断材料を生成コードのコメントに残した。

### client_name は client_id に併記する

`client_name` を出すときも `client_id` を `<code>` で併記する。
名称は登録者の自己申告であり、`Example Client` を名乗る別クライアントを登録できてしまうため、名称単独の表示はなりすましの隠れ蓑になる。
識別子が常に見えていれば、エンドユーザー（と運用のスクリーンショット監査）は名称の詐称に気付ける。

### クライアント未解決でも 500 にしない

`prepareConsent` の表示用メタデータ解決は、resolver の失敗とクライアント不在をどちらも「メタデータなし」に落とす。
この画面に到達した時点で `/authorize` がクライアントを検証済みなので、ここでの解決失敗は表示の劣化で済ませるのが適切であり、同意フロー自体を 500 で止める理由にならない。

### semver は core / cli とも minor

core は `ClientInfo` へのフィールド追加と `isSafeDisplayUri()` の新規 export で、API の追加にあたる。
cli は生成される同意画面の機能追加である。
リポジトリの release contract は core の minor で `experimental` / `google-login` の同時リリースを要求するため、両パッケージの patch changeset を添え、core peer range の下限を `>=0.7.0` へ上げた。

## core の変更コード

### packages/core/src/authorization-request.ts：ClientInfo の追加フィールド

`ClientInfo` の末尾に表示用の 5 フィールドを OPTIONAL で追加した。
追加部分の全文は次のとおりである。

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

### packages/core/src/authorization-request.ts：isSafeDisplayUri

`validateRegisteredRedirectUris` の直後に追加した。
関数全文は次のとおりである。

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

`packages/core/src/index.ts` の export 一覧へ `isSafeDisplayUri` を追加している。

### packages/core/src/authorization-request.test.ts：追加テスト全文

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

## CLI が生成コードへ注入するコード

生成元は `packages/cli/src/frameworks/hono/templates.ts`（ビュー型・ルート・設定。web-standard 経由で express / fastify も共有）、`packages/cli/src/frameworks/hono/views.ts`（hono の JSX ビュー）、`packages/cli/src/frameworks/hono/pages.ts`（画面ルーティング層）、`packages/cli/src/frameworks/nextjs/interaction.ts`（Next.js の同意ページ）である。
以下は生成結果をファイルごとに示す。

### 生成物 routes/consent.ts：ConsentScreen の追加フィールド

hono / express / fastify で共通の生成結果である。
`ConsentScreen` に表示用フィールドを追加した。

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

### 生成物 routes/consent.ts：loadClientDisplay と prepareConsent

同ファイルの import には core の `isSafeDisplayUri` と、`resolvers.js` の `clientResolver as defaultClientResolver` が加わる。
GET 経路の本体は次のとおりである。

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

カスタムスコープを宣言して生成した場合は、`prepareConsent` の分割束縛とスコープ解決だけが従来どおり変わり、`loadClientDisplay` の合成は同じ形で入る。

### 生成物 views.ts：ConsentPageParams の追加フィールド

ビューの入力型にも同じ 5 フィールドを追加した。
JSDoc は自作ビューの作者に向けた判断材料を兼ねる。

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

### 生成物 views.ts：defaultConsentPage（express / fastify の文字列ビュー）

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

### 生成物 views.tsx：defaultConsentPage（hono の JSX ビュー）

hono のビューは JSX で、補間値のエスケープは JSX が担う。

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

### 生成物 pages/consent.ts：GET ハンドラの受け渡し

画面ルーティング層は `prepareConsent` の結果をビューの入力へ移し替えるだけである。
追加フィールドの受け渡しが加わった。

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

### 生成物 consent/page.tsx（Next.js）

Next.js はルートとビューが React Server Component に一体化しているため、表示用メタデータの解決ヘルパーをページ内に生成する。
`clientResolver` は `_oidc-provider/provider` の named export である。
ページ全文は次のとおりである。

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

Next.js の `ClientDisplay` に `logoUri` が無いのは意図的である。
ページとビューが一体の Next.js では「渡すが描画しない」という分担が成り立たないため、ヘルパー自体が読み込まず、カスタマイズ時はヘルパーごと書き換える。

### 生成物 config.ts：example-client の表示用メタデータ

サンプルの既定クライアントに例を追加し、ローカル起動でそのまま表示の変化を体験できるようにした。

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

## E2E テスト

### tests/e2e/specs/consent-client-identification.spec.ts（新規・全文）

E2E の OP は `OIDC_CLIENTS_JSON` でクライアントを登録するため、`tests/e2e/playwright.config.ts` の `e2e-client` に `clientName` / `clientUri` / `logoUri` / `policyUri` / `tosUri` を追加した。
`logo_uri` を登録するのは、既定ビューがそれでも `<img>` を出さないことを固定するためである。

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

### 既存スペックの追随

`auth-code-flow.spec.ts` と `pushed-authorization-requests.spec.ts` は、同意画面の `<strong>` が `client_id` そのものであることを固定していた。
`e2e-client` が `client_name` を登録したため、`<strong>` は `E2E Test Client`、`<code>` が `e2e-client` という期待へ更新し、スコープ一覧の検証は「最初の `<ul>`」に限定した（二つ目の `<ul>` は文書リンクの一覧になったため）。

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

## 検証

次のコマンドがすべて成功することを確認した。

```bash
pnpm run build
pnpm run typecheck
pnpm --filter "./packages/*" test   # core 1173 / cli 53 / google-login 130 / experimental 624
pnpm run test:conformance
pnpm run test:release-contract
pnpm run test:e2e                   # hono / express / fastify / nextjs の 4 sample
```

スキーム検査と HTML エスケープのような悪性入力の検証は、sample に悪性クライアントを登録しない方針のため E2E ではなく core の単体テスト（`isSafeDisplayUri`）と既存の全値エスケープ機構が担う。
