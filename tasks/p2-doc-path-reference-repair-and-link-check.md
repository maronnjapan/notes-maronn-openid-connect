# [P2] 調査資産の壊れたパス参照（125 件）を修復し、リンク検査を CI に組み込む

## ステータス

🟡 Medium / 未着手（ドキュメント整備 + CI スクリプト追加）

## 背景

`study-material/` と `tasks/` は、次の調査回（人間または AI）が「既に扱われている論点か」を判断するための索引である。
CLAUDE.md と継続調査タスクは、新規トピック作成前にこれらを確認し、既存ファイルを参照する形で書くことを要求している。

この索引が機能する前提は、文書内に書かれた相対パス参照が実在することだが、
**参照されているユニークなパス 460 件のうち 125 件（27.2%）が存在しない**。

| 参照先プレフィックス | 壊れている件数 | 原因 |
|---|---:|---|
| `tasks/…` | 47 | 完了に伴い `tasks/done/` へ移動したが参照元が旧パスのまま。一部は `study-material/` のファイルを `tasks/` として誤記 |
| `packages/…` | 34 | 旧 `packages/sample/`（現存しない）を指す。サンプルは `samples/*` へ移設済み |
| `samples/…` | 28 | 旧命名 `samples/hono` / `samples/express` / `samples/fastify` / `samples/nextjs` を指す |
| `study-material/…` | 13 | `study-material/done/` へ移動済みのファイルを旧パスで参照 |
| `docs/…` / `tests/…` | 3 | 個別調査 |

影響は 2 つある。

1. **重複トピックの発生源になっている。** 参照が壊れていると、規約どおりに既存確認をしても
   到達できず「未追跡」と誤判定する。`tasks/p3-study-material-duplicate-topic-consolidation.md` が
   指摘する重複 5 組は、この誤判定の結果である可能性が高い。
2. **監査ハブが信用できない。** `study-material/basic-op-requirement-traceability.md` は
   「Basic OP 要件 → 実装 → テスト → タスク」の対応表として認定可否の判断根拠になる設計だが、
   実装マップのパス・タスクポインタ・状態列のいずれも陳腐化しており、
   **実装済みの項目を「不足」と誤読させる**（後述）。

検討詳細は `study-material/done/study-asset-broken-path-references.md` を参照。

> 関連: 同一トピックの重複ファイル統合と PAR のステータス陳腐化は
> `tasks/p3-study-material-duplicate-topic-consolidation.md` が扱う。本タスクは
> **パス参照の実在性**に限定する。本タスクを先に実施すると、重複タスク側の判定が正確になる。

## 対象ファイル

- `study-material/**/*.md`（`done/` を含む）
- `tasks/**/*.md`（`done/` を含む）
- `study-material/basic-op-requirement-traceability.md`（状態列の更新を含む）
- `.github/scripts/check-doc-links.mjs`（新規）
- `.github/scripts/check-doc-links.test.mjs`（新規）
- `package.json`（`test:docs-links` スクリプト、`test:ci` への組み込み）
- `.github/workflows/ci.yml`
- `CLAUDE.md`（移動時の参照更新手順）

## 仕様参照

OIDC/OAuth の条文には関わらない。準拠先は本リポジトリの運用規約。

- CLAUDE.md「ディレクトリの構成」: サンプルのディレクトリ名は「フレームワーク-デプロイ想定環境」形式
  （`hono-cloudflare` / `express-flyio` / `fastify-flyio` / `nextjs-vercel`）と規定されている。
  旧名参照はこの規約より前に書かれたもの。
- CLAUDE.md「samples/*」: `samples/*/src/oidc-provider` は `packages/cli` の生成物である。
- 継続調査タスクの前提: 「新しいトピックのファイルを作成する前に、`study-material/` /
  `study-material/done/` / `tasks/` をすべて確認し、同じ論点が扱われていないか確認する」。

## 現状の実装

### 再現手順

```bash
grep -rhoE '(study-material|tasks|packages|samples|tests|docs)/[A-Za-z0-9_./-]+\.(md|ts|mjs|json|yml|sh)' \
  study-material tasks --include=*.md | sort -u > /tmp/refs.txt
