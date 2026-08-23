# 拡張: OpenID Connect Native SSO for Mobile Apps 1.0

## ステータス

🟢 拡張機能 / 検討段階（方針未決定）

## 1. このトピックで確認したいこと

OpenID Connect **Native SSO for Mobile Apps 1.0** を導入するかを整理する。

これは「**同一デバイス上の、同一ベンダーの複数ネイティブアプリ間**で、ユーザーに再ログインさせずに SSO を実現する」ための仕様。1 つ目のアプリでログインした結果（`device_secret`）を OS のセキュアストレージで共有し、2 つ目のアプリは Token Exchange でトークンを取得する。

本リポジトリには既に 2 つの関連資産がある:

- ブラウザベースの SSO（`tasks/done/p1-generated-provider-browser-session-sso.md`）= **ブラウザ Cookie セッション**での SSO。
- Token Exchange（`study-material/ext-token-exchange-rfc8693.md`）= Native SSO が土台にする grant。

Native SSO はこの中間にある「**ネイティブアプリ間のデバイスローカル SSO**」という別ユースケースを埋める。確認したいのは、その価値と既存資産との接続性。

> 注意: Token Exchange（RFC 8693）の詳細・委譲・ポリシーは `ext-token-exchange-rfc8693.md` に記載済み。ブラウザ Cookie セッション SSO の設計は done タスクに記載済み。本ファイルでは「Native SSO 固有の差分」（`device_secret` / `device_sso` scope / `ds_hash`）に絞る。

## 2. 関連する仕様・基準

共通の仕様索引は `study-material/basic-op-requirement-traceability.md` を参照。本トピック固有のポイントのみ。

### Native SSO 1.0 の要点

1. **`device_sso` scope**:
   - 1 つ目のアプリが認可リクエストに `openid device_sso` を含める。
   - これにより、トークンレスポンスに **`device_secret`** が追加で返る。
2. **`device_secret`**:
   - デバイスにローカルな秘密。OS のセキュアストレージ（iOS Keychain / Android Keystore）で同一ベンダーのアプリ群が共有する。
   - サーバ側は `device_secret` をデバイス × ユーザー認証セッションに束ねて保持する。
3. **ID Token の `ds_hash` クレーム**:
   - `device_secret` のハッシュ（base64url）を ID Token に含め、`device_secret` と ID Token の束縛を検証可能にする。
4. **2 つ目のアプリの SSO（Token Exchange）**:
   - `grant_type=urn:ietf:params:oauth:grant-type:token-exchange`（RFC 8693）を使う。
   - `subject_token` = 1 つ目のアプリの ID Token（`subject_token_type=...:id_token`）。
   - `actor_token` = `device_secret`（`actor_token_type=urn:openid:params:token-type:device-secret`）。
   - `scope` に `device_sso` を含めて、2 つ目のアプリ向けの access/id/refresh token を **再ログインなしに発行**。
   - サーバは「ID Token の `ds_hash` と提示された `device_secret` の一致」「device_secret が有効・未失効」「ユーザーセッションが生存」を検証。

### 既存トピックとの関係（重複回避）

- **Token Exchange 本体**: `ext-token-exchange-rfc8693.md`。Native SSO は **その上の特殊化**（`actor_token`=device_secret の固定パターン）。→ TX の汎用説明は再掲しない。
- **ブラウザ SSO**: `tasks/done/p1-generated-provider-browser-session-sso.md`。Native SSO は **ブラウザ Cookie ではなくデバイスローカル秘密**で SSO する点が本質的に異なる。
- **Native apps の OAuth ベストプラクティス（PKCE / loopback 等）**: `study-material/done/oauth-native-apps-rfc8252.md` / `ext-native-apps-rfc8252.md`。Native SSO はこれを前提に、複数アプリ間の SSO を追加する。

## 3. 参照資料

- OpenID Connect Native SSO for Mobile Apps 1.0: https://openid.net/specs/openid-connect-native-sso-1_0.html
  - 「device_sso scope」「device_secret」「ds_hash」「Token Exchange によるトークン取得」節
- RFC 8693 OAuth 2.0 Token Exchange（土台の grant）: https://www.rfc-editor.org/rfc/rfc8693
- RFC 8252 OAuth 2.0 for Native Apps: https://www.rfc-editor.org/rfc/rfc8252

> 注: Native SSO 仕様は版が更新されうる（token-type URN や claim 名）。着手前に最新版で確認すること（本ファイルは知識時点 2026-01 の整理）。

## 4. 現在の実装確認

- Token Exchange（RFC 8693）は未実装（`ext-token-exchange-rfc8693.md` で検討中）。Native SSO はこれに依存する。
- `device_sso` scope / `device_secret` 発行 / `ds_hash` クレームの実装は無い。
- ID Token 生成（`packages/core/src/id-token.ts` / `token-response.ts`）は `ds_hash` を扱わない。
- セッション resolver（`SessionResolver` 相当）はブラウザ Cookie セッション向けで、デバイスローカル秘密（device_secret）を保持する経路は無い。

