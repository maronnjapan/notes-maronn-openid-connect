# `claims` パラメータのクレーム名アロウリスト実装解説

対象は `@maronn-openid-connect/core` の UserInfo レスポンス生成（`applyRequestedClaims`）と ID Token 生成（`applyRequestedIdTokenClaims`）である。
OSS リポジトリのタスク `tasks/done/p1-claims-parameter-claim-name-allowlist.md` から実装した。

## この機能は何をするのか

OpenID Provider は、認可リクエストの `claims` パラメータ（OIDC Core 1.0 §5.5）で、クレーム単位の返却要求を受け取れる。
本ライブラリはこの要求を、`claims.userinfo` は UserInfo レスポンスへ、`claims.id_token` は ID Token へ反映する。

変更前の実装は、`claims` パラメータのキー名を、`UserClaimsResolver.findUserClaims()` が返したオブジェクトのプロパティ名としてそのまま読み出していた。
読み出してよいクレーム名の集合が定義されていなかったため、resolver が標準クレーム以外のフィールドを持つオブジェクトを返すと、そのフィールドも `claims` 経由で開示できた。

`findUserClaims()` は利用者が実装する関数で、DB の行オブジェクトや内部ユーザーモデルをそのまま返す実装は PoC で最も自然な書き方である。
その場合、`claims={"userinfo":{"password_hash":null}}` のようなリクエスト 1 本で、scope とは無関係にその内部フィールドが UserInfo レスポンスから返っていた。
`claims={"id_token":{"password_hash":null}}` とすれば、同じ値が ID Token からも返っていた。

この変更により、`claims` 経由で読み出せるキーは**アロウリスト**（既定は `sub` とスコープ対応の標準クレーム）に載っている名前だけになる。
アロウリスト外の要求は、OIDC Core 1.0 §5.5.1 の「返せないクレームでエラーを返してはならない（MUST NOT）」のとおり、エラーにせず黙って省く。

## 型の見た目と実行時の防御

変更前のコードが無防備に見えなかった点が、このタスクの主眼である。
`UserClaims` は閉じた interface で、要求キーの取得関数は戻り値を `as (keyof UserClaims)[]` とキャストしていた。
型の上では「標準クレーム名しか来ない」ように読めるが、TypeScript の構造的部分型では変数経由の余剰プロパティは検査されず、キャストは実行時に何も保証しない。
今回この実態と食い違うキャストを除去し、戻り値型を `string[]` に直したうえで、実行時のアロウリスト判定を置いた。

## 設計判断

### アロウリストの既定は「OP が定義した語彙」

既定のアロウリスト `DEFAULT_REQUESTABLE_CLAIMS` は、`sub` と `SCOPE_CLAIMS_MAP`（OIDC Core 1.0 §5.4 の profile / email / address / phone 各 scope に対応する標準クレーム）の全クレーム名とした。
§5.1 / §5.1.2 のとおりクレーム名の語彙は OP が定義するものであり、この集合は本ライブラリの OP が「返しうる」と宣言している名前と一致する。
scope 経路（`filterClaimsByScope`）はもともと `SCOPE_CLAIMS_MAP` だけをコピーするアロウリスト方式だったので、この変更で `claims` 経路も同じ語彙に揃い、二経路の非対称が消えた。

### 引数はオプションにして将来の注入点を残す

アロウリストは第 4 引数で差し替えられる。
既定値を使う限り既存の挙動は変わらず、カスタムクレームを提供する OP は Discovery の `claims_supported` と同じ一覧を注入できる（カスタムクレームの運搬自体は `study-material/userinfo-custom-claims-and-scope-claim-mapping-extensibility.md` の別トピック）。
apps / samples の生成コードは core の既定値をそのまま使うため、生成コード側の変更は不要だった。

### own プロパティだけを読む

アロウリスト判定に加えて、`Object.prototype.hasOwnProperty` の検査も入れた。
アロウリストは標準クレーム名しか通さないため、`constructor` のような継承プロパティは名前の時点で弾かれるが、resolver が getter を持つクラスインスタンスを返す構成では、標準クレーム名の継承プロパティがありうる。
読み出しを own プロパティに限ることで、「resolver が明示的に持たせた値だけが開示される」という契約を名前の検査と独立に成立させる。

### ID Token 側にも同じアロウリストを適用する

