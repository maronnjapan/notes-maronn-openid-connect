# `claims` リクエストパラメータで要求されたクレームが同意（認可）境界を通らずに開示される

## 1. このトピックで確認したいこと

`claims` リクエストパラメータ（OIDC Core 1.0 §5.5）で個別要求されたクレームが、**エンドユーザーの同意（authorization）を一切経由せずに** UserInfo レスポンスへ載る。

- 同意画面は `scope` の一覧だけを表示し、`claims.userinfo` / `claims.id_token` で要求された個別クレームを表示しない。
- `applyRequestedClaims` はスコープ由来のレスポンスに対して、**付与スコープと無関係に**要求クレームを重ねる（生成コードのコメントも "independently of scope" と明記している）。
- SSO の同意スキップ経路（`hasConsent`）は **要求 scope の部分集合判定のみ**で行われるため、`claims` が変わっても「同意済み」と判定され、追加の PII が無言で開示される。

つまり「scope 単位の同意」と「claims 単位の開示」が**別レイヤで動いており接続されていない**。本ファイルはこの**認可境界の欠落**に限定して扱う。

**既存ファイルとの切り分け（重複回避）**

| 論点 | 扱っているファイル |
|---|---|
| `claims` の構文・`value` / `values` / `essential` の**解釈** | `study-material/done/claims-parameter-value-values-essential.md`、`tasks/p2-claims-id-token-member-individual-claims.md` |
| `claims` パラメータの**サイズ上限 / DoS** | `study-material/done/untrusted-input-payload-size-dos-hardening.md`、`tasks/done/p2-claims-parameter-payload-size-limit.md` |
| **同意の永続化・grant 管理**そのもの | `study-material/done/consent-grant-persistence-and-management.md` |
| scope の**部分同意（チェックボックス）** | `study-material/scope-handling-validation-and-granted-scope.md` |
| Discovery `claims_supported` / `claims_parameter_supported` の広告整合 | `study-material/done/discovery-claims-feature-advertisement.md` |
| 要求**できるクレーム名の集合**が定義されていない（任意プロパティ読み出し） | `study-material/done/claims-parameter-claim-name-allowlist.md`、`tasks/p1-claims-parameter-claim-name-allowlist.md` |

本ファイルは上記のいずれとも異なり、「**要求クレームを返してよいという判断を誰が下したのか**」だけを論点にする。

## 2. 関連する仕様・基準（このトピック固有の差分）

### 2.1 OIDC Core 1.0 §5.5 — 開示は「End-User が許可した場合」に限られる

§5.5 は `claims` パラメータの導入部で、要求されたクレームの返却が**エンドユーザーの許可に条件付けられている**ことを明示している。

> The Claims requested by the `profile`, `email`, `address`, and `phone` scope values are returned from the UserInfo Endpoint ... **if the End-User authorized their release**.

同じ条件は §5.4（scope 由来のクレーム）にも掛かっており、§5.5 の個別クレーム要求もこの前提の上に置かれている。つまり仕様上、`claims` は「RP が要求できる」ことを定めるだけで、「OP が無条件に返してよい」とは定めていない。**開示の可否判断は OP の認可（同意）レイヤの責務**である。

### 2.2 OIDC Core 1.0 §3.1.2.4 — 同意取得は Authorization Endpoint の責務

> Once the End-User is authenticated, the Authorization Server MUST obtain an authorization decision before releasing information to the Relying Party.

「releasing information」は access token / ID Token だけでなく、**その後 UserInfo で開示される情報**も含めて読むのが自然である（§5.5 の "authorized their release" と整合する）。scope しか提示していない同意画面は、`claims` で追加要求された属性について authorization decision を取っていない。

### 2.3 OIDC Core 1.0 §16.x（Privacy Considerations）/ §5.5.1 の位置づけ

- §5.5.1 は `essential` について「取得できなくても OP はエラーを返してはならない（MUST NOT）」と定める。裏返すと、**要求されたクレームを返さないことは常に仕様適合**である。したがって「同意が無いので返さない」という保守的挙動は仕様違反にならない。
- 逆に「同意なしで返す」ことを仕様が要求する記述は存在しない。すなわち**安全側に倒す自由度が仕様上ある**。

### 2.4 Basic OP certification profile との関係

OpenID Foundation の Basic OP certification profile（OpenID Connect Conformance Profiles）は `claims` パラメータを必須テスト対象にしていない（`claims_parameter_supported` は OPTIONAL なメタデータで、Basic OP のコアテストは `response_type=code` + scope 由来クレームを対象とする）。

したがって本トピックは **Basic OP の必須要件ではなく、`claims` を実装している以上守るべき OIDC Core の認可要件・プライバシー要件**として扱う。Basic OP 要件の全体像は `study-material/basic-op-requirements-baseline.md` を参照（ここでは繰り返さない）。

