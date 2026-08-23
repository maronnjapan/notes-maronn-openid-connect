# [P2] Refresh Token アイドルタイムアウトを生成 OP へ配線する（`lastUsedAt` 永続化と config 化）

## ステータス

🟡 Medium / 未着手

## 背景

core には Refresh Token のアイドル（無操作）タイムアウト判定 `validateRefreshTokenIdleTimeout` が実装済みで、`RefreshTokenInfo.lastUsedAt` の doc も「**ローテーション時に「今」へ更新する（スライディング）**」と契約を明記している。しかし CLI が生成する OP からはこの機能に**到達できない**。

1. 生成テンプレートは `validateRefreshTokenIdleTimeout(refreshTokenInfo, undefined)` とタイムアウト値を undefined 固定で呼ぶ。
2. 生成テンプレートの `refreshTokenStore.set(...)` は `lastUsedAt` を**一切保存しない**。
3. `validateRefreshTokenIdleTimeout` は `lastUsedAt === undefined` のとき早期 return するため、利用者が (1) の undefined を秒数へ書き換えても**何も起きない**。

実際、`packages/cli` と `samples/*` の全体を検索しても `lastUsedAt` / `refreshTokenIdleTimeout` という識別子は 1 箇所も存在しない（`packages/core` のみ）。生成コードのコメントは「undefined を秒数に置き換えれば有効になる」と読めるため、**コメントが実装と乖離**している。

`tasks/done/p3-refresh-token-idle-inactivity-timeout.md` は完了扱いだが、その修正方針に含まれていた「テンプレートの store.set に `lastUsedAt: issuedAt` を保存」「`refreshTokenIdleTimeout` を config 化」が未反映のまま残っている。本タスクはその**積み残し分**を対象とする。

アイドルタイムアウトの意義・RFC 上の位置づけは `study-material/done/refresh-token-idle-inactivity-timeout.md` を、到達不能である事実の詳細は `study-material/done/refresh-token-idle-timeout-unreachable-in-generated-op.md` を参照（ここでは繰り返さない）。

