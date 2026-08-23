# PAR（Pushed Authorization Requests）実装解説

この文書は、`packages/experimental` に実装した **Pushed Authorization Requests**（RFC 9126、以下 PAR）について、何を実装したのか、どう実装したのかを、関連するコードの全文とともに説明する。
読み終えたとき、実装の一行一行がなぜその形になっているかを追える状態を目指している。

この文書が全文を載せるのは次のコードである。

- `packages/experimental/src/par/` の実装 4 ファイルとテスト 2 ファイルのすべて
- CLI の `--enable par` が生成コードへ注入する差分の全文（hono）
- PAR の E2E テストスペックの全文

core 本体、E2E 共有ハーネス、他フレームワークの生成差分は全機能で共有される基盤なので、リンクで参照する。

## 機能の概要

通常の Authorization Code Flow では、クライアントは認可リクエストのパラメータ（`client_id`、`redirect_uri`、`scope`、`state`、`code_challenge` など）をすべてブラウザのリダイレクト URL に載せて認可エンドポイントへ送る。
この経路はフロントチャネルと呼ばれ、パラメータがユーザーの手元を通るため、次の弱点を抱えている。

- パラメータが URL としてブラウザ履歴、プロキシのログ、Referer ヘッダに残り得る
- ユーザー（または中間者）がパラメータを書き換えてから認可エンドポイントへ届けられる
- リクエストの正当性をクライアント認証で裏付けられない（認可エンドポイントはクライアントを認証しない）

PAR はこの弱点を、認可リクエストの「本体」をフロントチャネルから引き剥がすことで解決する。
クライアントはまずバックチャネルで OP の PAR エンドポイントへパラメータ一式を POST し、クライアント認証を受けたうえで、短命な参照値 **request_uri**（`urn:ietf:params:oauth:request_uri:...` 形式）を受け取る。
ブラウザ経由の認可リクエストには `client_id` と `request_uri` だけを載せ、認可エンドポイントが参照値を保存済みパラメータへ展開して通常どおり処理する。
パラメータの実体はクライアントと OP の間から出ないので、改ざんも漏えいも起こらない。

```text
クライアント                               OP
    │  POST /par（クライアント認証つき）      │
    │  scope, redirect_uri, code_challenge…  │
    │ ─────────────────────────────────────> │ 検証して保存
    │  201 { request_uri, expires_in }       │
    │ <───────────────────────────────────── │
    │                                        │
    │  （ブラウザへリダイレクト指示）          │
    │  GET /authorize?client_id=…&request_uri=… （ブラウザ経由）
    │ ─────────────────────────────────────> │ request_uri を展開し、
    │                                        │ 以降は通常の認可リクエスト
```

### ユースケース

- FAPI 2.0 をはじめとする高セキュリティプロファイルの事前検証。FAPI 2.0 Security Profile は PAR の使用を必須にしているため、FAPI 対応を見据えた PoC の足がかりになる
- 認可リクエストの改ざんや漏えいを防ぎたい要件が、自分のクライアント構成で成立するかの確認
- `require_pushed_authorization_requests`（RFC 9126 §5）で「PAR を通らない認可リクエストを拒否する」運用の検証
- 長大な認可リクエスト（多数の scope や claims）が URL 長制限に触れる構成からの退避先の検証

### 実装スコープと非目標

実装したのは RFC 9126 の中核で、次の範囲である。

- PAR エンドポイントの処理一式（§2.1 のリクエスト検証、§2.2 の応答、§2.3 のエラー応答）
- 認可エンドポイント側の `request_uri` 展開（§4）と、単回使用の強制（§7.3）
- `require_pushed_authorization_requests` のガード（§5）
- `request_uri` の有効期間の設定と、§2.2 の推奨レンジ（5〜600 秒）の起動時検証

非目標として明示的に外したものが 2 つある。
URL 形式の `request_uri`（OIDC Core §6.2）は発行も受理もしない（URN 形式のみ。URL 形式は core が `request_uri_not_supported` で拒否する）。
Request Object（JAR）との併用もしない（PAR ボディの `request` パラメータは `invalid_request` で拒否する）。

## 実装の設計方針

コードを読む前に、ファイル構成と、全体を貫く設計判断を押さえておく。

| ファイル | 役割 |
|---|---|
| `store.ts` | ストア契約と URN 前置詞の定義 |
| `par-request.ts` | PAR エンドポイントの処理（ステップ関数と合成関数） |
| `resolve-request-uri.ts` | 認可エンドポイント側の `request_uri` 展開 |
| `index.ts` | 公開 API の再エクスポート |

設計判断は 4 つある。

第一に、処理を**ステップ関数**（仕様の検証単位ごとの関数）と**合成関数**（ステップ関数を仕様順に呼ぶだけの関数）の二層に分けている。
CLI 生成コードはステップ関数を順に呼ぶ形で出力されるため、利用者は「この検証を外したらどうなるか」を生成コード上で試せる。

第二に、core を変更しない。
core の `AuthorizationErrorCode` は閉じた enum で、RFC 9126 が使う `invalid_request_uri` を含まない。
そこで PAR エンドポイント用の `ParError` と、認可エンドポイント側の `PushedRequestUriError` を機能側に新設し、core のエラーは変換して写す。

第三に、`request_uri` の解決失敗から情報を漏らさない。
不存在、使用済み、期限切れ、client_id 不一致のどれで失敗しても、同じエラーコードと同じ文言で応答する。
応答差から「その request_uri が存在したか」を判定できるオラクルを作らないための設計である。

第四に、クライアント認証情報をストアへ残さない。
PAR ボディはクライアント認証情報と認可リクエストパラメータが同居する特殊な形なので、保存前に `client_secret` などを必ず取り除く。
残すとシークレットが永続層やログに流出し、展開後のパラメータにも混入してしまう。

## 実装コードの全文と解説

### store.ts（ストア契約）

最初に読むべきはストア契約である。
`PushedAuthorizationRecord` が保存の単位で、認証済みクライアントに正規化した `client_id` を含むパラメータ一式と、紐付けクライアント、期限を持つ。

契約の特徴は、`get` を提供しない点にある。
読むだけの操作を契約から排除し、取得と削除を同時に行う `consume` だけを置くことで、RFC 9126 §7.3 の単回使用を型レベルで強制している。
`consume` が atomic でない実装は同一 `request_uri` の並行使用（リプレイ）を許してしまうため、コメントで atomic 性を契約要件として明記している。

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

### par-request.ts（PAR エンドポイントの処理）

PAR エンドポイントの本体である。
エラー型、ステップ関数 5 つ、合成関数、core エラーの変換の順に並んでいる。

`ParError` は RFC 9126 §2.3 の「token endpoint と同じ形式のエラーレスポンス」を実装する。
リダイレクト先情報を持たせていないのは意図的で、PAR エンドポイントはバックチャネルなので決してリダイレクトしない。
`statusCode` はクライアント認証失敗（`invalid_client`）のみ 401、それ以外は 400 で、401 のときだけ `WWW-Authenticate: Basic` チャレンジを返す。token endpoint と同じ挙動である。

ステップ関数は仕様の処理順に並ぶ。

1. `rejectForbiddenParParams`：ボディの `request_uri`（§2.1 の MUST NOT）と `request`（JAR 併用は非目標）を拒否する
2. `authenticateParClient`：クライアントを認証する（後述の特殊事情がある）
3. `validatePushedAuthorizationParams`：pushed されたパラメータを、認可エンドポイントと同じ規則（core の `validateAuthorizationRequest`）で検証する
4. `createPushedAuthorizationRecord`：256 ビットの暗号論的乱数で参照値を生成し、レコードを保存する
5. `buildPushedAuthorizationResponse`：201 応答のボディ（`request_uri` と `expires_in`）を組み立てる

