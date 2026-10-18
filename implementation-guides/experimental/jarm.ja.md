# JARM（JWT Secured Authorization Response Mode）実装解説

この文書は、`packages/experimental` に実装した **JARM**（JWT Secured Authorization Response Mode for OAuth 2.0、OpenID Foundation Final Specification 2022-11-09）について、何を実装したのか、どう実装したのかを、関連するコードの全文とともに説明する。

この文書が全文を載せるのは次のコードである。

- `packages/experimental/src/jarm/` の実装 3 ファイルとテスト 2 ファイルのすべて
- CLI の `--enable jarm` が生成コードへ加えるコードの全文（hono）
- JARM の E2E テストスペックの全文

core 本体、E2E 共有ハーネス、他フレームワークの生成コードは全機能で共有される基盤なので、リンクで参照する。

## 機能の概要

通常の Authorization Code Flow では、認可レスポンスは `code` と `state` を素のクエリパラメータとしてリダイレクト URL に載せて返る。
この応答には発行元の署名が無いため、クライアントは「この応答が本当に意図した OP から来たのか」「途中で書き換えられていないか」を応答単体からは確かめられない。
攻撃としては、別の OP の応答を混ぜ込む mix-up 攻撃や、応答パラメータの改ざんが該当する。

JARM は認可レスポンス全体を 1 つの署名付き JWT に包んで返す仕組みである。
`code` や `state` は JWT のクレームになり、そこへ発行者（`iss`）、宛先（`aud`）、有効期限（`exp`）が加わって、OP の鍵で署名される。
クライアントは JWKS で署名を検証してからクレームを取り出すので、応答の完全性、真正性、宛先、鮮度を暗号的に確認できる。

リクエスト側の入口は `response_mode` パラメータで、JARM は `query.jwt` / `fragment.jwt` / `form_post.jwt` / `jwt` の 4 値を追加する。
本 OP は `response_type=code` 専用なので、`query.jwt`（と、code フローではその別名になる省略形 `jwt`）だけを実装した。

```text
クライアント                               OP
    │  GET /authorize?response_mode=query.jwt&…  │
    │ ─────────────────────────────────────────> │ 通常どおり認証・同意
    │                                            │ 応答パラメータを JWT に署名
    │  302 redirect_uri?response=<signed JWT>    │
    │ <───────────────────────────────────────── │
    │  （JWKS で署名検証 → クレームから code を取得）
```

### ユースケース

- FAPI 系プロファイルが要求する応答の完全性保護を、手元のクライアント構成で検証する
- mix-up 攻撃対策（応答の発行者確認）をクライアント側でどう実装するかの検証
- 認可レスポンスの改ざん検知が必要な要件で、JARM の導入コストと挙動を確かめる

### 実装スコープと非目標

実装したのは次の範囲である。

- `response_mode` の分類（`query.jwt` / `jwt` を JARM モードとして解釈し、他の `.jwt` 系は非対応として報告する）
- JARM §2.1 のクレーム構造での応答 JWT の生成（成功応答とエラー応答の両方）と、§2.3.1 のリダイレクト URL の組み立て
- 応答 JWT の寿命設定と、§2.1 の推奨上限（10 分）に基づく起動時検証

非目標は次のとおりである。

- `fragment.jwt` / `form_post.jwt`（§2.3.2 / §2.3.3）。本 OP は code フロー専用なので対象にしない
- 応答 JWT の暗号化（JWE、§2.2）
- クライアント別の `authorization_signed_response_alg`（§3）。本 OP はクライアント別 alg を持たないため、§3 の既定である RS256 に固定する

## 実装の設計方針

ファイルは実装 2 つと公開 API で構成する。

| ファイル | 役割 |
|---|---|
| `response-mode.ts` | `response_mode` の分類 |
| `response-jwt.ts` | 応答 JWT の生成とリダイレクト URL の組み立て |
| `index.ts` | 公開 API の再エクスポートと、transaction への相乗り型 |

設計判断は 3 つある。

第一に、`response_mode` の分類は例外ではなく判別共用体で返す。
`unsupported-jwt-mode` を検出できる時点（パラメータ解釈時）と、それをリダイレクト可能なエラーにできる時点（`redirect_uri` 確定後）が呼び出し側で異なるためで、エラー化のタイミングを生成コードに委ねている。
非 `.jwt` の値（`query` や `form_post`）を従来どおり無視するのも意図的で、JARM は `.jwt` 系にだけ意味を足す拡張だから、JARM 有効化が既存リクエストの挙動を変えることはない。

第二に、署名は Web Crypto API（`crypto.subtle.sign`）で compact JWS を組み立てる自前実装である。
core にも同種の署名コードがあるが、非公開の低レベルヘルパーであり、core 無変更の制約下では使えない。
experimental 機能は独立性を優先して重複を許容する方針に従い、機能内に閉じた実装とした。

第三に、「JARM で応答すべきトランザクションである」という事実の記録は、core の `AuthTransaction` に**相乗り**させる。
core の interface は閉じているので、experimental は交差型 `JarmAuthTransactionFields`（`jarmResponseMode` フィールド）を定義している。
現在の生成コードはこの型を使わず、base の `endpoints/authorize/response-mode.ts` が定める `ResponseModeTransaction` の `responseMode` フィールドに、応答モードの名前 `query.jwt` を記録する（`create-transaction` ステップ）。
このため auth transaction store の実装には「未知フィールドを透過的に保存する」ことが契約として要求される。
オブジェクトを丸ごと JSON 化する通常の実装なら自然に満たされるが、フィールドを列挙してコピーする実装では記録が失われ、JARM を要求したクライアントへ静かに平文クエリで応答してしまう。

## 実装コードの全文と解説

### response-mode.ts（response_mode の分類）

`resolveJarmResponseMode` は認可リクエストの実効パラメータ（Request Object マージ後）を受け取り、3 値の判別共用体を返す。

- `{ kind: 'jarm', mode: 'query.jwt' }`：`query.jwt` または `jwt`。§2.3.4 により code フローの `jwt` は `query.jwt` と同義になる
- `{ kind: 'plain' }`：未指定、`query`、`form_post` など。挙動は一切変えない
- `{ kind: 'unsupported-jwt-mode', requested: … }`：`fragment.jwt` など、対応しない `.jwt` 終端値。呼び出し側が `invalid_request` にする

値の比較は大文字小文字を区別する（OAuth 2.0 Multiple Response Type Encoding Practices §2.1 の response_mode 値は case-sensitive）。
引数を `object` で受けているのは、core の `AuthorizationRequestParams`（index signature を持たない interface）と素の `Record<string, string>` の双方をそのまま渡せるようにするためで、文字列でない値（フレームワークのクエリパーサが配列を返す場合など）は解釈せず plain として扱う。

```typescript
/**
 * JWT Secured Authorization Response Mode (JARM) — response_mode interpretation.
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * JARM §2.3 は `query.jwt` / `fragment.jwt` / `form_post.jwt` / `jwt` の 4 値を
 * `response_mode` に追加する。この OP は `response_type=code` 専用なので
 * `query.jwt`（と §2.3.4 でその別名になる `jwt`）だけを実装する。
 */

/** JARM モードとして解釈するリクエスト値（JARM §2.3.1 / §2.3.4）。 */
export const JARM_SUPPORTED_RESPONSE_MODES = ['query.jwt', 'jwt'] as const;

/** 応答 JWT を運ぶクエリパラメータ名（JARM §2.3.1）。他の名前は使わない。 */
export const JARM_RESPONSE_PARAM = 'response';

/**
 * `response_mode` の分類結果。
 *
 * 例外ではなく判別共用体を返すのは、`unsupported-jwt-mode` を検出できる時点
 * （パラメータ解釈時）と、それをリダイレクト可能エラーにできる時点
 * （redirect_uri 確定後）が呼び出し側で異なるため。エラー化は生成コードが
 * core の `AuthorizationError('invalid_request', ...)` で行う。
 */
export type JarmResponseModeResolution =
  /** JARM モード。応答を JWT 化し `response` パラメータで返す。 */
  | { kind: 'jarm'; mode: 'query.jwt' }
  /** 従来どおりの平文クエリ応答。挙動は一切変わらない。 */
  | { kind: 'plain' }
  /** 本 OP が対応しない `.jwt` 系モード。呼び出し側が invalid_request にする。 */
  | { kind: 'unsupported-jwt-mode'; requested: string };

/**
 * 認可リクエストの `response_mode` を JARM の観点で分類する。
 *
 * - `query.jwt` / `jwt` → JARM モード（§2.3.4: `response_type=code` の既定運搬は
 *   `query.jwt` なので、省略形 `jwt` は `query.jwt` と同義）
 * - 未指定 / `query` / `form_post` / `fragment` / その他の非 `.jwt` 値 → 従来どおり
 *   無視する（隔離原則。JARM は `.jwt` 系にだけ意味を足す拡張であり、この OP が
 *   今まで response_mode を無視してきた挙動を JARM 有効化で変えない）
 * - `fragment.jwt` / `form_post.jwt` / その他の `.jwt` 終端値 → 非対応として報告
 *
 * 値の比較は大文字小文字を区別する（OAuth 2.0 Multiple Response Type Encoding
 * Practices §2.1 の response_mode 値は case-sensitive）。
 *
 * @param params 認可リクエストの実効パラメータ（Request Object マージ後）。
 *   `response_mode` 以外のキーは参照しない。
 */
export function resolveJarmResponseMode(params: object): JarmResponseModeResolution {
  // 引数を `object` で受けるのは、core の `AuthorizationRequestParams`（index
  // signature を持たない interface）と素の `Record<string, string>` の双方を
  // そのまま渡せるようにするため。値が文字列でない場合（フレームワークの
  // クエリパーサが配列を返す等）は解釈せず plain として扱う。
  const responseMode = (params as { response_mode?: unknown })['response_mode'];
  if (typeof responseMode !== 'string') {
    return { kind: 'plain' };
  }
  if ((JARM_SUPPORTED_RESPONSE_MODES as readonly string[]).includes(responseMode)) {
    return { kind: 'jarm', mode: 'query.jwt' };
  }
  if (responseMode.endsWith('.jwt')) {
    return { kind: 'unsupported-jwt-mode', requested: responseMode };
  }
  return { kind: 'plain' };
}
```

