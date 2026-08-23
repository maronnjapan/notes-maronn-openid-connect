# 生成 OP の内部リダイレクト（`/login` / `/consent`）の origin 導出がフレームワーク間で非一貫（hono テンプレートだけリクエスト URL 由来）

## ステータス

🟠 High（セキュリティ・移植性・テンプレート間一貫性）/ 未着手

## 1. このトピックで確認したいこと

生成 OP は Authorization Endpoint から `/login` / `/consent` へ **絶対 URL の 302 リダイレクト**で遷移する。
この絶対 URL の origin（scheme + host）を **何から導出しているか**が、CLI が生成する 4 つのフレームワークテンプレートで揃っていない。

- express / fastify / Next.js の各テンプレート: リクエストの origin を **設定値 `config.issuer` に正規化してから** OIDC ハンドラへ渡す
- hono テンプレート: 正規化せず、**ランタイムが組み立てたリクエスト URL（＝ `Host` ヘッダ由来）をそのまま使う**

つまり同じ生成物であるはずの OP が、hono を選んだときだけ「内部リダイレクトの飛び先を **リクエストヘッダが決める**」挙動になる。
本ファイルでは以下を確認・整理する。

- この非一貫が仕様上どう位置づけられるか（MUST 違反か、ハードニングか）
- 実害がどのデプロイ形態で顕在化するか（Cloudflare Workers / Node・Bun 上の hono / リバースプロキシ配下）
- 既存の防御（トランザクション束縛 Cookie）でどこまで塞がれ、どこが残るか
- 4 テンプレートで導出元を揃えるとしたらどの方針が妥当か

### 既存ファイルとの差分（重複回避）

| 論点 | 扱っているファイル |
|---|---|
| `redirect_uri`（クライアントへ返す認可レスポンス先）の登録・完全一致・危険スキーム | `tasks/done/p1-redirect-uri-dangerous-scheme-rejection.md`、`tasks/done/p0-redirect-uri-fragment-rejection.md`、`study-material/redirect-uri-required-oidc-authentication-request.md` |
| `transaction_id` を持つブラウザの本人性確認（束縛 Cookie） | `study-material/done/auth-transaction-user-agent-binding.md`、`tasks/done/p1-auth-transaction-user-agent-binding.md` |
| issuer 値そのものの検証（https / query / fragment） | `packages/core/src/discovery.ts` の `validateIssuer`、`tasks/p3-discovery-endpoint-url-validation.md` |
| issuer をサブパス・マルチテナントで運用する設計 | `study-material/issuer-multitenancy-and-subpath.md` |
| Web 標準 API のみでフレームワーク移植性を保つ設計 | `study-material/cli-framework-portability-and-web-standard-handler.md` |

本ファイルは上記のいずれとも異なり、「**OP が自分自身へ飛ばす内部リダイレクトの origin を、設定値とリクエストヘッダのどちらから採るか**」だけを論点にする。
クライアントへ返す `redirect_uri` の検証は既に堅牢で、本トピックの対象外。

## 2. 関連する仕様・基準（このトピック固有の差分）

### 2.1 OIDC Core 1.0 §3.1.2.1 — Authorization Endpoint と `issuer` の関係

Authorization Endpoint の URL は Discovery の `authorization_endpoint` として広告され、その `issuer` は
OIDC Discovery 1.0 §3 で「`iss` クレームと一致する URL」と定義される。
OP が「自分自身」を指す URL を組み立てる場面では、**広告した値（設定）が真実の情報源**であり、
受信リクエストのヘッダは真実の情報源ではない。仕様は「内部リダイレクトの origin を issuer にせよ」と直接は書いていないが、
`iss` / `authorization_endpoint` / 実際に稼働している origin が食い違う状態は §3 の一貫性前提から外れる。

### 2.2 RFC 9700（OAuth 2.0 Security BCP）— リダイレクトの取り扱い

RFC 9700 は「AS はユーザーエージェントを **信頼できる URI にのみ**自動リダイレクトすべき」と述べる（MCP 認可仕様もこの要件を AS へ SHOULD として引いている）。
`Host` ヘッダから組み立てた origin は、その値が信頼できるかを AS が検証していない限り「信頼できる URI」の定義を満たさない。

### 2.3 RFC 9110 §10.2.2 — `Location` は相対参照でよい

HTTP セマンティクス（RFC 9110）は `Location` フィールド値に **相対参照を許容**する（RFC 7231 以降の変更点）。
したがって「絶対 URL を組み立てる」こと自体が必須ではなく、`Location: /consent?transaction_id=...` で十分に仕様適合する。
これは origin 導出問題を根本から消す選択肢になる（方針 C）。

