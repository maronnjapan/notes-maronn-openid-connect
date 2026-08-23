# [P2] `authorization_code` グラントの検証結果に `subject` / `auth_time` を含める

## ステータス

🟠 High / 未着手

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

- [ ] **`AuthorizationCodeInfo` に認証コンテキストを追加する**
  - [ ] `subject: string` を**必須**で追加する。JSDoc に「発行時に確定した End-User 識別子。ID Token の `sub` の源であり、authorization_code grant では必ず存在する」と記す
  - [ ] `authTime?: number` を追加する。JSDoc に「発行時の認証時刻（Unix epoch 秒）。ID Token の `auth_time` の源。`max_age` 要求時 / `require_auth_time` 登録時に必須（OIDC Core §2）」と記す
- [ ] **`ValidatedAuthorizationCodeRequest` に転記する**
  - [ ] `subject: string` / `authTime?: number` を追加し、`buildValidatedAuthorizationCodeRequest` で `authorizationCode` から転記する
  - [ ] refresh 側（`ValidatedRefreshTokenRequest`）とフィールド名を揃える（`subject` / `authTime`）
- [ ] **生成テンプレートから再取得を削除する**
  - [ ] `authCodeStore.get(validatedRequest.code)` のブロックを削除し、`subject = validatedRequest.subject` / `authTime = validatedRequest.authTime` にする
  - [ ] `authTime === undefined` のときのガードは、refresh token 発行ブロックの既存チェック（`rtAuthTime === undefined` → `invalid_grant`）に一本化できるか確認する
- [ ] **`AuthorizationCodeResolver` の JSDoc を更新する**
  - [ ] `findAuthorizationCode` が `subject` を返す責務を持つことを明記する
  - [ ] `revokeAuthorizationCode` の「物理削除ではなく `used=true`」契約の理由が、再利用検知 cascade **のみ**であること（トークン発行のための再取得には依存しなくなったこと）を明記する
- [ ] **semver / changeset の判断**
  - [ ] `AuthorizationCodeInfo.subject` を必須にすることは、独自 `AuthorizationCodeResolver` を実装済みの利用者にとって破壊的変更（型エラー）になる。`RELEASE.md` の方針に照らして bump 種別（minor / major）を決め、changeset に移行手順を書く
  - [ ] `packages/experimental/src` の変更は含まないため、experimental の自動 changeset 規約（patch 固定）とは無関係

## テスト要件

`packages/core`:

- [ ] `should return the subject stored on the authorization code`（`buildValidatedAuthorizationCodeRequest`）
- [ ] `should return the authTime stored on the authorization code`
- [ ] `should return undefined authTime when the authorization code has none`
- [ ] `should expose subject on the validated request for the authorization_code grant`（`validateTokenRequest` 経由の統合的な確認。判別共用体の両枝で `subject` が取れること）
- [ ] 既存テストの `AuthorizationCodeInfo` フィクスチャに `subject` を追加しても、他の検証（client binding / expiration / redirect_uri / PKCE / reuse cascade）の挙動が変わらないこと

`packages/cli`:

- [ ] `should not re-read the authorization code store after consuming the code`（生成された token ルートに `authCodeStore.get(` の呼び出しが残っていないことを文字列で固定する）

生成 OP の `conformance.test.ts`（生成元 `packages/cli/src/frameworks/hono/templates.ts` を変更すること）:

- [ ] `should issue an ID Token whose sub matches the authenticated end-user`
- [ ] `should issue an ID Token whose auth_time matches the authentication time recorded at authorization`
- [ ] `should still issue tokens when the authorization code store physically deletes consumed codes`
  - 消費後の再取得に依存していないことの回帰固定。なお再利用検知 cascade が効かなくなる点は従来どおり別テスト（`p1-revoke-mark-used-contract-and-reuse-cascade-regression` 由来）が検知する

## 完了条件

- [ ] 上記テストがすべて通る
- [ ] `pnpm --filter @maronn-openid-connect/core test`
- [ ] `pnpm --filter @maronn-openid-connect/cli test`
- [ ] `pnpm typecheck`
- [ ] `samples/*` を再生成し、各 `conformance.test.ts` が通る
- [ ] 生成された token ルートに `authCodeStore.get(validatedRequest.code)` が存在しない
- [ ] changeset が作成され、破壊的変更を含む場合は移行手順が記載されている
