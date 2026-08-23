# Refresh Token grant でアクセストークンの `aud` を絞り込めない（RFC 8707 §2.2 の refresh 時 resource 指定が不在）

## ステータス

🟡 Medium（最小権限 / 拡張性。Basic OP の必須要件ではない）/ タスク化済み

タスク: `tasks/p3-rfc8707-study-material-refresh-narrowing-correction.md`（T-A＝親トピックの現状整理の訂正のみ）。
実装（方針A/B/C）は RFC 8707 導入そのものの合意と、`token-exchange-audience-narrowing-vs-userinfo-permanent-membership.md`
の結論（方針E）を前提とするため保留。

## 1. このトピックで確認したいこと

現在の Refresh Token grant は、**元の grant で確定した audience をそのまま複製する**。
クライアント側から audience を絞り込む手段は存在しない。

`packages/core/src/refresh-token-grant.ts:170-192`:

```ts
export function buildValidatedRefreshTokenRequest(refreshTokenInfo, authenticatedClientId, effectiveScope) {
  return {
    grantType: 'refresh_token',
    ...
    scope: effectiveScope,          // ← scope は縮小できる
    audience: refreshTokenInfo.audience,   // ← audience は元の値をそのまま複製
    ...
  };
}
```

`scope` には縮小の仕組み（`validateRefreshTokenScope`、同 :136-165）があるのに、
**`audience` には対応する縮小の仕組みが無い**。

一方 RFC 8707（Resource Indicators for OAuth 2.0）§2.2 は、
**refresh token grant で `resource` パラメータを使って audience を絞る**ことを
正規のユースケースとして例示している（後述の Figure 5 / 6）。

確認したいのは次の 3 点。

1. RFC 8707 §2.2 が想定する「refresh 時の resource 指定」は、本 OP に必要か
2. 現在の非標準 `audience` リクエストパラメータ（認可エンドポイント側）との関係をどう整理するか
3. 導入する場合、`scope` の縮小ロジックと**どこまで対称に**作るべきか

### 既存ファイルとの差分（重複回避）

| 既存ファイル | 扱っている論点 | 本ファイルとの差分 |
|---|---|---|
| `study-material/ext-resource-indicators-rfc8707.md` | RFC 8707 拡張そのものの導入検討。「refresh: `RefreshTokenInfo.audience` を保持しローテーション後も同 aud」＝**満たしている**と整理されている | 本ファイルは、その整理が **§2.2 の refresh 時 narrowing を見落としている**点を差分として扱う。「保持する」と「絞れる」は別要件 |
| `study-material/authorization-audience-parameter-unvalidated-token-audience.md` | **認可エンドポイント**の非標準 `audience` パラメータが無検証である問題 | 本ファイルは**トークンエンドポイント（refresh）**側。入口が違う。ただし §7 で両者の統一は判断材料として触れる |
| `study-material/refresh-token-grant-scope-preservation.md` | refresh 時の **scope** 上限の基準点（originally granted） | 本ファイルは **audience** 側。RFC 8707 §2.2 は scope と resource を直交する軸として扱う（後述 §2.2） |
| `study-material/token-exchange-audience-narrowing-vs-userinfo-permanent-membership.md` | Token Exchange で絞った audience に UserInfo が再追加される問題 | 交換ではなく refresh 経路。ただし `buildAccessTokenAudience` を共有するため **同じ罠を踏む**。§5 で参照する |

---

## 2. 関連する仕様・基準（このトピック固有の差分）

RFC 8707 の全体像は `study-material/ext-resource-indicators-rfc8707.md` を参照。
ここでは **refresh token grant に固有の条文** だけを引く。

### 2.1 RFC 8707 §2 — `resource` パラメータの構文

逐語（抜粋）:

> **resource**
> Indicates the target service or resource to which access is being requested.
> Its value **MUST be an absolute URI**, as specified by Section 4.3 of [RFC3986].
> The URI **MUST NOT include a fragment component**. It **SHOULD NOT include a query component**,
> but it is recognized that there are cases that make a query component a useful and necessary part
> of the resource parameter ...
> **Multiple `resource` parameters MAY be used** to indicate that the requested token is intended
> to be used at multiple resources.

