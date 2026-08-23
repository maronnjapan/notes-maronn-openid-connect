# JARM（JWT Secured Authorization Response Mode）実装解説

この文書は、`packages/experimental` に実装した **JARM**（JWT Secured Authorization Response Mode for OAuth 2.0、OpenID Foundation Final Specification 2022-11-09）について、何を実装したのか、どう実装したのかを、関連するコードの全文とともに説明する。

この文書が全文を載せるのは次のコードである。

- `packages/experimental/src/jarm/` の実装 3 ファイルとテスト 2 ファイルのすべて
- CLI の `--enable jarm` が生成コードへ注入する差分の全文（hono）
- JARM の E2E テストスペックの全文

core 本体、E2E 共有ハーネス、他フレームワークの生成差分は全機能で共有される基盤なので、リンクで参照する。

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
core の interface は閉じているので、交差型 `JarmAuthTransactionFields` を定義し、生成コードが transaction を store へ保存するときに `jarmResponseMode: 'query.jwt'` を追加フィールドとして持たせる。
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

`maronn-oidc generate <framework> --enable jarm` を指定すると、生成コードに次が入る。

- **routes/jarm.ts の追加**：`jarmConfig`（`jarmResponseLifetimeSeconds: 60`）を置き、モジュール読み込み時に `assertJarmLifetimeSeconds` で検証する。新しい HTTP ルートは増えない（JARM は応答の運び方の変更であり、エンドポイントの追加ではない）
- **routes/authorize.ts の変更**：パラメータ解釈時に `resolveJarmResponseMode` で分類し、`unsupported-jwt-mode` は `redirect_uri` 確定後に `invalid_request` としてエラー化する。JARM モードのときは transaction に `jarmResponseMode: 'query.jwt'` を記録する。即時応答（prompt=none など）では、その場で応答 JWT を生成して `response` パラメータで返す
- **routes/consent.ts の変更**：同意完了後の最終リダイレクトで、transaction の記録を読み、JARM モードなら応答（成功もエラーも）を JWT 化して返す
- **routes/discovery.ts の変更**：`response_modes_supported` に `query.jwt` と `jwt` を、`authorization_signing_alg_values_supported` に `RS256` を広告する
- **conformance.test.ts の変更**：上記の挙動一式を契約テストとして固定する

### 生成コードに入る差分の全文（hono）

以下は、デフォルト構成（`default-op`）と `--enable jarm`（`with-jarm`）の生成結果の差分そのもので、`--enable jarm` が生成コードに足すもののすべてである。

````diff
diff --git a/default-op/conformance.test.ts b/with-jarm/conformance.test.ts
index 58258e6..9d521b3 100644
--- a/default-op/conformance.test.ts
+++ b/with-jarm/conformance.test.ts
@@ -415,10 +415,11 @@ describe('generated provider HTTP conformance', () => {
         jwks_uri: 'http://localhost:3000/.well-known/jwks.json',
         userinfo_endpoint: 'http://localhost:3000/userinfo',
         response_types_supported: ['code'],
-        // OAuth 2.0 Multiple Response Type Encoding Practices §2: the code flow
-        // returns the authorization response via query, so the OP advertises
-        // response_modes_supported as exactly ['query'].
-        response_modes_supported: ['query'],
+        // OAuth 2.0 Multiple Response Type Encoding Practices §2 + JARM §4: the
+        // code flow returns the authorization response via query, and this OP was
+        // generated with --enable jarm, so the JWT-secured query modes are
+        // advertised alongside it.
+        response_modes_supported: ['query', 'query.jwt', 'jwt'],
       });
     });
 
@@ -2529,6 +2530,407 @@ describe('generated provider HTTP conformance', () => {
     });
   });
 
