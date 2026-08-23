# 調査資産（`study-material/` / `tasks/`）のファイルパス参照が 4 分の 1 以上壊れている

## 1. このトピックで確認したいこと

`study-material/` と `tasks/` は、本リポジトリにおいて **次の調査回（人間または AI）が「既に扱われている論点か」を判断するための索引**として機能する。
CLAUDE.md と継続調査タスクは、新しいトピックを作る前にこれらを確認し、
「既存ファイルを参照する形で記載する」「同じ説明を繰り返さない」ことを明示的に要求している。

この索引が機能する前提は、**ファイル内に書かれた相対パス参照が実在すること**である。
本ファイルでは、参照の実在率を機械的に測定し、壊れている参照の種類と原因、再発防止策を整理する。

測定結果（本ファイル作成時点）: **参照されているユニークなパス 460 件のうち 125 件（27.2%）が存在しない。**

> `study-material/` の**重複ファイル**（同一トピックが 2 本ある）と PAR のステータス陳腐化は
> `tasks/p3-study-material-duplicate-topic-consolidation.md` が扱う。本ファイルは
> **パス参照の実在性**という別軸に限定し、重複しない。

## 2. 関連する仕様・基準

OIDC/OAuth の条文には関わらない。対応する基準は本リポジトリの運用規約のみ。

- **CLAUDE.md「レビュー内容について」**: レビュー JSON は `targetFile` で対象を指すため、パスの正確性が前提。
- **CLAUDE.md「ディレクトリの構成」**: サンプルのディレクトリ名は
  「フレームワーク-デプロイ想定環境」形式（`hono-cloudflare` / `express-flyio` / `fastify-flyio` / `nextjs-vercel`）と規定されている。
  この規約が導入される前に書かれた文書は `samples/hono` 等の旧名を参照している。
- **継続調査タスクの前提**: 「新しいトピックのファイルを作成する前に、上記すべてのディレクトリを確認し、
  同じ論点がすでに扱われていないかを確認してください」。
  参照が壊れていると、この確認が「ファイルが無い＝未追跡」という**誤った結論**に落ちる。

## 3. 参照資料

- 本リポジトリ `CLAUDE.md`（ディレクトリ構成規約 / 調査資産の運用手順）
- 本リポジトリ `tasks/p3-study-material-duplicate-topic-consolidation.md`（重複トピック統合。本ファイルの隣接タスク）
- 本リポジトリ `study-material/done/study-material-topic-duplication-and-status-drift.md`（重複とステータス陳腐化の検討）
- 測定手順（再現可能）:

  ```bash
  grep -rhoE '(study-material|tasks|packages|samples|tests|docs)/[A-Za-z0-9_./-]+\.(md|ts|mjs|json|yml|sh)' \
    study-material tasks --include=*.md | sort -u > /tmp/refs.txt
  while read -r p; do [ -e "$p" ] || echo "$p"; done < /tmp/refs.txt
  ```

## 4. 現在の実装確認

### 4.1 測定結果の内訳

| 参照先プレフィックス | 壊れている件数 | 原因 |
|---|---:|---|
| `tasks/…` | 47 | タスク完了に伴い `tasks/done/` へ移動したが、参照元が旧パスのまま。一部は `study-material/` のファイル名を `tasks/` として誤記 |
| `packages/…` | 34 | 旧 `packages/sample/`（現在は存在しない）を指す。サンプルは `samples/*` へ移設済み |
| `samples/…` | 28 | 旧命名 `samples/hono` / `samples/express` / `samples/fastify` / `samples/nextjs` を指す。現行は `hono-cloudflare` / `express-flyio` / `fastify-flyio` / `nextjs-vercel` |
| `study-material/…` | 13 | `study-material/done/` へ移動済みのファイルを旧パスで参照 |
| `docs/…` / `tests/…` | 3 | 個別要調査 |
| **合計** | **125 / 460（27.2%）** | |

`packages/sample/` を参照しているファイルは 75 件・152 箇所。うち `done/` を除いた「現役」の文書は
`study-material/` 直下 34 件、`tasks/` 直下 2 件（`tasks/p3-introspection-caller-authorization-hook.md`、
`tasks/p2-signing-alg-ps256.md`）である。

