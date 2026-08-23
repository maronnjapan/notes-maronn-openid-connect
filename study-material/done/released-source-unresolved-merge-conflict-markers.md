# 配布対象ソースに未解決のマージコンフリクトマーカーが commit されている（`main` がビルド不能）

## ステータス

🔴 Critical（リリース健全性・利用者影響）/ タスク化済み → 📌 `tasks/p0-resolve-committed-merge-conflict-markers.md`

> 本ファイルは仕様準拠ではなく **リポジトリ成果物の健全性** を扱う。
> 「なぜ検知できなかったか」という CI ゲート側の論点は
> 📌 `study-material/done/ci-trigger-coverage-and-static-verification-gate.md` が扱い、本ファイルでは重複させない。
> 本ファイルは「いま `main` に何が入っているか」「どう解消すべきか」に絞る。

## 1. このトピックで確認したいこと

`origin/main` の HEAD（`95c9efe` 「experimentalのpublish設定」）に、**未解決の Git コンフリクトマーカー
（`<<<<<<< Updated upstream` / `=======` / `>>>>>>> Stashed changes`）がソースコードごと commit されている**。

確認したいのは次の 3 点。

1. どのファイルの、どの範囲に混入しているか（影響範囲の確定）
2. それぞれのコンフリクトについて、どちらの side を採るのが正しいか（機械的に決定できるか、人間の判断が要るか）
3. この状態で `packages/core` / `packages/cli` のビルド・テスト・publish がどうなるか（利用者影響）

## 2. 関連する仕様・基準

本トピックは OpenID Connect / OAuth の仕様要件ではない。ただし、本リポジトリが掲げる差別化 3 軸のうち
**Fidelity（Conformance 準拠を信頼性のシグナルとして維持する）** と **Portability** は、
「配布物が実際にビルド・実行できる」ことを前提にして初めて成立する。

関係する自リポジトリ内の規約は次のとおり。

- `CLAUDE.md`「利用者の入口」: **CLI コマンドでフロー実装コードを生成し、利用者はそのコードを改造しながら仕様を検証する**。
  → CLI がビルドできない状態は、利用者の入口そのものが塞がっていることを意味する。
- `CLAUDE.md`「samples/\*」: `samples/*/src/oidc-provider` は `packages/cli` のコード生成物であり、
  修正は必ず `packages/cli` 側で行う。→ 生成器が壊れると sample の再生成・`conformance.test.ts` の更新経路も止まる。
- `RELEASE.md` / `package.json`: `ci:publish` は `pnpm run build`（= core / experimental / cli の `tsc` ビルド）を
  前提に `changeset publish` する。→ ビルドが通らない限り publish は成立しない。

## 3. 参照資料

- Git: `git merge` / コンフリクトマーカーの形式 — https://git-scm.com/docs/git-merge#_how_conflicts_are_presented
  - `<<<<<<<` / `=======` / `>>>>>>>` は**そのままではどの言語としても構文エラー**であることの一次情報。
  - ラベルが `Updated upstream` / `Stashed changes` である点は `git stash pop`（`git stash apply`）由来のコンフリクトを示す
    — https://git-scm.com/docs/git-stash
- TypeScript: `tsc` は構文エラーで非ゼロ終了する — https://www.typescriptlang.org/docs/handbook/compiler-options.html
- 本リポジトリ: `.github/workflows/ci.yml` / `.github/workflows/release.yml` / `package.json` の `build` / `ci:publish`

## 4. 現在の実装確認

### 4.1 混入している箇所（`origin/main` = `95c9efe` 時点）

`git log -S'<<<<<<< Updated upstream'` により、**4 ファイル・5 箇所すべてが単一コミット `95c9efe` で導入された**ことを確認済み。
`95c9efe` は親が 1 つ（`57a9646`）の通常コミットであり、マージコミットではない。

