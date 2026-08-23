# 拡張: OpenID Connect Back-Channel Logout 1.0

## ステータス

🟢 拡張機能 / 未着手

## 1. このトピックで確認したいこと

OpenID Connect Back-Channel Logout 1.0 は、**OP が同一エンドユーザーセッションを共有する全 RP へ、サーバー間（バックチャネル）でログアウト通知を送る**仕様。
ユーザーのブラウザを介さず確実に SLO（Single Logout）を伝播できるため、現代の SSO ログアウトの主流。

既存ファイル `study-material/ext-rp-initiated-logout.md` は **RP-Initiated Logout 1.0**（RP がブラウザリダイレクトで OP に遷移してログアウト）を主題とし、Back-Channel Logout は関連として軽く触れているだけ。
本ファイルは **Back-Channel Logout 1.0 の OP 側実装要件・差分**に絞って独立トピックとして整理する。Front-Channel Logout（別仕様、ブラウザ iframe 経由）は別ファイル化候補だが、本ファイルでは扱わない。

## 2. 関連する仕様・基準

共通の仕様索引は `study-material/basic-op-requirement-traceability.md` を参照。RP-Initiated Logout の仕様説明は重複させず `study-material/ext-rp-initiated-logout.md` を参照すること。

本トピック固有のポイント:

- **OpenID Connect Back-Channel Logout 1.0**:
  - **`logout_token`** = ログアウト通知用 JWT。OP が署名し、RP の `backchannel_logout_uri` に **POST**（`application/x-www-form-urlencoded` で `logout_token=<JWT>`）する。
  - `logout_token` の **必須クレーム**:
    - `iss`（OP の issuer）
    - `aud`（RP の client_id、複数可）
    - `iat`（発行時刻）
    - `jti`（一意 ID、リプレイ防止）
    - `events`: **`{"http://schemas.openid.net/event/backchannel-logout": {}}` を含む** JSON オブジェクト
    - `sub` または `sid` の **少なくとも一方**（両方も可）
  - **禁止クレーム**: `nonce` MUST NOT be present（ID Token と区別するため）。
  - **署名**: OP の通常の ID Token 署名鍵で署名。暗号化（JWE）も任意。
  - **`sid`（Session ID）クレーム**: OP セッションを一意に識別する不透明な ID。ID Token 発行時に同じ `sid` を含めておくと、RP が「自分が持つ ID Token のセッションがログアウトされた」と紐付けられる。
- **RP のクライアントメタデータ**:
  - `backchannel_logout_uri`: OP が POST する RP のエンドポイント URL（HTTPS 必須）
  - `backchannel_logout_session_required`: boolean、`logout_token` に `sid` が必要かどうか
- **Discovery メタデータ**:
  - `backchannel_logout_supported`: boolean
  - `backchannel_logout_session_supported`: boolean（`sid` を発行するか）
- **OP 側責務**:
  - エンドユーザーがログアウト（RP-Initiated またはセッション期限）すると、影響を受ける全 RP の `backchannel_logout_uri` に `logout_token` を POST する。
  - POST 失敗時のリトライ／タイムアウト方針は仕様に明示なし。実装次第（指数バックオフが現実的）。
- **RP 側責務**（参考）:
  - `logout_token` の署名検証、`events` クレーム検証、`nonce` 不在検証、`jti` リプレイチェック、対応するローカルセッションの破棄。
  - HTTP 200 OK を 5 秒以内に返すことが推奨される。

## 3. 参照資料

- OpenID Connect Back-Channel Logout 1.0: https://openid.net/specs/openid-connect-backchannel-1_0.html
  - §2 Back-Channel Logout
  - §2.4 Logout Token Validation（OP は発行責務、RP は検証責務）
  - §3 Back-Channel Logout Endpoint
  - §5 Logout Token（必須クレーム、events、sid）
- OpenID Connect Core 1.0 §2.10 / §2.11（sid クレームの定義）: https://openid.net/specs/openid-connect-core-1_0.html
- 本リポジトリ `study-material/ext-rp-initiated-logout.md`（RP-Initiated と関連だが別仕様）

