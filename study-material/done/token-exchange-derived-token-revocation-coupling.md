# Token Exchange で発行したトークンの失効連動が非対称（`grantId` 継承はあるが subject_token 失効は伝播しない）

## ステータス

🟠 High（失効の実効性 / 監査可能性。experimental 拡張の設計判断）/ タスク化済み

タスク: `tasks/p2-token-exchange-require-subject-token-grant-id.md`（方針A + 方針B）。
方針C（派生関係の記録と失効伝播）はストア契約の変更を伴うため保留。
方針D（交換用 grant の分離）は Grant Management API の判断とセットで扱う。

## 1. このトピックで確認したいこと

`packages/experimental/src/token-exchange` は、交換で発行するトークンに
**subject_token の `grantId` を継承させる**。生成 OP はその `grantId` を
アクセストークンストアへ書き込む。

`packages/experimental/src/token-exchange/token-exchange-request.ts:417`:

```ts
return {
  subject: subject.sub,
  clientId: context.client.clientId,
  scope,
  requestedAudience,
  expiresIn,
  grantId: subject.grantId,     // ← subject_token の grantId を継承
};
```

`samples/hono-cloudflare/src/oidc-provider/routes/token.ts:253-256`（生成元は `packages/cli`）:

```ts
// Inherit the subject token's grant so revoking the grant (e.g. on code
// reuse detection) also kills every token exchanged from it.
grantId: grant.grantId,
```

この設計により **grant 単位の失効は交換トークンにも届く**。ここまでは意図どおりである。

しかし、失効の伝播は **一方向にしか成立していない**。

> **subject_token（交換元のアクセストークン）そのものを RFC 7009 で失効させても、
> そこから交換して発行されたトークンは失効しない。**

さらに、`grantId` は `AccessTokenInfo.grantId?` が **optional** であるため、
**`grantId` を持たない subject_token から交換されたトークンは、
grant 単位の失効を含むすべての失効機構から外れる**。

確認したいのは次の 4 点。

1. 「交換元を失効させても派生トークンが生き残る」ことは意図された挙動か
2. RFC 8693 / RFC 7009 はこの伝播について何を規定しているか（規定していないなら誰が決めるか）
3. `grantId` 未設定の subject_token から交換した場合の穴をどう塞ぐか
4. 交換されたトークンであることが **どこにも記録されていない**（監査可能性）ことをどう扱うか

### 既存ファイルとの差分（重複回避）

Token Exchange には既に 3 つのファイルがあるが、いずれも**失効ライフサイクル**は扱っていない。

| 既存ファイル | 扱っている論点 |
|---|---|
| `study-material/ext-token-exchange-rfc8693.md` | 拡張の導入検討そのもの（実装前の文書） |
| `study-material/token-exchange-audience-narrowing-vs-userinfo-permanent-membership.md` | 交換**結果**の権限範囲（`aud` に UserInfo が必ず残る） |
| `study-material/token-exchange-authorization-model-allowed-targets-and-subject-token-binding.md` | **誰が**交換してよいか（`allowedTargets` のグローバル性、subject_token と要求クライアントの非結合） |
| `tasks/experimental/done/token-exchange/specification.md` ほか | 実装仕様と review log |

→ 本ファイルは **「交換後、トークンをどう殺すか」＝ライフサイクル**に限定する。
「誰が交換できるか」「交換で何が得られるか」は上記へ委譲する。

また、grant 単位失効の store 意味論そのものは
`study-material/done/authorization-code-reuse-cascade-store-semantics.md` が扱っている。
本ファイルは **交換経路が加わったことでその意味論に生じる穴**に絞る。

---

## 2. 関連する仕様・基準（このトピック固有の差分）

RFC 8693 の全体像は `study-material/ext-token-exchange-rfc8693.md` を参照。
ここでは失効ライフサイクルに直接効く条文だけを引く。

### 2.1 RFC 8693 §1.1 — impersonation では「交換されたこと」は見えなくてよい

逐語（抜粋）:

> When principal A impersonates principal B, A is given all the rights that B has within some
> defined rights context and **is indistinguishable from B in that context**. ...
> **It is true that some members of the identity system might have awareness that impersonation
> is going on, but it is not a requirement.**

→ **事実**: impersonation 型の交換において、
発行されたトークンから「交換の産物である」ことが分からなくても **RFC 8693 違反ではない**。
（`act` クレーム（§4.1）は delegation 用であり、impersonation では付けないのが正しい。）

ただしこれは **リソースサーバから見た可視性**の話であって、
**AS 自身が内部記録を持たなくてよい**という意味ではない。§5 で区別して扱う。

### 2.2 RFC 8693 §5 — 濫用の抑制手段として挙げられているのは scope と寿命

逐語:

> In addition, both delegation and impersonation introduce unique security issues.
> **Any time one principal is delegated the rights of another principal, the potential for abuse
> is a concern.** The use of the `scope` claim (in addition to other typical constraints such as
> a limited token lifetime) is suggested to mitigate potential for such abuse, as it restricts
> the contexts in which the delegated rights can be exercised.

→ **事実**: RFC 8693 が明示的に挙げる緩和策は **scope の制限** と **短い寿命**の 2 つだけで、
**失効（revocation）の伝播には一切触れていない**。

→ **判断**: したがって「交換元を失効させたら派生も失効させるか」は
**仕様が答えを持たない領域**であり、**本 OP が設計判断として決めるべき事項**である。
本ファイルの目的は、その判断材料を揃えることにある。

### 2.3 RFC 7009 §2.1 — 失効の連鎖について仕様が定めていること

RFC 7009 §2.1 の規定は次の 2 点のみ。

- refresh token を失効させた場合、**同じ authorization grant で発行されたアクセストークンも
  失効させる SHOULD**。
- access token を失効させた場合、関連する refresh token を失効させても **よい（MAY）**。

→ **事実**: RFC 7009 が語るのは「**同一 grant 内**の access ↔ refresh の連鎖」であり、
「あるアクセストークンから**派生した別のアクセストークン**」という関係は
RFC 7009 の想定に存在しない（token exchange は RFC 7009 より後の仕様）。

→ **判断材料**: 現在の実装は RFC 7009 §2.1 を忠実に実装しているが、
**忠実であるがゆえに交換の派生関係を取りこぼしている**。
これは「仕様違反」ではなく「仕様の空白」である。

### 2.4 RFC 9700 §4.13 / §4.14 — 漏洩時は「そこから派生したもの」を殺すのが原則

RFC 9700（OAuth 2.0 Security BCP）は、
認可コード再利用検知時（§4.13）およびリフレッシュトークン再利用検知時（§4.14.2）に、
**そのコード／トークンに基づいて発行済みのトークンをすべて失効させる**ことを推奨する。

→ **原則の抽出**: 「侵害された資格情報から**派生したもの**は連鎖的に無効化する」。
この原則を token exchange に当てはめるなら、
「subject_token が侵害された（＝失効させられた）なら、そこから交換されたトークンも殺す」
のが BCP の精神に沿う。

→ ただし RFC 9700 も token exchange の派生を明示的に扱ってはいない。
これも**演繹**であり、規範ではない点は明確にしておく。

---

## 3. 参照資料

- **RFC 8693（OAuth 2.0 Token Exchange）**
  <https://datatracker.ietf.org/doc/html/rfc8693>
  - §1.1 Delegation vs. Impersonation Semantics — impersonation では
    「交換されたこと」が受領側から見えなくてよい（"not a requirement"）
  - §2.1 Request / §2.2 Response — 交換の要求・応答（失効の規定は無い）
  - §4.1 "act" (Actor) Claim — delegation 用のクレーム（impersonation では付けない）
  - **§5 Security Considerations** — 濫用の緩和策として挙がるのは `scope` と限定的な寿命のみ。
    失効の伝播への言及は無い
- **RFC 7009（OAuth 2.0 Token Revocation）**
  <https://datatracker.ietf.org/doc/html/rfc7009>
  - §2.1 Revocation Request — refresh 失効時の access 連鎖（SHOULD）、
    access 失効時の refresh 連鎖（MAY）。派生トークンの規定は無い
  - §2.2 Revocation Response — 未知トークンでも 200 を返す
