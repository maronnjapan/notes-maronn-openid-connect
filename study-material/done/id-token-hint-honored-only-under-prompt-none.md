# `id_token_hint` が `prompt=none` 経路でしか尊重されず、対話フローでは無視される

## 1. このトピックで確認したいこと

生成 OP は `id_token_hint` の検証（署名・`iss`・`aud`・`exp`・`iat`）とセッション subject との突合を、**`prompt=none` の分岐の内側でのみ**行っている。

`prompt` が無い／`prompt=login` 等の対話フローでは、`id_token_hint` はトランザクションに保存されるだけで**一切参照されない**。その結果:

- ブラウザに User B のセッションがある状態で、RP が User A を指す `id_token_hint` を付けて認可リクエストを送ると、
  OP は SSO 高速経路で **User B の認可コードを黙って発行する**。
- RP は「A を再認証させたつもり」で B の ID Token を受け取る。エラーも警告も出ない。

OIDC Core §3.1.2.1 の `id_token_hint` の記述は `prompt=none` に限定されていない。本ファイルはこの**適用範囲の欠落**に限定して扱う。

**既存ファイルとの切り分け（重複回避）**

| 論点 | 扱っているファイル |
|---|---|
| `id_token_hint` の**JWS 検証の厳格さ**（`crit` / 外部鍵ヘッダ / strict base64url / clock skew） | `study-material/inbound-jws-verification-crit-and-alg-binding.md`、`tasks/done/p2-jwt-header-reject-unsafe-fields.md`、`tasks/done/p2-clock-skew-configurable-and-iat-bound.md` |
| `prompt=none` + `id_token_hint` の成功／失敗条件の E2E 固定 | `tasks/done/p2-id-token-hint-success-flow-e2e.md` |
| ブラウザセッション確立と SSO そのもの | `study-material/done/cli-generated-provider-browser-session-and-sso.md` |
| `login_hint` の UI 反映 | `tasks/done/p3-login-hint-ui-prefill.md` |
| `prompt=select_account` の扱い | `study-material/prompt-select-account.md`、`tasks/p3-prompt-select-account-phase2.md` |

JWS 検証ロジックの正しさや `prompt=none` 内の挙動は上記で扱い済みのため繰り返さない。ここでは「**検証が呼ばれるのはどの経路か**」だけを論じる。

## 2. 関連する仕様・基準（このトピック固有の差分）

### 2.1 OIDC Core 1.0 §3.1.2.1 — `id_token_hint` は prompt に依存しない

`id_token_hint` の定義（Authentication Request のパラメータ表）は次の通り。

> **id_token_hint** — OPTIONAL. ID Token previously issued by the Authorization Server being passed as a hint about the End-User's current or past authenticated session with the Client. **If the End-User identified by the ID Token is logged in or is logged in by the request, then the Authorization Server returns a positive response; otherwise, it SHOULD return an error, such as `login_required`.**
>
> When possible, an `id_token_hint` SHOULD be present when `prompt=none` is used and an `invalid_request` error MAY be returned if it is not; however, the server SHOULD respond successfully when possible, even if it is not present.

読み取れる構造:

1. 前段の「logged in or is logged in by the request → positive response / otherwise SHOULD return an error」は、**prompt の値に条件付けられていない**。`prompt=none` は 2 文目で「hint があることが望ましい」と述べられるだけで、hint の意味論を限定していない。
2. 「**is logged in by the request**」という語がある以上、対話フローで「その End-User としてログインさせる」ことも仕様の想定範囲に含まれる。つまり対話フローで hint を無視するのではなく、
   - 既存セッションが hint と一致 → そのまま進める
   - 一致しない → その End-User としてログインさせる（ログイン画面で対象ユーザーを固定する）か、`login_required` を返す
   のいずれかが期待される挙動である。

### 2.2 §3.1.2.1 `prompt` との関係

`prompt=none` は「UI を出してはならない」制約であって、hint の適用条件ではない。`prompt=login` は「必ず再認証させる」制約であり、hint と組み合わされた場合は「**hint が指す End-User として再認証させる**」のが自然な合成になる。

### 2.3 SHOULD であることの意味

上記は MUST ではなく SHOULD である。したがって「対話フローでは hint を無視する」という実装が直ちに仕様違反になるわけではない。ただし SHOULD を外す場合、仕様は相応の理由を求める（RFC 2119 / 8174）。**現状の実装は意図的に外したのか、単に `prompt=none` 分岐へ実装が閉じているだけなのかがコードから判別できない**点が問題である。

### 2.4 Basic OP certification profile との関係

