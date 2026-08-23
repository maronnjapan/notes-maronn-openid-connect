# 拡張: Cross-Device Flows Security BCP（クロスデバイス・フローのセキュリティ）

## ステータス

🟠 セキュリティ（拡張フローの前提条件）/ 未着手

## 1. このトピックで確認したいこと

Device Authorization Grant（RFC 8628）や CIBA のような**クロスデバイス・フロー**
（あるデバイスで開始し、別のデバイスで認可する流れ）に対する
**Cross-Device Consent Phishing（クロスデバイス同意フィッシング）**攻撃と、その緩和策
（`draft-ietf-oauth-cross-device-security`）を本リポジトリがどう扱うべきかを確認する。

確認したい中心点は次の 3 つ。

1. 本リポジトリで既に study-material 化済みの**クロスデバイス系拡張**
   （`ext-device-authorization-grant-rfc8628.md` / `ext-ciba.md`）に、
   この BCP が定める**攻撃モデルと緩和策**が反映されているか（現状は未反映）。
2. これらの拡張を**将来実装する場合の前提条件（セキュリティ・ゲート）**として、
   どの緩和策を必須・推奨にすべきか。
3. クロスデバイス・フローを**そもそも提供しない**場合でも、ドキュメントとして
   「なぜ危険か」「実装するなら何が必須か」を残す価値があるか。

### 既存の関連ファイルとの差分（重複回避）

- `study-material/ext-device-authorization-grant-rfc8628.md`:
  Device Authorization Grant（`device_authorization_endpoint`、`device_code` / `user_code`、
  polling）の**機能**を扱う。
  → 本ファイルは同フローに対する**攻撃モデルと緩和策（BCP）**という別軸を扱う。機能仕様は重複させない。
- `study-material/ext-ciba.md`:
  CIBA（Client-Initiated Backchannel Authentication）の**機能**を扱う。
  → 本ファイルは CIBA を含むクロスデバイス・フロー全般の**セキュリティ BCP**に絞る。
- `study-material/done/oauth-security-bcp-rfc9700.md` /
  `study-material/rate-limiting-and-brute-force.md`:
  OAuth 全般のセキュリティ BCP（RFC 9700）と、エンドポイント全般のレート制限を扱う。
  → 本ファイルは**クロスデバイス特有の脅威（同意フィッシング）**と、それに固有の緩和
  （`user_code` の短命化・推測不能化・近接性確認等）に限定する。一般的なレート制限の説明は重複させず、
  「クロスデバイス文脈での `user_code` ブルートフォース対策」という差分のみ扱う。

## 2. 関連する仕様・基準

> ⚠️ 注記: 本環境からは datatracker.ietf.org / ietf.org への直接 HTTP 取得が 403 で不可だった
> （既存ファイル群と同じ制約）。以下は IETF の文書検索結果（公式ドラフトの要約）と記載者の知識に基づく。
> 章番号・MUST/SHOULD の逐語は §8 のタスクで一次資料の再確認を必須とする。

### 2.1 Cross-Device Flows: Security Best Current Practice（`draft-ietf-oauth-cross-device-security`）

- **目的（事実）**: クロスデバイス・フローに対する
  **Cross-Device Consent Phishing** と **Cross-Device Session Phishing** を
  実装者が防御できるようにするガイダンス。IETF で **BCP** として策定中
  （検索時点の最新は `-16` 系。本ファイルは draft であることを前提に扱う）。
- **ガイダンスの 3 本柱（事実）**:
  1. 影響を受けるプロトコルに対する**実践的な緩和策**。
  2. 影響を受けにくいプロトコルを選ぶための**プロトコル選択ガイダンス**。
  3. 脆弱なプロトコルの**形式的解析（formal analysis）の結果**。
- **登場ロール（用語）**:
  - **Consumption Device（利用デバイス）**: フローを開始する、入力制約のあるデバイス
    （例: スマート TV、CLI、IoT）。Device Grant の「device」側。
  - **Authorization Device（認可デバイス）**: ユーザが実際に認証・同意を行うデバイス
    （例: スマホ）。`verification_uri` / `user_code` を入力したり QR を読む側。
