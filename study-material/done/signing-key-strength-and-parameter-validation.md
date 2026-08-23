# 署名鍵の強度・パラメータ検証（弱い RSA / 非承認 EC 曲線 / `use`・`key_ops` の拒否）

## ステータス

🟠 High（セキュリティ）/ 未着手

## 1. このトピックで確認したいこと

本リポジトリは `SigningKeyProvider` 経由で登録された鍵を ID Token / JWT アクセストークン / UserInfo JWT の署名に使い、その公開鍵を JWKS で配布する。鍵の **import 経路**（`crypto-utils.ts` の `importKeyFromJwk` / `extractAlgorithmParamsFromJwk`）が、**鍵そのものの暗号学的強度を検証していない**点を確認する。

具体的に扱う差分:

- RSA 鍵の **モジュラス長（鍵長）下限**を強制していない（512bit / 1024bit の弱鍵でも import が通る）
- EC 鍵の曲線は `extractAlgorithmParamsFromJwk` で `P-256 / P-384 / P-521` に限定しているが、これは「対応 alg の解決」目的であり、「鍵強度ポリシー」として明示的にレビューされていない
- JWK の `use`（`sig`）/ `key_ops`（`sign` / `verify`）の整合チェックが無く、暗号化用途の鍵を署名に流用できてしまう余地がある
- RSA 公開鍵が HMAC 共通鍵として誤用される「alg confusion」防御は `study-material/jws-algorithm-policy-and-alg-none-defense.md` で alg 側から扱っているが、**鍵パラメータ側の最低保証**は未集約

本ファイルは「どの alg を受け入れるか」（= `jws-algorithm-policy-and-alg-none-defense.md`）でも「鍵をいつ回す/退役させるか」（= `signing-key-rotation-operations.md`）でもなく、**「登録時点でその鍵がそもそも安全な強度を満たしているか」**という未カバーの差分に絞る。

## 2. 関連する仕様・基準

共通の仕様索引は `study-material/basic-op-requirement-traceability.md` を参照。本トピック固有のポイント:

- **RFC 8725（JWT BCP）§3.3 Validate All Cryptographic Operations / §3.5 Ensure Cryptographic Keys Have Sufficient Entropy**: 署名鍵は十分な強度（鍵長・エントロピー）を持たねばならない。`study-material/jwt-bcp-rfc8725.md` の対応表では §3.3/§3.5 を **本ファイルの前段である `signing-key-rotation-operations.md` に委譲**しているが、当該ファイルは「ローテーション運用フロー」を扱っており、**鍵長下限の検証ロジックは未整理**。本ファイルがその差分を埋める。
- **NIST SP 800-57 Part 1 Rev.5 / SP 800-131A Rev.2**: 2030 年以降も使える非対称鍵強度として **RSA 2048bit 以上（112bit 強度）**、EC は P-256 以上を推奨。RSA 1024bit は 2013 年に deprecated、現在は disallowed。
- **FAPI 1.0 / FAPI 2.0 Security Profile**: 署名鍵は RSA 2048bit 以上を要求。将来 `study-material/ext-fapi-2-0-security-profile.md` を満たすうえでも前提になる。
- **RFC 7517（JWK）§4.2 `use` / §4.3 `key_ops`**: 鍵の用途を宣言する。署名検証鍵は `use=sig` または `key_ops` に `verify`/`sign` を含めるべきで、`use=enc` の鍵を署名に使うのは用途違反。
- **OIDC Core 1.0 §10.1**: OP は ID Token の署名に用いる非対称鍵を JWKS で公開する。配布する鍵が弱いと、クライアント側の検証は成功するが**第三者が現実的な計算量で偽造可能**になり、信頼チェーン全体が崩れる。

注意: Basic OP 認定の Conformance テストは「弱鍵の拒否」を直接は叩かない（テスト鍵は十分強い）。したがって本トピックは **認定ブロッカーではなく、本番運用時のセキュリティ・ハードニング**として位置づける。

## 3. 参照資料

- RFC 8725 JSON Web Token Best Current Practices §3.3, §3.5 — https://www.rfc-editor.org/rfc/rfc8725#section-3.3 （鍵パラメータ検証・鍵強度）
- RFC 7517 JSON Web Key §4.2 `use` / §4.3 `key_ops` — https://www.rfc-editor.org/rfc/rfc7517#section-4.2
- NIST SP 800-131A Rev.2 — https://csrc.nist.gov/pubs/sp/800/131/a/r2/final （RSA 2048bit 以上、1024bit disallowed）
- NIST SP 800-57 Part 1 Rev.5 — https://csrc.nist.gov/pubs/sp/800/57/pt1/r5/final （鍵強度の等価ビット表）
- OpenID Connect Core 1.0 §10.1 Signing — https://openid.net/specs/openid-connect-core-1_0.html#Signing
- 本リポジトリ内の関連（重複説明回避のため参照に留める）:
  - `study-material/jws-algorithm-policy-and-alg-none-defense.md`（alg 許容リスト・alg confusion）
  - `study-material/signing-key-rotation-operations.md`（鍵のライフサイクル・退役）
  - `study-material/jwt-bcp-rfc8725.md`（§3.3/§3.5 を本ファイルへ委譲する旨の対応表）

