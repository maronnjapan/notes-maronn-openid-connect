# 拡張: OAuth 2.0 Client Credentials Grant（RFC 6749 §4.4 / OAuth 2.1 §4.2）

## ステータス

🟢 拡張機能 / 未着手（検討段階：OP の対象範囲を「ユーザ認証」から「マシン間認可」へ広げるかの方針判断が必要）

## 1. このトピックで確認したいこと

現在 Token Endpoint がサポートする `grant_type` は `authorization_code` と `refresh_token` の 2 つのみ（`packages/core/src/token-request.ts:403`）。
本トピックでは、**Client Credentials Grant（`grant_type=client_credentials`）** を本リポジトリに導入するかを整理する。

Client Credentials Grant は、ユーザの介在しない **マシン間（machine-to-machine, M2M）認可** のためのフローで、クライアント自身が自分の権限でアクセストークンを取得する。
代表的なユースケース:

- バックエンドサービス同士のAPI呼び出し（cron / バッチ / サービスメッシュ）
- CLIツール・CI/CDパイプラインからの保護リソースアクセス
- IdaaS（Auth0 / Okta / Entra ID）が「API用のM2Mトークン」として広く提供している機能の検証

OIDC のユーザ認証フロー（Authorization Code）とは独立した OAuth 2.0 の機能であり、**Basic OP 認定の必須範囲ではない**。しかし「自分の要件がこの仕様で実現できるか」を検証する本ライブラリのコンセプト上、PoC 開発者が頻繁に必要とする。

## 2. 関連する仕様・基準

共通の仕様索引（OIDC Core / OAuth 2.1 / Basic OP の定義）は `study-material/basic-op-requirement-traceability.md` の「3. 関連する仕様・基準」を参照。本トピック固有のポイントのみ記載する。

### 2.1 RFC 6749 §4.4 / OAuth 2.1 §4.2（Client Credentials Grant）

- リクエスト（Token Endpoint への POST）:
  - `grant_type=client_credentials`（必須）
  - `scope`（任意、スペース区切り）
  - **クライアント認証は必須**。RFC 6749 §4.4.2 は「The client MUST authenticate with the authorization server」と規定。すなわち **公開クライアント（`token_endpoint_auth_method=none`）はこのグラントを使用できない**。
- レスポンス（RFC 6749 §4.4.3 / §5.1）:
  - `access_token` / `token_type` / `expires_in` / （必要に応じ）`scope`
  - **`refresh_token` を含めてはならない（SHOULD NOT）**。RFC 6749 §4.4.3: "A refresh token SHOULD NOT be included." リフレッシュは不要で、必要なら再度 client_credentials で取得する。
  - **`id_token` は発行しない**。エンドユーザが存在せず、認証イベントが無いため OIDC ID Token の概念が当てはまらない（`sub` がユーザを指さない）。
- エラー: スコープ過大要求は `invalid_scope`、未認可クライアントは `unauthorized_client`、OP 全体未サポート時は `unsupported_grant_type`（RFC 6749 §5.2）。

### 2.2 RFC 9068（JWT Access Token）における sub の扱い

- M2M トークンには「リソースオーナー」が存在しない。RFC 9068 §3 は「In the case of access tokens obtained through grants where a resource owner is not present, such as the client credentials grant, the value of `sub` SHOULD correspond to an identifier the authorization server uses to indicate the client」と規定。
- すなわち **`sub` = `client_id`（またはOPがクライアントに割り当てた安定識別子）** とするのが正しい。`client_id` クレームと併記する。

### 2.3 Discovery（RFC 8414 §2 / OIDC Discovery 1.0 §3）

- 対応する場合は `grant_types_supported` に `client_credentials` を追加する。
- Client Credentials Grant のスコープは `openid` を含まないのが通常（ユーザ認証ではないため）。`scopes_supported` の意味づけと整合させる。

### 2.4 セキュリティ上の注意（OAuth 2.0 Security BCP / RFC 9700）

