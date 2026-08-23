# CLI 生成プロバイダのブラウザセッション確立と SSO（`prompt=none` / `max_age` が実機能しない問題）

## 1. このトピックで確認したいこと

このリポジトリの差別化軸の一つは「CLI でフロー実装コードを生成し、利用者はそのコードを改造しながら仕様を検証する」ことであり、**OIDF Conformance Suite が実際に叩くのは core ライブラリではなく CLI が生成したプロバイダ（= `packages/sample/src/oidc-provider` 相当）** である。

ところが、CLI が生成する認証フローには **「ブラウザに紐づく永続的な認証セッション（OP セッション）」が存在しない**。生成コードの「セッション」は 1 回の認可トランザクション（`transaction_id`）にスコープされ、同意完了直後に削除される。

このトピックでは、その結果として **Basic OP 認定で検証される `prompt=none` / `max_age` / SSO（Single Sign-On）が、生成コードでは実機能していない**ことを確認し、CLI テンプレートにブラウザセッション確立（セッション Cookie + Cookie をキーにした `SessionResolver`）を導入すべきかを検討する。

> 補足: core ライブラリ単体（`checkPromptNone` / `requiresReauthentication` / `SessionResolver` インターフェース）は正しく実装されている。問題は **生成コード側がそれらを「実際のブラウザセッション」に接続していない**点にある。

## 2. 関連する仕様・基準

- **OpenID Connect Core 1.0 §3.1.2.1（Authorization Request）**
  - `prompt=none`: OP は **いかなる認証・同意 UI も表示してはならない**。End-User が未認証なら `login_required`、同意が未取得なら `consent_required` を返す。これは「OP が End-User の既存セッションを参照できる」ことを前提にした分岐である。
  - `max_age`: 指定秒数を超えて経過した認証は再認証を要求する。判定には **過去の認証時刻（`auth_time`）を保持する OP セッション**が必要。
- **OpenID Connect Core 1.0 §3.1.2.3（Authorization Server Authenticates End-User）**
  - 「If the End-User is authenticated ... by means of a **session cookie or other mechanism**」と明記され、SSO は OP が End-User セッションを跨いで維持することで成立する（spec はセッション実装を Cookie に限定しないが、ブラウザ越しの SSO には何らかのセッション識別子の永続化が必要）。
- **OpenID Connect Core 1.0 §3.1.2.6（Authentication Error Response）**
  - `login_required` / `consent_required` / `interaction_required` / `account_selection_required` の定義。`prompt=none` が機能するには既存セッションの有無で正しく出し分ける必要がある。
- **OIDF Basic OP Certification Profile**（OpenID Connect Conformance Profiles v3.0, Basic OP）
  - `prompt` パラメータ対応（none / login / consent / select_account）は Basic OP の必須機能（CLAUDE.md「Basic OP の必須機能」参照）。Conformance Suite は実際に 2 回連続でリクエストを送り、2 回目の `prompt=none` がエラーにならず（= 既存セッションで silent に通る）ことや、`max_age` 経過時に再認証されることを検証するテストを含む。

> 共通仕様の机上対応は `study-material/basic-op-requirements-baseline.md` と `study-material/basic-op-requirement-traceability.md` を参照（重複記載回避）。`SessionResolver` の契約は `study-material/resolver-and-store-contract.md` を参照。Cookie 属性そのものの指針は `study-material/http-security-headers-and-tls.md` を参照。本ファイルはそれらが前提とする「ブラウザセッションが実在すること」自体が生成コードに欠けている、という**差分**に絞る。

## 3. 参照資料

- OpenID Connect Core 1.0 §3.1.2.1 / §3.1.2.3 / §3.1.2.6 — https://openid.net/specs/openid-connect-core-1_0.html#AuthRequest （`prompt` / `max_age` / `auth_time` とセッション認証の規定）
- OpenID Connect Conformance Profiles v3.0（Basic OP）— https://openid.net/certification/profile_op_testing/ および https://openid.net/specs/openid-connect-conformance-profiles-1_0.html （`prompt`/`max_age` 系テストの存在根拠）
- 本リポジトリ `study-material/basic-op-conformance-verification-plan.md`（Suite 実行段取り。本ファイルはその「検証が通るための前提実装」を補完）

## 4. （上に統合）