### response-jwt.ts（応答 JWT の生成）

`createJarmResponseJwt` が JARM §2.1 のクレーム構造で署名付き JWT を作る。

- JOSE ヘッダーは `{ alg: 'RS256', kid }`。JARM は応答 JWT の `typ` を規定しておらず、§2.3.1 の実例ヘッダーにも無いため付けない
- ペイロードは応答パラメータ（`code` / `state`、またはエラー系）に、§2.1 で必須の `iss` / `aud` / `exp` を加えたもの
- 値が `undefined` のパラメータはクレームに含めない。`state` の無いリクエストでは `state` クレーム自体が存在しない、という §2.1 の要求の実現である

`iss` / `aud` / `exp` を応答パラメータの後から代入している一行に注意してほしい。
これらは OP 自身の表明なので、上流から渡ったパラメータに同名の値があっても上書きされない、という保証を代入順で作っている。

署名アルゴリズムを RS256 に固定しているのは、クライアントが `authorization_signed_response_alg` を登録していない場合の §3 の既定が RS256 で、本 OP がクライアント別 alg を持たないためである。
固定であることの裏返しとして、渡す `signingKey` は RS256 鍵でなければならない。
RFC 7515 §4.1.1 の `alg` は「この JWS がどのアルゴリズムで署名されたか」の表明なので、別種の鍵で署名した JWS に `alg: RS256` を付けることは許されない。
実際には Web Crypto が鍵とアルゴリズムの不一致で例外を投げるため、そのような JWS が生成される余地はなく、失敗するのは署名処理そのものである。
生成コードは登録鍵セットから `selectSigningKeyByAlg(keys, 'RS256')` で鍵を選ぶ（active key はこの契約を満たす保証がない）。

`buildJarmRedirectUrl` はリダイレクト URL に `response` パラメータ（§2.3.1）だけを付ける。
素の `code` / `state` / `iss` は付けない。
issuer の識別は JWT の `iss` クレームが担うからである。

`assertJarmLifetimeSeconds` は寿命設定（5〜600 秒の整数）の起動時検証で、生成コードが `jarmConfig` の宣言直後に呼ぶ。

```typescript
/**
 * JWT Secured Authorization Response Mode (JARM) — response JWT generation.
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * JARM §2.1 のクレーム構造で認可レスポンスを署名付き JWT にする。署名は Web
 * Crypto API（`crypto.subtle.sign`）で compact JWS を組み立てる自前実装であり、
 * core の非公開な低レベル署名ヘルパーには依存しない（core 無変更の維持）。
 * core 内部と同種のコードになるが、Experimental 機能は独立性を優先して重複を
 * 許容する方針に従う。
 */
import type { SigningKey } from '@maronn-openid-connect/core';

/** 応答 JWT の寿命の下限（秒）。 */
const MIN_LIFETIME_SECONDS = 5;

/**
 * 応答 JWT の寿命の上限（秒）。
 *
 * JARM §2.1: "The JWT MUST have an expiration time ... A maximum lifetime of 10
 * minutes is RECOMMENDED."
 */
const MAX_LIFETIME_SECONDS = 600;

/** 設定が省略されたときの寿命（秒）。 */
const DEFAULT_LIFETIME_SECONDS = 60;

/**
 * 応答 JWT の署名アルゴリズム。
 *
 * JARM §3: クライアントが `authorization_signed_response_alg` を登録していない
 * 場合の既定は RS256。この OP はクライアント別 alg を持たないため RS256 固定と
 * する。設定で変更できないので、クライアントが §2.4 で拒否する `alg: none` を
 * この OP が生成することはない。
 *
 * 固定であることの裏返しとして、{@link createJarmResponseJwt} に渡す `signingKey`
 * は **RS256 鍵でなければならない**。RFC 7515 §4.1.1 の `alg` は「この JWS が
 * どのアルゴリズムで署名されたか」の表明であり、別種の鍵で署名した JWS に
 * `alg: RS256` を付けることは許されない。実際には Web Crypto が鍵と
 * アルゴリズムの不一致で例外を投げるため、そのような JWS が生成されることは
 * ない（署名偽造の余地は無く、失敗するのは署名処理そのもの）。
 */
const RESPONSE_SIGNING_ALG = 'RS256';

/** RS256 に対応する Web Crypto のアルゴリズム名。 */
const WEB_CRYPTO_ALGORITHM = 'RSASSA-PKCS1-v1_5';

function base64UrlFromBytes(bytes: Uint8Array): string {
  let binary = '';
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function base64UrlFromJson(value: Record<string, unknown>): string {
  return base64UrlFromBytes(new TextEncoder().encode(JSON.stringify(value)));
}

/**
 * 応答 JWT の寿命設定を起動時に検証する（JARM §2.1）。
 *
 * 生成コードは `jarmConfig` の宣言直後にこれを呼び、範囲外の設定を持つ OP が
 * 起動できないようにする。
 *
 * @throws {Error} 5〜600 秒の整数でない場合
 */
export function assertJarmLifetimeSeconds(value: number): void {
  if (
    !Number.isInteger(value) ||
    value < MIN_LIFETIME_SECONDS ||
    value > MAX_LIFETIME_SECONDS
  ) {
    throw new Error(
      `jarmConfig.jarmResponseLifetimeSeconds must be an integer between ${MIN_LIFETIME_SECONDS} and ${MAX_LIFETIME_SECONDS} seconds (JARM Section 2.1), got ${value}`,
    );
  }
}

/**
 * 認可レスポンスパラメータを JARM §2.1 のクレーム構造で署名付き JWT にする。
 *
 * - JOSE ヘッダー: `{ alg: 'RS256', kid: signingKey.keyId }`。JARM は応答 JWT の
 *   `typ` を規定しておらず §2.3.1 の実例ヘッダーにも無いため付けない。
 * - ペイロード: `iss` / `aud` / `exp`（いずれも §2.1 で REQUIRED）＋ 応答パラメータ。
 *   値が `undefined` のパラメータはクレームに含めない（`state` が無いリクエスト
 *   では `state` クレーム自体が存在しない、という §2.1 の要求の実現）。
 * - `iss` / `aud` / `exp` は `parameters` から上書きできない。これらは OP 自身の
 *   表明であり、上流から渡った値で書き換えられてはならない。
 *
 * `error_description` を渡す場合は、呼び出し側が core の
 * `sanitizeErrorDescription` を通した文字列を渡すこと。
 *
 * @param options.issuer `iss` クレーム（OP の issuer）
 * @param options.clientId `aud` クレーム（応答先クライアント）
 * @param options.parameters 認可レスポンスパラメータ（code/state または error 系）
 * @param options.signingKey 応答 JWT の署名鍵。**RS256 鍵であること**（JOSE ヘッダの
 *   `alg` は常に RS256 固定なので、他の alg の鍵を渡すと Web Crypto が署名を拒否して
 *   例外になる）。生成コードは登録鍵セットから `selectSigningKeyByAlg(keys, 'RS256')`
 *   で選ぶこと。active key はこの契約を満たす保証がない。
 * @param options.lifetimeSeconds `exp` までの秒数（既定 60）
 * @param options.now 発行時刻（テスト用の注入点。既定は現在時刻）
 */
export async function createJarmResponseJwt(options: {
  issuer: string;
  clientId: string;
  parameters: Record<string, string | undefined>;
  signingKey: SigningKey;
  lifetimeSeconds?: number;
  now?: Date;
}): Promise<string> {
  const lifetimeSeconds = options.lifetimeSeconds ?? DEFAULT_LIFETIME_SECONDS;
  const issuedAtSeconds = Math.floor((options.now ?? new Date()).getTime() / 1000);

  const claims: Record<string, string | number> = {};
  for (const [name, value] of Object.entries(options.parameters)) {
    if (value !== undefined) {
      claims[name] = value;
    }
  }
  // JARM §2.1: iss / aud / exp are REQUIRED. Assigned after the response
  // parameters so a parameter of the same name can never restate them.
  claims['iss'] = options.issuer;
  claims['aud'] = options.clientId;
  claims['exp'] = issuedAtSeconds + lifetimeSeconds;

  const encodedHeader = base64UrlFromJson({
    alg: RESPONSE_SIGNING_ALG,
    kid: options.signingKey.keyId,
  });
  const encodedPayload = base64UrlFromJson(claims);
  const signingInput = `${encodedHeader}.${encodedPayload}`;

  const signature = await crypto.subtle.sign(
    WEB_CRYPTO_ALGORITHM,
    options.signingKey.privateKey,
    new TextEncoder().encode(signingInput),
  );

  return `${signingInput}.${base64UrlFromBytes(new Uint8Array(signature))}`;
}

/**
 * JARM モードのリダイレクト URL を組み立てる（JARM §2.3.1）。
 *
 * 付与するのは `response` パラメータのみ。素の `code` / `state` / `iss` は付けない
 * （issuer 識別は JWT の `iss` クレームが担う）。
 */
export function buildJarmRedirectUrl(redirectUri: string, responseJwt: string): string {
  const url = new URL(redirectUri);
  url.searchParams.set('response', responseJwt);
  return url.toString();
}
```

