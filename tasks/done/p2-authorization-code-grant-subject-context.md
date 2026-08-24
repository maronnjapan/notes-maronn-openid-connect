# [P2] `authorization_code` グラントの検証結果に `subject` / `auth_time` を含める

## ステータス

✅ 完了

方針 A（`AuthorizationCodeInfo` / `ValidatedAuthorizationCodeRequest` への追加）で実装した。

- core: `AuthorizationCodeInfo` に `subject: string`（必須）と `authTime?: number` を追加し、`buildValidatedAuthorizationCodeRequest` が転記する。resolver の JSDoc に「発行時の認証コンテキストを返す責務」と「used=true 契約の目的は再利用検知 cascade のみ」を明記した
- cli: token ルートの消費済みコード再取得ブロックを削除し、`validatedRequest.subject` / `validatedRequest.authTime` を使う形へ変更。token ルートは `authCodeStore` 自体を参照しなくなった。`authTime === undefined` のガードは refresh token 発行ブロックの既存チェック（`rtAuthTime === undefined` → `invalid_grant`）に一本化した
- 生成 conformance テストへ `subjectContextConformanceBlock`（sub 一致・auth_time が認可時記録値と一致・物理削除ストアでの発行継続）を追加し、hono / web-standard 両テンプレートに配線。4 sample を再生成した
- semver: `AuthorizationCodeInfo.subject` 必須化は独自 resolver 実装者に破壊的なため core は minor（0.x）とし、移行手順を changeset に記載。cli は生成コードの変更のため patch
- 検証: core 1172 / cli 868 / experimental 314、conformance 212+134+134+132、E2E 35+16+16+16、typecheck、ci-gate / supply-chain / release-contract すべて green

## 背景

core の Token Endpoint 検証が返す判別共用体 `ValidatedTokenRequest` は、grant 間で運ぶ情報が非対称である。

- `ValidatedRefreshTokenRequest` は `subject` / `authTime` / `nonce` / `acr` / `amr` / `azp` を含む
- `ValidatedAuthorizationCodeRequest` は `subject` も `authTime` も含まない

`AuthorizationCodeInfo`（resolver が返す型）にも `subject` / `authTime` が無い。一方、発行側の `AuthorizationCodeData` にはどちらも存在する。すなわち **発行時に保存された認証コンテキストが、検証結果の型で落ちている**。

その結果、生成 OP は認可コードを `consumeAuthorizationCode`（`used=true` 化）した**直後に、同じ認可コードをストアからもう一度読み直して** `subject` / `authTime` を取得している。

問題:

- ID Token の `sub` は REQUIRED（OIDC Core §2）であり、authorization_code grant では ID Token 発行が必須（§3.1.3.3）。**Token Endpoint が必ず知らねばならない情報を core が返さない**
- 生成 OP が「消費済みレコードを読み直せる」ことに依存しているが、`revokeAuthorizationCode` の JSDoc にはその前提が書かれていない（書かれているのは再利用検知 cascade のための契約のみ）。物理削除で実装した利用者は、cascade の欠落だけでなく**正常なトークン発行そのものが `invalid_grant` で失敗する**
- 検証時に読んだレコードと再取得したレコードが別スナップショットになるため、理論上の TOCTOU の窓が生じる
- core を直接使う利用者（CLAUDE.md いわく「高度な組み込みユースケース向け」）は、`sub` を得るための回避策を自前で用意する必要がある

詳細な検討は `study-material/done/authorization-code-grant-subject-context-omission.md` を参照。本タスクは同ファイルの**方針 A（`AuthorizationCodeInfo` / `ValidatedAuthorizationCodeRequest` に追加する）**を実装する。

## 対象ファイル

