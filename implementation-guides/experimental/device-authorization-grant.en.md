# Device Authorization Grant: Implementation Guide

This document explains what was implemented for the **OAuth 2.0 Device Authorization Grant** (RFC 8628) in `packages/experimental`, and how, together with the complete source code involved.

The following code is embedded in full:

- all six implementation files, four test files, and the test fixture file under `packages/experimental/src/device-authorization-grant/`
- the complete diff that `--enable device-authorization-grant` adds to the CLI-generated code (hono)
- the complete Device Authorization Grant E2E test spec

The core package itself, the shared E2E harness, and the other frameworks' generated diffs are infrastructure shared by all features, so they are linked rather than embedded.
The embedded sources carry Japanese comments; the prose here conveys the same information.

## What the feature does

The Authorization Code Flow presumes it can take the user's browser to the OP by redirect and bring it back.
Smart TVs, CLI tools, and IoT boxes break that premise: they have no browser, or typing on them is painful.

The Device Authorization Grant solves this by moving the authorization to a second device the user already owns (a phone or a laptop browser).
The flow runs as three parallel threads:

1. The device POSTs to the OP's device authorization endpoint and receives a **device_code** (a long secret the device will redeem for tokens) paired with a **user_code** (a short transcription-friendly code such as `WDJB-MJHT`), and shows the user_code and a verification URL on its screen
2. The user opens the verification URL on their phone, types the user_code, logs in, and approves (or denies)
3. Meanwhile the device polls the token endpoint with `grant_type=urn:ietf:params:oauth:grant-type:device_code`, and the poll that lands after approval returns the token set

```text
Device                          OP                        User's browser
    │ POST /device_authorization │                              │
    │ ─────────────────────────> │                              │
    │ device_code + user_code    │                              │
    │ <───────────────────────── │                              │
    │ show user_code on screen   │        GET /device           │
    │                            │ <──────────────────────────  │
    │ POST /token (poll)         │        enter user_code       │
    │ ─────────────────────────> │        log in, approve       │
    │ authorization_pending      │ <──────────────────────────  │
    │ <───────────────────────── │                              │
    │ POST /token (poll)         │                              │
    │ ─────────────────────────> │                              │
    │ 200 { access_token, … }    │                              │
    │ <───────────────────────── │                              │
```

### Use cases

- A smart TV or set-top-box app getting authorized from the user's phone
- Reproducing a CLI login experience (in the style of `gh auth login`) against your own OP
- Authorization design for provisioning keyboard-less IoT devices

### Scope and non-goals

The implementation covers:

- the device authorization endpoint (RFC 8628 §3.1 / §3.2)
- the verification UI's step functions (§3.3: user_code matching, browser binding, CSRF, approval and denial)
- the token endpoint's device-code branch (the §3.4 / §3.5 state machine)
- user_code generation and normalization (§6.1)

One known limitation: scope omission is not supported.
RFC 8628 §3.1 makes scope OPTIONAL, but this OP imposes the same profile restriction as its authorization endpoint (scope required, `openid` required) on device authorization too.
The verification UI also offers no partial scope approval; approval covers the requested scope as a whole.

## Design approach

This feature has the largest file set of the four.

| File | Role |
|---|---|
| `store.ts` | store contract, the grant-type URN, user_code charset constants |
| `errors.ts` | the two error types (OAuth errors and verification-UI errors) |
| `user-code.ts` | user_code generation, formatting, normalization |
| `device-authorization-request.ts` | the device authorization endpoint |
| `verification.ts` | the verification UI's step functions |
| `device-code-grant.ts` | the token endpoint's state machine |
| `index.ts` | public API re-exports |
| `test-helpers.ts` | test fixtures (excluded from the published artifact) |

The decision specific to this feature is making **browser binding** the primary CSRF defense of the verification UI.
A device flow's user_code is by design known to whoever started the flow, and that party can be the attacker.
A CSRF token merely tied to the record is therefore no defense at all: the attacker can obtain a legitimate one by POSTing `/device` themselves.
So on a successful user_code match the OP issues a **bindingSecret**, puts the raw value only in an HttpOnly browser cookie, and stores nothing but its SHA-256 hash on the record.
The login and approval steps refuse to run unless the cookie's raw value hashes to the record's stored hash.
A forged cross-site POST cannot carry the victim's cookie (SameSite=Lax), and the victim's browser never held a cookie for the attacker's record in the first place, so the attack is cut off without relying on token secrecy.
Where the authorize flow's transaction-binding is opt-in hardening, this binding is always on: a transaction_id is normally secret, but a user_code is known to the flow's initiator by construction, which turns binding into a baseline requirement here.

Information leakage is sealed with the same consistency as the other features.
A failed user_code match answers with one message whether the code is unknown, expired, or already used (RFC 8628 §5.1); a failed device_code resolution answers with one `invalid_grant` message whether the record is missing or belongs to another client; and generated user_codes never appear in logs or exception messages.

## The implementation, file by file

### store.ts (store contract and constants)

The record carries the state machine (`pending` / `approved` / `denied`), and only an approved record gains `subject` / `authTime` / `approvedScope` / `grantId`.
The user_code is stored twice on purpose: the normalized matching key (`userCode`) and the display form (`userCodeDisplay`).

The charset `BCDFGHJKLMNPQRSTVWXZ` is the base-20 set RFC 8628 §6.1 recommends, with visually confusable characters and vowels removed.
No vowels also means no accidental words.
Eight characters give 20^8 ≈ 2.6 × 10^10 of entropy.

The contract enforces single use at token issuance through `consume` (atomic fetch-and-delete).
A store whose `update` is not an atomic read-modify-write may enforce the polling interval loosely under concurrency, and the comments spell out why that is acceptable: as long as state transitions and `consume` hold, the security properties stand.

```typescript
/**
 * OAuth 2.0 Device Authorization Grant — RFC 8628
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * デバイス認可レコードのストア契約。
 */

/** RFC 8628 §3.4: トークンリクエストの grant_type 値。 */
export const DEVICE_CODE_GRANT_TYPE = 'urn:ietf:params:oauth:grant-type:device_code';

/**
 * RFC 8628 §6.1 が推奨する base-20 文字種。
 *
 * 視覚的に紛らわしい文字（母音・0/1/O/I 等）を除いてあり、ユーザーが別デバイスの
 * 画面から書き写す前提の user_code に適する。母音を含まないため、偶発的に意味の
 * ある単語が生成されることもない。
 */
export const USER_CODE_CHARSET = 'BCDFGHJKLMNPQRSTVWXZ';

/** RFC 8628 §6.1: 20^8 ≈ 2.6×10^10 のエントロピーを確保する文字数。 */
export const USER_CODE_LENGTH = 8;

/** 表示形式 `XXXX-XXXX` のハイフン位置（先頭からの文字数）。 */
export const USER_CODE_GROUP_SIZE = 4;

/** デバイス認可レコードの状態（RFC 8628 §3.5 の状態機械）。 */
export type DeviceAuthorizationStatus = 'pending' | 'approved' | 'denied';

/**
 * デバイス認可エンドポイントが発行したレコード。
 *
 * `deviceCode` は認可コード同等の機密として扱う（RFC 8628 §5.2）。ログ出力・
 * エラーメッセージへの混入は禁止する。
 */
export interface DeviceAuthorizationRecord {
  /** 256bit ランダム。デバイスがトークンエンドポイントへ提示する。 */
  deviceCode: string;
  /** 正規化済み照合キー（例 'WDJBMJHT'）。ストアの検索キーになる。 */
  userCode: string;
  /** 表示形式（例 'WDJB-MJHT'）。ユーザーへの提示と承認画面の再表示に使う。 */
  userCodeDisplay: string;
  /** device_code の発行先クライアント（RFC 8628 §3.4 の紐付け）。 */
  clientId: string;
  /** 要求 scope（offline_access ポリシー適用後）。 */
  scope: string[];
  status: DeviceAuthorizationStatus;
  createdAt: Date;
  expiresAt: Date;
  /** 現在の要求ポーリング間隔（秒）。slow_down のたびに +5 される（§3.5）。 */
  interval: number;
  lastPolledAt: Date | null;
  /** user_code 照合成功時に発行・回転する CSRF トークン。多層防御。 */
  csrfToken: string | null;
  /**
   * bindingSecret の SHA-256 ハッシュ。生値はブラウザの HttpOnly Cookie にのみ
   * 存在するため、ストアが漏洩しても Cookie を再構成できない。
   */
  bindingHash: string | null;
  /** デバイス用ログインの失敗回数（レコード単位）。 */
  loginAttempts: number;
  /** 承認時のみ設定される認証済み subject。 */
  subject?: string;
  /** 承認時のみ設定される認証時刻（epoch 秒）。 */
  authTime?: number;
  /** 承認時のみ設定される承認済み scope。 */
  approvedScope?: string[];
  /** 承認時のみ設定される grant 識別子（revocation の grant 単位失効に使う）。 */
  grantId?: string;
}

/**
 * 利用者が実装するストア契約。
 *
 * `deviceCode` / `userCode` はいずれも外部入力由来の不透明値として扱うこと。
 * 永続ストア実装ではキーをクエリ文字列へ連結せず、必ずパラメータ化した
 * 問い合わせを使う。
 */
export interface DeviceAuthorizationStore {
  save(record: DeviceAuthorizationRecord): Promise<void>;
  findByDeviceCode(deviceCode: string): Promise<DeviceAuthorizationRecord | null>;
  /** 正規化済みキー（{@link normalizeUserCode} の出力）で照合する。 */
  findByUserCode(userCode: string): Promise<DeviceAuthorizationRecord | null>;
  /**
   * レコードを更新する。
   *
   * `lastPolledAt` / `interval` の read-modify-write が atomic でない実装では、
   * 並行ポーリング時にポーリング間隔の強制が甘くなり得る。ただし認可状態の遷移
   * （pending → approved / denied）と {@link DeviceAuthorizationStore.consume}
   * による単回使用が守られていればセキュリティ特性は保たれる。
   */
  update(record: DeviceAuthorizationRecord): Promise<void>;
  delete(deviceCode: string): Promise<void>;
  /**
   * 取得と同時に削除する（トークン発行時の単回使用強制）。
   *
   * 取得と削除は atomic でなければならない。atomic でない実装は同一 device_code の
   * 並行リデンプションを許してしまう（PAR store の consume と同じ要件）。
   *
   * 期限切れレコードの掃除: 期限切れは原則トークンエンドポイントのポーリング時に
   * `expired_token` 応答とともに削除されるが、ポーリングを止めたデバイスのレコードは
   * 残る。ストア実装は `expiresAt` から十分な猶予（目安: TTL と同程度）を置いた後に
   * 期限切れレコードを自主的に破棄してよい。破棄後のポーリングは `expired_token`
   * ではなく `invalid_grant` になるが、クライアントはどちらのエラーでもフローを
   * 終了するため相互運用上の問題はない。
   */
  consume(deviceCode: string): Promise<DeviceAuthorizationRecord | null>;
}
```

### errors.ts (error types)

The errors split along response format.
`DeviceAuthorizationError` is the OAuth error for the back channel (the device authorization endpoint and the token endpoint); it carries the four §3.5-registered values (`authorization_pending` / `slow_down` / `access_denied` / `expired_token`) plus the RFC 6749 §5.2 classics, and always maps to a 400.
`DeviceVerificationError` is for the verification UI (HTML pages) and carries its HTTP status (401 / 403) directly.

```typescript
/**
 * OAuth 2.0 Device Authorization Grant — RFC 8628
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * エラー型。RFC 8628 §3.5 が RFC 6749 のエラーレジストリへ追加登録した 4 値と、
 * デバイス認可エンドポイントが使う RFC 6749 §5.2 の既存値のみを扱う。
 */
import { sanitizeErrorDescription } from '@maronn-openid-connect/core';

/**
 * デバイス認可グラントのエラーコード。
 *
 * - `authorization_pending` / `slow_down` / `access_denied` / `expired_token`:
 *   RFC 8628 §3.5 がトークンエンドポイント用に登録した値。
 * - `invalid_request` / `invalid_grant` / `invalid_scope` / `unauthorized_client`:
 *   RFC 6749 §5.2 の既存値。
 */
export type DeviceAuthorizationErrorCode =
  | 'authorization_pending'
  | 'slow_down'
  | 'access_denied'
  | 'expired_token'
  | 'invalid_request'
  | 'invalid_grant'
  | 'invalid_scope'
  | 'unauthorized_client';

/**
 * デバイス認可グラントのエラー。
 *
 * バックチャネル（デバイス認可エンドポイント / トークンエンドポイント）専用で、
 * リダイレクトは行わない。クライアント認証失敗は生成コード側の共有パイプラインが
 * core の `TokenError` として 401 を返すため、この型は常に 400 になる。
 *
 * `errorDescription` には device_code / user_code / CSRF トークン /
 * bindingSecret を含めてはならない（RFC 8628 §5.2）。
 */
export class DeviceAuthorizationError extends Error {
  readonly code: DeviceAuthorizationErrorCode;
  readonly errorDescription: string;

  constructor(code: DeviceAuthorizationErrorCode, errorDescription: string) {
    // RFC 6749 §5.2: error_description は安全な文字集合に限定する。
    const sanitized = sanitizeErrorDescription(errorDescription);
    super(sanitized);
    this.name = 'DeviceAuthorizationError';
    this.code = code;
    this.errorDescription = sanitized;
  }

  /** RFC 8628 §3.5 / RFC 6749 §5.2: このエラー群は常に 400 で返す。 */
  get statusCode(): 400 {
    return 400;
  }
}

/**
 * 検証 UI（`/device`, `/device/login`, `/device/approve`）で発生するエラー。
 *
 * トークンエンドポイントの OAuth エラーとは応答形式が異なる（HTML ページ）ため
 * 型を分ける。`statusCode` はそのまま HTTP ステータスとして使う。
 */
export class DeviceVerificationError extends Error {
  readonly statusCode: 401 | 403;

  constructor(message: string, statusCode: 401 | 403) {
    super(message);
    this.name = 'DeviceVerificationError';
    this.statusCode = statusCode;
  }
}
```

### user-code.ts (generation and normalization)

`generateUserCode` picks characters one at a time from a CSPRNG.
Since 20 does not divide 256, a naive modulo would bias character frequencies (modulo bias), weakening the 20^8 entropy claim, so bytes outside the modulo period are discarded and redrawn (rejection sampling).
The charset and length are deliberately not configurable: the entropy guarantee must not be breakable by a user's configuration mistake.

`normalizeUserCode` absorbs the input variance a human transcriber produces: lowercase is uppercased, and whitespace (including full-width spaces) and hyphens are stripped.
Charset validity is deliberately not checked here; a nonexistent code and a malformed code must be indistinguishable in the response.

`generateUniqueUserCode` redraws until the code collides with no pending record.
A collision left in place would make `findByUserCode` return some other record, handing one user's approval to a different device.
If the attempts cap is exhausted, it throws rather than swallowing the failure (generated code turns that into a 500).

```typescript
/**
 * OAuth 2.0 Device Authorization Grant — RFC 8628 §6.1
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * user_code の生成と正規化。
 */
import {
  USER_CODE_CHARSET,
  USER_CODE_GROUP_SIZE,
  USER_CODE_LENGTH,
  type DeviceAuthorizationStore,
} from './store.js';

/**
 * user_code を 1 つ生成する（表示形式 `XXXX-XXXX`）。
 *
 * RFC 8628 §6.1 推奨の base-20 文字種から {@link USER_CODE_LENGTH} 文字を
 * CSPRNG で選ぶ。20 は 256 の約数ではないため、単純な剰余では文字ごとの出現確率が
 * 偏る（modulo bias）。偏りは 20^8 のエントロピー主張を弱めるので、剰余の周期に
 * 収まらないバイトは破棄して引き直す（rejection sampling）。
 *
 * 文字種と長さは設定値にしていない。エントロピー保証を利用者の設定ミスで壊さない
 * ためで、変更したい場合は定数を fork する想定（昇格時に設定化を再検討）。
 */
export function generateUserCode(): string {
  const charset = USER_CODE_CHARSET;
  // 256 を charset.length で割った剰余の周期に収まらない値の下限。
  const limit = 256 - (256 % charset.length);
  let code = '';
  const buffer = new Uint8Array(1);
  while (code.length < USER_CODE_LENGTH) {
    crypto.getRandomValues(buffer);
    const byte = buffer[0] as number;
    if (byte >= limit) continue;
    code += charset[byte % charset.length];
  }
  return formatUserCode(code);
}

/**
 * 正規化済みの user_code を表示形式（`XXXX-XXXX`）へ整形する。
 *
 * RFC 8628 §6.1: 書き写しやすさのため区切り文字を入れてよい。区切りは照合前に
 * {@link normalizeUserCode} が除去する。
 */
export function formatUserCode(normalized: string): string {
  const groups: string[] = [];
  for (let i = 0; i < normalized.length; i += USER_CODE_GROUP_SIZE) {
    groups.push(normalized.slice(i, i + USER_CODE_GROUP_SIZE));
  }
  return groups.join('-');
}

/**
 * ユーザー入力の user_code を照合キーへ正規化する。
 *
 * RFC 8628 §6.1: 大文字小文字の別・区切り文字の有無をユーザーに強制しない。
 * 小文字を大文字化し、空白（全角スペースを含む）とハイフン類を除去する。
 * 文字種の妥当性検証はここでは行わない（照合が失敗すれば同一文言のエラーになる。
 * 実在しないコードと不正な形式のコードを区別しないための設計）。
 */
export function normalizeUserCode(input: string): string {
  return input
    .toUpperCase()
    .replace(/[\s　-]/g, '');
}

/**
 * 既存の pending レコードと衝突しない user_code を生成する。
 *
 * 衝突したまま保存すると `findByUserCode` が別レコードを返し、あるユーザーの承認が
 * 別デバイスへ渡り得る。衝突確率は 1/20^8 程度なので、上限回数まで引き直せば実際上
 * 必ず成功する。上限に達した場合は握りつぶさず throw し、生成コード側で 500 にする。
 *
 * @throws {Error} 規定回数連続で衝突した場合
 */
export async function generateUniqueUserCode(
  store: DeviceAuthorizationStore,
  maxAttempts = 5,
): Promise<{ userCode: string; userCodeDisplay: string }> {
  for (let attempt = 0; attempt < maxAttempts; attempt++) {
    const userCodeDisplay = generateUserCode();
    const userCode = normalizeUserCode(userCodeDisplay);
    const existing = await store.findByUserCode(userCode);
    if (existing === null) {
      return { userCode, userCodeDisplay };
    }
  }
  // 生成された値そのものはログにも例外にも残さない（RFC 8628 §5.1）。
  throw new Error(
    `Failed to generate a unique user_code after ${maxAttempts} attempts`,
  );
}
```

### device-authorization-request.ts (the device authorization endpoint)

Five step functions, composed in spec order by `processDeviceAuthorizationRequest`:

1. `validateDeviceGrantAllowed`: a client whose registered `grantTypes` lacks the device grant URN gets `unauthorized_client`
2. `validateDeviceAuthorizationScope`: enforces the scope-required and `openid`-required profile, normalizing whitespace and duplicates under the same rules as core's authorization endpoint
3. `applyOfflineAccessPolicy`: silently removes `offline_access` when its conditions are unmet (the OIDC Core §11 "ignore" semantics rather than an error). The conditions are that the refresh-token feature is enabled and the client registered the `refresh_token` grant; no `prompt=consent`-style precondition applies, because the verification UI's approval screen is explicit consent itself
4. `createDeviceAuthorizationRecord`: generates the 256-bit device_code and a collision-free user_code and stores the record
5. `buildDeviceAuthorizationResponse`: assembles the §3.2 response (`verification_uri` is `<issuer>/device`, and `verification_uri_complete` carries the user_code as a query parameter)

`verification_uri_complete` is OPTIONAL but always returned.
The user_code rides a URL there, so it can linger in browser history and proxy logs; the recorded judgment is that a one-time, short-lived code is worthless to anyone but the person doing the approval.

Client authentication is deliberately absent from this module.
It happens in the generated code's shared pipeline (the four core functions from `extractClientCredentials` on), which then hands the authenticated client in.

```typescript
/**
 * OAuth 2.0 Device Authorization Grant — RFC 8628 §3.1 / §3.2
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * デバイス認可エンドポイント（`POST /device_authorization`）の処理。core と同じく
 * 「合成関数＋ステップ関数」の二層構成とし、CLI 生成コードはステップ関数を順に
 * 呼び出して処理を組み立てられるようにする。
 *
 * クライアント認証は生成コード側の共有パイプライン（extractClientCredentials →
 * resolveAuthenticatedTokenClient → validateClientAuthMethod → verifyClientSecret）
 * で済ませてから、認証済みクライアントをここへ渡す。
 */
import { generateRandomString } from '@maronn-openid-connect/core';
import { DeviceAuthorizationError } from './errors.js';
import { generateUniqueUserCode } from './user-code.js';
import {
  DEVICE_CODE_GRANT_TYPE,
  type DeviceAuthorizationRecord,
  type DeviceAuthorizationStore,
} from './store.js';

/** RFC 8628 §5.2: device_code は認可コード同等のエントロピー（256bit）で生成する。 */
const DEVICE_CODE_BYTE_LENGTH = 32;

/** RFC 8628 §3.2 の既定値。生成コードの config から上書きできる。 */
export const DEFAULT_DEVICE_CODE_EXPIRES_IN = 600;
/** RFC 8628 §3.2: interval を省略した場合クライアントは 5 秒を使う MUST。 */
export const DEFAULT_POLL_INTERVAL = 5;

/** デバイス認可エンドポイントに渡す最小限のクライアント情報。 */
export interface DeviceAuthorizationClient {
  clientId: string;
  /** 登録済み grant_types。URN 未登録は unauthorized_client。 */
  grantTypes?: string[];
}

/** RFC 8628 §3.2 の成功レスポンス（JSON のフィールド名そのまま）。 */
export interface DeviceAuthorizationResponse {
  device_code: string;
  user_code: string;
  verification_uri: string;
  verification_uri_complete: string;
  expires_in: number;
  interval: number;
}

/**
 * ステップ 1: クライアントがデバイス認可グラントを許可されているか検証する。
 *
 * RFC 6749 §5.2: 登録済み grant_types に含まれないグラントは unauthorized_client。
 *
 * @throws {DeviceAuthorizationError} unauthorized_client
 */
export function validateDeviceGrantAllowed(client: DeviceAuthorizationClient): void {
  const grantTypes = client.grantTypes ?? [];
  if (!grantTypes.includes(DEVICE_CODE_GRANT_TYPE)) {
    throw new DeviceAuthorizationError(
      'unauthorized_client',
      'The client is not authorized to use the device_code grant',
    );
  }
}

/**
 * ステップ 2: scope を検証して正規化する。
 *
 * RFC 8628 §3.1 では scope は OPTIONAL だが、本 OP は認可エンドポイントと同じ
 * プロファイル制限（scope 必須・`openid` 必須）をデバイス認可にも課す。RFC 8628 が
 * 許容する scope 省略には対応しない、既知の制限である。
 *
 * 空白区切り・重複除去の扱いは core の `validateAuthorizationScope` と同じ規則。
 *
 * @throws {DeviceAuthorizationError} invalid_request / invalid_scope
 */
export function validateDeviceAuthorizationScope(scope: string | undefined): string[] {
  if (scope === undefined || scope.trim() === '') {
    throw new DeviceAuthorizationError(
      'invalid_request',
      'Missing required parameter: scope',
    );
  }
  const values = [...new Set(scope.trim().split(/\s+/).filter((value) => value.length > 0))];
  if (!values.includes('openid')) {
    throw new DeviceAuthorizationError(
      'invalid_scope',
      'The openid scope is required',
    );
  }
  return values;
}

/**
 * ステップ 3: 許可条件を満たさない `offline_access` を scope から除去する。
 *
 * OIDC Core 1.0 §11: 許可条件を満たさない offline_access は無視する（エラーには
 * しない）。デバイスフローでは検証 UI の承認画面が明示同意そのものなので、許可条件は
 * 「refresh-token feature が有効」かつ「クライアントが refresh_token grant を登録
 * 済み」の 2 点とし、`prompt=consent` 相当の事前条件は課さない。
 */
export function applyOfflineAccessPolicy(
  scope: string[],
  options: { client: DeviceAuthorizationClient; refreshTokenFeatureEnabled: boolean },
): string[] {
  const clientAllowsRefresh = (options.client.grantTypes ?? []).includes('refresh_token');
  if (options.refreshTokenFeatureEnabled && clientAllowsRefresh) {
    return scope;
  }
  return scope.filter((value) => value !== 'offline_access');
}

/**
 * ステップ 4: device_code / user_code を生成してレコードを保存する。
 *
 * @throws {Error} user_code が規定回数連続で衝突した場合（生成コードは 500 にする）
 */
export async function createDeviceAuthorizationRecord(options: {
  clientId: string;
  scope: string[];
  store: DeviceAuthorizationStore;
  expiresIn: number;
  interval: number;
  now?: Date;
}): Promise<DeviceAuthorizationRecord> {
  const { userCode, userCodeDisplay } = await generateUniqueUserCode(options.store);
  const createdAt = options.now ?? new Date();
  const record: DeviceAuthorizationRecord = {
    deviceCode: generateRandomString(DEVICE_CODE_BYTE_LENGTH),
    userCode,
    userCodeDisplay,
    clientId: options.clientId,
    scope: options.scope,
    status: 'pending',
    createdAt,
    expiresAt: new Date(createdAt.getTime() + options.expiresIn * 1000),
    interval: options.interval,
    lastPolledAt: null,
    csrfToken: null,
    bindingHash: null,
    loginAttempts: 0,
  };
  await options.store.save(record);
  return record;
}

/**
 * ステップ 5: RFC 8628 §3.2 のレスポンスボディを組み立てる。
 *
 * `verification_uri_complete` は OPTIONAL だが常に返す。user_code がクエリに載るため
 * ユーザー側ブラウザの履歴や中間プロキシのログに残り得るが、user_code はワンタイム
 * かつ短命で、承認操作をした本人以外には価値を持たない。
 */
export function buildDeviceAuthorizationResponse(
  record: DeviceAuthorizationRecord,
  issuer: string,
): DeviceAuthorizationResponse {
  const verificationUri = `${issuer}/device`;
  return {
    device_code: record.deviceCode,
    user_code: record.userCodeDisplay,
    verification_uri: verificationUri,
    verification_uri_complete: `${verificationUri}?user_code=${encodeURIComponent(record.userCodeDisplay)}`,
    expires_in: Math.round((record.expiresAt.getTime() - record.createdAt.getTime()) / 1000),
    interval: record.interval,
  };
}

/**
 * 合成関数: デバイス認可エンドポイントの全処理（RFC 8628 §3.1 / §3.2）。
 *
 * 個々のステップ関数を仕様順に合成しただけの API。生成コードは通常この関数ではなく
 * ステップ関数を順に呼び出し、検証の差し替え・削除ができるようにする。
 *
 * @throws {DeviceAuthorizationError}
 */
export async function processDeviceAuthorizationRequest(input: {
  params: Record<string, string>;
  client: DeviceAuthorizationClient;
  issuer: string;
  expiresIn?: number;
  interval?: number;
  refreshTokenFeatureEnabled: boolean;
  store: DeviceAuthorizationStore;
  now?: Date;
}): Promise<DeviceAuthorizationResponse> {
  validateDeviceGrantAllowed(input.client);

  const requestedScope = validateDeviceAuthorizationScope(input.params['scope']);
  const scope = applyOfflineAccessPolicy(requestedScope, {
    client: input.client,
    refreshTokenFeatureEnabled: input.refreshTokenFeatureEnabled,
  });

  const record = await createDeviceAuthorizationRecord({
    clientId: input.client.clientId,
    scope,
    store: input.store,
    expiresIn: input.expiresIn ?? DEFAULT_DEVICE_CODE_EXPIRES_IN,
    interval: input.interval ?? DEFAULT_POLL_INTERVAL,
    now: input.now,
  });

  return buildDeviceAuthorizationResponse(record, input.issuer);
}
```

