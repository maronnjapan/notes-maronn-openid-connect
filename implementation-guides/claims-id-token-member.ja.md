# `claims` パラメータ `id_token` メンバーを ID Token に反映する実装解説

対象は `@maronn-openid-connect/core` のトークンレスポンス生成と、CLI が生成する token エンドポイントおよび契約テストである。
OSS リポジトリのタスク `tasks/done/p2-claims-id-token-member-individual-claims.md` から実装した。

## この機能は何をするのか

OpenID Provider は、認可リクエストの `claims` パラメータ（OIDC Core 1.0 §5.5）で、クレーム単位の返却要求を受け取れる。
このパラメータはトップレベルに `userinfo` と `id_token` の 2 メンバーを持ち、`userinfo` は UserInfo エンドポイントへ、`id_token` は ID Token へ、列挙した個別クレームを返すことの要求と定義されている。

本ライブラリは `userinfo` メンバーを実装済みで、`claims={"userinfo":{"name":{"essential":true}}}` のような要求は scope と独立に UserInfo レスポンスへ反映される。
一方 `id_token` メンバーは `acr` の要求（§5.5.1.1 の `claims.id_token.acr.values` を acr resolver への種として渡す経路）にしか使われておらず、`email` や `name` を `id_token` メンバーで要求しても ID Token には載らなかった。
discovery は `claims_parameter_supported: true` を広告しているため、広告と実挙動が一部食い違った状態だった。

この変更により、次のリクエストは scope に `email` が無くても、ID Token に `email` クレームを含むようになる。

```
GET /authorize?response_type=code&scope=openid
  &claims=%7B%22id_token%22%3A%7B%22email%22%3Anull%7D%7D&...
```

## ユースケース

`claims.id_token` メンバーの典型的な用途は、UserInfo への追加リクエストを省くことである。
RP がログイン直後の表示にメールアドレスだけ必要な場合、`id_token` メンバーで要求すれば、トークンレスポンスの ID Token を検証するだけで値が手に入る。

もう一つは他 IdP からの移行検証である。
本ライブラリのコンセプトは「自分の要件がこの仕様で実現できるかを素早く検証する」ことにあり、`claims` パラメータを使う既存クライアントをそのまま接続して試せることが重要になる。
`userinfo` メンバーだけ効いて `id_token` メンバーが効かない状態は、この検証でつまずきやすいポイントだった。

## 設計判断

### 許可リスト方式で反映するクレームを限定する

反映対象は `SCOPE_CLAIMS_MAP`（§5.4 の profile / email / address / phone 各 scope に対応する標準クレーム）の値域に限定した。
この集合には `iss` / `sub` / `aud` / `exp` / `iat` / `at_hash` / `nonce` / `auth_time` / `acr` / `amr` / `azp` のいずれも含まれないため、`claims` パラメータ経由で ID Token の確定済みクレームを上書き・注入する経路は存在しない。

`sub` を除外したのは、`sub` の値要求がトークン発行先のバインディングというセキュリティ上の意味を持つためである（`study-material/claims-sub-value-request-binding.md` で別トピックとして扱う）。
`acr` を除外したのは、既存の resolver 種経路（`resolveAcrAmr` が `claims.id_token.acr.values` を要求値として使う）が担っており、二重処理を避けるためである。

保護は二重にした。
許可リストがプロトコルクレームを通さないことに加えて、`buildIdTokenPayload` の代入順序（ユーザークレームを先に置き、プロトコルクレームを後から代入する）が最終値を確定する。
どちらか一方の実装が壊れても、もう一方が注入を防ぐ。

### 不一致・未充足はエラーにせず省略する

§5.5.1 の `value` / `values` 制約は、UserInfo 側と同じ深い等価（`matchesRequestedValue`）で判定する。
実値が制約と一致しない場合、および `essential: true` のクレームをユーザーが持たない場合は、そのクレームを省略するだけでエラーにしない。
§5.5.1 が「essential クレームを返せなくてもエラーを返してはならない（MUST NOT）」と定めるためである。

### 生成 OP は要求があるときだけユーザークレームを引く

