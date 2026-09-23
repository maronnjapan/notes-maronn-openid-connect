# RP-Initiated Logout（OpenID Connect RP-Initiated Logout 1.0）実装解説

この文書は、`packages/experimental` に実装した **OpenID Connect RP-Initiated Logout 1.0**（Final、2022 年 9 月発行）について、何を実装したのか、どう実装したのかを、関連するコードの全文とともに説明する。

この文書が全文を載せるのは次のコードである。

- `packages/experimental/src/rp-initiated-logout/` の実装 4 ファイルとテスト 3 ファイルのすべて
- CLI の `--enable rp-initiated-logout` が生成コードへ注入するコードの全文（hono）
- この機能の E2E テストスペックの全文

core 本体、E2E 共有ハーネス、他フレームワークの生成差分は全機能で共有される基盤なので、リンクで参照する。

## 機能の概要

この OP はログインと同意を実装しているが、既定の生成物にはログアウトの経路が無い。
End-User が RP からログアウトしても OP のブラウザセッションは残り続け、次の認可リクエストは再認証なしで通る。
SSO 構成の検証では「ログアウトが要件どおり動くか」がログインと同じ重みで問われるため、この空白は「自分の要件がこの仕様で実現できるか」を検証するという本ライブラリのコンセプトに対する欠落だった。

RP-Initiated Logout 1.0 は、RP がユーザーエージェントごと OP へ遷移させてセッションを終了させる **end_session_endpoint** を定義する仕様である。
ログアウト系 4 仕様（RP-Initiated / Session Management / Front-Channel / Back-Channel）のうち、RP-Initiated だけが RP から OP への一方向で完結し、他の 3 つは OP から RP への通知チャネルを必要とする。
この非対称が、RP-Initiated だけを experimental の 1 機能として切り出せる理由になっている。

```text
RP                                     OP（生成コード + experimental/rp-initiated-logout + core）
 |                                       |
 |-- GET /logout ----------------------->| (1) パラメータ解釈（GET query / POST form 両対応。§2 MUST）
 |   ?id_token_hint=...                  | (2) id_token_hint 検証: core validateIdTokenHint
 |   &post_logout_redirect_uri=...       | (3) client_id パラメータがあれば aud との一致検証（§2 MUST）
 |   &state=...                          | (4) ヒントの sub と現在セッションの subject を照合
 |                                       |
 |          [有効なヒント + セッション一致]  | (5a) セッション削除 + Cookie 破棄
 |<- 302 post_logout_redirect_uri?state= | (6a) 登録値と完全一致すれば state 付きでリダイレクト（§3）
 |                                       |
 |          [ヒントなし / 無効 / 不一致]    | (5b) 確認画面を表示（§2 MUST。何も消さない）
 |                                       | (6b) 承認の POST で初めてセッション削除
```

有効な `id_token_hint` が現在のセッションの End-User を指す場合だけ即時にログアウトし、それ以外の要求はすべて同じ確認画面に落ちる。
仕様が確認を要求する（§2 MUST）のは、確認なしのログアウトエンドポイントが「リンクを踏ませるだけで被害者のセッションを終了させる」DoS の道具になるためである（§7）。

### ユースケース

- SSO 構成の PoC で、RP のログアウトボタンから OP セッション終了までの全周を検証する
- `post_logout_redirect_uri` の登録運用と完全一致検証の挙動（未登録 URI、部分一致、クエリ差分で何が起きるか）を手元で確認する
- ログアウト後の `prompt=none` の失敗（`login_required`）や online refresh token の失効など、セッション終了の波及を検証する

### 実装スコープと非目標

実装したのは次の範囲である。

- `GET|POST /logout`（§2 MUST の両メソッド受理）と、確認画面の承認先 `POST /logout/approve`
- `id_token_hint` の検証（core 公開の `validateIdTokenHint` をそのまま使用）と、確認画面への fail-closed 分岐
- 登録値との完全一致によるリダイレクトと `state` の返却（§3）
- discovery への `end_session_endpoint` の公表（§2.1）

非目標は次のとおりである。

