# Introspection の `refresh_token` レスポンスがアクセストークンと非対称（`aud` が保存済みなのに返らない）

## ステータス

🟢 Low〜🟡 Medium（相互運用性 / 情報の一貫性。仕様違反ではない）/ タスク化済み

タスク: `tasks/p3-introspection-response-claim-set-contract.md`（方針A＝現状維持＋明文化＋テストで固定）。
方針B（`aud` の追加）は `tasks/p3-introspection-caller-authorization-hook.md` の完了を前提とするため保留。
方針C（独自名での返却）は不採用寄りとして整理済み。

## 1. このトピックで確認したいこと

`packages/core/src/introspection.ts` は、active なトークンのレスポンスを
**種別ごとに別関数で組み立てている**。

- アクセストークン: `buildAccessTokenResponse`（:131-149）
- リフレッシュトークン: `buildRefreshTokenResponse`（:151-163）

この 2 つが返すクレーム集合は一致していない。特に **`aud` は
`RefreshTokenInfo.audience` としてストアに保存されているにもかかわらず、
リフレッシュトークンのレスポンスには載らない**。

確認したいのは次の 3 点。

1. この非対称は **意図的な情報最小化**なのか、単なる実装の取りこぼしなのか
2. RFC 7662 §2.2 の観点で、RT レスポンスに `aud` を含めることは適切か
3. 含めるとしたら、`nbf` / `jti` / `username` のように **そもそも保存されていない**
   クレームとどう区別して扱うか

### 既存ファイルとの差分（重複回避）

Introspection には既に 3 つのファイルがあるが、いずれも本論点は扱っていない。

| 既存ファイル | 扱っている論点 |
|---|---|
| `study-material/done/introspection-refresh-token-type-value-rfc7662.md` / `tasks/p2-introspection-refresh-token-type-value.md` | `token_type` に `refresh_token` を入れてよいか（**値の妥当性**） |
| `study-material/done/introspection-caller-authorization-and-disclosure.md` / `tasks/p3-introspection-caller-authorization-hook.md` | **誰が**内省してよいか（所有者チェック・開示範囲） |
| `study-material/done/introspection-refresh-token-idle-timeout-active-consistency.md` / `tasks/p3-introspection-refresh-token-idle-timeout-active-consistency.md` | `active` 判定にアイドル失効を反映するか（**active の真偽**） |

→ 本ファイルは **「active=true のときに返すクレーム集合」の種別間の差** に限定する。
`token_type` の値・`active` の真偽・呼び出し元の認可は扱わない。

また、`study-material/done/refresh-token-absolute-expiry-visibility.md` は
「クライアントが RT の `exp` を Introspection で観測する」経路を扱う。
本ファイルはその経路が返す**内容の品質**を扱う。両者は依存関係にあるが論点は別。

---

## 2. 関連する仕様・基準（このトピック固有の差分）

RFC 7662 の全体像は `study-material/done/introspection-refresh-token-type-value-rfc7662.md` を参照。
ここでは「どのクレームを返すべきか」に直接効く条文だけを引く。

### 2.1 RFC 7662 §2.2 — すべての内容クレームは OPTIONAL

RFC 7662 §2.2 の逐語（抜粋）:

> The server responds with a JSON object [RFC7159] in "application/json" format
> with the following top-level members.
>
> **active** — REQUIRED. Boolean indicator of whether or not the presented token is currently active. ...
>
> **scope** — OPTIONAL. ...
> **client_id** — OPTIONAL. ...
> **username** — OPTIONAL. Human-readable identifier for the resource owner who authorized this token.
> **token_type** — OPTIONAL. Type of the token as defined in Section 5.1 of OAuth 2.0 [RFC6749].
> **exp** — OPTIONAL. ...
> **iat** — OPTIONAL. ...
> **nbf** — OPTIONAL. ...
> **sub** — OPTIONAL. ...
> **aud** — OPTIONAL. Service-specific string identifier or list of string identifiers
> representing the intended audience for this token, as defined in JWT [RFC7519].
> **iss** — OPTIONAL. ...
> **jti** — OPTIONAL. ...

→ **事実**: `active` 以外はすべて OPTIONAL。したがって
**`aud` を返さないことは RFC 7662 違反ではない**。本トピックは「準拠」ではなく
「一貫性と有用性」の問題である。

### 2.2 RFC 7662 §2.2 — 開示範囲を絞ってよいことも明記されている

同 §2.2 の逐語:

> The authorization server MAY respond differently to different protected resources
> making the same request. For instance, an authorization server MAY limit which scopes
> from a given token are returned for each protected resource to prevent a protected
> resource from learning more about the larger network than is necessary for its operation.