→ **事実**: 値は絶対 URI、fragment 禁止、query は非推奨だが許容、**複数指定可**。

### 2.2 RFC 8707 §2.2 — Access Token Request（refresh を含む）

逐語（抜粋）:

> When the `resource` parameter is used on an access token request made to the token endpoint,
> **for all grant types**, it indicates the target service or protected resource where the client
> intends to use the requested access token.
>
> The resource value(s) that is acceptable to an authorization server in fulfilling an access token
> request is at its **sole discretion based on local policy or configuration**. In the case of a
> **`refresh_token` or `authorization_code` grant type request, such policy may limit the acceptable
> resources to those that were originally granted by the resource owner or a subset thereof.**
>
> In the `authorization_code` case where the requested resources are a subset of the set of resources
> originally granted, the authorization server will issue an access token based on that subset of
> requested resources, whereas **any refresh token that is returned is bound to the full original grant.**

そして §2.2 は、この動作を **図で明示している**。

- Figure 3/4: `grant_type=authorization_code` ＋ `resource=https://cal.example.com/`
  → `aud` が `https://cal.example.com/` のアクセストークンと、**フル grant に紐づく** refresh token が返る。
- **Figure 5/6**: 上で得た **同じ refresh token** を使い、
  `grant_type=refresh_token` ＋ `resource=https://contacts.example.com/`
  → 今度は `contacts` 向けのアクセストークンが返る。

→ **事実**: RFC 8707 §2.2 の中心的なユースケースは
「**1 本の refresh token から、リクエストごとに違う resource 向けの狭いアクセストークンを取る**」ことである。
「元の aud をそのまま複製する」実装では、この仕様の主要な価値が得られない。

同 §2.2 はさらに、AS が積極的に権限を狭めるべきとも述べている。

> To the extent possible, when issuing access tokens, the authorization server should **downscope**
> the scope value associated with an access token to the value the respective resource is able to
> process and needs to know. ... This further improves privacy as a list of scope values is an
> indication that the resource owner uses the multiple various services listed; downscoping a token
> to only that which is needed for a particular service can limit the extent to which such information
> is revealed across different services.

→ **事実**: `resource` と `scope` は直交する軸であり、
`resource` を指定したときに `scope` も併せて絞ることが推奨されている
（"cartesian product of all the scopes at all the target services" の考え方）。

### 2.3 RFC 8707 §2 — `invalid_target` エラー

要求された resource を AS が許可しない場合のエラーコードとして `invalid_target` が定義され、
RFC 6749 §5.2 のエラー集合を拡張する（IANA "OAuth Extensions Error" レジストリに登録済み）。

→ **重要な実装制約**: 本リポジトリの `TokenErrorCode`（`packages/core/src/token-error.ts`）は
**closed な enum** であり `invalid_target` を含まない。
これは Token Exchange の実装が core の `TokenError` に相乗りできず
専用エラークラスを作った理由と同じ制約である
（`packages/experimental/src/token-exchange/token-exchange-request.ts:45-53` のコメント参照）。
→ core に導入するなら enum の拡張が必要で、これは公開 API の変更になる。

### 2.4 RFC 6749 §6 — refresh 時の scope 縮小との関係

RFC 6749 §6 は refresh 時の `scope` について
「originally granted を超えてはならない」と定める（詳細は
`study-material/refresh-token-grant-scope-preservation.md`）。

RFC 8707 §2.2 は **同じ論理を resource にも適用してよい（may limit ... to those that were
originally granted ... or a subset thereof）** と述べているが、
`scope` と違い **MUST ではなく AS のポリシー裁量**である点が異なる。

→ **判断材料**: したがって「元 grant の audience 部分集合に限る」は
仕様上の義務ではなく、**本 OP が選ぶべき安全側のポリシー**である。

### 2.5 RFC 9068 §3 — `aud` は非空でなければならない

JWT アクセストークンの `aud` は非空必須。
本リポジトリは `buildAccessTokenAudience`（`packages/core/src/token-response.ts:203-214`）で
これを担保しており、UserInfo エンドポイントを恒久メンバとして先頭に必ず含める。

