# `error_description` に攻撃者制御の入力値が無制限に反射される（長さ上限・反射方針の不在）

## ステータス

🟡 Medium（防御の多層化 / 可用性 / 相互運用性。XSS は既に別の層で緩和済み）/ タスク化済み

タスク: `tasks/p3-error-description-length-bound-and-ascii-literals.md`（方針A + 方針B + 方針E）。
方針C（反射をやめて固定文言化）と方針D（反射方針の統一）は人間の判断待ちとして保留。
タスクのスコープ外として明記してある。

## 1. このトピックで確認したいこと

core の各バリデーション関数は、**リクエスト由来の値をそのまま `error_description` に埋め込む**。

`packages/core/src/authorization-request.ts:966`:

```ts
throw new AuthorizationError(
  AuthorizationErrorCode.UnsupportedResponseType,
  `Unsupported response_type: ${responseType}`,   // ← 攻撃者が自由に決められる文字列
  redirectUri,
  state,
);
```

これは 1 箇所ではない。認可エンドポイント・トークンエンドポイントを合わせて
**10 箇所以上**が同じ形をしている（§4.1 に一覧）。

埋め込まれた値は `sanitizeErrorDescription`（`packages/core/src/error-utils.ts:14-26`）を通ってから、

- 認可エラーの **リダイレクト URL のクエリパラメータ**
- トークン／内省／失効エラーの **JSON ボディ**
- UserInfo エラーの **`WWW-Authenticate` ヘッダ**
- 非リダイレクトエラーの **HTML エラーページ**

の 4 経路へ出ていく。

`sanitizeErrorDescription` は **文字集合しか制限していない**。確認したいのは次の 3 点。

1. 「攻撃者の入力をそのままエラー説明に反射する」という方針は、
   RFC 6749 §5.2 が `error_description` に与えた役割と整合しているか
2. **長さ上限が無い**ことで、どの経路にどんな実害が出るか
3. 文字集合の置換規則（不許可文字を `?` に置換）が、**OP 自身が書いた文言**を
   壊していないか

### 既存ファイルとの差分（重複回避）

本トピックに隣接するファイルは複数あるが、いずれも**別の層**を扱っている。

| 既存ファイル | 扱っている層 | 本ファイルとの差分 |
|---|---|---|
| `tasks/done/p1-authorization-error-description-redirect.md` | `error_description` を redirect に**載せる**（機能追加） | 本ファイルは載せる**中身の方針**（何を、どこまでの長さで載せるか） |
| `study-material/done/generated-login-consent-html-escaping-consistency.md` / `tasks/done/p2-generated-views-html-escaping-consistency.md` | **ビュー側の HTML エスケープ** | エスケープは既に実装済み（§4.4）。本ファイルは「そもそも何を渡すか」 |
| `study-material/done/untrusted-input-payload-size-dos-hardening.md` | **入力**のサイズ・深さ上限（パース時のコスト） | 本ファイルは**出力**（反射）側。入力を受理したあと、それを外へ返す量の話 |
| `study-material/error-response-cross-endpoint.md` | エラーレスポンスの**形式・ステータス・ヘッダ**の横断整理 | 形式ではなく `error_description` の**内容**の方針 |
| `study-material/audit-logging-and-observability.md` | ログに何を出すか | クライアントへ返す値の話（ログは出口が違う） |

---

## 2. 関連する仕様・基準（このトピック固有の差分）

### 2.1 RFC 6749 §5.2 — `error_description` は「クライアント開発者向け」である

逐語:

> **error_description**
> OPTIONAL. Human-readable ASCII [USASCII] text providing additional information,
> **used to assist the client developer in understanding the error that occurred.**
> Values for the "error_description" parameter MUST NOT include characters outside
> the set %x20-21 / %x23-5B / %x5D-7E.

そして Appendix A.8:

> error-description = 1*NQSCHAR

Appendix A の共通定義:

> NQSCHAR = %x20-21 / %x23-5B / %x5D-7E

→ **事実 1**: `error_description` の目的は **クライアント開発者のデバッグ支援**である。
「攻撃者が送った値を鏡のように返す」ことは目的に含まれていない。

