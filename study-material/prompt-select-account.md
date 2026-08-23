# `prompt=select_account` の挙動と `account_selection_required`

## ステータス

🟡 Major / 未着手

## 1. このトピックで確認したいこと

`prompt=select_account` は値としては受理されるが、**専用の挙動が無い**。
OIDC Core §15.1 が全 OP に `select_account` サポートを課している点に対し、
現状の「黙ってログイン画面へフォールバック」が仕様準拠として妥当か、
また `account_selection_required` エラー経路が必要かを確認する。

> `prompt` 全体（none/login/consent）の基礎は `tasks/done/02-prompt-none.md` /
> `tasks/done/03-prompt-login.md` で扱い済み。本ファイルは **重複を避け**、
> `select_account` 固有の差分のみを扱う。03-prompt-login には「select_account は未実装、
> 整理してドキュメント化する」とのメモがあり、本ファイルがその受け皿。

## 2. 関連する仕様・基準

- **OIDC Core 1.0 §3.1.2.1（Authentication Request, `prompt`）**:
  - `select_account`: OP は End-User にアカウント選択を促す **SHOULD**。
    複数アカウントを扱えない、または選択 UI を出せない場合は
    エラー（典型的には `account_selection_required`）を返す。
  - `none` は他値と併用不可（実装済み）。`select_account` は `login`/`consent` と併用可。
- **OIDC Core 1.0 §3.1.2.6（Authentication Error Response）**:
  - `account_selection_required`: End-User にアカウント選択が必要だが
    `prompt=none` 等で対話できない、または OP がアカウント選択を行えない場合のエラーコード。
