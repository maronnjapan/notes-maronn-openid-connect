# Refresh Token の絶対失効時刻がクライアントから観測できない（90 日の hard expiry の不可視性）

## ステータス

🟡 Medium（相互運用性 / 運用・UX。仕様違反ではない）/ タスク化済み

タスク: `tasks/p3-refresh-token-absolute-expiry-contract-documentation.md`（方針A + 方針B の一部＝契約の明文化）。
方針C（非標準 `refresh_expires_in` の追加）と方針D（アイドル失効併用時の `exp` の意味）は
人間の判断待ちとして保留。タスクのスコープ外として明記してある。

## 1. このトピックで確認したいこと

生成 OP は Refresh Token に **初回発行時刻からの絶対寿命（既定 90 日 = 7776000 秒）** を課しており、
ローテーションを何度繰り返しても失効時刻は前へ進まない（sliding expiry を持たない）。
この設計自体は `tasks/done/p1-refresh-token-absolute-lifetime.md` で確定済みである。

本ファイルで確認したいのは、その帰結として生まれる次の一点である。

> **クライアントは、自分が保持している Refresh Token が「いつ hard expire するか」を
> トークンレスポンスからは一切知ることができない。**

`access_token` には `expires_in` があるが、`refresh_token` の残存寿命を伝える標準パラメータは
トークンレスポンスに存在しない。結果としてクライアントは、

- 90 日目の refresh 要求が **予告なく `invalid_grant`** になる、
- その `invalid_grant` が「絶対寿命切れ」なのか「ローテーション再利用検知による family 失効」なのか
  「同意撤回」なのかを **区別できない**、

という状態に置かれる。エンドユーザから見ると「ある日突然ログアウトされた」になる。

確認したいのは次の 3 点。

1. Refresh Token の失効時刻をクライアントへ伝える **標準的な手段は何か**（そもそも存在するのか）
2. 本リポジトリが既に持っている機構（Token Introspection の `exp`）でそれを満たせているか
3. 満たせていないとしたら、**どこを埋めるのが仕様準拠かつ OSS 利用者にとって使いやすいか**

### 既存ファイルとの差分（重複回避）

このトピックは「RT の寿命をどう決めるか」ではなく「**決まった寿命をどうクライアントに見せるか**」を扱う。

| 既存ファイル | 扱っている論点 | 本ファイルとの差分 |
|---|---|---|
| `tasks/done/p1-refresh-token-absolute-lifetime.md` | 絶対寿命の導入そのもの（sliding をやめる） | 本ファイルは導入済み前提で「可観測性」を扱う |
| `study-material/token-lifetime-security-policy.md` | 各トークンの寿命値の妥当性・ポリシー | 寿命「値」ではなく寿命「の通知手段」 |
| `study-material/done/refresh-token-idle-inactivity-timeout.md` / `tasks/p2-refresh-token-idle-timeout-generated-op-wiring.md` | アイドル失効という**別軸の失効** | 本ファイルは絶対寿命側。ただし §5 で「2 軸あることが不可視性を悪化させる」点だけ触れる |
| `study-material/refresh-token-rotation-replay-grace.md` | 再利用検知の猶予 | 失効の**理由の区別不能性**は本ファイルで扱うが、猶予の設計はあちら |
| `study-material/done/introspection-refresh-token-response-claim-asymmetry.md` | Introspection の RT レスポンスの欠落クレーム | 本ファイルは「Introspection を可観測性の答えとして採用してよいか」を扱い、レスポンス内容の差分はあちらへ委譲 |

---

## 2. 関連する仕様・基準（このトピック固有の差分）

Basic OP の定義・共通仕様索引は `study-material/basic-op-requirement-traceability.md` を参照。
ここでは「RT の寿命通知」に直接効く条文だけを引く。

### 2.1 RFC 6749 §5.1 — トークンレスポンスに RT の寿命フィールドは無い

RFC 6749 §5.1 が定義する成功レスポンスのパラメータは次のとおり。

