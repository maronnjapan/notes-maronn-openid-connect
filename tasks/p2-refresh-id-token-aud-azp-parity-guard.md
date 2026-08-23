# [P2] Refresh 再発行 ID Token の `aud` / `azp` 同一性（OIDC Core §12.2 MUST）をテストで固定し、破れる経路を塞ぐ

## ステータス

🟡 Medium / 未着手

## 背景

OIDC Core 1.0 §12.2 は、refresh で ID Token を返す場合に **`aud` は初回認証時の ID Token と同じ値でなければならない（MUST）**、**`azp` も同じ値でなければならず、初回に `azp` が無かったなら新しい ID Token にも `azp` があってはならない（MUST NOT）** と規定する。

現状は次の 2 点が問題になっている。

### (1) `RefreshTokenInfo.azp` が実装上デッドフィールドになっている

生成 OP の refresh token 永続化（`samples/hono-cloudflare/src/oidc-provider/routes/token.ts:651`）:

```ts
azp: validatedRequest.grantType === 'refresh_token' ? validatedRequest.azp : undefined,
```

**初回発行（authorization_code grant）では常に `undefined` が書かれる。** refresh 側は直前の RT の値を引き継ぐだけなので、値が入る経路が存在しない。一方 `RefreshTokenInfo.azp` の JSDoc（`packages/core/src/token-request.ts:234-238`）は「refresh 時にも同じ値を保持する」と書いており、**実装と矛盾している**。`acr` / `amr` が `resolvedAcr` / `resolvedAmr` から実値を受け取っているのと対照的。

### (2) 公開オプション `idTokenAudiences` を使うと §12.2 の 2 つの MUST を同時に破る

core は ID Token の `aud` を複数化する公開オプション `TokenResponseOptions.idTokenAudiences`（`packages/core/src/token-response.ts:74`）を持ち、`buildIdTokenAudience`（同 :239-246）が「1 件なら単一文字列 + `azp` なし / 複数なら配列 + `azp=clientId`」を正しく合成する。

しかし **ID Token の audience 集合を refresh へ引き継ぐ永続化フィールドが `RefreshTokenInfo` に無い**（`audience` フィールドはアクセストークン用で別物）。したがって利用者が authorization_code 経路にだけ `idTokenAudiences` を渡すと:

| 経路 | `aud` | `azp` |
|---|---|---|
| authorization_code | `["client", "extra"]`（配列） | `"client"` |
| refresh_token | `"client"`（単一文字列） | なし |

となり §12.2 に違反する。OIDF Conformance Suite の `CompareIdTokenClaims` は `azp` の有無の一貫性を判定するため（`tasks/p3-basic-op-conformance-module-list-confirmation.md` の記録）、この構成の OP は認定でも落ちる。

**既定生成物（`idTokenAudiences` 未使用）では `aud` が常に単一 `clientId`、`azp` が常に不在なので §12.2 は自明に成立する。** 破れるのは利用者が公開 API どおりに使ったときだけであり、それを警告する記述がどこにも無い。

仕様上の位置づけ・影響範囲・方針比較の詳細は `study-material/done/refresh-id-token-aud-azp-preservation.md` を参照（ここでは繰り返さない）。

### 本タスクのスコープ

本タスクは **「既定の正しさを固定し、破れる経路を可視化する」ところまで**を対象とする。

- ✅ 対象: (1) の矛盾解消、既定構成での `aud` / `azp` 同一性の契約テスト化、`idTokenAudiences` への警告記載
- ❌ 対象外: multi-audience ID Token を refresh でも正しく再現する本格対応（`study-material/done/refresh-id-token-aud-azp-preservation.md` の方針 A / B / C の選択）。**どの方針を採るかが未決定のため、本タスクではタスク化しない。**

本タスクを先に済ませることで、方針が決まった時点で既に回帰テストが揃っている状態になる。

## 対象ファイル