while read -r p; do [ -e "$p" ] || echo "$p"; done < /tmp/refs.txt | wc -l
# => 125
```

### 監査ハブの陳腐化（`study-material/basic-op-requirement-traceability.md`）

**(a) 実装マップが存在しないパスを指す**

```
- Authorization Endpoint: packages/core/src/authorization-request.ts、packages/sample/src/oidc-provider/routes/authorize.ts
```

`packages/sample/` は存在しない。

**(b) タスクポインタが存在しない**

`tasks/sub-stability-and-subject-types.md` / `tasks/extension-dynamic-client-registration.md` /
`tasks/basic-op-conformance-verification-plan.md` はいずれも存在せず、実体は `study-material/` 側にある。
`tasks/p0-userinfo-cache-control.md` / `tasks/p2-display-param-validation.md` /
`tasks/p3-registration-param-explicit-rejection.md` / `tasks/p2-acr-values-request-propagation.md` は
`tasks/done/` へ移動済み。

**(c) 状態列が実装と乖離している**

| 行 | 表の記載 | 現在の実装 |
|---|---|---|
| UserInfo の Cache-Control | 🔴 不足 | ✅ 生成コードは UserInfo ハンドラ入口で `Cache-Control: no-store` / `Pragma: no-cache` を設定 |
| `display` の値検証 | 受理（無視）。値検証はタスク | ✅ `validateDisplayParameter`（`packages/core/src/authorization-request.ts`）が page/popup/touch/wap 以外を `invalid_request` で拒否 |
| Request Object（§6） | 🔴 非対応 | ✅ `packages/core/src/request-object.ts` ＋ CLI feature `request-object`（既定 ON）。無効時は `request_not_supported` |
| `registration` パラメータ | 🔴 非対応 | ✅ 実装済み（`tasks/done/p3-registration-param-explicit-rejection.md`） |

### 検出の仕組みが無い

`.github/workflows/ci.yml` はコードのみを検査し、Markdown 内のパス参照は対象外。
一方 `.github/scripts/*.test.mjs` に `node --test`（外部依存なし）でスクリプトを検査する既存パターンがあるため、
同じ枠組みでリンク検査を追加できる。

## 修正方針

### A. 表記規約を先に決める（他のすべての前提）

- [ ] 生成コードの例として引用する場合の表記を決める。候補:
  - A-1: 代表フレームワークに固定する（`samples/hono-cloudflare/src/oidc-provider/routes/token.ts`）
  - A-2: グロブ表記に統一する（`samples/*/src/oidc-provider/routes/token.ts`）
  - A-3: 生成元テンプレートを指す（`packages/cli/src/frameworks/hono/templates.ts`）
- [ ] リンク検査スクリプトがグロブ表記を許容するかどうかを、上の決定に合わせて定める
      （A-2 を採る場合、`*` を含むパスは実在チェックの対象外とするか、展開して 1 件以上一致することを要求するかを決める）

### B. 一括修復

- [ ] `packages/sample/` を参照する 75 ファイル・152 箇所を、A で決めた表記へ置換する
- [ ] `samples/hono` / `samples/express` / `samples/fastify` / `samples/nextjs` の旧名を、
      現行ディレクトリ名（`hono-cloudflare` / `express-flyio` / `fastify-flyio` / `nextjs-vercel`）へ置換する
      （Next.js の生成物パスは `samples/nextjs-vercel/src/app/_oidc-provider/…` である点に注意）
- [ ] `tasks/xxx.md` のうち `tasks/done/xxx.md` が実在するものを機械判定して張り替える
- [ ] `study-material/xxx.md` のうち `study-material/done/xxx.md` が実在するものを張り替える
- [ ] ディレクトリごと誤っている参照（`tasks/sub-stability-and-subject-types.md` 等）を実体へ張り替える
- [ ] 上記のいずれでも解決しない参照（実体が存在しない・命名が変わった）は個別に判断し、
      解決できないものは参照そのものを削除するか「（未作成）」と明記する

### C. 監査ハブの更新

- [ ] `study-material/basic-op-requirement-traceability.md` の実装マップを現行パスへ更新する
- [ ] タスクポインタを実在するパス（`tasks/done/…` を含む）へ張り替える
- [ ] 状態列の 4 行（UserInfo Cache-Control / `display` 値検証 / Request Object / `registration`）を ✅ へ更新し、
      根拠となる実装ファイルとタスクを併記する
- [ ] 「6.7 Pre-Certification」の 🟡 行が現状と合っているかを確認する
- [ ] 表の更新運用（同ファイル §8 の A 案 / B 案）が未決のままである旨を明記するか、この機会に決める

### D. 再発防止（リンク検査の CI 化）

- [ ] `.github/scripts/check-doc-links.mjs` を追加する（外部依存なし、Node 標準 API のみ）
  - `study-material/**/*.md` と `tasks/**/*.md` を走査
  - `(study-material|tasks|packages|samples|tests|docs)/…` 形式のパスを抽出
  - コードフェンス（``` で囲まれた範囲）内は除外する
  - 存在しないパスがあれば一覧を出力して非ゼロ終了する
  - 除外が必要なケース向けに allowlist ファイル（例: `.github/scripts/doc-links-allowlist.txt`）を用意する。
    **少なくとも次の 2 ファイルは、壊れた参照そのものを証跡として本文に引用しているため除外対象になる**:
    `study-material/done/study-asset-broken-path-references.md` と本タスクファイル
    （`tasks/p2-doc-path-reference-repair-and-link-check.md`）。
    また `xxx.md` / `foo.md` のような説明用のプレースホルダ表記をどう扱うかも決める
