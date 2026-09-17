# [P3] CLI --scope の値欠落・オプション吸い込みをエラーにする

## ステータス

🟢 Low / 未着手

## 背景

`parseArgs` の `--scope` 分岐は、次の引数が無ければ黙って捨て、次の引数が別オプションならそれを scope 名として消費する。

- 末尾の `--scope`（値なし）: scope 宣言が静かに脱落し、OP は全 scope 受理のまま生成される
- `--scope --output ./dir`: `--output` が ABNF 上有効な scope-token のため `"--output"` という scope が宣言され、出力先指定が失われる

`resolveCustomScopes` は空リストの `--scope` に throw する「静かに無視しない」方針を採っており、引数解析だけがそこから漏れている。

詳細は `study-material/done/cli-scope-option-missing-value-handling.md` を参照。

## 対象ファイル

- `packages/cli/src/index.ts`（`parseArgs`）
- `packages/cli` には単体テストを置かない（README「packages/cli には単体テストを置かない」）。検証はビルド済み CLI を実行して行う

## 仕様参照

OIDC / OAuth の条文には関わらない。準拠先は CLI 自身の既存設計（未知 feature 名・enable/disable 矛盾・空 scope リストはいずれも明示エラー）。

## 現状の実装

```typescript
} else if (arg === '--scope') {
  i++;
  const value = args[i];
  if (value !== undefined) scope.push(value);
```

## 修正方針

- [ ] `--scope` の次の引数が `undefined`、または `--` で始まる場合、`Error: --scope requires a value` を表示して非ゼロ終了する
- [ ] `--enable` / `--disable` / `--output` / `--entry` の値欠落挙動を確認し、同じ静かな無視があれば同様にエラーへ揃える

## テスト要件

`packages/cli` の単体テストは廃止したので、ビルド済み CLI（`packages/cli/dist/index.js`）を実行して次を確認する。
自動化する場合は、CLI を子プロセスとして起動する検証を `tests/` 配下に置く。

- [ ] `--scope` に値が無いとき、非ゼロ終了する
- [ ] `--scope --output ./dir` のとき、`--output` が scope として扱われず、非ゼロ終了する
- [ ] scope オプションが不正なとき、ファイルを 1 つも書き出さない

## 完了条件

```bash
pnpm --filter @maronn-openid-connect/cli build
node packages/cli/dist/index.js generate hono --output /tmp/oidc-scope-check --scope
node packages/cli/dist/index.js generate hono --scope --output /tmp/oidc-scope-check
pnpm typecheck
```

- 値欠落の 2 経路がどちらも非ゼロ終了し、`/tmp/oidc-scope-check` に何も生成されないことを確認する
