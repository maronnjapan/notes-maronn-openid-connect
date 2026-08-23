# 昇格レビューパケット: token-exchange

> **このディレクトリは `pnpm review:experimental token-exchange` が生成した機械生成物です。**
> `decision.md` 以外はツールが再生成のたびに作り直します。手で編集しないでください。

experimental 機能 `token-exchange` を experimental から外してよいか（昇格させてよいか）を、
**人間がレビューして判断する** ための材料一式です。
ツールは材料の収集と差分の切り出しだけを行い、判断はしません。
判断は [decision.md](./decision.md) に記録してください。

- 準拠仕様: RFC 8693 - OAuth 2.0 Token Exchange
- [tasks/experimental/done/token-exchange/specification.md](../../../../../tasks/experimental/done/token-exchange/specification.md)
- [tasks/experimental/done/token-exchange/understanding-guide.md](../../../../../tasks/experimental/done/token-exchange/understanding-guide.md)
- [tasks/experimental/done/token-exchange/sources.md](../../../../../tasks/experimental/done/token-exchange/sources.md)
- [tasks/experimental/done/token-exchange/review-log.md](../../../../../tasks/experimental/done/token-exchange/review-log.md)
- [tasks/experimental/done/token-exchange/state.yaml](../../../../../tasks/experimental/done/token-exchange/state.yaml)

## 1. この機能を構成するコードの地図

### 1.1 experimental パッケージ本体（ロジック層）

実装（[packages/experimental/src/token-exchange](../../../../../packages/experimental/src/token-exchange)）:

| ファイル | 行数 |
|---|---|
| [packages/experimental/src/token-exchange/index.ts](../../../../../packages/experimental/src/token-exchange/index.ts) | 39 |
| [packages/experimental/src/token-exchange/token-exchange-request.ts](../../../../../packages/experimental/src/token-exchange/token-exchange-request.ts) | 595 |

単体テスト:

| ファイル | 行数 |
|---|---|
| [packages/experimental/src/token-exchange/token-exchange-request.test.ts](../../../../../packages/experimental/src/token-exchange/token-exchange-request.test.ts) | 1221 |

### 1.2 CLI 統合（コード生成側）

`packages/cli` 内で `token-exchange` に言及しているファイル（言及回数は機械カウント）:

| ファイル | 言及回数 |
|---|---|
| [packages/cli/src/__tests__/cli.test.ts](../../../../../packages/cli/src/__tests__/cli.test.ts) | 1 |
| [packages/cli/src/__tests__/device-authorization-grant-feature.test.ts](../../../../../packages/cli/src/__tests__/device-authorization-grant-feature.test.ts) | 7 |
| [packages/cli/src/__tests__/features.test.ts](../../../../../packages/cli/src/__tests__/features.test.ts) | 6 |
| [packages/cli/src/__tests__/jarm-feature.test.ts](../../../../../packages/cli/src/__tests__/jarm-feature.test.ts) | 6 |
| [packages/cli/src/__tests__/par-feature.test.ts](../../../../../packages/cli/src/__tests__/par-feature.test.ts) | 5 |
| [packages/cli/src/__tests__/token-exchange-feature.test.ts](../../../../../packages/cli/src/__tests__/token-exchange-feature.test.ts) | 51 |
| [packages/cli/src/features.ts](../../../../../packages/cli/src/features.ts) | 9 |
| [packages/cli/src/frameworks/hono/templates.ts](../../../../../packages/cli/src/frameworks/hono/templates.ts) | 52 |
| [packages/cli/src/frameworks/web-standard/templates.ts](../../../../../packages/cli/src/frameworks/web-standard/templates.ts) | 6 |
| [packages/cli/src/index.ts](../../../../../packages/cli/src/index.ts) | 2 |

テンプレートファイルは巨大なため、直接読むより **次節の生成コード差分で読む** ことを推奨します。
テンプレート側の変更意図を確認したいときだけ、上の言及箇所を検索してください。

### 1.3 生成コードへの寄与（このパケットの中心）

`maronn-oidc generate <framework>`（デフォルト構成 = `default-op`）に
`--enable token-exchange`（= `with-token-exchange`）を足したときに生成コードへ入る差分だけを、
フレームワークごとに機械的に切り出したものです。**他機能のコードは一切混ざっていません。**

| フレームワーク | 差分ドキュメント | 追加 | 変更 | 削除 | 規模 |
|---|---|---|---|---|---|
| hono | [generated-code/hono.md](./generated-code/hono.md) | 0 | 4 | 0 | +847 / -2 |
| express / fastify | [generated-code/express-fastify.md](./generated-code/express-fastify.md) | 0 | 4 | 0 | +847 / -2 |
| nextjs | [generated-code/nextjs.md](./generated-code/nextjs.md) | 0 | 4 | 0 | +847 / -2 |

