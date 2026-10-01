# 空文字列の `client_secret` を「未提示」として扱う実装解説

対象は `@maronn-openid-connect/core` のクライアント認証と、CLI が生成する契約テストである。
OSS リポジトリのタスク `tasks/done/p2-client-auth-empty-client-secret-as-absent.md` から実装した。

## この機能は何をするのか

Token Endpoint のクライアント認証で、値の無いフォームフィールド（`client_secret=`）を「資格情報の提示なし」として扱うようにする。
RFC 6749 §3.2 は「Parameters sent without a value MUST be treated as if they were omitted from the request」と定めており、空値の `client_secret` は省略と同じ扱いになるべきだからである。

変更前の `extractClientCredentials` は `params.client_secret !== undefined` で提示有無を判定していたため、空文字列を client_secret_post の資格情報として数えていた。
これにより次の 2 つの誤挙動が起きていた。

1. `token_endpoint_auth_method: none` の public client が `client_id=x&client_secret=` を送ると、method が `client_secret_post` と判定され、登録方式不一致の `invalid_client` で拒否される。
2. `Authorization: Basic` と空の `client_secret` フィールドが併存すると、「複数認証方式」の `invalid_request` で拒否される。

同じファイルの後段ステップ（`validateClientAuthMethod` / `verifyClientSecret`）は falsy 判定で「空 secret = 未提示」と扱っており、抽出側だけ意味論が割れていた。
今回の変更は、抽出の冒頭で空文字列を undefined に正規化し、この割れを解消する。

## ユースケース

設定オブジェクト全体をフォームボディへ直列化するクライアント実装では、未設定のシークレットが空文字列フィールドとして送出されることがある。
変更前は、この形のリクエストを出す public client がこの OP からトークンを一切取得できなかった。
また、Basic 認証を使うクライアントの HTTP スタックがボディに空の `client_secret` フィールドを残すと、実際に使われた認証方式は一つなのに多重方式として拒否されていた。
どちらもエラーメッセージが方式不一致・多重方式を指すため、原因（余分な空フィールド）にたどり着きにくかった。

修正はセキュリティを弱めない。
confidential client が空の `client_secret` だけを送った場合は、後段の `validateClientAuthMethod` が従来どおり `invalid_client` で拒否する。
変わるのは拒否理由（方式不一致 → 認証必須）と、public client が正しく通ることだけである。

## 設計判断

正規化は `extractClientCredentials` の冒頭の 1 箇所で行う。
検討資料（`study-material/done/client-auth-empty-string-client-secret-presence.md`）には、判定箇所ごとに truthy 判定へ揃える案もあったが、結果が同じでも「値なしは省略」という仕様上の意味論が実装に現れにくいため、一箇所での正規化を採った。
正規化した値を多重方式判定、method 判定、抽出結果のすべてが参照するので、後段の falsy 判定と合わせてモジュール全体の意味論が揃う。

対象外とした範囲が 2 つある。
第一に、`client_id` の空文字列は正規化しない。
現状も `!clientId` で「認証必須」に落ちるため、挙動が変わらず、触る理由がない。
第二に、Basic ヘッダ内の空 secret（`base64(client:)`）の扱いは変えない。
§3.2 が対象とするのはリクエストのパラメータであり、Basic ヘッダはパラメータではない。
この経路は従来どおり `verifyClientSecret` の定数時間比較が拒否する。

semver は core / cli とも patch とした。
core は仕様（MUST）への適合を目的とした不具合修正であり、API の追加・変更がない。
cli は生成される契約テストだけの変更である。
リポジトリの release contract は、core の次バージョン（0.4.1）より古い下限を peer range に残すことを patch でも許さないため、`experimental` と `google-login` の core peer range 下限を `>=0.4.1` へ上げ、両パッケージの patch changeset を添えた。

## core の変更コード

### packages/core/src/client-auth.ts：extractClientCredentials

変更後の関数全体は次のとおりである。
冒頭の `postSecret` が今回追加した正規化で、以降の判定はすべてこの値を参照する。

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

正規化が効く経路を追うと、挙動の変化が読み取れる。
`client_id=x&client_secret=` の場合、`postSecret` が undefined になるので `hasPostSecret` は false、抽出される `clientSecret` も undefined となり、method は `'none'` に落ちる。
Basic ヘッダと `client_secret=` が併存する場合も `hasPostSecret` が false なので多重方式の throw を通過し、Basic 側の資格情報がそのまま抽出される。

