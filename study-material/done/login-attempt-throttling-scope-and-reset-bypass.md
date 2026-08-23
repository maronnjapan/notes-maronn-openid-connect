# ログイン試行回数の上限が「認可トランザクション単位」で、トランザクションを再作成すれば無制限に試行できる

## ステータス

🟠 High（セキュリティ）/ 未着手

## 1. このトピックで確認したいこと

`packages/core/src/auth-transaction.ts` の `handleLoginFailure` は、ログイン失敗回数を
**`AuthTransaction.failedAttempts`（＝認可トランザクション単位）** でカウントし、既定 5 回で
トランザクションを削除して打ち切る。

しかし攻撃者は認可エンドポイントを叩き直すだけで新しい `transaction_id` を無制限に取得できるため、
**「5 回失敗 → 新しい認可リクエストを開始 → また 5 回」を繰り返すことで、同一アカウントに対する
パスワード総当たりを事実上無制限に実行できる**。カウンタがアカウント（subject）にも送信元にも
紐づいていないため、上限が上限として機能しない。

確認したいのは次の点である。

1. 認証試行回数の制限は、どの単位（アカウント / 送信元 / トランザクション）で課すのが基準か
2. 現在の実装がどの単位でカウントし、どこで上限が回避されるか
3. 上限到達時に「トランザクションごと削除する」現在の挙動が、正当ユーザーの可用性に与える影響
4. 上限到達時のレスポンス（HTTP 429）が、標準的なヘッダ（`Retry-After`）を返しているか

本ファイルは、横断的な攻撃面の棚卸しである `study-material/rate-limiting-and-brute-force.md` とは別に、
**「既に実装されているカウンタが仕様上の要件を満たしていない」という個別の欠陥**に絞る。
（`rate-limiting-and-brute-force.md` §4 は「失敗試行のカウント / レート制限 / アカウントロックは
実装されていない」と記述しているが、これは `handleLoginFailure` の実装を見落としており、
現状と食い違っている。この記述の訂正も本ファイルの対象に含める。）

## 2. 関連する仕様・基準

共通の仕様索引は `study-material/basic-op-requirement-traceability.md` §3.3 を参照する。
ここでは本トピックに直接効くものだけを引く。

### 2.1 NIST SP 800-63B §5.2.2 Rate Limiting (Throttling)

NIST SP 800-63B は、オンラインでの推測攻撃に対する緩和として **「単一アカウントに対する連続した
認証失敗の回数を制限する」** ことを要求する（verifier SHALL limit consecutive failed authentication
attempts on a single account）。ここで本質的なのは以下の 2 点である。

- 制限の単位は **アカウント（および／または送信元 IP）** であって、リクエストのセッションや
  トランザクションではない
- 攻撃者がカウンタをリセットできる手段があってはならない

現在の実装はカウンタを **攻撃者が自由に作り直せる単位**（トランザクション）に置いているため、
この要件の意図を満たしていない。

> 注（不明点として明記）: SP 800-63B が挙げる具体的な回数（例: 100 回 / 30 日）は AAL や
> 追加の緩和策の有無で変わる。本ファイルでは「単位がアカウント／送信元であること」を要件として扱い、
> **具体的な閾値は本リポジトリのポリシー判断事項**とする。

### 2.2 OAuth 2.0 Security Best Current Practice（RFC 9700）/ OAuth 2.0 Threat Model（RFC 6819）

RFC 9700 はトークンやコードを推測不能にすることを求めるが、**エンドユーザー認証（ログイン画面）の
レート制限は OAuth/OIDC の仕様範囲外**である。ログイン UI は OP のローカルな認証機構であり、
OIDC Core も認証方式を規定しない。したがって本件は「OIDC 仕様違反」ではなく、
**OP を名乗る以上必要な認証基盤側のセキュリティ要件**として扱うのが正確である。

### 2.3 RFC 6585 §4（429 Too Many Requests）

429 は「レート制限に達した」ことを表すステータスであり、RFC 6585 §4 は
**`Retry-After` ヘッダを含めてよい（MAY）** と定める。現在の実装は 429 を返しつつ `Retry-After` を
付けていないため、クライアント（および自動化されたリトライ）が待機時間を判断できない。

## 3. 参照資料

- NIST SP 800-63B Digital Identity Guidelines: Authentication and Lifecycle Management §5.2.2
  Rate Limiting (Throttling) — https://pages.nist.gov/800-63-3/sp800-63b.html#throttle
  （制限の単位が「single account」であることの根拠）
