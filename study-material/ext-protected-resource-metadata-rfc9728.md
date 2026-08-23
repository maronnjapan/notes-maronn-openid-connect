# 拡張: OAuth 2.0 Protected Resource Metadata（RFC 9728）

## ステータス

🟢 拡張機能 / 新しめの仕様 / 未着手

## 1. このトピックで確認したいこと

RFC 9728（OAuth 2.0 Protected Resource Metadata、2025 年公開、IETF Proposed Standard）は、
**Resource Server（保護リソース）が自身のメタデータを well-known URL で広告する**ための仕様。
これまで AS（Authorization Server）メタデータは RFC 8414 / OIDC Discovery で広告できたが、
**RS 側の広告手段は標準化されていなかった**。RFC 9728 は最新の MCP（Model Context Protocol）認可仕様などでも
参照されており、今後の相互運用性の基礎になる。

ターゲット:

- AS が複数あるとき、RS が「自分はどの AS が発行したトークンを受け入れるか」を Client に伝える
- RS が **どの scope、どの bearer methods、どの resource indicator** を期待するかを宣言する
- Client が動的に RS の認可要件を発見できる

本リポジトリは PoC ツールであり、サンプルとして RS 側（UserInfo / カスタム RS）も同居している。
RFC 9728 を実装すると「OP だけでなく RS 側のメタデータも広告できる OSS」として差別化できる。

## 2. 関連する仕様・基準

共通の仕様索引は `study-material/basic-op-requirement-traceability.md` を参照。本トピック固有のポイント:

- **RFC 9728 §2 メタデータ取得**:
  - Resource Server URL に対して `/.well-known/oauth-protected-resource` パスを生成（URL 構築規則は §3）。
  - Resource Server URL `https://api.example.com/foo` → `https://api.example.com/.well-known/oauth-protected-resource/foo`。
  - 認証なし HTTP GET。レスポンスは `application/json`。
- **RFC 9728 §3 メタデータフィールド**:
  - `resource`（必須）: この RS の resource indicator URL
  - `authorization_servers`: この RS がトークンを受け入れる AS の issuer URL 配列
  - `jwks_uri`: RS 自身が JWE 復号鍵を持つ場合（RFC 9068 JWT AT の暗号化）
  - `scopes_supported`: RS が認識する scope 一覧
  - `bearer_methods_supported`: `header` / `body` / `query`（OAuth 2.1 は `query` 非推奨）
  - `resource_signing_alg_values_supported`: RS が署名 JWT を返す場合の alg
  - `resource_name`: 人間可読の名前
  - `resource_documentation`: ドキュメント URL
  - `resource_policy_uri` / `resource_tos_uri`
- **RFC 9728 §5 署名付きメタデータ**:
  - `signed_metadata` フィールド（JWT 形式）で改ざん防止。任意。
- **WWW-Authenticate ヘッダーとの連携**:
  - RS は 401 応答に `WWW-Authenticate: Bearer resource_metadata="<URL>"` パラメータを付け、Client にメタデータ URL を案内できる（§5.1）。
- **Resource Indicators（RFC 8707）との関係**:
  - `resource` フィールドは Client が認可リクエストで送る `resource` パラメータと整合する想定。RFC 9728 は RFC 8707 の上位ピースとして機能する。

## 3. 参照資料

- RFC 9728 OAuth 2.0 Protected Resource Metadata: https://www.rfc-editor.org/rfc/rfc9728
  - §2 Metadata Format（fields）
  - §3 Obtaining Resource Server Metadata
  - §5 Signed Metadata（任意の改ざん防止）
  - §5.1 WWW-Authenticate Header との連携
- RFC 8414（AS Metadata、本仕様の RS 版の祖型）: https://www.rfc-editor.org/rfc/rfc8414
- RFC 8707（Resource Indicators）: https://www.rfc-editor.org/rfc/rfc8707
- 本リポジトリ内: `study-material/ext-resource-indicators-rfc8707.md`（resource パラメータの基礎）
- 本リポジトリ内: `study-material/oauth-authorization-server-metadata-rfc8414.md`（AS Metadata の整理）

## 4. 現在の実装確認

- Resource Server（UserInfo / カスタム RS）側のメタデータ広告は **未実装**。
- `packages/core/src/discovery.ts` の `buildProviderMetadata` は **AS Metadata 専用**（OIDC Discovery 1.0 + RFC 8414 互換）。RS 向け関数は無い。
- `packages/sample/src/oidc-provider/routes/` に `/.well-known/oauth-protected-resource` ルートは無い。
- `WWW-Authenticate` ヘッダー実装は done `p1-www-authenticate-header.md` で基本対応済み（`realm` / `error` / `error_description`）。`resource_metadata` パラメータは追加されていない。
- Resource Indicators（RFC 8707）の study-material はあるが未実装（拡張候補）。

## 5. 現在の実装との差分

満たしていること:

- RS の中核（UserInfo Endpoint、access_token 検証、`WWW-Authenticate` ヘッダー基本）は実装済み。
- AS Metadata は OIDC Discovery 経由で配信中。
- JWT access_token（done `p1-opaque-access-token.md` / 関連タスク群）の基盤あり。

不足／要確認:

- 🔴 **RS メタデータ広告エンドポイント無し**: `/.well-known/oauth-protected-resource` ルートと、`buildResourceMetadata(config)` 純関数を新設する必要がある。
- 🔴 **`resource_metadata` を `WWW-Authenticate` に追加する経路無し**: 401 応答に `resource_metadata="<URL>"` を付けるヘルパー拡張が必要（done p1-www-authenticate-header の延長）。
- 🟡 **`signed_metadata` の運用**: RS メタデータを JWT 署名するか平文か。FAPI 系では署名必須、一般用途では任意。本リポジトリでは「平文 + 任意で署名」を提供する設計が自然。
- 🟡 **AS と RS の同居問題**: 本リポジトリのサンプル構成は AS と RS（UserInfo）が同じ origin にいる。RFC 9728 は **AS と RS が分離している前提**。同居構成でも形式上の整合は取れるが、メタデータ広告経路が AS / RS で別 well-known パスになることに注意。
- 🟢 **RFC 8707 との接続**: `resource` パラメータを認可リクエストで受理する経路を作る場合（既存 study-material 参照）、RFC 9728 の `resource` フィールドと値整合が前提。
- 🟡 **MCP（Model Context Protocol）の RFC 9728 採用**: 最近 MCP 認可仕様が RFC 9728 を参照する形になっている。PoC ユーザーが MCP 検証目的で本ライブラリを採用する場合、RFC 9728 が必要になる可能性が高い。

セキュリティ観点:

- 🟡 **メタデータの完全性**: 平文 HTTPS で十分という仕様判断もあるが、改ざんリスクを完全排除するには `signed_metadata`。
- 🟢 **メタデータ自体に機密情報は含めない**: 仕様上 public information のみ。

相互運用性観点:

- 🟢 **MCP / FAPI 2.0 / 高度な API ゲートウェイ**: いずれも RFC 9728 を採用する流れ。実装すれば最新スタックでの相互運用が見える。

## 6. 改善・追加を検討する理由

- **`Speed` 軸（最新仕様最速）**: RFC 9728 は 2025 年 IETF Proposed Standard。AS Metadata（RFC 8414）の RS 版という位置づけで、今後の標準的セットになる見込み。**早期実装は差別化シグナル**。
- **MCP / AI エージェント認可**: Model Context Protocol が認可仕様で RFC 9728 を参照しており、AI エージェント周辺の PoC 検証で需要が出る可能性が高い。
- **実装コスト小**: AS Metadata builder の拡張パターンを RS 用に作るだけ。同居構成では既存 sample 構造を流用できる。
- **実装しない場合のリスク**: MCP / FAPI 2.0 / 最新 API ゲートウェイ系の PoC で「RS メタデータが出せない」と詰む。

## 7. 実装方針の候補

### 方針A（最小・builder のみ）

- `packages/core/src/protected-resource-metadata.ts`（新規）に `buildProtectedResourceMetadata(config)` を追加。
- 必須フィールド `resource`、推奨フィールド `authorization_servers`、`scopes_supported`、`bearer_methods_supported`、`resource_signing_alg_values_supported` を含む。
- ルート設置は CLI/sample 側で対応（`routes/protected-resource-metadata.ts`）。

### 方針B（中・WWW-Authenticate 統合）

- 方針A + `WWW-Authenticate` 構築ヘルパーに `resource_metadata` パラメータを追加。
- sample に「401 を返すと resource_metadata URL が WWW-Authenticate に含まれる」デモを追加。

### 方針C（フル・signed_metadata 対応）

- 方針B + `signed_metadata` を発行する関数（既存 JWT 署名インフラ流用）。

### 方針D（後送り）

- v0.x スコープ外。後続ロードマップで FAPI / MCP 系を本格化する段階で実装。

最終判断は人間。MCP / FAPI 系を狙うなら方針B。

## 8. タスク案

- [ ] `buildProtectedResourceMetadata(config)` の TDD テスト先行（必須/推奨フィールド、必須欠如エラー）
- [ ] `ProtectedResourceMetadataConfig` 型を `packages/core/src/protected-resource-metadata.ts` に新設
- [ ] sample に `routes/protected-resource-metadata.ts` を追加し、`/.well-known/oauth-protected-resource` で JSON を返す
- [ ] WWW-Authenticate 構築ヘルパー（done `p1-www-authenticate-header.md` の延長）に `resource_metadata` パラメータを追加
- [ ] sample UserInfo の 401 応答に `resource_metadata` を付けるオプションを追加
- [ ] `tasks/basic-op-requirement-traceability.md` に RFC 9728 の対応行を追加
- [ ] README に「RS メタデータ広告」セクションを追加し、AS Metadata との関係を整理
