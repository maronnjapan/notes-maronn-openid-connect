# ID Token / UserInfo の JWE 暗号化対応（OIDC Core §16.7 / §5.3.2）

## ステータス

🟢 拡張機能 / 未着手

## 1. このトピックで確認したいこと

OpenID Connect Core は ID Token / UserInfo Response を **署名のみの JWS** に加え、**暗号化された JWE（JSON Web Encryption）**で配送することを許容する。
クライアントメタデータ（`id_token_encrypted_response_alg` / `id_token_encrypted_response_enc` / `userinfo_encrypted_response_alg` / `userinfo_encrypted_response_enc`）を持つクライアントに対し、OP は JWE を発行する責務を負う。

本リポジトリは現在 **署名のみ**実装（UserInfo の `userinfo_signed_response_alg` までは対応）。JWE 暗号化は実装も Discovery 広告も無い。

このファイルでは:

- JWE 暗号化対応を実装すべきかの判断材料
- 実装する場合の最小スコープと選択 alg/enc
- 既存の鍵管理 / 鍵 rotation との接続点

を整理する。Basic OP では JWE は必須ではない（OIDC Conformance Profiles の Basic OP プロファイルには暗号化テストは含まれない）が、Conformance Suite には Encrypted OP プロファイルが存在し、エンタープライズ要件で必須になることがある。

## 2. 関連する仕様・基準

共通の仕様索引は `study-material/basic-op-requirement-traceability.md` を参照。本トピック固有のポイント:

- **OIDC Core 1.0 §16.7 ID Token Encryption**: 署名済み ID Token をネスト化して JWE で暗号化（`Nested JWT`）。`alg` は鍵管理アルゴリズム、`enc` はコンテンツ暗号化アルゴリズム。
- **OIDC Core 1.0 §5.3.2 UserInfo Response**: UserInfo はクレーム JSON または JWT（署名・暗号化）で返却。署名と暗号化を組み合わせる場合は **署名→暗号化（ネスト JWT）**。
- **OIDC Registration 1.0 §2 / §16.7**: クライアントは `id_token_encrypted_response_alg` / `id_token_encrypted_response_enc`（および UserInfo 版）を登録できる。`enc` が指定され `alg` が未指定の場合の既定は `RSA1_5`（仕様上）。
- **OIDC Discovery 1.0 §3**: OP は以下を広告:
  - `id_token_encryption_alg_values_supported`
  - `id_token_encryption_enc_values_supported`
  - `userinfo_encryption_alg_values_supported`
  - `userinfo_encryption_enc_values_supported`
- **クライアントの鍵入手**: OP はクライアントの公開鍵を `jwks_uri` または `jwks` メタデータから取得（コンテンツ暗号化鍵を OP が生成し、クライアントの公開鍵で鍵ラップ）。
- **RFC 7516 JWE / RFC 7518 JWA**:
  - 鍵管理 alg（`alg`）: `RSA-OAEP`、`RSA-OAEP-256`、`ECDH-ES`、`ECDH-ES+A128KW`、`A128KW` 等。
  - コンテンツ暗号化 enc（`enc`）: `A128CBC-HS256`、`A256GCM` 等。
- **JWT BCP（RFC 8725）§3.4**: `RSA1_5` は CCA 攻撃に弱いため非推奨。`RSA-OAEP` / `RSA-OAEP-256` または ECDH-ES を推奨。

## 3. 参照資料

- OpenID Connect Core 1.0 §16.7: https://openid.net/specs/openid-connect-core-1_0.html#IDTokenEncryption
- OpenID Connect Core 1.0 §5.3.2: https://openid.net/specs/openid-connect-core-1_0.html#UserInfoResponse
- OpenID Connect Discovery 1.0 §3: https://openid.net/specs/openid-connect-discovery-1_0.html#ProviderMetadata
- RFC 7516 JWE: https://www.rfc-editor.org/rfc/rfc7516
- RFC 7518 JWA: https://www.rfc-editor.org/rfc/rfc7518
- RFC 8725 JWT BCP §3.4（鍵管理 alg の選定）: https://www.rfc-editor.org/rfc/rfc8725#section-3.4

## 4. 現在の実装確認

- ID Token: `packages/core/src/id-token.ts` / `token-response.ts` — JWS（RS256 既定）のみ発行
- UserInfo: `packages/core/src/userinfo.ts` — JSON 直接 or JWT 署名応答（`userinfo_signed_response_alg`）まで実装。暗号化（`userinfo_encrypted_response_alg` / `_enc`）の経路は無い
- Discovery: `packages/core/src/discovery.ts` — 暗号化アルゴリズム広告フィールド (`*_encryption_*_values_supported`) を **`ProviderMetadataConfig` に持たない**
- クライアントメタデータ: `ClientInfo` / `TokenClientInfo` に `id_token_encrypted_response_alg` 等のフィールド無し
- クライアント公開鍵入手経路（`jwks_uri` 解決）: 実装無し（DCR が無いので静的登録前提でも JWKS フェッチが必要）

## 5. 現在の実装との差分

