# packages/experimental の全体像

この文書は `@maronn-openid-connect/experimental` というパッケージそのものの解説である。
個々の機能（PAR、Token Exchange、JARM、Device Authorization Grant）の実装は機能別の解説に全文を載せているので、ここではパッケージの位置づけ、機能を横断する設計規約、ビルドとリリースの仕組みを説明する。

## このパッケージが存在する理由

このリポジトリは「最新の OIDC/OAuth 仕様を誰よりも早く・忠実に・どこでも動く形で検証できる」ことを目標にしている。
新しい仕様を最速で追うには、API の安定性を約束する `@maronn-openid-connect/core` とは別の場所が要る。
**packages/experimental** はその置き場で、API が安定していない実装をまとめた独立パッケージである。

core と experimental の分離は、利用者への約束の分離でもある。
core のバージョンは安定性のシグナルとして扱い、experimental は「変更内容に関わらず patch を 1 つ上げるだけ」という機械的な運用で core より速く publish する。
バージョン番号で互換性を表現しないため、利用者に伝えるべき互換性の情報は CHANGELOG と README に書く。

## 機能の一覧と import 経路

実装済みの機能は 4 つで、それぞれ subpath export として公開している。

| feature-id | 内容 | 準拠仕様 | import 元 |
|---|---|---|---|
| `par` | Pushed Authorization Requests | RFC 9126 | `@maronn-openid-connect/experimental/par` |
| `token-exchange` | OAuth 2.0 Token Exchange（impersonation と delegation） | RFC 8693 | `@maronn-openid-connect/experimental/token-exchange` |
| `jarm` | JWT Secured Authorization Response Mode（署名付き `query.jwt` のみ） | JARM (OpenID Foundation Final, 2022-11-09) | `@maronn-openid-connect/experimental/jarm` |
| `device-authorization-grant` | OAuth 2.0 Device Authorization Grant | RFC 8628 | `@maronn-openid-connect/experimental/device-authorization-grant` |

ルート（`.`）からの再エクスポートは提供しない。
機能間でコードを共有しないことで、ある機能を core へ昇格させたり削除したりするときに、他機能へ影響しない構造を保っている。
テスト専用のフィクスチャも機能ディレクトリの中だけで共有する（device-authorization-grant の `test-helpers.ts` が例で、tsconfig の exclude により配布物には含めない）。

## 機能を横断する設計規約

4 つの機能は独立に実装されているが、次の規約を共有している。
機能別の解説を読むときは、この規約を前提にすると個々の判断が追いやすい。

- **ステップ関数と合成関数の二層構成**：処理を仕様の検証単位ごとのステップ関数に分け、それを仕様順に呼ぶだけの合成関数を別に置く。CLI 生成コードはステップ関数を順に呼び出す形で出力されるため、利用者は検証の差し替えや削除を生成コード上で行える。
- **core 無変更**：experimental の機能追加のために core のコードへ手を入れない。core のエラー enum が閉じているために相乗りできない場面では、機能側で専用のエラークラスを新設する（`ParError`、`TokenExchangeError`、`DeviceAuthorizationError` など）。
- **オラクルを作らない**：資格情報や参照値の解決に失敗したとき、失敗理由を応答から区別できないよう固定文言で返す。PAR の `request_uri`、Token Exchange の `subject_token`、デバイスフローの `user_code` と `device_code` のいずれも同じ方針を取る。
- **error_description のサニタイズ**：エラー文言は必ず core の `sanitizeErrorDescription` を通し、RFC 6749 §5.2 の安全な文字集合に限定する。
- **単回使用は store の契約で強制する**：一度しか使わせない値（PAR の `request_uri`、デバイスフローの `device_code`）は、取得と削除を atomic に行う `consume` だけを契約に置き、「読むだけ」の操作を型レベルで排除する。
- **時刻の注入**：期限計算を伴う関数は `now?: Date` を受け取り、テストから決定的に検証できるようにする。

## 依存方向と core との関係

依存の向きは一方向に固定している。

```text
packages/cli ────> @maronn-openid-connect/experimental（生成コードの依存として明示）
@maronn-openid-connect/experimental ────> @maronn-openid-connect/core（許可）
packages/core ──X──> packages/experimental（禁止）
```