- **中核となる攻撃（Cross-Device Consent Phishing、事実ベースの要約）**:
  攻撃者が**自分の Consumption Device でフローを開始**し、得られた `user_code` / QR を
  **被害者に送りつけて（メール・SMS・QR 偽装等）認可させる**。被害者が自分の正規アカウントで
  「同意」してしまうと、**攻撃者側のデバイスにトークンが発行される**（同意の取り違え）。
  デバイスフローでは「コードを入力した端末」と「認可した端末」が物理的に異なるため、
  ユーザは「いま自分の目の前にない端末に権限を渡している」ことに気づきにくい。
- **緩和策（検索結果＋知識ベースの要約。逐語は §8 で要確認）**:
  - **近接性の確立（proximity）**: Consumption Device と Authorization Device の
    **物理的近接**を前提とするフロー（QR をその場で読む等）は、
    遠隔に大量配布する攻撃に強い。ただし VPN や位置偽装で回避されうる点に注意。
  - **短命なコード（short-lived codes）**: QR / `user_code` を短命にすると、
    攻撃者が窃取したコードを悪用できる時間窓が縮み、攻撃コストが上がる。
  - **推測不能・一回限りの `user_code`**: ブルートフォース・推測を防ぐ。
  - **レート制限・異常検知**: 同意エンドポイント／polling に対する試行回数制限と監視。
  - **同意画面のコンテキスト提示**: 「どのアプリ／どのデバイスに何を許可するのか」を
    ユーザに明示し、取り違えを気づきやすくする。
  - **影響を受けにくいプロトコルの選択**: 可能なら近接性を強制するフローを選ぶ
    （プロトコル選択ガイダンス）。
  - **多層防御（事実）**: 「**1 つ以上の緩和策を適用することが RECOMMENDED**」。
    各緩和策は「攻撃の開始を難しくする／進行中の攻撃を妨げる／成功時の影響を減らす」層を追加する。

### 2.2 ベースとなるクロスデバイス・フロー仕様

機能仕様そのものは隣接ファイルに委ね、ここでは重複させない。

- **RFC 8628 OAuth 2.0 Device Authorization Grant**:
  詳細は `study-material/ext-device-authorization-grant-rfc8628.md`。
- **CIBA（OpenID Connect Client-Initiated Backchannel Authentication）**:
  詳細は `study-material/ext-ciba.md`。

## 3. 参照資料

- Cross-Device Flows: Security Best Current Practice
  （`draft-ietf-oauth-cross-device-security`、検索時点最新 `-16`）:
  https://datatracker.ietf.org/doc/draft-ietf-oauth-cross-device-security/
  - 本ファイルの根拠箇所: 「Cross-Device Consent Phishing / Session Phishing を防ぐガイダンス」
    「3 本柱（実践的緩和・プロトコル選択・形式的解析）」「proximity / short-lived codes /
    多層防御（1 つ以上の緩和を適用するのが RECOMMENDED）」。
- HTML ミラー（403 のため未取得、要再確認）:
  https://www.ietf.org/archive/id/draft-ietf-oauth-cross-device-security-04.html
- RFC 8628 OAuth 2.0 Device Authorization Grant:
  https://datatracker.ietf.org/doc/html/rfc8628
- 隣接トピック（重複回避のための参照先）:
  - `study-material/ext-device-authorization-grant-rfc8628.md`
  - `study-material/ext-ciba.md`
  - `study-material/done/oauth-security-bcp-rfc9700.md`
  - `study-material/rate-limiting-and-brute-force.md`

## 4. 現在の実装確認

- **クロスデバイス・フローは未実装**:
  `packages/core/src` には `device_authorization_endpoint` / `device_code` / `user_code` の処理も、
  CIBA の backchannel 処理も存在しない（いずれも study-material 段階）。
  → したがって本 BCP の攻撃面は**現時点では存在しない**（フローを提供していないため）。
