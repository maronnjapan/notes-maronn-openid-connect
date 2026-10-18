# CIBA (Client-Initiated Backchannel Authentication) Implementation Guide

- **feature-id**: `ciba`
- **Specifications**: OpenID Connect Client-Initiated Backchannel Authentication Flow - Core 1.0 (Final, 2021-09-01), RFC 6749
- **Location**: `packages/experimental/src/ciba/`
- **Enable with**: `maronn-oidc generate <framework> --enable ciba`
- **Requirement documents**: `tasks/experimental/done/ciba/` (specification.md / understanding-guide.md / sources.md)

## What the feature does

**CIBA (Client-Initiated Backchannel Authentication)** is an OpenID Connect extension for starting a login from a device the user is not operating.
A device such as a call-center console, an in-store terminal, or a smart speaker (the spec calls it the consumption device) asks the OP for authentication over the back channel, carrying nothing but a user identifier (`login_hint`).
The actual authentication and approval happen on the user's own device (the authentication device), and the requesting device receives its tokens by polling the token endpoint.

The feature adds three surfaces to a generated OP.

- **The backchannel authentication endpoint** (`POST /backchannel_authentication`): the client presents a `login_hint` and receives `auth_req_id` / `expires_in` / `interval` (CIBA §7)
- **The authentication device UI** (`GET /ciba` / `POST /ciba/login` / `POST /ciba/approve`): the user signs in to the OP on their own browser, reviews the pending requests addressed to them (client name, scopes, `binding_message`), and approves or denies
- **A token endpoint grant branch**: `grant_type=urn:openid:params:grant-type:ciba` answers with `authorization_pending` / `slow_down` / `access_denied` / `expired_token` or a token response, depending on the record's state (CIBA §10.1 / §11)

The building blocks closely resemble the already-implemented Device Authorization Grant, but the flow points the other way.
In the Device Flow the user copies a `user_code` and comes to the OP themselves; in CIBA the client names the user and the OP waits for the user's approval.
The three shared parts (polling-based token delivery, an approval UI, a grant dispatch) have the same shape; what differs is the identification handle (`user_code` vs `login_hint`) and the direction of initiation.

### Use cases

- Verifying whether the "operator types the user's identifier, the user approves on their phone" UX of a call center actually works for your requirements
- Building a PoC for authorization from input-constrained devices such as in-store terminals and voice devices
- Understanding plain CIBA Core 1.0 hands-on before adopting FAPI-CIBA

### Scope and non-goals

Of CIBA Core 1.0's three token delivery modes, this implementation offers **poll mode only**.
Ping and push mode require callbacks to a client notification endpoint (managing an SSRF surface and validating `client_notification_token`), which exceeds the isolation budget of an experimental feature.
Discovery advertises `backchannel_token_delivery_modes_supported: ["poll"]` only, and a request from a client registered for any other mode is refused with `unauthorized_client`.

The only supported hint is `login_hint`.
`id_token_hint` would need a relaxed variant of core's validation (CIBA's re-authentication use case presents an expired ID Token as the hint, which core's validator rejects), so it is recorded as a future extension in the requirement documents.
`login_hint_token` has no standardized format in CIBA Core.
Signed authentication requests (§7.1.1), the `user_code` parameter (§7.1.2) and the FAPI-CIBA profile are also out of scope.

How the authentication device is reached, and how the user authenticates on it, are explicitly outside the CIBA Core specification (§7.1).
This feature implements that layer as an OP-hosted browser UI.
The push notification typical of production CIBA deployments is left to the deployment together with its notification infrastructure; the approve / deny logic is exposed as public API so the UI can be replaced wholesale.

## Design decisions

**Ride on the Device Authorization Grant precedent.**
The polling state machine (the +5 seconds of `slow_down`, expiry evaluated first, atomic consume), the client-authentication pipeline of the backchannel endpoint, and the session / CSRF design of the approval UI all follow the structure of the implemented device-authorization-grant feature.
No code is shared (per the experimental policy, each feature keeps its own copy), but reusing a reviewed design narrows the genuinely new surface to what is specific to CIBA.

**Bind the approval to the session subject.**
The Device Flow guards its approval with a binding cookie; CIBA deliberately has no equivalent.
The Device Flow needed the browser binding because the `user_code` is the only link to the record and is, by construction, known to whoever started the flow — a party that can be the attacker.
A CIBA approval is bound by "the authenticated OP session's subject must equal the record's subject", and the per-record CSRF token is only ever rendered on the session-gated listing.
Knowing an `auth_req_id` gives an attacker no operation to perform without that session.

**Always bind the login form to the browser.**
A successful login creates an OP session, whose reach goes beyond CIBA (SSO, `prompt=none`).
A form-embedded CSRF token alone is not enough: an attacker can open `GET /ciba` themselves, obtain a valid `login_transaction_id` + CSRF pair, and embed both into a forged form.
So the form response mints a **login transaction**: the raw bindingSecret travels only in an HttpOnly cookie held by that one browser, and the record stores its SHA-256 hash.
A forged cross-site POST fails because the victim's browser never held this transaction's cookie — no secrecy assumption required.
This applies the generated code's existing principle that any step establishing an OP session is guarded by a binding (the same as `/device/login`).
The login transaction doubles as the anchor for counting credential attempts; exceeding the limit discards the transaction itself.

**Keep errors from becoming oracles.**
An unknown `auth_req_id` and another client's `auth_req_id` share one `invalid_grant` wording (§11's "invalid or was issued to another Client"); a missing user and a throwing resolver share one `unknown_user_id` wording; and every UI verification failure (unknown, expired, binding mismatch, CSRF mismatch, subject mismatch) is the same 403 message.
No response distinguishes internal state.

**Cap the approval-screen flood by pending count.**
The `user_code` of §7.1.2 (a per-user secret that suppresses unsolicited requests) is not implemented, so its role is covered by four measures: (1) mandatory client authentication, (2) a per-subject cap on pending requests (`maxPendingPerSubject`), (3) a pull-style UI with no push notifications (nothing interrupts the user), and (4) an approval screen that always shows the client, the scopes and the `binding_message`, with a Deny button as prominent as Approve.
Exceeding the cap answers `invalid_request` with a fixed description: §13's `access_denied` risks being read by client implementations as the end of the flow (user denial), which does not fit a temporary state that clears as pending requests resolve.

**Leave core untouched.**
Token issuance runs through core's existing functions (`buildAccessTokenPayload` / `buildIdTokenPayload` / `generateIdToken`) inside the generated code; the experimental module owns only record management and the state machine.
The CIBA registration extension (`backchannelTokenDeliveryMode`) is defined on the experimental side as `CibaClientInfo`, an intersection over core's `TokenClientInfo`; core's types are unchanged.

## The implementation, file by file

The module has six files. store / errors sit at the bottom; the endpoint processing (backchannel-authentication-request), the UI step functions (verification), the token branch (ciba-grant) and the public API (index) build on them.

### store.ts (store contracts and in-memory implementations)

There are two kinds of records.
An **authentication request record** (`CibaAuthenticationRequestRecord`) is the state machine of one backchannel request: it moves one-way through `pending → approved / denied` and is consumed at token issuance.
A **login transaction** (`CibaLoginTransactionRecord`) manages the lifetime of one login form of the authentication device UI, anchoring both the login-CSRF defense (bindingHash) and the failure count (loginAttempts).

The atomicity requirement on `consume` and the note delegating expired-record cleanup to the store implementation follow the PAR / Device store contracts.
Unlike the device feature, the in-memory implementations are exported from the package as factory functions (`createInMemoryCibaAuthenticationRequestStore`), so the generated `features/ciba/store.ts` only keeps what the factories return instead of a copied class.

```typescript
/**
 * OpenID Connect Client-Initiated Backchannel Authentication (CIBA) Core 1.0 —
 * Poll モード
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * 認証リクエストレコードとログイントランザクションのストア契約。
 */

/** CIBA Core 1.0 §10.1: トークンリクエストの grant_type 値。 */
export const CIBA_GRANT_TYPE = 'urn:openid:params:grant-type:ciba';

/**
 * ログイントランザクションの TTL（秒）。
 *
 * 既存の auth transaction の TTL / Cookie Max-Age と同値の 600 秒に固定し、
 * 設定面を増やさない（仕様の設計判断）。
 */
export const CIBA_LOGIN_TRANSACTION_TTL_SECONDS = 600;

/** 認証リクエストレコードの状態（CIBA §11 の状態機械）。 */
export type CibaStatus = 'pending' | 'approved' | 'denied';

/**
 * バックチャネル認証エンドポイントが発行したレコード。
 *
 * `authReqId` は認可コード同等の機密として扱う（CIBA §7.3）。ログ出力・
 * エラーメッセージへの混入は禁止する。
 */
export interface CibaAuthenticationRequestRecord {
  /** 256bit Base64URL。クライアントがトークンエンドポイントへ提示する。 */
  authReqId: string;
  /** auth_req_id の発行先クライアント（CIBA §11 の紐付け）。 */
  clientId: string;
  /** login_hint 解決結果（リクエスト受理時点で確定）。 */
  subject: string;
  /** 要求 scope（offline_access ポリシー適用後）。 */
  scope: string[];
  /** CIBA §7.1 binding_message。承認画面に表示する（表示時エスケープ必須）。 */
  bindingMessage?: string;
  /** CIBA §7.1 acr_values。advisory として保存するのみ。 */
  acrValues?: string;
  status: CibaStatus;
  createdAt: Date;
  expiresAt: Date;
  /** 現在の要求ポーリング間隔（秒）。slow_down のたびに +5 される（§11）。 */
  interval: number;
  lastPolledAt: Date | null;
  /** 認証デバイス UI の一覧表示時に発行・回転する CSRF トークン。 */
  csrfToken: string | null;
  /** 承認時のみ設定される認証時刻（epoch 秒）。 */
  authTime?: number;
  /** 承認時のみ設定される承認済み scope。 */
  approvedScope?: string[];
  /** 承認時のみ設定される grant 識別子（revocation の grant 単位失効に使う）。 */
  grantId?: string;
}

/**
 * 利用者が実装する認証リクエストレコードのストア契約。
 *
 * `authReqId` は外部入力由来の不透明値として扱うこと。永続ストア実装では
 * キーをクエリ文字列へ連結せず、必ずパラメータ化した問い合わせを使う。
 */
export interface CibaAuthenticationRequestStore {
  save(record: CibaAuthenticationRequestRecord): Promise<void>;
  findByAuthReqId(authReqId: string): Promise<CibaAuthenticationRequestRecord | null>;
  /** 認証デバイス UI の一覧用。期限内・pending のレコードのみ返す。 */
  listPendingBySubject(subject: string): Promise<CibaAuthenticationRequestRecord[]>;
  /**
   * レコードを更新する。
   *
   * `lastPolledAt` / `interval` の read-modify-write が atomic でない実装では、
   * 並行ポーリング時にポーリング間隔の強制が甘くなり得る。ただし認可状態の遷移
   * （pending → approved / denied）と {@link CibaAuthenticationRequestStore.consume}
   * による単回使用が守られていればセキュリティ特性は保たれる。
   */
  update(record: CibaAuthenticationRequestRecord): Promise<void>;
  delete(authReqId: string): Promise<void>;
  /**
   * 取得と同時に削除する（トークン発行時の単回使用強制）。
   *
   * 取得と削除は atomic でなければならない。atomic でない実装は同一 auth_req_id の
   * 並行リデンプションを許してしまう（device store の consume と同じ要件）。
   *
   * 期限切れレコードの掃除: 期限切れは原則トークンエンドポイントのポーリング時に
   * `expired_token` 応答とともに削除されるが、ポーリングを止めたクライアントの
   * レコードは残る。ストア実装は `expiresAt` から十分な猶予（目安: TTL と同程度）を
   * 置いた後に期限切れレコードを自主的に破棄してよい。破棄後のポーリングは
   * `expired_token` ではなく `invalid_grant` になるが、クライアントはどちらの
   * エラーでもフローを終了するため相互運用上の問題はない。
   */
  consume(authReqId: string): Promise<CibaAuthenticationRequestRecord | null>;
}

/**
 * 認証デバイス UI のログイントランザクション。
 *
 * ログイン CSRF 防御（binding Cookie のハッシュ照合）と資格情報試行の計数の
 * 錨になる。`id` / `csrfToken` は hidden フィールドで運び、`bindingHash` の
 * 生値（bindingSecret）はブラウザの HttpOnly Cookie にのみ存在する。
 */
export interface CibaLoginTransactionRecord {
  /** 256bit Base64URL。hidden フィールドで運ぶ。 */
  id: string;
  /** 256bit Base64URL。hidden フィールドで運ぶ。 */
  csrfToken: string;
  /** bindingSecret（Cookie 生値）の SHA-256 Base64URL。生値は保存しない。 */
  bindingHash: string;
  /** ログイン失敗回数（トランザクション単位）。 */
  loginAttempts: number;
  expiresAt: Date;
}

/** ログイントランザクションのストア契約。 */
export interface CibaLoginTransactionStore {
  save(record: CibaLoginTransactionRecord): Promise<void>;
  findById(id: string): Promise<CibaLoginTransactionRecord | null>;
  update(record: CibaLoginTransactionRecord): Promise<void>;
  delete(id: string): Promise<void>;
}

/**
 * インメモリの認証リクエストレコードストア。
 *
 * 動作確認用。本番では永続ストア（Redis / KV / database）に置き換えること。
 * consume は取得と削除を単一の同期処理で行うため atomic 要件を満たす。
 */
export function createInMemoryCibaAuthenticationRequestStore(): CibaAuthenticationRequestStore {
  const records = new Map<string, CibaAuthenticationRequestRecord>();
  // 期限切れから 1 TTL 相当の猶予を置いて自主破棄する（expired_token を
  // 返せる期間を 1 TTL 残しつつ、放置ストアが際限なく育たないようにする）。
  const evictionGraceMs = 600 * 1000;
  const evictExpired = (): void => {
    const cutoff = Date.now() - evictionGraceMs;
    for (const [authReqId, record] of records) {
      if (record.expiresAt.getTime() < cutoff) {
        records.delete(authReqId);
      }
    }
  };
  return {
    async save(record: CibaAuthenticationRequestRecord): Promise<void> {
      evictExpired();
      records.set(record.authReqId, record);
    },
    async findByAuthReqId(authReqId: string): Promise<CibaAuthenticationRequestRecord | null> {
      return records.get(authReqId) ?? null;
    },
    async listPendingBySubject(subject: string): Promise<CibaAuthenticationRequestRecord[]> {
      const now = Date.now();
      const pending: CibaAuthenticationRequestRecord[] = [];
      for (const record of records.values()) {
        if (
          record.subject === subject &&
          record.status === 'pending' &&
          record.expiresAt.getTime() > now
        ) {
          pending.push(record);
        }
      }
      return pending;
    },
    async update(record: CibaAuthenticationRequestRecord): Promise<void> {
      records.set(record.authReqId, record);
    },
    async delete(authReqId: string): Promise<void> {
      records.delete(authReqId);
    },
    async consume(authReqId: string): Promise<CibaAuthenticationRequestRecord | null> {
      const record = records.get(authReqId) ?? null;
      // 単回使用（CIBA §11）: 読み取りと同時に削除し、同じ auth_req_id の
      // リプレイが 2 本目のトークンを得られないようにする。
      records.delete(authReqId);
      return record;
    },
  };
}

/**
 * インメモリのログイントランザクションストア。
 *
 * 動作確認用。本番では永続ストアに置き換えること。
 */
export function createInMemoryCibaLoginTransactionStore(): CibaLoginTransactionStore {
  const records = new Map<string, CibaLoginTransactionRecord>();
  const evictExpired = (): void => {
    const now = Date.now();
    for (const [id, record] of records) {
      if (record.expiresAt.getTime() < now) {
        records.delete(id);
      }
    }
  };
  return {
    async save(record: CibaLoginTransactionRecord): Promise<void> {
      evictExpired();
      records.set(record.id, record);
    },
    async findById(id: string): Promise<CibaLoginTransactionRecord | null> {
      return records.get(id) ?? null;
    },
    async update(record: CibaLoginTransactionRecord): Promise<void> {
      records.set(record.id, record);
    },
    async delete(id: string): Promise<void> {
      records.delete(id);
    },
  };
}
```

### errors.ts (error types)