core は experimental の `peerDependencies` であり、`dependencies` ではない。
experimental は core のエラークラスを `instanceof` で判定し、resolver や store を生成コードと受け渡しするため、アプリ全体で core のインスタンスが 1 つでなければならない。
core を `dependencies` に入れると core が二重にインストールされ、`instanceof` が静かに false になって、本来 `invalid_request` を返すべき場面が 500 になる。
peer range（現在 `>=0.1.1 <1.0.0`）は「experimental が実際に要求する最低の core」を宣言する下限であり、バージョン番号の一致を要求するものではない。
下限の妥当性は CI（`.github/scripts/verify-release-contract.mjs`）が機械的に検査する。

## CLI 統合の仕組み

利用者が experimental の機能に触れる入口は CLI である。
`maronn-oidc generate <framework> --enable <feature-id>` と明示したときだけ、生成コードにその機能のコードが入り、生成物が experimental パッケージへ依存するようになる。
デフォルト生成では experimental は一切参照されない。

### 生成コードを抜き出す元のアプリ

`maronn-oidc generate` は、テンプレートから生成コードを組み立てるのではなく、動いているアプリからコードを写す。
写す元は、全機能を有効にした OP として動く [apps/hono](../../../apps/hono) の `src/oidc-provider/` で、PR ごとの E2E はこのアプリに対して走る。
どのディレクトリをどのフレームワークの出力にするかは [packages/cli/extract.json](../../../packages/cli/extract.json) が定め、CLI のビルドがそのディレクトリを CLI パッケージの中へ写し、ステップとエンドポイントのメタ情報をカタログにまとめる。
`generate` はこの写しから有効な機能のファイルを選び、無効な機能のコードを取り除いて出力する（[packages/cli/src/generate.ts](../../../packages/cli/src/generate.ts)）。
テストファイル（`*.test.ts` と `*.test.tsx`）は写さないので、生成物には含まれない。

hono の生成コードは次の構成になる。

```text
app.ts  apply.ts  config.ts  store.ts  resolvers.ts  views.tsx  cors.ts  cookies.ts  scopes.ts  development.ts
db/                         データベース（--db で選んだ種類）
pages/                      エラー画面と応答の補助
endpoints/<endpoint>/
  pipeline.ts               そのエンドポイントのステップを順に呼ぶ
  steps/<step>.ts           ステップ 1 つにつき 1 ファイル
  endpoint.ts               maronn-oidc graph の図の元になるメタ情報
features/
  feature.ts                defineFeature() とフックの型
  enabled.ts                有効な機能の一覧
  <feature-id>/             その機能が所有するもののすべて
```

### base と機能の境界

アプリのファイルは、パスによって base、機能、データベースの種類のどれかに属する。
`features/<feature-id>/` の下はその機能に、`db/<kind>/` の下はそのデータベースの種類（memory、sql、kv）に属し、それ以外が base である。
base は `features/<feature-id>/` も experimental パッケージも import せず、この境界は `pnpm run lint`（`.github/scripts/lint-import-boundaries.mjs`）が検査する。
機能が base に差し込む手段は、`features/feature.ts` のフックと、base のパイプラインに置く所有者付きブロックの 2 つに限られる。

フックは、base が決まった場所で読む宣言的な値である。
各機能の `feature.ts` は `defineFeature({...})` で、次の決まった種類のフックに値を与えて機能を宣言する。

- **routes**：機能が提供するエンドポイント。`app.ts` がマウントし、パスのメソッド（それ以外は 405）、配下のパスとそのメソッド（`subpaths`）、トークンエンドポイントと同じ CORS を使うか（`cors: 'protected'`）もここで宣言する
- **discovery**：プロバイダメタデータに加える項目。配列の値は base の配列にまとめ、それ以外の値は置き換える
- **context**：機能のステップのために、リクエストコンテキストへ入れる値（`c.set`）
- **config**：プロバイダ設定の既定値。`config.ts` の既定値の上に重ねる
- **token.grants**：トークンエンドポイントで答える `grant_type` の値。discovery の `grant_types_supported` にも加わる
- **authorize.responseModes**：機能が応答する応答モード。`/consent` は保存した transaction から、認可リクエストが求めたモードをこれで復元する
- **loginMethods**：ログイン画面がパスワードのフォームの隣に出すログイン方法

