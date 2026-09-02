# CIBA (Client-Initiated Backchannel Authentication) 実装解説

- **feature-id**: `ciba`
- **準拠仕様**: OpenID Connect Client-Initiated Backchannel Authentication Flow - Core 1.0（Final, 2021-09-01）、RFC 6749
- **実装場所**: `packages/experimental/src/ciba/`
- **有効化**: `maronn-oidc generate <framework> --enable ciba`
- **要件文書**: `tasks/experimental/done/ciba/`（specification.md / understanding-guide.md / sources.md）

## 機能の概要

**CIBA（Client-Initiated Backchannel Authentication）** は、ユーザーが操作していないデバイスからログインを始めるための OpenID Connect 拡張である。
コールセンターのオペレーター画面・店頭端末・スマートスピーカーのようなデバイス（仕様の用語で consumption device）が、ユーザーの識別子（`login_hint`）だけを添えて OP にバックチャネルで認証を依頼する。
実際の認証と承認はユーザーが自分の手元のデバイス（authentication device）で行い、依頼したデバイスはトークンエンドポイントをポーリングしてトークンを受け取る。

本機能が生成 OP に追加するのは次の 3 面である。

- **バックチャネル認証エンドポイント**（`POST /backchannel_authentication`）: クライアントが `login_hint` を提示して `auth_req_id` / `expires_in` / `interval` を受け取る（CIBA §7）
- **認証デバイス UI**（`GET /ciba` / `POST /ciba/login` / `POST /ciba/approve`）: ユーザーが自分のブラウザで OP にログインし、自分宛の保留中リクエスト（クライアント名・scope・`binding_message`）を確認して承認または拒否する
- **トークンエンドポイントの grant 分岐**: `grant_type=urn:openid:params:grant-type:ciba` を受け、レコードの状態に応じて `authorization_pending` / `slow_down` / `access_denied` / `expired_token` またはトークン発行を返す（CIBA §10.1 / §11）

実装済みの Device Authorization Grant と部品はよく似ているが、起点が逆である。
Device Flow は「ユーザーが `user_code` を書き写して自ら OP に来る」のに対し、CIBA は「クライアントがユーザーを名指しし、OP がユーザー側の承認を待つ」。
ポーリング型のトークン取得・承認 UI・grant ディスパッチという 3 部品は同型で、識別手段（`user_code` か `login_hint` か）とフローの向きが異なる。

### ユースケース

- コールセンターで「オペレーターがユーザーの識別子を入力し、ユーザーのスマホで承認」という UX が自分の要件で成立するかを検証する
- 店頭端末・音声デバイスなど、ユーザー入力が制約されるデバイスからの認可を PoC する
- FAPI-CIBA の導入を見据えて、まず素の CIBA Core 1.0 のフローを手元で理解する

### 実装スコープと非目標

CIBA Core 1.0 の 3 つの token delivery モードのうち **Poll モードのみ**を実装する。
Ping / Push モードはクライアント通知エンドポイントへの callback 送信（SSRF 面の管理と `client_notification_token` の検証）が必要になり、experimental の隔離規模を超えるため対象外とした。
discovery は `backchannel_token_delivery_modes_supported: ["poll"]` のみを広告し、`poll` 以外を登録したクライアントの依頼は `unauthorized_client` で拒否する。

ヒントは `login_hint` のみに対応する。
`id_token_hint` は core の検証関数が期限切れを拒否する設計で、CIBA の再認証ユースケース（期限切れ ID トークンをヒントに使う）には検証を緩和した別バリアントが要るため、将来拡張として要件文書に記録した。
`login_hint_token` は CIBA Core がフォーマットを標準化していない。
このほか、署名付き認証リクエスト（§7.1.1）、`user_code` パラメータ（§7.1.2）、FAPI-CIBA プロファイルも対象外である。

認証デバイスへの到達手段とユーザー認証方法は、CIBA Core 自身が仕様の対象外と明言している（§7.1）。
本機能はこれを「OP がホストするブラウザ UI」として実装した。
実運用の CIBA で典型的なスマホへのプッシュ通知は通知基盤ごと利用者の責務とし、承認・拒否のロジックを公開 API として提供することで UI を差し替えられる構造にしてある。

## 実装の設計方針

**Device Authorization Grant の先例に載せる。**
ポーリング状態機械（`slow_down` の +5 秒・期限切れ優先・atomic な consume）、バックチャネルエンドポイントのクライアント認証パイプライン、承認 UI のセッション・CSRF 設計は、実装済みの device-authorization-grant と同じ構造にした。
コードは共有しない（experimental の運用方針どおり機能内に複製する）が、レビュー済みの設計をそのまま使うことで、新規に検討した面をこの機能固有の部分に絞っている。

**承認操作はセッションの subject 一致で束縛する。**
Device Flow の承認は binding Cookie で守ったが、CIBA では相当する仕組みを設けていない。
Device Flow では `user_code` しかレコードへのリンクが無く、しかもその値はフロー開始者（攻撃者になり得る）に既知であるため、ブラウザ束縛が必要だった。
CIBA の承認は「認証済み OP セッションの subject とレコードの subject の一致」で束縛されており、レコード単位の CSRF トークンもセッション必須の一覧表示でしか得られない。
`auth_req_id` を知っていても、セッションが無ければ承認操作は一切できない。

**ログインフォームには常時ブラウザ束縛を設ける。**
ログイン成功は OP セッションという CIBA 外にも及ぶ状態（SSO / `prompt=none`）を作る。
フォーム埋め込みの CSRF トークンだけでは足りない。攻撃者が自分で `GET /ciba` を開けば、有効な `login_transaction_id` と CSRF トークンの対を入手して偽造フォームへ埋め込めるからである。
そこでフォーム表示時に**ログイントランザクション**を発行し、bindingSecret の生値をブラウザだけが持つ HttpOnly Cookie で配り、レコードには SHA-256 ハッシュのみを保存する。
偽造されたクロスサイト POST は被害者ブラウザに binding Cookie が無いため、トークンの秘匿に依存せず遮断できる。
これは既存生成コードの「OP セッションを確立するステップは binding で守る」原則（`/device/login` と同じ）の適用である。
ログイントランザクションは資格情報試行の計数の錨も兼ね、上限超過でトランザクションごと破棄される。

**エラーはオラクルにしない。**
`auth_req_id` の不存在と別クライアント宛ては同じ文言の `invalid_grant` にし（§11 の "invalid or was issued to another Client"）、`login_hint` の不存在と resolver の例外は同じ文言の `unknown_user_id` にし、UI の検証失敗（不存在・期限切れ・binding 不一致・CSRF 不一致・subject 不一致）は同一文言の 403 にする。
応答から内部状態を区別できる面を残さない。

**未承諾リクエストの flood は保留数の上限で抑える。**
§7.1.2 の `user_code`（ユーザーごとの秘密で未承諾依頼を抑止する仕組み）は実装しないため、その代替として (1) クライアント認証必須、(2) subject あたりの保留数上限（`maxPendingPerSubject`）、(3) プッシュ通知のない pull 型 UI、(4) 承認画面でのクライアント名・scope・`binding_message` の表示と同等の視認性の拒否ボタン、の 4 点で構成した。
上限超過のエラーコードは `invalid_request` の固定文言とした。§13 の `access_denied` はクライアント実装が「ユーザー拒否によるフロー終端」と解釈する恐れがあり、保留の解消で直る一時的状態には合わないためである。

**core は変更しない。**
トークン発行は生成コードが core の既存関数（`buildAccessTokenPayload` / `buildIdTokenPayload` / `generateIdToken`）で行い、experimental 側は「レコードの管理と状態機械」だけを持つ。
クライアント登録の CIBA 拡張（`backchannelTokenDeliveryMode`）は core の `TokenClientInfo` への交差型 `CibaClientInfo` として experimental 側に定義し、core の型は変えていない。

## 実装コードの全文と解説

モジュールは 6 ファイルで、依存の向きは store / errors を底に、その上へエンドポイント処理（backchannel-authentication-request）、UI ステップ関数（verification）、トークン分岐（ciba-grant)、公開 API（index）が載る。

### store.ts（ストア契約とインメモリ実装）

レコードは 2 種類ある。
**認証リクエストレコード**（`CibaAuthenticationRequestRecord`）はバックチャネル依頼 1 件の状態機械そのもので、`pending → approved / denied` の一方向に遷移し、トークン発行時に consume される。
**ログイントランザクション**（`CibaLoginTransactionRecord`）は認証デバイス UI のログインフォーム 1 枚の寿命を管理し、ログイン CSRF 防御（bindingHash）と失敗計数（loginAttempts）の錨になる。

`consume` の atomic 要件と、期限切れレコードの掃除をストア実装の裁量に委ねる注記は、PAR / Device のストア契約と同じ扱いである。
Device と違い、インメモリ実装をクラスではなくファクトリ関数（`createInMemoryCibaAuthenticationRequestStore`）としてパッケージ側で公開した。
生成コードの `store.ts` はこのファクトリを呼ぶ 1 行になり、生成コードへ複製されるストア実装が減る。

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

### errors.ts（エラー型）

エラー型は応答面ごとに 3 つに分ける。
`BackchannelAuthenticationError` はバックチャネル認証エンドポイントの §13 語彙、`CibaGrantError` はトークンエンドポイントの §11 語彙で、どちらも RFC 6749 §5.2 の JSON 形・常に 400 で返る（401 はクライアント認証を担う core の `TokenError` だけが返す）。
`CibaVerificationError` は HTML ページで応答する UI 層専用の型である。

`BackchannelAuthenticationError` の語彙に `access_denied` を含めていないのは意図的である。
§13 は認証エンドポイントでの即時拒否用にこれを定義するが、Poll モードの本実装は依頼を受理してからユーザーの判断を待つため、拒否は常にトークンエンドポイント側の `access_denied` で配信される。

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
 * - `invalid_grant` / `invalid_request`: RFC 6749 §5.2 の既存値。
 */
export type CibaGrantErrorCode =
  | 'authorization_pending'
  | 'slow_down'
  | 'expired_token'
  | 'access_denied'
  | 'invalid_grant'
  | 'invalid_request';

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

### backchannel-authentication-request.ts（バックチャネル認証エンドポイント）

