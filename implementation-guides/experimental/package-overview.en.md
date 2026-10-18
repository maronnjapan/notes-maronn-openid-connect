# The packages/experimental Package: an Overview

This document explains the `@maronn-openid-connect/experimental` package itself: why it exists, the design conventions shared by every feature in it, and how it is built and released.
The implementation of each individual feature (PAR, Token Exchange, JARM, Device Authorization Grant) is covered, with complete source code, in the per-feature guides.

Note on language: the source files embedded throughout these guides carry Japanese comments, because Japanese is the repository's primary documentation language.
The English prose in each guide conveys the same information as those comments, so you can read the guides without reading Japanese.

## Why this package exists

This repository aims to let developers verify the newest OIDC/OAuth specifications faster than anywhere else, faithfully, in any JavaScript runtime.
Chasing new specifications at that speed is incompatible with the API-stability promise that `@maronn-openid-connect/core` makes, so unstable implementations need a home of their own.
**packages/experimental** is that home: a separate package that collects implementations whose APIs are not yet stable.

The separation of core and experimental is also a separation of promises to users.
The core version number is treated as a stability signal, while experimental is published faster than core under a mechanical rule: every release bumps patch by one, no matter what changed.
Since the version number does not express compatibility, compatibility information that users need is written in the CHANGELOG and README instead.

## Features and import paths

Four features are implemented, each exposed as its own subpath export.

| feature-id | What it is | Spec | Import from |
|---|---|---|---|
| `par` | Pushed Authorization Requests | RFC 9126 | `@maronn-openid-connect/experimental/par` |
| `token-exchange` | OAuth 2.0 Token Exchange (impersonation and delegation) | RFC 8693 | `@maronn-openid-connect/experimental/token-exchange` |
| `jarm` | JWT Secured Authorization Response Mode (signed `query.jwt` only) | JARM (OpenID Foundation Final, 2022-11-09) | `@maronn-openid-connect/experimental/jarm` |
| `device-authorization-grant` | OAuth 2.0 Device Authorization Grant | RFC 8628 | `@maronn-openid-connect/experimental/device-authorization-grant` |

There is no root (`.`) re-export.
Features share no code with each other, so promoting one to core, or deleting one, never affects the others.
Even test fixtures are shared only inside a feature directory (the `test-helpers.ts` of device-authorization-grant is the one example; the tsconfig excludes it from the published artifact).

## Design conventions shared by every feature

The four features are implemented independently, but they follow the same conventions.
Keeping these in mind makes the individual decisions in each per-feature guide easier to follow.

- **Two layers: step functions and a composition function.** Processing is split into step functions, one per unit of spec validation, plus a composition function that merely calls them in spec order. The CLI emits generated code that calls the step functions one by one, so users can replace or delete individual validations in their generated code.
- **Core stays untouched.** No core code is modified for the sake of an experimental feature. Where core's closed error enums cannot express a code the spec needs, the feature defines its own error class (`ParError`, `TokenExchangeError`, `DeviceAuthorizationError`, and so on).
- **No oracles.** When resolving a credential or reference value fails, the response uses a single fixed message that does not distinguish the failure reason. PAR's `request_uri`, Token Exchange's `subject_token`, and the device flow's `user_code` and `device_code` all follow this policy, so responses never confirm whether a value exists.
- **Sanitized error descriptions.** Every error message passes through core's `sanitizeErrorDescription`, restricting it to the safe character set of RFC 6749 §5.2.
- **Single use is enforced by the store contract.** Values that must be used exactly once (PAR's `request_uri`, the device flow's `device_code`) are retrievable only through `consume`, which fetches and deletes atomically. A read-only accessor is deliberately absent from the contract, so single use is enforced at the type level.
- **Injectable clocks.** Every function that computes an expiry accepts `now?: Date`, so tests can verify deadline behavior deterministically.

## Dependency direction and the relationship with core

The dependency direction is fixed and one-way.

```text
packages/cli ────> @maronn-openid-connect/experimental (declared as a dependency of generated code)
@maronn-openid-connect/experimental ────> @maronn-openid-connect/core (allowed)
packages/core ──X──> packages/experimental (forbidden)
```

Core is a `peerDependency` of experimental, not a `dependency`.
Experimental checks core's error classes with `instanceof` and passes resolvers and stores back and forth with generated code, so the whole application must contain exactly one instance of core.
If core were a `dependency`, it would be installed twice, `instanceof` would silently become false, and situations that should return `invalid_request` would surface as 500s.
The peer range (currently `>=0.1.1 <1.0.0`) declares a lower bound, the minimum core that experimental actually requires; it does not demand matching version numbers.
CI verifies the lower bound mechanically (`.github/scripts/verify-release-contract.mjs`).

