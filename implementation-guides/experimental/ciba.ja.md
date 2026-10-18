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
生成コードの `features/ciba/store.ts` はこのファクトリを呼んだ結果を保持するだけになり、生成コードへ複製されるストア実装が減る。

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
`BackchannelAuthenticationError` はバックチャネル認証エンドポイントの §13 語彙、`CibaGrantError` はトークンエンドポイントの §11 語彙（`unauthorized_client` など RFC 6749 §5.2 の既存値を含む）で、どちらも RFC 6749 §5.2 の JSON 形・常に 400 で返る（401 はクライアント認証を担う core の `TokenError` だけが返す）。
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
評価に入る前に、`validateCibaGrantAllowed` がクライアントの登録 `grant_types` に CIBA の URN が含まれることを検証する（RFC 6749 §5.2 の `unauthorized_client`）。
バックチャネルエンドポイントは受付時に同じ検査を行うが、`auth_req_id` の発行から償還までの間に登録から CIBA が外れる場合を受付時の検査だけでは塞げない。
Device Flow が `validateDeviceCodeGrantAllowed` で償還時にも検査しているのと同じ位置づけである。
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

export {
  SLOW_DOWN_INTERVAL_INCREMENT,
  processCibaGrant,
  validateCibaGrantAllowed,
} from './ciba-grant.js';
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

トークンエンドポイントの状態機械の 20 ケース。
全遷移（pending → `authorization_pending`、interval 内再ポーリング → `slow_down` と +5 の永続化、denied → `access_denied` と削除、期限切れ → `expired_token` と削除、approved → 発行データ返却）と、consume 後の再要求・別クライアント提示・欠落フィールドの `invalid_grant` を固定する。
加えて `validateCibaGrantAllowed` の受理・拒否と、CIBA grant の登録が外れたクライアントの償還が状態機械の評価前に `unauthorized_client` で止まり、レコードに状態遷移を残さないことを固定する。

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

### テストが全部通ると何が保証されるのか

単体テストは「エンドポイントの入力検証が仕様の語彙どおりに落ちること」「状態機械が §11 の遷移と削除タイミングを守ること」「UI の防御（binding・CSRF・subject 束縛・オラクル防止）が関数レベルで成立していること」を保証する。
HTTP 層の配線（共有クライアント認証、Cache-Control、ルーティング）は生成コードの取り出し元 `apps/hono` で機能のファイルの隣に置いたテストが、実ブラウザと実ポーリングの全周は E2E テストが受け持つ。

## CLI 統合と生成コードへの寄与

experimental パッケージが持つのはレコードの管理と状態機械という論理の層で、HTTP の受け口、Cookie、画面、トークン発行の組み立ては CLI の生成コードが持つ。
`maronn-oidc generate <framework> --enable ciba` は、動くアプリである `apps/hono/src/oidc-provider/` からこの機能が所有するコードを取り出し、生成コードへ加える。
取り出し方は [packages/cli/extract.json](../../../packages/cli/extract.json) が定め、[packages/cli/src/generate.ts](../../../packages/cli/src/generate.ts) が実行する。
加わるのは次の 3 つである。

- **`features/ciba/`**：機能が所有するファイル一式で、`feature.ts` の `defineFeature()` が、ルート 2 つ（保護 CORS つきの `POST /backchannel_authentication` と、下位パス `/ciba/login` と `/ciba/approve` を持つ認証デバイス画面 `/ciba`）、discovery の `backchannel_authentication_endpoint` と `backchannel_token_delivery_modes_supported`、context の 2 ストアと `cibaUserResolver`、`token.grants` の `urn:openid:params:grant-type:ciba` を宣言し、`config.ts` が `OidcProviderOptions` に `cibaUserResolver` を加える
- **`features/enabled.ts` の import 1 つとリスト要素 1 つ**
- **`endpoints/token/pipeline.ts` の `(feature: ciba)` ブロック 1 つ**：`authenticate-client` ステップと `validate-grant-type` ステップのあいだで CIBA grant を引き換える

