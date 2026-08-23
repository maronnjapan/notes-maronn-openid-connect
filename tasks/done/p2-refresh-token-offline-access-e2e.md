# [P2] `offline_access` refresh token flow を Playwright E2E で固定する

## ステータス

✅ 完了（2026-07-21）

## 背景

生成 Discovery の `scopes_supported` には `offline_access` が入り、sample の `conformance.test.ts` では `scope=openid offline_access&prompt=consent` を使った refresh token 発行・再利用カスケードを検証済み。

一方、`tests/e2e` の実ブラウザフローは通常の Authorization Code Flow に留まっており、`offline_access` を要求した場合の refresh token 発行と、要求しない場合に refresh token が出ないことはまだ固定していない。

## 対象ファイル

- `tests/e2e/specs/*.spec.ts`
- `tests/e2e/apps/client.mjs`
- 必要に応じて `tests/e2e/apps/resource-server.mjs`

E2E で使う OpenID Provider は `samples/*` 配下の CLI 生成アプリを対象にし、E2E 専用クライアントやリソースサーバーは `tests/e2e/apps` に置く。

## 修正方針

- [ ] `scope=openid offline_access` と `prompt=consent` の実ブラウザ Authorization Code Flow で token response に `refresh_token` が含まれることを確認する。
- [ ] 取得した refresh token で refresh token grant が成功し、新しい access token と必要に応じた ID Token を返すことを確認する。
- [ ] `offline_access` を要求しない通常 flow では token response に `refresh_token` が含まれないことを確認する。
- [ ] 他 client の refresh token を使った場合に `invalid_grant` になることを確認する。
- [ ] E2E client 側の UI / callback 表示は、テストが必要な token response 値だけを安定して参照できるようにする。

## テスト要件

- [ ] Playwright E2E で `offline_access` ありの refresh token 発行が通ること。
- [ ] refresh token grant で新しい access token が返ること。
- [ ] `offline_access` なしでは refresh token が返らないこと。
- [ ] refresh token の client binding が破られないこと。
- [ ] `pnpm --filter @maronn-openid-connect/e2e test` または既存の E2E 実行コマンドがパスすること。

## 完了条件

`offline_access` の Discovery 広告から refresh token 発行・利用までが、実ブラウザと実 HTTP フローで回帰固定されていること。
