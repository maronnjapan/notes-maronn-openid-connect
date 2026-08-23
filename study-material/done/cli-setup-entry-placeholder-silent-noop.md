# CLI `setup` がプレースホルダ未検出・部分適用でも成功として報告する（silent no-op）

## 1. このトピックで確認したいこと

`maronn-oidc setup <framework>` は、生成に加えて既存のエントリファイルへ OP を組み込む（配線する）コマンドである。
配線はエントリファイル内のプレースホルダコメント 2 種の文字列置換で行われる。

このトピックでは、**置換対象が見つからなかった場合／片方しか見つからなかった場合に、CLI が何を報告するか**を確認する。
結論として、現状はどちらの場合も `Patched: <file>` と表示して正常終了する。
利用者は「OP が組み込まれた」と信じてサーバを起動するが、OP はどのルートにもマウントされていない。

## 2. 関連する仕様・基準

OIDC/OAuth の条文に関わるトピックではない。対応する基準は次のとおり。

- **CLAUDE.md「利用者の入口」**: 「CLI コマンドでフロー実装コードを生成し、利用者はそのコードを改造しながら仕様を検証する」。
  `setup` はこの入口の最短経路であり、ここで silent failure が起きると利用者は「ライブラリが動かない」と判断して離脱する。
- **CLI の一般的な期待**: 要求した副作用が実行できなかった場合、終了コードを非ゼロにして失敗を報告する
  （`process.exitCode = 1`）。本 CLI 自身、他の失敗経路（未知の framework、エントリファイル不在、Next.js への `setup`）
  ではこの規約に従っている（`packages/cli/src/index.ts:146-170`）。プレースホルダ未検出だけが例外になっている。

> 仕様準拠の問題ではなく **実装の欠陥（バグ）** として扱う。仕様参照は上記の内部規約のみで足りる。

## 3. 参照資料

- 本リポジトリ `packages/cli/src/index.ts:117-134`（`patchEntryFile`）
- 本リポジトリ `packages/cli/src/index.ts:136-230`（`run`。他の失敗経路の扱い）
- 本リポジトリ `packages/cli/src/__tests__/cli.test.ts:237-315`（`setup command` の既存テスト）
- 本リポジトリ `docs/library-document/src/content/docs/guides/cli.md:22`（プレースホルダの説明）
- 本リポジトリ `docs/library-document/src/content/docs/quick-start.md`（`setup` を使う導線）

## 4. 現在の実装確認

```ts
// packages/cli/src/index.ts:117-134
function patchEntryFile(entryFilePath: string, outputDir: string): void {
  const entryDir = dirname(resolve(entryFilePath));
  const resolvedOutput = resolve(outputDir);
  const relPath = relative(entryDir, resolvedOutput);
  const importPath = relPath.startsWith('.') ? relPath : `./${relPath}`;
  const applyImportPath = `${importPath}/apply.js`;

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
  console.log(`  Patched: ${entryFilePath}`);
}
```

`String.prototype.replace` は対象が見つからなければ元の文字列をそのまま返す。したがって:

| エントリファイルの状態 | 実際に起きること | CLI の報告 |
|---|---|---|
| 両方のプレースホルダあり | import 追加 + `applyOidc(app)` 追加。正常 | `Patched:` ✅ 正しい |
| **どちらも無い** | ファイルを読んで同一内容で書き戻すだけ。配線されない | `Patched:` ❌ 誤報 |
| **IMPORT だけある** | import は入るが `applyOidc(app)` は入らない。OP はマウントされない | `Patched:` ❌ 誤報 |
| **SETUP だけある** | `applyOidc(app)` は入るが import が無い。**実行時 / 型検査エラー** | `Patched:` ❌ 誤報 |

さらに `run()` は `patchEntryFile` の後、無条件に次の案内を出す（`packages/cli/src/index.ts:198-208`）:

```
Next steps:
  1. Provide runtime config, signing keys, and client resolvers from env/DB/KV
  ...
  4. Start the server
```

