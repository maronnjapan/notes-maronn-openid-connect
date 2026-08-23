# [P2] `claims` パラメータ `id_token` メンバーの個別標準クレームを ID Token に反映する

## ステータス

🟡 Medium / 未着手

## 背景

OIDC Core §5.5 は `claims` リクエストパラメータの `id_token` トップレベルメンバーを
「列挙した個別クレームを **ID Token に返す**ことの要求」と定義する。§5.4 も、`claims` パラメータを使うと
クレームの返却先（UserInfo か ID Token か）と対象を個別指定できると述べる。

本リポジトリは `claims.id_token` メンバーを **`acr` の seed 用途にしか使っておらず**、`email` / `name` などの
標準クレームを `id_token` メンバーで要求しても ID Token に載らない。一方 UserInfo エンドポイントは
`userinfo` メンバーを honor して要求クレームを追加している（`handleUserInfoRequest` の step 5）。この
**ID Token 側と UserInfo 側の非対称**により、`claims_parameter_supported: true` の広告と実挙動が一部食い違う。

Basic OP 認定の必須ではないが、`claims` 対応が「半分」になっており、他 IdP からの移行検証（本ライブラリの
コンセプト）でつまずきやすい。詳細な検討は
`study-material/claims-id-token-member-individual-claims-in-id-token.md` を参照。

`sub` の値要求は別トピック（セキュリティ意味を持つバインディング）として
`study-material/claims-sub-value-request-binding.md` で扱う。本タスクは `sub` を除く標準クレームの
反映に限定する。

## 対象ファイル

- `packages/core/src/token-response.ts`（`generateTokenResponse` の ID Token ペイロード組み立て）
- `packages/core/src/token-response.test.ts`（テスト追加）
- `packages/core/src/userinfo.ts`（`SCOPE_CLAIMS_MAP` / `matchesRequestedValue` の再利用・export 調整があれば）
- `packages/cli/src/frameworks/**/templates.ts` と `samples/*/conformance.test.ts`（生成元経由で契約テスト更新）

## 仕様参照

- OpenID Connect Core 1.0 §5.5「Requesting Claims using the claims Request Parameter」
  - 「**id_token** — ... Requests that the listed individual Claims be returned in the ID Token.」
- OpenID Connect Core 1.0 §5.4「Requesting Claims using Scope Values」
  - scope 由来クレームの既定返却先（UserInfo）と、`claims` パラメータによる返却先の個別指定
- OpenID Connect Core 1.0 §5.5.1「Individual Claims Requests」
  - `value` / `values` / `essential`。Essential でも取得不可時に **エラーを返してはならない（MUST NOT）**

## 現状の実装

```ts
// packages/core/src/token-response.ts（generateTokenResponse）
// L355-361: ID Token のユーザクレームは scope フィルタ結果のみ
if (userClaims) {
  const filtered = filterClaimsByScope(userClaims, scope);
  Object.assign(idTokenPayload, filtered);
}

// L299-311: claims.id_token は acr の seed としてのみ参照
if (effectiveRequestedAcrValues === undefined && claims?.id_token) {
  const acrEntry = claims.id_token['acr'];
  // ... acr.values only
}
// L120-125 doc: "Unknown id_token [members] are ignored."
```

対照的に UserInfo 側は `userinfo` メンバーを honor 済み:

```ts
// packages/core/src/userinfo.ts（handleUserInfoRequest, L423-441）
const response = filterClaimsByScope(userClaims, tokenInfo.scope);
const requestedClaims = getRequestedClaimNames(claimsParameter); // claimsParameter.userinfo のキー
for (const claimName of requestedClaims) {
  if (claimName === 'sub') continue;
  const value = userClaims[claimName];
  if (value === undefined || value === null) continue;
  const entry = claimsParameter?.userinfo?.[claimName] ?? null;
  if (!matchesRequestedValue(value, entry)) continue;
  (response as Record<string, unknown>)[claimName] = value;
}
```

## 修正方針

- [ ] `generateTokenResponse` の ID Token 組み立てで、`filterClaimsByScope` 直後・**プロトコルクレーム代入より前**に、
      `claims.id_token` の各キーを反映する処理を追加する（UserInfo 側と対称化）。
  ```ts
  if (userClaims) {
    const filtered = filterClaimsByScope(userClaims, scope);
    Object.assign(idTokenPayload, filtered);

    // OIDC Core §5.4 / §5.5: claims.id_token で要求された個別標準クレームを scope に依存せず反映する。
    // プロトコルクレーム代入(iss/sub/aud/exp/iat/at_hash/nonce/acr/amr/azp)は後段で上書きされるため安全。
    if (claims?.id_token) {
      for (const [claimName, entry] of Object.entries(claims.id_token)) {
        if (!ID_TOKEN_REQUESTABLE_CLAIMS.has(claimName)) continue; // 許可リスト（sub / acr / プロトコルは除外）
        const value = (userClaims as Record<string, unknown>)[claimName];
        if (value === undefined || value === null) continue;
        if (!matchesRequestedValue(value, entry)) continue;
        idTokenPayload[claimName] = value;
      }
    }
  }
  ```
- [ ] 反映対象は **既知標準クレームの許可リスト**（`SCOPE_CLAIMS_MAP` の値域＝`profile`/`email`/`address`/`phone` 系）に限定する。
      `sub` は除外（別タスク）。`acr` は既存 seed 経路が担うため二重処理しない。
- [ ] プロトコルクレーム（iss/sub/aud/exp/iat/at_hash/nonce/acr/amr/azp）が `claims.id_token` 経由で
      上書き・注入されないことを、代入順序（後段で上書き）と許可リストの二重で担保する。
- [ ] `matchesRequestedValue` / `deepEqual` を `userinfo.ts` から再利用する（必要なら export を追加）。
- [ ] discovery / README のコメントを実挙動に合わせて更新する（`id_token` メンバー対応済みと明記）。

## テスト要件

- [ ] `claims={"id_token":{"email":null}}` かつ `userClaims.email` あり → ID Token に `email` が載る
- [ ] `claims={"id_token":{"name":null,"email":null}}` → 両方載る
- [ ] `claims={"id_token":{"email":{"value":"a@example.com"}}}` で値一致 → 載る／値不一致 → 載らない（エラーにしない）
- [ ] `claims={"id_token":{"email":{"essential":true}}}` で `userClaims.email` 欠落 → エラーにならず単に省略
- [ ] `claims={"id_token":{"iss":null}}` 等プロトコルクレーム要求 → 正規の `iss` のまま（注入不可・許可リスト外）
- [ ] `claims={"id_token":{"sub":{"value":"X"}}}` → 本タスクでは `sub` を反映しない（別タスク管轄）
- [ ] `claims={"id_token":{"unknown_claim":null}}` → 無視される（許可リスト外）
- [ ] `acr` seed の既存挙動（`claims.id_token.acr.values` → resolver）が回帰しない
- [ ] `samples/*/conformance.test.ts` に「`id_token` メンバーで要求したクレームが ID Token に現れる」契約テストを追加
      （`conformance.test.ts` は直接編集せず `packages/cli` の生成元を変更する）

## 完了条件

- `pnpm --filter @maronn-openid-connect/core test` がパスすること
- 各 sample の `conformance.test.ts` がパスすること
- （余力があれば）`tests/e2e` に該当 E2E を追加し `pnpm test:e2e` がパスすること