リクエストの流れは 3 本ある。
consumption device の `POST /backchannel_authentication` は、`app.ts` が `routesOf(features)` でマウントした `features/ciba/endpoints/backchannel-authentication/pipeline.ts` に届く。
このパイプラインはリクエストの解析、クライアント認証、登録 scope の検証、`login_hint` の解決と保留リクエストの作成、応答の順にステップを呼ぶ。
ユーザーが自分のブラウザで開く `/ciba` は `features/ciba/endpoints/ciba/page.tsx` が受け、`steps/` の 3 ステップが返す outcome を画面と Cookie に変える。
consumption device のポーリング `POST /token` は基盤の `endpoints/token/pipeline.ts` に届き、クライアント認証の直後にある dispatch-ciba ブロックが `grant_type` を見て、CIBA grant ならその場で応答を返す。

トークンエンドポイントへの寄与だけがフックではなくブロックになっているのは、処理を基盤のパイプラインの途中に置く必要があるからである。
基盤の `validate-grant-type` ステップが呼ぶ core の `validateGrantTypeSupported()` は、`authorization_code` と `refresh_token` 以外の `grant_type` を `unsupported_grant_type` で拒否する。
そのため CIBA grant は、このステップより前で応答を返さなければならない。
固定のフック（`routes`、`discovery`、`context`、`config`、`token.grants` など）は基盤のパイプラインに処理を差し込む手段を持たないので、この処理は所有ブロックとしてパイプラインに置かれ、ステップの本体は `features/ciba/steps/dispatch-ciba.ts` に置かれる。
`token.grants` に宣言した URN は discovery の `grant_types_supported` に並ぶが、トークンエンドポイントで URN を実際に受け付けるのはこのブロックである。

これに対して `login_hint` の解決は、パイプラインのブロックではなく context フックの値として渡す。
解決方法はデプロイごとに差し替える設定であってパイプラインの段ではなく、ステップは `c.get('cibaUserResolver')` を呼ぶだけで済む。
context フックを関数にしているのは、既定の解決がリクエストごとのユーザーストア（`c.get('userStore')`）を読むからである。
`app.ts` はストアをリクエストごとに解決するので（Cloudflare Workers では D1 のバインディングがリクエストに付く）、既定の解決もリクエストの `c` から組み立てる必要がある。

機能を無効にした生成では、ディレクトリ `features/ciba/` が出力されず、`features/enabled.ts` にも import とリスト要素が書かれない。
トークンエンドポイントのパイプラインからは、ブロックとブロックだけが使う import が削除される。
ブロックが定義する `cibaGrantResponse` を後続のブロックは読まないので、`const cibaGrantResponse = undefined;` の置き換えも残らない。

生成コードにはテストが入らない。
取り出し元の `apps/hono` では、この機能のファイルの隣に置いたテスト（[apps/hono/src/oidc-provider/features/ciba](../../../apps/hono/src/oidc-provider/features/ciba) 以下の `*.test.ts` と `*.test.tsx`）が挙動を固定しており、取り出しの際に除外される。

### 生成コードに入るコードの全文（hono）

以下は、既定の機能に `--enable ciba` を加えて hono 向けに生成した出力から、この機能が加えるコードを掲載したものである。
機能ディレクトリのファイルは 21 個あり、`feature.ts`、設定とストアと Cookie と画面、バックチャネル認証エンドポイント、認証デバイス画面、トークンエンドポイントのステップの順に並べる。

#### `features/enabled.ts` に入る行

`features/enabled.ts` は有効な機能の一覧で、機能ごとに import 1 つとリスト要素 1 つを持つ。
フックはこの配列の順に適用される。

```typescript
import { ciba } from './ciba/feature.js';
```

```typescript
  ciba,
```

#### `endpoints/token/endpoint.ts` に入る行

`endpoints/token/endpoint.ts` は、トークンエンドポイントのステップの並びと矢印を記述するファイルで、`maronn-oidc graph` の図と `--flow` の検証はこの記述から作る。
`steps` には `ciba` のステップの行が入る。
`ciba` を無効にして生成すると、CLI はこれらの行を削除し、出力の `endpoint.ts` には出力にあるステップだけが残る。

```typescript
    'dispatch-ciba',
```

#### `endpoints/token/pipeline.ts` の `(feature: ciba)` ブロック

トークンエンドポイントのパイプラインの先頭に、ブロックが呼ぶステップの import が加わる。

```typescript
import { redeemCibaRequest } from '../../features/ciba/steps/dispatch-ciba.js';
```

