# エラーレスポンスの一貫性と仕様準拠（全エンドポイント横断）

## 1. タイトル

Authorization Endpoint、Token Endpoint、UserInfo Endpoint、Revocation Endpoint、Introspection Endpoint の各エラーレスポンスが、OAuth 2.1 / OIDC Core 仕様に対して一貫した形式・ステータスコード・ヘッダーを返しているかの横断的確認。

## 2. このトピックで確認したいこと

エラーハンドリングに関する個別タスクが複数存在するが（Cache-Control、error_description のリダイレクト、www-authenticate 等）、エンドポイント全体を見渡す視点がなかった。

このファイルでは:
- 各エンドポイントのエラー形式を仕様に照らして整理する
- 既存タスクで追跡されている改善点をまとめて参照できるようにする
- まだ追跡されていない差分を特定する

## 3. 関連する仕様・基準

共通の仕様索引は `tasks/basic-op-requirement-traceability.md` の「3.3」を参照。エラーレスポンス固有の差分:

### 3.1 RFC 6749 §5.2 エラー応答の形式（Token Endpoint）

```
HTTP/1.1 400 Bad Request
Content-Type: application/json;charset=UTF-8
Cache-Control: no-store
Pragma: no-cache

{
  "error": "invalid_request",
  "error_description": "...",
  "error_uri": "..."
}
```

- `error`: REQUIRED。ASCII 文字（スペースなし）
- `error_description`: OPTIONAL。ASCII 可読文字列（`%x20-21 / %x23-5B / %x5D-7E`）
- `error_uri`: OPTIONAL

### 3.2 OIDC Core §3.1.2.6 認可エンドポイントのエラー応答

```
HTTP/1.1 302 Found
Location: https://client.example.org/cb?
  error=invalid_request
  &error_description=...
  &state=af0ifjsldkj
```

redirect_uri が無効・未登録の場合はリダイレクトせずに直接エラーを返す（RFC 6749 §4.1.2.1）。

### 3.3 RFC 6750 §3 Bearer Token エラー（UserInfo 等）

```
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer realm="example",
  error="invalid_token",
  error_description="The access token expired"
```

- `invalid_token` → 401
- `insufficient_scope` → 403（`WWW-Authenticate: Bearer error="insufficient_scope", scope="profile"`）

### 3.4 RFC 7009 §2.2.1 Revocation エラー

- 見つからないトークン → 200 OK（エラーにしない）
- 別クライアントのトークン → 400 `invalid_grant`
- クライアント未認証 → 401 `invalid_client`

### 3.5 RFC 7662 §2.3 Introspection エラー

- クライアント未認証 → 401 `invalid_client`
- `token` パラメータ欠如 → 400 `invalid_request`
- 有効でないトークン → 200 OK `{ "active": false }`（エラーにしない）

## 4. 参照資料

- RFC 6749 §5.2 — https://www.rfc-editor.org/rfc/rfc6749#section-5.2 （Token Endpoint エラー形式）
- RFC 6749 §4.1.2.1 — https://www.rfc-editor.org/rfc/rfc6749#section-4.1.2.1 （Authorization Endpoint エラー）
- OIDC Core 1.0 §3.1.2.6 — https://openid.net/specs/openid-connect-core-1_0.html#AuthError （OIDC 固有エラーコード）
- RFC 6750 §3 — https://www.rfc-editor.org/rfc/rfc6750#section-3 （Bearer Token エラーレスポンス）
- RFC 7009 §2.2 — https://www.rfc-editor.org/rfc/rfc7009#section-2.2 （Revocation エラー）
- RFC 7662 §2.3 — https://www.rfc-editor.org/rfc/rfc7662#section-2.3 （Introspection エラー）

関連する既存タスク（本ファイルでは詳細を繰り返さない）:
- 📌 `tasks/p0-token-endpoint-error-cache-control.md` — Token Endpoint エラー時の Cache-Control
- 📌 `tasks/p1-authorization-error-description-redirect.md` — 認可リダイレクトへの error_description
- 📌 `tasks/done/p1-www-authenticate-header.md` — UserInfo WWW-Authenticate ヘッダー（完了）
- 📌 `tasks/done/oidc-improvements-2026-05.md` T-010 — error_description サニタイズ（完了）
- ✅ `tasks/done/p3-www-authenticate-realm.md` — WWW-Authenticate の realm パラメータ（完了）

