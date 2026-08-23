# [P3] 生成 Node アダプタの複数 `Set-Cookie` カンマ結合を修正する

## ステータス

✅ 完了（2026-07-21）

複数 Cookie と単一 Cookie は、生成された Node アダプタを直接通す conformance 契約で固定した。
既定 OP は Cookie を 1 個だけ発行するため、2 個目を E2E 専用に追加すると生成 OP の標準挙動ではなく
テスト専用カスタマイズを検証することになる。このため Playwright への追加は見送り、HTTP 出力境界を
直接検証する契約テストを採用した。

## 背景

CLI が生成する Node 用 HTTP アダプタ（express / fastify が使う `writeWebResponse`）は、Web 標準 `Response` のヘッダを `response.headers.forEach((value, name) => res.setHeader(name, value))` で書き戻す。`Headers.forEach` は複数の `Set-Cookie` を**カンマ結合した 1 本**として返すため、Cookie を 2 つ以上設定すると不正な `Set-Cookie`（1 本にカンマ結合）になりブラウザがパースできない。現状はログインルートが Cookie 1 個のみで顕在化しないが、利用者が生成コードに 2 個目の Cookie を足した瞬間に静かに壊れる。Next.js は `Response` をネイティブに返すため影響を受けず、フレームワーク間で挙動が分岐している。

詳細な検討は `study-material/done/generated-node-adapter-set-cookie-header-folding.md` を参照。Cookie 属性・セッション意味論は `study-material/http-security-headers-and-tls.md` / `study-material/done/cli-generated-provider-browser-session-and-sso.md` で扱い済み。

## 対象ファイル

- `packages/cli/src/frameworks/web-standard/templates.ts`（`writeWebResponse`: L318-328 付近）
- `samples/hono/src/server.ts`（同型コード: L53-63 付近。生成元がテンプレートなら再生成で揃う）
- `tests/e2e`（複数 Cookie の実ブラウザ検証を追加できる場合）

## 仕様参照

- RFC 6265 §4.1（Cookie ごとに独立した `Set-Cookie`）: https://www.rfc-editor.org/rfc/rfc6265#section-4.1
- WHATWG Fetch `Headers.getSetCookie()`: https://fetch.spec.whatwg.org/#dom-headers-getsetcookie
- Node.js `response.setHeader(name, value)`（配列で複数ヘッダ行）: https://nodejs.org/api/http.html#responsesetheadername-value

## 現状の実装

```ts
// packages/cli/src/frameworks/web-standard/templates.ts
export async function writeWebResponse(outgoing: ServerResponse, response: Response): Promise<void> {
  outgoing.statusCode = response.status;
  response.headers.forEach((value, name) => {   // L323
    outgoing.setHeader(name, value);            // L324: Set-Cookie もカンマ結合の1本になる
  });
  const body = Buffer.from(await response.arrayBuffer());
  outgoing.end(body);
}
```

express / fastify の生成コードはこの `writeWebResponse` を経由する。

## 修正方針

- [ ] 本リポジトリが要求する最小 Node バージョンを確認し、`Headers.getSetCookie()`（Node 18+）を前提にできるか判定
- [ ] `writeWebResponse` で `Set-Cookie` を `getSetCookie()` の配列として別扱いする（study-material 方針A）
  ```ts
  const setCookies = response.headers.getSetCookie();
  if (setCookies.length > 0) outgoing.setHeader('Set-Cookie', setCookies);
  response.headers.forEach((value, name) => {
    if (name.toLowerCase() === 'set-cookie') return;   // 上で処理済み
    outgoing.setHeader(name, value);
  });
  ```
- [ ] sample の同型コード（`samples/hono/src/server.ts`）の生成元を同時に是正（再生成で揃える）

## テスト要件

- [ ] 生成 OP が複数 `Set-Cookie` を設定した際、独立ヘッダとして出力される（カンマ結合されない）
- [ ] 単一 Cookie のケースがリグレッションしない
- [ ] `tests/e2e`（Playwright）で「生成 OP が複数 Cookie を設定 → ブラウザが両方受け取れる」検証を追加できるか検討（CLAUDE.md の E2E 方針に合致）
- [ ] express / fastify 生成 OP を再生成し複数 Cookie が独立ヘッダで出力されることを確認

## 完了条件

- `pnpm test`（生成物検証 CI を含む）がパスすること
