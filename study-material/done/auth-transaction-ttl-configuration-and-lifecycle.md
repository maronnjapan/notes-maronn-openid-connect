# 認可トランザクションの TTL が二重にハードコードされ、設定できない（`authorizationCodeTtl` との非対称）

## ステータス

🟡 Medium（相互運用性 / 生成コードの一貫性）/ 未着手

## 1. このトピックで確認したいこと

認可トランザクション（`AuthTransaction`）の寿命は、次の **2 箇所で独立にハードコード** されている。

1. `packages/core/src/auth-transaction.ts:179` — `DEFAULT_TTL_MS = 600_000`
   （`createAuthTransaction` が `transaction.expiresAt` を計算するために使う）
2. 生成コードの `routes/authorize.ts:271` — `10 * 60`
   （`transactionStore.put(key, transaction, ttlSeconds)` に渡すストア側の TTL）

両者は「同じ 10 分」であることを前提に書かれているが、**型でも設定でも結び付いていない**。
片方だけを変えると、`expiresAt` とストアの実効寿命が食い違う。

また、認可コードの TTL は `ProviderConfig.authorizationCodeTtl` として設定可能になっている
（`tasks/done/p2-auth-code-ttl-configurable.md` で対応済み）のに対し、認可トランザクションの TTL は
設定できない。**同じ「短命な中間状態の寿命」でありながら扱いが非対称**である。

確認したいのは次の点である。

1. 認可トランザクションの寿命に関する仕様上の要件（そもそも規定があるか）
2. 2 箇所のハードコードがずれた場合に何が起きるか
3. 認可コード TTL と同様に設定可能にすべきか、その場合の既定値と下限
4. 失効・完了以外の経路で残るトランザクション（孤児エントリ）のライフサイクル

本ファイルは以下と重複しない。

- 認可コードの TTL: `tasks/done/p2-auth-code-ttl-configurable.md`
- store の期限切れエントリ回収: `study-material/done/store-expired-entry-eviction-and-ttl.md`
- resolver / store の契約全般: `study-material/resolver-and-store-contract.md`
- トランザクションのブラウザ束縛: `study-material/done/auth-transaction-user-agent-binding.md`

## 2. 関連する仕様・基準

共通の仕様索引は `study-material/basic-op-requirement-traceability.md` §3.3 を参照。

### 2.1 認可トランザクションは仕様上の概念ではない

OIDC Core 1.0 / OAuth 2.1 は、認可エンドポイントから login / consent 画面を経て認可コード発行に至る
**中間状態を仕様上の実体として定義していない**。`AuthTransaction` は本リポジトリの実装都合の概念であり、
したがって TTL の値そのものを直接規定する条文は存在しない。

> 明確に記す: 「認可トランザクションの TTL は N 分でなければならない」という一次仕様は無い。
> 本ファイルの論点は仕様準拠ではなく、**設定可能性と 2 箇所のハードコードの整合性**である。

### 2.2 ただし寿命の上限・下限には仕様由来の制約がある

- **上限側**: 認可トランザクションが生きている間、`redirect_uri` / `state` / `nonce` / `code_challenge` /
  `claims` といった認可リクエストの内容が OP のストアに保持される。OIDC Core 1.0 §3.1.3.1 が
  認可コードに求める "short-lived" の思想（および RFC 6749 §4.1.2 の推奨上限 10 分）は、
  その前段である認可トランザクションにも同じ論法で当てはまる。長すぎる TTL は攻撃面
  （`study-material/done/auth-transaction-user-agent-binding.md` で扱うトランザクション横取り）を広げる。
- **下限側**: トランザクションは **人間がログイン画面とパスワードマネージャと MFA を操作する時間**を
  跨いで生き続ける必要がある。短すぎると正当ユーザーがフローを完走できない。認可コード TTL
  （既定 300 秒）より短くしてはならない、という関係が自然に成り立つ。

### 2.3 `max_age` / `auth_time` との無関係性

`max_age` は「認証の鮮度」の要求であり、トランザクションの寿命とは別軸である
（`tasks/done/04-max-age-enforcement.md` / `study-material/id-token-auth-time-conditional-requirement.md`）。
両者を混同して片方の値でもう片方を導出しないこと。

