# Request Object 検証失敗を `invalid_request_object` で返す実装解説

対象は `@maronn-openid-connect/core` の認可リクエスト検証と、CLI が生成する契約テストである。
OSS リポジトリのタスク `tasks/done/p2-authorization-error-invalid-request-object.md` から実装した。

## この機能は何をするのか

OpenID Provider は、認可リクエストの `request` パラメータで **Request Object**（認可リクエストのパラメータを claim として持つ JWT、OIDC Core 1.0 §6.1）を受け取れる。
本ライブラリは Request Object by value を実装済みだが、これまではそのパース・署名検証に失敗すると、汎用のエラーコード `invalid_request` を返していた。
この変更により、検証失敗は OIDC Core 1.0 §6.3 が定義する専用コード `invalid_request_object` で返るようになる。

§6.3 は Request Object に関するエラーコードを 4 つ定義している。

- **`invalid_request_uri`**：`request_uri` が到達不能、またはエラーや不正なデータを返した
- **`invalid_request_object`**：`request` パラメータが不正な Request Object を含む
- **`request_not_supported`**：OP が `request` パラメータ自体をサポートしない
- **`request_uri_not_supported`**：OP が `request_uri` パラメータをサポートしない

変更前の `AuthorizationErrorCode` enum には、このうち後ろの 2 つしか存在しなかった。
enum のコメントは §6.3 を明記していたので、前の 2 つの欠落は設計判断ではなく実装漏れと判断した。
実装にあたっては、OIDC Core 1.0 の Authentication Error Response のエラーコード表で 4 コードの定義文を確認している（`invalid_request_object`: "The request parameter contains an invalid Request Object."）。

## ユースケース

エラーコードの使い分けは、クライアント開発者の対処を分ける。
`request_not_supported` を受け取ったクライアントは Request Object の使用をやめるべきで、`invalid_request_object` を受け取ったクライアントは自分の Request Object 生成処理（署名鍵、`alg`、JWS の組み立て）を直すべきである。
対処が正反対なのに、変更前はどちらの状況でも同じ失敗レポート（後者は `invalid_request`）になりうるため、原因の切り分けをエラーレスポンスから始められなかった。

もう一つの動機は拡張パッケージとの接続である。
experimental の PAR 実装（RFC 9126）は `invalid_request_uri` を必要とするが、core の enum に存在しないため、独自のエラークラス `PushedRequestUriError` を定義して回避していた。
今回 `invalid_request_uri` も enum に追加したので、将来この回避策を core のエラー型へ統合できる（統合自体は別タスクとして残している）。
JAR（RFC 9101）を正式サポートする場合にも、この 2 コードは必須になる。

## 設計判断

変更は「enum に 2 値を追加し、変換先を 1 箇所差し替える」に絞った。

第一に、既存の enum メンバーとシリアライズ値は一切変えていない。
enum への値追加は後方互換であり、`invalid_request` を返す他の検証（必須パラメータ欠落など）はそのまま残る。

第二に、非リダイレクト挙動を維持した。
Request Object のパースは redirect_uri の解決より前に走るため、検証失敗の `AuthorizationError` は `redirectUri` / `state` を持たず、クライアントへのリダイレクトではなく OP 上のエラー表示になる。
壊れた Request Object の中にある redirect_uri は信頼できないので、この設計は変えるわけにはいかない。
今回の変更はエラーコードだけを差し替え、この挙動が変わっていないことをテストで固定した。

第三に、`invalid_request_object` を返すのは `RequestObjectError` の変換箇所 1 箇所だけである。
`parseRequestObject` が投げるすべての失敗（JWS の構造不正、JWE の受信、`alg` 欠落・未対応、`alg: "none"` の非許可受信、クライアント JWKS 未登録、`kid` 不一致、署名検証失敗）はこの 1 箇所を通るため、変換先の差し替えで全ケースが §6.3 準拠になる。
機能トグルで Request Object を無効化した構成が返す `request_not_supported` は別の関数が担っており、無変更である。

semver は core を minor、cli を patch とした。
core は enum 追加という機能追加に加えて、クライアントから見えるエラーコードが変わる。
`invalid_request` の受信を前提にしたクライアントに影響しうるため、changeset にその旨を記載した。
cli はテンプレートが出力する契約テストだけの変更なので patch である。

