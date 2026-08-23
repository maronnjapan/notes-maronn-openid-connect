# 拡張: OAuth Client ID Metadata Document（HTTPS URL を client_id として使う事前登録レス方式）

## ステータス

🟢 拡張機能 / 未着手

## 1. このトピックで確認したいこと

`draft-ietf-oauth-client-id-metadata-document`（以下 CIMD）は、**HTTPS URL そのものを `client_id` として使い、その URL を参照（dereference）してクライアントメタデータ（`redirect_uris`, `jwks` など）を取得する**方式である。RFC 7591/7592（Dynamic Client Registration）や本リポジトリの `ClientResolver` が前提とする「事前にクライアントを登録し、発行された `client_id` を使う」モデルとは根本的に異なる。

このファイルで確認したいのは以下:

- CIMD が本リポジトリの `ClientResolver` 抽象にどう接続できるか（`findClient(clientId)` に URL を渡し、内部で fetch する実装が書けるか）
- 「事前登録なしで素早く試す」という本ライブラリのコンセプトに CIMD がどれだけ合致するか
- CIMD を導入する場合に、既存の redirect_uri 検証・PKCE・client 認証方式の前提が崩れないか
- Basic OP conformance の必須要件ではないことの確認（あくまで拡張）

> 前提となる「クライアント登録の考え方」「redirect_uri 完全一致」「private_key_jwt 認証」の一般説明は、
> `study-material/ext-dynamic-client-registration.md`、
> `study-material/redirect-uri-required-oidc-authentication-request.md`、
> `study-material/ext-private-key-jwt-client-auth.md` を参照する。本ファイルは **CIMD 固有の差分**に絞る。

## 2. 関連する仕様・基準

### 2.1 CIMD の中核メカニズム（draft-ietf-oauth-client-id-metadata-document-02）

- `client_id` に **HTTPS URL** を使う。AS はこの URL を GET して JSON の Client ID Metadata Document を取得し、`redirect_uris` 等を得る。
- **Client Identifier URL の制約**（draft §2 相当）:
  - スキームは **`https` のみ**
  - **userinfo 部（`user:pass@`）を含まない**
  - **パス component を持つ**（ドメインのみの URL は不可 = 攻撃者が同一ホスト上の別パスと衝突させにくくする）
  - `.` / `..` のパスセグメントを含まない
  - フラグメントを含まない
  - AS は `client_id` を **単純文字列一致**で比較する（ポート正規化などをしない。本リポジトリの redirect_uri 比較方針と同じ考え方）
- **Client ID Metadata Document（JSON）の制約**:
  - `client_id` プロパティを含み、**取得元 URL と完全一致**しなければならない（自己参照の一貫性チェック）
  - メタデータは RFC 7591（DCR）のメタデータパラメータ名を使う
  - HTTP 200 で返る
  - **対称鍵系（`client_secret`, `client_secret_basic` 等）を含んではならない** → CIMD クライアントは public か、または非対称鍵（`private_key_jwt` 等）認証のみ
  - 公開鍵は `jwks` または `jwks_uri` で提供
- **取得・キャッシュ**:
  - AS は「毎リクエストで fetch する義務はない」。HTTP キャッシュヘッダを尊重しつつ AS 側で上限/下限を定める
  - ドキュメントの読み取りサイズ上限は **5 KB 程度**が推奨（DoS 抑制）
- **redirect_uri 検証**: RFC 9700 に従い **完全一致必須**。加えて AS は「`redirect_uris` を `client_id` のドメインに紐付ける」制約を課してよい。

### 2.2 セキュリティ考慮（本トピック固有の重点）

- **SSRF**: AS は client_id URL を fetch する。**special-use IP（loopback / link-local / メタデータサービス等）に解決される URL を fetch してはならない**（開発時 loopback 例外のみ）。これは本リポジトリが現状持たない「アウトバウンド fetch」を新たに導入するため、最重要リスク。
- **フィッシング**: 事前登録がないため、AS は同意画面でホスト名を表示し、取得したメタデータでアプリ情報を提示すべき。
- **メタデータ変化**: `redirect_uris` / `jwks_uri` / 鍵が大きく変わった場合はトークン失効・再同意のトリガーとしてよい。

