# CLI の上書きガードと生成マニフェストの実装解説

対象は `@maronn-openid-connect/cli` のコマンド入口（`packages/cli/src/index.ts`）とその CLI テスト、4 sample の再生成スクリプト、CLI ガイドのドキュメントである。
OSS リポジトリのタスク `tasks/done/p2-cli-generate-overwrite-guard.md` から実装した。

## この機能は何をするのか

`maronn-oidc generate` / `maronn-oidc setup` は、これまで出力先の既存ファイルを確認せずに書き込んでいた。
既存ファイルを潰した場合でもログは常に `Created:` と表示され、上書きが起きた事実は利用者に伝わらない。
また、生成物には「どの CLI バージョン・どの機能構成から生成されたか」を示す情報が無く、テンプレートへ入った仕様修正を利用者が取り込むとき、差分の起点を特定できなかった。

この変更で、CLI の書き込みは次の動作になる。

- 出力先に生成対象と同名のファイルが 1 つでもあれば、**1 バイトも書き込まずに**そのファイル一覧を表示し、終了コード 1 で中断する
- `--force` を明示したときだけ上書きし、ログを新規 `Created:` と上書き `Overwritten:` で出し分ける
- `--dry-run` は書き込みを行わず、出力予定の全ファイルを `Would create:` / `Would overwrite:` で表示する
- 生成物に **マニフェスト**（`.maronn-openid-connect.json`）を追加し、生成元の CLI バージョン（`cliVersion`）、framework、機能構成（`features`）、カスタムスコープ（`scopes`）を記録する

`setup` はコード生成を終えてからエントリファイルを配線するため、生成が中断されれば配線にも到達しない。
ガードは両コマンドに同じ形で効く。

## ユースケース

第一のユースケースは、改造済み生成コードの保護である。
生成コードは改造して使うことが公式に許容されており、`config.ts`（issuer・クライアント定義）や `store.ts`（永続化の実装）はほぼ確実に利用者の資産になる。
`-o` の指定ミスや、機能フラグを変えた再実行が、その資産を無警告で潰す事故をガードが防ぐ。

第二のユースケースは、テンプレートに入った仕様修正の取り込み判断である。
本ライブラリはテンプレートへ仕様修正（多くはセキュリティ修正）を継続的に入れているが、生成元の版が分からなければ、利用者は「どこからどこまでの差分を取ればよいか」を特定できない。
マニフェストの `cliVersion` をリリースノートと突き合わせれば、生成元の版と最新版の差分が取り込み判断の材料になる。

## 設計判断

### 既定を「中断」にする

上書きを既定にして警告を足す案もありえたが、既定を中断にした。
上書き事故は一度でも起きると復旧不能になりうる（Git 管理外のディレクトリでは特に）一方、中断の回避は `--force` を 1 回書き足すだけで済む。
失うものの大きさが非対称なので、安全側を既定にしている。

中断のメッセージには、既存ファイルの一覧に加えて回避手段（`--force`、`-o <dir>`）と、上書き前にコミットしておく運用の勧めを含めた。

```
Error: 3 file(s) already exist in ./oidc-provider:
  config.ts
  store.ts
  routes/token.ts

Re-run with --force to overwrite them, or use -o <dir> to generate into a new directory.
Tip: commit the generated files before overwriting so you can diff your changes.
```

### マニフェスト方式を採り、ヘッダコメント方式を採らない

生成元バージョンの記録には、各生成ファイルの先頭にコメントを付ける方式と、独立したマニフェストファイルを 1 つ置く方式があった。
ヘッダコメント方式は全テンプレートの期待出力を固定している既存テストへ一斉に波及するため、マニフェスト方式を採った。
生成ファイルの内容は 1 バイトも変わらず、既存の生成物固定テストはそのまま通る。

### マニフェストは CLI 層で書き、generator の API には足さない