### index.ts（公開 API と transaction への相乗り型）

subpath export `@maronn-openid-connect/experimental/jarm` の実体である。
`JarmAuthTransactionFields` の JSDoc に、auth transaction store への契約要件（未知フィールドの透過的な保存）を明記している。

```typescript
/**
 * JWT Secured Authorization Response Mode (JARM) — OpenID Foundation Final
 * Specification (2022-11-09)
 *
 * **Experimental**: この機能の API は安定していない。マイナーリリースでも
 * 破壊的に変更されることがある。本番運用の前に
 * `docs/library-document` の Experimental セクションを確認すること。
 *
 * `@maronn-openid-connect/core` とは別 package であり、CLI で `--enable jarm` を
 * 明示したときのみ生成コードから利用される。
 *
 * 初期スコープは `query.jwt`（と省略形 `jwt`）の**署名のみ**に限定する。
 * `fragment.jwt` / `form_post.jwt`（§2.3.2 / §2.3.3）・応答 JWT の暗号化（JWE,
 * §2.2）・クライアント別 `authorization_signed_response_alg`（§3）は非対応。
 */
export {
  JARM_RESPONSE_PARAM,
  JARM_SUPPORTED_RESPONSE_MODES,
  resolveJarmResponseMode,
  type JarmResponseModeResolution,
} from './response-mode.js';

export {
  assertJarmLifetimeSeconds,
  buildJarmRedirectUrl,
  createJarmResponseJwt,
} from './response-jwt.js';

/**
 * core の `AuthTransaction`（closed interface）に JARM モードを相乗りさせるための
 * 交差型。
 *
 * 生成コードは transaction を store へ put するときに
 * `{ ...transaction, jarmResponseMode: 'query.jwt' }` を保存し、get 後にこの型
 * として読む。**auth transaction store の実装は未知フィールドを透過的に保存する
 * 必要がある**（契約要件。オブジェクトを丸ごと JSON 化する通常の実装なら自然に
 * 満たされる。フィールドを列挙してコピーする実装ではこの記録が失われ、JARM を
 * 要求したクライアントへ静かに平文クエリで応答してしまう）。
 */
export type JarmAuthTransactionFields = {
  /** JARM モードで応答すべきトランザクションであることの記録。無指定は平文応答。 */
  jarmResponseMode?: 'query.jwt';
};
```

## 単体テストの全文

`response-mode.test.ts` は分類の全経路を固定する。

- `query.jwt` と `jwt` が JARM モードになること
- 未指定、`query`、`form_post`、`fragment`、その他の非 `.jwt` 値、文字列でない値が plain になること
- `QUERY.JWT` のような大文字違いが JARM モードにならないこと（case-sensitive）
- `fragment.jwt` / `form_post.jwt` などの `.jwt` 終端値が `unsupported-jwt-mode` として報告されること

```typescript
import { describe, expect, it } from 'vitest';
import { JARM_SUPPORTED_RESPONSE_MODES, resolveJarmResponseMode } from './response-mode.js';

describe('resolveJarmResponseMode', () => {
  // JARM §2.3.1 / §2.3.4: query.jwt is the only mode this OP implements, and the
  // shorthand `jwt` resolves to it for response_type=code.
  describe('JARM modes', () => {
    it('should resolve response_mode=query.jwt to the query.jwt JARM mode', () => {
      expect(resolveJarmResponseMode({ response_mode: 'query.jwt' })).toEqual({
        kind: 'jarm',
        mode: 'query.jwt',
      });
    });

    it('should resolve the shorthand response_mode=jwt to the query.jwt JARM mode', () => {
      expect(resolveJarmResponseMode({ response_mode: 'jwt' })).toEqual({
        kind: 'jarm',
        mode: 'query.jwt',
      });
    });
  });

  // The generated OP does not interpret response_mode at all today. JARM only
  // adds meaning to the `.jwt` family; every other value keeps the current
  // (ignore it) behavior so enabling the feature changes nothing else.
  describe('Plain (unchanged) modes', () => {
    it('should resolve an absent response_mode to plain', () => {
      expect(resolveJarmResponseMode({})).toEqual({ kind: 'plain' });
    });

    it('should resolve an explicitly undefined response_mode to plain', () => {
      expect(resolveJarmResponseMode({ response_mode: undefined })).toEqual({ kind: 'plain' });
    });

    it('should resolve response_mode=query to plain', () => {
      expect(resolveJarmResponseMode({ response_mode: 'query' })).toEqual({ kind: 'plain' });
    });

    it('should resolve response_mode=form_post to plain', () => {
      expect(resolveJarmResponseMode({ response_mode: 'form_post' })).toEqual({ kind: 'plain' });
    });

    it('should resolve response_mode=fragment to plain', () => {
      expect(resolveJarmResponseMode({ response_mode: 'fragment' })).toEqual({ kind: 'plain' });
    });

    // フレームワークのクエリパーサが文字列以外（配列など）を返す場合でも、
    // JARM モードとして解釈しない。
    it('should resolve a non-string response_mode to plain', () => {
      expect(resolveJarmResponseMode({ response_mode: 42 } as object)).toEqual({ kind: 'plain' });
    });

    it('should resolve an empty response_mode to plain', () => {
      expect(resolveJarmResponseMode({ response_mode: '' })).toEqual({ kind: 'plain' });
    });

    // response_mode values are case-sensitive (OAuth 2.0 Multiple Response Type
    // Encoding Practices §2.1), so QUERY.JWT is not the JARM mode.
    it('should resolve an uppercase QUERY.JWT to plain', () => {
      expect(resolveJarmResponseMode({ response_mode: 'QUERY.JWT' })).toEqual({ kind: 'plain' });
    });
  });

  // JARM §2.3.2 / §2.3.3: fragment.jwt and form_post.jwt exist in the spec but
  // are non-goals here, so they are reported to the caller which turns them into
  // a redirectable invalid_request.
  describe('Unsupported JWT modes', () => {
    it('should report fragment.jwt as an unsupported JWT mode', () => {
      expect(resolveJarmResponseMode({ response_mode: 'fragment.jwt' })).toEqual({
        kind: 'unsupported-jwt-mode',
        requested: 'fragment.jwt',
      });
    });

    it('should report form_post.jwt as an unsupported JWT mode', () => {
      expect(resolveJarmResponseMode({ response_mode: 'form_post.jwt' })).toEqual({
        kind: 'unsupported-jwt-mode',
        requested: 'form_post.jwt',
      });
    });

    it('should report an unknown .jwt value as an unsupported JWT mode', () => {
      expect(resolveJarmResponseMode({ response_mode: 'foo.jwt' })).toEqual({
        kind: 'unsupported-jwt-mode',
        requested: 'foo.jwt',
      });
    });

    it('should report a bare .jwt value as an unsupported JWT mode', () => {
      expect(resolveJarmResponseMode({ response_mode: '.jwt' })).toEqual({
        kind: 'unsupported-jwt-mode',
        requested: '.jwt',
      });
    });
  });
});

describe('JARM_SUPPORTED_RESPONSE_MODES', () => {
  it('should list exactly the request values that select JARM', () => {
    expect(JARM_SUPPORTED_RESPONSE_MODES).toEqual(['query.jwt', 'jwt']);
  });
});
```

