# JWT Introspection Response（RFC 9701）実装解説

この文書は、`packages/experimental` に実装した **JWT Response for OAuth Token Introspection**（RFC 9701、Proposed Standard、2025 年 1 月発行）について、何を実装したのか、どう実装したのかを、関連するコードの全文とともに説明する。

この文書が全文を載せるのは次のコードである。

- `packages/experimental/src/jwt-introspection-response/` の実装 4 ファイルとテスト 3 ファイルのすべて
- CLI の `--enable jwt-introspection-response` が生成コードへ注入するコードの全文（hono）
- この機能の E2E テストスペックの全文

core 本体、E2E 共有ハーネス、他フレームワークの生成差分は全機能で共有される基盤なので、リンクで参照する。

## 機能の概要

トークンイントロスペクション（RFC 7662）は、リソースサーバーがトークンの状態を Authorization Server に問い合わせる仕組みで、応答は素の JSON で返る。
TLS を終端したあとの経路（多段ゲートウェイやサービスメッシュ）では、この JSON が改ざんされてもリソースサーバーは気づけず、応答がどの AS から来たのかも応答単体からは確かめられない。

RFC 9701 は、このイントロスペクション応答を AS が署名した JWT として返す仕組みである。
RFC 7662 の応答メンバーは `token_introspection` クレームに封入され、そこへ発行者（`iss`）、宛先（`aud`）、発行時刻（`iat`）が加わり、JOSE ヘッダに専用の `typ`（`token-introspection+jwt`）を立てて署名される。
リソースサーバーは JWKS で署名を検証し、`typ` と `iss` / `aud` を確認してから中身を使うので、応答の完全性と出所を暗号的に確認できる。

入口はリクエストの `Accept` ヘッダで、`application/token-introspection+jwt` を明示したときだけ応答が JWT になる。
指定しなければ従来どおりの RFC 7662 JSON が返る。

```text
Resource Server（クライアントとして登録済み）        OP
  |-- POST /introspect ------------------------------->|
  |   Accept: application/token-introspection+jwt      | クライアント認証・トークン解決（従来どおり）
  |   token=...                                        | Accept 判定 → audience 制限 → RS256 署名
  |<- 200 application/token-introspection+jwt ---------|
  |   <compact JWS>                                    |
  |  （JWKS で署名検証 → typ / iss / aud 確認 → token_introspection を利用）
```

### ユースケース

- マイクロサービス間や TLS 終端が多段の構成で、イントロスペクション結果の改ざん耐性と出所検証を要件に持つ設計を PoC する
- FAPI 系・高保証 API を見据え、署名付きイントロスペクションの RS 側検証チェーン（JWKS 解決、署名検証、`typ` 確認、クレーム利用）を手元で確認する
- `typ` 検証を怠った RS 実装に対する cross-JWT confusion（イントロスペクション JWT のアクセストークンへの流用）が、どの検証で止まるかを再現する

### 実装スコープと非目標

実装したのは次の範囲である。

- `Accept` ヘッダの判定（§4。メディアタイプの明示一致のみ）
- 呼び出し元 audience 制限（§3 / §5。発行先本人または `aud` 記載先以外には `{"active": false}`）
- 応答 JWT の生成（§5。`typ: token-introspection+jwt`、トップレベル `iss` / `aud` / `iat`、`token_introspection` への封入、RS256 固定）
- discovery への `introspection_signing_alg_values_supported: ["RS256"]` の広告（§7）

非目標は次のとおりである。

- クライアント別の `introspection_signed_response_alg`（§6）。本 OP はクライアント別 alg を持たないため、§6 の省略時既定である RS256 に固定する（JARM と同じ判断）
- 応答 JWT の暗号化（§6 の Nested JWT / JWE）。JWE 基盤が本リポジトリに無いため対象にしない
- アクセストークンによるイントロスペクション呼び出しの認証（§4）。従来どおりクライアント認証のみとし、RS はクライアントとして登録する
- JSON 応答経路の挙動変更。`Accept` で JWT を要求しないリクエストへの応答は、audience 制限を含め一切変えない

## 実装の設計方針

ファイルは実装 3 つと公開 API で構成する。

| ファイル | 役割 |
|---|---|
| `accept.ts` | `Accept` ヘッダの判定 |
| `audience.ts` | 呼び出し元 audience 制限 |
| `response-jwt.ts` | 応答 JWT の生成 |
| `index.ts` | 公開 API の再エクスポート |

設計判断は 5 つある。

第一に、`Accept` の判定はメディアタイプの明示一致だけを見る。
カンマ区切りの各要素から `;` より前を取り出して小文字比較し、`*/*` や `application/*` のワイルドカードは JWT 要求と解釈しない。
汎用 HTTP クライアントは既定で `Accept: */*` を送るので、ワイルドカードを JWT と解釈すると従来型リクエストの応答形式まで変わり、RFC 7662 の後方互換が壊れるためである。
q 値による選好解決もしない（§4 に q 値の規定は無く、拒否したい RS はメディアタイプ自体を送らなければよい）。

第二に、audience 制限は fail-closed かつオラクルを作らない形にする。
開示できるのは、呼び出し元の client_id がトークンの発行先（`client_id` メンバー）か `aud` メンバーに一致する場合だけで、該当しなければ core の `INACTIVE_INTROSPECTION_RESPONSE` そのものを返す。
新しいオブジェクトを組み立てず共有シングルトンを返すのは、制限された応答を「もともと無効なトークンへの応答」とバイト単位で同一にし、制限が働いたこと自体を漏らさないためである。

第三に、署名は Web Crypto API（`crypto.subtle.sign`）で compact JWS を組み立てる自前実装である。
core にも同種の署名コードがあるが非公開ヘルパーであり、core 無変更の制約下では使えない。
JARM の `response-jwt.ts` と同種のコードになるが、experimental 機能は独立性を優先して重複を許容する方針に従い、機能内に閉じた実装とした。

第四に、設定値とエラークラスを持たない。
署名 alg は RS256 固定（§6 の省略時既定と一致）で、応答 JWT は `exp` を持たない（§5 SHOULD NOT）ため、JARM に存在した寿命設定に相当するものが無い。
各関数は入力が公開 API の契約を満たす限り失敗せず、鍵の不一致は Web Crypto の例外がそのまま伝播して生成コードの既存 `server_error` 分岐に落ちる。

第五に、生成コード側の応答分岐は、クライアント認証とトークン解決がすべて終わった後の応答出口だけに置く。
`Accept` ヘッダの値が認証やトークン解決を迂回する経路を構造的に作らないためで（§8.2 のダウングレード防止）、JARM が authorize ルートの応答出口に合流したのと同じ構造である。
返却には hono の `c.body` を使う。
仕様書の未解決事項 U2 は `c.text` を予定していたが、実装時の conformance テストで hono の `c.text` が設定済み `Content-Type` を `text/plain` で上書きすることが判明したため、設定済みヘッダを保持する `c.body`（web-standard 変換先の `WebContext.body` も同挙動）へ変更した。

## 実装コードの全文と解説

### accept.ts（Accept ヘッダの判定）

