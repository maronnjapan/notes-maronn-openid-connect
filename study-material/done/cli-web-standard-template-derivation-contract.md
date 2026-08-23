# Express / Fastify / Next.js 生成コードが Hono テンプレートの文字列置換で作られている契約と、その回帰ガード

## ステータス

🟡 Medium（保守性 / Portability の裏付け）/ 未着手

## 1. このトピックで確認したいこと

CLI は 4 つのフレームワーク（hono / express / fastify / nextjs）向けに OP を生成する。しかし **ルートのテンプレート実体は Hono 用の 1 系統しか存在しない**。express / fastify / nextjs は `web-standard` ジェネレータへ委譲し、`web-standard` は Hono テンプレートの出力文字列に対して次の変換を掛けて再利用している。

```ts
function toWebRouteTemplate(content: string): string {
  return content
    .replace("import { Hono } from 'hono';", "import { WebRouter } from '../web-router.js';")
    .replaceAll('new Hono<{ Variables: Record<string, any> }>()', 'new WebRouter()');
}
```

この設計は「1 か所を直せば 5 ターゲットに反映される」という利点があり、実際に PAR / Token Exchange / JARM の実装記録（`tasks/experimental/done/*/specification.md`）はそれを実装コスト削減の根拠として明示的に挙げている。

一方で、**変換が前提とする文字列が失われても、`String.prototype.replace` は例外を投げずに元の文字列を返す**。すなわち変換の失敗は静かに起きる。確認したいのは次の 3 点である。

- 変換前提が壊れたとき、どこで検知されるか（検知されないルートはどれか）
- `WebContext` / `WebRouter` が再実装している Hono の API 表面は、どこまで一致していて、どこから乖離するか
- 「Web 標準だけでどこでも動く」という Portability 軸の主張を、テストで裏付けられているか

### 既存ファイルとの関係（重複回避）

| 論点 | 扱っているファイル |
|---|---|
| Hono 以外のターゲットを持つべきか（Portability 軸の是非） | `study-material/cli-framework-portability-and-web-standard-handler.md` |
| `applyOidc` / `createApp` の 2 経路の等価性と conformance 経路 | `study-material/done/hono-createapp-applyoidc-parity-and-conformance-path.md` |
| 生成コードのエントリ配線がプレースホルダ文字列置換であること・その静的失敗検知 | `study-material/done/cli-setup-entry-placeholder-silent-noop.md`、`tasks/done/p1-cli-setup-placeholder-detection-and-failure.md` |
| 生成物を再生成したとき既存の改造を壊さないための上書きガード | `study-material/done/cli-generated-code-overwrite-safety-and-upgrade-path.md`、`tasks/p2-cli-generate-overwrite-guard.md` |
| 生成物と `samples/*` の一致を CI で保証する | `study-material/done/cli-generated-output-conformance-ci.md` |
| Node アダプタの `Set-Cookie` ヘッダ畳み込み | `study-material/done/generated-node-adapter-set-cookie-header-folding.md` |

**本ファイル固有の差分**は「**ルートテンプレートそのものの派生方式**（Hono → Web 標準の文字列変換）が持つ契約と、その回帰ガードの網羅性」である。
`done/cli-setup-entry-placeholder-silent-noop.md` は**エントリファイルへの配線**のプレースホルダ置換を扱っており、対象が異なる（あちらは利用者プロジェクトのファイル、こちらは CLI 内部のテンプレート派生）。ただし「置換が静かに no-op になる」という失敗の形は同型であり、そこで採られた解決（置換前に前提の存在を検証して失敗させる）は本トピックにも応用できる。

`study-material/cli-framework-portability-and-web-standard-handler.md` は「Hono 1 種類しか出せない」という**当時の**状態を前提に「Web 標準ターゲットを追加すべきか」を論じている。その提案は既に実現済み（本ファイルの §4 参照）であり、記述内容は現状と食い違っている。本ファイルは実現後の運用上の論点を扱う（当該ファイルの現状記述は別途更新が必要）。