→ **事実 2**: 文字集合の制約は MUST だが、**長さの上限は仕様に無い**
（`1*NQSCHAR` は「1 文字以上」であり上限を課さない）。

→ **事実 3**: 除外されるのは `"`（0x22）と `\`（0x5C）と制御文字・非 ASCII のみ。
**`<` `>` `&` `'` はすべて許容集合の中にある**（0x3C / 0x3E / 0x26 / 0x27 はいずれも 0x23-0x5B の範囲）。
つまり RFC 6749 の charset 制約は **HTML 安全性を一切保証しない**。

### 2.2 RFC 6749 §4.1.2.1 — 認可エラーは redirect URI のクエリに載る

§4.1.2.1 は、リダイレクト可能な認可エラーを
`application/x-www-form-urlencoded` 形式でリダイレクト URI の **query component** に付けると定める。

→ **帰結**: `error_description` の長さは **リダイレクト URL の全長**に直結する。
URL の長さ上限は RFC 3986 では規定されないが、ブラウザ・プロキシ・
リバースプロキシには実務上の上限がある（一般的なミドルウェアの既定は 4KB〜8KB 程度）。

→ **判断材料**: `error_description` が長すぎると、
**エラーリダイレクト自体が届かなくなる**（クライアントは 414 やプロキシの拒否を見る）。
「エラーを伝えるための仕組みが、エラーを伝えられなくする」ことになる。

### 2.3 RFC 6750 §3 — `WWW-Authenticate` の値は quoted-string

