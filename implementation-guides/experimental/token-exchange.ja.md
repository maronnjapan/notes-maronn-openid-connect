# Token Exchange 実装解説

この文書は、`packages/experimental` に実装した **OAuth 2.0 Token Exchange**（RFC 8693）について、何を実装したのか、どう実装したのかを、関連するコードの全文とともに説明する。

この文書が全文を載せるのは次のコードである。

- `packages/experimental/src/token-exchange/` の実装 2 ファイルとテスト 1 ファイルのすべて
- CLI の `--enable token-exchange` が生成コードへ注入するコードの全文（hono。ファイルごとに TypeScript として示す）
- Token Exchange の E2E テストスペックの全文

core 本体、E2E 共有ハーネス、他フレームワークの生成差分は全機能で共有される基盤なので、リンクで参照する。

## 機能の概要

Token Exchange は、手持ちのトークンをトークンエンドポイントへ提示して、別のトークンへ交換するための grant である。
交換元のトークンを **subject_token** と呼び、`grant_type=urn:ietf:params:oauth:grant-type:token-exchange` のリクエストで提示する。
OP は subject_token を検証し、要求された scope や対象（audience / resource）を審査したうえで、新しいアクセストークンを発行する。

なぜトークンを交換したくなるのか。
典型的なのはマイクロサービス構成で、ユーザーからリクエストを受けたゲートウェイが、後段のサービスを呼ぶ場面である。
受け取ったアクセストークンをそのまま横流しすると、後段には過剰に広い権限（ゲートウェイ向けの全 scope と audience）が渡ってしまう。
Token Exchange を使うと、ゲートウェイは「ユーザー本人として振る舞うが、権限は後段サービスに必要な分だけに狭めたトークン」を OP から調達できる。

RFC 8693 §1.1 は交換を 2 つの型に分けており、本実装はその両方に対応する。
**impersonation**（`actor_token` なし）は、単純に subject として振る舞うトークンを発行する型である。交換後トークンの `sub` は subject_token の `sub` のままで、交換を行った当事者は `client_id` 以外に現れない。
**delegation**（`actor_token` あり）でも `sub` は変わらないが、「誰が subject の代理として振る舞っているか」を **act claim**（§4.1）に記録する。トークンが「これはサービス X がユーザー Y の代理で使うものだ」と自ら語る形になり、交換を連鎖させると `act` のネストとして委譲の履歴が残る。

```text
クライアント（例: ゲートウェイ）                 OP
    │  POST /token（クライアント認証つき）        │
    │  grant_type=…:token-exchange               │
    │  subject_token=<手持ちのアクセストークン>    │
    │  actor_token=<呼び出し側自身のトークン>      │ （任意: delegation）
    │  scope=read  audience=https://backend.example │
    │ ─────────────────────────────────────────> │ subject_token（と actor_token）
    │                                            │ を検証し、scope の縮小と
    │  200 { access_token, issued_token_type,    │ 対象の許可を審査
    │        token_type, expires_in, scope }     │
    │ <───────────────────────────────────────── │
```

### ユースケース

- マイクロサービス間で権限を狭めたトークンを取り回す構成（いわゆる token downscoping）の検証
- ゲートウェイやバックエンドが、ユーザーの subject を保ったまま特定リソースサーバー向けのトークンを調達するフローの検証
- 「どのサービスがユーザーの代理として動いたか」をトークン自身に記録する delegation 設計（`act` claim とその連鎖）の検証
- `allowedTargets` の許可リスト運用（どの audience / resource への発行を認めるか）の設計検証

### 実装スコープと非目標

実装したのは次の範囲である。

- `urn:ietf:params:oauth:grant-type:token-exchange` grant の検証一式（RFC 8693 §2.1）
- subject_token と actor_token の解決と有効性検証（本 OP が発行したアクセストークンのみ）
- delegation の `act` claim の組み立て（§4.1）。委譲済みトークンを再交換したときのチェーンのネストを含む
- scope の縮小検証、audience / resource の許可リスト検証、寿命の cap
- §2.2.1 の応答ボディの組み立て

非目標は次のとおりで、いずれも意図的に外している。

- **アクセストークン以外の token type**。`subject_token_type` も `actor_token_type` も `requested_token_type` も `urn:ietf:params:oauth:token-type:access_token` のみ受け付ける（理由は次項）
- **audience / resource の複数指定**。生成 OP のトークンエンドポイントが RFC 6749 §3.2 に基づき重複パラメータを拒否するため、各 1 つまでとなる

#### アクセストークンに限定する理由と、ID トークン交換の置き場所