`response-jwt.test.ts` は JWT 生成を、実際に署名検証しながら固定する。

- JOSE ヘッダーの形（`alg: RS256`、`kid`、`typ` を付けないこと）
- 成功応答のクレーム（`code` / `state` / `iss` / `aud` / `exp`、`undefined` パラメータの不在、`iss` / `aud` / `exp` がパラメータから上書きできないこと、`exp` の計算）
- エラー応答のクレーム（`error` / `error_description`、`code` が含まれないこと）
- 署名が公開鍵で検証できること、別の鍵では検証できないこと
- リダイレクト URL の組み立て（`response` パラメータのみが付くこと、既存クエリの保持）
- 寿命設定の境界値（5 と 600 を受理し、範囲外と非整数を拒否）

```typescript
import type { SigningKey } from '@maronn-openid-connect/core';
import { beforeAll, describe, expect, it } from 'vitest';
import {
  assertJarmLifetimeSeconds,
  buildJarmRedirectUrl,
  createJarmResponseJwt,
} from './response-jwt.js';

function decodeSegment(segment: string): Record<string, unknown> {
  const base64 = segment.replace(/-/g, '+').replace(/_/g, '/');
  const padded = base64.padEnd(base64.length + ((4 - (base64.length % 4)) % 4), '=');
  const bytes = Uint8Array.from(atob(padded), (char) => char.charCodeAt(0));
  return JSON.parse(new TextDecoder().decode(bytes)) as Record<string, unknown>;
}

function header(jwt: string): Record<string, unknown> {
  return decodeSegment(jwt.split('.')[0] ?? '');
}

function payload(jwt: string): Record<string, unknown> {
  return decodeSegment(jwt.split('.')[1] ?? '');
}

function signatureBytes(jwt: string): Uint8Array {
  const segment = jwt.split('.')[2] ?? '';
  const base64 = segment.replace(/-/g, '+').replace(/_/g, '/');
  const padded = base64.padEnd(base64.length + ((4 - (base64.length % 4)) % 4), '=');
  return Uint8Array.from(atob(padded), (char) => char.charCodeAt(0));
}

// 2026-08-04T00:00:00Z. Injected so every exp assertion is a fixed value.
const NOW = new Date('2026-08-04T00:00:00.000Z');
const NOW_SECONDS = 1785801600;

let signingKey: SigningKey;
let publicKey: CryptoKey;

beforeAll(async () => {
  const keyPair = await crypto.subtle.generateKey(
    {
      name: 'RSASSA-PKCS1-v1_5',
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: 'SHA-256',
    },
    true,
    ['sign', 'verify'],
  );
  const publicJwk = await crypto.subtle.exportKey('jwk', keyPair.publicKey);
  signingKey = { privateKey: keyPair.privateKey, publicJwk, keyId: 'jarm-key-1' };
  publicKey = keyPair.publicKey;
});

describe('createJarmResponseJwt', () => {
  describe('JOSE Header', () => {
    // JARM §2.2 / §3: the OP signs with RS256 (the default when the client
    // registered no authorization_signed_response_alg). alg is not configurable,
    // so `none` (rejected by clients per §2.4) can never be produced.
    it('should set alg to RS256 and kid to the signing key id without a typ header', async () => {
      const jwt = await createJarmResponseJwt({
        issuer: 'http://localhost:3000',
        clientId: 'my-client',
        parameters: { code: 'auth-code-1' },
        signingKey,
        now: NOW,
      });

      expect(header(jwt)).toEqual({ alg: 'RS256', kid: 'jarm-key-1' });
    });
  });

  describe('Success response claims', () => {
    // JARM §2.1: iss / aud / exp are REQUIRED, and the authorization response
    // parameters travel as claims of the same JWT.
    it('should carry iss, aud, exp, code and state as claims', async () => {
      const jwt = await createJarmResponseJwt({
        issuer: 'http://localhost:3000',
        clientId: 'my-client',
        parameters: { code: 'auth-code-1', state: 'S8NJ7' },
        signingKey,
        now: NOW,
      });

      expect(payload(jwt)).toEqual({
        iss: 'http://localhost:3000',
        aud: 'my-client',
        exp: NOW_SECONDS + 60,
        code: 'auth-code-1',
        state: 'S8NJ7',
      });
    });

    // JARM §2.1: state is present in the response only when the request had one.
    it('should omit the state claim entirely when state is undefined', async () => {
      const jwt = await createJarmResponseJwt({
        issuer: 'http://localhost:3000',
        clientId: 'my-client',
        parameters: { code: 'auth-code-1', state: undefined },
        signingKey,
        now: NOW,
      });

      expect(payload(jwt)).toEqual({
        iss: 'http://localhost:3000',
        aud: 'my-client',
        exp: NOW_SECONDS + 60,
        code: 'auth-code-1',
      });
    });

    it('should default the response JWT lifetime to 60 seconds', async () => {
      const jwt = await createJarmResponseJwt({
        issuer: 'http://localhost:3000',
        clientId: 'my-client',
        parameters: { code: 'auth-code-1' },
        signingKey,
        now: NOW,
      });

      expect(payload(jwt)['exp']).toBe(NOW_SECONDS + 60);
    });

    it('should set exp to now plus the requested lifetime', async () => {
      const jwt = await createJarmResponseJwt({
        issuer: 'http://localhost:3000',
        clientId: 'my-client',
        parameters: { code: 'auth-code-1' },
        signingKey,
        lifetimeSeconds: 600,
        now: NOW,
      });

      expect(payload(jwt)['exp']).toBe(NOW_SECONDS + 600);
    });

    // Sub-second precision must not leak into exp: JWT NumericDate is seconds.
    it('should floor exp to whole seconds', async () => {
      const jwt = await createJarmResponseJwt({
        issuer: 'http://localhost:3000',
        clientId: 'my-client',
        parameters: { code: 'auth-code-1' },
        signingKey,
        now: new Date(NOW.getTime() + 999),
      });

      expect(payload(jwt)['exp']).toBe(NOW_SECONDS + 60);
    });

    // The protocol claims are the OP's own statement about the response. A
    // caller-supplied parameter of the same name must not be able to restate it.
    it('should keep iss, aud and exp non-overridable by response parameters', async () => {
      const jwt = await createJarmResponseJwt({
        issuer: 'http://localhost:3000',
        clientId: 'my-client',
        parameters: {
          code: 'auth-code-1',
          iss: 'https://evil.example',
          aud: 'other-client',
          exp: '9999999999',
        },
        signingKey,
        now: NOW,
      });

      expect(payload(jwt)).toEqual({
        iss: 'http://localhost:3000',
        aud: 'my-client',
        exp: NOW_SECONDS + 60,
        code: 'auth-code-1',
      });
    });
  });

  describe('Error response claims', () => {
    // JARM §2.1 error example: the error response is the same JWT shape with
    // error / error_description / state instead of code.
    it('should carry error, error_description and state as claims', async () => {
      const jwt = await createJarmResponseJwt({
        issuer: 'http://localhost:3000',
        clientId: 'my-client',
        parameters: {
          error: 'access_denied',
          error_description: 'User denied the request',
          state: 'S8NJ7',
        },
        signingKey,
        now: NOW,
      });

      expect(payload(jwt)).toEqual({
        iss: 'http://localhost:3000',
        aud: 'my-client',
        exp: NOW_SECONDS + 60,
        error: 'access_denied',
        error_description: 'User denied the request',
        state: 'S8NJ7',
      });
    });

    it('should omit error_description when it is undefined', async () => {
      const jwt = await createJarmResponseJwt({
        issuer: 'http://localhost:3000',
        clientId: 'my-client',
        parameters: {
          error: 'access_denied',
          error_description: undefined,
          state: 'S8NJ7',
        },
        signingKey,
        now: NOW,
      });

      expect(payload(jwt)).toEqual({
        iss: 'http://localhost:3000',
        aud: 'my-client',
        exp: NOW_SECONDS + 60,
        error: 'access_denied',
        state: 'S8NJ7',
      });
    });
  });

  describe('Signature', () => {
    // JARM §2.4: the client verifies the JWS with a key resolved from the OP's
    // jwks_uri via kid. The compact serialization must therefore verify against
    // the public half of the signing key.
    it('should produce a compact JWS that verifies with the signing key public half', async () => {
      const jwt = await createJarmResponseJwt({
        issuer: 'http://localhost:3000',
        clientId: 'my-client',
        parameters: { code: 'auth-code-1', state: 'S8NJ7' },
        signingKey,
        now: NOW,
      });
      const [encodedHeader, encodedPayload] = jwt.split('.');
      const verified = await crypto.subtle.verify(
        'RSASSA-PKCS1-v1_5',
        publicKey,
        signatureBytes(jwt),
        new TextEncoder().encode(`${encodedHeader}.${encodedPayload}`),
      );

      expect(verified).toBe(true);
    });

    it('should produce exactly three base64url segments', async () => {
      const jwt = await createJarmResponseJwt({
        issuer: 'http://localhost:3000',
        clientId: 'my-client',
        parameters: { code: 'auth-code-1' },
        signingKey,
        now: NOW,
      });

      expect(jwt.split('.')).toHaveLength(3);
      expect(/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(jwt)).toBe(true);
    });

    // JARM §3 / RFC 7515 §4.1.1: this function always declares `alg: RS256`, so
    // the JOSE header would lie about the signature if it accepted another key
    // type. Web Crypto refuses to sign with a mismatched key, which is what pins
    // the contract "signingKey MUST be an RS256 key" — the caller (the CLI
    // generated code) is responsible for selecting one.
    it('should reject an ES256 signing key instead of signing under the RS256 header', async () => {
      const ecdsaKeyPair = await crypto.subtle.generateKey(
        { name: 'ECDSA', namedCurve: 'P-256' },
        true,
        ['sign', 'verify'],
      );
      const ecdsaPublicJwk = await crypto.subtle.exportKey('jwk', ecdsaKeyPair.publicKey);

      await expect(
        createJarmResponseJwt({
          issuer: 'http://localhost:3000',
          clientId: 'my-client',
          parameters: { code: 'auth-code-1' },
          signingKey: {
            privateKey: ecdsaKeyPair.privateKey,
            publicJwk: ecdsaPublicJwk,
            keyId: 'es256-key',
          },
          now: NOW,
        }),
      ).rejects.toThrow();
    });

    // Non-ASCII claim values must survive as UTF-8 before base64url encoding.
    it('should encode non-ASCII claim values as UTF-8', async () => {
      const jwt = await createJarmResponseJwt({
        issuer: 'http://localhost:3000',
        clientId: 'クライアント',
        parameters: { code: 'auth-code-1' },
        signingKey,
        now: NOW,
      });

      expect(payload(jwt)['aud']).toBe('クライアント');
    });
  });
});

describe('buildJarmRedirectUrl', () => {
  // JARM §2.3.1: the response is delivered as the single `response` query
  // parameter. No plain code / state / iss parameter is added.
  it('should append only the response parameter to the redirect URI', () => {
    expect(buildJarmRedirectUrl('https://client.example.com/cb', 'header.payload.signature')).toBe(
      'https://client.example.com/cb?response=header.payload.signature',
    );
  });

  it('should preserve query parameters already present on the redirect URI', () => {
    expect(buildJarmRedirectUrl('https://client.example.com/cb?tenant=a', 'a.b.c')).toBe(
      'https://client.example.com/cb?tenant=a&response=a.b.c',
    );
  });

  it('should replace an existing response parameter instead of appending a second one', () => {
    expect(buildJarmRedirectUrl('https://client.example.com/cb?response=stale', 'a.b.c')).toBe(
      'https://client.example.com/cb?response=a.b.c',
    );
  });
});

describe('assertJarmLifetimeSeconds', () => {
  // JARM §2.1: "The JWT MUST have an expiration time (exp) ... a maximum
  // lifetime of 10 minutes is RECOMMENDED."
  describe('Accepted values', () => {
    it('should accept the lower bound of 5 seconds', () => {
      expect(() => assertJarmLifetimeSeconds(5)).not.toThrow();
    });

    it('should accept the upper bound of 600 seconds', () => {
      expect(() => assertJarmLifetimeSeconds(600)).not.toThrow();
    });

    it('should accept the default of 60 seconds', () => {
      expect(() => assertJarmLifetimeSeconds(60)).not.toThrow();
    });
  });

  describe('Rejected values', () => {
    it('should reject 4 seconds as below the lower bound', () => {
      expect(() => assertJarmLifetimeSeconds(4)).toThrow(
        'jarmConfig.jarmResponseLifetimeSeconds must be an integer between 5 and 600 seconds (JARM Section 2.1), got 4',
      );
    });

    it('should reject 601 seconds as above the upper bound', () => {
      expect(() => assertJarmLifetimeSeconds(601)).toThrow(
        'jarmConfig.jarmResponseLifetimeSeconds must be an integer between 5 and 600 seconds (JARM Section 2.1), got 601',
      );
    });

    it('should reject a non-integer lifetime', () => {
      expect(() => assertJarmLifetimeSeconds(60.5)).toThrow(
        'jarmConfig.jarmResponseLifetimeSeconds must be an integer between 5 and 600 seconds (JARM Section 2.1), got 60.5',
      );
    });

    it('should reject NaN', () => {
      expect(() => assertJarmLifetimeSeconds(Number.NaN)).toThrow(
        'jarmConfig.jarmResponseLifetimeSeconds must be an integer between 5 and 600 seconds (JARM Section 2.1), got NaN',
      );
    });
  });
});
```

