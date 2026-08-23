# [P2] 認可リクエストの `acr_values` を Token Endpoint の `AcrResolver` まで伝播する

## ステータス

🟡 Medium / 未着手

## 背景

`AcrResolver`（T-015 done）は型コメントで「認可リクエストの `acr_values` を `requestedAcrValues` として受け取り、それを根拠に ID Token の `acr` / `amr` を決定する」と約束している（`token-response.ts` L17-20, L90-92）。しかし `acr_values` は **認可リクエストのバリデーション後、Auth Transaction には保存されるものの、`completeAuthTransaction` → 認可コード → Token Endpoint の経路で脱落**しており、実フローでは `requestedAcrValues` が常に `undefined` になる。

結果として、利用者が `AcrResolver` を実装しても **`acr_values` パラメータ単体では resolver に何も伝わらない**。同義の `claims={"id_token":{"acr":{"values":[...]}}}` 経由（OIDC Core §5.5.1.1 で equivalent）だけは届くため、要求方法によって挙動が割れる非対称が生じている。

検討の経緯・方針比較・仕様根拠は `study-material/done/acr-values-request-propagation-to-id-token.md` を参照。本タスクは最小配線（study-material の方針 A）に絞る。`acr_values` と `claims.id_token.acr.values` の合流規則（方針 B）と essential フラグの伝播（方針 C）は API 設計合意が必要なため対象外とし、必要なら別タスク化する。

Basic OP 認定の必須要件ではない（§15.1 は `acr_values` を「エラーにしない」までが MUST）。位置づけは **公開済み拡張機能 `AcrResolver` の end-to-end 整合性修正**。

## Conformance 調査メモ

`tests/conformance` の直近実行でも同じ差分が warning として出ている。

- Current result artifact: `tests/conformance/results/oidcc-basic-certification-test-plan-discovery-static_client-0zMCWqum8rQnj-21-Jun-2026.zip`
- Previous result artifact: `tests/conformance/results/oidcc-basic-certification-test-plan-discovery-static_client-5XeV397bGW050-17-Jun-2026.zip`
- Module: `oidcc-ensure-request-with-acr-values-succeeds`
- Result: `FINISHED / WARNING`
- Warning: `An acr value was requested using acr_values, so the server 'SHOULD' return an acr claim, but it did not.`

OIDF Conformance Suite `OIDCCEnsureRequestWithAcrValuesSucceeds` は、`acr_values` で要求された値のいずれかを ID Token の `acr` に返すことを warning 条件として確認している。Basic OP の最低要件は「エラーにしない」だが、Basic OP static-client result を warning なしに近づけるには本タスクの実装が必要。

## 対象ファイル

- `packages/core/src/auth-transaction.ts`（`AuthorizationResponseParams` / `completeAuthTransaction`）
- `packages/core/src/authorization-code.ts`（`AuthorizationCodeData` / `createAuthorizationCode`）
- `packages/core/src/token-request.ts`（`AuthorizationCodeInfo` / `ValidatedAuthorizationCodeRequest` / `validateTokenRequest`）
- `samples/*/src/oidc-provider/routes/token.ts`（`generateTokenResponse` 呼び出し。CLI 生成物なので修正元は `packages/cli`）
- `packages/cli/src/frameworks/hono/templates.ts`（生成 Provider のトークンルートテンプレート）
- 各 `*.test.ts`（`auth-transaction.test.ts` / `token-request.test.ts` / `token-response.test.ts`）

## 仕様参照

- OIDC Core 1.0 §3.1.2.1 — `acr_values`: 「Space-separated string that specifies the acr values that the Authorization Server is being requested to use for processing this Authentication Request, with the values appearing in order of preference.」 acr は本パラメータにより Voluntary Claim として要求される。
- OIDC Core 1.0 §5.5.1.1 — `claims` の `id_token.acr.values` は `acr_values` と equivalent な要求。
- OIDC Core 1.0 §2 — `acr` は Voluntary Claim。
- OIDC Core 1.0 §15.1 — `acr_values` は「エラーにしない」が最低要件（処理は MUST ではない）。

## 現状の実装