## 3. 参照資料

- OpenID Connect Core 1.0 §5.4 Requesting Claims using Scope Values
  — https://openid.net/specs/openid-connect-core-1_0.html#ScopeClaims
  （"...are returned from the UserInfo Endpoint ... if the End-User authorized their release"）
- OpenID Connect Core 1.0 §5.5 Requesting Claims using the "claims" Request Parameter
  — https://openid.net/specs/openid-connect-core-1_0.html#ClaimsParameter
- OpenID Connect Core 1.0 §5.5.1 Individual Claims Requests
  — https://openid.net/specs/openid-connect-core-1_0.html#IndividualClaimsRequests
  （`essential` を満たせなくてもエラーにしない MUST NOT）
- OpenID Connect Core 1.0 §3.1.2.4 Authorization Server Obtains End-User Consent/Authorization
  — https://openid.net/specs/openid-connect-core-1_0.html#Consent
  （"MUST obtain an authorization decision before releasing information to the Relying Party"）
- OpenID Connect Core 1.0 §16 Security Considerations / Privacy Considerations
  — https://openid.net/specs/openid-connect-core-1_0.html#Security
- 本リポジトリ内（重複回避のための参照先）: `study-material/done/claims-parameter-value-values-essential.md`、`study-material/done/consent-grant-persistence-and-management.md`、`study-material/scope-handling-validation-and-granted-scope.md`

## 4. 現在の実装確認

### 4.1 core: 付与スコープを見ずに要求クレームを重ねる

`packages/core/src/userinfo.ts`

```ts
// getRequestedClaimNames（257-262 行）: claims.userinfo のキーをそのまま列挙する
function getRequestedClaimNames(claimsParameter?: ClaimsParameter): (keyof UserClaims)[] {
  if (!claimsParameter?.userinfo) return [];
  return Object.keys(claimsParameter.userinfo) as (keyof UserClaims)[];
}

// applyRequestedClaims（477-497 行）
export function applyRequestedClaims(
  response: UserInfoResponse,
  userClaims: UserClaims,
  claimsParameter?: ClaimsParameter,
): UserInfoResponse {
  const result: Record<string, unknown> = { ...response };
  for (const claimName of getRequestedClaimNames(claimsParameter)) {
    if (claimName === 'sub') continue;
    const value = userClaims[claimName];
    if (value === undefined || value === null) continue;
    const entry = claimsParameter?.userinfo?.[claimName] ?? null;
    if (!matchesRequestedValue(value, entry)) continue;
    result[claimName] = value;      // ← 付与 scope も同意状態も参照しない
  }
  return result as UserInfoResponse;
}
```

`handleUserInfoRequest`（519-539 行）は `filterClaimsByScope`（scope でフィルタ）→ `applyRequestedClaims`（scope 無視で上書き）の順に呼ぶため、**後段が前段の制約を実質的に無効化できる**構造になっている。

### 4.2 生成 OP: 同意画面は scope しか出さない

`packages/cli/src/frameworks/hono/templates.ts`（`consentRouteTemplate`）

```ts
// 3409 行付近
return renderView(views.consentPage({
  transactionId,
  csrfToken: transaction.csrfToken,
  scopes: transaction.scope.split(' ').filter(Boolean),   // ← claims は渡していない
  clientId: transaction.clientId,
}));
```

`AuthTransaction`（`packages/core/src/auth-transaction.ts:123-124`）は `claims?: ClaimsParameter` を保持しているので、**画面に渡すデータは存在するのに使われていない**。

### 4.3 生成 OP: claims をアクセストークン metadata へ保存し、UserInfo で無条件適用

`packages/cli/src/frameworks/hono/templates.ts`（`tokenRouteTemplate`, 2708 行付近）

```ts
await accessTokenStore.set(tokenResponse.access_token, {
  ...
  // OIDC Core 1.0 §5.5: persist the authorization request's claims parameter
  // so the UserInfo endpoint can honor claims.userinfo members (e.g.
  // {"userinfo":{"name":{"essential":true}}}) independently of scope.
  claims: validatedRequest.grantType === 'authorization_code' ? validatedRequest.claims : undefined,
});
```

生成された UserInfo ルート（例: `samples/hono-cloudflare/src/oidc-provider/routes/userinfo.ts:138-143`）は `filterClaimsByScope` の結果に `applyRequestedClaims(scopedResponse, userClaims, tokenInfo.claims)` を重ねる。

### 4.4 生成 OP: SSO 同意スキップは scope 部分集合だけで判定

`packages/cli/src/frameworks/hono/templates.ts`（`authorizeRouteTemplate`, 1975-1982 行付近）