- **既存の関連基盤**:
  - レート制限・ブルートフォース対策の指針: `study-material/rate-limiting-and-brute-force.md`。
  - ログイン失敗試行のトラッキング: `auth-transaction.ts`（`handleLoginFailure`、既定 5 回）。
    → 将来 `user_code` 検証を実装する場合の試行回数制限の足がかりになる。
  - 短命トークン／コードの TTL・失効の素地: `store-expired-entry-eviction-and-ttl.md`、
    `authorization-code.ts`（コードの TTL 管理）。
- **Discovery**: `device_authorization_endpoint` / `backchannel_authentication_endpoint` は広告していない
  （フロー未提供と整合）。

## 5. 現在の実装との差分

満たしていること:

- 🟢 クロスデバイス・フローを提供していないため、**現状この攻撃の脆弱性は無い**（攻撃面ゼロ）。
- 🟢 将来実装に流用できる基盤（試行回数制限・TTL・失効）が部分的に存在する。

不足している可能性があること:

- 🔴 Device Grant / CIBA を**実装する場合**、本 BCP の緩和策を**設計段階の前提条件**として
  組み込む枠組みが無い（現状の study-material はフロー機能のみで、攻撃モデルが欠落）。
- 🟡 隣接ファイル（`ext-device-authorization-grant-rfc8628.md` / `ext-ciba.md`）に
  「Cross-Device Consent Phishing への注意」「最低限適用すべき緩和策」への**相互参照が無い**。

セキュリティ上、改善（検討）した方がよいこと:

- 🟠 クロスデバイス系を実装する際は、**「1 つ以上の緩和策の適用（RECOMMENDED）」**を
  ライブラリの既定・テンプレートに反映すべき（短命 `user_code`・推測不能・レート制限を既定にする等）。
- 🟠 同意画面に「どのアプリ／どのデバイスに何を許可するか」を必ず提示する設計を、
  生成テンプレートのデフォルトにすると、取り違えに気づきやすくなる。

相互運用性 / Basic OP 観点:

- 🟢 **Basic OP 必須ではない**（クロスデバイス・フロー自体が認定プロファイル外）。
  Basic OP 定義は `study-material/basic-op-requirement-traceability.md` を参照。
- 🟡 ただし「最新仕様を忠実に・安全に検証できる」という本ライブラリのコンセプト上、
  クロスデバイス拡張を出すなら**この BCP 準拠をセットで示す**ことが信頼性シグナルになる。

## 6. 改善・追加を検討する理由

- **なぜ価値があるか**:
  - Device Grant / CIBA は study-material 化済みで、**将来実装の候補**。実装に踏み切る前に
    「この BCP の緩和策を前提にする」と決めておけば、**安全でないクロスデバイス実装を最初から避けられる**。
  - 近年、Microsoft 365 等で **device code phishing** の実被害が報告されており
    （参考: Help Net Security 2025-12 の報道）、攻撃が理論上の話ではない。
- **Basic OP として必要か / 拡張か**: 拡張フロー（Device/CIBA）の**セキュリティ前提**。Basic OP 必須ではない。
- **導入しやすいか / しにくいか**:
  - 🟢 **ドキュメント・設計ガイドとしては今すぐ導入しやすい**（本ファイル自体がそれ）。
  - 🟡 **実装としては**、Device/CIBA 本体が未実装のため、本 BCP 単体では着手対象が無い
    （フロー実装と同時に効いてくる）。
- **既存実装との接続**:
  - `auth-transaction.ts` の試行回数制限、`authorization-code.ts` / store の TTL・失効を
    `user_code` 検証・短命化に流用できる。
  - 同意画面テンプレート（CLI 生成）に「アプリ名・デバイス・要求 scope」の明示を組み込める。
- **利用者・開発者・運用者のメリット**:
  - 利用者（RP 開発者）: クロスデバイス・フローを検証する際、安全な既定で試せる。
  - 運用者: 同意フィッシングという現実的な脅威への耐性を、移行前に確認できる。