- **RFC 9700（Best Current Practice for OAuth 2.0 Security）**
  <https://datatracker.ietf.org/doc/html/rfc9700>
  - §4.13 Authorization Code Injection / §4.14 Refresh Token Protection —
    侵害された資格情報から派生したトークンの連鎖失効
- **OAuth 2.1（draft-ietf-oauth-v2-1）**
  <https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1>
  - §4.1.2 / §4.3.1 — コード再利用・RT 再利用時の連鎖失効
- **RFC 7662（OAuth 2.0 Token Introspection）**
  <https://datatracker.ietf.org/doc/html/rfc7662>
  - §2.2 — 内省レスポンスのメンバ（交換の事実を表すメンバは無い。
    RFC 8693 §7.5 が `act` / `may_act` を内省レスポンスへ登録している）

---

## 4. 現在の実装確認

### 4.1 失効が **届く** 経路

| 起点 | 経路 | 交換トークンに届くか |
|---|---|---|
| 認可コード再利用検知 | `AuthorizationCodeResolver.revokeTokensByGrantId(grantId)` → `accessTokenStore.revokeByGrantId` | **届く** |
| RT 再利用検知（token family 失効） | `RefreshTokenResolver.revokeTokensByGrantId(grantId)` | **届く** |
| RT を RFC 7009 で失効 | `revokeGrantAccessTokens`（`packages/core/src/revocation.ts:213-219`）→ `revokeAccessTokensByGrantId` | **届く** |
| 同意撤回 | `revokeConsentAndTokens`（`samples/hono-cloudflare/src/oidc-provider/resolvers.ts:131-136`）→ grantId ごとに `revokeTokensByGrantId` | **届く** |

`grantId` を継承させた設計判断は、ここでは正しく効いている。

### 4.2 失効が **届かない** 経路

#### (a) subject_token 自身を RFC 7009 で失効させたとき

`packages/core/src/revocation.ts:213-219`:

```ts
export async function revokeGrantAccessTokens(resolved, resolvers): Promise<void> {
  if (resolved.tokenType !== 'refresh_token') return;      // ← access token では何もしない
  await resolvers.revokeAccessTokensByGrantId?.(resolved.refreshToken.grantId);
}
```

`revokeResolvedToken`（同 :192-202）は、access token のときは
`resolvers.revokeAccessToken(token)` を呼ぶだけで、**提示されたトークン 1 本しか消さない**。

→ **帰結**: クライアント A が「このアクセストークンは漏れたので失効させたい」と
RFC 7009 で失効させても、**クライアント B が既にそれを交換して得たトークンは生き残る**。

これは RFC 7009 §2.1 の規定どおり（access 失効時の連鎖は MAY）であり、
**単体では正しい**。問題は「交換という派生関係が加わったのに、
その MAY を選ばない判断が見直されていない」ことである。

#### (b) subject_token が `grantId` を持たないとき

`AccessTokenInfo.grantId` は optional（`packages/core/src/userinfo.ts:57-63`）。
`TokenExchangeGrant.grantId` も optional（`token-exchange-request.ts:105-106`）。

生成 OP の既定経路では `grantId` は必ず入るが、
**core / experimental の公開 API としては `grantId` 無しのアクセストークンを受け付ける**。
利用者が独自の `AccessTokenResolver` を実装した場合（本リポジトリは resolver 差し替えを
明示的に推奨している）、`grantId` を返し忘れると、
そこから交換したトークンは **`grantId: undefined` で保存され、
すべての `revokeByGrantId` から漏れる**。

しかも **交換は成功する**（`resolveSubjectToken` は `grantId` の有無を検査しない）。
つまり **失効不能なトークンが黙って生まれる**。

これは `study-material/done/authorization-code-reuse-cascade-store-semantics.md` が扱っている
「store 実装の契約違反が黙って失効を無効化する」フットガンと同型の問題である。