- `access_token`（REQUIRED）
- `token_type`（REQUIRED）
- `expires_in`（RECOMMENDED）— **「the lifetime in seconds of the access token」**
- `refresh_token`（OPTIONAL）
- `scope`（条件付き REQUIRED）

**`expires_in` はアクセストークンの寿命であると明記されており、Refresh Token の寿命ではない。**
そして Refresh Token の寿命を表すパラメータは §5.1 に存在しない。
OAuth 2.1 draft も §3.2.3（Access Token Response）でこの構造を踏襲しており、
RT 寿命フィールドは追加されていない。

→ **事実**: 「RT の残存寿命をトークンレスポンスで返す」標準的な方法は無い。

### 2.2 RFC 6749 §10.4 / OAuth 2.1 §4.3 — RT の寿命は AS の裁量

RFC 6749 §10.4（Refresh Tokens）は、Refresh Token が長期資格情報であること、
AS が RT の有効性を維持する責務を負うことを述べるが、
**寿命をクライアントへ通知する義務は課していない**。

OAuth 2.1 draft §4.3.1 も、public client に対する rotation / sender-constraining の要求はするが、
寿命の通知は要求していない。

→ **事実**: 通知しないこと自体は仕様違反ではない。本トピックは「準拠」ではなく
「**相互運用性と運用性**」の問題である。

### 2.3 RFC 7662 §2.2 — Introspection は RT の `exp` を返せる（＝標準的な観測手段）

RFC 7662 §2.2 のレスポンスメンバ定義（逐語）:

> **exp** — OPTIONAL. Integer timestamp, measured in the number of seconds since January 1 1970 UTC,
> indicating when this token will expire, as defined in JWT [RFC7519].

そして §2.1（Introspection Request）は `token` に **アクセストークンだけでなく
Refresh Token も渡せる**ことを前提としており、`token_type_hint` の登録値として
`access_token` と `refresh_token` の両方を定義している。

→ **事実**: 「クライアントが自分の RT の失効時刻を知る」ための **標準的で相互運用可能な経路は
Token Introspection である**。追加の非標準パラメータを発明する必要はない。

ただし RFC 7662 §2.1 は Introspection を **protected resource（リソースサーバ）向け**の
エンドポイントとして位置づけており、「クライアントが自分のトークンを内省する」用途は
明示的には想定されていない。この点は §5 / §7 で判断材料として整理する。

### 2.4 非標準の先行実装（事実としての言及。推奨ではない）

一部の実装は独自パラメータでこれを埋めている。

- Keycloak: トークンレスポンスに `refresh_expires_in`（非標準）を追加する。
- 一部の商用 IdP: `refresh_token_expires_in` を返す。

これらは **IANA "OAuth Parameters" レジストリに登録された標準パラメータではない**。
RFC 6749 §8.2 は追加のレスポンスパラメータを禁じてはいないが、
§11.2（Parameters Registry）は「ドメインを跨いで使う名前は登録すること」を求めている。

→ **判断材料**: 非標準パラメータの追加は「利用者に優しい」が「相互運用性の名を借りた方言の追加」
にもなる。§7 で両論として整理する。

### 2.5 RFC 9700（OAuth 2.0 Security BCP）§4.14 — 失効理由の区別可能性

RFC 9700 §4.14.2 は、rotation 済み RT の再利用を検知したら token family を失効させることを推奨する。
このとき返すのは `invalid_grant` である（RFC 6749 §5.2: "The provided authorization grant ...
is invalid, expired, revoked, ..."）。

**`invalid_grant` は「無効・期限切れ・失効」を意味的に区別しないコードとして定義されている。**
つまり「失効理由をクライアントへ伝えない」ことは仕様の設計意図に沿っている
（理由を伝えると攻撃者への情報漏洩になりうる）。

→ **事実**: 「なぜ失効したか」をエラーコードで区別しないのは**正しい**。
本ファイルが問題にするのは「失効する**前に**、いつ失効するかを知る手段」であり、
これは事後のエラーコードとは別レイヤである。

---

## 3. 参照資料

