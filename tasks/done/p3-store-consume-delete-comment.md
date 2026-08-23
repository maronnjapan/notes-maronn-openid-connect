# [P3] 生成 store の `consume()` / `delete()` の使い分けコメントを補強する

## ステータス

🟢 Low / 未着手（`tasks/done/p1-revoke-mark-used-contract-and-reuse-cascade-regression.md` から任意残作業を切り出し）

## 背景

`revokeAuthorizationCode` / `revokeRefreshToken` は、再利用検知時に同一 grant のトークンを失効できるよう、物理削除ではなく `used=true` への状態更新として扱う責務が JSDoc と conformance test で固定されている。

生成 store には `consume()` と `delete()` が同居しているため、利用者が読み替えやすいように、store 実装側にも「resolver からは `consume()` を使う」「`delete()` は物理削除が正しい場面だけに使う」という短いコメントを置く。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`
- `samples/hono/src/oidc-provider/store.ts`
- `samples/express/src/oidc-provider/store.ts`
- `samples/fastify/src/oidc-provider/store.ts`
- `samples/nextjs/src/app/_oidc-provider/store.ts`
- 必要に応じて `packages/cli/src/__tests__/hono-generator.test.ts`

`samples/*/src/oidc-provider` は CLI 生成物なので、修正元は必ず `packages/cli` に置く。

## 修正方針

- [ ] `AuthorizationCodeStore.consume()` に、認可コード再利用検知のため `used=true` として保持する旨をコメントする。
- [ ] `RefreshTokenStore.consume()` に、ローテーション済み refresh token の再利用検知のため `used=true` として保持する旨をコメントする。
- [ ] `delete()` は revocation / grant cascade / 期限切れ回収など、物理削除が妥当な場面向けであることを簡潔にコメントする。
- [ ] コメント追加に伴う生成物差分を `samples/*` に同期する。

## テスト要件

- [ ] 必要なら generator test でコメントまたは `consume()` 利用がテンプレートに残ることを固定する。
- [ ] `pnpm --filter @maronn-openid-connect/cli test` がパスすること。

## 完了条件

生成 store を読んだ利用者が、再利用検知用の `consume()` と物理削除用の `delete()` を混同しにくい状態になっていること。
