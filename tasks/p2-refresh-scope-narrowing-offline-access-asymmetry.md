# [P2] Refresh の scope 縮小で `offline_access` だけが復活する非対称を解消する（rotation 可否を scope から分離）

## ステータス

🟡 Medium / 未着手

## 背景

`refresh_token` grant で `scope` を縮小したとき、**縮小の効き方が scope ごとに異なる**。

- `profile` / `email` などは縮小以降、二度と要求できない（`validateRefreshTokenScope` が `invalid_scope` で拒否する）。
- `offline_access` だけは、**次回の refresh レスポンスとアクセストークンの `scope` にクライアントが要求しないまま復活する**。

原因は、生成 OP が rotation 継続のために**同じ目的の機構を 2 つ持っている**ことにある。

1. `ValidatedRefreshTokenRequest.hadOfflineAccess`（core が返す。rotation 可否を縮小後 scope から切り離す正しい抽象）
2. 永続化する新 refresh token の `scope` に `offline_access` を書き戻す（生成テンプレート側）

(1) だけで rotation 可否は判定できているため **(2) は不要**だが、(2) が書き戻した値は `validateRefreshTokenScope` の「`scope` 省略時は保存された scope を返す」経路を通って次回リクエストの発行 scope になる。

### 再現（コード上で決定的にたどれる）

前提: 認可時の付与 scope = `openid profile email offline_access`。

| # | リクエスト | 発行 scope（AT / ID Token / レスポンス） | 新 RT に保存される scope |
|---|---|---|---|
| 1 | `scope` 省略 | `openid profile email offline_access` | 同左 |
| 2 | `scope=openid` | `openid` | **`openid offline_access`** |
| 3 | `scope` 省略 | **`openid offline_access`** | `openid offline_access` |

#3 で返る `openid offline_access` は、RFC 6749 §6 が言う「originally granted」（`openid profile email offline_access`）でも、直前に要求された scope（`openid`）でもない**第 3 の値**である。

詳細な仕様上の位置づけ・影響範囲・方針比較は `study-material/done/refresh-scope-narrowing-offline-access-asymmetry.md` を参照（ここでは繰り返さない）。

### 本タスクのスコープ

`study-material/refresh-token-grant-scope-preservation.md` が扱う「保存すべきは元 grant scope か縮小後 scope か（方針 A / B）」の判断とは**独立に**、非対称そのものを解消する。すなわち **rotation 可否を `scope` フィールドから分離する**。方針 A を後から採用しても、本タスクの変更は無駄にならない。

**既定の外形挙動（rotation が継続すること）は変えない。** 変わるのは「縮小後の refresh で `offline_access` が復活しなくなる」点のみ。

## 対象ファイル

- `packages/core/src/token-request.ts`（`RefreshTokenInfo` の型定義）
- `packages/core/src/refresh-token-grant.ts`（`buildValidatedRefreshTokenRequest` の `hadOfflineAccess` 導出）
- `packages/cli/src/frameworks/hono/templates.ts`（`tokenRouteTemplate` の `refreshTokenPersistenceBlock`。`web-standard/templates.ts` が再エクスポートするため、ここを直せば express / fastify / nextjs にも反映される）
- `packages/cli` 内の `conformance.test.ts` 生成コード（`samples/*/conformance.test.ts` の生成元。**生成物を直接編集しないこと**）
- `packages/cli/src/__tests__/hono-generator.test.ts` / `web-framework-generators.test.ts`
- `study-material/resolver-and-store-contract.md`（refresh token store の保存契約）
- `samples/*/src/oidc-provider/routes/token.ts`（再生成される生成物）

## 仕様参照

- **RFC 6749 §6 Refreshing an Access Token**
  > The requested scope MUST NOT include any scope not originally granted by the resource owner, and if omitted is treated as equal to the scope originally granted by the resource owner.

  上限も省略時の既定値も基準点は「originally granted」。「前回要求した scope」ではない。
  — https://datatracker.ietf.org/doc/html/rfc6749#section-6