## 2. 関連する仕様・基準

OIDC / OAuth の条文に直接対応する論点ではない。関連するのは次の 2 つ。

### 2.1 WHATWG Fetch Standard（`Request` / `Response` / `Headers`）

`WebRouter` / `WebContext` は `Request` を受けて `Response` を返す薄いルータであり、Fetch Standard の型だけに依存する。Cloudflare Workers / Deno / Bun / Node 18+ / Vercel Edge のいずれでも動く前提はここに由来する。

- https://fetch.spec.whatwg.org/

### 2.2 本リポジトリの設計方針（CLAUDE.md）

- 「**Portability**: Web 標準 API のみ使用し、JavaScript が動く環境ならどこでも動く」
- 「`samples/*/src/oidc-provider` については、`packages/cli` によるコード生成されたものなので、この部分の修正が必要な場合は必ず `packages/cli` を修正することで対応すること」
- 「`conformance.test.ts` は、CLI 生成 OP が本リポジトリの想定する挙動を満たすことを利用者に示す契約テスト」

すなわち **生成物の正しさは `packages/cli` のテンプレートと `conformance.test.ts` の 2 点で担保する**という方針が既に決まっている。本トピックはその担保が、フレームワーク派生の軸でどこまで効いているかを確認するものである。

## 3. 参照資料

- **WHATWG Fetch Standard** — https://fetch.spec.whatwg.org/ （`Request` / `Response` / `Headers` の標準。フレームワーク非依存ハンドラの根拠）
- **MDN `String.prototype.replace`** — https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/String/replace （検索文字列が見つからない場合、元の文字列をそのまま返す。例外は投げない = 静かな no-op の根拠）
- 本リポジトリ内:
  - `packages/cli/src/frameworks/web-standard/templates.ts`（`toWebRouteTemplate`、`webRouterTemplate`、`webGeneratedFiles`）
  - `packages/cli/src/frameworks/hono/templates.ts`（唯一のルートテンプレート実体）
  - `packages/cli/src/frameworks/{express,fastify,nextjs}/index.ts`（いずれも `webGeneratedFiles` へ委譲）
  - `packages/cli/src/__tests__/web-framework-generators.test.ts`（現在の回帰ガード）
  - `tasks/experimental/done/par/specification.md` / `tasks/experimental/done/token-exchange/specification.md`（共有テンプレートを実装コスト削減の根拠として挙げた記録）

## 4. 現在の実装確認

### 4.1 派生の構造

```
packages/cli/src/frameworks/
├── hono/templates.ts          ← ルートテンプレートの実体（唯一）
├── web-standard/templates.ts  ← toWebRouteTemplate() で Hono 出力を変換 + WebRouter/WebContext を生成
├── express/index.ts           ← webGeneratedFiles(..., expressApplyTemplate(...))
├── fastify/index.ts           ← webGeneratedFiles(..., fastifyApplyTemplate(...))
└── nextjs/index.ts            ← webGeneratedFiles(..., nextjsApplyTemplate(...))
```

`webGeneratedFiles` は `toWebRouteTemplate` を **12 か所**（authorize / token / userinfo / introspection / revocation / par / device-authorization / device / jwks / discovery / login / consent）に適用する。

### 4.2 `WebContext` / `WebRequest` は Hono のコンテキスト API の手書き再実装

`webRouterTemplate()` が出力する `WebContext` は、Hono のコンテキスト API を意図的に模倣している。コード中のコメントにもそう書かれている。

> Mirrors Hono's loose context variable API so generated route templates can stay framework-neutral without forcing every `c.get()` call to cast.

現在 Hono テンプレートが使っているコンテキスト API と、`WebContext` / `WebRequest` / `WebRouter` の実装状況は次のとおり（Hono テンプレートを `c.` で grep した結果との突き合わせ）。

