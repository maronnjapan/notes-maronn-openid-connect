# Token Exchange: Implementation Guide

This document explains what was implemented for **OAuth 2.0 Token Exchange** (RFC 8693) in `packages/experimental`, and how, together with the complete source code involved.

The following code is embedded in full:

- both implementation files and the test file under `packages/experimental/src/token-exchange/`
- the complete code that `--enable token-exchange` adds to the CLI-generated output (hono), presented file by file as TypeScript
- the complete Token Exchange E2E test spec

The core package itself, the shared E2E harness, and the other frameworks' generated diffs are infrastructure shared by all features, so they are linked rather than embedded.
The embedded sources carry Japanese comments; the prose here conveys the same information.

## What the feature does

Token Exchange is a grant for presenting a token you already hold to the token endpoint and trading it for a different one.
The token being traded in is the **subject_token**, presented in a request with `grant_type=urn:ietf:params:oauth:grant-type:token-exchange`.
The OP validates the subject_token, vets the requested scope and target (audience / resource), and issues a new access token.

Why would anyone trade a token?
The typical setting is a microservice architecture: a gateway receives a user request and must call services behind it.
Forwarding the received access token as-is hands the downstream service far more authority than it needs (every scope and audience the gateway had).
With Token Exchange, the gateway can obtain from the OP a token that still acts as the user but is narrowed to exactly what the downstream call requires.

RFC 8693 §1.1 describes two shapes of exchange, and this implementation supports both.
**Impersonation** (no `actor_token`) issues a token that simply acts as the subject: the exchanged token's `sub` remains the subject_token's `sub`, and nothing in the token names the exchanging party beyond its `client_id`.
**Delegation** (`actor_token` present) also keeps `sub` unchanged, but additionally records who acts on the subject's behalf in the **act claim** (§4.1): the token now says "this is party X acting for user Y", and a chain of such exchanges nests inside `act`.

```text
Client (e.g. a gateway)                        OP
    │  POST /token (client-authenticated)        │
    │  grant_type=…:token-exchange               │
    │  subject_token=<access token in hand>      │
    │  actor_token=<the caller's own token>      │ (optional: delegation)
    │  scope=read  audience=https://backend.example │
    │ ─────────────────────────────────────────> │ validate subject_token
    │                                            │ (and actor_token), vet
    │  200 { access_token, issued_token_type,    │ scope narrowing & target
    │        token_type, expires_in, scope }     │
    │ <───────────────────────────────────────── │
```

### Use cases

- Verifying token downscoping between microservices (narrowed tokens passed along a call chain)
- Verifying a gateway or backend obtaining a token for a specific resource server while preserving the user's subject
- Verifying a delegation design in which the token records which service acts for the user (the `act` claim, including chains)
- Designing an `allowedTargets` allow-list policy (which audiences / resources exchanges may be issued for)

### Scope and non-goals

The implementation covers:

- the full validation of the `urn:ietf:params:oauth:grant-type:token-exchange` grant (RFC 8693 §2.1)
- subject_token and actor_token resolution and validity checking (only access tokens issued by this OP)
- delegation: composing the `act` claim (§4.1), including nesting the prior chain when a delegated token is exchanged again
- scope-narrowing validation, audience / resource allow-list validation, and lifetime capping
- assembly of the §2.2.1 response body

The non-goals are deliberate:

- **token types other than access tokens**: `subject_token_type`, `actor_token_type`, and `requested_token_type` accept only `urn:ietf:params:oauth:token-type:access_token` (the reasoning follows below)
- **multiple audience / resource values**: the generated OP's token endpoint rejects duplicate parameters per RFC 6749 §3.2, so each may appear at most once

#### Why only access tokens, and where ID-token exchange belongs

RFC 8693 leaves the supported token types to the authorization server: `requested_token_type` is OPTIONAL, and an AS may support any subset of the §3 identifiers.
This implementation accepts and issues only access tokens, and it answers any other `requested_token_type` with an explicit `invalid_request` rather than ignoring the parameter.
Ignoring it would be the quieter option, but then a client that asked for an ID token would receive an access token and only notice by inspecting `issued_token_type`; an explicit error surfaces the mismatch at the request itself.
Omitting `requested_token_type` always works and yields an access token.

The exchange patterns that genuinely need other token types are planned as their own features, not as extensions of this grant.
The main one is Cross App Access (the Identity Assertion Authorization Grant pattern), where the token endpoint receives an ID token as the subject and issues a JWT assertion addressed to another authorization server.
That flow validates a different thing (an ID token signature instead of a stored access token) and issues a different thing (an assertion for another AS instead of an access token for this OP), so nearly every step of this pipeline would fork if it were bolted on here.
When that feature lands it will carry its own validation; the restriction in this grant stays.

## Design approach

The feature consists of one implementation file, its test file, and the public API file.

| File | Role |
|---|---|
| `token-exchange-request.ts` | the grant's validation pipeline (step functions and the composition function) |
| `index.ts` | public API re-exports |

The design's center of gravity is the guarantee that **an exchange only ever narrows authority**.
Four mechanisms carry it:

- the requested scope must be a subset of the subject_token's scope (`validateExchangeScope`)
- audience / resource must come from the allow-list (`allowedTargets`); when omitted, the subject's audience is inherited (`resolveExchangeTarget`)
- the lifetime is capped at `min(configured, subject_token's remaining seconds)`, so chained exchanges decrease monotonically (`computeExchangedTokenLifetime`)
- `sub` is inherited from the subject_token and cannot be changed; in a delegation the actor appears only in `act`

Two of the identifiers in that list deserve a definition, because both come from configuration or convention rather than the spec text.

`configuredExpiresIn` is the OP's configured access-token lifetime, the same ceiling every ordinary issuance gets; the generated code passes its `config.accessTokenExpiresIn` here.
An exchange never issues beyond that ceiling, and the subject_token's remaining seconds then cap it further.

`audience` and `resource` both name the party the client wants the new token issued for, and RFC 8693 §2.1 keeps them as two parameters on purpose.
`resource` takes the **location** of the target as a URI (the lineage is RFC 8707 Resource Indicators, which is where the absolute-URI-without-fragment syntax rule comes from).
`audience` takes a **logical name** of the target (whatever identifier the AS and its services have agreed on, with no syntax constraint).
A deployment that names services by URL uses `resource`; one that names them by logical identifiers uses `audience`; one request may carry both.
This implementation folds the two into a single policy: either kind of name must appear in `allowedTargets`, and the vetted values merge into the requested audience, which is why they converge in one step function (`resolveExchangeTarget`).

Delegation reuses the same skeleton.
The actor_token passes exactly the validation the subject_token does (`resolveActorToken`), and its only contribution to the issued token is the `act` claim value assembled by `composeActClaim`: the current actor's `sub` outermost and, when the subject_token itself carries an `act` (it was minted by an earlier delegation), that prior chain nested one level down, which is §4.1's ordering rule.
The actor deliberately does not cap the issued lifetime: the subject_token is the source of the authority being narrowed, while the actor_token only proves, at exchange time, that the actor holds a live token of this OP.
For the chain to survive into a later exchange, generated code persists `act` in the token's store metadata as well as in the JWT; the structural extension type `ExchangedAccessTokenInfo` carries it without changing core.

The other axis is oracle elimination.
Every subject_token resolution failure (unknown, expired, `nbf` in the future, revoked) produces the same fixed-message `invalid_request`, and actor_token failures get their own single fixed message.
The response never lets a caller infer whether a token exists or has been revoked, the same policy as PAR's `request_uri`.
Client authorization (`authorizeTokenExchangeClient`) runs first for the same reason: a client that is not allowed to exchange is never given a verdict on any token's validity.

The module issues and stores no tokens.
It returns issuance material (`TokenExchangeGrant`) and stops; generated code feeds that into core's issuance pipeline (`buildAccessTokenAudience` / `buildAccessTokenPayload` / `AccessTokenIssuer` / `accessTokenStore`).
This split keeps issuance semantics (the permanent UserInfo audience member, deduplication, the non-empty fallback) shared with the existing token route.