```typescript
/**
 * JWT Response for OAuth Token Introspection (RFC 9701) — Accept ヘッダ判定。
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * RFC 9701 §4: リソースサーバーは Accept ヘッダを
 * `application/token-introspection+jwt` に設定して署名付き JWT の応答を要求する。
 * 本 OP はメディアタイプが明示された場合のみ JWT で応答し、ワイルドカード
 * （star-slash-star や `application/star`）は JWT 応答の要求と解釈しない。
 * ワイルドカードを JWT と解釈すると、汎用 HTTP クライアントが既定で送る
 * ワイルドカード Accept を持つ従来型リクエストの応答形式まで変わり、
 * RFC 7662 の後方互換が壊れるためである。
 */

/** RFC 9701 §4 / §5: 署名付きイントロスペクション応答のメディアタイプ。 */
export const TOKEN_INTROSPECTION_JWT_MEDIA_TYPE = 'application/token-introspection+jwt';

/**
 * Accept ヘッダが署名付き JWT のイントロスペクション応答を要求しているかを返す。
 *
 * カンマ区切りの各要素からメディアタイプ部分（`;` より前）を取り出し、
 * 前後空白を除いて小文字化した値が {@link TOKEN_INTROSPECTION_JWT_MEDIA_TYPE}
 * と完全一致する要素が 1 つでもあれば true。q 値による選好順位は解決しない
 * （`;q=0` の明示的拒否も JWT 要求として扱う。§4 に q 値の規定はなく、拒否
 * したい RS はメディアタイプ自体を送らなければよい）。
 */
export function acceptsIntrospectionJwt(acceptHeader: string | null | undefined): boolean {
  if (acceptHeader === null || acceptHeader === undefined || acceptHeader === '') {
    return false;
  }
  return acceptHeader.split(',').some((element) => {
    const mediaType = element.split(';')[0]?.trim().toLowerCase();
    return mediaType === TOKEN_INTROSPECTION_JWT_MEDIA_TYPE;
  });
}
```

判定は「カンマで分割 → 各要素の `;` より前 → trim → 小文字化 → 完全一致」の一本道である。
`null` / `undefined` / 空文字を最初に落としているのは、生成コードの `c.req.header('Accept')` がヘッダ不在時に `undefined` を返すためで、呼び出し側に前処理を要求しない。

### audience.ts（呼び出し元 audience 制限）

```typescript
/**
 * JWT Response for OAuth Token Introspection (RFC 9701) — 呼び出し元 audience 制限。
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * RFC 9701 §3: AS は「リソースサーバーがそのアクセストークンの audience で
 * あるか」を判定できなければならない（MUST）。§5: トークンが呼び出し元 RS
 * 宛でない場合、`token_introspection.active` を false にし、他のメンバーを
 * 含めてはならない（MUST NOT）。
 *
 * この制限は JWT 応答経路にのみ適用する。Accept で JWT を要求しない従来の
 * RFC 7662 JSON 応答には適用せず、既存利用者のイントロスペクション挙動を
 * 変えない（JSON 経路の呼び出し元認可は core 側の将来フックの責務）。
 */
import {
  INACTIVE_INTROSPECTION_RESPONSE,
  type IntrospectionResponse,
} from '@maronn-openid-connect/core';

/**
 * イントロスペクション応答を、認証済み呼び出し元へ開示できる形に制限する。
 *
 * `active: true` の応答をそのまま返すのは、呼び出し元の client_id が
 * 「トークンの発行先（`client_id` メンバー）」または「トークンの `aud`
 * メンバー（文字列または配列）」に一致する場合のみ。どちらにも該当しない
 * 場合は `{ active: false }` に置き換え、制限が働いたことを応答から区別
 * させない（RFC 7662 §2.2 の「存在しないトークンと区別させない」原則と
 * 同じオラクル防止）。`active: false` の応答は常にそのまま返す。
 *
 * 入力オブジェクトは変更しない（純関数）。
 */
export function restrictIntrospectionResponseToCaller(
  response: IntrospectionResponse,
  callerClientId: string,
): IntrospectionResponse {
  if (!response.active) {
    return response;
  }
  if (response.client_id === callerClientId) {
    return response;
  }
  if (response.aud === callerClientId) {
    return response;
  }
  if (Array.isArray(response.aud) && response.aud.includes(callerClientId)) {
    return response;
  }
  return INACTIVE_INTROSPECTION_RESPONSE;
}
```

判定材料は応答オブジェクトだけで揃う。
core の `buildIntrospectionResponse` が返す応答は発行先（`client_id`）と、保存されている場合の `aud` を含むので、ストアへの追加アクセスも core の変更も要らない。
`active: false` の応答を先頭で素通ししているのは、無効なトークンの応答には制限すべき属性がそもそも無いからである。

### response-jwt.ts（応答 JWT の生成）

```typescript
/**
 * JWT Response for OAuth Token Introspection (RFC 9701) — 応答 JWT 生成。
 *
 * Experimental: このモジュールの API は安定していない。破壊的変更があり得る。
 *
 * RFC 9701 §5 のクレーム構造でイントロスペクション応答を署名付き JWT にする。
 * 署名は Web Crypto API（`crypto.subtle.sign`）で compact JWS を組み立てる
 * 自前実装であり、core の非公開な低レベル署名ヘルパーには依存しない
 * （core 無変更の維持）。JARM の response-jwt と同種のコードになるが、
 * Experimental 機能は独立性を優先して重複を許容する方針に従う。
 */
import type { IntrospectionResponse, SigningKey } from '@maronn-openid-connect/core';

/**
 * RFC 9701 §5 REQUIRED: 応答 JWT の `typ` JOSE ヘッダ。
 *
 * cross-JWT confusion（§8.1: イントロスペクション JWT をアクセストークンや
 * ID トークンとして流用する攻撃）対策の要であり、RS は検証時にこの値を
 * 確認しなければならない。
 */
export const TOKEN_INTROSPECTION_JWT_TYP = 'token-introspection+jwt';

/**
 * 応答 JWT の署名アルゴリズム。
 *
 * RFC 9701 §6: クライアントが `introspection_signed_response_alg` を登録して
 * いない場合の既定は RS256。この OP はクライアント別 alg を持たないため
 * RS256 固定とする（JARM と同じ固定方針）。固定であることの裏返しとして、
 * {@link createIntrospectionResponseJwt} に渡す `signingKey` は RS256 鍵で
 * なければならない。別種の鍵では Web Crypto が署名を拒否して例外になるため、
 * `alg: RS256` を偽って表明する JWS が生成されることはない。
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
 * イントロスペクション応答を RFC 9701 §5 のクレーム構造で署名付き JWT にする。
 *
 * - JOSE ヘッダー: `{ typ: 'token-introspection+jwt', alg: 'RS256', kid }`。
 *   `typ` は §5 REQUIRED、`kid` は JWKS で検証鍵を特定させる（RFC 8725 §3.10
 *   の実践。JARM と同じ）。
 * - ペイロード: `iss` / `aud` / `iat`（いずれも §5 MUST）と、RFC 7662 の応答
 *   メンバーをそのまま収めた `token_introspection` クレーム。トップレベルに
 *   `sub` / `exp` は含めない（§5 SHOULD NOT — アクセストークンとしての悪用
 *   防止。§8.1）。
 * - `token_introspection` の中身は渡された応答オブジェクトそのもので、
 *   メンバーの追加・削除・改変はしない。active でない応答も同じ構造で
 *   JWT 化する（§5: active を false にし他のメンバーを含めない —
 *   `INACTIVE_INTROSPECTION_RESPONSE` がその形そのもの）。
 *
 * @param options.issuer `iss` クレーム（OP の issuer）
 * @param options.audience `aud` クレーム。認証済み呼び出し元の client_id
 *   （§5 MUST: 「introspection response を受け取る RS を識別」。この OP は RS
 *   をクライアントとして登録するため client_id が識別子になる）
 * @param options.introspection `token_introspection` クレームに封入する応答。
 *   呼び出し側で {@link restrictIntrospectionResponseToCaller} を通した値を
 *   渡すこと
 * @param options.signingKey 応答 JWT の署名鍵。**RS256 鍵であること**（JOSE
 *   ヘッダの `alg` は常に RS256 固定なので、他の alg の鍵を渡すと Web Crypto
 *   が署名を拒否して例外になる）。生成コードは登録鍵セットから
 *   `selectSigningKeyByAlg(keys, 'RS256')` で選ぶこと
 * @param options.now `iat` の発行時刻（テスト用の注入点。既定は現在時刻）
 */
export async function createIntrospectionResponseJwt(options: {
  issuer: string;
  audience: string;
  introspection: IntrospectionResponse;
  signingKey: SigningKey;
  now?: Date;
}): Promise<string> {
  const issuedAtSeconds = Math.floor((options.now ?? new Date()).getTime() / 1000);

  // RFC 9701 §5: iss / aud / iat are MUST; the RFC 7662 members travel inside
  // token_introspection and are never spread onto the top level (§8.1).
  const claims: Record<string, unknown> = {
    iss: options.issuer,
    aud: options.audience,
    iat: issuedAtSeconds,
    token_introspection: options.introspection,
  };

  const encodedHeader = base64UrlFromJson({
    typ: TOKEN_INTROSPECTION_JWT_TYP,
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
```

