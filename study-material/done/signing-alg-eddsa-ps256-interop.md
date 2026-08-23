# 署名アルゴリズムの拡張：RSA-PSS（PS256）/ EdDSA（Ed25519）対応の検討

## 1. タイトル

ID Token / UserInfo JWT / 各種 JWS 生成で OP が選べる署名アルゴリズムに **RSA-PSS（PS256/384/512）** と **EdDSA（Ed25519）** を追加するかの検討。相互運用性（FAPI 等のプロファイル要求）と拡張性、Portability（Web 標準 API での実現可否）のトレードオフを整理する。

## 2. このトピックで確認したいこと

- 現状の暗号レイヤ（`crypto-utils.ts` / `jwks.ts`）がサポートする署名 alg は何か、そこに PS256 / EdDSA が含まれるか。
- per-client の `id_token_signed_response_alg` 選択機構（`selectSigningKeyByAlg`）が既にあるが、選べる alg の母集合が RS\* / ES\* に限られていないか。
- PS256（FAPI 系で要求される）や EdDSA（モダンクライアントで採用増、鍵が小さく署名が速い）を追加する価値と、Web Crypto API での実現可否・Portability への影響。
- 既存ファイルとの関係（重複回避）:
  - `study-material/jws-algorithm-policy-and-alg-none-defense.md` … **検証側の allowlist / alg ピン / アルゴリズム混同 / `alg=none` 防御**を扱う。本ファイルは**署名（発行）側で扱える alg を増やす**という別論点。allowlist 設計の再説明はしない。
  - `study-material/signing-key-rotation-operations.md` … `kid` 戦略・鍵ローテーション運用。alg 追加とは別軸（追加した alg の鍵もこの運用に乗る）。
  - `study-material/ext-fapi-2-0-security-profile.md` … FAPI 2.0 を次の Conformance ターゲット候補として扱う。本ファイルはそこで必要になる署名 alg（PS256 / ES256）の暗号レイヤ対応という前提部品。
  - `study-material/id-token-and-userinfo-encryption-jwe.md` … JWE 暗号化。署名 alg とは独立。

## 3. 関連する仕様・基準

共通索引は `study-material/basic-op-requirements-baseline.md` を参照。本トピック固有の差分のみ記載。

### 3.1 JWA（RFC 7518）

- §3.1 の `alg` 値テーブルに `PS256` / `PS384` / `PS512`（RSASSA-PSS using SHA-256/384/512 と MGF1）が登録されている。
- §3.5: RSASSA-PSS。**salt 長は対応ハッシュの出力長と同じ**にすること（PS256 なら 32 バイト）。MGF は MGF1。

### 3.2 EdDSA（RFC 8037 / RFC 8032）

- RFC 8037（CFRG Curves in JOSE）が JOSE に `EdDSA` alg と OKP 鍵タイプ（`kty=OKP`, `crv=Ed25519` / `Ed448`）を追加。
- ID Token の JWS としても `alg=EdDSA`（Ed25519）が利用可能。JWK は `{"kty":"OKP","crv":"Ed25519","x":"..."}`。

### 3.3 OIDC Core 1.0 §15.1（必須 alg）

- OP は **RS256 を MUST**。PS256 / ES256 / EdDSA は **任意**。よって本トピックは Basic OP の必須要件ではなく、**相互運用・拡張**の文脈。
- per-client の `id_token_signed_response_alg`（OIDC Registration §2）で alg を選ばせる場合も RS256 鍵は必ず保持する（既に `assertHasRs256Key` で保証）。

### 3.4 FAPI 等プロファイルでの要求

- FAPI 1.0 Advanced / FAPI 2.0 のメッセージ署名は **PS256 または ES256** を要求（`RS256` は不可とするプロファイルがある）。ES256 は対応済みだが **PS256 は未対応**。FAPI を将来ターゲットにするなら PS256 は前提部品。

### 3.5 Web Crypto API での実現可否（Portability 観点）

- **RSA-PSS**: Web Crypto 標準アルゴリズム（`{ name: 'RSA-PSS', saltLength }`）。主要ランタイム（ブラウザ / Node / Deno / Cloudflare Workers）で広くサポートされ、Portability リスクは低い。
- **Ed25519**: 2026-07-21 時点の現行ランタイムでは `generateKey` / `sign` / `verify` / JWK `importKey`・`exportKey` が利用可能。ただし Web Cryptography Level 2 は Working Draft であり、古いブラウザや JWK の `alg` 処理に差が残るため、実装時は feature detection と RS256/ES256 フォールバックを維持する。