base はこれらを `features/feature.ts` の関数（`routesOf()`、`discoveryOf()`、`applyContextOf()`、`configOf()`、`tokenGrantsOf()`、`responseModesOf()`、`loginMethodsOf()`）を通して読み、機能を直接 import しない。
機能が受け取るオプション、設定、画面は、機能のディレクトリからのモジュール拡張（`declare module '../../app.js'`、`'../../config.js'`、`'../../views.js'`）で base の型に加える。

base のパイプラインの途中で動く処理はフックにしない。
その処理のステップの関数は機能のディレクトリに置き、呼び出しは base の `pipeline.ts` の中に、機能の名前を書いた目印のコメントで始まるブロックとして置く。
次は PAR が認可エンドポイントのパイプラインに置くブロックである。

```typescript
    // [resolve-pushed-request] (feature: par) Expand the pushed request_uri — RFC 9126 §4 / §5
    params = await resolvePushedAuthorizationRequest(c, params);
```

目印の行から次の目印の直前までがブロックで、これを **所有者付きブロック** と呼ぶ。
機能を無効にして生成すると、CLI はその機能のブロックと、ブロックだけが使っていた import を削除する。
削除したブロックが定義し、後続のコードがまだ読む値は `const <name> = undefined;` として残し、だれも読まなくなった束縛は外す。
この処理をフックにしないのは、パイプラインの中の位置に意味があるからである。
ブロックの 1 つ 1 つは `maronn-oidc graph` の図の箱 1 つに対応し、`--flow` のフロー文書でステップを並べ替えたり外したりすると、CLI はそれに合わせてブロックを並べ替えたり削除したりして出力する。

### `--enable` が加えるもの

以上から、`--enable <feature-id>` が生成コードに加えるのは次の 3 つである。

1. `features/<feature-id>/` ディレクトリ（その機能のファイルのすべて）
2. `features/enabled.ts` の import 行 1 行と、配列 `features` の項目 1 つ
3. base のパイプラインにある `(feature: <feature-id>)` の所有者付きブロックと、パイプラインの先頭でそのブロックが使う import

`features/enabled.ts` の配列の順序は、フックを適用する順序である。
生成後に機能を手で外すときは、`features/enabled.ts` の 2 行とディレクトリを消すだけでは足りず、その機能の所有者付きブロックと、ブロックが使う import も消す必要がある。

### 機能の登録簿

CLI が知っている機能は、[packages/cli/src/registry.ts](../../../packages/cli/src/registry.ts) の `FEATURE_REGISTRY` に 1 項目ずつ並ぶ。
項目は、`--enable` と `--disable` で使う名前（`features/` の下のディレクトリ名でもある `id`）、生成の既定（`tier`）、その機能のコードが import する機能（`requires`）、生成コードが import するパッケージ（`packages`）、対応するフレームワークと実行環境を持つ。
`tier` は 3 種類で、`stable` は既定で生成し、`experimental` と `extension` は `--enable` で名指ししたときだけ生成する。
experimental の機能はすべて `tier: 'experimental'` で、`packages` に `@maronn-openid-connect/experimental` を挙げる。
import 境界の lint は `requires` をこのファイルから読み、`features/<a>/` が `features/<b>/` を import してよいのは、`a` の項目が `b` を挙げているときに限る。
`features/enabled.ts` に並ぶ機能の順序は、この登録簿の順序である。

### 他フレームワークの生成コード

express と fastify の生成コードも `apps/hono` から抜き出す。
CLI はエンドポイントが import する `hono` のルーターを、Fetch API の小さなルーター `web-router.ts`（`WebRouter` と `WebContext`）に置き換え、フレームワーク向けの `apply.ts`、`web-router.ts`、`node-adapter.ts` を [apps/hono/src/web/](../../../apps/hono/src/web) から加える。
画面は hono/jsx のままなので、これらの生成物も JSX ランタイムとして `hono` を必要とする。

Next.js の生成コードは、Next.js App Router のアプリ [apps/nextjs](../../../apps/nextjs) から抜き出す。
機能のルートファイルはルートグループ `app/(<feature-id>)/` に、それ以外のコードは `app/_oidc-provider/features/<feature-id>/` に置かれる。

### `features/feature.ts` の全文

