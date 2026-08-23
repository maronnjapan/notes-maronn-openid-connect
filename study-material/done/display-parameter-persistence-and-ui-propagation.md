# `display` パラメータを AuthTransaction に保持し、ログイン/同意 UI へ伝播する

## 1. このトピックで確認したいこと

Authorization Request の `display` は `validateAuthorizationRequest` で値検証（`page`/`popup`/`touch`/`wap`）され `ValidatedAuthorizationRequest` に格納されるが、`createAuthTransaction` が `AuthTransaction` へ転記していないため、後続のログイン UI・同意画面がリクエストされた表示モードを参照できない。「検証はするが後段で消費できない（validate-then-drop）」という非対称を是正すべきか確認したい。

これは同じ「OP 側 UI ヒントを AuthTransaction に保持する」系統の未着手タスク `tasks/p3-persist-ui-claims-locales-auth-transaction.md`（`ui_locales` / `claims_locales`）の**兄弟トピック**であり、対象パラメータが `display` である点で別ファイルとして扱う。

## 2. 関連する仕様・基準

共通の「認可リクエストのオプションパラメータを AuthTransaction に転記して UI へ渡すパターン」の説明は `tasks/p3-persist-ui-claims-locales-auth-transaction.md` および `study-material/done/ui-claims-locales-auth-transaction-handling.md` を参照し繰り返さない。本トピック固有の差分に絞る。

- **OpenID Connect Core 1.0 §3.1.2.1 (`display`)**: OP が認証および同意 UI をどう表示するかの ASCII 文字列値。定義値は `page` / `popup` / `touch` / `wap`。OP がこれを尊重するかは SHOULD/MAY レベル（未対応でもエラーにしてはならない）。
- **OpenID Connect Core 1.0 §15.1 (Mandatory to Implement)**: OP は `display` を含む一連のリクエストパラメータを**受理できなければならない**（未知値でエラーにしない）。ただし各表示モードでの実 UI 出し分けまでは MUST ではない。
- **本トピックの位置づけ**: 「値検証（`tasks/done`... 実際は `oidc-improvements-2026-05` / `p2-display-param-validation` 系）」と「Discovery での `display_values_supported` 広告（`study-material/discovery-optional-metadata-fields.md`）」は既に別トピックで扱い済み。本ファイルは**検証済みの `display` を AuthTransaction 経由で UI 層に届ける伝播経路**の欠落に限定する。

## 3. 参照資料

- OpenID Connect Core 1.0 §3.1.2.1 Authentication Request（`display` の定義値と意味）— https://openid.net/specs/openid-connect-core-1_0.html#AuthRequest
- OpenID Connect Core 1.0 §15.1 Mandatory to Implement Features for All OPs — https://openid.net/specs/openid-connect-core-1_0.html#ServerMTI
- 兄弟タスク: `tasks/p3-persist-ui-claims-locales-auth-transaction.md`（`ui_locales`/`claims_locales` を同じパターンで転記。方針 A を採用済み）
- 既存の周辺トピック: `study-material/discovery-optional-metadata-fields.md`（`display_values_supported` 広告）、display 値検証（`p2-display-param-validation` 系）

## 4. 現在の実装確認

- 値検証と返却: `packages/core/src/authorization-request.ts:908-921`（`page/popup/touch/wap` 以外は `invalid_request`（redirectable））、`:972`（`display` を `ValidatedAuthorizationRequest` にそのまま返却）。
- 転記漏れ:
  - `AuthTransaction` 型 `packages/core/src/auth-transaction.ts:96-127` に `display` フィールドが**無い**。
  - `createAuthTransaction`（`:200-248`）は state/nonce/codeChallenge/prompt/maxAge/acrValues/loginHint/idTokenHint/audience/claims を転記するが `display` を転記しない（`uiLocales`/`claimsLocales` も同様に落ちており、そちらは別タスクで対応予定）。
  - `AuthorizationResponseParams`（`:142-161`）にも `display` は無い。
- 結果: sample の login/consent ビュー（`samples/*/src/oidc-provider/views.ts` 等、`packages/cli` テンプレート由来）は、リクエストされた `display` を知り得ず、常に既定レンダリングになる。

## 5. 現在の実装との差分

満たしていること:
- `display` の**受理と値検証**は実装済み（未知値は `invalid_request`、既知値はエラーにしない）。§15.1 の「受理する」最低要件は充足。

不足している可能性があること:
- 🟢 **検証済み `display` が AuthTransaction / レスポンスパラメータに転記されず、UI 層で参照不能**。`login_hint` 等が保持されるのに `display` だけ落ちるのは非対称（`ui_locales`/`claims_locales` と同じ穴）。