## 3. 参照資料

- OpenID Connect Core 1.0 §3.1.3.1 Token Request（認可コードの short-lived 要件）—
  https://openid.net/specs/openid-connect-core-1_0.html#TokenRequest
- RFC 6749 §4.1.2 Authorization Response（authorization code の推奨最大寿命 10 分）—
  https://www.rfc-editor.org/rfc/rfc6749#section-4.1.2
- 本リポジトリ内:
  - `packages/core/src/auth-transaction.ts:178-179`（`DEFAULT_TTL_MS = 600_000`）
  - `packages/core/src/auth-transaction.ts:194-200`（`createAuthTransaction(..., ttlMs = DEFAULT_TTL_MS)`）
  - `packages/core/src/auth-transaction.ts:126-130`（`createdAt` / `expiresAt` / `failedAttempts`）
  - `samples/hono-cloudflare/src/oidc-provider/routes/authorize.ts:263-272`（`10 * 60` の直書き）
  - `samples/express-flyio` / `samples/fastify-flyio` / `samples/nextjs-vercel` の同一箇所（いずれも `:271`）
  - `packages/cli/src/frameworks/hono/templates.ts:1823`
  - `samples/hono-cloudflare/src/oidc-provider/config.ts`（`authorizationCodeTtl` の設定例）
  - `tasks/done/p2-auth-code-ttl-configurable.md`（認可コード TTL を設定可能にした先行タスク）

## 4. 現在の実装確認

### 4.1 core 側（`expiresAt` の計算）

```ts
/** デフォルトのTTL（ミリ秒）: 10分 */
const DEFAULT_TTL_MS = 600_000;                       // auth-transaction.ts:179

export function createAuthTransaction(
  request: ...,
  csrfToken: string,
  ttlMs: number = DEFAULT_TTL_MS                      // :200
): AuthTransaction { ... }                            // createdAt / expiresAt を設定
```

`ttlMs` は引数で上書きできるが、**生成コードは引数を渡していない**。

### 4.2 生成コード側（ストアの TTL）

```ts
const transaction = createAuthTransaction(validatedRequest, csrfToken);   // ttlMs 未指定 → 600_000
const transactionId = await generateRandomString(32);
await transactionStore.put(
  'auth_txn:' + transactionId,
  transaction,
  10 * 60,                                                                // 秒。core の 600_000ms と別の literal
);
```

同一の値を「ミリ秒（core の既定引数）」と「秒（テンプレートの literal）」という異なる単位・異なる場所で
二重に持っている。

### 4.3 `handleLoginFailure` は `expiresAt` を信頼している

```ts
const remainingTtlMs = transaction.expiresAt - Date.now();
const remainingTtlSeconds = Math.max(1, Math.ceil(remainingTtlMs / 1000));
await store.put(key, transaction, remainingTtlSeconds);      // auth-transaction.ts:342-344
```

ログイン失敗のたびに、ストアの TTL は **`expiresAt` から再計算した残り時間**で書き戻される。
つまり `expiresAt`（core 由来）が実質的な真実の情報源であり、authorize 時の `10 * 60`（テンプレート由来）は
**最初の 1 回だけ効く別系統の値**になっている。

### 4.4 トランザクションが削除される経路と、削除されない経路

削除される（正常系・異常系ともに明示的に `delete` する）:

- consent の承認完了 / 拒否（`completeAuthTransaction` / `deny` 分岐）
- `prompt=none` の各エラー分岐、`prompt` 組み合わせエラー、`id_token_hint` 検証失敗、`max_age` 超過
- ログイン失敗の上限到達（`handleLoginFailure`）

削除されない（ストアの TTL 満了に委ねる）:

- ユーザーがログイン画面・同意画面を開いたまま離脱した場合
- SSO 経路で `authSessionStore.set` した後、consent へ遷移したまま離脱した場合
- 認可エンドポイントを叩いただけで以降のリクエストが来ない場合（**認証不要で誰でも発生させられる**）

最後のケースは、ストアに未認証・匿名の書き込みを許す入口になっている。TTL が長いほど滞留量が増える。

