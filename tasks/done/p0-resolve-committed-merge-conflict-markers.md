# [P0] `main` に commit された未解決マージコンフリクトマーカーを解消する

## ステータス

🔴 Critical / 未着手

## 背景

`origin/main` の HEAD（`95c9efe` 「experimentalのpublish設定」）に、未解決の Git コンフリクトマーカー
（`<<<<<<< Updated upstream` / `=======` / `>>>>>>> Stashed changes`）が **4 ファイル・5 箇所**、
ソースコードごと commit されている。ラベルからして `git stash pop` のコンフリクトを解消せずに
`git add` して commit したものと考えられる。

`95c9efe` は親が 1 つの通常コミットであり、PR を経由していない。
`.github/workflows/ci.yml` のトリガは `on: pull_request` のみなので、
このコミットは **CI に一度もかかっていない**。

影響:

- `packages/core/src/client-auth.ts` が構文エラー → `@maronn-openid-connect/core` の `tsc` ビルドが失敗する
- `packages/cli/src/frameworks/hono/templates.ts` が構文エラー → **CLI がビルドできない**。
  CLAUDE.md が定義する利用者の入口（`maronn-oidc generate hono`）が機能しない
- `vitest` がソースを transform できず、`pnpm run test:ci` が失敗する
- `ci:publish` は `pnpm run build` を経由するため、現状の `main` からは publish できない。
  リモートには `changeset-release/main` ブランチが既に存在しており、
  Version Packages PR がマージされると壊れたまま publish を試みる経路が開いている
- sample OP は CLI 生成物であるため、Basic OP 適合性を再確認する手段（conformance 実行）も止まっている

### 実測（2026-08-01）

docs のみの PR #39 の CI（`c05fea7`）で実際に確認済み。

```
packages/cli test: Error: Transform failed with 1 error:
  .../packages/cli/src/__tests__/hono-generator.test.ts:313:0: ERROR: Unexpected "<<"
 Test Files  6 failed | 1 passed (7)
 ERR_PNPM_RECURSIVE_RUN_FIRST_FAIL  @maronn-openid-connect/cli@0.0.1 test: `vitest run`
```

- **現在の `main` を base にする PR は、内容にかかわらず CI が赤になる**
- `packages/core` のテスト自体は個別には緑（`token-request.test.ts` 105 tests /
  `authorization-request.test.ts` 158 tests は成功）。壊れているのは構文レベルのみであり、
  仕様準拠ロジックには影響していない

検討詳細は `study-material/done/released-source-unresolved-merge-conflict-markers.md` を参照。

> 再発防止（CI トリガ拡張・typecheck / build ゲート）は
> `tasks/p1-ci-push-trigger-and-static-verification-gate.md` が扱う。本タスクは現物の解消に限定する。

## 対象ファイル

| ファイル | 行範囲 | upstream 側 | stashed 側 | 両 side 同一か |
|---|---|---|---|---|
| `packages/core/src/client-auth.ts` | 192–202 | 4 行 | 4 行 | **同一** |
| `packages/cli/src/frameworks/hono/templates.ts` | 1658–1735 | 75 行 | 0 行 | 異なる |
| `packages/cli/src/frameworks/hono/templates.ts` | 3203–3239 | 17 行 | 17 行 | **同一** |
| `packages/cli/src/__tests__/hono-generator.test.ts` | 313–349 | 17 行 | 17 行 | **同一** |
| `packages/experimental/README.md` | 1–62 | 58 行 | 1 行 | 異なる |

## 仕様参照

OIDC / OAuth の条文には関わらない。準拠先は Git / TypeScript の仕様と本リポジトリの方針。

- Git: コンフリクトマーカーの形式 — https://git-scm.com/docs/git-merge#_how_conflicts_are_presented
  `<<<<<<<` / `=======` / `>>>>>>>` はそのままではどの言語としても構文エラーになる
- Git: `git stash` — https://git-scm.com/docs/git-stash
  ラベル `Updated upstream` / `Stashed changes` は `git stash pop` 由来であることを示す
- CLAUDE.md「利用者の入口」: CLI 生成が利用者の入口である。CLI がビルドできない状態は入口が塞がっていることを意味する
- CLAUDE.md「samples/\*」: `samples/*/src/oidc-provider` は生成物であり、修正は `packages/cli` 側で行う
- `RELEASE.md` / `package.json`: `ci:publish` は `pnpm run build` を前提とする

## 現状の実装

### (a) `packages/core/src/client-auth.ts:192-202` — 両 side 同一

`extractClientCredentials` の末尾。両 side とも次で完全一致する。マーカー削除のみでよい。

```ts
  return { clientId, clientSecret, method };
}
```

### (b) `packages/cli/src/frameworks/hono/templates.ts:1658-1735` — upstream を採る

