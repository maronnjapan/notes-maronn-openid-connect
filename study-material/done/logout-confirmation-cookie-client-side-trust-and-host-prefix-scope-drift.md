# ログアウト確認 Cookie がリダイレクト先まで含めてクライアント側だけを信頼している

## ステータス

🟡 タスク化済み（`tasks/p3-logout-confirmation-server-side-anchor.md`、および `tasks/p2-op-cookie-host-prefix.md` のスコープ拡張）

## 1. このトピックで確認したいこと

生成 OP がブラウザへ発行する Cookie は、RP-Initiated Logout と Device Authorization Grant の追加により 4 系統に増えた。

- OP セッション Cookie：`session_id`
- トランザクション束縛 Cookie：`oidc_txn_<transactionId>`
- デバイス検証束縛 Cookie：`oidc_device_<user_code>`
- ログアウト確認 Cookie：`oidc_logout_confirm`

このうちログアウト確認 Cookie だけが、検証の照合先をサーバー側に持たない。
束縛系の 2 つ（トランザクション、デバイス検証）は秘密の SHA-256 ハッシュをサーバー側レコードに保存し、Cookie の値をそのハッシュと突き合わせる。
ログアウト確認 Cookie は CSRF シークレットとリダイレクト先の両方を Cookie の値に載せ、承認 POST では「Cookie 内のシークレット」と「フォームの hidden `csrf_token`」を比較するだけで、サーバー側には何も残さない。

この設計は「攻撃者は被害者のブラウザに Cookie を書き込めない」という前提の上に立つ。
その前提を成立させる手段（`__Host-` プレフィックス）は `tasks/p2-op-cookie-host-prefix.md` が扱うが、同タスクは作成時点の 2 系統（セッション、トランザクション束縛）しか対象に挙げていない。
確認したいのは次の 2 点である。

1. Cookie 書き込みを許す環境（RFC 6265 §8.6 の兄弟ホスト問題）で、ログアウト確認 Cookie の注入が何を可能にするか
2. `__Host-` タスクのスコープを 4 系統へ広げるだけで足りるか、ログアウト確認の状態をサーバー側へ移す多層防御まで行うか

## 2. 関連する仕様・基準

Cookie の弱い完全性（兄弟ホストからの書き込み）と `__Host-` プレフィックスの働きは `study-material/done/op-cookie-host-prefix-and-domain-isolation.md` と `tasks/p2-op-cookie-host-prefix.md` の §仕様参照が説明しており、繰り返さない。
本トピック固有の根拠は次の 3 点である。

- **OpenID Connect RP-Initiated Logout 1.0 §3**：`post_logout_redirect_uri` は、クライアントに事前登録された値のいずれかと一致しない限り使用してはならない（MUST NOT）。Cookie 注入でリダイレクト先を差し込めると、この登録チェックを通らない URL への 302 を OP のオリジンから返すことになる
- **OpenID Connect RP-Initiated Logout 1.0 §7**：有効な `id_token_hint` のないログアウト要求はセッション終了の DoS 手段になり得るため、確認画面を要求する。注入した Cookie で承認 POST を偽造できると、確認画面そのものを迂回して強制ログアウトが成立する
- **RFC 6749 §10.15（オープンリダイレクタ）**：認可サーバーのオリジンから攻撃者の URL へ 302 を返す経路は、フィッシングの着地点として使われる

## 3. 参照資料

- OpenID Connect RP-Initiated Logout 1.0 §3, §7 — https://openid.net/specs/openid-connect-rpinitiated-1_0.html
- RFC 6265 §8.6 Weak Integrity — https://www.rfc-editor.org/rfc/rfc6265#section-8.6
- RFC 6749 §10.15 Open Redirectors — https://www.rfc-editor.org/rfc/rfc6749#section-10.15
- draft-ietf-httpbis-rfc6265bis §4.1.3 Cookie Name Prefixes — https://datatracker.ietf.org/doc/html/draft-ietf-httpbis-rfc6265bis
- 本リポジトリ内：`study-material/done/op-cookie-host-prefix-and-domain-isolation.md`（兄弟ホスト問題の全体像）、`tasks/p2-op-cookie-host-prefix.md`（プレフィックス導入タスク）

## 4. 現在の実装確認

生成物（確認用。修正は `packages/cli` のテンプレート側で行う）：

- `samples/hono-cloudflare/src/oidc-provider/store.ts:378-460`
  - `LOGOUT_CONFIRMATION_COOKIE = 'oidc_logout_confirm'`
  - `buildLogoutConfirmationCookie`：値は `<csrfSecret>.<base64url(redirectTo)>`。属性は `HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=600`
  - `parseLogoutConfirmation`：値を分解して `{ csrfSecret, redirectTo }` を返す。不正な形は null（fail-closed）
- `samples/hono-cloudflare/src/oidc-provider/routes/logout.ts`
  - 確認画面の描画時に `csrfSecret` を発行し、OP が計算したリダイレクト先とともに Cookie に載せる。サーバー側ストアには何も保存しない
  - `POST /logout/approve` は「Cookie の `csrfSecret`」と「フォームの `csrf_token`」の一致だけを確認し、一致すればセッションを削除して `redirectTo` へ 302 する