## core の変更コード

### packages/core/src/authorization-request.ts：エラーコードの enum

`AuthorizationErrorCode` に §6.3 の 2 値を追加した。
変更後の enum 全体は次のとおりである。

```typescript
/**
 * 認可エンドポイントのエラーコード
 * OAuth 2.1 Section 4.1.2.1 / OIDC Core 1.0 Section 3.1.2.6
 */
export enum AuthorizationErrorCode {
  // OAuth 2.1 Section 4.1.2.1
  InvalidRequest = 'invalid_request',
  UnauthorizedClient = 'unauthorized_client',
  AccessDenied = 'access_denied',
  UnsupportedResponseType = 'unsupported_response_type',
  InvalidScope = 'invalid_scope',
  ServerError = 'server_error',
  TemporarilyUnavailable = 'temporarily_unavailable',
  // OIDC Core 1.0 Section 3.1.2.6
  InteractionRequired = 'interaction_required',
  LoginRequired = 'login_required',
  AccountSelectionRequired = 'account_selection_required',
  ConsentRequired = 'consent_required',
  // OIDC Core 1.0 Section 6.3: returned when the request_uri is unreachable or
  // yields invalid data, or the request parameter carries an invalid Request Object.
  InvalidRequestUri = 'invalid_request_uri',
  InvalidRequestObject = 'invalid_request_object',
  // OIDC Core 1.0 Section 6.3: returned when the OP does not support the
  // request / request_uri parameters but the client used them.
  RequestNotSupported = 'request_not_supported',
  RequestUriNotSupported = 'request_uri_not_supported',
  // OIDC Core 1.0 §3.1.2.6: returned when the OP does not support the `registration`
  // parameter (Self-Issued OP RP metadata, §7.2.1) but the client used it.
  RegistrationNotSupported = 'registration_not_supported',
}
```

`InvalidRequestUri` は今回の変換経路では使われない。
それでも同時に追加したのは、§6.3 の 4 コードを enum として揃えることで、experimental PAR が持つ「core の enum に無いから独自エラー型を作る」という制約を外すためである。

### packages/core/src/authorization-request.ts：変換箇所

Request Object の解決を担うステップ関数 `resolveRequestObjectParams` が、`parseRequestObject` の投げる `RequestObjectError` を捕捉して `AuthorizationError` へ変換する。
この変換先を `InvalidRequest` から `InvalidRequestObject` に差し替えた。
変更後の関数全体は次のとおりである。

```typescript
/**
 * Request Object by value（OIDC Core 1.0 §6.1）を解決する（機能単位のステップ関数）。
 *
 * `request` パラメータが無い場合はクエリパラメータのコピーをそのまま返す。
 * ある場合は署名付き JWS Request Object をクライアント登録鍵（`ClientInfo.jwks`）で
 * 検証し、claim をクエリ値に supersede した有効パラメータ集合を返す。検証失敗
 * （壊れた JWT / 未対応 alg / 鍵不一致 / 署名不一致）は信頼できないため、
 * 内部の redirect_uri も信用せず非リダイレクトの invalid_request_object
 * （OIDC Core 1.0 §6.3）とする。
 *
 * `response_type` / `client_id` は OAuth 2.0 request syntax 側を正とするため
 * 上書きしない（後段の {@link validateRequestObjectConsistency} で一致検証する）。
 */
export async function resolveRequestObjectParams(
  params: AuthorizationRequestParams,
  client: ClientInfo,
  options: {
    /**
     * 受理する JWS 署名アルゴリズム。
     * 未指定なら {@link DEFAULT_REQUEST_OBJECT_SIGNING_ALGS}（`["RS256"]`）。
     */
    supportedSigningAlgs?: string[];
    /**
     * 署名無し（`alg: "none"`）Request Object を互換受理するか。既定 false（署名必須）。
     * OIDF Conformance Suite 互換の場合のみ true にする。
     */
    allowUnsigned?: boolean;
  } = {},
): Promise<ResolvedRequestObjectParams> {
  if (params.request === undefined) {
    return { effectiveParams: { ...params } };
  }

  let requestObjectClaims: Record<string, unknown>;
  try {
    requestObjectClaims = await parseRequestObject(params.request, {
      jwks: client.jwks,
      supportedSigningAlgs:
        options.supportedSigningAlgs ?? [
          ...DEFAULT_REQUEST_OBJECT_SIGNING_ALGS,
        ],
      allowUnsigned: options.allowUnsigned ?? false,
    });
  } catch (e) {
    if (e instanceof RequestObjectError) {
      // OIDC Core 1.0 §6.3: an invalid Request Object is reported as
      // invalid_request_object, distinguishing "fix your Request Object"
      // from request_not_supported ("stop using the request parameter").
      throw new AuthorizationError(
        AuthorizationErrorCode.InvalidRequestObject,
        e.message,
      );
    }
    throw e;
  }

  return {
    effectiveParams: mergeRequestObjectParams(params, requestObjectClaims),
    requestObjectClaims,
  };
}
```