## CLI 統合と生成コードへの寄与

experimental 本体はロジック層であり、認可レスポンスを応答 JWT にして返すのは CLI が生成するコードである。
生成コードは、全機能を有効にして動かしているアプリ [apps/hono](../../../apps/hono) の `src/oidc-provider/` から、CLI が抜き出したものである。
`maronn-oidc generate <framework> --enable jarm` を指定すると、生成コードに次の 3 つが入る。

- **`features/jarm/` ディレクトリ**：JARM が所有するファイルのすべて。`feature.ts` が `defineFeature()` で機能を宣言し、`authorize.responseModes` フックで `query.jwt` の応答モードを `/consent` に復元させ、`discovery` フックで `response_modes_supported` に `query.jwt` と `jwt` を、`authorization_signing_alg_values_supported` に `RS256` を加える。`routes` は持たないので、新しい HTTP ルートは増えない（JARM は応答の運び方の変更であり、エンドポイントの追加ではない）
- **`features/enabled.ts` の 2 行**：`jarm` の import 行と、機能の一覧 `features` の 1 項目
- **`endpoints/authorize/pipeline.ts` の所有者付きブロック 1 つ**：`[resolve-jarm-response-mode]` ブロックが、base の `[resolve-redirect-uri]` と `[validate-request]` のあいだで `response_mode` を解釈し、JWT で応答するリクエストなら応答モード `responseMode` を決める。ブロックが呼ぶステップの import 行も、ファイル先頭に 1 行入る

フックが受け渡すのは、ルート、メタデータ、応答モードのハンドラのように、base が決まった場所で読む宣言的な値である。
base のパイプラインの途中で動く処理はフックにせず、そのパイプラインの中に、機能の名前を書いた目印のコメントで始まるブロックとして置く。
目印のコメントは `// [step-id] (feature: <feature-id>)` で始まり、次の目印の直前までがそのブロックになる。
このブロックを **所有者付きブロック** と呼ぶ。
`--enable jarm` を付けずに生成すると、CLI は JARM のブロックと、そのブロックだけが使っていた import 行を削除する。
`responseMode` は base が `try` の外で `let` として宣言しているので、ブロックがなければ `undefined`（平文の query 応答）のまま残り、後続のステップも `catch` もその値を読める。

応答の経路は次のとおりである。
`GET /authorize` では、base の `endpoints/authorize/pipeline.ts` が `redirect_uri` を確定した直後に、JARM のブロックが `responseMode` を決める。
`[create-transaction]` はその名前（`query.jwt`）を transaction に記録し、その場で応答するステップ（prompt=none、SSO、エラー）は `responseMode.redirect()` で応答 JWT を組み立てる。
ログインと同意を経る応答は別のリクエストで返るので、`/consent` の `[build-authorization-response]` ステップが、`endpoints/authorize/response-mode.ts` の `restoreResponseMode()` で transaction の記録から応答モードを復元し、成功も拒否も JWT で返す。
discovery では、`features/feature.ts` の `discoveryOf()` が JARM の `discovery` フックの配列を base の配列にまとめ、`response_modes_supported` は `query`、`query.jwt`、`jwt` になる。