### verification.ts (the verification UI's step functions)

These are the functions behind the three verification routes (`GET/POST /device`, `POST /device/login`, `POST /device/approve`).

`findPendingRecordByUserCode` normalizes and matches the user_code and returns only an approvable pending record.
Unknown, expired, and non-pending all come back as `null`, and the caller re-renders the form with one message for all of them.

`issueVerificationBinding` issues and rotates the bindingSecret / CSRF token pair on a successful match.
If another browser matches the same user_code later, the earlier browser's binding is invalidated (last-writer-wins); someone who knows the user_code can steer the record's approval or denial in RFC 8628's model anyway, so this is accepted as a constraint rather than treated as a feature.

`validateVerificationBinding` hashes the cookie's raw value and compares against the record.
Timing differences in that comparison cannot be stacked into recovering the stored value, because turning a prefix into the secret requires a preimage computation.
`validateVerificationCsrfToken` checks the hidden-field token as defense in depth on top of the binding.

`recordDeviceLoginFailure` counts failed device logins per record and flips the record to `denied` at the cap, ending the flow for that code (the device sees `access_denied` on its next poll).
An attacker with a device-grant-enabled client can mint records without limit, so the aggregate guess budget stays unbounded; that residual surface is identical to the existing `/login` route, and subject-scoped throttling is assigned to a separate task.

`approveDeviceAuthorization` / `denyDeviceAuthorization` are one-way transitions.
Approval fixes `subject` / `authTime` / `approvedScope` / `grantId` and clears the now-useless binding and CSRF values from the record.
The freshly issued `grantId` is what lets the existing revocation machinery apply grant-level revocation to device-issued tokens unchanged.

```typescript
/**
 * OAuth 2.0 Device Authorization Grant — RFC 8628 §3.3
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * 検証 UI（`GET/POST /device`, `POST /device/login`, `POST /device/approve`）が
 * 呼ぶステップ関数群。
 *
 * ## ブラウザバインディングが CSRF 防御の主役である理由
 *
 * device フローの user_code は「フローを開始した主体」が設計上必ず知っている識別子で
 * あり、その主体こそが攻撃者になり得る。したがってレコードに紐づけただけの CSRF
 * トークンは、攻撃者自身が `POST /device` を叩いて取得できてしまい防御にならない。
 *
 * そこで user_code の照合成功時に bindingSecret を発行し、生値はブラウザだけが持つ
 * HttpOnly Cookie に、SHA-256 ハッシュのみをレコードへ保存する。`/device/login` と
 * `/device/approve` は Cookie の生値がレコードの bindingHash と一致しない限り実行
 * されない。フォージされたクロスサイト POST は被害者ブラウザの Cookie を運べない
 * （SameSite=Lax）うえ、そもそも被害者ブラウザは当該レコードの Cookie を保持して
 * いないため、トークン秘匿に依存せず遮断できる。
 *
 * authorize フローの transaction-binding が opt-in なのに対し、こちらは常時有効で
 * ある。transaction_id は通常秘匿されるためバインディングは追加ハードニングで足りるが、
 * user_code は開始者に既知であることが前提のため、これがベースライン要件になる。
 */
import { generateRandomString } from '@maronn-openid-connect/core';
import { DeviceAuthorizationError, DeviceVerificationError } from './errors.js';
import { normalizeUserCode } from './user-code.js';
import type {
  DeviceAuthorizationRecord,
  DeviceAuthorizationStore,
} from './store.js';

/** bindingSecret / csrfToken のエントロピー（256bit）。 */
const VERIFICATION_SECRET_BYTE_LENGTH = 32;

/**
 * user_code 照合の失敗理由を利用者へ区別させないための単一文言。
 *
 * 未知・期限切れ・使用済み（非 pending）を同じ文言で返すことで、有効な user_code の
 * 実在性を推測材料として渡さない（RFC 8628 §5.1）。
 */
export const INVALID_USER_CODE_MESSAGE = 'The code is invalid or has expired';

/**
 * SHA-256 ハッシュを Base64URL で返す。
 *
 * bindingSecret の生値はブラウザの Cookie にのみ存在し、レコードにはこのハッシュ
 * だけを保存する。ストアが漏洩しても Cookie を再構成できない。
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
 * user_code を正規化して照合し、承認可能な pending レコードだけを返す。
 *
 * 未知・期限切れ・非 pending はすべて null。呼び出し側は理由を区別せず
 * {@link INVALID_USER_CODE_MESSAGE} でフォームを再表示する。
 *
 * 照合のタイミング差（ストア検索由来）は user_code の実在性をわずかに漏らし得るが、
 * 主防御はエントロピー（20^8）と短い TTL であり、実在を知っても承認操作には至れない。
 */
export async function findPendingRecordByUserCode(
  userCode: string,
  store: DeviceAuthorizationStore,
  now: Date = new Date(),
): Promise<DeviceAuthorizationRecord | null> {
  const normalized = normalizeUserCode(userCode);
  if (normalized === '') return null;
  const record = await store.findByUserCode(normalized);
  if (record === null) return null;
  if (record.status !== 'pending') return null;
  if (now.getTime() >= record.expiresAt.getTime()) return null;
  return record;
}

/**
 * `POST /device` の照合成功時に、ブラウザバインディングと CSRF トークンを
 * ペアで発行・回転する。
 *
 * bindingSecret の生値は戻り値としてのみ返し（生成コードが Cookie に載せる）、
 * レコードへは SHA-256 ハッシュだけを保存する。
 *
 * 別ブラウザが同じ user_code で `POST /device` すると先のブラウザのバインディングは
 * 無効になる（last-writer-wins）。user_code を知る者はレコードの承認 / 拒否を
 * 左右できるという RFC 8628 のモデルを変えるものではないため、機能ではなく制約と
 * して受け入れる。
 */
export async function issueVerificationBinding(
  record: DeviceAuthorizationRecord,
  store: DeviceAuthorizationStore,
): Promise<{ bindingSecret: string; csrfToken: string }> {
  const bindingSecret = generateRandomString(VERIFICATION_SECRET_BYTE_LENGTH);
  const csrfToken = generateRandomString(VERIFICATION_SECRET_BYTE_LENGTH);
  record.bindingHash = await sha256Base64Url(bindingSecret);
  record.csrfToken = csrfToken;
  await store.update(record);
  return { bindingSecret, csrfToken };
}

/**
 * Cookie から取り出した bindingSecret がこのレコードのものかを検証する。
 *
 * 照合は「入力の SHA-256 ハッシュ vs 保存ハッシュ」の比較なので、比較のタイミング差
 * から保存値の前方一致を積み上げても原像計算が必要になり成立しない。
 *
 * バインディング未発行（`bindingHash === null`）のレコードは、まだ `POST /device` を
 * 通っていないということなので拒否する（transaction-binding の後方互換スキップとは
 * 異なり、ここでは常時必須）。
 *
 * @throws {DeviceVerificationError} 403
 */
export async function validateVerificationBinding(
  record: DeviceAuthorizationRecord,
  bindingSecret: string | null | undefined,
): Promise<void> {
  if (record.bindingHash === null || !bindingSecret) {
    throw new DeviceVerificationError('Device verification binding is missing', 403);
  }
  const presented = await sha256Base64Url(bindingSecret);
  if (presented !== record.bindingHash) {
    throw new DeviceVerificationError('Device verification binding is invalid', 403);
  }
}

/**
 * hidden フィールドの csrf_token を照合する（多層防御）。
 *
 * 主防御は {@link validateVerificationBinding} なので、常に binding を先に検証して
 * から呼ぶこと。比較方法は既存 login / consent の `validateCsrfToken` と
 * 同じ水準に揃えてある。定数時間比較への変更時は本機能にも同じ方針を適用する。
 *
 * @throws {DeviceVerificationError} 403
 */
export function validateVerificationCsrfToken(
  record: DeviceAuthorizationRecord,
  csrfToken: string,
): void {
  if (record.csrfToken === null || csrfToken === '' || csrfToken !== record.csrfToken) {
    throw new DeviceVerificationError('CSRF token mismatch', 403);
  }
}

/**
 * デバイス用ログインの失敗をレコード単位で計数する。
 *
 * 上限を超えたレコードは `denied` へ遷移させ、そのコードでのフローを終わらせる
 * （デバイス側は次のポーリングで `access_denied` を受け取る）。
 *
 * 既知の残存面: device グラントを許可されたクライアントを持つ攻撃者はレコードを
 * 無制限に発行できるため、集計上のパスワード試行回数は無制限になる。これは既存
 * `/login` ルート（auth transaction を無制限に開始できる）と同一の残存面である。
 * subject 単位のスロットリングは別機能の責務とする。
 */
export async function recordDeviceLoginFailure(
  record: DeviceAuthorizationRecord,
  store: DeviceAuthorizationStore,
  maxLoginAttempts: number,
): Promise<{ canRetry: boolean; remainingAttempts: number }> {
  record.loginAttempts += 1;
  const canRetry = record.loginAttempts < maxLoginAttempts;
  if (!canRetry) {
    record.status = 'denied';
  }
  await store.update(record);
  return {
    canRetry,
    remainingAttempts: Math.max(0, maxLoginAttempts - record.loginAttempts),
  };
}

/**
 * 承認（`POST /device/approve` の `decision=approve`）。
 *
 * バインディング検証は呼び出し側が先に済ませておくこと（生成コードは Cookie を
 * 読む責務を持つため、この関数はレコードと CSRF トークンだけを見る）。
 *
 * `approvedScope` は要求 scope をそのまま採用する（本 OP の検証 UI は scope の
 * 部分承認を提供しない）。`grantId` を新規発行し、既存の revocation 機構が
 * grant 単位失効をそのまま適用できるようにする。
 *
 * @throws {DeviceVerificationError} CSRF 不一致 (403)
 * @throws {DeviceAuthorizationError} レコードが pending でない (invalid_grant)
 */
export async function approveDeviceAuthorization(input: {
  record: DeviceAuthorizationRecord;
  store: DeviceAuthorizationStore;
  csrfToken: string;
  subject: string;
  authTime: number;
}): Promise<DeviceAuthorizationRecord> {
  validateVerificationCsrfToken(input.record, input.csrfToken);
  assertPending(input.record);

  input.record.status = 'approved';
  input.record.subject = input.subject;
  input.record.authTime = input.authTime;
  input.record.approvedScope = [...input.record.scope];
  input.record.grantId = generateRandomString(VERIFICATION_SECRET_BYTE_LENGTH);
  // 承認後はバインディングも CSRF トークンも用済み。承認 / 拒否は一方向遷移なので、
  // 残しておく理由がない値をレコードから落とす。
  input.record.bindingHash = null;
  input.record.csrfToken = null;
  await input.store.update(input.record);
  return input.record;
}

/**
 * 拒否（`POST /device/approve` の `decision=deny`）。
 *
 * @throws {DeviceVerificationError} CSRF 不一致 (403)
 * @throws {DeviceAuthorizationError} レコードが pending でない (invalid_grant)
 */
export async function denyDeviceAuthorization(input: {
  record: DeviceAuthorizationRecord;
  store: DeviceAuthorizationStore;
  csrfToken: string;
}): Promise<DeviceAuthorizationRecord> {
  validateVerificationCsrfToken(input.record, input.csrfToken);
  assertPending(input.record);

  input.record.status = 'denied';
  input.record.bindingHash = null;
  input.record.csrfToken = null;
  await input.store.update(input.record);
  return input.record;
}

/**
 * 承認 / 拒否は一方向遷移とする。`approved` / `denied` になったレコードは
 * 検証 UI から再度操作できない。
 */
function assertPending(record: DeviceAuthorizationRecord): void {
  if (record.status !== 'pending') {
    throw new DeviceAuthorizationError(
      'invalid_grant',
      INVALID_USER_CODE_MESSAGE,
    );
  }
}
```

### device-code-grant.ts (the token endpoint's state machine)

This rides the token endpoint's grant branch; `evaluateDeviceCodeState` evaluates the RFC 8628 §3.5 state machine top down:

1. expiry → `expired_token` (record deleted). Expiry is checked before poll speed because raising the interval of an expired record is pointless; the device should be told the flow is over
2. polling too fast → `slow_down`. The §3.5 MUST ("increase the interval by 5 seconds") is enforced server-side by adding 5 to the record's interval and saving it
3. pending → `authorization_pending` (with `lastPolledAt` updated)
4. denied → `access_denied` (record deleted)
5. approved → return the result. Single use is enforced through the atomic `consume`; under concurrent redemption exactly one poll wins and the rest get `invalid_grant`

`resolveDeviceCodeRecord` enforces the client binding of §3.4 and collapses "no such record" and "another client's record" into one `invalid_grant` message.

```typescript
/**
 * OAuth 2.0 Device Authorization Grant — RFC 8628 §3.4 / §3.5
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * トークンエンドポイントの grant 分岐に載る状態機械。生成コードは core の
 * `validateGrantTypeSupported` より前でこれを呼び、分岐内で応答を返し切る。
 */
import { DeviceAuthorizationError } from './errors.js';
import {
  DEVICE_CODE_GRANT_TYPE,
  type DeviceAuthorizationRecord,
  type DeviceAuthorizationStore,
} from './store.js';

/** RFC 8628 §3.5: slow_down のたびにサーバー側も interval を +5 秒する。 */
export const SLOW_DOWN_INTERVAL_INCREMENT = 5;

/**
 * device_code の実在性を漏らさないための単一文言。
 *
 * 「レコードが無い」「他クライアントの device_code」を同じ文言にすることで、
 * 攻撃者が他クライアントのコードの実在を確かめられないようにする。
 */
const INVALID_DEVICE_CODE_MESSAGE =
  'The device_code is invalid, expired, or was issued to another client';

/** トークン分岐に渡す最小限のクライアント情報。 */
export interface DeviceCodeGrantClient {
  clientId: string;
  grantTypes?: string[];
}

/** 承認済みレコードから確定した、トークン発行に必要な情報。 */
export interface DeviceCodeGrantResult {
  subject: string;
  clientId: string;
  scope: string[];
  authTime: number;
  grantId: string;
}

/**
 * ステップ 1: クライアントがデバイス認可グラントを許可されているか検証する。
 *
 * @throws {DeviceAuthorizationError} unauthorized_client
 */
export function validateDeviceCodeGrantAllowed(client: DeviceCodeGrantClient): void {
  if (!(client.grantTypes ?? []).includes(DEVICE_CODE_GRANT_TYPE)) {
    throw new DeviceAuthorizationError(
      'unauthorized_client',
      'The client is not authorized to use the device_code grant',
    );
  }
}

/**
 * ステップ 2: `device_code` パラメータを取り出し、発行先クライアントのレコードを解決する。
 *
 * RFC 8628 §3.4: device_code は発行先クライアントに紐づく。存在しない場合も
 * クライアント不一致の場合も同一文言の `invalid_grant` にする。
 *
 * @throws {DeviceAuthorizationError} invalid_request / invalid_grant
 */
export async function resolveDeviceCodeRecord(
  params: Record<string, string>,
  client: DeviceCodeGrantClient,
  store: DeviceAuthorizationStore,
): Promise<DeviceAuthorizationRecord> {
  const deviceCode = params['device_code'];
  if (deviceCode === undefined || deviceCode === '') {
    throw new DeviceAuthorizationError(
      'invalid_request',
      'Missing required parameter: device_code',
    );
  }
  const record = await store.findByDeviceCode(deviceCode);
  if (record === null || record.clientId !== client.clientId) {
    throw new DeviceAuthorizationError('invalid_grant', INVALID_DEVICE_CODE_MESSAGE);
  }
  return record;
}

/**
 * ステップ 3: RFC 8628 §3.5 の状態機械を評価する。
 *
 * 判定順序（上から評価し、最初に該当したものを返す）:
 *
 * 1. 期限切れ → `expired_token`（レコード削除）
 * 2. ポーリング過速 → `slow_down`（interval を +5 して保存）
 * 3. pending → `authorization_pending`（lastPolledAt 更新）
 * 4. denied → `access_denied`（レコード削除）
 * 5. approved → 結果を返す（レコードは consume で単回使用にする）
 *
 * 期限切れをポーリング過速より先に評価するのは、期限切れレコードに対して interval を
 * 増やしても意味がなく、デバイスへはフロー終了を伝えるべきだから。
 *
 * @throws {DeviceAuthorizationError} §3.5 の各状態
 */
export async function evaluateDeviceCodeState(
  record: DeviceAuthorizationRecord,
  store: DeviceAuthorizationStore,
  now: Date = new Date(),
): Promise<DeviceCodeGrantResult> {
  if (now.getTime() >= record.expiresAt.getTime()) {
    await store.delete(record.deviceCode);
    throw new DeviceAuthorizationError(
      'expired_token',
      'The device_code has expired. Start a new device authorization request.',
    );
  }

  if (
    record.lastPolledAt !== null &&
    now.getTime() - record.lastPolledAt.getTime() < record.interval * 1000
  ) {
    // RFC 8628 §3.5: "the interval MUST be increased by 5 seconds for this and
    // all subsequent requests" — サーバー側も新しい間隔を強制する。
    record.interval += SLOW_DOWN_INTERVAL_INCREMENT;
    record.lastPolledAt = now;
    await store.update(record);
    throw new DeviceAuthorizationError(
      'slow_down',
      'Polling too frequently. Increase the interval by 5 seconds.',
    );
  }

  if (record.status === 'pending') {
    record.lastPolledAt = now;
    await store.update(record);
    throw new DeviceAuthorizationError(
      'authorization_pending',
      'The authorization request is still pending',
    );
  }

  if (record.status === 'denied') {
    await store.delete(record.deviceCode);
    throw new DeviceAuthorizationError(
      'access_denied',
      'The end-user denied the authorization request',
    );
  }

  // approved: 単回使用を強制するため atomic な consume で回収する。並行リデンプション
  // では先勝ちの 1 本だけがトークンを得て、後続は record が null になり invalid_grant。
  const consumed = await store.consume(record.deviceCode);
  if (
    consumed === null ||
    consumed.status !== 'approved' ||
    consumed.subject === undefined ||
    consumed.authTime === undefined ||
    consumed.grantId === undefined
  ) {
    throw new DeviceAuthorizationError('invalid_grant', INVALID_DEVICE_CODE_MESSAGE);
  }

  return {
    subject: consumed.subject,
    clientId: consumed.clientId,
    scope: consumed.approvedScope ?? consumed.scope,
    authTime: consumed.authTime,
    grantId: consumed.grantId,
  };
}

/**
 * 合成関数: トークンエンドポイントのデバイスコード分岐（RFC 8628 §3.4 / §3.5）。
 *
 * 承認済みのときだけ {@link DeviceCodeGrantResult} を返し、それ以外の状態は
 * {@link DeviceAuthorizationError} を throw する。
 *
 * @throws {DeviceAuthorizationError}
 */
export async function processDeviceCodeGrant(input: {
  params: Record<string, string>;
  client: DeviceCodeGrantClient;
  store: DeviceAuthorizationStore;
  now?: Date;
}): Promise<DeviceCodeGrantResult> {
  validateDeviceCodeGrantAllowed(input.client);
  const record = await resolveDeviceCodeRecord(input.params, input.client, input.store);
  return evaluateDeviceCodeState(record, input.store, input.now);
}
```

### index.ts (public API)

The substance of the subpath export `@maronn-openid-connect/experimental/device-authorization-grant`.