### packages/core/src/request-object.ts：エラークラスの doc コメント

`RequestObjectError` 自体の挙動は変えていない。
「呼び出し側がどのコードへ変換するか」を述べる doc コメントだけを、新しい変換先に合わせて更新した。

```typescript
/**
 * Request Object のパース・署名検証に失敗したことを表すエラー。
 *
 * 呼び出し側（`validateAuthorizationRequest`）はこれを捕捉して
 * `invalid_request_object`（OIDC Core 1.0 §6.3）の `AuthorizationError` に変換する。
 */
export class RequestObjectError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'RequestObjectError';
  }
}
```

## core のテスト

TDD で進め、先にエラーコードの期待値を `InvalidRequestObject` に変えたテストを Red にしてから実装した。
`parseRequestObject` が `RequestObjectError` を投げる条件自体は変わっていないので、`request-object.test.ts` の既存 11 ケース（構造不正、JWE、`alg: "none"` の扱い、JWKS 未登録、`kid` 不一致、署名不一致など）は無変更で通っている。

### packages/core/src/authorization-request.test.ts

「Request Object by value」の describe にある失敗系テストを新しいコードへ更新し、JWKS 未登録のケースと非リダイレクト挙動を固定するケースを追加した。
変更・追加後のテストは次のとおりである。

```typescript
    // OIDC Core 1.0 §6.3: "invalid_request_object: The request parameter contains an
    // invalid Request Object." Parse/verification failures use this code, not the
    // generic invalid_request.
    it('should reject a request object whose signature does not verify with invalid_request_object', async () => {
      // Signed with a different key than the one published under kid.
      const request = await buildSignedRequestObject(
        {
          response_type: 'code',
          client_id: 'ro-client',
          redirect_uri: registeredRedirect,
          scope: 'openid',
        },
        otherKeyPair.privateKey,
        kid,
      );

      const error = await validateAuthorizationRequest(
        baseParams({ request }),
        resolver,
      ).catch((e: unknown) => e);

      expect(error).toBeInstanceOf(AuthorizationError);
      expect((error as AuthorizationError).error).toEqual(
        AuthorizationErrorCode.InvalidRequestObject,
      );
    });

    it('should reject a request object with an unknown kid with invalid_request_object', async () => {
      const request = await buildSignedRequestObject(
        {
          response_type: 'code',
          client_id: 'ro-client',
          redirect_uri: registeredRedirect,
          scope: 'openid',
        },
        rsaKeyPair.privateKey,
        'unknown-kid',
      );

      const error = await validateAuthorizationRequest(
        baseParams({ request }),
        resolver,
      ).catch((e: unknown) => e);

      expect(error).toBeInstanceOf(AuthorizationError);
      expect((error as AuthorizationError).error).toEqual(
        AuthorizationErrorCode.InvalidRequestObject,
      );
    });

    it('should reject a request object with an unsupported signing alg with invalid_request_object', async () => {
      const request = buildRequestObjectWithAlg('HS256', {
        response_type: 'code',
        client_id: 'ro-client',
        redirect_uri: registeredRedirect,
        scope: 'openid',
      });

      const error = await validateAuthorizationRequest(
        baseParams({ request }),
        resolver,
      ).catch((e: unknown) => e);

      expect(error).toBeInstanceOf(AuthorizationError);
      expect((error as AuthorizationError).error).toEqual(
        AuthorizationErrorCode.InvalidRequestObject,
      );
    });

    it('should reject a request object when no client JWKS is registered with invalid_request_object', async () => {
      const noJwksClient: ClientInfo = {
        clientId: 'ro-client-nokeys',
        redirectUris: [registeredRedirect],
      };
      const request = await buildSignedRequestObject(
        {
          response_type: 'code',
          client_id: 'ro-client-nokeys',
          redirect_uri: registeredRedirect,
          scope: 'openid',
        },
        rsaKeyPair.privateKey,
        kid,
      );

      const error = await validateAuthorizationRequest(
        baseParams({ client_id: 'ro-client-nokeys', request }),
        createClientResolver([noJwksClient]),
      ).catch((e: unknown) => e);

      expect(error).toBeInstanceOf(AuthorizationError);
      expect((error as AuthorizationError).error).toEqual(
        AuthorizationErrorCode.InvalidRequestObject,
      );
    });

    it('should throw without a redirect uri when the request object cannot be parsed', async () => {
      // A broken Request Object cannot be trusted, including any redirect_uri it may
      // carry, so the error must stay on the OP (non-redirectable, no state echo).
      const error = await validateAuthorizationRequest(
        baseParams({ request: 'not-a-jwt', state: 'st-broken' }),
        resolver,
      ).catch((e: unknown) => e);

      expect(error).toBeInstanceOf(AuthorizationError);
      const authError = error as AuthorizationError;
      expect(authError.error).toEqual(
        AuthorizationErrorCode.InvalidRequestObject,
      );
      expect(authError.redirectable).toBe(false);
      expect(authError.redirectUri).toBeUndefined();
      expect(authError.state).toBeUndefined();
    });
```

