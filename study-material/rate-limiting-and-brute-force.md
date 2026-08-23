# レート制限 / ブルートフォース / 列挙攻撃対策

## ステータス

🟡 Major（セキュリティ）/ 未着手

## 1. このトピックで確認したいこと

OAuth/OIDC エンドポイントは、認証情報・トークン・コードを扱うため、**自動化攻撃**（ブルートフォース、コード／トークン推測、ユーザー列挙）の標的になりやすい。RFC 9700 はトークンを推測不能にすることやクライアント認証を扱うが、レート制限の具体策は規定していないため、RFC 6819 と NIST SP 800-63B も併せて参照する。

本リポジトリは現時点で **アプリケーション層のレート制限を一切実装していない**（Cloudflare Workers のプラットフォーム側 WAF / Turnstile / Rate Limiting に委ねる前提とも明示されていない）。
ここでは:

- OAuth/OIDC で守るべき対象とエンドポイント
- ライブラリ側 vs ホスティング側の責務分界
- 利用者が自分の OP でレート制限を組む際の指針

を整理する。

## 2. 関連する仕様・基準

共通の仕様索引は `study-material/basic-op-requirement-traceability.md` を参照。本トピック固有のポイント:

- **OAuth 2.0 Security Best Current Practice（RFC 9700）§2.5 / §4.14**:
  - クライアント認証の強化と、refresh token を生成・改変・推測不能にすることを要求する。
  - 失敗試行のレート制限、応答時間の固定、エンドポイントごとの監視は RFC 9700 の明示要件ではなく、RFC 6819 と運用上の防御策として整理する。
- **OAuth 2.1 §7**: §10/§11 で credential brute force を「実装が緩和する」前提が記載。
- **OIDC Core §16.13**: Replay 攻撃と Token 重複使用への注意。
- **NIST SP 800-63B**: 認証失敗回数のロックアウト基準（通常 100 回 / 30 日等。OP のログイン UI に該当）。
- **エンドポイント別の典型脅威**:
  - Authorization Endpoint: ログイン試行のブルートフォース、`prompt=none` の同意済み判定スキャン、ユーザー列挙（エラーメッセージ差異）
  - Token Endpoint: client_secret のブルートフォース、code の推測（短いランダム値の場合）、refresh_token のブルートフォース
  - UserInfo Endpoint: access_token のブルートフォース（opaque AT の場合）
  - Introspection / Revocation: client_secret ブルートフォース
  - Discovery / JWKS: 認証不要なので DoS 標的（読み取り専門だが帯域消費）

## 3. 参照資料

- OAuth 2.0 Security Best Current Practice（RFC 9700）: https://www.rfc-editor.org/rfc/rfc9700.html
- OAuth 2.0 Threat Model（RFC 6819）: https://www.rfc-editor.org/rfc/rfc6819
- OIDC Core §16: https://openid.net/specs/openid-connect-core-1_0.html
- NIST SP 800-63B（参考、認証強度の文脈）: https://pages.nist.gov/800-63-3/sp800-63b.html

## 4. 現在の実装確認

- 汎用のレート制限 / アカウントロックは **実装されていない**（grep でレートリミッタの実装は見当たらない）。
  - ⚠️ **訂正**: ログイン失敗試行のカウント自体は `packages/core/src/auth-transaction.ts` の
    `handleLoginFailure`（既定 5 回）として **実装されている**。ただしカウンタが認可トランザクション単位で、
    攻撃者が認可エンドポイントを叩き直せばリセットできるため、総当たり対策として機能していない。
    この個別欠陥は `study-material/done/login-attempt-throttling-scope-and-reset-bypass.md` と
    `tasks/p2-login-attempt-throttling-subject-scope.md` で扱う。本ファイルは横断的な攻撃面の棚卸しに専念する。
- client_secret の比較は `tasks/p0-client-secret-timing-safe-comparison.md` で改善予定（タイミング攻撃面）。
- 認可コードのエントロピー: `packages/core/src/authorization-code.ts` で `generateRandomString` 経由。実装は十分なエントロピーを持つ（要確認: 32 文字以上）。
- refresh_token のエントロピー: 同様に `generateRandomString` 経由。
- Discovery / JWKS の Cache-Control: short TTL があれば DoS は抑制できる（個別タスク対象）。

## 5. 現在の実装との差分