- **RFC 6749（The OAuth 2.0 Authorization Framework）**
  <https://datatracker.ietf.org/doc/html/rfc6749>
  - §5.1 Successful Response — `expires_in` の定義（"the lifetime in seconds of the access token"）と、
    RT 寿命パラメータが存在しないこと
  - §5.2 Error Response — `invalid_grant` の定義（無効／期限切れ／失効を区別しない）
  - §10.4 Refresh Tokens — RT の寿命は AS の裁量
  - §11.2 OAuth Parameters Registry — 追加パラメータの登録要件
- **RFC 7662（OAuth 2.0 Token Introspection）**
  <https://datatracker.ietf.org/doc/html/rfc7662>
  - §2.1 Introspection Request — `token_type_hint` に `refresh_token` を含む
  - §2.2 Introspection Response — `exp` / `iat` / `aud` などの OPTIONAL メンバ定義
- **RFC 9700（Best Current Practice for OAuth 2.0 Security）**
  <https://datatracker.ietf.org/doc/html/rfc9700>
  - §4.14 Refresh Token Protection / §4.14.2 Refresh Token Rotation
- **OAuth 2.1（draft-ietf-oauth-v2-1）**
  <https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1>
  - §3.2.3 Access Token Response / §4.3 Refresh Token Grant
- **OpenID Connect Core 1.0** <https://openid.net/specs/openid-connect-core-1_0.html>
  - §12 Using Refresh Tokens（refresh でのトークン再発行）
- **OpenID Connect Discovery 1.0** <https://openid.net/specs/openid-connect-discovery-1_0.html>
  - §3 OpenID Provider Metadata（`introspection_endpoint` は RFC 8414 §2 由来の広告項目）

---

## 4. 現在の実装確認

### 4.1 RT は発行されるが、寿命はレスポンスに載らない

`packages/core/src/token-response.ts:612`:

```ts
refresh_token: issueRefreshToken ? generateRandomString(32) : undefined,
```

`TokenResponse` の型定義（`packages/core/src/token-response.ts:133-150`）にも
RT 寿命を表すフィールドは無い。`expires_in`（同 :136）は
`accessTokenExpiresIn` をそのまま返しており、アクセストークンの寿命である。

### 4.2 絶対寿命は「サーバ側だけが知っている」

生成 OP は初回発行時刻を `originalIssuedAt` として保持し、絶対寿命を足して `expiresAt` を確定する。

`samples/hono-cloudflare/src/oidc-provider/routes/token.ts:624`（生成元は `packages/cli`）:

```ts
const refreshTokenExpiresAt = originalIssuedAt + config.refreshTokenAbsoluteLifetime;
```

`samples/hono-cloudflare/src/oidc-provider/config.ts:73`:

```ts
refreshTokenAbsoluteLifetime: 7776000,   // 90 日
```

`RefreshTokenInfo.originalIssuedAt` の JSDoc（`packages/core/src/token-request.ts:186-192`）にも
「ローテーション時は元 RT の値をそのまま引き継ぐ」と明記されている。
つまり `expiresAt` は **ローテーションを跨いで固定** であり、クライアントから見ると
「使い続けているのに、ある日突然使えなくなる」挙動になる。

### 4.3 失効判定は `invalid_grant` に潰される

`packages/core/src/refresh-token-grant.ts:94-104`:

```ts
export function validateRefreshTokenExpiration(refreshTokenInfo, currentTime = ...) {
  if (refreshTokenInfo.expiresAt <= currentTime) {
    throw new TokenError(TokenErrorCode.InvalidGrant, 'Refresh token has expired');
  }
}
```

同ファイルの `validateRefreshTokenUnused`（:57-72）と `validateRefreshTokenIdleTimeout`（:112-128）も
すべて `TokenErrorCode.InvalidGrant` を投げる。
`error_description` の文言だけが違うが、**クライアントが機械的に区別すべきものではない**
（§2.5 のとおり、区別しないのが正しい）。

### 4.4 Introspection は RT の `exp` を返せる（既に実装済み）

`packages/core/src/introspection.ts:151-163`:

```ts
function buildRefreshTokenResponse(info: RefreshTokenInfo): IntrospectionResponse {
  const res = {
    active: true,
    scope: info.scope.join(' '),
    client_id: info.clientId,
    token_type: 'refresh_token',
    sub: info.subject,
    exp: info.expiresAt,        // ← 絶対失効時刻が返る
  };
  ...
}
```

さらに `isRefreshTokenActive`（同 :125-129）は `used` と `expiresAt` を見て active を判定するため、
**ローテーション後の古い RT を内省すると `{ active: false }` になる**。
つまり「今持っている RT が有効か／いつ切れるか」を問い合わせる用途は、
現在の実装で **既に成立している**。

### 4.5 ただし、その経路には 3 つの前提条件がある

1. **Introspection 機能が有効化されていること**（CLI の feature トグル）。
2. **`refreshTokenResolver` が Introspection 側に配線されていること**
   （`IntrospectionRequestContext.refreshTokenResolver` は optional。
   `packages/core/src/introspection.ts:69`）。未配線だと RT は解決されず `{ active: false }` になり、
   **「失効済み」と「内省未対応」が区別できない**。
3. **呼び出し側がクライアント認証を通せること**。
   `requireIntrospectionClient`（同 :191-199）は認証済み clientId を要求する。
   public client は client_secret を持たないため、**SPA / ネイティブアプリは自分の RT を内省できない**。
   ところが RT の絶対寿命が一番効くのはまさにその public client である。

また、現在の Introspection は所有者チェックを行わない
（`packages/core/src/introspection.ts:8-12` のコメント）。
所有者チェックの導入は `tasks/p3-introspection-caller-authorization-hook.md` で別途追跡されており、
本トピックの「クライアントが自分の RT を内省する」用途と**設計上干渉する**（§7 で扱う）。

---

## 5. 現在の実装との差分

### 満たしていること

- RFC 6749 §5.1 の必須／推奨パラメータ（`access_token` / `token_type` / `expires_in` / `scope`）は返している。
- RT 寿命をレスポンスで返さないことは **仕様違反ではない**（§2.1 / §2.2）。
- 失効理由を `invalid_grant` に潰すことは **仕様の設計意図に沿っている**（§2.5）。
- RT の `exp` を返す標準経路（RFC 7662 Introspection）は **実装済み**（§4.4）。

### 不足している可能性があること

- **confidential client 以外に観測手段が無い**。public client（SPA / native）は
  Introspection を呼べないため、RT の hard expiry を知る手段が一切ない（§4.5-3）。
- **Discovery で「RT を内省できる」ことを伝えていない**。
  `introspection_endpoint` は広告できる（`packages/core/src/discovery.ts:74`）が、
  「RT も内省対象である」ことは metadata では表現できない（RFC 7662 / RFC 8414 に該当項目が無い）。
  → ドキュメントで補うしかない。
- **`refreshTokenResolver` 未配線時のフォールバックが「失効済み」と見分けられない**（§4.5-2）。
  これは可観測性以前に、Introspection の回答が**嘘になりうる**という問題である。

### 実装はあるが仕様上の確認が必要なこと

- Introspection を「クライアントが自分のトークンを内省する」用途に使ってよいか。
  RFC 7662 §2.1 は protected resource 向けと位置づけている。
  ただし §2.1 は呼び出し元を protected resource に**限定してはいない**（"OAuth 2.0 client" も
  クライアント認証の主体として想定されている）。→ 一次資料での字句確認が望ましい。
- 所有者チェック導入（`tasks/p3-introspection-caller-authorization-hook.md`）後に、
  「自分に発行された RT だけは内省できる」という緩和を残すかどうか。

### セキュリティ上、改善した方がよいこと

- **失効時刻を返すことの是非**は両面ある。
  - 返す側の利点: クライアントが事前に再認証を促せる → 突然のログアウトを避けられる。
  - 返さない側の利点: トークンの寿命情報は、トークンを窃取した攻撃者にとっても
    「あと何日使えるか」の情報になる。ただし攻撃者は試行すれば分かるため、
    **実効的な機密性はほぼ無い**（判断材料としては「返してもリスクは小さい」側）。
