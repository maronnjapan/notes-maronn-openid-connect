# Token Introspection (RFC 7662) 実装

## 目的
リソースサーバが受け取ったアクセストークン (またはリフレッシュトークン) が現在 `active` か、
誰宛に発行されたか、scope などの属性をクエリできる Introspection エンドポイントを実装する。
JWT 形式・Opaque 形式の両方に対応する。

## 仕様参照
- RFC 7662 (OAuth 2.0 Token Introspection) Section 2.1 / 2.2 / 2.3
- OAuth 2.1 Section 3.2 (Cache-Control / 認証要件)
- 調査メモ: `.claude/docs/research/token-revocation-introspection.md`

## エンドポイント仕様
- パス: `POST /introspect`
- リクエスト Content-Type: `application/x-www-form-urlencoded`
- パラメータ:
  - `token` (REQUIRED): イントロスペクション対象トークン文字列
  - `token_type_hint` (OPTIONAL): `access_token` | `refresh_token` 以外は無視して両方検索
- クライアント認証: `client_secret_basic` または `client_secret_post`（confidential client）
- レスポンス: `application/json`
- 成功時 `200 OK`:
  - 必須: `active: true|false`
  - active=true のとき推奨: `scope`, `client_id`, `token_type`, `exp`, `iat`, `sub`, `aud`, `iss`, `jti?`
- エラー: 認証失敗は `401 Unauthorized` (+ `WWW-Authenticate: Basic`) または `400 Bad Request`
- レスポンスヘッダ: `Cache-Control: no-store`, `Pragma: no-cache`

## active=false 判定基準
- トークンが見つからない（未発行 / 既に削除 / revoke 済）
- `expiresAt <= now`
- リフレッシュトークンの `used` フラグが立っている（rotation 後）

> NOTE: RFC 7662 §2.1 は introspection caller を主に protected resource として
> 想定しており、トークン所有クライアントと caller の一致は要件ではない。
> よって本実装では別クライアント所有のトークンでも `active=true` を返す。
> アクセス制御は confidential client 認証で担保する。

## 設計上の対象ファイル
### packages/core (新規)
- `src/introspection.ts`
  - `IntrospectionRequestParams` / `IntrospectionResponse` 型
  - `IntrospectionError` (エラー型 + statusCode)
  - `handleIntrospectionRequest(context)` 本体
  - `AccessTokenIntrospectionResolver`, `RefreshTokenIntrospectionResolver` インタフェース
- `src/introspection.test.ts` 新規

### packages/core (改修)
- `src/index.ts` に新規 export を追加
- `src/discovery.ts`
  - `introspectionEndpoint?` / `introspectionEndpointAuthMethodsSupported?` フィールド追加
  - 出力に `introspection_endpoint` / `introspection_endpoint_auth_methods_supported` を含める

### packages/sample / packages/cli
- `routes/introspection.ts` を生成 / 配置
- discovery レスポンスに `introspection_endpoint` を追加
- KV / In-memory ストアに `introspectAccessToken`, `introspectRefreshToken` 等のメソッドを追加

## テスト方針 (TDD)
- describe('handleIntrospectionRequest')
  - describe('Validation')
    - should reject when token parameter is missing
    - should reject when client authentication fails
  - describe('Active access token')
    - should return active=true with scope/client_id/sub/exp/iat/aud/iss/token_type
    - should return active=false when access token expired
    - should return active=false when access token revoked
    - should return active=false when access token does not exist
    - should ignore unknown token_type_hint and still find the token
  - describe('Active refresh token')
    - should return active=true for valid refresh token
    - should return active=false when refresh token already used (rotated)
    - should return active=false when refresh token expired
  - describe('Token type hint preference')
    - should look up access tokens first when hint=access_token
    - should look up refresh tokens first when hint=refresh_token
    - should return active=false only after both lookups fail
  - describe('Response format')
    - should always include active field
    - should include token_type=Bearer for access tokens
    - should include token_type=refresh_token for refresh tokens

## 完了条件
- 上記テストケースが全部通る
- discovery メタデータに `introspection_endpoint` が現れる
- sample アプリの `/introspect` が curl でテスト可能