| ファイル | 行範囲 | upstream 側 | stashed 側 | 両 side 同一か |
|---|---|---|---|---|
| `packages/core/src/client-auth.ts` | 192–202 | 4 行 | 4 行 | **同一** |
| `packages/cli/src/frameworks/hono/templates.ts` | 1658–1735 | 75 行 | 0 行 | 異なる |
| `packages/cli/src/frameworks/hono/templates.ts` | 3203–3239 | 17 行 | 17 行 | **同一** |
| `packages/cli/src/__tests__/hono-generator.test.ts` | 313–349 | 17 行 | 17 行 | **同一** |
| `packages/experimental/README.md` | 1–62 | 58 行 | 1 行 | 異なる |

### 4.2 各コンフリクトの中身

**(a) `packages/core/src/client-auth.ts:192-202`（両 side 同一）**

`extractClientCredentials` の末尾。両 side とも次の 4 行で完全に一致する。

```ts
  return { clientId, clientSecret, method };
}
```

マーカーを取り除いて片側を残すだけでよい。意味的な判断は不要。

**(b) `packages/cli/src/frameworks/hono/templates.ts:1658-1735`（異なる／決定可能）**

upstream 側だけが、experimental PAR（RFC 9126）機能の生成テンプレート断片を定義している。

```ts
  const parImports = features.par ? `
import { PushedRequestUriError, assertPushedRequestUsed, resolvePushedRequestUri } from '${EXPERIMENTAL_PACKAGE}/par';
...` : '';
  const parParamsBinding = ...
  const parResolveStep = ...
  const parCatchBranch = ...
```

stashed 側はこのブロックが**丸ごと存在しない**。しかし同ファイルの下流（例: 1786 行
``import { defaultViews, renderView } from '../views.js';${parImports}``）が
これらの変数を参照しているため、stashed 側を採ると `parImports` 等が未定義となり
**そもそも `tsc` が通らない**。加えて次の周辺証跡が揃っている。

- `packages/cli/src/features.ts`: `EXPERIMENTAL_FEATURES = ['par']`、`FeatureFlags.par: boolean`
- `packages/experimental/par/` が実在する
- `.changeset/experimental-par.md`、`docs/library-document/src/content/docs/experimental/par.md` が存在する
- 同ファイル内の他の PAR 分岐（23 / 75 / 3488 / 3905 / 6411 / 6824 行付近）は conflict 外で健在

→ **upstream 側（PAR ブロックあり）が意図された内容**であり、stashed 側は PAR 導入前の古い状態と判断できる。

**(c) `packages/cli/src/frameworks/hono/templates.ts:3203-3239`（両 side 同一）**

生成 UserInfo ルートの `validateUserInfoAudience` → `resolveUserInfoClaims` →
`filterClaimsByScope` → `applyRequestedClaims` の 17 行。両 side が完全一致。

**(d) `packages/cli/src/__tests__/hono-generator.test.ts:313-349`（両 side 同一）**

生成器テストの 17 行。両 side が完全一致。

**(e) `packages/experimental/README.md:1-62`（異なる／決定可能）**

upstream 側は experimental package の完全な README（位置づけ・提供機能表・peerDependency 方針・
依存方向・昇格条件）。stashed 側は冒頭 1 行のみの断片。
upstream 側の記述内容（`par` feature、peer range、`verify-release-contract.mjs` への言及）は
いずれもリポジトリの現状と一致するため、**upstream 側が正**。

### 4.3 現在の影響

- `packages/core/src/client-auth.ts` が構文エラー → `@maronn-openid-connect/core` の **`tsc` ビルドが失敗**する。
  core は全パッケージの土台であり、`pnpm run build` / `pnpm run typecheck` は最初の段階で止まる。
- `packages/cli/src/frameworks/hono/templates.ts` が構文エラー → **CLI がビルドできない**。
  `CLAUDE.md` が定義する利用者の入口（`maronn-oidc generate hono`）が機能しない。
- `vitest` はソースを transform できないため、`pnpm run test:ci` の
  `pnpm --filter "./packages/*" test` が失敗する（＝ **リポジトリ自身のテストが緑にならない**）。
- `ci:publish` は `pnpm run build` を経由するため、**現状の `main` からは publish できない**。

