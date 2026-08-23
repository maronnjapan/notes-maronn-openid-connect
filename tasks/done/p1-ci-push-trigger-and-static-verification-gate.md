# [P1] CI に `main` push トリガと静的検証ゲート（typecheck / build / lint）を追加する

## ステータス

🟢 High / 対応済み（段階 1・2 実装、段階 3 は見送り、段階 4 はリポジトリ設定側で要対応）

## 対応結果

### 実測（有効化コストの把握）

| コマンド | 結果 |
|---|---|
| `pnpm run typecheck` | `pnpm run build` の**後**なら 0 エラー。build 前だと `packages/experimental` が `Cannot find module '@maronn-openid-connect/core'` 他 7 件で落ちる（`samples/*` も core を dist で解決する） |
| `pnpm run build` | 0 エラー |
| `pnpm run lint` | `None of the selected packages has a "lint" script` と表示して **exit 0**。lint ツール自体が未導入 |

`packages/core` に `typecheck` スクリプトが無く、`pnpm --filter "./packages/*" typecheck` が
core を黙って読み飛ばしていた（`build` の `tsc` で結果的に型検査されていただけ）。

### 実装

- `ci.yml` に `push: branches: [main]` を追加。`concurrency` を併用し、
  `cancel-in-progress` は `pull_request` のときだけ true にした
  （main push の実行を打ち切ると「main が緑である」記録が残らないため）
- `Build packages` → `Type check` → `Unit & Integration tests` の順でステップを追加。
  build を先に置く理由は上記の実測どおり
- `packages/core` に `typecheck: tsc --noEmit` を追加
- ゲート構成自体を `.github/scripts/verify-ci-gate.mjs` で検証し、`test:ci` に組み込んだ
  （`pnpm run test:ci-gate`）。push トリガ・ステップの順序・`typecheck` の網羅・
  実体のない Lint ステップを、いずれも壊したときにテストが赤くなる形で固定した

### 人間判断が必要な論点への決定

| 論点 | 決定 | 理由 |
|---|---|---|
| `typecheck` の対象 | リポジトリ全体（`packages/*` / `samples/*` / `tests/*`） | build 後は 0 エラーで、段階導入する必要がなかった |
| `main` push の二重実行 | `concurrency` で間引く（main push はキャンセルしない） | main の検証結果は release の前提なので取り消さない |
| conformance ワークフロー | 現状（`run-conformance` ラベル・手動）のまま | `timeout-minutes: 75` を毎 push で回すのは割に合わない。常時検証でない点は RELEASE.md に記録済み |
| Lint | 有効化しない（段階 3 は見送り） | lint ツール未導入で `pnpm run lint` が対象 0 件のまま成功する。ステップを足すと常に緑で何も検証しない false green になる |
| ブランチ保護 | **有効化を推奨（リポジトリ設定側で要対応）** | `push: [main]` は直接 push を検知できるが、壊れたコミットが main に入ること自体は止められない。決定内容は `RELEASE.md`「publish に流れ込む前の検証ゲート」に記録 |

### 未了

- `main` ブランチ保護の有効化はリポジトリ設定（コード管理外）であり、本変更には含まれない
- 「`main` push で CI が起動する」実地確認は、本変更が main にマージされた後にしか観測できない

## 背景

構文的に壊れたコード（未解決コンフリクトマーカー）が `main` に入り、
`@maronn-openid-connect/core` と `@maronn-openid-connect/cli` がビルド不能な状態のまま残った
（現物の解消は `tasks/p0-resolve-committed-merge-conflict-markers.md`）。

原因は単一の作業ミスではなく、CI ゲートの構成にある。

1. `.github/workflows/ci.yml` のトリガが `on: pull_request` のみで、
   **`main` への直接 push は一度も検査されない**。実際に問題のコミット `95c9efe` は
   親 1 つの通常コミット（PR 非経由）としてこの経路から入った。