## How the CLI integration works

Users reach the experimental features through the CLI.
Only when they run `maronn-oidc generate <framework> --enable <feature-id>` does the generated code gain that feature's code, and only then does the generated project depend on the experimental package.
A default generation never references experimental at all.

### The app the generated code is extracted from

`maronn-oidc generate` does not assemble the generated code from templates; it copies code out of a running app.
The source is `src/oidc-provider/` of [apps/hono](../../../apps/hono), an OP that runs with every feature enabled and that the per-PR E2E suite runs against.
[packages/cli/extract.json](../../../packages/cli/extract.json) defines which directories become the output of which framework; the CLI build copies those directories into the CLI package and gathers the meta of their steps and endpoints into a catalog.
`generate` selects the files of the enabled features from that copy, removes the code of the disabled ones, and writes the result ([packages/cli/src/generate.ts](../../../packages/cli/src/generate.ts)).
Test files (`*.test.ts`, `*.test.tsx`) are not copied, so the generated output contains none.

The hono output is laid out as follows.

```text
app.ts  apply.ts  config.ts  store.ts  resolvers.ts  views.tsx  cors.ts  cookies.ts  scopes.ts  development.ts
db/                         the database (the kind chosen with --db)
pages/                      the error pages and response helpers
endpoints/<endpoint>/
  pipeline.ts               calls the steps of the endpoint in order
  steps/<step>.ts           one file per step
  endpoint.ts               the meta the maronn-oidc graph diagram is drawn from
features/
  feature.ts                defineFeature() and the types of the hooks
  enabled.ts                the list of enabled features
  <feature-id>/             everything that feature owns
```

### The boundary between the base and the features

Every file of the app belongs, by its path, to the base, to one feature, or to one database kind.
Files under `features/<feature-id>/` belong to that feature, files under `db/<kind>/` to that database kind (memory, sql, kv), and everything else is the base.
The base imports neither `features/<feature-id>/` nor the experimental package, a boundary that `pnpm run lint` (`.github/scripts/lint-import-boundaries.mjs`) checks.
A feature plugs into the base in exactly two ways: through the hooks of `features/feature.ts`, and through owner blocks in the base pipelines.

Hooks are declarative values that the base reads at fixed places.
The `feature.ts` of each feature declares the feature with `defineFeature({...})`, giving values to a fixed set of hooks:

- **routes**: the endpoints the feature serves. `app.ts` mounts them; the entry also declares the methods of the path (any other is answered with 405), the paths below it with their methods (`subpaths`), and whether it takes the CORS policy of the token endpoint (`cors: 'protected'`)
- **discovery**: members added to the provider metadata. An array value is merged with the base array; any other value replaces it
- **context**: values put into the request context (`c.set`) for the feature's own steps
- **config**: defaults of the provider settings, applied over the defaults of `config.ts`
- **token.grants**: the `grant_type` values answered at the token endpoint; they are also added to `grant_types_supported` in discovery
- **authorize.responseModes**: the response modes the feature answers in; `/consent` uses them to restore, from the stored transaction, the mode the authorization request asked for
- **loginMethods**: ways to sign in that the login page offers next to the password form

The base reads them through the functions of `features/feature.ts` (`routesOf()`, `discoveryOf()`, `applyContextOf()`, `configOf()`, `tokenGrantsOf()`, `responseModesOf()`, `loginMethodsOf()`) and never imports a feature.
The options, settings and screens a feature takes are added to the base types by module augmentation from the feature's directory (`declare module '../../app.js'`, `'../../config.js'`, `'../../views.js'`).

Logic that runs in the middle of a base pipeline is not a hook.
The step function of that logic lives in the feature's directory, and its call sits in the base `pipeline.ts` as a block that starts with a marker comment naming the feature.
This is the block PAR places in the pipeline of the authorization endpoint:

```typescript
    // [resolve-pushed-request] (feature: par) Expand the pushed request_uri — RFC 9126 §4 / §5
    params = await resolvePushedAuthorizationRequest(c, params);
```

A block runs from its marker line to the line before the next marker, and is called an **owner block**.
When a feature is disabled, the CLI deletes the feature's blocks and the imports only those blocks used.
A value such a block defined that later code still reads is left as `const <name> = undefined;`, and a binding nothing reads any more is dropped.
This logic is not a hook because its position in the pipeline matters.
Each block is one box of the `maronn-oidc graph` diagram, and when a `--flow` document reorders or leaves out steps, the CLI reorders or deletes the blocks to match.