## 5. 現在の実装との差分

満たしていること:

- ✅ 既定 10 分という値そのものは、認可コード（5 分）より長く、人間の操作時間を跨げる妥当な範囲にある
- ✅ 完了・拒否・エラーの各経路でトランザクションを明示的に削除しており、リークは限定的
- ✅ `handleLoginFailure` が残り TTL を再計算しており、ログイン失敗のたびに寿命が延びる
      （＝スライディング）事故を避けている
- ✅ core の `createAuthTransaction` は `ttlMs` を引数で受け取れる構造になっている

不足している可能性があること:

- 🟡 **2 箇所のハードコードが結び付いていない**: 利用者が core の `ttlMs` を渡すようカスタマイズしても、
  テンプレートの `10 * 60` を直さなければ、初回の store TTL だけが 10 分のまま残る。逆にテンプレート側だけ
  変えると `expiresAt` が古いままで、`handleLoginFailure` が短い残り TTL を書き戻して整合が崩れる。
  **どちらの方向のカスタマイズでも静かに壊れる。**
- 🟡 **設定できない（`authorizationCodeTtl` との非対称）**: `ProviderConfig` には
  `authorizationCodeTtl` があるのに `authTransactionTtl` が無い。PoC で「トランザクション期限切れの
  挙動を試したい」利用者は、生成コードを直接書き換えるしかない。本リポジトリのコンセプト
  （「素早く仕様を検証する」）と噛み合わない。
- 🟡 **孤児トランザクションのライフサイクルが契約化されていない**: 認証不要な認可エンドポイントで
  誰でもストアに書き込みを発生させられるが、その保持期間と回収の責務が
  `study-material/resolver-and-store-contract.md` の TTL 表に記載されていない
  （同表は認可コード・refresh token・auth-transaction を挙げるが、authorize 時の匿名書き込みの
  攻撃面としては扱っていない）。
- 🟢 **単位の混在（ms / 秒）**: core は ms、store I/F は秒。バグではないが、設定値を導入する際に
  どちらに揃えるかを決めておかないと同種の取り違えを再生産する。

相互運用性の観点で改善した方がよいこと:

- OIDF Conformance Suite の手動操作を伴う module では、人間がスクリーンショットを撮るなどして
  10 分を超えることがありうる。TTL を設定可能にしておくと検証時の詰まりを避けられる
  （`study-material/basic-op-conformance-verification-plan.md` の実行手順と接続する）。

Basic OP として提供する上で確認すべきこと:

- Basic OP 認定要件に認可トランザクションの寿命は含まれず、**認定可否には影響しない**。

## 6. 改善・追加を検討する理由

- **なぜ価値があるか**: 「二重に持っている定数が静かにずれる」は、後から原因を特定しにくい種類の不具合。
  かつ利用者が最初に触りたくなる値（画面操作の猶予時間）でもある。設定として 1 箇所に集約すれば、
  カスタマイズの入口が明確になり、ずれる余地が消える。
- **Basic OP に必要か / 拡張か**: どちらでもない。**先行タスク（認可コード TTL 設定化）との一貫性を
  取るための整理**である。
- **導入しやすさ**: 🟢 高い。`ProviderConfig` に 1 フィールド追加し、`createAuthTransaction` へ渡し、
  `transactionStore.put` の TTL を同じ値から導出するだけ。既定値を現行と同じ 600 秒にすれば
  後方互換を保てる。
- **既存実装との接続**: `authorizationCodeTtl` が通っている経路（`config.ts` → `routes/*.ts`）に
  そのまま相乗りできる。`config` は既に `c.get('config')` で authorize ハンドラから読めている。
- **利用者・開発者のメリット**: 「トランザクション期限切れで login 画面が失効する」挙動を、
  値を 1 つ変えるだけで再現・検証できる。PoC の検証速度に直結する。
- **実装しない場合に残るリスク**: 定数が二重管理のまま残り、利用者のカスタマイズが静かに壊れる。
  設定の粒度が `authorizationCodeTtl` とちぐはぐなままになる。

## 7. 実装方針の候補

最終判断は人間が行う。

