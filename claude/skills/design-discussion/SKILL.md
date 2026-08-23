---
name: design-discussion
description: 設計フェーズと実装後レビューの両方で使う汎用スキル。CodexをセカンドオピニオンとしてClaudeが最終判断を下す。
---

# design-discussion — Claude × Codex 協議スキル

## 概要

設計フェーズと実装後レビューの両方で使う汎用スキル。
CodexをセカンドオピニオンとしてClaudeが最終判断を下す。

---

## 使い方A: 設計協議（実装前）

### 1. Claudeが設計ドラフトを準備する

以下の形式でドラフトを整理しておく:

```
- 目的: （何を実現するか）
- ファイル構成: （新規・変更するファイル一覧）
- データの流れ: （入力→処理→出力）
- 懸念点: （迷っている箇所、トレードオフ）
```

### 2. Codexに設計レビューを依頼する

```bash
codex exec `--sandbox workspace-write \
  "Review the following design draft and provide feedback in Japanese.

Labels to use:
- [AGREE] good design decision
- [CONCERN] potential problem or risk
- [ALTERNATIVE] suggest a different approach

Focus on:
1. Is the design appropriate for the stated goal?
2. Are there hidden risks or edge cases?
3. Is there a simpler or better approach?

Design draft:
{DRAFT}
"
```

### 3. Claudeが設計を確定する

Codexの意見を踏まえて以下を判断する:

- `[CONCERN]` は設計を見直すか、リスクを許容する理由を明確にする
- `[ALTERNATIVE]` はこのプロジェクトの方針と照らして採否を決める
- 判断した内容を「確定設計」としてメモしてから実装に進む

---

### 4. 完了レポートに協議結果を記載する

```
## 設計協議の結果
- Codexの主な意見: （要約）
- 採用した意見: （内容）
- 採用しなかった意見: （内容と理由）
```

## 使い方B: コードレビュー（実装後）

### 1. 差分を取得する

```bash
git diff HEAD~1 --unified=5
```

### 2. Codexにコードレビューを依頼する

```bash
codex exec --sandbox workspace-write \
  "Review the following code changes and provide feedback in Japanese.

Labels to use:
- [ISSUE] should be fixed
- [SUGGESTION] optional improvement
- [OK] no problems

Focus on:
1. Does the implementation match the design intent?
2. Code readability — names, comments, structure
3. Error handling and edge cases
4. Test quality — meaningful, close to real behavior
5. TypeScript correctness

Code changes:
{DIFF}
"
```

### 3. Claudeが最終判断を下す

- `[ISSUE]` は修正してテストを再実行する
- `[SUGGESTION]` はプロジェクト方針と照らして採否を決める
- 修正しない場合は理由を記録する

### 4. 完了レポートに協議結果を記載する

```
## 設計協議の結果
- Codexの主な意見: （要約）
- 採用した意見: （内容）
- 採用しなかった意見: （内容と理由）
```