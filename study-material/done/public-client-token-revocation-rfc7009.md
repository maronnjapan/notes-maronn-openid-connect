# パブリッククライアントの Token Revocation 対応（RFC 7009 §2.1）

## ステータス

🟡 Medium / 未着手

## 1. このトピックで確認したいこと

Token Revocation エンドポイント（RFC 7009）が **confidential client 認証を必須**としており、`client_secret` を持たない **public client（SPA / ネイティブアプリ等、OAuth 2.1 で認可コード＋PKCE が前提のクライアント）が自身のトークンを revoke できない** 点を確認する。

OAuth 2.1 では public client が認可コードフロー（PKCE 必須）の主役であり、refresh token を保持し得る（public client は rotation 強制、`study-material/refresh-token-public-client-rotation-enforcement.md` 参照）。にもかかわらず、**ログアウト時やトークン破棄時に public client が refresh/access token を能動的に失効させる経路が無い**。RFC 7009 §2.1 は public client による revocation を想定しているため、この欠落を埋めるべきか検討する。

> 重複を避けるための関連既存ファイル（同じ説明は繰り返さない）:
> - public client の **Token Endpoint** 認証対応（`token_endpoint_auth_method=none`）: `tasks/p1-public-client-token-endpoint.md`（本ファイルはその **Revocation エンドポイントへの波及**という差分のみを扱う）
> - Revocation の実装そのもの（cascade revocation 等）: `tasks/done/p1-token-revocation.md`
> - public client の refresh token rotation 強制: `study-material/refresh-token-public-client-rotation-enforcement.md`
> - クライアント認証の core 化: `tasks/done/p0-client-authentication.md`
>
> なお **Introspection（RFC 7662）は protected resource（resource server）向け**であり、public client が呼ぶことは本来想定されない（resource server は別途認証される）。よって本ファイルは **Revocation に限定**し、introspection の public client 対応は対象外とする。

## 2. 関連する仕様・基準（このトピック固有の差分）

### 2.1 RFC 7009 §2.1 Revocation Request

- クライアントは revocation リクエストに **自身の認証情報（authentication credentials）を含める**。ただし RFC 7009 §2.1 は **confidential client のときに client credentials を検証**し、その後に「トークンがリクエスト元クライアントに発行されたものか」を検証する、と規定する。
  - 引用（趣旨）: "the authorization server first validates the client credentials (in case of a confidential client) and then verifies whether the token was issued to the client making the revocation request."
  - → **public client の場合は `client_secret` 検証は行わず、`client_id` によりトークンの発行先クライアント一致のみを検証する**、という読み方になる。public client が revoke できることが前提。
- §2.1: トークンが他クライアントに発行されていた場合はリクエストを拒否し、クライアントへエラーを返す（現実装は `invalid_grant` で対応済み）。

### 2.2 RFC 7009 §2.2 Revocation Response

- 失効成功・トークン未発見いずれも `200 OK`（情報サイドチャネルを与えない）。本要件は public/confidential 共通で、現実装は満たす。

### 2.3 OAuth 2.1 における public client の位置づけ

- OAuth 2.1 §2.1: public client は `client_secret` を安全に保持できないクライアント。認可コード＋PKCE が必須。
- public client が refresh token を保持し得る以上、**漏洩時の被害最小化のために自発的失効（logout 等）の手段を提供することはセキュリティ上有益**。

## 3. 参照資料

- RFC 7009 OAuth 2.0 Token Revocation §2.1 Revocation Request
  — https://www.rfc-editor.org/rfc/rfc7009#section-2.1
  （"in case of a confidential client" の条件付き credential 検証＝public client は client_id 一致のみ）
- RFC 7009 §2.2 Revocation Response
  — https://www.rfc-editor.org/rfc/rfc7009#section-2.2
- OAuth 2.1 draft（public client / PKCE）
  — https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1
- 関連: RFC 9700 OAuth 2.0 Security BCP（トークン失効の推奨）
  — https://www.rfc-editor.org/rfc/rfc9700

## 4. 現在の実装確認

- core: `packages/core/src/revocation.ts`
  - `handleRevocationRequest`（`revocation.ts:124-151`）は `authenticatedClientId` が非空であることを要求し、`tryRevokeAccess` / `tryRevokeRefresh` で `info.clientId !== authenticatedClientId` のとき `invalid_grant` を返す。
  - core 自体は **`authenticatedClientId` を受け取るだけ**で、認証方式（confidential/public）を区別しない。したがって **「public client の client_id を `authenticatedClientId` として渡せば」core はそのまま機能する**余地がある。問題は HTTP 配線側（クライアント認証ステップ）。
- core: `packages/core/src/client-auth.ts`
  - `authenticateClient`（`client-auth.ts:106-180`）は `client_id` と `client_secret` の両方が無いと `invalid_client`（`client-auth.ts:141-146`）。`tokenEndpointAuthMethod` の既定は `client_secret_basic` で、`none`（public）経路は現状未実装（`tasks/p1-public-client-token-endpoint.md` が Token Endpoint 向けに整備予定）。
- sample: `packages/sample/src/oidc-provider/routes/revocation.ts`
  - 冒頭コメントで **`Confidential client only — public clients are out of scope for this template.`** と明示。`authenticateClient(...)` を confidential 前提で呼ぶため、public client は revoke 不能。