- Session Management 1.0（`check_session_iframe` / `session_state`）と Front-Channel / Back-Channel Logout。他 RP への伝播は行わず、`sid` クレームも発行しない
- 期限切れ `id_token_hint` の受理（§2 の SHOULD）。core の `validateIdTokenHint` は `exp` 超過を拒否するため、期限切れヒントは無効なヒントとして確認画面の経路に落とす。確認を経ればログアウト自体は完了できるので、安全側の不採用である
- `logout_hint` / `ui_locales` の解釈。どちらも受理するが動作を変えない（OPTIONAL）
- 発行済みトークンの後始末。消えるのはセッションと、その帰結として使えなくなる online refresh token だけで、offline refresh token とアクセストークンの失効は revocation（RFC 7009）の責務のまま残る

## 実装の設計方針

実装は判定と実行を分けている。
experimental パッケージ側は、HTTP にもセッションストアにも触れない純関数群（リクエストの正規化、ヒント audience の抽出、ログアウト分岐の判定、リダイレクト先の解決）だけを持つ。
セッションの実体（`session_id` Cookie と browser session store）は従来から生成コードの責務であり、削除もその既存 `delete` を呼ぶだけにした。
判定を純関数に閉じ込めれば単体テストで網羅でき、将来 core へ昇格させるときも（調査資料の方針 A が想定する「core にログアウト要求検証の純関数を置く」形へ）そのまま移植できる。

core への変更は無い。
core から使うのは公開 API の `validateIdTokenHint` / `IdTokenHintError` / `generateRandomString` だけで、ヒント検証の鍵セットも生成コードが常に配線している `jwksProvider`（既定は OP 自身の ID Token 署名鍵）をそのまま使う。
この機能はセッション基盤と鍵基盤がどのビルドにも存在することに乗るだけなので、他機能への依存も組み合わせ制約も無い。

もう一つの設計判断は、確認画面をまたぐ状態の運び方である。
確認画面から承認 POST までの間、リダイレクトしてよい先をどこかに保持しなければならないが、hidden フィールドに書けば改ざんでき、`id_token_hint` を書き戻せばトークン値が HTML に露出する。
この実装は、確認画面の描画時に発行する CSRF cookie（HttpOnly）に OP が確定したリダイレクト先を同乗させ、フォームが送り返すのは対になる乱数シークレットだけにした。
新しいストア契約を増やさずに、ページへ書き戻す情報を CSRF トークン 1 つに抑えられる。

## 実装コードの全文と解説

### request.ts（リクエストの正規化と audience 抽出）

`parseEndSessionRequest` は §2 の 6 パラメータを URLSearchParams から正規化する。
GET はクエリ、POST はフォームボディと入口が分かれるが、どちらも URLSearchParams にしてから渡す設計にして、正規化の規則（重複は最初の値、空文字は値なし）を一箇所に固定した。

`extractIdTokenHintAudience` は、`client_id` パラメータの無いリクエストで検証に使う期待 audience をヒント自身から特定する。
これは署名検証**前**の復号であり、返り値は「この aud で検証を試みる」という候補にすぎない（信頼は後段の `validateIdTokenHint` が与える）。
aud 配列時の `azp` フォールバックは防御的分岐ではない。
core の `buildIdTokenAudience` は追加 audience が構成されると `aud` を配列にして `azp` を必ず付与するため、自 OP 発行の ID Token でもこの経路を通る。

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

### decision.ts（ログアウト分岐の判定）

`decideLogoutFlow` は §2 の MUST をそのまま分岐にした純関数である。
即時ログアウトの条件は「ヒントが有効」「セッションが存在」「ヒントの `sub` がセッションの subject と一致」の 3 つがすべて成り立つ場合だけで、それ以外はすべて確認画面に落ちる。
落ちた理由を返さないのは、理由の差がセッション状態のオラクルになるためで、呼び出し側（生成コード）も画面に出さない前提である。

`client_id` パラメータと期待 audience の不一致（§2 MUST 違反）は、確認画面に落とすだけでなく `verifiedClientId` も null にする。
ヒント全体を無効として扱うことで、§3 のリダイレクト権限も同時に失わせるためである。
一方、セッション不在や `sub` 不一致で確認画面に落ちた場合はヒント自体は有効なので、`verifiedClientId` を保持する。
リダイレクトの条件（§3）はヒントの供給と登録値の完全一致であり、確認画面の経由有無ではないからである。

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

### redirect.ts（リダイレクト先の解決）