機能が base に差し込める値はこのファイルが定める型に限られるので、全文を載せる。
hono の生成コードでは、どの機能を有効にしてもこのファイルは同じ内容である（express と fastify では `Hono` が `WebRouter` に置き換わる）。

```typescript
/**
 * What a feature can add to the provider.
 *
 * Each directory under features/ is one feature, and its feature.ts describes
 * it with defineFeature(): the routes it serves, the discovery metadata it
 * advertises, the values it puts into the request context, the defaults it
 * adds to the provider settings, the grants it answers at the token
 * endpoint, the response modes it restores at /consent and the login methods
 * it shows on the login page. These are the hooks; the rest of the provider
 * reads them through the functions below and never imports a feature.
 *
 * Logic that runs inside one of the provider's pipelines is not a hook: the
 * pipeline.ts of that endpoint calls the step of the feature in a block whose
 * marker line names it, `// [step-id] (feature: <id>) Label — Spec`.
 *
 * features/enabled.ts lists the features of this provider. Remove a feature
 * by deleting its directory, its lines there and the owner blocks that name
 * it in the pipelines (with their imports).
 */
import type { Hono } from 'hono';
import type { OidcProviderOptions } from '../app.js';
import type { ProviderConfig } from '../config.js';
import type { AuthorizationResponseModeHandler } from '../endpoints/authorize/response-mode.js';
import type { LoginMethod } from '../endpoints/login/login-method.js';
import type { ProviderStores } from '../store.js';

/** An endpoint a feature serves, mounted by app.ts. */
export interface FeatureRoute {
  /** Where the app is mounted. */
  path: string;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  app: Hono<any>;
  /** The HTTP methods of the path itself; any other one is answered with 405. */
  methods: readonly string[];
  /** The paths below the mount point the app also answers, with their methods. */
  subpaths?: Readonly<Record<string, readonly string[]>>;
  /**
   * 'protected': the CORS policy of the token endpoint (the origins of
   * OidcProviderOptions.corsOrigins). Leave it out for a browser-facing page.
   */
  cors?: 'protected';
}

/** What a context hook can read while the provider sets up a request. */
export interface FeatureContextInput {
  /** The request context, with every value the provider and the features before this one set. */
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  c: any;
  options: OidcProviderOptions;
  stores: ProviderStores;
}

/**
 * The values a feature puts into the request context (c.set) for its own
 * steps. A function runs for every request; a value it returns under a name
 * the provider already set replaces that value.
 */
export type FeatureContext =
  | Readonly<Record<string, unknown>>
  | ((input: FeatureContextInput) => Record<string, unknown> | Promise<Record<string, unknown>>);

export interface Feature {
  /** The id of --enable / --disable. */
  readonly id: string;
  readonly routes?: readonly FeatureRoute[];
  /**
   * Members added to the provider metadata (OIDC Discovery 1.0 §3). An array
   * is merged with the array the provider already advertises under that name;
   * any other value replaces it.
   */
  readonly discovery?: (issuer: string, config: ProviderConfig) => Record<string, unknown>;
  readonly context?: FeatureContext;
  /** Defaults of the provider settings, applied over the defaults of config.ts. */
  readonly config?: Partial<ProviderConfig>;
  readonly token?: {
    /**
     * The grant_type values the feature answers at the token endpoint. The
     * token endpoint accepts them and discovery advertises them
     * (grant_types_supported).
     */
    readonly grants?: readonly string[];
  };
  readonly authorize?: {
    /**
     * Response modes the feature answers in. /consent restores the one the
     * authorization request asked for from the stored transaction.
     */
    readonly responseModes?: readonly AuthorizationResponseModeHandler[];
  };
  /** Ways to sign in that the login page offers next to the password form. */
  readonly loginMethods?: readonly LoginMethod[];
}

/** Describe a feature. The function only checks the shape; it returns its argument. */
export function defineFeature<const F extends Feature>(feature: F): F {
  return feature;
}

export function routesOf(features: readonly Feature[]): FeatureRoute[] {
  return features.flatMap((feature) => feature.routes ?? []);
}

/**
 * The provider metadata with the members of the features added: an array
 * member is merged (each value once, in order), any other member replaced.
 */