#### Ed25519 可用性調査（2026-07-21）

| 対象 | generate / sign / verify / JWK import-export | 根拠・制約 |
|---|---|---|
| Web Cryptography Level 2 | 定義あり | §25 が `Ed25519` の全対象操作を定義。First Public Working Draft のため仕様成熟度には注意 |
| Node.js | ✅ | Node 20.19.3 から stable。ローカル Node 24.18.0 で全操作とラウンドトリップを実測、フラグ不要 |
| Cloudflare Workers | ✅ | 公式 Web Crypto 対応表で標準 `Ed25519` の全対象操作をサポート。非標準 `NODE-ED25519` ではなく標準名を使う |
| Deno | ✅（公式情報） | Deno 1.26 で Ed25519 を実装。ローカル環境に Deno がないため実機再検証は未実施 |
| Chromium | ✅ | Playwright 同梱 HeadlessChrome 148.0.7778.96 で全操作とラウンドトリップを実測 |
| Firefox | ✅（公式情報） | Firefox 129 で `sign` / `verify` / `generateKey` / `importKey` / `exportKey` をサポート |
| Safari | ✅（公式情報、版差あり） | Safari 17 で Ed25519、18.4 で OKP 鍵生成・import/export を強化。Safari 26 で Edward 曲線 JWK の `alg` パラメータ対応を追加 |

ローカルの相互運用試験では、Node 24 が生成・署名した OKP JWK を Chromium 148 が検証し、Chromium が生成・署名した JWK を Node が検証できた。公開鍵は `kty=OKP`、`crv=Ed25519`、`x` は base64url 43 文字、秘密鍵の `d` も 43 文字、署名は 64 byte で一致した。

JWK の `alg` には注意が必要。Web Crypto が export する値は現行 Node / Chromium で `Ed25519` だが、JOSE で公開する `alg` は RFC 8037 の `EdDSA` である。実測した Node / Chromium は import 時に `alg=Ed25519`、`alg=EdDSA`、`alg` 省略のすべてを受理した一方、Safari は `alg` 対応が後から追加されている。したがって実装時は次を守る:

- Web Crypto のアルゴリズム名には `Ed25519` を使う。
- JWKS で公開する JOSE `alg` は `EdDSA` に正規化する。
- import 用 JWK は検証済みの `kty` / `crv` / key material を使い、互換性のため `alg` を除去してから `crypto.subtle.importKey` へ渡す。
- 初期化時に Ed25519 の feature detection を行い、未対応環境では明示的な設定エラーにする。Basic OP 必須の RS256 鍵と ES256 選択肢は残す。

結論: **EdDSA 実装は可能**。ただし全環境の無条件デフォルトにはせず、当面は opt-in の環境依存機能として提供するのが Portability 軸と整合する。サポート対象の最低バージョンを引き上げ、Safari 26 相当までを必須にできる時点で opt-in 解除を再評価する。

## 4. 参照資料

- RFC 7518 JWA §3.1（alg 値テーブル）/ §3.5（RSASSA-PSS, salt 長 = ハッシュ長）
  https://www.rfc-editor.org/rfc/rfc7518#section-3.5
- RFC 8037 CFRG Curves in JOSE（`EdDSA` alg / `kty=OKP` / `crv=Ed25519`）
  https://www.rfc-editor.org/rfc/rfc8037
- RFC 8032 EdDSA（Ed25519 署名アルゴリズム）
  https://www.rfc-editor.org/rfc/rfc8032
- OpenID Connect Core 1.0 §15.1（RS256 必須、他は任意）
  https://openid.net/specs/openid-connect-core-1_0.html#SigningOrder
- W3C Web Cryptography API（RSA-PSS / Ed25519 アルゴリズム）
  https://www.w3.org/TR/webcrypto-2/
- Node.js Web Crypto API（Ed25519 の追加・stable 履歴）
  https://nodejs.org/api/webcrypto.html
- Cloudflare Workers Web Crypto 対応表
  https://developers.cloudflare.com/workers/runtime-apis/web-crypto/
- Deno 1.26 Release Notes（WebCrypto Secure Curves）
  https://deno.com/blog/v1.26
- Firefox 129 release notes for developers
  https://developer.mozilla.org/en-US/docs/Mozilla/Firefox/Releases/129
- WebKit Features in Safari 17.0 / 18.4 / 26
  https://webkit.org/blog/14445/webkit-features-in-safari-17-0/
  https://webkit.org/blog/16574/webkit-features-in-safari-18-4/
  https://webkit.org/blog/16993/news-from-wwdc25-web-technology-coming-this-fall-in-safari-26-beta/

