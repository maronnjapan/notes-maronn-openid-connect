# 拡張: OpenID Connect Front-Channel Logout 1.0 / Back-Channel Logout 1.0

## ステータス

🟢 拡張機能 / 未着手

## 1. このトピックで確認したいこと

`study-material/ext-rp-initiated-logout.md` は **RP からの OP セッション終了要求**（`end_session_endpoint`）が主題で、
Front-Channel / Back-Channel Logout については「方針B（段階導入）」として一言触れるにとどまっている。

しかし Front-Channel / Back-Channel Logout は **「OP セッションが終了したことを他 RP（同じ OP セッション配下で SSO していた RP 群）にどう通知するか」** という、RP-Initiated とは独立した責務を持つ仕様である。

このファイルは Front-Channel Logout 1.0 / Back-Channel Logout 1.0 の比較・選択基準・本リポジトリへの導入観点を、RP-Initiated と重複しない差分だけ整理する。

具体的には:

- 「ログアウト要求の入口」は RP-Initiated 側で扱い、本ファイルは扱わない
- 「OP セッション終了後の他 RP への通知メカニズム」（フロント iframe / バックチャネル JWT POST）を扱う
- 既存資産（`SessionResolver`, `validateIdTokenHint`, 署名鍵プロバイダ）を流用できる範囲を確認する

## 2. 関連する仕様・基準

RP-Initiated Logout / Session Management の概要は `study-material/ext-rp-initiated-logout.md` を参照。
本ファイルはそれを踏まえた **通知メカニズムの差分** にフォーカスする。

### 2.1 Front-Channel Logout 1.0

- ユーザーエージェントを経由した「OP の logout ページに対象 RP の `frontchannel_logout_uri` を `<iframe>` として埋め込み、ブラウザのクッキー権限で各 RP のセッションを破棄させる」モデル。
- クライアントメタデータ:
  - `frontchannel_logout_uri`（URI、`https`）
  - `frontchannel_logout_session_required`（boolean: true なら `iss`/`sid` クエリを付与）
- Discovery: `frontchannel_logout_supported`、`frontchannel_logout_session_supported`。
- 受動的通知。OP は iframe を描画するだけで、各 RP のセッションが本当に終わったかは保証しない。
- サードパーティクッキーの規制（Chrome 第三者クッキー段階的廃止、Safari ITP、Firefox ETP）でブラウザ環境では将来的に成立しにくくなっている点に注意。

### 2.2 Back-Channel Logout 1.0

- OP がサーバー間で直接 `backchannel_logout_uri` に **`logout_token`（JWT）** を POST して通知するモデル。ユーザーエージェント非依存。
- `logout_token` の必須クレーム:
  - `iss`, `aud`, `iat`, `jti`, `events`（`{"http://schemas.openid.net/event/backchannel-logout": {}}`）
  - `sub` または `sid` のどちらか必須（両方含めても可）
  - `nonce` は **MUST NOT**（ID Token と取り違え防止）
- `logout_token` は OP の通常 ID Token 署名鍵で署名（RS256 既定）。検証は ID Token と同様に JWKS で行う。
- Discovery: `backchannel_logout_supported`、`backchannel_logout_session_supported`。
- 確実性が高くサードパーティクッキー規制の影響を受けない代わりに、OP → RP のサーバー間通信が必須（リーチャビリティ要件）。

### 2.3 SLO（Single Logout）における立ち位置

- RP-Initiated: 「ログアウト開始」エンドポイント。ユーザー起点。
- Front-Channel: 「OP セッション終了の波及通知」をブラウザ経由で行う方式。
- Back-Channel: 「OP セッション終了の波及通知」をサーバー間で行う方式。
- 上記三者は補完関係。Single Logout を成立させるなら RP-Initiated + Back-Channel の組み合わせが現在のベストプラクティス。

## 3. 参照資料

- OpenID Connect Front-Channel Logout 1.0: https://openid.net/specs/openid-connect-frontchannel-1_0.html
  - §2 Client Registration / §3 OP Logout Function / §4 Logout Request / §5 Discovery
- OpenID Connect Back-Channel Logout 1.0: https://openid.net/specs/openid-connect-backchannel-1_0.html
  - §2.3 Logout Token / §2.4 Logout Token Validation / §2.5 Logout Token Errors / §4 Discovery
- OpenID Connect Session Management 1.0: https://openid.net/specs/openid-connect-session-1_0.html
- 関連: `study-material/ext-rp-initiated-logout.md`（ログアウト要求の入口側）

## 4. 現在の実装確認

- **ログアウト関連は皆無**（`ext-rp-initiated-logout.md` の現状確認と一致）。
- 流用可能な既存資産:
  - `packages/core/src/id-token.ts` の ID Token 生成パスは `logout_token`（JWT）にほぼ転用可能。`nonce` を含めない／`events` クレームを追加するだけで、JOSE 部分は再利用できる。
  - `packages/core/src/jwks.ts` / `packages/core/src/signing-key.ts` の鍵管理は `logout_token` 署名にもそのまま使える。
  - `SessionResolver` の `sid` 概念は持っていない。Back-Channel Logout の `sid` 連動には **「OP セッション ID → 関連 ID Token の `sid` クレーム」のヒモづけ**が新規必要。