マニフェストの書き出しは `run()`（CLI のコマンド処理）に置き、`generate()`（プログラム利用向け API）の戻り値には含めない。
`generate()` の呼び出し元は framework と features を自分で渡しており、記録の必要があるのは「CLI の実行内容を後から復元できない」利用者側だけだからである。
この配置により、`generator.test.ts` や各フレームワークの生成ファイル一覧を固定しているテストは変更が要らない。

### マニフェストは上書きガードの対象外とし、毎回更新する

マニフェストは機械が書くファイルで、利用者が編集する種類のファイルではない。
そのため既存の有無をガードの判定に使わず、書き込みが行われる実行では毎回更新する。
出力先にマニフェストだけが残っている場合、`--force` 無しの再実行は中断されない。

### 生成日時を含めない

マニフェストには `cliVersion` / `framework` / `features` / `scopes` だけを記録し、生成日時を含めない。
同じ入力から同じ出力になる決定性を壊さないためである。
この決定性は「sample の生成物を再生成して差分ゼロを確認する」という本リポジトリ自身の検証手順の前提でもある。

### sample の再生成スクリプトは `--force` 前提にする

`samples/*` の `generate` スクリプトは、コミット済みの生成物ディレクトリへ再生成する運用なので、ガード導入後は必ず既存ファイルに当たる。
4 sample のスクリプトへ `--force` を追記し、再生成が従来どおり 1 コマンドで完了することを確認した。
再生成で各 sample にマニフェストが生まれるため、生成物の一部としてコミットしてある。

### semver

`@maronn-openid-connect/cli` の minor とした。
`--force` / `--dry-run` というオプションの追加と、生成物へのマニフェスト追加は機能追加である。
一方、既存ファイルがあるディレクトリへの再実行が中断されるようになる点は挙動変更だが、意図しない上書きという事故的挙動の廃止であり、破壊的変更とは扱っていない。

## CLI の変更コード

### packages/cli/src/index.ts：定数とバージョン読み取り

マニフェストのファイル名と、CLI 自身のバージョンをモジュールの先頭で確定する。
バージョンは自 package の `package.json` から読む。
`src/` と `dist/` はどちらも package ルートの 1 階層下にあるので、`../package.json` はビルド前後のどちらから実行しても同じファイルに解決される。

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

### packages/cli/src/index.ts：parseArgs

`--force` と `--dry-run` の 2 フラグを追加した。
どちらも値を取らない真偽フラグである。

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

ヘルプ表示（`printUsage`）のオプション一覧にも 2 行を足した。

```
  --force               Overwrite files that already exist in the output directory
  --dry-run             Show what would be written without writing anything
```

### packages/cli/src/index.ts：マニフェスト構築・既存検出・表示の各関数

書き込み前の判定と表示を担う 4 つの関数を追加し、`writeGeneratedFiles` のログを既存有無で出し分けるようにした。

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

`writeGeneratedFiles` の判定は書き込み直前の `existsSync` なので、`Overwritten:` の表示は実際に既存ファイルを置き換えたときだけ現れる。

### packages/cli/src/index.ts：run() の配線

`generate()` の結果を受けてから書き込みに入るまでの間に、dry-run とガードの分岐を差し込んだ。
分岐は「Generating ...」などの案内ログより前に置き、中断される実行では成功を思わせる出力を出さない。

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

書き込みはマニフェストを含めた `plannedFiles` に対して行い、件数表示もそれに合わせた。

```typescript
    writeGeneratedFiles(parsed.outputDir, plannedFiles);
    console.log(`\nDone! Generated ${plannedFiles.length} files in ${parsed.outputDir}`);
```

ガードの判定（`findExistingFiles`）に渡すのは `result.files` であり、`plannedFiles` ではない。
マニフェストをガード対象外にするという設計判断が、この 1 引数の違いに現れている。
`setup` の場合、この分岐で `return` するとエントリファイルの配線（`patchEntryFile`）にも到達しないため、「配線より前に中断する」という要件も同じコードで満たされる。

## CLI のテストコード

テスト駆動で進め、以下のテストを先に書いて失敗（11 件）を確認してから実装した。
`packages/cli/src/__tests__/cli.test.ts` に describe を 2 つ追加している。

