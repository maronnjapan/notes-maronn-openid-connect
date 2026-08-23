# [P1] 認可トランザクションをユーザーエージェント（Cookie）に束縛する

## ステータス

✅ 完了（2026-08-04）

**実装時の方針変更**: 本文は束縛を無条件で入れる前提で書かれているが、実装では
**opt-in 機能（`--enable transaction-binding`）とし、既定を OFF にした**。

- この束縛を MUST/SHOULD で要求する OIDC Core / OAuth 2.1 の条文は無い（本文 §仕様参照にも
  そう書かれている）。`Fidelity` を掲げる以上、既定生成物は「仕様そのもの」に保つべきで、
  仕様非必須のハードニングは既定に含めない
- 有効時は Cookie の持ち回りが必須になるため、curl で `/authorize` → `transaction_id` を拾って
  `/login` を叩く、という **OP を手で触るときの最初の一手**が 400 で止まる。これは
  「気軽に試せる」という本リポジトリのコンセプトと正面から衝突する
- ON/OFF を切り替えて挙動差を観察できる形の方が、「この手法を検証する」という用途に合う

既定 OFF 側の「Cookie 無しでフロー全体を完走できる」挙動も、生成 `conformance.test.ts` の
契約テストとして固定している（将来これが無条件で有効化されると失敗する）。

## 背景

CLI が生成する OP は `transaction_id`（32 バイト乱数）を URL で受け渡して
`authorize` → `/login` → `/consent` と遷移させるが、**トランザクションと要求元ブラウザを結び付ける
検証がどのステップにも無い**。`AuthTransaction`（`packages/core/src/auth-transaction.ts:96-131`）にも
束縛用のフィールドが存在しない。

その結果:

1. `GET /login?transaction_id=X` と `GET /consent?transaction_id=X` は、**誰に対しても
   `csrf_token` を HTML に埋めて返す**。CSRF トークンの安全性は `transaction_id` の秘匿性に
   完全に依存しており、OWASP が求める「CSRF トークンをユーザーセッションに束縛する」を満たしていない。
2. `transaction_id` が漏れた場合（ブラウザ履歴・アクセスログ・画面共有など）、第三者が
   `GET /consent` で `csrf_token` を取得して `POST /consent` を完了させ、被害者の意思によらず
   同意を成立させられる（強制同意 / 意図しない grant 発生）。発行される認可コードは登録済み
   `redirect_uri` へ届くため、攻撃者がコードを直接受け取ることはできない。
3. 攻撃者が自分のクライアントでフローを開始して `transaction_id` を取得し、被害者を
   `/login?transaction_id=<攻撃者の>` へ誘導してログインさせると、攻撃者側が `POST /consent` を
   完了させて **攻撃者のクライアントに被害者 identity の認可コードが届く**。これは RP 側の
   `state` 検証では防げない類型で、OP 側の束縛が唯一の防御になる。

`transaction_id` / `csrf_token` はいずれも CSPRNG 由来 32 バイトで推測は現実的でないため、問題は
推測ではなく**漏洩後の悪用**である。Basic OP 認定要件ではなく、生成コードの防御深度の改善。

検討の詳細・脅威シナリオの評価・方針比較は
`study-material/done/auth-transaction-user-agent-binding.md` を参照（本タスクは実装に絞る）。

## 対象ファイル

- `packages/core/src/auth-transaction.ts`
  - `AuthTransaction`（`:96-131`）へ束縛用フィールドを追加
  - `createAuthTransaction`（`:194-200` 付近）のシグネチャ拡張
  - 新規ステップ関数 `validateTransactionBinding`
- `packages/core/src/crypto-utils.ts`（`sha256` / `timingSafeEqual` を流用）
- `packages/core/src/auth-transaction.test.ts`（TDD）
- `packages/cli/src/frameworks/hono/templates.ts`
  - authorize（`:1823` 付近のトランザクション保存箇所）で Cookie 発行
  - login / consent の GET・POST ハンドラで束縛検証
  - `store.ts` テンプレートへ Cookie ヘルパを追加
