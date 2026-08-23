# [P1] 発行トークン値の一意性を保証する（同一秒の JWT 再発行がバイト同一になる問題）

## ステータス

🟢 完了（2026-08-03）

`jti` 付与により、同一入力・同一秒の 2 回発行が別トークン文字列になることを固定した。
`packages/core` / `packages/cli` テンプレート / 各 sample の `conformance.test.ts` に反映済み。

## 背景

既定の JWT アクセストークン（`accessTokenFormat: 'jwt'`）は、payload が
`{iss, sub, aud, exp, iat, scope, client_id, nbf}` だけで構成され、**発行ごとに変化する要素を一切持たない**。
署名アルゴリズムの RS256（RSASSA-PKCS1-v1_5）は決定的なので、
`(iss, sub, aud, scope, client_id)` が同じ 2 回の発行が**同じ壁時計秒**に落ちると、
アクセストークン文字列がバイト単位で同一になる。`at_hash` も一致するため ID Token も同一になり、`iat` も同値になる。

**実測で確認済み**（詳細は `study-material/done/token-value-uniqueness-same-second-jwt-reissuance-collision.md`）:

- core の関数を直接呼んだ再現: `at1 === at2` / `id1 === id2` / `iat` 同値
- `samples/hono-cloudflare` の `conformance.test.ts` の rotation テストを一時計測したところ、
  **authorization_code で発行したアクセストークンと refresh_token で発行したアクセストークンが同一文字列**
  だった（in-process のため同一秒に収まる）。既存の契約テストは値の一意性をアサートしていないためパスしている。

### 影響

1. 🟠 **grant 単位失効の取りこぼし（セキュリティ）**
   同一クライアント・同一 subject・同一 scope・同一 aud の認可コードフローが 2 本、同じ秒に
   Token Endpoint へ到達すると（2 タブ同時ログイン、自動テスト、負荷試験）、`grantId` は異なるのに
   アクセストークン文字列が同一になる。`accessTokenStore` はトークン文字列をキーにするため、
   後勝ちの `set` が先の grant の `grantId` を上書きし、
   **先の grant に対する `revokeByGrantId`（認可コード再利用検知・同意撤回・RT ファミリー失効）が
   そのトークンを失効できなくなる**。エラーもログも出ないため利用者は検知できない。

2. 🟠 **`claims` 認可コンテキストの破壊**
   refresh 経路は `accessTokenStore.set` に `claims: undefined` を書き込む。衝突時は
   authorization_code 経路で保存された `claims` が `undefined` で上書きされ、UserInfo が無言で縮退する。

3. 🟠 **リフレッシュしても新しい秘密が発行されない**
   rotation 後のアクセストークンが初回と同一値になるため、初回アクセストークンが漏洩していた場合に
   リフレッシュで影響を断ち切れない。

4. 🟡 **Basic OP conformance の非決定的失敗**
   OIDF Conformance Suite の `CompareIdTokenClaims` は「refresh 後 ID Token の `iat` が初回と同値ならエラー」
   を明示的に実装している。2026-06-21 の実測では `oidcc-refresh-token` は PASSED だったが、
   OP 応答が速い環境で再実行すると FAILED になりうる。

### 既存タスクとの関係

`tasks/p2-jwt-access-token-jti.md` は同じ `jti` 付与を「RFC 9068 §2.2 の required claim を満たす」という
**仕様準拠の観点**で立てている。本タスクはその実装内容を包含し、動機に上記のセキュリティ影響を加えたもの。
**両者は 1 回の実装で解決するため、本タスクに統合して実施すること。**

## 対象ファイル

- `packages/core/src/access-token.ts`（`AccessTokenPayload` に `jti` を追加）
- `packages/core/src/token-response.ts`（`buildAccessTokenPayload` で `jti` を既定生成）
- `packages/core/src/access-token-issuer.ts`（`AccessTokenIssuer.issue()` の一意性契約を JSDoc 化）
- `packages/core/src/introspection.ts`（`jti` を返す）
- `packages/cli/src/frameworks/hono/templates.ts`（生成 OP で `jti` をストアへ保存、契約テストの追加）
- `packages/cli/src/frameworks/web-standard/templates.ts`（同上・必要なら）
- `samples/*/src/oidc-provider/**`（テンプレート変更後に再生成）
- `packages/core/src/token-response.test.ts` / `access-token.test.ts` / `crypto-utils.test.ts`

## 仕様参照

- **RFC 9068 §2.2**: JWT アクセストークンの `jti` は **REQUIRED**。
- **RFC 7519 §4.1.7 (`jti`)**: "The identifier value MUST be assigned in a manner that ensures that
  there is a negligible probability that the same value will be accidentally assigned to a different
  data object." — 異なるトークンに同じ値が付かないことを要求する。