このうちステップ 2 には、core の認証ヘルパーをそのまま使えない事情がある。
RFC 9126 §2.1 は「`client_id` は認可リクエストの必須パラメータなので pushed request にも必須」と定めるため、`client_secret_basic`（Authorization ヘッダ認証）を使う場合でもボディに `client_id` が載る。
一方 core の `extractClientCredentials` は、ボディに `client_id` があること自体を `client_secret_post` の使用と見なすので、ヘッダと併用すると「複数の認証方式」として拒否してしまう。
そこで `authenticateParClient` は、ヘッダがあるときはヘッダだけを資格情報として渡し、認証が済んでからボディの `client_id` が認証済みクライアントと一致することを別に検証する、という順序で core 無変更のまま両立させている。
なお、ボディの `client_secret` とヘッダの併用は本当に「複数方式」なので、OAuth 2.1 §2.3 violation として拒否する。

期限まわりでは、`assertParExpiresInSeconds` が §2.2 の推奨レンジ（5〜600 秒の整数）を検証する。
この関数は生成コードが設定読み込み時（起動時）に呼ぶ想定で、範囲外の設定をリクエスト処理前に失敗させる。

末尾の `toParError` は core のエラーを PAR のエラーコードへ写す変換で、未知の例外は握りつぶさず再スローする（呼び出し側が 500 として扱う）。
認可エンドポイント固有のインタラクション系コード（`login_required` など）は pushed request の検証では発生しないため、対応する PAR コードが無いものは `invalid_request` に集約している。

