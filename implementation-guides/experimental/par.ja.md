# PAR（Pushed Authorization Requests）実装解説

この文書は、`packages/experimental` に実装した **Pushed Authorization Requests**（RFC 9126、以下 PAR）について、何を実装したのか、どう実装したのかを、関連するコードの全文とともに説明する。
読み終えたとき、実装の一行一行がなぜその形になっているかを追える状態を目指している。

この文書が全文を載せるのは次のコードである。

- `packages/experimental/src/par/` の実装 4 ファイルとテスト 2 ファイルのすべて
- CLI の `--enable par` が生成コードへ加えるコードの全文（hono）
- PAR の E2E テストスペックの全文

core 本体、E2E 共有ハーネス、他フレームワークの生成コードは全機能で共有される基盤なので、リンクで参照する。

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
2. `authenticateParClient`：クライアントを認証する（token endpoint と同一規則。後述）
3. `validatePushedAuthorizationParams`：pushed されたパラメータを、認可エンドポイントと同じ規則（core の `validateAuthorizationRequest`）で検証する
4. `createPushedAuthorizationRecord`：256 ビットの暗号論的乱数で参照値を生成し、レコードを保存する
5. `buildPushedAuthorizationResponse`：201 応答のボディ（`request_uri` と `expires_in`）を組み立てる

ステップ 2 は、資格情報の抽出から多重方式の判定まで core の `extractClientCredentials` 以降のステップへそのまま委譲する。
RFC 9126 §2.1 が PAR エンドポイントに求めるのは「token endpoint と同じクライアント認証」であり、core 側がその規則をすべて持っているからである。

- ヘッダ認証の対象は `Basic` スキームだけで、ゲートウェイが注入する `Bearer` など他スキームのヘッダは無視してボディの資格情報で認証する
- 空文字列の `client_secret` は「未提示」に正規化する（RFC 6749 §3.2 の「値のないパラメータは省略として扱う」MUST）
- `Basic` とボディの `client_secret`（非空）の併用は、OAuth 2.1 §2.3 の多重方式として `invalid_request` で拒否する
- RFC 9126 §2.1 の必須パラメータとしてボディに載る `client_id` は、`Basic` 併用時に core が Basic 側の `client_id` との一致を検証する（RFC 9126 §2.2 の「request_uri は pushed request を送ったクライアントに紐付く」を支える検査）

かつてこの関数は「Authorization ヘッダの有無」で分岐する独自実装だった。
当時の core はボディに `client_id` があること自体を `client_secret_post` の使用と見なしたため、ヘッダと併用すると多重方式として拒否されてしまい、PAR 側で資格情報を選り分ける必要があったからである。
その後 core が Basic スキーム判定と空シークレットの正規化を備えたことで独自実装の前提は消え、むしろ「同じ資格情報が `/token` では通り `/par` では 4xx になる」という §2.1 違反の食い違いだけが残った。
現在の全面委譲はこの食い違いを解消した形である。

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

### resolve-request-uri.ts（認可エンドポイント側の展開）

認可エンドポイントの前段に差し込む処理である。
`resolvePushedRequestUri` は、`request_uri` が URN 前置詞に一致するときだけ動き、それ以外は `null` を返して従来のフローへ合流させる。
この「一致しなければ何もしない」という振る舞いが、PAR 有効化が既存挙動を変えないことの保証になっている（URL 形式の `request_uri` は従来どおり core が `request_uri_not_supported` で拒否する）。

一致した場合は store の `consume` で単回使用として取得し、期限と client_id の紐付けを検証したうえで、`request_uri` を除いた pushed パラメータを返す。
消費が検証より先に来ていることには意味があり、期限切れでも client_id 不一致でも、提示された `request_uri` はその時点で消費済みになる（失敗した提示の再試行を許さない）。
展開後のパラメータから `request_uri` を落とすのは、残すと core の `rejectUnsupportedRequestParams` が `request_uri_not_supported` で拒否してしまうからである。