## 4. 現在の実装確認

- `packages/core/src/crypto-utils.ts`
  - `importKeyFromJwk(jwkString, algorithm, extractable, keyUsages)`（189–207 行）: `JSON.parse` した JWK を `crypto.subtle.importKey('jwk', jwk, algorithm, ...)` にそのまま渡す。**モジュラス長や曲線の強度チェックは無い**。WebCrypto の `importKey` は 512bit / 1024bit RSA でも成功するため、弱鍵が通る。
  - `importPrivateKeyFromJwk` / `importPublicKeyFromJwk`（222–257 行）: 上記の薄いラッパ。検証は追加していない。
  - `extractAlgorithmParams(key)`（272–299 行）: **SHA-1 ハッシュのみ明示拒否**（280–282 行）。鍵長は見ていない。
  - `extractAlgorithmParamsFromJwk(jwk)`（312–340 行）: EC は `P-256 / P-384 / P-521` 以外を `Unsupported EC curve` で拒否、RSA は `RS256/384/512` 以外の alg を拒否。これは「alg 解決」のための制約であり、**RSA モジュラス長は未検証**。
  - `use` / `key_ops` フィールドは参照していない。
- `packages/core/src/signing-key.ts`
  - `assertHasRs256Key()`: RS256 鍵が 1 つ以上あることは保証するが、その鍵の**強度**は問わない。
- `packages/core/src/jwks.ts`
  - `exportPublicJwk` / `exportJwks`: 登録鍵を JWKS として export。弱鍵もそのまま公開してしまう。

## 5. 現在の実装との差分

満たしていること:

- SHA-1 ハッシュの明示拒否（`extractAlgorithmParams`）。
- EC 曲線は実質 P-256 以上に限定（`extractAlgorithmParamsFromJwk`）。結果として EC 側は強度の下限が事実上担保されている。
- alg confusion / `alg=none` は別ファイルでガード済み。

不足／曖昧な点:

- 🟠 **RSA モジュラス長の下限が無い**: `importKeyFromJwk` は 1024bit 以下の RSA 鍵を受理する。OSS 利用者が誤って弱い鍵（古いツールが生成した 1024bit 等）を設定しても、起動時にもリクエスト時にも警告が出ない。配布される ID Token は「検証は通るが偽造可能」になる。
- 🟡 **`use` / `key_ops` の用途検証が無い**: `use=enc` 用途の鍵を署名鍵として登録しても弾かれない。RFC 7517 §4.2/§4.3、RFC 8725 §3.4（Cryptographic Inputs）の観点で要改善。`jwt-bcp-rfc8725.md` の §3.4 行と接続する論点だが、当該ファイルは「受信 JWT の鍵用途」を扱い、本ファイルは「自分が登録・公開する署名鍵の用途宣言」を扱う差分。
- 🟡 **強度ポリシーの集約点が無い**: 「OP が署名鍵として受け入れる最小強度（RSA 2048bit / EC P-256 以上）」がコードにもドキュメントにも明文化されていない。FAPI ターゲット時に再議論が発生する。
- 🟢 **エラーメッセージの方針**: 弱鍵を拒否する場合、起動時（`assertHasRs256Key` の隣で `assertKeyStrength`）か、JWKS 構築時か、import 時かで、どこで fail-closed にするかが未決。

セキュリティ的観点:

- 🔴 弱い署名鍵は **ID Token 偽造 → なりすまし**に直結する最上位リスク。alg を厳格にしても鍵自体が弱ければ意味がない。本リポジトリは「セキュリティ最優先」を方針に掲げているため、鍵強度の下限保証は方針と整合する。

相互運用性の観点:

- 🟡 大手 IdP・ライブラリは弱鍵を拒否する。本 OP が弱鍵を許すと、利用者が「動いた」と誤認したまま本番に持ち込み、後段の Conformance / FAPI 認定や相手システムの鍵ポリシーで弾かれて初めて気付く。早期に拒否する方が PoC → 本番移行の体験が良い。