RFC 6750 §3 は Bearer チャレンジの `error_description` を
`quoted-string`（RFC 7230 §3.2.6）として定義する。
`"` と `\` を含められないのはこのためであり、
`sanitizeErrorDescription` がこの 2 文字を除外しているのは正しい。

→ ただしここでも **長さの上限は無い**。HTTP ヘッダ全体のサイズ上限は
サーバ／ランタイム依存（Cloudflare Workers など、エッジランタイムでは厳しい）。

### 2.4 RFC 9700（OAuth 2.0 Security BCP）§2.5 ほか — 未認証エンドポイントの濫用耐性

認可エンドポイントは未認証・パブリックである。
RFC 9700 は未認証エンドポイントが濫用に対して堅牢であるべきとする。

→ **判断材料**: 「攻撃者が送った 100KB の `response_type` をそのまま返す」という挙動は、
サービス拒否そのものではないが **増幅（amplification）の性質**を持つ。
攻撃者は 1 リクエストで、OP に対して同量のレスポンス生成と、
**クライアント側サーバのログへの同量の書き込み**を強制できる。

### 2.5 仕様が規定していないこと（＝実装判断が要る範囲）

- `error_description` の長さ上限
- 攻撃者制御の入力を反射してよいか
- 不許可文字を「除去する」か「置換する」か（RFC 6749 は「含めてはならない」としか言わない）

→ **これらはすべて実装の裁量**である。本ファイルはその裁量をどう使うかの判断材料を整理する。

---

## 3. 参照資料

- **RFC 6749（The OAuth 2.0 Authorization Framework）**
  <https://datatracker.ietf.org/doc/html/rfc6749>
  - §4.1.2.1 Error Response — 認可エラーを redirect URI の query に載せる
  - §5.2 Error Response — `error_description` の目的（"to assist the client developer"）と
    文字集合 MUST（`%x20-21 / %x23-5B / %x5D-7E`）
  - Appendix A.8 "error_description" Syntax — `error-description = 1*NQSCHAR`
  - Appendix A（共通定義）— `NQSCHAR = %x20-21 / %x23-5B / %x5D-7E`
- **RFC 6750（Bearer Token Usage）** <https://datatracker.ietf.org/doc/html/rfc6750>
  - §3 The WWW-Authenticate Response Header Field — `error_description` は quoted-string
- **RFC 7230（HTTP/1.1 Message Syntax and Routing）**
  <https://datatracker.ietf.org/doc/html/rfc7230>
  - §3.2.6 Field Value Components — quoted-string の定義
- **RFC 9700（Best Current Practice for OAuth 2.0 Security）**
  <https://datatracker.ietf.org/doc/html/rfc9700>
  - 未認証エンドポイントの濫用耐性
- **OpenID Connect Core 1.0** <https://openid.net/specs/openid-connect-core-1_0.html>
  - §3.1.2.6 Authentication Error Response — 認可エラー応答（RFC 6749 §4.1.2.1 を踏襲）
- **OWASP — Unvalidated Redirects / Log Injection の一般原則**
  <https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html>
  （反射値がログへ入る際の一般的注意。仕様ではなく一般則として参照）

---

## 4. 現在の実装確認

### 4.1 反射している箇所（core）

`packages/core` 内で、**リクエスト由来の値**を `error_description` に埋め込んでいる箇所。

| ファイル:行 | 埋め込む値 | 攻撃者が制御できるか |
|---|---|---|
| `authorization-request.ts:541` | `prompt` の各値 | ✅ 完全に制御可 |
| `authorization-request.ts:662` | `code_challenge_method` | ✅ |
| `authorization-request.ts:966` | `response_type` | ✅ |
| `authorization-request.ts:980` | `response_type` | ✅ |
| `authorization-request.ts:1077` | `display` | ✅ |
| `refresh-token-grant.ts:160` | 要求 scope のうち超過分（`invalidScopes.join(' ')`） | ✅ |
| `token-request.ts:416` | `grant_type` | ✅ |
| `token-request.ts:468` | `grant_type` | ✅ |
| `token-exchange-request.ts`（experimental）| 固定文言のみ | ❌（設計済み） |
| `authorization-request.ts:402,411,419,431,437` | **登録済み** `redirect_uri` | ❌（設定由来。`server_error` なのでリダイレクトもしない） |
| `authorization-request.ts:758` | resolver が返した `clientId` | ❌（設定・実装由来） |

→ **確認**: 攻撃者が完全に制御できる反射は **8 箇所**。
いずれも「リダイレクト可能なエラー」であり、
`error_description` はクライアントの redirect URI へ届く。

Token Exchange の実装（experimental）は、
**あえて固定文言だけを返す**方針を明示的に採っている
（`token-exchange-request.ts:32-40`、`:311` のコメント: 「allowedTargets の内容・部分一致情報を
露出しない固定文言」）。
→ **同じリポジトリ内で、core と experimental の方針が揃っていない**。

### 4.2 `sanitizeErrorDescription` は文字集合だけを見る

`packages/core/src/error-utils.ts:14-26`:

```ts
export function sanitizeErrorDescription(value: string): string {
  let result = '';
  for (let i = 0; i < value.length; i++) {
    const code = value.charCodeAt(i);
    const allowed =
      code === 0x20 || code === 0x21 ||
      (code >= 0x23 && code <= 0x5b) ||
      (code >= 0x5d && code <= 0x7e);
    result += allowed ? value[i] : '?';
  }
  return result;
}
```

- **長さ上限が無い**。入力 1MB なら出力も 1MB。
- 不許可文字は **`?` に置換**（除去ではない）。
- `<` `>` `&` `'` は **通す**（§2.1 の事実 3）。

### 4.3 出口 1: 認可エラーの redirect URL

生成 OP の `buildErrorRedirect`（`packages/cli/src/frameworks/hono/templates.ts` 内、
JARM 有効時 :1969 付近／無効時 :2048 付近）:

```ts
const url = new URL(redirectUri);
url.searchParams.set('error', error);
if (description) url.searchParams.set('error_description', description);
if (state) url.searchParams.set('state', state);
```

`URLSearchParams.set` が percent-encoding を行うため、
**URL 構造の破壊やパラメータ注入は起きない**。ここは安全。

残るのは **長さ**である。`error_description` が長いほど URL が長くなる（§2.2）。

### 4.4 出口 2: HTML エラーページ（エスケープ済み）

生成 OP の `defaultErrorPage`:

```ts
function defaultErrorPage(params: ErrorPageParams): string {
  // Escape error and error_description so a crafted error_description cannot
  // inject markup into the browser error page (XSS).
  const descriptionHtml = params.errorDescription
    ? `  <p>${escapeHtml(params.errorDescription)}</p>\n`
    : '';
  ...
}
```

→ **既定ビューでは XSS は成立しない**。
`study-material/done/generated-login-consent-html-escaping-consistency.md` /
`tasks/done/p2-generated-views-html-escaping-consistency.md` の成果である。

