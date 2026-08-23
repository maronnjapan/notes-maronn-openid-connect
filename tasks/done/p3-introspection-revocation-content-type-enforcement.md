# [P3] Introspection / Revocation エンドポイントに Content-Type 検証を追加し Token Endpoint とパリティを取る

## ステータス

✅ 完了（2026-07-21）

## 背景

Token Endpoint のルートテンプレートは、リクエストボディの `Content-Type` が
`application/x-www-form-urlencoded` であることを `isFormUrlEncoded` で検証してからパースしている。
一方で Introspection（RFC 7662）と Revocation（RFC 7009）のルートテンプレートは
**Content-Type を検証せず、いきなり `c.req.parseBody()` を呼んでいる**。

RFC 7662 §2.1 / RFC 7009 §2.1 はいずれもリクエストボディを `application/x-www-form-urlencoded` と規定する。
Token Endpoint だけ厳格で Introspection / Revocation が緩いという非対称は、非 form ペイロード
（`application/json` 等）を黙ってパースに通し、`token` 欠如等へフォールバックするため、クライアント側の
バグを観測しにくくする。エンドポイント間パリティ（Fidelity）の品質課題。

詳細な検討は `study-material/done/introspection-revocation-content-type-enforcement.md` を参照。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`
  - `introspectionRouteTemplate`
  - `revocationRouteTemplate`
  - （`tokenRouteTemplate` の `isFormUrlEncoded` を共通化する場合はその切り出し）
- 該当 sample の `conformance.test.ts` 生成元（`packages/cli` 内のテスト生成コード）

## 仕様参照

- RFC 7662 §2.1「Introspection Request」: ボディは `application/x-www-form-urlencoded`
- RFC 7009 §2.1「Revocation Request」: ボディは `application/x-www-form-urlencoded`
- RFC 9110 §8.3.1: メディアタイプは大文字小文字非依存（`; charset=...` パラメータを含みうる）
- 既存方針: `tokenRouteTemplate` の `isFormUrlEncoded`（RFC 6749 §4.1.3 / OIDC Core §3.1.3.1 を根拠に採用済み）

## 現状の実装

```ts
// packages/cli/src/frameworks/hono/templates.ts（introspectionRouteTemplate）
introspectionApp.post('/', async (c) => {
  const body = await c.req.parseBody();   // ← Content-Type 未検証でパース
  ...
});

// revocationRouteTemplate も同様
revocationApp.post('/', async (c) => {
  const body = await c.req.parseBody();   // ← Content-Type 未検証でパース
  ...
});
```

対して Token Endpoint は冒頭で `isFormUrlEncoded(c.req.header('Content-Type'))` を検証している。

## 修正方針

- [ ] `isFormUrlEncoded` 相当の判定を introspection / revocation のハンドラ冒頭（`parseBody()` 前）に追加する
- [ ] 共通化できる場合は `isFormUrlEncoded` を 1 箇所に定義して 3 テンプレートで再利用する（重複回避）
- [ ] 非 form Content-Type の場合は `400` + `{ error: 'invalid_request', error_description: ... }` を返し、
  `Cache-Control: no-store` / `Pragma: no-cache` を付与する（Token Endpoint と同一スタイル）
- [ ] web-standard / 各フレームワーク生成物にも反映されることを確認する

```ts
// 例（introspection / revocation 共通の冒頭ガード）
const contentType = c.req.header('Content-Type') ?? '';
if (!isFormUrlEncoded(contentType)) {
  c.header('Cache-Control', 'no-store');
  c.header('Pragma', 'no-cache');
  return c.json({ error: 'invalid_request', error_description: 'Content-Type must be application/x-www-form-urlencoded' }, 400);
}
```

## テスト要件

- [ ] Introspection に `application/json` ボディを送ると `400 invalid_request` になること
- [ ] Revocation に `application/json` ボディを送ると `400 invalid_request` になること
- [ ] `application/x-www-form-urlencoded`（`; charset=UTF-8` 付き含む）では従来どおり処理されること
- [ ] 大文字小文字違いの Content-Type（例 `Application/X-WWW-Form-Urlencoded`）でも受理されること
- [ ] 該当 sample の `conformance.test.ts`（生成元を更新）に上記ケースを反映すること

## 完了条件

- `pnpm --filter @maronn-openid-connect/cli test` がパスすること
- 生成された `samples/*` の `conformance.test.ts` が更新後の挙動でパスすること