この配置には 3 つの設計判断がある。

第一に、`response_mode` の解釈を所有者付きブロックにしたのは、置く位置が仕様の要件から決まるからである。
対応しない `.jwt` 系のモード（`fragment.jwt` と `form_post.jwt`）の拒否はリダイレクトで返すエラーなので、`redirect_uri` の確定より後でなければならない。
また、`[create-transaction]` より前でなければ記録が残らず、`[validate-request]` より前に置くことで、パラメータ検証のエラーも JWT で返る。
ブロックの中で投げる拒否そのものは、`responseMode` が決まる前なので平文の query で返る（OP は実装していない応答モードでは応答できない）。

第二に、`/consent` での復元をフックにしたのは、同意の画面を経る応答が別のリクエストで返るからである。
認可エンドポイントのパイプラインの局所変数は `/consent` に届かないので、transaction に記録した名前と、名前から応答モードを作り直すハンドラの組で受け渡す。
`restoreResponseMode()` は有効な機能のハンドラから記録された名前を扱うものを探し、見つからなければ例外を投げるので、`/consent` は 500 のエラーで失敗する。
transaction を作った後で JARM を外した OP が、JWT を求めたクライアントへ黙って平文の query で応答することはない。

第三に、署名鍵は `signingKeys` の先頭ではなく、`selectJarmSigningKey()` が RS256 の鍵を選ぶ。
応答 JWT の `alg` は常に RS256（JARM §3 の既定）で、discovery もそれだけを広告するので、ES256 の鍵が先頭にある鍵セットでも `alg` と鍵が食い違わない。
RS256 の鍵が登録されていなければ `selectSigningKeyByAlg` が例外を投げ、応答は検証できない JWT ではなく 500 のエラーになる。

サンプルでこの機能を有効にしているのは [samples/hono-cloudflare](../../../samples/hono-cloudflare) だけである。
他の機能と組み合わせた生成結果は、そのサンプルの `src/oidc-provider/` で確認できる。
サンプルの `src/app.ts` は JARM の設定に手を加えず、生成された既定値のまま動かしている。

### 生成コードに入るコードの全文（hono）

以下は、デフォルトの機能に `--enable jarm` を加えて hono 向けに生成した結果のうち、JARM が加えるもののすべてである。
`features/enabled.ts` と認可エンドポイントのパイプラインについては加わる行とブロックを、`features/jarm/` についてはファイルの全文を、生成されたファイルからそのまま写している。

#### `features/enabled.ts` に入る行

`features/enabled.ts` は、この OP が持つ機能の一覧である。
CLI は有効な機能ごとに import 行を 1 行と、配列 `features` の項目を 1 つ書く。
配列の順序はフックを適用する順序で、JARM は既定の機能（`pkce` から `request-object` まで）の後ろに並ぶ。

```typescript
import { jarm } from './jarm/feature.js';
```

```typescript
  jarm,
```

#### `endpoints/authorize/pipeline.ts` の `(feature: jarm)` ブロック

認可エンドポイントのパイプラインは、ファイル先頭で、ブロックが呼ぶ JARM のステップを import する。

```typescript
import { resolveJarmResponseContext } from '../../features/jarm/steps/resolve-jarm-response-mode.js';
```

ブロックは `[resolve-redirect-uri]` ブロックの直後、`[validate-request]` ブロックの直前で動く。
Request Object を重ねた後のパラメータ（`effectiveParams ?? params`）、確定した `redirectUri` と `state`、issuer を `resolveJarmResponseContext()` に渡し、返った応答モードを base の `responseMode` に代入する。
JWT の応答を求めないリクエストでは `undefined` が返り、応答は従来どおり平文の query になる。

```typescript
    // [resolve-jarm-response-mode] (feature: jarm) Interpret response_mode=query.jwt — JARM §2.3 / §3
    responseMode = resolveJarmResponseContext(c, effectiveParams ?? params, client, redirectUri, state, issuer);
```

#### `features/jarm/feature.ts`

JARM が base に差し込むものを宣言するファイルで、`features/enabled.ts` が import するのはこのファイルである。
`authorize.responseModes` に置いた `jarmResponseModeHandler` が、`/consent` で `query.jwt` を記録した transaction の応答モードを作り直す。
`discovery` は JARM §4 のメタデータを返し、`response_modes_supported` の配列は base の `['query']` にまとめられる。
`authorization_signing_alg_values_supported` を `RS256` 1 つにしているのは、応答 JWT を常に RS256 で署名するからである。
`routes` と `context` は持たない。

```typescript
import { JARM_SUPPORTED_RESPONSE_MODES } from '@maronn-openid-connect/experimental/jarm';
import { defineFeature } from '../feature.js';
import { jarmResponseModeHandler } from './response-mode.js';

/**
 * EXPERIMENTAL — JWT Secured Authorization Response Mode (JARM, OpenID
 * Foundation Final 2022-11-09): response_mode=query.jwt (and its `jwt`
 * shorthand) returns the authorization response as one signed JWT. The
 * resolve-jarm-response-mode block of endpoints/authorize/pipeline.ts reads
 * the request, and /consent answers in the same mode through
 * authorize.responseModes. A request that does not ask for a JWT response
 * mode is answered exactly as before. Settings are in config.ts.
 *
 * Backed by @maronn-openid-connect/experimental, whose API is NOT stable: it
 * may change in a breaking way between releases.
 */
export const jarm = defineFeature({
  id: 'jarm',
  authorize: { responseModes: [jarmResponseModeHandler] },
  discovery: () => ({
    // JARM §4: the JWT-secured query modes are advertised alongside query.
    response_modes_supported: [...JARM_SUPPORTED_RESPONSE_MODES],
    // JARM §4 metadata. The response JWT is always signed with RS256 (JARM §3:
    // the default for a client that registered no
    // authorization_signed_response_alg), so exactly one alg is advertised.
    authorization_signing_alg_values_supported: ['RS256'],
  }),
});
```

#### `features/jarm/config.ts`

JARM の設定で、`response-mode.ts` が応答 JWT の寿命として読む。
`jarmResponseLifetimeSeconds` は `exp` までの秒数で、末尾の `assertJarmLifetimeSeconds` が 5〜600 秒の外の値をモジュール読み込み時に拒否する（JARM §2.1 は最大 10 分を推奨している）。
JWT は URL に載ってブラウザのリダイレクトを 1 回越えれば足りるので、既定は 60 秒である。
署名アルゴリズム、応答パラメータの名前、対応する応答モードは設定にせず、ヘッダコメントに固定の理由を書いている。

```typescript
/**
 * EXPERIMENTAL — JWT Secured Authorization Response Mode (JARM).
 *
 * This feature was generated because the OP was created with `--enable jarm`.
 * It is backed by @maronn-openid-connect/experimental, whose API is NOT stable: it may
 * change in a breaking way between releases. Do not build production code on it
 * without pinning the version.
 *
 * Read by the response mode of this feature (response-mode.ts), which the
 * authorize and consent endpoints answer in.
 *
 * - jarmResponseLifetimeSeconds: how long the response JWT stays valid (its
 *   `exp` claim). JARM Section 2.1 RECOMMENDs a maximum lifetime of 10 minutes,
 *   so values outside 5-600 seconds fail fast at module load. Keep it short: the
 *   JWT rides in a URL and only needs to survive one browser redirect.
 *
 * Not configurable: the signing algorithm (RS256, JARM Section 3's default for a
 * client with no registered authorization_signed_response_alg), the response
 * parameter name (`response`, JARM Section 2.3.1) and the supported response
 * modes (`query.jwt` / `jwt` — this OP implements response_type=code only, so
 * `fragment.jwt` and `form_post.jwt` are rejected with invalid_request).
 */
import { assertJarmLifetimeSeconds } from '@maronn-openid-connect/experimental/jarm';

export const jarmConfig = {
  jarmResponseLifetimeSeconds: 60,
};

assertJarmLifetimeSeconds(jarmConfig.jarmResponseLifetimeSeconds);
```

#### `features/jarm/response-mode.ts`