タスク文書は「影響範囲は UserInfo レスポンスに限定される」と書いていたが、これはタスク作成後に `applyRequestedIdTokenClaims` が導入される前の記述である。
実装時点の ID Token 側は own プロパティ検査こそ持っていたものの、名前の検査が無く、UserInfo 側と同じ経路で余剰フィールドを開示できた。
UserInfo の扉だけ閉じて同じ形の扉を ID Token に残す理由は無いので、同じ既定アロウリストを両方へ適用した。
ID Token 自身のクレーム（`iss` / `sub` / `aud` など）を End-User のクレームから取らない既存の検査（`ID_TOKEN_OWN_CLAIMS`）は、そのまま残している。

### resolver の契約を明文化する

コードの防御と併せて、`findUserClaims()` の戻り値が外部開示されうる面であることを `UserClaimsResolver` の JSDoc に書いた。
既定のアロウリストが守るのは標準クレーム名だけなので、アロウリストを広げる構成では「開示してよいクレームだけを持つオブジェクトへ写して返す」ことが利用者側の契約になる。
同じ内容を notes リポジトリの `study-material/resolver-and-store-contract.md` にも追記した。

## core の変更コード

### packages/core/src/userinfo.ts：UserClaimsResolver の契約

```typescript
/**
 * ユーザークレームを解決するインターフェース
 */
export interface UserClaimsResolver {
  /**
   * subject の End-User クレームを返す。
   *
   * 契約: 返したオブジェクトは外部開示されうる面である。UserInfo レスポンスと
   * ID Token は、ここが返したプロパティを scope（{@link filterClaimsByScope}）と
   * `claims` パラメータのアロウリスト（{@link DEFAULT_REQUESTABLE_CLAIMS}）で絞って
   * 開示する。アロウリストが既定で守るのは標準クレーム名だけなので、アロウリストを
   * 広げる構成では、DB の行や内部ユーザーモデルをそのまま返さず、開示してよい
   * クレームだけを持つオブジェクトへ写して返すこと。
   */
  findUserClaims(sub: string): Promise<UserClaims | null>;
}
```

### packages/core/src/userinfo.ts：既定アロウリスト

`SCOPE_CLAIMS_MAP` の直後に追加した。

```typescript
/**
 * `claims` パラメータで要求できるクレーム名の既定アロウリスト。
 * `sub` と、スコープが対応付ける標準クレーム（{@link SCOPE_CLAIMS_MAP}）の全名前。
 *
 * OIDC Core 1.0 §5.5.1: 要求されたクレームを返せない場合でも OP はエラーを
 * 返してはならない（MUST NOT）。したがって未知のクレーム名を黙って返さないことは
 * 常に仕様適合である。§5.1 / §5.1.2 のとおり、クレーム名の語彙は OP が定義する。
 *
 * `claims` のキー名は RP が任意に指定できる。これを resolver が返したオブジェクトの
 * プロパティ名として無検査で読み出すと、利用者が `findUserClaims` から余剰フィールド
 * （DB の行など）を返した場合に、scope を迂回してそのフィールドが開示される。
 * 読み出せるキーを OP が宣言した語彙に限定するのがこのアロウリストの役割で、
 * {@link applyRequestedClaims} と `applyRequestedIdTokenClaims` の既定値になる。
 */
export const DEFAULT_REQUESTABLE_CLAIMS: ReadonlySet<string> = new Set([
  'sub',
  ...Object.values(SCOPE_CLAIMS_MAP).flat(),
]);
```

### packages/core/src/userinfo.ts：要求キーの取得

実態と食い違っていた `as (keyof UserClaims)[]` キャストを除去し、戻り値を文字列の配列に直した。

```typescript
/**
 * claimsパラメータで要求されたクレーム名を取得する
 *
 * キー名は RP が任意に指定できるため、戻り値は `keyof UserClaims` ではなく
 * ただの文字列である。読み出してよい名前かどうかは呼び出し側がアロウリストで
 * 判定する（{@link applyRequestedClaims}）。
 */
function getRequestedClaimNames(claimsParameter?: ClaimsParameter): string[] {
  if (!claimsParameter?.userinfo) return [];
  return Object.keys(claimsParameter.userinfo);
}
```

### packages/core/src/userinfo.ts：applyRequestedClaims

アロウリスト引数（既定 `DEFAULT_REQUESTABLE_CLAIMS`）と own プロパティ検査を追加した。