差分に **現れない** 生成ファイル（この機能のレビューでは読む必要がないもの）:

- hono: app.ts, apply.ts, resolvers.ts, routes/authorize.ts, routes/consent.ts, routes/introspection.ts, routes/jwks.ts, routes/login.ts, routes/revocation.ts, routes/userinfo.ts, store.ts, views.ts
- express / fastify: app.ts, apply.ts, node-adapter.ts, resolvers.ts, routes/authorize.ts, routes/consent.ts, routes/introspection.ts, routes/jwks.ts, routes/login.ts, routes/revocation.ts, routes/userinfo.ts, store.ts, views.ts, web-router.ts
- nextjs: .well-known/jwks.json/route.ts, .well-known/openid-configuration/route.ts, _oidc-provider/app.ts, _oidc-provider/next.ts, _oidc-provider/resolvers.ts, _oidc-provider/routes/authorize.ts, _oidc-provider/routes/consent.ts, _oidc-provider/routes/introspection.ts, _oidc-provider/routes/jwks.ts, _oidc-provider/routes/login.ts, _oidc-provider/routes/revocation.ts, _oidc-provider/routes/userinfo.ts, _oidc-provider/runtime.ts, _oidc-provider/storage-backend.ts, _oidc-provider/store.ts, _oidc-provider/views.ts, _oidc-provider/web-router.ts, authorize/route.ts, consent/actions.ts, consent/page.tsx, introspect/route.ts, login/actions.ts, login/page.tsx, oidc-error/error.tsx, oidc-error/page.tsx, revoke/route.ts, token/route.ts, userinfo/route.ts

`conformance.test.ts` の差分には、この機能が生成 OP に保証させる挙動（契約テスト）が
すべて含まれます。**仕様と実装の突き合わせはここを起点にしてください。**

### 1.4 サンプルでの実配置

| サンプル | --enable | この機能 |
|---|---|---|
| [samples/express-flyio](../../../../../samples/express-flyio) | device-authorization-grant | 無効 |
| [samples/fastify-flyio](../../../../../samples/fastify-flyio) | device-authorization-grant | 無効 |
| [samples/hono-cloudflare](../../../../../samples/hono-cloudflare) | par, token-exchange, transaction-binding, jarm, device-authorization-grant | **有効** |
| [samples/nextjs-vercel](../../../../../samples/nextjs-vercel) | device-authorization-grant | 無効 |

有効なサンプルの生成ディレクトリ（`src/oidc-provider` など）は、他機能と併用した合成結果です。
単独の寄与は 1.3 の差分で、他機能との併用結果はサンプルの実コードと conformance.test.ts で確認できます。

### 1.5 E2E テスト（実ブラウザ・実 HTTP フロー）

| ファイル | 言及回数 |
|---|---|
| [tests/e2e/apps/client.mjs](../../../../../tests/e2e/apps/client.mjs) | 1 |
| [tests/e2e/playwright.config.ts](../../../../../tests/e2e/playwright.config.ts) | 2 |
| [tests/e2e/specs/token-exchange.spec.ts](../../../../../tests/e2e/specs/token-exchange.spec.ts) | 8 |
| [tests/e2e/specs/transaction-binding.spec.ts](../../../../../tests/e2e/specs/transaction-binding.spec.ts) | 1 |

### 1.6 ドキュメント

| ファイル | 言及回数 |
|---|---|
| [docs/library-document/src/content/docs/experimental/index.md](../../../../../docs/library-document/src/content/docs/experimental/index.md) | 2 |
| [docs/library-document/src/content/docs/experimental/token-exchange.md](../../../../../docs/library-document/src/content/docs/experimental/token-exchange.md) | 15 |
| [packages/experimental/README.md](../../../../../packages/experimental/README.md) | 2 |

## 2. 推奨レビュー手順

1. 仕様書（specification.md）と review-log.md を読み、期待挙動と過去の論点を把握する
2. 1.1 の experimental 本体実装と単体テストを読む
3. 1.3 の生成コード差分を読む（conformance.test.ts の差分 = この機能の契約）
4. 必要に応じて 1.4 のサンプルで他機能との併用結果を確認し、実起動して触る（`pnpm sample:hono-cloudflare` など）
5. 1.5 の E2E テストを読む・実行する（`pnpm test:e2e`）
6. [decision.md](./decision.md) のチェックリストを埋め、判断を記録する

## 3. 鮮度について

このパケットは生成時点のリポジトリ内容のスナップショットです。
`pnpm review:experimental token-exchange --check` が失敗する場合、パケット生成後に実装が変わっています。
再生成して差分を確認してから判断してください。判断の記録時には `reviewed_commit` に
`--check` が通った時点のコミット SHA を残すと、あとから「何を見て判断したか」を追えます。
