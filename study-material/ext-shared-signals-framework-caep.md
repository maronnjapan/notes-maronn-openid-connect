# 拡張: Shared Signals Framework (SSF) 1.0 / CAEP / RISC によるセキュリティイベント共有

## ステータス

🟢 拡張機能 / 検討段階（このファイル単体ではタスク化しない）

## 1. このトピックで確認したいこと

OP（Authorization Server / IdP）は、セッション失効・認証情報変更・アカウント無効化・リスク検知といった
**セキュリティ関連イベント**を内部で把握している。しかし現状、それらは「次にトークン検証された時に弾く」
（`revocation.ts`、`subject-wide-token-invalidation-on-credential-change.md`）という **pull / 受動的** な伝播に留まっている。

**Shared Signals Framework (SSF) 1.0**（OpenID Foundation）は、OP が **Transmitter** となり、これらのイベントを
署名付き JWT（Security Event Token, SET）として **能動的（push / poll）に Receiver（RP・リソースサーバー）へ配信する**
標準化されたメカニズムを定義する。**CAEP**（Continuous Access Evaluation Profile）と **RISC**（Risk Incident Sharing
and Coordination）は、その上で「どんなイベント種別を、どんなペイロードで送るか」を規定するプロファイルである。

このファイルで確認したいのは以下:

- SSF / CAEP / RISC が標準化している「OP からのセキュリティイベント外部配信」の要件
- 本リポジトリが既に持つ内部イベント（トークン失効・credential 変更）を、標準形式で外部へ伝播できるか
- Basic OP の必須要件ではない（別認証プロファイル）が、Speed / Fidelity / Security 軸でどこまで価値があるか
- 既存の logout 系・失効系トピックと **何が違い、何を新規に必要とするか**

> 注意（重複回避）: ブラウザ/サーバー間で「ログアウト」を伝播する仕組みは
> `study-material/ext-backchannel-logout-oidc.md`（Back-Channel Logout）と
> `study-material/ext-channel-logout-notifications.md`（Front/Back-Channel 比較）で既に扱っている。
> SSF/CAEP は **「ログアウト」に限定されない継続的セキュリティイベント（リスク・credential 変更・assurance 変化）を、
> ストリーム管理 API を介して継続配信する**点が本質的に異なる。本ファイルではその差分に絞る。

## 2. 関連する仕様・基準

共通仕様の索引は `study-material/basic-op-requirement-traceability.md` を参照。
SET（Security Event Token）の JWT 構造・署名は本リポジトリの ID Token / logout_token と共通基盤
（`signing-key.ts` / `crypto-utils.ts`）を再利用できるため、JWT 署名の一般説明は繰り返さない。

本トピック固有のポイント:

- **Shared Signals Framework (SSF) 1.0**（旧称 Shared Signals and Events / SSE）
  - **役割**: **Transmitter**（イベント送信側 = OP）と **Receiver**（受信側 = RP / リソースサーバー）。
  - **Security Event Token (SET)** = RFC 8417 の JWT。`events` クレーム（イベント種別 URI → ペイロードのマップ）に
    1 つ以上のイベントを格納し、`iss` / `iat` / `jti` / `aud` と **Subject Identifier** を含む。
  - **Stream（ストリーム）**: Transmitter と Receiver の間の論理的な配信チャネル。**Stream Management API**
    （create / read / update / delete、subjects の add / remove、verification）で構成・運用する。
  - **配信方式 2 種**:
    - **Push**（RFC 8935: *Push-Based SET Delivery over HTTP*）: Transmitter が Receiver のエンドポイントへ SET を POST。
    - **Poll**（RFC 8936: *Poll-Based SET Delivery*）: Receiver が Transmitter のエンドポイントを定期取得し ACK を返す。
  - **Transmitter Configuration Metadata**: `/.well-known/ssf-configuration`（または OAuth AS Metadata の
    `ssf_configuration` 指定）で、`issuer` / `jwks_uri` / `configuration_endpoint` / `status_endpoint` /
    `add_subject_endpoint` / `remove_subject_endpoint` / `verification_endpoint` / 対応 delivery 方式 /
    `events_supported`（配信可能イベント URI 群）などを公開する。
  - **Subject Identifier**: RFC 9493 *Subject Identifiers for SETs*。`email` / `phone_number` / `iss_sub` /
    `opaque` / `uri` / `aud` などの形式で「誰についてのイベントか」を表現する。OIDC の `sub`（`iss_sub` 形式）と接続できる。