CLI 生成 OP の token エンドポイントは、これまでユーザークレームを一切読まなかった（scope 由来のクレームは §5.4 のとおり UserInfo が返す）。
今回の反映のために毎回 `userClaimsResolver` を呼ぶと、`claims` パラメータを使わない大多数のリクエストにストア照会が 1 回増える。
そこで、authorization_code グラントかつ `claims.id_token` が非空のときだけ resolver を呼ぶ形にした。
refresh_token グラントは `claims` コンテキストを保存していないため対象外である（保存の是非は `study-material/refresh-grant-claims-context-not-preserved.md` の別トピック）。

また、この反映で scope 由来のクレームが ID Token に混ざらないことを契約テストで固定した。
core の `buildIdTokenPayload` は `userClaims` を渡すと scope フィルタ結果も載せる設計だが、生成 OP は `buildIdTokenPayload` に `userClaims` を渡さず、組み立て済み payload へ `pickIdTokenRequestedClaims` の結果だけを重ねる。
許可リストが保証するとおり、この後置きの `Object.assign` が確定済みクレームを壊すことはない。

### テンプレートの変更は 1 箇所で全フレームワークに効く

CLI の web-standard フレームワーク（express / fastify / nextjs の生成元）は、hono の route テンプレートを変換して使う。
そのため token エンドポイントの変更は hono テンプレート 1 箇所で 4 フレームワークすべてに展開される。
契約テストも共有の conformance ブロックとして追加し、両テンプレートの合成箇所へ差し込んだ。

### semver

core / cli とも minor とした。
core は公開 API の追加（`pickIdTokenRequestedClaims` / `ID_TOKEN_REQUESTABLE_CLAIMS` / `matchesRequestedValue` の export と `IdTokenPayloadInput.claims`）であり、`claims` を渡していた既存呼び出しは ID Token の内容が変わりうる。
cli は生成 OP の挙動追加である。
core の minor に伴い、リリース契約（`RELEASE.md`）に従って experimental の core peer range 下限を `>=0.3.0` へ上げた。

## core の変更コード

### packages/core/src/token-response.ts：許可リストと反映関数

`buildIdTokenPayload` の直前に、許可リスト定数と反映関数を追加した。

```typescript
/**
 * `claims.id_token` メンバーで要求できる標準クレームの許可リスト。
 *
 * OIDC Core 1.0 §5.4 の scope 対応クレーム（profile / email / address / phone）に限定する。
 * `sub`・`acr`・プロトコルクレーム（iss / aud / exp / iat / at_hash / nonce / auth_time /
 * amr / azp）はこの集合に含まれないため、`claims` パラメータ経由で ID Token の
 * 確定済みクレームを上書き・注入することはできない。
 * - `sub` の値要求はトークン発行先のバインディングというセキュリティ上の意味を持つため
 *   別トピックとして扱い、ここでは反映しない
 * - `acr` は {@link resolveAcrAmr} の seed 経路（§5.5.1.1）が担うため二重処理しない
 */
export const ID_TOKEN_REQUESTABLE_CLAIMS: ReadonlySet<string> = new Set(
  Object.values(SCOPE_CLAIMS_MAP).flat(),
);

/**
 * ステップ: `claims.id_token` メンバー（OIDC Core 1.0 §5.5）で個別要求された
 * 標準クレームを、ID Token に載せる形で取り出す。
 *
 * §5.5: 「id_token — Requests that the listed individual Claims be returned in
 * the ID Token.」に対応する。granted scope とは独立に、要求されたクレームだけを返す。
 *
 * - {@link ID_TOKEN_REQUESTABLE_CLAIMS} にある標準クレームのみ対象（許可リスト方式）
 * - ユーザーが値を持たないクレームは省略する。§5.5.1: essential クレームを返せない
 *   場合でもエラーにしてはならない（MUST NOT）
 * - `value` / `values` 制約は実値との深い等価で判定し、不一致なら省略する
 *   （UserInfo 側の {@link matchesRequestedValue} と同一規則）
 *
 * 戻り値に `sub` やプロトコルクレームが含まれることはないため、組み立て済みの
 * ID Token payload へ `Object.assign` で重ねても確定済みクレームは壊れない。
 */
export function pickIdTokenRequestedClaims(
  userClaims: UserClaims,
  claims?: ClaimsParameter,
): Partial<UserClaims> {
  const result: Record<string, unknown> = {};
  if (!claims?.id_token) {
    return result as Partial<UserClaims>;
  }

  for (const [claimName, entry] of Object.entries(claims.id_token)) {
    if (!ID_TOKEN_REQUESTABLE_CLAIMS.has(claimName)) continue;
    const value = (userClaims as unknown as Record<string, unknown>)[claimName];
    if (value === undefined || value === null) continue;
    if (!matchesRequestedValue(value, entry)) continue;
    result[claimName] = value;
  }

  return result as Partial<UserClaims>;
}
```

