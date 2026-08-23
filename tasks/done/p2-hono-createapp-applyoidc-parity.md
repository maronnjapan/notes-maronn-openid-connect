# [P2] Hono の `createApp` を `applyOidc` とパリティにし、conformance.test が実デプロイ経路を検証するようにする

## ステータス

✅ 完了（2026-07-21）

## 背景

Hono テンプレートには OP 組み立ての 2 系統がある。`createApp`（`app.ts` のスタンドアロン経路）と
`applyOidc`（既存アプリへの後付け経路）。`applyOidc` は `acrResolver` / `corsOrigins`（CORS + OPTIONS）/
分離署名鍵プロバイダをサポートするが、`createApp` はこれらを**オプションで受け付けず、コンテキストに set しない**。
そのため `createApp` 経由の OP は `acr_values` を honor できず（ID Token に `acr` が載らない）、
CORS/OPTIONS も無いためブラウザ／SPA から token/userinfo を呼べない。

さらに Hono の `conformance.test.ts` は機能不足側の `createApp` を検証しており、実 `samples/hono` が使うのは
機能の揃った `applyOidc`。つまり契約テストが「実デプロイと異なる経路」を認証し、ACR/CORS を一切アサートしていない。
web-standard は単一の `createApp` で acr/CORS を wiring 済みで、Hono だけが非対称。
検討詳細は `study-material/done/hono-createapp-applyoidc-parity-and-conformance-path.md` を参照。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`
  - `CreateAppOptions` / `createApp`（`acrResolver` / `corsOrigins` / 分離署名鍵プロバイダの欠落）
  - `conformance.test.ts` 生成部（`createApp` を駆動し ACR/CORS を未アサート）
- `samples/hono`（再生成対象）
- 参考: `packages/cli/src/frameworks/web-standard/templates.ts`（単一 createApp で acr/CORS を wiring 済み）

## 仕様参照

- OpenID Connect Core 1.0 §3.1.2.1 / §2（`acr_values` / `acr`）。OIDF `oidcc-ensure-request-with-acr-values-succeeds`
- OAuth 2.0 for Browser-Based Apps（SPA からの token/userinfo 呼び出しに CORS/OPTIONS が必要）
- 本リポジトリ CLAUDE.md「conformance.test.ts は実際のリクエスト挙動を全網羅し、生成元（packages/cli）を変更する」

## 現状の実装

```ts
// packages/cli/src/frameworks/hono/templates.ts
export interface CreateAppOptions { /* acrResolver / corsOrigins が無い */ }

export function createApp(options: CreateAppOptions) {
  app.use('*', async (c, next) => {
    // c.set('acrResolver', ...) を呼ばない / cors() も OPTIONS も無い
    ...
  });
}

// token ルートは c.get('acrResolver') を読むが createApp 経路では常に undefined
const acrResolver = c.get('acrResolver'); // undefined

// applyOidc（別経路）は acrResolver / corsOrigins を受け付け wiring する
```

## 修正方針

- [ ] 方針A: Hono `createApp` に `acrResolver` / `corsOrigins`（CORS + OPTIONS プリフライト）/
  分離署名鍵プロバイダを追加し、web-standard の createApp や applyOidc と機能を揃える。
  - もしくは 方針B: `createApp` を `applyOidc` の薄いラッパとして再実装し、二重メンテを解消する
- [ ] `conformance.test.ts`（生成元）が実デプロイ経路（`applyOidc` 相当の機能を持つ経路）を検証するようにする
- [ ] 他フレームワーク（express / fastify / nextjs）の createApp 相当が acr/CORS を wiring しているか横断確認し、
  同様の乖離があれば併せて是正する

## テスト要件

- [ ] Hono conformance で `acr_values` 要求時に ID Token へ `acr` が載ること（acrResolver 経由）
- [ ] Hono conformance で token/userinfo の OPTIONS プリフライトに `Access-Control-Allow-Origin` が返ること
- [ ] `createApp` と `applyOidc` の機能差が無い（同じ入力で同じ ACR/CORS 挙動）ことを確認するテスト
- [ ] `samples/hono` を再生成し、既存の conformance テストが更新後の挙動でパスすること

## 完了条件

- `pnpm --filter @maronn-openid-connect/cli test` がパスすること
- 再生成した `samples/hono` の `conformance.test.ts` がパスすること