## 4. 現在の実装確認

- ログアウト関連エンドポイント・ロジックは**全く未実装**（`ext-rp-initiated-logout.md` の §4 と同じ）。
- `packages/core/src/id-token.ts`: ID Token 発行ロジックに `sid` クレームを埋め込む経路は **無い**。`IdTokenPayload` 型に `sid` は含まれていない。
- `packages/core/src/auth-transaction.ts` の `SessionInfo` には `subject` / `authTime` のみで、セッション一意 ID は無い。Back-Channel Logout の `sid` 設計の基盤が欠けている。
- `packages/core/src/discovery.ts` の `ProviderMetadataConfig` には `backchannel_logout_supported` / `backchannel_logout_session_supported` フィールド無し。
- `ClientInfo` には `backchannel_logout_uri` / `backchannel_logout_session_required` フィールド無し。
- JWT 署名のヘルパー（`packages/core/src/id-token.ts` 内の sign 部分）は存在し再利用可能。**`logout_token` 専用の発行関数**を追加すれば、署名インフラは流用できる。

## 5. 現在の実装との差分

満たしていること:

- JWT 署名インフラ（RS256 / JWKS 公開）は既存（`signing-key.ts` / `id-token.ts`）。
- ID Token 発行時に追加クレームを差し込む経路は存在し、`sid` を入れることは技術的に容易。

不足／要確認:

- 🔴 **`logout_token` 発行関数が無い**: `events` / `sid` / `jti` / `nonce` 禁止 を含む logout_token を作る純関数を core に新設する必要がある（ID Token 発行と似た構造だがクレーム集合が異なる）。
- 🔴 **OP セッションに `sid` が無い**: `SessionInfo` に session ID を持たせ、ID Token 発行時に同じ値を `sid` クレームとして埋め込む実装が必要。
- 🔴 **クライアントメタデータ拡張**: `ClientInfo` に `backchannelLogoutUri` / `backchannelLogoutSessionRequired` を追加。
- 🔴 **RP 通知の配送機構**: 影響を受ける RP リスト（同一エンドユーザーセッションを共有する RP の集合）を解決する resolver / store の I/F が無い。Back-Channel Logout は **OP がアクティブに POST するプッシュ通知**で、通知失敗時のリトライ / タイムアウト / 並行送信戦略の設計が必要（純関数 core ではなく、利用者注入の resolver/transport で扱う設計が自然）。
- 🔴 **Discovery メタデータ**: `backchannel_logout_supported` / `backchannel_logout_session_supported` を `ProviderMetadataConfig` に追加。
- 🟡 **`jti` のリプレイ防止**: RP 側責務だが、OP が `jti` を確実に一意にする（`crypto.randomUUID()` 等）保証は必要。
- 🟡 **RP-Initiated Logout との連動**: RP-Initiated Logout で OP セッションが終了したとき、関連 RP に Back-Channel 通知を発火する経路が必要（`ext-rp-initiated-logout.md` の方針A実装と統合設計を要する）。

セキュリティ観点:

- 🟡 **`logout_token` リプレイ攻撃**: OP は `jti` を一意化、`iat` を current time、TTL 短（数分）にする。RP 側で重複検知。
- 🟡 **`backchannel_logout_uri` 検証**: クライアント登録時に HTTPS スキーム必須。OP は **DNS Rebinding / SSRF 防止** のため、内部 IP への POST を拒否するかどうかの方針を決める（運用ポリシー）。
- 🟡 **複数 audience のときの aud**: 同一ユーザーが複数 RP にログインしている場合、各 RP ごとに別 `logout_token` を発行する（`aud` を 1 つに絞る）。複数 `aud` も仕様上可能だが、混乱を避けるため OP は単独 aud で発行するのが慣例。

相互運用性観点:

- 🟡 **OP セッション一意 ID `sid` の運用**: ID Token 発行 → 後から logout_token に同じ `sid` を入れる必要があるため、`sid` は OP セッション全寿命で安定する必要がある。SessionResolver の I/F 変更を伴う。

## 6. 改善・追加を検討する理由

