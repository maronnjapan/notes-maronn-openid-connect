# [P2] GET エンドポイントへの HEAD リクエストを 405 にせず処理する（RFC 9110 §9.1）

## ステータス

🟡 Medium / 未着手

## 背景

CLI 生成 OP のメソッド強制ミドルウェアは、パスごとの許可メソッド許可リスト（`OIDC_ENDPOINT_METHODS`）で
メソッドを強制する。GET エンドポイント（Discovery / JWKS / UserInfo-GET）の許可リストは `'GET'` のみで
`HEAD` を含意しないため、`HEAD` リクエストが `405 Method Not Allowed` になる。

RFC 9110 §9.1 は「汎用サーバは GET と HEAD を必ずサポートしなければならない（MUST）」と定める。
HEAD は GET と同一処理でボディを返さないだけであり、GET を提供するリソースへの HEAD への 405 は不適切。
監視/ヘルスチェック/CDN のキャッシュ再検証は HEAD を使うことがあり（サンプルの想定デプロイ Workers/Vercel/Fly は
前段に CDN/プロキシが入りうる）、405 はこれらを壊す。

検討詳細は `study-material/done/http-head-method-on-get-endpoints.md` を参照。

> 関連：405 + `Allow` の横断方針は `tasks/done/p2-http-method-405-and-allow.md` / `study-material/done/http-method-enforcement-and-allow-header.md`（HEAD は🟢で明示的に先送りされていた）。
> `OPTIONS`（CORS プリフライト）は CORS ミドルウェアの責務で本タスクの対象外。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`（`OIDC_ENDPOINT_METHODS` / `enforceOidcEndpointMethod`）
- `packages/cli/src/frameworks/web-standard/templates.ts`（許可リスト方式の 405 送出箇所）
- 他フレームワーク（express / fastify / nextjs）テンプレートのメソッド強制実装（要棚卸し）
- 各 sample の `conformance.test.ts` を生成する `packages/cli` 側コード

## 仕様参照

- RFC 9110 §9.1: "All general-purpose servers MUST support the methods GET and HEAD."
- RFC 9110 §9.3.2: HEAD は GET と同一セマンティクス。サーバはレスポンスにコンテンツ（ボディ）を送ってはならない。
- RFC 9110 §15.5.6: 405 は「対象リソースがそのメソッドをサポートしない」場合に返す。GET 提供リソースは HEAD をサポートしているとみなされる。

## 現状の実装

```ts
// packages/cli/src/frameworks/hono/templates.ts:15-33
const OIDC_ENDPOINT_METHODS = {
  '/authorize': ['GET', 'POST'],
  '/token': ['POST'],
  '/userinfo': ['GET', 'POST'],
  '/.well-known/jwks.json': ['GET'],
  '/.well-known/openid-configuration': ['GET'],
  // ...
};
async function enforceOidcEndpointMethod(c, next) {
  const pathname = new URL(c.req.url).pathname;
  const allowed = OIDC_ENDPOINT_METHODS[pathname];
  if (allowed && !allowed.includes(c.req.method)) { // HEAD は 'GET' に含まれず 405
    c.header('Allow', allowed.join(', '));
    return c.body(null, 405);
  }
  await next();
}
```

web-standard も `templates.ts:260` で同様に許可リスト外を 405 にする。HEAD は許可リスト外。

## 修正方針

- [ ] 「許可リストに `GET` を含むパスは `HEAD` も許可」とする判定を `enforceOidcEndpointMethod`（相当）に入れる
- [ ] HEAD 通過後、レスポンスにボディを送らないことを保証する（RFC 9110 §9.3.2）。
  ランタイム/フレームワークが HEAD で自動的にボディを落とすか確認し、落とさないなら明示的に空ボディにする
- [ ] `Allow` ヘッダを返す既存挙動は維持（405 を返す本来の未サポートメソッドには従来通り `Allow`）
- [ ] 生成コードは直接編集せず `packages/cli` テンプレートを修正する
- [ ] 他フレームワークテンプレートのメソッド強制も同様に揃える

実装イメージ（判定部）:

```ts
const method = c.req.method;
const isHeadOnGet = method === 'HEAD' && allowed?.includes('GET');
if (allowed && !allowed.includes(method) && !isHeadOnGet) {
  c.header('Allow', allowed.join(', '));
  return c.body(null, 405);
}
```

## テスト要件

- [ ] （conformance / 生成 OP）Discovery（`/.well-known/openid-configuration`）への HEAD が 200 かつボディ空
- [ ] JWKS（`/.well-known/jwks.json`）への HEAD が 200 かつボディ空
- [ ] UserInfo(GET) への HEAD が 405 にならない（認可要件は別途）
- [ ] 本来未サポートのメソッド（例: Discovery への POST）は従来通り 405 + `Allow`（回帰固定）
- [ ] （任意）`tests/e2e` に Discovery/JWKS への HEAD が 200 になる E2E

## 完了条件

- 生成 OP のメソッド挙動を変えるため、`packages/cli` テンプレートと各 sample の `conformance.test.ts` を更新し、`pnpm test` がパスすること
- `study-material/done/http-method-enforcement-and-allow-header.md` の HEAD 先送り注記を解消済みに更新