ただし本リポジトリはビューの差し替えを明示的に推奨しており
（`Views` インターフェース、`createApp({ views: ... })`）、
**利用者が独自ビューでエスケープを忘れると即座に XSS になる**。
`sanitizeErrorDescription` が `<` `>` を通すため、
「core が sanitize しているから安全だろう」という誤解は成立しやすい。

→ **本ファイルの立場**: XSS は既に緩和済みなので**主要な論点ではない**。
ただし「`sanitize` という名前が HTML 安全性を含意してしまう」問題は残る（§7 方針A）。

### 4.5 出口 3: `WWW-Authenticate` ヘッダ

UserInfo エラー（`packages/cli/src/frameworks/hono/templates.ts:3843` 付近）:

```ts
`Bearer realm="UserInfo", error="${error.error}", error_description="${error.errorDescription}"`,
```

`"` と `\` は sanitize で落ちるため quoted-string は壊れない。
UserInfo の `error_description` は現在すべて固定文言であり、
反射は起きていない（`packages/core/src/userinfo.ts` の各 throw を確認）。
→ **現時点では問題なし**。ただし将来ここに反射を足すと、ヘッダ長の問題が出る。

### 4.6 実害の見積もり

| 影響 | 深刻度の評価 | 根拠 |
|---|---|---|
| XSS | **低**（既定ビューで緩和済み） | §4.4 |
| URL パラメータ注入 | **無し** | §4.3（percent-encoding） |
| ヘッダインジェクション | **無し** | §4.5（`"` `\` を除去、制御文字も除去） |
| **エラーリダイレクトの到達失敗** | **中** | §2.2。長い URL がプロキシ／ブラウザに拒否される |
| **クライアント側ログの増幅** | **中** | 攻撃者が RP のログへ任意 ASCII を大量書き込みできる |
| **OP 側の帯域・CPU** | **低** | 入力サイズに線形。§4.7 の入力側上限が効けば抑えられる |
| 情報漏洩 | **無し** | 反射しているのは攻撃者自身が送った値のみ |

→ **総合すると「重大な脆弱性」ではない**。
「防御の多層化と、可用性・運用品質の改善」として扱うのが妥当である。
ステータスを 🟡 Medium としているのはこの評価による。

### 4.7 入力側の上限も無い（関連トピックとの接続）

`response_type` / `grant_type` / `display` / `prompt` にはいずれも長さ検証が無い。
`claims` パラメータだけは `maxClaimsParameterLength`（既定 16384、
`packages/core/src/authorization-request.ts:243`）があるが、
これは JSON パースコスト対策であり反射対策ではない。

→ 入力側の上限は `study-material/done/untrusted-input-payload-size-dos-hardening.md` の管轄。
**入力側に上限を入れれば反射側の問題もかなり緩和される**が、
`error_description` は OP 自身の文言も連結するため、
**出力側の上限は独立して必要**である（§7）。

---

## 5. 現在の実装との差分

### 満たしていること

- RFC 6749 §5.2 の文字集合 MUST を満たしている（`sanitizeErrorDescription`）。
- RFC 6750 §3 の quoted-string 制約を満たしている（`"` `\` を除去）。
- 認可エラーの redirect URL は percent-encoding されており構造破壊は起きない。
- 既定ビューは HTML エスケープ済みで、XSS は成立しない。
- Token Exchange（experimental）は反射しない方針を明示的に採っている。

### 不足している可能性があること

- **`error_description` の長さ上限が無い**（出力側）。
- **反射してよいかの方針が決まっていない**。
  core は反射し、experimental は反射しない。同じリポジトリ内で不統一。
- **不許可文字を `?` に置換する規則が、OP 自身の文言を壊している**（§5 次項）。

### 実装はあるが仕様上の確認が必要なこと

- `sanitizeErrorDescription` の置換規則。
  `packages/core/src/authorization-request.ts:437` の文言:

  ```ts
  `Registered redirect_uri must use https:// or loopback http:// — got ${uri}`
  ```

  ここに含まれる **em dash（`—`, U+2014）は非 ASCII なので `?` に置換される**。
  結果としてクライアントには `... loopback http:// ? got ...` が届く。
  RFC 6749 §5.2 が「ASCII text」と定めている以上、**非 ASCII を落とすこと自体は正しい**。
  問題は **OP 自身が非 ASCII を含む文言を書いてしまっていること**であり、
  これは lint / テストで防げる種類の不整合である。
  → 現状 `AuthorizationErrorCode.ServerError` なのでクライアントへリダイレクトされないが、
    JSON / HTML エラーページには出る。

