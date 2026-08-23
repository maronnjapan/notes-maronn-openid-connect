# 拡張: SD-JWT（Selective Disclosure for JWTs）による選択的開示

## ステータス

🟢 Low（拡張・検討段階）/ 未着手

## 1. このトピックで確認したいこと

SD-JWT（Selective Disclosure for JWTs, RFC 9839 系の IETF OAuth WG 仕様）は、JWT の**個々のクレームを発行者が「選択的に開示可能」な形でハッシュ化して埋め込み**、保持者（Holder）が検証者（Verifier）に提示する際に**開示するクレームだけを選んで提示できる**汎用メカニズム。

本リポジトリには既に Verifiable Credentials 系の検討ファイルがあるが、それらは **OID4VCI（クレデンシャル発行フロー）/ OID4VP（クレデンシャル提示フロー）という「フロー」**を扱っており、その中で SD-JWT VC を「クレデンシャルフォーマットの一例」として言及しているにとどまる。

このファイルでは、フローから切り離した **「SD-JWT という選択的開示プリミティブそのもの」を core の署名・ハッシュ基盤の上で扱えるか**という差分に絞って整理する。具体的には:

- ID Token / UserInfo 応答を SD-JWT 化し、利用者（RP）が必要なクレームだけ受け取る／第三者へ最小開示で転送できるユースケースの可否
- SD-JWT の Disclosure 構造・`_sd` ハッシュ・Key Binding JWT を Web 標準 API（Web Crypto）のみで実装可能か
- 既存の `signing-key` / `jwks` / `id-token` 基盤との接続点

## 2. 関連する仕様・基準

共通の VC/フロー側の説明は重複させない。既存ファイルを参照すること:

- OID4VCI（発行フロー）: `study-material/ext-openid4vci-credential-issuance.md`（SD-JWT VC を発行フォーマットとして言及）
- OID4VP / SIOPv2（提示フロー）: `study-material/ext-openid4vp-siopv2-credential-presentation.md`（VP Token 内の SD-JWT VC 検証に言及）
- JWT 関連 BCP: `study-material/jwt-bcp-rfc8725.md`
- JWT アクセストークン: `study-material/jwt-access-token-rfc9068.md`
- JWS alg ポリシー: `study-material/jws-algorithm-policy-and-alg-none-defense.md`

本トピック固有のポイント（SD-JWT プリミティブそのもの）:

### 2.1 SD-JWT の構造（IETF OAuth WG: SD-JWT）

- 発行者は、選択的開示したいクレームを **Disclosure**（`[salt, claim_name, claim_value]` を base64url した文字列）として外に出し、JWT 本体（Issuer-signed JWT）には各 Disclosure の**ハッシュのみ**を `_sd` 配列に格納する。
- 全体は `<Issuer-signed JWT>~<Disclosure 1>~<Disclosure 2>~...~<optional KB-JWT>` の `~` 連結（Combined Format）で表現される。
- Holder は提示時に、開示したい Disclosure だけを残して提示する。検証者は残った Disclosure を再ハッシュして `_sd` と突き合わせ、開示クレームの真正性を検証する。
- **Key Binding JWT (KB-JWT)**: Holder が鍵を保持していることを証明し、提示の対象（aud / nonce）に束縛する。`cnf` クレームで Holder 公開鍵を JWT 本体に埋め込む。

### 2.2 SD-JWT VC との関係

- SD-JWT VC（`vc+sd-jwt`）は SD-JWT に `vct`（Verifiable Credential Type）等の追加規約を載せたプロファイル。既存の OID4VCI/OID4VP ファイルが扱うのはこの **VC プロファイル＋発行/提示フロー**。
- 本ファイルは、その土台である **SD-JWT 汎用メカニズム**（VC でない通常クレームの選択的開示にも使える）に焦点を当てる。

### 2.3 暗号要件

