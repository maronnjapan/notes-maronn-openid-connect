# [P3] `login_hint` を生成 Provider のログイン画面にプレフィルする

## ステータス

🟡 Medium / 未着手

## 背景

`login_hint` は core で受理され `AuthTransaction` に永続化されるが、CLI 生成プロバイダのログイン画面に
一切伝わっておらず、write-only で死蔵している。OIDC Core §3.1.2.1 は「ログインフォームに `login_hint` の値を
投入することが RECOMMENDED」としており、Fidelity の観点で「受理だけ」は説明責任上弱い。

transaction まで値が載っているため、UI への動線を 1 本通すだけで RECOMMENDED を満たせる。

検討の詳細は `study-material/done/login-hint-ui-prefill.md` を参照。

## 対象ファイル

- `packages/cli/src/frameworks/*/templates.ts`（`LoginPageParams` / `defaultLoginPage` / login ルートの生成元）
- 生成物の確認用: `samples/{express,hono,fastify,nextjs}/src/oidc-provider/views.ts`（`LoginPageParams` L16, `defaultLoginPage` L74）、
  `.../routes/login.ts`（`views.loginPage(...)` 呼び出し L34, L76）
- CLI ジェネレータのテスト（`packages/cli/src/__tests__/`）

## 仕様参照

- OpenID Connect Core 1.0 §3.1.2.1 "Authentication Request" — `login_hint`
  > it is RECOMMENDED that the OP populate the login form with this value.
  - 任意パラメータ。値は信頼できない外部入力であり、OP は「ヒント」として初期表示のみに使う。
  https://openid.net/specs/openid-connect-core-1_0.html#AuthRequest

## 現状の実装

- 受理: `packages/core/src/authorization-request.ts:57, 254, 898, 934`。
- 永続化: `packages/core/src/auth-transaction.ts:116, 234-235`（transaction に `loginHint` を複写）。
- UI 連携: 欠落。`LoginPageParams`（各 `views.ts:16`）に `loginHint` フィールドが無く、
  login ルート（各 `login.ts:34`）も `views.loginPage({ transactionId, csrfToken })` で `loginHint` を渡していない。

## 修正方針

- [ ] CLI テンプレートの `LoginPageParams` に `loginHint?: string` を追加する。
- [ ] 生成 login ルートで transaction から `loginHint` を取り出し、`views.loginPage({ ..., loginHint })` に渡す。
- [ ] `defaultLoginPage` の username 入力欄に **HTML エスケープした上で** `value="..."` を反映する
      （`login_hint` は未認証の外部入力。属性値コンテキストで安全にエスケープすること）。
- [ ] OP は値を信頼せず、初期表示のみとする（実認証はユーザー入力で確定）。
- [ ] 4 フレームワーク（express/hono/fastify/nextjs）で挙動を統一する。

```ts
// イメージ（views.ts）
export interface LoginPageParams {
  transactionId: string;
  csrfToken: string;
  loginHint?: string; // 追加
}
// username 入力欄: value="${escapeHtmlAttr(params.loginHint ?? '')}"
```

## テスト要件

- [ ] `login_hint=alice@example.com` を含む認可リクエスト後、生成ログイン画面の username 欄に
      その値が初期表示されること。
- [ ] **XSS 回帰**: `login_hint=<script>alert(1)</script>` や `" onfocus=...` が属性値として
      安全にエスケープされ、HTML/属性インジェクションが成立しないこと。
- [ ] `login_hint` 不在時に空欄で正常表示されること。
- [ ] 4 フレームワークで同一挙動になること。

## 完了条件

- `pnpm --filter @maronn-openid-connect/cli test` がパスすること
- 生成物のログイン画面で `login_hint` が安全にプレフィルされること
