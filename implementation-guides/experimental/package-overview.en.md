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
Only when they run `maronn-oidc generate <framework> --enable <feature-id>` does the generated code gain that feature's routes and branches, and only then does the generated project depend on the experimental package.
A default generation never references experimental at all.

The feature registry lives in `packages/cli/src/features.ts`.
Adding a feature-id to `EXPERIMENTAL_FEATURES` and mapping it to an `OidcFeatureConfig` flag makes it available to the CLI's `--enable` resolution.
This file is the single source of truth for the experimental integration, so it is embedded here in full.

```typescript
/**
 * Feature toggles for the generated OpenID Connect Provider.
 *
 * The default generation output enables every feature (the full Basic OP +
 * optional endpoints). Users can remove features from the default with
 * `--disable`, and explicitly (re-)enable them with `--enable`.
 *
 * Basic OP mandatory capabilities (authorize / token / userinfo / discovery /
 * jwks / login / consent) are not toggleable and are always generated.
 *
 * Optional features are stable core capabilities that are nonetheless NOT part
 * of the default output, because the spec does not require them. Experimental
 * features are a third category: they live in the separate experimental package
 * and their APIs are unstable. Both must be requested explicitly with
 * `--enable`.
 */

/** CLI-facing feature names (kebab-case, used with --enable / --disable). */
export const AVAILABLE_FEATURES = [
  'pkce',
  'refresh-token',
  'introspection',
  'revocation',
  'request-object',
] as const;

export type FeatureName = (typeof AVAILABLE_FEATURES)[number];

/**
 * Optional feature names (kebab-case, used with --enable).
 *
 * Stable, implemented in `@maronn-openid-connect/core` — but **disabled by
 * default** because no OIDC Core / OAuth 2.1 clause requires them. The default
 * generation output is meant to be the specification and nothing more, so a
 * user verifying "does the spec allow X?" is never answered by this library's
 * own hardening opinions. Turn one on to study the hardening itself.
 *
 * - transaction-binding: bind the authorization transaction to the User-Agent
 *   that started it, via a per-transaction HttpOnly cookie
 *   (OIDC Core 1.0 §3.1.2.3 / §3.1.2.4 leave the mechanism to the
 *   implementation). Costs a cookie jar: driving login / consent by hand with
 *   curl requires carrying the cookie, which is why it is not the default.
 */
export const OPTIONAL_FEATURES = ['transaction-binding'] as const;

export type OptionalFeatureName = (typeof OPTIONAL_FEATURES)[number];

/**
 * Experimental feature names (kebab-case, used with --enable).
 *
 * Unlike AVAILABLE_FEATURES these are **disabled by default** and are only
 * generated when named explicitly with `--enable`. They are implemented in the
 * separate `@maronn-openid-connect/experimental` package, whose API is unstable and may
 * change in a breaking way between releases.
 *
 * - par: Pushed Authorization Requests (RFC 9126).
 * - token-exchange: OAuth 2.0 Token Exchange (RFC 8693), impersonation and
 *   delegation (act claim per §4.1).
 * - jarm: JWT Secured Authorization Response Mode (JARM), signed query.jwt only.
 * - device-authorization-grant: OAuth 2.0 Device Authorization Grant (RFC 8628).
 */
export const EXPERIMENTAL_FEATURES = [
  'par',
  'token-exchange',
  'jarm',
  'device-authorization-grant',
] as const;

export type ExperimentalFeatureName = (typeof EXPERIMENTAL_FEATURES)[number];

/**
 * Resolved feature configuration passed through the generator pipeline.
 *
 * - pkce: when false, the generated config defaults to
 *   `allowNonPkceAuthorizationCodeFlow: true` (PKCE optional for explicit
 *   confidential clients; public clients still require it).
 * - refreshToken: when false, the token endpoint rejects the refresh_token
 *   grant with `unsupported_grant_type`, offline_access is never granted, and
 *   no refresh token is issued or persisted.
 * - introspection: when false, the RFC 7662 endpoint is not generated.
 * - revocation: when false, the RFC 7009 endpoint is not generated.
 * - requestObject: when false, the authorize endpoint rejects the `request`
 *   parameter with `request_not_supported` (OIDC Core 1.0 §6.3).
 * - par: experimental, disabled by default. When true, the PAR endpoint
 *   (RFC 9126) is generated and the authorize route resolves URN-form
 *   `request_uri` values through `@maronn-openid-connect/experimental/par`.
 * - tokenExchange: experimental, disabled by default. When true, the token
 *   route dispatches the `urn:ietf:params:oauth:grant-type:token-exchange`
 *   grant (RFC 8693) to `@maronn-openid-connect/experimental/token-exchange` before
 *   core's grant_type validation would reject the URN.
 * - jarm: experimental, disabled by default. When true, the authorize route
 *   interprets `response_mode=query.jwt` (and its `jwt` shorthand) and returns
 *   the authorization response as a single signed JWT in the `response` query
 *   parameter, via `@maronn-openid-connect/experimental/jarm`. A request that
 *   does not ask for a JWT response mode is answered exactly as before.
 * - deviceAuthorizationGrant: experimental, disabled by default. When true, the
 *   OP additionally serves the device authorization endpoint
 *   (POST /device_authorization), the verification UI (/device, /device/login,
 *   /device/approve) and dispatches the
 *   `urn:ietf:params:oauth:grant-type:device_code` grant (RFC 8628) to
 *   `@maronn-openid-connect/experimental/device-authorization-grant` before
 *   core's grant_type validation would reject the URN.
 * - transactionBinding: optional hardening, disabled by default. When true, the
 *   authorize endpoint issues a per-transaction HttpOnly cookie and the
 *   login / consent steps refuse to run for a User-Agent that cannot present
 *   it, so a leaked `transaction_id` alone drives no step of the flow.
 */
export interface OidcFeatureConfig {
  pkce: boolean;
  refreshToken: boolean;
  introspection: boolean;
  revocation: boolean;
  requestObject: boolean;
  par: boolean;
  tokenExchange: boolean;
  jarm: boolean;
  deviceAuthorizationGrant: boolean;
  transactionBinding: boolean;
}

/** Mapping from CLI feature names to OidcFeatureConfig keys. */
const FEATURE_KEYS: Record<FeatureName, keyof OidcFeatureConfig> = {
  pkce: 'pkce',
  'refresh-token': 'refreshToken',
  introspection: 'introspection',
  revocation: 'revocation',
  'request-object': 'requestObject',
};

/** Mapping from CLI optional feature names to OidcFeatureConfig keys. */
const OPTIONAL_FEATURE_KEYS: Record<OptionalFeatureName, keyof OidcFeatureConfig> = {
  'transaction-binding': 'transactionBinding',
};

/** Mapping from CLI experimental feature names to OidcFeatureConfig keys. */
const EXPERIMENTAL_FEATURE_KEYS: Record<ExperimentalFeatureName, keyof OidcFeatureConfig> = {
  par: 'par',
  'token-exchange': 'tokenExchange',
  jarm: 'jarm',
  'device-authorization-grant': 'deviceAuthorizationGrant',
};

/**
 * Default: every stable feature enabled (matches the historical generation
 * output), every optional and experimental feature disabled.
 */
export const DEFAULT_FEATURES: OidcFeatureConfig = {
  pkce: true,
  refreshToken: true,
  introspection: true,
  revocation: true,
  requestObject: true,
  par: false,
  tokenExchange: false,
  jarm: false,
  deviceAuthorizationGrant: false,
  transactionBinding: false,
};

function isOptionalFeature(name: string): name is OptionalFeatureName {
  return (OPTIONAL_FEATURES as readonly string[]).includes(name);
}

function isExperimentalFeature(name: string): name is ExperimentalFeatureName {
  return (EXPERIMENTAL_FEATURES as readonly string[]).includes(name);
}

function assertKnownFeature(
  name: string,
): asserts name is FeatureName | OptionalFeatureName | ExperimentalFeatureName {
  if (
    !(AVAILABLE_FEATURES as readonly string[]).includes(name) &&
    !isOptionalFeature(name) &&
    !isExperimentalFeature(name)
  ) {
    throw new Error(
      `Unknown feature: "${name}". Available features: ${AVAILABLE_FEATURES.join(', ')}. ` +
        `Optional features (disabled by default): ${OPTIONAL_FEATURES.join(', ')}. ` +
        `Experimental features (disabled by default): ${EXPERIMENTAL_FEATURES.join(', ')}`,
    );
  }
}

function featureKey(
  name: FeatureName | OptionalFeatureName | ExperimentalFeatureName,
): keyof OidcFeatureConfig {
  if (isOptionalFeature(name)) return OPTIONAL_FEATURE_KEYS[name];
  return isExperimentalFeature(name) ? EXPERIMENTAL_FEATURE_KEYS[name] : FEATURE_KEYS[name];
}

/**
 * Resolve CLI --enable / --disable lists into an OidcFeatureConfig,
 * starting from DEFAULT_FEATURES.
 *
 * @throws {Error} on an unknown feature name, or a feature listed in both
 *   enable and disable.
 */
export function resolveFeatures(options: {
  enable?: string[];
  disable?: string[];
}): OidcFeatureConfig {
  const enable = options.enable ?? [];
  const disable = options.disable ?? [];

  for (const name of [...enable, ...disable]) {
    assertKnownFeature(name);
  }

  for (const name of enable) {
    if (disable.includes(name)) {
      throw new Error(`Feature "${name}" cannot be both enabled and disabled`);
    }
  }

  const features: OidcFeatureConfig = { ...DEFAULT_FEATURES };
  for (const name of enable) {
    assertKnownFeature(name);
    features[featureKey(name)] = true;
  }
  // An optional / experimental feature listed in --disable is already off by
  // default, so this is a no-op rather than an error (same as omitting it).
  for (const name of disable) {
    assertKnownFeature(name);
    features[featureKey(name)] = false;
  }
  return features;
}
```

Each feature guide embeds the complete code that the feature contributes to generated output.
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