| Hono テンプレートでの使用 | 出現数 | Web 標準側の実装 |
|---|---|---|
| `c.get(key)` | 122 | ✅ `WebContext.get`（戻り値 `any`） |
| `c.set(key, value)` | 72 | ✅ |
| `c.header(name, value)` | 55 | ✅ |
| `c.json(data, status)` | 51 | ✅ |
| `c.req.header(name)` | 24 | ✅ `WebRequest.header` |
| `c.redirect(url, status)` | 23 | ✅ |
| `c.req.text()` | 7 | ✅ |
| `c.req.url` | 5 | ✅ getter |
| `c.req.parseBody()` | 5 | ✅（`x-www-form-urlencoded` / `multipart/form-data` のみ） |
| `c.text(data, status)` | 3 | ✅ |
| `c.req.query(name)` | 3 | ✅ |
| `c.req.method` | 3 | ✅ getter |
| `c.body(data, status)` | 3 | ✅ |
| `c.req.raw` | 2 | ✅ |

**現時点では過不足なく一致している**。`WebRouter` 側は `get` / `post` / `use` / `route` / `request` / `fetch` を実装しており、Hono テンプレートが使うルーティング API（`.get()` / `.post()` / `.use()` / `.route()`）を満たしている。

### 4.3 回帰ガードの現状

`packages/cli/src/__tests__/web-framework-generators.test.ts` には次のアサーションがある。

```ts
// Express の describe 内
it('should generate framework-neutral OIDC routes', () => {
  const file = files.find((f) => f.path === 'routes/authorize.ts');
  expect(file?.content).toContain("import { WebRouter } from '../web-router.js'");
  expect(file?.content).not.toContain("from 'hono'");
  expect(file?.content).toContain('export const authorizeApp = new WebRouter()');
});

// Fastify の describe 内
it('should generate framework-neutral OIDC routes', () => {
  const file = files.find((f) => f.path === 'routes/token.ts');
  // 同様のアサーション（対象は routes/token.ts）
});
```

すなわち **12 本のルートのうち、`routes/authorize.ts` と `routes/token.ts` の 2 本にしか「hono を含まないこと」のアサーションが無い**。残る 10 本（userinfo / jwks / discovery / login / consent / introspection / revocation / par / device-authorization / device）には同種のガードが無い。

### 4.4 変換失敗が検知されうる別経路

生成物が壊れたとき、次の経路でも気付ける可能性がある。

- `pnpm typecheck` は `samples/*` を対象に含む。`samples/express-flyio` / `samples/fastify-flyio` / `samples/nextjs-vercel` の `src/oidc-provider` に `import { Hono } from 'hono'` が残れば、`hono` が依存に無い限り型エラーになる
- `study-material/done/cli-generated-output-conformance-ci.md` が扱う「生成物と `samples/*` の一致を CI で確認する」仕組み

ただしこれらは **生成物をコミット済みの `samples/*` へ反映した後**に効く事後検知であり、`packages/cli` の単体テストの段階では 10 本のルートが素通りする。

## 5. 現在の実装との差分

### 満たしていること

- ✅ Hono / Express / Fastify / Next.js の 4 ターゲットが実際に生成できる（`cli-framework-portability-and-web-standard-handler.md` の提案は実現済み）
- ✅ ルートロジックが 1 系統に集約されており、仕様変更が全ターゲットに一度で反映される
- ✅ `WebRouter` / `WebContext` は Fetch Standard の型のみに依存し、Portability 軸の主張と整合する
- ✅ `WebContext` の API 表面は、現時点で Hono テンプレートの使用箇所を過不足なくカバーしている
- ✅ 2 本のルートについては「hono を含まない」ことがテストで固定されている

### 不足している可能性があること

