# Cross-App Access / ID-JAG Implementation Guide

- **feature-id**: `id-jag`
- **Specification**: draft-ietf-oauth-identity-assertion-authz-grant-04 (May 2026), RFC 8693, RFC 7521 / RFC 7523, RFC 8414, RFC 8725
- **Implementation**: `packages/experimental/src/id-jag/`
- **Enable with**: `maronn-oidc generate <framework> --enable id-jag`
- **Requirement documents**: `tasks/experimental/id-jag/` (specification.md / understanding-guide.md / sources.md)

## What the feature does

**Cross-App Access (XAA)** is a pattern in which the API access between two applications that already share an IdP for SSO is brokered by that IdP.
Traditionally this connection is a separate OAuth consent — the user is redirected to app B's authorization screen — and the IdP never sees it.
With XAA, app A exchanges the ID Token it already holds for an **ID-JAG (Identity Assertion JWT Authorization Grant)** at the IdP's token endpoint (RFC 8693 Token Exchange), and presents that ID-JAG to app B's authorization server as a JWT Bearer Grant (RFC 7523) to obtain an access token.
No additional user consent appears; which cross-app connections are allowed is decided by the IdP's allow list.

The feature adds both roles to one generated OP:

- **Issuing side (IdP)**: the token-exchange grant accepts `requested_token_type=urn:ietf:params:oauth:token-type:id-jag`, validates an ID Token this OP issued, and returns a signed ID-JAG
- **Consuming side (the resource app's authorization server)**: the `urn:ietf:params:oauth:grant-type:jwt-bearer` grant validates an ID-JAG signed by a trust-listed external IdP and issues this OP's own access token

Run two instances of a generated OP, point their trust configuration at each other, and the four XAA steps (SSO, token exchange, ID-JAG presentation, API access) complete end to end. The E2E suite does exactly that.

### Use cases

- Reproducing the enterprise SSO extension — "app A reads app B's data without re-consent" — locally, before committing to an IDaaS
- Verifying the pattern where an AI agent obtains external-tool API tokens through the enterprise IdP (draft Appendix A.4)
- Learning-oriented PoCs that walk the chain of Token Exchange and the JWT Bearer Grant at the protocol level

### Scope and non-goals

The subject_token is limited to an ID Token issued by this OP.
SAML assertions and refresh tokens as subjects (which the draft permits as MAY), `sub_id` (SAML NameID), `authorization_details` (RAR), `actor_token`, DPoP sender-constraining, step-up authentication, and the tenant claims are all out of the initial scope.
Parameters that would misstate the granted authority if silently ignored (`actor_token` / `authorization_details`) are explicitly rejected with `invalid_request` instead of being dropped.

The ID-JAG's `client_id` claim carries the client_id the client authenticated with at the IdP.
Draft §5 also allows a mapping to a different client_id at the resource AS; the initial implementation is fixed to the same-client_id assumption (the shared namespace that Client ID Metadata Documents would provide).

There is no jti replay store.
Draft §4.4.3 defines re-presenting the same still-valid ID-JAG as the replacement for refresh tokens, so re-use within the lifetime is a legitimate protocol behavior.
The binding comes from client authentication, the `client_id` claim match, and the short lifetime (300 seconds by default).

## Design decisions

**No code is shared with other experimental features.**
The token-exchange grant_type URN overlaps with the existing `token-exchange` feature, but not even the constant is shared; dispatch order separates them.
Generated code enters this feature's issuance branch only when `requested_token_type` is the ID-JAG URN; everything else falls through to the existing token-exchange branch (when enabled) or to `unsupported_grant_type`.
`--enable id-jag` works alone and in combination with `--enable token-exchange`, and changes to one feature never leak into the other.

**Inbound JWS verification uses pre-registered keys only.**
The issuing side delegates subject_token (ID Token) validation to core's `validateIdTokenHint`, inheriting the full RFC 8725 hardening: signature verification, iss / aud / exp / iat, rejection of `alg: none` and of the external key headers (jku / jwk / x5u / x5c).
The consuming side verifies assertions with its own implementation, but with the same key-selection rules as core (kid first, then alg match, per-key alg pinning), and keys always come from the injected trusted-IdP JWKS.
No code path derives a key source from the assertion itself; jwks_uri fetching happens only in generated code and only from static configuration (blocking both SSRF and key substitution).

**The ID-JAG is signed by the same self-contained compact-JWS code JARM uses.**
It does not depend on core's private low-level signing helpers (core stays unchanged), the alg is pinned to RS256, and `typ: oauth-id-jag+jwt` is always set (explicit typing per RFC 8725 §3.11 — also a mandatory check on the consuming side).

**Trust configuration defaults to empty (fail safe).**
Both the issuing side's `allowedAudiences` and the consuming side's `trustedIdentityProviders` are generated empty; until configured, no ID-JAG is issued and none is accepted.
XAA has no user consent screen, so adding an entry to the allow list grants that cross-app connection on behalf of every user — the generated code says so in its comments.

**Same-trust-domain use is forbidden twice.**
Draft §9.3 ("the IdP MUST NOT issue access tokens in response to an ID-JAG it issued itself in the same domain") is enforced on both sides: the issuing side rejects `audience` equal to its own issuer with `invalid_target`, and the consuming side rejects `iss` equal to its own issuer with `invalid_grant`. A misconfiguration on one side alone opens no hole.

**The redeemed access token's lifetime is NOT capped by the ID-JAG's remaining lifetime.**
The token-exchange feature caps exchanged-token lifetimes at the subject's remainder; the ID-JAG works the other way — a short-lived grant legitimately produces a normal-lifetime access token (the draft's own examples show a 300-second grant and an 86400-second token). It is the same relationship as a 5-minute authorization code producing a 1-hour token.