OpenID Foundation の Basic OP profile には `id_token_hint` を扱うテストが含まれる（`oidcc-prompt-none-logged-in` 系で hint を用いる構成など）。ただしこれらは主に `prompt=none` 経路を対象とする。Basic OP 要件の全体像は `study-material/basic-op-requirements-baseline.md` および `study-material/basic-op-requirement-traceability.md`（`OP-Req-id_token_hint` は SHOULD として ✅ 判定）を参照。

**本トピックはトレーサビリティ表の判定を「prompt=none 限定で満たしている」へ精緻化することを含意する。**

## 3. 参照資料

- OpenID Connect Core 1.0 §3.1.2.1 Authentication Request（`id_token_hint` / `prompt` の定義）
  — https://openid.net/specs/openid-connect-core-1_0.html#AuthRequest
- OpenID Connect Core 1.0 §3.1.2.2 Authentication Request Validation
  — https://openid.net/specs/openid-connect-core-1_0.html#AuthRequestValidation
- OpenID Connect Core 1.0 §3.1.2.3 Authorization Server Authenticates End-User（SSO の扱い）
  — https://openid.net/specs/openid-connect-core-1_0.html#Authenticates
- OpenID Connect Core 1.0 §3.1.2.6 Authentication Error Response（`login_required` / `account_selection_required`）
  — https://openid.net/specs/openid-connect-core-1_0.html#AuthError
- RFC 8174 / RFC 2119（SHOULD の解釈）— https://www.rfc-editor.org/rfc/rfc8174
- 本リポジトリ内: `study-material/basic-op-requirement-traceability.md`（`OP-Req-id_token_hint`）、`tasks/done/p2-id-token-hint-success-flow-e2e.md`

## 4. 現在の実装確認

### 4.1 `id_token_hint` の受理と保存

- `packages/core/src/authorization-request.ts:1229` — `idTokenHint: effective.id_token_hint` として `ValidatedAuthorizationRequest` に載る。
- `packages/core/src/auth-transaction.ts:121` / `249-251` — `AuthTransaction.idTokenHint` に保存される。

ここまでは prompt に依存しない。

### 4.2 検証は `prompt=none` 分岐の内側にしかない

`packages/cli/src/frameworks/hono/templates.ts`（`authorizeRouteTemplate`）

```ts
// 1836 行
if (promptValues.includes('none')) {
  ...
  // 1854-1881 行: id_token_hint の検証はこのブロックの中だけ
  let verifiedHintSubject: string | undefined;
  if (transaction.idTokenHint !== undefined) {
    const jwksProvider = c.get('jwksProvider') ...;
    const verified = await validateIdTokenHint(transaction.idTokenHint, {
      expectedIss: issuer,
      expectedAud: transaction.clientId,
      jwks,
    });
    verifiedHintSubject = verified.sub;
  }
  ...
  // 1895 行
  validatePromptNoneIdTokenHint(transaction, session, verifiedHintSubject);
  ...
}
```

`verifiedHintSubject` はこのブロックのローカル変数であり、ブロック外からは参照できない。

### 4.3 対話フロー（SSO 高速経路）は hint を見ない

`packages/cli/src/frameworks/hono/templates.ts:1959-2020` 付近

```ts
// prompt=login / select_account 以外なら既存セッションを再利用する
if (!promptValues.includes('login') && !promptValues.includes('select_account')) {
  const sessionResolver = c.get('sessionResolver');
  if (sessionResolver) {
    const existingSession = await sessionResolver.resolve(c.req.raw);
    const sessionIsFresh = existingSession !== null &&
      (transaction.maxAge === undefined ||
       !requiresReauthentication(transaction.maxAge, existingSession.authTime));
    if (existingSession && sessionIsFresh) {
      // ← transaction.idTokenHint を一切参照しない
      const consentAlreadyGranted = ... hasConsent(existingSession.subject, ...);
      if (consentAlreadyGranted) {
        // existingSession.subject で認可コードを発行してリダイレクト
      }
      // 同意画面へ（authSessionStore に existingSession.subject を書き込む）
    }
  }
}
// ログイン画面へ（transaction.idTokenHint は login ルートでも参照されない）
```

`loginRouteTemplate`（3300 行以降）でも `idTokenHint` は参照されない（`loginHint` はログインフォームの prefill に使われるが、`idTokenHint` は使われない）。

### 4.4 core 側の状況

`packages/core/src/auth-transaction.ts:414-427` の `validatePromptNoneIdTokenHint` は**関数名が示す通り prompt=none 専用**として定義されている。対話フロー用の汎用ヘルパー（例: 「hint とセッションが一致するか」を返す純関数）は core に存在しない。

`validateIdTokenHint`（`packages/core/src/id-token.ts:276-391`）自体は prompt に依存しない汎用関数なので、呼び出し箇所さえ増やせば再利用できる。

### 4.5 再現シナリオ