`assertPushedRequestUsed` は `require_pushed_authorization_requests`（§5）のガードで、PAR 必須設定のときに URN 形式の `request_uri` を伴わない認可リクエストを拒否する。

エラー型 `PushedRequestUriError` を core の `AuthorizationError` と別に新設しているのは、core の enum が `invalid_request_uri` を含まないためである。
このエラーは常に非リダイレクトである。
生成コードでは `features/par/steps/resolve-pushed-request.ts` がこれを `redirect_uri` を持たない core の `AuthorizationError` に写し、既存の非リダイレクトのエラーと同じ経路で OP 上に返す。

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
- クライアント認証の全経路（Basic とボディの `client_id` 併存、`client_secret_post`、public client、空文字列 `client_secret` の未提示扱い、非 Basic ヘッダ下でのボディ資格情報による認証、複数方式の拒否、client_id 不一致、誤ったシークレット、未知のクライアント）
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
生成コードは、全機能を有効にして動かしているアプリ [apps/hono](../../../apps/hono) の `src/oidc-provider/` から、CLI が抜き出したものである。
`maronn-oidc generate <framework> --enable par` を指定すると、生成コードに次の 3 つが入る。

- **`features/par/` ディレクトリ**：PAR が所有するファイルのすべて。`feature.ts` が `defineFeature()` で機能を宣言し、`routes` フックで `POST /par`（POST 以外は 405、CORS はトークンエンドポイントと同じ protected）を、`discovery` フックで `pushed_authorization_request_endpoint` を、`context` フックで `parStore` を base に差し込む
- **`features/enabled.ts` の 2 行**：`par` の import 行と、機能の一覧 `features` の 1 項目
- **`endpoints/authorize/pipeline.ts` の所有者付きブロック 1 つ**：`[resolve-pushed-request]` ブロックが、base の `[parse-request]` と `[resolve-client]` のあいだで、URN 形式の `request_uri` を pushed パラメータへ展開する。ブロックが呼ぶステップの import 行も、ファイル先頭に 1 行入る

フックが受け渡すのは、ルート、メタデータ、リクエストコンテキストの値のように、base が決まった場所で読む宣言的な値である。
base のパイプラインの途中で動く処理はフックにせず、そのパイプラインの中に、機能の名前を書いた目印のコメントで始まるブロックとして置く。
目印のコメントは `// [step-id] (feature: <feature-id>)` で始まり、次の目印の直前までがそのブロックになる。
このブロックを **所有者付きブロック** と呼ぶ。
`--enable par` を付けずに生成すると、CLI は PAR のブロックと、そのブロックだけが使っていた import 行を削除する。
PAR のブロックは base が宣言した `params` に展開の結果を代入し直すだけなので、削除してもパイプラインの残りはそのまま動く。

リクエストの経路をまとめると次のようになる。
`POST /par` は、`app.ts` が `routes` フックから受け取って `/par` にマウントした `parApp`（`features/par/endpoints/par/pipeline.ts`）に届き、「本文の解析 → クライアント認証 → 認可リクエストの検証 → 保存 → 201」の順に進む。
`GET /authorize` は、base の `endpoints/authorize/pipeline.ts` が「リクエストの解析 →（PAR のブロック）必須設定なら PAR 使用ガード、続いて URN の展開 → 従来の認可処理」の順に進める。
discovery では、base の `build-metadata` ステップが組み立てたメタデータに、`features/feature.ts` の `discoveryOf()` が PAR の `discovery` フックの値を加える。

この配置には 3 つの設計判断がある。

第一に、`request_uri` の展開を所有者付きブロックにしたのは、置く位置に意味があるからである。
クライアントの解決、Request Object の検証、`redirect_uri` の確定、パラメータの検証は、どれも展開後のパラメータを読まなければならない。
そのため展開は `[parse-request]` の直後、`[resolve-client]` より前に置く必要があり、フックのような宣言的な値ではこの位置を表せない。
ブロックとして置いたステップは `maronn-oidc graph` の図に箱として現れ、メタ情報が `removable: false` なので、`--flow` のフロー文書で PAR を残したままこのステップだけを外すことはできない。