- 対比：`samples/hono-cloudflare/src/oidc-provider/store.ts:1061-1135`（`oidc_device_`）は `bindingSecret` の SHA-256 ハッシュをサーバー側レコードに保存し、Cookie の生値をハッシュ化して突き合わせる。トランザクション束縛も同じ形

テンプレート側の実体：`packages/cli/src/frameworks/hono/templates.ts:1483-1540`（ログアウト確認 Cookie）、同 `:1074-1120`（デバイス検証束縛 Cookie）、`endSessionRouteTemplate`（同 `:4414` 以降）。

## 5. 現在の実装との差分

満たしていること：

- 承認 POST は Double Submit Cookie（HttpOnly Cookie とフォームの hidden 値の一致）で保護されており、Cookie を書き込めない攻撃者にはクロスサイトの偽造 POST が成立しない
- リダイレクト先は OP が §3 の登録簿と完全一致で解決した結果だけを Cookie に載せ、`id_token_hint` やリクエストパラメータを HTML 経由で往復させない
- `parseLogoutConfirmation` は形式不正を null に落とし、承認 POST は 400 で何も削除しない

不足している可能性があること：

- 🟡 **Cookie 注入で確認フローの信頼全体が崩れる**。同じ登録可能ドメインの兄弟ホストを握った攻撃者は、シークレット S とリダイレクト先を自分で選んで `oidc_logout_confirm=S.<base64url(攻撃者URL)>` を被害者のブラウザに書き込める。攻撃者のページから `csrf_token=S` を載せたフォームを `POST /logout/approve` へ自動送信すると（兄弟ホストからの POST は same-site なので SameSite=Lax も妨げない）、比較は成立し、被害者の OP セッションが確認画面なしで削除され、応答は OP のオリジンから攻撃者 URL への 302 になる
- 🟡 帰結は 2 つで、性質が異なる。強制ログアウトは §7 が確認画面で防ごうとした DoS の成立であり、302 は §3 の登録チェックを通らないオープンリダイレクト（RFC 6749 §10.15）である
- 🟡 セッション Cookie の注入（セッション固定）とトランザクション束縛は `tasks/p2-op-cookie-host-prefix.md` が扱うが、同タスクの対象列挙は「2 種類の Cookie」のままで、後から追加されたデバイス検証束縛とログアウト確認の 2 系統が漏れている（スコープドリフト）

推測と事実の区別：

- 兄弟ホストからの書き込みという前提条件は、OP をサブドメインで運用する構成でのみ現実になる。単独ドメイン運用ではこの経路は存在しない
- 束縛系 2 つは注入されてもサーバー側ハッシュと一致しないため、成立するのはフローの妨害までで、承認の偽造には至らない（実装確認に基づく事実）

## 6. 改善・追加を検討する理由

`__Host-` プレフィックスの導入タスクは、対象 Cookie を実装時点で列挙し直さない限り、後から増えた Cookie を守らない。
スコープの拡張はタスク文書の更新だけで済み、実装コストを増やさない。

ログアウト確認 Cookie に固有の論点は、プレフィックスが「書き込みを防ぐ」防御である一方、このリポジトリ自身がデバイス検証束縛で「書き込まれても照合で落とす」防御（サーバー側ハッシュ）を選んでいることにある。
同じ生成 OP の中で、攻撃者が識別子を知っている前提のデバイスフローはサーバー側照合を持ち、セッション削除とリダイレクトという強い作用を持つログアウト承認はクライアント側比較だけという非対称は、設計判断として説明がつかない。
デバイス検証束縛と同じ形（サーバー側にハッシュとリダイレクト先を保存し、Cookie には秘密だけを載せる）へ揃えれば、Cookie 注入が成立する環境でも承認の偽造とリダイレクト先の差し込みが照合で落ちる。

実装しない場合のリスクは、`__Host-` 未対応の経路（プレフィックス導入前の期間、および何らかの理由で http 運用となりプレフィックスを外した構成）で上記の注入経路が残ることに限られる。

## 7. 実装方針の候補

最終判断は人間が行う。

- **方針 A（タスク文書の更新。実施済み）**：`tasks/p2-op-cookie-host-prefix.md` の対象 Cookie を 4 系統に拡張し、テスト要件にデバイス検証束縛とログアウト確認の期待値を加える
- **方針 B（多層防御。推奨）**：ログアウト確認の状態をサーバー側ストアへ移す。確認画面の描画時に `csrfSecret` の SHA-256 ハッシュと `redirectTo` をストアに保存（TTL 600 秒）し、Cookie には `csrfSecret` だけを載せる。承認 POST はフォーム値をハッシュ化してストアを引き、レコードの `redirectTo` を使う。デバイス検証束縛（`store.ts` の `hashDeviceBindingSecret` 相当）と同じ照合モデルになる
- **方針 C（署名付き Cookie）**：Cookie の値に HMAC を付けて完全性を守る。サーバー側に鍵管理が増える一方、生成 OP には既存の署名鍵基盤と別の秘密が必要になり、ストアを持つ方針 B より導入コストが高い

## 8. タスク案

- [x] `tasks/p2-op-cookie-host-prefix.md` の対象 Cookie 列挙とテスト要件を 4 系統へ拡張する（本セッションで反映）
- [x] 方針 B を `tasks/p3-logout-confirmation-server-side-anchor.md` としてタスク化する
- [ ] 方針 C を採る場合の鍵管理の検討（タスク化しない。方針 B が退けられた場合にのみ再検討する）