#### (c) 交換トークンから、さらに交換した場合

現在の実装は交換トークンを subject_token として再交換できる
（`resolveSubjectToken` は「交換由来か」を区別しない）。
寿命は `min(configured, 残存)` で単調減少するため無限延命はできないが、
`grantId` は継承され続けるので **失効の連鎖自体は保たれる**。
→ ここは問題ない。ただし「何段交換されたか」の記録は残らない（§4.3）。

### 4.3 交換されたことがどこにも記録されない

生成 OP が保存する交換トークンのレコード
（`samples/hono-cloudflare/src/oidc-provider/routes/token.ts:246-266`）には、

- `sub`: 元ユーザ（継承）
- `clientId`: **交換を要求したクライアント B**
- `grantId`: **クライアント A の grant**
- `audience` / `scope` / `exp` / `jti`

が入るが、**「これは交換の産物であり、元は誰のどのトークンか」を示すフィールドは無い**。

帰結:

- 内省（RFC 7662）しても `client_id: B` としか分からない。
  「B が A のトークンを交換して得たもの」という事実は表に出ない。
  → §2.1 のとおり RFC 8693 違反ではないが、**AS 運用者が事故調査できない**。
- `grantId` は A の grant を指すため、レコードだけを見ると
  **`clientId` と `grantId` の所属が食い違う**。
  この不一致を「交換の印」として読むことは可能だが、暗黙的で脆い。
- 監査ログ側の整備は `study-material/audit-logging-and-observability.md` /
  `study-material/audit-logging-observability.md` が扱うが、
  **ストアのレコードに情報が無いと、ログにも書けない**。

### 4.4 交換トークンは RFC 7009 で誰が失効できるか

`validateRevocationTokenClient`（`packages/core/src/revocation.ts:168-183`）は
`resolved.accessToken.clientId !== authenticatedClientId` なら `invalid_grant` を返す。

交換トークンの `clientId` は **B** なので:

- **B は自分の交換トークンを失効できる**（正しい）。
- **A は B の交換トークンを直接は失効できない**（正しい。他人のトークンを消せてはならない）。
- ただし **A は自分の refresh token を失効させれば、grantId 経由で B の交換トークンを巻き添えにできる**。

→ この「直接はできないが間接的にはできる」という非対称は、
**設計としては妥当**（権限の出どころは A の grant なので）だが、
**A / B のどちらにも説明されていない**。B から見れば
「自分は何もしていないのに突然トークンが死ぬ」ことになる。

---

## 5. 現在の実装との差分

### 満たしていること

- grant 単位の失効（コード再利用・RT family・同意撤回・RT の RFC 7009 失効）は
  交換トークンへ **確実に届く**。これは `grantId` 継承という明確な設計判断の成果である。
- 寿命は `min(configured, subject の残存)` で単調減少し、交換による延命はできない
  （`computeExchangedTokenLifetime`、`token-exchange-request.ts:335-354`）。
  RFC 8693 §5 が挙げる「限定的な寿命」を満たしている。
- scope は subject の部分集合に限られる（`validateExchangeScope`、同 :265-282）。
  RFC 8693 §5 が挙げるもう 1 つの緩和策も満たしている。
- 交換トークンは自分の `jti` を持ち、ストア上で別レコードになる（同 :262 の生成 OP コメント）。

### 不足している可能性があること

- **subject_token（access token）自身の失効が派生トークンへ伝播しない**（§4.2-a）。
  RFC 7009 §2.1 上は MAY だが、RFC 9700 の「派生したものを殺す」原則からは外れる。
- **`grantId` 無しの subject_token からの交換が黙って成功する**（§4.2-b）。
  失効不能なトークンが生まれる経路が公開 API に存在する。
- **交換の事実がストアに記録されない**（§4.3）。事故調査ができない。

### 実装はあるが仕様上の確認が必要なこと

- 「交換トークンの `clientId` は B、`grantId` は A の grant」という
  レコード上の所属の食い違いを、**正式なデータモデルとして認めるか**。
  認めるなら JSDoc に明記すべきであり、認めないなら
  「交換用の grant を新規に切る」設計もありうる（§7 方針C）。