The error types split by response surface.
`BackchannelAuthenticationError` carries the §13 vocabulary of the backchannel authentication endpoint, and `CibaGrantError` the §11 vocabulary of the token endpoint (plus existing RFC 6749 §5.2 values such as `unauthorized_client`); both use the RFC 6749 §5.2 JSON shape and are always 400 (401 comes only from core's `TokenError`, which owns client authentication).
`CibaVerificationError` is the UI layer's type, answered as an HTML page.

Omitting `access_denied` from `BackchannelAuthenticationError` is deliberate.
§13 defines it for immediate refusal at the authentication endpoint, but this poll-mode implementation accepts the request and then waits for the user, so a denial is always delivered as the token endpoint's `access_denied`.

```typescript
/**
 * OpenID Connect Client-Initiated Backchannel Authentication (CIBA) Core 1.0 —
 * Poll モード
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * エラー型。CIBA §13 がバックチャネル認証エンドポイント用に定義する値と、
 * §11 がトークンエンドポイント用に定義する値（RFC 8628 と共通の語彙を含む）を
 * それぞれ専用クラスで扱う。
 */
import { sanitizeErrorDescription } from '@maronn-openid-connect/core';

/**
 * バックチャネル認証エンドポイント（`POST /backchannel_authentication`）の
 * エラーコード（CIBA §13）。
 *
 * `access_denied` は含めない: §13 は認証エンドポイントでの即時拒否用に定義するが、
 * Poll モードの本実装は受理後にユーザー判断を待つため、拒否は常にトークン
 * エンドポイントの `access_denied` で配信される。
 */
export type BackchannelAuthenticationErrorCode =
  | 'invalid_request'
  | 'invalid_scope'
  | 'unknown_user_id'
  | 'unauthorized_client'
  | 'invalid_binding_message';

/**
 * バックチャネル認証エンドポイントのエラー。
 *
 * クライアント認証失敗は生成コード側の共有パイプラインが core の `TokenError`
 * として 401 を返すため、この型は常に 400 になる（CIBA §13 / RFC 6749 §5.2）。
 *
 * `errorDescription` には `login_hint` の値・`auth_req_id` を含めてはならない
 * （`login_hint` は PII。CIBA §15）。
 */
export class BackchannelAuthenticationError extends Error {
  readonly code: BackchannelAuthenticationErrorCode;
  readonly errorDescription: string;

  constructor(code: BackchannelAuthenticationErrorCode, errorDescription: string) {
    // RFC 6749 §5.2: error_description は安全な文字集合に限定する。
    const sanitized = sanitizeErrorDescription(errorDescription);
    super(sanitized);
    this.name = 'BackchannelAuthenticationError';
    this.code = code;
    this.errorDescription = sanitized;
  }

  /** CIBA §13 / RFC 6749 §5.2: このエラー群は常に 400 で返す。 */
  get statusCode(): 400 {
    return 400;
  }
}

/**
 * 認証デバイス UI（`/ciba`, `/ciba/login`, `/ciba/approve`）で発生するエラー。
 *
 * トークンエンドポイントの OAuth エラーとは応答形式が異なる（HTML ページ）ため
 * 型を分ける。`statusCode` はそのまま HTTP ステータスとして使う。
 *
 * message は失敗理由（不存在・期限切れ・binding 不一致・CSRF 不一致・subject
 * 不一致）を区別しない固定文言とし、`auth_req_id` やログイントランザクションの
 * 有効性を外部から識別できるオラクルにしない。
 */
export class CibaVerificationError extends Error {
  readonly statusCode: 401 | 403;

  constructor(message: string, statusCode: 401 | 403) {
    super(message);
    this.name = 'CibaVerificationError';
    this.statusCode = statusCode;
  }
}

/**
 * トークンエンドポイントの CIBA grant 分岐のエラーコード（CIBA §11）。
 *
 * - `authorization_pending` / `slow_down` / `access_denied` / `expired_token`:
 *   §11 が Poll モードのポーリング応答用に定める値。
 * - `invalid_grant` / `invalid_request` / `unauthorized_client`: RFC 6749 §5.2 の既存値。
 */
export type CibaGrantErrorCode =
  | 'authorization_pending'
  | 'slow_down'
  | 'expired_token'
  | 'access_denied'
  | 'invalid_grant'
  | 'invalid_request'
  | 'unauthorized_client';

/**
 * トークンエンドポイントの CIBA grant 分岐のエラー。
 *
 * バックチャネル専用でリダイレクトは行わない。クライアント認証失敗は分岐前の
 * 共有パイプラインが core の `TokenError` として 401 を返すため、この型は
 * 常に 400 になる。
 *
 * `errorDescription` には `auth_req_id` を含めてはならない。
 */
export class CibaGrantError extends Error {
  readonly code: CibaGrantErrorCode;
  readonly errorDescription: string;

  constructor(code: CibaGrantErrorCode, errorDescription: string) {
    // RFC 6749 §5.2: error_description は安全な文字集合に限定する。
    const sanitized = sanitizeErrorDescription(errorDescription);
    super(sanitized);
    this.name = 'CibaGrantError';
    this.code = code;
    this.errorDescription = sanitized;
  }

  /** CIBA §11 / RFC 6749 §5.2: このエラー群は常に 400 で返す。 */
  get statusCode(): 400 {
    return 400;
  }
}
```

### backchannel-authentication-request.ts (the backchannel authentication endpoint)

`processBackchannelAuthenticationRequest` implements all of §7.1 / §7.2 / §7.3.
Content-Type and duplicate-parameter checks, plus client authentication, run earlier in the generated code's shared pipeline; the function receives an already-authenticated client.

Validation follows the order fixed in the requirement documents: client checks (public client → CIBA grant registration → delivery mode), rejection of the `request` parameter, the hint rule, scope, `binding_message`, `requested_expiry`, `login_hint` resolution, and the pending cap.
The hint rule (§7.1's "one (and only one) of the hints") answers zero or multiple hints with `invalid_request`, and a lone `id_token_hint` / `login_hint_token` with a different fixed `invalid_request` wording for an unsupported hint type.
That split follows the requirement documents' reading of §13: `unknown_user_id` is the vocabulary for "the hint did not match a user", while an unsupported hint type is a malformed request.

`requested_expiry` is honored by clamping into `[30, authReqIdExpiresIn]` (§7.1 says "The server MAY use this value").
`login_hint` resolution is delegated to the `CibaUserResolver` contract (the deployment's swap point); a throwing resolver collapses into the same fixed wording as a missing user.

```typescript
/**
 * OpenID Connect Client-Initiated Backchannel Authentication (CIBA) Core 1.0 —
 * Poll モード、§7（バックチャネル認証エンドポイント）
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * バックチャネル認証エンドポイント（`POST /backchannel_authentication`）の処理。
 * Content-Type / 重複パラメータの検証とクライアント認証は、生成コード側の
 * 共有パイプライン（extractClientCredentials → resolveAuthenticatedTokenClient →
 * validateClientAuthMethod → verifyClientSecret）で済ませてから、認証済み
 * クライアントをここへ渡す。
 */
import { generateRandomString, type TokenClientInfo } from '@maronn-openid-connect/core';
import { BackchannelAuthenticationError } from './errors.js';
import {
  CIBA_GRANT_TYPE,
  type CibaAuthenticationRequestRecord,
  type CibaAuthenticationRequestStore,
} from './store.js';

/** CIBA §7.3: auth_req_id は認可コード同等のエントロピー（256bit）で生成する。 */
const AUTH_REQ_ID_BYTE_LENGTH = 32;

/**
 * CIBA §7.1: binding_message は「表示能力の限られたデバイスに収まる、
 * 比較しやすい短い値」であることが求められる。本実装は 100 文字を上限とし、
 * 制御文字を拒否する（承認画面へ表示する値のため、表示時エスケープと併せた二層防御）。
 */
export const BINDING_MESSAGE_MAX_LENGTH = 100;

/** requested_expiry のクランプ下限（秒）。 */
const REQUESTED_EXPIRY_MIN = 30;

/**
 * ユーザー不存在と resolver 例外を区別させないための単一文言（オラクル防止）。
 */
const UNKNOWN_USER_MESSAGE = 'The login_hint could not be matched to a user';

/**
 * クライアント登録の CIBA 拡張メタデータ。
 *
 * `backchannelTokenDeliveryMode`（CIBA §4 の Registration パラメータ相当）を
 * core の `TokenClientInfo` へ交差型で足す。core の型変更は行わない。
 * 未設定は `poll` とみなす（本 OP は poll しか広告しないため、CIBA grant の
 * 登録を poll 登録と読み替える設計判断）。
 */
export type CibaClientInfo = TokenClientInfo & {
  backchannelTokenDeliveryMode?: 'poll' | 'ping' | 'push';
};

/**
 * login_hint からユーザーを解決する契約（利用者の swap point）。
 *
 * `login_hint` の意味論（メールアドレス / 電話番号 / ユーザー名）は利用者の
 * ユーザーストア設計に依存するため、解決ロジックを丸ごと差し替えられるようにする。
 * 解決できないときは null を返す。例外は不存在と同じ扱いになる（オラクル防止）。
 */
export type CibaUserResolver = (
  loginHint: string,
) => Promise<{ subject: string } | null> | { subject: string } | null;

/** バックチャネル認証エンドポイントの設定値。 */
export interface CibaConfig {
  /** auth_req_id の有効期間（秒）。既定 120、範囲 30–600。 */
  authReqIdExpiresIn: number;
  /** 要求ポーリング間隔の初期値（秒）。既定 5、範囲 1–60。 */
  pollingInterval: number;
  /** 1 subject あたりの保留中リクエスト数の上限。既定 10、範囲 1–100。 */
  maxPendingPerSubject: number;
}

/** CIBA §7.3 の成功レスポンスボディ（JSON のフィールド名そのまま）。 */
export interface BackchannelAuthenticationResponse {
  auth_req_id: string;
  expires_in: number;
  interval: number;
}

/**
 * バックチャネル認証エンドポイントの全処理（CIBA §7.1 / §7.2 / §7.3）。
 *
 * 検証は仕様書の検証順序どおりに進む: クライアント検証（auth method none 拒否 →
 * CIBA grant 登録 → delivery mode）→ `request` 拒否 → ヒント規則 → scope →
 * binding_message → requested_expiry → login_hint 解決 → 保留数制限 →
 * レコード生成・保存。
 *
 * @throws {BackchannelAuthenticationError}
 */
export async function processBackchannelAuthenticationRequest(input: {
  params: Record<string, string>;
  /** 認証済みクライアント（共有認証パイプラインを通過済みであること）。 */
  client: CibaClientInfo;
  store: CibaAuthenticationRequestStore;
  config: CibaConfig;
  /** OIDC Core 1.0 §11: refresh-token feature が無効なら offline_access は落とす。 */
  refreshTokenFeatureEnabled: boolean;
  resolveUser: CibaUserResolver;
  /** テスト用の時刻注入点。既定は現在時刻。 */
  now?: Date;
}): Promise<BackchannelAuthenticationResponse> {
  const { params, client, store, config } = input;

  validateCibaClient(client);
  rejectSignedRequest(params);
  const loginHint = extractLoginHint(params);
  const scope = applyOfflineAccessPolicy(validateCibaScope(params['scope']), {
    client,
    refreshTokenFeatureEnabled: input.refreshTokenFeatureEnabled,
  });
  const bindingMessage = validateBindingMessage(params['binding_message']);
  const expiresIn = resolveExpiresIn(params['requested_expiry'], config);

  const subject = await resolveSubject(loginHint, input.resolveUser);

  // 承認 UI の flood 対策（設計判断。CIBA Core に該当エラーは無いため
  // 終端を示唆しない invalid_request の固定文言で返す）。
  const pending = await store.listPendingBySubject(subject);
  if (pending.length >= config.maxPendingPerSubject) {
    throw new BackchannelAuthenticationError(
      'invalid_request',
      'Too many pending authentication requests for this user',
    );
  }

  const createdAt = input.now ?? new Date();
  const record: CibaAuthenticationRequestRecord = {
    authReqId: generateRandomString(AUTH_REQ_ID_BYTE_LENGTH),
    clientId: client.clientId,
    subject,
    scope,
    status: 'pending',
    createdAt,
    expiresAt: new Date(createdAt.getTime() + expiresIn * 1000),
    interval: config.pollingInterval,
    lastPolledAt: null,
    csrfToken: null,
  };
  if (bindingMessage !== undefined) {
    record.bindingMessage = bindingMessage;
  }
  // acr_values は advisory として保存するだけで、要求 acr を満たさない場合の
  // 拒否は行わない（発行 ID トークンの acr / amr は既存の acrResolver が解決する）。
  const acrValues = params['acr_values'];
  if (acrValues !== undefined && acrValues !== '') {
    record.acrValues = acrValues;
  }
  await store.save(record);

  return {
    auth_req_id: record.authReqId,
    expires_in: expiresIn,
    interval: config.pollingInterval,
  };
}

/**
 * クライアント側の検証（検証順序 3〜5）。
 *
 * - CIBA §7.1 はクライアント認証を MUST とするため、認証を行えない
 *   auth method `none`（public client）は要件を満たせない
 * - RFC 6749 §5.2: 登録済み grant_types に含まれないグラントは unauthorized_client。
 *   `TokenClientInfo.grantTypes` の既定は `['authorization_code']` のため、
 *   CIBA を使うクライアントは URN の明示登録が必要
 * - 本 OP は discovery で `backchannel_token_delivery_modes_supported: ['poll']`
 *   のみを広告するため、poll 以外を登録したクライアントは拒否する。未設定は
 *   poll とみなす
 *
 * @throws {BackchannelAuthenticationError} unauthorized_client
 */
function validateCibaClient(client: CibaClientInfo): void {
  if (client.tokenEndpointAuthMethod === 'none') {
    throw new BackchannelAuthenticationError(
      'unauthorized_client',
      'Public clients are not allowed to use the CIBA grant type',
    );
  }
  if (!(client.grantTypes ?? []).includes(CIBA_GRANT_TYPE)) {
    throw new BackchannelAuthenticationError(
      'unauthorized_client',
      'The client is not authorized to use the CIBA grant',
    );
  }
  const deliveryMode = client.backchannelTokenDeliveryMode ?? 'poll';
  if (deliveryMode !== 'poll') {
    throw new BackchannelAuthenticationError(
      'unauthorized_client',
      'This provider only supports the poll token delivery mode',
    );
  }
}

/**
 * CIBA §7.1.1 の署名付き認証リクエスト（`request` パラメータ）は受け付けない。
 *
 * @throws {BackchannelAuthenticationError} invalid_request
 */
function rejectSignedRequest(params: Record<string, string>): void {
  if (params['request'] !== undefined) {
    throw new BackchannelAuthenticationError(
      'invalid_request',
      'Signed authentication requests are not supported',
    );
  }
}

/**
 * ヒント規則（CIBA §7.1 / §7.2）。
 *
 * 「3 つのヒントのうちちょうど 1 つ」が REQUIRED。0 個・2 個以上は
 * invalid_request（§7.2 MUST）。対応するヒントは login_hint のみで、
 * id_token_hint / login_hint_token の単独提示はヒント種別の非対応として
 * invalid_request の固定文言で拒否する（§13 `unknown_user_id` は「ヒントから
 * ユーザーを特定できない」場合の語彙であり、種別の非対応は malformed 系）。
 *
 * @throws {BackchannelAuthenticationError} invalid_request
 */
function extractLoginHint(params: Record<string, string>): string {
  const presented = (['login_hint', 'id_token_hint', 'login_hint_token'] as const).filter(
    (name) => params[name] !== undefined && params[name] !== '',
  );
  if (presented.length !== 1) {
    throw new BackchannelAuthenticationError(
      'invalid_request',
      'Exactly one of login_hint, id_token_hint or login_hint_token is required',
    );
  }
  if (presented[0] !== 'login_hint') {
    throw new BackchannelAuthenticationError(
      'invalid_request',
      'Only login_hint is supported by this provider',
    );
  }
  // presented の要素判定を通っているため空文字ではない。
  return params['login_hint'] as string;
}

/**
 * scope を検証して正規化する。
 *
 * CIBA §7.1 は scope に `openid` を含めることを求める（CIBA は OIDC 拡張）。
 * 本 OP は認可エンドポイント・デバイス認可と同じプロファイル制限
 * （scope 必須・`openid` 必須）を課す。空白区切り・重複除去の扱いは
 * device-authorization-grant と同じ規則。
 *
 * @throws {BackchannelAuthenticationError} invalid_request / invalid_scope
 */
function validateCibaScope(scope: string | undefined): string[] {
  if (scope === undefined || scope.trim() === '') {
    throw new BackchannelAuthenticationError(
      'invalid_request',
      'Missing required parameter: scope',
    );
  }
  const values = [...new Set(scope.trim().split(/\s+/).filter((value) => value.length > 0))];
  if (!values.includes('openid')) {
    throw new BackchannelAuthenticationError('invalid_scope', 'The openid scope is required');
  }
  return values;
}

/**
 * 許可条件を満たさない `offline_access` を scope から除去する。
 *
 * OIDC Core 1.0 §11: 許可条件を満たさない offline_access は無視する（エラーには
 * しない）。CIBA では認証デバイス UI の承認画面が明示同意そのものなので、許可
 * 条件は「refresh-token feature が有効」かつ「クライアントが refresh_token
 * grant を登録済み」の 2 点とする（device-authorization-grant と同じ規則）。
 */
function applyOfflineAccessPolicy(
  scope: string[],
  options: { client: CibaClientInfo; refreshTokenFeatureEnabled: boolean },
): string[] {
  const clientAllowsRefresh = (options.client.grantTypes ?? []).includes('refresh_token');
  if (options.refreshTokenFeatureEnabled && clientAllowsRefresh) {
    return scope;
  }
  return scope.filter((value) => value !== 'offline_access');
}

/**
 * binding_message を検証する（CIBA §7.1 / §13 invalid_binding_message）。
 *
 * @throws {BackchannelAuthenticationError} invalid_binding_message
 */
function validateBindingMessage(bindingMessage: string | undefined): string | undefined {
  if (bindingMessage === undefined) return undefined;
  const hasControlCharacter = [...bindingMessage].some((char) => {
    const code = char.codePointAt(0) ?? 0;
    return code < 0x20 || code === 0x7f;
  });
  if (
    bindingMessage.length < 1 ||
    bindingMessage.length > BINDING_MESSAGE_MAX_LENGTH ||
    hasControlCharacter
  ) {
    throw new BackchannelAuthenticationError(
      'invalid_binding_message',
      'binding_message must be 1 to 100 characters without control characters',
    );
  }
  return bindingMessage;
}

/**
 * requested_expiry を検証してクランプ済みの有効期間（秒）を返す。
 *
 * CIBA §7.1 は正の整数を求め、「The server MAY use this value」とする。本実装は
 * `[30, authReqIdExpiresIn]` へクランプして採用する（設計判断）。10 進数字のみを
 * 受理し、小数・符号・指数表記は拒否する。
 *
 * @throws {BackchannelAuthenticationError} invalid_request
 */
function resolveExpiresIn(requestedExpiry: string | undefined, config: CibaConfig): number {
  if (requestedExpiry === undefined) {
    return config.authReqIdExpiresIn;
  }
  if (!/^[0-9]+$/.test(requestedExpiry) || Number(requestedExpiry) < 1) {
    throw new BackchannelAuthenticationError(
      'invalid_request',
      'requested_expiry must be a positive integer',
    );
  }
  const requested = Number(requestedExpiry);
  return Math.min(Math.max(requested, REQUESTED_EXPIRY_MIN), config.authReqIdExpiresIn);
}

/**
 * login_hint を subject へ解決する（CIBA §13 unknown_user_id）。
 *
 * resolver の例外と不存在を同じ固定文言にし、失敗理由を応答から区別させない。
 *
 * @throws {BackchannelAuthenticationError} unknown_user_id
 */
async function resolveSubject(loginHint: string, resolveUser: CibaUserResolver): Promise<string> {
  let resolved: { subject: string } | null;
  try {
    resolved = await resolveUser(loginHint);
  } catch {
    resolved = null;
  }
  if (resolved === null) {
    throw new BackchannelAuthenticationError('unknown_user_id', UNKNOWN_USER_MESSAGE);
  }
  return resolved.subject;
}
```

### verification.ts (step functions of the authentication device UI)

These are the step functions the three UI routes call: minting and validating login transactions (`createCibaLoginTransaction` / `validateCibaLoginSubmission` / `recordCibaLoginFailure`), issuing the per-record CSRF tokens of the pending list (`listPendingCibaRequests`), and deciding (`approveCibaRequest` / `denyCibaRequest`).

Login validation checks the binding cookie's hash before the CSRF token: the binding proves "this is the browser the form was issued to", and the CSRF token is defense in depth on top of it.
The shared decision check (`resolveApprovableRecord`) collapses unknown, expired, already-decided, subject-mismatch and CSRF-mismatch into one 403 message.

`approveCibaRequest` takes the `grantId` as an argument.
Minting it in the caller (the generated code) lets the existing revocation machinery apply grant-scoped revocation unchanged, and keeps the experimental module out of the id's semantics.
`approvedScope` adopts the requested scope as-is (this OP's UI offers no partial approval).

```typescript
/**
 * OpenID Connect Client-Initiated Backchannel Authentication (CIBA) Core 1.0 —
 * Poll モード、認証デバイス UI
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * 認証デバイス UI（`GET /ciba`, `POST /ciba/login`, `POST /ciba/approve`）が呼ぶ
 * ステップ関数群。CIBA Core は認証デバイスへの到達手段とユーザー認証方法を仕様の
 * 対象外としており（§7.1）、これは「OP がホストするブラウザ UI」という本機能の
 * 実装判断に属する層である。
 *
 * ## ログイントランザクションがログインフォームを守る理由
 *
 * ログイン成功は OP セッションという CIBA 外にも及ぶ状態（SSO / prompt=none）を
 * 作るため、クロスサイトの偽造 POST で攻撃者アカウントのセッションを被害者
 * ブラウザへ植え付けるログイン CSRF を防ぐ必要がある。フォーム埋め込みトークン
 * だけでは、攻撃者が自分で `GET /ciba` を叩いて有効な `login_transaction_id` +
 * CSRF の対を入手し偽造フォームへ埋め込めるため足りない。そこでフォーム表示時に
 * bindingSecret を発行し、生値はブラウザだけが持つ HttpOnly Cookie に、SHA-256
 * ハッシュのみをトランザクションへ保存する。偽造 POST は被害者ブラウザに
 * binding Cookie が無いため、トークンの秘匿に依存せず遮断できる
 * （`/device/login` の「セッションを確立するステップは binding で守る」原則と同じ）。
 *
 * ## 承認操作に binding Cookie を要求しない理由
 *
 * CIBA の承認は認証済み OP セッションの subject とレコード subject の一致で
 * 束縛されており、レコードの CSRF トークンもセッション必須の一覧表示でしか
 * 得られない。`auth_req_id` を知っていてもセッションが無ければ承認操作は一切
 * できないため、Device Flow の bindingSecret Cookie に相当する仕組みは要らない。
 */
import { generateRandomString } from '@maronn-openid-connect/core';
import { CibaVerificationError } from './errors.js';
import {
  CIBA_LOGIN_TRANSACTION_TTL_SECONDS,
  type CibaAuthenticationRequestRecord,
  type CibaAuthenticationRequestStore,
  type CibaLoginTransactionRecord,
  type CibaLoginTransactionStore,
} from './store.js';

/** bindingSecret / csrfToken / grantId 系シークレットのエントロピー（256bit）。 */
const VERIFICATION_SECRET_BYTE_LENGTH = 32;

/**
 * ログイン検証の失敗理由（不存在・期限切れ・binding 不一致・CSRF 不一致）を
 * 区別させないための単一文言。
 */
const INVALID_LOGIN_SUBMISSION_MESSAGE = 'The sign-in request could not be verified';

/**
 * 承認 / 拒否の失敗理由（不存在・期限切れ・subject 不一致・CSRF 不一致・
 * 既決定）を区別させないための単一文言。`auth_req_id` の有効性を外部から
 * 確かめるオラクルにしない。
 */
const INVALID_APPROVAL_MESSAGE = 'The authentication request could not be verified';

/**
 * SHA-256 ハッシュを Base64URL で返す。
 *
 * bindingSecret の生値はブラウザの Cookie にのみ存在し、トランザクションには
 * このハッシュだけを保存する。ストアが漏洩しても Cookie を再構成できない。
 */
async function sha256Base64Url(value: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
  let binary = '';
  for (const byte of new Uint8Array(digest)) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/**
 * ログインフォーム表示時にログイントランザクションを発行する。
 *
 * bindingSecret の生値は戻り値としてのみ返し（生成コードが Cookie に載せる）、
 * レコードへは SHA-256 ハッシュだけを保存する。TTL は 600 秒固定
 * （{@link CIBA_LOGIN_TRANSACTION_TTL_SECONDS}）。
 */
export async function createCibaLoginTransaction(
  store: CibaLoginTransactionStore,
): Promise<{ record: CibaLoginTransactionRecord; bindingSecret: string }> {
  const bindingSecret = generateRandomString(VERIFICATION_SECRET_BYTE_LENGTH);
  const record: CibaLoginTransactionRecord = {
    id: generateRandomString(VERIFICATION_SECRET_BYTE_LENGTH),
    csrfToken: generateRandomString(VERIFICATION_SECRET_BYTE_LENGTH),
    bindingHash: await sha256Base64Url(bindingSecret),
    loginAttempts: 0,
    expiresAt: new Date(Date.now() + CIBA_LOGIN_TRANSACTION_TTL_SECONDS * 1000),
  };
  await store.save(record);
  return { record, bindingSecret };
}

/**
 * `POST /ciba/login` の提出内容を検証する。
 *
 * binding Cookie 生値のハッシュ一致 → CSRF 一致の順で検証する。不存在・
 * 期限切れ・binding 不一致・CSRF 不一致はすべて同じ 403 の固定文言で拒否し、
 * 失敗理由を区別させない。
 *
 * @throws {CibaVerificationError} 403
 */
export async function validateCibaLoginSubmission(input: {
  transactionId: string;
  csrfToken: string;
  /** Cookie から取り出した bindingSecret の生値。 */
  bindingSecret: string | null | undefined;
  store: CibaLoginTransactionStore;
  now?: Date;
}): Promise<CibaLoginTransactionRecord> {
  const reject: () => never = () => {
    throw new CibaVerificationError(INVALID_LOGIN_SUBMISSION_MESSAGE, 403);
  };
  const record = await input.store.findById(input.transactionId);
  if (record === null) reject();
  const now = input.now ?? new Date();
  if (now.getTime() >= record.expiresAt.getTime()) reject();
  if (!input.bindingSecret) reject();
  // 照合は「入力の SHA-256 ハッシュ vs 保存ハッシュ」の比較なので、比較の
  // タイミング差から保存値の前方一致を積み上げても原像計算が必要になり成立しない。
  const presented = await sha256Base64Url(input.bindingSecret);
  if (presented !== record.bindingHash) reject();
  if (input.csrfToken === '' || input.csrfToken !== record.csrfToken) reject();
  return record;
}

/**
 * ログイン失敗をトランザクション単位で計数する。
 *
 * 上限に達したトランザクションは削除し、同じフォームからの再試行を打ち切る
 * （生成コードは 429 を返す）。既知の残存面: トランザクションを再発行すれば
 * 集計上の試行回数は無制限になる。これは既存 `/login`（auth transaction 単位）・
 * `/device/login`（レコード単位）と同一の残存面で、subject 単位のスロットリングは
 * 別タスクの責務とする。
 */
export async function recordCibaLoginFailure(
  record: CibaLoginTransactionRecord,
  store: CibaLoginTransactionStore,
  maxLoginAttempts: number,
): Promise<{ canRetry: boolean; remainingAttempts: number }> {
  record.loginAttempts += 1;
  const canRetry = record.loginAttempts < maxLoginAttempts;
  if (canRetry) {
    await store.update(record);
  } else {
    await store.delete(record.id);
  }
  return {
    canRetry,
    remainingAttempts: Math.max(0, maxLoginAttempts - record.loginAttempts),
  };
}

/**
 * セッション subject 宛の保留中認証リクエストを一覧し、レコードごとの CSRF
 * トークンを発行・回転して保存する。
 *
 * CSRF トークンはこの一覧表示（OP セッション必須）でしか得られないため、
 * `auth_req_id` を知っているだけの第三者は承認 / 拒否の POST を組み立てられない。
 */
export async function listPendingCibaRequests(input: {
  subject: string;
  store: CibaAuthenticationRequestStore;
}): Promise<CibaAuthenticationRequestRecord[]> {
  const pending = await input.store.listPendingBySubject(input.subject);
  for (const record of pending) {
    record.csrfToken = generateRandomString(VERIFICATION_SECRET_BYTE_LENGTH);
    await input.store.update(record);
  }
  return pending;
}

/**
 * 承認（`POST /ciba/approve` の `decision=approve`）。
 *
 * OP セッションの確認は呼び出し側の責務で、この関数はセッションから確定した
 * subject を受け取り、レコードの subject との一致・CSRF 一致・期限内・pending で
 * あることを検証する。`approvedScope` は要求 scope をそのまま採用する
 * （本 OP の UI は scope の部分承認を提供しない）。`grantId` は呼び出し側が
 * 発行して渡し、既存の revocation 機構が grant 単位失効をそのまま適用できる
 * ようにする。
 *
 * @throws {CibaVerificationError} 403（不存在・期限切れ・subject 不一致・
 *   CSRF 不一致・既決定のいずれも同一文言）
 */
export async function approveCibaRequest(input: {
  authReqId: string;
  /** OP セッションから確定した subject。レコードと不一致なら拒否。 */
  subject: string;
  csrfToken: string;
  /** 承認時刻として ID トークンの auth_time に載る値（epoch 秒）。 */
  authTime: number;
  grantId: string;
  store: CibaAuthenticationRequestStore;
  now?: Date;
}): Promise<CibaAuthenticationRequestRecord> {
  const record = await resolveApprovableRecord(input);
  record.status = 'approved';
  record.authTime = input.authTime;
  record.approvedScope = [...record.scope];
  record.grantId = input.grantId;
  // 承認後は CSRF トークンは用済み。承認 / 拒否は一方向遷移なので、残して
  // おく理由がない値をレコードから落とす。
  record.csrfToken = null;
  await input.store.update(record);
  return record;
}

/**
 * 拒否（`POST /ciba/approve` の `decision=deny`）。
 *
 * @throws {CibaVerificationError} 403
 */
export async function denyCibaRequest(input: {
  authReqId: string;
  subject: string;
  csrfToken: string;
  store: CibaAuthenticationRequestStore;
  now?: Date;
}): Promise<void> {
  const record = await resolveApprovableRecord(input);
  record.status = 'denied';
  record.csrfToken = null;
  await input.store.update(record);
}

/**
 * 承認 / 拒否の共通検証。失敗はすべて同一文言の 403 に落とす。
 *
 * @throws {CibaVerificationError} 403
 */
async function resolveApprovableRecord(input: {
  authReqId: string;
  subject: string;
  csrfToken: string;
  store: CibaAuthenticationRequestStore;
  now?: Date;
}): Promise<CibaAuthenticationRequestRecord> {
  const reject: () => never = () => {
    throw new CibaVerificationError(INVALID_APPROVAL_MESSAGE, 403);
  };
  const record = await input.store.findByAuthReqId(input.authReqId);
  if (record === null) reject();
  const now = input.now ?? new Date();
  if (now.getTime() >= record.expiresAt.getTime()) reject();
  // 承認 / 拒否は一方向遷移。approved / denied になったレコードは UI から
  // 再度操作できない。
  if (record.status !== 'pending') reject();
  if (record.subject !== input.subject) reject();
  if (
    record.csrfToken === null ||
    input.csrfToken === '' ||
    input.csrfToken !== record.csrfToken
  ) {
    reject();
  }
  return record;
}
```

### ciba-grant.ts (the token endpoint state machine)

`processCibaGrant` is the CIBA branch of the token endpoint, evaluating the §11 state machine.
Before the state machine runs, `validateCibaGrantAllowed` verifies that the client's registered `grant_types` still include the CIBA URN (`unauthorized_client` per RFC 6749 §5.2).
The backchannel endpoint performs the same check when it accepts the request, but a check at acceptance time alone cannot cover a registration that drops CIBA between issuing the `auth_req_id` and redeeming it; the Device Flow guards redemption the same way with `validateDeviceCodeGrantAllowed`.
The evaluation order matches the Device Flow implementation, with expiry checked before polling pace: raising the interval of an expired record would be pointless, and the client should learn the flow ended.

`lastPolledAt` is updated on exactly two paths, `slow_down` and `authorization_pending`; every other outcome deletes or consumes the record, leaving nothing to update.
A `denied` record is deleted together with the `access_denied` delivery, so a further poll answers `invalid_grant` — per §11 the client ends the flow on either error, so interoperability is unaffected.
An `approved` record is collected through the atomic `consume`, so of concurrent redemptions exactly one wins.

```typescript
/**
 * OpenID Connect Client-Initiated Backchannel Authentication (CIBA) Core 1.0 —
 * Poll モード、§10.1 / §11（トークンエンドポイント）
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * トークンエンドポイントの grant 分岐に載る状態機械。生成コードは core の
 * `validateGrantTypeSupported` より前でこれを呼び、分岐内で応答を返し切る。
 */
import type { TokenClientInfo } from '@maronn-openid-connect/core';
import { CibaGrantError } from './errors.js';
import { CIBA_GRANT_TYPE } from './store.js';
import type {
  CibaAuthenticationRequestRecord,
  CibaAuthenticationRequestStore,
} from './store.js';

/** CIBA §11: slow_down のたびにサーバー側も interval を +5 秒する。 */
export const SLOW_DOWN_INTERVAL_INCREMENT = 5;

/**
 * auth_req_id の実在性を漏らさないための単一文言。
 *
 * 「レコードが無い」「他クライアントの auth_req_id」を同じ文言にすることで
 * （CIBA §11 "invalid or was issued to another Client"）、攻撃者が他クライアントの
 * auth_req_id の実在を確かめられないようにする。
 */
const INVALID_AUTH_REQ_ID_MESSAGE =
  'The auth_req_id is invalid, expired, or was issued to another client';

/** 承認済みレコードから確定した、トークン発行に必要な情報。 */
export interface CibaGrantResult {
  subject: string;
  clientId: string;
  scope: string[];
  authTime: number;
  grantId: string;
}

/**
 * トークンエンドポイントの CIBA 分岐（CIBA §10.1 / §11、Poll モード）。
 *
 * 状態機械の判定順序（上から評価し、最初に該当したものを返す）:
 *
 * 1. CIBA grant 未登録クライアント → `unauthorized_client`（RFC 6749 §5.2。
 *    バックチャネル受付後に登録から CIBA が外れたクライアントの償還を拒否する。
 *    device-authorization-grant の `validateDeviceCodeGrantAllowed` と同順）
 * 2. `auth_req_id` 欠落 → `invalid_request`
 * 3. レコード不存在・クライアント不一致 → `invalid_grant`（同一文言・レコードは残す）
 * 4. 期限切れ → `expired_token`（レコード削除）
 * 5. ポーリング過速 → `slow_down`（interval を +5 して保存）
 * 6. pending → `authorization_pending`（lastPolledAt 更新）
 * 7. denied → `access_denied`（レコード削除。再ポーリングは invalid_grant）
 * 8. approved → 結果を返す（レコードは consume で単回使用にする）
 *
 * 期限切れをポーリング過速より先に評価するのは、期限切れレコードの interval を
 * 増やしても意味がなく、クライアントへはフロー終了を伝えるべきだから。
 * `lastPolledAt` の更新は slow_down と authorization_pending の 2 経路のみ
 * （他の結果はレコードを削除または consume するため更新対象が残らない）。
 *
 * 過剰ポーリングへ `invalid_request` を返す選択肢（§11 の MAY）は採らず、
 * device-authorization-grant と同じ slow_down 方式に統一する。
 *
 * @throws {CibaGrantError}
 */
export async function processCibaGrant(input: {
  params: Record<string, string>;
  /** 認証済みクライアント（分岐前の共有認証パイプラインが解決したもの）。 */
  client: TokenClientInfo;
  store: CibaAuthenticationRequestStore;
  now?: Date;
}): Promise<CibaGrantResult> {
  validateCibaGrantAllowed(input.client);
  const record = await resolveCibaRecord(input.params, input.client, input.store);
  return evaluateCibaState(record, input.store, input.now ?? new Date());
}

/**
 * クライアントが CIBA grant を許可されているかを償還時にも検証する。
 *
 * バックチャネルエンドポイントは受付時に同じ検査を行うが、auth_req_id の発行から
 * 償還までの間に登録から CIBA が外れることがある（RFC 6749 §5.2 の
 * unauthorized_client）。device-authorization-grant の
 * `validateDeviceCodeGrantAllowed` と同じ位置づけの検査。
 *
 * @throws {CibaGrantError} unauthorized_client
 */
export function validateCibaGrantAllowed(client: TokenClientInfo): void {
  if (!(client.grantTypes ?? []).includes(CIBA_GRANT_TYPE)) {
    throw new CibaGrantError(
      'unauthorized_client',
      'The client is not authorized to use the CIBA grant',
    );
  }
}

/**
 * `auth_req_id` パラメータを取り出し、発行先クライアントのレコードを解決する。
 *
 * @throws {CibaGrantError} invalid_request / invalid_grant
 */
async function resolveCibaRecord(
  params: Record<string, string>,
  client: TokenClientInfo,
  store: CibaAuthenticationRequestStore,
): Promise<CibaAuthenticationRequestRecord> {
  const authReqId = params['auth_req_id'];
  if (authReqId === undefined || authReqId === '') {
    throw new CibaGrantError('invalid_request', 'Missing required parameter: auth_req_id');
  }
  const record = await store.findByAuthReqId(authReqId);
  if (record === null || record.clientId !== client.clientId) {
    throw new CibaGrantError('invalid_grant', INVALID_AUTH_REQ_ID_MESSAGE);
  }
  return record;
}

/**
 * CIBA §11 の状態機械を評価する。
 *
 * @throws {CibaGrantError} §11 の各状態
 */
async function evaluateCibaState(
  record: CibaAuthenticationRequestRecord,
  store: CibaAuthenticationRequestStore,
  now: Date,
): Promise<CibaGrantResult> {
  if (now.getTime() >= record.expiresAt.getTime()) {
    await store.delete(record.authReqId);
    throw new CibaGrantError(
      'expired_token',
      'The auth_req_id has expired. Start a new backchannel authentication request.',
    );
  }

  if (
    record.lastPolledAt !== null &&
    now.getTime() - record.lastPolledAt.getTime() < record.interval * 1000
  ) {
    // CIBA §11: "the interval MUST be increased by at least 5 seconds for this
    // and all subsequent requests" — サーバー側も新しい間隔を強制する。
    record.interval += SLOW_DOWN_INTERVAL_INCREMENT;
    record.lastPolledAt = now;
    await store.update(record);
    throw new CibaGrantError(
      'slow_down',
      'Polling too frequently. Increase the interval by 5 seconds.',
    );
  }

  if (record.status === 'pending') {
    record.lastPolledAt = now;
    await store.update(record);
    throw new CibaGrantError(
      'authorization_pending',
      'The authentication request is still pending',
    );
  }

  if (record.status === 'denied') {
    await store.delete(record.authReqId);
    throw new CibaGrantError('access_denied', 'The end-user denied the authentication request');
  }

  // approved: 単回使用を強制するため atomic な consume で回収する。並行
  // リデンプションでは先勝ちの 1 本だけがトークンを得て、後続は record が
  // null になり invalid_grant。
  const consumed = await store.consume(record.authReqId);
  if (
    consumed === null ||
    consumed.status !== 'approved' ||
    consumed.authTime === undefined ||
    consumed.grantId === undefined
  ) {
    throw new CibaGrantError('invalid_grant', INVALID_AUTH_REQ_ID_MESSAGE);
  }

  return {
    subject: consumed.subject,
    clientId: consumed.clientId,
    scope: consumed.approvedScope ?? consumed.scope,
    authTime: consumed.authTime,
    grantId: consumed.grantId,
  };
}
```

### index.ts (public API)

The public surface of the subpath export `@maronn-openid-connect/experimental/ciba`.
Nothing is re-exported from the package root (`.`).

```typescript
/**
 * EXPERIMENTAL — OpenID Connect Client-Initiated Backchannel Authentication
 * (CIBA) Core 1.0, Poll モード。
 *
 * ユーザーが操作していないデバイス（店頭端末・コールセンターのオペレーター画面・
 * スマートスピーカー等）が、ユーザー識別ヒント（login_hint）だけを添えて OP に
 * バックチャネルで認証を依頼し、ユーザーは自分の手元のブラウザで承認する。
 * 依頼したデバイスはトークンエンドポイントをポーリングしてトークンを受け取る。
 *
 * この package の API は安定していない。破壊的変更があり得るため、production で
 * 使う場合はバージョンを固定すること。
 */
export {
  CIBA_GRANT_TYPE,
  CIBA_LOGIN_TRANSACTION_TTL_SECONDS,
  createInMemoryCibaAuthenticationRequestStore,
  createInMemoryCibaLoginTransactionStore,
} from './store.js';
export type {
  CibaAuthenticationRequestRecord,
  CibaAuthenticationRequestStore,
  CibaLoginTransactionRecord,
  CibaLoginTransactionStore,
  CibaStatus,
} from './store.js';

export {
  BackchannelAuthenticationError,
  CibaGrantError,
  CibaVerificationError,
} from './errors.js';
export type {
  BackchannelAuthenticationErrorCode,
  CibaGrantErrorCode,
} from './errors.js';

export {
  BINDING_MESSAGE_MAX_LENGTH,
  processBackchannelAuthenticationRequest,
} from './backchannel-authentication-request.js';
export type {
  BackchannelAuthenticationResponse,
  CibaClientInfo,
  CibaConfig,
  CibaUserResolver,
} from './backchannel-authentication-request.js';

export {
  approveCibaRequest,
  createCibaLoginTransaction,
  denyCibaRequest,
  listPendingCibaRequests,
  recordCibaLoginFailure,
  validateCibaLoginSubmission,
} from './verification.js';

export {
  SLOW_DOWN_INTERVAL_INCREMENT,
  processCibaGrant,
  validateCibaGrantAllowed,
} from './ciba-grant.js';
export type { CibaGrantResult } from './ciba-grant.js';
```

## The unit tests in full

The 90 test cases pin the specification's test plan: happy paths, boundary values, the error vocabulary, oracle prevention, every state-machine transition, and single-use consume.

### test-helpers.ts (test-only fixtures)

A record factory and a client factory shared inside the feature.
The tsconfig excludes the file from dist, so it never ships in the published package.

```typescript
/**
 * テスト専用のフィクスチャ。tsconfig の exclude で dist から除外している。
 *
 * 複数のテストファイルが同じレコード工場とクライアント工場を必要とするため、
 * 機能内で共有する（experimental 機能を跨いだ共通化はしない）。
 */
import type { CibaClientInfo } from './backchannel-authentication-request.js';
import type { CibaAuthenticationRequestRecord } from './store.js';

/** テスト内で時刻を固定するための基準時刻。 */
export const NOW = new Date('2026-09-02T00:00:00.000Z');

/** 既定値つきのレコード工場。上書きしたいフィールドだけ渡す。 */
export function makeRecord(
  overrides: Partial<CibaAuthenticationRequestRecord> = {},
): CibaAuthenticationRequestRecord {
  return {
    authReqId: 'auth-req-id-value',
    clientId: 'ciba-client',
    subject: 'testuser',
    scope: ['openid'],
    status: 'pending',
    createdAt: NOW,
    expiresAt: new Date(NOW.getTime() + 120_000),
    interval: 5,
    lastPolledAt: null,
    csrfToken: null,
    ...overrides,
  };
}

/** 既定値つきのクライアント工場。CIBA grant 登録済みの confidential client。 */
export function makeClient(overrides: Partial<CibaClientInfo> = {}): CibaClientInfo {
  return {
    clientId: 'ciba-client',
    clientSecret: 'secret',
    grantTypes: ['urn:openid:params:grant-type:ciba'],
    tokenEndpointAuthMethod: 'client_secret_post',
    ...overrides,
  };
}
```

### store.test.ts

Pins the in-memory store contracts, notably single-use consume (of concurrent consumes exactly one is non-null) and the `listPendingBySubject` filter (decided and expired records excluded).

```typescript
import { describe, expect, it } from 'vitest';
import {
  createInMemoryCibaAuthenticationRequestStore,
  createInMemoryCibaLoginTransactionStore,
} from './store.js';
import { makeRecord } from './test-helpers.js';

describe('createInMemoryCibaAuthenticationRequestStore', () => {
  it('should find a saved record by auth_req_id', async () => {
    const store = createInMemoryCibaAuthenticationRequestStore();
    await store.save(makeRecord({ expiresAt: future() }));

    expect((await store.findByAuthReqId('auth-req-id-value'))?.clientId).toBe('ciba-client');
  });

  it('should return null for an unknown auth_req_id', async () => {
    const store = createInMemoryCibaAuthenticationRequestStore();

    expect(await store.findByAuthReqId('unknown')).toBe(null);
  });

  describe('consume (single use, CIBA Section 11)', () => {
    it('should return the record exactly once', async () => {
      const store = createInMemoryCibaAuthenticationRequestStore();
      await store.save(makeRecord({ expiresAt: future() }));

      const first = await store.consume('auth-req-id-value');
      const second = await store.consume('auth-req-id-value');

      expect(first?.authReqId).toBe('auth-req-id-value');
      expect(second).toBe(null);
    });

    it('should hand the record to only one concurrent consumer', async () => {
      const store = createInMemoryCibaAuthenticationRequestStore();
      await store.save(makeRecord({ expiresAt: future() }));

      const results = await Promise.all([
        store.consume('auth-req-id-value'),
        store.consume('auth-req-id-value'),
        store.consume('auth-req-id-value'),
      ]);

      expect(results.filter((record) => record !== null).length).toBe(1);
    });
  });

  describe('listPendingBySubject', () => {
    it('should exclude records that are decided or expired', async () => {
      const store = createInMemoryCibaAuthenticationRequestStore();
      await store.save(makeRecord({ authReqId: 'live', expiresAt: future() }));
      await store.save(makeRecord({ authReqId: 'approved', status: 'approved', expiresAt: future() }));
      await store.save(makeRecord({
        authReqId: 'expired',
        expiresAt: new Date(Date.now() - 1_000),
      }));

      const pending = await store.listPendingBySubject('testuser');

      expect(pending.map((record) => record.authReqId)).toEqual(['live']);
    });
  });
});

describe('createInMemoryCibaLoginTransactionStore', () => {
  it('should save, find, update and delete a transaction', async () => {
    const store = createInMemoryCibaLoginTransactionStore();
    const record = {
      id: 'txn-1',
      csrfToken: 'csrf',
      bindingHash: 'hash',
      loginAttempts: 0,
      expiresAt: future(),
    };
    await store.save(record);
    expect((await store.findById('txn-1'))?.csrfToken).toBe('csrf');

    record.loginAttempts = 2;
    await store.update(record);
    expect((await store.findById('txn-1'))?.loginAttempts).toBe(2);

    await store.delete('txn-1');
    expect(await store.findById('txn-1')).toBe(null);
  });
});

function future(): Date {
  return new Date(Date.now() + 120_000);
}
```

### backchannel-authentication-request.test.ts

43 cases for the backchannel authentication endpoint: the three response fields and the `auth_req_id` entropy (256 bits = 43 Base64URL characters), client validation (public client / unregistered grant / ping and push registrations), the hint rule, scope normalization and the offline_access policy, the `binding_message` boundaries (100 characters accepted, 101 rejected, control characters rejected), `requested_expiry` clamping and rejection, the fixed `unknown_user_id` wording (indistinguishable from a throwing resolver), and the pending cap.

```typescript
import { describe, expect, it } from 'vitest';
import {
  BINDING_MESSAGE_MAX_LENGTH,
  processBackchannelAuthenticationRequest,
} from './backchannel-authentication-request.js';
import { BackchannelAuthenticationError } from './errors.js';
import { createInMemoryCibaAuthenticationRequestStore } from './store.js';
import { makeClient, makeRecord } from './test-helpers.js';

function makeInput(
  overrides: Partial<Parameters<typeof processBackchannelAuthenticationRequest>[0]> = {},
) {
  return {
    params: { scope: 'openid', login_hint: 'testuser' },
    client: makeClient(),
    store: createInMemoryCibaAuthenticationRequestStore(),
    config: { authReqIdExpiresIn: 120, pollingInterval: 5, maxPendingPerSubject: 10 },
    refreshTokenFeatureEnabled: true,
    resolveUser: (loginHint: string) =>
      loginHint === 'testuser' ? { subject: 'testuser' } : null,
    ...overrides,
  };
}

async function expectError(
  input: Parameters<typeof processBackchannelAuthenticationRequest>[0],
  code: string,
): Promise<BackchannelAuthenticationError> {
  try {
    await processBackchannelAuthenticationRequest(input);
  } catch (error) {
    expect(error).toBeInstanceOf(BackchannelAuthenticationError);
    const typed = error as BackchannelAuthenticationError;
    expect(typed.code).toBe(code);
    expect(typed.statusCode).toBe(400);
    return typed;
  }
  throw new Error('expected processBackchannelAuthenticationRequest to throw');
}

describe('processBackchannelAuthenticationRequest', () => {
  describe('Success response (CIBA Section 7.3)', () => {
    it('should return auth_req_id, expires_in and interval for a minimal request', async () => {
      const result = await processBackchannelAuthenticationRequest(makeInput());

      expect(result.expires_in).toBe(120);
      expect(result.interval).toBe(5);
      expect(typeof result.auth_req_id).toBe('string');
    });

    // CIBA Section 7.3: at least 128 bits of entropy; this implementation mints
    // 256 bits (32 bytes), which Base64URL-encodes to 43 characters.
    it('should mint a 256-bit auth_req_id in the Base64URL character set', async () => {
      const result = await processBackchannelAuthenticationRequest(makeInput());

      expect(result.auth_req_id.length).toBe(43);
      expect(/^[A-Za-z0-9_-]{43}$/.test(result.auth_req_id)).toBe(true);
    });

    it('should issue a distinct auth_req_id for every request', async () => {
      const input = makeInput();
      const first = await processBackchannelAuthenticationRequest(input);
      const second = await processBackchannelAuthenticationRequest(input);

      expect(first.auth_req_id === second.auth_req_id).toBe(false);
    });

    it('should save a pending record carrying the resolved subject and scope', async () => {
      const store = createInMemoryCibaAuthenticationRequestStore();
      const result = await processBackchannelAuthenticationRequest(makeInput({ store }));
      const record = await store.findByAuthReqId(result.auth_req_id);

      expect(record).toMatchObject({
        clientId: 'ciba-client',
        subject: 'testuser',
        scope: ['openid'],
        status: 'pending',
        interval: 5,
        lastPolledAt: null,
        csrfToken: null,
      });
    });

    it('should store the validated binding_message on the record', async () => {
      const store = createInMemoryCibaAuthenticationRequestStore();
      const result = await processBackchannelAuthenticationRequest(makeInput({
        store,
        params: { scope: 'openid', login_hint: 'testuser', binding_message: 'AB-123' },
      }));
      const record = await store.findByAuthReqId(result.auth_req_id);

      expect(record?.bindingMessage).toBe('AB-123');
    });

    it('should store acr_values as advisory data on the record', async () => {
      const store = createInMemoryCibaAuthenticationRequestStore();
      const result = await processBackchannelAuthenticationRequest(makeInput({
        store,
        params: { scope: 'openid', login_hint: 'testuser', acr_values: 'urn:example:loa:2' },
      }));
      const record = await store.findByAuthReqId(result.auth_req_id);

      expect(record?.acrValues).toBe('urn:example:loa:2');
    });

    // CIBA Section 7.1: "The server MAY use this value" — this implementation
    // clamps requested_expiry into [30, authReqIdExpiresIn].
    it('should honor a requested_expiry inside the allowed range', async () => {
      const result = await processBackchannelAuthenticationRequest(makeInput({
        params: { scope: 'openid', login_hint: 'testuser', requested_expiry: '60' },
      }));

      expect(result.expires_in).toBe(60);
    });

    it('should clamp requested_expiry below 30 up to 30', async () => {
      const result = await processBackchannelAuthenticationRequest(makeInput({
        params: { scope: 'openid', login_hint: 'testuser', requested_expiry: '5' },
      }));

      expect(result.expires_in).toBe(30);
    });

    it('should clamp requested_expiry above the configured lifetime down to it', async () => {
      const result = await processBackchannelAuthenticationRequest(makeInput({
        params: { scope: 'openid', login_hint: 'testuser', requested_expiry: '999999' },
      }));

      expect(result.expires_in).toBe(120);
    });

    it('should set expiresAt from the injected now and the clamped expiry', async () => {
      const store = createInMemoryCibaAuthenticationRequestStore();
      const now = new Date('2026-09-02T00:00:00.000Z');
      const result = await processBackchannelAuthenticationRequest(makeInput({
        store,
        now,
        params: { scope: 'openid', login_hint: 'testuser', requested_expiry: '60' },
      }));
      const record = await store.findByAuthReqId(result.auth_req_id);

      expect(record?.createdAt).toEqual(now);
      expect(record?.expiresAt).toEqual(new Date(now.getTime() + 60_000));
    });

    // CIBA Section 7.1: client_notification_token is only meaningful for the
    // Ping / Push modes this implementation does not offer, and user_code is
    // not supported (backchannel_user_code_parameter_supported defaults false).
    it('should ignore client_notification_token and user_code', async () => {
      const result = await processBackchannelAuthenticationRequest(makeInput({
        params: {
          scope: 'openid',
          login_hint: 'testuser',
          client_notification_token: 'notify-me',
          user_code: '1234',
        },
      }));

      expect(result.expires_in).toBe(120);
    });

    // RFC 6749 Section 3.1: unrecognized parameters are ignored.
    it('should ignore unknown parameters', async () => {
      const result = await processBackchannelAuthenticationRequest(makeInput({
        params: { scope: 'openid', login_hint: 'testuser', unknown_param: 'x' },
      }));

      expect(result.expires_in).toBe(120);
    });
  });

  describe('Client validation', () => {
    // CIBA Section 7.1 requires client authentication, which auth method 'none'
    // can never satisfy — a deliberate profile restriction on public clients.
    it('should reject a public client (auth method none) with unauthorized_client', async () => {
      const error = await expectError(
        makeInput({ client: makeClient({ tokenEndpointAuthMethod: 'none', clientSecret: undefined }) }),
        'unauthorized_client',
      );

      expect(error.errorDescription).toBe(
        'Public clients are not allowed to use the CIBA grant type',
      );
    });

    it('should reject a client that did not register the CIBA grant', async () => {
      const error = await expectError(
        makeInput({ client: makeClient({ grantTypes: ['authorization_code'] }) }),
        'unauthorized_client',
      );

      expect(error.errorDescription).toBe(
        'The client is not authorized to use the CIBA grant',
      );
    });

    it('should treat missing grantTypes as the authorization_code default and reject', async () => {
      await expectError(
        makeInput({ client: makeClient({ grantTypes: undefined }) }),
        'unauthorized_client',
      );
    });

    // This OP only offers Poll delivery, so a client registered for ping or
    // push cannot be served (CIBA Section 4 advertises ['poll'] only).
    it('should reject a client registered for the ping delivery mode', async () => {
      const error = await expectError(
        makeInput({ client: makeClient({ backchannelTokenDeliveryMode: 'ping' }) }),
        'unauthorized_client',
      );

      expect(error.errorDescription).toBe(
        'This provider only supports the poll token delivery mode',
      );
    });

    it('should reject a client registered for the push delivery mode', async () => {
      await expectError(
        makeInput({ client: makeClient({ backchannelTokenDeliveryMode: 'push' }) }),
        'unauthorized_client',
      );
    });

    it('should accept a client explicitly registered for poll', async () => {
      const result = await processBackchannelAuthenticationRequest(
        makeInput({ client: makeClient({ backchannelTokenDeliveryMode: 'poll' }) }),
      );

      expect(typeof result.auth_req_id).toBe('string');
    });
  });

  describe('Hint validation (CIBA Section 7.1 / 7.2)', () => {
    it('should reject a request with no hint', async () => {
      const error = await expectError(
        makeInput({ params: { scope: 'openid' } }),
        'invalid_request',
      );

      expect(error.errorDescription).toBe(
        'Exactly one of login_hint, id_token_hint or login_hint_token is required',
      );
    });

    it('should reject a request with two hints', async () => {
      const error = await expectError(
        makeInput({ params: { scope: 'openid', login_hint: 'testuser', id_token_hint: 'x' } }),
        'invalid_request',
      );

      expect(error.errorDescription).toBe(
        'Exactly one of login_hint, id_token_hint or login_hint_token is required',
      );
    });

    // id_token_hint / login_hint_token are outside this feature's initial
    // scope; presenting one alone is a malformed request, not unknown_user_id.
    it('should reject id_token_hint alone as an unsupported hint type', async () => {
      const error = await expectError(
        makeInput({ params: { scope: 'openid', id_token_hint: 'x' } }),
        'invalid_request',
      );

      expect(error.errorDescription).toBe(
        'Only login_hint is supported by this provider',
      );
    });

    it('should reject login_hint_token alone as an unsupported hint type', async () => {
      const error = await expectError(
        makeInput({ params: { scope: 'openid', login_hint_token: 'x' } }),
        'invalid_request',
      );

      expect(error.errorDescription).toBe(
        'Only login_hint is supported by this provider',
      );
    });

    it('should treat an empty login_hint as absent', async () => {
      await expectError(
        makeInput({ params: { scope: 'openid', login_hint: '' } }),
        'invalid_request',
      );
    });

    // CIBA Section 7.1.1: signed authentication requests are not supported.
    it('should reject a request parameter (signed authentication request)', async () => {
      const error = await expectError(
        makeInput({ params: { scope: 'openid', login_hint: 'testuser', request: 'ey.x.y' } }),
        'invalid_request',
      );

      expect(error.errorDescription).toBe(
        'Signed authentication requests are not supported',
      );
    });
  });

  describe('Scope validation', () => {
    it('should reject a missing scope', async () => {
      const error = await expectError(
        makeInput({ params: { login_hint: 'testuser' } }),
        'invalid_request',
      );

      expect(error.errorDescription).toBe('Missing required parameter: scope');
    });

    it('should reject a scope without openid', async () => {
      const error = await expectError(
        makeInput({ params: { scope: 'profile', login_hint: 'testuser' } }),
        'invalid_scope',
      );

      expect(error.errorDescription).toBe('The openid scope is required');
    });

    it('should normalize whitespace and deduplicate scope values', async () => {
      const store = createInMemoryCibaAuthenticationRequestStore();
      const result = await processBackchannelAuthenticationRequest(makeInput({
        store,
        params: { scope: '  openid  profile openid ', login_hint: 'testuser' },
      }));
      const record = await store.findByAuthReqId(result.auth_req_id);

      expect(record?.scope).toEqual(['openid', 'profile']);
    });

    // OIDC Core 1.0 Section 11: offline_access that could never be granted is
    // dropped silently rather than rejected.
    it('should drop offline_access when the refresh-token feature is disabled', async () => {
      const store = createInMemoryCibaAuthenticationRequestStore();
      const result = await processBackchannelAuthenticationRequest(makeInput({
        store,
        refreshTokenFeatureEnabled: false,
        client: makeClient({
          grantTypes: ['urn:openid:params:grant-type:ciba', 'refresh_token'],
        }),
        params: { scope: 'openid offline_access', login_hint: 'testuser' },
      }));
      const record = await store.findByAuthReqId(result.auth_req_id);

      expect(record?.scope).toEqual(['openid']);
    });

    it('should drop offline_access when the client did not register refresh_token', async () => {
      const store = createInMemoryCibaAuthenticationRequestStore();
      const result = await processBackchannelAuthenticationRequest(makeInput({
        store,
        refreshTokenFeatureEnabled: true,
        params: { scope: 'openid offline_access', login_hint: 'testuser' },
      }));
      const record = await store.findByAuthReqId(result.auth_req_id);

      expect(record?.scope).toEqual(['openid']);
    });

    it('should keep offline_access when the feature and registration both allow it', async () => {
      const store = createInMemoryCibaAuthenticationRequestStore();
      const result = await processBackchannelAuthenticationRequest(makeInput({
        store,
        refreshTokenFeatureEnabled: true,
        client: makeClient({
          grantTypes: ['urn:openid:params:grant-type:ciba', 'refresh_token'],
        }),
        params: { scope: 'openid offline_access', login_hint: 'testuser' },
      }));
      const record = await store.findByAuthReqId(result.auth_req_id);

      expect(record?.scope).toEqual(['openid', 'offline_access']);
    });
  });

  describe('binding_message validation (CIBA Section 7.1)', () => {
    it('should accept a binding message of exactly the maximum length', async () => {
      const store = createInMemoryCibaAuthenticationRequestStore();
      const message = 'a'.repeat(BINDING_MESSAGE_MAX_LENGTH);
      const result = await processBackchannelAuthenticationRequest(makeInput({
        store,
        params: { scope: 'openid', login_hint: 'testuser', binding_message: message },
      }));
      const record = await store.findByAuthReqId(result.auth_req_id);

      expect(record?.bindingMessage).toBe(message);
    });

    it('should reject a binding message longer than the maximum', async () => {
      const error = await expectError(
        makeInput({
          params: {
            scope: 'openid',
            login_hint: 'testuser',
            binding_message: 'a'.repeat(BINDING_MESSAGE_MAX_LENGTH + 1),
          },
        }),
        'invalid_binding_message',
      );

      expect(error.errorDescription).toBe(
        'binding_message must be 1 to 100 characters without control characters',
      );
    });

    it('should reject an empty binding message', async () => {
      await expectError(
        makeInput({
          params: { scope: 'openid', login_hint: 'testuser', binding_message: '' },
        }),
        'invalid_binding_message',
      );
    });

    it('should reject a binding message containing control characters', async () => {
      await expectError(
        makeInput({
          params: { scope: 'openid', login_hint: 'testuser', binding_message: 'ok\nline' },
        }),
        'invalid_binding_message',
      );
    });
  });

  describe('requested_expiry validation', () => {
    it('should reject a non-integer requested_expiry', async () => {
      const error = await expectError(
        makeInput({
          params: { scope: 'openid', login_hint: 'testuser', requested_expiry: '12.5' },
        }),
        'invalid_request',
      );

      expect(error.errorDescription).toBe(
        'requested_expiry must be a positive integer',
      );
    });

    it('should reject zero', async () => {
      await expectError(
        makeInput({
          params: { scope: 'openid', login_hint: 'testuser', requested_expiry: '0' },
        }),
        'invalid_request',
      );
    });

    it('should reject a negative value', async () => {
      await expectError(
        makeInput({
          params: { scope: 'openid', login_hint: 'testuser', requested_expiry: '-5' },
        }),
        'invalid_request',
      );
    });

    it('should reject a non-numeric value', async () => {
      await expectError(
        makeInput({
          params: { scope: 'openid', login_hint: 'testuser', requested_expiry: 'soon' },
        }),
        'invalid_request',
      );
    });
  });

  describe('User resolution (CIBA Section 13 unknown_user_id)', () => {
    it('should reject an unresolvable login_hint with unknown_user_id', async () => {
      const error = await expectError(
        makeInput({ params: { scope: 'openid', login_hint: 'nobody' } }),
        'unknown_user_id',
      );

      expect(error.errorDescription).toBe(
        'The login_hint could not be matched to a user',
      );
    });

    // The resolver failing and the user not existing must not be
    // distinguishable, so the same fixed wording is used for both.
    it('should answer a throwing resolver with the same fixed wording', async () => {
      const error = await expectError(
        makeInput({
          resolveUser: () => {
            throw new Error('backend down');
          },
        }),
        'unknown_user_id',
      );

      expect(error.errorDescription).toBe(
        'The login_hint could not be matched to a user',
      );
    });

    it('should accept a resolver returning a promise', async () => {
      const result = await processBackchannelAuthenticationRequest(makeInput({
        resolveUser: async () => ({ subject: 'testuser' }),
      }));

      expect(typeof result.auth_req_id).toBe('string');
    });
  });

  describe('Pending request flood control', () => {
    it('should reject a request when the subject already has the maximum pending requests', async () => {
      const store = createInMemoryCibaAuthenticationRequestStore();
      for (let i = 0; i < 10; i++) {
        await store.save(makeRecord({
          authReqId: `pending-${i}`,
          expiresAt: new Date(Date.now() + 60_000),
        }));
      }

      const error = await expectError(makeInput({ store }), 'invalid_request');

      expect(error.errorDescription).toBe(
        'Too many pending authentication requests for this user',
      );
    });

    it('should count only the same subject toward the limit', async () => {
      const store = createInMemoryCibaAuthenticationRequestStore();
      for (let i = 0; i < 10; i++) {
        await store.save(makeRecord({
          authReqId: `pending-${i}`,
          subject: 'otheruser',
          expiresAt: new Date(Date.now() + 60_000),
        }));
      }

      const result = await processBackchannelAuthenticationRequest(makeInput({ store }));

      expect(typeof result.auth_req_id).toBe('string');
    });
  });
});
```

### verification.test.ts

25 cases for the UI step functions: login transaction minting (the raw secret never stored), the uniform failure wording of login validation, failure counting and deletion at the limit, CSRF issuance and rotation on the listing, and the subject binding of approve / deny.

```typescript
import { describe, expect, it } from 'vitest';
import { CibaVerificationError } from './errors.js';
import {
  approveCibaRequest,
  createCibaLoginTransaction,
  denyCibaRequest,
  listPendingCibaRequests,
  recordCibaLoginFailure,
  validateCibaLoginSubmission,
} from './verification.js';
import {
  createInMemoryCibaAuthenticationRequestStore,
  createInMemoryCibaLoginTransactionStore,
} from './store.js';
import { makeRecord } from './test-helpers.js';

async function expectVerificationError(action: () => Promise<unknown>): Promise<CibaVerificationError> {
  try {
    await action();
  } catch (error) {
    expect(error).toBeInstanceOf(CibaVerificationError);
    return error as CibaVerificationError;
  }
  throw new Error('expected a CibaVerificationError');
}

describe('createCibaLoginTransaction', () => {
  it('should mint a 256-bit id, csrf token and binding secret', async () => {
    const store = createInMemoryCibaLoginTransactionStore();
    const { record, bindingSecret } = await createCibaLoginTransaction(store);

    expect(record.id.length).toBe(43);
    expect(record.csrfToken.length).toBe(43);
    expect(bindingSecret.length).toBe(43);
  });

  it('should save the transaction with a 600 second lifetime and zero attempts', async () => {
    const store = createInMemoryCibaLoginTransactionStore();
    const before = Date.now();
    const { record } = await createCibaLoginTransaction(store);
    const saved = await store.findById(record.id);

    expect(saved?.loginAttempts).toBe(0);
    const lifetimeMs = (saved?.expiresAt.getTime() ?? 0) - before;
    expect(lifetimeMs >= 600_000 && lifetimeMs <= 601_000).toBe(true);
  });

  it('should store only the SHA-256 hash of the binding secret', async () => {
    const store = createInMemoryCibaLoginTransactionStore();
    const { record, bindingSecret } = await createCibaLoginTransaction(store);

    expect(record.bindingHash === bindingSecret).toBe(false);
    expect(record.bindingHash.length).toBe(43);
  });
});

describe('validateCibaLoginSubmission', () => {
  async function setup() {
    const store = createInMemoryCibaLoginTransactionStore();
    const { record, bindingSecret } = await createCibaLoginTransaction(store);
    return { store, record, bindingSecret };
  }

  it('should return the transaction when binding and csrf both match', async () => {
    const { store, record, bindingSecret } = await setup();

    const validated = await validateCibaLoginSubmission({
      transactionId: record.id,
      csrfToken: record.csrfToken,
      bindingSecret,
      store,
    });

    expect(validated.id).toBe(record.id);
  });

  it('should reject an unknown transaction id with 403', async () => {
    const { store, record, bindingSecret } = await setup();

    const error = await expectVerificationError(() =>
      validateCibaLoginSubmission({
        transactionId: 'unknown',
        csrfToken: record.csrfToken,
        bindingSecret,
        store,
      }),
    );

    expect(error.statusCode).toBe(403);
  });

  it('should reject an expired transaction with 403', async () => {
    const store = createInMemoryCibaLoginTransactionStore();
    const { record, bindingSecret } = await createCibaLoginTransaction(store);
    record.expiresAt = new Date(Date.now() - 1_000);
    await store.update(record);

    const error = await expectVerificationError(() =>
      validateCibaLoginSubmission({
        transactionId: record.id,
        csrfToken: record.csrfToken,
        bindingSecret,
        store,
      }),
    );

    expect(error.statusCode).toBe(403);
  });

  it('should reject a missing binding secret with 403', async () => {
    const { store, record } = await setup();

    const error = await expectVerificationError(() =>
      validateCibaLoginSubmission({
        transactionId: record.id,
        csrfToken: record.csrfToken,
        bindingSecret: null,
        store,
      }),
    );

    expect(error.statusCode).toBe(403);
  });

  it('should reject a wrong binding secret with 403', async () => {
    const { store, record } = await setup();

    const error = await expectVerificationError(() =>
      validateCibaLoginSubmission({
        transactionId: record.id,
        csrfToken: record.csrfToken,
        bindingSecret: 'forged-secret',
        store,
      }),
    );

    expect(error.statusCode).toBe(403);
  });

  it('should reject a wrong csrf token with 403', async () => {
    const { store, record, bindingSecret } = await setup();

    const error = await expectVerificationError(() =>
      validateCibaLoginSubmission({
        transactionId: record.id,
        csrfToken: 'forged',
        bindingSecret,
        store,
      }),
    );

    expect(error.statusCode).toBe(403);
  });

  it('should use the same message for every failure reason', async () => {
    const { store, record, bindingSecret } = await setup();

    const unknown = await expectVerificationError(() =>
      validateCibaLoginSubmission({
        transactionId: 'unknown',
        csrfToken: record.csrfToken,
        bindingSecret,
        store,
      }),
    );
    const forgedBinding = await expectVerificationError(() =>
      validateCibaLoginSubmission({
        transactionId: record.id,
        csrfToken: record.csrfToken,
        bindingSecret: 'forged',
        store,
      }),
    );
    const forgedCsrf = await expectVerificationError(() =>
      validateCibaLoginSubmission({
        transactionId: record.id,
        csrfToken: 'forged',
        bindingSecret,
        store,
      }),
    );

    expect(unknown.message).toBe(forgedBinding.message);
    expect(forgedBinding.message).toBe(forgedCsrf.message);
  });
});

describe('recordCibaLoginFailure', () => {
  it('should count a failure and allow retrying below the limit', async () => {
    const store = createInMemoryCibaLoginTransactionStore();
    const { record } = await createCibaLoginTransaction(store);

    const result = await recordCibaLoginFailure(record, store, 5);

    expect(result).toEqual({ canRetry: true, remainingAttempts: 4 });
    expect((await store.findById(record.id))?.loginAttempts).toBe(1);
  });

  it('should delete the transaction when the limit is reached', async () => {
    const store = createInMemoryCibaLoginTransactionStore();
    const { record } = await createCibaLoginTransaction(store);

    let result = { canRetry: true, remainingAttempts: 0 };
    for (let i = 0; i < 5; i++) {
      result = await recordCibaLoginFailure(record, store, 5);
    }

    expect(result).toEqual({ canRetry: false, remainingAttempts: 0 });
    expect(await store.findById(record.id)).toBe(null);
  });
});

describe('listPendingCibaRequests', () => {
  it('should return only pending requests of the given subject', async () => {
    const store = createInMemoryCibaAuthenticationRequestStore();
    await store.save(makeRecord({ authReqId: 'mine', subject: 'testuser', expiresAt: future() }));
    await store.save(makeRecord({ authReqId: 'other', subject: 'otheruser', expiresAt: future() }));
    await store.save(makeRecord({
      authReqId: 'mine-denied',
      subject: 'testuser',
      status: 'denied',
      expiresAt: future(),
    }));

    const listed = await listPendingCibaRequests({ subject: 'testuser', store });

    expect(listed.map((record) => record.authReqId)).toEqual(['mine']);
  });

  it('should mint and persist a csrf token for every listed record', async () => {
    const store = createInMemoryCibaAuthenticationRequestStore();
    await store.save(makeRecord({ authReqId: 'mine', expiresAt: future() }));

    const [listed] = await listPendingCibaRequests({ subject: 'testuser', store });
    const persisted = await store.findByAuthReqId('mine');

    expect(typeof listed?.csrfToken).toBe('string');
    expect(persisted?.csrfToken).toBe(listed?.csrfToken ?? null);
  });

  it('should rotate the csrf token on every listing', async () => {
    const store = createInMemoryCibaAuthenticationRequestStore();
    await store.save(makeRecord({ authReqId: 'mine', expiresAt: future() }));

    // 文字列を先に取り出す: インメモリストアは同一オブジェクトを返すため、
    // 参照のまま比較すると 2 回目の回転が 1 回目の値も上書きしてしまう。
    const first = (await listPendingCibaRequests({ subject: 'testuser', store }))[0]?.csrfToken;
    const second = (await listPendingCibaRequests({ subject: 'testuser', store }))[0]?.csrfToken;

    expect(first === second).toBe(false);
  });
});

describe('approveCibaRequest', () => {
  async function setupPending() {
    const store = createInMemoryCibaAuthenticationRequestStore();
    await store.save(makeRecord({ authReqId: 'mine', expiresAt: future() }));
    const [listed] = await listPendingCibaRequests({ subject: 'testuser', store });
    return { store, csrfToken: listed?.csrfToken ?? '' };
  }

  it('should move the record to approved with authTime, scope and grantId', async () => {
    const { store, csrfToken } = await setupPending();

    const approved = await approveCibaRequest({
      authReqId: 'mine',
      subject: 'testuser',
      csrfToken,
      authTime: 1_760_000_000,
      grantId: 'grant-1',
      store,
    });

    expect(approved).toMatchObject({
      status: 'approved',
      authTime: 1_760_000_000,
      approvedScope: ['openid'],
      grantId: 'grant-1',
      csrfToken: null,
    });
    expect((await store.findByAuthReqId('mine'))?.status).toBe('approved');
  });

  it('should reject an unknown auth_req_id with 403', async () => {
    const { store, csrfToken } = await setupPending();

    const error = await expectVerificationError(() =>
      approveCibaRequest({
        authReqId: 'unknown',
        subject: 'testuser',
        csrfToken,
        authTime: 1,
        grantId: 'g',
        store,
      }),
    );

    expect(error.statusCode).toBe(403);
  });

  it('should reject a session subject that does not own the record', async () => {
    const { store, csrfToken } = await setupPending();

    const error = await expectVerificationError(() =>
      approveCibaRequest({
        authReqId: 'mine',
        subject: 'otheruser',
        csrfToken,
        authTime: 1,
        grantId: 'g',
        store,
      }),
    );

    expect(error.statusCode).toBe(403);
    expect((await store.findByAuthReqId('mine'))?.status).toBe('pending');
  });

  it('should reject a wrong csrf token with 403', async () => {
    const { store } = await setupPending();

    const error = await expectVerificationError(() =>
      approveCibaRequest({
        authReqId: 'mine',
        subject: 'testuser',
        csrfToken: 'forged',
        authTime: 1,
        grantId: 'g',
        store,
      }),
    );

    expect(error.statusCode).toBe(403);
  });

  it('should reject a record whose csrf token was never issued', async () => {
    const store = createInMemoryCibaAuthenticationRequestStore();
    await store.save(makeRecord({ authReqId: 'mine', expiresAt: future() }));

    const error = await expectVerificationError(() =>
      approveCibaRequest({
        authReqId: 'mine',
        subject: 'testuser',
        csrfToken: '',
        authTime: 1,
        grantId: 'g',
        store,
      }),
    );

    expect(error.statusCode).toBe(403);
  });

  it('should reject an expired record with 403', async () => {
    const store = createInMemoryCibaAuthenticationRequestStore();
    await store.save(makeRecord({
      authReqId: 'mine',
      csrfToken: 'csrf',
      expiresAt: new Date(Date.now() - 1_000),
    }));

    const error = await expectVerificationError(() =>
      approveCibaRequest({
        authReqId: 'mine',
        subject: 'testuser',
        csrfToken: 'csrf',
        authTime: 1,
        grantId: 'g',
        store,
      }),
    );

    expect(error.statusCode).toBe(403);
  });

  it('should reject a record that was already decided', async () => {
    const store = createInMemoryCibaAuthenticationRequestStore();
    await store.save(makeRecord({
      authReqId: 'mine',
      status: 'denied',
      csrfToken: 'csrf',
      expiresAt: future(),
    }));

    const error = await expectVerificationError(() =>
      approveCibaRequest({
        authReqId: 'mine',
        subject: 'testuser',
        csrfToken: 'csrf',
        authTime: 1,
        grantId: 'g',
        store,
      }),
    );

    expect(error.statusCode).toBe(403);
  });

  it('should use one message for unknown, mismatched and decided records', async () => {
    const { store, csrfToken } = await setupPending();

    const unknown = await expectVerificationError(() =>
      approveCibaRequest({
        authReqId: 'unknown',
        subject: 'testuser',
        csrfToken,
        authTime: 1,
        grantId: 'g',
        store,
      }),
    );
    const wrongSubject = await expectVerificationError(() =>
      approveCibaRequest({
        authReqId: 'mine',
        subject: 'otheruser',
        csrfToken,
        authTime: 1,
        grantId: 'g',
        store,
      }),
    );

    expect(unknown.message).toBe(wrongSubject.message);
  });
});

describe('denyCibaRequest', () => {
  it('should move the record to denied and clear the csrf token', async () => {
    const store = createInMemoryCibaAuthenticationRequestStore();
    await store.save(makeRecord({ authReqId: 'mine', expiresAt: future() }));
    const [listed] = await listPendingCibaRequests({ subject: 'testuser', store });

    await denyCibaRequest({
      authReqId: 'mine',
      subject: 'testuser',
      csrfToken: listed?.csrfToken ?? '',
      store,
    });

    expect(await store.findByAuthReqId('mine')).toMatchObject({
      status: 'denied',
      csrfToken: null,
    });
  });

  it('should reject a session subject that does not own the record', async () => {
    const store = createInMemoryCibaAuthenticationRequestStore();
    await store.save(makeRecord({ authReqId: 'mine', expiresAt: future() }));
    const [listed] = await listPendingCibaRequests({ subject: 'testuser', store });

    const error = await expectVerificationError(() =>
      denyCibaRequest({
        authReqId: 'mine',
        subject: 'otheruser',
        csrfToken: listed?.csrfToken ?? '',
        store,
      }),
    );

    expect(error.statusCode).toBe(403);
    expect((await store.findByAuthReqId('mine'))?.status).toBe('pending');
  });
});

function future(): Date {
  return new Date(Date.now() + 120_000);
}
```

### ciba-grant.test.ts

20 cases for the token endpoint state machine: every transition (pending → `authorization_pending`; a poll inside the interval → `slow_down` with the persisted +5; denied → `access_denied` plus deletion; expired → `expired_token` plus deletion; approved → the issuance data), and `invalid_grant` for re-redemption after consume, presentation by another client, and missing approval context.
They also pin `validateCibaGrantAllowed` accepting and rejecting, and that a client whose registration dropped the CIBA grant is stopped with `unauthorized_client` before the state machine runs, leaving no state transition on the record.

```typescript
import { describe, expect, it } from 'vitest';
import { processCibaGrant, validateCibaGrantAllowed } from './ciba-grant.js';
import { CibaGrantError } from './errors.js';
import { createInMemoryCibaAuthenticationRequestStore } from './store.js';
import { NOW, makeClient, makeRecord } from './test-helpers.js';

function makeInput(
  overrides: Partial<Parameters<typeof processCibaGrant>[0]> = {},
) {
  return {
    params: { auth_req_id: 'auth-req-id-value' },
    client: makeClient(),
    store: createInMemoryCibaAuthenticationRequestStore(),
    now: NOW,
    ...overrides,
  };
}

async function expectGrantError(
  input: Parameters<typeof processCibaGrant>[0],
  code: string,
): Promise<CibaGrantError> {
  try {
    await processCibaGrant(input);
  } catch (error) {
    expect(error).toBeInstanceOf(CibaGrantError);
    const typed = error as CibaGrantError;
    expect(typed.code).toBe(code);
    expect(typed.statusCode).toBe(400);
    return typed;
  }
  throw new Error('expected processCibaGrant to throw');
}

describe('validateCibaGrantAllowed', () => {
  it('should accept a client registered for the CIBA grant', () => {
    expect(() => validateCibaGrantAllowed(makeClient())).not.toThrow();
  });

  // RFC 6749 §5.2: the authenticated client must be registered for the grant
  // type it presents. The backchannel endpoint already enforces this at
  // request time; the token endpoint must enforce it again at redemption time
  // (the registration can change between the two).
  it('should reject a client whose grantTypes omit the CIBA URN', () => {
    expect(() =>
      validateCibaGrantAllowed(makeClient({ grantTypes: ['authorization_code'] })),
    ).toThrowError(
      new CibaGrantError('unauthorized_client', 'The client is not authorized to use the CIBA grant'),
    );
  });

  it('should reject a client without grantTypes', () => {
    expect(() => validateCibaGrantAllowed(makeClient({ grantTypes: undefined }))).toThrowError(
      new CibaGrantError('unauthorized_client', 'The client is not authorized to use the CIBA grant'),
    );
  });
});

describe('processCibaGrant', () => {
  describe('Request validation (CIBA Section 10.1)', () => {
    it('should reject a client no longer registered for the CIBA grant before evaluating the record', async () => {
      const store = createInMemoryCibaAuthenticationRequestStore();
      await store.save(makeRecord());

      const error = await expectGrantError(
        makeInput({ store, client: makeClient({ grantTypes: ['authorization_code'] }) }),
        'unauthorized_client',
      );

      expect(error.errorDescription).toBe('The client is not authorized to use the CIBA grant');
      // The record is untouched: no state transition happened for the
      // deauthorized caller.
      const record = await store.findByAuthReqId('auth-req-id-value');
      expect(record).toMatchObject({ status: 'pending', lastPolledAt: null });
    });

    it('should reject a missing auth_req_id with invalid_request', async () => {
      const error = await expectGrantError(makeInput({ params: {} }), 'invalid_request');

      expect(error.errorDescription).toBe('Missing required parameter: auth_req_id');
    });

    it('should reject an empty auth_req_id with invalid_request', async () => {
      await expectGrantError(makeInput({ params: { auth_req_id: '' } }), 'invalid_request');
    });

    it('should reject an unknown auth_req_id with invalid_grant', async () => {
      const error = await expectGrantError(makeInput(), 'invalid_grant');

      expect(error.errorDescription).toBe(
        'The auth_req_id is invalid, expired, or was issued to another client',
      );
    });

    // CIBA Section 11: "invalid or was issued to another Client" share one
    // wording so a client cannot probe which auth_req_id values exist.
    it('should reject another client\'s auth_req_id with the same wording', async () => {
      const store = createInMemoryCibaAuthenticationRequestStore();
      await store.save(makeRecord());

      const error = await expectGrantError(
        makeInput({ store, client: makeClient({ clientId: 'other-client' }) }),
        'invalid_grant',
      );

      expect(error.errorDescription).toBe(
        'The auth_req_id is invalid, expired, or was issued to another client',
      );
      // The record stays: the rightful client can still poll it.
      expect(await store.findByAuthReqId('auth-req-id-value')).not.toBe(null);
    });
  });

  describe('State machine (CIBA Section 11)', () => {
    it('should answer authorization_pending for a pending record and stamp lastPolledAt', async () => {
      const store = createInMemoryCibaAuthenticationRequestStore();
      await store.save(makeRecord());

      const error = await expectGrantError(makeInput({ store }), 'authorization_pending');

      expect(error.errorDescription).toBe('The authentication request is still pending');
      expect((await store.findByAuthReqId('auth-req-id-value'))?.lastPolledAt).toEqual(NOW);
    });

    it('should answer slow_down and raise the interval by 5 when polled inside the interval', async () => {
      const store = createInMemoryCibaAuthenticationRequestStore();
      await store.save(makeRecord({ lastPolledAt: new Date(NOW.getTime() - 2_000) }));

      const error = await expectGrantError(makeInput({ store }), 'slow_down');

      expect(error.errorDescription).toBe(
        'Polling too frequently. Increase the interval by 5 seconds.',
      );
      const record = await store.findByAuthReqId('auth-req-id-value');
      expect(record?.interval).toBe(10);
      expect(record?.lastPolledAt).toEqual(NOW);
    });

    // CIBA Section 11: "the interval MUST be increased by at least 5 seconds
    // for this and all subsequent requests" — the raise is persistent.
    it('should keep raising the interval on repeated fast polls', async () => {
      const store = createInMemoryCibaAuthenticationRequestStore();
      await store.save(makeRecord({ lastPolledAt: new Date(NOW.getTime() - 2_000) }));

      await expectGrantError(makeInput({ store }), 'slow_down');
      await expectGrantError(
        makeInput({ store, now: new Date(NOW.getTime() + 6_000) }),
        'slow_down',
      );

      expect((await store.findByAuthReqId('auth-req-id-value'))?.interval).toBe(15);
    });

    it('should answer authorization_pending again once the interval has passed', async () => {
      const store = createInMemoryCibaAuthenticationRequestStore();
      await store.save(makeRecord({ lastPolledAt: new Date(NOW.getTime() - 6_000) }));

      await expectGrantError(makeInput({ store }), 'authorization_pending');
    });

    it('should answer expired_token and delete the record when it expired', async () => {
      const store = createInMemoryCibaAuthenticationRequestStore();
      await store.save(makeRecord({ expiresAt: new Date(NOW.getTime() - 1_000) }));

      const error = await expectGrantError(makeInput({ store }), 'expired_token');

      expect(error.errorDescription).toBe(
        'The auth_req_id has expired. Start a new backchannel authentication request.',
      );
      expect(await store.findByAuthReqId('auth-req-id-value')).toBe(null);
    });

    // Expiry is evaluated before the polling pace: raising the interval of an
    // expired record would be meaningless, the client must learn the flow ended.
    it('should prefer expired_token over slow_down', async () => {
      const store = createInMemoryCibaAuthenticationRequestStore();
      await store.save(makeRecord({
        expiresAt: new Date(NOW.getTime() - 1_000),
        lastPolledAt: new Date(NOW.getTime() - 1_000),
      }));

      await expectGrantError(makeInput({ store }), 'expired_token');
    });

    it('should answer access_denied and delete the record after the user denied', async () => {
      const store = createInMemoryCibaAuthenticationRequestStore();
      await store.save(makeRecord({ status: 'denied' }));

      const error = await expectGrantError(makeInput({ store }), 'access_denied');

      expect(error.errorDescription).toBe(
        'The end-user denied the authentication request',
      );
      expect(await store.findByAuthReqId('auth-req-id-value')).toBe(null);
    });

    it('should answer invalid_grant when polling again after access_denied', async () => {
      const store = createInMemoryCibaAuthenticationRequestStore();
      await store.save(makeRecord({ status: 'denied' }));
      await expectGrantError(makeInput({ store }), 'access_denied');

      await expectGrantError(makeInput({ store }), 'invalid_grant');
    });
  });

  describe('Token issuance data (approved record)', () => {
    function approvedRecord() {
      return makeRecord({
        status: 'approved',
        authTime: 1_760_000_000,
        approvedScope: ['openid', 'profile'],
        grantId: 'grant-1',
      });
    }

    it('should return the issuance data for an approved record', async () => {
      const store = createInMemoryCibaAuthenticationRequestStore();
      await store.save(approvedRecord());

      const result = await processCibaGrant(makeInput({ store }));

      expect(result).toEqual({
        subject: 'testuser',
        clientId: 'ciba-client',
        scope: ['openid', 'profile'],
        authTime: 1_760_000_000,
        grantId: 'grant-1',
      });
    });

    it('should consume the record so a second redemption fails with invalid_grant', async () => {
      const store = createInMemoryCibaAuthenticationRequestStore();
      await store.save(approvedRecord());
      await processCibaGrant(makeInput({ store }));

      await expectGrantError(makeInput({ store }), 'invalid_grant');
    });

    it('should reject an approved record missing its approval context', async () => {
      const store = createInMemoryCibaAuthenticationRequestStore();
      await store.save(makeRecord({ status: 'approved' }));

      await expectGrantError(makeInput({ store }), 'invalid_grant');
    });

    it('should fall back to the requested scope when approvedScope is absent', async () => {
      const store = createInMemoryCibaAuthenticationRequestStore();
      await store.save(makeRecord({
        status: 'approved',
        authTime: 1_760_000_000,
        grantId: 'grant-1',
      }));

      const result = await processCibaGrant(makeInput({ store }));

      expect(result.scope).toEqual(['openid']);
    });
  });
});
```

### What passing all of them guarantees

The unit tests guarantee that the endpoint's input validation fails with the specification's vocabulary, that the state machine honors §11's transitions and deletion timing, and that the UI defenses (binding, CSRF, subject binding, oracle prevention) hold at the function level.
The HTTP wiring (shared client authentication, Cache-Control, routing) is covered by the tests placed next to the feature's files in `apps/hono`, the source the generated code is extracted from, and the full round trip with a real browser and real polling by the E2E tests.

## CLI integration and the generated-code contribution

The experimental package is the logic layer (record management and the state machine); the HTTP side, with its endpoints, cookies, screens and the assembly of token issuance, is generated code.
`maronn-oidc generate <framework> --enable ciba` takes the code this feature owns out of a running app, `apps/hono/src/oidc-provider/`, and adds it to the generated output.
What is taken and how is defined by [packages/cli/extract.json](../../../packages/cli/extract.json) and carried out by [packages/cli/src/generate.ts](../../../packages/cli/src/generate.ts).
The feature adds three things:

- **`features/ciba/`**: every file the feature owns. The `defineFeature()` of `feature.ts` declares two routes (`POST /backchannel_authentication` with the protected CORS policy, and the authentication device screens at `/ciba` with the subpaths `/ciba/login` and `/ciba/approve`), the discovery members `backchannel_authentication_endpoint` and `backchannel_token_delivery_modes_supported`, the two stores and `cibaUserResolver` as context values, and `urn:openid:params:grant-type:ciba` under `token.grants`. `config.ts` adds `cibaUserResolver` to `OidcProviderOptions`
- **one import and one list entry in `features/enabled.ts`**
- **one `(feature: ciba)` block in `endpoints/token/pipeline.ts`**: between the `authenticate-client` and `validate-grant-type` steps, it redeems the CIBA grant

There are three request flows.
The consumption device's `POST /backchannel_authentication` reaches `features/ciba/endpoints/backchannel-authentication/pipeline.ts`, which `app.ts` mounts through `routesOf(features)`.
That pipeline calls its steps in order: parse the request, authenticate the client, check the scope against the registration, resolve the `login_hint` and create the pending request, respond.
The `/ciba` page the user opens in their own browser is served by `features/ciba/endpoints/ciba/page.tsx`, which turns the outcomes of the three steps under `steps/` into screens and cookies.
The consumption device's polling `POST /token` reaches the base `endpoints/token/pipeline.ts`, where the dispatch-ciba block right after client authentication looks at `grant_type` and, for the CIBA grant, answers on the spot.

Only the token endpoint contribution is a block rather than a hook, because it has to sit in the middle of a base pipeline.
Core's `validateGrantTypeSupported()`, called by the base `validate-grant-type` step, rejects every `grant_type` other than `authorization_code` and `refresh_token` with `unsupported_grant_type`.
The CIBA grant therefore has to be answered before that step.
The fixed hooks (`routes`, `discovery`, `context`, `config`, `token.grants`, and so on) have no way to insert logic into a base pipeline, so the logic is an owner block in the pipeline and the step itself lives in `features/ciba/steps/dispatch-ciba.ts`.
The URN declared under `token.grants` is listed in discovery's `grant_types_supported`; what actually accepts the URN at the token endpoint is the block.

The resolution of `login_hint`, on the other hand, is handed over as a value of the context hook, not as a pipeline block.
How the hint is resolved is a deployment setting, not a stage of the pipeline, and the step only has to call `c.get('cibaUserResolver')`.
The context hook is a function because the default resolution reads the user store of the request (`c.get('userStore')`).
`app.ts` resolves the stores for each request (on Cloudflare Workers the D1 binding comes with the request), so the default resolution has to be built from the request's `c` too.

Generating without the feature leaves out the directory `features/ciba/`, and `features/enabled.ts` gets neither its import nor its list entry.
The token pipeline loses the block and the import only the block uses.
No later block reads the `cibaGrantResponse` the block defines, so no `const cibaGrantResponse = undefined;` stand-in is left either.

The generated output contains no tests.
In `apps/hono`, the source of the extraction, tests placed next to the feature's files (the `*.test.ts` and `*.test.tsx` under [apps/hono/src/oidc-provider/features/ciba](../../../apps/hono/src/oidc-provider/features/ciba)) pin the behavior, and the extraction leaves them out.

### The generated code in full (hono)

The code below is what this feature adds to the hono output generated with the default features plus `--enable ciba`.
The feature directory holds 21 files, listed in this order: `feature.ts`; the settings, stores, cookies and screens; the backchannel authentication endpoint; the authentication device screens; the token endpoint step.

#### The lines added to `features/enabled.ts`

`features/enabled.ts` lists the enabled features, with one import and one list entry per feature.
The hooks apply in the order of that array.

```typescript
import { ciba } from './ciba/feature.js';
```

```typescript
  ciba,
```

#### The lines added to `endpoints/token/endpoint.ts`

`endpoints/token/endpoint.ts` describes the steps of the token endpoint and the edges between them; `maronn-oidc graph` draws its diagram and `--flow` checks a flow document from this description.
Its `steps` hold the line of the `ciba` step.
When the provider is generated without `ciba`, the CLI removes these lines, so the output's `endpoint.ts` lists only the steps the output has.

```typescript
    'dispatch-ciba',
```

#### The `(feature: ciba)` block of `endpoints/token/pipeline.ts`

The import of the step the block calls joins the top of the token pipeline.

```typescript
import { redeemCibaRequest } from '../../features/ciba/steps/dispatch-ciba.js';
```

The block runs right after the `authenticate-client` step (client authentication) and right before the `validate-grant-type` step.
For any `grant_type` other than the CIBA grant the step returns `undefined` and the pipeline goes on to validate the standard grants.
For the CIBA grant the step returns a `Response`, and the pipeline answers with it there.
When other features are enabled too, their dispatch blocks (id-jag, token-exchange, device-authorization-grant) sit in the same stretch, in the order of the pipeline of `apps/hono`, the source of the extraction.

```typescript
    // [dispatch-ciba] (feature: ciba) Redeem an auth_req_id (CIBA) — CIBA Core 1.0 §10.1 / §11
    const cibaGrantResponse = await redeemCibaRequest(c, params, tokenClient, authenticatedClientId);
    if (cibaGrantResponse) return cibaGrantResponse;
```

#### `features/ciba/feature.ts`

The declaration of the feature.
`app.ts` mounts the two `routes` entries the same way as the base routes.
`/backchannel_authentication` is an API the consumption device calls over the back channel, so it gets the same protected CORS policy as `/token` (the origins of `corsOrigins`).
`/ciba` is a page the browser navigates to, so it has no CORS, and the method guard of `app.ts` answers 405 to anything but `GET /ciba`, `POST /ciba/login` and `POST /ciba/approve`.

`discovery` advertises the two REQUIRED members of CIBA Core §4.
The delivery modes list only poll, the one implemented, and the OPTIONAL members (signing algorithms and user_code support) are left out because they are not supported.
The URN of `token.grants` joins discovery's `grant_types_supported`.

`context` is a function that puts the two stores and `cibaUserResolver` into the request context.
`cibaUserResolver` prefers the one passed in the options; without one, the default hands the hint to `getClaims()` of the user store.
This OP's password form checks the sub as the username, so by default the hint is the same value as the username used to sign in.
The side-effect-only `import './config.js'` makes the file that extends `OidcProviderOptions` a dependency of feature.ts and runs the range checks of the settings when feature.ts is loaded.

```typescript
import { CIBA_GRANT_TYPE } from '@maronn-openid-connect/experimental/ciba';
import { defineFeature } from '../feature.js';
import './config.js';
import { backchannelAuthenticationApp } from './endpoints/backchannel-authentication/pipeline.js';
import { cibaPage } from './endpoints/ciba/page.js';
import { cibaAuthenticationRequestStore, cibaLoginTransactionStore } from './store.js';

/**
 * EXPERIMENTAL — OpenID Connect Client-Initiated Backchannel Authentication
 * (CIBA Core 1.0), poll mode: POST /backchannel_authentication, the
 * authentication device screens under /ciba, and the dispatch-ciba block of
 * endpoints/token/pipeline.ts, which answers the urn:openid:params:grant-type:ciba
 * grant. Settings are in config.ts.
 *
 * Backed by @maronn-openid-connect/experimental, whose API is NOT stable: it
 * may change in a breaking way between releases.
 */
export const ciba = defineFeature({
  id: 'ciba',
  routes: [
    { path: '/backchannel_authentication', app: backchannelAuthenticationApp, methods: ['POST'], cors: 'protected' },
    {
      path: '/ciba',
      app: cibaPage,
      methods: ['GET'],
      subpaths: { '/login': ['POST'], '/approve': ['POST'] },
    },
  ],
  // CIBA Core 1.0 §4 metadata. Only the poll delivery mode is implemented.
  discovery: (issuer) => ({
    backchannel_token_delivery_modes_supported: ['poll'],
    backchannel_authentication_endpoint: `${issuer}/backchannel_authentication`,
  }),
  context: ({ c, options }) => ({
    cibaAuthenticationRequestStore,
    cibaLoginTransactionStore,
    // CIBA Core 1.0 §7.1: login_hint → subject. The default treats the hint as
    // a username of the user store; pass cibaUserResolver to replace it.
    cibaUserResolver:
      options.cibaUserResolver ??
      (async (loginHint: string) => {
        const claims = await c.get('userStore').getClaims(loginHint);
        return claims ? { subject: claims.sub } : null;
      }),
  }),
  token: { grants: [CIBA_GRANT_TYPE] },
});
```

#### `features/ciba/config.ts`

The feature's settings, `cibaConfig`, the addition of `cibaUserResolver` to `OidcProviderOptions`, and the addition of `backchannelTokenDeliveryMode` to `RegisteredClient`.
`authReqIdExpiresIn`, `pollingInterval` and `maxPendingPerSubject` are handed to the experimental package by the `create-request` step of the backchannel authentication endpoint, and `maxLoginAttempts` is read by the `submit-login` step of the authentication device screens.
The token endpoint's dispatch-ciba step does not read this object; `processCibaGrant()` uses the interval stored on the record.
The values are properties of an exported object, so they are changed by editing this file or by assigning to the properties when the host app starts.

A value outside the documented ranges throws when the module is loaded.
A typo in the settings would weaken either the cap that holds back floods of the approval screen or the polling contract.
`declare module '../../app.js'` adds `cibaUserResolver` to the options of `createApp()` and `applyOidc()`.
What a `login_hint` means (an email address, a phone number, a username) depends on the design of the user store, so the resolution can be replaced as a whole.
`declare module '../../config.js'` adds the CIBA §4 client metadata `backchannel_token_delivery_mode` to `RegisteredClient`, the type of a client registration.
This OP offers poll only, so the experimental package refuses every backchannel authentication request of a client registered for ping or push with `unauthorized_client` in the `create-request` step.
The member is added from the feature's directory, so generating without ciba removes it from the type as well.

```typescript
/**
 * EXPERIMENTAL — CIBA settings (CIBA Core 1.0).
 *
 * Read by the backchannel authentication endpoint, the authentication device
 * UI (/ciba) and the CIBA grant of the token endpoint.
 *
 * - authReqIdExpiresIn: §7.3 expires_in, in seconds (range 30–600). Keep it
 *   short: it is the window the user has to approve, and the window in which a
 *   pending request can pile up on the approval screen.
 * - pollingInterval: §7.3 interval, in seconds (range 1–60). The token endpoint
 *   raises a record's own interval by 5 every time it answers slow_down (§11).
 * - maxPendingPerSubject: pending backchannel requests allowed per user (range
 *   1–100) before new ones are refused — the flood defense for the approval
 *   screen (the role §7.1.2's unsupported user_code would otherwise play).
 * - maxLoginAttempts: failed /ciba logins allowed per login transaction before
 *   it is discarded. Per-transaction only — see the notes in the UI route.
 */
export const cibaConfig = {
  authReqIdExpiresIn: 120,
  pollingInterval: 5,
  maxPendingPerSubject: 10,
  maxLoginAttempts: 5,
};

// Fail fast on a config edit that leaves the documented ranges: a typo here
// weakens either the approval-screen flood cap or the polling contract.
if (cibaConfig.authReqIdExpiresIn < 30 || cibaConfig.authReqIdExpiresIn > 600) {
  throw new Error('cibaConfig.authReqIdExpiresIn must be between 30 and 600 seconds');
}
if (cibaConfig.pollingInterval < 1 || cibaConfig.pollingInterval > 60) {
  throw new Error('cibaConfig.pollingInterval must be between 1 and 60 seconds');
}
if (cibaConfig.maxPendingPerSubject < 1 || cibaConfig.maxPendingPerSubject > 100) {
  throw new Error('cibaConfig.maxPendingPerSubject must be between 1 and 100');
}

declare module '../../app.js' {
  interface OidcProviderOptions {
    /**
     * EXPERIMENTAL (CIBA Core 1.0 §7.1): resolve a login_hint to the subject the
     * authentication request is for. Defaults to treating the hint as a username
     * of the configured user store. Return null when no user matches.
     */
    cibaUserResolver?: (
      loginHint: string,
    ) => Promise<{ subject: string } | null> | { subject: string } | null;
  }
}

declare module '../../config.js' {
  interface RegisteredClient {
    /**
     * EXPERIMENTAL (CIBA Core 1.0 §4): the backchannel_token_delivery_mode
     * client metadata. This provider offers poll only, so a client registered
     * for ping or push has every backchannel authentication request refused
     * with unauthorized_client. Omitted means poll.
     */
    backchannelTokenDeliveryMode?: 'poll' | 'ping' | 'push';
  }
}
```

#### `features/ciba/store.ts`

The two stores: authentication request records and login transactions.
The in-memory implementations are factories of the experimental package (`createInMemoryCibaAuthenticationRequestStore()` and `createInMemoryCibaLoginTransactionStore()`), so this file only keeps what the factories return.
The stores live in the feature's directory rather than in the base `store.ts`, so disabling the feature removes them with the directory, and the base code never imports a feature.

The instances are kept on `globalThis`, so every module gets the same stores, also when a module is loaded more than once (dev-mode hot reloads, separate module layers).
`--db` does not apply to these stores: the samples generated with `--db sql` get the same file.
On runtimes without shared memory between instances the records are split between instances too, so production deployments replace them with persistent stores (Redis, KV, a database), as the comment says.

```typescript
import {
  createInMemoryCibaAuthenticationRequestStore,
  createInMemoryCibaLoginTransactionStore,
  type CibaAuthenticationRequestStore,
  type CibaLoginTransactionStore,
} from '@maronn-openid-connect/experimental/ciba';

// EXPERIMENTAL — CIBA stores. The in-memory implementations ship with
// @maronn-openid-connect/experimental/ciba; replace them with persistent stores (Redis, KV,
// database) in production. Treat authReqId and the login transaction id as
// opaque external values: never interpolate them into a query, always bind
// them as parameters. Kept on globalThis so every module that asks for a store
// gets the same one, also where a framework loads a module more than once
// (dev-mode hot reloads, separate module layers).
const cibaStoreRegistry = globalThis as typeof globalThis & {
  __oidcCibaAuthenticationRequestStore?: CibaAuthenticationRequestStore;
  __oidcCibaLoginTransactionStore?: CibaLoginTransactionStore;
};

export const cibaAuthenticationRequestStore: CibaAuthenticationRequestStore =
  (cibaStoreRegistry.__oidcCibaAuthenticationRequestStore ??=
    createInMemoryCibaAuthenticationRequestStore());

export const cibaLoginTransactionStore: CibaLoginTransactionStore =
  (cibaStoreRegistry.__oidcCibaLoginTransactionStore ??=
    createInMemoryCibaLoginTransactionStore());
```

#### `features/ciba/cookies.ts`

The helpers of the cookie that binds the login form of the authentication device screens to the browser it was issued to.
A successful login at `/ciba/login` establishes an OP session, whose reach goes beyond CIBA (SSO, `prompt=none`).
A `csrf_token` embedded in the form cannot stop login CSRF on its own.
By opening `GET /ciba` themselves, attackers get a valid `login_transaction_id` and `csrf_token` pair to embed in a forged form.

The login form response hands the raw bindingSecret to that one browser in an HttpOnly cookie, and the transaction stores only its SHA-256 hash.
A forged POST cannot carry the victim's cookie (SameSite=Lax), and the victim never held this transaction's cookie anyway.
The cookie name embeds the transaction id so two login forms in the same browser do not overwrite each other's secret, and a clearing cookie removes it after a successful login.

```typescript
/**
 * EXPERIMENTAL — CIBA login transaction binding cookie (CIBA Core 1.0; the
 * authentication device UI itself is outside the spec's scope, §7.1).
 *
 * Why this exists: a successful login on /ciba/login establishes an OP session,
 * whose reach goes beyond CIBA (SSO, prompt=none). A hidden csrf_token alone
 * cannot stop login CSRF: the attacker fetches their own /ciba login form,
 * reads a valid login_transaction_id + csrf_token pair, and embeds both in a
 * forged cross-site POST — planting the attacker's session in the victim's
 * browser. What stops it is this cookie: the login form response binds the
 * transaction to the browser that requested it by handing that one browser the
 * raw bindingSecret in an HttpOnly cookie while the transaction stores only its
 * SHA-256 hash. A forged POST cannot carry the victim's cookie (SameSite=Lax),
 * and the victim never held this transaction's cookie anyway.
 *
 * The cookie name embeds the transaction id so two login forms can run in the
 * same browser without overwriting each other's secret.
 */
export const CIBA_LOGIN_BINDING_COOKIE_PREFIX = 'oidc_ciba_login_';

/**
 * Build the Set-Cookie value binding one CIBA login transaction to this
 * browser. Same attributes as the session cookie: HttpOnly (no JS access),
 * Secure (HTTPS only; http://localhost is treated as trustworthy by browsers)
 * and SameSite=Lax. Max-Age matches the transaction TTL so an abandoned login
 * form does not leave a cookie behind.
 */
export function buildCibaLoginBindingCookie(
  transactionId: string,
  bindingSecret: string,
  ttlSeconds: number,
): string {
  return (
    CIBA_LOGIN_BINDING_COOKIE_PREFIX + transactionId + '=' + bindingSecret +
    '; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=' + String(ttlSeconds)
  );
}

/**
 * Build the Set-Cookie value that clears the binding cookie once the login
 * succeeded, so the browser does not accumulate one cookie per login form.
 */
export function buildClearedCibaLoginBindingCookie(transactionId: string): string {
  return (
    CIBA_LOGIN_BINDING_COOKIE_PREFIX + transactionId +
    '=; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=0'
  );
}

/**
 * Extract the binding secret for one CIBA login transaction from a Cookie
 * header. Returns null when the header is missing or this transaction's cookie
 * is absent, which validateCibaLoginSubmission() rejects with 403.
 */
export function parseCibaLoginBindingSecret(
  cookieHeader: string | null,
  transactionId: string,
): string | null {
  if (!cookieHeader) return null;
  const name = CIBA_LOGIN_BINDING_COOKIE_PREFIX + transactionId;
  for (const part of cookieHeader.split(';')) {
    const trimmed = part.trim();
    const eq = trimmed.indexOf('=');
    if (eq === -1) continue;
    if (trimmed.slice(0, eq) === name) {
      return trimmed.slice(eq + 1);
    }
  }
  return null;
}
```

#### `features/ciba/views.tsx`

The three views of the authentication device screens (sign-in, the list of pending requests with approval, completion), in hono/jsx.
`declare module '../../views.js'` adds them to the base `Views` interface as optional members, so the `views` option of `createApp()` / `applyOidc()` replaces them the same way as the login and consent views.
`cibaViews(c)` returns the views the app replaced, or the defaults of this file.

The list shows the `binding_message` so the user can compare it with what the consumption device shows (CIBA Core §7.1).
The `binding_message` is client-supplied text, but JSX escapes every value interpolated with `{...}`.
The Deny button looks the same as the Approve button, and the screen asks the user to approve only requests they started themselves.

```tsx
/** @jsxImportSource hono/jsx */
/**
 * EXPERIMENTAL — the views of the CIBA authentication device screens (CIBA
 * Core 1.0 §7.1), in hono/jsx.
 *
 * They are members of Views (views.tsx), added below, so the views option of
 * createApp() / applyOidc() can replace them like the login and consent
 * views. A member left out falls back to the default of this file.
 */
import type { JSX } from 'hono/jsx/jsx-runtime';
import {
  CredentialFields,
  DecisionOutcome,
  FormError,
  Layout,
  ScopeList,
  type Views,
} from '../../views.js';

export interface CibaLoginPageParams {
  /** Login transaction id; carried through as a hidden field. */
  loginTransactionId: string;
  /** CSRF token (must be included as hidden form field) */
  csrfToken: string;
  /** Error message from a previous failed attempt */
  error?: string;
  /** Number of remaining login attempts for this login transaction */
  remainingAttempts?: number;
}

export interface CibaPendingRequestParams {
  /** auth_req_id; carried through as a hidden field of the decision form. */
  authReqId: string;
  /** Client that asked for the backchannel authentication */
  clientId: string;
  /** Scopes the client asked for */
  scopes: string[];
  /**
   * CIBA Core 1.0 §7.1 binding_message: shown so the user can compare it with
   * the message on the consumption device — the visual check that they are
   * approving THEIR transaction and not someone else's. Client-supplied text:
   * it MUST be escaped before rendering.
   */
  bindingMessage?: string;
  /** Seconds until this request expires */
  expiresInSeconds: number;
  /** Per-record CSRF token (must be included as hidden form field) */
  csrfToken: string;
}

export interface CibaPendingRequestsPageParams {
  /** Pending backchannel authentication requests addressed to the signed-in user */
  requests: CibaPendingRequestParams[];
}

export interface CibaCompletedPageParams {
  /** true when the user approved, false when they denied */
  approved: boolean;
  /** Client the decision applied to */
  clientId: string;
}

declare module '../../views.js' {
  interface Views {
    /** EXPERIMENTAL (CIBA Core 1.0): render the sign-in form of the authentication device UI */
    cibaLoginPage?(params: CibaLoginPageParams): ViewResult;
    /** EXPERIMENTAL (CIBA Core 1.0): render the pending-requests approval screen */
    cibaPendingRequestsPage?(params: CibaPendingRequestsPageParams): ViewResult;
    /** EXPERIMENTAL (CIBA Core 1.0): render the decision-recorded screen */
    cibaCompletedPage?(params: CibaCompletedPageParams): ViewResult;
  }
}

function defaultCibaLoginPage(params: CibaLoginPageParams): JSX.Element {
  return (
    <Layout title="Sign in">
      <h1>Sign in</h1>
      <p>Sign in to review sign-in requests sent to you.</p>
      <FormError error={params.error} remainingAttempts={params.remainingAttempts} />
      <form method="post" action="/ciba/login">
        <input type="hidden" name="login_transaction_id" value={params.loginTransactionId} />
        <input type="hidden" name="csrf_token" value={params.csrfToken} />
        <CredentialFields />
        <button type="submit">Login</button>
      </form>
    </Layout>
  );
}

function defaultCibaPendingRequestsPage(params: CibaPendingRequestsPageParams): JSX.Element {
  if (params.requests.length === 0) {
    return (
      <Layout title="Sign-in Requests">
        <h1>Sign-in Requests</h1>
        <p>No pending sign-in requests.</p>
      </Layout>
    );
  }

  // CIBA Core 1.0 §7.1: the binding_message is repeated here on purpose. Ask
  // the user to check it against the device that started the request before
  // approving. The Deny button is rendered with the same prominence as Approve.
  return (
    <Layout title="Sign-in Requests">
      <h1>Sign-in Requests</h1>
      <p>Only approve a request you started yourself on another device.</p>
      {params.requests.map((request) => (
        <section>
          <p>Client <strong>{request.clientId}</strong> is requesting access to the following scopes:</p>
          <ScopeList scopes={request.scopes} />
          {request.bindingMessage ? (
            <p>Confirm that your device is showing this message: <strong>{request.bindingMessage}</strong></p>
          ) : null}
          <p>This request expires in {request.expiresInSeconds} seconds.</p>
          <form method="post" action="/ciba/approve">
            <input type="hidden" name="auth_req_id" value={request.authReqId} />
            <input type="hidden" name="csrf_token" value={request.csrfToken} />
            <button type="submit" name="decision" value="approve">Approve</button>
            <button type="submit" name="decision" value="deny">Deny</button>
          </form>
        </section>
      ))}
    </Layout>
  );
}

function defaultCibaCompletedPage(params: CibaCompletedPageParams): JSX.Element {
  return (
    <Layout title="Sign-in Requests">
      <h1>Sign-in Requests</h1>
      <DecisionOutcome approved={params.approved} clientId={params.clientId} />
      <p>You can close this page and go back to your device.</p>
    </Layout>
  );
}

/** The views of the request for these screens: the ones the app replaced, else the defaults above. */
export function cibaViews(c: any): Required<Pick<Views, 'cibaLoginPage' | 'cibaPendingRequestsPage' | 'cibaCompletedPage'>> {
  const views: Partial<Views> = c.get('views') ?? {};
  return {
    cibaLoginPage: views.cibaLoginPage ?? defaultCibaLoginPage,
    cibaPendingRequestsPage: views.cibaPendingRequestsPage ?? defaultCibaPendingRequestsPage,
    cibaCompletedPage: views.cibaCompletedPage ?? defaultCibaCompletedPage,
  };
}
```

#### `features/ciba/endpoints/backchannel-authentication/pipeline.ts`

The pipeline of the backchannel authentication endpoint, `POST /backchannel_authentication`.
Each block calls one step, and when a step throws, `respondBackchannelAuthenticationError()` turns the failure into the OAuth error response.
Each block is one box of `maronn-oidc graph --detail steps --endpoint backchannel-authentication`.

The comment at the top records that the `login_hint` is a user identifier (PII) and is therefore never logged nor echoed in an `error_description` (CIBA §15).
Rate limiting the endpoint as a whole is left to the deployment layer.
On runtimes without shared memory between instances an in-process counter does not work; the in-band defenses are mandatory client authentication, the fixed `unknown_user_id` wording, and the cap on pending requests per subject.

```typescript
import { Hono } from 'hono';
import { authenticateCibaClient } from './steps/authenticate-client.js';
import { createBackchannelAuthenticationRequest } from './steps/create-request.js';
import { parseBackchannelAuthenticationRequest } from './steps/parse-request.js';
import { respondBackchannelAuthenticationError } from './steps/respond-error.js';
import { respondBackchannelAuthentication } from './steps/respond.js';
import { validateCibaClientScope } from './steps/validate-client-scope.js';

/**
 * EXPERIMENTAL — OpenID Connect Client-Initiated Backchannel Authentication
 * (CIBA Core 1.0), poll mode.
 *
 * This endpoint was generated because the OP was created with `--enable ciba`.
 * It is backed by @maronn-openid-connect/experimental, whose API is NOT stable: it may
 * change in a breaking way between releases. Do not build production code on it
 * without pinning the version.
 *
 * The consumption device (a call-center console, a kiosk, a smart speaker
 * backend) POSTs here — back channel, client-authenticated — with a login_hint
 * naming the user, and receives an auth_req_id it polls the token endpoint
 * with. The user approves or denies on their own browser at /ciba. Each block
 * below calls one step (one box of
 * `maronn-oidc graph --detail steps --endpoint backchannel-authentication`).
 *
 * NOTE (CIBA §15): the login_hint is a user identifier and therefore PII.
 * Never log it, and never echo it in an error_description. Rate limiting the
 * endpoint as a whole is deliberately left to the deployment layer (reverse
 * proxy / platform): an in-process counter cannot work on runtimes without
 * shared memory between instances. The in-band defenses are mandatory client
 * authentication, the fixed unknown_user_id wording, and the per-subject
 * pending-request cap (cibaConfig in config.ts).
 */
export const backchannelAuthenticationApp = new Hono<{ Variables: Record<string, any> }>();

backchannelAuthenticationApp.post('/', async (c) => {
  try {
    // [parse-request] Parse the backchannel authentication request — CIBA Core 1.0 §7.1
    const { params, authorization } = await parseBackchannelAuthenticationRequest(c);

    // [authenticate-client] Authenticate the client — CIBA Core 1.0 §7.1
    const client = await authenticateCibaClient(c, params, authorization);

    // [validate-client-scope] Check the requested scope against the registration — RFC 7591 §2 / RFC 6749 §3.3
    validateCibaClientScope(params, client);

    // [create-request] Resolve the login_hint and create the pending request — CIBA Core 1.0 §7.1 - §7.3
    const cibaResponse = await createBackchannelAuthenticationRequest(c, params, client);

    // [respond] Respond with auth_req_id (no-store) — CIBA Core 1.0 §7.3
    return respondBackchannelAuthentication(c, cibaResponse);
  } catch (error) {
    return respondBackchannelAuthenticationError(c, error);
  }
});
```

#### `features/ciba/endpoints/backchannel-authentication/endpoint.ts`

The metadata `maronn-oidc graph` draws this endpoint from.
It declares the order of the steps, the error step, and the arrows of the diagram from this endpoint to the authentication device screens (the user's approval) and to the token endpoint (auth_req_id polling).
`rearrangeable: true` means `--flow` may reorder the steps.

```typescript
import { defineEndpoint } from '../../../../endpoints/step.js';

/** EXPERIMENTAL — the backchannel authentication endpoint (poll mode). CIBA Core 1.0 §7 */
export const endpoint = defineEndpoint({
  id: 'backchannel-authentication',
  order: 150,
  label: 'Backchannel authentication endpoint',
  path: '/backchannel_authentication',
  methods: ['POST'],
  layer: 'api',
  group: { id: 'backchannel-authentication', label: 'CIBA (poll mode)' },
  spec: 'CIBA Core 1.0 §7',
  feature: 'ciba',
  rearrangeable: true,
  steps: [
    'parse-request',
    'authenticate-client',
    'validate-client-scope',
    'create-request',
    'respond',
    'respond-error',
  ],
  errorStep: 'respond-error',
  edges: {
    chain: true,
  },
  journeys: [
    { from: 'backchannel-authentication', to: 'ciba', label: 'End-User approves', kind: 'flow', order: 150 },
    { from: 'backchannel-authentication', to: 'token', label: 'auth_req_id (polling)', kind: 'flow', order: 160 },
  ],
});
```

#### `features/ciba/endpoints/backchannel-authentication/response.ts`

The response type of the endpoint, `BackchannelAuthenticationEndpointError` for failures with a fixed response (a malformed request), and `noStore()`, which sets `Cache-Control: no-store`.
The auth_req_id is a credential, so the response follows the token response rules of RFC 6749 §5.1 and §5.2.

```typescript
/**
 * What the backchannel authentication endpoint answers, and the failure a
 * step answers with a fixed response.
 */

/** What the backchannel authentication endpoint answers; respondBackchannelAuthentication() turns it into HTTP. */
export interface BackchannelAuthenticationEndpointResponse {
  status: number;
  body: object;
  headers?: Record<string, string>;
}

/** A failure a step answers with a fixed response (a malformed request). */
export class BackchannelAuthenticationEndpointError extends Error {
  constructor(readonly response: BackchannelAuthenticationEndpointResponse) {
    const details = (response.body ?? {}) as { error?: unknown; error_description?: unknown };
    super(String(details.error_description ?? details.error ?? 'backchannel authentication endpoint error'));
    this.name = 'BackchannelAuthenticationEndpointError';
  }
}

export function noStore(c: any): void {
  // auth_req_id is a credential, so the response follows the token response
  // rules of RFC 6749 §5.1 / §5.2.
  c.header('Cache-Control', 'no-store');
  c.header('Pragma', 'no-cache');
}
```

#### `features/ciba/endpoints/backchannel-authentication/steps/parse-request.ts`

The step that reads the form body and the `Authorization` header.
The body must be `application/x-www-form-urlencoded` (CIBA §7.1).
It iterates the raw body with `URLSearchParams` so a repeated parameter (forbidden by RFC 6749 §3.1) is rejected with `invalid_request` instead of silently keeping the last value.

```typescript
import { sanitizeErrorDescription } from '@maronn-openid-connect/core';
import { BackchannelAuthenticationEndpointError } from '../response.js';
import { step } from '../../../../../endpoints/step.js';

export const meta = step({
  id: 'parse-request',
  endpoint: 'backchannel-authentication',
  feature: 'ciba',
  kind: 'parse',
  label: 'Parse the backchannel authentication request',
  spec: 'CIBA Core 1.0 §7.1',
  function: 'parseBackchannelAuthenticationRequest',
  consumes: [],
  produces: ['params', 'authorization'],
  removable: false,
});

/**
 * CIBA §7.1: the backchannel authentication request body MUST be
 * application/x-www-form-urlencoded.
 */
function isFormUrlEncoded(contentType: string): boolean {
  const [mediaType = ''] = contentType.toLowerCase().split(';');
  return mediaType.trim() === 'application/x-www-form-urlencoded';
}

/**
 * Parse the backchannel authentication request: the form body and the
 * Authorization header. CIBA Core 1.0 §7.1 / RFC 6749 §3.1
 */
export async function parseBackchannelAuthenticationRequest(
  c: any,
): Promise<{ params: Record<string, string>; authorization: string }> {
  const contentType = c.req.header('Content-Type') ?? '';
  if (!isFormUrlEncoded(contentType)) {
    throw new BackchannelAuthenticationEndpointError({
      status: 400,
      body: { error: 'invalid_request', error_description: 'Backchannel authentication requests must use application/x-www-form-urlencoded' },
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
    throw new BackchannelAuthenticationEndpointError({
      status: 400,
      body: { error: 'invalid_request', error_description: `Parameter "${sanitizeErrorDescription(duplicateKey)}" must not be repeated` },
    });
  }

  const authorization = c.req.header('Authorization') ?? '';
  return { params, authorization };
}
```

#### `features/ciba/endpoints/backchannel-authentication/steps/authenticate-client.ts`

The client authentication step.
CIBA §7.1 requires the client to authenticate with the method registered for it, so the step calls the same four core functions in the same order as the token endpoint.
Public clients are rejected later, by the client checks of the experimental package.
An authentication failure is thrown as core's `TokenError` (401), which the `respond-error` step returns with `WWW-Authenticate`.

```typescript
import {
  extractClientCredentials,
  resolveAuthenticatedTokenClient,
  validateClientAuthMethod,
  verifyClientSecret,
  type TokenClientInfo,
} from '@maronn-openid-connect/core';
import { step } from '../../../../../endpoints/step.js';

export const meta = step({
  id: 'authenticate-client',
  endpoint: 'backchannel-authentication',
  feature: 'ciba',
  kind: 'validate',
  label: 'Authenticate the client',
  spec: 'CIBA Core 1.0 §7.1',
  function: 'authenticateCibaClient',
  calls: ['extractClientCredentials', 'resolveAuthenticatedTokenClient', 'validateClientAuthMethod', 'verifyClientSecret'],
  consumes: ['params', 'authorization'],
  produces: ['client'],
  removable: false,
});

/**
 * CIBA §7.1: "The Client MUST authenticate ... using the authentication
 * method registered for its client_id" — the same pipeline the token
 * endpoint runs, step function for step function.
 */
export async function authenticateCibaClient(
  c: any,
  params: Record<string, string>,
  authorization: string,
): Promise<TokenClientInfo> {
  const tokenClientResolver = c.get('tokenClientResolver');
  const presentedCredentials = extractClientCredentials({
    params,
    authorizationHeader: authorization,
  });
  const client = await resolveAuthenticatedTokenClient(
    presentedCredentials.clientId,
    tokenClientResolver,
  );
  validateClientAuthMethod(client, presentedCredentials);
  await verifyClientSecret(client, presentedCredentials.clientSecret);
  return client;
}
```

#### `features/ciba/endpoints/backchannel-authentication/steps/validate-client-scope.ts`

The step that checks the requested scope against what the OP declares and what the client registered.
A scope the OP never declared is `invalid_scope`, checked against the same allow list as `/authorize` (`scopes.ts`, RFC 6749 §3.3).
The step comes before the request is created, so a request for an unknown scope never reaches the store.
`offline_access` is left out of this check.
An `offline_access` that cannot be granted is meant to be ignored (OIDC Core 1.0 §11), and the policy of a later step drops it silently.
Checking it here would turn a value that should be ignored into `invalid_scope`.
A client registered with a scope list may only request those scopes (RFC 7591 §2).

```typescript
import { type TokenClientInfo, findUnregisteredClientScopes } from '@maronn-openid-connect/core';
import { BackchannelAuthenticationError } from '@maronn-openid-connect/experimental/ciba';
import { findUnsupportedScopes } from '../../../../../scopes.js';
import { step } from '../../../../../endpoints/step.js';

export const meta = step({
  id: 'validate-client-scope',
  endpoint: 'backchannel-authentication',
  feature: 'ciba',
  kind: 'validate',
  label: 'Check the requested scope against the registration',
  spec: 'RFC 7591 §2 / RFC 6749 §3.3',
  function: 'validateCibaClientScope',
  calls: ['findUnsupportedScopes', 'findUnregisteredClientScopes'],
  consumes: ['params', 'client'],
  produces: [],
  removable: false,
});

/**
 * RFC 7591 §2: a client registered with a scope list (client.scope) may only
 * request those scopes, the same rule as /authorize.
 */
export function validateCibaClientScope(params: Record<string, string>, client: TokenClientInfo): void {
  // RFC 6749 §3.3: reject a scope this OP never declared, the same allow list
  // /authorize uses (scopes.ts). Checked before the pipeline so a request for
  // an unknown scope never reaches the store. offline_access is left out of
  // the check: the pipeline applies its own policy and ignores it when it
  // cannot be granted (OIDC Core 1.0 §11), which must not become an error.
  const unsupportedScopes = findUnsupportedScopes(
    (params['scope'] ?? '')
      .split(' ')
      .filter((scope) => scope.length > 0 && scope !== 'offline_access'),
  );
  if (unsupportedScopes.length > 0) {
    throw new BackchannelAuthenticationError(
      'invalid_scope',
      'Unsupported scope: ' + unsupportedScopes.join(' '),
    );
  }

  const unregisteredScopes = findUnregisteredClientScopes(
    (params['scope'] ?? '').split(' ').filter((scope) => scope.length > 0),
    client.scope,
  );
  if (unregisteredScopes.length > 0) {
    throw new BackchannelAuthenticationError(
      'invalid_scope',
      'Client is not registered for scope: ' + unregisteredScopes.join(' '),
    );
  }
}
```

#### `features/ciba/endpoints/backchannel-authentication/steps/create-request.ts`

The step that resolves the `login_hint` and creates the pending authentication request.
Validation runs inside the experimental package's `processBackchannelAuthenticationRequest()` in CIBA §7.1 order.
The order is: the client checks (public client, grant registration, delivery mode), rejection of the `request` parameter, the exactly-one-hint rule, scope, `binding_message`, `requested_expiry`, `login_hint` resolution, the cap on pending requests per subject, and record creation.

The step hands over `cibaConfig` of `config.ts`, `cibaUserResolver` and the store from the context, and whether refresh tokens can be issued.
Whether refresh tokens can be issued is read from the hooks of the enabled features, `tokenGrantsOf(features).includes('refresh_token')`, without importing the refresh-token feature.
A feature's directory may import another feature only when `requires` in `packages/cli/src/registry.ts` lists it.
The delivery mode reaches the experimental package as the client registration has it (`backchannelTokenDeliveryMode`, which `features/ciba/config.ts` adds to `RegisteredClient`), through the client passed as `CibaClientInfo`.
A client without it is treated as poll, the experimental package's default.

```typescript
import type { TokenClientInfo } from '@maronn-openid-connect/core';
import { processBackchannelAuthenticationRequest, type CibaClientInfo } from '@maronn-openid-connect/experimental/ciba';
import { step } from '../../../../../endpoints/step.js';
import { features } from '../../../../enabled.js';
import { tokenGrantsOf } from '../../../../feature.js';
import { cibaConfig } from '../../../config.js';

export const meta = step({
  id: 'create-request',
  endpoint: 'backchannel-authentication',
  feature: 'ciba',
  kind: 'issue',
  label: 'Resolve the login_hint and create the pending request',
  spec: 'CIBA Core 1.0 §7.1 - §7.3',
  function: 'createBackchannelAuthenticationRequest',
  calls: ['processBackchannelAuthenticationRequest'],
  consumes: ['params', 'client'],
  produces: ['cibaResponse'],
  removable: false,
});

/**
 * Resolve the login_hint and create the pending authentication request.
 * CIBA Core 1.0 §7.1 - §7.3
 *
 * Validation runs in CIBA §7.1 order inside the experimental package:
 * client checks (public client / grant registration / delivery mode) →
 * request parameter rejection → the one-and-only-one hint rule → scope →
 * binding_message → requested_expiry → login_hint resolution → the
 * per-subject pending cap → record creation.
 *
 * login_hint → subject resolution is the deployment's swap point: the
 * default (the context entry of features/ciba/feature.ts) treats the hint as
 * a username of the configured user store. Pass cibaUserResolver to
 * createApp() / applyOidc() to resolve email addresses, phone numbers, or
 * your own ids.
 *
 * Never log auth_req_id (a live credential) or login_hint (PII, CIBA §15).
 */
export async function createBackchannelAuthenticationRequest(
  c: any,
  params: Record<string, string>,
  client: TokenClientInfo,
): Promise<object> {
  const cibaStore = c.get('cibaAuthenticationRequestStore');
  const resolveUser = c.get('cibaUserResolver');
  return processBackchannelAuthenticationRequest({
    params,
    client: client as CibaClientInfo,
    store: cibaStore,
    config: cibaConfig,
    // OIDC Core 1.0 §11: offline_access is ignored when the provider has no
    // refresh_token grant (the refresh-token feature is not generated).
    refreshTokenFeatureEnabled: tokenGrantsOf(features).includes('refresh_token'),
    resolveUser,
  });
}
```

#### `features/ciba/endpoints/backchannel-authentication/steps/respond.ts`

The step that returns the authentication request acknowledgement (the `auth_req_id`, `expires_in` and `interval` of CIBA §7.3).
The auth_req_id is a credential, so the response carries `noStore()`.

```typescript
import { noStore } from '../response.js';
import { step } from '../../../../../endpoints/step.js';

export const meta = step({
  id: 'respond',
  endpoint: 'backchannel-authentication',
  feature: 'ciba',
  kind: 'respond',
  label: 'Respond with auth_req_id (no-store)',
  spec: 'CIBA Core 1.0 §7.3',
  function: 'respondBackchannelAuthentication',
  consumes: ['cibaResponse'],
  produces: [],
  removable: false,
});

/**
 * CIBA Core 1.0 §7.3: the authentication request acknowledgement. auth_req_id
 * is a credential, so the response follows the token response rules of
 * RFC 6749 §5.1 (no-store).
 */
export function respondBackchannelAuthentication(c: any, response: object): Response {
  noStore(c);
  return c.json(response);
}
```

#### `features/ciba/endpoints/backchannel-authentication/steps/respond-error.ts`

The step that turns the failure of any step into an error response of the CIBA §13 / RFC 6749 §5.2 shape.
There are three kinds of failure.
A malformed request is a `BackchannelAuthenticationEndpointError`, whose fixed response is returned as it is.
A client authentication failure is core's `TokenError`, answered with its 401 and `WWW-Authenticate`.
What the experimental package rejects is a `BackchannelAuthenticationError`, answered with its error code and status code.
Any other exception becomes a 500 `server_error`, and every one of these responses carries `no-store`.

```typescript
import { TokenError } from '@maronn-openid-connect/core';
import { BackchannelAuthenticationError } from '@maronn-openid-connect/experimental/ciba';
import { BackchannelAuthenticationEndpointError, noStore } from '../response.js';
import { step } from '../../../../../endpoints/step.js';

export const meta = step({
  id: 'respond-error',
  endpoint: 'backchannel-authentication',
  feature: 'ciba',
  kind: 'respond',
  label: 'Respond with the OAuth error',
  spec: 'CIBA Core 1.0 §13',
  function: 'respondBackchannelAuthenticationError',
  consumes: [],
  produces: [],
  removable: false,
});

/**
 * CIBA §13 / RFC 6749 §5.2 error shape. Authentication failures are core
 * TokenErrors (with their 401); everything the experimental package rejects
 * is a BackchannelAuthenticationError.
 */
export function respondBackchannelAuthenticationError(c: any, error: unknown): Response {
  noStore(c);
  if (error instanceof BackchannelAuthenticationEndpointError) {
    for (const [name, value] of Object.entries(error.response.headers ?? {})) {
      c.header(name, value);
    }
    return c.json(error.response.body, error.response.status);
  }
  if (error instanceof BackchannelAuthenticationError) {
    return c.json({ error: error.code, error_description: error.errorDescription }, error.statusCode);
  }
  if (error instanceof TokenError) {
    if (error.wwwAuthenticate) {
      c.header('WWW-Authenticate', error.wwwAuthenticate);
    }
    return c.json({ error: error.error, error_description: error.errorDescription }, error.statusCode);
  }
  return c.json({ error: 'server_error' }, 500);
}
```

#### `features/ciba/endpoints/ciba/page.tsx`

The screen routing layer of the authentication device screens at `/ciba`: its three routes hold no logic.
`respond()` turns into a screen the outcome of `prepareCibaDevice()` for `GET /ciba`, and for the two POST routes the outcome of the step the form values are handed to.
A missing session is a 401 error page, a `decision` that is neither `approve` nor `deny` a 400, and exhausted attempts a 429.
`renderView()` builds its own `Response`, so `withCookies()` attaches the cookies an outcome carries to the finished `Response` afterwards.
To change the screens, edit this file or `../../views.tsx`; the steps never have to change.

```tsx
/** @jsxImportSource hono/jsx */
/**
 * EXPERIMENTAL — CIBA authentication device screens (CIBA Core 1.0 §7.1),
 * screen routing layer.
 *
 * The user signs in at /ciba, reviews the pending requests addressed to them
 * (client, scopes, binding_message) and approves or denies. All three routes of
 * that UI are here; none of them holds logic. The steps of steps/ —
 * prepareCibaDevice(), submitCibaLogin() and submitCibaDecision() — mint the
 * login transaction, check the credentials, list the requests and record the
 * decision, and report what happened as an outcome (one box each of
 * `maronn-oidc graph --detail steps --endpoint ciba`). This file turns each
 * outcome into a screen, with the cookies the outcome carries. To customize
 * the CIBA UI, edit this file or the views in ../../views.tsx; the steps never
 * have to change.
 *
 * Backed by @maronn-openid-connect/experimental, whose API is NOT stable.
 */
import { Hono } from 'hono';
import { renderErrorPage } from '../../../../pages/errors.js';
import { withCookies } from '../../../../pages/respond.js';
import { renderView } from '../../../../views.js';
import {
  cibaViews,
  type CibaCompletedPageParams,
  type CibaLoginPageParams,
  type CibaPendingRequestsPageParams,
} from '../../views.js';
import type { CibaOutcome } from './outcome.js';
import { prepareCibaDevice } from './steps/prepare-device.js';
import { submitCibaDecision } from './steps/submit-decision.js';
import { submitCibaLogin } from './steps/submit-login.js';

export const cibaPage = new Hono<{ Variables: Record<string, any> }>();

/** Render the sign-in form of the authentication device UI. */
export function renderCibaLoginPage(c: any, params: CibaLoginPageParams): Response {
  const views = cibaViews(c);
  return renderView(<views.cibaLoginPage {...params} />);
}

/** Render the pending-requests approval screen (CIBA Core 1.0 §7.1 binding_message). */
export function renderCibaPendingRequestsPage(
  c: any,
  params: CibaPendingRequestsPageParams,
): Response {
  const views = cibaViews(c);
  return renderView(<views.cibaPendingRequestsPage {...params} />);
}

/** Render the decision-recorded screen. */
export function renderCibaCompletedPage(c: any, params: CibaCompletedPageParams): Response {
  const views = cibaViews(c);
  return renderView(<views.cibaCompletedPage {...params} />);
}

/** Turn the outcome of a step into the screen that follows it. */
function respond(c: any, outcome: CibaOutcome): Response {
  if (outcome.kind === 'error') return renderErrorPage(c, outcome);
  if (outcome.kind === 'session_required') {
    return renderErrorPage(c, {
      error: 'Sign in again to review this request',
      statusCode: 401,
    });
  }
  if (outcome.kind === 'invalid_decision') {
    return renderErrorPage(c, {
      error: 'invalid_request',
      errorDescription: 'decision must be approve or deny',
      statusCode: 400,
    });
  }
  if (outcome.kind === 'locked_out') {
    // The login transaction is gone: this form cannot be retried at all.
    return renderErrorPage(c, {
      error: 'Too many login attempts',
      statusCode: 429,
    });
  }
  if (outcome.kind === 'login') {
    return withCookies(renderCibaLoginPage(c, {
      loginTransactionId: outcome.loginTransactionId,
      csrfToken: outcome.csrfToken,
    }), outcome.cookies);
  }
  if (outcome.kind === 'invalid_credentials') {
    return renderCibaLoginPage(c, {
      loginTransactionId: outcome.loginTransactionId,
      csrfToken: outcome.csrfToken,
      error: 'Invalid credentials',
      remainingAttempts: outcome.remainingAttempts,
    });
  }
  if (outcome.kind === 'pending_requests') {
    return withCookies(
      renderCibaPendingRequestsPage(c, { requests: outcome.requests }),
      outcome.cookies,
    );
  }
  return renderCibaCompletedPage(c, {
    approved: outcome.approved,
    clientId: outcome.clientId,
  });
}

/**
 * Listing / login form - GET
 *
 * With an OP session: the pending requests addressed to the signed-in user.
 * Without one: the sign-in form, with the binding cookie its submission needs.
 */
cibaPage.get('/', async (c) => respond(c, await prepareCibaDevice(c)));

/** Sign in - POST */
cibaPage.post('/login', async (c) => {
  const body = await c.req.parseBody();
  return respond(c, await submitCibaLogin(c, {
    loginTransactionId: String(body['login_transaction_id'] ?? ''),
    csrfToken: String(body['csrf_token'] ?? ''),
    username: String(body['username'] ?? ''),
    password: String(body['password'] ?? ''),
  }));
});

/** Approve or deny - POST */
cibaPage.post('/approve', async (c) => {
  const body = await c.req.parseBody();
  return respond(c, await submitCibaDecision(c, {
    authReqId: String(body['auth_req_id'] ?? ''),
    csrfToken: String(body['csrf_token'] ?? ''),
    decision: String(body['decision'] ?? ''),
  }));
});
```

#### `features/ciba/endpoints/ciba/endpoint.ts`

The metadata `maronn-oidc graph` draws the authentication device screens from.
The three steps are drawn not as a chain but as branches on whether there is an OP session (from preparing the list to the sign-in, or straight to the approval).
The order of the screens fixes the order of the steps, so `rearrangeable: false` forbids reordering.

```typescript
import { defineEndpoint } from '../../../../endpoints/step.js';

/** EXPERIMENTAL — the CIBA authentication device screens. CIBA Core 1.0 §7.1 */
export const endpoint = defineEndpoint({
  id: 'ciba',
  order: 160,
  label: 'CIBA authentication device screens',
  path: '/ciba',
  methods: ['GET', 'POST'],
  layer: 'browser',
  group: { id: 'backchannel-authentication', label: 'CIBA (poll mode)' },
  spec: 'CIBA Core 1.0 §7.1',
  feature: 'ciba',
  rearrangeable: false,
  steps: [
    'prepare-device',
    'submit-login',
    'submit-decision',
  ],
  edges: {
    chain: false,
    extra: [
      { from: 'prepare-device', to: 'submit-login', label: 'no OP session', kind: 'branch' },
      { from: 'prepare-device', to: 'submit-decision', label: 'OP session', kind: 'branch' },
      { from: 'submit-login', to: 'submit-decision', kind: 'flow' },
    ],
  },
});
```

#### `features/ciba/endpoints/ciba/outcome.ts`

The outcome type the steps of the authentication device screens return, and functions they share.
The steps never build a `Response`: they return the next screen and the cookies to set as an outcome, and `page.tsx` turns it into HTTP.

The comment at the top records two decisions.
The login form demands a binding cookie, because the binding of the transaction is what stops login CSRF.
Approval and denial do not use a binding cookie.
The approval is bound to the authenticated OP session: the record's subject must equal the session subject, and the per-record `csrf_token` only appears on the session-gated list, so knowing an auth_req_id leaves an attacker no step to forge.

`listPendingRequests()` returns the pending requests addressed to the session subject, with freshly rotated CSRF tokens.
The experimental package's `listPendingCibaRequests()` mints new tokens on every listing, and this list is the only place they are ever exposed.
The scopes shown are narrowed by `resolveGrantableScopes()` of `scopes.ts` to what this user can actually grant.

```typescript
/**
 * EXPERIMENTAL — OpenID Connect Client-Initiated Backchannel Authentication
 * (CIBA Core 1.0), authentication device UI — API layer: logic only.
 *
 * This module was generated because the OP was created with `--enable ciba`.
 * It is backed by @maronn-openid-connect/experimental, whose API is NOT stable: it may
 * change in a breaking way between releases. Do not build production code on it
 * without pinning the version.
 *
 * CIBA Core leaves the authentication device — how the user is reached and how
 * they authenticate — outside the specification (§7.1). This UI implements it
 * as an OP-hosted browser page the user visits themselves: sign in at /ciba,
 * review the pending requests addressed to you (client, scopes,
 * binding_message), and approve or deny. The consumption device learns the
 * outcome only by polling the token endpoint — there is no push channel in
 * poll mode.
 *
 * The three steps of steps/ are the three steps of that UI. None of them
 * builds a Response: each returns an outcome (which screen comes next, with
 * which cookies), and page.tsx — which owns the GET and POST routes — turns it
 * into HTTP.
 *
 * ## Why the login form demands a binding cookie
 *
 * A successful login establishes an OP session, whose reach goes beyond CIBA
 * (SSO, prompt=none). A hidden csrf_token alone cannot stop login CSRF: the
 * attacker fetches their own login form, reads a valid transaction id + token
 * pair, and embeds both in a forged cross-site POST — planting the attacker's
 * session in the victim's browser. The login transaction's binding cookie
 * (minted by prepare-device, hash-stored) is what stops it — see
 * buildCibaLoginBindingCookie() in ../../cookies.ts for the full model.
 *
 * ## Why approve / deny does NOT use a binding cookie
 *
 * The approval is already bound to the authenticated OP session: the record's
 * subject must equal the session subject, and the per-record csrf_token is only
 * ever rendered on the session-gated listing. Knowing an auth_req_id gives an
 * attacker no step to forge.
 */
import { CibaVerificationError, listPendingCibaRequests } from '@maronn-openid-connect/experimental/ciba';
import { resolveGrantableScopes } from '../../../../scopes.js';

/** One pending backchannel authentication request, as the approval screen shows it. */
export interface CibaPendingRequest {
  /** auth_req_id; posted back by the decision form. */
  authReqId: string;
  clientId: string;
  /** Scopes this End-User is asked to grant (already narrowed by the scope policy). */
  scopes: string[];
  /** CIBA Core 1.0 §7.1 binding_message, client-supplied: escape before rendering. */
  bindingMessage?: string;
  expiresInSeconds: number;
  /** Per-record CSRF token; posted back by the decision form. */
  csrfToken: string;
}

/** What a step of the UI decided; page.tsx turns it into the next screen. */
export type CibaOutcome =
  /** A binding or CSRF failure the OP shows on its own error page. */
  | { kind: 'error'; error: string; statusCode: number }
  /** The decision step needs an OP session this browser does not have (401). */
  | { kind: 'session_required' }
  /** decision was neither approve nor deny (400). */
  | { kind: 'invalid_decision' }
  /** recordCibaLoginFailure() discarded the login transaction: no further attempt (429). */
  | { kind: 'locked_out' }
  /** Show the sign-in form; cookies carries the binding its submission needs. */
  | { kind: 'login'; loginTransactionId: string; csrfToken: string; cookies: string[] }
  /** Wrong credentials: show the sign-in form again with the attempts left. */
  | {
      kind: 'invalid_credentials';
      loginTransactionId: string;
      csrfToken: string;
      remainingAttempts: number;
    }
  /** Show the signed-in user's pending requests; cookies carries a new OP session, if any. */
  | { kind: 'pending_requests'; requests: CibaPendingRequest[]; cookies: string[] }
  /** The decision is recorded. */
  | { kind: 'completed'; approved: boolean; clientId: string };

/** The fields of the sign-in form. */
export interface CibaLoginSubmission {
  loginTransactionId: string;
  csrfToken: string;
  username: string;
  password: string;
}

/** The fields of the approve / deny form. */
export interface CibaDecisionSubmission {
  authReqId: string;
  csrfToken: string;
  /** 'approve' or 'deny'. */
  decision: string;
}

/** Map a verification failure to the error to show; anything else is re-thrown. */
export function verificationFailure(error: unknown): CibaOutcome {
  if (error instanceof CibaVerificationError) {
    return { kind: 'error', error: error.message, statusCode: error.statusCode };
  }
  throw error;
}

/** Remaining lifetime of a pending request, in whole seconds, never negative. */
export function remainingSeconds(expiresAt: Date): number {
  return Math.max(0, Math.ceil((expiresAt.getTime() - Date.now()) / 1000));
}

/**
 * The session subject's pending requests with freshly rotated CSRF tokens (the
 * only place those tokens are ever exposed, and it is session-gated).
 */
export async function listPendingRequests(c: any, subject: string): Promise<CibaPendingRequest[]> {
  const cibaStore = c.get('cibaAuthenticationRequestStore');
  const pending = await listPendingCibaRequests({ subject, store: cibaStore });
  return Promise.all(
    pending.map(async (record) => ({
      authReqId: record.authReqId,
      clientId: record.clientId,
      // Show only what this End-User can actually grant (scopes.ts).
      scopes: await resolveGrantableScopes(record.scope, subject),
      bindingMessage: record.bindingMessage,
      expiresInSeconds: remainingSeconds(record.expiresAt),
      csrfToken: record.csrfToken ?? '',
    })),
  );
}
```

#### `features/ciba/endpoints/ciba/steps/prepare-device.ts`

The step of `GET /ciba`.
With an OP session it lists the pending requests addressed to that user.
Without one it creates a login transaction with `createCibaLoginTransaction()` and returns the sign-in form together with the binding cookie its submission needs.
The cookie's `Max-Age` follows the remaining lifetime of the transaction.

```typescript
import { createCibaLoginTransaction } from '@maronn-openid-connect/experimental/ciba';
import { buildCibaLoginBindingCookie } from '../../../cookies.js';
import { parseSessionId } from '../../../../../cookies.js';
import { type CibaOutcome, remainingSeconds, listPendingRequests } from '../outcome.js';
import { step } from '../../../../../endpoints/step.js';

export const meta = step({
  id: 'prepare-device',
  endpoint: 'ciba',
  feature: 'ciba',
  kind: 'resolve',
  label: 'List pending requests, or start a login transaction',
  function: 'prepareCibaDevice',
  calls: ['listPendingCibaRequests', 'createCibaLoginTransaction', 'buildCibaLoginBindingCookie'],
  consumes: [],
  produces: ['loginTransaction'],
  removable: false,
});

/**
 * Listing / login form (GET /ciba)
 *
 * With an OP session: the pending requests addressed to the signed-in user.
 * Without one: mint a login transaction and describe the sign-in form, with the
 * binding cookie its submission needs.
 */
export async function prepareCibaDevice(c: any): Promise<CibaOutcome> {
  const browserSessionStore = c.get('browserSessionStore');
  const loginTransactionStore = c.get('cibaLoginTransactionStore');

  const sessionId = parseSessionId(c.req.header('Cookie') ?? null);
  const session = sessionId ? await browserSessionStore.get(sessionId) : undefined;
  if (session) {
    return { kind: 'pending_requests', requests: await listPendingRequests(c, session.subject), cookies: [] };
  }

  const { record, bindingSecret } = await createCibaLoginTransaction(loginTransactionStore);
  const cookie = buildCibaLoginBindingCookie(
    record.id,
    bindingSecret,
    remainingSeconds(record.expiresAt),
  );
  return {
    kind: 'login',
    loginTransactionId: record.id,
    csrfToken: record.csrfToken,
    cookies: [cookie],
  };
}
```

#### `features/ciba/endpoints/ciba/steps/submit-login.ts`

The step that signs the user in on this browser at `POST /ciba/login`.
`validateCibaLoginSubmission()` checks the binding and CSRF, and answers an unknown or expired transaction and every mismatch with the same 403.
The credential check is the single call to `c.get('authenticateUser')`, which can be swapped for LDAP, WebAuthn or an upstream IdP.

`recordCibaLoginFailure()` counts failures per transaction and, at `maxLoginAttempts`, discards the transaction, so that form cannot be retried.
The count is per transaction only.
Reopening `/ciba` creates a new transaction, so the overall password-guessing budget is the same as on `/login`.

On success the step consumes the transaction and establishes the OP session under a newly minted id.
It never reuses an id the request brought along, which prevents session fixation.
The list screen carries two cookies: the new session cookie and the cleared binding cookie.

```typescript
import { recordCibaLoginFailure, validateCibaLoginSubmission } from '@maronn-openid-connect/experimental/ciba';
import { generateRandomString } from '@maronn-openid-connect/core';
import {
  buildClearedCibaLoginBindingCookie,
  parseCibaLoginBindingSecret,
} from '../../../cookies.js';
import { buildSessionCookie } from '../../../../../cookies.js';
import { cibaConfig } from '../../../config.js';
import { type CibaOutcome, type CibaLoginSubmission, verificationFailure, listPendingRequests } from '../outcome.js';
import { step } from '../../../../../endpoints/step.js';

export const meta = step({
  id: 'submit-login',
  endpoint: 'ciba',
  feature: 'ciba',
  kind: 'validate',
  label: 'Sign the End-User in on this browser',
  function: 'submitCibaLogin',
  calls: ['validateCibaLoginSubmission', 'recordCibaLoginFailure', 'buildSessionCookie'],
  consumes: ['loginTransaction'],
  produces: ['session'],
  removable: false,
});

/**
 * Sign in (POST /ciba/login)
 *
 * Binding first, then CSRF, then credentials: the binding is what proves this
 * is the browser the login form was issued to, and it must gate the step that
 * would otherwise let a forged POST establish an OP session in the victim's
 * browser.
 */
export async function submitCibaLogin(c: any, input: CibaLoginSubmission): Promise<CibaOutcome> {
  const { loginTransactionId: transactionId, csrfToken, username, password } = input;

  const browserSessionStore = c.get('browserSessionStore');
  const loginTransactionStore = c.get('cibaLoginTransactionStore');
  const authenticateUser = c.get('authenticateUser');

  let transaction;
  try {
    transaction = await validateCibaLoginSubmission({
      transactionId,
      csrfToken,
      bindingSecret: parseCibaLoginBindingSecret(c.req.header('Cookie') ?? null, transactionId),
      store: loginTransactionStore,
    });
  } catch (error) {
    return verificationFailure(error);
  }

  // Swap point: replace this with your own credential check (LDAP, WebAuthn, an
  // upstream IdP) without touching anything above or below it.
  const user = await authenticateUser(username, password);
  if (!user) {
    // Per-transaction throttling only. Anyone can mint fresh login
    // transactions by reloading /ciba, so the aggregate password-guess budget
    // is the same as the one on /login. Subject-scoped throttling is a
    // separate concern.
    const failure = await recordCibaLoginFailure(
      transaction,
      loginTransactionStore,
      cibaConfig.maxLoginAttempts,
    );
    if (!failure.canRetry) {
      // The transaction is gone: this form cannot be retried at all.
      return { kind: 'locked_out' };
    }
    return {
      kind: 'invalid_credentials',
      loginTransactionId: transaction.id,
      csrfToken: transaction.csrfToken,
      remainingAttempts: failure.remainingAttempts,
    };
  }

  // The transaction is single-use: a successful login consumes it, and the
  // session is established under a NEWLY minted id (never one the request
  // brought along — session fixation).
  await loginTransactionStore.delete(transaction.id);
  const authTime = Math.floor(Date.now() / 1000);
  const sessionId = generateRandomString(32);
  await browserSessionStore.set(sessionId, { subject: user.sub, authTime });

  // Two cookies travel with the listing: the new OP session, and the cleared
  // login binding (it is single-use and would otherwise linger until Max-Age).
  return {
    kind: 'pending_requests',
    requests: await listPendingRequests(c, user.sub),
    cookies: [buildSessionCookie(sessionId), buildClearedCibaLoginBindingCookie(transaction.id)],
  };
}
```

#### `features/ciba/endpoints/ciba/steps/submit-decision.ts`

The step that records the approval or denial at `POST /ciba/approve`.
It is the only step of the authentication device screens that changes state, and it demands an OP session whose subject owns the record plus the per-record `csrf_token` from the session-gated list.
`decision` must be either `approve` or `deny`.

On approval, `approveCibaRequest()` validates the subject and the CSRF token and marks the record approved.
The step mints the grantId and hands it in, so the existing revocation machinery applies grant-scoped revocation unchanged.
It then narrows the approved scope with `resolveGrantableScopes()` and stores the record again.
The token endpoint reads `approvedScope`, and RFC 6749 §3.3 allows a granted scope narrower than the request.
Consent and the grant are recorded the same way `/consent` records them, so a later authorization code flow of the same client can skip the consent screen (OIDC Core 1.0 §3.1.2.4).
On denial, the step first reads the client to show on the completion screen from the record, then denies with `denyCibaRequest()`.

```typescript
import { approveCibaRequest, denyCibaRequest } from '@maronn-openid-connect/experimental/ciba';
import { generateRandomString } from '@maronn-openid-connect/core';
import { parseSessionId } from '../../../../../cookies.js';
import { resolveGrantableScopes } from '../../../../../scopes.js';
import { type CibaOutcome, type CibaDecisionSubmission, verificationFailure } from '../outcome.js';
import { step } from '../../../../../endpoints/step.js';

export const meta = step({
  id: 'submit-decision',
  endpoint: 'ciba',
  feature: 'ciba',
  kind: 'persist',
  label: 'Approve or deny a pending request',
  spec: 'CIBA Core 1.0 §7.1 (authentication device)',
  function: 'submitCibaDecision',
  calls: ['approveCibaRequest', 'denyCibaRequest', 'consentResolver.recordConsent', 'consentResolver.recordGrant'],
  consumes: ['session'],
  produces: [],
  removable: false,
});

/**
 * Approve or deny (POST /ciba/approve)
 *
 * The only state-changing step of the UI. It demands an OP session whose
 * subject owns the record, plus the per-record csrf_token from the
 * session-gated listing.
 */
export async function submitCibaDecision(c: any, input: CibaDecisionSubmission): Promise<CibaOutcome> {
  const { authReqId, csrfToken, decision } = input;

  const browserSessionStore = c.get('browserSessionStore');
  const cibaStore = c.get('cibaAuthenticationRequestStore');
  const consentResolver = c.get('consentResolver');

  const sessionId = parseSessionId(c.req.header('Cookie') ?? null);
  const session = sessionId ? await browserSessionStore.get(sessionId) : undefined;
  if (!session) {
    return { kind: 'session_required' };
  }

  if (decision !== 'approve' && decision !== 'deny') {
    return { kind: 'invalid_decision' };
  }

  try {
    if (decision === 'approve') {
      // subject and csrf_token are validated inside; the record moves to
      // approved with auth_time, scope and a fresh grantId the token endpoint
      // reads.
      const approved = await approveCibaRequest({
        authReqId,
        subject: session.subject,
        csrfToken,
        authTime: session.authTime,
        grantId: generateRandomString(32),
        store: cibaStore,
      });
      // Apply the scope policy to what was approved. approveCibaRequest()
      // copies the requested scope into approvedScope, so the policy is applied
      // to the record afterwards and persisted; the token endpoint reads
      // approvedScope, and RFC 6749 §3.3 allows a granted scope narrower than the
      // request. Write the policy in resolveGrantableScopes() (scopes.ts).
      approved.approvedScope = await resolveGrantableScopes(
        approved.approvedScope ?? approved.scope,
        session.subject,
      );
      await cibaStore.update(approved);

      // Record the consent the same way /consent does, so a later Authorization
      // Code Flow for this client skips the consent screen (OIDC Core 1.0 §3.1.2.4).
      await consentResolver?.recordConsent?.(
        approved.subject,
        approved.clientId,
        approved.approvedScope ?? approved.scope,
      );
      await consentResolver?.recordGrant?.(approved.subject, approved.clientId, approved.grantId);
      return { kind: 'completed', approved: true, clientId: approved.clientId };
    }

    const record = await cibaStore.findByAuthReqId(authReqId);
    await denyCibaRequest({
      authReqId,
      subject: session.subject,
      csrfToken,
      store: cibaStore,
    });
    return { kind: 'completed', approved: false, clientId: record?.clientId ?? '' };
  } catch (error) {
    return verificationFailure(error);
  }
}
```

#### `features/ciba/steps/dispatch-ciba.ts`

The step the dispatch-ciba block of the token endpoint calls.
`before: ['validate-grant-type']` in its `meta` declares that a `--flow` reordering keeps it ahead of the `grant_type` validation.
For any `grant_type` other than the CIBA grant it does nothing and returns `undefined`.

`processCibaGrant()` is the CIBA §11 state machine: every state except approved (`authorization_pending`, `slow_down`, `access_denied`, `expired_token`) as well as `invalid_request` and `invalid_grant` are thrown.
The thrown `CibaGrantError` is rewrapped at the end of the step as the base `TokenEndpointError`, which the base `respond-error` step returns as it is.

An approved record gets its tokens.
They are assembled with the same core functions as the base steps from `issue-access-token` to `persist-access-token`, but the step does not join the rest of the pipeline; it goes all the way to `respondToken()` itself.
The `cibaConfig` inside the step is the provider-wide configuration read with `c.get('config')`, not the `cibaConfig` of `features/ciba/config.ts`.
The access token is signed with the first key of the registered key set.
The ID Token key follows the same rule as the standard grants: the key whose alg matches the client's registered `id_token_signed_response_alg`.
Taking the first key would hand an ES256-registered client an RS256 ID Token and compute at_hash with the wrong algorithm.
With no matching key the answer is a 500 `server_error`.

The backchannel authentication endpoint requires `openid`, so an ID Token is always issued.
CIBA §7.1 has no nonce parameter and there is no authorization code, so the ID Token carries neither nonce nor c_hash.
Poll mode adds no CIBA-specific claims either (the `auth_req_id` claim of §10.3.1 belongs to the push-mode token delivery message).
The access token record inherits the grantId minted at approval, so revoking the grant revokes every token issued from this backchannel authentication.
A refresh token is issued only when `offline_access` is still in the scope, and the approval screen the user went through is the explicit consent §11 asks for.

```typescript
import {
  type TokenClientInfo,
  selectSigningKeyByAlg,
  type SigningKey,
  buildAccessTokenAudience,
  buildAccessTokenPayload,
  createJwtAccessTokenIssuer,
  createOpaqueAccessTokenIssuer,
  type AccessTokenIssuer,
  buildIdTokenPayload,
  computeAtHash,
  generateIdToken,
  resolveAcrAmr,
  generateRandomString,
  type AcrResolver,
} from '@maronn-openid-connect/core';
import type { RegisteredClient } from '../../../config.js';
import { CIBA_GRANT_TYPE, CibaGrantError, processCibaGrant } from '@maronn-openid-connect/experimental/ciba';
import { type TokenRequestBody, TokenEndpointError } from '../../../endpoints/token/response.js';
import { respondToken } from '../../../endpoints/token/steps/respond.js';
import { step } from '../../../endpoints/step.js';

export const meta = step({
  id: 'dispatch-ciba',
  endpoint: 'token',
  feature: 'ciba',
  kind: 'dispatch',
  label: 'Redeem an auth_req_id (CIBA)',
  spec: 'CIBA Core 1.0 §10.1 / §11',
  function: 'redeemCibaRequest',
  calls: ['processCibaGrant', 'selectSigningKeyByAlg', 'buildAccessTokenAudience', 'buildAccessTokenPayload', 'computeAtHash', 'resolveAcrAmr', 'buildIdTokenPayload', 'generateIdToken'],
  consumes: ['params', 'tokenClient', 'authenticatedClientId'],
  produces: [],
  removable: false,
  before: ['validate-grant-type'],
});

/**
 * EXPERIMENTAL — CIBA grant (CIBA Core 1.0 §10.1, poll mode).
 *
 * Dispatched right after client authentication and BEFORE the grant_type
 * validation, which does not know the URN and would reject it with
 * unsupported_grant_type. Answers the request itself and never falls through
 * to the standard grants; returns undefined for any other grant_type.
 *
 * Backed by @maronn-openid-connect/experimental, whose API is NOT stable: it may change
 * in a breaking way between releases. Do not build production code on it
 * without pinning the version.
 */
export async function redeemCibaRequest(
  c: any,
  params: TokenRequestBody,
  tokenClient: TokenClientInfo,
  authenticatedClientId: string,
): Promise<Response | undefined> {
  if (params.grant_type !== CIBA_GRANT_TYPE) return undefined;

  try {
    const tokenClientResolver = c.get('tokenClientResolver');
    const accessTokenStore = c.get('accessTokenStore');
    const cibaStore = c.get('cibaAuthenticationRequestStore');

    // CIBA §11 state machine. Everything except "approved" throws:
    // authorization_pending / slow_down / access_denied / expired_token, plus
    // invalid_request / invalid_grant.
    const cibaGrant = await processCibaGrant({
      params,
      client: tokenClient,
      store: cibaStore,
    });

    const cibaConfig = c.get('config');
    // The first registered key signs new tokens (SigningKeyProvider contract).
    const cibaSigningKey: SigningKey = c.get('signingKeys')[0];
    const cibaPrivateKey = cibaSigningKey.privateKey;
    const cibaKeyId = cibaSigningKey.keyId;
    // T-022: the ID Token this grant issues follows the SAME key-selection rule
    // as the standard grants — pick a registered ID Token key whose alg matches
    // the client's id_token_signed_response_alg (OIDC Dynamic Client
    // Registration 1.0 §2), not simply the first key of the set. Using the
    // first key would hand an ES256-registered client an RS256 ID Token, which
    // it rejects, and would hash at_hash with the wrong algorithm.
    const cibaIdTokenSigningKeys = (c.get('idTokenSigningKeys') as SigningKey[] | undefined) ?? [];
    const cibaRegisteredClient = (await tokenClientResolver.findClient(
      authenticatedClientId,
    )) as RegisteredClient | null;
    const cibaRequestedIdTokenAlg = cibaRegisteredClient?.idTokenSignedResponseAlg;
    let cibaSelectedIdTokenKey: SigningKey;
    try {
      cibaSelectedIdTokenKey = selectSigningKeyByAlg(cibaIdTokenSigningKeys, cibaRequestedIdTokenAlg);
    } catch {
      throw new TokenEndpointError({
        status: 500,
        body: {
          error: 'server_error',
          error_description: `No ID Token signing key registered for alg "${cibaRequestedIdTokenAlg ?? 'RS256'}"`,
        },
      });
    }
    const cibaIdTokenPrivateKey = cibaSelectedIdTokenKey.privateKey;
    const cibaIdTokenKeyId = cibaSelectedIdTokenKey.keyId;
    const cibaIssuer: AccessTokenIssuer =
      cibaConfig.accessTokenFormat === 'opaque'
        ? createOpaqueAccessTokenIssuer()
        : createJwtAccessTokenIssuer();

    // Same aud policy as the standard grants: the UserInfo endpoint stays a
    // permanent member (RFC 9068 §3). CIBA §7.1 has no resource parameter,
    // so nothing else is requested.
    const cibaAudience = buildAccessTokenAudience({
      userInfoEndpoint: `${cibaConfig.issuer}/userinfo`,
      issuer: cibaConfig.issuer,
    });

    const cibaIssuedAt = Math.floor(Date.now() / 1000);
    const cibaAccessTokenPayload = buildAccessTokenPayload({
      issuer: cibaConfig.issuer,
      subject: cibaGrant.subject,
      clientId: cibaGrant.clientId,
      scope: cibaGrant.scope,
      audience: cibaAudience,
      expiresIn: cibaConfig.accessTokenExpiresIn,
      issuedAt: cibaIssuedAt,
    });
    const cibaAccessToken = await cibaIssuer.issue({
      payload: cibaAccessTokenPayload,
      privateKey: cibaPrivateKey,
      keyId: cibaKeyId,
    });

    // The backchannel authentication endpoint requires the openid scope, so
    // an ID Token is always issued. It carries no nonce (CIBA §7.1 defines no
    // such parameter, and OIDC Core 1.0 §2 only requires nonce when the
    // authentication request carried one) and no c_hash (there is no code).
    // Poll mode adds no CIBA-specific claims either — the auth_req_id claim
    // of §10.3.1 belongs to the push-mode token delivery message.
    const cibaAtHash = await computeAtHash(cibaAccessToken, cibaIdTokenPrivateKey);
    const cibaAcrResolver = c.get('acrResolver') as AcrResolver | undefined;
    const { acr: cibaAcr, amr: cibaAmr } = await resolveAcrAmr({
      subject: cibaGrant.subject,
      clientId: cibaGrant.clientId,
      acrResolver: cibaAcrResolver,
    });
    const cibaIdTokenPayload = buildIdTokenPayload({
      issuer: cibaConfig.issuer,
      subject: cibaGrant.subject,
      clientId: cibaGrant.clientId,
      scope: cibaGrant.scope,
      expiresIn: cibaConfig.idTokenExpiresIn,
      issuedAt: cibaIssuedAt,
      atHash: cibaAtHash,
      authTime: cibaGrant.authTime,
      acr: cibaAcr,
      amr: cibaAmr,
    });
    const cibaIdToken = await generateIdToken({
      payload: cibaIdTokenPayload,
      privateKey: cibaIdTokenPrivateKey,
      keyId: cibaIdTokenKeyId,
    });

    await accessTokenStore.set(cibaAccessToken, {
      sub: cibaGrant.subject,
      clientId: cibaGrant.clientId,
      scope: cibaGrant.scope,
      expiresAt: cibaIssuedAt + cibaConfig.accessTokenExpiresIn,
      // Inherit the grantId minted at approval so revoking the grant kills
      // every token issued from this backchannel authentication.
      grantId: cibaGrant.grantId,
      iat: cibaIssuedAt,
      nbf: cibaIssuedAt,
      audience: cibaAudience,
      issuer: cibaConfig.issuer,
      jti: cibaAccessTokenPayload.jti,
    });

    // OIDC Core 1.0 §11: offline_access survived the backchannel
    // authentication endpoint's policy check only if this client may hold
    // refresh tokens, and the approval screen the user just went through IS
    // the explicit consent that §11 asks for. Nothing further to gate on here.
    const cibaRefreshToken = cibaGrant.scope.includes('offline_access')
      ? generateRandomString(32)
      : undefined;
    if (cibaRefreshToken) {
      const cibaRefreshTokenStore = c.get('refreshTokenStore');
      await cibaRefreshTokenStore.set(cibaRefreshToken, {
        subject: cibaGrant.subject,
        clientId: cibaGrant.clientId,
        scope: cibaGrant.scope,
        // OAuth 2.1 §6.1: absolute lifetime from initial issuance; rotations
        // inherit originalIssuedAt so the deadline never slides forward.
        expiresAt: cibaIssuedAt + cibaConfig.refreshTokenAbsoluteLifetime,
        originalIssuedAt: cibaIssuedAt,
        used: false,
        grantId: cibaGrant.grantId,
        iat: cibaIssuedAt,
        issuer: cibaConfig.issuer,
        audience: cibaAudience,
        authTime: cibaGrant.authTime,
        // CIBA §7.1 defines no nonce parameter, so the re-issued ID Token has
        // none to preserve either.
        nonce: undefined,
        acr: cibaAcr,
        amr: cibaAmr,
        azp: undefined,
      });
    }

    return respondToken(c, {
      status: 200,
      body: {
        access_token: cibaAccessToken,
        token_type: 'Bearer' as const,
        expires_in: cibaConfig.accessTokenExpiresIn,
        id_token: cibaIdToken,
        scope: cibaGrant.scope.join(' '),
        refresh_token: cibaRefreshToken,
      },
    });
  } catch (error) {
    // CIBA §11: authorization_pending / slow_down / access_denied /
    // expired_token use the RFC 6749 §5.2 shape and are always 400. A 401 can
    // only come from client authentication, which runs before the branch and
    // throws core's TokenError.
    if (error instanceof CibaGrantError) {
      throw new TokenEndpointError({
        status: error.statusCode,
        body: { error: error.code, error_description: error.errorDescription },
      });
    }
    throw error;
  }
}
```

### The other frameworks

The Express and Fastify output has the same files.
The generator replaces the `hono` imports of the endpoints with `WebRouter` / `WebContext` of `web-router.ts` (a small router on the Fetch API) and adds an `apply.ts` for the framework, `web-router.ts` and `node-adapter.ts`.
What is replaced and which files are added is defined in [packages/cli/extract.json](../../../packages/cli/extract.json); the router and the adapters live in [apps/hono/src/web/](../../../apps/hono/src/web/).
The authentication device screens stay hono/jsx, so these outputs still need `hono` as the JSX runtime.

The Next.js output is extracted from [apps/nextjs](../../../apps/nextjs), a Next.js App Router app.
This feature's route files live in the route group `app/(ciba)/` and its code in `app/_oidc-provider/features/ciba/`.

### Samples and the E2E environment

All four samples (hono-cloudflare, express-flyio, fastify-flyio, nextjs-vercel) have `--enable ciba` in the `generate` script of their `package.json`.
The `src/app.ts` of the hono, express and fastify samples has no CIBA-specific wiring.
No `cibaUserResolver` is passed, so a `login_hint` is resolved as a username of the user store.
The E2E client app sends `login_hint=testuser` by default, which matches a development user the samples register (testuser and otheruser of `development.ts`).

The E2E clients are handed to the samples by [tests/e2e/playwright.config.ts](../../../tests/e2e/playwright.config.ts) in the environment variable `OIDC_CLIENTS_JSON`.
The `grantTypes` of `e2e-client` include the CIBA URN, and `e2e-ciba-other` exists to prove that an auth_req_id presented by another client is refused.
`e2e-scope-limited`, which exercises the registered-scope check, has the CIBA URN too.
The samples register this list in the client tables of `db/` at startup, and the development users the same way.
This is the part of [samples/express-flyio/src/app.ts](../../../samples/express-flyio/src/app.ts) that does it; [samples/fastify-flyio/src/app.ts](../../../samples/fastify-flyio/src/app.ts) has the same code.

```typescript
// The generated app reads its clients from the client tables of db/ (--db), so
// the sample clients (OIDC_CLIENTS_JSON, or the E2E defaults below) are
// registered there at startup. registerClient() replaces an earlier
// registration of the same client_id, so a restart picks up changed clients.
const clients = readRegisteredClients();
for (const client of clients.values()) {
  await registerClient(createDatabase(), client);
}

// Users are read from the users table too. E2E and the conformance suite sign
// in as the development users of development.ts (testuser / otheruser,
// password "password"), so they are registered there with their claims.
for (const user of developmentUsers) {
  await registerUser(createDatabase(), user);
}
```

[samples/hono-cloudflare/src/app.ts](../../../samples/hono-cloudflare/src/app.ts) does the same registration on the first request of each isolate, because Workers reach D1 only while handling a request.

```typescript
// The sample clients (OIDC_CLIENTS_JSON, or the E2E defaults below) and the
// development users are registered in the D1 tables the generated app reads.
// Workers reach D1 only while handling a request, so the first request of
// each isolate registers them before the OP handles it. registerClient()
// writes the same rows when the values are the same, so isolates that start
// at the same moment do not conflict.
let sampleDataRegistered = false;
app.use('*', async (c, next) => {
  if (!sampleDataRegistered) {
    await registerSampleData(createDatabase(c));
    sampleDataRegistered = true;
  }
  await next();
});
```

```typescript
async function registerSampleData(db: Database): Promise<void> {
  // registerClient() replaces an earlier registration of the same client_id,
  // so a restart picks up changed clients.
  for (const client of clients.values()) {
    await registerClient(db, client);
  }

  // E2E and the conformance suite sign in as the development users of
  // development.ts (testuser / otheruser, password "password").
  // registerDevelopmentUsers() leaves a user that is already registered as
  // it is, since hashing the password costs CPU time on every isolate.
  await registerDevelopmentUsers(db);
}
```

The consumption device is played by the E2E client app, [tests/e2e/apps/client.mjs](../../../tests/e2e/apps/client.mjs).
`/start-ciba` sends the backchannel authentication request and starts background polling (including the +5 seconds after `slow_down`), and `/ciba-result` reports how far that polling has come.
These are the parts of the client app.

```javascript
const cibaFlows = new Map();
```

```javascript
    // EXPERIMENTAL (CIBA Core 1.0, poll mode): act as the consumption device —
    // present a login_hint over the back channel and start polling the token
    // endpoint in the background while the user approves on their own browser.
    if (req.method === 'GET' && url.pathname === '/start-ciba') {
      await startCibaAuthentication(url, res);
      return;
    }
    // Report what the background polling has reached so far, so the spec can
    // wait for the outcome instead of reimplementing the poll loop.
    if (req.method === 'GET' && url.pathname === '/ciba-result') {
      reportCibaResult(url, res);
      return;
    }
```

The poll loop skips a round whose body cannot be read as JSON with `readJsonBody()`, and `failFlowOnError()` records an unexpected failure of the loop itself on the flow.
Both are helpers of the same file, shared with the device-flow polling.

```javascript
/**
 * EXPERIMENTAL — CIBA Core 1.0 §7.1 / §10.1 (poll mode).
 *
 * Plays the consumption device: one back-channel POST naming the user via
 * login_hint, then a poll loop that honors the interval the OP asked for,
 * including the +5 seconds a slow_down response demands (§11).
 */
async function startCibaAuthentication(requestUrl, res) {
  const fields = {
    client_id: clientId,
    client_secret: clientSecret,
    scope: requestUrl.searchParams.get('scope') ?? 'openid profile email',
    login_hint: requestUrl.searchParams.get('login_hint') ?? 'testuser',
  };
  const bindingMessage = requestUrl.searchParams.get('binding_message');
  if (bindingMessage !== null) {
    fields.binding_message = bindingMessage;
  }
  const authentication = await formPost(new URL('/backchannel_authentication', issuer), fields);

  const flowId = randomString(16);
  const flow = {
    status: 'pending',
    tokens: null,
    error: null,
  };
  cibaFlows.set(flowId, flow);

  // Deliberately not awaited: the device keeps polling while the spec drives
  // the browser through the authentication device UI.
  void pollCibaToken(flow, authentication.auth_req_id, authentication.interval)
    .catch((error) => failFlowOnError(flow, error));

  sendJson(res, 200, {
    flow_id: flowId,
    auth_req_id: authentication.auth_req_id,
    expires_in: authentication.expires_in,
    interval: authentication.interval,
  });
}

async function pollCibaToken(flow, authReqId, initialInterval) {
  let intervalSeconds = initialInterval ?? 5;
  const deadline = Date.now() + 60_000;

  while (Date.now() < deadline) {
    await sleep(intervalSeconds * 1000);
    const response = await fetch(new URL('/token', issuer), {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'urn:openid:params:grant-type:ciba',
        auth_req_id: authReqId,
        client_id: clientId,
        client_secret: clientSecret,
      }).toString(),
    });
    const body = await readJsonBody(response);
    // Same transient tolerance as the device poll loop above.
    if (body === null) continue;

    if (response.ok) {
      flow.status = 'complete';
      flow.tokens = body;
      return;
    }
    if (body.error === 'authorization_pending') continue;
    // CIBA §11: after slow_down the client MUST add 5 seconds.
    if (body.error === 'slow_down') {
      intervalSeconds += 5;
      continue;
    }
    flow.status = 'failed';
    flow.error = body.error;
    return;
  }

  flow.status = 'failed';
  flow.error = 'timeout';
}

function reportCibaResult(url, res) {
  const flowId = requireSearchParam(url, 'flow_id');
  const flow = cibaFlows.get(flowId);
  if (flow === undefined) {
    sendJson(res, 404, { error: 'unknown_flow' });
    return;
  }
  sendJson(res, 200, {
    status: flow.status,
    error: flow.error,
    access_token: flow.tokens?.access_token ?? null,
    id_token: flow.tokens?.id_token ?? null,
    scope: flow.tokens?.scope ?? null,
    token_type: flow.tokens?.token_type ?? null,
  });
}
```

## The E2E spec in full

The E2E suite verifies the full round trip with a real browser (Playwright) and real HTTP: the approval flow (backchannel request → sign in on the browser → find one's own request by its `binding_message` and approve → polling completes → UserInfo), the denial flow (receiving `access_denied`), `authorization_pending` before the decision, refusal of a forged login POST without the binding cookie, and refusal of an `auth_req_id` presented by another client.
Against a sample OP generated without `--enable ciba`, every test skips itself based on discovery.

Each flow carries a unique `binding_message` because the OP process outlives individual tests: the spec can pick its own request's section out of the pending list even when earlier tests left records behind.

```typescript
import { expect, test } from '@playwright/test';

const host = process.env.E2E_HOST ?? '127.0.0.1';
const clientPort = Number(process.env.E2E_CLIENT_PORT ?? '3020');
const clientBaseURL =
  process.env.E2E_CLIENT_BASE_URL ?? `http://${host}:${clientPort}`;
const clientId = 'e2e-client';
const clientSecret = 'e2e-client-secret';
const CIBA_GRANT_TYPE = 'urn:openid:params:grant-type:ciba';

interface StartedCibaFlow {
  flow_id: string;
  auth_req_id: string;
  expires_in: number;
  interval: number;
}

interface CibaResult {
  status: 'pending' | 'complete' | 'failed';
  error: string | null;
  access_token: string | null;
  id_token: string | null;
  scope: string | null;
  token_type: string | null;
}

/**
 * EXPERIMENTAL — OpenID Connect Client-Initiated Backchannel Authentication
 * (CIBA Core 1.0, poll mode).
 *
 * Only the samples generated with `--enable ciba` expose the endpoint, so every
 * test here skips when discovery does not advertise it. That keeps the shared
 * spec suite green across all sample OPs.
 *
 * The consumption-device side runs inside the E2E client (`/start-ciba`), which
 * polls the token endpoint in the background while Playwright drives the
 * browser through the authentication device UI — the real two-device shape of
 * the flow. Each flow carries a unique binding_message so the spec can pick its
 * own request out of the pending list even when earlier tests left records
 * behind (the OP process persists across tests).
 */
test.describe('CIBA (CIBA Core 1.0, poll mode)', () => {
  test('should issue tokens after the user approves on their own browser', async ({
    page,
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const endpoint = await backchannelAuthenticationEndpoint(request, issuer);
    test.skip(
      endpoint === undefined,
      'This sample OP was generated without --enable ciba',
    );
    expect(endpoint).toBe(`${issuer}/backchannel_authentication`);

    const bindingMessage = `E2E-${Date.now()}`;
    const flow = await startCibaFlow(request, bindingMessage);
    expect(flow.interval).toBe(5);
    expect(flow.expires_in).toBe(120);

    // The user signs in on their own device (no session yet in this context).
    await page.goto(`${issuer}/ciba`);
    await page.getByLabel('Username:').fill('testuser');
    await page.getByLabel('Password:').fill('password');
    await page.getByRole('button', { name: 'Login' }).click();

    // The pending request shows the client, the scopes and the binding message
    // so the user can match it against the device that started it (§7.1).
    await expect(page.getByRole('heading', { name: 'Sign-in Requests' })).toBeVisible();
    const section = page.locator('section', { hasText: bindingMessage });
    await expect(section.locator('strong').first()).toHaveText(clientId);
    await expect(section.locator('li')).toHaveText(['openid', 'profile', 'email']);

    await section.getByRole('button', { name: 'Approve' }).click();
    await expect(page.getByText('You can close this page and go back to your device.')).toBeVisible();

    const result = await waitForCibaResult(request, flow.flow_id);
    expect(result.status).toBe('complete');
    expect(result.token_type).toBe('Bearer');
    expect(result.scope).toBe('openid profile email');
    expect(typeof result.id_token).toBe('string');

    // The consumption device's own token reaches the UserInfo endpoint.
    const userInfo = await request.get(`${issuer}/userinfo`, {
      headers: { Authorization: `Bearer ${result.access_token}` },
    });
    expect(userInfo.status()).toBe(200);
    expect((await userInfo.json()).sub).toBe('testuser');
  });

  test('should report access_denied to the device when the user denies', async ({
    page,
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const endpoint = await backchannelAuthenticationEndpoint(request, issuer);
    test.skip(
      endpoint === undefined,
      'This sample OP was generated without --enable ciba',
    );

    const bindingMessage = `E2E-DENY-${Date.now()}`;
    const flow = await startCibaFlow(request, bindingMessage);

    await page.goto(`${issuer}/ciba`);
    await page.getByLabel('Username:').fill('testuser');
    await page.getByLabel('Password:').fill('password');
    await page.getByRole('button', { name: 'Login' }).click();
    await page
      .locator('section', { hasText: bindingMessage })
      .getByRole('button', { name: 'Deny' })
      .click();
    await expect(page.getByText('You can close this page and go back to your device.')).toBeVisible();

    const result = await waitForCibaResult(request, flow.flow_id);
    expect(result.status).toBe('failed');
    expect(result.error).toBe('access_denied');
    expect(result.access_token).toBe(null);
  });

  test('should answer authorization_pending while the user has not decided', async ({
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const endpoint = await backchannelAuthenticationEndpoint(request, issuer);
    test.skip(
      endpoint === undefined,
      'This sample OP was generated without --enable ciba',
    );

    const authentication = await request.post(`${issuer}/backchannel_authentication`, {
      form: {
        client_id: clientId,
        client_secret: clientSecret,
        scope: 'openid',
        login_hint: 'testuser',
      },
    });
    expect(authentication.status()).toBe(200);
    expect(authentication.headers()['cache-control']).toBe('no-store');
    const codes = await authentication.json() as { auth_req_id: string };

    const poll = await request.post(`${issuer}/token`, {
      form: {
        grant_type: CIBA_GRANT_TYPE,
        auth_req_id: codes.auth_req_id,
        client_id: clientId,
        client_secret: clientSecret,
      },
    });

    expect(poll.status()).toBe(400);
    expect(await poll.json()).toEqual({
      error: 'authorization_pending',
      error_description: 'The authentication request is still pending',
    });
  });

  test('should refuse the login form without the browser binding cookie', async ({
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const endpoint = await backchannelAuthenticationEndpoint(request, issuer);
    test.skip(
      endpoint === undefined,
      'This sample OP was generated without --enable ciba',
    );

    // The attacker can load /ciba themselves and read a valid transaction id +
    // csrf_token pair. Without the binding cookie the pair is worth nothing: a
    // forged cross-site POST is refused, so no OP session can be planted.
    const form = await request.get(`${issuer}/ciba`);
    const html = await form.text();
    const loginTransactionId = html.match(/name="login_transaction_id" value="([^"]+)"/)?.[1] ?? '';
    const csrfToken = csrfTokenFrom(html);
    expect(loginTransactionId.length > 0).toBe(true);
    expect(csrfToken.length > 0).toBe(true);

    const forged = await request.post(`${issuer}/ciba/login`, {
      form: {
        login_transaction_id: loginTransactionId,
        csrf_token: csrfToken,
        username: 'testuser',
        password: 'password',
      },
      // Playwright's request context keeps cookies, so start from a clean state
      // to model a browser that never held this transaction's binding cookie.
      headers: { Cookie: '' },
    });

    expect(forged.status()).toBe(403);
  });

  test('should reject an auth_req_id presented by a different client', async ({
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const endpoint = await backchannelAuthenticationEndpoint(request, issuer);
    test.skip(
      endpoint === undefined,
      'This sample OP was generated without --enable ciba',
    );

    const authentication = await request.post(`${issuer}/backchannel_authentication`, {
      form: {
        client_id: clientId,
        client_secret: clientSecret,
        scope: 'openid',
        login_hint: 'testuser',
      },
    });
    const codes = await authentication.json() as { auth_req_id: string };

    // CIBA Core 1.0 §11: the auth_req_id belongs to the client it was issued
    // to. e2e-ciba-other authenticates fine and is registered for the CIBA
    // grant, so the only thing that stops it is the id's client binding.
    const poll = await request.post(`${issuer}/token`, {
      form: {
        grant_type: CIBA_GRANT_TYPE,
        auth_req_id: codes.auth_req_id,
        client_id: 'e2e-ciba-other',
        client_secret: 'e2e-ciba-other-secret',
      },
    });

    expect(poll.status()).toBe(400);
    // The wording matches the unknown-id case so existence is not leaked.
    expect(await poll.json()).toEqual({
      error: 'invalid_grant',
      error_description: 'The auth_req_id is invalid, expired, or was issued to another client',
    });
  });
});

async function startCibaFlow(
  request: { get(url: string): Promise<{ json(): Promise<unknown> }> },
  bindingMessage: string,
): Promise<StartedCibaFlow> {
  const response = await request.get(
    `${clientBaseURL}/start-ciba?binding_message=${encodeURIComponent(bindingMessage)}`,
  );
  return await response.json() as StartedCibaFlow;
}

/**
 * Poll the E2E client until its background CIBA polling settles.
 *
 * The OP's interval is 5 seconds, so the device needs a couple of poll cycles
 * after the browser finishes; 45 seconds leaves room for a slow_down bump.
 */
async function waitForCibaResult(
  request: { get(url: string): Promise<{ json(): Promise<unknown> }> },
  flowId: string,
): Promise<CibaResult> {
  const deadline = Date.now() + 45_000;
  let result = await readCibaResult(request, flowId);
  while (result.status === 'pending' && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 1_000));
    result = await readCibaResult(request, flowId);
  }
  return result;
}

async function readCibaResult(
  request: { get(url: string): Promise<{ json(): Promise<unknown> }> },
  flowId: string,
): Promise<CibaResult> {
  const response = await request.get(`${clientBaseURL}/ciba-result?flow_id=${flowId}`);
  return await response.json() as CibaResult;
}

async function backchannelAuthenticationEndpoint(
  request: { get(url: string): Promise<{ json(): Promise<unknown> }> },
  issuer: string,
): Promise<string | undefined> {
  const response = await request.get(`${issuer}/.well-known/openid-configuration`);
  const metadata = await response.json() as { backchannel_authentication_endpoint?: string };
  return metadata.backchannel_authentication_endpoint;
}

function csrfTokenFrom(html: string): string {
  return html.match(/name="csrf_token" value="([^"]+)"/)?.[1] ?? '';
}

function requireBaseUrl(baseURL: string | undefined): string {
  if (baseURL === undefined) {
    throw new Error('baseURL is not configured');
  }
  return baseURL;
}
```

## References

- [OpenID Connect Client-Initiated Backchannel Authentication Flow - Core 1.0](https://openid.net/specs/openid-client-initiated-backchannel-authentication-core-1_0.html)
- [RFC 6749 - The OAuth 2.0 Authorization Framework](https://www.rfc-editor.org/rfc/rfc6749)
- [RFC 8628 - OAuth 2.0 Device Authorization Grant](https://www.rfc-editor.org/rfc/rfc8628) (the polling state machine precedent; not normative for CIBA)
- Requirement documents: `tasks/experimental/done/ciba/` (specification, understanding guide, sources, review log)
- User-facing documentation: `docs/library-document/src/content/docs/experimental/ciba.md` in the OSS repository
