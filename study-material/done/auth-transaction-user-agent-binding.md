# 認可トランザクションがユーザーエージェントに束縛されていない（`transaction_id` 単独で login / consent を進行できる）

## ステータス

🟠 High（セキュリティ / 生成コード）/ 未着手

## 1. このトピックで確認したいこと

CLI が生成する OP は、認可リクエストを受けると `transaction_id`（32 バイト乱数）を発行し、
`/login?transaction_id=...` → `/consent?transaction_id=...` と画面遷移させる。

このとき **`transaction_id` を知っているだけで、認可リクエストを開始したブラウザとは別のユーザー
エージェントからでも login / consent の各ステップを進行できる**。トランザクションとブラウザ
（OP セッション Cookie）を結び付ける検証が、どのステップにも存在しない。

確認したいのは次の点である。

1. OIDC / OAuth の仕様が、認可トランザクションと End-User の User-Agent の束縛について何を要求するか
2. 現在の生成コードで、どのステップが `transaction_id` だけで進行できるか
3. 束縛が無いことで成立する具体的なシナリオと、その現実的な影響度
4. 束縛を導入する場合、`AuthTransaction` / store 契約にどのような変更が必要か

本ファイルは以下とは別の論点である（重複説明はしない）。

- CSRF トークンの比較方法: `study-material/done/csrf-token-constant-time-comparison.md`
- ブラウザ（OP）セッションと SSO の成立: `study-material/done/cli-generated-provider-browser-session-and-sso.md`
- 認可コード自体の single-use / 再利用検知: `study-material/done/authorization-code-reuse-cascade-store-semantics.md`

## 2. 関連する仕様・基準

共通の仕様索引は `study-material/basic-op-requirement-traceability.md` §3.3 を参照。

### 2.1 OpenID Connect Core 1.0 §3.1.2.3 / §3.1.2.4

- §3.1.2.3（Authorization Server Authenticates End-User）: OP は End-User を認証するか、既に認証済みで
  あるかを判定する。判定の対象は「**この認可リクエストを送ってきた User-Agent の End-User**」である。
- §3.1.2.4（Authorization Server Obtains End-User Consent/Authorization）: 情報を RP へ渡す前に
  authorization decision を取得しなければならない（MUST）。

いずれも「認証した End-User」「決定した End-User」と「認可リクエストの主体」が同一であることを前提に
書かれているが、**その同一性をどう技術的に保証するか（トランザクションと User-Agent の束縛）は
仕様本文では規定されていない**。これは OP 実装の責務として残されている。

> 明確に記しておく: 「認可トランザクションを Cookie でブラウザに束縛せよ」という MUST/SHOULD を持つ
> OIDC Core / OAuth 2.1 の条文は、本調査の範囲では特定できなかった。本ファイルは **仕様違反の指摘では
> なく、実装上の安全策（defense in depth）としての検討**である。

### 2.2 RFC 6749 §10.12（Cross-Site Request Forgery）

RFC 6749 §10.12 は CSRF について、攻撃者が被害者のブラウザに「攻撃者に紐づく認可フロー」を完了させる
クラスの攻撃を扱い、**「認可リクエストとユーザーエージェントの認証済み状態を結び付ける、推測不能な値」**
による対策を求めている。RFC 6749 が主に想定しているのはクライアント側の `state` だが、同じ論法は
OP 内部の多段フロー（authorize → login → consent）にも当てはまる。本実装で「推測不能な値」に相当するのは
`transaction_id`（32 バイト乱数）であり、**推測は現実的でない**。したがって残る問題は推測ではなく
**漏洩後の悪用**である。

### 2.3 OWASP（Session Management / CSRF）

- OWASP Session Management Cheat Sheet: セッション識別子を URL に載せない（Referer・履歴・ログ経由の漏洩）
- OWASP CSRF Prevention Cheat Sheet: CSRF トークンは**ユーザーセッションに束縛**すべきであり、
  リクエストパラメータのみから再取得できる状態にしない

現在の実装では `csrf_token` は `AuthTransaction` に保存されており、`GET /login?transaction_id=X` および
`GET /consent?transaction_id=X` が **その `csrf_token` を HTML に埋めて返す**。つまり `transaction_id` を
知っている者は誰でも `csrf_token` を取得できるため、CSRF トークンの安全性は完全に
「`transaction_id` の秘匿性」に依存している。

## 3. 参照資料

- OpenID Connect Core 1.0 incorporating errata set 2 §3.1.2.3 / §3.1.2.4 —
  https://openid.net/specs/openid-connect-core-1_0.html#Authenticates
  https://openid.net/specs/openid-connect-core-1_0.html#Consent
