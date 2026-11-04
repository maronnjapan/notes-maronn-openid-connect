# Rich Authorization Requests（RFC 9396）実装解説

この文書は、`@maronn-openid-connect/experimental` の `rar` 機能（OAuth 2.0 Rich Authorization Requests、RFC 9396）の実装解説である。
機能の目的とユースケース、`packages/experimental/src/rar/` の全ファイル、CLI の `--enable rar` が生成コードへ注入するコード、E2E スペックを全文で載せ、設計判断を説明する。

対象コードは PR [maronnjapan/maronn-openid-connect#179](https://github.com/maronnjapan/maronn-openid-connect/pull/179) で実装したものである。
仕様策定とレビューの経緯は、この notes リポジトリの `tasks/experimental/done/rar/` にある。

## 機能の概要

`scope` は空白区切りの文字列の集合で、認可の粒度が「API 全体」や「操作の種類」で止まる。
「口座 X から 123.50 ユーロを 1 回だけ送金する」のような要求を scope で表すには、値の中に構造を埋め込む独自規約を発明するしかなく、相互運用できない。

**Rich Authorization Requests（RAR）** は、この構造を `authorization_details` という JSON 配列パラメータとして標準化した仕様である。
各要素は `type` フィールドで意味を宣言するオブジェクトで、金額、口座、操作のような型固有フィールドを持てる。

`--enable rar` で生成した OP は、認可コードフローで次を行う。

1. 認可リクエストの `authorization_details` を検証する（構造の検査と、設定に登録した**型定義**による型固有の検証）
2. 同意画面に、要求された details の表示行を scope と併記する（RFC 9396 §3.1）
3. 承認された details をグラントへ紐付ける
4. トークンレスポンス（refresh を含む。§7）と introspection の応答（§9.2）に `authorization_details` を含める
5. discovery に `authorization_details_types_supported` を公表する（§10）

`authorization_details` の無いリクエストは、機能の有効・無効にかかわらず従来とまったく同じに処理される。

### ユースケース

- 送金額や口座を特定した認可（`payment_initiation` 型など）を試す金融系 PoC
- `scope` の荒い粒度を細分化したい API 提供者が、型定義の設計（必須フィールド、同意文言）を検証する用途
- FAPI 2.0 の推奨構成（PAR + RAR）の組み合わせ検証。PAR のパラメータ検証は未知パラメータを保持するので、`/par` へ送った `authorization_details` もそのまま受理される

### 実装スコープと非目標

RFC 9396 のうち、次は実装していない。

- **トークンリクエストでの再指定（§6 の narrowing）**：受理しない。パラメータが来たら `invalid_authorization_details` で明示拒否する。黙って無視すると「絞り込まれた」とクライアントに誤認させるためである
- **enriched authorization details（§7.1）**：AS 側で details を拡充せず、承認された内容をそのまま返す
- **JWT アクセストークンへの claim（§9.1、RECOMMENDED）**：資源サーバーへの伝達は introspection だけで行う。アクセストークン発行は base のステップで、そこへ踏み込む変更は昇格時に検討する
- **認可コードフロー以外への適用**：device authorization grant と CIBA のエンドポイントは、従来どおりパラメータを無視する
- **部分同意（§3 Note の MAY）**：同意は要求された details 全体への承認か拒否かの二択とする
- **クライアントメタデータ `authorization_details_types`（§10）**：クライアント単位の型制限は行わない

## 実装の設計方針

RFC 9396 は type の意味論を API ごとのプロファイルに委ねており、OP 単体では「正しい実装」が閉じない。
そこで本機能は、型の意味解釈を OP 運用者が注入する**型定義**（`type` ごとの validator と同意表示文の生成関数）に委ね、experimental パッケージは構造検証と配管だけを持つ。
型定義が一つも無い既定の状態では、`authorization_details` 付きのリクエストをすべて `invalid_authorization_details` で拒否する（fail-closed。§5 の「理解しない type を含むリクエストは拒否しなければならない」に、空集合の場合も含めて従う）。

details の保持は、core の型を広げずに **grantId / transactionId をキーにした副ストア**で行う。
core のトランザクション・認可コード・トークン情報の各ビルダーは固定フィールドしか写さないため、details をパラメータの相乗りで「リクエスト → トークン応答」まで運ぶことはできない。
core に `authorizationDetails` フィールドを足すのが本筋だが、それは昇格時の変更であり、experimental の段階では PAR / CIBA と同じ in-memory の割り切りを選んだ。
ストアは承認前（transactionId キー、トランザクションと同じ寿命）と承認後（grantId キー、リフレッシュトークンの絶対寿命）の 2 インスタンスで、同意の確定点で付け替える。
grantId は authorization_code と refresh_token の両グラントを貫通するので、refresh しても同じ details が引ける。

同意の迂回は **prompt 制御**で塞ぐ。
過去の同意の記録（`consentResolver.hasConsent`）は subject / client / scope しか受けず、details の中身を知らない。
そのまま SSO の同意スキップに乗せると、エンドユーザーが見ていない金額や口座がグラントに紐づいてしまう。
そこで details があるリクエストでは、`prompt=none` 単独なら `consent_required` で拒否し、それ以外なら `prompt` に `consent` を加えて、silent（`prompt=none` 処理）と SSO（セッション再利用）の両経路を同意画面へ向ける。
`prompt=consent` の意味は OIDC Core 1.0 §3.1.2.1 の「consent を求め直す」にそのまま乗る。
`none` が他の値と組む不正なリクエストには手を出さず、base の検査が従来どおり `invalid_request` で拒否する。

トークンリクエストの `authorization_details` の拒否は、**どの副作用よりも前のステップ**で行う。
token パイプラインは dispatch 群 → グラント検証 → トークン発行・保存 → 提示リフレッシュトークンのローテーション失効 → 応答組み立ての順に進むので、応答組み立て時に拒否すると、拒否したリクエストの副作用（保存済みトークン、失効済みリフレッシュトークン）が残る。
拒否ステップは feature grant の dispatch 群の直後・grant_type 検証の前に置き、id-jag / token-exchange など他機能が応答するグラントでは各機能の既存拒否が先に効く順序を保った。

エラーは、認可エンドポイントでは `AuthorizationError`、トークンエンドポイントでは `TokenEndpointError` という既存の器で返す。
`invalid_authorization_details` は core のエラーコード enum に無いが、enum は string-valued であり、PAR が enum 外コードをキャストで投げる先例に倣った（core 無変更の原則）。
`error_description` は固定の ASCII 文言とし、details の内容（金額、口座、type 名）を反映しない（§13）。どの要素が拒否されたかはクライアント側で送った値から再現できるので、反映による情報価値よりログやリファラ経由の漏えい面を減らす方を取った。

## 実装コードの全文と解説

`packages/experimental/src/rar/` は次の 5 ファイルで、公開 API は subpath `@maronn-openid-connect/experimental/rar` から import する。
すべて Web 標準 API（TextEncoder、JSON）だけを使う純関数とプレーンな in-memory ストアである。

### authorization-details.ts（構造検証と型定義の突き合わせ）

検証の入口 `parseAuthorizationDetailsInput()` が `unknown` を受けるのは、届く形が経路で違うためである。
クエリと PAR 経由では URL エンコードされた文字列、Request Object 経由では JWT ペイロードを JSON デコードした時点でパース済みの配列になっている。
文字列は生文字列のバイト長を検査してからパースし、パース済みの値は `JSON.stringify` した文字列でバイト長を測って、どちらの経路でも同じ上限が効くようにした。
バイト長の検査をパースより前に置くのは、巨大な JSON のパース自体を入口で止めるためである（DoS 対策。§11.4 は長大なリクエストに PAR を示唆している）。

details オブジェクトは不透明な JSON 値として保持・転記だけを行い、他のオブジェクトへの深いマージや動的キーアクセスによる書き込みをしない。
`__proto__` キーを持つ入力も、`JSON.parse` が作る own property のまま運ばれ、プロトタイプへ届かない（§12 の sanitize 要求への答えで、単体テストで検証している）。

```typescript
/**
 * Rich Authorization Requests (RAR) — RFC 9396
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * `authorization_details` パラメータの構造検証と、OP 運用者が注入する型定義
 * （type ごとの validator と同意表示文の生成関数）との突き合わせ。
 * ここにあるのは純関数だけで、HTTP やストアには触れない。
 */

/** RFC 9396 §3: 認可リクエストのパラメータ名。 */
export const AUTHORIZATION_DETAILS_PARAM = 'authorization_details';

/**
 * RFC 9396 §2 の authorization details オブジェクト。
 *
 * `type` だけが必須で（§2）、共通フィールド（§2.2）はすべて任意である。
 * 型固有フィールドはインデックスシグネチャで不透明に保持し、解釈は型定義へ委ねる。
 */
export interface AuthorizationDetail {
  readonly type: string;
  readonly locations?: readonly string[];
  readonly actions?: readonly string[];
  readonly datatypes?: readonly string[];
  readonly identifier?: string;
  readonly privileges?: readonly string[];
  readonly [key: string]: unknown;
}

/**
 * OP 運用者が type ごとに注入する定義。
 *
 * RFC 9396 §5 は「理解しない type を含むリクエストを拒否しなければならない」とし、
 * 「理解する」の中身を OP に委ねている。この定義を登録した type だけが受理される。
 */
export interface AuthorizationDetailTypeDefinition {
  /** この定義が受け持つ `type` の値。 */
  readonly type: string;
  /**
   * 型固有の検証。違反したら `RarError('invalid_authorization_details')` を投げる。
   * message は固定の ASCII 文言とし、入力値を含めないこと（RFC 9396 §13）。
   */
  validate(detail: AuthorizationDetail): void;
  /**
   * 同意画面に出す表示行。プレーン文字列だけを返し、HTML を組み立てない
   * （エスケープは view 層に委ねる）。金額や宛先など安全上重要なフィールドは
   * すべて文言に含める責任を持つ（RFC 9396 §3.1 / §13）。
   */
  describe(detail: AuthorizationDetail): readonly string[];
}

/** RFC 9396 §5 / §14.6 のエラーコード。authorization / token 両エンドポイントで使う。 */
export type RarErrorCode = 'invalid_authorization_details';

/**
 * `authorization_details` の検証失敗。
 *
 * message は呼び出し側が固定 ASCII 文言で渡す契約で、details の内容
 * （type 名を含む）を反映してはならない（RFC 9396 §13 の機微データ考慮）。
 */
export class RarError extends Error {
  readonly code: RarErrorCode = 'invalid_authorization_details';

  constructor(message: string) {
    super(message);
    this.name = 'RarError';
  }
}

/** `parseAuthorizationDetailsInput` の上限値。DoS 対策（RFC 9396 §11.4 参照）。 */
export interface AuthorizationDetailsLimits {
  /** パラメータの UTF-8 バイト長の上限（TextEncoder 基準）。 */
  readonly maxBytes: number;
  /** 配列の要素数の上限。 */
  readonly maxEntries: number;
}

/** 共通フィールド（RFC 9396 §2.2）のうち、文字列配列でなければならないもの。 */
const STRING_ARRAY_COMMON_FIELDS = ['locations', 'actions', 'datatypes', 'privileges'] as const;

/**
 * `authorization_details` の入力を検証して、パース済みの配列を返す。失敗は `RarError` で投げる。
 *
 * クエリ / PAR 経由の文字列と、Request Object 経由のパース済み JSON 値の両方を受ける。
 * - 文字列: 生文字列の UTF-8 バイト長を検査してから `JSON.parse` する。
 * - それ以外: `JSON.stringify` した文字列でバイト長を測り、配列であることを検査する
 *   （stringify できない値、文字列でも配列でもない値は拒否する）。
 *
 * 検査は、バイト長 → 配列であること → 空でなく要素数が上限以下 → 各要素が
 * プレーンなオブジェクト → `type` が非空文字列（§2 REQUIRED）→ 共通フィールドの型
 * （§2.2）の順に行う。型定義との突き合わせ（§5）は `validateAuthorizationDetails()` が行う。
 *
 * @spec RFC 9396 §2
 * @spec RFC 9396 §2.2
 * @spec RFC 9396 §3
 * @throws {RarError} 入力がどれかの検査に違反したとき。message は固定 ASCII 文言で、入力値を含まない。
 */
export function parseAuthorizationDetailsInput(
  input: unknown,
  limits: AuthorizationDetailsLimits,
): AuthorizationDetail[] {
  const parsed = typeof input === 'string'
    ? parseFromString(input, limits)
    : measureParsedInput(input, limits);
  if (!Array.isArray(parsed)) {
    throw new RarError('authorization_details must be a JSON array');
  }
  if (parsed.length === 0) {
    throw new RarError('authorization_details must not be empty');
  }
  if (parsed.length > limits.maxEntries) {
    throw new RarError('authorization_details has too many entries');
  }
  for (const entry of parsed) {
    assertAuthorizationDetailShape(entry);
  }
  return parsed as AuthorizationDetail[];
}

/**
 * 文字列の入力をバイト長検査のうえ JSON としてパースして返す。失敗は `RarError` で投げる。
 *
 * バイト長は生文字列の UTF-8 表現（TextEncoder 基準）で測る。
 *
 * @spec RFC 9396 §3
 * @throws {RarError} バイト長が上限を超えるか、JSON としてパースできないとき。
 */
function parseFromString(input: string, limits: AuthorizationDetailsLimits): unknown {
  if (new TextEncoder().encode(input).length > limits.maxBytes) {
    throw new RarError('authorization_details is too large');
  }
  try {
    return JSON.parse(input);
  } catch {
    throw new RarError('authorization_details must be valid JSON');
  }
}

/**
 * パース済みの入力（Request Object 経由）のバイト長を JSON 表現で測り、そのまま返す。失敗は `RarError` で投げる。
 *
 * `JSON.stringify` できない値（undefined、関数、循環参照を含む値）は拒否する。
 *
 * @spec RFC 9396 §3
 * @throws {RarError} JSON にできない値か、バイト長が上限を超えるとき。
 */
function measureParsedInput(input: unknown, limits: AuthorizationDetailsLimits): unknown {
  let serialized: string | undefined;
  try {
    serialized = JSON.stringify(input);
  } catch {
    throw new RarError('authorization_details must be a JSON value');
  }
  if (typeof serialized !== 'string') {
    throw new RarError('authorization_details must be a JSON value');
  }
  if (new TextEncoder().encode(serialized).length > limits.maxBytes) {
    throw new RarError('authorization_details is too large');
  }
  return input;
}

/**
 * 配列の 1 要素が authorization details オブジェクトの形であることを確かめる。違反は `RarError` で投げる。
 *
 * プレーンなオブジェクトであること、`type` が非空文字列であること（§2 REQUIRED）、
 * 共通フィールドが存在するなら §2.2 の型（`locations` / `actions` / `datatypes` /
 * `privileges` は文字列配列、`identifier` は文字列）であることを検査する。
 * 同じ `type` の要素が複数あってもよい（§2 MAY）。
 *
 * @spec RFC 9396 §2
 * @spec RFC 9396 §2.2
 * @throws {RarError} 要素がオブジェクトでない、`type` が欠落・空・非文字列、共通フィールドの型が違うとき。
 */
function assertAuthorizationDetailShape(entry: unknown): asserts entry is AuthorizationDetail {
  if (typeof entry !== 'object' || entry === null || Array.isArray(entry)) {
    throw new RarError('authorization_details entries must be JSON objects');
  }
  const detail = entry as Record<string, unknown>;
  if (typeof detail['type'] !== 'string' || detail['type'].length === 0) {
    throw new RarError('authorization_details entries must have a non-empty type');
  }
  for (const field of STRING_ARRAY_COMMON_FIELDS) {
    const value = detail[field];
    if (value === undefined) continue;
    if (!Array.isArray(value) || value.some((item) => typeof item !== 'string')) {
      throw new RarError('authorization_details common fields must have the RFC 9396 types');
    }
  }
  if (detail['identifier'] !== undefined && typeof detail['identifier'] !== 'string') {
    throw new RarError('authorization_details common fields must have the RFC 9396 types');
  }
}

/**
 * すべての要素を登録済みの型定義と突き合わせ、未知の type と型固有の違反を `RarError` で拒否する。
 *
 * 型定義が一つも無ければ、どの要素も未知 type として拒否される（fail-closed。§5 の
 * MUST refuse）。型定義の `validate` が投げた `RarError` はそのまま伝え、それ以外の
 * 例外は握りつぶさずそのまま伝える（呼び出し側が `server_error` として扱う）。
 *
 * @spec RFC 9396 §5
 * @throws {RarError} 要素の `type` に対応する型定義が無いか、型定義の `validate` が違反を見つけたとき。
 */
export function validateAuthorizationDetails(
  details: readonly AuthorizationDetail[],
  types: readonly AuthorizationDetailTypeDefinition[],
): void {
  for (const detail of details) {
    const definition = types.find((candidate) => candidate.type === detail.type);
    if (definition === undefined) {
      throw new RarError('authorization_details contains an unsupported type');
    }
    definition.validate(detail);
  }
}

/**
 * 同意画面向けの表示行を、要素の順に型定義の `describe` で組み立てて返す。
 *
 * 対応する型定義が無い要素があれば `RarError` を投げる（表示できない要素を黙って
 * 落とすと、エンドユーザーが見ていない権限が承認されてしまうため）。
 * 返す値はプレーン文字列の配列で、エスケープは呼び出し側の view 層に委ねる。
 *
 * @spec RFC 9396 §3.1
 * @throws {RarError} 要素の `type` に対応する型定義が無いとき。
 */
export function describeAuthorizationDetails(
  details: readonly AuthorizationDetail[],
  types: readonly AuthorizationDetailTypeDefinition[],
): readonly string[] {
  const lines: string[] = [];
  for (const detail of details) {
    const definition = types.find((candidate) => candidate.type === detail.type);
    if (definition === undefined) {
      throw new RarError('authorization_details contains an unsupported type');
    }
    lines.push(...definition.describe(detail));
  }
  return lines;
}
```

`describeAuthorizationDetails()` が未知の type に例外を投げるのは、承認段階の fail-closed である。
検証を通ってから運用者が型定義を外した場合、その要素の文言を作れない。
黙って行を落とすと、エンドユーザーが見ていない権限が「表示された分だけ承認した」ことになってしまうので、画面の描画ごと失敗させる。

### store.ts（details の保持）

ストア契約は `set` / `get` / `delete` の 3 メソッドだけで、`expiresAt`（エポックミリ秒）を過ぎたエントリを返さないことを実装へ求める。
in-memory 実装は `set` のたびに失効エントリを掃除する（書き込み時の lazy eviction）。
タイマーを持たないのは、CIBA のストアと同じ判断で、プロセスに常駐の後始末を仕込まずに、放置されたストアが際限なく大きくなるのを防ぐためである。

```typescript
/**
 * Rich Authorization Requests (RAR) — RFC 9396
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * 承認前（transactionId キー）と承認後（grantId キー）の authorization details を
 * 保持するストア契約と、動作確認用の in-memory 実装。
 */

import type { AuthorizationDetail } from './authorization-details.js';

/**
 * 利用者が実装するストア契約。
 *
 * キーは transactionId か grantId で、どちらも外部へ出ない不透明な識別子である。
 * 永続ストア実装では、キーをクエリ文字列へ埋め込まず、必ずパラメータ化した
 * 問い合わせを使うこと。`expiresAt`（UNIX エポックミリ秒）を渡されたら、その時刻を
 * 過ぎたエントリを返してはならない。
 */
export interface RarDetailsStore {
  /** details をキーに紐付けて保存する。`expiresAt` はエポックミリ秒の失効時刻。 */
  set(key: string, details: readonly AuthorizationDetail[], expiresAt?: number): Promise<void>;
  /** キーに紐づく details を返す。無いか失効していれば `undefined` を返す。 */
  get(key: string): Promise<readonly AuthorizationDetail[] | undefined>;
  /** キーに紐づく details を削除する。 */
  delete(key: string): Promise<void>;
}

/**
 * details をメモリに置くストアを作って返す。
 *
 * 動作確認のためのもので、本番では永続的なストア（Redis、KV、データベースなど）に
 * 置き換える。`set` を呼ぶたびに失効したエントリを削除する（書き込み時の lazy
 * eviction）ので、放置されたストアが際限なく大きくならない。`get` は失効した
 * エントリを削除してから `undefined` を返す。
 */
export function createInMemoryRarDetailsStore(): RarDetailsStore {
  const records = new Map<string, { details: readonly AuthorizationDetail[]; expiresAt?: number }>();
  const evictExpired = (): void => {
    const now = Date.now();
    for (const [key, record] of records) {
      if (record.expiresAt !== undefined && record.expiresAt <= now) {
        records.delete(key);
      }
    }
  };
  return {
    async set(key, details, expiresAt): Promise<void> {
      evictExpired();
      records.set(key, { details, expiresAt });
    },
    async get(key): Promise<readonly AuthorizationDetail[] | undefined> {
      const record = records.get(key);
      if (record === undefined) return undefined;
      if (record.expiresAt !== undefined && record.expiresAt <= Date.now()) {
        records.delete(key);
        return undefined;
      }
      return record.details;
    },
    async delete(key): Promise<void> {
      records.delete(key);
    },
  };
}
```

### index.ts（公開 API）

```typescript
/**
 * Rich Authorization Requests (RAR) — RFC 9396
 *
 * **Experimental**: この機能の API は安定していない。マイナーリリースでも
 * 破壊的に変更されることがある。本番運用の前に
 * `docs/library-document` の Experimental セクションを確認すること。
 *
 * `@maronn-openid-connect/core` とは別 package であり、CLI で `--enable rar` を明示した
 * ときのみ生成コードから利用される。
 */
export {
  AUTHORIZATION_DETAILS_PARAM,
  RarError,
  describeAuthorizationDetails,
  parseAuthorizationDetailsInput,
  validateAuthorizationDetails,
  type AuthorizationDetail,
  type AuthorizationDetailTypeDefinition,
  type AuthorizationDetailsLimits,
  type RarErrorCode,
} from './authorization-details.js';

export { createInMemoryRarDetailsStore, type RarDetailsStore } from './store.js';
```

`package.json` の `exports` には `"./rar"` の subpath を足した。ルート `.` からの再エクスポートは、機能単位の独立性を保つ package の方針どおり追加していない。

```json
"./rar": {
  "types": "./dist/rar/index.d.ts",
  "import": "./dist/rar/index.js"
},
```

## 単体テストの全文

テスト入力には RFC 9396 §2.1 Figure 1 の `payment_initiation` の例（EUR 123.50）をそのまま使っている。
境界値（UTF-8 バイト長の on / over、要素数上限）、`__proto__` / `constructor` キーの入力がプロトタイプを汚染しないこと、エラー message に入力値（口座番号を模した文字列）が混ざらないことを固定している。

### authorization-details.test.ts

```typescript
import { describe, expect, it } from 'vitest';
import {
  AUTHORIZATION_DETAILS_PARAM,
  RarError,
  describeAuthorizationDetails,
  parseAuthorizationDetailsInput,
  validateAuthorizationDetails,
  type AuthorizationDetail,
  type AuthorizationDetailTypeDefinition,
} from './authorization-details.js';

const LIMITS = { maxBytes: 16384, maxEntries: 16 };

// RFC 9396 §2.1 Figure 1 の payment_initiation の例をテスト入力に使う。
const PAYMENT_DETAIL = {
  type: 'payment_initiation',
  actions: ['initiate'],
  locations: ['https://example.com/payments'],
  instructedAmount: { currency: 'EUR', amount: '123.50' },
};

// 型固有検証と表示のデモ型定義（RFC 9396 §2.1 の例の形）。
const PAYMENT_TYPE: AuthorizationDetailTypeDefinition = {
  type: 'payment_initiation',
  validate(detail: AuthorizationDetail): void {
    if (!Array.isArray(detail.actions) || detail.actions.length === 0) {
      throw new RarError('payment_initiation requires actions');
    }
  },
  describe(detail: AuthorizationDetail): readonly string[] {
    const amount = detail['instructedAmount'] as { currency: string; amount: string };
    return [`Initiate a payment of ${amount.currency} ${amount.amount}`];
  },
};

describe('AUTHORIZATION_DETAILS_PARAM', () => {
  it('should name the RFC 9396 request parameter', () => {
    expect(AUTHORIZATION_DETAILS_PARAM).toBe('authorization_details');
  });
});

describe('parseAuthorizationDetailsInput', () => {
  describe('string input (query / PAR)', () => {
    it('should parse a single-entry JSON array string', () => {
      const details = parseAuthorizationDetailsInput(JSON.stringify([PAYMENT_DETAIL]), LIMITS);
      expect(details).toEqual([PAYMENT_DETAIL]);
    });

    it('should parse multiple entries and keep duplicated types', () => {
      // RFC 9396 §2: 同じ type の要素が複数あってよい（MAY）。
      const details = parseAuthorizationDetailsInput(
        JSON.stringify([PAYMENT_DETAIL, PAYMENT_DETAIL]),
        LIMITS,
      );
      expect(details).toEqual([PAYMENT_DETAIL, PAYMENT_DETAIL]);
    });

    it('should reject a string that is not valid JSON', () => {
      expect(() => parseAuthorizationDetailsInput('{not json', LIMITS)).toThrow(RarError);
    });

    it('should reject JSON that is not an array', () => {
      expect(() => parseAuthorizationDetailsInput(JSON.stringify(PAYMENT_DETAIL), LIMITS)).toThrow(
        'authorization_details must be a JSON array',
      );
    });

    it('should reject a raw string over maxBytes measured as UTF-8', () => {
      // 多バイト文字（3 バイトの「あ」）で、文字数でなくバイト数が検査されることを確かめる。
      const padding = 'あ'.repeat(40);
      const raw = JSON.stringify([{ ...PAYMENT_DETAIL, note: padding }]);
      const onLimit = new TextEncoder().encode(raw).length;
      expect(() => parseAuthorizationDetailsInput(raw, { maxBytes: onLimit, maxEntries: 16 })).not.toThrow();
      expect(() => parseAuthorizationDetailsInput(raw, { maxBytes: onLimit - 1, maxEntries: 16 })).toThrow(
        'authorization_details is too large',
      );
    });
  });

  describe('parsed JSON input (Request Object)', () => {
    it('should accept an already-parsed array', () => {
      const details = parseAuthorizationDetailsInput([PAYMENT_DETAIL], LIMITS);
      expect(details).toEqual([PAYMENT_DETAIL]);
    });

    it('should reject a parsed value that is neither string nor array', () => {
      expect(() => parseAuthorizationDetailsInput(PAYMENT_DETAIL, LIMITS)).toThrow(
        'authorization_details must be a JSON array',
      );
      expect(() => parseAuthorizationDetailsInput(42, LIMITS)).toThrow(
        'authorization_details must be a JSON array',
      );
    });

    it('should reject undefined input', () => {
      expect(() => parseAuthorizationDetailsInput(undefined, LIMITS)).toThrow(
        'authorization_details must be a JSON value',
      );
    });

    it('should reject a parsed array whose JSON serialization is over maxBytes', () => {
      const value = [{ ...PAYMENT_DETAIL, note: 'x'.repeat(50) }];
      const onLimit = new TextEncoder().encode(JSON.stringify(value)).length;
      expect(() => parseAuthorizationDetailsInput(value, { maxBytes: onLimit, maxEntries: 16 })).not.toThrow();
      expect(() => parseAuthorizationDetailsInput(value, { maxBytes: onLimit - 1, maxEntries: 16 })).toThrow(
        'authorization_details is too large',
      );
    });
  });

  describe('array shape', () => {
    it('should reject an empty array', () => {
      expect(() => parseAuthorizationDetailsInput('[]', LIMITS)).toThrow(
        'authorization_details must not be empty',
      );
    });

    it('should reject more entries than maxEntries', () => {
      const entries = Array.from({ length: 3 }, () => PAYMENT_DETAIL);
      expect(() =>
        parseAuthorizationDetailsInput(JSON.stringify(entries), { maxBytes: 16384, maxEntries: 2 }),
      ).toThrow('authorization_details has too many entries');
    });

    it('should accept exactly maxEntries entries', () => {
      const entries = Array.from({ length: 2 }, () => PAYMENT_DETAIL);
      expect(
        parseAuthorizationDetailsInput(JSON.stringify(entries), { maxBytes: 16384, maxEntries: 2 }),
      ).toEqual(entries);
    });

    it('should reject entries that are not plain objects', () => {
      for (const entry of ['payment_initiation', ['nested'], null, 42]) {
        expect(() => parseAuthorizationDetailsInput(JSON.stringify([entry]), LIMITS)).toThrow(
          'authorization_details entries must be JSON objects',
        );
      }
    });
  });

  describe('type field (RFC 9396 §2 REQUIRED)', () => {
    it('should reject an entry without type', () => {
      expect(() => parseAuthorizationDetailsInput(JSON.stringify([{ actions: ['initiate'] }]), LIMITS)).toThrow(
        'authorization_details entries must have a non-empty type',
      );
    });

    it('should reject an empty-string type', () => {
      expect(() => parseAuthorizationDetailsInput(JSON.stringify([{ type: '' }]), LIMITS)).toThrow(
        'authorization_details entries must have a non-empty type',
      );
    });

    it('should reject a non-string type', () => {
      expect(() => parseAuthorizationDetailsInput(JSON.stringify([{ type: 7 }]), LIMITS)).toThrow(
        'authorization_details entries must have a non-empty type',
      );
    });
  });

  describe('common fields (RFC 9396 §2.2)', () => {
    it('should reject a locations value that is not an array', () => {
      expect(() =>
        parseAuthorizationDetailsInput(JSON.stringify([{ type: 'payment_initiation', locations: 'https://example.com' }]), LIMITS),
      ).toThrow('authorization_details common fields must have the RFC 9396 types');
    });

    it('should reject an identifier value that is not a string', () => {
      expect(() =>
        parseAuthorizationDetailsInput(JSON.stringify([{ type: 'payment_initiation', identifier: ['account-14'] }]), LIMITS),
      ).toThrow('authorization_details common fields must have the RFC 9396 types');
    });

    it('should reject a string-array field holding a non-string item', () => {
      expect(() =>
        parseAuthorizationDetailsInput(JSON.stringify([{ type: 'payment_initiation', actions: ['initiate', 7] }]), LIMITS),
      ).toThrow('authorization_details common fields must have the RFC 9396 types');
    });

    it('should accept all common fields with their RFC 9396 types', () => {
      const entry = {
        type: 'payment_initiation',
        locations: ['https://example.com/payments'],
        actions: ['initiate'],
        datatypes: ['transactions'],
        identifier: 'account-14',
        privileges: ['admin'],
      };
      expect(parseAuthorizationDetailsInput(JSON.stringify([entry]), LIMITS)).toEqual([entry]);
    });
  });

  describe('prototype safety (RFC 9396 §12 sanitize)', () => {
    it('should keep a __proto__ key as an own property without polluting prototypes', () => {
      const raw = '[{"type":"payment_initiation","__proto__":{"polluted":true}}]';
      const [detail] = parseAuthorizationDetailsInput(raw, LIMITS);
      expect(Object.getOwnPropertyNames(detail)).toEqual(['type', '__proto__']);
      expect(({} as Record<string, unknown>)['polluted']).toBe(undefined);
      expect(Object.getPrototypeOf(detail)).toBe(Object.prototype);
    });

    it('should keep a constructor key as data without replacing the real constructor behavior', () => {
      const raw = '[{"type":"payment_initiation","constructor":"overridden"}]';
      const [detail] = parseAuthorizationDetailsInput(raw, LIMITS);
      expect(detail['constructor']).toBe('overridden');
      expect(({} as Record<string, unknown>)['constructor']).toBe(Object);
    });
  });

  describe('error hygiene (RFC 9396 §13)', () => {
    it('should keep the input value out of the error message', () => {
      const secret = 'IBAN-DE75512108001245126199';
      let caught: unknown;
      try {
        parseAuthorizationDetailsInput(JSON.stringify([{ type: 7, account: secret }]), LIMITS);
      } catch (error) {
        caught = error;
      }
      expect(caught).toBeInstanceOf(RarError);
      expect((caught as RarError).message).toBe('authorization_details entries must have a non-empty type');
      expect((caught as RarError).message.includes(secret)).toBe(false);
    });
  });
});

describe('validateAuthorizationDetails', () => {
  it('should accept entries whose type definition validates', () => {
    expect(() => validateAuthorizationDetails([PAYMENT_DETAIL], [PAYMENT_TYPE])).not.toThrow();
  });

  it('should reject every entry when no type definitions are registered', () => {
    // fail-closed: 型定義が空なら全拒否（RFC 9396 §5）。
    expect(() => validateAuthorizationDetails([PAYMENT_DETAIL], [])).toThrow(
      'authorization_details contains an unsupported type',
    );
  });

  it('should reject an entry whose type has no definition', () => {
    const unknownDetail = { type: 'account_information' };
    expect(() => validateAuthorizationDetails([PAYMENT_DETAIL, unknownDetail], [PAYMENT_TYPE])).toThrow(
      'authorization_details contains an unsupported type',
    );
  });

  it('should propagate a RarError thrown by the type definition validate', () => {
    const invalid = { type: 'payment_initiation', actions: [] };
    expect(() => validateAuthorizationDetails([invalid], [PAYMENT_TYPE])).toThrow(
      'payment_initiation requires actions',
    );
  });

  it('should propagate a non-RarError thrown by the type definition validate', () => {
    const throwingType: AuthorizationDetailTypeDefinition = {
      type: 'payment_initiation',
      validate(): void {
        throw new TypeError('validator bug');
      },
      describe(): readonly string[] {
        return [];
      },
    };
    expect(() => validateAuthorizationDetails([PAYMENT_DETAIL], [throwingType])).toThrow(TypeError);
  });
});

describe('describeAuthorizationDetails', () => {
  it('should build the display lines in entry order', () => {
    const second = {
      ...PAYMENT_DETAIL,
      instructedAmount: { currency: 'USD', amount: '9.99' },
    };
    expect(describeAuthorizationDetails([PAYMENT_DETAIL, second], [PAYMENT_TYPE])).toEqual([
      'Initiate a payment of EUR 123.50',
      'Initiate a payment of USD 9.99',
    ]);
  });

  it('should reject an entry whose type has no definition', () => {
    expect(() => describeAuthorizationDetails([{ type: 'account_information' }], [PAYMENT_TYPE])).toThrow(
      'authorization_details contains an unsupported type',
    );
  });
});
```

### store.test.ts

```typescript
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { createInMemoryRarDetailsStore } from './store.js';

const DETAILS = [{ type: 'payment_initiation', actions: ['initiate'] }] as const;

describe('createInMemoryRarDetailsStore', () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-11-04T00:00:00Z'));
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it('should return stored details for a key', async () => {
    const store = createInMemoryRarDetailsStore();
    await store.set('txn-1', DETAILS);
    expect(await store.get('txn-1')).toEqual(DETAILS);
  });

  it('should return undefined for an unknown key', async () => {
    const store = createInMemoryRarDetailsStore();
    expect(await store.get('missing')).toBe(undefined);
  });

  it('should return undefined after delete', async () => {
    const store = createInMemoryRarDetailsStore();
    await store.set('txn-1', DETAILS);
    await store.delete('txn-1');
    expect(await store.get('txn-1')).toBe(undefined);
  });

  it('should return undefined once expiresAt has passed', async () => {
    const store = createInMemoryRarDetailsStore();
    await store.set('grant-1', DETAILS, Date.now() + 1000);
    expect(await store.get('grant-1')).toEqual(DETAILS);
    vi.advanceTimersByTime(1000);
    expect(await store.get('grant-1')).toBe(undefined);
  });

  it('should keep an entry without expiresAt alive', async () => {
    const store = createInMemoryRarDetailsStore();
    await store.set('txn-1', DETAILS);
    vi.advanceTimersByTime(10 * 24 * 60 * 60 * 1000);
    expect(await store.get('txn-1')).toEqual(DETAILS);
  });

  it('should evict expired entries on the next set', async () => {
    const store = createInMemoryRarDetailsStore();
    await store.set('grant-1', DETAILS, Date.now() + 1000);
    vi.advanceTimersByTime(2000);
    // 書き込み時の lazy eviction で、失効済みの grant-1 が掃除される。
    await store.set('grant-2', DETAILS, Date.now() + 1000);
    expect(await store.get('grant-1')).toBe(undefined);
    expect(await store.get('grant-2')).toEqual(DETAILS);
  });
});
```

## CLI 統合と生成コードへの寄与

`packages/cli/src/registry.ts` の `FEATURE_REGISTRY` と `EXPERIMENTAL_FEATURES` へ `rar` を足した。
デフォルト無効（`DEFAULT_FEATURES` で `false`）で、`--enable rar` を明示したときだけ、以下のコードが生成物に入る。
他機能への `requires` は無く、introspection への反映は introspection パイプライン内のブロックに置いたので、introspection 無効時はそのブロックごと生成されない。

```typescript
{ id: 'rar', tier: 'experimental', requires: [], packages: EXPERIMENTAL, frameworks: ALL_FRAMEWORKS, runtimes: ALL_RUNTIMES, summary: 'OAuth 2.0 Rich Authorization Requests (RFC 9396)' },
```

以下は hono の生成結果に入るコードの全文である。
Express と Fastify の生成結果は hono と同じ feature ディレクトリとブロックを共有し、Next.js の違いは後述の節で説明する。

### features/rar/config.ts（新規ファイル全文）

上限値の fail-fast 検査は CIBA の config と同型で、型定義の注入口は `ProviderConfig` の `declare module` 拡張（google-login の config 拡張と同じパターン）である。

```typescript
/**
 * EXPERIMENTAL — Rich Authorization Requests settings (RFC 9396).
 *
 * Read by the validate-authorization-details step of the authorization
 * endpoint. The type definitions themselves (`rarTypes`) live on
 * ProviderConfig, so an application injects them next to its other provider
 * settings.
 *
 * - maxAuthorizationDetailsBytes: UTF-8 byte cap of the whole parameter
 *   (range 1024–65536). RFC 9396 §11.4 points large requests to PAR; this cap
 *   is the DoS guard for everything the endpoint still parses.
 * - maxAuthorizationDetailsEntries: entries allowed in the array (range 1–64).
 */
import type { AuthorizationDetailTypeDefinition } from '@maronn-openid-connect/experimental/rar';

export const rarConfig = {
  maxAuthorizationDetailsBytes: 16384,
  maxAuthorizationDetailsEntries: 16,
};

// Fail fast on a config edit that leaves the documented ranges: a typo here
// either re-opens the DoS surface or rejects every request.
if (rarConfig.maxAuthorizationDetailsBytes < 1024 || rarConfig.maxAuthorizationDetailsBytes > 65536) {
  throw new Error('rarConfig.maxAuthorizationDetailsBytes must be between 1024 and 65536');
}
if (rarConfig.maxAuthorizationDetailsEntries < 1 || rarConfig.maxAuthorizationDetailsEntries > 64) {
  throw new Error('rarConfig.maxAuthorizationDetailsEntries must be between 1 and 64');
}

declare module '../../config.js' {
  interface ProviderConfig {
    /**
     * EXPERIMENTAL (RFC 9396 §5): 受理する authorization details 型の定義。
     * 登録した type だけが受理され、空（未設定）なら `authorization_details`
     * 付きのリクエストはすべて `invalid_authorization_details` になる
     * （fail-closed）。discovery はこの一覧の type 値を
     * `authorization_details_types_supported` として広告する（§10）。
     */
    rarTypes?: readonly AuthorizationDetailTypeDefinition[];
  }
}
```

### features/rar/store.ts（新規ファイル全文）

同じストア契約の 2 インスタンスを、PAR のストアと同じく `globalThis` のレジストリで共有する。

```typescript
import {
  createInMemoryRarDetailsStore,
  type RarDetailsStore,
} from '@maronn-openid-connect/experimental/rar';

/**
 * EXPERIMENTAL — in-memory stores of the requested and granted
 * authorization details (RFC 9396).
 *
 * Two instances of the same contract:
 *
 * - rarTransactionStore: keyed by transactionId, holds the validated details
 *   between the authorization request and the consent decision. Entries live
 *   as long as the authorization transaction.
 * - rarGrantStore: keyed by grantId, holds the approved details for the token
 *   response (§7) and introspection (§9.2). Entries live as long as the
 *   refresh token absolute lifetime, evicted lazily on writes.
 *
 * Replace with persistent stores (Redis, KV, database) in production. Keys
 * are opaque identifiers minted by this provider: never interpolate them into
 * a query, always bind them as parameters.
 */

// Kept on globalThis so every module that asks for the stores gets the same
// ones, also where a framework loads a module more than once (dev-mode hot
// reloads, separate module layers).
const rarStoreRegistry = globalThis as typeof globalThis & {
  __oidcRarTransactionStore?: RarDetailsStore;
  __oidcRarGrantStore?: RarDetailsStore;
};

export const rarTransactionStore: RarDetailsStore =
  (rarStoreRegistry.__oidcRarTransactionStore ??= createInMemoryRarDetailsStore());

export const rarGrantStore: RarDetailsStore =
  (rarStoreRegistry.__oidcRarGrantStore ??= createInMemoryRarDetailsStore());
```

### features/rar/feature.ts（新規ファイル全文）

discovery フックは、型定義が空のときに member 自体を出さない。
クライアントは広告の無い OP へ RAR を送るべきでなく、型定義が空の OP はすべてのリクエストを拒否するためで、「広告しているのに全部拒否する」状態を作らない。

```typescript
import { defineFeature } from '../feature.js';
import { rarGrantStore, rarTransactionStore } from './store.js';

/**
 * EXPERIMENTAL — Rich Authorization Requests (RFC 9396): the
 * authorization_details parameter of the authorization endpoint, its rows on
 * the consent screen, and the approved details on the token response and
 * introspection. Settings are in config.ts; the accepted types are injected
 * through ProviderConfig.rarTypes.
 *
 * Backed by @maronn-openid-connect/experimental, whose API is NOT stable: it
 * may change in a breaking way between releases.
 */
export const rar = defineFeature({
  id: 'rar',
  // RFC 9396 §10 metadata. Only advertised while type definitions are
  // registered: a client must not send RAR to an OP that does not advertise
  // the member, and this OP rejects every request while the list is empty.
  discovery: (_issuer, config) =>
    config.rarTypes !== undefined && config.rarTypes.length > 0
      ? { authorization_details_types_supported: config.rarTypes.map((definition) => definition.type) }
      : {},
  context: { rarTransactionStore, rarGrantStore },
});
```

### features/rar/steps/validate-authorization-details.ts（新規ファイル全文）

値は Request Object の claim を優先して読む。
core の Request Object 処理は固定キーしか `effectiveParams` へ写さないため、`authorization_details` はクエリ側へ現れず、`requestObjectClaims`（JWT ペイロードをデコードした値）から読む必要がある。
クエリ値より優先するのは OIDC Core 1.0 §6.1 の supersede 規則で、署名付き Request Object で details を保護する §12 の想定経路を成立させる。

```typescript
import {
  AuthorizationError,
  type AuthorizationErrorCode,
  type ValidatedAuthorizationRequest,
} from '@maronn-openid-connect/core';
import {
  AUTHORIZATION_DETAILS_PARAM,
  RarError,
  parseAuthorizationDetailsInput,
  validateAuthorizationDetails,
  type AuthorizationDetail,
} from '@maronn-openid-connect/experimental/rar';
import type { AuthorizationRequestInput } from '../../../endpoints/authorize/outcome.js';
import { step } from '../../../endpoints/step.js';
import { rarConfig } from '../config.js';

export const meta = step({
  id: 'validate-authorization-details',
  endpoint: 'authorize',
  feature: 'rar',
  kind: 'validate',
  label: 'authorization_details を検証し、同意を必須にする',
  spec: 'RFC 9396 §3 / §5',
  function: 'validateAuthorizationDetailsRequest',
  consumes: ['params', 'requestObjectClaims', 'validatedRequest'],
  optional: ['requestObjectClaims'],
  produces: ['authorizationDetails'],
  removable: false,
});

/**
 * `authorization_details` を検証して返し、details があるリクエストには同意画面を必須にする。
 *
 * パラメータは、Request Object の claim（あればクエリより優先。OIDC Core 1.0 §6.1 の
 * supersede 規則）、無ければクエリ / PAR 由来の `params` から読む。無ければ何もせず
 * `undefined` を返す。あれば構造（RFC 9396 §2 / §2.2）と上限（`rarConfig`）を検査し、
 * `config.rarTypes` の型定義と突き合わせる（§5。型定義が空ならすべて拒否）。
 *
 * details があるリクエストはエンドユーザーの同意を毎回要する（SSO の同意スキップは
 * scope 単位の記録しか持たず details を知らない）ので、`prompt=none` 単独なら
 * `consent_required` で拒否し、それ以外なら `validatedRequest.prompt` へ `consent` を
 * 加えて、silent / SSO の両経路を同意画面へ向ける。`none` が他の値と組む不正な
 * リクエストには手を出さず、base の `[validate-prompt-combination]` に委ねる。
 *
 * エラーの `error_description` は固定の ASCII 文言で、details の内容を反映しない
 * （RFC 9396 §13）。
 *
 * 実験的な機能である。
 *
 * @spec RFC 9396 §3
 * @spec RFC 9396 §5
 * @throws {AuthorizationError} `invalid_authorization_details`: 構造違反、上限超過、未知の type、型定義の検証違反のとき
 * @throws {AuthorizationError} `consent_required`: details 付きのリクエストが `prompt=none` 単独のとき
 */
export function validateAuthorizationDetailsRequest(
  c: any,
  input: {
    params: AuthorizationRequestInput;
    requestObjectClaims?: Record<string, unknown>;
    validatedRequest: ValidatedAuthorizationRequest;
  },
): AuthorizationDetail[] | undefined {
  const { params, requestObjectClaims, validatedRequest } = input;
  const raw = requestObjectClaims?.[AUTHORIZATION_DETAILS_PARAM] ?? params[AUTHORIZATION_DETAILS_PARAM];
  if (raw === undefined) return undefined;

  const config = c.get('config');
  let details: AuthorizationDetail[];
  try {
    details = parseAuthorizationDetailsInput(raw, {
      maxBytes: rarConfig.maxAuthorizationDetailsBytes,
      maxEntries: rarConfig.maxAuthorizationDetailsEntries,
    });
    validateAuthorizationDetails(details, config.rarTypes ?? []);
  } catch (error) {
    // 失敗の種類（構造、上限、未知 type、型定義の違反）によらず同じ固定文言にし、
    // details の値（金額、口座、type 名）をエラー経由で漏らさない（RFC 9396 §13）。
    if (error instanceof RarError) {
      throw new AuthorizationError(
        error.code as AuthorizationErrorCode,
        'The authorization_details parameter is invalid',
        validatedRequest.redirectUri,
        validatedRequest.state,
      );
    }
    throw error;
  }

  const promptValues = validatedRequest.prompt ?? [];
  if (promptValues.includes('none')) {
    // `none` 単独は、画面を出せないのに新規同意が要るので `consent_required`（OIDC Core 1.0 §3.1.2.1 の意味論）。
    // `none` と他の値の組み合わせは本機能の管轄外で、base の検査が `invalid_request` にする。
    if (promptValues.length === 1) {
      throw new AuthorizationError(
        'consent_required' as AuthorizationErrorCode,
        'authorization_details requires user consent',
        validatedRequest.redirectUri,
        validatedRequest.state,
      );
    }
    return details;
  }

  // details は毎回ユーザーに見せて承認させる。`prompt=consent` は OIDC Core 1.0
  // §3.1.2.1 の「consent MUST re-display」にそのまま乗り、silent / SSO の同意
  // スキップ（authenticate-silently / reuse-session）の両方がこの値で止まる。
  if (!promptValues.includes('consent')) {
    validatedRequest.prompt = [...promptValues, 'consent'];
  }
  return details;
}
```

### features/rar/steps/record-authorization-details.ts（新規ファイル全文）

```typescript
import type { AuthorizationDetail } from '@maronn-openid-connect/experimental/rar';
import { step } from '../../../endpoints/step.js';

export const meta = step({
  id: 'record-authorization-details',
  endpoint: 'authorize',
  feature: 'rar',
  kind: 'persist',
  label: 'authorization details をトランザクションへ保持する',
  spec: 'RFC 9396 §3',
  function: 'recordAuthorizationDetails',
  calls: ['rarTransactionStore.set'],
  consumes: ['transactionId', 'transactionTtlSeconds', 'authorizationDetails'],
  optional: ['authorizationDetails'],
  produces: [],
  removable: false,
});

/**
 * 検証済みの authorization details を、トランザクション ID をキーに保存する。
 *
 * details の無いリクエスト（`authorizationDetails` が `undefined`）では何もしない。
 * 保存の寿命は認可トランザクションと同じ（`transactionTtlSeconds`）で、同意まで
 * 進まなかったトランザクションの details はストアの失効で消える。
 *
 * 実験的な機能である。
 *
 * @spec RFC 9396 §3
 */
export async function recordAuthorizationDetails(
  c: any,
  input: {
    transactionId: string;
    transactionTtlSeconds: number;
    authorizationDetails: AuthorizationDetail[] | undefined;
  },
): Promise<void> {
  const { transactionId, transactionTtlSeconds, authorizationDetails } = input;
  if (authorizationDetails === undefined) return;
  const rarTransactionStore = c.get('rarTransactionStore');
  await rarTransactionStore.set(
    transactionId,
    authorizationDetails,
    Date.now() + transactionTtlSeconds * 1000,
  );
}
```

### features/rar/steps/describe-authorization-details.ts（新規ファイル全文）

```typescript
import { describeAuthorizationDetails } from '@maronn-openid-connect/experimental/rar';
import { step } from '../../../endpoints/step.js';

export const meta = step({
  id: 'describe-authorization-details',
  endpoint: 'consent',
  feature: 'rar',
  kind: 'transform',
  label: '同意画面に出す authorization details の表示行を作る',
  spec: 'RFC 9396 §3.1',
  function: 'describeTransactionAuthorizationDetails',
  calls: ['rarTransactionStore.get'],
  consumes: ['transactionId'],
  produces: ['authorizationDetails'],
  removable: false,
});

/**
 * トランザクションに保持した authorization details の表示行を返す。
 *
 * details の無いトランザクションでは `undefined` を返し、同意画面は従来どおりに
 * なる。あれば、`config.rarTypes` の型定義の `describe` が作るプレーン文字列の行を
 * 返し、同意画面が scope の一覧と併記する（RFC 9396 §3.1 の merged set）。
 * 行のエスケープは view 層（JSX）に委ねる。
 *
 * 保持した details の type に対応する型定義が無くなっていたら例外を投げる
 * （表示できない要素を黙って落とすと、見ていない権限が承認されてしまう）。
 *
 * 実験的な機能である。
 *
 * @spec RFC 9396 §3.1
 * @throws {RarError} 保持した details の type に対応する型定義が設定から消えているとき
 */
export async function describeTransactionAuthorizationDetails(
  c: any,
  transactionId: string,
): Promise<readonly string[] | undefined> {
  const rarTransactionStore = c.get('rarTransactionStore');
  const details = await rarTransactionStore.get(transactionId);
  if (details === undefined) return undefined;
  const config = c.get('config');
  return describeAuthorizationDetails(details, config.rarTypes ?? []);
}
```

### features/rar/steps/record-granted-details.ts（新規ファイル全文）

寿命を `refreshTokenAbsoluteLifetime` 起点にできるのは、リフレッシュトークンのローテーションが絶対寿命を初回発行時刻起点で固定するためである。
有効なリフレッシュトークンが存在する間にエントリが先に消えることはなく、§7 の MUST（応答に details を含める）はグラントの正規の生存期間全体で満たされる。

```typescript
import type { AuthorizationCodeData } from '@maronn-openid-connect/core';
import { step } from '../../../endpoints/step.js';

export const meta = step({
  id: 'record-granted-details',
  endpoint: 'consent',
  feature: 'rar',
  kind: 'persist',
  label: '承認された authorization details をグラントへ紐付ける',
  spec: 'RFC 9396 §7',
  function: 'recordGrantedAuthorizationDetails',
  calls: ['rarTransactionStore.get', 'rarTransactionStore.delete', 'rarGrantStore.set'],
  consumes: ['transactionId', 'authCodeData'],
  produces: [],
  removable: false,
});

/**
 * 承認されたトランザクションの authorization details を grantId へ付け替える。
 *
 * details の無いトランザクションでは何もしない。あれば grantId をキーに保存し、
 * transactionId 側のエントリを削除する。grantId は authorization_code と
 * refresh_token の両グラントを貫通するので、トークン応答（RFC 9396 §7）と
 * introspection（§9.2）はこのキーで details を引ける。
 *
 * 保存の寿命は `発行時刻 + config.refreshTokenAbsoluteLifetime`。ローテーションは
 * 絶対寿命を初回発行時刻起点で固定するため、有効なリフレッシュトークンが存在する
 * 間にエントリが先に消えることはない。リフレッシュトークンを発行しないグラントでは
 * 寿命まで過剰保持になるが、in-memory の experimental として許容している。
 *
 * 実験的な機能である。
 *
 * @spec RFC 9396 §7
 */
export async function recordGrantedAuthorizationDetails(
  c: any,
  transactionId: string,
  authCodeData: AuthorizationCodeData,
): Promise<void> {
  const rarTransactionStore = c.get('rarTransactionStore');
  const details = await rarTransactionStore.get(transactionId);
  if (details === undefined) return;
  const config = c.get('config');
  const rarGrantStore = c.get('rarGrantStore');
  await rarGrantStore.set(
    authCodeData.grantId,
    details,
    Date.now() + config.refreshTokenAbsoluteLifetime * 1000,
  );
  await rarTransactionStore.delete(transactionId);
}
```

### features/rar/steps/reject-token-request-details.ts（新規ファイル全文）

```typescript
import { AUTHORIZATION_DETAILS_PARAM } from '@maronn-openid-connect/experimental/rar';
import { TokenEndpointError } from '../../../endpoints/token/response.js';
import { step } from '../../../endpoints/step.js';

export const meta = step({
  id: 'reject-token-request-details',
  endpoint: 'token',
  feature: 'rar',
  kind: 'validate',
  label: 'トークンリクエストの authorization_details を拒否する',
  spec: 'RFC 9396 §6',
  function: 'rejectTokenRequestAuthorizationDetails',
  consumes: ['params'],
  produces: [],
  removable: false,
});

/**
 * トークンリクエストに `authorization_details` があれば、400 の `invalid_authorization_details` で拒否する。
 *
 * RFC 9396 §6 のトークンリクエストでの再指定（narrowing）には対応しない。黙って
 * 無視すると「絞り込まれた」とクライアントに誤認させるので、明示的に拒否する。
 * このステップは feature grant の dispatch 群の直後・`[validate-grant-type]` の前に
 * 置き、トークンの発行・保存・提示リフレッシュトークンのローテーション失効という
 * どの副作用よりも前に拒否を確定させる（応答組み立て時の拒否は、拒否済み
 * リクエストの副作用を残すため禁止している）。
 *
 * 実験的な機能である。
 *
 * @spec RFC 9396 §6
 * @throws {TokenEndpointError} 400 `invalid_authorization_details`: リクエストに `authorization_details` パラメータがあるとき
 */
export function rejectTokenRequestAuthorizationDetails(params: Record<string, string>): void {
  if (params[AUTHORIZATION_DETAILS_PARAM] === undefined) return;
  throw new TokenEndpointError({
    status: 400,
    body: {
      error: 'invalid_authorization_details',
      error_description: 'authorization_details is not accepted at the token endpoint',
    },
  });
}
```

### features/rar/steps/append-token-response-details.ts（新規ファイル全文）

```typescript
import type { ValidatedTokenRequest } from '@maronn-openid-connect/core';
import type { TokenEndpointResponse } from '../../../endpoints/token/response.js';
import { step } from '../../../endpoints/step.js';

export const meta = step({
  id: 'append-token-response-details',
  endpoint: 'token',
  feature: 'rar',
  kind: 'transform',
  label: '承認済みの authorization details を応答へ含める',
  spec: 'RFC 9396 §7',
  function: 'appendAuthorizationDetailsToTokenResponse',
  calls: ['rarGrantStore.get'],
  consumes: ['tokenResponse', 'validatedRequest'],
  produces: ['tokenResponse'],
  removable: false,
});

/**
 * グラントに紐づく authorization details があれば、トークンレスポンスのボディへ加えて返す。
 *
 * `validatedRequest.grantId`（authorization_code / refresh_token の両グラントを
 * 貫通する）で grant ストアを引き、あれば承認された配列をそのまま
 * `authorization_details` メンバーとして加える（RFC 9396 §7 の MUST。§7.1 の
 * enrichment はしない）。無ければ応答を変えずに返すので、details を持たない
 * グラントの応答は従来とバイト単位で同じである。
 *
 * 実験的な機能である。
 *
 * @spec RFC 9396 §7
 */
export async function appendAuthorizationDetailsToTokenResponse(
  c: any,
  tokenResponse: TokenEndpointResponse,
  validatedRequest: ValidatedTokenRequest,
): Promise<TokenEndpointResponse> {
  const rarGrantStore = c.get('rarGrantStore');
  const details = await rarGrantStore.get(validatedRequest.grantId);
  if (details === undefined) return tokenResponse;
  return {
    ...tokenResponse,
    body: { ...tokenResponse.body, authorization_details: details },
  };
}
```

### features/rar/steps/append-introspection-details.ts（新規ファイル全文）

```typescript
import type {
  IntrospectionResponse,
  ResolvedIntrospectionToken,
} from '@maronn-openid-connect/core';
import { step } from '../../../endpoints/step.js';

export const meta = step({
  id: 'append-introspection-details',
  endpoint: 'introspection',
  feature: 'rar',
  kind: 'transform',
  label: 'authorization details を introspection 応答へ含める',
  spec: 'RFC 9396 §9.2',
  function: 'appendAuthorizationDetailsToIntrospection',
  calls: ['rarGrantStore.get'],
  consumes: ['introspection', 'resolved'],
  produces: ['introspection'],
  removable: false,
});

/**
 * 有効なトークンのグラントに authorization details があれば、introspection 応答へ加えて返す。
 *
 * `active: true` の応答に限り、解決済みトークンの `grantId` で grant ストアを引き、
 * あれば `authorization_details` を top-level member として加える（RFC 9396 §9.2 の
 * 構造要件。資源サーバー別のフィルタリングはしない）。`active: false` の応答と
 * details を持たないトークンの応答は変えずに返す。jwt-introspection-response
 * 併用時は、このステップの後に署名されるので member は署名対象に含まれる。
 *
 * 実験的な機能である。
 *
 * @spec RFC 9396 §9.2
 */
export async function appendAuthorizationDetailsToIntrospection(
  c: any,
  introspection: IntrospectionResponse,
  resolved: ResolvedIntrospectionToken | null,
): Promise<IntrospectionResponse> {
  if (!introspection.active || resolved === null) return introspection;
  const grantId =
    resolved.tokenType === 'access_token'
      ? resolved.accessToken.grantId
      : resolved.refreshToken.grantId;
  const rarGrantStore = c.get('rarGrantStore');
  const details = await rarGrantStore.get(grantId);
  if (details === undefined) return introspection;
  // RFC 9396 §9.2 の拡張 member。core の IntrospectionResponse 型は閉じた union
  // なので、member を足した応答は型表明で IntrospectionResponse に戻す。
  return { ...introspection, authorization_details: details } as IntrospectionResponse;
}
```

### endpoints/authorize/pipeline.ts に入るコード

`[validate-hybrid-request]` と `[create-transaction]` の間、および `[create-transaction]` と `[validate-prompt-combination]` の間に、次の 2 ブロックが入る。
検証をトランザクション作成の前に置くのは、`validatedRequest.prompt` への `consent` 付与をトランザクションに保存させるためである。

```typescript
    // [validate-authorization-details] (feature: rar) authorization_details を検証し、同意を必須にする — RFC 9396 §3 / §5
    const authorizationDetails = validateAuthorizationDetailsRequest(c, { params, requestObjectClaims, validatedRequest });
```

```typescript
    // [record-authorization-details] (feature: rar) authorization details をトランザクションへ保持する — RFC 9396 §3
    await recordAuthorizationDetails(c, { transactionId, transactionTtlSeconds, authorizationDetails });
```

### endpoints/consent/pipeline.ts に入るコードと base の組み替え

`prepareConsent()` は、これまで `describeConsentScreen()` の戻り値を直接 `return` していた。
hono のパイプラインでは、機能のブロックは「自分のマーカーから次のマーカー（またはハンドラの末尾）まで」を所有するので、末尾に rar のブロックを置くと、無効時のブロック除去が `return` 文まで巻き込んでしまう。
そこで rar のブロックを `[describe-consent-screen]` の**前**に置き、base の `return` が rar の produce（`authorizationDetails`）を読む形にした。
rar 無効時は、生成器がこの変数を `const authorizationDetails = undefined;` に置き換えるので、`{ ...screen, authorizationDetails: undefined }` となり画面は従来どおりである。

```typescript
  // [describe-authorization-details] (feature: rar) 同意画面に出す authorization details の表示行を作る — RFC 9396 §3.1
  const authorizationDetails = await describeTransactionAuthorizationDetails(c, transactionId);

  // [describe-consent-screen] 同意画面の表示内容を組み立てる
  const screen = await describeConsentScreen(c, transactionId, transaction);
  return { ...screen, authorizationDetails };
```

`submitConsent()` では、認可コードの発行と同意の記録の間に、承認の確定点として付け替えのブロックが入る。

```typescript
  // [record-granted-details] (feature: rar) 承認された authorization details をグラントへ紐付ける — RFC 9396 §7
  await recordGrantedAuthorizationDetails(c, transactionId, authCodeData);
```

### endpoints/token/pipeline.ts に入るコード

`[dispatch-ciba]` の直後に拒否ブロックが、`[build-token-response]` の直後に反映ブロックが入り、応答の変数は `const` から `let` になる（PAR が `let params` を再代入する既存パターンと同型）。

```typescript
    // [reject-token-request-details] (feature: rar) トークンリクエストの authorization_details を拒否する — RFC 9396 §6
    rejectTokenRequestAuthorizationDetails(params);
```

```typescript
    // [build-token-response] トークンレスポンスのボディを組み立てる — OIDC Core 1.0 §3.1.3.3 / RFC 6749 §5.1
    let tokenResponse = buildTokenResponse(c, { accessToken, idToken, refreshToken, validatedRequest });

    // [append-token-response-details] (feature: rar) 承認済みの authorization details を応答へ含める — RFC 9396 §7
    tokenResponse = await appendAuthorizationDetailsToTokenResponse(c, tokenResponse, validatedRequest);
```

### introspection の pipeline.ts に入るコード

introspection 機能のパイプラインでは、`[build-response]` と `[sign-response]` の間にブロックが入る。
署名（jwt-introspection-response）より前に member を足すので、JWT 応答でも `authorization_details` は署名対象に含まれる。

```typescript
    // [build-response] トークンの情報をまとめる（有効かどうか） — RFC 7662 §2.2
    let introspection = describeIntrospectedToken(resolved);

    // [append-introspection-details] (feature: rar) authorization details を introspection 応答へ含める — RFC 9396 §9.2
    introspection = await appendAuthorizationDetailsToIntrospection(c, introspection, resolved);
```

### 同意画面の base 変更（screen.ts / views.tsx / page.tsx）

`ConsentScreen`（consent の論理層）と `ConsentPageParams`（view 層）に optional のフィールドを足し、既定ビューは存在するときだけ一覧を描画する。
rar 無効時はフィールドが `undefined` のままなので、画面は従来どおりである。

```typescript
  /**
   * Display lines of the requested authorization details (RFC 9396 §3.1),
   * shown next to the scopes. Set by the rar feature; absent without it or
   * when the request carried no authorization_details.
   */
  authorizationDetails?: readonly string[];
```

```tsx
      {params.authorizationDetails && params.authorizationDetails.length > 0 ? (
        <>
          <p>The client also requests the following authorization details:</p>
          <ul>
            {params.authorizationDetails.map((line) => (
              <li>{line}</li>
            ))}
          </ul>
        </>
      ) : null}
```

`page.tsx` は `screen.authorizationDetails` をビューへ渡すだけである。

```tsx
  return renderConsentPage(c, {
    csrfToken: screen.csrfToken,
    scopes: screen.scopes,
    clientId: screen.clientId,
    authorizationDetails: screen.authorizationDetails,
  });
```

### endpoint.ts と features/enabled.ts への追記

各エンドポイントの `endpoint.ts` の steps へ、feature 付きのステップ id を足した（authorize: `validate-authorization-details` / `record-authorization-details`、consent: `describe-authorization-details` / `record-granted-details` と GET・承認経路の edges、token: `reject-token-request-details` / `append-token-response-details`、introspection: `append-introspection-details`）。
`features/enabled.ts` には import と一覧の 1 行ずつが入る。

```typescript
import { rar } from './rar/feature.js';
```

```typescript
  rar,
```

### Next.js の生成結果

Next.js は route group を持たず、`_oidc-provider/features/rar/`（config / store / feature / authorize / consent / token / introspect）と、authorize・consent decision・token・introspect の各 route.ts への同名ブロックで同じ流れを実装する。
コードの内容は hono と同等なのでリンクで示し（[apps/nextjs/src/app/_oidc-provider/features/rar/](https://github.com/maronnjapan/maronn-openid-connect/tree/main/apps/nextjs/src/app/_oidc-provider/features/rar)）、hono と構造が異なる 2 点だけをここで説明する。

第一に、同意画面は Route Handler でなく React Server Component のページなので、所有ブロックを置けない。
そこで Next.js の `Feature` インタフェースに consent フック（`describeTransaction`）を足し、ページは有効な機能の行を並べるだけにした。
rar 無効時は features の一覧に rar が無く、行は空になる。
これは login ページが `loginMethods` フックを並べるのと同じ機構である。

```typescript
  readonly consent?: {
    /**
     * Extra display rows the consent page lists next to the scopes of a
     * transaction (plain strings; the page escapes them as JSX). A feature
     * returns [] for a transaction it has nothing to show for.
     */
    readonly describeTransaction?: (
      transactionId: string,
      config: ProviderConfig,
    ) => Promise<readonly string[]>;
  };
```

```typescript
/**
 * 機能が同意画面に加える表示行を、機能の順に集めて返す。
 *
 * 各機能の `consent.describeTransaction` をトランザクション ID と設定で呼び、
 * 返った行をつなげる。表示する内容を持たない機能は空配列を返すので、
 * どの機能も無ければ結果も空配列になる。
 */
export async function consentRowsOf(
  features: readonly Feature[],
  transactionId: string,
  config: ProviderConfig,
): Promise<string[]> {
  const rows: string[] = [];
  for (const feature of features) {
    const describe = feature.consent?.describeTransaction;
    if (describe === undefined) continue;
    rows.push(...(await describe(transactionId, config)));
  }
  return rows;
}
```

第二に、型定義の注入口が二段になっている。
Next.js はモジュールを層（Route Handler、ページ、`instrumentation.ts`）ごとに読み込むため、起動フックから `config.rarTypes` へ代入しても Route Handler の層には届かない。
そこで `provider.ts` の設定（`config.rarTypes`。コードなのでどの層でも同じ値になる）を優先しつつ、起動フック用の注入口として `shared()` の `rarConfig.types` をフォールバックにした。
このリポジトリの開発用アプリは、`dev-data.ts` が `rarConfig.types` へデモ型定義を代入する。

```typescript
/**
 * この OP が受理する authorization details の型定義を返す。
 *
 * `config.rarTypes`（provider.ts の設定）があればそれを、無ければ
 * `rarConfig.types`（起動フックからの注入）を返す。どちらも無ければ
 * `undefined` で、`authorization_details` 付きのリクエストはすべて拒否される
 * （fail-closed）。
 *
 * @spec RFC 9396 §5
 */
export function resolveRarTypes(
  config: ProviderConfig,
): readonly AuthorizationDetailTypeDefinition[] | undefined {
  return config.rarTypes ?? rarConfig.types;
}
```

もう一つの小さな base 変更として、authorize の route.ts では `const prompt` を `let prompt` にした。
Route Handler では rar の検証ブロックの時点で `validatedRequest` がまだ存在しないため、更新後の prompt を戻り値で受けて再代入する。

```typescript
    // [validate-authorization-details] (feature: rar) authorization_details を検証し、同意を必須にする — RFC 9396 §3 / §5
    const rarRequest = validateAuthorizationDetailsRequest({ params, requestObjectClaims, prompt, redirectUri, state, rarTypes: resolveRarTypes(config) });
    const authorizationDetails = rarRequest.authorizationDetails;
    prompt = rarRequest.prompt;
```

### デモ型定義（生成コードの外）

E2E が実プロトコルで検証できるよう、このリポジトリの開発用アプリ（apps/hono は `app.ts`、apps/nextjs は `dev-data.ts`）はデモ型 `payment_initiation` を登録する。
どちらも CLI の抽出範囲の外にあり、生成コードには入らない。
生成した OP は型定義ゼロから始まる。

```typescript
/**
 * EXPERIMENTAL (RFC 9396): the demo authorization-details type of this app.
 *
 * A payment_initiation type shaped after the example of RFC 9396 §2.1
 * Figure 1, registered by app.ts so tests/e2e can exercise the rar feature
 * over the protocol. It is this app's own development data — the CLI never
 * copies this file into generated code, and a generated provider accepts no
 * type until its operator injects definitions through config.rarTypes.
 */
import {
  RarError,
  type AuthorizationDetail,
  type AuthorizationDetailTypeDefinition,
} from '@maronn-openid-connect/experimental/rar';

/** The actions the demo type accepts (RFC 9396 §2.1 uses "initiate"). */
const PAYMENT_ACTIONS = ['initiate', 'status', 'cancel'] as const;

/** The display verb of each accepted action on the consent screen. */
const ACTION_VERBS: Record<(typeof PAYMENT_ACTIONS)[number], string> = {
  initiate: 'Initiate a payment of',
  status: 'Check the status of a payment of',
  cancel: 'Cancel a payment of',
};

/**
 * payment_initiation の要素を検証し、`actions` の値域と `instructedAmount` の構造に違反があれば `RarError` を投げる。
 *
 * `actions` は `initiate` / `status` / `cancel` だけからなる非空の配列、
 * `instructedAmount` は `{ currency: 大文字 3 文字, amount: 小数 2 桁の文字列 }` の
 * オブジェクトでなければならない（RFC 9396 §2.1 の例の形）。
 * message は固定の ASCII 文言で、入力値を含めない。
 *
 * @spec RFC 9396 §2.1
 * @throws {RarError} `actions` か `instructedAmount` が上の形でないとき
 */
function validatePaymentInitiation(detail: AuthorizationDetail): void {
  const actions = detail.actions;
  if (
    !Array.isArray(actions) ||
    actions.length === 0 ||
    actions.some((action) => !(PAYMENT_ACTIONS as readonly string[]).includes(action))
  ) {
    throw new RarError('payment_initiation requires actions out of initiate, status, cancel');
  }
  const instructedAmount = detail['instructedAmount'];
  if (typeof instructedAmount !== 'object' || instructedAmount === null || Array.isArray(instructedAmount)) {
    throw new RarError('payment_initiation requires an instructedAmount object');
  }
  const { currency, amount } = instructedAmount as Record<string, unknown>;
  if (typeof currency !== 'string' || !/^[A-Z]{3}$/.test(currency)) {
    throw new RarError('payment_initiation requires an uppercase three-letter currency');
  }
  if (typeof amount !== 'string' || !/^\d+\.\d{2}$/.test(amount)) {
    throw new RarError('payment_initiation requires a decimal amount string');
  }
}

/**
 * payment_initiation の要素から、同意画面に出す固定書式の表示行（アクションごとに 1 行）を返す。
 *
 * `validatePaymentInitiation()` を通った要素だけを受ける前提で、
 * `Initiate a payment of EUR 123.50` のようなプレーン文字列を組み立てる。
 *
 * @spec RFC 9396 §3.1
 */
function describePaymentInitiation(detail: AuthorizationDetail): readonly string[] {
  const { currency, amount } = detail['instructedAmount'] as { currency: string; amount: string };
  const actions = (detail.actions ?? []) as readonly (typeof PAYMENT_ACTIONS)[number][];
  return actions.map((action) => `${ACTION_VERBS[action]} ${currency} ${amount}`);
}

/** The demo type definitions app.ts passes to applyOidc as config.rarTypes. */
export const demoRarTypes: readonly AuthorizationDetailTypeDefinition[] = [
  {
    type: 'payment_initiation',
    validate: validatePaymentInitiation,
    describe: describePaymentInitiation,
  },
];
```

## E2E テストの全文

E2E クライアント（`tests/e2e/apps/client.mjs`）には `/start-rar` ルートを足した。
`authorization_details` 付きで認可コードフローを回し、トークン応答・refresh・introspection の 3 チャネルで details を観測する。
仕様テスト側は discovery の `authorization_details_types_supported` で自己スキップし、rar 無しの sample OP ではパラメータが従来どおり無視されることだけを確かめる。

トークンエンドポイントの拒否テストは、拒否が副作用より前であることをプロトコルで検証している。
`authorization_details` 付きの refresh リクエストが 400 で拒否されたあと、**同じリフレッシュトークン**でのやり直しが成功することは、拒否時点でローテーション（提示トークンの失効）が起きていないことを意味する。

### specs/rar.spec.ts

```typescript
import { expect, test } from '@playwright/test';

const host = process.env.E2E_HOST ?? '127.0.0.1';
const clientPort = Number(process.env.E2E_CLIENT_PORT ?? '3020');
const clientBaseURL =
  process.env.E2E_CLIENT_BASE_URL ?? `http://${host}:${clientPort}`;
const clientId = 'e2e-client';
const clientSecret = 'e2e-client-secret';

// The demo type the app OPs register (apps/*/src/rar-demo.ts): the
// payment_initiation example of RFC 9396 §2.1 Figure 1.
const PAYMENT_DETAIL = {
  type: 'payment_initiation',
  actions: ['initiate'],
  locations: ['https://example.com/payments'],
  instructedAmount: { currency: 'EUR', amount: '123.50' },
};

/**
 * EXPERIMENTAL — Rich Authorization Requests (RFC 9396).
 *
 * Only an OP generated with `--enable rar` (and with type definitions
 * registered) advertises authorization_details_types_supported, so most tests
 * here skip when discovery does not advertise the demo type. That keeps the
 * shared spec suite green across all sample OPs; the one test that runs
 * without the feature shows the parameter is ignored as before.
 */
test.describe('Rich Authorization Requests (RAR)', () => {
  test('should carry the approved details to the token response, the refresh and introspection', async ({
    page,
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    test.skip(!(await rarAdvertised(request, issuer)), 'This OP was generated without --enable rar');

    await page.goto(`${clientBaseURL}/start-rar`);
    await page.getByLabel('Username:').fill('testuser');
    await page.getByLabel('Password:').fill('password');
    await page.getByRole('button', { name: 'Login' }).click();
    await expect(page).toHaveURL(new RegExp(`^${escapeRegExp(issuer)}/consent$`));

    // RFC 9396 §3.1: the consent screen lists the requested details next to
    // the scopes, with the display line the type definition built.
    await expect(page.getByText('Initiate a payment of EUR 123.50')).toBeVisible();

    await page.getByRole('button', { name: 'Approve' }).click();

    // §7: the token response of the code grant carries the approved details,
    // and a refresh of the same grant carries them unchanged.
    await expect(page.getByTestId('token-type')).toHaveText('Bearer');
    await expect(page.getByTestId('rar-token-details')).toHaveText(JSON.stringify([PAYMENT_DETAIL]));
    await expect(page.getByTestId('rar-refresh-details')).toHaveText(JSON.stringify([PAYMENT_DETAIL]));

    // §9.2: introspection reports them as a top-level member.
    await expect(page.getByTestId('rar-introspection-active')).toHaveText('true');
    await expect(page.getByTestId('rar-introspection-details')).toHaveText(JSON.stringify([PAYMENT_DETAIL]));
  });

  test('should advertise the registered types in discovery', async ({ request, baseURL }) => {
    const issuer = requireBaseUrl(baseURL);
    const types = await advertisedTypes(request, issuer);
    test.skip(types === undefined, 'This OP was generated without --enable rar');

    // RFC 9396 §10: exactly the registered demo type.
    expect(types).toEqual(['payment_initiation']);
  });

  test('should reject an unknown type with an invalid_authorization_details redirect', async ({
    page,
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    test.skip(!(await rarAdvertised(request, issuer)), 'This OP was generated without --enable rar');

    // RFC 9396 §5: a request with a type the OP does not understand MUST be
    // refused. The error redirects to the client with the registered code.
    await page.goto(`${clientBaseURL}/start-rar?type=account_information`);
    await expect(page.getByTestId('authorization-error')).toHaveText('invalid_authorization_details');
    // The fixed description carries no detail values (RFC 9396 §13).
    await expect(page.getByTestId('authorization-error-description')).toHaveText(
      'The authorization_details parameter is invalid',
    );
  });

  test('should answer prompt=none with consent_required', async ({ page, request, baseURL }) => {
    const issuer = requireBaseUrl(baseURL);
    test.skip(!(await rarAdvertised(request, issuer)), 'This OP was generated without --enable rar');

    // Details always need fresh consent, and prompt=none forbids showing the
    // consent screen (OIDC Core 1.0 §3.1.2.1), so the request fails up front.
    await page.goto(`${clientBaseURL}/start-rar?prompt=none`);
    await expect(page.getByTestId('authorization-error')).toHaveText('consent_required');
  });

  test('should reject authorization_details at the token endpoint before any side effect', async ({
    page,
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    test.skip(!(await rarAdvertised(request, issuer)), 'This OP was generated without --enable rar');

    await page.goto(`${clientBaseURL}/start-rar`);
    await page.getByLabel('Username:').fill('testuser');
    await page.getByLabel('Password:').fill('password');
    await page.getByRole('button', { name: 'Login' }).click();
    await page.getByRole('button', { name: 'Approve' }).click();
    await expect(page.getByTestId('token-type')).toHaveText('Bearer');
    const refreshToken = await page.getByTestId('rar-refresh-token').textContent();
    expect(refreshToken).not.toBe('');

    // RFC 9396 §6 narrowing is not supported: the request is refused with the
    // registered error code instead of being silently ignored.
    const rejected = await request.post(`${issuer}/token`, {
      form: {
        grant_type: 'refresh_token',
        refresh_token: refreshToken ?? '',
        client_id: clientId,
        client_secret: clientSecret,
        authorization_details: JSON.stringify([PAYMENT_DETAIL]),
      },
    });
    expect(rejected.status()).toBe(400);
    expect(await rejected.json()).toEqual({
      error: 'invalid_authorization_details',
      error_description: 'authorization_details is not accepted at the token endpoint',
    });

    // The rejection happened before any side effect: the presented refresh
    // token was neither rotated nor revoked, so the same token still works.
    const retried = await request.post(`${issuer}/token`, {
      form: {
        grant_type: 'refresh_token',
        refresh_token: refreshToken ?? '',
        client_id: clientId,
        client_secret: clientSecret,
      },
    });
    expect(retried.status()).toBe(200);
    const retriedBody = (await retried.json()) as { token_type: string; authorization_details?: unknown };
    expect(retriedBody.token_type).toBe('Bearer');
    expect(retriedBody.authorization_details).toEqual([PAYMENT_DETAIL]);
  });

  test('should complete the flow as before when the OP was generated without rar', async ({
    page,
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    test.skip(await rarAdvertised(request, issuer), 'This OP answers authorization_details');

    // Without the feature the parameter is an unknown request parameter: the
    // flow completes and no channel carries authorization_details.
    await page.goto(`${clientBaseURL}/start-rar`);
    await page.getByLabel('Username:').fill('testuser');
    await page.getByLabel('Password:').fill('password');
    await page.getByRole('button', { name: 'Login' }).click();
    await expect(page).toHaveURL(new RegExp(`^${escapeRegExp(issuer)}/consent$`));
    await page.getByRole('button', { name: 'Approve' }).click();

    await expect(page.getByTestId('token-type')).toHaveText('Bearer');
    await expect(page.getByTestId('rar-token-details')).toHaveText('null');
    await expect(page.getByTestId('rar-refresh-details')).toHaveText('null');
    await expect(page.getByTestId('rar-introspection-details')).toHaveText('null');
  });
});

interface DiscoveryMetadata {
  authorization_details_types_supported?: string[];
}

async function advertisedTypes(
  request: { get(url: string): Promise<{ json(): Promise<unknown> }> },
  issuer: string,
): Promise<string[] | undefined> {
  const response = await request.get(`${issuer}/.well-known/openid-configuration`);
  const metadata = (await response.json()) as DiscoveryMetadata;
  return metadata.authorization_details_types_supported;
}

async function rarAdvertised(
  request: { get(url: string): Promise<{ json(): Promise<unknown> }> },
  issuer: string,
): Promise<boolean> {
  return ((await advertisedTypes(request, issuer)) ?? []).includes('payment_initiation');
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

### E2E クライアントへの追加

`/start-rar` ルートと、認可 URL への `authorization_details` の付与、コールバック後の 3 チャネル観測である。

```javascript
    // EXPERIMENTAL (RFC 9396): run the ordinary code flow with an
    // authorization_details parameter (the payment_initiation example of
    // §2.1), then refresh and introspect to see the approved details come
    // back on every channel.
    if (req.method === 'GET' && url.pathname === '/start-rar') {
      await startAuthorization(url, res, { rar: true });
      return;
    }
```

```javascript
  // EXPERIMENTAL (RFC 9396 §3): the authorization_details parameter, a
  // URL-encoded JSON array shaped after the payment_initiation example of
  // §2.1. A spec overrides the type (?type=...) to drive the unknown-type
  // rejection of §5.
  if (options.rar === true) {
    authorizationUrl.searchParams.set('authorization_details', JSON.stringify([
      {
        type: requestUrl.searchParams.get('type') ?? 'payment_initiation',
        actions: ['initiate'],
        locations: ['https://example.com/payments'],
        instructedAmount: { currency: 'EUR', amount: '123.50' },
      },
    ]));
  }
```

```javascript
/**
 * EXPERIMENTAL — Rich Authorization Requests (RFC 9396 §7 / §9.2).
 *
 * Follows the approved details over every channel they travel on: the token
 * response of the code grant, the token response of a refresh (same grant),
 * and the introspection answer a resource server would get. The page prints
 * each one as JSON ('null' when the member is absent), plus the rotated
 * refresh token so a spec can drive the token-endpoint rejection of §6 with
 * it.
 */
async function completeRarInspection(res, tokens) {
  const refreshed = tokens.refresh_token === undefined
    ? null
    : await formPost(new URL('/token', issuer), {
      grant_type: 'refresh_token',
      refresh_token: tokens.refresh_token,
      client_id: clientId,
      client_secret: clientSecret,
    });
  const introspected = await formPost(new URL('/introspect', issuer), {
    token: (refreshed ?? tokens).access_token,
    client_id: clientId,
    client_secret: clientSecret,
  });
  sendHtml(res, 200, `<!doctype html>
<html>
  <head><title>RAR Complete</title></head>
  <body>
    <main>
      <h1>RAR Complete</h1>
      <dl>
        <dt>token type</dt><dd data-testid="token-type">${escapeHtml(tokens.token_type)}</dd>
        <dt>token details</dt><dd data-testid="rar-token-details">${escapeHtml(JSON.stringify(tokens.authorization_details ?? null))}</dd>
        <dt>refreshed details</dt><dd data-testid="rar-refresh-details">${escapeHtml(JSON.stringify(refreshed?.authorization_details ?? null))}</dd>
        <dt>refresh token</dt><dd data-testid="rar-refresh-token">${escapeHtml(refreshed?.refresh_token ?? '')}</dd>
        <dt>introspection active</dt><dd data-testid="rar-introspection-active">${escapeHtml(String(introspected.active))}</dd>
        <dt>introspection details</dt><dd data-testid="rar-introspection-details">${escapeHtml(JSON.stringify(introspected.authorization_details ?? null))}</dd>
      </dl>
    </main>
  </body>
</html>`);
}
```

## 関連資料

- [RFC 9396: OAuth 2.0 Rich Authorization Requests](https://datatracker.ietf.org/doc/html/rfc9396)
- 仕様タスク一式（specification / understanding-guide / sources / review-log）: `tasks/experimental/done/rar/`
- 利用者向けドキュメント: OSS リポジトリの `docs/library-document/src/content/docs/experimental/rar.md`
- 変更メモ: OSS リポジトリの `apps/map/changes/rar.md`
- 英語版: [rar.en.md](./rar.en.md)