→ **事実**: 「呼び出し元に応じて情報を絞る」ことは仕様が明示的に認めている。
ただしこれは **呼び出し元による出し分け**であって、
**トークン種別による恒常的な欠落**を正当化するものではない。

### 2.3 RFC 7662 §5 — 情報開示は攻撃面である

RFC 7662 §5（Security Considerations）は、内省エンドポイントが
トークンに関する情報を返すこと自体がリスクであり、認証と最小開示を求めている。

→ **判断材料**: 「返さない」側にも正当な理由がありうる。したがって
本トピックの結論は自動的に「`aud` を足すべき」にはならない。§7 で両論を整理する。

### 2.4 RFC 9068 §3 / §4 — アクセストークンの `aud` は「どこで使えるか」を表す

RFC 9068（JWT Profile for OAuth 2.0 Access Tokens）§3 は、
JWT アクセストークンの `aud` を非空必須とし、§4 は受領側が
自分を指す識別子が `aud` に含まれることを検証すべきと定める。

**Refresh Token は resource server に提示されるものではない**（トークンエンドポイント専用）ため、
RT の `aud` は RFC 9068 の意味での「受領側検証用」ではない。
本リポジトリの `RefreshTokenInfo.audience` は
**「この RT からローテーションで発行されるアクセストークンの `aud`」** を保持している
（`packages/core/src/token-request.ts:202-207` の JSDoc に明記）。

→ **重要な差分**: RT の `aud` は「RT 自身の受領者」ではなく
**「派生するアクセストークンの受領者」** である。
これをそのまま `aud` として返すと、RFC 7662 §2.2 の
"intended audience for this token" という定義と **意味がずれる**。
→ この意味論のずれこそが、本トピックで最も判断が要る点である（§5 / §7）。

---

## 3. 参照資料

- **RFC 7662（OAuth 2.0 Token Introspection）**
  <https://datatracker.ietf.org/doc/html/rfc7662>
  - §2.1 Introspection Request — `token_type_hint`（`access_token` / `refresh_token`）
  - §2.2 Introspection Response — 全レスポンスメンバの定義（`active` のみ REQUIRED、
    `aud` は "intended audience for this token"）、および呼び出し元別の出し分けが MAY であること
  - §3.1 OAuth Token Introspection Response registry — 追加メンバの登録要件
  - §5 Security Considerations — 情報開示のリスク
- **RFC 7519（JSON Web Token）** <https://datatracker.ietf.org/doc/html/rfc7519>
  - §4.1.3 "aud" (Audience) Claim / §4.1.5 "nbf" / §4.1.7 "jti" — RFC 7662 が参照する定義
- **RFC 9068（JWT Profile for OAuth 2.0 Access Tokens）**
  <https://datatracker.ietf.org/doc/html/rfc9068>
  - §3 Data Structure（`aud` 非空必須）/ §4 Validating JWT Access Tokens
- **RFC 6749** <https://datatracker.ietf.org/doc/html/rfc6749>
  - §1.5 Refresh Token（RT はトークンエンドポイント専用の資格情報である）

---

## 4. 現在の実装確認

### 4.1 2 つの組み立て関数の差分

`packages/core/src/introspection.ts:131-149`（アクセストークン）:

```ts
function buildAccessTokenResponse(info: AccessTokenInfo): IntrospectionResponse {
  const res = {
    active: true,
    scope: info.scope.join(' '),
    client_id: info.clientId,
    token_type: 'Bearer',
    sub: info.sub,
    exp: info.expiresAt,
  };
  if (info.iat !== undefined) res.iat = info.iat;
  if (info.nbf !== undefined) res.nbf = info.nbf;
  if (info.audience !== undefined && info.audience.length > 0) res.aud = info.audience;
  if (info.issuer !== undefined) res.iss = info.issuer;
  if (info.jti !== undefined) res.jti = info.jti;
  return res;
}
```

`packages/core/src/introspection.ts:151-163`（リフレッシュトークン）:

```ts
function buildRefreshTokenResponse(info: RefreshTokenInfo): IntrospectionResponse {
  const res = {
    active: true,
    scope: info.scope.join(' '),
    client_id: info.clientId,
    token_type: 'refresh_token',
    sub: info.subject,
    exp: info.expiresAt,
  };
  if (info.iat !== undefined) res.iat = info.iat;
  if (info.issuer !== undefined) res.iss = info.issuer;
  return res;
}
```

### 4.2 差分の内訳（保存有無で 2 群に分かれる）