クレームの構成は §5 の MUST（`iss` / `aud` / `iat` / `token_introspection`）だけで、トップレベルに `sub` / `exp` を置かない。
これは応答 JWT がアクセストークンとして流用される余地（§8.1）を構造から消すためで、`typ` の固定と合わせて cross-JWT confusion 対策の実装点になっている。
`token_introspection` には渡された応答オブジェクトをそのまま入れ、メンバーの追加や削除をしない。
応答の中身を決めるのは core と `restrictIntrospectionResponseToCaller` の責務で、署名層が内容へ関与しない分担にしている。

### index.ts（公開 API）

```typescript
/**
 * JWT Response for OAuth Token Introspection — RFC 9701 (Proposed Standard,
 * 2025-01)
 *
 * **Experimental**: この機能の API は安定していない。マイナーリリースでも
 * 破壊的に変更されることがある。本番運用の前に
 * `docs/library-document` の Experimental セクションを確認すること。
 *
 * `@maronn-openid-connect/core` とは別 package であり、CLI で
 * `--enable jwt-introspection-response` を明示したときのみ生成コードから利用される。
 *
 * スコープは**署名付き応答（RS256 固定）のみ**に限定する。暗号化応答
 * （§6 の Nested JWT）・クライアント別 `introspection_signed_response_alg`
 * （§6）・アクセストークンによる RS 認証（§4）は非対応。Accept で JWT を
 * 要求しない従来の RFC 7662 JSON 応答は一切変えない。
 */
export {
  TOKEN_INTROSPECTION_JWT_MEDIA_TYPE,
  acceptsIntrospectionJwt,
} from './accept.js';

export { restrictIntrospectionResponseToCaller } from './audience.js';

export {
  TOKEN_INTROSPECTION_JWT_TYP,
  createIntrospectionResponseJwt,
} from './response-jwt.js';
```

## 単体テストの全文

テストは t_wada 流の TDD で、`accept` → `audience` → `response-jwt` の順に red → green で書いた。
アサーションは合格値を一意に固定する規約（リポジトリの `README.md`）に従い、JOSE ヘッダとペイロードは `toEqual` で全体を固定している。

### accept.test.ts

```typescript
import { describe, expect, it } from 'vitest';
import { TOKEN_INTROSPECTION_JWT_MEDIA_TYPE, acceptsIntrospectionJwt } from './accept.js';

describe('acceptsIntrospectionJwt', () => {
  describe('Explicit media type (RFC 9701 §4)', () => {
    it('should return true for the exact media type', () => {
      expect(acceptsIntrospectionJwt('application/token-introspection+jwt')).toBe(true);
    });

    it('should match the media type case-insensitively', () => {
      expect(acceptsIntrospectionJwt('Application/Token-Introspection+JWT')).toBe(true);
    });

    it('should match the media type inside a multi-element Accept header', () => {
      expect(
        acceptsIntrospectionJwt('application/json, application/token-introspection+jwt'),
      ).toBe(true);
    });

    it('should ignore media type parameters such as a q value', () => {
      expect(acceptsIntrospectionJwt('application/token-introspection+jwt;q=0.9')).toBe(true);
    });

    it('should tolerate surrounding whitespace around list elements', () => {
      expect(
        acceptsIntrospectionJwt('application/json ,  application/token-introspection+jwt '),
      ).toBe(true);
    });
  });

  describe('Requests that stay on the RFC 7662 JSON path', () => {
    it('should return false for a missing header', () => {
      expect(acceptsIntrospectionJwt(undefined)).toBe(false);
    });

    it('should return false for a null header', () => {
      expect(acceptsIntrospectionJwt(null)).toBe(false);
    });

    it('should return false for an empty header', () => {
      expect(acceptsIntrospectionJwt('')).toBe(false);
    });

    it('should return false for application/json', () => {
      expect(acceptsIntrospectionJwt('application/json')).toBe(false);
    });

    // A generic HTTP client's default Accept must not flip the response format:
    // only the explicitly named RFC 9701 media type requests the JWT.
    it('should return false for the full wildcard', () => {
      expect(acceptsIntrospectionJwt('*/*')).toBe(false);
    });

    it('should return false for the application type wildcard', () => {
      expect(acceptsIntrospectionJwt('application/*')).toBe(false);
    });

    it('should return false for an unrelated jwt-suffixed media type', () => {
      expect(acceptsIntrospectionJwt('application/jwt')).toBe(false);
    });
  });

  describe('Media type constant', () => {
    it('should expose the RFC 9701 media type verbatim', () => {
      expect(TOKEN_INTROSPECTION_JWT_MEDIA_TYPE).toBe('application/token-introspection+jwt');
    });
  });
});
```

### audience.test.ts

