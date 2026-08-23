# [P1] 生成 OP の内部リダイレクト（`/login` / `/consent`）の origin 導出を `config.issuer` に統一する

## ステータス

🟠 High / 未着手

## 背景

生成 OP は Authorization Endpoint から `/login` / `/consent` へ **絶対 URL の 302 リダイレクト**で遷移する。
この絶対 URL の origin をどこから導出しているかが、CLI が生成する 4 テンプレートで揃っていない。

| テンプレート | リクエスト URL の origin | Host ヘッダの影響 |
|---|---|---|
| express | `config.issuer` に正規化（`apply.ts` → `node-adapter.ts`） | 受けない |
| fastify | `config.issuer` に正規化（同上） | 受けない |
| Next.js | `config.issuer` に正規化（`next.ts` の `rebaseRequestOrigin`） | 受けない |
| **hono** | **正規化していない（ランタイムのリクエスト URL をそのまま使用）** | **受ける** |

ルート側のコード（`new URL('/consent', c.req.url)`）は 4 テンプレートで同一であり、
差が出るのはアダプタ層だけである。hono テンプレートだけ「内部リダイレクトの飛び先を
リクエストヘッダが決める」挙動になっている。

影響:

1. **Node / Bun / Deno 上の hono**（`@hono/node-server` 等）では `c.req.url` が `Host` ヘッダから組み立てられる。
   前段プロキシが `Host` を固定していなければ、攻撃者が指定した origin が `Location` に入り、
   **`transaction_id` が第三者へ漏れる**／**ログイン途中のユーザーを攻撃者ホストへ着地させる**。
2. **Cloudflare Workers** では任意の攻撃者 Host は通常成立しないが、
   `*.workers.dev` とカスタムドメインの両方が有効な構成では、内部リダイレクトが
   `issuer` / Discovery / ID Token の `iss` と**別 origin に留まる**。
3. **公開ホスト名 ≠ 内部ホスト名のリバースプロキシ構成**では、内部ホスト名が `Location` に出て
   **認可フローがログイン画面手前で止まる**（Portability 軸の実害）。

`/login` / `/consent` はパスがリテラル固定のため、**任意 URL へのオープンリダイレクトにはならない**。
また束縛 Cookie（`tasks/done/p1-auth-transaction-user-agent-binding.md`）により、
`transaction_id` を得た第三者が `/consent` を完遂することはできない。影響は origin の取り違えに限定される。

検討詳細は `study-material/done/generated-op-internal-redirect-origin-derivation.md` を参照。

> 関連（重複しない）: クライアントへ返す `redirect_uri` の検証は既に堅牢で本タスクの対象外
> （`tasks/done/p1-redirect-uri-dangerous-scheme-rejection.md` ほか）。
> 本タスクは **OP が自分自身へ飛ばす内部リダイレクトの origin** のみを扱う。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`
  - 内部リダイレクト組み立て（`new URL('/consent', c.req.url)` / `new URL('/login', c.req.url)`。生成物では 3 箇所）
  - `applyOidc` / `createApp` 相当のミドルウェア層（origin 正規化を入れる場合）
- `packages/cli/src/frameworks/express/index.ts`、`fastify/index.ts`、`nextjs/index.ts`、`web-standard/templates.ts`
  （導出元が `config.issuer` であることをコメントで明示する）
- 各 sample の `conformance.test.ts` を生成する `packages/cli` 側コード
- 生成物（直接編集しない・確認用）:
  `samples/hono-cloudflare/src/oidc-provider/routes/authorize.ts:650,662`、`routes/login.ts:170`

## 仕様参照

- **OIDC Discovery 1.0 §3 Provider Metadata**: `issuer` は `iss` クレームと一致する URL であり、
  `authorization_endpoint` もそこから広告される。OP が「自分自身」を指す URL を組み立てるとき、
  **真実の情報源は設定値であってリクエストヘッダではない**。
- **RFC 9700（OAuth 2.0 Security BCP）**: AS はユーザーエージェントを**信頼できる URI にのみ**自動リダイレクトすべき。
  `Host` ヘッダから組み立てた origin は、検証していない限りこの条件を満たさない。
- **RFC 9110 §10.2.2 Location**: `Location` フィールド値は**相対参照でよい**。
  絶対 URL の組み立ては必須ではなく、`Location: /consent?transaction_id=...` でも仕様適合する。
- **RFC 6265 §8.5 / §8.6**: Cookie は origin ではなくドメインで隔離される。
  origin が変わっても Cookie が付く／付かないの境界は host 単位であり、
  origin 取り違えは Cookie の到達性にそのまま影響する。

## 現状の実装

### hono テンプレート（正規化なし）

```ts
// 生成物: samples/hono-cloudflare/src/oidc-provider/routes/authorize.ts:650
const consentUrl = new URL('/consent', c.req.url);   // ← c.req.url は Host ヘッダ由来
consentUrl.searchParams.set('transaction_id', transactionId);
return c.redirect(consentUrl.toString());            // ← 絶対 URL の Location
```

`samples/hono-cloudflare/src/oidc-provider/apply.ts` / `app.ts` を通しても、
`config.issuer` は Discovery メタデータ・`iss` クレーム・`corsOrigins` にしか使われず、
リクエスト URL の origin を書き換える処理は存在しない。

### express / fastify テンプレート（正規化あり）

```ts
// samples/express-flyio/src/oidc-provider/apply.ts:24-29
const baseUrl = options.config?.issuer ?? 'http://localhost';
const response = await oidc.request(toWebRequest(req, baseUrl));