### 4.4 実測による裏取り（2026-08-01）

当初は依存関係を install できない環境での調査だったため上記は静的な推論だったが、
本 study-material を追加した **docs のみの PR #39** の CI（`c05fea7`）で実際に赤くなり、裏取りできた。

```
packages/cli test: Error: Transform failed with 1 error:
  .../packages/cli/src/__tests__/hono-generator.test.ts:313:0: ERROR: Unexpected "<<"
  Plugin: vite:esbuild
  311|        expect(file?.content).not.toContain('await validateAuthorizationCodeGrant(');
  312|        expect(file?.content).not.toContain('await validateRefreshTokenGrant(');
  313|  <<<<<<< Updated upstream
     |  ^
 Test Files  6 failed | 1 passed (7)
 ERR_PNPM_RECURSIVE_RUN_FIRST_FAIL  @maronn-openid-connect/cli@0.0.1 test: `vitest run`
```

確定した事実:

- **`pnpm run test:ci` は現在の `main` を base にすると必ず失敗する。**
  `packages/cli` の 7 テストファイル中 6 が transform 段階で落ちる。
- 失敗はドキュメント変更とは無関係で、**base branch（`main`）に起因する**。
  したがって現時点でこのリポジトリに出されるあらゆる PR の CI が赤になる。
- `packages/core` のテスト自体は個別には緑（`token-request.test.ts` 105 tests /
  `authorization-request.test.ts` 158 tests は成功）。
  つまり **仕様準拠ロジックは壊れておらず、壊れているのは構文レベルのみ**である。
  この点は修正が純粋にマーカー除去で足りることの傍証になる。

> 残る未確認事項: `pnpm run build`（`tsc`）と `pnpm run typecheck` は
> CI で実行されていない（📌 `study-material/done/ci-trigger-coverage-and-static-verification-gate.md`）ため、
> ビルド失敗そのものの実行ログはまだ取得できていない。P0 タスクの修正 PR で確認すること。

## 5. 現在の実装との差分

- **満たしていること**: 5 箇所のうち 3 箇所は両 side が完全一致しており、解消に意味的判断を要さない。
  残り 2 箇所も、周辺コードの参照関係とリポジトリ内の他の証跡から採用すべき side を一意に決定できる。
  すなわち「どう直すか分からない」種類の破損ではない。
- **不足している可能性があること**: `95c9efe` は `git stash pop` のコンフリクトを解消せずに
  `git add -A` して commit した形跡がある。同じ作業で**他にも取りこぼした変更が無いか**、
  `57a9646..95c9efe` の差分全体を確認する必要がある（マーカーが無くても、
  stash 由来の中途半端な適用が混ざっている可能性は排除できていない）。
- **セキュリティ上、改善した方がよいこと**: 直接のセキュリティ欠陥ではないが、
  「配布物が壊れた状態で `main` に存在しうる」こと自体がサプライチェーン健全性の弱点である
  （📌 `study-material/done/supply-chain-security-and-release-integrity.md` / `tasks/p2-supply-chain-ci-security.md` の
  文脈に接続する。ただし本ファイルは provenance / 依存監査とは別論点）。
- **相互運用性の観点**: 現状の `main` を clone した利用者は CLI 生成すらできないため、
  「素早く検証するためのブリッジ」というコンセプトが成立しない。
- **Basic OP として提供する上で確認すべきこと**: conformance 実行系（`pnpm run test:conformance` /
  `conformance:basic-op`）は sample OP の起動に依存し、sample は CLI 生成物であるため、
  この破損が解消されるまで **Basic OP の適合性を再確認する手段そのものが止まっている**。

## 6. 改善・追加を検討する理由

- **なぜ価値があるか**: これは「追加機能」ではなく、リポジトリのあらゆる作業の前提条件である。
  この状態では、他のどの study-material / tasks も検証（テスト実行）まで到達できない。
- **Basic OP として必要か**: Basic OP の要件そのものではない。ただし Basic OP 適合性を
  **証明・維持する手段**（ビルド・テスト・conformance 実行）を復旧させるという意味で、
  他のすべての Basic OP タスクの前提となる。