RFC 8693 は、どの token type を受け付けて何を発行するかを認可サーバーの裁量に委ねている。
`requested_token_type` は OPTIONAL で、認可サーバーは §3 の識別子のうち任意の部分集合だけ対応してよい。
本実装はアクセストークンだけを受け付けて発行し、それ以外の `requested_token_type` は黙って無視するのではなく `invalid_request` で明示的に拒否する。
無視するほうが穏当に見えるかもしれないが、ID トークンを要求したクライアントにアクセストークンが返り、`issued_token_type` を見るまで齟齬に気付けない、という結果になる。
明示的なエラーなら、齟齬はリクエストの時点で表面化する。
なお `requested_token_type` を省略した要求は常に成立し、アクセストークンが発行される。

アクセストークン以外の token type を本当に必要とする交換パターンは、この grant の拡張としてではなく、独立した機能として実装する予定である。
筆頭は Cross App Access（Identity Assertion Authorization Grant のパターン）で、トークンエンドポイントが subject として ID トークンを受け取り、別の認可サーバー宛の JWT アサーションを発行する。
このフローは検証する対象（ストア上のアクセストークンではなく ID トークンの署名）も発行する対象（本 OP のアクセストークンではなく他 AS 宛のアサーション）も異なるため、この実装に継ぎ足すとパイプラインのほぼ全段が分岐する。
その機能を実装するときは専用の検証を持たせることになり、この grant の限定はそのまま残る。

## 実装の設計方針

ファイルは実装とテストで 1 つずつ、それに公開 API の `index.ts` が付く。

| ファイル | 役割 |
|---|---|
| `token-exchange-request.ts` | grant の検証一式（ステップ関数と合成関数） |
| `index.ts` | 公開 API の再エクスポート |

設計の中核は、**交換で権限が単調に狭まる**ことの保証である。
具体的には次の 4 点が対応する。

- scope は subject_token の scope の部分集合しか要求できない（`validateExchangeScope`）
- audience / resource は許可リスト（`allowedTargets`）内しか要求できず、省略時は subject の audience を継承する（`resolveExchangeTarget`）
- 寿命は `min(設定値, subject_token の残存秒数)` で cap され、交換を連鎖しても単調減少する（`computeExchangedTokenLifetime`）
- `sub` は subject_token の値を継承し、変更できない。delegation でも actor は `act` にのみ現れる

この一覧に出てくる識別子のうち 2 つは、仕様の本文ではなく設定や取り決めに由来するので、ここで定義しておく。

`configuredExpiresIn` は、OP に設定されたアクセストークンの有効期間である。
通常の発行が受ける上限と同じ値で、生成コードは `config.accessTokenExpiresIn` をここへ渡す。
交換はこの上限を超えて発行することはなく、subject_token の残存秒数がさらにそれを cap する。

`audience` と `resource` は、どちらも「新しいトークンを誰に向けて発行してほしいか」を指定するパラメータで、RFC 8693 §2.1 は意図的に 2 つを併置している。
`resource` は対象の**所在**を URI で指定する（出自は RFC 8707 Resource Indicators で、絶対 URI かつ fragment なしという構文規則もそこから来ている）。
`audience` は対象の**論理名**を指定する（認可サーバーと配下のサービスが合意した識別子であれば何でもよく、構文の制約はない）。
サービスを URL で呼ぶ運用なら `resource`、論理名で呼ぶ運用なら `audience` を使い、1 つのリクエストに両方あってもよい。
本実装は 2 つを 1 つのポリシーに畳み込む。どちらの名前でも `allowedTargets` に載っていることを要求し、審査済みの値を要求 audience として合流させる。`resolveExchangeTarget` という 1 つのステップ関数に両方が集まるのはこのためである。

delegation も同じ骨格の上に載る。
actor_token は subject_token と同一の検証（`resolveActorToken`）を通り、発行されるトークンへの寄与は `composeActClaim` が組み立てる `act` claim の値だけである。
最外に今回の actor の `sub` を置き、subject_token 自身が `act` を持っていた（＝それ自体が過去の委譲で発行された）場合はそのチェーンを 1 段下へネストする。これが §4.1 の並び順の規則である。
actor_token は発行トークンの寿命を cap しない。これは意図した設計判断で、狭める対象の権限は subject_token に由来し、actor_token は「交換の時点で actor が本 OP の有効なトークンを保持している」ことの確認に使うからである。
チェーンを後続の交換に引き継ぐため、生成コードは `act` を JWT だけでなくストアの metadata にも保存する。core を変更せずにこれを表現するのが構造的拡張型 `ExchangedAccessTokenInfo` である。