- 🟢 **Basic OP プロファイルとしては差分ではない**: JWE は OIDC Core §15.1 必須機能に含まれない。
- 🟡 **エンタープライズ／Conformance Encrypted OP**: JWE が要件の検証 PoC では一切不可。
- 🟡 **クライアント設定 surface の空白**: クライアントメタデータが暗号化フィールドを保持できないため、利用者が「暗号化対応 IdP の差し替え検証」を行う準備にすらならない。
- 🟢 **Discovery の正直さは保たれている**: 広告フィールドを持たないので「対応していると見せかける」誤広告は無い。

## 6. 改善・追加を検討する理由

- 利用者の典型シナリオ「自分の要件がこの仕様で実現できるか」を考えたとき、医療・金融などで **PII を含む ID Token / UserInfo を必ず暗号化する**要件がある。署名のみで完結する PoC では十分だが、その先の本番 IdP（Auth0 / Keycloak / ID Token 暗号化サポートあり）への移行検証を想定するなら、暗号化経路の有無が分岐点になる。
- 本リポジトリは Web Crypto API のみで完結する設計のため、JWE 実装は外部依存無しで可能（RSA-OAEP / ECDH-ES / AES-GCM はすべて Web Crypto がサポート）。
- 一方、JWE 実装は **テストマトリクスが急増**（4 種類の `alg`、3 種類の `enc`、ネスト JWT、`zip` 圧縮の扱いなど）。OSS としての保守コストが高い。
- リリース v0.x（`study-material/RELEASE-v0.x-scope.md`）のスコープ判定上、暗号化は「v0.x スコープ外、後続継ぎ足し」が自然。

導入しやすさ:

- 鍵管理は OP 側は **クライアントの公開鍵を fetch**して使うため、OP の signing-key 管理は変えなくてよい。
- ただし JWKS フェッチャー（クライアントの `jwks_uri` をネットワーク取得 → キャッシュ）が必要になり、Cloudflare Workers 環境では `fetch` で動くが、KV キャッシュ等の追加配線が必要。

## 7. 実装方針の候補

### 方針A（非対応の明文化・現状維持）

- README / Discovery に「暗号化非対応」を明示。
- `id_token_encrypted_response_alg` 等が設定されたクライアントが来た場合、登録時または Authorization Request 時に明示エラー（`invalid_client_metadata` 相当）を返す。
- v0.x のスコープ外として `RELEASE-v0.x-scope.md` に「非スコープ」記載を提案。

### 方針B（最小実装: ID Token のみ・RSA-OAEP-256+A256GCM 固定）

- `id_token_encrypted_response_alg=RSA-OAEP-256` / `id_token_encrypted_response_enc=A256GCM` を **唯一サポート組合せ**として、それ以外を拒否。
- ネスト化（署名→暗号化）必須、`zip` 非対応。
- Discovery で `id_token_encryption_alg_values_supported: ['RSA-OAEP-256']` / `id_token_encryption_enc_values_supported: ['A256GCM']` を広告。
- クライアントの公開鍵は `ClientInfo.encryptionPublicJwk` として **静的に登録**（jwks_uri フェッチは方針 C で導入）。

### 方針C（フルセット）

- RSA-OAEP-256 / ECDH-ES+A128KW + A128CBC-HS256 / A256GCM の主要組合せ。
- クライアントの `jwks_uri` フェッチ + ETag キャッシュ。
- UserInfo の暗号化も同時対応。

### 方針D（クライアント Resolver 経由のプラグイン）

- core は「JWE 発行関数の I/F」だけ持ち、利用者が暗号化実装を注入できるようにする。Web Crypto API のみで動くデフォルト実装を CLI テンプレートで生成。

判断材料:

- 「Speed（最新仕様に最速で追随）」を取るなら方針 B が早い。
- 「Portability（どこでも動く）」を保つなら方針 C / D が望ましいが、ローカルで CryptoKey 種別の差異検証が必要。
- 「OSS 利用者が使いやすい」を取るなら、まず方針 A（非対応の明示）でハマりを防止し、需要があれば方針 B → C と継ぎ足すのが堅実。

## 8. タスク案

- [ ] 方針 A / B / C / D のどれを採用するか人間が判断する
- [ ] 方針 A 採用時: README と Discovery の整合（暗号化フィールドを意図的に出さない／クライアント登録時の早期拒否を実装）
- [ ] 方針 B 採用時:
  - [ ] `ProviderMetadataConfig` に `idTokenEncryptionAlgValuesSupported` / `idTokenEncryptionEncValuesSupported` を追加
  - [ ] `ClientInfo` / `TokenClientInfo` に `encryption_public_jwk` / `id_token_encrypted_response_alg` / `_enc` を追加
  - [ ] `packages/core/src/jwe.ts`（新規）: RSA-OAEP-256 + A256GCM の暗号化関数を Web Crypto API で実装
  - [ ] `token-response.ts` で「クライアントが暗号化を要求 → JWS をネスト JWT 化」する分岐を追加
  - [ ] テスト: 既知ベクトル（または往復テスト）で「OP が発行した JWE をクライアント側相当ロジックで復号できる」ことを確認
- [ ] 方針 C 採用時: 上記に加え UserInfo 暗号化 + `jwks_uri` フェッチャ + キャッシュ
- [ ] RFC 8725 §3.4 に従い、`RSA1_5` は **広告しないこと**をテストで固定
