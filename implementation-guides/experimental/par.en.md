# PAR (Pushed Authorization Requests): Implementation Guide

This document explains what was implemented for **Pushed Authorization Requests** (RFC 9126, "PAR" below) in `packages/experimental`, and how, together with the complete source code involved.
The goal is that after reading it, you can account for why every line of the implementation looks the way it does.

The following code is embedded in full:

- all four implementation files and both test files under `packages/experimental/src/par/`
- the complete code that `--enable par` adds to the CLI-generated output (hono)
- the complete PAR E2E test spec

The core package itself, the shared E2E harness, and the other frameworks' generated code are infrastructure shared by all features, so they are linked rather than embedded.
The embedded sources carry Japanese comments; the prose here conveys the same information.

## What the feature does

In a plain Authorization Code Flow, the client sends every authorization request parameter (`client_id`, `redirect_uri`, `scope`, `state`, `code_challenge`, and so on) to the authorization endpoint on the browser's redirect URL.
That path is the front channel, and because the parameters travel through the user's hands, it has structural weaknesses:

- parameters end up in browser history, proxy logs, and Referer headers as part of a URL;
- the user (or an intermediary) can rewrite parameters before they reach the authorization endpoint;
- the request's legitimacy cannot be backed by client authentication, because the authorization endpoint does not authenticate clients.

PAR resolves these weaknesses by pulling the body of the authorization request off the front channel.
The client first POSTs the full parameter set to the OP's PAR endpoint over the back channel, gets authenticated as a client, and receives a short-lived reference called a **request_uri** (in the form `urn:ietf:params:oauth:request_uri:...`).
The browser-borne authorization request then carries only `client_id` and `request_uri`, and the authorization endpoint expands the reference back into the stored parameters and proceeds as usual.
The parameter payload never leaves the client–OP channel, so it can be neither tampered with nor leaked.

```text
Client                                     OP
    │  POST /par (client-authenticated)      │
    │  scope, redirect_uri, code_challenge…  │
    │ ─────────────────────────────────────> │ validate & store
    │  201 { request_uri, expires_in }       │
    │ <───────────────────────────────────── │
    │                                        │
    │  (redirect the browser)                │
    │  GET /authorize?client_id=…&request_uri=…  (via browser)
    │ ─────────────────────────────────────> │ expand request_uri, then
    │                                        │ process as a normal request
```

### Use cases

- Groundwork for high-security profiles such as FAPI 2.0, whose Security Profile mandates PAR, verified in a PoC before committing to a full implementation
- Confirming that authorization-request integrity and confidentiality requirements hold for your client configuration
- Verifying a "reject anything that did not come through PAR" deployment via `require_pushed_authorization_requests` (RFC 9126 §5)
- Evaluating PAR as an escape hatch when large authorization requests (many scopes or claims) hit URL length limits

### Scope and non-goals

The implementation covers the core of RFC 9126:

- the PAR endpoint processing (request validation per §2.1, the success response per §2.2, error responses per §2.3)
- `request_uri` expansion on the authorization endpoint side (§4) with enforced single use (§7.3)
- the `require_pushed_authorization_requests` guard (§5)
- a configurable `request_uri` lifetime, validated at startup against the §2.2 recommended range (5–600 seconds)

Two things are deliberately out of scope.
URL-form `request_uri` values (OIDC Core §6.2) are neither issued nor accepted; only the URN form is supported, and core keeps rejecting the URL form with `request_uri_not_supported`.
Combining PAR with Request Objects (JAR) is also out of scope; a `request` parameter in the PAR body is rejected with `invalid_request`.

## Design approach

Before reading the code, here is the file layout and the decisions that run through all of it.

| File | Role |
|---|---|
| `store.ts` | store contract and the URN prefix |
| `par-request.ts` | PAR endpoint processing (step functions and the composition function) |
| `resolve-request-uri.ts` | `request_uri` expansion on the authorization endpoint side |
| `index.ts` | public API re-exports |

There are four load-bearing decisions.

First, processing is split into **step functions** (one per unit of spec validation) and a **composition function** that only calls them in spec order.
The CLI emits generated code that calls the step functions one by one, so users can experiment with removing or replacing a validation directly in their generated code.

Second, core stays untouched.
Core's `AuthorizationErrorCode` is a closed enum that lacks RFC 9126's `invalid_request_uri`, so the feature defines `ParError` for the PAR endpoint and `PushedRequestUriError` for the authorization endpoint, and maps core's errors onto them.

Third, `request_uri` resolution failures leak nothing.
Whether a value is unknown, already used, expired, or bound to another client, the response uses the same error code and the same message.
This avoids creating an oracle that would let a caller learn whether a given `request_uri` ever existed.

Fourth, client credentials never reach the store.
A PAR body is unusual in that client authentication material and authorization request parameters share one form, so `client_secret` and friends are stripped before the record is saved.
Left in place, the secret would leak into persistence, logs, and the parameters expanded at the authorization endpoint.

## The implementation, file by file

### store.ts (the store contract)

The store contract is the right place to start.
`PushedAuthorizationRecord` is the unit of storage: the full parameter set (with `client_id` normalized to the authenticated client), the owning client, and the expiry.

The contract's defining trait is that it offers no `get`.
By excluding read-only access and providing only `consume`, which fetches and deletes in one step, single use (RFC 9126 §7.3) is enforced at the type level.
A non-atomic `consume` would allow the same `request_uri` to be used concurrently (a replay), so atomicity is stated as a contract requirement in the comments.

```typescript
/**
 * Pushed Authorization Requests (PAR) — RFC 9126
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * ストア契約と、request_uri の URN 形式に関する定義。
 */

/**
 * RFC 9126 §2.2: 認可サーバーが返す `request_uri` の推奨形式。
 * 本実装はこの URN 形式のみを発行・受理する（URL 形式は非対応）。
 */
export const PAR_REQUEST_URI_PREFIX = 'urn:ietf:params:oauth:request_uri:';

/**
 * PAR エンドポイントが受け付けたリクエストの保存レコード。
 *
 * `params` は PAR エンドポイントが受領した認可リクエストパラメータをそのまま保持する
 * （`client_id` は認証済みクライアントの値に正規化済み）。認可エンドポイントは
 * このパラメータを展開して通常の認可リクエストとして処理する（RFC 9126 §4）。
 */
export interface PushedAuthorizationRecord {
  /** `urn:ietf:params:oauth:request_uri:<reference-value>` */
  requestUri: string;
  /** PAR エンドポイントで認証・解決されたクライアントID（RFC 9126 §2.2 の紐付け MUST） */
  clientId: string;
  /** 受領した認可リクエストパラメータ */
  params: Record<string, string>;
  createdAt: Date;
  expiresAt: Date;
}

/**
 * 利用者が実装するストア契約。
 *
 * `get` を提供しないのは意図的で、「読むだけ」の操作を契約から排除して
 * 単回使用（RFC 9126 §7.3）を型レベルで強制するため。
 */
export interface PushedAuthorizationRequestStore {
  /** レコードを保存する。同じ requestUri で二度呼ばれることは想定しない。 */
  save(record: PushedAuthorizationRecord): Promise<void>;
  /**
   * 取得と同時に削除する（単回使用。RFC 9126 §7.3 の SHOULD を本実装では必須運用にする）。
   * 存在しない場合は null を返す。
   *
   * requestUri は不透明なキーとして扱うこと。URN 前置詞の一致は呼び出し側で検証済みだが、
   * 値そのものは外部入力（認可エンドポイントのクエリ）由来である。永続ストア実装では
   * キーをクエリ文字列へ埋め込まず、必ずパラメータ化した問い合わせを使うこと。
   *
   * 取得と削除は atomic でなければならない。atomic でない実装は同一 request_uri の
   * 並行使用（リプレイ）を許してしまう。
   */
  consume(requestUri: string): Promise<PushedAuthorizationRecord | null>;
}
```

### par-request.ts (the PAR endpoint)

This is the endpoint's core: the error type, five step functions, the composition function, and the core-error mapping, in that order.

`ParError` implements RFC 9126 §2.3, which reuses the token endpoint's error format.
It deliberately carries no redirect target, because the PAR endpoint is back-channel-only and never redirects.
`statusCode` is 401 only for failed client authentication (`invalid_client`) and 400 otherwise, and only the 401 case returns a `WWW-Authenticate: Basic` challenge, matching the token endpoint's behavior.

The step functions follow the spec's processing order:

1. `rejectForbiddenParParams` rejects `request_uri` in the body (a MUST NOT in §2.1) and `request` (JAR combination is a non-goal)
2. `authenticateParClient` authenticates the client (under exactly the token endpoint's rules, described below)
3. `validatePushedAuthorizationParams` validates the pushed parameters under exactly the rules of the authorization endpoint (core's `validateAuthorizationRequest`)
4. `createPushedAuthorizationRecord` generates the reference value from 256 bits of cryptographic randomness and stores the record
5. `buildPushedAuthorizationResponse` assembles the 201 response body (`request_uri` and `expires_in`)

Step 2 delegates credential extraction and the multiple-method check entirely to core's `extractClientCredentials` and the steps that follow it.
What RFC 9126 §2.1 demands of the PAR endpoint is client authentication "in the same way as at the token endpoint", and core carries all of those rules:

- Header authentication is keyed on the `Basic` scheme alone; a header in any other scheme (say, a `Bearer` token injected by a gateway) is ignored and the body credentials authenticate the client
- An empty-string `client_secret` is normalized to "not presented" (RFC 6749 §3.2: parameters sent without a value MUST be treated as omitted)
- A `Basic` header combined with a non-empty body `client_secret` is rejected as multiple authentication methods per OAuth 2.1 §2.3 (`invalid_request`)
- The `client_id` that §2.1 requires in the body is checked by core for consistency with the `Basic` credentials, which is what ties the request_uri to the client that pushed it (RFC 9126 §2.2)

This function used to be a hand-rolled implementation that branched on the mere presence of an Authorization header.
Core at the time treated a body `client_id` by itself as use of `client_secret_post`, so combining it with the header was rejected as multiple methods, and PAR had to pre-sort the credentials.
Once core gained the Basic-scheme keying and the empty-secret normalization, that premise disappeared, and what remained of the hand-rolled version was only a §2.1 violation: the same credentials passed at `/token` and drew a 4xx at `/par`.
The full delegation removes that divergence.

On lifetimes, `assertParExpiresInSeconds` validates the §2.2 recommended range (an integer between 5 and 600).
Generated code calls it while loading configuration, at startup, so an out-of-range setting fails before any request is processed.

`toParError` at the bottom maps core's errors onto PAR error codes and rethrows anything it does not recognize (the caller treats that as a 500).
Interaction-class authorization codes (`login_required` and the like) cannot occur while validating a pushed request, so codes without a PAR counterpart collapse into `invalid_request`.

```typescript
/**
 * Pushed Authorization Requests (PAR) — RFC 9126 §2
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * PAR エンドポイントの処理。「合成関数＋ステップ関数」の二層構成とし、
 * CLI 生成コードはステップ関数を順に呼び出して処理を組み立てられるようにする。
 */
import {
  AuthorizationError,
  AuthorizationErrorCode,
  TokenError,
  TokenErrorCode,
  extractClientCredentials,
  generateRandomString,
  parseClaimsRequestParameter,
  rejectUnsupportedRequestParams,
  resolveAuthenticatedTokenClient,
  resolveAuthorizationRedirectUri,
  resolveClientForAuthorization,
  resolveMaxAge,
  sanitizeErrorDescription,
  validateAuthorizationCodePkce,
  validateAuthorizationScope,
  validateClientAuthMethod,
  validateDisplayParameter,
  validatePromptParameter,
  validateRegisteredRedirectUris,
  validateResponseType,
  verifyClientSecret,
  type AuthorizationRequestParams,
  type ClientResolver,
  type TokenClientResolver,
} from '@maronn-openid-connect/core';
import { PAR_REQUEST_URI_PREFIX } from './store.js';
import type {
  PushedAuthorizationRecord,
  PushedAuthorizationRequestStore,
} from './store.js';

/**
 * PAR エンドポイントのエラーコード。
 * RFC 9126 §2.3: token endpoint と同じ形式のエラーレスポンスを返す。
 */
export type ParErrorCode =
  | 'invalid_request'
  | 'invalid_client'
  | 'invalid_scope'
  | 'unauthorized_client'
  | 'unsupported_response_type';

/**
 * PAR エンドポイントのエラー。
 *
 * バックチャネルのエンドポイントなのでリダイレクトは行わず、常に JSON で返す
 * （リダイレクト先情報を持たないのは意図的な設計）。
 */
export class ParError extends Error {
  readonly code: ParErrorCode;
  readonly errorDescription: string;

  constructor(code: ParErrorCode, errorDescription: string) {
    // RFC 6749 §5.2: error_description は安全な文字集合に限定する。
    const sanitized = sanitizeErrorDescription(errorDescription);
    super(sanitized);
    this.name = 'ParError';
    this.code = code;
    this.errorDescription = sanitized;
  }

  /** RFC 6749 §5.2: クライアント認証失敗のみ 401、それ以外は 400。 */
  get statusCode(): 400 | 401 {
    return this.code === 'invalid_client' ? 401 : 400;
  }

  /** RFC 6749 §5.2: 401 の場合のみ Basic チャレンジを返す（token endpoint と同挙動）。 */
  get wwwAuthenticate(): string | undefined {
    return this.code === 'invalid_client' ? 'Basic realm="Client Authentication"' : undefined;
  }
}

/** PAR エンドポイントの成功レスポンス（RFC 9126 §2.2）。 */
export interface PushedAuthorizationResponse {
  /** `urn:ietf:params:oauth:request_uri:<reference-value>` */
  requestUri: string;
  /** request_uri の有効期間（秒） */
  expiresIn: number;
}

/** {@link validatePushedAuthorizationParams} のオプション。 */
export interface PushedAuthorizationValidationOptions {
  /**
   * OIDF Basic OP static-client conformance 互換。true かつ confidential client が
   * PKCE を完全に省略した場合だけ省略を許容する。認可エンドポイントと同じ値を渡すこと。
   */
  allowNonPkceAuthorizationCodeFlow?: boolean;
  /**
   * `claims` パラメータ（OIDC Core 1.0 §5.5）を `JSON.parse` する前に課す最大長。
   * 未指定なら core の `DEFAULT_MAX_CLAIMS_PARAMETER_LENGTH`。
   */
  maxClaimsParameterLength?: number;
}

/** PAR エンドポイント処理のコンテキスト。 */
export interface PushedAuthorizationRequestContext {
  /** フォームボディのパラメータ（application/x-www-form-urlencoded） */
  params: Record<string, string>;
  /** Authorization ヘッダの値（client_secret_basic 用）。無ければ空文字 */
  authorizationHeader?: string;
  /** クライアント解決。認可リクエスト検証とクライアント認証の両方に使う */
  clientResolver: ClientResolver & TokenClientResolver;
  store: PushedAuthorizationRequestStore;
  /** {@link validatePushedAuthorizationParams} へ渡すオプション */
  validationOptions: PushedAuthorizationValidationOptions;
  /** request_uri の有効期間（秒）。既定 60、許容範囲 5〜600 */
  expiresInSeconds?: number;
  /** 現在時刻。テストと決定的な期限計算のために注入できる */
  now?: Date;
}

/** RFC 9126 §2.2: expires_in は "typically ... between 5 and 600 seconds"。 */
const MIN_EXPIRES_IN_SECONDS = 5;
const MAX_EXPIRES_IN_SECONDS = 600;
const DEFAULT_EXPIRES_IN_SECONDS = 60;

/** RFC 9126 §2.2 / §7.1: 参照値は暗号論的乱数で生成する（32 バイト = 256 ビット）。 */
const REFERENCE_VALUE_BYTE_LENGTH = 32;

/**
 * request_uri の有効期間が RFC 9126 §2.2 の推奨レンジ内かを検証する。
 *
 * 生成コードは設定値の読み込み時（= 起動時）にこれを呼び、範囲外の設定を
 * リクエスト処理前に失敗させる。
 *
 * @throws {RangeError} 5〜600 の整数でない場合
 */
export function assertParExpiresInSeconds(seconds: number): void {
  const isValid =
    Number.isInteger(seconds) &&
    seconds >= MIN_EXPIRES_IN_SECONDS &&
    seconds <= MAX_EXPIRES_IN_SECONDS;
  if (!isValid) {
    throw new RangeError(
      `expiresInSeconds must be an integer between ${MIN_EXPIRES_IN_SECONDS} and ${MAX_EXPIRES_IN_SECONDS} (RFC 9126 §2.2), received ${seconds}`,
    );
  }
}

/**
 * ステップ 1: PAR ボディに含めてはならないパラメータを拒否する。
 *
 * - `request_uri`: RFC 9126 §2.1 の MUST NOT
 * - `request`: PAR と Request Object (JAR) の併用は本機能の非目標
 *
 * @throws {ParError} invalid_request
 */
export function rejectForbiddenParParams(params: Record<string, string>): void {
  if (params['request_uri'] !== undefined) {
    throw new ParError(
      'invalid_request',
      'request_uri MUST NOT be included in a pushed authorization request',
    );
  }
  if (params['request'] !== undefined) {
    throw new ParError(
      'invalid_request',
      'The request parameter (Request Object) is not supported by this pushed authorization request endpoint',
    );
  }
}

/**
 * ステップ 2: クライアントを認証する（RFC 9126 §2.1: token endpoint と同一規則）。
 *
 * 資格情報の抽出・多重方式の判定・検証はすべて core の
 * {@link extractClientCredentials} 以降のステップへ委譲し、token endpoint と
 * 同一の規則を適用する:
 *
 * - ヘッダ認証は `Basic` スキームだけが対象で、他スキームのヘッダ（ゲートウェイが
 *   注入する `Bearer` など）は無視してボディの資格情報で認証する
 * - 空文字列の `client_secret` は「未提示」に正規化される（RFC 6749 §3.2）
 * - `Basic` とボディの `client_secret`（非空）の併用は OAuth 2.1 §2.3 の
 *   多重方式として invalid_request
 * - RFC 9126 §2.1 で必須の認可パラメータとしてボディに入る `client_id` は、
 *   `Basic` 併用時に core が Basic 側の client_id との一致を検証する
 *   （RFC 9126 §2.2: request_uri は pushed request を送ったクライアントに紐付く）
 *
 * @returns 認証されたクライアントID
 * @throws {ParError} invalid_client / invalid_request
 */
export async function authenticateParClient(context: {
  params: Record<string, string>;
  authorizationHeader?: string;
  clientResolver: TokenClientResolver;
}): Promise<string> {
  const { params, clientResolver } = context;
  return runClientAuthentication({
    params: { client_id: params['client_id'], client_secret: params['client_secret'] },
    authorizationHeader: context.authorizationHeader ?? '',
    clientResolver,
  });
}

/**
 * core のクライアント認証ステップ関数を仕様順に実行し、TokenError を ParError へ写す。
 */
async function runClientAuthentication(context: {
  params: Record<string, string | undefined>;
  authorizationHeader: string;
  clientResolver: TokenClientResolver;
}): Promise<string> {
  try {
    const presented = extractClientCredentials({
      params: context.params,
      authorizationHeader: context.authorizationHeader,
    });
    const client = await resolveAuthenticatedTokenClient(presented.clientId, context.clientResolver);
    validateClientAuthMethod(client, presented);
    await verifyClientSecret(client, presented.clientSecret);
    return presented.clientId;
  } catch (error) {
    throw toParError(error);
  }
}

/**
 * ステップ 3: pushed されたパラメータを、認可エンドポイントと同じ規則で検証する。
 *
 * RFC 9126 §2.1: "The authorization server ... MUST validate the request as it would
 * an authorization request sent to the authorization endpoint."
 *
 * 認可エンドポイントの生成コードと同じ順序で core のステップ関数を呼び、パラメータを
 * 拒否するものだけを実行する（scope の絞り込みなど値を組み立てる処理は、request_uri を
 * 展開した認可エンドポイントが行う）。PAR は Request Object（`request`）と併用しない
 * （{@link rejectForbiddenParParams}）ため、`request` はパースせず request_not_supported
 * として拒否する。
 *
 * 失敗は必ず {@link ParError} になり、リダイレクトはしない（RFC 9126 §2.3）。
 *
 * @throws {ParError}
 */
export async function validatePushedAuthorizationParams(
  params: Record<string, string>,
  clientResolver: ClientResolver,
  options: PushedAuthorizationValidationOptions = {},
): Promise<void> {
  const request = params as unknown as AuthorizationRequestParams;
  try {
    const client = await resolveClientForAuthorization(request, clientResolver);
    validateRegisteredRedirectUris(client.redirectUris);
    const redirectUri = resolveAuthorizationRedirectUri(request, client);
    const state = request.state;
    rejectUnsupportedRequestParams(request, redirectUri, state, {
      requestParameterSupported: false,
    });
    validateResponseType(request, client, redirectUri, state);
    validateAuthorizationScope(request, request, redirectUri, state);
    validateAuthorizationCodePkce(request, client, redirectUri, state, {
      allowNonPkceAuthorizationCodeFlow: options.allowNonPkceAuthorizationCodeFlow,
    });
    validatePromptParameter(request, redirectUri, state);
    validateDisplayParameter(request, redirectUri, state);
    resolveMaxAge(request, client, redirectUri, state);
    parseClaimsRequestParameter(request, redirectUri, state, options.maxClaimsParameterLength);
  } catch (error) {
    throw toParError(error);
  }
}

/**
 * 保存対象から必ず除外するクライアント認証パラメータ。
 *
 * PAR ボディはクライアント認証情報と認可リクエストパラメータが同居する。認証情報を
 * レコードへ残すと、シークレットがストア（永続層・ログ・バックアップ）に残り、さらに
 * 認可エンドポイントで展開されたパラメータにも混入する。認証は保存前に完了しているため
 * 保持する必要はない。
 */
const CLIENT_AUTHENTICATION_PARAMS = ['client_secret', 'client_assertion', 'client_assertion_type'];

/**
 * ステップ 4: 参照値（URN）を生成してレコードを保存する（RFC 9126 §2.2）。
 *
 * `params` の `client_id` は認証済みクライアントの値に正規化して保存し、クライアント
 * 認証パラメータ（`client_secret` 等）は保存しない。
 * 呼び出し側が渡したオブジェクトは変更しない。
 *
 * @throws {RangeError} expiresInSeconds が RFC 9126 §2.2 の推奨レンジ外
 */
export async function createPushedAuthorizationRecord(options: {
  clientId: string;
  params: Record<string, string>;
  store: PushedAuthorizationRequestStore;
  expiresInSeconds?: number;
  now?: Date;
}): Promise<PushedAuthorizationRecord> {
  const expiresInSeconds = options.expiresInSeconds ?? DEFAULT_EXPIRES_IN_SECONDS;
  assertParExpiresInSeconds(expiresInSeconds);

  const storedParams: Record<string, string> = { ...options.params, client_id: options.clientId };
  for (const name of CLIENT_AUTHENTICATION_PARAMS) {
    delete storedParams[name];
  }

  const createdAt = options.now ?? new Date();
  const record: PushedAuthorizationRecord = {
    requestUri: PAR_REQUEST_URI_PREFIX + generateRandomString(REFERENCE_VALUE_BYTE_LENGTH),
    clientId: options.clientId,
    params: storedParams,
    createdAt,
    expiresAt: new Date(createdAt.getTime() + expiresInSeconds * 1000),
  };
  await options.store.save(record);
  return record;
}

/** ステップ 5: 201 レスポンスのボディを組み立てる（RFC 9126 §2.2）。 */
export function buildPushedAuthorizationResponse(
  record: PushedAuthorizationRecord,
): PushedAuthorizationResponse {
  return {
    requestUri: record.requestUri,
    expiresIn: Math.round((record.expiresAt.getTime() - record.createdAt.getTime()) / 1000),
  };
}

/**
 * 合成関数: PAR エンドポイントの全処理（RFC 9126 §2）。
 *
 * 個々のステップ関数を仕様順に合成しただけの API。生成コードは通常この関数ではなく
 * ステップ関数を順に呼び出し、検証の差し替え・削除ができるようにする。
 *
 * @throws {ParError}
 */
export async function handlePushedAuthorizationRequest(
  context: PushedAuthorizationRequestContext,
): Promise<PushedAuthorizationResponse> {
  rejectForbiddenParParams(context.params);

  const clientId = await authenticateParClient({
    params: context.params,
    authorizationHeader: context.authorizationHeader,
    clientResolver: context.clientResolver,
  });

  // client_id を認証済みの値に正規化してから検証する（ボディ省略時にも成立させる）。
  const params = { ...context.params, client_id: clientId };
  await validatePushedAuthorizationParams(params, context.clientResolver, context.validationOptions);

  const record = await createPushedAuthorizationRecord({
    clientId,
    params,
    store: context.store,
    expiresInSeconds: context.expiresInSeconds,
    now: context.now,
  });

  return buildPushedAuthorizationResponse(record);
}

/**
 * core のエラーを PAR エンドポイントのエラーへ写す。
 *
 * 未知の例外はそのまま再スローし、握りつぶさない（呼び出し側が 500 として扱う）。
 */
function toParError(error: unknown): unknown {
  if (error instanceof ParError) return error;
  if (error instanceof TokenError) return new ParError(toParErrorCodeFromToken(error.error), error.errorDescription);
  if (error instanceof AuthorizationError) {
    return new ParError(toParErrorCodeFromAuthorization(error.error), error.errorDescription);
  }
  return error;
}

function toParErrorCodeFromToken(code: TokenErrorCode): ParErrorCode {
  switch (code) {
    case TokenErrorCode.InvalidClient:
      return 'invalid_client';
    case TokenErrorCode.UnauthorizedClient:
      return 'unauthorized_client';
    case TokenErrorCode.InvalidScope:
      return 'invalid_scope';
    default:
      return 'invalid_request';
  }
}

function toParErrorCodeFromAuthorization(code: AuthorizationErrorCode): ParErrorCode {
  switch (code) {
    case AuthorizationErrorCode.InvalidScope:
      return 'invalid_scope';
    case AuthorizationErrorCode.UnauthorizedClient:
      return 'unauthorized_client';
    case AuthorizationErrorCode.UnsupportedResponseType:
      return 'unsupported_response_type';
    default:
      // RFC 9126 §2.3 は PAR 固有のエラーコードを追加しない。認可エンドポイント固有の
      // インタラクション系コード（login_required 等）は pushed request の検証では
      // 発生しないため、残りは invalid_request に集約する。
      return 'invalid_request';
  }
}
```

### resolve-request-uri.ts (expansion at the authorization endpoint)

This is the stage inserted in front of the authorization endpoint.
`resolvePushedRequestUri` acts only when `request_uri` matches the URN prefix; otherwise it returns `null` and the caller continues the ordinary flow.
That do-nothing-unless-matched behavior is what guarantees enabling PAR changes nothing for existing requests (URL-form `request_uri` values keep being rejected by core with `request_uri_not_supported`).

On a match, the record is fetched through the store's `consume` (single use), then the expiry and the client binding are checked, and the pushed parameters minus `request_uri` are returned.
Consumption deliberately precedes validation: whether the failure is expiry or a client mismatch, the presented `request_uri` is already gone, so a failed presentation cannot be retried.
`request_uri` is dropped from the expanded parameters because core's `rejectUnsupportedRequestParams` would otherwise reject it with `request_uri_not_supported`.

`assertPushedRequestUsed` is the guard for `require_pushed_authorization_requests` (§5): when PAR is mandatory, an authorization request without a URN-form `request_uri` is rejected.

The dedicated error type `PushedRequestUriError` exists because core's enum lacks `invalid_request_uri`.
It is always non-redirecting: in the generated code, `features/par/steps/resolve-pushed-request.ts` maps it to a core `AuthorizationError` without a `redirect_uri`, which takes the same non-redirect path on the OP as the existing errors.

```typescript
/**
 * Pushed Authorization Requests (PAR) — RFC 9126 §4 / §5
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * 認可エンドポイントの前段で `request_uri` を pushed パラメータへ展開する処理。
 */
import { sanitizeErrorDescription } from '@maronn-openid-connect/core';
import { PAR_REQUEST_URI_PREFIX } from './store.js';
import type { PushedAuthorizationRequestStore } from './store.js';

/**
 * 認可エンドポイント側の `request_uri` 解決エラー。
 *
 * 常に非リダイレクトである（リダイレクト先情報を持たない）。core の
 * `AuthorizationErrorCode` は closed な enum で `invalid_request_uri` を含まないため、
 * core を変更せずに済むよう専用クラスとしている。生成コードは authorize ハンドラの
 * catch 節にこのクラス用の分岐を持ち、既存の非リダイレクト経路（JSON / 内部 303 /
 * HTML エラーページ）と同じ描画で処理する。
 */
export class PushedRequestUriError extends Error {
  readonly code: 'invalid_request_uri' | 'invalid_request';
  readonly errorDescription: string;

  constructor(code: 'invalid_request_uri' | 'invalid_request', errorDescription: string) {
    // RFC 6749 §5.2: error_description は安全な文字集合に限定する。
    const sanitized = sanitizeErrorDescription(errorDescription);
    super(sanitized);
    this.name = 'PushedRequestUriError';
    this.code = code;
    this.errorDescription = sanitized;
  }
}

/**
 * 解決失敗時の固定 error_description。
 *
 * 不存在・使用済み・期限切れ・client_id 不一致を区別しないのは意図的で、応答差から
 * 「その request_uri が存在したか」を判定できるオラクルを作らないため。
 */
const OPAQUE_RESOLUTION_FAILURE_DESCRIPTION =
  'The request_uri is invalid, expired, or has already been used';

/**
 * `request_uri` が URN 形式なら pushed パラメータへ展開する（RFC 9126 §4）。
 *
 * - `request_uri` が無い、または URN 前置詞に一致しない場合は `null` を返す。
 *   呼び出し側は従来どおりのフローを続ける（OIDC Core §6.2 の URL 形式は core が
 *   `request_uri_not_supported` で拒否する）。
 * - 一致した場合は store から単回使用（atomic consume）で取得し、期限と client_id の
 *   紐付けを検証したうえで、`request_uri` を除いた pushed パラメータを返す。
 *
 * 展開後のパラメータは既存の core 検証パイプラインへそのまま流すこと
 * （RFC 9126 §4 の "MUST validate ... as it would any other authorization request"）。
 *
 * @throws {PushedRequestUriError} 解決に失敗した場合（常に非リダイレクト）
 */
export async function resolvePushedRequestUri(options: {
  params: Record<string, string>;
  store: PushedAuthorizationRequestStore;
  now?: Date;
}): Promise<Record<string, string> | null> {
  const requestUri = options.params['request_uri'];
  if (requestUri === undefined || !requestUri.startsWith(PAR_REQUEST_URI_PREFIX)) {
    return null;
  }

  // RFC 9126 §7.3: 単回使用。取得と同時に削除する（失敗種別に関わらず消費する）。
  const record = await options.store.consume(requestUri);
  if (record === null) {
    throw new PushedRequestUriError('invalid_request_uri', OPAQUE_RESOLUTION_FAILURE_DESCRIPTION);
  }

  // RFC 9126 §4: "An expired request_uri MUST be rejected as invalid."
  const now = options.now ?? new Date();
  if (record.expiresAt.getTime() < now.getTime()) {
    throw new PushedRequestUriError('invalid_request_uri', OPAQUE_RESOLUTION_FAILURE_DESCRIPTION);
  }

  // RFC 9126 §2.2: "The request_uri value ... MUST be bound to the client that posted
  // the authorization request."
  if (options.params['client_id'] !== record.clientId) {
    throw new PushedRequestUriError('invalid_request_uri', OPAQUE_RESOLUTION_FAILURE_DESCRIPTION);
  }

  // 展開後は request_uri を残さない。残すと core の rejectUnsupportedRequestParams が
  // request_uri_not_supported で拒否してしまう。
  const { request_uri: _consumed, ...pushedParams } = record.params;
  return pushedParams;
}

/**
 * `require_pushed_authorization_requests` 用のガード（RFC 9126 §5）。
 *
 * PAR 必須設定のとき、URN 形式の `request_uri` を伴わない認可リクエストを拒否する。
 *
 * @throws {PushedRequestUriError} invalid_request（非リダイレクト）
 */
export function assertPushedRequestUsed(params: Record<string, string>): void {
  const requestUri = params['request_uri'];
  if (requestUri === undefined || !requestUri.startsWith(PAR_REQUEST_URI_PREFIX)) {
    throw new PushedRequestUriError(
      'invalid_request',
      'Pushed authorization requests are required by this authorization server',
    );
  }
}
```

### index.ts (public API)

The substance of the subpath export `@maronn-openid-connect/experimental/par`.
Step functions, the composition function, error types, and the store contract are all exported so that generated code can pick and assemble them.

```typescript
/**
 * Pushed Authorization Requests (PAR) — RFC 9126
 *
 * **Experimental**: この機能の API は安定していない。マイナーリリースでも
 * 破壊的に変更されることがある。本番運用の前に
 * `docs/library-document` の Experimental セクションを確認すること。
 *
 * `@maronn-openid-connect/core` とは別 package であり、CLI で `--enable par` を明示した
 * ときのみ生成コードから利用される。
 */
export {
  ParError,
  assertParExpiresInSeconds,
  authenticateParClient,
  buildPushedAuthorizationResponse,
  createPushedAuthorizationRecord,
  handlePushedAuthorizationRequest,
  rejectForbiddenParParams,
  validatePushedAuthorizationParams,
  type ParErrorCode,
  type PushedAuthorizationRequestContext,
  type PushedAuthorizationResponse,
} from './par-request.js';

export {
  PushedRequestUriError,
  assertPushedRequestUsed,
  resolvePushedRequestUri,
} from './resolve-request-uri.js';

export {
  PAR_REQUEST_URI_PREFIX,
  type PushedAuthorizationRecord,
  type PushedAuthorizationRequestStore,
} from './store.js';
```

## The unit tests, in full

The tests mirror the implementation split across two files.
Both run in an Edge Runtime environment (Web standard APIs only) against an in-memory store, so they are deterministic.

What `par-request.test.ts` pins down, in summary:

- rejection of the forbidden parameters (`request_uri` / `request`) and acceptance of a body carrying neither
- lifetime boundary values (5 and 600 accepted; out-of-range and non-integers rejected)
- every client authentication path (Basic with `client_id` in the body, `client_secret_post`, public clients, an empty-string `client_secret` treated as not presented, body credentials authenticating under a non-Basic header, rejection of multiple methods, `client_id` mismatch, wrong secret, unknown client)
- `ParError`'s HTTP status and `WWW-Authenticate` challenge, and sanitization of `error_description`
- the error-code mapping of pushed-parameter validation (`invalid_request` / `invalid_scope` / `unsupported_response_type`) and the fact that thrown errors carry no redirect target
- record creation: the URN form, the 256-bit reference value, uniqueness per call, default and configured lifetimes, credentials never being persisted, and caller-supplied arguments never being mutated
- the composition function end to end (what gets stored; nothing stored on failed authentication or failed validation; PKCE required for public clients)

```typescript
import { describe, it, expect } from 'vitest';
import type {
  ClientInfo,
  ClientResolver,
  TokenClientInfo,
  TokenClientResolver,
} from '@maronn-openid-connect/core';
import {
  ParError,
  assertParExpiresInSeconds,
  authenticateParClient,
  buildPushedAuthorizationResponse,
  createPushedAuthorizationRecord,
  handlePushedAuthorizationRequest,
  rejectForbiddenParParams,
  validatePushedAuthorizationParams,
} from './par-request.js';
import { PAR_REQUEST_URI_PREFIX } from './store.js';
import type {
  PushedAuthorizationRecord,
  PushedAuthorizationRequestStore,
} from './store.js';

type TestClient = ClientInfo & TokenClientInfo;

const BASIC_CLIENT: TestClient = {
  clientId: 'web-app',
  clientSecret: 'secret',
  redirectUris: ['https://client.example/cb'],
  clientType: 'confidential',
  tokenEndpointAuthMethod: 'client_secret_basic',
};

const POST_CLIENT: TestClient = {
  clientId: 'post-app',
  clientSecret: 'secret',
  redirectUris: ['https://client.example/cb'],
  clientType: 'confidential',
  tokenEndpointAuthMethod: 'client_secret_post',
};

const PUBLIC_CLIENT: TestClient = {
  clientId: 'spa-app',
  redirectUris: ['https://spa.example/cb'],
  clientType: 'public',
  tokenEndpointAuthMethod: 'none',
};

const TEST_CLIENTS: readonly TestClient[] = [BASIC_CLIENT, POST_CLIENT, PUBLIC_CLIENT];

function createClientResolver(): ClientResolver & TokenClientResolver {
  return {
    async findClient(clientId: string): Promise<TestClient | null> {
      return TEST_CLIENTS.find((client) => client.clientId === clientId) ?? null;
    },
  };
}

class RecordingStore implements PushedAuthorizationRequestStore {
  readonly saved: PushedAuthorizationRecord[] = [];

  async save(record: PushedAuthorizationRecord): Promise<void> {
    this.saved.push(record);
  }

  async consume(requestUri: string): Promise<PushedAuthorizationRecord | null> {
    const index = this.saved.findIndex((entry) => entry.requestUri === requestUri);
    if (index === -1) return null;
    const [record] = this.saved.splice(index, 1);
    return record ?? null;
  }
}

/** RFC 9126 §2.1 の例と同じ、認可エンドポイントへ送るのと同じパラメータ一式。 */
function validParams(overrides: Record<string, string> = {}): Record<string, string> {
  return {
    response_type: 'code',
    client_id: 'web-app',
    redirect_uri: 'https://client.example/cb',
    scope: 'openid profile',
    state: 'af0ifjsldkj',
    nonce: 'n-0S6_WzA2Mj',
    code_challenge: 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
    code_challenge_method: 'S256',
    ...overrides,
  };
}

/** `client_secret_basic` 用の Authorization ヘッダ（RFC 6749 §2.3.1）。 */
function basicHeader(clientId: string, clientSecret: string): string {
  return 'Basic ' + btoa(`${encodeURIComponent(clientId)}:${encodeURIComponent(clientSecret)}`);
}

describe('rejectForbiddenParParams', () => {
  it('should reject a request_uri parameter in the pushed request body', () => {
    // RFC 9126 §2.1: "the request_uri authorization request parameter is one exception
    // and it MUST NOT be provided."
    expect(() => rejectForbiddenParParams(validParams({ request_uri: 'urn:x' }))).toThrowError(
      new ParError('invalid_request', 'request_uri MUST NOT be included in a pushed authorization request'),
    );
  });

  it('should reject a request parameter because PAR with a Request Object is out of scope', () => {
    expect(() => rejectForbiddenParParams(validParams({ request: 'eyJhbGciOiJSUzI1NiJ9.e30.sig' }))).toThrowError(
      new ParError('invalid_request', 'The request parameter (Request Object) is not supported by this pushed authorization request endpoint'),
    );
  });

  it('should accept a body that carries neither request_uri nor request', () => {
    expect(rejectForbiddenParParams(validParams())).toBe(undefined);
  });
});

describe('assertParExpiresInSeconds', () => {
  it('should accept the lower bound of 5 seconds', () => {
    expect(assertParExpiresInSeconds(5)).toBe(undefined);
  });

  it('should accept the upper bound of 600 seconds', () => {
    expect(assertParExpiresInSeconds(600)).toBe(undefined);
  });

  it('should reject a value below the RFC 9126 recommended range', () => {
    expect(() => assertParExpiresInSeconds(4)).toThrowError(
      new RangeError('expiresInSeconds must be an integer between 5 and 600 (RFC 9126 §2.2), received 4'),
    );
  });

  it('should reject a value above the RFC 9126 recommended range', () => {
    expect(() => assertParExpiresInSeconds(601)).toThrowError(
      new RangeError('expiresInSeconds must be an integer between 5 and 600 (RFC 9126 §2.2), received 601'),
    );
  });

  it('should reject a non-integer value', () => {
    expect(() => assertParExpiresInSeconds(60.5)).toThrowError(
      new RangeError('expiresInSeconds must be an integer between 5 and 600 (RFC 9126 §2.2), received 60.5'),
    );
  });
});

describe('authenticateParClient', () => {
  it('should return the authenticated client id for client_secret_basic with client_id in the body', async () => {
    // RFC 9126 §2.1: client_id is a required authorization request parameter, so it is
    // present in the body even when the client authenticates with HTTP Basic.
    const clientId = await authenticateParClient({
      params: validParams(),
      authorizationHeader: basicHeader('web-app', 'secret'),
      clientResolver: createClientResolver(),
    });

    expect(clientId).toBe('web-app');
  });

  it('should return the authenticated client id for client_secret_post', async () => {
    const clientId = await authenticateParClient({
      params: validParams({ client_id: 'post-app', client_secret: 'secret' }),
      authorizationHeader: '',
      clientResolver: createClientResolver(),
    });

    expect(clientId).toBe('post-app');
  });

  it('should return the client id for a public client presenting only client_id', async () => {
    const clientId = await authenticateParClient({
      params: validParams({ client_id: 'spa-app', redirect_uri: 'https://spa.example/cb' }),
      authorizationHeader: '',
      clientResolver: createClientResolver(),
    });

    expect(clientId).toBe('spa-app');
  });

  it('should authenticate with Basic when the body carries an empty client_secret', async () => {
    // RFC 6749 §3.2: "Parameters sent without a value MUST be treated as if they
    // were omitted from the request." — the token endpoint normalizes an empty
    // client_secret to "not presented", and RFC 9126 §2.1 requires the PAR
    // endpoint to authenticate the client the same way.
    const clientId = await authenticateParClient({
      params: validParams({ client_secret: '' }),
      authorizationHeader: basicHeader('web-app', 'secret'),
      clientResolver: createClientResolver(),
    });

    expect(clientId).toBe('web-app');
  });

  it('should authenticate via body credentials when a non-Basic Authorization header is present', async () => {
    // The token endpoint keys header authentication on the Basic scheme and
    // ignores other schemes (e.g. a Bearer header injected by a gateway), so
    // the PAR endpoint must do the same (RFC 9126 §2.1).
    const clientId = await authenticateParClient({
      params: validParams({ client_id: 'post-app', client_secret: 'secret' }),
      authorizationHeader: 'Bearer gateway-injected-token',
      clientResolver: createClientResolver(),
    });

    expect(clientId).toBe('post-app');
  });

  it('should reject a body client_secret combined with a Basic Authorization header', async () => {
    // OAuth 2.1 §2.3: a client MUST NOT use more than one authentication method.
    await expect(
      authenticateParClient({
        params: validParams({ client_secret: 'secret' }),
        authorizationHeader: basicHeader('web-app', 'secret'),
        clientResolver: createClientResolver(),
      }),
    ).rejects.toThrowError(
      new ParError('invalid_request', 'Multiple client authentication methods provided. Use either Authorization header or request body, not both.'),
    );
  });

  it('should reject a body client_id that differs from the Basic-authenticated client', async () => {
    await expect(
      authenticateParClient({
        params: validParams({ client_id: 'spa-app' }),
        authorizationHeader: basicHeader('web-app', 'secret'),
        clientResolver: createClientResolver(),
      }),
    ).rejects.toThrowError(
      new ParError('invalid_request', 'client_id in request body does not match the Authorization header'),
    );
  });

  it('should reject a wrong client_secret with invalid_client', async () => {
    await expect(
      authenticateParClient({
        params: validParams(),
        authorizationHeader: basicHeader('web-app', 'wrong-secret'),
        clientResolver: createClientResolver(),
      }),
    ).rejects.toThrowError(new ParError('invalid_client', 'Client authentication failed'));
  });

  it('should reject an unknown client with invalid_client', async () => {
    await expect(
      authenticateParClient({
        params: validParams({ client_id: 'unknown' }),
        authorizationHeader: '',
        clientResolver: createClientResolver(),
      }),
    ).rejects.toThrowError(new ParError('invalid_client', 'Client authentication failed'));
  });
});

describe('ParError', () => {
  it('should map invalid_client to HTTP 401', () => {
    expect(new ParError('invalid_client', 'Client authentication failed').statusCode).toBe(401);
  });

  it('should map invalid_request to HTTP 400', () => {
    expect(new ParError('invalid_request', 'bad request').statusCode).toBe(400);
  });

  it('should return a Basic challenge for invalid_client', () => {
    expect(new ParError('invalid_client', 'Client authentication failed').wwwAuthenticate).toBe(
      'Basic realm="Client Authentication"',
    );
  });

  it('should not return a challenge for errors other than invalid_client', () => {
    expect(new ParError('invalid_request', 'bad request').wwwAuthenticate).toBe(undefined);
  });

  it('should sanitize the error description to the RFC 6749 §5.2 character set', () => {
    expect(new ParError('invalid_request', 'bad "quoted"\nvalue').errorDescription).toBe(
      'bad ?quoted??value',
    );
  });
});

describe('validatePushedAuthorizationParams', () => {
  it('should resolve for a well-formed pushed request', async () => {
    await expect(
      validatePushedAuthorizationParams(
        { ...validParams(), client_id: 'web-app' },
        createClientResolver(),
      ),
    ).resolves.toBeUndefined();
  });

  // RFC 9126 §3: PAR combined with a Request Object is not supported, so the
  // request parameter is rejected without being parsed, even when this step is
  // called without rejectForbiddenParParams() in front of it.
  it('should map a request parameter to invalid_request without parsing it', async () => {
    await expect(
      validatePushedAuthorizationParams(
        { ...validParams(), request: 'not-a-jwt' },
        createClientResolver(),
      ),
    ).rejects.toThrowError(
      new ParError('invalid_request', 'request parameter (Request Object) is not supported'),
    );
  });

  it('should map an invalid prompt value to invalid_request', async () => {
    await expect(
      validatePushedAuthorizationParams({ ...validParams(), prompt: 'none login' }, createClientResolver()),
    ).rejects.toMatchObject({ code: 'invalid_request', statusCode: 400 });
  });

  it('should allow an omitted PKCE for a confidential client when allowNonPkceAuthorizationCodeFlow is enabled', async () => {
    const params = validParams();
    delete params['code_challenge'];
    delete params['code_challenge_method'];

    await expect(
      validatePushedAuthorizationParams(params, createClientResolver(), {
        allowNonPkceAuthorizationCodeFlow: true,
      }),
    ).resolves.toBeUndefined();
  });

  it('should map an unregistered redirect_uri to invalid_request', async () => {
    await expect(
      validatePushedAuthorizationParams(
        { ...validParams(), redirect_uri: 'https://attacker.example/cb' },
        createClientResolver(),
      ),
    ).rejects.toMatchObject({ code: 'invalid_request', statusCode: 400 });
  });

  it('should map a missing openid scope to invalid_scope', async () => {
    await expect(
      validatePushedAuthorizationParams({ ...validParams(), scope: 'profile' }, createClientResolver()),
    ).rejects.toMatchObject({ code: 'invalid_scope', statusCode: 400 });
  });

  it('should map an unsupported response_type to unsupported_response_type', async () => {
    await expect(
      validatePushedAuthorizationParams({ ...validParams(), response_type: 'token' }, createClientResolver()),
    ).rejects.toMatchObject({ code: 'unsupported_response_type', statusCode: 400 });
  });

  it('should map an unknown client to invalid_request', async () => {
    await expect(
      validatePushedAuthorizationParams({ ...validParams(), client_id: 'unknown' }, createClientResolver()),
    ).rejects.toMatchObject({ code: 'invalid_request', statusCode: 400 });
  });

  it('should never redirect: the thrown error carries no redirect target', async () => {
    // RFC 9126 §2.3: PAR errors are returned as token-endpoint style JSON, never as a redirect.
    const error = await validatePushedAuthorizationParams(
      { ...validParams(), scope: 'profile' },
      createClientResolver(),
    ).catch((thrown: unknown) => thrown);

    expect(error).toBeInstanceOf(ParError);
    expect(Object.hasOwn(error as object, 'redirectUri')).toBe(false);
  });
});

describe('createPushedAuthorizationRecord', () => {
  it('should issue a request_uri using the RFC 9126 §2.2 URN form', async () => {
    const store = new RecordingStore();
    const record = await createPushedAuthorizationRecord({
      clientId: 'web-app',
      params: validParams(),
      store,
      now: new Date('2026-07-29T00:00:00.000Z'),
    });

    expect(record.requestUri.startsWith(PAR_REQUEST_URI_PREFIX)).toBe(true);
  });

  it('should generate a 256-bit base64url reference value', async () => {
    // RFC 9126 §2.2 / §7.1: the reference value MUST be created with a cryptographically
    // strong PRNG. generateRandomString(32) yields 32 bytes = 43 base64url characters.
    const store = new RecordingStore();
    const record = await createPushedAuthorizationRecord({
      clientId: 'web-app',
      params: validParams(),
      store,
      now: new Date('2026-07-29T00:00:00.000Z'),
    });
    const reference = record.requestUri.slice(PAR_REQUEST_URI_PREFIX.length);

    expect(reference.length).toBe(43);
    expect(/^[A-Za-z0-9_-]{43}$/.test(reference)).toBe(true);
  });

  it('should produce a different reference value on every call', async () => {
    const store = new RecordingStore();
    const first = await createPushedAuthorizationRecord({ clientId: 'web-app', params: validParams(), store });
    const second = await createPushedAuthorizationRecord({ clientId: 'web-app', params: validParams(), store });

    expect(first.requestUri === second.requestUri).toBe(false);
  });

  it('should default the lifetime to 60 seconds', async () => {
    const store = new RecordingStore();
    const record = await createPushedAuthorizationRecord({
      clientId: 'web-app',
      params: validParams(),
      store,
      now: new Date('2026-07-29T00:00:00.000Z'),
    });

    expect(record.expiresAt.toISOString()).toBe('2026-07-29T00:01:00.000Z');
  });

  it('should honor a configured lifetime', async () => {
    const store = new RecordingStore();
    const record = await createPushedAuthorizationRecord({
      clientId: 'web-app',
      params: validParams(),
      store,
      expiresInSeconds: 120,
      now: new Date('2026-07-29T00:00:00.000Z'),
    });

    expect(record.expiresAt.toISOString()).toBe('2026-07-29T00:02:00.000Z');
  });

  it('should reject a lifetime outside the RFC 9126 recommended range', async () => {
    const store = new RecordingStore();

    await expect(
      createPushedAuthorizationRecord({ clientId: 'web-app', params: validParams(), store, expiresInSeconds: 601 }),
    ).rejects.toThrowError(
      new RangeError('expiresInSeconds must be an integer between 5 and 600 (RFC 9126 §2.2), received 601'),
    );
  });

  it('should persist the pushed parameters with the authenticated client_id', async () => {
    const store = new RecordingStore();
    const now = new Date('2026-07-29T00:00:00.000Z');
    const record = await createPushedAuthorizationRecord({
      clientId: 'web-app',
      params: validParams({ client_id: 'web-app' }),
      store,
      now,
    });

    expect(store.saved).toEqual([
      {
        requestUri: record.requestUri,
        clientId: 'web-app',
        params: validParams(),
        createdAt: now,
        expiresAt: new Date('2026-07-29T00:01:00.000Z'),
      },
    ]);
  });

  it('should normalize client_id in the stored parameters to the authenticated client', async () => {
    const store = new RecordingStore();
    const params = validParams();
    delete params['client_id'];
    const record = await createPushedAuthorizationRecord({ clientId: 'web-app', params, store });

    expect(record.params['client_id']).toBe('web-app');
  });

  it('should never persist the client credentials presented for authentication', async () => {
    const store = new RecordingStore();
    const record = await createPushedAuthorizationRecord({
      clientId: 'post-app',
      params: validParams({
        client_id: 'post-app',
        client_secret: 'secret',
        client_assertion: 'assertion',
        client_assertion_type: 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer',
      }),
      store,
    });

    expect(record.params).toEqual(validParams({ client_id: 'post-app' }));
  });

  it('should not mutate the caller-supplied parameters', async () => {
    const store = new RecordingStore();
    const params = validParams();
    delete params['client_id'];
    await createPushedAuthorizationRecord({ clientId: 'web-app', params, store });

    expect(params['client_id']).toBe(undefined);
  });
});

describe('buildPushedAuthorizationResponse', () => {
  it('should return the request_uri and the lifetime in seconds', () => {
    const response = buildPushedAuthorizationResponse({
      requestUri: `${PAR_REQUEST_URI_PREFIX}ref`,
      clientId: 'web-app',
      params: validParams(),
      createdAt: new Date('2026-07-29T00:00:00.000Z'),
      expiresAt: new Date('2026-07-29T00:01:00.000Z'),
    });

    expect(response).toEqual({
      requestUri: `${PAR_REQUEST_URI_PREFIX}ref`,
      expiresIn: 60,
    });
  });
});

describe('handlePushedAuthorizationRequest', () => {
  it('should store the request and return a 60 second request_uri for a confidential client', async () => {
    const store = new RecordingStore();
    const response = await handlePushedAuthorizationRequest({
      params: validParams(),
      authorizationHeader: basicHeader('web-app', 'secret'),
      clientResolver: createClientResolver(),
      store,
      validationOptions: {},
      now: new Date('2026-07-29T00:00:00.000Z'),
    });

    expect(response).toEqual({
      requestUri: store.saved[0]?.requestUri,
      expiresIn: 60,
    });
    expect(store.saved).toEqual([
      {
        requestUri: store.saved[0]?.requestUri,
        clientId: 'web-app',
        params: validParams(),
        createdAt: new Date('2026-07-29T00:00:00.000Z'),
        expiresAt: new Date('2026-07-29T00:01:00.000Z'),
      },
    ]);
  });

  it('should accept a public client that presents only client_id', async () => {
    const store = new RecordingStore();
    const response = await handlePushedAuthorizationRequest({
      params: validParams({ client_id: 'spa-app', redirect_uri: 'https://spa.example/cb' }),
      authorizationHeader: '',
      clientResolver: createClientResolver(),
      store,
      validationOptions: {},
      now: new Date('2026-07-29T00:00:00.000Z'),
    });

    expect(response.expiresIn).toBe(60);
    expect(store.saved[0]?.clientId).toBe('spa-app');
  });

  it('should not store a record when client authentication fails', async () => {
    const store = new RecordingStore();

    await expect(
      handlePushedAuthorizationRequest({
        params: validParams(),
        authorizationHeader: basicHeader('web-app', 'wrong-secret'),
        clientResolver: createClientResolver(),
        store,
        validationOptions: {},
      }),
    ).rejects.toThrowError(new ParError('invalid_client', 'Client authentication failed'));
    expect(store.saved).toEqual([]);
  });

  it('should not store a record when the pushed parameters are invalid', async () => {
    const store = new RecordingStore();

    await expect(
      handlePushedAuthorizationRequest({
        params: validParams({ redirect_uri: 'https://attacker.example/cb' }),
        authorizationHeader: basicHeader('web-app', 'secret'),
        clientResolver: createClientResolver(),
        store,
        validationOptions: {},
      }),
    ).rejects.toMatchObject({ code: 'invalid_request', statusCode: 400 });
    expect(store.saved).toEqual([]);
  });

  it('should reject a request_uri in the body before authenticating', async () => {
    const store = new RecordingStore();

    await expect(
      handlePushedAuthorizationRequest({
        params: validParams({ request_uri: `${PAR_REQUEST_URI_PREFIX}x` }),
        authorizationHeader: basicHeader('web-app', 'secret'),
        clientResolver: createClientResolver(),
        store,
        validationOptions: {},
      }),
    ).rejects.toThrowError(
      new ParError('invalid_request', 'request_uri MUST NOT be included in a pushed authorization request'),
    );
    expect(store.saved).toEqual([]);
  });

  it('should reject a PKCE-less request from a public client', async () => {
    // OAuth 2.1 §4.1.1: PKCE is required. The pushed request is validated exactly as
    // an authorization request would be (RFC 9126 §2.1).
    const store = new RecordingStore();
    const params = validParams({ client_id: 'spa-app', redirect_uri: 'https://spa.example/cb' });
    delete params['code_challenge'];
    delete params['code_challenge_method'];

    await expect(
      handlePushedAuthorizationRequest({
        params,
        authorizationHeader: '',
        clientResolver: createClientResolver(),
        store,
        validationOptions: {},
      }),
    ).rejects.toMatchObject({ code: 'invalid_request', statusCode: 400 });
  });
});
```

`resolve-request-uri.test.ts` pins down the expansion side:

- pass-through when the URN prefix does not match (returns `null`, store untouched)
- successful expansion (`request_uri` removed, pushed values authoritative, the store key treated as opaque)
- every failure kind (unknown, second use, expired, client mismatch, missing `client_id`) producing the same error code and message
- acceptance exactly at the expiry instant, and consumption of the record regardless of failure kind
- the mandatory-PAR guard `assertPushedRequestUsed`, and `PushedRequestUriError` sanitization

```typescript
import { describe, it, expect } from 'vitest';
import {
  PushedRequestUriError,
  assertPushedRequestUsed,
  resolvePushedRequestUri,
} from './resolve-request-uri.js';
import { PAR_REQUEST_URI_PREFIX } from './store.js';
import type {
  PushedAuthorizationRecord,
  PushedAuthorizationRequestStore,
} from './store.js';

const REQUEST_URI = `${PAR_REQUEST_URI_PREFIX}6esc_11ACC5bwc014ltc14eY22c`;

/** 解決失敗時の固定文言（失敗種別を外部から区別させないため）。 */
const OPAQUE_DESCRIPTION = 'The request_uri is invalid, expired, or has already been used';

const PUSHED_PARAMS: Record<string, string> = {
  response_type: 'code',
  client_id: 'web-app',
  redirect_uri: 'https://client.example/cb',
  scope: 'openid profile',
  state: 'af0ifjsldkj',
  code_challenge: 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
  code_challenge_method: 'S256',
};

function createRecord(overrides: Partial<PushedAuthorizationRecord> = {}): PushedAuthorizationRecord {
  return {
    requestUri: REQUEST_URI,
    clientId: 'web-app',
    params: { ...PUSHED_PARAMS },
    createdAt: new Date('2026-07-29T00:00:00.000Z'),
    expiresAt: new Date('2026-07-29T00:01:00.000Z'),
    ...overrides,
  };
}

class SingleRecordStore implements PushedAuthorizationRequestStore {
  readonly consumedKeys: string[] = [];
  private record: PushedAuthorizationRecord | null;

  constructor(record: PushedAuthorizationRecord | null) {
    this.record = record;
  }

  async save(record: PushedAuthorizationRecord): Promise<void> {
    this.record = record;
  }

  async consume(requestUri: string): Promise<PushedAuthorizationRecord | null> {
    this.consumedKeys.push(requestUri);
    if (!this.record || this.record.requestUri !== requestUri) return null;
    const consumed = this.record;
    this.record = null;
    return consumed;
  }
}

describe('resolvePushedRequestUri', () => {
  describe('URN prefix matching', () => {
    it('should return null when request_uri is absent so the normal flow continues', async () => {
      const store = new SingleRecordStore(createRecord());

      const resolved = await resolvePushedRequestUri({
        params: { client_id: 'web-app', response_type: 'code' },
        store,
      });

      expect(resolved).toBe(null);
    });

    it('should return null for a URL-form request_uri so core rejects it with request_uri_not_supported', async () => {
      // OIDC Core 1.0 §6.2 の URL 形式は本機能の対象外（specification.md 非目標）。
      const store = new SingleRecordStore(createRecord());

      const resolved = await resolvePushedRequestUri({
        params: { client_id: 'web-app', request_uri: 'https://client.example/request.jwt' },
        store,
      });

      expect(resolved).toBe(null);
    });

    it('should not touch the store when the prefix does not match', async () => {
      const store = new SingleRecordStore(createRecord());

      await resolvePushedRequestUri({
        params: { client_id: 'web-app', request_uri: 'https://client.example/request.jwt' },
        store,
      });

      expect(store.consumedKeys).toEqual([]);
    });
  });

  describe('successful resolution', () => {
    it('should expand the pushed parameters and drop request_uri', async () => {
      // RFC 9126 §4: the authorization server MUST validate the expanded request as it
      // would any other authorization request, so request_uri is removed before the
      // core pipeline sees it.
      const store = new SingleRecordStore(createRecord());

      const resolved = await resolvePushedRequestUri({
        params: { client_id: 'web-app', request_uri: REQUEST_URI },
        store,
        now: new Date('2026-07-29T00:00:30.000Z'),
      });

      expect(resolved).toEqual(PUSHED_PARAMS);
    });

    it('should ignore extra query parameters and keep the pushed values authoritative', async () => {
      const store = new SingleRecordStore(createRecord());

      const resolved = await resolvePushedRequestUri({
        params: {
          client_id: 'web-app',
          request_uri: REQUEST_URI,
          scope: 'openid admin',
          redirect_uri: 'https://attacker.example/cb',
        },
        store,
        now: new Date('2026-07-29T00:00:30.000Z'),
      });

      expect(resolved).toEqual(PUSHED_PARAMS);
    });

    it('should pass the request_uri to the store as an opaque key', async () => {
      const store = new SingleRecordStore(createRecord());

      await resolvePushedRequestUri({
        params: { client_id: 'web-app', request_uri: REQUEST_URI },
        store,
        now: new Date('2026-07-29T00:00:30.000Z'),
      });

      expect(store.consumedKeys).toEqual([REQUEST_URI]);
    });

    it('should strip a request_uri that a store implementation left in the record', async () => {
      const store = new SingleRecordStore(
        createRecord({ params: { ...PUSHED_PARAMS, request_uri: REQUEST_URI } }),
      );

      const resolved = await resolvePushedRequestUri({
        params: { client_id: 'web-app', request_uri: REQUEST_URI },
        store,
        now: new Date('2026-07-29T00:00:30.000Z'),
      });

      expect(resolved).toEqual(PUSHED_PARAMS);
    });
  });

  describe('resolution failures', () => {
    it('should reject an unknown request_uri with invalid_request_uri', async () => {
      const store = new SingleRecordStore(null);

      await expect(
        resolvePushedRequestUri({
          params: { client_id: 'web-app', request_uri: REQUEST_URI },
          store,
        }),
      ).rejects.toThrowError(new PushedRequestUriError('invalid_request_uri', OPAQUE_DESCRIPTION));
    });

    it('should reject the second use of the same request_uri', async () => {
      // RFC 9126 §7.3: the request_uri is single use; consume() removes it atomically.
      const store = new SingleRecordStore(createRecord());
      await resolvePushedRequestUri({
        params: { client_id: 'web-app', request_uri: REQUEST_URI },
        store,
        now: new Date('2026-07-29T00:00:30.000Z'),
      });

      await expect(
        resolvePushedRequestUri({
          params: { client_id: 'web-app', request_uri: REQUEST_URI },
          store,
          now: new Date('2026-07-29T00:00:31.000Z'),
        }),
      ).rejects.toThrowError(new PushedRequestUriError('invalid_request_uri', OPAQUE_DESCRIPTION));
    });

    it('should reject an expired request_uri', async () => {
      // RFC 9126 §4: "An expired request_uri MUST be rejected as invalid."
      const store = new SingleRecordStore(createRecord());

      await expect(
        resolvePushedRequestUri({
          params: { client_id: 'web-app', request_uri: REQUEST_URI },
          store,
          now: new Date('2026-07-29T00:01:00.001Z'),
        }),
      ).rejects.toThrowError(new PushedRequestUriError('invalid_request_uri', OPAQUE_DESCRIPTION));
    });

    it('should accept a request_uri used exactly at its expiry instant', async () => {
      const store = new SingleRecordStore(createRecord());

      const resolved = await resolvePushedRequestUri({
        params: { client_id: 'web-app', request_uri: REQUEST_URI },
        store,
        now: new Date('2026-07-29T00:01:00.000Z'),
      });

      expect(resolved).toEqual(PUSHED_PARAMS);
    });

    it('should reject a request_uri presented by another client', async () => {
      // RFC 9126 §2.2: "The request_uri value ... MUST be bound to the client that
      // posted the authorization request."
      const store = new SingleRecordStore(createRecord());

      await expect(
        resolvePushedRequestUri({
          params: { client_id: 'other-app', request_uri: REQUEST_URI },
          store,
          now: new Date('2026-07-29T00:00:30.000Z'),
        }),
      ).rejects.toThrowError(new PushedRequestUriError('invalid_request_uri', OPAQUE_DESCRIPTION));
    });

    it('should reject a request_uri presented without client_id', async () => {
      const store = new SingleRecordStore(createRecord());

      await expect(
        resolvePushedRequestUri({
          params: { request_uri: REQUEST_URI },
          store,
          now: new Date('2026-07-29T00:00:30.000Z'),
        }),
      ).rejects.toThrowError(new PushedRequestUriError('invalid_request_uri', OPAQUE_DESCRIPTION));
    });

    it('should consume the record even when the client_id does not match', async () => {
      // 不一致でもレコードを残さないことで、正しい client_id による再試行を許さない。
      const store = new SingleRecordStore(createRecord());
      await resolvePushedRequestUri({
        params: { client_id: 'other-app', request_uri: REQUEST_URI },
        store,
        now: new Date('2026-07-29T00:00:30.000Z'),
      }).catch(() => undefined);

      await expect(
        resolvePushedRequestUri({
          params: { client_id: 'web-app', request_uri: REQUEST_URI },
          store,
          now: new Date('2026-07-29T00:00:31.000Z'),
        }),
      ).rejects.toThrowError(new PushedRequestUriError('invalid_request_uri', OPAQUE_DESCRIPTION));
    });

    it('should report the same error code and description for every failure kind', async () => {
      // 存在確認オラクル化の防止（specification.md セキュリティ要件）。
      const unknown = await resolvePushedRequestUri({
        params: { client_id: 'web-app', request_uri: REQUEST_URI },
        store: new SingleRecordStore(null),
      }).catch((error: unknown) => error as PushedRequestUriError);
      const expired = await resolvePushedRequestUri({
        params: { client_id: 'web-app', request_uri: REQUEST_URI },
        store: new SingleRecordStore(createRecord()),
        now: new Date('2026-07-29T01:00:00.000Z'),
      }).catch((error: unknown) => error as PushedRequestUriError);
      const mismatched = await resolvePushedRequestUri({
        params: { client_id: 'other-app', request_uri: REQUEST_URI },
        store: new SingleRecordStore(createRecord()),
        now: new Date('2026-07-29T00:00:30.000Z'),
      }).catch((error: unknown) => error as PushedRequestUriError);

      expect([unknown.code, expired.code, mismatched.code]).toEqual([
        'invalid_request_uri',
        'invalid_request_uri',
        'invalid_request_uri',
      ]);
      expect([unknown.errorDescription, expired.errorDescription, mismatched.errorDescription]).toEqual([
        OPAQUE_DESCRIPTION,
        OPAQUE_DESCRIPTION,
        OPAQUE_DESCRIPTION,
      ]);
    });
  });
});

describe('assertPushedRequestUsed', () => {
  it('should pass when a URN-form request_uri is present', () => {
    expect(assertPushedRequestUsed({ client_id: 'web-app', request_uri: REQUEST_URI })).toBe(undefined);
  });

  it('should reject a request without request_uri when PAR is required', () => {
    // RFC 9126 §5: require_pushed_authorization_requests=true means the AS rejects
    // authorization requests that were not pushed.
    expect(() => assertPushedRequestUsed({ client_id: 'web-app', response_type: 'code' })).toThrowError(
      new PushedRequestUriError('invalid_request', 'Pushed authorization requests are required by this authorization server'),
    );
  });

  it('should reject a URL-form request_uri when PAR is required', () => {
    expect(() =>
      assertPushedRequestUsed({ client_id: 'web-app', request_uri: 'https://client.example/request.jwt' }),
    ).toThrowError(
      new PushedRequestUriError('invalid_request', 'Pushed authorization requests are required by this authorization server'),
    );
  });
});

describe('PushedRequestUriError', () => {
  it('should sanitize the error description to the RFC 6749 §5.2 character set', () => {
    expect(new PushedRequestUriError('invalid_request_uri', 'bad "quoted"\nvalue').errorDescription).toBe(
      'bad ?quoted??value',
    );
  });

  it('should expose the error code used by the authorization endpoint', () => {
    expect(new PushedRequestUriError('invalid_request_uri', OPAQUE_DESCRIPTION).code).toBe(
      'invalid_request_uri',
    );
  });
});
```

## CLI integration and the generated-code contribution

The experimental package is the logic layer; the PAR HTTP endpoint itself is implemented by CLI-generated code.
That code is extracted by the CLI from `src/oidc-provider/` of [apps/hono](../../../apps/hono), an app that runs with every feature enabled.
Running `maronn-oidc generate <framework> --enable par` adds three things to the generated code:

- **the directory `features/par/`**: every file PAR owns. Its `feature.ts` declares the feature with `defineFeature()` and plugs into the base through hooks: `routes` adds `POST /par` (any other method is answered with 405, CORS is the protected policy of the token endpoint), `discovery` adds `pushed_authorization_request_endpoint`, and `context` puts `parStore` into the request context
- **two lines of `features/enabled.ts`**: the import of `par` and its entry in the list `features`
- **one owner block in `endpoints/authorize/pipeline.ts`**: the `[resolve-pushed-request]` block expands a URN-form `request_uri` into the pushed parameters, between the base `[parse-request]` and `[resolve-client]` blocks. The import of the step it calls is added at the top of that file

Hooks carry declarative values that the base reads at fixed places: routes, metadata, values of the request context.
Logic that runs in the middle of a base pipeline is not a hook; it sits in that pipeline as a block that starts with a marker comment naming the feature.
The marker comment starts with `// [step-id] (feature: <feature-id>)`, and the block runs to the line before the next marker.
Such a block is called an **owner block**.
When the provider is generated without `--enable par`, the CLI deletes the PAR block and the imports only that block used.
The PAR block only reassigns `params`, which the base declares, so the rest of the pipeline runs unchanged without it.

Summarized as request paths: `POST /par` reaches `parApp` (`features/par/endpoints/par/pipeline.ts`), which `app.ts` mounts at `/par` from the `routes` hook, and runs "parse the body → authenticate the client → validate the authorization request → store → 201".
`GET /authorize` runs through the base `endpoints/authorize/pipeline.ts`: "parse the request → (the PAR block) the mandatory-PAR guard when PAR is required, then the URN expansion → the ordinary authorization processing".
At discovery, `discoveryOf()` of `features/feature.ts` adds the values of the PAR `discovery` hook to the metadata the base `build-metadata` step builds.

Three design decisions shape this layout.

First, the `request_uri` expansion is an owner block because its position matters.
Resolving the client, verifying a Request Object, settling `redirect_uri` and validating the parameters must all read the expanded parameters.
The expansion therefore has to run right after `[parse-request]` and before `[resolve-client]`, a position that a declarative hook value cannot express.
A step placed as a block appears as a box in the `maronn-oidc graph` diagram, and since its meta says `removable: false`, a `--flow` document cannot leave this step out while keeping PAR.

Second, `parStore` is not added to the base stores (`ProviderStores` of `store.ts`); it lives in the feature's directory and reaches the request context through the `context` hook.
The `store-request` step of the PAR endpoint and the `resolve-pushed-request` step of the authorization endpoint both read the same store with `c.get('parStore')`.
The base never names it, so generating without PAR removes the store's type and instance together with the directory, and leaves no unused member in the base.
The trade-off is that this store is not part of the database chosen with `--db`.
The default implementation is an in-process Map, so a production deployment that runs several instances replaces `features/par/store.ts` with a persistent implementation.

Third, the settings are gathered in `parConfig` of `features/par/config.ts` and validated with `assertParExpiresInSeconds` at module load.
A `request_uri` lifetime outside the range §2.2 recommends (5 to 600 seconds) makes the OP fail while loading, before it serves a request.
`requirePushedAuthorizationRequests` defaults to `false`, so authorization requests that did not go through PAR keep being accepted.
Set to `true`, it makes the `resolve-pushed-request` step apply the mandatory-PAR guard, and discovery advertises `require_pushed_authorization_requests: true`.

Among the samples, only [samples/hono-cloudflare](../../../samples/hono-cloudflare) enables this feature.
Its `src/oidc-provider/` shows the generated code combined with the other features.
The sample's `src/app.ts` leaves the PAR settings alone and runs with the generated defaults.

### The generated code in full (hono)

The following is everything PAR adds to the hono output generated with the default features plus `--enable par`.
For `features/enabled.ts` and the authorization endpoint's pipeline it shows the lines and the block that are added; for `features/par/` it shows every file in full, copied as generated.

#### The lines added to `features/enabled.ts`

`features/enabled.ts` lists the features of the OP.
The CLI writes one import and one entry of the array `features` for each enabled feature.
The order of the array is the order in which the hooks apply; PAR comes after the default features (`pkce` through `request-object`).

```typescript
import { par } from './par/feature.js';
```

```typescript
  par,
```

#### The lines added to `endpoints/authorize/endpoint.ts`

`endpoints/authorize/endpoint.ts` describes the steps of the authorization endpoint and the edges between them; `maronn-oidc graph` draws its diagram and `--flow` checks a flow document from this description.
Its `steps` hold the line of the `par` step.
When the provider is generated without `par`, the CLI removes these lines, so the output's `endpoint.ts` lists only the steps the output has.

```typescript
    'resolve-pushed-request',
```

#### The `(feature: par)` block of `endpoints/authorize/pipeline.ts`

The authorization endpoint's pipeline imports the PAR step the block calls at the top of the file.

```typescript
import { resolvePushedAuthorizationRequest } from '../../features/par/steps/resolve-pushed-request.js';
```

The block runs right after the `[parse-request]` block and right before the `[resolve-client]` block.
It passes the `params` that `parse-request` produced to `resolvePushedAuthorizationRequest()`, which replaces them with the pushed parameters when `request_uri` is in URN form.
Otherwise `params` comes back unchanged, so an authorization request that does not use PAR proceeds as before.

```typescript
    // [resolve-pushed-request] (feature: par) Expand the pushed request_uri — RFC 9126 §4 / §5
    params = await resolvePushedAuthorizationRequest(c, params);
```

#### `features/par/feature.ts`

This file declares what PAR plugs into the base, and it is the file `features/enabled.ts` imports.
`routes` has `parApp` mounted at `/par`, other methods refused with 405, and the protected CORS policy of the token endpoint applied.
`discovery` returns the RFC 9126 §5 metadata and advertises `require_pushed_authorization_requests` only while PAR is enforced (its default when omitted is `false`).
`context` puts `parStore` into the request context, so the steps of the PAR endpoint and of the authorization endpoint read the same store.

```typescript
import { defineFeature } from '../feature.js';
import { parConfig } from './config.js';
import { parApp } from './endpoints/par/pipeline.js';
import { parStore } from './store.js';

/**
 * EXPERIMENTAL — Pushed Authorization Requests (RFC 9126): POST /par, and the
 * resolve-pushed-request block of endpoints/authorize/pipeline.ts, which
 * expands a URN request_uri into the pushed parameters. Settings are in
 * config.ts.
 *
 * Backed by @maronn-openid-connect/experimental, whose API is NOT stable: it
 * may change in a breaking way between releases.
 */
export const par = defineFeature({
  id: 'par',
  routes: [{ path: '/par', app: parApp, methods: ['POST'], cors: 'protected' }],
  // RFC 9126 §5 metadata. require_pushed_authorization_requests is only
  // advertised when PAR is actually enforced (its default is false).
  discovery: (issuer) => ({
    pushed_authorization_request_endpoint: `${issuer}/par`,
    ...(parConfig.requirePushedAuthorizationRequests ? { require_pushed_authorization_requests: true } : {}),
  }),
  context: { parStore },
});
```

#### `features/par/config.ts`

The PAR settings, read by the `store-request` step, the `resolve-pushed-request` step and the `discovery` hook of `feature.ts`.
`expiresInSeconds` is the `request_uri` lifetime; the `assertParExpiresInSeconds` call at the end rejects a value outside the §2.2 recommendation at module load.
`requirePushedAuthorizationRequests` is the §5 enforcement switch and defaults to `false`.
Neither is an option of `createApp()`, so changing them means editing the values in this file.

```typescript
import { assertParExpiresInSeconds } from '@maronn-openid-connect/experimental/par';

/**
 * PAR settings, read by the par endpoint and the resolve-pushed-request step
 * of the authorization endpoint.
 *
 * - expiresInSeconds: request_uri lifetime. RFC 9126 §2.2 recommends 5–600
 *   seconds; values outside that range fail fast at module load.
 * - requirePushedAuthorizationRequests: RFC 9126 §5. When true, /authorize
 *   rejects any request that did not go through this endpoint, and discovery
 *   advertises require_pushed_authorization_requests: true.
 */
export const parConfig = {
  expiresInSeconds: 60,
  requirePushedAuthorizationRequests: false,
};

assertParExpiresInSeconds(parConfig.expiresInSeconds);
```

#### `features/par/store.ts`

Where the pushed requests are kept: an in-memory implementation of the experimental `PushedAuthorizationRequestStore` contract and its instance `parStore`.
`consume` reads and deletes in one operation and deletes the record whether or not it has expired, so presenting the same reference a second time never expands it (single use, §7.3).
The instance is kept on `globalThis` so that the step that stores a push and the step that expands it see the same store even when a module is loaded twice, as during dev-mode hot reloads.
Records do not outlive the process, so in production `save` and `consume` are reimplemented on Redis, KV, a database or the like.
That `consume` must fetch and delete atomically, and must bind `requestUri` as a parameter rather than interpolating it into a query.

```typescript
import type {
  PushedAuthorizationRecord,
  PushedAuthorizationRequestStore,
} from '@maronn-openid-connect/experimental/par';

/**
 * EXPERIMENTAL — in-memory Pushed Authorization Request store (RFC 9126).
 *
 * Replace with a persistent store (Redis, KV, database) in production. The
 * contract is only two methods:
 *
 * - save(record): persist the pushed request, ideally with a TTL matching
 *   record.expiresAt so entries cannot pile up (RFC 9126 §7.3).
 * - consume(requestUri): fetch AND delete in one atomic operation. A
 *   non-atomic implementation lets the same request_uri be replayed
 *   concurrently. Treat requestUri as an opaque external value: never
 *   interpolate it into a query, always bind it as a parameter.
 */
export class InMemoryPushedAuthorizationRequestStore
  implements PushedAuthorizationRequestStore
{
  private records = new Map<string, PushedAuthorizationRecord>();

  async save(record: PushedAuthorizationRecord): Promise<void> {
    this.records.set(record.requestUri, record);
  }

  async consume(requestUri: string): Promise<PushedAuthorizationRecord | null> {
    const record = this.records.get(requestUri);
    // Single use (RFC 9126 §7.3): delete on read, expired or not, so a replay of
    // the same reference can never succeed.
    this.records.delete(requestUri);
    if (!record) {
      this.evictExpired();
      return null;
    }
    return record;
  }

  /** Drop entries whose lifetime has passed so an idle store cannot grow unbounded. */
  private evictExpired(): void {
    const now = Date.now();
    for (const [requestUri, record] of this.records) {
      if (record.expiresAt.getTime() < now) {
        this.records.delete(requestUri);
      }
    }
  }
}

// Kept on globalThis so every module that asks for the store gets the same one,
// also where a framework loads a module more than once (dev-mode hot reloads,
// separate module layers).
const parStoreRegistry = globalThis as typeof globalThis & {
  __oidcPushedAuthorizationRequestStore?: PushedAuthorizationRequestStore;
};

export const parStore: PushedAuthorizationRequestStore =
  (parStoreRegistry.__oidcPushedAuthorizationRequestStore ??=
    new InMemoryPushedAuthorizationRequestStore());
```

#### `features/par/endpoints/par/pipeline.ts`

The `POST /par` handler; it calls the steps of the PAR endpoint in spec order.
Each block is one box of the `maronn-oidc graph --detail steps --endpoint par` diagram, and `respondParError()` turns a failure of any step into the OAuth error response.
As the header comment says, the §2.3 status codes 413 (request too large) and 429 (rate limiting) are left to the reverse proxy or the platform.
Anyone can call the endpoint until the client credentials are checked, so a production deployment puts a rate limit in front of it.

```typescript
import { Hono } from 'hono';
import { authenticatePushingClient } from './steps/authenticate-client.js';
import { parsePushedAuthorizationRequest } from './steps/parse-request.js';
import { respondParError } from './steps/respond-error.js';
import { respondPar } from './steps/respond.js';
import { storePushedRequest } from './steps/store-request.js';
import { validatePushedRequest } from './steps/validate-request.js';

/**
 * EXPERIMENTAL — Pushed Authorization Requests (RFC 9126).
 *
 * This endpoint was generated because the OP was created with `--enable par`.
 * It is backed by @maronn-openid-connect/experimental, whose API is NOT stable: it may
 * change in a breaking way between releases. Do not build production code on it
 * without pinning the version.
 *
 * The client POSTs the authorization request parameters here (back channel,
 * authenticated) and receives a short-lived `request_uri` reference that it
 * then passes to /authorize. Each block below calls one step (one box of
 * `maronn-oidc graph --detail steps --endpoint par`).
 *
 * NOTE (RFC 9126 §2.3): request size limits (413) and rate limiting (429) are
 * deliberately left to the deployment layer (reverse proxy / platform), not
 * implemented here. This endpoint is unauthenticated until the client
 * credentials are checked, so put a rate limit in front of it in production.
 */
export const parApp = new Hono<{ Variables: Record<string, any> }>();

parApp.post('/', async (c) => {
  try {
    // [parse-request] Parse the pushed authorization request — RFC 9126 §2.1 / RFC 6749 §3.1
    const { params, authorization } = await parsePushedAuthorizationRequest(c);

    // [authenticate-client] Authenticate the pushing client — RFC 9126 §2.1
    const { clientId, pushedParams } = await authenticatePushingClient(c, params, authorization);

    // [validate-request] Validate the request as /authorize would — RFC 9126 §2.1
    await validatePushedRequest(c, pushedParams);

    // [store-request] Store the request under a fresh request_uri — RFC 9126 §2.2 / §7.1
    const parResponse = await storePushedRequest(c, clientId, pushedParams);

    // [respond] Respond 201 (no-store) — RFC 9126 §2.2
    return respondPar(c, parResponse);
  } catch (error) {
    return respondParError(c, error);
  }
});
```

#### `features/par/endpoints/par/endpoint.ts`

The meta of the PAR endpoint, from which `maronn-oidc graph` draws it.
`steps` is the order of the steps, `errorStep` the step every failure ends in, and `journeys` the arrow from `/par` to `/authorize` that carries the `request_uri`.
With `rearrangeable: true`, a `--flow` document may reorder its steps.

```typescript
import { defineEndpoint } from '../../../../endpoints/step.js';

/** EXPERIMENTAL — the pushed authorization request endpoint. RFC 9126 §2 */
export const endpoint = defineEndpoint({
  id: 'par',
  order: 110,
  label: 'Pushed authorization request endpoint',
  path: '/par',
  methods: ['POST'],
  layer: 'api',
  group: { id: 'pushed-authorization', label: 'Pushed Authorization Requests (RFC 9126)' },
  spec: 'RFC 9126 §2',
  feature: 'par',
  rearrangeable: true,
  steps: [
    'parse-request',
    'authenticate-client',
    'validate-request',
    'store-request',
    'respond',
    'respond-error',
  ],
  errorStep: 'respond-error',
  edges: {
    chain: true,
  },
  journeys: [
    { from: 'par', to: 'authorize', label: 'request_uri', kind: 'flow', order: 10 },
  ],
});
```

#### `features/par/endpoints/par/response.ts`

Defines the shape of the PAR endpoint's answer, `ParEndpointResponse`, and `ParEndpointError`, the exception a step throws to answer with a fixed response.
Where the experimental `ParError` stands for a failed RFC 9126 validation, `ParEndpointError` stands for failures the generated code decides itself (a wrong Content-Type, a repeated parameter).

```typescript
/**
 * What the pushed authorization request endpoint answers, and the failure a
 * step answers with a fixed response.
 */

/** What the pushed authorization request endpoint answers; respondPar() turns it into HTTP. */
export interface ParEndpointResponse {
  status: number;
  body: object;
  headers?: Record<string, string>;
}

/** A failure a step answers with a fixed response (a malformed request). */
export class ParEndpointError extends Error {
  constructor(readonly response: ParEndpointResponse) {
    const details = (response.body ?? {}) as { error?: unknown; error_description?: unknown };
    super(String(details.error_description ?? details.error ?? 'pushed authorization request endpoint error'));
    this.name = 'ParEndpointError';
  }
}
```

#### `features/par/endpoints/par/steps/parse-request.ts`

The step that reads the body and the `Authorization` header.
§2.1 restricts the body to `application/x-www-form-urlencoded`, so any other Content-Type is rejected with `invalid_request`.
The body is read raw with `c.req.text()` so that iterating `URLSearchParams` exposes repeated parameters (RFC 6749 §3.1).
A parsed form keeps only the last value of a name, which would hide the repetition.
The parameter name put into the error message passes through `sanitizeErrorDescription`.

```typescript
import { sanitizeErrorDescription } from '@maronn-openid-connect/core';
import { ParEndpointError } from '../response.js';
import { step } from '../../../../../endpoints/step.js';

export const meta = step({
  id: 'parse-request',
  endpoint: 'par',
  feature: 'par',
  kind: 'parse',
  label: 'Parse the pushed authorization request',
  spec: 'RFC 9126 §2.1 / RFC 6749 §3.1',
  function: 'parsePushedAuthorizationRequest',
  consumes: [],
  produces: ['params', 'authorization'],
  removable: false,
});

/**
 * RFC 9126 §2.1: the pushed authorization request body MUST be
 * application/x-www-form-urlencoded.
 */
function isFormUrlEncoded(contentType: string): boolean {
  const [mediaType = ''] = contentType.toLowerCase().split(';');
  return mediaType.trim() === 'application/x-www-form-urlencoded';
}

/**
 * Parse the pushed authorization request: the form body and the Authorization
 * header. RFC 9126 §2.1 / RFC 6749 §3.1
 */
export async function parsePushedAuthorizationRequest(
  c: any,
): Promise<{ params: Record<string, string>; authorization: string }> {
  const contentType = c.req.header('Content-Type') ?? '';
  if (!isFormUrlEncoded(contentType)) {
    throw new ParEndpointError({
      status: 400,
      body: { error: 'invalid_request', error_description: 'Pushed authorization requests must use application/x-www-form-urlencoded' },
    });
  }

  // RFC 6749 §3.1: request parameters MUST NOT be repeated. Read the raw body so
  // URLSearchParams iteration exposes duplicates instead of silently keeping the last.
  const rawBody = await c.req.text();
  const params: Record<string, string> = {};
  const seen = new Set<string>();
  let duplicateKey: string | undefined;
  for (const [key, value] of new URLSearchParams(rawBody)) {
    if (seen.has(key)) {
      duplicateKey = key;
      break;
    }
    seen.add(key);
    params[key] = value;
  }

  if (duplicateKey !== undefined) {
    throw new ParEndpointError({
      status: 400,
      body: { error: 'invalid_request', error_description: `Parameter "${sanitizeErrorDescription(duplicateKey)}" must not be repeated` },
    });
  }

  const authorization = c.req.header('Authorization') ?? '';
  return { params, authorization };
}
```

#### `features/par/endpoints/par/steps/authenticate-client.ts`

The step that authenticates the pushing client exactly as the token endpoint does (a public client presents only `client_id`).
Before authenticating, `rejectForbiddenParParams` refuses `request_uri`, which a pushed request must not carry (§2.1), and `request`, since this generated OP does not combine PAR with JAR (§3).
Once the client is authenticated, `client_id` is overwritten with the authenticated value, which binds the following validation and storage to that client.

```typescript
import { authenticateParClient, rejectForbiddenParParams } from '@maronn-openid-connect/experimental/par';
import { step } from '../../../../../endpoints/step.js';

export const meta = step({
  id: 'authenticate-client',
  endpoint: 'par',
  feature: 'par',
  kind: 'validate',
  label: 'Authenticate the pushing client',
  spec: 'RFC 9126 §2.1',
  function: 'authenticatePushingClient',
  calls: ['rejectForbiddenParParams', 'authenticateParClient'],
  consumes: ['params', 'authorization'],
  produces: ['clientId', 'pushedParams'],
  removable: false,
});

/**
 * Authenticate the pushing client exactly like the token endpoint does
 * (public clients present only client_id), after refusing the parameters a
 * pushed request must not carry. RFC 9126 §2.1
 *
 * client_id is a required authorization request parameter, so the pushed
 * parameters are pinned to the authenticated client before validation.
 */
export async function authenticatePushingClient(
  c: any,
  params: Record<string, string>,
  authorization: string,
): Promise<{ clientId: string; pushedParams: Record<string, string> }> {
  const clientResolver = c.get('clientResolver');

  // RFC 9126 §2.1: request_uri MUST NOT be pushed. The request parameter
  // (PAR + JAR, §3) is not supported by this generated provider.
  rejectForbiddenParParams(params);

  const clientId = await authenticateParClient({
    params,
    authorizationHeader: authorization,
    clientResolver,
  });

  return { clientId, pushedParams: { ...params, client_id: clientId } };
}
```

#### `features/par/endpoints/par/steps/validate-request.ts`

Following §2.1, this step validates the request at push time the same way the authorization endpoint would.
An unregistered `redirect_uri` or a bad `scope` fails here, before the user sees any screen.
Whether PKCE may be omitted follows the base setting `allowNonPkceAuthorizationCodeFlow`, which is `false` (PKCE required) in the default generation, where the `pkce` feature is enabled.

```typescript
import { validatePushedAuthorizationParams } from '@maronn-openid-connect/experimental/par';
import { step } from '../../../../../endpoints/step.js';

export const meta = step({
  id: 'validate-request',
  endpoint: 'par',
  feature: 'par',
  kind: 'validate',
  label: 'Validate the request as /authorize would',
  spec: 'RFC 9126 §2.1',
  function: 'validatePushedRequest',
  calls: ['validatePushedAuthorizationParams'],
  consumes: ['pushedParams'],
  produces: [],
  removable: false,
});

/**
 * RFC 9126 §2.1: "validate the request the same way the authorization
 * endpoint would" — an unregistered redirect_uri or a bad scope fails here,
 * before the user ever sees a screen.
 */
export async function validatePushedRequest(c: any, pushedParams: Record<string, string>): Promise<void> {
  const clientResolver = c.get('clientResolver');
  const config = c.get('config');
  await validatePushedAuthorizationParams(pushedParams, clientResolver, {
    allowNonPkceAuthorizationCodeFlow: config.allowNonPkceAuthorizationCodeFlow,
  });
}
```

#### `features/par/endpoints/par/steps/store-request.ts`

The step that mints a cryptographically random reference and stores the pushed parameters under it (§2.2 and §7.1).
Creating the record is left to the experimental `createPushedAuthorizationRecord`, which receives the authenticated `client_id`, the parameters, `parStore` and `parConfig.expiresInSeconds`.
The experimental side strips the client credentials (`client_secret` and the like), so they never reach the store.
The answer is the §2.2 201 with only `request_uri` and `expires_in` in the body.
The pushed parameters can carry personal data such as `login_hint`, so they are not logged.

```typescript
import {
  buildPushedAuthorizationResponse,
  createPushedAuthorizationRecord,
} from '@maronn-openid-connect/experimental/par';
import type { ParEndpointResponse } from '../response.js';
import { parConfig } from '../../../config.js';
import { step } from '../../../../../endpoints/step.js';

export const meta = step({
  id: 'store-request',
  endpoint: 'par',
  feature: 'par',
  kind: 'persist',
  label: 'Store the request under a fresh request_uri',
  spec: 'RFC 9126 §2.2 / §7.1',
  function: 'storePushedRequest',
  calls: ['createPushedAuthorizationRecord', 'buildPushedAuthorizationResponse'],
  consumes: ['clientId', 'pushedParams'],
  produces: ['parResponse'],
  removable: false,
});

/**
 * RFC 9126 §2.2 / §7.1: mint a cryptographically random reference value and
 * store the request under it. Client credentials are never persisted.
 */
export async function storePushedRequest(
  c: any,
  clientId: string,
  pushedParams: Record<string, string>,
): Promise<ParEndpointResponse> {
  const parStore = c.get('parStore');
  const record = await createPushedAuthorizationRecord({
    clientId,
    params: pushedParams,
    store: parStore,
    expiresInSeconds: parConfig.expiresInSeconds,
  });
  const response = buildPushedAuthorizationResponse(record);

  // Never log the pushed parameters themselves: they can carry PII such as
  // login_hint, and the Authorization header carries the client_secret.

  // RFC 9126 §2.2: 201 Created.
  return { status: 201, body: { request_uri: response.requestUri, expires_in: response.expiresIn } };
}
```

#### `features/par/endpoints/par/steps/respond.ts`

Success and failure alike end in this function, which turns the answer into HTTP.
The JSON is answered as non-cacheable, matching §2.2, with `Cache-Control: no-cache, no-store` and `Pragma: no-cache`.
Additional headers such as `WWW-Authenticate` are copied from `ParEndpointResponse.headers`.

```typescript
import type { ParEndpointResponse } from '../response.js';
import { step } from '../../../../../endpoints/step.js';

export const meta = step({
  id: 'respond',
  endpoint: 'par',
  feature: 'par',
  kind: 'respond',
  label: 'Respond 201 (no-store)',
  spec: 'RFC 9126 §2.2',
  function: 'respondPar',
  consumes: ['parResponse'],
  produces: [],
  removable: false,
});

/** RFC 9126 §2.2: a non-cacheable JSON body. */
export function respondPar(c: any, response: ParEndpointResponse): Response {
  c.header('Cache-Control', 'no-cache, no-store');
  c.header('Pragma', 'no-cache');
  for (const [name, value] of Object.entries(response.headers ?? {})) {
    c.header(name, value);
  }
  return c.json(response.body, response.status);
}
```

#### `features/par/endpoints/par/steps/respond-error.ts`

The step that turns a failure of any step into a JSON error of the token endpoint's shape (§2.3).
This endpoint never redirects.
A `ParEndpointError` is answered with the response it carries, an experimental `ParError` with its status code, error code and `WWW-Authenticate`, and any other exception with `server_error` (500).

```typescript
import { ParError } from '@maronn-openid-connect/experimental/par';
import { ParEndpointError } from '../response.js';
import { respondPar } from './respond.js';
import { step } from '../../../../../endpoints/step.js';

export const meta = step({
  id: 'respond-error',
  endpoint: 'par',
  feature: 'par',
  kind: 'respond',
  label: 'Respond with the OAuth error',
  spec: 'RFC 9126 §2.3',
  function: 'respondParError',
  consumes: [],
  produces: [],
  removable: false,
});

/**
 * RFC 9126 §2.3: token-endpoint style JSON errors. This endpoint never redirects.
 */
export function respondParError(c: any, error: unknown): Response {
  if (error instanceof ParEndpointError) {
    return respondPar(c, error.response);
  }
  if (error instanceof ParError) {
    return respondPar(c, {
      status: error.statusCode,
      body: { error: error.code, error_description: error.errorDescription },
      headers: error.wwwAuthenticate ? { 'WWW-Authenticate': error.wwwAuthenticate } : undefined,
    });
  }
  return respondPar(c, { status: 500, body: { error: 'server_error' } });
}
```

#### `features/par/steps/resolve-pushed-request.ts`

The step the owner block of the authorization endpoint calls; of the PAR code, this file is the only one that runs inside a base pipeline.
`endpoint: 'authorize'` and `feature: 'par'` in its `meta` say which endpoint runs it and which feature owns it.
When PAR is mandatory it first applies `assertPushedRequestUsed`, then expands a URN-form `request_uri` with `resolvePushedRequestUri`.
For anything that is not a URN, `null` comes back and the step returns the `params` it received (a URL-form `request_uri` is rejected later with `request_uri_not_supported`).
A `PushedRequestUriError` from a failed expansion becomes a core `AuthorizationError` without a `redirect_uri`.
The failure happened before any `redirect_uri` was verified, so `authorizationErrorOutcome()` does not redirect it and answers it as an error on the OP.
Every kind of failure (unknown, used, expired, client mismatch) carries the same code and message, so the response does not reveal whether the reference existed.

```typescript
import { AuthorizationError, type AuthorizationErrorCode } from '@maronn-openid-connect/core';
import {
  PushedRequestUriError,
  assertPushedRequestUsed,
  resolvePushedRequestUri,
} from '@maronn-openid-connect/experimental/par';
import { parConfig } from '../config.js';
import { type AuthorizationRequestInput, isAuthorizationRequestParams } from '../../../endpoints/authorize/outcome.js';
import { step } from '../../../endpoints/step.js';

export const meta = step({
  id: 'resolve-pushed-request',
  endpoint: 'authorize',
  feature: 'par',
  kind: 'resolve',
  label: 'Expand the pushed request_uri',
  spec: 'RFC 9126 §4 / §5',
  function: 'resolvePushedAuthorizationRequest',
  calls: ['assertPushedRequestUsed', 'resolvePushedRequestUri'],
  consumes: ['params'],
  produces: ['params'],
  removable: false,
});

/**
 * EXPERIMENTAL — Pushed Authorization Requests (RFC 9126 §4 / §5).
 *
 * Expands a request_uri of the form urn:ietf:params:oauth:request_uri:<ref>
 * into the parameters pushed to /par. The reference is single use and short
 * lived, so a reload of this URL fails with invalid_request_uri by design.
 * Anything that is not a URN (absent, or an OIDC Core §6.2 URL) is left to the
 * normal pipeline, which rejects it with request_uri_not_supported.
 *
 * A request_uri that does not resolve fails with an AuthorizationError that
 * authorizationErrorOutcome() keeps on the OP: without a resolved request
 * there is no verified redirect_uri.
 */
export async function resolvePushedAuthorizationRequest(
  c: any,
  params: AuthorizationRequestInput,
): Promise<AuthorizationRequestInput> {
  const parStore = c.get('parStore');
  try {
    // RFC 9126 §5: when require_pushed_authorization_requests is on, an
    // authorization request that did not go through /par is rejected outright.
    if (parConfig.requirePushedAuthorizationRequests) {
      assertPushedRequestUsed(params);
    }
    const pushedParams = await resolvePushedRequestUri({ params, store: parStore });
    if (pushedParams === null) return params;
    if (!isAuthorizationRequestParams(pushedParams)) {
      // Defensive: client_id was validated when the request was pushed.
      throw new PushedRequestUriError('invalid_request_uri', 'The request_uri is invalid, expired, or has already been used');
    }
    return pushedParams;
  } catch (error) {
    // RFC 9126 §4 / OIDC Core 1.0 §3.1.2.6: a request_uri that cannot be
    // resolved leaves us without a verified redirect_uri, so this error is
    // NEVER redirected (RFC 6749 §4.1.2.1): an AuthorizationError without a
    // redirect URI stays on the OP. Every failure kind (unknown / used /
    // expired / wrong client) carries the identical code and description so
    // the response cannot be used as an existence oracle.
    if (error instanceof PushedRequestUriError) {
      throw new AuthorizationError(error.code as AuthorizationErrorCode, error.errorDescription);
    }
    throw error;
  }
}
```

### The other frameworks

The express and fastify outputs consist of the same files as hono.
The CLI replaces the `hono` router the endpoints import with `web-router.ts`, a small Fetch-API router (`WebRouter` and `WebContext`), and adds the framework's `apply.ts`, `web-router.ts` and `node-adapter.ts`.
The added files come from [apps/hono/src/web/](../../../apps/hono/src/web), and [packages/cli/extract.json](../../../packages/cli/extract.json) defines which file goes where.
The screens stay hono/jsx, so those outputs need `hono` as their JSX runtime.
Within `features/par/`, the only difference is that `Hono` becomes `WebRouter` in `features/par/endpoints/par/pipeline.ts`; every other file is the same as for hono.

The Next.js output is extracted from [apps/nextjs](../../../apps/nextjs), a Next.js App Router app.
The route files of PAR live in the route group `app/(par)/`, and the rest of its code in `app/_oidc-provider/features/par/`.
Neither is embedded in this guide; the directory is linked instead.

## The E2E test, in full

The E2E test drives a real browser against a really running OP and runs only against OPs generated with `--enable par` (it skips when discovery does not advertise the PAR endpoint).
It pins down:

- the full flow through a pushed `request_uri` (the browser carries only `client_id` and `request_uri`; the consent screen shows the pushed scope)
- rejection of a second use of the same `request_uri` (single use)
- rejection of an unauthenticated pushed request
- rejection of an unknown `request_uri` without redirecting

The E2E client (`tests/e2e/apps/client.mjs`) is harness shared by all features, so it is linked rather than embedded.

```typescript
import { expect, test } from '@playwright/test';

const host = process.env.E2E_HOST ?? '127.0.0.1';
const clientPort = Number(process.env.E2E_CLIENT_PORT ?? '3020');
const clientBaseURL =
  process.env.E2E_CLIENT_BASE_URL ?? `http://${host}:${clientPort}`;
const clientId = 'e2e-client';
const clientSecret = 'e2e-client-secret';
const REQUEST_URI_PREFIX = 'urn:ietf:params:oauth:request_uri:';

/**
 * EXPERIMENTAL — Pushed Authorization Requests (RFC 9126).
 *
 * Only the samples generated with `--enable par` expose the endpoint, so every
 * test here skips when discovery does not advertise it. That keeps the shared
 * spec suite green across all sample OPs.
 */
test.describe('Pushed Authorization Requests (RFC 9126)', () => {
  test('should complete the full flow with a pushed request_uri', async ({
    page,
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const parEndpoint = await pushedAuthorizationEndpoint(request, issuer);
    test.skip(parEndpoint === undefined, 'This sample OP was generated without --enable par');
    expect(parEndpoint).toBe(`${issuer}/par`);

    const redirectUri = `${clientBaseURL}/callback`;

    await page.goto(`${clientBaseURL}/start-par`);
    // The browser only ever carried client_id and request_uri to the OP.
    await expect(page).toHaveURL(new RegExp(`^${escapeRegExp(issuer)}/login\\?transaction_id=`));

    await page.getByLabel('Username:').fill('testuser');
    await page.getByLabel('Password:').fill('password');
    await page.getByRole('button', { name: 'Login' }).click();
    await expect(page).toHaveURL(new RegExp(`^${escapeRegExp(issuer)}/consent\\?transaction_id=`));
    await expect(page.locator('strong')).toHaveText(clientId);
    // The consent screen shows the scope that was pushed, not one from the URL.
    await expect(page.locator('li')).toHaveText(['openid', 'profile', 'email']);

    await page.getByRole('button', { name: 'Approve' }).click();
    await expect(page).toHaveURL(new RegExp(`^${escapeRegExp(redirectUri)}\\?`));

    // The code exchange succeeded, so the OP issued tokens from the pushed request.
    await expect(page.getByTestId('token-type')).toHaveText('Bearer');
    await expect(page.getByTestId('userinfo-sub')).toHaveText('testuser');
    const callbackUrl = new URL(page.url());
    expect(callbackUrl.searchParams.get('iss')).toBe(issuer);
  });

  test('should return a single-use request_uri that cannot be replayed', async ({
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const parEndpoint = await pushedAuthorizationEndpoint(request, issuer);
    test.skip(parEndpoint === undefined, 'This sample OP was generated without --enable par');

    const pushResponse = await request.post(`${issuer}/par`, {
      form: pushedRequestForm(),
    });
    expect(pushResponse.status()).toBe(201);
    expect(pushResponse.headers()['cache-control']).toBe('no-cache, no-store');
    const pushed = await pushResponse.json() as { request_uri: string; expires_in: number };
    expect(pushed.expires_in).toBe(60);
    expect(pushed.request_uri.startsWith(REQUEST_URI_PREFIX)).toBe(true);

    const authorizeUrl =
      `${issuer}/authorize?client_id=${clientId}&request_uri=` +
      encodeURIComponent(pushed.request_uri);
    const first = await request.get(authorizeUrl, { maxRedirects: 0 });
    expect(first.status()).toBe(302);

    // RFC 9126 §7.3: the reference is single use.
    const replay = await request.get(authorizeUrl, {
      maxRedirects: 0,
      headers: { Accept: 'application/json' },
    });
    expect(replay.status()).toBe(400);
    expect(replay.headers()['location']).toBe(undefined);
    expect(await replay.json()).toEqual({
      error: 'invalid_request_uri',
      error_description: 'The request_uri is invalid, expired, or has already been used',
    });
  });

  test('should reject an unauthenticated pushed request', async ({ request, baseURL }) => {
    const issuer = requireBaseUrl(baseURL);
    const parEndpoint = await pushedAuthorizationEndpoint(request, issuer);
    test.skip(parEndpoint === undefined, 'This sample OP was generated without --enable par');

    const form = pushedRequestForm();
    delete form.client_secret;
    const response = await request.post(`${issuer}/par`, { form });

    expect(response.status()).toBe(401);
    expect((await response.json()).error).toBe('invalid_client');
  });

  test('should reject an unknown request_uri without redirecting', async ({
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const parEndpoint = await pushedAuthorizationEndpoint(request, issuer);
    test.skip(parEndpoint === undefined, 'This sample OP was generated without --enable par');

    const response = await request.get(
      `${issuer}/authorize?client_id=${clientId}&request_uri=` +
        encodeURIComponent(`${REQUEST_URI_PREFIX}never-issued-reference`),
      { maxRedirects: 0, headers: { Accept: 'application/json' } },
    );

    expect(response.status()).toBe(400);
    expect(response.headers()['location']).toBe(undefined);
    expect(await response.json()).toEqual({
      error: 'invalid_request_uri',
      error_description: 'The request_uri is invalid, expired, or has already been used',
    });
  });
});

function pushedRequestForm(): Record<string, string> {
  return {
    response_type: 'code',
    client_id: clientId,
    client_secret: clientSecret,
    redirect_uri: `${clientBaseURL}/callback`,
    scope: 'openid profile email',
    state: 'e2e-par-state',
    nonce: 'e2e-par-nonce',
    // RFC 7636 Appendix B example challenge.
    code_challenge: 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
    code_challenge_method: 'S256',
  };
}

async function pushedAuthorizationEndpoint(
  request: { get(url: string): Promise<{ json(): Promise<unknown> }> },
  issuer: string,
): Promise<string | undefined> {
  const response = await request.get(`${issuer}/.well-known/openid-configuration`);
  const metadata = await response.json() as {
    pushed_authorization_request_endpoint?: string;
  };
  return metadata.pushed_authorization_request_endpoint;
}

function requireBaseUrl(baseURL: string | undefined): string {
  if (baseURL === undefined) {
    throw new Error('baseURL is not configured');
  }
  return baseURL;
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}
```

## Related material

- User-facing documentation: [docs/library-document experimental/par.md](../../library-document/src/content/docs/experimental/par.md)
- Specification study documents: [tasks/experimental/done/par/](../../../tasks/experimental/done/par/) (specification.md / understanding-guide.md / review-log.md)
- Promotion-review packet: [tasks/experimental/done/par/promotion-review/](../../../tasks/experimental/done/par/promotion-review/README.md)
- Package-wide conventions: [package-overview.en.md](./package-overview.en.md)
- 日本語版: [par.ja.md](./par.ja.md)