| クレーム | AccessTokenInfo | RefreshTokenInfo | RT レスポンス | 区分 |
|---|---|---|---|---|
| `active` | — | — | 返す | — |
| `scope` | あり | あり | 返す | — |
| `client_id` | あり | あり | 返す | — |
| `token_type` | 固定 `Bearer` | 固定 `refresh_token` | 返す | 別トピックで係争中 |
| `sub` | `sub` | `subject` | 返す | — |
| `exp` | `expiresAt` | `expiresAt` | 返す | — |
| `iat` | `iat?` | `iat?` | 返す | — |
| `iss` | `issuer?` | `issuer?` | 返す | — |
| **`aud`** | `audience?` | **`audience?`（保存されている）** | **返さない** | **群 A: 保存済みだが未出力** |
| `nbf` | `nbf?` | **フィールド自体が無い** | 返さない | 群 B: 保存されていない |
| `jti` | `jti?` | **フィールド自体が無い** | 返さない | 群 B: 保存されていない |
| `username` | 無い | 無い | 返さない | 群 B（両種別とも保存していない） |

`RefreshTokenInfo` の定義は `packages/core/src/token-request.ts:173-239`。
`audience?: string[]` は :207 にあり、JSDoc は
「認可時に決定されたアクセストークンの audience。Refresh Token grant でもローテーション後の
アクセストークンに同じ aud を保持する。拡大も欠損も許容しない」と説明している。

→ **確認できた事実**:
- **群 A（`aud`）だけが「データはあるのに返していない」状態**である。
- 群 B（`nbf` / `jti` / `username`）は、そもそもストアに無いので返しようがない。
  `nbf` / `jti` は RT に概念的にも不要（RT は JWT ではなく opaque な CSPRNG 値であり、
  `nbf` を持たない設計になっている）。`username` は core が
  ユーザー表示名を知る層に居ないため（`UserClaimsResolver` は UserInfo 側の責務）返せない。

### 4.3 コード上の意図表明が無い

`buildRefreshTokenResponse` にも `IntrospectionResponse` 型定義（同 :76-90）にも、
**`aud` を意図的に落としているというコメントは無い**。
一方で本リポジトリは、意図的な省略には必ず理由コメントを置く方針を取っている
（例: `INACTIVE_INTROSPECTION_RESPONSE` の :92-95、
`RefreshTokenInfo.nonce`（`packages/core/src/token-request.ts:216-220`）が「なぜ refresh 再発行 ID Token へ出さないか」を明記）。

→ **判断**: コメントが無いことは「取りこぼしである」ことの強い示唆ではあるが、決定的ではない。
いずれにせよ **どちらの結論を採っても、意図を明記すべき状態にはある**。

### 4.4 実際に困る場面

RFC 7662 §2.1 の想定どおり protected resource が内省する場面では、RT は登場しない。
困るのは次の 2 つの場面である。

1. **運用・デバッグ**: 「この RT からローテーションしたアクセストークンは、どの resource 向けに出るのか」を
   OP 運用者が確認したいとき。現状は RT を内省しても分からず、
   一度 refresh して出てきたアクセストークンを内省するしかない。
   → 副作用（ローテーション＋旧 RT 失効）を伴う操作でしか観測できない、という不健全な状態。
2. **RFC 8707 の resource narrowing を将来入れる場合**（`study-material/done/refresh-grant-resource-parameter-audience-narrowing-rfc8707.md`）:
   「元の grant で許可された resource 集合」がクライアントから見えないと、
   クライアントは何を要求してよいか分からない。RT の内省結果はその自然な開示点になる。

---

## 5. 現在の実装との差分

### 満たしていること

- `active` は必ず返している（RFC 7662 §2.2 の唯一の REQUIRED）。
- inactive のときは `{ active: false }` のみを返し、存在情報を漏らさない（同 :92-98）。
- アクセストークン側は、保存済みの optional クレームをすべて返しており、取りこぼしが無い。

### 不足している可能性があること

- **`aud` が保存されているのに返らない**（群 A）。これは「情報最小化の判断」か
  「実装の取りこぼし」かがコード上区別できない。

### 実装はあるが仕様上の確認が必要なこと

- **RT の `aud` の意味論**（§2.4）。
  本リポジトリの `RefreshTokenInfo.audience` は「派生アクセストークンの `aud`」であり、
  RFC 7662 §2.2 の "intended audience for **this** token" とは指すものが違う。
  そのまま `aud` として返すと、受け取った側が
  「この RT をその audience に提示してよい」と誤解する余地がある
  （RT はトークンエンドポイント専用であり、RFC 6749 §1.5 のとおり resource server には提示しない）。
  → **`aud` という名前で返すのが妥当かどうか**が、本トピックの実質的な争点である。