- `packages/core/src/token-request.ts`（`AuthorizationCodeInfo` / `ValidatedAuthorizationCodeRequest` / `AuthorizationCodeResolver` の JSDoc）
- `packages/core/src/authorization-code-grant.ts`（`buildValidatedAuthorizationCodeRequest`）
- `packages/core/src/token-request.test.ts` / `packages/core/src/token-request-steps.test.ts`（テスト追加）
- `packages/cli/src/frameworks/hono/templates.ts`（token ルートの再取得ブロック削除。`samples/*/src/oidc-provider` を直接編集しないこと）
- `.changeset/`（`packages/core` の型変更に対する changeset）

## 仕様参照

- **OpenID Connect Core 1.0 §2 ID Token** — https://openid.net/specs/openid-connect-core-1_0.html#IDToken
  `sub` は REQUIRED。`auth_time` は `max_age` が要求された場合、または `require_auth_time` が登録されている場合に REQUIRED
- **OpenID Connect Core 1.0 §3.1.3.3 Successful Token Response** — https://openid.net/specs/openid-connect-core-1_0.html#TokenResponse
  authorization_code grant のトークンレスポンスは `id_token` を含む
- **OpenID Connect Core 1.0 §12.1** — https://openid.net/specs/openid-connect-core-1_0.html#RefreshingAccessToken
  refresh 側が `subject` / `authTime` を検証結果に載せている設計根拠
- **RFC 6749 §4.1.2 / §4.1.3** — https://www.rfc-editor.org/rfc/rfc6749#section-4.1.2
  認可コードは resource owner の認可を表す。Token Endpoint はコードと引き換えにトークンを発行する

## 現状の実装

`packages/core/src/token-request.ts`:

```ts
export interface AuthorizationCodeInfo {
  code: string; grantId: string; clientId: string;
  redirectUri: string; redirectUriExplicit: boolean;
  scope: string[];
  codeChallenge?: string; codeChallengeMethod?: 'S256';
  expiresAt: number; used: boolean;
  nonce?: string; audience?: string[]; acrValues?: string; claims?: ClaimsParameter;
  // subject / authTime が無い
}
```

`packages/core/src/authorization-code-grant.ts`:

```ts
export function buildValidatedAuthorizationCodeRequest(
  code, authorizationCode, authenticatedClientId, codeVerified,
): ValidatedAuthorizationCodeRequest {
  return {
    grantType: 'authorization_code',
    clientId: authenticatedClientId,
    code, grantId: authorizationCode.grantId,
    redirectUri: authorizationCode.redirectUri,
    scope: authorizationCode.scope,
    nonce: authorizationCode.nonce,
    audience: authorizationCode.audience,
    acrValues: authorizationCode.acrValues,
    claims: authorizationCode.claims,
    codeVerified,
    // subject / authTime を返さない
  };
}
```

生成 OP（`packages/cli/src/frameworks/hono/templates.ts` の token ルート、`consumeAuthorizationCode` の後）:

```ts
if (validatedRequest.grantType === 'authorization_code') {
  const authCode = await authCodeStore.get(validatedRequest.code);   // ← 消費済みコードの再取得
  if (!authCode?.subject || !authCode.authTime) {
    throw new TokenError(TokenErrorCode.InvalidGrant, 'Authorization code missing required subject context');
  }
  subject = authCode.subject;
  authTime = authCode.authTime;
  nonce = validatedRequest.nonce;
} else {
  subject = validatedRequest.subject;      // ← refresh 側は型から直接取れる
  authTime = validatedRequest.authTime;
  nonce = undefined;
}
```

`!authCode.authTime` は `authTime === 0` を falsy として扱う点も不正確（実運用では 0 にならないが、存在チェックとしては誤り）。

## 修正方針

- [x] **`AuthorizationCodeInfo` に認証コンテキストを追加する**
  - [x] `subject: string` を**必須**で追加する。JSDoc に「発行時に確定した End-User 識別子。ID Token の `sub` の源であり、authorization_code grant では必ず存在する」と記す
  - [x] `authTime?: number` を追加する。JSDoc に「発行時の認証時刻（Unix epoch 秒）。ID Token の `auth_time` の源。`max_age` 要求時 / `require_auth_time` 登録時に必須（OIDC Core §2）」と記す