import には `matchesRequestedValue` と `SCOPE_CLAIMS_MAP` を追加している。

```typescript
import { filterClaimsByScope, matchesRequestedValue, SCOPE_CLAIMS_MAP } from './userinfo.js';
```

### packages/core/src/token-response.ts：buildIdTokenPayload の入力と組み立て

`IdTokenPayloadInput` に `claims` を追加した。

```typescript
  /** クライアント自身以外に ID Token を受け取る audience */
  idTokenAudiences?: string[];
  /** scope に応じて含めるユーザクレーム */
  userClaims?: UserClaims;
  /**
   * OIDC Core 1.0 §5.5: Authorization Request の `claims` パラメータ。
   * `id_token` メンバーで個別要求された標準クレームを、scope と独立に ID Token へ
   * 反映する（{@link pickIdTokenRequestedClaims}）。userClaims が無い場合は反映しない。
   */
  claims?: ClaimsParameter;
```

組み立ては、scope フィルタの直後・プロトコルクレーム代入の前に反映を差し込んだ。

```typescript
  const payload: Record<string, unknown> = {};

  // OIDC Core 1.0 §5.4 / §12: scope に応じてユーザクレームを含める。
  // 必須クレーム (iss/sub/aud/exp/iat/at_hash etc.) は後続の代入で上書きされるため
  // ここではユーザクレーム由来の sub などによる spoof を防げる。
  if (userClaims) {
    Object.assign(payload, filterClaimsByScope(userClaims, scope));

    // OIDC Core 1.0 §5.5: claims.id_token で個別要求された標準クレームを scope と
    // 独立に反映する。許可リスト（ID_TOKEN_REQUESTABLE_CLAIMS）でプロトコルクレームは
    // 除外済みだが、後続のプロトコルクレーム代入が最終値を確定する二重防御とする。
    Object.assign(payload, pickIdTokenRequestedClaims(userClaims, claims));
  }
```

`generateTokenResponse` は受け取っていた `claims` オプションを `buildIdTokenPayload` へ渡すようになった。

```typescript
    const idTokenPayload = buildIdTokenPayload({
      issuer,
      subject,
      clientId,
      scope,
      expiresIn: idTokenExpiresIn,
      issuedAt: now,
      atHash,
      nonce,
      authTime,
      acr: resolvedAcr,
      amr: resolvedAmr,
      idTokenAudiences,
      userClaims,
      claims,
    });
```

`TokenResponseOptions.claims` の説明も実挙動に合わせて更新した。

```typescript
  /**
   * OIDC Core 1.0 §5.5: parsed `claims` request parameter from the authorization step.
   * `claims.id_token.acr.values` is fed into the acrResolver as requested acr_values
   * so the resolver can satisfy the requested values where possible. Standard claims
   * requested via the `id_token` member (e.g. `{"id_token":{"email":null}}`) are
   * reflected into the ID Token independently of scope when `userClaims` is provided
   * ({@link pickIdTokenRequestedClaims}). Other id_token claim members are ignored.
   */
  claims?: ClaimsParameter;
```

### packages/core/src/userinfo.ts：matchesRequestedValue の export

UserInfo 側で使っていた値制約の判定関数を、ID Token 側から再利用するために export へ変えた。
実装は無変更である。

```typescript
export function matchesRequestedValue(
  actual: unknown,
  entry: ClaimRequestValue
): boolean {
  if (entry === null) return true; // 制約なし

  if (entry.value !== undefined) {
    return deepEqual(actual, entry.value);
  }

  if (Array.isArray(entry.values)) {
    return entry.values.some((candidate) => deepEqual(actual, candidate));
  }

  return true; // essential のみ等、値制約なし
}
```

### packages/core/src/index.ts：パッケージ公開面

