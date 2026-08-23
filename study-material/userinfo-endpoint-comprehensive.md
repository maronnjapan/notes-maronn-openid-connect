# UserInfo Endpoint 包括的レビュー（OIDC Core §5.3）

## 1. タイトル

OIDC Core 1.0 Section 5.3 に基づく UserInfo Endpoint の全要件確認と、現在の実装との差分整理。個別タスク（Cache-Control、Content-Type、署名応答等）の親トピックとして機能し、全体像を俯瞰する。

## 2. このトピックで確認したいこと

UserInfo Endpoint は Basic OP 必須エンドポイントであり、Conformance Suite でも複数のテストが割り当てられている（`tasks/basic-op-requirement-traceability.md` §6.3 参照）。個別の改善タスクが複数存在するが、UserInfo 全体を見渡すファイルがなかった。

このファイルでは:
- OIDC Core §5.3 が要求する全仕様を整理する
- 現在の実装がどこまで満たしているかを確認する
- 既存タスクが扱っていない差分を特定する

## 3. 関連する仕様・基準

共通の仕様索引は `tasks/basic-op-requirement-traceability.md` の「3.3」を参照。以下は UserInfo 固有の差分と重要ポイントのみ記載する。

### 3.1 OIDC Core §5.3 の要件

**アクセス方法:**
- `GET` または `POST` でアクセス可能（§5.3.1）
- Bearer Token は `Authorization: Bearer <token>` ヘッダー（REQUIRED）または POST ボディの `access_token` フォームパラメータ（OPTIONAL）
- URL クエリパラメータへのトークン埋め込みは OAuth 2.1 §5.2.1 で明示的に禁止（本リポジトリでは意図的に非対応）

**レスポンス:**
- `Content-Type: application/json`（JSON 形式のとき）
- `Content-Type: application/jwt`（署名済み JWT 形式のとき）
- `sub` クレームは REQUIRED
- ID Token の `sub` と UserInfo の `sub` は一致しなければならない（§5.3.2）
- `Cache-Control: no-store` の設定が推奨される（プライバシー保護）

**署名付き応答（§5.3.2）:**
- クライアントの `userinfo_signed_response_alg` が設定されている場合、OP は署名済み JWT を返す
- JWT のペイロードには UserInfo クレームに加え `iss`・`aud`・`iat`・`exp` を含める

**エラー応答（§5.3.3）:**
- `invalid_token`: 401（Bearer トークン無効・期限切れ）
- `insufficient_scope`: 403（スコープ不足）
- エラー時は `WWW-Authenticate: Bearer error="<code>"` ヘッダーを設定する（RFC 6750 §3）

### 3.2 RFC 6750（Bearer Token Usage）との関係

- Bearer Token の転送方法: Authorization ヘッダー > リクエストボディ（クエリパラメータは OAuth 2.1 で禁止）
- 複数のトークン転送方法の同時使用は禁止（RFC 6750 §2）
- エラー応答の `WWW-Authenticate` ヘッダー形式: `Bearer realm="..." error="..." error_description="..."`

### 3.3 OIDC Core §5.4 スコープとクレームのマッピング

| スコープ | クレーム |
|---|---|
| `openid` | `sub`（REQUIRED） |
| `profile` | `name`, `family_name`, `given_name`, `middle_name`, `nickname`, `preferred_username`, `profile`, `picture`, `website`, `gender`, `birthdate`, `zoneinfo`, `locale`, `updated_at` |
| `email` | `email`, `email_verified` |
| `address` | `address` |
| `phone` | `phone_number`, `phone_number_verified` |

スコープに含まれないクレームは UserInfo に含めない（但し `claims` パラメータで個別要求した場合を除く）。

## 4. 参照資料

