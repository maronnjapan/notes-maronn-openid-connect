# [P3] UserInfo の `insufficient_scope` チャレンジに `scope` 属性を付与する（RFC 6750 §3.1）

## ステータス

🟢 Low / 未着手

## 背景

UserInfo エンドポイントがアクセストークンのスコープ不足で `insufficient_scope`（HTTP 403）を返すとき、
`WWW-Authenticate: Bearer` チャレンジに RFC 6750 §3.1 が SHOULD とする `scope` 属性が含まれていない。
OP は不足スコープ（この実装では `openid`）を確実に把握しているのに、標準の機械可読な場所で伝えていないため、
準拠 RP が「どのスコープを再要求すべきか」を自動判定できない。

Basic OP 認証の MUST ではないが、Fidelity と将来のスコープベース制御（step-up 等）の土台として価値がある。
検討詳細は `study-material/done/userinfo-insufficient-scope-www-authenticate-scope-attribute.md` を参照。

> 関連：`realm` 属性の付与・認証情報欠落時の bare `Bearer` は `tasks/done/p3-www-authenticate-realm.md` で対応済み。
> 本タスクは `insufficient_scope` の `scope` 属性に限定する。

## 対象ファイル

- `packages/core/src/userinfo.ts`（`UserInfoError` / `insufficient_scope` 送出箇所）
- `packages/core/src/userinfo.test.ts`
- `packages/cli/src/frameworks/*/templates.ts`（`WWW-Authenticate` 組み立て。web-standard / hono / express / fastify / nextjs）
- 各 sample の `conformance.test.ts` を生成する `packages/cli` 側コード

## 仕様参照

- RFC 6750 §3.1: `insufficient_scope` を返す場合、リソースサーバは必要なスコープを示す `scope` 属性を
  含める SHOULD。`scope` はスペース区切り・大小文字区別のスコープ値リスト。
- OpenID Connect Core 1.0 §5.3.3: UserInfo のエラー返却は RFC 6750 に従う。

## 現状の実装

```ts
// packages/core/src/userinfo.ts:387-393
if (!tokenInfo.scope.includes('openid')) {
  throw new UserInfoError(
    UserInfoErrorCode.InsufficientScope,
    'The openid scope is required'
  );
}
```

`UserInfoError` は必要スコープを保持するフィールドを持たない。

```ts
// packages/cli/src/frameworks/hono/templates.ts:1852-1857（他フレームワークも同様）
c.header(
  'WWW-Authenticate',
  `Bearer error="${error.error}", error_description="${error.errorDescription}"`,
);
```

`scope` 属性が付かない。

## 修正方針

- [ ] `UserInfoError` に `requiredScope?: string[]` を追加する
- [ ] `insufficient_scope` を送出する箇所で `requiredScope: ['openid']` を設定する
- [ ] 各フレームワークテンプレートの `WWW-Authenticate` 組み立てで、`insufficient_scope` かつ
  `requiredScope` があるとき ` scope="openid"` を追記する（複数値はスペース区切り）
- [ ] `scope` 値はチャレンジ文字列に埋め込むため、制御文字・引用符が混入しない安全な文字集合であることを保証する
  （`openid` は問題ないが将来値のため一般化時に注意）
- [ ] 生成コードは直接編集せず `packages/cli` テンプレートを修正する

実装イメージ（テンプレート側）:

```ts
let challenge = `Bearer error="${error.error}", error_description="${error.errorDescription}"`;
if (error.error === 'insufficient_scope' && error.requiredScope?.length) {
  challenge += `, scope="${error.requiredScope.join(' ')}"`;
}
c.header('WWW-Authenticate', challenge);
```

## テスト要件

- [ ] （core）`openid` を含まないアクセストークンで UserInfo を叩くと、送出される `UserInfoError` が
  `requiredScope: ['openid']` を持つ
- [ ] （conformance / 生成 OP）`insufficient_scope` の `WWW-Authenticate` ヘッダーが
  `scope="openid"` を含む
- [ ] `invalid_token`（401）のチャレンジには `scope` 属性が付かない（回帰固定）

## 完了条件

- `pnpm --filter @maronn-openid-connect/core test` がパスすること
- 生成 OP のチャレンジ挙動を変えるため、`packages/cli` テンプレートと各 sample の
  `conformance.test.ts` を更新し、`pnpm test` がパスすること