## core のテスト

### packages/core/src/client-auth-steps.test.ts：追加した 4 ケース

`extractClientCredentials` の describe に次の 4 ケースを追加した。
`basicHeader` と `captureError` は同ファイル既存のヘルパー、`confidentialClient` は登録方式 client_secret_basic の既存フィクスチャである。

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

3 つ目のケース（client_id なし）は変更前から通っていた挙動だが、正規化の導入で「空 secret 単独 = 何も提示していない」という解釈が意味を持つようになったため、回帰防止として固定した。
4 つ目のケースは抽出と検証の 2 ステップを続けて呼び、拒否理由が「方式不一致」から「認証必須」に変わったことを error_description で固定する。
既存の多重方式拒否（Basic + 非空の `client_secret`）は既存ケース `should reject combining the Basic header with body credentials` が引き続き固定している。

## CLI が生成コードへ注入するコード

### packages/cli/src/frameworks/hono/templates.ts：tokenEndpointAuthMethodsConformanceBlock

生成される `conformance.test.ts` の「Token Endpoint client authentication methods」describe に 3 ケースを追加した。
このブロックは hono テンプレートが export し、web-standard テンプレート（express / fastify / nextjs）も import して使うため、1 箇所の追加で 4 フレームワークすべての生成物に展開される。
以下は生成されるテストコードそのものである（各 sample の `conformance.test.ts` にこのまま現れる）。

前半 2 ケースは認可コードフローをフルで走らせる。
同じ describe の既存ケースと同じく、`/authorize` → `/login` → `/consent` → `/token` をたどり、最後の token リクエストだけが検証対象の形を持つ。

