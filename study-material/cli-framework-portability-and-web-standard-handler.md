# CLI ジェネレータのフレームワーク・ポータビリティ（Web 標準 `Request`/`Response` ハンドラ生成の検討）

## ステータス

🟢 **実質的に解決済み（要記述追随）**

> **現状注記（重要）**
> 本ファイルの初版は「CLI が Hono 1 種類しか出力できない」状態を前提に、Web 標準ハンドラを追加すべきかを論じたものである。
> その後 **方針 A + B に相当する実装が既に入っており**、記述は現状と食い違っている。現状は次のとおり:
>
> - 登録済みジェネレータは **hono / express / fastify / nextjs の 4 種類**（`packages/cli/src/frameworks/index.ts`）
> - express / fastify / nextjs は共通の `web-standard` ジェネレータへ委譲し、Fetch Standard の `Request` / `Response` だけに依存する `WebRouter` / `WebContext` ランタイム（`web-router.ts`）を生成する
> - ルートロジックは Hono テンプレート 1 系統に集約され、`toWebRouteTemplate()` の文字列変換で Web 標準版へ派生している
> - `samples/` にも `hono-cloudflare` / `express-flyio` / `fastify-flyio` / `nextjs-vercel` の 4 つが存在する
>
> したがって本ファイルの §5「現在の実装確認」以降は歴史的記録として読むこと。
> **派生方式そのものの契約と回帰ガード**という後継の論点は
> `study-material/done/cli-web-standard-template-derivation-contract.md` が扱う。

## 1. このトピックで確認したいこと

CLAUDE.md が掲げる差別化軸「**Portability: Web 標準 API のみ使用し、JavaScript が動く環境ならどこでも動く**」に対し、**CLI コードジェネレータが現状 Hono フレームワーク 1 種類しか出力できない**点を確認し、ポータビリティ/拡張性を高めるために何を追加検討すべきかを整理する。

core ライブラリ自体は Web 標準 API（Web Crypto / `URLSearchParams` / `Request` 等）のみで実装されており移植性が高い。一方、**利用者の入口である生成コードは Hono に固定**されているため、「どこでも動く」という主張と生成物の実態の間に差分がある。

## 2. 関連する仕様・基準

これは特定の OIDC/OAuth 仕様要件ではなく、**プロジェクトの設計方針（Portability 軸）と拡張性**に関するトピックである。関連する技術基準は以下:

- **WHATWG Fetch Standard**（`Request` / `Response` / `Headers`）— 多くの JS ランタイム（Cloudflare Workers / Deno / Bun / Node 18+ の `fetch`/`undici` / Vercel Edge 等）が共通でサポートする HTTP インターフェース。フレームワーク非依存の「`(request: Request) => Promise<Response>`」ハンドラはこれらすべてで動く。
- **OAuth 2.1 / OIDC Core のトランスポート要件**: エンドポイントは HTTP で公開され、`application/x-www-form-urlencoded` リクエストや `application/json` レスポンス、`Cache-Control: no-store`、`WWW-Authenticate` 等のヘッダ制御が必要。これらはフレームワークに依存せず Web 標準 `Request`/`Response` で表現可能（HTTP レイヤ要件の詳細は `study-material/http-security-headers-and-tls.md` および各エンドポイント包括レビューを参照）。

> Hono 自体が複数ランタイムで動くため「Hono を選べばある程度ポータブル」ではあるが、**Hono への依存を強制すること自体**が「フレームワークを問わない」という主張とは別物である点が論点。

## 3. 参照資料

- WHATWG Fetch Standard — https://fetch.spec.whatwg.org/ （`Request`/`Response`/`Headers` の標準）
- Hono — https://hono.dev/ （現状唯一の生成ターゲット。マルチランタイム対応の根拠）
- 本リポジトリ `CLAUDE.md`「差別化の3軸 / Portability」および「利用者の入口」セクション
- 本リポジトリ `packages/cli/src/frameworks/types.ts`（`FrameworkGenerator` 抽象。拡張点の根拠）

## 4. （上に統合）

## 5. 現在の実装確認

- ジェネレータは **フレームワーク抽象 `FrameworkGenerator`** を持つ: `packages/cli/src/frameworks/types.ts`（`generate(options): GeneratedFile[]`）。
- 登録されているジェネレータは **Hono のみ**: `packages/cli/src/frameworks/index.ts` で `registerGenerator(new HonoGenerator())` の 1 件だけ。`getAvailableFrameworks()` は `['hono']` を返す。
- 実体は `packages/cli/src/frameworks/hono/`（`index.ts` / `templates.ts`）。生成コードは `import { Hono } from 'hono'` に依存し、ルーティング・`c.req` / `c.json` / `c.header` 等 Hono のコンテキスト API を直接使用している。
- core 側は Web 標準のみ（`checkPromptNone` 等が `Request`（`c.req.raw`）を受ける設計など、すでに Web 標準 `Request` 受け渡しの素地はある）。

## 6. 現在の実装との差分

