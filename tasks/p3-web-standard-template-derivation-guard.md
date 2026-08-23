# [P3] Hono → Web 標準テンプレート変換の前提を検証し、全ルートに回帰ガードを掛ける

## ステータス

🟡 Medium / 未着手

## 背景

CLI は hono / express / fastify / nextjs の 4 ターゲットを生成するが、**ルートテンプレートの実体は Hono 用の 1 系統しかない**。express / fastify / nextjs は `web-standard` ジェネレータへ委譲し、`web-standard` は Hono テンプレートの出力文字列に次の変換を掛けて再利用している。

```ts
function toWebRouteTemplate(content: string): string {
  return content
    .replace("import { Hono } from 'hono';", "import { WebRouter } from '../web-router.js';")
    .replaceAll('new Hono<{ Variables: Record<string, any> }>()', 'new WebRouter()');
}
```

`String.prototype.replace` は検索文字列が見つからなくても例外を投げず、元の文字列をそのまま返す。したがって **Hono テンプレート側の import 行やルータ生成式が変わると、変換は静かに no-op になり、Express 用に生成されたコードが `hono` を import したまま出力される**。

さらに、`toWebRouteTemplate` は 12 本のルート（authorize / token / userinfo / introspection / revocation / par / device-authorization / device / jwks / discovery / login / consent）に適用されるが、`packages/cli/src/__tests__/web-framework-generators.test.ts` が `not.toContain("from 'hono'")` を確認しているのは **`routes/authorize.ts`（Express）と `routes/token.ts`（Fastify）の 2 本だけ**である。残る 10 本にはガードが無く、experimental 機能が増えるたびにガードの無いルートが増える構造になっている。

同型の失敗（置換が静かに no-op になる）はこのリポジトリで一度問題になっており、`study-material/done/cli-setup-entry-placeholder-silent-noop.md` → `tasks/done/p1-cli-setup-placeholder-detection-and-failure.md` で「置換前提が無ければ失敗させる」という解決が既に確立している。本タスクはその手法をテンプレート派生側にも適用する。

詳細な検討は `study-material/done/cli-web-standard-template-derivation-contract.md` を参照。本タスクは同ファイルの**方針 A（変換を fail-fast にする）+ 方針 B（全ルート走査の回帰テスト）**を実装する。方針 C（Hono コンテキスト API の使用箇所を静的に検証する）と方針 D（派生方向の反転）は範囲外とする。

## 対象ファイル

- `packages/cli/src/frameworks/web-standard/templates.ts`（`toWebRouteTemplate`）
- `packages/cli/src/__tests__/web-framework-generators.test.ts`（回帰テスト）
- `packages/cli/src/frameworks/hono/templates.ts`（変換前提であることを示すコメントの追加）

## 仕様参照

OIDC / OAuth の条文に直接対応する論点ではない。根拠は次のとおり。

- **WHATWG Fetch Standard** — https://fetch.spec.whatwg.org/
  `WebRouter` / `WebContext` が依存する `Request` / `Response` / `Headers`。「Web 標準 API のみ使用し、JavaScript が動く環境ならどこでも動く」という CLAUDE.md の Portability 軸の根拠
- **MDN `String.prototype.replace`** — https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/String/replace
  > If `pattern` is a string, only the first occurrence will be replaced...

  検索文字列が見つからない場合は元の文字列がそのまま返る（例外は投げられない）。静かな no-op の根拠
- 本リポジトリ `CLAUDE.md`「差別化の3軸 / Portability」および「`samples/*/src/oidc-provider` は `packages/cli` を修正して対応する」方針

## 現状の実装

`packages/cli/src/frameworks/web-standard/templates.ts`:

```ts
function toWebRouteTemplate(content: string): string {
  return content
    .replace("import { Hono } from 'hono';", "import { WebRouter } from '../web-router.js';")
    .replaceAll('new Hono<{ Variables: Record<string, any> }>()', 'new WebRouter()');
}
```

`packages/cli/src/__tests__/web-framework-generators.test.ts`（現在のガード。Express と Fastify の describe に 1 本ずつ）:

```ts
it('should generate framework-neutral OIDC routes', () => {
  const file = files.find((f) => f.path === 'routes/authorize.ts');   // Fastify 側は 'routes/token.ts'
  expect(file?.content).toContain("import { WebRouter } from '../web-router.js'");
  expect(file?.content).not.toContain("from 'hono'");
  expect(file?.content).toContain('export const authorizeApp = new WebRouter()');
});
```

問題:

- 変換前提の欠落が検知されない（`toWebRouteTemplate` は常に成功する）
- 12 本中 10 本のルートにガードが無い
- Next.js ターゲットには「hono を含まない」アサーションが 1 本も無い

## 修正方針