```typescript
export {
  generateTokenResponse,
  buildAccessTokenAudience,
  buildIdTokenAudience,
  // トークンレスポンス生成のステップ関数（generateTokenResponse はこれらの合成）
  buildAccessTokenPayload,
  computeAtHash,
  resolveAcrAmr,
  buildIdTokenPayload,
  pickIdTokenRequestedClaims,
  ID_TOKEN_REQUESTABLE_CLAIMS,
} from './token-response.js';
```

```typescript
export {
  handleUserInfoRequest,
  generateUserInfoJwt,
  filterClaimsByScope,
  UserInfoError,
  UserInfoErrorCode,
  SCOPE_CLAIMS_MAP,
  // UserInfo リクエスト処理のステップ関数（handleUserInfoRequest はこれらの合成）
  resolveUserInfoAccessToken,
  validateUserInfoTokenExpiration,
  validateUserInfoScope,
  validateUserInfoAudience,
  resolveUserInfoClaims,
  applyRequestedClaims,
  matchesRequestedValue,
} from './userinfo.js';
```

## core のテストコード

### packages/core/src/token-response.test.ts：generateTokenResponse 経由の反映

```typescript
  // OIDC Core 1.0 §5.5: the id_token top-level member of the claims request
  // parameter requests that the listed individual Claims be returned in the
  // ID Token, independently of the granted scope (§5.4).
  describe('ID Token claims requested via claims.id_token member (OIDC Core §5.5)', () => {
    const userClaims = {
      sub: 'user-claims',
      name: 'Alice',
      email: 'alice@example.com',
      email_verified: true,
    };

    it('should include email claim requested via claims.id_token without email scope', async () => {
      const options = createValidOptions({
        scope: ['openid'],
        userClaims,
        claims: { id_token: { email: null } },
      });
      const { response } = await generateTokenResponse(options);
      const { payload } = decodeJwt(response.id_token!);
      expect(payload.email).toBe('alice@example.com');
    });

    it('should include both claims when name and email are requested', async () => {
      const options = createValidOptions({
        scope: ['openid'],
        userClaims,
        claims: { id_token: { name: null, email: null } },
      });
      const { response } = await generateTokenResponse(options);
      const { payload } = decodeJwt(response.id_token!);
      expect(payload.name).toBe('Alice');
      expect(payload.email).toBe('alice@example.com');
    });

    it('should include email claim when the requested value matches', async () => {
      const options = createValidOptions({
        scope: ['openid'],
        userClaims,
        claims: { id_token: { email: { value: 'alice@example.com' } } },
      });
      const { response } = await generateTokenResponse(options);
      const { payload } = decodeJwt(response.id_token!);
      expect(payload.email).toBe('alice@example.com');
    });

    it('should omit email claim when the requested value does not match', async () => {
      const options = createValidOptions({
        scope: ['openid'],
        userClaims,
        claims: { id_token: { email: { value: 'other@example.com' } } },
      });
      const { response } = await generateTokenResponse(options);
      const { payload } = decodeJwt(response.id_token!);
      // OIDC Core 1.0 §5.5.1: a non-matching value request is omitted, not an error.
      expect(payload.email).toBeUndefined();
    });

    it('should omit missing essential claim without raising an error', async () => {
      const options = createValidOptions({
        scope: ['openid'],
        userClaims: { sub: 'user-claims', name: 'Alice' },
        claims: { id_token: { email: { essential: true } } },
      });
      // OIDC Core 1.0 §5.5.1: unfulfilled essential claims MUST NOT cause an error.
      const { response } = await generateTokenResponse(options);
      const { payload } = decodeJwt(response.id_token!);
      expect(payload.email).toBeUndefined();
    });

    it('should not let claims.id_token override the iss protocol claim', async () => {
      const options = createValidOptions({
        scope: ['openid'],
        userClaims: { ...userClaims, iss: 'https://evil.example.com' } as never,
        claims: { id_token: { iss: { value: 'https://evil.example.com' } } },
      });
      const { response } = await generateTokenResponse(options);
      const { payload } = decodeJwt(response.id_token!);
      expect(payload.iss).toBe('https://op.example.com');
    });

    it('should not reflect sub value requests via claims.id_token', async () => {
      const options = createValidOptions({
        subject: 'user-real',
        scope: ['openid'],
        userClaims: { ...userClaims, sub: 'user-real' },
        claims: { id_token: { sub: { value: 'user-spoofed' } } },
      });
      const { response } = await generateTokenResponse(options);
      const { payload } = decodeJwt(response.id_token!);
      // sub binding requests are out of scope here (tracked separately);
      // the ID Token always carries the authenticated subject.
      expect(payload.sub).toBe('user-real');
    });

    it('should ignore unknown claims requested via claims.id_token', async () => {
      const options = createValidOptions({
        scope: ['openid'],
        userClaims: { ...userClaims, custom_claim: 'x' } as never,
        claims: { id_token: { custom_claim: null } },
      });
      const { response } = await generateTokenResponse(options);
      const { payload } = decodeJwt(response.id_token!);
      expect(payload.custom_claim).toBeUndefined();
    });

    it('should reflect requested claims and still feed acr.values to the resolver', async () => {
      const options = createValidOptions({
        scope: ['openid'],
        userClaims,
        claims: {
          id_token: {
            email: null,
            acr: { values: ['urn:example:loa:2'] },
          },
        },
        acrResolver: async ({ requestedAcrValues }) => ({
          acr: requestedAcrValues ?? 'unset',
          amr: ['pwd'],
        }),
      });
      const { response } = await generateTokenResponse(options);
      const { payload } = decodeJwt(response.id_token!);
      expect(payload.email).toBe('alice@example.com');
      // OIDC Core 1.0 §5.5.1.1: acr.values seeds the resolver's requested values.
      expect(payload.acr).toBe('urn:example:loa:2');
    });
  });
```

