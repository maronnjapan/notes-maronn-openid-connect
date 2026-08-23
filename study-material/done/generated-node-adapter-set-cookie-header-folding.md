# 生成 Node アダプタが複数 `Set-Cookie` を 1 本にカンマ結合してしまう（潜在バグ）

## 1. このトピックで確認したいこと

CLI が生成する Node 用 HTTP アダプタ（express / fastify が使う `writeWebResponse`）は、Web 標準 `Response` のヘッダを `response.headers.forEach((value, name) => res.setHeader(name, value))` で書き戻す。`Headers.forEach`（および `.get`）は複数の `Set-Cookie` を**カンマ結合した 1 本の文字列**として返すため、Cookie を 2 つ以上設定すると不正な `Set-Cookie` ヘッダ（1 本にカンマ結合）になる。

現状は生成 OP のログインルートが Cookie を 1 個しか設定しないため顕在化しないが、利用者が生成コードをカスタマイズして 2 個目の Cookie（例: 別の CSRF Cookie、言語 Cookie）を足した瞬間に静かに壊れる。Next.js は `Response` をネイティブに返すため影響を受けず、**フレームワーク間で挙動が分岐**している。

本ファイルは、この Node アダプタの複数 `Set-Cookie` シリアライズの穴に限定する（Cookie 属性・セッション意味論は `study-material/http-security-headers-and-tls.md` / `study-material/done/cli-generated-provider-browser-session-and-sso.md` で扱い済み）。

## 2. 関連する仕様・基準

Cookie 属性・セッションの共通説明は上記 2 ファイルを参照し繰り返さない。

- **RFC 6265 §3（Overview / Set-Cookie）**: サーバは Cookie ごとに**独立した `Set-Cookie` ヘッダ**を送る。複数 Cookie を 1 本にカンマ結合するのは不正で、ブラウザは正しくパースできない（`Expires` の日付にカンマが含まれるため単純分割もできない）。
- **WHATWG Fetch（`Headers`）**: `Headers.prototype.getSetCookie()` が複数 `Set-Cookie` を配列で取り出す正しい API。`forEach` / `get('set-cookie')` はカンマ結合された 1 本を返す。
- **Node.js `ServerResponse.setHeader(name, value)`**: `value` に配列を渡すと複数ヘッダ行として出力できる。文字列 1 本を渡すと 1 行になる。

## 3. 参照資料

- RFC 6265 §3 / §4.1 Set-Cookie — https://www.rfc-editor.org/rfc/rfc6265#section-4.1
- WHATWG Fetch `Headers.getSetCookie()` — https://fetch.spec.whatwg.org/#dom-headers-getsetcookie
- Node.js `response.setHeader()`（配列で複数行） — https://nodejs.org/api/http.html#responsesetheadername-value
- 既存の関連記述（重複回避）: `study-material/http-security-headers-and-tls.md`、`study-material/done/cli-generated-provider-browser-session-and-sso.md`

## 4. 現在の実装確認

`packages/cli/src/frameworks/web-standard/templates.ts`（`writeWebResponse`）:

```ts
export async function writeWebResponse(outgoing: ServerResponse, response: Response): Promise<void> {
  outgoing.statusCode = response.status;
  response.headers.forEach((value, name) => {           // L323
    outgoing.setHeader(name, value);                    // L324: Set-Cookie もカンマ結合の1本になる
  });
  const body = Buffer.from(await response.arrayBuffer());
  outgoing.end(body);
}
```

- express / fastify の生成コードはこの `writeWebResponse` を経由する。
- 同様のパターンが sample サーバにも存在: `samples/hono/src/server.ts:53-63` 付近。
- Next.js は `Response` をそのまま返すため（Node アダプタを経由しない）この問題を受けない → フレームワーク間の分岐。
- 現状のログインルートは Cookie 1 個のみのため、実害は出ていない（潜在バグ）。

## 5. 現在の実装との差分