### セキュリティ上、改善した方がよいこと

- `aud` を返すと、内省できる任意の confidential client に対して
  **「この OP がどんな resource 識別子を扱っているか」** が漏れる。
  RFC 7662 §2.2 が挙げる
  "prevent a protected resource from learning more about the larger network than is necessary"
  はまさにこれを指す。
  現在は所有者チェックが無い（`packages/core/src/introspection.ts:8-12`）ため、
  **登録済みの任意の confidential client が他社クライアントの RT を内省できる**。
  この状態で `aud` を足すと、開示面が広がる。
  → **所有者チェック（`tasks/p3-introspection-caller-authorization-hook.md`）より先に
  `aud` を足すべきではない**、という順序制約がある。これは重要な判断材料。

### 相互運用性の観点で改善した方がよいこと

- 種別ごとにレスポンス形状が違うこと自体は許容されるが、
  **差がある理由が公開されていない**ため、内省結果を扱うツールが
  「RT には `aud` が無い OP なのか、たまたまこのトークンに無いのか」を判別できない。
  クレームの有無が「データの有無」を意味するのか「方針」を意味するのかは、
  文書で固定する価値がある。

### Basic OP として提供する上で確認すべきこと

- Token Introspection は **Basic OP の要件ではない**（OIDC Core §15.1 にも
  Conformance Profiles の Basic OP テストプランにも含まれない）。
  本トピックは認定に一切影響しない。優先度は運用品質で決める。

---

## 6. 改善・追加を検討する理由

### なぜこの改善に価値があるのか

小さな差分だが、**「保存しているのに返さない」は将来の判断を静かに狂わせる**種類の欠落である。

- 今後 RFC 8707 の resource narrowing（§4.4-2）や Grant Management API
  （`study-material/ext-grant-management-api.md`）を検討するとき、
  「grant が許可している audience 集合」をどこで開示するかが必ず論点になる。
  そのとき「Introspection では返していない」という現状が、
  意図的な方針なのか単なる未実装なのか分からないと、判断をやり直すことになる。
- 逆に「返さない」が方針なら、それを明記しておけば
  後続トピックはその制約を前提に設計できる。

つまり本トピックの価値は **`aud` を足すこと自体より、方針を確定させて記録すること** にある。

### Basic OP として必要か、拡張として有用か

- **Basic OP の必須要件ではない**（§5）。
- Introspection 自体が拡張機能（RFC 7662）であり、本トピックはその内部の品質改善。

### 現在のリポジトリ構成から見て導入しやすいか

- **極めて導入しやすい**。`buildRefreshTokenResponse` に 1 行足すだけで実装は終わる
  （データは既に `RefreshTokenInfo.audience` にある）。
- **導入しにくい点**は実装ではなく**順序**である。§5 のとおり、
  所有者チェックが無い状態で開示面を広げるのは望ましくない。

### 既存実装とどう接続できそうか

- `buildAccessTokenResponse` と同じ条件式（`info.audience !== undefined && info.audience.length > 0`）を
  そのまま流用できる。両関数の対称性が保たれる。
- 意味論のずれ（§2.4）を避けたい場合は、`aud` ではなく
  RFC 7662 §3.1 のレジストリ外の独自名（例: `token_audience`）にする案もあるが、
  **独自名は相互運用性を下げる**のでおすすめしにくい。§7 で整理する。

### 利用者・開発者・運用者のメリット

- **運用者**: RT を副作用なしに内省して、派生トークンの向き先を確認できる。
- **開発者**: `buildAccessTokenResponse` / `buildRefreshTokenResponse` の非対称が
  意図であることが明示され、次に触る人が迷わない。

### 実装しない場合に残る制約・リスク

- 「保存済みだが未出力」というコメントの無い欠落が残り続ける。
- 将来 resource narrowing / Grant Management を入れるときに、
  同じ論点を最初から議論し直すことになる。

---

## 7. 実装方針の候補（最終判断は人間が行う）

### 方針A: 現状維持＋「返さない」ことを明記する

- `buildRefreshTokenResponse` に、`aud` を意図的に返さない理由をコメントで書く。
  理由の候補: (1) RT の `audience` は「派生 AT の aud」であり RFC 7662 の `aud` とは意味が違う、
  (2) 所有者チェックが無い現状では開示面を広げない。
- `IntrospectionResponse` 型の JSDoc に、種別ごとのクレーム集合の差を表で記す。

**利点**: 開示面を広げない。実装リスクゼロ。順序制約に抵触しない。
**欠点**: 運用時の観測性は改善しない。