- RFC 6585 §4 429 Too Many Requests — https://www.rfc-editor.org/rfc/rfc6585#section-4
  （`Retry-After` の扱い）
- OAuth 2.0 Security Best Current Practice（RFC 9700）— https://www.rfc-editor.org/rfc/rfc9700.html
- OAuth 2.0 Threat Model and Security Considerations（RFC 6819）— https://www.rfc-editor.org/rfc/rfc6819
- 本リポジトリ内:
  - `packages/core/src/auth-transaction.ts:178-185`（`DEFAULT_TTL_MS` / `DEFAULT_MAX_ATTEMPTS = 5`）
  - `packages/core/src/auth-transaction.ts:324-351`（`handleLoginFailure`）
  - `samples/hono-cloudflare/src/oidc-provider/routes/login.ts:64-82`（呼び出し箇所と 429 応答）
  - `samples/hono-cloudflare/src/oidc-provider/routes/authorize.ts:263-272`（トランザクション新規発行）
  - `study-material/rate-limiting-and-brute-force.md`（横断的な攻撃面。§4 の記述に訂正が必要）

## 4. 現在の実装確認

### 4.1 カウンタの単位と保存先

`packages/core/src/auth-transaction.ts`:

```ts
/** デフォルトの最大認証試行回数 */
const DEFAULT_MAX_ATTEMPTS = 5;                                        // L182

export async function handleLoginFailure(
  txnId: string,
  transaction: AuthTransaction,
  store: AuthTransactionStore,
  maxAttempts: number = DEFAULT_MAX_ATTEMPTS
): Promise<LoginFailureResult> {
  const key = `${STORE_KEY_PREFIX}${txnId}`;
  transaction.failedAttempts++;                                        // L331: トランザクション上のカウンタ

  if (transaction.failedAttempts >= maxAttempts) {
    await store.delete(key);                                           // L334: トランザクションごと削除
    return { canRetry: false, failedAttempts: ..., maxAttempts };
  }

  const remainingTtlMs = transaction.expiresAt - Date.now();
  const remainingTtlSeconds = Math.max(1, Math.ceil(remainingTtlMs / 1000));
  await store.put(key, transaction, remainingTtlSeconds);              // L344: 残り TTL で書き戻す
  return { canRetry: true, failedAttempts: ..., maxAttempts };
}
```

`failedAttempts` は `AuthTransaction` のフィールド（`auth-transaction.ts:130`）であり、
**username / subject / IP のいずれとも紐づいていない**。

### 4.2 呼び出し側（生成コード）

`samples/hono-cloudflare/src/oidc-provider/routes/login.ts`:

```ts
const user = await authenticateUser(username, password);
if (!user) {
  const failureResult = await handleLoginFailure(transactionId, transaction, transactionStore);
  if (!failureResult.canRetry) {
    return renderView(views.errorPage({
      error: 'Too many login attempts',
      statusCode: 429,
    }), { status: 429 });                     // Retry-After なし
  }
  return renderView(views.loginPage({ ..., error: 'Invalid credentials', ... }));
}
```

- 失敗メッセージは `Invalid credentials` に統一されており、**ユーザー存在の有無で文言が変わらない**
  （ユーザー列挙耐性という点では正しい）
- 上限到達時は 429 を返すが `Retry-After` は付かない

### 4.3 上限が回避される経路

1. 攻撃者が `GET /authorize?...` を叩く → 新しい `transaction_id`（`failedAttempts = 0`）が発行される
2. `POST /login` を 4 回まで実行（5 回目でトランザクションが消える）
3. 手順 1 に戻る

認可エンドポイントは**認証不要**で、`client_id` と登録済み `redirect_uri` さえあれば誰でも叩ける。
したがって手順 1 のコストはほぼゼロで、**上限 5 回は攻撃者にとって「4 回ごとに 1 リクエスト余分に
投げる」程度のコストにしかならない**。

### 4.4 影響範囲

`handleLoginFailure` は core の関数で、4 sample すべてと CLI テンプレート 2 種が同じ形で呼んでいる
（`packages/cli/src/frameworks/hono/templates.ts:3333` 付近、
`packages/cli/src/frameworks/web-standard/templates.ts:1358` 付近）。

## 5. 現在の実装との差分

満たしていること:

- ✅ 失敗回数のカウント機構と、上限到達時の打ち切り経路が存在する
- ✅ 上限到達時に 429 を返しており、ステータスコードの選択は適切（RFC 6585 §4）
- ✅ 失敗メッセージがユーザー存在の有無で変わらず、ユーザー列挙に配慮している
- ✅ `remainingTtlSeconds` を `Math.max(1, ...)` でクランプしており、TTL が負値になって
      即時失効する事故を避けている