`processBackchannelAuthenticationRequest` が §7.1 / §7.2 / §7.3 の全処理を担う。
Content-Type と重複パラメータの検証、クライアント認証は生成コード側の共有パイプラインが先に済ませ、この関数は認証済みクライアントを受け取る。

検証順序は要件文書の定義どおりで、クライアント側の検証（public client 拒否 → CIBA grant 登録 → delivery mode）→ `request` パラメータ拒否 → ヒント規則 → scope → `binding_message` → `requested_expiry` → `login_hint` 解決 → 保留数制限、と進む。
ヒント規則（§7.1 の "one (and only one) of the hints"）は、0 個・2 個以上を `invalid_request` にしたうえで、`login_hint` 以外の単独提示を種別の非対応として別の固定文言の `invalid_request` で拒否する。
§13 の `unknown_user_id` は「ヒントからユーザーを特定できない」場合の語彙であり、ヒント種別自体の非対応は malformed 系として扱うという要件文書の区別に従った。

`requested_expiry` は §7.1 が "The server MAY use this value" とするため、`[30, authReqIdExpiresIn]` へのクランプで採用する。
`login_hint` の解決は `CibaUserResolver` 契約（利用者の swap point）へ委譲し、resolver の例外は不存在と同じ固定文言に落とす。

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

### verification.ts（認証デバイス UI のステップ関数）

認証デバイス UI の 3 ルートが呼ぶステップ関数群である。
ログイントランザクションの発行と検証（`createCibaLoginTransaction` / `validateCibaLoginSubmission` / `recordCibaLoginFailure`）、保留一覧の CSRF 発行（`listPendingCibaRequests`）、承認・拒否（`approveCibaRequest` / `denyCibaRequest`）に分かれる。

ログイン検証は binding Cookie のハッシュ一致を CSRF 一致より先に見る。
binding が「このブラウザにフォームを渡した」ことの証明であり、CSRF トークンはその上の多層防御だからである。
承認・拒否の共通検証（`resolveApprovableRecord`）は、不存在・期限切れ・既決定・subject 不一致・CSRF 不一致をすべて同一文言の 403 に落とす。

`approveCibaRequest` は `grantId` を引数で受け取る。
grantId の発行を呼び出し側（生成コード）に置くことで、既存の revocation 機構が grant 単位失効をそのまま適用でき、experimental 側は ID の意味論に関与しない。
`approvedScope` は要求 scope をそのまま採用する（本 OP の UI は scope の部分承認を提供しない）。

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

### ciba-grant.ts（トークンエンドポイントの状態機械）

`processCibaGrant` はトークンエンドポイントの CIBA 分岐で、§11 の状態機械を評価する。
判定順序は Device Flow の実装と同じで、期限切れをポーリング過速より先に評価する。期限切れレコードの interval を増やしても意味がなく、クライアントへはフロー終了を伝えるべきだからである。

`lastPolledAt` の更新は `slow_down` と `authorization_pending` の 2 経路だけで行う。
他の結果はレコードを削除または consume するため、更新対象が残らない。
`denied` は `access_denied` の配信と同時にレコードを削除し、再ポーリングは `invalid_grant` になる。クライアントは §11 によりどちらのエラーでもフローを終了するため、相互運用上の問題はない。
`approved` は atomic な `consume` で回収し、並行リデンプションでは先勝ちの 1 本だけがトークンを得る。

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
 * 1. `auth_req_id` 欠落 → `invalid_request`
 * 2. レコード不存在・クライアント不一致 → `invalid_grant`（同一文言・レコードは残す）
 * 3. 期限切れ → `expired_token`（レコード削除）
 * 4. ポーリング過速 → `slow_down`（interval を +5 して保存）
 * 5. pending → `authorization_pending`（lastPolledAt 更新）
 * 6. denied → `access_denied`（レコード削除。再ポーリングは invalid_grant）
 * 7. approved → 結果を返す（レコードは consume で単回使用にする）
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
  const record = await resolveCibaRecord(input.params, input.client, input.store);
  return evaluateCibaState(record, input.store, input.now ?? new Date());
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

### index.ts（公開 API）

subpath export `@maronn-openid-connect/experimental/ciba` の公開面である。
ルート（`.`）からの再エクスポートはしない。

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

export { SLOW_DOWN_INTERVAL_INCREMENT, processCibaGrant } from './ciba-grant.js';
export type { CibaGrantResult } from './ciba-grant.js';
```

## 単体テストの全文と解説

テストは 90 ケースで、仕様書のテスト計画（正常系・境界値・エラー語彙・オラクル防止・状態機械の全遷移・consume の単回性）を固定する。

### test-helpers.ts（テスト専用フィクスチャ）

レコード工場とクライアント工場を機能内で共有する。
tsconfig の exclude で dist からは除外され、公開 package には載らない。

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

インメモリストアの契約、特に consume の単回性（並行 consume で 1 つだけ non-null）と `listPendingBySubject` のフィルタ（決定済み・期限切れの除外）を固定する。

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

バックチャネル認証エンドポイントの 43 ケース。
応答 3 フィールドと `auth_req_id` のエントロピー（256bit = Base64URL 43 文字）、クライアント検証（public client / grant 未登録 / ping・push 登録）、ヒント規則、scope の正規化と offline_access ポリシー、`binding_message` の境界（100 文字 OK / 101 文字 NG / 制御文字 NG）、`requested_expiry` のクランプと拒否、`unknown_user_id` の固定文言（resolver 例外との無差別化）、保留数制限を検証する。

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

認証デバイス UI のステップ関数の 25 ケース。
ログイントランザクションの発行（生値がレコードに保存されないこと）、検証の失敗理由の無差別化（同一文言）、失敗計数と上限到達時の削除、一覧の CSRF 発行と回転、承認・拒否の subject 束縛を検証する。

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

トークンエンドポイントの状態機械の 16 ケース。
全遷移（pending → `authorization_pending`、interval 内再ポーリング → `slow_down` と +5 の永続化、denied → `access_denied` と削除、期限切れ → `expired_token` と削除、approved → 発行データ返却）と、consume 後の再要求・別クライアント提示・欠落フィールドの `invalid_grant` を固定する。

```typescript
import { describe, expect, it } from 'vitest';
import { processCibaGrant } from './ciba-grant.js';
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

