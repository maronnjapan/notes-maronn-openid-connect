# 発行トークン値の一意性が保証されない（同一秒・同一クレームの JWT 再発行がバイト同一になる）

## 1. このトピックで確認したいこと

本 OP は既定で JWT 形式のアクセストークン（`accessTokenFormat: 'jwt'`）を発行する。JWT の payload は
`buildAccessTokenPayload()` が組み立てる `{iss, sub, aud, exp, iat, scope, client_id}`（+ `nbf`）だけで構成され、
**発行ごとに変化する一意識別子（`jti`）を持たない**。署名は RS256（RSASSA-PKCS1-v1_5）で決定的である。

したがって、`(iss, sub, aud, scope, client_id)` が同じ 2 回の発行が**同じ壁時計秒に落ちる**と、
payload が完全一致し、署名も一致し、**アクセストークン文字列がバイト単位で同一**になる。
同じ理由で ID Token も（`at_hash` まで一致するため）バイト同一になり、`iat` も同値になる。

このファイルで確認したいのは次の 3 点である。

1. 「トークン値は発行ごとに一意である」という暗黙の前提が、実装のどこにも保証として存在しないこと
2. その帰結として、`accessTokenStore` のキー衝突により **grant 単位の失効（`revokeByGrantId`）が取りこぼす**経路があること
3. OIDF Conformance Suite の `CompareIdTokenClaims` が「refresh 後の ID Token の `iat` は初回と異なること」を
   明示的に要求しており、同一秒 refresh が起きると Basic OP の `oidcc-refresh-token` が落ちうること

> **重複回避の方針**: `jti` クレームの追加そのものは 📌 `tasks/p2-jwt-access-token-jti.md` が
> 「RFC 9068 の required claim を満たす」という**仕様準拠の観点**で既にタスク化している。
> 本ファイルはその実装内容を繰り返さず、**「トークン値の一意性が壊れると何が壊れるか」という
> セキュリティ・conformance 上の帰結**にのみ絞る。`jti` は本問題の解決手段の候補の一つであって、
> 本ファイルの論点は `jti` の有無ではなく**一意性の契約**である。
> 併せて、Opaque アクセストークンの有効期限バインディングは
> `study-material/token-expiry-boundary-and-opaque-lifetime-binding.md`、
> ストアの原子性・CAS 契約は `study-material/resolver-and-store-contract.md` を参照し、繰り返さない。

## 2. 関連する仕様・基準

本トピック固有のポイントに絞る。共通の Basic OP 要件索引は
`study-material/basic-op-requirement-traceability.md` を参照。

- **RFC 9068 §2.2 (JWT Profile for OAuth 2.0 Access Tokens)**: JWT アクセストークンの
  `jti` クレームは **REQUIRED**。RFC 9068 は `jti` を「トークンの一意識別子」として定義しており、
  リプレイ検知・監査・失効の基礎となる。現状の実装は `jti` を出力していない。
- **RFC 7519 §4.1.7 (`jti`)**: "The identifier value MUST be assigned in a manner that ensures that
  there is a negligible probability that the same value will be accidentally assigned to a different
  data object." — すなわち `jti` は**異なるトークンに同じ値が付かない**ことを要求する。逆に言えば、
  `jti` を持たない JWT には「異なる発行が異なる値になる」保証が仕様上どこにも無い。
- **RFC 8017 §8.2 (RSASSA-PKCS1-v1_5)**: PKCS#1 v1.5 署名は**決定的**（乱数を含まない）。
  同じ鍵・同じ入力からは常に同じ署名バイト列が得られる。JWA の `RS256` はこの方式であり、
  同 payload の JWT は必ず同一文字列になる。対して `PS256`（RSASSA-PSS, RFC 8017 §8.1）は
  salt による確率的署名のため同 payload でも署名が変わる。
  → **RS256 必須という Basic OP の要件（OIDC Core §15.1）自体が、この衝突条件を成立させる。**
- **OIDC Core 1.0 §12.2 (Successful Refresh Response)**: refresh で再発行する ID Token について
  "its `iat` Claim MUST represent the time that the new ID Token is issued" と定める。
  OIDF Conformance Suite の `CompareIdTokenClaims` はこれを「初回 ID Token の `iat` と同値なら失敗」
  として実装している（後述の実測根拠を参照）。
- **OAuth 2.1 §4.1.2 / RFC 9700 §4.13**: 認可コード再利用検知時、同一認可付与から発行済みの
  トークンを失効すべき（SHOULD）。本リポジトリはこれを `grantId` 単位の `revokeByGrantId` で実装している。
  この失効はストアのレコードが「どの grant に属するか」を正しく保持していることに依存する。

