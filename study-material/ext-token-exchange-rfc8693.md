# 拡張: OAuth 2.0 Token Exchange（RFC 8693）

## ステータス

🟢 拡張機能 / 未着手

## 1. このトピックで確認したいこと

サブジェクト・トークン（access_token / id_token / SAML 等）を新しいトークンに交換するための仕様 **RFC 8693 Token Exchange** を本リポジトリに導入するかを整理する。
具体的な用途は:

- マイクロサービス間の **トークン スコープ縮小（downscope）**
- 別 audience / 別 resource へのトークン発行
- 委譲 / インパーソネーション（`act` / `may_act` クレーム）
- ID Token を **OAuth Access Token に交換**

Basic OP の必須範囲ではないが、SaaS や複数バックエンドを跨ぐ PoC で頻出する。

## 2. 関連する仕様・基準

共通の仕様索引は `study-material/basic-op-requirement-traceability.md` を参照。本トピック固有のポイント:

- **RFC 8693**:
  - 新規 `grant_type=urn:ietf:params:oauth:grant-type:token-exchange`。
  - リクエストパラメータ:
    - `subject_token`（必須）、`subject_token_type`（必須、例: `urn:ietf:params:oauth:token-type:access_token`、`...:id_token`、`...:jwt`）
    - `actor_token` / `actor_token_type`（任意、委譲）
    - `audience` / `resource` / `scope` / `requested_token_type`
  - レスポンス:
    - `access_token` / `issued_token_type` / `token_type` / `expires_in`、必要に応じ `refresh_token` / `scope`
  - **`act` クレーム**: 委譲チェーンを表現。発行されるトークンに含める。
  - **`may_act` クレーム**: ID Token 等が「この actor が代わって動いてよい」と事前に許可する（OP が事前検証で参照）。
- **セキュリティ Considerations（RFC 8693 §6）**:
  - subject token の検証は厳格に。署名 / 期限 / `aud` / `iss` を確認。
  - スコープ拡大の拒否（縮小のみ許可するポリシーが安全側）。
  - 委譲のチェーン長制限。
  - 公衆クライアントの token-exchange は通常拒否。
- **Discovery**:
  - `grant_types_supported` に `urn:ietf:params:oauth:grant-type:token-exchange` を含める。
  - 必要に応じ `token_endpoint_auth_methods_supported` の文脈で意味づけ。

## 3. 参照資料

- RFC 8693 OAuth 2.0 Token Exchange: https://www.rfc-editor.org/rfc/rfc8693
- RFC 8693 §6 Security Considerations: https://www.rfc-editor.org/rfc/rfc8693#section-6
- 関連するセキュリティガイダンス（RFC 9700）: https://www.rfc-editor.org/rfc/rfc9700.html

## 4. 現在の実装確認

- Token Exchange の実装は無い。
- `Token Endpoint`（`packages/core/src/token-request.ts`）は `authorization_code` / `refresh_token` のみ。
- ID Token の検証ロジックは `validateIdTokenHint`（`packages/core/src/id-token.ts`）が存在し、subject_token=id_token のときに **再利用可能**。
- `act` / `may_act` クレームの発行ロジックも `IdTokenPayload` の動的キーで通せるが、明示的なサポートは無い。

## 5. 現在の実装との差分

- 🟢 **Basic OP プロファイル要件ではない**: 仕様違反ではない。
- 🟡 **コンセプト的に「自分の要件がこの仕様で実現できるか」検証層と相性が良い**: 特にマイクロサービス／BFF アーキテクチャの PoC で需要。
- 🟢 **広告整合性**: 対応していないため広告無し。

## 6. 改善・追加を検討する理由

価値:

- AWS STS / Google Workload Identity Federation / Azure AD token exchange など、商用クラウドが採用している。OSS で動くサーバを使って同等の動作を試したいニーズがある。
- 既存の Refresh Token Rotation との設計整合性が高い（grant_id ベースのトークン管理、`tasks/done/01-refresh-token.md`）。同 `grantId` に紐づく派生トークンとして TX で発行するトークンを管理できる。

導入難易度:

- 🟡 **subject_token の検証種別が複数**: ID Token（JWT）/ Opaque Access Token（自前 introspection）/ JWT Access Token（RFC 9068 検証）の 3 経路。
- 🟡 **ポリシー判断が肝**: スコープ縮小／拡大、audience 変更、actor 委譲の許容ポリシーは利用者の OP 実装ごとに違う。**ポリシー実装は resolver 注入**にして core は判定機構だけ提供する形がライブラリとしては自然。
- 🟢 **既存資産流用**:
  - ID Token 検証: `validateIdTokenHint` を再利用
  - JWT AT 検証: `packages/core/src/access-token.ts` のロジック
  - Refresh Token Rotation: `grant_id` 設計を流用してチェーン管理

実装しない場合:

- マイクロサービス委譲系の PoC は不可。一般的 OIDC / OAuth 2.1 検証には影響しない。

## 7. 実装方針の候補

### 方針A（非対応の明文化）

- `RELEASE-v0.x-scope.md` に「v0.x スコープ外」を明記。

### 方針B（最小: subject_token_type=id_token のみ）

- ID Token を subject token として受け取り、新しい access_token を発行するだけのスコープ。
- subject_token は **同一 OP が発行した ID Token** に限定（外部 IdP の ID Token は受け入れない）。
- スコープ縮小のみ許可（拡大は `invalid_scope`）。
- `act` クレームの自動付与は無し（呼び出し側 / resolver の責務）。

### 方針C（フルセット）

- subject_token_type: access_token / id_token / jwt を網羅。
- audience / resource パラメータ、`act` / `may_act` 完全対応。
- 委譲ポリシー注入用の `TokenExchangePolicyResolver` I/F。

### 方針D（プラグイン）

- core の `Token Endpoint` を grant-type プラグインに変える（`registerGrantTypeHandler('urn:ietf:params:oauth:grant-type:token-exchange', ...)`）。
- Device Flow / CIBA / TX を同じプラグイン構造で受け入れられるようにする抽象化。

判断材料:

- 方針 D は影響範囲が大きいが、複数の grant_type 拡張（Device / CIBA / TX）を一気にやるなら投資価値が高い。
- まず方針 A を採り、需要に応じて方針 B から始めるのが堅実。

## 8. タスク案

- [ ] 方針 A / B / C / D のどれを採用するかを人間が判断
- [ ] 方針 B 採用時:
  - [ ] `Token Endpoint` に `grant_type=urn:ietf:params:oauth:grant-type:token-exchange` の分岐追加
  - [ ] subject_token=id_token を `validateIdTokenHint` 相当で検証
  - [ ] スコープ縮小チェック（要求 scope ⊆ subject token scope）
  - [ ] `TokenExchangePolicyResolver`（最小は「縮小のみ許可」固定でも可）
  - [ ] Discovery に `grant_types_supported` で token-exchange を広告
  - [ ] テスト: ID Token を渡し downscoped access_token を取得、拡大スコープ要求は拒否、subject_token 改ざんは拒否
- [ ] 方針 C 採用時: 上記 + access_token / jwt の subject_token_type、`act` / `may_act` 対応
- [ ] 方針 D は別タスクとして grant-type プラグイン化を切り出し（Device / CIBA / TX 全体を見越した抽象化）