- [ ] **`toWebRouteTemplate` を fail-fast にする**
  - [ ] 変換前提の文字列を定数として抽出する（`HONO_ROUTER_IMPORT` / `HONO_ROUTER_CONSTRUCTOR`）
  - [ ] 変換前に両方の存在を確認し、無ければ「Hono テンプレート側の変更で変換前提が壊れた」ことが分かるメッセージで `throw` する
  - [ ] 変換後に `from 'hono'` / `new Hono` が残っていないことを確認し、残っていれば `throw` する（import 行以外の Hono 参照が増えた場合も検知できる）
  - [ ] JSDoc を付け、「Hono テンプレートが唯一のルート実体であり、express / fastify / nextjs はこの変換で派生する」ことと、変換前提を壊す変更をした場合はここも直す必要があることを明記する
- [ ] **全ルート走査の回帰テストを追加する**
  - [ ] express / fastify / nextjs の 3 ターゲットそれぞれについて、生成ファイルのうち `routes/` 配下の全ファイルが `from 'hono'` を含まないことを検証する
  - [ ] 同じく `routes/` 配下の全ファイルが `import { WebRouter } from '../web-router.js'` を含むことを検証する
  - [ ] 全 feature を有効化した生成（experimental を含む）でも走らせ、par / device-authorization / device のルートもガード対象に入れる
  - [ ] 既存の 2 本のアサーション（`routes/authorize.ts` / `routes/token.ts` 個別）は、全ルート走査に置き換えるか併存させるかを実装時に決める
- [ ] **Hono テンプレート側にコメントを追加する**
  - [ ] ルートテンプレートが出力する `import { Hono } from 'hono';` 行と `new Hono<{ Variables: Record<string, any> }>()` 式が、`web-standard` 側の変換前提であることを、テンプレート生成関数の JSDoc に記す

実装例（`toWebRouteTemplate`）:

```ts
const HONO_ROUTER_IMPORT = "import { Hono } from 'hono';";
const HONO_ROUTER_CONSTRUCTOR = 'new Hono<{ Variables: Record<string, any> }>()';

/**
 * Hono 用ルートテンプレートの出力を Web 標準（WebRouter / WebContext）版へ変換する。
 *
 * express / fastify / nextjs は独自のルートテンプレートを持たず、Hono テンプレートを
 * 唯一の実体としてこの変換で派生させている。変換前提が壊れると生成物が静かに
 * hono 依存のまま出力されるため、前提の有無をここで検証して fail-fast にする。
 */
function toWebRouteTemplate(content: string): string {
  if (!content.includes(HONO_ROUTER_IMPORT)) {
    throw new Error(
      `toWebRouteTemplate: expected ${JSON.stringify(HONO_ROUTER_IMPORT)} in the Hono route template. ` +
        'The Hono template changed; update web-standard/templates.ts to match.',
    );
  }
  if (!content.includes(HONO_ROUTER_CONSTRUCTOR)) {
    throw new Error(
      `toWebRouteTemplate: expected ${JSON.stringify(HONO_ROUTER_CONSTRUCTOR)} in the Hono route template. ` +
        'The Hono template changed; update web-standard/templates.ts to match.',
    );
  }

  const converted = content
    .replace(HONO_ROUTER_IMPORT, "import { WebRouter } from '../web-router.js';")
    .replaceAll(HONO_ROUTER_CONSTRUCTOR, 'new WebRouter()');

  if (converted.includes("from 'hono'") || converted.includes('new Hono')) {
    throw new Error(
      'toWebRouteTemplate: the converted route template still references hono. ' +
        'A new Hono API was introduced in the Hono template; extend the conversion or the WebRouter runtime.',
    );
  }
  return converted;
}
```

## テスト要件

`packages/cli/src/__tests__/web-framework-generators.test.ts`:

- [ ] `should throw when the Hono router import line is missing from a route template`
- [ ] `should throw when the Hono router constructor expression is missing from a route template`
- [ ] `should throw when the converted route template still references hono`
- [ ] `should generate no route file that references hono for the Express target`（`routes/` 配下の全ファイルを走査）
- [ ] `should generate no route file that references hono for the Fastify target`
- [ ] `should generate no route file that references hono for the Next.js target`
- [ ] `should generate every route file with the WebRouter import for the Express target`
- [ ] 上記の全ルート走査を、experimental を含む全 feature 有効の生成オプションでも実行する

`toWebRouteTemplate` は現在 module private なので、テストから直接呼べるようにエクスポートするか、生成物経由（不正な入力を与えられないため間接検証になる）で検証するかを実装時に決める。エクスポートする場合は「テスト用に公開している」旨を JSDoc に記す。

## 完了条件

- [ ] 上記テストがすべて通る
- [ ] `pnpm --filter @maronn-openid-connect/cli test`
- [ ] `pnpm typecheck`
- [ ] `samples/*` の再生成結果が変わらない（本タスクは生成物の内容を変えない。差分が出た場合は変換の副作用なので調査すること）
- [ ] `toWebRouteTemplate` と Hono テンプレート側の該当箇所に、派生関係を説明する JSDoc / コメントが入っている
