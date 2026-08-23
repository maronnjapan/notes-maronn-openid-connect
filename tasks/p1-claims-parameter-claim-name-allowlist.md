# [P1] `claims` パラメータのクレーム名にアロウリストを導入し、任意プロパティ読み出しを塞ぐ

## ステータス

🟠 High / 未着手

## 背景

UserInfo の `applyRequestedClaims` は、`claims.userinfo` の **キー名をそのまま `userClaims` のプロパティ名として読み出す**。
読み出してよいクレーム名の集合が定義されておらず、`hasOwnProperty` 検査も無い。

一方 scope 由来の経路（`filterClaimsByScope`）は `SCOPE_CLAIMS_MAP` に載っているクレーム名だけをコピーする
アロウリスト方式である。**同じ `UserClaims` に対して scope 経路はアロウリスト、`claims` 経路は任意キー読み出し**という非対称がある。

`UserClaimsResolver.findUserClaims()` は利用者が実装する。DB の行オブジェクトや内部ユーザーモデルを
そのまま返す実装は PoC で最も自然な書き方であり、その場合
`claims={"userinfo":{"password_hash":null}}` のようなリクエスト 1 本で、
**scope とは無関係にその内部フィールドが UserInfo レスポンスから返る**。

`UserClaims` は閉じた interface で、`getRequestedClaimNames` は `as (keyof UserClaims)[]` とキャストしているため
**型で守られているように読めるが、いずれも実行時の防御ではない**（TypeScript の構造的部分型では
変数経由の余剰プロパティは検査されない）。この「見た目の安全性」が本タスクの主眼。

影響範囲は UserInfo レスポンスに限定される（ID Token 側は `filterClaimsByScope` しか通らない）。

検討詳細は `study-material/done/claims-parameter-claim-name-allowlist.md` を参照。

> 関連（重複しない）:
> - 要求クレームを返してよいと**誰が判断したか**（同意境界）: `study-material/claims-parameter-consent-authorization-boundary.md`
> - 非標準クレームを**運べるようにする**拡張性: `study-material/userinfo-custom-claims-and-scope-claim-mapping-extensibility.md`
> - `value` / `values` / `essential` の判定規則: `study-material/done/claims-parameter-value-values-essential.md`
>
> 本タスクは「**読み出してよいキーの集合を定義する**」ことだけを対象とする。

## 対象ファイル

- `packages/core/src/userinfo.ts`（`getRequestedClaimNames` / `applyRequestedClaims` / `SCOPE_CLAIMS_MAP`）
- `packages/core/src/userinfo.test.ts`
- `study-material/resolver-and-store-contract.md`（resolver 契約の追記）
- `packages/cli/src/frameworks/*/templates.ts`（生成 OP の UserInfo ルートが `applyRequestedClaims` を呼ぶ箇所）
- 各 sample の `conformance.test.ts` を生成する `packages/cli` 側コード

## 仕様参照

- **OIDC Core 1.0 §5.5.1 Individual Claims Requests**: 要求されたクレームを返せない場合でも
  OP は **エラーを返してはならない（MUST NOT return an error）**。`essential` についても
  「best effort で提供する SHOULD」であり、**返さないことは常に仕様適合**。
  → アロウリストで絞ることは仕様違反にならない。
- **OIDC Core 1.0 §5.5**: `claims` は「RP が要求できる」ことを定めるだけで、
  「OP が無条件に返してよい」とは定めていない。返す範囲は OP が決める。
- **OIDC Core 1.0 §5.1 / §5.1.2**: クレーム名は **OP が定義し公開する語彙**。
  Additional Claims は「OP と RP の合意のもとで」使うものと規定されている。
- **OIDC Discovery 1.0 §3**: `claims_supported` は OP が返しうるクレーム名のリスト。
  語彙の宣言場所として仕様が用意している項目（現在は実行時判断に使われていない）。

## 現状の実装

```ts
// packages/core/src/userinfo.ts:257-262
function getRequestedClaimNames(claimsParameter?: ClaimsParameter): (keyof UserClaims)[] {
  if (!claimsParameter?.userinfo) return [];
  return Object.keys(claimsParameter.userinfo) as (keyof UserClaims)[];  // ← 実行時検査なし
}

// packages/core/src/userinfo.ts:477-497
export function applyRequestedClaims(response, userClaims, claimsParameter): UserInfoResponse {
  const result: Record<string, unknown> = { ...response };
  const requestedClaims = getRequestedClaimNames(claimsParameter);
  for (const claimName of requestedClaims) {
    if (claimName === 'sub') continue;
    const value = userClaims[claimName];        // ← 任意プロパティ読み出し / hasOwnProperty 検査なし
    if (value === undefined || value === null) continue;
    const entry = claimsParameter?.userinfo?.[claimName] ?? null;
    if (!matchesRequestedValue(value, entry)) continue;
    result[claimName] = value;                   // ← そのままレスポンスへ
  }
  return result as UserInfoResponse;
}
```

問題:

1. `claimName` が標準クレーム・宣言済みクレームであるかを検査していない。
2. `Object.prototype.hasOwnProperty.call(userClaims, claimName)` の検査が無く、
   プロトタイプチェーン上のプロパティも読める（プレーンオブジェクトの場合、関数値は
   `JSON.stringify` で落ちるため直接の漏洩にはならないが、getter を持つオブジェクトや
   クラスインスタンスを返す resolver では値が返りうる）。
