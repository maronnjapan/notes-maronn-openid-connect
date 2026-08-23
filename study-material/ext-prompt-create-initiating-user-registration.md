# 拡張: `prompt=create`（Initiating User Registration via OpenID Connect 1.0）

## ステータス

🟢 拡張機能 / 未着手

## 1. このトピックで確認したいこと

`prompt=create` は **「ログインではなく新規ユーザー登録のフローを優先表示してほしい」** ことを OP に伝えるリクエスト値。OpenID Foundation の **「Initiating User Registration via OpenID Connect 1.0」**（実装者向けドラフト/Implementer's Draft）で定義され、Discovery メタデータと `prompt` パラメータの拡張として標準化が進んでいる。

本リポジトリでは:

- `prompt` は `none / login / consent / select_account` のみサポート（`packages/core/src/authorization-request.ts` および `study-material/prompt-select-account.md`）
- `prompt=create` は受理されず、`invalid_request` 扱いになる可能性が高い（要動作確認）

このファイルは **`prompt=create` を受理・実行するかの判断材料**を整理する。

## 2. 関連する仕様・基準

### 2.1 Initiating User Registration via OpenID Connect 1.0 概要

- OpenID Connect Core 1.0 §3.1.2.1 の `prompt` 値に **`create`** を追加する拡張。
- `create` 値の意味: 「End-User を **新規アカウント作成画面**にルーティングして認可フローを継続せよ。既存セッションがあっても新規登録を優先せよ」。
- 既存セッションがあり、ユーザーが「既にあるアカウントを使う」を選ぶ場合は、`create` を無視してログインフローに切り替えることが許容される（ユーザー UX 優先）。
- 他の `prompt` 値（`login` / `consent` 等）と組み合わせて指定可能（半角スペース区切り）。
- Discovery メタデータ:
  - `prompt_values_supported`（配列）: OP が受理する `prompt` 値を広告。これは `prompt=create` を含めるか否かを RP が事前検知するための仕組み。RFC 8414 とも整合。

### 2.2 OIDC との関係

- `prompt=login`: 強制再認証。`prompt=create` とは目的が異なる（後者は新規登録優先）。
- `prompt=consent`: 同意画面強制。
- `prompt=select_account`: アカウント選択 → `study-material/prompt-select-account.md` で別途追跡。
- `prompt=none`: UI 無し（インタラクション禁止）。`prompt=create` と組み合わせは矛盾するため、`prompt=none create` は `interaction_required` などのエラーが妥当。

### 2.3 既存セッション・Existing User の扱い

- 「既にログイン済みで、`prompt=create` で来た場合に新規登録 UI を出すか、確認なしで既存セッションを使うか」は仕様上 OP 裁量。ベストプラクティスは「新規登録 UI を出すが、既存セッション利用の選択肢も提示」。
- セキュリティ: `prompt=create` を悪用して別ユーザーアカウントが意図せず作成されないよう、確認 UI を経由するのが安全。

## 3. 参照資料

- Initiating User Registration via OpenID Connect 1.0（Implementer's Draft）: https://openid.net/specs/openid-connect-prompt-create-1_0.html
- OpenID Connect Core 1.0 §3.1.2.1（`prompt` パラメータ）: https://openid.net/specs/openid-connect-core-1_0.html
- 関連: `study-material/prompt-select-account.md`、`packages/core/src/authorization-request.ts`、`tasks/done/02-prompt-none.md` / `03-prompt-login.md`

## 4. 現在の実装確認

- `prompt` 受理ロジック: `packages/core/src/authorization-request.ts` の `validateAuthorizationRequest` で「許可値リスト」と照合（`none / login / consent / select_account`）。
- `prompt=create` は **未許可値として `invalid_request` エラー扱い**になる可能性が高い（コードを再確認のうえ、テストで挙動を固定すべき）。
- `auth-transaction.ts` の `checkPromptNone` / `requiresReauthentication` は `none` / `login` 専用ロジックで、`create` 経路は無い。
- CLI テンプレート `routes/login.ts` / `routes/consent.ts` に新規登録 UI ハンドリングは無し（ログイン専用）。
- Discovery: `prompt_values_supported` 未広告。