### 4.2 具体例: `study-material/basic-op-requirement-traceability.md`

このファイルは自身を「Basic OP 認定要件 → 実装 → テスト → 既存タスクの対応表（監査ハブ）」と位置づけており、
索引の中核であるが、次のすべてが壊れている。

**(a) 実装マップのパスが存在しない**

```
- Authorization Endpoint: packages/core/src/authorization-request.ts、packages/sample/src/oidc-provider/routes/authorize.ts
- Token Endpoint: packages/core/src/token-request.ts / token-response.ts、routes/token.ts
```

`packages/sample/` は存在しない。正しくは `samples/<framework>/src/oidc-provider/routes/authorize.ts`
（Next.js は `samples/nextjs-vercel/src/app/_oidc-provider/…`）。

**(b) タスクへのポインタが存在しない**

| 表中の記載 | 実在するか |
|---|---|
| `tasks/sub-stability-and-subject-types.md` | ❌（実体は `study-material/sub-stability-and-subject-types.md`） |
| `tasks/extension-dynamic-client-registration.md` | ❌（実体は `study-material/extension-dynamic-client-registration.md`） |
| `tasks/basic-op-conformance-verification-plan.md` | ❌（実体は `study-material/basic-op-conformance-verification-plan.md`） |
| `tasks/p0-userinfo-cache-control.md` | ❌（`tasks/done/` に移動済み） |
| `tasks/p2-display-param-validation.md` | ❌（`tasks/done/` に移動済み） |
| `tasks/p3-registration-param-explicit-rejection.md` | ❌（`tasks/done/` に移動済み） |
| `tasks/p2-acr-values-request-propagation.md` | ❌（`tasks/done/` に移動済み） |

**(c) 状態列が実装と乖離している**

| 行 | 表の記載 | 現在の実装 |
|---|---|---|
| UserInfo の Cache-Control | 🔴 不足 | ✅ 実装済み。生成コードは UserInfo ハンドラ入口で `Cache-Control: no-store` / `Pragma: no-cache` を設定する |
| `display` の値検証 | 「受理（無視）。値検証は 📌 タスク」 | ✅ 実装済み。`validateDisplayParameter`（`packages/core/src/authorization-request.ts:1065`）が page/popup/touch/wap 以外を `invalid_request` で拒否 |
| Request Object（§6） | 🔴 非対応 | ✅ 実装済み。`packages/core/src/request-object.ts` と CLI feature `request-object`（既定 ON）。無効時は `request_not_supported` |
| `registration` パラメータ | 🔴 非対応 | ✅ 実装済み（`tasks/done/p3-registration-param-explicit-rejection.md`） |

つまり **監査ハブとして参照すると、実装済みの項目を「不足」と誤読する**。

### 4.3 検出の仕組みが無い

- `.github/workflows/ci.yml` はコード（型検査・lint・単体・conformance・supply chain）を検査するが、
  Markdown 内のパス参照は検査対象外。
- `.github/scripts/*.test.mjs` に既存の Node 標準テストの枠組み（`node --test`、外部依存なし）があり、
  同じ枠組みでリンク検査を足せる素地はある。

## 5. 現在の実装との差分

満たしていること:

- ✅ 調査資産そのものは非常に厚く（`study-material/` 113 + `done/` 83、`tasks/` 45 + `done/` 多数）、
  トピックの網羅性は高い。
- ✅ 「新規作成前に既存を確認する」という運用規約は文書化されている。
- ✅ 重複トピックの整理は別タスクで追跡中。

不足している可能性があること:

- 🔴 **参照の 27% が壊れている**ため、規約どおりに既存確認を行っても正しい既存ファイルへ到達できない。
  これは「同じ論点を別ファイルで再度書く」＝重複トピックの**発生源**でもある
  （`tasks/p3-study-material-duplicate-topic-consolidation.md` が扱う 5 組の重複と因果関係がある可能性が高い）。
- 🔴 **監査ハブ（`basic-op-requirement-traceability.md`）の状態列が実装と乖離**しており、
  「Basic OP として何が足りないか」を機械的に追う目的を果たしていない。