### packages/core/src/token-response.test.ts：pickIdTokenRequestedClaims の単体テスト

```typescript
describe('pickIdTokenRequestedClaims', () => {
  const userClaims = {
    sub: 'user-1',
    name: 'Alice',
    email: 'alice@example.com',
    address: { country: 'JP', locality: 'Tokyo' },
  };

  it('should return empty object when claims parameter is absent', () => {
    expect(pickIdTokenRequestedClaims(userClaims, undefined)).toEqual({});
  });

  it('should return empty object when id_token member is absent', () => {
    expect(
      pickIdTokenRequestedClaims(userClaims, { userinfo: { email: null } }),
    ).toEqual({});
  });

  it('should pick requested standard claims that exist on the user', () => {
    expect(
      pickIdTokenRequestedClaims(userClaims, {
        id_token: { email: null, name: null, phone_number: null },
      }),
    ).toEqual({ email: 'alice@example.com', name: 'Alice' });
  });

  it('should match object-typed claims by deep equality', () => {
    // OIDC Core 1.0 §5.5.1: value comparison of JSON values (address is an object).
    expect(
      pickIdTokenRequestedClaims(userClaims, {
        id_token: { address: { value: { country: 'JP', locality: 'Tokyo' } } },
      }),
    ).toEqual({ address: { country: 'JP', locality: 'Tokyo' } });
  });

  it('should exclude sub and protocol claims from the allowlist', () => {
    expect(
      pickIdTokenRequestedClaims(
        { ...userClaims, iss: 'https://evil.example.com' } as never,
        { id_token: { sub: { value: 'user-1' }, iss: null, aud: null, exp: null } },
      ),
    ).toEqual({});
  });

  it('should exclude acr so the resolver seed path stays the single acr source', () => {
    expect(
      pickIdTokenRequestedClaims({ ...userClaims, acr: 'urn:x' } as never, {
        id_token: { acr: { values: ['urn:x'] } },
      }),
    ).toEqual({});
  });
});
```

## CLI の変更コード

### packages/cli/src/frameworks/hono/templates.ts：token route への注入

生成される `routes/token.ts` の core import に `pickIdTokenRequestedClaims` を、resolver import に `userClaimsResolver` を追加した。

```typescript
  buildAccessTokenPayload,
  computeAtHash,
  resolveAcrAmr,
  buildIdTokenPayload,
  pickIdTokenRequestedClaims,
```

```typescript
import {
  tokenClientResolver as defaultTokenClientResolver,
  authorizationCodeResolver as defaultAuthorizationCodeResolver,
  userClaimsResolver as defaultUserClaimsResolver,
} from '../resolvers.js';
```

token エンドポイントの openid 分岐では、`buildIdTokenPayload` の呼び出し直後（`generateIdToken` で署名する前）に次のコードが入る。

