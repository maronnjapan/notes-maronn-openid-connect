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

experimental パッケージが持つのは、ログアウト要求の正規化、ヒント audience の抽出、ログアウト分岐の判定、リダイレクト先の解決という判定のロジック層だけである。
HTTP の受け口、Cookie、セッションの削除、画面は、`maronn-oidc generate` が出力する生成コードの側にある。
`--enable rp-initiated-logout` は、生成コードに次の 2 つを加える。

- **`features/rp-initiated-logout/`**：機能を記述する `feature.ts`、リダイレクト先の登録簿の `config.ts`、確認画面の Cookie の `cookies.ts`、画面の `views.tsx`、エンドポイント本体の `endpoints/logout/`（`page.tsx`、`endpoint.ts`、`outcome.ts`、`steps/` の 2 ステップ）
- **`features/enabled.ts`**：`rpInitiatedLogout` の import 1 行と、機能一覧 `features` の要素 1 つ

生成コードでは、機能が基底のパイプラインの中で動かすロジックを、そのエンドポイントの `pipeline.ts` に、`(feature: <feature-id>)` を含むマーカーコメントで始まるブロック（この解説では **オーナーブロック** と呼ぶ）として置く。
rp-initiated-logout のオーナーブロックは基底のパイプラインに 1 つも無く、基底への寄与はすべて `feature.ts` のフックを通る。
この機能は自分のエンドポイントで完結し、他のエンドポイントのパイプラインの途中で動く処理を持たないためである。

`feature.ts` が使うフックは `routes` と `discovery` の 2 つである。
`routes` は `/logout`（GET と POST）とその下の `/approve`（POST のみ）を宣言し、`app.ts` がこれをマウントして、宣言したメソッド以外を 405 で答える。
`cors` を指定しないので、`/login` や `/consent` と同じく、ブラウザが直接開く画面として CORS ヘッダは付かない。
`discovery` は `end_session_endpoint` を返す。

ステップが読むセッションストア、設定、`jwksProvider` は基底の `setRequestContext()` がどの構成でもリクエストコンテキストに置くので、`context` フックも使わない。
セッション Cookie を読む `parseSessionId()` と消す `buildClearedSessionCookie()` も基底の `cookies.ts` にあり、機能の有無に関わらず生成される。
画面の 2 つは、`views.tsx` のモジュール拡張（`declare module '../../views.js'`）が基底の `Views` にメンバーとして加えるので、`createApp()` や `applyOidc()` の `views` オプションで差し替えられる。

ログアウトの流れは次のとおりである。
RP がユーザーエージェントを `GET` か `POST` の `/logout` へ送ると、`app.ts` の共通ミドルウェアがリクエストコンテキストを用意し、`endpoints/logout/page.tsx` がパラメータを取り出して `processEndSessionRequest()` を呼ぶ。
ステップは `Response` を作らず、次に何を返すか（確認画面、リダイレクト、完了画面）と付ける Cookie を `LogoutOutcome` として返し、`page.tsx` がそれを HTTP に変える。
確認画面のフォームは `csrf_token` を `/logout/approve` へ送り、`approveLogout()` が HttpOnly の Cookie と照合してからセッションを削除する。

`--enable rp-initiated-logout` を付けずに生成すると、`features/rp-initiated-logout/` と `features/enabled.ts` の 2 行が出力されないだけで、他のファイルは変わらない。

### 生成コードに入るコードの全文（hono）

以下は、既定の機能に rp-initiated-logout を加えて `maronn-oidc generate hono --enable rp-initiated-logout` で生成した出力からの掲載である。

#### `features/enabled.ts` に入る行

`features/enabled.ts` は、有効な機能をフックの適用順に並べるファイルである。
rp-initiated-logout はこのファイルに、`feature.ts` の import と配列 `features` の要素を 1 つずつ加える。

```typescript
import { rpInitiatedLogout } from './rp-initiated-logout/feature.js';
```

```typescript
  rpInitiatedLogout,
```

#### `features/rp-initiated-logout/feature.ts`

機能を記述するファイルで、`defineFeature()` に `id`、`routes`、`discovery` を渡す。
`routes` の要素は、マウント先のパス、そこにマウントする `page.tsx` の `logoutPage`、パス自体のメソッド、その下のパスとメソッド（`subpaths`）である。
§2 は end_session_endpoint に GET と POST の両方を求め（MUST）、承認の `/logout/approve` はフォームの POST だけを受ける。
`discovery` は §2.1 の `end_session_endpoint` を issuer から組み立てる。

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