```typescript
/**
 * EXPERIMENTAL — OAuth 2.0 Device Authorization Grant (RFC 8628).
 *
 * ブラウザを持たない・文字入力が困難なデバイス（スマート TV / CLI ツール / IoT 機器）
 * が、別デバイスのブラウザでユーザーに認可してもらい、自分はトークンエンドポイントを
 * ポーリングしてトークンを受け取るためのグラント。
 *
 * この package の API は安定していない。破壊的変更があり得るため、production で
 * 使う場合はバージョンを固定すること。
 */
export {
  DEVICE_CODE_GRANT_TYPE,
  USER_CODE_CHARSET,
  USER_CODE_GROUP_SIZE,
  USER_CODE_LENGTH,
} from './store.js';
export type {
  DeviceAuthorizationRecord,
  DeviceAuthorizationStatus,
  DeviceAuthorizationStore,
} from './store.js';

export { DeviceAuthorizationError, DeviceVerificationError } from './errors.js';
export type { DeviceAuthorizationErrorCode } from './errors.js';

export {
  formatUserCode,
  generateUniqueUserCode,
  generateUserCode,
  normalizeUserCode,
} from './user-code.js';

export {
  DEFAULT_DEVICE_CODE_EXPIRES_IN,
  DEFAULT_POLL_INTERVAL,
  applyOfflineAccessPolicy,
  buildDeviceAuthorizationResponse,
  createDeviceAuthorizationRecord,
  processDeviceAuthorizationRequest,
  validateDeviceAuthorizationScope,
  validateDeviceGrantAllowed,
} from './device-authorization-request.js';
export type {
  DeviceAuthorizationClient,
  DeviceAuthorizationResponse,
} from './device-authorization-request.js';

export {
  INVALID_USER_CODE_MESSAGE,
  approveDeviceAuthorization,
  denyDeviceAuthorization,
  findPendingRecordByUserCode,
  issueVerificationBinding,
  recordDeviceLoginFailure,
  validateVerificationBinding,
  validateVerificationCsrfToken,
} from './verification.js';

export {
  SLOW_DOWN_INTERVAL_INCREMENT,
  evaluateDeviceCodeState,
  processDeviceCodeGrant,
  resolveDeviceCodeRecord,
  validateDeviceCodeGrantAllowed,
} from './device-code-grant.js';
export type {
  DeviceCodeGrantClient,
  DeviceCodeGrantResult,
} from './device-code-grant.js';
```

### test-helpers.ts (test fixtures)

Four test files need the same store implementation and record factory, so they are shared inside the feature.
The tsconfig exclude keeps them out of the published `dist`.

```typescript
/**
 * テスト専用のフィクスチャ。tsconfig の exclude で dist から除外している。
 *
 * 4 つのテストファイルが同じストア実装とレコード工場を必要とするため、機能内で
 * 共有する（experimental 機能を跨いだ共通化はしない）。
 */
import type {
  DeviceAuthorizationRecord,
  DeviceAuthorizationStore,
} from './store.js';

/** テスト内で時刻を固定するための基準時刻。 */
export const NOW = new Date('2026-08-07T00:00:00.000Z');

/** 既定値つきのレコード工場。上書きしたいフィールドだけ渡す。 */
export function makeRecord(
  overrides: Partial<DeviceAuthorizationRecord> = {},
): DeviceAuthorizationRecord {
  return {
    deviceCode: 'device-code-value',
    userCode: 'WDJBMJHT',
    userCodeDisplay: 'WDJB-MJHT',
    clientId: 'device-client',
    scope: ['openid'],
    status: 'pending',
    createdAt: NOW,
    expiresAt: new Date(NOW.getTime() + 600_000),
    interval: 5,
    lastPolledAt: null,
    csrfToken: null,
    bindingHash: null,
    loginAttempts: 0,
    ...overrides,
  };
}

/** テスト用のインメモリ実装。契約どおり consume は取得と削除を同時に行う。 */
export function createInMemoryDeviceAuthorizationStore(): DeviceAuthorizationStore & {
  records: Map<string, DeviceAuthorizationRecord>;
} {
  const records = new Map<string, DeviceAuthorizationRecord>();
  return {
    records,
    async save(record) {
      records.set(record.deviceCode, record);
    },
    async findByDeviceCode(deviceCode) {
      return records.get(deviceCode) ?? null;
    },
    async findByUserCode(userCode) {
      for (const record of records.values()) {
        if (record.userCode === userCode) return record;
      }
      return null;
    },
    async update(record) {
      records.set(record.deviceCode, record);
    },
    async delete(deviceCode) {
      records.delete(deviceCode);
    },
    async consume(deviceCode) {
      const record = records.get(deviceCode) ?? null;
      records.delete(deviceCode);
      return record;
    },
  };
}
```

## The unit tests, in full

`user-code.test.ts` pins down generation and normalization: the charset and length, the display format, normalization variance (lowercase, spaces, full-width spaces, hyphens), redraws on collision with a throw at the cap, and generated values never leaking into exception messages.

```typescript
import { describe, expect, it } from 'vitest';
import {
  formatUserCode,
  generateUniqueUserCode,
  generateUserCode,
  normalizeUserCode,
} from './user-code.js';
import { USER_CODE_CHARSET } from './store.js';
import { createInMemoryDeviceAuthorizationStore, makeRecord } from './test-helpers.js';

describe('generateUserCode', () => {
  describe('Character set and length (RFC 8628 §6.1)', () => {
    it('should return a code of exactly 9 characters including the separator', () => {
      expect(generateUserCode()).toHaveLength(9);
    });

    it('should format the code as XXXX-XXXX', () => {
      expect(/^[A-Z]{4}-[A-Z]{4}$/.test(generateUserCode())).toBe(true);
    });

    it('should only use characters from the RFC 8628 base-20 charset', () => {
      const offCharset = new Set<string>();
      for (let i = 0; i < 200; i++) {
        for (const char of generateUserCode().replace('-', '')) {
          if (!USER_CODE_CHARSET.includes(char)) offCharset.add(char);
        }
      }

      expect([...offCharset]).toEqual([]);
    });

    it('should produce every charset character across enough samples', () => {
      // rejection sampling が特定の文字を落としていないことの確認。
      const seen = new Set<string>();
      for (let i = 0; i < 2000; i++) {
        for (const char of generateUserCode().replace('-', '')) seen.add(char);
      }

      expect([...seen].sort().join('')).toBe([...USER_CODE_CHARSET].sort().join(''));
    });

    it('should not repeat the same code across consecutive calls', () => {
      expect(generateUserCode() === generateUserCode()).toBe(false);
    });
  });
});

describe('formatUserCode', () => {
  it('should insert a hyphen between the two 4-character groups', () => {
    expect(formatUserCode('WDJBMJHT')).toBe('WDJB-MJHT');
  });
});

describe('normalizeUserCode', () => {
  it('should upper-case a lower-case code', () => {
    expect(normalizeUserCode('wdjbmjht')).toBe('WDJBMJHT');
  });

  it('should strip the display hyphen', () => {
    expect(normalizeUserCode('WDJB-MJHT')).toBe('WDJBMJHT');
  });

  it('should strip spaces around and inside the code', () => {
    expect(normalizeUserCode(' wdjb mjht ')).toBe('WDJBMJHT');
  });

  it('should strip a full-width space', () => {
    expect(normalizeUserCode('WDJB　MJHT')).toBe('WDJBMJHT');
  });

  it('should leave an already normalized code unchanged', () => {
    expect(normalizeUserCode('WDJBMJHT')).toBe('WDJBMJHT');
  });

  it('should return an empty string for an empty input', () => {
    expect(normalizeUserCode('')).toBe('');
  });
});

describe('generateUniqueUserCode', () => {
  it('should return the normalized key alongside the display form', async () => {
    const store = createInMemoryDeviceAuthorizationStore();

    const result = await generateUniqueUserCode(store);

    expect(result.userCode).toBe(result.userCodeDisplay.replace('-', ''));
  });

  it('should retry until it finds a code that is not already stored', async () => {
    const store = createInMemoryDeviceAuthorizationStore();
    const lookups: string[] = [];
    let calls = 0;
    const collidingStore = {
      ...store,
      async findByUserCode(userCode: string) {
        lookups.push(userCode);
        calls++;
        // 最初の 2 回だけ衝突しているように見せる。
        return calls <= 2 ? makeRecord({ userCode }) : null;
      },
    };

    const result = await generateUniqueUserCode(collidingStore);

    expect(lookups).toEqual([lookups[0], lookups[1], result.userCode]);
  });

  it('should throw after the attempt limit when every generated code collides', async () => {
    const store = createInMemoryDeviceAuthorizationStore();
    const alwaysCollidingStore = {
      ...store,
      async findByUserCode(userCode: string) {
        return makeRecord({ userCode });
      },
    };

    await expect(generateUniqueUserCode(alwaysCollidingStore, 3)).rejects.toThrow(
      'Failed to generate a unique user_code after 3 attempts',
    );
  });

  it('should not include the generated code in the collision error message', async () => {
    const store = createInMemoryDeviceAuthorizationStore();
    const generated: string[] = [];
    const alwaysCollidingStore = {
      ...store,
      async findByUserCode(userCode: string) {
        generated.push(userCode);
        return makeRecord({ userCode });
      },
    };

    const error = await generateUniqueUserCode(alwaysCollidingStore, 2).catch((e: Error) => e);

    expect(generated.some((code) => (error as Error).message.includes(code))).toBe(false);
  });
});
```

`device-authorization-request.test.ts` pins down the device authorization endpoint: grant permission checks, scope requirements and normalization, the four quadrants of the offline_access policy (feature enabled × client registration), record contents and expiry, the response shape (including `verification_uri_complete` assembly), and the composition function end to end.

```typescript
import { describe, expect, it } from 'vitest';
import {
  applyOfflineAccessPolicy,
  buildDeviceAuthorizationResponse,
  createDeviceAuthorizationRecord,
  processDeviceAuthorizationRequest,
  validateDeviceAuthorizationScope,
  validateDeviceGrantAllowed,
  type DeviceAuthorizationClient,
} from './device-authorization-request.js';
import { DeviceAuthorizationError } from './errors.js';
import { DEVICE_CODE_GRANT_TYPE } from './store.js';
import { NOW, createInMemoryDeviceAuthorizationStore, makeRecord } from './test-helpers.js';

const ISSUER = 'http://localhost:3000';

const DEVICE_CLIENT: DeviceAuthorizationClient = {
  clientId: 'tv-app',
  grantTypes: [DEVICE_CODE_GRANT_TYPE],
};

const DEVICE_AND_REFRESH_CLIENT: DeviceAuthorizationClient = {
  clientId: 'tv-app-refresh',
  grantTypes: [DEVICE_CODE_GRANT_TYPE, 'refresh_token'],
};

describe('validateDeviceGrantAllowed', () => {
  it('should accept a client registered for the device_code grant', () => {
    expect(() => validateDeviceGrantAllowed(DEVICE_CLIENT)).not.toThrow();
  });

  it('should reject a client whose grantTypes omit the device_code URN', () => {
    const client: DeviceAuthorizationClient = {
      clientId: 'web-app',
      grantTypes: ['authorization_code'],
    };

    expect(() => validateDeviceGrantAllowed(client)).toThrowError(
      new DeviceAuthorizationError(
        'unauthorized_client',
        'The client is not authorized to use the device_code grant',
      ),
    );
  });

  it('should reject a client with no registered grantTypes at all', () => {
    expect(() => validateDeviceGrantAllowed({ clientId: 'unknown' })).toThrowError(
      DeviceAuthorizationError,
    );
  });

  it('should set the error code to unauthorized_client', () => {
    const error = (() => {
      try {
        validateDeviceGrantAllowed({ clientId: 'web-app', grantTypes: [] });
        return null;
      } catch (caught) {
        return caught as DeviceAuthorizationError;
      }
    })();

    expect(error?.code).toBe('unauthorized_client');
  });
});

describe('validateDeviceAuthorizationScope', () => {
  // RFC 8628 §3.1 では scope は OPTIONAL だが、本 OP は authorize と同じ
  // プロファイル制限（scope 必須・openid 必須）を課す。
  it('should return the parsed scope values when openid is present', () => {
    expect(validateDeviceAuthorizationScope('openid profile')).toEqual(['openid', 'profile']);
  });

  it('should collapse repeated whitespace between scope values', () => {
    expect(validateDeviceAuthorizationScope('  openid   email  ')).toEqual(['openid', 'email']);
  });

  it('should remove duplicate scope values', () => {
    expect(validateDeviceAuthorizationScope('openid openid profile')).toEqual([
      'openid',
      'profile',
    ]);
  });

  it('should reject a missing scope with invalid_request', () => {
    expect(() => validateDeviceAuthorizationScope(undefined)).toThrowError(
      new DeviceAuthorizationError('invalid_request', 'Missing required parameter: scope'),
    );
  });

  it('should reject a blank scope with invalid_request', () => {
    expect(() => validateDeviceAuthorizationScope('   ')).toThrowError(
      new DeviceAuthorizationError('invalid_request', 'Missing required parameter: scope'),
    );
  });

  it('should reject a scope without openid with invalid_scope', () => {
    expect(() => validateDeviceAuthorizationScope('profile email')).toThrowError(
      new DeviceAuthorizationError('invalid_scope', 'The openid scope is required'),
    );
  });
});

describe('applyOfflineAccessPolicy', () => {
  // OIDC Core 1.0 §11: 許可条件を満たさない offline_access は無視する（エラーにしない）。
  it('should keep offline_access when the feature is enabled and the client allows refresh', () => {
    const result = applyOfflineAccessPolicy(['openid', 'offline_access'], {
      client: DEVICE_AND_REFRESH_CLIENT,
      refreshTokenFeatureEnabled: true,
    });

    expect(result).toEqual(['openid', 'offline_access']);
  });

  it('should drop offline_access when the refresh-token feature is disabled', () => {
    const result = applyOfflineAccessPolicy(['openid', 'offline_access'], {
      client: DEVICE_AND_REFRESH_CLIENT,
      refreshTokenFeatureEnabled: false,
    });

    expect(result).toEqual(['openid']);
  });

  it('should drop offline_access when the client is not registered for refresh_token', () => {
    const result = applyOfflineAccessPolicy(['openid', 'offline_access'], {
      client: DEVICE_CLIENT,
      refreshTokenFeatureEnabled: true,
    });

    expect(result).toEqual(['openid']);
  });

  it('should leave a scope without offline_access unchanged', () => {
    const result = applyOfflineAccessPolicy(['openid', 'profile'], {
      client: DEVICE_CLIENT,
      refreshTokenFeatureEnabled: false,
    });

    expect(result).toEqual(['openid', 'profile']);
  });
});

describe('createDeviceAuthorizationRecord', () => {
  it('should save a pending record under the generated device_code', async () => {
    const store = createInMemoryDeviceAuthorizationStore();

    const record = await createDeviceAuthorizationRecord({
      clientId: 'tv-app',
      scope: ['openid'],
      store,
      expiresIn: 600,
      interval: 5,
      now: NOW,
    });

    expect(await store.findByDeviceCode(record.deviceCode)).toEqual(record);
  });

  it('should initialize the record with the full pending state', async () => {
    const store = createInMemoryDeviceAuthorizationStore();

    const record = await createDeviceAuthorizationRecord({
      clientId: 'tv-app',
      scope: ['openid', 'profile'],
      store,
      expiresIn: 600,
      interval: 5,
      now: NOW,
    });

    expect(record).toMatchObject({
      clientId: 'tv-app',
      scope: ['openid', 'profile'],
      status: 'pending',
      createdAt: NOW,
      expiresAt: new Date(NOW.getTime() + 600_000),
      interval: 5,
      lastPolledAt: null,
      csrfToken: null,
      bindingHash: null,
      loginAttempts: 0,
    });
  });

  it('should generate a 256-bit URL-safe device_code (RFC 8628 §5.2)', async () => {
    const store = createInMemoryDeviceAuthorizationStore();

    const record = await createDeviceAuthorizationRecord({
      clientId: 'tv-app',
      scope: ['openid'],
      store,
      expiresIn: 600,
      interval: 5,
    });

    // 32 バイトの Base64URL は 43 文字（padding なし）。
    expect(record.deviceCode).toHaveLength(43);
  });

  it('should store the normalized user_code as the lookup key', async () => {
    const store = createInMemoryDeviceAuthorizationStore();

    const record = await createDeviceAuthorizationRecord({
      clientId: 'tv-app',
      scope: ['openid'],
      store,
      expiresIn: 600,
      interval: 5,
    });

    expect(await store.findByUserCode(record.userCode)).toEqual(record);
  });

  it('should keep the display form separate from the lookup key', async () => {
    const store = createInMemoryDeviceAuthorizationStore();

    const record = await createDeviceAuthorizationRecord({
      clientId: 'tv-app',
      scope: ['openid'],
      store,
      expiresIn: 600,
      interval: 5,
    });

    expect(record.userCodeDisplay).toBe(
      record.userCode.slice(0, 4) + '-' + record.userCode.slice(4),
    );
  });
});

describe('buildDeviceAuthorizationResponse', () => {
  // RFC 8628 §3.2 の応答フィールド。
  it('should build all six response fields from the record and issuer', () => {
    const record = makeRecord({
      deviceCode: 'dc-value',
      userCode: 'WDJBMJHT',
      userCodeDisplay: 'WDJB-MJHT',
      interval: 5,
    });

    expect(buildDeviceAuthorizationResponse(record, ISSUER)).toEqual({
      device_code: 'dc-value',
      user_code: 'WDJB-MJHT',
      verification_uri: 'http://localhost:3000/device',
      verification_uri_complete: 'http://localhost:3000/device?user_code=WDJB-MJHT',
      expires_in: 600,
      interval: 5,
    });
  });

  it('should derive expires_in from the record lifetime', () => {
    const record = makeRecord({
      createdAt: NOW,
      expiresAt: new Date(NOW.getTime() + 300_000),
    });

    expect(buildDeviceAuthorizationResponse(record, ISSUER).expires_in).toBe(300);
  });

  it('should report the record interval, including one raised by slow_down', () => {
    const record = makeRecord({ interval: 10 });

    expect(buildDeviceAuthorizationResponse(record, ISSUER).interval).toBe(10);
  });
});

describe('processDeviceAuthorizationRequest', () => {
  it('should return the RFC 8628 §3.2 response for a valid request', async () => {
    const store = createInMemoryDeviceAuthorizationStore();

    const response = await processDeviceAuthorizationRequest({
      params: { scope: 'openid profile' },
      client: DEVICE_CLIENT,
      issuer: ISSUER,
      refreshTokenFeatureEnabled: true,
      store,
      now: NOW,
    });

    expect(response).toMatchObject({
      verification_uri: 'http://localhost:3000/device',
      expires_in: 600,
      interval: 5,
    });
  });

  it('should default expires_in to 600 and interval to 5 seconds', async () => {
    const store = createInMemoryDeviceAuthorizationStore();

    const response = await processDeviceAuthorizationRequest({
      params: { scope: 'openid' },
      client: DEVICE_CLIENT,
      issuer: ISSUER,
      refreshTokenFeatureEnabled: true,
      store,
      now: NOW,
    });

    expect([response.expires_in, response.interval]).toEqual([600, 5]);
  });

  it('should honor the configured expires_in and interval', async () => {
    const store = createInMemoryDeviceAuthorizationStore();

    const response = await processDeviceAuthorizationRequest({
      params: { scope: 'openid' },
      client: DEVICE_CLIENT,
      issuer: ISSUER,
      expiresIn: 300,
      interval: 10,
      refreshTokenFeatureEnabled: true,
      store,
      now: NOW,
    });

    expect([response.expires_in, response.interval]).toEqual([300, 10]);
  });

  it('should build verification_uri_complete from the display user_code', async () => {
    const store = createInMemoryDeviceAuthorizationStore();

    const response = await processDeviceAuthorizationRequest({
      params: { scope: 'openid' },
      client: DEVICE_CLIENT,
      issuer: ISSUER,
      refreshTokenFeatureEnabled: true,
      store,
      now: NOW,
    });

    expect(response.verification_uri_complete).toBe(
      'http://localhost:3000/device?user_code=' + response.user_code,
    );
  });

  it('should persist the record so it can be found by device_code', async () => {
    const store = createInMemoryDeviceAuthorizationStore();

    const response = await processDeviceAuthorizationRequest({
      params: { scope: 'openid' },
      client: DEVICE_CLIENT,
      issuer: ISSUER,
      refreshTokenFeatureEnabled: true,
      store,
      now: NOW,
    });
    const record = await store.findByDeviceCode(response.device_code);

    expect(record).toMatchObject({ clientId: 'tv-app', status: 'pending', scope: ['openid'] });
  });

  it('should strip offline_access from the stored scope when refresh is unavailable', async () => {
    const store = createInMemoryDeviceAuthorizationStore();

    const response = await processDeviceAuthorizationRequest({
      params: { scope: 'openid offline_access' },
      client: DEVICE_CLIENT,
      issuer: ISSUER,
      refreshTokenFeatureEnabled: false,
      store,
      now: NOW,
    });
    const record = await store.findByDeviceCode(response.device_code);

    expect(record?.scope).toEqual(['openid']);
  });

  it('should keep offline_access in the stored scope when refresh is available', async () => {
    const store = createInMemoryDeviceAuthorizationStore();

    const response = await processDeviceAuthorizationRequest({
      params: { scope: 'openid offline_access' },
      client: DEVICE_AND_REFRESH_CLIENT,
      issuer: ISSUER,
      refreshTokenFeatureEnabled: true,
      store,
      now: NOW,
    });
    const record = await store.findByDeviceCode(response.device_code);

    expect(record?.scope).toEqual(['openid', 'offline_access']);
  });

  it('should reject a request from a client without the device_code grant', async () => {
    const store = createInMemoryDeviceAuthorizationStore();

    await expect(
      processDeviceAuthorizationRequest({
        params: { scope: 'openid' },
        client: { clientId: 'web-app', grantTypes: ['authorization_code'] },
        issuer: ISSUER,
        refreshTokenFeatureEnabled: true,
        store,
      }),
    ).rejects.toThrowError(DeviceAuthorizationError);
  });

  it('should reject a request with no scope before creating a record', async () => {
    const store = createInMemoryDeviceAuthorizationStore();

    await processDeviceAuthorizationRequest({
      params: {},
      client: DEVICE_CLIENT,
      issuer: ISSUER,
      refreshTokenFeatureEnabled: true,
      store,
    }).catch(() => undefined);

    expect(store.records.size).toBe(0);
  });

  it('should issue a different device_code for every request', async () => {
    const store = createInMemoryDeviceAuthorizationStore();
    const input = {
      params: { scope: 'openid' },
      client: DEVICE_CLIENT,
      issuer: ISSUER,
      refreshTokenFeatureEnabled: true,
      store,
    };

    const first = await processDeviceAuthorizationRequest(input);
    const second = await processDeviceAuthorizationRequest(input);

    expect(first.device_code === second.device_code).toBe(false);
  });

  it('should issue a different user_code for every request', async () => {
    const store = createInMemoryDeviceAuthorizationStore();
    const input = {
      params: { scope: 'openid' },
      client: DEVICE_CLIENT,
      issuer: ISSUER,
      refreshTokenFeatureEnabled: true,
      store,
    };

    const first = await processDeviceAuthorizationRequest(input);
    const second = await processDeviceAuthorizationRequest(input);

    expect(first.user_code === second.user_code).toBe(false);
  });
});
```

`verification.test.ts` pins down the verification step functions: every match-failure kind returning `null`, binding issuance / rotation / validation (hash-only storage, 403 without the raw value), CSRF matching, login-failure counting with the `denied` transition at the cap, and the approval / denial transitions (which fields get fixed, spent values cleared, non-pending rejected).

