# 同意（consent）決定が fail-open：`action` が `deny` 以外なら「承認」として認可コードを発行している

## ステータス

🟠 High（セキュリティ / 生成コード）/ 未着手

## 1. このトピックで確認したいこと

CLI が生成する OP の同意エンドポイント（`routes/consent.ts` の POST ハンドラ）は、フォームの `action`
パラメータが `deny` **以外のすべての値**（未送信・空文字・未知の値・タイプミスを含む）を「ユーザーが承認した」
と解釈し、認可コードを発行して `redirect_uri` へリダイレクトする。

確認したいのは次の 3 点である。

1. OIDC / OAuth の仕様上、OP が「明示的な承認」を得たと言えるのはどの条件か（fail-open が許されるのか）
2. 現在の実装が、承認を **拒否側へ倒す（fail-closed）** 設計になっているか
3. 同意画面の view が送る値（`approve`）と、ハンドラが判定する値（`deny` の否定）と、既存ドキュメントの
   記載（`action=allow`）の **三者が不一致**である状態を、契約としてどう固定するか

本ファイルは「同意の記録・永続化」（`study-material/done/consent-grant-persistence-and-management.md`）や
「部分同意 / granted scope」（`study-material/scope-handling-validation-and-granted-scope.md`）とは別の論点で、
**「同意したという判定そのものの安全側の既定値」**に絞る。

## 2. 関連する仕様・基準

共通の仕様索引は `study-material/basic-op-requirement-traceability.md` §3.3 を参照し、ここでは本トピックに
直接効く条文のみを引く。

### 2.1 OpenID Connect Core 1.0 §3.1.2.4（Authorization Server Obtains End-User Consent/Authorization）

> Once the End-User is authenticated, the Authorization Server MUST obtain an authorization decision
> before releasing information to the Relying Party.

要点は「情報を RP へ渡す前に **authorization decision を取得しなければならない（MUST）**」という点にある。
仕様は「decision をどの UI・どのパラメータで表現するか」までは規定しないが、**decision が取得できたと
判定する条件**は OP の責務である。`deny` という 1 つの否定語に一致しないことを以て「決定が得られた」と
みなす実装は、この MUST を「否定形の一致」に置き換えており、決定が取得できなかったケース（パラメータ欠落・
不正値・別バージョンの view からの POST）を **承認として扱ってしまう**。

### 2.2 OpenID Connect Core 1.0 §3.1.2.1（`prompt=consent`）

`prompt=consent` は「同意画面を必ず再表示して、改めて決定を取り直す」ことを要求する。再表示した画面から
戻ってきた POST が「値が何であれ承認」であれば、再表示の意味（＝改めて意思確認する）が実質的に失われる。

### 2.3 fail-closed の一般原則（本リポジトリ内の既存方針）

`study-material/resolver-and-store-contract.md` は resolver の例外時に fail-closed（拒否側に倒す）で
あるべきこと、そして「誤実装で fail-open を作るリスク」を明示的な論点として挙げている。同意判定はその
最たるもので、**同じ原則を同意ハンドラにも適用すべきか**が本ファイルの判断対象となる。

> 注（不明点として明記）: 「同意の肯定値をどの文字列にするか」（`approve` / `allow` / `accept`）を
> 規定する OIDC / OAuth の一次仕様は存在しない。これは OP 実装のローカルな UI 契約であり、
> 仕様準拠の問題ではなく **本リポジトリが生成コードの契約として何を固定するか** の問題である。

## 3. 参照資料

- OpenID Connect Core 1.0 incorporating errata set 2 §3.1.2.4 Authorization Server Obtains End-User
  Consent/Authorization — https://openid.net/specs/openid-connect-core-1_0.html#Consent
  （「MUST obtain an authorization decision before releasing information to the Relying Party」の根拠）
- OpenID Connect Core 1.0 §3.1.2.1 Authentication Request（`prompt=consent` の意味論）—
  https://openid.net/specs/openid-connect-core-1_0.html#AuthRequest
- 本リポジトリ内:
  - `samples/hono-cloudflare/src/oidc-provider/routes/consent.ts:51,67`（判定箇所）
  - `samples/hono-cloudflare/src/oidc-provider/views.ts:173-174`（view が送る値）
  - `packages/cli/src/frameworks/hono/templates.ts:3438,4259-4260`
  - `packages/cli/src/frameworks/web-standard/templates.ts:1453,1456,1503`
  - `study-material/done/consent-grant-persistence-and-management.md:102,162,187`
    （`action=allow` 時に記録する、と記述されている＝実装と表記が不一致）
  - `study-material/resolver-and-store-contract.md`（fail-closed 原則の既存記述）

## 4. 現在の実装確認

### 4.1 判定ロジック（全 sample・全テンプレート共通）

`samples/hono-cloudflare/src/oidc-provider/routes/consent.ts`:

```ts
const action = String(body['action'] ?? '');   // L51: 欠落時は空文字になる
...
if (action === 'deny') {                        // L67: 「deny のときだけ拒否」
  // access_denied で redirect_uri へ戻す
  ...
  return c.redirect(redirectUrl.toString());
}

// ここから先はすべて「承認」経路
const session = await authSessionStore.get(transactionId);
...
const authCodeData = await createAuthorizationCode({ ... });
await authCodeStore.set(authCodeData.code, authCodeData);
await consentResolver.recordConsent?.(session.subject, transaction.clientId, grantedScope);
```

### 4.2 view が実際に送る値

`samples/hono-cloudflare/src/oidc-provider/views.ts:173-174`:

```html
<button type="submit" name="action" value="approve">Approve</button>
<button type="submit" name="action" value="deny">Deny</button>
```

肯定側は `approve`。しかしハンドラは `approve` を検査していない。

### 4.3 影響範囲（生成物すべて）

同一パターンが以下すべてに存在することを確認した。

| 対象 | 判定箇所 | view |
|---|---|---|
| `samples/hono-cloudflare` | `routes/consent.ts:67` | `views.ts:173` |
| `samples/express-flyio` | `routes/consent.ts:67` | `views.ts:173` |
| `samples/fastify-flyio` | `routes/consent.ts:67` | `views.ts:173` |
| `samples/nextjs-vercel` | `src/app/_oidc-provider/routes/consent.ts:67` / `src/app/consent/actions.ts:37` | `_oidc-provider/views.ts:173` / `src/app/consent/page.tsx:54` |
| CLI テンプレート | `frameworks/hono/templates.ts:3438` / `frameworks/web-standard/templates.ts:1503` | `templates.ts:4259` / `templates.ts:1453` |

`samples/*/src/oidc-provider` は CLI 生成物のため、修正は `packages/cli` 側テンプレートで行う必要がある
（CLAUDE.md のルール）。

### 4.4 既存の防御で塞がれている範囲

- CSRF: `validateCsrfToken(transaction, csrfToken)` が POST の直前に走る（`consent.ts:60`）。したがって
  **外部サイトからの純粋な CSRF は成立しない**（攻撃者は `transaction_id` と `csrf_token` の両方を知らない）。
- 認証: `authSessionStore.get(transactionId)` が無ければ 400 になる（`consent.ts:79-85`）ため、
  ログイン前の承認は起きない。

したがって本件は「リモートの第三者が任意に同意を捏造できる」重大脆弱性ではない。**残るのは
「同意画面まで到達したブラウザが、明示的な承認意思なしに承認扱いになる」経路**である。

## 5. 現在の実装との差分

満たしていること:

- ✅ 同意画面を表示し、`deny` の明示的な拒否経路（`access_denied` + `state` + `iss` の返却）を実装している
- ✅ CSRF トークン検証と認証済みセッション確認が承認経路の前段にある
- ✅ 承認時に `recordConsent` / `recordGrant` で同意を記録している

不足している可能性があること:

- 🟠 **fail-open な既定値**: `action` が欠落・空文字・未知値のとき承認になる。具体的に到達しうる経路:
  - **（最も現実的）** 利用者が view をカスタマイズして `value="allow"` / `value="accept"` に変えた場合、
    **拒否ボタンだけが壊れずに残り、承認は「意図せず常に成立」する**。誤りが画面上で観測できないため
    気づけない。本リポジトリは「生成コードを改造しながら検証する」ことを前提としており、
    ボタン文言・値の書き換えは最も起こりやすいカスタマイズである。
  - 自動化テスト・スクリプト・フォームを再構成するツール等が、`csrf_token` は送るが `action` を
    送らずに POST した場合。
  - （未検証）submit ボタンの name/value が付かない送信経路が実装差として存在した場合、ユーザーが
    何もボタンを押していないのに承認される。現行の HTML 仕様では暗黙送信（Enter キー）でも最初の
    submit ボタンの name/value が送られるため、**この経路が実在するかは環境依存であり、
    本ファイルの根拠としては採用しない**（推測と事実を分けるため明記する）。
- 🟠 **契約の三者不一致**: view は `approve`、ハンドラは「`deny` の否定」、ドキュメントは `allow`。
  どれが正なのかがコードから読み取れず、利用者がカスタマイズする際の基準が無い。
- 🟡 **conformance.test.ts で肯定値が固定されていない**: `deny` 経路は
  `samples/nextjs-vercel/src/app/_oidc-provider/conformance.test.ts:800` などで固定されているが、
  「未知の `action` 値では承認しない」という契約テストは無い。したがって利用者が生成コードを改変して
  この契約から外れても、テスト失敗として検知できない（CLAUDE.md の conformance.test.ts 方針と不整合）。

セキュリティ上、改善した方がよいこと:

- 認可の意思決定は「肯定を明示的に検出する」設計（allowlist）にすべきで、「否定を検出しなかった」という
  否定形（denylist）で判定すべきではない。denylist 判定は、値の追加・変更・欠落に対して常に危険側へ倒れる。

Basic OP として提供する上で確認すべきこと:

- Basic OP 認定テストに「未知の consent action」を送る module は無いため、**認定可否には影響しない**。
  本件は認定要件ではなく、生成コードの安全な既定値という OSS 品質の論点である。

## 6. 改善・追加を検討する理由