もう 1 つの軸はオラクルの排除である。
subject_token の解決失敗（不存在、期限切れ、nbf 未来、失効済み）は、どれも同じ固定文言の `invalid_request` になり、actor_token の失敗にも専用の固定文言が 1 つだけある。
応答からトークンの存在や失効状況を推測させないための、PAR の `request_uri` と同じ方針である。
クライアント認可（`authorizeTokenExchangeClient`）を最初に置いているのも同じ理由で、許可されていないクライアントにはどのトークンの有効性判定もさせない。

このモジュールはトークンの発行と保存を行わない。
返すのは発行素材（`TokenExchangeGrant`）までで、生成コードがそれを core の発行パイプライン（`buildAccessTokenAudience` / `buildAccessTokenPayload` / `AccessTokenIssuer` / `accessTokenStore`）へ流す。
発行の一貫性（UserInfo エンドポイントの audience への恒久追加、重複除去、非空フォールバック）を既存トークンルートと共有するための分担である。

エラー型 `TokenExchangeError` を新設しているのは、RFC 8693 §2.2.2 が追加する `invalid_target` を core の閉じた `TokenErrorCode` が含まないためである。
このエラーは常に 400 で、401 になるのはクライアント認証失敗だけだが、それは grant 分岐より前の共有認証パイプライン（core の `TokenError`）が担当する。

## 実装コードの全文と解説

### token-exchange-request.ts（grant の検証一式）

ステップ関数は仕様の処理順に並ぶ（番号はコード内のコメントと対応する）。

1. `authorizeTokenExchangeClient`：クライアントが交換を要求してよいかを検証する。登録済み `grantTypes` に交換の URN が無ければ `unauthorized_client`。加えて public client（`tokenEndpointAuthMethod: 'none'`）を拒否する。RFC 8693 §2.1 の「クライアント認証を省くと、窃取されたトークンを STS 経由で別のトークンへ増幅できる」という注記を、public client の拒否まで強めた設計判断である
2. `parseTokenExchangeParams`：必須パラメータと非対応パラメータを検証して型付けする。`subject_token` / `subject_token_type` の必須、token type の限定、`resource` の構文検証（絶対 URI かつ fragment なし）に加えて、delegation の組み合わせ規則（§2.1: `actor_token_type` は `actor_token` があるとき必須、無いとき禁止）を検証する。空文字や空白のみの任意パラメータは「送られなかった」と同じに扱い、フォームの空フィールドを黙って対象指定や委譲要求へ昇格させない
3. `resolveSubjectToken`：subject_token を `AccessTokenResolver` で解決し、存在、期限、`nbf` を検証する。失敗理由は応答から区別できない
4. `resolveActorToken`（コード上はステップ 3'。delegation のみ）：actor_token に対して subject_token と同一の検証を行う。失敗文言は actor_token 専用の固定文言になる
5. `composeActClaim`（ステップ 3''。delegation のみ）：`act` の値を組み立てる。最外が今回の actor、subject_token が持っていたチェーンはその下へネストする
6. `validateExchangeScope`：要求 scope が subject の scope の部分集合であることを検証し、実効 scope を返す。省略時は subject の scope をそのまま継承する
7. `resolveExchangeTarget`：audience / resource を許可リストで検証する。戻り値は最終的な `aud` ではなく、core の `buildAccessTokenAudience` へ渡す審査済みの「要求」である。両方省略時は subject の audience を継承する（そのときの交換は scope 縮小と期限短縮だけを行うもので、無制限のトークンになるわけではない）
8. `computeExchangedTokenLifetime`：`min(設定値, 残存秒数)` を計算する。`resolveSubjectToken` を通過していれば残存は必ず 1 秒以上なので、`expires_in: 0` のトークンは発行されない
9. `buildTokenExchangeResponse`：§2.2.1 の応答ボディを組み立てる。発行するのはアクセストークンだけなので `token_type` は `Bearer` に固定し、`scope` は分岐を避けて常に含める

合成関数 `processTokenExchangeRequest` はこれらを順に呼び、発行素材（`TokenExchangeGrant`）を返す。
`grantId` の継承に注目してほしい。交換後トークンは元の認可 grant の失効に連動し、元 grant を失効させると交換で作られたトークンも一緒に死ぬ。delegation で継承されるのは subject 側の grant であり、actor の grant には連ならない。

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

### index.ts（公開 API）

subpath export `@maronn-openid-connect/experimental/token-exchange` の実体である。

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

## 単体テストの全文と解説

テストは 1 ファイルで、行数の大半はステップ関数ごとの境界値の検証である。
何を固定しているかを要約する。

