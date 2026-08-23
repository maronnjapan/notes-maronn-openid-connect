# [P3] Introspection のトークン種別ごとのクレーム集合を契約として固定する（RT に `aud` を返さない理由の明記）

## ステータス

🟢 Low / 未着手

## 背景

`packages/core/src/introspection.ts` は、active なトークンのレスポンスを種別ごとに
別関数で組み立てている。

- アクセストークン: `buildAccessTokenResponse`（:131-149）
- リフレッシュトークン: `buildRefreshTokenResponse`（:151-163）

この 2 つが返すクレーム集合は一致していない。特に **`aud` は
`RefreshTokenInfo.audience` としてストアに保存されているのに、
リフレッシュトークンのレスポンスには載らない**。

差分は 2 群に分かれる。

| クレーム | RT のストアに値があるか | RT レスポンスに載るか | 群 |
|---|---|---|---|
| `aud` | **ある**（`RefreshTokenInfo.audience`、`token-request.ts:207`） | **載らない** | **A: 保存済みだが未出力** |
| `nbf` | 無い（フィールド自体が無い） | 載らない | B: 保存していない |
| `jti` | 無い（フィールド自体が無い） | 載らない | B |
| `username` | 無い（core は表示名を知る層に居ない） | 載らない | B |

RFC 7662 §2.2 では `active` 以外すべて OPTIONAL なので、
**どちらの群も仕様違反ではない**。問題は次の 2 点である。

1. **群 A（`aud`）を意図的に落としているのか、取りこぼしなのかがコードから読めない**。
   本リポジトリは意図的な省略には必ず理由コメントを置く方針を取っている
   （例: `INACTIVE_INTROSPECTION_RESPONSE` の :92-95、
   `RefreshTokenInfo.nonce`（`packages/core/src/token-request.ts:216-220`）は「なぜ refresh 再発行 ID Token へ出さないか」を明記）。
   ここにはそれが無い。
2. **群 B を「返せない」のか「返さない」のかも書かれていない**。

さらに、RT の `audience` は意味論が特殊である。
`RefreshTokenInfo.audience` の JSDoc（`packages/core/src/token-request.ts:202-207`）は
「**認可時に決定されたアクセストークンの audience**」と定義しており、
RFC 7662 §2.2 の `aud`（"intended audience for **this** token"）とは指すものが違う。
Refresh Token はトークンエンドポイント専用の資格情報（RFC 6749 §1.5）であり、
resource server に提示するものではないため、
**そのまま `aud` として返すと受け取り側が誤解しうる**。

加えて、現在の Introspection は所有者チェックを行わない
（`packages/core/src/introspection.ts:8-12` のコメント）。
この状態で `aud` を足すと、登録済みの任意の confidential client に対して
「この OP がどんな resource 識別子を扱っているか」が開示される。
RFC 7662 §2.2 が挙げる
"prevent a protected resource from learning more about the larger network than is necessary"
に反する方向である。

→ **したがって本タスクは「`aud` を追加する」ことではなく、
「現在の欠落を意図として固定し、テストで動かないようにする」ことをスコープとする。**

`aud` の追加自体は、所有者チェック（`tasks/p3-introspection-caller-authorization-hook.md`）の
完了後に改めて判断する。判断材料は
`study-material/done/introspection-refresh-token-response-claim-asymmetry.md` §7 にある。

## 対象ファイル

- `packages/core/src/introspection.ts`
- `packages/core/src/introspection.test.ts`
- `packages/core/src/introspection-steps.test.ts`

## 仕様参照

- **RFC 7662 §2.2 Introspection Response**
  <https://datatracker.ietf.org/doc/html/rfc7662>
  - `active` のみ REQUIRED。`scope` / `client_id` / `username` / `token_type` /
    `exp` / `iat` / `nbf` / `sub` / `aud` / `iss` / `jti` はすべて **OPTIONAL**
  - `aud` の定義（逐語）:
    > **aud** — OPTIONAL. Service-specific string identifier or list of string identifiers
    > representing the intended audience for this token, as defined in JWT [RFC7519].
  - 開示範囲の出し分けが認められていること（逐語）:
    > The authorization server MAY respond differently to different protected resources
    > making the same request. For instance, an authorization server MAY limit which scopes
    > from a given token are returned for each protected resource to prevent a protected
    > resource from learning more about the larger network than is necessary for its operation.
- **RFC 7662 §5 Security Considerations** — 内省エンドポイントの情報開示はそれ自体が攻撃面
- **RFC 6749 §1.5 Refresh Token**
  <https://datatracker.ietf.org/doc/html/rfc6749> —
  Refresh Token は **AS のトークンエンドポイント専用**であり resource server には提示しない
- **RFC 9068 §3 / §4**
  <https://datatracker.ietf.org/doc/html/rfc9068> —
  JWT アクセストークンの `aud` は「受領するリソースの識別子」。
  RT の `audience` はこの意味での aud ではない（派生アクセストークンの aud である）