- **アイドル失効（`refreshTokenIdleTimeoutSeconds`）を併用すると不可視性が悪化する**。
  絶対寿命とアイドル失効の 2 軸があり、いずれか早い方で失効する
  （`packages/core/src/token-request.ts:301-310`）。
  Introspection の `exp` は **絶対寿命側しか返さない**ため、
  アイドル失効を有効にした OP では `exp` が「実際にはもっと早く切れる可能性がある上限」になる。
  → `study-material/done/introspection-refresh-token-idle-timeout-active-consistency.md` が
  `active` 判定の一貫性を扱っているが、**`exp` の値そのものの意味**は本ファイルの論点。

### 相互運用性の観点で改善した方がよいこと

- 非標準の `refresh_expires_in` を足すと、それを知らない RP は無視するだけなので害は少ないが、
  「このライブラリ固有の方言」を利用者コードに刷り込むことになる。
  本リポジトリのコンセプト（Fidelity = 仕様への忠実さ）とは緊張関係にある。
- 逆に「Introspection を使え」という答えは標準準拠だが、
  **public client では使えない**ため、実際の PoC で最も困る層を救えない。

### Basic OP として提供する上で確認すべきこと

- Basic OP 認定テストプランに RT 寿命の通知に関するテストは **無い**
  （Basic OP は `response_type=code` の認証フローと ID Token / UserInfo が中心）。
  → **本トピックは Basic OP の必須要件ではない**。認定への影響はゼロ。
- したがって優先度は「認定」ではなく「OSS 利用者の体験」で決める。

---

## 6. 改善・追加を検討する理由

### なぜこの改善に価値があるのか

本リポジトリの想定ユースケースは「PoC 開発者が自分の要件をこの仕様で満たせるか素早く検証する」ことである。
Refresh Token の絶対寿命は、**PoC の期間（数日〜数週間）では絶対に踏まない**が、
**本番導入の検討では必ず論点になる**（「うちのモバイルアプリは 90 日で強制再ログインになるのか？」）。

現状は次の状態にある。

- 90 日という値は `config.ts` に書いてあるので **OP 運用者は知っている**。
- しかし **クライアント実装者（RP 側）はコードを読まないと知りようがない**。
- 生成 OP を触っている利用者は多くの場合その両方を兼ねるので気づかないが、
  「OP を配って RP は別チーム」という現実的な構成に移った瞬間、これは運用事故になる。

つまりこれは「実装のバグ」ではなく **「契約の明文化が欠けている」** 種類の問題である。
本リポジトリが `resolver-and-store-contract.md` などで契約の明文化を重視してきた方針と整合する。

### Basic OP として必要か、拡張として有用か

- **Basic OP の必須要件ではない**（§5）。
- **拡張機能ですらない**。既存機能（Introspection）＋ドキュメントで大半が解決する。
- したがって「新機能の追加」ではなく「**既存機能の意味づけと文書化**」として扱うのが自然。

### 現在のリポジトリ構成から見て導入しやすいか

- **導入しやすい**。
  - Introspection の RT 対応は既にある（§4.4）。
  - 生成 OP の config に `refreshTokenAbsoluteLifetime` があるので、
    トークンレスポンスへ追加パラメータを載せる場合も 1 箇所の変更で済む。
- **導入しにくい点**は「public client に観測手段が無い」ことで、
  これは Introspection のクライアント認証要件に由来する構造的制約である。
  ここを埋めようとすると、認証不要な内省エンドポイントを作ることになり、
  それは **トークン存在オラクル**を作るため採用できない
  （`study-material/revocation-response-shape-token-existence-oracle.md` と同じ論点）。

### 既存実装とどう接続できそうか

- 案 1（ドキュメント）: `RefreshTokenInfo.expiresAt` / `originalIssuedAt` の JSDoc と
  生成 OP の `config.ts` コメントに「この値は RT の hard expiry であり、
  クライアントは Introspection の `exp` でのみ観測できる」と明記する。