- 🟠 **移動時に参照を追随させる手順が無い**。`study-material/` → `done/`、`tasks/` → `tasks/done/` の移動は
  継続調査タスクの定常作業だが、参照元の更新は手順に含まれていない。
- 🟠 **検出の自動化が無い**ため、修正しても再び壊れる。

セキュリティ上の観点:

- 🟢 直接のセキュリティ影響は無い。
- 🟡 ただし、セキュリティ関連の未追跡項目を「追跡済み」と誤認する／逆に対応済みを「未対応」と誤認することで、
  優先順位の判断を誤らせる二次的なリスクはある（4.2(c) の 4 行がまさにその例）。

Basic OP として提供する上で確認すべきこと:

- 🟠 認定準備の判断は `basic-op-requirement-traceability.md` を根拠にする設計になっている。
  この表が信用できない状態では、認定に進む/進まないの判断材料が無い。

## 6. 改善・追加を検討する理由

**なぜ価値があるのか**

- 本リポジトリは「継続的に調査 → study-material → tasks → 実装」というループを回す運用を採っている。
  そのループの入力である索引が 27% 壊れていると、**ループを回すほど重複と誤判断が増える**。
  規模（240 ファイル超）が大きいほど、人手での確認は現実的でなくなる。
- 修正自体は機械的で、判断を要する箇所が少ない（旧パス → 新パスの対応は一意に決まるものが大半）。
- 再発防止（リンク検査の CI 化）は外部依存なしで実装でき、既存の `node --test` 枠組みに乗る。

**Basic OP 必須か、拡張として有用か**

- どちらでもない。OIDF 認定要件ではないが、**認定可否の判断根拠を回復する**という意味で
  Fidelity 軸の前提条件にあたる。

**現在の構成から見た導入しやすさ**

- 🟢 `packages/sample/` → `samples/<framework>/` の置換は、対象が一意に決まらないケース
  （どのフレームワークのサンプルを指すか）を除けば機械的。ほとんどの記述は「生成コードの例」として
  引用しているので、代表として `samples/hono-cloudflare/…` を採るか、
  「`samples/*/src/oidc-provider/…`」というグロブ表記に統一するかの判断が 1 つ要る。
- 🟢 `tasks/xxx.md` → `tasks/done/xxx.md` は実在確認で自動判定できる。
- 🟡 `tasks/sub-stability-and-subject-types.md` のように **ディレクトリごと誤っている**参照は、
  実体（`study-material/` 側）へ張り替える判断が要る。
- 🟢 リンク検査スクリプトは `.github/scripts/` に置き、`node --test` で回す既存パターンに合わせられる。

**既存実装との接続**

- `package.json` の `test:supply-chain`（`node --test .github/scripts/*.test.mjs`）と同じ形で
  `test:docs-links` を足せる。CI 追加は 1 行。

**利用者・開発者・運用者のメリット**

- 次回以降の調査回（人間・AI とも）が、既存トピックへ確実に到達できる。重複調査のコストが下がる。
- 監査ハブが再び信用できるようになり、「Basic OP として何が残っているか」が 1 ファイルで分かる。

**実装しない場合に残るリスク**

- 重複トピックが増え続ける（既に 5 組が発生している）。
- 実装済み項目を「不足」と誤認したタスクが作られる／逆に未対応が見落とされる。
- 索引の信頼性が落ちるほど、CLAUDE.md の「重複を避けよ」という指示が守れなくなる。

## 7. 実装方針の候補（最終判断は人間が行う）

### 方針A: 一括修正のみ（スクリプトで機械置換 + 手動レビュー）

- 旧パス → 新パスの対応表を作り、`study-material/` / `tasks/` 全体に適用する。
- `done/` 配下の履歴文書も対象にするかを決める（対象にすると差分が大きいが、索引としての一貫性は上がる）。
- 利点: 一度で解消する。
- 欠点: 再発防止が無いため、次の移動でまた壊れる。

### 方針B: 方針A + リンク検査の CI 化（推奨候補）