`post_logout_redirect_uri` の登録簿 `rpInitiatedLogoutConfig.postLogoutRedirectUris` を置くファイルで、client_id ごとに完全一致で照合する URI の一覧を持つ。
認可エンドポイントの `redirect_uris` は流用せず、ログアウト用に別の登録簿を持つ。
既定は空で、登録するまではどのログアウトもリダイレクトせず完了画面で終わる（fail-closed）。
登録簿を `config` フックではなくこのファイルのオブジェクトに置くのは、`config` フックが与えられるのが基底の設定（`ProviderConfig`）の既定値だけで、この登録簿はそこに含まれないからである。
`process-end-session-request` ステップがこのオブジェクトを直接 import して読み、デプロイは起動時に中身を書き換える（後述のサンプルがその例である）。

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

確認画面と承認 POST を結ぶ Cookie の組み立てと解釈を置くファイルである。
確認画面を描くたびに乱数のシークレットを作り、HttpOnly の Cookie とフォームの hidden の `csrf_token` の 2 か所で同じブラウザへ渡す。
攻撃者は自分のブラウザで有効な組を手に入れられても、被害者のブラウザへこの Cookie を置けないので、クロスサイトから偽造した POST は照合で落ちる。

Cookie の値は、シークレットと、OP が確定したリダイレクト先を base64url にしたものをドットでつないだ 2 部構成である。
リダイレクト先を hidden フィールドではなく HttpOnly の Cookie で運ぶので、フォームから書き換えられず、`id_token_hint` をページへ書き戻す必要もない。
`parseLogoutConfirmation()` はどんな不正な形も `null` に落とし、承認 POST はそれを 400 にして何も削除しない。
有効期間は 10 分（`Max-Age=600`）で、放置された確認画面の Cookie を長く残さない。

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

確認画面と完了画面の既定の hono/jsx 実装と、そのパラメータ型を置くファイルである。
モジュール拡張で基底の `Views` に `logoutConfirmationPage` と `logoutCompletedPage` を省略可能なメンバーとして加え、`logoutViews()` が差し替えられた画面か既定の画面を選ぶ。
確認画面の文言は、どの経路から来ても（ヒントなし、無効や期限切れのヒント、別ユーザーのセッション、セッションなし）同じである。
完了画面のパラメータ型 `LogoutCompletedPageParams` をあえて空にしているのは、画面に End-User やクライアントの識別子を出さないことと、文言を削除の有無で変えないこと（セッション状態のオラクルにしないこと）を型で固定するためである。

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

`/logout` にマウントされる Hono アプリ `logoutPage` で、`GET /`、`POST /`、`POST /approve` の 3 ルートを持つ。
GET はクエリから、POST は `application/x-www-form-urlencoded` のボディから `URLSearchParams` を作り、同じ `processEndSessionRequest()` に渡す。
`respond()` は `LogoutOutcome` の種類ごとに応答を組み立てる。
偽造や期限切れの確認は、ブラウザが見る画面なので OAuth のエラー JSON ではなくエラーページ（400）で答える。
確認画面と完了画面には `LogoutOutcome` が運ぶ Cookie を付け、リダイレクトは Cookie 付きの 302 で返す。
ステップが `Response` を作らないので、ログアウトの UI を変えるときに触るのはこのファイルか `views.tsx` だけで、判定のステップは変えなくてよい。

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

`maronn-oidc graph` がエンドポイントの図を描くための記述である。
`layer: 'browser'` のエンドポイントで、2 つのステップは一直線につながらず（`chain: false`）、確認画面を経由する分岐の辺だけを持つ。
画面のエンドポイントなので `rearrangeable: false` で、`--flow` はこのエンドポイントのステップを外したり並べ替えたりしない。
`journeys` は、トークンエンドポイントで発行した ID Token が `id_token_hint` としてここへ届く流れを図に載せる。

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

ステップと `page.tsx` の間で受け渡す `LogoutOutcome` の型を置くファイルである。
冒頭のコメントが、エンドポイントの振る舞い（有効なヒントと現在のセッションの End-User が一致するときだけ即時ログアウトし、それ以外はすべて同じ確認画面へ落とす）と、承認 POST に Cookie とトークンの組を求める理由を説明している。

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