### セキュリティ上、改善した方がよいこと

- §4.2-a は **実運用で最も踏みやすい穴**である。
  「アクセストークンが漏れた → 失効させた → 安心した」という自然な運用が、
  交換が絡むと成立しない。しかも失効操作は 200 OK を返すため、
  運用者は成功したと信じる（RFC 7009 §2.2 のとおり、これ自体は正しい挙動）。
- §4.2-b は **公開 API のフットガン**である。
  本リポジトリが store / resolver 契約の明文化を重視してきた方針
  （`study-material/resolver-and-store-contract.md`）からすると、
  **契約違反を実行時に検知できないまま通す**のは一貫していない。

### 相互運用性の観点で改善した方がよいこと

- RFC 8693 §7.5 は `act` / `may_act` を **内省レスポンスのメンバとして登録している**。
  delegation を実装するときには必要になる。
  現在は impersonation 限定なので不要だが、
  「交換の事実を内省で見せるか」を将来判断する際の標準的な受け皿は既に存在する。

### Basic OP として提供する上で確認すべきこと

- Token Exchange は **Basic OP の要件ではない**（RFC 8693 は OIDC の認定プロファイルに含まれない）。
- 本トピックは **experimental 拡張の内部品質**であり、Basic OP 認定には影響しない。
- ただし、`packages/experimental` は `RELEASE.md` の方針で **patch 固定で自動 publish される**。
  つまり「実験的だが出荷されている」状態であり、
  失効の穴を放置したまま利用者の手に渡り続けることになる。優先度はその点で決まる。

---

## 6. 改善・追加を検討する理由

### なぜこの改善に価値があるのか

Token Exchange モジュールは、自身のセキュリティ設計の中核をこう宣言している
（`token-exchange-request.ts:10-17`）。

> 交換で権限が単調に狭まること（scope は部分集合・audience は許可リスト内・
> 寿命は subject_token の残存期間以下・`sub` は変更不可）が本モジュールの
> セキュリティ設計の中核である。

この 4 つはすべて **「発行時の権限の広さ」** に関する保証である。
一方、**「発行後に権限を取り消せるか」** については何も宣言されていない。

セキュリティ上、**取り消せない権限は、狭くても危険**である。
「狭いトークンだが消せない」より「広いトークンだが確実に消せる」ほうが
運用としては安全な場合すらある。
現状は「狭いが、元を消しても消えない」という、宣言されていない性質を持っている。

つまり本トピックの価値は、**モジュールが掲げる保証の第 5 の軸
（失効の単調性）を明示的に定義すること**にある。

### Basic OP として必要か、拡張として有用か

- **Basic OP の要件ではない**（§5）。
- **拡張機能の必須品質**として扱うべき。出荷済みであることが理由（§5 の最後）。

### 現在のリポジトリ構成から見て導入しやすいか

**導入しやすい要素**:

- `grantId` 継承の仕組みは既にあり、`revokeByGrantId` も全ストアに実装済み。
- §4.2-b（`grantId` 必須化）は `resolveSubjectToken` に数行足すだけで塞げる。
- §4.3（交換の記録）は `AccessTokenInfo` に optional フィールドを 1〜2 個足すだけ。

**導入しにくい要素**:

- §4.2-a（access token 失効の派生伝播）は、
  **「あるアクセストークンから派生したトークン」を引く索引が無い**。
  現在のストアは `grantId` 索引しか持たない。
  同一 grant 内には交換トークン以外のトークンも居るため、
  `grantId` で消すと **交換されていないトークンまで巻き添え**になる。
  → 新しい索引（例: `derivedFrom` = 元トークンの `jti`）が要る。
  これはストア契約の変更であり、利用者の独自ストア実装に影響する。

### 既存実装とどう接続できそうか

- `AccessTokenInfo` に `derivedFromJti?: string`（仮）を足せば、
  §4.3（記録）と §4.2-a（伝播の索引）の両方が同じフィールドで賄える。