第二に、`parStore` は base のストア（`store.ts` の `ProviderStores`）に加えず、機能のディレクトリに置いて `context` フックでリクエストコンテキストへ入れている。
PAR エンドポイントの `store-request` ステップと、認可エンドポイントの `resolve-pushed-request` ステップは、どちらも `c.get('parStore')` で同じストアを読む。
base はこの名前を知らないので、PAR を外して生成すればストアの型もインスタンスもディレクトリごと消え、base に使われない項目が残らない。
その代わり、`--db` で選んだデータベースにはこのストアが入らない。
既定の実装はプロセス内の Map なので、複数のインスタンスで動かす本番環境では `features/par/store.ts` を永続ストアの実装に差し替える。

第三に、設定は `features/par/config.ts` の `parConfig` にまとめ、モジュール読み込み時に `assertParExpiresInSeconds` で検証する。
`request_uri` の有効期間が §2.2 の推奨レンジ（5〜600 秒）を外れていれば、OP はリクエストを受ける前の読み込みの時点で失敗する。
`requirePushedAuthorizationRequests` の既定は `false` で、PAR を通らない認可リクエストも従来どおり受け付ける。
`true` にすると、`resolve-pushed-request` ステップが PAR 使用ガードを通し、discovery も `require_pushed_authorization_requests: true` を広告する。

サンプルでこの機能を有効にしているのは [samples/hono-cloudflare](../../../samples/hono-cloudflare) だけである。
他の機能と組み合わせた生成結果は、そのサンプルの `src/oidc-provider/` で確認できる。
サンプルの `src/app.ts` は PAR の設定に手を加えず、生成された既定値のまま動かしている。

### 生成コードに入るコードの全文（hono）

以下は、デフォルトの機能に `--enable par` を加えて hono 向けに生成した結果のうち、PAR が加えるもののすべてである。
`features/enabled.ts` と認可エンドポイントのパイプラインについては加わる行とブロックを、`features/par/` についてはファイルの全文を、生成されたファイルからそのまま写している。

#### `features/enabled.ts` に入る行

`features/enabled.ts` は、この OP が持つ機能の一覧である。
CLI は有効な機能ごとに import 行を 1 行と、配列 `features` の項目を 1 つ書く。
配列の順序はフックを適用する順序で、PAR は既定の機能（`pkce` から `request-object` まで）の後ろに並ぶ。

```typescript
import { par } from './par/feature.js';
```

```typescript
  par,
```

#### `endpoints/authorize/pipeline.ts` の `(feature: par)` ブロック

認可エンドポイントのパイプラインは、ファイル先頭で、ブロックが呼ぶ PAR のステップを import する。

```typescript
import { resolvePushedAuthorizationRequest } from '../../features/par/steps/resolve-pushed-request.js';
```

ブロックは `[parse-request]` ブロックの直後、`[resolve-client]` ブロックの直前で動く。
`parse-request` が作った `params` を `resolvePushedAuthorizationRequest()` に渡し、URN 形式の `request_uri` であれば pushed パラメータに置き換える。
URN でなければ `params` はそのまま返るので、PAR を使わない認可リクエストは従来どおり進む。

```typescript
    // [resolve-pushed-request] (feature: par) Expand the pushed request_uri — RFC 9126 §4 / §5
    params = await resolvePushedAuthorizationRequest(c, params);
```

#### `features/par/feature.ts`

PAR が base に差し込むものを宣言するファイルで、`features/enabled.ts` が import するのはこのファイルである。
`routes` は `/par` に `parApp` をマウントさせ、POST 以外のメソッドを 405 で拒否させ、トークンエンドポイントと同じ protected の CORS を適用させる。
`discovery` は RFC 9126 §5 のメタデータを返し、`require_pushed_authorization_requests` は PAR を強制しているときだけ広告する（省略時の既定値が `false` だから）。
`context` は `parStore` をリクエストコンテキストへ入れ、PAR エンドポイントと認可エンドポイントのステップが同じストアを読めるようにする。

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