- 案 2（レスポンス拡張）: `TokenResponse` に optional な非標準フィールドを足す。
  既存の `generateTokenResponse` は `refreshTokenExpiresIn` を **オプションとして既に受け取っている**
  （`packages/core/src/token-response.ts:78`。現在はレスポンスに反映せず、
  呼び出し側がストア保存に使う想定）。この既存フィールドを出力に繋げるだけで実装は完了する。

### 利用者・開発者・運用者のメリット

- **RP 実装者**: 「あと N 日で切れる」が分かるので、切れる前にサイレント再認証（`prompt=none`）を
  仕込める。ユーザー体験の断絶を避けられる。
- **OP 運用者**: 「なぜ 90 日でログアウトするのか」という問い合わせに、
  仕様上の答え（Introspection で観測可能）を提示できる。
- **本リポジトリの利用者**: 「絶対寿命を採用している」という設計判断が
  ドキュメント上で可視になり、他 IdP（sliding expiry を採る実装）との差分を意識できる。

### 実装しない場合に残る制約・リスク

- 本番移行の検討時に「90 日で必ず切れる」が発見されず、リリース後に発覚する。
- Introspection を有効化していない構成では、**誰も RT の寿命を観測できない**。
- アイドル失効を併用した構成では、`exp` の意味が曖昧なまま残る（§5）。

---

## 7. 実装方針の候補（最終判断は人間が行う）

### 方針A: ドキュメントと JSDoc の明文化のみ（最小・非破壊）

- `RefreshTokenInfo.expiresAt` / `originalIssuedAt` の JSDoc に
  「hard expiry であり sliding しない」「クライアントからの観測は RFC 7662 Introspection の `exp`」を追記。
- 生成 OP の `config.ts` の `refreshTokenAbsoluteLifetime` コメントに、
  RP へ周知すべき値である旨を追記。
- README / RELEASE ノートに 1 節。

**利点**: 仕様に一切方言を足さない。実装リスクゼロ。
**欠点**: public client 問題は残る。RP が能動的に読まないと届かない。

### 方針B: Introspection を「RT 寿命の公式な観測手段」として位置づける

- 方針A に加えて、`IntrospectionRequestContext.refreshTokenResolver` を
  **未配線だと起動時に警告する**（または生成 OP では必ず配線する）。
  → §4.5-2 の「嘘の `{ active: false }`」を潰す。
- `tasks/p3-introspection-caller-authorization-hook.md` の所有者チェック導入時に、
  「自クライアント向け RT の自己内省は許可する」既定を検討する。
- 生成 OP の README に「RT の残存寿命の確認方法」として introspection の curl 例を載せる。

**利点**: 標準準拠のまま実用性が上がる。既存タスクと自然に結合する。
**欠点**: public client は依然として救えない。

### 方針C: トークンレスポンスに非標準の `refresh_expires_in` を追加する（オプトイン）

- `TokenResponseOptions.refreshTokenExpiresIn`（既存フィールド、`token-response.ts:78`）を
  レスポンス出力に接続する。
- **既定は off**。`ProviderConfig` のフラグでオプトインにする。
  既定 on にすると、この方言を知らない RP にとってはただのノイズであり、
  かつ conformance テストの期待レスポンス形状を変えてしまう。
- 値は「絶対寿命の残り秒数」（= `expiresAt - now`）とし、ローテーションのたびに減っていく。

**利点**: public client を含め全クライアントが即座に観測できる。実装量が最小。
**欠点**: IANA 未登録の方言。本リポジトリの Fidelity 軸と緊張する。
`samples/*/conformance.test.ts` の期待値更新が必要。

### 方針D: アイドル失効併用時の `exp` の意味を確定させる

- 方針B/C のいずれを採っても、アイドル失効が有効な構成では
  「`exp` は上限であって実際の失効時刻ではない」という但し書きが要る。
