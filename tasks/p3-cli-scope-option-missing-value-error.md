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
- `packages/cli/src/__tests__/cli.test.ts`

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

- [ ] `should error when --scope is given without a value`
- [ ] `should error when --scope swallows the next option`（`--scope --output ./dir` で `--output` が scope にならないこと）
- [ ] `should not write any file when the scope option is malformed`

## 完了条件

```bash
pnpm --filter @maronn-openid-connect/cli test
pnpm typecheck
```

- 値欠落の 2 経路がどちらも非ゼロ終了し、何も生成しないことをテストで固定する