- **満たしていること**: 単一 Cookie のケースは正しく動作。通常ヘッダのコピーも正しい。
- **不足している可能性があること**: 複数 `Set-Cookie` を独立ヘッダで出力していない。`getSetCookie()` を使っていない。
- **セキュリティ上の観点**: 直接の脆弱性ではないが、Cookie が壊れると（例: セキュアな CSRF Cookie を追加したのに送られない）セキュリティ機能が静かに無効化される二次的リスク。
- **相互運用性の観点**: 利用者が生成コードに 2 個目の Cookie を足すと、ブラウザが受け取れず認証フローが壊れる。原因が「生成アダプタのヘッダ折り畳み」だと気付きにくい。
- **Basic OP として確認すべきこと**: 認定要件ではない。生成 OP の実装品質・拡張容易性の問題。

## 6. 改善・追加を検討する理由

- **なぜ検討するか**: 利用者が生成コードを改変して使う前提（本リポジトリのコンセプト）では、「2 個目の Cookie を足したら壊れる」落とし穴は拡張容易性を損なう。修正は小さい。
- **Basic OP 必須か拡張か**: 拡張（生成 OP の堅牢性・移植性）。
- **導入しやすさ**: `writeWebResponse` で `Set-Cookie` だけ `response.headers.getSetCookie()` で取り出し、`setHeader('Set-Cookie', array)` で配列渡しする分岐を足すだけ。生成コードの変更は `packages/cli` テンプレート側で行う。
- **既存実装との接続**: sample サーバの同型コード（`samples/hono/src/server.ts`）も同時に是正する（生成元がテンプレートなら再生成で揃う）。
- **実装しない場合のリスク**: フレームワーク間で Cookie 挙動が分岐したまま残り、express/fastify 利用者がカスタマイズ時に踏む。移植性（Portability）の主張に穴。

## 7. 実装方針の候補（判断材料）

最終判断は人間が行う。生成コードの変更は `packages/cli` テンプレートで行う。

- 方針A（`getSetCookie()` で分岐, 推奨）:
  ```ts
  const setCookies = response.headers.getSetCookie();
  if (setCookies.length > 0) outgoing.setHeader('Set-Cookie', setCookies);
  response.headers.forEach((value, name) => {
    if (name.toLowerCase() === 'set-cookie') return;   // 上で処理済み
    outgoing.setHeader(name, value);
  });
  ```
  Node 18+ の `getSetCookie()` を前提にする（本リポジトリの対応 Node バージョンを確認）。
- 方針B（`getSetCookie` 非対応環境の互換）: `getSetCookie` が無い場合のフォールバック（`response.headers` の raw 取得や undici の内部 API）を用意。互換の複雑さが増すため、対応 Node バージョン次第で不要と判断できる。
- どの方針でも、express/fastify/nextjs で「複数 Cookie が独立ヘッダで届く」ことを揃える。

## 8. タスク案

- [ ] 本リポジトリが要求する最小 Node バージョンを確認し、`Headers.getSetCookie()` を前提にできるか判定
- [ ] `packages/cli` の `writeWebResponse` テンプレート（および sample の同型コードの生成元）に `Set-Cookie` 分岐を追加（方針A）
- [ ] `tests/e2e`（Playwright）に「生成 OP が複数 Cookie を設定した際、ブラウザが両方受け取れる」検証を追加できるか検討（実ブラウザで検証可能なため CLAUDE.md の E2E 方針に合致）
- [ ] express / fastify 生成 OP を再生成し、複数 Cookie が独立ヘッダで出力されることを確認
- [ ] 完了条件: `pnpm test`（生成物検証 CI 含む）がパス

## 関連トピック

- `study-material/http-security-headers-and-tls.md` — Cookie 属性・TLS。本ファイルは複数 Cookie のシリアライズという別軸。
- `study-material/done/cli-generated-provider-browser-session-and-sso.md` — セッション Cookie の意味論。
- `study-material/cli-framework-portability-and-web-standard-handler.md` — Web 標準ハンドラの移植性。本ファイルはその Node アダプタの穴。
