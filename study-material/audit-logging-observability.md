# 監査ログ / 可観測性（Audit Logging / Observability）の整備

## ステータス

🟡 Major（運用 / セキュリティ / OSS UX）/ 未着手

## 1. このトピックで確認したいこと

OAuth/OIDC OP は **認証・認可イベント・トークン発行履歴・失敗イベントを残せる**ことが、本番志向の利用者にとって必須要件である。

- 攻撃検知（refresh token reuse、code reuse、PKCE 不一致、認可コードリプレイ）
- 不正アクセス調査（誰がいつ何の AT/RT を取得したか）
- ライセンス／監査・コンプライアンス対応（ISO 27001、SOC 2、PCI-DSS、銀行業ガイドライン）

本リポジトリ:

- core のロジックはほぼ純関数で、ログ／メトリクス出力点が無い（`packages/core/src/`）
- CLI が生成するサンプルにも構造化ログ出力の組込みが無い
- 既存タスクで「監査ログ」「Observability」を独立論点として扱った文書は無い（`rate-limiting-and-brute-force.md` の文脈で軽く触れる程度）

このファイルは **「core / CLI / sample にどう監査フックを挿すか」「OSS 利用者にどんなイベントが拾えるよう設計すべきか」**の判断材料を整理する。

## 2. 関連する仕様・基準

監査ログ自体は OIDC/OAuth 仕様で **必須化されていない**が、関連仕様で言及がある:

- **OAuth 2.0 Security BCP**（RFC 9700）
  - §4.8 / §4.14 は PKCE downgrade と Refresh Token replay の検出処理を要求するが、異常イベントの記録方式は規定しない。Code 再利用、PKCE 失敗、redirect_uri 不一致をログに残すことは運用上の推奨として扱う。
- **RFC 9068 JWT Access Token §5**: AT に `jti` を含めることで失効・追跡が可能になる（既存タスク `tasks/p2-jwt-access-token-jti.md` で扱う）。
- **PCI-DSS / FedRAMP / NIST SP 800-63**: 業界・政府向け規格は認証イベントの保管期限（90日〜1年以上）と改竄防止を要件化することが多い。
- **OpenTelemetry**: 業界デファクトの telemetry プロトコル。OP 実装に組み込めば外部のオブザーバビリティ基盤（Datadog、Honeycomb、Grafana 等）に統合しやすい。

仕様準拠の必須要件ではなく **本番志向ユーザー向けの差別化軸**であることに注意。

## 3. 参照資料

- OAuth 2.0 Security Best Current Practice（RFC 9700）: https://www.rfc-editor.org/rfc/rfc9700.html
- OAuth 2.0 Threat Model and Security Considerations（RFC 6819）: https://www.rfc-editor.org/rfc/rfc6819
- NIST SP 800-63B（Digital Identity Guidelines / Authentication Lifecycle Management 含む）: https://pages.nist.gov/800-63-3/sp800-63b.html
- OpenTelemetry Semantic Conventions for HTTP: https://opentelemetry.io/docs/specs/semconv/http/
- 関連: `study-material/rate-limiting-and-brute-force.md`（攻撃検知文脈）、`study-material/resolver-and-store-contract.md`（外部化された I/F のフック点）

## 4. 現在の実装確認

- core: 例外を `throw` する箇所はあるが（`AuthorizationError` / `TokenError` / `UserInfoError` / `IntrospectionError` / `RevocationError`）、**観測フック（コールバック / イベントエミッタ）は無い**。
- core の検知ロジック:
  - `token-request.ts` 内 Refresh Token 再利用検知 → cascade revoke（`tasks/done/oidc-improvements-2026-05.md` T-003）
  - 認可コード再利用検知 → cascade revoke（`tasks/done/p0-token-revocation-on-code-reuse.md`）
  - PKCE 不一致 → `invalid_grant` エラー
  - これらは **`throw` するだけで、検知イベントを呼び出し側に「通知」する手段が無い**。
- CLI / sample: `console.log` レベルでも構造化ログ出力の規約無し（個別ルートで `console.error` する程度）。
- ID Token / AT の `jti` クレーム未付与 → 既存 `tasks/p2-jwt-access-token-jti.md` で扱う。`jti` が無いとログ突合がしづらい。

## 5. 現在の実装との差分