- [x] **`ValidatedAuthorizationCodeRequest` に転記する**
  - [x] `subject: string` / `authTime?: number` を追加し、`buildValidatedAuthorizationCodeRequest` で `authorizationCode` から転記する
  - [x] refresh 側（`ValidatedRefreshTokenRequest`）とフィールド名を揃える（`subject` / `authTime`）
- [x] **生成テンプレートから再取得を削除する**
  - [x] `authCodeStore.get(validatedRequest.code)` のブロックを削除し、`subject = validatedRequest.subject` / `authTime = validatedRequest.authTime` にする
  - [x] `authTime === undefined` のときのガードは、refresh token 発行ブロックの既存チェック（`rtAuthTime === undefined` → `invalid_grant`）に一本化できるか確認する
    - 一本化した。ID Token 側は `auth_time` が省略されるだけで、`max_age` / `require_auth_time` の無い要求では仕様適合（OIDC Core §2）。生成 OP の実フローでは `createAuthorizationCode` が `authTime` を必須で受け取るため未確定になる経路は無い
- [x] **`AuthorizationCodeResolver` の JSDoc を更新する**
  - [x] `findAuthorizationCode` が `subject` を返す責務を持つことを明記する
  - [x] `revokeAuthorizationCode` の「物理削除ではなく `used=true`」契約の理由が、再利用検知 cascade **のみ**であること（トークン発行のための再取得には依存しなくなったこと）を明記する
- [x] **semver / changeset の判断**
  - [x] `AuthorizationCodeInfo.subject` を必須にすることは、独自 `AuthorizationCodeResolver` を実装済みの利用者にとって破壊的変更（型エラー）になる。`RELEASE.md` の方針に照らして bump 種別（minor / major）を決め、changeset に移行手順を書く
    - 0.x 系のため minor とした（既存の破壊的変更を含む minor 運用（online refresh token）と同じ扱い）。移行手順を changeset に記載。core minor に対する experimental のペアリング changeset は既存のものが適用される
  - [x] `packages/experimental/src` の変更は含まないため、experimental の自動 changeset 規約（patch 固定）とは無関係

## テスト要件

`packages/core`:

- [x] `should return the subject stored on the authorization code`（`buildValidatedAuthorizationCodeRequest`）
- [x] `should return the authTime stored on the authorization code`
- [x] `should return undefined authTime when the authorization code has none`
- [x] `should expose subject on the validated request for the authorization_code grant`（`validateTokenRequest` 経由の統合的な確認。判別共用体の両枝で `subject` が取れること）
- [x] 既存テストの `AuthorizationCodeInfo` フィクスチャに `subject` を追加しても、他の検証（client binding / expiration / redirect_uri / PKCE / reuse cascade）の挙動が変わらないこと

`packages/cli`:

- [x] `should not re-read the authorization code store after consuming the code`（生成された token ルートに `authCodeStore.get(` の呼び出しが残っていないことを文字列で固定する）

生成 OP の `conformance.test.ts`（生成元 `packages/cli/src/frameworks/hono/templates.ts` を変更すること）:

- [x] `should issue an ID Token whose sub matches the authenticated end-user`
- [x] `should issue an ID Token whose auth_time matches the authentication time recorded at authorization`
- [x] `should still issue tokens when the authorization code store physically deletes consumed codes`
  - 消費後の再取得に依存していないことの回帰固定。なお再利用検知 cascade が効かなくなる点は従来どおり別テスト（`p1-revoke-mark-used-contract-and-reuse-cascade-regression` 由来）が検知する

## 完了条件

- [x] 上記テストがすべて通る
- [x] `pnpm --filter @maronn-openid-connect/core test`
- [x] `pnpm --filter @maronn-openid-connect/cli test`
- [x] `pnpm typecheck`
- [x] `samples/*` を再生成し、各 `conformance.test.ts` が通る
- [x] 生成された token ルートに `authCodeStore.get(validatedRequest.code)` が存在しない
- [x] changeset が作成され、破壊的変更を含む場合は移行手順が記載されている
