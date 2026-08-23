# クライアント登録メタデータの強制（`grant_types` / `response_types` / `token_endpoint_auth_method`）と `unauthorized_client`

## ステータス

🟠 Major / 未着手

## 1. このトピックで確認したいこと

OAuth 2.0 / OpenID Connect では、クライアントは登録時に「どの grant type を使えるか（`grant_types`）」「どの response type を使えるか（`response_types`）」「どのクライアント認証方式を使うか（`token_endpoint_auth_method`）」「どの scope を要求できるか」を登録（あるいは OP に既定）しておき、**認可サーバは登録外の使い方を拒否しなければならない**。

本リポジトリは Authorization Code Flow / `client_secret_basic` / `client_secret_post` / refresh_token grant を実装済みだが、**「そのクライアントがその grant / response_type / 認証方式を使ってよいか」というクライアント単位のポリシー検証を一切行っていない**。

具体的に確認したいこと:

- 認可エンドポイントで、`response_type=code` を使う権限がそのクライアントにあるか検証していない（グローバルに `code` 固定で受理しているのみ）。
- トークンエンドポイントで、`grant_type=refresh_token` / `authorization_code` をそのクライアントが使ってよいか検証していない。**refresh token を発行すべきでないクライアントでも refresh_token grant が通る。**
- クライアントが登録した `token_endpoint_auth_method`（例: `client_secret_basic` 限定）と異なる方式での認証を拒否していない。
- これらの違反に対して返すべき `unauthorized_client` エラーが、`AuthorizationErrorCode` / `TokenErrorCode` に **定義はされているが一度も使われていない**（dead code）。

> 補足（ユーザーの関心「Refresh Token フロー」との接続）: Refresh Token の rotation / 再利用検知 / 絶対寿命などは既存タスクで扱い済み（重複しない、§3 参照）。本トピックが補うのは「そもそもこのクライアントは refresh_token grant を使ってよいのか」という**入口の認可判定**であり、Refresh Token フローの安全性に直結する未対応点である。

## 2. 関連する仕様・基準

Discovery の `*_supported` 広告（OP 全体でサポートする値の一覧）は既存ファイルで扱っているため重複させない。本トピックは「OP 全体のサポート集合」ではなく「**クライアント単位の許可集合の強制**」という直交した論点を扱う。

関連既存ファイル（重複記載しない、参照に留める）:

- OP 全体の scope ポリシー（未知/未サポート scope を `invalid_scope` で弾くか無視するか）: `study-material/scope-handling-validation-and-granted-scope.md`
- public client（`token_endpoint_auth_method=none`）の Token Endpoint 取り扱い: `tasks/p1-public-client-token-endpoint.md`
- Discovery の `grant_types_supported` / `token_endpoint_auth_methods_supported` 広告: `tasks/T-021-discovery-metadata.md`
- Dynamic Client Registration（クライアントメタデータの動的払い出し）: `study-material/ext-dynamic-client-registration.md` / `study-material/extension-dynamic-client-registration.md`
- 削除された grant（implicit / password 等）の明示的拒否: `study-material/done/oauth21-removed-grants-explicit-rejection.md`

本トピック固有のポイント:

### 2.1 `unauthorized_client` の定義

- **トークンエンドポイント**（RFC 6749 §5.2 / OAuth 2.1 §3.2.3）:
  `unauthorized_client` = 「The authenticated client is not authorized to use this authorization grant type.（認証されたクライアントが、この authorization grant type を使う権限を持たない）」
- **認可エンドポイント**（RFC 6749 §4.1.2.1 / OAuth 2.1 §4.1.2.1）:
  `unauthorized_client` = 「The client is not authorized to request an authorization code using this method.（クライアントがこの方法で authorization code を要求する権限を持たない）」
- `invalid_client`（認証自体の失敗：client_id 不明・secret 不一致・認証方式不正）とは区別される。本トピックは「認証は成功したが、その操作を行う権限がない」ケースであり `unauthorized_client` が正しい。

### 2.2 クライアント登録メタデータ（`grant_types` / `response_types`）

- **OpenID Connect Dynamic Client Registration 1.0 §2** / **RFC 7591（OAuth 2.0 Dynamic Client Registration）§2** は、クライアントメタデータとして以下を定義する:
  - `grant_types`: クライアントが使用する grant type の配列（例: `["authorization_code", "refresh_token"]`）。既定は `["authorization_code"]`。
  - `response_types`: クライアントが使用する response type の配列（例: `["code"]`）。既定は `["code"]`。
  - `token_endpoint_auth_method`: トークンエンドポイントでのクライアント認証方式（`client_secret_basic` / `client_secret_post` / `none` / `private_key_jwt` 等）。既定は `client_secret_basic`。
  - `scope`: クライアントが要求できる scope のスペース区切り文字列。