ブロックは `authenticate-client` ステップ（クライアント認証）の直後、`validate-grant-type` ステップの直前で実行される。
ステップは `grant_type` が CIBA grant でなければ `undefined` を返し、パイプラインはそのまま標準の grant の検証へ進む。
CIBA grant なら、ステップが返す `Response` でパイプラインはそこで応答を返す。
ほかの機能を併せて有効にすると、その機能の dispatch ブロック（id-jag、token-exchange、device-authorization-grant）も同じ区間に並び、順は取り出し元の `apps/hono` のパイプラインと同じになる。

```typescript
    // [dispatch-ciba] (feature: ciba) Redeem an auth_req_id (CIBA) — CIBA Core 1.0 §10.1 / §11
    const cibaGrantResponse = await redeemCibaRequest(c, params, tokenClient, authenticatedClientId);
    if (cibaGrantResponse) return cibaGrantResponse;
```

#### `features/ciba/feature.ts`

機能の宣言である。
`routes` の 2 エントリは、`app.ts` が基盤のルートと同じ方法でマウントする。
`/backchannel_authentication` は consumption device がバックチャネルで呼ぶ API なので、`/token` と同じ保護 CORS（`corsOrigins` の origin）を付ける。
`/ciba` はブラウザが遷移する画面なので CORS を付けず、`GET /ciba`、`POST /ciba/login`、`POST /ciba/approve` 以外のメソッドは `app.ts` のメソッド制約が 405 で返す。

`discovery` は CIBA Core §4 の REQUIRED 2 項目を広告する。
配信モードは実装している poll だけを並べ、OPTIONAL 項目（署名 alg と user_code の対応）は対応していないので出さない。
`token.grants` の URN は discovery の `grant_types_supported` に加わる。

`context` は関数で、2 つのストアと `cibaUserResolver` をリクエストのコンテキストに置く。
`cibaUserResolver` はオプションで渡されたものを優先し、無ければヒントをユーザーストアの `getClaims()` に渡す既定を使う。
この OP のパスワードフォームはユーザー名として sub を照合するので、既定ではヒントはログインに使うユーザー名と同じ値になる。
値を取り出さない `import './config.js'` は、`OidcProviderOptions` を拡張するそのファイルを feature.ts の依存に含め、設定値の範囲検査も feature.ts の読み込み時に走らせる。

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

機能の設定値 `cibaConfig` と、`OidcProviderOptions` への `cibaUserResolver` の追加、`RegisteredClient` への `backchannelTokenDeliveryMode` の追加である。
`authReqIdExpiresIn`、`pollingInterval`、`maxPendingPerSubject` はバックチャネル認証エンドポイントの `create-request` ステップが experimental パッケージに渡し、`maxLoginAttempts` は認証デバイス画面の `submit-login` ステップが読む。
トークンエンドポイントの dispatch-ciba ステップはこのオブジェクトを読まず、レコードに記録された間隔を `processCibaGrant()` が使う。
値は export されたオブジェクトのプロパティなので、このファイルを編集するか、ホストアプリが起動時にプロパティへ代入して変える。

文書化した範囲を外れる値は、モジュールの読み込み時に例外になる。
設定の書き損じは、承認画面への flood を抑える上限か、ポーリングの契約のどちらかを弱めるからである。
`declare module '../../app.js'` は、`createApp()` と `applyOidc()` のオプションに `cibaUserResolver` を加える。
`login_hint` の意味（メールアドレス、電話番号、ユーザー名）はユーザーストアの設計に依存するので、解決を丸ごと差し替えられるようにしている。
`declare module '../../config.js'` は、クライアントの登録の型 `RegisteredClient` に CIBA §4 のクライアントメタデータ `backchannel_token_delivery_mode` を加える。
この OP は poll しか提供しないので、ping または push で登録したクライアントのバックチャネル認証リクエストは、`create-request` ステップで experimental パッケージが `unauthorized_client` で拒否する。
項目は機能のディレクトリから加えるので、ciba を外して生成すると型からも消える。

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

認証リクエストレコードとログイントランザクションの 2 ストアである。
インメモリ実装は experimental パッケージのファクトリ（`createInMemoryCibaAuthenticationRequestStore()` と `createInMemoryCibaLoginTransactionStore()`）が持つので、このファイルはファクトリを呼んだ結果を保持するだけになる。
ストアは基盤の `store.ts` ではなく機能のディレクトリに置かれるので、機能を無効にすればディレクトリごと消え、基盤のコードが機能を import することもない。

