# [P2] 生成 Provider の view 戻り値を `ViewResult` / `renderView` に拡張する

## ステータス

✅ 完了（2026-07-21）

## 背景

Authorization Endpoint の非リダイレクトエラーは、既存 `Views.errorPage(params)` を使ってブラウザ向け HTML を返せるようになっている。一方で、生成 Provider の view API はまだ `string` 戻り値前提であり、framework native response や custom renderer を自然に差し込む余地が狭い。

このタスクは Basic OP の error page 実装とは切り離し、view 拡張性の改善に絞る。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`
- `packages/cli/src/frameworks/web-standard/templates.ts`
- `packages/cli/src/__tests__/hono-generator.test.ts`
- `packages/cli/src/__tests__/web-framework-generators.test.ts`
- `samples/*/src/oidc-provider/views.ts`
- `samples/*/src/oidc-provider/routes/*.ts`
- `samples/nextjs/src/app/_oidc-provider/views.ts`

`samples/*/src/oidc-provider` は CLI 生成物なので、修正元は必ず `packages/cli` に置く。

## 修正方針

- [ ] `Views` の戻り値を `string` 固定から `ViewResult` に拡張する。
- [ ] `ViewResult` は既存互換の `string` と、framework がそのまま返せる response 型を扱える形にする。
- [ ] route 側を `renderView` helper 経由にし、login / consent / error page の返却処理をそろえる。
- [ ] default `renderView` で `string` / `Response` を扱う。
- [ ] Hono / Express / Fastify / Next.js の生成物で、framework ごとの response 変換が破綻しないようにする。
- [ ] Authorization Endpoint の非リダイレクトエラーは引き続き `Views.errorPage(params)` を使い、未登録 `redirect_uri` を view params に渡さない。

## テスト要件

- [ ] `views.ts` に `ViewResult` / `renderView` の拡張点が生成されること。
- [ ] custom `errorPage` が HTML string を返した場合に各 framework でその本文が返ること。
- [ ] custom renderer / `Response` 返却を使うケースをテンプレートテストで固定し、view の戻り値が string 固定へ戻らないことを検出できること。
- [ ] Next.js 生成物では `login/page.tsx` / `consent/page.tsx` の React Server Component 方針を崩さないこと。
- [ ] `pnpm --filter @maronn-openid-connect/cli test` がパスすること。

## 完了条件

生成 Provider の view API が `ViewResult` / `renderView` 経由になり、既存の HTML string view と framework native response の両方を扱えること。