The dedicated error type `TokenExchangeError` exists because RFC 8693 §2.2.2 adds `invalid_target`, which core's closed `TokenErrorCode` lacks.
It is always a 400; the only 401 case, failed client authentication, is handled before this branch by the shared authentication pipeline (core's `TokenError`).

## The implementation, file by file

### token-exchange-request.ts (the grant's validation pipeline)

The step functions follow the spec's processing order (the labels mirror the comments in the code):

1. `authorizeTokenExchangeClient` checks whether the client may exchange at all. A client whose registered `grantTypes` lacks the exchange URN gets `unauthorized_client`. Public clients (`tokenEndpointAuthMethod: 'none'`) are also rejected: RFC 8693 §2.1 notes that skipping client authentication lets a stolen token be amplified into new tokens through the STS, and this implementation strengthens that note into a hard rejection
2. `parseTokenExchangeParams` validates and types the parameters: required `subject_token` / `subject_token_type`, the token-type restriction, `resource` syntax (absolute URI without a fragment), and the §2.1 pairing rules for delegation (`actor_token_type` is required with `actor_token` and forbidden without it). Blank or whitespace-only optional parameters count as absent, so an empty form field is never silently promoted into a target, scope, or delegation request
3. `resolveSubjectToken` resolves the subject_token through the `AccessTokenResolver` and checks existence, expiry, and `nbf`. Failure reasons are indistinguishable in the response
4. `resolveActorToken` (step 3' in the code; delegation only) runs the identical checks on the actor_token, with its own fixed failure message
5. `composeActClaim` (step 3''; delegation only) assembles the `act` value: the current actor outermost, the subject_token's prior chain nested below it
6. `validateExchangeScope` checks the requested scope is a subset of the subject's scope and returns the effective scope; omission inherits the subject's scope unchanged
7. `resolveExchangeTarget` validates audience / resource against the allow-list. Its return value is not the final `aud` but the vetted "requested" input for core's `buildAccessTokenAudience`. When both are omitted, the subject's audience is inherited (the exchange is then a pure scope-narrowing / lifetime-shortening one, not an unrestricted token)
8. `computeExchangedTokenLifetime` computes `min(configured, remaining seconds)`. Having passed `resolveSubjectToken`, the remainder is always at least 1, so an `expires_in: 0` token can never be issued
9. `buildTokenExchangeResponse` assembles the §2.2.1 response body. Since only access tokens are issued, `token_type` is fixed to `Bearer`, and `scope` is always included to avoid a conditional

The composition function `processTokenExchangeRequest` calls these in order and returns the issuance material, `TokenExchangeGrant`.
Note the inherited `grantId`: it ties the exchanged token into grant-level revocation, so revoking the original grant also kills tokens minted through exchange; in a delegation it is the subject's grant that is inherited, never the actor's.

```typescript
/**
 * OAuth 2.0 Token Exchange — RFC 8693
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * トークンエンドポイントの `urn:ietf:params:oauth:grant-type:token-exchange` grant を
 * 処理する。core と同じく「合成関数＋ステップ関数」の二層構成とし、CLI 生成コードは
 * ステップ関数を順に呼び出して検証を差し替え・削除できるようにする。
 *
 * **impersonation 型**（`actor_token` なし。交換後トークンは subject として振る舞う）と
 * **delegation 型**（`actor_token` あり。RFC 8693 §4.1 の `act` claim で actor を記録する）の
 * 両方に対応する。どちらでも、交換で権限が単調に狭まること（scope は部分集合・
 * audience は許可リスト内・寿命は subject_token の残存期間以下・`sub` は変更不可）が
 * 本モジュールのセキュリティ設計の中核である。
 *
 * トークンの発行・保存は行わない。呼び出し側（生成コード）が core の
 * `buildAccessTokenAudience` / `buildAccessTokenPayload` / `AccessTokenIssuer` /
 * `accessTokenStore` と組み合わせる。
 */
import {
  sanitizeErrorDescription,
  type AccessTokenInfo,
  type AccessTokenResolver,
  type TokenClientInfo,
} from '@maronn-openid-connect/core';

/** RFC 8693 §2.1: token exchange の grant type 識別子。 */
export const TOKEN_EXCHANGE_GRANT_TYPE = 'urn:ietf:params:oauth:grant-type:token-exchange';

/** RFC 8693 §3: アクセストークンの token type 識別子。本機能が扱う唯一の種別。 */
export const TOKEN_TYPE_ACCESS_TOKEN = 'urn:ietf:params:oauth:token-type:access_token';

/**
 * subject_token の解決に失敗したときの固定 error_description。
 *
 * 不存在・期限切れ・nbf 未来・失効済みを区別しない。応答からトークンの存在や
 * 失効状況を推測できる「オラクル」を作らないための意図的な設計（PAR の
 * request_uri 解決失敗と同じ方針）。
 */
export const SUBJECT_TOKEN_INVALID_DESCRIPTION =
  'The provided subject_token is not valid';

/**
 * actor_token の解決に失敗したときの固定 error_description。
 * {@link SUBJECT_TOKEN_INVALID_DESCRIPTION} と同じオラクル排除方針で、
 * どのパラメータが不正だったかだけを伝え、失敗理由は区別しない。
 */
export const ACTOR_TOKEN_INVALID_DESCRIPTION =
  'The provided actor_token is not valid';

/**
 * Token Exchange のエラーコード。
 *
 * RFC 8693 §2.2.2 は RFC 6749 §5.2 の形式を使い、`invalid_target` を追加する。
 * core の `TokenErrorCode` は closed な enum で `invalid_target` を含まないため、
 * core 無変更の制約下では core の `TokenError` に相乗りできない。
 */
export type TokenExchangeErrorCode =
  | 'invalid_request'
  | 'unauthorized_client'
  | 'invalid_scope'
  | 'invalid_target';

/**
 * Token Exchange のエラー。
 *
 * バックチャネル専用（リダイレクトは存在しない）で、常に 400 + JSON で返す。
 * 401 になるのはクライアント認証失敗（`invalid_client`）だけであり、それは
 * 本分岐より前の共有認証パイプライン（core の `TokenError`）が担当する。
 */
export class TokenExchangeError extends Error {
  readonly code: TokenExchangeErrorCode;
  readonly errorDescription: string;

  constructor(code: TokenExchangeErrorCode, errorDescription: string) {
    // RFC 6749 §5.2: error_description は安全な文字集合に限定する。
    const sanitized = sanitizeErrorDescription(errorDescription);
    super(sanitized);
    this.name = 'TokenExchangeError';
    this.code = code;
    this.errorDescription = sanitized;
  }

  /** 本エラーは常に 400（401 は分岐前の共有パイプラインが返す）。 */
  get statusCode(): 400 {
    return 400;
  }
}

/**
 * RFC 8693 §4.1 の `act` claim 値。
 *
 * `sub` が現在の actor。委譲が連鎖した場合は `act` のネストでチェーンを表し、
 * 最外が現在の actor、最深が最も古い actor になる。
 */
export interface TokenExchangeActor {
  sub: string;
  act?: TokenExchangeActor;
}

/**
 * 交換で発行したトークンの store metadata。
 *
 * core の {@link AccessTokenInfo} に `act` を加えた構造的拡張。生成コードが
 * delegation の発行時にこの形で store へ保存しておくと、そのトークンを後日
 * subject_token として再交換したときに {@link processTokenExchangeRequest} が
 * `act` を読み出して委譲チェーンを繋げられる（core は無変更のまま）。
 */
export type ExchangedAccessTokenInfo = AccessTokenInfo & {
  act?: TokenExchangeActor;
};

/** 検証済みの Token Exchange リクエストパラメータ（RFC 8693 §2.1）。 */
export interface ParsedTokenExchangeParams {
  subjectToken: string;
  /** 空白区切りの要求 scope。省略時は undefined（subject の scope を継承する） */
  scope?: string;
  audience?: string;
  resource?: string;
  /** delegation の actor_token。省略時は undefined（impersonation） */
  actorToken?: string;
}

/**
 * 発行素材。生成コードはこれを core の `buildAccessTokenAudience` /
 * `buildAccessTokenPayload` / `AccessTokenIssuer.issue` / `accessTokenStore.set` へ流す。
 */
export interface TokenExchangeGrant {
  /** subject_token の `sub` を継承する（delegation でも actor は `act` にのみ現れる） */
  subject: string;
  /** 交換を要求したクライアント（subject_token の発行先クライアントではない） */
  clientId: string;
  /** 縮小後の実効 scope */
  scope: string[];
  /** 検証済みの要求対象。core の `buildAccessTokenAudience` の `requested` へ渡す */
  requestedAudience?: string[];
  /** subject_token の残存期間で cap 済みの有効期間（秒） */
  expiresIn: number;
  /** subject_token の `grantId` を継承する（grant 単位失効の連動） */
  grantId?: string;
  /**
   * delegation の act claim 値（RFC 8693 §4.1）。impersonation では undefined。
   * 生成コードは JWT payload と store metadata の両方へ `act` として載せる。
   */
  actor?: TokenExchangeActor;
}

/** RFC 8693 §2.2.1 の成功レスポンスボディ。 */
export interface TokenExchangeResponse {
  access_token: string;
  issued_token_type: typeof TOKEN_TYPE_ACCESS_TOKEN;
  token_type: 'Bearer';
  expires_in: number;
  scope: string;
}

/** Token Exchange 処理のコンテキスト。 */
export interface TokenExchangeRequestContext {
  /** フォームボディのパラメータ（application/x-www-form-urlencoded） */
  params: Record<string, string>;
  /** 認証済みクライアント（分岐前の共有認証パイプラインが解決したもの） */
  client: TokenClientInfo;
  accessTokenResolver: AccessTokenResolver;
  /** `audience` / `resource` で要求できる対象の許可リスト。既定は空（安全側） */
  allowedTargets: string[];
  /** 設定上のアクセストークン有効期間（秒）。subject の残存期間で cap される */
  configuredExpiresIn: number;
  /** 現在時刻。テストと決定的な期限計算のために注入できる */
  now?: Date;
}

/**
 * ステップ 1: クライアントが交換を要求してよいかを検証する。
 *
 * RFC 8693 §2.1 は「クライアント認証を省くと、窃取されたトークンを STS 経由で
 * 別のトークンへ増幅できてしまう」と注記している。本機能はこれを
 * **public client の拒否**まで強めている（設計判断）。
 *
 * @throws {TokenExchangeError} unauthorized_client
 */
export function authorizeTokenExchangeClient(client: TokenClientInfo): void {
  // OIDC Dynamic Client Registration 1.0 §2 / RFC 7591 §2: grantTypes 未指定は
  // ['authorization_code'] 扱い。よって交換は明示登録したクライアントのみ許される。
  const grantTypes = client.grantTypes ?? ['authorization_code'];
  if (!grantTypes.includes(TOKEN_EXCHANGE_GRANT_TYPE)) {
    throw new TokenExchangeError(
      'unauthorized_client',
      'The client is not authorized to use the token-exchange grant type',
    );
  }
  if (client.tokenEndpointAuthMethod === 'none') {
    throw new TokenExchangeError(
      'unauthorized_client',
      'Public clients are not allowed to use the token-exchange grant type',
    );
  }
}

/**
 * ステップ 2: 必須・非対応パラメータを検証して型付けする（RFC 8693 §2.1）。
 *
 * 空文字・空白のみの任意パラメータは「送られなかった」と同じに扱う
 * （フォームの空フィールドを黙って対象指定・scope 指定に昇格させないため）。
 *
 * @throws {TokenExchangeError} invalid_request
 */
export function parseTokenExchangeParams(
  params: Record<string, string>,
): ParsedTokenExchangeParams {
  const subjectToken = optional(params['subject_token']);
  if (subjectToken === undefined) {
    throw new TokenExchangeError('invalid_request', 'subject_token is required');
  }

  const subjectTokenType = optional(params['subject_token_type']);
  if (subjectTokenType === undefined) {
    throw new TokenExchangeError('invalid_request', 'subject_token_type is required');
  }
  if (subjectTokenType !== TOKEN_TYPE_ACCESS_TOKEN) {
    throw new TokenExchangeError(
      'invalid_request',
      `Unsupported subject_token_type. Only ${TOKEN_TYPE_ACCESS_TOKEN} is supported.`,
    );
  }

  // RFC 8693 §2.1: requested_token_type は OPTIONAL。省略時の発行種別は AS の裁量で、
  // 本機能は常にアクセストークンを発行する。
  const requestedTokenType = optional(params['requested_token_type']);
  if (requestedTokenType !== undefined && requestedTokenType !== TOKEN_TYPE_ACCESS_TOKEN) {
    throw new TokenExchangeError(
      'invalid_request',
      `Unsupported requested_token_type. Only ${TOKEN_TYPE_ACCESS_TOKEN} is supported.`,
    );
  }

  const resource = optional(params['resource']);
  if (resource !== undefined && !isAbsoluteUriWithoutFragment(resource)) {
    // RFC 8693 §2.1: resource は絶対 URI で fragment を含んではならない（query は許容）。
    // 構文違反は RFC 6749 §5.2 の invalid_request とし、invalid_target は
    // 「対象への発行を拒否する」ポリシー判定に限定する（本仕様の設計判断）。
    throw new TokenExchangeError(
      'invalid_request',
      'resource must be an absolute URI without a fragment component',
    );
  }

  // delegation（RFC 8693 §2.1）: actor_token_type は actor_token があるとき REQUIRED、
  // 無いとき MUST NOT be included。
  const actorToken = optional(params['actor_token']);
  const actorTokenType = optional(params['actor_token_type']);
  if (actorToken !== undefined && actorTokenType === undefined) {
    throw new TokenExchangeError(
      'invalid_request',
      'actor_token_type is required when actor_token is present',
    );
  }
  if (actorToken === undefined && actorTokenType !== undefined) {
    throw new TokenExchangeError(
      'invalid_request',
      'actor_token_type must not be present without actor_token',
    );
  }
  if (actorTokenType !== undefined && actorTokenType !== TOKEN_TYPE_ACCESS_TOKEN) {
    throw new TokenExchangeError(
      'invalid_request',
      `Unsupported actor_token_type. Only ${TOKEN_TYPE_ACCESS_TOKEN} is supported.`,
    );
  }

  return {
    subjectToken,
    scope: optional(params['scope']),
    audience: optional(params['audience']),
    resource,
    actorToken,
  };
}

/**
 * ステップ 3: subject_token を解決し、有効性を検証する。
 *
 * RFC 8693 §2.1: "the authorization server MUST perform the appropriate validation
 * procedures for the indicated token type"。本機能は本 OP 発行のアクセストークンに
 * 限るため、store メタデータの有効性検証（存在・期限・nbf）でこれを満たす。
 *
 * 失敗理由は応答から区別できない（{@link SUBJECT_TOKEN_INVALID_DESCRIPTION}）。
 *
 * @throws {TokenExchangeError} invalid_request（RFC 8693 §2.2.2。`invalid_grant` ではない）
 */
export async function resolveSubjectToken(options: {
  subjectToken: string;
  accessTokenResolver: AccessTokenResolver;
  now?: Date;
}): Promise<AccessTokenInfo> {
  return resolveExchangeToken(
    options.subjectToken,
    options.accessTokenResolver,
    options.now,
    invalidSubjectToken,
  );
}

/**
 * ステップ 3': actor_token を解決し、有効性を検証する（delegation のみ）。
 *
 * 検証内容は {@link resolveSubjectToken} と同一（本 OP 発行のアクセストークンで、
 * 存在・期限・nbf を満たすこと）。actor_token は「交換を要求した時点で actor が
 * 実在し有効なトークンを保持していること」の確認であり、発行後トークンの寿命は
 * actor_token に連動しない（{@link computeExchangedTokenLifetime} 参照）。
 *
 * 失敗理由は応答から区別できない（{@link ACTOR_TOKEN_INVALID_DESCRIPTION}）。
 *
 * @throws {TokenExchangeError} invalid_request
 */
export async function resolveActorToken(options: {
  actorToken: string;
  accessTokenResolver: AccessTokenResolver;
  now?: Date;
}): Promise<AccessTokenInfo> {
  return resolveExchangeToken(
    options.actorToken,
    options.accessTokenResolver,
    options.now,
    invalidActorToken,
  );
}

/**
 * ステップ 3'': act claim を組み立てる（RFC 8693 §4.1、delegation のみ）。
 *
 * 最外の `sub` は今回の actor。subject_token が既に `act` を持つ（＝それ自体が
 * 委譲で発行された）場合は、そのチェーンをネストへ押し下げる。これで
 * 「最外が現在の actor、最深が最も古い actor」という §4.1 の規則を満たす。
 */
export function composeActClaim(options: {
  /** actor_token の sub */
  actorSub: string;
  /** subject_token の store metadata に保存されていた act チェーン */
  subjectActChain?: TokenExchangeActor;
}): TokenExchangeActor {
  if (options.subjectActChain === undefined) {
    return { sub: options.actorSub };
  }
  return { sub: options.actorSub, act: options.subjectActChain };
}

/**
 * ステップ 4: 要求 scope が subject_token の scope の部分集合であることを検証する。
 *
 * 権限昇格（scope 拡大）の防止が目的。省略時・空白のみの場合は subject の scope を
 * そのまま継承する（拡大はしない）。
 *
 * @returns 交換後トークンの実効 scope
 * @throws {TokenExchangeError} invalid_scope
 */
export function validateExchangeScope(
  requestedScope: string | undefined,
  subjectScope: string[],
): string[] {
  const requested = splitScope(requestedScope);
  if (requested.length === 0) {
    return [...subjectScope];
  }
  for (const value of requested) {
    if (!subjectScope.includes(value)) {
      throw new TokenExchangeError(
        'invalid_scope',
        'The requested scope exceeds the scope of the subject_token',
      );
    }
  }
  return requested;
}

/**
 * ステップ 5: `audience` / `resource` を許可リストで検証し、要求対象を返す。
 *
 * 戻り値は最終的な `aud` ではなく、生成コードが core の `buildAccessTokenAudience` の
 * `requested` へ渡す入力。UserInfo エンドポイントの恒久メンバ追加・重複除去・
 * 非空フォールバックは既存トークンルートと同じ合成関数に委ねる。
 *
 * 両方が省略された場合は subject_token の audience を継承する（対象変更なしの
 * scope 縮小・期限短縮のみの交換として扱う。無制限になるわけではない）。
 *
 * @throws {TokenExchangeError} invalid_target
 */
export function resolveExchangeTarget(options: {
  audience?: string;
  resource?: string;
  allowedTargets: string[];
  subjectAudience?: string[];
}): string[] | undefined {
  const { audience, resource, allowedTargets, subjectAudience } = options;
  if (audience === undefined && resource === undefined) {
    return subjectAudience === undefined ? undefined : [...subjectAudience];
  }

  const targets: string[] = [];
  for (const requested of [audience, resource]) {
    if (requested === undefined) continue;
    if (!allowedTargets.includes(requested)) {
      // error_description は allowedTargets の内容・部分一致情報を露出しない固定文言。
      throw new TokenExchangeError(
        'invalid_target',
        'The requested target is not allowed for token exchange',
      );
    }
    targets.push(requested);
  }
  return [...new Set(targets)];
}

/**
 * ステップ 6: 発行トークンの有効期間（秒）を算出する。
 *
 * `min(configured, subject の残存秒数)`。交換を何度連鎖しても寿命は単調減少し、
 * 交換によるトークン寿命の洗浄（無期限延命）ができない。
 *
 * 残存秒数は `subjectExpiresAt - floor(now / 1000)` で計算する。`expiresAt` は整数秒で、
 * {@link resolveSubjectToken} を通過した時点で `subjectExpiresAt > now` が保証されるため、
 * この丸め規則では残存秒数は必ず 1 以上になり `expires_in: 0` のトークンは発行されない。
 *
 * @throws {TokenExchangeError} invalid_request（残存期間がない場合の防御的チェック）
 * @throws {RangeError} configuredExpiresIn が正の整数でない場合（設定ミス）
 */
export function computeExchangedTokenLifetime(options: {
  /** Unix epoch 秒 */
  subjectExpiresAt: number;
  configuredExpiresIn: number;
  now?: Date;
}): number {
  const { subjectExpiresAt, configuredExpiresIn } = options;
  if (!Number.isInteger(configuredExpiresIn) || configuredExpiresIn <= 0) {
    throw new RangeError(
      `configuredExpiresIn must be a positive integer, received ${configuredExpiresIn}`,
    );
  }

  const remaining = subjectExpiresAt - toEpochSeconds(options.now);
  if (remaining <= 0) {
    // resolveSubjectToken を先に通していれば到達しない。単独呼び出し時の防御。
    throw invalidSubjectToken();
  }
  return Math.min(configuredExpiresIn, remaining);
}

/** ステップ 7: RFC 8693 §2.2.1 の応答ボディを組み立てる。 */
export function buildTokenExchangeResponse(options: {
  accessToken: string;
  expiresIn: number;
  scope: string[];
}): TokenExchangeResponse {
  return {
    access_token: options.accessToken,
    issued_token_type: TOKEN_TYPE_ACCESS_TOKEN,
    // 発行したのはアクセストークンなので常に Bearer（RFC 8693 の N_A は使わない）。
    token_type: 'Bearer',
    expires_in: options.expiresIn,
    // §2.2.1 は「要求と同一なら OPTIONAL」だが、判定分岐を避けるため常に含める。
    scope: options.scope.join(' '),
  };
}

/**
 * 合成関数: Token Exchange の検証〜発行素材の導出（RFC 8693 §2.1）。
 *
 * 個々のステップ関数を仕様順に合成しただけの API。トークンの発行・保存・応答生成は
 * 行わないため、呼び出し側が core の発行パイプラインと組み合わせる。
 *
 * @throws {TokenExchangeError}
 */
export async function processTokenExchangeRequest(
  context: TokenExchangeRequestContext,
): Promise<TokenExchangeGrant> {
  // クライアント認可を最初に行う。許可されていないクライアントには subject_token の
  // 有効性すら判定させない（オラクルを与えない）。
  authorizeTokenExchangeClient(context.client);

  const parsed = parseTokenExchangeParams(context.params);

  const subject = await resolveSubjectToken({
    subjectToken: parsed.subjectToken,
    accessTokenResolver: context.accessTokenResolver,
    now: context.now,
  });

  // delegation: actor_token を解決し、act claim を組み立てる（RFC 8693 §4.1）。
  // subject_token 自体が委譲で発行されていた場合、その act チェーンをネストへ継承する。
  let actor: TokenExchangeActor | undefined;
  if (parsed.actorToken !== undefined) {
    const actorInfo = await resolveActorToken({
      actorToken: parsed.actorToken,
      accessTokenResolver: context.accessTokenResolver,
      now: context.now,
    });
    actor = composeActClaim({
      actorSub: actorInfo.sub,
      subjectActChain: (subject as ExchangedAccessTokenInfo).act,
    });
  }

  const scope = validateExchangeScope(parsed.scope, subject.scope);

  const requestedAudience = resolveExchangeTarget({
    audience: parsed.audience,
    resource: parsed.resource,
    allowedTargets: context.allowedTargets,
    subjectAudience: subject.audience,
  });

  const expiresIn = computeExchangedTokenLifetime({
    subjectExpiresAt: subject.expiresAt,
    configuredExpiresIn: context.configuredExpiresIn,
    now: context.now,
  });

  return {
    subject: subject.sub,
    clientId: context.client.clientId,
    scope,
    requestedAudience,
    expiresIn,
    grantId: subject.grantId,
    ...(actor === undefined ? {} : { actor }),
  };
}

/** 空文字・空白のみを「未指定」として扱う。 */
function optional(value: string | undefined): string | undefined {
  if (value === undefined) return undefined;
  const trimmed = value.trim();
  return trimmed.length === 0 ? undefined : trimmed;
}

function splitScope(scope: string | undefined): string[] {
  if (scope === undefined) return [];
  return [...new Set(scope.split(/\s+/).filter((value) => value.length > 0))];
}

function toEpochSeconds(now: Date | undefined): number {
  return Math.floor((now ?? new Date()).getTime() / 1000);
}

function invalidSubjectToken(): TokenExchangeError {
  return new TokenExchangeError('invalid_request', SUBJECT_TOKEN_INVALID_DESCRIPTION);
}

function invalidActorToken(): TokenExchangeError {
  return new TokenExchangeError('invalid_request', ACTOR_TOKEN_INVALID_DESCRIPTION);
}

/**
 * subject_token / actor_token 共通の解決と有効性検証。
 * RFC 8693 §2.1: "the authorization server MUST perform the appropriate validation
 * procedures for the indicated token type"。本機能は本 OP 発行のアクセストークンに
 * 限るため、store メタデータの有効性検証（存在・期限・nbf）でこれを満たす。
 */
async function resolveExchangeToken(
  token: string,
  accessTokenResolver: AccessTokenResolver,
  now: Date | undefined,
  invalidToken: () => TokenExchangeError,
): Promise<AccessTokenInfo> {
  const info = await accessTokenResolver.findAccessToken(token);
  if (info === null) {
    // 不存在・失効済みのいずれも resolver が null を返す。
    throw invalidToken();
  }

  const nowSeconds = toEpochSeconds(now);
  if (info.expiresAt <= nowSeconds) {
    throw invalidToken();
  }
  if (info.nbf !== undefined && info.nbf > nowSeconds) {
    throw invalidToken();
  }
  return info;
}

/**
 * RFC 8693 §2.1: `resource` は絶対 URI（RFC 3986 §4.3）で fragment を含んではならない。
 * query は許容される。
 */
function isAbsoluteUriWithoutFragment(value: string): boolean {
  if (value.includes('#')) return false;
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    return false;
  }
  // URL は相対参照を解決しない（base なしでは throw する）ため、ここに来た時点で
  // scheme を持つ絶対 URI である。念のため scheme の存在を明示的に確認する。
  return parsed.protocol.length > 0;
}
```

### index.ts (public API)

The substance of the subpath export `@maronn-openid-connect/experimental/token-exchange`.

```typescript
/**
 * OAuth 2.0 Token Exchange — RFC 8693
 *
 * **Experimental**: この機能の API は安定していない。マイナーリリースでも
 * 破壊的に変更されることがある。本番運用の前に
 * `docs/library-document` の Experimental セクションを確認すること。
 *
 * `@maronn-openid-connect/core` とは別 package であり、CLI で `--enable token-exchange` を
 * 明示したときのみ生成コードから利用される。
 *
 * impersonation 型（`actor_token` なし）と delegation 型（`actor_token` あり、
 * RFC 8693 §4.1 の `act` claim で actor を記録）の両方に対応する。
 * `audience` / `resource` の複数指定には対応しない（生成 OP のトークン
 * エンドポイントが RFC 6749 §3.2 に基づき重複パラメータを拒否するため）。
 */
export {
  ACTOR_TOKEN_INVALID_DESCRIPTION,
  SUBJECT_TOKEN_INVALID_DESCRIPTION,
  TOKEN_EXCHANGE_GRANT_TYPE,
  TOKEN_TYPE_ACCESS_TOKEN,
  TokenExchangeError,
  authorizeTokenExchangeClient,
  buildTokenExchangeResponse,
  composeActClaim,
  computeExchangedTokenLifetime,
  parseTokenExchangeParams,
  processTokenExchangeRequest,
  resolveActorToken,
  resolveExchangeTarget,
  resolveSubjectToken,
  validateExchangeScope,
  type ExchangedAccessTokenInfo,
  type ParsedTokenExchangeParams,
  type TokenExchangeActor,
  type TokenExchangeErrorCode,
  type TokenExchangeGrant,
  type TokenExchangeRequestContext,
  type TokenExchangeResponse,
} from './token-exchange-request.js';
```

## The unit tests, in full

The tests live in a single file; most of its lines are boundary checks per step function.
What they pin down, in summary:

- the constants (the grant-type and token-type URNs, both fixed failure descriptions) and `TokenExchangeError`'s traits (always 400, sanitization, the error name)
- every parameter-parsing path (valid requests, blank optionals ignored, missing required parameters, unsupported token types, the actor_token / actor_token_type pairing rules, `resource` syntax violations)
- client authorization (URN not registered, the default for unspecified `grantTypes`, public clients rejected)
- all subject_token failure kinds yielding one message, and the expiry / `nbf` boundaries; the same for actor_token with its own message
- `composeActClaim` building a single-level act and preserving nested chains
- scope narrowing (subsets accepted, excess rejected, omission inherits, duplicates removed)
- target validation (allow-listed values accepted, others rejected, omission inherits the subject audience, audience and resource combined)
- lifetime capping (min of configured and remaining, boundary values, `RangeError` on misconfiguration)
- the response body shape
- the composition function end to end (impersonation and delegation issuance material; act chaining; the actor not capping the lifetime; each stage's failure propagating with the right error)

### What a green suite guarantees

Each test targets one step function, so it is fair to ask what all of them passing adds up to.
When the steps are composed in the shipped order (authorize → parse → resolve subject → resolve actor → compose act → scope → target → lifetime → response), which is exactly what `processTokenExchangeRequest` and the generated code do, a green suite guarantees the following about any request the OP answers:

- no client outside the registered, confidential set ever gets a verdict about any token, because authorization runs before resolution
- no malformed or unsupported parameter combination reaches token resolution, because parsing runs second
- an issued token's scope is a subset of the subject's, its target is allow-listed or inherited, and its lifetime never exceeds the subject's remainder, because each of those steps rejects everything else
- the issued token acts as the subject (`sub` unchanged), and in a delegation the actor is recorded in `act` with any prior chain preserved
- every unusable subject_token or actor_token produces one fixed message per parameter, so the endpoint cannot be used as an existence oracle

What the suite cannot guarantee is the composition order itself in customized code: a generated OP whose owner reorders the steps (say, resolving tokens before authorizing the client) still passes these unit tests.
That composition is pinned one level up, by the generated conformance tests and the E2E spec below.

```typescript
import { describe, expect, it } from 'vitest';
import type { AccessTokenInfo, AccessTokenResolver, TokenClientInfo } from '@maronn-openid-connect/core';
import {
  ACTOR_TOKEN_INVALID_DESCRIPTION,
  SUBJECT_TOKEN_INVALID_DESCRIPTION,
  TOKEN_EXCHANGE_GRANT_TYPE,
  TOKEN_TYPE_ACCESS_TOKEN,
  TokenExchangeError,
  authorizeTokenExchangeClient,
  buildTokenExchangeResponse,
  composeActClaim,
  computeExchangedTokenLifetime,
  parseTokenExchangeParams,
  processTokenExchangeRequest,
  resolveActorToken,
  resolveExchangeTarget,
  resolveSubjectToken,
  validateExchangeScope,
  type ExchangedAccessTokenInfo,
} from './token-exchange-request.js';

/** 2026-01-01T00:00:00Z。Unix epoch 秒で 1767225600。 */
const NOW = new Date('2026-01-01T00:00:00Z');
const NOW_SECONDS = 1767225600;

function confidentialClient(overrides: Partial<TokenClientInfo> = {}): TokenClientInfo {
  return {
    clientId: 'exchange-client',
    clientSecret: 'secret',
    grantTypes: ['authorization_code', TOKEN_EXCHANGE_GRANT_TYPE],
    tokenEndpointAuthMethod: 'client_secret_basic',
    ...overrides,
  };
}

function subjectTokenInfo(overrides: Partial<AccessTokenInfo> = {}): AccessTokenInfo {
  return {
    sub: 'user-1',
    scope: ['openid', 'profile', 'api:read'],
    clientId: 'front-api',
    expiresAt: NOW_SECONDS + 300,
    grantId: 'grant-1',
    audience: ['https://op.example.com/userinfo'],
    ...overrides,
  };
}

function resolverFor(info: AccessTokenInfo | null): AccessTokenResolver {
  return {
    findAccessToken: async () => info,
  };
}

/** delegation テスト用: トークン文字列ごとに別の情報を返す resolver。 */
function resolverByToken(map: Record<string, AccessTokenInfo>): AccessTokenResolver {
  return {
    findAccessToken: async (token) => map[token] ?? null,
  };
}

function validParams(overrides: Record<string, string | undefined> = {}): Record<string, string> {
  const base: Record<string, string | undefined> = {
    grant_type: TOKEN_EXCHANGE_GRANT_TYPE,
    subject_token: 'subject-access-token',
    subject_token_type: TOKEN_TYPE_ACCESS_TOKEN,
    ...overrides,
  };
  const params: Record<string, string> = {};
  for (const [key, value] of Object.entries(base)) {
    if (value !== undefined) params[key] = value;
  }
  return params;
}

describe('token exchange constants', () => {
  // RFC 8693 §2.1 / §3
  it('should expose the RFC 8693 grant type URN', () => {
    expect(TOKEN_EXCHANGE_GRANT_TYPE).toBe('urn:ietf:params:oauth:grant-type:token-exchange');
  });

  it('should expose the RFC 8693 access token type URN', () => {
    expect(TOKEN_TYPE_ACCESS_TOKEN).toBe('urn:ietf:params:oauth:token-type:access_token');
  });
});

describe('TokenExchangeError', () => {
  it('should expose the error code as given', () => {
    expect(new TokenExchangeError('invalid_target', 'nope').code).toBe('invalid_target');
  });

  // 401 を返すのはクライアント認証失敗のみで、それは分岐より前の共有パイプラインが担う。
  it('should always report status code 400', () => {
    expect(new TokenExchangeError('invalid_request', 'nope').statusCode).toBe(400);
  });

  // RFC 6749 §5.2: error_description は %x20-21 / %x23-5B / %x5D-7E に限定される。
  // core の sanitizeErrorDescription は範囲外の文字（改行・二重引用符）を '?' に置換する。
  it('should sanitize control characters out of the error description', () => {
    expect(new TokenExchangeError('invalid_request', 'bad\n"value"').errorDescription).toBe(
      'bad??value?',
    );
  });

  it('should set the error name to TokenExchangeError', () => {
    expect(new TokenExchangeError('invalid_scope', 'nope').name).toBe('TokenExchangeError');
  });
});

describe('parseTokenExchangeParams', () => {
  describe('Valid requests', () => {
    it('should return only the subject token when no optional parameter is present', () => {
      expect(parseTokenExchangeParams(validParams())).toEqual({
        subjectToken: 'subject-access-token',
        scope: undefined,
        audience: undefined,
        resource: undefined,
        actorToken: undefined,
      });
    });

    it('should return every optional parameter when all are present', () => {
      const params = validParams({
        scope: 'api:read',
        audience: 'internal-api',
        resource: 'https://internal.example.com/api',
        requested_token_type: TOKEN_TYPE_ACCESS_TOKEN,
        actor_token: 'actor-access-token',
        actor_token_type: TOKEN_TYPE_ACCESS_TOKEN,
      });
      expect(parseTokenExchangeParams(params)).toEqual({
        subjectToken: 'subject-access-token',
        scope: 'api:read',
        audience: 'internal-api',
        resource: 'https://internal.example.com/api',
        actorToken: 'actor-access-token',
      });
    });

    // 空文字のフォームフィールドは「送られなかった」と同じに扱う（本仕様の設計判断）。
    it('should treat a blank optional parameter as omitted', () => {
      const params = validParams({ scope: '', audience: '  ', resource: '' });
      expect(parseTokenExchangeParams(params)).toEqual({
        subjectToken: 'subject-access-token',
        scope: undefined,
        audience: undefined,
        resource: undefined,
        actorToken: undefined,
      });
    });

    // RFC 8693 §2.1: resource は絶対 URI。query は許容される。
    it('should accept a resource with a query component', () => {
      const params = validParams({ resource: 'https://internal.example.com/api?tenant=a' });
      expect(parseTokenExchangeParams(params).resource).toBe(
        'https://internal.example.com/api?tenant=a',
      );
    });

    // RFC 8693 §2.1: requested_token_type は OPTIONAL。省略時はアクセストークンを発行する。
    it('should accept an omitted requested_token_type', () => {
      expect(parseTokenExchangeParams(validParams()).subjectToken).toBe('subject-access-token');
    });
  });

  describe('Missing required parameters', () => {
    it('should reject a missing subject_token with invalid_request', () => {
      const params = validParams({ subject_token: undefined });
      expect(() => parseTokenExchangeParams(params)).toThrow(
        new TokenExchangeError('invalid_request', 'subject_token is required'),
      );
    });

    it('should reject a blank subject_token with invalid_request', () => {
      const params = validParams({ subject_token: '   ' });
      expect(() => parseTokenExchangeParams(params)).toThrow(
        new TokenExchangeError('invalid_request', 'subject_token is required'),
      );
    });

    it('should reject a missing subject_token_type with invalid_request', () => {
      const params = validParams({ subject_token_type: undefined });
      expect(() => parseTokenExchangeParams(params)).toThrow(
        new TokenExchangeError('invalid_request', 'subject_token_type is required'),
      );
    });
  });

  describe('Unsupported token types', () => {
    // 非目標: id_token / refresh_token / jwt / saml の subject_token_type は受け付けない。
    it('should reject an id_token subject_token_type with invalid_request', () => {
      const params = validParams({
        subject_token_type: 'urn:ietf:params:oauth:token-type:id_token',
      });
      expect(() => parseTokenExchangeParams(params)).toThrow(
        new TokenExchangeError(
          'invalid_request',
          'Unsupported subject_token_type. Only urn:ietf:params:oauth:token-type:access_token is supported.',
        ),
      );
    });

    it('should reject a refresh_token subject_token_type with invalid_request', () => {
      const params = validParams({
        subject_token_type: 'urn:ietf:params:oauth:token-type:refresh_token',
      });
      expect(() => parseTokenExchangeParams(params)).toThrow(TokenExchangeError);
    });

    it('should reject an id_token requested_token_type with invalid_request', () => {
      const params = validParams({
        requested_token_type: 'urn:ietf:params:oauth:token-type:id_token',
      });
      expect(() => parseTokenExchangeParams(params)).toThrow(
        new TokenExchangeError(
          'invalid_request',
          'Unsupported requested_token_type. Only urn:ietf:params:oauth:token-type:access_token is supported.',
        ),
      );
    });
  });

  describe('Delegation parameters (RFC 8693 §2.1)', () => {
    it('should return the actor token when actor_token and actor_token_type are present', () => {
      const params = validParams({
        actor_token: 'actor-access-token',
        actor_token_type: TOKEN_TYPE_ACCESS_TOKEN,
      });
      expect(parseTokenExchangeParams(params)).toEqual({
        subjectToken: 'subject-access-token',
        scope: undefined,
        audience: undefined,
        resource: undefined,
        actorToken: 'actor-access-token',
      });
    });

    // RFC 8693 §2.1: actor_token_type は actor_token があるとき REQUIRED。
    it('should reject actor_token without actor_token_type with invalid_request', () => {
      const params = validParams({ actor_token: 'actor-access-token' });
      expect(() => parseTokenExchangeParams(params)).toThrow(
        new TokenExchangeError(
          'invalid_request',
          'actor_token_type is required when actor_token is present',
        ),
      );
    });

    // RFC 8693 §2.1: actor_token_type は actor_token が無いとき MUST NOT be included。
    it('should reject actor_token_type without actor_token with invalid_request', () => {
      const params = validParams({ actor_token_type: TOKEN_TYPE_ACCESS_TOKEN });
      expect(() => parseTokenExchangeParams(params)).toThrow(
        new TokenExchangeError(
          'invalid_request',
          'actor_token_type must not be present without actor_token',
        ),
      );
    });

    // 空文字の actor_token は「送られなかった」扱い。残った actor_token_type が
    // 単独指定として拒否される。
    it('should treat a blank actor_token as omitted and reject the remaining actor_token_type', () => {
      const params = validParams({
        actor_token: '   ',
        actor_token_type: TOKEN_TYPE_ACCESS_TOKEN,
      });
      expect(() => parseTokenExchangeParams(params)).toThrow(
        new TokenExchangeError(
          'invalid_request',
          'actor_token_type must not be present without actor_token',
        ),
      );
    });

    it('should reject an id_token actor_token_type with invalid_request', () => {
      const params = validParams({
        actor_token: 'actor-access-token',
        actor_token_type: 'urn:ietf:params:oauth:token-type:id_token',
      });
      expect(() => parseTokenExchangeParams(params)).toThrow(
        new TokenExchangeError(
          'invalid_request',
          'Unsupported actor_token_type. Only urn:ietf:params:oauth:token-type:access_token is supported.',
        ),
      );
    });
  });

  describe('resource syntax (RFC 8693 §2.1)', () => {
    it('should reject a relative resource with invalid_request', () => {
      const params = validParams({ resource: '/api' });
      expect(() => parseTokenExchangeParams(params)).toThrow(
        new TokenExchangeError(
          'invalid_request',
          'resource must be an absolute URI without a fragment component',
        ),
      );
    });

    it('should reject a resource carrying a fragment with invalid_request', () => {
      const params = validParams({ resource: 'https://internal.example.com/api#section' });
      expect(() => parseTokenExchangeParams(params)).toThrow(
        new TokenExchangeError(
          'invalid_request',
          'resource must be an absolute URI without a fragment component',
        ),
      );
    });

    it('should reject a resource with an empty fragment with invalid_request', () => {
      const params = validParams({ resource: 'https://internal.example.com/api#' });
      expect(() => parseTokenExchangeParams(params)).toThrow(
        new TokenExchangeError(
          'invalid_request',
          'resource must be an absolute URI without a fragment component',
        ),
      );
    });
  });
});

describe('authorizeTokenExchangeClient', () => {
  it('should accept a confidential client registered for the exchange grant', () => {
    expect(authorizeTokenExchangeClient(confidentialClient())).toBeUndefined();
  });

  it('should accept a client_secret_post client registered for the exchange grant', () => {
    const client = confidentialClient({ tokenEndpointAuthMethod: 'client_secret_post' });
    expect(authorizeTokenExchangeClient(client)).toBeUndefined();
  });

  // RFC 6749 §5.2 / OIDC Dynamic Client Registration §2: 未指定の grantTypes は
  // ['authorization_code'] 扱いなので、交換は常に拒否される。
  it('should reject a client whose grantTypes omit the exchange URN with unauthorized_client', () => {
    const client = confidentialClient({ grantTypes: ['authorization_code', 'refresh_token'] });
    expect(() => authorizeTokenExchangeClient(client)).toThrow(
      new TokenExchangeError(
        'unauthorized_client',
        'The client is not authorized to use the token-exchange grant type',
      ),
    );
  });

  it('should reject a client with unspecified grantTypes with unauthorized_client', () => {
    const client = confidentialClient({ grantTypes: undefined });
    expect(() => authorizeTokenExchangeClient(client)).toThrow(
      new TokenExchangeError(
        'unauthorized_client',
        'The client is not authorized to use the token-exchange grant type',
      ),
    );
  });

  // RFC 8693 §2.1 の注記（窃取トークンの STS 経由の増幅）に対する設計判断。
  it('should reject a public client with unauthorized_client', () => {
    const client = confidentialClient({
      tokenEndpointAuthMethod: 'none',
      clientSecret: undefined,
    });
    expect(() => authorizeTokenExchangeClient(client)).toThrow(
      new TokenExchangeError(
        'unauthorized_client',
        'Public clients are not allowed to use the token-exchange grant type',
      ),
    );
  });
});

describe('resolveSubjectToken', () => {
  it('should return the resolved access token info when the token is valid', async () => {
    const info = subjectTokenInfo();
    const resolved = await resolveSubjectToken({
      subjectToken: 'subject-access-token',
      accessTokenResolver: resolverFor(info),
      now: NOW,
    });
    expect(resolved).toEqual(info);
  });

  it('should accept a token whose nbf is exactly now', async () => {
    const info = subjectTokenInfo({ nbf: NOW_SECONDS });
    const resolved = await resolveSubjectToken({
      subjectToken: 'subject-access-token',
      accessTokenResolver: resolverFor(info),
      now: NOW,
    });
    expect(resolved).toEqual(info);
  });

  it('should pass the subject token through to the resolver', async () => {
    const seen: string[] = [];
    const resolver: AccessTokenResolver = {
      findAccessToken: async (token) => {
        seen.push(token);
        return subjectTokenInfo();
      },
    };
    await resolveSubjectToken({
      subjectToken: 'subject-access-token',
      accessTokenResolver: resolver,
      now: NOW,
    });
    expect(seen).toEqual(['subject-access-token']);
  });

  describe('Invalid subject tokens', () => {
    // オラクル化防止: 失敗種別を error_description から区別できないようにする。
    it('should reject an unknown token with the fixed invalid_request description', async () => {
      await expect(
        resolveSubjectToken({
          subjectToken: 'unknown',
          accessTokenResolver: resolverFor(null),
          now: NOW,
        }),
      ).rejects.toThrow(new TokenExchangeError('invalid_request', SUBJECT_TOKEN_INVALID_DESCRIPTION));
    });

    it('should reject an expired token with the fixed invalid_request description', async () => {
      await expect(
        resolveSubjectToken({
          subjectToken: 'expired',
          accessTokenResolver: resolverFor(subjectTokenInfo({ expiresAt: NOW_SECONDS - 1 })),
          now: NOW,
        }),
      ).rejects.toThrow(new TokenExchangeError('invalid_request', SUBJECT_TOKEN_INVALID_DESCRIPTION));
    });

    it('should reject a token expiring exactly now with the fixed invalid_request description', async () => {
      await expect(
        resolveSubjectToken({
          subjectToken: 'expired-now',
          accessTokenResolver: resolverFor(subjectTokenInfo({ expiresAt: NOW_SECONDS })),
          now: NOW,
        }),
      ).rejects.toThrow(new TokenExchangeError('invalid_request', SUBJECT_TOKEN_INVALID_DESCRIPTION));
    });

    it('should reject a token whose nbf is in the future with the fixed invalid_request description', async () => {
      await expect(
        resolveSubjectToken({
          subjectToken: 'not-yet',
          accessTokenResolver: resolverFor(subjectTokenInfo({ nbf: NOW_SECONDS + 1 })),
          now: NOW,
        }),
      ).rejects.toThrow(new TokenExchangeError('invalid_request', SUBJECT_TOKEN_INVALID_DESCRIPTION));
    });

    it('should report the same error code for every failure kind', async () => {
      const codes: string[] = [];
      const cases: Array<AccessTokenInfo | null> = [
        null,
        subjectTokenInfo({ expiresAt: NOW_SECONDS - 1 }),
        subjectTokenInfo({ nbf: NOW_SECONDS + 1 }),
      ];
      for (const info of cases) {
        await resolveSubjectToken({
          subjectToken: 'x',
          accessTokenResolver: resolverFor(info),
          now: NOW,
        }).catch((error: TokenExchangeError) => {
          codes.push(`${error.code}:${error.errorDescription}`);
        });
      }
      expect(codes).toEqual([
        `invalid_request:${SUBJECT_TOKEN_INVALID_DESCRIPTION}`,
        `invalid_request:${SUBJECT_TOKEN_INVALID_DESCRIPTION}`,
        `invalid_request:${SUBJECT_TOKEN_INVALID_DESCRIPTION}`,
      ]);
    });
  });
});

describe('resolveActorToken', () => {
  it('should return the resolved access token info when the actor token is valid', async () => {
    const info = subjectTokenInfo({ sub: 'service-a', clientId: 'gateway' });
    const resolved = await resolveActorToken({
      actorToken: 'actor-access-token',
      accessTokenResolver: resolverFor(info),
      now: NOW,
    });
    expect(resolved).toEqual(info);
  });

  it('should pass the actor token through to the resolver', async () => {
    const seen: string[] = [];
    const resolver: AccessTokenResolver = {
      findAccessToken: async (token) => {
        seen.push(token);
        return subjectTokenInfo();
      },
    };
    await resolveActorToken({ actorToken: 'actor-access-token', accessTokenResolver: resolver, now: NOW });
    expect(seen).toEqual(['actor-access-token']);
  });

  describe('Invalid actor tokens', () => {
    // subject_token と同じオラクル排除方針: 失敗理由は応答から区別できない。
    it('should reject an unknown actor token with the fixed invalid_request description', async () => {
      await expect(
        resolveActorToken({
          actorToken: 'unknown',
          accessTokenResolver: resolverFor(null),
          now: NOW,
        }),
      ).rejects.toThrow(new TokenExchangeError('invalid_request', ACTOR_TOKEN_INVALID_DESCRIPTION));
    });

    it('should reject an expired actor token with the fixed invalid_request description', async () => {
      await expect(
        resolveActorToken({
          actorToken: 'expired',
          accessTokenResolver: resolverFor(subjectTokenInfo({ expiresAt: NOW_SECONDS - 1 })),
          now: NOW,
        }),
      ).rejects.toThrow(new TokenExchangeError('invalid_request', ACTOR_TOKEN_INVALID_DESCRIPTION));
    });

    it('should reject an actor token whose nbf is in the future with the fixed invalid_request description', async () => {
      await expect(
        resolveActorToken({
          actorToken: 'not-yet-valid',
          accessTokenResolver: resolverFor(subjectTokenInfo({ nbf: NOW_SECONDS + 1 })),
          now: NOW,
        }),
      ).rejects.toThrow(new TokenExchangeError('invalid_request', ACTOR_TOKEN_INVALID_DESCRIPTION));
    });
  });
});

describe('composeActClaim', () => {
  // RFC 8693 §4.1: act claim は現在の actor を識別する。
  it('should build a single-level act claim for the first delegation', () => {
    expect(composeActClaim({ actorSub: 'service-a' })).toEqual({ sub: 'service-a' });
  });

  // RFC 8693 §4.1: 委譲チェーンは act のネストで表す。最外が現在の actor、
  // ネストが過去の actor（最も古い actor が最深）。
  it('should nest the subject token act chain under the current actor', () => {
    expect(
      composeActClaim({
        actorSub: 'service-b',
        subjectActChain: { sub: 'service-a' },
      }),
    ).toEqual({ sub: 'service-b', act: { sub: 'service-a' } });
  });

  it('should keep a two-level prior chain intact under the current actor', () => {
    expect(
      composeActClaim({
        actorSub: 'service-c',
        subjectActChain: { sub: 'service-b', act: { sub: 'service-a' } },
      }),
    ).toEqual({
      sub: 'service-c',
      act: { sub: 'service-b', act: { sub: 'service-a' } },
    });
  });
});

describe('validateExchangeScope', () => {
  it('should inherit the subject scope when scope is omitted', () => {
    expect(validateExchangeScope(undefined, ['openid', 'profile'])).toEqual(['openid', 'profile']);
  });

  it('should inherit the subject scope when scope is blank', () => {
    expect(validateExchangeScope('   ', ['openid', 'profile'])).toEqual(['openid', 'profile']);
  });

  it('should return the requested subset in the requested order', () => {
    expect(validateExchangeScope('api:read openid', ['openid', 'profile', 'api:read'])).toEqual([
      'api:read',
      'openid',
    ]);
  });

  it('should return the full subject scope when every value is requested', () => {
    expect(validateExchangeScope('openid profile', ['openid', 'profile'])).toEqual([
      'openid',
      'profile',
    ]);
  });

  it('should collapse duplicate requested values', () => {
    expect(validateExchangeScope('openid openid', ['openid', 'profile'])).toEqual(['openid']);
  });

  it('should ignore repeated whitespace between scope values', () => {
    expect(validateExchangeScope('openid   profile', ['openid', 'profile'])).toEqual([
      'openid',
      'profile',
    ]);
  });

  // 権限昇格の防止: 交換で scope は単調に縮小する。
  it('should reject a scope value outside the subject scope with invalid_scope', () => {
    expect(() => validateExchangeScope('openid admin', ['openid', 'profile'])).toThrow(
      new TokenExchangeError(
        'invalid_scope',
        'The requested scope exceeds the scope of the subject_token',
      ),
    );
  });

  it('should reject a scope request against an empty subject scope with invalid_scope', () => {
    expect(() => validateExchangeScope('openid', [])).toThrow(
      new TokenExchangeError(
        'invalid_scope',
        'The requested scope exceeds the scope of the subject_token',
      ),
    );
  });
});

describe('resolveExchangeTarget', () => {
  it('should inherit the subject audience when neither audience nor resource is given', () => {
    expect(
      resolveExchangeTarget({
        allowedTargets: ['internal-api'],
        subjectAudience: ['https://op.example.com/userinfo'],
      }),
    ).toEqual(['https://op.example.com/userinfo']);
  });

  it('should return undefined when nothing is requested and the subject has no audience', () => {
    expect(resolveExchangeTarget({ allowedTargets: ['internal-api'] })).toBeUndefined();
  });

  it('should return the requested audience when it is allowed', () => {
    expect(
      resolveExchangeTarget({ audience: 'internal-api', allowedTargets: ['internal-api'] }),
    ).toEqual(['internal-api']);
  });

  it('should return the requested resource when it is allowed', () => {
    expect(
      resolveExchangeTarget({
        resource: 'https://internal.example.com/api',
        allowedTargets: ['https://internal.example.com/api'],
      }),
    ).toEqual(['https://internal.example.com/api']);
  });

  // RFC 8693 §2.1 は audience と resource の併用を許容する。
  it('should return both targets when audience and resource are used together', () => {
    expect(
      resolveExchangeTarget({
        audience: 'internal-api',
        resource: 'https://internal.example.com/api',
        allowedTargets: ['internal-api', 'https://internal.example.com/api'],
      }),
    ).toEqual(['internal-api', 'https://internal.example.com/api']);
  });

  it('should collapse audience and resource when they name the same target', () => {
    expect(
      resolveExchangeTarget({
        audience: 'https://internal.example.com/api',
        resource: 'https://internal.example.com/api',
        allowedTargets: ['https://internal.example.com/api'],
      }),
    ).toEqual(['https://internal.example.com/api']);
  });

  it('should ignore the subject audience when a target is requested explicitly', () => {
    expect(
      resolveExchangeTarget({
        audience: 'internal-api',
        allowedTargets: ['internal-api'],
        subjectAudience: ['https://op.example.com/userinfo'],
      }),
    ).toEqual(['internal-api']);
  });

  describe('Disallowed targets', () => {
    // error_description は allowedTargets の内容を露出しない固定文言。
    it('should reject an audience outside allowedTargets with invalid_target', () => {
      expect(() =>
        resolveExchangeTarget({ audience: 'other-api', allowedTargets: ['internal-api'] }),
      ).toThrow(
        new TokenExchangeError(
          'invalid_target',
          'The requested target is not allowed for token exchange',
        ),
      );
    });

    it('should reject a resource outside allowedTargets with invalid_target', () => {
      expect(() =>
        resolveExchangeTarget({
          resource: 'https://other.example.com/api',
          allowedTargets: ['https://internal.example.com/api'],
        }),
      ).toThrow(
        new TokenExchangeError(
          'invalid_target',
          'The requested target is not allowed for token exchange',
        ),
      );
    });

    // 安全側デフォルト: allowedTargets が空なら対象指定付き交換はすべて拒否される。
    it('should reject any requested audience when allowedTargets is empty', () => {
      expect(() => resolveExchangeTarget({ audience: 'internal-api', allowedTargets: [] })).toThrow(
        new TokenExchangeError(
          'invalid_target',
          'The requested target is not allowed for token exchange',
        ),
      );
    });

    it('should reject a target that only partially matches an allowed entry', () => {
      expect(() =>
        resolveExchangeTarget({ audience: 'internal', allowedTargets: ['internal-api'] }),
      ).toThrow(
        new TokenExchangeError(
          'invalid_target',
          'The requested target is not allowed for token exchange',
        ),
      );
    });
  });
});

describe('computeExchangedTokenLifetime', () => {
  it('should use the configured lifetime when it is shorter than the remaining lifetime', () => {
    expect(
      computeExchangedTokenLifetime({
        subjectExpiresAt: NOW_SECONDS + 3600,
        configuredExpiresIn: 300,
        now: NOW,
      }),
    ).toBe(300);
  });

  // トークン寿命の洗浄の防止: 交換で寿命は延びない。
  it('should cap the lifetime to the remaining lifetime of the subject token', () => {
    expect(
      computeExchangedTokenLifetime({
        subjectExpiresAt: NOW_SECONDS + 300,
        configuredExpiresIn: 3600,
        now: NOW,
      }),
    ).toBe(300);
  });

  it('should return the shared value when both lifetimes are equal', () => {
    expect(
      computeExchangedTokenLifetime({
        subjectExpiresAt: NOW_SECONDS + 3600,
        configuredExpiresIn: 3600,
        now: NOW,
      }),
    ).toBe(3600);
  });

  // 丸め規則の固定検証（仕様書バリデーション 9）: 残存 1 秒でも expires_in は 0 にならない。
  it('should return 1 when only one second of the subject lifetime remains', () => {
    expect(
      computeExchangedTokenLifetime({
        subjectExpiresAt: NOW_SECONDS + 1,
        configuredExpiresIn: 3600,
        now: NOW,
      }),
    ).toBe(1);
  });

  it('should floor a sub-second current time when computing the remaining lifetime', () => {
    expect(
      computeExchangedTokenLifetime({
        subjectExpiresAt: NOW_SECONDS + 10,
        configuredExpiresIn: 3600,
        now: new Date(NOW.getTime() + 900),
      }),
    ).toBe(10);
  });

  it('should reject an already expired subject token with the fixed invalid_request description', () => {
    expect(() =>
      computeExchangedTokenLifetime({
        subjectExpiresAt: NOW_SECONDS,
        configuredExpiresIn: 3600,
        now: NOW,
      }),
    ).toThrow(new TokenExchangeError('invalid_request', SUBJECT_TOKEN_INVALID_DESCRIPTION));
  });

  it('should reject a non-positive configured lifetime with a RangeError', () => {
    expect(() =>
      computeExchangedTokenLifetime({
        subjectExpiresAt: NOW_SECONDS + 300,
        configuredExpiresIn: 0,
        now: NOW,
      }),
    ).toThrow(RangeError);
  });

  it('should reject a fractional configured lifetime with a RangeError', () => {
    expect(() =>
      computeExchangedTokenLifetime({
        subjectExpiresAt: NOW_SECONDS + 300,
        configuredExpiresIn: 1.5,
        now: NOW,
      }),
    ).toThrow(RangeError);
  });
});

describe('buildTokenExchangeResponse', () => {
  // RFC 8693 §2.2.1
  it('should build the full response body with every required member', () => {
    expect(
      buildTokenExchangeResponse({
        accessToken: 'exchanged-token',
        expiresIn: 300,
        scope: ['api:read'],
      }),
    ).toEqual({
      access_token: 'exchanged-token',
      issued_token_type: TOKEN_TYPE_ACCESS_TOKEN,
      token_type: 'Bearer',
      expires_in: 300,
      scope: 'api:read',
    });
  });

  it('should join multiple scope values with a single space', () => {
    expect(
      buildTokenExchangeResponse({
        accessToken: 'exchanged-token',
        expiresIn: 60,
        scope: ['openid', 'api:read'],
      }).scope,
    ).toBe('openid api:read');
  });

  // 発行トークンがアクセストークンである以上 token_type は常に Bearer（N_A は使わない）。
  it('should always report Bearer as the token_type', () => {
    expect(
      buildTokenExchangeResponse({ accessToken: 't', expiresIn: 1, scope: [] }).token_type,
    ).toBe('Bearer');
  });

  it('should not include a refresh_token member', () => {
    expect(
      Object.keys(buildTokenExchangeResponse({ accessToken: 't', expiresIn: 1, scope: [] })).sort(),
    ).toEqual(['access_token', 'expires_in', 'issued_token_type', 'scope', 'token_type']);
  });
});

describe('processTokenExchangeRequest', () => {
  describe('Successful exchanges', () => {
    it('should derive the full grant material for a scope-narrowing exchange', async () => {
      const grant = await processTokenExchangeRequest({
        params: validParams({ scope: 'api:read' }),
        client: confidentialClient(),
        accessTokenResolver: resolverFor(subjectTokenInfo()),
        allowedTargets: [],
        configuredExpiresIn: 3600,
        now: NOW,
      });
      expect(grant).toEqual({
        subject: 'user-1',
        clientId: 'exchange-client',
        scope: ['api:read'],
        requestedAudience: ['https://op.example.com/userinfo'],
        expiresIn: 300,
        grantId: 'grant-1',
      });
    });

    // impersonation: sub は subject_token のものを継承する。
    it('should keep the subject of the subject_token', async () => {
      const grant = await processTokenExchangeRequest({
        params: validParams(),
        client: confidentialClient(),
        accessTokenResolver: resolverFor(subjectTokenInfo({ sub: 'user-42' })),
        allowedTargets: [],
        configuredExpiresIn: 60,
        now: NOW,
      });
      expect(grant.subject).toBe('user-42');
    });

    // 交換後トークンの client_id は「交換を要求したクライアント」。
    it('should set the client id to the requesting client, not the subject token client', async () => {
      const grant = await processTokenExchangeRequest({
        params: validParams(),
        client: confidentialClient({ clientId: 'gateway' }),
        accessTokenResolver: resolverFor(subjectTokenInfo({ clientId: 'front-api' })),
        allowedTargets: [],
        configuredExpiresIn: 60,
        now: NOW,
      });
      expect(grant.clientId).toBe('gateway');
    });

    it('should inherit the subject scope when scope is omitted', async () => {
      const grant = await processTokenExchangeRequest({
        params: validParams(),
        client: confidentialClient(),
        accessTokenResolver: resolverFor(subjectTokenInfo()),
        allowedTargets: [],
        configuredExpiresIn: 60,
        now: NOW,
      });
      expect(grant.scope).toEqual(['openid', 'profile', 'api:read']);
    });

    it('should return the allowed audience as the requested audience', async () => {
      const grant = await processTokenExchangeRequest({
        params: validParams({ audience: 'internal-api' }),
        client: confidentialClient(),
        accessTokenResolver: resolverFor(subjectTokenInfo()),
        allowedTargets: ['internal-api'],
        configuredExpiresIn: 60,
        now: NOW,
      });
      expect(grant.requestedAudience).toEqual(['internal-api']);
    });

    // 失効連動: 交換後トークンは subject の grant に連なる。
    it('should inherit the grant id of the subject token', async () => {
      const grant = await processTokenExchangeRequest({
        params: validParams(),
        client: confidentialClient(),
        accessTokenResolver: resolverFor(subjectTokenInfo({ grantId: 'grant-99' })),
        allowedTargets: [],
        configuredExpiresIn: 60,
        now: NOW,
      });
      expect(grant.grantId).toBe('grant-99');
    });

    it('should leave the grant id undefined when the subject token has none', async () => {
      const grant = await processTokenExchangeRequest({
        params: validParams(),
        client: confidentialClient(),
        accessTokenResolver: resolverFor(subjectTokenInfo({ grantId: undefined })),
        allowedTargets: [],
        configuredExpiresIn: 60,
        now: NOW,
      });
      expect(grant.grantId).toBeUndefined();
    });

    it('should default the current time to now when it is not injected', async () => {
      const grant = await processTokenExchangeRequest({
        params: validParams(),
        client: confidentialClient(),
        accessTokenResolver: resolverFor(
          subjectTokenInfo({ expiresAt: Math.floor(Date.now() / 1000) + 120 }),
        ),
        allowedTargets: [],
        configuredExpiresIn: 3600,
      });
      expect(grant.expiresIn).toBe(120);
    });
  });

  describe('Rejected exchanges', () => {
    it('should reject an unauthorized client before reading the subject token', async () => {
      let resolverCalls = 0;
      const resolver: AccessTokenResolver = {
        findAccessToken: async () => {
          resolverCalls += 1;
          return subjectTokenInfo();
        },
      };
      await processTokenExchangeRequest({
        params: validParams(),
        client: confidentialClient({ grantTypes: ['authorization_code'] }),
        accessTokenResolver: resolver,
        allowedTargets: [],
        configuredExpiresIn: 60,
        now: NOW,
      }).catch(() => undefined);
      expect(resolverCalls).toBe(0);
    });

    it('should reject a public client with unauthorized_client', async () => {
      await expect(
        processTokenExchangeRequest({
          params: validParams(),
          client: confidentialClient({ tokenEndpointAuthMethod: 'none', clientSecret: undefined }),
          accessTokenResolver: resolverFor(subjectTokenInfo()),
          allowedTargets: [],
          configuredExpiresIn: 60,
          now: NOW,
        }),
      ).rejects.toThrow(
        new TokenExchangeError(
          'unauthorized_client',
          'Public clients are not allowed to use the token-exchange grant type',
        ),
      );
    });

    it('should reject an exchange whose scope exceeds the subject scope with invalid_scope', async () => {
      await expect(
        processTokenExchangeRequest({
          params: validParams({ scope: 'admin' }),
          client: confidentialClient(),
          accessTokenResolver: resolverFor(subjectTokenInfo()),
          allowedTargets: [],
          configuredExpiresIn: 60,
          now: NOW,
        }),
      ).rejects.toThrow(
        new TokenExchangeError(
          'invalid_scope',
          'The requested scope exceeds the scope of the subject_token',
        ),
      );
    });

    it('should reject an exchange to a disallowed audience with invalid_target', async () => {
      await expect(
        processTokenExchangeRequest({
          params: validParams({ audience: 'other-api' }),
          client: confidentialClient(),
          accessTokenResolver: resolverFor(subjectTokenInfo()),
          allowedTargets: ['internal-api'],
          configuredExpiresIn: 60,
          now: NOW,
        }),
      ).rejects.toThrow(
        new TokenExchangeError(
          'invalid_target',
          'The requested target is not allowed for token exchange',
        ),
      );
    });

    it('should reject an expired subject token with invalid_request', async () => {
      await expect(
        processTokenExchangeRequest({
          params: validParams(),
          client: confidentialClient(),
          accessTokenResolver: resolverFor(subjectTokenInfo({ expiresAt: NOW_SECONDS - 1 })),
          allowedTargets: [],
          configuredExpiresIn: 60,
          now: NOW,
        }),
      ).rejects.toThrow(
        new TokenExchangeError('invalid_request', SUBJECT_TOKEN_INVALID_DESCRIPTION),
      );
    });

    it('should reject an unknown actor_token with invalid_request', async () => {
      await expect(
        processTokenExchangeRequest({
          params: validParams({
            actor_token: 'unknown-actor-token',
            actor_token_type: TOKEN_TYPE_ACCESS_TOKEN,
          }),
          client: confidentialClient(),
          accessTokenResolver: resolverByToken({
            'subject-access-token': subjectTokenInfo(),
          }),
          allowedTargets: [],
          configuredExpiresIn: 60,
          now: NOW,
        }),
      ).rejects.toThrow(
        new TokenExchangeError('invalid_request', ACTOR_TOKEN_INVALID_DESCRIPTION),
      );
    });

    it('should reject an expired actor_token with invalid_request', async () => {
      await expect(
        processTokenExchangeRequest({
          params: validParams({
            actor_token: 'actor-access-token',
            actor_token_type: TOKEN_TYPE_ACCESS_TOKEN,
          }),
          client: confidentialClient(),
          accessTokenResolver: resolverByToken({
            'subject-access-token': subjectTokenInfo(),
            'actor-access-token': subjectTokenInfo({
              sub: 'service-a',
              expiresAt: NOW_SECONDS - 1,
            }),
          }),
          allowedTargets: [],
          configuredExpiresIn: 60,
          now: NOW,
        }),
      ).rejects.toThrow(
        new TokenExchangeError('invalid_request', ACTOR_TOKEN_INVALID_DESCRIPTION),
      );
    });
  });

  describe('Delegation exchanges (RFC 8693 §1.1 / §4.1)', () => {
    it('should record the actor of a delegation exchange in the grant material', async () => {
      const grant = await processTokenExchangeRequest({
        params: validParams({
          scope: 'api:read',
          actor_token: 'actor-access-token',
          actor_token_type: TOKEN_TYPE_ACCESS_TOKEN,
        }),
        client: confidentialClient(),
        accessTokenResolver: resolverByToken({
          'subject-access-token': subjectTokenInfo(),
          'actor-access-token': subjectTokenInfo({ sub: 'service-a', clientId: 'gateway' }),
        }),
        allowedTargets: [],
        configuredExpiresIn: 3600,
        now: NOW,
      });
      expect(grant).toEqual({
        subject: 'user-1',
        clientId: 'exchange-client',
        scope: ['api:read'],
        requestedAudience: ['https://op.example.com/userinfo'],
        expiresIn: 300,
        grantId: 'grant-1',
        actor: { sub: 'service-a' },
      });
    });

    // delegation でも sub は subject_token のもの。actor は act にのみ現れる。
    it('should keep the subject unchanged in a delegation exchange', async () => {
      const grant = await processTokenExchangeRequest({
        params: validParams({
          actor_token: 'actor-access-token',
          actor_token_type: TOKEN_TYPE_ACCESS_TOKEN,
        }),
        client: confidentialClient(),
        accessTokenResolver: resolverByToken({
          'subject-access-token': subjectTokenInfo({ sub: 'user-42' }),
          'actor-access-token': subjectTokenInfo({ sub: 'service-a' }),
        }),
        allowedTargets: [],
        configuredExpiresIn: 60,
        now: NOW,
      });
      expect(grant).toMatchObject({
        subject: 'user-42',
        actor: { sub: 'service-a' },
      });
    });

    it('should leave the actor undefined for an impersonation exchange', async () => {
      const grant = await processTokenExchangeRequest({
        params: validParams(),
        client: confidentialClient(),
        accessTokenResolver: resolverFor(subjectTokenInfo()),
        allowedTargets: [],
        configuredExpiresIn: 60,
        now: NOW,
      });
      expect(grant.actor).toBeUndefined();
    });

    // RFC 8693 §4.1: subject_token が既に act を持つ（＝それ自体が委譲で発行された）
    // 場合、過去の actor はネストへ押し下がり、最外は今回の actor になる。
    it('should chain the prior actor when the subject token already carries an act claim', async () => {
      const delegatedSubject: ExchangedAccessTokenInfo = {
        ...subjectTokenInfo(),
        act: { sub: 'service-a' },
      };
      const grant = await processTokenExchangeRequest({
        params: validParams({
          actor_token: 'actor-access-token',
          actor_token_type: TOKEN_TYPE_ACCESS_TOKEN,
        }),
        client: confidentialClient(),
        accessTokenResolver: resolverByToken({
          'subject-access-token': delegatedSubject,
          'actor-access-token': subjectTokenInfo({ sub: 'service-b' }),
        }),
        allowedTargets: [],
        configuredExpiresIn: 60,
        now: NOW,
      });
      expect(grant.actor).toEqual({ sub: 'service-b', act: { sub: 'service-a' } });
    });

    // 設計判断: 有効期間の cap は subject_token の残存期間だけで決まる。actor_token は
    // 交換時点の本人性確認に使うのであって、発行後トークンの寿命は actor に連動しない。
    it('should not cap the lifetime by the actor token expiry', async () => {
      const grant = await processTokenExchangeRequest({
        params: validParams({
          actor_token: 'actor-access-token',
          actor_token_type: TOKEN_TYPE_ACCESS_TOKEN,
        }),
        client: confidentialClient(),
        accessTokenResolver: resolverByToken({
          'subject-access-token': subjectTokenInfo({ expiresAt: NOW_SECONDS + 300 }),
          'actor-access-token': subjectTokenInfo({
            sub: 'service-a',
            expiresAt: NOW_SECONDS + 30,
          }),
        }),
        allowedTargets: [],
        configuredExpiresIn: 3600,
        now: NOW,
      });
      expect(grant.expiresIn).toBe(300);
    });

    // grantId は subject 側を継承する。actor の grant には連ならない。
    it('should inherit the grant id from the subject token, not the actor token', async () => {
      const grant = await processTokenExchangeRequest({
        params: validParams({
          actor_token: 'actor-access-token',
          actor_token_type: TOKEN_TYPE_ACCESS_TOKEN,
        }),
        client: confidentialClient(),
        accessTokenResolver: resolverByToken({
          'subject-access-token': subjectTokenInfo({ grantId: 'grant-subject' }),
          'actor-access-token': subjectTokenInfo({ sub: 'service-a', grantId: 'grant-actor' }),
        }),
        allowedTargets: [],
        configuredExpiresIn: 60,
        now: NOW,
      });
      expect(grant.grantId).toBe('grant-subject');
    });
  });
});
```

## CLI integration and the generated-code contribution

Running `maronn-oidc generate <framework> --enable token-exchange` adds the following to the generated code:

- **routes/token.ts (changed)**: after the token endpoint's shared client authentication, and before core's `validateGrantTypeSupported` would reject the URN, a `grant_type === TOKEN_EXCHANGE_GRANT_TYPE` branch is inserted. It calls `processTokenExchangeRequest` and feeds the returned material into core's issuance pipeline, answering the request inside the branch. `tokenExchangeConfig` (`allowedTargets: []`, an empty, fail-safe default) also lands in this file
- **routes/discovery.ts (changed)**: `grant_types_supported` gains the exchange URN
- **config.ts (changed)**: the sample confidential client registers the exchange URN in its `grantTypes`
- **conformance.test.ts (changed)**: the exchange's success and failure behaviors, including delegation and the act claim, are pinned as contract tests

No new route appears.
The integration takes the shape of one more grant branch inside the existing `POST /token`.

Earlier revisions of this guide embedded the contribution as one long unified diff; without syntax highlighting it was close to unreadable.
The same contribution is now shown file by file: each block below is the exact TypeScript that `--enable token-exchange` adds or changes, and the surrounding text states where in the file it lands.
The machine-checked diff form still exists in the promotion-review packet linked under "Related material".

### What lands in config.ts

The sample confidential client's `grantTypes` gains the exchange URN (inside `defaultRegisteredClients`).
Removing the URN from a client is how an operator forbids exchanges for it.

```typescript
      // RFC 7591 §2: grant_types default is ["authorization_code"]. Registering
      // refresh_token is the single switch that lets this client receive refresh
      // tokens at all: an online refresh token (bound to the login session) on every
      // authorization, and an offline one (usable after logout) when offline_access
      // is granted per OIDC Core 1.0 §11. Remove it and neither is issued.
      // EXPERIMENTAL (RFC 8693): registering the token-exchange URN is what lets
      // this confidential client exchange its access tokens. Remove it to forbid
      // exchanges for this client; public clients are rejected either way.
      grantTypes: ['authorization_code', 'refresh_token', 'urn:ietf:params:oauth:grant-type:token-exchange'],
```

### What lands in routes/discovery.ts

One line changes: `grantTypesSupported` advertises the exchange URN.

```typescript
    grantTypesSupported: ['authorization_code', 'refresh_token', 'urn:ietf:params:oauth:grant-type:token-exchange'],
```

### What lands in routes/token.ts

Two additions appear at the top of the file: the access-token resolver (used to validate subject and actor tokens) joins the resolver imports, and the exchange functions arrive from the experimental subpath.

```typescript
  accessTokenResolver as defaultAccessTokenResolver,
```

```typescript
import {
  TOKEN_EXCHANGE_GRANT_TYPE,
  TokenExchangeError,
  buildTokenExchangeResponse,
  processTokenExchangeRequest,
  type ExchangedAccessTokenInfo,
} from '@maronn-openid-connect/experimental/token-exchange';
```

Next to the imports, the module-level policy object is exported.
The empty default means every exchange that names a target is refused with `invalid_target` until the operator lists downstream services here.

```typescript
/**
 * EXPERIMENTAL — OAuth 2.0 Token Exchange settings (RFC 8693).
 *
 * - allowedTargets: the audience / resource values a client may ask an
 *   exchanged token to be issued for. Empty by default (fail safe): with an
 *   empty list every exchange that names a target is rejected with
 *   invalid_target, and only scope-narrowing / lifetime-shortening exchanges
 *   succeed. Add the identifiers of your downstream services here.
 */
export const tokenExchangeConfig = {
  allowedTargets: [] as string[],
};
```

The grant branch itself is inserted right after client authentication, before the standard token pipeline.
It validates through `processTokenExchangeRequest`, issues through core's ordinary pipeline (audience composition, payload, signing, store), and answers inside the branch.
The two `grant.actor` spreads are the delegation additions: the act claim goes into the JWT payload and into the store metadata, the latter so a later exchange of this token can extend the chain.

```typescript
    // --- EXPERIMENTAL: OAuth 2.0 Token Exchange (RFC 8693 §2.1) ------------
    // Dispatched right after client authentication and BEFORE core's
    // validateGrantTypeSupported, which does not know the URN and would reject
    // it with unsupported_grant_type. The branch answers the request itself and
    // never falls through to the standard grants.
    //
    // Backed by @maronn-openid-connect/experimental, whose API is NOT stable: it may change
    // in a breaking way between releases. Do not build production code on it
    // without pinning the version.
    //
    // Known limitation: RFC 8693 §2.1 permits repeated `resource` / `audience`
    // parameters, but this endpoint rejects any repeated parameter (RFC 6749
    // §3.2), so only a single value of each is supported.
    if (params.grant_type === TOKEN_EXCHANGE_GRANT_TYPE) {
      const accessTokenResolver = c.get('accessTokenResolver') ?? defaultAccessTokenResolver;
      // config / privateKey / keyId are bound further down for the standard
      // grants. This branch reads them on its own so the generated output is
      // unchanged when the feature is off; it returns, so nothing runs twice.
      const exchangeConfig = c.get('config');
      const exchangeIssuer: AccessTokenIssuer =
        exchangeConfig.accessTokenFormat === 'opaque'
          ? createOpaqueAccessTokenIssuer()
          : createJwtAccessTokenIssuer();

      // Validate the request and derive the issuing material. Each check inside
      // is also exported as its own step function, so you can call them one by
      // one instead and drop or replace individual rules.
      const grant = await processTokenExchangeRequest({
        params,
        client: tokenClient,
        accessTokenResolver,
        allowedTargets: tokenExchangeConfig.allowedTargets,
        configuredExpiresIn: exchangeConfig.accessTokenExpiresIn,
      });

      // Same aud policy as the standard token route: the UserInfo endpoint stays
      // a permanent member (RFC 9068 §3), so an exchanged token still passes the
      // UserInfo endpoint's audience check.
      const exchangeAudience = buildAccessTokenAudience({
        userInfoEndpoint: `${exchangeConfig.issuer}/userinfo`,
        requested: grant.requestedAudience,
        issuer: exchangeConfig.issuer,
      });

      const exchangeIssuedAt = Math.floor(Date.now() / 1000);
      const exchangePayload = buildAccessTokenPayload({
        issuer: exchangeConfig.issuer,
        subject: grant.subject,
        clientId: grant.clientId,
        scope: grant.scope,
        audience: exchangeAudience,
        expiresIn: grant.expiresIn,
        issuedAt: exchangeIssuedAt,
      });
      const exchangedToken = await exchangeIssuer.issue({
        payload: {
          ...exchangePayload,
          // RFC 8693 §4.1: a delegation exchange records the current actor in
          // the act claim (chains already nested by processTokenExchangeRequest).
          // Impersonation exchanges carry no act claim.
          ...(grant.actor === undefined ? {} : { act: grant.actor }),
        },
        privateKey: c.get('privateKey'),
        keyId: c.get('keyId'),
      });

      const exchangeMetadata: ExchangedAccessTokenInfo = {
        // RFC 8693 §1.1: the exchanged token acts as the same subject, but is
        // bound to the client that requested the exchange.
        sub: grant.subject,
        clientId: grant.clientId,
        scope: grant.scope,
        expiresAt: exchangeIssuedAt + grant.expiresIn,
        // Inherit the subject token's grant so revoking the grant (e.g. on code
        // reuse detection) also kills every token exchanged from it.
        grantId: grant.grantId,
        iat: exchangeIssuedAt,
        nbf: exchangeIssuedAt,
        audience: exchangeAudience,
        issuer: exchangeConfig.issuer,
        // RFC 9068 §2.2 / RFC 7662 §2.2: the exchanged token gets its own jti,
        // so it is a distinct store record even when it is exchanged twice from
        // the same subject_token within one second.
        jti: exchangePayload.jti,
        // Persisting act lets a later exchange that presents THIS token as its
        // subject_token pick up the chain (RFC 8693 §4.1 nesting).
        ...(grant.actor === undefined ? {} : { act: grant.actor }),
        // The subject token's stored claims parameter (OIDC Core 1.0 §5.5) is
        // deliberately NOT inherited: an exchanged token yields scope-based
        // claims only at the UserInfo endpoint.
      };
      await accessTokenStore.set(exchangedToken, exchangeMetadata);

      // RFC 6749 §5.1: token responses MUST NOT be cached.
      c.header('Cache-Control', 'no-store');
      c.header('Pragma', 'no-cache');
      // RFC 8693 §2.2.1: access_token / issued_token_type / token_type are
      // REQUIRED; expires_in and scope are always included here.
      return c.json(buildTokenExchangeResponse({
        accessToken: exchangedToken,
        expiresIn: grant.expiresIn,
        scope: grant.scope,
      }));
    }
```

Finally, the token route's catch block learns to translate `TokenExchangeError` (always a 400 with the RFC 6749 §5.2 body shape, plus `invalid_target`).

```typescript
    if (error instanceof TokenExchangeError) {
      // RFC 8693 §2.2.2: the exchange errors use the RFC 6749 §5.2 shape. They
      // are always 400 — a 401 can only come from client authentication, which
      // runs before the branch and throws core's TokenError.
      c.header('Cache-Control', 'no-store');
      c.header('Pragma', 'no-cache');
      return c.json(
        { error: error.code, error_description: error.errorDescription },
        error.statusCode,
      );
    }
```

### What lands in conformance.test.ts

One import, two extra registered test clients, and the contract-test block.
The clients: a confidential one registered for the exchange grant, and a public one also registered for it, which pins that public clients are refused even when the URN is registered.

```typescript
import { tokenExchangeConfig } from './routes/token.js';
```

```typescript
  // EXPERIMENTAL (RFC 8693): a confidential client registered for the exchange
  // grant, and a public one registered for it as well — the latter pins that a
  // public client is rejected even when the URN is registered.
  ['c-exchange', {
    clientId: 'c-exchange',
    clientSecret: 's',
    redirectUris: [REDIRECT_URI],
    clientType: 'confidential' as const,
    responseTypes: ['code'],
    grantTypes: ['authorization_code', 'urn:ietf:params:oauth:grant-type:token-exchange'],
    tokenEndpointAuthMethod: 'client_secret_post',
  }],
  ['c-public-exchange', {
    clientId: 'c-public-exchange',
    redirectUris: [REDIRECT_URI],
    clientType: 'public' as const,
    responseTypes: ['code'],
    grantTypes: ['authorization_code', 'urn:ietf:params:oauth:grant-type:token-exchange'],
    tokenEndpointAuthMethod: 'none',
  }],
```

The contract tests drive the full authorization-code flow over HTTP to obtain live subject and actor tokens (the second seeded user, `otheruser`, provides an actor whose `sub` differs from the subject's), then pin every success and failure behavior, including decoding the issued JWT to check the `act` claim.

```typescript
  // EXPERIMENTAL — OAuth 2.0 Token Exchange (RFC 8693). Generated because this
  // provider was created with --enable token-exchange. These tests pin the
  // contract the repository guarantees for the generated exchange grant: change
  // the behavior and they fail, which is how a customized OP learns it drifted.
  describe('Token Exchange (RFC 8693)', () => {
    // RFC 7636 Appendix B example PKCE pair (verifier -> its S256 challenge).
    const PKCE_VERIFIER = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
    const PKCE_CHALLENGE_S256 = 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM';
    const EXCHANGE_GRANT_TYPE = 'urn:ietf:params:oauth:grant-type:token-exchange';
    const ACCESS_TOKEN_TYPE = 'urn:ietf:params:oauth:token-type:access_token';
    // The exchange rejects every kind of unusable subject_token / actor_token
    // with one description each, so the response cannot be used as an existence
    // oracle.
    const SUBJECT_INVALID_DESCRIPTION = 'The provided subject_token is not valid';
    const ACTOR_INVALID_DESCRIPTION = 'The provided actor_token is not valid';
    const TARGET_REJECTED_DESCRIPTION =
      'The requested target is not allowed for token exchange';

    // Pure helpers: they fetch and parse only. Every assertion lives in an it().
    function relativeFrom(location: string | null): string {
      const url = new URL(location ?? '', 'http://localhost');
      return url.pathname + url.search;
    }

    function csrfFrom(html: string): string {
      return html.match(/name="csrf_token" value="([^"]+)"/)?.[1] ?? '';
    }

    function postToken(fields: Record<string, string>): Promise<Response> {
      return app.request('/token', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams(fields).toString(),
      });
    }

    function exchangeRequest(overrides: Record<string, string> = {}): Promise<Response> {
      return postToken({
        client_id: 'c-exchange',
        client_secret: 's',
        grant_type: EXCHANGE_GRANT_TYPE,
        subject_token_type: ACCESS_TOKEN_TYPE,
        ...overrides,
      });
    }

    // Decode a JWT access token's payload (base64url, RFC 7515 §2) so the act
    // claim of a delegated token can be pinned. The generated default issues
    // JWT access tokens (config.accessTokenFormat: 'jwt').
    function decodeJwtPayload(token: string): Record<string, unknown> {
      const segment = token.split('.')[1] ?? '';
      const base64 = segment.replace(/-/g, '+').replace(/_/g, '/');
      const padded = base64 + '='.repeat((4 - (base64.length % 4)) % 4);
      return JSON.parse(atob(padded)) as Record<string, unknown>;
    }

    // Drive authorize -> login -> consent over HTTP and hand back the code. No
    // assertions and no branching here: the flow contract lives in the it()s.
    async function authorizeFlow(
      clientId: string,
      scope: string,
      claims?: string,
      username = 'testuser',
    ): Promise<string> {
      const authorizeUrl =
        '/authorize?response_type=code&client_id=' + clientId +
        '&redirect_uri=' + encodeURIComponent(REDIRECT_URI) +
        '&scope=' + encodeURIComponent(scope) +
        '&state=tx-state&nonce=tx-nonce' +
        (claims === undefined ? '' : '&claims=' + encodeURIComponent(claims)) +
        '&code_challenge=' + PKCE_CHALLENGE_S256 + '&code_challenge_method=S256';

      const authorizeRes = await app.request(authorizeUrl);
      const loginPath = relativeFrom(authorizeRes.headers.get('Location'));
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
          csrf_token: csrfFrom(await loginGet.text()),
          username,
          password: 'password',
        }).toString(),
      });
      const consentPath = relativeFrom(loginRes.headers.get('Location'));

      const consentGet = await app.request(consentPath, { headers: { Cookie: bindingCookie } });
      const consentRes = await app.request('/consent', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded', Cookie: bindingCookie },
        body: new URLSearchParams({
          transaction_id: transactionId,
          csrf_token: csrfFrom(await consentGet.text()),
          action: 'approve',
        }).toString(),
      });
      const callback = new URL(consentRes.headers.get('Location') ?? '', 'http://localhost');
      return callback.searchParams.get('code') ?? '';
    }

    // A subject_token obtained through the ordinary Authorization Code Flow.
    async function subjectTokenFor(
      scope: string,
      clientId = 'c-exchange',
      claims?: string,
      username = 'testuser',
    ): Promise<string> {
      const code = await authorizeFlow(clientId, scope, claims, username);
      const res = await postToken({
        client_id: clientId,
        ...(clientId === 'c-public-exchange' ? {} : { client_secret: 's' }),
        grant_type: 'authorization_code',
        code,
        redirect_uri: REDIRECT_URI,
        code_verifier: PKCE_VERIFIER,
      });
      return ((await res.json()) as Record<string, string>).access_token;
    }

    // An actor_token with a sub distinct from the subject: the second seeded
    // user runs the same flow, so delegation tests can tell subject and actor
    // apart in the act claim.
    function actorTokenFor(scope: string): Promise<string> {
      return subjectTokenFor(scope, 'c-exchange', undefined, 'otheruser');
    }

    describe('Successful exchange', () => {
      it('should return every RFC 8693 §2.2.1 response member for a scope-narrowing exchange', async () => {
        const subjectToken = await subjectTokenFor('openid profile email');
        const res = await exchangeRequest({ subject_token: subjectToken, scope: 'openid profile' });
        const body = await res.json();

        expect(res.status).toBe(200);
        expect(res.headers.get('Cache-Control')).toBe('no-store');
        expect(res.headers.get('Pragma')).toBe('no-cache');
        expect(Object.keys(body).sort()).toEqual([
          'access_token',
          'expires_in',
          'issued_token_type',
          'scope',
          'token_type',
        ]);
        expect(body.issued_token_type).toBe(ACCESS_TOKEN_TYPE);
        expect(body.token_type).toBe('Bearer');
        expect(body.scope).toBe('openid profile');
        expect(body.expires_in).toBe(3600);
      });

      it('should inherit the subject scope when scope is omitted', async () => {
        const subjectToken = await subjectTokenFor('openid profile');
        const res = await exchangeRequest({ subject_token: subjectToken });

        expect(res.status).toBe(200);
        expect((await res.json()).scope).toBe('openid profile');
      });

      // RFC 8693 §2.2.1: token exchange does not issue a refresh token here.
      it('should not issue a refresh token from an exchange', async () => {
        const subjectToken = await subjectTokenFor('openid');
        const res = await exchangeRequest({ subject_token: subjectToken });

        expect((await res.json()).refresh_token).toBe(undefined);
      });

      // The exchanged token is an ordinary access token in the store, so every
      // existing endpoint keeps working with it.
      it('should return a token that the UserInfo endpoint accepts', async () => {
        const subjectToken = await subjectTokenFor('openid profile');
        const exchanged = (await (await exchangeRequest({ subject_token: subjectToken })).json())
          .access_token as string;
        const res = await app.request('/userinfo', {
          headers: { Authorization: 'Bearer ' + exchanged },
        });

        expect(res.status).toBe(200);
        expect((await res.json()).sub).toBe('testuser');
      });

      // RFC 8693 §1.1 impersonation: sub is inherited, client_id is the caller.
      it('should bind the exchanged token to the requesting client and the original subject', async () => {
        const subjectToken = await subjectTokenFor('openid');
        const exchanged = (await (await exchangeRequest({ subject_token: subjectToken })).json())
          .access_token as string;
        const res = await app.request('/introspect', {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: new URLSearchParams({
            client_id: 'c-exchange',
            client_secret: 's',
            token: exchanged,
          }).toString(),
        });
        const body = await res.json();

        expect(body.active).toBe(true);
        expect(body.sub).toBe('testuser');
        expect(body.client_id).toBe('c-exchange');
        expect(body.aud).toEqual(['http://localhost:3000/userinfo']);
      });

      // The subject token stays usable: RFC 8693 does not make it single use.
      it('should leave the subject token valid after an exchange', async () => {
        const subjectToken = await subjectTokenFor('openid');
        await exchangeRequest({ subject_token: subjectToken });
        const res = await app.request('/userinfo', {
          headers: { Authorization: 'Bearer ' + subjectToken },
        });

        expect(res.status).toBe(200);
      });

      // The exchanged token never outlives the subject token, so a chain of
      // exchanges cannot launder a token into a longer lifetime.
      it('should not extend the lifetime beyond the subject token', async () => {
        const subjectToken = await subjectTokenFor('openid');
        const first = (await (await exchangeRequest({ subject_token: subjectToken })).json()) as
          Record<string, number | string>;
        const second = (await (
          await exchangeRequest({ subject_token: first.access_token as string })
        ).json()) as Record<string, number | string>;

        expect((second.expires_in as number) <= (first.expires_in as number)).toBe(true);
      });

      // OIDC Core 1.0 §5.5: the consented claims request is NOT carried over, so
      // an exchanged token yields scope-based claims only.
      it('should not inherit the claims parameter of the subject token', async () => {
        const claims = JSON.stringify({ userinfo: { name: { essential: true } } });
        const subjectToken = await subjectTokenFor('openid', 'c-exchange', claims);
        const subjectUserInfo = await (
          await app.request('/userinfo', { headers: { Authorization: 'Bearer ' + subjectToken } })
        ).json();
        const exchanged = (await (await exchangeRequest({ subject_token: subjectToken })).json())
          .access_token as string;
        const exchangedUserInfo = await (
          await app.request('/userinfo', { headers: { Authorization: 'Bearer ' + exchanged } })
        ).json();

        expect(subjectUserInfo.name).toBe('Test User');
        expect(exchangedUserInfo.name).toBe(undefined);
      });

      // RFC 9068 §2.2 / RFC 7519 §4.1.7: each exchanged token gets its own jti.
      // Two exchanges of the same subject_token land in the same wall-clock second
      // with identical claims; without jti the deterministic RS256 signature
      // (RFC 8017 §8.2) would make them one string and one store record, so
      // revoking one would revoke the other.
      it('should issue a distinct token for each exchange of the same subject token', async () => {
        const subjectToken = await subjectTokenFor('openid');
        const first = (await (await exchangeRequest({ subject_token: subjectToken })).json())
          .access_token as string;
        const second = (await (await exchangeRequest({ subject_token: subjectToken })).json())
          .access_token as string;

        const firstUserInfo = await app.request('/userinfo', { headers: { Authorization: 'Bearer ' + first } });
        const secondUserInfo = await app.request('/userinfo', { headers: { Authorization: 'Bearer ' + second } });

        expect(first === second).toBe(false);
        expect(firstUserInfo.status).toBe(200);
        expect(secondUserInfo.status).toBe(200);
      });
    });

    describe('Client authorization', () => {
      it('should reject an unauthenticated exchange with 401 invalid_client', async () => {
        const subjectToken = await subjectTokenFor('openid');
        const res = await postToken({
          client_id: 'c-exchange',
          grant_type: EXCHANGE_GRANT_TYPE,
          subject_token: subjectToken,
          subject_token_type: ACCESS_TOKEN_TYPE,
        });

        expect(res.status).toBe(401);
        expect((await res.json()).error).toBe('invalid_client');
      });

      // RFC 6749 §5.2: the exchange URN must be registered on the client.
      it('should reject a client that has not registered the exchange grant', async () => {
        const subjectToken = await subjectTokenFor('openid');
        const res = await postToken({
          client_id: 'c-conf',
          client_secret: 's',
          grant_type: EXCHANGE_GRANT_TYPE,
          subject_token: subjectToken,
          subject_token_type: ACCESS_TOKEN_TYPE,
        });

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'unauthorized_client',
          error_description: 'The client is not authorized to use the token-exchange grant type',
        });
      });

      // RFC 8693 §2.1 notes that skipping client authentication lets a stolen
      // token be amplified through the STS, so public clients are refused.
      it('should reject a public client even when it registered the exchange grant', async () => {
        const subjectToken = await subjectTokenFor('openid', 'c-public-exchange');
        const res = await postToken({
          client_id: 'c-public-exchange',
          grant_type: EXCHANGE_GRANT_TYPE,
          subject_token: subjectToken,
          subject_token_type: ACCESS_TOKEN_TYPE,
        });

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'unauthorized_client',
          error_description: 'Public clients are not allowed to use the token-exchange grant type',
        });
      });
    });

    describe('Parameter validation', () => {
      it('should reject a missing subject_token with invalid_request', async () => {
        const res = await exchangeRequest({});

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_request',
          error_description: 'subject_token is required',
        });
      });

      it('should reject an unsupported subject_token_type with invalid_request', async () => {
        const subjectToken = await subjectTokenFor('openid');
        const res = await exchangeRequest({
          subject_token: subjectToken,
          subject_token_type: 'urn:ietf:params:oauth:token-type:id_token',
        });

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_request',
          error_description:
            'Unsupported subject_token_type. Only urn:ietf:params:oauth:token-type:access_token is supported.',
        });
      });

      it('should reject an unsupported requested_token_type with invalid_request', async () => {
        const subjectToken = await subjectTokenFor('openid');
        const res = await exchangeRequest({
          subject_token: subjectToken,
          requested_token_type: 'urn:ietf:params:oauth:token-type:refresh_token',
        });

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_request',
          error_description:
            'Unsupported requested_token_type. Only urn:ietf:params:oauth:token-type:access_token is supported.',
        });
      });

      // RFC 8693 §2.1: actor_token_type is REQUIRED when actor_token is present.
      it('should reject actor_token without actor_token_type', async () => {
        const subjectToken = await subjectTokenFor('openid');
        const res = await exchangeRequest({
          subject_token: subjectToken,
          actor_token: subjectToken,
        });

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_request',
          error_description: 'actor_token_type is required when actor_token is present',
        });
      });

      // RFC 8693 §2.1: actor_token_type MUST NOT be included without actor_token.
      it('should reject actor_token_type without actor_token', async () => {
        const subjectToken = await subjectTokenFor('openid');
        const res = await exchangeRequest({
          subject_token: subjectToken,
          actor_token_type: ACCESS_TOKEN_TYPE,
        });

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_request',
          error_description: 'actor_token_type must not be present without actor_token',
        });
      });

      it('should reject an unsupported actor_token_type with invalid_request', async () => {
        const subjectToken = await subjectTokenFor('openid');
        const res = await exchangeRequest({
          subject_token: subjectToken,
          actor_token: subjectToken,
          actor_token_type: 'urn:ietf:params:oauth:token-type:id_token',
        });

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_request',
          error_description:
            'Unsupported actor_token_type. Only urn:ietf:params:oauth:token-type:access_token is supported.',
        });
      });

      // The actor_token failure description is fixed for the same oracle-
      // elimination reason as the subject_token one.
      it('should reject an unknown actor_token with the fixed description', async () => {
        const subjectToken = await subjectTokenFor('openid');
        const res = await exchangeRequest({
          subject_token: subjectToken,
          actor_token: 'not-a-real-token',
          actor_token_type: ACCESS_TOKEN_TYPE,
        });

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_request',
          error_description: ACTOR_INVALID_DESCRIPTION,
        });
      });

      // RFC 8693 §2.1: resource MUST be an absolute URI without a fragment.
      it('should reject a relative resource with invalid_request', async () => {
        const subjectToken = await subjectTokenFor('openid');
        const res = await exchangeRequest({ subject_token: subjectToken, resource: '/api' });

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_request',
          error_description: 'resource must be an absolute URI without a fragment component',
        });
      });

      it('should reject a resource carrying a fragment with invalid_request', async () => {
        const subjectToken = await subjectTokenFor('openid');
        const res = await exchangeRequest({
          subject_token: subjectToken,
          resource: 'https://api.example.com/x#frag',
        });

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_request',
          error_description: 'resource must be an absolute URI without a fragment component',
        });
      });

      // RFC 6749 §3.2: repeated token endpoint parameters are refused, which is
      // why this OP supports only a single audience / resource value.
      it('should reject a repeated resource parameter', async () => {
        const subjectToken = await subjectTokenFor('openid');
        const res = await app.request('/token', {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body:
            'client_id=c-exchange&client_secret=s&grant_type=' +
            encodeURIComponent(EXCHANGE_GRANT_TYPE) +
            '&subject_token=' + encodeURIComponent(subjectToken) +
            '&subject_token_type=' + encodeURIComponent(ACCESS_TOKEN_TYPE) +
            '&resource=https%3A%2F%2Fa.example.com&resource=https%3A%2F%2Fb.example.com',
        });

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_request',
          error_description: 'Parameter "resource" must not be repeated',
        });
      });

      // RFC 8693 §2.2.2 sends invalid subject tokens to invalid_request, NOT to
      // invalid_grant as the authorization_code / refresh_token grants would.
      it('should reject an unknown subject_token with invalid_request', async () => {
        const res = await exchangeRequest({ subject_token: 'not-a-real-token' });

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_request',
          error_description: SUBJECT_INVALID_DESCRIPTION,
        });
      });

      it('should report a revoked subject_token exactly like an unknown one', async () => {
        const subjectToken = await subjectTokenFor('openid');
        await app.request('/revoke', {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: new URLSearchParams({
            client_id: 'c-exchange',
            client_secret: 's',
            token: subjectToken,
          }).toString(),
        });
        const revoked = await exchangeRequest({ subject_token: subjectToken });
        const unknown = await exchangeRequest({ subject_token: 'not-a-real-token' });

        expect(revoked.status).toBe(400);
        expect(await revoked.json()).toEqual(await unknown.json());
      });
    });

    describe('Scope narrowing', () => {
      it('should reject a scope that exceeds the subject token scope', async () => {
        const subjectToken = await subjectTokenFor('openid');
        const res = await exchangeRequest({ subject_token: subjectToken, scope: 'openid profile' });

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_scope',
          error_description: 'The requested scope exceeds the scope of the subject_token',
        });
      });

      it('should grant exactly the requested subset', async () => {
        const subjectToken = await subjectTokenFor('openid profile email');
        const res = await exchangeRequest({ subject_token: subjectToken, scope: 'email' });

        expect(res.status).toBe(200);
        expect((await res.json()).scope).toBe('email');
      });
    });

    describe('Delegation (RFC 8693 §4.1)', () => {
      // sub stays the subject; the actor appears only in the act claim.
      it('should record the actor in the act claim of the issued token', async () => {
        const subjectToken = await subjectTokenFor('openid profile');
        const actorToken = await actorTokenFor('openid');
        const res = await exchangeRequest({
          subject_token: subjectToken,
          actor_token: actorToken,
          actor_token_type: ACCESS_TOKEN_TYPE,
        });
        const body = await res.json();
        const payload = decodeJwtPayload(body.access_token as string);

        expect(res.status).toBe(200);
        expect(payload.sub).toBe('testuser');
        expect(payload.act).toEqual({ sub: 'otheruser' });
      });

      it('should not add an act claim to an impersonation exchange', async () => {
        const subjectToken = await subjectTokenFor('openid');
        const body = await (await exchangeRequest({ subject_token: subjectToken })).json();
        const payload = decodeJwtPayload(body.access_token as string);

        expect(payload.act).toBe(undefined);
      });

      // RFC 8693 §4.1: exchanging a delegated token again pushes the prior
      // actor one level down; the outermost act names the current actor.
      it('should nest the prior actor when a delegated token is exchanged again', async () => {
        const subjectToken = await subjectTokenFor('openid');
        const firstActor = await actorTokenFor('openid');
        const delegated = (await (
          await exchangeRequest({
            subject_token: subjectToken,
            actor_token: firstActor,
            actor_token_type: ACCESS_TOKEN_TYPE,
          })
        ).json()).access_token as string;
        const secondActor = await actorTokenFor('openid');
        const res = await exchangeRequest({
          subject_token: delegated,
          actor_token: secondActor,
          actor_token_type: ACCESS_TOKEN_TYPE,
        });
        const payload = decodeJwtPayload((await res.json()).access_token as string);

        expect(res.status).toBe(200);
        expect(payload.act).toEqual({ sub: 'otheruser', act: { sub: 'otheruser' } });
      });

      // A delegated token is an ordinary access token of the subject: the
      // UserInfo endpoint answers for the subject, not the actor.
      it('should answer UserInfo for the subject of a delegated token', async () => {
        const subjectToken = await subjectTokenFor('openid profile');
        const actorToken = await actorTokenFor('openid');
        const delegated = (await (
          await exchangeRequest({
            subject_token: subjectToken,
            actor_token: actorToken,
            actor_token_type: ACCESS_TOKEN_TYPE,
          })
        ).json()).access_token as string;
        const res = await app.request('/userinfo', {
          headers: { Authorization: 'Bearer ' + delegated },
        });

        expect(res.status).toBe(200);
        expect((await res.json()).sub).toBe('testuser');
      });
    });

    describe('Target policy (allowedTargets)', () => {
      // The generated default is an empty list, so any named target is refused
      // until the operator opts in. The list is restored after each test.
      it('should reject an audience that is not in allowedTargets', async () => {
        const subjectToken = await subjectTokenFor('openid');
        const res = await exchangeRequest({
          subject_token: subjectToken,
          audience: 'https://internal.example.com',
        });

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_target',
          error_description: TARGET_REJECTED_DESCRIPTION,
        });
      });

      it('should reject a resource that is not in allowedTargets', async () => {
        const subjectToken = await subjectTokenFor('openid');
        const res = await exchangeRequest({
          subject_token: subjectToken,
          resource: 'https://internal.example.com/api',
        });

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_target',
          error_description: TARGET_REJECTED_DESCRIPTION,
        });
      });

      it('should issue a token for an allowed audience', async () => {
        const subjectToken = await subjectTokenFor('openid');
        tokenExchangeConfig.allowedTargets = ['https://internal.example.com'];
        const res = await exchangeRequest({
          subject_token: subjectToken,
          audience: 'https://internal.example.com',
        });
        const body = await res.json();
        tokenExchangeConfig.allowedTargets = [];

        expect(res.status).toBe(200);
        expect(body.token_type).toBe('Bearer');
      });

      // The UserInfo endpoint stays a permanent aud member (RFC 9068 §3), so an
      // exchanged token keeps working against this OP as well as the new target.
      it('should add the allowed audience alongside the UserInfo endpoint', async () => {
        const subjectToken = await subjectTokenFor('openid');
        tokenExchangeConfig.allowedTargets = ['https://internal.example.com'];
        const exchanged = (await (
          await exchangeRequest({
            subject_token: subjectToken,
            audience: 'https://internal.example.com',
          })
        ).json()).access_token as string;
        tokenExchangeConfig.allowedTargets = [];
        const introspection = await (
          await app.request('/introspect', {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: new URLSearchParams({
              client_id: 'c-exchange',
              client_secret: 's',
              token: exchanged,
            }).toString(),
          })
        ).json();

        expect(introspection.aud).toEqual([
          'http://localhost:3000/userinfo',
          'https://internal.example.com',
        ]);
      });
    });

    describe('Discovery', () => {
      it('should advertise the exchange grant in grant_types_supported', async () => {
        const metadata = await (await app.request('/.well-known/openid-configuration')).json();

        expect(metadata.grant_types_supported.includes(EXCHANGE_GRANT_TYPE)).toBe(true);
      });
    });
  });
```

### Diffs for the other frameworks

The express and fastify diffs are identical and therefore consolidated into one file; nextjs is equivalent.

- [express-fastify](../../../tasks/experimental/done/token-exchange/promotion-review/generated-code/express-fastify.md)
- [nextjs](../../../tasks/experimental/done/token-exchange/promotion-review/generated-code/nextjs.md)

Among the samples, only [samples/hono-cloudflare](../../../samples/hono-cloudflare) enables this feature.

## The E2E test, in full

Two kinds of exchanges appear in this spec, and they run in different places; knowing which code performs the actual exchange makes the tests much easier to read.

The impersonation test ("should exchange a browser-obtained access token for a narrowed one") drives a real browser through the E2E client app's `/start-exchange` page.
The spec itself never posts to the token endpoint in that test: after the OP redirects back, the client app finishes the code flow on its server side and immediately performs the exchange there, in `completeTokenExchange` of `tests/e2e/apps/client.mjs`, then renders every outcome into the page the assertions read.
This is the excerpt that does it (the client app is shared E2E infrastructure, so only this function is quoted here):

```javascript
/**
 * EXPERIMENTAL — OAuth 2.0 Token Exchange (RFC 8693 §2.1).
 *
 * Trade the access token just obtained for one restricted to a narrower scope.
 * `audience` / `resource` are omitted on purpose: the exchange then inherits the
 * subject token's audience, which already names the resource server, so the
 * exchanged token passes its aud check with the generated default
 * `allowedTargets: []`.
 */
async function completeTokenExchange(res, tokens) {
  const exchanged = await formPost(new URL('/token', issuer), {
    grant_type: 'urn:ietf:params:oauth:grant-type:token-exchange',
    subject_token: tokens.access_token,
    subject_token_type: 'urn:ietf:params:oauth:token-type:access_token',
    scope: 'openid profile',
    client_id: clientId,
    client_secret: clientSecret,
  });

  const userInfo = await fetchJson(new URL('/userinfo', issuer), {
    headers: {
      Authorization: `Bearer ${exchanged.access_token}`,
    },
  });
  const resourceProfile = await fetchJson(new URL('/profile', resourceServerUrl), {
    headers: {
      Authorization: `Bearer ${exchanged.access_token}`,
    },
  });

  sendHtml(res, 200, renderExchangeResult({
    subjectScope: tokens.scope,
    exchanged,
    userInfo,
    resourceProfile,
  }));
}
```

The delegation test performs its exchange in the spec itself.
Two browser logins (testuser, then otheruser in an isolated browser context) yield a subject token and an actor token; the spec posts the delegation request over the back channel, decodes the issued JWT, and pins the `act` claim.

The spec pins down:

- a successful impersonation exchange (a token narrowed in scope comes back, and the resource server still accepts it)
- discovery advertising the exchange URN
- rejection of an unauthenticated exchange
- an unknown subject_token yielding `invalid_request`
- a delegation exchange recording the actor in the `act` claim of the issued JWT
- the §2.1 pairing rule (`actor_token` without `actor_token_type` is refused)

Every test skips on an OP whose discovery does not advertise the exchange URN.

```typescript
import { expect, test } from '@playwright/test';

const host = process.env.E2E_HOST ?? '127.0.0.1';
const clientPort = Number(process.env.E2E_CLIENT_PORT ?? '3020');
const resourceServerPort = Number(process.env.E2E_RESOURCE_SERVER_PORT ?? '3030');
const clientBaseURL =
  process.env.E2E_CLIENT_BASE_URL ?? `http://${host}:${clientPort}`;
const resourceServerURL =
  process.env.E2E_RESOURCE_SERVER_URL ?? `http://${host}:${resourceServerPort}`;
const clientId = 'e2e-client';
const clientSecret = 'e2e-client-secret';
const EXCHANGE_GRANT_TYPE = 'urn:ietf:params:oauth:grant-type:token-exchange';
const ACCESS_TOKEN_TYPE = 'urn:ietf:params:oauth:token-type:access_token';

/**
 * EXPERIMENTAL — OAuth 2.0 Token Exchange (RFC 8693).
 *
 * Only samples generated with `--enable token-exchange` dispatch the grant, so
 * every test here skips when discovery does not advertise the URN. That keeps
 * the shared spec suite green across all sample OPs.
 */
test.describe('Token Exchange (RFC 8693)', () => {
  test('should exchange a browser-obtained access token for a narrowed one', async ({
    page,
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const supported = await supportsTokenExchange(request, issuer);
    test.skip(!supported, 'This sample OP was generated without --enable token-exchange');

    // The full Authorization Code Flow runs in a real browser first; the client
    // then exchanges the resulting access token over the back channel.
    await page.goto(`${clientBaseURL}/start-exchange`);
    await page.getByLabel('Username:').fill('testuser');
    await page.getByLabel('Password:').fill('password');
    await page.getByRole('button', { name: 'Login' }).click();
    await page.getByRole('button', { name: 'Approve' }).click();

    // RFC 8693 §2.2.1 response members.
    await expect(page.getByTestId('exchange-subject-scope')).toHaveText('openid profile email');
    await expect(page.getByTestId('exchange-issued-token-type')).toHaveText(ACCESS_TOKEN_TYPE);
    await expect(page.getByTestId('exchange-token-type')).toHaveText('Bearer');
    // The exchange asked for a subset of the subject token's scope.
    await expect(page.getByTestId('exchange-scope')).toHaveText('openid profile');
    // RFC 8693 §2.2.1: no refresh token is issued for an exchange.
    await expect(page.getByTestId('exchange-refresh-token')).toHaveText('');

    // RFC 8693 §1.1 impersonation: the exchanged token still acts as the user.
    await expect(page.getByTestId('exchange-userinfo-sub')).toHaveText('testuser');
    // email was dropped from the scope, so the UserInfo response no longer carries it.
    await expect(page.getByTestId('exchange-userinfo-email')).toHaveText('');

    // The exchanged token inherited the subject token's audience, so the
    // resource server's aud check still passes.
    await expect(page.getByTestId('exchange-resource-subject')).toHaveText('testuser');
    await expect(page.getByTestId('exchange-resource-client-id')).toHaveText(clientId);
    await expect(page.getByTestId('exchange-resource-scope')).toHaveText('openid profile');
    await expect(page.getByTestId('exchange-resource-audience')).toContainText(resourceServerURL);
  });

  test('should advertise the exchange grant in discovery', async ({ request, baseURL }) => {
    const issuer = requireBaseUrl(baseURL);
    const supported = await supportsTokenExchange(request, issuer);
    test.skip(!supported, 'This sample OP was generated without --enable token-exchange');

    const metadata = await grantTypesSupported(request, issuer);

    expect(metadata.includes(EXCHANGE_GRANT_TYPE)).toBe(true);
  });

  test('should reject an unauthenticated exchange', async ({ request, baseURL }) => {
    const issuer = requireBaseUrl(baseURL);
    const supported = await supportsTokenExchange(request, issuer);
    test.skip(!supported, 'This sample OP was generated without --enable token-exchange');

    const response = await request.post(`${issuer}/token`, {
      form: {
        grant_type: EXCHANGE_GRANT_TYPE,
        subject_token: 'irrelevant',
        subject_token_type: ACCESS_TOKEN_TYPE,
        client_id: clientId,
      },
    });

    expect(response.status()).toBe(401);
    expect((await response.json()).error).toBe('invalid_client');
  });

  // RFC 8693 §2.2.2 routes an invalid subject_token to invalid_request, not to
  // invalid_grant, and the description does not reveal why it failed.
  test('should reject an unknown subject_token with invalid_request', async ({
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const supported = await supportsTokenExchange(request, issuer);
    test.skip(!supported, 'This sample OP was generated without --enable token-exchange');

    const response = await request.post(`${issuer}/token`, {
      form: {
        grant_type: EXCHANGE_GRANT_TYPE,
        subject_token: 'never-issued-token',
        subject_token_type: ACCESS_TOKEN_TYPE,
        client_id: clientId,
        client_secret: clientSecret,
      },
    });

    expect(response.status()).toBe(400);
    expect(response.headers()['cache-control']).toBe('no-store');
    expect(await response.json()).toEqual({
      error: 'invalid_request',
      error_description: 'The provided subject_token is not valid',
    });
  });

  // Delegation (RFC 8693 §1.1 / §4.1): two real browser logins provide a
  // subject token (testuser) and an actor token (otheruser); the exchange
  // itself is performed by this spec over the back channel, and the act claim
  // of the issued JWT is decoded and pinned.
  test('should record the actor in the act claim of a delegated exchange', async ({
    page,
    browser,
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const supported = await supportsTokenExchange(request, issuer);
    test.skip(!supported, 'This sample OP was generated without --enable token-exchange');

    // Subject: testuser completes the Authorization Code Flow in the default context.
    const subjectToken = await obtainAccessToken(page, 'testuser');

    // Actor: otheruser runs the same flow in an isolated browser context, so the
    // OP's browser-session cookie of the first login cannot leak into it.
    const actorContext = await browser.newContext();
    const actorToken = await obtainAccessToken(await actorContext.newPage(), 'otheruser');
    await actorContext.close();

    const response = await request.post(`${issuer}/token`, {
      form: {
        grant_type: EXCHANGE_GRANT_TYPE,
        subject_token: subjectToken,
        subject_token_type: ACCESS_TOKEN_TYPE,
        actor_token: actorToken,
        actor_token_type: ACCESS_TOKEN_TYPE,
        scope: 'openid',
        client_id: clientId,
        client_secret: clientSecret,
      },
    });

    expect(response.status()).toBe(200);
    const body = (await response.json()) as {
      access_token: string;
      issued_token_type: string;
      token_type: string;
    };
    expect(body.issued_token_type).toBe(ACCESS_TOKEN_TYPE);
    expect(body.token_type).toBe('Bearer');

    // RFC 8693 §4.1: sub stays the subject; the actor appears only in act.
    const payload = decodeJwtPayload(body.access_token);
    expect(payload.sub).toBe('testuser');
    expect(payload.act).toEqual({ sub: 'otheruser' });

    // The delegated token is an ordinary access token of the subject.
    const userInfo = await request.get(`${issuer}/userinfo`, {
      headers: { Authorization: `Bearer ${body.access_token}` },
    });
    expect(userInfo.status()).toBe(200);
    expect(((await userInfo.json()) as { sub: string }).sub).toBe('testuser');
  });

  // RFC 8693 §2.1: actor_token_type is REQUIRED when actor_token is present.
  // Parameter pairing is validated before any token is resolved, so no live
  // token is needed here.
  test('should reject actor_token without actor_token_type', async ({ request, baseURL }) => {
    const issuer = requireBaseUrl(baseURL);
    const supported = await supportsTokenExchange(request, issuer);
    test.skip(!supported, 'This sample OP was generated without --enable token-exchange');

    const response = await request.post(`${issuer}/token`, {
      form: {
        grant_type: EXCHANGE_GRANT_TYPE,
        subject_token: 'never-issued-token',
        subject_token_type: ACCESS_TOKEN_TYPE,
        actor_token: 'never-issued-token',
        client_id: clientId,
        client_secret: clientSecret,
      },
    });

    expect(response.status()).toBe(400);
    expect(await response.json()).toEqual({
      error: 'invalid_request',
      error_description: 'actor_token_type is required when actor_token is present',
    });
  });

  // The target policy (allowedTargets, including invalid_target) needs a live
  // subject token, so it is covered by the generated conformance contract tests
  // rather than duplicated here.
});

/**
 * Complete the ordinary Authorization Code Flow at the E2E client app as the
 * given user and read the raw access token off the client's result page.
 */
async function obtainAccessToken(
  page: import('@playwright/test').Page,
  username: string,
): Promise<string> {
  await page.goto(`${clientBaseURL}/start`);
  await page.getByLabel('Username:').fill(username);
  await page.getByLabel('Password:').fill('password');
  await page.getByRole('button', { name: 'Login' }).click();
  await page.getByRole('button', { name: 'Approve' }).click();
  return (await page.getByTestId('token-access-token').textContent()) ?? '';
}

/** Decode a JWT access token's payload (base64url, RFC 7515 §2). */
function decodeJwtPayload(token: string): Record<string, unknown> {
  const segment = token.split('.')[1] ?? '';
  const base64 = segment.replace(/-/g, '+').replace(/_/g, '/');
  const padded = base64 + '='.repeat((4 - (base64.length % 4)) % 4);
  return JSON.parse(atob(padded)) as Record<string, unknown>;
}

async function grantTypesSupported(
  request: { get(url: string): Promise<{ json(): Promise<unknown> }> },
  issuer: string,
): Promise<string[]> {
  const response = await request.get(`${issuer}/.well-known/openid-configuration`);
  const metadata = (await response.json()) as { grant_types_supported?: string[] };
  return metadata.grant_types_supported ?? [];
}

async function supportsTokenExchange(
  request: { get(url: string): Promise<{ json(): Promise<unknown> }> },
  issuer: string,
): Promise<boolean> {
  return (await grantTypesSupported(request, issuer)).includes(EXCHANGE_GRANT_TYPE);
}

function requireBaseUrl(baseURL: string | undefined): string {
  if (baseURL === undefined) {
    throw new Error('baseURL is not configured');
  }
  return baseURL;
}
```

## Related material

- User-facing documentation: [docs/library-document experimental/token-exchange.md](../../library-document/src/content/docs/experimental/token-exchange.md)
- Specification study documents: [tasks/experimental/done/token-exchange/](../../../tasks/experimental/done/token-exchange/)
- Promotion-review packet: [tasks/experimental/done/token-exchange/promotion-review/](../../../tasks/experimental/done/token-exchange/promotion-review/README.md)
- Package-wide conventions: [package-overview.en.md](./package-overview.en.md)
- 日本語版: [token-exchange.ja.md](./token-exchange.ja.md)