Error mapping is two-tracked.
Issuance follows RFC 8693 §2.2.2 (`invalid_request` / `invalid_target` / `invalid_scope` / `unauthorized_client`); assertion defects on redemption follow RFC 7521 §4.1 (`invalid_grant`).
Two fixed descriptions eliminate oracles: subject_token failures on the issuing side are indistinguishable by cause, and on the consuming side "issuer not trusted" and "signature invalid" share one description so responses cannot enumerate the trusted-IdP list (the same concern behind draft §9.4's ban on disclosing the list in discovery).

## The implementation, in full

The module is four files, in the same two-layer shape as core: composition functions plus step functions.
Generated code calls the compositions (`processIdJagIssuanceRequest` / `processIdJagRedemptionRequest`); users can rewrite the call site into individual steps to replace or drop single rules.

### errors.ts (error type and fixed descriptions)

`IdJagError` is a separate class from core's `TokenError` for the same reason as in token-exchange: core's closed enum has no `invalid_target`.
The two oracle-eliminating fixed descriptions live here too, so the implementation, the unit tests, and the generated conformance tests all reference the same constants.

```typescript
/**
 * Identity Assertion Authorization Grant (ID-JAG) — エラー型
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * 発行側（IdP、Token Exchange 分岐）と受領側（リソース AS、jwt-bearer 分岐）の
 * 両方がこのエラーを投げる。どちらもバックチャネル専用（リダイレクトは存在
 * しない）で、常に 400 + JSON で返す。401 になるのはクライアント認証失敗
 * （`invalid_client`）だけであり、それは分岐より前の共有認証パイプライン
 * （core の `TokenError`）が担当する。
 *
 * core の `TokenErrorCode` は closed な enum で `invalid_target` を含まないため、
 * core 無変更の制約下では core の `TokenError` に相乗りできない
 * （token-exchange 機能の `TokenExchangeError` と同じ帰結）。
 */
import { sanitizeErrorDescription } from '@maronn-openid-connect/core';

/**
 * ID-JAG のエラーコード。
 *
 * - 発行側（RFC 8693 §2.2.2 / RFC 6749 §5.2）: invalid_request /
 *   unauthorized_client / invalid_scope / invalid_target
 * - 受領側（RFC 7521 §4.1）: assertion の不備は invalid_grant、それ以外は
 *   invalid_request / unauthorized_client / invalid_scope
 */
export type IdJagErrorCode =
  | 'invalid_request'
  | 'invalid_grant'
  | 'unauthorized_client'
  | 'invalid_scope'
  | 'invalid_target';

export class IdJagError extends Error {
  readonly code: IdJagErrorCode;
  readonly errorDescription: string;

  constructor(code: IdJagErrorCode, errorDescription: string) {
    // RFC 6749 §5.2: error_description は安全な文字集合に限定する。
    const sanitized = sanitizeErrorDescription(errorDescription);
    super(sanitized);
    this.name = 'IdJagError';
    this.code = code;
    this.errorDescription = sanitized;
  }

  /** 本エラーは常に 400（401 は分岐前の共有パイプラインが返す）。 */
  get statusCode(): 400 {
    return 400;
  }
}

/**
 * 発行側で subject_token（ID トークン）の検証に失敗したときの固定 error_description。
 *
 * 署名不正・iss 不一致・aud（クライアント）不一致・期限切れ・構造不正を区別しない。
 * 応答からトークンの有効性を推測できる「オラクル」を作らないための意図的な設計で、
 * token-exchange 機能の subject_token 解決失敗と同じ方針（文言も同一）。
 */
export const SUBJECT_TOKEN_INVALID_DESCRIPTION =
  'The provided subject_token is not valid';

/**
 * 受領側で「iss が信頼リスト外」と「署名検証失敗」の両方に使う固定 error_description。
 *
 * 両者を区別すると、応答の違いから信頼済み IdP のリストを外部から探索できて
 * しまう（ID-JAG draft §9.4 が discovery でのリスト開示を禁じるのと同じ趣旨）。
 */
export const ASSERTION_UNTRUSTED_DESCRIPTION =
  'The assertion issuer is not trusted or the assertion signature is invalid';
```

### issue-id-jag.ts (issuing side: the IdP role)

Three validations carry the issuing side.
Subject-token validation (`resolveIdJagSubject`) delegates to core's `validateIdTokenHint` and satisfies the draft §4.3.3 MUST — "the audience of the assertion matches the client_id of the client authentication" — via `expectedAud`. An ID Token issued to another client dies here with the fixed `invalid_request` description.
Audience validation (`validateIdJagAudience`) is two-staged (allow list, own-issuer exclusion), and scope validation (`validateIdJagScope`) passes requests through when `allowedScopes` is not configured (scope semantics belong to the resource AS's domain, which applies the same narrowing policy again on redemption).

```typescript
/**
 * Identity Assertion Authorization Grant (ID-JAG) の発行 — IdP 側
 * draft-ietf-oauth-identity-assertion-authz-grant-04 §3 / §4.3
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * 既存トークンエンドポイントの Token Exchange grant（RFC 8693）のうち、
 * `requested_token_type=urn:ietf:params:oauth:token-type:id-jag` の要求を処理する。
 * subject_token として自 OP 発行の ID トークンを受け取り、検証のうえで
 * 別トラストドメインのリソース AS 宛ての署名付き authorization grant JWT
 * （ID-JAG）を発行する。
 *
 * core と同じ「合成関数＋ステップ関数」の二層構成とし、CLI 生成コードは
 * ステップ関数を順に呼び出して検証を差し替え・削除できるようにする。
 * 既存の token-exchange 機能とは grant_type URN を共有するが、コードは共有
 * しない（experimental 機能同士の独立性優先。重複を許容する方針）。
 *
 * ID-JAG の署名は JARM の応答 JWT と同じく Web Crypto API による自前の
 * compact JWS 組み立てで行い、core の非公開な低レベル署名ヘルパーには
 * 依存しない（core 無変更の維持）。
 */
import {
  IdTokenHintError,
  generateRandomString,
  validateIdTokenHint,
  type JwkSet,
  type SigningKey,
  type TokenClientInfo,
} from '@maronn-openid-connect/core';
import {
  IdJagError,
  SUBJECT_TOKEN_INVALID_DESCRIPTION,
} from './errors.js';

/** RFC 8693 §2.1: token exchange の grant type 識別子（発行側のディスパッチ条件）。 */
export const TOKEN_EXCHANGE_GRANT_TYPE = 'urn:ietf:params:oauth:grant-type:token-exchange';

/** ID-JAG draft §4.3: 要求する token type 識別子。 */
export const ID_JAG_TOKEN_TYPE = 'urn:ietf:params:oauth:token-type:id-jag';

/** RFC 8693 §3: OIDC ID トークンの token type 識別子。本機能が受ける唯一の subject 種別。 */
export const TOKEN_TYPE_ID_TOKEN = 'urn:ietf:params:oauth:token-type:id_token';

/**
 * ID-JAG draft §3.1: JOSE ヘッダーの `typ` 値。
 * RFC 8725 §3.11 の explicit typing により、ID トークンなど他種の JWT との
 * 取り違え（token confusion）を受領側が構造的に拒否できる。
 */
export const ID_JAG_JWT_TYP = 'oauth-id-jag+jwt';

/**
 * ID-JAG draft §7.2 / §8: authorization grant profile の識別子。
 * discovery の `authorization_grant_profiles_supported` に載せる値。
 */
export const ID_JAG_GRANT_PROFILE = 'urn:ietf:params:oauth:grant-profile:id-jag';

/**
 * ID-JAG の署名アルゴリズム。
 *
 * draft は alg を規定しないため、本 OP の必須アルゴリズムである RS256 に固定する
 * （JARM の応答 JWT と同じ設計）。{@link createIdJagJwt} に渡す `signingKey` は
 * RS256 鍵でなければならない。生成コードは登録鍵セットから
 * `selectSigningKeyByAlg(keys, 'RS256')` で選ぶこと。
 */
const ID_JAG_SIGNING_ALG = 'RS256';

/** RS256 に対応する Web Crypto のアルゴリズム名。 */
const WEB_CRYPTO_ALGORITHM = 'RSASSA-PKCS1-v1_5';

/** 検証済みの ID-JAG 発行リクエストパラメータ（draft §4.3）。 */
export interface ParsedIdJagIssuanceParams {
  subjectToken: string;
  /** リソース AS の issuer identifier（RFC 8414 §2）。draft §4.3 で REQUIRED */
  audience: string;
  /** 空白区切りの要求 scope。省略時は undefined（scope クレームを発行しない） */
  scope?: string;
  /** RFC 8707 §2 のリソース識別子。省略時は undefined */
  resource?: string;
}

/** subject_token（ID トークン）の検証で得た発行素材。 */
export interface IdJagSubject {
  /** ID トークンの sub。ID-JAG の sub にそのまま引き継ぐ（draft §3.1） */
  sub: string;
  /** ID トークンの auth_time（存在する場合のみ。draft §3.1 OPTIONAL） */
  authTime?: number;
  /** ID トークンの acr（存在する場合のみ） */
  acr?: string;
  /** ID トークンの amr（存在する場合のみ） */
  amr?: string[];
}

/** ID-JAG のクレームセット（draft §3.1）。 */
export interface IdJagClaims {
  iss: string;
  sub: string;
  aud: string;
  client_id: string;
  jti: string;
  exp: number;
  iat: number;
  scope?: string;
  resource?: string;
  auth_time?: number;
  acr?: string;
  amr?: string[];
}

/** RFC 8693 §2.2.1 / draft §4.3.4 の成功レスポンスボディ。 */
export interface IdJagIssuanceResponse {
  /** ID-JAG 本体。アクセストークンではないが §2.2.1 の歴史的経緯でこの名前になる */
  access_token: string;
  issued_token_type: typeof ID_JAG_TOKEN_TYPE;
  /** 発行物がアクセストークンではないため常に N_A（draft §4.3.4 REQUIRED） */
  token_type: 'N_A';
  expires_in: number;
  scope: string;
}

/** ID-JAG 発行処理のコンテキスト。 */
export interface IdJagIssuanceContext {
  /** フォームボディのパラメータ（application/x-www-form-urlencoded） */
  params: Record<string, string>;
  /** 認証済みクライアント（分岐前の共有認証パイプラインが解決したもの） */
  client: TokenClientInfo;
  /** 自 OP（IdP）の issuer。ID-JAG の iss になり、subject_token の期待 iss にもなる */
  issuer: string;
  /** subject_token（ID トークン）の署名検証に使う自 OP の JWKS */
  jwks: JwkSet;
  /** ID-JAG の署名鍵。RS256 鍵であること */
  signingKey: SigningKey;
  /** ID-JAG を発行してよいリソース AS issuer の許可リスト。既定は空（安全側） */
  allowedAudiences: string[];
  /** 許可する scope の上限リスト。undefined は素通し（リソース AS 側ポリシーに委ねる） */
  allowedScopes?: string[];
  /** ID-JAG の有効期間（秒） */
  lifetimeSeconds: number;
  /** 現在時刻。テストと決定的な期限計算のために注入できる */
  now?: Date;
}

/**
 * 生成コードのディスパッチ用: この要求が ID-JAG 発行要求かを判定する。
 *
 * grant_type が token-exchange URN で、かつ requested_token_type が ID-JAG の
 * ときだけ真になる。既存の token-exchange 分岐より前に評価することで、両機能を
 * 同時に有効化しても要求が正しい側へ流れる。
 */
export function matchesIdJagIssuanceRequest(params: Record<string, string>): boolean {
  return (
    params['grant_type'] === TOKEN_EXCHANGE_GRANT_TYPE &&
    optional(params['requested_token_type']) === ID_JAG_TOKEN_TYPE
  );
}

/**
 * ステップ 1: クライアントが ID-JAG の発行を要求してよいかを検証する。
 *
 * draft §9.1 は本仕様を confidential client に限る SHOULD を置く。本機能は
 * これを public client の拒否まで強めている（token-exchange 機能と同じ設計判断。
 * ID-JAG はユーザー同意なしで発行されるため、クライアント認証が唯一の束縛になる）。
 *
 * @throws {IdJagError} unauthorized_client
 */
export function authorizeIdJagIssuanceClient(client: TokenClientInfo): void {
  // OIDC Dynamic Client Registration 1.0 §2 / RFC 7591 §2: grantTypes 未指定は
  // ['authorization_code'] 扱い。よって発行は token-exchange URN を明示登録した
  // クライアントのみ許される。
  const grantTypes = client.grantTypes ?? ['authorization_code'];
  if (!grantTypes.includes(TOKEN_EXCHANGE_GRANT_TYPE)) {
    throw new IdJagError(
      'unauthorized_client',
      'The client is not authorized to use the token-exchange grant type',
    );
  }
  if (client.tokenEndpointAuthMethod === 'none') {
    throw new IdJagError(
      'unauthorized_client',
      'Public clients are not allowed to request an ID-JAG',
    );
  }
}

/**
 * ステップ 2: 必須・非対応パラメータを検証して型付けする（draft §4.3）。
 *
 * 空文字・空白のみの任意パラメータは「送られなかった」と同じに扱う
 * （token-exchange 機能と同じ規則）。
 *
 * @throws {IdJagError} invalid_request
 */
export function parseIdJagIssuanceParams(
  params: Record<string, string>,
): ParsedIdJagIssuanceParams {
  const subjectToken = optional(params['subject_token']);
  if (subjectToken === undefined) {
    throw new IdJagError('invalid_request', 'subject_token is required');
  }

  const subjectTokenType = optional(params['subject_token_type']);
  if (subjectTokenType === undefined) {
    throw new IdJagError('invalid_request', 'subject_token_type is required');
  }
  // draft §4.3 は saml2 / refresh_token の subject も定義するが、本機能は
  // OIDC OP として自 OP 発行の ID トークンだけを受ける（仕様の非目標）。
  if (subjectTokenType !== TOKEN_TYPE_ID_TOKEN) {
    throw new IdJagError(
      'invalid_request',
      `Unsupported subject_token_type for ID-JAG issuance. Only ${TOKEN_TYPE_ID_TOKEN} is supported.`,
    );
  }

  // draft §4.3: audience は REQUIRED（RFC 8693 では OPTIONAL だが、この profile が
  // 必須へ強めている）。ID-JAG の aud クレームそのものになる。
  const audience = optional(params['audience']);
  if (audience === undefined) {
    throw new IdJagError('invalid_request', 'audience is required');
  }

  const resource = optional(params['resource']);
  if (resource !== undefined && !isAbsoluteUriWithoutFragment(resource)) {
    // RFC 8707 §2: resource は絶対 URI で fragment を含んではならない（query は許容）。
    throw new IdJagError(
      'invalid_request',
      'resource must be an absolute URI without a fragment component',
    );
  }

  // draft §4.3 は actor_token を運べることだけを定め、処理規則を定義しない
  // （§9.7: 将来の拡張）。規則が無いまま受け取ると委譲の権限が過大表明され得る
  // ため、明示的に拒否する（fail-safe）。
  if (optional(params['actor_token']) !== undefined || optional(params['actor_token_type']) !== undefined) {
    throw new IdJagError(
      'invalid_request',
      'actor_token is not supported for ID-JAG issuance',
    );
  }

  // RAR（RFC 9396）は非対応（仕様の非目標）。無視して発行すると要求より狭い
  // 権限表明と誤解されるため、明示的に拒否する。
  if (optional(params['authorization_details']) !== undefined) {
    throw new IdJagError(
      'invalid_request',
      'authorization_details is not supported for ID-JAG issuance',
    );
  }

  return {
    subjectToken,
    audience,
    scope: optional(params['scope']),
    resource,
  };
}

/**
 * ステップ 3: subject_token（ID トークン）を検証し、発行素材を返す。
 *
 * draft §4.3.3: IdP は assertion を検証し、その audience（ID トークンの aud）が
 * リクエストのクライアント認証の client_id と一致することを検証しなければ
 * ならない（MUST）。他クライアント宛てに発行された ID トークンの持ち込みを防ぐ。
 *
 * 検証本体は core の `validateIdTokenHint` に委譲する。署名（事前登録 JWKS のみ・
 * kid / alg による鍵選択）、iss、aud、exp / iat（leeway 60 秒）、`alg: none` と
 * 外部鍵取得ヘッダ（jku / jwk / x5u / x5c）の拒否がそのまま適用される。
 *
 * 失敗理由は応答から区別できない（{@link SUBJECT_TOKEN_INVALID_DESCRIPTION}）。
 *
 * @throws {IdJagError} invalid_request（固定文言）
 */
export async function resolveIdJagSubject(options: {
  subjectToken: string;
  issuer: string;
  clientId: string;
  jwks: JwkSet;
}): Promise<IdJagSubject> {
  let payload: { sub: string; [key: string]: unknown };
  try {
    payload = await validateIdTokenHint(options.subjectToken, {
      expectedIss: options.issuer,
      expectedAud: options.clientId,
      jwks: options.jwks,
    });
  } catch (error) {
    if (error instanceof IdTokenHintError) {
      throw new IdJagError('invalid_request', SUBJECT_TOKEN_INVALID_DESCRIPTION);
    }
    throw error;
  }

  // auth_time / acr / amr は ID トークンに存在する場合だけ ID-JAG へ引き継ぐ
  // （draft §3.1 OPTIONAL。リソース AS 側の認証コンテキスト評価の材料）。
  const authTime = typeof payload['auth_time'] === 'number' ? payload['auth_time'] : undefined;
  const acr = typeof payload['acr'] === 'string' ? payload['acr'] : undefined;
  const amr =
    Array.isArray(payload['amr']) && payload['amr'].every((v) => typeof v === 'string')
      ? (payload['amr'] as string[])
      : undefined;

  return {
    sub: payload.sub,
    ...(authTime === undefined ? {} : { authTime }),
    ...(acr === undefined ? {} : { acr }),
    ...(amr === undefined ? {} : { amr }),
  };
}

/**
 * ステップ 4: audience を検証する。
 *
 * - draft §9.3: IdP は自分が発行した ID-JAG に対して同一ドメイン内でアクセス
 *   トークンを発行してはならない。自 OP の issuer と同一の audience 要求は、
 *   その禁止された構成そのものなので発行時点で拒否する（受領側の iss 検証と
 *   合わせた二重ガード）。
 * - 許可リスト（既定は空）に無い audience は拒否する。error_description は
 *   リストの内容・部分一致情報を露出しない固定文言。
 *
 * issuer identifier の比較は byte-exact（RFC 8414 §2 の識別子比較）。
 *
 * @throws {IdJagError} invalid_target
 */
export function validateIdJagAudience(options: {
  audience: string;
  issuer: string;
  allowedAudiences: string[];
}): void {
  if (options.audience === options.issuer) {
    // 利用者が自力で直せる構成エラーなので、この場合だけ理由を明示する
    // （自 OP の issuer は公開情報でありオラクルにならない）。
    throw new IdJagError(
      'invalid_target',
      'The requested audience must belong to a different trust domain than this authorization server',
    );
  }
  if (!options.allowedAudiences.includes(options.audience)) {
    throw new IdJagError(
      'invalid_target',
      'The requested audience is not allowed for ID-JAG issuance',
    );
  }
}

/**
 * ステップ 5: 要求 scope を検証し、ID-JAG に載せる実効 scope を返す。
 *
 * draft §4.3.3: IdP はポリシーを評価し、許可 scope は要求の部分集合であってよい。
 * 本機能のポリシーは「`allowedScopes` が設定されていればその部分集合のみ許可、
 * 未設定なら要求をそのまま許可」。未設定素通しにするのは、scope の意味論が
 * リソース AS のドメインに属し、受領側でも同じ縮小ポリシーが働くため
 * （設計判断。仕様書の設定値の節を参照）。
 *
 * @throws {IdJagError} invalid_scope
 */
export function validateIdJagScope(
  requestedScope: string | undefined,
  allowedScopes: string[] | undefined,
): string[] {
  const requested = splitScope(requestedScope);
  if (allowedScopes === undefined) {
    return requested;
  }
  for (const value of requested) {
    if (!allowedScopes.includes(value)) {
      throw new IdJagError(
        'invalid_scope',
        'The requested scope exceeds the scopes allowed for ID-JAG issuance',
      );
    }
  }
  return requested;
}

/**
 * ステップ 6: ID-JAG のクレームセットを組み立てる（draft §3.1）。
 *
 * - `client_id` は交換を要求した認証済みクライアントの client_id。draft §5 は
 *   リソース AS 側で別の client_id を使う対応付けも認めるが、本機能は両 AS で
 *   同一 client_id を使う前提に固定する（仕様の非目標）。
 * - `scope` は空配列のときクレーム自体を含めない（draft §3.1 OPTIONAL）。
 * - `jti` は 256bit のランダム値。受領側はリプレイ拒否には使わないが（draft
 *   §4.4.3 の再提示を許すため）、grant 単位の追跡とログ相関に使える。
 *
 * @throws {RangeError} lifetimeSeconds が正の整数でない場合（設定ミス）
 */
export function buildIdJagClaims(options: {
  issuer: string;
  subject: IdJagSubject;
  audience: string;
  clientId: string;
  scope: string[];
  resource?: string;
  lifetimeSeconds: number;
  now?: Date;
}): IdJagClaims {
  if (!Number.isInteger(options.lifetimeSeconds) || options.lifetimeSeconds <= 0) {
    throw new RangeError(
      `lifetimeSeconds must be a positive integer, received ${options.lifetimeSeconds}`,
    );
  }
  const issuedAt = Math.floor((options.now ?? new Date()).getTime() / 1000);
  return {
    iss: options.issuer,
    sub: options.subject.sub,
    aud: options.audience,
    client_id: options.clientId,
    jti: generateRandomString(32),
    exp: issuedAt + options.lifetimeSeconds,
    iat: issuedAt,
    ...(options.scope.length === 0 ? {} : { scope: options.scope.join(' ') }),
    ...(options.resource === undefined ? {} : { resource: options.resource }),
    ...(options.subject.authTime === undefined ? {} : { auth_time: options.subject.authTime }),
    ...(options.subject.acr === undefined ? {} : { acr: options.subject.acr }),
    ...(options.subject.amr === undefined ? {} : { amr: options.subject.amr }),
  };
}

/**
 * ステップ 7: ID-JAG を compact JWS として署名する。
 *
 * JOSE ヘッダーは `{ alg: 'RS256', typ: 'oauth-id-jag+jwt', kid }`。
 * `typ` は受領側の必須検証項目（draft §4.4.1 / RFC 8725 §3.11）なので必ず付ける。
 * `kid` を含めるのは、受領側が IdP の JWKS から鍵を一意に選べるようにするため。
 *
 * @param options.signingKey RS256 鍵であること（alg 表明と鍵種の不一致は Web
 *   Crypto が署名時に例外にするため、偽った alg の JWS は生成されない）
 */
export async function createIdJagJwt(options: {
  claims: IdJagClaims;
  signingKey: SigningKey;
}): Promise<string> {
  const encodedHeader = base64UrlFromJson({
    alg: ID_JAG_SIGNING_ALG,
    typ: ID_JAG_JWT_TYP,
    kid: options.signingKey.keyId,
  });
  const encodedPayload = base64UrlFromJson(options.claims as unknown as Record<string, unknown>);
  const signingInput = `${encodedHeader}.${encodedPayload}`;

  const signature = await crypto.subtle.sign(
    WEB_CRYPTO_ALGORITHM,
    options.signingKey.privateKey,
    new TextEncoder().encode(signingInput),
  );

  return `${signingInput}.${base64UrlFromBytes(new Uint8Array(signature))}`;
}

/**
 * ステップ 8: RFC 8693 §2.2.1 / draft §4.3.4 の応答ボディを組み立てる。
 *
 * `token_type` は常に `N_A`（発行物はアクセストークンではない）。`scope` は
 * draft 上「要求と同一なら OPTIONAL」だが、判定分岐を避けるため常に含める
 * （token-exchange 機能と同じ設計判断。scope 無しの発行では空文字列）。
 * refresh_token は返さない（draft §4.3.4 SHOULD NOT）。
 */
export function buildIdJagIssuanceResponse(options: {
  idJag: string;
  expiresIn: number;
  scope: string[];
}): IdJagIssuanceResponse {
  return {
    access_token: options.idJag,
    issued_token_type: ID_JAG_TOKEN_TYPE,
    token_type: 'N_A',
    expires_in: options.expiresIn,
    scope: options.scope.join(' '),
  };
}

/**
 * 合成関数: ID-JAG 発行の検証〜応答生成（draft §4.3）。
 *
 * 個々のステップ関数を仕様順に合成しただけの API。ID-JAG はストアに保存しない
 * （自己完結した署名付き grant であり、受領側が署名と exp で検証する）。
 *
 * @throws {IdJagError}
 */
export async function processIdJagIssuanceRequest(
  context: IdJagIssuanceContext,
): Promise<IdJagIssuanceResponse> {
  // クライアント認可を最初に行う。許可されていないクライアントには
  // subject_token の有効性すら判定させない（オラクルを与えない）。
  authorizeIdJagIssuanceClient(context.client);

  const parsed = parseIdJagIssuanceParams(context.params);

  const subject = await resolveIdJagSubject({
    subjectToken: parsed.subjectToken,
    issuer: context.issuer,
    clientId: context.client.clientId,
    jwks: context.jwks,
  });

  validateIdJagAudience({
    audience: parsed.audience,
    issuer: context.issuer,
    allowedAudiences: context.allowedAudiences,
  });

  const scope = validateIdJagScope(parsed.scope, context.allowedScopes);

  const claims = buildIdJagClaims({
    issuer: context.issuer,
    subject,
    audience: parsed.audience,
    clientId: context.client.clientId,
    scope,
    ...(parsed.resource === undefined ? {} : { resource: parsed.resource }),
    lifetimeSeconds: context.lifetimeSeconds,
    ...(context.now === undefined ? {} : { now: context.now }),
  });

  const idJag = await createIdJagJwt({
    claims,
    signingKey: context.signingKey,
  });

  return buildIdJagIssuanceResponse({
    idJag,
    expiresIn: context.lifetimeSeconds,
    scope,
  });
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

/**
 * RFC 8707 §2: resource は絶対 URI（RFC 3986 §4.3）で fragment を含んではならない。
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
  return parsed.protocol.length > 0;
}

function base64UrlFromBytes(bytes: Uint8Array): string {
  let binary = '';
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function base64UrlFromJson(value: Record<string, unknown>): string {
  return base64UrlFromBytes(new TextEncoder().encode(JSON.stringify(value)));
}
```

### redeem-id-jag.ts (consuming side: the resource AS role)

The heart of the consuming side is `verifyIdJagAssertion`, which layers the draft §4.4.1 processing rules over RFC 7521 §5.2 into eleven ordered checks.
`aud` must equal the own issuer exactly; an array form is accepted only with exactly one element (the draft's MUST — audience-injection rejection).
The match between the `client_id` claim and the authenticated client (client continuity) is what closes the path of a stolen ID-JAG being cashed in by another client.
Effective-scope derivation (`resolveIdJagGrantScope`) always strips `offline_access`: the jwt-bearer grant never issues refresh tokens (draft §4.4.3 SHOULD NOT), so leaving it in the effective scope would assert a long-lived access nobody consented to.

```typescript
/**
 * Identity Assertion Authorization Grant (ID-JAG) の受領 — リソース AS 側
 * draft-ietf-oauth-identity-assertion-authz-grant-04 §4.4 / RFC 7523 §2.1・§3 / RFC 7521 §5.2
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * トークンエンドポイントの `urn:ietf:params:oauth:grant-type:jwt-bearer` grant を
 * 処理する。信頼設定済みの外部 IdP が署名した ID-JAG（`typ: oauth-id-jag+jwt`）
 * だけを assertion として受け、検証のうえアクセストークンの発行素材を導出する。
 * 素の RFC 7523 assertion（他の typ）は受けない（仕様の非目標）。
 *
 * トークンの発行・保存は行わない。呼び出し側（生成コード）が core の
 * `buildAccessTokenAudience` / `buildAccessTokenPayload` / `AccessTokenIssuer` /
 * `accessTokenStore` と組み合わせる（token-exchange 機能と同じ分担）。
 *
 * JWS の検証は Web Crypto API による自前実装で、鍵は必ず注入された信頼 IdP の
 * JWKS から選ぶ。assertion の内容（jku ヘッダなど）から鍵の取得先を導出する
 * 経路は存在しない（RFC 8725 §3.1 / SSRF 対策）。ネットワーク取得（jwks_uri）は
 * 本モジュールの責務ではなく、生成コード側で解決してから渡す。
 */
import type { webcrypto } from 'node:crypto';
import {
  extractAlgorithmParamsFromJwk,
  type Jwk,
  type JwkSet,
  type TokenClientInfo,
} from '@maronn-openid-connect/core';
import {
  ASSERTION_UNTRUSTED_DESCRIPTION,
  IdJagError,
} from './errors.js';
import { ID_JAG_JWT_TYP } from './issue-id-jag.js';

/** RFC 7523 §2.1: JWT authorization grant の grant type 識別子。 */
export const JWT_BEARER_GRANT_TYPE = 'urn:ietf:params:oauth:grant-type:jwt-bearer';

/**
 * Clock skew 許容の既定値（秒）。
 * RFC 8725 §3.8: leeway は数分以内に留める。core の ID トークン検証と同じ 60 秒。
 */
export const DEFAULT_ASSERTION_CLOCK_SKEW_SEC = 60;

/**
 * 信頼する IdP の解決済みエントリ。
 *
 * `jwks` は検証時点で手元にある JWK セット（インライン設定、または生成コードが
 * jwks_uri から取得してキャッシュしたもの）。issuer は RFC 8414 §2 の issuer
 * identifier で、assertion の `iss` と byte-exact に比較される。
 */
export interface IdJagTrustedIdentityProvider {
  issuer: string;
  jwks: JwkSet;
}

/** 検証済みの jwt-bearer リクエストパラメータ。 */
export interface ParsedIdJagRedemptionParams {
  assertion: string;
  /** 空白区切りの要求 scope。省略時は undefined（ID-JAG の scope を継承する） */
  scope?: string;
}

/** 検証を通過した ID-JAG のペイロード（draft §3.1）。 */
export interface IdJagAssertionPayload {
  iss: string;
  sub: string;
  aud: string | string[];
  client_id: string;
  jti: string;
  exp: number;
  iat: number;
  scope?: string;
  /** RFC 8707 のリソース識別子。単一 URI または URI 配列（draft §3.1） */
  resource?: string | string[];
  auth_time?: number;
  acr?: string;
  amr?: string[];
}

/**
 * 発行素材。生成コードはこれを core の `buildAccessTokenAudience` /
 * `buildAccessTokenPayload` / `AccessTokenIssuer.issue` / `accessTokenStore.set` へ流す。
 */
export interface IdJagRedemptionGrant {
  /** ID-JAG の sub をそのままローカル subject として使う（JIT 対応は非目標） */
  subject: string;
  /** redemption を要求した認証済みクライアント（= ID-JAG の client_id） */
  clientId: string;
  /** 実効 scope（ID-JAG の scope から offline_access を除去し、要求で縮小した値） */
  scope: string[];
  /** ID-JAG の resource クレーム。core の `buildAccessTokenAudience` の `requested` へ渡す */
  requestedResources?: string[];
  /**
   * 発行するアクセストークンの有効期間（秒）。設定値をそのまま使い、ID-JAG の
   * 残存期間で cap しない（draft §4.4.3: アクセストークン失効後は同じ ID-JAG を
   * 再提示して再取得する設計で、grant はトークンより短命でよい）。
   */
  expiresIn: number;
  /** ID-JAG を発行した IdP の issuer（監査ログとストアメタデータ用） */
  idpIssuer: string;
  /** ID-JAG の jti（ログ相関用。リプレイ拒否には使わない） */
  jti: string;
  authTime?: number;
  acr?: string;
  amr?: string[];
}

/** ID-JAG redemption 処理のコンテキスト。 */
export interface IdJagRedemptionContext {
  /** フォームボディのパラメータ（application/x-www-form-urlencoded） */
  params: Record<string, string>;
  /** 認証済みクライアント（分岐前の共有認証パイプラインが解決したもの） */
  client: TokenClientInfo;
  /** 自 OP（リソース AS）の issuer。assertion の期待 aud であり、自己発行拒否の基準 */
  issuer: string;
  /** 信頼する IdP のリスト（JWKS 解決済み）。既定は空（安全側） */
  identityProviders: IdJagTrustedIdentityProvider[];
  /** 設定上のアクセストークン有効期間（秒） */
  configuredExpiresIn: number;
  /** 現在時刻。テストと決定的な期限計算のために注入できる */
  now?: Date;
  /** exp / iat / nbf 判定の leeway（秒）。既定 60 */
  clockSkewToleranceSec?: number;
}

/**
 * RFC 7515 が「鍵を外部から取得するための情報源」として定義する JOSE Header
 * フィールド。鍵は事前登録済みの信頼 IdP の JWKS からだけ選ぶため、受信 JWS に
 * 含まれていたら即拒否する（RFC 8725 §3.1: SSRF と任意公開鍵差し替えの防止）。
 */
const FORBIDDEN_KEY_HEADERS = ['jku', 'x5u', 'jwk', 'x5c'] as const;

/**
 * ステップ 1: クライアントが jwt-bearer grant を使ってよいかを検証する。
 *
 * RFC 7521 §4.1 は authorization grant の assertion でクライアント認証を必須と
 * しないが、draft §4.4.1 は ID-JAG の client_id クレームと「リクエストの認証
 * クライアント」の一致を MUST とし、§9.1 は confidential client 限定の SHOULD を
 * 置く。本機能はこれを public client の拒否まで強めている（発行側と同じ設計判断）。
 *
 * @throws {IdJagError} unauthorized_client
 */
export function authorizeIdJagRedemptionClient(client: TokenClientInfo): void {
  // RFC 7591 §2: grantTypes 未指定は ['authorization_code'] 扱い。よって redemption は
  // jwt-bearer URN を明示登録したクライアントのみ許される。
  const grantTypes = client.grantTypes ?? ['authorization_code'];
  if (!grantTypes.includes(JWT_BEARER_GRANT_TYPE)) {
    throw new IdJagError(
      'unauthorized_client',
      'The client is not authorized to use the jwt-bearer grant type',
    );
  }
  if (client.tokenEndpointAuthMethod === 'none') {
    throw new IdJagError(
      'unauthorized_client',
      'Public clients are not allowed to use the jwt-bearer grant type',
    );
  }
}

/**
 * ステップ 2: 必須・非対応パラメータを検証して型付けする（RFC 7523 §2.1）。
 *
 * @throws {IdJagError} invalid_request
 */
export function parseIdJagRedemptionParams(
  params: Record<string, string>,
): ParsedIdJagRedemptionParams {
  const assertion = optional(params['assertion']);
  if (assertion === undefined) {
    throw new IdJagError('invalid_request', 'assertion is required');
  }

  // RAR（RFC 9396）は非対応（仕様の非目標）。発行側と同じく明示的に拒否する。
  if (optional(params['authorization_details']) !== undefined) {
    throw new IdJagError(
      'invalid_request',
      'authorization_details is not supported for the jwt-bearer grant',
    );
  }

  return {
    assertion,
    scope: optional(params['scope']),
  };
}

/**
 * ステップ 3: assertion（ID-JAG）を検証し、ペイロードを返す。
 *
 * RFC 7521 §5.2 の一般規則に加え、draft §4.4.1 の処理規則を適用する:
 *
 * 1. compact JWS として構造が正しいこと
 * 2. `typ` が `oauth-id-jag+jwt` であること（RFC 8725 §3.11 の explicit typing。
 *    RFC 7515 §4.1.9 に従い `application/` 前置と大文字小文字の差は許容する）
 * 3. `alg` があり `none` でないこと。外部鍵取得ヘッダが無いこと
 * 4. `iss` が信頼 IdP のいずれかと一致し、かつ自 OP の issuer と異なること
 *    （draft §9.3: 同一ドメイン内で ID-JAG をアクセストークンに引き換えない）
 * 5. 署名がその IdP の JWKS で検証できること（kid 一致を優先、無ければ alg 一致
 *    鍵を順次試行。鍵ごとの alg ピン留めは core の ID トークン検証と同じ規則）
 * 6. `aud` が自 OP の issuer と一致すること。文字列、または要素数 1 の配列のみ
 *    許す（draft §4.4.1 MUST。要素数 2 以上は audience injection として拒否）
 * 7. `exp` / `iat` / `nbf`（存在時）が leeway 内で妥当なこと
 * 8. `jti` / `sub` が非空文字列であること
 * 9. `client_id` が認証済みクライアントと一致すること（draft §4.4.1 MUST。
 *    盗まれた ID-JAG を別クライアントが換金する経路を塞ぐ）
 *
 * `iss` 非信頼と署名不正は同一の固定文言で返し、信頼 IdP リストを応答から
 * 探索させない（{@link ASSERTION_UNTRUSTED_DESCRIPTION}）。それ以外の失敗は、
 * クライアントが手元の assertion から自力で確認できる内容だけを述べる。
 *
 * jti によるリプレイ拒否は行わない。draft §4.4.3 は有効期間内の同一 ID-JAG の
 * 再提示（リフレッシュトークンの代替）を意図しており、束縛はクライアント認証と
 * client_id 一致、短い exp が担う。
 *
 * @throws {IdJagError} invalid_grant
 */
export async function verifyIdJagAssertion(options: {
  assertion: string;
  issuer: string;
  clientId: string;
  identityProviders: IdJagTrustedIdentityProvider[];
  now?: Date;
  clockSkewToleranceSec?: number;
}): Promise<IdJagAssertionPayload> {
  const leeway = options.clockSkewToleranceSec ?? DEFAULT_ASSERTION_CLOCK_SKEW_SEC;

  const parts = options.assertion.split('.');
  if (parts.length !== 3) {
    throw invalidAssertion('The provided assertion is not a valid JWS compact serialization');
  }
  const [headerB64, payloadB64, signatureB64] = parts as [string, string, string];

  let header: Record<string, unknown>;
  let payload: Record<string, unknown>;
  try {
    header = parseBase64UrlJson(headerB64);
    payload = parseBase64UrlJson(payloadB64);
  } catch {
    throw invalidAssertion('The provided assertion is not a valid JWS compact serialization');
  }

  // draft §4.4.1 / RFC 8725 §3.11: typ の検証で ID トークン等の流用（token
  // confusion）を構造的に拒否する。
  if (!isIdJagTyp(header['typ'])) {
    throw invalidAssertion(`The assertion typ must be ${ID_JAG_JWT_TYP}`);
  }

  const headerAlg = typeof header['alg'] === 'string' ? header['alg'] : undefined;
  if (!headerAlg || headerAlg === 'none') {
    throw invalidAssertion('The assertion alg is missing or "none"');
  }
  for (const field of FORBIDDEN_KEY_HEADERS) {
    if (field in header) {
      throw invalidAssertion(`The assertion JOSE header contains unsupported field: ${field}`);
    }
  }

  const iss = payload['iss'];
  if (typeof iss !== 'string' || iss.length === 0) {
    throw invalidAssertion(ASSERTION_UNTRUSTED_DESCRIPTION);
  }
  // draft §9.3: 自分が発行した ID-JAG を自分で引き換えると、SSO 用の assertion が
  // 同一ドメイン内のアクセストークンへ昇格する抜け道になる。信頼リストの構成に
  // かかわらず拒否する。
  if (iss === options.issuer) {
    throw invalidAssertion(
      'An assertion issued by this authorization server cannot be redeemed here',
    );
  }
  const identityProvider = options.identityProviders.find((idp) => idp.issuer === iss);
  if (identityProvider === undefined) {
    throw invalidAssertion(ASSERTION_UNTRUSTED_DESCRIPTION);
  }

  // 鍵選択: kid 一致を優先し、無ければ alg 一致の鍵を順次試行（core の
  // validateIdTokenHint と同じ規則）。鍵の alg とヘッダの alg の不一致は
  // 検証せず読み飛ばす（RFC 7515 §4.1.1 の鍵ごとの alg ピン留め）。
  const headerKid = typeof header['kid'] === 'string' ? header['kid'] : undefined;
  const candidates = headerKid
    ? identityProvider.jwks.keys.filter((key) => key.kid === headerKid)
    : identityProvider.jwks.keys.filter((key) => key.alg === headerAlg);

  const signingInput = `${headerB64}.${payloadB64}`;
  let signatureValid = false;
  for (const jwk of candidates) {
    if (jwk.alg !== headerAlg) {
      continue;
    }
    if (await verifySignature(signingInput, signatureB64, jwk)) {
      signatureValid = true;
      break;
    }
  }
  if (!signatureValid) {
    // 「鍵が見つからない」も「署名が壊れている」も同一文言（信頼構成の探索防止）。
    throw invalidAssertion(ASSERTION_UNTRUSTED_DESCRIPTION);
  }

  // draft §4.4.1: aud は自 AS の issuer identifier。文字列か、要素数 1 の配列のみ。
  const aud = payload['aud'];
  const audMatches =
    aud === options.issuer ||
    (Array.isArray(aud) && aud.length === 1 && aud[0] === options.issuer);
  if (!audMatches) {
    throw invalidAssertion('The assertion audience does not match this authorization server');
  }

  const nowSeconds = Math.floor((options.now ?? new Date()).getTime() / 1000);
  const exp = payload['exp'];
  if (typeof exp !== 'number') {
    throw invalidAssertion('The assertion is missing an exp claim');
  }
  if (exp + leeway < nowSeconds) {
    throw invalidAssertion('The assertion has expired');
  }
  const iat = payload['iat'];
  if (typeof iat !== 'number') {
    throw invalidAssertion('The assertion is missing an iat claim');
  }
  if (iat > nowSeconds + leeway) {
    throw invalidAssertion('The assertion iat is in the future');
  }
  const nbf = payload['nbf'];
  if (nbf !== undefined) {
    if (typeof nbf !== 'number' || nbf > nowSeconds + leeway) {
      throw invalidAssertion('The assertion is not yet valid');
    }
  }

  const jti = payload['jti'];
  if (typeof jti !== 'string' || jti.length === 0) {
    throw invalidAssertion('The assertion is missing a jti claim');
  }
  const sub = payload['sub'];
  if (typeof sub !== 'string' || sub.length === 0) {
    throw invalidAssertion('The assertion is missing a sub claim');
  }

  // draft §4.4.1: client_id クレームは「リクエストを認証したクライアント」と
  // 一致しなければならない（クライアント継続性）。
  const clientId = payload['client_id'];
  if (typeof clientId !== 'string' || clientId.length === 0) {
    throw invalidAssertion('The assertion is missing a client_id claim');
  }
  if (clientId !== options.clientId) {
    throw invalidAssertion('The assertion client_id does not match the authenticated client');
  }

  const scope = payload['scope'];
  if (scope !== undefined && typeof scope !== 'string') {
    throw invalidAssertion('The assertion scope claim must be a string');
  }

  const resource = payload['resource'];
  if (
    resource !== undefined &&
    typeof resource !== 'string' &&
    !(Array.isArray(resource) && resource.every((value) => typeof value === 'string'))
  ) {
    throw invalidAssertion('The assertion resource claim must be a string or an array of strings');
  }

  const authTime = typeof payload['auth_time'] === 'number' ? payload['auth_time'] : undefined;
  const acr = typeof payload['acr'] === 'string' ? payload['acr'] : undefined;
  const amr =
    Array.isArray(payload['amr']) && payload['amr'].every((value) => typeof value === 'string')
      ? (payload['amr'] as string[])
      : undefined;

  return {
    iss,
    sub,
    aud: aud as string | string[],
    client_id: clientId,
    jti,
    exp,
    iat,
    ...(scope === undefined ? {} : { scope }),
    ...(resource === undefined ? {} : { resource: resource as string | string[] }),
    ...(authTime === undefined ? {} : { auth_time: authTime }),
    ...(acr === undefined ? {} : { acr }),
    ...(amr === undefined ? {} : { amr }),
  };
}

/**
 * ステップ 4: 実効 scope を導出する。
 *
 * 許可の上限は ID-JAG の scope クレーム（IdP が許可した範囲。draft §4.4.1 は
 * リソース AS がさらに部分集合へ絞ることを認める）。要求 scope があれば
 * その範囲内で縮小し、無ければ継承する。
 *
 * `offline_access` は常に除去する。jwt-bearer grant では refresh token を発行
 * しない（draft §4.4.3 SHOULD NOT。ID-JAG の再提示が代替）ため、実効 scope に
 * 残すと同意していない長期アクセスの表明になってしまう。
 *
 * @throws {IdJagError} invalid_scope
 */
export function resolveIdJagGrantScope(
  requestedScope: string | undefined,
  assertionScope: string | undefined,
): string[] {
  const granted = splitScope(assertionScope).filter((value) => value !== 'offline_access');
  const requested = splitScope(requestedScope);
  if (requested.length === 0) {
    return granted;
  }
  for (const value of requested) {
    if (!granted.includes(value)) {
      throw new IdJagError(
        'invalid_scope',
        'The requested scope exceeds the scope of the assertion',
      );
    }
  }
  return requested;
}

/**
 * 合成関数: jwt-bearer（ID-JAG）redemption の検証〜発行素材の導出。
 *
 * トークンの発行・保存・応答生成は行わないため、呼び出し側が core の
 * 発行パイプラインと組み合わせる。ID トークンと refresh token は発行しない
 * （jwt-bearer は OIDC の認証フローではなく、refresh token は draft §4.4.3 の
 * SHOULD NOT）。
 *
 * @throws {IdJagError}
 * @throws {RangeError} configuredExpiresIn が正の整数でない場合（設定ミス）
 */
export async function processIdJagRedemptionRequest(
  context: IdJagRedemptionContext,
): Promise<IdJagRedemptionGrant> {
  if (!Number.isInteger(context.configuredExpiresIn) || context.configuredExpiresIn <= 0) {
    throw new RangeError(
      `configuredExpiresIn must be a positive integer, received ${context.configuredExpiresIn}`,
    );
  }

  // クライアント認可を最初に行う。許可されていないクライアントには assertion の
  // 有効性すら判定させない（オラクルを与えない）。
  authorizeIdJagRedemptionClient(context.client);

  const parsed = parseIdJagRedemptionParams(context.params);

  const assertion = await verifyIdJagAssertion({
    assertion: parsed.assertion,
    issuer: context.issuer,
    clientId: context.client.clientId,
    identityProviders: context.identityProviders,
    ...(context.now === undefined ? {} : { now: context.now }),
    ...(context.clockSkewToleranceSec === undefined
      ? {}
      : { clockSkewToleranceSec: context.clockSkewToleranceSec }),
  });

  const scope = resolveIdJagGrantScope(parsed.scope, assertion.scope);

  const requestedResources =
    assertion.resource === undefined
      ? undefined
      : typeof assertion.resource === 'string'
        ? [assertion.resource]
        : [...assertion.resource];

  return {
    subject: assertion.sub,
    clientId: context.client.clientId,
    scope,
    ...(requestedResources === undefined ? {} : { requestedResources }),
    expiresIn: context.configuredExpiresIn,
    idpIssuer: assertion.iss,
    jti: assertion.jti,
    ...(assertion.auth_time === undefined ? {} : { authTime: assertion.auth_time }),
    ...(assertion.acr === undefined ? {} : { acr: assertion.acr }),
    ...(assertion.amr === undefined ? {} : { amr: assertion.amr }),
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

function invalidAssertion(description: string): IdJagError {
  return new IdJagError('invalid_grant', description);
}

/**
 * RFC 7515 §4.1.9: typ は大文字小文字を無視して解釈され、`application/` 前置は
 * 省略形と等価に扱う。`oauth-id-jag+jwt` と `application/oauth-id-jag+jwt` を受ける。
 */
function isIdJagTyp(typ: unknown): boolean {
  if (typeof typ !== 'string') return false;
  const normalized = typ.toLowerCase();
  return normalized === ID_JAG_JWT_TYP || normalized === `application/${ID_JAG_JWT_TYP}`;
}

/** base64url（パディング無し）の JSON セグメントを厳格にパースする。 */
function parseBase64UrlJson(segment: string): Record<string, unknown> {
  if (!/^[A-Za-z0-9_-]+$/.test(segment)) {
    throw new Error('invalid base64url');
  }
  const base64 = segment.replace(/-/g, '+').replace(/_/g, '/');
  const padded = base64 + '='.repeat((4 - (base64.length % 4)) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  const parsed: unknown = JSON.parse(new TextDecoder().decode(bytes));
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    throw new Error('not a JSON object');
  }
  return parsed as Record<string, unknown>;
}

function base64UrlToArrayBuffer(segment: string): ArrayBuffer {
  if (!/^[A-Za-z0-9_-]*$/.test(segment)) {
    throw new Error('invalid base64url');
  }
  const base64 = segment.replace(/-/g, '+').replace(/_/g, '/');
  const padded = base64 + '='.repeat((4 - (base64.length % 4)) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes.buffer;
}

/**
 * 1 つの JWK で compact JWS の署名を検証する。
 *
 * 検証パラメータは import 済み鍵の algorithm から導出する（ECDSA のハッシュは
 * 曲線に対応する。core の verify ヘルパーと同じ規則）。鍵の import 失敗・
 * アルゴリズム不一致・署名不一致はすべて false（呼び出し側が次の候補鍵を試すか、
 * 最終的に固定文言で拒否する）。
 */
async function verifySignature(
  signingInput: string,
  signatureB64: string,
  jwk: Jwk,
): Promise<boolean> {
  let signature: ArrayBuffer;
  try {
    signature = base64UrlToArrayBuffer(signatureB64);
  } catch {
    return false;
  }

  try {
    const algParams = extractAlgorithmParamsFromJwk(jwk as webcrypto.JsonWebKey);
    const publicKey = await crypto.subtle.importKey(
      'jwk',
      jwk as webcrypto.JsonWebKey,
      algParams,
      false,
      ['verify'],
    );

    const algorithm = publicKey.algorithm;
    let verifyParams: webcrypto.AlgorithmIdentifier | webcrypto.EcdsaParams;
    if (algorithm.name === 'RSASSA-PKCS1-v1_5') {
      verifyParams = { name: 'RSASSA-PKCS1-v1_5' };
    } else if (algorithm.name === 'ECDSA' && 'namedCurve' in algorithm) {
      const namedCurve = (algorithm as webcrypto.EcKeyAlgorithm).namedCurve;
      const hash =
        namedCurve === 'P-256' ? 'SHA-256' : namedCurve === 'P-384' ? 'SHA-384' : 'SHA-512';
      verifyParams = { name: 'ECDSA', hash };
    } else {
      return false;
    }

    return await crypto.subtle.verify(
      verifyParams,
      publicKey,
      signature,
      new TextEncoder().encode(signingInput),
    );
  } catch {
    return false;
  }
}
```

### index.ts (public API)

```typescript
/**
 * Identity Assertion Authorization Grant (ID-JAG) / Cross-App Access (XAA)
 * draft-ietf-oauth-identity-assertion-authz-grant-04
 *
 * **Experimental**: この機能の API は安定していない。マイナーリリースでも
 * 破壊的に変更されることがある。準拠先が IETF draft であり、改版でクレームや
 * 必須性が変わり得る点にも注意すること。
 *
 * `@maronn-openid-connect/core` とは別 package であり、CLI で `--enable id-jag` を
 * 明示したときのみ生成コードから利用される。
 *
 * 1 つの生成 OP に 2 つの役割を追加する:
 *
 * - **発行側（IdP）**: Token Exchange grant（RFC 8693）で
 *   `requested_token_type=urn:ietf:params:oauth:token-type:id-jag` を受け、
 *   自 OP 発行の ID トークンを検証して別トラストドメインのリソース AS 宛ての
 *   ID-JAG を発行する
 * - **受領側（リソース AS）**: `urn:ietf:params:oauth:grant-type:jwt-bearer`
 *   grant（RFC 7523）で信頼済み IdP の ID-JAG を検証し、自 OP のアクセス
 *   トークンの発行素材を導出する
 *
 * 既存の token-exchange 機能とは grant_type URN を共有するがコードは共有しない。
 * SAML subject / refresh_token subject / RAR / actor_token / DPoP は非対応
 * （notes リポジトリの仕様書の非目標を参照）。
 */
export {
  ASSERTION_UNTRUSTED_DESCRIPTION,
  SUBJECT_TOKEN_INVALID_DESCRIPTION,
  IdJagError,
  type IdJagErrorCode,
} from './errors.js';
export {
  ID_JAG_GRANT_PROFILE,
  ID_JAG_JWT_TYP,
  ID_JAG_TOKEN_TYPE,
  TOKEN_EXCHANGE_GRANT_TYPE,
  TOKEN_TYPE_ID_TOKEN,
  authorizeIdJagIssuanceClient,
  buildIdJagClaims,
  buildIdJagIssuanceResponse,
  createIdJagJwt,
  matchesIdJagIssuanceRequest,
  parseIdJagIssuanceParams,
  processIdJagIssuanceRequest,
  resolveIdJagSubject,
  validateIdJagAudience,
  validateIdJagScope,
  type IdJagClaims,
  type IdJagIssuanceContext,
  type IdJagIssuanceResponse,
  type IdJagSubject,
  type ParsedIdJagIssuanceParams,
} from './issue-id-jag.js';
export {
  DEFAULT_ASSERTION_CLOCK_SKEW_SEC,
  JWT_BEARER_GRANT_TYPE,
  authorizeIdJagRedemptionClient,
  parseIdJagRedemptionParams,
  processIdJagRedemptionRequest,
  resolveIdJagGrantScope,
  verifyIdJagAssertion,
  type IdJagAssertionPayload,
  type IdJagRedemptionContext,
  type IdJagRedemptionGrant,
  type IdJagTrustedIdentityProvider,
  type ParsedIdJagRedemptionParams,
} from './redeem-id-jag.js';
```

## The unit tests, in full

There are 108 tests — 56 on the issuing side, 52 on the consuming side — written to the repository's conventions (should + verb naming, uniquely pinned passing values, no conditionals inside `it`).
Keys and JWSs come from a test-only fixture and use nothing beyond the Web Crypto API, so the suite runs unchanged in the edge-runtime environment.

### test-helpers.ts (test-only fixtures)

Excluded by tsconfig, so it never reaches dist.
`signTestJwt` is a JWS builder independent of the implementation, used to craft invalid tokens the implementation itself refuses to produce (altered typ, expired lifetimes).

```typescript
/**
 * id-jag テスト専用フィクスチャ。
 *
 * tsconfig の exclude 対象なので dist へは出ない（公開 package に載らない）。
 * 鍵生成と JWS 組み立てを Web Crypto API だけで行い、edge-runtime 環境の
 * テストでそのまま動くようにしている。
 */
import type { webcrypto } from 'node:crypto';
import type { Jwk, JwkSet, SigningKey } from '@maronn-openid-connect/core';

export interface TestRs256Key {
  signingKey: SigningKey;
  jwk: Jwk;
  jwks: JwkSet;
}

/** RS256 鍵ペアを生成し、SigningKey と公開 JWK セットの両形式で返す。 */
export async function generateTestRs256Key(keyId: string): Promise<TestRs256Key> {
  const keyPair = await crypto.subtle.generateKey(
    {
      name: 'RSASSA-PKCS1-v1_5',
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: 'SHA-256',
    },
    true,
    ['sign', 'verify'],
  );
  const publicJwk = (await crypto.subtle.exportKey('jwk', keyPair.publicKey)) as Jwk;
  publicJwk.alg = 'RS256';
  publicJwk.use = 'sig';
  publicJwk.kid = keyId;
  return {
    signingKey: {
      privateKey: keyPair.privateKey,
      publicJwk: publicJwk as unknown as webcrypto.JsonWebKey,
      keyId,
    },
    jwk: publicJwk,
    jwks: { keys: [publicJwk] },
  };
}

function base64UrlFromBytes(bytes: Uint8Array): string {
  let binary = '';
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function base64UrlFromJson(value: Record<string, unknown>): string {
  return base64UrlFromBytes(new TextEncoder().encode(JSON.stringify(value)));
}

export function decodeJwtSegment(segment: string): Record<string, unknown> {
  const base64 = segment.replace(/-/g, '+').replace(/_/g, '/');
  const padded = base64 + '='.repeat((4 - (base64.length % 4)) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return JSON.parse(new TextDecoder().decode(bytes)) as Record<string, unknown>;
}

export function decodeJwt(token: string): {
  header: Record<string, unknown>;
  payload: Record<string, unknown>;
} {
  const [headerB64 = '', payloadB64 = ''] = token.split('.');
  return {
    header: decodeJwtSegment(headerB64),
    payload: decodeJwtSegment(payloadB64),
  };
}

/**
 * 任意のヘッダーとペイロードで compact JWS を組み立てる。
 *
 * typ 改変や不正クレームのケースを作るためのテスト専用実装で、
 * 本体実装（createIdJagJwt）とは独立している。
 */
export async function signTestJwt(options: {
  header: Record<string, unknown>;
  payload: Record<string, unknown>;
  privateKey: CryptoKey;
}): Promise<string> {
  const encodedHeader = base64UrlFromJson(options.header);
  const encodedPayload = base64UrlFromJson(options.payload);
  const signingInput = `${encodedHeader}.${encodedPayload}`;
  const signature = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5',
    options.privateKey,
    new TextEncoder().encode(signingInput),
  );
  return `${signingInput}.${base64UrlFromBytes(new Uint8Array(signature))}`;
}

/** 署名部だけを別の値に差し替える（署名改ざんケース用）。 */
export function tamperSignature(token: string): string {
  const [headerB64 = '', payloadB64 = ''] = token.split('.');
  return `${headerB64}.${payloadB64}.AAAA`;
}
```

### issue-id-jag.test.ts (issuing side)

```typescript
import { beforeAll, describe, expect, it } from 'vitest';
import { generateIdToken, type TokenClientInfo } from '@maronn-openid-connect/core';
import { IdJagError, SUBJECT_TOKEN_INVALID_DESCRIPTION } from './errors.js';
import {
  ID_JAG_GRANT_PROFILE,
  ID_JAG_JWT_TYP,
  ID_JAG_TOKEN_TYPE,
  TOKEN_EXCHANGE_GRANT_TYPE,
  TOKEN_TYPE_ID_TOKEN,
  authorizeIdJagIssuanceClient,
  buildIdJagClaims,
  buildIdJagIssuanceResponse,
  createIdJagJwt,
  matchesIdJagIssuanceRequest,
  parseIdJagIssuanceParams,
  processIdJagIssuanceRequest,
  resolveIdJagSubject,
  validateIdJagAudience,
  validateIdJagScope,
  type IdJagIssuanceContext,
} from './issue-id-jag.js';
import {
  decodeJwt,
  generateTestRs256Key,
  signTestJwt,
  type TestRs256Key,
} from './test-helpers.js';

/** IdP（自 OP）の issuer。subject_token の期待 iss であり ID-JAG の iss になる。 */
const ISSUER = 'https://idp.example.com';
/** ID-JAG の宛先（リソース AS の issuer）。 */
const AUDIENCE = 'https://rs-as.example.net';
const CLIENT_ID = 'xaa-client';

/** 2026-01-01T00:00:00Z。Unix epoch 秒で 1767225600。クレーム組み立ての固定時刻。 */
const NOW = new Date('2026-01-01T00:00:00Z');
const NOW_SECONDS = 1767225600;

let idpKey: TestRs256Key;
/** 現在時刻基準で有効な、CLIENT_ID 宛ての ID トークン。 */
let validIdToken: string;

beforeAll(async () => {
  idpKey = await generateTestRs256Key('idp-rs256-key');
  validIdToken = await mintIdToken({});
});

/**
 * core の generateIdToken で ID トークンを作る。exp / iat は実時刻基準
 * （resolveIdJagSubject が委譲する core の検証は実時刻で判定するため）。
 */
async function mintIdToken(overrides: Record<string, unknown>): Promise<string> {
  const nowSeconds = Math.floor(Date.now() / 1000);
  return generateIdToken({
    payload: {
      iss: ISSUER,
      sub: 'user-1',
      aud: CLIENT_ID,
      exp: nowSeconds + 3600,
      iat: nowSeconds,
      auth_time: nowSeconds - 10,
      acr: 'urn:mace:incommon:iap:silver',
      amr: ['pwd', 'mfa'],
      ...overrides,
    },
    privateKey: idpKey.signingKey.privateKey,
    keyId: idpKey.signingKey.keyId,
  });
}

function confidentialClient(overrides: Partial<TokenClientInfo> = {}): TokenClientInfo {
  return {
    clientId: CLIENT_ID,
    clientSecret: 'secret',
    grantTypes: ['authorization_code', TOKEN_EXCHANGE_GRANT_TYPE],
    tokenEndpointAuthMethod: 'client_secret_basic',
    ...overrides,
  };
}

function validParams(overrides: Record<string, string | undefined> = {}): Record<string, string> {
  const base: Record<string, string | undefined> = {
    grant_type: TOKEN_EXCHANGE_GRANT_TYPE,
    requested_token_type: ID_JAG_TOKEN_TYPE,
    subject_token: validIdToken,
    subject_token_type: TOKEN_TYPE_ID_TOKEN,
    audience: AUDIENCE,
    scope: 'openid profile',
    ...overrides,
  };
  const params: Record<string, string> = {};
  for (const [key, value] of Object.entries(base)) {
    if (value !== undefined) params[key] = value;
  }
  return params;
}

function issuanceContext(overrides: Partial<IdJagIssuanceContext> = {}): IdJagIssuanceContext {
  return {
    params: validParams(),
    client: confidentialClient(),
    issuer: ISSUER,
    jwks: idpKey.jwks,
    signingKey: idpKey.signingKey,
    allowedAudiences: [AUDIENCE],
    lifetimeSeconds: 300,
    now: NOW,
    ...overrides,
  };
}

describe('id-jag issuance constants', () => {
  // draft §4.3 / RFC 8693 §3
  it('should expose the ID-JAG token type URN', () => {
    expect(ID_JAG_TOKEN_TYPE).toBe('urn:ietf:params:oauth:token-type:id-jag');
  });

  it('should expose the id_token subject token type URN', () => {
    expect(TOKEN_TYPE_ID_TOKEN).toBe('urn:ietf:params:oauth:token-type:id_token');
  });

  // draft §3.1: JWT header typ (RFC 8725 §3.11 explicit typing)
  it('should expose the oauth-id-jag+jwt typ value', () => {
    expect(ID_JAG_JWT_TYP).toBe('oauth-id-jag+jwt');
  });

  // draft §7.2 / §8
  it('should expose the grant profile identifier', () => {
    expect(ID_JAG_GRANT_PROFILE).toBe('urn:ietf:params:oauth:grant-profile:id-jag');
  });
});

describe('matchesIdJagIssuanceRequest', () => {
  it('should match a token-exchange request that asks for an ID-JAG', () => {
    expect(matchesIdJagIssuanceRequest(validParams())).toBe(true);
  });

  it('should not match a token-exchange request without requested_token_type', () => {
    expect(matchesIdJagIssuanceRequest(validParams({ requested_token_type: undefined }))).toBe(
      false,
    );
  });

  it('should not match a token-exchange request for an access token', () => {
    expect(
      matchesIdJagIssuanceRequest(
        validParams({ requested_token_type: 'urn:ietf:params:oauth:token-type:access_token' }),
      ),
    ).toBe(false);
  });

  it('should not match other grant types', () => {
    expect(matchesIdJagIssuanceRequest(validParams({ grant_type: 'authorization_code' }))).toBe(
      false,
    );
  });
});

describe('authorizeIdJagIssuanceClient', () => {
  it('should accept a confidential client registered for the token-exchange grant', () => {
    expect(() => authorizeIdJagIssuanceClient(confidentialClient())).not.toThrow();
  });

  // RFC 7591 §2: grantTypes 未指定は ['authorization_code'] 扱い
  it('should reject a client without registered grantTypes with unauthorized_client', () => {
    const client = confidentialClient();
    delete (client as { grantTypes?: string[] }).grantTypes;
    expect(() => authorizeIdJagIssuanceClient(client)).toThrow(
      new IdJagError(
        'unauthorized_client',
        'The client is not authorized to use the token-exchange grant type',
      ),
    );
  });

  it('should reject a client not registered for the token-exchange grant', () => {
    const client = confidentialClient({ grantTypes: ['authorization_code'] });
    expect(() => authorizeIdJagIssuanceClient(client)).toThrow(
      new IdJagError(
        'unauthorized_client',
        'The client is not authorized to use the token-exchange grant type',
      ),
    );
  });

  // draft §9.1: confidential client 限定
  it('should reject a public client with unauthorized_client', () => {
    const client = confidentialClient({
      tokenEndpointAuthMethod: 'none',
      clientSecret: undefined,
    });
    expect(() => authorizeIdJagIssuanceClient(client)).toThrow(
      new IdJagError('unauthorized_client', 'Public clients are not allowed to request an ID-JAG'),
    );
  });
});

describe('parseIdJagIssuanceParams', () => {
  it('should return the typed parameters', () => {
    expect(parseIdJagIssuanceParams(validParams({ resource: 'https://api.example.net/files' }))).toEqual({
      subjectToken: validIdToken,
      audience: AUDIENCE,
      scope: 'openid profile',
      resource: 'https://api.example.net/files',
    });
  });

  it('should treat omitted scope and resource as undefined', () => {
    expect(parseIdJagIssuanceParams(validParams({ scope: undefined }))).toEqual({
      subjectToken: validIdToken,
      audience: AUDIENCE,
      scope: undefined,
      resource: undefined,
    });
  });

  it('should reject a missing subject_token with invalid_request', () => {
    expect(() => parseIdJagIssuanceParams(validParams({ subject_token: undefined }))).toThrow(
      new IdJagError('invalid_request', 'subject_token is required'),
    );
  });

  it('should reject a missing subject_token_type with invalid_request', () => {
    expect(() => parseIdJagIssuanceParams(validParams({ subject_token_type: undefined }))).toThrow(
      new IdJagError('invalid_request', 'subject_token_type is required'),
    );
  });

  // 非目標: saml2 / refresh_token / access_token の subject は受けない
  it('should reject a saml2 subject_token_type with invalid_request', () => {
    expect(() =>
      parseIdJagIssuanceParams(
        validParams({ subject_token_type: 'urn:ietf:params:oauth:token-type:saml2' }),
      ),
    ).toThrow(
      new IdJagError(
        'invalid_request',
        `Unsupported subject_token_type for ID-JAG issuance. Only ${TOKEN_TYPE_ID_TOKEN} is supported.`,
      ),
    );
  });

  it('should reject a refresh_token subject_token_type with invalid_request', () => {
    expect(() =>
      parseIdJagIssuanceParams(
        validParams({ subject_token_type: 'urn:ietf:params:oauth:token-type:refresh_token' }),
      ),
    ).toThrow(IdJagError);
  });

  // draft §4.3: audience は REQUIRED
  it('should reject a missing audience with invalid_request', () => {
    expect(() => parseIdJagIssuanceParams(validParams({ audience: undefined }))).toThrow(
      new IdJagError('invalid_request', 'audience is required'),
    );
  });

  it('should treat a whitespace-only audience as missing', () => {
    expect(() => parseIdJagIssuanceParams(validParams({ audience: '   ' }))).toThrow(
      new IdJagError('invalid_request', 'audience is required'),
    );
  });

  // RFC 8707 §2: resource は絶対 URI・fragment 禁止
  it('should reject a relative resource with invalid_request', () => {
    expect(() => parseIdJagIssuanceParams(validParams({ resource: '/files' }))).toThrow(
      new IdJagError(
        'invalid_request',
        'resource must be an absolute URI without a fragment component',
      ),
    );
  });

  it('should reject a resource with a fragment with invalid_request', () => {
    expect(() =>
      parseIdJagIssuanceParams(validParams({ resource: 'https://api.example.net/#top' })),
    ).toThrow(IdJagError);
  });

  // draft §9.7: actor_token の処理規則は未定義なので fail-safe に拒否する
  it('should reject an actor_token with invalid_request', () => {
    expect(() => parseIdJagIssuanceParams(validParams({ actor_token: 'some-token' }))).toThrow(
      new IdJagError('invalid_request', 'actor_token is not supported for ID-JAG issuance'),
    );
  });

  it('should reject an actor_token_type with invalid_request', () => {
    expect(() =>
      parseIdJagIssuanceParams(
        validParams({ actor_token_type: 'urn:ietf:params:oauth:token-type:access_token' }),
      ),
    ).toThrow(IdJagError);
  });

  // 非目標: RAR
  it('should reject authorization_details with invalid_request', () => {
    expect(() =>
      parseIdJagIssuanceParams(validParams({ authorization_details: '[{"type":"x"}]' })),
    ).toThrow(
      new IdJagError('invalid_request', 'authorization_details is not supported for ID-JAG issuance'),
    );
  });
});

describe('resolveIdJagSubject', () => {
  it('should return the subject material from a valid ID Token', async () => {
    const nowSeconds = Math.floor(Date.now() / 1000);
    const idToken = await mintIdToken({ auth_time: nowSeconds - 20 });
    await expect(
      resolveIdJagSubject({
        subjectToken: idToken,
        issuer: ISSUER,
        clientId: CLIENT_ID,
        jwks: idpKey.jwks,
      }),
    ).resolves.toEqual({
      sub: 'user-1',
      authTime: nowSeconds - 20,
      acr: 'urn:mace:incommon:iap:silver',
      amr: ['pwd', 'mfa'],
    });
  });

  it('should omit auth context fields the ID Token does not carry', async () => {
    const idToken = await mintIdToken({ auth_time: undefined, acr: undefined, amr: undefined });
    await expect(
      resolveIdJagSubject({
        subjectToken: idToken,
        issuer: ISSUER,
        clientId: CLIENT_ID,
        jwks: idpKey.jwks,
      }),
    ).resolves.toEqual({ sub: 'user-1' });
  });

  // draft §4.3.3: assertion の audience はクライアント認証の client_id と一致しなければならない
  it('should reject an ID Token issued to another client with the fixed description', async () => {
    const idToken = await mintIdToken({ aud: 'another-client' });
    await expect(
      resolveIdJagSubject({
        subjectToken: idToken,
        issuer: ISSUER,
        clientId: CLIENT_ID,
        jwks: idpKey.jwks,
      }),
    ).rejects.toThrow(new IdJagError('invalid_request', SUBJECT_TOKEN_INVALID_DESCRIPTION));
  });

  // オラクル排除: 失敗種別によらず同じ応答になる
  it('should reject a tampered ID Token with the same fixed description', async () => {
    const [headerB64 = '', payloadB64 = ''] = validIdToken.split('.');
    await expect(
      resolveIdJagSubject({
        subjectToken: `${headerB64}.${payloadB64}.AAAA`,
        issuer: ISSUER,
        clientId: CLIENT_ID,
        jwks: idpKey.jwks,
      }),
    ).rejects.toThrow(new IdJagError('invalid_request', SUBJECT_TOKEN_INVALID_DESCRIPTION));
  });

  it('should reject an expired ID Token with the same fixed description', async () => {
    // core の generateIdToken は期限切れ payload の生成自体を拒否するため、
    // 期限切れトークンはテスト用の JWS 手組みで作る（署名は正当なまま）。
    const nowSeconds = Math.floor(Date.now() / 1000);
    const idToken = await signTestJwt({
      header: { alg: 'RS256', typ: 'JWT', kid: idpKey.signingKey.keyId },
      payload: {
        iss: ISSUER,
        sub: 'user-1',
        aud: CLIENT_ID,
        exp: nowSeconds - 3600,
        iat: nowSeconds - 7200,
      },
      privateKey: idpKey.signingKey.privateKey,
    });
    await expect(
      resolveIdJagSubject({
        subjectToken: idToken,
        issuer: ISSUER,
        clientId: CLIENT_ID,
        jwks: idpKey.jwks,
      }),
    ).rejects.toThrow(new IdJagError('invalid_request', SUBJECT_TOKEN_INVALID_DESCRIPTION));
  });

  it('should reject an ID Token from another issuer with the same fixed description', async () => {
    const idToken = await mintIdToken({ iss: 'https://other-idp.example.com' });
    await expect(
      resolveIdJagSubject({
        subjectToken: idToken,
        issuer: ISSUER,
        clientId: CLIENT_ID,
        jwks: idpKey.jwks,
      }),
    ).rejects.toThrow(new IdJagError('invalid_request', SUBJECT_TOKEN_INVALID_DESCRIPTION));
  });
});

describe('validateIdJagAudience', () => {
  it('should accept an allow-listed audience', () => {
    expect(() =>
      validateIdJagAudience({
        audience: AUDIENCE,
        issuer: ISSUER,
        allowedAudiences: [AUDIENCE],
      }),
    ).not.toThrow();
  });

  it('should reject an audience outside the allow list with invalid_target', () => {
    expect(() =>
      validateIdJagAudience({
        audience: 'https://unknown.example.org',
        issuer: ISSUER,
        allowedAudiences: [AUDIENCE],
      }),
    ).toThrow(
      new IdJagError('invalid_target', 'The requested audience is not allowed for ID-JAG issuance'),
    );
  });

  it('should reject every audience when the allow list is empty', () => {
    expect(() =>
      validateIdJagAudience({ audience: AUDIENCE, issuer: ISSUER, allowedAudiences: [] }),
    ).toThrow(IdJagError);
  });

  // draft §9.3: クロスドメイン限定。自分宛ての発行は許可リストに関係なく拒否する
  it('should reject the issuer itself as audience even when allow-listed', () => {
    expect(() =>
      validateIdJagAudience({ audience: ISSUER, issuer: ISSUER, allowedAudiences: [ISSUER] }),
    ).toThrow(
      new IdJagError(
        'invalid_target',
        'The requested audience must belong to a different trust domain than this authorization server',
      ),
    );
  });
});

describe('validateIdJagScope', () => {
  it('should pass the requested scope through when no allow list is configured', () => {
    expect(validateIdJagScope('openid profile', undefined)).toEqual(['openid', 'profile']);
  });

  it('should return an empty scope when nothing is requested', () => {
    expect(validateIdJagScope(undefined, undefined)).toEqual([]);
  });

  it('should deduplicate repeated scope values', () => {
    expect(validateIdJagScope('openid openid profile', undefined)).toEqual(['openid', 'profile']);
  });

  it('should accept a subset of the configured allow list', () => {
    expect(validateIdJagScope('openid', ['openid', 'profile'])).toEqual(['openid']);
  });

  it('should reject a scope outside the allow list with invalid_scope', () => {
    expect(() => validateIdJagScope('openid admin', ['openid', 'profile'])).toThrow(
      new IdJagError(
        'invalid_scope',
        'The requested scope exceeds the scopes allowed for ID-JAG issuance',
      ),
    );
  });
});

describe('buildIdJagClaims', () => {
  // draft §3.1 の REQUIRED クレーム一式
  it('should build the required claims from the subject and request', () => {
    const claims = buildIdJagClaims({
      issuer: ISSUER,
      subject: { sub: 'user-1' },
      audience: AUDIENCE,
      clientId: CLIENT_ID,
      scope: ['openid', 'profile'],
      lifetimeSeconds: 300,
      now: NOW,
    });
    expect(claims).toMatchObject({
      iss: ISSUER,
      sub: 'user-1',
      aud: AUDIENCE,
      client_id: CLIENT_ID,
      exp: NOW_SECONDS + 300,
      iat: NOW_SECONDS,
      scope: 'openid profile',
    });
    expect(typeof claims.jti).toBe('string');
    // 256bit を base64url した長さ（43 文字）
    expect(claims.jti.length).toBe(43);
  });

  it('should omit the scope claim when no scope was granted', () => {
    const claims = buildIdJagClaims({
      issuer: ISSUER,
      subject: { sub: 'user-1' },
      audience: AUDIENCE,
      clientId: CLIENT_ID,
      scope: [],
      lifetimeSeconds: 300,
      now: NOW,
    });
    expect('scope' in claims).toBe(false);
  });

  it('should carry resource and auth context claims when present', () => {
    const claims = buildIdJagClaims({
      issuer: ISSUER,
      subject: { sub: 'user-1', authTime: NOW_SECONDS - 60, acr: 'silver', amr: ['pwd'] },
      audience: AUDIENCE,
      clientId: CLIENT_ID,
      scope: [],
      resource: 'https://api.example.net/files',
      lifetimeSeconds: 300,
      now: NOW,
    });
    expect(claims).toMatchObject({
      resource: 'https://api.example.net/files',
      auth_time: NOW_SECONDS - 60,
      acr: 'silver',
      amr: ['pwd'],
    });
  });

  it('should reject a non-positive lifetime with a RangeError', () => {
    expect(() =>
      buildIdJagClaims({
        issuer: ISSUER,
        subject: { sub: 'user-1' },
        audience: AUDIENCE,
        clientId: CLIENT_ID,
        scope: [],
        lifetimeSeconds: 0,
        now: NOW,
      }),
    ).toThrow(RangeError);
  });
});

describe('createIdJagJwt', () => {
  // draft §3.1: typ は oauth-id-jag+jwt（RFC 8725 §3.11）
  it('should set alg RS256, the ID-JAG typ and the kid in the JOSE header', async () => {
    const claims = buildIdJagClaims({
      issuer: ISSUER,
      subject: { sub: 'user-1' },
      audience: AUDIENCE,
      clientId: CLIENT_ID,
      scope: ['openid'],
      lifetimeSeconds: 300,
      now: NOW,
    });
    const jwt = await createIdJagJwt({ claims, signingKey: idpKey.signingKey });
    const { header, payload } = decodeJwt(jwt);
    expect(header).toEqual({
      alg: 'RS256',
      typ: 'oauth-id-jag+jwt',
      kid: 'idp-rs256-key',
    });
    expect(payload).toEqual({ ...claims });
  });

  it('should produce a verifiable RS256 signature', async () => {
    const claims = buildIdJagClaims({
      issuer: ISSUER,
      subject: { sub: 'user-1' },
      audience: AUDIENCE,
      clientId: CLIENT_ID,
      scope: [],
      lifetimeSeconds: 300,
      now: NOW,
    });
    const jwt = await createIdJagJwt({ claims, signingKey: idpKey.signingKey });
    const [headerB64 = '', payloadB64 = '', signatureB64 = ''] = jwt.split('.');
    const publicKey = await crypto.subtle.importKey(
      'jwk',
      idpKey.jwk as JsonWebKey,
      { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
      false,
      ['verify'],
    );
    const base64 = signatureB64.replace(/-/g, '+').replace(/_/g, '/');
    const padded = base64 + '='.repeat((4 - (base64.length % 4)) % 4);
    const signature = Uint8Array.from(atob(padded), (char) => char.charCodeAt(0));
    await expect(
      crypto.subtle.verify(
        'RSASSA-PKCS1-v1_5',
        publicKey,
        signature,
        new TextEncoder().encode(`${headerB64}.${payloadB64}`),
      ),
    ).resolves.toBe(true);
  });
});

describe('buildIdJagIssuanceResponse', () => {
  // draft §4.3.4: token_type は N_A、issued_token_type は ID-JAG の URN
  it('should build the RFC 8693 response with token_type N_A', () => {
    expect(
      buildIdJagIssuanceResponse({ idJag: 'jwt-value', expiresIn: 300, scope: ['openid'] }),
    ).toEqual({
      access_token: 'jwt-value',
      issued_token_type: 'urn:ietf:params:oauth:token-type:id-jag',
      token_type: 'N_A',
      expires_in: 300,
      scope: 'openid',
    });
  });

  it('should return an empty scope string when no scope was granted', () => {
    expect(buildIdJagIssuanceResponse({ idJag: 'jwt-value', expiresIn: 300, scope: [] })).toEqual({
      access_token: 'jwt-value',
      issued_token_type: 'urn:ietf:params:oauth:token-type:id-jag',
      token_type: 'N_A',
      expires_in: 300,
      scope: '',
    });
  });
});

describe('processIdJagIssuanceRequest', () => {
  it('should issue an ID-JAG for a valid request', async () => {
    const response = await processIdJagIssuanceRequest(issuanceContext());
    expect(response.issued_token_type).toBe('urn:ietf:params:oauth:token-type:id-jag');
    expect(response.token_type).toBe('N_A');
    expect(response.expires_in).toBe(300);
    expect(response.scope).toBe('openid profile');

    const { header, payload } = decodeJwt(response.access_token);
    expect(header['typ']).toBe('oauth-id-jag+jwt');
    expect(header['alg']).toBe('RS256');
    expect(payload).toMatchObject({
      iss: ISSUER,
      sub: 'user-1',
      aud: AUDIENCE,
      client_id: CLIENT_ID,
      exp: NOW_SECONDS + 300,
      iat: NOW_SECONDS,
      scope: 'openid profile',
    });
  });

  it('should reject an unauthorized client before validating the subject_token', async () => {
    await expect(
      processIdJagIssuanceRequest(
        issuanceContext({
          client: confidentialClient({ grantTypes: ['authorization_code'] }),
          params: validParams({ subject_token: 'never-validated' }),
        }),
      ),
    ).rejects.toThrow(
      new IdJagError(
        'unauthorized_client',
        'The client is not authorized to use the token-exchange grant type',
      ),
    );
  });

  it('should reject an ID Token issued to another client with invalid_request', async () => {
    const foreignIdToken = await mintIdToken({ aud: 'another-client' });
    await expect(
      processIdJagIssuanceRequest(
        issuanceContext({ params: validParams({ subject_token: foreignIdToken }) }),
      ),
    ).rejects.toThrow(new IdJagError('invalid_request', SUBJECT_TOKEN_INVALID_DESCRIPTION));
  });

  it('should reject an audience outside the allow list with invalid_target', async () => {
    await expect(
      processIdJagIssuanceRequest(
        issuanceContext({ params: validParams({ audience: 'https://unknown.example.org' }) }),
      ),
    ).rejects.toThrow(
      new IdJagError('invalid_target', 'The requested audience is not allowed for ID-JAG issuance'),
    );
  });

  it('should reject the issuer itself as audience with invalid_target', async () => {
    await expect(
      processIdJagIssuanceRequest(
        issuanceContext({
          params: validParams({ audience: ISSUER }),
          allowedAudiences: [AUDIENCE, ISSUER],
        }),
      ),
    ).rejects.toThrow(
      new IdJagError(
        'invalid_target',
        'The requested audience must belong to a different trust domain than this authorization server',
      ),
    );
  });

  it('should reject a scope outside the configured allow list with invalid_scope', async () => {
    await expect(
      processIdJagIssuanceRequest(
        issuanceContext({
          allowedScopes: ['openid'],
          params: validParams({ scope: 'openid profile' }),
        }),
      ),
    ).rejects.toThrow(
      new IdJagError(
        'invalid_scope',
        'The requested scope exceeds the scopes allowed for ID-JAG issuance',
      ),
    );
  });

  it('should omit the scope claim and return an empty scope when none was requested', async () => {
    const response = await processIdJagIssuanceRequest(
      issuanceContext({ params: validParams({ scope: undefined }) }),
    );
    expect(response.scope).toBe('');
    const { payload } = decodeJwt(response.access_token);
    expect('scope' in payload).toBe(false);
  });

  it('should carry the resource parameter into the resource claim', async () => {
    const response = await processIdJagIssuanceRequest(
      issuanceContext({ params: validParams({ resource: 'https://api.example.net/files' }) }),
    );
    const { payload } = decodeJwt(response.access_token);
    expect(payload['resource']).toBe('https://api.example.net/files');
  });
});
```

### redeem-id-jag.test.ts (consuming side)

```typescript
import { beforeAll, describe, expect, it } from 'vitest';
import type { TokenClientInfo } from '@maronn-openid-connect/core';
import { ASSERTION_UNTRUSTED_DESCRIPTION, IdJagError } from './errors.js';
import { ID_JAG_JWT_TYP } from './issue-id-jag.js';
import {
  DEFAULT_ASSERTION_CLOCK_SKEW_SEC,
  JWT_BEARER_GRANT_TYPE,
  authorizeIdJagRedemptionClient,
  parseIdJagRedemptionParams,
  processIdJagRedemptionRequest,
  resolveIdJagGrantScope,
  verifyIdJagAssertion,
  type IdJagRedemptionContext,
  type IdJagTrustedIdentityProvider,
} from './redeem-id-jag.js';
import {
  generateTestRs256Key,
  signTestJwt,
  tamperSignature,
  type TestRs256Key,
} from './test-helpers.js';

/** 自 OP（リソース AS）の issuer。assertion の期待 aud。 */
const ISSUER = 'https://rs-as.example.net';
/** 信頼する IdP の issuer。assertion の iss。 */
const IDP_ISSUER = 'https://idp.example.com';
const CLIENT_ID = 'xaa-client';

/** 2026-01-01T00:00:00Z。Unix epoch 秒で 1767225600。 */
const NOW = new Date('2026-01-01T00:00:00Z');
const NOW_SECONDS = 1767225600;

let idpKey: TestRs256Key;
let otherKey: TestRs256Key;
let identityProviders: IdJagTrustedIdentityProvider[];

beforeAll(async () => {
  idpKey = await generateTestRs256Key('trusted-idp-key');
  otherKey = await generateTestRs256Key('untrusted-key');
  identityProviders = [{ issuer: IDP_ISSUER, jwks: idpKey.jwks }];
});

function idJagClaims(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    iss: IDP_ISSUER,
    sub: 'user-1',
    aud: ISSUER,
    client_id: CLIENT_ID,
    jti: 'jag-1',
    exp: NOW_SECONDS + 300,
    iat: NOW_SECONDS,
    scope: 'openid profile offline_access',
    ...overrides,
  };
}

function idJagHeader(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return { alg: 'RS256', typ: ID_JAG_JWT_TYP, kid: 'trusted-idp-key', ...overrides };
}

async function mintIdJag(options: {
  claims?: Record<string, unknown>;
  header?: Record<string, unknown>;
  key?: TestRs256Key;
} = {}): Promise<string> {
  const key = options.key ?? idpKey;
  return signTestJwt({
    header: idJagHeader(options.header),
    payload: idJagClaims(options.claims),
    privateKey: key.signingKey.privateKey,
  });
}

function confidentialClient(overrides: Partial<TokenClientInfo> = {}): TokenClientInfo {
  return {
    clientId: CLIENT_ID,
    clientSecret: 'secret',
    grantTypes: ['authorization_code', JWT_BEARER_GRANT_TYPE],
    tokenEndpointAuthMethod: 'client_secret_basic',
    ...overrides,
  };
}

function redemptionContext(
  assertion: string,
  overrides: Partial<IdJagRedemptionContext> = {},
): IdJagRedemptionContext {
  return {
    params: { grant_type: JWT_BEARER_GRANT_TYPE, assertion },
    client: confidentialClient(),
    issuer: ISSUER,
    identityProviders,
    configuredExpiresIn: 3600,
    now: NOW,
    ...overrides,
  };
}

async function expectAssertionRejection(
  assertion: string,
  description: string,
): Promise<void> {
  await expect(
    verifyIdJagAssertion({
      assertion,
      issuer: ISSUER,
      clientId: CLIENT_ID,
      identityProviders,
      now: NOW,
    }),
  ).rejects.toThrow(new IdJagError('invalid_grant', description));
}

describe('id-jag redemption constants', () => {
  // RFC 7523 §2.1
  it('should expose the jwt-bearer grant type URN', () => {
    expect(JWT_BEARER_GRANT_TYPE).toBe('urn:ietf:params:oauth:grant-type:jwt-bearer');
  });

  // RFC 8725 §3.8: leeway は数分以内。core の ID トークン検証と同じ 60 秒
  it('should default the clock skew tolerance to 60 seconds', () => {
    expect(DEFAULT_ASSERTION_CLOCK_SKEW_SEC).toBe(60);
  });
});

describe('authorizeIdJagRedemptionClient', () => {
  it('should accept a confidential client registered for the jwt-bearer grant', () => {
    expect(() => authorizeIdJagRedemptionClient(confidentialClient())).not.toThrow();
  });

  it('should reject a client not registered for the jwt-bearer grant with unauthorized_client', () => {
    const client = confidentialClient({ grantTypes: ['authorization_code'] });
    expect(() => authorizeIdJagRedemptionClient(client)).toThrow(
      new IdJagError(
        'unauthorized_client',
        'The client is not authorized to use the jwt-bearer grant type',
      ),
    );
  });

  // draft §9.1: confidential client 限定
  it('should reject a public client with unauthorized_client', () => {
    const client = confidentialClient({
      tokenEndpointAuthMethod: 'none',
      clientSecret: undefined,
    });
    expect(() => authorizeIdJagRedemptionClient(client)).toThrow(
      new IdJagError(
        'unauthorized_client',
        'Public clients are not allowed to use the jwt-bearer grant type',
      ),
    );
  });
});

describe('parseIdJagRedemptionParams', () => {
  it('should return the typed parameters', () => {
    expect(
      parseIdJagRedemptionParams({
        grant_type: JWT_BEARER_GRANT_TYPE,
        assertion: 'a.b.c',
        scope: 'openid',
      }),
    ).toEqual({ assertion: 'a.b.c', scope: 'openid' });
  });

  it('should reject a missing assertion with invalid_request', () => {
    expect(() => parseIdJagRedemptionParams({ grant_type: JWT_BEARER_GRANT_TYPE })).toThrow(
      new IdJagError('invalid_request', 'assertion is required'),
    );
  });

  // 非目標: RAR
  it('should reject authorization_details with invalid_request', () => {
    expect(() =>
      parseIdJagRedemptionParams({
        grant_type: JWT_BEARER_GRANT_TYPE,
        assertion: 'a.b.c',
        authorization_details: '[{"type":"x"}]',
      }),
    ).toThrow(
      new IdJagError(
        'invalid_request',
        'authorization_details is not supported for the jwt-bearer grant',
      ),
    );
  });
});

describe('verifyIdJagAssertion', () => {
  describe('acceptance', () => {
    it('should return the payload of a valid ID-JAG', async () => {
      const assertion = await mintIdJag({
        claims: {
          resource: 'https://api.example.net/files',
          auth_time: NOW_SECONDS - 60,
          acr: 'silver',
          amr: ['pwd'],
        },
      });
      await expect(
        verifyIdJagAssertion({
          assertion,
          issuer: ISSUER,
          clientId: CLIENT_ID,
          identityProviders,
          now: NOW,
        }),
      ).resolves.toEqual({
        iss: IDP_ISSUER,
        sub: 'user-1',
        aud: ISSUER,
        client_id: CLIENT_ID,
        jti: 'jag-1',
        exp: NOW_SECONDS + 300,
        iat: NOW_SECONDS,
        scope: 'openid profile offline_access',
        resource: 'https://api.example.net/files',
        auth_time: NOW_SECONDS - 60,
        acr: 'silver',
        amr: ['pwd'],
      });
    });

    // draft §4.4.1: aud は要素数 1 の配列でもよい
    it('should accept an aud claim that is a single-element array', async () => {
      const assertion = await mintIdJag({ claims: { aud: [ISSUER] } });
      await expect(
        verifyIdJagAssertion({
          assertion,
          issuer: ISSUER,
          clientId: CLIENT_ID,
          identityProviders,
          now: NOW,
        }),
      ).resolves.toMatchObject({ aud: [ISSUER] });
    });

    // RFC 7515 §4.1.9: typ は application/ 前置と大文字小文字の差を許容する
    it('should accept an application/-prefixed typ header', async () => {
      const assertion = await mintIdJag({ header: { typ: `application/${ID_JAG_JWT_TYP}` } });
      await expect(
        verifyIdJagAssertion({
          assertion,
          issuer: ISSUER,
          clientId: CLIENT_ID,
          identityProviders,
          now: NOW,
        }),
      ).resolves.toMatchObject({ jti: 'jag-1' });
    });

    // kid が無くても alg 一致の鍵で検証できる
    it('should verify with an alg-matched key when the header has no kid', async () => {
      const assertion = await mintIdJag({ header: { kid: undefined } });
      await expect(
        verifyIdJagAssertion({
          assertion,
          issuer: ISSUER,
          clientId: CLIENT_ID,
          identityProviders,
          now: NOW,
        }),
      ).resolves.toMatchObject({ sub: 'user-1' });
    });

    it('should pick the trusted IdP by the iss claim when several are configured', async () => {
      const assertion = await mintIdJag();
      await expect(
        verifyIdJagAssertion({
          assertion,
          issuer: ISSUER,
          clientId: CLIENT_ID,
          identityProviders: [
            { issuer: 'https://another-idp.example.org', jwks: otherKey.jwks },
            { issuer: IDP_ISSUER, jwks: idpKey.jwks },
          ],
          now: NOW,
        }),
      ).resolves.toMatchObject({ iss: IDP_ISSUER });
    });

    // RFC 8725 §3.8: exp は leeway 内なら許容
    it('should accept an assertion that expired within the clock skew tolerance', async () => {
      const assertion = await mintIdJag({ claims: { exp: NOW_SECONDS - 30 } });
      await expect(
        verifyIdJagAssertion({
          assertion,
          issuer: ISSUER,
          clientId: CLIENT_ID,
          identityProviders,
          now: NOW,
        }),
      ).resolves.toMatchObject({ exp: NOW_SECONDS - 30 });
    });
  });

  describe('structural rejection', () => {
    it('should reject a value that is not a compact JWS', async () => {
      await expectAssertionRejection(
        'not-a-jwt',
        'The provided assertion is not a valid JWS compact serialization',
      );
    });

    it('should reject a JWS whose segments are not base64url JSON', async () => {
      await expectAssertionRejection(
        '!!!.???.___',
        'The provided assertion is not a valid JWS compact serialization',
      );
    });

    // draft §4.4.1 / RFC 8725 §3.11: typ の検証で token confusion を拒否する
    it('should reject a JWT typ other than oauth-id-jag+jwt', async () => {
      const assertion = await mintIdJag({ header: { typ: 'JWT' } });
      await expectAssertionRejection(assertion, `The assertion typ must be ${ID_JAG_JWT_TYP}`);
    });

    it('should reject a missing typ header', async () => {
      const assertion = await mintIdJag({ header: { typ: undefined } });
      await expectAssertionRejection(assertion, `The assertion typ must be ${ID_JAG_JWT_TYP}`);
    });

    it('should reject alg none', async () => {
      const assertion = await mintIdJag({ header: { alg: 'none' } });
      await expectAssertionRejection(assertion, 'The assertion alg is missing or "none"');
    });

    // RFC 8725 §3.1: 外部鍵取得ヘッダは SSRF と鍵差し替えの経路になるため拒否する
    it('should reject a jku header', async () => {
      const assertion = await mintIdJag({ header: { jku: 'https://evil.example.com/jwks' } });
      await expectAssertionRejection(
        assertion,
        'The assertion JOSE header contains unsupported field: jku',
      );
    });

    it('should reject an embedded jwk header', async () => {
      const assertion = await mintIdJag({ header: { jwk: { kty: 'RSA' } } });
      await expectAssertionRejection(
        assertion,
        'The assertion JOSE header contains unsupported field: jwk',
      );
    });
  });

  describe('issuer and signature rejection', () => {
    // オラクル排除: iss 非信頼と署名不正は同一文言
    it('should reject an untrusted issuer with the fixed description', async () => {
      const assertion = await mintIdJag({ claims: { iss: 'https://unknown-idp.example.org' } });
      await expectAssertionRejection(assertion, ASSERTION_UNTRUSTED_DESCRIPTION);
    });

    it('should reject a tampered signature with the same fixed description', async () => {
      const assertion = tamperSignature(await mintIdJag());
      await expectAssertionRejection(assertion, ASSERTION_UNTRUSTED_DESCRIPTION);
    });

    it('should reject a signature by an untrusted key with the same fixed description', async () => {
      const assertion = await mintIdJag({ key: otherKey, header: { kid: 'untrusted-key' } });
      await expectAssertionRejection(assertion, ASSERTION_UNTRUSTED_DESCRIPTION);
    });

    // draft §9.3: 自分が発行した ID-JAG は同一ドメイン内で引き換えない
    it('should reject an assertion issued by this authorization server itself', async () => {
      const assertion = await mintIdJag({ claims: { iss: ISSUER } });
      await expectAssertionRejection(
        assertion,
        'An assertion issued by this authorization server cannot be redeemed here',
      );
    });

    it('should reject the self-issued assertion even when the own issuer is trust-listed', async () => {
      const assertion = await mintIdJag({ claims: { iss: ISSUER } });
      await expect(
        verifyIdJagAssertion({
          assertion,
          issuer: ISSUER,
          clientId: CLIENT_ID,
          identityProviders: [{ issuer: ISSUER, jwks: idpKey.jwks }],
          now: NOW,
        }),
      ).rejects.toThrow(
        new IdJagError(
          'invalid_grant',
          'An assertion issued by this authorization server cannot be redeemed here',
        ),
      );
    });
  });

  describe('claim rejection', () => {
    // draft §4.4.1: aud 不一致は audience injection として拒否
    it('should reject an aud claim for another authorization server', async () => {
      const assertion = await mintIdJag({ claims: { aud: 'https://other-as.example.org' } });
      await expectAssertionRejection(
        assertion,
        'The assertion audience does not match this authorization server',
      );
    });

    // draft §4.4.1: 配列 aud は要素数 1 のみ
    it('should reject an aud array with more than one element', async () => {
      const assertion = await mintIdJag({
        claims: { aud: [ISSUER, 'https://other-as.example.org'] },
      });
      await expectAssertionRejection(
        assertion,
        'The assertion audience does not match this authorization server',
      );
    });

    it('should reject an expired assertion', async () => {
      const assertion = await mintIdJag({ claims: { exp: NOW_SECONDS - 120 } });
      await expectAssertionRejection(assertion, 'The assertion has expired');
    });

    it('should reject a missing exp claim', async () => {
      const assertion = await mintIdJag({ claims: { exp: undefined } });
      await expectAssertionRejection(assertion, 'The assertion is missing an exp claim');
    });

    it('should reject an iat claim in the future', async () => {
      const assertion = await mintIdJag({ claims: { iat: NOW_SECONDS + 120 } });
      await expectAssertionRejection(assertion, 'The assertion iat is in the future');
    });

    it('should reject a missing iat claim', async () => {
      const assertion = await mintIdJag({ claims: { iat: undefined } });
      await expectAssertionRejection(assertion, 'The assertion is missing an iat claim');
    });

    it('should reject an nbf claim that has not arrived yet', async () => {
      const assertion = await mintIdJag({ claims: { nbf: NOW_SECONDS + 120 } });
      await expectAssertionRejection(assertion, 'The assertion is not yet valid');
    });

    // draft §3.1: jti は REQUIRED
    it('should reject a missing jti claim', async () => {
      const assertion = await mintIdJag({ claims: { jti: undefined } });
      await expectAssertionRejection(assertion, 'The assertion is missing a jti claim');
    });

    it('should reject a missing sub claim', async () => {
      const assertion = await mintIdJag({ claims: { sub: undefined } });
      await expectAssertionRejection(assertion, 'The assertion is missing a sub claim');
    });

    it('should reject a missing client_id claim', async () => {
      const assertion = await mintIdJag({ claims: { client_id: undefined } });
      await expectAssertionRejection(assertion, 'The assertion is missing a client_id claim');
    });

    // draft §4.4.1: client_id はリクエストを認証したクライアントと一致しなければならない
    it('should reject a client_id claim bound to another client', async () => {
      const assertion = await mintIdJag({ claims: { client_id: 'another-client' } });
      await expectAssertionRejection(
        assertion,
        'The assertion client_id does not match the authenticated client',
      );
    });

    it('should reject a non-string scope claim', async () => {
      const assertion = await mintIdJag({ claims: { scope: ['openid'] } });
      await expectAssertionRejection(assertion, 'The assertion scope claim must be a string');
    });

    it('should reject a resource claim that is neither a string nor a string array', async () => {
      const assertion = await mintIdJag({ claims: { resource: 42 } });
      await expectAssertionRejection(
        assertion,
        'The assertion resource claim must be a string or an array of strings',
      );
    });
  });
});

describe('resolveIdJagGrantScope', () => {
  it('should inherit the assertion scope when no scope is requested', () => {
    expect(resolveIdJagGrantScope(undefined, 'openid profile')).toEqual(['openid', 'profile']);
  });

  // draft §4.4.3 SHOULD NOT: refresh token を発行しないため offline_access は常に落とす
  it('should always drop offline_access from the assertion scope', () => {
    expect(resolveIdJagGrantScope(undefined, 'openid offline_access profile')).toEqual([
      'openid',
      'profile',
    ]);
  });

  it('should narrow to the requested subset', () => {
    expect(resolveIdJagGrantScope('openid', 'openid profile')).toEqual(['openid']);
  });

  it('should return an empty scope when the assertion carries none', () => {
    expect(resolveIdJagGrantScope(undefined, undefined)).toEqual([]);
  });

  it('should reject a requested scope beyond the assertion scope with invalid_scope', () => {
    expect(() => resolveIdJagGrantScope('openid email', 'openid profile')).toThrow(
      new IdJagError('invalid_scope', 'The requested scope exceeds the scope of the assertion'),
    );
  });

  // offline_access は除去済みの集合が上限になるため、要求しても超過扱いになる
  it('should reject a requested offline_access with invalid_scope', () => {
    expect(() => resolveIdJagGrantScope('offline_access', 'openid offline_access')).toThrow(
      new IdJagError('invalid_scope', 'The requested scope exceeds the scope of the assertion'),
    );
  });
});

describe('processIdJagRedemptionRequest', () => {
  it('should derive the grant material from a valid assertion', async () => {
    const assertion = await mintIdJag({
      claims: { resource: 'https://api.example.net/files', auth_time: NOW_SECONDS - 60 },
    });
    await expect(processIdJagRedemptionRequest(redemptionContext(assertion))).resolves.toEqual({
      subject: 'user-1',
      clientId: CLIENT_ID,
      scope: ['openid', 'profile'],
      requestedResources: ['https://api.example.net/files'],
      expiresIn: 3600,
      idpIssuer: IDP_ISSUER,
      jti: 'jag-1',
      authTime: NOW_SECONDS - 60,
    });
  });

  it('should narrow the scope to the requested subset', async () => {
    const assertion = await mintIdJag();
    await expect(
      processIdJagRedemptionRequest(
        redemptionContext(assertion, {
          params: { grant_type: JWT_BEARER_GRANT_TYPE, assertion, scope: 'openid' },
        }),
      ),
    ).resolves.toMatchObject({ scope: ['openid'] });
  });

  it('should reject an unauthorized client before validating the assertion', async () => {
    await expect(
      processIdJagRedemptionRequest(
        redemptionContext('never-validated', {
          client: confidentialClient({ grantTypes: ['authorization_code'] }),
        }),
      ),
    ).rejects.toThrow(
      new IdJagError(
        'unauthorized_client',
        'The client is not authorized to use the jwt-bearer grant type',
      ),
    );
  });

  it('should reject an assertion bound to another client with invalid_grant', async () => {
    const assertion = await mintIdJag({ claims: { client_id: 'another-client' } });
    await expect(processIdJagRedemptionRequest(redemptionContext(assertion))).rejects.toThrow(
      new IdJagError(
        'invalid_grant',
        'The assertion client_id does not match the authenticated client',
      ),
    );
  });

  it('should reject every assertion when no identity provider is trusted', async () => {
    const assertion = await mintIdJag();
    await expect(
      processIdJagRedemptionRequest(redemptionContext(assertion, { identityProviders: [] })),
    ).rejects.toThrow(new IdJagError('invalid_grant', ASSERTION_UNTRUSTED_DESCRIPTION));
  });

  it('should reject a non-positive configuredExpiresIn with a RangeError', async () => {
    const assertion = await mintIdJag();
    await expect(
      processIdJagRedemptionRequest(redemptionContext(assertion, { configuredExpiresIn: 0 })),
    ).rejects.toThrow(RangeError);
  });

  // draft §4.4.3: 同じ ID-JAG は有効期間内なら再提示できる（リプレイ拒否ストアを持たない）
  it('should accept the same assertion presented twice', async () => {
    const assertion = await mintIdJag();
    const first = await processIdJagRedemptionRequest(redemptionContext(assertion));
    const second = await processIdJagRedemptionRequest(redemptionContext(assertion));
    expect(first).toEqual(second);
  });
});
```

### What a fully green suite guarantees

- **Protocol shape**: the issuance response's `token_type: N_A` and `issued_token_type`; the ID-JAG's JOSE header (RS256 / `oauth-id-jag+jwt` / kid) and the full draft §3.1 claim set; a scope-less issuance omitting the scope claim entirely
- **Cross-domain boundary**: issuing to the own issuer and redeeming a self-issued assertion are rejected regardless of what the allow / trust lists say
- **Binding**: issuance from another client's ID Token, redemption of another client's ID-JAG, public clients, and clients without the grant registration are all rejected
- **Oracle elimination**: subject_token failure causes, and untrusted-issuer vs. broken-signature, each collapse to one identical response
- **Replay by design**: re-presenting the same ID-JAG succeeds (the draft §4.4.3 contract) while expiry beyond the leeway is rejected

## CLI integration and the generated-code contribution

`--enable id-jag` adds no endpoint.
Two branches on the token route, a config object, discovery metadata, and conformance tests are added through conditional interpolation; without the flag the output is byte-identical to before (a CLI test pins that no file of the default output mentions the feature at all).
Everything below is quoted from the hono target's generated output; the other frameworks share the same templates through the web-standard conversion and come out equivalent.

### What lands in config.ts

The example client registers both URNs.

```typescript
      // EXPERIMENTAL (ID-JAG draft §4.3 / §4.4): the token-exchange URN lets this
      // confidential client request an ID-JAG for a trusted resource authorization
      // server, and the jwt-bearer URN lets it redeem an ID-JAG issued by a trusted
      // identity provider. Remove either to forbid that half of Cross-App Access.
      grantTypes: ['authorization_code', 'refresh_token', 'urn:ietf:params:oauth:grant-type:token-exchange', 'urn:ietf:params:oauth:grant-type:jwt-bearer'],
```

### What lands in routes/discovery.ts

`grant_types_supported` gains both URNs (the token-exchange URN is advertised for the issuing side even when the token-exchange feature is off), and the two draft §7 metadata entries are merged into the response.
Neither the trusted IdPs nor the allowed audiences are disclosed (draft §9.4 MUST NOT).

```typescript
    grantTypesSupported: ['authorization_code', 'refresh_token', 'urn:ietf:params:oauth:grant-type:token-exchange', 'urn:ietf:params:oauth:grant-type:jwt-bearer', 'urn:ietf:params:oauth:grant-type:device_code'],
```

```typescript
    // EXPERIMENTAL — ID-JAG draft §7.1: this OP can issue an ID-JAG via token
    // exchange (identity-chaining requested token type).
    identity_chaining_requested_token_types_supported: ['urn:ietf:params:oauth:token-type:id-jag'],
    // EXPERIMENTAL — ID-JAG draft §7.2: this OP can process the ID-JAG grant
    // profile on the jwt-bearer grant. Which issuers are actually trusted is
    // local policy and is not disclosed here (draft §9.4).
    authorization_grant_profiles_supported: ['urn:ietf:params:oauth:grant-profile:id-jag'],
```

### What lands in routes/token.ts

First the imports, the config object, and the trusted-IdP JWKS resolution helper.
The fetch target can only come from static configuration. A failed fetch propagates to a 500 rather than `invalid_grant` — the assertion was never evaluated, so blaming the client's grant for an outage on this side would be wrong.

```typescript
import {
  IdJagError,
  JWT_BEARER_GRANT_TYPE,
  matchesIdJagIssuanceRequest,
  processIdJagIssuanceRequest,
  processIdJagRedemptionRequest,
  type IdJagTrustedIdentityProvider,
} from '@maronn-openid-connect/experimental/id-jag';
import type { JwkSet } from '@maronn-openid-connect/core';
```

```typescript
/**
 * EXPERIMENTAL — Cross-App Access (XAA) / ID-JAG settings
 * (draft-ietf-oauth-identity-assertion-authz-grant-04).
 *
 * Issuing side (this OP as the IdP, draft §4.3):
 * - allowedAudiences: resource authorization server issuers this IdP may issue
 *   an ID-JAG for. Empty by default (fail safe): every issuance request is
 *   rejected with invalid_target until you list the peer AS issuers here.
 *   Adding an entry grants that cross-app connection on behalf of every user —
 *   there is no per-user consent screen in this flow.
 * - idJagLifetimeSeconds: ID-JAG lifetime. Keep it short (draft example: 300);
 *   clients are expected to request a fresh one instead of holding it.
 * - allowedScopes: optional cap on the scopes an ID-JAG may carry. undefined
 *   passes the requested scopes through (the resource AS applies its own
 *   policy again on redemption).
 *
 * Consuming side (this OP as the resource authorization server, draft §4.4):
 * - trustedIdentityProviders: the IdPs whose ID-JAGs are accepted on the
 *   jwt-bearer grant. Empty by default (fail safe). Keys come from the inline
 *   `jwks` when present, otherwise from `jwksUri` (fetched and cached below).
 *   Never derive the key source from the assertion itself.
 */
export const idJagConfig = {
  allowedAudiences: [] as string[],
  idJagLifetimeSeconds: 300,
  allowedScopes: undefined as string[] | undefined,
  trustedIdentityProviders: [] as Array<{ issuer: string; jwksUri?: string; jwks?: JwkSet }>,
};

/**
 * EXPERIMENTAL — jwks_uri cache for trusted identity providers.
 *
 * A fetched JWKS is reused for 300 seconds, so a signing-key rotation at the
 * IdP can take up to that long to be picked up (a verification that fails
 * within the window is answered as an untrusted assertion). The fetch target
 * comes exclusively from the static idJagConfig above — never from request or
 * assertion content — which is what keeps this endpoint SSRF-free.
 */
const idJagJwksCache = new Map<string, { jwks: JwkSet; expiresAt: number }>();
const ID_JAG_JWKS_CACHE_TTL_MS = 300_000;

async function resolveTrustedIdentityProviders(): Promise<IdJagTrustedIdentityProvider[]> {
  const resolved: IdJagTrustedIdentityProvider[] = [];
  for (const entry of idJagConfig.trustedIdentityProviders) {
    if (entry.jwks !== undefined) {
      resolved.push({ issuer: entry.issuer, jwks: entry.jwks });
      continue;
    }
    if (entry.jwksUri === undefined) {
      // An entry with neither jwks nor jwksUri can never verify anything; skip
      // it so the assertion is answered with the fixed untrusted description.
      continue;
    }
    const cached = idJagJwksCache.get(entry.jwksUri);
    if (cached !== undefined && cached.expiresAt > Date.now()) {
      resolved.push({ issuer: entry.issuer, jwks: cached.jwks });
      continue;
    }
    // A failed fetch propagates: the generic catch turns it into server_error,
    // which is honest — the assertion was never evaluated, so invalid_grant
    // would wrongly blame the client for an outage on this side.
    const response = await fetch(entry.jwksUri);
    if (!response.ok) {
      throw new Error(`Fetching the JWKS of trusted IdP ${entry.issuer} failed with status ${response.status}`);
    }
    const jwks = (await response.json()) as JwkSet;
    idJagJwksCache.set(entry.jwksUri, { jwks, expiresAt: Date.now() + ID_JAG_JWKS_CACHE_TTL_MS });
    resolved.push({ issuer: entry.issuer, jwks });
  }
  return resolved;
}
```

Inside the handler, the issuance branch sits right after client authentication and before core's `validateGrantTypeSupported`.
It shares the grant_type URN with the token-exchange branch, so it is always placed before it.

```typescript
    // --- EXPERIMENTAL: ID-JAG issuance (Cross-App Access, draft §4.3) ------
    // A token-exchange request whose requested_token_type is the ID-JAG URN.
    // Dispatched right after client authentication and BEFORE the plain
    // token-exchange branch (same grant_type URN) and core's
    // validateGrantTypeSupported. The subject_token must be an ID Token this OP
    // issued to the authenticated client; the result is a signed grant JWT for
    // the resource authorization server named by `audience` — not an access
    // token (the response carries token_type N_A).
    //
    // Backed by @maronn-openid-connect/experimental, whose API is NOT stable: it may change
    // in a breaking way between releases. The underlying specification is an
    // IETF draft (-04) and may itself change. Do not build production code on
    // this without pinning versions.
    if (matchesIdJagIssuanceRequest(params)) {
      const idJagIssuanceConfig = c.get('config');
      // The ID-JAG is signed with a registered RS256 key so the peer AS can
      // verify it against this OP's JWKS endpoint (same key-selection contract
      // as JARM: RS256 is pinned, the active key may be a different alg).
      const idJagSigningKeys = (c.get('signingKeys') as SigningKey[] | undefined) ?? [];
      let idJagSigningKey: SigningKey;
      try {
        idJagSigningKey = selectSigningKeyByAlg(idJagSigningKeys, 'RS256');
      } catch {
        c.header('Cache-Control', 'no-store');
        c.header('Pragma', 'no-cache');
        return c.json(
          { error: 'server_error', error_description: 'No RS256 signing key registered for ID-JAG issuance' },
          500,
        );
      }
      // The subject_token is verified against the same JWKS that id_token_hint
      // uses (the OP's own ID Token signing keys) — draft §4.3.3 requires the
      // assertion's audience to be the authenticated client, which
      // processIdJagIssuanceRequest checks.
      const idJagJwks = await c.get('jwksProvider')();

      const idJagIssuanceResponse = await processIdJagIssuanceRequest({
        params,
        client: tokenClient,
        issuer: idJagIssuanceConfig.issuer,
        jwks: idJagJwks,
        signingKey: idJagSigningKey,
        allowedAudiences: idJagConfig.allowedAudiences,
        allowedScopes: idJagConfig.allowedScopes,
        lifetimeSeconds: idJagConfig.idJagLifetimeSeconds,
      });

      // RFC 6749 §5.1: token responses MUST NOT be cached. The ID-JAG itself is
      // not persisted — it is a self-contained signed grant the peer AS
      // verifies by signature and exp.
      c.header('Cache-Control', 'no-store');
      c.header('Pragma', 'no-cache');
      return c.json(idJagIssuanceResponse);
    }
```

The redemption branch follows. Access-token minting and persistence use the same core parts as the standard token route (`buildAccessTokenAudience` / `buildAccessTokenPayload` / issuer / store), and neither `id_token` nor `refresh_token` is returned.
Each redemption is its own grant, so `grantId` is the token's own `jti` — revoking one issued token must not cascade into tokens from other redemptions of the same (re-presentable) ID-JAG.

```typescript
    // --- EXPERIMENTAL: ID-JAG redemption (Cross-App Access, draft §4.4) ----
    // The jwt-bearer grant (RFC 7523 §2.1). The assertion must be an ID-JAG
    // (typ oauth-id-jag+jwt) issued by one of idJagConfig.trustedIdentityProviders
    // for THIS issuer and for the authenticated client. This OP then issues its
    // own access token — the IdP never mints tokens for this AS.
    //
    // No ID Token is issued (this is not an OIDC authentication flow: the
    // openid scope only grants UserInfo access) and no refresh token is issued
    // (draft §4.4.3 SHOULD NOT — re-presenting the still-valid ID-JAG replaces
    // the refresh token).
    if (params.grant_type === JWT_BEARER_GRANT_TYPE) {
      const idJagRedemptionConfig = c.get('config');
      const idJagIdentityProviders = await resolveTrustedIdentityProviders();

      const idJagGrant = await processIdJagRedemptionRequest({
        params,
        client: tokenClient,
        issuer: idJagRedemptionConfig.issuer,
        identityProviders: idJagIdentityProviders,
        configuredExpiresIn: idJagRedemptionConfig.accessTokenExpiresIn,
      });

      // config / privateKey / keyId are bound further down for the standard
      // grants. This branch reads them on its own so the generated output is
      // unchanged when the feature is off; it returns, so nothing runs twice.
      const idJagTokenIssuer: AccessTokenIssuer =
        idJagRedemptionConfig.accessTokenFormat === 'opaque'
          ? createOpaqueAccessTokenIssuer()
          : createJwtAccessTokenIssuer();

      // Same aud policy as the standard token route: the UserInfo endpoint
      // stays a permanent member (RFC 9068 §3); the ID-JAG's resource claim
      // (RFC 8707) contributes the requested resources.
      const idJagAudience = buildAccessTokenAudience({
        userInfoEndpoint: `${idJagRedemptionConfig.issuer}/userinfo`,
        requested: idJagGrant.requestedResources,
        issuer: idJagRedemptionConfig.issuer,
      });

      const idJagIssuedAt = Math.floor(Date.now() / 1000);
      const idJagAccessTokenPayload = buildAccessTokenPayload({
        issuer: idJagRedemptionConfig.issuer,
        subject: idJagGrant.subject,
        clientId: idJagGrant.clientId,
        scope: idJagGrant.scope,
        audience: idJagAudience,
        expiresIn: idJagGrant.expiresIn,
        issuedAt: idJagIssuedAt,
      });
      const idJagAccessToken = await idJagTokenIssuer.issue({
        payload: idJagAccessTokenPayload,
        privateKey: c.get('privateKey'),
        keyId: c.get('keyId'),
      });

      await accessTokenStore.set(idJagAccessToken, {
        // draft §4.4.1: the ID-JAG's sub is used as the local subject directly
        // (subject resolution by identical sub; JIT provisioning is out of scope).
        sub: idJagGrant.subject,
        clientId: idJagGrant.clientId,
        scope: idJagGrant.scope,
        expiresAt: idJagIssuedAt + idJagGrant.expiresIn,
        // Each redemption is its own grant: revoking one issued token must not
        // affect tokens from other redemptions of the same (re-presentable)
        // ID-JAG, so the payload's own jti doubles as the grant id.
        grantId: idJagAccessTokenPayload.jti,
        iat: idJagIssuedAt,
        nbf: idJagIssuedAt,
        audience: idJagAudience,
        issuer: idJagRedemptionConfig.issuer,
        jti: idJagAccessTokenPayload.jti,
      });

      // RFC 6749 §5.1: token responses MUST NOT be cached.
      c.header('Cache-Control', 'no-store');
      c.header('Pragma', 'no-cache');
      return c.json({
        access_token: idJagAccessToken,
        token_type: 'Bearer' as const,
        expires_in: idJagGrant.expiresIn,
        scope: idJagGrant.scope.join(' '),
      });
    }
```

The catch chain gains the `IdJagError` branch.

```typescript
    if (error instanceof IdJagError) {
      // ID-JAG errors use the RFC 6749 §5.2 shape and are always 400 — a 401
      // can only come from client authentication, which runs before both
      // branches and throws core's TokenError. Issuance failures map to
      // invalid_request / invalid_target / invalid_scope / unauthorized_client
      // (RFC 8693 §2.2.2); assertion failures on redemption map to
      // invalid_grant (RFC 7521 §4.1).
      c.header('Cache-Control', 'no-store');
      c.header('Pragma', 'no-cache');
      return c.json(
        { error: error.code, error_description: error.errorDescription },
        error.statusCode,
      );
    }
```

Only when `--enable id-jag` is used without token-exchange does an extra fallback branch appear right after the issuance branch, telling clients that this OP's token exchange exists solely to issue ID-JAGs (so the discovery advertisement of the exchange grant never dead-ends in `unsupported_grant_type`). This sample enables token-exchange as well, so the branch is not generated here.

### What lands in conformance.test.ts

The 22 contract tests generate a fake external-IdP key inside the suite and trust-list it as an inline JWKS (no network fetch).
Even the joined case — an ID-JAG this OP issued being refused at this same OP — is pinned over real HTTP.

```typescript
  // EXPERIMENTAL — Cross-App Access / ID-JAG
  // (draft-ietf-oauth-identity-assertion-authz-grant-04). Generated because this
  // provider was created with --enable id-jag. These tests pin the contract the
  // repository guarantees for both halves of XAA: issuing an ID-JAG on the
  // token-exchange grant (draft §4.3) and redeeming one on the jwt-bearer grant
  // (draft §4.4). Change the behavior and they fail, which is how a customized
  // OP learns it drifted.
  describe('Cross-App Access / ID-JAG (draft-ietf-oauth-identity-assertion-authz-grant)', () => {
    // RFC 7636 Appendix B example PKCE pair (verifier -> its S256 challenge).
    const XAA_PKCE_VERIFIER = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
    const XAA_PKCE_CHALLENGE_S256 = 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM';
    const XAA_EXCHANGE_GRANT_TYPE = 'urn:ietf:params:oauth:grant-type:token-exchange';
    const XAA_JWT_BEARER_GRANT_TYPE = 'urn:ietf:params:oauth:grant-type:jwt-bearer';
    const XAA_ID_JAG_TOKEN_TYPE = 'urn:ietf:params:oauth:token-type:id-jag';
    const XAA_ID_TOKEN_TYPE = 'urn:ietf:params:oauth:token-type:id_token';
    // This OP's own issuer (createApp above runs on the default config).
    const XAA_OWN_ISSUER = 'http://localhost:3000';
    // The peer resource authorization server ID-JAGs are issued for.
    const XAA_PEER_AS_ISSUER = 'https://peer-as.conformance.example';
    // The fake external IdP whose signed ID-JAGs this OP redeems.
    const XAA_TRUSTED_IDP_ISSUER = 'https://trusted-idp.conformance.example';
    // Every unusable subject_token is rejected with this one description, and
    // an untrusted issuer is indistinguishable from a broken signature, so the
    // responses cannot be used as an existence / trust-list oracle.
    const XAA_SUBJECT_INVALID_DESCRIPTION = 'The provided subject_token is not valid';
    const XAA_ASSERTION_UNTRUSTED_DESCRIPTION =
      'The assertion issuer is not trusted or the assertion signature is invalid';

    let externalIdpPrivateKey: CryptoKey;
    let externalIdpJwk: Awaited<ReturnType<typeof exportPublicJwk>>;

    beforeAll(async () => {
      // The fake external IdP: its public JWK is trust-listed inline by the
      // tests below, so no jwks_uri fetch happens inside this suite.
      const externalIdpKeyPair = await crypto.subtle.generateKey(
        { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
        true,
        ['sign', 'verify'],
      );
      externalIdpPrivateKey = externalIdpKeyPair.privateKey;
      externalIdpJwk = await exportPublicJwk(externalIdpKeyPair.publicKey, 'external-idp-key');
    });

    // Pure helpers: they fetch, sign and parse only. Every assertion lives in an it().
    function xaaRelativeFrom(location: string | null): string {
      const url = new URL(location ?? '', 'http://localhost');
      return url.pathname + url.search;
    }

    function xaaCsrfFrom(html: string): string {
      return html.match(/name="csrf_token" value="([^"]+)"/)?.[1] ?? '';
    }

    function xaaB64Url(bytes: Uint8Array): string {
      let binary = '';
      for (const byte of bytes) binary += String.fromCharCode(byte);
      return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
    }

    function xaaB64UrlJson(value: Record<string, unknown>): string {
      return xaaB64Url(new TextEncoder().encode(JSON.stringify(value)));
    }

    function xaaDecodeJwtSegment(segment: string): Record<string, unknown> {
      const base64 = segment.replace(/-/g, '+').replace(/_/g, '/');
      const padded = base64 + '='.repeat((4 - (base64.length % 4)) % 4);
      return JSON.parse(atob(padded)) as Record<string, unknown>;
    }

    function postXaaToken(
      fields: Record<string, string>,
      path = '/token',
      base: Record<string, string> = {},
    ): Promise<Response> {
      return app.request(path, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({ ...base, ...fields }).toString(),
      });
    }

    // Drive authorize -> login -> consent over HTTP and hand back the code. No
    // assertions and no branching here: the flow contract lives in the it()s.
    async function xaaAuthorizeFlow(clientId: string, scope: string): Promise<string> {
      const authorizeUrl =
        '/authorize?response_type=code&client_id=' + clientId +
        '&redirect_uri=' + encodeURIComponent(REDIRECT_URI) +
        '&scope=' + encodeURIComponent(scope) +
        '&state=xaa-state&nonce=xaa-nonce' +
        '&code_challenge=' + XAA_PKCE_CHALLENGE_S256 + '&code_challenge_method=S256';

      const authorizeRes = await app.request(authorizeUrl);
      const loginPath = xaaRelativeFrom(authorizeRes.headers.get('Location'));
      // Carry forward whatever cookie /authorize set, exactly as a browser would
      // (with --enable transaction-binding it is the binding secret).
      const bindingCookie = (authorizeRes.headers.get('Set-Cookie') ?? '').split(';')[0] ?? '';
      const transactionId =
        new URL(loginPath, 'http://localhost').searchParams.get('transaction_id') ?? '';

      const loginGet = await app.request(loginPath, { headers: { Cookie: bindingCookie } });
      const loginRes = await app.request('/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded', Cookie: bindingCookie },
        body: new URLSearchParams({
          transaction_id: transactionId,
          csrf_token: xaaCsrfFrom(await loginGet.text()),
          username: 'testuser',
          password: 'password',
        }).toString(),
      });
      const consentPath = xaaRelativeFrom(loginRes.headers.get('Location'));

      const consentGet = await app.request(consentPath, { headers: { Cookie: bindingCookie } });
      const consentRes = await app.request('/consent', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded', Cookie: bindingCookie },
        body: new URLSearchParams({
          transaction_id: transactionId,
          csrf_token: xaaCsrfFrom(await consentGet.text()),
          action: 'approve',
        }).toString(),
      });
      const callback = new URL(consentRes.headers.get('Location') ?? '', 'http://localhost');
      return callback.searchParams.get('code') ?? '';
    }

    // The identity assertion the issuance half consumes: an ID Token from the
    // ordinary Authorization Code Flow of the given client.
    async function xaaCodeFlowTokens(clientId: string): Promise<Record<string, string>> {
      const code = await xaaAuthorizeFlow(clientId, 'openid profile');
      const res = await postXaaToken({
        client_id: clientId,
        client_secret: 's',
        grant_type: 'authorization_code',
        code,
        redirect_uri: REDIRECT_URI,
        code_verifier: XAA_PKCE_VERIFIER,
      });
      return (await res.json()) as Record<string, string>;
    }

    function issuanceRequest(overrides: Record<string, string> = {}): Promise<Response> {
      return postXaaToken(overrides, '/token', {
        client_id: 'c-idjag',
        client_secret: 's',
        grant_type: XAA_EXCHANGE_GRANT_TYPE,
        requested_token_type: XAA_ID_JAG_TOKEN_TYPE,
        subject_token_type: XAA_ID_TOKEN_TYPE,
        audience: XAA_PEER_AS_ISSUER,
        scope: 'openid profile',
      });
    }

    function redeemRequest(
      overrides: Record<string, string> = {},
      clientId = 'c-idjag',
    ): Promise<Response> {
      return postXaaToken(overrides, '/token', {
        client_id: clientId,
        client_secret: 's',
        grant_type: XAA_JWT_BEARER_GRANT_TYPE,
      });
    }

    // Sign an ID-JAG as the fake external IdP. An override set to undefined
    // removes the member (JSON.stringify drops undefined values).
    async function mintExternalIdJag(
      claims: Record<string, unknown>,
      header: Record<string, unknown> = {},
    ): Promise<string> {
      const nowSeconds = Math.floor(Date.now() / 1000);
      const encodedHeader = xaaB64UrlJson({
        alg: 'RS256',
        typ: 'oauth-id-jag+jwt',
        kid: 'external-idp-key',
        ...header,
      });
      const encodedPayload = xaaB64UrlJson({
        iss: XAA_TRUSTED_IDP_ISSUER,
        sub: 'testuser',
        aud: XAA_OWN_ISSUER,
        client_id: 'c-idjag',
        jti: 'conformance-jag',
        exp: nowSeconds + 300,
        iat: nowSeconds,
        scope: 'openid profile offline_access',
        ...claims,
      });
      const signingInput = encodedHeader + '.' + encodedPayload;
      const signature = await crypto.subtle.sign(
        'RSASSA-PKCS1-v1_5',
        externalIdpPrivateKey,
        new TextEncoder().encode(signingInput),
      );
      return signingInput + '.' + xaaB64Url(new Uint8Array(signature));
    }

    // Config helpers: flip the generated allow lists for one call and always
    // restore them, so the fail-safe empty defaults stay pinned by other tests.
    async function withIssuanceAudience<T>(fn: () => Promise<T>): Promise<T> {
      idJagConfig.allowedAudiences = [XAA_PEER_AS_ISSUER];
      try {
        return await fn();
      } finally {
        idJagConfig.allowedAudiences = [];
      }
    }

    async function withTrustedIdp<T>(fn: () => Promise<T>): Promise<T> {
      idJagConfig.trustedIdentityProviders = [
        { issuer: XAA_TRUSTED_IDP_ISSUER, jwks: { keys: [externalIdpJwk] } },
      ];
      try {
        return await fn();
      } finally {
        idJagConfig.trustedIdentityProviders = [];
      }
    }

    describe('ID-JAG issuance (draft §4.3)', () => {
      it('should issue an ID-JAG with the §3.1 claims and the §4.3.4 response members', async () => {
        const idToken = (await xaaCodeFlowTokens('c-idjag')).id_token;
        const res = await withIssuanceAudience(() =>
          issuanceRequest({ subject_token: idToken }),
        );
        const body = (await res.json()) as Record<string, unknown>;

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
        expect(body.issued_token_type).toBe(XAA_ID_JAG_TOKEN_TYPE);
        // draft §4.3.4: the issued grant is NOT an access token.
        expect(body.token_type).toBe('N_A');
        expect(body.expires_in).toBe(300);
        expect(body.scope).toBe('openid profile');

        const segments = String(body.access_token).split('.');
        const header = xaaDecodeJwtSegment(segments[0] ?? '');
        const claims = xaaDecodeJwtSegment(segments[1] ?? '');
        // draft §3.1 / RFC 8725 §3.11: explicit typing, RS256, published kid.
        expect(header.typ).toBe('oauth-id-jag+jwt');
        expect(header.alg).toBe('RS256');
        expect(header.kid).toBe('test-key');
        expect(claims.iss).toBe(XAA_OWN_ISSUER);
        expect(claims.sub).toBe('testuser');
        expect(claims.aud).toBe(XAA_PEER_AS_ISSUER);
        expect(claims.client_id).toBe('c-idjag');
        expect(claims.scope).toBe('openid profile');
        expect(typeof claims.jti).toBe('string');
        expect((claims.exp as number) - (claims.iat as number)).toBe(300);
      });

      it('should omit the scope claim and return an empty scope when none is requested', async () => {
        const idToken = (await xaaCodeFlowTokens('c-idjag')).id_token;
        const res = await withIssuanceAudience(() =>
          issuanceRequest({ subject_token: idToken, scope: '' }),
        );
        const body = (await res.json()) as Record<string, unknown>;

        expect(res.status).toBe(200);
        expect(body.scope).toBe('');
        const claims = xaaDecodeJwtSegment(String(body.access_token).split('.')[1] ?? '');
        expect('scope' in claims).toBe(false);
      });

      it('should reject an audience outside the allow list with invalid_target', async () => {
        const idToken = (await xaaCodeFlowTokens('c-idjag')).id_token;
        // The generated default allow list is empty (fail safe), so the same
        // audience that succeeds above is rejected without the config flip.
        const res = await issuanceRequest({ subject_token: idToken });

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_target',
          error_description: 'The requested audience is not allowed for ID-JAG issuance',
        });
      });

      it('should reject this issuer itself as audience with invalid_target', async () => {
        const idToken = (await xaaCodeFlowTokens('c-idjag')).id_token;
        // draft §9.3: cross-domain only — even an allow-listed own issuer is refused.
        idJagConfig.allowedAudiences = [XAA_OWN_ISSUER];
        try {
          const res = await issuanceRequest({ subject_token: idToken, audience: XAA_OWN_ISSUER });

          expect(res.status).toBe(400);
          expect(await res.json()).toEqual({
            error: 'invalid_target',
            error_description:
              'The requested audience must belong to a different trust domain than this authorization server',
          });
        } finally {
          idJagConfig.allowedAudiences = [];
        }
      });

      it('should reject an ID Token issued to another client with the fixed description', async () => {
        // draft §4.3.3: the assertion audience must be the authenticated client.
        const foreignIdToken = (await xaaCodeFlowTokens('c-conf')).id_token;
        const res = await withIssuanceAudience(() =>
          issuanceRequest({ subject_token: foreignIdToken }),
        );

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_request',
          error_description: XAA_SUBJECT_INVALID_DESCRIPTION,
        });
      });

      it('should reject an access token presented as the subject with the same fixed description', async () => {
        const accessToken = (await xaaCodeFlowTokens('c-idjag')).access_token;
        const res = await withIssuanceAudience(() =>
          issuanceRequest({ subject_token: accessToken }),
        );

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_request',
          error_description: XAA_SUBJECT_INVALID_DESCRIPTION,
        });
      });

      it('should reject a saml2 subject_token_type with invalid_request', async () => {
        const res = await issuanceRequest({
          subject_token: 'unused',
          subject_token_type: 'urn:ietf:params:oauth:token-type:saml2',
        });

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_request',
          error_description:
            'Unsupported subject_token_type for ID-JAG issuance. Only urn:ietf:params:oauth:token-type:id_token is supported.',
        });
      });

      it('should reject an actor_token with invalid_request', async () => {
        const res = await issuanceRequest({
          subject_token: 'unused',
          actor_token: 'unused',
          actor_token_type: XAA_ID_TOKEN_TYPE,
        });

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_request',
          error_description: 'actor_token is not supported for ID-JAG issuance',
        });
      });

      it('should reject a client without the token-exchange grant with unauthorized_client', async () => {
        // c-conf authenticates fine (client_secret_post) but never registered
        // the exchange URN.
        const res = await issuanceRequest({
          subject_token: 'unused',
          client_id: 'c-conf',
        });

        expect(res.status).toBe(400);
        expect(((await res.json()) as Record<string, unknown>).error).toBe('unauthorized_client');
      });

      it('should reject a public client with unauthorized_client', async () => {
        const res = await postXaaToken({
          client_id: 'c-public-idjag',
          grant_type: XAA_EXCHANGE_GRANT_TYPE,
          requested_token_type: XAA_ID_JAG_TOKEN_TYPE,
          subject_token: 'unused',
          subject_token_type: XAA_ID_TOKEN_TYPE,
          audience: XAA_PEER_AS_ISSUER,
        });

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'unauthorized_client',
          error_description: 'Public clients are not allowed to request an ID-JAG',
        });
      });

      it('should cap the issued scopes at idJagConfig.allowedScopes with invalid_scope', async () => {
        const idToken = (await xaaCodeFlowTokens('c-idjag')).id_token;
        idJagConfig.allowedScopes = ['openid'];
        try {
          const res = await withIssuanceAudience(() =>
            issuanceRequest({ subject_token: idToken, scope: 'openid profile' }),
          );

          expect(res.status).toBe(400);
          expect(await res.json()).toEqual({
            error: 'invalid_scope',
            error_description: 'The requested scope exceeds the scopes allowed for ID-JAG issuance',
          });
        } finally {
          idJagConfig.allowedScopes = undefined;
        }
      });
    });

    describe('ID-JAG redemption (draft §4.4)', () => {
      it('should redeem a trusted ID-JAG for an access token of this AS', async () => {
        const assertion = await mintExternalIdJag({});
        const res = await withTrustedIdp(() => redeemRequest({ assertion }));
        const body = (await res.json()) as Record<string, unknown>;

        expect(res.status).toBe(200);
        expect(res.headers.get('Cache-Control')).toBe('no-store');
        expect(res.headers.get('Pragma')).toBe('no-cache');
        // draft §4.4.2 / §4.4.3: a plain token response — no refresh_token (the
        // re-presentable ID-JAG replaces it) and no id_token (this is not an
        // OIDC authentication flow).
        expect(Object.keys(body).sort()).toEqual([
          'access_token',
          'expires_in',
          'scope',
          'token_type',
        ]);
        expect(body.token_type).toBe('Bearer');
        expect(body.expires_in).toBe(3600);
        // offline_access is always dropped: no refresh token is ever issued here.
        expect(body.scope).toBe('openid profile');

        const claims = xaaDecodeJwtSegment(String(body.access_token).split('.')[1] ?? '');
        // The access token is this AS's own (draft §1: the IdP never mints
        // tokens for the resource AS), for the ID-JAG's subject and client.
        expect(claims.iss).toBe(XAA_OWN_ISSUER);
        expect(claims.sub).toBe('testuser');
        expect(claims.client_id).toBe('c-idjag');
      });

      it('should let the redeemed access token pass the UserInfo endpoint', async () => {
        const assertion = await mintExternalIdJag({});
        const redeemed = await withTrustedIdp(() => redeemRequest({ assertion }));
        const accessToken = ((await redeemed.json()) as Record<string, string>).access_token;

        const res = await app.request('/userinfo', {
          headers: { Authorization: 'Bearer ' + accessToken },
        });
        const body = (await res.json()) as Record<string, unknown>;

        expect(res.status).toBe(200);
        expect(body.sub).toBe('testuser');
      });

      it('should report a redeemed access token active with the ID-JAG subject and client', async () => {
        const assertion = await mintExternalIdJag({});
        const redeemed = await withTrustedIdp(() => redeemRequest({ assertion }));
        const redeemedBody = (await redeemed.json()) as Record<string, string>;

        const res = await postXaaToken({}, '/introspect', {
          token: redeemedBody.access_token,
          client_id: 'c-idjag',
          client_secret: 's',
        });
        const body = (await res.json()) as Record<string, unknown>;

        expect(res.status).toBe(200);
        expect(body.active).toBe(true);
        // draft §4.4.1: the ID-JAG sub becomes the local subject directly, and
        // the token is bound to the client that redeemed the grant.
        expect(body.sub).toBe('testuser');
        expect(body.client_id).toBe('c-idjag');
        expect(body.scope).toBe('openid profile');
      });

      it('should accept the same ID-JAG again while it is valid', async () => {
        // draft §4.4.3: re-presenting the still-valid grant replaces the refresh
        // token, so a second redemption MUST succeed (no jti replay store).
        const assertion = await mintExternalIdJag({});
        const first = await withTrustedIdp(() => redeemRequest({ assertion }));
        const second = await withTrustedIdp(() => redeemRequest({ assertion }));

        expect(first.status).toBe(200);
        expect(second.status).toBe(200);
      });

      it('should answer an untrusted issuer and a broken signature identically', async () => {
        const untrusted = await mintExternalIdJag({ iss: 'https://unknown-idp.example.org' });
        const [h, p] = (await mintExternalIdJag({})).split('.');
        const tampered = h + '.' + p + '.AAAA';

        const untrustedRes = await withTrustedIdp(() => redeemRequest({ assertion: untrusted }));
        const tamperedRes = await withTrustedIdp(() => redeemRequest({ assertion: tampered }));
        const expected = {
          error: 'invalid_grant',
          error_description: XAA_ASSERTION_UNTRUSTED_DESCRIPTION,
        };

        expect(untrustedRes.status).toBe(400);
        expect(tamperedRes.status).toBe(400);
        expect(await untrustedRes.json()).toEqual(expected);
        expect(await tamperedRes.json()).toEqual(expected);
      });

      it('should reject every assertion when no identity provider is trusted', async () => {
        // The generated default trust list is empty (fail safe).
        const assertion = await mintExternalIdJag({});
        const res = await redeemRequest({ assertion });

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_grant',
          error_description: XAA_ASSERTION_UNTRUSTED_DESCRIPTION,
        });
      });

      it('should reject an ID-JAG addressed to another authorization server with invalid_grant', async () => {
        const assertion = await mintExternalIdJag({ aud: 'https://other-as.example.org' });
        const res = await withTrustedIdp(() => redeemRequest({ assertion }));

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_grant',
          error_description: 'The assertion audience does not match this authorization server',
        });
      });

      it('should reject an ID-JAG bound to another client with invalid_grant', async () => {
        // draft §4.4.1 client continuity: c-idjag-other authenticates correctly
        // but presents a grant that names c-idjag.
        const assertion = await mintExternalIdJag({});
        const res = await withTrustedIdp(() => redeemRequest({ assertion }, 'c-idjag-other'));

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_grant',
          error_description: 'The assertion client_id does not match the authenticated client',
        });
      });

      it('should reject a JWT without the ID-JAG typ with invalid_grant', async () => {
        // RFC 8725 §3.11 explicit typing: an ID Token (typ JWT) can never be
        // redeemed as an ID-JAG even with otherwise plausible claims.
        const assertion = await mintExternalIdJag({}, { typ: 'JWT' });
        const res = await withTrustedIdp(() => redeemRequest({ assertion }));

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_grant',
          error_description: 'The assertion typ must be oauth-id-jag+jwt',
        });
      });

      it('should reject an expired ID-JAG with invalid_grant', async () => {
        const nowSeconds = Math.floor(Date.now() / 1000);
        const assertion = await mintExternalIdJag({ exp: nowSeconds - 120, iat: nowSeconds - 400 });
        const res = await withTrustedIdp(() => redeemRequest({ assertion }));

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_grant',
          error_description: 'The assertion has expired',
        });
      });

      it('should reject a client without the jwt-bearer grant with unauthorized_client', async () => {
        // c-conf authenticates fine (client_secret_post) but never registered
        // the jwt-bearer URN.
        const res = await redeemRequest({ assertion: 'unused', client_id: 'c-conf' });

        expect(res.status).toBe(400);
        expect(((await res.json()) as Record<string, unknown>).error).toBe('unauthorized_client');
      });

      it('should reject a public client with unauthorized_client', async () => {
        const res = await postXaaToken({
          client_id: 'c-public-idjag',
          grant_type: XAA_JWT_BEARER_GRANT_TYPE,
          assertion: 'unused',
        });

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'unauthorized_client',
          error_description: 'Public clients are not allowed to use the jwt-bearer grant type',
        });
      });

      it('should refuse to redeem an ID-JAG this authorization server issued itself', async () => {
        // draft §9.3: the full chain — a real ID-JAG issued by this OP (for the
        // peer AS) must not be exchangeable for this OP's own access token,
        // whatever the trust list says.
        const idToken = (await xaaCodeFlowTokens('c-idjag')).id_token;
        const issued = await withIssuanceAudience(() =>
          issuanceRequest({ subject_token: idToken }),
        );
        const selfIssuedJag = ((await issued.json()) as Record<string, string>).access_token;

        const res = await withTrustedIdp(() => redeemRequest({ assertion: selfIssuedJag }));

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_grant',
          error_description: 'An assertion issued by this authorization server cannot be redeemed here',
        });
      });
    });

    describe('Discovery advertisement (draft §7)', () => {
      it('should advertise both XAA grant types and the profile metadata', async () => {
        const res = await app.request('/.well-known/openid-configuration');
        const metadata = (await res.json()) as Record<string, unknown>;
        const grantTypes = metadata.grant_types_supported as string[];

        expect(grantTypes.includes(XAA_EXCHANGE_GRANT_TYPE)).toBe(true);
        expect(grantTypes.includes(XAA_JWT_BEARER_GRANT_TYPE)).toBe(true);
        // draft §7.1 / §7.2: profile support only — the trusted-IdP list and the
        // audience allow list are deliberately NOT disclosed (draft §9.4).
        expect(metadata.identity_chaining_requested_token_types_supported).toEqual([
          'urn:ietf:params:oauth:token-type:id-jag',
        ]);
        expect(metadata.authorization_grant_profiles_supported).toEqual([
          'urn:ietf:params:oauth:grant-profile:id-jag',
        ]);
      });
    });
  });
```

### Differences on the other frameworks

express / fastify / nextjs share the hono token-route template through the web-standard conversion, so the branches are identical (Next.js only drops the extensions of relative imports).
The conformance block is the same function interpolated by both templates.

### Sample and E2E wiring

The hono-cloudflare sample's hand-written entry (`src/app.ts`) overrides `idJagConfig` from environment variables, so the two-instance trust relationship can be assembled with env alone.

```typescript
// EXPERIMENTAL (Cross-App Access / ID-JAG): wire the trust configuration from
// env vars so two instances of this sample can play the IdP and the resource
// authorization server against each other (tests/e2e does exactly that).
// With the vars unset the generated fail-safe defaults stay: no ID-JAG is
// issued and none is accepted.
const xaaAllowedAudiences = (bindings.XAA_ALLOWED_AUDIENCES ?? '')
  .split(',')
  .map((value) => value.trim())
  .filter((value) => value.length > 0);
if (xaaAllowedAudiences.length > 0) {
  idJagConfig.allowedAudiences = xaaAllowedAudiences;
}
if (bindings.XAA_TRUSTED_IDP_ISSUER) {
  idJagConfig.trustedIdentityProviders = [
    {
      issuer: bindings.XAA_TRUSTED_IDP_ISSUER,
      jwksUri:
        bindings.XAA_TRUSTED_IDP_JWKS_URI ||
        `${bindings.XAA_TRUSTED_IDP_ISSUER}/.well-known/jwks.json`,
    },
  ];
}
```

## The E2E test, in full

The E2E setup adds a second sample-OP instance (the resource AS role — its own port, issuer, and persistence path) to the Playwright webServer list, hands the first instance (the IdP role) `XAA_ALLOWED_AUDIENCES`, and the second `XAA_TRUSTED_IDP_ISSUER` / `XAA_TRUSTED_IDP_JWKS_URI`.
The consuming side really fetches the IdP's JWKS endpoint to verify signatures, so key distribution takes the production path.
The spec completes SSO in a real browser to obtain the ID Token, then performs issuance and redemption over the back channel.
Against a sample OP generated without id-jag, the spec skips itself on the discovery probe.

```typescript
import { expect, test, type APIRequestContext } from '@playwright/test';

const host = process.env.E2E_HOST ?? '127.0.0.1';
const clientPort = Number(process.env.E2E_CLIENT_PORT ?? '3020');
const xaaOpPort = Number(process.env.E2E_XAA_OP_PORT ?? '3040');
const clientBaseURL =
  process.env.E2E_CLIENT_BASE_URL ?? `http://${host}:${clientPort}`;
const xaaIssuer = process.env.E2E_XAA_ISSUER ?? `http://${host}:${xaaOpPort}`;
const clientId = 'e2e-client';
const clientSecret = 'e2e-client-secret';

const EXCHANGE_GRANT_TYPE = 'urn:ietf:params:oauth:grant-type:token-exchange';
const JWT_BEARER_GRANT_TYPE = 'urn:ietf:params:oauth:grant-type:jwt-bearer';
const ID_JAG_TOKEN_TYPE = 'urn:ietf:params:oauth:token-type:id-jag';
const ID_TOKEN_TYPE = 'urn:ietf:params:oauth:token-type:id_token';
const ID_JAG_GRANT_PROFILE = 'urn:ietf:params:oauth:grant-profile:id-jag';

/**
 * EXPERIMENTAL — Cross-App Access / ID-JAG
 * (draft-ietf-oauth-identity-assertion-authz-grant-04).
 *
 * Two OP instances of the sample play the two trust domains: the first
 * (baseURL) is the IdP that issues ID-JAGs, the second (xaaIssuer) is the
 * resource authorization server that redeems them. The second instance only
 * starts for the hono sample, and only an OP generated with --enable id-jag
 * advertises the profile — every test here skips itself otherwise, so the
 * shared spec suite stays green across all sample OPs.
 */
test.describe('Cross-App Access / ID-JAG (draft-ietf-oauth-identity-assertion-authz-grant)', () => {
  test('should walk the full XAA chain: SSO, ID-JAG issuance, redemption, API access', async ({
    page,
    request,
    baseURL,
  }) => {
    const idpIssuer = requireBaseUrl(baseURL);
    test.skip(!(await supportsXaa(request, idpIssuer)), XAA_SKIP_REASON);

    // (1) SSO: the ordinary Authorization Code Flow in a real browser yields
    // the Identity Assertion (ID Token) at the IdP.
    const idToken = await obtainIdToken(page);

    // (2) Token Exchange at the IdP (draft §4.3): trade the ID Token for an
    // ID-JAG addressed to the second OP's trust domain.
    const exchangeRes = await request.post(`${idpIssuer}/token`, {
      form: {
        grant_type: EXCHANGE_GRANT_TYPE,
        requested_token_type: ID_JAG_TOKEN_TYPE,
        subject_token: idToken,
        subject_token_type: ID_TOKEN_TYPE,
        audience: xaaIssuer,
        scope: 'openid profile',
        client_id: clientId,
        client_secret: clientSecret,
      },
    });
    expect(exchangeRes.status()).toBe(200);
    const exchangeBody = (await exchangeRes.json()) as Record<string, unknown>;
    // draft §4.3.4: the ID-JAG travels in access_token for historical reasons,
    // but token_type N_A says it is NOT an access token.
    expect(exchangeBody.issued_token_type).toBe(ID_JAG_TOKEN_TYPE);
    expect(exchangeBody.token_type).toBe('N_A');
    expect(exchangeBody.expires_in).toBe(300);
    expect(exchangeBody.scope).toBe('openid profile');

    const idJag = String(exchangeBody.access_token);
    const jagHeader = decodeJwtSegment(idJag.split('.')[0] ?? '');
    const jagClaims = decodeJwtSegment(idJag.split('.')[1] ?? '');
    // draft §3.1: explicit typing plus the cross-domain addressing.
    expect(jagHeader.typ).toBe('oauth-id-jag+jwt');
    expect(jagHeader.alg).toBe('RS256');
    expect(jagHeader.kid).toBe('e2e-rs256-key');
    expect(jagClaims.iss).toBe(idpIssuer);
    expect(jagClaims.aud).toBe(xaaIssuer);
    expect(jagClaims.sub).toBe('testuser');
    expect(jagClaims.client_id).toBe(clientId);

    // (3) Redemption at the resource AS (draft §4.4): the jwt-bearer grant.
    // The second OP verifies the signature against the IdP's live JWKS.
    const redeemRes = await request.post(`${xaaIssuer}/token`, {
      form: {
        grant_type: JWT_BEARER_GRANT_TYPE,
        assertion: idJag,
        client_id: clientId,
        client_secret: clientSecret,
      },
    });
    expect(redeemRes.status()).toBe(200);
    const redeemBody = (await redeemRes.json()) as Record<string, unknown>;
    // draft §4.4.2 / §4.4.3: a plain token response — no refresh_token (the
    // re-presentable ID-JAG replaces it) and no id_token.
    expect(Object.keys(redeemBody).sort()).toEqual([
      'access_token',
      'expires_in',
      'scope',
      'token_type',
    ]);
    expect(redeemBody.token_type).toBe('Bearer');
    expect(redeemBody.scope).toBe('openid profile');

    // The access token is minted by the resource AS itself, not by the IdP.
    const accessTokenClaims = decodeJwtSegment(
      String(redeemBody.access_token).split('.')[1] ?? '',
    );
    expect(accessTokenClaims.iss).toBe(xaaIssuer);
    expect(accessTokenClaims.sub).toBe('testuser');
    expect(accessTokenClaims.client_id).toBe(clientId);

    // (4) API access in the second trust domain: the resource AS resolves the
    // ID-JAG subject to its own local user of the same sub.
    const userInfoRes = await request.get(`${xaaIssuer}/userinfo`, {
      headers: { Authorization: `Bearer ${String(redeemBody.access_token)}` },
    });
    expect(userInfoRes.status()).toBe(200);
    expect(((await userInfoRes.json()) as { sub: string }).sub).toBe('testuser');
  });

  test('should advertise the XAA metadata on both trust domains', async ({
    request,
    baseURL,
  }) => {
    const idpIssuer = requireBaseUrl(baseURL);
    test.skip(!(await supportsXaa(request, idpIssuer)), XAA_SKIP_REASON);

    const idpMetadata = await discovery(request, idpIssuer);
    const asMetadata = await discovery(request, xaaIssuer);

    // draft §7.1: the IdP side announces the identity-chaining token type.
    expect(idpMetadata.identity_chaining_requested_token_types_supported).toEqual([
      ID_JAG_TOKEN_TYPE,
    ]);
    // draft §7.2: the resource AS side announces the grant profile and, with
    // it, MUST announce the jwt-bearer grant.
    expect(asMetadata.authorization_grant_profiles_supported).toEqual([ID_JAG_GRANT_PROFILE]);
    expect((asMetadata.grant_types_supported as string[]).includes(JWT_BEARER_GRANT_TYPE)).toBe(
      true,
    );
  });

  test('should refuse to redeem the ID-JAG at the IdP that issued it', async ({
    page,
    request,
    baseURL,
  }) => {
    const idpIssuer = requireBaseUrl(baseURL);
    test.skip(!(await supportsXaa(request, idpIssuer)), XAA_SKIP_REASON);

    const idJag = await obtainIdJag(page, request, idpIssuer);

    // draft §9.3: same trust domain — the issuing OP must never turn its own
    // ID-JAG into its own access token, whatever grants the client holds.
    const res = await request.post(`${idpIssuer}/token`, {
      form: {
        grant_type: JWT_BEARER_GRANT_TYPE,
        assertion: idJag,
        client_id: clientId,
        client_secret: clientSecret,
      },
    });

    expect(res.status()).toBe(400);
    expect(await res.json()).toEqual({
      error: 'invalid_grant',
      error_description: 'An assertion issued by this authorization server cannot be redeemed here',
    });
  });

  test('should refuse an ID-JAG presented by a client it does not name', async ({
    page,
    request,
    baseURL,
  }) => {
    const idpIssuer = requireBaseUrl(baseURL);
    test.skip(!(await supportsXaa(request, idpIssuer)), XAA_SKIP_REASON);

    const idJag = await obtainIdJag(page, request, idpIssuer);

    // draft §4.4.1 client continuity: e2e-xaa-other authenticates correctly at
    // the resource AS but presents a grant that names e2e-client.
    const res = await request.post(`${xaaIssuer}/token`, {
      form: {
        grant_type: JWT_BEARER_GRANT_TYPE,
        assertion: idJag,
        client_id: 'e2e-xaa-other',
        client_secret: 'e2e-xaa-other-secret',
      },
    });

    expect(res.status()).toBe(400);
    expect(await res.json()).toEqual({
      error: 'invalid_grant',
      error_description: 'The assertion client_id does not match the authenticated client',
    });
  });

  test('should refuse a tampered ID-JAG with the fixed untrusted description', async ({
    page,
    request,
    baseURL,
  }) => {
    const idpIssuer = requireBaseUrl(baseURL);
    test.skip(!(await supportsXaa(request, idpIssuer)), XAA_SKIP_REASON);

    const idJag = await obtainIdJag(page, request, idpIssuer);
    const [header = '', payload = ''] = idJag.split('.');

    const res = await request.post(`${xaaIssuer}/token`, {
      form: {
        grant_type: JWT_BEARER_GRANT_TYPE,
        assertion: `${header}.${payload}.AAAA`,
        client_id: clientId,
        client_secret: clientSecret,
      },
    });

    expect(res.status()).toBe(400);
    // The same description covers "issuer unknown" — the response never says
    // which trust check failed, so it cannot enumerate the trusted-IdP list.
    expect(await res.json()).toEqual({
      error: 'invalid_grant',
      error_description: 'The assertion issuer is not trusted or the assertion signature is invalid',
    });
  });
});

const XAA_SKIP_REASON =
  'This sample OP was generated without --enable id-jag, or the second (resource AS) OP instance is not running';

/**
 * Complete the ordinary Authorization Code Flow at the E2E client app as
 * testuser and read the raw ID Token off the client's result page.
 */
async function obtainIdToken(page: import('@playwright/test').Page): Promise<string> {
  await page.goto(`${clientBaseURL}/start`);
  await page.getByLabel('Username:').fill('testuser');
  await page.getByLabel('Password:').fill('password');
  await page.getByRole('button', { name: 'Login' }).click();
  await page.getByRole('button', { name: 'Approve' }).click();
  return (await page.getByTestId('token-id-token').textContent()) ?? '';
}

/** SSO plus the token exchange: hand back a freshly issued ID-JAG. */
async function obtainIdJag(
  page: import('@playwright/test').Page,
  request: APIRequestContext,
  idpIssuer: string,
): Promise<string> {
  const idToken = await obtainIdToken(page);
  const res = await request.post(`${idpIssuer}/token`, {
    form: {
      grant_type: EXCHANGE_GRANT_TYPE,
      requested_token_type: ID_JAG_TOKEN_TYPE,
      subject_token: idToken,
      subject_token_type: ID_TOKEN_TYPE,
      audience: xaaIssuer,
      scope: 'openid profile',
      client_id: clientId,
      client_secret: clientSecret,
    },
  });
  return ((await res.json()) as Record<string, string>).access_token ?? '';
}

/** Decode a JWT segment (base64url, RFC 7515 §2). */
function decodeJwtSegment(segment: string): Record<string, unknown> {
  const base64 = segment.replace(/-/g, '+').replace(/_/g, '/');
  const padded = base64 + '='.repeat((4 - (base64.length % 4)) % 4);
  return JSON.parse(atob(padded)) as Record<string, unknown>;
}

async function discovery(
  request: APIRequestContext,
  issuer: string,
): Promise<Record<string, unknown>> {
  const response = await request.get(`${issuer}/.well-known/openid-configuration`);
  return (await response.json()) as Record<string, unknown>;
}

/**
 * True only when the IdP OP advertises ID-JAG issuance AND the second OP is up
 * and advertises the grant profile. The second instance only starts for the
 * hono sample, so the reachability probe doubles as the skip condition for
 * every other sample OP.
 */
async function supportsXaa(request: APIRequestContext, idpIssuer: string): Promise<boolean> {
  try {
    const idpMetadata = await discovery(request, idpIssuer);
    const chaining = idpMetadata.identity_chaining_requested_token_types_supported;
    if (!Array.isArray(chaining) || !chaining.includes(ID_JAG_TOKEN_TYPE)) {
      return false;
    }
    const asMetadata = await discovery(request, xaaIssuer);
    const profiles = asMetadata.authorization_grant_profiles_supported;
    return Array.isArray(profiles) && profiles.includes(ID_JAG_GRANT_PROFILE);
  } catch {
    return false;
  }
}

function requireBaseUrl(baseURL: string | undefined): string {
  if (baseURL === undefined) {
    throw new Error('baseURL is not configured');
  }
  return baseURL;
}
```

## References

- Requirement documents: `tasks/experimental/id-jag/specification.md` (the full error tables and security requirements), `tasks/experimental/id-jag/understanding-guide.md` (the background of XAA and its common misconceptions)
- Primary sources: `tasks/experimental/id-jag/sources.md`
- User-facing documentation: `docs/library-document/src/content/docs/experimental/id-jag.md` in the OSS repository
- Neighbor feature: [token-exchange.en.md](./token-exchange.en.md) (shares the grant_type URN; differs in both input and output token kinds)