JARM の応答モードそのものである。
`jarmResponseMode()` は、base の `AuthorizationResponseMode` を、認可レスポンスのパラメータ（`code` と `state`、またはエラーの項目）を 1 つの署名付き JWT にして `response` クエリパラメータで運ぶ形で実装する（JARM §2.3.1）。
JWT の `iss` クレームが issuer を示すので、平文の `iss` パラメータは加えない。
`selectJarmSigningKey()` は登録鍵セットから RS256 の鍵を選び、`jarmResponseModeHandler` は `/consent` で transaction の記録からこの応答モードを作り直す。
`contribution` は、JARM が `/consent` の `build-authorization-response` ステップにも寄与することを `maronn-oidc graph` に伝えるメタ情報で、その箱に JARM §2.3.1 が加わる。

```typescript
/**
 * EXPERIMENTAL — the JWT Secured Authorization Response Mode, as the
 * authorization endpoint answers in it.
 *
 * The authorization response parameters (code and state, or the error
 * members) become claims of one signed JWT, delivered as the single `response`
 * query parameter (JARM §2.3.1). The JWT's iss claim identifies the issuer, so
 * no plain iss parameter is added.
 */
import { selectSigningKeyByAlg, type SigningKey } from '@maronn-openid-connect/core';
import { buildJarmRedirectUrl, createJarmResponseJwt } from '@maronn-openid-connect/experimental/jarm';
import type {
  AuthorizationResponseMode,
  AuthorizationResponseModeHandler,
} from '../../endpoints/authorize/response-mode.js';
import { contribute } from '../../endpoints/step.js';
import { jarmConfig } from './config.js';

/**
 * What JARM adds to the build-authorization-response box of the consent
 * endpoint: the response it restores can be the signed JWT of JARM §2.3.1.
 */
export const contribution = contribute({
  endpoint: 'consent',
  step: 'build-authorization-response',
  feature: 'jarm',
  spec: 'JARM §2.3.1',
});

/** The name the transaction stores: the query.jwt mode (its `jwt` shorthand is answered the same way). */
export const JARM_RESPONSE_MODE_NAME = 'query.jwt';

/** The JARM response mode for a client, signed with signingKey (RS256, JARM §3). */
export function jarmResponseMode(input: {
  issuer: string;
  clientId: string;
  signingKey: SigningKey;
}): AuthorizationResponseMode {
  return {
    name: JARM_RESPONSE_MODE_NAME,
    async redirect(redirectUri, parameters) {
      return buildJarmRedirectUrl(
        redirectUri,
        await createJarmResponseJwt({
          issuer: input.issuer,
          clientId: input.clientId,
          parameters,
          signingKey: input.signingKey,
          lifetimeSeconds: jarmConfig.jarmResponseLifetimeSeconds,
        }),
      );
    },
  };
}

/**
 * JARM §3: this OP declares alg RS256 on every response JWT (the default for
 * a client that registered no authorization_signed_response_alg), and
 * discovery advertises authorization_signing_alg_values_supported: ['RS256'].
 * The first key of the general-purpose set is not guaranteed to be RS256 — a
 * SigningKeyProvider may legitimately put an ES256 key first in an RS256 +
 * ES256 set — so the key is picked by alg from the set. Its public half is
 * published at /.well-known/jwks.json under the same kid.
 * selectSigningKeyByAlg throws when no RS256 key is registered, which surfaces
 * as a server_error (a configuration mistake) rather than as an unverifiable
 * authorization response.
 */
export function selectJarmSigningKey(c: any): SigningKey {
  const jarmSigningKeys = (c.get('signingKeys') as SigningKey[] | undefined) ?? [];
  return selectSigningKeyByAlg(jarmSigningKeys, 'RS256');
}

/**
 * The JARM response mode of a stored transaction: /consent answers in it when
 * the authorization request asked for response_mode=query.jwt (JARM §2.3).
 */
export const jarmResponseModeHandler: AuthorizationResponseModeHandler = {
  names: [JARM_RESPONSE_MODE_NAME],
  restore(c, { clientId, issuer }) {
    return jarmResponseMode({ issuer, clientId, signingKey: selectJarmSigningKey(c) });
  },
};
```

#### `features/jarm/steps/resolve-jarm-response-mode.ts`

認可エンドポイントの所有者付きブロックが呼ぶステップである。
`meta` の `endpoint: 'authorize'` と `feature: 'jarm'` が、どのエンドポイントのどの機能のステップかを示し、`produces: ['responseMode']` が後続のステップに渡す値を示す。
experimental の `resolveJarmResponseMode` が判別共用体で返す分類を、`redirect_uri` が確定したこの時点でエラーにする。
`unsupported-jwt-mode` は、確定した `redirectUri` と `state` を持つ `invalid_request` の `AuthorizationError` になり、平文の query でクライアントへ返る。
`jarm` 以外の分類では `undefined` を返し、`.jwt` 系でない `response_mode` の値は従来どおり無視される。

```typescript
import {
  AuthorizationError,
  AuthorizationErrorCode,
  type AuthorizationRequestParams,
  type ClientInfo,
} from '@maronn-openid-connect/core';
import { resolveJarmResponseMode } from '@maronn-openid-connect/experimental/jarm';
import type { AuthorizationResponseMode } from '../../../endpoints/authorize/response-mode.js';
import { step } from '../../../endpoints/step.js';
import { jarmResponseMode, selectJarmSigningKey } from '../response-mode.js';

export const meta = step({
  id: 'resolve-jarm-response-mode',
  endpoint: 'authorize',
  feature: 'jarm',
  kind: 'resolve',
  label: 'Interpret response_mode=query.jwt',
  spec: 'JARM §2.3 / §3',
  function: 'resolveJarmResponseContext',
  calls: ['resolveJarmResponseMode', 'selectSigningKeyByAlg'],
  consumes: ['params', 'effectiveParams', 'client', 'redirectUri', 'state', 'issuer'],
  produces: ['responseMode'],
  removable: false,
});

/**
 * EXPERIMENTAL — JARM §2.3: interpret response_mode now that redirect_uri is
 * verified, so an unsupported JWT mode can be reported as a redirectable
 * error. Values outside the `.jwt` family stay ignored exactly as before, and
 * the result is undefined: the plain query response.
 */
export function resolveJarmResponseContext(
  c: any,
  params: AuthorizationRequestParams,
  client: ClientInfo,
  redirectUri: string,
  state: string | undefined,
  issuer: string,
): AuthorizationResponseMode | undefined {
  const jarmResolution = resolveJarmResponseMode(params);
  if (jarmResolution.kind === 'unsupported-jwt-mode') {
    // JARM §2.3.2 / §2.3.3 (fragment.jwt / form_post.jwt) are not implemented
    // here. The rejection itself goes back as a PLAIN query error: the OP
    // cannot answer in a response mode it does not implement.
    throw new AuthorizationError(
      AuthorizationErrorCode.InvalidRequest,
      'response_mode ' + jarmResolution.requested + ' is not supported',
      redirectUri,
      state,
    );
  }
  if (jarmResolution.kind !== 'jarm') return undefined;
  return jarmResponseMode({ issuer, clientId: client.clientId, signingKey: selectJarmSigningKey(c) });
}
```

### 他フレームワークの生成コード

express と fastify の生成コードは、hono と同じファイルからなる。
CLI は、エンドポイントが import する `hono` のルーターを Fetch API の小さなルーター `web-router.ts`（`WebRouter` と `WebContext`）に置き換え、フレームワーク向けの `apply.ts`、`web-router.ts`、`node-adapter.ts` を加える。
加えるファイルの元は [apps/hono/src/web/](../../../apps/hono/src/web) にあり、どのファイルをどこに置くかは [packages/cli/extract.json](../../../packages/cli/extract.json) が定める。
画面は hono/jsx のままなので、これらの生成物も JSX ランタイムとして `hono` を必要とする。
`features/jarm/` のファイルは `hono` を import しないので、express と fastify でも hono と同じ内容になる。

Next.js の生成コードは、Next.js App Router のアプリ [apps/nextjs](../../../apps/nextjs) から抜き出す。
機能のルートファイルはルートグループ `app/(<feature-id>)/` に、それ以外のコードは `app/_oidc-provider/features/<feature-id>/` に置かれ、JARM のコードは `app/_oidc-provider/features/jarm/` に入る。
どちらもこの解説には載せず、ディレクトリへのリンクで示す。

## E2E テストの全文

E2E テストは、実ブラウザでフローを完走しながら次を固定する。

- 認可レスポンスが署名検証可能な JWT として返ること（JWKS で検証し、クレームの `code` でトークン取得まで通ること）
- ユーザーが同意を拒否したとき、エラーも署名付き JWT で返ること
- 対応しない `.jwt` 系モードが平文のエラーで拒否されること
- discovery が JWT 応答モードと署名アルゴリズムを広告すること
- `response_mode` の無いリクエストでは従来どおり平文クエリで返ること（隔離原則の実地確認）