```typescript
import { INACTIVE_INTROSPECTION_RESPONSE, type IntrospectionResponse } from '@maronn-openid-connect/core';
import { describe, expect, it } from 'vitest';
import { restrictIntrospectionResponseToCaller } from './audience.js';

function activeResponse(overrides: Partial<Extract<IntrospectionResponse, { active: true }>> = {}): IntrospectionResponse {
  return {
    active: true,
    scope: 'openid',
    client_id: 'issued-to-client',
    token_type: 'Bearer',
    sub: 'testuser',
    exp: 1785801600,
    ...overrides,
  };
}

describe('restrictIntrospectionResponseToCaller', () => {
  describe('Responses disclosed to the caller (RFC 9701 §3)', () => {
    it('should return the response unchanged for the client the token was issued to', () => {
      const response = activeResponse();

      expect(restrictIntrospectionResponseToCaller(response, 'issued-to-client')).toEqual({
        active: true,
        scope: 'openid',
        client_id: 'issued-to-client',
        token_type: 'Bearer',
        sub: 'testuser',
        exp: 1785801600,
      });
    });

    it('should return the response unchanged for a caller listed in a string aud', () => {
      const response = activeResponse({ aud: 'rs-client' });

      expect(restrictIntrospectionResponseToCaller(response, 'rs-client')).toEqual({
        active: true,
        scope: 'openid',
        client_id: 'issued-to-client',
        token_type: 'Bearer',
        sub: 'testuser',
        exp: 1785801600,
        aud: 'rs-client',
      });
    });

    it('should return the response unchanged for a caller listed in an array aud', () => {
      const response = activeResponse({ aud: ['http://localhost:3000/userinfo', 'rs-client'] });

      expect(restrictIntrospectionResponseToCaller(response, 'rs-client')).toEqual({
        active: true,
        scope: 'openid',
        client_id: 'issued-to-client',
        token_type: 'Bearer',
        sub: 'testuser',
        exp: 1785801600,
        aud: ['http://localhost:3000/userinfo', 'rs-client'],
      });
    });
  });

  describe('Responses withheld from the caller (RFC 9701 §5 MUST NOT)', () => {
    it('should replace the response with active false only for a caller that is neither issuee nor audience', () => {
      const response = activeResponse({ aud: ['http://localhost:3000/userinfo'] });

      expect(restrictIntrospectionResponseToCaller(response, 'other-client')).toEqual({
        active: false,
      });
    });

    it('should withhold a response without an aud member from every caller but the issuee', () => {
      const response = activeResponse();

      expect(restrictIntrospectionResponseToCaller(response, 'other-client')).toEqual({
        active: false,
      });
    });

    // The withheld shape must be the shared inactive singleton so a restricted
    // response is byte-identical to a genuinely inactive one (no oracle).
    it('should return the shared inactive response object when withholding', () => {
      const restricted = restrictIntrospectionResponseToCaller(activeResponse(), 'other-client');

      expect(restricted).toBe(INACTIVE_INTROSPECTION_RESPONSE);
    });
  });

  describe('Inactive responses', () => {
    it('should pass an inactive response through unchanged', () => {
      const response: IntrospectionResponse = { active: false };

      expect(restrictIntrospectionResponseToCaller(response, 'any-client')).toBe(response);
    });
  });

  describe('Purity', () => {
    it('should not mutate the input response when withholding', () => {
      const response = activeResponse({ aud: 'someone-else' });

      restrictIntrospectionResponseToCaller(response, 'other-client');

      expect(response).toEqual({
        active: true,
        scope: 'openid',
        client_id: 'issued-to-client',
        token_type: 'Bearer',
        sub: 'testuser',
        exp: 1785801600,
        aud: 'someone-else',
      });
    });
  });
});
```

制限時に共有シングルトンが返ることを `toBe` で固定しているテストが、設計判断（オラクル防止）の回帰ガードになっている。

### response-jwt.test.ts

```typescript
import type { IntrospectionResponse, SigningKey } from '@maronn-openid-connect/core';
import { beforeAll, describe, expect, it } from 'vitest';
import { TOKEN_INTROSPECTION_JWT_TYP, createIntrospectionResponseJwt } from './response-jwt.js';

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

// 2026-08-24T00:00:00Z. Injected so every iat assertion is a fixed value.
const NOW = new Date('2026-08-24T00:00:00.000Z');
const NOW_SECONDS = 1787529600;

const ACTIVE_INTROSPECTION: IntrospectionResponse = {
  active: true,
  scope: 'openid',
  client_id: 'rs-client',
  token_type: 'Bearer',
  sub: 'testuser',
  exp: NOW_SECONDS + 3600,
};

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
  signingKey = { privateKey: keyPair.privateKey, publicJwk, keyId: 'introspection-key-1' };
  publicKey = keyPair.publicKey;
});

describe('createIntrospectionResponseJwt', () => {
  describe('JOSE Header', () => {
    // RFC 9701 §5 REQUIRED typ + §8.1: the typ header is what stops the response
    // JWT from being replayed as an access token or ID token.
    it('should set typ to token-introspection+jwt, alg to RS256 and kid to the signing key id', async () => {
      const jwt = await createIntrospectionResponseJwt({
        issuer: 'http://localhost:3000',
        audience: 'rs-client',
        introspection: ACTIVE_INTROSPECTION,
        signingKey,
        now: NOW,
      });

      expect(header(jwt)).toEqual({
        typ: 'token-introspection+jwt',
        alg: 'RS256',
        kid: 'introspection-key-1',
      });
    });
  });

  describe('Payload claims (RFC 9701 §5)', () => {
    it('should carry iss, aud, iat and the token_introspection claim with the response verbatim', async () => {
      const jwt = await createIntrospectionResponseJwt({
        issuer: 'http://localhost:3000',
        audience: 'rs-client',
        introspection: ACTIVE_INTROSPECTION,
        signingKey,
        now: NOW,
      });

      expect(payload(jwt)).toEqual({
        iss: 'http://localhost:3000',
        aud: 'rs-client',
        iat: NOW_SECONDS,
        token_introspection: {
          active: true,
          scope: 'openid',
          client_id: 'rs-client',
          token_type: 'Bearer',
          sub: 'testuser',
          exp: NOW_SECONDS + 3600,
        },
      });
    });

    // RFC 9701 §5 SHOULD NOT: top-level sub / exp would let the JWT pass for an
    // access token; the member set is pinned so neither can appear.
    it('should not put sub or exp on the top level', async () => {
      const jwt = await createIntrospectionResponseJwt({
        issuer: 'http://localhost:3000',
        audience: 'rs-client',
        introspection: ACTIVE_INTROSPECTION,
        signingKey,
        now: NOW,
      });

      expect(Object.keys(payload(jwt))).toEqual(['iss', 'aud', 'iat', 'token_introspection']);
    });

    // RFC 9701 §5: an unknown or expired token is answered with the same JWT
    // structure whose token_introspection carries only active: false.
    it('should wrap an inactive response as token_introspection with active false only', async () => {
      const jwt = await createIntrospectionResponseJwt({
        issuer: 'http://localhost:3000',
        audience: 'rs-client',
        introspection: { active: false },
        signingKey,
        now: NOW,
      });

      expect(payload(jwt)).toEqual({
        iss: 'http://localhost:3000',
        aud: 'rs-client',
        iat: NOW_SECONDS,
        token_introspection: { active: false },
      });
    });

    it('should derive iat deterministically from the injected now', async () => {
      const jwt = await createIntrospectionResponseJwt({
        issuer: 'http://localhost:3000',
        audience: 'rs-client',
        introspection: { active: false },
        signingKey,
        now: new Date('2026-08-24T00:00:59.999Z'),
      });

      expect(payload(jwt).iat).toBe(NOW_SECONDS + 59);
    });
  });

  describe('Signature', () => {
    it('should produce a compact JWS whose signature verifies with the public key', async () => {
      const jwt = await createIntrospectionResponseJwt({
        issuer: 'http://localhost:3000',
        audience: 'rs-client',
        introspection: ACTIVE_INTROSPECTION,
        signingKey,
        now: NOW,
      });

      const [encodedHeader = '', encodedPayload = ''] = jwt.split('.');
      const verified = await crypto.subtle.verify(
        'RSASSA-PKCS1-v1_5',
        publicKey,
        signatureBytes(jwt),
        new TextEncoder().encode(`${encodedHeader}.${encodedPayload}`),
      );

      expect(jwt.split('.').length).toBe(3);
      expect(verified).toBe(true);
    });
  });

  describe('typ constant', () => {
    it('should expose the RFC 9701 typ value verbatim', () => {
      expect(TOKEN_INTROSPECTION_JWT_TYP).toBe('token-introspection+jwt');
    });
  });
});
```

`Object.keys(payload(jwt))` の固定が「トップレベルに `sub` / `exp` が無い」ことの検証で、クレームが 1 つ増えただけでも失敗する。

## CLI 統合と生成コードへの寄与

`maronn-oidc generate <framework> --enable jwt-introspection-response` を指定すると、生成コードに次が入る。

