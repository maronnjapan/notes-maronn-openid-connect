# [P2] UserInfo署名付きレスポンス（JWT形式）

## 背景

現状の `handleUserInfoRequest()` はJSONオブジェクトを返すのみ。

OIDC Core Section 5.3.2 では、クライアントのメタデータ設定に応じて
UserInfoレスポンスを署名済みJWT形式で返すことを規定している。

Basic OPのconformanceテストでは、署名付きUserInfoレスポンスを
検証するテストケースが含まれる場合がある。

## 準拠仕様

- OIDC Core 1.0 Section 5.3.2 (Successful UserInfo Response)
  > If the UserInfo Response is signed and/or encrypted, then the Claims are returned in a JWT
  > and the `content-type` MUST be `application/jwt`.

## 実装内容

### `packages/core/src/userinfo.ts` への追加

既存の `handleUserInfoRequest()` はそのまま維持し、
JWT形式レスポンスを生成する新しい関数を追加する。

```ts
export interface UserInfoJwtOptions {
  issuer: string;
  audience: string;  // client_id
  privateKey: CryptoKey;
  keyId?: string;
  expiresIn?: number;  // デフォルト: 3600 (1時間)
}

/**
 * UserInfoレスポンスをJWT形式で生成する
 * OIDC Core 1.0 Section 5.3.2
 *
 * @param userInfoResponse handleUserInfoRequest() の戻り値
 * @param options JWT生成オプション
 * @returns 署名済みJWT文字列
 */
export async function generateUserInfoJwt(
  userInfoResponse: UserInfoResponse,
  options: UserInfoJwtOptions
): Promise<string>
```

内部的には `generateIdToken` の署名ロジック（crypto-utils）を再利用する。
JWTのペイロードはUserInfoレスポンスのクレームをそのまま使い、
`iss` / `aud` / `iat` / `exp` を追加する。

### エクスポート

`packages/core/src/index.ts` から `generateUserInfoJwt` と `UserInfoJwtOptions` をエクスポートする。

## テスト

`packages/core/src/userinfo.test.ts` に追記する（TDD）。

追加するテストケース:
- should generate a valid JWT
- should include iss claim
- should include aud claim matching the client_id
- should include sub claim from UserInfoResponse
- should include iat and exp claims
- should include additional claims from UserInfoResponse

## 完了条件

- [ ] テストが全て通る
- [ ] `generateUserInfoJwt` が core の index.ts からエクスポートされている
- [ ] サンプルのuserinfoエンドポイントで `Accept: application/jwt` ヘッダー時にJWT形式で返すよう対応（任意）

## 備考

クライアントがJWT形式を要求するかどうかの判定（`userinfo_signed_response_alg` など）は
クライアントメタデータの範囲であり、coreはJWT生成機能のみを提供する。
どちらの形式を返すかは利用者が判断する。