## 5. 現在の実装確認

### 5.1 Authorization Endpoint（`routes/authorize.ts`）

エラーが発生する場面と処理:

| ケース | 現在の挙動 |
|---|---|
| `redirect_uri` 不明・未登録 | `c.json({error, error_description}, 400)` ✅ |
| `client_id` 不明 | `c.json({error, error_description}, 400)` ✅ |
| `response_type` 不正 | `c.redirect(redirectUrl)` ✅ |
| `prompt=none` で未認証 | `c.redirect(errorRedirect)` ✅（state 付き）|
| エラーリダイレクトの `error_description` | ❌ `buildErrorRedirect` が `error_description` を含めない |

```typescript
// routes/authorize.ts 内 buildErrorRedirect（現状）
function buildErrorRedirect(redirectUri: string, error: string, state?: string): string {
  const url = new URL(redirectUri);
  url.searchParams.set('error', error);
  if (state) url.searchParams.set('state', state);
  // error_description が含まれない ← p1 タスク
  return url.toString();
}
```

### 5.2 Token Endpoint（`routes/token.ts`）

| ケース | 現在の挙動 |
|---|---|
| 認証失敗（401）| `{ error, error_description }` + `WWW-Authenticate: Basic realm="..."` ✅ |
| 不正リクエスト（400）| `{ error, error_description }` ✅ |
| Cache-Control（エラー時）| ❌ 成功時のみ `Cache-Control: no-store`。エラー時は未設定 |
| Content-Type 検証 | ❌ → 📌 `tasks/p1-token-endpoint-content-type.md` |
| `error_description` サニタイズ | ✅（`sanitizeErrorDescription` で完了） |

### 5.3 UserInfo Endpoint（`routes/userinfo.ts`）

| ケース | 現在の挙動 |
|---|---|
| 無効なトークン（401）| `WWW-Authenticate: Bearer error="invalid_token"` ✅ |
| スコープ不足（403）| `WWW-Authenticate: Bearer error="insufficient_scope"` ✅ |
| 複数トークン送信（400）| `WWW-Authenticate: Bearer error="invalid_request"` ✅ |
| Cache-Control | ❌ → 📌 `tasks/p0-userinfo-cache-control.md` |

### 5.4 Revocation Endpoint（`packages/core/src/revocation.ts` + `routes/revocation.ts`）

| ケース | 現在の挙動 |
|---|---|
| トークン未発見 | `void`（200 OK を呼び出し側が返す）✅ |
| 別クライアントのトークン | `invalid_grant` / 400 ✅（RFC 7009 §2.2.1 準拠） |
| クライアント未認証 | `invalid_client` / 401 + `WWW-Authenticate: Basic` ✅ |
| `token` パラメータ欠如 | `invalid_request` / 400 ✅ |

### 5.5 Introspection Endpoint（`packages/core/src/introspection.ts`）

| ケース | 現在の挙動 |
|---|---|
| クライアント未認証 | `invalid_client` / 401 + `WWW-Authenticate: Basic` ✅ |
| `token` パラメータ欠如 | `invalid_request` / 400 ✅ |
| 有効でないトークン | `{ active: false }` / 200 ✅（RFC 7662 §2.2 準拠） |

### 5.6 `sanitizeErrorDescription`（`packages/core/src/error-utils.ts`）

すべてのエラークラス（`AuthorizationError`, `TokenError`, `UserInfoError`, `RevocationError`, `IntrospectionError`）のコンストラクタで `sanitizeErrorDescription` を呼び、RFC 6749 §5.2 の安全文字集合に制限 ✅

## 6. 現在の実装との差分

### 6.1 未解決の差分