- **満たしていること**: エラーの型が分類されている（`AuthorizationErrorCode` 等の enum）ため、ログイベントの種別キーには使える。例外発生位置が明確。
- **不足している可能性があること**
  - 観測点となる **イベントフック / コールバック I/F**。例:
    ```typescript
    export interface AuditSink {
      onTokenIssued?(event: {...}): void;
      onTokenReused?(event: {...}): void;
      onPkceMismatch?(event: {...}): void;
      ...
    }
    ```
    を core が受け取り、検知時に発火する。同期 / 非同期どちらにするかは要設計。
  - 推奨イベント種別（最小セット）:
    - 認可リクエスト受理 / 拒否
    - 認可コード発行
    - 認可コード使用（成功）／再利用検知（失敗）
    - Refresh Token 発行
    - Refresh Token 使用（成功）／再利用検知（失敗 + cascade revoke 発火）
    - クライアント認証成功 / 失敗
    - PKCE 検証失敗
    - UserInfo 取得（任意、PII を含むためログレベル要慎重）
  - **PII の扱い**: `sub` を直接ログに残すかは利用者選択。core からは `sub` を渡しつつ、利用者が hashing / redact できる設計。
  - 構造化ログのスキーマ規約。例:
    ```json
    {
      "event": "refresh_token.reused",
      "ts": "2026-05-22T12:00:00Z",
      "iss": "...",
      "client_id": "...",
      "grant_id": "...",
      "jti": "...",
      "outcome": "rejected_cascade_revoked"
    }
    ```
  - CLI 生成テンプレートに「`AuditSink` を実装する例」を含めるかどうか。最小例は `console.log` で十分。
- **セキュリティ観点**
  - ログ自体の改竄防止は OP 実装の責務外。WORM ストレージ・署名付きログ・SIEM 転送は利用者責務として明記。
  - Refresh Token / Access Token の **値そのものをログに残さない**こと。`jti` / `grantId` / `clientId` で識別する。core からのイベント引数に value を含めない設計が必要。
  - レート制限ログ（`rate-limiting-and-brute-force.md`）と監査ログを統合管理するか分けるかは利用者選択。

## 6. 改善・追加を検討する理由

- 「本番導入を見据える開発者」をターゲットにする以上、監査要件が **PoC 段階で見えていないと採用がブロックされる**。
- core 側に **イベントフック I/F だけ**入れておけば、利用者が SIEM・OpenTelemetry・カスタムログに自由に統合できる。実装コストは中程度、影響は大。
- 既存の `resolver-and-store-contract.md` 設計と同じ「外部化された I/F を core に持たせる」方針と一貫する。
- 実装しない場合の制約: 利用者がライブラリ内部で何が起きているかを観測できず、エラー発生時にスタックトレース以外の情報がない。攻撃検知・コンプライアンス対応が自力で困難。

## 7. 実装方針の候補

### 方針A（推奨）: `AuditSink` I/F を core に導入、CLI に最小実装例

- `packages/core/src/audit.ts` 新規。`AuditSink` インターフェース定義 + ヘルパー。
- core の検知ポイント（`token-request.ts` / `authorization-request.ts` / `client-auth.ts` / `revocation.ts` / `userinfo.ts`）から `auditSink?.on*()` を非同期呼び出し（fire-and-forget）。
- 後方互換: `AuditSink` は **オプショナル**。未設定なら何も呼ばない。既存テストは影響しない。
- イベント設計:
  - 最小: `token.issued` / `token.refresh_reused` / `code.reused` / `client_auth.failed` / `pkce.mismatch`
  - 値そのもの（access_token 文字列）は含めない、`jti` / `grantId` / `clientId` / `sub` のみ。
  - PII を含むイベントは利用者が redact できるよう、payload を構造化（hashing 用フィールドを別途）。
- CLI: 生成テンプレートに「`console.log` する AuditSink 例」を入れる。利用者は差し替え自由。
- ドキュメント: `resolver-and-store-contract.md` に AuditSink セクションを追記（独立ファイル化はしない、責務が近接するため）。

### 方針B（最小）: ドキュメント + ベストプラクティスのみ

- 実装変更なし。`resolver-and-store-contract.md` に「監査ログは利用者責務。本ライブラリは `throw` する例外で代替できる」旨を追記。
- ただしこれだと検知タイミングを正確に把握できない（例外の前後でログを挟むしかなく、cascade revoke のような **複合イベント**が表現しづらい）。

### 方針C: OpenTelemetry 統合の標準サポート

- core で `@opentelemetry/api` を peer dependency にし、span/event を発火する。
- メリット: 業界標準に直接乗せられる。
- デメリット: 外部依存になる（CLAUDE.md の「dependencies は内部ライブラリのみ」と矛盾する。peer dependencies なら回避可能だが peer も慎重さが必要）。

## 8. タスク案

- [ ] 方針A/B/C を選択する（ユーザー判断）。CLAUDE.md の外部依存ポリシーから方針A が現実解
- [ ] 方針A 採用時: 必要イベントの一覧と payload スキーマを確定（最小セット v0、拡張可）
- [ ] `AuditSink` I/F のテストを先行作成（フックが呼ばれること、`AuditSink` 未設定時に既存挙動が変わらないこと）
- [ ] core: `audit.ts` 追加と各検知ポイントへの呼び出し挿入
- [ ] CLI: 生成テンプレートに `AuditSink` の最小例（console.log 版）を追加
- [ ] ドキュメント: `resolver-and-store-contract.md` に AuditSink セクション追記
- [ ] PII / トークン値漏洩防止のガイドライン明記
- [ ] 完了条件: core / cli テストパス、CLI で生成したサンプルが `AuditSink` を opt-in で利用できること