- Client Credentials は **クライアント自身の権限**を表す。ユーザ委譲の権限（Authorization Code で得たスコープ）と **混同しない**こと。同じ `scope` 名でも「ユーザに代わって」か「サービス自身として」かで意味が変わるため、リソースサーバ側の認可判断で区別が必要。
- 公開クライアント禁止の徹底（§2.1）。client_secret 漏洩は全権限の漏洩に直結するため、`client_secret` のタイミング安全比較・at-rest ハッシュ（既存 `study-material/security-client-secret-handling.md` / `study-material/credential-at-rest-hashing.md`）の前提が一層重要になる。

## 3. 参照資料

- RFC 6749 §4.4 Client Credentials Grant: https://www.rfc-editor.org/rfc/rfc6749#section-4.4 （リクエスト/レスポンス、refresh_token を含めない SHOULD NOT の根拠）
- OAuth 2.1 draft §4.2 Client Credentials Grant: https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1#section-4.2 （OAuth 2.1 でも維持されているグラント。implicit/password と異なり削除されていない点が重要）
- RFC 9068 §3 JWT Profile for Access Tokens（`sub` = client identifier の扱い）: https://www.rfc-editor.org/rfc/rfc9068#section-3
- RFC 6749 §5.2 Error Response（`unauthorized_client` / `unsupported_grant_type` / `invalid_scope`）: https://www.rfc-editor.org/rfc/rfc6749#section-5.2
- RFC 9700 OAuth 2.0 Security Best Current Practice: https://www.rfc-editor.org/rfc/rfc9700

## 4. 現在の実装確認

- **未実装**。`packages/core/src/token-request.ts:403` で `grant_type` が `authorization_code` / `refresh_token` 以外なら `unsupported_grant_type` を返す。`client_credentials` はここで弾かれる。
- クライアント認証基盤は既に存在: `packages/core/src/client-auth.ts`（`authenticateClient`、`client_secret_basic` / `client_secret_post` / `none`、タイミング安全比較）。Client Credentials に必要な「confidential クライアント認証」はそのまま流用可能。
- アクセストークン発行基盤も存在: `packages/core/src/access-token-issuer.ts`（`createJwtAccessTokenIssuer` / `createOpaqueAccessTokenIssuer`）、`packages/core/src/access-token.ts`（RFC 9068 JWT AT）、`buildAccessTokenAudience`（`token-response.ts`）。
- クライアント単位のグラント認可は実装済み: `token-request.ts:430` が `client.grantTypes ?? ['authorization_code']` を見て `unauthorized_client` を返す。`grantTypes` に `client_credentials` を含むクライアントだけ許可、という制御が既存機構で可能。
- Discovery の `grant_types_supported` は呼び出し側が指定する形（`packages/core/src/discovery.ts`、`tasks/T-021-discovery-metadata.md`）。

## 5. 現在の実装との差分

- 🟢 **Basic OP 認定要件ではない**: 未対応でも仕様違反ではない。広告（Discovery）もしていないため整合は取れている。
- 🟡 **核となる部品はほぼ揃っている**: クライアント認証・アクセストークン発行・スコープ処理・grant_types 認可がすべて既存。`token-request.ts` に分岐を 1 つ足し、`token-response.ts` に「id_token / refresh_token を発行しない経路」を通せば成立する規模。
- 🔴 **不足**: `client_credentials` 分岐そのもの。`scope` の検証（クライアントに許可されたスコープのサブセットか）と、`sub=client_id` のアクセストークン発行経路。
- 🟡 **設計上の確認点**:
  - 既存 `generateTokenResponse` は ID Token 発行を前提にした引数構成（`idTokenPrivateKey` 等）。Client Credentials では ID Token を発行しないため、`generateTokenResponse` に経路を足すか、専用の軽量関数（`generateClientCredentialsResponse` 等）を切り出すかの判断が必要。
  - クライアントに許可するスコープ（`client.allowedScopes` 相当）を表現するクライアントメタデータが現状は無い。スコープ過大要求の拒否（`invalid_scope`）を実装するには、クライアント定義にスコープ許可リストを足すか、resolver にスコープ判定を委譲する。

## 6. 改善・追加を検討する理由

価値:

- **PoC 需要が高い**: M2M トークンは IdaaS の定番機能。本ライブラリで「Authorization Code はユーザ認証、client_credentials はサービス認可」という 2 軸を両方試せると、API 認可基盤の検証ブリッジとして価値が上がる。
- **OAuth 2.1 で維持されたグラント**: implicit / password は OAuth 2.1 で削除された（`study-material/done/oauth21-removed-grants-explicit-rejection.md`）が、client_credentials は **削除されていない正規のグラント**。「OAuth 2.1 準拠を謳うなら本来カバーすべき範囲」という整合性の観点もある。
- **導入が容易**: §5 のとおり既存部品の再利用で完結し、ユーザ認証フロー（セッション・consent・nonce 等）に一切触れないため副作用が小さい。

Basic OP として必要か、拡張機能か:

- **拡張機能**。Basic OP（Authorization Code Flow のみ）の必須範囲外。ただし「OAuth 2.1 準拠」という上位の主張を補強する位置づけ。

導入しない場合のリスク・制約:

- M2M / API-to-API 認可の PoC ができず、ユーザ認証フローしか検証できない。商用 IdaaS からの移行検証では「M2M トークンも出せること」を期待されることが多く、機能ギャップになる。

## 7. 実装方針の候補

最終判断（採用可否・方針）は人間が行う。以下は判断材料。

### 方針A（非対応の明文化）

- `RELEASE-v0.x-scope.md` に「v0.x はユーザ認証フローに集中、client_credentials はスコープ外」と明記し、`unsupported_grant_type` を返す現状を意図的挙動として固定する（テストで担保）。

### 方針B（最小実装：scope 許可リスト無し）

- `token-request.ts` に `client_credentials` 分岐を追加。confidential クライアント認証必須（`none` は `invalid_client` で拒否）。
- スコープは要求された値をそのまま付与（過大要求の検証はせず、resolver/リソースサーバ側に委譲）。
- アクセストークンのみ発行（`sub=client_id`、`refresh_token`・`id_token` 無し）。
- Discovery の `grant_types_supported` に `client_credentials` を追加。

### 方針C（推奨：scope 許可リスト付き）

- 方針B に加え、クライアントメタデータに「許可スコープ」を持たせる（または `ClientScopePolicyResolver` を注入）。
- 要求 scope ⊄ 許可スコープ なら `invalid_scope`。
- これにより「クライアントごとに M2M で出せるスコープを制限」という実運用に近い検証ができる。

判断材料:

- 方針 B は最短だが、スコープ無制限は検証用途として物足りない（リソースサーバが全スコープを受け入れる前提になる）。
- 方針 C はクライアント定義の拡張が必要だが、`client.grantTypes` を既に持つクライアント定義に許可スコープを足すのは自然な延長。
- いずれの方針でも **公開クライアント禁止** と **refresh_token 非発行** は仕様上固定で、ブレない。

接続先の既存実装:

- クライアント認証: `client-auth.ts`（そのまま再利用）
- トークン発行: `access-token-issuer.ts` / `access-token.ts` / `buildAccessTokenAudience`
- grant_types 認可: `token-request.ts:430` の既存機構

## 8. タスク案

- [ ] 方針 A / B / C のいずれを採用するか人間が判断（OP の対象範囲を M2M へ広げるかの product 判断）
- [ ] 採用時（方針 B/C 共通）:
  - [ ] `packages/cli` のテンプレートと `packages/core` を変更する（生成 OP の挙動変更のため、`samples/*/conformance.test.ts` を直接ではなく CLI 側で更新）
  - [ ] `token-request.ts` に `grant_type=client_credentials` 分岐を追加（confidential 認証必須、`none` は `invalid_client`）
  - [ ] アクセストークン発行経路（`sub=client_id`、`id_token`/`refresh_token` 無し）
  - [ ] Discovery `grant_types_supported` に `client_credentials` を追加
  - [ ] テスト: confidential クライアントで AT 取得 / 公開クライアントは拒否 / `refresh_token` が返らない / `id_token` が返らない / `sub=client_id`
- [ ] 方針 C 採用時: クライアント許可スコープの表現（メタデータ or resolver）と `invalid_scope` 拒否のテスト
- [ ] E2E（`tests/e2e`）: 生成 OP に対し client_credentials で AT 取得 → リソースサーバで検証するフローを追加（実HTTPフロー検証）

> 注: 本グラントは OP の対象範囲（ユーザ認証 vs マシン認可）に関わる方針判断を含むため、方針が確定するまでは検討段階（study-material）に留める。確定後にタスク化する。