- 🟡 **アプリ層レート制限が空白**: Cloudflare Workers のプラットフォーム機能（Rate Limiting / Turnstile）に委ねる方針自体は妥当だが、**ライブラリ側で「ここはレート制限すべき」推奨が明示されていない**。利用者が漏らすリスクがある。
- 🟢 **エラー応答からの情報漏洩（確認済み・問題なし）**: ログイン UI で「ユーザーが存在しない」と「パスワードが違う」の差異を返すと列挙攻撃を許す。生成コード `routes/login.ts` を確認したところ、いずれの場合も同一メッセージ（`Invalid credentials`）・同一 HTTP ステータスを返しており、メッセージ経由の列挙は成立しない。ただし将来パスワードをハッシュ検証に変更すると「未知ユーザーは速く失敗する」タイミング差が生まれるため、ダミー検証が必要になる。詳細は `study-material/end-user-authentication-contract-and-credential-handling.md` を参照。
- 🟡 **`prompt=none` の悪用**: 攻撃者が複数 RP で `prompt=none` を試して「セッションが立っているか」を推測する。実装側で `prompt=none` 試行レートを抑える、もしくは `interaction_required` を一律で返すなどの推奨を出していない。
- 🟢 **コード／トークンのエントロピー**: 主要 secret は CSPRNG 由来で十分（`crypto-utils.ts` の `generateRandomString`）。

## 6. 改善・追加を検討する理由

価値:

- 本リポジトリは Cloudflare Workers ベース sample で出すが、利用者が他環境（Node、Bun、AWS Lambda、自前 Hono）にデプロイすることもありうる。**「プラットフォームに委ねる」一辺倒では、特定環境でハマる**。
- ライブラリとしてレート制限を実装するのは責務オーバーだが、「**どこを守るべきか／どこをホスティングに委ねてよいか**」を分界した文書を出すだけで利用者の事故が減る。
- `tasks/done/oidc-improvements-2026-05.md` の流れで個別改善を進めているが、横断的な「攻撃面 → 対策」表が無い。

導入難易度:

- 🟢 **ドキュメント中心で進められる**。
- 🟡 **オプションで `RateLimitResolver` の I/F を切る案**: core から見て「ここで失敗回数を加算してください」というフックを提供できる。ただし I/F を増やすと OSS UX 上の負担も増える。

実装しない場合:

- 利用者が「攻撃を受けて初めて穴に気づく」ファネルになる。本リポジトリの「Fidelity」「本番志向」と整合しない。

## 7. 実装方針の候補

### 方針A（ガイドライン文書化のみ）

- 本ファイルに以下を表で固定:
  - エンドポイント × 攻撃面 × 推奨対策 × 責務（ライブラリ / 利用者 / ホスティング）
- CLI 生成テンプレに「ここでレート制限ミドルウェアを置く想定」のコメント付き箇所を残す。

### 方針B（ライブラリにフックを追加）

- core の主要検証関数（client_auth、token_request、auth_transaction）に **オプションの監視フック**（`onAuthenticationFailure(context)`）を追加。
- 利用者は自前のカウンタ（KV / D1 / Durable Object など）と接続でき、しきい値超過で 429 を返せる。
- ライブラリ自身はカウンタを実装しない。

### 方針C（最小実装 + フック）

- 上記 B に加え、CLI Hono テンプレに **デフォルトのインメモリレートリミッタ**（開発用、Cloudflare KV/Durable Object 例も併記）を提供。
- 利用者は本番では自分のストアに切り替える。

判断材料:

- 方針 A は OSS の責務として妥当。
- 方針 B は I/F が増えるが、利用者が「フックを呼んでくれる」ので実装漏れが減る。
- 方針 C は便利だがメンテ負荷増。

## 8. タスク案

- [ ] 方針 A / B / C のどれを採用するかを人間が判断
- [ ] 方針 A 採用時:
  - [ ] 本ファイルに「エンドポイント × 攻撃面 × 対策 × 責務」表を固定
  - [ ] ログイン UI のエラーメッセージを「ユーザー存在 / パスワード違い」を区別しない形に統一する CLI テンプレ修正を提案
  - [ ] `prompt=none` のスキャン抑制ポリシーを文書化（lifecycle として `interaction_required` を返す閾値、IP 単位の rate-limit 想定）
- [ ] 方針 B 採用時:
  - [ ] `onAuthenticationFailure` / `onTokenRequestFailure` / `onPromptNoneFailure` などの監視フックを設計
  - [ ] 既存 `client-auth.ts` / `token-request.ts` / `auth-transaction.ts` にフック呼び出しを追加（呼び出しは最小コスト、未指定なら no-op）
  - [ ] テスト: フックが正しく失敗回数だけ呼ばれること、成功時には呼ばれないこと
- [ ] 方針 C 採用時:
  - [ ] CLI Hono テンプレに inMemoryRateLimiter / DurableObjectRateLimiter 等のサンプル
  - [ ] sample アプリで 429 が出るシナリオを E2E テスト化
- [ ] 関連: `tasks/p0-client-secret-timing-safe-comparison.md` と本ファイルでブルートフォース面の責務を分割（タイミング攻撃は既存タスク、回数制限は本ファイル）
