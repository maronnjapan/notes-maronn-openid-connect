# [P1] `id_token_hint` 検証用 JWKS provider を生成 Provider の既定配線にする

## ステータス

🟢 High / 既定 jwksProvider 配線済み（OP 自身の ID Token 鍵で hint 検証）。full success-flow の id_token_hint テストは E2E へ繰り越し

## 背景

`tests/conformance` の直近実行で `oidcc-id-token-hint` が失敗している。

対象結果:

- `tests/conformance/results/oidcc-basic-certification-test-plan-discovery-static_client-5XeV397bGW050-17-Jun-2026.zip`
- module: `oidcc-id-token-hint`
- status/result: `INTERRUPTED / FAILED`
- 直接原因: `prompt=none + id_token_hint` の2回目認可で `login_required` が返る
- エラー詳細: `jwksProvider is not configured; cannot verify id_token_hint`

`validateIdTokenHint` 自体は実装済みだが、CLI 生成 Provider / samples の通常起動では `jwksProvider` が未指定のため、OP 自身が発行した ID Token を hint として検証できない。

この失敗は「Cookie が切れても `id_token_hint` だけで認証済みにするべき」という話ではない。Cookie / session が失効している場合は従来どおり認証が必要であり、`prompt=none` なら `login_required` を返す。`id_token_hint` の役割は、request がどの End-User の過去または現在の認証を前提としているかを OP に伝え、既存 session と同じ subject かを安全に確認することにある。

Conformance Suite の `oidcc-id-token-hint` では、1回目の認証で作られた browser session が残っている前提で、同じ ID Token を2回目の `prompt=none` request に hint として渡す。このとき OP は hint の署名・issuer・audience・有効期限などを検証し、hint が示す subject と現在の session subject が一致する場合に即時成功できる。現在は `jwksProvider` が無いため hint を検証できず、session が残っていても「hint が信頼できない」状態になり、`login_required` へ落ちている。

## 調査根拠

- OIDC Core 1.0 §3.1.2.1: `id_token_hint` は End-User の現在または過去の認証セッションの hint として使われ、hint が示すユーザーがログイン済みなら OP は成功応答を返せる。
- OIDC Core 1.0 §3.1.2.2: `id_token_hint` がある場合、OP は自分が発行した ID Token であることを検証する必要がある。
- Conformance Suite `OIDCCIdTokenHint`: 1回目の ID Token を2回目の `prompt=none` リクエストに `id_token_hint` として付け、即時成功を期待する。
- 現行実装: `authorize.ts` は `jwksProvider` 未設定時に `login_required` を返す。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`
- `packages/cli/src/frameworks/web-standard/templates.ts`
- `packages/cli/src/__tests__/hono-generator.test.ts`
- `packages/cli/src/__tests__/web-framework-generators.test.ts`
- `samples/hono/src/oidc-provider/apply.ts`
- `samples/express/src/oidc-provider/apply.ts`
- `samples/fastify/src/oidc-provider/apply.ts`
- `samples/nextjs/src/app/_oidc-provider/runtime.ts`
- 必要に応じて `samples/*/src/app.ts`

## 修正方針

- [ ] `ApplyOidcOptions.jwksProvider` は上書き用として維持する。
- [ ] `jwksProvider` 未指定時は、生成 Provider が保持している ID Token 署名鍵セットから JWKS を返す既定 provider をセットする。
- [ ] `idTokenSigningKeyProvider` が指定されている場合は、primary signing key ではなく ID Token 用の公開鍵セットを使う。
- [ ] `createApp()` 系のテンプレートでも同様に、単一の signing key set から既定 `jwksProvider` をセットする。
- [ ] `jwksProvider` の戻り値は `JwkSet` (`{ keys: [...] }`) とし、`kid`, `alg`, `use` を含む公開 JWK を返す。
- [ ] 既定 provider は request ごとに最新の registered ID Token signing keys を参照し、鍵ローテーション済み key set と矛盾しないようにする。
- [ ] 外部から `options.jwksProvider` が渡された場合はそれを優先する。
- [ ] `id_token_hint` は session の代替認証手段として扱わない。hint 検証に成功しても、現在の browser session が無い、または session subject と hint subject が一致しない場合は成功応答にしない。
- [ ] `prompt=none + id_token_hint` の成功条件を「hint が検証できること」と「既存 session が hint の subject と一致すること」に分けてテスト名・コメントで明示する。

## テスト要件

- [ ] `hono-generator.test.ts`: `jwksProvider` 未指定時にも `c.set('jwksProvider', ...)` されること。
- [ ] `hono-generator.test.ts`: `idTokenSigningKeyProvider` がある場合は ID Token key set を使うこと。
- [ ] `hono-generator.test.ts`: 明示 `options.jwksProvider` が既定 provider を上書きできること。
- [ ] sample の HTTP conformance test または E2E で、1回目に発行した ID Token を `prompt=none` の `id_token_hint` に指定して成功すること。
- [ ] browser session が無い状態では、有効な `id_token_hint` があっても `prompt=none` は `login_required` になること。
- [ ] browser session subject と `id_token_hint` subject が一致しない場合は、`prompt=none` が成功しないこと。
- [ ] `pnpm --filter @maronn-openid-connect/cli test` がパスすること。
- [ ] `pnpm run conformance:basic-op` の ZIP で `oidcc-id-token-hint` が pass すること。

## 完了条件

- 生成 Provider / samples の標準構成で `id_token_hint` が検証できる。
- `oidcc-id-token-hint` の `jwksProvider is not configured` エラーが消えている。
