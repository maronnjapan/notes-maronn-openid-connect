# rp-initiated-logout の `/logout` が express / fastify / nextjs の生成物で配線されない問題

## ステータス

🟡 Medium / タスク化済み（`tasks/p2-rp-initiated-logout-web-standard-route-wiring.md`）

## 1. このトピックで確認したいこと

`maronn-oidc generate <framework> --enable rp-initiated-logout` で生成した OP が、discovery で広告する `end_session_endpoint` に実際に応答できるかを、hono 以外の 3 フレームワークについて確認する。

## 2. 関連する仕様・基準

- OpenID Connect RP-Initiated Logout 1.0 §2
  OP は logout エンドポイントで GET と POST の両方をサポートしなければならない（MUST）。
- OpenID Connect Discovery 1.0 §3
  メタデータで広告したエンドポイントは、その URL で実際に提供されている必要がある（広告と実挙動の整合）。

## 3. 参照資料

- OpenID Connect RP-Initiated Logout 1.0 §2
- `tasks/experimental/done/rp-initiated-logout/`（機能本体の仕様書と実装記録。ルート配線の欠落は扱っていない）

## 4. 現在の実装確認

- 共有の `createApp`（`packages/cli/src/frameworks/web-standard/templates.ts`）は、rpInitiatedLogout 有効時に `/logout` をマウントし、discovery も `end_session_endpoint: ${issuer}/logout` を広告する。
- express 用 `applyOidc` の `OIDC_ENDPOINTS` 配列に `/logout` がない。
  device / ciba / par などは feature ごとの条件付き要素があるが、logout だけ対応する要素が存在しない。
- fastify 用 `applyOidc` のルート登録に `/logout`（GET / POST）と `/logout/approve`（POST）がない。
- nextjs の `nextJsGeneratedFiles` は device / ciba の `route.ts` を生成するが、`logout/route.ts` と `logout/approve/route.ts` を生成しない。
- hono は `app.route('/logout', ...)` とメソッドガード（`'/logout': ['GET','POST']`、`'/logout/approve': ['POST']`）が揃っており問題ない。
- 生成テスト `rp-initiated-logout-feature.test.ts` は共有 `app.ts` の内容しか検証せず、生成される `conformance.test.ts` も `createApp().request()` を直接叩くため、アダプタ層（`applyOidc` / Next の route ファイル）の欠落はどのテストでも検出されない。

## 5. 現在の実装との差分

- express / fastify / nextjs で `--enable rp-initiated-logout` を付けて生成すると、discovery は `end_session_endpoint` を広告するのに、RP がそこへブラウザを送るとフレームワークの 404 になる。
  OP セッションは残り続け、RP-Initiated Logout 1.0 §2 の MUST と広告の整合の両方に反する。
- 既定（logout 無効）の生成物には影響しない。

## 6. 改善・追加を検討する理由

アダプタ層の配線漏れは、共有 `createApp` にルートを足すたびに同じ形で再発しうる。
今回の修正では、配線の追加に加えて、アダプタ層を経由した契約テスト（または generator テスト）で「createApp がマウントするパスとアダプタが公開するパスの一致」を固定する価値がある。

## 7. 実装方針の候補

1. express：`OIDC_ENDPOINTS` に rpInitiatedLogout 条件付きで `/logout` を追加する（`app.use` は前方一致なので `/logout/approve` も届く）。
2. fastify：`/logout`（GET / POST）と `/logout/approve`（POST）のルートを条件付きで追加する。
3. nextjs：`logout/route.ts` と `logout/approve/route.ts` を条件付きで生成する。
4. 再発防止：generator テストで、rpInitiatedLogout 有効時の 3 フレームワークの生成物に logout ルートが含まれることを固定する。

## 8. タスク案

方針 1〜4 を `tasks/p2-rp-initiated-logout-web-standard-route-wiring.md` としてタスク化済み。