インスタンスは `globalThis` に保持し、開発時のホットリロードやモジュール層の分離でモジュールが複数回読み込まれても、全員が同じストアを使う。
`--db` の指定はこのストアに及ばず、`--db sql` で生成したサンプルにも同じファイルが入る。
インスタンス間でメモリを共有しないランタイムでは、レコードもインスタンスごとに分かれるので、本番ではコメントのとおり永続ストア（Redis、KV、データベース）に置き換える。

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

認証デバイス画面のログインフォームを、フォームを受け取ったブラウザに結び付ける Cookie のヘルパーである。
`/ciba/login` のログイン成功は OP セッションを作り、その効果は CIBA の外（SSO や `prompt=none`）にも及ぶ。
フォームに埋め込んだ `csrf_token` だけではログイン CSRF を止められない。
攻撃者が自分で `GET /ciba` を開けば、有効な `login_transaction_id` と `csrf_token` の対を入手して偽造フォームに埋め込めるからである。

ログインフォームの応答は、bindingSecret の生値をそのブラウザだけに HttpOnly Cookie で渡し、トランザクションには SHA-256 ハッシュだけを保存する。
偽造 POST は被害者の Cookie を運べず（SameSite=Lax）、被害者はこのトランザクションの Cookie をそもそも持たない。
Cookie 名にトランザクション ID を埋め込むのは、同じブラウザで 2 枚のログインフォームを並行させても互いの secret を上書きしないためで、ログインに成功すると消去用の Cookie で消す。

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

認証デバイス画面の 3 つのビュー（ログイン、保留リクエストの一覧と承認、完了）を hono/jsx で書いたものである。
`declare module '../../views.js'` で基盤の `Views` インターフェイスに任意メンバーとして加わるので、`createApp()` や `applyOidc()` の `views` オプションでログイン画面や同意画面と同じように差し替えられる。
`cibaViews(c)` は、アプリが差し替えたビューがあればそれを、無ければこのファイルの既定を返す。

一覧の画面は `binding_message` を表示して、consumption device の表示と見比べさせる（CIBA Core §7.1）。
`binding_message` はクライアントが送るテキストだが、JSX は `{...}` で埋め込む値をすべてエスケープする。
拒否ボタンは承認ボタンと同じ見た目で置き、自分で始めたリクエストだけを承認するよう画面で求める。

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

バックチャネル認証エンドポイント `POST /backchannel_authentication` のパイプラインである。
各ブロックがステップを 1 つ呼び、ステップの 1 つが例外を投げると `respondBackchannelAuthenticationError()` が OAuth のエラー応答にする。
各ブロックは `maronn-oidc graph --detail steps --endpoint backchannel-authentication` の図の箱 1 つに対応する。

ファイル冒頭のコメントは、`login_hint` が利用者の識別子（個人情報）なので、ログにも `error_description` にも出さないこと（CIBA §15）を記録している。
エンドポイント全体のレート制限はデプロイ層に委ねる。
インスタンス間でメモリを共有しないランタイムではプロセス内のカウンタが働かないからで、アプリ内の防御は必須のクライアント認証、`unknown_user_id` の固定文言、subject ごとの保留数の上限である。

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

`maronn-oidc graph` がこのエンドポイントを描くためのメタデータである。
ステップの並び、エラー時のステップ、図の上でこのエンドポイントから認証デバイス画面（ユーザーの承認）とトークンエンドポイント（auth_req_id のポーリング）へ向かう矢印を宣言する。
`rearrangeable: true` は、`--flow` でステップを並べ替えてよいことを表す。

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

エンドポイントの応答の型と、形の決まった失敗（不正な形式のリクエスト）を表す `BackchannelAuthenticationEndpointError`、`Cache-Control: no-store` を付ける `noStore()` である。
auth_req_id は資格情報なので、応答は RFC 6749 §5.1 と §5.2 のトークン応答と同じ扱いにする。

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

リクエストのフォーム本体と `Authorization` ヘッダを読むステップである。
本体は `application/x-www-form-urlencoded` でなければならない（CIBA §7.1）。
生の本体を `URLSearchParams` で走査するのは、重複したパラメータ（RFC 6749 §3.1 が禁じる）を後勝ちで黙って受け入れず、`invalid_request` で拒否するためである。

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

