---
feature: par
decision: pending
decided_at: null
decided_by: null
reviewed_commit: null
---

# 昇格判断: par

このファイルは **人間のレビュアーが記入する** 判断記録です。ツールは上書きしません。

- `decision`: `pending`（未判断） / `go`（昇格してよい） / `no-go`（昇格しない） / `hold`（保留）
- Go サインを出すときは `decision: go` に書き換え、`decided_at`（YYYY-MM-DD）・
  `decided_by`・`reviewed_commit`（`--check` が通った時点のコミット SHA）を記入する
- 判断の根拠・条件・残課題は「判断メモ」に残す

## 昇格条件チェックリスト

packages/experimental/README.md の「昇格条件」に対応する。

- [ ] 生成 OP の conformance テストが 2 サイクル以上安定している
- [ ] resolver / store 契約への変更要望が収束している
- [ ] この仕様がリポジトリのロードマップ上で必須になっている

## レビュー完了チェックリスト

- [ ] specification.md の期待挙動と実装が一致していることを確認した
- [ ] packages/experimental/src/par を単体テスト含めて読了した
- [ ] 生成コード差分（全フレームワーク）を読了した
- [ ] conformance.test.ts への寄与（この機能の契約テスト）を確認した
- [ ] E2E テストを確認した
- [ ] 利用者向けドキュメントを確認した

## 判断メモ

（理由・条件・残課題をここに書く）
