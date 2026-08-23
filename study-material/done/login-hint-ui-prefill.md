# `login_hint` のログイン UI 連携（受理・永続化済みだが画面に出ていない）

## ステータス

🟡 Medium / 未着手

## 1. このトピックで確認したいこと

`login_hint`（認可リクエストのヒントパラメータ）は、core では受理され `AuthTransaction` に永続化されるが、
CLI 生成プロバイダのログイン画面に**一切伝わっていない**（write-only で死蔵）。
OIDC Core §3.1.2.1 が「ログインフォームに `login_hint` の値を投入することが RECOMMENDED」としている点に対し、
現状の「受理して保存するだけで UI 反映なし」が妥当か、またどう接続すべきかを確認する。

> 関連既存ファイル：
> - `study-material/done/ui-claims-locales-auth-transaction-handling.md` は `ui_locales` / `claims_locales` の
>   AuthTransaction 永続化を扱う。`login_hint` の UI 連携は扱っていない。
> - `study-material/current-implementation-documentation-backlog.md` は `loginHint` を
>   「ドキュメント未整備フィールド」として列挙しているのみで、UI 連携の不足には踏み込んでいない。
> - `study-material/basic-op-requirements-baseline.md` は `login_hint` を「エラーにせず受理」のレベルでしか要求していない。
> 本ファイルは **UI へのプレフィル動線の欠落**という固有の差分のみを扱う。

## 2. 関連する仕様・基準

- **OpenID Connect Core 1.0 §3.1.2.1（Authentication Request）— `login_hint`**:
  > Hint to the Authorization Server about the login identifier the End-User might use to log in
  > (if necessary). This hint can be used by an RP if it first asks the End-User for their e-mail
  > address (or other identifier) and then wants to pass that value as a hint to the discovered
  > authorization service. ... **it is RECOMMENDED that the OP populate the login form with this value.**
  - 任意（OPTIONAL）パラメータ。SHOULD/MUST ではなく **RECOMMENDED** な UI 反映。
  - 値の形式は OP 依存（メール、電話番号、独自識別子など）。OP は信頼せず、あくまで「ヒント」。

## 3. 参照資料

- OpenID Connect Core 1.0 §3.1.2.1:
  https://openid.net/specs/openid-connect-core-1_0.html#AuthRequest
  - `login_hint` の定義と「ログインフォームへ投入することが RECOMMENDED」の記述

## 4. 現在の実装確認

- 受理: `packages/core/src/authorization-request.ts:57`（`login_hint?: string` 入力型）、
  `:254`（`loginHint?: string` 出力型）、`:898`（`const loginHint = effective.login_hint;`）、
  `:934`（`ValidatedAuthorizationRequest.loginHint` へ格納）、`:968`（`REQUEST_OBJECT_OVERRIDE_KEYS` に含む）。
- 永続化: `packages/core/src/auth-transaction.ts:116`（`AuthTransaction.loginHint?: string`）、
  `:234-235`（`validatedRequest.loginHint` を transaction に複写）。
- UI 連携: **欠落**。各 sample の `LoginPageParams` に `loginHint` フィールドが無い:
  - `samples/express/src/oidc-provider/views.ts:16`（`LoginPageParams` 定義）
  - `samples/express/src/oidc-provider/routes/login.ts:34`（`views.loginPage({ transactionId, csrfToken })` 呼び出し — `loginHint` を渡していない）
  - hono / fastify / nextjs も同一構造（`views.ts:16` / `login.ts:34`）。生成元は `packages/cli/src/frameworks/*`。
- 結果: `login_hint` は transaction には載るが、ログインフォームの username 入力欄に反映されない。

## 5. 現在の実装との差分

- **満たしていること**
  - `login_hint` を不正値として弾かず受理（Basic OP 最低限）。
  - transaction に保持しているため、UI 連携の「材料」は core 側に揃っている。
- **不足している可能性があること**
  - §3.1.2.1 の RECOMMENDED（ログインフォームへの投入）が未実装。値が UI に届かない。
  - 利用者が「`login_hint` を使った検証（メール事前入力など）」をこのライブラリで再現できない。
- **相互運用性**
  - `login_hint` を活用する RP（メールアドレス事前収集型のフロー）の挙動を検証できない。
- **Basic OP として確認すべきこと**
  - Basic OP 認定の必須テストではない（RECOMMENDED 止まり）。ただし Fidelity の観点で「受理だけ」は説明責任上弱い。

## 6. 改善・追加を検討する理由

- **Fidelity**: 「受理するが意味が無い」状態は仕様忠実性の穴。RECOMMENDED とはいえ、
  transaction まで保持済みなのに UI に出さないのは設計の中途半端さが残る。
- **導入しやすさ**: 既に transaction へ `loginHint` が載っているため、
  `LoginPageParams` への 1 フィールド追加 ＋ テンプレートの `value="..."` 反映で完結し、影響範囲が狭い。
- **既存実装との接続**: `ui_locales` 永続化（done）と同じ「transaction → 生成ルート → views」の動線に素直に乗る。
- **利用者メリット**: PoC で「RP がメールを事前取得 → OP のログイン画面に自動入力」という典型フローを再現できる。
- **実装しない場合のリスク**: `login_hint` 系のユースケース検証ができない。値が死蔵で、
  「なぜ保持しているのに使わないのか」という設計上の疑問が残る。

## 7. 実装方針の候補

判断材料の整理（最終判断は人間）。

### 方針A（推奨・最小）: ログインフォームへプレフィル

- 生成ルート（`login.ts`）で transaction から `loginHint` を取り出し、`views.loginPage({ ..., loginHint })` へ渡す。
- `LoginPageParams` に `loginHint?: string` を追加し、`defaultLoginPage` の username 入力欄に
  `value="${escapeHtml(loginHint ?? '')}"` を反映。
- **エスケープ必須**（`login_hint` は信頼できない外部入力。XSS 対策で HTML エスケープ）。
- OP は値を信頼せず、あくまで初期表示のみ（実認証はユーザー入力で確定）。

### 方針B（割り切り＋明文化）

- 「`login_hint` は受理・保持するが UI 反映は利用者責務」と型 doc / 生成コードのコメントに明記し、
  プレフィルは行わない。RECOMMENDED に従わない選択を文書で正当化する。

## 8. タスク案

- [ ] 方針A/B を選択（ユーザー判断）
- [ ]（方針A）CLI テンプレートの `LoginPageParams` に `loginHint?: string` を追加するテストを先行作成
- [ ]（方針A）生成 `login.ts` で transaction の `loginHint` を `loginPage` に渡す
- [ ]（方針A）`defaultLoginPage` の username 欄へ **HTML エスケープした上で** `value` 反映
- [ ] XSS 回帰テスト: `login_hint=<script>` 等が属性値として安全にエスケープされること
- [ ] 4 フレームワーク（express/hono/fastify/nextjs）で挙動を統一
- [ ] 完了条件: `pnpm --filter @maronn-openid-connect/cli test` がパス
