# 期限切れ `id_token_hint` の受け入れ方針（認可エンドポイント）

## ステータス

🟡 Medium / 検討中（方針未確定のためタスク化しない）

## 1. このトピックで確認したいこと

認可エンドポイントに提示された `id_token_hint` の `exp` が過ぎているとき、検証失敗（`login_required`）として扱ってよいかを確認する。
あわせて、prompt の値によって失敗時の挙動を変えるべきかを検討する。

## 2. 関連する仕様・基準

- OIDC Core 1.0 §3.1.2.1（`id_token_hint` の定義）
  - hint は「the End-User's current **or past** authenticated session」についてのヒントと定義されている。
  - 「If the End-User identified by the ID Token is logged in or **is logged in by the request**, then the Authorization Server returns a positive response; otherwise, it SHOULD return an error, such as login_required.」
  - エラーにすべき条件は「hint が指す End-User がログインしておらず、この要求でもログインしない」ことであり、hint 自体の `exp` 切れはその条件に含まれていない。
- OIDC Core 1.0 §3.1.2.6
  - `login_required` は「End-User の認証が必要だが、表示できない（典型は prompt=none）」場合のエラーとして定義されている。
- 参考：OIDC RP-Initiated Logout 1.0 §2 は、logout 用の `id_token_hint` について「期限切れでも受け入れてよい（SHOULD 相当の緩和）」を明示している。
  認可エンドポイント側の Core にはこの明文がないため、扱いは OP の設計判断になる。

## 3. 参照資料

- OpenID Connect Core 1.0 §3.1.2.1 / §3.1.2.6
- OpenID Connect RP-Initiated Logout 1.0 §2（期限切れ hint の扱いの対比として）
- `tasks/done/p0-id-token-hint-prompt-none.md`（「期限切れ hint の許容は別途議論」と TODO 記載あり）
- `tasks/done/p1-id-token-hint-verification-all-prompt-paths.md`（現在の「exp 切れ → login_required」を期待値として固定した経緯）

## 4. 現在の実装確認

- `packages/core/src/id-token.ts` の `validateIdTokenHint`
  - `exp + leeway < now` で一律に `IdTokenHintError('id_token_hint has expired')` を投げる。
  - 猶予は `clockSkewToleranceSec`（既定 60 秒）だけで、`exp` 検査自体を外す注入点はない。
  - `IdTokenHintError.error` は常に `'login_required'` である。
- `packages/cli/src/frameworks/hono/templates.ts` の authorize ルート
  - hint の検証は prompt の値に関係なく実行される。
  - 検証に失敗すると、認証トランザクションを削除してから `login_required` をエラーリダイレクトする。
  - 生成 OP の ID Token 有効期間は既定 3600 秒である。

## 5. 現在の実装との差分

- 満たしていること
  - 署名、`iss`、`aud`、`sub` の検証はどの prompt 経路でも行われる。
  - 取得直後の ID Token を使う限り、`prompt=none` のサイレント認証は成立する。
- 相互運用性の観点で確認が必要なこと
  - 一般的な RP ライブラリのサイレント更新は「前回受け取った ID Token」を `id_token_hint` に入れて `prompt=none` を送る。
    ID Token の発行から有効期間（既定 1 時間）を過ぎると、OP セッションが有効で `sub` も一致しているのに `login_required` になり、サイレント更新がその時点から常に失敗する。
  - prompt 指定なしや `prompt=login` の対話フローでも、期限切れ hint が付いているだけでログイン画面を出さずにエラーリダイレクトする。
    §3.1.2.1 の「is logged in by the request」（この要求の中でログインさせて肯定応答を返す）経路を自ら閉じている。
- 判断の記録の観点
  - RP-Initiated Logout 側は「期限切れ hint を受け入れない」判断を仕様書に明記済みである。
    認可エンドポイント側には、それに当たる判断の記録がない。

## 6. 改善・追加を検討する理由

hint の `exp` は「その ID Token を RP が受け入れてよい期限」であり、「OP がセッション照合の材料に使ってよい期限」ではない。
セッションの生死は OP 自身のセッションストアが判定するため、hint の鮮度検査を緩めても、なりすましの材料になるのは署名検証を通った自発行トークンだけである。
一方で、期限切れ hint の無期限受け入れは、漏洩した古い ID Token から `sub` を特定したサイレントプローブを許す面もある。
受け入れ期間の上限（たとえば「exp から N 日」）を設けるか、無条件に受け入れるかは設計判断であり、ここで確定しない。

## 7. 実装方針の候補

1. **prompt≠none の経路では、hint 検証失敗をエラーにせずログイン画面へ進める**
   §3.1.2.1 の「is logged in by the request」に沿う。
   `login_required` の定義（§3.1.2.6）とも整合する。
2. **`validateIdTokenHint` に `exp` の扱いを注入できるオプションを足す**
   既定は現状維持（厳格）とし、OP が「期限切れを許容する」「許容期間に上限を設ける」を選べるようにする。
   RP-Initiated Logout 側の実装と対称になる。
3. **現状維持を判断として明文化する**
   「サイレント更新には有効期間内の ID Token が必要」という制約を README か生成コードのコメントに書き、判断の記録を残す。

## 8. タスク案

- 方針 1〜3 のどれを採るか（組み合わせるか）は人間の判断を待つ。
  方針 1 は既存タスク `tasks/done/p1-id-token-hint-verification-all-prompt-paths.md` が固定した期待値の変更にあたるため、タスク化は判断確定後に行う。