```typescript
    // RFC 6749 §3.2: "Parameters sent without a value MUST be treated as if they
    // were omitted from the request." A public client whose HTTP stack serializes
    // an unset secret as client_secret= must still authenticate as method 'none'.
    it('should treat an empty client_secret field as absent for a public client', async () => {
      const verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
      const authorizeRes = await app.request(
        '/authorize?response_type=code&client_id=c-public' +
        '&redirect_uri=' + encodeURIComponent(REDIRECT_URI) +
        '&scope=openid&state=public-empty-secret' +
        '&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256',
      );
      const loginPath = relativeLocation(authorizeRes.headers.get('Location'));
      // Carry forward whatever cookie /authorize set, exactly as a browser would.
      // With --enable transaction-binding this is the per-transaction binding
      // secret the later steps require; without it this is '' and the OP ignores
      // it, so the same flow works in both builds.
      const bindingCookie = (authorizeRes.headers.get('Set-Cookie') ?? '').split(';')[0] ?? '';
      const transactionId =
        new URL(loginPath, 'http://localhost').searchParams.get('transaction_id') ?? '';
      const loginGet = await app.request(loginPath, { headers: { Cookie: bindingCookie } });
      const loginRes = await app.request('/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded', Cookie: bindingCookie },
        body: new URLSearchParams({
          transaction_id: transactionId,
          csrf_token: csrfTokenFrom(await loginGet.text()),
          username: 'testuser',
          password: 'password',
        }).toString(),
      });
      const consentPath = relativeLocation(loginRes.headers.get('Location'));
      const consentGet = await app.request(consentPath, { headers: { Cookie: bindingCookie } });
      const consentRes = await app.request('/consent', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded', Cookie: bindingCookie },
        body: new URLSearchParams({
          transaction_id: transactionId,
          csrf_token: csrfTokenFrom(await consentGet.text()),
          action: 'approve',
        }).toString(),
      });
      const callback = new URL(consentRes.headers.get('Location') ?? '', 'http://localhost');
      const tokenRes = await app.request('/token', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({
          grant_type: 'authorization_code',
          code: callback.searchParams.get('code') ?? '',
          redirect_uri: REDIRECT_URI,
          code_verifier: verifier,
          client_id: 'c-public',
          // A valueless form field (client_secret=) carries no credential.
          client_secret: '',
        }).toString(),
      });

      expect(consentRes.status).toBe(302);
      expect(tokenRes.status).toBe(200);
      const tokenBody = await tokenRes.json();
      expect(tokenBody.token_type).toBe('Bearer');
      expect(tokenBody.scope).toBe('openid');
      expect((tokenBody.access_token as string).split('.')).toHaveLength(3);
      expect((tokenBody.id_token as string).split('.')).toHaveLength(3);
    });

    // RFC 6749 §2.3 / §3.2: an empty client_secret field carries no credential,
    // so it is not a second authentication method next to Authorization: Basic.
    it('should authenticate a client_secret_basic request that also sends an empty client_secret field', async () => {
      const verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
      const authorizeRes = await app.request(
        '/authorize?response_type=code&client_id=c-conf-basic' +
        '&redirect_uri=' + encodeURIComponent(REDIRECT_URI) +
        '&scope=openid&state=basic-empty-secret' +
        '&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256',
      );
      const loginPath = relativeLocation(authorizeRes.headers.get('Location'));
      // Carry forward whatever cookie /authorize set, exactly as a browser would.
      // With --enable transaction-binding this is the per-transaction binding
      // secret the later steps require; without it this is '' and the OP ignores
      // it, so the same flow works in both builds.
      const bindingCookie = (authorizeRes.headers.get('Set-Cookie') ?? '').split(';')[0] ?? '';
      const transactionId =
        new URL(loginPath, 'http://localhost').searchParams.get('transaction_id') ?? '';
      const loginGet = await app.request(loginPath, { headers: { Cookie: bindingCookie } });
      const loginRes = await app.request('/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded', Cookie: bindingCookie },
        body: new URLSearchParams({
          transaction_id: transactionId,
          csrf_token: csrfTokenFrom(await loginGet.text()),
          username: 'testuser',
          password: 'password',
        }).toString(),
      });
      const consentPath = relativeLocation(loginRes.headers.get('Location'));
      const consentGet = await app.request(consentPath, { headers: { Cookie: bindingCookie } });
      const consentRes = await app.request('/consent', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded', Cookie: bindingCookie },
        body: new URLSearchParams({
          transaction_id: transactionId,
          csrf_token: csrfTokenFrom(await consentGet.text()),
          action: 'approve',
        }).toString(),
      });
      const callback = new URL(consentRes.headers.get('Location') ?? '', 'http://localhost');
      const tokenRes = await app.request('/token', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          Authorization: 'Basic ' + btoa('c-conf-basic:s'),
        },
        body: new URLSearchParams({
          grant_type: 'authorization_code',
          code: callback.searchParams.get('code') ?? '',
          redirect_uri: REDIRECT_URI,
          code_verifier: verifier,
          client_id: 'c-conf-basic',
          // A valueless form field left behind by the client's HTTP stack.
          client_secret: '',
        }).toString(),
      });

      expect(consentRes.status).toBe(302);
      expect(tokenRes.status).toBe(200);
      const tokenBody = await tokenRes.json();
      expect(tokenBody.token_type).toBe('Bearer');
      expect(tokenBody.scope).toBe('openid');
      expect((tokenBody.access_token as string).split('.')).toHaveLength(3);
      expect((tokenBody.id_token as string).split('.')).toHaveLength(3);
    });

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

3 ケース目だけフローを省いているのは、生成 OP の token ルートがクライアント認証（ステップ 1〜4）を認可コードの解決より前に実行するためである。
存在しない code を渡しても、認証失敗が先に 401 を返すので、拒否理由（`Client authentication required`）を最短で固定できる。

テストクライアントは既存のフィクスチャを使う。
`c-public` は `token_endpoint_auth_method: none`、`c-conf-basic` は secret `s` を持つ client_secret_basic 登録である。

## 動作確認

- `pnpm --filter @maronn-openid-connect/core test`：1179 件パス（新規 4 件。実装前はそのうち 3 件が失敗することを確認済み）
- `pnpm --filter @maronn-openid-connect/cli test`：1414 件パス
- `pnpm --filter ./samples/hono-cloudflare test:conformance`：318 件パス（新規 3 件）
- `pnpm run typecheck` / `pnpm run build` / `pnpm run test:ci`（ci-gate、supply-chain、release-contract、packages テスト、conformance を含む）パス
- 4 sample を再生成し、差分が追加契約テストとメタデータの cliVersion 更新だけであることを確認済み

express / fastify / nextjs の契約テストは、main にテストランナーが未配線のため実行していない（配線は別 PR でレビュー中）。
生成されるテストコード自体は 4 フレームワークで同一の共有ブロックである。
