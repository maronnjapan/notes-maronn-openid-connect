# Experimental 実装解説 / Experimental Implementation Guides

このディレクトリには、`@maronn-openid-connect/experimental` に実装した機能ごとの実装解説を置く。
それぞれの解説は、機能が何をするものか、どんなユースケースを想定しているか、そして実際に実装したコードの全文を、設計判断の説明とともに収録している。

This directory holds one implementation guide per feature implemented in `@maronn-openid-connect/experimental`.
Each guide explains what the feature does, which use cases it serves, and walks through the complete source code of the implementation together with the design decisions behind it.

## 文書一覧 / Documents

| 機能 / Feature | 準拠仕様 / Spec | 日本語版 | English |
|---|---|---|---|
| パッケージ全体像 / Package overview | – | [package-overview.ja.md](./package-overview.ja.md) | [package-overview.en.md](./package-overview.en.md) |
| Pushed Authorization Requests | RFC 9126 | [par.ja.md](./par.ja.md) | [par.en.md](./par.en.md) |
| Token Exchange | RFC 8693 | [token-exchange.ja.md](./token-exchange.ja.md) | [token-exchange.en.md](./token-exchange.en.md) |
| JARM | JARM (OpenID Foundation Final, 2022-11-09) | [jarm.ja.md](./jarm.ja.md) | [jarm.en.md](./jarm.en.md) |
| Device Authorization Grant | RFC 8628 | [device-authorization-grant.ja.md](./device-authorization-grant.ja.md) | [device-authorization-grant.en.md](./device-authorization-grant.en.md) |
| Cross-App Access / ID-JAG | draft-ietf-oauth-identity-assertion-authz-grant-04 | [id-jag.ja.md](./id-jag.ja.md) | [id-jag.en.md](./id-jag.en.md) |

## 各解説が全文を載せる範囲 / What each guide embeds in full

各機能の解説は、次のコードをすべて全文で載せる。

- `packages/experimental/src/<feature-id>/` の実装ファイルとテストファイルのすべて
- CLI の `--enable <feature-id>` が生成コードへ注入するコードの全文（hono。他フレームワークの差分は同等の内容なのでリンクで示す）
- その機能の E2E テストスペックの全文

全機能で共有される基盤（core 本体、E2E ハーネス、CLI テンプレート全体）は個別機能のコードではないため、リンクで参照する。

生成コードへの寄与は、unified diff をそのまま貼らず、ファイルごとの節に分けて、追加・変更されるコードを言語指定つきのコードブロック（TypeScript なら ```typescript）で示す。
diff 形式はシンタックスハイライトが効かず読みにくいためで、どこに入るコードかは前後の文で述べる。
CLI 統合を変更した場合は、生成結果と解説に掲載したコードを同じ変更内で照合する。

Each feature guide embeds, verbatim and in full:

- every implementation and test file under `packages/experimental/src/<feature-id>/`
- the complete code that `--enable <feature-id>` adds to the CLI-generated output (hono; the other frameworks' diffs are equivalent and are linked)
- the complete E2E test spec for the feature

Infrastructure shared by all features (the core package itself, the E2E harness, the CLI template files as a whole) is not code of any single feature, so the guides link to it instead of embedding it.

The generated-code contribution is presented file by file, as syntax-highlighted code blocks (```typescript) of the added or changed code, with the surrounding prose stating where each block lands.
Raw unified diffs are not embedded in the guides: they render without syntax highlighting and are hard to read.
When the CLI integration changes, verify the generated result against the code embedded in the guide within the same change.

## 更新の規約 / Maintenance rules

これらの文書は OSS 実装リポジトリの `README.md` と notes リポジトリの `CLAUDE.md` にある規約で管理されている。

- experimental の機能を実装しきったら、その機能の実装解説（日本語版と英語版）をこのディレクトリに追加する。
- `packages/experimental/src` や CLI 統合を変更したら、該当機能の解説に載せているコード全文と説明を同じ変更で更新する。
- 文書の執筆や改稿では `japanese-tech-writing` をはじめとした文章生成系スキルを使う。

These documents are governed by the conventions in the OSS repository's `README.md` and this notes repository's `CLAUDE.md`:

- when an experimental feature is fully implemented, add its implementation guide (Japanese and English) to this directory;
- when `packages/experimental/src` or the CLI integration changes, update the embedded code and the explanations of the affected guide in the same change;
- writing and revising these documents must use the writing skills (starting with `japanese-tech-writing`).
