---
name: tech-research
description: Gemini CLIを使って技術仕様・外部ドキュメントの調査を行うスキル。Claude Codeのコンテキスト節約と、最新ドキュメントへのアクセスが目的。
---

# tech-research — Gemini CLI による技術調査

## 概要

技術仕様・外部ドキュメントの調査をGemini CLIに依頼する。
Claude Codeのコンテキスト節約と、最新ドキュメントへのアクセスが目的。

## どんなときに使うか（例）

- Vikeの挙動・設定オプションが不明なとき
- Cloudflare Workers / D1 の制約・仕様を確認したいとき
- HonoのAPIや型の使い方が不明なとき
- Auth0の設定・SDK仕様を調べたいとき
- npmパッケージの最新バージョン・breaking changesを確認したいとき

## 実行手順

### 1. 調査クエリを作る

調査したい内容を英語で1〜2文にまとめる。具体的なほど精度が上がる。

例:
- `"How to use Cloudflare D1 with Vitest for integration testing without mocks"`
- `"Vike (vite-plugin-ssr) data fetching with +data.ts and TypeScript types"`
- `"Hono v4 zod validator middleware usage and error handling"`

### 2. Geminiに調査を依頼する

```bash
gemini -p  "Research the following and provide a concise summary in Japanese (max 500 words).
Include: key findings, code examples if relevant, and any caveats or limitations.

Topic: {QUERY}
" 2>/dev/null
```

### 3. 結果をメモする

調査結果は `.claude/docs/research/` に保存する:

```bash
# ファイル名は調査トピックを英語スネークケースで
echo "{RESULT}" > .claude/docs/research/{topic_name}.md
```

### 4. 調査結果を設計・実装に反映する

Geminiの回答を参考に設計方針を確定し、②設計フェーズに戻る。
不明点が残る場合は `gemini -p` でフォローアップ質問をする。

### 5. 完了レポートに調査内容を記載する

## 注意事項

- Geminiの回答は参考情報。公式ドキュメントのURLが示された場合は内容を確認する
- Cloudflareのドキュメントは更新が速いため、バージョンに注意する
- 調査結果が実装と矛盾した場合は⑥レポートで報告する