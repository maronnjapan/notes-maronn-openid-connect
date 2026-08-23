# [P1] `maronn-oidc setup` がプレースホルダ未検出・部分適用でも成功と報告する問題を修正する

## ステータス

🟠 High / 未着手

## 背景

`maronn-oidc setup <framework>` は、生成に加えて既存のエントリファイルへ OP を組み込む（配線する）。
配線は 2 つのプレースホルダコメントの文字列置換で行われる。

- `// <!-- OIDC_IMPORT_PLACEHOLDER -->` → `import { applyOidc } from '...';`
- `// <!-- OIDC_SETUP_PLACEHOLDER -->` → `applyOidc(app);`

`String.prototype.replace` は対象が無ければ元の文字列をそのまま返すため、**プレースホルダが 1 つも無い
エントリファイルに対しても、CLI は同一内容を書き戻して `Patched: <file>` と表示し、終了コード 0 で終わる**。
利用者はその後 `Next steps: ... Start the server` の案内どおりにサーバを起動するが、OP はどのルートにも
マウントされていない。原因が表示されないため、quick-start の最初の一歩で沈黙失敗する。

さらに「SETUP 側だけ存在する」エントリファイルでは、`import` の無い `applyOidc(app);` が書き込まれるため、
**CLI が利用者のファイルを型検査の通らない状態に壊したうえで成功と報告する**。

`setup` は CLAUDE.md が定義する「利用者の入口」の最短経路であり、ここでの silent failure は離脱に直結する。
本 CLI は他の失敗経路（未知の framework、エントリファイル不在、Next.js への `setup`）では
`process.exitCode = 1` で失敗を報告しており、プレースホルダ未検出だけが例外になっている。

検討詳細は `study-material/done/cli-setup-entry-placeholder-silent-noop.md` を参照。

> 関連: 生成物ディレクトリ側の無警告上書きは `tasks/p2-cli-generate-overwrite-guard.md` が扱う。
> 本タスクは **利用者の既存エントリファイルに対する配線** に限定する。

## 対象ファイル

- `packages/cli/src/index.ts`（`patchEntryFile`、`run` の `setup` 分岐）
- `packages/cli/src/__tests__/cli.test.ts`（`setup command` ブロック）
- `docs/library-document/src/content/docs/guides/cli.md`
- `docs/library-document/src/content/docs/quick-start.md`

## 仕様参照

OIDC/OAuth の条文には関わらない実装欠陥。準拠先は本リポジトリの内部規約。

- CLAUDE.md「利用者の入口」: CLI コマンドでフロー実装コードを生成し、利用者がそれを改造して仕様を検証する。
- 本 CLI の既存規約: 要求した副作用を実行できない場合は `process.exitCode = 1` で失敗を報告する
  （`packages/cli/src/index.ts` の framework 未指定 / エントリファイル不在 / Next.js への `setup` の各分岐）。

## 現状の実装

```ts
// packages/cli/src/index.ts:116-134
function patchEntryFile(entryFilePath: string, outputDir: string): void {
  // ...
  let content = readFileSync(entryFilePath, 'utf-8');
  content = content.replace(
    '// <!-- OIDC_IMPORT_PLACEHOLDER -->',
    `import { applyOidc } from '${applyImportPath}';`,
  );
  content = content.replace(
    '// <!-- OIDC_SETUP_PLACEHOLDER -->',
    'applyOidc(app);',
  );
  writeFileSync(entryFilePath, content, 'utf-8');
  console.log(`  Patched: ${entryFilePath}`);   // 置換ゼロでもここに到達する
}
```

| エントリファイルの状態 | 実際に起きること | 現状の報告 |
|---|---|---|
| 両方あり | 正常に配線される | `Patched:` ✅ |
| どちらも無い | 同一内容を書き戻すだけ。配線されない | `Patched:` ❌ 誤報 |
| IMPORT だけ | import は入るが `applyOidc(app)` が入らない。マウントされない | `Patched:` ❌ 誤報 |
| SETUP だけ | import 無しの `applyOidc(app)` を書き込む。**ファイルが壊れる** | `Patched:` ❌ 誤報 |

