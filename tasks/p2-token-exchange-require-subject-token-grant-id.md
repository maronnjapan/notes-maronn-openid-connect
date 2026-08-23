# [P2] Token Exchange: `grantId` を持たない subject_token の交換を拒否し、失効保証の範囲を明文化する

## ステータス

🟠 High / 未着手

## 背景

`packages/experimental/src/token-exchange` は、交換で発行するトークンに
**subject_token の `grantId` を継承させる**ことで、grant 単位の失効
（認可コード再利用検知 / リフレッシュトークン family 失効 / 同意撤回 /
RT の RFC 7009 失効）が交換トークンにも届くようにしている。

しかしこの仕組みには 2 つの問題がある。

### (1) `grantId` 無しの subject_token から、失効不能なトークンが黙って生まれる

`AccessTokenInfo.grantId` は optional（`packages/core/src/userinfo.ts:57-63`）であり、
`TokenExchangeGrant.grantId` も optional
（`packages/experimental/src/token-exchange/token-exchange-request.ts:105-106`）。

`resolveSubjectToken`（同 :235-254）は `grantId` の有無を **一切検査しない**。
したがって `grantId` を返さない `AccessTokenResolver`（本リポジトリは resolver の差し替えを
明示的に推奨している）を使うと、

- 交換は **成功する**
- 発行されたトークンは `grantId: undefined` で保存される
- **すべての `revokeByGrantId` から漏れる**＝ **どの失効経路でも殺せないトークンになる**

しかも失敗の兆候が一切出ない。これは
`study-material/done/authorization-code-reuse-cascade-store-semantics.md` が扱っている
「store 実装の契約違反が黙って失効を無効化する」フットガンと同型である。

### (2) 失効に関する保証の範囲がどこにも書かれていない

モジュール冒頭（`token-exchange-request.ts:10-17`）は、
「scope は部分集合・audience は許可リスト内・寿命は subject_token の残存期間以下・
`sub` は変更不可」という **発行時の権限の狭さ**を保証として宣言している。

一方、**失効については何も宣言していない**。実際には次の非対称がある。

| 起点 | 交換トークンに届くか |
|---|---|
| 認可コード再利用検知 / RT family 失効 / 同意撤回 / RT の RFC 7009 失効 | **届く**（grantId 経由） |
| **subject_token（アクセストークン）自身の RFC 7009 失効** | **届かない** |

後者は `revokeGrantAccessTokens`（`packages/core/src/revocation.ts:213-219`）が
`resolved.tokenType !== 'refresh_token'` で早期 return するためで、
RFC 7009 §2.1（access token 失効時の連鎖は MAY）としては正しい実装である。
だが「アクセストークンが漏れたので失効させた」という自然な運用が、
交換が絡むと成立しないことは **利用者に伝わっていない**。

### 本タスクのスコープ

- **(1) を塞ぐ**: `grantId` 無しの subject_token の交換を拒否する。
- **(2) を明文化する**: 届く／届かないを JSDoc と生成コードのコメントに書く。

**スコープ外**: subject_token 失効の派生伝播そのものの実装
（派生関係の記録が必要で、ストア契約の変更を伴う）。
これは `study-material/done/token-exchange-derived-token-revocation-coupling.md` の
方針C として検討段階のまま残す。

## 対象ファイル

- `packages/experimental/src/token-exchange/token-exchange-request.ts`
- `packages/experimental/src/token-exchange/token-exchange-request.test.ts`
- `packages/cli/src/frameworks/hono/templates.ts`（生成コードの token-exchange 分岐コメント）
- `packages/cli/src/__tests__/hono-generator.test.ts`
- `samples/*/src/oidc-provider/routes/token.ts`（生成物。直接編集しない）
- `samples/*/conformance.test.ts`（生成物。生成元は `packages/cli`）

> `packages/experimental/src` の変更に対して changeset を手で書かないこと。
> main への push で CI が patch の changeset を自動生成する（`RELEASE.md` 参照）。

## 仕様参照

- **RFC 8693 §5 Security Considerations**
  <https://datatracker.ietf.org/doc/html/rfc8693>
  > Any time one principal is delegated the rights of another principal, the potential for abuse
  > is a concern. The use of the `scope` claim (in addition to other typical constraints such as
  > a limited token lifetime) is suggested to mitigate potential for such abuse ...

  → RFC 8693 は濫用の緩和策として `scope` と寿命しか挙げておらず、
  **失効の伝播は規定していない**。したがって本件は「仕様違反の是正」ではなく
  **OP が決めるべき設計判断の確定**である。

- **RFC 7009 §2.1 Revocation Request**
  <https://datatracker.ietf.org/doc/html/rfc7009>
  - refresh token 失効時、同一 grant のアクセストークンも失効させる **SHOULD**
  - access token 失効時、関連 refresh token を失効させても **よい（MAY）**
  - 「あるアクセストークンから派生した別のアクセストークン」という関係は **規定が無い**

- **RFC 9700 §4.13 / §4.14**
  <https://datatracker.ietf.org/doc/html/rfc9700>
  - 侵害された資格情報から**派生したもの**を連鎖的に無効化する原則
  - → 「失効連動できないトークンを発行しない」という本タスクの方向は、この原則に沿う

- **RFC 8693 §1.1 Delegation vs. Impersonation Semantics**
  - impersonation では受領側から「交換の産物である」ことが見えなくてよい
    （"it is not a requirement"）。本タスクは受領側の可視性ではなく
    **AS 内部の失効連動**を扱うため、この規定とは衝突しない。

## 現状の実装

### 交換の入口（`grantId` を検査しない）

