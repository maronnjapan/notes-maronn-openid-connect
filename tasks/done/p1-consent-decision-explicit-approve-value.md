# [P1] 同意 POST の承認判定を fail-closed にする（`action` の肯定値を明示検出する）

## ステータス

🟠 High / 未着手

## 背景

CLI が生成する OP の同意ハンドラは `if (action === 'deny')` だけで拒否を判定し、**それ以外のすべての値
（未送信・空文字・未知の値）を「承認」として認可コードを発行している**。承認を「否定の否定」で判定する
denylist 方式のため、値の欠落・変更に対して常に危険側（承認側）へ倒れる。

具体的に到達しうる経路:

- 利用者が view の `value="approve"` を `allow` / `accept` 等に書き換えると、**拒否ボタンだけが正しく動き、
  承認は「常に成立」する**。画面上は正常に見えるため誤りに気づけない（最も現実的な経路）
- `action` を含まない POST（自動化テスト、スクリプト、フォームを再構成するツール等）が
  `csrf_token` さえ揃っていれば承認になる
- （未検証）実装差により submit ボタンの name/value が付かない送信経路が存在した場合、
  ユーザーが何も押していないのに承認される。現行の HTML 仕様では暗黙送信でも最初の submit ボタンの
  name/value が送られるため、この経路が実在するかは環境依存であり本タスクの前提には置かない

さらに、view が送る値（`approve`）、ハンドラの判定（`deny` の否定）、既存ドキュメントの記載（`allow`：
`study-material/done/consent-grant-persistence-and-management.md:102,162,187`）の **三者が不一致**で、
「同意はどの値で成立するのか」がコードから一意に読めない。

CSRF トークン検証と認証済みセッション確認が前段にあるため、外部サイトからの純粋な CSRF は成立しない。
本件は「リモートの第三者が任意に同意を捏造できる」重大脆弱性ではなく、**同意画面まで到達したブラウザが
明示的な承認意思なしに承認扱いになる**という、生成コードの安全側既定値の問題である。