- **RFC 6749 §3.3 Access Token Scope**
  > If the issued access token scope is different from the one requested by the client, the authorization server MUST include the "scope" response parameter to inform the client of the actual scope granted.

  現実装は常に `scope` を返すため通知自体は満たすが、返る値が「クライアントが一度も要求していない scope を含む」状態になる。
  — https://datatracker.ietf.org/doc/html/rfc6749#section-3.3
- **OpenID Connect Core 1.0 §11 Offline Access** — `offline_access` は refresh token を得るための scope であり、UserInfo のクレーム集合に対応しない（`SCOPE_CLAIMS_MAP` にも無い）。OP 内部で追加の権限を意味しない。
  — https://openid.net/specs/openid-connect-core-1_0.html#OfflineAccess
- **Basic OP certification** — refresh 時の scope 縮小を検証する module は `oidcc-basic-certification-test-plan` に含まれない（`tasks/p3-basic-op-conformance-module-list-confirmation.md` で一覧を確定中）。**認定合否には影響しない。** 本タスクはライブラリとしての一貫性・利用者の予測可能性の問題。

## 現状の実装

### core（責務は正しく分離されている）

`packages/core/src/refresh-token-grant.ts:136-165`

```ts
export function validateRefreshTokenScope(
  requestedScope: string | undefined,
  originalScope: string[],
): string[] {
  if (requestedScope === undefined) {
    return originalScope;          // ← 省略時の既定値は「保存された scope」
  }
  // ... originalScope のサブセットであることを検証
}
```

`packages/core/src/refresh-token-grant.ts:170-192`

```ts
export function buildValidatedRefreshTokenRequest(...) {
  return {
    ...
    scope: effectiveScope,                                                 // 縮小後
    hadOfflineAccess: refreshTokenInfo.scope.includes('offline_access'),   // ← scope から導出している
  };
}
```

`hadOfflineAccess` は「rotation 可否」という別概念だが、**その導出元が `scope` フィールドになっている**。これが (2) の書き戻しを必要にしている根本原因。

### 生成テンプレート（非対称の発生源）

`packages/cli/src/frameworks/hono/templates.ts:3038-3045`（生成物: `samples/hono-cloudflare/src/oidc-provider/routes/token.ts:629-635`）

```ts
// RFC 6749 §6: 縮小後 scope（validatedRequest.scope）から offline_access が落ちても、
// grant が offline_access を持つ限り次回以降の rotation を継続できるよう、永続化する
// refresh token の scope には offline_access を保持する。
const refreshTokenScope =
  grantHasOfflineAccess && !validatedRequest.scope.includes('offline_access')
    ? [...validatedRequest.scope, 'offline_access']
    : validatedRequest.scope;
await refreshTokenStore.set(tokenResponse.refresh_token, {
  ...
  scope: refreshTokenScope,   // ← ここで書き戻される
});
```

一方 rotation 可否は同ファイル `templates.ts:2990-2995`（生成物 `token.ts:476-479`）の `grantHasOfflineAccess` が `validatedRequest.hadOfflineAccess` で既に判定済み。**書き戻しは rotation 継続には不要。**

## 修正方針

- [ ] `RefreshTokenInfo` に rotation 可否を表す独立フィールドを追加する

  ```ts
  /**
   * この grant が offline access（refresh token の継続発行）を許可されているか。
   * OIDC Core 1.0 §11 の offline_access は grant 単位の permission であり、
   * リクエスト単位の scope 縮小（RFC 6749 §6）とは別軸のため、`scope` とは
   * 独立したフィールドで保持する。
   *
   * 未設定（旧レコード）の場合は後方互換のため `scope.includes('offline_access')`
   * にフォールバックする。
   */
  offlineAccessGranted?: boolean;
  ```

