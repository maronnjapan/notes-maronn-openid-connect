# 拡張: OAuth 2.0 for Native Apps（RFC 8252 / BCP 212）

## ステータス

🟡 BCP / 一部実装済み・ガイド不足 / 未着手

## 1. このトピックで確認したいこと

RFC 8252（OAuth 2.0 for Native Apps、BCP 212）は **ネイティブアプリ（モバイル、デスクトップ）が OAuth/OIDC を安全に行うためのベストカレントプラクティス**を規定する IETF BCP。
本リポジトリは PoC 検証ツールとして「ネイティブアプリから OP を試したい開発者」も想定ユーザーに含まれる（モバイルアプリでログインを試すのは PoC で頻出）。

ここで確認したいことは以下:

- RFC 8252 が OP に課す要件（OP 側責務）を整理する
- 本リポジトリの現在の実装（loopback ポート許容、PKCE 必須、public client サポート）が RFC 8252 の要件にどこまで応えているか
- ネイティブアプリ向けに OP として **明示すべきガイダンス・拒否すべき動作**は何か
- 既存タスク（PKCE、redirect_uri 厳格一致、public client の token endpoint 利用）との接続点

このファイルは **OP 側で RFC 8252 に準拠／支援するための差分** に絞る。RP 側実装（カスタムスキーム、AppAuth ライブラリ等）は OP の責任範囲外。

## 2. 関連する仕様・基準

共通の仕様索引は `study-material/basic-op-requirement-traceability.md` を参照。本トピック固有のポイント:

- **RFC 8252 §7 Initiating the Authorization Request**:
  - ネイティブアプリは **External User-Agent**（システムブラウザ・カスタムタブ）で認可リクエストを開始 MUST。Web View（埋め込みブラウザ）は **避ける** SHOULD NOT。
  - OP 側はこの方針を強制できないが、Discovery/ドキュメントで明示し、必要に応じて User-Agent ヘッダー検査などの緩い検出をしてもよい。
- **RFC 8252 §7.3 Loopback Interface Redirection**:
  - public client（ネイティブ）は `http://127.0.0.1:<port>` または `http://[::1]:<port>` を redirect_uri に登録し、port は **登録時と起動時で変わってよい**。OP はループバックホストの port を厳格一致**しない** MUST。
  - 本リポジトリ実装: `packages/core/src/authorization-request.ts:223-237` で `clientType==='public'` のときのみループバックの port 差異を許容する分岐あり。OAuth 2.1 §10.3.3 と整合済み。
- **RFC 8252 §7.1 Private-Use URI Scheme Redirection**:
  - カスタムスキーム（`com.example.app:/oauth/callback`）の利用を許可。OP は scheme/path の厳格一致を要求 MUST。
  - 本リポジトリ実装: 任意 URI スキームを受理（redirect_uri 完全一致は `done/p0-redirect-uri-fragment-rejection.md`）。
- **RFC 8252 §7.2 Claimed "https" Scheme URI Redirection**:
  - iOS Universal Links / Android App Links のような **検証済み https カスタムドメイン**を推奨。OP 側の追加処理は不要だが、Discovery ドキュメントで RP に推奨する価値あり。
- **RFC 8252 §8.1 Protecting the Authorization Code (PKCE 必須)**:
  - ネイティブアプリ（public client）は **PKCE 必須**。本リポジトリは全クライアント PKCE 必須を OAuth 2.1 準拠で実装済み（`authorization-request.ts:387-427`、`token-request.ts:531-557`）。
- **RFC 8252 §8.5 Client Authentication**:
  - public client は client_secret を保持しない MUST。Token Endpoint 認証は **client_id のみ** で良い（PKCE があれば AS は code を本物の client が引き換えしていると判断できる）。
  - 既存タスク: 📌 `tasks/p1-public-client-token-endpoint.md`（public client が client_secret を持たず token を交換できる経路の確認）。
- **RFC 8252 §8.6 Inter-App Communication / Cross-App Request Forgery**:
  - state パラメータの厳密検証、authorization code を別アプリが拾わないようにする責任は RP 側だが、OP は **state を必ず echo する**実装が前提（既に実装済み）。