同じ describe の unsigned・構造不正・JWE のケースも、期待値を新しいコードへ更新した。

```typescript
    it('should reject an unsigned request object with invalid_request_object when allowUnsigned is false', async () => {
      const request = buildUnsignedRequestObject({
        response_type: 'code',
        client_id: 'ro-client',
        redirect_uri: registeredRedirect,
        scope: 'openid',
      });

      const error = await validateAuthorizationRequest(
        baseParams({ request }),
        resolver,
      ).catch((e: unknown) => e);

      expect(error).toBeInstanceOf(AuthorizationError);
      expect((error as AuthorizationError).error).toEqual(
        AuthorizationErrorCode.InvalidRequestObject,
      );
    });

    it('should reject a request object with a broken JWS structure with invalid_request_object', async () => {
      const error = await validateAuthorizationRequest(
        baseParams({ request: 'not-a-jwt' }),
        resolver,
      ).catch((e: unknown) => e);

      expect(error).toBeInstanceOf(AuthorizationError);
      expect((error as AuthorizationError).error).toEqual(
        AuthorizationErrorCode.InvalidRequestObject,
      );
    });

    it('should reject a JWE (5-segment) request object with invalid_request_object', async () => {
      const error = await validateAuthorizationRequest(
        baseParams({ request: 'a.b.c.d.e' }),
        resolver,
      ).catch((e: unknown) => e);

      expect(error).toBeInstanceOf(AuthorizationError);
      expect((error as AuthorizationError).error).toEqual(
        AuthorizationErrorCode.InvalidRequestObject,
      );
    });
```

state を echo しない不変条件の describe にも、Request Object 失敗のケースがある。
期待するエラーコードだけを更新した。

```typescript
    it('should not echo state when the Request Object fails to parse', async () => {
      const error = await validateAuthorizationRequest(
        validParams({ request: 'not.a.valid.jws', state: STATE }),
        createClientResolver([defaultClient]),
      ).catch((e: unknown) => e);

      const authError = error as AuthorizationError;
      expect(authError.error).toBe(AuthorizationErrorCode.InvalidRequestObject);
      expect(authError.redirectable).toBe(false);
      expect(authError.state).toBeUndefined();
    });
```

機能トグル無効時に `request_not_supported` を返す既存テストは無変更で通っており、`invalid_request_object` との使い分けが変わっていないことを担保している。

### packages/core/src/authorization-request-steps.test.ts

ステップ関数 `resolveRequestObjectParams` を直接呼ぶテストも、期待値を更新した。

