# [P2] 現役タスクから廃止済み契約テスト（conformance.test.ts）への指示を一掃する

## ステータス

🟡 Medium / 未着手（ドキュメント整備。OSS リポジトリのコードは変更しない）

## 背景

PR #119（commit cb33342、2026-10-07）で、CLI が生成していた契約テスト `conformance.test.ts` が廃止された。
README の「テストコードの書き方」も「CLI が生成するコードのテストは書かない。生成 OP の挙動は `tests/e2e` と `tests/conformance` で確認する」という方針へ改められた。

しかし `tasks/` 配下の現役タスクのうち 30 件超が、廃止前に書かれたため
「`packages/cli` の `conformance.test.ts` 生成コードに契約テストを追加する」
「各 sample の `conformance.test.ts` がパスすること」といった手順・テスト要件・完了条件を今も含んでいる。
次にタスクへ着手するセッションが README 方針に反する手順を実行するか、存在しない生成物を探して止まる。

検討詳細は `study-material/done/generated-contract-test-removal-doc-drift.md` を参照。

> 関連（重複しない）: ファイル移動・改名による壊れたパス参照の修復とリンク検査 CI は
> `tasks/p2-doc-path-reference-repair-and-link-check.md` が扱う。
> 本タスクは**方針変更で無効になった契約テスト指示の書き換え**だけを対象とする。
> 両タスクを同時に実施すると、`samples/*/conformance.test.ts` への参照はどちらの観点でも消えるため、
> 同時実施を推奨する。

## 対象ファイル

- `tasks/*.md`（`done/` と `experimental/` を除く現役タスク）のうち `conformance.test.ts` に一致するファイル
  - 一覧は `grep -rln "conformance\.test\.ts" tasks/*.md` で取得する（本タスク作成時点で 30 件超）
- `tasks/op-playground-spec.md`（「`conformance.test.ts` が担保する Basic OP 挙動を基準とする」という基準の置き換え）
- 必要に応じて CLAUDE.md（読み替え規約を残す場合のみ）

`study-material/` 配下の同種の参照は、調査資料という性質上「作成時点の実装の記録」として許容する。
ただし「タスク案」セクションに契約テスト追加を指示している場合だけは、タスク化の際に誤って転記されないよう書き換える。

## 仕様参照

OIDC / OAuth の条文には関わらない。準拠先は本リポジトリの方針である。

- README「テストコードの書き方」：生成コードのテストは書かない。生成 OP の挙動は `tests/e2e` と `tests/conformance` で確認する
- CLAUDE.md「タスクと調査資料」：タスク文書は着手可能な正確さを保つ

## 現状の実装

文書側の典型的な記載は次の三形である。

1. 対象ファイル欄：「`packages/cli` 内の `conformance.test.ts` 生成コード」「`samples/*/conformance.test.ts`（生成元は `packages/cli`）」
2. 修正方針・テスト要件：「契約テスト（`conformance.test.ts` 生成コードに追加）: should ...」
3. 完了条件:「各 sample の `conformance.test.ts` がパスすること」「`pnpm --filter "./samples/*" test` で ... がパスすること」

いずれも参照先の生成コード・生成物が存在しない。

## 修正方針

- [ ] `grep -rln "conformance\.test\.ts" tasks/*.md` で対象を列挙する
- [ ] 対象ファイル欄の参照を削除するか、挙動の固定が必要なタスクでは `tests/e2e/specs/` の該当スペックへ置き換える
- [ ] テスト要件の契約テスト項目を、E2E で固定できるもの（HTTP 応答・画面遷移・Cookie・Discovery 出力など）は Playwright スペックの要件へ翻訳し、関数単体で固定できるものは `packages/core` / `packages/cli` の単体テスト要件へ付け替える
- [ ] 完了条件の「`conformance.test.ts` がパス」を `pnpm test:e2e`（挙動固定を E2E へ移した場合）または既存の単体テストコマンドへ置き換える
- [ ] `tasks/op-playground-spec.md` の挙動基準を「`tests/e2e` と `tests/conformance` が担保する Basic OP 挙動」へ置き換える
- [ ] 書き換え後、`grep -rn "conformance\.test\.ts" tasks/*.md` の残存一致が意図した記録（経緯の説明など）だけであることを確認する

## テスト要件

ドキュメントのみの変更のため、自動テストは追加しない。検証は次の実測で行う。

- [ ] `grep -rln "conformance\.test\.ts" tasks/*.md` の一致が、経緯説明として意図的に残したものだけになること
- [ ] 書き換えたタスクを 2〜3 件無作為に選び、テスト要件・完了条件が現在のリポジトリ構成（`tests/e2e` / `tests/conformance` / 各パッケージの単体テスト）で実行可能であることを机上確認すること

## 完了条件

- 現役タスクのどの「修正方針」「テスト要件」「完了条件」にも、`conformance.test.ts` への追加・更新・パスを要求する記載が残っていない
- 変更は notes リポジトリの `main` へコミットされている（OSS リポジトリに変更を作らない）
