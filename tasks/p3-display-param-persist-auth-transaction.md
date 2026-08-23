# [P3] `display` を AuthTransaction に保持し UI 層へ伝播する

## ステータス

🟢 Minor / 未着手

## 背景

Authorization Request の `display` は `validateAuthorizationRequest` で値検証（`page`/`popup`/`touch`/`wap`）され `ValidatedAuthorizationRequest` に格納されるが、`createAuthTransaction` が `AuthTransaction` へ転記していないため、後続のログイン UI・同意画面がリクエストされた表示モードを参照できない（validate-then-drop）。`login_hint` は保持されるのに `display` だけ落ちるのは非対称で、`ui_locales`/`claims_locales` と同じ穴（そちらは `tasks/p3-persist-ui-claims-locales-auth-transaction.md` で対応予定）。本タスクはその**兄弟**で、対象パラメータが `display` である点だけが異なる。

`display` の UI 出し分け自体は OIDC Core 上 SHOULD/MAY であり Basic OP 認定の必須ではない。本タスクは「検証済み `display` を UI 層に届ける」ところまでに限定した低リスク改善。

詳細な検討は `study-material/done/display-parameter-persistence-and-ui-propagation.md` を参照。

## 対象ファイル

- `packages/core/src/auth-transaction.ts`（`AuthTransaction` 型 + `createAuthTransaction` の転記処理）
- `packages/core/src/auth-transaction.test.ts`（テスト）
- （方針 B 採用時）`AuthorizationResponseParams` および `packages/cli` テンプレート / 各 sample の views

## 仕様参照

- OpenID Connect Core 1.0 §3.1.2.1 `display`（`page`/`popup`/`touch`/`wap`。OP は SHOULD/MAY で尊重、未対応でもエラーにしない）
- OpenID Connect Core 1.0 §15.1（`display` を受理できること＝既に充足。UI 出し分けまでは MUST でない）

## 現状の実装

```ts
// packages/core/src/authorization-request.ts
//   L908-921: display の値検証（page/popup/touch/wap 以外は invalid_request）
//   L972:     display を ValidatedAuthorizationRequest にそのまま返却

// packages/core/src/auth-transaction.ts
//   AuthTransaction 型（L96-127）に display フィールドが無い
//   createAuthTransaction（L200-248）は login_hint 等を転記するが display を転記しない
//   AuthorizationResponseParams（L142-161）にも display が無い
```

`ValidatedAuthorizationRequest` 側に `display` が既に存在するため、`login_hint` と同じパターンで転記するだけでよい。

## 修正方針

- [ ] `AuthTransaction` 型に `display?: string` を追加する
  ```ts
  /** OIDC Core 1.0 §3.1.2.1: 認証/同意 UI の表示モード（page/popup/touch/wap）。OP は SHOULD/MAY で尊重 */
  display?: string;
  ```
- [ ] `createAuthTransaction` で `login_hint` と同じパターンで転記する
  ```ts
  if (validatedRequest.display !== undefined) {
    transaction.display = validatedRequest.display;
  }
  ```
- [ ] core はパススルーのみとし、値の変形・再検証は行わない（検証は `validateAuthorizationRequest` 側で完了済み）
- [ ] （任意・方針 B）`AuthorizationResponseParams` にも `display` を追加し同意画面経路で参照可能にするか、UI 出し分けを sample/テンプレートで最小実装するかは、`ui_locales`/`claims_locales` タスクと足並みを揃えて判断する

## テスト要件

- [ ] `display` を含む認可リクエスト → `createAuthTransaction` 結果に `display` が保持される
- [ ] `display` 未指定時 → `AuthTransaction.display` が `undefined`
- [ ] 各 `display` 値（`page`/`popup`/`touch`/`wap`）がそのまま保持される（値の変形が無い）
- [ ] 既存の `login_hint` / `acr_values` 等の転記が回帰しないこと

## 完了条件

- `pnpm --filter @maronn-openid-connect/core test` がパスすること
- 検証済み `display` が AuthTransaction 経由で UI 層から参照可能になっていること