export function discoveryOf(
  features: readonly Feature[],
  metadata: Record<string, unknown>,
  issuer: string,
  config: ProviderConfig,
): Record<string, unknown> {
  const merged: Record<string, unknown> = { ...metadata };
  for (const feature of features) {
    for (const [name, value] of Object.entries(feature.discovery?.(issuer, config) ?? {})) {
      const current = merged[name];
      merged[name] = Array.isArray(current) && Array.isArray(value)
        ? [...new Set([...current, ...value])]
        : value;
    }
  }
  return merged;
}

/** Put the context values of the features into the request context, in the order of the features. */
export async function applyContextOf(
  features: readonly Feature[],
  input: FeatureContextInput,
): Promise<void> {
  for (const feature of features) {
    const context = feature.context;
    if (context === undefined) continue;
    const values = typeof context === 'function' ? await context(input) : context;
    for (const [name, value] of Object.entries(values)) {
      input.c.set(name, value);
    }
  }
}

export function configOf(features: readonly Feature[]): Partial<ProviderConfig> {
  return Object.assign({}, ...features.map((feature) => feature.config ?? {}));
}

export function tokenGrantsOf(features: readonly Feature[]): string[] {
  // Two features may answer the same grant_type (token-exchange and id-jag
  // both read the token-exchange URN); it is listed once.
  return [...new Set(features.flatMap((feature) => feature.token?.grants ?? []))];
}

export function responseModesOf(features: readonly Feature[]): AuthorizationResponseModeHandler[] {
  return features.flatMap((feature) => feature.authorize?.responseModes ?? []);
}

export function loginMethodsOf(features: readonly Feature[]): LoginMethod[] {
  return features.flatMap((feature) => feature.loginMethods ?? []);
}
```

各機能が生成コードに加えるコードの全文は、機能別の解説に載せている。
CLI 統合を変更した場合は、生成結果と解説の掲載コードを同じ変更内で更新する。

## パッケージ構成ファイルの全文

パッケージの形を決めている 3 つのファイルを示す。

### package.json

subpath export の定義、peer range、公開対象（`files`）をここで決めている。
`exports` に `.`（ルート）が無いこと、core が `peerDependencies` にあることが、前述の設計の実体である。

```json
{
  "name": "@maronn-openid-connect/experimental",
  "version": "0.0.4",
  "description": "Experimental OAuth/OIDC extensions for maronn-openid-connect (unstable APIs)",
  "type": "module",
  "exports": {
    "./device-authorization-grant": {
      "types": "./dist/device-authorization-grant/index.d.ts",
      "import": "./dist/device-authorization-grant/index.js"
    },
    "./jarm": {
      "types": "./dist/jarm/index.d.ts",
      "import": "./dist/jarm/index.js"
    },
    "./par": {
      "types": "./dist/par/index.d.ts",
      "import": "./dist/par/index.js"
    },
    "./token-exchange": {
      "types": "./dist/token-exchange/index.d.ts",
      "import": "./dist/token-exchange/index.js"
    }
  },
  "files": [
    "dist",
    "LICENSE",
    "README.md"
  ],
  "publishConfig": {
    "access": "public"
  },
  "scripts": {
    "build": "tsc",
    "test": "vitest run",
    "test:ci": "vitest run",
    "test:watch": "vitest",
    "typecheck": "tsc --noEmit"
  },
  "keywords": [
    "openid-connect",
    "oauth2.1",
    "experimental"
  ],
  "author": "maronnjapan",
  "license": "MIT",
  "repository": {
    "type": "git",
    "url": "git+https://github.com/maronnjapan/maronn-openid-connect.git",
    "directory": "packages/experimental"
  },
  "bugs": {
    "url": "https://github.com/maronnjapan/maronn-openid-connect/issues"
  },
  "homepage": "https://github.com/maronnjapan/maronn-openid-connect/tree/main/packages/experimental#readme",
  "peerDependencies": {
    "@maronn-openid-connect/core": ">=0.1.1 <1.0.0"
  },
  "devDependencies": {
    "@edge-runtime/vm": "^5.0.0",
    "@maronn-openid-connect/core": "workspace:*",
    "@types/node": "^26.1.2",
    "typescript": "^5.7.2",
    "vitest": "^3.2.6"
  }
}
```

### tsconfig.json

core と同じく NodeNext でビルドし、`"type": "module"` のパッケージとして Node の ESM ローダで解決できる形で emit する。
テストとテスト専用フィクスチャは exclude してあり、配布物（`dist`）に載らない。

```jsonc
{
  "compilerOptions": {
    // Language and Environment
    "target": "ES2022",
    "lib": [
      "ES2022"
    ],
    // core と同じ理由で NodeNext を使う（相対 import の拡張子を必須にして、
    // "type": "module" の package が Node の ESM ローダで解決できる形で emit されるようにする）。
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    // Emit
    "declaration": true,
    "declarationMap": true,
    "sourceMap": true,
    "rootDir": "./src",
    "outDir": "./dist",
    "removeComments": true,
    // Interop Constraints
    "isolatedModules": true,
    "esModuleInterop": true,
    "forceConsistentCasingInFileNames": true,
    "allowSyntheticDefaultImports": true,
    // Type Checking
    "strict": true,
    "noUnusedLocals": true,
    "noUnusedParameters": true,
    "noFallthroughCasesInSwitch": true,
    "noUncheckedIndexedAccess": true,
    "noImplicitReturns": true,
    "skipLibCheck": true
  },
  "include": [
    "src/**/*"
  ],
  "exclude": [
    "node_modules",
    "dist",
    "**/*.test.ts",
    "**/*.spec.ts",
    // テスト専用フィクスチャ。dist へ出すと公開 package に未使用コードが載るため除外する。
    "**/test-helpers.ts"
  ]
}
```

### vitest.config.ts

テストは Edge Runtime 環境（Web 標準 API のみ）で実行する。
experimental の機能も Portability の方針（JavaScript が動く環境ならどこでも動く）から外れないことを、テスト環境の選択で保証している。
core への alias はソース直結で、core を先にビルドしなくてもテストが起動する。

```typescript
import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vitest/config';