- OIDC Registration §2 は `grant_types` と `response_types` の整合性（`authorization_code` を使うなら `code` を含むべき等）にも言及する。
- Dynamic Client Registration を実装しない場合でも（Basic OP では DCR は必須ではない）、**手動登録されたクライアントレコードがこれらの値を保持し、OP がそれを強制する**ことは仕様の意図に沿う。OIDC Conformance の Basic OP は最低 1 つの `client_secret_basic` クライアントを手動登録して回す運用が想定されている（`study-material/basic-op-requirements-baseline.md` §2）。

### 2.3 「登録外の grant / response_type は拒否」の根拠

- RFC 6749 §3.1（response_type）/ §4.1.1 は、クライアントが認可サーバに登録した内容に基づいて認可リクエストが評価されることを前提にしている。登録された grant / response type と異なる要求は、認可サーバがクライアントに権限を与えていない操作であり `unauthorized_client` に該当する。
- OAuth 2.1 Security 観点（OAuth 2.0 Security BCP / RFC 9700、`study-material/done/oauth-security-bcp-rfc9700.md` で別途扱い済み）でも、クライアントの能力を必要最小限に絞る（grant の最小権限化）ことが推奨される。

## 3. 参照資料

- OAuth 2.1 draft（draft-ietf-oauth-v2-1） §3.2.3 Token Endpoint エラーレスポンス（`unauthorized_client` の定義）, §4.1.2.1 認可エンドポイントエラーレスポンス
  - https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1
- RFC 6749（OAuth 2.0） §4.1.2.1（認可エラー）, §5.2（トークンエラー: `unauthorized_client`）, §3.1（response_type と登録）
  - https://www.rfc-editor.org/rfc/rfc6749
- OpenID Connect Dynamic Client Registration 1.0 §2 Client Metadata（`grant_types` / `response_types` / `token_endpoint_auth_method` / `scope`）
  - https://openid.net/specs/openid-connect-registration-1_0.html#ClientMetadata
- RFC 7591（OAuth 2.0 Dynamic Client Registration Protocol） §2 Client Metadata
  - https://www.rfc-editor.org/rfc/rfc7591#section-2
- OpenID Connect Core 1.0 §9 Client Authentication（`token_endpoint_auth_method` の各方式）
  - https://openid.net/specs/openid-connect-core-1_0.html#ClientAuthentication

> 調査環境の制約: 本調査時、ネットワークポリシーにより `openid.net` および IETF datatracker への直接フェッチが 403 で遮断された。`unauthorized_client` の字句は OAuth 2.0/2.1 の確立済み定義（RFC 6749 §5.2 / §4.1.2.1）に基づく。`grant_types` / `response_types` の既定値（`["authorization_code"]` / `["code"]`）は OIDC Registration §2 の規定だが、字句は人間が上記 URL で最終確認することを推奨する（**要一次資料確認**）。

## 4. 現在の実装確認

### 4.1 クライアントモデルに該当フィールドが無い

- `packages/core/src/authorization-request.ts` `ClientInfo`（70-74 行付近）: `clientId` / `redirectUris` / `clientType?` のみ。`responseTypes` / `grantTypes` / `tokenEndpointAuthMethod` / `allowedScopes` は無い。
- `packages/core/src/token-request.ts` `TokenClientInfo`（81-84 行付近）: `clientId` / `clientSecret` のみ。
- `packages/sample/src/op/d1-resolver.ts` `FullClientInfo`（45-51 行）: `clientSecret` / `redirectUris` / `clientType` / `offlineAccessAllowed` のみ。grant/response_type/auth_method は保持していない。

### 4.2 認可エンドポイント：response_type をクライアント単位で検証していない

- `packages/core/src/authorization-request.ts` `validateAuthorizationRequest`（510-528 行）:
  `response_type` が `'code'` かどうかをグローバルに判定するだけ。`'code'` 以外は `unsupported_response_type`。
  「このクライアントが `code` を使ってよいか」は一切見ていない。

### 4.3 トークンエンドポイント：grant_type をクライアント単位で検証していない

- `packages/core/src/token-request.ts` `validateTokenRequest`（316-329 行）:
  `grant_type` が `authorization_code` / `refresh_token` のいずれかかをグローバル判定するのみ。
  認証されたクライアント（`authenticatedClientId`）がその grant を使ってよいかは検証していない。
  → **refresh_token を発行すべきでないクライアントでも `grant_type=refresh_token` が通る。**

### 4.4 クライアント認証：登録方式の強制をしていない