- **SSO シングルログアウトは本番運用で常に問われる**: PoC で「複数アプリにログインして、1 箇所からログアウトすると全部切れる」を検証するのが SME ファネルの典型シナリオ（`RELEASE-v0.x-scope.md` の検証シナリオ「1ログインで複数サンプルアプリに入れる」の対になる）。
- **Front-Channel Logout より Back-Channel が現代的**: iframe 経由（Front-Channel）はサードパーティ Cookie 制限・CSP 制限で実運用が困難。Back-Channel は HTTPS POST だけで動くため信頼性が高い。
- **規模が大きい**: 実装は中〜大規模。`logout_token` 発行関数、`sid` 管理、RP 通知 transport / リトライ、Discovery 追加、ClientInfo 拡張、`ext-rp-initiated-logout.md` との統合が必要。
- **実装しない場合のリスク**: SLO 検証ができず、PoC でログアウト周りの仕様検証が成立しない。SME 向け FAQ で「ログアウトはどう伝播しますか」の答えが「自前で実装してください」になる。

## 7. 実装方針の候補

### 方針A（段階導入・推奨度高）: RP-Initiated Logout 完了後に Back-Channel を追加

- `ext-rp-initiated-logout.md` の方針A（RP-Initiated 最小実装）を先に完了し、`SessionResolver` / セッション終了 callback の I/F を確立した上で、Back-Channel をその上に乗せる。
- core に `generateLogoutToken({ iss, aud, sub?, sid?, jti, iat, eventsExtra? })` を追加。`signJwt` ヘルパーを ID Token 実装と共有。
- `ClientInfo` に `backchannelLogoutUri?: string` / `backchannelLogoutSessionRequired?: boolean` を追加。
- `BackchannelLogoutNotifier` 的 callback I/F を新設し、HTTP POST 実装は利用者責務（fetch を使った参照実装は CLI テンプレートで提供）。
- Discovery メタデータに `backchannel_logout_supported: true` / `backchannel_logout_session_supported: <配置による>` を追加。
- `SessionInfo` を `{ subject, authTime, sessionId? }` に拡張し、ID Token 発行時に `sid` を埋める（既存 ID Token テストへの後方互換は `sessionId` を optional にして担保）。

### 方針B（先行・小さく試す）: `logout_token` 発行関数とテストだけ先に追加

- `generateLogoutToken` 関数と単体テスト（必須クレーム / 禁止クレーム / 署名 / events）のみを core に追加。
- 配送機構・RP 通知は後続。
- 利点: 仕様の中核（JWT フォーマット）を低コストで固定でき、Conformance Suite の logout_token 検証ロジックが先行テスト可能。

### 方針C（非対応の明文化）

- ロードマップ後送り。Discovery に `backchannel_logout_supported: false` を明示。

最終判断は人間。RELEASE-v0.x-scope.md の v0.x スコープ外で良いが、SME ファネルの SSO シナリオを検証可能にするには中期で必要。

## 8. タスク案

- [ ] `ext-rp-initiated-logout.md` の方針A の完了状況を確認し、Back-Channel を「その後段」として位置づける
- [ ] `generateLogoutToken` 関数のテストを TDD で先行作成（必須クレーム、`events` の値、`nonce` 不在、`jti` 一意、署名アルゴリズム RS256）
- [ ] `IdTokenPayload` / `SessionInfo` に `sid` を追加（後方互換: optional）
- [ ] ID Token 発行時に `sid` を含めるオプションを `generateTokenResponse` に追加
- [ ] `ClientInfo` に `backchannelLogoutUri` / `backchannelLogoutSessionRequired` を追加（後方互換: optional）
- [ ] `ProviderMetadataConfig` に `backchannelLogoutSupported` / `backchannelLogoutSessionSupported` を追加
- [ ] `BackchannelLogoutNotifier` 的 I/F を設計（POST / リトライポリシーは注入）
- [ ] CLI / sample に Back-Channel 通知の参照実装（fetch + 指数バックオフ）を生成
- [ ] `tasks/basic-op-requirement-traceability.md` に Back-Channel Logout の充足状況を追記