クライアント認証のステップである。
CIBA §7.1 はクライアントに登録済みの方式での認証を求めるので、トークンエンドポイントと同じ core の 4 関数を同じ順に呼ぶ。
public クライアントの拒否は、このあと experimental パッケージのクライアント検証が行う。
認証の失敗は core の `TokenError`（401）として投げられ、`respond-error` ステップが `WWW-Authenticate` を付けて返す。

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

要求された scope を OP の宣言とクライアントの登録に照らすステップである。
OP が宣言していない scope は、`/authorize` と同じ許可リスト（`scopes.ts`）で `invalid_scope` にする（RFC 6749 §3.3）。
このステップはリクエスト作成の前にあるので、未知の scope を求めるリクエストはストアに届かない。
`offline_access` はこの検査から外す。
付与できない `offline_access` は無視されるべき値で（OIDC Core 1.0 §11）、後のステップのポリシーがそれを黙って落とす。
ここで検査に含めると、無視されるはずの値が `invalid_scope` になってしまう。
scope リストを登録したクライアントは、その scope しか要求できない（RFC 7591 §2）。

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

`login_hint` を解決し、保留状態の認証リクエストを作るステップである。
検証は experimental パッケージの `processBackchannelAuthenticationRequest()` の中で CIBA §7.1 の順に進む。
クライアントの検証（public クライアント、grant の登録、配信モード）、`request` パラメータの拒否、ヒントがちょうど 1 つという規則、scope、`binding_message`、`requested_expiry`、`login_hint` の解決、subject ごとの保留数の上限、レコードの作成の順である。

ステップが渡すのは、`config.ts` の `cibaConfig`、context の `cibaUserResolver` とストア、refresh token を発行できるかどうかである。
refresh token の可否は、refresh-token 機能を import せず、有効な機能のフックから `tokenGrantsOf(features).includes('refresh_token')` で読む。
機能のディレクトリが別の機能を import してよいのは、`packages/cli/src/registry.ts` の `requires` に書いた場合だけだからである。
配信モードは、クライアントの登録（`features/ciba/config.ts` が `RegisteredClient` に加えた `backchannelTokenDeliveryMode`）のまま `CibaClientInfo` として渡る。
未設定のクライアントは、experimental パッケージの既定どおり poll として扱われる。

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

認証リクエストの受理応答（CIBA §7.3 の `auth_req_id`、`expires_in`、`interval`）を返すステップである。
auth_req_id は資格情報なので `noStore()` を付ける。

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

どのステップの失敗も CIBA §13 と RFC 6749 §5.2 の形のエラー応答にするステップである。
失敗は 3 種類ある。
形式の誤りは `BackchannelAuthenticationEndpointError` で、決まった応答をそのまま返す。
クライアント認証の失敗は core の `TokenError` で、401 と `WWW-Authenticate` を返す。
experimental パッケージが拒否したものは `BackchannelAuthenticationError` で、そのエラーコードと状態コードを返す。
それ以外の例外は 500 の `server_error` になり、どの応答にも `no-store` が付く。

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

認証デバイス画面 `/ciba` の 3 ルートを持つ画面ルーティング層で、ルート自体は論理を持たない。
`GET /ciba` は `prepareCibaDevice()` の outcome を、2 つの POST はフォームの値をステップに渡して返ってきた outcome を、`respond()` が画面に変える。
セッション切れは 401、`approve` でも `deny` でもない `decision` は 400、試行回数の超過は 429 のエラー画面になる。
`renderView()` は自分で `Response` を作るので、outcome が運ぶ Cookie は `withCookies()` が組み立て済みの `Response` に後から付ける。
画面を変えたいときは、このファイルか `../../views.tsx` を編集すれば、ステップには手を入れずに済む。

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

認証デバイス画面を `maronn-oidc graph` が描くためのメタデータである。
3 ステップは連鎖ではなく、OP セッションの有無による分岐（一覧の準備からログインへ、または直接承認へ）として描かれる。
画面の遷移順がステップの順を決めるので、`rearrangeable: false` で並べ替えを許さない。

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

認証デバイス画面のステップが返す outcome の型と、ステップが共有する関数である。
ステップは `Response` を作らず、次に出す画面と付ける Cookie を outcome として返し、`page.tsx` がそれを HTTP にする。