- `packages/cli/src/frameworks/web-standard/templates.ts`（同上）
- `packages/cli/src/frameworks/web-standard/templates.ts` の Next.js Server Action 版
  （`nextJsConsentActionTemplate` `:1492` 付近 / login action `:1315` 付近）
- `packages/cli` の `conformance.test.ts` 生成コード
- `tests/e2e`（別ブラウザコンテキストからの完走を拒否する E2E）
- 再生成される sample 4 種の `routes/authorize.ts` / `routes/login.ts` / `routes/consent.ts` / `store.ts`

> CLAUDE.md のルールに従い、`samples/*/src/oidc-provider` は直接編集せず `packages/cli` のテンプレートを
> 修正して再生成すること。

## 仕様参照

- **OpenID Connect Core 1.0 §3.1.2.3 / §3.1.2.4**: OP は「この認可リクエストを送ってきた User-Agent の
  End-User」を認証し、その End-User から authorization decision を取得する。**同一性を技術的に
  どう保証するかは仕様本文では規定されていない**（＝実装責務）。
  - 明確に記す: 「認可トランザクションを Cookie でブラウザに束縛せよ」という MUST/SHOULD を持つ
    OIDC Core / OAuth 2.1 の条文は特定できていない。本タスクは仕様違反の是正ではなく
    defense in depth の追加である。
- **RFC 6749 §10.12 Cross-Site Request Forgery**: 認可フローとユーザーエージェントの認証済み状態を
  結び付ける推測不能な値による対策。本実装で該当するのは `transaction_id` であり、推測耐性はあるが
  漏洩後の束縛が無い。
- **OWASP CSRF Prevention Cheat Sheet**: CSRF トークンはユーザーセッションに束縛すべきで、
  リクエストパラメータのみから再取得できる状態にしない。
  https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html
- **OWASP Session Management Cheat Sheet**: セッション識別子を URL に置かない。
  https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html

## 現状の実装

`samples/hono-cloudflare/src/oidc-provider/routes/authorize.ts:263-272`:

```ts
const csrfToken = await generateRandomString(32);
const transaction = createAuthTransaction(validatedRequest, csrfToken);
const transactionId = await generateRandomString(32);
await transactionStore.put('auth_txn:' + transactionId, transaction, 10 * 60);
...
const loginUrl = new URL('/login', c.req.url);
loginUrl.searchParams.set('transaction_id', transactionId);
return c.redirect(loginUrl.toString());   // Cookie は発行されない
```

`routes/login.ts:24-39`（GET）— `transaction_id` だけで `csrfToken` を返す:

```ts
const transaction = await getAuthTransaction(transactionId, transactionStore);
return renderView(views.loginPage({ transactionId, csrfToken: transaction.csrfToken, ... }));
```

`routes/consent.ts:47-60`（POST）— Cookie を一切見ない:

```ts
const transaction = await getAuthTransaction(transactionId, transactionStore);
validateCsrfToken(transaction, csrfToken);
...
const session = await authSessionStore.get(transactionId);   // キーは transactionId のみ
```

`AuthTransaction` に `userAgentId` / `browserSessionId` / `bindingHash` 相当のフィールドは存在しない。

## 修正方針

- [ ] 先に設計判断を確定する
  - [ ] 複数タブでの同時フローを壊さないことを要件に含めるか（含めるなら Cookie 値をトランザクション別に持つ）
  - [ ] `SameSite` の値（`Lax` / `Strict`）。RP からの初回遷移で Cookie が付くかを実測で確認する
  - [ ] 後方互換: `bindingHash` 未設定のトランザクションは検証をスキップするか、拒否するか
- [ ] core にトランザクション束縛を追加する