1. ブラウザで User B としてログインし、OP セッション cookie を持つ。
2. RP が User A の ID Token を `id_token_hint` に付け、`prompt` 無しで認可リクエストを送る。
3. SSO 高速経路が `existingSession.subject = B` を採用し、B の同意記録があれば**そのまま B の認可コードを発行**する。
4. RP は A のつもりで B のセッションを確立する（アカウント取り違え）。

補足: `id_token_hint` の署名検証も行われないため、**壊れた hint / 別 OP が発行した hint でもエラーにならない**（無視される）。

## 5. 現在の実装との差分

### 満たしていること

- `id_token_hint` の JWS 検証ロジック（署名・`iss`・`aud`・`exp`・`iat`・外部鍵ヘッダ拒否）は core に実装済みで堅牢。
- `prompt=none` 経路では検証・突合ともに正しく行われ、不一致は `login_required` になる。
- `jwksProvider` の既定配線があり、OP 自身が発行した ID Token を hint として検証できる。

### 不足している可能性があること

- 対話フロー（`prompt` 無し / `login` / `consent` / `select_account`）で `id_token_hint` が完全に無視される。
- 不正・期限切れ・別 issuer の `id_token_hint` が対話フローでは検証されず、エラーにもならない。
- ログイン画面が hint の指す End-User を提示・固定しない（「is logged in by the request」を満たす手段が無い）。
- core に対話フロー用の hint 突合ヘルパーが無い（`validatePromptNoneIdTokenHint` は名前も引数も prompt=none 前提）。

### 実装はあるが仕様上の確認が必要なこと

- SHOULD をどこまで満たすか。「一致しなければ `login_required`」なのか「hint のユーザーとして再ログインさせる」なのかは実装裁量。後者のほうが UX は良いが、`select_account` 的な機能が必要になる。
- hint 不一致時に `login_required` を返すと、既存セッションを持つ正当なユーザーがループに入る可能性がある（RP が古い hint を送り続けるケース）。エラー選択の妥当性検討が要る。

### セキュリティ上、改善した方がよいこと

- **アカウント取り違え（subject confusion）**。RP が hint で特定ユーザーの再認証を意図しているのに別ユーザーが返る。共有端末・複数アカウント環境で現実的な問題になる。
- 対話フローで hint の署名を検証しないため、「検証されない入力が保存され、後続処理へ流れる」構造が残る（現状は使われないので実害は無いが、将来の改造で危険になる）。

### 相互運用性の観点で改善した方がよいこと

- 主要 IdP（Google / Auth0 / Keycloak 等）は `id_token_hint` を prompt に関係なく尊重し、不一致時はアカウント選択または再認証へ誘導する。PoC → 本番移行時に挙動差になる。

### Basic OP として提供する上で確認すべきこと

- `study-material/basic-op-requirement-traceability.md` の `OP-Req-id_token_hint`（SHOULD / ✅）は**適用範囲の注記が必要**。現状は「prompt=none 限定で満たす」が正確な記述。

## 6. 改善・追加を検討する理由

- **価値**: `id_token_hint` は「特定ユーザーのセッション継続」を RP から要求する唯一の標準手段であり、SSO / セッション管理を検証したい PoC 開発者にとって中核の機能。prompt=none 限定では検証できるシナリオが半分になる。
- **Basic OP 必須か拡張か**: Basic OP profile の必須テスト対象ではないが、OIDC Core の SHOULD であり、`id_token_hint` を実装している以上は適用範囲を明確にすべき。
- **導入しやすさ**: `validateIdTokenHint` は既に汎用関数として存在し、`prompt=none` 分岐で使っているコードをブロック外へ引き上げるだけで大半が済む。`jwksProvider` の配線も既にある。**変更は生成テンプレートに閉じる**（core の新規 API は必須ではない）。
- **既存実装との接続**: SSO 高速経路の `sessionIsFresh` 判定の隣に「hint 一致」条件を足すのが自然。`consentAlreadyGranted` と同じ形で条件を1つ増やせる。
- **メリット**: 利用者は「hint あり／なし」「一致／不一致」の4象限を実機で比較検証できる。RP 実装者はアカウント取り違えを再現・確認できる。
- **実装しない場合に残るリスク**: 対話フローでのアカウント取り違えが既定挙動として残る。トレーサビリティ表の記載も実態より広く読める状態が続く。

## 7. 実装方針の候補（最終判断は人間が行う）

### 方針A: 検証を prompt 分岐の外へ引き上げ、不一致は再認証へ誘導する（推奨候補）

1. `id_token_hint` の検証（`validateIdTokenHint`）を `promptValues.includes('none')` 分岐の**前**に移動し、`verifiedHintSubject` を関数スコープの変数にする。
2. 検証失敗は prompt に関係なく `login_required` でリダイレクト（現行の prompt=none 挙動と同じ）。
3. SSO 高速経路の条件に `verifiedHintSubject === undefined || verifiedHintSubject === existingSession.subject` を追加。
4. 不一致なら SSO を使わずログイン画面へ遷移させ、ログイン画面に hint の subject を渡して対象ユーザーを提示／固定する。
5. `prompt=none` 経路は既存の `validatePromptNoneIdTokenHint` をそのまま使う（挙動不変）。