2. `typecheck` / `lint` が `# TODO` でコメントアウトされたまま運用されている。
   `package.json` にはスクリプトが定義済みで、**CI から呼ぶだけの状態**にある。
3. `pnpm run build`（`tsc` によるパッケージビルド）が CI のどのジョブでも実行されない。
   `test:ci` は `supply-chain → release-contract → packages のテスト → conformance` であり build を含まない。
   `vitest` は都度 transform するため型エラーで落ちないケースがあり、
   ビルド可否は別途検査しないと担保できない。**`build` が初めて走るのは `ci:publish`（publish 直前）**。

`release.yml` は `main` への push を起点に version / publish 段階を進めるため、
無検査の `main` はそのまま publish 経路へ流れ込む。

検討詳細は `study-material/done/ci-trigger-coverage-and-static-verification-gate.md` を参照。

> 依存脆弱性監査 / provenance / Dependabot は `tasks/p2-supply-chain-ci-security.md` の範囲であり、
> 本タスクには含めない。同じ `ci.yml` を触るが論点は別。

## 対象ファイル

- `.github/workflows/ci.yml`（`on` トリガ、`Type check` / `Lint` のコメントアウト解除、`build` ステップ追加）
- `package.json`（`typecheck` の対象範囲を段階導入する場合のスクリプト分割）
- GitHub リポジトリ設定（`main` のブランチ保護。コード外の作業）

## 仕様参照

OIDC / OAuth の条文には関わらない。準拠先は本リポジトリの方針と一般的なサプライチェーン基準。

- CLAUDE.md「リリース方針」: 「テストコードで主要ケースを網羅し、仕様参照を明記することは必須」。
  テストが**書かれている**ことと**常に実行され緑である**ことは別であり、後者を担保するのが CI ゲート。
- CLAUDE.md「差別化の 3 軸 / Fidelity」: Conformance 準拠を信頼性のシグナルとして維持する。
  シグナルは「CI が常に緑である」ことで初めて外部から観測可能になる。
- GitHub Actions `on.<push|pull_request>` — https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows
- GitHub ブランチ保護 / 必須ステータスチェック — https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches
- OpenSSF Scorecard `Branch-Protection` / `CI-Tests` — https://github.com/ossf/scorecard/blob/main/docs/checks.md
- SLSA v1.0 Build track — https://slsa.dev/spec/v1.0/levels

## 現状の実装

`.github/workflows/ci.yml`

```yaml
name: CI

on:
  pull_request:
    branches: [main]          # ← push トリガが無い
```

```yaml
      # TODO: Lintと型チェックを適用後、有効化する。
      # - name: Type check
      #   run: pnpm run typecheck

      # - name: Lint
      #   run: pnpm run lint

      - name: Unit & Integration tests
        run: pnpm run test:ci   # ← build を含まない
```

`package.json`（スクリプトは定義済み）

```jsonc
"typecheck": "pnpm --filter \"./packages/*\" typecheck && pnpm --filter \"./samples/*\" typecheck && pnpm --filter \"./tests/*\" typecheck",
"lint": "pnpm --filter \"./packages/*\" lint",
"build": "pnpm --filter @maronn-openid-connect/core --filter @maronn-openid-connect/experimental --filter @maronn-openid-connect/cli run build",
"test:ci": "pnpm run test:supply-chain && pnpm run test:release-contract && pnpm --filter \"./packages/*\" test && pnpm run test:conformance",
```

問題:

- `main` 直接 push が無検査
- 型エラー・構文エラーが CI で検知されない
- ビルド破綻が publish 直前まで露見しない

補足: `.github/workflows/conformance.yml` の `basic-op` ジョブは
`run-conformance` ラベル付き PR か `workflow_dispatch` のときだけ実行される
（`timeout-minutes: 75`）。実行時間を考えれば妥当な設計だが、
「Basic OP 適合性が常時検証されているわけではない」点は本タスクの前提として記録しておく。