upstream 側だけが experimental PAR（RFC 9126）の生成テンプレート断片
（`parImports` / `parParamsBinding` / `parResolveStep` / `parCatchBranch`）を定義している。
stashed 側はこのブロックが丸ごと無い。

**stashed 側を採ると同ファイル下流（1786 行の ``${parImports}`` など）が未定義参照になり、
そもそも `tsc` が通らない。** 加えて次の証跡が upstream 側の正当性を裏づける。

- `packages/cli/src/features.ts`: `EXPERIMENTAL_FEATURES = ['par']` / `FeatureFlags.par: boolean`
- `packages/experimental/par/` が実在する
- `.changeset/experimental-par.md` / `docs/library-document/src/content/docs/experimental/par.md` が存在する
- 同ファイル内の他の PAR 分岐（23 / 75 / 3488 / 3905 / 6411 / 6824 行付近）は conflict 外で健在

### (c) `packages/cli/src/frameworks/hono/templates.ts:3203-3239` — 両 side 同一

生成 UserInfo ルートの `validateUserInfoAudience` → `resolveUserInfoClaims` →
`filterClaimsByScope` → `applyRequestedClaims` の 17 行。完全一致。

### (d) `packages/cli/src/__tests__/hono-generator.test.ts:313-349` — 両 side 同一

生成器テストの 17 行。完全一致。

### (e) `packages/experimental/README.md:1-62` — upstream を採る

upstream 側は experimental package の完全な README（位置づけ / 提供機能表 / peerDependency 方針 /
依存方向 / 昇格条件）。stashed 側は冒頭 1 行のみの断片。
upstream 側の記述内容（`par` feature、peer range、`verify-release-contract.mjs` への言及）は
いずれもリポジトリの現状と一致する。

## 修正方針

**すべてのコンフリクトで upstream（`Updated upstream`）側を採用し、マーカー行を削除する。**
両 side 同一の 3 箇所は結果的にどちらを採っても同一になる。
機能変更は一切含めない（レビューを容易にし、リバートも安全にする）。

- [ ] `packages/core/src/client-auth.ts:192-202` のマーカーを削除し、`return { clientId, clientSecret, method };` を 1 つだけ残す
- [ ] `packages/cli/src/frameworks/hono/templates.ts:1658-1735` を upstream 側（PAR ブロック 75 行）に解消する
- [ ] `packages/cli/src/frameworks/hono/templates.ts:3203-3239` のマーカーを削除し、17 行を 1 つだけ残す
- [ ] `packages/cli/src/__tests__/hono-generator.test.ts:313-349` のマーカーを削除し、17 行を 1 つだけ残す
- [ ] `packages/experimental/README.md:1-62` を upstream 側（完全な README）に解消する
- [ ] リポジトリ全体を再走査し、コンフリクトマーカーが 0 件であることを確認する
- [ ] `57a9646..HEAD` の差分を目視し、`git stash pop` 由来の中途半端な適用が他に無いことを確認する
      （マーカーが残っていない箇所でも、片側だけ適用された変更が混ざっている可能性は排除できていない）

検出コマンド（0 件になること）:

```bash
grep -rn '^<<<<<<< \|^>>>>>>> \|^=======$' \
  --include='*.ts' --include='*.tsx' --include='*.js' --include='*.mjs' \
  --include='*.json' --include='*.md' \
  packages samples tests scripts
```

## テスト要件

- [ ] `pnpm install` が成功する
- [ ] `pnpm run typecheck` が成功する（`packages/*` が `tsc` を通る）
- [ ] `pnpm run build` が成功する（core / experimental / cli のビルド）
- [ ] `pnpm run test:ci` が成功する（supply-chain / release-contract / packages のテスト / conformance）
- [ ] `pnpm run build:cli` 後に `samples/*/src/oidc-provider` を再生成し、**生成結果が現行と一致する**
      （PAR ブロックを復元しても既定 feature（`par: false`）では生成物が変わらないこと）
- [ ] 各 sample の `conformance.test.ts` が通る
- [ ] `maronn-oidc generate hono --enable par` が成功し、PAR ルートを含む生成物が出力される
      （upstream 側を採った根拠の実地確認）
- [ ] 上記 `grep` によるマーカー検出が 0 件

## 完了条件

```bash
pnpm install
pnpm run typecheck
pnpm run build
pnpm run test:ci
grep -rn '^<<<<<<< \|^>>>>>>> \|^=======$' --include='*.ts' --include='*.md' packages samples tests scripts
# → 何も出力されないこと
```

- 上記がすべて成功する
- `changeset-release/main` ブランチの状態を確認し、壊れた内容で publish されない状態であることを確かめている
- 再発防止は `tasks/p1-ci-push-trigger-and-static-verification-gate.md` に引き継がれている
