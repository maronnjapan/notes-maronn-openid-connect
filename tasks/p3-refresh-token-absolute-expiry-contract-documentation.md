# [P3] Refresh Token 絶対寿命の契約（sliding しない・観測手段は Introspection）を明文化する

## ステータス

🟢 Low / 未着手

## 背景

生成 OP は Refresh Token に **初回発行時刻からの絶対寿命（既定 90 日 = 7776000 秒）** を課す。
ローテーションを何度繰り返しても失効時刻は前へ進まない（sliding expiry を持たない）。
この設計は `tasks/done/p1-refresh-token-absolute-lifetime.md` で確定済みである。

しかしその帰結として、次の状態になっている。

> **クライアントは、自分が保持している Refresh Token が「いつ hard expire するか」を
> トークンレスポンスからは一切知ることができない。**

- RFC 6749 §5.1 の `expires_in` は **アクセストークンの寿命**であり、
  Refresh Token の寿命を伝える標準パラメータは **存在しない**。
- したがって「返さないこと」自体は **仕様違反ではない**。
- しかし 90 日目の refresh 要求は予告なく `invalid_grant` になり、
  エンドユーザから見ると「ある日突然ログアウトされた」になる。

一方、**標準的な観測手段は既に実装されている**。
`buildRefreshTokenResponse`（`packages/core/src/introspection.ts:151-163`）は
RT の `exp`（= 絶対失効時刻）を返しており、
`isRefreshTokenActive`（同 :125-129）はローテーション済み RT を `{ active: false }` にする。
つまり RFC 7662 Token Introspection が、そのまま「RT の寿命を知る経路」になっている。

問題は **その事実がどこにも書かれていないこと**である。

- 90 日という値は `config.ts` にあるので **OP 運用者は知っている**。
- **クライアント実装者（RP 側）はコードを読まないと知りようがない**。
- 「Introspection の `exp` で観測できる」ことも、どのドキュメントにも書かれていない。

これは実装のバグではなく **契約の明文化が欠けている**種類の問題であり、
本リポジトリが `study-material/resolver-and-store-contract.md` などで
契約の明文化を重視してきた方針と整合する。

### 本タスクのスコープ

- **明文化のみ**を行う。挙動は一切変えない。
- 非標準パラメータ（`refresh_expires_in` 等）の追加は **スコープ外**。
  採否は `study-material/done/refresh-token-absolute-expiry-visibility.md` §7 方針C の
  判断待ちとして残す。
- アイドル失効併用時の `exp` の意味の確定も **スコープ外**（同 §7 方針D）。

## 対象ファイル

- `packages/core/src/token-request.ts`（`RefreshTokenInfo` の JSDoc）
- `packages/core/src/introspection.ts`（`buildRefreshTokenResponse` の JSDoc）
- `packages/cli/src/frameworks/hono/templates.ts`（生成 `config.ts` のコメント、生成 README）
- `packages/cli/src/__tests__/hono-generator.test.ts`
- `samples/*/src/oidc-provider/config.ts`（生成物。直接編集しない）

## 仕様参照

- **RFC 6749 §5.1 Successful Response**
  <https://datatracker.ietf.org/doc/html/rfc6749>
  - `expires_in`（逐語）: "The lifetime in seconds of the access token."
  - → **アクセストークンの寿命**であり RT の寿命ではない。RT 寿命のパラメータは §5.1 に無い
- **RFC 6749 §5.2 Error Response**
  - `invalid_grant` は「無効／期限切れ／失効」を意味的に区別しない
  - → 失効理由をエラーコードで区別しないのは **正しい**。本タスクは「失効前に知る手段」を扱う
- **RFC 6749 §10.4 Refresh Tokens** — RT の寿命は AS の裁量。通知義務は無い
- **RFC 7662 §2.1 / §2.2 Token Introspection**
  <https://datatracker.ietf.org/doc/html/rfc7662>
  - `token_type_hint` の登録値に `refresh_token` を含む（＝ RT を内省できる）
  - `exp`（逐語）: "OPTIONAL. Integer timestamp ... indicating when this token will expire"
  - → **RT の失効時刻を知る標準経路は Introspection である**
- **OAuth 2.1（draft-ietf-oauth-v2-1）§3.2.3 / §4.3**
  <https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1>
  - RFC 6749 のレスポンス構造を踏襲。RT 寿命フィールドは追加されていない
- **RFC 9700 §4.14 Refresh Token Protection**
  <https://datatracker.ietf.org/doc/html/rfc9700>

## 現状の実装

### 絶対寿命はサーバ側だけが知っている

`samples/hono-cloudflare/src/oidc-provider/routes/token.ts:624`（生成元は `packages/cli`）:

```ts
const refreshTokenExpiresAt = originalIssuedAt + config.refreshTokenAbsoluteLifetime;
```