export default defineConfig({
  resolve: {
    alias: {
      // core のソースを直接解決する。workspace リンクは package.json の
      // main（./dist/index.js）を指すため、そのままだと core を先にビルドしないと
      // テストが起動しない（ルートの test:ci はビルドを挟まない）。
      '@maronn-openid-connect/core': fileURLToPath(new URL('../core/src/index.ts', import.meta.url)),
    },
  },
  test: {
    // packages/core と同じ Edge Runtime 環境（Web標準APIのみ）でテストする。
    // Experimental 機能も Portability の方針（どこでも動く）から外れないことを保証する。
    environment: 'edge-runtime',
    globals: false,
    coverage: {
      provider: 'v8',
      reporter: ['text', 'json', 'html'],
      exclude: [
        'node_modules/',
        'dist/',
        '**/*.test.ts',
        '**/*.spec.ts',
      ],
    },
    include: ['src/**/*.{test,spec}.{js,ts}'],
  },
});
```

## リリースと changeset の自動化

experimental のリリースは「`packages/experimental/src` が変わったら patch を 1 つ上げて publish する」という機械的な運用で回す。
main への push を契機に CI が patch の changeset を自動生成する（`.github/scripts/ensure-experimental-changeset.mjs`）ため、experimental の変更に対して changeset を手で書いてはならない。
minor / major を指定した手書き changeset は `pnpm run test:release-contract` が CI で落とす。
背景と事故例を含む詳細は [RELEASE.md](../../../RELEASE.md) の「バージョニング方針」と「experimental の自動 publish」にある。

## 昇格の判断材料

experimental の機能を experimental から外してよいか（core へ昇格させてよいか）は、人間のレビュアーが判断する。
レビュアーは実装、テスト、Conformance の結果、利用者向けドキュメント、実装解説を確認し、notes リポジトリへ判断を記録する。

## 関連資料

- 利用者向けドキュメント：[docs/library-document の Experimental セクション](../../library-document/src/content/docs/experimental/index.md)
- パッケージの README：[packages/experimental/README.md](../../../packages/experimental/README.md)
- 変更履歴：[packages/experimental/CHANGELOG.md](../../../packages/experimental/CHANGELOG.md)
- 機能別の実装解説：[par](./par.ja.md) / [token-exchange](./token-exchange.ja.md) / [jarm](./jarm.ja.md) / [device-authorization-grant](./device-authorization-grant.ja.md)