```typescript
import { describe, expect, it } from 'vitest';
import {
  approveDeviceAuthorization,
  denyDeviceAuthorization,
  findPendingRecordByUserCode,
  issueVerificationBinding,
  recordDeviceLoginFailure,
  validateVerificationBinding,
  validateVerificationCsrfToken,
} from './verification.js';
import { DeviceAuthorizationError, DeviceVerificationError } from './errors.js';
import { NOW, createInMemoryDeviceAuthorizationStore, makeRecord } from './test-helpers.js';

describe('findPendingRecordByUserCode', () => {
  it('should find a pending record by its normalized user_code', async () => {
    const store = createInMemoryDeviceAuthorizationStore();
    const record = makeRecord();
    await store.save(record);

    expect(await findPendingRecordByUserCode('WDJBMJHT', store, NOW)).toEqual(record);
  });

  it('should accept the display form with its hyphen', async () => {
    const store = createInMemoryDeviceAuthorizationStore();
    const record = makeRecord();
    await store.save(record);

    expect(await findPendingRecordByUserCode('WDJB-MJHT', store, NOW)).toEqual(record);
  });

  it('should accept a lower-case code with surrounding spaces', async () => {
    const store = createInMemoryDeviceAuthorizationStore();
    const record = makeRecord();
    await store.save(record);

    expect(await findPendingRecordByUserCode(' wdjb-mjht ', store, NOW)).toEqual(record);
  });

  it('should return null for an unknown code', async () => {
    const store = createInMemoryDeviceAuthorizationStore();
    await store.save(makeRecord());

    expect(await findPendingRecordByUserCode('BCDFGHJK', store, NOW)).toBe(null);
  });

  it('should return null for an empty input', async () => {
    const store = createInMemoryDeviceAuthorizationStore();
    await store.save(makeRecord());

    expect(await findPendingRecordByUserCode('', store, NOW)).toBe(null);
  });

  it('should return null for an expired record', async () => {
    const store = createInMemoryDeviceAuthorizationStore();
    await store.save(makeRecord({ expiresAt: new Date(NOW.getTime() - 1) }));

    expect(await findPendingRecordByUserCode('WDJBMJHT', store, NOW)).toBe(null);
  });

  it('should return null exactly at the expiry instant', async () => {
    const store = createInMemoryDeviceAuthorizationStore();
    await store.save(makeRecord({ expiresAt: NOW }));

    expect(await findPendingRecordByUserCode('WDJBMJHT', store, NOW)).toBe(null);
  });

  it('should return null for an already approved record', async () => {
    const store = createInMemoryDeviceAuthorizationStore();
    await store.save(makeRecord({ status: 'approved' }));

    expect(await findPendingRecordByUserCode('WDJBMJHT', store, NOW)).toBe(null);
  });

  it('should return null for an already denied record', async () => {
    const store = createInMemoryDeviceAuthorizationStore();
    await store.save(makeRecord({ status: 'denied' }));

    expect(await findPendingRecordByUserCode('WDJBMJHT', store, NOW)).toBe(null);
  });
});

describe('issueVerificationBinding', () => {
  it('should persist the binding hash and the csrf token together', async () => {
    const store = createInMemoryDeviceAuthorizationStore();
    const record = makeRecord();
    await store.save(record);

    const { csrfToken } = await issueVerificationBinding(record, store);
    const stored = await store.findByDeviceCode(record.deviceCode);

    expect([stored?.bindingHash === null, stored?.csrfToken]).toEqual([false, csrfToken]);
  });

  it('should never store the raw binding secret on the record', async () => {
    const store = createInMemoryDeviceAuthorizationStore();
    const record = makeRecord();
    await store.save(record);

    const { bindingSecret } = await issueVerificationBinding(record, store);
    const stored = await store.findByDeviceCode(record.deviceCode);

    expect(stored?.bindingHash === bindingSecret).toBe(false);
  });

  it('should rotate both the binding secret and the csrf token on re-issue', async () => {
    const store = createInMemoryDeviceAuthorizationStore();
    const record = makeRecord();
    await store.save(record);

    const first = await issueVerificationBinding(record, store);
    const second = await issueVerificationBinding(record, store);

    expect([
      first.bindingSecret === second.bindingSecret,
      first.csrfToken === second.csrfToken,
    ]).toEqual([false, false]);
  });
});

describe('validateVerificationBinding', () => {
  it('should accept the binding secret that was just issued', async () => {
    const store = createInMemoryDeviceAuthorizationStore();
    const record = makeRecord();
    await store.save(record);
    const { bindingSecret } = await issueVerificationBinding(record, store);

    await expect(validateVerificationBinding(record, bindingSecret)).resolves.toBeUndefined();
  });

  it('should reject a missing cookie with 403', async () => {
    const store = createInMemoryDeviceAuthorizationStore();
    const record = makeRecord();
    await store.save(record);
    await issueVerificationBinding(record, store);

    await expect(validateVerificationBinding(record, null)).rejects.toThrowError(
      new DeviceVerificationError('Device verification binding is missing', 403),
    );
  });

  it('should reject a record that never issued a binding', async () => {
    const record = makeRecord();

    await expect(validateVerificationBinding(record, 'anything')).rejects.toThrowError(
      new DeviceVerificationError('Device verification binding is missing', 403),
    );
  });

  it('should reject a binding secret that does not match the stored hash', async () => {
    const store = createInMemoryDeviceAuthorizationStore();
    const record = makeRecord();
    await store.save(record);
    await issueVerificationBinding(record, store);

    await expect(validateVerificationBinding(record, 'wrong-secret')).rejects.toThrowError(
      new DeviceVerificationError('Device verification binding is invalid', 403),
    );
  });

  it('should reject the binding secret issued before a rotation', async () => {
    const store = createInMemoryDeviceAuthorizationStore();
    const record = makeRecord();
    await store.save(record);
    const stale = await issueVerificationBinding(record, store);
    await issueVerificationBinding(record, store);

    await expect(validateVerificationBinding(record, stale.bindingSecret)).rejects.toThrowError(
      new DeviceVerificationError('Device verification binding is invalid', 403),
    );
  });

  it('should report 403 as the status code for a binding failure', async () => {
    const record = makeRecord();

    const error = await validateVerificationBinding(record, null).catch(
      (caught: DeviceVerificationError) => caught,
    );

    expect(error.statusCode).toBe(403);
  });
});

describe('validateVerificationCsrfToken', () => {
  it('should accept the stored csrf token', () => {
    const record = makeRecord({ csrfToken: 'csrf-value' });

    expect(() => validateVerificationCsrfToken(record, 'csrf-value')).not.toThrow();
  });

  it('should reject a different csrf token with 403', () => {
    const record = makeRecord({ csrfToken: 'csrf-value' });

    expect(() => validateVerificationCsrfToken(record, 'other')).toThrowError(
      new DeviceVerificationError('CSRF token mismatch', 403),
    );
  });

  it('should reject an empty csrf token', () => {
    const record = makeRecord({ csrfToken: 'csrf-value' });

    expect(() => validateVerificationCsrfToken(record, '')).toThrowError(DeviceVerificationError);
  });

  it('should reject when the record has no csrf token yet', () => {
    const record = makeRecord({ csrfToken: null });

    expect(() => validateVerificationCsrfToken(record, '')).toThrowError(DeviceVerificationError);
  });
});

describe('recordDeviceLoginFailure', () => {
  it('should increment the attempt counter and allow a retry below the limit', async () => {
    const store = createInMemoryDeviceAuthorizationStore();
    const record = makeRecord();
    await store.save(record);

    const result = await recordDeviceLoginFailure(record, store, 5);

    expect(result).toEqual({ canRetry: true, remainingAttempts: 4 });
  });

  it('should keep the record pending while retries remain', async () => {
    const store = createInMemoryDeviceAuthorizationStore();
    const record = makeRecord();
    await store.save(record);

    await recordDeviceLoginFailure(record, store, 5);

    expect((await store.findByDeviceCode(record.deviceCode))?.status).toBe('pending');
  });

  it('should refuse a retry once the attempt limit is reached', async () => {
    const store = createInMemoryDeviceAuthorizationStore();
    const record = makeRecord({ loginAttempts: 4 });
    await store.save(record);

    const result = await recordDeviceLoginFailure(record, store, 5);

    expect(result).toEqual({ canRetry: false, remainingAttempts: 0 });
  });

  it('should move the record to denied when the attempt limit is exceeded', async () => {
    const store = createInMemoryDeviceAuthorizationStore();
    const record = makeRecord({ loginAttempts: 4 });
    await store.save(record);

    await recordDeviceLoginFailure(record, store, 5);

    expect((await store.findByDeviceCode(record.deviceCode))?.status).toBe('denied');
  });
});

describe('approveDeviceAuthorization', () => {
  it('should move the record to approved with the full grant context', async () => {
    const store = createInMemoryDeviceAuthorizationStore();
    const record = makeRecord({ csrfToken: 'csrf-value', scope: ['openid', 'profile'] });
    await store.save(record);

    const approved = await approveDeviceAuthorization({
      record,
      store,
      csrfToken: 'csrf-value',
      subject: 'user-1',
      authTime: 1_800_000_000,
    });

    expect(approved).toMatchObject({
      status: 'approved',
      subject: 'user-1',
      authTime: 1_800_000_000,
      approvedScope: ['openid', 'profile'],
    });
  });

  it('should mint a grantId so revocation can kill the grant', async () => {
    const store = createInMemoryDeviceAuthorizationStore();
    const record = makeRecord({ csrfToken: 'csrf-value' });
    await store.save(record);

    const approved = await approveDeviceAuthorization({
      record,
      store,
      csrfToken: 'csrf-value',
      subject: 'user-1',
      authTime: 1_800_000_000,
    });

    expect(approved.grantId).toHaveLength(43);
  });

  it('should clear the binding hash and csrf token after approval', async () => {
    const store = createInMemoryDeviceAuthorizationStore();
    const record = makeRecord({ csrfToken: 'csrf-value', bindingHash: 'hash' });
    await store.save(record);

    const approved = await approveDeviceAuthorization({
      record,
      store,
      csrfToken: 'csrf-value',
      subject: 'user-1',
      authTime: 1_800_000_000,
    });

    expect([approved.bindingHash, approved.csrfToken]).toEqual([null, null]);
  });

  it('should persist the approved record through the store', async () => {
    const store = createInMemoryDeviceAuthorizationStore();
    const record = makeRecord({ csrfToken: 'csrf-value' });
    await store.save(record);

    await approveDeviceAuthorization({
      record,
      store,
      csrfToken: 'csrf-value',
      subject: 'user-1',
      authTime: 1_800_000_000,
    });

    expect((await store.findByDeviceCode(record.deviceCode))?.status).toBe('approved');
  });

  it('should reject an approval whose csrf token does not match', async () => {
    const store = createInMemoryDeviceAuthorizationStore();
    const record = makeRecord({ csrfToken: 'csrf-value' });
    await store.save(record);

    await expect(
      approveDeviceAuthorization({
        record,
        store,
        csrfToken: 'wrong',
        subject: 'user-1',
        authTime: 1_800_000_000,
      }),
    ).rejects.toThrowError(DeviceVerificationError);
  });

  it('should leave the record pending when the csrf check fails', async () => {
    const store = createInMemoryDeviceAuthorizationStore();
    const record = makeRecord({ csrfToken: 'csrf-value' });
    await store.save(record);

    await approveDeviceAuthorization({
      record,
      store,
      csrfToken: 'wrong',
      subject: 'user-1',
      authTime: 1_800_000_000,
    }).catch(() => undefined);

    expect((await store.findByDeviceCode(record.deviceCode))?.status).toBe('pending');
  });

  it('should refuse to approve a record that was already denied', async () => {
    const store = createInMemoryDeviceAuthorizationStore();
    const record = makeRecord({ csrfToken: 'csrf-value', status: 'denied' });
    await store.save(record);

    await expect(
      approveDeviceAuthorization({
        record,
        store,
        csrfToken: 'csrf-value',
        subject: 'user-1',
        authTime: 1_800_000_000,
      }),
    ).rejects.toThrowError(DeviceAuthorizationError);
  });
});

describe('denyDeviceAuthorization', () => {
  it('should move the record to denied', async () => {
    const store = createInMemoryDeviceAuthorizationStore();
    const record = makeRecord({ csrfToken: 'csrf-value' });
    await store.save(record);

    const denied = await denyDeviceAuthorization({ record, store, csrfToken: 'csrf-value' });

    expect(denied.status).toBe('denied');
  });

  it('should not record a subject when the user denies', async () => {
    const store = createInMemoryDeviceAuthorizationStore();
    const record = makeRecord({ csrfToken: 'csrf-value' });
    await store.save(record);

    const denied = await denyDeviceAuthorization({ record, store, csrfToken: 'csrf-value' });

    expect(denied.subject).toBeUndefined();
  });

  it('should reject a denial whose csrf token does not match', async () => {
    const store = createInMemoryDeviceAuthorizationStore();
    const record = makeRecord({ csrfToken: 'csrf-value' });
    await store.save(record);

    await expect(
      denyDeviceAuthorization({ record, store, csrfToken: 'wrong' }),
    ).rejects.toThrowError(DeviceVerificationError);
  });

  it('should refuse to deny a record that was already approved', async () => {
    const store = createInMemoryDeviceAuthorizationStore();
    const record = makeRecord({ csrfToken: 'csrf-value', status: 'approved' });
    await store.save(record);

    await expect(
      denyDeviceAuthorization({ record, store, csrfToken: 'csrf-value' }),
    ).rejects.toThrowError(DeviceAuthorizationError);
  });
});
```

`device-code-grant.test.ts` pins down the token-endpoint state machine: each of the five §3.5 states' responses and record side effects, the evaluation order (expiry before poll speed), the interval increase on slow_down, consumption of approved records with first-wins concurrent redemption, and the single-message client binding.

```typescript
import { describe, expect, it } from 'vitest';
import {
  evaluateDeviceCodeState,
  processDeviceCodeGrant,
  resolveDeviceCodeRecord,
  validateDeviceCodeGrantAllowed,
  type DeviceCodeGrantClient,
} from './device-code-grant.js';
import { DeviceAuthorizationError } from './errors.js';
import { DEVICE_CODE_GRANT_TYPE } from './store.js';
import { NOW, createInMemoryDeviceAuthorizationStore, makeRecord } from './test-helpers.js';

const DEVICE_CLIENT: DeviceCodeGrantClient = {
  clientId: 'device-client',
  grantTypes: [DEVICE_CODE_GRANT_TYPE],
};

function approvedRecord(overrides = {}) {
  return makeRecord({
    status: 'approved',
    subject: 'user-1',
    authTime: 1_800_000_000,
    approvedScope: ['openid', 'profile'],
    grantId: 'grant-1',
    ...overrides,
  });
}

async function codeFor(record = makeRecord()) {
  const store = createInMemoryDeviceAuthorizationStore();
  await store.save(record);
  return { store, record };
}

describe('validateDeviceCodeGrantAllowed', () => {
  it('should accept a client registered for the device_code grant', () => {
    expect(() => validateDeviceCodeGrantAllowed(DEVICE_CLIENT)).not.toThrow();
  });

  it('should reject a client whose grantTypes omit the device_code URN', () => {
    expect(() =>
      validateDeviceCodeGrantAllowed({ clientId: 'web-app', grantTypes: ['authorization_code'] }),
    ).toThrowError(
      new DeviceAuthorizationError(
        'unauthorized_client',
        'The client is not authorized to use the device_code grant',
      ),
    );
  });
});

describe('resolveDeviceCodeRecord', () => {
  it('should resolve the record issued to this client', async () => {
    const { store, record } = await codeFor();

    expect(
      await resolveDeviceCodeRecord({ device_code: record.deviceCode }, DEVICE_CLIENT, store),
    ).toEqual(record);
  });

  it('should reject a missing device_code with invalid_request', async () => {
    const { store } = await codeFor();

    await expect(resolveDeviceCodeRecord({}, DEVICE_CLIENT, store)).rejects.toThrowError(
      new DeviceAuthorizationError('invalid_request', 'Missing required parameter: device_code'),
    );
  });

  it('should reject an empty device_code with invalid_request', async () => {
    const { store } = await codeFor();

    await expect(
      resolveDeviceCodeRecord({ device_code: '' }, DEVICE_CLIENT, store),
    ).rejects.toThrowError(DeviceAuthorizationError);
  });

  it('should reject an unknown device_code with invalid_grant', async () => {
    const { store } = await codeFor();

    await expect(
      resolveDeviceCodeRecord({ device_code: 'unknown' }, DEVICE_CLIENT, store),
    ).rejects.toThrowError(
      new DeviceAuthorizationError(
        'invalid_grant',
        'The device_code is invalid, expired, or was issued to another client',
      ),
    );
  });

  it('should reject a device_code issued to another client with the same wording', async () => {
    // RFC 8628 §3.4: device_code は発行先クライアントに紐づく。文言を不存在時と
    // 揃えることで、他クライアントのコードの実在性を漏らさない。
    const { store, record } = await codeFor();

    await expect(
      resolveDeviceCodeRecord(
        { device_code: record.deviceCode },
        { clientId: 'other-client', grantTypes: [DEVICE_CODE_GRANT_TYPE] },
        store,
      ),
    ).rejects.toThrowError(
      new DeviceAuthorizationError(
        'invalid_grant',
        'The device_code is invalid, expired, or was issued to another client',
      ),
    );
  });
});

describe('evaluateDeviceCodeState', () => {
  describe('expired_token (RFC 8628 §3.5)', () => {
    it('should return expired_token once the lifetime has passed', async () => {
      const { store, record } = await codeFor(
        makeRecord({ expiresAt: new Date(NOW.getTime() - 1) }),
      );

      await expect(evaluateDeviceCodeState(record, store, NOW)).rejects.toThrowError(
        new DeviceAuthorizationError(
          'expired_token',
          'The device_code has expired. Start a new device authorization request.',
        ),
      );
    });

    it('should return expired_token exactly at the expiry instant', async () => {
      const { store, record } = await codeFor(makeRecord({ expiresAt: NOW }));

      const error = await evaluateDeviceCodeState(record, store, NOW).catch(
        (caught: DeviceAuthorizationError) => caught,
      );

      expect(error.code).toBe('expired_token');
    });

    it('should delete the expired record', async () => {
      const { store, record } = await codeFor(makeRecord({ expiresAt: NOW }));

      await evaluateDeviceCodeState(record, store, NOW).catch(() => undefined);

      expect(await store.findByDeviceCode(record.deviceCode)).toBe(null);
    });

    it('should prefer expired_token over slow_down for an expired record', async () => {
      const { store, record } = await codeFor(
        makeRecord({ expiresAt: NOW, lastPolledAt: NOW }),
      );

      const error = await evaluateDeviceCodeState(record, store, NOW).catch(
        (caught: DeviceAuthorizationError) => caught,
      );

      expect(error.code).toBe('expired_token');
    });
  });

  describe('slow_down (RFC 8628 §3.5)', () => {
    it('should return slow_down when polled inside the interval', async () => {
      const { store, record } = await codeFor(
        makeRecord({ lastPolledAt: new Date(NOW.getTime() - 1_000) }),
      );

      const error = await evaluateDeviceCodeState(record, store, NOW).catch(
        (caught: DeviceAuthorizationError) => caught,
      );

      expect(error.code).toBe('slow_down');
    });

    it('should increase the stored interval by 5 seconds on slow_down', async () => {
      const { store, record } = await codeFor(
        makeRecord({ interval: 5, lastPolledAt: new Date(NOW.getTime() - 1_000) }),
      );

      await evaluateDeviceCodeState(record, store, NOW).catch(() => undefined);

      expect((await store.findByDeviceCode(record.deviceCode))?.interval).toBe(10);
    });

    it('should keep raising the interval on repeated slow_down responses', async () => {
      const { store, record } = await codeFor(
        makeRecord({ interval: 5, lastPolledAt: new Date(NOW.getTime() - 1_000) }),
      );

      await evaluateDeviceCodeState(record, store, NOW).catch(() => undefined);
      await evaluateDeviceCodeState(record, store, NOW).catch(() => undefined);

      expect((await store.findByDeviceCode(record.deviceCode))?.interval).toBe(15);
    });

    it('should not return slow_down exactly at the interval boundary', async () => {
      const { store, record } = await codeFor(
        makeRecord({ interval: 5, lastPolledAt: new Date(NOW.getTime() - 5_000) }),
      );

      const error = await evaluateDeviceCodeState(record, store, NOW).catch(
        (caught: DeviceAuthorizationError) => caught,
      );

      expect(error.code).toBe('authorization_pending');
    });
  });

  describe('authorization_pending (RFC 8628 §3.5)', () => {
    it('should return authorization_pending on the first poll', async () => {
      const { store, record } = await codeFor();

      await expect(evaluateDeviceCodeState(record, store, NOW)).rejects.toThrowError(
        new DeviceAuthorizationError(
          'authorization_pending',
          'The authorization request is still pending',
        ),
      );
    });

    it('should record the poll timestamp so the next poll can be rate-checked', async () => {
      const { store, record } = await codeFor();

      await evaluateDeviceCodeState(record, store, NOW).catch(() => undefined);

      expect((await store.findByDeviceCode(record.deviceCode))?.lastPolledAt).toEqual(NOW);
    });

    it('should keep the record so the device can poll again', async () => {
      const { store, record } = await codeFor();

      await evaluateDeviceCodeState(record, store, NOW).catch(() => undefined);

      expect((await store.findByDeviceCode(record.deviceCode))?.status).toBe('pending');
    });
  });

  describe('access_denied (RFC 8628 §3.5)', () => {
    it('should return access_denied for a denied record', async () => {
      const { store, record } = await codeFor(makeRecord({ status: 'denied' }));

      await expect(evaluateDeviceCodeState(record, store, NOW)).rejects.toThrowError(
        new DeviceAuthorizationError(
          'access_denied',
          'The end-user denied the authorization request',
        ),
      );
    });

    it('should delete the denied record', async () => {
      const { store, record } = await codeFor(makeRecord({ status: 'denied' }));

      await evaluateDeviceCodeState(record, store, NOW).catch(() => undefined);

      expect(await store.findByDeviceCode(record.deviceCode)).toBe(null);
    });
  });

  describe('Approved (RFC 8628 §3.5 → RFC 6749 §5.1)', () => {
    it('should return the grant context for an approved record', async () => {
      const { store, record } = await codeFor(approvedRecord());

      expect(await evaluateDeviceCodeState(record, store, NOW)).toEqual({
        subject: 'user-1',
        clientId: 'device-client',
        scope: ['openid', 'profile'],
        authTime: 1_800_000_000,
        grantId: 'grant-1',
      });
    });

    it('should consume the record so the device_code cannot be reused', async () => {
      const { store, record } = await codeFor(approvedRecord());

      await evaluateDeviceCodeState(record, store, NOW);

      expect(await store.findByDeviceCode(record.deviceCode)).toBe(null);
    });

    it('should fall back to the requested scope when approvedScope is absent', async () => {
      const { store, record } = await codeFor(
        approvedRecord({ approvedScope: undefined, scope: ['openid'] }),
      );

      expect((await evaluateDeviceCodeState(record, store, NOW)).scope).toEqual(['openid']);
    });

    it('should reject a concurrent second redemption with invalid_grant', async () => {
      const { store, record } = await codeFor(approvedRecord());
      await evaluateDeviceCodeState(record, store, NOW);

      await expect(evaluateDeviceCodeState(record, store, NOW)).rejects.toThrowError(
        new DeviceAuthorizationError(
          'invalid_grant',
          'The device_code is invalid, expired, or was issued to another client',
        ),
      );
    });
  });
});

describe('processDeviceCodeGrant', () => {
  it('should issue the grant context for an approved device_code', async () => {
    const { store, record } = await codeFor(approvedRecord());

    const result = await processDeviceCodeGrant({
      params: { device_code: record.deviceCode },
      client: DEVICE_CLIENT,
      store,
      now: NOW,
    });

    expect(result).toEqual({
      subject: 'user-1',
      clientId: 'device-client',
      scope: ['openid', 'profile'],
      authTime: 1_800_000_000,
      grantId: 'grant-1',
    });
  });

  it('should reject a client that is not registered for the device_code grant', async () => {
    const { store, record } = await codeFor(approvedRecord());

    await expect(
      processDeviceCodeGrant({
        params: { device_code: record.deviceCode },
        client: { clientId: 'device-client', grantTypes: ['authorization_code'] },
        store,
        now: NOW,
      }),
    ).rejects.toThrowError(DeviceAuthorizationError);
  });

  it('should return invalid_grant when the same device_code is redeemed twice', async () => {
    const { store, record } = await codeFor(approvedRecord());
    const input = {
      params: { device_code: record.deviceCode },
      client: DEVICE_CLIENT,
      store,
      now: NOW,
    };
    await processDeviceCodeGrant(input);

    const error = await processDeviceCodeGrant(input).catch(
      (caught: DeviceAuthorizationError) => caught,
    );

    expect(error.code).toBe('invalid_grant');
  });

  it('should answer every state error with HTTP 400', async () => {
    const { store, record } = await codeFor();

    const error = await processDeviceCodeGrant({
      params: { device_code: record.deviceCode },
      client: DEVICE_CLIENT,
      store,
      now: NOW,
    }).catch((caught: DeviceAuthorizationError) => caught);

    expect(error.statusCode).toBe(400);
  });

  it('should not leak the device_code into the error description', async () => {
    const { store, record } = await codeFor();

    const error = await processDeviceCodeGrant({
      params: { device_code: record.deviceCode },
      client: DEVICE_CLIENT,
      store,
      now: NOW,
    }).catch((caught: DeviceAuthorizationError) => caught);

    expect(error.errorDescription.includes(record.deviceCode)).toBe(false);
  });
});
```

