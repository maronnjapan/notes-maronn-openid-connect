# 設計ドラフト: Token Introspection / Revocation / Opaque Access Token

date: 2026-04-30 (Codex 協議反映 2026-05-01)

## 0. Codex協議結果サマリ（実装後コードレビューで修正された項目を含む）
| 項目 | 結論 |
|---|---|
| Q1: 他クライアント発行トークンの revoke | **invalid_grant 400** ← 設計協議では 200 no-op としたが、実装後の Codex コードレビューで RFC 7009 §2.1「verifies whether the token was issued to the client making the revocation request. If this validation fails, the request is refused and the client is informed」に従う方が正しいと判断し変更 |
| Q2: active=false で何を返すか | **`{ active: false }` のみ**（採用） |
| Q3: JWT denylist を本タスクに含めるか | **含めない**。「JWT は RS が introspection を呼ぶ運用でのみ即時失効可能。自己検証 only RS では revoke 不可」を明記 |
| Q4: 不明な `token_type_hint` | **無視して両方検索**（採用） |
| Q5: Opaque サイズ | **デフォルト 32 byte**（採用、可変長 API は維持） |
| Introspection の他クライアント扱い | **`active=true` を返す** ← コードレビューで「RFC 7662 の主体は protected resource であり OAuth client と RS を同一視するな」との指摘に従い変更 |
| `AccessTokenInfo`/`RefreshTokenInfo` の拡張 | **iat / aud / iss / jti を保持できる形に拡張**（採用） |
| store 層の扱い | **変更が必要であることを明記**（採用） |
| route テスト | sample side は手動テストとし将来タスク化（他テストで挙動は十分担保） |

## 1. ゴール
1. `POST /introspect` (RFC 7662) を core / sample / cli に実装
2. `POST /revoke` (RFC 7009) を core / sample / cli に実装
3. アクセストークンを JWT / Opaque で切替可能にする

## 2. ファイル構成（追加）
```
packages/core/src/
  introspection.ts
  introspection.test.ts
  revocation.ts
  revocation.test.ts
  access-token-issuer.ts
  access-token-issuer.test.ts
packages/sample/src/oidc-provider/routes/
  introspection.ts
  revocation.ts
packages/cli/src/frameworks/hono/templates.ts (出力テンプレに追加)
```

## 3. 型の拡張（RFC 7662 active=true レスポンス対応）

### 3.1 AccessTokenInfo の拡張
```ts
// 既存:
//   sub, scope, clientId, expiresAt, grantId?
// 拡張:
export interface AccessTokenInfo {
  sub: string;
  scope: string[];
  clientId: string;
  expiresAt: number;
  grantId?: string;
  // --- introspection / 仕様準拠のため追加 ---
  iat?: number;         // 発行時刻
  audience?: string[];  // OIDC AT の aud
  issuer?: string;      // 発行 OP の iss
  jti?: string;         // (任意) JWT の jti / Opaque は token 値とは独立
}
```

### 3.2 RefreshTokenInfo の拡張
```ts
export interface RefreshTokenInfo {
  subject: string;
  clientId: string;
  scope: string[];
  expiresAt: number;
  used: boolean;
  grantId: string;
  // --- introspection 用 ---
  iat?: number;
  issuer?: string;
}
```

これら拡張フィールドはすべて optional で、未設定の場合は introspection レスポンスから当該クレームを単に省く（RFC 7662 SHOULD なので問題なし）。
=> **後方互換性は保たれる**（既存 setter は引き続き動く）。

## 4. core 層の責務分離

### 4.1 introspection.ts
```ts
export interface IntrospectionAccessTokenResolver {
  findAccessToken(token: string): Promise<AccessTokenInfo | null>;
}

export interface IntrospectionRefreshTokenResolver {
  resolve(token: string): Promise<RefreshTokenInfo | null>;
}

export interface IntrospectionRequestContext {
  params: { token?: string; token_type_hint?: string };
  authenticatedClientId: string;
  issuer: string;
  accessTokenResolver: IntrospectionAccessTokenResolver;
  refreshTokenResolver?: IntrospectionRefreshTokenResolver;
}

export type IntrospectionResponse =
  | { active: false }
  | {
      active: true;
      scope?: string;
      client_id?: string;
      token_type?: 'Bearer' | 'refresh_token';
      exp?: number;
      iat?: number;
      sub?: string;
      aud?: string | string[];
      iss?: string;
      jti?: string;
    };

export class IntrospectionError extends Error { /* invalid_request / invalid_client + statusCode */ }

export async function handleIntrospectionRequest(ctx: IntrospectionRequestContext): Promise<IntrospectionResponse>;
```

判定ロジック:
1. `token` 欠落 → `IntrospectionError(invalid_request, 400)`
2. hint = `refresh_token` なら refresh → access の順、それ以外（含む不明値）は access → refresh の順
3. 見つかった `info`:
   - `expiresAt <= now` → `active=false`
   - `info.clientId !== authenticatedClientId` → **`active=false`**（修正）
   - refresh の `used === true` → `active=false`
   - 上記以外 → `active=true` + 各クレーム
4. どちらも見つからなければ `active=false`