```typescript
/**
 * ステップ 7: claims リクエストパラメータで要求されたクレームを追加する
 * OIDC Core 1.0 Section 5.5 / 5.5.1
 *
 * スコープ由来のレスポンス（`filterClaimsByScope` の結果）へ、`claims.userinfo` で
 * 個別要求されたクレームを重ねる。value / values が指定された場合は実値が一致する
 * クレームだけを返し、一致しない場合は省略する（エラーにはしない）。
 * `sub` はアクセストークンの subject で確定済みのため上書きしない。
 *
 * 要求されたキー名はアロウリスト（既定 {@link DEFAULT_REQUESTABLE_CLAIMS}）に
 * 載っている名前だけを読み出す。`claims` のキー名は RP が任意に指定できるため、
 * 無検査で読むと resolver が返した余剰フィールド（DB の行など）が scope を迂回して
 * 開示される。アロウリスト外のクレームは黙って省く（§5.5.1 の MUST NOT のとおり
 * エラーにはしない）。読み出しは own プロパティに限り、プロトタイプチェーン上の
 * プロパティ（getter を持つクラスインスタンスを resolver が返した場合など）は読まない。
 *
 * 入力のレスポンスは変更せず、新しいオブジェクトを返す。
 *
 * @param response スコープでフィルタ済みの UserInfo レスポンス
 * @param userClaims ユーザーの全クレーム
 * @param claimsParameter Authorization Request の claims パラメータ
 * @param allowedClaimNames `claims` 経由で読み出してよいクレーム名。既定は標準クレーム。
 *   Discovery の `claims_supported` と同じ語彙を公開する OP は、その一覧をここへ注入する
 * @returns 要求クレームを追加した UserInfo レスポンス
 */
export function applyRequestedClaims(
  response: UserInfoResponse,
  userClaims: UserClaims,
  claimsParameter?: ClaimsParameter,
  allowedClaimNames: ReadonlySet<string> = DEFAULT_REQUESTABLE_CLAIMS
): UserInfoResponse {
  const result: Record<string, unknown> = { ...response };

  const requestedClaims = getRequestedClaimNames(claimsParameter);
  for (const claimName of requestedClaims) {
    if (claimName === 'sub') continue;
    if (!allowedClaimNames.has(claimName)) continue;
    // Only the End-User's own claims, not what the object inherits (constructor, toString...).
    if (!Object.prototype.hasOwnProperty.call(userClaims, claimName)) continue;

    const value = (userClaims as unknown as Record<string, unknown>)[claimName];
    if (value === undefined || value === null) continue;

    const entry = claimsParameter?.userinfo?.[claimName] ?? null;
    if (!matchesRequestedClaimValue(value, entry)) continue;

    result[claimName] = value;
  }

  return result as UserInfoResponse;
}
```

### packages/core/src/token-response.ts：applyRequestedIdTokenClaims

import に `DEFAULT_REQUESTABLE_CLAIMS` を追加した。

```typescript
import { DEFAULT_REQUESTABLE_CLAIMS, filterClaimsByScope, matchesRequestedClaimValue } from './userinfo.js';
```

関数本体には、`ID_TOKEN_OWN_CLAIMS` の検査（変更なし）の直後にアロウリスト判定を追加した。