- RFC 6749 §10.12 Cross-Site Request Forgery — https://www.rfc-editor.org/rfc/rfc6749#section-10.12
- OWASP Cross-Site Request Forgery Prevention Cheat Sheet —
  https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html
  （「CSRF トークンはユーザーセッションに束縛する」の根拠）
- OWASP Session Management Cheat Sheet —
  https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html
  （セッション識別子を URL に置かない、の根拠）
- 本リポジトリ内:
  - `samples/hono-cloudflare/src/oidc-provider/routes/authorize.ts:263-272`（transaction 生成・保存）
  - `samples/hono-cloudflare/src/oidc-provider/routes/login.ts:24-39`（GET: csrfToken を HTML に出力）
  - `samples/hono-cloudflare/src/oidc-provider/routes/login.ts:44-116`（POST: Cookie 検証なし）
  - `samples/hono-cloudflare/src/oidc-provider/routes/consent.ts:25-41,47-60`（同上）
  - `packages/core/src/auth-transaction.ts:96-131`（`AuthTransaction` に束縛用フィールドが無い）

## 4. 現在の実装確認

### 4.1 トランザクションの生成（authorize）

`routes/authorize.ts`:

```ts
const csrfToken = await generateRandomString(32);
const transaction = createAuthTransaction(validatedRequest, csrfToken);
const transactionId = await generateRandomString(32);
await transactionStore.put('auth_txn:' + transactionId, transaction, 10 * 60);
...
const loginUrl = new URL('/login', c.req.url);
loginUrl.searchParams.set('transaction_id', transactionId);
return c.redirect(loginUrl.toString());
```

この時点で **Cookie は発行されていない**（Cookie が発行されるのはログイン成功後）。したがって
「このトランザクションを開始したブラウザ」を後から識別する手掛かりが OP 側に一切残らない。

### 4.2 `AuthTransaction` の構造（`packages/core/src/auth-transaction.ts:96-131`）

```ts
export interface AuthTransaction {
  clientId: string; redirectUri: string; redirectUriExplicit: boolean;
  responseType: string; scope: string; state?: string;
  nonce?: string; codeChallenge?: string; codeChallengeMethod?: 'S256';
  prompt?: string; maxAge?: number; acrValues?: string; loginHint?: string;
  uiLocales?: string; claimsLocales?: string; idTokenHint?: string;
  audience?: string[]; claims?: ClaimsParameter;
  csrfToken: string; createdAt: number; expiresAt: number; failedAttempts: number;
}
```

`userAgentId` / `browserSessionId` / `deviceId` に相当するフィールドは **存在しない**。

### 4.3 各ステップの検証内容

| ステップ | 検証している | 検証していない |
|---|---|---|
| `GET /login?transaction_id=` | transaction の存在・有効期限 | 要求元ブラウザ（Cookie なし）。**`csrfToken` を HTML に出力する** |
| `POST /login` | `validateCsrfToken`、資格情報 | 要求元ブラウザ。ログイン成功時に初めて Cookie を発行 |
| `GET /consent?transaction_id=` | transaction の存在・有効期限 | 要求元ブラウザ。**`csrfToken` を HTML に出力する** |
| `POST /consent` | `validateCsrfToken`、`authSessionStore.get(transactionId)` の存在 | 要求元ブラウザ。`authSessionStore` は `transactionId` のみをキーにしており、Cookie と突き合わせない |

`authSessionStore` は「ログイン済み subject の受け渡し」を `transactionId` だけで行っている
（`login.ts` で `set(transactionId, { subject, authTime })`、`consent.ts` で `get(transactionId)`）。

### 4.4 影響範囲

4 つの sample すべて（`hono-cloudflare` / `express-flyio` / `fastify-flyio` / `nextjs-vercel`）と
CLI テンプレート 2 種（`frameworks/hono/templates.ts`、`frameworks/web-standard/templates.ts`）が同一構造。

## 5. 現在の実装との差分

満たしていること:

- ✅ `transaction_id` / `csrf_token` はいずれも CSPRNG 由来の 32 バイト（`generateRandomString(32)`）で、
  **推測（オンライン総当たり）は現実的でない**
- ✅ 外部サイトからの純粋な CSRF（`transaction_id` も `csrf_token` も知らない攻撃者）は成立しない
- ✅ ログイン成功後は OP セッション Cookie が発行され、以降の認可リクエストの SSO はその Cookie で判定される

不足している可能性があること:

- 🟠 **トランザクション横取り（漏洩後の悪用）**: `transaction_id` は URL に載るため、ブラウザ履歴・
  リバースプロキシ／CDN のアクセスログ・画面共有・アドレスバーのスクリーンショット等から漏れうる。
  漏れた `transaction_id` があれば、第三者は
  1. `GET /consent?transaction_id=X` で `csrf_token` を取得し、
  2. `POST /consent` を実行して、被害者が認証済みのトランザクションを完了させられる。

  ただし発行される認可コードは **登録済み `redirect_uri` へ届く**ため、攻撃者がコードを直接受け取ることは
  できない。実害は「被害者の意思によらず同意が成立し、クライアントに認可が付与される」ことに限定される
  （＝強制同意 / 意図しない grant 発生）。
- 🟠 **クロスブラウザでのフロー完走**: 攻撃者が自分のクライアントで認可フローを開始して `transaction_id`
  を取得し、被害者を `/login?transaction_id=<攻撃者の>` へ誘導してログインさせると、攻撃者側が
  `POST /consent` を完了させて **攻撃者のクライアントに被害者の identity の認可コードが届く**。
  これは RP 側の `state` 検証（RFC 6749 §10.12）では防げない類型で、OP 側でトランザクションを
  ブラウザに束縛していれば「ログインしたブラウザ以外は consent を完了できない」ため成立しない。

  > 影響度の評価（推測と区別して記す）: このシナリオはフィッシング的な誘導を要し、かつ被害者が
  > 見慣れない同意画面を経ずに完了する必要がある。**現実的な悪用難易度は低くない**が、多くの
  > 商用 OP がトランザクションを Cookie に束縛しているのは、まさにこの類型を塞ぐためである。
  > 本リポジトリでこの脅威をどこまで重く扱うかは人間の判断事項とする。
- 🟡 **CSRF トークンが実質的に無力化されている**: `GET /login` / `GET /consent` が `csrf_token` を
  `transaction_id` だけで返すため、CSRF トークンは `transaction_id` 以上の防御を提供していない。
  OWASP が求める「ユーザーセッションへの束縛」を満たしていない。
- 🟡 **`transaction_id` が URL に載る**: OWASP Session Management Cheat Sheet の「セッション識別子を
  URL に置かない」に反する形。ただし OP の login/consent 画面は外部リソースを読み込まないため、
  Referer 経由の他サイトへの漏洩は現状は起きにくい（`Referrer-Policy` の設定自体は
  `study-material/http-security-headers-and-tls.md` の範疇）。

Basic OP として提供する上で確認すべきこと:

- Basic OP 認定テストにこの束縛を検証する module は無く、**認定可否には影響しない**。
  本件は認定要件ではなく、生成コードの防御深度の論点である。

## 6. 改善・追加を検討する理由

- **なぜ価値があるか**: 本リポジトリは「PoC 開発者・本番導入を見据える開発者」を対象にしており
  （CLAUDE.md）、生成コードがそのまま本番の骨格になる可能性がある。トランザクションのブラウザ束縛は
  商用 OP では標準的な実装であり、これが無いと「検証で使った構成をそのまま本番に持ち込むと危ない」
  という、利用者が気づきにくい落とし穴を残す。
- **Basic OP に必要か / 拡張か**: 認定要件ではない。**セキュリティ既定値の強化**として位置づけられる。
- **導入しやすさ**: 🟡 中程度。`AuthTransaction` に 1 フィールド追加し、authorize で「トランザクション
  束縛用 Cookie」を発行、login / consent の各ハンドラで突き合わせる。core の型変更を伴うため、
  後方互換（フィールド未設定時は検証をスキップ）の扱いを決める必要がある。
- **既存実装との接続**: 既に `buildSessionCookie` / `parseSessionId`（`store.ts`）という Cookie の
  読み書きヘルパがあるため、同じ流儀で「トランザクション Cookie」を足せる。
  `validateCsrfToken` の隣に `validateTransactionBinding` を並べる形が既存のステップ関数思想と整合する。
- **利用者・開発者のメリット**: 「なぜ Cookie 束縛が要るのか」を生成コードのコメントで学べる。
  この設計は OP を自作する際に最も落としやすい箇所の一つで、教材価値が高い。
- **実装しない場合に残るリスク**: 上記の強制同意・クロスブラウザ完走の経路が残る。加えて、
  CSRF トークンが「見た目は有るが実質 `transaction_id` と同値」という状態が説明されないまま残り、
  セキュリティレビューを受ける利用者が誤解する。

## 7. 実装方針の候補

最終判断は人間が行う。

### 方針A: 認可トランザクション専用の短命 Cookie を発行して束縛する（推奨候補）

