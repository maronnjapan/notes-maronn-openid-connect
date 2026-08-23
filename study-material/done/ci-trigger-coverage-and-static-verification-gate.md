# CI のトリガ範囲と静的検証ゲート（`main` への直接 push が無検査 / typecheck・lint が無効）

## ステータス

🟠 High（リリース健全性・開発プロセス）/ タスク化済み → 📌 `tasks/p1-ci-push-trigger-and-static-verification-gate.md`

> 「いま `main` に何が入っているか」という現物の破損は
> 📌 `study-material/done/released-source-unresolved-merge-conflict-markers.md` が扱う。
> 本ファイルは重複させず、**「なぜ検知されずに `main` へ入れたのか」「どうゲートを張るか」**という再発防止側に絞る。
> 依存脆弱性監査・provenance・Dependabot は 📌 `tasks/p2-supply-chain-ci-security.md` の範囲であり、本ファイルでは扱わない。

## 1. このトピックで確認したいこと

構文的に壊れたコード（未解決コンフリクトマーカー）が `main` に入ったという事実から逆算し、
本リポジトリの CI が **どの経路の変更を検査していないか** を確定させる。具体的には次の 3 点。

1. `ci.yml` のトリガが `pull_request` のみで、`main` への直接 push を検査していないのではないか
2. `typecheck` / `lint` が `# TODO` としてコメントアウトされたまま運用されているのではないか
3. `pnpm run build`（`tsc` によるパッケージビルド）が CI のどのジョブでも実行されていないのではないか

そのうえで、「どのゲートを、どのトリガで、どこまで必須にするか」の判断材料を整理する。

## 2. 関連する仕様・基準

OpenID Connect / OAuth の仕様要件ではなく、リポジトリの開発プロセス品質の論点である。
ただし本リポジトリのコンセプトに直結する。

- `CLAUDE.md`「リリース方針」: **「テストコードで主要ケースを網羅し、仕様参照を明記することは必須」**。
  テストが「書かれている」ことと「常に実行され緑であること」は別であり、後者を担保するのが CI ゲートの役割。
- `CLAUDE.md`「差別化の 3 軸」の **Fidelity**: Conformance 準拠を信頼性のシグナルとして維持する
  → シグナルは「CI が常に緑である」ことによって初めて外部から観測可能になる。
- `RELEASE.md` / `package.json`: `ci:publish` は `pnpm run build` を前提とする。
  ビルド可否を PR 段階で検査していなければ、publish 直前まで破綻が露見しない。

一般的な基準としては次を参照できる。

- **OpenSSF Scorecard** の `Branch-Protection` / `CI-Tests` チェック:
  デフォルトブランチへの直接 push を禁止し、変更が CI を通過してからマージされることを求める。
- **SLSA v1.0 Build track**: ビルドが定義済みプロセスを経ることを前提とする。
  デフォルトブランチが検査されない経路で更新できると、この前提が崩れる。

## 3. 参照資料

- 本リポジトリ `.github/workflows/ci.yml`（`on: pull_request: branches: [main]` / `# TODO` でコメントアウトされた typecheck・lint）
- 本リポジトリ `.github/workflows/release.yml`（`main` への push を起点に version / publish 段階が進む運用）
- 本リポジトリ `package.json`（`typecheck` / `lint` / `build` / `test:ci` スクリプト定義）
- GitHub Actions: `on.<push|pull_request>` トリガ — https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows
- GitHub: ブランチ保護ルール / 必須ステータスチェック — https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches
- OpenSSF Scorecard checks（`Branch-Protection` / `CI-Tests`） — https://github.com/ossf/scorecard/blob/main/docs/checks.md
- SLSA v1.0 Build track — https://slsa.dev/spec/v1.0/levels

## 4. 現在の実装確認

### 4.1 `ci.yml` のトリガ

```yaml
name: CI

on:
  pull_request:
    branches: [main]
```

`push` トリガが無い。したがって **`main` へ直接 push されたコミットは CI に一度もかからない**。

実際に `origin/main` の HEAD `95c9efe`（親 1 つの通常コミット、PR 経由でない）が
この経路で入り、構文的に壊れたソースがそのまま `main` に残っている。
`57a9646` 以前は Merge commit（`Merge pull request #37 …` 等）が並んでおり、
PR 経由の変更は CI を通っていたことと対照的である。

### 4.2 `typecheck` / `lint` が無効

`ci.yml` の `test` ジョブ:

```yaml
      # TODO: Lintと型チェックを適用後、有効化する。
      # - name: Type check
      #   run: pnpm run typecheck

      # - name: Lint
      #   run: pnpm run lint

      - name: Unit & Integration tests
        run: pnpm run test:ci
```

`package.json` には両スクリプトが定義済みである。