- **実装しない場合のリスク / 制約**:
  - 将来 Device/CIBA を「機能だけ」実装すると、緩和策の検討漏れで**同意フィッシングに脆弱な OP**を
    利用者へ配布してしまう恐れがある。本ファイルはその予防線。

## 7. 実装方針の候補

> 最終判断は人間が行う。Device/CIBA を実装するか自体が方針判断であり、本 BCP はその前提条件として扱う。

### 方針A（ドキュメント・設計ガイドとして確定／実装は据え置き）

- 本ファイルを「クロスデバイス拡張を実装する際のセキュリティ要件チェックリスト」として確定する。
- `ext-device-authorization-grant-rfc8628.md` / `ext-ciba.md` に
  「実装時は本 BCP の緩和策を前提とする」旨の相互参照を 1 行ずつ追記する。
- メリット: コスト極小で、将来の不安全実装を予防。デメリット: いますぐの機能追加は無い。

### 方針B（Device Grant 実装時に緩和策を必須デフォルトとして同梱）

- Device Grant を実装する段階で、以下を**既定 ON / 設定可能**にする:
  - 短命・推測不能・一回限りの `user_code`（TTL は既存 store 機構を流用）。
  - `user_code` 検証・polling のレート制限（`auth-transaction.ts` の試行制限を拡張）。
  - 同意画面に「アプリ・デバイス・scope」の明示（CLI テンプレートのデフォルト）。
- メリット: 安全な既定で配布できる。デメリット: Device Grant 本体の実装が前提。

### 方針C（クロスデバイス・フローは当面非対応と明文化）

- Device/CIBA を当面ロードマップ外とし、ドキュメントで非対応と本 BCP の存在を告知する。
- メリット: 攻撃面を増やさない。デメリット: クロスデバイス検証ニーズに応えられない。

判断材料:

- 「いま手を動かす対象」を最小にしたい → 方針 A（本ファイル確定＋相互参照のみ）。
- Device Grant を近く実装する計画がある → 方針 A を前提に、実装時に方針 B を適用。
- クロスデバイスは当面やらない → 方針 C。

## 8. タスク案

> 本トピックは「将来のクロスデバイス実装の前提」であり、Device/CIBA 本体が未実装のため、
> **現時点で独立して着手できるコード変更は方針 A の相互参照追記のみ**。それ以外は実装と同時に行う。

- [ ] `draft-ietf-oauth-cross-device-security`（最新版）を一次資料で確認し、
      §2 の攻撃モデル（Consent / Session Phishing の区別）と緩和策の章番号・MUST/SHOULD を確定する
- [ ] 方針 A: `ext-device-authorization-grant-rfc8628.md` と `ext-ciba.md` に
      「実装時は本 BCP（`ext-cross-device-flows-security-bcp.md`）の緩和策を前提とする」相互参照を追記する
- [ ] Device Grant / CIBA を実装する判断が出た場合（方針 B）に着手する項目:
  - [ ] `user_code` を短命・推測不能・一回限りにする（TTL は既存 store 機構を流用）
  - [ ] `user_code` 検証・polling のレート制限を `auth-transaction.ts` の試行制限から拡張する
  - [ ] 同意画面テンプレート（CLI 生成）に「アプリ名・デバイス種別・要求 scope」を明示する
  - [ ] 「1 つ以上の緩和策が有効であること」を sample の `conformance.test.ts`（CLI 生成元）で固定する
- [ ] テスト要件（方針 B 着手時）:
  - [ ] 期限切れ `user_code` が拒否される
  - [ ] `user_code` の連続誤入力が一定回数で拒否・スロットリングされる
  - [ ] 同意レスポンスにアプリ・scope・デバイス情報が含まれる
- [ ] 完了条件（方針 A のみ実施時）: 隣接 2 ファイルへの相互参照追記が入り、本ファイルが査読されること