3. Discovery の `claims_supported` と実行時挙動が独立している（広告に無いクレームも返る）。

## 修正方針

- [ ] `applyRequestedClaims` に **`hasOwnProperty` 検査**を追加し、プロトタイプチェーン由来のプロパティを読まない
- [ ] `applyRequestedClaims` に **アロウリスト引数**を追加する（既定は `SCOPE_CLAIMS_MAP` の全クレーム ＋ `sub`）
- [ ] 引数は optional にし、将来 Discovery の `claims_supported` を注入できる形にしておく
      （`study-material/userinfo-custom-claims-and-scope-claim-mapping-extensibility.md` の方針決定への接続点）
- [ ] `handleUserInfoRequest`（合成関数）から新しい引数を渡せるよう `UserInfoRequestContext` を拡張する
- [ ] 既定値を使う限り**既存の挙動は変わらない**こと（標準クレームは従来どおり `claims` 経由で返る）を保証する
- [ ] `UserClaimsResolver.findUserClaims` の JSDoc に契約を追記する
- [ ] `study-material/resolver-and-store-contract.md` に同契約を追記する
- [ ] 生成コードは直接編集せず `packages/cli` テンプレートを修正する

実装例:

```ts
/**
 * `claims` パラメータで要求できるクレーム名の既定アロウリスト。
 *
 * OIDC Core 1.0 §5.5.1: 要求クレームを返せない場合に OP はエラーを返してはならない（MUST NOT）。
 * したがって未知のクレーム名を「黙って返さない」ことは常に仕様適合である。
 *
 * `claims` のキー名は RP が任意に指定できるため、これを resolver が返したオブジェクトの
 * プロパティ名として無検査で読み出すと、利用者が `findUserClaims` から余剰フィールド
 * （DB の行など）を返した場合に scope を迂回して開示される。読み出せるキーを
 * OP が宣言した語彙に限定する。
 */
export const DEFAULT_REQUESTABLE_CLAIMS: ReadonlySet<string> = new Set([
  'sub',
  ...Object.values(SCOPE_CLAIMS_MAP).flat(),
]);

export function applyRequestedClaims(
  response: UserInfoResponse,
  userClaims: UserClaims,
  claimsParameter?: ClaimsParameter,
  allowedClaimNames: ReadonlySet<string> = DEFAULT_REQUESTABLE_CLAIMS,
): UserInfoResponse {
  const result: Record<string, unknown> = { ...response };

  for (const claimName of getRequestedClaimNames(claimsParameter)) {
    if (claimName === 'sub') continue;
    if (!allowedClaimNames.has(claimName)) continue;
    if (!Object.prototype.hasOwnProperty.call(userClaims, claimName)) continue;

    const value = userClaims[claimName as keyof UserClaims];
    if (value === undefined || value === null) continue;

    const entry = claimsParameter?.userinfo?.[claimName] ?? null;
    if (!matchesRequestedValue(value, entry)) continue;

    result[claimName] = value;
  }

  return result as UserInfoResponse;
}
```

`getRequestedClaimNames` の戻り値型も `string[]` に直し、
`as (keyof UserClaims)[]` という**実態と食い違うキャスト**を除去すること。

## テスト要件

`packages/core/src/userinfo.test.ts` に以下を追加する。アサーションは一意値で固定する
（`toContain` / `expect.any` は使わない）。

- [ ] `should return a standard claim requested via the claims parameter`
      — `claims.userinfo.email` を要求し、`email` が返ることを `toEqual` で固定
- [ ] `should not return a non-standard property present on the resolved user claims`
      — resolver が `{ sub, email, password_hash }` を返す状態で
      `claims.userinfo.password_hash` を要求し、レスポンスが `{ sub, email }` と**完全一致**すること
- [ ] `should not return a prototype chain property when requested as a claim`
      — `claims.userinfo.constructor` / `claims.userinfo.toString` を要求し、
      レスポンスが `{ sub }` と完全一致すること
- [ ] `should not alter the response prototype when __proto__ is requested as a claim`
      — `claims.userinfo.__proto__` を要求してもレスポンスが `{ sub }` と完全一致すること
- [ ] `should return only claims within an explicitly supplied allowlist`
      — `allowedClaimNames` を `new Set(['sub', 'email'])` で明示し、
      `claims.userinfo` に `email` と `name` を要求したとき `{ sub, email }` と完全一致すること
- [ ] `should keep the existing behavior when no allowlist is supplied`
      — 既存の `claims` 関連テストが引数追加後も無変更で通ること（後方互換の確認）
- [ ] `should not return an error when a requested claim is not allowed`
      — アロウリスト外を要求しても例外が投げられず 200 相当で返ること（§5.5.1 の MUST NOT）

生成 OP 側:

- [ ] `samples/*/conformance.test.ts`（生成元は `packages/cli`）に
      「resolver が余剰フィールドを返しても `claims` 経由で開示されない」契約テストを追加する

## 完了条件

- `pnpm --filter @maronn-openid-connect/core test` がパスすること
- `pnpm test:conformance` がパスすること
- `pnpm typecheck` がパスすること
- `packages/core/src/userinfo.ts` から `as (keyof UserClaims)[]` の実態と食い違うキャストが除去されていること
- `study-material/resolver-and-store-contract.md` と `UserClaimsResolver` の JSDoc に
  「`findUserClaims` の戻り値は外部開示されうる面である」旨の契約が記載されていること
