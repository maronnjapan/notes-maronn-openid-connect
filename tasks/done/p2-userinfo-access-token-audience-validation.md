# [P2] UserInfo エンドポイントでアクセストークンの `aud` を検証する

## ステータス

🟡 Medium / 未着手

## 背景

`handleUserInfoRequest`（`packages/core/src/userinfo.ts`）は、アクセストークンの「存在・有効期限・`openid` scope」のみを検証し、トークンの `aud`（audience）が UserInfo エンドポイント（= OP 自身）向けであることを検証していない。

一方 `buildAccessTokenAudience`（`packages/core/src/token-response.ts:185`）は、アクセストークンの `aud` に「UserInfo エンドポイント URL（恒久メンバ）＋要求された `resource` indicator（RFC 8707）」を合成して載せている。つまり aud には OP 以外のリソース識別子が混入しうる。

RFC 9068 §4 は、JWT アクセストークンを受け取るリソースサーバに対し「`aud` に自分を指す識別子が含まれることを検証 MUST、含まれなければ `invalid_token` で拒否」を課す。UserInfo は OIDC Core §5.3 のアクセストークン保護リソースであり、JWT AT 採用 OP では検証義務の対象になる。現状は **発行側だけが aud を載せ、受領側（UserInfo）が aud を見ない片側実装**であり、`resource` indicator を本格採用すると「API 専用トークンで UserInfo の PII を取得できる」confused deputy が成立しうる。

検討の全体像・方針比較は `study-material/done/userinfo-access-token-audience-validation.md` を参照。

> **追記（PR #125 レビュー反映）**: 当初は後方互換のオプトイン方式で実装したが、レビューで「opt-in ではなく JWT / Opaque 両方で aud を基本的に検証する」方針に変更した。`expectedAudience` は core API としては引数のまま残すが、生成された Provider（`packages/cli` の userinfo route テンプレート）が UserInfo エンドポイント URL を常に渡すため、audience 検証はデフォルトで有効になる。opaque でも aud 未保存の緩和は行わず、`expectedAudience` 指定時は aud 未設定・不一致のいずれも `invalid_token`（401）で拒否する（当 OP は JWT / opaque を問わず全アクセストークンに UserInfo エンドポイントを含む aud を保存するため）。

## 対象ファイル

- `packages/core/src/userinfo.ts`
- `packages/core/src/userinfo.test.ts`

## 仕様参照

- RFC 9068 §4（Validating JWT Access Tokens）: リソースサーバは `aud` に自分を指すリソース識別子が含まれることを検証 MUST、含まれなければ拒否 MUST、エラーは `invalid_token`
- RFC 8707（Resource Indicators）: `resource` による audience 限定の意図。受領側が aud を見ないと限定効果が無効化される
- OIDC Core 1.0 §5.3: UserInfo はアクセストークンで保護された保護リソース

## 現状の実装

```ts
// packages/core/src/userinfo.ts handleUserInfoRequest（抜粋）
const tokenInfo = await accessTokenResolver.findAccessToken(accessToken);
if (!tokenInfo) { /* invalid_token */ }
if (tokenInfo.expiresAt < now) { /* invalid_token */ }
if (!tokenInfo.scope.includes('openid')) { /* insufficient_scope */ }
// ↑ tokenInfo.audience は一度も参照されない（検証フックが無い）
```

`AccessTokenInfo.audience`（`userinfo.ts:67`）は introspection（`introspection.ts:114-115`）でのみ参照され、UserInfo の検証経路では使われていない。

## 修正方針

- [ ] `UserInfoRequestContext` に `expectedAudience?: string`（UserInfo エンドポイント URL）を追加する
- [ ] `expectedAudience` が指定されている場合のみ、`tokenInfo.audience` に当該値が含まれるか検証する
- [ ] 含まれない場合は `UserInfoError(UserInfoErrorCode.InvalidToken, ...)`（401）を投げる
- [ ] `expectedAudience` 未指定時、または `tokenInfo.audience` が未設定（opaque で aud 未保存）の場合は従来どおり検証をスキップし、完全な後方互換を維持する
- [ ] `buildAccessTokenAudience` の `userInfoEndpoint` と本検証の `expectedAudience` を同一設定から導出すべき旨をコメント / JSDoc に明記する（不一致による誤検知＝自前トークンを弾く事故を防ぐ）

```ts
export interface UserInfoRequestContext {
  accessToken: string;
  accessTokenResolver: AccessTokenResolver;
  userClaimsResolver: UserClaimsResolver;
  claimsParameter?: ClaimsParameter;
  /**
   * UserInfo エンドポイント自身を指す audience 識別子（UserInfo エンドポイント URL）。
   * 指定時のみ RFC 9068 §4 の aud 検証を行う。未指定なら検証しない（後方互換）。
   * 値は buildAccessTokenAudience の userInfoEndpoint と同一にすること。
   */
  expectedAudience?: string;
}

// 検証（openid scope チェックの後に追加）
if (context.expectedAudience !== undefined && tokenInfo.audience !== undefined) {
  if (!tokenInfo.audience.includes(context.expectedAudience)) {
    throw new UserInfoError(
      UserInfoErrorCode.InvalidToken,
      'The access token is not intended for the UserInfo endpoint',
    );
  }
}
```

## テスト要件

- [ ] `expectedAudience` を指定し、`tokenInfo.audience` に同値を含むトークンは受理されること
- [ ] `expectedAudience` を指定し、`tokenInfo.audience` が `resource` 専用（UserInfo URL を含まない）のトークンは `invalid_token`（401）で拒否されること
- [ ] `expectedAudience` 未指定時は、aud に関係なく従来どおり受理されること（後方互換）
- [ ] `expectedAudience` 指定かつ `tokenInfo.audience` が未設定（undefined）の場合は受理されること（opaque 後方互換）
- [ ] 拒否時の `UserInfoError.statusCode` が 401 であること

## 完了条件

`pnpm --filter @maronn-openid-connect/core test` がパスすること