`packages/experimental/src/token-exchange/token-exchange-request.ts:235-254`:

```ts
export async function resolveSubjectToken(options: {...}): Promise<AccessTokenInfo> {
  const info = await options.accessTokenResolver.findAccessToken(options.subjectToken);
  if (info === null) {
    throw invalidSubjectToken();
  }
  const nowSeconds = toEpochSeconds(options.now);
  if (info.expiresAt <= nowSeconds) {
    throw invalidSubjectToken();
  }
  if (info.nbf !== undefined && info.nbf > nowSeconds) {
    throw invalidSubjectToken();
  }
  return info;                      // ← grantId の有無は見ていない
}
```

### 発行素材（optional のまま素通し）

同 :411-419:

```ts
return {
  subject: subject.sub,
  clientId: context.client.clientId,
  scope,
  requestedAudience,
  expiresIn,
  grantId: subject.grantId,        // ← undefined でも通る
};
```

### 生成 OP の保存（undefined がそのまま入る）

`samples/hono-cloudflare/src/oidc-provider/routes/token.ts:253-256`（生成元は `packages/cli`）:

```ts
// Inherit the subject token's grant so revoking the grant (e.g. on code
// reuse detection) also kills every token exchanged from it.
grantId: grant.grantId,
```

`grant.grantId` が `undefined` なら、保存されたレコードは
`accessTokenStore.revokeByGrantId(...)` の対象から外れる。

### 失敗時の応答（オラクルを作らない既存方針）

同 :32-40:

```ts
export const SUBJECT_TOKEN_INVALID_DESCRIPTION =
  'The provided subject_token is not valid';
```

不存在・期限切れ・nbf 未来・失効済みを **区別しない**固定文言。
本タスクで追加する拒否も、この方針に揃える。

## 修正方針

- [ ] `packages/experimental/src/token-exchange/token-exchange-request.ts`
  - [ ] `resolveSubjectToken` の末尾（`return info` の直前）に `grantId` の存在検査を追加する
    ```ts
    // 交換トークンは subject_token の grantId を継承することでのみ grant 単位失効の
    // 対象になる（本モジュールは独自の失効索引を持たない）。grantId を持たない
    // subject_token から交換すると、どの失効経路でも殺せないトークンが生まれるため、
    // ここで拒否する。失敗理由は他の失敗と区別できない固定文言にする。
    if (info.grantId === undefined) {
      throw invalidSubjectToken();
    }
    ```
  - [ ] `resolveSubjectToken` の JSDoc に、`grantId` 必須である理由を追記する
  - [ ] `TokenExchangeGrant.grantId` を `grantId: string`（必須）へ変更する
        （`resolveSubjectToken` を通過した時点で必ず存在するため、型で表現できる）
  - [ ] モジュール冒頭コメント（:10-17）に「失効に関する保証範囲」の節を追加する
    - 届く: 認可コード再利用検知 / RT family 失効 / 同意撤回 / RT の RFC 7009 失効
    - 届かない: subject_token（アクセストークン）自身の RFC 7009 失効
      （RFC 7009 §2.1 上は MAY。派生関係の索引を持たないため）
- [ ] `packages/cli/src/frameworks/hono/templates.ts`
  - [ ] token-exchange 分岐の既存コメント
        （"Inherit the subject token's grant so revoking the grant ..."）の直後に、
        「subject_token 自身の失効は伝播しない」ことを 2〜3 行で追記する
  - [ ] `grantId: grant.grantId` の型が必須化されることに伴うコンパイルエラーが無いことを確認する

## テスト要件

### `packages/experimental`

- [ ] `should reject a subject_token that has no grantId`
- [ ] `should return the opaque failure description when the subject_token has no grantId`
      （`SUBJECT_TOKEN_INVALID_DESCRIPTION` と `toBe` で一致することを固定し、
      他の失敗理由と応答が区別できないことを保証する）
- [ ] `should throw invalid_request when the subject_token has no grantId`
      （`TokenExchangeError.code` を `toBe('invalid_request')` で固定）
- [ ] `should carry the subject token grantId into the exchange grant`
      （既存挙動の回帰防止。`toMatchObject` で `grantId` を具体値で固定する）
- [ ] `processTokenExchangeRequest` 経由でも同じ拒否が起きること
      （合成関数とステップ関数の両方で固定する）

### `packages/cli`

- [ ] 生成された token ルートに「subject_token 自身の失効は伝播しない」旨のコメントが
      含まれることを固定する
- [ ] 生成された token ルートが `grantId: grant.grantId` を保存し続けることを固定する（回帰防止）

### `samples/*/conformance.test.ts`（生成元は `packages/cli`）

- [ ] token-exchange 機能が有効な生成 OP に対し、
      grant に紐づいたアクセストークンを交換すると成功し、
      交換トークンが元 grant の `grantId` を持つことを固定する
- [ ] 元 grant を失効させると（RT を RFC 7009 で失効させる経路）、
      交換トークンも UserInfo / Introspection から無効になることを固定する

## 完了条件

- [ ] `pnpm --filter @maronn-openid-connect/experimental test` が通る
- [ ] `pnpm --filter @maronn-openid-connect/cli test` が通る
- [ ] `pnpm --filter "./packages/*" test` が通る
- [ ] `pnpm run test:conformance` が通る
- [ ] `packages/experimental` に手書きの changeset を **追加していない**
      （`pnpm run test:release-contract` が通ること）
- [ ] `study-material/done/token-exchange-derived-token-revocation-coupling.md` の
      方針C（派生関係の記録と失効伝播）は **未着手のまま**であり、
      本タスクのスコープ外であることが同ファイルに明記されている