### 2.4 `Host` ヘッダの信頼性はランタイム依存（事実の切り分け）

- **Cloudflare Workers**: Worker はアカウントに紐づくルート／カスタムドメインでのみ発火するため、**任意の攻撃者ホストを `Host` に入れて到達させることは通常できない**。ただし「`*.workers.dev` の既定ホスト名」と「カスタムドメイン」の**両方**が有効な構成では、ユーザーが `workers.dev` 側から入ってきたときに内部リダイレクトが `workers.dev` 側に留まり、`issuer` / Discovery / ID Token の `iss` が指す origin と食い違う。
- **Node / Bun / Deno 上の hono（`@hono/node-server` など）**: `c.req.url` は受信した `Host` ヘッダから組み立てられる。前段のプロキシが `Host` を固定していなければ、**クライアントが指定した任意のホスト名**がそのまま origin になる。
- **リバースプロキシ / CDN 配下**: 公開ホスト名と内部ホスト名が異なる構成（`https://op.example.com` → `http://10.0.0.5:8080`）では、内部ホスト名が `Location` に露出してフローが壊れる。

この 3 つは「同じコードでも運用形態で結論が変わる」ため、**ランタイムに依存しない導出元**を選ぶことに価値がある。

## 3. 参照資料

- OpenID Connect Discovery 1.0 §3 Provider Metadata（`issuer` / `authorization_endpoint` の定義） — https://openid.net/specs/openid-connect-discovery-1_0.html#ProviderMetadata
- OpenID Connect Core 1.0 §3.1.2 Authorization Endpoint — https://openid.net/specs/openid-connect-core-1_0.html#AuthorizationEndpoint
- RFC 9700 Best Current Practice for OAuth 2.0 Security（リダイレクト先の信頼、オープンリダイレクト） — https://www.rfc-editor.org/rfc/rfc9700
- RFC 9110 HTTP Semantics §10.2.2 Location — https://www.rfc-editor.org/rfc/rfc9110#field.location
- RFC 6265bis（draft-ietf-httpbis-rfc6265bis）§4.1.3 Cookie 名プレフィックス（Cookie が host-only である前提の確認用） — https://datatracker.ietf.org/doc/draft-ietf-httpbis-rfc6265bis/

## 4. 現在の実装確認

### 4.1 内部リダイレクトの組み立て（4 テンプレート共通のロジック）

`packages/cli/src/frameworks/hono/templates.ts`（生成結果は `samples/*/src/oidc-provider/routes/*.ts`）:

```ts
// authorize ルート: 同意画面へ
const consentUrl = new URL('/consent', c.req.url);
consentUrl.searchParams.set('transaction_id', transactionId);
return c.redirect(consentUrl.toString());

// authorize ルート: ログイン画面へ
const loginUrl = new URL('/login', c.req.url);
loginUrl.searchParams.set('transaction_id', transactionId);
return c.redirect(loginUrl.toString());

// login ルート: 認証後の同意画面へ
const consentUrl = new URL('/consent', c.req.url);
```

生成結果の該当箇所:

- `samples/hono-cloudflare/src/oidc-provider/routes/authorize.ts:650, 662`
- `samples/hono-cloudflare/src/oidc-provider/routes/login.ts:170`
- `samples/express-flyio/src/oidc-provider/routes/authorize.ts:486, 494`、`routes/login.ts:113`
- `samples/fastify-flyio/src/oidc-provider/routes/authorize.ts:486, 494`、`routes/login.ts:113`
- `samples/nextjs-vercel/src/app/_oidc-provider/routes/authorize.ts:486, 494`、`routes/login.ts:113`

ルート側のコードは 4 テンプレートで同一である。差が出るのは **`c.req.url` に何が入るか**を決める前段（アダプタ層）。

### 4.2 アダプタ層：express / fastify は issuer に正規化している

`samples/express-flyio/src/oidc-provider/apply.ts:22-33`

```ts
export function applyOidc(app: Express, options: ApplyOidcOptions): void {
  const oidc = createApp(options);
  const baseUrl = options.config?.issuer ?? 'http://localhost';   // ← 設定値が origin
  for (const endpoint of OIDC_ENDPOINTS) {
    app.use(endpoint, async (req, res, next) => {
      const response = await oidc.request(toWebRequest(req, baseUrl));
      ...
```

`samples/express-flyio/src/oidc-provider/node-adapter.ts:4-11`

