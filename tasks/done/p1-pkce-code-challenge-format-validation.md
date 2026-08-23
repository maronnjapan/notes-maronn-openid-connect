# [P1] Authorization Endpoint で PKCE `code_challenge` 値の長さ・文字種を検証する

## ステータス

🟡 Major / 未着手

## 背景

OAuth 2.1 / RFC 7636 では `code_challenge_method=S256` の場合、`code_challenge` は SHA-256 出力 32 バイトの base64url-no-padding 表現であり、**長さ 43 文字固定、文字種 `[A-Za-z0-9\-_]`** に限定される。

現在の `validateAuthorizationRequest` は `code_challenge` の存在チェックと `code_challenge_method` の値検証は行うが、`code_challenge` 値そのものの長さ・文字種は検証していない。問題は Token Endpoint の `code_verifier` 比較段階で初めて顕在化し、

- 利用者へのエラーフィードバックが遅延する（同意画面到達後に Token Endpoint で `invalid_grant`）
- 誤実装クライアントの「`code_challenge` をどう計算したか」のデバッグが困難
- Conformance Suite の厳格テストで指摘されうる

なお Token Endpoint 側は `code_verifier` の長さ（43-128）・文字種を既に検証している（`token-request.ts:531-557`）。本タスクは「`code_challenge` 側」の同等検証を Authorization Endpoint に追加する差分。

詳細な仕様調査と方針候補は `study-material/done/pkce-code-challenge-format-validation.md` を参照。

## 対象ファイル

- `packages/core/src/authorization-request.ts`
- `packages/core/src/authorization-request.test.ts`

## 仕様参照

- RFC 7636 §4.1: `code_verifier` の文字種・長さ（unreserved `[A-Za-z0-9\-._~]` / 43-128 文字）
- RFC 7636 §4.2: `code_challenge = BASE64URL-ENCODE(SHA256(ASCII(code_verifier)))`（S256 では 43 文字固定の `[A-Za-z0-9\-_]`）
- OAuth 2.1 §4.1.1 / §7.5: PKCE S256 必須

## 現状の実装

```ts
// packages/core/src/authorization-request.ts:384-427 validateCodeChallenge
function validateCodeChallenge(
  codeChallenge: string | undefined,
  codeChallengeMethod: string | undefined,
  redirectUri: string,
  state?: string
): { codeChallenge: string; codeChallengeMethod: 'S256' } {
  if (!codeChallenge) { /* invalid_request */ }
  if (!codeChallengeMethod) { /* invalid_request */ }
  if (!(VALID_CODE_CHALLENGE_METHODS as readonly string[]).includes(codeChallengeMethod)) {
    /* invalid_request */
  }
  return { codeChallenge, codeChallengeMethod: codeChallengeMethod as 'S256' };
  // ↑ codeChallenge 値の長さ・文字種は未検証
}
```

## 修正方針

- [ ] `validateCodeChallenge` 内で `code_challenge_method === 'S256'` のとき、以下を検証する:
  - 長さが 43 文字であること
  - 文字種が `[A-Za-z0-9\-_]`（base64url-no-padding）であること
- [ ] 違反時は `invalid_request` を返す（redirectable error）
- [ ] `error_description` を「`code_challenge` must be a 43-character base64url-encoded SHA-256 hash」相当にする（既存 `sanitizeErrorDescription` 経由）

```ts
const CODE_CHALLENGE_S256_LENGTH = 43;
const CODE_CHALLENGE_S256_PATTERN = /^[A-Za-z0-9\-_]+$/;

// validateCodeChallenge 内で codeChallengeMethod === 'S256' 判定後に追加
if (codeChallenge.length !== CODE_CHALLENGE_S256_LENGTH) {
  throw new AuthorizationError(
    AuthorizationErrorCode.InvalidRequest,
    `code_challenge length must be ${CODE_CHALLENGE_S256_LENGTH} characters for S256`,
    redirectUri,
    state,
  );
}
if (!CODE_CHALLENGE_S256_PATTERN.test(codeChallenge)) {
  throw new AuthorizationError(
    AuthorizationErrorCode.InvalidRequest,
    'code_challenge contains invalid characters (must be base64url)',
    redirectUri,
    state,
  );
}
```

## テスト要件

- [ ] 43 文字の有効 base64url 文字列 → 通過する
- [ ] 42 文字以下 → `invalid_request` で redirect
- [ ] 44 文字以上 → `invalid_request` で redirect
- [ ] 文字種違反（記号 `!` `?` `=` `/` `+` 等を含む）→ `invalid_request` で redirect
- [ ] スペース・改行を含む → `invalid_request` で redirect
- [ ] error_description に「base64url」「43」等の情報が含まれること（人間が原因を推測できる）

## 完了条件

`pnpm --filter @maronn-openid-connect/core test` および `pnpm --filter @maronn-openid-connect/cli test` がパスすること