- 🟡 **`toWebRouteTemplate` の置換が静かに no-op になりうる**。`.replace("import { Hono } from 'hono';", ...)` は完全一致が前提であり、Hono テンプレート側の import 行が変わる（例: `import { Hono, type Context } from 'hono';` に変える、`import {Hono} from 'hono';` のように空白が変わる、テンプレート文字列内で行頭が変わる）と、変換は例外を投げずに元のまま返す
- 🟡 **回帰ガードが 12 本中 2 本**。新しいルートを追加した場合、そのルートには自動的にはガードが付かない
- 🟡 **`WebContext` の API 表面に「これで全部」を保証する仕組みが無い**。Hono テンプレートが新しい Hono API（例: `c.notFound()` / `c.newResponse()` / `c.req.param()` / `c.executionCtx`）を使い始めても、文字列変換は成功し、生成物は `packages/cli` のテストを通過する
- 🟡 **`WebRouter` は `get` / `post` しか HTTP メソッドを持たない**。`tasks/done/p2-http-method-405-and-allow.md` が方針候補として挙げた「各ルートで `app.all` フォールバック」を将来採用すると、Hono 側では動くが Web 標準側では存在しないメソッドになる。同様に、将来 `DELETE` を使うエンドポイント（例: RFC 7592 のクライアント管理、`study-material/ext-dynamic-client-registration-management-rfc7592.md`）を足す場合も `WebRouter` の拡張が必要になる
- 🟢 **派生方式が文書化されていない**。`toWebRouteTemplate` にコメントが無く、「Hono テンプレートを編集するときは変換前提を壊さないこと」という制約が読み手に伝わらない

### 実装はあるが仕様上の確認が必要なこと

- 🟡 **`parseBody()` の対応 MIME**。Web 標準側は `application/x-www-form-urlencoded` と `multipart/form-data` のみを扱い、それ以外は空オブジェクトを返す。Hono の `parseBody()` とセマンティクスが完全一致するかは、Token Endpoint の Content-Type 検証（既に厳格化済み）と併せて確認しておく価値がある
- 🟢 **`WebContext.get()` が `any` を返すこと**。Hono の緩いコンテキスト API を模倣するための意図的な選択だが、型安全性は失われている。これは既知のトレードオフとしてコメントに記録されている

### セキュリティ上、改善した方がよいこと

- 🟡 **静かな変換失敗が生成物の実行時破綻に化ける経路**。変換が no-op になると、Express 用に生成されたコードが `hono` を import する。利用者のプロジェクトに `hono` が入っていなければビルドで落ちるため実害は限定的だが、**入っていた場合は「Hono のルータが Express アダプタから呼ばれる」状態**になり、挙動が不定になる。認可サーバの生成物としては望ましくない失敗の仕方である

### Basic OP として提供する上で確認すべきこと

- Basic OP の要件そのものには影響しない。ただし各 `samples/*` の `conformance.test.ts` が全ターゲットで通ることが、フレームワークを跨いだ挙動同一性の実質的な保証になっている。この保証がどのターゲットで実行されているかを確認する価値がある

## 6. 改善・追加を検討する理由

### なぜ価値があるのか

- **Portability 軸は本リポジトリの差別化 3 軸の 1 つ**であり、その実装が「文字列置換」という壊れやすい機構に依存していることは、主張の裏付けとして弱い。裏付けを固めることはブランド上も実利上も意味がある
- **同型の失敗（静かな置換 no-op）は既にこのリポジトリで一度問題になっている**。`done/cli-setup-entry-placeholder-silent-noop.md` → `tasks/done/p1-cli-setup-placeholder-detection-and-failure.md` で「置換前提が無ければ失敗させる」という解決が採られており、その知見をテンプレート派生側にも適用するだけで済む
- **新しいエンドポイントを足すたびに同じ穴が開く**。experimental 機能（PAR / Device Grant / JARM）が増えるにつれ、ガードの無いルートが増え続ける構造になっている

### Basic OP として必要か、拡張機能として有用か

- **どちらでもない。ビルド基盤の堅牢性の話**である。優先度は仕様準拠タスクより下だが、experimental 機能の追加ペースが速いこのリポジトリでは、放置するとコストが増え続ける類の負債にあたる

### 現在のリポジトリ構成から見た導入しやすさ

