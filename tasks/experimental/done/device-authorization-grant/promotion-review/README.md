# 昇格レビューパケット: device-authorization-grant

> **このディレクトリは `pnpm review:experimental device-authorization-grant` が生成した機械生成物です。**
> `decision.md` 以外はツールが再生成のたびに作り直します。手で編集しないでください。

experimental 機能 `device-authorization-grant` を experimental から外してよいか（昇格させてよいか）を、
**人間がレビューして判断する** ための材料一式です。
ツールは材料の収集と差分の切り出しだけを行い、判断はしません。
判断は [decision.md](./decision.md) に記録してください。

- 準拠仕様: RFC 8628 - OAuth 2.0 Device Authorization Grant
- [tasks/experimental/done/device-authorization-grant/specification.md](../../../../../tasks/experimental/done/device-authorization-grant/specification.md)
- [tasks/experimental/done/device-authorization-grant/understanding-guide.md](../../../../../tasks/experimental/done/device-authorization-grant/understanding-guide.md)
- [tasks/experimental/done/device-authorization-grant/sources.md](../../../../../tasks/experimental/done/device-authorization-grant/sources.md)
- [tasks/experimental/done/device-authorization-grant/review-log.md](../../../../../tasks/experimental/done/device-authorization-grant/review-log.md)
- [tasks/experimental/done/device-authorization-grant/state.yaml](../../../../../tasks/experimental/done/device-authorization-grant/state.yaml)

## 1. この機能を構成するコードの地図

### 1.1 experimental パッケージ本体（ロジック層）

実装（[packages/experimental/src/device-authorization-grant](../../../../../packages/experimental/src/device-authorization-grant)）:

| ファイル | 行数 |
|---|---|
| [packages/experimental/src/device-authorization-grant/device-authorization-request.ts](../../../../../packages/experimental/src/device-authorization-grant/device-authorization-request.ts) | 204 |
| [packages/experimental/src/device-authorization-grant/device-code-grant.ts](../../../../../packages/experimental/src/device-authorization-grant/device-code-grant.ts) | 184 |
| [packages/experimental/src/device-authorization-grant/errors.ts](../../../../../packages/experimental/src/device-authorization-grant/errors.ts) | 72 |
| [packages/experimental/src/device-authorization-grant/index.ts](../../../../../packages/experimental/src/device-authorization-grant/index.ts) | 69 |
| [packages/experimental/src/device-authorization-grant/store.ts](../../../../../packages/experimental/src/device-authorization-grant/store.ts) | 108 |
| [packages/experimental/src/device-authorization-grant/test-helpers.ts](../../../../../packages/experimental/src/device-authorization-grant/test-helpers.ts) | 68 |
| [packages/experimental/src/device-authorization-grant/user-code.ts](../../../../../packages/experimental/src/device-authorization-grant/user-code.ts) | 94 |
| [packages/experimental/src/device-authorization-grant/verification.ts](../../../../../packages/experimental/src/device-authorization-grant/verification.ts) | 248 |

単体テスト:

| ファイル | 行数 |
|---|---|
| [packages/experimental/src/device-authorization-grant/device-authorization-request.test.ts](../../../../../packages/experimental/src/device-authorization-grant/device-authorization-request.test.ts) | 442 |
| [packages/experimental/src/device-authorization-grant/device-code-grant.test.ts](../../../../../packages/experimental/src/device-authorization-grant/device-code-grant.test.ts) | 371 |
| [packages/experimental/src/device-authorization-grant/user-code.test.ts](../../../../../packages/experimental/src/device-authorization-grant/user-code.test.ts) | 137 |
| [packages/experimental/src/device-authorization-grant/verification.test.ts](../../../../../packages/experimental/src/device-authorization-grant/verification.test.ts) | 412 |

### 1.2 CLI 統合（コード生成側）

`packages/cli` 内で `device-authorization-grant` に言及しているファイル（言及回数は機械カウント）:

| ファイル | 言及回数 |
|---|---|
| [packages/cli/src/__tests__/cli.test.ts](../../../../../packages/cli/src/__tests__/cli.test.ts) | 1 |
| [packages/cli/src/__tests__/device-authorization-grant-feature.test.ts](../../../../../packages/cli/src/__tests__/device-authorization-grant-feature.test.ts) | 48 |
| [packages/cli/src/__tests__/features.test.ts](../../../../../packages/cli/src/__tests__/features.test.ts) | 6 |
| [packages/cli/src/__tests__/jarm-feature.test.ts](../../../../../packages/cli/src/__tests__/jarm-feature.test.ts) | 3 |
| [packages/cli/src/__tests__/par-feature.test.ts](../../../../../packages/cli/src/__tests__/par-feature.test.ts) | 4 |
| [packages/cli/src/__tests__/token-exchange-feature.test.ts](../../../../../packages/cli/src/__tests__/token-exchange-feature.test.ts) | 3 |
| [packages/cli/src/features.ts](../../../../../packages/cli/src/features.ts) | 8 |
| [packages/cli/src/frameworks/hono/index.ts](../../../../../packages/cli/src/frameworks/hono/index.ts) | 2 |
| [packages/cli/src/frameworks/hono/templates.ts](../../../../../packages/cli/src/frameworks/hono/templates.ts) | 39 |
| [packages/cli/src/frameworks/web-standard/templates.ts](../../../../../packages/cli/src/frameworks/web-standard/templates.ts) | 11 |
| [packages/cli/src/index.ts](../../../../../packages/cli/src/index.ts) | 2 |