PAR の設定で、`store-request` ステップ、`resolve-pushed-request` ステップ、`feature.ts` の `discovery` フックが読む。
`expiresInSeconds` は `request_uri` の有効期間で、末尾の `assertParExpiresInSeconds` が §2.2 の推奨レンジを外れた値をモジュール読み込み時に拒否する。
`requirePushedAuthorizationRequests` は §5 の強制スイッチで、既定は `false` である。
どちらも `createApp()` のオプションには含まれないので、変えるときはこのファイルの値を書き換える。

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

`request_uri` の保存先で、experimental の `PushedAuthorizationRequestStore` 契約を満たすメモリ上の実装と、そのインスタンス `parStore` を置く。
`consume` は読み出しと削除を一度に行い、期限切れかどうかに関わらず記録を消すので、同じ参照値を二度目に提示しても展開されない（§7.3 の単回使用）。
インスタンスを `globalThis` に置くのは、開発時のホットリロードなどでモジュールが二度読み込まれても、push を受けたステップと展開するステップが同じストアを見るためである。
記録はプロセスの外に残らないので、本番では `save` と `consume` の 2 メソッドを Redis、KV、データベースなどで実装し直す。
そのとき `consume` は取得と削除を atomic に行わなければならず、`requestUri` はクエリに埋め込まずパラメータとして束縛する。

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

`POST /par` のハンドラで、PAR エンドポイントのステップを仕様の順に呼ぶ。
各ブロックは `maronn-oidc graph --detail steps --endpoint par` の図の箱 1 つに対応し、どのステップが投げた失敗も `respondParError()` が OAuth のエラー応答にする。
ヘッダコメントにあるとおり、§2.3 の 413（リクエストが大きすぎる）と 429（レート制限）は実装せず、リバースプロキシやプラットフォームに任せている。
クライアント認証が済むまでは誰でも呼べるエンドポイントなので、本番ではレート制限を前に置く。

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

PAR エンドポイントのメタ情報で、`maronn-oidc graph` はこれを読んで図を描く。
`steps` がステップの順序、`errorStep` が失敗したときに行き着くステップ、`journeys` が `/par` から `/authorize` へ `request_uri` を運ぶ矢印を表す。
`rearrangeable: true` なので、`--flow` のフロー文書でステップを並べ替えられる。

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

PAR エンドポイントの応答の形 `ParEndpointResponse` と、決まった応答で失敗を返すための例外 `ParEndpointError` を定義する。
experimental の `ParError` が RFC 9126 の検証の失敗を表すのに対し、`ParEndpointError` は生成コードの側で決める失敗（Content-Type の誤りやパラメータの重複）を表す。

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

本文と `Authorization` ヘッダを読むステップである。
§2.1 は本文を `application/x-www-form-urlencoded` に限るので、それ以外の Content-Type は `invalid_request` で拒否する。
本文を `c.req.text()` で生のまま読むのは、`URLSearchParams` を走査して重複したパラメータを見つけるためである（RFC 6749 §3.1）。
フォームの解析結果だけを見ると同じ名前の最後の値しか残らず、重複を検出できない。
エラー文言に入れるパラメータ名は `sanitizeErrorDescription` を通す。

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

pushed request を送ってきたクライアントを、トークンエンドポイントと同じ方法で認証するステップである（public client は `client_id` だけを示す）。
認証の前に `rejectForbiddenParParams` で、pushed request に含めてはならない `request_uri`（§2.1）と、この生成 OP が対応しない `request`（PAR と JAR の併用、§3）を拒否する。
認証が済んだら `client_id` を認証済みの値で上書きし、以降の検証と保存をこのクライアントに結びつける。

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