## 5. 現在の実装との差分

- **満たしていること**: JWT 署名と JWKS 配布の基盤が整っているため、`logout_token` の生成自体は core ヘルパー追加で実現できる。
- **不足している可能性があること**
  - クライアントメタデータの拡張（`frontchannel_logout_uri` / `backchannel_logout_uri` と `*_session_required`）。`ClientInfo` には現在 `redirectUris` 系しか無い。
  - ID Token の `sid` クレーム未発行。Back-Channel で `sid` を使うなら ID Token 発行時に `sid` を埋め、Session Store にも保持する必要がある。
  - `logout_token` 生成ヘルパー（core）。
  - Front-Channel iframe レンダリング（CLI テンプレート責務）。HTML の動的生成は core に置かず、テンプレート側で扱うのが筋。
  - Back-Channel の RP への POST（`application/jwt` ボディ、レスポンス 200/204）と、失敗時の再試行ポリシー。
  - Discovery メタデータ追加（`frontchannel_logout_supported` 等）。
- **セキュリティ観点**
  - `logout_token` は **`nonce` クレーム禁止**。ID Token と区別するため、検証側ライブラリの取り扱い差を理解すること。
  - `logout_token` の `aud` は通知先 RP の `client_id` 単体。複数 RP 通知では 1 通知につき 1 JWT を生成。
  - Back-Channel の通知失敗時、OP セッションは「終了済み」とする（RP 側で再 SSO 時に整合）。OP セッションを保持し続けるとセキュリティ的に意味が薄れる。

## 6. 改善・追加を検討する理由

- ログイン中心の PoC ライブラリでも、「ログアウト通知」は SSO シナリオの実証には必須。
- Back-Channel Logout は **サードパーティクッキー規制の流れで Front-Channel の代替**として重要度が上がっている。FAPI 2.0 / 銀行系ガイドラインでも要求が増加傾向。
- ID Token 発行基盤を流用できるため、`logout_token` 単体の実装コストは想定より低い。
- 実装しない場合の制約: シングルログアウト要件を要件定義段階で「不可」と即答するしかなく、PoC ツールとしての価値を毀損する。

## 7. 実装方針の候補

### 方針A（推奨度高・段階導入）: Back-Channel Logout を先行

理由: ブラウザ環境変化に対する将来性、JOSE 基盤の流用性、サーバー間通信のみで完結する単純さ。

- core に `generateLogoutToken({ iss, aud, sub?, sid?, jti, privateKey, keyId })` 純関数を追加（`generateIdToken` の隣に置く）。
- `ClientInfo` に `backchannelLogoutUri?: string` / `backchannelLogoutSessionRequired?: boolean` を任意フィールドで追加（後方互換）。
- セッション ID（`sid`）の発行・保持の I/F を `SessionResolver` に追加（`sid?: string`）。既存利用者は未設定で互換。
- Back-Channel 通知ループは CLI テンプレート責務（POST → 200/204 確認 → 失敗時ログ）。再試行ポリシーは settable。
- Discovery（core builder）に `backchannel_logout_supported: true`、`backchannel_logout_session_supported`。

### 方針B: Front-Channel Logout のみ先行

- HTML iframe レンダリングが必要で、core ではなくテンプレート側のロジック比重が高い。
- サードパーティクッキー規制で将来性が低い。

### 方針C: 両方非対応の明文化

- 当面 RP-Initiated のみ（ext-rp-initiated-logout.md 方針A）で運用、Front/Back-Channel はロードマップに据置。

### 方針D（最大スコープ）: RP-Initiated + Back-Channel + Front-Channel すべて実装

- 規模大。リリース直前ではなく v1.x で検討。

## 8. タスク案

- [ ] 方針A/B/C/D を選択する（ユーザー判断）。`ext-rp-initiated-logout.md` の方針選択と整合させること
- [ ] 方針A を選ぶ場合: `logout_token` 生成・検証ペアのテストを先行作成（`events` クレーム形式、`nonce` MUST NOT、`sub`/`sid` のどちらか必須、`aud` 単体）
- [ ] `ClientInfo` に Back-Channel 用フィールド追加（optional）
- [ ] `SessionResolver` に `sid` を追加（optional フィールド、生成は実装者責務）
- [ ] ID Token 発行パスで Session の `sid` を `sid` クレームに反映する経路を用意
- [ ] core: `generateLogoutToken` ヘルパー
- [ ] CLI テンプレート: end_session 内から `backchannelLogoutUri` を持つクライアントへ並列 POST
- [ ] Discovery メタデータ追加
- [ ] 完了条件: core / cli テストパス、Back-Channel 通知が `application/jwt` で POST されることを CLI 生成テストで検証
