# Implementation guide: the CLI overwrite guard and generation manifest

This guide covers the command entry point of `@maronn-openid-connect/cli` (`packages/cli/src/index.ts`) with its CLI tests, the regeneration scripts of the four samples, and the CLI guide documentation.
Implemented from the OSS repository task `tasks/done/p2-cli-generate-overwrite-guard.md`.

## What the feature does

`maronn-oidc generate` / `maronn-oidc setup` used to write into the output directory without checking for existing files.
Even when an existing file was clobbered, the log always printed `Created:`, so the user never learned that an overwrite had happened.
The generated output also carried no record of which CLI version and which feature configuration produced it, so a user trying to pick up a template fix had no starting point for a diff.

With this change, the CLI writes as follows.

- If even one file with a generated name already exists in the output directory, the CLI aborts with exit code 1, listing those files, **without writing a single byte**
- Only an explicit `--force` overwrites, and the log distinguishes new files (`Created:`) from overwritten ones (`Overwritten:`)
- `--dry-run` writes nothing and lists every planned file as `Would create:` / `Would overwrite:`
- The output gains a **manifest** (`.maronn-openid-connect.json`) recording the generating CLI version (`cliVersion`), the framework, the feature configuration (`features`) and the custom scopes (`scopes`)

`setup` wires the entry file only after generation finishes, so an aborted generation never reaches the patch step.
The guard applies to both commands in the same shape.

## Use cases

The first use case is protecting customized generated code.
Customizing the generated code is officially supported, and `config.ts` (issuer, client definitions) and `store.ts` (the persistence implementation) almost certainly become the user's own assets.
The guard prevents a mistyped `-o` or a re-run with different feature flags from silently destroying those assets.

The second use case is deciding whether to pick up a template fix.
This library continuously lands specification fixes (many of them security fixes) in its templates, but without a record of the generating version, a user cannot tell which range of changes to diff.
Matching the manifest's `cliVersion` against the release notes gives that starting point.

## Design decisions

### Refusing is the default

Overwriting by default with a warning was an option; refusing by default was chosen instead.
An overwrite accident can be unrecoverable (especially outside Git), while getting past the refusal costs one `--force` flag.
The asymmetry of what each side loses argues for the safe default.

The refusal message includes the list of existing files, the two ways out (`--force`, `-o <dir>`), and the advice to commit before overwriting.

```
Error: 3 file(s) already exist in ./oidc-provider:
  config.ts
  store.ts
  routes/token.ts

Re-run with --force to overwrite them, or use -o <dir> to generate into a new directory.
Tip: commit the generated files before overwriting so you can diff your changes.
```

### A manifest file, not header comments

Recording the generating version could go into a header comment on every generated file, or into a single separate manifest file.
The header-comment approach would break every existing test that pins template output, so the manifest approach was chosen.
No generated file changes by a single byte, and the existing output-pinning tests keep passing.

### The manifest is written by the CLI layer, not the generator API

Manifest writing lives in `run()` (the CLI command handler), and the return value of `generate()` (the programmatic API) does not include it.
Callers of `generate()` pass the framework and features themselves; only CLI users, who cannot later reconstruct what they ran, need the record.
This placement leaves `generator.test.ts` and the per-framework file-list tests untouched.

### The manifest is exempt from the guard and always refreshed

The manifest is machine-written, not a file the user edits.
Its presence therefore never arms the guard, and every run that writes files also rewrites it.
When only the manifest remains in the output directory, a re-run without `--force` is not refused.

### No timestamp

The manifest records only `cliVersion` / `framework` / `features` / `scopes`, with no generation timestamp.
The same inputs must keep producing byte-identical output, and this determinism is also what this repository's own "regenerate the samples and confirm a clean diff" verification relies on.

### The sample regeneration scripts assume `--force`

The `generate` scripts of `samples/*` regenerate into committed output directories, so after the guard they always hit existing files.
`--force` was appended to all four scripts, and regeneration was confirmed to still complete in one command.
Regeneration now produces a manifest in each sample, committed as part of the generated output.

### Semver

A minor bump of `@maronn-openid-connect/cli`.
The `--force` / `--dry-run` options and the manifest are feature additions.
Refusing a re-run into a non-empty directory is a behavior change, but it removes an accidental behavior (unintended overwrites) and is not treated as breaking.

## CLI changes