### 2.3 DCR との違い

- RFC 7591（DCR）は **registration endpoint への登録という状態変更**を伴うステートフル方式。
- CIMD は登録エンドポイント不要で、**クライアントが自分のメタデータを公開するだけ**のディスカバリ型。安定したドメインを持つ公開アプリ向き（例: AT Protocol / Bluesky が同種の client-metadata 方式を採用）。

## 3. 参照資料

- draft-ietf-oauth-client-id-metadata-document-02（Client ID Metadata Document）:
  https://datatracker.ietf.org/doc/draft-ietf-oauth-client-id-metadata-document/
  - §2 相当: Client Identifier URL の構文制約（https のみ・パス必須・userinfo/フラグメント禁止・単純文字列一致）
  - Metadata Document の自己参照 `client_id` 一致、対称鍵禁止、`jwks`/`jwks_uri`、5KB 読取上限
  - Security Considerations: SSRF 防止（special-use IP 禁止）、フィッシング、メタデータ変化時の失効
- RFC 9700（OAuth 2.0 Security BCP）redirect_uri 完全一致: https://www.rfc-editor.org/rfc/rfc9700
  （本リポジトリ内の関連整理: `study-material/done/oauth-security-bcp-rfc9700.md`）
- RFC 7591（Dynamic Client Registration）メタデータ名の出典: https://www.rfc-editor.org/rfc/rfc7591
- 比較対象の実運用例（一次情報ではないが背景理解用）: AT Protocol OAuth client metadata。

## 4. 現在の実装確認

- クライアント解決は **`ClientResolver` / `TokenClientResolver` の `findClient(clientId)`** に集約されている
  （`packages/core/src/authorization-request.ts:105-154`, `packages/core/src/token-request.ts:53-66`）。
  - `ClientInfo` は `clientId` / `redirectUris` / `jwks?` / `tokenEndpointAuthMethod?` / `clientSecret?` を持つ。
  - 解決の実体（DB/メモリ）は sample/利用者側の store であり、core は「解決関数」を受け取るだけ。
- redirect_uri 検証は `validateRegisteredRedirectUris` / 完全一致ロジック（`authorization-request.ts:341` 周辺）で実装済み。
- クライアント認証は `client-auth.ts` にあり、`private_key_jwt` は **未実装**（`study-material/ext-private-key-jwt-client-auth.md` 参照）。
- **アウトバウンド HTTP fetch を行うコードは core に存在しない**（Web 標準 `fetch` は使えるが、現状 client 解決で外部取得はしていない）。

## 5. 現在の実装との差分

- **満たしていること / 接続しやすい点**:
  - `ClientResolver` が「関数」抽象なので、**CIMD は core を変更せず利用者側 resolver 実装として載せられる**可能性が高い（`findClient(url)` の中で fetch → 検証 → `ClientInfo` を組み立てる）。core の redirect_uri 完全一致・単純文字列一致方針は CIMD の要求と整合する。
- **不足している可能性があること**:
  - CIMD が要求する **SSRF 防御付き fetch ヘルパ**（special-use IP 拒否、5KB 上限、タイムアウト、キャッシュ）が無い。利用者に丸投げすると危険な実装を書かれやすい。
  - CIMD クライアントは対称鍵を持てないため、**`private_key_jwt`（未実装）が実質前提**。private_key_jwt が無いと confidential な CIMD クライアントを認証できず、public + PKCE に限定される。
  - `ClientInfo.clientId === 引数 clientId` の一貫性チェックは既存だが、CIMD の「**ドキュメント内 `client_id` == 取得 URL**」という自己参照検証は別レイヤで必要。