- **CAEP (Continuous Access Evaluation Profile) 1.0**: SSF を「継続的アクセス評価」向けに具体化したイベントプロファイル。
  主なイベント種別 URI（`https://schemas.openid.net/secevent/caep/event-type/...`）:
  - `session-revoked`（セッション失効。Back-Channel Logout の汎化。リスクや管理者操作による失効も表現）
  - `token-claims-change`（claim 値の変化。例: ロール剥奪）
  - `credential-change`（認証情報の追加/更新/失効）
  - `assurance-level-change`（認証保証レベルの変化）
  - `device-compliance-change`（デバイスのコンプライアンス状態変化）
  - 各イベントは `event_timestamp`、`initiating_entity`、`reason_admin` / `reason_user` 等のサブクレームを持てる。
- **RISC (Risk Incident Sharing and Coordination) Profile 1.0**: アカウントレベルのセキュリティイベントプロファイル。
  主なイベント種別 URI（`https://schemas.openid.net/secevent/risc/event-type/...`）:
  - `account-credential-change-required` / `account-disabled` / `account-enabled` / `account-purged`
  - `identifier-changed` / `identifier-recycled`
  - `credential-compromise`
  - `opt-in` / `opt-out-initiated` / `opt-out-cancelled` / `opt-out-effective`
  - `recovery-activated` / `recovery-information-changed`
- **Basic OP との関係**: SSF / CAEP / RISC は **Basic OP 認証プロファイルの必須要件ではない**。OpenID Foundation は
  SSF 向けに別途 conformance / 認証を提供している。したがって本リポジトリでは **拡張機能**として位置づける。

## 3. 参照資料

- OpenID Shared Signals Framework Specification 1.0（OpenID Foundation）:
  https://openid.net/specs/openid-sharedsignals-framework-1_0.html
  - Transmitter / Receiver の役割、Stream Management API、Configuration Metadata、Push/Poll、Subject Identifiers の参照。
- OpenID Continuous Access Evaluation Profile (CAEP) 1.0:
  https://openid.net/specs/openid-caep-1_0.html
  - `session-revoked` / `credential-change` / `token-claims-change` / `assurance-level-change` のイベント定義。
- OpenID RISC Profile 1.0:
  https://openid.net/specs/openid-risc-profile-specification-1_0.html
  - アカウントレベルイベント（`account-disabled`、`credential-compromise` 等）の定義。
- RFC 8417 *Security Event Token (SET)*: https://www.rfc-editor.org/rfc/rfc8417 — SET の JWT 構造、`events` クレーム。
- RFC 8935 *Push-Based SET Delivery over HTTP*: https://www.rfc-editor.org/rfc/rfc8935 — push 配信時の HTTP セマンティクス。
- RFC 8936 *Poll-Based SET Delivery*: https://www.rfc-editor.org/rfc/rfc8936 — poll 配信・ACK / エラーレスポンス。
- RFC 9493 *Subject Identifiers for Security Event Tokens*: https://www.rfc-editor.org/rfc/rfc9493 — Subject Identifier 形式。
- 本リポジトリ関連ファイル:
  - `study-material/subject-wide-token-invalidation-on-credential-change.md`（credential 変更時の **内部**失効。SSF はその**外部通知**）
  - `study-material/ext-backchannel-logout-oidc.md` / `ext-channel-logout-notifications.md`（logout 限定の通知。CAEP `session-revoked` の部分集合）
  - `study-material/refresh-token-rotation-replay-grace.md`（失効伝播の整合性タイミング）

## 4. 現在の実装確認

SSF / CAEP / RISC に該当する実装は **現状存在しない**（grep: `SSF` / `CAEP` / `RISC` / `shared signal` / `secevent` のヒットなし）。
ただし SSF Transmitter を構築する上で再利用できる基盤は既にある:

- **イベントの発生源（内部状態）**:
  - `packages/core/src/revocation.ts`: `handleRevocationRequest`（RFC 7009）でトークン失効を実行。CAEP `session-revoked` の発火点候補。
  - `study-material/subject-wide-token-invalidation-on-credential-change.md` で整理済みの「credential 変更で subject 配下を一括失効」: CAEP `credential-change` の発火点候補。
  - `packages/core/src/introspection.ts`: `used` / `expiresAt` による active 判定。Receiver 側の検証ロジックとは独立。
