# [P2] Introspection のリフレッシュトークンレスポンスから非標準 `token_type: "refresh_token"` を除去する

## ステータス

🟠 High / 未着手

## 背景

Token Introspection（RFC 7662）のレスポンスで、リフレッシュトークンをイントロスペクトすると
`token_type: "refresh_token"` を返している。RFC 7662 §2.2 は `token_type` を
「RFC 6749 §7.1 で定義されるトークンの型」と規定しており、そこに `refresh_token` という値は存在しない
（§7.1 の型は `Bearer` などアクセストークンの提示型）。RFC 7662 のトップレベルメンバーは `active` 以外すべて
OPTIONAL なので、リフレッシュトークンでは `token_type` を**省略**するのが準拠かつ素直。

非標準値を返すと、`token_type` を RFC 6749 §7.1 の型として解釈する RS / Gateway で未知の値となり
相互運用性を損なう。検討詳細は `study-material/done/introspection-refresh-token-type-value-rfc7662.md` を参照。

## 対象ファイル

- `packages/core/src/introspection.ts`
  - `IntrospectionResponse` 型（`token_type?: 'Bearer' | 'refresh_token'`）
  - `buildRefreshTokenResponse`
- `packages/core/src/introspection.test.ts`
- `packages/cli` 内の `conformance.test.ts` 生成コード（リフレッシュトークンのイントロスペクション期待値）

## 仕様参照

- RFC 7662 §2.2「Introspection Response」: `token_type` は RFC 6749 §7.1 で定義される型
- RFC 6749 §7.1「Access Token Types」: `refresh_token` は定義されていない
- RFC 6750: `token_type=Bearer`（アクセストークン用）

## 現状の実装

```ts
// packages/core/src/introspection.ts
export type IntrospectionResponse =
  | { active: false }
  | { active: true; ...; token_type?: 'Bearer' | 'refresh_token'; ... };

function buildRefreshTokenResponse(info: RefreshTokenInfo): IntrospectionResponse {
  const res = {
    active: true,
    scope: info.scope.join(' '),
    client_id: info.clientId,
    token_type: 'refresh_token', // ← RFC 6749 §7.1 に存在しない値
    sub: info.subject,
    exp: info.expiresAt,
  };
  ...
}
```

## 修正方針

- [ ] `buildRefreshTokenResponse` から `token_type` フィールドを削除する（リフレッシュトークンでは省略）
- [ ] `IntrospectionResponse` の `token_type` を `'Bearer'` のみに型を狭める
- [ ] アクセストークン側の `token_type: 'Bearer'`（RFC 6750 準拠）は変更しない
- [ ] `packages/cli` の conformance.test.ts 生成コードを更新し、リフレッシュトークンの期待値から `token_type` を除去

## テスト要件

- [ ] リフレッシュトークンのイントロスペクションレスポンスに `token_type` が**含まれない**こと
- [ ] アクセストークンのイントロスペクションレスポンスは従来どおり `token_type: 'Bearer'` を含むこと
- [ ] `active`, `scope`, `client_id`, `sub`, `exp`, `iat`, `iss` 等の他メンバーは従来どおり返ること
- [ ] 生成 sample の `conformance.test.ts`（生成元を更新）に上記を反映すること

## 完了条件

- `pnpm --filter @maronn-openid-connect/core test` がパスすること
- 生成された `samples/*` の `conformance.test.ts` が更新後の挙動でパスすること