- [ ] `buildValidatedRefreshTokenRequest` の `hadOfflineAccess` を新フィールドから導出し、旧レコード向けフォールバックを入れる

  ```ts
  hadOfflineAccess:
    refreshTokenInfo.offlineAccessGranted ??
    refreshTokenInfo.scope.includes('offline_access'),
  ```

- [ ] 生成テンプレートの `refreshTokenScope` 書き戻しを廃止し、`scope: validatedRequest.scope` をそのまま保存する
- [ ] 同じ `refreshTokenStore.set(...)` に `offlineAccessGranted: grantHasOfflineAccess` を追加する
- [ ] 書き戻しを説明していたコメントを、新しい根拠に置き換える

  ```ts
  // RFC 6749 §6: 縮小後 scope はそのまま保存する（このリクエストで要求された権限が次回の上限になる）。
  // rotation の継続可否は scope ではなく offlineAccessGranted が持つため、offline_access を
  // scope へ書き戻す必要はない。書き戻すと、クライアントが明示的に外した offline_access が
  // 次回の refresh レスポンスへ復活してしまう。
  ```

- [ ] `study-material/resolver-and-store-contract.md` に「refresh token store は `offlineAccessGranted` を保存すること。省略すると旧挙動（`scope` からの導出）にフォールバックする」を追記する
- [ ] `study-material/refresh-token-grant-scope-preservation.md` に、本タスクが「方針 B を選ぶ場合の前提作業」であること、および方針 A を採る場合は本タスクの変更が引き続き有効であることを追記する

## テスト要件

### `packages/core`

- [ ] `buildValidatedRefreshTokenRequest` は `offlineAccessGranted: true` の RefreshTokenInfo に対し、`scope` に `offline_access` が無くても `hadOfflineAccess: true` を返す
- [ ] `buildValidatedRefreshTokenRequest` は `offlineAccessGranted` 未設定の RefreshTokenInfo に対し、`scope.includes('offline_access')` の結果を `hadOfflineAccess` として返す（旧レコード互換）
- [ ] `validateRefreshTokenScope` に、縮小後 scope を保存した場合に元の scope へ再拡大しようとすると `invalid_scope` になることを固定するテストを追加する

### `samples/*/conformance.test.ts`（生成元は `packages/cli`）

- [ ] `scope=openid profile email offline_access` で得た RT に対し `scope=openid` で refresh すると、レスポンスの `scope` が **`openid` ちょうど**である
- [ ] 続けて `scope` を省略して refresh すると、レスポンスの `scope` が **`openid` のまま**で `offline_access` が復活しない
- [ ] その 2 回目の refresh でも `refresh_token` が発行される（rotation が継続する = 既定の外形挙動が変わっていない）
- [ ] `scope` を縮小しない通常の refresh では、レスポンスの `scope` に `offline_access` が含まれ続ける（回帰）
- [ ] 縮小後の refresh で `profile` を再要求すると `invalid_scope` で拒否される（他 scope の恒久縮小は変更しないことの回帰）

### `packages/cli`

- [ ] 生成コードに `offlineAccessGranted` が出力され、`refreshTokenScope` の書き戻しが存在しないことを生成コードの文字列テストで固定する
- [ ] `features.refreshToken` が false のとき、上記いずれも生成物に現れない

## 完了条件

- `pnpm --filter @maronn-openid-connect/core test` がパスすること
- `pnpm --filter @maronn-openid-connect/cli test` がパスすること
- `pnpm --filter "./samples/*" test` で各 sample の `conformance.test.ts` がパスすること
- `pnpm typecheck` がパスすること
- 4 つの sample の生成物を再生成しても差分が安定していること（`tasks/done/p2-cli-generated-output-verification-ci.md` の検証が通ること）
- `samples/*/src/oidc-provider/routes/token.ts` に `refreshTokenScope` の書き戻しが残っていないこと