## CLI integration and the generated-code contribution

Running `maronn-oidc generate <framework> --enable device-authorization-grant` adds the following to the generated code:

- **routes/device-authorization.ts (new)**: the `POST /device_authorization` handler: client authentication through the shared pipeline, the step-function calls, and `deviceAuthorizationConfig` (`deviceCodeExpiresIn: 600` / `pollInterval: 5` / `maxLoginAttempts: 5`). The file's comments also record the decision to leave rate limiting of the user_code guessing surface to the deployment layer: on runtimes without shared memory between instances (Cloudflare Workers and friends) an in-process counter would only give a false sense of protection, so the in-band defenses are the 20^8 entropy, the short TTL, and identical answers to every failed match
- **routes/device.ts (new)**: the three verification routes: the user_code form, the device login, the approval screen, and issuing / validating the binding cookie
- **routes/token.ts (changed)**: a `grant_type=urn:ietf:params:oauth:grant-type:device_code` branch lands before core's `validateGrantTypeSupported`, feeding `processDeviceCodeGrant`'s result into core's issuance pipeline
- **routes/discovery.ts (changed)**: advertises `device_authorization_endpoint` and the grant type
- **store.ts (changed)**: gains `deviceAuthorizationStore`
- **app.ts / apply.ts / views.ts (changed)**: route mounting, method constraints, and the verification UI views
- **conformance.test.ts (changed)**: all of the above pinned as contract tests

### The complete generated-code diff (hono)

The following is the verbatim diff between the default generation (`default-op`) and `--enable device-authorization-grant` (`with-device-authorization-grant`); it is everything `--enable device-authorization-grant` adds to the generated code.

````diff
diff --git a/default-op/app.ts b/with-device-authorization-grant/app.ts
index 4246f6b..cdce04b 100644
--- a/default-op/app.ts
+++ b/with-device-authorization-grant/app.ts
@@ -5,6 +5,8 @@ import { tokenApp } from './routes/token.js';
 import { userinfoApp } from './routes/userinfo.js';
 import { introspectionApp } from './routes/introspection.js';
 import { revocationApp } from './routes/revocation.js';
+import { deviceAuthorizationApp } from './routes/device-authorization.js';
+import { deviceApp } from './routes/device.js';
 import { jwksApp } from './routes/jwks.js';
 import { discoveryApp } from './routes/discovery.js';
 import { loginApp } from './routes/login.js';
@@ -19,6 +21,7 @@ import {
 } from './resolvers.js';
 import {
   defaultProviderStores,
+  deviceAuthorizationStore,
   type ProviderStores,
   type ProviderStoresFactory,
 } from './store.js';