- **OIDC Core 1.0 §15.1**: 全 OP は `prompt` 値 none/login/consent/**select_account** を
  サポート必須（`tasks/basic-op-requirements-baseline.md` 参照、仕様は重複記載しない）。
- 認定テスト観点（要一次資料確認）: Basic OP テストプランは `prompt=login`/`none` を
  重点検証する。`select_account` 専用テストは Basic OP プランには通常含まれない見込み。
  ただし §15.1 のサポート義務は別途存在する。

## 3. 参照資料

- OIDC Core 1.0 §3.1.2.1 / §3.1.2.6 / §15.1:
  https://openid.net/specs/openid-connect-core-1_0.html
  - §3.1.2.1 `prompt` 値の定義（`select_account` の SHOULD / エラー要件）
  - §3.1.2.6 `account_selection_required`
- OpenID 認定（OP テスト手順）: https://openid.net/certification/connect_op_testing/

## 4. 現在の実装確認

- 値の受理: `packages/core/src/authorization-request.ts:206`

  ```ts
  const VALID_PROMPT_VALUES = ['none', 'login', 'consent', 'select_account'] as const;
  ```

  `validatePrompt`（`authorization-request.ts:329-359`）は `select_account` を有効値として通すのみ。
- エラーコード: `AuthorizationErrorCode`（`authorization-request.ts:12-26`）に
  `AccountSelectionRequired = 'account_selection_required'` は **定義済み**だが、
  この値を投げる経路は実装に存在しない（参照のみ）。
- ルート挙動: sample `routes/authorize.ts`
  - `prompt=none` 経路は専用処理あり（`authorize.ts:98-189`）。
  - `prompt=login` は login ルートで session 破棄（`routes/login.ts:79-82`）。
  - `prompt=select_account` は **どの分岐にも該当せず**、最終的に
    `/login` への通常リダイレクト（`authorize.ts:211-214`）にフォールバック。
- sample/CLI はユーザーが常に 1 アカウント前提のログインフォームで、
  アカウント選択 UI は存在しない。

## 5. 現在の実装との差分

- **満たしていること**
  - `select_account` を不正値として弾かない（§15.1 の最低限：受理）。
  - 結果的にログイン画面が出るため、単一アカウント運用では実害が出にくい。
- **不足している可能性があること**
  - `select_account` を要求されても「アカウント選択を促す」挙動が一切無い。
  - アカウント選択ができない／対話不能（`prompt=none select_account` は §3.1.2.1 上
    `none` 併用不可なので発生しないが、`prompt=none` 単体でアカウント選択が必要な状況）で
    `account_selection_required` を返す経路が無い。
  - core にアカウント選択を抽象化する I/F（resolver / callback）が無く、
    利用者が「複数アカウント選択」を表現できない。
- **相互運用性**
  - 単一アカウント前提なら現状で動くが、`select_account` を強く解釈する RP/テストでは
    「選択 UI を見せる or `account_selection_required`」が期待されうる。
- **Basic OP として確認すべきこと**
  - §15.1 のサポート義務は満たすべき。Basic OP **認定テスト**での専用検証有無は
    一次資料（Conformance Profiles v3.0 / テストプラン）で要確認。

## 6. 改善・追加を検討する理由

- §15.1 は全 OP に `select_account` を課す。本リポジトリは Fidelity を差別化軸に
  掲げており、「受理はするが意味が無い」状態は仕様準拠の説明責任上きれいでない。
- core はロジック層として「アカウント選択は利用者責務」と切り分けつつ、
  **resolver 注入で挙動を表現可能にする**設計（既存の `ConsentResolver` /
  `SessionResolver` / `AcrResolver` と同じ思想）に乗せやすく、導入しやすい。
- 実装しない場合のリスク: 複数アカウント／企業 SSO 的ユースケースを検証したい利用者が
  `select_account` の検証をこのライブラリで行えない。仕様準拠主張の穴が残る。

## 7. 実装方針の候補

判断材料の整理（最終判断は人間）。

### 方針A（最小）: `account_selection_required` 経路の整備のみ

- `prompt=select_account` かつ「アカウント選択ができない」と
  利用者が判定した場合に `AccountSelectionRequired` を返せるよう、
  既存の `checkPromptNone` 同様の判定ヘルパー or コールバックを core に追加。
- sample/CLI は単一アカウントなので「常にログイン画面（=暗黙のアカウント確定）」とし、
  少なくとも `prompt=none` で session 無し時に `login_required`（現状どおり）を維持。
- 仕様の SHOULD（選択を促す）は満たさないが、エラー経路は仕様準拠化。

### 方針B（resolver 注入）: アカウント選択を抽象化

- `AccountSelectionResolver` 的 I/F を定義（候補アカウント列挙 or
  「選択 UI を出すべきか」を返す callback）。
- sample/CLI テンプレートに「アカウント選択画面」スタブを生成（単一アカウントなら自動確定）。
- 既存 `SessionResolver`/`ConsentResolver` と同じ注入パターンで一貫性を保つ。
- §3.1.2.1 の SHOULD（選択を促す）まで満たせる。

### 方針C（割り切り＋明文化）

- 「単一アカウント前提のため `select_account` はログインで代替」と
  型 doc / 生成コードのコメントに明記し、`account_selection_required` だけ最低限用意。

## 8. タスク案

- [ ] 方針A/B/C を選択（ユーザー判断）。`select_account` を Basic OP 認定で
      検証されるか一次資料（Conformance Profiles v3.0 / テストプラン）で確認
- [ ] （方針A/B）`authorization-request.ts` か `auth-transaction.ts` に
      `select_account` 用の判定ヘルパー／resolver I/F を追加するテストを先行作成
- [ ] core 実装（`AccountSelectionRequired` を投げる経路 / resolver 注入）
- [ ] sample/CLI テンプレートの authorize 経路に `select_account` 分岐を追加
      （単一アカウントは自動確定、対話不能時は `account_selection_required` redirect）
- [ ] テスト: `prompt=select_account` 受理 / 対話不能時 `account_selection_required` /
      `prompt=login select_account` 併用が壊れないこと
- [ ] 完了条件:
      `pnpm --filter @maronn-openid-connect/core test` /
      `pnpm --filter @maronn-openid-connect/cli test` がパス
