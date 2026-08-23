# [P2] OAuth 2.1 §1.5 で削除されたグラント／レガシー response_type の明示的拒否テスト追加

## ステータス

🟡 Minor / 未着手

## 背景

OAuth 2.1（draft-ietf-oauth-v2-1）§1.5 では `password` グラントと Implicit Grant（`response_type=token` / `response_type=id_token token`）が削除されている。本ライブラリの `validateTokenRequest` は `authorization_code` / `refresh_token` 以外を `unsupported_grant_type` で拒否するホワイトリスト方式で実装されており、`validateAuthorizationRequest` は `response_type=code` 以外を `unsupported_response_type` で拒否する。

挙動自体は仕様準拠だが、**個別の削除グラント・レガシー response_type が拒否されることのテストが薄い**:

- `token-request.test.ts` は `client_credentials` を渡したケースのみ
- `password` / `urn:ietf:params:oauth:grant-type:jwt-bearer` / `urn:ietf:params:oauth:grant-type:saml2-bearer` / `implicit` は未テスト
- `authorization-request.test.ts` 側もレガシー `response_type` 値（`token`、`id_token`、`code token`、`id_token token`、`code id_token` 等）の拒否を網羅していない

リファクタでホワイトリスト方式が崩れると静かに脆弱化するため、Fidelity 軸の証跡としてテストを追加する。詳細な背景・仕様参照は `study-material/oauth21-removed-grants-explicit-rejection.md` を参照。

## 対象ファイル

- `packages/core/src/token-request.test.ts`
- `packages/core/src/authorization-request.test.ts`
- （任意）`packages/cli/src/frameworks/hono/templates.ts` の Discovery config コメント

## 仕様参照

- OAuth 2.1 §1.5: Differences from OAuth 2.0（`password` / Implicit Grant の削除）
- OAuth 2.1 §3.2.3.1 / RFC 6749 §5.2: `unsupported_grant_type` エラー定義
- RFC 6749 §3.1.1 / OIDC Core 1.0 §3.1.2.6: `unsupported_response_type` エラー定義
- OAuth 2.0 Security BCP §2.4: ROPC 非推奨

## 現状の実装

```ts
// packages/core/src/token-request.ts:324-329
if (params.grant_type !== 'authorization_code' && params.grant_type !== 'refresh_token') {
  throw new TokenError(
    TokenErrorCode.UnsupportedGrantType,
    `Unsupported grant_type: ${params.grant_type}`
  );
}
```

```ts
// packages/core/src/authorization-request.ts（要旨）
// response_type が 'code' でない場合は AuthorizationError(unsupported_response_type) を返す
```

`token-request.test.ts:142` で `client_credentials` のテストは存在。`password` / 拡張 grant URN は未テスト。

## 修正方針

- [ ] `token-request.test.ts` に「OAuth 2.1 §1.5 削除グラント」カテゴリを `describe` ブロックとして追加し、以下を含むテーブル駆動テストを書く:
  - `password`（OAuth 2.1 で削除）
  - `client_credentials`（OAuth 2.1 では削除されていないが本ライブラリの非対応）
  - `urn:ietf:params:oauth:grant-type:jwt-bearer`（RFC 7523、本ライブラリ非対応）
  - `urn:ietf:params:oauth:grant-type:saml2-bearer`（RFC 7522、本ライブラリ非対応）
  - `urn:ietf:params:oauth:grant-type:device_code`（RFC 8628、本ライブラリ非対応）
  - `urn:ietf:params:oauth:grant-type:token-exchange`（RFC 8693、本ライブラリ非対応）
  - 空文字列（`grant_type=`）と空白のみの値
  - すべてが `TokenErrorCode.UnsupportedGrantType` で拒否され、HTTP 400 になることを検証
- [ ] `authorization-request.test.ts` に「OAuth 2.1 §1.5 削除レガシー response_type」カテゴリを追加し、以下を含むテーブル駆動テストを書く:
  - `token`（Implicit Grant）
  - `id_token`（OIDC Hybrid 系の一部、Basic OP 非対応）
  - `code token`（Hybrid）
  - `id_token token`（Hybrid）
  - `code id_token`（Hybrid）
  - `code id_token token`（Hybrid）
  - 順序違いの組み合わせ（例: `token code`）
  - すべてが `AuthorizationErrorCode.UnsupportedResponseType` で拒否されることを検証
- [ ] テストケース名は「should reject {value} with unsupported_grant_type」「should reject {value} with unsupported_response_type」の形式で、OIDC 仕様参照（OAuth 2.1 §1.5 / RFC 6749 §5.2）をコメントに記載
- [ ] CLI テンプレートの `grantTypesSupported` 設定箇所に「実装の真実だけを広告する（OAuth 2.1 削除グラントは追加しない）」コメントを追加（任意）

### テスト記述例

```ts
describe('validateTokenRequest', () => {
  describe('OAuth 2.1 Section 1.5 Removed / Unsupported grant_types', () => {
    // OAuth 2.1 §1.5: Resource Owner Password Credentials Grant is REMOVED
    it.each([
      'password',
      'client_credentials',
      'urn:ietf:params:oauth:grant-type:jwt-bearer',
      'urn:ietf:params:oauth:grant-type:saml2-bearer',
      'urn:ietf:params:oauth:grant-type:device_code',
      'urn:ietf:params:oauth:grant-type:token-exchange',
    ])('should reject grant_type=%s with unsupported_grant_type', async (grantType) => {
      const context = makeBaseContext({ grant_type: grantType });
      await expect(validateTokenRequest(context)).rejects.toMatchObject({
        error: TokenErrorCode.UnsupportedGrantType,
      });
    });
  });
});
```

## テスト要件

- [ ] `password` グラントが `unsupported_grant_type` で拒否されること
- [ ] 各 URN 形式拡張グラント（jwt-bearer / saml2-bearer / device_code / token-exchange）が `unsupported_grant_type` で拒否されること
- [ ] `client_credentials` グラントが引き続き `unsupported_grant_type` で拒否されること（既存テスト維持）
- [ ] レガシー `response_type` 値（`token` / `id_token` / `code token` / `id_token token` / `code id_token` / `code id_token token` / 順序違い）が `unsupported_response_type` で拒否されること
- [ ] 空文字列 / 空白のみの `grant_type` / `response_type` 値が拒否されること
- [ ] エラー HTTP ステータスコードが 400 であること（Token Endpoint）／redirect でのエラー応答経路が機能していること（Authorization Endpoint、`state` 透過）

## 完了条件

- `pnpm --filter @maronn-openid-connect/core test` がパスすること
- 追加したテーブル駆動テストがすべて pass
- `study-material/oauth21-removed-grants-explicit-rejection.md` の §8 タスク案にあるテスト追加項目にチェックを入れる
- `basic-op-requirement-traceability.md` の OAuth Behaviors 行に「§1.5 削除グラント・レガシー response_type 拒否のテスト証跡」状態を追加
