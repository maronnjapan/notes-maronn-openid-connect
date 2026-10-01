# [P2] rp-initiated-logout の `/logout` を express / fastify / nextjs の生成物に配線する

## ステータス

🟡 Medium / 未着手

## 背景

`--enable rp-initiated-logout` で生成した OP は、共有の `createApp` が `/logout` をマウントし、discovery が `end_session_endpoint: ${issuer}/logout` を広告する。
しかし hono 以外の 3 フレームワークでは、アダプタ層がこのルートを公開していない。

- express：`applyOidc` の `OIDC_ENDPOINTS` 配列に `/logout` がない
- fastify：`applyOidc` のルート登録に `/logout` と `/logout/approve` がない
- nextjs：`nextJsGeneratedFiles` が `logout/route.ts` と `logout/approve/route.ts` を生成しない

結果、RP が `end_session_endpoint` へブラウザを送るとフレームワークの 404 になり、OP セッションが残り続ける。
生成テストは共有 `app.ts` しか検証せず、conformance テストも `createApp().request()` を直接叩くため、アダプタ層の欠落はどのテストでも検出されない。

詳細は `study-material/done/rp-initiated-logout-web-standard-route-wiring.md` を参照。

## 対象ファイル

- `packages/cli/src/frameworks/web-standard/templates.ts`
  - `expressApplyTemplate`（`OIDC_ENDPOINTS`）
  - `fastifyApplyTemplate`（ルート登録）
  - `nextJsGeneratedFiles`（route.ts の生成）
- `packages/cli/src/__tests__/rp-initiated-logout-feature.test.ts`（アダプタ層の検証を追加）
- 再生成対象の `samples/*`（rp-initiated-logout を有効にしている sample があれば）

## 仕様参照

- OpenID Connect RP-Initiated Logout 1.0 §2：logout エンドポイントは GET と POST をサポートしなければならない（MUST）
- OpenID Connect Discovery 1.0 §3：広告したエンドポイントは実際に提供する

## 現状の実装

- 共有 `createApp` は rpInitiatedLogout 有効時に `app.route('/logout', logoutPage)` をマウントする
- hono のみ `/logout`（GET / POST）と `/logout/approve`（POST）のメソッドガードまで揃っている
- express の `app.use` は前方一致でパスを引き渡すため、`OIDC_ENDPOINTS` に `/logout` を足せば `/logout/approve` にも届く

## 修正方針

- [ ] express：rpInitiatedLogout 有効時に `OIDC_ENDPOINTS` へ `/logout` を追加する（device / ciba と同じ条件付き変数の形式）
- [ ] fastify：rpInitiatedLogout 有効時に `/logout`（GET / POST）と `/logout/approve`（POST）のルートを追加する
- [ ] nextjs：rpInitiatedLogout 有効時に `logout/route.ts` と `logout/approve/route.ts` を生成する（device / ciba の route.ts と同じ形式）
- [ ] 生成物に差分が出る sample があれば再生成する

## テスト要件

- [ ] `should expose the logout endpoints through the express adapter when rp-initiated-logout is enabled`
- [ ] `should expose the logout endpoints through the fastify adapter when rp-initiated-logout is enabled`
- [ ] `should generate logout route files for nextjs when rp-initiated-logout is enabled`
- [ ] `should not expose logout endpoints when rp-initiated-logout is disabled`（3 フレームワーク）
- [ ] 可能なら、アダプタ経由で `GET /logout` が 200 を返すことを検証する統合テスト（既存のアダプタテストの形式に従う）

## 完了条件

```bash
pnpm --filter @maronn-openid-connect/cli test
pnpm run typecheck
```

- 追加テストがすべて緑であること
- `--enable rp-initiated-logout` で生成した express / fastify / nextjs の生成物で、`end_session_endpoint` の URL が 404 にならないこと