1. `authorize` で `transactionBindingSecret = generateRandomString(32)` を生成
2. `AuthTransaction` に `bindingHash?: string`（`sha256(secret)`）を保存
   （Cookie 値そのものを store に置かないことで、store 漏洩時に横取りできないようにする）
3. `Set-Cookie: __Host-oidc_txn=<secret>; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=600`
   （`SameSite=Lax` は OP 内の遷移が GET リダイレクト主体のため機能する。`Strict` にすると
   RP からの初回遷移で Cookie が付かないケースがあるため要検証）
4. `GET/POST /login`、`GET/POST /consent` の各ハンドラで
   `sha256(cookie) === transaction.bindingHash` を **定数時間比較**で検証。不一致・欠落なら 400

- 長所: 上記シナリオの両方を塞ぐ。CSRF トークンが本来の「セッション束縛トークン」として機能する
- 短所: Cookie が 1 つ増える。`SameSite` の値と、複数タブで同時に別の認可フローを走らせた場合の
  挙動（Cookie を上書きすると先行タブが壊れる）を設計する必要がある

### 方針A': 方針A に加え、複数同時フローに対応する

Cookie 値を単一の secret ではなく `transactionId → secret` のマップ（または Cookie 名に
`transactionId` の先頭数文字を含める）にすることで、タブ並行を壊さない。

- 長所: 実運用（複数タブ）で壊れない
- 短所: 実装が増え、Cookie サイズ管理が必要。PoC 向けライブラリとして過剰かどうかは判断事項

### 方針B: ログイン成功後のみ束縛する（部分適用）

`login` で発行される既存のブラウザセッション Cookie を、`authSessionStore` のキーに含める
（`authSessionStore.set(transactionId + ':' + sessionId, ...)`）。

- 長所: 変更が `login.ts` / `consent.ts` に閉じる。core の型変更が不要
- 短所: `GET /login` 段階の `csrf_token` 漏洩は塞げない。強制同意シナリオのうち
  「被害者ログイン済み → 攻撃者が consent を完了」は塞げるが、クロスブラウザ誘導は塞げない

### 方針C: 束縛は入れず、ドキュメントで明示する

- 長所: コスト 0
- 短所: 「生成コードをそのまま本番へ」の利用者を守れない。本リポジトリの Fidelity の看板と整合しない

### 方針D: `transaction_id` を URL から外し、Cookie のみで受け渡す

- 長所: URL 漏洩の経路そのものが消える
- 短所: 複数タブが原理的に壊れる。OIDF Conformance Suite の手動操作フローとの相性も要検証

## 8. タスク案

- [ ] 方針（A / A' / B / C / D）を決定する（人間判断）。特に「複数タブ同時フローを壊さないこと」を
      要件に含めるかを先に決める
- [ ] 脅威の影響度評価を確定する: 「強制同意」「クロスブラウザ完走」のそれぞれについて、
      本リポジトリの想定利用（PoC 検証）でどこまで重く扱うかを記録する
- [ ] 方針A系を選ぶ場合:
  - [ ] `packages/core/src/auth-transaction.ts` の `AuthTransaction` に `bindingHash?: string` を追加し、
        `createAuthTransaction` のシグネチャを拡張する（未指定時は従来動作＝検証なし、で後方互換を保つ）
  - [ ] `validateTransactionBinding(transaction, cookieValue)` をステップ関数として core に追加する
        （比較は既存の `timingSafeEqual` を使う）
  - [ ] `packages/cli` のテンプレート（`frameworks/hono/templates.ts` / `frameworks/web-standard/templates.ts`）
        の authorize / login / consent に Cookie 発行と検証を組み込む
  - [ ] `store.ts` テンプレートに `buildTransactionCookie` / `parseTransactionCookie` を追加する
- [ ] `packages/cli` の conformance.test.ts 生成コードに契約テストを追加する
      （CLAUDE.md: conformance.test.ts は生成側を変更する）
      - [ ] トランザクション Cookie を付けずに `POST /consent` → 認可コードが発行されないこと
      - [ ] 別のトランザクションの Cookie を付けて `POST /consent` → 認可コードが発行されないこと
      - [ ] 正しい Cookie を付けた通常フロー → 従来どおり認可コードが発行されること
- [ ] `tests/e2e` に「別ブラウザコンテキストから consent を完了できない」E2E を追加する
      （CLAUDE.md: 実ブラウザで検証できるものは Playwright E2E を追加する方針）
- [ ] 4 sample を再生成し、`pnpm test` と E2E がパスすることを確認する
- [ ] `study-material/done/csrf-token-constant-time-comparison.md` に「CSRF トークンの束縛先」に関する
      追記または本ファイルへの参照を入れる
