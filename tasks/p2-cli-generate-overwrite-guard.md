# [P2] `maronn-oidc generate` の無警告上書きをガードし、生成元バージョンを記録する

## ステータス

🟡 Medium / 未着手

## 背景

CLI は生成物を **既存ファイルの有無を確認せずに** 書き込み、ログは常に `Created:` を表示する。
既存ファイルを潰した場合でもログ上は新規作成と区別できず、`--force` / `--dry-run` 相当の
オプションも存在しない。

上書き対象には、利用者が必ず改造するファイルが含まれる。

| 種別 | 例 | 利用者が触る前提か |
|---|---|---|
| 仕様準拠ロジック | `routes/token.ts` / `routes/authorize.ts` | 触ってよい（ステップ関数を消す/足す設計） |
| 環境固有の設定 | `config.ts`（issuer / TTL / クライアント定義） | **ほぼ確実に触る** |
| 永続化の実装 | `store.ts` / `resolvers.ts` | **ほぼ確実に触る**（KV / DB へ差し替え） |
| 契約テスト | `conformance.test.ts` | 原則触らない（上流が正） |

CLI 自身も生成後の Next steps で「`config.ts` のデフォルトはローカル検証用。永続ストアを注入せよ」と案内している。
つまり **上書きされると必ず困るファイルが、無警告上書きの対象**になっている。
`-o` の指定ミスや、feature フラグを変えた再実行だけで改造が失われる。

加えて、生成物には **どの `@maronn-openid-connect/cli` バージョン・どの feature 構成で生成されたか**を示す情報が一切無い。
本リポジトリは `packages/cli` のテンプレートに仕様修正（多くはセキュリティ修正）を継続的に入れているが、
既存利用者がそれを取り込む際、「自分のコードがどの版から生成されたか」が分からないため差分の起点を特定できない。

検討詳細は `study-material/done/cli-generated-code-overwrite-safety-and-upgrade-path.md` を参照。

> 関連: `setup` によるエントリファイル配線の silent failure は `tasks/p1-cli-setup-placeholder-detection-and-failure.md`。
> 本タスクは **生成物ディレクトリへの書き込み** に限定する。

## 対象ファイル

- `packages/cli/src/index.ts`（`parseArgs` / `writeGeneratedFiles` / `run`）
- `packages/cli/src/generator.ts`（マニフェスト出力を採る場合）
- `packages/cli/src/__tests__/cli.test.ts`
- `packages/cli/src/__tests__/generator.test.ts`（生成ファイル数を固定しているテスト。マニフェスト追加時に更新）
- `docs/library-document/src/content/docs/guides/cli.md`

## 仕様参照

OIDC/OAuth の条文には関わらない。準拠先は本リポジトリの方針。

- CLAUDE.md「差別化の3軸 / Speed」: 新仕様へ最速で追随する。追随したテンプレート修正が既存利用者に届く経路が必要。
- CLAUDE.md「利用者の入口」: 生成コードは利用者が改造する前提。改造は公式に許容されている。
- CLAUDE.md「`samples/*/src/oidc-provider` は生成物なので修正は `packages/cli` 側で行う」:
  リポジトリ内部では「上流が単一の真実」という前提を採っており、利用者側にも同じ前提を伝える必要がある。

## 現状の実装

```ts
// packages/cli/src/index.ts:104-114
function writeGeneratedFiles(outputDir: string, files: Array<{ path: string; content: string }>): void {
  for (const file of files) {
    const fullPath = join(outputDir, file.path);
    const dir = dirname(fullPath);
    if (!existsSync(dir)) {
      mkdirSync(dir, { recursive: true });
    }
    writeFileSync(fullPath, file.content, 'utf-8');   // 既存ファイルを無条件で上書き
    console.log(`  Created: ${file.path}`);           // 上書きでも "Created"
  }
}
```

`parseArgs`（`packages/cli/src/index.ts:60-102`）が受け付けるオプションは
`--output` / `-o`、`--entry` / `-e`、`--enable`、`--disable`、`--help` / `-h` のみで、
上書き制御や dry-run のフラグは存在しない。

## 修正方針

`study-material/done/cli-generated-code-overwrite-safety-and-upgrade-path.md` の
方針A（上書きガード）＋方針B のマニフェスト方式を採る。方針C（保護リストによる選択的上書き）と
方針D（`upgrade` コマンド）は本タスクに含めない。

### A. 上書きガード