```typescript
import { expect, test } from '@playwright/test';

const host = process.env.E2E_HOST ?? '127.0.0.1';
const clientPort = Number(process.env.E2E_CLIENT_PORT ?? '3020');
const clientBaseURL =
  process.env.E2E_CLIENT_BASE_URL ?? `http://${host}:${clientPort}`;
const clientId = 'e2e-client';

/**
 * EXPERIMENTAL — JWT Secured Authorization Response Mode (JARM).
 *
 * Only the samples generated with `--enable jarm` interpret the JWT response
 * modes, so every test here skips when discovery does not advertise them. That
 * keeps the shared spec suite green across all sample OPs.
 *
 * The client half of the contract (JARM §2.4: verify the JWS with a key from the
 * OP's jwks_uri, check iss / aud / exp, reject alg=none) lives in
 * tests/e2e/apps/client.mjs and throws on any violation — so a rendered result
 * page is itself evidence that verification passed.
 */
test.describe('JWT Secured Authorization Response Mode (JARM)', () => {
  test('should return the authorization response as a verifiable signed JWT', async ({
    page,
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const responseModes = await supportedResponseModes(request, issuer);
    test.skip(
      !responseModes.includes('query.jwt'),
      'This sample OP was generated without --enable jarm',
    );

    const redirectUri = `${clientBaseURL}/callback`;

    await page.goto(`${clientBaseURL}/start-jarm`);
    await expect(page).toHaveURL(new RegExp(`^${escapeRegExp(issuer)}/login\\?transaction_id=`));

    await page.getByLabel('Username:').fill('testuser');
    await page.getByLabel('Password:').fill('password');
    await page.getByRole('button', { name: 'Login' }).click();
    await expect(page).toHaveURL(new RegExp(`^${escapeRegExp(issuer)}/consent\\?transaction_id=`));

    await page.getByRole('button', { name: 'Approve' }).click();
    await expect(page).toHaveURL(new RegExp(`^${escapeRegExp(redirectUri)}\\?response=`));

    // JARM §2.3.1: `response` is the only query parameter. The plain code /
    // state / iss parameters are gone — the JWT's iss claim replaces RFC 9207's
    // iss parameter (RFC 9700 §2.1 accepts JARM for issuer identification).
    const callbackUrl = new URL(page.url());
    expect([...callbackUrl.searchParams.keys()]).toEqual(['response']);

    // JARM §2.1 / §2.4, checked by the client before it used the code.
    await expect(page.getByTestId('jarm-alg')).toHaveText('RS256');
    await expect(page.getByTestId('jarm-iss')).toHaveText(issuer);
    await expect(page.getByTestId('jarm-aud')).toHaveText(clientId);
    await expect(page.getByTestId('jarm-signature-valid')).toHaveText('true');
    await expect(page.getByTestId('jarm-claim-names')).toHaveText('aud code exp iss state');

    // The code carried by the JWT is an ordinary authorization code: the token
    // endpoint and UserInfo are untouched by JARM.
    await expect(page.getByTestId('token-type')).toHaveText('Bearer');
    await expect(page.getByTestId('userinfo-sub')).toHaveText('testuser');
  });

  test('should return a signed error JWT when the End-User denies consent', async ({
    page,
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const responseModes = await supportedResponseModes(request, issuer);
    test.skip(
      !responseModes.includes('query.jwt'),
      'This sample OP was generated without --enable jarm',
    );

    const redirectUri = `${clientBaseURL}/callback`;

    await page.goto(`${clientBaseURL}/start-jarm`);
    await page.getByLabel('Username:').fill('testuser');
    await page.getByLabel('Password:').fill('password');
    await page.getByRole('button', { name: 'Login' }).click();
    await expect(page).toHaveURL(new RegExp(`^${escapeRegExp(issuer)}/consent\\?transaction_id=`));

    await page.getByRole('button', { name: 'Deny' }).click();
    await expect(page).toHaveURL(new RegExp(`^${escapeRegExp(redirectUri)}\\?response=`));

    const callbackUrl = new URL(page.url());
    expect([...callbackUrl.searchParams.keys()]).toEqual(['response']);

    // JARM §2.1 error example: an error response is the same signed JWT shape,
    // so the client can verify that the OP it trusts is the one that refused.
    await expect(page.getByTestId('authorization-error')).toHaveText('access_denied');
    await expect(page.getByTestId('jarm-alg')).toHaveText('RS256');
    await expect(page.getByTestId('jarm-signature-valid')).toHaveText('true');
    await expect(page.getByTestId('jarm-claim-names')).toHaveText('aud error exp iss state');
  });

  test('should reject an unsupported JWT response mode with a plain error', async ({
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const responseModes = await supportedResponseModes(request, issuer);
    test.skip(
      !responseModes.includes('query.jwt'),
      'This sample OP was generated without --enable jarm',
    );

    // JARM §2.3.2: fragment.jwt is for response types that return tokens in the
    // fragment, which this OP does not implement. The rejection cannot itself be
    // delivered in that mode, so it comes back as a plain query error.
    const response = await request.get(
      `${issuer}/authorize?response_type=code&client_id=${clientId}` +
        `&redirect_uri=${encodeURIComponent(`${clientBaseURL}/callback`)}` +
        '&scope=openid&state=e2e-jarm-state&response_mode=fragment.jwt' +
        '&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256',
      { maxRedirects: 0 },
    );

    expect(response.status()).toBe(302);
    const location = new URL(response.headers()['location'] ?? '');
    expect(location.searchParams.get('error')).toBe('invalid_request');
    expect(location.searchParams.get('error_description')).toBe(
      'response_mode fragment.jwt is not supported',
    );
    expect(location.searchParams.get('state')).toBe('e2e-jarm-state');
    expect(location.searchParams.get('response')).toBe(null);
  });

  test('should advertise the JWT response modes and signing algorithm in discovery', async ({
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const metadata = await discoveryMetadata(request, issuer);
    test.skip(
      !(metadata.response_modes_supported ?? []).includes('query.jwt'),
      'This sample OP was generated without --enable jarm',
    );

    // JARM §4: both AS metadata members the specification defines for JARM.
    expect(metadata.response_modes_supported).toEqual(['query', 'query.jwt', 'jwt']);
    expect(metadata.authorization_signing_alg_values_supported).toEqual(['RS256']);
  });

  test('should keep the plain query response for a request without response_mode', async ({
    page,
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const responseModes = await supportedResponseModes(request, issuer);
    test.skip(
      !responseModes.includes('query.jwt'),
      'This sample OP was generated without --enable jarm',
    );

    // Enabling JARM must not change anything for a client that did not ask for
    // it: the default response is still the plain query one.
    await page.goto(`${clientBaseURL}/start`);
    await page.getByLabel('Username:').fill('testuser');
    await page.getByLabel('Password:').fill('password');
    await page.getByRole('button', { name: 'Login' }).click();
    await page.getByRole('button', { name: 'Approve' }).click();

    const callbackUrl = new URL(page.url());
    expect([...callbackUrl.searchParams.keys()].sort()).toEqual(['code', 'iss', 'state']);
    expect(callbackUrl.searchParams.get('iss')).toBe(issuer);
  });
});

interface DiscoveryMetadata {
  response_modes_supported?: string[];
  authorization_signing_alg_values_supported?: string[];
}

async function discoveryMetadata(
  request: { get(url: string): Promise<{ json(): Promise<unknown> }> },
  issuer: string,
): Promise<DiscoveryMetadata> {
  const response = await request.get(`${issuer}/.well-known/openid-configuration`);
  return (await response.json()) as DiscoveryMetadata;
}

async function supportedResponseModes(
  request: { get(url: string): Promise<{ json(): Promise<unknown> }> },
  issuer: string,
): Promise<string[]> {
  return (await discoveryMetadata(request, issuer)).response_modes_supported ?? [];
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

- 利用者向けドキュメント：[docs/library-document experimental/jarm.md](../../library-document/src/content/docs/experimental/jarm.md)
- 仕様検討文書：[tasks/experimental/done/jarm/](../../../tasks/experimental/done/jarm/)
- 昇格レビューパケット：[tasks/experimental/done/jarm/promotion-review/](../../../tasks/experimental/done/jarm/promotion-review/README.md)
- パッケージ全体の設計規約：[package-overview.ja.md](./package-overview.ja.md)
- English version: [jarm.en.md](./jarm.en.md)
