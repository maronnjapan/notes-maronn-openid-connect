# 拡張: Pushed Authorization Requests（PAR, RFC 9126）

## ステータス

🟢 拡張機能 / 未着手

## 1. このトピックで確認したいこと

認可リクエストのパラメータをフロントチャネル（ブラウザの URL）ではなく、
バックチャネルで AS に事前 POST して `request_uri` で参照する **PAR（RFC 9126）**を
拡張として提供すべきかを確認する。OAuth 2.0 Security BCP が推奨する強化策。

## 2. 関連する仕様・基準

- **RFC 9126（OAuth 2.0 Pushed Authorization Requests）**
  - §2: PAR エンドポイント（`pushed_authorization_request_endpoint`）。クライアント認証必須。
    認可パラメータを POST で受け、`request_uri`（`urn:ietf:params:oauth:request_uri:...`）と
    `expires_in` を返す。
  - §3: 認可エンドポイントは `request_uri` を受け、保存済みパラメータで処理。
    PAR で渡されたパラメータと矛盾するクエリは無視/拒否。
  - §5: Discovery メタデータ `pushed_authorization_request_endpoint`、
    `require_pushed_authorization_requests`（任意で PAR 必須化）。
- **OAuth 2.0 Security BCP**: PAR を推奨（リクエスト改ざん・漏洩耐性向上）。
- Basic OP 必須ではない（拡張）。位置づけは `tasks/basic-op-requirements-baseline.md` 参照。

## 3. 参照資料

- RFC 9126: https://www.rfc-editor.org/rfc/rfc9126
  - §2 PAR Endpoint / §3 Authorization Request / §5 Metadata
- OAuth 2.0 Security BCP（RFC 9700）: https://www.rfc-editor.org/rfc/rfc9700.html
- RFC 8414 §2（メタデータ）: https://www.rfc-editor.org/rfc/rfc8414#section-2

## 4. 現在の実装確認

- 認可リクエストはクエリ受理前提: sample `routes/authorize.ts:57`
  `Object.fromEntries(new URL(c.req.url).searchParams)`（POST 認可は done p0-authorization-endpoint-post）。
- 認可パラメータの一時保存機構は既に存在: `auth-transaction.ts`
  （`AuthTransaction` を `AuthTransactionStore` に保存、ランダム ID で参照）。
  **PAR の `request_uri` ↔ 保存パラメータの構図に近い既存資産**がある。
- クライアント認証は `client-auth.ts`（`client_secret_basic`/`post`）が再利用可能。
- PAR エンドポイント／`request_uri` 受理／対応 Discovery メタデータは **未実装**。
- 関連: `request`/`request_uri`（JAR）非サポートは
  `tasks/done/oidc-improvements-2026-05.md` T-018 で別途記録（PAR の `request_uri` は
  JAR の `request_uri` とは別物だが、認可エンドポイントの `request_uri` 受理判定で交差する点に注意）。

## 5. 現在の実装との差分

- **満たしていること**: パラメータ事前保存（auth-transaction）とクライアント認証の
  再利用可能な部品が既にある。PAR の中核は「保存して URI で参照」であり親和性が高い。
- **不足している可能性があること**
  - PAR エンドポイント本体（クライアント認証 + パラメータ検証 + `request_uri` 発行）。
  - 認可エンドポイントでの `request_uri`（PAR 由来）解決と「他パラメータ無視/拒否」ポリシー。
  - Discovery への `pushed_authorization_request_endpoint` / `require_pushed_authorization_requests`。
  - T-018（JAR の `request_uri` 非サポート）と PAR の `request_uri` 受理の整合
    （URN スキーム判定で分岐する設計が必要）。
- **相互運用性/セキュリティ**: PAR 非対応でも Basic OP は成立。あくまで強化拡張。

## 6. 改善・追加を検討する理由

- 「最新仕様を最速で試せる」コンセプトに合致。FAPI 2.0 等のセキュアプロファイル前提として
  PAR を検証したい利用者は多い。
- auth-transaction の既存設計を活かせるため **導入しやすい部類**。
- 実装しない場合の制約: セキュアプロファイル（FAPI 等）の事前検証ができない。

## 7. 実装方針の候補

### 方針A（core ヘルパー + テンプレート）

- core に「PAR リクエスト検証 → 保存用 transaction 生成 → `request_uri`/`expires_in` 算出」の
  純関数を追加（`auth-transaction.ts` の `createAuthTransaction` を再利用）。
- 認可エンドポイント側に「`request_uri`（PAR URN）なら保存 transaction を解決し、
  他クエリは無視（RFC 9126 §3）」分岐を追加。JAR の `request_uri`（T-018 非サポート）とは
  URN プレフィックスで判別。
- Discovery（core builder）に `pushed_authorization_request_endpoint` 等を追加
  （`tasks/discovery-code-challenge-methods-supported.md` と同じ「core builder へ寄せる」方針で整合）。
- CLI テンプレートに PAR ルートを生成。`require_pushed_authorization_requests` は config。

### 方針B（最小・実験的）

- PAR エンドポイントと `request_uri` 解決のみ。Discovery の必須化フラグや
  パラメータ矛盾検出は後続。

### 方針C（非対応の明文化）

- 当面非対応とし、ロードマップに記載。

## 8. タスク案

- [ ] 方針A/B/C を選択（ユーザー判断）。`require_pushed_authorization_requests` の既定（false 推奨）も決定
- [ ] PAR 検証・`request_uri` 発行・認可側解決のテストを先行作成
- [ ] core: PAR 検証ヘルパー実装（auth-transaction 再利用）
- [ ] 認可エンドポイント: PAR `request_uri` 解決分岐（JAR `request_uri` 非サポートと判別）
- [ ] Discovery メタデータ追加（core builder へ）
- [ ] CLI/sample テンプレートに PAR ルート生成
- [ ] 完了条件: core / cli テストがパス