- **routes/introspection.ts の変更**：応答構築後の出口に `Accept` 判定と JWT 応答分岐が入る。新しい HTTP ルートは増えない
- **routes/discovery.ts の変更**：`introspection_signing_alg_values_supported: ['RS256']` を広告する
- **conformance.test.ts の変更**：上記の挙動一式を契約テストとして固定する

feature-id の解決には組み合わせ検証が 1 つある。
RFC 9701 の応答は RFC 7662 のエンドポイントが運ぶので、`--enable jwt-introspection-response --disable introspection` は生成する場所が無い。
`packages/cli/src/features.ts` の `resolveFeatures` は解決後にこの組を検査し、理由つきのエラーで拒否する（cross-feature 依存の検証は本機能が初である）。

```typescript
  // Cross-feature dependency: the RFC 9701 JWT response rides on the RFC 7662
  // introspection endpoint, which is not generated when introspection is
  // disabled — there would be nowhere to answer with the JWT.
  if (features.jwtIntrospectionResponse && !features.introspection) {
    throw new Error(
      'Feature "jwt-introspection-response" requires the introspection feature: ' +
        'the RFC 9701 JWT response is returned by the RFC 7662 introspection endpoint, ' +
        'which is not generated when introspection is disabled',
    );
  }
```

機能を有効にしない生成出力は、変更前の CLI とバイト単位で同一である。
conformance の契約ブロックも機能無効時は一切出力しない（無効時の契約は「生成コードに分岐も discovery メタデータも存在しないこと」であり、CLI のジェネレータテストが固定している）。

### routes/introspection.ts に入るコード

import には、core からの 2 名（`selectSigningKeyByAlg` / `SigningKey` 型）と、experimental subpath からの 4 名が加わる。

```typescript
import {
  extractClientCredentials,
  resolveAuthenticatedTokenClient,
  validateClientAuthMethod,
  verifyClientSecret,
  requireIntrospectionToken,
  requireIntrospectionClient,
  requireConfidentialIntrospectionCaller,
  resolveIntrospectionToken,
  isIntrospectionTokenActive,
  buildIntrospectionResponse,
  INACTIVE_INTROSPECTION_RESPONSE,
  IntrospectionError,
  TokenError,
  selectSigningKeyByAlg,
  type SigningKey,
  type IntrospectionResponse,
} from '@maronn-openid-connect/core';
```

```typescript
import {
  TOKEN_INTROSPECTION_JWT_MEDIA_TYPE,
  acceptsIntrospectionJwt,
  createIntrospectionResponseJwt,
  restrictIntrospectionResponseToCaller,
} from '@maronn-openid-connect/experimental/jwt-introspection-response';
```

import 一覧に見える `requireConfidentialIntrospectionCaller` は本機能の追加ではなく、introspection ルート共通のステップである（`tasks/done/p1-introspection-reject-public-client-caller.md`）。
クライアント認証パイプラインの直後で `token_endpoint_auth_method: 'none'` の呼び出し元を `invalid_client`（401）で拒否する。
public client の client_id は公開情報であり、その提示だけでは認証にならないためである（RFC 7662 §2.1 / RFC 9701 §5）。
JWT 分岐はこの拒否より後ろにあるので、`Accept` ヘッダで迂回できない。

ハンドラ本体では、応答オブジェクト `response` を構築した直後、従来の `return c.json(response)` の直前に次の分岐が入る。

```typescript
    // EXPERIMENTAL — RFC 9701 §4 / §5: a caller whose Accept header names
    // application/token-introspection+jwt receives the introspection response
    // as a signed JWT. Any other request (no Accept, application/json, a
    // wildcard) is answered exactly as before, and the branch sits AFTER client
    // authentication and token resolution so the Accept header can never
    // bypass either (§8.2 downgrade prevention).
    if (acceptsIntrospectionJwt(c.req.header('Accept'))) {
      // RFC 9701 §3 / §5: before the response leaves as a signed assertion its
      // members are restricted to what the authenticated caller may see — a
      // caller that is neither the client the token was issued to nor listed in
      // its aud gets { active: false }, indistinguishable from an unknown token.
      const restrictedResponse = restrictIntrospectionResponseToCaller(
        response,
        authenticatedClientId,
      );
      // RFC 9701 §6: alg is pinned to RS256 (the default for a client that
      // registered no introspection_signed_response_alg). The general-purpose
      // ACTIVE key is not guaranteed to be RS256 — SigningKeyProvider may
      // legitimately return ES256 as active alongside an RS256 + ES256
      // registered set — so the key is picked by alg from the registered set.
      // Its public half is published at /.well-known/jwks.json under the same
      // kid. selectSigningKeyByAlg throws when no RS256 key is registered,
      // which surfaces as a server_error below (a configuration mistake)
      // rather than as an unverifiable introspection response.
      const introspectionSigningKeys = (c.get('signingKeys') as SigningKey[] | undefined) ?? [];
      const introspectionSigningKey = introspectionSigningKeys.length > 0
        ? selectSigningKeyByAlg(introspectionSigningKeys, 'RS256')
        : {
            // Falls back to the single-key context so a hand-wired provider
            // that never populated the key set keeps working; on the default
            // single RS256 key both branches resolve the same key.
            privateKey: c.get('privateKey'),
            publicJwk: c.get('publicJwk'),
            keyId: c.get('keyId'),
          };
      const responseJwt = await createIntrospectionResponseJwt({
        issuer: c.get('config').issuer,
        audience: authenticatedClientId,
        introspection: restrictedResponse,
        signingKey: introspectionSigningKey,
      });
      // RFC 9701 §5: the success response is the compact JWS itself under its
      // own media type. c.body (unlike c.text, which forces text/plain) keeps
      // the explicitly set Content-Type, and the cache-busting headers set at
      // the top of the handler still apply.
      c.header('Content-Type', TOKEN_INTROSPECTION_JWT_MEDIA_TYPE);
      return c.body(responseJwt);
    }
```

鍵の選択が active key ではなく登録鍵セットからの alg 選択なのは、JARM と同じ理由による。
`SigningKeyProvider` の契約上、active key が ES256 で登録セットに RS256 + ES256 が並ぶ構成は正当であり、`alg: RS256` を表明する JWT は RS256 鍵で署名しなければならない。
RS256 鍵が無い構成では `selectSigningKeyByAlg` が例外を投げ、既存の catch で `server_error` になる（誤った `alg` を表明した検証不能な JWT を返すことはない）。

### routes/discovery.ts に入るコード

discovery の最終 `c.json` のスプレッドマージ（PAR / Device / CIBA / JARM / ID-JAG のメタデータと同じ場所）に、次の 1 エントリが加わる。

```typescript
    // EXPERIMENTAL — RFC 9701 §7 metadata. The introspection response JWT is
    // always signed with RS256 (§6: the default for a client that registered no
    // introspection_signed_response_alg), so exactly one alg is advertised.
    introspection_signing_alg_values_supported: ['RS256'],
```

### conformance.test.ts に入るコード

テストクライアントの登録に、発行先でも `aud` 記載先でもない呼び出し元が 1 つ加わる。

```typescript
  // EXPERIMENTAL (RFC 9701 §3): a registered confidential client that is
  // neither the issuee nor an audience of the introspected test tokens, so the
  // caller restriction on the JWT response path can be pinned.
  ['c-introspect-other', {
    clientId: 'c-introspect-other',
    clientSecret: 's',
    redirectUris: [REDIRECT_URI],
    clientType: 'confidential' as const,
    responseTypes: ['code'],
    grantTypes: ['authorization_code'],
    tokenEndpointAuthMethod: 'client_secret_post',
  }],
```

