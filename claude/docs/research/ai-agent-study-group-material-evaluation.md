# AIエージェント勉強会教材としての本リポジトリ評価（2026-05-16）

## 調査方法
- tech-research スキル経由で Gemini CLI 調査（※play.googleapis.com がサンドボックスでブロック→sandbox解除で実行）
- WebSearch で Anthropic 公式 / 2026ワークショップ動向を補強

## 結論
- ケーススタディ教材としては優秀。ハンズオン演習の土台としては不向き（OIDC/OAuthのドメイン依存が強すぎる）。
- マルチツール分業の考え方は現代的だが、外部CLI(Codex/Gemini)依存はやや旧式。2026ネイティブは Subagents + Agent Teams + Plan Mode + Plugins。
- 再現性が低い（Codex/Gemini/Serena/Windowsフック前提）。本調査中も Gemini CLI が認証/ネットワークで一度失敗。

## 推奨
- A: 本リポジトリは「実例ショーケース」(20-30分)に限定
- B: ハンズオンは小さな低ドメインrepo（pnpm install && pnpm test で回る）で実施
- C: 概念パートは Anthropic公式（Building effective agents / Claude Code best practices / Skills・Subagents・Hooks docs）で固定
- 必須トーク: 外部CLI方式 vs 2026ネイティブ(Subagents/Agent Teams/Plan Mode) のトレードオフ対比

## 主な参照
- https://www.anthropic.com/research/building-effective-agents
- https://www.anthropic.com/engineering/claude-code-best-practices
- https://code.claude.com/docs/en/hooks
- https://alexop.dev/posts/understanding-claude-code-full-stack/