既存テスト `packages/cli/src/__tests__/cli.test.ts` の `setup command` ブロックは、
「IMPORT だけ」「SETUP だけ」のケースを *置換されること* のみ検証しており、
配線が不完全であることは検証していない。「プレースホルダ皆無」のケースはテストが存在しない。

## 修正方針

`study-material/done/cli-setup-entry-placeholder-silent-noop.md` の方針A（両方揃っていなければエラー）
＋方針C（べき等性の明示）を採る。

- [ ] `patchEntryFile` を、置換結果を返す関数へ変更する
      （例: `{ importPatched: boolean; setupPatched: boolean; alreadyPatched: boolean }`）
- [ ] **書き込み前に**両プレースホルダの存在を確認する。片方でも欠けている場合は
      **`writeFileSync` を呼ばずに** 戻り、`run()` 側で非ゼロ終了させる
      （＝どの失敗経路でも利用者のファイルを壊さない）
- [ ] エラーメッセージに、必要なプレースホルダ 2 種の正確な文字列と、記述例を含める

      ```
      Error: Entry file is missing the required OIDC placeholders: ./src/index.ts
        Missing: // <!-- OIDC_SETUP_PLACEHOLDER -->

      Add both placeholder comments to the entry file and re-run `setup`:
        // <!-- OIDC_IMPORT_PLACEHOLDER -->
        const app = new Hono();
        // <!-- OIDC_SETUP_PLACEHOLDER -->
      ```

- [ ] べき等性: 既に `applyOidc` の import と呼び出しが両方存在する場合は、
      ファイルを書き換えずに `Already patched (no changes): <file>` を表示して**成功終了**する
- [ ] 配線に失敗した場合は `Next steps: ... Start the server` の案内を**表示しない**
      （`packages/cli/src/index.ts:205` 以降の分岐）
- [ ] 生成ファイルの書き込み（`writeGeneratedFiles`）は配線判定より前に走るため、
      「生成は済んだが配線に失敗した」ことが分かる文言にする
      （例: `Generated files are in ./oidc-provider, but the entry file was not patched.`）
- [ ] 生成コードは直接編集せず `packages/cli` 側を修正する（CLAUDE.md の規約）

## テスト要件

`packages/cli/src/__tests__/cli.test.ts` の `setup command` ブロックに追加・更新する。
テストケース名は「should + 動詞」形式で書き、`it` ブロック内に条件分岐を書かないこと。

- [ ] `should exit with a non-zero code when the entry file has no OIDC placeholders`
- [ ] `should leave the entry file unchanged when the entry file has no OIDC placeholders`
      （読み込んだ内容と書き込み後の内容が完全一致することを `toBe` で固定）
- [ ] `should exit with a non-zero code when only the import placeholder is present`
- [ ] `should exit with a non-zero code when only the setup placeholder is present`
- [ ] `should leave the entry file unchanged when only the setup placeholder is present`
      （現状はファイルを壊すため、このケースの回帰防止が本タスクの核心）
- [ ] `should name the missing placeholder in the error message`
      （エラー出力に欠けている側のプレースホルダ文字列が含まれることを固定値で検証）
- [ ] `should not print the start-the-server guidance when patching fails`
- [ ] `should report already patched and leave the file unchanged on a second setup run`
- [ ] 既存の `should patch entry file ... placeholder` 2 件（IMPORT だけ / SETUP だけ）を、
      新しい契約（エラーになる）に合わせて書き換える
- [ ] 正常系（両方あり）が引き続き通ること: import 行と `applyOidc(app);` の**両方**が
      書き込まれていることを固定文字列で検証する

## 完了条件

- [ ] プレースホルダが揃っていない場合、エントリファイルが 1 バイトも変更されず、非ゼロ終了すること
- [ ] 上記テストがすべてパスすること

  ```bash
  pnpm --filter @maronn-openid-connect/cli test
  pnpm typecheck
  pnpm lint
  ```

- [ ] `docs/library-document/src/content/docs/guides/cli.md` と `quick-start.md` に、
      必要なプレースホルダ 2 種と、欠けている場合に `setup` が失敗することが明記されていること
- [ ] 手動確認: プレースホルダを 1 つも書いていないエントリファイルに `setup` を実行し、
      エラーメッセージが表示され `echo $?` が非ゼロになること