- `packages/core/src/client-auth.ts` `authenticateClient`（106-166 行）:
  Authorization ヘッダ（Basic）か body（post）かを「送られてきた方」で受理する。
  クライアントが `client_secret_basic` 限定で登録されていても `client_secret_post` を受け入れてしまう（逆も同様）。

### 4.5 `unauthorized_client` が未使用（dead code）

- `AuthorizationErrorCode.UnauthorizedClient`（`authorization-request.ts:15`）と
  `TokenErrorCode.UnauthorizedClient`（`token-request.ts:12`）は **定義のみで参照ゼロ**（`grep` 確認済み）。

## 5. 現在の実装との差分

満たしていること:

- `response_type=code` 以外を `unsupported_response_type` で拒否（OP 全体ポリシーとしては正しい）。
- 未サポート grant（`client_credentials` / `password` 等）を `unsupported_grant_type` で拒否（`study-material/done/oauth21-removed-grants-explicit-rejection.md`）。
- `redirect_uris` はクライアント単位で完全一致検証している（クライアントメタデータ強制の前例がある）。

不足している可能性があること:

- 🟠 **grant_type のクライアント単位強制が無い**: refresh_token を許可していないクライアントでも refresh token grant が通る。最小権限の原則に反する。
- 🟠 **response_type のクライアント単位強制が無い**: Basic OP は `code` のみだが、将来 Hybrid / Implicit プロファイルを拡張する際、クライアント単位の許可が無いと「全クライアントが全 response_type を使える」状態になる。
- 🟡 **`token_endpoint_auth_method` のクライアント単位強制が無い**: 登録方式と異なる認証方式を受理する。`private_key_jwt` / `none` を導入する際に特に問題（confidential として登録したクライアントが `none` で通る、等のダウングレードを防げない）。
- 🟡 **クライアント単位の scope 制限が無い**: クライアントが登録外の scope を要求しても素通り（OP 全体の scope ポリシーは `scope-handling-validation-and-granted-scope.md` の別論点。本件は「クライアント A は `email` を登録していないのに `email` を要求できる」というクライアント単位の話）。

実装はあるが仕様上の確認が必要なこと:

- `unsupported_response_type` と `unauthorized_client` の使い分け: OP がそもそも `code` 以外を一切サポートしない場合は `unsupported_response_type` が正しく、「OP はサポートするがこのクライアントには許可していない」場合は `unauthorized_client` が正しい。Basic OP（`code` のみ）では前者が主だが、クライアント単位ポリシーを入れると後者の出番が生まれる。

セキュリティ上、改善した方がよいこと:

- 最小権限化: クライアントが使える grant / 認証方式を登録値に縛ることで、漏洩クライアントの悪用範囲を限定できる。
- 認証方式ダウングレード防止: `token_endpoint_auth_method` 強制が無いと、強い認証（`private_key_jwt` 等）を導入しても弱い方式へのフォールバックを防げない。

相互運用性の観点:

- DCR / 手動登録のメタデータと実際の挙動が一致することは、クライアントライブラリや Conformance テストの期待に沿う。

Basic OP として提供する上で確認すべきこと:

- Basic OP の必須範囲は `response_type=code` / `client_secret_basic` であり、本件の強制が無くても「Basic OP の主要テスト」は通る可能性が高い。ただし `unauthorized_client` を正しく返せること自体は OAuth の基礎的な健全性であり、拡張プロファイル（Hybrid / DCR / private_key_jwt）に進む際の前提インフラになる。**要一次資料確認**: Basic OP テストプランが `unauthorized_client` を直接検証するかは一次資料で確認する。

## 6. 改善・追加を検討する理由

- **なぜ価値があるか**: 「認証は通ったが、その操作の権限が無い」ことを正しく `unauthorized_client` で返すのは OAuth の基本的な認可境界。これが無いと、クライアントの能力を絞れず（全クライアントが refresh_token / 任意 scope を使える）、本番志向ユーザーの最小権限設計を妨げる。
- **Basic OP 必須か、拡張か**: 厳密には Basic OP 認定の必須テスト対象ではない可能性が高い（**要一次資料確認**）。ただし「Fidelity（仕様準拠を信頼性シグナルにする）」という本プロジェクトの差別化軸に直接効く。また DCR / private_key_jwt / Hybrid といった既存 study-material 群を実装する際の**共通前提**になるため、早めに土台を作る価値がある。
- **導入しやすさ**: `redirect_uris` という「クライアント単位メタデータをモデルに持ち検証する」前例が既にある。同じパターンに乗るだけなので導入は素直。`ClientInfo` / `TokenClientInfo` に optional フィールドを足し、未指定なら既定値（`["code"]` / `["authorization_code"]` / `client_secret_basic`）で後方互換にできる。
- **既存実装との接続**: 検証点は `validateAuthorizationRequest`（response_type 検証直後）、`validateTokenRequest`（grant_type 検証直後）、`authenticateClient`（方式判定箇所）。いずれも既に分岐がある場所に 1 ステップ足す形。
- **メリット**:
  - 利用者（PoC 開発者）: クライアントごとに「このアプリは refresh 不可」等を宣言的に設定でき、本番設計に近づけられる。
  - 運用者: 漏洩時の被害範囲をクライアント単位で限定できる。
  - 開発者（コア利用者）: DCR / 拡張認証を後付けする際の前提が揃う。