## 修正方針

段階導入とする。各段階で「何が原因で赤くなったか」を明確にし、停滞を避ける。

### 段階 1: トリガ拡張（最優先・低リスク）

- [ ] `ci.yml` に `push: branches: [main]` を追加する
- [ ] PR と `main` push で同一ジョブが二重に走るコストを抑えるため、
      `concurrency` グループの併用を検討する

```yaml
on:
  pull_request:
    branches: [main]
  push:
    branches: [main]

concurrency:
  group: ci-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

### 段階 2: 型チェックとビルド

- [ ] `pnpm run typecheck` をローカルで実行し、現時点のエラー件数と対象パッケージを記録する（有効化コストの実測）
- [ ] `Type check` ステップのコメントアウトを解除する。
      `samples/*` / `tests/*` に既存エラーが出る場合は、まず
      `pnpm --filter "./packages/*" typecheck` だけを必須にし、残りを段階的に追加する
- [ ] `pnpm run build` ステップを追加する（publish 前にビルド可否を検知する）

```yaml
      - name: Type check
        run: pnpm run typecheck

      - name: Build packages
        run: pnpm run build

      - name: Unit & Integration tests
        run: pnpm run test:ci
```

### 段階 3: Lint

- [ ] `pnpm run lint` をローカルで実行し、現時点の指摘件数を記録する
- [ ] `Lint` ステップのコメントアウトを解除する

### 段階 4: ブランチ保護（コード外・人間判断）

- [ ] `main` への直接 push を禁止するか決定する
- [ ] 必須ステータスチェックに CI の `test` ジョブを設定する
- [ ] 有効化する場合、今後 `main` へ直接 push できなくなる運用変更を伴うことを合意しておく

> 段階 4 はワークフロー変更と排他ではなく併用が望ましい。
> ブランチ保護は「CI をすり抜ける経路を塞ぐ」役割で、CI ジョブの拡充とは別軸である。

### 人間判断が必要な論点

| 論点 | 選択肢 |
|---|---|
| `typecheck` の対象 | リポジトリ全体（`samples/*` / `tests/*` 含む）/ `packages/*` に限定して段階導入 |
| `main` push の二重実行 | 許容する / `concurrency` で間引く |
| conformance ワークフロー | `main` push でも走らせる / 現状（ラベル・手動）のまま |
| ブランチ保護 | 有効化する / しない |

## テスト要件

- [ ] `main` への push で CI ワークフローが起動することを確認する（トリガの実地確認）
- [ ] `pnpm run typecheck` が CI で実行され、成功する
- [ ] `pnpm run build` が CI で実行され、成功する
- [ ] `pnpm run lint` が CI で実行され、成功する（段階 3 完了時）
- [ ] **負のテスト**: 意図的に構文エラー（例: コンフリクトマーカー）を含めた検証用ブランチで
      PR を作り、CI が **赤になる** ことを確認する。
      同じ内容が `main` push 経路でも赤になることを確認する
- [ ] **負のテスト**: 意図的な型エラーを含む変更で `Type check` ステップが落ちることを確認する
- [ ] 既存の PR ワークフロー（`test:ci` / conformance ラベル運用）が壊れていないことを確認する

## 完了条件

```bash
# ローカルで先に実測（有効化コストの把握）
pnpm install
pnpm run typecheck
pnpm run build
pnpm run lint
```

- `ci.yml` が `pull_request` と `push: branches: [main]` の両方で起動する
- `Type check` / `Build packages` / `Unit & Integration tests` が CI で実行され、`main` で緑である
- `Lint` が有効化されている（段階 3 まで完了した場合）
- 負のテストにより、壊れた変更が CI で赤くなることを実地確認済み
- ブランチ保護の要否を決定し、決定内容を本タスクまたは `RELEASE.md` に記録している
- `tasks/p0-resolve-committed-merge-conflict-markers.md` が完了しており、`main` が緑である