→ **重要**: narrowing を入れても **UserInfo エンドポイントは aud から外れない**。
これは `study-material/token-exchange-audience-narrowing-vs-userinfo-permanent-membership.md` が
Token Exchange 経路で指摘しているのと**同じ構造**であり、
refresh 経路で narrowing を入れると同じ問題が再発する。→ §5 / §7 で扱う。

---

## 3. 参照資料

- **RFC 8707（Resource Indicators for OAuth 2.0）**
  <https://datatracker.ietf.org/doc/html/rfc8707>
  - §2 Resource Parameter — `resource` の構文（絶対 URI / fragment 禁止 / 複数指定可）
  - **§2.2 Access Token Request** — "for all grant types"、refresh 時のポリシー裁量、
    Figure 5/6（refresh_token grant で `resource=https://contacts.example.com/` を指定する例）、
    downscope の推奨
  - §5.2 OAuth Extensions Error Registration — `invalid_target`
- **RFC 3986（URI Generic Syntax）** <https://datatracker.ietf.org/doc/html/rfc3986>
  - §4.3 Absolute URI — `resource` の値制約が参照する定義
- **RFC 6749** <https://datatracker.ietf.org/doc/html/rfc6749>
  - §6 Refreshing an Access Token — `scope` の縮小可・拡大不可
  - §5.2 Error Response — エラーコード集合（`invalid_target` はここへの拡張）
- **RFC 9068（JWT Profile for OAuth 2.0 Access Tokens）**
  <https://datatracker.ietf.org/doc/html/rfc9068>
  - §3 Data Structure — `aud` 非空必須
- **RFC 8414（OAuth 2.0 Authorization Server Metadata）**
  <https://datatracker.ietf.org/doc/html/rfc8414>
  - §2 — `resource` 対応を広告する標準フィールドは **定義されていない**ことの確認用
    （RFC 8707 も metadata フィールドを定義していない）

---

## 4. 現在の実装確認

### 4.1 トークンエンドポイントは `resource` を受け取れない

`packages/core/src/token-request.ts:45-58`:

```ts
export interface TokenRequestParams {
  grant_type: string;
  code?: string;
  redirect_uri?: string;
  code_verifier?: string;
  client_id?: string;
  client_secret?: string;
  refresh_token?: string;
  scope?: string;      // ← refresh 時の scope 縮小はある
  // resource / audience は無い
}
```

生成 OP のトークンルートも、重複パラメータ検出のためにボディを走査するが、
`resource` を読み取る分岐は持たない。

### 4.2 audience は元 grant から無条件に複製される

`packages/core/src/refresh-token-grant.ts:181`:

```ts
audience: refreshTokenInfo.audience,
```

`ValidatedRefreshTokenRequest.audience` の JSDoc（`packages/core/src/token-request.ts:351-355`）:

> 元のアクセストークンに設定された audience。
> 呼び出し側はこの値をそのまま新アクセストークンの aud に渡す。

`RefreshTokenInfo.audience` の JSDoc（同 :202-207）:

> 認可時に決定されたアクセストークンの audience。
> Refresh Token grant でもローテーション後のアクセストークンに同じ aud を保持する。
> **拡大も欠損も許容しない。**

→ **設計意図は明確**: 「拡大させない」ことに主眼があり、
**「クライアントが自発的に縮める」経路は最初から想定されていない**。

### 4.3 audience の入口は認可エンドポイントの非標準 `audience` パラメータのみ

`packages/core/src/authorization-request.ts:1089-1097`:

```ts
export function parseAudienceParameter(effectiveParams: AuthorizationRequestParams): string[] | undefined {
  const audienceValue = effectiveParams.audience;
  if (audienceValue === undefined) return undefined;
  return audienceValue.split(' ').filter((a) => a.length > 0);
}
```

- パラメータ名は `resource` ではなく **`audience`**（RFC 8707 の標準名ではない）。
- 値は **スペース区切りの 1 パラメータ**（RFC 8707 は「同名パラメータの複数回出現」を使う）。
- 絶対 URI 検証も fragment 禁止も無い
  （→ `study-material/authorization-audience-parameter-unvalidated-token-audience.md` で追跡中）。

→ つまり本 OP は「RFC 8707 に**似た**独自パラメータ」を認可エンドポイントにだけ持っている状態である。