## 6. 改善・追加を検討する理由

- **価値**: ID Token の偽造耐性は Basic OP の信頼の根幹（差別化軸 "Fidelity"）。弱鍵を起動時に fail-closed で弾くだけで、利用者の最悪事故（弱鍵での本番運用）を構造的に防げる。
- **Basic OP として必須か**: 認定テストの直接対象ではない（拡張的ハードニング）。ただし「本番志向の OSS」を名乗るうえでは実質的に必要。
- **導入しやすさ**: `crypto-utils.ts` / `signing-key.ts` に**純粋関数の検証 1 つを足すだけ**で済み、既存の `assertHasRs256Key` と同じ場所・同じパターンに乗る。鍵の modulus 長は `JsonWebKey.n`（base64url のバイト長 × 8 ≈ ビット長）から算出可能で、外部ライブラリ不要（方針：dependencies に外部ライブラリを足さない制約を満たす）。
- **既存実装との接続**: `assertHasRs256Key(keys)` の隣に `assertKeyStrength(keys, policy)` を追加し、`buildProviderMetadata`（discovery.ts）と起動時チェックの両方から呼べる。
- **実装しない場合のリスク**: 「rotation も alg も厳格」だが「鍵強度は無検証」という穴が残る。セキュリティ文書としての一貫性が欠ける。

## 7. 実装方針の候補

最終判断（下限値・どこで fail させるか・既定で強制か警告か）は人間が行う。判断材料を整理する。

- **方針A（起動時アサーション）**: `signing-key.ts` に `assertKeyStrength(keys, { minRsaModulusBits = 2048, allowedCurves = ['P-256','P-384','P-521'] })` を新設。`assertHasRs256Key` と同様、登録鍵集合に対して起動時に評価し、弱鍵があれば throw（fail-closed）。最小コストで効果最大。
- **方針B（import 時検証）**: `importKeyFromJwk` 内で JWK の `n` 長 / `crv` / `use` / `key_ops` を検証してから `importKey` に渡す。すべての import 経路を一括で守れるが、`id_token_hint` 等「外部 JWT の検証鍵 import」にも影響するため、署名鍵登録経路と検証鍵 import 経路で**ポリシーを分けられる設計**が必要。
- **方針C（ポリシー注入）**: 下限値や `use` 強制の有無を `SigningKeyProvider` 設定 / オプションとして外部注入し、core はデフォルト値のみ持つ（既存の resolver 注入思想と整合）。FAPI プロファイルでは下限を引き上げる、といった切り替えが可能。
- **方針D（警告＋ドキュメント）**: 拒否はせず、弱鍵検出時に `console.warn` 相当の通知とドキュメント明記に留める。後方互換は最も高いが、本リポジトリのセキュリティ最優先方針とは弱い整合。

RSA モジュラス長の算出は、JWK の `n`（base64url）をデコードした先頭ゼロを除いたバイト長から導出する純粋関数で実現できる（Web 標準 API のみ）。

## 8. タスク案

- [ ] 受け入れ最小強度（RSA bit 数下限・許容 EC 曲線・`use`/`key_ops` を強制するか）を人間が決定する
- [ ]（方針A採用時）`signing-key.ts` に `assertKeyStrength(keys, policy)` を追加し、`assertHasRs256Key` と同じ起動経路から呼ぶ
- [ ]（TDD）`signing-key.test.ts` / `crypto-utils.test.ts`: 1024bit RSA 鍵を登録すると拒否される / 2048bit は通る / 非承認曲線は拒否される / `use=enc` 鍵は署名鍵として拒否される（強制する場合）テストを先に追加
- [ ] JWK の `n`（base64url）からモジュラスビット長を求める純粋ヘルパ（外部依存なし）を実装
- [ ] `study-material/jwt-bcp-rfc8725.md` の §3.3/§3.5 行と `study-material/jws-algorithm-policy-and-alg-none-defense.md` から本ファイルへ相互リンクを張り、責務境界を明確化
- [ ] FAPI ターゲット時に下限を引き上げる設計余地（方針C）を `study-material/ext-fapi-2-0-security-profile.md` に注記

## 関連トピック

- `study-material/jws-algorithm-policy-and-alg-none-defense.md` — 受け入れ **alg** のポリシー（本ファイルは受け入れ **鍵強度** のポリシー）
- `study-material/signing-key-rotation-operations.md` — 鍵の **ライフサイクル/退役**（本ファイルは **登録時点の強度ゲート**）
- `study-material/jwt-bcp-rfc8725.md` — RFC 8725 全体の監査ハブ（§3.3/§3.5 の実装差分を本ファイルへ委譲）