`samples/hono-cloudflare/src/oidc-provider/config.ts:73`:

```ts
refreshTokenAbsoluteLifetime: 7776000,
```

`RefreshTokenInfo.originalIssuedAt` の JSDoc（`packages/core/src/token-request.ts:186-192`）は
「ローテーション時は元 RT の値をそのまま引き継ぐ」と書いているが、
**「クライアントからは観測できない」ことには触れていない**。

### レスポンスに RT 寿命は載らない

`packages/core/src/token-response.ts:133-150` の `TokenResponse` に該当フィールドは無い。
`generateTokenResponse` は `refreshTokenExpiresIn` をオプションとして受け取るが
（同 :78）、レスポンスには反映せず、呼び出し側のストア保存用としてのみ定義されている。
**この非対称（受け取るが返さない）も JSDoc に説明が無い。**

### Introspection は既に `exp` を返している

`packages/core/src/introspection.ts:151-163` の `buildRefreshTokenResponse` は
`exp: info.expiresAt` を返す。生成 OP は `introspectionRefreshTokenResolver` を
Introspection へ配線済みである（`samples/hono-cloudflare/src/oidc-provider/resolvers.ts`）。
つまり **経路は動いているのに、使い方が案内されていない**。

## 修正方針

- [ ] `packages/core/src/token-request.ts`
  - [ ] `RefreshTokenInfo.expiresAt` の JSDoc に追記
    - 「初回発行時刻からの絶対寿命であり、ローテーションで前へ進まない（sliding しない）」
    - 「クライアントがこの値を観測する標準経路は RFC 7662 Token Introspection の `exp` である
      （RFC 6749 §5.1 には RT 寿命を返すパラメータが無い）」
  - [ ] `RefreshTokenInfo.originalIssuedAt` の JSDoc に、上記への相互参照を追記
- [ ] `packages/core/src/token-response.ts`
  - [ ] `TokenResponseOptions.refreshTokenExpiresIn` の JSDoc に
        「この値は **レスポンスには含めない**。RFC 6749 §5.1 に対応するパラメータが無いため、
        呼び出し側のストア保存用にのみ受け取る」ことを明記
- [ ] `packages/core/src/introspection.ts`
  - [ ] `buildRefreshTokenResponse` の JSDoc（または関数上のコメント）に
        「`exp` は RT の絶対失効時刻であり、クライアントが hard expiry を知る唯一の標準経路である」
        ことを明記
- [ ] `packages/cli/src/frameworks/hono/templates.ts`
  - [ ] 生成される `config.ts` の `refreshTokenAbsoluteLifetime` のコメントに
        「この値は RP へ周知すべき運用パラメータである。RP は Introspection の `exp` で
        残存寿命を観測できる」ことを追記
  - [ ] 生成される README（または対応する説明ファイル）に
        「Refresh Token の残存寿命を確認する」節を追加し、
        `token_type_hint=refresh_token` を付けた introspection の curl 例を載せる

## テスト要件

- [ ] `packages/core/src/introspection.test.ts`
  - [ ] `should return the absolute expiry as exp for an active refresh token`
        — `expiresAt` に具体値を設定し、`exp` が同じ値であることを `toBe` で固定する
  - [ ] `should report a rotated refresh token as inactive`
        — `used: true` の RT が `{ active: false }` になることを `toEqual` で固定する
        （既存挙動の回帰防止。「observation 経路が壊れていない」ことの担保）
- [ ] `packages/cli/src/__tests__/hono-generator.test.ts`
  - [ ] `should document that the refresh token lifetime is absolute in the generated config`
        — 生成された `config.ts` に該当コメント文言が含まれることを固定する
  - [ ] `should document how to observe the refresh token expiry in the generated README`
        — 生成された README に introspection の案内が含まれることを固定する
  - [ ] `should wire the refresh token resolver into the generated introspection route`
        — Introspection から RT を解決できる配線が外れていないことを固定する
        （外れると `exp` の観測経路が黙って死ぬため）

## 完了条件

- [ ] `pnpm --filter @maronn-openid-connect/core test` が通る
- [ ] `pnpm --filter @maronn-openid-connect/cli test` が通る
- [ ] `pnpm --filter "./packages/*" test` が通る
- [ ] `pnpm run test:conformance` が通る
- [ ] 生成 OP の挙動（レスポンス形状・エラーコード）が **一切変わっていない**
      （`samples/*/conformance.test.ts` が無変更で通ること）
- [ ] `study-material/done/refresh-token-absolute-expiry-visibility.md` の
      方針C（`refresh_expires_in` の追加）／方針D（アイドル失効併用時の `exp` の意味）は
      未着手のまま残り、本タスクのスコープ外であることが同ファイルに明記されている