### packages/cli/src/index.ts: constants and version lookup

The manifest filename and the CLI's own version are fixed at the top of the module.
The version is read from the package's own `package.json`.
Both `src/` and `dist/` sit one level below the package root, so `../package.json` resolves to the same file from either build state.

```typescript
import { createRequire } from 'node:module';
```

```typescript
/**
 * Manifest recording which CLI version and which inputs produced the output,
 * so a user can later diff their code against the release that generated it.
 * It is machine-written, never user-edited, so it is exempt from the overwrite
 * guard and refreshed on every (non-dry-run) generation.
 */
const MANIFEST_FILENAME = '.maronn-openid-connect.json';

// src/ and dist/ both sit one level below the package root, so ../package.json
// resolves to this package's own manifest from either build state.
const CLI_VERSION: string = (
  createRequire(import.meta.url)('../package.json') as { version: string }
).version;
```

### packages/cli/src/index.ts: parseArgs

Two boolean flags, `--force` and `--dry-run`, were added.

```typescript
function parseArgs(args: string[]): {
  command?: string;
  framework?: string;
  outputDir: string;
  entryFile: string;
  enable: string[];
  disable: string[];
  scope: string[];
  force: boolean;
  dryRun: boolean;
  help: boolean;
} {
  let command: string | undefined;
  let framework: string | undefined;
  let outputDir = './oidc-provider';
  let entryFile = './src/index.ts';
  const enable: string[] = [];
  const disable: string[] = [];
  // Kept raw here; splitting and validation are resolveCustomScopes()'s job.
  const scope: string[] = [];
  let force = false;
  let dryRun = false;
  let help = false;

  const splitFeatureList = (value: string | undefined): string[] =>
    (value ?? '').split(',').map((f) => f.trim()).filter((f) => f.length > 0);

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === '--help' || arg === '-h') {
      help = true;
    } else if (arg === '--output' || arg === '-o') {
      i++;
      outputDir = args[i] ?? outputDir;
    } else if (arg === '--entry' || arg === '-e') {
      i++;
      entryFile = args[i] ?? entryFile;
    } else if (arg === '--enable') {
      i++;
      enable.push(...splitFeatureList(args[i]));
    } else if (arg === '--disable') {
      i++;
      disable.push(...splitFeatureList(args[i]));
    } else if (arg === '--scope') {
      i++;
      const value = args[i];
      if (value !== undefined) scope.push(value);
    } else if (arg === '--force') {
      force = true;
    } else if (arg === '--dry-run') {
      dryRun = true;
    } else if (!command) {
      command = arg;
    } else if (!framework) {
      framework = arg;
    }
  }

  return { command, framework, outputDir, entryFile, enable, disable, scope, force, dryRun, help };
}
```

The help text (`printUsage`) gained two lines in the options list.

```
  --force               Overwrite files that already exist in the output directory
  --dry-run             Show what would be written without writing anything
```

### packages/cli/src/index.ts: manifest building, existence detection and printing

Four functions carry the pre-write decisions and output, and `writeGeneratedFiles` now labels each write by whether the file existed.

```typescript
function buildManifestFile(
  framework: string,
  features: OidcFeatureConfig,
  scopes: string[],
): { path: string; content: string } {
  // No timestamp: the same inputs must keep producing byte-identical output.
  const manifest = { cliVersion: CLI_VERSION, framework, features, scopes };
  return { path: MANIFEST_FILENAME, content: `${JSON.stringify(manifest, null, 2)}\n` };
}

/** Planned paths that already exist on disk, in generation order. */
function findExistingFiles(outputDir: string, files: Array<{ path: string }>): string[] {
  return files.map((file) => file.path).filter((path) => existsSync(join(outputDir, path)));
}

function printOverwriteRefusal(outputDir: string, existingPaths: string[]): void {
  console.error(`Error: ${existingPaths.length} file(s) already exist in ${outputDir}:`);
  for (const path of existingPaths) {
    console.error(`  ${path}`);
  }
  console.error('');
  console.error(
    'Re-run with --force to overwrite them, or use -o <dir> to generate into a new directory.',
  );
  console.error('Tip: commit the generated files before overwriting so you can diff your changes.');
}

function printDryRunPlan(outputDir: string, files: Array<{ path: string }>): void {
  console.log(`Dry run: nothing was written. Planned output in ${outputDir}:`);
  for (const file of files) {
    const label = existsSync(join(outputDir, file.path)) ? 'Would overwrite' : 'Would create';
    console.log(`  ${label}: ${file.path}`);
  }
}

function writeGeneratedFiles(outputDir: string, files: Array<{ path: string; content: string }>): void {
  for (const file of files) {
    const fullPath = join(outputDir, file.path);
    const dir = dirname(fullPath);
    if (!existsSync(dir)) {
      mkdirSync(dir, { recursive: true });
    }
    const label = existsSync(fullPath) ? 'Overwritten' : 'Created';
    writeFileSync(fullPath, file.content, 'utf-8');
    console.log(`  ${label}: ${file.path}`);
  }
}
```

