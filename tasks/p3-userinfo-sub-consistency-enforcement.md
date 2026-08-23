# [P3] UserInfo の `sub` を アクセストークン `sub` にピン留めし一致を強制する

## ステータス

🟡 Medium / 未着手

## 背景

OIDC Core §5.3.2 は「UserInfo Response の `sub` は ID Token の `sub` と完全一致を検証しなければならない（MUST be verified to exactly match）」と定める。正しく実装された RP は不一致応答を破棄するため、OP は一貫した `sub` を返す責任を負う。

現状 `handleUserInfoRequest` は `findUserClaims(tokenInfo.sub)` でルックアップ自体は正しいキーで行うが、レスポンスの `sub` には `filterClaimsByScope` が **resolver が返した** `userClaims.sub` をそのまま設定しており、`userClaims.sub === tokenInfo.sub` の一致検証が無い。`UserClaimsResolver` は利用者の拡張点であり、ルックアップキーと異なる `sub` を返すバグ・カスタマイズがあると UserInfo の `sub` が ID Token と静かに乖離し、相互運用が壊れる（subject confusion の温床）。

`aud` 検証は別タスク（`tasks/p2-userinfo-access-token-audience-validation.md`）。本タスクは `sub` 一致のみを対象とする。詳細な検討は `study-material/done/userinfo-sub-consistency-enforcement.md` を参照。

## 対象ファイル

- `packages/core/src/userinfo.ts`（`handleUserInfoRequest` / `filterClaimsByScope`）
- `packages/core/src/userinfo.test.ts`（テスト追加）
- `study-material/resolver-and-store-contract.md`（resolver 契約の明記）
- `samples/*/conformance.test.ts`（生成元 `packages/cli`、契約テスト追加）

## 仕様参照

- OpenID Connect Core 1.0 §5.3.2「Successful UserInfo Response」
  - 「The `sub` (subject) Claim MUST always be returned in the UserInfo Response.」
  - 「The `sub` Claim in the UserInfo Response MUST be verified to exactly match the `sub` Claim in the ID Token; if they do not match, the UserInfo Response values MUST NOT be used.」
- OpenID Connect Core 1.0 §5.3.1「UserInfo Request」

## 現状の実装

```ts
// packages/core/src/userinfo.ts handleUserInfoRequest
const userClaims = await userClaimsResolver.findUserClaims(tokenInfo.sub); // 行 377（キーは正しい）
const response = filterClaimsByScope(userClaims, tokenInfo.scope);          // 行 386

// filterClaimsByScope（行 214-234）
const result: Record<string, unknown> = { sub: userClaims.sub };           // 行 218
// ← resolver が返した sub をそのまま採用。tokenInfo.sub との一致検証が無い
```

## 修正方針

- [ ] 方針A（ピン留め, 推奨）: `handleUserInfoRequest` で UserInfo レスポンスの `sub` を `tokenInfo.sub` に強制設定する。
  ```ts
  const response = filterClaimsByScope(userClaims, tokenInfo.scope);
  // OIDC Core §5.3.2: UserInfo sub MUST match the access token (ID Token) sub.
  (response as Record<string, unknown>).sub = tokenInfo.sub;
  ```
  - resolver が何を返しても UserInfo の `sub` は必ず ID Token の `sub` と一致する
  - pairwise/PPID を将来扱う場合も、`tokenInfo.sub` 自体が PPID であるべき（`study-material/pairwise-subject-identifier.md`）なのでピン留めが正しい
- [ ] （任意）開発時に `userClaims.sub !== tokenInfo.sub` を warn ログで検出し、resolver 契約違反に気付けるようにする
- [ ] 署名付き UserInfo（JWT）経路でも `sub` が `tokenInfo.sub` になることを確認
- [ ] `study-material/resolver-and-store-contract.md` に「`findUserClaims(sub)` の戻り `sub` は引数と一致すること」契約を追記

## テスト要件

- [ ] resolver が `tokenInfo.sub` と異なる `sub` を返しても、UserInfo レスポンスの `sub` が `tokenInfo.sub` と一致する
- [ ] resolver が `sub` 欠落レコードを返しても、UserInfo の `sub` が `tokenInfo.sub` で補完される（§5.3.2「always returned」を満たす）
- [ ] 署名付き UserInfo（JWT）でも `sub` クレームが `tokenInfo.sub` になる
- [ ] 通常ケース（resolver の `sub` == `tokenInfo.sub`）で従来どおり動作する（リグレッション無し）
- [ ] `samples/*/conformance.test.ts` に UserInfo `sub` 一致の契約テストを追加

## 完了条件

- `pnpm --filter @maronn-openid-connect/core test` がパスすること
- 各 sample の `conformance.test.ts` がパスすること