- **なぜ価値があるか**: 本ライブラリの利用者は「生成コードを改造しながら仕様を検証する」ことを前提として
  いる（CLAUDE.md）。view のボタン値を書き換えるのは最も起こりやすいカスタマイズであり、そこで
  「拒否だけが動いて承認は常に成立する」壊れ方をするのは、OSS が提供すべき既定値として不適切。
- **Basic OP に必要か / 拡張か**: どちらでもない。**既存実装の安全側修正**であり、新機能ではない。
- **導入しやすさ**: 🟢 非常に高い。判定式 1 行と view の値、テンプレート、conformance テストの追加のみ。
  core の API 変更は不要で、後方互換性の懸念も小さい（`approve` を送る現行 view はそのまま動く）。
- **既存実装との接続**: `consent.ts` の既存の `deny` 分岐の直後に「肯定値でなければエラー」を足すだけ。
  `views.ts` / テンプレートの値と 1 箇所で対応付ける。
- **利用者・運用者のメリット**: カスタマイズ時の壊れ方が「承認が通らない（すぐ気づく）」側に倒れる。
  監査時に「同意はどの値で成立するか」がコードから一意に読める。
- **実装しない場合に残るリスク**: 明示的な承認意思なしに認可コードが発行されうる経路が残り続け、
  かつ view をカスタマイズした利用者がそれをテストで検知できない。

## 7. 実装方針の候補

最終判断は人間が行う。以下は判断材料。

### 方針A: 肯定値を allowlist で明示（fail-closed）— 最小変更

```ts
const action = String(body['action'] ?? '');

if (action === 'deny') {
  // 既存の access_denied 経路（変更なし）
}

// OIDC Core 1.0 §3.1.2.4: 情報を RP へ渡す前に authorization decision を取得しなければならない。
// 肯定値を明示的に検出する（未知値・欠落は決定が得られていないので承認しない）。
if (action !== 'approve') {
  return renderView(views.errorPage({
    error: 'Invalid consent decision. Please use the Approve or Deny button.',
    statusCode: 400,
  }), { status: 400 });
}
```

- 長所: 変更が局所的。`redirect_uri` へは飛ばさない（決定が得られていないため `access_denied` とも言えない）
- 短所: 既存の利用者が view を `allow` に書き換えていた場合、承認が 400 になる（＝意図どおり検知される
  が、破壊的変更として release note に書く必要がある）

### 方針B: 肯定値を複数許容（`approve` / `allow` / `accept`）

- 長所: 利用者のカスタマイズ耐性が高い
- 短所: 「同意の肯定値は何か」が曖昧なままで、契約を固定するという目的を達成しない。非推奨

### 方針C: 未知値を「拒否」として扱い `access_denied` で `redirect_uri` へ戻す

- 長所: クライアントに OAuth エラーとして届くので、RP 側でハンドリングできる
- 短所: 「ユーザーが拒否した」と「決定が取得できなかった」を同じ `access_denied` に潰す。
  OIDC Core §3.1.2.6 のエラー語彙としては `access_denied` は「resource owner が拒否した」意味であり、
  厳密には誤り。方針A の 400 のほうが意味論的に正確

### 方針D: `action` 自体をやめ、submit ボタンの `name` で分岐（`name="approve"` / `name="deny"`）

- 長所: 「押されたボタンだけが送信される」HTML の性質を使うので、欠落時は両方 undefined になり
  自然に fail-closed になる
- 短所: 既存 view / テンプレート / conformance テストの書き換え量が増える。Next.js の Server Action
  （`src/app/consent/actions.ts`）とも形を揃える必要がある

推奨は方針A（意味論が最も正確で変更が最小）。ただし破壊的変更の扱いを人間が判断すること。

## 8. タスク案

- [ ] 方針（A / B / C / D）を決定する（人間判断）
- [ ] `packages/cli` のテンプレート（`frameworks/hono/templates.ts`、`frameworks/web-standard/templates.ts`）
      の consent ハンドラを、肯定値の明示検出に変更する
- [ ] Next.js の Server Action 版（`src/app/consent/actions.ts` を生成するテンプレート）も同じ判定にする
- [ ] view 側の肯定値（現行 `approve`）とハンドラの期待値を 1 箇所で対応付け、コメントで
      「この値を変えるならハンドラも変えること」を明記する
- [ ] `packages/cli` の conformance.test.ts 生成コードに以下の契約テストを追加する
      （CLAUDE.md: conformance.test.ts は直接編集せず生成側を変更する）
      - `action` 未送信で POST → 認可コードが発行されないこと
      - `action=''` / `action=unknown` で POST → 認可コードが発行されないこと
      - `action=approve` で POST → 従来どおり認可コードが発行されること
      - `action=deny` で POST → 従来どおり `access_denied` で `redirect_uri` へ戻ること
- [ ] 4 つの sample を再生成し `conformance.test.ts` の差分を確認する
- [ ] `study-material/done/consent-grant-persistence-and-management.md` の `action=allow` 記述を
      実際の値へ修正する（ドキュメントと実装の不一致解消）
- [ ] 破壊的変更となる場合は `RELEASE.md` / release note に記載する
