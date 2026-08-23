# [P1] `prompt=select_account` のアカウント選択フローを実装する

## ステータス

✅ Phase 1 完了（2026-07-22）

> 複数セッションから選択する Phase 2 は、core の複数セッション解決契約を前提とするため
> `tasks/p3-prompt-select-account-phase2.md` で別管理する。

## 背景

`prompt=select_account` はバリデーションを通過し `ValidatedAuthorizationRequest.prompt` に格納されるが、Authorization Endpoint の handler 側に分岐がなく、通常の login フローと同じ動作になる。OIDC Core §3.1.2.1 では「OP は End-User にアカウントを選択させるべき (SHOULD)」と規定しており、Conformance テストで `select_account` が要求された際に意図した挙動になっていない。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`（`authorizeRouteTemplate`・`loginRouteTemplate`）

## 仕様参照

- OIDC Core 1.0 §3.1.2.1: Authentication Request — `prompt` parameter

## 現状の実装

`authorizeRouteTemplate` の `promptValues.includes('login')` 分岐は存在するが、`select_account` 向けの分岐はない。`select_account` リクエストは `promptValues` に格納されるが、その後は通常の login ページリダイレクトと同一パスを通る。

## 修正方針

### Phase 1（最小対応）
- [x] `prompt=select_account` を受け取った際、既存セッションがあっても強制的に login ページへ誘導する（`prompt=login` と同様の扱い）
  - 根拠: アカウント選択の最低要件は「現在のセッションを使わずにユーザに再提示する」こと
  - セッション破棄は `login` と同様に `authSessionStore.delete(transactionId)` で行う

### Phase 2（将来拡張・利用者責務）
- `sessionResolver` が複数セッションを返せるようになった場合に、アカウント選択 UI（select_account ページ）へ誘導する経路を template に追加する
- アカウント選択 UI は利用者が実装するため、template はリダイレクト先の URL を設定できる形にする

## テスト要件

- [x] `prompt=select_account` のとき、既存セッションが存在しても login ページにリダイレクトすること
- [x] `prompt=select_account` が `prompt=login` と同様に既存セッションを使用しないこと
- [x] `prompt=login` の既存テストが壊れないこと

## 完了条件

`pnpm --filter @maronn-openid-connect/cli test` がパスすること