- **導入しやすさ**: 極めて容易。3 箇所はマーカー削除のみ、2 箇所も採用 side が決定済み。
  新規設計・新規テストを要しない。
- **既存実装との接続**: 既存コードを復元する作業であり、新しい接続点は発生しない。
- **利用者・開発者・運用者のメリット**: 利用者は CLI 生成が復旧する。開発者はテストが動く。
  運用者は publish パイプラインが再び通る。
- **実装しない場合のリスク**: `main` が恒久的にビルド不能のまま残り、
  以後のすべての PR が「元から赤い CI」を前提に進むことになる。
  さらに `changeset-release/main` ブランチが既に存在する（`git ls-remote` で確認）ため、
  Version Packages PR がマージされた場合に**壊れたまま publish を試みる**経路が開いている。

## 7. 実装方針の候補

### 方針A（推奨候補: マーカー解消のみを行う最小 PR）

- 5 箇所すべてで **upstream（`Updated upstream`）側を採用**し、マーカー行を削除する。
  - 両 side 同一の 3 箇所は結果的にどちらを採っても同一。
  - `templates.ts:1658-1735` は upstream を採らないとコンパイル不能。
  - `experimental/README.md` は upstream が現状記述と一致。
- `pnpm run typecheck` / `pnpm run build` / `pnpm run test:ci` が通ることを確認する。
- 機能変更を一切含めない（レビューを容易にし、リバートも安全にする）。

### 方針B（`95c9efe` を revert して再適用）

- `95c9efe` を revert して `57a9646` の状態に戻したうえで、
  「experimentalのpublish設定」の意図した変更だけを改めて正しく適用する。
- 利点: stash 由来の取りこぼしがあった場合も含めて確実に洗い直せる。
- 欠点: `95c9efe` に含まれる正当な変更（experimental の publish 設定）を再現する手間が増える。
  また revert コミットが `main` の履歴に残る。

### 方針C（`95c9efe` を force-push で書き換え）

- 履歴を綺麗にできるが、`main` の公開履歴を書き換えるため他ブランチ・既存 PR との整合が崩れる。
  本リポジトリは PR ベースの運用（`claude/*` ブランチ多数）であり、**採用は推奨しない**。

> どの方針でも、解消後に `57a9646..HEAD` の差分を目視し、
> stash 由来の中途半端な適用が他に無いかを確認する工程は共通で必要。

## 8. タスク案

- [ ] 方針A / B / C を選択（人間判断）。既定の推奨は方針A
- [ ] 5 箇所のマーカーを解消する（両 side 同一の 3 箇所 → 片側採用、残り 2 箇所 → upstream 採用）
- [ ] `pnpm install` → `pnpm run typecheck` → `pnpm run build` → `pnpm run test:ci` が通ることを確認する
- [ ] `57a9646..HEAD` の差分をレビューし、stash 由来の取りこぼしが他に無いことを確認する
- [ ] `packages/cli` を再ビルドし、`samples/*/src/oidc-provider` の生成結果が変わらないことを確認する
- [ ] 各 sample の `conformance.test.ts` が通ることを確認する
- [ ] `changeset-release/main` ブランチの状態を確認し、壊れた内容で publish されない状態であることを確かめる
- [ ] 再発防止（CI ゲート）は 📌 `study-material/done/ci-trigger-coverage-and-static-verification-gate.md` 側で扱う

## 関連トピック

- 📌 `study-material/done/ci-trigger-coverage-and-static-verification-gate.md` — なぜ CI がこれを検知できなかったか（再発防止側）
- 📌 `tasks/p2-supply-chain-ci-security.md` / `study-material/done/supply-chain-security-and-release-integrity.md` — 配布物の完全性（provenance / 依存監査）。本ファイルとは別論点
- 📌 `tasks/done/p2-cli-generated-output-verification-ci.md` — CLI 生成物の CI 検証。本破損により実行できない状態にある