+  // EXPERIMENTAL — JWT Secured Authorization Response Mode (JARM). Generated
+  // because this provider was created with --enable jarm. These tests pin the
+  // contract the repository guarantees for the generated JARM responses: change
+  // the behavior and they fail, which is how a customized OP learns it drifted.
+  describe('JWT Secured Authorization Response Mode (JARM)', () => {
+    // RFC 7636 Appendix B example PKCE pair (verifier -> its S256 challenge).
+    const PKCE_VERIFIER = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
+    const PKCE_CHALLENGE_S256 = 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM';
+
+    // Pure helpers: they fetch, parse and verify only. Every assertion lives in
+    // an it(), and none of them branches on the OP's behavior.
+    function relativeFrom(location: string | null): string {
+      const url = new URL(location ?? '', 'http://localhost');
+      return url.pathname + url.search;
+    }
+
+    function csrfFrom(html: string): string {
+      return html.match(/name="csrf_token" value="([^"]+)"/)?.[1] ?? '';
+    }
+
+    function firstCookie(res: Response): string {
+      return (res.headers.get('Set-Cookie') ?? '').split(';')[0] ?? '';
+    }
+
+    function decodeSegment(segment: string): Record<string, unknown> {
+      const base64 = segment.replace(/-/g, '+').replace(/_/g, '/');
+      const padded = base64.padEnd(base64.length + ((4 - (base64.length % 4)) % 4), '=');
+      const bytes = Uint8Array.from(atob(padded), (char) => char.charCodeAt(0));
+      return JSON.parse(new TextDecoder().decode(bytes));
+    }
+
+    function authorizeUrl(overrides: Record<string, string> = {}): string {
+      return '/authorize?' + new URLSearchParams({
+        response_type: 'code',
+        client_id: 'c-conf',
+        redirect_uri: REDIRECT_URI,
+        scope: 'openid',
+        state: 'jarm-state',
+        nonce: 'jarm-nonce',
+        code_challenge: PKCE_CHALLENGE_S256,
+        code_challenge_method: 'S256',
+        ...overrides,
+      }).toString();
+    }
+
+    /**
+     * Drives authorize -> login -> consent and returns the final Location plus
+     * the browser session cookie login handed out (used by the SSO / prompt=none
+     * cases below). The transaction cookie is carried forward exactly as a
+     * browser would, so this works with or without --enable transaction-binding.
+     */
+    async function interactiveFlow(
+      url: string,
+      action: 'approve' | 'deny' = 'approve',
+    ): Promise<{ location: string; sessionCookie: string }> {
+      const authorizeRes = await app.request(url);
+      const loginPath = relativeFrom(authorizeRes.headers.get('Location'));
+      const bindingCookie = firstCookie(authorizeRes);
+      const transactionId =
+        new URL(loginPath, 'http://localhost').searchParams.get('transaction_id') ?? '';
+
+      const loginGet = await app.request(loginPath, { headers: { Cookie: bindingCookie } });
+      const loginRes = await app.request('/login', {
+        method: 'POST',
+        headers: { 'Content-Type': 'application/x-www-form-urlencoded', Cookie: bindingCookie },
+        body: new URLSearchParams({
+          transaction_id: transactionId,
+          csrf_token: csrfFrom(await loginGet.text()),
+          username: 'testuser',
+          password: 'password',
+        }).toString(),
+      });
+      const sessionCookie = firstCookie(loginRes);
+
+      const consentPath = relativeFrom(loginRes.headers.get('Location'));
+      const consentGet = await app.request(consentPath, { headers: { Cookie: bindingCookie } });
+      const consentRes = await app.request('/consent', {
+        method: 'POST',
+        headers: { 'Content-Type': 'application/x-www-form-urlencoded', Cookie: bindingCookie },
+        body: new URLSearchParams({
+          transaction_id: transactionId,
+          csrf_token: csrfFrom(await consentGet.text()),
+          action,
+        }).toString(),
+      });
+
+      return {
+        location: consentRes.headers.get('Location') ?? '',
+        sessionCookie,
+      };
+    }
+
+    function queryOf(location: string): URLSearchParams {
+      return new URL(location, 'http://localhost').searchParams;
+    }
+
+    /**
+     * JARM Section 2.4 / Section 5.1, from the client's side: resolve the key
+     * from the OP's jwks_uri by kid and verify the RS256 signature before any
+     * claim is trusted.
+     */
+    async function inspectJarmJwt(jwt: string): Promise<{
+      header: Record<string, unknown>;
+      payload: Record<string, unknown>;
+      signatureValid: boolean;
+    }> {
+      const [encodedHeader = '', encodedPayload = '', encodedSignature = ''] = jwt.split('.');
+      const header = decodeSegment(encodedHeader);
+      const jwks = await (await app.request('/.well-known/jwks.json')).json();
+      const jwk = (jwks.keys as Array<Record<string, unknown>>).find(
+        (candidate) => candidate.kid === header.kid,
+      );
+      const key = await crypto.subtle.importKey(
+        'jwk',
+        { kty: 'RSA', n: jwk?.n as string, e: jwk?.e as string },
+        { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
+        false,
+        ['verify'],
+      );
+      const base64 = encodedSignature.replace(/-/g, '+').replace(/_/g, '/');
+      const padded = base64.padEnd(base64.length + ((4 - (base64.length % 4)) % 4), '=');
+      const signatureValid = await crypto.subtle.verify(
+        'RSASSA-PKCS1-v1_5',
+        key,
+        Uint8Array.from(atob(padded), (char) => char.charCodeAt(0)),
+        new TextEncoder().encode(encodedHeader + '.' + encodedPayload),
+      );
+      return { header, payload: decodeSegment(encodedPayload), signatureValid };
+    }
+
+    describe('Signing key selection (JARM Section 3)', () => {
+      // A SigningKeyProvider may legitimately return an ES256 active key next to
+      // a registered set that also holds RS256 — packages/core's
+      // SigningKeyProvider contract documents alternate-alg key sets, and only
+      // the SET is required to contain RS256 (OIDC Core 1.0 Section 15.1). The
+      // JARM response JWT always declares alg RS256, so it must be signed with
+      // the RS256 key from that set: signing it with whichever key happens to be
+      // active would make Web Crypto refuse and break the authorization response
+      // delivery path for every client that asked for a JWT response mode.
+      it('should sign with the registered RS256 key when the active key is ES256', async () => {
+        const rs256Pair = await crypto.subtle.generateKey(
+          { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
+          true,
+          ['sign', 'verify'],
+        );
+        const es256Pair = await crypto.subtle.generateKey(
+          { name: 'ECDSA', namedCurve: 'P-256' },
+          true,
+          ['sign', 'verify'],
+        );
+        const rs256Key: SigningKey = {
+          privateKey: rs256Pair.privateKey,
+          publicJwk: await crypto.subtle.exportKey('jwk', rs256Pair.publicKey),
+          keyId: 'mixed-rs256',
+        };
+        const es256Key: SigningKey = {
+          privateKey: es256Pair.privateKey,
+          publicJwk: await crypto.subtle.exportKey('jwk', es256Pair.publicKey),
+          keyId: 'mixed-es256',
+        };
+        const mixedProvider: SigningKeyProvider = {
+          // Active key is the ES256 one; the registered set holds both.
+          async getSigningKey(): Promise<SigningKey> {
+            return es256Key;
+          },
+          async getSigningKeys(): Promise<SigningKey[]> {
+            return [rs256Key, es256Key];
+          },
+        };
+        const mixedApp = createApp({
+          signingKeyProvider: mixedProvider,
+          clientResolver: createInMemoryClientResolver(testClients),
+        });
+
+        // OIDC Core 1.0 Section 3.1.2.1: prompt=none with no session is
+        // login_required — a redirectable error, so it is answered in JARM mode
+        // straight from the authorize route, with no interaction to drive.
+        const res = await mixedApp.request(
+          authorizeUrl({ response_mode: 'query.jwt', prompt: 'none' }),
+        );
+        const location = res.headers.get('Location') ?? '';
+        const jwt = queryOf(location).get('response') ?? '';
+        const [encodedHeader = '', encodedPayload = '', encodedSignature = ''] = jwt.split('.');
+        const base64 = encodedSignature.replace(/-/g, '+').replace(/_/g, '/');
+        const padded = base64.padEnd(base64.length + ((4 - (base64.length % 4)) % 4), '=');
+        const signatureValid = await crypto.subtle.verify(
+          'RSASSA-PKCS1-v1_5',
+          rs256Pair.publicKey,
+          Uint8Array.from(atob(padded), (char) => char.charCodeAt(0)),
+          new TextEncoder().encode(encodedHeader + '.' + encodedPayload),
+        );
+
+        expect([...queryOf(location).keys()]).toEqual(['response']);
+        expect(decodeSegment(encodedHeader)).toEqual({ alg: 'RS256', kid: 'mixed-rs256' });
+        expect(signatureValid).toBe(true);
+        expect(decodeSegment(encodedPayload).error).toBe('login_required');
+      });
+    });
+
+    describe('Success response (JARM Section 2.3.1)', () => {
+      it('should deliver the authorization response as the only response query parameter', async () => {
+        const { location } = await interactiveFlow(authorizeUrl({ response_mode: 'query.jwt' }));
+
+        // JARM Section 2.3.1: the response is carried by a single `response`
+        // parameter. The plain code / state / iss parameters MUST NOT be added —
+        // the JWT's iss claim replaces RFC 9207's iss parameter.
+        expect([...queryOf(location).keys()]).toEqual(['response']);
+      });
+
+      it('should sign the response JWT with RS256 under a kid published in JWKS', async () => {
+        const { location } = await interactiveFlow(authorizeUrl({ response_mode: 'query.jwt' }));
+        const inspected = await inspectJarmJwt(queryOf(location).get('response') ?? '');
+
+        // JARM Section 3: RS256 is the default (and here the only) algorithm.
+        // No typ header: JARM does not define one and its Section 2.3.1 example
+        // header carries only kid and alg.
+        expect(inspected.header).toEqual({ alg: 'RS256', kid: 'test-key' });
+        expect(inspected.signatureValid).toBe(true);
+      });
+
+      it('should carry exactly iss, aud, exp, code and state as claims', async () => {
+        const { location } = await interactiveFlow(authorizeUrl({ response_mode: 'query.jwt' }));
+        const { payload } = await inspectJarmJwt(queryOf(location).get('response') ?? '');
+
+        // JARM Section 2.1: iss / aud / exp are REQUIRED and the authorization
+        // response parameters travel as claims of the same JWT. The claim set is
+        // pinned whole so an added claim (a PII leak, for instance) fails here.
+        expect(Object.keys(payload).sort()).toEqual(['aud', 'code', 'exp', 'iss', 'state']);
+        expect(payload.iss).toBe('http://localhost:3000');
+        expect(payload.aud).toBe('c-conf');
+        expect(payload.state).toBe('jarm-state');
+      });
+
+      it('should exchange the code carried by the response JWT for tokens', async () => {
+        const { location } = await interactiveFlow(authorizeUrl({ response_mode: 'query.jwt' }));
+        const { payload } = await inspectJarmJwt(queryOf(location).get('response') ?? '');
+        const res = await app.request('/token', {
+          method: 'POST',
+          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
+          body: new URLSearchParams({
+            grant_type: 'authorization_code',
+            code: String(payload.code ?? ''),
+            redirect_uri: REDIRECT_URI,
+            client_id: 'c-conf',
+            client_secret: 's',
+            code_verifier: PKCE_VERIFIER,
+          }).toString(),
+        });
+
+        // JARM changes only how the response is delivered; the code itself is an
+        // ordinary authorization code and the token endpoint is untouched.
+        expect(res.status).toBe(200);
+        expect((await res.json()).token_type).toBe('Bearer');
+      });
+
+      it('should treat the jwt shorthand as query.jwt', async () => {
+        // JARM Section 2.3.4: for response_type=code the default JWT delivery
+        // mode is query.jwt, so the `jwt` shorthand means exactly that.
+        const { location } = await interactiveFlow(authorizeUrl({ response_mode: 'jwt' }));
+        const { payload, signatureValid } = await inspectJarmJwt(
+          queryOf(location).get('response') ?? '',
+        );
+
+        expect([...queryOf(location).keys()]).toEqual(['response']);
+        expect(signatureValid).toBe(true);
+        expect(Object.keys(payload).sort()).toEqual(['aud', 'code', 'exp', 'iss', 'state']);
+      });
+    });
+
+    describe('Error response (JARM Section 2.1)', () => {
+      it('should return a signed error JWT when the End-User denies consent', async () => {
+        const { location } = await interactiveFlow(
+          authorizeUrl({ response_mode: 'query.jwt' }),
+          'deny',
+        );
+        const { payload, signatureValid } = await inspectJarmJwt(
+          queryOf(location).get('response') ?? '',
+        );
+
+        expect([...queryOf(location).keys()]).toEqual(['response']);
+        expect(signatureValid).toBe(true);
+        expect(Object.keys(payload).sort()).toEqual(['aud', 'error', 'exp', 'iss', 'state']);
+        expect(payload.error).toBe('access_denied');
+        expect(payload.state).toBe('jarm-state');
+      });
+
+      it('should return a signed error JWT for a prompt=none request with no session', async () => {
+        // OIDC Core 1.0 Section 3.1.2.1: prompt=none without a session is
+        // login_required. It is a redirectable error, so JARM applies to it.
+        const res = await app.request(
+          authorizeUrl({ response_mode: 'query.jwt', prompt: 'none' }),
+        );
+        const { payload, signatureValid } = await inspectJarmJwt(
+          queryOf(res.headers.get('Location') ?? '').get('response') ?? '',
+        );
+
+        expect([...queryOf(res.headers.get('Location') ?? '').keys()]).toEqual(['response']);
+        expect(signatureValid).toBe(true);
+        expect(payload.error).toBe('login_required');
+        expect(payload.state).toBe('jarm-state');
+      });
+    });
+
+    describe('Unsupported JWT response modes', () => {
+      // JARM Section 2.3.2 / Section 2.3.3 exist in the specification but are not
+      // implemented by this OP (response_type=code only, no auto-submitting form).
+      // The rejection itself is a PLAIN query error: the OP cannot answer in a
+      // response mode it does not implement.
+      it('should reject fragment.jwt with a plain invalid_request redirect', async () => {
+        const res = await app.request(authorizeUrl({ response_mode: 'fragment.jwt' }));
+        const query = queryOf(res.headers.get('Location') ?? '');
+
+        expect(res.status).toBe(302);
+        expect([...query.keys()].sort()).toEqual(['error', 'error_description', 'iss', 'state']);
+        expect(query.get('error')).toBe('invalid_request');
+        expect(query.get('error_description')).toBe('response_mode fragment.jwt is not supported');
+        expect(query.get('state')).toBe('jarm-state');
+      });
+
+      it('should reject form_post.jwt with a plain invalid_request redirect', async () => {
+        const res = await app.request(authorizeUrl({ response_mode: 'form_post.jwt' }));
+        const query = queryOf(res.headers.get('Location') ?? '');
+
+        expect(query.get('error')).toBe('invalid_request');
+        expect(query.get('error_description')).toBe('response_mode form_post.jwt is not supported');
+      });
+    });
+
+    describe('Unchanged behavior without a JWT response mode', () => {
+      it('should return the plain query response when response_mode is absent', async () => {
+        const { location } = await interactiveFlow(authorizeUrl());
+
+        // The whole point of the isolation: enabling JARM must not change the
+        // response for a client that did not ask for it.
+        expect([...queryOf(location).keys()].sort()).toEqual(['code', 'iss', 'state']);
+        expect(queryOf(location).get('iss')).toBe('http://localhost:3000');
+      });
+
+      it('should keep ignoring a non-JWT response_mode value', async () => {
+        // form_post is not implemented and never was; JARM only adds meaning to
+        // the .jwt family, so this request is answered exactly as before.
+        const { location } = await interactiveFlow(authorizeUrl({ response_mode: 'form_post' }));
+
+        expect([...queryOf(location).keys()].sort()).toEqual(['code', 'iss', 'state']);
+      });
+    });
+
+    describe('Transaction store round trip', () => {
+      // The authorize route records the mode on the transaction and the consent
+      // route reads it back, so a store that drops unknown fields would answer in
+      // plain query. These paths, by contrast, answer inside the authorize route
+      // itself and never touch the store round trip.
+      it('should answer the SSO fast path with a signed JWT', async () => {
+        const first = await interactiveFlow(
+          authorizeUrl({ response_mode: 'query.jwt', prompt: 'consent' }),
+        );
+        const res = await app.request(authorizeUrl({ response_mode: 'query.jwt' }), {
+          headers: { Cookie: first.sessionCookie },
+        });
+        const { header, payload, signatureValid } = await inspectJarmJwt(
+          queryOf(res.headers.get('Location') ?? '').get('response') ?? '',
+        );
+
+        expect([...queryOf(res.headers.get('Location') ?? '').keys()]).toEqual(['response']);
+        // JARM Section 3: the authorize route signs with the RS256 key selected
+        // from the registered key set, not with whichever key happens to be
+        // active, so the alg header always matches the key that produced it.
+        expect(header).toEqual({ alg: 'RS256', kid: 'test-key' });
+        expect(signatureValid).toBe(true);
+        expect(Object.keys(payload).sort()).toEqual(['aud', 'code', 'exp', 'iss', 'state']);
+      });
+
+      it('should answer a prompt=none success with a signed JWT', async () => {
+        const first = await interactiveFlow(
+          authorizeUrl({ response_mode: 'query.jwt', prompt: 'consent' }),
+        );
+        const res = await app.request(
+          authorizeUrl({ response_mode: 'query.jwt', prompt: 'none' }),
+          { headers: { Cookie: first.sessionCookie } },
+        );
+        const { header, payload, signatureValid } = await inspectJarmJwt(
+          queryOf(res.headers.get('Location') ?? '').get('response') ?? '',
+        );
+
+        expect([...queryOf(res.headers.get('Location') ?? '').keys()]).toEqual(['response']);
+        expect(header).toEqual({ alg: 'RS256', kid: 'test-key' });
+        expect(signatureValid).toBe(true);
+        expect(Object.keys(payload).sort()).toEqual(['aud', 'code', 'exp', 'iss', 'state']);
+      });
+    });
+
+    describe('Discovery metadata (JARM Section 4)', () => {
+      it('should advertise the JWT response modes and the response signing algorithm', async () => {
+        const metadata = await (await app.request('/.well-known/openid-configuration')).json();
+
+        expect(metadata.response_modes_supported).toEqual(['query', 'query.jwt', 'jwt']);
+        expect(metadata.authorization_signing_alg_values_supported).toEqual(['RS256']);
+      });
+    });
+  });
+
   describe('Consent decision value (OIDC Core 1.0 §3.1.2.4)', () => {
     const DECISION_PKCE_CHALLENGE = 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM';
 
diff --git a/default-op/routes/authorize.ts b/with-jarm/routes/authorize.ts
index a3ffab2..c9be0d0 100644
--- a/default-op/routes/authorize.ts
+++ b/with-jarm/routes/authorize.ts
@@ -29,6 +29,9 @@ import {
   IdTokenHintError,
   type AuthorizationRequestParams,
   type JwkSet,
+  AuthorizationErrorCode,
+  selectSigningKeyByAlg,
+  type SigningKey,
 } from '@maronn-openid-connect/core';
 import { clientResolver as defaultClientResolver } from '../resolvers.js';
 import {
@@ -37,6 +40,12 @@ import {
   authSessionStore as defaultAuthSessionStore,
 } from '../store.js';
 import { defaultViews, renderView } from '../views.js';
+import {
+  buildJarmRedirectUrl,
+  createJarmResponseJwt,
+  resolveJarmResponseMode,
+} from '@maronn-openid-connect/experimental/jarm';
+import { jarmConfig } from './jarm.js';
 
 export const authorizeApp = new Hono<{ Variables: Record<string, any> }>();
 
@@ -53,6 +62,19 @@ function isAuthorizationRequestParams(
   return typeof p['client_id'] === 'string';
 }
 
+/**
+ * EXPERIMENTAL — JARM response context (JARM Section 2.1).
+ *
+ * Present only for a request that asked for response_mode=query.jwt (or its
+ * `jwt` shorthand). undefined means the plain query response this OP has always
+ * produced, so a client that does not ask for JARM sees no change at all.
+ */
+type JarmResponseContext = {
+  issuer: string;
+  clientId: string;
+  signingKey: SigningKey;
+};
+
 /**
  * Builds a redirect URL with an OAuth error response.
  * OIDC Core 1.0 Section 3.1.2.6 / RFC 6749 Section 4.1.2.1.
@@ -61,26 +83,84 @@ function isAuthorizationRequestParams(
  * Section 5.2 allowed character set before being appended so user-controlled
  * fragments cannot smuggle control bytes into the redirect URL.
  *
- * RFC 9207 §2: when issuer is provided, the iss parameter is appended so the
- * client can pin the issuer that produced this authorization response.
+ * RFC 9207 Section 2: when issuer is provided, the iss parameter is appended so
+ * the client can pin the issuer that produced this authorization response.
+ *
+ * EXPERIMENTAL (JARM Section 2.1 / 2.3.1): when jarm is present the very same
+ * parameters travel as claims of one signed JWT in the `response` query
+ * parameter instead, and no plain error / error_description / state / iss
+ * parameter is added — the JWT's iss claim identifies the issuer (RFC 9700
+ * Section 2.1 accepts JARM as the issuer-identification mechanism).
  */
-function buildErrorRedirect(
+async function buildErrorRedirect(
+  jarm: JarmResponseContext | undefined,
   redirectUri: string,
   error: string,
   state?: string,
   errorDescription?: string,
   issuer?: string,
-): string {
+): Promise<string> {
+  // RFC 6749 Section 5.2: sanitize once, for both response shapes.
+  const description = errorDescription
+    ? sanitizeErrorDescription(errorDescription)
+    : undefined;
+  if (jarm) {
+    return buildJarmRedirectUrl(
+      redirectUri,
+      await createJarmResponseJwt({
+        issuer: jarm.issuer,
+        clientId: jarm.clientId,
+        parameters: { error, error_description: description, state },
+        signingKey: jarm.signingKey,
+        lifetimeSeconds: jarmConfig.jarmResponseLifetimeSeconds,
+      }),
+    );
+  }
   const url = new URL(redirectUri);
   url.searchParams.set('error', error);
-  if (errorDescription) {
-    url.searchParams.set('error_description', sanitizeErrorDescription(errorDescription));
+  if (description) {
+    url.searchParams.set('error_description', description);
   }
   if (state) url.searchParams.set('state', state);
   if (issuer) url.searchParams.set('iss', issuer);
   return url.toString();
 }
 
+/**
+ * Builds the success redirect URL carrying the authorization code.
+ * OIDC Core 1.0 Section 3.1.2.5 / RFC 9207 Section 2 (iss).
+ *
+ * EXPERIMENTAL (JARM Section 2.3.1): when jarm is present the code and state
+ * become claims of a signed JWT delivered as the single `response` parameter;
+ * no plain code / state / iss parameter is added.
+ */
+async function buildSuccessRedirect(
+  jarm: JarmResponseContext | undefined,
+  redirectUri: string,
+  code: string,
+  state: string | undefined,
+  issuer: string,
+): Promise<string> {
+  if (jarm) {
+    return buildJarmRedirectUrl(
+      redirectUri,
+      await createJarmResponseJwt({
+        issuer: jarm.issuer,
+        clientId: jarm.clientId,
+        parameters: { code, state },
+        signingKey: jarm.signingKey,
+        lifetimeSeconds: jarmConfig.jarmResponseLifetimeSeconds,
+      }),
+    );
+  }
+  const url = new URL(redirectUri);
+  url.searchParams.set('code', code);
+  if (state) url.searchParams.set('state', state);
+  // RFC 9207 Section 2: include iss in success responses.
+  url.searchParams.set('iss', issuer);
+  return url.toString();
+}
+
 /**
  * Iterates URLSearchParams and reports the first repeated key, if any.
  * OIDC Core 1.0 §3.1.2.1 / RFC 6749 §3.1: authorization request parameters
@@ -148,6 +228,10 @@ const handleAuthorizationRequest = async (c: any) => {
   }
 
   const params = rawParams;
+  // EXPERIMENTAL — JARM §2.3. Set once redirect_uri is verified; undefined means
+  // the plain query response. Every authorize-route response site below reads
+  // this local, so none of them depends on the transaction store round-trip.
+  let jarmResponse: JarmResponseContext | undefined;
 
   try {
     const clientResolver = c.get('clientResolver') ?? defaultClientResolver;
@@ -189,6 +273,49 @@ const handleAuthorizationRequest = async (c: any) => {
     // RFC 6749 §4.1.2.1: state is echoed only on redirectable errors from here on.
     const state = effectiveParams.state;
 
+    // EXPERIMENTAL — JARM §2.3: interpret response_mode now that redirect_uri is
+    // verified, so an unsupported JWT mode can be reported as a redirectable
+    // error. Values outside the `.jwt` family stay ignored exactly as before.
+    const jarmResolution = resolveJarmResponseMode(effectiveParams);
+    if (jarmResolution.kind === 'unsupported-jwt-mode') {
+      // JARM §2.3.2 / §2.3.3 (fragment.jwt / form_post.jwt) are not implemented
+      // here. The rejection itself goes back as a PLAIN query error: the OP
+      // cannot answer in a response mode it does not implement.
+      throw new AuthorizationError(
+        AuthorizationErrorCode.InvalidRequest,
+        'response_mode ' + jarmResolution.requested + ' is not supported',
+        redirectUri,
+        state,
+      );
+    }
+    if (jarmResolution.kind === 'jarm') {
+      // JARM §3: this OP declares alg RS256 on every response JWT (the default
+      // for a client that registered no authorization_signed_response_alg), and
+      // discovery advertises authorization_signing_alg_values_supported:
+      // ['RS256']. The general-purpose ACTIVE key is not guaranteed to be RS256 —
+      // SigningKeyProvider may legitimately return ES256 as active alongside an
+      // RS256 + ES256 registered set — so the key is picked by alg from the
+      // registered set. Its public half is published at /.well-known/jwks.json
+      // under the same kid. selectSigningKeyByAlg throws when no RS256 key is
+      // registered, which surfaces as a server_error here (a configuration
+      // mistake) rather than as an unverifiable authorization response.
+      const jarmSigningKeys = (c.get('signingKeys') as SigningKey[] | undefined) ?? [];
+      jarmResponse = {
+        issuer,
+        clientId: client.clientId,
+        // Falls back to the single-key context so a hand-wired provider that
+        // never populated the key set keeps working; on the default single
+        // RS256 key both branches resolve the same key.
+        signingKey: jarmSigningKeys.length > 0
+          ? selectSigningKeyByAlg(jarmSigningKeys, 'RS256')
+          : {
+              privateKey: c.get('privateKey'),
+              publicJwk: c.get('publicJwk'),
+              keyId: c.get('keyId'),
+            },
+      };
+    }
+
     // OIDC Core 1.0 §6.3: request_uri / registration are not supported here.
     rejectUnsupportedRequestParams(params, redirectUri, state);
 
@@ -270,7 +397,7 @@ const handleAuthorizationRequest = async (c: any) => {
     const transactionTtlSeconds = 10 * 60; // 10 minutes TTL
     await transactionStore.put(
       'auth_txn:' + transactionId,
-      transaction,
+      jarmResponse ? { ...transaction, jarmResponseMode: 'query.jwt' } : transaction,
       transactionTtlSeconds,
     );
 
@@ -280,7 +407,7 @@ const handleAuthorizationRequest = async (c: any) => {
     // prompt=none must not be combined with other values (OIDC Core 1.0 Section 3.1.2.1)
     if (promptValues.includes('none') && promptValues.length > 1) {
       await transactionStore.delete('auth_txn:' + transactionId);
-      return c.redirect(buildErrorRedirect(transaction.redirectUri, 'invalid_request', transaction.state, 'prompt=none must not be combined with other prompt values', issuer));
+      return c.redirect(await buildErrorRedirect(jarmResponse, transaction.redirectUri, 'invalid_request', transaction.state, 'prompt=none must not be combined with other prompt values', issuer));
     }
 
     // OIDC Core 1.0 §3.1.2.1: the id_token_hint rule ("if the End-User identified
@@ -296,7 +423,7 @@ const handleAuthorizationRequest = async (c: any) => {
       if (!jwksProvider) {
         // jwksProvider 未提供では hint を検証できない → login_required で拒否
         await transactionStore.delete('auth_txn:' + transactionId);
-        return c.redirect(buildErrorRedirect(transaction.redirectUri, 'login_required', transaction.state, 'jwksProvider is not configured; cannot verify id_token_hint', issuer));
+        return c.redirect(await buildErrorRedirect(jarmResponse, transaction.redirectUri, 'login_required', transaction.state, 'jwksProvider is not configured; cannot verify id_token_hint', issuer));
       }
       try {
         const jwks = await jwksProvider();
@@ -309,7 +436,7 @@ const handleAuthorizationRequest = async (c: any) => {
       } catch (hintError) {
         await transactionStore.delete('auth_txn:' + transactionId);
         const code = hintError instanceof IdTokenHintError ? hintError.error : 'login_required';
-        return c.redirect(buildErrorRedirect(transaction.redirectUri, code, transaction.state, hintError instanceof Error && hintError.message ? hintError.message : 'id_token_hint verification failed', issuer));
+        return c.redirect(await buildErrorRedirect(jarmResponse, transaction.redirectUri, code, transaction.state, hintError instanceof Error && hintError.message ? hintError.message : 'id_token_hint verification failed', issuer));
       }
     }
 
@@ -322,14 +449,14 @@ const handleAuthorizationRequest = async (c: any) => {
       // No sessionResolver configured → cannot verify session → login_required
       if (!sessionResolver) {
         await transactionStore.delete('auth_txn:' + transactionId);
-        return c.redirect(buildErrorRedirect(transaction.redirectUri, 'login_required', transaction.state, 'sessionResolver is not configured; cannot satisfy prompt=none', issuer));
+        return c.redirect(await buildErrorRedirect(jarmResponse, transaction.redirectUri, 'login_required', transaction.state, 'sessionResolver is not configured; cannot satisfy prompt=none', issuer));
       }
 
       // No consentResolver configured → cannot confirm consent → consent_required
       // (OIDC Core 1.0 Section 3.1.2.1: prompt=none must not display consent screen)
       if (!consentResolver) {
         await transactionStore.delete('auth_txn:' + transactionId);
-        return c.redirect(buildErrorRedirect(transaction.redirectUri, 'consent_required', transaction.state, 'consentResolver is not configured; cannot satisfy prompt=none', issuer));
+        return c.redirect(await buildErrorRedirect(jarmResponse, transaction.redirectUri, 'consent_required', transaction.state, 'consentResolver is not configured; cannot satisfy prompt=none', issuer));
       }
 
       let session;
@@ -356,20 +483,20 @@ const handleAuthorizationRequest = async (c: any) => {
       } catch (promptError) {
         await transactionStore.delete('auth_txn:' + transactionId);
         if (promptError instanceof AuthorizationError) {
-          return c.redirect(buildErrorRedirect(transaction.redirectUri, promptError.error, transaction.state, promptError.errorDescription, issuer));
+          return c.redirect(await buildErrorRedirect(jarmResponse, transaction.redirectUri, promptError.error, transaction.state, promptError.errorDescription, issuer));
         }
         const serverDescription =
           promptError instanceof Error && promptError.message
             ? promptError.message
             : 'Unexpected error while evaluating prompt=none';
-        return c.redirect(buildErrorRedirect(transaction.redirectUri, 'server_error', transaction.state, serverDescription, issuer));
+        return c.redirect(await buildErrorRedirect(jarmResponse, transaction.redirectUri, 'server_error', transaction.state, serverDescription, issuer));
       }
 
       // Check max_age: if session is too old, prompt=none cannot trigger re-authentication
       // OIDC Core 1.0 Section 3.1.2.1
       if (transaction.maxAge !== undefined && requiresReauthentication(transaction.maxAge, session.authTime)) {
         await transactionStore.delete('auth_txn:' + transactionId);
-        return c.redirect(buildErrorRedirect(transaction.redirectUri, 'login_required', transaction.state, 'Session exceeds the requested max_age; re-authentication required', issuer));
+        return c.redirect(await buildErrorRedirect(jarmResponse, transaction.redirectUri, 'login_required', transaction.state, 'Session exceeds the requested max_age; re-authentication required', issuer));
       }
 
       // transaction.scope は認可リクエスト検証時に applyOfflineAccessPolicy を通した
@@ -401,12 +528,15 @@ const handleAuthorizationRequest = async (c: any) => {
         authCodeData.grantId,
       );
 
-      const redirectUrl = new URL(transaction.redirectUri);
-      redirectUrl.searchParams.set('code', authCodeData.code);
-      if (transaction.state) redirectUrl.searchParams.set('state', transaction.state);
-      // RFC 9207 §2: include iss in success responses too.
-      redirectUrl.searchParams.set('iss', issuer);
-      return c.redirect(redirectUrl.toString());
+      return c.redirect(
+        await buildSuccessRedirect(
+          jarmResponse,
+          transaction.redirectUri,
+          authCodeData.code,
+          transaction.state,
+          issuer,
+        ),
+      );
     }
 
     // OIDC Core 1.0 Section 3.1.2.3: an active OP session enables Single Sign-On.
@@ -473,12 +603,15 @@ const handleAuthorizationRequest = async (c: any) => {
               authCodeData.grantId,
             );
 
-            const redirectUrl = new URL(transaction.redirectUri);
-            redirectUrl.searchParams.set('code', authCodeData.code);
-            if (transaction.state) redirectUrl.searchParams.set('state', transaction.state);
-            // RFC 9207 §2: include iss in success responses.
-            redirectUrl.searchParams.set('iss', issuer);
-            return c.redirect(redirectUrl.toString());
+            return c.redirect(
+              await buildSuccessRedirect(
+                jarmResponse,
+                transaction.redirectUri,
+                authCodeData.code,
+                transaction.state,
+                issuer,
+              ),
+            );
           }
 
           const authSessionStore = c.get('authSessionStore') ?? defaultAuthSessionStore;
@@ -503,20 +636,24 @@ const handleAuthorizationRequest = async (c: any) => {
   } catch (error) {
     if (error instanceof AuthorizationError) {
       if (error.redirectUri) {
-        const redirectUrl = new URL(error.redirectUri);
-        redirectUrl.searchParams.set('error', error.error);
-        if (error.errorDescription) {
-          redirectUrl.searchParams.set('error_description', error.errorDescription);
-        }
-        if (error.state) {
-          redirectUrl.searchParams.set('state', error.state);
-        }
         // RFC 9207 §2: include iss on error redirects so the client can
         // pin the issuer. config has already been read into context by
         // middleware; reread it here because the early-bound issuer is
-        // scoped to the try block.
-        redirectUrl.searchParams.set('iss', c.get('config').issuer);
-        return c.redirect(redirectUrl.toString());
+        // scoped to the try block. EXPERIMENTAL (JARM §2.1): when this request
+        // asked for a JWT response mode, the same members become claims of a
+        // signed JWT and no plain parameter is added. jarmResponse is undefined
+        // for errors thrown before response_mode was interpreted (unknown
+        // client, unsupported JWT mode), which is why those stay plain.
+        return c.redirect(
+          await buildErrorRedirect(
+            jarmResponse,
+            error.redirectUri,
+            error.error,
+            error.state,
+            error.errorDescription,
+            c.get('config').issuer,
+          ),
+        );
       }
       // OIDC Core 1.0 §3.1.2.2: errors that cannot be redirected (unknown
       // client_id, unregistered redirect_uri, redirect_uri with a fragment) MUST
diff --git a/default-op/routes/consent.ts b/with-jarm/routes/consent.ts
index 41d7d41..83b82e2 100644
--- a/default-op/routes/consent.ts
+++ b/with-jarm/routes/consent.ts
@@ -4,6 +4,9 @@ import {
   validateCsrfToken,
   completeAuthTransaction,
   createAuthorizationCode,
+  selectSigningKeyByAlg,
+  type AuthTransaction,
+  type SigningKey,
 } from '@maronn-openid-connect/core';
 import {
   consentResolver as defaultConsentResolver,
@@ -14,9 +17,89 @@ import {
   authSessionStore as defaultAuthSessionStore,
 } from '../store.js';
 import { defaultViews, renderView } from '../views.js';
+import {
+  buildJarmRedirectUrl,
+  createJarmResponseJwt,
+  type JarmAuthTransactionFields,
+} from '@maronn-openid-connect/experimental/jarm';
+import { jarmConfig } from './jarm.js';
 
 export const consentApp = new Hono<{ Variables: Record<string, any> }>();
 
+/**
+ * EXPERIMENTAL — JARM (JWT Secured Authorization Response Mode).
+ *
+ * The authorize route recorded the requested response mode on the transaction
+ * (jarmResponseMode). This route only ever sees the transaction it read back
+ * from the store, so the auth transaction store MUST persist fields it does not
+ * know about — otherwise a client that asked for a JWT response silently gets a
+ * plain query response instead. conformance.test.ts pins that round trip.
+ */
+function resolveJarmResponse(
+  c: any,
+  transaction: AuthTransaction & JarmAuthTransactionFields,
+): JarmResponseContext | undefined {
+  if (transaction.jarmResponseMode !== 'query.jwt') return undefined;
+  // JARM Section 3: the response JWT always declares alg RS256, so the key is
+  // picked by alg from the registered key set rather than taken from the
+  // general-purpose ACTIVE key, which the SigningKeyProvider contract does not
+  // guarantee to be RS256. Its public half is published at
+  // /.well-known/jwks.json under the same kid. The single-key context is kept as
+  // a fallback for providers that never populated the key set; on the default
+  // single RS256 key both branches resolve the same key.
+  const jarmSigningKeys = (c.get('signingKeys') as SigningKey[] | undefined) ?? [];
+  return {
+    issuer: c.get('config').issuer,
+    clientId: transaction.clientId,
+    signingKey: jarmSigningKeys.length > 0
+      ? selectSigningKeyByAlg(jarmSigningKeys, 'RS256')
+      : {
+          privateKey: c.get('privateKey'),
+          publicJwk: c.get('publicJwk'),
+          keyId: c.get('keyId'),
+        },
+  };
+}
+
+type JarmResponseContext = {
+  issuer: string;
+  clientId: string;
+  signingKey: SigningKey;
+};
+
+/**
+ * EXPERIMENTAL — JARM Section 2.3.1: deliver the authorization response as the
+ * single `response` query parameter holding a signed JWT. Without a JARM
+ * transaction this is the plain query response the OP has always produced
+ * (RFC 9207 Section 2 appends iss; in JARM mode the JWT's iss claim carries the
+ * same statement, so no plain iss parameter is added).
+ */
+async function buildConsentRedirect(
+  jarm: JarmResponseContext | undefined,
+  redirectUri: string,
+  parameters: Record<string, string | undefined>,
+  issuer: string,
+): Promise<string> {
+  if (jarm) {
+    return buildJarmRedirectUrl(
+      redirectUri,
+      await createJarmResponseJwt({
+        issuer: jarm.issuer,
+        clientId: jarm.clientId,
+        parameters,
+        signingKey: jarm.signingKey,
+        lifetimeSeconds: jarmConfig.jarmResponseLifetimeSeconds,
+      }),
+    );
+  }
+  const url = new URL(redirectUri);
+  for (const [name, value] of Object.entries(parameters)) {
+    if (value !== undefined) url.searchParams.set(name, value);
+  }
+  url.searchParams.set('iss', issuer);
+  return url.toString();
+}
+
 /**
  * Consent Page - GET
  * Displays the consent form for scope authorization.
@@ -63,15 +146,17 @@ consentApp.post('/', async (c) => {
   const issuer = config.issuer;
 
   if (action === 'deny') {
-    const redirectUrl = new URL(transaction.redirectUri);
-    redirectUrl.searchParams.set('error', 'access_denied');
-    if (transaction.state) {
-      redirectUrl.searchParams.set('state', transaction.state);
-    }
-    redirectUrl.searchParams.set('iss', issuer);
     await transactionStore.delete('auth_txn:' + transactionId);
     await authSessionStore.delete(transactionId);
-    return c.redirect(redirectUrl.toString());
+    // EXPERIMENTAL (JARM §2.1): a request that asked for response_mode=query.jwt
+    // gets its error as a signed JWT too, so the client can verify that the OP
+    // it trusts is the one that denied the request.
+    return c.redirect(
+      await buildConsentRedirect(resolveJarmResponse(c, transaction), transaction.redirectUri, {
+        error: 'access_denied',
+        state: transaction.state,
+      }, issuer),
+    );
   }
 
   // OIDC Core 1.0 Section 3.1.2.4: "the Authorization Server MUST obtain an
@@ -144,11 +229,10 @@ consentApp.post('/', async (c) => {
   await authSessionStore.delete(transactionId);
 
   // Redirect back to client with authorization code
-  const redirectUrl = new URL(responseParams.redirectUri);
-  redirectUrl.searchParams.set('code', authCodeData.code);
-  if (responseParams.state) {
-    redirectUrl.searchParams.set('state', responseParams.state);
-  }
-  redirectUrl.searchParams.set('iss', issuer);
-  return c.redirect(redirectUrl.toString());
+  return c.redirect(
+    await buildConsentRedirect(resolveJarmResponse(c, transaction), responseParams.redirectUri, {
+      code: authCodeData.code,
+      state: responseParams.state,
+    }, issuer),
+  );
 });
diff --git a/default-op/routes/discovery.ts b/with-jarm/routes/discovery.ts
index 72c0758..3eb0040 100644
--- a/default-op/routes/discovery.ts
+++ b/with-jarm/routes/discovery.ts
@@ -40,9 +40,10 @@ discoveryApp.get('/', (c) => {
     responseTypesSupported: ['code'],
     // OAuth 2.0 Multiple Response Type Encoding Practices §2 / OIDC Discovery 1.0 §3:
     // the OP only implements the authorization code flow, whose authorization
-    // response is returned via query, so response_modes_supported is pinned to
-    // ['query']. Extend this list when form_post (or other modes) are added.
-    responseModesSupported: ['query'],
+    // response is returned via query. EXPERIMENTAL (JARM §4): this provider was
+    // generated with --enable jarm, so the JWT-secured query modes are advertised
+    // alongside it. Extend this list when form_post (or other modes) are added.
+    responseModesSupported: ['query', 'query.jwt', 'jwt'],
     subjectTypesSupported: ['public'],
     idTokenSigningKeys,
     userinfoEndpoint: `${issuer}/userinfo`,
@@ -144,5 +145,9 @@ discoveryApp.get('/', (c) => {
   return c.json({
     ...metadata,
     code_challenge_methods_supported: ['S256'],
+    // EXPERIMENTAL — JARM §4 metadata. The response JWT is always signed with
+    // RS256 (JARM §3: the default for a client that registered no
+    // authorization_signed_response_alg), so exactly one alg is advertised.
+    authorization_signing_alg_values_supported: ['RS256'],
   });
 });
diff --git a/with-jarm/routes/jarm.ts b/with-jarm/routes/jarm.ts
new file mode 100644
index 0000000..303064e
--- /dev/null
+++ b/with-jarm/routes/jarm.ts
@@ -0,0 +1,29 @@
+/**
+ * EXPERIMENTAL — JWT Secured Authorization Response Mode (JARM).
+ *
+ * This module was generated because the OP was created with `--enable jarm`.
+ * It is backed by @maronn-openid-connect/experimental, whose API is NOT stable: it may
+ * change in a breaking way between releases. Do not build production code on it
+ * without pinning the version.
+ *
+ * Imported by the authorize and consent routes, so keep all three in sync when
+ * changing these settings.
+ *
+ * - jarmResponseLifetimeSeconds: how long the response JWT stays valid (its
+ *   `exp` claim). JARM Section 2.1 RECOMMENDs a maximum lifetime of 10 minutes,
+ *   so values outside 5-600 seconds fail fast at module load. Keep it short: the
+ *   JWT rides in a URL and only needs to survive one browser redirect.
+ *
+ * Not configurable: the signing algorithm (RS256, JARM Section 3's default for a
+ * client with no registered authorization_signed_response_alg), the response
+ * parameter name (`response`, JARM Section 2.3.1) and the supported response
+ * modes (`query.jwt` / `jwt` — this OP implements response_type=code only, so
+ * `fragment.jwt` and `form_post.jwt` are rejected with invalid_request).
+ */
+import { assertJarmLifetimeSeconds } from '@maronn-openid-connect/experimental/jarm';
+
+export const jarmConfig = {
+  jarmResponseLifetimeSeconds: 60,
+};
+
+assertJarmLifetimeSeconds(jarmConfig.jarmResponseLifetimeSeconds);

````

### 他フレームワークの差分

express と fastify は差分が同一なので 1 ファイルに集約されている。
nextjs も同等の内容である。

- [express-fastify](../../../tasks/experimental/done/jarm/promotion-review/generated-code/express-fastify.md)
- [nextjs](../../../tasks/experimental/done/jarm/promotion-review/generated-code/nextjs.md)

サンプルでこの機能を有効にしているのは [samples/hono-cloudflare](../../../samples/hono-cloudflare) だけである。

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
