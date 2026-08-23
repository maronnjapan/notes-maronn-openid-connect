# [P1] 署名鍵の強度を起動時に検証する（弱い RSA / 非承認 EC 曲線の拒否）

## ステータス

🟠 High / 未着手

## 背景

`packages/core/src/crypto-utils.ts` の `importKeyFromJwk` は JWK を `crypto.subtle.importKey` にそのまま渡すだけで、**RSA モジュラス長（鍵長）の下限を検証していない**。WebCrypto の `importKey` は 512bit / 1024bit の弱い RSA 鍵でも成功するため、OSS 利用者が誤って弱鍵を署名鍵に設定しても起動時・リクエスト時のどちらでも弾かれない。配布される ID Token は「検証は通るが第三者が現実的な計算量で偽造可能」になり、なりすましに直結する。

`extractAlgorithmParams` は SHA-1 ハッシュのみ明示拒否しており、鍵長は見ていない。EC 曲線は `extractAlgorithmParamsFromJwk` が `P-256/P-384/P-521` に限定済み（事実上の下限担保）だが、これは alg 解決目的であって「鍵強度ポリシー」としては未集約。RS256 鍵の存在は `assertHasRs256Key` で保証するが、その鍵の強度は問わない。

NIST SP 800-131A Rev.2 は RSA 1024bit を disallowed とし、2048bit 以上を要求する。FAPI も RSA 2048bit 以上を前提とするため、将来の FAPI ターゲットの前提部品でもある。検討の経緯・方針比較は `study-material/done/signing-key-strength-and-parameter-validation.md` を参照。

本タスクは「最小・起動時アサーション」（study-material 方針A）に絞る。`use`/`key_ops` の用途強制（方針B/C）は範囲外とし、必要なら別タスク化する。

## 対象ファイル

- `packages/core/src/signing-key.ts`（`assertKeyStrength` の新設、`assertHasRs256Key` と同経路で呼ぶ）
- `packages/core/src/crypto-utils.ts`（JWK の `n` からモジュラスビット長を求める純粋ヘルパ。外部依存を増やさない）
- `packages/core/src/signing-key.test.ts` / `crypto-utils.test.ts`（テスト追加）
- `packages/core/src/discovery.ts`（任意：`buildProviderMetadata` の鍵検証点に組み込むか検討）

## 仕様参照

- RFC 8725 JWT BCP §3.3（Validate All Cryptographic Operations）/ §3.5（Ensure Cryptographic Keys Have Sufficient Entropy）— 署名鍵は十分な強度を持つこと。
- NIST SP 800-131A Rev.2 — RSA 1024bit は disallowed、2048bit 以上（112bit 強度）を要求。
- NIST SP 800-57 Part 1 Rev.5 — 鍵強度の等価ビット表。
- OIDC Core 1.0 §10.1 Signing / §15.1（RS256 MUST。RS256 鍵保持は `assertHasRs256Key` で維持）。

注: Basic OP 認定の Conformance テストは弱鍵拒否を直接叩かない（拡張的ハードニング）。本タスクは本番運用時のセキュリティ強化。

## 現状の実装

```ts
// packages/core/src/crypto-utils.ts:189-207
async function importKeyFromJwk(jwkString, algorithm = { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, extractable = true, keyUsages?) {
  const jwk = JSON.parse(jwkString) as webcrypto.JsonWebKey;
  // ... モジュラス長・曲線強度の検証は無い
  return crypto.subtle.importKey('jwk', jwk, algorithm, extractable, usages);
}
```

```ts
// packages/core/src/crypto-utils.ts:272-299 extractAlgorithmParams
if (hashName === 'SHA-1') { throw new Error('Unsupported hash algorithm: SHA-1'); } // 鍵長は未検証
```

`signing-key.ts` の `assertHasRs256Key(keys)` は RS256 鍵の存在のみを保証し、強度は問わない。

## 修正方針

- [ ] 受け入れ最小強度を定数化する（既定: RSA モジュラス **2048bit 以上**、許容 EC 曲線 **P-256/P-384/P-521**）。値は設定で上書き可能にするか、まずは固定値で導入するかを決める。
- [ ] `crypto-utils.ts` に JWK の `n`（base64url）からモジュラスビット長を求める純粋ヘルパ `rsaModulusBitLength(jwkN: string): number` を追加（先頭ゼロバイトを除いたバイト長 × 8。Web 標準 API のみ、外部依存なし）。
- [ ] `signing-key.ts` に `assertKeyStrength(keys: SigningKey[], policy?)` を追加し、各 RSA 鍵のモジュラス長が下限未満なら throw（fail-closed）、EC 鍵が非承認曲線なら throw。
- [ ] `assertHasRs256Key` を呼ぶ起動経路（または `buildProviderMetadata`）の隣で `assertKeyStrength` を呼ぶ。
- [ ] エラーメッセージに「どの kid のどの鍵が下限未満か」を含め、利用者が原因を即特定できるようにする（`error_description` 等への漏洩はしない、ログ向け）。

実装イメージ（モジュラス長算出）:

```ts
// JWK の n は base64url。先頭の 0x00 パディングを除いたバイト長がモジュラス長
export function rsaModulusBitLength(jwkN: string): number {
  const bytes = new Uint8Array(base64UrlToArrayBuffer(jwkN));
  let i = 0;
  while (i < bytes.length && bytes[i] === 0) i++;
  return (bytes.length - i) * 8;
}
```

## テスト要件

- [ ] 1024bit RSA 鍵を登録すると `assertKeyStrength` が throw すること。
- [ ] 2048bit RSA 鍵は通ること。
- [ ] `rsaModulusBitLength` が 2048bit 鍵の `n` に対して 2048 を返すこと（先頭ゼロパディング有無の両ケース）。
- [ ] 非承認の EC 曲線（例: P-192 相当の JWK）を渡すと拒否されること。
- [ ] P-256 鍵は通ること。
- [ ] 既存の正常系（2048bit RS256 鍵での Discovery / ID Token 署名）が回帰しないこと。

## 完了条件

`pnpm --filter @maronn-openid-connect/core test` がパスし、上記テストが追加されていること。弱鍵が起動時に fail-closed で拒否されること。