`writeGeneratedFiles` checks `existsSync` right before the write, so `Overwritten:` appears only when an existing file was actually replaced.

### packages/cli/src/index.ts: wiring in run()

The dry-run and guard branches sit between the `generate()` call and any writes, and before the informational logging, so an aborted run never prints output that suggests success.

```typescript
    const result = generate({
      framework: parsed.framework,
      outputDir: parsed.outputDir,
      features,
      scopes,
    });
    const manifestFile = buildManifestFile(result.framework, features, scopes);
    const plannedFiles = [...result.files, manifestFile];

    if (parsed.dryRun) {
      printDryRunPlan(parsed.outputDir, plannedFiles);
      return;
    }

    // Only user-facing files arm the guard: the manifest is machine-written
    // and is refreshed on every generation, --force or not.
    const existingPaths = findExistingFiles(parsed.outputDir, result.files);
    if (existingPaths.length > 0 && !parsed.force) {
      printOverwriteRefusal(parsed.outputDir, existingPaths);
      process.exitCode = 1;
      return;
    }

    console.log(`\nGenerating ${result.framework} OIDC Provider code...\n`);
```

Writing covers `plannedFiles`, manifest included, and the count in the closing message follows.

```typescript
    writeGeneratedFiles(parsed.outputDir, plannedFiles);
    console.log(`\nDone! Generated ${plannedFiles.length} files in ${parsed.outputDir}`);
```

The guard (`findExistingFiles`) receives `result.files`, not `plannedFiles`.
The design decision that the manifest never arms the guard shows up as this one-argument difference.
For `setup`, returning from these branches also means `patchEntryFile` is never reached, which satisfies the "abort before wiring" requirement with the same code.

## CLI tests

The work was test-driven: the tests below were written first and confirmed failing (11 cases) before the implementation.
Two describes were added to `packages/cli/src/__tests__/cli.test.ts`.

### cli.test.ts: overwrite guard