- 定数（grant type と token type の URN、subject / actor それぞれの固定失敗文言）と `TokenExchangeError` の性質（常に 400、サニタイズ、エラー名）
- パラメータ解析の全経路（正常系、空文字の任意パラメータの無視、必須欠落、非対応 token type、actor_token / actor_token_type の組み合わせ規則、`resource` の構文違反）
- クライアント認可（URN 未登録、`grantTypes` 未指定時の既定、public client の拒否）
- subject_token の全失敗種別が 1 つの文言に収束すること、期限と `nbf` の境界。actor_token についても専用文言で同様
- `composeActClaim` が単段の act を作り、ネスト済みチェーンを保持すること
- scope 縮小（部分集合の許可、超過の拒否、省略時の継承、重複の除去）
- 対象検証（許可リスト内の受理、リスト外の拒否、省略時の subject audience 継承、audience と resource の併用）
- 寿命の cap（設定値と残存の min、境界値、設定ミス時の `RangeError`）
- 応答ボディの形
- 合成関数の端から端まで（impersonation と delegation の発行素材、act の連鎖、actor が寿命を cap しないこと、各段の失敗が正しいエラーで伝播すること）

### テストが全部通ると何が保証されるのか

各テストは 1 つのステップ関数だけを対象にしているから、「全部通ったら結局何が言えるのか」を書いておく。
ステップを出荷順（クライアント認可 → 解析 → subject 解決 → actor 解決 → act 組み立て → scope → 対象 → 寿命 → 応答）で合成したとき（`processTokenExchangeRequest` と生成コードはまさにこの順で呼ぶ）、緑のテストスイートは OP が応答するすべてのリクエストについて次を保証する。

- 登録済みの confidential client 以外は、どのトークンについても有効性の判定結果を得られない（認可が解決より先に走るため）
- 形式不正や非対応のパラメータ組み合わせは、トークン解決まで到達しない（解析が 2 番目に走るため）
- 発行されるトークンの scope は subject の部分集合、対象は許可リスト内か継承、寿命は subject の残存以下になる（各ステップがそれ以外を拒否するため）
- 発行されるトークンは subject として振る舞い（`sub` 不変）、delegation では actor が `act` に記録され、過去のチェーンも保持される
- 使えない subject_token / actor_token への応答はパラメータごとに 1 つの固定文言で、エンドポイントを存在オラクルとして使えない

このスイートが保証できないのは、カスタマイズされたコードにおける合成順そのものである。
生成 OP の所有者がステップを並べ替えても（たとえばクライアント認可より先にトークンを解決しても）、単体テストは通ってしまう。
合成順は 1 つ上の層、つまり生成される conformance テストと後述の E2E スペックが固定している。

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

## CLI 統合と生成コードへの寄与

`maronn-oidc generate <framework> --enable token-exchange` を実行すると、生成コードに次が加わる。

- **routes/token.ts（変更）**：トークンエンドポイントの共有クライアント認証の直後、core の `validateGrantTypeSupported` が URN を拒否するより前に、`grant_type === TOKEN_EXCHANGE_GRANT_TYPE` の分岐が入る。分岐は `processTokenExchangeRequest` を呼び、返った素材を core の発行パイプラインへ流し、分岐の中で応答まで済ませる。`tokenExchangeConfig`（既定 `allowedTargets: []` の安全側デフォルト）もこのファイルに入る
- **routes/discovery.ts（変更）**：`grant_types_supported` に交換の URN が加わる
- **config.ts（変更）**：サンプルの confidential client の `grantTypes` に交換の URN が加わる
- **conformance.test.ts（変更）**：交換の成功・失敗の挙動が、delegation と act claim を含めて契約テストとして固定される

新しいルートは増えない。
統合は、既存の `POST /token` の中に grant 分岐が 1 つ増える、という形を取る。

以前の版は、この寄与を 1 本の長大な unified diff として掲載していた。
シンタックスハイライトが効かず読みにくかったため、現在はファイルごとに分け、`--enable token-exchange` が追加・変更するコードそのものを TypeScript ブロックで示し、どこに入るかは前後の文で述べる形にしている。
機械照合可能な diff 形式は、末尾の「関連資料」から辿れる昇格レビューパケットに残っている。

### config.ts に入るもの

サンプルの confidential client（`defaultRegisteredClients` 内）の `grantTypes` に交換の URN が加わる。
クライアントからこの URN を外すことが、そのクライアントに交換を禁止する操作になる。

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

### routes/discovery.ts に入るもの

変更は 1 行で、`grantTypesSupported` が交換の URN を広告するようになる。