## 5. 現在の実装確認

- `packages/core/src/crypto-utils.ts`
  - `sign()`（L9-）… `RSASSA-PKCS1-v1_5` と `ECDSA` のみ分岐。**`RSA-PSS` / `Ed25519` は未対応**（else で未サポート扱い）。
  - `getJwaAlgorithm()`（L364-377）… RSA→`RS256/384/512`、EC→`ES256/384/512` のみ返す。**PS\* / EdDSA は throw**。
  - `extractAlgorithmParamsFromJwk()`（L312-340）… `kty=RSA`（RS\*）/ `kty=EC` のみ。**`kty=OKP`（Ed25519）未対応**。
- `packages/core/src/jwks.ts`
  - `exportPublicJwk()`（L54-）… `kty=RSA`（`n`/`e`）/ `kty=EC`（`crv`/`x`/`y`）のみ出力。**OKP（`crv=Ed25519`, `x`）未対応**。
- `packages/core/src/signing-key.ts`
  - `selectSigningKeyByAlg()`（L56-76）… per-client `id_token_signed_response_alg` で鍵を選ぶ機構は**実装済み**。ただし `getJwaAlgorithm` が PS\* / EdDSA を認識しないため、それらの鍵は選択肢に乗らない。
  - `assertHasRs256Key()`（L87-100）… RS256 必須保証は alg 追加後も不変。
- `packages/sample/src/oidc-provider/config.ts`
  - `RegisteredClient.idTokenSignedResponseAlg?: 'RS256' | 'ES256'` … 型として **PS256 / EdDSA は選べない**。

要約: per-client alg 選択の**枠組みは完成**しているが、**選べる alg の母集合が RS\* / ES\* に限定**されている。PS256 / EdDSA は暗号レイヤ（sign / getJwaAlgorithm / JWK 入出力）に追加実装が必要。

## 6. 現在の実装との差分

| alg | 署名 | JWKS 公開 | per-client 選択 | 状態 |
|---|---|---|---|---|
| RS256/384/512 | ✅ | ✅ | ✅ | 対応済み（RS256 は必須） |
| ES256/384/512 | ✅ | ✅ | ✅ | 対応済み（良好な相互運用） |
| PS256/384/512 | ❌ | ❌ | ❌ | **未対応**（FAPI 系で必要、Web Crypto は広くサポート） |
| EdDSA(Ed25519) | ❌ | ❌ | ❌ | **未対応**（モダン採用増、ただし Web Crypto 可用性に差 → Portability 要確認） |

- セキュリティ: PS256 / EdDSA とも RS256 より新しい/堅牢な署名。追加で攻撃面は増えないが、`jws-algorithm-policy` の allowlist にこれらを「明示的に許可した alg」として載せる必要がある（混同防止）。
- 相互運用: ES256 は既にあるが、**PS256 を要求する RP / プロファイル（FAPI 1.0 Advanced 等）に現状応えられない**のが最大の差分。

## 7. 改善・追加を検討する理由

- **なぜ価値があるか**: 本プロジェクトの差別化軸は Speed（新仕様への追随）と Fidelity（Conformance）。FAPI を将来ターゲットにする以上、PS256 は遅かれ早かれ必要になる前提部品。EdDSA は鍵・署名が小さく高速で、モバイル / IoT / モダン RP での採用が増えており、「最新仕様を最速で試せる」コンセプトと親和的。
- **Basic OP 必須か / 拡張か**: **どちらも Basic OP の必須ではない**（RS256 で充足）。純粋に相互運用・拡張ティア。よって優先度は中〜低だが、FAPI ターゲット化が決まれば PS256 は前提化する。
- **導入しやすさ**: per-client alg 選択（`selectSigningKeyByAlg`）と alg 派生（`getJwaAlgorithm`）の**差し込み口が既にある**ため、追加は局所的。具体的には `sign()` / `getJwaAlgorithm()` / `exportPublicJwk()` / `extractAlgorithmParamsFromJwk()` に分岐を足すだけ。
- **既存実装との接続**: `idTokenSignedResponseAlg` の型を広げ、`selectSigningKeyByAlg` がそのまま新 alg の鍵を選べるようになる。Discovery の `id_token_signing_alg_values_supported` は鍵集合から自動派生済みなので、新 alg 鍵を登録すれば広告も自動で正しくなる。
- **メリット**: PS256 で FAPI 系 RP と相互運用でき、EdDSA で軽量・高速な署名を選べる。
- **実装しない場合のリスク**: PS256 必須プロファイルの RP と接続できない。EdDSA を要求する新しめの RP に応えられない（Speed 軸の説得力が落ちる）。

