# 署名鍵の強度検証で RSA 公開指数 `e` を検証していない（退化指数の受理リスク）

## 1. タイトル

起動時フェイルクローズ検証 `assertKeyStrength` が、RSA 鍵をモジュラス長（`n` のビット長）だけで判定し、公開指数 `e` を一切検査しないため、`e=1` / `e=3` / 偶数など退化・脆弱な指数を持つ RSA 署名鍵が「強い鍵」として JWKS に公開され ID Token 署名に使われうる問題。

## 2. このトピックで確認したいこと

- `assertKeyStrength` の RSA 分岐は `jwk.n` の有無とビット長のみを見て `continue` しており、`jwk.e`（公開指数）を参照しない
- `KeyStrengthPolicy` には `minRsaModulusBits` / `allowedCurves` はあるが指数に関するフィールドが無い
- 退化指数（特に `e=1`）は RSASSA 検証を実質「署名 ≡ パディング済みメッセージ」に縮退させ、ID Token 署名の偽造を容易にしうる。にもかかわらず本検証は「2048bit だから強い」と判定してしまう
- 本トピックは既存の鍵強度検証（モジュラス長・EC 曲線・`use`/`key_ops`）の**差分**として、公開指数の検査という未カバー観点を扱う

## 3. 関連する仕様・基準

共通の鍵強度検証（モジュラス長・曲線・`use`/`key_ops`）の説明は重複させない。既存の確定事項:

- RSA モジュラス長（>=2048bit, NIST SP 800-131A Rev.2）・EC 曲線許可リスト・`use`/`key_ops` 検証: `study-material/signing-key-strength-and-parameter-validation.md` / `tasks/done/p1-signing-key-strength-validation.md`
- 鍵の暗号操作全般の妥当性・十分なエントロピー（RFC 8725 §3.3 / §3.5）は上記および `study-material/jwt-bcp-rfc8725.md` が扱う（ただし公開指数の具体検査は未言及）

本トピック固有の差分（公開指数の妥当性）に関する根拠:

- **NIST FIPS 186-5 §5.1（RSA key pair generation）** および **NIST SP 800-56B Rev.2 §6.4.1.1**: RSA 公開指数 `e` は奇数で、`65537 ≤ e < 2^256` の範囲にあること（`e=1`, `e=3`, 偶数, 過大な指数は不適格）。デファクトでは `e=65537`（`0x010001`）が標準
- **RFC 8725（JWT BCP）§3.3（Validate All Cryptographic Operations）**: 署名検証を含む暗号操作は妥当性を検証すること。鍵パラメータが不正なら検証結果は信頼できない
- **OIDC Core 1.0 §10.1（Signing）**: OP は非対称署名鍵を JWKS で公開する。脆弱な公開鍵は「クライアントは検証に成功するのに偽造が可能」という状態を生む

留保・脅威モデル（事実の切り分け）:

- 署名鍵は **OP 運用者が投入する**もので、外部攻撃者が直接注入できるものではない。したがって本件は「外部からの能動的攻撃面」ではなく、**運用者の設定ミス/不正鍵をフェイルクローズで弾く hardening**の範疇
- 一部の WebCrypto `importKey` 実装は最も退化した指数（`e=1` 等）を独自に拒否する可能性がある。ただしこれは実装依存であり、`assertKeyStrength` が明示的に保証している性質ではない（= 移植性を掲げる本ライブラリとして自前検証で担保するのが筋）
- Basic OP 認定テストの合否には直結しない（Conformance の鍵は常に整形式）。本件は認定ブロッカーではなく、本リポジトリの「security-first・起動時フェイルクローズ検証」思想に沿った拡張

## 4. 参照資料

- NIST FIPS 186-5 Digital Signature Standard §5.1 — https://csrc.nist.gov/pubs/fips/186-5/final （RSA 公開指数の要件）
- NIST SP 800-56B Rev.2 §6.4.1.1 — https://csrc.nist.gov/pubs/sp/800/56/b/r2/final （`65537 ≤ e < 2^256`, 奇数）
- RFC 8725 JSON Web Token Best Current Practices §3.3 — https://www.rfc-editor.org/rfc/rfc8725#section-3.3
- OpenID Connect Core 1.0 §10.1 Signing — https://openid.net/specs/openid-connect-core-1_0.html
- 本リポジトリ内: `study-material/signing-key-strength-and-parameter-validation.md`（モジュラス長・曲線・use。本ファイルは公開指数の差分）

## 5. 現在の実装確認

- `packages/core/src/signing-key.ts:182-195`（RSA 分岐）:
  - `if (!jwk.n)` でモジュラス欠如を拒否
  - `rsaModulusBitLength(jwk.n) < minRsaModulusBits` でビット長を検査
  - いずれも通れば `continue` — `jwk.e` は読まれない
