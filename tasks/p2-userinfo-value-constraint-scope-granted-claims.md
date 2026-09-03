# [P2] scope で付与済みのクレームにも `claims` の value / values 制約を適用する

## ステータス

🟡 Medium / 未着手

## 背景

`claims` リクエストパラメータの `value` / `values` 制約（OIDC Core 1.0 §5.5.1）について、
本リポジトリは「実値と不一致なら省略し、エラーにしない」を採用済みである
（`tasks/done/p2-claims-parameter-value-values-enforcement.md`）。

しかし `applyRequestedClaims` は scope フィルタ済みレスポンスへ要求クレームを追加するだけで、
不一致のクレームを除去しない。
そのため `scope=openid email` のように対象クレームが scope でも付与されるリクエストでは、
`claims={"userinfo":{"email":{"value":"a@example.com"}}}` が実値と不一致でも
`email` が scope 経由でそのまま返り、採用済みの決定と JSDoc の契約
（「一致しない場合は省略する」）に反する。
既存テストの value / values ケースはすべて `scope: ['openid']` で書かれており、
scope 重複パターンが固定されていない。

詳細は `study-material/done/userinfo-claims-value-constraint-scope-granted-claims.md` を参照。

## 対象ファイル

- `packages/core/src/userinfo.ts`（`applyRequestedClaims`）
- `packages/core/src/userinfo.test.ts`（scope 重複パターンのテスト追加）
- `packages/core/src/token-response.ts` / `token-response.test.ts`
  （ID Token 側の同一パターン確認。`buildIdTokenPayload` で scope 由来クレームと
  `pickIdTokenRequestedClaims` を併用したときの挙動を揃える）

## 仕様参照

- OIDC Core 1.0 §5.5.1 Individual Claims Requests（value / values の定義）
  - 不一致時の挙動は仕様が明示しないため、本リポジトリの採用済み決定
    （不一致なら省略、エラーにしない）に一貫させる
- `packages/core/src/userinfo.ts` の `applyRequestedClaims` JSDoc（公開契約）

## 現状の実装

```typescript
// packages/core/src/userinfo.ts（applyRequestedClaims）
const result: Record<string, unknown> = { ...response };   // scope 由来の email はここに残る

for (const claimName of requestedClaims) {
  if (claimName === 'sub') continue;
  const value = userClaims[claimName];
  if (value === undefined || value === null) continue;
  const entry = claimsParameter?.userinfo?.[claimName] ?? null;
  if (!matchesRequestedValue(value, entry)) continue;      // 追加をやめるだけ
  result[claimName] = value;
}
```

## 修正方針

- [ ] `applyRequestedClaims` で、`claimsParameter.userinfo` に載っているクレームのうち
      value / values 制約に一致しないものを `result` から削除する
      （追加をやめるだけでなく、scope 由来の値も除去する）
- [ ] `sub` は従来どおり対象外（アクセストークンの subject で確定済み）
- [ ] `essential: true` のみで value / values の無いエントリは値制約なしとして従来どおり返す
- [ ] JSDoc を実挙動に合わせて更新する（「scope 付与分にも制約が効く」ことを明記）
- [ ] ID Token 側（`buildIdTokenPayload` の scope フィルタ + `pickIdTokenRequestedClaims`）で
      同じ非対称が残らないよう挙動を確認し、必要なら同じ規則で除去する

## テスト要件

- [ ] `should omit email when scope grants it but the requested value does not match`
      （`scope: ['openid','email']` + `claims.userinfo.email.value` 不一致 → email 省略、エラーなし）
- [ ] `should include email when scope grants it and the requested value matches`
      （同 scope + value 一致 → email が返る）
- [ ] `should keep scope-granted claims that are not listed in the claims parameter`
      （`claims` に載っていない scope 由来クレームは従来どおり返る）
- [ ] `should keep email for an essential-only request without value constraints`
      （`{"essential":true}` のみ → 制約なしとして返る）
- [ ] ID Token 側: scope 由来クレームと `claims.id_token` の value 不一致が併存するケースの挙動を固定

## 完了条件

```bash
pnpm --filter @maronn-openid-connect/core test
```

- 上記が成功し、追加テストがすべて緑であること
- `samples/*/conformance.test.ts` に影響がある場合は `packages/cli` の生成元経由で更新すること