- 置換（`?`）か除去かの選択。
  置換は「何かが落ちた」ことが見えるので**デバッグ支援としては優れている**が、
  長さが変わらないため §4.6 の増幅は抑えられない。
  → **意図的な選択であるならコメントで明記すべき**。現在コメントは無い。

### セキュリティ上、改善した方がよいこと

- `sanitizeErrorDescription` という名前は「安全化した」と読めるが、
  **`<` `>` `&` を通すので HTML 文脈では安全ではない**。
  ビューを差し替える利用者が誤解する余地がある。
  → JSDoc に「これは RFC 6749 の charset 制約のみを満たす。
    HTML 文脈では別途エスケープが必要」と明記すべき。

### 相互運用性の観点で改善した方がよいこと

- 長い `error_description` を載せた redirect URL は、
  RP 側のミドルウェアで拒否されうる（§2.2）。
  この場合 RP は「エラーが起きた」ことすら受け取れない。
  上限を課すほうが**相互運用性は上がる**。

### Basic OP として提供する上で確認すべきこと

- OIDC Conformance の Basic OP テストプランは、
  エラー応答について `error` の値と redirect の到達を検証するが、
  `error_description` の内容・長さは検証しない。
- → **本トピックは Basic OP 認定に影響しない**。優先度は品質観点で決める。

---

## 6. 改善・追加を検討する理由

### なぜこの改善に価値があるのか

3 つの理由がある。

1. **リポジトリ内の方針が割れている**。
   core は反射し、experimental は固定文言を貫く。
   どちらが本リポジトリの方針なのかが、コードからは読み取れない。
   新しいエンドポイントを足す人（利用者を含む）は、どちらに倣えばよいか判断できない。

2. **「安全な文字集合に限定した」という表現が、実際より強い保証を含意している**。
   `sanitizeErrorDescription` の JSDoc は RFC 6749 の charset を説明しているが、
   `<` `>` が通ることには触れていない。
   ビューを差し替える利用者にとって、これは見落としやすい落とし穴である。

3. **長さ上限は「入れておけば一生問題にならない」種類のガードレール**である。
   入れないと、いつか誰かが RP のログを 1GB 埋められる。
   実装は数行で済む。

### Basic OP として必要か、拡張として有用か

- **Basic OP の要件ではない**（§5）。
- **拡張機能でもない**。既存関数への数行の追加と、方針の明文化。

### 現在のリポジトリ構成から見て導入しやすいか

- **極めて導入しやすい**。
  - 長さ上限は `sanitizeErrorDescription` の中で `slice` するだけ。
    呼び出し側（`AuthorizationError` / `TokenError` / `UserInfoError` /
    `RevocationError` / `IntrospectionError` / `ParError` / `TokenExchangeError` の
    各コンストラクタ）は **すべて既にこの関数を通している**ので、
    1 箇所の変更で全経路に効く。
  - 反射をやめる場合は、8 箇所の文言を固定文言に書き換えるだけ。
- **導入しにくい点**: 反射をやめると **デバッグ体験が悪化する**。
  「`Unsupported response_type: token`」と「`Unsupported response_type`」では、
  クライアント開発者にとっての情報量が違う。
  RFC 6749 §5.2 が明記する目的（"to assist the client developer"）を損なう。
  → この緊張が本トピックの中心的な判断ポイントである。

### 既存実装とどう接続できそうか

- `sanitizeErrorDescription(value, maxLength?)` にオプション引数を足すか、
  モジュール定数（例: `MAX_ERROR_DESCRIPTION_LENGTH`）を置いて常に適用する。
- 反射値だけを切り詰める案（OP の文言は残し、埋め込む値だけ上限をかける）もある。
  こちらのほうがデバッグ体験を損なわないが、埋め込み側 8 箇所の変更が必要になる。

