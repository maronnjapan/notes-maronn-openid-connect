# Token Revocation (RFC 7009) 実装

## 目的
クライアントが自発的にアクセストークン / リフレッシュトークンを失効させられる
Revocation エンドポイントを実装する。

## 仕様参照
- RFC 7009 (OAuth 2.0 Token Revocation) Section 2.1 / 2.2 / 2.3
- OAuth 2.1 Section 4.3.1 (refresh token rotation)
- OAuth 2.1 Section 4.1.2 (code reuse → sibling token revoke)
- 調査メモ: `.claude/docs/research/token-revocation-introspection.md`

## エンドポイント仕様
- パス: `POST /revoke`
- リクエスト Content-Type: `application/x-www-form-urlencoded`
- パラメータ:
  - `token` (REQUIRED): 失効対象トークン
  - `token_type_hint` (OPTIONAL): 不明な値は無視し両方検索
- クライアント認証: `client_secret_basic` / `client_secret_post`（confidential 必須）
- 成功レスポンス: `200 OK` ボディ空
  - **token が見つからない場合も 200 OK** を返す（サイドチャネル攻撃防止）
- エラー:
  - クライアント認証失敗 → `401` (`invalid_client`) + `WWW-Authenticate: Basic`
  - 必須パラメータ欠落 → `400` (`invalid_request`)
  - `unsupported_token_type` は返さない方針（hint 不明値は無視）
- レスポンスヘッダ: `Cache-Control: no-store`, `Pragma: no-cache`

## リフレッシュトークンの扱い（重要・調査結果反映）
RFC 7009 Section 2.1 の規定:

| 失効対象 | 関連トークンの扱い | 規範レベル |
|---|---|---|
| Refresh Token | そのリフレッシュトークンから発行された **すべてのアクセストークン** を失効すべき | **SHOULD** |
| Access Token | そのアクセストークンの取得に使われたリフレッシュトークンも失効してよい | **MAY** |

### 本プロジェクトで採用する方針
- **Refresh Token を revoke した場合**: 同じ `grantId` に紐づく
  - リフレッシュトークン → 当該トークンを失効
  - アクセストークン → grantId 経由で全て失効（既存 `revokeByGrantId` を再利用）
- **Access Token を revoke した場合**:
  - 当該アクセストークン1件のみ失効（デフォルト）
  - リフレッシュトークンは保持（短命 AT の自然失効を待つ前提）
  - 「セッション全体終了」を望むクライアントは別途リフレッシュトークンの revoke を呼ぶ
- **JWT アクセストークン**: Opaque と同じく grantId 経由で失効。JWT 自体はステートレスだが、
  リソースサーバ側で本ライブラリの Introspection を呼ぶ運用とすることで即時失効を担保する。
  （JWT-only のリソースサーバ向けに JTI denylist を提供する案は将来拡張とし、本タスクでは扱わない）

## 設計上の対象ファイル
### packages/core (新規)
- `src/revocation.ts`
  - `RevocationRequestParams` / `RevocationError`
  - `RevocationTokenResolver` インタフェース（access/refresh 両対応）
  - `handleRevocationRequest(context)`: 検索順序とポリシーをここで決定
- `src/revocation.test.ts` 新規

### packages/core (改修)
- `src/index.ts` に export 追加
- `src/discovery.ts`
  - `revocationEndpoint?` / `revocationEndpointAuthMethodsSupported?` フィールド追加

### packages/sample / packages/cli
- `routes/revocation.ts` を生成 / 配置
- store に `revokeAccessToken(token)` / `revokeRefreshToken(token)` 等を追加
- discovery レスポンスに `revocation_endpoint` を追加

## テスト方針 (TDD)
- describe('handleRevocationRequest')
  - describe('Validation')
    - should reject when token parameter is missing
    - should reject when client authentication fails
  - describe('Access token revocation')
    - should revoke the access token when found
    - should NOT revoke associated refresh tokens by default
    - should still return 200 when access token does not exist
  - describe('Refresh token revocation')
    - should revoke the refresh token
    - should revoke all access tokens sharing the same grantId
    - should still return 200 when refresh token does not exist
  - describe('Token type hint behavior')
    - should look up access tokens first when hint=access_token
    - should fall back to refresh token search when hint=access_token but not found
    - should ignore unknown hint values without raising unsupported_token_type
  - describe('Cross-client safety')
    - should reject with invalid_grant when token belongs to a different client
      → RFC 7009 §2.1: "verifies whether the token was issued to the client making
        the revocation request. If this validation fails, the request is refused
        and the client is informed of the error" に従い **invalid_grant 400** を返す。

## 完了条件
- 上記テストケースが全部通る
- discovery メタデータに `revocation_endpoint` が現れる
- sample アプリの `/revoke` が curl でテスト可能
- リフレッシュトークン失効時に grantId 経由のアクセストークンも消える