- **RFC 8252 §8.10 OAuth Implicit Grant Authorization Flow**:
  - **ネイティブアプリは Implicit Grant 使用禁止**。Authorization Code + PKCE のみ。本リポジトリは Implicit 自体を実装していない（Basic OP として `response_type=code` 限定）ので自動的に充足。

## 3. 参照資料

- RFC 8252 OAuth 2.0 for Native Apps（BCP 212）: https://www.rfc-editor.org/rfc/rfc8252
  - §7 Initiating the Authorization Request
  - §7.3 Loopback Interface Redirection
  - §8.1 Protecting the Authorization Code（PKCE）
  - §8.5 Client Authentication（public client）
  - §8.10 OAuth Implicit Grant 禁止
- OAuth 2.1 draft §2.1 / §10.3.3 / §10.5: https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1
- AppAuth Native SDKs（参考、RP 側実装ガイドの実例）: https://openid.net/code/

## 4. 現在の実装確認

ネイティブアプリ視点で関連する既存実装:

- `packages/core/src/authorization-request.ts:65-74`: `ClientInfo.clientType?: 'confidential' | 'public'` で public client を区別。
- `packages/core/src/authorization-request.ts:223-237`: redirect_uri 検証で、`clientType==='public'` のループバック URI に対してのみ port 差異を許容（RFC 8252 §7.3 / OAuth 2.1 §10.3.3）。
- `packages/core/src/authorization-request.ts:387-427`: PKCE 必須（code_challenge / code_challenge_method=S256 強制、plain 拒否）。
- `packages/core/src/token-request.ts:531-557`: PKCE 検証（S256 で code_verifier を SHA-256 してチャレンジと比較）。
- `packages/core/src/client-auth.ts`: クライアント認証ロジック（`client_secret_basic` / `client_secret_post` 中心）。public client 経路（client_secret なし）は 📌 `tasks/p1-public-client-token-endpoint.md` で追跡中。
- CLI/sample テンプレート: 静的クライアント設定例にネイティブアプリ向けクライアントは含まれていない（基本は Web 用 confidential client サンプル）。

## 5. 現在の実装との差分

満たしていること:

- ループバック port 差異許容（§7.3）の **コア機構**は既に実装済み。
- PKCE 全クライアント必須（§8.1）は OAuth 2.1 準拠で実装済み。
- Implicit Grant 非対応（§8.10）は Basic OP として `response_type=code` 限定で自動充足。
- カスタムスキーム / 任意 https URI を redirect_uri として受理し、厳格一致で検証（§7.1）。

不足／要確認:

- 🟡 **public client の Token Endpoint 利用シナリオが未整理**: 既存 `tasks/p1-public-client-token-endpoint.md` で追跡中。これがブロッカーになると、ネイティブアプリは PKCE があっても Token Endpoint で `client_secret` を要求されてしまう。RFC 8252 §8.5 への適合確認が必要。
- 🟡 **OP 側ガイダンス（Web View 利用回避の推奨）が不足**: README / CLI 生成コードのコメントに「RP はシステムブラウザ／カスタムタブを使うべき」「Web View 検出は OP では行わない（が、RP が AppAuth を使う前提を明示）」と書く価値あり。これは実装ではなくドキュメント差分。
- 🟡 **ネイティブアプリ向けクライアントサンプル不足**: CLI / sample にネイティブアプリ向け（public client + loopback redirect / カスタムスキーム）のクライアント設定例が無い。PoC ユーザーが「ネイティブアプリで試したい」ときに参照できる雛形が欲しい。
- 🟢 **Claimed https Scheme（§7.2）の特別対応は不要**: OP は scheme を区別せず URI 完全一致するのみ。RP 側で iOS Universal Links / Android App Links を構成する。OP ドキュメントには「推奨します」程度の言及で十分。
- 🟡 **`response_type=code` 以外を public client が要求した場合の挙動**: 現状 OP は `response_type=code` のみサポートのため自動拒否されるが、エラー応答（`unsupported_response_type`）がネイティブアプリでも正しく URL fragment ではなく query で返ることを確認する必要あり（既に query 返却で実装されているはず。Implicit 用 fragment 経路は無いので問題なし）。

セキュリティ観点:

- 🟡 **authorization code の漏洩経路**（カスタムスキームを別アプリが横取り）は OP では完全防御不可。**PKCE 必須 + code 単回使用 + code 失効** で実害を抑える設計。現実装は code 単回使用 + 再利用検知で同 grant 全失効（📌 `done/p0-token-revocation-on-code-reuse.md`）。RFC 8252 §8.6 の防御線として十分。
- 🟡 **state echo の挙動**: OP は state を必ず echo（実装済み）。RP 側が検証するため OP 側は echo のみで良い。

相互運用性観点:

- 🟡 **Discovery で public client を明示する手段**: RFC 8414 / OIDC Discovery には「public client を許容するか」の明示フィールドは無い。`token_endpoint_auth_methods_supported: ['none']` を含めることで「PKCE のみで認証可能なクライアント方式を許容」を示せる。本リポジトリの Discovery 設定例にこれが含まれているか確認が必要。

## 6. 改善・追加を検討する理由

- **PoC ターゲット拡張**: 「PoC 開発者・本番導入を見据える開発者」（CLAUDE.md）にはネイティブアプリ開発者が多く含まれる。RFC 8252 の準拠と「ネイティブアプリで試せる雛形」があると差別化軸の **Portability**（どこでも動く）に直結。
- **ファネル価値（SME 向け）**: モバイルアプリ × ID 管理は SME が IDaaS 検討に至る最頻ケースの一つ。ネイティブアプリ雛形を提供することで RELEASE-v0.x-scope.md の Tier A（非専門家が体感できる）にも貢献。
- **コスト**: コア機構はほぼ実装済み。**追加で必要なのは主にドキュメント整備 + CLI/sample の雛形**。実装コストは小〜中。
- **実装しない場合のリスク**: ネイティブアプリで試そうとした PoC 利用者が「ループバック ポート差異が動かない」「PKCE のみで token を取れない」など個別箇所で詰まり、ライブラリの仕様準拠が見えづらくなる。

## 7. 実装方針の候補

### 方針A（最小・ドキュメント整備のみ）

- README / 各 study-material に「RFC 8252 の OP 側責務はこれ／RP 側責務はこれ」の表を追加。
- CLI 生成コード（templates）に「ネイティブアプリ向けは AppAuth を推奨。Web View は使わない」コメント追加。
- 既存タスク（public client Token Endpoint）の完了を本ファイルから参照。
- 実装変更ゼロ。

### 方針B（中・サンプルクライアント追加）

- 方針A + CLI/sample の **クライアント設定例にネイティブ用 public client を追加**:
  - redirect_uri 例: `http://127.0.0.1:0/callback`（port=0 でループバック動的 port を意図）と `com.example.app:/oauth/callback`（カスタムスキーム）
  - `clientType: 'public'`、`tokenEndpointAuthMethod: 'none'`
- Discovery 設定例に `token_endpoint_auth_methods_supported` に `'none'` を含める（既に含まれているなら明示テスト）。

### 方針C（大・E2E 動作確認）

- 方針B + ネイティブアプリ E2E 確認用の参考スクリプトまたはガイド（AppAuth SDK と組み合わせる手順）を README に追加。実装は不要だが、PoC 体感価値が最大化。

実装するか / どの方針か / v0.x に入れるかは人間が判断。RELEASE-v0.x-scope.md の Tier A シナリオに「ネイティブアプリでログイン」が無いため v0.x 直接ブロッカーではないが、後続ロードマップ（モバイル / SSO 体感）と整合する。

## 8. タスク案

- [ ] `tasks/p1-public-client-token-endpoint.md` の完了を本トピックの前提条件として明記し、進捗を確認する
- [ ] README に「OAuth 2.0 for Native Apps（RFC 8252）対応状況」セクションを追加し、本リポジトリの実装範囲（loopback port、PKCE 必須、custom scheme）と RP 側責務（システムブラウザ使用、AppAuth 推奨）を表で示す
- [ ] CLI/sample にネイティブアプリ向けクライアント設定例を追加（方針B採用時）
- [ ] Discovery メタデータが `token_endpoint_auth_methods_supported: ['none', 'client_secret_basic', 'client_secret_post']` を返すことをテストで固定
- [ ] `basic-op-requirement-traceability.md` に RFC 8252 の OP 側責務マトリクスを追記（充足／不足を一覧化）