契約テスト本体は次のとおりである。
JWKS から `kid` で鍵を解決して RS256 検証するヘルパーは JARM の conformance ブロックにも同型があるが、機能間でヘルパーを共有しない方針（重複許容）に従い、このブロック内に複製している。

```typescript
  // EXPERIMENTAL — JWT Response for OAuth Token Introspection (RFC 9701).
  // Generated because this provider was created with --enable
  // jwt-introspection-response. These tests pin the contract the repository
  // guarantees for the JWT-shaped introspection response: change the behavior
  // and they fail, which is how a customized OP learns it drifted.
  describe('JWT introspection response (RFC 9701)', () => {
    const INTROSPECTION_JWT_MEDIA_TYPE = 'application/token-introspection+jwt';

    function introspectWith(body: Record<string, string>, accept?: string): Promise<Response> {
      const headers: Record<string, string> = {
        'Content-Type': 'application/x-www-form-urlencoded',
      };
      if (accept !== undefined) headers.Accept = accept;
      return app.request('/introspect', {
        method: 'POST',
        headers,
        body: new URLSearchParams(body).toString(),
      });
    }

    // Pure helpers: they fetch, parse and verify only. Every assertion lives in
    // an it(), and none of them branches on the OP's behavior. The JWKS-based
    // verifier is deliberately local to this block (features do not share
    // conformance helpers).
    function decodeIntrospectionJwtSegment(segment: string): Record<string, unknown> {
      const base64 = segment.replace(/-/g, '+').replace(/_/g, '/');
      const padded = base64.padEnd(base64.length + ((4 - (base64.length % 4)) % 4), '=');
      const bytes = Uint8Array.from(atob(padded), (char) => char.charCodeAt(0));
      return JSON.parse(new TextDecoder().decode(bytes));
    }

    async function inspectIntrospectionJwt(jwt: string): Promise<{
      header: Record<string, unknown>;
      payload: Record<string, unknown>;
      signatureValid: boolean;
    }> {
      const [encodedHeader = '', encodedPayload = '', encodedSignature = ''] = jwt.split('.');
      const header = decodeIntrospectionJwtSegment(encodedHeader);
      const jwks = await (await app.request('/.well-known/jwks.json')).json();
      const jwk = (jwks.keys as Array<Record<string, unknown>>).find(
        (candidate) => candidate.kid === header.kid,
      );
      const key = await crypto.subtle.importKey(
        'jwk',
        { kty: 'RSA', n: jwk?.n as string, e: jwk?.e as string },
        { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
        false,
        ['verify'],
      );
      const base64 = encodedSignature.replace(/-/g, '+').replace(/_/g, '/');
      const padded = base64.padEnd(base64.length + ((4 - (base64.length % 4)) % 4), '=');
      const signatureValid = await crypto.subtle.verify(
        'RSASSA-PKCS1-v1_5',
        key,
        Uint8Array.from(atob(padded), (char) => char.charCodeAt(0)),
        new TextEncoder().encode(encodedHeader + '.' + encodedPayload),
      );
      return { header, payload: decodeIntrospectionJwtSegment(encodedPayload), signatureValid };
    }

    describe('Signed JWT response (RFC 9701 §4 / §5)', () => {
      it('should answer a JWT-accepting caller with a verifiable signed introspection JWT', async () => {
        const now = Math.floor(Date.now() / 1000);
        accessTokenStore.set('rfc9701-active', {
          sub: 'testuser',
          clientId: 'c-conf',
          scope: ['openid'],
          expiresAt: now + 3600,
          iat: now,
        });
        const res = await introspectWith(
          { client_id: 'c-conf', client_secret: 's', token: 'rfc9701-active' },
          INTROSPECTION_JWT_MEDIA_TYPE,
        );

        expect(res.status).toBe(200);
        // RFC 9701 §5: the compact JWS travels under its own media type, and the
        // RFC 7662 §2.2 cache-busting headers still apply.
        expect(res.headers.get('Content-Type')).toBe(INTROSPECTION_JWT_MEDIA_TYPE);
        expect(res.headers.get('Cache-Control')).toBe('no-store');
        expect(res.headers.get('Pragma')).toBe('no-cache');

        const { header, payload, signatureValid } = await inspectIntrospectionJwt(await res.text());
        // §5 REQUIRED typ (the §8.1 cross-JWT confusion defense) + §6 default alg.
        expect(header).toEqual({ typ: 'token-introspection+jwt', alg: 'RS256', kid: 'test-key' });
        expect(signatureValid).toBe(true);
        // §5: iss / aud / iat at the top level, the RFC 7662 members inside
        // token_introspection — and nothing else (no top-level sub / exp, which
        // would let the JWT pass for an access token).
        expect(Object.keys(payload).sort()).toEqual(['aud', 'iat', 'iss', 'token_introspection']);
        expect(payload.iss).toBe('http://localhost:3000');
        expect(payload.aud).toBe('c-conf');
        expect(payload.token_introspection).toEqual({
          active: true,
          scope: 'openid',
          client_id: 'c-conf',
          token_type: 'Bearer',
          sub: 'testuser',
          exp: now + 3600,
          iat: now,
        });
      });

      it('should wrap an unknown token as token_introspection with active false only', async () => {
        const res = await introspectWith(
          { client_id: 'c-conf', client_secret: 's', token: 'rfc9701-unknown' },
          INTROSPECTION_JWT_MEDIA_TYPE,
        );

        expect(res.status).toBe(200);
        expect(res.headers.get('Content-Type')).toBe(INTROSPECTION_JWT_MEDIA_TYPE);
        const { payload, signatureValid } = await inspectIntrospectionJwt(await res.text());
        expect(signatureValid).toBe(true);
        expect(payload.token_introspection).toEqual({ active: false });
      });
    });

    describe('RFC 7662 JSON path is unchanged', () => {
      it('should keep answering RFC 7662 JSON when the caller sends no Accept header', async () => {
        const now = Math.floor(Date.now() / 1000);
        accessTokenStore.set('rfc9701-json', {
          sub: 'testuser',
          clientId: 'c-conf',
          scope: ['openid'],
          expiresAt: now + 3600,
          iat: now,
        });
        const res = await introspectWith({
          client_id: 'c-conf',
          client_secret: 's',
          token: 'rfc9701-json',
        });

        expect(res.status).toBe(200);
        expect(res.headers.get('Content-Type')).toBe('application/json');
        expect(await res.json()).toEqual({
          active: true,
          scope: 'openid',
          client_id: 'c-conf',
          token_type: 'Bearer',
          sub: 'testuser',
          exp: now + 3600,
          iat: now,
        });
      });

      it('should not treat a wildcard Accept as a JWT request', async () => {
        // A generic HTTP client's default Accept must not flip the response
        // format — only the explicitly named RFC 9701 media type does.
        const res = await introspectWith(
          { client_id: 'c-conf', client_secret: 's', token: 'rfc9701-unknown' },
          '*/*',
        );

        expect(res.status).toBe(200);
        expect(res.headers.get('Content-Type')).toBe('application/json');
        expect(await res.json()).toEqual({ active: false });
      });
    });

    describe('Caller audience restriction (RFC 9701 §3 / §5)', () => {
      it('should answer a caller that is neither issuee nor audience with active false', async () => {
        const now = Math.floor(Date.now() / 1000);
        accessTokenStore.set('rfc9701-foreign', {
          sub: 'testuser',
          clientId: 'c-conf',
          scope: ['openid'],
          expiresAt: now + 3600,
          iat: now,
        });
        const res = await introspectWith(
          { client_id: 'c-introspect-other', client_secret: 's', token: 'rfc9701-foreign' },
          INTROSPECTION_JWT_MEDIA_TYPE,
        );

        expect(res.status).toBe(200);
        const { payload, signatureValid } = await inspectIntrospectionJwt(await res.text());
        expect(signatureValid).toBe(true);
        // The withheld response is indistinguishable from an unknown token, and
        // the JWT is addressed to the caller that asked.
        expect(payload.aud).toBe('c-introspect-other');
        expect(payload.token_introspection).toEqual({ active: false });
      });

      it('should disclose the response to a caller listed in the token audience', async () => {
        const now = Math.floor(Date.now() / 1000);
        accessTokenStore.set('rfc9701-audience', {
          sub: 'testuser',
          clientId: 'c-conf',
          scope: ['openid'],
          expiresAt: now + 3600,
          iat: now,
          audience: ['c-introspect-other'],
        });
        const res = await introspectWith(
          { client_id: 'c-introspect-other', client_secret: 's', token: 'rfc9701-audience' },
          INTROSPECTION_JWT_MEDIA_TYPE,
        );

        expect(res.status).toBe(200);
        const { payload, signatureValid } = await inspectIntrospectionJwt(await res.text());
        expect(signatureValid).toBe(true);
        expect(payload.token_introspection).toEqual({
          active: true,
          scope: 'openid',
          client_id: 'c-conf',
          token_type: 'Bearer',
          sub: 'testuser',
          exp: now + 3600,
          iat: now,
          aud: ['c-introspect-other'],
        });
      });
    });

    describe('Downgrade prevention (RFC 9701 §8.2)', () => {
      it('should refuse an unauthenticated request no matter what the Accept header asks for', async () => {
        const res = await introspectWith({ token: 'rfc9701-active' }, INTROSPECTION_JWT_MEDIA_TYPE);

        // Client authentication runs before the response-format branch, so the
        // Accept header can never bypass it; the error stays RFC 7662 JSON.
        expect(res.status).toBe(401);
        expect(res.headers.get('Content-Type')).toBe('application/json');
        expect(await res.json()).toMatchObject({ error: 'invalid_client' });
      });

      // RFC 9701 §5: an unauthenticated request must be refused, and a public
      // client_id alone is not authentication. Without this rejection the
      // signed assertion would vouch for a caller identity that was never
      // verified.
      it('should reject a public client introspection request even when it asks for the JWT response', async () => {
        const res = await introspectWith(
          { client_id: 'c-public', token: 'rfc9701-active' },
          INTROSPECTION_JWT_MEDIA_TYPE,
        );

        expect(res.status).toBe(401);
        expect(res.headers.get('Content-Type')).toBe('application/json');
        expect(await res.json()).toEqual({
          error: 'invalid_client',
          error_description: 'Introspection requires an authenticated confidential client',
        });
      });
    });

    describe('Provider metadata (RFC 9701 §7)', () => {
      it('should advertise introspection_signing_alg_values_supported as exactly RS256', async () => {
        const metadata = await (await app.request('/.well-known/openid-configuration')).json();

        expect(metadata.introspection_signing_alg_values_supported).toEqual(['RS256']);
      });
    });
  });
```

