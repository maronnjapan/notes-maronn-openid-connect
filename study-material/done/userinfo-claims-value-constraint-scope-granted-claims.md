# scope で付与済みのクレームには `claims` の value / values 制約が効かない問題

## ステータス

🟡 Medium / タスク化済み（`tasks/p2-userinfo-value-constraint-scope-granted-claims.md`）

## 1. このトピックで確認したいこと

`claims` リクエストパラメータ（OIDC Core 1.0 §5.5.1）の `value` / `values` 制約が、
「scope でも付与されているクレーム」に対して機能しているかを確認する。

`applyRequestedClaims` は scope フィルタ済みレスポンスへ要求クレームを**追加**するだけで、
制約に一致しないクレームを**除去**しない。
そのため、`email` scope が付与されたリクエストで `claims.userinfo.email.value` が実値と
不一致でも、`email` は scope 経由でそのまま返る。
JSDoc の「一致しない場合は省略する」という契約は、scope が重ならない場合にしか成立していない。

## 2. 関連する仕様・基準

- OIDC Core 1.0 §5.5.1 Individual Claims Requests
  - `value`: 「Requests that the Claim be returned with a particular value.」
  - `values`: 「Requests that the Claim be returned with one of a set of values.」
  - いずれも「特定の値での返却を要求する」のであり、不一致時の挙動（省略するか、通常値を返すか）は
    仕様が明示していない。
- 本リポジトリ自身の決定（`tasks/done/p2-claims-parameter-value-values-enforcement.md`）
  - 「`claims.userinfo.email.value` が実値と不一致 → email を省略し、エラーにしない」を採用済み。
  - ただしそのテスト要件はすべて `scope: ['openid']` で書かれており、scope と重なるケースを固定していない。

仕様が明示しない以上、「scope 付与分は制約の対象外」という読み方も可能ではある。
しかし同じ `claims` 指定が scope の組み合わせ次第で効いたり効かなかったりする現状は、
リポジトリが一度決めた「不一致なら省略」の契約とも、`applyRequestedClaims` 自身の JSDoc とも食い違う。

## 3. 参照資料

- OpenID Connect Core 1.0 §5.5.1（value / values / essential の定義）
- `packages/core/src/userinfo.ts` の JSDoc（本リポジトリの公開契約）
- `study-material/done/claims-parameter-value-values-essential.md`（value / values 対応の元調査）

## 4. 現在の実装確認

`packages/core/src/userinfo.ts` の `handleUserInfoRequest`（step 6-7）:

```typescript
const scopedResponse = filterClaimsByScope(userClaims, tokenInfo.scope);
return applyRequestedClaims(scopedResponse, userClaims, claimsParameter);
```

`applyRequestedClaims`（同ファイル）:

```typescript
const result: Record<string, unknown> = { ...response };   // scope 由来の email はすでにここに居る

const requestedClaims = getRequestedClaimNames(claimsParameter);
for (const claimName of requestedClaims) {
  if (claimName === 'sub') continue;
  const value = userClaims[claimName];
  if (value === undefined || value === null) continue;

  const entry = claimsParameter?.userinfo?.[claimName] ?? null;
  if (!matchesRequestedValue(value, entry)) continue;      // 追加をやめるだけで、除去はしない

  result[claimName] = value;
}
```

不一致時に `continue` するのは「追加」の側だけであり、`{ ...response }` に入った
scope 由来の値はそのまま残る。

## 5. 現在の実装との差分

- 満たしていること
  - scope が重ならないクレーム（例: `scope=openid` のみ）では、value / values 不一致時に省略される。
    `userinfo.test.ts` の value / values テストはすべてこのパターンで固定済み。
- 不足していること
  - `scope=openid email` かつ `claims={"userinfo":{"email":{"value":"a@example.com"}}}` で
    実値が不一致の場合、`email` が返る。JSDoc の「一致しない場合は省略する」に反する。
  - 既存テストに scope 重複パターンが 1 件も無く、この挙動が固定されていない。
- ID Token 側の対称性
  - `claims.id_token` の反映（`pickIdTokenRequestedClaims`）も「追加のみ」で構成されている。
    core を直接使い `userClaims` と scope を両方渡す構成では、同じ非対称が成立する。

## 6. 改善・追加を検討する理由

`value` / `values` を「この値のときだけ返してほしい」という条件として使う RP から見ると、
制約が効くかどうかが scope 構成という無関係な要素で決まる現状は、挙動を予測できない。
制約が実際に必要になるのは対象クレームを取得できる（= scope が付与されがちな）場面なので、
「scope が重なると効かない」は、制約が最も使われる場面で効かないことを意味する。

セキュリティ境界の問題ではない（scope を付与された RP はもともとそのクレームを取得できる）。
問題は、公開している契約（JSDoc と done タスクの決定）と実挙動の乖離、
および挙動の一貫性の欠如にある。

## 7. 実装方針の候補

1. **不一致なら除去する（推奨）**
   `applyRequestedClaims` で、`claimsParameter.userinfo` に載っているクレームのうち
   value / values 制約に一致しないものを `result` から削除する。
   done タスクで採用済みの「不一致なら省略」を scope 重複時にも一貫させる。
2. **現挙動を契約にする**
   JSDoc を「scope で付与済みのクレームは制約の対象外」と書き換え、テストで固定する。
   仕様上は許される読み方だが、既に採用した決定と食い違う。

## 8. タスク案

方針 1 で `tasks/p2-userinfo-value-constraint-scope-granted-claims.md` としてタスク化済み。
ID Token 側（`buildIdTokenPayload` + `pickIdTokenRequestedClaims`）の同一パターンも
同タスクの確認項目に含める。
