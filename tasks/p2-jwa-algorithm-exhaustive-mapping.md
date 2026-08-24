# [P2] `getJwaAlgorithm` の写像を網羅化し、SHA-1 鍵の黙った `RS512` 誤表示を起動時エラーにする

## ステータス

🟠 High / 未着手

## 背景

`getJwaAlgorithm(key)` は RSASSA-PKCS1-v1_5 のハッシュ名を三項演算子で写像しており、SHA-256 / SHA-384 以外（Web Crypto がインポートを受け付ける SHA-1 を含む）を**すべて `RS512`** に落とす。
ECDSA 側も P-256 / P-384 以外を `ES512` に落とす同型のフォールバックを持つ（こちらは非 NIST 曲線がインポートで弾かれるため実害経路は RSA + SHA-1）。

SHA-1 鍵で OP を構成すると、Discovery の `id_token_signing_alg_values_supported`、JWKS の `alg`、ID Token / UserInfo JWT / JWT アクセストークンの JOSE ヘッダがすべて `RS512` を名乗りながら、署名バイト列は RSA-SHA1 になる。
RP の署名検証は全滅し、原因（ヘッダと実アルゴリズムの不一致）の診断が難しい。
SHA-1 を拒否する CryptoKey 版 `extractAlgorithmParams` は存在するが、production 経路から呼ばれていない dead code である。

検討詳細は `study-material/done/jwa-algorithm-hash-fallback-mislabeling.md` を参照。

## 対象ファイル

- `packages/core/src/crypto-utils.ts`（`getJwaAlgorithm`: 404 行付近。CryptoKey 版 `extractAlgorithmParams`: 312 行付近）
- `packages/core/src/crypto-utils.test.ts`
- 必要に応じて `packages/core/src/signing-key.ts`（`assertKeyStrength` へのハッシュ検査追加を採る場合）

## 仕様参照

- **RFC 7515 §4.1.1** — https://www.rfc-editor.org/rfc/rfc7515#section-4.1.1
  `alg` ヘッダは実際に使われたアルゴリズムを識別する
- **RFC 7518 §3.1** — https://www.rfc-editor.org/rfc/rfc7518#section-3.1
  署名 `alg` の定義一覧。RSA + SHA-1 の署名 `alg` は存在しない
- **RFC 8725 §3.1-§3.3** — 適切なアルゴリズムの使用
- **OIDC Discovery 1.0 §3** — 広告する署名アルゴリズムは実態と一致させる

## 現状の実装

```typescript
// packages/core/src/crypto-utils.ts:404-418
if (algorithm.name === 'RSASSA-PKCS1-v1_5' && 'hash' in algorithm) {
  const hash = (algorithm as webcrypto.RsaHashedKeyAlgorithm).hash.name;
  return hash === 'SHA-256' ? 'RS256' : hash === 'SHA-384' ? 'RS384' : 'RS512';
}

if (algorithm.name === 'ECDSA' && 'namedCurve' in algorithm) {
  const curve = (algorithm as webcrypto.EcKeyAlgorithm).namedCurve;
  return curve === 'P-256' ? 'ES256' : curve === 'P-384' ? 'ES384' : 'ES512';
}
```

`getJwaAlgorithm` は discovery / jwks / id-token / userinfo / access-token / token-response（at_hash）/ signing-key（鍵選択）から使われるため、誤写像はこれら全てへ波及する。

## 修正方針

- [ ] 三項フォールバックを明示的な分岐へ置き換え、SHA-512 / P-521 を**明示的に**写像した上で、未知のハッシュは `Unsupported hash algorithm for JWS signing: <name>`、未知の曲線は `Unsupported curve for JWS signing: <name>` で throw する
- [ ] SHA-1 拒否の一次防衛点をどこに置くか（`getJwaAlgorithm` の throw で足りるか、`assertKeyStrength` にもハッシュ検査を足して起動時に落とすか）を決め、決定理由をコメントに残す
- [ ] dead code の CryptoKey 版 `extractAlgorithmParams` を、削除するか「テスト専用」と JSDoc に明記するか決める（公開 API のため削除は semver 判断を伴う）
- [ ] `packages/core` の変更に対する changeset を作成する（挙動変更: これまで `RS512` が返っていた入力が throw になる）

## テスト要件

- [ ] `should throw for an RSA key bound to SHA-1`（`getJwaAlgorithm`。現状は `'RS512'` が返ることから Red を作れる）
- [ ] `should return RS512 for an RSA key bound to SHA-512`（正常系の明示写像が壊れていないこと）
- [ ] `should return ES512 for a P-521 key`
- [ ] 既存の RS256 / RS384 / ES256 / ES384 のテストが回帰しないこと
- [ ] `assertKeyStrength` にハッシュ検査を足す場合: SHA-1 鍵が起動時（provider 構築時）に拒否されることを固定する

## 完了条件

- `pnpm --filter @maronn-openid-connect/core test` がパスする
- `pnpm typecheck` がパスする
- SHA-1 の RSA 鍵が黙って `RS512` として広告・署名される経路が存在しないことがテストで固定されている
- changeset が作成されている