```ts
export function toWebRequest(incoming, baseUrl = 'http://localhost', bodyOverride?) {
  const path = incoming.originalUrl ?? incoming.url ?? '/';
  const url = new URL(path, baseUrl);   // ← path のみ採用、origin は baseUrl
```

`Host` ヘッダは `headers` にコピーされるだけで **URL 組み立てには使われない**。fastify テンプレートも同一（`apply.ts:29`）。

### 4.3 アダプタ層：Next.js も issuer に正規化している

`samples/nextjs-vercel/src/app/_oidc-provider/next.ts:24-41`

```ts
function rebaseRequestOrigin(request: Request, issuer: string | undefined): Request {
  if (!issuer) return request;
  const issuerUrl = new URL(issuer);
  const requestUrl = new URL(request.url);
  if (requestUrl.origin === issuerUrl.origin) return request;
  requestUrl.protocol = issuerUrl.protocol;
  requestUrl.host = issuerUrl.host;      // ← issuer の host に付け替える
  ...
```

### 4.4 アダプタ層：hono だけ正規化していない

`samples/hono-cloudflare/src/oidc-provider/apply.ts` / `app.ts` を通しても、
`config.issuer` は Discovery メタデータ・`iss` クレーム・`corsOrigins` にしか使われず、
**リクエスト URL の origin を書き換える処理は存在しない**（`rebase` / `baseUrl` 相当の識別子が無い）。
したがって `c.req.url` はランタイムが受け取った URL そのままである。

## 5. 現在の実装との差分

### 満たしていること

- クライアントへ返す `redirect_uri` は登録済み URI との完全一致で検証されており、本トピックの経路とは独立に堅牢。
- `/login` / `/consent` はいずれも **OP 自身のパス固定**（`new URL('/consent', base)` の第 1 引数がリテラル）であり、
  リクエストパラメータからパスを組み立ててはいない。したがって**任意 URL へのオープンリダイレクトにはならない**。
  影響は「origin だけが想定と違う場所になる」ことに限定される。
- express / fastify / Next.js は設定値由来で正規化済みであり、`Host` ヘッダ注入の影響を受けない。
- トランザクション束縛 Cookie（`tasks/done/p1-auth-transaction-user-agent-binding.md`）が導入済みのため、
  `transaction_id` を第三者が入手しても **その第三者のブラウザでは `/consent` を完遂できない**（Cookie は OP の origin に host-only で紐づく）。

### 不足している可能性があること

- **テンプレート間の非一貫**: 4 つのうち 1 つだけ導出元が違う。利用者は「hono を選んだ場合だけリバースプロキシ設定に注意が必要」という事実をどこからも知らされない（README・生成コードのコメント・`conformance.test.ts` のいずれにも記述が無い）。
- **`Host` 由来 origin の信頼**: Node / Bun 上の hono では、前段で `Host` を固定していなければ攻撃者が origin を選べる。
  `Location` に `transaction_id` が乗るため、**`transaction_id` の第三者への漏洩**と、
  **ログイン途中のユーザーを攻撃者ホストへ着地させる（フィッシング面の提供）**が成立しうる。
- **公開ホスト ≠ 内部ホストのデプロイで壊れる**: 内部ホスト名が `Location` に出るとブラウザが辿れず、認可フローがログイン画面手前で止まる。
  これは「どこでも動く」という Portability 軸の主張に対する実害。

### 実装はあるが仕様上の確認が必要なこと

- Cloudflare Workers 単体では攻撃者 Host が成立しにくい。「hono テンプレート＝危険」ではなく
  「**hono テンプレートの安全性が配置先の性質に依存している**」が正確な表現であり、この差を文書化する必要がある。

### Basic OP として提供する上で確認すべきこと

- Basic OP 認定は `/login` / `/consent` という OP 内部の遷移を規定しないため、**認定ブロッカーではない**。
- ただし認定テストは OP を「広告した `issuer` の origin」で操作するため、
  内部リダイレクトが別 origin に飛ぶ構成では、認定実行時にブラウザ側の Cookie が付かず**テストが不安定になりうる**。

## 6. 改善・追加を検討する理由

- **一貫性が最大の理由**: 同じ CLI から生成した OP が、フレームワークによってセキュリティ前提を変えるのは、利用者が仕様検証に集中できない。
  すでに 3 つのテンプレートが「issuer に正規化する」という結論を出しているので、**残り 1 つを揃えるだけ**で判断が統一される。