- **セキュリティ上の要確認**:
  - fetch 導入は本ライブラリの攻撃面を増やす。SSRF は最優先。誤設定で内部メタデータサービス（169.254.169.254 等）を叩かせない。
- **相互運用性**:
  - 事前登録なしで動くため PoC 検証の摩擦が下がる。一方で「ホスト名 = 信頼の単位」になるので同意 UI 側の対応が要る。
- **Basic OP として**: CIMD は Basic OP conformance の要件ではない。純粋な拡張。

## 6. 改善・追加を検討する理由

- **価値**: 本ライブラリのコンセプトは「素早く仕様を検証する」。CIMD は **登録手順ゼロでクライアントを試せる**ため、PoC 開発者の初速に直結する。DCR（`study-material/ext-dynamic-client-registration.md`）と並ぶ「登録レス」導線の第二の選択肢になる。
- **Basic OP 必須か拡張か**: 拡張。Basic OP には不要。
- **導入しやすさ**: `ClientResolver` が関数抽象なので **core 改変を最小化**でき、まず「安全な CIMD resolver を作るためのユーティリティ（SSRF ガード付き fetch）」を提供する形が現実的。
- **既存実装との接続**: `findClient` の戻り値組み立てに帰着。private_key_jwt（未実装）と強く関連。
- **メリット**: 利用者は client 登録 UI/DB を用意せず、URL を publish するだけで試せる。
- **実装しない場合のリスク/制約**: 事前登録前提のままだと、CIMD 系エコシステム（AT Protocol 等）や「登録レスで試したい」ニーズに応えられない。ただし未対応でも Basic OP には影響しない。

## 7. 実装方針の候補

（最終判断は人間が行う。ここでは判断材料の整理）

### 方針A: SSRF ガード付き fetch ユーティリティのみ core に追加し、CIMD resolver は利用者/CLI 生成側に置く（推奨度：低リスク先行）
- core に `fetchClientMetadataDocument(url, opts)`（https 限定・special-use IP 拒否・5KB 上限・タイムアウト・自己参照 `client_id` 一致検証）を追加。
- CIMD を使うかどうかは resolver 実装者の裁量。core の他部分は不変。

### 方針B: `ClientResolver` に CIMD を第一級サポートとして組み込む
- `findClient` が URL を受けたら core が自動 fetch。副作用（外部 I/O）が core に入るため、テスト容易性・Portability（Web 標準 fetch 依存）とのトレードオフを評価。

### 方針C: 見送り（DCR を先に整備）
- CIMD は private_key_jwt 前提が強いので、`ext-private-key-jwt-client-auth.md` と DCR を先に固めてから再検討。

いずれの方針でも **redirect_uri は既存の完全一致ロジックを流用**し、`client_id` ドメインとの紐付け制約を追加するかを別途決める。

## 8. タスク案

- [ ] draft-ietf-oauth-client-id-metadata-document の最新版（-02 以降）を再確認し、URL 制約・fetch 要件・鍵要件を確定
- [ ] 方針A/B/C の選択（人間判断）。private_key_jwt 未実装との依存関係を明記
- [ ] （方針A採用時）SSRF ガード付き fetch ユーティリティの設計:
      https 限定 / special-use IP 拒否（loopback 開発例外）/ 5KB 読取上限 / タイムアウト / キャッシュ方針
- [ ] Client Identifier URL 構文バリデータ（https・パス必須・userinfo/フラグメント/`.`,`..` 禁止・単純一致）
- [ ] Metadata Document の自己参照 `client_id` 一致・対称鍵不在・`jwks`/`jwks_uri` 検証
- [ ] CIMD で解決した `ClientInfo` を既存 redirect_uri 完全一致・PKCE 経路に流す結合テスト
- [ ] Basic OP conformance に影響しないこと（既存 `conformance.test.ts` が緑のまま）を確認
- [ ] 完了条件: `pnpm --filter @maronn-openid-connect/core test` がパスし、SSRF ガードの単体テスト（special-use IP 拒否・サイズ上限）が緑