| 差分 | 対応タスク |
|---|---|
| 認可エラーリダイレクトに `error_description` なし | 📌 `tasks/p1-authorization-error-description-redirect.md` |
| Token Endpoint エラー時に `Cache-Control: no-store` なし | 📌 `tasks/p0-token-endpoint-error-cache-control.md` |
| UserInfo エラー時に `Cache-Control: no-store` なし | 📌 `tasks/p0-userinfo-cache-control.md` |
| Token Endpoint の Content-Type 検証なし | 📌 `tasks/p1-token-endpoint-content-type.md` |

### 6.2 既存タスクでカバーされていない差分

#### `insufficient_scope` エラー時の `scope` パラメータ

RFC 6750 §3 では、`insufficient_scope` を返す場合に `WWW-Authenticate` ヘッダーに `scope` パラメータを含めることを推奨している:

```
WWW-Authenticate: Bearer error="insufficient_scope",
  error_description="...",
  scope="profile email"
```

現在の実装（`routes/userinfo.ts`）の `insufficient_scope` 応答には `scope` パラメータが含まれていない。クライアントが不足スコープを自動再要求する際にこの情報が必要になる。

#### Discovery Endpoint のエラー応答

`routes/discovery.ts` は基本的に常に 200 OK を返すが、内部エラー時のエラーハンドリングが未確認。OP が Discovery に失敗すると全フロー不能になるため、適切な 500 応答が返ることを確認する必要がある。

#### 重複パラメータ（Duplicate Parameters）

OAuth 2.1 では同一パラメータが複数回送信された場合にリクエストを拒否することを要求する（§2.3 等）。既存タスク `tasks/p1-duplicate-parameter-rejection.md` で追跡済みだが、エラー応答の形式も明確にしておく必要がある（JSON の `invalid_request` または認可リダイレクト）。

## 7. 改善・追加を検討する理由

- **Basic OP 認定**: Conformance Suite はエラー応答のフォーマットを検証する。`error_description` がリダイレクトに含まれないことや `Cache-Control` の欠如は FAIL につながる可能性がある。
- **仕様 Fidelity**: エラーの一貫性は「仕様準拠を信頼性シグナルとして維持する」という本プロジェクトの差別化軸に直結する。各エンドポイントのエラー形式が仕様通りでないと、クライアント側の自動エラーハンドリングが壊れる。
- **セキュリティ**: `Cache-Control: no-store` は認証情報（エラー内容含む）が中間プロキシにキャッシュされないことを保証する。エラー応答に設定しないことはセキュリティ上のリスク。

## 8. 実装方針の候補

### 方針A（既存タスクの順次消化）

既存タスク（p0/p1 優先度）を優先順位通りに実装する。本ファイルは全体マップとして機能し、各タスク完了後に状態を更新する。

### 方針B（エラーレスポンスの共通ミドルウェア化）

`routes/token.ts`・`routes/userinfo.ts`・`routes/revocation.ts`・`routes/introspection.ts` に共通して `Cache-Control: no-store` を設定するミドルウェア（Hono の `app.use()` or ルートレベルミドルウェア）を導入する。これにより各ルートファイルで個別に設定する必要がなくなり、設定漏れのリスクを下げられる。

### 方針C（テストによる一括確認）

エンドポイントごとのエラーレスポンステストを追加し、現状の差分を一括で把握してから修正する。「テストが先」の TDD 原則と整合。

## 9. タスク案

- [ ] `insufficient_scope` エラー応答の `WWW-Authenticate` ヘッダーに `scope` パラメータを追加する（RFC 6750 §3 準拠）
- [ ] 既存タスクの依存関係を確認: p0-token-endpoint-error-cache-control → p0-userinfo-cache-control → p1-authorization-error-description-redirect の順で実施
- [ ] エラーレスポンスへの `Cache-Control: no-store` を共通ミドルウェアで設定する案を検討し、方針B か方針A（個別設定）かを決定する
- [ ] Discovery Endpoint の内部エラーハンドリング（500 応答）をテストで確認する
- [ ] `p1-duplicate-parameter-rejection` のエラー応答形式（JSON vs リダイレクト）を仕様に照らして明確化する
- [ ] 全エンドポイントのエラー形式が RFC 6749 §5.2 の文字制約を満たすことを統合テストで確認する（`sanitizeErrorDescription` の網羅確認）