### 4.4 Token Exchange 側には narrowing がある（経路間の非対称）

`packages/experimental/src/token-exchange/token-exchange-request.ts:296-320` の
`resolveExchangeTarget` は、`audience` / `resource` を受け取り
`allowedTargets` 許可リストで検証したうえで **絞り込んだ** 値を返す。
`resource` は絶対 URI / fragment 禁止も検証している（同 :205-214、:445-456）。

→ **非対称の確認**:

| 経路 | audience 縮小 | `resource` 受理 | 絶対 URI 検証 |
|---|---|---|---|
| 認可エンドポイント | 指定のみ（縮小の概念なし） | ✗（独自 `audience`） | ✗ |
| Token Endpoint / authorization_code grant | ✗ | ✗ | — |
| **Token Endpoint / refresh_token grant** | **✗** | **✗** | — |
| Token Endpoint / token-exchange grant（experimental） | ✓ | ✓ | ✓ |

experimental の拡張機能のほうが、core の標準グラントより
**RFC 8707 に近い挙動を実装している**という逆転が起きている。

### 4.5 UserInfo エンドポイントは常に aud に入る

`packages/core/src/token-response.ts:203-214`:

```ts
export function buildAccessTokenAudience(input: AccessTokenAudienceInput): string[] {
  const { userInfoEndpoint, requested, issuer } = input;
  const members: string[] = [];
  if (userInfoEndpoint) members.push(userInfoEndpoint);   // ← 恒久メンバ
  if (requested) members.push(...requested);
  const deduped = [...new Set(members)];
  return deduped.length > 0 ? deduped : [issuer];
}
```

→ narrowing を refresh 経路に足しても、生成 OP がこの関数を通す限り
**UserInfo エンドポイントは必ず aud に残る**。
つまり「downstream 専用の狭いトークン」を作ったつもりでも、
そのトークンで UserInfo（＝エンドユーザの PII）が読める。
これは Token Exchange 経路で既に指摘されている問題と同一である
（`study-material/token-exchange-audience-narrowing-vs-userinfo-permanent-membership.md`）。

---

## 5. 現在の実装との差分

### 満たしていること

- audience が **拡大しない**ことは保証されている（`refreshTokenInfo.audience` の複製のみ）。
  RFC 8707 §2.2 の「元 grant のサブセットに限ってよい」というポリシー裁量の
  **最も保守的な端**（＝サブセット＝全体）を選んでいる状態。
- `scope` の縮小は RFC 6749 §6 に沿って実装済み。
- RFC 9068 §3 の「`aud` 非空」は担保されている。

### 不足している可能性があること

- **RFC 8707 §2.2 の主要ユースケース（refresh 時の resource 指定）が実現できない**。
  1 本の RT から複数の downstream 向けに狭いトークンを取り分けられない。
- 標準パラメータ名 `resource` をどのエンドポイントでも受け付けていない
  （experimental の token-exchange を除く）。
- `invalid_target` エラーコードを core が表現できない（§2.3）。

### 実装はあるが仕様上の確認が必要なこと

- 認可エンドポイントの独自 `audience` パラメータを、
  RFC 8707 の `resource` に **寄せるのか / 併存させるのか / 廃止するのか**。
  併存させると、同じ概念に 2 つの入口ができ、優先順位規則が必要になる。
- 「元 grant のサブセットに限る」を **MUST として実装するか**。
  RFC 8707 §2.2 上はポリシー裁量だが、拡大を許すと権限昇格になるため
  本 OP としては MUST 扱いにするのが妥当と考えられる（判断は人間）。

### セキュリティ上、改善した方がよいこと

- **最小権限が実現できていない**。現状、refresh で得たアクセストークンは
  元 grant の全 audience に対して有効であり、
  1 つの downstream が漏洩させたトークンで他の downstream も攻撃できる。
  RFC 8707 §1 が挙げる "an access token must only be valid for use at a specific protected
  resource and for a specific scope of access" という前提が満たされない。
- narrowing を入れる場合、**§4.5 の UserInfo 恒久メンバ問題を同時に解決しないと、
  narrowing の実効性が無い**。「絞ったつもりで PII だけは常に読める」状態は、
  絞れないより誤解を招くぶん危険とも言える。
  → **この 2 つは必ずセットで判断すべき**である。