- **導入しやすい点**:
  - `toWebRouteTemplate` は 6 行の関数で、変更が 1 か所に閉じる
  - 「置換前提が無ければ throw する」パターンは、`tasks/done/p1-cli-setup-placeholder-detection-and-failure.md` で既に確立済みの手法である
  - `webGeneratedFiles` は生成ファイルの配列を返すので、「全ルートに対して `from 'hono'` を含まないことを検証する」テストは 1 本のループで書ける
- **導入しにくい点**:
  - `WebContext` の API 表面の網羅を機械的に保証するには、Hono テンプレートから `c.*` の使用箇所を静的に抽出して `WebContext` のメンバーと突き合わせる仕組みが要る。単純な文字列 grep でどこまで正確にやるかの判断が必要
  - 根本解決（ルートテンプレートを最初から Web 標準で書き、Hono 側をアダプタにする）は大規模なリファクタになる

### 既存実装との接続

- `packages/cli/src/frameworks/web-standard/templates.ts`: `toWebRouteTemplate` のアサーション追加点
- `packages/cli/src/__tests__/web-framework-generators.test.ts`: 全ルート走査テストの追加点
- `packages/cli/src/frameworks/hono/templates.ts`: 変換前提となる文字列（import 行 / `new Hono<...>()` 呼び出し）を持つ側。ここを編集する人に制約を伝えるコメントの追加点

### 利用者・開発者・運用者のメリット

- 開発者（このリポジトリの保守者）: Hono テンプレートを編集したときに、変換前提を壊したことが `packages/cli` のテストで即座に分かる
- 利用者: Express / Fastify / Next.js 向けに生成したコードが確実にフレームワーク中立であることが、テストで保証される

### 実装しない場合に残る制約・リスク

- Hono テンプレートの import 行やルータ生成式を触った瞬間に、3 ターゲットの生成物が静かに壊れる（10 本のルートは `packages/cli` のテストで検知されない）
- 新しい Hono API を使い始めても気付かず、`samples/*` を再生成して typecheck するまで露見しない
- experimental 機能を足すたびにガードの無いルートが増える

## 7. 実装方針の候補

**最終判断は人間が行う。以下は判断材料の整理である。**

### 方針 A: `toWebRouteTemplate` を「前提が無ければ失敗する」変換にする（最小・即効）

```ts
function toWebRouteTemplate(content: string): string {
  const HONO_IMPORT = "import { Hono } from 'hono';";
  const HONO_ROUTER = 'new Hono<{ Variables: Record<string, any> }>()';
  if (!content.includes(HONO_IMPORT)) {
    throw new Error('toWebRouteTemplate: expected the Hono import line ...');
  }
  // ... 変換後に 'hono' が残っていないことも検証する
}
```

- 変更範囲: 関数 1 つ + そのユニットテスト
- 利点: 静かな no-op が消える。実装コスト最小。`done/cli-setup-entry-placeholder-silent-noop.md` で確立済みのパターンの再利用
- 欠点: 「Hono API の使用箇所が増えた」ケースは検知できない（import と router 生成式だけを見るため）
- 補足: 変換後に `from 'hono'` / `new Hono` が残っていないことも同関数内で検証すれば、A の検知範囲は import 行以外にも広がる

### 方針 B: 生成ファイル全体を走査する回帰テストを足す

`webGeneratedFiles` の戻り値（`GeneratedFile[]`）を全件走査し、`routes/` 配下のすべてのファイルについて `from 'hono'` を含まず `WebRouter` を使っていることを検証する。

- 変更範囲: `packages/cli/src/__tests__/web-framework-generators.test.ts` に 1 本
- 利点: 新しいルートを足しても自動的にガードが付く。既存の 2 本のアサーションを置き換えられる
- 欠点: 生成物の中身（Hono API の使用）までは見ない
- 方針 A との関係: 補完関係にあり、両方入れるのが自然

### 方針 C: `WebContext` の API 表面と Hono テンプレートの使用箇所の一致をテストで固定する

Hono テンプレートの出力から `c.<member>` / `c.req.<member>` を抽出し、既知の許可リスト（= `WebContext` / `WebRequest` が実装しているメンバー）に含まれることを検証する。