`resolvePostLogoutRedirect` は §3 の MUST NOT の裏返しをそのまま実装する。
完全一致は文字列比較で、正規化も前方一致もクエリ無視もしない（authorize の `redirect_uri` 検証と同じ判断。RFC 6749 §10.15）。
`state` は URL API のクエリ付加でのみ出力するので、URL エンコードを通らずに応答へ出る経路が無い。

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

### index.ts（公開 API）

subpath export `@maronn-openid-connect/experimental/rp-initiated-logout` の入口である。
エラークラスは公開しない。
各関数は入力が契約を満たす限り失敗せず、判定の否定は戻り値の null / `requiresConfirmation` で表す。

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

## 単体テストの全文

t_wada 流の TDD で、テストを先に書いて red を確認してから実装した。
`parseEndSessionRequest` の正規化規則、`extractIdTokenHintAudience` の aud 形ごとの分岐と不正入力、`decideLogoutFlow` の全分岐、`resolvePostLogoutRedirect` の fail-closed 各条件を固定している。

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

## CLI 統合と生成コードへの寄与

`maronn-oidc generate <framework> --enable rp-initiated-logout` を指定すると、生成コードに次が入る。

- **routes/logout.ts（新規）**：`GET|POST /logout` と `POST /logout/approve` の 3 ルートと、設定オブジェクト `rpInitiatedLogoutConfig`
- **store.ts の追記**：確認画面の CSRF cookie ヘルパーと、セッション Cookie を破棄する Set-Cookie ビルダー
- **views.ts の追記**：確認画面と完了画面（`views` オプションで差し替え可能）
- **routes/discovery.ts の追記**：`end_session_endpoint` メタデータ
- **app.ts の追記**：メソッドガードへの 2 パス登録とルートのマウント
- **conformance.test.ts の追記**：ログアウト経路の契約テスト

機能を有効にしない生成コードは、変更前の CLI とバイト単位で同一である（解決済みフィーチャー構成の全キーを記録する生成マニフェスト `.maronn-openid-connect.json` にだけ、`rpInitiatedLogout: false` のキーが増える）。
無効時の契約（`/logout` が存在しないこと、discovery に `end_session_endpoint` が無いこと）は、CLI のジェネレータテスト `packages/cli/src/__tests__/rp-initiated-logout-feature.test.ts` が固定している。

### routes/logout.ts（新規ファイル全文）

ルートは判定を experimental の純関数と core の `validateIdTokenHint` に寄せ、自分では HTTP の入出力と Cookie、ストアの `delete` だけを行う。
承認 POST の検証順序（cookie とトークンの対の照合が先、削除は後）と、リダイレクト先を cookie 側で運ぶ設計は、ファイル冒頭のコメントに理由ごと書いてある。