### cli.test.ts：overwrite guard

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

dry-run のテストは、hono 既定構成の 16 ファイルとマニフェストの計 17 行を順序込みで固定している。
生成順序やファイル集合が変わればこのテストが検知する。

### cli.test.ts：generation manifest

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

マニフェストのアサーションは、13 個の feature キーすべてを具体値で固定した `toEqual` で行う。
`cliVersion` の期待値だけはリテラルにせず、テストファイル冒頭で自 package の `package.json` から読んだ値を使う。
リリースのたびにバージョン番号が変わるため、リテラルで固定するとリリース PR で必ず壊れるテストになるからである。

```typescript
import { createRequire } from 'node:module';

// The manifest pins the version of the CLI that generated the output, so the
// expected value is the package's own version rather than a literal that would
// go stale on every release.
const CLI_VERSION = (
  createRequire(import.meta.url)('../../package.json') as { version: string }
).version;
```

### cli.test.ts：既存テストの更新

既存テストには 2 つの更新が要った。

一つ目はテスト用ディレクトリの作り方である。
従来の `join(tmpdir(), 'maronn-cli-test-' + Date.now())` は、同一ミリ秒に始まった 2 つのテストで同じディレクトリを再利用しうる。
上書きが黙って成功していた従来はそれでも通ったが、ガード導入後は前のテストの残骸が中断を引き起こす。
`mkdtempSync` に置き換えて、テストごとに必ず新しいディレクトリを得るようにした。

```typescript
  beforeEach(() => {
    // mkdtempSync guarantees a fresh directory even when two tests start in
    // the same millisecond; a reused directory would trip the overwrite guard.
    testDir = mkdtempSync(join(tmpdir(), 'maronn-cli-test-'));
  });
```

二つ目は `setup` を同じ出力先へ 2 回実行するテストである。
1 回目の実行で出力先が埋まるため、2 回目は `--force` を付けないとガードで中断され、検証対象の「配線済み判定」に到達しない。

```typescript
        // --force: the first run filled outputDir, so a plain re-run would be
        // refused by the overwrite guard before reaching the patch step.
        const logSpy = vi.spyOn(console, 'log').mockImplementation(() => {});
        run(['setup', 'hono', '-o', outputDir, '-e', entryFile, '--force']);
```

## sample とドキュメントの変更

### samples/*/package.json：generate スクリプトの --force 追記

4 sample の `generate` スクリプトの末尾へ `--force` を追記した。
hono-cloudflare の例を示す（他 3 つも同じ形）。

```json
"generate": "maronn-oidc generate hono --enable par --enable token-exchange --enable transaction-binding --enable jarm --enable device-authorization-grant --enable id-jag --enable ciba --enable jwt-introspection-response --output ./src/oidc-provider --force"
```

4 sample すべてで再生成を実行し、既存の生成ファイルが 1 バイトも変わらず（`git status` clean）、マニフェストだけが新規に生まれることを確認した。
生まれたマニフェストは生成物の一部としてコミットしてある。

### ドキュメント

`docs/library-document/src/content/docs/guides/cli.md` に「Overwrite Protection」節と「Generation Manifest」節を追加し、オプション表へ `--force` / `--dry-run` を足した。
`packages/cli/README.md` にも同じ内容を簡潔に記載した。
どちらも、再生成の予定があるなら生成直後にコミットしてから改造する運用を勧めている。

## 検証

タスクの完了条件のコマンドをすべて実行し、確認した。

- `pnpm --filter @maronn-openid-connect/cli test`：1230 件パス（新規 15 件を含む）
- `pnpm typecheck`：packages / samples / tests すべて成功
- `pnpm lint`：対象 package に lint スクリプトが無く、従来どおり no-op
- `pnpm test:conformance`：7 件パス
- `pnpm --filter "./packages/*" test`：core 1170 件・experimental 588 件・cli 1230 件パス
- ビルド済みバイナリでの手動確認：既存ディレクトリへの `generate` が一覧を表示して終了コード 1、`--force` で上書き、`--dry-run` で書き込みなし