冒頭のコメントは、2 つの判断を記録している。
ログインフォームはバインディング Cookie を要求する。
ログイン CSRF を止めるのはトランザクションのバインディングだからである。
承認と拒否はバインディング Cookie を使わない。
承認は認証済みの OP セッションに結び付いており、レコードの subject がセッションの subject と一致しなければならず、レコードごとの `csrf_token` もセッション必須の一覧にしか出ないので、auth_req_id を知っていても偽造できるステップが無い。

`listPendingRequests()` は、セッションの subject 宛ての保留リクエストを、CSRF トークンを回し直したうえで返す。
experimental パッケージの `listPendingCibaRequests()` が一覧のたびにトークンを作り直し、この一覧がトークンの唯一の出口になる。
画面に出す scope は `scopes.ts` の `resolveGrantableScopes()` で、そのユーザーが実際に付与できるものに絞る。

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

`GET /ciba` のステップである。
OP セッションがあれば、そのユーザー宛ての保留リクエストを一覧にする。
無ければ `createCibaLoginTransaction()` でログイントランザクションを作り、ログインフォームと、その送信に必要なバインディング Cookie を返す。
Cookie の `Max-Age` はトランザクションの残り寿命に合わせる。

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

`POST /ciba/login` でユーザーをこのブラウザにサインインさせるステップである。
`validateCibaLoginSubmission()` がバインディングと CSRF を検証し、不存在、期限切れ、不一致をすべて同じ 403 にする。
資格情報の検査は `c.get('authenticateUser')` を呼ぶ 1 か所で、LDAP や WebAuthn、上流の IdP に差し替えられる。

失敗は `recordCibaLoginFailure()` がトランザクション単位で数え、`maxLoginAttempts` に達するとトランザクションを捨てるので、そのフォームからは再試行できない。
計数はトランザクション単位だけである。
`/ciba` を開き直せば新しいトランザクションを作れるので、パスワード推測の総量に対する上限は `/login` と変わらない。

成功するとトランザクションを消費し、新しく発行した ID で OP セッションを作る。
リクエストが持ち込んだ ID を使わないのは、セッション固定攻撃を防ぐためである。
一覧の画面には、新しいセッション Cookie と、消去したバインディング Cookie の 2 つが付く。

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

`POST /ciba/approve` で承認か拒否を記録するステップである。
認証デバイス画面で状態を変える唯一のステップで、レコードの subject と一致する OP セッションと、セッション必須の一覧から得たレコードごとの `csrf_token` を要求する。
`decision` は `approve` か `deny` のどちらかでなければならない。

承認では `approveCibaRequest()` が subject と CSRF トークンを検証し、レコードを承認済みにする。
grantId はこのステップで発行して渡すので、既存の失効の仕組みが grant 単位の失効をそのまま適用できる。
そのあと `resolveGrantableScopes()` で承認した scope を絞り込んで保存し直す。
トークンエンドポイントは `approvedScope` を読み、RFC 6749 §3.3 は要求より狭い scope の付与を認めている。
同意と grant は `/consent` と同じ形で記録するので、同じクライアントの後の認可コードフローは同意画面を省ける（OIDC Core 1.0 §3.1.2.4）。
拒否では、完了画面に出すクライアントを先にレコードから読み、`denyCibaRequest()` で拒否する。

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

トークンエンドポイントの dispatch-ciba ブロックが呼ぶステップである。
`meta` の `before: ['validate-grant-type']` は、`--flow` で並べ替えても `grant_type` の検証より前に置かれ続けることを宣言する。
`grant_type` が CIBA grant でなければ何もせず `undefined` を返す。

`processCibaGrant()` は CIBA §11 の状態機械で、承認済み以外の状態（`authorization_pending`、`slow_down`、`access_denied`、`expired_token`）と `invalid_request`、`invalid_grant` は例外になる。
例外の `CibaGrantError` はステップの末尾で基盤の `TokenEndpointError` に包み直され、基盤の `respond-error` ステップがそのまま返す。

承認済みならトークンを発行する。
組み立てには、基盤の `issue-access-token` から `persist-access-token` までと同じ core の関数を使うが、パイプラインの後段には合流せず、このステップの中で `respondToken()` まで進む。
ステップ内の `cibaConfig` は `c.get('config')` で読んだ OP 全体の設定で、`features/ciba/config.ts` の `cibaConfig` とは別物である。
アクセストークンは登録鍵セットの先頭の鍵で署名する。
ID Token の鍵は、標準の grant と同じ規則で、クライアント登録の `id_token_signed_response_alg` に合う鍵を選ぶ。
先頭の鍵を使うと、ES256 を登録したクライアントに RS256 の ID Token を渡し、at_hash も誤ったアルゴリズムで計算することになるからである。
合う鍵が無ければ 500 の `server_error` になる。