- `.github/scripts/check-doc-links.mjs`（外部依存なし）を追加。
  `study-material/**` / `tasks/**` の Markdown から `(study-material|tasks|packages|samples|tests|docs)/…` 形式の
  パスを抽出し、存在しないものがあれば非ゼロ終了する。
- `package.json` に `test:docs-links` を追加し、`test:ci` から呼ぶ。
- 利点: 再発しない。ファイル移動時に CI が気づく。
- 欠点: 誤検出の扱い（意図的に将来のパスを書く、コードブロック内の擬似パス等）を除外する仕組みが要る。
  除外は「コードフェンス内を無視する」「明示的な allowlist ファイルを持つ」のいずれか。

### 方針C: 方針B + 移動手順の明文化

- CLAUDE.md に「`study-material/` → `done/`、`tasks/` → `tasks/done/` へ移動したら、
  `grep -rn "<旧パス>" study-material tasks` で参照を更新する」を追記。
- 利点: 人間・AI ともに手順として守れる。
- 欠点: 手順は守られないことがあるため、方針B の自動検査と併用が前提。

### 方針D: 相対リンクをやめ、ファイル名のみで参照する

- `study-material/foo.md` ではなく `foo.md`（あるいはトピック名）で参照し、ディレクトリ移動に影響されなくする。
- 利点: `done/` への移動で壊れない。
- 欠点: 曖昧さが増える（同名ファイルの区別ができない）。既存 240 ファイルの書き換えコストが大きい。

### 方針E: `basic-op-requirement-traceability.md` の状態列を先に直す（部分対応）

- 参照修正とは独立に、4.2(c) の 4 行だけを実装状況に合わせて更新する。
- 利点: 監査ハブの誤読リスクを最短で消せる。
- 欠点: 他の陳腐化は残る。運用（更新のトリガ）を決めないと再発する。

**判断材料の要約**

- 方針B が費用対効果の中心。方針A 単独は再発するため推奨しない。
- 方針E は方針B と独立に先行実施できる（監査ハブの誤読リスクが最も高いため、優先度を上げる価値がある）。
- 方針D は既存資産の規模から見て割に合わない。

## 8. タスク案

- [ ] `packages/sample/` を参照している 75 ファイル・152 箇所を棚卸しし、`samples/*/src/oidc-provider/…` へ置換する
      （代表フレームワーク固定かグロブ表記かの表記規約を先に決める）
- [ ] `samples/hono` / `samples/express` / `samples/fastify` / `samples/nextjs` の旧名参照を、
      現行のディレクトリ名（`hono-cloudflare` / `express-flyio` / `fastify-flyio` / `nextjs-vercel`）へ置換する
- [ ] `tasks/xxx.md` のうち `tasks/done/xxx.md` に実在するものを機械判定して張り替える
- [ ] ディレクトリごと誤っている参照（`tasks/sub-stability-and-subject-types.md` 等）を実体へ張り替える
- [ ] `study-material/xxx.md` のうち `study-material/done/xxx.md` に実在するものを張り替える
- [ ] `basic-op-requirement-traceability.md` の実装マップ・タスクポインタ・状態列を現状に合わせて更新する
      （UserInfo Cache-Control / display 値検証 / Request Object / registration の 4 行は ✅ へ）
- [ ] `.github/scripts/check-doc-links.mjs`（外部依存なし）を追加し、`node --test` で回るテストを付ける
- [ ] `package.json` に `test:docs-links` を追加し、`test:ci` から呼ぶ
- [ ] CLAUDE.md に「ファイル移動時は参照を更新する」手順を追記する

## 関連トピック

- `tasks/p3-study-material-duplicate-topic-consolidation.md` — 重複トピックの統合。本ファイルはその**発生源**にあたる
  参照の壊れを扱う。順序としては本ファイルの修正を先に行うと、重複判定が正しくできるようになる。
- `study-material/done/study-material-topic-duplication-and-status-drift.md` — 重複とステータス陳腐化の検討。
- `study-material/basic-op-requirement-traceability.md` — 本ファイルが指摘する監査ハブ。修正対象。
- `study-material/current-implementation-documentation-backlog.md` — 実装ドキュメントの不足。参照先パスは同様に要修正。