- OIDC Core 1.0 §5.3 — https://openid.net/specs/openid-connect-core-1_0.html#UserInfo （UserInfo Endpoint の全要件）
- OIDC Core 1.0 §5.4 — https://openid.net/specs/openid-connect-core-1_0.html#ScopeClaims （スコープ→クレームのマッピング）
- OIDC Core 1.0 §5.5 — https://openid.net/specs/openid-connect-core-1_0.html#ClaimsParameter （`claims` リクエストパラメータ）
- RFC 6750（Bearer Token Usage）— https://www.rfc-editor.org/rfc/rfc6750 （Bearer トークンの使用方法とエラー応答）

関連する既存タスク（本ファイルでは詳細を繰り返さない）:
- 📌 `tasks/p0-userinfo-cache-control.md` — `Cache-Control: no-store` の付与
- ✅ `tasks/done/p2-userinfo-post-content-type-normalize.md` — POST 時の Content-Type 正規化（完了）
- 📌 `tasks/done/p2-userinfo-signed-response.md` — 署名済み JWT 応答（完了）
- 📌 `tasks/done/p0-userinfo-signed-response-wiring.md` — sample への署名応答配線（完了）
- 📌 `tasks/done/p2-userinfo-post-form-body.md` — POST フォームボディ対応（完了）
- 📌 `tasks/done/p0-claims-id-token-support.md` — `claims` パラメータ対応（完了）
- 📌 `tasks/done/p1-www-authenticate-header.md` — WWW-Authenticate ヘッダー（完了）

## 5. 現在の実装確認

### 5.1 コアロジック（`packages/core/src/userinfo.ts`）

- `handleUserInfoRequest`: アクセストークン検証 → openid スコープ確認 → ユーザークレーム取得 → スコープフィルタリング → claims パラメータ適用
- `filterClaimsByScope`: `SCOPE_CLAIMS_MAP`（profile/email/address/phone）に基づくフィルタリング。`sub` は常に含まれる
- `generateUserInfoJwt`: 署名済み JWT 生成（`iss`, `aud`, `iat`, `exp` を自動付与）
- アクセストークン検証: 存在確認・有効期限のみ。スコープ取得・clientId 取得あり
- エラー: `UserInfoError`（`invalid_token` = 401, `insufficient_scope` = 403）

### 5.2 sample ルート（`packages/sample/src/oidc-provider/routes/userinfo.ts`）

- `Authorization: Bearer` ヘッダーからのトークン抽出: ✅（case-sensitive の `Bearer ` プレフィックス確認）
- POST フォームボディからの `access_token` 抽出: ✅（media type の大小文字・パラメータを正規化）
- 複数トークン送信時の `invalid_request` エラー: ✅
- URL クエリパラメータ不対応: ✅（意図的に非実装）
- 署名済み JWT 応答（`userinfo_signed_response_alg: 'RS256'`）: ✅（クライアントメタデータに基づく条件分岐）
- `WWW-Authenticate` ヘッダーのエラー応答: ✅（`Bearer error="..." error_description="..."` 形式）
- **`Cache-Control: no-store` ヘッダー**: ❌ 未設定 → 📌 `tasks/p0-userinfo-cache-control.md`
- CORS: ❌ 未設定 → 📌 `study-material/cors-cross-origin-support.md`

### 5.3 Bearer Token 抽出の実装詳細

```typescript
// routes/userinfo.ts 内
const authHeader = c.req.header('Authorization') ?? '';
const headerToken = authHeader.startsWith('Bearer ')  // ← case-sensitive
  ? authHeader.slice(7)
  : '';
```

RFC 7235 §2.1 は認証スキームを case-insensitive と規定している。`client-auth.ts` では `matchAuthScheme` を使って case-insensitive 比較しているが、UserInfo ルートは `startsWith('Bearer ')` で **case-sensitive** な比較をしている。

## 6. 現在の実装との差分

### 6.1 満たしていること

- GET / POST の両対応 ✅
- `Authorization: Bearer` ヘッダーからのトークン抽出 ✅
- POST フォームボディからのトークン抽出 ✅（案件 p2 完了）
- URL クエリパラメータ禁止 ✅（意図的非対応）
- 複数トークン送信禁止 ✅
- `sub` クレームを常に含む ✅
- スコープフィルタリング（profile/email/address/phone）✅
- `claims` パラメータ対応 ✅
- 署名済み JWT 応答 ✅
- `WWW-Authenticate` エラーヘッダー ✅

