# Implementation guide: claim name allowlist for the `claims` parameter

This guide covers the UserInfo response assembly (`applyRequestedClaims`) and the ID Token assembly (`applyRequestedIdTokenClaims`) in `@maronn-openid-connect/core`.
Implemented from the task `tasks/done/p1-claims-parameter-claim-name-allowlist.md` in the OSS repository.

## What this change does

An OpenID Provider accepts per-claim requests through the `claims` request parameter of the authorization request (OIDC Core 1.0 §5.5).
This library reflects those requests into the UserInfo response (`claims.userinfo`) and into the ID Token (`claims.id_token`).

Before this change, the implementation used the key names of the `claims` parameter directly as property names on whatever object `UserClaimsResolver.findUserClaims()` returned.
No set of readable claim names was defined, so any extra field the resolver happened to carry was disclosable through the `claims` parameter.

`findUserClaims()` is implemented by the library user, and returning a DB row or an internal user model as-is is the most natural way to write it in a PoC.
In that setup, a single request such as `claims={"userinfo":{"password_hash":null}}` returned that internal field from the UserInfo response, independently of any granted scope.
The same value was also reachable from the ID Token via `claims={"id_token":{"password_hash":null}}`.

With this change, the keys readable through the `claims` parameter are limited to an **allowlist**, which defaults to `sub` plus the scope-mapped standard claims.
A request outside the allowlist is silently omitted rather than rejected, following OIDC Core 1.0 §5.5.1: the OP MUST NOT return an error when a requested claim cannot be returned.

## Apparent type safety versus runtime defense

The main point of this task is that the previous code did not look unguarded.
`UserClaims` is a closed interface, and the function collecting the requested keys cast its result with `as (keyof UserClaims)[]`.
At the type level it reads as if only standard claim names can arrive, but TypeScript's structural typing does not check excess properties passed through a variable, and a cast guarantees nothing at runtime.
This change removes the cast that misrepresented the reality, changes the return type to `string[]`, and puts the actual defense into a runtime allowlist check.

## Design decisions

### The default allowlist is the vocabulary the OP defines

The default allowlist `DEFAULT_REQUESTABLE_CLAIMS` is `sub` plus every claim name of `SCOPE_CLAIMS_MAP` (the standard claims of the profile / email / address / phone scopes, OIDC Core 1.0 §5.4).
Per §5.1 / §5.1.2 the claim name vocabulary is defined by the OP, and this set matches exactly the names this library's OP declares it can return.
The scope path (`filterClaimsByScope`) already copied only `SCOPE_CLAIMS_MAP` names, so the `claims` path now uses the same vocabulary and the asymmetry between the two paths is gone.

### The allowlist argument is optional, keeping an injection point

The allowlist can be replaced through a new optional fourth parameter.
With the default, existing behavior is unchanged; an OP that serves custom claims can inject the same list it advertises as `claims_supported` in Discovery (transporting custom claims itself is a separate topic, `study-material/userinfo-custom-claims-and-scope-claim-mapping-extensibility.md`).
The generated code in apps and samples calls the core functions without the argument, so no generated-code change was needed.

### Only own properties are read

In addition to the allowlist, the functions now check `Object.prototype.hasOwnProperty`.
The allowlist already rejects names such as `constructor` because they are not standard claims, but a resolver returning a class instance with getters could expose an inherited property under a standard claim name.
Restricting the read to own properties makes the contract "only values the resolver explicitly carries are disclosed" hold independently of the name check.

### The same allowlist applies to the ID Token path

The task document stated that only the UserInfo response was affected, but that was written before `applyRequestedIdTokenClaims` existed.
At implementation time the ID Token path had an own-property check but no name check, so the same extra-field disclosure worked there.
There is no reason to close the UserInfo door and leave the identically shaped ID Token door open, so the same default allowlist now applies to both.
The existing guard that never takes the ID Token's own claims (`iss` / `sub` / `aud` and the rest of `ID_TOKEN_OWN_CLAIMS`) from the End-User's claims is kept unchanged.

### The resolver contract is written down

Alongside the code defense, the JSDoc of `UserClaimsResolver` now states that the return value of `findUserClaims()` is a surface that can be disclosed externally.
The default allowlist protects only standard claim names, so in a configuration that widens the allowlist, mapping the stored row to an object that carries only disclosable claims becomes the user's side of the contract.
The same contract was added to `study-material/resolver-and-store-contract.md` in the notes repository.

## Changed code in core

### packages/core/src/userinfo.ts: the UserClaimsResolver contract

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

### packages/core/src/userinfo.ts: the default allowlist

Added right after `SCOPE_CLAIMS_MAP`.

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

### packages/core/src/userinfo.ts: collecting the requested keys

The cast `as (keyof UserClaims)[]` that misrepresented the runtime reality is removed; the function now returns plain strings.

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

### packages/core/src/userinfo.ts: applyRequestedClaims

The allowlist parameter (defaulting to `DEFAULT_REQUESTABLE_CLAIMS`) and the own-property check are added.

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

### packages/core/src/token-response.ts: applyRequestedIdTokenClaims

`DEFAULT_REQUESTABLE_CLAIMS` is added to the import from userinfo.

```typescript
import { DEFAULT_REQUESTABLE_CLAIMS, filterClaimsByScope, matchesRequestedClaimValue } from './userinfo.js';
```

In the function body, the allowlist check is inserted right after the unchanged `ID_TOKEN_OWN_CLAIMS` check.

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

### packages/core/src/index.ts: the package surface

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

## Test code in core

### packages/core/src/userinfo.test.ts: the allowlist of applyRequestedClaims

Added at the end of `describe('applyRequestedClaims')`; the import list gains `DEFAULT_REQUESTABLE_CLAIMS`.

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

### packages/core/src/userinfo.test.ts: pinning the default allowlist

```typescript
describe('DEFAULT_REQUESTABLE_CLAIMS', () => {
  it('should contain sub and every scope-mapped claim name exactly once', () => {
    expect([...DEFAULT_REQUESTABLE_CLAIMS].sort()).toEqual(
      ['sub', ...Object.values(SCOPE_CLAIMS_MAP).flat()].sort()
    );
  });
});
```

### packages/core/src/token-response.test.ts: the allowlist of applyRequestedIdTokenClaims

Added after the "Claims of the ID Token itself" block inside `describe('applyRequestedIdTokenClaims')`.

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

## Effect on the generated code

The UserInfo routes in apps and samples (the `resolve-claims` step on hono, `userinfo/route.ts` on Next.js) and the Implicit / Hybrid Flow ID Token issuance all call the core functions without the allowlist argument.
The default applies as-is, so no generated-code change was needed.
Other than restricting requests to standard claim names, there is no behavior difference, and every existing test passes unchanged.

## Verification

All of the following commands succeed.

```bash
pnpm --filter @maronn-openid-connect/core test   # 1336 tests (9 new)
pnpm --filter "./packages/*" test
pnpm --filter "./apps/*" test
pnpm typecheck
pnpm test:conformance
pnpm run lint
```