- 利点: 「新しい Hono API を使い始めた」を `packages/cli` のテスト段階で検知できる。API 表面の対応表がテストとして常に最新になる
- 欠点: 正規表現ベースの抽出は誤検知・見落としの余地がある（文字列リテラル中の `c.` など）。許可リストの保守が必要
- 補足: `WebRouter` の HTTP メソッド（`get` / `post` のみ）についても同種の検証を入れられる

### 方針 D: 派生方向を反転する（根本解決）

ルートテンプレートを最初から `WebRouter` / `WebContext` ベースで書き、Hono ターゲットは薄いアダプタ（`Hono` から `WebRouter` へブリッジ）として生成する。

- 利点: 文字列変換が消える。Portability 軸の主張が構造として成立する
- 欠点: 12,000 行超の Hono テンプレートを全面的に書き換えることになり、影響範囲が大きい。`samples/hono-cloudflare` の生成物が全面的に変わる
- 判断材料: 現在の変換が実際に壊れた実績が無い以上、コストに見合うかは疑問。方針 A + B で十分という判断も十分成り立つ

### 方針 E: 契約の文書化のみ

`toWebRouteTemplate` と Hono テンプレート冒頭にコメントを追加し、「この import 行 / ルータ生成式は Web 標準変換の前提であり、変更する場合は `web-standard/templates.ts` を併せて更新すること」と明記する。

- 利点: コストゼロ
- 欠点: 人間の注意力に依存する

### 横断的な論点

- **`WebRouter` の HTTP メソッド拡張のタイミング**。`get` / `post` 以外が必要になる具体的な予定（RFC 7592 のクライアント管理エンドポイントは `PUT` / `DELETE` を使う）があるなら、その実装時に併せて拡張することになる。今の時点で先回りする必要があるかは判断事項
- **`study-material/cli-framework-portability-and-web-standard-handler.md` の記述更新**。当該ファイルは「Hono 1 種類しか出せない」という古い状態を前提にしている。本トピックとは別に、現状へ追随させる必要がある

## 8. タスク案

- [ ] **方針 A の実装**: `toWebRouteTemplate` を、変換前提が存在しなければ明示的にエラーを投げる形に変える。変換後に `hono` への参照が残っていないことも同関数内で検証する
- [ ] **方針 B の実装**: `webGeneratedFiles` が返す `routes/` 配下の全ファイルについて、`from 'hono'` を含まないこと・`WebRouter` を使っていることを検証するテストを追加する（express / fastify / nextjs の 3 ターゲット分）
- [ ] **テストケース（`packages/cli`）**:
  - [ ] `should throw when the Hono import line is missing from a route template`
  - [ ] `should throw when the Hono router expression is missing from a route template`
  - [ ] `should generate no route file that references hono for the Express target`（全ルート走査）
  - [ ] `should generate no route file that references hono for the Fastify target`
  - [ ] `should generate no route file that references hono for the Next.js target`
- [ ] **方針 C の要否判断**: Hono コンテキスト API の使用箇所を静的に検証するテストを入れるか決める。入れる場合は許可リストの置き場所（`web-standard/templates.ts` に定数としてエクスポートするか、テスト内に持つか）を決める
- [ ] **契約の文書化**: `toWebRouteTemplate` に JSDoc を付け、Hono テンプレート側の該当箇所にも「Web 標準変換の前提である」旨のコメントを追加する
- [ ] **`WebRouter` の HTTP メソッド方針の確認**: 将来 `PUT` / `DELETE` / `all` が必要になる機能（RFC 7592、405 の `app.all` フォールバック案）との関係を整理し、先行実装するか都度対応するかを決める
- [ ] **既存ファイルの更新**: `study-material/cli-framework-portability-and-web-standard-handler.md` の「登録されているジェネレータは Hono のみ」という記述を現状（hono / express / fastify / nextjs + web-standard 共通ランタイム）に合わせて更新する
