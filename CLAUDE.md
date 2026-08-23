# 作業規約

OSS 実装リポジトリの `README.md` を先に読み、公開されている開発規約に従ってください。

## タスクと調査資料

タスク文書の実体は、この notes リポジトリの `tasks/` にあります。
調査資料の実体は `study-material/` にあります。
OSS 実装リポジトリでは、`tasks/` と `study-material/` のシンボリックリンクから同じ内容を参照します。
追加、更新、完了済みディレクトリへの移動は、notes リポジトリ側の変更としてコミットします。

## レビュー内容について

Markdown ファイルのレビューコメントは、このリポジトリの `review/` に保存します。
OSS 実装リポジトリでは `.review/` のシンボリックリンクから参照します。
対象ファイルと同じ相対パスを `review/` 配下に再現し、末尾に `.review.json` を付けます。

例：

- 対象ファイル：`tasks/p1-basic-op-authorization-error-page.md`
- レビューコメント：`review/tasks/p1-basic-op-authorization-error-page.md.review.json`

レビュー JSON のトップレベル構造は次のとおりです。

```json
{
  "targetFile": "レビュー対象ファイルのリポジトリ相対パス",
  "updatedAt": "レビューJSONの最終更新日時（ISO 8601）",
  "comments": [
    {
      "id": "コメントID",
      "type": "document | section | paragraph | text-selection",
      "comment": "レビューコメント本文",
      "createdAt": "コメント作成日時（ISO 8601）"
    }
  ]
}
```

各コメントの `type` は、コメントが紐づく粒度を表します。

- `document`：文書全体へのコメント
- `section`：`headingPath` と `heading` で特定する見出し単位のコメント
- `paragraph`：`targetText` または `selectedText` で特定する段落単位のコメント
- `text-selection`：`selectedText`、`contextBefore`、`contextAfter` で特定する選択範囲へのコメント

レビューコメントを反映するときは、次の順序で確認します。

1. `review/**/*.review.json` を読み、`targetFile` ごとに対象原稿を開く
2. `comments` を上から順に確認する
3. `headingPath` がある場合は、対象原稿内の該当見出しへ移動する
4. `text-selection` は `selectedText` だけで置換せず、`contextBefore` と `contextAfter` も見て同じ箇所か確認する
5. `paragraph` は `targetText` または `selectedText` を手がかりにする。CLI 表示由来の補助文言を本文と誤認しない
6. `section` は見出し配下全体への指摘として扱う
7. `document` は文書全体の方針、構成、表現への指摘として扱う
8. コメントの依頼内容をそのまま採用せず、仕様、既存方針、周辺文脈と照合して判断する

対応後は、対応したコメント ID と判断を作業報告に含めます。
未対応のコメントがある場合は理由も記載します。

## 実装解説

experimental 機能の実装解説は `implementation-guides/experimental/` に置き、日本語版と英語版を作成します。
解説には機能の目的とユースケースに加え、`packages/experimental/src/<feature-id>/` の全ファイル、CLI が生成コードへ注入するコード、その機能の E2E スペックを抜粋せず掲載します。
生成コードへの寄与は unified diff のまま貼らず、ファイルごとの節に分け、TypeScript には `typescript` の言語指定を付けます。
`packages/experimental/src` または CLI 統合を変更した場合は、掲載コードと説明も同じ変更内で更新します。
構成は `implementation-guides/experimental/README.md` に従います。

日本語版の作成または改稿では `claude/skills/japanese-tech-writing/SKILL.md` を読み、その規約に従います。
