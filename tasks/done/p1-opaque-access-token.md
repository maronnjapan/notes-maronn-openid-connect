# Opaque Access Token 対応

## 目的
現在 JWT 形式で発行しているアクセストークンを、Opaque（不透明）形式でも発行できるようにする。
両方式を `accessTokenFormat: 'jwt' | 'opaque'` のような設定で切替可能にする。

## 背景
- JWT は自己完結だが即時失効が困難
- Opaque はストア参照が必須だが Introspection / Revocation との相性が良い
- 主要 IdP (Auth0, Keycloak) はどちらか/両方をサポート
- 本ライブラリは PoC 検証ツールであり「両方試せる」ことが価値

## 仕様参照
- OAuth 2.1 Section 5 (Bearer Token Usage)
- RFC 6750 Section 2.1 (Bearer ヘッダ)
- RFC 7662 (Introspection は Opaque トークン前提で書かれている)
- 調査メモ: `.claude/docs/research/token-revocation-introspection.md`

## 設計

### コア層: AccessTokenIssuer 抽象化
```ts
export type AccessTokenFormat = 'jwt' | 'opaque';

export interface AccessTokenIssuer {
  /**
   * トークン文字列を発行する。
   * - jwt: 既存の generateAccessToken を内部で呼ぶ
   * - opaque: ランダムバイト列を base64url で文字列化して返す
   * 副作用としてストアへ保存するかは呼び出し側の責務。
   * issuer が返すのはあくまで「文字列」のみ。
   */
  issue(payload: AccessTokenPayload, signingKey?: { privateKey: CryptoKey; keyId?: string }): Promise<string>;
}

export function createJwtAccessTokenIssuer(): AccessTokenIssuer;
export function createOpaqueAccessTokenIssuer(byteLength?: number): AccessTokenIssuer;
```

### token-response.ts の改修
- `TokenResponseOptions` に `accessTokenIssuer?: AccessTokenIssuer` を追加（デフォルトは JWT）
- 既存呼び出しは無変更で動くようにする（後方互換）

### at_hash の扱い
OIDC Core 1.0 Section 3.1.3.6 の `at_hash` は **アクセストークン文字列の SHA-256 左半分の base64url** であり、
JWT 形式かどうかは関係ない。Opaque トークンでもそのまま計算してよい。

### サンプル/CLI 側のストア
- アクセストークンは現状 `accessTokenStore.set(token, AccessTokenInfo)` で管理されているので、
  Opaque に切り替えても格納/参照ロジックは無変更で済む（Introspection / Revocation と整合する）。
- JWT 方式でもストアに登録する現在のサンプルは維持し、JWT/Opaque 双方で
  「Introspection / Revocation で即時失効可能」とする。

## 設計上の対象ファイル
### packages/core (新規)
- `src/access-token-issuer.ts`
  - `AccessTokenFormat`, `AccessTokenIssuer`, `createJwtAccessTokenIssuer`, `createOpaqueAccessTokenIssuer`
- `src/access-token-issuer.test.ts`

### packages/core (改修)
- `src/token-response.ts`
  - `accessTokenIssuer?: AccessTokenIssuer` を受け取り、未指定なら JWT issuer をデフォルト使用
  - `at_hash` 計算は発行された文字列に対して実施
- `src/index.ts` に export 追加
- `src/discovery.ts`
  - 任意で `op_tokens_supported` のような独自フィールドは出さない（標準外のため）

### packages/sample / packages/cli
- `config.ts` に `accessTokenFormat: 'jwt' | 'opaque'` を追加
- `routes/token.ts` で issuer を切替えて生成
- README/コメント更新

## テスト方針 (TDD)
- describe('createJwtAccessTokenIssuer')
  - should return a JWT token with three dot-separated segments
  - should sign with the supplied private key
- describe('createOpaqueAccessTokenIssuer')
  - should return a non-JWT, non-empty random string
  - should produce unique tokens across calls
  - should respect the configured byteLength (default 32 bytes → 43 char base64url)
  - should not embed payload claims in the token string
- describe('generateTokenResponse with opaque issuer')
  - should return access_token in opaque form
  - should still compute at_hash from the opaque string
  - should still return token_type=Bearer
  - should still set refresh_token when offline_access scope requested

## 完了条件
- 上記テストケースが全部通る
- sample で `accessTokenFormat: 'opaque'` を指定するとアクセストークンが Opaque で発行される
- Opaque でも UserInfo / Introspection / Revocation が動く
- 既存 JWT 経路の動作・テストに退行がない