配線されていなくても「サーバを起動してください」と表示され、終了コードは 0 のままである。

### 既存テストの状況

`packages/cli/src/__tests__/cli.test.ts` の `setup command` ブロックには次のケースがある。

- 両方のプレースホルダがある場合（`:243`）
- **IMPORT だけ**がある場合（`:257`）— 置換後に `<!-- OIDC_IMPORT_PLACEHOLDER -->` が消えていることのみを検証。
  `applyOidc(app)` が入っていないこと（＝配線が不完全であること）は検証していない
- **SETUP だけ**がある場合（`:267`）— 同様
- framework 未指定 / エントリファイル不在 / Next.js への `setup` の各エラー（`:281` 以降）

つまり **部分適用は「そういう動作」としてテストに固定されており、プレースホルダ皆無のケースはテストが無い**。
これが意図的な仕様なのか、単に想定漏れなのかは既存の記述からは判断できない（不明点として明記する）。

## 5. 現在の実装との差分

満たしていること:

- ✅ プレースホルダが揃っている正常系は正しく動作する。
- ✅ エントリファイルが存在しない場合は非ゼロ終了で失敗を報告する（`index.ts:169-173`）。
- ✅ Next.js に対する `setup` は明示的に拒否される（`index.ts:161-167`）。

不足している可能性があること:

- 🔴 **プレースホルダ皆無でも成功扱い**。利用者は原因不明の 404 に直面する。
  `setup` は quick-start 導線の中心であり、最初の 5 分で失敗する体験になる。
- 🟠 **部分適用も成功扱い**。特に「SETUP だけある」ケースは、import の無い `applyOidc(app)` を書き込むため、
  **エントリファイルを型検査が通らない状態に壊す**。CLI がファイルを壊しておいて成功を報告する。
- 🟠 **置換は先頭 1 箇所のみ**（`replace` は非グローバル）。プレースホルダを複数書いた場合の挙動が未定義のまま。
  実用上は問題になりにくいが、契約として明記されていない。
- 🟡 **べき等性が未定義**: 一度 `setup` した後に再度 `setup` すると、プレースホルダは既に消えているため
  「皆無」ケースに落ち、無変更で成功と報告される。利用者は「更新された」と誤解する。

セキュリティ上の観点:

- 🟢 直接のセキュリティ影響は無い（配線されなければ OP は公開されない＝安全側に倒れる）。
  ただし「SETUP だけある」ケースでファイルを壊す点は、利用者のリポジトリへの破壊的副作用として扱うべき。

## 6. 改善・追加を検討する理由

**なぜ価値があるか**

- 本リポジトリのターゲットは「PoC 開発者・本番導入を見据える開発者」であり、彼らは最短経路で動くかどうかを見る。
  `setup` が黙って何もしないと、原因調査に時間を要し、そのまま離脱する。
- 修正コストが極小（既存文字列の有無を確認して分岐するだけ）で、外部依存も不要。
- 現状の欠陥は「CLI が利用者のファイルを壊しても成功と言う」ケースを含み、
  `study-material/done/cli-generated-code-overwrite-safety-and-upgrade-path.md` が扱う上書き問題と同じ根（安全確認の欠如）を持つ。
  ただしそちらは「生成物ディレクトリ」の話であり、本ファイルは「利用者の既存エントリファイル」を対象とする別問題。

**Basic OP 必須か、拡張か**

- どちらでもない。OIDF 認定要件とは無関係の実装欠陥。ただし利用者体験としては最優先級。

**導入しやすさ**

- 🟢 `patchEntryFile` を `boolean` / 結果オブジェクトを返す形に変え、`run()` 側で分岐するだけ。
  影響範囲は `packages/cli/src/index.ts` と `packages/cli/src/__tests__/cli.test.ts` に閉じる。
- 🟡 既存テスト（`:257` / `:267` の部分適用ケース）の期待値変更が必要。
  「部分適用をエラーにする」なら既存テストは書き換えになる。

**利用者・開発者のメリット**