`acr_values` は authorization → transaction までは保持されるが、その先で脱落する:

```ts
// auth-transaction.ts L221-223: transaction には入る ✅
if (validatedRequest.acrValues !== undefined) {
  transaction.acrValues = validatedRequest.acrValues;
}

// auth-transaction.ts L441-474: completeAuthTransaction は acrValues を転記しない 🔴
// AuthorizationResponseParams 型にも acrValues フィールドが無い（L142-155）
const result: AuthorizationResponseParams = {
  redirectUri, redirectUriExplicit, clientId, scope, codeChallenge, codeChallengeMethod,
  // state / nonce / audience / claims は転記するが acrValues は無い
};
```

```ts
// token.ts L237-262: acrResolver と claims は渡すが requestedAcrValues は渡していない 🔴
await generateTokenResponse({
  ...,
  acrResolver: validatedRequest.grantType === 'authorization_code' ? acrResolver : undefined,
  claims: validatedRequest.grantType === 'authorization_code' ? validatedRequest.claims : undefined,
  // requestedAcrValues が無い → resolver は acr_values を受け取れない
});
```

`token-response.ts` の `effectiveRequestedAcrValues`（L260-269）は引数 `requestedAcrValues` か `claims.id_token.acr.values` のいずれかから決まるが、`acr_values` パラメータ由来の値は供給経路が存在しない。

## 修正方針

- [ ] `AuthorizationResponseParams`（auth-transaction.ts）に `acrValues?: string` を追加する。
- [ ] `completeAuthTransaction` で `transaction.acrValues` を `AuthorizationResponseParams.acrValues` に転記する（`nonce` / `audience` 等と同じ並び）。
- [ ] `AuthorizationCodeData`（authorization-code.ts）に `acrValues?: string` を追加し、`createAuthorizationCode` で `authorizationResponse.acrValues` を転記する。
- [ ] `AuthorizationCodeInfo` / `ValidatedAuthorizationCodeRequest`（token-request.ts）に `acrValues?: string` を追加し、`validateTokenRequest` の authorization_code 経路で `authCode.acrValues` を返り値へ含める。
- [ ] sample / cli テンプレートのトークンルートで、authorization_code grant のとき `requestedAcrValues: validatedRequest.acrValues` を `generateTokenResponse` に渡す。
- [ ] refresh_token grant では従来どおり `requestedAcrValues` を渡さず、保存済み `acr` / `amr` を直接引き継ぐ（§12.1）挙動を変えない。

実装イメージ:

```ts
// auth-transaction.ts completeAuthTransaction 内
if (transaction.acrValues !== undefined) {
  result.acrValues = transaction.acrValues;
}

// token.ts generateTokenResponse 呼び出し
requestedAcrValues:
  validatedRequest.grantType === 'authorization_code'
    ? validatedRequest.acrValues
    : undefined,
```

## テスト要件

- [ ] `auth-transaction.test.ts`: `acrValues` を持つ transaction を `completeAuthTransaction` に通すと `AuthorizationResponseParams.acrValues` に保持されること。
- [ ] `token-request.test.ts`: authorization_code grant で、`acrValues` を持つ認可コードを検証すると `ValidatedAuthorizationCodeRequest.acrValues` に引き継がれること。
- [ ] `token-response.test.ts`: `requestedAcrValues='loa2'` を渡すと `AcrResolver` が `requestedAcrValues='loa2'` を受け取ること（resolver 呼び出し引数を検証）。
- [ ] `token-response.test.ts`: `requestedAcrValues` 不在 + `claims.id_token.acr.values=['loa2']` のとき従来どおり `claims` 由来値が resolver に渡ること（既存挙動の固定）。
- [ ] refresh_token grant では `requestedAcrValues` が渡されず、保存済み `acr` / `amr` がそのまま ID Token に入ること（回帰防止）。

## 完了条件

`pnpm --filter @maronn-openid-connect/core test` と生成 Provider（sample）のテストがパスし、上記テストが追加されていること。`acr_values=<値>` を送った認可フローで、`AcrResolver` の `requestedAcrValues` にその値が届くことが統合テストで確認できること。