### 他フレームワークの生成結果

introspection ルートは全フレームワーク共通の hono テンプレートから `toWebRouteTemplate` 変換で生成されるため、express / fastify / nextjs の内容は上記と同等である。
変換の仕組みは [packages/cli/src/frameworks/web-standard](../../../packages/cli/src/frameworks/web-standard) を参照。
サンプルでこの機能を有効にしているのは [samples/hono-cloudflare](../../../samples/hono-cloudflare) だけである。

## E2E テストの全文

E2E テストは、実ブラウザで認可コードフローを完走して得たアクセストークンを実 HTTP でイントロスペクトし、次を固定する。

- 発行先クライアント自身が `Accept` で JWT を要求すると、`Content-Type` が専用メディアタイプになり、JWKS で署名検証でき、`typ` / `iss` / `aud` / クレーム集合が仕様どおりであること
- 発行先でも `aud` 記載先でもない登録クライアント（E2E のリソースサーバー役）には `token_introspection` が `{"active": false}` になること、そして同じ呼び出し元でも `Accept` を外せば従来の JSON で全属性が返ること（JSON 経路の不変の実地確認）
- discovery が署名アルゴリズムを広告すること

機能を有効にしていないサンプル OP では、discovery の広告が無いことを条件に全テストがスキップされ、共有スペックスイートは全サンプルで緑を保つ。

```typescript
import { expect, test, type Locator } from '@playwright/test';

const host = process.env.E2E_HOST ?? '127.0.0.1';
const clientPort = Number(process.env.E2E_CLIENT_PORT ?? '3020');
const resourceServerPort = Number(process.env.E2E_RESOURCE_SERVER_PORT ?? '3030');
const clientBaseURL =
  process.env.E2E_CLIENT_BASE_URL ?? `http://${host}:${clientPort}`;
const resourceServerURL =
  process.env.E2E_RESOURCE_SERVER_URL ?? `http://${host}:${resourceServerPort}`;
const clientId = 'e2e-client';
const clientSecret = 'e2e-client-secret';
const resourceServerClientId = 'e2e-resource-server';
const resourceServerClientSecret = 'e2e-resource-server-secret';

const INTROSPECTION_JWT_MEDIA_TYPE = 'application/token-introspection+jwt';

/**
 * EXPERIMENTAL — JWT Response for OAuth Token Introspection (RFC 9701).
 *
 * Only the samples generated with `--enable jwt-introspection-response` answer
 * the RFC 9701 Accept header with a signed JWT, so every test here skips when
 * discovery does not advertise introspection_signing_alg_values_supported. That
 * keeps the shared spec suite green across all sample OPs.
 *
 * The verification chain a resource server must run (resolve the key from
 * jwks_uri, verify the JWS, check typ / iss / aud, then read
 * token_introspection) is performed inside this spec, over real HTTP.
 */