```typescript
  it('should reject a broken request JWT with a non-redirectable invalid_request_object', async () => {
    const error = await resolveRequestObjectParams(
      validParams({ request: 'not-a-jwt' }),
      defaultClient,
      { allowUnsigned: true }
    ).catch((e: unknown) => e);

    expect(error).toBeInstanceOf(AuthorizationError);
    const authError = error as AuthorizationError;
    expect(authError.error).toBe(AuthorizationErrorCode.InvalidRequestObject);
    expect(authError.redirectable).toBe(false);
  });

  it('should reject an unsigned request object when allowUnsigned is not enabled', async () => {
    const request = buildUnsignedRequestObject({
      response_type: 'code',
      client_id: 'client123',
    });

    const error = await resolveRequestObjectParams(
      validParams({ request }),
      defaultClient
    ).catch((e: unknown) => e);

    expect(error).toBeInstanceOf(AuthorizationError);
    const authError = error as AuthorizationError;
    expect(authError.error).toBe(AuthorizationErrorCode.InvalidRequestObject);
    expect(authError.redirectable).toBe(false);
  });
```

## CLI 生成コードへの寄与

生成 OP のリクエスト処理の観測結果（エラーコード）が変わるので、リポジトリの規約に従い、生成される契約テスト `conformance.test.ts` も同じ変更で更新した。
テンプレートは `packages/cli/src/frameworks/hono/templates.ts` の `requestObjectValueConformanceBlock` で、hono と web-standard（express / fastify / nextjs）の両テンプレートが共有している。
そのため 1 箇所の追加が 4 フレームワークすべての生成物に入る。

### 生成される conformance.test.ts に追加されるテスト

「Request Object by value (OIDC Core 1.0 §6.1)」の describe に、次のテストが追加される。
壊れた Request Object に対して、OP がリダイレクトせずに `invalid_request_object` のエラーページを表示することを、デフォルトのエラーページ HTML との完全一致で固定する。

```typescript
    it('should reject a broken request object with a non-redirect invalid_request_object error page', async () => {
      const url =
        '/authorize?response_type=code&client_id=c-conf' +
        '&redirect_uri=' + encodeURIComponent(REDIRECT_URI) +
        '&scope=openid&state=req-broken' +
        '&request=not-a-jwt' +
        '&code_challenge=' + PKCE_CHALLENGE_S256 + '&code_challenge_method=S256';
      const res = await app.request(url);

      // OIDC Core 1.0 §6.3: the request parameter contains an invalid Request
      // Object, so the OP reports invalid_request_object (not the generic
      // invalid_request). A redirect_uri carried inside a broken Request Object
      // cannot be trusted, so the error stays on the OP: HTTP 400, no redirect,
      // no state echo. Pinned to the default error page so a change in either
      // the error code or the non-redirect behavior is caught exactly.
      expect(res.status).toBe(400);
      expect(res.headers.get('Location')).toBe(null);
      expect(res.headers.get('Content-Type')).toBe('text/html; charset=UTF-8');
      const body = await res.text();
      expect(body).toBe(
        [
          '<!DOCTYPE html>',
          '<html>',
          '<head><title>Error</title></head>',
          '<body>',
          '  <h1>Error</h1>',
          '  <p>invalid_request_object</p>',
          '  <p>request object is not a JWS compact serialization</p>',
          '</body>',
          '</html>',
        ].join('\n'),
      );
    });
```

4 sample（hono-cloudflare / express-flyio / fastify-flyio / nextjs-vercel）を CLI で再生成し、生成物の差分がこのテストの追加だけであることを確認した。
生成 OP のルート実装そのものは無変更である。
authorize ルートは `AuthorizationError` の `error` プロパティをそのまま表示・リダイレクトに使うため、core の変換先の差し替えだけで生成 OP の応答が変わる。

## 検証

次をすべて確認した。

- core のテスト 1170 件、cli 868 件、experimental 314 件がすべて通る
- hono-cloudflare の契約テスト 210 件が通る（追加したテストを含む）
- 4 フレームワークの E2E（35 + 16 + 16 + 16 件）が通る
- typecheck、CI ゲート、supply-chain、release contract の各検証が通る

changeset は core を minor、cli を patch で追加し、`invalid_request` の受信を前提にしたクライアントへの影響を記載した。