- 長所: 仕様の SHOULD を素直に満たす。UX も自然（再ログインで解決できる）。
- 短所: ログイン画面テンプレートに hint 表示の配線が必要。ログイン後に「hint と違うユーザーでログインした」ケースの扱いを決める必要がある。

### 方針B: 検証は全経路で行い、不一致は常に `login_required` を返す

方針A の 4 を省略し、hint 不一致なら prompt に関係なくエラーを返す。

- 長所: 実装が最小。挙動が単純で予測しやすい。
- 短所: RP が古い hint を送るとユーザーが復帰できない（RP 側で hint を落として再試行する必要がある）。仕様の "is logged in by the request" は満たさない。

### 方針C: 検証だけ全経路で行い、突合は prompt=none のみ（中間案）

`id_token_hint` の JWS 検証は全経路で実施し、壊れた hint は `invalid_request` / `login_required` で拒否する。ただしセッション subject との突合は `prompt=none` のままにする。

- 長所: 「検証されない入力を保存する」構造だけを解消できる。挙動変化が小さい。
- 短所: アカウント取り違えは解消しない。

### 方針D: 現状を意図的挙動として固定する

`prompt=none` 以外では `id_token_hint` を無視することを README / 生成コードコメント / `basic-op-requirement-traceability.md` に明記し、`conformance.test.ts` で固定する。

- 長所: コスト最小。
- 短所: SHOULD を外したままで、アカウント取り違えのリスクが残る。

### 判断材料

- 方針A が仕様・UX・セキュリティのいずれでも最良だが、ログイン画面の変更を伴う。
- 方針B は最小コストで取り違えを潰せる。**まず B を入れ、後で A へ拡張する**という段階導入が現実的な選択肢。
- `prompt=select_account` の Phase 2（`tasks/p3-prompt-select-account-phase2.md`）でアカウント選択 UI を持つなら、方針A の 4 はそこへ合流できる。**両タスクの順序を人間が決めるとよい。**

## 8. タスク案

- [ ] 現状（対話フローで `id_token_hint` が無視され、別 subject の認可コードが発行される）を統合テストで**再現・固定**する
- [ ] 方針A〜D のいずれを採るかを決定する（人間判断）
- [ ] 方針A/B/C: `id_token_hint` の `validateIdTokenHint` 呼び出しを `prompt=none` 分岐の外へ引き上げ、全経路で検証する
- [ ] 方針A/B: SSO 高速経路（`consentAlreadyGranted` 判定の前）に hint subject 一致条件を追加する
- [ ] 方針A: ログイン画面テンプレートへ hint subject を伝播し、対象ユーザーを提示／固定する。ログイン結果が hint と異なる場合の挙動を決める
- [ ] 修正点は `packages/cli/src/frameworks/hono/templates.ts`（`authorizeRouteTemplate` / `loginRouteTemplate`）の 1 箇所。`web-standard/templates.ts` が再エクスポートするため express / fastify / nextjs にも反映される。Next.js のログイン画面のみ `web-standard/templates.ts` の別テンプレートなので個別に確認する
- [ ] `samples/*/conformance.test.ts`（生成元は `packages/cli`）に「hint 一致 / 不一致 / 不正 hint」の契約テストを追加する
- [ ] `tests/e2e` に実ブラウザでの「セッション User B + hint User A」シナリオを追加する
- [ ] `study-material/basic-op-requirement-traceability.md` の `OP-Req-id_token_hint` に適用範囲の注記を入れる
- [ ] `tasks/p3-prompt-select-account-phase2.md` との実施順序を決める

## 9. 実装状況（2026-07-27 時点）

`tasks/done/p1-id-token-hint-verification-all-prompt-paths.md` として、**方針A と方針B の共通部分**のみを実装済み。

- `id_token_hint` の検証（署名・`iss`・`aud`・`exp`・`iat`）を `prompt=none` 分岐の外へ引き上げ、全 prompt 経路で実行する
- SSO 高速経路のセッション採用条件に hint subject の一致を追加し、不一致なら既存セッションを再利用しない
- 不一致時は `login_required` を即返さず**ログイン画面へ落とす**

未着手のまま残っているのは方針A固有の部分（ログイン画面への hint 伝播・対象ユーザーの提示／固定、ログイン結果が hint と異なる場合の挙動）と、方針B（不一致を常に `login_required` で返す）への切り替え判断。`tasks/p3-prompt-select-account-phase2.md` との実施順序も未決のまま。