```jsonc
"typecheck": "pnpm --filter \"./packages/*\" typecheck && pnpm --filter \"./samples/*\" typecheck && pnpm --filter \"./tests/*\" typecheck",
"lint": "pnpm --filter \"./packages/*\" lint",
```

つまり **実行手段は既に揃っているのに、CI で呼ばれていない**。

なお `tasks/p2-supply-chain-ci-security.md` の「現状の実装」節にこの事実の記述はあるが、
同タスクのスコープは provenance / 依存監査 / Dependabot であり、
**typecheck・lint の有効化そのものは同タスクの修正方針にもテスト要件にも含まれていない**。
本ファイルはその隙間を扱う。

### 4.3 `build` が CI で実行されていない

`test:ci` の中身は次のとおりで、`pnpm run build`（`tsc` によるパッケージビルド）を含まない。

```
test:supply-chain → test:release-contract → pnpm --filter "./packages/*" test → test:conformance
```

`vitest` はソースを都度 transform するため型エラーでは落ちないケースがあり、
`tsc` ビルドの成否は別途検査しないと担保できない。
`build` が初めて走るのは `ci:publish`（= publish 直前）である。

### 4.4 conformance ワークフローは既定でスキップされる

`.github/workflows/conformance.yml` の `basic-op` ジョブは

```yaml
    if: github.event_name == 'workflow_dispatch' || contains(join(github.event.pull_request.labels.*.name, ','), 'run-conformance')
```

であり、`run-conformance` ラベルが付いた PR か手動実行のときだけ動く。
これは実行時間（`timeout-minutes: 75`）を考えれば妥当な設計だが、
「Basic OP 適合性が常時検証されているわけではない」という事実は明示しておく価値がある。

> 未確認事項: GitHub 側のブランチ保護設定（`main` への直接 push の可否、必須ステータスチェックの構成）は
> リポジトリ設定であり、ワークフロー定義からは判定できない。`main` に親 1 つの直接コミットが存在することから
> 「直接 push が禁止されていない」ことは推測できるが、設定画面での確認が必要。

## 5. 現在の実装との差分

- **満たしていること**
  - PR 経由の変更については unit / integration / conformance(sample) / supply-chain / release-contract テストが走る。
  - `typecheck` / `lint` / `build` のスクリプトは既に定義済みで、CI から呼ぶだけの状態にある。
  - 重量級の OIDF conformance suite はラベル / 手動でオプトイン実行できる設計になっている。
- **不足している可能性があること**
  - `push: branches: [main]` トリガが無く、**デフォルトブランチの健全性が一度も検査されない**。
  - `typecheck` が無効なため、型エラー・構文エラーが PR でも検知されない場合がある。
  - `build`（`tsc`）が publish 直前まで走らないため、ビルド不能な状態を早期に検知できない。
  - `lint` が無効なため、コンフリクトマーカーのような明白な異常を静的解析で拾う経路が無い。
- **実装はあるが仕様上の確認が必要なこと**
  - `typecheck` は `samples/*` と `tests/*` も対象に含む。生成物である `samples/*` が
    現在この型検査を通過するかは未確認であり、有効化前に実測が要る（通らない場合、有効化が停滞する原因になる）。
- **セキュリティ上、改善した方がよいこと**
  - デフォルトブランチが無検査で更新できる状態は、OpenSSF Scorecard の `Branch-Protection` /
    `CI-Tests` の観点で弱点となる。認証・認可ライブラリという性質上、この指標は下流利用者の信頼判断に直結する。
- **相互運用性の観点**
  - 直接の影響は無い。ただし `main` が壊れていると利用者が clone した時点で動かないため、
    実務上の相互運用性（試せること）は損なわれる。
- **Basic OP として提供する上で確認すべきこと**
  - `conformance.test.ts`（sample の契約テスト）は `test:ci` に含まれ PR で走るため、
    Basic OP 挙動の契約自体は PR 経路では守られている。守られていないのは「`main` 直接 push 経路」である。

## 6. 改善・追加を検討する理由

- **なぜ価値があるか**: 本リポジトリは「Conformance 準拠を信頼性のシグナルとして掲げる」OSS である。
  シグナルの前提は「デフォルトブランチが常にビルド・テストを通過している」ことであり、
  それを保証する仕組みが現状は存在しない。実際にその欠落が壊れた `main` として顕在化している。
- **Basic OP として必要か**: Basic OP の認定要件ではない。ただし Basic OP 適合性を
  **主張し続けるための土台**であり、認定取得後の維持コストを大きく下げる。
- **導入しやすさ**: 非常に容易。トリガ 3 行の追加とコメントアウトの解除が中心で、
  新規スクリプトの実装は不要。ただし `typecheck` を有効化した際に `samples/*` / `tests/*` の
  既存型エラーが露見する可能性があり、その解消コストが唯一の不確定要素。