### 相互運用性の観点で改善した方がよいこと

- 標準名 `resource` を受けないため、RFC 8707 対応のクライアントライブラリ
  （resource パラメータを自動付与するもの）を素通しすることになる。
  現状は **黙って無視**されるため、クライアントは「絞れたつもり」になる。
  → 少なくとも「無視している」ことが分かる必要がある
    （後述のとおり RFC 8707 は未対応時の挙動を規定していないため、これは設計判断）。

### Basic OP として提供する上で確認すべきこと

- RFC 8707 は **Basic OP の要件ではない**。OIDC Core §15.1 にも
  Conformance Profiles v3.0 の Basic OP テストプランにも含まれない。
- したがって本トピックは **拡張機能の位置づけ**であり、
  Basic OP の認定には一切影響しない。

---

## 6. 改善・追加を検討する理由

### なぜこの改善に価値があるのか

本リポジトリのコンセプトは「最新の OIDC/OAuth 仕様を誰よりも早く・忠実に検証できる」ことである。
RFC 8707 は「マイクロサービス構成で、1 つの OP から複数の API 向けに
audience を分けたトークンを出したい」という、
**PoC 段階で必ず出てくる要件**に直接答える仕様である。

現状は次のねじれがある。

- `RefreshTokenInfo.audience` という **データ構造は既にある**。
- 認可エンドポイントには **似て非なる独自パラメータ**がある。
- experimental の token-exchange には **標準準拠の narrowing がある**。
- しかし **core の refresh 経路にだけ何も無い**。

つまり材料は揃っているのに、いちばん使う経路が繋がっていない。

### Basic OP として必要か、拡張として有用か

- **Basic OP の必須要件ではない**（§5）。
- **拡張機能として有用**。特に「PoC で複数 API 構成を検証したい」層に効く。
- ただし、`study-material/ext-resource-indicators-rfc8707.md` が
  RFC 8707 全体の導入判断を扱っており、**本ファイルはその中の refresh 経路の差分**である。
  独立して実装するのではなく、RFC 8707 導入判断の一部として扱うのが自然。

### 現在のリポジトリ構成から見て導入しやすいか

**導入しやすい要素**:

- `refresh-token-grant.ts` は既に「ステップ関数の列」で構成されており、
  `validateRefreshTokenScope` の隣に `validateRefreshTokenResource`（仮）を足すだけで
  構造が壊れない。
- `buildValidatedRefreshTokenRequest` は `audience` を既に受け渡しているので、
  縮小後の値に差し替えるだけで済む。
- 検証ロジック（絶対 URI / fragment 禁止 / 許可リスト照合）は
  experimental の token-exchange に**動く実装が既にある**（同 :205-214、:296-320、:445-456）。
  これを core へ引き上げるか、共通ユーティリティにできる。

**導入しにくい要素**:

- **`invalid_target` を返せない**（§2.3）。`TokenErrorCode` は closed enum なので、
  拡張は公開 API の変更（minor bump）になる。
  代替として `invalid_request` / `invalid_scope` へ潰すこともできるが、
  RFC 8707 §5.2 で登録された標準エラーコードを使わないのは Fidelity 軸に反する。
- **`resource` は同名パラメータの複数出現で複数値を表す**（§2.1）。
  ところが生成 OP は**重複パラメータを一律で拒否する**
  （`tasks/done/p1-duplicate-parameter-rejection.md`。
  token-exchange 側も同じ制約を "Known limitation" として明記している）。
  → **複数 resource を受けるには重複拒否ルールに例外を作る必要がある**。
  これは既存のセキュリティ判断（重複パラメータ拒否）との正面衝突であり、
  最も設計判断が要る点。
- **UserInfo 恒久メンバ問題**（§4.5）と同時に解かないと実効性が無い。

### 既存実装とどう接続できそうか

- `TokenRequestParams` に `resource?: string`（単数）または `resource?: string[]`（複数）を追加。
- `TokenRequestContext` に許可対象（`allowedResources` 等）を追加するか、
  「元 grant の audience 部分集合であること」だけをルールにする。