```typescript
    describe('overwrite guard', () => {
      it('should exit with a non-zero code when the output directory already contains generated files', () => {
        const outputDir = join(testDir, 'guarded-output');
        mkdirSync(outputDir, { recursive: true });
        writeFileSync(join(outputDir, 'config.ts'), 'export const mine = true;\n');
        vi.spyOn(console, 'log').mockImplementation(() => {});
        vi.spyOn(console, 'error').mockImplementation(() => {});
        run(['generate', 'hono', '-o', outputDir]);
        expect(process.exitCode).toBe(1);
        vi.restoreAllMocks();
        process.exitCode = undefined;
      });

      it('should leave existing files untouched when generate is refused', () => {
        const outputDir = join(testDir, 'guarded-output');
        mkdirSync(outputDir, { recursive: true });
        const customized = 'export const mine = true;\n';
        writeFileSync(join(outputDir, 'config.ts'), customized);
        vi.spyOn(console, 'log').mockImplementation(() => {});
        vi.spyOn(console, 'error').mockImplementation(() => {});
        run(['generate', 'hono', '-o', outputDir]);
        expect(readFileSync(join(outputDir, 'config.ts'), 'utf-8')).toBe(customized);
        expect(existsSync(join(outputDir, 'app.ts'))).toBe(false);
        expect(existsSync(join(outputDir, '.maronn-openid-connect.json'))).toBe(false);
        vi.restoreAllMocks();
        process.exitCode = undefined;
      });

      it('should list every existing file in the refusal message', () => {
        const outputDir = join(testDir, 'guarded-output');
        mkdirSync(join(outputDir, 'routes'), { recursive: true });
        writeFileSync(join(outputDir, 'config.ts'), '// a\n');
        writeFileSync(join(outputDir, 'store.ts'), '// b\n');
        writeFileSync(join(outputDir, 'routes', 'token.ts'), '// c\n');
        vi.spyOn(console, 'log').mockImplementation(() => {});
        const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {});
        run(['generate', 'hono', '-o', outputDir]);
        const output = errorSpy.mock.calls.map((c) => c[0]).join('\n');
        expect(output).toBe(
          [
            `Error: 3 file(s) already exist in ${outputDir}:`,
            '  config.ts',
            '  store.ts',
            '  routes/token.ts',
            '',
            'Re-run with --force to overwrite them, or use -o <dir> to generate into a new directory.',
            'Tip: commit the generated files before overwriting so you can diff your changes.',
          ].join('\n'),
        );
        vi.restoreAllMocks();
        process.exitCode = undefined;
      });

      it('should overwrite existing files when --force is given', () => {
        const outputDir = join(testDir, 'forced-output');
        mkdirSync(outputDir, { recursive: true });
        writeFileSync(join(outputDir, 'config.ts'), 'export const mine = true;\n');
        vi.spyOn(console, 'log').mockImplementation(() => {});
        run(['generate', 'hono', '-o', outputDir, '--force']);
        expect(process.exitCode).toBe(undefined);
        expect(readFileSync(join(outputDir, 'config.ts'), 'utf-8')).not.toBe(
          'export const mine = true;\n',
        );
        expect(existsSync(join(outputDir, 'app.ts'))).toBe(true);
        vi.restoreAllMocks();
      });

      it('should log Overwritten for an existing file when --force is given', () => {
        const outputDir = join(testDir, 'forced-output');
        mkdirSync(outputDir, { recursive: true });
        writeFileSync(join(outputDir, 'config.ts'), 'export const mine = true;\n');
        const logSpy = vi.spyOn(console, 'log').mockImplementation(() => {});
        run(['generate', 'hono', '-o', outputDir, '--force']);
        expect(logSpy.mock.calls.map((c) => c[0])).toContain('  Overwritten: config.ts');
        vi.restoreAllMocks();
      });

      it('should log Created for a new file when --force is given', () => {
        const outputDir = join(testDir, 'forced-output');
        mkdirSync(outputDir, { recursive: true });
        writeFileSync(join(outputDir, 'config.ts'), 'export const mine = true;\n');
        const logSpy = vi.spyOn(console, 'log').mockImplementation(() => {});
        run(['generate', 'hono', '-o', outputDir, '--force']);
        expect(logSpy.mock.calls.map((c) => c[0])).toContain('  Created: app.ts');
        vi.restoreAllMocks();
      });

      it('should not write any file when --dry-run is given', () => {
        const outputDir = join(testDir, 'dry-run-output');
        vi.spyOn(console, 'log').mockImplementation(() => {});
        run(['generate', 'hono', '-o', outputDir, '--dry-run']);
        expect(process.exitCode).toBe(undefined);
        expect(existsSync(outputDir)).toBe(false);
        vi.restoreAllMocks();
      });

      it('should list the files it would write when --dry-run is given', () => {
        const outputDir = join(testDir, 'dry-run-output');
        mkdirSync(outputDir, { recursive: true });
        writeFileSync(join(outputDir, 'config.ts'), 'export const mine = true;\n');
        const logSpy = vi.spyOn(console, 'log').mockImplementation(() => {});
        run(['generate', 'hono', '-o', outputDir, '--dry-run']);
        const wouldLines = logSpy.mock.calls
          .map((c) => String(c[0]))
          .filter((line) => line.startsWith('  Would '));
        expect(wouldLines).toEqual([
          '  Would create: app.ts',
          '  Would create: apply.ts',
          '  Would overwrite: config.ts',
          '  Would create: store.ts',
          '  Would create: resolvers.ts',
          '  Would create: views.ts',
          '  Would create: routes/authorize.ts',
          '  Would create: routes/token.ts',
          '  Would create: routes/userinfo.ts',
          '  Would create: routes/introspection.ts',
          '  Would create: routes/revocation.ts',
          '  Would create: routes/jwks.ts',
          '  Would create: routes/discovery.ts',
          '  Would create: routes/login.ts',
          '  Would create: routes/consent.ts',
          '  Would create: conformance.test.ts',
          '  Would create: .maronn-openid-connect.json',
        ]);
        expect(readFileSync(join(outputDir, 'config.ts'), 'utf-8')).toBe(
          'export const mine = true;\n',
        );
        vi.restoreAllMocks();
      });

      it('should refuse setup as well when the output directory already contains generated files', () => {
        const outputDir = join(testDir, 'oidc-provider');
        const srcDir = join(testDir, 'src');
        const entryFile = join(srcDir, 'index.ts');
        mkdirSync(srcDir, { recursive: true });
        writeFileSync(
          entryFile,
          "import { Hono } from 'hono';\n// <!-- OIDC_IMPORT_PLACEHOLDER -->\nconst app = new Hono();\n// <!-- OIDC_SETUP_PLACEHOLDER -->\n",
        );
        vi.spyOn(console, 'log').mockImplementation(() => {});
        run(['setup', 'hono', '-o', outputDir, '-e', entryFile]);
        vi.restoreAllMocks();
        const afterFirstRun = readFileSync(entryFile, 'utf-8');

        vi.spyOn(console, 'log').mockImplementation(() => {});
        const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {});
        run(['setup', 'hono', '-o', outputDir, '-e', entryFile]);
        expect(process.exitCode).toBe(1);
        expect(errorSpy.mock.calls.map((c) => String(c[0]))[0]).toBe(
          `Error: 16 file(s) already exist in ${outputDir}:`,
        );
        expect(readFileSync(entryFile, 'utf-8')).toBe(afterFirstRun);
        vi.restoreAllMocks();
        process.exitCode = undefined;
      });

      it('should list --force and --dry-run in help output', () => {
        const consoleSpy = vi.spyOn(console, 'log').mockImplementation(() => {});
        run(['--help']);
        const output = consoleSpy.mock.calls.map((c) => c[0]).join('\n');
        expect(output).toContain('--force');
        expect(output).toContain('--dry-run');
        consoleSpy.mockRestore();
      });
    });
```