バックチャネル認証エンドポイントが `openid` を必須にしているので、ID Token は必ず発行される。
CIBA §7.1 に nonce パラメータは無く、認可コードも無いので、ID Token に nonce と c_hash は載らない。
poll モードには CIBA 固有のクレームも無い（§10.3.1 の `auth_req_id` クレームは push モードの配信メッセージのものである）。
アクセストークンのレコードは承認時の grantId を引き継ぎ、grant を失効させればこのバックチャネル認証から出たトークンもまとめて失効する。
refresh token は scope に `offline_access` が残っているときだけ発行し、ユーザーが通った承認画面が §11 の求める明示的な同意になる。

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

### 他フレームワークの生成コード

express と fastify の出力は、上と同じファイルを持つ。
生成器はエンドポイントの `hono` の import を `web-router.ts` の `WebRouter` / `WebContext`（Fetch API の上の小さなルーター）に差し替え、各フレームワーク用の `apply.ts` と、`web-router.ts`、`node-adapter.ts` を加える。
差し替えの対象と加えるファイルは [packages/cli/extract.json](../../../packages/cli/extract.json) が定め、ルーターとアダプタの実体は [apps/hono/src/web/](../../../apps/hono/src/web/) にある。
認証デバイス画面は hono/jsx のまま残るので、これらの出力も JSX ランタイムとして `hono` を必要とする。

Next.js の出力は、Next.js App Router のアプリ [apps/nextjs](../../../apps/nextjs) から取り出される。
この機能のルートファイルはルートグループ `app/(ciba)/` に、コードは `app/_oidc-provider/features/ciba/` に置かれる。

### サンプルと E2E 環境の配線

4 つのサンプル（hono-cloudflare、express-flyio、fastify-flyio、nextjs-vercel）は、`package.json` の `generate` スクリプトに `--enable ciba` を持つ。
hono、express、fastify のサンプルの `src/app.ts` に CIBA 固有の配線は無い。
`cibaUserResolver` を渡していないので、`login_hint` はユーザーストアのユーザー名として解決される。
E2E のクライアントアプリは既定で `login_hint=testuser` を送り、サンプルが登録する開発用ユーザー（`development.ts` の testuser と otheruser）がこれを受ける。

E2E のクライアントは、[tests/e2e/playwright.config.ts](../../../tests/e2e/playwright.config.ts) が環境変数 `OIDC_CLIENTS_JSON` でサンプルに渡す。
`e2e-client` の `grantTypes` には CIBA の URN があり、別クライアントによる auth_req_id の引き換えが拒否されることを確かめるために `e2e-ciba-other` がある。
登録 scope の検証用の `e2e-scope-limited` も CIBA の URN を持つ。
サンプルはこの一覧を起動時に `db/` のクライアント表へ登録し、開発用ユーザーも同じ方法で登録する。
[samples/express-flyio/src/app.ts](../../../samples/express-flyio/src/app.ts) の該当部分は次のとおりで、[samples/fastify-flyio/src/app.ts](../../../samples/fastify-flyio/src/app.ts) も同じである。

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

[samples/hono-cloudflare/src/app.ts](../../../samples/hono-cloudflare/src/app.ts) は、Workers が D1 にリクエストの処理中しか触れられないので、isolate の最初のリクエストで同じ登録を行う。

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

consumption device の役は E2E のクライアントアプリ [tests/e2e/apps/client.mjs](../../../tests/e2e/apps/client.mjs) が担う。
`/start-ciba` がバックチャネル認証を依頼してバックグラウンドのポーリング（`slow_down` のあとの +5 秒を含む）を始め、`/ciba-result` がポーリングの到達状態を返す。
クライアントアプリの該当部分は次のとおりである。

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

ポーリングのループは、応答本体が JSON として読めない回を `readJsonBody()` で読み飛ばし、ループ自体の予期しない失敗は `failFlowOnError()` でフローに記録する。
どちらもデバイスフローのポーリングと共有する、同じファイルの補助関数である。

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