### 利用者・開発者・運用者のメリット

- **RP 開発者**: エラーリダイレクトが確実に届く。
- **OP 運用者**: 反射由来のログ増幅を受けない。
- **本リポジトリの利用者**: 「エラー説明に何を書いてよいか」の方針が明文化され、
  独自エンドポイントを足すときに迷わない。

### 実装しない場合に残る制約・リスク

- 反射の方針が不統一のまま残り、新しいエンドポイントごとに判断がぶれる。
- 長い入力でエラーリダイレクトが届かない事象が、原因不明のまま報告される。
- 独自ビューでのエスケープ漏れが XSS になる（既定ビューは安全だが、差し替えは推奨されている）。

---

## 7. 実装方針の候補（最終判断は人間が行う）

### 方針A: 契約の明文化のみ（最小・非破壊）

- `sanitizeErrorDescription` の JSDoc に次を明記する。
  - この関数は **RFC 6749 §5.2 の charset 制約のみ**を満たす。
  - `<` `>` `&` `'` は **通す**。HTML 文脈では呼び出し側が別途エスケープすること。
  - 不許可文字を `?` に置換するのは「情報が落ちたことを可視にする」意図的な選択であること。
- `Views` の JSDoc に「`errorPage` を差し替える場合は `errorDescription` を必ずエスケープすること」を明記。

**利点**: リスクゼロ。誤解の防止効果は大きい。
**欠点**: 長さ問題・方針不統一は残る。

### 方針B: 長さ上限を課す（推奨度が高い・非破壊）

- `sanitizeErrorDescription` に上限（例: 256 文字）を導入し、
  超過分は切り詰める。切り詰めたことが分かる印（末尾 `...` 等）を付けるかは選択。
- 上限値の根拠:
  - redirect URL の実務上の余裕（4KB 級のミドルウェア上限に対して十分小さい）
  - `WWW-Authenticate` ヘッダに載せても問題ない大きさ
  - RFC には根拠が無い（§2.5）ので、**運用パラメータとして選ぶ**しかない。
    値そのものは人間が決める。
- 上限を `ProviderConfig` で変えられるようにするかは別途判断。
  固定値のほうが「利用者が緩めて事故る」経路が無く安全側。

**利点**: 1 箇所の変更で全経路に効く。デバッグ体験をほとんど損なわない。
**欠点**: 既存テストのうち、長い `error_description` を期待しているものがあれば更新が要る
（現状そのようなテストは無いと見られるが、要確認）。

### 方針C: 反射をやめて固定文言にする（experimental と揃える）

- §4.1 の 8 箇所を、値を含まない固定文言に置き換える。
  例: `Unsupported response_type: ${responseType}` → `Unsupported response_type`

**利点**: 反射面がゼロになる。experimental と方針が揃う。
**欠点**: RFC 6749 §5.2 が明記する「クライアント開発者の支援」という目的を大きく損なう。
本リポジトリは PoC 開発者を主要ターゲットにしており、
**デバッグ情報の削減は利用者体験を直接下げる**。
→ **セキュリティ上の実害が小さい（§4.6）ことを踏まえると、費用対効果が悪い**。
両論併記のために挙げるが、積極的に推す根拠は弱い。

### 方針D: 反射値のみを切り詰める（B の変種）

- 埋め込む値そのものに上限を課すヘルパ（例: `truncateForErrorDescription(value)`）を作り、
  §4.1 の 8 箇所で使う。OP 自身の文言は切り詰めない。

**利点**: OP の説明文が常に完全に届く。デバッグ体験が最も良い。
**欠点**: 変更箇所が 8 箇所。新しい反射を足す人が使い忘れると効かない
（方針B は使い忘れが起きない）。

### 方針E: OP 自身の文言から非 ASCII を排除する（B/D と独立）

- `authorization-request.ts:437` の em dash を ASCII に置き換える。
- `packages/core` 全体で、`AuthorizationError` / `TokenError` などへ渡す
  リテラル文言に非 ASCII が混ざっていないことをテストで固定する。

**利点**: 意図しない `?` の混入がなくなる。実装は極小。
**欠点**: 無し（純粋な改善）。