## 8. 実装方針の候補（最終判断は人間）

判断材料の整理に留める。**PS256 と EdDSA は Portability 特性が異なるため分けて判断する**のが妥当。

- **方針 A: PS256/384/512（RSA-PSS）を先行追加**
  - `crypto-utils.sign()` に `RSA-PSS`（`saltLength` = ハッシュ長: PS256→32 / PS384→48 / PS512→64）分岐、`getJwaAlgorithm()` に RSA-PSS→`PS*` マッピング、`extractAlgorithmParamsFromJwk()` の `kty=RSA` で `alg=PS*` を受理、`verify()` 側も対応。JWKS は `kty=RSA` のまま（`n`/`e`）で `alg=PS256` を付与可能。
  - 注意: RSASSA-PKCS1-v1_5 鍵と RSA-PSS 鍵は Web Crypto 上で**用途（`usages`）と `name` が異なる** import が必要。`getJwaAlgorithm` は `key.algorithm.name` で判別するため、`RSASSA-PKCS1-v1_5` と `RSA-PSS` は正しく区別できる。
  - 長所: Portability リスク低、FAPI 前提を満たす。短所: 同じ RSA 鍵素材でも v1.5 と PSS で別 CryptoKey を import する運用整理が必要。
- **方針 B: EdDSA（Ed25519）を追加（Portability 確認後）**
  - `kty=OKP` / `crv=Ed25519` の JWK 入出力、`sign()`/`verify()` に `Ed25519` 分岐、`getJwaAlgorithm()` に OKP→`EdDSA` マッピングを追加。
  - **前提条件**: 対象ランタイム（少なくとも Node / Cloudflare Workers / Deno / 主要ブラウザ）で Web Crypto の `Ed25519` が利用可能であることを確認。未対応環境がある場合は「opt-in / 環境依存機能」と明示し、RS256/ES256 のフォールバックを必ず残す。
  - 長所: 軽量・高速・モダン。短所: Portability 差別化軸と衝突しうる（要事前検証）。
- **方針 C: 当面は型・ドキュメントのみ広げ、実装は需要ドリブン**
  - `idTokenSignedResponseAlg` の型に `'PS256'` を加える等、API 面の拡張余地だけ用意し、実装は FAPI ターゲット化の意思決定後に行う。
- 推奨の出発点: **方針 A（PS256）を Conformance/相互運用の前提部品として先行検討**。EdDSA（方針 B）は **Portability 検証タスクを先に回す**。

## 9. タスク案

- [ ] **（A）PS256 署名対応**: `crypto-utils.ts` の `sign()` / `verify()` / `getJwaAlgorithm()` / `extractAlgorithmParamsFromJwk()` に RSA-PSS（PS256/384/512, saltLength=ハッシュ長）分岐を追加。`jwks.ts` で `kty=RSA` + `alg=PS256` を公開できるようにする。
- [ ] **（A）テスト**: PS256 鍵で署名した ID Token / UserInfo JWT が `getJwaAlgorithm`→`PS256`、JWKS が `kty=RSA`/`alg=PS256` を返し、`selectSigningKeyByAlg(keys,'PS256')` が当該鍵を選び、検証が通ることを固定する。RS256 鍵との区別（`RSASSA-PKCS1-v1_5` vs `RSA-PSS`）も検証。
- [ ] **（A）Discovery 連動**: PS256 鍵を登録したとき `id_token_signing_alg_values_supported` に `PS256` が自動的に含まれることのテストを追加（既存の自動派生ロジックの回帰固定）。
- [x] **（B・調査）EdDSA Portability 検証**: Node / Cloudflare Workers / Deno / 主要ブラウザで Web Crypto の `Ed25519`（generateKey / sign / verify / import-export OKP JWK）が利用可能かを検証し、結果と opt-in 推奨を本ファイル §3.5 に追記した（2026-07-21）。
- [ ] **（B・調査結果次第）EdDSA 実装**: 調査で十分な可用性が確認できた場合に限り、`kty=OKP`/`crv=Ed25519` の JWK 入出力と `EdDSA` 署名・検証・alg 派生を追加する。未対応環境向けに RS256/ES256 フォールバックを保証する。
- [ ] **allowlist 整合**: 追加した alg を `study-material/jws-algorithm-policy-and-alg-none-defense.md` の検証 allowlist 方針に反映（明示許可リストに追加、`none`/`HS*` は除外のまま）。
