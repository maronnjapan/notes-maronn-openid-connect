# `getJwaAlgorithm` が SHA-1 の RSA 鍵を `RS512` と誤表示する（フォールバック分岐の非網羅）

## 1. タイトル

`getJwaAlgorithm(key)` は RSASSA-PKCS1-v1_5 鍵のハッシュ名を JWA の `alg` へ写像する際、SHA-256 / SHA-384 以外を**すべて `RS512` に落とす**三項演算子のフォールバックを持つ（ECDSA 側も同型で、P-256 / P-384 以外を `ES512` に落とす）。
Web Crypto は RSASSA-PKCS1-v1_5 + SHA-1 の鍵インポートを受け付けるため、SHA-1 鍵を渡した OP は実際には SHA-1 で署名しながら、Discovery・JWKS・JOSE ヘッダで `RS512` を広告する。
SHA-1 を拒否する唯一のガード `extractAlgorithmParams`（CryptoKey 版）は、production コードから一度も呼ばれていない。

## 2. このトピックで確認したいこと

- `getJwaAlgorithm` の写像を網羅的にし、未知のハッシュ・曲線で例外を投げるべきか
- CryptoKey 版 `extractAlgorithmParams` が dead code である現状をどう扱うか（削除するか、鍵受け入れ経路に組み込むか）
- 鍵強度検証（`assertKeyStrength`）が RSA の modulus 長と EC の曲線しか見ず、ハッシュを検査しないことの整理

## 3. 関連する仕様・基準

- **RFC 7515 §4.1.1**: JOSE ヘッダの `alg` は、その JWS を保護するために**実際に使われた**アルゴリズムを識別する。署名は SHA-1、ヘッダは `RS512` という組み合わせは、この定義に反する
- **RFC 8725 §3.1-§3.3（JWT BCP）**: 適切なアルゴリズムの使用と、暗号入力の検証。SHA-1 ベースの RSASSA-PKCS1-v1_5 は JWA に定義が無く、署名用途では避けるべき
- **OIDC Discovery 1.0 §3**: `id_token_signing_alg_values_supported` は OP が実際に署名できるアルゴリズムを広告する。`discovery.ts` 自身が「鍵から導出することで広告と実態を一致させる」と説明しており、誤写像はその設計意図を破る

鍵強度検証の一般論は `study-material/done/signing-key-strength-and-parameter-validation.md` を参照。
なお同ファイルの「満たしていること」には SHA-1 拒否が `extractAlgorithmParams` によって効いていると読める記述があるが、この関数は production 経路から呼ばれていない。
本トピックはその前提の訂正を含む。

## 4. 参照資料

- RFC 7515 JSON Web Signature §4.1.1 — https://www.rfc-editor.org/rfc/rfc7515#section-4.1.1
- RFC 8725 JSON Web Token Best Current Practices — https://www.rfc-editor.org/rfc/rfc8725.html
- RFC 7518 JSON Web Algorithms §3.1（`alg` の定義一覧。RSA + SHA-1 の署名 `alg` は存在しない）— https://www.rfc-editor.org/rfc/rfc7518#section-3.1
- 本リポジトリ内: `study-material/done/signing-key-strength-and-parameter-validation.md`（modulus 長・曲線の検証。本ファイルはハッシュ写像の差分）

## 5. 現在の実装確認

- `packages/core/src/crypto-utils.ts:404-418`（`getJwaAlgorithm`）:

```typescript
if (algorithm.name === 'RSASSA-PKCS1-v1_5' && 'hash' in algorithm) {
  const hash = (algorithm as webcrypto.RsaHashedKeyAlgorithm).hash.name;
  return hash === 'SHA-256' ? 'RS256' : hash === 'SHA-384' ? 'RS384' : 'RS512';
}
```

SHA-1 を含む「その他」がすべて `RS512` になる。ECDSA 側（P-256 / P-384 以外 → `ES512`）も同型だが、Web Crypto は非 NIST 曲線のインポート自体を拒否するため、現実に到達するのは RSA + SHA-1 である。

- `packages/core/src/crypto-utils.ts:312`（`extractAlgorithmParams`、CryptoKey 版）: SHA-1 を明示的に拒否するが、呼び出し元はテストのみ。production で使われているのは JWK 版の `extractAlgorithmParamsFromJwk` であり、こちらは CryptoKey のハッシュを見ない
- `getJwaAlgorithm` の利用箇所: `discovery.ts`（`id_token_signing_alg_values_supported` の導出）、`jwks.ts`（公開 JWK の `alg`）、`id-token.ts` / `userinfo.ts` / `access-token.ts`（JWS ヘッダ）、`token-response.ts`（at_hash のハッシュ長決定）、`signing-key.ts`（`selectSigningKeyByAlg` / `assertHasRs256Key`）
- `packages/core/src/signing-key.ts`（`assertKeyStrength`）: RSA modulus 長と EC 曲線のみ検査し、ハッシュは見ない
- `importPrivateKeyFromJwk` は `algorithm` 引数を呼び出し側から受け取るため、`{ name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-1' }` を渡す経路が公開 API として存在する

## 6. 現在の実装との差分

満たしていること:

- SHA-256 / 384 / 512、P-256 / 384 / 521 の正常系写像は正しい
- modulus 長・曲線の強度検証は起動時に fail-closed で効いている

不足している可能性があること:

- 🟡 **未知ハッシュの黙った誤写像**: SHA-1 鍵で OP を構成すると、例外ではなく `RS512` の広告と署名ヘッダになる。RP の署名検証は全滅し（相互運用の破壊）、原因が「ヘッダと実アルゴリズムの不一致」であるため診断が難しい。ライブラリが他の箇所で掲げる「弱い鍵は署名する前に起動時に落とす」方針とも矛盾する
- 🟡 **dead code の存在**: SHA-1 ガードを持つ CryptoKey 版 `extractAlgorithmParams` が呼ばれておらず、レビュー資料も含めて「守られている」と誤認しやすい

## 7. 改善・追加を検討する理由

誤設定に対して黙って壊れた出力を生成するのは、fail-closed を方針とする本ライブラリの他の検証（鍵強度、`alg` ダウングレード防止）と整合しない。
修正は写像の網羅化という小さな変更で済み、既存の正常系挙動を変えない。
実装しない場合、SHA-1 鍵を渡した利用者は「全 RP で署名検証が失敗する OP」を原因表示なしで運用することになる。

## 8. 実装方針の候補

- **方針 A**: `getJwaAlgorithm` の三項フォールバックを明示的な分岐に置き換え、SHA-256 / 384 / 512、P-256 / 384 / 521 以外は `Unsupported hash algorithm: ...` / `Unsupported curve: ...` で throw する
- **方針 B**: 方針 A に加え、`assertKeyStrength` でもハッシュを検査して起動時に落とす（`resolveSigningKeyProvider` 経由の構成ミスを最初のトークン発行前に検出）
- **方針 C**: dead code の CryptoKey 版 `extractAlgorithmParams` は、用途が無ければ削除するか、テスト専用であることを JSDoc に明記する

方針 A は必須に近い。B / C は同時に行うかを人間が判断する。

## 9. タスク案

- `tasks/p2-jwa-algorithm-exhaustive-mapping.md` として切り出す
  - `getJwaAlgorithm` の写像を網羅化し、未知のハッシュ・曲線で throw
  - SHA-1 の RSA 鍵を渡すと throw されることをテストで固定（現状は `RS512` が返ることの回帰から Red を作れる）
  - `assertKeyStrength` へのハッシュ検査追加と dead code の扱いは、タスク内で方針を確定してから着手
