# [P2] Discovery エンドポイントに `Cache-Control` ヘッダを追加する

## ステータス

🟡 Medium / 未着手

## 背景

`/.well-known/openid-configuration` を返す Discovery エンドポイントが HTTP キャッシュヘッダを返していない。
一方で JWKS エンドポイント（`/.well-known/jwks.json`）は既に `Cache-Control: public, max-age=3600` を設定済みであり、両者の挙動が非対称になっている。

クライアントライブラリ（`openid-client`、`oidc-client-ts` 等）は Discovery メタデータをキャッシュして使い回すが、サーバ側がキャッシュヘッダを出さないとライブラリのキャッシュ戦略がライブラリ依存になり、メタデータ更新時の伝播が予測できない。

詳細は `study-material/done/discovery-cache-control-and-etag.md` 参照。

## 対象ファイル

- `packages/sample/src/oidc-provider/routes/discovery.ts`
- `packages/cli/src/frameworks/hono/templates.ts`（Discovery テンプレート）
- 関連するテスト（discovery / generator）

## 仕様参照

- OpenID Connect Discovery 1.0 §4 — Provider Configuration Response（`Content-Type: application/json` MUST。キャッシュは規定無し）
- RFC 8414 §3.2 — メタデータの取得とキャッシュ可能性（クライアントはキャッシュしてよい）
- RFC 9111 (HTTP Caching) §5.2 — `Cache-Control` フィールド
- 本リポジトリ内: `packages/sample/src/oidc-provider/routes/jwks.ts:90`（JWKS が既に `Cache-Control: public, max-age=3600` を設定している既存ファクト）
- 本リポジトリ内: `study-material/jwks-endpoint-comprehensive.md` §3.4（JWKS のキャッシュ運用方針）

## 現状の実装

```ts
// packages/sample/src/oidc-provider/routes/discovery.ts (末尾)
return c.json({
  ...metadata,
  code_challenge_methods_supported: ['S256'],
});
```

HTTP レスポンスヘッダに `Cache-Control` / `ETag` / `Last-Modified` のいずれも設定していない。

## 修正方針

方針 A（最小実装、`study-material/done/discovery-cache-control-and-etag.md` §7-A）を採用する想定:

- [ ] `routes/discovery.ts` の `return c.json(...)` の直前に `c.header('Cache-Control', 'public, max-age=3600')` を追加する。
- [ ] `packages/cli/src/frameworks/hono/templates.ts` の Discovery テンプレートにも同じヘッダを追加する。
- [ ] `max-age` 値は JWKS（`packages/sample/src/oidc-provider/routes/jwks.ts:90`）と同じ `3600` 秒で揃える（対称性の確保）。
- [ ] `ETag` / `Last-Modified` は本タスクでは扱わない（方針 C/D は別タスクで切り出す）。

実装例:

```ts
c.header('Cache-Control', 'public, max-age=3600');
return c.json({
  ...metadata,
  code_challenge_methods_supported: ['S256'],
});
```

## テスト要件

- [ ] sample 統合テスト（または discovery ルートの単体テスト）で「Discovery レスポンスの `Cache-Control` ヘッダが `public, max-age=3600` を含む」アサーションを追加する。
- [ ] CLI generator テスト（`hono-generator.test.ts`）で生成された Discovery テンプレートに `Cache-Control` ヘッダの行が含まれることを assert する。
- [ ] レスポンスボディが既存テストと変わらないこと（後方互換）を確認する。

## 完了条件

- `pnpm --filter @maronn-openid-connect/sample test` がパスする（sample テストがある場合）。
- `pnpm --filter @maronn-openid-connect/cli test` がパスする。
- `curl -i http://localhost:<port>/.well-known/openid-configuration` のレスポンスヘッダに `Cache-Control: public, max-age=3600` が含まれることを目視確認する。

## 補足

- 方針 B（`ProviderConfig.discoveryCacheMaxAgeSeconds` で設定可能化）は別タスクとして切り出す。
- 方針 C（`ETag` 対応）は別タスクとして切り出す。
- 鍵ローテーション時の `max-age` 動的短縮は `study-material/signing-key-rotation-operations.md` 側で扱う。
