# [P1] Basic OP Conformance 用の標準 UserInfo クレーム fixture を揃える

## ステータス

🟢 High / fixture 拡充＋claims parameter の UserInfo 伝播 実装済み（実フローで profile/address/phone 返却・claims-essential を確認）

## 背景

`tests/conformance` の直近実行結果では、UserInfo の標準 scope claim が不足しているため複数 module が warning になっている。

対象結果:

- `tests/conformance/results/oidcc-basic-certification-test-plan-discovery-static_client-5XeV397bGW050-17-Jun-2026.zip`
- `oidcc-scope-profile`: warning
- `oidcc-scope-address`: warning
- `oidcc-scope-phone`: warning
- `oidcc-scope-all`: warning
- `oidcc-claims-essential`: warning (`name not found in userinfo`)

Conformance Suite の `VerifyScopesReturnedInUserInfoClaims` は、要求された scope に対応する標準 claim を UserInfo で返せているかを warning 条件として確認している。ここでの問題は「余計な claim を返している」ことではなく、OP が Discovery で `profile`, `email`, `address`, `phone` を対応 scope として広告しているのに、要求された scope に対応する fixture claim が不足していること。現在の CLI 生成 store / samples の `testuser` は `name` と `email` 以外をほぼ持たないため、`profile`, `address`, `phone` scope を要求されても返せる標準 claim が足りない。

`claims-essential` は別の問題を見ている。`claims={"userinfo":{"name":{"essential":true}}}` は、scope とは別に UserInfo response の個別 claim として `name` を要求する指定であり、`openid` scope だけの request でも UserInfo に `name` を含めることを期待する。これは「profile scope がないのに name を返すのが問題」という意味ではない。OIDC Core の `claims` parameter による明示要求を UserInfo 側へ伝播できていないことが問題である。

現行実装は Authorization Request の `claims` を ID Token 生成へ渡しているが、Access Token metadata に `claims` を保存しておらず、UserInfo route から `handleUserInfoRequest` へ `claimsParameter` を渡していない。そのため fixture に `name` が存在しても、UserInfo の追加 claim 要求が反映されない。

## 調査根拠

- OIDC Core 1.0 §5.4: `profile`, `email`, `address`, `phone` scope が要求する標準 claim を定義している。
- OIDC Core 1.0 §5.5: `claims` parameter の `userinfo` member は UserInfo response に含める個別 claim を要求する。
- OIDF Conformance Suite `AbstractVerifyScopesReturnedInClaims`: scope ごとの期待 claim 一覧を使って UserInfo を検証している。
- OIDF Conformance Suite `OIDCCClaimsEssential`: `claims.userinfo.name.essential=true` を要求し、UserInfo に `name` が返ることを warning 条件として確認している。
- 現行実装: `packages/cli/src/frameworks/hono/templates.ts` の `UserStore` は `testuser` に `sub`, `name`, `email`, `email_verified` だけを設定している。
- 現行実装: token route は `generateTokenResponse` にだけ `claims` を渡し、`accessTokenStore.set(...)` には保存していない。UserInfo route も `handleUserInfoRequest` に `claimsParameter` を渡していない。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`
- `packages/cli/src/__tests__/hono-generator.test.ts`
- `packages/core/src/userinfo.ts`
- `packages/core/src/userinfo.test.ts`
- `samples/hono/src/oidc-provider/store.ts`
- `samples/hono/src/oidc-provider/routes/token.ts`
- `samples/hono/src/oidc-provider/routes/userinfo.ts`
- `samples/express/src/oidc-provider/store.ts`
- `samples/fastify/src/oidc-provider/store.ts`
- `samples/nextjs/src/app/_oidc-provider/store.ts`
- 必要に応じて各 sample の `conformance.test.ts`

`samples/*/src/oidc-provider` は CLI 生成物なので、修正元は必ず `packages/cli` のテンプレートに置く。

## 修正方針

- [ ] CLI 生成 `UserStore` の `testuser` に、Discovery で広告している scope に対応する標準 claim を固定値で追加する。
- [ ] `profile` scope:
  - `name`
  - `family_name`
  - `given_name`
  - `middle_name`
  - `nickname`
  - `preferred_username`
  - `profile`
  - `picture`
  - `website`
  - `gender`
  - `birthdate`
  - `zoneinfo`
  - `locale`
  - `updated_at`
- [ ] `email` scope:
  - `email`
  - `email_verified`
- [ ] `address` scope:
  - `address.formatted`
  - `address.street_address`
  - `address.locality`
  - `address.region`
  - `address.postal_code`
  - `address.country`
- [ ] `phone` scope:
  - `phone_number`
  - `phone_number_verified`
- [ ] `filterClaimsByScope` の仕様は変えない。クレームの有無は resolver / fixture 側の責務として扱う。
- [ ] Authorization Code に紐づく `claims` parameter を Access Token metadata に保存できるようにする。
- [ ] UserInfo route で Access Token metadata の `claims` を `handleUserInfoRequest({ claimsParameter })` に渡す。
- [ ] `claims.userinfo` による追加 claim 返却は `scope` による claim filtering の後に適用する。既存 `handleUserInfoRequest` の方針を維持し、`value` / `values` 制約に一致しない claim は省略する。
- [ ] `openid` scope だけの request で `claims.userinfo.name` がある場合、`profile` scope が無いことだけを理由に `name` を落とさない。`claims` parameter は scope と独立した個別 claim 要求として扱う。
- [ ] scope 由来の claim と `claims.userinfo` 由来の claim はテスト名・コメントで区別し、Conformance warning の原因が fixture 不足なのか claims 伝播不足なのか読めるようにする。
- [ ] Discovery の `scopes_supported` / `claims_supported` と fixture の整合を維持する。

## テスト要件

- [ ] 生成 store に標準 claim が含まれることを `hono-generator.test.ts` で固定する。
- [ ] `profile` scope の UserInfo が上記 profile claim を返すこと。
- [ ] `address` scope の UserInfo が `address` claim を返すこと。
- [ ] `phone` scope の UserInfo が `phone_number` / `phone_number_verified` を返すこと。
- [ ] `claims={"userinfo":{"name":{"essential":true}}}` で UserInfo に `name` が含まれること。
- [ ] `claims.userinfo.name` を含む Authorization Request で発行した Access Token から、`openid` scope だけでも UserInfo に `name` が含まれること。
- [ ] `claims.userinfo.name.value` が実際の `name` と一致しない場合は、UserInfo に `name` を含めないこと。
- [ ] `pnpm --filter @maronn-openid-connect/cli test` がパスすること。
- [ ] `pnpm run conformance:basic-op` の ZIP で上記 scope / claims-essential warning が消えること。

## 完了条件

- `oidcc-scope-profile`, `oidcc-scope-address`, `oidcc-scope-phone`, `oidcc-scope-all`, `oidcc-claims-essential` が warning なしで完了する。
- CLI 生成物と `samples/*` が同期している。