**既定は OFF のまま**（`refreshTokenIdleTimeoutSeconds` 未設定＝従来挙動）で、後方互換を壊さないこと。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`（`configTemplate` の `ProviderConfig` / `tokenRouteTemplate` の `refreshTokenPersistenceBlock`）
  — **単一の修正点**。`web-standard/templates.ts` が `configTemplate` / `tokenRouteTemplate` を再エクスポートし、express / fastify / nextjs はいずれも `webGeneratedFiles` 経由で同じ生成物を使うため、ここを直せば全フレームワークに反映される
- `packages/cli/src/__tests__/hono-generator.test.ts` / `web-framework-generators.test.ts`（生成コードのテスト）
- `packages/cli` 内の `conformance.test.ts` 生成コード（`samples/*/conformance.test.ts` の生成元）
- `study-material/resolver-and-store-contract.md`（`lastUsedAt` の保存契約）

## 仕様参照

- **RFC 9700 (BCP 240) §4.14 Refresh Token Protection** — Refresh Token は sender-constrained にするか rotation を行うこと。加えて有効期限を限定することを推奨する。アイドルタイムアウトという語自体は RFC の規定ではなく、商用 IdaaS で一般的な運用機構であり、この推奨を具体化する追加の失効軸として位置づける。
  — https://www.rfc-editor.org/rfc/rfc9700
- **OAuth 2.1 draft §6.1 Refresh Token Lifetime** — 絶対寿命は initial issuance 起点。アイドルタイムアウトはこれと独立の軸で、いずれか早い方で失効させる。
  — https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1
- **RFC 6749 §6 Refreshing an Access Token**
  — https://www.rfc-editor.org/rfc/rfc6749#section-6
- Basic OP certification profile はアイドルタイムアウトを要求しない（`study-material/basic-op-requirements-baseline.md` 参照）。本タスクは運用機能の品質・API の正直さの問題。

## 現状の実装

### core（正しく実装済み）

`packages/core/src/refresh-token-grant.ts:112-128`

```ts
export function validateRefreshTokenIdleTimeout(
  refreshTokenInfo: RefreshTokenInfo,
  idleTimeoutSeconds: number | undefined,
  currentTime: number = Math.floor(Date.now() / 1000),
): void {
  if (
    idleTimeoutSeconds !== undefined &&
    idleTimeoutSeconds > 0 &&
    refreshTokenInfo.lastUsedAt !== undefined &&   // ← 生成 OP では必ず undefined
    currentTime - refreshTokenInfo.lastUsedAt > idleTimeoutSeconds
  ) {
    throw new TokenError(TokenErrorCode.InvalidGrant, 'Refresh token expired due to inactivity');
  }
}
```

### 生成テンプレート（配線が欠けている）

`packages/cli/src/frameworks/hono/templates.ts:2154`

```ts
// Optional inactivity policy. Replace undefined with your timeout in seconds
// to enable it, or remove this step if your experiment has no idle lifetime.
validateRefreshTokenIdleTimeout(refreshTokenInfo, undefined);
```

同ファイル 2303 行以降（`refreshTokenPersistenceBlock`）

```ts
await refreshTokenStore.set(tokenResponse.refresh_token, {
  subject,
  clientId: validatedRequest.clientId,
  scope: refreshTokenScope,
  expiresAt: refreshTokenExpiresAt,
  originalIssuedAt,
  used: false,
  grantId: validatedRequest.grantId,
  iat: issuedAt,
  issuer: config.issuer,
  audience: effectiveAudience,
  authTime: rtAuthTime,
  nonce,
  acr: ...,
  amr: ...,
  azp: ...,
});
// ← lastUsedAt が無い
```

`ProviderConfig` には `refreshTokenAbsoluteLifetime` はあるが、アイドルタイムアウト相当の設定項目が無い（同ファイル 300-320 行付近）。

## 修正方針

- [ ] `ProviderConfig` に任意フィールドを追加する（既定 `undefined` = アイドル失効なし）
  ```ts
  /**
   * RFC 9700 §4.14 の「有効期限を限定する」推奨を具体化する追加の失効軸。
   * 未設定または 0 以下ならアイドル失効なし（既定・従来挙動）。
   * 絶対寿命（refreshTokenAbsoluteLifetime）とは独立で、いずれか早い方で失効する。
   */
  refreshTokenIdleTimeoutSeconds?: number;
  ```
- [ ] 生成される `defaultProviderConfig` には**設定しない**（既定 OFF を保つ）。コメントで「秒数を設定すると有効になる」ことを示す
- [ ] `refreshTokenStore.set(...)` に `lastUsedAt: issuedAt` を追加する
  ```ts
  // アイドル（無操作）失効の基準。ローテーションのたびに「今」へ更新する（スライディング）。
  // originalIssuedAt（絶対寿命の基準）は据え置きなので、二軸が独立に効く。
  lastUsedAt: issuedAt,
  ```
- [ ] 呼び出しを config 参照へ差し替える
  ```ts
  // 未設定なら従来どおりアイドル失効なし。
  validateRefreshTokenIdleTimeout(refreshTokenInfo, config.refreshTokenIdleTimeoutSeconds);
  ```
- [ ] 生成コードのコメントを実装と一致させる（「undefined を秒数に置き換えれば有効」→「config で秒数を設定すると有効。既定は無効」）
- [ ] `hono/templates.ts` の修正が web-standard 経由で express / fastify / nextjs の生成物にも反映されることを、生成コードのテストで確認する
- [ ] `study-material/resolver-and-store-contract.md` に「refresh token store は `lastUsedAt` を保存すること。省略するとアイドル失効が機能しない」契約を追記する
- [ ] Introspection 側との整合（アイドル失効済み RT を `active: true` と報告する不整合）は本タスクの範囲外。`tasks/p3-introspection-refresh-token-idle-timeout-active-consistency.md` の実施タイミングを本タスクと合わせて判断すること

## テスト要件

- [ ] `refreshTokenIdleTimeoutSeconds` 未設定のとき、`lastUsedAt` が古い RT でも従来どおりローテーションできる（既定 OFF の後方互換）
- [ ] authorization_code grant で発行した RT に `lastUsedAt` が保存され、その値が `iat` と一致する
- [ ] refresh_token grant でローテーションした新 RT の `lastUsedAt` が「今」へ更新される
- [ ] ローテーション後も `originalIssuedAt` と `expiresAt`（絶対寿命）が変わらない（スライディング延長が起きない）
- [ ] `refreshTokenIdleTimeoutSeconds` 設定時、`now - lastUsedAt > timeout` の RT が `invalid_grant`（`Refresh token expired due to inactivity`）で拒否される
- [ ] `refreshTokenIdleTimeoutSeconds` 設定時、`now - lastUsedAt == timeout`（境界値）の RT は有効である
- [ ] 生成コードのコメントに `undefined` を書き換える旨の誤誘導が残っていないことを、生成コードのスナップショット／文字列テストで固定する
- [ ] `samples/*/conformance.test.ts` に「既定ではアイドル失効が起きない」「`lastUsedAt` が保存されている」契約テストを追加する（生成元は `packages/cli`）

## 完了条件

- `pnpm --filter @maronn-openid-connect/cli test` がパスすること
- `pnpm --filter @maronn-openid-connect/core test` がパスすること
- 各 sample の `conformance.test.ts` がパスすること
- `pnpm test` がパスすること
- `packages/cli` / `samples/*` に `lastUsedAt` が存在し、`refreshTokenIdleTimeoutSeconds` を設定すればアイドル失効が実際に発火すること