§2.1 に従い、認可エンドポイントと同じ検証を push の時点で行うステップである。
未登録の `redirect_uri` や不正な `scope` は、ユーザーが画面を見る前にここで失敗する。
PKCE を省略してよいかは base の設定 `allowNonPkceAuthorizationCodeFlow` に従い、`pkce` 機能が有効な既定の生成では `false`（PKCE 必須）になる。

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

暗号論的に安全な乱数で参照値を作り、pushed パラメータをその下に保存するステップである（§2.2 と §7.1）。
記録の作成は experimental の `createPushedAuthorizationRecord` に任せ、認証済みの `client_id`、パラメータ、`parStore`、`parConfig.expiresInSeconds` を渡す。
クライアントの認証情報（`client_secret` など）は experimental の側で取り除かれるので、ストアには残らない。
応答は §2.2 の 201 で、本文は `request_uri` と `expires_in` だけである。
pushed パラメータは `login_hint` のような個人情報を含みうるので、ログには出さない。

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

成功も失敗も、最後はこの関数が HTTP の応答にする。
§2.2 に合わせてキャッシュされない JSON で返すため、`Cache-Control: no-cache, no-store` と `Pragma: no-cache` を付ける。
`WWW-Authenticate` のような追加のヘッダは、`ParEndpointResponse.headers` から写す。

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

どのステップが投げた失敗も、トークンエンドポイントと同じ形の JSON エラーにするステップである（§2.3）。
このエンドポイントはリダイレクトしない。
`ParEndpointError` は決めてあった応答をそのまま返し、experimental の `ParError` はステータスコード、エラーコード、`WWW-Authenticate` を写し、それ以外の例外は `server_error`（500）にする。

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

認可エンドポイントの所有者付きブロックが呼ぶステップで、PAR のコードのうち base のパイプラインの中で動くのはこのファイルだけである。
`meta` の `endpoint: 'authorize'` と `feature: 'par'` が、どのエンドポイントのどの機能のステップかを示す。
必須設定のときは先に `assertPushedRequestUsed` を通し、続いて `resolvePushedRequestUri` で URN 形式の `request_uri` を展開する。
URN でなければ `null` が返り、受け取った `params` をそのまま返す（URL 形式の `request_uri` は後続の検証が `request_uri_not_supported` で拒否する）。
展開に失敗したときの `PushedRequestUriError` は、`redirect_uri` を持たない core の `AuthorizationError` に写す。
検証済みの `redirect_uri` がない失敗なので、`authorizationErrorOutcome()` はこのエラーをリダイレクトせず、OP 上のエラーとして返す。
失敗の種類（不存在、使用済み、期限切れ、client_id の不一致）によらずコードと文言が同じなので、応答から参照値が存在したかどうかを判定できない。

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

### 他フレームワークの生成コード

express と fastify の生成コードは、hono と同じファイルからなる。
CLI は、エンドポイントが import する `hono` のルーターを Fetch API の小さなルーター `web-router.ts`（`WebRouter` と `WebContext`）に置き換え、フレームワーク向けの `apply.ts`、`web-router.ts`、`node-adapter.ts` を加える。
加えるファイルの元は [apps/hono/src/web/](../../../apps/hono/src/web) にあり、どのファイルをどこに置くかは [packages/cli/extract.json](../../../packages/cli/extract.json) が定める。
画面は hono/jsx のままなので、これらの生成物も JSX ランタイムとして `hono` を必要とする。
`features/par/` で変わるのは `features/par/endpoints/par/pipeline.ts` の `Hono` が `WebRouter` になる点だけで、ほかのファイルは hono と同じ内容である。

Next.js の生成コードは、Next.js App Router のアプリ [apps/nextjs](../../../apps/nextjs) から抜き出す。
PAR のルートファイルはルートグループ `app/(par)/` に、それ以外のコードは `app/_oidc-provider/features/par/` に置かれる。
どちらもこの解説には載せず、ディレクトリへのリンクで示す。

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