- 選択肢は 2 つ。
  - (a) `exp` は絶対寿命のまま返し、意味を文書で固定する。
  - (b) `exp = min(絶対寿命, lastUsedAt + idleTimeout)` にして「次に切れる時刻」を返す。
    → `study-material/done/introspection-refresh-token-idle-timeout-active-consistency.md` の
    `active` 判定と意味が揃うため一貫性は高いが、`exp` が refresh のたびに動く。

### 判断材料の整理

| 観点 | 方針A | 方針B | 方針C |
|---|---|---|---|
| 仕様準拠（方言を足さない） | ◎ | ◎ | △ |
| public client の救済 | × | × | ◎ |
| 実装コスト | 極小 | 小 | 小 |
| conformance テストへの影響 | 無し | 無し | 有り（要更新） |
| 既存タスクとの結合 | — | 強い | 弱い |

- 「仕様準拠を第一、その次にセキュリティ、その次に利用者の使いやすさ」という本リポジトリの優先順位に
  厳密に従うなら **A → B** の順で進め、C は「オプトインの利便機能」として後置するのが整合的。
- 逆に「PoC 利用者の体験」を重く見るなら C を先に入れる判断もありうる。
  **この選択は人間が決めるべき事項**であり、本ファイルでは決めない。

---

## 8. タスク案

以下は「着手可能な粒度」に割ったもの。優先度は暫定。

### T-A（P3・確度高・非破壊）: RT 絶対寿命の契約を明文化する

- `packages/core/src/token-request.ts` の `RefreshTokenInfo.expiresAt` / `originalIssuedAt` の JSDoc に
  「hard expiry / sliding しない / クライアント観測手段は Introspection の `exp`」を追記
- `packages/cli` のテンプレートが出力する `config.ts` の `refreshTokenAbsoluteLifetime` コメントに
  「RP へ周知すべき値」であることを追記
- 生成 OP の README に「RT の残存寿命を確認する」節（introspection の curl 例）を追加
- テスト: `packages/cli/src/__tests__` で、生成された `config.ts` / README に該当文言が含まれることを固定

### T-B（P3・要判断）: Introspection の `refreshTokenResolver` 未配線を検知可能にする

- 未配線のまま `token_type_hint=refresh_token` を受けたとき、
  `{ active: false }` を返す現在の挙動が「未対応」と区別できない問題を解消する
- 生成 OP では必ず配線する（既に配線されているかを CLI テストで固定する）
- core 側は契約 JSDoc の追記に留める（core は HTTP 配線を持たないため）

### T-C（P3・方針未確定・要人間判断）: `refresh_expires_in` のオプトイン追加

- **方針C を採る決定が出るまで着手しない**
- 決定した場合の作業:
  - `TokenResponse` に optional フィールドを追加
  - `generateTokenResponse` が `refreshTokenExpiresIn` を出力へ接続（既定 off）
  - `ProviderConfig` にトグルを追加
  - `samples/*/conformance.test.ts`（生成元は `packages/cli`）の期待値を更新
  - 「非標準パラメータである」ことを JSDoc と README に明記

### T-D（P3・方針未確定）: アイドル失効併用時の `exp` の意味を確定する

- 方針D の (a) / (b) を選ぶ
- 選んだ側で `buildRefreshTokenResponse` の JSDoc とテストを固定する
- `study-material/done/introspection-refresh-token-idle-timeout-active-consistency.md` の
  `active` 判定と意味が矛盾しないことを契約テストで固定する

---

## 関連トピック

- `study-material/done/introspection-refresh-token-response-claim-asymmetry.md`
  — Introspection の RT レスポンスに `aud` が載らない件（本ファイルが依拠する観測経路の品質）
- `tasks/done/p1-refresh-token-absolute-lifetime.md` — 絶対寿命の導入（本ファイルの前提）
- `tasks/p3-introspection-caller-authorization-hook.md` — 所有者チェック（方針B と干渉する）
- `study-material/token-lifetime-security-policy.md` — 寿命値そのもののポリシー
- `study-material/revocation-response-shape-token-existence-oracle.md`
  — 「認証不要な観測手段を作らない」理由の共通論点