- 失敗が即座に分かる。エラーメッセージにプレースホルダの正しい書式を含めれば、そのまま自己解決できる。
- CI で `setup` を使う利用者は、非ゼロ終了により配線失敗を検出できる。

**実装しない場合に残るリスク**

- quick-start の最初の一歩で沈黙失敗し、原因が分からないままの離脱が続く。
- 「SETUP だけ」のケースでエントリファイルが壊れ、CLI への信頼が失われる。

## 7. 実装方針の候補（最終判断は人間が行う）

### 方針A: 両方揃っていなければエラー（厳格）

- `patchEntryFile` の前に 2 つのプレースホルダの存在を確認。
  片方でも欠けていれば **ファイルを書き換えずに** 非ゼロ終了し、期待するプレースホルダの書式を表示する。
- 利点: 破壊的副作用がゼロになる。契約が単純（「両方必要」）。
- 欠点: 既存テストの「片方だけ」ケース 2 件を「エラーになること」の検証に書き換える必要がある。
  片方だけを意図的に使っている利用者がいた場合は破壊的変更になる（そのような利用が実在するかは不明）。

### 方針B: 皆無のみエラー、部分適用は警告

- 両方無ければ非ゼロ終了。片方だけなら適用した上で警告を出し、終了コードは 0 のまま。
- 利点: 既存テストの意図（片方だけでも置換される）を保てる。
- 欠点: 「SETUP だけ」でファイルを壊す問題が残る。警告は見落とされる。

### 方針C: 方針A + べき等性の明示

- 方針A に加え、「既に `applyOidc` の import と呼び出しが存在する」場合は
  「already patched（no changes）」として **成功終了**する（再実行しても壊さない）。
- 利点: 再実行が安全になり、生成の再実行（上書きガード側の方針）と一貫する。
- 欠点: 「既にパッチ済み」の判定条件を決める必要がある（import パスが変わっている場合の扱い等）。

### 方針D: `setup` を廃止し `generate` + 手動配線に一本化

- ドキュメントで配線手順を案内し、CLI からは自動配線を外す。
- 利点: 曖昧さが消える。
- 欠点: 入口の手数が増える。CLAUDE.md の「利用者の入口」方針と逆行するため、採るなら明確な理由が要る。

**判断材料の要約**

- 方針A/C は破壊的副作用を根絶できる。方針C は再実行体験まで含めて一貫させる分だけ設計判断が 1 つ増える。
- 方針B は既存テストを変えずに済むが、最も危険なケース（SETUP だけ → ファイル破壊）が残るため、
  本ファイルとしては推奨しない。
- 方針D は入口設計そのものの変更であり、本トピック単独で決めるべきでない。

## 8. タスク案

- [ ] 方針A / B / C / D のいずれを採るか決める（本ファイルとしては A または C を推す）
- [ ] `patchEntryFile` を「置換結果（両方置換 / 片方 / 皆無）」を返す関数へ変更し、`run()` で分岐させる
- [ ] プレースホルダ未検出時は **ファイルを書き換えずに** 非ゼロ終了し、期待書式を含むエラーメッセージを出す
- [ ] 既存テスト `cli.test.ts:257` / `:267`（片方だけのケース）の期待値を、採用方針に合わせて更新する
- [ ] 「プレースホルダ皆無」「既にパッチ済みの再実行」のテストケースを追加する
- [ ] `docs/library-document/src/content/docs/guides/cli.md` と `docs/library-document/src/content/docs/quick-start.md` に、必要なプレースホルダ 2 種と失敗時の挙動を明記する

## 関連トピック

- `study-material/done/cli-generated-code-overwrite-safety-and-upgrade-path.md` — 同じ CLI の別欠陥（生成物ディレクトリの無警告上書き）。
  本ファイルは利用者の既存エントリファイルに対する silent no-op / 破壊を扱う。
- `study-material/done/cli-generated-output-conformance-ci.md` — 生成物の CI 検証。`setup` の配線結果は現状 CI で検証されていない。