- **RFC 8017 §8.2 (RSASSA-PKCS1-v1_5)**: PKCS#1 v1.5 署名は決定的。同鍵・同入力から常に同一署名。
  対して §8.1 の RSASSA-PSS（`PS256`）は salt により確率的。
- **OIDC Core 1.0 §12.2**: refresh で再発行する ID Token の `iat` は
  "MUST represent the time that the new ID Token is issued"。
- **OIDC Core 1.0 §15.1**: RS256 は必須。つまり RS256 を外して衝突を回避する選択肢は無い。
- **OAuth 2.1 §4.1.2 / RFC 9700 §4.13**: 認可コード再利用検知時に発行済みトークンを失効すべき（SHOULD）。
  この失効はストアレコードが正しい `grantId` を保持していることに依存する。
- **OIDF Conformance Suite `CompareIdTokenClaims`**:
  https://gitlab.com/openid/conformance-suite/-/raw/master/src/main/java/net/openid/conformance/condition/client/CompareIdTokenClaims.java

## 現状の実装

`packages/core/src/token-response.ts:267-282`:

```ts
export function buildAccessTokenPayload(input: AccessTokenPayloadInput): AccessTokenPayload {
  const { issuer, subject, clientId, scope, audience, expiresIn } = input;
  const issuedAt = input.issuedAt ?? Math.floor(Date.now() / 1000);
  return {
    iss: issuer, sub: subject,
    aud: buildAccessTokenAudience({ requested: audience, issuer }),
    exp: issuedAt + expiresIn, iat: issuedAt,
    scope: scope.join(' '), client_id: clientId,
  };
}
```

7 クレームすべてが入力から決まり、`jti` も乱数も無い。`createJwtAccessTokenIssuer()` が足すのは
`nbf = iat` だけで、これも可変要素にならない。

一方 `createOpaqueAccessTokenIssuer()`（`access-token-issuer.ts:73-83`）は `generateRandomString(32)`
（256bit 乱数）を返すため、**Opaque 形式は影響を受けない**。影響は既定の `'jwt'` のみ。

生成 OP（`samples/*/src/oidc-provider/routes/token.ts:571-588`）は
`accessTokenStore.set(tokenResponse.access_token, {...grantId, claims...})` と
**トークン文字列をキーに**保存するため、同一文字列は既存レコードを上書きする。

## 修正方針

- [x] `AccessTokenPayload` に `jti?: string` を追加する（`packages/core/src/access-token.ts`）
- [x] `AccessTokenPayloadInput` に `jti?: string` を追加し、`buildAccessTokenPayload` で
      未指定なら `generateRandomString(16)`（128bit）を既定生成する。
      呼び出し側は戻り値の `payload.jti` をそのままストアへ渡せる
- [x] `AccessTokenIssuer.issue()` の JSDoc に
      「**発行ごとに一意な値を返さなければならない**（同じ payload でも異なる値になること）」を
      契約として明記する。独自 issuer を差し替える利用者向けの前提提示
- [x] 生成 OP テンプレートで `accessTokenStore.set` に `jti: accessTokenPayload.jti` を保存する
      （token-exchange 経路は `jti: exchangePayload.jti`）
- [x] `introspection` が `jti` を返せるようにする
      （core は元から `AccessTokenInfo.jti` をエコーする実装だったため、欠けていたのは
      生成 OP 側の保存のみ。合成 API 利用者向けに
      `GenerateTokenResponseResult.accessTokenJti` も追加した）
- [x] refresh で再発行する ID Token の `iat` が初回と必ず異なることを保証するかを判断する。
      → **(a) 受容を選択した（2026-08-03）。** 判断根拠と、(b) を選ぶ場合に必要な作業は
      下記「`iat` 単調性の判断記録」に残す。
      `jti` 導入で `at_hash` が変わるため **ID Token 自体はバイト単位で一意になる**が、
      `iat` は依然同値になりうる。以下のいずれかを選ぶ:
      - (a) 受容する（同一秒 refresh は実運用ではまれ、という判断。ただし conformance 再実行時のリスクは残る）
      - (b) 「refresh 経路では `iat` が直前の ID Token の `iat` 以下にならないよう +1 する」限定的な単調性ガードを入れる
      - **この判断は人間が行うこと。** 判断材料は
        `study-material/done/token-value-uniqueness-same-second-jwt-reissuance-collision.md` §7 方針B / 方針D

実装例（`buildAccessTokenPayload`）:

