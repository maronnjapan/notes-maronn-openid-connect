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
`maronn-oidc generate <framework> --enable <feature-id>` と明示したときだけ、生成コードに該当機能のルートや分岐が注入され、生成物が experimental パッケージへ依存するようになる。
デフォルト生成では experimental は一切参照されない。

機能の登録簿は `packages/cli/src/features.ts` にある。
`EXPERIMENTAL_FEATURES` に feature-id を追加し、`OidcFeatureConfig` のフラグへ対応づけると、CLI の `--enable` 解決対象に入る。
このファイルは experimental 統合の唯一の情報源なので、全文を載せる。

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

各機能が生成コードへ注入するコードの全文は、機能別の解説に載せている。
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
