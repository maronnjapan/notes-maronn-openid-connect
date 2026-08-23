# [P1] sample の conformance.test.ts をテストランナーに接続し、生成物の未定義参照を直す

## ステータス

🟠 High / 未着手

## 背景

CLAUDE.md は `samples/*` の `conformance.test.ts` を「CLI 生成 OP が本リポジトリの想定する挙動を
満たすことを**利用者に示す契約テスト**」と位置づけている。しかし現状、この契約は二重に機能していない。

### (1) 生成物が壊れている（express / fastify / nextjs）

生成された `conformance.test.ts` が未定義の関数 `conformanceAuthorizationCode` を参照しており、
vitest で実行すると 1 件失敗する。`main` でも同じ。

```
FAIL src/oidc-provider/conformance.test.ts > Token Introspection nbf validation (RFC 7662 §2.2)
     > should echo the jti of an access token issued by the token endpoint
ReferenceError: conformanceAuthorizationCode is not defined
```

原因は判明している。ヘルパーを出力する `authorizationCodeConformanceHelper(features)` は
**hono の `conformanceTestTemplate` にしか差し込まれていない**（`packages/cli/src/frameworks/hono/templates.ts:8795`）。
一方、そのヘルパーを呼ぶテストを出力する `introspectionConformanceBlock(features)` は
hono と web-standard の**両方**から使われている（`web-standard/templates.ts:2291`）。
結果、express / fastify / nextjs の生成物だけが「呼ぶ側はあるが定義側が無い」状態になる。

`features.introspection` は既定 ON なので、**既定生成物が壊れている**。

### (2) どのテストランナーにも接続されていない

上記が今まで顕在化しなかったのは、sample の `conformance.test.ts` が CI でも
ローカルの `pnpm test` でも一度も実行されていないため。

| sample | `vitest` devDependency | `test` スクリプト | 実行される？ |
|---|---|---|---|
| `hono-cloudflare` | あり | `core/experimental build && typecheck && test:conformance`（`vitest run`） | `pnpm --filter "./samples/*" test` でのみ実行される |
| `express-flyio` | **なし** | `pnpm run typecheck` のみ | されない |
| `fastify-flyio` | **なし** | `pnpm run typecheck` のみ | されない |
| `nextjs-vercel` | **なし** | `pnpm run typecheck` のみ | されない |

さらに root の `test:ci` は

```
test:ci-gate && test:supply-chain && test:release-contract
  && pnpm --filter "./packages/*" test && test:conformance
```

であり、`--filter "./packages/*"` に samples は含まれない。`test:conformance` は
`tests/conformance`（OIDF Conformance Suite の runner スクリプト）であって sample のテストではない。
`.github/workflows/ci.yml` も `build` / `typecheck` / `test:ci` / `test:e2e` しか実行しない。

したがって **hono の分も含め、sample の契約テストは CI で 1 件も走っていない**。
「契約テストが落ちたら想定挙動から外れたと分かる」という CLAUDE.md の前提が成立していない。

> 直近の `tasks/done/p1-auth-transaction-user-agent-binding.md` で追加した
> transaction-binding の契約テスト（有効時 9 件 / 既定時 2 件）も、この配線が無いため
> CI では実行されていない。既定の「Cookie 無しでフロー全体を完走できる」契約を
> 回帰から守るには本タスクが前提になる。

## 対象ファイル

- `packages/cli/src/frameworks/web-standard/templates.ts`
  - `webConformanceTestTemplate` に `authorizationCodeConformanceHelper` 相当を差し込む
- `packages/cli/src/frameworks/hono/templates.ts`
  - `authorizationCodeConformanceHelper` は現在 module-private。web-standard から使うため export する
- `packages/cli/src/__tests__/web-framework-generators.test.ts` / `hono-generator.test.ts`
  - 再発防止の generator テスト
- `samples/express-flyio/package.json` / `samples/fastify-flyio/package.json` / `samples/nextjs-vercel/package.json`
  - `vitest` を devDependency に追加し、`test:conformance` と `test` を hono に揃える
- `package.json`（root）
  - `test:ci` に sample の契約テストを組み込む
- 再生成される 4 sample の `conformance.test.ts`

> CLAUDE.md のルールに従い、`samples/*/src/oidc-provider` は直接編集せず
> `packages/cli` のテンプレートを修正して再生成すること。

## 仕様参照

OIDC / OAuth の条文には直接関わらない。準拠先は本リポジトリの方針。

- CLAUDE.md「samples ディレクトリの…conformance.test.ts について」: 生成 OP の結合テストであり、
  packages 側で挙動が変わったら更新が必要。**直接変更せず `packages/cli` の生成コードを変更する**
- CLAUDE.md「実装におけるルール」: `conformance.test.ts` は利用者に示す契約テストとして扱う。
  利用者が生成コードを改変して想定挙動から外れた場合に**テスト失敗で認識できる**ようにすること
- CLAUDE.md「実装におけるルール」: dependencies は内部ライブラリのみ。**devDependencies は任意の外部ライブラリ可**
  （`vitest` の追加はこれに該当し、方針に抵触しない）
- `.github/scripts/verify-ci-gate.mjs`: `TEST_COMMAND = 'pnpm run test:ci'`。
  sample のテストを `test:ci` の中に入れる限り、workflow 側の編集は不要でゲートも維持される

## 現状の実装

`packages/cli/src/frameworks/hono/templates.ts:6360`:

```ts
// Emitted only when the introspection endpoint is generated: it is the only
// caller, and the generated sample tsconfig sets noUnusedLocals.
function authorizationCodeConformanceHelper(features: OidcFeatureConfig): string {
  if (!features.introspection) return '';
  return `
const CONFORMANCE_PKCE_CHALLENGE = '...';
async function conformanceAuthorizationCode(scope: string): Promise<string> { ... }
`;
}
```

hono 側（`:8795`）だけがこれを差し込んでいる:

```ts
${authorizationCodeConformanceHelper(features)}
${conformanceTestClientsBlock(features)}...
```

`webConformanceTestTemplate`（`web-standard/templates.ts:1596` 付近）には対応する差し込みが無い。
`noUnusedLocals` があるため、**introspection 無効時に無条件で出力してはいけない**点に注意。

## 修正方針

### Step 1: 未定義参照を直す（これ単体で 3 sample が緑になる）

- [ ] `authorizationCodeConformanceHelper` を `export` する
- [ ] `web-standard/templates.ts` の import に追加し、`webConformanceTestTemplate` の
      `introspectionConformanceBlock` と同じ features 条件で差し込む
- [ ] `--disable introspection` で生成したときにヘルパーが出力されないことを確認する
      （`noUnusedLocals` で `tsc` が落ちるため、ここを取り違えると別の壊れ方をする）

### Step 2: 再発防止

- [ ] generator テストを追加する。「生成された `conformance.test.ts` が
      `conformanceAuthorizationCode(` を参照するなら、同じファイルが
      `async function conformanceAuthorizationCode(` を定義していること」を
      **4 フレームワーク × introspection 有効／無効**で検証する
- [ ] 同じ形の穴が他にないか、`hono` 側のみで差し込まれている
      `${...ConformanceHelper}` / `${...ModuleSetup}` 系を洗い出して確認する
      （`requestObjectConformanceModuleSetup` などは両方に入っているか要確認）

### Step 3: テストランナーへ接続する

- [ ] `express-flyio` / `fastify-flyio` / `nextjs-vercel` に `vitest` を devDependency として追加
- [ ] 3 sample に `test:conformance: "vitest run"` を追加し、`test` を hono と同じ構成に揃える
- [ ] root の `test:ci` に sample の契約テストを追加する。例:
      `... && pnpm --filter "./packages/*" test && pnpm --filter "./samples/*" test:conformance && pnpm run test:conformance`
      - `test:conformance` を直接呼ぶ形にすると、sample の `test` が持つ
        `core/experimental build && typecheck` の再実行を避けられる（`test:ci` の前段で
        すでに build / typecheck 済みのため）
      - root の `test:conformance`（`tests/conformance`）と sample の `test:conformance` は
        名前が衝突して紛らわしい。どちらかの改名も検討してよい
- [ ] `verify-ci-gate.mjs` が緑のままであることを確認する（`test:ci` の中に入れる限り不要のはず）

### Step 4: nextjs sample の実行可否を確認する

- [ ] `samples/nextjs-vercel/src/app/_oidc-provider/conformance.test.ts` が vitest で動くか確認する。
      `.tsx` を含むディレクトリ配下にあるため、`include` の絞り込みや
      `vitest.config.ts` の追加が必要になる可能性がある
- [ ] 動かない場合は、原因（Next.js 固有の解決、`node:sqlite` を使う storage-backend の読み込み等）を
      特定して対処するか、対処不能なら**その理由を明記した上で**当面 3 sample のみ接続する

## テスト要件

`packages/cli`:

- [ ] `should define conformanceAuthorizationCode when the generated conformance test references it`
      （express / fastify / nextjs / hono の 4 ケース）
- [ ] `should not emit the authorization code helper when introspection is disabled`
      （`noUnusedLocals` 対策の裏取り。4 ケース）

sample:

- [ ] 4 sample すべてで `pnpm --filter ./samples/<name> test:conformance` が緑
- [ ] `pnpm run test:ci` が 4 sample の契約テストを実際に実行していること
      （ログに各 sample のテスト件数が出ること）

回帰:

- [ ] `pnpm run test:e2e` が従来どおり緑

## 完了条件

```bash
pnpm install
pnpm run typecheck
pnpm run build
pnpm run test:ci     # 4 sample の conformance.test.ts が実行され、すべて緑
pnpm run test:e2e
```

- 上記がすべて成功する
- `pnpm --filter "./samples/*" test:conformance` を単体で実行しても緑
- `maronn-oidc generate express --disable introspection` で生成した出力が `tsc --noEmit` を通る
- CI（`pull_request`）のログに 4 sample の契約テスト結果が現れている

## 備考

- 本タスクは**テスト／CI 配線の修復**であり、OP の挙動は一切変えない。
  `packages/cli` のテンプレート変更は「生成される conformance.test.ts」にのみ影響する
- `test:ci` の実行時間が伸びる。許容できない場合は sample の契約テストを
  独立した CI ジョブに切り出す案も検討してよい（その場合 `verify-ci-gate.mjs` の
  更新が必要になる可能性がある）
- changeset は不要と思われる（publish 対象パッケージの出荷物が変わるのは
  `packages/cli` の生成テンプレートなので、判断に迷う場合は cli の patch を入れる）
- Step 1 だけでも独立して価値がある。未定義参照の修正は数行で、それだけで 3 sample の
  契約テストが緑になる。Step 3（CI 配線）が重い場合は Step 1+2 で切って別タスクにしてもよい