```typescript
/**
 * EXPERIMENTAL — OpenID Connect RP-Initiated Logout 1.0, end_session_endpoint.
 *
 * This route was generated because the OP was created with
 * `--enable rp-initiated-logout`. It is backed by
 * @maronn-openid-connect/experimental, whose API is NOT stable: it may change in a breaking
 * way between releases. Do not build production code on it without pinning the
 * version.
 *
 * The RP sends the user agent here (GET or POST, §2 MUST) to end the OP
 * browser session. A request whose id_token_hint verifies against this OP's
 * keys AND matches the current session's End-User logs out immediately; every
 * other request — no hint, an invalid or expired hint, a client_id that
 * mismatches the hint audience, no session, another user's session — falls to
 * one shared confirmation screen (§2 MUST; §7: an unauthenticated logout link
 * would otherwise be a denial-of-service primitive). The failure reason is
 * never disclosed anywhere: a reason would turn this endpoint into an oracle
 * for session state.
 *
 * ## Why the confirmation approve step demands a cookie + token pair
 *
 * The approve POST ends a session, so a forged cross-site POST must not drive
 * it. When the confirmation screen is rendered the OP mints a fresh secret and
 * hands it to that one browser twice: in an HttpOnly cookie and in the form's
 * hidden csrf_token. /logout/approve runs only when both come back equal. An
 * attacker can obtain a valid pair in their own browser but cannot plant that
 * cookie into the victim's, so the forged POST fails the comparison — the
 * same model as the device verification binding cookie (see store.ts).
 *
 * The cookie also carries the OP-computed post-logout redirect target, so the
 * confirmation flow never round-trips the id_token_hint (or any redirect
 * parameter) through the HTML page: the only value the form submits back is
 * the csrf_token itself.
 */
import { Hono } from 'hono';
import {
  decideLogoutFlow,
  extractIdTokenHintAudience,
  parseEndSessionRequest,
  resolvePostLogoutRedirect,
} from '@maronn-openid-connect/experimental/rp-initiated-logout';
import { IdTokenHintError, generateRandomString, validateIdTokenHint } from '@maronn-openid-connect/core';
import {
  browserSessionStore as defaultBrowserSessionStore,
  buildClearedLogoutConfirmationCookie,
  buildClearedSessionCookie,
  buildLogoutConfirmationCookie,
  parseLogoutConfirmation,
  parseSessionId,
} from '../store.js';
import { defaultProviderConfig } from '../config.js';
import { defaultViews, renderView } from '../views.js';

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

export const logoutApp = new Hono<{ Variables: Record<string, any> }>();

/**
 * Attach Set-Cookie headers to a Response a view already produced.
 * renderView() builds its own Response, so headers staged on the framework
 * context never reach it (same helper as the device verification UI).
 */
function withCookies(response: Response, cookies: string[]): Response {
  const headers = new Headers(response.headers);
  for (const cookie of cookies) {
    headers.append('Set-Cookie', cookie);
  }
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

/** 302 to the registered post_logout_redirect_uri, with cookies attached. */
function redirectResponse(location: string, cookies: string[]): Response {
  const headers = new Headers({ Location: location });
  for (const cookie of cookies) {
    headers.append('Set-Cookie', cookie);
  }
  return new Response(null, { status: 302, headers });
}

/**
 * Interpret one end_session request (§2) and answer it. GET and POST share
 * this handler — they differ only in where the parameters come from.
 */
async function handleEndSessionRequest(c: any, params: URLSearchParams): Promise<Response> {
  const views = c.get('views') ?? defaultViews;
  const browserSessionStore = c.get('browserSessionStore') ?? defaultBrowserSessionStore;
  const config = c.get('config') ?? defaultProviderConfig;
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
    return withCookies(
      renderView(views.logoutConfirmationPage({ csrfToken: csrfSecret })),
      [buildLogoutConfirmationCookie({ csrfSecret, redirectTo })],
    );
  }

  // Immediate logout: a valid hint for the current session's End-User (§2).
  // Delete the store entry and expire the cookie together.
  if (sessionId) {
    await browserSessionStore.delete(sessionId);
  }
  const cookies = [buildClearedSessionCookie()];
  if (redirectTo !== null) {
    return redirectResponse(redirectTo, cookies);
  }
  return withCookies(renderView(views.logoutCompletedPage({})), cookies);
}

/** end_session_endpoint - GET (§2: the OP MUST support GET and POST). */
logoutApp.get('/', (c) => handleEndSessionRequest(c, new URL(c.req.url).searchParams));

/** end_session_endpoint - POST, application/x-www-form-urlencoded body (§2). */
logoutApp.post('/', async (c) => {
  const body = await c.req.parseBody();
  const params = new URLSearchParams();
  for (const [key, value] of Object.entries(body)) {
    if (typeof value === 'string') {
      params.append(key, value);
    }
  }
  return handleEndSessionRequest(c, params);
});

/**
 * Confirmation approve - POST
 *
 * Runs only for the browser that rendered the confirmation screen: the
 * HttpOnly cookie and the hidden csrf_token must present the same secret
 * (neither alone is accepted). On success the session is deleted and the
 * redirect decision computed at render time — carried in the cookie, never in
 * the form — is honored (§3).
 */
logoutApp.post('/approve', async (c) => {
  const views = c.get('views') ?? defaultViews;
  const browserSessionStore = c.get('browserSessionStore') ?? defaultBrowserSessionStore;

  const body = await c.req.parseBody();
  const csrfToken = String(body['csrf_token'] ?? '');
  const confirmation = parseLogoutConfirmation(c.req.header('Cookie') ?? null);
  if (confirmation === null || csrfToken === '' || confirmation.csrfSecret !== csrfToken) {
    // Forged, replayed or expired confirmation: delete nothing. This is a
    // browser surface, so the answer is the error page, not OAuth error JSON.
    return renderView(
      views.errorPage({ error: 'Invalid logout confirmation', statusCode: 400 }),
      { status: 400 },
    );
  }

  // The End-User explicitly approved (§2). When the session is already gone
  // there is nothing to delete and the response is the same either way — the
  // confirmation flow is not an oracle for whether a session existed.
  const sessionId = parseSessionId(c.req.header('Cookie') ?? null);
  if (sessionId) {
    await browserSessionStore.delete(sessionId);
  }
  const cookies = [buildClearedSessionCookie(), buildClearedLogoutConfirmationCookie()];
  if (confirmation.redirectTo !== null) {
    return redirectResponse(confirmation.redirectTo, cookies);
  }
  return withCookies(renderView(views.logoutCompletedPage({})), cookies);
});
```