// samples/express-flyio/src/oidc-provider/node-adapter.ts:9-10
const path = incoming.originalUrl ?? incoming.url ?? '/';
const url = new URL(path, baseUrl);   // ← path のみ採用。Host ヘッダは URL 組み立てに使わない
```

### Next.js テンプレート（正規化あり）

```ts
// samples/nextjs-vercel/src/app/_oidc-provider/next.ts:24-33
function rebaseRequestOrigin(request: Request, issuer: string | undefined): Request {
  if (!issuer) return request;
  const issuerUrl = new URL(issuer);
  const requestUrl = new URL(request.url);
  if (requestUrl.origin === issuerUrl.origin) return request;
  requestUrl.protocol = issuerUrl.protocol;
  requestUrl.host = issuerUrl.host;
  ...
```

## 修正方針

方針は 3 案ある。**着手前にどれを採るかを決めること**（詳細な比較は study-material を参照）。

- 方針 A: hono の `applyOidc` / `createApp` に、Next.js テンプレートと同型の origin 正規化ミドルウェアを追加する
- 方針 B: ルート側の `new URL(path, c.req.url)` を `new URL(path, config.issuer)` に変更する（3 箇所）
- 方針 C: `Location` を相対参照にする（`c.redirect('/consent?transaction_id=...')`）

チェックリスト:

- [ ] 方針（A / B / C）を決定し、決定理由をコメントかコミットメッセージに残す
- [ ] `packages/cli/src/frameworks/hono/templates.ts` に決定した方針を実装する
- [ ] 他 3 テンプレートに「内部リダイレクトの origin は `config.issuer` 由来である」ことを明示するコメントを追加し、
      意図が読み取れる状態にする（挙動は既に正しいため変更不要）
- [ ] サブパス付き `issuer`（例 `https://example.com/op`）で `/login` / `/consent` の組み立てが壊れないことを確認する
      （方針 C を採る場合はパス前置が別途必要。`study-material/issuer-multitenancy-and-subpath.md` と接続）
- [ ] 生成コードは直接編集せず `packages/cli` テンプレートを修正する

方針 A の実装例（hono ミドルウェア層）:

```ts
/**
 * リクエスト URL の origin を config.issuer に正規化する。
 *
 * OIDC Discovery 1.0 §3: OP が「自分自身」を指す URL の真実の情報源は
 * 広告した issuer であり、受信リクエストの Host ヘッダではない。
 * RFC 9700: AS はユーザーエージェントを信頼できる URI にのみ自動リダイレクトすべき。
 *
 * express / fastify テンプレートは node-adapter が baseUrl=issuer で Request を
 * 組み立て、Next.js テンプレートは rebaseRequestOrigin で同じことをしている。
 * hono も同じ不変条件（自分の origin は設定値だけで決まる）に揃える。
 */
app.use('*', async (c, next) => {
  const issuer = c.get('config')?.issuer;
  if (!issuer) return next();
  const issuerUrl = new URL(issuer);
  const requestUrl = new URL(c.req.url);
  if (requestUrl.origin === issuerUrl.origin) return next();
  requestUrl.protocol = issuerUrl.protocol;
  requestUrl.host = issuerUrl.host;
  // 以降のハンドラが正規化後の URL を見るよう Request を差し替える
  ...
});
```

## テスト要件

`packages/cli` のテンプレートテスト、および生成 OP の `conformance.test.ts`（生成元は `packages/cli`）に追加する。
アサーションは一意値で固定する。

- [ ] `should build the login redirect Location on the configured issuer origin`
      — `issuer` を `https://op.example.com` に設定した OP へ `GET /authorize` を送り、
      `Location` が `https://op.example.com/login?transaction_id=<id>` と一致すること
      （方針 C を採る場合は `/login?transaction_id=<id>` と一致すること）
- [ ] `should build the consent redirect Location on the configured issuer origin`
      — 既存セッションがある状態の `GET /authorize` で `Location` の origin が `issuer` と一致すること
- [ ] `should ignore the Host header when building the login redirect Location`
      — `Host: attacker.example` を付けた `GET /authorize` に対し、`Location` の origin が `issuer` のままであること
- [ ] `should build the consent redirect Location on the configured issuer origin after login`
      — `POST /login` 成功後の `Location` の origin が `issuer` と一致すること
- [ ] `should keep the redirect Location stable for a subpath issuer`
      — `issuer` が `https://example.com/op` のとき、`Location` のパスが `/op/login`（または方針に応じた期待値）と一致すること
- [ ] 既存の認可フロー（SSO / `prompt=none` / `prompt=login` / 同意）の `conformance.test.ts` が回帰しないこと
- [ ] `tests/e2e` の既存 Playwright フローが 4 サンプルすべてで通ること

## 完了条件

- `pnpm --filter @maronn-openid-connect/cli test` がパスすること
- `pnpm test:conformance` がパスすること
- `pnpm test:e2e` がパスすること
- `pnpm typecheck` がパスすること
- 4 テンプレートすべてで「内部リダイレクトの origin は `config.issuer` だけで決まる」ことがコードから読み取れること
- `Host` ヘッダを変えても `Location` の origin が変わらないことがテストで固定されていること