```ts
const requestedScopes = transaction.scope.split(' ').filter(Boolean);
const consentAlreadyGranted =
  !promptValues.includes('consent') &&
  consentResolver !== undefined &&
  (await consentResolver.hasConsent(
    existingSession.subject,
    transaction.clientId,
    requestedScopes,          // ← claims は判定に入らない
  ));
```

`prompt=none` 経路（`validatePromptNoneConsent`, `packages/core/src/auth-transaction.ts:441-462`）も同じく `transaction.scope` だけを見る。

### 4.5 帰結（再現シナリオ）

1. RP が `scope=openid`（profile / email 無し）で認可リクエストを送り、同時に
   `claims={"userinfo":{"email":null,"phone_number":null,"address":null}}` を付ける。
2. 同意画面には `openid` だけが表示される。ユーザーは「メールアドレスも住所も電話番号も渡さない」と認識して許可する。
3. UserInfo は `filterClaimsByScope` で `sub` だけを返した後、`applyRequestedClaims` が `email` / `phone_number` / `address` を上書きで追加する。
4. さらに一度この状態で同意が記録されると、以後 `claims` を差し替えた別リクエストでも SSO 経路の `hasConsent(scope)` が true になり、**同意画面が二度と出ないまま**追加クレームが開示され続ける。

## 5. 現在の実装との差分

### 満たしていること

- `claims` パラメータの構文パース・サニタイズ（`parseClaimsRequestParameter`）は実装済み。
- `value` / `values` の値制約は `matchesRequestedValue` で解釈済み（`essential` でもエラーにしない §5.5.1 の MUST NOT を守る）。
- `sub` は要求クレームで上書きできないよう保護されている（`applyRequestedClaims` の `if (claimName === 'sub') continue`）。
- `claims` を認可コード → アクセストークン metadata へ引き継ぐ配線は存在する（開示の**土管**は正しく通っている）。

### 不足している可能性があること

- 同意画面に `claims.userinfo` / `claims.id_token` の要求クレームが**一切表示されない**（§3.1.2.4 の authorization decision を取れていない）。
- 付与スコープ・同意記録と `applyRequestedClaims` の間に**ゲートが無い**。
- 同意記録の粒度が scope 集合のみで、`claims` の差分が「同意の変化」として検知されない（SSO スキップの再判定条件に入らない）。

### 実装はあるが仕様上の確認が必要なこと

- `claims` を無条件に honor する現在の設計が「意図的な PoC 向け割り切り」なのか「未実装」なのかがコードコメント以外に明記されていない。ライブラリの利用者（生成コードを改造する PoC 開発者）が**気付けない**。
- `claims_parameter_supported: true` を広告している場合、広告と「同意なしで返す」挙動の組合せが利用者にどう見えるかの整理（Discovery 側の整合は `study-material/done/discovery-claims-feature-advertisement.md`）。

### セキュリティ上、改善した方がよいこと

- **同意バイパスによる PII 開示**。攻撃者ではなく「行儀の悪い RP」で成立する点が問題で、ユーザーは自分が何を渡したか把握できない。
- **同意記録の再利用による恒久化**。一度でも同意を取れば、以後 `claims` を膨らませても再同意が発生しない。
- OP を PoC として立てた利用者が、そのままの挙動を本番同等と誤解するリスク。

### 相互運用性の観点で改善した方がよいこと

- 主要 IdP（Google / Auth0 / Keycloak 等）は `claims` の個別要求に対しても scope / consent の認可を前提にしており、無条件開示は挙動差になる。RP 側の PoC が「このライブラリでは取れるのに本番 IdaaS では取れない」という移行時の落とし穴になる。

### Basic OP として提供する上で確認すべきこと

- Basic OP certification profile 自体は `claims` を必須にしていないため、**この差分が Conformance の合否を左右する可能性は低い**。ただし `claims_parameter_supported` を true で広告する構成では、機能を提供する以上 §5.5 の前提（authorized release）を満たす必要がある。

## 6. 改善・追加を検討する理由

- **価値**: 「同意画面に出ていないものは返らない」という不変条件は、OIDC の学習・検証ツールとして最も分かりやすい安全側の性質であり、PoC 開発者が自分の要件（どこまで属性を出すか）を検証するうえで本質的。
- **Basic OP 必須か拡張か**: Basic OP の必須要件ではない。ただし `claims` を実装した時点で OIDC Core §5.5 / §3.1.2.4 の適用対象になるため、「拡張機能の正しさ」の問題として扱うのが妥当。
- **導入しやすさ**: `AuthTransaction.claims` は既に保持されており、同意画面テンプレートに渡すだけで表示できる。ゲート側も `applyRequestedClaims` に「許可されたクレーム名の集合」を渡すオプション引数を足すだけで局所導入できる。既存シグネチャは第3引数までなので**後方互換な追加が可能**。
- **既存実装との接続**: `ConsentResolver`（`auth-transaction.ts:30-47`）が既に拡張点として存在するため、同意粒度を `{ scopes, claims }` に拡張する余地がある。ただし `hasConsent(subject, clientId, scopes)` のシグネチャ変更は破壊的なので、別メソッド追加（任意実装）が現実的。
- **メリット**: 利用者は「scope と claims のどちらで属性を要求すべきか」を実機で比較検証できる。運用者は同意ログに claims を残せる。
- **実装しない場合に残るリスク**: 同意なしの PII 開示が既定挙動として残り、生成コードをそのまま本番寄りに使った利用者が個人情報保護の観点で事故を起こしうる。少なくとも**ドキュメントでの明示は必須**。