GET と POST の `/logout` が呼ぶステップである。
`id_token_hint` があれば、期待する audience を `client_id` パラメータから、無ければ検証前のヒントのペイロードから取り出し、`validateIdTokenHint()` で署名、iss、aud、exp を検証する。
鍵セットは、他の場所の id_token_hint と同じ `jwksProvider` である。
`IdTokenHintError` はログアウト権限を示せなかっただけなので `null` にして確認画面へ回し、理由はどこにも出さない。
それ以外の例外（JWKS プロバイダ自体の障害など）は投げ直す。
障害を「無効なヒント」として隠すと、すべてのログアウトが黙って確認画面に変わってしまうためである。

リダイレクト先は分岐の前に `resolvePostLogoutRedirect()` で解決する。
確認画面を経由した場合も承認後に同じ結果を使うためで、リダイレクトの条件はヒントと登録簿との完全一致であり、どちらの経路でログアウトしたかではない。
確認が必要なら何も削除せずにシークレットを作って確認画面の `LogoutOutcome` を返し、即時ログアウトならセッションストアのエントリを削除して Cookie を消す。
`logout_hint` と `ui_locales` は受け付けるが使わず、ログにも残さない。

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

`POST /logout/approve` が呼ぶステップである。
確認の Cookie を解釈し、そのシークレットとフォームの `csrf_token` が一致しなければ、何も削除せずに `invalid_confirmation` を返す。
照合が先で削除が後という順序により、偽造した POST がセッションに触れることは無い。
一致したらセッションがあれば削除し、セッション Cookie と確認の Cookie の両方を消して、確認画面を描いたときに Cookie へ入れたリダイレクト先へ戻すか、完了画面を返す。
セッションがすでに無くても応答は同じで、確認の流れがセッションの有無のオラクルにならない。

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

### 他フレームワークの生成コード

Express と Fastify の出力も同じファイル構成である。
ジェネレータはエンドポイントの `hono` の import を `web-router.ts`（Fetch API の上で動き、`WebRouter` と `WebContext` を持つ小さなルーター）に置き換え、フレームワーク用の `apply.ts`、`web-router.ts`、`node-adapter.ts` を加える。
これらの元は [apps/hono/src/web/](https://github.com/maronnjapan/maronn-openid-connect/tree/main/apps/hono/src/web) で、どのファイルをどこへ置くかは [packages/cli/extract.json](https://github.com/maronnjapan/maronn-openid-connect/blob/main/packages/cli/extract.json) が定める。
この機能で置き換わるのは `endpoints/logout/page.tsx` のルーター（`new Hono<...>()` が `new WebRouter()` になる）で、他のファイルは `hono` のルーターを import しない。
`views.tsx` と `page.tsx` の画面は hono/jsx のまま残るので、Express と Fastify の出力も JSX ランタイムとして `hono` を必要とする。

Next.js の出力は、Next.js App Router のアプリ [apps/nextjs](https://github.com/maronnjapan/maronn-openid-connect/tree/main/apps/nextjs) から抽出する。
この機能のルートファイルはルートグループ `app/(rp-initiated-logout)/` に、コードは `app/_oidc-provider/features/rp-initiated-logout/` に入る。
Express、Fastify、Next.js のコードは、この解説には載せない。

### サンプルと登録簿の注入

`samples/hono-cloudflare` は `--enable rp-initiated-logout` を付けて生成し、手書きのエントリ `src/app.ts` が生成コードの `features/rp-initiated-logout/config.ts` から `rpInitiatedLogoutConfig` を import する。

```typescript
import { rpInitiatedLogoutConfig } from './oidc-provider/features/rp-initiated-logout/config.js';
```

`applyOidc()` を呼ぶ前に、環境変数 `OIDC_POST_LOGOUT_REDIRECT_URIS_JSON` から `rpInitiatedLogoutConfig.postLogoutRedirectUris` を注入する。
変数を設定しなければ、生成コードの空の登録簿が残る。

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

E2E では、`tests/e2e/playwright.config.ts` がこの変数に E2E クライアントの `/logged-out` ページを登録して OP を起動する。

```typescript
        // EXPERIMENTAL (RP-Initiated Logout 1.0 §3): register the E2E client's
        // post-logout return page. A sample OP generated without the feature
        // ignores the variable; the logout spec skips itself via discovery.
        OIDC_POST_LOGOUT_REDIRECT_URIS_JSON: JSON.stringify({
          'e2e-client': [`${clientBaseURL}/logged-out`],
        }),
```

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