相互運用性の観点:
- Discovery で `display_values_supported` を広告する場合（`study-material/discovery-optional-metadata-fields.md`）、「広告はするが実際にはリクエスト値を消費する経路が無い」不整合が生じる。`popup` を要求した RP に対しても `page` 相当の画面しか返せない。

Basic OP として確認すべきこと:
- 各 `display` モードでの UI 出し分けは Basic OP 認定の MUST ではない。したがって**認定可否には影響しない**。本トピックは「OSS 利用者が display 対応 UI を実装する入口を整える」低リスク改善。

## 6. 改善・追加を検討する理由

- **なぜ価値があるか**: `display` を AuthTransaction に載せておけば、生成コードを受け取った利用者が「`popup` のときはヘッダを省いた軽量画面を返す」等のカスタマイズを、core 改変なしに実装できる。ライブラリの想定ユースケース（生成コードを改造して仕様を検証する）に直結。
- **Basic OP 必須か拡張か**: 拡張（UI 品質・相互運用の入口）。ただし `ui_locales`/`claims_locales` タスクと同じ「validate-then-drop の是正」カテゴリで、方針が既に定まっている（転記のみ・値の変形はしない）。
- **導入しやすさ**: `ValidatedAuthorizationRequest` 側に `display` が既に存在するため、`login_hint` と同じパターンで 1 フィールド転記するだけ。core 内で完結。UI 出し分けの実装は利用者に委ねられるため、本タスクは「値を届ける」ところまでに限定できる。
- **利用者メリット**: 多デバイス（touch/wap）や埋め込み（popup）向けの認証画面を、生成 OP を土台に素早く試せる。
- **実装しない場合のリスク**: `display_values_supported` を広告した場合の言行不一致が残る。利用者は「`display` を送っても何も変わらない」ことを「ライブラリの不足」と受け取り得る。

## 7. 実装方針の候補

最終判断は人間が行う前提で整理する。兄弟タスク（`ui_locales`/`claims_locales`）で採用済みの「方針 A: core はパススルー転記のみ、UI 出し分けは利用者に委ねる」を踏襲するのが自然。

- 方針A（転記のみ / 兄弟タスクと同一方針・推奨）: `AuthTransaction` に `display?: string` を追加し、`createAuthTransaction` で `login_hint` と同じパターンで転記する。UI レンダリングの分岐は行わず、値を届けるところまでを core の責務とする。
- 方針B（レスポンスパラメータにも載せる）: `AuthorizationResponseParams` にも `display` を追加し、同意画面リダイレクト経路でも参照可能にする。UI 出し分けを sample/テンプレートで最小実装（例: `popup` で最小レイアウト）まで踏み込むか判断する。
- 方針C（現状維持 + 文書化）: 転記せず「`display` は受理・検証のみ。UI 出し分けは未対応」と生成コードのコメント/README に明記。実装コスト最小だが入口整備の価値は得られない。

方針B で sample の UI 出し分けまで含めるかは、`ui_locales`/`claims_locales` タスクの進め方（現状は転記のみ）と足並みを揃えて判断する。

## 8. タスク案

- [ ] （TDD）`auth-transaction.test.ts` に「`display` を含む認可リクエスト → `createAuthTransaction` 結果に `display` が保持される」「未指定時は `undefined`」「既存 `login_hint`/`acr_values` 等の転記が回帰しない」テストを追加（Red）
- [ ] `AuthTransaction` 型に `display?: string` を追加し、`createAuthTransaction` で `login_hint` と同じパターンで転記（Green）
- [ ] （方針B採用時）`AuthorizationResponseParams` にも `display` を追加し、同意画面経路での参照を可能にする。sample/`packages/cli` テンプレートの UI 出し分け範囲を決める
- [ ] core はパススルーのみとし、値の変形・再検証は行わない（検証は `validateAuthorizationRequest` 側で完了済み）
- [ ] `pnpm --filter @maronn-openid-connect/core test` がパスすること

## 関連トピック

- `tasks/p3-persist-ui-claims-locales-auth-transaction.md` / `study-material/done/ui-claims-locales-auth-transaction-handling.md` — 同じ「OP 側 UI ヒントを AuthTransaction に保持する」パターン。共通の設計判断（転記のみ・方針 A）はそちらを一次記録とし、本ファイルは `display` 固有の差分に絞る。
- `study-material/discovery-optional-metadata-fields.md` — `display_values_supported` 広告。広告と消費経路の整合性の観点で関連。
