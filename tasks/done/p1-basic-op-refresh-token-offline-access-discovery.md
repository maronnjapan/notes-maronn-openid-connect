# [P1] Basic OP refresh token module のため `offline_access` を Discovery と発行条件に通す

## ステータス

🟢 High / Discovery 広告＋契約テスト実装済み（E2E refresh フローテストは別タスクへ繰り越し）

## 背景

`tests/conformance` の直近実行で `oidcc-refresh-token` が skipped になっている。

対象結果:

- `tests/conformance/results/oidcc-basic-certification-test-plan-discovery-static_client-5XeV397bGW050-17-Jun-2026.zip`
- module: `oidcc-refresh-token`
- result: `SKIPPED`
- 直接原因:
  - Discovery の `scopes_supported` に `offline_access` が無い
  - Conformance Suite が `scope=openid` のみで認可を実行する
  - Token Endpoint response に refresh token が含まれない

Conformance Suite は Discovery に `offline_access` が広告されている場合だけ `scope=openid offline_access` と `prompt=consent` を付ける。現在の static client artifact は `grantTypes: ["authorization_code", "refresh_token"]` と `offlineAccessAllowed: true` を持つが、Discovery が `offline_access` を広告していないため refresh token module が実行対象になっていない。

## 調査根拠

- OIDC Core 1.0 §11: `offline_access` scope は refresh token 発行を要求するための scope で、通常は `prompt=consent` が必要。
- OIDC Core 1.0 §12: refresh token grant の振る舞いを定義している。
- OIDF Conformance Suite `OIDCCRefreshToken`: Discovery の `scopes_supported` に `offline_access` がある場合に要求 scope へ追加し、refresh token が返らない場合は skipped にする。
- 現行 Discovery: `scopes_supported` は `["openid", "profile", "email", "address", "phone"]` で、`offline_access` が無い。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`
- `packages/cli/src/frameworks/web-standard/templates.ts`
- `packages/cli/src/__tests__/hono-generator.test.ts`
- `packages/cli/src/__tests__/web-framework-generators.test.ts`
- `tests/conformance/scripts/create-basic-op-config.mjs`
- `tests/conformance/scripts/create-basic-op-config.test.mjs`
- `samples/hono/src/oidc-provider/routes/discovery.ts`
- `samples/express/src/oidc-provider/routes/discovery.ts`
- `samples/fastify/src/oidc-provider/routes/discovery.ts`
- `samples/nextjs/src/app/_oidc-provider/routes/discovery.ts`
- 必要に応じて `packages/core/src/discovery.ts` / `tasks/T-021-discovery-metadata.md`

## 修正方針

- [x] 生成 Discovery の `scopesSupported` に `offline_access` を追加する。
- [x] `claims_supported` は `offline_access` に対応する claim を追加しない。`offline_access` は claim scope ではなく refresh token 要求用 scope として扱う。
- [x] Conformance static clients は既存どおり `grantTypes: ["authorization_code", "refresh_token"]` と `offlineAccessAllowed: true` を維持する。
- [ ] `validateAuthorizationRequest` の既存ロジックどおり、`offline_access` は `prompt=consent` がある場合だけ残す。
- [ ] Token route で `validatedRequest.scope.includes("offline_access")` のとき refresh token が発行されることを確認する。
- [ ] 通常 sample / E2E で `offline_access` を要求しない場合は refresh token を発行しない挙動を維持する。
- [ ] 逆に `scope=openid offline_access` と `prompt=consent` を要求する場合は、E2E と各 sample の `conformance.test.ts` で refresh token が発行されることを担保する。
- [ ] `T-021-discovery-metadata.md` と重複する Discovery 追加項目は、本タスク完了時に状態を更新する。

## テスト要件

- [ ] CLI generator test: Discovery template の `scopesSupported` に `offline_access` が含まれること。
- [ ] `create-basic-op-config.test.mjs`: static clients が refresh token grant と `offlineAccessAllowed: true` を持つことを維持する。
- [ ] 各 sample の `conformance.test.ts`: `scope=openid offline_access&prompt=consent` の authorization code flow で token response に `refresh_token` が含まれること。
- [ ] `tests/e2e`: `scope=openid offline_access&prompt=consent` の実ブラウザ authorization code flow で token response に `refresh_token` が含まれること。
- [ ] `tests/e2e`: `offline_access` を要求しない通常 authorization code flow では token response に `refresh_token` が含まれないこと。
- [ ] refresh token grant が成功し、新しい access token と必要に応じた ID Token を返すこと。
- [ ] 他 client の refresh token を使った場合に `invalid_grant` になること。
- [ ] `pnpm --filter @maronn-openid-connect/cli test` がパスすること。
- [ ] `pnpm run conformance:basic-op` の ZIP で `oidcc-refresh-token` が skipped ではなく pass すること。

## 完了条件

- Discovery が `offline_access` を広告する。
- `oidcc-refresh-token` が実行され、refresh token 発行・使用・client binding 検証まで pass する。