## 5. 現在の実装確認

CLI が生成するコード（および同一構造の生成済みサンプル）でのセッションの扱い:

- **セッションストアは `transaction_id` をキーにする**
  - `packages/cli/src/frameworks/hono/templates.ts` の `AuthSessionStore`（`sessions = new Map<transactionId, AuthSessionInfo>()`、`set/get/delete(transactionId)`）
  - 生成済みミラー: `packages/sample/src/oidc-provider/store.ts:157`（`AuthSessionStore`、`authSessionStore` インスタンス）
- **ログイン成功時、`transaction_id` をキーにセッションを保存**
  - `templates.ts` の login route（POST）: `authSessionStore.set(transactionId, { subject, authTime })` の直後に `/consent?transaction_id=...` へリダイレクト
  - 生成済みミラー: `packages/sample/src/oidc-provider/routes/login.ts`
- **同意完了時にそのセッションを削除**
  - `templates.ts` の consent route（POST）: 認可コード発行後に `authSessionStore.delete(transactionId)`。つまりセッションはトランザクション 1 回限りで破棄される。
- **`prompt=none` 経路は `sessionResolver` を `c.get('sessionResolver')` から取得するが、デフォルトでは未設定**
  - `templates.ts` authorize route: `if (!sessionResolver) { ... return ...buildErrorRedirect(... 'login_required' ...) }`
  - 生成済みミラーの `packages/sample/src/oidc-provider/resolvers.ts` には `sessionResolver` の既定実装が存在しない（grep で未定義）。
- **ブラウザに対するセッション Cookie の発行が一切ない**
  - `templates.ts` / `packages/sample/src/oidc-provider/` 全体で `setCookie` / `Set-Cookie` / `HttpOnly` / `SameSite` の使用なし（grep で 0 件）。

## 6. 現在の実装との差分

満たしていること:
- core の `checkPromptNone` / `requiresReauthentication` / `SessionResolver` 契約は実装済みで、適切な `SessionResolver` を渡せば仕様通り動作する設計になっている。
- 単一トランザクション内（login → consent → code 発行）は正しく完結する。

不足している可能性があること（生成コード側）:
- 🔴 **永続的なブラウザ OP セッションが存在しない**。`authSessionStore` が `transaction_id` キーかつ同意後に削除されるため、認可フロー完了後にユーザーの「ログイン済み状態」がどこにも残らない。
- 🔴 **SSO が成立しない**。別クライアント（または同一クライアントの 2 回目）の認可リクエストが来ても、参照すべき OP セッションがないため毎回ログイン画面に誘導される。
- 🔴 **`prompt=none` が実質常に `login_required`**。デフォルトで `sessionResolver` が未設定であり、仮に設定しても **Cookie 等のブラウザ識別子がないため「誰のセッションか」を解決できない**（`transaction_id` は毎回新規発行され、過去セッションと紐づかない）。
- 🟠 **`max_age` の silent 再認証が機能しない**。再認証要否は「既存セッションの `auth_time`」と比較して初めて意味を持つが、既存セッションが残らないため常に新規ログインになる（=「期限切れだから再認証」ではなく「そもそもセッションがない」状態）。

セキュリティ上、確認した方がよいこと:
- 🟠 **`transaction_id` が事実上のベアラ能力**になっている。login → consent 間の状態接続が URL クエリの `transaction_id` のみに依存し、ブラウザ束縛（Cookie 等）がない。`transaction_id` が Referer / ブラウザ履歴 / ログ経由で漏れると、別ブラウザから同意ステップを継続できる余地がある（CSRF トークンはフォーム同期トークンとして機能するが、セッション束縛は別問題）。セッション Cookie 導入はこの束縛も改善する。

Basic OP として提供する上で確認すべきこと:
- Conformance Suite の `prompt=none` / `max_age` / SSO 系テストは、生成プロバイダをそのまま使うと **意図せず Fail もしくは「常に login_required」で進行不能**になる可能性が高い。`study-material/basic-op-conformance-verification-plan.md` の「検証が通る前提」を満たすには、生成コード側のセッション確立が必要。

## 7. 改善・追加を検討する理由