### store.ts に入るコード

`buildSessionCookie` の直後に、確認画面の CSRF cookie 一式とセッション破棄ヘルパーが入る。
cookie 値はシークレットと base64url 化したリダイレクト先をドットでつないだ 2 部構成で、`parseLogoutConfirmation` はどんな不正形も null に落とす（承認 POST は null を 400 にし、何も削除しない）。

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
 * as the device verification binding cookie above.
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

/**
 * Build the Set-Cookie value that removes the browser session cookie. The
 * logout routes pair it with browserSessionStore.delete(): the store entry
 * and the cookie go away together (RP-Initiated Logout 1.0 §2).
 */
export function buildClearedSessionCookie(): string {
  return SESSION_COOKIE_NAME + '=; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=0';
}
```

### views.ts に入るコード

パラメータ型が 2 つ、`Views` インターフェースのメンバーが 2 つ、既定実装が 2 つ、`defaultViews` のエントリが 2 行入る。
完了画面のパラメータをあえて空にしているのは、この画面に End-User やクライアントの識別子を出さない（画面を見た第三者に何も漏らさない）方針と、文言を削除の有無で変えない（オラクルにしない）方針の両方を型で固定するためである。

```typescript
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
```

`Views` インターフェースには次の 2 メンバーが加わる。

```typescript
  /** EXPERIMENTAL (RP-Initiated Logout 1.0 §2): render the logout confirmation screen */
  logoutConfirmationPage(params: LogoutConfirmationPageParams): ViewResult;
  /** EXPERIMENTAL (RP-Initiated Logout 1.0): render the logged-out screen */
  logoutCompletedPage(params: LogoutCompletedPageParams): ViewResult;
```

既定実装は次の 2 関数で、`defaultViews` へ次の 2 行で登録される。

```typescript
// RP-Initiated Logout 1.0 §2: the wording is fixed for every path into this
// screen (no hint, an invalid or expired hint, another user's session, no
// session at all), so the page cannot be used as an oracle for session state
// or for why the hint failed.
function defaultLogoutConfirmationPage(params: LogoutConfirmationPageParams): string {
  return `<!DOCTYPE html>
<html>
<head><title>Log out</title></head>
<body>
  <h1>Log out</h1>
  <p>Do you want to log out of the OpenID Provider?</p>
  <p>If you did not request this, close this page.</p>
  <form method="POST" action="/logout/approve">
    <input type="hidden" name="csrf_token" value="${escapeHtml(params.csrfToken)}" />
    <button type="submit">Log out</button>
  </form>
</body>
</html>`;
}

function defaultLogoutCompletedPage(_params: LogoutCompletedPageParams): string {
  return `<!DOCTYPE html>
<html>
<head><title>Logged out</title></head>
<body>
  <h1>Logged out</h1>
  <p>You have been logged out.</p>
  <p>You can close this page.</p>
</body>
</html>`;
}
```

```typescript
  logoutConfirmationPage: defaultLogoutConfirmationPage,
  logoutCompletedPage: defaultLogoutCompletedPage,
```

### routes/discovery.ts に入るコード

メタデータのスプレッドマージに 1 エントリ加わる。

```typescript
    // EXPERIMENTAL — RP-Initiated Logout 1.0 §2.1 metadata.
    end_session_endpoint: `${issuer}/logout`,
```

### app.ts に入るコード

メソッドガードの表に 2 パスが入る（§2 MUST の GET / POST 両対応と、承認 POST の POST 限定）。

```typescript
  '/logout': ['GET', 'POST'],
  '/logout/approve': ['POST'],