```typescript
      // OIDC Core 1.0 §5.5: reflect standard claims requested via the claims
      // parameter's id_token member (e.g. {"id_token":{"email":null}}) into the
      // ID Token, independently of the granted scope. Only authorization_code
      // carries the claims context (a refresh grant does not persist it).
      // pickIdTokenRequestedClaims allowlists the §5.4 standard claims, so
      // protocol claims (iss/sub/aud/exp/...) can never be replaced through it.
      const idTokenClaimsRequest =
        validatedRequest.grantType === 'authorization_code' ? validatedRequest.claims : undefined;
      if (idTokenClaimsRequest?.id_token && Object.keys(idTokenClaimsRequest.id_token).length > 0) {
        const userClaimsResolver = c.get('userClaimsResolver') ?? defaultUserClaimsResolver;
        const idTokenUserClaims = await userClaimsResolver.findUserClaims(subject);
        if (idTokenUserClaims) {
          Object.assign(idTokenPayload, pickIdTokenRequestedClaims(idTokenUserClaims, idTokenClaimsRequest));
        }
      }
```

web-standard フレームワーク（express / fastify / nextjs）は hono の `tokenRouteTemplate` を変換して使うため、この変更はそのまま 4 フレームワークすべての生成物に展開される。

### packages/cli/src/frameworks/hono/templates.ts：契約テストの共有ブロック

生成される `conformance.test.ts` に、認可コードフロー一式（authorize → login → consent → token）を `claims` パラメータ付きで実行し、ID Token の payload を検証する describe を追加した。
ブロックは関数として定義し、hono と web-standard の両方の conformance テンプレートへ差し込んでいる。

```typescript
export function idTokenClaimsParameterConformanceBlock(): string {
  return `
  // OIDC Core 1.0 §5.5: the id_token top-level member of the claims request
  // parameter requests that the listed individual Claims be returned in the
  // ID Token, independently of the granted scope (§5.4).
  describe('claims parameter id_token member (OIDC Core §5.5)', () => {
    // RFC 7636 Appendix B example PKCE pair.
    const CLAIMS_IDT_PKCE_CHALLENGE = 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM';
    const CLAIMS_IDT_PKCE_VERIFIER = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';

    function claimsIdtRelative(location: string | null): string {
      const url = new URL(location ?? '', 'http://localhost');
      return url.pathname + url.search;
    }

    function claimsIdtCsrf(html: string): string {
      return html.match(/name="csrf_token" value="([^"]+)"/)?.[1] ?? '';
    }

    function claimsIdtDecodeJwtPayload(token: string): Record<string, unknown> {
      const segment = token.split('.')[1] ?? '';
      const base64 = segment.replace(/-/g, '+').replace(/_/g, '/');
      const padded = base64 + '='.repeat((4 - (base64.length % 4)) % 4);
      return JSON.parse(atob(padded)) as Record<string, unknown>;
    }

    // Drives authorize -> login -> consent with a claims request parameter and
    // exchanges the code, handing back the decoded ID Token payload. Pure data
    // collection: no assertions or branching here, the contract lives in the it()s.
    async function idTokenPayloadFor(
      scope: string,
      claims: Record<string, unknown>,
    ): Promise<Record<string, unknown>> {
      const authorizeRes = await app.request(
        '/authorize?response_type=code&client_id=c-conf' +
          '&redirect_uri=' + encodeURIComponent(REDIRECT_URI) +
          '&scope=' + encodeURIComponent(scope) +
          '&state=claims-idt&prompt=consent' +
          '&claims=' + encodeURIComponent(JSON.stringify(claims)) +
          '&code_challenge=' + CLAIMS_IDT_PKCE_CHALLENGE + '&code_challenge_method=S256',
      );
      const loginPath = claimsIdtRelative(authorizeRes.headers.get('Location'));
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
          csrf_token: claimsIdtCsrf(await loginGet.text()),
          username: 'testuser',
          password: 'password',
        }).toString(),
      });

      const consentPath = claimsIdtRelative(loginRes.headers.get('Location'));
      const consentGet = await app.request(consentPath, { headers: { Cookie: bindingCookie } });
      const consentRes = await app.request('/consent', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded', Cookie: bindingCookie },
        body: new URLSearchParams({
          transaction_id: transactionId,
          csrf_token: claimsIdtCsrf(await consentGet.text()),
          action: 'approve',
        }).toString(),
      });
      const code =
        new URL(consentRes.headers.get('Location') ?? '', 'http://localhost')
          .searchParams.get('code') ?? '';

      const tokenRes = await app.request('/token', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({
          grant_type: 'authorization_code',
          code,
          redirect_uri: REDIRECT_URI,
          client_id: 'c-conf',
          client_secret: 's',
          code_verifier: CLAIMS_IDT_PKCE_VERIFIER,
        }).toString(),
      });
      const body = (await tokenRes.json()) as Record<string, string>;
      return claimsIdtDecodeJwtPayload(body.id_token ?? '');
    }

    it('should include email claim in the ID Token when requested via the id_token member without email scope', async () => {
      const payload = await idTokenPayloadFor('openid', { id_token: { email: null } });

      expect(payload.email).toBe('test@example.com');
      expect(payload.sub).toBe('testuser');
    });

    it('should omit a value-constrained claim that does not match without failing the flow', async () => {
      // OIDC Core 1.0 §5.5.1: a non-matching value request is omitted, not an error.
      const payload = await idTokenPayloadFor('openid', {
        id_token: { email: { value: 'someone-else@example.com' } },
      });

      expect(payload.email).toBe(undefined);
      expect(payload.sub).toBe('testuser');
    });

    it('should keep protocol claims authoritative when listed in the id_token member', async () => {
      const payload = await idTokenPayloadFor('openid', {
        id_token: { iss: null, email: null },
      });

      expect(payload.iss).toBe('http://localhost:3000');
      expect(payload.email).toBe('test@example.com');
    });

    it('should not pull scope-derived claims into the ID Token beyond the requested ones', async () => {
      // OIDC Core 1.0 §5.4: with response_type=code, scope-derived claims are
      // returned from the UserInfo endpoint; only the claims.id_token requests
      // land in the ID Token.
      const payload = await idTokenPayloadFor('openid profile', {
        id_token: { email: null },
      });

      expect(payload.email).toBe('test@example.com');
      expect(payload.name).toBe(undefined);
    });
  });
