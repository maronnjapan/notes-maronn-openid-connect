# [P2] 署名鍵強度検証で RSA 公開指数 `e` を検証する（退化指数の起動時拒否）

## ステータス

🟡 Medium / 未着手

## 背景

起動時フェイルクローズ検証 `assertKeyStrength` の RSA 分岐は、モジュラス長（`n` のビット長）だけを見て
公開指数 `e` を一切検査しない。そのため `e=1` / `e=3` / 偶数 / 過小・過大指数を持つ RSA 署名鍵が
「強い鍵」として受理され、JWKS に公開され ID Token 署名に使われうる。特に `e=1` は RSASSA 検証を
実質「署名 ≡ パディング済みメッセージ」に縮退させ、ID Token 署名の偽造を容易にしうる。

署名鍵は OP 運用者が投入するもので外部注入面ではないが、鍵生成スクリプトのバグや手組み JWK の誤りで
退化指数が混入しうる。本リポジトリの "security-first・起動時フェイルクローズ" 思想（`assertKeyStrength` /
`assertHasRs256Key`）に沿って、指数も自前で検証するのが一貫する。WebCrypto 実装依存に委ねない
（Portability の担保）。Basic OP 認証の合否には直結しない security-hardening。

検討詳細は `study-material/done/signing-key-rsa-public-exponent-validation.md` を参照。

> 関連：モジュラス長・EC 曲線・`use`/`key_ops` の検証は `tasks/done/p1-signing-key-strength-validation.md` /
> `study-material/signing-key-strength-and-parameter-validation.md`。本タスクは公開指数の差分に限定する。

## 対象ファイル

- `packages/core/src/signing-key.ts`（`assertKeyStrength` RSA 分岐 / `KeyStrengthPolicy`）
- `packages/core/src/crypto-utils.ts`（`e` の base64url デコード補助が要る場合）
- `packages/core/src/signing-key.test.ts`

## 仕様参照

- NIST FIPS 186-5 §5.1 / NIST SP 800-56B Rev.2 §6.4.1.1: RSA 公開指数 `e` は奇数で `65537 ≤ e < 2^256`。
  デファクト標準は `e=65537`（`0x010001` / JWK では `AQAB`）。
- RFC 8725 §3.3: 署名検証を含む暗号操作は妥当性を検証する。
- OIDC Core 1.0 §10.1: OP は非対称署名鍵を JWKS で公開する（脆弱鍵は「検証成功だが偽造可能」を生む）。

## 現状の実装

```ts
// packages/core/src/signing-key.ts:182-195
if (jwk.kty === 'RSA') {
  if (!jwk.n) { throw new Error(`... has no modulus (n)`); }
  const bits = rsaModulusBitLength(jwk.n);
  if (bits < minRsaModulusBits) { throw new Error(`... ${bits}-bit RSA modulus ...`); }
  continue; // jwk.e は読まれない
}
```

`KeyStrengthPolicy`（`signing-key.ts:137-142`）は `minRsaModulusBits` / `allowedCurves` のみ。指数フィールド無し。
テスト鍵は `publicExponent: [1,0,1]`（65537）のみで、退化指数の負テストは無い。

## 修正方針

- [ ] 既定ポリシーを決定（案A: `e === 65537` のみ許可 / 案B: 奇数かつ `65537 ≤ e < 2^256` / 案C: `e=1`・偶数・過小のみ拒否）
- [ ] `assertKeyStrength` の RSA 分岐に、`jwk.e` を base64url デコードして整数化し、選択した基準で検証する処理を追加
- [ ] エラーメッセージは `keyId` を含めるがログ/起動時限定とし、`error_description` へは出さない（既存方針踏襲）
- [ ] （任意）`KeyStrengthPolicy` に指数制約フィールドを追加し、FAPI 等の厳格化を注入可能にする

実装イメージ:

```ts
// n チェックの後
const e = base64urlToBigInt(jwk.e); // 'AQAB' → 65537n
if (e < 65537n || (e & 1n) === 0n /* 偶数 */ || e >= (1n << 256n)) {
  throw new Error(`Signing key "${key.keyId}" has an invalid RSA public exponent (NIST SP 800-56B: odd, 65537 <= e < 2^256)`);
}
```

## テスト要件

- [ ] `e=1` の RSA 鍵で `assertKeyStrength` が throw
- [ ] 偶数指数 / 過小指数（例: `e=3`、方針次第）で throw
- [ ] 空・不正 `e` で throw
- [ ] 正常系（`e=65537` / `AQAB`）は通過（回帰固定）
- [ ] エラーメッセージに `keyId` を含む

## 完了条件

- `pnpm --filter @maronn-openid-connect/core test` がパスすること
- 新規負テストが追加され、既存の鍵強度テストが回帰しないこと