## 3. 参照資料

- RFC 9068 (JWT Profile for OAuth 2.0 Access Tokens) §2.2 — https://www.rfc-editor.org/rfc/rfc9068.html#section-2.2
  （`jti` が REQUIRED であること）
- RFC 7519 (JSON Web Token) §4.1.7 `jti` — https://www.rfc-editor.org/rfc/rfc7519#section-4.1.7
  （「異なるオブジェクトに同じ値が割り当たる確率は無視できるほど小さくなければならない」）
- RFC 8017 (PKCS #1 v2.2) §8.1 RSASSA-PSS / §8.2 RSASSA-PKCS1-v1_5 —
  https://www.rfc-editor.org/rfc/rfc8017#section-8.2 （PKCS1-v1_5 が決定的、PSS が確率的であること）
- OpenID Connect Core 1.0 §12.2 Successful Refresh Response —
  https://openid.net/specs/openid-connect-core-1_0.html#RefreshTokenResponse
  （refresh 後 ID Token の `iat` は「新しく発行された時刻」を表す MUST）
- OpenID Connect Core 1.0 §15.1 Mandatory to Implement Features for All OpenID Providers —
  https://openid.net/specs/openid-connect-core-1_0.html#ServerMTI （RS256 必須）
- OIDF Conformance Suite `CompareIdTokenClaims`（Basic OP の `oidcc-refresh-token` が実行する条件）—
  https://gitlab.com/openid/conformance-suite/-/raw/master/src/main/java/net/openid/conformance/condition/client/CompareIdTokenClaims.java
  本調査時点の実装は次を要求する:
  - `iss` / `sub` / `aud` は初回 ID Token と一致すること
  - 初回に `azp` が無ければ再発行 ID Token にも `azp` があってはならない
  - 再発行 ID Token に `auth_time` があるなら初回と一致すること
  - **`iat` が初回と同値ならエラー**（「新しい発行時刻を表さなければならない」）
  - `nonce` は検証しない（本リポジトリの refresh 時 nonce 省略方針
    📌 `tasks/done/p2-refresh-id-token-nonce-omission.md` と矛盾しないことの一次情報上の裏付け）
- OIDF Conformance Suite `RefreshTokenRequestSteps`（refresh 応答に対して実行される条件列）—
  https://gitlab.com/openid/conformance-suite/-/raw/master/src/main/java/net/openid/conformance/sequence/client/RefreshTokenRequestSteps.java
  アクセストークンについて「**直前のトークンと異なること（uniqueness）**」「最小エントロピー」
  「許可文字種」を検証する条件が並ぶ。
- 本リポジトリ内: `packages/core/src/token-response.ts:267-282`（`buildAccessTokenPayload`）、
  `packages/core/src/access-token-issuer.ts:37-59`（JWT issuer）、`:73-83`（Opaque issuer）、
  `packages/core/src/token-response.ts:406-463`（`buildIdTokenPayload`）、
  `samples/hono-cloudflare/src/oidc-provider/routes/token.ts:483`（1 レスポンス 1 タイムスタンプ）、
  `:571-588`（`accessTokenStore.set`）

## 4. 現在の実装確認

### 4-1. アクセストークン payload に発行ごとの可変要素が無い

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

7 クレームすべてが入力から決まる。乱数・カウンタ・`jti` は無い。
`createJwtAccessTokenIssuer()` は `nbf = iat` を足すだけで、これも可変要素にならない。

対して Opaque issuer（`access-token-issuer.ts:73-83`）は `generateRandomString(32)`（256bit 乱数）を返すため、
**Opaque 形式は本問題の影響を受けない**。影響を受けるのは既定の `accessTokenFormat: 'jwt'` のみ。

### 4-2. 1 レスポンス 1 タイムスタンプ設計

生成 OP（`samples/*/src/oidc-provider/routes/token.ts:483`）は
`const issuedAt = Math.floor(Date.now() / 1000);` を 1 回だけ取り、アクセストークン・ID Token・
ストアレコードすべてに使い回す。これは「発行物とストアの `iat`/`exp` を一致させる」ための
意図的な設計であり、それ自体は正しい。ただし秒解像度であるため、**同一秒内の 2 回の発行は同じ `iat` になる**。

### 4-3. ストアはトークン文字列をキーにする

`samples/hono-cloudflare/src/oidc-provider/routes/token.ts:571-588`:

```ts
await accessTokenStore.set(tokenResponse.access_token, {
  sub: subject,
  clientId: validatedRequest.clientId,
  scope: validatedRequest.scope,
  expiresAt: issuedAt + config.accessTokenExpiresIn,
  grantId: validatedRequest.grantId,      // ← grant 単位失効の紐付け
  iat: issuedAt, nbf: issuedAt,
  audience: effectiveAudience, issuer: config.issuer,
  claims: validatedRequest.grantType === 'authorization_code' ? validatedRequest.claims : undefined,
});
```

キーはトークン文字列そのもの。**同じ文字列で `set` すると既存レコードを上書きする。**

### 4-4. 実測（本リポジトリの実コードで確認済み）

**(a) core の関数を直接呼んだ再現**（Node.js v22 / vitest, RSA-2048 の一時鍵）。
`buildAccessTokenPayload` + `createJwtAccessTokenIssuer().issue()` を同じ入力・同じ `issuedAt` で
2 回呼び、`buildIdTokenPayload` + `generateIdToken` も同様に 2 回呼んだ結果:

```
at1 === at2                       → true   （アクセストークンがバイト同一）
id1 === id2                       → true   （ID Token がバイト同一）
iat(id1) === iat(id2)             → true
```

**(b) 生成 OP の実 HTTP フローでの確認**（`samples/hono-cloudflare` の `conformance.test.ts` にある
「should reject rotated refresh token reuse and revoke every token from that grant」を一時的に計測）。
authorize → login → consent → `grant_type=authorization_code` → `grant_type=refresh_token` を
`app.request()` で通した結果:

```
access_token identical (初回発行 vs rotation 後)  → true
id_token identical                                → true
id_token iat equal                                → true
```

→ **既定構成の生成 OP では、リフレッシュしても「新しい」アクセストークン／ID Token の値が
初回発行分とバイト単位で同一**になる（テストが in-process で高速なため同一秒に収まる）。
既存の契約テストは値の一意性を一切アサートしていないため、これを検出できずにパスしている。

**(c) 対照**: 同じ payload を `PS256`（RSA-PSS）で署名すると署名バイト列は毎回変わる
（salt により確率的）。したがって本問題は「RS256 を使う限り」成立する。

## 5. 現在の実装との差分

### 満たしていること

- Opaque アクセストークン（`accessTokenFormat: 'opaque'`）は 256bit 乱数で、一意性は実質的に保証される
- リフレッシュトークン・認可コード・`grantId` はいずれも `generateRandomString(32)` で生成されるため衝突しない
  （`packages/core/src/authorization-code.ts:90-91`, `token-response.ts:587`）
- 2026-06-21 の Conformance 実測（📌 `tasks/done/p1-basic-op-static-client-conformance-result-2026-06-21.md`）では
  `oidcc-refresh-token` は PASSED。Suite のステップ間に十分な経過時間があったためと考えられる

### 不足している可能性があること

- 🟠 **grant 単位失効の取りこぼし（セキュリティ）**: 同一クライアント・同一 subject・同一 scope・同一 aud の
  認可コードフローが 2 本、同じ秒に token endpoint へ到達すると（例: ユーザーが 2 タブで同時にログインを完了、
  あるいは自動テスト・負荷試験）、`grantId` は異なるのにアクセストークン文字列が同一になる。
  後勝ちの `accessTokenStore.set` が先の grant の `grantId` を上書きするため、
  **先の grant に対する `revokeByGrantId`（認可コード再利用検知・同意撤回・RT ファミリー失効）が
  そのトークンを失効できない**。ユーザーから見れば「revoke したのにトークンが生きている」状態になる。
- 🟠 **`claims` 認可コンテキストの黙示的破壊**: 4-3 のとおり refresh 経路は `claims: undefined` を書き込む。
  同一秒衝突が起きると、authorization_code 経路で保存された `claims` が refresh 経路の `undefined` で
  上書きされ、UserInfo の応答が無言で縮退する。
  （refresh で `claims` を引き継がないこと自体は 📌 `study-material/refresh-grant-claims-context-not-preserved.md` の論点。
  本ファイルの差分は「衝突によって**既存レコードまで壊れる**」点。）
- 🟠 **「リフレッシュしても値が変わらない」**: 4-4(b) のとおり、生成 OP の実フローで
  rotation 後のアクセストークンが初回と同一文字列になることを確認済み。
  リフレッシュはアクセストークンを更新する操作だと利用者は期待するが、この条件下では
  **新しい秘密が発行されない**。初回アクセストークンが漏洩していた場合、リフレッシュしても
  同じ値が返るため、漏洩の影響をリフレッシュで断ち切れない。
- 🟡 **Basic OP conformance の潜在的 flakiness**: `CompareIdTokenClaims` は `iat` 同値を明示的に失敗にする。
  ローカル・CI のように OP 応答が速い環境で `oidcc-refresh-token` を再実行したとき、
  初回トークン発行と refresh が同じ秒に入れば FAILED になりうる。
  2026-06-21 の実測では PASSED だったが、4-4(b) が示すとおり in-process では確実に同一秒に入るため、
  「一度 PASSED だから大丈夫」とは言えない性質の失敗である。
- 🟡 **一意性が契約として存在しない**: `AccessTokenIssuer` インターフェース
  （`packages/core/src/access-token-issuer.ts:31-34`）の JSDoc は「発行ごとに一意な値を返すこと」を
  要求していない。利用者が独自 issuer を差し替える際の前提が明示されていない。

### 実装はあるが仕様上の確認が必要なこと

- RFC 9068 §2.2 は `jti` を REQUIRED としており、現状の JWT アクセストークンは**この点で仕様非準拠**。
  📌 `tasks/p2-jwt-access-token-jti.md` が既に立っているが、そちらは「introspection で `jti` を返せるようにする」
  という文脈で、本ファイルが指摘する**衝突・失効取りこぼし**は動機として書かれていない。

### 相互運用性の観点

- 一部の RP / リソースサーバはアクセストークンを**キャッシュキーやログの相関 ID**として使う。
  同じ文字列が別の認可付与を指しうる状態は、RP 側のキャッシュ汚染・監査ログの誤集計を招く。
- Basic OP として提供する上では、`iat` 秒解像度そのものは仕様どおり（`NumericDate` は秒）であり、
  問題は「秒解像度 × 可変要素なし × 決定的署名」の 3 条件が重なることにある。

## 6. 改善・追加を検討する理由

- **なぜ検討すべきか**: 本問題は「めったに起きないが、起きたときに**セキュリティ機構（失効）が黙って効かなくなる**」
  タイプの不具合である。エラーもログも出ないため、利用者は検知できない。
  本リポジトリは「仕様準拠を信頼性のシグナルとして維持する（Fidelity）」ことを差別化軸に掲げており、
  失効が取りこぼす経路を放置するのは軸に反する。
- **Basic OP 必須か拡張か**: `jti` 自体は Basic OP 認定の必須項目ではない（RFC 9068 は OIDC Core の
  認定要件ではない）。しかし `oidcc-refresh-token` の `iat` 相違要求は **Basic OP プロファイル内の要求**であり、
  こちらは認定に直結する。したがって本トピックは「認定リスク（`iat`）」と
  「認定外だが重要なセキュリティ（トークン値衝突）」の 2 層を持つ。
- **導入しやすさ**: 発行の入口が `buildAccessTokenPayload` / `AccessTokenIssuer` の 2 箇所に集約されており、
  可変要素の追加は局所的。既に `AccessTokenInfo.jti?: string` の型枠が存在する
  （📌 `tasks/p2-jwt-access-token-jti.md` の「現状の実装」節）ため、ストア側の受け皿も揃っている。
- **導入しにくさ**: `generateTokenResponse()` の戻り値には `jti` を返す口が無く、呼び出し側が
  「発行した JWT の中の `jti`」をストアへ保存できない。ここは既存タスクでも「内部メタデータ伝播方法を見直す」
  として未解決になっている。生成 OP 側（`packages/cli` テンプレート）と各 sample の再生成も伴う。
- **利用者のメリット**: 失効が確実に効く／introspection で `jti` を返せる／
  監査ログでトークンを一意に相関できる。
- **実装しない場合に残る制約**: 同時発行時の失効取りこぼしと、conformance 再実行時の非決定的失敗が残る。
  また `accessTokenFormat: 'jwt'`（既定）と `'opaque'` で一意性の保証レベルが異なるという
  文書化されていない非対称が残る。

## 7. 実装方針の候補（最終判断は人間が行う）

### 方針A: JWT アクセストークンに `jti` を付与する（RFC 9068 準拠と同時に解決）

- `buildAccessTokenPayload` で `jti = generateRandomString(16)`（128bit）を既定生成し、
  入力で明示指定もできるようにする。
- 利点: RFC 9068 §2.2 の REQUIRED を満たし、衝突も同時に解消する。📌 `tasks/p2-jwt-access-token-jti.md` と統合できる。
- 論点: 発行された `jti` を呼び出し側（ストア保存）へどう返すか。
  `buildAccessTokenPayload` の戻り値 payload に含まれるので、生成 OP は
  `accessTokenPayload.jti` をそのまま `accessTokenStore.set` へ渡せる（`generateTokenResponse` 合成関数側は別途要検討）。

### 方針B: 同一秒の再発行を検出して `iat` を進める（単調増加ガード）

- OP プロセス内で「直近に発行した `iat`」を保持し、同値なら +1 する。
- 利点: `jti` を導入せずとも ID Token の `iat` 相違要求（conformance）を満たせる。
- 欠点: `iat` が実時刻から乖離する／マルチインスタンスでは共有できず効果が限定的／
  アクセストークン文字列の衝突は解消するが、根本原因（可変要素の不在）は残る。**単独では推奨しにくい。**

### 方針C: 契約として明文化し、既定 issuer を Opaque に寄せる

- `AccessTokenIssuer` の JSDoc に「`issue()` は発行ごとに一意な値を返さなければならない」を契約として追加。
- 既定の `accessTokenFormat` を `'opaque'` にするかは別判断（JWT 既定は自己完結検証という利点があるため、
  安易に変えると利用者の期待を壊す）。
- 利点: 独自 issuer を差し替える利用者への前提提示になる。方針A と併用できる。

### 方針D: ID Token 側にも一意要素を入れる

- ID Token は保存されないため衝突自体は無害だが、`CompareIdTokenClaims` の `iat` 要求は残る。
- 方針A でアクセストークンが一意になれば `at_hash` が変わり、**ID Token もバイト単位では一意になる**。
  ただし `iat` は依然同値になりうるため、conformance の `iat` 要求は方針A では解消しない。
  → **方針A と方針B（または「refresh 時のみ `iat` 単調性を保証する」限定版）の併用**が必要かどうかが判断ポイント。

### 検討の分岐点（人間が決めること）

1. RFC 9068 の `jti` REQUIRED をこのリリーススコープで満たすか（📌 `study-material/RELEASE-v0.x-scope.md` との整合）
2. conformance の `iat` 相違要求を「運用上まず起きない」として受容するか、単調性ガードを入れるか
3. 一意性を core の契約として型・JSDoc に固定するか、利用者責務のままにするか

## 8. タスク案

- [ ] 4-4(a)（core 関数の直接呼び出し）を恒久的な回帰テストとして
      `packages/core/src/token-response.test.ts` に落とす。修正後は「同一入力でも
      アクセストークン文字列が異なる」ことを固定する（現状は同一になるため Red）
- [ ] 4-4(b) を生成 OP の `conformance.test.ts`（生成元は `packages/cli`）へ入れる:
      rotation 後の `access_token` が初回と異なること、ID Token の `iat` が初回と異なること。
      **現状は両方とも失敗する**（実測済み）
- [ ] `accessTokenStore` のキー衝突で `grantId` / `claims` が上書きされ、先の grant に対する
      `revokeByGrantId` が当該トークンを失効できないことを統合テストで再現する（Red）
- [ ] 方針A（`jti` 付与）を採る場合: `AccessTokenPayload` に `jti` を追加し、
      `buildAccessTokenPayload` で既定生成 → 生成 OP テンプレートで `accessTokenStore.set` へ保存 →
      introspection で返す、まで一気通貫にする（📌 `tasks/p2-jwt-access-token-jti.md` と統合して実施）
- [ ] `AccessTokenIssuer.issue()` の JSDoc に「発行ごとに一意な値を返すこと」を契約として明記する
- [ ] refresh 経路で再発行される ID Token の `iat` が初回と異なることを、
      生成 OP の `conformance.test.ts`（生成元は `packages/cli`）で固定するかを判断する
- [ ] `iat` 単調性ガード（方針B）を入れるか、入れないなら「同一秒 refresh では conformance が
      非決定的に落ちうる」ことを 📌 `study-material/basic-op-conformance-verification-plan.md` に注記する

## 9. 関連ファイル

- 📌 `tasks/p2-jwt-access-token-jti.md` — `jti` 実装タスク（本ファイルは動機と帰結を補強する）
- 📌 `study-material/token-expiry-boundary-and-opaque-lifetime-binding.md` — Opaque の有効期限バインディング
- 📌 `study-material/refresh-grant-claims-context-not-preserved.md` — refresh で `claims` を引き継がない論点
- 📌 `study-material/resolver-and-store-contract.md` — ストアの原子性・CAS 契約
- 📌 `tasks/done/p1-basic-op-static-client-conformance-result-2026-06-21.md` — 直近の Conformance 実測結果
