# Basic OP 準拠修正タスク

コード調査の結果、以下の修正タスクを確認した。

## 調査の結果、問題なしと判断した項目（対応不要）

当初 Major として報告されていた2点はコード精読により非問題と判断した。

| 項目 | 判断 | 根拠 |
|------|------|------|
| azp クレーム欠落 | 非問題 | `generateTokenResponse` の ID Token `aud` は常に `clientId` 単体文字列なので `azp` 不要 |
| `revokeTokensByGrantId` 未実装 | 非問題 | `packages/sample/src/oidc-provider/resolvers.ts:42-45` に実装済み |

---

## 修正タスク一覧

### T-001 [Critical] `code_verifier` の長さ・文字種検証追加

**ファイル**: `packages/core/src/token-request.ts`  
**根拠**: RFC 7636 Section 4.1 — code_verifier は 43〜128 文字かつ `[A-Za-z0-9\-._~]` のみ許容  
**現状**: 存在チェック（truthy）のみ。長さ・文字種を検証していない。

修正内容:
- [ ] `token-request.test.ts`: 43文字未満 → `invalid_grant` テスト追加
- [ ] `token-request.test.ts`: 128文字超 → `invalid_grant` テスト追加
- [ ] `token-request.test.ts`: 不正文字（スペース・`+` など）→ `invalid_grant` テスト追加
- [ ] `token-request.test.ts`: 境界値 43文字 → 正常系テスト追加
- [ ] `token-request.test.ts`: 境界値 128文字 → 正常系テスト追加
- [ ] `token-request.ts`: 長さ検証 `(43 ≤ len ≤ 128)` を追加
- [ ] `token-request.ts`: 文字種検証 `/^[A-Za-z0-9\-._~]+$/` を追加

---

### T-002 [Major] `createRefreshTokenContext` テストヘルパーの `grantId` デフォルト欠損

**ファイル**: `packages/core/src/token-request.test.ts`  
**根拠**: `RefreshTokenInfo.grantId` は required だがヘルパーのデフォルトに含まれていない。  
結果として既存の refresh_token テストは `grantId: undefined` で動作しており、grantId 伝播の検証が抜けている。

修正内容:
- [ ] `token-request.test.ts`: `createRefreshTokenContext` の `defaultRefreshTokenInfo` に `grantId: 'grant-rt-001'` を追加
- [ ] `token-request.test.ts`: refresh_token grant 成功時に `grantId` が正しく返ることをテストで確認

---

### T-003 [Minor] `validateMaxAge` のロジック重複解消

**ファイル**: `packages/core/src/authorization-request.ts`  
**根拠**: `validateMaxAge` 内に2つの独立した `if` ブロックがあるが、条件が重複している（`!Number.isFinite` + `!Number.isInteger` を1つ目でチェックし、`num < 0` を2つ目でチェック）。1つの `if` にまとめてよい。

修正内容:
- [ ] `authorization-request.ts`: 2つの `if` を `||` で1つの条件式に統合
- [ ] `authorization-request.test.ts`: 既存テストが通ることを確認（動作変更なし）

---

## 完了条件

- `pnpm --filter @maronn-openid-connect/core test` が全件パス
