# [P3] CIBA の auth_time を「承認時刻」と説明する文書を訂正する

## ステータス

🟢 Low / 未着手

## 背景

CIBA の生成コードは `auth_time` に OP セッションの認証時刻（`session.authTime`）を渡しており、OIDC Core 1.0 §2 の定義（End-User 認証が発生した時刻）に合致する。
一方、周辺文書 3 箇所が「承認時刻」と説明しており、SSO 済みセッションから承認したときの実挙動（過去のログイン時刻）と一致しない。
テスト名を信じて「承認時刻を返すよう修正」されると仕様違反になるため、文書側を直す。

詳細は `study-material/done/ciba-auth-time-documentation-accuracy.md` を参照。

## 対象ファイル

- `packages/experimental/src/ciba/verification.ts`（JSDoc「承認時刻として ID トークンの auth_time に載る値」）
- 生成 conformance テストテンプレートのテスト名 "auth_time recorded at approval"（`packages/cli/src/frameworks/hono/templates.ts`）と再生成される sample の conformance.test.ts
- notes リポジトリ `tasks/experimental/done/ciba/specification.md`（「auth_time は承認時刻」）
- 実装解説 `implementation-guides/experimental/ciba.{ja,en}.md`（掲載コードの同期）

## 仕様参照

- OIDC Core 1.0 §2（auth_time の定義）

## 現状の実装

コードの挙動は正しい。文言のみが誤り。

## 修正方針

- [ ] JSDoc を「セッションの認証時刻（End-User 認証時刻）。SSO 済みセッションでは過去のログイン時刻になる」へ修正する
- [ ] conformance テスト名を挙動に合わせて改名する（例: `should set auth_time to the session authentication time`）
- [ ] specification.md の該当行を修正する（notes リポジトリ側のコミット）
- [ ] 実装解説（ja / en）の掲載コードと説明を同期する
- [ ] コードの挙動は変更しない

## テスト要件

- [ ] 改名した conformance テストが引き続き挙動（セッション認証時刻の採用）を固定していること
- [ ] 可能なら SSO 済みセッション経由の承認で auth_time がログイン時刻になるテストを追加する

## 完了条件

```bash
pnpm --filter @maronn-openid-connect/experimental test
pnpm --filter @maronn-openid-connect/cli test
pnpm test:conformance
```

- 「承認時刻」という説明が実装・文書・解説のどこにも残っていない
