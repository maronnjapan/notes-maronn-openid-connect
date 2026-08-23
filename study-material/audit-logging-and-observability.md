# 監査ログと可観測性（Authentication / Authorization Events）

## ステータス

🟡 運用品質 / Major / 未着手

## 1. このトピックで確認したいこと

OIDC OP は本番運用で **誰が・いつ・どのクライアントで・何の結果になったか**の監査ログを残すことが期待される。
具体例:

- ログイン成功 / 失敗（クライアント・ユーザー・要因）
- 同意付与 / 拒否
- 認可コード発行 / 引き換え
- access_token / refresh_token 発行 / リフレッシュ / 失効
- refresh_token 再利用検知（cascade revocation 発火）
- クライアント認証失敗（client_secret 不一致）
- 不正パラメータ / セキュリティ違反（PKCE 不一致、redirect_uri 不一致）

本リポジトリは現状、コア層は純関数ライブラリで副作用を持たず、ログ出力を一切しない。
sample / CLI 生成コードも `console.log` 程度で、構造化ログ・標準スキーマは未整備。

確認したいこと:

- OP として最低限残すべきイベント種別
- 業界標準スキーマ（SCIM Audit Events / RFC 8417 SET / CAEP）との整合
- core の純関数性を保ちつつ、可観測性 hook をどう注入するか
- 既存 study-material（rate-limiting-and-brute-force など）との接続

## 2. 関連する仕様・基準

共通の仕様索引は `study-material/basic-op-requirement-traceability.md` を参照。本トピック固有のポイント:

- **OAuth 2.0 Security BCP（RFC 9700）**:
  - §4.8 と §4.14 は PKCE downgrade や refresh token replay を AS が検出するための処理を要求する。ただし監査ログやイベント形式は規定しないため、検出結果をログに残すことは本リポジトリの運用上の推奨として扱う。
- **OIDC Core / Conformance Suite**:
  - 仕様自体は監査ログを必須化しないが、認定運用で「ログを後から検証できる」ことが暗黙の前提。
- **RFC 8417 Security Event Token（SET）**:
  - セキュリティイベント（ログアウト、トークン失効、ユーザー無効化等）を JWT で表現する標準フォーマット。
  - イベントタイプは `events` クレームの URI で識別。例:
    - `https://schemas.openid.net/secevent/risc/event-type/account-disabled`
    - `https://schemas.openid.net/secevent/risc/event-type/credential-change-required`
- **OpenID Continuous Access Evaluation Profile（CAEP）**:
  - SET の拡張。OP/RP 間でリアルタイムにセキュリティイベントを送る仕組み。FAPI / 高セキュリティ用途。
- **OWASP ASVS V7（Errors and Logging）**:
  - 認証イベントの記録、機密データのログ排除、ログの完全性。
- **GDPR / 個人情報保護法**:
  - ログにユーザー個人識別子（メール、氏名）を含める場合は **保存期間 / 削除手順**が必須。`sub` は内部識別子なので長期保存可能。

## 3. 参照資料

- OAuth 2.0 Security Best Current Practice（RFC 9700）: https://www.rfc-editor.org/rfc/rfc9700.html
- RFC 8417 Security Event Token: https://www.rfc-editor.org/rfc/rfc8417
- OpenID CAEP 1.0: https://openid.net/specs/openid-caep-specification-1_0.html
- OWASP ASVS V7: https://owasp.org/www-project-application-security-verification-standard/
- 本リポジトリ内: `study-material/rate-limiting-and-brute-force.md`（同じイベント発火源を扱う）
- 本リポジトリ内: `study-material/refresh-token-rotation-replay-grace.md`（cascade revocation のイベント発火点）

## 4. 現在の実装確認

- `packages/core/src/*.ts`: 純関数ライブラリでログ出力ゼロ。例外は `throw` で返すが、外部観測は呼び出し側責務。
- `packages/sample/src/oidc-provider/routes/*.ts`: `console.log` 等が散在するが、構造化なし。
- 監査用 store / sink の I/F は無い。
- refresh token 再利用検知（`packages/core/src/token-request.ts` の `revokeTokensByGrantId` 経路）は副作用が resolver 経由で行われるが、**「再利用を検知した」というイベントの可観測点**は呼び出し側が知るしかない（戻り値の error code を見るのみ）。

## 5. 現在の実装との差分

満たしていること:

- core の純関数性は保たれており、副作用を持つ resolver 経由でログを差し込む素地はある。
- エラー型（`AuthorizationError` / `TokenError` / `RevocationError` 等）にコードが定義されており、機械可読なエラー分類は可能。

不足／要確認:

- 🔴 **監査イベント I/F が未定義**: `AuditEventSink` のような型と、各エンドポイントで発火するイベント定義（`login_success`, `login_failure`, `code_issued`, `code_redeemed`, `token_refreshed`, `refresh_reuse_detected`, `revocation_requested` 等）が無い。
- 🔴 **イベントスキーマ統一なし**: イベント毎にどんなフィールドを残すか（clientId、subject、ipHash、userAgent、errorCode、timestamp）の正規スキーマ無し。
- 🟡 **PII / 機密データの除外方針**: 現状サンプルが `console.log` するときに `id_token` 本体・`access_token` 本体・パスワード・client_secret を **誤ってログに出していないか**の系統的チェックは無い。
- 🟡 **SET / CAEP との接続点無し**: イベントを JWT として外部に送出する I/F は無い。FAPI 系では将来必要になり得る。
- 🟡 **ログ集約 / 構造化**: 開発者が利用者に「Cloud Logging に送るには」「OpenTelemetry にエクスポートするには」を提示する雛形が無い。
- 🟡 **レート制限イベントとの連動**: `study-material/rate-limiting-and-brute-force.md` の検出イベント（同一 IP からの連続失敗等）は監査ログのキー入力でもある。同じ I/F で扱うのが自然。

セキュリティ観点:

- 🔴 **`error_description` の機密化**: 既存 `error-utils.ts` の `sanitizeErrorDescription` で外部応答はサニタイズされているが、**監査ログには詳細な error_description を残したい**。サニタイズ前後の差分を内部ログに残す経路を設ける必要あり。
- 🟡 **client_secret / access_token / refresh_token をログに出さない**: 静的解析または `console.log` の禁則ルール（lint）で防御。
- 🟡 **ログのリプレイ耐性 / 改ざん検知**: 高セキュリティでは SET / append-only ストレージが必要。PoC スコープでは不要。

相互運用性観点:

- 🟡 **CAEP / SET 対応**: 将来的に他 IdP / SaaS とセキュリティイベントを連携する場合に必要。本リポジトリの段階ではオプションだが I/F だけ揃えると拡張容易。

## 6. 改善・追加を検討する理由

- **本番志向ユーザーへの透明性シグナル**: 「PoC 完了後 IDaaS / 自前運用へ移行」の文脈で、監査ログがどう取れるかは IDaaS 選定の主要評価軸。OSS で **どこに hook を入れれば監査が取れるか**を示すこと自体が価値。
- **トラブルシュート効率**: PoC 中に「ログインが失敗する」「token が拒否される」を切り分けるには構造化ログが必須。`console.log` は再現困難。
- **セキュリティ事象の検出**: refresh_token 再利用、PKCE 違反、redirect_uri 違反などはセキュリティ侵害の兆候。検出経路を標準化すれば、利用者が IDS / SIEM 連携を組みやすい。
- **コスト**: I/F 設計 + 各エンドポイントへの hook 注入 + サンプル JSON ロガー実装で **中規模**。
- **実装しない場合のリスク**: 本番志向ユーザーが「ログが取れない OSS」と判断して離脱。SME 向けには「IDaaS 移行時にログ移行できない」が懸念点として残る。

## 7. 実装方針の候補

### 方針A（小・I/F 定義のみ）

- core に `AuditEventSink` インターフェースとイベント型（`AuditEvent`、`AuditEventType`、`AuditEventContext`）を定義。
- 既存 endpoints / handlers の主要分岐点に **イベント発火 callback** を任意で挿入（呼ばないと no-op）。
- 実装は利用者責務。JSON line に出すサンプル loggerを CLI/sample に同梱。

### 方針B（中・サンプル実装込み）

- 方針A + sample に「JSON line ログを stdout に出すデフォルト sink」を実装。
- イベント名・フィールドスキーマを README に明示。
- レート制限（`study-material/rate-limiting-and-brute-force.md`）の検出ロジックと統合。

### 方針C（フル・SET / CAEP 対応）

- 方針B + SET（JWT）発行ヘルパーを追加。外部 SaaS / IdP に CAEP 経由でイベント送出可能。

### 方針D（後送り）

- v0.x スコープ外。リリース後に継ぎ足し。`RELEASE-v0.x-scope.md` の Tier A シナリオには非ブロッカー。

最終判断は人間。本番志向ユーザー向け価値を考えると方針B が現実的。

## 8. タスク案

- [ ] `AuditEvent` / `AuditEventType` / `AuditEventSink` の型定義と TDD テストを先行作成
- [ ] 各エンドポイント（authorize / token / userinfo / revoke / introspect）の処理中で発火すべきイベント一覧を列挙（成功・失敗・セキュリティ事象）
- [ ] `AuditEventSink` を resolver と同じ注入方式（core は I/F のみ、実装は利用者）で組み込む
- [ ] PII / 機密値（client_secret、id_token、access_token、refresh_token、password）をイベントに含めないテストガード
- [ ] sample に JSON line stdout sink を同梱
- [ ] `study-material/rate-limiting-and-brute-force.md` の検出ロジックと統合（同イベントを発火）
- [ ] `study-material/refresh-token-rotation-replay-grace.md` の cascade revocation トリガーで `refresh_reuse_detected` イベントを発火（誤検知緩和時の挙動も含めて整理）
- [ ] README に「監査ログを取る」セクションを追加し、IDaaS 移行を見据えたフォーマット指針を記載
- [ ] SET / CAEP 対応は別タスクとして切り出し（方針C を採用する場合のみ）