```typescript
/**
 * Pushed Authorization Requests (PAR) — RFC 9126 §2
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * PAR エンドポイントの処理。core と同じく「合成関数＋ステップ関数」の二層構成とし、
 * CLI 生成コードはステップ関数を順に呼び出して処理を組み立てられるようにする。
 */
import {
  AuthorizationError,
  AuthorizationErrorCode,
  TokenError,
  TokenErrorCode,
  extractClientCredentials,
  generateRandomString,
  resolveAuthenticatedTokenClient,
  sanitizeErrorDescription,
  validateAuthorizationRequest,
  validateClientAuthMethod,
  verifyClientSecret,
  type AuthorizationRequestParams,
  type ClientResolver,
  type TokenClientResolver,
  type ValidateAuthorizationRequestOptions,
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

/** PAR エンドポイント処理のコンテキスト。 */
export interface PushedAuthorizationRequestContext {
  /** フォームボディのパラメータ（application/x-www-form-urlencoded） */
  params: Record<string, string>;
  /** Authorization ヘッダの値（client_secret_basic 用）。無ければ空文字 */
  authorizationHeader?: string;
  /** クライアント解決。認可リクエスト検証とクライアント認証の両方に使う */
  clientResolver: ClientResolver & TokenClientResolver;
  store: PushedAuthorizationRequestStore;
  /** core の認可リクエスト検証へそのまま渡すオプション */
  validationOptions: ValidateAuthorizationRequestOptions;
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
 * RFC 9126 §2.1 は「`client_id` は認可リクエストの必須パラメータなので pushed request にも
 * 必須」と定めており、`client_secret_basic` を使う場合でもボディに `client_id` が入る。
 * 一方 core の {@link extractClientCredentials} はボディの `client_id` の存在自体を
 * client_secret_post の使用と見なすため、Authorization ヘッダと併用すると
 * 「複数の認証方式」として拒否される。そこで PAR では、
 *
 * - Authorization ヘッダがある場合はヘッダのみを資格情報として扱い（ボディの
 *   `client_secret` があれば OAuth 2.1 §2.3 違反として invalid_request）、
 * - 認証後にボディの `client_id` が認証済みクライアントと一致することを検証する
 *
 * という順序で処理する。core は変更しない。
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
  const authorizationHeader = context.authorizationHeader ?? '';
  const usesAuthorizationHeader = authorizationHeader.trim().length > 0;

  // OAuth 2.1 §2.3: 1リクエストにつき認証方式は 1 つ。ボディの client_secret と
  // Authorization ヘッダの併用は本当に「複数方式」なので拒否する。
  if (usesAuthorizationHeader && params['client_secret'] !== undefined) {
    throw new ParError(
      'invalid_request',
      'Multiple client authentication methods provided. Use either the Authorization header or the request body, not both.',
    );
  }

  // client_id は認可リクエストのパラメータとしてボディに存在しうるので、資格情報の
  // 抽出には Authorization ヘッダ使用時はボディを渡さない。
  const credentialParams: Record<string, string | undefined> = usesAuthorizationHeader
    ? {}
    : { client_id: params['client_id'], client_secret: params['client_secret'] };

  const authenticatedClientId = await runClientAuthentication({
    params: credentialParams,
    authorizationHeader,
    clientResolver,
  });

  // RFC 9126 §2.2: request_uri は「pushed request を送ったクライアント」に紐付く。
  // ボディの client_id が別クライアントを名乗る場合はここで拒否する。
  const bodyClientId = params['client_id'];
  if (bodyClientId !== undefined && bodyClientId !== authenticatedClientId) {
    throw new ParError('invalid_request', 'client_id does not match the authenticated client');
  }

  return authenticatedClientId;
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
 * 失敗は必ず {@link ParError} になり、リダイレクトはしない（RFC 9126 §2.3）。
 *
 * @throws {ParError}
 */
export async function validatePushedAuthorizationParams(
  params: Record<string, string>,
  clientResolver: ClientResolver,
  options: ValidateAuthorizationRequestOptions = {},
): Promise<Awaited<ReturnType<typeof validateAuthorizationRequest>>> {
  try {
    return await validateAuthorizationRequest(
      params as unknown as AuthorizationRequestParams,
      clientResolver,
      options,
    );
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

### resolve-request-uri.ts（認可エンドポイント側の展開）

認可エンドポイントの前段に差し込む処理である。
`resolvePushedRequestUri` は、`request_uri` が URN 前置詞に一致するときだけ動き、それ以外は `null` を返して従来のフローへ合流させる。
この「一致しなければ何もしない」という振る舞いが、PAR 有効化が既存挙動を変えないことの保証になっている（URL 形式の `request_uri` は従来どおり core が `request_uri_not_supported` で拒否する）。

一致した場合は store の `consume` で単回使用として取得し、期限と client_id の紐付けを検証したうえで、`request_uri` を除いた pushed パラメータを返す。
消費が検証より先に来ていることには意味があり、期限切れでも client_id 不一致でも、提示された `request_uri` はその時点で消費済みになる（失敗した提示の再試行を許さない）。
展開後のパラメータから `request_uri` を落とすのは、残すと core の `rejectUnsupportedRequestParams` が `request_uri_not_supported` で拒否してしまうからである。

`assertPushedRequestUsed` は `require_pushed_authorization_requests`（§5）のガードで、PAR 必須設定のときに URN 形式の `request_uri` を伴わない認可リクエストを拒否する。

エラー型 `PushedRequestUriError` を core の `AuthorizationError` と別に新設しているのは、core の enum が `invalid_request_uri` を含まないためである。
このエラーは常に非リダイレクトで、生成コードの authorize ハンドラが catch 節に専用の分岐を持ち、既存の非リダイレクト経路と同じ描画で処理する。

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

### index.ts（公開 API）

subpath export `@maronn-openid-connect/experimental/par` の実体である。
ステップ関数、合成関数、エラー型、ストア契約をすべて公開し、生成コードが選んで組み立てられるようにしている。

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

## 単体テストの全文

テストは実装と同じ粒度で 2 ファイルに分かれている。
どちらも Edge Runtime 環境（Web 標準 API のみ）で実行され、in-memory のストア実装を使って決定的に検証する。

`par-request.test.ts` が固定している挙動を要約すると次のとおりである。

- 禁止パラメータ（`request_uri` / `request`）の拒否と、両方が無いボディの受理
- 有効期間の境界値（5 と 600 を受理し、範囲外と非整数を拒否）
- クライアント認証の全経路（Basic とボディの `client_id` 併存、`client_secret_post`、public client、複数方式の拒否、client_id 不一致、誤ったシークレット、未知のクライアント）
- `ParError` の HTTP ステータスと `WWW-Authenticate` チャレンジ、`error_description` のサニタイズ
- pushed パラメータ検証のエラーコード写像（`invalid_request` / `invalid_scope` / `unsupported_response_type`）と、エラーがリダイレクト先情報を持たないこと
- レコード生成の URN 形式、256 ビットの参照値、呼び出しごとの一意性、期限の既定値と設定値、認証情報を保存しないこと、呼び出し側の引数を変更しないこと
- 合成関数の一気通貫（保存される内容、認証や検証に失敗したときに保存されないこと、public client の PKCE 必須）

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

  it('should reject a body client_secret combined with an Authorization header', async () => {
    // OAuth 2.1 §2.3: a client MUST NOT use more than one authentication method.
    await expect(
      authenticateParClient({
        params: validParams({ client_secret: 'secret' }),
        authorizationHeader: basicHeader('web-app', 'secret'),
        clientResolver: createClientResolver(),
      }),
    ).rejects.toThrowError(
      new ParError('invalid_request', 'Multiple client authentication methods provided. Use either the Authorization header or the request body, not both.'),
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
      new ParError('invalid_request', 'client_id does not match the authenticated client'),
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
  it('should return the validated request for a well-formed pushed request', async () => {
    const validated = await validatePushedAuthorizationParams(
      { ...validParams(), client_id: 'web-app' },
      createClientResolver(),
    );

    expect(validated).toMatchObject({
      responseType: 'code',
      clientId: 'web-app',
      redirectUri: 'https://client.example/cb',
      scope: ['openid', 'profile'],
      state: 'af0ifjsldkj',
      nonce: 'n-0S6_WzA2Mj',
      codeChallengeMethod: 'S256',
    });
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

`resolve-request-uri.test.ts` は展開側を固定する。

- URN 前置詞に一致しないときの素通り（`null` を返し、store に触れないこと）
- 展開の成功（`request_uri` の除去、pushed 値が優先されること、store へ渡すキーが不透明であること）
- 解決失敗の全種別（不存在、二度目の使用、期限切れ、client_id 不一致、client_id 欠落）が同一のエラーコードと文言になること
- 期限ちょうどの瞬間は受理されること、失敗種別に関わらずレコードが消費されること
- `assertPushedRequestUsed` の必須ガードと、`PushedRequestUriError` のサニタイズ

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

## CLI 統合と生成コードへの寄与

experimental 本体はロジック層であり、HTTP エンドポイントとしての PAR は CLI が生成するコードが実装する。
`maronn-oidc generate <framework> --enable par` を指定すると、生成コードに次が入る。

- **routes/par.ts の追加**：`POST /par` のハンドラ。`application/x-www-form-urlencoded` の検証、ステップ関数の順次呼び出し、`ParError` の JSON 応答化を行う。`parConfig`（`expiresInSeconds: 60` と `requirePushedAuthorizationRequests: false`）もこのファイルにあり、モジュール読み込み時に `assertParExpiresInSeconds` で検証される
- **routes/authorize.ts の変更**：認可処理の前段に `resolvePushedRequestUri` を差し込み、URN 形式の `request_uri` を展開する。PAR 必須設定のときは `assertPushedRequestUsed` を先に通す。catch 節に `PushedRequestUriError` の非リダイレクト分岐が加わる
- **routes/discovery.ts の変更**：メタデータに `pushed_authorization_request_endpoint` を追加し、必須設定のときは `require_pushed_authorization_requests: true` も広告する
- **store.ts の変更**：`parStore`（`PushedAuthorizationRequestStore` の実装）が加わる
- **app.ts / apply.ts の変更**：`/par` ルートのマウント、メソッド制約（POST のみ）、CORS の適用
- **conformance.test.ts の変更**：上記すべての挙動を契約テストとして固定する

リクエストの経路をまとめると、`POST /par` は「ボディ検証 → クライアント認証 → 認可リクエスト検証 → 保存 → 201」、`GET /authorize` は「（必須設定なら PAR 使用ガード →）URN 展開 → 従来の認可処理」という流れになる。

### 生成コードに入る差分の全文（hono）

以下は、デフォルト構成（`default-op`）と `--enable par`（`with-par`）の生成結果の差分そのもので、`--enable par` が生成コードに足すもののすべてである。
conformance.test.ts の差分には、この機能が生成 OP に保証させる挙動（契約テスト）がすべて含まれるので、仕様と実装の突き合わせはそこを起点にするとよい。

````diff
diff --git a/default-op/app.ts b/with-par/app.ts
index 4246f6b..270379c 100644
--- a/default-op/app.ts
+++ b/with-par/app.ts
@@ -5,6 +5,7 @@ import { tokenApp } from './routes/token.js';
 import { userinfoApp } from './routes/userinfo.js';
 import { introspectionApp } from './routes/introspection.js';
 import { revocationApp } from './routes/revocation.js';
+import { parApp } from './routes/par.js';
 import { jwksApp } from './routes/jwks.js';
 import { discoveryApp } from './routes/discovery.js';
 import { loginApp } from './routes/login.js';
@@ -19,6 +20,7 @@ import {
 } from './resolvers.js';
 import {
   defaultProviderStores,
+  parStore,
   type ProviderStores,
   type ProviderStoresFactory,
 } from './store.js';
@@ -105,6 +107,7 @@ const OIDC_ENDPOINT_METHODS: Readonly<Record<string, readonly string[]>> = {
   '/userinfo': ['GET', 'POST'],
   '/introspect': ['POST'],
   '/revoke': ['POST'],
+  '/par': ['POST'],
   '/.well-known/jwks.json': ['GET'],
   '/.well-known/openid-configuration': ['GET'],
   '/login': ['GET', 'POST'],
@@ -148,6 +151,7 @@ export function createApp(options: CreateAppOptions): Hono<{ Variables: Record<s
   app.use('/userinfo', protectedCors);
   app.use('/introspect', protectedCors);
   app.use('/revoke', protectedCors);
+  app.use('/par', protectedCors);
   app.use('/.well-known/openid-configuration', publicCors);
   app.use('/.well-known/jwks.json', publicCors);
   // CORS must run first so OPTIONS preflights are answered before method enforcement.
@@ -215,6 +219,7 @@ export function createApp(options: CreateAppOptions): Hono<{ Variables: Record<s
     c.set('introspectionAccessTokenResolver', storeResolvers.introspectionAccessTokenResolver);
     c.set('introspectionRefreshTokenResolver', storeResolvers.introspectionRefreshTokenResolver);
     c.set('revocationResolvers', storeResolvers.revocationResolvers);
+    c.set('parStore', parStore);
 
     // P1: default cookie-based session + consent resolvers so prompt=none /
     // max_age / SSO work out of the box (OIDC Core 1.0 Section 3.1.2.1 / 3.1.2.3).
@@ -238,6 +243,7 @@ export function createApp(options: CreateAppOptions): Hono<{ Variables: Record<s
   app.route('/userinfo', userinfoApp);
   app.route('/introspect', introspectionApp);
   app.route('/revoke', revocationApp);
+  app.route('/par', parApp);
   app.route('/.well-known/jwks.json', jwksApp);
   app.route('/.well-known/openid-configuration', discoveryApp);
   app.route('/login', loginApp);
diff --git a/default-op/apply.ts b/with-par/apply.ts
index db15234..ec6d629 100644
--- a/default-op/apply.ts
+++ b/with-par/apply.ts
@@ -5,6 +5,7 @@ import { tokenApp } from './routes/token.js';
 import { userinfoApp } from './routes/userinfo.js';
 import { introspectionApp } from './routes/introspection.js';
 import { revocationApp } from './routes/revocation.js';
+import { parApp } from './routes/par.js';
 import { jwksApp } from './routes/jwks.js';
 import { discoveryApp } from './routes/discovery.js';
 import { loginApp } from './routes/login.js';
@@ -19,6 +20,7 @@ import {
 } from './resolvers.js';
 import {
   defaultProviderStores,
+  parStore,
   type ProviderStores,
   type ProviderStoresFactory,
 } from './store.js';
@@ -136,6 +138,7 @@ const OIDC_ENDPOINT_METHODS: Readonly<Record<string, readonly string[]>> = {
   '/userinfo': ['GET', 'POST'],
   '/introspect': ['POST'],
   '/revoke': ['POST'],
+  '/par': ['POST'],
   '/.well-known/jwks.json': ['GET'],
   '/.well-known/openid-configuration': ['GET'],
   '/login': ['GET', 'POST'],
@@ -191,6 +194,7 @@ export function applyOidc(app: Hono<any>, options: ApplyOidcOptions): void {
   app.use('/userinfo', protectedCors);
   app.use('/introspect', protectedCors);
   app.use('/revoke', protectedCors);
+  app.use('/par', protectedCors);
   app.use('/.well-known/openid-configuration', publicCors);
   app.use('/.well-known/jwks.json', publicCors);
   // CORS must run first so OPTIONS preflights are answered before method enforcement.
@@ -266,6 +270,7 @@ export function applyOidc(app: Hono<any>, options: ApplyOidcOptions): void {
     c.set('introspectionAccessTokenResolver', storeResolvers.introspectionAccessTokenResolver);
     c.set('introspectionRefreshTokenResolver', storeResolvers.introspectionRefreshTokenResolver);
     c.set('revocationResolvers', storeResolvers.revocationResolvers);
+    c.set('parStore', parStore);
 
     // T-015: acr / amr resolver (optional; undefined preserves T-009 hold behavior).
     if (options.acrResolver) {
@@ -289,6 +294,7 @@ export function applyOidc(app: Hono<any>, options: ApplyOidcOptions): void {
   app.route('/userinfo', userinfoApp);
   app.route('/introspect', introspectionApp);
   app.route('/revoke', revocationApp);
+  app.route('/par', parApp);
   app.route('/.well-known/jwks.json', jwksApp);
   app.route('/.well-known/openid-configuration', discoveryApp);
   app.route('/login', loginApp);
diff --git a/default-op/conformance.test.ts b/with-par/conformance.test.ts
index 58258e6..2a12eca 100644
--- a/default-op/conformance.test.ts
+++ b/with-par/conformance.test.ts
@@ -9,6 +9,8 @@ import { accessTokenStore, authSessionStore, consentStore, createJsonProviderSto
 import { consentResolver } from './resolvers.js';
 import { defaultViews } from './views.js';
 import { renderView } from './views.js';
+import { parStore } from './store.js';
+import { parConfig } from './routes/par.js';
 
 /**
  * HTTP conformance smoke tests for the generated OpenID Connect Provider.
@@ -2474,6 +2476,416 @@ describe('generated provider HTTP conformance', () => {
   });
 
 
+  // EXPERIMENTAL — Pushed Authorization Requests (RFC 9126). Generated because
+  // this provider was created with --enable par. These tests pin the contract the
+  // repository guarantees for the generated PAR endpoint: change the behavior and
+  // they fail, which is how a customized OP learns it has drifted.
+  describe('Pushed Authorization Requests (RFC 9126)', () => {
+    // RFC 7636 Appendix B example PKCE pair (verifier -> its S256 challenge).
+    const PKCE_VERIFIER = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
+    const PKCE_CHALLENGE_S256 = 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM';
+    const REQUEST_URI_PREFIX = 'urn:ietf:params:oauth:request_uri:';
+    const OPAQUE_FAILURE_DESCRIPTION =
+      'The request_uri is invalid, expired, or has already been used';
+
+    // Pure helpers: they fetch and parse only. Every assertion lives in an it().
+    function pushedRequestBody(overrides: Record<string, string> = {}): Record<string, string> {
+      return {
+        response_type: 'code',
+        client_id: 'c-conf',
+        client_secret: 's',
+        redirect_uri: REDIRECT_URI,
+        scope: 'openid',
+        state: 'par-state',
+        nonce: 'par-nonce',
+        code_challenge: PKCE_CHALLENGE_S256,
+        code_challenge_method: 'S256',
+        ...overrides,
+      };
+    }
+
+    function pushRequest(body: Record<string, string>): Promise<Response> {
+      return app.request('/par', {
+        method: 'POST',
+        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
+        body: new URLSearchParams(body).toString(),
+      });
+    }
+
+    async function pushAndGetRequestUri(overrides: Record<string, string> = {}): Promise<string> {
+      const res = await pushRequest(pushedRequestBody(overrides));
+      const body = await res.json();
+      return body.request_uri as string;
+    }
+
+    function authorizeWithRequestUri(requestUri: string, clientId = 'c-conf'): Promise<Response> {
+      return app.request(
+        '/authorize?client_id=' + clientId + '&request_uri=' + encodeURIComponent(requestUri),
+        { headers: { Accept: 'application/json' } },
+      );
+    }
+
+    function relativeFrom(location: string | null): string {
+      const url = new URL(location ?? '', 'http://localhost');
+      return url.pathname + url.search;
+    }
+
+    function csrfFrom(html: string): string {
+      return html.match(/name="csrf_token" value="([^"]+)"/)?.[1] ?? '';
+    }
+
+    describe('Endpoint response', () => {
+      it('should return 201 with a URN request_uri and the configured lifetime', async () => {
+        // RFC 9126 §2.2: 201 Created, application/json, Cache-Control: no-cache, no-store.
+        const res = await pushRequest(pushedRequestBody());
+        const body = await res.json();
+
+        expect(res.status).toBe(201);
+        expect(res.headers.get('Content-Type')).toBe('application/json');
+        expect(res.headers.get('Cache-Control')).toBe('no-cache, no-store');
+        expect(Object.keys(body).sort()).toEqual(['expires_in', 'request_uri']);
+        expect(body.expires_in).toBe(60);
+        expect((body.request_uri as string).startsWith(REQUEST_URI_PREFIX)).toBe(true);
+        expect((body.request_uri as string).slice(REQUEST_URI_PREFIX.length)).toHaveLength(43);
+      });
+
+      it('should issue a different request_uri for every pushed request', async () => {
+        const first = await pushAndGetRequestUri();
+        const second = await pushAndGetRequestUri();
+
+        expect(first === second).toBe(false);
+      });
+
+      it('should reject a request that is not form-urlencoded', async () => {
+        const res = await app.request('/par', {
+          method: 'POST',
+          headers: { 'Content-Type': 'application/json' },
+          body: JSON.stringify(pushedRequestBody()),
+        });
+
+        expect(res.status).toBe(400);
+        expect(await res.json()).toEqual({
+          error: 'invalid_request',
+          error_description: 'Pushed authorization requests must use application/x-www-form-urlencoded',
+        });
+      });
+
+      it('should reject a GET on the PAR endpoint with 405', async () => {
+        // RFC 9126 §2.3 lists 405 among the responses the endpoint may return.
+        const res = await app.request('/par');
+
+        expect(res.status).toBe(405);
+        expect(res.headers.get('Allow')).toBe('POST');
+      });
+    });
+
+    describe('Client authentication', () => {
+      it('should reject an unauthenticated pushed request with 401 invalid_client', async () => {
+        const body = pushedRequestBody();
+        delete body.client_secret;
+        const res = await pushRequest(body);
+
+        expect(res.status).toBe(401);
+        expect(res.headers.get('WWW-Authenticate')).toBe('Basic realm="Client Authentication"');
+        expect((await res.json()).error).toBe('invalid_client');
+      });
+
+      it('should reject a wrong client_secret with 401 invalid_client', async () => {
+        const res = await pushRequest(pushedRequestBody({ client_secret: 'wrong' }));
+
+        expect(res.status).toBe(401);
+        expect((await res.json()).error).toBe('invalid_client');
+      });
+    });
+
+    describe('Pushed parameter validation', () => {
+      it('should reject a request_uri inside the pushed body', async () => {
+        // RFC 9126 §2.1: request_uri MUST NOT be provided in a pushed request.
+        const res = await pushRequest(
+          pushedRequestBody({ request_uri: REQUEST_URI_PREFIX + 'anything' }),
+        );
+
+        expect(res.status).toBe(400);
+        expect(await res.json()).toEqual({
+          error: 'invalid_request',
+          error_description: 'request_uri MUST NOT be included in a pushed authorization request',
+        });
+      });
+
+      it('should reject a request parameter because PAR with a Request Object is unsupported', async () => {
+        const res = await pushRequest(pushedRequestBody({ request: 'eyJhbGciOiJSUzI1NiJ9.e30.s' }));
+
+        expect(res.status).toBe(400);
+        expect(await res.json()).toEqual({
+          error: 'invalid_request',
+          error_description: 'The request parameter (Request Object) is not supported by this pushed authorization request endpoint',
+        });
+      });
+
+      it('should reject an unregistered redirect_uri before the user sees anything', async () => {
+        // RFC 9126 §2.1: the pushed request is validated as an authorization request
+        // would be — so this fails on the back channel, with no redirect.
+        const res = await pushRequest(
+          pushedRequestBody({ redirect_uri: 'http://attacker.example/cb' }),
+        );
+
+        expect(res.status).toBe(400);
+        expect(res.headers.get('Location')).toBe(null);
+        expect((await res.json()).error).toBe('invalid_request');
+      });
+
+      it('should reject a scope without openid as invalid_scope', async () => {
+        const res = await pushRequest(pushedRequestBody({ scope: 'profile' }));
+
+        expect(res.status).toBe(400);
+        expect((await res.json()).error).toBe('invalid_scope');
+      });
+    });
+
+    describe('Authorization endpoint resolution', () => {
+      it('should complete the full PAR to token flow', async () => {
+        const requestUri = await pushAndGetRequestUri();
+
+        const authorizeRes = await app.request(
+          '/authorize?client_id=c-conf&request_uri=' + encodeURIComponent(requestUri),
+        );
+        const loginPath = relativeFrom(authorizeRes.headers.get('Location'));
+        // Carry forward whatever cookie /authorize set, exactly as a browser would.
+        // With --enable transaction-binding this is the per-transaction binding
+        // secret the later steps require; without it this is '' and the OP ignores
+        // it, so the same flow works in both builds.
+        const bindingCookie = (authorizeRes.headers.get('Set-Cookie') ?? '').split(';')[0] ?? '';
+        const transactionId =
+          new URL(loginPath, 'http://localhost').searchParams.get('transaction_id') ?? '';
+        const loginGet = await app.request(loginPath, { headers: { Cookie: bindingCookie } });
+        const loginRes = await app.request('/login', {
+          method: 'POST',
+          headers: { 'Content-Type': 'application/x-www-form-urlencoded', Cookie: bindingCookie },
+          body: new URLSearchParams({
+            transaction_id: transactionId,
+            csrf_token: csrfFrom(await loginGet.text()),
+            username: 'testuser',
+            password: 'password',
+          }).toString(),
+        });
+        const consentPath = relativeFrom(loginRes.headers.get('Location'));
+        const consentGet = await app.request(consentPath, { headers: { Cookie: bindingCookie } });
+        const consentRes = await app.request('/consent', {
+          method: 'POST',
+          headers: { 'Content-Type': 'application/x-www-form-urlencoded', Cookie: bindingCookie },
+          body: new URLSearchParams({
+            transaction_id: transactionId,
+            csrf_token: csrfFrom(await consentGet.text()),
+            action: 'approve',
+          }).toString(),
+        });
+        const callback = new URL(consentRes.headers.get('Location') ?? '', 'http://localhost');
+
+        expect(authorizeRes.status).toBe(302);
+        expect(loginPath.startsWith('/login?')).toBe(true);
+        expect(consentPath.startsWith('/consent?')).toBe(true);
+        // The pushed state is what comes back, proving the stored parameters were used.
+        expect(callback.searchParams.get('state')).toBe('par-state');
+
+        const tokenRes = await app.request('/token', {
+          method: 'POST',
+          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
+          body: new URLSearchParams({
+            grant_type: 'authorization_code',
+            client_id: 'c-conf',
+            client_secret: 's',
+            code: callback.searchParams.get('code') ?? '',
+            redirect_uri: REDIRECT_URI,
+            code_verifier: PKCE_VERIFIER,
+          }).toString(),
+        });
+        const tokenBody = await tokenRes.json();
+
+        expect(tokenRes.status).toBe(200);
+        // The nonce pushed to /par is the one bound into the ID Token (OIDC Core §2).
+        expect(idTokenPayload(tokenBody.id_token as string).nonce).toBe('par-nonce');
+      });
+
+      it('should keep the pushed parameters authoritative over the query string', async () => {
+        // RFC 9126 §4: the client sends only client_id and request_uri; anything else
+        // in the query is ignored so it cannot tamper with the pushed request.
+        const requestUri = await pushAndGetRequestUri();
+
+        const authorizeRes = await app.request(
+          '/authorize?client_id=c-conf&scope=openid+admin&state=tampered&request_uri=' +
+            encodeURIComponent(requestUri),
+        );
+        const loginPath = relativeFrom(authorizeRes.headers.get('Location'));
+        // Carry forward whatever cookie /authorize set, exactly as a browser would.
+        // With --enable transaction-binding this is the per-transaction binding
+        // secret the later steps require; without it this is '' and the OP ignores
+        // it, so the same flow works in both builds.
+        const bindingCookie = (authorizeRes.headers.get('Set-Cookie') ?? '').split(';')[0] ?? '';
+        const transactionId =
+          new URL(loginPath, 'http://localhost').searchParams.get('transaction_id') ?? '';
+        const loginGet = await app.request(loginPath, { headers: { Cookie: bindingCookie } });
+        const loginRes = await app.request('/login', {
+          method: 'POST',
+          headers: { 'Content-Type': 'application/x-www-form-urlencoded', Cookie: bindingCookie },
+          body: new URLSearchParams({
+            transaction_id: transactionId,
+            csrf_token: csrfFrom(await loginGet.text()),
+            username: 'testuser',
+            password: 'password',
+          }).toString(),
+        });
+        const consentPath = relativeFrom(loginRes.headers.get('Location'));
+        const consentHtml = await (await app.request(consentPath, { headers: { Cookie: bindingCookie } })).text();
+
+        expect(authorizeRes.status).toBe(302);
+        // The consent screen lists the pushed scope, not the tampered one.
+        expect(consentHtml.includes('<li>admin</li>')).toBe(false);
+      });
+
+      it('should reject the second use of the same request_uri', async () => {
+        // RFC 9126 §7.3: single use. A browser reload of the authorize URL fails too;
+        // that is the intended trade-off of not allowing the §4 duplicate-use MAY.
+        const requestUri = await pushAndGetRequestUri();
+        const first = await app.request(
+          '/authorize?client_id=c-conf&request_uri=' + encodeURIComponent(requestUri),
+        );
+        const second = await authorizeWithRequestUri(requestUri);
+
+        expect(first.status).toBe(302);
+        expect(second.status).toBe(400);
+        expect(await second.json()).toEqual({
+          error: 'invalid_request_uri',
+          error_description: OPAQUE_FAILURE_DESCRIPTION,
+        });
+      });
+
+      it('should reject an expired request_uri', async () => {
+        // RFC 9126 §4: "An expired request_uri MUST be rejected as invalid."
+        const requestUri = REQUEST_URI_PREFIX + 'expired-conformance-reference';
+        await parStore.save({
+          requestUri,
+          clientId: 'c-conf',
+          params: pushedRequestBody({ client_secret: '' }),
+          createdAt: new Date(Date.now() - 120_000),
+          expiresAt: new Date(Date.now() - 60_000),
+        });
+
+        const res = await authorizeWithRequestUri(requestUri);
+
+        expect(res.status).toBe(400);
+        expect((await res.json()).error).toBe('invalid_request_uri');
+      });
+
+      it('should reject a request_uri presented by a different client', async () => {
+        // RFC 9126 §2.2: the request_uri MUST be bound to the client that pushed it.
+        const requestUri = await pushAndGetRequestUri();
+
+        const res = await authorizeWithRequestUri(requestUri, 'c-public');
+
+        expect(res.status).toBe(400);
+        expect((await res.json()).error).toBe('invalid_request_uri');
+      });
+
+      it('should return the identical response for every resolution failure', async () => {
+        // The response must not reveal whether a given request_uri ever existed.
+        const consumed = await pushAndGetRequestUri();
+        await app.request('/authorize?client_id=c-conf&request_uri=' + encodeURIComponent(consumed));
+        const reused = await authorizeWithRequestUri(consumed);
+        const unknown = await authorizeWithRequestUri(REQUEST_URI_PREFIX + 'never-issued');
+        const stolen = await pushAndGetRequestUri();
+        const mismatched = await authorizeWithRequestUri(stolen, 'c-public');
+
+        expect([reused.status, unknown.status, mismatched.status]).toEqual([400, 400, 400]);
+        expect([await reused.json(), await unknown.json(), await mismatched.json()]).toEqual([
+          { error: 'invalid_request_uri', error_description: OPAQUE_FAILURE_DESCRIPTION },
+          { error: 'invalid_request_uri', error_description: OPAQUE_FAILURE_DESCRIPTION },
+          { error: 'invalid_request_uri', error_description: OPAQUE_FAILURE_DESCRIPTION },
+        ]);
+      });
+
+      it('should never redirect a resolution failure to the client', async () => {
+        // RFC 6749 §4.1.2.1: without a verified redirect_uri the OP MUST NOT redirect.
+        const res = await authorizeWithRequestUri(REQUEST_URI_PREFIX + 'never-issued');
+
+        expect(res.status).toBe(400);
+        expect(res.headers.get('Location')).toBe(null);
+      });
+
+      it('should leave a URL-form request_uri to the core request_uri_not_supported path', async () => {
+        // OIDC Core 1.0 §6.2 by-reference request objects stay unsupported.
+        const res = await app.request(
+          '/authorize?response_type=code&client_id=c-conf' +
+            '&redirect_uri=' + encodeURIComponent(REDIRECT_URI) +
+            '&scope=openid&state=url-form' +
+            '&code_challenge=' + PKCE_CHALLENGE_S256 + '&code_challenge_method=S256' +
+            '&request_uri=' + encodeURIComponent('https://client.example/request.jwt'),
+        );
+        const location = new URL(res.headers.get('Location') ?? '', 'http://localhost');
+
+        expect(res.status).toBe(302);
+        expect(location.searchParams.get('error')).toBe('request_uri_not_supported');
+      });
+    });
+
+    describe('Provider metadata and PAR enforcement', () => {
+      it('should advertise the pushed_authorization_request_endpoint', async () => {
+        // RFC 9126 §5.
+        const res = await app.request('/.well-known/openid-configuration');
+        const metadata = await res.json();
+
+        expect(metadata.pushed_authorization_request_endpoint).toBe(
+          'http://localhost:3000/par',
+        );
+      });
+
+      it('should not advertise require_pushed_authorization_requests while PAR is optional', async () => {
+        const metadata = await (await app.request('/.well-known/openid-configuration')).json();
+
+        expect(metadata.require_pushed_authorization_requests).toBe(undefined);
+      });
+
+      it('should advertise require_pushed_authorization_requests when PAR is enforced', async () => {
+        parConfig.requirePushedAuthorizationRequests = true;
+        const metadata = await (await app.request('/.well-known/openid-configuration')).json();
+        parConfig.requirePushedAuthorizationRequests = false;
+
+        expect(metadata.require_pushed_authorization_requests).toBe(true);
+      });
+
+      it('should reject a non-pushed authorization request when PAR is enforced', async () => {
+        // RFC 9126 §5. The rejection is non-redirect, like every other PAR failure.
+        parConfig.requirePushedAuthorizationRequests = true;
+        const res = await app.request(
+          '/authorize?response_type=code&client_id=c-conf' +
+            '&redirect_uri=' + encodeURIComponent(REDIRECT_URI) +
+            '&scope=openid&state=no-par' +
+            '&code_challenge=' + PKCE_CHALLENGE_S256 + '&code_challenge_method=S256',
+          { headers: { Accept: 'application/json' } },
+        );
+        const body = await res.json();
+        parConfig.requirePushedAuthorizationRequests = false;
+
+        expect(res.status).toBe(400);
+        expect(res.headers.get('Location')).toBe(null);
+        expect(body).toEqual({
+          error: 'invalid_request',
+          error_description: 'Pushed authorization requests are required by this authorization server',
+        });
+      });
+
+      it('should still accept a pushed request while PAR is enforced', async () => {
+        parConfig.requirePushedAuthorizationRequests = true;
+        const requestUri = await pushAndGetRequestUri();
+        const res = await app.request(
+          '/authorize?client_id=c-conf&request_uri=' + encodeURIComponent(requestUri),
+        );
+        parConfig.requirePushedAuthorizationRequests = false;
+
+        expect(res.status).toBe(302);
+      });
+    });
+  });
+
   // The device authorization grant is disabled in this generated provider: no
   // endpoint, no metadata, and the URN stays an unsupported grant. These pin the
   // default-off contract so enabling the feature by accident is visible.
diff --git a/default-op/routes/authorize.ts b/with-par/routes/authorize.ts
index a3ffab2..cfa29de 100644
--- a/default-op/routes/authorize.ts
+++ b/with-par/routes/authorize.ts
@@ -37,6 +37,13 @@ import {
   authSessionStore as defaultAuthSessionStore,
 } from '../store.js';
 import { defaultViews, renderView } from '../views.js';
+import {
+  PushedRequestUriError,
+  assertPushedRequestUsed,
+  resolvePushedRequestUri,
+} from '@maronn-openid-connect/experimental/par';
+import { parConfig } from './par.js';
+import { parStore as defaultParStore } from '../store.js';
 
 export const authorizeApp = new Hono<{ Variables: Record<string, any> }>();
 
@@ -147,9 +154,31 @@ const handleAuthorizationRequest = async (c: any) => {
     return c.json({ error: 'invalid_request', error_description: 'Missing required parameter: client_id' }, 400);
   }
 
-  const params = rawParams;
+  let params = rawParams;
 
   try {
+    // EXPERIMENTAL — Pushed Authorization Requests (RFC 9126 §4).
+    const parStore = c.get('parStore') ?? defaultParStore;
+    // RFC 9126 §5: when require_pushed_authorization_requests is on, an
+    // authorization request that did not go through /par is rejected outright.
+    if (parConfig.requirePushedAuthorizationRequests) {
+      assertPushedRequestUsed(rawParams);
+    }
+    // Expand a request_uri of the form urn:ietf:params:oauth:request_uri:<ref> into
+    // the parameters pushed to /par. The reference is single use and short lived,
+    // so a reload of this URL fails with invalid_request_uri by design.
+    // Anything that is not a URN (absent, or an OIDC Core §6.2 URL) returns null
+    // and is left to the normal pipeline, which rejects it with
+    // request_uri_not_supported.
+    const pushedParams = await resolvePushedRequestUri({ params: rawParams, store: parStore });
+    if (pushedParams !== null) {
+      if (!isAuthorizationRequestParams(pushedParams)) {
+        // Defensive: client_id was validated when the request was pushed.
+        throw new PushedRequestUriError('invalid_request_uri', 'The request_uri is invalid, expired, or has already been used');
+      }
+      params = pushedParams;
+    }
+
     const clientResolver = c.get('clientResolver') ?? defaultClientResolver;
     const transactionStore = c.get('transactionStore') ?? defaultTransactionStore;
     const authCodeStore = c.get('authCodeStore') ?? defaultAuthCodeStore;
@@ -501,6 +530,35 @@ const handleAuthorizationRequest = async (c: any) => {
     loginUrl.searchParams.set('transaction_id', transactionId);
     return c.redirect(loginUrl.toString());
   } catch (error) {
+    if (error instanceof PushedRequestUriError) {
+      // RFC 9126 §4 / OIDC Core 1.0 §3.1.2.6: a request_uri that cannot be
+      // resolved leaves us without a verified redirect_uri, so this error is
+      // NEVER redirected (RFC 6749 §4.1.2.1). It is rendered through the same
+      // non-redirect path as AuthorizationError below. Every failure kind
+      // (unknown / used / expired / wrong client) returns the identical code and
+      // description so the response cannot be used as an existence oracle.
+      const acceptsJson = (c.req.header('Accept') ?? '').includes('application/json');
+      if (acceptsJson) {
+        return c.json({ error: error.code, error_description: error.errorDescription }, 400);
+      }
+      const parErrorPagePath = c.get('config').authorizationErrorRedirectPath;
+      if (parErrorPagePath && parErrorPagePath.startsWith('/') && !parErrorPagePath.startsWith('//')) {
+        const parErrorParams = new URLSearchParams({
+          error: error.code,
+          error_description: error.errorDescription,
+        });
+        return c.redirect(`${parErrorPagePath}?${parErrorParams.toString()}`, 303);
+      }
+      const parViews = c.get('views') ?? defaultViews;
+      return renderView(
+        parViews.errorPage({
+          error: error.code,
+          errorDescription: error.errorDescription,
+          statusCode: 400,
+        }),
+        { status: 400 },
+      );
+    }
     if (error instanceof AuthorizationError) {
       if (error.redirectUri) {
         const redirectUrl = new URL(error.redirectUri);
diff --git a/default-op/routes/discovery.ts b/with-par/routes/discovery.ts
index 72c0758..364ac2a 100644
--- a/default-op/routes/discovery.ts
+++ b/with-par/routes/discovery.ts
@@ -1,6 +1,7 @@
 import { Hono } from 'hono';
 import { buildProviderMetadata, getJwaAlgorithm, type SigningKey } from '@maronn-openid-connect/core';
 import { defaultProviderConfig } from '../config.js';
+import { parConfig } from './par.js';
 
 export const discoveryApp = new Hono<{ Variables: Record<string, any> }>();
 
@@ -144,5 +145,11 @@ discoveryApp.get('/', (c) => {
   return c.json({
     ...metadata,
     code_challenge_methods_supported: ['S256'],
+    // EXPERIMENTAL — RFC 9126 §5 metadata. require_pushed_authorization_requests
+    // is only advertised when PAR is actually enforced (its default is false).
+    pushed_authorization_request_endpoint: `${issuer}/par`,
+    ...(parConfig.requirePushedAuthorizationRequests
+      ? { require_pushed_authorization_requests: true }
+      : {}),
   });
 });
diff --git a/with-par/routes/par.ts b/with-par/routes/par.ts
new file mode 100644
index 0000000..0369ff8
--- /dev/null
+++ b/with-par/routes/par.ts
@@ -0,0 +1,157 @@
+/**
+ * EXPERIMENTAL — Pushed Authorization Requests (RFC 9126).
+ *
+ * This route was generated because the OP was created with `--enable par`.
+ * It is backed by @maronn-openid-connect/experimental, whose API is NOT stable: it may
+ * change in a breaking way between releases. Do not build production code on it
+ * without pinning the version.
+ *
+ * The client POSTs the authorization request parameters here (back channel,
+ * authenticated) and receives a short-lived `request_uri` reference that it
+ * then passes to /authorize.
+ */
+import { Hono } from 'hono';
+import {
+  ParError,
+  assertParExpiresInSeconds,
+  authenticateParClient,
+  buildPushedAuthorizationResponse,
+  createPushedAuthorizationRecord,
+  rejectForbiddenParParams,
+  validatePushedAuthorizationParams,
+} from '@maronn-openid-connect/experimental/par';
+import { sanitizeErrorDescription } from '@maronn-openid-connect/core';
+import { clientResolver as defaultClientResolver } from '../resolvers.js';
+import { parStore as defaultParStore } from '../store.js';
+
+/**
+ * PAR settings. Imported by the authorize route, so keep both files in sync when
+ * changing them.
+ *
+ * - expiresInSeconds: request_uri lifetime. RFC 9126 §2.2 recommends 5–600
+ *   seconds; values outside that range fail fast at module load.
+ * - requirePushedAuthorizationRequests: RFC 9126 §5. When true, /authorize
+ *   rejects any request that did not go through this endpoint, and discovery
+ *   advertises require_pushed_authorization_requests: true.
+ */
+export const parConfig = {
+  expiresInSeconds: 60,
+  requirePushedAuthorizationRequests: false,
+};
+
+assertParExpiresInSeconds(parConfig.expiresInSeconds);
+
+export const parApp = new Hono<{ Variables: Record<string, any> }>();
+
+/**
+ * RFC 9126 §2.1: the pushed authorization request body MUST be
+ * application/x-www-form-urlencoded.
+ */
+function isFormUrlEncoded(contentType: string): boolean {
+  const [mediaType = ''] = contentType.toLowerCase().split(';');
+  return mediaType.trim() === 'application/x-www-form-urlencoded';
+}
+
+/**
+ * Pushed Authorization Request Endpoint
+ * RFC 9126 §2
+ *
+ * NOTE (RFC 9126 §2.3): request size limits (413) and rate limiting (429) are
+ * deliberately left to the deployment layer (reverse proxy / platform), not
+ * implemented here. This endpoint is unauthenticated until the client
+ * credentials are checked, so put a rate limit in front of it in production.
+ */
+parApp.post('/', async (c) => {
+  const contentType = c.req.header('Content-Type') ?? '';
+  if (!isFormUrlEncoded(contentType)) {
+    c.header('Cache-Control', 'no-cache, no-store');
+    c.header('Pragma', 'no-cache');
+    return c.json({ error: 'invalid_request', error_description: 'Pushed authorization requests must use application/x-www-form-urlencoded' }, 400);
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
+    c.header('Cache-Control', 'no-cache, no-store');
+    c.header('Pragma', 'no-cache');
+    return c.json({ error: 'invalid_request', error_description: `Parameter "${sanitizeErrorDescription(duplicateKey)}" must not be repeated` }, 400);
+  }
+
+  const authorization = c.req.header('Authorization') ?? '';
+
+  try {
+    const clientResolver = c.get('clientResolver') ?? defaultClientResolver;
+    const parStore = c.get('parStore') ?? defaultParStore;
+    const config = c.get('config');
+
+    // --- Pushed authorization request pipeline ------------------------------
+    // Each step below is an independent function from @maronn-openid-connect/experimental/par,
+    // called in RFC 9126 §2.1 order. Delete a call to drop that validation, or
+    // insert your own logic between steps.
+
+    // RFC 9126 §2.1: request_uri MUST NOT be pushed. The request parameter
+    // (PAR + JAR, §3) is not supported by this generated provider.
+    rejectForbiddenParParams(params);
+
+    // RFC 9126 §2.1: authenticate exactly like the token endpoint does.
+    // Public clients present only client_id (no credentials).
+    const clientId = await authenticateParClient({
+      params,
+      authorizationHeader: authorization,
+      clientResolver,
+    });
+
+    // client_id is a required authorization request parameter (RFC 9126 §2.1),
+    // so pin it to the authenticated client before validating and storing.
+    const pushedParams = { ...params, client_id: clientId };
+
+    // RFC 9126 §2.1: "validate the request the same way the authorization
+    // endpoint would" — an unregistered redirect_uri or a bad scope fails here,
+    // before the user ever sees a screen.
+    await validatePushedAuthorizationParams(pushedParams, clientResolver, {
+      allowNonPkceAuthorizationCodeFlow: config.allowNonPkceAuthorizationCodeFlow,
+    });
+
+    // RFC 9126 §2.2 / §7.1: mint a cryptographically random reference value and
+    // store the request under it. Client credentials are never persisted.
+    const record = await createPushedAuthorizationRecord({
+      clientId,
+      params: pushedParams,
+      store: parStore,
+      expiresInSeconds: parConfig.expiresInSeconds,
+    });
+    const response = buildPushedAuthorizationResponse(record);
+
+    // Never log the pushed parameters themselves: they can carry PII such as
+    // login_hint, and the Authorization header carries the client_secret.
+
+    // RFC 9126 §2.2: 201 Created with a non-cacheable JSON body.
+    c.header('Cache-Control', 'no-cache, no-store');
+    c.header('Pragma', 'no-cache');
+    return c.json({ request_uri: response.requestUri, expires_in: response.expiresIn }, 201);
+  } catch (error) {
+    c.header('Cache-Control', 'no-cache, no-store');
+    c.header('Pragma', 'no-cache');
+    if (error instanceof ParError) {
+      // RFC 9126 §2.3: token-endpoint style JSON errors. This endpoint never redirects.
+      if (error.wwwAuthenticate) {
+        c.header('WWW-Authenticate', error.wwwAuthenticate);
+      }
+      return c.json({ error: error.code, error_description: error.errorDescription }, error.statusCode);
+    }
+    return c.json({ error: 'server_error' }, 500);
+  }
+});
diff --git a/default-op/store.ts b/with-par/store.ts
index e530896..ef42ec2 100644
--- a/default-op/store.ts
+++ b/with-par/store.ts
@@ -6,6 +6,10 @@ import type {
   RefreshTokenInfo,
   UserClaims,
 } from '@maronn-openid-connect/core';
+import type {
+  PushedAuthorizationRecord,
+  PushedAuthorizationRequestStore,
+} from '@maronn-openid-connect/experimental/par';
 
 /**
  * In-memory Authorization Transaction Store.
@@ -823,3 +827,58 @@ export const authSessionStore = defaultProviderStores.authSessionStore;
 export const browserSessionStore = defaultProviderStores.browserSessionStore;
 export const consentStore = defaultProviderStores.consentStore;
 export const userStore = defaultProviderStores.userStore;
+
+/**
+ * EXPERIMENTAL — in-memory Pushed Authorization Request store (RFC 9126).
+ *
+ * Replace with a persistent store (Redis, KV, database) in production. The
+ * contract is only two methods:
+ *
+ * - save(record): persist the pushed request, ideally with a TTL matching
+ *   record.expiresAt so entries cannot pile up (RFC 9126 §7.3).
+ * - consume(requestUri): fetch AND delete in one atomic operation. A
+ *   non-atomic implementation lets the same request_uri be replayed
+ *   concurrently. Treat requestUri as an opaque external value: never
+ *   interpolate it into a query, always bind it as a parameter.
+ */
+export class InMemoryPushedAuthorizationRequestStore
+  implements PushedAuthorizationRequestStore
+{
+  private records = new Map<string, PushedAuthorizationRecord>();
+
+  async save(record: PushedAuthorizationRecord): Promise<void> {
+    this.records.set(record.requestUri, record);
+  }
+
+  async consume(requestUri: string): Promise<PushedAuthorizationRecord | null> {
+    const record = this.records.get(requestUri);
+    // Single use (RFC 9126 §7.3): delete on read, expired or not, so a replay of
+    // the same reference can never succeed.
+    this.records.delete(requestUri);
+    if (!record) {
+      this.evictExpired();
+      return null;
+    }
+    return record;
+  }
+
+  /** Drop entries whose lifetime has passed so an idle store cannot grow unbounded. */
+  private evictExpired(): void {
+    const now = Date.now();
+    for (const [requestUri, record] of this.records) {
+      if (record.expiresAt.getTime() < now) {
+        this.records.delete(requestUri);
+      }
+    }
+  }
+}
+
+// Kept on globalThis for the same reason as the provider stores above: Next.js
+// instantiates route handlers and server actions in separate module layers.
+const parStoreRegistry = globalThis as typeof globalThis & {
+  __oidcPushedAuthorizationRequestStore?: PushedAuthorizationRequestStore;
+};
+
+export const parStore: PushedAuthorizationRequestStore =
+  (parStoreRegistry.__oidcPushedAuthorizationRequestStore ??=
+    new InMemoryPushedAuthorizationRequestStore());

````

### 他フレームワークの差分

express / fastify / nextjs にも同等の差分が入る（ルーティングの書き方だけがフレームワークに合わせて変わる）。
全文は昇格レビューパケットにある。

- [express](../../../tasks/experimental/done/par/promotion-review/generated-code/express.md)
- [fastify](../../../tasks/experimental/done/par/promotion-review/generated-code/fastify.md)
- [nextjs](../../../tasks/experimental/done/par/promotion-review/generated-code/nextjs.md)

サンプルでこの機能を有効にしているのは [samples/hono-cloudflare](../../../samples/hono-cloudflare) だけで、他機能と併用した合成結果はそのソースと conformance.test.ts で確認できる。

## E2E テストの全文

実ブラウザと実 HTTP で検証する E2E テストは、`--enable par` で生成された OP に対してだけ動く（discovery が PAR エンドポイントを広告しないサンプルではスキップされる）。
固定しているのは次の挙動である。

- pushed request_uri を使ったフローの完走（ブラウザが運ぶのは `client_id` と `request_uri` だけであること、consent 画面に pushed された scope が表示されること）
- 同じ `request_uri` の二度目の使用が拒否されること（単回使用）
- クライアント認証なしの pushed request の拒否
- 未知の `request_uri` が、リダイレクトせずに拒否されること

E2E 専用クライアント（`tests/e2e/apps/client.mjs`）は全機能で共有するハーネスなので、ここには載せずリンクで示す。

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

## 関連資料

- 利用者向けドキュメント：[docs/library-document experimental/par.md](../../library-document/src/content/docs/experimental/par.md)
- 仕様検討文書：[tasks/experimental/done/par/](../../../tasks/experimental/done/par/)（specification.md / understanding-guide.md / review-log.md）
- 昇格レビューパケット：[tasks/experimental/done/par/promotion-review/](../../../tasks/experimental/done/par/promotion-review/README.md)
- パッケージ全体の設計規約：[package-overview.ja.md](./package-overview.ja.md)
- English version: [par.en.md](./par.en.md)