The dry-run test pins all 17 lines (the 16 default hono files plus the manifest) including their order, so any change to the file set or generation order is caught here.

### cli.test.ts: generation manifest

```typescript
    describe('generation manifest', () => {
      it('should write a .maronn-openid-connect.json manifest recording the cli version, framework and features', () => {
        const outputDir = join(testDir, 'manifest-output');
        vi.spyOn(console, 'log').mockImplementation(() => {});
        run(['generate', 'hono', '-o', outputDir, '--enable', 'par', '--disable', 'revocation']);
        const manifest = JSON.parse(
          readFileSync(join(outputDir, '.maronn-openid-connect.json'), 'utf-8'),
        );
        expect(manifest).toEqual({
          cliVersion: CLI_VERSION,
          framework: 'hono',
          features: {
            pkce: true,
            refreshToken: true,
            introspection: true,
            revocation: false,
            requestObject: true,
            par: true,
            tokenExchange: false,
            jarm: false,
            deviceAuthorizationGrant: false,
            idJag: false,
            ciba: false,
            jwtIntrospectionResponse: false,
            transactionBinding: false,
          },
          scopes: [],
        });
        vi.restoreAllMocks();
      });

      it('should record declared custom scopes in the manifest', () => {
        const outputDir = join(testDir, 'manifest-scopes-output');
        vi.spyOn(console, 'log').mockImplementation(() => {});
        run(['generate', 'hono', '-o', outputDir, '--scope', 'reports.read,reports.write']);
        const manifest = JSON.parse(
          readFileSync(join(outputDir, '.maronn-openid-connect.json'), 'utf-8'),
        );
        expect(manifest.scopes).toEqual(['reports.read', 'reports.write']);
        vi.restoreAllMocks();
      });

      it('should update the manifest even when generate is run with --force', () => {
        const outputDir = join(testDir, 'manifest-force-output');
        vi.spyOn(console, 'log').mockImplementation(() => {});
        run(['generate', 'hono', '-o', outputDir]);
        writeFileSync(join(outputDir, '.maronn-openid-connect.json'), '{"stale":true}\n');
        run(['generate', 'hono', '-o', outputDir, '--force']);
        const manifest = JSON.parse(
          readFileSync(join(outputDir, '.maronn-openid-connect.json'), 'utf-8'),
        );
        expect(manifest).toEqual({
          cliVersion: CLI_VERSION,
          framework: 'hono',
          features: {
            pkce: true,
            refreshToken: true,
            introspection: true,
            revocation: true,
            requestObject: true,
            par: false,
            tokenExchange: false,
            jarm: false,
            deviceAuthorizationGrant: false,
            idJag: false,
            ciba: false,
            jwtIntrospectionResponse: false,
            transactionBinding: false,
          },
          scopes: [],
        });
        vi.restoreAllMocks();
      });

      // The manifest is not a file the user edits, so its presence alone must
      // not require --force for a re-run into the same directory.
      it('should not refuse generate when only the manifest exists in the output directory', () => {
        const outputDir = join(testDir, 'manifest-only-output');
        mkdirSync(outputDir, { recursive: true });
        writeFileSync(join(outputDir, '.maronn-openid-connect.json'), '{"stale":true}\n');
        vi.spyOn(console, 'log').mockImplementation(() => {});
        run(['generate', 'hono', '-o', outputDir]);
        expect(process.exitCode).toBe(undefined);
        expect(existsSync(join(outputDir, 'app.ts'))).toBe(true);
        vi.restoreAllMocks();
      });
    });
```