- **実装しない場合のリスク**:
  - クライアント能力の最小権限化ができない。
  - `token_endpoint_auth_method` 強制が無いまま `private_key_jwt` / `none` を入れると認証ダウングレードの穴が残る。
  - `unauthorized_client` が dead code のままで、仕様準拠の網羅性に欠ける。

## 7. 実装方針の候補

最終判断は人間が行う。以下は判断材料。

### 方針A（後方互換の optional メタデータ＋既定値で強制）

- `ClientInfo` / `TokenClientInfo`（および sample/CLI の client モデル）に optional で追加:
  - `responseTypes?: string[]`（既定 `["code"]`）
  - `grantTypes?: string[]`（既定 `["authorization_code"]`、refresh を使うクライアントは `["authorization_code", "refresh_token"]`）
  - `tokenEndpointAuthMethod?: 'client_secret_basic' | 'client_secret_post' | 'none'`（既定 `client_secret_basic`）
- 検証:
  - 認可エンドポイント: `response_type` が `client.responseTypes`（既定込み）に含まれなければ `unauthorized_client`（redirect 可能エラー）。
  - トークンエンドポイント: `grant_type` が `client.grantTypes`（既定込み）に含まれなければ `unauthorized_client`。
  - クライアント認証: 実際に使われた方式が `client.tokenEndpointAuthMethod` と一致しなければ `invalid_client`（方式不一致は認証失敗扱い）。
- 未指定クライアントは既定値で動くため既存テスト・既存利用者に影響なし。

### 方針B（grant_types のみ先行、response_types / auth_method は後続）

- 最も価値が高くリスクが低い `grant_types` 強制（特に refresh_token）だけ先に入れる。
- `response_types` は Basic OP では `code` 固定のため恩恵が小さく、Hybrid 拡張時に合わせて入れる。
- `token_endpoint_auth_method` 強制は `private_key_jwt` / `none` 導入（既存 study）と同時に入れる。

### 方針C（per-client scope も同時に強制）

- `allowedScopes?: string[]` を足し、登録外 scope を `invalid_scope` で弾く or フィルタ。
- ただし「弾く vs フィルタ」は `scope-handling-validation-and-granted-scope.md` の未決事項と連動するため、本トピック単独では決めない。

### 方針D（現状維持＋ドキュメント）

- Basic OP 必須ではないとして見送り、利用者が resolver 側で自前検証する前提をドキュメント化。

判断材料:

- `redirect_uris` 検証という前例があり、方針 A のコストは中程度（型追加＋3 箇所の検証＋テスト）。
- refresh_token の grant 強制（方針 B の核）は Refresh Token フローの安全性に直結し、単独でも価値が高い。
- `response_types` 強制は Basic OP 単体では恩恵が薄く、拡張プロファイル前提。
- per-client scope（方針 C）は別ファイルの未決事項に依存するため、本タスクから切り離すのが安全。

## 8. タスク案

- [ ] 方針 A / B / C / D を人間が選択する
- [ ] （採用時）`ClientInfo` / `TokenClientInfo` に `grantTypes` / `responseTypes` / `tokenEndpointAuthMethod` を optional 追加し、既定値を定義
- [ ] `validateTokenRequest` に grant_type のクライアント単位検証を追加し、違反時 `unauthorized_client` を throw（TDD: Red → Green）
- [ ] `validateAuthorizationRequest` に response_type のクライアント単位検証を追加し、違反時 `unauthorized_client`（redirect 可能エラー）を throw
- [ ] `authenticateClient` に `token_endpoint_auth_method` 一致検証を追加
- [ ] sample / CLI テンプレートの client モデルに新フィールドを反映（refresh を使うサンプルクライアントは `grant_types` に `refresh_token` を含める）
- [ ] Discovery の `grant_types_supported` / `token_endpoint_auth_methods_supported`（T-021）と整合をとる
- [ ] per-client scope 強制（方針 C）は `scope-handling-validation-and-granted-scope.md` の未決事項を確認してから別途判断する
- [ ] Basic OP テストプランが `unauthorized_client` を検証するかを一次資料で確認する
