# [P2] CLI 生成コードの型検査・挙動を CI で自動検証する

## ステータス

🟡 Medium / 未着手

## 背景

OIDF Conformance Suite および利用者が実際に動かすのは CLI が生成したプロバイダだが、現状の CLI テストは **「ファイルが生成されること」と「特定の import 文字列が含まれること」しか検証していない**。生成された TypeScript が型検査を通るか・主要エンドポイントが規定どおり応答するかは自動検証されておらず、テンプレート編集や core API シグネチャ変更によるデグレを CI で検知できない。

Fidelity 軸（Conformance 準拠を信頼性のシグナルとして維持する）を生成物レベルで担保するため、CI で常時回せる軽量な自動検証を追加する。

詳細な分析は `study-material/done/cli-generated-output-conformance-ci.md` を参照。動的・手動の Suite 実行（公開 HTTPS 前提、v1.0 条件）は `study-material/basic-op-conformance-verification-plan.md` が扱い、本タスクはその前段の軽量・常時 CI 検証に限定する。

## 対象ファイル

- `packages/cli/src/__tests__/hono-generator.test.ts`（または新規テストファイル）
- `packages/cli/src/generator.ts` / `frameworks/hono/templates.ts`（必要に応じ）
- `packages/sample/src/oidc-provider/`（B 案で挙動テスト対象とする場合）

## 仕様参照

- CLAUDE.md「テストコードで主要ケースを網羅」「Fidelity: Conformance 準拠を信頼性のシグナルとして維持」
- 生成物が満たすべき HTTP レイヤ要件の根拠は既存 study-material（`error-response-cross-endpoint.md` / `userinfo-endpoint-comprehensive.md` / `token-lifetime-security-policy.md`）を参照。

## 現状の実装

- `hono-generator.test.ts` は `files.find(f => f.path === ...)`、`toHaveLength(15)`、`content.toContain('validateAuthorizationRequest')` 等の **文字列存在チェックのみ**。
- 生成コードの型安全性・ビルド可否・挙動（ステータス／ヘッダ／JSON 形）は未検証。

## 修正方針

- [ ]（A 案）`generate()` の出力を一時ディレクトリへ書き出し、`@maronn-openid-connect/core` を解決できる状態で `tsc --noEmit` を実行し、型エラーがあればテスト失敗とする
- [ ]（B 案）`packages/sample/src/oidc-provider/`（生成物の同型ミラー）に対し Hono の `app.fetch(new Request(...))` ベースの最小挙動テストを追加する:
  - Discovery が必須メタデータフィールドを返す
  - Token エンドポイントのエラー応答が `Cache-Control: no-store` と OAuth エラー JSON 形（`error` フィールド）を持つ
  - UserInfo の 401 応答が `WWW-Authenticate` を持つ
- [ ] CI ワークフローに上記テストが含まれることを確認する

## テスト要件

- [ ] 生成出力に意図的な型エラーを混入させると CI（`tsc --noEmit`）が失敗すること（A 案の有効性確認）
- [ ] Discovery レスポンスが `issuer` / `authorization_endpoint` / `token_endpoint` / `jwks_uri` / `response_types_supported` 等を含むこと（B 案）
- [ ] Token エラー応答に `Cache-Control: no-store` が付与され、`error` を含む JSON であること（B 案）
- [ ] UserInfo の無効トークン応答が 401 + `WWW-Authenticate` を返すこと（B 案）

## 完了条件

`pnpm --filter @maronn-openid-connect/cli test`（および B 案を採る場合は対象パッケージの test）がパスし、生成コードの型検査・主要挙動が CI で自動検証されること。