## 7. 実装方針の候補（最終判断は人間が行う）

### 方針A: 付与スコープでゲートする（最小・後方互換）

`applyRequestedClaims` に第4引数 `options?: { grantedScopes?: string[] }` を追加し、指定時は
「要求クレームが `SCOPE_CLAIMS_MAP` 上いずれかの付与スコープに属する場合のみ返す」ようにする。

- 長所: core の変更が小さい。同意 UI を変えずに「scope に無い属性は出ない」を保証できる。
- 短所: `claims` の存在意義（scope に紐づかない属性の個別要求）を削ってしまう。
  `SCOPE_CLAIMS_MAP` に載らないカスタムクレームは常に返せなくなる。

### 方針B: 同意画面に claims を表示し、同意結果を granted claims として記録する（本筋）

1. `consentPage` に `requestedClaims`（`claims.userinfo` / `claims.id_token` のキー）を渡して表示。
2. 同意 POST で `grantedClaims: string[]` を確定し、`AuthorizationCodeData` → アクセストークン metadata へ引き継ぐ。
3. `applyRequestedClaims` は `grantedClaims` に含まれるものだけを適用。
4. `ConsentResolver` に任意メソッド `hasClaimsConsent?(subject, clientId, claimNames)` を追加し、SSO スキップ判定に組み込む。

- 長所: 仕様の意図（authorized release）に最も忠実。scope に無いカスタムクレームも扱える。
- 短所: 変更範囲が core・CLI テンプレート・views・store 契約・conformance.test に広がる。

### 方針C: 既定は「無視」、オプトインで honor する

`claims` を既定では適用せず、`ProviderConfig.honorClaimsParameterWithoutConsent: true`（既定 false）を明示的に設定した場合のみ現行挙動にする。Discovery の `claims_parameter_supported` も同フラグに連動させる。

- 長所: 最も安全側。§5.5.1 の「返さなくてよい」に依拠するため仕様違反にならない。
- 短所: 現行の `p2-claims-id-token-member-individual-claims` 系タスクの方向性（claims を厚く honor する）と逆行しうる。

### 方針D: 挙動は変えず、ドキュメントと警告に留める

README / 生成コードコメント / `RELEASE-v0.x-scope.md` に「`claims` は同意ゲートを通らない」ことを明記し、
`conformance.test.ts` で現行挙動を意図的挙動として固定する。

- 長所: コスト最小。v0.x のリリースを止めない。
- 短所: 事故リスクは残る。

### 判断材料

- 方針B が仕様的には正解だが、v0.x のリリース方針（主要フロー優先）からは重い。
- **方針A + 方針D の併用**（scope ゲートを既定にし、カスタムクレームを扱いたい利用者向けに拡張点とドキュメントを用意）が、コストと安全性のバランスとしては有力。
- 方針C は「Basic OP の主要フローには claims が要らない」ことを踏まえると合理的だが、既存の claims 対応タスク群との整合を人間が判断する必要がある。

## 8. タスク案

- [ ] `applyRequestedClaims` の現行挙動（scope 非依存の上書き）を単体テストで**明示的に固定**し、「意図された挙動」なのか「未実装」なのかを判断できる状態にする
- [ ] 方針A〜D のいずれを採るかを決定する（人間判断）
- [ ] 方針A を採る場合: `applyRequestedClaims(response, userClaims, claimsParameter, options?: { grantedScopes?: string[] })` を後方互換で追加し、生成 UserInfo ルートから `tokenInfo.scope` を渡す
- [ ] 方針B を採る場合: 同意画面テンプレートへの `requestedClaims` 伝播、`grantedClaims` の永続化経路、`ConsentResolver` の任意メソッド追加を設計する
- [ ] SSO 同意スキップ（`consentAlreadyGranted`）と `validatePromptNoneConsent` の判定に `claims` 差分を含めるかを決定する
- [ ] `samples/*/conformance.test.ts`（生成元は `packages/cli`）に「scope に無い claims 要求の扱い」を契約テストとして追加する
- [ ] `study-material/RELEASE-v0.x-scope.md` に本トピックの結論（v0.x で対応するか、ドキュメント明示に留めるか）を追記する