検討の詳細・仕様根拠・方針比較は `study-material/done/consent-decision-fail-open-action-value.md` を参照
（本タスクは実装に絞る）。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`（consent ハンドラ `:3438` 付近、consent view `:4259-4260`）
- `packages/cli/src/frameworks/web-standard/templates.ts`（consent ハンドラ `:1503` 付近、view `:1453,1456`）
- `packages/cli/src/frameworks/web-standard/templates.ts` の Next.js Server Action 版
  （`nextJsConsentActionTemplate` = `:1492` 付近、consent page = `:1406,1450`。
  生成物: `src/app/consent/actions.ts` / `src/app/consent/page.tsx`）
- `packages/cli` の `conformance.test.ts` 生成コード（契約テストの追加先）
- 再生成される sample:
  - `samples/hono-cloudflare/src/oidc-provider/routes/consent.ts:51,67` / `views.ts:173-174`
  - `samples/express-flyio/src/oidc-provider/routes/consent.ts:67` / `views.ts:173`
  - `samples/fastify-flyio/src/oidc-provider/routes/consent.ts:67` / `views.ts:173`
  - `samples/nextjs-vercel/src/app/_oidc-provider/routes/consent.ts:67` /
    `src/app/consent/actions.ts:37` / `src/app/consent/page.tsx:54` / `_oidc-provider/views.ts:173-174`
- `study-material/done/consent-grant-persistence-and-management.md`（`action=allow` の記述訂正）

> CLAUDE.md のルールに従い、`samples/*/src/oidc-provider` は直接編集せず `packages/cli` のテンプレートを
> 修正して再生成すること。`conformance.test.ts` も生成側を変更すること。

## 仕様参照

- **OpenID Connect Core 1.0 §3.1.2.4 Authorization Server Obtains End-User Consent/Authorization**:
  「Once the End-User is authenticated, the Authorization Server MUST obtain an authorization decision
  before releasing information to the Relying Party.」
  → 情報を RP へ渡す前に authorization decision を **取得しなければならない**。decision が取得できたと
  判定する条件は OP の責務であり、「否定語に一致しないこと」で代替してはならない。
- **OpenID Connect Core 1.0 §3.1.2.1（`prompt=consent`）**: 同意画面を必ず再表示して決定を取り直す。
  戻ってきた POST が「値が何であれ承認」なら再表示の意味が失われる。
- 同意の肯定値そのもの（`approve` / `allow` / `accept`）を規定する一次仕様は存在しない。
  本タスクは**本リポジトリが生成コードの契約としてどの値を固定するか**を決めるものである。
- 本リポジトリの既存方針: `study-material/resolver-and-store-contract.md`（resolver は fail-closed。
  「誤実装で fail-open を作るリスク」を論点として明記）

## 現状の実装

`samples/hono-cloudflare/src/oidc-provider/routes/consent.ts`:

```ts
const action = String(body['action'] ?? '');   // L51: 欠落時は空文字

const transaction = await getAuthTransaction(transactionId, transactionStore);
validateCsrfToken(transaction, csrfToken);

if (action === 'deny') {                        // L67: deny のときだけ拒否
  // access_denied で redirect_uri へ戻す
  return c.redirect(redirectUrl.toString());
}

// ここから先はすべて「承認」経路 — action の値は二度と参照されない
const session = await authSessionStore.get(transactionId);
...
const authCodeData = await createAuthorizationCode({ ... });
await authCodeStore.set(authCodeData.code, authCodeData);
await consentResolver.recordConsent?.(session.subject, transaction.clientId, grantedScope);
```

`views.ts:173-174` が送る値:

```html
<button type="submit" name="action" value="approve">Approve</button>
<button type="submit" name="action" value="deny">Deny</button>
```

肯定側の `approve` はハンドラで一度も検査されていない。

## 修正方針

- [ ] 肯定値を `approve`（現行 view と同じ）に固定することを決定し、テンプレートのコメントに明記する
- [ ] consent ハンドラを allowlist 判定に変更する（方針A：`study-material/done/` の推奨）

```ts
const action = String(body['action'] ?? '');

if (action === 'deny') {
  // 既存の access_denied 経路（変更しない）
  ...
}

// OIDC Core 1.0 §3.1.2.4: 情報を RP へ渡す前に authorization decision を取得しなければならない。
// 肯定値を明示的に検出する（未知値・欠落は「決定が得られていない」ので承認しない）。
// この値を変更する場合は views.ts / page.tsx の button value も必ず合わせること。
if (action !== 'approve') {
  return renderView(views.errorPage({
    error: 'Invalid consent decision. Please use the Approve or Deny button.',
    statusCode: 400,
  }), { status: 400 });
}
```

- [ ] 未知値を `access_denied` で `redirect_uri` へ返さないこと。`access_denied` は
      「resource owner が拒否した」意味（OIDC Core §3.1.2.6）であり、「決定が取得できなかった」とは
      意味論が異なるため、OP 自身の 400 エラーページで止める
- [ ] Next.js の Server Action 版（`src/app/consent/actions.ts`）も同じ判定にする
- [ ] view（`views.ts` / `page.tsx`）とハンドラの期待値の対応を、テンプレート内のコメントで 1 箇所に
      集約して示す
- [ ] `study-material/done/consent-grant-persistence-and-management.md` の `action=allow` という記述を
      実際の値（`approve`）へ修正する
- [ ] 利用者が view を書き換えていた場合に承認が 400 になるため、破壊的変更として `RELEASE.md` /
      release note に記載する

## テスト要件

`packages/cli` の conformance.test.ts 生成コードに以下を追加する（生成物を直接編集しないこと）。

- [ ] `should not issue an authorization code when the consent POST omits the action parameter`
- [ ] `should not issue an authorization code when the consent POST sends an empty action value`
- [ ] `should not issue an authorization code when the consent POST sends an unknown action value`
- [ ] `should return 400 for a consent POST with an unrecognized action value`
- [ ] `should issue an authorization code when the consent POST sends action=approve`（既存挙動の回帰確認）
- [ ] `should redirect with error=access_denied when the consent POST sends action=deny`（既存挙動の回帰確認）
- [ ] `should not record consent via recordConsent when the action value is unrecognized`

`packages/cli` の generator テストにも以下を追加する。

- [ ] 生成された consent ハンドラに `action !== 'approve'` 相当の allowlist 判定が含まれること
- [ ] 生成された view の button value と、ハンドラの期待値が一致していること

## 完了条件

- `pnpm --filter @maronn-openid-connect/cli test` がパスすること
- 4 sample を再生成し、`pnpm test` がパスすること
- 生成された 4 sample すべてで `action` の欠落・空文字・未知値が認可コードを発行しないこと
- `study-material/done/consent-grant-persistence-and-management.md` の記述が実装と一致していること