- **Basic OP の必須機能（`prompt`/`max_age`）の実機能化**: 仕様分岐ロジック（core）が正しくても、生成プロバイダがブラウザセッションを持たないと「動く Basic OP」として提示できない。Fidelity 軸（Conformance 準拠のシグナル）を生成コードレベルで担保するために必要。
- **OSS 利用者の体験**: 利用者は CLI 生成コードを起点に SSO や `prompt=none` を検証したいはずだが、現状はそれが土台から動かない。最小でも「Cookie ベースのセッション + 既定 `SessionResolver`」がテンプレートに含まれていれば、改造の出発点として大幅に使いやすくなる。
- **導入しやすさ**: core 側は `SessionResolver` 注入点を既に持つため、変更は **CLI テンプレート（`templates.ts`）と生成済みサンプルの配線のみ**で完結し、core の公開 API 変更は不要。`AuthSessionStore` を「`session_id`（Cookie 値）キー」に置き換え、login で `Set-Cookie`、authorize で Cookie から既定 `SessionResolver` を構築する形に寄せられる。
- **実装しない場合のリスク**: `prompt=none`/`max_age`/SSO を「実装済み」と主張しても生成コードで再現できず、Conformance 検証時に手戻り。利用者にも「core は対応だが生成コードでは動かない」という説明コストが残り続ける。

## 8. 実装方針の候補

最終判断は人間が行う前提で、判断材料を整理する。

- **A 案（推奨度: 判断材料／最小実装）**: 生成テンプレートに **セッション Cookie ベースの OP セッション**を導入。
  - login 成功時に `session_id`（CSPRNG）を発行し、`Set-Cookie: session_id=...; HttpOnly; Secure; SameSite=Lax; Path=/` を返す（属性指針は `http-security-headers-and-tls.md` を参照）。
  - セッションストアを `transaction_id` キーから `session_id` キーへ変更し、同意後に削除しない（ログアウト or 期限で破棄）。
  - authorize ルートで Cookie から `session_id` を読み、`session_id → { subject, authTime }` を返す既定 `SessionResolver` を提供。これにより `prompt=none` / `max_age` / SSO が既定で機能する。
  - `SameSite=Lax` を選ぶ理由（`Strict` だとクロスサイトからの認可リダイレクト復帰時に Cookie が送られずフローが破綻する点）は `http-security-headers-and-tls.md` を参照。
- **B 案（最小ドキュメント対応）**: 実装は変えず、生成コードの README/コメントに「このテンプレートはトランザクション単位の擬似セッションであり、SSO/`prompt=none` を検証するには Cookie ベースの `SessionResolver` を自前で配線する必要がある」旨を明記し、配線例を docs に置く。
- **C 案（折衷）**: A 案を「オプトイン」（CLI フラグ or 生成後コメント）として提供し、既定はトランザクション単位のまま。利用者が必要時に切り替える。

検討ポイント（人間判断）:
- 既定をどこまで「SSO 込み」にするか（PoC として最小で出す方針との兼ね合い）。
- セッションストアの永続化先（in-memory / KV）。生成サンプルは in-memory 前提で問題ないか。
- `ext-oidc-session-management-1_0.md`（`session_state` / `check_session_iframe`）や RP-Initiated Logout との接続をどこまで見据えるか（本トピックは「ログインセッションの実在」までを範囲とし、Session Management 拡張は別ファイルに委譲）。

## 9. タスク案

- [ ] CLI Hono テンプレート（`packages/cli/src/frameworks/hono/templates.ts`）の `AuthSessionStore` を `session_id` キーへ変更し、login 成功時にセッション Cookie（`HttpOnly` / `Secure` / `SameSite=Lax`）を発行する
- [ ] 同意完了時にセッションを削除しない運用へ変更（トランザクションのみ削除、セッションは存続）
- [ ] Cookie の `session_id` を参照する既定 `SessionResolver` をテンプレートに追加し、authorize ルートへ配線する
- [ ] 生成済みミラー（`packages/sample/src/oidc-provider/`）を同等に更新（CLAUDE.md: 生成物の修正は CLI 経由で行う）
- [ ] `prompt=none` 2 回目リクエストが既存セッションで silent 成功すること、`max_age` 経過時に再認証されること、別クライアントで SSO が効くことの統合テストを追加
- [ ] `study-material/basic-op-conformance-verification-plan.md` の前提条件に「生成プロバイダのセッション確立」を依存関係として追記する
