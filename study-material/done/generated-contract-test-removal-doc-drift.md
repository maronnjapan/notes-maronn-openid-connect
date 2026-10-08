# 生成契約テスト廃止（PR #119）に伴うタスク文書の追随

## このトピックで確認したいこと

PR #119（commit cb33342）で、CLI が生成コードと一緒に出力していた契約テスト `conformance.test.ts` が廃止された。
README の「テストコードの書き方」も「CLI が生成するコードのテストは書かない。生成 OP の挙動は `tests/e2e` と `tests/conformance` で確認する」という方針へ改められた。

一方、`tasks/` と `study-material/` の多数の文書は、廃止前に書かれたため「`packages/cli` の `conformance.test.ts` 生成コードに契約テストを追加する」という手順・テスト要件・完了条件を今も含んでいる。
このままでは、次にタスクへ着手するセッション（人間または AI）が README 方針に反する手順を実行するか、存在しない生成物を探して止まる。
このファイルでは乖離の範囲を確定し、修正の方針を整理する。

## 関連する仕様・基準

OIDC / OAuth の条文には関わらない。準拠先は本リポジトリのテスト方針である。

- README「テストコードの書き方」：生成コードのテストは書かない。生成物の文字列・ファイル構成を検査する単体テストも、生成物に含めて出力するテストも追加しない
- CLAUDE.md「タスクと調査資料」：`tasks/` と `study-material/` は次の調査回の索引であり、着手可能な正確さを保つ

## 参照資料

- OSS リポジトリ commit `cb33342`（PR #119。2026-10-07 マージ）：hono / web-standard / Next.js のテンプレートから契約テスト生成を削除し、4 sample の `conformance.test.ts` を削除。README・docs・JSDoc から契約テストへの言及を除去
- `.changeset/drop-generated-conformance-test.md`（同 PR）：変更の公開告知
- 本ファイル作成時の実測：`grep -rln "conformance\.test\.ts" tasks/*.md` が 38 件、`study-material/*.md`（done を除く）が 20 件以上に一致

## 現在の実装確認

- `packages/cli/src/frameworks/*/templates.ts` に契約テストを生成するコードは存在しない
- `samples/*/src/oidc-provider/` に `conformance.test.ts` は存在しない
- 生成 OP の挙動確認は `tests/e2e`（Playwright）と `tests/conformance`（OIDF Conformance Suite の runner）が担う

## 現在の実装との差分

文書側の記載が実装・方針の双方から乖離している。影響は三段階に分かれる。

1. **タスクの前提そのものが消滅**：`tasks/p1-exec-conformance-test.md` は「生成された `conformance.test.ts` の未定義参照を直し、テストランナーへ接続する」タスクだが、PR #119 は接続ではなく廃止でこの問題を解消した。タスクは実装せず廃止として `tasks/done/` へ移動する（本トピックのタスク化と同時に実施）
2. **手順・テスト要件の一部が実行不能**：`tasks/` 配下の現役タスクのうち 30 件超が、「対象ファイル」「修正方針」「テスト要件」「完了条件」のいずれかで `conformance.test.ts` への契約テスト追加・更新・パスを要求している。該当タスクの本題（OP の挙動修正）は有効なまま、検証手段の記載だけが無効になっている
3. **実装状況の記載が陳腐化**：`tasks/p2-op-cookie-host-prefix.md` は、PR #112（commit 180f662）でトランザクション Cookie が `__Host-oidc_txn` へ置き換わったため、5 系統の対象 Cookie のうち 1 系統が別方式で対応済みになった（同タスクへ追記済み）

2 の該当ファイルは `grep -rln "conformance\.test\.ts" tasks/*.md` で機械的に列挙できるため、ここでの全列挙はしない。
なお `tasks/p2-doc-path-reference-repair-and-link-check.md` が扱う「壊れたパス参照の修復」とは原因が異なる（あちらはファイル移動・改名、こちらは方針変更による手段の無効化）が、`samples/*/conformance.test.ts` への参照はパスとしても実在しなくなったため、リンク検査を導入すれば再発は機械的に検出できる。

## 改善・追加を検討する理由

- タスク文書は「そのまま着手できる粒度」を価値とする資産であり、検証手段の記載が方針違反のままでは、着手のたびに読み替えコストと誤実装リスクが生じる
- 特にテスト要件・完了条件は実装セッションがそのまま実行する箇所であり、「生成物にテストを追加する」という指示は README の禁止事項と正面衝突する
- 放置した場合、`conformance.test.ts` を再生成・再導入する誤修正が起きうる

## 実装方針の候補

最終判断は人間が行う。候補は次の三つである。

- **案 A（一括置換）**：現役タスク全件を走査し、`conformance.test.ts` への契約テスト指示を「`tests/e2e` への Playwright スペック追加」または「挙動確認は `tests/e2e` / `tests/conformance` で行う」へ書き換える。確実だが変更量が多い
- **案 B（読み替え規約）**：CLAUDE.md に「タスク文書中の `conformance.test.ts` への契約テスト指示は `tests/e2e` への追加と読み替える」という一文を置く。変更は最小だが、個々のタスクの検証粒度（単体で固定できた期待値を E2E でどう固定するか）は着手時の判断に委ねられる
- **案 C（A + 着手時判断）**：機械的に置換できる参照（対象ファイル欄・完了条件のコマンド）は案 A で直し、テスト要件の具体的な期待値は各タスク着手時に E2E へ翻訳する。その旨をタスク冒頭の注記で示す

## タスク案

- `tasks/` 配下の現役タスクから `conformance.test.ts` への契約テスト指示を一掃し、`tests/e2e` 方針へ書き換える（→ `tasks/p2-doc-generated-contract-test-reference-sweep.md` としてタスク化済み）
- `tasks/p1-exec-conformance-test.md` を廃止として `tasks/done/` へ移動する（本トピックの反映と同時に実施済み）
- リンク実在性の機械検査は `tasks/p2-doc-path-reference-repair-and-link-check.md` の CI スクリプトに委ね、本件では重複して作らない
