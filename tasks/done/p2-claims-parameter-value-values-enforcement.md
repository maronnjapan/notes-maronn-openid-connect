# [P2] UserInfo の `claims` パラメータで `value` / `values` の値一致をフィルタする

## ステータス

🟡 Medium / 未着手

## 背景

`claims` リクエストパラメータの **構造対応**（`userinfo` / `id_token` メンバー、`acr.values` の resolver 連携）は
`tasks/done/p0-claims-id-token-support.md` で完了している。しかし個別クレーム要求に付く
`value` / `values`（特定値での返却要求）は **解釈されていない**。

`packages/core/src/userinfo.ts` の `getRequestedClaimNames` は `claims.userinfo` から
**クレーム名（キー）だけ**を取り出し、`value` / `values` を無視する。このため
`claims.userinfo.email.value="a@example.com"` を要求しても、実際の email が異なっても
そのまま返してしまい、OIDC Core §5.5.1 の「要求した値（のいずれか）で返す」意図に沿わない。

本タスクは UserInfo 側に限定した、仕様で挙動がほぼ確定する最小の値一致フィルタを入れる。
ID Token 側への汎用反映・`essential` の優先扱いは設計判断を伴うため本タスクの対象外とし、
検討は `study-material/done/claims-parameter-value-values-essential.md` に残す。

## 対象ファイル

- `packages/core/src/userinfo.ts`（`handleUserInfoRequest` / claims 適用ロジック）
- `packages/core/src/userinfo.test.ts`

## 仕様参照

- OpenID Connect Core 1.0 §5.5.1 Individual Claims Requests
  — https://openid.net/specs/openid-connect-core-1_0.html#IndividualClaimsRequests
  - `value`: そのクレームを特定の値で返すことを要求する
  - `values`: 列挙された値のいずれかで返すことを要求する
  - `essential: true` でも **取得できない場合に OP はエラーを返してはならない（MUST NOT）**
- 関連検討: `study-material/done/claims-parameter-value-values-essential.md`（方針A）

## 現状の実装

```ts
// packages/core/src/userinfo.ts:232-237
function getRequestedClaimNames(claimsParameter?: ClaimsParameter): (keyof UserClaims)[] {
  if (!claimsParameter?.userinfo) return [];
  return Object.keys(claimsParameter.userinfo) as (keyof UserClaims)[];
}

// userinfo.ts:308-316（claims 適用）
const requestedClaims = getRequestedClaimNames(claimsParameter);
for (const claimName of requestedClaims) {
  if (claimName === 'sub') continue;
  const value = userClaims[claimName];
  if (value !== undefined && value !== null) {
    (response as Record<string, unknown>)[claimName] = value;  // ← value/values を見ず無条件追加
  }
}
```

- `value` / `values` を参照していないため、要求値と実値が不一致でも返す。

## 修正方針

- [ ] `claims.userinfo` の各エントリを「クレーム名 + 要求エントリ（`null | {essential?, value?, values?}`）」として読む
- [ ] 要求エントリに `value` がある場合: 実値が `value` と等価のときだけ当該クレームを返す
- [ ] 要求エントリに `values`（配列）がある場合: 実値が `values` に含まれるときだけ返す
- [ ] `value` / `values` のどちらも無い（`null` または制約なし）場合: 従来どおりクレーム名ベースで返す
- [ ] 一致しない場合は当該クレームを **省略**するだけで **エラーにしない**（§5.5.1 MUST NOT）
- [ ] 等価判定は厳密一致（プリミティブの `===`）を基本とし、オブジェクト型クレーム（`address` 等）は
      `value`/`values` 指定の対象外として扱う（PoC スコープを狭く保つ）

実装例（方針）:

```ts
function matchesRequestedValue(actual: unknown, entry: ClaimRequestValue): boolean {
  if (entry === null) return true;            // 制約なし
  if (entry.value !== undefined) return actual === entry.value;
  if (Array.isArray(entry.values)) return entry.values.includes(actual);
  return true;                                 // essential のみ等、値制約なし
}
```

`handleUserInfoRequest` の claims 適用ループで `matchesRequestedValue(userClaims[name], entry)` が
`true` のときだけ `response[name]` に代入する。

## テスト要件

- [ ] `claims.userinfo.email.value` が実値と一致 → email を返す
- [ ] `claims.userinfo.email.value` が実値と不一致 → email を省略し、**エラーにしない**
- [ ] `claims.userinfo.<claim>.values` に実値が含まれる → 返す
- [ ] `claims.userinfo.<claim>.values` に実値が含まれない → 省略し、エラーにしない
- [ ] `essential: true`（値制約なし）で取得不能 → 省略し、エラーにしない（§5.5.1 MUST NOT）
- [ ] `claims.userinfo.<claim> = null`（制約なし）→ 従来どおり返す（リグレッションなし）
- [ ] scope ベースのクレーム返却が値制約の影響を受けない（claims に出てこないクレームは従来挙動）

## 完了条件

- 上記テストがすべて通る
- `pnpm --filter @maronn-openid-connect/core test` がパスする
- `userinfo.ts` の既存テストが引き続きパスする（リグレッションなし）