### 6.2 不足・確認が必要なこと

- 🔴 **`Cache-Control: no-store` 未設定** → 📌 `tasks/p0-userinfo-cache-control.md`
- 🟡 **Bearer スキームの case-insensitive 対応**: `routes/userinfo.ts` は `startsWith('Bearer ')` で大文字小文字を区別している。`BEARER token` のような RFC 準拠クライアントは拒否される可能性。`client-auth.ts` の `matchAuthScheme` と同じアプローチに統一が望ましい
- ✅ **POST Content-Type 正規化**: 大小文字差と `;charset=UTF-8` 等のパラメータを正規化して受理する → `tasks/done/p2-userinfo-post-content-type-normalize.md`
- 🟡 **CORS 未設定**: ブラウザベースクライアントからのアクセスに CORS ヘッダーが必要 → 📌 `study-material/cors-cross-origin-support.md`
- 🟡 **`sub` の ID Token との一致検証**: OP は常に同じ `sub` を返すよう実装されているが、テストで明示的に保証されているか確認が必要（`UserClaimsResolver.findUserClaims` が正しい subject で呼ばれることのテスト）

### 6.3 UserInfo JWT の `exp` 設定

`generateUserInfoJwt` は `expiresIn` オプション（デフォルト 3600 秒）で有効期限を計算するが、この値がアクセストークンの `expiresAt` と連動していない。アクセストークンが失効した後も UserInfo JWT が有効な状態になりうる。この差分は仕様違反ではないが、クライアントが JWT をキャッシュする場合にトークン失効が反映されない。

## 7. 改善・追加を検討する理由

- **Basic OP 認定**: Conformance Suite の `OP-UserInfo-Header`、`OP-UserInfo-Body`、`OP-UserInfo-RS256` テストは既に通過できる状態にある。`Cache-Control` の欠如は直接の FAIL 原因にはならないが、プライバシー要件として仕様が推奨している。
- **セキュリティ**: UserInfo レスポンスにはユーザーの個人情報が含まれるため、`Cache-Control: no-store` がないと中間プロキシや CDN にキャッシュされるリスクがある。PoC 用途でも事故を防ぐために早期対応が望ましい（p0 優先度の根拠）。
- **相互運用性**: Bearer スキームの case-insensitive 対応は RFC 7235 の要件であり、一部の標準的なクライアントライブラリが大文字を使う場合に影響する。

## 8. 実装方針の候補

- **方針A（p0 タスク優先）**: `Cache-Control: no-store` → `Pragma: no-cache` を先に付与する。既存 Token Endpoint の実装と同様（`routes/token.ts` で設定済み）。
- **方針B（Bearer case-insensitive）**: `routes/userinfo.ts` の Bearer 抽出を `client-auth.ts` の `matchAuthScheme` 相当に置き換える。Breaking change なし・テスト修正は小さい。
- **方針C（UserInfo JWT の exp 連動）**: `generateUserInfoJwt` に `accessTokenExpiresAt` を渡し、`exp = min(now + expiresIn, accessTokenExpiresAt)` とする。後方互換を維持しながら追加オプションとして導入できる。

## 9. タスク案

- [ ] `routes/userinfo.ts` の Bearer 抽出を case-insensitive に修正する（RFC 7235 §2.1 準拠）
- [ ] `Cache-Control: no-store` を `routes/userinfo.ts` のレスポンスに追加する（📌 `tasks/p0-userinfo-cache-control.md` の実装）
- [ ] `UserClaimsResolver.findUserClaims` が正しい subject で呼ばれることをテストで明示的に保証する
- [ ] UserInfo JWT の `exp` をアクセストークン有効期限と連動させるオプションを追加するか判断する
- [ ] CLI 生成テンプレートの UserInfo ルートに上記修正を反映する
- [ ] CORS 設定を追加する（📌 `study-material/cors-cross-origin-support.md` のタスク）