```typescript
    grantTypesSupported: ['authorization_code', 'refresh_token', 'urn:ietf:params:oauth:grant-type:token-exchange'],
```

### routes/token.ts に入るもの

ファイル先頭に import が加わる。subject と actor の検証に使うアクセストークン resolver が resolver 群の import に 1 行加わり、交換の関数群が experimental の subpath から入る。

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

import の隣に、モジュールレベルのポリシーオブジェクトが export される。
既定が空リストなので、運用者が後段サービスをここへ列挙するまで、対象を名指しする交換はすべて `invalid_target` で拒否される。

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

grant の分岐本体は、クライアント認証の直後、標準のトークンパイプラインより前に入る。
検証は `processTokenExchangeRequest`、発行は core の通常パイプライン（audience 合成、payload、署名、ストア保存）で行い、分岐の中で応答する。
2 箇所の `grant.actor` のスプレッドが delegation の追加分で、act claim を JWT payload とストア metadata の両方に載せる。後者は、このトークンを後日 subject_token として再交換したときにチェーンを繋げるためである。

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

最後に、トークンルートの catch ブロックが `TokenExchangeError` の変換を覚える（常に 400 で、RFC 6749 §5.2 の形に `invalid_target` が加わる）。

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

### conformance.test.ts に入るもの

import が 1 行、テスト用クライアントが 2 つ、そして契約テストのブロックが加わる。
クライアントは、交換 grant を登録した confidential client と、同じく登録した public client の 2 つで、後者は「URN を登録していても public client は拒否される」ことを固定するためにいる。

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

契約テストは、認可コードフローを HTTP で最後まで駆動して生きた subject / actor トークンを取得し（2 人目のシードユーザー `otheruser` が、subject と `sub` の異なる actor を提供する）、成功と失敗の全挙動を固定する。発行された JWT をデコードして `act` claim を検証するテストもここに含まれる。

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

### 他フレームワークの差分

express と fastify の差分は同一のため 1 ファイルに集約し、nextjs も同等の内容である。

- [express-fastify](../../../tasks/experimental/done/token-exchange/promotion-review/generated-code/express-fastify.md)
- [nextjs](../../../tasks/experimental/done/token-exchange/promotion-review/generated-code/nextjs.md)

サンプルの中でこの機能を有効化しているのは [samples/hono-cloudflare](../../../samples/hono-cloudflare) だけである。

## E2E テストの全文と解説

このスペックには 2 種類の交換が登場し、実行される場所が異なる。
どのコードが実際の交換を行っているかを押さえておくと、テストがずっと読みやすくなる。

impersonation のテスト（"should exchange a browser-obtained access token for a narrowed one"）は、実ブラウザで E2E クライアントアプリの `/start-exchange` ページを駆動する。
このテストの中でスペック自身がトークンエンドポイントへ POST することはない。
OP からのリダイレクトを受けたクライアントアプリが、サーバー側でコードフローを完了させ、その場で交換まで行い（`tests/e2e/apps/client.mjs` の `completeTokenExchange`）、結果をページに描画する。アサーションはそのページを読む。
交換を行っている箇所は次のとおりである（クライアントアプリは E2E の共有基盤なので、この関数だけを抜粋する）。

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

delegation のテストは、スペック自身が交換を行う。
2 回のブラウザログイン（testuser と、隔離したブラウザコンテキストでの otheruser）で subject トークンと actor トークンを取得し、スペックがバックチャネルで delegation リクエストを POST して、発行された JWT をデコードし、`act` claim を固定する。

スペックが固定するのは次の挙動である。

- impersonation 交換の成功（scope を狭めたトークンが返り、リソースサーバーにもそのまま通る）
- discovery が交換の URN を広告すること
- 未認証の交換の拒否
- 未知の subject_token が `invalid_request` になること
- delegation 交換が発行 JWT の `act` claim に actor を記録すること
- §2.1 の組み合わせ規則（`actor_token_type` を欠く `actor_token` の拒否）

すべてのテストは、discovery が交換の URN を広告しない OP ではスキップされる。

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

## 関連資料

- 利用者向けドキュメント: [docs/library-document experimental/token-exchange.md](../../library-document/src/content/docs/experimental/token-exchange.md)
- 仕様の学習ドキュメント: [tasks/experimental/done/token-exchange/](../../../tasks/experimental/done/token-exchange/)
- 昇格レビューパケット: [tasks/experimental/done/token-exchange/promotion-review/](../../../tasks/experimental/done/token-exchange/promotion-review/README.md)
- パッケージ全体の規約: [package-overview.ja.md](./package-overview.ja.md)
- English version: [token-exchange.en.md](./token-exchange.en.md)