- [ ] `parseArgs` に `--force` と `--dry-run` を追加する
- [ ] `writeGeneratedFiles` の前に、出力予定パスのうち既に存在するものを列挙する
- [ ] 既存ファイルが 1 件以上あり `--force` が無い場合は、**1 バイトも書き込まずに**中断し、
      非ゼロ終了する。メッセージに既存ファイル一覧と `--force` の案内を含める

      ```
      Error: 3 file(s) already exist in ./oidc-provider:
        config.ts
        store.ts
        routes/token.ts

      Re-run with --force to overwrite them, or use -o <dir> to generate into a new directory.
      Tip: commit the generated files before overwriting so you can diff your changes.
      ```

- [ ] `--force` 指定時はログを出し分ける（`Created:` / `Overwritten:`）
- [ ] `--dry-run` は書き込みを行わず、出力予定のファイル一覧と、それぞれが新規か上書きかを表示する
- [ ] `setup` コマンドでも同じガードが効くようにする（配線より前に中断する）

### B. 生成元バージョンの記録（マニフェスト方式）

ヘッダコメント方式は全テンプレートの期待出力テストに波及するため、マニフェストファイル方式を採る。

- [ ] 生成物に `.maronn-openid-connect.json` を追加し、次を記録する

      ```json
      {
        "cliVersion": "0.0.1",
        "framework": "hono",
        "features": { "pkce": true, "refreshToken": true, "introspection": true,
                      "revocation": true, "requestObject": true, "par": false }
      }
      ```

- [ ] `cliVersion` は `packages/cli/package.json` の `version` を参照する
      （バンドル方法に応じて、ビルド時定数化するか `createRequire` で読むかを実装時に決める）
- [ ] 生成日時は含めない（同じ入力から同じ出力になる決定性を壊さないため）
- [ ] マニフェストは上書きガードの対象外とし、`--force` 無しでも常に更新する
      （利用者が編集する種類のファイルではないため）
- [ ] `generator.test.ts` などで生成ファイル数を固定しているテストを更新する

### C. ドキュメント

- [ ] `docs/library-document/src/content/docs/guides/cli.md` に次を追記する
  - 既定では既存ファイルを上書きしないこと、`--force` / `--dry-run` の使い方
  - 生成直後にコミットしてから改造することを推奨する運用
  - `.maronn-openid-connect.json` の見方と、上流のリリースノートと突き合わせる手順

## テスト要件

`packages/cli/src/__tests__/cli.test.ts` に追加する。
テストケース名は「should + 動詞」形式で書き、`it` ブロック内に条件分岐を書かないこと。

- [ ] `should exit with a non-zero code when the output directory already contains generated files`
- [ ] `should leave existing files untouched when generate is refused`
      （既存ファイルの内容が変更前と完全一致することを `toBe` で固定）
- [ ] `should list every existing file in the refusal message`
      （表示されるパス集合を `toEqual` で固定）
- [ ] `should overwrite existing files when --force is given`
- [ ] `should log Overwritten for an existing file when --force is given`
- [ ] `should log Created for a new file when --force is given`
- [ ] `should not write any file when --dry-run is given`
- [ ] `should list the files it would write when --dry-run is given`
- [ ] `should refuse setup as well when the output directory already contains generated files`
- [ ] `should write a .maronn-openid-connect.json manifest recording the cli version, framework and features`
      （マニフェストの内容を `toEqual` で固定。`features` は全キーを具体値で指定する）
- [ ] `should update the manifest even when generate is run with --force`
- [ ] 既存の生成テスト（ファイル数・ファイル一覧を固定しているもの）をマニフェスト追加後の値へ更新する

## 完了条件

- [ ] 既存の出力ディレクトリに対する `generate` が、`--force` 無しでは 1 バイトも書き込まずに非ゼロ終了すること
- [ ] `--dry-run` が書き込みを行わないこと
- [ ] 生成物に `.maronn-openid-connect.json` が含まれ、`cliVersion` / `framework` / `features` が記録されていること
- [ ] 下記がすべてパスすること

  ```bash
  pnpm --filter @maronn-openid-connect/cli test
  pnpm typecheck
  pnpm lint
  pnpm test:conformance
  ```

- [ ] 4 サンプル（`hono-cloudflare` / `express-flyio` / `fastify-flyio` / `nextjs-vercel`）の
      再生成手順が、マニフェスト追加後も破綻しないことを確認すること
      （サンプル配下の生成物を再生成する運用がある場合は `--force` 前提に更新する）
- [ ] `docs/library-document/src/content/docs/guides/cli.md` に上書き挙動が明記されていること