```ts
// packages/core/src/auth-transaction.ts
export interface AuthTransaction {
  ...
  /**
   * トランザクションを開始した User-Agent に配る秘密値のハッシュ（SHA-256, base64url）。
   * Cookie 値そのものを保存しないことで、store 漏洩だけでは横取りできないようにする。
   * 未設定のトランザクションは束縛検証をスキップする（後方互換）。
   */
  bindingHash?: string;
}

/**
 * トランザクションが、それを開始した User-Agent から提示されたものかを検証する。
 * OIDC Core 1.0 §3.1.2.3 / §3.1.2.4 は「認可リクエストの主体」と「認証・同意した End-User」の
 * 同一性を前提とするが、その保証手段は実装責務。Cookie で配った秘密値のハッシュ一致で担保する。
 */
export async function validateTransactionBinding(
  transaction: AuthTransaction,
  presentedBindingSecret: string | undefined,
): Promise<void> { ... }   // 比較は timingSafeEqual を使う
```

- [ ] `createAuthTransaction` が `bindingSecret` を受け取り `bindingHash` を設定できるようにする
- [ ] テンプレートの authorize で秘密値を生成し Cookie を発行する

```ts
const bindingSecret = await generateRandomString(32);
const transaction = createAuthTransaction(validatedRequest, csrfToken, { bindingSecret });
...
c.header('Set-Cookie', buildTransactionCookie(bindingSecret));
// __Host-oidc_txn=<secret>; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=<transaction TTL>
```

- [ ] `GET /login` / `POST /login` / `GET /consent` / `POST /consent` の各ハンドラで
      `await validateTransactionBinding(transaction, parseTransactionCookie(cookieHeader))` を
      `validateCsrfToken` の**直前**に呼ぶ（CSRF トークンを HTML に出す前に弾く必要があるため、
      GET でも呼ぶこと）
- [ ] 不一致・欠落時は `redirect_uri` へ飛ばさず、OP 自身の 400 エラーページで止める
      （どのトランザクションの持ち主か確認できていない状態でクライアントへ応答すべきではない）
- [ ] `store.ts` テンプレートに `buildTransactionCookie` / `parseTransactionCookie` を追加し、
      既存の `buildSessionCookie` / `parseSessionId` と同じ流儀に揃える
- [ ] Next.js の Server Action 版でも同じ検証を行う（Cookie 読み取り API が異なる点に注意）
- [ ] 束縛が「なぜ必要か」を生成コードのコメントに書く（本リポジトリの教材価値の維持）

## テスト要件

core（`packages/core/src/auth-transaction.test.ts`）:

- [ ] `should accept a transaction when the presented binding secret matches the stored hash`
- [ ] `should reject a transaction when the presented binding secret does not match`
- [ ] `should reject a transaction when no binding secret is presented`
- [ ] `should skip binding validation when the transaction has no bindingHash`（後方互換）
- [ ] `should store only the hash and never the raw binding secret in the transaction`

`packages/cli` の conformance.test.ts 生成コード:

- [ ] `should return 400 for GET /consent without the transaction binding cookie`
- [ ] `should not expose the csrf token for GET /login without the transaction binding cookie`
- [ ] `should not issue an authorization code for POST /consent without the transaction binding cookie`
- [ ] `should not issue an authorization code for POST /consent with another transaction's binding cookie`
- [ ] `should issue an authorization code for the normal flow with a valid binding cookie`（回帰確認）

`tests/e2e`:

- [ ] 別のブラウザコンテキストから `transaction_id` を使って consent を完了できないこと
- [ ] 通常のログイン→同意→コード受領の E2E が回帰しないこと
- [ ] （複数タブ対応を要件に含めた場合）2 つのタブで同時に別クライアントの認可フローを完走できること

## 完了条件

- `pnpm --filter @maronn-openid-connect/core test` と `pnpm --filter @maronn-openid-connect/cli test` がパスすること
- 4 sample を再生成し `pnpm test` と `tests/e2e` がパスすること
- `transaction_id` のみでは login / consent のどのステップも進行できないこと
- `study-material/done/csrf-token-constant-time-comparison.md` に、CSRF トークンの束縛先に関する
  追記または本タスクへの参照が入っていること
