# [P2] 署名アルゴリズムに RSA-PSS（PS256/384/512）を追加する

## ステータス

🟡 Medium / 未着手

## 背景

現状の暗号レイヤは `RSASSA-PKCS1-v1_5`（RS256/384/512）と `ECDSA`（ES256/384/512）のみをサポートし、`RSA-PSS`（PS256/384/512）に対応していない。per-client の `id_token_signed_response_alg` 選択機構（`selectSigningKeyByAlg`）は実装済みだが、`getJwaAlgorithm` が PS\* を認識しないため PS256 鍵を選択肢に乗せられない。

PS256 は FAPI 1.0 Advanced / FAPI 2.0 のメッセージ署名で要求される（RS256 を不可とするプロファイルがある）ため、FAPI を将来ターゲットにするなら前提部品となる。RSA-PSS は Web Crypto 標準アルゴリズムで主要ランタイムに広くサポートされ、Portability リスクが低い。

検討の経緯・トレードオフ（EdDSA との比較含む）は `study-material/done/signing-alg-eddsa-ps256-interop.md` を参照。EdDSA の Portability 検証は `tasks/done/p3-signing-alg-eddsa-portability-investigation.md` で完了済みであり、本タスクは PS256 に絞る。

## 対象ファイル

- `packages/core/src/crypto-utils.ts`（`sign` / `verify` / `getJwaAlgorithm` / `extractAlgorithmParamsFromJwk`）
- `packages/core/src/jwks.ts`（`exportPublicJwk`）
- `packages/core/src/crypto-utils.test.ts` / `jwks.test.ts` / `signing-key.test.ts` / `discovery.test.ts`
- `packages/sample/src/oidc-provider/config.ts`（`idTokenSignedResponseAlg` の型拡張、任意）

## 仕様参照

- RFC 7518 JWA §3.1 — `PS256`/`PS384`/`PS512`（RSASSA-PSS using SHA-256/384/512 と MGF1）。
- RFC 7518 JWA §3.5 — RSASSA-PSS。**salt 長は対応ハッシュの出力長と同じ**（PS256→32, PS384→48, PS512→64 バイト）、MGF は MGF1。
- OIDC Core 1.0 §15.1 — RS256 は MUST、PS256 等は任意（RS256 鍵保持は `assertHasRs256Key` で維持）。
- W3C Web Cryptography API — `{ name: 'RSA-PSS', saltLength }`。

## 現状の実装

- `crypto-utils.ts` `sign()` … `RSASSA-PKCS1-v1_5` / `ECDSA` のみ分岐。`RSA-PSS` は未対応。
- `crypto-utils.ts` `getJwaAlgorithm()`（L364-377）… RSA→`RS*` / EC→`ES*` のみ。PS\* は throw。
- `crypto-utils.ts` `extractAlgorithmParamsFromJwk()`（L312-340）… `kty=RSA` で RS\* のみ受理。
- `jwks.ts` `exportPublicJwk()` … `kty=RSA`（`n`/`e`）は出すが alg=PS\* の付与経路が無い。

## 修正方針

- [ ] `sign()` に `RSA-PSS` 分岐を追加し、ハッシュに応じた `saltLength`（32/48/64）を設定する。
- [ ] `verify()` にも対応する `RSA-PSS` + `saltLength` 分岐を追加する。
- [ ] `getJwaAlgorithm()` で `key.algorithm.name === 'RSA-PSS'` のときハッシュから `PS256/384/512` を返す。`RSASSA-PKCS1-v1_5`（RS\*）と確実に区別する。
- [ ] `extractAlgorithmParamsFromJwk()` で `kty=RSA` かつ `alg=PS*` のとき `{ name: 'RSA-PSS', hash }` を返す。
- [ ] `exportPublicJwk()` が PS\* 鍵に対し `kty=RSA` + `alg=PS256` 等を出力できるようにする。
- [ ] `idTokenSignedResponseAlg` の型に `'PS256'` を加える（sample / CLI、任意）。

実装イメージ（sign の分岐）:

```ts
// RFC 7518 §3.5: RSASSA-PSS, salt 長 = ハッシュ出力長, MGF1
if (algorithm.name === 'RSA-PSS' && 'hash' in algorithm) {
  const hash = (algorithm as webcrypto.RsaHashedKeyAlgorithm).hash.name;
  const saltLength = hash === 'SHA-256' ? 32 : hash === 'SHA-384' ? 48 : 64;
  signParams = { name: 'RSA-PSS', saltLength };
}
```

## テスト要件

- [ ] PS256 鍵（`{ name: 'RSA-PSS', hash: 'SHA-256' }` で generateKey）で署名→検証が往復で通ること。
- [ ] `getJwaAlgorithm(ps256Key)` が `'PS256'` を返し、RS256 鍵（`RSASSA-PKCS1-v1_5`）とは区別されること。
- [ ] `exportPublicJwk(ps256Key)` が `kty:'RSA'` かつ `alg:'PS256'` を返すこと。
- [ ] `selectSigningKeyByAlg(keys, 'PS256')` が PS256 鍵を選択すること。
- [ ] PS256 鍵を `idTokenSigningKeys` に含めると Discovery の `id_token_signing_alg_values_supported` に `PS256` が自動的に含まれること。
- [ ] PS384 / PS512 の salt 長（48/64）でも署名検証が通ること。

## 完了条件

`pnpm --filter @maronn-openid-connect/core test` がパスし、上記テストが追加されていること。