テンプレートファイルは巨大なため、直接読むより **次節の生成コード差分で読む** ことを推奨します。
テンプレート側の変更意図を確認したいときだけ、上の言及箇所を検索してください。

### 1.3 生成コードへの寄与（このパケットの中心）

`maronn-oidc generate <framework>`（デフォルト構成 = `default-op`）に
`--enable device-authorization-grant`（= `with-device-authorization-grant`）を足したときに生成コードへ入る差分だけを、
フレームワークごとに機械的に切り出したものです。**他機能のコードは一切混ざっていません。**

| フレームワーク | 差分ドキュメント | 追加 | 変更 | 削除 | 規模 |
|---|---|---|---|---|---|
| hono | [generated-code/hono.md](./generated-code/hono.md) | 2 | 7 | 0 | +1806 / -36 |
| express | [generated-code/express.md](./generated-code/express.md) | 2 | 7 | 0 | +1793 / -36 |
| fastify | [generated-code/fastify.md](./generated-code/fastify.md) | 2 | 7 | 0 | +1795 / -36 |
| nextjs | [generated-code/nextjs.md](./generated-code/nextjs.md) | 6 | 6 | 0 | +1817 / -36 |

差分に **現れない** 生成ファイル（この機能のレビューでは読む必要がないもの）:

- hono: config.ts, resolvers.ts, routes/authorize.ts, routes/consent.ts, routes/introspection.ts, routes/jwks.ts, routes/login.ts, routes/revocation.ts, routes/userinfo.ts
- express: config.ts, node-adapter.ts, resolvers.ts, routes/authorize.ts, routes/consent.ts, routes/introspection.ts, routes/jwks.ts, routes/login.ts, routes/revocation.ts, routes/userinfo.ts, web-router.ts
- fastify: config.ts, node-adapter.ts, resolvers.ts, routes/authorize.ts, routes/consent.ts, routes/introspection.ts, routes/jwks.ts, routes/login.ts, routes/revocation.ts, routes/userinfo.ts, web-router.ts
- nextjs: .well-known/jwks.json/route.ts, .well-known/openid-configuration/route.ts, _oidc-provider/config.ts, _oidc-provider/next.ts, _oidc-provider/resolvers.ts, _oidc-provider/routes/authorize.ts, _oidc-provider/routes/consent.ts, _oidc-provider/routes/introspection.ts, _oidc-provider/routes/jwks.ts, _oidc-provider/routes/login.ts, _oidc-provider/routes/revocation.ts, _oidc-provider/routes/userinfo.ts, _oidc-provider/runtime.ts, _oidc-provider/storage-backend.ts, _oidc-provider/web-router.ts, authorize/route.ts, consent/actions.ts, consent/page.tsx, introspect/route.ts, login/actions.ts, login/page.tsx, oidc-error/error.tsx, oidc-error/page.tsx, revoke/route.ts, token/route.ts, userinfo/route.ts

`conformance.test.ts` の差分には、この機能が生成 OP に保証させる挙動（契約テスト）が
すべて含まれます。**仕様と実装の突き合わせはここを起点にしてください。**

### 1.4 サンプルでの実配置

| サンプル | --enable | この機能 |
|---|---|---|
| [samples/express-flyio](../../../../../samples/express-flyio) | device-authorization-grant | **有効** |
| [samples/fastify-flyio](../../../../../samples/fastify-flyio) | device-authorization-grant | **有効** |
| [samples/hono-cloudflare](../../../../../samples/hono-cloudflare) | par, token-exchange, transaction-binding, jarm, device-authorization-grant | **有効** |
| [samples/nextjs-vercel](../../../../../samples/nextjs-vercel) | device-authorization-grant | **有効** |

有効なサンプルの生成ディレクトリ（`src/oidc-provider` など）は、他機能と併用した合成結果です。
単独の寄与は 1.3 の差分で、他機能との併用結果はサンプルの実コードと conformance.test.ts で確認できます。

### 1.5 E2E テスト（実ブラウザ・実 HTTP フロー）

| ファイル | 言及回数 |
|---|---|
| [tests/e2e/specs/device-authorization-grant.spec.ts](../../../../../tests/e2e/specs/device-authorization-grant.spec.ts) | 6 |

### 1.6 ドキュメント

| ファイル | 言及回数 |
|---|---|
| [docs/library-document/src/content/docs/experimental/device-authorization-grant.md](../../../../../docs/library-document/src/content/docs/experimental/device-authorization-grant.md) | 7 |
| [docs/library-document/src/content/docs/experimental/index.md](../../../../../docs/library-document/src/content/docs/experimental/index.md) | 2 |
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
`pnpm review:experimental device-authorization-grant --check` が失敗する場合、パケット生成後に実装が変わっています。
再生成して差分を確認してから判断してください。判断の記録時には `reviewed_commit` に
`--check` が通った時点のコミット SHA を残すと、あとから「何を見て判断したか」を追えます。