@@ -105,6 +108,10 @@ const OIDC_ENDPOINT_METHODS: Readonly<Record<string, readonly string[]>> = {
   '/userinfo': ['GET', 'POST'],
   '/introspect': ['POST'],
   '/revoke': ['POST'],
+  '/device_authorization': ['POST'],
+  '/device': ['GET', 'POST'],
+  '/device/login': ['POST'],
+  '/device/approve': ['POST'],
   '/.well-known/jwks.json': ['GET'],
   '/.well-known/openid-configuration': ['GET'],
   '/login': ['GET', 'POST'],
@@ -148,6 +155,7 @@ export function createApp(options: CreateAppOptions): Hono<{ Variables: Record<s
   app.use('/userinfo', protectedCors);
   app.use('/introspect', protectedCors);
   app.use('/revoke', protectedCors);
+  app.use('/device_authorization', protectedCors);
   app.use('/.well-known/openid-configuration', publicCors);
   app.use('/.well-known/jwks.json', publicCors);
   // CORS must run first so OPTIONS preflights are answered before method enforcement.
@@ -215,6 +223,7 @@ export function createApp(options: CreateAppOptions): Hono<{ Variables: Record<s
     c.set('introspectionAccessTokenResolver', storeResolvers.introspectionAccessTokenResolver);
     c.set('introspectionRefreshTokenResolver', storeResolvers.introspectionRefreshTokenResolver);
     c.set('revocationResolvers', storeResolvers.revocationResolvers);
+    c.set('deviceAuthorizationStore', deviceAuthorizationStore);
 
     // P1: default cookie-based session + consent resolvers so prompt=none /
     // max_age / SSO work out of the box (OIDC Core 1.0 Section 3.1.2.1 / 3.1.2.3).
@@ -238,6 +247,8 @@ export function createApp(options: CreateAppOptions): Hono<{ Variables: Record<s
   app.route('/userinfo', userinfoApp);
   app.route('/introspect', introspectionApp);
   app.route('/revoke', revocationApp);
+  app.route('/device_authorization', deviceAuthorizationApp);
+  app.route('/device', deviceApp);
   app.route('/.well-known/jwks.json', jwksApp);
   app.route('/.well-known/openid-configuration', discoveryApp);
   app.route('/login', loginApp);
diff --git a/default-op/apply.ts b/with-device-authorization-grant/apply.ts
index db15234..02fcc6f 100644
--- a/default-op/apply.ts
+++ b/with-device-authorization-grant/apply.ts
@@ -5,6 +5,8 @@ import { tokenApp } from './routes/token.js';
 import { userinfoApp } from './routes/userinfo.js';
 import { introspectionApp } from './routes/introspection.js';
 import { revocationApp } from './routes/revocation.js';
+import { deviceAuthorizationApp } from './routes/device-authorization.js';
+import { deviceApp } from './routes/device.js';
 import { jwksApp } from './routes/jwks.js';
 import { discoveryApp } from './routes/discovery.js';
 import { loginApp } from './routes/login.js';
@@ -19,6 +21,7 @@ import {
 } from './resolvers.js';
 import {
   defaultProviderStores,
+  deviceAuthorizationStore,
   type ProviderStores,
   type ProviderStoresFactory,
 } from './store.js';
@@ -136,6 +139,10 @@ const OIDC_ENDPOINT_METHODS: Readonly<Record<string, readonly string[]>> = {
   '/userinfo': ['GET', 'POST'],
   '/introspect': ['POST'],
   '/revoke': ['POST'],
+  '/device_authorization': ['POST'],
+  '/device': ['GET', 'POST'],
+  '/device/login': ['POST'],
+  '/device/approve': ['POST'],
   '/.well-known/jwks.json': ['GET'],
   '/.well-known/openid-configuration': ['GET'],
   '/login': ['GET', 'POST'],
@@ -191,6 +198,7 @@ export function applyOidc(app: Hono<any>, options: ApplyOidcOptions): void {
   app.use('/userinfo', protectedCors);
   app.use('/introspect', protectedCors);
   app.use('/revoke', protectedCors);
+  app.use('/device_authorization', protectedCors);
   app.use('/.well-known/openid-configuration', publicCors);
   app.use('/.well-known/jwks.json', publicCors);
   // CORS must run first so OPTIONS preflights are answered before method enforcement.
@@ -266,6 +274,7 @@ export function applyOidc(app: Hono<any>, options: ApplyOidcOptions): void {
     c.set('introspectionAccessTokenResolver', storeResolvers.introspectionAccessTokenResolver);
     c.set('introspectionRefreshTokenResolver', storeResolvers.introspectionRefreshTokenResolver);
     c.set('revocationResolvers', storeResolvers.revocationResolvers);
+    c.set('deviceAuthorizationStore', deviceAuthorizationStore);
 
     // T-015: acr / amr resolver (optional; undefined preserves T-009 hold behavior).
     if (options.acrResolver) {
@@ -289,6 +298,8 @@ export function applyOidc(app: Hono<any>, options: ApplyOidcOptions): void {
   app.route('/userinfo', userinfoApp);
   app.route('/introspect', introspectionApp);
   app.route('/revoke', revocationApp);
+  app.route('/device_authorization', deviceAuthorizationApp);
+  app.route('/device', deviceApp);
   app.route('/.well-known/jwks.json', jwksApp);
   app.route('/.well-known/openid-configuration', discoveryApp);
   app.route('/login', loginApp);
diff --git a/default-op/conformance.test.ts b/with-device-authorization-grant/conformance.test.ts
index 58258e6..cf099a8 100644
--- a/default-op/conformance.test.ts
+++ b/with-device-authorization-grant/conformance.test.ts
@@ -137,6 +137,40 @@ const testClients = new Map<string, RegisteredClient>([
     grantTypes: ['authorization_code'],
     tokenEndpointAuthMethod: 'client_secret_post',
   }],
+  // EXPERIMENTAL (RFC 8628): a client registered for the device grant, plus a
+  // second one so the contract test can prove a device_code is refused when it is
+  // presented by a client other than the one it was issued to (§3.4).
+  ['c-device', {
+    clientId: 'c-device',
+    clientSecret: 's',
+    redirectUris: [REDIRECT_URI],
+    clientType: 'confidential' as const,
+    responseTypes: ['code'],
+    grantTypes: ['urn:ietf:params:oauth:grant-type:device_code', 'refresh_token'],
+    tokenEndpointAuthMethod: 'client_secret_post',
+  }],
+  ['c-device-other', {
+    clientId: 'c-device-other',
+    clientSecret: 's',
+    redirectUris: [REDIRECT_URI],
+    clientType: 'confidential' as const,
+    responseTypes: ['code'],
+    grantTypes: ['urn:ietf:params:oauth:grant-type:device_code'],
+    tokenEndpointAuthMethod: 'client_secret_post',
+  }],
+  // A third device client that registered id_token_signed_response_alg, so the
+  // contract test can prove the device grant honors it just like the standard
+  // grants (OIDC Dynamic Client Registration 1.0 §2).
+  ['c-device-es256', {
+    clientId: 'c-device-es256',
+    clientSecret: 's',
+    redirectUris: [REDIRECT_URI],
+    clientType: 'confidential' as const,
+    responseTypes: ['code'],
+    grantTypes: ['urn:ietf:params:oauth:grant-type:device_code'],
+    tokenEndpointAuthMethod: 'client_secret_post',
+    idTokenSignedResponseAlg: 'ES256' as const,
+  }],
 ]);
 
 // OIDC Core 1.0 §6.1: a signed RS256 Request Object for the conformance flow,
@@ -965,6 +999,10 @@ describe('generated provider HTTP conformance', () => {
         { path: '/userinfo', method: 'PUT', allow: 'GET, POST' },
       { path: '/introspect', method: 'GET', allow: 'POST' },
       { path: '/revoke', method: 'GET', allow: 'POST' },
+      { path: '/device_authorization', method: 'GET', allow: 'POST' },
+      { path: '/device', method: 'PUT', allow: 'GET, POST' },
+      { path: '/device/login', method: 'GET', allow: 'POST' },
+      { path: '/device/approve', method: 'GET', allow: 'POST' },
         { path: '/.well-known/openid-configuration', method: 'POST', allow: 'GET' },
         { path: '/.well-known/jwks.json', method: 'POST', allow: 'GET' },
       ];
@@ -2474,58 +2512,723 @@ describe('generated provider HTTP conformance', () => {
   });
 
 
-  // The device authorization grant is disabled in this generated provider: no
-  // endpoint, no metadata, and the URN stays an unsupported grant. These pin the
-  // default-off contract so enabling the feature by accident is visible.
-  describe('Device Authorization Grant disabled (RFC 8628)', () => {
-    it('should not serve a device authorization endpoint', async () => {
-      const res = await app.request('/device_authorization', {
+  // EXPERIMENTAL — OAuth 2.0 Device Authorization Grant (RFC 8628). Generated
+  // because this provider was created with --enable device-authorization-grant.
+  describe('Device Authorization Grant (RFC 8628)', () => {
+    const DEVICE_GRANT_TYPE = 'urn:ietf:params:oauth:grant-type:device_code';
+
+    /**
+     * The app under test. Defaults to the shared one; the ID Token signing key
+     * selection test passes an app built on a mixed RS256 + ES256 key set.
+     */
+    type DeviceTargetApp = { request: (path: string, init?: RequestInit) => Promise<Response> };
+
+    // Pure helpers: they fetch and parse only. Every assertion lives in an it().
+    function requestDeviceAuthorization(
+      overrides: Record<string, string> = {},
+      target: DeviceTargetApp = app,
+    ): Promise<Response> {
+      return target.request('/device_authorization', {
         method: 'POST',
         headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
-        body: new URLSearchParams({ client_id: 'c-conf', scope: 'openid' }).toString(),
+        body: new URLSearchParams({
+          client_id: 'c-device',
+          client_secret: 's',
+          scope: 'openid',
+          ...overrides,
+        }).toString(),
       });
+    }
 
-      expect(res.status).toBe(404);
-    });
-
-    it('should not serve the device verification UI', async () => {
-      const res = await app.request('/device');
-
-      expect(res.status).toBe(404);
-    });
-
-    it('should reject the device_code grant with unsupported_grant_type', async () => {
-      const res = await app.request('/token', {
+    function pollToken(
+      deviceCode: string,
+      overrides: Record<string, string> = {},
+      target: DeviceTargetApp = app,
+    ): Promise<Response> {
+      return target.request('/token', {
         method: 'POST',
         headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
         body: new URLSearchParams({
-          grant_type: 'urn:ietf:params:oauth:grant-type:device_code',
-          device_code: 'anything',
-          client_id: 'c-conf',
+          grant_type: DEVICE_GRANT_TYPE,
+          device_code: deviceCode,
+          client_id: 'c-device',
           client_secret: 's',
+          ...overrides,
         }).toString(),
       });
+    }
 
-      expect(res.status).toBe(400);
-      expect((await res.json()).error).toBe('unsupported_grant_type');
+    function csrfFrom(html: string): string {
+      return html.match(/name="csrf_token" value="([^"]+)"/)?.[1] ?? '';
+    }
+
+    /** All Set-Cookie name=value pairs of a response, joined for a Cookie header. */
+    function cookieJar(...responses: Response[]): string {
+      return responses
+        .flatMap((res) => res.headers.getSetCookie())
+        .map((cookie) => cookie.split(';')[0] ?? '')
+        .filter((pair) => pair.length > 0 && !pair.endsWith('='))
+        .join('; ');
+    }
+
+    function submitUserCode(
+      userCode: string,
+      cookie = '',
+      target: DeviceTargetApp = app,
+    ): Promise<Response> {
+      return target.request('/device', {
+        method: 'POST',
+        headers: {
+          'Content-Type': 'application/x-www-form-urlencoded',
+          ...(cookie ? { Cookie: cookie } : {}),
+        },
+        body: new URLSearchParams({ user_code: userCode }).toString(),
+      });
+    }
+
+    function deviceLogin(
+      body: Record<string, string>,
+      cookie: string,
+      target: DeviceTargetApp = app,
+    ): Promise<Response> {
+      return target.request('/device/login', {
+        method: 'POST',
+        headers: {
+          'Content-Type': 'application/x-www-form-urlencoded',
+          ...(cookie ? { Cookie: cookie } : {}),
+        },
+        body: new URLSearchParams(body).toString(),
+      });
+    }
+
+    function deviceApprove(
+      body: Record<string, string>,
+      cookie: string,
+      target: DeviceTargetApp = app,
+    ): Promise<Response> {
+      return target.request('/device/approve', {
+        method: 'POST',
+        headers: {
+          'Content-Type': 'application/x-www-form-urlencoded',
+          ...(cookie ? { Cookie: cookie } : {}),
+        },
+        body: new URLSearchParams(body).toString(),
+      });
+    }
+
+    /**
+     * Drive the whole browser side of the flow: user_code -> login -> decision.
+     * The binding cookie is carried forward at every step, exactly as a browser
+     * would; without it the OP answers 403.
+     */
+    async function runDeviceFlow(
+      overrides: Record<string, string> = {},
+      decision: 'approve' | 'deny' = 'approve',
+      target: DeviceTargetApp = app,
+    ): Promise<{ device_code: string; user_code: string; completed: Response }> {
+      const authorization = await (await requestDeviceAuthorization(overrides, target)).json();
+      const submitted = await submitUserCode(authorization.user_code, '', target);
+      const bindingCookie = cookieJar(submitted);
+      const loginRes = await deviceLogin(
+        {
+          user_code: authorization.user_code,
+          csrf_token: csrfFrom(await submitted.text()),
+          username: 'testuser',
+          password: 'password',
+        },
+        bindingCookie,
+        target,
+      );
+      const sessionCookie = cookieJar(submitted, loginRes);
+      const completed = await deviceApprove(
+        {
+          user_code: authorization.user_code,
+          csrf_token: csrfFrom(await loginRes.text()),
+          decision,
+        },
+        sessionCookie,
+        target,
+      );
+      return {
+        device_code: authorization.device_code,
+        user_code: authorization.user_code,
+        completed,
+      };
+    }
+
+    describe('Device authorization endpoint (RFC 8628 §3.1 / §3.2)', () => {
+      it('should return the six response fields with a non-cacheable body', async () => {
+        const res = await requestDeviceAuthorization();
+        const body = await res.json();
+
+        expect(res.status).toBe(200);
+        expect(res.headers.get('Cache-Control')).toBe('no-store');
+        expect(res.headers.get('Pragma')).toBe('no-cache');
+        expect(Object.keys(body).sort()).toEqual([
+          'device_code',
+          'expires_in',
+          'interval',
+          'user_code',
+          'verification_uri',
+          'verification_uri_complete',
+        ]);
+      });
+
+      it('should return the configured lifetime and poll interval', async () => {
+        const body = await (await requestDeviceAuthorization()).json();
+
+        expect([body.expires_in, body.interval]).toEqual([600, 5]);
+      });
+
+      it('should build verification_uri and verification_uri_complete from the issuer', async () => {
+        const body = await (await requestDeviceAuthorization()).json();
+
+        expect(body.verification_uri).toBe('http://localhost:3000/device');
+        expect(body.verification_uri_complete).toBe(
+          'http://localhost:3000/device?user_code=' + body.user_code,
+        );
+      });
+
+      it('should mint a base-20 user_code in XXXX-XXXX form (RFC 8628 §6.1)', async () => {
+        const body = await (await requestDeviceAuthorization()).json();
+
+        expect(/^[BCDFGHJKLMNPQRSTVWXZ]{4}-[BCDFGHJKLMNPQRSTVWXZ]{4}$/.test(body.user_code)).toBe(true);
+      });
+
+      it('should mint a 256-bit device_code (RFC 8628 §5.2)', async () => {
+        const body = await (await requestDeviceAuthorization()).json();
+
+        expect((body.device_code as string).length).toBe(43);
+      });
+
+      it('should issue a distinct device_code for every request', async () => {
+        const first = await (await requestDeviceAuthorization()).json();
+        const second = await (await requestDeviceAuthorization()).json();
+
+        expect(first.device_code === second.device_code).toBe(false);
+      });
+
+      it('should reject a body that is not form-urlencoded', async () => {
+        const res = await app.request('/device_authorization', {
+          method: 'POST',
+          headers: { 'Content-Type': 'application/json' },
+          body: JSON.stringify({ client_id: 'c-device', scope: 'openid' }),
+        });
+
+        expect(res.status).toBe(400);
+        expect(await res.json()).toEqual({
+          error: 'invalid_request',
+          error_description: 'Device authorization requests must use application/x-www-form-urlencoded',
+        });
+      });
+
+      it('should reject an unauthenticated request with 401 invalid_client', async () => {
+        const res = await app.request('/device_authorization', {
+          method: 'POST',
+          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
+          body: new URLSearchParams({ client_id: 'c-device', scope: 'openid' }).toString(),
+        });
+
+        expect(res.status).toBe(401);
+        expect((await res.json()).error).toBe('invalid_client');
+      });
+
+      it('should reject a client that is not registered for the device grant', async () => {
+        const res = await requestDeviceAuthorization({ client_id: 'c-conf' });
+
+        expect(res.status).toBe(400);
+        expect(await res.json()).toEqual({
+          error: 'unauthorized_client',
+          error_description: 'The client is not authorized to use the device_code grant',
+        });
+      });
+
+      it('should reject a request with no scope', async () => {
+        // RFC 8628 §3.1 makes scope OPTIONAL; this OP requires it (and openid)
+        // everywhere, which is a documented profile restriction.
+        const res = await app.request('/device_authorization', {
+          method: 'POST',
+          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
+          body: new URLSearchParams({ client_id: 'c-device', client_secret: 's' }).toString(),
+        });
+
+        expect(res.status).toBe(400);
+        expect(await res.json()).toEqual({
+          error: 'invalid_request',
+          error_description: 'Missing required parameter: scope',
+        });
+      });
+
+      it('should reject a scope without openid', async () => {
+        const res = await requestDeviceAuthorization({ scope: 'profile' });
+
+        expect(res.status).toBe(400);
+        expect(await res.json()).toEqual({
+          error: 'invalid_scope',
+          error_description: 'The openid scope is required',
+        });
+      });
     });
 
-    it('should not advertise device authorization metadata', async () => {
-      const res = await app.request('/.well-known/openid-configuration');
-      const metadata = await res.json();
+    describe('Discovery metadata (RFC 8628 §4)', () => {
+      it('should advertise the device authorization endpoint', async () => {
+        const metadata = await (await app.request('/.well-known/openid-configuration')).json();
+
+        expect(metadata.device_authorization_endpoint).toBe(
+          'http://localhost:3000/device_authorization',
+        );
+      });
+
+      it('should advertise the device_code grant type', async () => {
+        const metadata = await (await app.request('/.well-known/openid-configuration')).json();
+
+        expect((metadata.grant_types_supported as string[]).includes(DEVICE_GRANT_TYPE)).toBe(true);
+      });
+    });
+
+    describe('Verification UI (RFC 8628 §3.3)', () => {
+      it('should serve the code entry form without authentication', async () => {
+        const res = await app.request('/device');
+
+        expect(res.status).toBe(200);
+        expect(res.headers.get('Content-Type')).toBe('text/html; charset=UTF-8');
+      });
+
+      it('should pre-fill the form from verification_uri_complete (§3.3.1)', async () => {
+        const body = await (await requestDeviceAuthorization()).json();
+        const url = new URL(body.verification_uri_complete);
+        const html = await (await app.request(url.pathname + url.search)).text();
+
+        expect(html.includes('value="' + body.user_code + '"')).toBe(true);
+      });
 
-      expect(metadata.device_authorization_endpoint).toBeUndefined();
+      it('should not expose a csrf_token before a code has matched', async () => {
+        // The csrf_token only appears on a response that also mints the binding
+        // cookie, so it is never readable by someone who only knows a user_code.
+        const html = await (await app.request('/device')).text();
+
+        expect(csrfFrom(html)).toBe('');
+      });
+
+      it('should answer an unknown user_code with the same reason-free message', async () => {
+        const res = await submitUserCode('BCDF-GHJK');
+
+        expect(res.status).toBe(400);
+        expect((await res.text()).includes('The code is invalid or has expired')).toBe(true);
+      });
+
+      it('should not set a binding cookie for an unknown user_code', async () => {
+        const res = await submitUserCode('BCDF-GHJK');
+
+        expect(res.headers.getSetCookie()).toEqual([]);
+      });
+
+      it('should accept the user_code with its hyphen stripped and lower-cased', async () => {
+        const body = await (await requestDeviceAuthorization()).json();
+        const res = await submitUserCode((body.user_code as string).replace('-', '').toLowerCase());
+
+        expect(res.status).toBe(200);
+      });
+
+      it('should set the binding cookie with the exact hardening attributes', async () => {
+        const body = await (await requestDeviceAuthorization()).json();
+        const res = await submitUserCode(body.user_code);
+        const cookie = res.headers.getSetCookie()[0] ?? '';
+
+        expect(cookie.startsWith('oidc_device_' + (body.user_code as string).replace('-', '') + '=')).toBe(true);
+        expect(cookie.endsWith('; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=600')).toBe(true);
+      });
+
+      it('should show the login form when no OP session exists', async () => {
+        const body = await (await requestDeviceAuthorization()).json();
+        const html = await (await submitUserCode(body.user_code)).text();
+
+        expect(html.includes('action="/device/login"')).toBe(true);
+      });
+
+      it('should embed a csrf_token once the code matched', async () => {
+        const body = await (await requestDeviceAuthorization()).json();
+        const html = await (await submitUserCode(body.user_code)).text();
+
+        expect(csrfFrom(html).length > 0).toBe(true);
+      });
     });
 
-    it('should not advertise the device_code grant type', async () => {
-      const res = await app.request('/.well-known/openid-configuration');
-      const metadata = await res.json();
+    describe('Browser binding enforcement (RFC 8628 §5.4)', () => {
+      it('should reject /device/login without the binding cookie even with a valid csrf_token', async () => {
+        // The whole point: a valid csrf_token is obtainable by anyone who knows
+        // the user_code, so it must NOT be sufficient on its own.
+        const body = await (await requestDeviceAuthorization()).json();
+        const submitted = await submitUserCode(body.user_code);
+        const csrfToken = csrfFrom(await submitted.text());
+
+        const res = await deviceLogin(
+          { user_code: body.user_code, csrf_token: csrfToken, username: 'testuser', password: 'password' },
+          '',
+        );
+
+        expect(res.status).toBe(403);
+      });
+
+      it('should not establish a session when /device/login is unbound', async () => {
+        const body = await (await requestDeviceAuthorization()).json();
+        const submitted = await submitUserCode(body.user_code);
+        const csrfToken = csrfFrom(await submitted.text());
+
+        const res = await deviceLogin(
+          { user_code: body.user_code, csrf_token: csrfToken, username: 'testuser', password: 'password' },
+          '',
+        );
+
+        expect(res.headers.getSetCookie()).toEqual([]);
+      });
+
+      it('should reject /device/approve without the binding cookie', async () => {
+        const body = await (await requestDeviceAuthorization()).json();
+        const submitted = await submitUserCode(body.user_code);
+        const bindingCookie = cookieJar(submitted);
+        const loginRes = await deviceLogin(
+          {
+            user_code: body.user_code,
+            csrf_token: csrfFrom(await submitted.text()),
+            username: 'testuser',
+            password: 'password',
+          },
+          bindingCookie,
+        );
+        // Session cookie only: the forged request cannot carry the binding.
+        const sessionOnly = cookieJar(loginRes);
+
+        const res = await deviceApprove(
+          {
+            user_code: body.user_code,
+            csrf_token: csrfFrom(await loginRes.text()),
+            decision: 'approve',
+          },
+          sessionOnly,
+        );
+
+        expect(res.status).toBe(403);
+      });
+
+      it('should leave the record unapproved after an unbound approve attempt', async () => {
+        const body = await (await requestDeviceAuthorization()).json();
+        const submitted = await submitUserCode(body.user_code);
+        const bindingCookie = cookieJar(submitted);
+        const loginRes = await deviceLogin(
+          {
+            user_code: body.user_code,
+            csrf_token: csrfFrom(await submitted.text()),
+            username: 'testuser',
+            password: 'password',
+          },
+          bindingCookie,
+        );
+        await deviceApprove(
+          {
+            user_code: body.user_code,
+            csrf_token: csrfFrom(await loginRes.text()),
+            decision: 'approve',
+          },
+          cookieJar(loginRes),
+        );
+        const res = await pollToken(body.device_code);
+
+        expect((await res.json()).error).toBe('authorization_pending');
+      });
+
+      it('should reject a wrong csrf_token even with a valid binding cookie', async () => {
+        const body = await (await requestDeviceAuthorization()).json();
+        const submitted = await submitUserCode(body.user_code);
+
+        const res = await deviceLogin(
+          { user_code: body.user_code, csrf_token: 'forged', username: 'testuser', password: 'password' },
+          cookieJar(submitted),
+        );
+
+        expect(res.status).toBe(403);
+      });
+
+      it('should invalidate the previous binding when the code is submitted again', async () => {
+        const body = await (await requestDeviceAuthorization()).json();
+        const first = await submitUserCode(body.user_code);
+        const firstCsrf = csrfFrom(await first.text());
+        const firstCookie = cookieJar(first);
+        await submitUserCode(body.user_code);
+
+        const res = await deviceLogin(
+          { user_code: body.user_code, csrf_token: firstCsrf, username: 'testuser', password: 'password' },
+          firstCookie,
+        );
+
+        expect(res.status).toBe(403);
+      });
+
+      it('should clear the binding cookie once the decision is recorded', async () => {
+        const flow = await runDeviceFlow();
+        const cleared = flow.completed.headers.getSetCookie()[0] ?? '';
+
+        expect(cleared.startsWith('oidc_device_' + flow.user_code.replace('-', '') + '=;')).toBe(true);
+        expect(cleared.endsWith('; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=0')).toBe(true);
+      });
+    });
+
+    describe('Token polling (RFC 8628 §3.5)', () => {
+      it('should answer authorization_pending before the user decides', async () => {
+        const body = await (await requestDeviceAuthorization()).json();
+        const res = await pollToken(body.device_code);
+
+        expect(res.status).toBe(400);
+        expect(res.headers.get('Cache-Control')).toBe('no-store');
+        expect(await res.json()).toEqual({
+          error: 'authorization_pending',
+          error_description: 'The authorization request is still pending',
+        });
+      });
+
+      it('should answer slow_down when polled again inside the interval', async () => {
+        const body = await (await requestDeviceAuthorization()).json();
+        await pollToken(body.device_code);
+        const res = await pollToken(body.device_code);
 
-      expect(
-        (metadata.grant_types_supported as string[]).includes(
-          'urn:ietf:params:oauth:grant-type:device_code',
-        ),
-      ).toBe(false);
+        expect(res.status).toBe(400);
+        expect(await res.json()).toEqual({
+          error: 'slow_down',
+          error_description: 'Polling too frequently. Increase the interval by 5 seconds.',
+        });
+      });
+
+      it('should reject a missing device_code with invalid_request', async () => {
+        const res = await app.request('/token', {
+          method: 'POST',
+          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
+          body: new URLSearchParams({
+            grant_type: DEVICE_GRANT_TYPE,
+            client_id: 'c-device',
+            client_secret: 's',
+          }).toString(),
+        });
+
+        expect(await res.json()).toEqual({
+          error: 'invalid_request',
+          error_description: 'Missing required parameter: device_code',
+        });
+      });
+
+      it('should reject an unknown device_code with invalid_grant', async () => {
+        const res = await pollToken('not-a-real-device-code');
+
+        expect(await res.json()).toEqual({
+          error: 'invalid_grant',
+          error_description: 'The device_code is invalid, expired, or was issued to another client',
+        });
+      });
+
+      it('should reject a device_code presented by another client with the same wording', async () => {
+        // RFC 8628 §3.4: the code belongs to the client it was issued to. The
+        // wording matches the unknown-code case so existence is not leaked.
+        const body = await (await requestDeviceAuthorization()).json();
+        const res = await app.request('/token', {
+          method: 'POST',
+          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
+          body: new URLSearchParams({
+            grant_type: DEVICE_GRANT_TYPE,
+            device_code: body.device_code,
+            client_id: 'c-device-other',
+            client_secret: 's',
+          }).toString(),
+        });
+
+        expect(await res.json()).toEqual({
+          error: 'invalid_grant',
+          error_description: 'The device_code is invalid, expired, or was issued to another client',
+        });
+      });
+
+      it('should reject a client that is not registered for the device grant', async () => {
+        const res = await app.request('/token', {
+          method: 'POST',
+          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
+          body: new URLSearchParams({
+            grant_type: DEVICE_GRANT_TYPE,
+            device_code: 'anything',
+            client_id: 'c-conf',
+            client_secret: 's',
+          }).toString(),
+        });
+
+        expect(await res.json()).toEqual({
+          error: 'unauthorized_client',
+          error_description: 'The client is not authorized to use the device_code grant',
+        });
+      });
+
+      it('should answer access_denied after the user denies', async () => {
+        const flow = await runDeviceFlow({}, 'deny');
+        const res = await pollToken(flow.device_code);
+
+        expect(await res.json()).toEqual({
+          error: 'access_denied',
+          error_description: 'The end-user denied the authorization request',
+        });
+      });
+    });
+
+    describe('Token issuance (RFC 8628 §3.5 → OIDC Core 1.0 §3.1.3.3)', () => {
+      it('should issue an access token and an ID Token after approval', async () => {
+        const flow = await runDeviceFlow();
+        const res = await pollToken(flow.device_code);
+        const body = await res.json();
+
+        expect(res.status).toBe(200);
+        expect(res.headers.get('Cache-Control')).toBe('no-store');
+        expect(body.token_type).toBe('Bearer');
+        expect(body.scope).toBe('openid');
+        expect(typeof body.access_token).toBe('string');
+        expect(typeof body.id_token).toBe('string');
+      });
+
+      it('should omit nonce and c_hash from the ID Token', async () => {
+        // RFC 8628 defines no nonce parameter, and there is no authorization code,
+        // so neither claim has a value to carry (OIDC Core 1.0 §2).
+        const flow = await runDeviceFlow();
+        const body = await (await pollToken(flow.device_code)).json();
+        const payload = idTokenPayload(body.id_token);
+
+        expect(payload.nonce).toBeUndefined();
+        expect(payload.c_hash).toBeUndefined();
+      });
+
+      it('should carry the auth_time recorded at approval', async () => {
+        const flow = await runDeviceFlow();
+        const body = await (await pollToken(flow.device_code)).json();
+        const payload = idTokenPayload(body.id_token);
+
+        expect(typeof payload.auth_time).toBe('number');
+        expect(payload.aud).toBe('c-device');
+      });
+
+      it('should let the issued access token reach the UserInfo endpoint', async () => {
+        const flow = await runDeviceFlow();
+        const body = await (await pollToken(flow.device_code)).json();
+        const res = await app.request('/userinfo', {
+          headers: { Authorization: 'Bearer ' + body.access_token },
+        });
+
+        expect(res.status).toBe(200);
+        expect((await res.json()).sub).toBe('testuser');
+      });
+
+      it('should refuse to redeem the same device_code twice', async () => {
+        const flow = await runDeviceFlow();
+        await pollToken(flow.device_code);
+        const res = await pollToken(flow.device_code);
+
+        expect(await res.json()).toEqual({
+          error: 'invalid_grant',
+          error_description: 'The device_code is invalid, expired, or was issued to another client',
+        });
+      });
+
+    it('should issue a refresh token when offline_access was approved', async () => {
+      // OIDC Core 1.0 §11: the approval screen IS the explicit consent, and
+      // c-device is registered for the refresh_token grant.
+      const flow = await runDeviceFlow({ scope: 'openid offline_access' });
+      const res = await pollToken(flow.device_code);
+      const body = await res.json();
+
+      expect(typeof body.refresh_token).toBe('string');
+    });
+    });
+
+    describe('ID Token signing key selection (OIDC Dynamic Client Registration 1.0 §4.2)', () => {
+      /** JOSE header of a compact JWS, decoded. */
+      function joseHeader(jwt: string): Record<string, unknown> {
+        const segment = jwt.split('.')[0] ?? '';
+        return JSON.parse(
+          new TextDecoder().decode(
+            Uint8Array.from(atob(segment.replace(/-/g, '+').replace(/_/g, '/')), (char) => char.charCodeAt(0)),
+          ),
+        );
+      }
+
+      // A client may register id_token_signed_response_alg, and the standard
+      // grants pick a registered key matching it. The device grant MUST NOT
+      // diverge: signing this client's ID Token with whichever key happens to be
+      // ACTIVE would hand it an RS256 token it rejects, and would compute at_hash
+      // with the wrong hash function (OIDC Core 1.0 Section 3.1.3.6).
+      it('should sign the device grant ID Token with the alg the client registered', async () => {
+        const rs256Pair = await crypto.subtle.generateKey(
+          { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
+          true,
+          ['sign', 'verify'],
+        );
+        const es256Pair = await crypto.subtle.generateKey(
+          { name: 'ECDSA', namedCurve: 'P-256' },
+          true,
+          ['sign', 'verify'],
+        );
+        const mixedProvider: SigningKeyProvider = {
+          // Active key is RS256; the registered set also holds an ES256 key.
+          async getSigningKey(): Promise<SigningKey> {
+            return {
+              privateKey: rs256Pair.privateKey,
+              publicJwk: await crypto.subtle.exportKey('jwk', rs256Pair.publicKey),
+              keyId: 'device-rs256',
+            };
+          },
+          async getSigningKeys(): Promise<SigningKey[]> {
+            return [
+              {
+                privateKey: rs256Pair.privateKey,
+                publicJwk: await crypto.subtle.exportKey('jwk', rs256Pair.publicKey),
+                keyId: 'device-rs256',
+              },
+              {
+                privateKey: es256Pair.privateKey,
+                publicJwk: await crypto.subtle.exportKey('jwk', es256Pair.publicKey),
+                keyId: 'device-es256',
+              },
+            ];
+          },
+        };
+        const mixedApp = createApp({
+          signingKeyProvider: mixedProvider,
+          clientResolver: createInMemoryClientResolver(testClients),
+        });
+        const client = { client_id: 'c-device-es256', client_secret: 's' };
+
+        const flow = await runDeviceFlow(client, 'approve', mixedApp);
+        const body = await (await pollToken(flow.device_code, client, mixedApp)).json();
+        const [encodedHeader = '', encodedPayload = '', encodedSignature = ''] =
+          (body.id_token as string).split('.');
+        const base64 = encodedSignature.replace(/-/g, '+').replace(/_/g, '/');
+        const padded = base64.padEnd(base64.length + ((4 - (base64.length % 4)) % 4), '=');
+        const signatureValid = await crypto.subtle.verify(
+          { name: 'ECDSA', hash: 'SHA-256' },
+          es256Pair.publicKey,
+          Uint8Array.from(atob(padded), (char) => char.charCodeAt(0)),
+          new TextEncoder().encode(encodedHeader + '.' + encodedPayload),
+        );
+
+        expect(joseHeader(body.id_token)).toEqual({
+          alg: 'ES256',
+          typ: 'JWT',
+          kid: 'device-es256',
+        });
+        expect(signatureValid).toBe(true);
+      });
+
+      it('should keep signing with RS256 for a client that registered no alg', async () => {
+        const flow = await runDeviceFlow();
+        const body = await (await pollToken(flow.device_code)).json();
+
+        expect(joseHeader(body.id_token)).toEqual({
+          alg: 'RS256',
+          typ: 'JWT',
+          kid: 'test-key',
+        });
+      });
     });
   });
 
diff --git a/with-device-authorization-grant/routes/device-authorization.ts b/with-device-authorization-grant/routes/device-authorization.ts
new file mode 100644
index 0000000..8074602
--- /dev/null
+++ b/with-device-authorization-grant/routes/device-authorization.ts
@@ -0,0 +1,187 @@
+/**
+ * EXPERIMENTAL — OAuth 2.0 Device Authorization Grant (RFC 8628).
+ *
+ * This route was generated because the OP was created with
+ * `--enable device-authorization-grant`. It is backed by
+ * @maronn-openid-connect/experimental, whose API is NOT stable: it may change in a breaking
+ * way between releases. Do not build production code on it without pinning the
+ * version.
+ *
+ * The device (a TV app, a CLI, an IoT box) POSTs here — back channel,
+ * client-authenticated — and receives a device_code it polls the token endpoint
+ * with, plus a short user_code the end user types into /device on another
+ * device's browser.
+ *
+ * NOTE (RFC 8628 §5.1): rate limiting the user_code guess surface is deliberately
+ * left to the deployment layer (reverse proxy / platform), not implemented here.
+ * An in-process counter cannot work on runtimes without shared memory between
+ * instances (Cloudflare Workers and friends), so putting one here would give a
+ * false sense of protection. The in-band defenses are the 20^8 user_code
+ * entropy, the short TTL, and answering every failed match identically.
+ */
+import { Hono } from 'hono';
+import {
+  DeviceAuthorizationError,
+  applyOfflineAccessPolicy,
+  buildDeviceAuthorizationResponse,
+  createDeviceAuthorizationRecord,
+  validateDeviceAuthorizationScope,
+  validateDeviceGrantAllowed,
+} from '@maronn-openid-connect/experimental/device-authorization-grant';
+import {
+  TokenError,
+  extractClientCredentials,
+  resolveAuthenticatedTokenClient,
+  sanitizeErrorDescription,
+  validateClientAuthMethod,
+  verifyClientSecret,
+} from '@maronn-openid-connect/core';
+import { tokenClientResolver as defaultTokenClientResolver } from '../resolvers.js';
+import { deviceAuthorizationStore as defaultDeviceAuthorizationStore } from '../store.js';
+
+/**
+ * EXPERIMENTAL — Device Authorization Grant settings (RFC 8628).
+ *
+ * Imported by the verification UI and the discovery route, so keep all three in
+ * sync when changing them.
+ *
+ * - deviceCodeExpiresIn: §3.2 expires_in, in seconds. Keep it short: it is the
+ *   window in which a user_code can be guessed (§5.1) or phished (§5.4).
+ * - pollInterval: §3.2 interval, in seconds. The token endpoint raises a
+ *   record's own interval by 5 every time it answers slow_down.
+ * - maxLoginAttempts: failed device logins allowed per record before it is
+ *   denied. Per-record only — see the security notes in the verification route.
+ *
+ * Not configurable: the user_code charset (RFC 8628 §6.1 base-20) and length (8).
+ * They carry the entropy claim, so they are constants in the experimental
+ * package rather than something a config typo can weaken.
+ */
+export const deviceAuthorizationConfig = {
+  deviceCodeExpiresIn: 600,
+  pollInterval: 5,
+  maxLoginAttempts: 5,
+};
+
+export const deviceAuthorizationApp = new Hono<{ Variables: Record<string, any> }>();
+
+/**
+ * RFC 8628 §3.1: the device authorization request body MUST be
+ * application/x-www-form-urlencoded (it follows RFC 6749 §3.2.1).
+ */
+function isFormUrlEncoded(contentType: string): boolean {
+  const [mediaType = ''] = contentType.toLowerCase().split(';');
+  return mediaType.trim() === 'application/x-www-form-urlencoded';
+}
+
+function noStore(c: any): void {
+  // RFC 8628 §3.2 has no explicit rule, but device_code is a credential, so the
+  // response follows the token response rules of RFC 6749 §5.1.
+  c.header('Cache-Control', 'no-store');
+  c.header('Pragma', 'no-cache');
+}
+
+/**
+ * Device Authorization Endpoint
+ * RFC 8628 §3.1 / §3.2
+ */
+deviceAuthorizationApp.post('/', async (c) => {
+  const contentType = c.req.header('Content-Type') ?? '';
+  if (!isFormUrlEncoded(contentType)) {
+    noStore(c);
+    return c.json({ error: 'invalid_request', error_description: 'Device authorization requests must use application/x-www-form-urlencoded' }, 400);
+  }
+
+  // RFC 6749 §3.1: request parameters MUST NOT be repeated. Read the raw body so
+  // URLSearchParams iteration exposes duplicates instead of silently keeping the last.
+  const rawBody = await c.req.text();
+  const params: Record<string, string> = {};
+  const seen = new Set<string>();
+  let duplicateKey: string | undefined;
+  for (const [key, value] of new URLSearchParams(rawBody)) {
+    if (seen.has(key)) {
+      duplicateKey = key;
+      break;
+    }
+    seen.add(key);
+    params[key] = value;
+  }
+
+  if (duplicateKey !== undefined) {
+    noStore(c);
+    return c.json({ error: 'invalid_request', error_description: `Parameter "${sanitizeErrorDescription(duplicateKey)}" must not be repeated` }, 400);
+  }
+
+  const authorization = c.req.header('Authorization') ?? '';
+
+  try {
+    const tokenClientResolver = c.get('tokenClientResolver') ?? defaultTokenClientResolver;
+    const deviceStore = c.get('deviceAuthorizationStore') ?? defaultDeviceAuthorizationStore;
+    const config = c.get('config');
+
+    // --- Client authentication pipeline -------------------------------------
+    // RFC 8628 §3.1: "The client authentication requirements of Section 3.2.1 of
+    // [RFC6749] apply" — so this is the same pipeline the token endpoint runs,
+    // step function for step function. Public clients present only client_id.
+    const presentedCredentials = extractClientCredentials({
+      params,
+      authorizationHeader: authorization,
+    });
+    const client = await resolveAuthenticatedTokenClient(
+      presentedCredentials.clientId,
+      tokenClientResolver,
+    );
+    validateClientAuthMethod(client, presentedCredentials);
+    await verifyClientSecret(client, presentedCredentials.clientSecret);
+
+    // --- Device authorization pipeline --------------------------------------
+    // Each step below is an independent function from
+    // @maronn-openid-connect/experimental/device-authorization-grant, called in RFC 8628 §3.1
+    // order. Delete a call to drop that validation, or insert your own logic
+    // between steps.
+
+    // RFC 6749 §5.2: the client must be registered for the device_code grant.
+    validateDeviceGrantAllowed(client);
+
+    // RFC 8628 §3.1 leaves scope OPTIONAL, but this OP requires scope and openid
+    // everywhere (same rule as /authorize). Requests that omit scope — legal per
+    // RFC 8628 — are therefore rejected: a known, deliberate profile restriction.
+    const requestedScope = validateDeviceAuthorizationScope(params['scope']);
+
+    // OIDC Core 1.0 §11: drop offline_access when it could never be granted.
+    const scope = applyOfflineAccessPolicy(requestedScope, {
+      client,
+      refreshTokenFeatureEnabled: true,
+    });
+
+    // RFC 8628 §3.2 / §5.2: mint a 256-bit device_code and a collision-checked
+    // base-20 user_code, then store the pending record under both.
+    const record = await createDeviceAuthorizationRecord({
+      clientId: client.clientId,
+      scope,
+      store: deviceStore,
+      expiresIn: deviceAuthorizationConfig.deviceCodeExpiresIn,
+      interval: deviceAuthorizationConfig.pollInterval,
+    });
+
+    // Never log device_code or user_code: both are live credentials for the
+    // lifetime of the record (RFC 8628 §5.1 / §5.2).
+
+    noStore(c);
+    return c.json(buildDeviceAuthorizationResponse(record, config.issuer));
+  } catch (error) {
+    noStore(c);
+    if (error instanceof DeviceAuthorizationError) {
+      // RFC 6749 §5.2 error shape. Authentication failures never reach here —
+      // they are core TokenErrors, handled below with their 401.
+      return c.json({ error: error.code, error_description: error.errorDescription }, error.statusCode);
+    }
+    if (error instanceof TokenError) {
+      const status = error.statusCode as 400 | 401;
+      if (error.wwwAuthenticate) {
+        c.header('WWW-Authenticate', error.wwwAuthenticate);
+      }
+      return c.json({ error: error.error, error_description: error.errorDescription }, status);
+    }
+    return c.json({ error: 'server_error' }, 500);
+  }
+});
diff --git a/with-device-authorization-grant/routes/device.ts b/with-device-authorization-grant/routes/device.ts
new file mode 100644
index 0000000..ed758bf
--- /dev/null
+++ b/with-device-authorization-grant/routes/device.ts
@@ -0,0 +1,325 @@
+/**
+ * EXPERIMENTAL — OAuth 2.0 Device Authorization Grant, verification UI
+ * (RFC 8628 §3.3).
+ *
+ * This route was generated because the OP was created with
+ * `--enable device-authorization-grant`. It is backed by
+ * @maronn-openid-connect/experimental, whose API is NOT stable: it may change in a breaking
+ * way between releases. Do not build production code on it without pinning the
+ * version.
+ *
+ * The end user opens /device on a second device, types the user_code the first
+ * device is showing, signs in, and approves or denies. The device learns the
+ * outcome only by polling the token endpoint — there is no push channel.
+ *
+ * ## Why every POST here demands a binding cookie
+ *
+ * The user_code is known to whoever started the flow, and that party can be the
+ * attacker. A CSRF token stored on the record is therefore not a defense: the
+ * attacker can fetch a valid one by POSTing /device with their own code. What
+ * stops both consent coercion (a forged /device/approve that ships the victim's
+ * tokens to the attacker's device) and login CSRF (a forged /device/login that
+ * plants the attacker's session in the victim's browser) is the binding cookie
+ * minted below — see buildDeviceBindingCookie() in store.ts for the full model.
+ * The hidden csrf_token is kept as defense in depth, never as the only check.
+ */
+import { Hono } from 'hono';
+import {
+  DeviceAuthorizationError,
+  DeviceVerificationError,
+  INVALID_USER_CODE_MESSAGE,
+  approveDeviceAuthorization,
+  denyDeviceAuthorization,
+  findPendingRecordByUserCode,
+  issueVerificationBinding,
+  recordDeviceLoginFailure,
+  validateVerificationBinding,
+  validateVerificationCsrfToken,
+  type DeviceAuthorizationRecord,
+} from '@maronn-openid-connect/experimental/device-authorization-grant';
+import { generateRandomString } from '@maronn-openid-connect/core';
+import {
+  browserSessionStore as defaultBrowserSessionStore,
+  buildClearedDeviceBindingCookie,
+  buildDeviceBindingCookie,
+  buildSessionCookie,
+  parseDeviceBindingSecret,
+  parseSessionId,
+  userStore,
+} from '../store.js';
+import { defaultViews, renderView } from '../views.js';
+import { deviceAuthorizationConfig } from './device-authorization.js';
+
+export const deviceApp = new Hono<{ Variables: Record<string, any> }>();
+
+/**
+ * Attach a Set-Cookie to a Response a view already produced.
+ *
+ * renderView() builds its own Response, so headers staged on the framework
+ * context never reach it. Rebuilding the Response is the framework-neutral way
+ * to add the cookie without making views cookie-aware.
+ */
+function withCookie(response: Response, cookie: string): Response {
+  const headers = new Headers(response.headers);
+  headers.append('Set-Cookie', cookie);
+  return new Response(response.body, {
+    status: response.status,
+    statusText: response.statusText,
+    headers,
+  });
+}
+
+/**
+ * Remaining lifetime of a record, in whole seconds, never negative.
+ *
+ * Rounded up so the cookie always outlives the record it binds: a cookie that
+ * expired first would turn a still-valid verification into an unexplained 403.
+ */
+function remainingTtlSeconds(record: DeviceAuthorizationRecord): number {
+  return Math.max(0, Math.ceil((record.expiresAt.getTime() - Date.now()) / 1000));
+}
+
+/**
+ * Re-render the code entry form with the single, reason-free failure message.
+ *
+ * RFC 8628 §5.1: unknown, expired and already-used codes must be
+ * indistinguishable, otherwise the response itself confirms which codes exist.
+ */
+function renderInvalidUserCode(views: typeof defaultViews, userCode: string): Response {
+  return renderView(
+    views.deviceVerificationPage({ userCode, error: INVALID_USER_CODE_MESSAGE }),
+    { status: 400 },
+  );
+}
+
+/** Map a verification failure to its error page; anything else is re-thrown. */
+function renderVerificationError(views: typeof defaultViews, error: unknown): Response {
+  if (error instanceof DeviceVerificationError) {
+    return renderView(
+      views.errorPage({ error: error.message, statusCode: error.statusCode }),
+      { status: error.statusCode },
+    );
+  }
+  if (error instanceof DeviceAuthorizationError) {
+    return renderView(
+      views.errorPage({ error: error.errorDescription, statusCode: 400 }),
+      { status: 400 },
+    );
+  }
+  throw error;
+}
+
+/**
+ * User code entry form - GET
+ * RFC 8628 §3.3 / §3.3.1
+ *
+ * Unauthenticated and side-effect free. A user_code in the query string
+ * (verification_uri_complete) only pre-fills the field: nothing is looked up or
+ * mutated until the form is submitted, so following the complete URI never
+ * consumes or reveals anything.
+ */
+deviceApp.get('/', (c) => {
+  const views = c.get('views') ?? defaultViews;
+  return renderView(views.deviceVerificationPage({ userCode: c.req.query('user_code') ?? '' }));
+});
+
+/**
+ * User code submission - POST
+ * RFC 8628 §3.3
+ *
+ * On a match this is where the browser binding is minted, so this is also the
+ * first response that may carry a csrf_token. Everything downstream requires the
+ * cookie this response sets.
+ */
+deviceApp.post('/', async (c) => {
+  const body = await c.req.parseBody();
+  const submittedUserCode = String(body['user_code'] ?? '');
+
+  const views = c.get('views') ?? defaultViews;
+  const deviceStore = c.get('deviceAuthorizationStore');
+  const browserSessionStore = c.get('browserSessionStore') ?? defaultBrowserSessionStore;
+
+  const record = await findPendingRecordByUserCode(submittedUserCode, deviceStore);
+  if (!record) {
+    return renderInvalidUserCode(views, submittedUserCode);
+  }
+
+  // Rotate the binding secret and the csrf token together. A second browser
+  // submitting the same user_code takes the binding over (last writer wins);
+  // that is inherent to a flow whose identifier is shareable by design.
+  const { bindingSecret, csrfToken } = await issueVerificationBinding(record, deviceStore);
+  const cookie = buildDeviceBindingCookie(
+    record.userCode,
+    bindingSecret,
+    remainingTtlSeconds(record),
+  );
+
+  const sessionId = parseSessionId(c.req.header('Cookie') ?? null);
+  const session = sessionId ? await browserSessionStore.get(sessionId) : undefined;
+  if (session) {
+    return withCookie(renderView(views.deviceApprovalPage({
+      userCode: record.userCodeDisplay,
+      csrfToken,
+      clientId: record.clientId,
+      scopes: record.scope,
+    })), cookie);
+  }
+
+  return withCookie(renderView(views.deviceLoginPage({
+    userCode: record.userCodeDisplay,
+    csrfToken,
+  })), cookie);
+});
+
+/**
+ * Device login - POST
+ * RFC 8628 §3.3
+ *
+ * Binding first, then CSRF, then credentials: the binding is what proves this is
+ * the browser that submitted the user_code, and it must gate the step that would
+ * otherwise let a forged POST establish an OP session in the victim's browser.
+ */
+deviceApp.post('/login', async (c) => {
+  const body = await c.req.parseBody();
+  const submittedUserCode = String(body['user_code'] ?? '');
+  const csrfToken = String(body['csrf_token'] ?? '');
+  const username = String(body['username'] ?? '');
+  const password = String(body['password'] ?? '');
+
+  const views = c.get('views') ?? defaultViews;
+  const deviceStore = c.get('deviceAuthorizationStore');
+  const browserSessionStore = c.get('browserSessionStore') ?? defaultBrowserSessionStore;
+  const authenticateUser =
+    c.get('authenticateUser') ??
+    ((u: string, p: string) => userStore.authenticate(u, p));
+
+  const record = await findPendingRecordByUserCode(submittedUserCode, deviceStore);
+  if (!record) {
+    return renderInvalidUserCode(views, submittedUserCode);
+  }
+
+  try {
+    await validateVerificationBinding(
+      record,
+      parseDeviceBindingSecret(c.req.header('Cookie') ?? null, record.userCode),
+    );
+    validateVerificationCsrfToken(record, csrfToken);
+  } catch (error) {
+    return renderVerificationError(views, error);
+  }
+
+  // Swap point: replace this with your own credential check (LDAP, WebAuthn, an
+  // upstream IdP) without touching anything above or below it.
+  const user = await authenticateUser(username, password);
+  if (!user) {
+    // Per-record throttling only. An attacker holding a device-grant client can
+    // mint unlimited records, so the aggregate password-guess budget is the same
+    // as the one on /login. Subject-scoped throttling is a separate concern.
+    const failure = await recordDeviceLoginFailure(
+      record,
+      deviceStore,
+      deviceAuthorizationConfig.maxLoginAttempts,
+    );
+    if (!failure.canRetry) {
+      // The record is now denied: the device gets access_denied on its next poll.
+      return renderView(views.errorPage({
+        error: 'Too many login attempts',
+        statusCode: 429,
+      }), { status: 429 });
+    }
+    return renderView(views.deviceLoginPage({
+      userCode: record.userCodeDisplay,
+      csrfToken,
+      error: 'Invalid credentials',
+      remainingAttempts: failure.remainingAttempts,
+    }));
+  }
+
+  const authTime = Math.floor(Date.now() / 1000);
+  const sessionId = generateRandomString(32);
+  await browserSessionStore.set(sessionId, { subject: user.sub, authTime });
+
+  // Two cookies on one response: the new OP session, and the binding cookie the
+  // approval POST will have to present again.
+  const withSession = withCookie(renderView(views.deviceApprovalPage({
+    userCode: record.userCodeDisplay,
+    csrfToken,
+    clientId: record.clientId,
+    scopes: record.scope,
+  })), buildSessionCookie(sessionId));
+  return withSession;
+});
+
+/**
+ * Approve or deny - POST
+ * RFC 8628 §3.3
+ *
+ * The only state-changing step of the UI, so it demands all three: an OP
+ * session, the binding cookie, and the csrf_token.
+ */
+deviceApp.post('/approve', async (c) => {
+  const body = await c.req.parseBody();
+  const submittedUserCode = String(body['user_code'] ?? '');
+  const csrfToken = String(body['csrf_token'] ?? '');
+  const decision = String(body['decision'] ?? '');
+
+  const views = c.get('views') ?? defaultViews;
+  const deviceStore = c.get('deviceAuthorizationStore');
+  const browserSessionStore = c.get('browserSessionStore') ?? defaultBrowserSessionStore;
+  const consentResolver = c.get('consentResolver');
+
+  const record = await findPendingRecordByUserCode(submittedUserCode, deviceStore);
+  if (!record) {
+    return renderInvalidUserCode(views, submittedUserCode);
+  }
+
+  const sessionId = parseSessionId(c.req.header('Cookie') ?? null);
+  const session = sessionId ? await browserSessionStore.get(sessionId) : undefined;
+  if (!session) {
+    return renderView(views.errorPage({
+      error: 'Sign in again to approve this device',
+      statusCode: 401,
+    }), { status: 401 });
+  }
+
+  const clearCookie = buildClearedDeviceBindingCookie(record.userCode);
+  try {
+    await validateVerificationBinding(
+      record,
+      parseDeviceBindingSecret(c.req.header('Cookie') ?? null, record.userCode),
+    );
+
+    if (decision === 'approve') {
+      // csrf_token is validated inside; the record moves to approved with the
+      // subject, auth_time, scope and a fresh grantId the token endpoint reads.
+      const approved = await approveDeviceAuthorization({
+        record,
+        store: deviceStore,
+        csrfToken,
+        subject: session.subject,
+        authTime: session.authTime,
+      });
+      // Record the consent the same way /consent does, so a later Authorization
+      // Code Flow for this client skips the consent screen (OIDC Core 1.0 §3.1.2.4).
+      await consentResolver?.recordConsent?.(
+        approved.subject,
+        approved.clientId,
+        approved.approvedScope ?? approved.scope,
+      );
+      await consentResolver?.recordGrant?.(approved.subject, approved.clientId, approved.grantId);
+      return withCookie(renderView(views.deviceCompletedPage({
+        approved: true,
+        clientId: approved.clientId,
+      })), clearCookie);
+    }
+
+    await denyDeviceAuthorization({ record, store: deviceStore, csrfToken });
+    return withCookie(renderView(views.deviceCompletedPage({
+      approved: false,
+      clientId: record.clientId,
+    })), clearCookie);
+  } catch (error) {
+    return renderVerificationError(views, error);
+  }
+});
diff --git a/default-op/routes/discovery.ts b/with-device-authorization-grant/routes/discovery.ts
index 72c0758..ebca2c5 100644
--- a/default-op/routes/discovery.ts
+++ b/with-device-authorization-grant/routes/discovery.ts
@@ -92,7 +92,7 @@ discoveryApp.get('/', (c) => {
       'phone_number',
       'phone_number_verified',
     ],
-    grantTypesSupported: ['authorization_code', 'refresh_token'],
+    grantTypesSupported: ['authorization_code', 'refresh_token', 'urn:ietf:params:oauth:grant-type:device_code'],
     // RFC 6749 §2.1 / OAuth 2.1 §2.4: 'none' advertises that public clients
     // (no client_secret) are accepted at the token endpoint.
     tokenEndpointAuthMethodsSupported: [
@@ -144,5 +144,7 @@ discoveryApp.get('/', (c) => {
   return c.json({
     ...metadata,
     code_challenge_methods_supported: ['S256'],
+    // EXPERIMENTAL — RFC 8628 §4 metadata.
+    device_authorization_endpoint: `${issuer}/device_authorization`,
   });
 });
diff --git a/default-op/routes/token.ts b/with-device-authorization-grant/routes/token.ts
index 32a3f45..4d70d5f 100644
--- a/default-op/routes/token.ts
+++ b/with-device-authorization-grant/routes/token.ts
@@ -53,6 +53,12 @@ import {
   refreshTokenStore as defaultRefreshTokenStore,
 } from '../store.js';
 import type { RegisteredClient } from '../config.js';
+import {
+  DEVICE_CODE_GRANT_TYPE,
+  DeviceAuthorizationError,
+  processDeviceCodeGrant,
+} from '@maronn-openid-connect/experimental/device-authorization-grant';
+import { deviceAuthorizationStore as defaultDeviceAuthorizationStore } from '../store.js';
 
 export const tokenApp = new Hono<{ Variables: Record<string, any> }>();
 
@@ -171,6 +177,194 @@ tokenApp.post('/', async (c) => {
 
     const authenticatedClientId = presentedCredentials.clientId;
 
+    // --- EXPERIMENTAL: OAuth 2.0 Device Authorization Grant (RFC 8628 §3.4) ---
+    // Dispatched right after client authentication and BEFORE core's
+    // validateGrantTypeSupported, which does not know the URN and would reject it
+    // with unsupported_grant_type. The branch answers the request itself and
+    // never falls through to the standard grants.
+    //
+    // Backed by @maronn-openid-connect/experimental, whose API is NOT stable: it may change
+    // in a breaking way between releases. Do not build production code on it
+    // without pinning the version.
+    if (params.grant_type === DEVICE_CODE_GRANT_TYPE) {
+      const deviceStore = c.get('deviceAuthorizationStore') ?? defaultDeviceAuthorizationStore;
+
+      // RFC 8628 §3.5 state machine. Everything except "approved" throws:
+      // authorization_pending / slow_down / access_denied / expired_token, plus
+      // invalid_request / invalid_grant / unauthorized_client from §3.4.
+      const deviceGrant = await processDeviceCodeGrant({
+        params,
+        client: tokenClient,
+        store: deviceStore,
+      });
+
+      // config / privateKey / keyId are bound further down for the standard
+      // grants. This branch reads them on its own so the generated output is
+      // unchanged when the feature is off; it returns, so nothing runs twice.
+      const deviceConfig = c.get('config');
+      const devicePrivateKey = c.get('privateKey');
+      const deviceKeyId = c.get('keyId');
+      // T-022: the ID Token this grant issues follows the SAME key-selection rule
+      // as the standard grants — pick a registered ID Token key whose alg matches
+      // the client's id_token_signed_response_alg (OIDC Dynamic Client
+      // Registration 1.0 §2), not the general-purpose ACTIVE key. Using the
+      // active key would hand an ES256-registered client an RS256 ID Token, which
+      // it rejects, and would hash at_hash with the wrong algorithm.
+      const deviceIdTokenSigningKeys = (c.get('idTokenSigningKeys') as SigningKey[] | undefined) ?? [];
+      const deviceFallbackIdKey: SigningKey | undefined =
+        c.get('idTokenPrivateKey') !== undefined
+          ? {
+              privateKey: c.get('idTokenPrivateKey'),
+              publicJwk: c.get('idTokenPublicJwk'),
+              keyId: c.get('idTokenKeyId') ?? deviceKeyId,
+            }
+          : undefined;
+      const deviceRegisteredClient = (await tokenClientResolver.findClient(
+        authenticatedClientId,
+      )) as RegisteredClient | null;
+      const deviceRequestedIdTokenAlg = deviceRegisteredClient?.idTokenSignedResponseAlg;
+      let deviceSelectedIdTokenKey: SigningKey;
+      if (deviceIdTokenSigningKeys.length > 0) {
+        try {
+          deviceSelectedIdTokenKey = selectSigningKeyByAlg(deviceIdTokenSigningKeys, deviceRequestedIdTokenAlg);
+        } catch {
+          c.header('Cache-Control', 'no-store');
+          c.header('Pragma', 'no-cache');
+          return c.json(
+            {
+              error: 'server_error',
+              error_description: `No ID Token signing key registered for alg "${deviceRequestedIdTokenAlg ?? 'RS256'}"`,
+            },
+            500,
+          );
+        }
+      } else if (deviceFallbackIdKey) {
+        deviceSelectedIdTokenKey = deviceFallbackIdKey;
+      } else {
+        c.header('Cache-Control', 'no-store');
+        c.header('Pragma', 'no-cache');
+        return c.json({ error: 'server_error', error_description: 'No ID Token signing key registered' }, 500);
+      }
+      const deviceIdTokenPrivateKey = deviceSelectedIdTokenKey.privateKey;
+      const deviceIdTokenKeyId = deviceSelectedIdTokenKey.keyId;
+      const deviceIssuer: AccessTokenIssuer =
+        deviceConfig.accessTokenFormat === 'opaque'
+          ? createOpaqueAccessTokenIssuer()
+          : createJwtAccessTokenIssuer();
+
+      // Same aud policy as the standard token route: the UserInfo endpoint stays
+      // a permanent member (RFC 9068 §3). RFC 8628 has no resource parameter, so
+      // nothing else is requested.
+      const deviceAudience = buildAccessTokenAudience({
+        userInfoEndpoint: `${deviceConfig.issuer}/userinfo`,
+        issuer: deviceConfig.issuer,
+      });
+
+      const deviceIssuedAt = Math.floor(Date.now() / 1000);
+      const deviceAccessTokenPayload = buildAccessTokenPayload({
+        issuer: deviceConfig.issuer,
+        subject: deviceGrant.subject,
+        clientId: deviceGrant.clientId,
+        scope: deviceGrant.scope,
+        audience: deviceAudience,
+        expiresIn: deviceConfig.accessTokenExpiresIn,
+        issuedAt: deviceIssuedAt,
+      });
+      const deviceAccessToken = await deviceIssuer.issue({
+        payload: deviceAccessTokenPayload,
+        privateKey: devicePrivateKey,
+        keyId: deviceKeyId,
+      });
+
+      // The device authorization endpoint requires the openid scope, so an ID
+      // Token is always issued. It carries no nonce (RFC 8628 defines no such
+      // parameter, and OIDC Core 1.0 §2 only requires nonce when the
+      // authentication request carried one) and no c_hash (there is no code).
+      const deviceAtHash = await computeAtHash(deviceAccessToken, deviceIdTokenPrivateKey);
+      const deviceAcrResolver = c.get('acrResolver') as AcrResolver | undefined;
+      const { acr: deviceAcr, amr: deviceAmr } = await resolveAcrAmr({
+        subject: deviceGrant.subject,
+        clientId: deviceGrant.clientId,
+        acrResolver: deviceAcrResolver,
+      });
+      const deviceIdTokenPayload = buildIdTokenPayload({
+        issuer: deviceConfig.issuer,
+        subject: deviceGrant.subject,
+        clientId: deviceGrant.clientId,
+        scope: deviceGrant.scope,
+        expiresIn: deviceConfig.idTokenExpiresIn,
+        issuedAt: deviceIssuedAt,
+        atHash: deviceAtHash,
+        authTime: deviceGrant.authTime,
+        acr: deviceAcr,
+        amr: deviceAmr,
+      });
+      const deviceIdToken = await generateIdToken({
+        payload: deviceIdTokenPayload,
+        privateKey: deviceIdTokenPrivateKey,
+        keyId: deviceIdTokenKeyId,
+      });
+
+      await accessTokenStore.set(deviceAccessToken, {
+        sub: deviceGrant.subject,
+        clientId: deviceGrant.clientId,
+        scope: deviceGrant.scope,
+        expiresAt: deviceIssuedAt + deviceConfig.accessTokenExpiresIn,
+        // Inherit the grantId minted at approval so revoking the grant kills
+        // every token issued from this device authorization.
+        grantId: deviceGrant.grantId,
+        iat: deviceIssuedAt,
+        nbf: deviceIssuedAt,
+        audience: deviceAudience,
+        issuer: deviceConfig.issuer,
+        jti: deviceAccessTokenPayload.jti,
+      });
+
+      // OIDC Core 1.0 §11: offline_access survived the device authorization
+      // endpoint's policy check only if this client may hold refresh tokens, and
+      // the approval screen the user just went through IS the explicit consent
+      // that §11 asks for. Nothing further to gate on here.
+      const deviceRefreshToken = deviceGrant.scope.includes('offline_access')
+        ? generateRandomString(32)
+        : undefined;
+      if (deviceRefreshToken) {
+        const deviceRefreshTokenStore = c.get('refreshTokenStore') ?? defaultRefreshTokenStore;
+        await deviceRefreshTokenStore.set(deviceRefreshToken, {
+          subject: deviceGrant.subject,
+          clientId: deviceGrant.clientId,
+          scope: deviceGrant.scope,
+          // OAuth 2.1 §6.1: absolute lifetime from initial issuance; rotations
+          // inherit originalIssuedAt so the deadline never slides forward.
+          expiresAt: deviceIssuedAt + deviceConfig.refreshTokenAbsoluteLifetime,
+          originalIssuedAt: deviceIssuedAt,
+          used: false,
+          grantId: deviceGrant.grantId,
+          iat: deviceIssuedAt,
+          issuer: deviceConfig.issuer,
+          audience: deviceAudience,
+          authTime: deviceGrant.authTime,
+          // RFC 8628 has no nonce parameter, so the re-issued ID Token has none
+          // to preserve either.
+          nonce: undefined,
+          acr: deviceAcr,
+          amr: deviceAmr,
+          azp: undefined,
+        });
+      }
+
+      // RFC 6749 §5.1: token responses MUST NOT be cached.
+      c.header('Cache-Control', 'no-store');
+      c.header('Pragma', 'no-cache');
+      return c.json({
+        access_token: deviceAccessToken,
+        token_type: 'Bearer' as const,
+        expires_in: deviceConfig.accessTokenExpiresIn,
+        id_token: deviceIdToken,
+        scope: deviceGrant.scope.join(' '),
+        refresh_token: deviceRefreshToken,
+      });
+    }
+
     // --- Token request validation pipeline --------------------------------
     // Each step below is an independent core function, called in the same order
     // as core's validateTokenRequest(). Delete a call to drop that validation,
@@ -591,6 +785,18 @@ tokenApp.post('/', async (c) => {
     c.header('Pragma', 'no-cache');
     return c.json(tokenResponse);
   } catch (error) {
+    if (error instanceof DeviceAuthorizationError) {
+      // RFC 8628 §3.5: authorization_pending / slow_down / access_denied /
+      // expired_token use the RFC 6749 §5.2 shape and are always 400. A 401 can
+      // only come from client authentication, which runs before the branch and
+      // throws core's TokenError.
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
diff --git a/default-op/store.ts b/with-device-authorization-grant/store.ts
index e530896..7412bab 100644
--- a/default-op/store.ts
+++ b/with-device-authorization-grant/store.ts
@@ -6,6 +6,10 @@ import type {
   RefreshTokenInfo,
   UserClaims,
 } from '@maronn-openid-connect/core';
+import type {
+  DeviceAuthorizationRecord,
+  DeviceAuthorizationStore,
+} from '@maronn-openid-connect/experimental/device-authorization-grant';
 
 /**
  * In-memory Authorization Transaction Store.
@@ -823,3 +827,163 @@ export const authSessionStore = defaultProviderStores.authSessionStore;
 export const browserSessionStore = defaultProviderStores.browserSessionStore;
 export const consentStore = defaultProviderStores.consentStore;
 export const userStore = defaultProviderStores.userStore;
+
+/**
+ * EXPERIMENTAL — device verification binding cookie (RFC 8628 §5.4 / §3.3).
+ *
+ * Why this exists: the user_code is, by design, known to whoever started the
+ * device flow — and that party can be the attacker. A CSRF token that hangs off
+ * the record is therefore worthless on its own: the attacker POSTs /device with
+ * their own code, reads the token, and can then forge `POST /device/approve`
+ * (consent coercion: the victim's tokens land on the attacker's device) or
+ * `POST /device/login` (login CSRF: the victim's browser gets the attacker's
+ * OP session). Neither is stopped by keeping the token secret.
+ *
+ * The binding is what stops them. On a successful user_code match the OP mints a
+ * bindingSecret, hands the raw value to that one browser in an HttpOnly cookie,
+ * and stores only its SHA-256 hash on the record. /device/login and
+ * /device/approve refuse to run unless the presented cookie hashes to the stored
+ * value, so a forged cross-site POST — which cannot carry the victim's cookie
+ * (SameSite=Lax), and whose victim never held this record's cookie anyway — is
+ * rejected without relying on any secret staying secret.
+ *
+ * Unlike the optional transaction-binding feature this is ALWAYS on: for the
+ * authorize flow the transaction_id is normally confidential, so binding is
+ * extra hardening, while here the identifier is public to the attacker by
+ * construction. The cost is that driving the verification UI by hand with curl
+ * needs a cookie jar (-c / -b).
+ *
+ * The cookie name embeds the normalized user_code so two device flows can run in
+ * the same browser without overwriting each other's secret.
+ */
+export const DEVICE_BINDING_COOKIE_PREFIX = 'oidc_device_';
+
+/**
+ * Build the Set-Cookie value binding one device verification to this browser.
+ * Same attributes as the session cookie: HttpOnly (no JS access), Secure (HTTPS
+ * only; http://localhost is treated as trustworthy by browsers) and
+ * SameSite=Lax. Max-Age matches the remaining record TTL so an abandoned
+ * verification does not leave a cookie behind.
+ */
+export function buildDeviceBindingCookie(
+  userCode: string,
+  bindingSecret: string,
+  ttlSeconds: number,
+): string {
+  return (
+    DEVICE_BINDING_COOKIE_PREFIX + userCode + '=' + bindingSecret +
+    '; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=' + String(ttlSeconds)
+  );
+}
+
+/**
+ * Build the Set-Cookie value that clears the binding cookie once the user has
+ * approved or denied, so the browser does not accumulate one cookie per flow.
+ */
+export function buildClearedDeviceBindingCookie(userCode: string): string {
+  return (
+    DEVICE_BINDING_COOKIE_PREFIX + userCode +
+    '=; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=0'
+  );
+}
+
+/**
+ * Extract the binding secret for one device verification from a Cookie header.
+ * Returns null when the header is missing or this record's cookie is absent,
+ * which validateVerificationBinding() rejects with 403.
+ */
+export function parseDeviceBindingSecret(
+  cookieHeader: string | null,
+  userCode: string,
+): string | null {
+  if (!cookieHeader) return null;
+  const name = DEVICE_BINDING_COOKIE_PREFIX + userCode;
+  for (const part of cookieHeader.split(';')) {
+    const trimmed = part.trim();
+    const eq = trimmed.indexOf('=');
+    if (eq === -1) continue;
+    if (trimmed.slice(0, eq) === name) {
+      return trimmed.slice(eq + 1);
+    }
+  }
+  return null;
+}
+
+/**
+ * EXPERIMENTAL — in-memory device authorization store (RFC 8628).
+ *
+ * Replace with a persistent store (Redis, KV, database) in production. Treat
+ * deviceCode and userCode as opaque external values: never interpolate them into
+ * a query, always bind them as parameters.
+ *
+ * - save / update: persist the record, ideally with a TTL derived from
+ *   record.expiresAt so entries cannot pile up.
+ * - consume(deviceCode): fetch AND delete in one atomic operation. A non-atomic
+ *   implementation lets the same device_code be redeemed concurrently.
+ * - Expired records whose device stopped polling are never reclaimed by the
+ *   token endpoint. A persistent implementation MAY drop them on its own after a
+ *   grace period (roughly one TTL); polling after that answers invalid_grant
+ *   instead of expired_token, which ends the client's flow just the same.
+ */
+export class InMemoryDeviceAuthorizationStore implements DeviceAuthorizationStore {
+  private records = new Map<string, DeviceAuthorizationRecord>();
+
+  async save(record: DeviceAuthorizationRecord): Promise<void> {
+    this.evictExpired();
+    this.records.set(record.deviceCode, record);
+  }
+
+  async findByDeviceCode(deviceCode: string): Promise<DeviceAuthorizationRecord | null> {
+    return this.records.get(deviceCode) ?? null;
+  }
+
+  async findByUserCode(userCode: string): Promise<DeviceAuthorizationRecord | null> {
+    for (const record of this.records.values()) {
+      if (record.userCode === userCode) return record;
+    }
+    return null;
+  }
+
+  async update(record: DeviceAuthorizationRecord): Promise<void> {
+    this.records.set(record.deviceCode, record);
+  }
+
+  async delete(deviceCode: string): Promise<void> {
+    this.records.delete(deviceCode);
+  }
+
+  async consume(deviceCode: string): Promise<DeviceAuthorizationRecord | null> {
+    const record = this.records.get(deviceCode) ?? null;
+    // Single use (RFC 8628 §3.5): delete on read so a replay of the same
+    // device_code can never mint a second token.
+    this.records.delete(deviceCode);
+    return record;
+  }
+
+  /**
+   * Drop records whose lifetime passed long enough ago that no device is still
+   * polling them, so an idle store cannot grow unbounded. The grace period keeps
+   * expired_token answerable for one more TTL after expiry.
+   */
+  private evictExpired(): void {
+    const cutoff = Date.now() - DEVICE_RECORD_EVICTION_GRACE_MS;
+    for (const [deviceCode, record] of this.records) {
+      if (record.expiresAt.getTime() < cutoff) {
+        this.records.delete(deviceCode);
+      }
+    }
+  }
+}
+
+/** Grace period before an expired record is reclaimed (one default TTL). */
+const DEVICE_RECORD_EVICTION_GRACE_MS = 600 * 1000;
+
+// Kept on globalThis for the same reason as the provider stores above: Next.js
+// instantiates route handlers and server actions in separate module layers.
+const deviceStoreRegistry = globalThis as typeof globalThis & {
+  __oidcDeviceAuthorizationStore?: DeviceAuthorizationStore;
+};
+
+export const deviceAuthorizationStore: DeviceAuthorizationStore =
+  (deviceStoreRegistry.__oidcDeviceAuthorizationStore ??=
+    new InMemoryDeviceAuthorizationStore());
diff --git a/default-op/views.ts b/with-device-authorization-grant/views.ts
index b084077..6dc42f5 100644
--- a/default-op/views.ts
+++ b/with-device-authorization-grant/views.ts
@@ -52,6 +52,55 @@ export interface ErrorPageParams {
   statusCode: number;
 }
 
+export interface DeviceVerificationPageParams {
+  /**
+   * user_code to pre-fill the input with. Comes from the query string of
+   * verification_uri_complete (RFC 8628 §3.3.1) or from the user's own previous
+   * submission, so it is untrusted input and MUST be escaped before rendering.
+   */
+  userCode?: string;
+  /**
+   * Failure message for a code that did not match. RFC 8628 §5.1: the same text
+   * is used for unknown, expired and already-used codes, so do not add detail
+   * here — it would tell an attacker which codes exist.
+   */
+  error?: string;
+}
+
+export interface DeviceLoginPageParams {
+  /** user_code in display form; carried through as a hidden field. */
+  userCode: string;
+  /** CSRF token (must be included as hidden form field) */
+  csrfToken: string;
+  /** Error message from a previous failed attempt */
+  error?: string;
+  /** Number of remaining login attempts for this device authorization */
+  remainingAttempts?: number;
+}
+
+export interface DeviceApprovalPageParams {
+  /**
+   * user_code in display form. RFC 8628 §5.4: show it so the user can compare it
+   * with the code on the device screen — that comparison is the only defense
+   * against a remote phishing attempt that lured them to approve someone else's
+   * device.
+   */
+  userCode: string;
+  /** CSRF token (must be included as hidden form field) */
+  csrfToken: string;
+  /** Client the device authorization was requested by */
+  clientId: string;
+  /** Scopes the device asked for */
+  scopes: string[];
+}
+
+export interface DeviceCompletedPageParams {
+  /** true when the user approved, false when they denied */
+  approved: boolean;
+  /** Client the decision applied to */
+  clientId: string;
+}
+
 // ============================================================
 // Views Interface
 // ============================================================
@@ -70,6 +119,14 @@ export interface Views {
   consentPage(params: ConsentPageParams): ViewResult;
   /** Render a generic error page */
   errorPage(params: ErrorPageParams): ViewResult;
+  /** EXPERIMENTAL (RFC 8628 §3.3): render the user_code entry form */
+  deviceVerificationPage(params: DeviceVerificationPageParams): ViewResult;
+  /** EXPERIMENTAL (RFC 8628 §3.3): render the sign-in form for a device flow */
+  deviceLoginPage(params: DeviceLoginPageParams): ViewResult;
+  /** EXPERIMENTAL (RFC 8628 §3.3): render the approve / deny screen */
+  deviceApprovalPage(params: DeviceApprovalPageParams): ViewResult;
+  /** EXPERIMENTAL (RFC 8628 §3.3): render the "go back to your device" screen */
+  deviceCompletedPage(params: DeviceCompletedPageParams): ViewResult;
 }
 
 /** Options applied when renderView wraps an HTML string into a Response. */
@@ -200,6 +257,106 @@ ${descriptionHtml}</body>
 </html>`;
 }
 
+function defaultDeviceVerificationPage(params: DeviceVerificationPageParams): string {
+  const errorHtml = params.error
+    ? `<p style="color: red;">${escapeHtml(params.error)}</p>`
+    : '';
+
+  return `<!DOCTYPE html>
+<html>
+<head><title>Device Activation</title></head>
+<body>
+  <h1>Device Activation</h1>
+  <p>Enter the code shown on your device.</p>
+  ${errorHtml}
+  <form method="POST" action="/device">
+    <div>
+      <label for="user_code">Code:</label>
+      <input type="text" id="user_code" name="user_code" value="${escapeHtml(params.userCode ?? '')}" required />
+    </div>
+    <button type="submit">Continue</button>
+  </form>
+</body>
+</html>`;
+}
+
+function defaultDeviceLoginPage(params: DeviceLoginPageParams): string {
+  const errorHtml = params.error
+    ? `<p style="color: red;">${escapeHtml(params.error)}${
+        params.remainingAttempts !== undefined
+          ? `. Attempts remaining: ${params.remainingAttempts}`
+          : ''
+      }</p>`
+    : '';
+
+  return `<!DOCTYPE html>
+<html>
+<head><title>Login</title></head>
+<body>
+  <h1>Login</h1>
+  <p>Activating device code <strong>${escapeHtml(params.userCode)}</strong></p>
+  ${errorHtml}
+  <form method="POST" action="/device/login">
+    <input type="hidden" name="user_code" value="${escapeHtml(params.userCode)}" />
+    <input type="hidden" name="csrf_token" value="${escapeHtml(params.csrfToken)}" />
+    <div>
+      <label for="username">Username:</label>
+      <input type="text" id="username" name="username" required />
+    </div>
+    <div>
+      <label for="password">Password:</label>
+      <input type="password" id="password" name="password" required />
+    </div>
+    <button type="submit">Login</button>
+  </form>
+</body>
+</html>`;
+}
+
+function defaultDeviceApprovalPage(params: DeviceApprovalPageParams): string {
+  const scopeListHtml = params.scopes
+    .map((s) => `    <li>${escapeHtml(s)}</li>`)
+    .join('\n');
+
+  // RFC 8628 §5.4: the code is repeated here on purpose. Ask the user to check it
+  // against the device in front of them before approving.
+  return `<!DOCTYPE html>
+<html>
+<head><title>Authorize Device</title></head>
+<body>
+  <h1>Authorize Device</h1>
+  <p>Confirm that your device is showing this code: <strong>${escapeHtml(params.userCode)}</strong></p>
+  <p>Do not continue if the code does not match.</p>
+  <p>Client <strong>${escapeHtml(params.clientId)}</strong> is requesting access to the following scopes:</p>
+  <ul>
+${scopeListHtml}
+  </ul>
+  <form method="POST" action="/device/approve">
+    <input type="hidden" name="user_code" value="${escapeHtml(params.userCode)}" />
+    <input type="hidden" name="csrf_token" value="${escapeHtml(params.csrfToken)}" />
+    <button type="submit" name="decision" value="approve">Approve</button>
+    <button type="submit" name="decision" value="deny">Deny</button>
+  </form>
+</body>
+</html>`;
+}
+
+function defaultDeviceCompletedPage(params: DeviceCompletedPageParams): string {
+  const outcome = params.approved
+    ? `<p>You approved <strong>${escapeHtml(params.clientId)}</strong>.</p>`
+    : `<p>You denied <strong>${escapeHtml(params.clientId)}</strong>.</p>`;
+
+  return `<!DOCTYPE html>
+<html>
+<head><title>Device Activation</title></head>
+<body>
+  <h1>Device Activation</h1>
+${outcome}
+  <p>You can close this page and go back to your device.</p>
+</body>
+</html>`;
+}
+
 /**
  * Default Views used when no custom views are injected.
  * These render minimal, unstyled HTML so the flow works out of the box.
@@ -208,6 +365,10 @@ export const defaultViews: Views = {
   loginPage: defaultLoginPage,
   consentPage: defaultConsentPage,
   errorPage: defaultErrorPage,
+  deviceVerificationPage: defaultDeviceVerificationPage,
+  deviceLoginPage: defaultDeviceLoginPage,
+  deviceApprovalPage: defaultDeviceApprovalPage,
+  deviceCompletedPage: defaultDeviceCompletedPage,
 };
 
 /**

````

### Diffs for the other frameworks

- [express](../../../tasks/experimental/done/device-authorization-grant/promotion-review/generated-code/express.md)
- [fastify](../../../tasks/experimental/done/device-authorization-grant/promotion-review/generated-code/fastify.md)
- [nextjs](../../../tasks/experimental/done/device-authorization-grant/promotion-review/generated-code/nextjs.md)

This feature is enabled in every sample (express-flyio / fastify-flyio / hono-cloudflare / nextjs-vercel).

## The E2E test, in full

The E2E test plays the device with raw HTTP requests and the user with a real browser, and pins down:

- the polling device receiving the token set after approval on the second device's browser
- `access_denied` reaching the device when the user denies
- `authorization_pending` repeating while the user has not decided
- the verification steps refusing to run for a browser without the binding cookie
- rejection of a device_code presented by a different client

```typescript
import { expect, test } from '@playwright/test';

const host = process.env.E2E_HOST ?? '127.0.0.1';
const clientPort = Number(process.env.E2E_CLIENT_PORT ?? '3020');
const clientBaseURL =
  process.env.E2E_CLIENT_BASE_URL ?? `http://${host}:${clientPort}`;
const clientId = 'e2e-client';
const clientSecret = 'e2e-client-secret';
const DEVICE_GRANT_TYPE = 'urn:ietf:params:oauth:grant-type:device_code';

interface StartedDeviceFlow {
  flow_id: string;
  user_code: string;
  verification_uri: string;
  verification_uri_complete: string;
  expires_in: number;
  interval: number;
}

interface DeviceResult {
  status: 'pending' | 'complete' | 'failed';
  error: string | null;
  user_code: string;
  access_token: string | null;
  id_token: string | null;
  scope: string | null;
  token_type: string | null;
}

/**
 * EXPERIMENTAL — OAuth 2.0 Device Authorization Grant (RFC 8628).
 *
 * Only the samples generated with `--enable device-authorization-grant` expose
 * the endpoint, so every test here skips when discovery does not advertise it.
 * That keeps the shared spec suite green across all sample OPs.
 *
 * The device side runs inside the E2E client (`/start-device`), which polls the
 * token endpoint in the background while Playwright drives the browser through
 * the verification UI — the real two-device shape of the flow.
 */
test.describe('Device Authorization Grant (RFC 8628)', () => {
  test('should issue tokens after the user approves on a second device', async ({
    page,
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const endpoint = await deviceAuthorizationEndpoint(request, issuer);
    test.skip(
      endpoint === undefined,
      'This sample OP was generated without --enable device-authorization-grant',
    );
    expect(endpoint).toBe(`${issuer}/device_authorization`);

    const flow = await startDeviceFlow(request);
    expect(flow.interval).toBe(5);
    expect(flow.expires_in).toBe(600);
    expect(flow.verification_uri).toBe(`${issuer}/device`);

    // RFC 8628 §3.3.1: following verification_uri_complete pre-fills the code.
    await page.goto(flow.verification_uri_complete);
    await expect(page.getByLabel('Code:')).toHaveValue(flow.user_code);

    await page.getByRole('button', { name: 'Continue' }).click();
    await page.getByLabel('Username:').fill('testuser');
    await page.getByLabel('Password:').fill('password');
    await page.getByRole('button', { name: 'Login' }).click();

    // RFC 8628 §5.4: the approval screen repeats the code so the user can check
    // it against the device in front of them.
    await expect(page.getByRole('heading', { name: 'Authorize Device' })).toBeVisible();
    await expect(page.locator('strong').first()).toHaveText(flow.user_code);
    await expect(page.locator('li')).toHaveText(['openid', 'profile', 'email']);

    await page.getByRole('button', { name: 'Approve' }).click();
    await expect(page.getByText('You can close this page and go back to your device.')).toBeVisible();

    const result = await waitForDeviceResult(request, flow.flow_id);
    expect(result.status).toBe('complete');
    expect(result.token_type).toBe('Bearer');
    expect(result.scope).toBe('openid profile email');
    expect(typeof result.id_token).toBe('string');

    // The device's own token reaches the UserInfo endpoint.
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
    const endpoint = await deviceAuthorizationEndpoint(request, issuer);
    test.skip(
      endpoint === undefined,
      'This sample OP was generated without --enable device-authorization-grant',
    );

    const flow = await startDeviceFlow(request);

    await page.goto(flow.verification_uri_complete);
    await page.getByRole('button', { name: 'Continue' }).click();
    await page.getByLabel('Username:').fill('testuser');
    await page.getByLabel('Password:').fill('password');
    await page.getByRole('button', { name: 'Login' }).click();
    await page.getByRole('button', { name: 'Deny' }).click();
    await expect(page.getByText('You can close this page and go back to your device.')).toBeVisible();

    const result = await waitForDeviceResult(request, flow.flow_id);
    expect(result.status).toBe('failed');
    expect(result.error).toBe('access_denied');
    expect(result.access_token).toBe(null);
  });

  test('should answer authorization_pending while the user has not decided', async ({
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const endpoint = await deviceAuthorizationEndpoint(request, issuer);
    test.skip(
      endpoint === undefined,
      'This sample OP was generated without --enable device-authorization-grant',
    );

    const authorization = await request.post(`${issuer}/device_authorization`, {
      form: { client_id: clientId, client_secret: clientSecret, scope: 'openid' },
    });
    expect(authorization.status()).toBe(200);
    expect(authorization.headers()['cache-control']).toBe('no-store');
    const codes = await authorization.json() as { device_code: string };

    const poll = await request.post(`${issuer}/token`, {
      form: {
        grant_type: DEVICE_GRANT_TYPE,
        device_code: codes.device_code,
        client_id: clientId,
        client_secret: clientSecret,
      },
    });

    expect(poll.status()).toBe(400);
    expect(await poll.json()).toEqual({
      error: 'authorization_pending',
      error_description: 'The authorization request is still pending',
    });
  });

  test('should refuse the verification steps without the browser binding cookie', async ({
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const endpoint = await deviceAuthorizationEndpoint(request, issuer);
    test.skip(
      endpoint === undefined,
      'This sample OP was generated without --enable device-authorization-grant',
    );

    const authorization = await request.post(`${issuer}/device_authorization`, {
      form: { client_id: clientId, client_secret: clientSecret, scope: 'openid' },
    });
    const codes = await authorization.json() as { user_code: string };

    // The attacker knows the user_code (they could have started the flow), so
    // they can obtain a valid csrf_token. Without the binding cookie it is worth
    // nothing: a forged cross-site POST is refused.
    const matched = await request.post(`${issuer}/device`, {
      form: { user_code: codes.user_code },
    });
    const csrfToken = csrfTokenFrom(await matched.text());
    expect(csrfToken.length > 0).toBe(true);

    const forged = await request.post(`${issuer}/device/login`, {
      form: {
        user_code: codes.user_code,
        csrf_token: csrfToken,
        username: 'testuser',
        password: 'password',
      },
      // Playwright's request context keeps cookies, so start from a clean state
      // to model a browser that never held this record's binding cookie.
      headers: { Cookie: '' },
    });

    expect(forged.status()).toBe(403);
  });

  test('should reject a device_code presented by a different client', async ({
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const endpoint = await deviceAuthorizationEndpoint(request, issuer);
    test.skip(
      endpoint === undefined,
      'This sample OP was generated without --enable device-authorization-grant',
    );

    const authorization = await request.post(`${issuer}/device_authorization`, {
      form: { client_id: clientId, client_secret: clientSecret, scope: 'openid' },
    });
    const codes = await authorization.json() as { device_code: string };

    // RFC 8628 §3.4: the code belongs to the client it was issued to.
    // e2e-device-other authenticates fine and is registered for the device
    // grant, so the only thing that stops it is the code's client binding.
    const poll = await request.post(`${issuer}/token`, {
      form: {
        grant_type: DEVICE_GRANT_TYPE,
        device_code: codes.device_code,
        client_id: 'e2e-device-other',
        client_secret: 'e2e-device-other-secret',
      },
    });

    expect(poll.status()).toBe(400);
    // The wording matches the unknown-code case so existence is not leaked.
    expect(await poll.json()).toEqual({
      error: 'invalid_grant',
      error_description: 'The device_code is invalid, expired, or was issued to another client',
    });
  });
});

async function startDeviceFlow(
  request: { get(url: string): Promise<{ json(): Promise<unknown> }> },
): Promise<StartedDeviceFlow> {
  const response = await request.get(`${clientBaseURL}/start-device`);
  return await response.json() as StartedDeviceFlow;
}

/**
 * Poll the E2E client until its background device polling settles.
 *
 * The OP's interval is 5 seconds, so the device needs a couple of poll cycles
 * after the browser finishes; 45 seconds leaves room for a slow_down bump.
 */
async function waitForDeviceResult(
  request: { get(url: string): Promise<{ json(): Promise<unknown> }> },
  flowId: string,
): Promise<DeviceResult> {
  const deadline = Date.now() + 45_000;
  let result = await readDeviceResult(request, flowId);
  while (result.status === 'pending' && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 1_000));
    result = await readDeviceResult(request, flowId);
  }
  return result;
}

async function readDeviceResult(
  request: { get(url: string): Promise<{ json(): Promise<unknown> }> },
  flowId: string,
): Promise<DeviceResult> {
  const response = await request.get(`${clientBaseURL}/device-result?flow_id=${flowId}`);
  return await response.json() as DeviceResult;
}

async function deviceAuthorizationEndpoint(
  request: { get(url: string): Promise<{ json(): Promise<unknown> }> },
  issuer: string,
): Promise<string | undefined> {
  const response = await request.get(`${issuer}/.well-known/openid-configuration`);
  const metadata = await response.json() as { device_authorization_endpoint?: string };
  return metadata.device_authorization_endpoint;
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

## Related material

- User-facing documentation: [docs/library-document experimental/device-authorization-grant.md](../../library-document/src/content/docs/experimental/device-authorization-grant.md)
- Specification study documents: [tasks/experimental/done/device-authorization-grant/](../../../tasks/experimental/done/device-authorization-grant/)
- Promotion-review packet: [tasks/experimental/done/device-authorization-grant/promotion-review/](../../../tasks/experimental/done/device-authorization-grant/promotion-review/README.md)
- Package-wide conventions: [package-overview.en.md](./package-overview.en.md)
- 日本語版: [device-authorization-grant.ja.md](./device-authorization-grant.ja.md)