不足している可能性があること:

- 🟠 **カウンタの単位が誤っている**: NIST SP 800-63B が求める「single account」単位ではなく、
  攻撃者が自由に再作成できるトランザクション単位。**上限が実効的に機能していない**。
- 🟠 **リセットが攻撃者の手中にある**: カウンタのリセット条件が「新しい認可リクエストを送る」であり、
  攻撃者が完全に制御できる。スロットリングの前提（攻撃者がカウンタをリセットできないこと）を満たさない。
- 🟡 **上限到達時にトランザクションを削除する副作用**: `store.delete(key)` によりトランザクション自体が
  消えるため、正当ユーザーが 5 回打ち間違えると **フローが復旧不能になり、RP から `redirect_uri` への
  エラー応答も返らない**（429 の HTML が表示されて行き止まりになる）。クライアントは `state` に対する
  応答を永久に受け取れず、タイムアウトを待つことになる。OIDC Core §3.1.2.6 の観点では
  `access_denied` などで `redirect_uri` へ戻す選択肢も検討に値する。
- 🟡 **`Retry-After` が無い**: RFC 6585 §4 が挙げる `Retry-After` を返していないため、
  正当なクライアント／ユーザーが再試行可能時刻を知る手段がない。またロックの解除条件が
  「新しいトランザクションを作る＝即時」であることが利用者に伝わらない。
- 🟡 **拡張点が無い**: core は `maxAttempts` を引数で受け取るだけで、「アカウント単位／送信元単位の
  カウンタ」を外から差し込むための resolver / フックが無い。利用者が正しく直そうとしても、
  `login.ts` を自前で書き換えるしかない。

セキュリティ上、改善した方がよいこと:

- スロットリングは「攻撃者が制御できない識別子」を軸に据える必要がある。最低でも
  **username（正規化後）単位**、可能なら **送信元 IP と組み合わせた複合キー**。

Basic OP として提供する上で確認すべきこと:

- Basic OP 認定テストにログイン試行のレート制限を検証する module は無く、**認定可否には影響しない**。
  ただし OP を名乗る以上、認証基盤としての基本要件であることは変わらない。

## 6. 改善・追加を検討する理由

- **なぜ価値があるか**: 現状は「試行回数制限が実装されている」ように見えるコード（`failedAttempts`、
  `maxAttempts`、`remainingAttempts` の表示）が存在するため、**利用者は保護されていると誤認しやすい**。
  実効性のない防御が「ある」ことは、防御が「ない」ことよりも危険である。
- **Basic OP に必要か / 拡張か**: 認定要件ではない。**認証基盤の必須要件**として位置づける。
- **導入しやすさ**: 🟡 中程度。core にカウンタの永続先を抽象化する resolver（例
  `LoginAttemptResolver`）を追加し、既定は「トランザクション単位（従来動作）」、
  利用者が注入すればアカウント単位にできる、という段階的な形にすれば後方互換を保てる。
  ただし「どこにカウンタを置くか」は store の選択（KV / D1 / Redis）に依存するため、
  core が実装を持つべきではない。
- **既存実装との接続**: 本リポジトリは既に `ClientResolver` / `ConsentResolver` / `SessionResolver` /
  `AcrResolver` といった resolver 注入の設計思想を持っており、同じ形に載せられる。
  `handleLoginFailure` はステップ関数としてそのまま残し、シグネチャに resolver を足す形が素直。
- **利用者・運用者のメリット**: 「PoC のまま本番へ」の利用者が最初に踏む地雷を 1 つ減らせる。
  また resolver 化すれば、アカウントロックの通知・監査ログ（`study-material/audit-logging-and-observability.md`）
  との接続点が自然にできる。
- **実装しない場合に残るリスク**: 実効性のない上限が残り、パスワード総当たりに対して無防備なまま。
  かつ「5 回で止まる」という表示がレビュアーを誤導する。

## 7. 実装方針の候補

最終判断は人間が行う。

### 方針A: `LoginAttemptResolver` を core に追加し、カウンタの単位を利用者に委ねる