### 方針B: 所有者チェック導入後に `aud` を返す（段階的）

1. `tasks/p3-introspection-caller-authorization-hook.md` を先に完了させる。
2. その上で `buildRefreshTokenResponse` に `aud` を追加し、
   `buildAccessTokenResponse` と対称にする。
3. `aud` の意味（「この RT から発行されるアクセストークンの audience」）を
   JSDoc とレスポンス仕様ドキュメントに明記する。

**利点**: 対称性が回復し、観測性も上がる。開示面の拡大は認可で抑えられる。
**欠点**: 前提タスクに依存するため着手が遅れる。

### 方針C: `aud` ではなく独自名で返す

- 意味論のずれ（§2.4）を避けるため、`aud` を使わず
  RFC 7662 §3.1 の registry 外の名前で返す。

**利点**: 誤解を招かない。
**欠点**: 相互運用性が下がる（汎用の内省クライアントは読まない）。
RFC 7662 §3.1 は「ドメインを跨いで使う名前は登録すること」を求めており、
未登録名の追加は本リポジトリの Fidelity 軸と合わない。
→ **積極的に推す理由は乏しい**。両論併記のために挙げる。

### 群 B（`nbf` / `jti` / `username`）の扱い

いずれの方針を採っても、群 B は **今回のスコープ外**とするのが妥当と考えられる。

- `nbf` / `jti`: RT は opaque な CSPRNG 値で、これらを持つ設計になっていない。
  持たせるならストア構造の変更を伴い、費用対効果が悪い。
- `username`: core は表示名を知る層に居ない（`UserClaimsResolver` は UserInfo 側）。
  返すには Introspection に新しい resolver を注入する必要があり、
  かつ **PII を内省結果に載せる**ため `study-material/done/introspection-caller-authorization-and-disclosure.md`
  の論点に直結する。別トピックとして扱うべき。

ただし **「返せないのではなく、返さない設計である」ことは JSDoc に書くべき**である
（方針A/B のいずれでも実施する）。

### 判断材料の整理

| 観点 | 方針A | 方針B | 方針C |
|---|---|---|---|
| 開示面の拡大 | 無し | 認可で抑制 | 拡大する |
| 実装コスト | 極小 | 小（前提タスク依存） | 小 |
| 相互運用性 | 変化なし | 向上 | 低下 |
| 意味論の正確さ | 明記で担保 | JSDoc で担保（誤解余地は残る） | 高い |
| 着手可能時期 | すぐ | 前提タスク完了後 | すぐ |

---

## 8. タスク案

### T-A（P3・確度高・非破壊・即着手可）: 種別間クレーム差を意図として明記する

- `packages/core/src/introspection.ts` の `buildRefreshTokenResponse` に、
  `aud` / `nbf` / `jti` / `username` を返さない理由をコメントで明記する
  （群 A =「方針判断で保留」、群 B =「保存していない／層が違う」を区別して書く）
- `IntrospectionResponse` 型の JSDoc に、種別ごとに返るクレームの表を追加する
- テスト（`packages/core/src/introspection.test.ts`）:
  - `should omit aud from an active refresh_token introspection response`
  - `should include aud in an active access_token introspection response`
  - いずれも `toEqual` でレスポンス全体を固定し、将来の追加が意図せず起きないようにする

### T-B（P3・前提タスク依存・要人間判断）: `aud` を RT レスポンスへ追加する

- **`tasks/p3-introspection-caller-authorization-hook.md` の完了を前提とする**
- 方針B を採る決定が出るまで着手しない
- 決定した場合の作業:
  - `buildRefreshTokenResponse` に `buildAccessTokenResponse` と同じ条件で `aud` を追加
  - `aud` の意味（派生アクセストークンの audience）を JSDoc に明記
  - `packages/core` のテストを `toEqual` で更新
  - `samples/*/conformance.test.ts`（生成元は `packages/cli`）に、
    RT 内省で `aud` が返ることを固定するケースを追加

---

## 関連トピック

- `study-material/done/refresh-token-absolute-expiry-visibility.md`
  — Introspection を RT 寿命の観測経路として位置づける話（本ファイルはその返却内容の品質）
- `tasks/p3-introspection-caller-authorization-hook.md` — 所有者チェック（方針B の前提）
- `study-material/done/introspection-caller-authorization-and-disclosure.md` — 開示範囲の一般論
- `study-material/done/refresh-grant-resource-parameter-audience-narrowing-rfc8707.md`
  — RT の audience 集合をクライアントへ開示する必要が生じる将来トピック
