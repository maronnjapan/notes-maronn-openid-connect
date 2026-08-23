# [P3] UserInfo エンドポイントのアクセストークン失効境界を他エンドポイントと統一する（`<` → `<=`）

## ステータス

🟢 Low / 未着手

## 背景

「アクセストークンが今失効しているか」を判定する境界演算子が、UserInfo エンドポイントだけ他と食い違っている。

- UserInfo: `expiresAt < now`（`expiresAt === now` のときは**まだ有効**扱い）
- Token（authorization_code / refresh_token 両方）・Introspection: `expiresAt <= now`（`expiresAt === now` は**失効**扱い）

RFC 7519 §4.1.4 は `exp` を「on or after（`exp` 以降）で受理不可」と定めるため、`<=`（境界秒で失効）が慣例に一致する。
`token-expiry-boundary` 系タスク（`tasks/done/p3-token-expiry-boundary-consistency.md`）が扱った
`validateTokenRequest` 内部の refresh_token 側は既に `<=` に修正済みで、**残る唯一の outlier が UserInfo の `<`**。
既存タスクのスコープ（`validateTokenRequest` 内部）には UserInfo が含まれていなかったため、本タスクで是正する。

影響は軽微（トークンを早く失効させる方向ではなく、境界ちょうどの 1 秒だけ甘い方向）だが、
「同一 OP で失効判定がブレる」こと自体が正しさ・保守性の欠陥。

検討の詳細は `study-material/done/userinfo-access-token-expiry-boundary-consistency.md` を参照。

## 対象ファイル

- `packages/core/src/userinfo.ts`（失効判定 L360-366、特に L361）
- `packages/core/src/userinfo.test.ts`

## 仕様参照

- RFC 7519 §4.1.4（`exp` は on-or-after で受理不可 = `exp <= now` で失効）: https://www.rfc-editor.org/rfc/rfc7519#section-4.1.4
- OIDC Core 1.0 §5.3（UserInfo Endpoint、無効/失効トークンは `invalid_token`／401）: https://openid.net/specs/openid-connect-core-1_0.html#UserInfo
- RFC 6749 §5.1 / OAuth 2.1 §3.2.3（`expires_in` は実有効期間を反映）

## 現状の実装

```ts
// packages/core/src/userinfo.ts:360-366
const now = Math.floor(Date.now() / 1000);
if (tokenInfo.expiresAt < now) {          // ← 他は <= 。expiresAt === now でまだ有効になる
  throw new UserInfoError(
    UserInfoErrorCode.InvalidToken,
    'The access token expired'
  );
}
```

参考（統一済みの他エンドポイント）:

```ts
// token-request.ts:503 / :602
if (refreshTokenInfo.expiresAt <= nowForRefresh) { ... }
if (authCode.expiresAt <= now) { ... }
// introspection.ts:94 / :100
if (info.expiresAt <= now) return false;
```

## 修正方針

- [ ] `packages/core/src/userinfo.ts:361` を `if (tokenInfo.expiresAt <= now)` に変更する
- [ ] コメントに RFC 7519 §4.1.4 の on-or-after 慣例と「Token/Introspection と境界を統一」する旨を追記する
- [ ] Token / Introspection の既存境界テストと突き合わせ、`<=` の意味が OP 全体で一意であることを確認する

## テスト要件

- [ ] `expiresAt === now`（ちょうど失効秒）で UserInfo が `invalid_token`（401）を返す（境界回帰の主眼）
- [ ] `expiresAt = now - 1`（明確に失効）で 401 を返す
- [ ] `expiresAt = now + 1`（明確に有効）で 200 と正しいクレームを返す
- [ ] 生成 OP の UserInfo 失効ケースが各 sample の `conformance.test.ts` で固定されているか確認し、
      挙動が変わる場合は `packages/cli` のテンプレート生成側テストを更新する（UserInfo route は core に委譲するため通常は不変）

## 完了条件

- [ ] 上記テストが追加され通過する
- [ ] `pnpm --filter @maronn-openid-connect/core test` がパス