- ハッシュ（`_sd_alg`、既定 `sha-256`）、salt（クレームごとに十分なエントロピー）、署名（既存 RS256/ES256）はいずれも Web Crypto API で実装可能。
- ただし Disclosure の正規シリアライズ・順序・base64url 規約の厳密一致が相互運用の鍵で、テストでの固定検証が重要。

## 3. 参照資料

- Selective Disclosure for JWTs (SD-JWT) — IETF OAuth WG — https://datatracker.ietf.org/doc/draft-ietf-oauth-selective-disclosure-jwt/ （Disclosure 構造、`_sd`、KB-JWT、Combined Format。最新ステータス・RFC 番号は参照時に要確認）
- SD-JWT-based Verifiable Credentials (SD-JWT VC) — https://datatracker.ietf.org/doc/draft-ietf-oauth-sd-jwt-vc/ （`vct` 等の VC プロファイル）
- RFC 7515 JWS / RFC 7518 JWA — 署名・alg 基盤
- RFC 7800 `cnf`（Proof-of-Possession Key）— Holder 鍵束縛 — https://www.rfc-editor.org/rfc/rfc7800
- RFC 8725 JWT BCP — `study-material/jwt-bcp-rfc8725.md` 参照
- 本リポジトリ: `packages/core/src/crypto-utils.ts`（Web Crypto による署名/ハッシュ）、`packages/core/src/id-token.ts` / `packages/core/src/signing-key.ts` / `packages/core/src/jwks.ts`

## 4. 現在の実装確認

- SD-JWT の Disclosure 生成・`_sd` 埋め込み・Combined Format・KB-JWT 検証を行うコードは **存在しない**。
- ただし基盤は揃っている:
  - 署名/検証: `packages/core/src/crypto-utils.ts`（`sign` / `verify` / `sha256`）。
  - alg 選択・鍵プロバイダ: `packages/core/src/signing-key.ts`（`selectSigningKeyByAlg`）。
  - ID Token 生成: `packages/core/src/token-response.ts` / `id-token.ts`（通常 JWT の ID Token）。
  - ランダム生成: `crypto-utils.ts` `generateRandomString`（salt 生成に流用可能）。
- 既存 VC ファイル（`ext-openid4vci-credential-issuance.md` 等）は SD-JWT を「将来フォーマット」として言及するのみで、汎用 SD-JWT エンコーダ/デコーダの設計には踏み込んでいない。

## 5. 現在の実装との差分

満たしていること:

- ✅ SD-JWT に必要な暗号プリミティブ（SHA-256、base64url、RS256/ES256 署名）は Web Crypto のみで実装済み。外部依存なし方針と矛盾しない。
- ✅ `cnf` / Holder 鍵束縛に流用できる JWK 取り扱い基盤がある。

不足／要確認:

- 🟢 **SD-JWT エンコーダ/デコーダが無い**: Disclosure 配列・`_sd` ハッシュ生成・`~` 連結・部分開示・再ハッシュ検証のロジックがない。
- 🟢 **KB-JWT 検証が無い**: Holder 鍵束縛（`cnf` + KB-JWT の aud/nonce/iat 検証）の仕組みがない。
- 🟡 **正規化・相互運用の厳密性**: Disclosure の base64url/JSON シリアライズ規約は実装間差異が出やすく、相互運用テスト（公式テストベクタとの突合）が必須。
- 🟡 **Basic OP との独立性**: SD-JWT は Basic OP 認定要件に**含まれない**完全な拡張。導入してもコア認定挙動には影響しない（混同しないこと）。

## 6. 改善・追加を検討する理由

価値:

- **拡張性（Portability/Extensibility 軸）**: SD-JWT は VC エコシステム（EUDI Wallet, HAIP 等）の基盤フォーマットになりつつあり、「Web 標準 API だけで SD-JWT を扱える OSS」という差別化になり得る。
- **最小開示プライバシー**: ID Token / UserInfo のクレームを選択的開示にすることで、RP が必要最小限のクレームだけを下流に渡す設計を PoC で検証できる。
- **既存基盤との親和性**: 署名/ハッシュ/鍵管理が既に Web Crypto で実装済みのため、新規に必要なのは「Disclosure 構造とハッシュ突合」という比較的局所的なロジック。
- **OID4VCI/OID4VP の前提部品**: 既存の VC 検討（発行/提示フロー）を将来実装する場合、SD-JWT プリミティブはその土台になる。先に汎用部品として切り出しておくと再利用できる。