### 4.2 revocation.ts
```ts
export interface RevocationTokenResolvers {
  findAccessToken(token: string): Promise<AccessTokenInfo | null>;
  revokeAccessToken(token: string): Promise<void>;
  findRefreshToken?(token: string): Promise<RefreshTokenInfo | null>;
  revokeRefreshToken?(token: string): Promise<void>;
  /** RFC 7009 SHOULD: refresh 失効時に同 grantId の access も全部失効 */
  revokeAccessTokensByGrantId?(grantId: string): Promise<void>;
}

export interface RevocationRequestContext {
  params: { token?: string; token_type_hint?: string };
  authenticatedClientId: string;
  resolvers: RevocationTokenResolvers;
}

export class RevocationError extends Error { /* invalid_request / invalid_client */ }

export async function handleRevocationRequest(ctx: RevocationRequestContext): Promise<void>;
```

挙動:
- `token` 欠落 → `RevocationError(invalid_request, 400)`
- hint と検索順序は introspection と同じ
- 見つかったトークンが **別クライアント所有なら何もせず return**（=200, no-op）
- access が見つかったら `revokeAccessToken(token)` のみ
- refresh が見つかったら `revokeRefreshToken(token)` + grantId 経由で access 全削除

### 4.3 access-token-issuer.ts
```ts
export type AccessTokenFormat = 'jwt' | 'opaque';

export interface AccessTokenIssuanceContext {
  payload: AccessTokenPayload;
  privateKey?: CryptoKey;  // jwt issuer のみ必須
  keyId?: string;
}

export interface AccessTokenIssuer {
  issue(ctx: AccessTokenIssuanceContext): Promise<string>;
}

export function createJwtAccessTokenIssuer(): AccessTokenIssuer;
export function createOpaqueAccessTokenIssuer(byteLength?: number): AccessTokenIssuer;
```

`generateTokenResponse(opts)` に `accessTokenIssuer?: AccessTokenIssuer` を追加。
未指定時は内部で JWT issuer を生成（後方互換）。

#### JWT revoke の限界（明示的に書く）
- アクセストークンが JWT のとき、リソースサーバが
  - **introspection を使って毎回検証**する運用なら即時失効可能
  - **JWT を自己検証のみで使う**運用では本ライブラリの revoke は効かない
- 本ライブラリは denylist (jti) を提供しないため、自己検証 only な RS で即時失効を必要とする場合は **Opaque を選択**するのが推奨

## 5. discovery.ts への追加フィールド
| camelCase | snake_case | 出典 |
|---|---|---|
| `introspectionEndpoint` | `introspection_endpoint` | RFC 8414 |
| `introspectionEndpointAuthMethodsSupported` | `introspection_endpoint_auth_methods_supported` | RFC 8414 |
| `revocationEndpoint` | `revocation_endpoint` | RFC 8414 |
| `revocationEndpointAuthMethodsSupported` | `revocation_endpoint_auth_methods_supported` | RFC 8414 |

OIDC Discovery 1.0 自身は規定しないが、RFC 8414 と主要 IdP の慣行に揃える。

## 6. sample / cli への配線
- `routes/introspection.ts`：client 認証 → core を呼ぶ → JSON 返却 / `Cache-Control: no-store` / `Pragma: no-cache`
- `routes/revocation.ts`：client 認証 → core を呼ぶ → 200 空ボディ + 同上ヘッダ
- `app.ts` / `apply.ts` で `/introspect` `/revoke` をマウント
- `config.ts` に `accessTokenFormat: 'jwt' | 'opaque'` 追加
- `routes/token.ts` で issuer を切替えて生成。`accessTokenStore.set(...)` には `iat / audience / issuer` を含めて保存
- `routes/discovery.ts` に新フィールド出力を追加

### store 層の変更（修正後）
- AccessTokenStore / RefreshTokenStore の **保存項目に iat / audience / issuer を追加**
- store API のシグネチャは無変更（`AccessTokenInfo` の任意フィールド追加なので破壊的変更なし）
- KV 実装も同様（任意プロパティ追加のため互換）
- public client は revocation/introspection の対象外。本実装では **confidential client のみサポート** と README/コメントで明記

## 7. 後方互換性
- `generateTokenResponse` は `accessTokenIssuer` 未指定で JWT 発行を継続
- `AccessTokenInfo` / `RefreshTokenInfo` の拡張フィールドはすべて optional
- Discovery の追加フィールドはすべて optional / additive
- 利用者が独自 store / resolver を書いている場合: 追加メソッドはすべて optional なので動作はするが
  Introspection / Revocation を有効にするには resolver の追加実装が必要
  → README とコメントで明示する

## 8. テスト戦略
TDD: Red → Green → Refactor。

### core ユニットテスト
- introspection.test.ts: validation / 各 active=false 条件 / hint 順序 / token_type
- revocation.test.ts: validation / hint 順序 / 別クライアントの no-op / grantId 経由失効
- access-token-issuer.test.ts: JWT/Opaque それぞれの形式・性質

### sample route テスト（新規追加）
- handler の単体テストは無いが、HTTP 仕様（200/400/401, Cache-Control / Pragma / WWW-Authenticate）が崩れないよう、最低限 **Hono の app に対してリクエストを投げる integration test** を追加する想定（時間が足りなければ手動 curl で代替し、TODO に残す）。

## 9. 実装順序
1. AccessTokenInfo / RefreshTokenInfo 型拡張（既存テストに影響しないことを確認）
2. access-token-issuer の TDD 実装
3. introspection の TDD 実装
4. revocation の TDD 実装
5. token-response.ts へ issuer 注入の対応
6. discovery.ts へフィールド追加
7. sample/cli の routes/store/config 配線
8. 動作確認（既存テスト全通過）