- 生成 OP は `subject.jti` を持っているので（`resolveSubjectToken` の戻り値）、
  書き込みは 1 行で済む。
- 伝播そのものは `RevocationTokenResolvers` に
  `revokeAccessTokensDerivedFrom?(jti)` を optional で足し、
  未実装なら従来どおり（＝伝播しない）とすれば **後方互換を壊さない**。

### 利用者・開発者・運用者のメリット

- **運用者**: 「漏れたトークンを失効させた」が本当に効く。事故対応の前提が成立する。
- **開発者**: `grantId` 未設定という契約違反が実行時に検知される。
- **利用者（PoC）**: 「token exchange を入れると失効設計がどう変わるか」を
  この OP のまま検証できる。これは実運用導入時に必ず問われる論点である。

### 実装しない場合に残る制約・リスク

- 「アクセストークンを失効させたのに、そこから交換されたトークンが生きている」状態が残る。
- 独自 resolver 利用時に、失効不能なトークンが黙って生まれる。
- 交換が絡む事故の調査ができない（記録が無い）。

---

## 7. 実装方針の候補（最終判断は人間が行う）

### 方針A: 現状維持＋保証範囲の明文化（最小・非破壊）

- `token-exchange-request.ts` のモジュール冒頭コメントに、
  **失効に関する保証の範囲**を明記する。
  - 保証すること: grant 単位の失効（コード再利用・RT family・同意撤回）は交換トークンに届く。
  - 保証しないこと: subject_token 自身の RFC 7009 失効は伝播しない。
- 生成 OP のコメントと README にも同じ内容を書く。

**利点**: 実装リスクゼロ。誤解を防ぐ効果は大きい。
**欠点**: 穴は残る。

### 方針B: `grantId` 必須化（穴の閉塞・小）

- `resolveSubjectToken` または `processTokenExchangeRequest` で
  `subject.grantId === undefined` を検出し、交換を拒否する。
- エラーは `invalid_request` ＋ 既存の固定文言（`SUBJECT_TOKEN_INVALID_DESCRIPTION`）を使い、
  **理由を区別させない**（オラクルを作らない既存方針と揃える）。
- `TokenExchangeGrant.grantId` を必須（`string`）に変えるかは別途判断
  （公開 API の変更になるが、experimental なので許容範囲）。

**利点**: 失効不能なトークンが生まれる経路を確実に塞ぐ。実装が小さい。
**欠点**: `grantId` を返さない独自 resolver を使っている利用者には破壊的。
ただし **その利用者は元々失効が効いていない**ので、壊れることに気づけるほうが良い。

### 方針C: 派生関係を記録し、伝播できるようにする（構造的）

1. `AccessTokenInfo` に `derivedFromJti?: string` を追加（optional なので非破壊）。
2. 生成 OP が交換時に `subject.jti` を書き込む。
3. `RevocationTokenResolvers` に `revokeAccessTokensDerivedFrom?(jti)` を optional で追加。
4. `revokeResolvedToken` の後段で、access token 失効時に
   `revokeAccessTokensDerivedFrom` があれば再帰的に呼ぶ（多段交換に対応）。
5. 未実装なら従来どおり伝播しない（後方互換）。

**利点**: RFC 9700 の原則に沿う。監査記録も同時に得られる。
再帰にすれば多段交換にも効く。
**欠点**: ストア契約が増える。再帰失効の停止条件（循環は起きないが深さ）を決める必要がある。
`jti` が opaque トークンでも保存されている前提に依存する
（生成 OP は保存しているが、契約として明文化が要る）。

### 方針D: 交換トークンに独立した grant を切る

- 交換のたびに新しい `grantId` を発行し、元 grant との親子関係を別テーブルで持つ。

**利点**: `clientId` と `grantId` の所属の食い違い（§4.3）が解消される。
Grant Management API（`study-material/ext-grant-management-api.md`）とも相性が良い。
**欠点**: 既存の「grant 単位失効が届く」という現在の利点を **自分で壊す**。
親子関係を辿る失効を別途実装しないと、むしろ後退する。
→ Grant Management を本格導入するときに再検討する話であり、**単独では推しにくい**。