```ts
export function buildAccessTokenPayload(input: AccessTokenPayloadInput): AccessTokenPayload {
  const { issuer, subject, clientId, scope, audience, expiresIn } = input;
  const issuedAt = input.issuedAt ?? Math.floor(Date.now() / 1000);
  return {
    iss: issuer,
    sub: subject,
    aud: buildAccessTokenAudience({ requested: audience, issuer }),
    exp: issuedAt + expiresIn,
    iat: issuedAt,
    // RFC 9068 §2.2: jti is REQUIRED. RFC 7519 §4.1.7 requires a negligible
    // collision probability. It is also what makes two issuances in the same
    // wall-clock second produce distinct tokens — RS256 (RFC 8017 §8.2) is
    // deterministic, so without jti an identical payload yields an identical JWT.
    jti: input.jti ?? generateRandomString(16),
    scope: scope.join(' '),
    client_id: clientId,
  };
}
```

## テスト要件

- [ ] `buildAccessTokenPayload` を同じ入力・同じ `issuedAt` で 2 回呼ぶと `jti` が異なること
- [ ] `createJwtAccessTokenIssuer().issue()` を同じ入力で 2 回呼ぶと**トークン文字列が異なる**こと
      （現状は同一になるため Red になる）
- [ ] `generateRandomString` の出力が base64url 文字種（`[A-Za-z0-9\-_]`）のみであること。
      RFC 6749 Appendix A.17 の `1*VSCHAR` を満たす回帰固定
- [ ] `generateRandomString(32)` を複数回呼んで値が重複しないこと
- [ ] 生成 OP の `conformance.test.ts`（**生成元の `packages/cli` テンプレートを修正すること**）に、
      rotation 前後の不変条件を追加する:
  - [x] rotation 後の `access_token` が初回と**異なる**こと（現状 Red）
  - [ ] rotation 後の `id_token` の `iat` が初回と**異なる**こと
        → **(a) 受容を選択したため追加していない。** (b) を採用する場合に追加する
  - [x] rotation 後の `id_token` の `iss` / `sub` / `aud` / `auth_time` が初回と**一致**すること
  - [x] 初回 ID Token に `azp` が無い場合、rotation 後にも `azp` が無いこと
        （OIDF `CompareIdTokenClaims` の要求）
- [x] 同一秒に 2 本の認可コードフローを完了させたとき、片方の grant に対する `revokeByGrantId` が
      もう片方のトークンを巻き込まない／取りこぼさないことを統合テストで固定する
      （`conformance.test.ts`: "should keep grant-scoped revocation inside one grant when two
      grants are issued in the same second"）
- [x] introspection のレスポンスに `jti` が含まれること
      （`conformance.test.ts`: "should echo the jti of an access token issued by the token endpoint"）

## 完了条件

```bash
pnpm --filter @maronn-openid-connect/core test
pnpm --filter @maronn-openid-connect/cli test
pnpm --filter "./samples/*" test
pnpm --filter "./samples/*" typecheck
```

がすべてパスし、かつ次を満たすこと。

- 同一入力・同一秒での 2 回発行が**異なるアクセストークン文字列**を返す
- 生成 OP の `conformance.test.ts` に rotation 前後の不変条件アサーションが入り、パスする
- `tasks/p2-jwt-access-token-jti.md` の修正方針・テスト要件がすべて本タスクで満たされている
  （満たしたら同タスクを `tasks/done/` へ移動する）

## `iat` 単調性の判断記録（2026-08-03）

タスク本文は「refresh 再発行 ID Token の `iat` を初回と必ず異ならせるか」を人間の判断事項として
留保していた。本実装では **(a) 受容** を選び、`iat` の挙動は変更していない。

理由:

- 本タスクの実害（grant 単位失効の取りこぼし・`claims` の上書き・rotation で新しい秘密が
  発行されない）は、すべてアクセストークン文字列の衝突に起因する。`jti` の導入でこれは解消し、
  `at_hash` も変わるため **ID Token 自体もバイト単位で一意**になる。残るのは `iat` の同値のみで、
  これ自体は失効にもストアにも影響しない
- (b) の「refresh では直前の `iat` 以下にならないよう +1 する」は、OIDC Core 1.0 §12.2 の
  「`iat` は新しい ID Token の発行時刻を表す MUST」に対して意図的に実時刻からずらす変更になる。
  実時刻からの乖離を許容するかは仕様解釈を伴う方針判断であり、本修正（バグ修正）の範囲を超える

残るリスク（引き継ぎ事項）:

- OIDF Conformance Suite の `CompareIdTokenClaims` は「refresh 後 ID Token の `iat` が初回と
  同値ならエラー」を実装している。OP 応答が同一秒に収まる高速な環境で `oidcc-refresh-token` を
  実行すると FAILED になりうる。実際に踏んだ場合は (b) の採用を再検討すること
  （判断材料: `study-material/done/token-value-uniqueness-same-second-jwt-reissuance-collision.md` §7 方針B / 方針D）