## 5. 現在の実装との差分

- 🟢 **Basic OP 要件ではない**: 未対応は仕様違反ではない。
- 🟡 **Token Exchange に強く依存**: Native SSO 単独では着手できず、RFC 8693 の実装が前提。
- 🟡 **新しい資格情報ライフサイクル（device_secret）**: 発行・保存・失効・デバイス束縛という新しいストア責務が増える（resolver 注入で外部化する設計が自然）。
- 🟡 **ID Token への `ds_hash` 追加**: ハッシュ計算と claim 付与（`at_hash` / `c_hash` と同系統。`study-material/done/id-token-at-hash-algorithm-agility.md` のハッシュ算出方針を流用可能）。
- 🟢 **モバイル PoC ユーザーに具体的価値**: 「自社アプリ群でワンタップ SSO を試したい」要件に直接応える。

## 6. 改善・追加を検討する理由

価値:

- **モバイルアプリ群の SSO はブラウザ SSO では代替できない**。ネイティブアプリは Cookie を共有しないため、`device_secret` ベースの仕組みが必要。本リポジトリの SSO 資産（ブラウザ）を補完する。
- **コンセプト適合**: 「自社のマルチアプリ SSO 要件がこの仕様で実現できるか」を試す検証層として有用。
- **Token Exchange への投資を活かせる**: TX を入れるなら、その代表的な実用ユースケースとして Native SSO をデモできる。

Basic OP として必要か / 拡張か:

- **拡張（Tier C 相当）**。Basic OP には不要。モバイル特化の発展機能。

導入しやすさ / しにくさ:

- 🟡 Token Exchange 実装が前提（依存が重い）。
- 🟡 `device_secret` の保存・失効という新ストア責務。
- 🟢 ハッシュ算出（`ds_hash`）と claim 付与は既存 at_hash 実装の延長で済む。
- 🟢 検証ロジックは「TX の actor_token 検証 + セッション生存確認」に整理でき、resolver 注入に乗せやすい。

既存実装との接続:

- ID Token: `id-token.ts` に `ds_hash` 算出・付与。
- Token Exchange ハンドラ（TX 実装時）に `actor_token_type=device-secret` 分岐を追加。
- 新規 `DeviceSecretResolver`（発行・検証・失効）を注入インターフェースとして定義。

実装しない場合のリスク / 制約:

- モバイルのネイティブ SSO PoC は不可。ブラウザ SSO のみの提供に留まる。

## 7. 実装方針の候補

### 方針A（非対応の明文化）

- `RELEASE-v0.x-scope.md` に「v0.x スコープ外、Token Exchange 後続」と記載。

### 方針B（Token Exchange 実装後にセットで導入）

- 先に `ext-token-exchange-rfc8693.md` の方針 B/C を実装。
- その上に Native SSO を追加: `device_sso` scope、`device_secret` 発行、`ds_hash`、`actor_token=device_secret` の TX 分岐、`DeviceSecretResolver`。
- CLI 生成コードにモバイル 2 アプリの SSO サンプルを含める。

### 方針C（最小デモ: 自前 OP 発行 ID Token + device_secret のみ）

- 外部 IdP は考えず、同一 OP が発行した ID Token + device_secret に限定。
- device_secret の失効はユーザーログアウト / セッション失効に連動。
- まず「2 アプリ間ワンタップ SSO」が動く最小デモに集中。

判断材料:

- Token Exchange を入れる計画があるかが最大の分岐。入れるなら Native SSO はその目玉デモになる。
- device_secret の保存はクライアント側（OS セキュアストレージ）の責務が大きく、サーバ側は「発行・検証・失効」に集中できる。

## 8. タスク案

> Token Exchange 依存のため **検討段階に留める**。TX 実装方針が決まってから着手判断するのが適切。

- [ ] 人間が方針 A / B / C を選択する（前提として Token Exchange を入れるかを先に決める）
- [ ] Token Exchange（`ext-token-exchange-rfc8693.md`）の実装が前提条件
- [ ] 方針 B/C 着手時:
  - [ ] `device_sso` scope を認可・トークン発行で受理し、`device_secret` を発行・返却
  - [ ] `DeviceSecretResolver`（発行 / 検証 / 失効 / ユーザー・デバイス束縛）を注入 I/F として定義
  - [ ] ID Token に `ds_hash`（device_secret のハッシュ）を付与（at_hash 実装を流用）
  - [ ] TX ハンドラに `actor_token_type=device-secret` 分岐を追加し、`ds_hash` 一致・device_secret 有効性・セッション生存を検証
  - [ ] セッション/ログアウト失効と device_secret 失効を連動
  - [ ] テスト: 1 アプリ目で device_secret 取得 → 2 アプリ目が再ログインなしで token 取得、改ざん device_secret 拒否、失効後の TX 拒否