- `packages/core/src/signing-key.ts:137-142`（`KeyStrengthPolicy`）: `minRsaModulusBits` と `allowedCurves` のみ。指数フィールド無し
- `packages/core/src/crypto-utils.ts`（`rsaModulusBitLength`）: 強度を `n` のみから導出。指数の随伴検査は存在しない
- `packages/core/src/signing-key.test.ts`: テスト鍵は `publicExponent: new Uint8Array([1,0,1])`（=65537）を使用。退化指数の負テストは無く、挙動が未規定・未テストであることを裏付ける

## 6. 現在の実装との差分

満たしていること:

- RSA モジュラス長（>=2048bit）・EC 曲線・`use`/`key_ops` の起動時フェイルクローズ検証は実装済み（既存タスクの成果）
- `assertHasRs256Key` と併せ、弱い鍵が署名に使われる前に起動時に弾く思想が確立

セキュリティ上、改善した方がよいこと:

- 🟡 **公開指数 `e` の未検査**: `e=1`（署名偽造がほぼ自明）・`e=3`（低指数攻撃の懸念文脈）・偶数・過小/過大指数を持つ RSA 鍵が強度検証を通過し、JWKS 公開・ID Token 署名に使われうる。`assertKeyStrength` は「強い」と報告するため、運用者は脆弱性に気づけない
- 🟡 **ポリシーの表現力不足**: `KeyStrengthPolicy` に指数制約が無く、FAPI 等でより厳格にしたい場合の注入口も無い

Basic OP として提供する上で確認すべきこと:

- 認定合否には出ないが、"security-first" と "Portability（自前検証で環境非依存に担保）" を掲げるライブラリとして、WebCrypto 実装依存に委ねず自前で弾くのが一貫する

## 7. 改善・追加を検討する理由

- **セキュリティ（設定ミス防御）**: ID Token 署名鍵の健全性は OP の信頼の根幹。退化指数はレアだが、鍵生成スクリプトのバグや手組み JWK の誤りで混入しうる。フェイルクローズで起動時に弾けば、被害が発生する前に検知できる
- **導入接続性**: 既存 `assertKeyStrength` の RSA 分岐に数行（`e` を base64url デコードし、奇数かつ `65537 ≤ e`、上限チェック）を足すだけで局所導入できる。`KeyStrengthPolicy` に `minRsaPublicExponent`/`requireStandardExponent` 等のオプションを足す拡張も既存パターンに沿う
- **実装しない場合のリスク**: 「起動時に弱い鍵を弾く」と謳いつつ、指数由来の弱鍵はすり抜ける。移植先ランタイムによっては WebCrypto も弾かず、偽造可能な ID Token を配布する OP が起動してしまう

## 8. 実装方針の候補

- 方針A（標準指数の強制）: 既定で `e === 65537`（`AQAB`）のみ許可し、それ以外を拒否。最も安全側だが、正当な非標準指数（稀）も弾く。ポリシーで緩和可能にする
- 方針B（範囲・奇偶検査）: `e` を整数化し「奇数 かつ `65537 ≤ e < 2^256`」（NIST SP 800-56B）を満たすかで判定。標準に忠実で `65537` 以外の妥当指数も許容
- 方針C（下限のみ）: 最低限 `e=1`（および偶数・過小指数）だけを弾く軽量チェック。退化ケース排除に絞る
- 方針D（ポリシー注入）: `KeyStrengthPolicy` に指数関連フィールドを追加し、core は既定安全値を持ちつつ利用者が調整できるようにする（FAPI 等の厳格化に対応）

既定を A/B/C のどれにするか、`KeyStrengthPolicy` を拡張するか、WebCrypto 実装差（`importKey` が退化指数を独自に弾くか）の実測を前提にするかは人間が決定する。

## 9. タスク案

- [ ] 既定ポリシー（方針 A/B/C）と `KeyStrengthPolicy` 拡張の要否（方針D）を決定
- [ ] （TDD）`signing-key.test.ts` に退化指数の負テストを先に追加: `e=1` / `e=3`（方針次第）/ 偶数指数 / 空・過小 `e` → `assertKeyStrength` が throw。正常系（`e=65537`）は通過
- [ ] `packages/core/src/signing-key.ts` の RSA 分岐に公開指数検査を実装（`jwk.e` を base64url デコードして判定。エラーメッセージは `keyId` を含めログ限定・`error_description` に出さない）
- [ ] （方針D）`KeyStrengthPolicy` に指数制約フィールドを追加し既定値を設定
- [ ] `study-material/signing-key-strength-and-parameter-validation.md` の検査対象一覧に「公開指数」を追記（相互参照）