- **JWT 署名基盤（SET 生成に再利用可能）**:
  - `packages/core/src/signing-key.ts`（鍵選択・RS256 保証・ローテーション）
  - `packages/core/src/crypto-utils.ts`（JWS 署名、base64url）
  - `packages/core/src/id-token.ts` / logout_token 系で確立済みの JWT 組み立てパターン。
- **公開メタデータ基盤**:
  - `packages/core/src/discovery.ts`（`buildProviderMetadata`）: SSF Configuration Metadata（`/.well-known/ssf-configuration`）を
    並列に追加できる構造。ただし SSF は OIDC Discovery とは **別の well-known** を持つ点に注意。
- **store 抽象**:
  - `study-material/resolver-and-store-contract.md` で整理済みの resolver/store パターン。Stream / subject の永続化に同じ契約を流用できる。

> 結論: **SET の生成・署名・メタデータ公開は既存基盤で十分賄える**。新規に必要なのは
> ①ストリーム管理 API（ステートフル）、②subject 管理、③push/poll の配信ランタイム（非同期・再送）、④内部イベント → SET 変換層。

## 5. 現在の実装との差分

- ✅ **満たしていること**:
  - JWT（SET）署名に必要な鍵管理・RS256 保証・JWKS 公開は既存（`signing-key.ts` / `jwks.ts`）。
  - イベントの「源」となる内部状態（失効・credential 変更）は既に概念整理済み。
- 🔴 **不足していること（新規実装が必要）**:
  - SET 生成層（`events` クレーム、RFC 9493 Subject Identifier、`txn` / `jti` 採番）。
  - Stream Management API（create/read/update/delete、status、add/remove subject、verification）。
  - Push 配信（RFC 8935: Receiver へ POST、4xx/5xx ハンドリング、再送/バックオフ）。
  - Poll 配信（RFC 8936: SET の保留キュー、ACK / `setErrs` 処理、maxEvents / returnImmediately）。
  - Transmitter Configuration Metadata エンドポイント（`/.well-known/ssf-configuration`）。
- 🟡 **仕様確認が必要なこと**:
  - 配信の **at-least-once / 順序保証 / 冪等性**。Receiver は `jti` で重複排除する前提だが、Transmitter 側の再送ポリシーは実装依存。
  - **失効タイミングの整合性**: 内部失効（DB 更新）と SET 配信の間に窓があると、Receiver が古い状態で許可してしまう。
    `study-material/refresh-token-rotation-replay-grace.md` と同種のタイミング論点。
- 🔒 **セキュリティ上の論点**:
  - SET の `aud` を Receiver ごとに正しく絞る（情報漏えい防止）。Subject Identifier の最小化（不要に email を晒さない）。
  - Stream Management API 自体の認可（Receiver の認証、ストリーム所有権チェック）。
  - Push 先 URL の SSRF 対策（登録済み `receiver` エンドポイントのみ許可）。
- 🔗 **相互運用性**: CAEP / RISC のイベント URI とサブクレーム名を **正確に**一致させること（プロファイル準拠が Receiver 互換性の鍵）。
- ⚠️ **Basic OP 観点**: 必須要件ではない。Basic OP 認証取得には不要であり、**コア機能の安定リリース後の拡張**として扱うべき。

## 6. 改善・追加を検討する理由

- **なぜ価値があるか**: 現状のトークン失効は「次回トークン検証まで効かない」遅延型である。アクセストークンの寿命が長いほど、
  失効から実遮断までの窓が広がる。SSF/CAEP は **失効・リスクイベントを即時に Receiver へ push** でき、Zero Trust /
  Continuous Access Evaluation を標準形式で実現する。これは `subject-wide-token-invalidation` の「実効性」を補完する。
- **Basic OP として必要か / 拡張か**: **拡張機能**。Basic OP の必須要件ではない（別認証プロファイル）。
  本リポジトリのコンセプト「最新の OIDC/OAuth 仕様を最速で・忠実に検証できる」に **強く合致**する一方、
  リリース方針（主要フロー 7〜8 割が動いてから拡張を継ぎ足す）に照らすと **優先度は後段**。
- **導入しやすさ / しにくさ**:
  - しやすい点: SET の署名・JWKS・メタデータ公開は既存基盤の流用で済む。Web 標準 fetch で push 配信が書ける（Portability 軸に合致）。
  - しにくい点: Stream / subject の **ステートフル管理**と、push の **非同期・再送・障害復旧**はコアの「ステートレス純粋関数」設計と毛色が異なる。
    sample（実検証）側の責務に寄せる設計判断が要る。
