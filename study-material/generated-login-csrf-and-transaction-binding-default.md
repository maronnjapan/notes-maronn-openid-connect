# 既定生成 OP の `/login` に対する login CSRF と transaction-binding 既定 OFF の再評価

## ステータス

🔴 High / 検討中（既定値の変更は利用者影響があるため、方針確定後にタスク化する）

## 1. このトピックで確認したいこと

CLI の既定生成物（`transaction-binding` 無効）で、`/login` への cross-site POST による login CSRF（攻撃者のセッションを被害者のブラウザへ植え付ける攻撃）を防げているかを確認する。
あわせて、`transactionBinding: false` という既定値の根拠が、この脅威を考慮したうえでの判断になっているかを確認する。

## 2. 関連する仕様・基準

- RFC 6749 §10.12（CSRF）
  認可サーバーの UI を含むエンドポイントの CSRF 防御を求めている。
- OWASP Cross-Site Request Forgery Prevention Cheat Sheet（Login CSRF）
  ログインフォームの CSRF は「被害者を攻撃者のアカウントでログインさせる」向きの攻撃として整理されている。
  hidden トークン単体では防げず、トークンをセッション（cookie）に束縛する必要がある。

## 3. 参照資料

- OWASP CSRF Prevention Cheat Sheet
- RFC 6749 §10.12
- `study-material/done/auth-transaction-user-agent-binding.md` と `tasks/done/p1-auth-transaction-user-agent-binding.md`
  （transaction-binding 機能を導入した経緯。扱った脅威は transaction_id 漏洩後の「強制同意」と「被害者 identity の攻撃者クライアントへの受け渡し」であり、本トピックとは攻撃の向きが逆になる）

## 4. 現在の実装確認

- `packages/cli/src/features.ts` で `transactionBinding: false` が既定である。
- `packages/cli/src/frameworks/hono/templates.ts` のコメントは、既定 OFF の理由を「OIDC Core / OAuth 2.1 に要求する条文がない」「curl などブラウザ以外からフローを叩けなくなる」としている。
- binding 無効のとき、`POST /login` に残る防御は `validateCsrfToken`（トランザクションに保存した csrf_token と hidden フィールドの一致検査）だけである。
  csrf_token は `GET /login?transaction_id=T` を知る者なら誰でも読めるため、セッションに束縛されていない。
- 同じテンプレート内の device フローと CIBA の承認画面は、「hidden csrf_token 単体では login CSRF を防げない（攻撃者が自分で正規の id + csrf_token の組を取得して罠に埋め込める）」と明記したうえで、cookie への束縛を常時有効にしている。
- `samples/*` は 4 つとも `transaction-binding` を有効にして生成されているため、サンプルではこの問題は再現しない。

## 5. 現在の実装との差分

- 攻撃シナリオ（既定生成物の場合）
  1. 攻撃者が自分のブラウザで `/authorize` を開始し、`/login?transaction_id=T` から csrf_token を読み取る。
  2. 罠ページが被害者のブラウザに、`transaction_id=T`、その csrf_token、攻撃者の資格情報を載せた `POST /login` をトップレベルナビゲーションで送信させる。
  3. トップレベルナビゲーションなので `SameSite=Lax` の session cookie は被害者のブラウザへ設定される。
  4. 以後、被害者がこの OP を使う RP にアクセスすると、SSO の高速経路で攻撃者の subject として認可コードが発行される。
    攻撃者が事前に自分のアカウントで同意済みなら `prompt=none` でも成立する。
  5. 被害者は攻撃者アカウントで RP を使うことになり、RP に入力したデータを攻撃者が後から閲覧できる。
- 既定 OFF を選んだ判断（コメントに残る根拠）は「transaction_id 漏洩後の悪用に対する追加防御」という整理であり、transaction_id を攻撃者自身が正規に取得できる login CSRF の向きを検討していない。
- Next.js だけは、ログインが Server Action で動き、フレームワーク側の Origin 検査が cross-site POST を拒否するため影響を受けない可能性が高い。
  ただしこれは生成コード側の保証ではなく、フレームワークの実装詳細への依存である（未検証）。

## 6. 改善・追加を検討する理由

既定生成物は「`maronn-oidc generate <framework>` の出力をそのまま動かす」利用形態の入口であり、PoC がそのまま外部公開される場合もある。
device と CIBA の承認画面がこの攻撃を防ぐ前提で設計されている以上、メインのログイン画面だけが同じ攻撃に無防備という非対称は、設計判断としても記録に残っていない。
一方で、binding を既定 ON にすると cookie を運ばないクライアント（curl、Conformance Suite の一部テスト）でフローが完走できなくなるという、既定 OFF を選んだ当初の理由も実在する。
防御の方式選択（binding 既定 ON か、Origin ヘッダ検査か）はトレードオフがあり、ここで確定しない。

## 7. 実装方針の候補

1. **transaction-binding を既定 ON にする**
   device / CIBA と同じ防御に揃う。
   curl でのフロー再現と Conformance 互換には、生成時フラグか環境変数での明示的な無効化を残す。
2. **`POST /login`（と `POST /consent`）に Origin ヘッダ検査を追加する**
   Fetch Metadata / Origin が issuer と一致しない cross-site POST を拒否する。
   cookie に依存しないため curl 互換を保てるが、Origin を送らない古いクライアントの扱いを決める必要がある。
3. **既定 OFF を維持し、脅威を文書化する**
   生成コードのコメントと README に「binding 無効の既定では login CSRF を防げない」旨を明記し、公開運用では有効化を促す。

## 8. タスク案

- 方針 1〜3 の選択は人間の判断を待つ（既定値の変更は全フレームワークの生成物と契約テスト `transactionBindingDisabledConformanceBlock` の期待値に影響する）。
- 方針確定後、選んだ方式の実装と、login CSRF を再現する契約テスト（攻撃者の transaction_id + csrf_token の組を別ブラウザ相当のリクエストから POST して拒否されること）をタスク化する。