```

続いて import とマウントの 2 行が入る。
`/logout` はブラウザが直接開く画面なので、`/login` や `/consent` と同じく CORS ヘッダは付けない。

```typescript
import { logoutApp } from './routes/logout.js';

  app.route('/logout', logoutApp);
```

### conformance.test.ts に入るコード

契約テストは、認可コードフローを実 HTTP で回して ID Token とセッション Cookie を取り、`prompt=none` の応答（生きたセッションなら code、消えたセッションなら `login_required`）でセッションの生死を観測する。
ログアウトの成否をストアの中身ではなく外形で固定するのは、利用者がストアを差し替えても契約が変わらないようにするためである。

```typescript
  // EXPERIMENTAL — OpenID Connect RP-Initiated Logout 1.0. Generated because
  // this provider was created with --enable rp-initiated-logout. These tests
  // pin the contract the repository guarantees for the generated
  // end_session_endpoint: change the behavior and they fail, which is how a
  // customized OP learns it drifted.
  describe('RP-Initiated Logout (RP-Initiated Logout 1.0)', () => {
    // RFC 7636 Appendix B example PKCE pair (verifier -> its S256 challenge).
    const LOGOUT_PKCE_VERIFIER = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
    const LOGOUT_PKCE_CHALLENGE = 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM';
    // A logout-specific registered return URI — deliberately NOT the authorize
    // REDIRECT_URI, because §3 defines post_logout_redirect_uris as its own
    // registry.
    const POST_LOGOUT_URI = 'http://localhost:3000/logged-out';
    const CLEARED_SESSION_COOKIE =
      'session_id=; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=0';

    // The generated settings object is the §3 registry; register the test
    // client's return URI once for every test in this block.
    rpInitiatedLogoutConfig.postLogoutRedirectUris = { 'c-conf': [POST_LOGOUT_URI] };

    // Pure helpers: they fetch and parse only. Every assertion lives in an it().
    function relativeFrom(location: string | null): string {
      const url = new URL(location ?? '', 'http://localhost');
      return url.pathname + url.search;
    }

    function csrfFrom(html: string): string {
      return html.match(/name="csrf_token" value="([^"]+)"/)?.[1] ?? '';
    }

    // Drive authorize -> login -> consent -> token and hand back the browser
    // session cookie plus the ID Token (the id_token_hint of the logout tests).
    async function loginSession(): Promise<{ idToken: string; sessionCookie: string }> {
      const authorizeRes = await app.request(
        '/authorize?response_type=code&client_id=c-conf' +
          '&redirect_uri=' + encodeURIComponent(REDIRECT_URI) +
          '&scope=openid&state=logout-flow&nonce=logout-nonce&prompt=consent' +
          '&code_challenge=' + LOGOUT_PKCE_CHALLENGE + '&code_challenge_method=S256',
      );
      const loginPath = relativeFrom(authorizeRes.headers.get('Location'));
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
          username: 'testuser',
          password: 'password',
        }).toString(),
      });
      const sessionCookie =
        (loginRes.headers.get('Set-Cookie') ?? '').match(/session_id=[^;,]+/)?.[0] ?? '';
      const cookies = bindingCookie ? bindingCookie + '; ' + sessionCookie : sessionCookie;

      const consentPath = relativeFrom(loginRes.headers.get('Location'));
      const consentGet = await app.request(consentPath, { headers: { Cookie: cookies } });
      const consentRes = await app.request('/consent', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded', Cookie: cookies },
        body: new URLSearchParams({
          transaction_id: transactionId,
          csrf_token: csrfFrom(await consentGet.text()),
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
          code_verifier: LOGOUT_PKCE_VERIFIER,
        }).toString(),
      });
      const idToken = ((await tokenRes.json()) as { id_token?: string }).id_token ?? '';
      return { idToken, sessionCookie };
    }

    // prompt=none is the observable session probe (OIDC Core 1.0 §3.1.2.1): a
    // live session answers with a code, a dead one with error=login_required.
    async function promptNoneProbe(
      sessionCookie: string,
    ): Promise<{ error: string | null; hasCode: boolean }> {
      const res = await app.request(
        '/authorize?response_type=code&client_id=c-conf' +
          '&redirect_uri=' + encodeURIComponent(REDIRECT_URI) +
          '&scope=openid&state=logout-probe&prompt=none' +
          '&code_challenge=' + LOGOUT_PKCE_CHALLENGE + '&code_challenge_method=S256',
        { headers: { Cookie: sessionCookie } },
      );
      const callback = new URL(res.headers.get('Location') ?? '', 'http://localhost');
      return {
        error: callback.searchParams.get('error'),
        hasCode: callback.searchParams.get('code') !== null,
      };
    }

    it('should advertise end_session_endpoint in discovery metadata', async () => {
      const res = await app.request('/.well-known/openid-configuration');

      expect(res.status).toBe(200);
      const metadata = await res.json();
      expect(metadata.end_session_endpoint).toBe('http://localhost:3000/logout');
    });

    // §2 + §3: a valid hint for the current session logs out at once, the
    // session cookie and store entry are destroyed together, and the browser
    // returns to the registered URI with state appended.
    it('should log out immediately and redirect with state for a valid hint and registered URI', async () => {
      const { idToken, sessionCookie } = await loginSession();

      const res = await app.request(
        '/logout?id_token_hint=' + encodeURIComponent(idToken) +
          '&post_logout_redirect_uri=' + encodeURIComponent(POST_LOGOUT_URI) +
          '&state=af0ifjsldkj',
        { headers: { Cookie: sessionCookie } },
      );

      expect(res.status).toBe(302);
      expect(res.headers.get('Location')).toBe(POST_LOGOUT_URI + '?state=af0ifjsldkj');
      expect(res.headers.get('Set-Cookie')).toBe(CLEARED_SESSION_COOKIE);
      expect(await promptNoneProbe(sessionCookie)).toEqual({
        error: 'login_required',
        hasCode: false,
      });
    });

    // §2 MUST: the end_session_endpoint accepts POST with a form body exactly
    // like GET with a query.
    it('should accept the logout request as a form POST', async () => {
      const { idToken, sessionCookie } = await loginSession();

      const res = await app.request('/logout', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded', Cookie: sessionCookie },
        body: new URLSearchParams({
          id_token_hint: idToken,
          post_logout_redirect_uri: POST_LOGOUT_URI,
          state: 'post-body-state',
        }).toString(),
      });

      expect(res.status).toBe(302);
      expect(res.headers.get('Location')).toBe(POST_LOGOUT_URI + '?state=post-body-state');
    });

    // §2 MUST + §7: without a valid hint nothing is deleted — the screen asks
    // first, so a planted <img src="/logout"> cannot end the victim's session.
    it('should show the confirmation screen and keep the session when the hint is absent', async () => {
      const { sessionCookie } = await loginSession();

      const res = await app.request('/logout', { headers: { Cookie: sessionCookie } });

      expect(res.status).toBe(200);
      expect(res.headers.get('Content-Type')).toBe('text/html; charset=UTF-8');
      const html = await res.text();
      expect(html.includes('action="/logout/approve"')).toBe(true);
      expect((res.headers.get('Set-Cookie') ?? '').startsWith('oidc_logout_confirm=')).toBe(true);
      expect(await promptNoneProbe(sessionCookie)).toEqual({ error: null, hasCode: true });
    });

    it('should delete the session when the confirmation is approved with the paired cookie and token', async () => {
      const { sessionCookie } = await loginSession();
      const confirmRes = await app.request('/logout', { headers: { Cookie: sessionCookie } });
      const confirmCookie =
        (confirmRes.headers.get('Set-Cookie') ?? '').match(/oidc_logout_confirm=[^;,]+/)?.[0] ?? '';
      const csrfToken = csrfFrom(await confirmRes.text());

      const res = await app.request('/logout/approve', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          Cookie: sessionCookie + '; ' + confirmCookie,
        },
        body: new URLSearchParams({ csrf_token: csrfToken }).toString(),
      });

      expect(res.status).toBe(200);
      expect((res.headers.get('Set-Cookie') ?? '').includes(CLEARED_SESSION_COOKIE)).toBe(true);
      expect(await promptNoneProbe(sessionCookie)).toEqual({
        error: 'login_required',
        hasCode: false,
      });
    });

    // The hidden token alone is not a defense: without the HttpOnly cookie the
    // approve POST must refuse to delete anything (forged cross-site POST).
    it('should reject an approve POST without the confirmation cookie and keep the session', async () => {
      const { sessionCookie } = await loginSession();
      const confirmRes = await app.request('/logout', { headers: { Cookie: sessionCookie } });
      const csrfToken = csrfFrom(await confirmRes.text());

      const res = await app.request('/logout/approve', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          Cookie: sessionCookie,
        },
        body: new URLSearchParams({ csrf_token: csrfToken }).toString(),
      });

      expect(res.status).toBe(400);
      expect(await promptNoneProbe(sessionCookie)).toEqual({ error: null, hasCode: true });
    });

    // §3 MUST NOT: an unregistered URI is never redirected to. The logout
    // itself still happens (the hint was valid) — the browser just stays on
    // the completed page and state is not echoed anywhere.
    it('should show the completed page instead of redirecting to an unregistered URI', async () => {
      const { idToken, sessionCookie } = await loginSession();

      const res = await app.request(
        '/logout?id_token_hint=' + encodeURIComponent(idToken) +
          '&post_logout_redirect_uri=' + encodeURIComponent('https://attacker.example/out') +
          '&state=leak-probe',
        { headers: { Cookie: sessionCookie } },
      );

      expect(res.status).toBe(200);
      expect(res.headers.get('Location')).toBe(null);
      expect((await res.text()).includes('leak-probe')).toBe(false);
      expect(await promptNoneProbe(sessionCookie)).toEqual({
        error: 'login_required',
        hasCode: false,
      });
    });

    // §2 MUST: a client_id parameter that mismatches the hint audience voids
    // the hint — confirmation screen, session intact, no redirect.
    it('should fall back to the confirmation screen when client_id mismatches the hint audience', async () => {
      const { idToken, sessionCookie } = await loginSession();

      const res = await app.request(
        '/logout?id_token_hint=' + encodeURIComponent(idToken) +
          '&client_id=c-public' +
          '&post_logout_redirect_uri=' + encodeURIComponent(POST_LOGOUT_URI),
        { headers: { Cookie: sessionCookie } },
      );

      expect(res.status).toBe(200);
      expect(res.headers.get('Location')).toBe(null);
      expect((await res.text()).includes('action="/logout/approve"')).toBe(true);
      expect(await promptNoneProbe(sessionCookie)).toEqual({ error: null, hasCode: true });
    });
  });
