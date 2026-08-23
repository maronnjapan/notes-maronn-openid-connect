# [P0] 認可コード再利用時のトークン失効

## 背景

OAuth 2.1 / RFC 6749 Section 4.1.2 / OIDC Core 1.0:
> If an authorization code is used more than once, the authorization server MUST deny the request and SHOULD revoke (when possible) all tokens previously issued based on that authorization code.

Basic OP 認定の `OP-OAuth-2nd-Revokes` テストで検証される。

## 現状の問題

`packages/core/src/token-request.ts` は `authCode.used === true` を検知すると `invalid_grant` を返す（再利用検知は OK）。しかし「最初の正規交換で発行済みのアクセストークン / リフレッシュトークン」を失効する仕組みが存在せず、攻撃者が盗んだトークンを使い続けられる。

`packages/sample/src/oidc-provider/store.ts` の `consume()` は `used = true` フラグを立てるだけで、関連トークンには触れない。

## 準拠仕様

- OAuth 2.1 Section 4.1.2 (Authorization Response)
- RFC 6749 Section 10.5
- OIDC Core 1.0 Section 3.1.3.2 (Token Request Validation)

## 実装方針（grantId 方式）

Codex との協議結果（2026-04-30）：トークン側に発行元コードを「逆参照」させる代わりに `grantId` を共有する方式を採用する。

### `packages/core/src/authorization-code.ts`

`AuthorizationCodeData` に `grantId` フィールドを追加する。

```ts
export interface AuthorizationCodeData {
  code: string;
  grantId: string;          // ← NEW: 認可付与の一意識別子
  // ... 既存フィールド ...
}
```

`createAuthorizationCode()` 内で `generateRandomString(32)` により発番する。
利用者は `authCodeData.grantId` をストアに保存する責務を負う。

### `packages/core/src/token-request.ts`

`AuthorizationCodeInfo` にも `grantId: string` を追加する（必須）。
`validateAuthorizationCodeRequest` が返す `ValidatedAuthorizationCodeRequest` に `grantId` を含める。

再利用検知時のフックを `AuthorizationCodeResolver` に追加する：

```ts
export interface AuthorizationCodeResolver {
  findAuthorizationCode(code: string): Promise<AuthorizationCodeInfo | null>;
  revokeAuthorizationCode(code: string): Promise<void>;
  /** code 再利用検知時に同 grantId を持つトークンをすべて失効する */
  revokeTokensByGrantId?(grantId: string): Promise<void>;
}
```

`if (authCode.used)` ブロックで `revokeTokensByGrantId?.(authCode.grantId)` を await し、その後 `invalid_grant` をスローする。`revokeTokensByGrantId` 未提供時は警告ログのみ（互換性維持）。

### `packages/core/src/token-response.ts`

`generateTokenResponse()` に `grantId` を渡せるよう `TokenResponseOptions` を拡張するが、トークン本体（JWT payload）には含めない（外部に漏らさない）。
利用者は `grantId` をアクセストークンとリフレッシュトークンのストア側 metadata に保存する。

### `packages/sample/src/oidc-provider/store.ts`

- `AccessTokenInfo` `RefreshTokenInfo` に `grantId: string` を追加
- `AccessTokenStore` `RefreshTokenStore` に `revokeByGrantId(grantId)` メソッドを追加
  （`Map.values()` を走査して該当エントリを削除/used=true 化）
- `AuthorizationCodeStore` に `getByGrantId` は不要

### `packages/sample/src/oidc-provider/resolvers.ts`

`authorizationCodeResolver.revokeTokensByGrantId` を実装：

```ts
async revokeTokensByGrantId(grantId: string): Promise<void> {
  await accessTokenStore.revokeByGrantId(grantId);
  await refreshTokenStore.revokeByGrantId(grantId);
}
```

### `packages/cli/src/generator.ts`

cli 経由で生成されるコードにも上記の grantId フィールドを必ず含めるようテンプレートを修正。

## テストケース

`packages/core/src/token-request.test.ts` に追記（TDD）：

- `should call revokeTokensByGrantId when authorization code is reused`
- `should still throw invalid_grant after revoking tokens`
- `should work without revokeTokensByGrantId resolver method (backward compat)`

`packages/core/src/authorization-code.test.ts` に追記：
- `should generate unique grantId per authorization code`

`packages/sample/src/op/kv-store.test.ts` に追記：
- `should revoke all tokens with matching grantId`

統合テスト（必要なら）：
- `should reject reused code AND prevent issued access token from being used at userinfo`

## 完了条件

- [ ] `core` のテストがすべて通る
- [ ] `revokeTokensByGrantId` が `AuthorizationCodeResolver` の optional メソッドとして公開されている
- [ ] sample 側で再利用検知から失効までが繋がっている
- [ ] cli 生成コードにも grantId 関連処理が含まれる

## 備考

- core 側はインターフェースとフック呼び出しまでが責務。実際の失効処理はストレージ依存のため利用者責務。
- grantId は外部公開しない。トークンに claim として埋めず、ストアの metadata 列にのみ持つ。