- **既存実装との接続**: `package.json` の既存スクリプトをそのまま呼ぶだけで接続できる。
  `p2-supply-chain-ci-security.md` が追加予定の `dependency-audit` 系ジョブとも独立に共存できる。
- **利用者・開発者・運用者のメリット**
  - 利用者: clone した `main` が動くことが保証される。
  - 開発者: 型エラーが PR 時点で分かる。壊れた `main` に引きずられない。
  - 運用者: publish 直前ではなく PR 時点でビルド破綻を検知できる。
- **実装しない場合のリスク**
  - 同種の破損が再発する。今回はコンフリクトマーカーという分かりやすい形だったが、
    型エラーや生成物の不整合は気づかれにくい。
  - `release.yml` は `main` への push を起点に version / publish 段階を進めるため、
    無検査の `main` はそのまま publish 経路に流れ込む。

## 7. 実装方針の候補

### 方針A（段階導入: トリガ拡張 → 型・ビルド → lint）

1. `ci.yml` に `push: branches: [main]` を追加し、まず既存の `test:ci` を `main` にも適用する。
2. `typecheck` を有効化する。ただし `samples/*` / `tests/*` で既存エラーが出る場合は、
   まず `pnpm --filter "./packages/*" typecheck` だけを必須にし、残りを段階的に追加する。
3. `pnpm run build` を CI ジョブに追加する（publish 前にビルド可否を検知する）。
4. `lint` を最後に有効化する（既存指摘数が読めないため）。

利点: 各段階で「何が原因で赤くなったか」が明確。停滞しにくい。
欠点: 完全なゲートが揃うまで時間がかかる。

### 方針B（一括有効化）

- `push` トリガ追加、`typecheck` / `lint` / `build` の同時有効化を 1 PR で行う。
- 利点: 一度で目的の状態に到達する。
- 欠点: `samples/*` の型エラーや lint 指摘が大量に出た場合、PR が肥大化して停滞しうる。

### 方針C（GitHub 設定側で担保する）

- ワークフローは変えず、`main` のブランチ保護（直接 push 禁止＋必須ステータスチェック）だけで担保する。
- 利点: ワークフロー変更が不要。
- 欠点: リポジトリ設定はコードレビューに乗らず、変更履歴も追いにくい。
  また `typecheck` / `build` が動かない問題は解決しない。
- 補足: 方針A / B と**排他ではなく併用が望ましい**。ブランチ保護は
  「CI をすり抜ける経路を塞ぐ」役割で、CI ジョブの拡充とは別軸である。

### 検討事項（人間判断が必要な点）

- `typecheck` の対象を最初からリポジトリ全体（`samples/*` / `tests/*` 含む）にするか、
  `packages/*` に限定して段階導入するか
- `push: branches: [main]` を追加した場合、PR と `main` push で同一ジョブが二重に走るコストを許容するか
  （`concurrency` グループでの間引きを併用するか）
- conformance ワークフローを `main` push でも走らせるか（実行時間 75 分のコストとのトレードオフ）
- ブランチ保護を有効にするか（有効にすると、今後 `main` へ直接 push できなくなる運用変更を伴う）

## 8. タスク案

- [ ] 方針A / B / C（および併用）を選択（人間判断）
- [ ] `pnpm run typecheck` をローカルで実行し、現時点のエラー件数と対象パッケージを記録する（有効化コストの実測）
- [ ] `pnpm run lint` をローカルで実行し、現時点の指摘件数を記録する
- [ ] `ci.yml` に `push: branches: [main]` トリガを追加する
- [ ] `ci.yml` の `Type check` ステップのコメントアウトを解除する（対象範囲は上記実測に基づき決定）
- [ ] `ci.yml` に `pnpm run build` ステップを追加する
- [ ] `ci.yml` の `Lint` ステップのコメントアウトを解除する
- [ ] `main` のブランチ保護（直接 push 禁止・必須ステータスチェック）の有効化可否を決定し、設定する
- [ ] 上記ゲートが実際に機能することを、意図的に壊した内容を含む検証用 PR で確認する（負のテスト）
- [ ] 完了条件: `main` に対して CI が走り、`typecheck` / `build` / `test:ci` が緑であること

## 関連トピック

- 📌 `study-material/done/released-source-unresolved-merge-conflict-markers.md` — 本ゲート欠落によって `main` に入った現物の破損
- 📌 `tasks/p2-supply-chain-ci-security.md` — 依存監査 / provenance / Dependabot。CI という同じファイルを触るが論点は別
- 📌 `tasks/done/p2-cli-generated-output-verification-ci.md` — CLI 生成物の CI 検証。本ゲートに乗せる対象のひとつ