- **既存実装との接続**: `revocation.ts` の失効処理・`subject-wide-token-invalidation` の credential 変更処理に
  **イベントフック**を 1 本足し、そこから SET 生成 → 配信層を呼ぶ形にすると疎結合に組み込める。
- **利用者メリット**: PoC 開発者が「失効イベントの即時伝播（CAEP）」「アカウント侵害共有（RISC）」を、
  IdaaS に移行せずに本ライブラリ上で検証できる。
- **実装しない場合の制約/リスク**: 失効の即時伝播ができず、長寿命アクセストークン運用時のリスク窓が残る。
  また「最新仕様への追随」という差別化軸で、SSF 対応 IdaaS（Okta / Google 等）に対する検証ブリッジとしての価値を取りこぼす。

## 7. 実装方針の候補

> 最終判断は人間が行う。以下は判断材料の整理。

- **方針A（Transmitter 最小: SET 生成 + Push のみ）**
  - `createSecurityEventToken(...)`（SET 署名）＋ `deliverViaPush(receiverEndpoint, set)` のみを core に追加。
  - Stream Management API は実装せず、配信先・subject は利用者が設定で固定する「静的ストリーム」前提。
  - 長所: 最小で CAEP `session-revoked` / `credential-change` の push を試せる。コアのステートレス性を保ちやすい。
  - 短所: SSF の Stream Management / Poll / verification を満たさないため **SSF 準拠ではない**（PoC 止まり）。
- **方針B（SSF Transmitter 準拠: Stream Management + Push/Poll）**
  - Stream Management API・Configuration Metadata・Push/Poll・verification をフル実装。
  - ストリーム/subject の永続化は `resolver-and-store-contract.md` の store 契約に従ったインターフェースで抽象化。
  - 長所: SSF / CAEP / RISC 準拠（Fidelity 軸・将来の SSF conformance 取得に道）。
  - 短所: 実装量が大きく、非同期配信・再送・障害復旧の運用責務が増える。
- **方針C（イベント発火フックのみ先行）**
  - core 側は `revocation` / credential 変更時に **イベントを emit するフック**（コールバック）だけを定義し、
    SET 生成・配信は sample / 利用者実装に委ねる。
  - 長所: コア最小・段階導入。Receiver 互換検証を sample で先に回せる。
  - 短所: 標準準拠の本体は利用者任せになり、「忠実さ（Fidelity）」のシグナルにはなりにくい。
- **プロファイル範囲の選択**: まず **CAEP `session-revoked` / `credential-change`** に限定し、RISC・assurance-level 等は後続。
- **配信方式の選択**: 検証用途では **Poll を先に**実装する方が Receiver 側の HTTP 受け口不要で試しやすい、という判断もある（要検討）。

## 8. タスク案

> いずれも「方針未決定」のため現時点では `tasks/` 化しない。方針確定後に切り出す。

- [ ] `/tech-research` で SSF 1.0 / CAEP 1.0 / RISC 1.0 の **最終版ステータスとイベント URI / サブクレーム名**を一次情報で確定する
      （プロファイルは改訂が入るため、実装前に URI 文字列を固定すること）。
- [ ] `/design-discussion` で「core をどこまでステートフルにするか（方針A/B/C）」を Codex と協議し確定設計を記録する。
- [ ] SET 生成のテスト先行実装（`events` クレーム構造、RFC 9493 Subject Identifier、`jti` 一意性、署名 alg）。
- [ ] CAEP `session-revoked` を `revocation.ts` の失効処理にフックする最小経路の設計（疎結合フック）。
- [ ] 配信タイミングと内部失効の整合（失効 → SET 配信の窓）を `refresh-token-rotation-replay-grace.md` の知見と突き合わせて整理。
- [ ] Stream Management API / Configuration Metadata を実装する場合の認可・SSRF 対策の要件整理。

## 9. メモ（不明点・前提）

- 本ファイルの SET / イベント URI の記述は一般に知られた SSF/CAEP/RISC の構造に基づくが、**プロファイルの版差**で
  イベント URI やサブクレーム名が変わりうる。実装着手前に §8 の `/tech-research` タスクで一次情報を再確認すること（推測と事実を混ぜない方針）。
- 本リポジトリは OP = **Transmitter** 側を想定。Receiver（RP 側の SET 検証）は利用者 RP の責務であり、core の主対象外。
</content>
</invoke>