```ts
// packages/core/src/auth-transaction.ts
export interface LoginAttemptResolver {
  /** 識別子（正規化済み username など）に対する現在の連続失敗回数を返す */
  getFailedAttempts(identifier: string): Promise<number>;
  /** 失敗を 1 加算し、加算後の回数を返す */
  recordFailure(identifier: string): Promise<number>;
  /** 認証成功時にカウンタをクリアする */
  clearFailures(identifier: string): Promise<void>;
  /** 任意: ロック解除までの秒数（Retry-After に使う） */
  getRetryAfterSeconds?(identifier: string): Promise<number | undefined>;
}
```

- `handleLoginFailure` に optional で渡し、未指定なら従来のトランザクション単位（後方互換）
- 生成コードでは既定実装（in-memory / D1 の `login_attempts` テーブル）を出力し、
  `username` を正規化したものをキーにする
- 長所: 本リポジトリの resolver 注入思想と完全に整合。core は保存戦略を持たない
- 短所: I/F が 1 つ増える。既定実装をどこまで用意するか（sample のストア実装が増える）

### 方針B: 生成コードだけで対応し、core は変えない

`login.ts` テンプレート内で `loginAttemptStore`（`store.ts` に追加）を直接使う。

- 長所: core の API を増やさない。変更が生成コードに閉じる
- 短所: core の `handleLoginFailure` に残る「実効性のないカウンタ」をどう扱うかの整理が別途必要
  （残すなら誤導が残り、消すなら破壊的変更）

### 方針C: 上限到達時の挙動だけ先に直す（トランザクション削除をやめる / `Retry-After` を付ける）

- 上限到達時は `store.delete` せず、`lockedUntil` を書いて `Retry-After` を返す
- あるいは `redirect_uri` へ `access_denied` で戻し、クライアントにフローの終了を伝える
- 長所: 可用性と相互運用性の改善だけを小さく先行できる
- 短所: 総当たり回避の本質（カウンタ単位）は直らない

### 方針D: ドキュメントのみ（プラットフォーム側の WAF / Rate Limiting に委ねる旨を明記）

- 長所: コスト 0
- 短所: `rate-limiting-and-brute-force.md` の方針A と同じで、「実装されているように見えるカウンタ」を
  残したままにするなら誤導が解消しない。最低でもコードコメントでの明示が必要

推奨は「方針C を先に入れて可用性と `Retry-After` を直し、方針A で単位を正す」の 2 段構え。
ただし最終判断は人間が行う。

## 8. タスク案

- [ ] 方針（A / B / C / D、および 2 段構えの採否）を決定する（人間判断）
- [ ] 閾値ポリシーを決める: 何回で / 何を単位に / どれだけロックするか（例: username 単位 10 回 / 15 分）
- [ ] `study-material/rate-limiting-and-brute-force.md` §4 の
      「失敗試行のカウント / レート制限 / アカウントロックは実装されていない」という記述を、
      `handleLoginFailure` の実装状況に合わせて訂正し、本ファイルへ参照を張る
- [ ] 方針C（先行）:
  - [ ] `handleLoginFailure` が上限到達時にトランザクションを削除する挙動を見直し、
        「ロック状態として残す」か「`redirect_uri` へ `access_denied` で戻す」かを実装する
  - [ ] 429 応答に `Retry-After` を付与する（`packages/cli` のテンプレート側）
- [ ] 方針A（本命）:
  - [ ] `packages/core/src/auth-transaction.ts` に `LoginAttemptResolver` を追加し、
        `handleLoginFailure` を optional 引数で受け取る形に拡張する（未指定時は従来動作）
  - [ ] `packages/cli` のテンプレートに既定実装（`store.ts` の `LoginAttemptStore`）と配線を追加する
  - [ ] 認証成功時に `clearFailures` を呼ぶ経路を `login.ts` テンプレートに追加する
- [ ] core のテストを TDD で追加する（`packages/core/src/auth-transaction.test.ts`）
  - [ ] `should keep counting failures across different transactions for the same identifier`
  - [ ] `should reject authentication once the identifier exceeds maxAttempts`
  - [ ] `should clear the failure counter after a successful authentication`
  - [ ] `should fall back to per-transaction counting when no LoginAttemptResolver is provided`
- [ ] `packages/cli` の conformance.test.ts 生成コードに契約テストを追加する
      - [ ] 新しいトランザクションを作り直しても同一 username の失敗回数が引き継がれること
      - [ ] 上限到達時のレスポンスが 429 で `Retry-After` を含むこと
- [ ] `tests/e2e` に「5 回失敗後に新しい認可リクエストを開始しても即座に再試行できない」E2E を追加する
- [ ] 4 sample を再生成し `pnpm test` がパスすることを確認する