`;
}
```

差し込み箇所は、hono / web-standard 両テンプレートの conformance 合成チェーンで、JARM ブロックと consent decision ブロックの間である。

```typescript
${jarmConformanceBlock(features)}${idTokenClaimsParameterConformanceBlock()}${consentDecisionConformanceBlock()}
```

web-standard 側は import を 1 行追加している。

```typescript
  idTokenClaimsParameterConformanceBlock,
  idTokenHintConformanceBlock,
```

## CLI のテストコード

### packages/cli/src/__tests__/hono-generator.test.ts

```typescript
  // OIDC Core 1.0 §5.5: standard claims requested via the claims parameter's
  // id_token member are reflected into the ID Token, independently of scope.
  describe('claims parameter id_token member reflection', () => {
    const files = generator.generate(options);
    const tokenRoute = files.find((f) => f.path === 'routes/token.ts')?.content ?? '';
    const conformance = files.find((f) => f.path === 'conformance.test.ts')?.content ?? '';

    it('should reflect claims.id_token requests through pickIdTokenRequestedClaims in the token route', () => {
      expect(tokenRoute.includes('pickIdTokenRequestedClaims,')).toBe(true);
      expect(
        tokenRoute.includes(
          'Object.assign(idTokenPayload, pickIdTokenRequestedClaims(idTokenUserClaims, idTokenClaimsRequest));',
        ),
      ).toBe(true);
      expect(tokenRoute.includes('userClaimsResolver as defaultUserClaimsResolver,')).toBe(true);
    });

    it('should generate the claims parameter id_token member conformance contract', () => {
      expect(conformance.includes("describe('claims parameter id_token member (OIDC Core §5.5)'")).toBe(true);
      expect(conformance.includes("it('should include email claim in the ID Token when requested via the id_token member without email scope'")).toBe(true);
      expect(conformance.includes("it('should omit a value-constrained claim that does not match without failing the flow'")).toBe(true);
      expect(conformance.includes("it('should keep protocol claims authoritative when listed in the id_token member'")).toBe(true);
      expect(conformance.includes("it('should not pull scope-derived claims into the ID Token beyond the requested ones'")).toBe(true);
    });
  });
```

