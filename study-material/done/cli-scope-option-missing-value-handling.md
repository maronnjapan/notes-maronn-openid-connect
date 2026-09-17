# CLI --scope の値欠落・オプション吸い込みが黙って無視される問題

## 1. このトピックで確認したいこと

`maronn-oidc generate hono --scope`（値なし）や `--scope --output ./dir` のような誤ったコマンドラインを、CLI が黙って受理してしまう。scope 宣言はセキュリティ機能（宣言外 scope の拒否）の入口なので、静かな脱落をどう防ぐかを確認する。

## 2. 関連する仕様・基準

OIDC / OAuth の条文には関わらない。準拠先は本リポジトリの方針と、CLI 自身の既存設計。

- `resolveCustomScopes` は空リストの `--scope` に `--scope requires at least one scope name` を throw する設計であり、「静かな無視をしない」方針を既に採っている。引数解析だけがその方針から漏れている。

## 3. 参照資料

- `packages/cli/src/index.ts` の `parseArgs`（`--scope` 分岐）
- `packages/cli/src/scopes.ts`
- `study-material/done/cli-setup-entry-placeholder-silent-noop.md`（CLI の別の静かな no-op。解析の欠落値は未カバー）

## 4. 現在の実装確認

```typescript
} else if (arg === '--scope') {
  i++;
  const value = args[i];
  if (value !== undefined) scope.push(value);
```

- 末尾の `--scope`（値なし）は無言で捨てられる。scopes.ts も許容リストも生成されず、OP は全 scope 受理のまま。
- `--scope --output ./dir` は `--output` を scope 名として消費する。`--output` は ABNF 上有効な scope-token なので `resolveCustomScopes` も通し、`"--output"` という scope が宣言され、出力先指定は失われる。

## 5. 現在の実装との差分

- 🟠 セキュリティ機能の宣言が静かに脱落し、利用者は「宣言したつもりの scope 制限が効いていない OP」を得る。
- 🟠 オプション値の吸い込みは、意図しない scope 宣言と出力先の変化を同時に起こす。

## 6. 改善・追加を検討する理由

CLI の他の検証（未知 feature 名のエラー、enable/disable 矛盾のエラー、空 `--scope` リストの throw）は失敗を明示する設計で統一されている。引数解析の 2 経路だけが無言なのは一貫性を欠き、修正は数行で済む。

## 7. 実装方針の候補

- `--scope` の次の引数が `undefined` または `--` で始まる場合、`Error: --scope requires a value` で非ゼロ終了する。
- `--enable` / `--disable` / `--output` / `--entry` にも同じ欠落値の問題があるか確認し、必要なら同時に揃える（`--enable`（値なし）は splitFeatureList が空を返すため現状も無害だが、無言である点は同じ）。

## 8. タスク案

- [ ] `--scope` の値欠落とオプション吸い込みをエラーにする
- [ ] 他のオプションの値欠落挙動を確認し、必要なら同じ扱いに揃える

→ `tasks/p3-cli-scope-option-missing-value-error.md` としてタスク化済み。
