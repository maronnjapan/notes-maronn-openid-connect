# [P0] UserInfo 署名付きレスポンスの動線整備

## 背景

OIDC Core 1.0 Section 5.3.2：
> If the UserInfo Response is signed and/or encrypted, then the Claims are returned in a JWT and the content-type MUST be `application/jwt`. (...) The signing algorithm to use is determined by the value of `userinfo_signed_response_alg` Client Metadata.

Basic OP 認定の `OP-UserInfo-RS256` は **REQUIRED** に分類されている。

`generateUserInfoJwt()` は core にすでに存在するが、サンプル UserInfo ルートが常に JSON を返しているため認定テストを通らない。Codex の指摘により、当初 P1 だったところを **P0** に昇格。

## 現状の問題

1. `packages/sample/src/oidc-provider/routes/userinfo.ts` は `handleUserInfoRequest()` の戻り値をそのまま `c.json()` で返す。
2. クライアントメタデータ `userinfo_signed_response_alg` を保存する場所がない（`RegisteredClient` 型に該当フィールドなし）。
3. discovery レスポンスに `userinfo_signing_alg_values_supported` が含まれていない。

## 準拠仕様

- OIDC Core 1.0 Section 5.3.2 (Successful UserInfo Response)
- OIDC Discovery 1.0 Section 3 (`userinfo_signing_alg_values_supported`)
- OIDC Registration 1.0 Section 2 (`userinfo_signed_response_alg`)

## 実装方針

### 判定ルール（クライアントメタデータ主、Accept は補助）

Codex との協議結果（2026-04-30）：
- **主条件**：登録された `userinfo_signed_response_alg` がある場合は署名付き JWT を返す
- **補助**：`userinfo_signed_response_alg` 未設定で `Accept: application/jwt` が来たら開発用に JWT を返す（オプション）

認定テストは前者で通る。

### `packages/sample/src/oidc-provider/config.ts`

`RegisteredClient` 型に追加：

```ts
export type RegisteredClient = ClientInfo & TokenClientInfo & {
  offlineAccessAllowed?: boolean;
  /** UserInfo レスポンスを署名付き JWT で返す場合のアルゴリズム（例: 'RS256'） */
  userinfoSignedResponseAlg?: 'RS256';
};
```

`defaultRegisteredClients` に既存の example クライアントへ `userinfoSignedResponseAlg: 'RS256'` を任意で追加してデモ可能にする。

### `packages/sample/src/oidc-provider/routes/userinfo.ts`

ハンドラを書き換え：

1. `handleUserInfoRequest()` で claims を取得
2. `accessTokenStore` から `clientId` を取り、`clientResolver.findClient(clientId)` で `userinfoSignedResponseAlg` を確認
3. 設定がある場合：
   - `generateUserInfoJwt({ userInfoResponse, issuer, audience: clientId, privateKey, keyId })` を呼ぶ
   - `Content-Type: application/jwt` ヘッダを返す
   - JWT を text として返却
4. 設定がない場合：従来通り JSON

`UserInfo` 専用署名鍵が分離されている場合は `c.get('userinfoPrivateKey')` を優先し、なければ `c.get('privateKey')` にフォールバック。

### `packages/sample/src/oidc-provider/routes/discovery.ts`

`buildProviderMetadata()` 結果に `userinfo_signing_alg_values_supported: ['RS256']` を追加。

`packages/core/src/discovery.ts` の `ProviderMetadataConfig` に optional field `userinfoSigningAlgValuesSupported?: string[]` を追加し、ある場合のみメタデータに含める。

### `packages/cli/src/generator.ts`

cli が生成するコードに同様の対応を反映。

## テストケース

### `packages/core/src/discovery.test.ts`
- `should include userinfo_signing_alg_values_supported when configured`
- `should omit userinfo_signing_alg_values_supported when not configured`

### `packages/core/src/userinfo.test.ts`
既存の `generateUserInfoJwt` テストはそのまま。サンプル統合テストを追加：

### `packages/sample/src/__tests__/userinfo-signed-response.test.ts`（新規 or 既存に追記）
- `should return JSON when client has no userinfo_signed_response_alg`
- `should return application/jwt when client has userinfo_signed_response_alg=RS256`
- `should set content-type to application/jwt`
- `should include sub, iss, aud, iat, exp claims in JWT`
- `should sign with the configured private key`

## 完了条件

- [ ] クライアントメタデータでレスポンス形式が切り替わる
- [ ] `Content-Type: application/jwt` が正しく返る
- [ ] discovery に `userinfo_signing_alg_values_supported` が含まれる
- [ ] テストが全て通る
- [ ] cli generator にも反映

## 備考

- `Accept: application/jwt` 判定の追加は optional。デモ用途なら入れる。
- 暗号化対応（`userinfo_encrypted_response_alg`）は Basic OP 範囲外。今回は対応しない。