満たしていること:
- `FrameworkGenerator` 抽象により、**新しいフレームワーク生成器を追加できる拡張点は既に用意されている**（実装は未追加）。
- core は Web 標準のみで、フレームワーク非依存ハンドラを書く土台がある。

不足している可能性があること:
- 🟠 **生成ターゲットが Hono 1 種類**。Express / Fastify / Node 標準 `http` / Deno `serve` / Bun.serve 等を使いたい利用者は、生成コードをまるごと書き換える必要がある。
- 🟠 **フレームワーク非依存の「Web 標準ハンドラ」生成がない**。`(request: Request) => Promise<Response>` を返すコア・ルータを生成できれば、各ランタイムへの薄いアダプタだけで「どこでも動く」を実証できる。
- 🟢 **`getAvailableFrameworks()` が 1 件のみ**で、CLI のフレームワーク選択 UX が実質固定。

相互運用性・拡張性の観点:
- ポータビリティ軸を「実証可能」にするには、最低 1 つは **フレームワーク非依存ターゲット**があると説得力が高い。

## 7. 改善・追加を検討する理由

- **Portability 軸の実証**: 「Web 標準だけでどこでも動く」を、生成コードのレベルで示せる。core が Web 標準でも、利用者が触る生成物が単一フレームワーク固定だと主張が弱い。
- **拡張性（本タスクの観点の一つ）**: `FrameworkGenerator` 抽象が既にあるため、追加コストは比較的低い。共通のロジック（ルート定義・バリデーション呼び出し）を Web 標準ハンドラに集約し、フレームワーク別ジェネレータは薄いアダプタにできれば、テンプレート重複（現状 Hono テンプレートは 2200 行超）も削減できる。
- **利用者メリット**: 既存スタック（Express/Fastify/Edge Functions 等）にそのまま載せたい PoC 開発者の参入障壁が下がる。
- **導入しにくさ（正直な評価）**: 現状の Hono テンプレートはコンテキスト API（`c.*`）に密結合しており、Web 標準ハンドラへリファクタするには **テンプレートの再設計**が必要。短期的には実装コストが小さくない。
- **実装しない場合のリスク**: 「どこでも動く」という主張と生成物の実態の乖離が残る。Hono を採用できない利用者を取りこぼす。

## 8. 実装方針の候補

最終判断は人間が行う前提で、判断材料を整理する。

- **A 案: Web 標準ハンドラ・ジェネレータを追加**
  - `(request: Request, deps) => Promise<Response>` を返す各エンドポイント関数を生成し、ランタイム別の最小エントリ（Workers `export default { fetch }` / Deno `Deno.serve` / Bun.serve / Node `createServer` アダプタ）を別ファイルで出力。
  - 既存 Hono ジェネレータはこの Web 標準ハンドラを内部利用する薄いラッパに再構成（重複削減）。
- **B 案: 追加フレームワーク・ジェネレータを個別実装**
  - `ExpressGenerator` / `FastifyGenerator` 等を `FrameworkGenerator` として追加。ロジックは共通モジュールへ抽出。Web 標準化はしないが対応フレームワークを増やす。
- **C 案: 現状維持 + ドキュメント**
  - Hono のみとし、「Hono は Workers/Deno/Bun/Node で動くので実用上ポータブル」と README で明示。他フレームワークは利用者責務。

検討ポイント（人間判断）:
- どこまでを「Speed（最新仕様への追随）」より優先するか。生成器が増えると、新仕様追加時に全ターゲットを更新するコストが乗る（Speed 軸とトレードオフ）。
- 第一候補ターゲット（Web 標準ハンドラ vs Express など具体フレームワーク）の選定。
- テンプレートの共通化リファクタ（2200 行超の Hono テンプレートの分割）を同時に行うか。

## 9. タスク案

初版のタスク案（方針 A/B の実装）は**すべて実施済み**である。

- [x] 第一候補ターゲットを選定し、`FrameworkGenerator` 実装を追加する → express / fastify / nextjs の 3 つを追加済み
- [x] 共通ロジックを Web 標準ハンドラへ抽出する → `web-standard` ジェネレータと `WebRouter` / `WebContext` ランタイムとして実現済み（ただし Hono テンプレートを正とし、そこから派生する形。Hono を薄いアダプタへ再構成する形にはなっていない）
- [x] 生成物が対象ランタイムで起動する検証 → `samples/express-flyio` / `samples/fastify-flyio` / `samples/nextjs-vercel` の `conformance.test.ts` および `tests/conformance` の Suite 実行（`CONFORMANCE_SAMPLE_APP` で切替）でカバー

残る論点は本ファイルの範囲を出ており、後継ファイルへ引き継ぐ:

- 派生方式（Hono テンプレートからの文字列変換）の契約と回帰ガード → `study-material/done/cli-web-standard-template-derivation-contract.md`
- 生成物と `samples/*` の一致を CI で保証すること → `study-material/done/cli-generated-output-conformance-ci.md`

本ファイル自体に対して残っている作業:

- [ ] §5「現在の実装確認」以降の本文を現状（4 ジェネレータ + web-standard 共通ランタイム）に合わせて書き直すか、歴史的記録として `study-material/done/` へ移すかを決める