### 判断材料の整理

| 観点 | 方針A | 方針B | 方針C | 方針D | 方針E |
|---|---|---|---|---|---|
| 長さ問題の解消 | × | ◎ | ○（間接） | ◎ | × |
| デバッグ体験 | 変化なし | ほぼ維持 | **悪化** | 最良 | 改善 |
| 変更箇所 | JSDoc のみ | 1 箇所 | 8 箇所 | 8 箇所＋新関数 | 1 箇所＋テスト |
| 使い忘れリスク | — | 無し | 有り | 有り | 無し |
| 方針の統一 | 明文化される | — | core = experimental | — | — |

- **A + B + E の組み合わせ**が、費用対効果と本リポジトリの優先順位
  （仕様準拠 → セキュリティ → 利用者の使いやすさ）に最もよく合う、というのが本ファイルの整理である。
  ただし **上限値の決定と、C を採らない判断は人間が行うべき**。

---

## 8. タスク案

### T-A（P3・確度高・非破壊・即着手可）: `sanitizeErrorDescription` の保証範囲を明文化する

- `packages/core/src/error-utils.ts` の JSDoc に次を追記
  - RFC 6749 §5.2 の charset 制約のみを満たすこと
  - `<` `>` `&` `'` は許容集合内であり **HTML 安全性は保証しないこと**
  - 不許可文字を `?` に置換するのは意図的であること（除去との差）
- `packages/cli` が生成する `views.ts` の `Views.errorPage` JSDoc に
  「差し替える場合は `errorDescription` を必ずエスケープすること」を追記
- テスト（`packages/core/src/error-utils.test.ts`）:
  - `should keep angle brackets because RFC 6749 allows them`
  - `should replace a double quote with a question mark`
  - `should replace a non-ASCII character with a question mark`

### T-B（P3・要人間判断は上限値のみ）: `error_description` に長さ上限を課す

- `packages/core/src/error-utils.ts` に `MAX_ERROR_DESCRIPTION_LENGTH` を定義し、
  `sanitizeErrorDescription` で切り詰める
- **上限値は人間が決める**（本ファイルは 256 文字を出発点として提示するが、決定しない）
- 切り詰めの印（`...` 等）を付けるかも人間が決める
- テスト要件:
  - `should truncate an error description longer than the maximum length`
  - `should keep an error description at exactly the maximum length unchanged`
  - `should apply truncation after character sanitization`
    （置換で長さが変わらないことを前提に順序を固定する）
- 全エラークラス（`AuthorizationError` / `TokenError` / `UserInfoError` /
  `RevocationError` / `IntrospectionError` / `ParError` / `TokenExchangeError`）が
  この関数を通ることを確認するテストを追加する
- `samples/*/conformance.test.ts`（生成元は `packages/cli`）に、
  長大な `response_type` を送っても redirect URL が上限内に収まることを固定する

### T-C（P3・確度高・非破壊）: OP 自身のエラー文言から非 ASCII を排除する

- `packages/core/src/authorization-request.ts:437` の em dash（`—`）を ASCII に置き換える
- `packages/core` 全体を対象に、エラーコンストラクタへ渡すリテラル文言に
  非 ASCII が含まれていないことをテストで固定する
  （静的検査でも可。`tasks/done/p1-ci-push-trigger-and-static-verification-gate.md` の
  静的検証ゲートに載せる案もある）

### T-D（方針未確定・要人間判断）: 反射方針の統一

- 方針C（固定文言化）を採るかどうかを決める
- 採らない場合は、「core は反射する / experimental の一部は反射しない」という
  差が **意図的である**ことを両モジュールの JSDoc に明記する
- **決定するまで着手しない**

---

## 関連トピック

- `study-material/error-response-cross-endpoint.md` — エラー応答の形式・ステータスの横断整理
- `tasks/done/p1-authorization-error-description-redirect.md` — `error_description` を redirect に載せる（本トピックの前提）
- `study-material/done/generated-login-consent-html-escaping-consistency.md` — ビュー側のエスケープ
- `study-material/done/untrusted-input-payload-size-dos-hardening.md` — 入力側のサイズ上限（直交）
- `study-material/audit-logging-and-observability.md` — ログ出力先での扱い