## 5. 現在の実装との差分

- **満たしていること**:
  - confidential client による revocation（cascade revocation 含む）は実装済み（`tasks/done/p1-token-revocation.md`）。
  - 他クライアント発行トークンの拒否（`invalid_grant`）、200 応答の側チャネル防止。
- **不足している可能性があること**:
  - **public client がトークンを revoke する経路が無い**（HTTP テンプレートが confidential 限定）。
  - `authenticateClient` に public（`none`）経路が無いため、revocation も含め public client 認証が成立しない。
- **セキュリティ上、改善した方がよいこと**:
  - public client（SPA/native）のログアウト時にサーバ側 refresh/access token を確実に失効できる手段が無いと、漏洩トークンの自発的無効化ができない。public client は rotation 強制でも、明示失効の経路があるとさらに被害を限定できる。
- **相互運用性の観点**:
  - 多くの IdP は public client の revocation を許容する。非対応だと SPA/native の検証で「ログアウトで RT を無効化したい」要件を満たせない。
- **Basic OP として確認すべきこと**:
  - Revocation は **Basic OP の必須要件ではない**（OAuth 拡張）。Conformance への影響は無い。OSS としての機能網羅・安全性の観点で扱う。

## 6. 改善・追加を検討する理由

- **なぜ価値があるか**: 本ライブラリは PoC 開発者が「自分の要件がこの仕様で実現できるか」を素早く検証するためのもの。SPA/native（public client）は主要な検証対象であり、その **ログアウト／トークン破棄フロー**は実運用直前で必ず問われる。public client が revoke できないと、この検証ができない。
- **Basic OP として必要か / 拡張か**: Basic OP 必須ではない。**OAuth 拡張の機能網羅**として位置づける。
- **導入しやすさ / しにくさ**:
  - core の `handleRevocationRequest` は既に `authenticatedClientId` ベースで動くため、**HTTP 配線で public client を `client_id` のみで解決できれば波及は小さい**。
  - ただし前提として `authenticateClient` の public（`none`）対応（`tasks/p1-public-client-token-endpoint.md`）が必要で、**そのタスクと足並みを揃える**のが自然。単独で revocation だけ先行すると認証ロジックが二重化する懸念がある。
- **既存実装との接続**: `RefreshTokenInfo.clientId` / `AccessTokenInfo.clientId` を `client_id` と突き合わせる既存ロジックがそのまま使える。
- **利用者メリット**: public client の logout / トークン破棄を実機で検証できる。
- **実装しない場合のリスク**: public client のトークンライフサイクル（特に失効）が検証不能のまま残り、「rotation はあるが明示失効が無い」非対称な状態になる。

## 7. 実装方針の候補（最終判断は人間）

### 方針A（推奨度：高 / 依存整理）: `p1-public-client-token-endpoint` の後追いで revocation を拡張

- 先に `tasks/p1-public-client-token-endpoint.md` で `authenticateClient`／クライアント認証解決を **confidential/public 両対応**に整える。
- その共通認証ロジックを revocation ルートでも再利用し、public client（`token_endpoint_auth_method=none`）は `client_id` のみで認証扱いにする。
- core 側 `handleRevocationRequest` は変更不要（`authenticatedClientId` に public の client_id を渡すだけ）。
- sample/CLI テンプレートの「Confidential client only」コメントを更新し、public 経路を追加。

### 方針B: revocation 専用の最小 public 受け入れ

- Token Endpoint の public 対応を待たず、revocation ルートだけで「`client_secret` 不在かつ登録上 public なら `client_id` のみで受理」する最小ロジックを入れる。
- 早く検証できるが、認証ロジックが Token Endpoint と revocation で二重化し、将来の統合コストが増える（**非推奨寄り**）。

### 方針C: ドキュメントで非対応を明示

- 当面 public client revocation を非対応と明記し、`refresh-token-public-client-rotation-enforcement.md`（rotation による被害限定）でカバーする旨を記載。
- 機能は増えないが、設計判断を保留したいときの選択肢。

> 判断材料: 方針A が認証ロジックの一元化と整合し最も健全。public client 対応そのもの（`p1-public-client-token-endpoint`）の進捗に依存するため、**依存関係を明示してそのタスク完了後に着手**するのが安全。

## 8. タスク案

- [ ] `tasks/p1-public-client-token-endpoint.md` の public 認証解決（`none` 対応）完了を前提条件として確認
- [ ] 方針A/B/C のいずれで進めるかをユーザー判断
- [ ] 方針A採用時: `revocation.test.ts`（または統合テスト）に先行テスト追加
      - public client が `client_id` のみで自身の refresh token を revoke できる
      - public client が **他クライアント発行**トークンを指定したら `invalid_grant`
      - confidential client の既存挙動は回帰しない
- [ ] public 認証経路を revocation ルートで再利用（core は変更しない方針を維持）
- [ ] sample/CLI テンプレートの「Confidential client only」コメントと配線を更新
- [ ] 完了条件: `pnpm --filter @maronn-openid-connect/core test` および `pnpm --filter @maronn-openid-connect/cli test` がパス