The manifest assertions use `toEqual` with all 13 feature keys as concrete values.
Only the expected `cliVersion` is not a literal: the test reads it from the package's own `package.json` at the top of the file, because a literal would break on every release when changesets bump the version.

```typescript
import { createRequire } from 'node:module';

// The manifest pins the version of the CLI that generated the output, so the
// expected value is the package's own version rather than a literal that would
// go stale on every release.
const CLI_VERSION = (
  createRequire(import.meta.url)('../../package.json') as { version: string }
).version;
```

### cli.test.ts: updates to existing tests

Two existing pieces needed updating.

The first is how test directories are created.
The previous `join(tmpdir(), 'maronn-cli-test-' + Date.now())` could reuse a directory when two tests started in the same millisecond.
That was harmless while overwrites succeeded silently; with the guard, leftovers from a previous test would trigger a refusal.
`mkdtempSync` now guarantees a fresh directory per test.

```typescript
  beforeEach(() => {
    // mkdtempSync guarantees a fresh directory even when two tests start in
    // the same millisecond; a reused directory would trip the overwrite guard.
    testDir = mkdtempSync(join(tmpdir(), 'maronn-cli-test-'));
  });
```

The second is the test that runs `setup` twice into the same output directory.
The first run fills the directory, so the second needs `--force` to get past the guard and reach the already-patched detection it verifies.

```typescript
        // --force: the first run filled outputDir, so a plain re-run would be
        // refused by the overwrite guard before reaching the patch step.
        const logSpy = vi.spyOn(console, 'log').mockImplementation(() => {});
        run(['setup', 'hono', '-o', outputDir, '-e', entryFile, '--force']);
```

## Sample and documentation changes

### samples/*/package.json: --force on the generate scripts

`--force` was appended to the `generate` script of all four samples.
The hono-cloudflare one is shown; the other three follow the same shape.

```json
"generate": "maronn-oidc generate hono --enable par --enable token-exchange --enable transaction-binding --enable jarm --enable device-authorization-grant --enable id-jag --enable ciba --enable jwt-introspection-response --output ./src/oidc-provider --force"
```

Regeneration was run in all four samples, confirming that the existing generated files stay byte-identical (`git status` clean) and only the manifest is new.
The resulting manifests are committed as part of the generated output.

### Documentation

`docs/library-document/src/content/docs/guides/cli.md` gained an "Overwrite Protection" section and a "Generation Manifest" section, plus `--force` / `--dry-run` rows in the options table.
`packages/cli/README.md` carries the same content in brief.
Both recommend committing right after generation before customizing, so `--force` overwrites stay recoverable through `git diff`.

## Verification

All commands from the task's completion criteria were run.

- `pnpm --filter @maronn-openid-connect/cli test`: 1230 passing (including the 15 new cases)
- `pnpm typecheck`: packages / samples / tests all pass
- `pnpm lint`: no package defines a lint script, unchanged no-op
- `pnpm test:conformance`: 7 passing
- `pnpm --filter "./packages/*" test`: core 1170, experimental 588, cli 1230 passing
- Manual check against the built binary: `generate` into a non-empty directory lists the files and exits 1, `--force` overwrites, `--dry-run` writes nothing
