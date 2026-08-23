# [P1] ID Token `at_hash` のハッシュアルゴリズムを署名 alg に追従させる

## ステータス

🟠 High / 未着手

## 背景

`at_hash` のハッシュ関数は OIDC Core 1.0 §3.1.3.6 により「ID Token の JOSE Header `alg` で使われるハッシュ関数」と一致させる必要がある（RS256/ES256→SHA-256, RS384/ES384→SHA-384, RS512/ES512→SHA-512）。

しかし `packages/core/src/token-response.ts` の `computeAtHash()` は `crypto.subtle.digest('SHA-256', ...)` 固定で、ID Token の署名 alg を参照していない。本ライブラリは `getJwaAlgorithm()` / `selectSigningKeyByAlg()`（T-022）を通じて RS384/RS512/ES384/ES512 の鍵で ID Token を署名でき、その場合に **仕様違反の `at_hash`** を発行する。厳格な RP は ID Token を `at_hash` 不一致で拒否し、ログインがサイレントに壊れる。

サンプル設定は現状 RS256/ES256（いずれも SHA-256）のみ配線しているため顕在化しないが、core は非 SHA-256 鍵の登録を妨げない潜在バグ。Conformance の at_hash チェック（含めるなら正しいこと）でも落ちる。

検討経緯: `study-material/done/id-token-at-hash-algorithm-agility.md`

## 対象ファイル

- `packages/core/src/crypto-utils.ts`（`jwaToHashName` 追加）
- `packages/core/src/token-response.ts`（`computeAtHash` を alg 追従化、`generateTokenResponse` から ID Token 署名鍵の alg を渡す）
- `packages/core/src/token-response.test.ts`（非 SHA-256 alg のテスト追加）

## 仕様参照

- OIDC Core 1.0 §3.1.3.6 — `at_hash`:「the hash algorithm used is the hash algorithm used in the `alg` Header Parameter of the ID Token's JOSE Header. For instance, if the `alg` is RS256, hash the access_token value with SHA-256, then take the left-most 128 bits and base64url-encode them.」
- OIDC Core 1.0 §3.1.3.8 — RP 側 `at_hash` 検証（不一致で拒否し得る）
- RFC 7518 §3.1 — RSxxx / ESxxx と SHA-xxx の対応

## 現状の実装

```ts
// packages/core/src/token-response.ts
async function computeAtHash(accessToken: string): Promise<string> {
  const tokenBytes = stringToArrayBuffer(accessToken);
  const hashBuffer = await crypto.subtle.digest('SHA-256', tokenBytes); // ← alg 非追従
  const leftHalf = hashBuffer.slice(0, hashBuffer.byteLength / 2);
  return arrayBufferToBase64Url(leftHalf);
}
```

- `leftHalf = slice(0, byteLength/2)` のロジックは alg 非依存に正しい（SHA-384→24B, SHA-512→32B に一般化）。**修正点は `digest('SHA-256', ...)` の一点**。
- `generateTokenResponse()` は ID Token を `idtKey = idTokenPrivateKey ?? privateKey` で署名するが、`computeAtHash(accessToken)` は `idtKey` を参照しないため、署名 alg と at_hash のハッシュ alg が構造的に分離している。

## 修正方針

- [ ] `crypto-utils.ts` に `jwaToHashName(alg: string): 'SHA-256' | 'SHA-384' | 'SHA-512'` を追加（RS256/ES256/PS256→SHA-256、…384→SHA-384、…512→SHA-512、未知 alg は例外）。
- [ ] `computeAtHash` をハッシュ名引数つきに変更（または汎用 `computeLeftHalfHash(value, hashName)` を新設し at_hash/将来の c_hash で共用）。
- [ ] `generateTokenResponse()` で `getJwaAlgorithm(idtKey)` → `jwaToHashName()` を求め、at_hash 計算へ渡す。
- [ ] `leftHalf = slice(0, byteLength/2)` は維持（16/24/32 bytes へ自動一般化）。

実装例（要点のみ）:

```ts
// crypto-utils.ts
export function jwaToHashName(alg: string): 'SHA-256' | 'SHA-384' | 'SHA-512' {
  if (alg.endsWith('256')) return 'SHA-256';
  if (alg.endsWith('384')) return 'SHA-384';
  if (alg.endsWith('512')) return 'SHA-512';
  throw new Error(`Unsupported alg for hash claim: ${alg}`);
}

// token-response.ts
async function computeAtHash(accessToken: string, hashName: 'SHA-256'|'SHA-384'|'SHA-512'): Promise<string> {
  const hashBuffer = await crypto.subtle.digest(hashName, stringToArrayBuffer(accessToken));
  const leftHalf = hashBuffer.slice(0, hashBuffer.byteLength / 2);
  return arrayBufferToBase64Url(leftHalf);
}
// 呼び出し側: const atHash = await computeAtHash(accessToken, jwaToHashName(getJwaAlgorithm(idtKey)));
```

## テスト要件

- [ ] RS256 / ES256（SHA-256）の at_hash が従来通り 16 bytes 由来で正しいこと（回帰）。
- [ ] RS384 / ES384（SHA-384）で署名した ID Token の at_hash が **SHA-384 由来 24 bytes の左半分**になること。
- [ ] RS512 / ES512（SHA-512）で署名した ID Token の at_hash が **SHA-512 由来 32 bytes の左半分**になること。
- [ ] 各 alg で「自前で SHA-xxx → 左半分 → base64url」した期待値と一致すること。
- [ ] 未知 alg で `jwaToHashName` が例外を投げること。

## 完了条件

- `pnpm --filter @maronn-openid-connect/core test` がパスすること。
- 非 SHA-256 alg で署名した ID Token の at_hash が仕様（左半分のバイト長・値）どおりであることがテストで担保されること。