### 方針A: `ProviderConfig.authTransactionTtl`（秒）を追加し、1 つの値から両方を導出する

```ts
// config.ts
/**
 * 認可トランザクション（login / consent 画面を跨ぐ中間状態）の有効期間（秒）。
 * 認可コード（authorizationCodeTtl、既定 300 秒）より長く設定すること。
 * 既定 600 秒（10 分）。
 */
authTransactionTtl: number;   // default: 600

// routes/authorize.ts
const transaction = createAuthTransaction(
  validatedRequest,
  csrfToken,
  config.authTransactionTtl * 1000,       // core は ms
);
await transactionStore.put('auth_txn:' + transactionId, transaction, config.authTransactionTtl);
```

- 長所: 単一の情報源になる。既定値を 600 にすれば完全な後方互換
- 短所: `ms` / `秒` の変換が呼び出し側に残る（コメントで明示する必要がある）

### 方針A': 方針A に加え、core 側で「秒」に統一する

`createAuthTransaction` に `ttlSeconds` のオーバーロード（または新しい引数名）を足し、
store I/F の単位に揃える。

- 長所: 単位の取り違えを構造的に防げる
- 短所: core の公開 API 変更になるため、破壊的変更の扱いを決める必要がある

### 方針B: テンプレートから `10 * 60` を消し、`transaction.expiresAt` から導出する

```ts
const ttlSeconds = Math.max(1, Math.ceil((transaction.expiresAt - Date.now()) / 1000));
await transactionStore.put('auth_txn:' + transactionId, transaction, ttlSeconds);
```

- 長所: `handleLoginFailure` と同じ導出式になり、core の `expiresAt` が唯一の真実になる。
  config を増やさずに二重管理だけを解消できる
- 短所: 設定可能にはならない（`createAuthTransaction` の `ttlMs` を渡すカスタマイズは依然必要）

### 方針C: 方針B を入れたうえで、方針A を後追いする

- 二重管理の解消（低リスク）を先に入れ、設定化は別途判断する

### 方針D: 何もせず、コメントで「2 箇所を同時に変えること」を明記する

- 長所: コスト 0
- 短所: 静かに壊れる構造がそのまま残る

推奨は方針C（方針B → 方針A）。ただし最終判断は人間が行う。

## 8. タスク案

- [ ] 方針（A / A' / B / C / D）を決定する（人間判断）。特に core の API を変えるか（A'）を先に決める
- [ ] 方針B 相当:
  - [ ] `packages/cli` のテンプレート（`frameworks/hono/templates.ts:1823` 付近、
        `frameworks/web-standard/templates.ts` の同等箇所）から `10 * 60` の直書きを除去し、
        `transaction.expiresAt` から TTL 秒を導出する形に変更する
- [ ] 方針A 相当:
  - [ ] `ProviderConfig` に `authTransactionTtl`（秒、既定 600）を追加する
        （`packages/cli` の `config.ts` テンプレート）
  - [ ] `routes/authorize.ts` テンプレートで `createAuthTransaction(..., config.authTransactionTtl * 1000)`
        を渡す
  - [ ] `authTransactionTtl >= authorizationCodeTtl` を起動時に検証するか、コメントで明示するかを決める
- [ ] core のテストを TDD で追加する（`packages/core/src/auth-transaction.test.ts`）
  - [ ] `should set expiresAt from the provided ttlMs instead of the default`
  - [ ] `should keep the remaining lifetime when a login failure is recorded`
- [ ] `packages/cli` の conformance.test.ts 生成コードに契約テストを追加する
      （CLAUDE.md: conformance.test.ts は生成側を変更する）
  - [ ] 設定した TTL を過ぎた `transaction_id` で `GET /login` すると失敗すること
  - [ ] `expiresAt` とストアの実効 TTL が一致していること（同一の設定値から導出されていること）
- [ ] `study-material/resolver-and-store-contract.md` の TTL 表に、認可トランザクションの
      「authorize 時の匿名書き込み」と保持期間の推奨を追記する（本ファイルへの参照でよい）
- [ ] 4 sample を再生成し `pnpm test` がパスすることを確認する
