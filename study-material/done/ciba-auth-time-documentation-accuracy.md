# CIBA の auth_time 説明文が実装と食い違う問題（コードは正しく、文書が誤り）

## 1. このトピックで確認したいこと

CIBA 実装の周辺文書が `auth_time` を「承認時刻」と説明しているが、生成コードは OP セッションの認証時刻（ログイン時刻）を渡している。OIDC Core の定義に照らすとコードが正しく、文書側を訂正すべきであることを確認する。

## 2. 関連する仕様・基準

- OIDC Core 1.0 §2: `auth_time` は「End-User 認証が発生した時刻」。承認（consent / approval）の時刻ではない。

## 3. 参照資料

- 生成コード: CIBA 承認ステップは `authTime: session.authTime`（OP セッション確立時刻）を渡す（`packages/cli/src/frameworks/hono/templates.ts` の CIBA verification ルート）
- 誤った記述: `packages/experimental/src/ciba/verification.ts` の JSDoc「承認時刻として ID トークンの auth_time に載る値」、`tasks/experimental/done/ciba/specification.md` の「auth_time は承認時刻」、conformance テスト名 "auth_time recorded at approval"

## 4. 現在の実装確認

SSO 済みセッションから承認した場合、`auth_time` は過去のログイン時刻になる。これは OIDC Core §2 の定義どおりの挙動であり、文書の「承認時刻」という説明だけが実挙動と一致しない。

## 5. 現在の実装との差分

- 🟢 コードの挙動は仕様に合致している。
- 🟠 JSDoc・仕様書・テスト名の 3 箇所が「承認時刻」と誤記しており、読者（と将来の改修者）を誤導する。テスト名を信じて「承認時刻を返すよう修正」されると仕様違反になる。

## 6. 改善・追加を検討する理由

実装解説は掲載コードの全文一致を規約とするため、JSDoc の誤記は解説（ciba.ja.md / ciba.en.md）へもそのまま転載されている。文言修正だけの低コストな変更で、将来の誤修正リスクを消せる。

## 7. 実装方針の候補

- JSDoc・specification.md・conformance テスト名の文言を「セッションの認証時刻（End-User 認証時刻）」へ修正する。コードの挙動変更は不要。
- 実装解説（ja / en）の掲載コードを同じ変更内で同期する。

## 8. タスク案

- [ ] 3 箇所の文言修正と実装解説の同期

→ `tasks/p3-ciba-auth-time-wording-fix.md` としてタスク化済み。