test.describe('JWT introspection response (RFC 9701)', () => {
  test('should answer the issuing client with a verifiable signed introspection JWT', async ({
    page,
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const algs = await introspectionSigningAlgs(request, issuer);
    test.skip(
      !algs.includes('RS256'),
      'This sample OP was generated without --enable jwt-introspection-response',
    );

    const accessToken = await completeAuthorizationCodeFlow(page, issuer);

    // The issuing client itself introspects the token and asks for the signed
    // response (RFC 9701 §4).
    const response = await request.post(`${issuer}/introspect`, {
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        Accept: INTROSPECTION_JWT_MEDIA_TYPE,
      },
      data: new URLSearchParams({
        client_id: clientId,
        client_secret: clientSecret,
        token: accessToken,
        token_type_hint: 'access_token',
      }).toString(),
    });

    expect(response.status()).toBe(200);
    expect(response.headers()['content-type']).toBe(INTROSPECTION_JWT_MEDIA_TYPE);

    const jwt = await response.text();
    const parsed = parseJwt(jwt);
    // RFC 9701 §5 REQUIRED typ — the §8.1 cross-JWT confusion defense — plus
    // the §6 default alg and the kid that resolves the key in jwks_uri.
    expect(parsed.header).toEqual({
      typ: 'token-introspection+jwt',
      alg: 'RS256',
      kid: 'e2e-rs256-key',
    });

    const jwks = (await (await request.get(`${issuer}/.well-known/jwks.json`)).json()) as JwkSet;
    expect(await verifyJwtSignature(jwt, jwks)).toBe(true);

    // RFC 9701 §5: iss / aud / iat at the top level and the RFC 7662 members
    // inside token_introspection — nothing else (no top-level sub / exp).
    expect(Object.keys(parsed.payload).sort()).toEqual(['aud', 'iat', 'iss', 'token_introspection']);
    expect(parsed.payload.iss).toBe(issuer);
    expect(parsed.payload.aud).toBe(clientId);
    expect(parsed.payload.token_introspection).toMatchObject({
      active: true,
      client_id: clientId,
      token_type: 'Bearer',
      sub: 'testuser',
      scope: 'openid profile email',
      aud: [`${issuer}/userinfo`, resourceServerURL],
    });
  });

  test('should withhold the signed response from a caller that is not an audience', async ({
    page,
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const algs = await introspectionSigningAlgs(request, issuer);
    test.skip(
      !algs.includes('RS256'),
      'This sample OP was generated without --enable jwt-introspection-response',
    );

    const accessToken = await completeAuthorizationCodeFlow(page, issuer);

    // The e2e resource server is registered as its own client, but the token's
    // aud carries the resource server URL, not that client_id — so on the JWT
    // path RFC 9701 §3 / §5 requires { active: false }, indistinguishable from
    // an unknown token. (To disclose to a third-party RS, the token must be
    // issued with that RS's client_id as an audience value.)
    const jwtResponse = await request.post(`${issuer}/introspect`, {
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        Accept: INTROSPECTION_JWT_MEDIA_TYPE,
        Authorization: `Basic ${basicCredentials(resourceServerClientId, resourceServerClientSecret)}`,
      },
      data: new URLSearchParams({ token: accessToken, token_type_hint: 'access_token' }).toString(),
    });

    expect(jwtResponse.status()).toBe(200);
    expect(jwtResponse.headers()['content-type']).toBe(INTROSPECTION_JWT_MEDIA_TYPE);
    const parsed = parseJwt(await jwtResponse.text());
    expect(parsed.payload.aud).toBe(resourceServerClientId);
    expect(parsed.payload.token_introspection).toEqual({ active: false });

    // The RFC 7662 JSON path is deliberately unchanged: the same caller without
    // the Accept header keeps seeing the full response, which is what the e2e
    // resource server's /profile check relies on.
    const jsonResponse = await request.post(`${issuer}/introspect`, {
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        Authorization: `Basic ${basicCredentials(resourceServerClientId, resourceServerClientSecret)}`,
      },
      data: new URLSearchParams({ token: accessToken, token_type_hint: 'access_token' }).toString(),
    });

    expect(jsonResponse.status()).toBe(200);
    expect((await jsonResponse.json()) as Record<string, unknown>).toMatchObject({
      active: true,
      client_id: clientId,
      sub: 'testuser',
    });
  });

  test('should advertise the introspection response signing algorithm in discovery', async ({
    request,
    baseURL,
  }) => {
    const issuer = requireBaseUrl(baseURL);
    const algs = await introspectionSigningAlgs(request, issuer);
    test.skip(
      !algs.includes('RS256'),
      'This sample OP was generated without --enable jwt-introspection-response',
    );

    // RFC 9701 §7: the one AS metadata member this implementation emits.
    expect(algs).toEqual(['RS256']);
  });
});

/**
 * Drives the browser through authorize -> login -> consent on the shared e2e
 * client app and returns the access token its result page shows.
 */
async function completeAuthorizationCodeFlow(
  page: import('@playwright/test').Page,
  issuer: string,
): Promise<string> {
  await page.goto(`${clientBaseURL}/start`);
  await expect(page).toHaveURL(new RegExp(`^${escapeRegExp(issuer)}/login\\?transaction_id=`));

  await page.getByLabel('Username:').fill('testuser');
  await page.getByLabel('Password:').fill('password');
  await page.getByRole('button', { name: 'Login' }).click();
  await expect(page).toHaveURL(new RegExp(`^${escapeRegExp(issuer)}/consent\\?transaction_id=`));

  await page.getByRole('button', { name: 'Approve' }).click();
  await expect(page).toHaveURL(new RegExp(`^${escapeRegExp(clientBaseURL)}/callback\\?`));

  return locatorText(page.getByTestId('token-access-token'), 'access token');
}

interface DiscoveryMetadata {
  introspection_signing_alg_values_supported?: string[];
}

async function introspectionSigningAlgs(
  request: { get(url: string): Promise<{ json(): Promise<unknown> }> },
  issuer: string,
): Promise<string[]> {
  const response = await request.get(`${issuer}/.well-known/openid-configuration`);
  const metadata = (await response.json()) as DiscoveryMetadata;
  return metadata.introspection_signing_alg_values_supported ?? [];
}

interface JwkSet {
  keys: Array<Record<string, unknown> & { kid?: string }>;
}

interface ParsedJwt {
  header: Record<string, unknown>;
  payload: Record<string, unknown>;
  signingInput: string;
  signature: ArrayBuffer;
}

function parseJwt(jwt: string): ParsedJwt {
  const parts = jwt.split('.');
  if (parts.length !== 3) {
    throw new Error('JWT must have three compact serialization segments');
  }
  const [headerSegment, payloadSegment, signatureSegment] = parts as [string, string, string];
  return {
    header: JSON.parse(base64UrlDecode(headerSegment)),
    payload: JSON.parse(base64UrlDecode(payloadSegment)),
    signingInput: `${headerSegment}.${payloadSegment}`,
    signature: base64UrlToBytes(signatureSegment),
  };
}

async function verifyJwtSignature(jwt: string, jwks: JwkSet): Promise<boolean> {
  const parsed = parseJwt(jwt);
  const kid = requireString(parsed.header.kid, 'introspection JWT kid is required');
  const jwk = requireJwk(jwks, kid);
  const key = await crypto.subtle.importKey(
    'jwk',
    jwk,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['verify'],
  );
  return crypto.subtle.verify(
    'RSASSA-PKCS1-v1_5',
    key,
    parsed.signature,
    new TextEncoder().encode(parsed.signingInput),
  );
}

function requireJwk(jwks: JwkSet, kid: string): Record<string, unknown> {
  const jwk = jwks.keys.find((candidate) => candidate.kid === kid);
  if (jwk === undefined) {
    throw new Error(`No JWK published under kid ${kid}`);
  }
  return jwk;
}

function requireString(value: unknown, message: string): string {
  if (typeof value !== 'string' || value.length === 0) {
    throw new Error(message);
  }
  return value;
}

async function locatorText(locator: Locator, label: string): Promise<string> {
  const value = await locator.textContent();
  if (value === null || value.length === 0) {
    throw new Error(`${label} text is required`);
  }
  return value;
}

function base64UrlDecode(segment: string): string {
  return new TextDecoder().decode(base64UrlToBytes(segment));
}

function base64UrlToBytes(segment: string): ArrayBuffer {
  const bytes = Buffer.from(segment, 'base64url');
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
}

function basicCredentials(id: string, secret: string): string {
  return Buffer.from(`${id}:${secret}`).toString('base64');
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

- [RFC 9701: JWT Response for OAuth Token Introspection](https://www.rfc-editor.org/rfc/rfc9701)
- [RFC 7662: OAuth 2.0 Token Introspection](https://www.rfc-editor.org/rfc/rfc7662)
- [RFC 8725: JSON Web Token Best Current Practices](https://www.rfc-editor.org/rfc/rfc8725)
- 仕様策定タスク一式: [tasks/experimental/done/jwt-introspection-response](../../../tasks/experimental/done/jwt-introspection-response)
- 利用者向けドキュメント: [docs/library-document の experimental ページ](../../../docs/library-document/src/content/docs/experimental/jwt-introspection-response.md)