### packages/cli/src/__tests__/web-framework-generators.test.ts

```typescript
// OIDC Core 1.0 §5.5: standard claims requested via the claims parameter's
// id_token member are reflected into the ID Token in every Web-standard framework.
describe('Web-standard generated claims.id_token member reflection', () => {
  const generatedProviders = [
    {
      framework: 'express',
      files: new ExpressGenerator().generate({ outputDir: './out', corePackageName: CORE_PKG }),
      tokenPath: 'routes/token.ts',
      conformancePath: 'conformance.test.ts',
    },
    {
      framework: 'fastify',
      files: new FastifyGenerator().generate({ outputDir: './out', corePackageName: CORE_PKG }),
      tokenPath: 'routes/token.ts',
      conformancePath: 'conformance.test.ts',
    },
    {
      framework: 'nextjs',
      files: new NextJsGenerator().generate({ outputDir: './out', corePackageName: CORE_PKG }),
      tokenPath: '_oidc-provider/routes/token.ts',
      conformancePath: '_oidc-provider/conformance.test.ts',
    },
  ];

  for (const { framework, files, tokenPath, conformancePath } of generatedProviders) {
    const tokenRoute = files.find((file) => file.path === tokenPath)?.content ?? '';
    const conformance = files.find((file) => file.path === conformancePath)?.content ?? '';

    it(`should reflect claims.id_token requests through pickIdTokenRequestedClaims for ${framework}`, () => {
      expect(tokenRoute.includes('pickIdTokenRequestedClaims,')).toBe(true);
      expect(
        tokenRoute.includes(
          'Object.assign(idTokenPayload, pickIdTokenRequestedClaims(idTokenUserClaims, idTokenClaimsRequest));',
        ),
      ).toBe(true);
      expect(tokenRoute.includes('userClaimsResolver as defaultUserClaimsResolver,')).toBe(true);
    });

    it(`should generate the claims parameter id_token member conformance contract for ${framework}`, () => {
      expect(conformance.includes("describe('claims parameter id_token member (OIDC Core §5.5)'")).toBe(true);
      expect(conformance.includes("it('should include email claim in the ID Token when requested via the id_token member without email scope'")).toBe(true);
    });
  }
});
```

## リリース関連の変更

changeset は core / cli とも minor で 1 ファイルにまとめた。

```markdown
---
"@maronn-openid-connect/core": minor
"@maronn-openid-connect/cli": minor
---

`claims` リクエストパラメータの `id_token` メンバーで要求された標準クレームを、scope と独立に ID Token へ反映する（OIDC Core 1.0 §5.5）。core は許可リスト方式の `pickIdTokenRequestedClaims` を追加し、`buildIdTokenPayload` / `generateTokenResponse` が `claims` を受け取って `email` などの §5.4 標準クレームを ID Token に載せる。許可リストは `SCOPE_CLAIMS_MAP` の値域に限定されるため、`iss` / `sub` / `aud` などのプロトコルクレームや `sub` の値要求はこの経路から注入できない。`value` / `values` 制約は UserInfo と同じ深い等価で判定し、不一致・値なし・essential 未充足はエラーにせず省略する（§5.5.1）。CLI 生成 OP の token エンドポイントは authorization_code グラントで `claims.id_token` があるときだけ userClaimsResolver を引いて反映する（全フレームワーク対象）。
```

core が minor になるため、リリース契約に従って experimental の peer range 下限を上げた（`packages/experimental/package.json`）。

```json
  "peerDependencies": {
    "@maronn-openid-connect/core": ">=0.3.0 <1.0.0"
  },
```

## 検証

次のコマンドがすべて成功することを確認した。

```bash
pnpm install
pnpm run build
pnpm run typecheck
pnpm --filter @maronn-openid-connect/core test          # 1183 件
pnpm --filter @maronn-openid-connect/cli test           # 1177 件
pnpm --filter ./samples/hono-cloudflare test:conformance # 300 件（新規 4 件を含む）
pnpm run test:release-contract
pnpm run test:e2e                                       # 4 sample すべて緑
```

express / fastify / nextjs の sample はテストランナー未接続のため（別タスク `tasks/p1-exec-conformance-test.md` の対象）、生成物の一致は generator テストと typecheck で確認している。