- **修正コストが小さい**: 既存の `rebaseRequestOrigin`（Next.js テンプレート）と同型の処理を hono のミドルウェア層に置くか、
  ルート側の `new URL(path, c.req.url)` を `new URL(path, config.issuer)` に変えるだけ。core への変更は不要。
- **セキュリティ**: 「設定値だけで自分の origin が決まる」という不変条件が立つと、`Host` / `X-Forwarded-Host` の扱いを
  利用者が個別に検討しなくてよくなる。OSS の利用者にとって「前段の設定次第で安全性が変わる」実装は事故源。
- **運用**: リバースプロキシ・CDN・カスタムドメイン移行という、サンプルが想定する 4 つのデプロイ先すべてで起こりうる構成に耐える。
- **実装しない場合に残る制約**: hono 生成 OP を非 Cloudflare（Node / Bun / 自前プロキシ配下）で運用する利用者は、
  自力で `Host` の固定または `Location` の書き換えを行う必要があり、その必要性が文書化されていない。

## 7. 実装方針の候補

### 方針 A：hono テンプレートに origin 正規化ミドルウェアを追加（Next.js テンプレートと同型）

`createApp` / `applyOidc` の先頭で、`config.issuer` と origin が異なるリクエストを
issuer の origin に付け替えた `Request` に差し替えてから下流へ渡す。

- 利点: ルート側のコードを一切変えずに済む。Next.js テンプレートに前例がありレビューが容易。3 テンプレートと導出元が一致する。
- 欠点: hono の `Request` 差し替えが Workers / Node / Bun のいずれでも同じ意味で動くか要検証。`c.req.url` を参照する他の箇所（`collectUniqueParams` など）にも影響が及ぶ（原則として望ましい影響だが回帰確認が必要）。

### 方針 B：ルート側で `config.issuer` を base にする

`new URL('/consent', c.req.url)` を `new URL('/consent', c.get('config').issuer)` に変更する（3 箇所）。

- 利点: 変更点が局所的で、影響範囲が「内部リダイレクトの組み立て」だけに閉じる。
- 欠点: 4 テンプレートすべてで同じ変更が必要（express 等は現状すでに issuer 由来なので結果は変わらないが、コードの意図は明確になる）。`c.req.url` を使う他の箇所は Host 由来のまま残る。

### 方針 C：`Location` を相対参照にする

`return c.redirect('/consent?transaction_id=' + encodeURIComponent(transactionId))` のように origin を持たせない。

- 利点: origin 導出問題そのものが消える。RFC 9110 §10.2.2 に適合。どのランタイム・どのプロキシ構成でも壊れない。
- 欠点: 「OP が自分の origin を知っている」という表明が弱くなり、サブパス配置（`issuer` にパスが含まれる構成、`study-material/issuer-multitenancy-and-subpath.md`）ではパス前置が別途必要。

### 方針 D：文書化のみ（実装は変更しない）

hono テンプレートの前提（`Host` を前段で固定すること）を README と生成コードのコメントに明記する。

- 利点: 挙動変更ゼロ。
- 欠点: テンプレート間の非一貫は残る。利用者側の設定ミスに依存する安全性は OSS として弱い。

**推奨の材料**: 方針 A と C は排他ではない。サブパス配置を将来サポートするなら A（issuer 由来）が素直で、
最小の壊れにくさを取るなら C。方針 B は A の簡易版。最終判断は人間が行う。

## 8. タスク案

- [ ] hono テンプレートの内部リダイレクト origin を `config.issuer` 由来に統一する方針（A / B / C）を決定する
- [ ] 決定した方針を `packages/cli/src/frameworks/hono/templates.ts` に実装する（生成物の `samples/*` は直接編集しない）
- [ ] 他 3 テンプレートについても「導出元は `config.issuer`」であることをコード上に明示（コメントまたは同型の実装）し、意図が読み取れる状態にする
- [ ] `samples/*/conformance.test.ts` の生成元（`packages/cli`）に、内部リダイレクトの `Location` が `config.issuer` の origin を指すことを固定する契約テストを追加する
- [ ] `Host: attacker.example` を付けた `GET /authorize` に対して、`Location` の origin が `issuer` のままであることを検証するテストを追加する（hono テンプレート）
- [ ] サブパス付き `issuer`（例 `https://example.com/op`）での `/login` / `/consent` の組み立てが壊れないことを確認する（`study-material/issuer-multitenancy-and-subpath.md` と接続）
- [ ] README または生成コードのコメントに、リバースプロキシ配下で公開ホスト名と内部ホスト名が異なる場合の前提を記載する
