# RP-Initiated Logout (OpenID Connect RP-Initiated Logout 1.0) Implementation Guide

This document explains what was implemented for **OpenID Connect RP-Initiated Logout 1.0** (Final, published September 2022) in `packages/experimental`, and how, together with the complete source code involved.

The document embeds, verbatim and in full:

- all four implementation files and all three test files under `packages/experimental/src/rp-initiated-logout/`
- the complete code that `--enable rp-initiated-logout` adds to the CLI-generated output (hono)
- the complete E2E test spec for the feature

The core package itself, the shared E2E harness, and the other frameworks' generated variants are infrastructure shared by every feature, so they are linked instead of embedded.

## What the feature does

The generated OP implements login and consent, but the default output has no logout path.
When the End-User logs out of an RP, the OP browser session stays alive, and the next authorization request passes without re-authentication.
When a team evaluates an SSO design, "does logout behave as required" carries the same weight as "can users log in", so this gap undermined the library's core promise of letting users verify whether a spec meets their requirements.

RP-Initiated Logout 1.0 defines the **end_session_endpoint**: the RP navigates the user agent to the OP to end the OP session.
Of the four logout specifications (RP-Initiated / Session Management / Front-Channel / Back-Channel), only RP-Initiated completes in one direction, from the RP to the OP; the other three need a notification channel from the OP back to RPs.
That asymmetry is what makes RP-Initiated Logout separable as a single experimental feature.

```text
RP                                     OP (generated code + experimental/rp-initiated-logout + core)
 |                                       |
 |-- GET /logout ----------------------->| (1) parse parameters (GET query / POST form, §2 MUST)
 |   ?id_token_hint=...                  | (2) verify id_token_hint: core validateIdTokenHint
 |   &post_logout_redirect_uri=...       | (3) if client_id is present, require it to match aud (§2 MUST)
 |   &state=...                          | (4) compare the hint's sub with the session subject
 |                                       |
 |        [valid hint + session match]   | (5a) delete the session + expire the cookie
 |<- 302 post_logout_redirect_uri?state= | (6a) redirect with state on an exact registered match (§3)
 |                                       |
 |        [no hint / invalid / mismatch] | (5b) render the confirmation screen (§2 MUST; delete nothing)
 |                                       | (6b) only the approve POST deletes the session
```

Only a request whose valid `id_token_hint` names the current session's End-User logs out immediately; every other request falls to one shared confirmation screen.
The spec demands that confirmation (§2 MUST) because an unconfirmed logout endpoint would be a denial-of-service primitive: planting a link would be enough to end the victim's session (§7).

### Use cases

- verify the full round trip of an SSO proof of concept, from the RP's logout button to the end of the OP session
- observe how registration and exact matching of `post_logout_redirect_uri` behave (unregistered URIs, partial matches, query differences)
- verify the downstream effects of ending a session: `prompt=none` failing with `login_required`, online refresh tokens becoming unusable

### Scope and non-goals

The implementation covers:

- `GET|POST /logout` (both methods, §2 MUST) and the confirmation approve route `POST /logout/approve`
- `id_token_hint` verification (core's public `validateIdTokenHint`, used as is) with a fail-closed fall-through to the confirmation screen
- the redirect on an exact registered match, echoing `state` (§3)
- advertising `end_session_endpoint` in discovery (§2.1)

Non-goals:

- Session Management 1.0 (`check_session_iframe` / `session_state`) and Front-Channel / Back-Channel Logout. Nothing is propagated to other RPs and no `sid` claim is issued
- accepting an expired `id_token_hint` (a SHOULD in §2). Core's `validateIdTokenHint` rejects an expired `exp`, so an expired hint counts as an invalid hint and falls to the confirmation path. Logout still completes after confirmation, so this is a safe-side omission
- interpreting `logout_hint` / `ui_locales`. Both are accepted but change nothing (OPTIONAL)
- cleaning up issued tokens. What disappears is the session, and with it the usability of online refresh tokens; offline refresh tokens and access tokens remain the responsibility of revocation (RFC 7009)

## Design approach

The implementation separates deciding from doing.
The experimental package holds only pure functions (request normalization, hint audience extraction, the logout flow decision, redirect resolution) that touch neither HTTP nor the session store.
The session itself (the `session_id` cookie and the browser session store) has always belonged to the generated code, and deleting it just calls the store's existing `delete`.
Keeping the decision in pure functions makes it exhaustively unit-testable, and if the feature is later promoted to core (the study material's plan A puts pure logout-request validation into core), the functions port as they are.

Core is unchanged.
The only core APIs used are the public `validateIdTokenHint` / `IdTokenHintError` / `generateRandomString`, and hint verification reuses the `jwksProvider` every build already wires (defaulting to the OP's own ID Token signing keys).
The feature only rides on the session and key infrastructure present in every build, so it has no dependency on, and no conflict with, any other feature.

The other notable decision is how state crosses the confirmation screen.
Between rendering the confirmation and receiving the approve POST, the OP must keep "where a redirect may go", but a hidden form field can be tampered with, and echoing the `id_token_hint` would expose a token value in HTML.
This implementation rides the OP-computed redirect target inside the HttpOnly CSRF cookie minted when the screen renders, and the form sends back only the paired random secret.
No new store contract is needed, and the only value written into the page is the CSRF token itself.

## Implementation code, in full

### request.ts (request normalization and audience extraction)

`parseEndSessionRequest` normalizes the six §2 parameters from a URLSearchParams.
GET arrives as a query and POST as a form body, but both are converted to URLSearchParams first, so the normalization rules (first value wins on duplicates, an empty string counts as absent) live in one place.

`extractIdTokenHintAudience` determines the expected audience for verification when the request has no `client_id` parameter.
This decodes the payload **before** signature verification: the return value is only a candidate ("try verifying against this aud"), and trust comes from `validateIdTokenHint` afterwards.
The `azp` fallback for an array-shaped aud is not a defensive branch: core's `buildIdTokenAudience` turns `aud` into an array and always sets `azp` when additional audiences are configured, so IDs token issued by this very OP take that path.

```typescript
/**
 * OpenID Connect RP-Initiated Logout 1.0 — end_session リクエストの正規化。
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * §2: OP は GET と POST の両方でログアウト要求を受理しなければならない。
 * 生成コードは GET なら URL クエリ、POST なら `application/x-www-form-urlencoded`
 * のボディを URLSearchParams にしてここへ渡す。
 */

/** end_session_endpoint のリクエストパラメータ（RP-Initiated Logout 1.0 §2）。 */
export interface EndSessionRequest {
  /** RECOMMENDED。過去に発行した ID Token（ログアウト権限の証拠）。 */
  idTokenHint?: string;
  /** OPTIONAL。指定時はヒントの aud と一致しなければならない（§2 MUST）。 */
  clientId?: string;
  /** OPTIONAL。登録値との完全一致時のみ使用する（§3）。 */
  postLogoutRedirectUri?: string;
  /** OPTIONAL。解釈せず、リダイレクト時にそのまま返す（§3）。 */
  state?: string;
  /** OPTIONAL。受理するが使用しない（本機能の非目標）。 */
  logoutHint?: string;
  /** OPTIONAL。受理するが使用しない（本機能の非目標）。 */
  uiLocales?: string;
}

/**
 * end_session リクエストのパラメータを正規化する。
 *
 * 重複パラメータは最初の値を採用し（`URLSearchParams.get` の挙動）、空文字は
 * 値なしとして undefined に落とす。空の `id_token_hint` を「ヒントあり」と
 * 数えると、後段の検証失敗と区別が付かないまま分岐だけ増えるため。
 */
export function parseEndSessionRequest(params: URLSearchParams): EndSessionRequest {
  return {
    idTokenHint: nonEmpty(params.get('id_token_hint')),
    clientId: nonEmpty(params.get('client_id')),
    postLogoutRedirectUri: nonEmpty(params.get('post_logout_redirect_uri')),
    state: nonEmpty(params.get('state')),
    logoutHint: nonEmpty(params.get('logout_hint')),
    uiLocales: nonEmpty(params.get('ui_locales')),
  };
}

function nonEmpty(value: string | null): string | undefined {
  return value === null || value === '' ? undefined : value;
}

/**
 * `id_token_hint` の payload から検証に使う期待 audience を抽出する。
 *
 * `client_id` パラメータが無いリクエストでは、core の `validateIdTokenHint` に
 * 渡す `expectedAud` をヒント自身から特定するしかない。これは署名検証**前**の
 * 復号であり、返り値は「この aud で検証を試みる」という候補にすぎない。信頼は
 * その後の `validateIdTokenHint`（署名・iss・aud・exp）が与える。
 *
 * aud の形（OIDC Core §2）ごとの扱い:
 * - 文字列 → その値
 * - 配列 + `azp`（文字列）→ azp の値。core の `buildIdTokenAudience` は追加
 *   audience 構成時に aud を配列にし azp を必ず付与するため、自 OP 発行の
 *   ID Token でもこの経路は必須である
 * - 配列（要素 1・azp なし）→ その要素。自 OP 発行では生じない形だが、署名検証前の
 *   入力に対する処理として許容する
 * - それ以外（複数要素で azp なし、aud 欠落・非文字列）→ null（特定不能）
 *
 * 復号できない・特定できない場合は null を返す。呼び出し側はヒントを無効として
 * 確認画面の経路（§2 MUST）に落とす。
 */
export function extractIdTokenHintAudience(idTokenHint: string): string | null {
  const parts = idTokenHint.split('.');
  if (parts.length !== 3) {
    return null;
  }
  let payload: Record<string, unknown>;
  try {
    payload = parseBase64UrlJson(parts[1] as string);
  } catch {
    return null;
  }
  const aud = payload['aud'];
  if (typeof aud === 'string') {
    return aud;
  }
  if (Array.isArray(aud)) {
    const azp = payload['azp'];
    if (typeof azp === 'string') {
      return azp;
    }
    if (aud.length === 1 && typeof aud[0] === 'string') {
      return aud[0];
    }
  }
  return null;
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
```

### decision.ts (the logout flow decision)

`decideLogoutFlow` is the §2 MUST turned into a pure function.
Immediate logout requires all three of: a valid hint, an existing session, and the hint's `sub` matching the session subject; everything else falls to the confirmation screen.
The function does not report why: differing reasons would make the endpoint an oracle for session state, and the generated caller keeps them off the screen for the same reason.

A `client_id` parameter that mismatches the expected audience (violating the §2 MUST) not only forces the confirmation screen but also nulls `verifiedClientId`, treating the whole hint as invalid so the §3 redirect authority is lost with it.
When the confirmation is forced by a missing session or a `sub` mismatch instead, the hint itself is valid, so `verifiedClientId` is kept: the §3 redirect condition is the supplied hint plus the exact registered match, not which path the logout took.

```typescript
/**
 * OpenID Connect RP-Initiated Logout 1.0 — ログアウトフローの分岐判定。
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * §2 MUST: `id_token_hint` が無い、または供給された ID Token が現在の OP
 * セッションのものでない場合、OP はユーザーに確認しなければならない。
 * §7: 有効なヒントのないログアウト要求はセッション終了の DoS 手段になり得る。
 * この関数はその MUST をそのまま分岐にした純関数で、HTTP にもストアにも触れない。
 */

/** `decideLogoutFlow` の判定結果。生成コードのルートはこの型だけを見て分岐する。 */
export interface LogoutDecision {
  /** true: 確認画面を出す（§2 MUST）。false: 即時ログアウト。 */
  requiresConfirmation: boolean;
  /**
   * §3 のリダイレクト権限を持つ検証済みクライアント。ヒントが無効（検証失敗・
   * `client_id` 不一致・aud 特定不能）なら null。確認画面の経路でも、ヒント自体が
   * 有効ならリダイレクト権限は残る（リダイレクトの条件はヒントの供給と登録値の
   * 完全一致であり、確認画面の経由有無ではない）。
   */
  verifiedClientId: string | null;
}

/**
 * ログアウト要求を「即時ログアウト」と「確認画面」に分岐する。
 *
 * 即時ログアウトは、ヒントが有効で、現在のブラウザセッションが存在し、ヒントの
 * `sub` がセッションの subject と一致する場合のみ（§2 の SHOULD 解釈。RP の
 * ログアウト操作は End-User 自身の操作であり、有効なヒントは RP がその End-User に
 * トークンを発行された当人であることを示す）。それ以外はすべて確認画面に落とす。
 * 落とした理由は返さない（失敗理由の差はセッション状態のオラクルになるため、
 * 呼び出し側も画面に出さない前提）。
 *
 * @param options.verifiedHint core `validateIdTokenHint` の戻り値（検証失敗時は null を渡す）
 * @param options.expectedAudience 検証に使った期待 aud（`client_id` パラメータ、
 *   または `extractIdTokenHintAudience` の結果。特定不能は null）
 * @param options.clientIdParam リクエストの `client_id` パラメータ。指定時は
 *   expectedAudience と一致しなければヒント全体を無効にする（§2 MUST）
 * @param options.sessionSubject 現在のブラウザセッションの subject（セッションなしは null）
 */
export function decideLogoutFlow(options: {
  verifiedHint: { sub: string; [key: string]: unknown } | null;
  expectedAudience: string | null;
  clientIdParam: string | undefined;
  sessionSubject: string | null;
}): LogoutDecision {
  const { verifiedHint, expectedAudience, clientIdParam, sessionSubject } = options;

  const hintValid =
    verifiedHint !== null &&
    expectedAudience !== null &&
    (clientIdParam === undefined || clientIdParam === expectedAudience);

  const verifiedClientId = hintValid ? expectedAudience : null;

  const requiresConfirmation = !(
    hintValid &&
    sessionSubject !== null &&
    verifiedHint.sub === sessionSubject
  );

  return { requiresConfirmation, verifiedClientId };
}
```

### redirect.ts (resolving the redirect target)

`resolvePostLogoutRedirect` implements the inverse of the §3 MUST NOT.
The exact match is a string comparison, with no normalization, no prefix matching and no query stripping (the same judgment as the authorize `redirect_uri` validation; RFC 6749 §10.15).
`state` is only ever emitted through the URL API's query appending, so there is no path into the response that bypasses URL encoding.

```typescript
/**
 * OpenID Connect RP-Initiated Logout 1.0 — post_logout_redirect_uri の解決。
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * §3: `post_logout_redirect_uri` の値は、クライアントに事前登録された
 * `post_logout_redirect_uris` のいずれかと一致しない限り使用してはならない
 * （MUST NOT）。また `id_token_hint` が併せて供給されない要求ではリダイレクト
 * してはならない。この関数はその両方を満たす場合だけ URL を返す純関数。
 */

/**
 * リダイレクト先 URL を確定する。条件を満たさなければ null（呼び出し側は
 * 完了画面を表示する。fail-closed）。
 *
 * 完全一致は文字列比較で行い、正規化・前方一致・クエリ無視をしない
 * （authorize の redirect_uri 検証と同じ判断。RFC 6749 §10.15 のオープン
 * リダイレクタ回避）。`state` は URL API のクエリ付加でのみ出力するため、
 * URL エンコードを通らずに応答へ出る経路はない。
 *
 * @param options.postLogoutRedirectUri リクエストのパラメータ値
 * @param options.state リクエストの `state`。リダイレクトしない場合はどこにも出力されない
 * @param options.verifiedClientId `decideLogoutFlow` が返した検証済みクライアント
 *   （null はヒント無効 = §3 によりリダイレクト禁止）
 * @param options.registeredUris verifiedClientId に登録された
 *   `post_logout_redirect_uris`（生成コードの設定から引く）
 */
export function resolvePostLogoutRedirect(options: {
  postLogoutRedirectUri: string | undefined;
  state: string | undefined;
  verifiedClientId: string | null;
  registeredUris: readonly string[];
}): string | null {
  const { postLogoutRedirectUri, state, verifiedClientId, registeredUris } = options;

  if (verifiedClientId === null || postLogoutRedirectUri === undefined) {
    return null;
  }
  if (!registeredUris.includes(postLogoutRedirectUri)) {
    return null;
  }

  let url: URL;
  try {
    url = new URL(postLogoutRedirectUri);
  } catch {
    // 登録簿に相対 URI などの不正値が紛れていた場合。組み立てられない値へは
    // リダイレクトしない。
    return null;
  }
  if (state !== undefined) {
    url.searchParams.append('state', state);
  }
  return url.toString();
}
```

### index.ts (public API)

The entry point of the subpath export `@maronn-openid-connect/experimental/rp-initiated-logout`.
No error class is exported: each function cannot fail as long as its inputs meet the contract, and negative outcomes are expressed as null / `requiresConfirmation` return values.

```typescript
/**
 * OpenID Connect RP-Initiated Logout 1.0 — Final (2022-09-12)
 *
 * **Experimental**: この機能の API は安定していない。マイナーリリースでも
 * 破壊的に変更されることがある。本番運用の前に
 * `docs/library-document` の Experimental セクションを確認すること。
 *
 * `@maronn-openid-connect/core` とは別 package であり、CLI で
 * `--enable rp-initiated-logout` を明示したときのみ生成コードから利用される。
 *
 * このモジュールは「ログアウト要求の解釈とリダイレクト先の確定」だけを持つ
 * 純関数群で、HTTP にもセッションストアにも触れない。`id_token_hint` の検証は
 * core 公開の `validateIdTokenHint` を使い、セッションの実体（Cookie とストア）は
 * 生成コード側の責務のまま変えない。
 *
 * スコープ外（非目標）: Session Management 1.0 / Front-Channel Logout 1.0 /
 * Back-Channel Logout 1.0（他 RP への伝播）、期限切れ `id_token_hint` の受理
 * （§2 の SHOULD。本実装は無効なヒントとして確認画面の経路に落とす）。
 */
export {
  parseEndSessionRequest,
  extractIdTokenHintAudience,
  type EndSessionRequest,
} from './request.js';

export { decideLogoutFlow, type LogoutDecision } from './decision.js';

export { resolvePostLogoutRedirect } from './redirect.js';
```

## Unit tests, in full

The implementation followed t_wada-style TDD: the tests were written first and confirmed red before the implementation.
They pin the normalization rules of `parseEndSessionRequest`, the per-shape branches and malformed inputs of `extractIdTokenHintAudience`, every branch of `decideLogoutFlow`, and each fail-closed condition of `resolvePostLogoutRedirect`.

### request.test.ts

```typescript
import { describe, expect, it } from 'vitest';
import { extractIdTokenHintAudience, parseEndSessionRequest } from './request.js';

/** base64url（パディング無し）でエンコードする。テスト内でのみ使用する。 */
function base64UrlEncode(value: string): string {
  const bytes = new TextEncoder().encode(value);
  let binary = '';
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/** ダミー署名付きの compact JWS を組み立てる。署名検証前の抽出だけを試すため中身は問わない。 */
function buildUnsignedJws(payload: Record<string, unknown>): string {
  const header = base64UrlEncode(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const body = base64UrlEncode(JSON.stringify(payload));
  return `${header}.${body}.c2ln`;
}

describe('parseEndSessionRequest', () => {
  // RP-Initiated Logout 1.0 §2: end_session_endpoint のリクエストパラメータ 6 種を
  // GET クエリ / POST フォームボディ共通の URLSearchParams から正規化する。
  describe('Parameter extraction', () => {
    it('should extract all six end_session parameters', () => {
      const params = new URLSearchParams({
        id_token_hint: 'hint-value',
        client_id: 'client-1',
        post_logout_redirect_uri: 'https://rp.example/loggedout',
        state: 'af0ifjsldkj',
        logout_hint: 'user@example.com',
        ui_locales: 'ja-JP ja',
      });
      expect(parseEndSessionRequest(params)).toEqual({
        idTokenHint: 'hint-value',
        clientId: 'client-1',
        postLogoutRedirectUri: 'https://rp.example/loggedout',
        state: 'af0ifjsldkj',
        logoutHint: 'user@example.com',
        uiLocales: 'ja-JP ja',
      });
    });

    it('should leave absent parameters undefined', () => {
      expect(parseEndSessionRequest(new URLSearchParams())).toEqual({
        idTokenHint: undefined,
        clientId: undefined,
        postLogoutRedirectUri: undefined,
        state: undefined,
        logoutHint: undefined,
        uiLocales: undefined,
      });
    });
  });

  describe('Duplicate and empty values', () => {
    // 重複パラメータは最初の値を採用する（仕様書の公開 API 契約）。
    it('should take the first value when a parameter is duplicated', () => {
      const params = new URLSearchParams(
        'id_token_hint=first&id_token_hint=second&state=s1&state=s2',
      );
      const parsed = parseEndSessionRequest(params);
      expect(parsed.idTokenHint).toBe('first');
      expect(parsed.state).toBe('s1');
    });

    // 空文字は値なしと同じ扱い。空の id_token_hint を「ヒントあり」と数えない。
    it('should treat an empty value as undefined', () => {
      const params = new URLSearchParams('id_token_hint=&client_id=&state=');
      expect(parseEndSessionRequest(params)).toEqual({
        idTokenHint: undefined,
        clientId: undefined,
        postLogoutRedirectUri: undefined,
        state: undefined,
        logoutHint: undefined,
        uiLocales: undefined,
      });
    });
  });
});

describe('extractIdTokenHintAudience', () => {
  // OIDC Core §2: aud は文字列または配列。配列で複数値のときは azp が必須。
  // 抽出は署名検証前の処理であり、信頼は後段の validateIdTokenHint が与える。
  describe('aud claim shapes', () => {
    it('should return the aud claim when aud is a string', () => {
      const jws = buildUnsignedJws({ aud: 'client-1', sub: 'user-1' });
      expect(extractIdTokenHintAudience(jws)).toBe('client-1');
    });

    // core の buildIdTokenAudience は追加 audience 構成時に aud 配列 + azp を発行する
    // ため、azp フォールバックは自 OP 発行トークンでも必須の経路になる。
    it('should return the azp claim when aud is an array and azp is present', () => {
      const jws = buildUnsignedJws({ aud: ['client-1', 'https://api.example'], azp: 'client-1' });
      expect(extractIdTokenHintAudience(jws)).toBe('client-1');
    });

    it('should return the sole element when aud is a one-element array without azp', () => {
      const jws = buildUnsignedJws({ aud: ['client-1'] });
      expect(extractIdTokenHintAudience(jws)).toBe('client-1');
    });

    it('should return null when aud is a multi-element array without azp', () => {
      const jws = buildUnsignedJws({ aud: ['client-1', 'client-2'] });
      expect(extractIdTokenHintAudience(jws)).toBe(null);
    });

    it('should return null when aud is missing', () => {
      const jws = buildUnsignedJws({ sub: 'user-1' });
      expect(extractIdTokenHintAudience(jws)).toBe(null);
    });

    it('should return null when aud is neither a string nor an array', () => {
      const jws = buildUnsignedJws({ aud: 42 });
      expect(extractIdTokenHintAudience(jws)).toBe(null);
    });

    it('should return null when azp is not a string and aud has multiple elements', () => {
      const jws = buildUnsignedJws({ aud: ['client-1', 'client-2'], azp: 42 });
      expect(extractIdTokenHintAudience(jws)).toBe(null);
    });
  });

  describe('Malformed input', () => {
    it('should return null for a value that is not a three-part compact JWS', () => {
      expect(extractIdTokenHintAudience('not-a-jwt')).toBe(null);
      expect(extractIdTokenHintAudience('a.b')).toBe(null);
      expect(extractIdTokenHintAudience('a.b.c.d')).toBe(null);
      expect(extractIdTokenHintAudience('')).toBe(null);
    });

    it('should return null when the payload is not valid base64url', () => {
      expect(extractIdTokenHintAudience('aGVhZGVy.!!invalid!!.c2ln')).toBe(null);
    });

    it('should return null when the payload is not valid JSON', () => {
      const jws = `${base64UrlEncode('{"alg":"RS256"}')}.${base64UrlEncode('not json')}.c2ln`;
      expect(extractIdTokenHintAudience(jws)).toBe(null);
    });

    it('should return null when the payload is a JSON array instead of an object', () => {
      const jws = `${base64UrlEncode('{"alg":"RS256"}')}.${base64UrlEncode('["client-1"]')}.c2ln`;
      expect(extractIdTokenHintAudience(jws)).toBe(null);
    });
  });
});
```

### decision.test.ts

```typescript
import { describe, expect, it } from 'vitest';
import { decideLogoutFlow } from './decision.js';

describe('decideLogoutFlow', () => {
  // RP-Initiated Logout 1.0 §2: 有効な id_token_hint が現在の OP セッションの
  // End-User のものである場合だけ確認画面を省略できる。それ以外はすべて
  // 確認画面（MUST）。
  describe('Immediate logout', () => {
    it('should skip confirmation when the verified hint sub matches the session subject', () => {
      expect(
        decideLogoutFlow({
          verifiedHint: { sub: 'user-1' },
          expectedAudience: 'client-1',
          clientIdParam: undefined,
          sessionSubject: 'user-1',
        }),
      ).toEqual({ requiresConfirmation: false, verifiedClientId: 'client-1' });
    });

    // §2 MUST: client_id パラメータがあるときはヒントの aud と一致しなければ
    // ならない。一致する場合は即時ログアウトを妨げない。
    it('should skip confirmation when client_id matches the expected audience', () => {
      expect(
        decideLogoutFlow({
          verifiedHint: { sub: 'user-1' },
          expectedAudience: 'client-1',
          clientIdParam: 'client-1',
          sessionSubject: 'user-1',
        }),
      ).toEqual({ requiresConfirmation: false, verifiedClientId: 'client-1' });
    });
  });

  describe('Confirmation required', () => {
    it('should require confirmation when the hint is absent or invalid', () => {
      expect(
        decideLogoutFlow({
          verifiedHint: null,
          expectedAudience: null,
          clientIdParam: undefined,
          sessionSubject: 'user-1',
        }),
      ).toEqual({ requiresConfirmation: true, verifiedClientId: null });
    });

    // client_id パラメータとヒント aud の不一致（§2 MUST 違反）はヒント全体を
    // 無効として扱い、リダイレクト権限も与えない。
    it('should require confirmation and drop the client when client_id mismatches the audience', () => {
      expect(
        decideLogoutFlow({
          verifiedHint: { sub: 'user-1' },
          expectedAudience: 'client-1',
          clientIdParam: 'client-2',
          sessionSubject: 'user-1',
        }),
      ).toEqual({ requiresConfirmation: true, verifiedClientId: null });
    });

    it('should require confirmation when there is no session', () => {
      expect(
        decideLogoutFlow({
          verifiedHint: { sub: 'user-1' },
          expectedAudience: 'client-1',
          clientIdParam: undefined,
          sessionSubject: null,
        }),
      ).toEqual({ requiresConfirmation: true, verifiedClientId: 'client-1' });
    });

    it('should require confirmation when the hint sub differs from the session subject', () => {
      expect(
        decideLogoutFlow({
          verifiedHint: { sub: 'user-2' },
          expectedAudience: 'client-1',
          clientIdParam: undefined,
          sessionSubject: 'user-1',
        }),
      ).toEqual({ requiresConfirmation: true, verifiedClientId: 'client-1' });
    });

    // 確認画面を経由しても、有効なヒントの RP には §3 のリダイレクト権限が残る
    // （リダイレクト条件は確認画面の経由有無ではない。仕様書 U1 の確定）。
    it('should keep verifiedClientId on the confirmation path when the hint is valid', () => {
      const decision = decideLogoutFlow({
        verifiedHint: { sub: 'user-1' },
        expectedAudience: 'client-1',
        clientIdParam: undefined,
        sessionSubject: null,
      });
      expect(decision.verifiedClientId).toBe('client-1');
    });

    // expectedAudience が特定できなかった場合、ヒントの検証は成立し得ないため
    // verifiedHint があっても信頼しない（防御的な整合性チェック）。
    it('should treat a missing expected audience as an invalid hint', () => {
      expect(
        decideLogoutFlow({
          verifiedHint: { sub: 'user-1' },
          expectedAudience: null,
          clientIdParam: undefined,
          sessionSubject: 'user-1',
        }),
      ).toEqual({ requiresConfirmation: true, verifiedClientId: null });
    });
  });
});
```

### redirect.test.ts

```typescript
import { describe, expect, it } from 'vitest';
import { resolvePostLogoutRedirect } from './redirect.js';

describe('resolvePostLogoutRedirect', () => {
  // RP-Initiated Logout 1.0 §3: post_logout_redirect_uri は事前登録値と一致した
  // 場合のみ使用し（MUST NOT の裏返し）、state はそのままクエリで返す。
  describe('Exact match redirect', () => {
    it('should return the registered URI with state appended', () => {
      expect(
        resolvePostLogoutRedirect({
          postLogoutRedirectUri: 'https://rp.example/loggedout',
          state: 'af0ifjsldkj',
          verifiedClientId: 'client-1',
          registeredUris: ['https://rp.example/loggedout'],
        }),
      ).toBe('https://rp.example/loggedout?state=af0ifjsldkj');
    });

    it('should return the URI unchanged when state is absent', () => {
      expect(
        resolvePostLogoutRedirect({
          postLogoutRedirectUri: 'https://rp.example/loggedout',
          state: undefined,
          verifiedClientId: 'client-1',
          registeredUris: ['https://rp.example/loggedout'],
        }),
      ).toBe('https://rp.example/loggedout');
    });

    // 登録 URI が既にクエリを持つ場合も URL API で state を追記し、既存クエリを保持する。
    it('should append state while preserving an existing query string', () => {
      expect(
        resolvePostLogoutRedirect({
          postLogoutRedirectUri: 'https://rp.example/loggedout?from=op',
          state: 'xyz',
          verifiedClientId: 'client-1',
          registeredUris: ['https://rp.example/loggedout?from=op'],
        }),
      ).toBe('https://rp.example/loggedout?from=op&state=xyz');
    });

    // state は URL API のクエリ付加でのみ出力する（URL エンコードを通す。反射対策）。
    it('should URL-encode the state value', () => {
      expect(
        resolvePostLogoutRedirect({
          postLogoutRedirectUri: 'https://rp.example/loggedout',
          state: 'a b&c=d',
          verifiedClientId: 'client-1',
          registeredUris: ['https://rp.example/loggedout'],
        }),
      ).toBe('https://rp.example/loggedout?state=a+b%26c%3Dd');
    });
  });

  describe('Fail-closed cases', () => {
    // 完全一致は文字列比較。正規化・前方一致・クエリ無視をしない（§3 MUST NOT）。
    it('should return null for a partial or prefix match', () => {
      expect(
        resolvePostLogoutRedirect({
          postLogoutRedirectUri: 'https://rp.example/loggedout/extra',
          state: undefined,
          verifiedClientId: 'client-1',
          registeredUris: ['https://rp.example/loggedout'],
        }),
      ).toBe(null);
    });

    it('should return null for a trailing-slash difference', () => {
      expect(
        resolvePostLogoutRedirect({
          postLogoutRedirectUri: 'https://rp.example/loggedout/',
          state: undefined,
          verifiedClientId: 'client-1',
          registeredUris: ['https://rp.example/loggedout'],
        }),
      ).toBe(null);
    });

    it('should return null for a query-string difference', () => {
      expect(
        resolvePostLogoutRedirect({
          postLogoutRedirectUri: 'https://rp.example/loggedout?x=1',
          state: undefined,
          verifiedClientId: 'client-1',
          registeredUris: ['https://rp.example/loggedout'],
        }),
      ).toBe(null);
    });

    // §3: RP を特定・検証できない場合はリダイレクトしない。
    it('should return null when the client is not verified', () => {
      expect(
        resolvePostLogoutRedirect({
          postLogoutRedirectUri: 'https://rp.example/loggedout',
          state: 'xyz',
          verifiedClientId: null,
          registeredUris: ['https://rp.example/loggedout'],
        }),
      ).toBe(null);
    });

    it('should return null when post_logout_redirect_uri is absent', () => {
      expect(
        resolvePostLogoutRedirect({
          postLogoutRedirectUri: undefined,
          state: 'xyz',
          verifiedClientId: 'client-1',
          registeredUris: ['https://rp.example/loggedout'],
        }),
      ).toBe(null);
    });

    it('should return null when the registered URI list is empty', () => {
      expect(
        resolvePostLogoutRedirect({
          postLogoutRedirectUri: 'https://rp.example/loggedout',
          state: 'xyz',
          verifiedClientId: 'client-1',
          registeredUris: [],
        }),
      ).toBe(null);
    });

    // 登録簿に相対 URI などの不正値が紛れても、URL として組み立てられない一致は
    // リダイレクトに使わない（fail-closed）。
    it('should return null when the matched value is not an absolute URL', () => {
      expect(
        resolvePostLogoutRedirect({
          postLogoutRedirectUri: '/relative/path',
          state: 'xyz',
          verifiedClientId: 'client-1',
          registeredUris: ['/relative/path'],
        }),
      ).toBe(null);
    });
  });
});
```

## CLI integration and the generated-code contribution

The experimental package is only the logic layer: request normalization, hint-audience extraction, the logout-flow decision and redirect resolution.
Receiving HTTP, the cookies, deleting the session and the screens all live in the code `maronn-oidc generate` writes.
`--enable rp-initiated-logout` adds two things to the generated code:

- **`features/rp-initiated-logout/`**: `feature.ts`, which describes the feature, `config.ts` with the redirect registry, `cookies.ts` with the confirmation cookie, `views.tsx` with the screens, and the endpoint itself under `endpoints/logout/` (`page.tsx`, `endpoint.ts`, `outcome.ts` and the two steps of `steps/`)
- **`features/enabled.ts`**: one import of `rpInitiatedLogout` and one entry in the `features` list

In the generated code, logic a feature runs inside a base pipeline sits in that endpoint's `pipeline.ts` as a block that starts with a marker comment containing `(feature: <feature-id>)`; this guide calls it an **owner block**.
rp-initiated-logout has no owner block in any base pipeline: everything it contributes to the base goes through the hooks of `feature.ts`.
The feature is complete within its own endpoint and runs nothing in the middle of another endpoint's pipeline.

`feature.ts` uses two hooks, `routes` and `discovery`.
`routes` declares `/logout` (GET and POST) and `/approve` below it (POST only); `app.ts` mounts it and answers any other method with 405.
It sets no `cors`, so, like `/login` and `/consent`, it is a screen the browser opens directly and gets no CORS headers.
`discovery` returns `end_session_endpoint`.

The steps read the session store, the settings and `jwksProvider`, which the base `setRequestContext()` puts into the request context in every build, so the `context` hook is not used either.
`parseSessionId()`, which reads the session cookie, and `buildClearedSessionCookie()`, which clears it, are in the base `cookies.ts` as well and are generated whether the feature is enabled or not.
The two screens are added as members of the base `Views` by the module augmentation in `views.tsx` (`declare module '../../views.js'`), so the `views` option of `createApp()` and `applyOidc()` can replace them.

The logout flows like this.
When the RP sends the user agent to `/logout` with `GET` or `POST`, the shared middleware of `app.ts` prepares the request context, and `endpoints/logout/page.tsx` extracts the parameters and calls `processEndSessionRequest()`.
The step builds no `Response`: it returns what comes next (the confirmation screen, a redirect or the completed screen) and the cookies to set, as a `LogoutOutcome`, and `page.tsx` turns it into HTTP.
The confirmation form posts `csrf_token` to `/logout/approve`, and `approveLogout()` checks it against the HttpOnly cookie before deleting the session.

When the OP is generated without `--enable rp-initiated-logout`, only `features/rp-initiated-logout/` and the two lines of `features/enabled.ts` are missing; no other file changes.

### The generated code in full (hono)

Everything below is quoted from the output of `maronn-oidc generate hono --enable rp-initiated-logout` (the default features plus rp-initiated-logout).

#### The lines added to `features/enabled.ts`

`features/enabled.ts` lists the enabled features in the order their hooks apply.
rp-initiated-logout adds one import of its `feature.ts` and one entry of the `features` array.

```typescript
import { rpInitiatedLogout } from './rp-initiated-logout/feature.js';
```

```typescript
  rpInitiatedLogout,
```

#### `features/rp-initiated-logout/feature.ts`

The file that describes the feature: it passes `id`, `routes` and `discovery` to `defineFeature()`.
The `routes` entry gives the mount path, the `logoutPage` of `page.tsx` mounted there, the methods of the path itself, and the paths below it with their methods (`subpaths`).
§2 requires the end_session_endpoint to support both GET and POST (MUST), and the approval at `/logout/approve` accepts only the form POST.
`discovery` builds the §2.1 `end_session_endpoint` from the issuer.

```typescript
import { defineFeature } from '../feature.js';
import { logoutPage } from './endpoints/logout/page.js';

/**
 * EXPERIMENTAL — OpenID Connect RP-Initiated Logout 1.0: the end session
 * endpoint GET|POST /logout and its confirmation POST /logout/approve.
 * Settings (the registered post_logout_redirect_uri values) are in config.ts.
 *
 * Backed by @maronn-openid-connect/experimental, whose API is NOT stable: it
 * may change in a breaking way between releases.
 */
export const rpInitiatedLogout = defineFeature({
  id: 'rp-initiated-logout',
  routes: [
    { path: '/logout', app: logoutPage, methods: ['GET', 'POST'], subpaths: { '/approve': ['POST'] } },
  ],
  // RP-Initiated Logout 1.0 §2.1 metadata.
  discovery: (issuer) => ({ end_session_endpoint: `${issuer}/logout` }),
});
```

#### `features/rp-initiated-logout/config.ts`

This file holds the `post_logout_redirect_uri` registry, `rpInitiatedLogoutConfig.postLogoutRedirectUris`: per client_id, the URIs matched by exact string comparison.
The authorization endpoint's `redirect_uris` are not reused; logout has a registry of its own.
It is empty by default, so until a URI is registered every logout ends on the completed screen without a redirect (fail-closed).
The registry is an object in this file rather than a `config` hook because the `config` hook only supplies defaults of the base settings (`ProviderConfig`), and the registry is not part of them.
The `process-end-session-request` step imports the object and reads it directly, and a deployment rewrites its contents at startup (the sample below does this).

```typescript
/**
 * EXPERIMENTAL — settings for RP-Initiated Logout.
 *
 * postLogoutRedirectUris is the registry §3 checks against: client_id → the
 * exact post_logout_redirect_uri values that client registered (a registry of
 * its own — the authorize redirect_uris are NOT reused). A requested URI is
 * used only on an exact string match for the client the id_token_hint
 * verified for; everything else falls back to the completed page
 * (fail-closed). The default is empty, so no logout redirect happens until
 * you register one here.
 */
export const rpInitiatedLogoutConfig = {
  postLogoutRedirectUris: {} as Record<string, string[]>,
};
```

#### `features/rp-initiated-logout/cookies.ts`

This file builds and parses the cookie that ties the confirmation screen to the approve POST.
Every time the confirmation screen is rendered, a fresh random secret is handed to that one browser twice: in an HttpOnly cookie and in the form's hidden `csrf_token`.
An attacker can obtain a valid pair in their own browser but cannot place this cookie in the victim's browser, so a forged cross-site POST fails the comparison.

The cookie value has two parts joined by a dot: the secret and the base64url of the redirect target the OP resolved.
Because the redirect target travels in an HttpOnly cookie rather than a hidden field, the form cannot change it, and the `id_token_hint` never has to be written back into the page.
`parseLogoutConfirmation()` collapses every malformed shape into `null`, which the approve POST answers with 400, deleting nothing.
The cookie lives for 10 minutes (`Max-Age=600`), so an abandoned confirmation screen does not leave it behind for long.

```typescript
/**
 * EXPERIMENTAL — RP-Initiated Logout confirmation cookie
 * (RP-Initiated Logout 1.0 §2).
 *
 * Rendering the logout confirmation screen mints a fresh secret and hands it
 * to that one browser twice: in this HttpOnly cookie and in the form's hidden
 * csrf_token. POST /logout/approve runs only when both come back carrying the
 * same secret. An attacker can collect a valid pair in their own browser, but
 * cannot set this cookie in the victim's browser, so a forged cross-site POST
 * fails the comparison (and SameSite=Lax drops the cookie from a cross-site
 * POST to begin with). Neither half alone is ever accepted — the same model
 * as the device verification binding cookie of the device-authorization-grant
 * feature.
 *
 * The cookie also carries the OP-computed post-logout redirect target
 * (base64url of the exact registered URL, or empty when there is none), so
 * the redirect decision survives the confirmation round-trip inside an
 * HttpOnly channel instead of a tamperable hidden form field — and the
 * id_token_hint itself is never echoed into the page.
 */
export const LOGOUT_CONFIRMATION_COOKIE = 'oidc_logout_confirm';

/** What one rendered confirmation screen carries across to its approve POST. */
export interface LogoutConfirmation {
  /** Secret pairing the HttpOnly cookie with the form's hidden csrf_token. */
  csrfSecret: string;
  /** Registered redirect URL resolved at render time, or null for the completed page. */
  redirectTo: string | null;
}

export function buildLogoutConfirmationCookie(confirmation: LogoutConfirmation): string {
  const bytes = new TextEncoder().encode(confirmation.redirectTo ?? '');
  const binary = Array.from(bytes, (byte) => String.fromCharCode(byte)).join('');
  const encodedRedirect = btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  return (
    LOGOUT_CONFIRMATION_COOKIE + '=' + confirmation.csrfSecret + '.' + encodedRedirect +
    // 10 minutes: enough to read the screen and click, short enough that an
    // abandoned confirmation does not leave a long-lived pre-auth cookie.
    '; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=600'
  );
}

/** Clear the confirmation cookie once the approve POST consumed it. */
export function buildClearedLogoutConfirmationCookie(): string {
  return LOGOUT_CONFIRMATION_COOKIE + '=; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=0';
}

/**
 * Parse the confirmation cookie back. Returns null when the cookie is absent
 * or malformed in any way, which the approve POST answers with 400 and,
 * crucially, without deleting anything.
 */
export function parseLogoutConfirmation(cookieHeader: string | null): LogoutConfirmation | null {
  if (!cookieHeader) return null;
  let value: string | null = null;
  for (const part of cookieHeader.split(';')) {
    const trimmed = part.trim();
    const eq = trimmed.indexOf('=');
    if (eq === -1) continue;
    if (trimmed.slice(0, eq) === LOGOUT_CONFIRMATION_COOKIE) {
      value = trimmed.slice(eq + 1);
      break;
    }
  }
  if (value === null) return null;
  const dot = value.indexOf('.');
  if (dot === -1) return null;
  const csrfSecret = value.slice(0, dot);
  if (csrfSecret === '') return null;
  const encodedRedirect = value.slice(dot + 1);
  if (encodedRedirect === '') return { csrfSecret, redirectTo: null };
  if (!/^[A-Za-z0-9_-]+$/.test(encodedRedirect)) return null;
  try {
    const base64 = encodedRedirect.replace(/-/g, '+').replace(/_/g, '/');
    const padded = base64 + '='.repeat((4 - (base64.length % 4)) % 4);
    const bytes = Uint8Array.from(atob(padded), (char) => char.charCodeAt(0));
    return { csrfSecret, redirectTo: new TextDecoder().decode(bytes) };
  } catch {
    return null;
  }
}
```

#### `features/rp-initiated-logout/views.tsx`

This file holds the default hono/jsx implementations of the confirmation and completed screens and their parameter types.
The module augmentation adds `logoutConfirmationPage` and `logoutCompletedPage` to the base `Views` as optional members, and `logoutViews()` picks the replaced screen or the default one.
The confirmation screen's wording is the same whichever path led there (no hint, an invalid or expired hint, another user's session, no session).
The completed screen's parameter type `LogoutCompletedPageParams` is deliberately empty: the type fixes both that the screen shows no End-User or client identifier and that its wording never varies with whether anything was deleted (so it is no oracle for session state).

```tsx
/** @jsxImportSource hono/jsx */
/**
 * EXPERIMENTAL — the views of the RP-Initiated Logout screens
 * (RP-Initiated Logout 1.0 §2), in hono/jsx.
 *
 * They are members of Views (views.tsx), added below, so the views option of
 * createApp() / applyOidc() can replace them like the login and consent
 * views. A member left out falls back to the default of this file.
 */
import type { JSX } from 'hono/jsx/jsx-runtime';
import {
  Layout,
  type Views,
} from '../../views.js';

export interface LogoutConfirmationPageParams {
  /** CSRF token (must be included as hidden form field of the approve POST) */
  csrfToken: string;
}

/**
 * Parameters of the logged-out page. Deliberately empty: the completed screen
 * shows no End-User or client identifier (whoever sees the screen learns
 * nothing), and its wording never depends on whether anything was actually
 * deleted — varying it would make the page a session-existence oracle.
 */
export interface LogoutCompletedPageParams {}

declare module '../../views.js' {
  interface Views {
    /** EXPERIMENTAL (RP-Initiated Logout 1.0 §2): render the logout confirmation screen */
    logoutConfirmationPage?(params: LogoutConfirmationPageParams): ViewResult;
    /** EXPERIMENTAL (RP-Initiated Logout 1.0): render the logged-out screen */
    logoutCompletedPage?(params: LogoutCompletedPageParams): ViewResult;
  }
}

// RP-Initiated Logout 1.0 §2: the wording is fixed for every path into this
// screen (no hint, an invalid or expired hint, another user's session, no
// session at all), so the page cannot be used as an oracle for session state
// or for why the hint failed.
function defaultLogoutConfirmationPage(params: LogoutConfirmationPageParams): JSX.Element {
  return (
    <Layout title="Log out">
      <h1>Log out</h1>
      <p>Do you want to log out of the OpenID Provider?</p>
      <p>If you did not request this, close this page.</p>
      <form method="post" action="/logout/approve">
        <input type="hidden" name="csrf_token" value={params.csrfToken} />
        <button type="submit">Log out</button>
      </form>
    </Layout>
  );
}

function defaultLogoutCompletedPage(_params: LogoutCompletedPageParams): JSX.Element {
  return (
    <Layout title="Logged out">
      <h1>Logged out</h1>
      <p>You have been logged out.</p>
      <p>You can close this page.</p>
    </Layout>
  );
}

/** The views of the request for these screens: the ones the app replaced, else the defaults above. */
export function logoutViews(c: any): Required<Pick<Views, 'logoutConfirmationPage' | 'logoutCompletedPage'>> {
  const views: Partial<Views> = c.get('views') ?? {};
  return {
    logoutConfirmationPage: views.logoutConfirmationPage ?? defaultLogoutConfirmationPage,
    logoutCompletedPage: views.logoutCompletedPage ?? defaultLogoutCompletedPage,
  };
}
```

#### `features/rp-initiated-logout/endpoints/logout/page.tsx`

The Hono app `logoutPage` mounted at `/logout`, with three routes: `GET /`, `POST /` and `POST /approve`.
GET builds the `URLSearchParams` from the query and POST from the `application/x-www-form-urlencoded` body, and both hand them to the same `processEndSessionRequest()`.
`respond()` builds the response for each kind of `LogoutOutcome`.
A forged or expired confirmation is answered with the error page (400) rather than OAuth error JSON, because this is a screen the browser shows.
The confirmation and completed screens carry the cookies of the `LogoutOutcome`, and a redirect is a 302 with those cookies.
Since the steps build no `Response`, changing the logout UI means touching only this file or `views.tsx`; the deciding steps stay as they are.

```tsx
/** @jsxImportSource hono/jsx */
/**
 * EXPERIMENTAL — RP-Initiated Logout screens (RP-Initiated Logout 1.0 §2),
 * screen routing layer.
 *
 * The RP sends the user agent to GET|POST /logout; the browser then sees one
 * of three things: the confirmation screen, the logged-out screen, or a
 * redirect to the RP's registered post_logout_redirect_uri. Deciding which —
 * verifying id_token_hint, matching the session, resolving the redirect — is
 * the steps of steps/, processEndSessionRequest() and approveLogout() (one box
 * each of `maronn-oidc graph --detail steps --endpoint logout`); this file only
 * turns their outcome into HTTP, with the cookies the outcome carries. To
 * customize the logout UI, edit this file or the views in ../../views.tsx; the
 * steps never have to change. The confirmation form must keep
 * posting csrf_token to /logout/approve: it is paired with the HttpOnly cookie
 * the logic mints.
 *
 * Backed by @maronn-openid-connect/experimental, whose API is NOT stable.
 */
import { Hono } from 'hono';
import { renderErrorPage } from '../../../../pages/errors.js';
import { redirectWithCookies, withCookies } from '../../../../pages/respond.js';
import { renderView } from '../../../../views.js';
import {
  logoutViews,
  type LogoutCompletedPageParams,
  type LogoutConfirmationPageParams,
} from '../../views.js';
import type { LogoutOutcome } from './outcome.js';
import { approveLogout } from './steps/approve-logout.js';
import { processEndSessionRequest } from './steps/process-end-session-request.js';

export const logoutPage = new Hono<{ Variables: Record<string, any> }>();

/** Render the logout confirmation screen (§2 MUST when no valid hint is presented). */
export function renderLogoutConfirmationPage(
  c: any,
  params: LogoutConfirmationPageParams,
): Response {
  const views = logoutViews(c);
  return renderView(<views.logoutConfirmationPage {...params} />);
}

/** Render the logged-out screen. */
export function renderLogoutCompletedPage(c: any, params: LogoutCompletedPageParams): Response {
  const views = logoutViews(c);
  return renderView(<views.logoutCompletedPage {...params} />);
}

/** Turn the outcome of a logout step into the HTTP response. */
function respond(c: any, outcome: LogoutOutcome): Response {
  if (outcome.kind === 'invalid_confirmation') {
    // Forged, replayed or expired confirmation: nothing was deleted. This is a
    // browser surface, so the answer is the error page, not OAuth error JSON.
    return renderErrorPage(c, { error: 'Invalid logout confirmation', statusCode: 400 });
  }
  if (outcome.kind === 'confirmation') {
    return withCookies(
      renderLogoutConfirmationPage(c, { csrfToken: outcome.csrfToken }),
      outcome.cookies,
    );
  }
  if (outcome.kind === 'redirect') {
    // §3: the registered post_logout_redirect_uri, state already appended.
    return redirectWithCookies(outcome.location, outcome.cookies);
  }
  return withCookies(renderLogoutCompletedPage(c, {}), outcome.cookies);
}

/** end_session_endpoint - GET (§2: the OP MUST support GET and POST). */
logoutPage.get('/', async (c) =>
  respond(c, await processEndSessionRequest(c, new URL(c.req.url).searchParams)),
);

/** end_session_endpoint - POST, application/x-www-form-urlencoded body (§2). */
logoutPage.post('/', async (c) => {
  const body = await c.req.parseBody();
  const params = new URLSearchParams();
  for (const [key, value] of Object.entries(body)) {
    if (typeof value === 'string') {
      params.append(key, value);
    }
  }
  return respond(c, await processEndSessionRequest(c, params));
});

/** Confirmation approve - POST */
logoutPage.post('/approve', async (c) => {
  const body = await c.req.parseBody();
  return respond(c, await approveLogout(c, String(body['csrf_token'] ?? '')));
});
```

#### `features/rp-initiated-logout/endpoints/logout/endpoint.ts`

The description `maronn-oidc graph` draws the endpoint from.
It is a `layer: 'browser'` endpoint whose two steps are not chained in a straight line (`chain: false`); they are connected only by the branch through the confirmation screen.
As a screen endpoint it is `rearrangeable: false`: `--flow` neither removes nor reorders its steps.
`journeys` puts on the diagram how an ID Token issued at the token endpoint arrives here as `id_token_hint`.

```typescript
import { defineEndpoint } from '../../../../endpoints/step.js';

/** EXPERIMENTAL — the end session endpoint. RP-Initiated Logout 1.0 §2 */
export const endpoint = defineEndpoint({
  id: 'logout',
  order: 170,
  label: 'End session endpoint',
  path: '/logout',
  methods: ['GET', 'POST'],
  layer: 'browser',
  group: { id: 'logout', label: 'RP-Initiated Logout 1.0' },
  spec: 'RP-Initiated Logout 1.0 §2',
  feature: 'rp-initiated-logout',
  rearrangeable: false,
  steps: [
    'process-end-session-request',
    'approve-logout',
  ],
  edges: {
    chain: false,
    extra: [
      { from: 'process-end-session-request', to: 'approve-logout', label: 'confirmation screen', kind: 'branch' },
    ],
  },
  journeys: [
    { from: 'token', to: 'logout', label: 'id_token_hint', kind: 'flow', order: 170 },
  ],
});
```

#### `features/rp-initiated-logout/endpoints/logout/outcome.ts`

The type `LogoutOutcome` that the steps hand to `page.tsx`.
The opening comment explains the endpoint's behavior (an immediate logout only when a valid hint matches the End-User of the current session, the same confirmation screen for everything else) and why the approve POST requires the cookie and token pair.

```typescript
/**
 * EXPERIMENTAL — OpenID Connect RP-Initiated Logout 1.0, end_session_endpoint
 * — API layer: logic only.
 *
 * This module was generated because the OP was created with
 * `--enable rp-initiated-logout`. It is backed by
 * @maronn-openid-connect/experimental, whose API is NOT stable: it may change in a breaking
 * way between releases. Do not build production code on it without pinning the
 * version.
 *
 * The RP sends the user agent to /logout (GET or POST, §2 MUST) to end the OP
 * browser session. A request whose id_token_hint verifies against this OP's
 * keys AND matches the current session's End-User logs out immediately; every
 * other request — no hint, an invalid or expired hint, a client_id that
 * mismatches the hint audience, no session, another user's session — falls to
 * one shared confirmation screen (§2 MUST; §7: an unauthenticated logout link
 * would otherwise be a denial-of-service primitive). The failure reason is
 * never disclosed anywhere: a reason would turn this endpoint into an oracle
 * for session state.
 *
 * Neither step of steps/ builds a Response: each returns an outcome (which
 * screen or redirect comes next, with which cookies), and page.tsx — which
 * owns the GET and POST routes — turns it into HTTP.
 *
 * ## Why the confirmation approve step demands a cookie + token pair
 *
 * The approve POST ends a session, so a forged cross-site POST must not drive
 * it. When the confirmation screen is shown the OP mints a fresh secret and
 * hands it to that one browser twice: in an HttpOnly cookie and in the form's
 * hidden csrf_token. approveLogout() runs only when both come back equal. An
 * attacker can obtain a valid pair in their own browser but cannot plant that
 * cookie into the victim's, so the forged POST fails the comparison — the
 * same model as the device verification binding cookie of the
 * device-authorization-grant feature.
 *
 * The cookie also carries the OP-computed post-logout redirect target, so the
 * confirmation flow never round-trips the id_token_hint (or any redirect
 * parameter) through the HTML page: the only value the form submits back is
 * the csrf_token itself.
 */

/** What a logout step decided; page.tsx turns it into HTTP. */
export type LogoutOutcome =
  /** Forged, replayed or expired confirmation: nothing was deleted (400). */
  | { kind: 'invalid_confirmation' }
  /** §2 MUST: ask first. cookies pairs the HttpOnly secret with the form's csrf_token. */
  | { kind: 'confirmation'; csrfToken: string; cookies: string[] }
  /** Logged out; §3: return to the registered post_logout_redirect_uri (state appended). */
  | { kind: 'redirect'; location: string; cookies: string[] }
  /** Logged out; no registered redirect applied, so show the completed screen. */
  | { kind: 'completed'; cookies: string[] };
```

#### `features/rp-initiated-logout/endpoints/logout/steps/process-end-session-request.ts`

The step that `GET` and `POST /logout` call.
When an `id_token_hint` is present, the expected audience is the `client_id` parameter, or, without one, the audience extracted from the unverified hint payload, and `validateIdTokenHint()` verifies the signature, iss, aud and exp.
The key set is the same `jwksProvider` that id_token_hint uses everywhere else.
An `IdTokenHintError` only means the hint failed to prove logout authority, so it becomes `null`, the request goes to the confirmation screen, and the reason is disclosed nowhere.
Any other exception (such as a failure of the JWKS provider itself) is rethrown.
Masking an outage as an invalid hint would silently turn every logout into a confirmation.

The redirect target is resolved with `resolvePostLogoutRedirect()` before the branch.
The confirmation path uses the same result after approval: the redirect condition is the hint and the exact match against the registry, not which path the logout took.
When confirmation is required, the step deletes nothing, mints a secret and returns the confirmation outcome; for an immediate logout it deletes the session store entry and clears the cookie.
`logout_hint` and `ui_locales` are accepted but not used, and never logged.

```typescript
import {
  decideLogoutFlow,
  extractIdTokenHintAudience,
  parseEndSessionRequest,
  resolvePostLogoutRedirect,
} from '@maronn-openid-connect/experimental/rp-initiated-logout';
import {
  IdTokenHintError,
  generateRandomString,
  validateIdTokenHint,
} from '@maronn-openid-connect/core';
import { buildClearedSessionCookie, parseSessionId } from '../../../../../cookies.js';
import { buildLogoutConfirmationCookie } from '../../../cookies.js';
import type { LogoutOutcome } from '../outcome.js';
import { step } from '../../../../../endpoints/step.js';
import { rpInitiatedLogoutConfig } from '../../../config.js';

export const meta = step({
  id: 'process-end-session-request',
  endpoint: 'logout',
  feature: 'rp-initiated-logout',
  kind: 'decide',
  label: 'Verify id_token_hint and decide: log out or confirm',
  spec: 'RP-Initiated Logout 1.0 §2 / §3',
  function: 'processEndSessionRequest',
  calls: ['parseEndSessionRequest', 'extractIdTokenHintAudience', 'validateIdTokenHint', 'decideLogoutFlow', 'resolvePostLogoutRedirect'],
  consumes: [],
  produces: ['confirmation'],
  removable: false,
});

/**
 * Interpret one end_session request (§2). GET and POST share this function —
 * they differ only in where the parameters come from.
 */
export async function processEndSessionRequest(c: any, params: URLSearchParams): Promise<LogoutOutcome> {
  const browserSessionStore = c.get('browserSessionStore');
  const config = c.get('config');
  const request = parseEndSessionRequest(params);
  // logout_hint and ui_locales are accepted but unused (OPTIONAL, §2): the
  // hint is not read past parsing and is never logged — it can identify the
  // End-User. The same goes for the id_token_hint value itself.

  // §2: verify the hint (signature / iss / aud / exp) against the same key
  // set id_token_hint uses elsewhere (context jwksProvider). The expected
  // audience is the client_id parameter when present, otherwise it is
  // extracted — unverified — from the hint payload; trust comes from
  // validateIdTokenHint afterwards.
  let verifiedHint: { sub: string; [key: string]: unknown } | null = null;
  let expectedAudience: string | null = null;
  if (request.idTokenHint !== undefined) {
    expectedAudience = request.clientId ?? extractIdTokenHintAudience(request.idTokenHint);
    if (expectedAudience !== null) {
      try {
        const jwks = await c.get('jwksProvider')();
        verifiedHint = await validateIdTokenHint(request.idTokenHint, {
          expectedIss: config.issuer,
          expectedAud: expectedAudience,
          jwks,
        });
      } catch (error) {
        // An expired, tampered or foreign hint is not an error to report — it
        // just fails to prove logout authority, so the request falls to the
        // confirmation path (§2 MUST) with no reason disclosed. Anything that
        // is not a hint-validation failure (e.g. the JWKS provider itself
        // failing) is rethrown: masking an outage as "invalid hint" would
        // silently degrade every logout into a confirmation.
        if (!(error instanceof IdTokenHintError)) throw error;
        verifiedHint = null;
      }
    }
  }

  const sessionId = parseSessionId(c.req.header('Cookie') ?? null);
  const session = sessionId ? await browserSessionStore.get(sessionId) : undefined;

  const decision = decideLogoutFlow({
    verifiedHint,
    expectedAudience,
    clientIdParam: request.clientId,
    sessionSubject: session ? session.subject : null,
  });

  // §3: redirect only to the verified client's exactly-matching registered
  // URI, with state appended. Resolved before the branch because the
  // confirmation flow honors the same result after approval — the redirect
  // condition is the hint and the exact match, not which path the logout took.
  const redirectTo = resolvePostLogoutRedirect({
    postLogoutRedirectUri: request.postLogoutRedirectUri,
    state: request.state,
    verifiedClientId: decision.verifiedClientId,
    registeredUris:
      decision.verifiedClientId === null
        ? []
        : rpInitiatedLogoutConfig.postLogoutRedirectUris[decision.verifiedClientId] ?? [],
  });

  if (decision.requiresConfirmation) {
    // §2 MUST. Nothing is deleted here, and the screen's wording never varies
    // with session state. The minted secret pairs the HttpOnly cookie with the
    // form's hidden csrf_token; the redirect target rides inside the cookie.
    const csrfSecret = generateRandomString(32);
    return {
      kind: 'confirmation',
      csrfToken: csrfSecret,
      cookies: [buildLogoutConfirmationCookie({ csrfSecret, redirectTo })],
    };
  }

  // Immediate logout: a valid hint for the current session's End-User (§2).
  // Delete the store entry and expire the cookie together.
  if (sessionId) {
    await browserSessionStore.delete(sessionId);
  }
  const cookies = [buildClearedSessionCookie()];
  if (redirectTo !== null) {
    return { kind: 'redirect', location: redirectTo, cookies };
  }
  return { kind: 'completed', cookies };
}
```

#### `features/rp-initiated-logout/endpoints/logout/steps/approve-logout.ts`

The step `POST /logout/approve` calls.
It parses the confirmation cookie, and when its secret does not equal the form's `csrf_token`, it returns `invalid_confirmation` without deleting anything.
Comparing first and deleting after means a forged POST never touches a session.
On a match it deletes the session if there is one, clears both the session cookie and the confirmation cookie, and returns to the redirect target put into the cookie when the confirmation screen was rendered, or to the completed screen.
The answer is the same when the session is already gone, so the confirmation flow is no oracle for whether a session existed.

```typescript
import { buildClearedLogoutConfirmationCookie, parseLogoutConfirmation } from '../../../cookies.js';
import { buildClearedSessionCookie, parseSessionId } from '../../../../../cookies.js';
import type { LogoutOutcome } from '../outcome.js';
import { step } from '../../../../../endpoints/step.js';

export const meta = step({
  id: 'approve-logout',
  endpoint: 'logout',
  feature: 'rp-initiated-logout',
  kind: 'persist',
  label: 'Confirmed: end the session',
  spec: 'RP-Initiated Logout 1.0 §2',
  function: 'approveLogout',
  calls: ['parseLogoutConfirmation', 'buildClearedSessionCookie'],
  consumes: ['confirmation'],
  produces: [],
  removable: false,
});

/**
 * Confirmation approve (POST /logout/approve)
 *
 * Runs only for the browser that saw the confirmation screen: the HttpOnly
 * cookie and the hidden csrf_token must present the same secret (neither
 * alone is accepted). On success the session is deleted and the redirect
 * decision computed when the screen was shown — carried in the cookie, never
 * in the form — is honored (§3).
 */
export async function approveLogout(c: any, csrfToken: string): Promise<LogoutOutcome> {
  const browserSessionStore = c.get('browserSessionStore');

  const confirmation = parseLogoutConfirmation(c.req.header('Cookie') ?? null);
  if (confirmation === null || csrfToken === '' || confirmation.csrfSecret !== csrfToken) {
    // Forged, replayed or expired confirmation: delete nothing.
    return { kind: 'invalid_confirmation' };
  }

  // The End-User explicitly approved (§2). When the session is already gone
  // there is nothing to delete and the answer is the same either way — the
  // confirmation flow is not an oracle for whether a session existed.
  const sessionId = parseSessionId(c.req.header('Cookie') ?? null);
  if (sessionId) {
    await browserSessionStore.delete(sessionId);
  }
  const cookies = [buildClearedSessionCookie(), buildClearedLogoutConfirmationCookie()];
  if (confirmation.redirectTo !== null) {
    return { kind: 'redirect', location: confirmation.redirectTo, cookies };
  }
  return { kind: 'completed', cookies };
}
```

### The other frameworks

The Express and Fastify output has the same files.
The generator replaces the `hono` imports of the endpoints with `web-router.ts` (a small router on the Fetch API, with `WebRouter` and `WebContext`) and adds the framework's `apply.ts`, `web-router.ts` and `node-adapter.ts`.
Their source is [apps/hono/src/web/](https://github.com/maronnjapan/maronn-openid-connect/tree/main/apps/hono/src/web), and [packages/cli/extract.json](https://github.com/maronnjapan/maronn-openid-connect/blob/main/packages/cli/extract.json) defines which file goes where.
In this feature only the router of `endpoints/logout/page.tsx` is replaced (`new Hono<...>()` becomes `new WebRouter()`); no other file imports the `hono` router.
The screens of `views.tsx` and `page.tsx` stay hono/jsx, so the Express and Fastify output still needs `hono` as its JSX runtime.

The Next.js output is extracted from [apps/nextjs](https://github.com/maronnjapan/maronn-openid-connect/tree/main/apps/nextjs), a Next.js App Router app.
The feature's route files go into the route group `app/(rp-initiated-logout)/` and its code into `app/_oidc-provider/features/rp-initiated-logout/`.
The code of Express, Fastify and Next.js is not embedded in this guide.

### The sample and registry injection

`samples/hono-cloudflare` is generated with `--enable rp-initiated-logout`, and its hand-written entry `src/app.ts` imports `rpInitiatedLogoutConfig` from the generated `features/rp-initiated-logout/config.ts`:

```typescript
import { rpInitiatedLogoutConfig } from './oidc-provider/features/rp-initiated-logout/config.js';
```

Before it calls `applyOidc()`, it injects `rpInitiatedLogoutConfig.postLogoutRedirectUris` from the `OIDC_POST_LOGOUT_REDIRECT_URIS_JSON` environment variable.
With the variable unset, the empty registry of the generated code stays.

```typescript
// EXPERIMENTAL (RP-Initiated Logout 1.0 §3): the per-client registry of
// post_logout_redirect_uri values, as JSON ({ [clientId]: string[] }). With
// the var unset the generated fail-closed default stays: every logout ends on
// the OP's completed page and no redirect happens.
if (bindings.OIDC_POST_LOGOUT_REDIRECT_URIS_JSON) {
  rpInitiatedLogoutConfig.postLogoutRedirectUris = JSON.parse(
    bindings.OIDC_POST_LOGOUT_REDIRECT_URIS_JSON,
  ) as Record<string, string[]>;
}
```

For E2E, `tests/e2e/playwright.config.ts` registers the E2E client's `/logged-out` page through that variable when it starts the OP:

```typescript
        // EXPERIMENTAL (RP-Initiated Logout 1.0 §3): register the E2E client's
        // post-logout return page. A sample OP generated without the feature
        // ignores the variable; the logout spec skips itself via discovery.
        OIDC_POST_LOGOUT_REDIRECT_URIS_JSON: JSON.stringify({
          'e2e-client': [`${clientBaseURL}/logged-out`],
        }),
```

## E2E test, in full

Two Playwright scenarios cover the full logout round trip in a real browser.
The first is the immediate logout with a hint and a registered URI (returning to the RP with `state`, after which a fresh authorization lands on the login screen); the second goes through the confirmation screen without a hint.
Both verify that the session is really gone by starting another authorization after logout and expecting the login screen.

```typescript
import { expect, test, type APIRequestContext, type Page } from '@playwright/test';

const host = process.env.E2E_HOST ?? '127.0.0.1';
const clientPort = Number(process.env.E2E_CLIENT_PORT ?? '3020');
const clientBaseURL =
  process.env.E2E_CLIENT_BASE_URL ?? `http://${host}:${clientPort}`;
const postLogoutRedirectUri = `${clientBaseURL}/logged-out`;

/**
 * EXPERIMENTAL — OpenID Connect RP-Initiated Logout 1.0, end-to-end.
 *
 * The OP under test is a CLI-generated sample started with
 * `--enable rp-initiated-logout` and the E2E client registered in
 * OIDC_POST_LOGOUT_REDIRECT_URIS_JSON (playwright.config.ts). Both scenarios
 * verify the session is really gone by starting a fresh authorization and
 * expecting the login screen instead of SSO.
 */
test.describe('RP-Initiated Logout (RP-Initiated Logout 1.0)', () => {
  test('should log out through the RP link and return with state, ending SSO', async ({
    page,
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    await skipUnlessLogoutEnabled(request, issuer);

    const idToken = await completeAuthorizationCodeFlow(page, issuer);

    // §2: the RP hands the browser to the end_session_endpoint with the ID
    // Token it holds as the hint. Valid hint + matching session: no
    // confirmation screen, immediate logout, §3 redirect with state echoed.
    await page.goto(
      `${issuer}/logout?id_token_hint=${encodeURIComponent(idToken)}` +
        `&post_logout_redirect_uri=${encodeURIComponent(postLogoutRedirectUri)}` +
        '&state=e2e-logout-state',
    );
    await expect(page).toHaveURL(`${postLogoutRedirectUri}?state=e2e-logout-state`);
    await expect(page.getByTestId('logged-out-state')).toHaveText('e2e-logout-state');

    await expectLoginRequired(page, issuer);
  });

  test('should require an explicit confirmation when no hint is presented', async ({
    page,
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    await skipUnlessLogoutEnabled(request, issuer);

    await completeAuthorizationCodeFlow(page, issuer);

    // §2 MUST: without a valid id_token_hint the OP asks first. Nothing is
    // deleted until the user approves the confirmation form.
    await page.goto(`${issuer}/logout`);
    await expect(page).toHaveURL(`${issuer}/logout`);
    await expect(page.getByRole('heading', { name: 'Log out' })).toBeVisible();

    await page.getByRole('button', { name: 'Log out' }).click();
    await expect(page.getByRole('heading', { name: 'Logged out' })).toBeVisible();

    await expectLoginRequired(page, issuer);
  });
});

/** Skip on a sample OP generated without --enable rp-initiated-logout. */
async function skipUnlessLogoutEnabled(
  request: APIRequestContext,
  issuer: string,
): Promise<void> {
  const response = await request.get(`${issuer}/.well-known/openid-configuration`);
  expect(response.status()).toBe(200);
  const metadata = await response.json() as { end_session_endpoint?: string };
  test.skip(
    metadata.end_session_endpoint === undefined,
    'This sample OP was generated without --enable rp-initiated-logout',
  );
  expect(metadata.end_session_endpoint).toBe(`${issuer}/logout`);
}

/**
 * Drive the ordinary code flow through the E2E client and return the issued
 * ID Token (the id_token_hint of the logout scenarios).
 */
async function completeAuthorizationCodeFlow(page: Page, issuer: string): Promise<string> {
  await page.goto(`${clientBaseURL}/start`);
  await expect(page).toHaveURL(new RegExp(`^${escapeRegExp(issuer)}/login\\?transaction_id=`));
  await page.getByLabel('Username:').fill('testuser');
  await page.getByLabel('Password:').fill('password');
  await page.getByRole('button', { name: 'Login' }).click();

  // A prior spec (or the first scenario) may have recorded consent for this
  // subject and client, in which case the consent screen is skipped.
  await page.waitForURL(/\/(consent|callback)\?/);
  if (new URL(page.url()).pathname === '/consent') {
    await page.getByRole('button', { name: 'Approve' }).click();
  }
  await expect(page).toHaveURL(new RegExp(`^${escapeRegExp(clientBaseURL)}/callback\\?`));

  const idToken = (await page.getByTestId('token-id-token').textContent())?.trim() ?? '';
  expect(idToken.split('.')).toHaveLength(3);
  return idToken;
}

/** A fresh authorization must land on the login screen: the SSO session is gone. */
async function expectLoginRequired(page: Page, issuer: string): Promise<void> {
  await page.goto(`${clientBaseURL}/start`);
  await expect(page).toHaveURL(new RegExp(`^${escapeRegExp(issuer)}/login\\?transaction_id=`));
}

function requireBaseUrl(baseURL: string | undefined): string {
  if (!baseURL) throw new Error('Playwright baseURL is not configured');
  return baseURL.replace(/\/$/, '');
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}
```

## References

- [OpenID Connect RP-Initiated Logout 1.0](https://openid.net/specs/openid-connect-rpinitiated-1_0.html) (Final, 2022-09-12)
- [RFC 6749 §10.15: Open Redirectors](https://www.rfc-editor.org/rfc/rfc6749#section-10.15)
- User-facing documentation: [docs/library-document/src/content/docs/experimental/rp-initiated-logout.md](https://github.com/maronnjapan/maronn-openid-connect/blob/main/docs/library-document/src/content/docs/experimental/rp-initiated-logout.md)
- Specification task (with the three review records): `tasks/experimental/done/rp-initiated-logout/` in the notes repository
