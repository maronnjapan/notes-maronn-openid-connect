# 拡張: FAPI 2.0 Security Profile（次の Conformance ターゲット候補）

## ステータス

🟢 拡張機能 / 検討段階（方針未決定）

## 1. このトピックで確認したいこと

Basic OP の次の **Conformance / Fidelity ターゲット**として、FAPI 2.0 Security Profile（OpenID Foundation, FAPI WG）を据えるべきかを整理する。

このリポジトリの差別化軸は **Speed / Fidelity / Portability**（`CLAUDE.md` 参照）であり、「Conformance 準拠を信頼性のシグナルとして維持する」ことを掲げている。Basic OP は最初の Conformance ターゲットだが、金融・行政・ヘルスケアなど高保証ユースケースの PoC を意識すると、**FAPI 2.0 が次の自然な認証プロファイル**になる。

ここで確認したいのは以下:

- FAPI 2.0 が要求する個別要素は、本リポジトリで **すでにどこまで揃っているか**（多くが既存 study-material / tasks で扱い済み）。
- FAPI 2.0 を「プロファイルとして束ねる」ために **追加で必要なのは何か**（個々の機能ではなく、組み合わせの強制・Discovery 整合・Attacker Model 対策）。
- 本リポジトリの構成（core はロジック層、CLI が生成、resolver 注入）から見て導入しやすいか。

> 注意: FAPI 2.0 を構成する個別仕様（PAR / DPoP / mTLS / JAR / JARM / iss パラメータ / PKCE / Refresh Rotation）の **詳細はそれぞれの既存ファイルに記載済み**。本ファイルでは重複説明を避け、「FAPI 2.0 として束ねるための差分」に絞る。

## 2. 関連する仕様・基準

共通の仕様索引は `study-material/basic-op-requirement-traceability.md` を参照。本トピック固有のポイントのみ記載する。

### FAPI 2.0 Security Profile が要求する構成要素（要点）

FAPI 2.0 Security Profile は OAuth 2.1 / Security BCP（RFC 9700）の上に、攻撃者モデル（FAPI 2.0 Attacker Model）に耐える形で以下を **MUST** として束ねる。

| FAPI 2.0 要求 | 本リポジトリでの扱い（既存ファイル参照） |
|---|---|
| **PAR（RFC 9126）必須**。すべての認可リクエストは PAR 経由 | `ext-pushed-authorization-requests-rfc9126.md` / `extension-pushed-authorization-requests-par.md` |
| **Sender-Constrained Access Token**（mTLS RFC 8705 **または** DPoP RFC 9449） | `ext-mtls-rfc8705.md` / `tasks/T-019-dpop.md` |
| **PKCE（S256）必須**、`plain` 拒否 | `study-material/done/pkce-code-challenge-format-validation.md` |
| **認可レスポンスの `iss` パラメータ（RFC 9207）必須**（mix-up 対策） | `tasks/done/p1-authorization-response-iss.md` |
| **Authorization Code Flow のみ**（implicit / hybrid 禁止） | `study-material/done/oauth21-removed-grants-explicit-rejection.md` / `ext-multiple-response-types-hybrid-flow.md` |
| **confidential client は `private_key_jwt` または mTLS で認証**（`client_secret_basic`/`post` は不可） | `ext-private-key-jwt-client-auth.md` / `ext-mtls-rfc8705.md` |
| **redirect_uri 完全一致** | `study-material/done/client-metadata-enforcement.md` / `tasks/done/p0-redirect-uri-fragment-rejection.md` |
| **Refresh Token は rotation または sender-constrained** | `refresh-token-rotation-replay-grace.md` |
| **`scope` または RFC 8707 `resource` による audience 制限** | `ext-resource-indicators-rfc8707.md` |

### FAPI 2.0 Message Signing（別仕様・任意）

非否認（non-repudiation）が必要な場合の上乗せプロファイル。**Security Profile とは別物**であり、必須ではない。

- リクエスト署名: JAR（`ext-jar-request-object-rfc9101.md`）
- レスポンス署名: JARM（`ext-jarm-jwt-secured-authorization-response.md`）
- Introspection 署名: RFC 9701（`ext-jwt-introspection-response-rfc9701.md`）

→ 構成部品はすべて既存トピックでカバー済み。Message Signing は「束ねる」だけ。

### FAPI 2.0 として「新規に」必要になる差分

個々の機能ではなく、**プロファイルとしての強制と整合**が新規論点:

1. **PAR の強制**: FAPI 2.0 ではフロントチャネルに認可パラメータを直接乗せず PAR 必須。`require_pushed_authorization_requests=true` 相当の client / server ポリシー。
2. **client_secret_basic/post の禁止**: 既存 `client-auth.ts` は `client_secret_basic` / `client_secret_post` のみ実装。FAPI クライアントでは **これらを拒否**し、`private_key_jwt` / mTLS を要求するポリシー切替が必要。
3. **Sender-Constrained の強制と整合**: access token に `cnf`（mTLS は `x5t#S256`、DPoP は `jkt`）を必ず付与し、UserInfo / RS 側で検証。
4. **Discovery の FAPI 整合**: `require_pushed_authorization_requests`、`tls_client_certificate_bound_access_tokens`、`dpop_signing_alg_values_supported`、`token_endpoint_auth_methods_supported` を FAPI 準拠値で広告。広告と実挙動の不一致は Conformance / honesty 違反（`request-object-rejection-and-discovery-honesty.md` の honesty 原則）。
5. **Attacker Model 対策の明示**: FAPI 2.0 Attacker Model は「認可リクエスト/レスポンスの改ざん・注入」を含む。PAR + PKCE + iss + sender-constraint の **組み合わせ**で塞ぐことの整理。

## 3. 参照資料

- FAPI 2.0 Security Profile（OpenID Foundation, Final）: https://openid.net/specs/fapi-2_0-security-profile.html
  - 特に「Authorization server requirements」「Client requirements」「Token requirements（sender-constraining）」節
- FAPI 2.0 Attacker Model: https://openid.net/specs/fapi-2_0-attacker-model.html
- FAPI 2.0 Message Signing: https://openid.net/specs/fapi-2_0-message-signing.html
- OpenID Foundation Conformance（FAPI 2.0 テスト計画）: https://openid.net/certification/conformance-testing-for-fapi-2-0/
- 構成要素の一次情報:
  - PAR: RFC 9126 https://www.rfc-editor.org/rfc/rfc9126
  - DPoP: RFC 9449 https://www.rfc-editor.org/rfc/rfc9449
  - mTLS / certificate-bound tokens: RFC 8705 https://www.rfc-editor.org/rfc/rfc8705
  - 認可レスポンス iss: RFC 9207 https://www.rfc-editor.org/rfc/rfc9207
  - Security BCP: RFC 9700 https://www.rfc-editor.org/rfc/rfc9700

> 注: FAPI 2.0 は版が更新されることがある。実装着手前に **published final の最新版**で MUST 一覧を再確認すること（本ファイルは知識時点 2026-01 の整理）。

## 4. 現在の実装確認

- core（`packages/core/src`）には FAPI 2.0 を「プロファイルとして」束ねる仕組みは無い。
- 構成部品の実装状況:
  - PAR / DPoP: 未実装（それぞれ study-material / `tasks/T-019-dpop.md` で検討中）。
  - mTLS / private_key_jwt: 未実装（検討中）。
  - PKCE S256 強制・`plain` 拒否: 実装済み（`token-request.ts` / `authorization-request.ts`）。
  - 認可レスポンス `iss`: 実装済み（`tasks/done/p1-authorization-response-iss.md`）。
  - implicit / hybrid 拒否、removed grants 拒否: 実装済み。
  - redirect_uri 完全一致・fragment 拒否: 実装済み。
  - Refresh Rotation: 実装済み（`packages/core/src/token-request.ts` / revocation）。
- `client-auth.ts` は `client_secret_basic` / `client_secret_post` のみ。FAPI が要求する `private_key_jwt` / mTLS は未対応。
- Discovery（`packages/core/src/discovery.ts`）に FAPI 関連メタデータ（`require_pushed_authorization_requests` 等）のフィールドは無い。

## 5. 現在の実装との差分

- 🟢 **Basic OP プロファイル要件ではない**: FAPI 2.0 未対応は仕様違反ではない。
- 🟢 **多くの部品は既に揃う設計方向**: PKCE / iss / rotation / redirect 完全一致など、FAPI 2.0 の土台はすでに OAuth 2.1 ベースで満たしている。残るギャップは PAR / DPoP or mTLS / 強い client auth の 3 つに集約される。
- 🟡 **client auth の方式拡張が前提**: `client_secret_*` のみの現状では FAPI confidential client を表現できない。`private_key_jwt` か mTLS の少なくとも一方が必須。
- 🟡 **プロファイル強制レイヤが必要**: 個別機能を入れても「FAPI モードとして矛盾なく強制する」設定軸（client ごと / server ごと）が無いと Conformance は通らない。
- 🟡 **Discovery 整合（honesty）**: FAPI メタデータの広告と実挙動の一致が必要。
- 🟢 **Fidelity シグナルとして価値が高い**: FAPI 2.0 認証取得は本リポジトリの「Fidelity」軸を強く裏付ける。

## 6. 改善・追加を検討する理由

価値:

- **Fidelity 軸の最上位シグナル**: Basic OP の次に FAPI 2.0 を掲げられれば、「最新仕様を忠実に」を体現できる。高保証ドメイン（金融・行政・医療）の PoC ユーザーに刺さる。
- **個別機能を「束ねる」だけで到達できる位置**: ゼロからではなく、既存検討中タスク（PAR / DPoP / mTLS / private_key_jwt）の **完了 + 組み合わせ強制**で到達できる。投資効率が良い。
- **Portability と相性**: DPoP（mTLS 不要）経路を選べば、Web 標準 Crypto だけで sender-constraining が可能。Cloudflare Workers / Deno でも動く FAPI 2.0 という独自ポジションを取れる。

Basic OP として必要か / 拡張か:

- **明確に拡張（Tier C 相当）**。Basic OP 認証には不要。ただし「次の Conformance ターゲット」としてロードマップに置く価値がある（`RELEASE-v0.x-scope.md` のロードマップに追記検討）。

導入しやすさ / しにくさ:

- 🟡 構成部品（PAR / DPoP / mTLS / private_key_jwt）が **それぞれ未着手**。FAPI 2.0 はこれらの完了が前提になるため、単独では着手できない（依存タスクが多い）。
- 🟢 一方で各部品は本リポジトリの resolver 注入アーキテクチャに乗せやすく、揃えば束ねるのは比較的軽い。

既存実装との接続:

- access token 発行（`packages/core/src/access-token-issuer.ts`）に `cnf` クレーム付与点を作る。
- Discovery（`discovery.ts`）に FAPI メタデータフィールドを追加。
- client モデル（`TokenClientResolver` の client 型）に「許可する client auth 方式」「PAR 必須フラグ」を持たせる。

実装しない場合のリスク / 制約:

- 高保証ドメインの PoC を取りこぼす。FAPI を試したいユーザーは Keycloak / 商用 IdaaS に流れる（本リポジトリのコンセプトが対象としたい層の一部）。

## 7. 実装方針の候補

### 方針A（ロードマップ明文化のみ・今は着手しない）

- `RELEASE-v0.x-scope.md` に「FAPI 2.0 = Basic OP の次の Conformance ターゲット（Tier C）」と記載。
- 依存タスク（PAR / DPoP / mTLS / private_key_jwt）の優先度付けだけ行い、束ねは保留。

### 方針B（DPoP 経路で最小 FAPI 2.0 を目指す）

- sender-constraining は **DPoP のみ**（mTLS は採らない）に絞り、Portability を維持。
- 依存: PAR + DPoP + private_key_jwt の 3 タスク完了。
- その上で「FAPI プロファイルモード」設定軸を追加し、Discovery を整合。
- FAPI 2.0 Conformance Suite（DPoP プロファイル）で検証。

### 方針C（mTLS / DPoP 両対応のフルセット）

- mTLS と DPoP の両 sender-constraining、private_key_jwt + mTLS の client auth を網羅。
- Message Signing（JAR/JARM/RFC 9701）も含めて FAPI 2.0 Advanced 相当まで。
- 投資は大きいが、最も強い Fidelity シグナル。

判断材料:

- Portability を最優先するなら方針 B（DPoP 経路）が本リポジトリの思想に最も合う。
- mTLS は実行環境依存（TLS 終端での client cert 取得）が強く、Web 標準だけでは完結しにくい → Portability と緊張関係。
- まず方針 A でロードマップに据え、依存タスクを進めてから B/C を判断するのが堅実。

## 8. タスク案

> 本トピックは依存タスクが多く「方針未決定」のため、原則は **タスク化せず検討段階に留める**。着手するのは依存タスク（PAR / DPoP / private_key_jwt / mTLS）が揃ってから。

- [ ] 人間が方針 A / B / C を選択する
- [ ] 方針 A: `RELEASE-v0.x-scope.md` のロードマップに FAPI 2.0 を Tier C ターゲットとして追記し、依存タスクを列挙
- [ ] 方針 B/C 着手の前提として、以下の既存検討中タスクの完了が必要:
  - [ ] PAR（`study-material/ext-pushed-authorization-requests-rfc9126.md`）
  - [ ] DPoP（`tasks/T-019-dpop.md`）
  - [ ] private_key_jwt client auth（`study-material/ext-private-key-jwt-client-auth.md`）
  - [ ]（方針 C のみ）mTLS（`study-material/ext-mtls-rfc8705.md`）
- [ ] 上記完了後:
  - [ ] client 型に「許可 client auth 方式」「PAR 必須」「sender-constraining 種別」を追加
  - [ ] access token 発行に `cnf` 付与点を追加し、UserInfo / introspection 検証を整合
  - [ ] Discovery に FAPI メタデータ（`require_pushed_authorization_requests` 等）を追加し honesty を担保
  - [ ] FAPI 2.0 Conformance Suite で検証（DPoP プロファイル想定）