- `validateRefreshTokenScope` と同じ形の `validateRefreshTokenResource` を追加し、
  `buildValidatedRefreshTokenRequest` の `audience` に縮小後の値を渡す。
- 生成 OP 側は `effectiveAudience` の算出だけが変わる。

### 利用者・開発者・運用者のメリット

- **利用者（PoC）**: 「API ごとに audience を分けられるか」を、
  この OP のまま検証できる。現状は「できない」ことを確認するために
  コードを読む必要がある。
- **開発者**: core と experimental の間の挙動の逆転（§4.4）が解消される。
- **運用者**: 漏洩時の影響範囲が resource 単位に閉じる。

### 実装しない場合に残る制約・リスク

- refresh で得たアクセストークンが常に全 audience 有効。最小権限が成立しない。
- RFC 8707 対応クライアントの `resource` が黙って無視され、
  クライアントが「絞れている」と誤認する。
- core と experimental の非対称が残り、利用者が
  「なぜ token-exchange だけ resource が効くのか」を毎回調べることになる。

---

## 7. 実装方針の候補（最終判断は人間が行う）

### 前提: 単独では決められない（RFC 8707 導入判断の一部）

本トピックは `study-material/ext-resource-indicators-rfc8707.md` の
「RFC 8707 を入れるか」という判断に従属する。
以下は「入れる」と決めた場合の refresh 経路の設計案である。

### 方針A: 単数 `resource` のみ受け付ける（最小・重複拒否ルールを壊さない）

- `resource` を **1 回だけ**指定できることにする。複数指定は `invalid_request`。
- 値は絶対 URI・fragment 禁止を検証（token-exchange の実装を流用）。
- 元 grant の `audience` に含まれない値は拒否。
- Token Exchange が既に採っている割り切り（"only a single value of each is supported"）と揃う。

**利点**: 重複パラメータ拒否という既存のセキュリティ判断を壊さない。実装が小さい。
実装済みの token-exchange と挙動が揃う。
**欠点**: RFC 8707 §2 の "Multiple resource parameters MAY be used" を満たさない
（MAY なので違反ではない）。

### 方針B: 重複拒否に `resource` だけ例外を作る（完全準拠寄り）

- `resource` に限り複数出現を許し、配列として集める。
- 重複拒否のロジックに「許可リスト方式」を導入する。

**利点**: RFC 8707 に完全に沿う。
**欠点**: 「重複パラメータは一律拒否」という単純で監査しやすいルールが崩れる。
例外リストの管理が必要になり、生成コードを改造する利用者が事故を起こす面が増える。
→ **セキュリティ第一の方針からは慎重に扱うべき**。

### 方針C: 認可エンドポイントの独自 `audience` を `resource` に統一する

- 認可エンドポイントの `audience`（`parseAudienceParameter`）を廃止または deprecated にし、
  `resource` に一本化する。
- `study-material/authorization-audience-parameter-unvalidated-token-audience.md` の
  「無検証」問題も同時に解消できる（絶対 URI 検証が入るため）。

**利点**: 入口が 1 つになる。標準名に寄る。2 つのトピックが同時に片付く。
**欠点**: 破壊的変更。既存の生成コードを使っている利用者に影響する。
→ **v0.x のうちにやるなら今**という性質の判断。

### 方針D: `invalid_target` の扱い

- (a) `TokenErrorCode` に `InvalidTarget = 'invalid_target'` を追加する（公開 API の追加）。
- (b) experimental 側と同様に専用エラークラスを作り、core を変更しない。
- (c) `invalid_request` に潰す（非推奨。標準エラーコードを捨てることになる）。

→ core の標準グラントに入れる以上、(a) が素直。
`AuthorizationErrorCode` も過去に拡張の必要が議論されている
（`study-material/done/authorization-error-code-invalid-request-object-and-enum-extensibility.md`）ため、
**enum の拡張性という共通論点として一緒に判断するのが効率的**。

### 方針E: UserInfo 恒久メンバ問題との同時解決（必須の前提）

§4.5 のとおり、narrowing を入れても UserInfo が aud に残る限り実効性が無い。