- [ ] `.github/scripts/check-doc-links.test.mjs` を `node --test` 形式で追加する
      （既存の `test:supply-chain` と同じ枠組み）
- [ ] `package.json` に `test:docs-links` を追加し、`test:ci` から呼ぶ
- [ ] `.github/workflows/ci.yml` で実行されることを確認する

### E. 手順の明文化

- [ ] CLAUDE.md に次を追記する
  - `study-material/` → `study-material/done/`、`tasks/` → `tasks/done/` へ移動したら、
    `grep -rn "<旧パス>" study-material tasks` で参照元を更新する
  - 生成コードを参照する際の表記規約（A で決めたもの）

## テスト要件

コード（ライブラリ）の挙動は変わらないため OP の単体テストは追加しないが、以下を機械的に確認する。
`check-doc-links` のテストケース名は「should + 動詞」形式で書くこと。

- [ ] `should exit with a non-zero code when a referenced path does not exist`
- [ ] `should exit with a zero code when every referenced path exists`
- [ ] `should ignore paths that appear inside fenced code blocks`
- [ ] `should report every broken reference with its source file and line number`
- [ ] 修復後に、再現手順の壊れた参照件数が **0 件**になること

  ```bash
  grep -rhoE '(study-material|tasks|packages|samples|tests|docs)/[A-Za-z0-9_./-]+\.(md|ts|mjs|json|yml|sh)' \
    study-material tasks --include=*.md | sort -u \
    | while read -r p; do [ -e "$p" ] || echo "$p"; done | wc -l
  # => 0
  ```

- [ ] `grep -rn "packages/sample/" study-material tasks | wc -l` が 0 になること
- [ ] `grep -rnE "samples/(hono|express|fastify|nextjs)/" study-material tasks | wc -l` が 0 になること

## 完了条件

- [ ] 壊れたパス参照が 0 件になっていること（上記コマンドで確認）
- [ ] `study-material/basic-op-requirement-traceability.md` の実装マップ・タスクポインタ・状態列が現状と一致すること
- [ ] `pnpm test:docs-links` が追加され、CI で実行されること
- [ ] 下記がパスすること

  ```bash
  pnpm test:docs-links
  pnpm test:ci
  ```

- [ ] CLAUDE.md に、ファイル移動時の参照更新手順と生成コード参照の表記規約が追記されていること