### What `--enable` adds

It follows that `--enable <feature-id>` adds exactly three things to the generated code:

1. the directory `features/<feature-id>/` (every file of the feature)
2. one import line and one entry of the array `features` in `features/enabled.ts`
3. the `(feature: <feature-id>)` owner blocks of the base pipelines, and the imports those blocks use at the top of each pipeline

The order of the array in `features/enabled.ts` is the order in which the hooks apply.
Removing a feature by hand after generating takes more than deleting its two lines in `features/enabled.ts` and its directory: its owner blocks and the imports they use must go too.

### The feature registry

The features the CLI knows are listed one entry each in `FEATURE_REGISTRY` of [packages/cli/src/registry.ts](../../../packages/cli/src/registry.ts).
An entry holds the name used with `--enable` and `--disable` (`id`, which is also the directory name under `features/`), whether it is generated by default (`tier`), the features its code imports (`requires`), the packages its generated code imports (`packages`), and the frameworks and runtimes it supports.
There are three tiers: `stable` is generated by default, while `experimental` and `extension` are generated only when named with `--enable`.
Every experimental feature has `tier: 'experimental'` and lists `@maronn-openid-connect/experimental` in `packages`.
The import-boundary lint reads `requires` from this file: `features/<a>/` may import `features/<b>/` only when the entry of `a` lists `b`.
The features in `features/enabled.ts` appear in the order of this registry.

### The other frameworks

The express and fastify outputs are extracted from `apps/hono` as well.
The CLI replaces the `hono` router the endpoints import with `web-router.ts`, a small Fetch-API router (`WebRouter` and `WebContext`), and adds the framework's `apply.ts`, `web-router.ts` and `node-adapter.ts` from [apps/hono/src/web/](../../../apps/hono/src/web).
The screens stay hono/jsx, so those outputs need `hono` as their JSX runtime.

The Next.js output is extracted from [apps/nextjs](../../../apps/nextjs), a Next.js App Router app.
A feature's route files live in the route group `app/(<feature-id>)/`, and the rest of its code in `app/_oidc-provider/features/<feature-id>/`.

### `features/feature.ts`, in full

The values a feature can plug into the base are limited to the types this file defines, so it is embedded in full.
In the hono output the file is the same whichever features are enabled (in the express and fastify outputs, `Hono` is replaced with `WebRouter`).

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

Each feature guide embeds the complete code that the feature adds to the generated output.
When the CLI integration changes, the generated result and the embedded guide code must be updated in the same change.

## The package configuration files, in full

Three files determine the shape of the package.

### package.json

The subpath exports, the peer range, and the published file set (`files`) are all decided here.
The absence of a `.` (root) entry in `exports` and the placement of core under `peerDependencies` are the concrete form of the design described above.

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

Like core, the package builds with NodeNext so that a `"type": "module"` package emits files the Node ESM loader can resolve.
Tests and test-only fixtures are excluded and never reach the published `dist`.

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

Tests run in an Edge Runtime environment, which offers Web standard APIs only.
That choice guarantees experimental features stay inside the repository's portability policy (run anywhere JavaScript runs).
The alias resolves core to its sources directly, so tests start without building core first.

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

## Releases and changeset automation

Experimental releases follow one mechanical rule: when `packages/experimental/src` changes, bump patch by one and publish.
CI generates the patch changeset automatically on pushes to main (`.github/scripts/ensure-experimental-changeset.mjs`), so changesets for experimental changes must never be written by hand.
A handwritten changeset that bumps experimental by minor or major fails `pnpm run test:release-contract` in CI.
The background, including a real incident that motivated the peer-range rule, is documented in [RELEASE.md](../../../RELEASE.md) under the versioning-policy and experimental-auto-publish sections.

## Promotion decisions

Whether a feature may leave experimental (be promoted into core) is decided by a human reviewer.
The reviewer examines the implementation, tests, Conformance results, user documentation, and implementation guide, then records the decision in the notes repository.

## Related material

- User-facing documentation: [the Experimental section of docs/library-document](../../library-document/src/content/docs/experimental/index.md)
- Package README: [packages/experimental/README.md](../../../packages/experimental/README.md)
- Change history: [packages/experimental/CHANGELOG.md](../../../packages/experimental/CHANGELOG.md)
- Per-feature implementation guides: [par](./par.en.md) / [token-exchange](./token-exchange.en.md) / [jarm](./jarm.en.md) / [device-authorization-grant](./device-authorization-grant.en.md)
- 日本語版: [package-overview.ja.md](./package-overview.ja.md)