```typescript
/**
 * ステップ: claims リクエストパラメータの id_token メンバーで個別に要求されたクレームを
 * ID Token の payload に加える
 * OIDC Core 1.0 Section 5.5 / 5.5.1
 *
 * id_token メンバーのクレームは、ID Token の既定のクレームに加えて返すよう要求されたもの
 * である（§5.5）。End-User のクレームにあるものを payload に足す。value / values が
 * 指定されたクレームは、実値が一致するときだけ足す。値の無いクレームと一致しない
 * クレームは省き、エラーにしない（§5.5.1）。
 *
 * ID Token 自身のクレーム（iss / sub / aud / exp / iat / auth_time / nonce / acr / amr /
 * azp / at_hash / c_hash）は End-User のクレームから取らず、payload がすでに持つクレームも
 * 置き換えない。acr の要求は acr_values と同じく {@link resolveAcrAmr} が扱う（§5.5.1.1）。
 *
 * 要求されたキー名はアロウリスト（既定 {@link DEFAULT_REQUESTABLE_CLAIMS}）に
 * 載っている名前だけを読み出す。`claims` のキー名は RP が任意に指定できるため、
 * 無検査で読むと resolver が返した余剰フィールド（DB の行など）が scope を迂回して
 * ID Token から開示される。アロウリスト外のクレームは黙って省く（§5.5.1 の
 * MUST NOT のとおりエラーにはしない）。
 *
 * 入力の payload は変更せず、新しいオブジェクトを返す。
 *
 * @param payload {@link buildIdTokenPayload} が組み立てた payload
 * @param userClaims End-User のクレーム。undefined なら payload をそのまま返す
 * @param claimsParameter 認可リクエストの claims パラメータ
 * @param allowedClaimNames `claims` 経由で読み出してよいクレーム名。既定は標準クレーム。
 *   Discovery の `claims_supported` と同じ語彙を公開する OP は、その一覧をここへ注入する
 * @returns 要求されたクレームを足した payload
 */
export function applyRequestedIdTokenClaims(
  payload: IdTokenPayload,
  userClaims: UserClaims | undefined,
  claimsParameter?: ClaimsParameter,
  allowedClaimNames: ReadonlySet<string> = DEFAULT_REQUESTABLE_CLAIMS,
): IdTokenPayload {
  const requested = claimsParameter?.id_token;
  if (userClaims === undefined || requested === undefined) return payload;

  const result: IdTokenPayload = { ...payload };
  for (const [claimName, entry] of Object.entries(requested)) {
    if (ID_TOKEN_OWN_CLAIMS.has(claimName)) continue;
    if (!allowedClaimNames.has(claimName)) continue;
    if (Object.prototype.hasOwnProperty.call(result, claimName)) continue;
    // Only the End-User's own claims, not what the object inherits (constructor, toString...).
    if (!Object.prototype.hasOwnProperty.call(userClaims, claimName)) continue;

    const value = (userClaims as unknown as Record<string, unknown>)[claimName];
    if (value === undefined || value === null) continue;
    if (!matchesRequestedClaimValue(value, entry)) continue;

    result[claimName] = value;
  }
  return result;
}
```

### packages/core/src/index.ts：パッケージ公開面

```typescript
  // UserInfo リクエスト処理のステップ関数
  resolveUserInfoAccessToken,
  validateUserInfoTokenExpiration,
  validateUserInfoScope,
  validateUserInfoAudience,
  resolveUserInfoClaims,
  applyRequestedClaims,
  matchesRequestedClaimValue,
  DEFAULT_REQUESTABLE_CLAIMS,
} from './userinfo.js';
```

## core のテストコード

### packages/core/src/userinfo.test.ts：applyRequestedClaims のアロウリスト

`describe('applyRequestedClaims')` の末尾に追加した。
import には `DEFAULT_REQUESTABLE_CLAIMS` を足している。