## 5. 現在の実装との差分

- **満たしていること**: `prompt` パラメータの parse・分岐基盤（`auth-transaction.ts`）。新 prompt 値の追加経路は再利用可能。
- **不足している可能性があること**
  - `prompt=create` の許可値追加（`authorization-request.ts` の許可値リスト）。
  - 「`prompt=create` を受け取ったらどのテンプレート/ルートに案内するか」のフック。core には `PromptCreateHandler` 的な resolver を注入する I/F が必要（実際の登録 UI は CLI テンプレート側）。
  - `prompt=none create` の矛盾検出（`interaction_required`）。
  - Discovery `prompt_values_supported` の追加（広告内容と実態の整合）。
- **既存タスクとの関係**
  - `prompt=select_account` を扱う `tasks/prompt-select-account.md` と並列に検討すべき。CLI テンプレートの分岐設計を共通化できる可能性がある（「prompt 値ごとのハンドラ注入」I/F）。

## 6. 改善・追加を検討する理由

- 新規登録フローを RP から明示できると、利用者（PoC 開発者）にとって **「OP に Auth0 / Cognito 等で実装される signup_hint 相当を試したい」** という具体的要求に応えられる。
- OIDC の最新ドラフトに早期追随するという差別化軸（Speed）に合致。
- 既存 `prompt` 取り扱い基盤を活かせるため、実装コストは小〜中。
- 実装しない場合の制約: 「サインアップ起点の OIDC フロー」を PoC で試せず、Cognito/Auth0 などと比較した検証ができない。

## 7. 実装方針の候補

### 方針A（推奨）: `prompt=create` 受理 + Resolver 注入による拡張ポイント

- `validateAuthorizationRequest` の許可値に `create` を追加。`prompt=none create` の同時指定は `invalid_request`（または `interaction_required` どちらが適切か仕様再確認）。
- `auth-transaction.ts` に「`prompt=create` を含む場合、認可フロー継続前に登録 UI を要求する」フラグ／ステータスを追加。
- CLI テンプレート: `prompt=create` 受信時に `/register` パスへルーティングする雛形を追加。登録成功後は通常の認可フローへ戻す（`auth-transaction` の resume）。
- Discovery（core builder）に `prompt_values_supported: ["none", "login", "consent", "select_account", "create"]` を出力する経路を追加。

### 方針B（最小）: 受理だけしてログイン扱いにフォールバック

- `prompt=create` を許可値に含めるが、実装の意味付けは「`prompt=login` と同じ」にとどめる。
- ドキュメントで「現状は登録 UI を持たないため、CLI テンプレート利用者が `/register` を追加する必要あり」と明記。

### 方針C: 非対応・明文化

- 拒否は仕様準拠と言えるが、ドラフト仕様であるため拒否のしかたは要慎重（`invalid_request` よりも単に無視のほうが将来互換性が高い）。

## 8. タスク案

- [ ] 方針A/B/C を選択する（ユーザー判断）。`tasks/prompt-select-account.md` と並列にハンドラ I/F を共通設計する案を併せて検討
- [ ] `prompt=create` を含む認可リクエストの受理／拒否動作の現状をテストで固定する（リグレッション基線）
- [ ] 方針A 採用時: `authorization-request.ts` の許可値に `create` 追加、`prompt=none create` の矛盾検出
- [ ] CLI テンプレートに `/register` ルート雛形と `auth-transaction` の resume パス
- [ ] Discovery `prompt_values_supported` の core builder 反映（`discovery-code-challenge-methods-supported.md` と同じ「core builder へ寄せる」方針）
- [ ] 完了条件: core / cli テストパス、Discovery が prompt_values_supported を出力すること