### 判断材料の整理

| 観点 | 方針A | 方針B | 方針C | 方針D |
|---|---|---|---|---|
| §4.2-a（access 失効の伝播） | × | × | ◎ | △ |
| §4.2-b（grantId 無しの穴） | × | ◎ | × | ◎ |
| §4.3（監査記録） | × | × | ◎ | ◎ |
| 実装コスト | 極小 | 小 | 中 | 大 |
| 後方互換 | ◎ | △ | ◎（optional） | × |
| 単独で着手可能か | ○ | ○ | ○ | ×（Grant Management 待ち） |

- **A と B は独立して着手でき、互いに補完的**（A は説明、B は閉塞）。
- **C は A/B の後に段階的に足せる**（optional 契約なので）。
- **D は Grant Management API の判断とセットにすべき**。

---

## 8. タスク案

### T-A（P2・確度高・非破壊・即着手可）: 失効保証の範囲を明文化する

- `packages/experimental/src/token-exchange/token-exchange-request.ts` のモジュール冒頭コメントに
  「失効に関する保証範囲」の節を追加する
  - 届く: grant 単位失効（コード再利用 / RT family / 同意撤回 / RT の RFC 7009 失効）
  - 届かない: subject_token（access token）自身の RFC 7009 失効
- `packages/cli` が生成する token ルートの token-exchange 分岐コメントにも同内容を追記する
- テスト（`packages/cli/src/__tests__`）: 生成コードに当該コメントが含まれることを固定する
- **experimental の変更なので changeset は手で書かない**（CI が patch を自動生成する）

### T-B（P2・確度高）: `grantId` を持たない subject_token の交換を拒否する

- `packages/experimental/src/token-exchange/token-exchange-request.ts`
  - `resolveSubjectToken` の直後（または `processTokenExchangeRequest` 内）で
    `subject.grantId === undefined` を検出し、`SUBJECT_TOKEN_INVALID_DESCRIPTION` で拒否する
  - JSDoc に「grantId 無しのトークンは失効連動できないため交換対象にしない」と明記
- テスト要件（`packages/experimental`）:
  - `should reject a subject_token that has no grantId with invalid_request`
  - `should return the opaque failure description for a subject_token without grantId`
    （他の失敗理由と応答が区別できないこと）
  - `should keep the exchanged token grantId equal to the subject token grantId`
- `samples/*/conformance.test.ts`（生成元は `packages/cli`）に、
  token-exchange 有効時の当該挙動を追加する

### T-C（P3・方針未確定・要人間判断）: 派生関係の記録と失効伝播

- **方針C を採る決定が出るまで着手しない**
- 決定した場合の作業:
  - `AccessTokenInfo` に `derivedFromJti?: string` を追加（`packages/core`）
  - 生成 OP の交換分岐で `subject.jti` を書き込む
  - `RevocationTokenResolvers` に `revokeAccessTokensDerivedFrom?(jti)` を optional 追加
  - `revokeResolvedToken` 後段で access token 失効時に再帰的に呼ぶ
  - ストア契約（`resolver-and-store-contract.md`）へ追記
  - テスト: 単段・多段の交換に対して、元トークン失効が派生を殺すこと／
    未実装 resolver では従来どおり伝播しないこと

---

## 関連トピック

- `study-material/token-exchange-audience-narrowing-vs-userinfo-permanent-membership.md` — 交換結果の権限範囲
- `study-material/token-exchange-authorization-model-allowed-targets-and-subject-token-binding.md` — 誰が交換してよいか
- `study-material/ext-token-exchange-rfc8693.md` — 拡張導入の親トピック
- `study-material/done/authorization-code-reuse-cascade-store-semantics.md` — grant 単位失効の store 意味論
- `study-material/resolver-and-store-contract.md` — resolver / store 契約の明文化方針
- `study-material/ext-grant-management-api.md` — 方針D の前提となる将来トピック
- `study-material/audit-logging-and-observability.md` — 監査ログ（§4.3 の出口）