describe('processCibaGrant', () => {
  describe('Request validation (CIBA Section 10.1)', () => {
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

### テストが全部通ると何が保証されるのか

単体テストは「エンドポイントの入力検証が仕様の語彙どおりに落ちること」「状態機械が §11 の遷移と削除タイミングを守ること」「UI の防御（binding・CSRF・subject 束縛・オラクル防止）が関数レベルで成立していること」を保証する。
HTTP 層の配線（共有クライアント認証・Cache-Control・ルーティング）は次節の conformance テストが、実ブラウザと実ポーリングの全周は E2E テストが受け持つ。

## CLI 統合と生成コードへの寄与

`maronn-oidc generate <framework> --enable ciba` を指定すると、新規 2 ファイルの生成と既存 7 ファイルへの追記が入る。
`--enable ciba` を付けない生成出力は、conformance.test.ts に入る default-off 契約テスト（機能が誤って有効化されたら気付くための固定）を除き、従来とバイト単位で同一である。
以下はすべて hono ターゲットの生成結果からの掲載で、他フレームワークは同じテンプレートの変換共有により同等になる。

### routes/backchannel-authentication.ts（新規ファイル）

バックチャネル認証エンドポイントと、機能の設定値 `cibaConfig` を持つ。
設定値は認証デバイス UI・トークンルート・discovery からも参照される単一の情報源で、文書化した範囲を外れる値はモジュール読み込み時にエラーになる。
`login_hint` の解決は context の `cibaUserResolver`（app.ts が配線する）を使い、無ければ生成ユーザーストアをユーザー名で引くフォールバックを同じファイル内に見える形で持つ。

```typescript
/**
 * EXPERIMENTAL — OpenID Connect Client-Initiated Backchannel Authentication
 * (CIBA Core 1.0), poll mode.
 *
 * This route was generated because the OP was created with `--enable ciba`.
 * It is backed by @maronn-openid-connect/experimental, whose API is NOT stable: it may
 * change in a breaking way between releases. Do not build production code on it
 * without pinning the version.
 *
 * The consumption device (a call-center console, a kiosk, a smart speaker
 * backend) POSTs here — back channel, client-authenticated — with a login_hint
 * naming the user, and receives an auth_req_id it polls the token endpoint
 * with. The user approves or denies on their own browser at /ciba.
 *
 * NOTE (CIBA §15): the login_hint is a user identifier and therefore PII.
 * Never log it, and never echo it in an error_description. Rate limiting the
 * endpoint as a whole is deliberately left to the deployment layer (reverse
 * proxy / platform): an in-process counter cannot work on runtimes without
 * shared memory between instances. The in-band defenses are mandatory client
 * authentication, the fixed unknown_user_id wording, and the per-subject
 * pending-request cap below.
 */
import { Hono } from 'hono';
import {
  BackchannelAuthenticationError,
  processBackchannelAuthenticationRequest,
  type CibaClientInfo,
} from '@maronn-openid-connect/experimental/ciba';
import {
  TokenError,
  extractClientCredentials,
  resolveAuthenticatedTokenClient,
  sanitizeErrorDescription,
  validateClientAuthMethod,
  verifyClientSecret,
} from '@maronn-openid-connect/core';
import { tokenClientResolver as defaultTokenClientResolver } from '../resolvers.js';
import {
  cibaAuthenticationRequestStore as defaultCibaAuthenticationRequestStore,
  userStore,
} from '../store.js';

/**
 * EXPERIMENTAL — CIBA settings (CIBA Core 1.0).
 *
 * Imported by the authentication device UI, the token route and the discovery
 * route, so keep all of them in sync when changing them.
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

export const backchannelAuthenticationApp = new Hono<{ Variables: Record<string, any> }>();

/**
 * CIBA §7.1: the backchannel authentication request body MUST be
 * application/x-www-form-urlencoded.
 */
function isFormUrlEncoded(contentType: string): boolean {
  const [mediaType = ''] = contentType.toLowerCase().split(';');
  return mediaType.trim() === 'application/x-www-form-urlencoded';
}

function noStore(c: any): void {
  // auth_req_id is a credential, so the response follows the token response
  // rules of RFC 6749 §5.1 / §5.2.
  c.header('Cache-Control', 'no-store');
  c.header('Pragma', 'no-cache');
}

/**
 * Backchannel Authentication Endpoint
 * CIBA Core 1.0 §7.1 / §7.2 / §7.3
 */
backchannelAuthenticationApp.post('/', async (c) => {
  const contentType = c.req.header('Content-Type') ?? '';
  if (!isFormUrlEncoded(contentType)) {
    noStore(c);
    return c.json({ error: 'invalid_request', error_description: 'Backchannel authentication requests must use application/x-www-form-urlencoded' }, 400);
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
    noStore(c);
    return c.json({ error: 'invalid_request', error_description: `Parameter "${sanitizeErrorDescription(duplicateKey)}" must not be repeated` }, 400);
  }

  const authorization = c.req.header('Authorization') ?? '';

  try {
    const tokenClientResolver = c.get('tokenClientResolver') ?? defaultTokenClientResolver;
    const cibaStore = c.get('cibaAuthenticationRequestStore') ?? defaultCibaAuthenticationRequestStore;

    // --- Client authentication pipeline -------------------------------------
    // CIBA §7.1: "The Client MUST authenticate ... using the authentication
    // method registered for its client_id" — the same pipeline the token
    // endpoint runs, step function for step function.
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

    // login_hint → subject resolution is the deployment's swap point: the
    // default (wired in app.ts) treats the hint as a username of the configured
    // user store. Replace c.set('cibaUserResolver', ...) — or the fallback
    // below — to resolve email addresses, phone numbers, or your own ids.
    const resolveUser =
      c.get('cibaUserResolver') ??
      (async (loginHint: string) => {
        const claims = await userStore.getClaims(loginHint);
        return claims ? { subject: claims.sub } : null;
      });

    // --- Backchannel authentication pipeline --------------------------------
    // Validation runs in CIBA §7.1 order inside the experimental package:
    // client checks (public client / grant registration / delivery mode) →
    // request parameter rejection → the one-and-only-one hint rule → scope →
    // binding_message → requested_expiry → login_hint resolution → the
    // per-subject pending cap → record creation.
    const response = await processBackchannelAuthenticationRequest({
      params,
      client: client as CibaClientInfo,
      store: cibaStore,
      config: cibaConfig,
      refreshTokenFeatureEnabled: true,
      resolveUser,
    });

    // Never log auth_req_id (a live credential) or login_hint (PII, CIBA §15).

    noStore(c);
    return c.json(response);
  } catch (error) {
    noStore(c);
    if (error instanceof BackchannelAuthenticationError) {
      // CIBA §13 / RFC 6749 §5.2 error shape. Authentication failures never
      // reach here — they are core TokenErrors, handled below with their 401.
      return c.json({ error: error.code, error_description: error.errorDescription }, error.statusCode);
    }
    if (error instanceof TokenError) {
      const status = error.statusCode as 400 | 401;
      if (error.wwwAuthenticate) {
        c.header('WWW-Authenticate', error.wwwAuthenticate);
      }
      return c.json({ error: error.error, error_description: error.errorDescription }, status);
    }
    return c.json({ error: 'server_error' }, 500);
  }
});
```

### routes/ciba-verification.ts（新規ファイル）

認証デバイス UI の 3 ルートである。
`GET /ciba` はセッションがあれば保留一覧、無ければログイントランザクションを発行してログインフォームを返す（binding Cookie はこの応答で配られる）。
`POST /ciba/login` は binding → CSRF → 資格情報の順で検証し、成功でトランザクションを消費して**新規発行した** sessionId でセッションを確立する（リクエストが持ち込んだ ID を再利用しない。セッション固定攻撃の遮断）。
`POST /ciba/approve` はセッション必須で、承認・拒否を experimental のステップ関数へ委譲し、承認時は `/consent` と同じ形で consent と grant を記録する。

```typescript
/**
 * EXPERIMENTAL — OpenID Connect Client-Initiated Backchannel Authentication
 * (CIBA Core 1.0), authentication device UI.
 *
 * This route was generated because the OP was created with `--enable ciba`.
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
 * ## Why the login form demands a binding cookie
 *
 * A successful login establishes an OP session, whose reach goes beyond CIBA
 * (SSO, prompt=none). A hidden csrf_token alone cannot stop login CSRF: the
 * attacker fetches their own login form, reads a valid transaction id + token
 * pair, and embeds both in a forged cross-site POST — planting the attacker's
 * session in the victim's browser. The login transaction's binding cookie
 * (minted below, hash-stored) is what stops it — see
 * buildCibaLoginBindingCookie() in store.ts for the full model.
 *
 * ## Why approve / deny does NOT use a binding cookie
 *
 * The approval is already bound to the authenticated OP session: the record's
 * subject must equal the session subject, and the per-record csrf_token is only
 * ever rendered on the session-gated listing. Knowing an auth_req_id gives an
 * attacker no step to forge.
 */
import { Hono } from 'hono';
import {
  CibaVerificationError,
  approveCibaRequest,
  createCibaLoginTransaction,
  denyCibaRequest,
  listPendingCibaRequests,
  recordCibaLoginFailure,
  validateCibaLoginSubmission,
} from '@maronn-openid-connect/experimental/ciba';
import { generateRandomString } from '@maronn-openid-connect/core';
import {
  browserSessionStore as defaultBrowserSessionStore,
  buildCibaLoginBindingCookie,
  buildClearedCibaLoginBindingCookie,
  buildSessionCookie,
  cibaAuthenticationRequestStore as defaultCibaAuthenticationRequestStore,
  cibaLoginTransactionStore as defaultCibaLoginTransactionStore,
  parseCibaLoginBindingSecret,
  parseSessionId,
  userStore,
} from '../store.js';
import { defaultViews, renderView } from '../views.js';
import { cibaConfig } from './backchannel-authentication.js';

export const cibaApp = new Hono<{ Variables: Record<string, any> }>();

/**
 * Attach a Set-Cookie to a Response a view already produced.
 *
 * renderView() builds its own Response, so headers staged on the framework
 * context never reach it. Rebuilding the Response is the framework-neutral way
 * to add the cookie without making views cookie-aware.
 */
function withCookie(response: Response, cookie: string): Response {
  const headers = new Headers(response.headers);
  headers.append('Set-Cookie', cookie);
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

/** Map a verification failure to its error page; anything else is re-thrown. */
function renderVerificationError(views: typeof defaultViews, error: unknown): Response {
  if (error instanceof CibaVerificationError) {
    return renderView(
      views.errorPage({ error: error.message, statusCode: error.statusCode }),
      { status: error.statusCode },
    );
  }
  throw error;
}

/** Remaining lifetime of a pending request, in whole seconds, never negative. */
function remainingSeconds(expiresAt: Date): number {
  return Math.max(0, Math.ceil((expiresAt.getTime() - Date.now()) / 1000));
}

/**
 * Render the session subject's pending requests with freshly rotated CSRF
 * tokens (the only place those tokens are ever exposed, and it is
 * session-gated).
 */
async function renderPendingRequests(c: any, subject: string): Promise<Response> {
  const views = c.get('views') ?? defaultViews;
  const cibaStore = c.get('cibaAuthenticationRequestStore') ?? defaultCibaAuthenticationRequestStore;
  const pending = await listPendingCibaRequests({ subject, store: cibaStore });
  return renderView(views.cibaPendingRequestsPage({
    requests: pending.map((record) => ({
      authReqId: record.authReqId,
      clientId: record.clientId,
      scopes: record.scope,
      bindingMessage: record.bindingMessage,
      expiresInSeconds: remainingSeconds(record.expiresAt),
      csrfToken: record.csrfToken ?? '',
    })),
  }));
}

/**
 * Listing / login form - GET
 *
 * With an OP session: list the pending requests addressed to the signed-in
 * user. Without one: mint a login transaction and show the sign-in form, with
 * the binding cookie this response sets.
 */
cibaApp.get('/', async (c) => {
  const views = c.get('views') ?? defaultViews;
  const browserSessionStore = c.get('browserSessionStore') ?? defaultBrowserSessionStore;
  const loginTransactionStore =
    c.get('cibaLoginTransactionStore') ?? defaultCibaLoginTransactionStore;

  const sessionId = parseSessionId(c.req.header('Cookie') ?? null);
  const session = sessionId ? await browserSessionStore.get(sessionId) : undefined;
  if (session) {
    return renderPendingRequests(c, session.subject);
  }

  const { record, bindingSecret } = await createCibaLoginTransaction(loginTransactionStore);
  const cookie = buildCibaLoginBindingCookie(
    record.id,
    bindingSecret,
    remainingSeconds(record.expiresAt),
  );
  return withCookie(renderView(views.cibaLoginPage({
    loginTransactionId: record.id,
    csrfToken: record.csrfToken,
  })), cookie);
});

/**
 * Sign in - POST
 *
 * Binding first, then CSRF, then credentials: the binding is what proves this
 * is the browser the login form was issued to, and it must gate the step that
 * would otherwise let a forged POST establish an OP session in the victim's
 * browser.
 */
cibaApp.post('/login', async (c) => {
  const body = await c.req.parseBody();
  const transactionId = String(body['login_transaction_id'] ?? '');
  const csrfToken = String(body['csrf_token'] ?? '');
  const username = String(body['username'] ?? '');
  const password = String(body['password'] ?? '');

  const views = c.get('views') ?? defaultViews;
  const browserSessionStore = c.get('browserSessionStore') ?? defaultBrowserSessionStore;
  const loginTransactionStore =
    c.get('cibaLoginTransactionStore') ?? defaultCibaLoginTransactionStore;
  const authenticateUser =
    c.get('authenticateUser') ??
    ((u: string, p: string) => userStore.authenticate(u, p));

  let transaction;
  try {
    transaction = await validateCibaLoginSubmission({
      transactionId,
      csrfToken,
      bindingSecret: parseCibaLoginBindingSecret(c.req.header('Cookie') ?? null, transactionId),
      store: loginTransactionStore,
    });
  } catch (error) {
    return renderVerificationError(views, error);
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
      return renderView(views.errorPage({
        error: 'Too many login attempts',
        statusCode: 429,
      }), { status: 429 });
    }
    return renderView(views.cibaLoginPage({
      loginTransactionId: transaction.id,
      csrfToken: transaction.csrfToken,
      error: 'Invalid credentials',
      remainingAttempts: failure.remainingAttempts,
    }));
  }

  // The transaction is single-use: a successful login consumes it, and the
  // session is established under a NEWLY minted id (never one the request
  // brought along — session fixation).
  await loginTransactionStore.delete(transaction.id);
  const authTime = Math.floor(Date.now() / 1000);
  const sessionId = generateRandomString(32);
  await browserSessionStore.set(sessionId, { subject: user.sub, authTime });

  // Two cookies on one response: the new OP session, and the cleared login
  // binding (it is single-use and would otherwise linger until Max-Age).
  const listing = await renderPendingRequests(c, user.sub);
  return withCookie(
    withCookie(listing, buildSessionCookie(sessionId)),
    buildClearedCibaLoginBindingCookie(transaction.id),
  );
});

/**
 * Approve or deny - POST
 *
 * The only state-changing step of the UI. It demands an OP session whose
 * subject owns the record, plus the per-record csrf_token from the
 * session-gated listing.
 */
cibaApp.post('/approve', async (c) => {
  const body = await c.req.parseBody();
  const authReqId = String(body['auth_req_id'] ?? '');
  const csrfToken = String(body['csrf_token'] ?? '');
  const decision = String(body['decision'] ?? '');

  const views = c.get('views') ?? defaultViews;
  const browserSessionStore = c.get('browserSessionStore') ?? defaultBrowserSessionStore;
  const cibaStore = c.get('cibaAuthenticationRequestStore') ?? defaultCibaAuthenticationRequestStore;
  const consentResolver = c.get('consentResolver');

  const sessionId = parseSessionId(c.req.header('Cookie') ?? null);
  const session = sessionId ? await browserSessionStore.get(sessionId) : undefined;
  if (!session) {
    return renderView(views.errorPage({
      error: 'Sign in again to review this request',
      statusCode: 401,
    }), { status: 401 });
  }

  if (decision !== 'approve' && decision !== 'deny') {
    return renderView(views.errorPage({
      error: 'invalid_request',
      errorDescription: 'decision must be approve or deny',
      statusCode: 400,
    }), { status: 400 });
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
      // Record the consent the same way /consent does, so a later Authorization
      // Code Flow for this client skips the consent screen (OIDC Core 1.0 §3.1.2.4).
      await consentResolver?.recordConsent?.(
        approved.subject,
        approved.clientId,
        approved.approvedScope ?? approved.scope,
      );
      await consentResolver?.recordGrant?.(approved.subject, approved.clientId, approved.grantId);
      return renderView(views.cibaCompletedPage({
        approved: true,
        clientId: approved.clientId,
      }));
    }

    const record = await cibaStore.findByAuthReqId(authReqId);
    await denyCibaRequest({
      authReqId,
      subject: session.subject,
      csrfToken,
      store: cibaStore,
    });
    return renderView(views.cibaCompletedPage({
      approved: false,
      clientId: record?.clientId ?? '',
    }));
  } catch (error) {
    return renderVerificationError(views, error);
  }
});
```

### config.ts に入るもの

`RegisteredClient` に CIBA §4 の Registration パラメータ相当の `backchannelTokenDeliveryMode` が加わり、サンプルクライアントの `grantTypes` に CIBA URN が加わる。

```typescript
  backchannelTokenDeliveryMode?: 'poll' | 'ping' | 'push';
```

```typescript
      // EXPERIMENTAL (CIBA Core 1.0 §7.1): registering the CIBA URN is what lets
      // this confidential client POST /backchannel_authentication and poll the
      // token endpoint with the resulting auth_req_id. Remove it to forbid CIBA
      // for this client; public clients are rejected either way.
      grantTypes: ['authorization_code', 'refresh_token', 'urn:openid:params:grant-type:ciba'],
```

### store.ts に入るもの

ログイン用バインディング Cookie のヘルパー 3 つと、experimental のファクトリで作る 2 ストアのシングルトンが加わる。
Cookie 名にトランザクション ID を埋め込むのは、同じブラウザで 2 枚のログインフォームが並行しても互いの secret を上書きしないためである。

```typescript
import {
  createInMemoryCibaAuthenticationRequestStore,
  createInMemoryCibaLoginTransactionStore,
  type CibaAuthenticationRequestStore,
  type CibaLoginTransactionStore,
} from '@maronn-openid-connect/experimental/ciba';
```

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

// EXPERIMENTAL — CIBA stores. The in-memory implementations ship with
// @maronn-openid-connect/experimental/ciba; replace them with persistent stores (Redis, KV,
// database) in production. Treat authReqId and the login transaction id as
// opaque external values: never interpolate them into a query, always bind
// them as parameters. Kept on globalThis for the same reason as the provider
// stores above: Next.js instantiates route handlers and server actions in
// separate module layers.
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

### views.ts に入るもの

3 ページ分の型・Views 契約・デフォルト実装が加わる。
承認画面は `binding_message` をユーザーに見比べさせる照合手段としてそのまま表示するため、クライアント供給テキストのエスケープが契約になっている（conformance テストが固定する）。
拒否ボタンは承認と同等の視認性で置く。

```typescript
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
```

```typescript
  /** EXPERIMENTAL (CIBA Core 1.0): render the sign-in form of the authentication device UI */
  cibaLoginPage(params: CibaLoginPageParams): ViewResult;
  /** EXPERIMENTAL (CIBA Core 1.0): render the pending-requests approval screen */
  cibaPendingRequestsPage(params: CibaPendingRequestsPageParams): ViewResult;
  /** EXPERIMENTAL (CIBA Core 1.0): render the decision-recorded screen */
  cibaCompletedPage(params: CibaCompletedPageParams): ViewResult;
```

```typescript
function defaultCibaLoginPage(params: CibaLoginPageParams): string {
  const errorHtml = params.error
    ? `<p style="color: red;">${escapeHtml(params.error)}${
        params.remainingAttempts !== undefined
          ? `. Attempts remaining: ${params.remainingAttempts}`
          : ''
      }</p>`
    : '';

  return `<!DOCTYPE html>
<html>
<head><title>Sign in</title></head>
<body>
  <h1>Sign in</h1>
  <p>Sign in to review sign-in requests sent to you.</p>
  ${errorHtml}
  <form method="POST" action="/ciba/login">
    <input type="hidden" name="login_transaction_id" value="${escapeHtml(params.loginTransactionId)}" />
    <input type="hidden" name="csrf_token" value="${escapeHtml(params.csrfToken)}" />
    <div>
      <label for="username">Username:</label>
      <input type="text" id="username" name="username" required />
    </div>
    <div>
      <label for="password">Password:</label>
      <input type="password" id="password" name="password" required />
    </div>
    <button type="submit">Login</button>
  </form>
</body>
</html>`;
}

function defaultCibaPendingRequestsPage(params: CibaPendingRequestsPageParams): string {
  if (params.requests.length === 0) {
    return `<!DOCTYPE html>
<html>
<head><title>Sign-in Requests</title></head>
<body>
  <h1>Sign-in Requests</h1>
  <p>No pending sign-in requests.</p>
</body>
</html>`;
  }

  // CIBA Core 1.0 §7.1: the binding_message is repeated here on purpose. Ask
  // the user to check it against the device that started the request before
  // approving. The Deny button is rendered with the same prominence as Approve.
  const requestListHtml = params.requests
    .map((request) => {
      const scopeListHtml = request.scopes
        .map((s) => `      <li>${escapeHtml(s)}</li>`)
        .join('\n');
      const bindingMessageHtml = request.bindingMessage
        ? `    <p>Confirm that your device is showing this message: <strong>${escapeHtml(request.bindingMessage)}</strong></p>\n`
        : '';
      return `  <section>
    <p>Client <strong>${escapeHtml(request.clientId)}</strong> is requesting access to the following scopes:</p>
    <ul>
${scopeListHtml}
    </ul>
${bindingMessageHtml}    <p>This request expires in ${request.expiresInSeconds} seconds.</p>
    <form method="POST" action="/ciba/approve">
      <input type="hidden" name="auth_req_id" value="${escapeHtml(request.authReqId)}" />
      <input type="hidden" name="csrf_token" value="${escapeHtml(request.csrfToken)}" />
      <button type="submit" name="decision" value="approve">Approve</button>
      <button type="submit" name="decision" value="deny">Deny</button>
    </form>
  </section>`;
    })
    .join('\n');

  return `<!DOCTYPE html>
<html>
<head><title>Sign-in Requests</title></head>
<body>
  <h1>Sign-in Requests</h1>
  <p>Only approve a request you started yourself on another device.</p>
${requestListHtml}
</body>
</html>`;
}

function defaultCibaCompletedPage(params: CibaCompletedPageParams): string {
  const outcome = params.approved
    ? `<p>You approved <strong>${escapeHtml(params.clientId)}</strong>.</p>`
    : `<p>You denied <strong>${escapeHtml(params.clientId)}</strong>.</p>`;

  return `<!DOCTYPE html>
<html>
<head><title>Sign-in Requests</title></head>
<body>
  <h1>Sign-in Requests</h1>
${outcome}
  <p>You can close this page and go back to your device.</p>
</body>
</html>`;
}
```

```typescript
  cibaLoginPage: defaultCibaLoginPage,
  cibaPendingRequestsPage: defaultCibaPendingRequestsPage,
  cibaCompletedPage: defaultCibaCompletedPage,
```

### routes/discovery.ts に入るもの

`grant_types_supported` に CIBA URN が入り、§4 の REQUIRED 2 項目が応答へマージされる。
OPTIONAL 項目（署名 alg・user_code サポート）は、対応していないため出力しない。

```typescript
    grantTypesSupported: ['authorization_code', 'refresh_token', 'urn:openid:params:grant-type:ciba'],
```

```typescript
    // EXPERIMENTAL — CIBA Core 1.0 §4 metadata. Only the poll delivery mode is
    // offered, so exactly one mode is advertised.
    backchannel_token_delivery_modes_supported: ['poll'],
    backchannel_authentication_endpoint: `${issuer}/backchannel_authentication`,
```

### routes/token.ts に入るもの

import と、core の `validateGrantTypeSupported` より前に置かれる CIBA 分岐、`CibaGrantError` の catch 分岐が入る。
分岐内のトークン発行は標準 grant と同じ core 関数で組み立てられ、ID トークンの署名鍵選択（クライアント登録の `id_token_signed_response_alg` に合わせる）も標準 grant と同じ規則に従う。
ID トークンに nonce と c_hash は載らない（CIBA §7.1 に nonce パラメータは無く、認可コードも無い）。Poll モードに CIBA 固有クレームも無い（§10.3.1 の `auth_req_id` クレームは Push モードの配信メッセージ用である）。

```typescript
import {
  CIBA_GRANT_TYPE,
  CibaGrantError,
  processCibaGrant,
} from '@maronn-openid-connect/experimental/ciba';
import { cibaAuthenticationRequestStore as defaultCibaAuthenticationRequestStore } from '../store.js';
```

```typescript
    // --- EXPERIMENTAL: CIBA grant (CIBA Core 1.0 §10.1, poll mode) ----------
    // Dispatched right after client authentication and BEFORE core's
    // validateGrantTypeSupported, which does not know the URN and would reject
    // it with unsupported_grant_type. The branch answers the request itself and
    // never falls through to the standard grants.
    //
    // Backed by @maronn-openid-connect/experimental, whose API is NOT stable: it may change
    // in a breaking way between releases. Do not build production code on it
    // without pinning the version.
    if (params.grant_type === CIBA_GRANT_TYPE) {
      const cibaStore = c.get('cibaAuthenticationRequestStore') ?? defaultCibaAuthenticationRequestStore;

      // CIBA §11 state machine. Everything except "approved" throws:
      // authorization_pending / slow_down / access_denied / expired_token, plus
      // invalid_request / invalid_grant.
      const cibaGrant = await processCibaGrant({
        params,
        client: tokenClient,
        store: cibaStore,
      });

      // config / privateKey / keyId are bound further down for the standard
      // grants. This branch reads them on its own so the generated output is
      // unchanged when the feature is off; it returns, so nothing runs twice.
      const cibaTokenConfig = c.get('config');
      const cibaPrivateKey = c.get('privateKey');
      const cibaKeyId = c.get('keyId');
      // T-022: the ID Token this grant issues follows the SAME key-selection rule
      // as the standard grants — pick a registered ID Token key whose alg matches
      // the client's id_token_signed_response_alg (OIDC Dynamic Client
      // Registration 1.0 §2), not the general-purpose ACTIVE key. Using the
      // active key would hand an ES256-registered client an RS256 ID Token, which
      // it rejects, and would hash at_hash with the wrong algorithm.
      const cibaIdTokenSigningKeys = (c.get('idTokenSigningKeys') as SigningKey[] | undefined) ?? [];
      const cibaFallbackIdKey: SigningKey | undefined =
        c.get('idTokenPrivateKey') !== undefined
          ? {
              privateKey: c.get('idTokenPrivateKey'),
              publicJwk: c.get('idTokenPublicJwk'),
              keyId: c.get('idTokenKeyId') ?? cibaKeyId,
            }
          : undefined;
      const cibaRegisteredClient = (await tokenClientResolver.findClient(
        authenticatedClientId,
      )) as RegisteredClient | null;
      const cibaRequestedIdTokenAlg = cibaRegisteredClient?.idTokenSignedResponseAlg;
      let cibaSelectedIdTokenKey: SigningKey;
      if (cibaIdTokenSigningKeys.length > 0) {
        try {
          cibaSelectedIdTokenKey = selectSigningKeyByAlg(cibaIdTokenSigningKeys, cibaRequestedIdTokenAlg);
        } catch {
          c.header('Cache-Control', 'no-store');
          c.header('Pragma', 'no-cache');
          return c.json(
            {
              error: 'server_error',
              error_description: `No ID Token signing key registered for alg "${cibaRequestedIdTokenAlg ?? 'RS256'}"`,
            },
            500,
          );
        }
      } else if (cibaFallbackIdKey) {
        cibaSelectedIdTokenKey = cibaFallbackIdKey;
      } else {
        c.header('Cache-Control', 'no-store');
        c.header('Pragma', 'no-cache');
        return c.json({ error: 'server_error', error_description: 'No ID Token signing key registered' }, 500);
      }
      const cibaIdTokenPrivateKey = cibaSelectedIdTokenKey.privateKey;
      const cibaIdTokenKeyId = cibaSelectedIdTokenKey.keyId;
      const cibaIssuer: AccessTokenIssuer =
        cibaTokenConfig.accessTokenFormat === 'opaque'
          ? createOpaqueAccessTokenIssuer()
          : createJwtAccessTokenIssuer();

      // Same aud policy as the standard token route: the UserInfo endpoint stays
      // a permanent member (RFC 9068 §3). CIBA §7.1 has no resource parameter,
      // so nothing else is requested.
      const cibaAudience = buildAccessTokenAudience({
        userInfoEndpoint: `${cibaTokenConfig.issuer}/userinfo`,
        issuer: cibaTokenConfig.issuer,
      });

      const cibaIssuedAt = Math.floor(Date.now() / 1000);
      const cibaAccessTokenPayload = buildAccessTokenPayload({
        issuer: cibaTokenConfig.issuer,
        subject: cibaGrant.subject,
        clientId: cibaGrant.clientId,
        scope: cibaGrant.scope,
        audience: cibaAudience,
        expiresIn: cibaTokenConfig.accessTokenExpiresIn,
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
        issuer: cibaTokenConfig.issuer,
        subject: cibaGrant.subject,
        clientId: cibaGrant.clientId,
        scope: cibaGrant.scope,
        expiresIn: cibaTokenConfig.idTokenExpiresIn,
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
        expiresAt: cibaIssuedAt + cibaTokenConfig.accessTokenExpiresIn,
        // Inherit the grantId minted at approval so revoking the grant kills
        // every token issued from this backchannel authentication.
        grantId: cibaGrant.grantId,
        iat: cibaIssuedAt,
        nbf: cibaIssuedAt,
        audience: cibaAudience,
        issuer: cibaTokenConfig.issuer,
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
        const cibaRefreshTokenStore = c.get('refreshTokenStore') ?? defaultRefreshTokenStore;
        await cibaRefreshTokenStore.set(cibaRefreshToken, {
          subject: cibaGrant.subject,
          clientId: cibaGrant.clientId,
          scope: cibaGrant.scope,
          // OAuth 2.1 §6.1: absolute lifetime from initial issuance; rotations
          // inherit originalIssuedAt so the deadline never slides forward.
          expiresAt: cibaIssuedAt + cibaTokenConfig.refreshTokenAbsoluteLifetime,
          originalIssuedAt: cibaIssuedAt,
          used: false,
          grantId: cibaGrant.grantId,
          iat: cibaIssuedAt,
          issuer: cibaTokenConfig.issuer,
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

      // RFC 6749 §5.1: token responses MUST NOT be cached.
      c.header('Cache-Control', 'no-store');
      c.header('Pragma', 'no-cache');
      return c.json({
        access_token: cibaAccessToken,
        token_type: 'Bearer' as const,
        expires_in: cibaTokenConfig.accessTokenExpiresIn,
        id_token: cibaIdToken,
        scope: cibaGrant.scope.join(' '),
        refresh_token: cibaRefreshToken,
      });
    }
```

```typescript
    if (error instanceof CibaGrantError) {
      // CIBA §11: authorization_pending / slow_down / access_denied /
      // expired_token use the RFC 6749 §5.2 shape and are always 400. A 401 can
      // only come from client authentication, which runs before the branch and
      // throws core's TokenError.
      c.header('Cache-Control', 'no-store');
      c.header('Pragma', 'no-cache');
      return c.json(
        { error: error.code, error_description: error.errorDescription },
        error.statusCode,
      );
    }
```

### app.ts / apply.ts に入るもの

4 エンドポイントの許可メソッド・マウント・CORS（バックチャネルは `/token` と同じ保護 CORS、UI はブラウザ遷移なので無し）と、ストアおよび `login_hint` リゾルバの context 配線が入る。
リゾルバの既定は「ヒントを注入済みユーザーストアのユーザー名として引く」実装で、`createApp` の `cibaUserResolver` オプションで丸ごと差し替えられる。
apply.ts にも同等の追記が入る。

```typescript
import { backchannelAuthenticationApp } from './routes/backchannel-authentication.js';
import { cibaApp } from './routes/ciba-verification.js';
```

```typescript
  cibaAuthenticationRequestStore,
  cibaLoginTransactionStore,
```

```typescript
  /**
   * EXPERIMENTAL (CIBA Core 1.0 §7.1): resolve a login_hint to the subject the
   * authentication request is for. Defaults to treating the hint as a username
   * of the configured user store. Return null when no user matches.
   */
  cibaUserResolver?: (
    loginHint: string,
  ) => Promise<{ subject: string } | null> | { subject: string } | null;
```

```typescript
  '/backchannel_authentication': ['POST'],
  '/ciba': ['GET'],
  '/ciba/login': ['POST'],
  '/ciba/approve': ['POST'],
```

```typescript
  app.use('/backchannel_authentication', protectedCors);
```

```typescript
    c.set('cibaAuthenticationRequestStore', cibaAuthenticationRequestStore);
    c.set('cibaLoginTransactionStore', cibaLoginTransactionStore);
    c.set('cibaUserResolver', options.cibaUserResolver ?? (async (loginHint: string) => {
      const claims = await stores.userStore.getClaims(loginHint);
      return claims ? { subject: claims.sub } : null;
    }));
```

```typescript
  app.route('/backchannel_authentication', backchannelAuthenticationApp);
  app.route('/ciba', cibaApp);
```

### conformance.test.ts に入るもの

有効時は 48 ケースの契約テストが入り、無効時は default-off の 5 ケース（エンドポイント 404・URN の `unsupported_grant_type`・メタデータ不在）が入る。
テスト用クライアントとして、CIBA grant 登録済みの `c-ciba`、別クライアント拒否検証用の `c-ciba-other`、`ping` 登録拒否検証用の `c-ciba-ping`、ID トークン署名鍵選択検証用の `c-ciba-es256` が加わる。
レコードストアはモジュールグローバルでテストをまたいで生きるため、`afterEach` で testuser の保留レコードを掃除し、保留数上限と一覧の検証を決定的にしている。

```typescript
import { describe, it, expect, beforeAll, afterEach } from 'vitest';
```

```typescript
import { cibaAuthenticationRequestStore } from './store.js';
```

```typescript
  // EXPERIMENTAL (CIBA Core 1.0): a client registered for the CIBA grant, plus
  // a second one so the contract test can prove an auth_req_id is refused when
  // it is presented by a client other than the one it was issued to (§11).
  ['c-ciba', {
    clientId: 'c-ciba',
    clientSecret: 's',
    redirectUris: [REDIRECT_URI],
    clientType: 'confidential' as const,
    responseTypes: ['code'],
    grantTypes: ['urn:openid:params:grant-type:ciba', 'refresh_token'],
    tokenEndpointAuthMethod: 'client_secret_post',
  }],
  ['c-ciba-other', {
    clientId: 'c-ciba-other',
    clientSecret: 's',
    redirectUris: [REDIRECT_URI],
    clientType: 'confidential' as const,
    responseTypes: ['code'],
    grantTypes: ['urn:openid:params:grant-type:ciba'],
    tokenEndpointAuthMethod: 'client_secret_post',
  }],
  // A client that registered the ping delivery mode, so the contract test can
  // prove this poll-only provider refuses it (CIBA §4 advertises ['poll']).
  ['c-ciba-ping', {
    clientId: 'c-ciba-ping',
    clientSecret: 's',
    redirectUris: [REDIRECT_URI],
    clientType: 'confidential' as const,
    responseTypes: ['code'],
    grantTypes: ['urn:openid:params:grant-type:ciba'],
    tokenEndpointAuthMethod: 'client_secret_post',
    backchannelTokenDeliveryMode: 'ping' as const,
  }],
  // A CIBA client that registered id_token_signed_response_alg, so the contract
  // test can prove the CIBA grant honors it just like the standard grants
  // (OIDC Dynamic Client Registration 1.0 §2).
  ['c-ciba-es256', {
    clientId: 'c-ciba-es256',
    clientSecret: 's',
    redirectUris: [REDIRECT_URI],
    clientType: 'confidential' as const,
    responseTypes: ['code'],
    grantTypes: ['urn:openid:params:grant-type:ciba'],
    tokenEndpointAuthMethod: 'client_secret_post',
    idTokenSignedResponseAlg: 'ES256' as const,
  }],
```

```typescript
  // EXPERIMENTAL — OpenID Connect Client-Initiated Backchannel Authentication
  // (CIBA Core 1.0, poll mode). Generated because this provider was created
  // with --enable ciba.
  describe('CIBA (CIBA Core 1.0, poll mode)', () => {
    const CIBA_URN = 'urn:openid:params:grant-type:ciba';

    // The record store is module-global and outlives each test, while the
    // backchannel endpoint caps pending requests per subject
    // (cibaConfig.maxPendingPerSubject). Clearing testuser's leftovers keeps
    // every test inside the cap and keeps the listing assertions deterministic.
    afterEach(async () => {
      for (const record of await cibaAuthenticationRequestStore.listPendingBySubject('testuser')) {
        await cibaAuthenticationRequestStore.delete(record.authReqId);
      }
    });

    /**
     * The app under test. Defaults to the shared one; the ID Token signing key
     * selection test passes an app built on a mixed RS256 + ES256 key set.
     */
    type CibaTargetApp = { request: (path: string, init?: RequestInit) => Promise<Response> };

    // Pure helpers: they fetch and parse only. Every assertion lives in an it().
    function requestBackchannelAuthentication(
      overrides: Record<string, string> = {},
      target: CibaTargetApp = app,
    ): Promise<Response> {
      return target.request('/backchannel_authentication', {
```

```typescript
          client_id: 'c-ciba',
```

```typescript
          scope: 'openid',
          login_hint: 'testuser',
          ...overrides,
```

```typescript
    }

    function pollCibaToken(
      authReqId: string,
      overrides: Record<string, string> = {},
      target: CibaTargetApp = app,
    ): Promise<Response> {
      return target.request('/token', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({
          grant_type: CIBA_URN,
          auth_req_id: authReqId,
          client_id: 'c-ciba',
          client_secret: 's',
          ...overrides,
        }).toString(),
      });
    }

    function cibaCsrfFrom(html: string): string {
      return html.match(/name="csrf_token" value="([^"]+)"/)?.[1] ?? '';
    }

    function loginTransactionIdFrom(html: string): string {
      return html.match(/name="login_transaction_id" value="([^"]+)"/)?.[1] ?? '';
    }

    /** All Set-Cookie name=value pairs of a response, joined for a Cookie header. */
    function cibaCookieJar(...responses: Response[]): string {
      return responses
        .flatMap((res) => res.headers.getSetCookie())
        .map((cookie) => cookie.split(';')[0] ?? '')
        .filter((pair) => pair.length > 0 && !pair.endsWith('='))
        .join('; ');
    }

    function cibaLogin(
      body: Record<string, string>,
      cookie: string,
      target: CibaTargetApp = app,
    ): Promise<Response> {
      return target.request('/ciba/login', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          ...(cookie ? { Cookie: cookie } : {}),
        },
        body: new URLSearchParams(body).toString(),
      });
    }

    function cibaDecide(
      body: Record<string, string>,
      cookie: string,
      target: CibaTargetApp = app,
    ): Promise<Response> {
      return target.request('/ciba/approve', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          ...(cookie ? { Cookie: cookie } : {}),
        },
        body: new URLSearchParams(body).toString(),
      });
    }

    /**
     * Sign in on the authentication device UI and return the pending-requests
     * listing plus the session cookie. The login binding cookie is carried
     * forward exactly as a browser would; without it the OP answers 403.
     */
    async function cibaSignIn(
      target: CibaTargetApp = app,
    ): Promise<{ listingHtml: string; sessionCookie: string }> {
      const form = await target.request('/ciba');
      const formHtml = await form.text();
      const loginRes = await cibaLogin(
        {
          login_transaction_id: loginTransactionIdFrom(formHtml),
          csrf_token: cibaCsrfFrom(formHtml),
          username: 'testuser',
          password: 'password',
        },
        cibaCookieJar(form),
        target,
      );
      return {
        listingHtml: await loginRes.text(),
        sessionCookie: cibaCookieJar(loginRes),
      };
    }

    /**
     * Drive the whole browser side of the flow: sign in, find the request's
     * csrf token on the listing, and record the decision.
     */
    async function runCibaFlow(
      overrides: Record<string, string> = {},
      decision: 'approve' | 'deny' = 'approve',
      target: CibaTargetApp = app,
    ): Promise<{ auth_req_id: string; completed: Response }> {
      const authorization = await (await requestBackchannelAuthentication(overrides, target)).json();
      const { listingHtml, sessionCookie } = await cibaSignIn(target);
      const completed = await cibaDecide(
        {
          auth_req_id: authorization.auth_req_id,
          csrf_token: cibaCsrfFrom(listingHtml),
          decision,
        },
        sessionCookie,
        target,
      );
      return { auth_req_id: authorization.auth_req_id, completed };
    }

    describe('Backchannel authentication endpoint (CIBA Section 7)', () => {
      it('should return the three response fields with a non-cacheable body', async () => {
        const res = await requestBackchannelAuthentication();
        const body = await res.json();

        expect(res.status).toBe(200);
        expect(res.headers.get('Cache-Control')).toBe('no-store');
        expect(res.headers.get('Pragma')).toBe('no-cache');
        expect(Object.keys(body).sort()).toEqual(['auth_req_id', 'expires_in', 'interval']);
      });

      it('should return the configured lifetime and poll interval', async () => {
        const body = await (await requestBackchannelAuthentication()).json();

        expect([body.expires_in, body.interval]).toEqual([120, 5]);
      });

      it('should mint a 256-bit auth_req_id in the Base64URL character set', async () => {
        // CIBA Section 7.3: at least 128 bits of entropy, characters limited to
        // A-Z a-z 0-9 . - _ (Base64URL is a subset).
        const body = await (await requestBackchannelAuthentication()).json();

        expect(/^[A-Za-z0-9_-]{43}$/.test(body.auth_req_id)).toBe(true);
      });

      it('should issue a distinct auth_req_id for every request', async () => {
        const first = await (await requestBackchannelAuthentication()).json();
        const second = await (await requestBackchannelAuthentication()).json();

        expect(first.auth_req_id === second.auth_req_id).toBe(false);
      });

      it('should honor requested_expiry by clamping it into the allowed range', async () => {
        const body = await (await requestBackchannelAuthentication({ requested_expiry: '60' })).json();

        expect(body.expires_in).toBe(60);
      });

      it('should reject a body that is not form-urlencoded', async () => {
        const res = await app.request('/backchannel_authentication', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ client_id: 'c-ciba', scope: 'openid', login_hint: 'testuser' }),
        });

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_request',
          error_description: 'Backchannel authentication requests must use application/x-www-form-urlencoded',
        });
      });

      it('should reject an unauthenticated request with 401 invalid_client', async () => {
        const res = await app.request('/backchannel_authentication', {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: new URLSearchParams({ client_id: 'c-ciba', scope: 'openid', login_hint: 'testuser' }).toString(),
        });

        expect(res.status).toBe(401);
        expect((await res.json()).error).toBe('invalid_client');
      });

      it('should reject a client that is not registered for the CIBA grant', async () => {
        const res = await requestBackchannelAuthentication({ client_id: 'c-conf' });

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'unauthorized_client',
          error_description: 'The client is not authorized to use the CIBA grant',
        });
      });

      it('should reject a client registered for the ping delivery mode', async () => {
        // This provider only advertises ['poll'] (CIBA Section 4).
        const res = await requestBackchannelAuthentication({ client_id: 'c-ciba-ping' });

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'unauthorized_client',
          error_description: 'This provider only supports the poll token delivery mode',
        });
      });

      it('should reject a request with no scope', async () => {
        const res = await app.request('/backchannel_authentication', {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: new URLSearchParams({
            client_id: 'c-ciba',
            client_secret: 's',
            login_hint: 'testuser',
          }).toString(),
        });

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_request',
          error_description: 'Missing required parameter: scope',
        });
      });

      it('should reject a scope without openid', async () => {
        const res = await requestBackchannelAuthentication({ scope: 'profile' });

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_scope',
          error_description: 'The openid scope is required',
        });
      });

      it('should reject a request with no hint', async () => {
        // CIBA Section 7.1: one (and only one) of the hints is REQUIRED.
        const res = await app.request('/backchannel_authentication', {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: new URLSearchParams({
            client_id: 'c-ciba',
            client_secret: 's',
            scope: 'openid',
          }).toString(),
        });

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_request',
          error_description: 'Exactly one of login_hint, id_token_hint or login_hint_token is required',
        });
      });

      it('should reject a request with two hints', async () => {
        const res = await requestBackchannelAuthentication({ id_token_hint: 'x' });

        expect(res.status).toBe(400);
        expect((await res.json()).error).toBe('invalid_request');
      });

      it('should reject id_token_hint as an unsupported hint type', async () => {
        const res = await app.request('/backchannel_authentication', {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: new URLSearchParams({
            client_id: 'c-ciba',
            client_secret: 's',
            scope: 'openid',
            id_token_hint: 'x',
          }).toString(),
        });

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_request',
          error_description: 'Only login_hint is supported by this provider',
        });
      });

      it('should answer an unknown login_hint with the fixed unknown_user_id wording', async () => {
        const res = await requestBackchannelAuthentication({ login_hint: 'nobody' });

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'unknown_user_id',
          error_description: 'The login_hint could not be matched to a user',
        });
      });

      it('should reject an oversized binding_message', async () => {
        const res = await requestBackchannelAuthentication({ binding_message: 'a'.repeat(101) });

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_binding_message',
          error_description: 'binding_message must be 1 to 100 characters without control characters',
        });
      });

      it('should reject a non-integer requested_expiry', async () => {
        const res = await requestBackchannelAuthentication({ requested_expiry: 'soon' });

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'invalid_request',
          error_description: 'requested_expiry must be a positive integer',
        });
      });
    });

    describe('Discovery metadata (CIBA Section 4)', () => {
      it('should advertise the backchannel authentication endpoint', async () => {
        const metadata = await (await app.request('/.well-known/openid-configuration')).json();

        expect(metadata.backchannel_authentication_endpoint).toBe(
          'http://localhost:3000/backchannel_authentication',
        );
      });

      it('should advertise only the poll delivery mode', async () => {
        const metadata = await (await app.request('/.well-known/openid-configuration')).json();

        expect(metadata.backchannel_token_delivery_modes_supported).toEqual(['poll']);
      });

      it('should advertise the CIBA grant type', async () => {
        const metadata = await (await app.request('/.well-known/openid-configuration')).json();

        expect((metadata.grant_types_supported as string[]).includes(CIBA_URN)).toBe(true);
      });
    });

    describe('Authentication device UI', () => {
      it('should show the sign-in form when no OP session exists', async () => {
        const res = await app.request('/ciba');
        const html = await res.text();

        expect(res.status).toBe(200);
        expect(html.includes('action="/ciba/login"')).toBe(true);
      });

      it('should set the login binding cookie with the exact hardening attributes', async () => {
        const res = await app.request('/ciba');
        const html = await res.text();
        const cookie = res.headers.getSetCookie()[0] ?? '';

        expect(cookie.startsWith('oidc_ciba_login_' + loginTransactionIdFrom(html) + '=')).toBe(true);
        expect(cookie.endsWith('; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=600')).toBe(true);
      });

      it('should reject /ciba/login without the binding cookie even with a valid csrf_token', async () => {
        // The whole point: a valid transaction id + csrf pair is obtainable by
        // anyone who loads /ciba themselves, so it must NOT suffice on its own.
        const form = await app.request('/ciba');
        const html = await form.text();

        const res = await cibaLogin(
          {
            login_transaction_id: loginTransactionIdFrom(html),
            csrf_token: cibaCsrfFrom(html),
            username: 'testuser',
            password: 'password',
          },
          '',
        );

        expect(res.status).toBe(403);
      });

      it('should not establish a session when /ciba/login is unbound', async () => {
        const form = await app.request('/ciba');
        const html = await form.text();

        const res = await cibaLogin(
          {
            login_transaction_id: loginTransactionIdFrom(html),
            csrf_token: cibaCsrfFrom(html),
            username: 'testuser',
            password: 'password',
          },
          '',
        );

        expect(res.headers.getSetCookie()).toEqual([]);
      });

      it('should reject a wrong csrf_token even with a valid binding cookie', async () => {
        const form = await app.request('/ciba');
        const html = await form.text();

        const res = await cibaLogin(
          {
            login_transaction_id: loginTransactionIdFrom(html),
            csrf_token: 'forged',
            username: 'testuser',
            password: 'password',
          },
          cibaCookieJar(form),
        );

        expect(res.status).toBe(403);
      });

      it('should discard the login transaction after too many failed attempts', async () => {
        const form = await app.request('/ciba');
        const html = await form.text();
        const cookie = cibaCookieJar(form);
        const credentials = {
          login_transaction_id: loginTransactionIdFrom(html),
          csrf_token: cibaCsrfFrom(html),
          username: 'testuser',
          password: 'wrong',
        };

        let res = await cibaLogin(credentials, cookie);
        for (let i = 0; i < 4; i++) {
          res = await cibaLogin(credentials, cookie);
        }
        const retry = await cibaLogin({ ...credentials, password: 'password' }, cookie);

        expect(res.status).toBe(429);
        // The transaction is gone: even the right password cannot use this form.
        expect(retry.status).toBe(403);
      });

      it('should list the pending request with its client, scopes and binding message', async () => {
        await requestBackchannelAuthentication({ binding_message: 'AB-123' });
        const { listingHtml } = await cibaSignIn();

        expect(listingHtml.includes('<strong>c-ciba</strong>')).toBe(true);
        expect(listingHtml.includes('<li>openid</li>')).toBe(true);
        expect(listingHtml.includes('<strong>AB-123</strong>')).toBe(true);
      });

      it('should HTML-escape the binding message on the approval screen', async () => {
        await requestBackchannelAuthentication({
          binding_message: "<img src=x onerror=alert(1)>",
        });
        const { listingHtml } = await cibaSignIn();

        expect(listingHtml.includes('<img src=x')).toBe(false);
        expect(listingHtml.includes('&lt;img src=x onerror=alert(1)&gt;')).toBe(true);
      });

      it('should show an empty listing to a user with no pending requests', async () => {
        const { listingHtml } = await cibaSignIn();

        expect(listingHtml.includes('No pending sign-in requests.')).toBe(true);
      });

      it('should not list requests addressed to another user', async () => {
        // The pending request names testuser; otheruser signs in and must not
        // see it (nor its csrf_token).
        await requestBackchannelAuthentication();
        const form = await app.request('/ciba');
        const formHtml = await form.text();
        const loginRes = await cibaLogin(
          {
            login_transaction_id: loginTransactionIdFrom(formHtml),
            csrf_token: cibaCsrfFrom(formHtml),
            username: 'otheruser',
            password: 'password',
          },
          cibaCookieJar(form),
        );
        const listingHtml = await loginRes.text();

        expect(listingHtml.includes('No pending sign-in requests.')).toBe(true);
      });

      it('should refuse the decision without an OP session', async () => {
        const authorization = await (await requestBackchannelAuthentication()).json();
        const { listingHtml } = await cibaSignIn();

        const res = await cibaDecide(
          {
            auth_req_id: authorization.auth_req_id,
            csrf_token: cibaCsrfFrom(listingHtml),
            decision: 'approve',
          },
          '',
        );

        expect(res.status).toBe(401);
      });

      it('should refuse a decision by a session whose subject does not own the record', async () => {
        const authorization = await (await requestBackchannelAuthentication()).json();
        const { listingHtml } = await cibaSignIn();
        const csrfToken = cibaCsrfFrom(listingHtml);
        // otheruser signs in on their own browser and replays testuser's form.
        const otherForm = await app.request('/ciba');
        const otherFormHtml = await otherForm.text();
        const otherLogin = await cibaLogin(
          {
            login_transaction_id: loginTransactionIdFrom(otherFormHtml),
            csrf_token: cibaCsrfFrom(otherFormHtml),
            username: 'otheruser',
            password: 'password',
          },
          cibaCookieJar(otherForm),
        );

        const res = await cibaDecide(
          {
            auth_req_id: authorization.auth_req_id,
            csrf_token: csrfToken,
            decision: 'approve',
          },
          cibaCookieJar(otherLogin),
        );

        expect(res.status).toBe(403);
        // The record is untouched: the rightful user can still decide.
        const poll = await pollCibaToken(authorization.auth_req_id);
        expect((await poll.json()).error).toBe('authorization_pending');
      });

      it('should refuse a decision with a wrong csrf_token', async () => {
        const authorization = await (await requestBackchannelAuthentication()).json();
        const { sessionCookie } = await cibaSignIn();

        const res = await cibaDecide(
          {
            auth_req_id: authorization.auth_req_id,
            csrf_token: 'forged',
            decision: 'approve',
          },
          sessionCookie,
        );

        expect(res.status).toBe(403);
      });

      it('should refuse an unknown decision value', async () => {
        const authorization = await (await requestBackchannelAuthentication()).json();
        const { listingHtml, sessionCookie } = await cibaSignIn();

        const res = await cibaDecide(
          {
            auth_req_id: authorization.auth_req_id,
            csrf_token: cibaCsrfFrom(listingHtml),
            decision: 'maybe',
          },
          sessionCookie,
        );

        expect(res.status).toBe(400);
      });
    });

    describe('Token polling (CIBA Section 10.1 / 11)', () => {
      it('should answer authorization_pending before the user decides', async () => {
        const body = await (await requestBackchannelAuthentication()).json();
        const res = await pollCibaToken(body.auth_req_id);

        expect(res.status).toBe(400);
        expect(res.headers.get('Cache-Control')).toBe('no-store');
        expect(await res.json()).toEqual({
          error: 'authorization_pending',
          error_description: 'The authentication request is still pending',
        });
      });

      it('should answer slow_down when polled again inside the interval', async () => {
        const body = await (await requestBackchannelAuthentication()).json();
        await pollCibaToken(body.auth_req_id);
        const res = await pollCibaToken(body.auth_req_id);

        expect(res.status).toBe(400);
        expect(await res.json()).toEqual({
          error: 'slow_down',
          error_description: 'Polling too frequently. Increase the interval by 5 seconds.',
        });
      });

      it('should reject a missing auth_req_id with invalid_request', async () => {
        const res = await app.request('/token', {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: new URLSearchParams({
            grant_type: CIBA_URN,
            client_id: 'c-ciba',
            client_secret: 's',
          }).toString(),
        });

        expect(await res.json()).toEqual({
          error: 'invalid_request',
          error_description: 'Missing required parameter: auth_req_id',
        });
      });

      it('should reject an unknown auth_req_id with invalid_grant', async () => {
        const res = await pollCibaToken('not-a-real-auth-req-id');

        expect(await res.json()).toEqual({
          error: 'invalid_grant',
          error_description: 'The auth_req_id is invalid, expired, or was issued to another client',
        });
      });

      it('should reject an auth_req_id presented by another client with the same wording', async () => {
        // CIBA Section 11: the auth_req_id belongs to the client it was issued
        // to. The wording matches the unknown-id case so existence is not leaked.
        const body = await (await requestBackchannelAuthentication()).json();
        const res = await pollCibaToken(body.auth_req_id, {
          client_id: 'c-ciba-other',
        });

        expect(await res.json()).toEqual({
          error: 'invalid_grant',
          error_description: 'The auth_req_id is invalid, expired, or was issued to another client',
        });
      });

      it('should answer access_denied after the user denies', async () => {
        const flow = await runCibaFlow({}, 'deny');
        const res = await pollCibaToken(flow.auth_req_id);

        expect(await res.json()).toEqual({
          error: 'access_denied',
          error_description: 'The end-user denied the authentication request',
        });
      });
    });

    describe('Token issuance (CIBA Section 10.1 → OIDC Core 1.0 Section 3.1.3.3)', () => {
      it('should issue an access token and an ID Token after approval', async () => {
        const flow = await runCibaFlow();
        const res = await pollCibaToken(flow.auth_req_id);
        const body = await res.json();

        expect(res.status).toBe(200);
        expect(res.headers.get('Cache-Control')).toBe('no-store');
        expect(body.token_type).toBe('Bearer');
        expect(body.scope).toBe('openid');
        expect(typeof body.access_token).toBe('string');
        expect(typeof body.id_token).toBe('string');
      });

      it('should omit nonce and c_hash from the ID Token', async () => {
        // CIBA Section 7.1 defines no nonce parameter, and there is no
        // authorization code, so neither claim has a value to carry
        // (OIDC Core 1.0 Section 2). Poll mode adds no CIBA-specific claims:
        // the auth_req_id claim of Section 10.3.1 belongs to push delivery.
        const flow = await runCibaFlow();
        const body = await (await pollCibaToken(flow.auth_req_id)).json();
        const payload = idTokenPayload(body.id_token);

        expect(payload.nonce).toBeUndefined();
        expect(payload.c_hash).toBeUndefined();
      });

      it('should carry the auth_time recorded at approval', async () => {
        const flow = await runCibaFlow();
        const body = await (await pollCibaToken(flow.auth_req_id)).json();
        const payload = idTokenPayload(body.id_token);

        expect(typeof payload.auth_time).toBe('number');
        expect(payload.aud).toBe('c-ciba');
      });

      it('should let the issued access token reach the UserInfo endpoint', async () => {
        const flow = await runCibaFlow();
        const body = await (await pollCibaToken(flow.auth_req_id)).json();
        const res = await app.request('/userinfo', {
          headers: { Authorization: 'Bearer ' + body.access_token },
        });

        expect(res.status).toBe(200);
        expect((await res.json()).sub).toBe('testuser');
      });

      it('should refuse to redeem the same auth_req_id twice', async () => {
        const flow = await runCibaFlow();
        await pollCibaToken(flow.auth_req_id);
        const res = await pollCibaToken(flow.auth_req_id);

        expect(await res.json()).toEqual({
          error: 'invalid_grant',
          error_description: 'The auth_req_id is invalid, expired, or was issued to another client',
        });
      });

    it('should issue a refresh token when offline_access was approved', async () => {
      // OIDC Core 1.0 §11: the approval screen IS the explicit consent, and
      // c-ciba is registered for the refresh_token grant.
      const flow = await runCibaFlow({ scope: 'openid offline_access' });
      const res = await pollCibaToken(flow.auth_req_id);
      const body = await res.json();

      expect(typeof body.refresh_token).toBe('string');
    });
    });

    describe('ID Token signing key selection (OIDC Dynamic Client Registration 1.0 Section 2)', () => {
      /** JOSE header of a compact JWS, decoded. */
      function cibaJoseHeader(jwt: string): Record<string, unknown> {
        const segment = jwt.split('.')[0] ?? '';
        return JSON.parse(
          new TextDecoder().decode(
            Uint8Array.from(atob(segment.replace(/-/g, '+').replace(/_/g, '/')), (char) => char.charCodeAt(0)),
          ),
        );
      }

      // A client may register id_token_signed_response_alg, and the standard
      // grants pick a registered key matching it. The CIBA grant MUST NOT
      // diverge: signing this client's ID Token with whichever key happens to
      // be ACTIVE would hand it an RS256 token it rejects, and would compute
      // at_hash with the wrong hash function (OIDC Core 1.0 Section 3.1.3.6).
      it('should sign the CIBA grant ID Token with the alg the client registered', async () => {
        const rs256Pair = await crypto.subtle.generateKey(
          { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
          true,
          ['sign', 'verify'],
        );
        const es256Pair = await crypto.subtle.generateKey(
          { name: 'ECDSA', namedCurve: 'P-256' },
          true,
          ['sign', 'verify'],
        );
        const mixedProvider: SigningKeyProvider = {
          // Active key is RS256; the registered set also holds an ES256 key.
          async getSigningKey(): Promise<SigningKey> {
            return {
              privateKey: rs256Pair.privateKey,
              publicJwk: await crypto.subtle.exportKey('jwk', rs256Pair.publicKey),
              keyId: 'ciba-rs256',
            };
          },
          async getSigningKeys(): Promise<SigningKey[]> {
            return [
              {
                privateKey: rs256Pair.privateKey,
                publicJwk: await crypto.subtle.exportKey('jwk', rs256Pair.publicKey),
                keyId: 'ciba-rs256',
              },
              {
                privateKey: es256Pair.privateKey,
                publicJwk: await crypto.subtle.exportKey('jwk', es256Pair.publicKey),
                keyId: 'ciba-es256',
              },
            ];
          },
        };
        const mixedApp = createApp({
          signingKeyProvider: mixedProvider,
          clientResolver: createInMemoryClientResolver(testClients),
        });
        const client = { client_id: 'c-ciba-es256', client_secret: 's' };

        const flow = await runCibaFlow(client, 'approve', mixedApp);
        const body = await (await pollCibaToken(flow.auth_req_id, client, mixedApp)).json();
        const [encodedHeader = '', encodedPayload = '', encodedSignature = ''] =
          (body.id_token as string).split('.');
        const base64 = encodedSignature.replace(/-/g, '+').replace(/_/g, '/');
        const padded = base64.padEnd(base64.length + ((4 - (base64.length % 4)) % 4), '=');
        const signatureValid = await crypto.subtle.verify(
          { name: 'ECDSA', hash: 'SHA-256' },
          es256Pair.publicKey,
          Uint8Array.from(atob(padded), (char) => char.charCodeAt(0)),
          new TextEncoder().encode(encodedHeader + '.' + encodedPayload),
        );

        expect(cibaJoseHeader(body.id_token)).toEqual({
          alg: 'ES256',
          typ: 'JWT',
          kid: 'ciba-es256',
        });
        expect(signatureValid).toBe(true);
      });

      it('should keep signing with RS256 for a client that registered no alg', async () => {
        const flow = await runCibaFlow();
        const body = await (await pollCibaToken(flow.auth_req_id)).json();

        expect(cibaJoseHeader(body.id_token)).toEqual({
          alg: 'RS256',
          typ: 'JWT',
          kid: 'test-key',
        });
      });
```

### 他フレームワークの差分

express / fastify は hono テンプレートの web-standard 変換で同じルートが入る（express はプレフィックス一致なので `/backchannel_authentication` と `/ciba` の 2 エントリ、fastify は完全一致なので 4 ルートを明示登録）。
Next.js は Route Handler（`backchannel_authentication/route.ts`・`ciba/route.ts`・`ciba/login/route.ts`・`ciba/approve/route.ts`）が加わり、UI は他フレームワークと同じ views.ts 契約で描画される。
CLI のテストが 4 フレームワークすべてについて、有効時の生成と無効時の不在を固定している。

### サンプルと E2E 環境の配線

4 つのサンプル（hono-cloudflare / express-flyio / fastify-flyio / nextjs-vercel）の `generate` スクリプトへ `--enable ciba` を追加して再生成した。
E2E 環境では、`e2e-client` の登録 `grantTypes` に CIBA URN が加わり、別クライアント拒否の検証用に `e2e-ciba-other` が加わる。
consumption device 役は E2E クライアントアプリが担い、`/start-ciba` がバックチャネル依頼とバックグラウンドのポーリング（`slow_down` の +5 秒対応を含む）を開始し、`/ciba-result` がその到達状態を返す。

E2E クライアントアプリに入るのは次のコードである。

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
  void pollCibaToken(flow, authentication.auth_req_id, authentication.interval);

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
    const body = await response.json();

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

## E2E テストの全文と解説

E2E は実ブラウザ（Playwright）と実 HTTP で全周を検証する。
承認フロー（バックチャネル依頼 → ブラウザでログイン → `binding_message` で自分の依頼を特定して承認 → ポーリング完了 → UserInfo）、拒否フロー（`access_denied` の受領）、決定前の `authorization_pending`、binding Cookie の無い偽造ログイン POST の拒否、別クライアントによる `auth_req_id` 提示の拒否、の 5 シナリオである。
`--enable ciba` なしで生成されたサンプル OP に対しては、discovery の判定で自動的に skip する。

各フローに一意な `binding_message` を付けているのは、OP プロセスがテストをまたいで生きるため、保留一覧に他のテストのレコードが残っていても自分の依頼のセクションを特定できるようにするためである。

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

## 関連資料

- [OpenID Connect Client-Initiated Backchannel Authentication Flow - Core 1.0](https://openid.net/specs/openid-client-initiated-backchannel-authentication-core-1_0.html)
- [RFC 6749 - The OAuth 2.0 Authorization Framework](https://www.rfc-editor.org/rfc/rfc6749)
- [RFC 8628 - OAuth 2.0 Device Authorization Grant](https://www.rfc-editor.org/rfc/rfc8628)（ポーリング状態機械の先例。CIBA の規範ではない）
- 要件文書: `tasks/experimental/done/ciba/`（仕様書・理解資料・一次資料対応表・レビュー記録）
- 利用者向けドキュメント: OSS リポジトリの `docs/library-document/src/content/docs/experimental/ciba.md`