```

### 他フレームワークの生成結果

express / fastify / nextjs は web-standard 変換で同じルートテンプレートから生成される。
`routes/logout.ts` は Hono の import と router クラスだけが置き換わり、判定・Cookie・応答の構成は同一である（[web-standard/templates.ts](https://github.com/maronnjapan/maronn-openid-connect/blob/main/packages/cli/src/frameworks/web-standard/templates.ts) の `toWebRouteTemplate`）。

### サンプルと登録簿の注入

`samples/hono-cloudflare` は `--enable rp-initiated-logout` で再生成し、環境変数 `OIDC_POST_LOGOUT_REDIRECT_URIS_JSON` から `rpInitiatedLogoutConfig.postLogoutRedirectUris` を注入する。
E2E では playwright.config.ts がこの変数に E2E クライアントの `/logged-out` ページを登録して OP を起動する。

## E2E テストの全文

Playwright で、実ブラウザのログアウト全周を 2 本検証する。
1 本目はヒントと登録 URI による即時ログアウト（`state` 付きで RP に戻り、以後の認可がログイン画面に落ちる）、2 本目はヒントなしの確認画面経由である。
どちらも、セッションが本当に消えたことを、ログアウト後にもう一度認可を始めてログイン画面が出ることで確かめる。

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

## 関連資料

- [OpenID Connect RP-Initiated Logout 1.0](https://openid.net/specs/openid-connect-rpinitiated-1_0.html)（Final, 2022-09-12）
- [RFC 6749 §10.15: Open Redirectors](https://www.rfc-editor.org/rfc/rfc6749#section-10.15)
- 利用者向けドキュメント: [docs/library-document/src/content/docs/experimental/rp-initiated-logout.md](https://github.com/maronnjapan/maronn-openid-connect/blob/main/docs/library-document/src/content/docs/experimental/rp-initiated-logout.md)
- 仕様策定タスク（3 回レビューの記録）: notes リポジトリ `tasks/experimental/done/rp-initiated-logout/`