これは Basic OP 必須ではなく**完全な拡張機能**。導入是非は本ライブラリのロードマップ（VC 領域に踏み込むか）次第。

導入難易度:

- 🟡 中。暗号プリミティブは揃っているが、相互運用の厳密性（シリアライズ規約・テストベクタ準拠）に検証コストがかかる。mdoc/COSE/CBOR は対象外（SD-JWT は JSON/JWS ベースなので Web 標準で完結しやすい）。

実装しない場合:

- VC エコシステムへの接続点を持てない。ただし Basic OP としての価値は損なわれない（あくまで拡張の機会損失）。

## 7. 実装方針の候補

最終判断は人間が行う前提で整理する。

### 方針A（汎用 SD-JWT プリミティブのみを core に追加）

- `encodeSdJwt(claims, { disclosable: string[], signingKey })` と `verifySdJwt(combined, { verifyKey })` の純粋関数を core に追加。
- ID Token フローには組み込まず、独立ユーティリティとして提供（既存の `id-token.ts` は据え置き）。
- KB-JWT は任意（第二段で追加）。

### 方針B（ID Token / UserInfo の SD-JWT 化オプション）

- 既存の ID Token / UserInfo 生成に「選択的開示クレーム」を指定できるオプションを足す。
- クライアント登録メタデータで SD-JWT 応答を要求できるようにする（Discovery 広告も連動）。
- 影響範囲が広く、Basic OP 挙動との分離設計が必要。

### 方針C（VC ロードマップに統合）

- 本ファイルは独立タスク化せず、`ext-openid4vci-credential-issuance.md` / `ext-openid4vp-siopv2-credential-presentation.md` の前提部品として、VC 着手時にまとめて設計する。

### 方針D（現状維持）

- VC 領域に踏み込まない方針なら、本トピックは参照資料として保持し未着手のまま。

判断材料:

- 方針A は最小単位で再利用性が高く、VC に踏み込む前の布石として安全。
- 方針B はプライバシー最小開示を OP の機能として提供できるが、Basic OP との分離・テスト負荷が大きい。
- 本リポジトリの「主要フローを先に出す」方針（`CLAUDE.md`）からは、SD-JWT は明確に**後続フェーズ**の候補。

## 8. タスク案

> 本トピックは検討段階（VC ロードマップ依存）であり、方針未決定のため現時点では `tasks/` 化しない。VC 領域に着手する判断が下りた段階で、以下を起票候補とする。

- [ ] VC ロードマップ（OID4VCI/OID4VP）に踏み込むかを人間が判断（踏み込まないなら本トピックは保留）
- [ ] （方針A 採用時）SD-JWT 公式テストベクタを用いた `encodeSdJwt` / `verifySdJwt` の TDD 実装（Web Crypto のみ、外部依存なし）
- [ ] （方針A 採用時）Disclosure の base64url/JSON シリアライズ規約を固定し、相互運用テストで検証
- [ ] （第二段）KB-JWT（`cnf` + aud/nonce/iat）の生成・検証を追加
- [ ] 既存 VC ファイルから本プリミティブを参照する形に整理（重複排除）

## 関連トピック

- `study-material/ext-openid4vci-credential-issuance.md` / `study-material/ext-openid4vp-siopv2-credential-presentation.md` — VC の発行/提示**フロー**。本ファイルはその土台となる **SD-JWT 汎用プリミティブ**の差分のみを扱う。
- `study-material/jwt-bcp-rfc8725.md` / `study-material/jws-algorithm-policy-and-alg-none-defense.md` — SD-JWT の署名 alg 安全性の前提。