- `packages/core/src/token-request.ts`（`RefreshTokenInfo.azp` の JSDoc）
- `packages/core/src/token-response.ts`（`TokenResponseOptions.idTokenAudiences` の JSDoc）
- `packages/cli/src/frameworks/hono/templates.ts`（`tokenRouteTemplate` の `refreshTokenPersistenceBlock`。`web-standard/templates.ts` が再エクスポートするため express / fastify / nextjs にも反映される）
- `packages/cli` 内の `conformance.test.ts` 生成コード（`samples/*/conformance.test.ts` の生成元。**生成物を直接編集しないこと**）
- `packages/core/src/token-response.test.ts`
- `samples/*/src/oidc-provider/routes/token.ts`（再生成される生成物）

## 仕様参照

- **OpenID Connect Core 1.0 §12.2 Successful Refresh Response** — refresh で ID Token を返す場合の要件。本タスクに関係するのは次の 2 点。
  - `aud` の値は初回認証時に発行した ID Token と同じでなければならない（MUST）。
  - `azp` の値も同じでなければならず、初回の ID Token に `azp` が無かった場合は新しい ID Token にも `azp` があってはならない（MUST NOT）。

  列挙全体は `study-material/done/refresh-id-token-nonce-omission.md` §3 に整理済み。
  — https://openid.net/specs/openid-connect-core-1_0.html#RefreshTokens
- **OpenID Connect Core 1.0 §2 ID Token** — `aud` が単一でそれが authorized party と同一なら `azp` は含めるべきでない（SHOULD NOT）。
  — https://openid.net/specs/openid-connect-core-1_0.html#IDToken
- **OpenID Connect Core 1.0 §3.1.3.7 ID Token Validation (4)-(5)** — クライアントは `aud` に自身の client_id が含まれることを検証し、`aud` が複数値のときは `azp` を要求する（REQUIRED）。`aud` の要素数と `azp` の有無は連動する。
  — https://openid.net/specs/openid-connect-core-1_0.html#IDTokenValidation
- **Basic OP certification** — 既定生成物は `aud` 単一・`azp` 不在で一貫しているため、**認定合否には影響しない**。本タスクは Fidelity（公開 API を仕様どおり使ったら仕様違反にならないこと）の担保。

## 現状の実装

### 発行側の合成（正しい）

`packages/core/src/token-response.ts:239-246`

```ts
export function buildIdTokenAudience(input: IdTokenAudienceInput): IdTokenAudienceResult {
  const { clientId, additional } = input;
  const deduped = [...new Set([clientId, ...(additional ?? [])])];
  if (deduped.length <= 1) {
    return { aud: clientId };            // 単一 → azp なし（§2 SHOULD NOT）
  }
  return { aud: deduped, azp: clientId }; // 複数 → azp 必須（§3.1.3.7）
}
```

### 永続化側（ID Token の aud を運べない / azp が入らない）

`packages/core/src/token-request.ts:173-239` の `RefreshTokenInfo`:

```ts
audience?: string[];   // L207 — アクセストークンの aud。ID Token の aud ではない。
azp?: string;          // L238 — JSDoc は「refresh 時にも同じ値を保持する」
                       //         → 実際には値が入る経路が無い（下記）
```

ID Token の追加 audience に相当するフィールドは存在しない。

### 生成 OP（azp の書き込みが常に undefined）

`packages/cli/src/frameworks/hono/templates.ts:3060` → 生成物 `samples/hono-cloudflare/src/oidc-provider/routes/token.ts:651`

```ts
azp: validatedRequest.grantType === 'refresh_token' ? validatedRequest.azp : undefined,
//                                                    ^^^^^^^^^^^^^^^^^^^^   ^^^^^^^^^
//                                                    出所は必ず undefined    初回は常に undefined
```

### 生成 OP（ID Token 組み立てに idTokenAudiences を渡さない）

同生成物の ID Token 発行ブロック:

```ts
const idTokenPayload = buildIdTokenPayload({
  issuer: config.issuer,
  subject,
  clientId: validatedRequest.clientId,
  scope: validatedRequest.scope,
  expiresIn: config.idTokenExpiresIn,
  issuedAt,
  atHash,
  nonce,
  authTime,
  acr: resolvedAcr,
  amr: resolvedAmr,
  // ← idTokenAudiences は authorization_code / refresh のどちらでも渡されない
});
```

## 修正方針

- [ ] `RefreshTokenInfo.azp` の JSDoc を実装に合わせて訂正する。現時点で値が入る経路が無いこと、および multi-audience 対応時に埋める予定のフィールドであることを明記する

  ```ts
  /**
   * Authorized Party。multiple-audience の ID Token を発行する場合に必須
   * （OIDC Core 1.0 §2 / §3.1.3.7）。
   *
   * 注意（現状）: 生成 OP は ID Token の aud を常に単一の clientId とするため azp を発行せず、
   * 初回発行時にこのフィールドへ書かれる値は常に undefined である。rotation 時の引き継ぎ経路
   * だけが実装されており、値の供給元は未実装。multi-audience ID Token を refresh でも
   * §12.2 のとおり再現する対応は
   * `study-material/done/refresh-id-token-aud-azp-preservation.md` の方針 A を参照。
   */
  ```

- [ ] `TokenResponseOptions.idTokenAudiences` の JSDoc に、refresh を伴う構成で使うと OIDC Core §12.2 の `aud` / `azp` 同一性を満たせない旨の警告を追記する（現状の JSDoc は発行時の合成規則しか説明していない）
- [ ] 生成テンプレートの `azp:` 行に、初回発行では常に `undefined` になる理由と、multi-audience 対応時にここが供給点になることをコメントで明示する
- [ ] `study-material/resolver-and-store-contract.md` に「refresh token store は ID Token の audience 集合を保存しない（＝ multi-audience ID Token は refresh で再現できない）」という現時点の契約を明記する

## テスト要件

### `packages/core`

- [ ] `buildIdTokenAudience({ clientId })` は `aud` を単一文字列で返し `azp` を返さない（回帰）
- [ ] `buildIdTokenAudience({ clientId, additional: ['extra'] })` は `aud` を `['client','extra']`、`azp` を `'client'` で返す（回帰）
- [ ] `buildIdTokenAudience({ clientId, additional: [clientId] })` は重複解決の結果 1 件になるため `aud` を単一文字列で返し `azp` を返さない
- [ ] `generateTokenResponse` に `idTokenAudiences` を渡して発行した ID Token の `aud` / `azp` と、同じ subject / clientId で `idTokenAudiences` を渡さずに発行した ID Token の `aud` / `azp` が**一致しない**ことをテストで固定し、§12.2 を満たせない条件を明示する（現状の制約を可視化する回帰テスト）

### `samples/*/conformance.test.ts`（生成元は `packages/cli`）

- [ ] authorization_code grant で得た ID Token の `aud` が `clientId` と等しい単一文字列であり、`azp` クレームが存在しない
- [ ] 同じ grant を refresh して得た ID Token の `aud` が **authorization_code のものと完全一致**し、`azp` クレームが存在しない（OIDC Core §12.2 の 2 つの MUST）
- [ ] refresh を 2 回連鎖させても `aud` / `azp` が変わらない
- [ ] refresh 時に永続化される refresh token の `azp` が `undefined` であること（現時点の仕様として固定し、multi-audience 対応時にこのテストを更新する目印にする）

### `packages/cli`

- [ ] 生成コードの `azp:` 行に上記の説明コメントが出力されることを文字列テストで固定する

## 完了条件

- `pnpm --filter @maronn-openid-connect/core test` がパスすること
- `pnpm --filter @maronn-openid-connect/cli test` がパスすること
- `pnpm --filter "./samples/*" test` で各 sample の `conformance.test.ts` がパスすること
- `pnpm typecheck` がパスすること
- 4 つの sample の生成物を再生成しても差分が安定していること
- `packages/core` の JSDoc に `idTokenAudiences` と `RefreshTokenInfo.azp` の現状制約が記載されており、実装と矛盾する記述が残っていないこと