## 現状の実装

`packages/core/src/introspection.ts:131-149`:

```ts
function buildAccessTokenResponse(info: AccessTokenInfo): IntrospectionResponse {
  const res: Extract<IntrospectionResponse, { active: true }> = {
    active: true,
    scope: info.scope.join(' '),
    client_id: info.clientId,
    token_type: 'Bearer',
    sub: info.sub,
    exp: info.expiresAt,
  };
  if (info.iat !== undefined) res.iat = info.iat;
  if (info.nbf !== undefined) res.nbf = info.nbf;
  if (info.audience !== undefined && info.audience.length > 0) res.aud = info.audience;
  if (info.issuer !== undefined) res.iss = info.issuer;
  if (info.jti !== undefined) res.jti = info.jti;
  return res;
}
```

`packages/core/src/introspection.ts:151-163`:

```ts
function buildRefreshTokenResponse(info: RefreshTokenInfo): IntrospectionResponse {
  const res: Extract<IntrospectionResponse, { active: true }> = {
    active: true,
    scope: info.scope.join(' '),
    client_id: info.clientId,
    token_type: 'refresh_token',
    sub: info.subject,
    exp: info.expiresAt,
  };
  if (info.iat !== undefined) res.iat = info.iat;
  if (info.issuer !== undefined) res.iss = info.issuer;
  return res;
  // aud / nbf / jti / username を返さない理由のコメントが無い
}
```

問題:

- `info.audience` は存在するのに使われていない（群 A）
- どちらの群についても理由が書かれていない
- 既存テストがレスポンス全体を `toEqual` で固定していない場合、
  将来 `aud` が「なんとなく」追加されても検知できない

## 修正方針

- [ ] `packages/core/src/introspection.ts`
  - [ ] `buildRefreshTokenResponse` に、返さないクレームの理由コメントを追加する
    ```ts
    // 返していないクレーム（RFC 7662 §2.2 上はいずれも OPTIONAL）:
    // - aud: RefreshTokenInfo.audience は「この RT から発行されるアクセストークンの aud」
    //   であり、RFC 7662 §2.2 の "intended audience for this token" とは指すものが違う。
    //   Refresh Token は AS のトークンエンドポイント専用（RFC 6749 §1.5）であり、
    //   aud として返すと受領側の誤解を招く。加えて現在は所有者チェックが無いため
    //   （tasks/p3-introspection-caller-authorization-hook.md）、開示面を広げない。
    //   追加の判断材料は
    //   study-material/done/introspection-refresh-token-response-claim-asymmetry.md。
    // - nbf / jti: RT は opaque な CSPRNG 値であり、これらを保持する設計にしていない。
    // - username: core はユーザー表示名を知る層に居ない（UserClaimsResolver は UserInfo 側）。
    //   PII を内省レスポンスへ載せる判断は
    //   study-material/done/introspection-caller-authorization-and-disclosure.md の管轄。
    ```
  - [ ] `IntrospectionResponse` 型（:76-90）の JSDoc に、
        トークン種別ごとに返るクレームの表を追加する
  - [ ] `buildAccessTokenResponse` にも「保存済みの optional クレームはすべて返す」方針を 1 行で明記する

## テスト要件

- [ ] `packages/core/src/introspection.test.ts`
  - [ ] `should return the full claim set for an active access token`
        — レスポンス**全体**を `toEqual` で固定する（`aud` / `nbf` / `jti` を含む具体値）
  - [ ] `should omit aud from an active refresh token response even when audience is stored`
        — `audience` を設定した `RefreshTokenInfo` を渡し、レスポンス**全体**を `toEqual` で固定する
        （`aud` キーが存在しないことを、部分一致ではなく全体一致で保証する）
  - [ ] `should omit nbf from an active refresh token response`
  - [ ] `should omit jti from an active refresh token response`
  - [ ] `should include iss in an active refresh token response when issuer is stored`
        — 返している optional クレームの回帰防止
- [ ] `packages/core/src/introspection-steps.test.ts`
  - [ ] `buildIntrospectionResponse` を種別ごとに直接呼び、上記と同じ全体一致を固定する

> テストは `toEqual` でレスポンス全体を固定すること。`toMatchObject` や
> `expect.objectContaining` を使うと、将来クレームが増えても気づけない
> （CLAUDE.md「アサーションは合格値を一意に固定する」）。

## 完了条件

- [ ] `pnpm --filter @maronn-openid-connect/core test` が通る
- [ ] `pnpm --filter "./packages/*" test` が通る
- [ ] `pnpm run test:conformance` が通る
- [ ] `buildRefreshTokenResponse` に `aud` を追加すると、
      新規に追加したテストが **必ず失敗する**（意図しない追加を検知できる）
- [ ] `study-material/done/introspection-refresh-token-response-claim-asymmetry.md` の
      T-B（`aud` の追加）は未着手のまま残り、
      前提が `tasks/p3-introspection-caller-authorization-hook.md` であることが明記されている