```typescript
  // OIDC Core 1.0 Section 5.5.1: the OP MUST NOT return an error when a requested
  // claim cannot be returned, so narrowing the readable names to the vocabulary the
  // OP defines (Section 5.1 standard claims) is always conformant. The claims
  // parameter keys are attacker-controlled, so they must never be used as free
  // property reads on whatever object findUserClaims() returned.
  describe('Claim name allowlist (OIDC Core Section 5.5.1)', () => {
    it('should return a standard claim requested via the claims parameter', () => {
      const result = applyRequestedClaims(
        { sub: 'user-123' },
        { sub: 'user-123', email: 'janedoe@example.com' },
        { userinfo: { email: null } }
      );
      expect(result).toEqual({ sub: 'user-123', email: 'janedoe@example.com' });
    });

    it('should not return a non-standard property present on the resolved user claims', () => {
      // A resolver that returns its DB row as-is carries extra fields.
      const rowLikeClaims = {
        sub: 'user-123',
        email: 'janedoe@example.com',
        password_hash: '$2b$10$secret',
      } as UserClaims;
      const result = applyRequestedClaims({ sub: 'user-123' }, rowLikeClaims, {
        userinfo: { email: null, password_hash: null },
      });
      expect(result).toEqual({ sub: 'user-123', email: 'janedoe@example.com' });
    });

    it('should not return a prototype chain property when requested as a claim', () => {
      const result = applyRequestedClaims({ sub: 'user-123' }, { sub: 'user-123' }, {
        userinfo: { constructor: null, toString: null },
      });
      expect(result).toEqual({ sub: 'user-123' });
    });

    it('should not alter the response prototype when __proto__ is requested as a claim', () => {
      // JSON.parse creates __proto__ as an own key, like a parsed claims parameter does.
      const claimsParameter = JSON.parse('{"userinfo":{"__proto__":{"polluted":true}}}');
      const result = applyRequestedClaims({ sub: 'user-123' }, createFullUserClaims(), claimsParameter);
      expect(result).toEqual({ sub: 'user-123' });
      expect(Object.getPrototypeOf(result)).toBe(Object.prototype);
    });

    it('should return only claims within an explicitly supplied allowlist', () => {
      const result = applyRequestedClaims(
        { sub: 'user-123' },
        createFullUserClaims(),
        { userinfo: { email: null, name: null } },
        new Set(['sub', 'email'])
      );
      expect(result).toEqual({ sub: 'user-123', email: 'janedoe@example.com' });
    });

    // OIDC Core 1.0 Section 5.5.1: MUST NOT return an error for a claim it will not return
    it('should not return an error when a requested claim is not allowed', () => {
      const rowLikeClaims = { sub: 'user-123', password_hash: '$2b$10$secret' } as UserClaims;
      const error = captureError(() =>
        applyRequestedClaims({ sub: 'user-123' }, rowLikeClaims, {
          userinfo: { password_hash: { essential: true } },
        })
      );
      expect(error).toBeUndefined();
      expect(
        applyRequestedClaims({ sub: 'user-123' }, rowLikeClaims, {
          userinfo: { password_hash: { essential: true } },
        })
      ).toEqual({ sub: 'user-123' });
    });
  });
```

### packages/core/src/userinfo.test.ts：既定アロウリストの内容固定

```typescript
describe('DEFAULT_REQUESTABLE_CLAIMS', () => {
  it('should contain sub and every scope-mapped claim name exactly once', () => {
    expect([...DEFAULT_REQUESTABLE_CLAIMS].sort()).toEqual(
      ['sub', ...Object.values(SCOPE_CLAIMS_MAP).flat()].sort()
    );
  });
});
```

### packages/core/src/token-response.test.ts：applyRequestedIdTokenClaims のアロウリスト

`describe('applyRequestedIdTokenClaims')` の「Claims of the ID Token itself」の後に追加した。

```typescript
  // OIDC Core 1.0 §5.5.1: the OP MUST NOT return an error for a claim it will not
  // return, so narrowing the readable names to the OP's vocabulary (§5.1) is always
  // conformant. The claims parameter keys are attacker-controlled, so they must
  // never be used as free property reads on whatever findUserClaims() returned.
  describe('Claim name allowlist (OIDC Core Section 5.5.1)', () => {
    it('should not add a non-standard property present on the claims of the End-User', () => {
      // A resolver that returns its DB row as-is carries extra fields.
      const rowLikeClaims = { ...userClaims, password_hash: '$2b$10$secret' } as UserClaims;
      const payload = applyRequestedIdTokenClaims(basePayload(), rowLikeClaims, {
        id_token: { password_hash: { essential: true } },
      });

      expect(payload).toStrictEqual(basePayload());
    });

    it('should add only claims within an explicitly supplied allowlist', () => {
      const payload = applyRequestedIdTokenClaims(
        basePayload(),
        userClaims,
        { id_token: { email: null, name: null } },
        new Set(['email']),
      );

      expect(payload).toStrictEqual({ ...basePayload(), email: 'janedoe@example.com' });
    });
  });
```

## 生成コードへの影響

apps / samples の UserInfo ルート（hono の `resolve-claims` ステップ、Next.js の `userinfo/route.ts`）と Implicit / Hybrid Flow の ID Token 発行は、いずれも core の関数をアロウリスト引数なしで呼んでいる。
既定値がそのまま効くため、生成コード側の変更は無い。
標準クレームしか要求できなくなる以外の挙動差も無く、既存のテストは全件無変更で通っている。

## 検証

次のコマンドがすべて成功することを確認した。

```bash
pnpm --filter @maronn-openid-connect/core test   # 1336 件（新規 9 件を含む）
pnpm --filter "./packages/*" test
pnpm --filter "./apps/*" test
pnpm typecheck
pnpm test:conformance
pnpm run lint
```