- `study-material/token-exchange-audience-narrowing-vs-userinfo-permanent-membership.md` の
  結論が出るまで、refresh 側の narrowing は **入れても意味が薄い**。
- 逆に言えば、あちらの結論（例: 「resource を明示した場合は UserInfo を aud から外す」）が出れば、
  refresh 経路にもそのまま適用できる。

→ **順序制約**: あちらを先に決める。

### 判断材料の整理

| 観点 | 方針A（単数） | 方針B（複数） | 方針C（統一） |
|---|---|---|---|
| RFC 8707 準拠度 | MAY 未実装（違反ではない） | 完全 | A/B と直交 |
| 既存セキュリティ判断との整合 | ◎ | △（重複拒否に例外） | ◎ |
| 実装コスト | 小 | 中 | 中（破壊的変更） |
| token-exchange との一貫性 | ◎ | △ | ◎ |
| 前提タスク | 方針E・方針D | 方針E・方針D | 方針E・方針D ＋ 破壊的変更の合意 |

---

## 8. タスク案

### T-A（P3・調査・即着手可）: `ext-resource-indicators-rfc8707.md` の現状整理を訂正する

- 既存ファイルの「refresh: `RefreshTokenInfo.audience` を保持しローテーション後も同 aud（done T-002）」
  「満たしていること: audience を認可〜トークン〜refresh で一貫保持する仕組みは既にある」という記述に、
  **「ただし RFC 8707 §2.2 が主眼とする refresh 時の narrowing は未対応」** を追記する
- 本ファイルへの参照を追加する
- **これは事実誤認の訂正であり、方針判断を伴わないため単独で着手できる**

### T-B（P3・方針未確定・要人間判断）: refresh 経路の `resource` narrowing を実装する

- **前提**: (1) RFC 8707 導入の合意、(2) 方針E（UserInfo 恒久メンバ問題）の結論、
  (3) 方針D（`invalid_target` の表現）の決定
- 決定した場合の作業:
  - `TokenRequestParams` に `resource` を追加
  - `validateRefreshTokenResource`（仮）を `refresh-token-grant.ts` に追加
    - 絶対 URI / fragment 禁止の検証（token-exchange の `isAbsoluteUriWithoutFragment` を共通化）
    - 元 grant の `audience` の部分集合であることを検証、外れたら `invalid_target`
    - 未指定なら元 grant の audience をそのまま（現状維持）
  - `buildValidatedRefreshTokenRequest` の `audience` に縮小後の値を渡す
  - 生成 OP のトークンルートで `resource` をボディから読み、ステップ関数へ渡す
- テスト要件:
  - `should narrow the access token audience to the requested resource`
  - `should reject a resource that was not in the original grant with invalid_target`
  - `should reject a resource containing a fragment with invalid_request`
  - `should keep the original audience when resource is omitted`
  - `should keep the rotated refresh token bound to the full original grant audience`
    （RFC 8707 §2.2 の "any refresh token that is returned is bound to the full original grant"）
  - `samples/*/conformance.test.ts`（生成元は `packages/cli`）に上記の契約を追加

### T-C（P3・方針未確定）: 認可エンドポイントの `audience` を `resource` へ統一するか決める

- 方針C の採否を決める
- 採る場合は `study-material/authorization-audience-parameter-unvalidated-token-audience.md` の
  タスクと統合する（別々に実装すると二重の入口が残る）

---

## 関連トピック

- `study-material/ext-resource-indicators-rfc8707.md` — RFC 8707 導入判断の親トピック（T-A で訂正対象）
- `study-material/token-exchange-audience-narrowing-vs-userinfo-permanent-membership.md`
  — UserInfo 恒久メンバ問題（方針E の前提）
- `study-material/authorization-audience-parameter-unvalidated-token-audience.md`
  — 認可エンドポイント側の独自 `audience` パラメータ（方針C で統合候補）
- `study-material/refresh-token-grant-scope-preservation.md` — refresh 時の scope 上限（直交する軸）
- `study-material/done/authorization-error-code-invalid-request-object-and-enum-extensibility.md`
  — エラーコード enum の拡張性（方針D の共通論点）
- `tasks/done/p1-duplicate-parameter-rejection.md` — 重複パラメータ拒否（方針B と衝突する）
