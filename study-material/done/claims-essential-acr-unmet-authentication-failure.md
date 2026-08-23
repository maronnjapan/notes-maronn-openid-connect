# Essential な `acr` クレーム要求を満たせない場合の認証失敗（OIDC Core §5.5.1.1 の MUST）

## ステータス

🟠 High（仕様準拠 / セキュリティ）/ 未着手

## 1. このトピックで確認したいこと

`claims` リクエストパラメータで `acr` が **Essential Claim**（`{"essential": true, "values": [...]}`）として要求されたとき、OIDC Core 1.0 §5.5.1.1 は次の 2 つを MUST として課す。

1. 要求された値のいずれかに一致する `acr` を返さなければならない
2. その要求を満たせない場合、**その結果を「認証失敗」として扱わなければならない**

本リポジトリは `claims.id_token.acr.values` を `AcrResolver` へ「要求値」として渡すところまでは実装済みだが、**resolver が返した `acr` が要求値に一致するかを検証せず、一致しなくてもそのまま ID Token を発行する**。`essential` フラグ自体はパースされ型にも保持されるが、コード上どこからも参照されていない。

確認したいのは次の 3 点である。

- §5.5.1.1 の MUST（2 つ）に対する現状の差分
- acr の決定が **Token Endpoint** で行われているため、「認証失敗として扱う」ことが構造上できるのか（認可エンドポイントまで判断が戻らない）
- 満たせない場合に返すべきエラー（`unmet_authentication_requirements`）が本リポジトリに存在しないこと

### 既存ファイルとの関係（重複回避）

同じ `claims` パラメータ・`acr` を扱う既存ファイルがあるため、以下は**繰り返さず参照に留める**。

| 論点 | 扱っているファイル |
|---|---|
| `claims` パラメータの構造対応・パース処理全体 | `tasks/done/p0-claims-id-token-support.md`、`study-material/userinfo-endpoint-comprehensive.md` §3.3 |
| `value` / `values` / `essential` の一般則（Essential でもエラーにしない MUST NOT） | `study-material/done/claims-parameter-value-values-essential.md` |
| `claims` の `sub` に `value` 制約が付いた場合の認証失敗 MUST | `study-material/claims-sub-value-request-binding.md` |
| `acr_values` パラメータの ID Token `acr` への伝播 | `study-material/done/acr-values-request-propagation-to-id-token.md` |
| クライアント登録 `default_acr_values` のフォールバック | `study-material/done/client-default-acr-values-fallback.md` |
| Step-up Authentication（RFC 9470）全体像 | `study-material/ext-step-up-authentication-rfc9470.md` |
| `claims` の claim 名 allowlist / 長さ上限 | `study-material/done/claims-parameter-claim-name-allowlist.md`、`tasks/p1-claims-parameter-claim-name-allowlist.md` |

**本ファイル固有の差分**は「Essential な `acr` 要求が満たせなかったときの MUST 挙動」である。
`study-material/done/claims-parameter-value-values-essential.md` は「Essential でも取得できなければエラーにしない（MUST NOT generate an error）」という**一般則**を結論として書いているが、§5.5.1 のその文言には `unless otherwise specified in the description of the specific claim` という但し書きが付いており、`acr`（§5.5.1.1）と `sub`（§5.5.1 の `value` 説明）はまさにその**例外**にあたる。すなわち一般則ファイルの結論は `acr` にはそのまま適用できない。この点は既存ファイルでは扱われていない。

`study-material/ext-step-up-authentication-rfc9470.md` は差分表の 1 行（🟡）と方針候補で `unmet_authentication_requirements` に触れているが、**RFC 9470（拡張機能）の文脈**であり、「OIDC Core の MUST として現状違反している」という位置づけでは書かれていない。本ファイルはそれを Core の準拠論点として独立させる。

## 2. 関連する仕様・基準

### 2.1 OIDC Core 1.0 §5.5.1.1 Requesting the "acr" Claim（一次情報の原文）

> If the `acr` Claim is requested as an Essential Claim for the ID Token with a `value` or `values` parameter requesting specific Authentication Context Class Reference values and the implementation supports the `claims` parameter, the Authorization Server MUST return an `acr` Claim Value that matches one of the requested values. The Authorization Server MAY ask the End-User to re-authenticate with additional factors to meet this requirement. **If this is an Essential Claim and the requirement cannot be met, then the Authorization Server MUST treat that outcome as a failed authentication attempt.**
>
> Note that the RP MAY request the `acr` Claim as a Voluntary Claim by using the `acr_values` request parameter or by not including `"essential": true` in an individual `acr` Claim request. **If the Claim is not Essential and a requested value cannot be provided, the Authorization Server SHOULD return the session's current `acr` as the value of the `acr` Claim.** If the Claim is not Essential, the Authorization Server is not required to provide this Claim in its response.

読み取れる規範は 4 つ。

| # | 規範 | レベル | 条件 |
|---|---|---|---|
| A | 要求値のいずれかに一致する `acr` を返す | MUST | Essential + `value`/`values` + `claims` パラメータ対応 OP |
| B | 要件を満たせないなら認証失敗として扱う | MUST | 同上 |
| C | 追加要素での再認証を求めてよい | MAY | 同上 |
| D | 非 Essential で要求値を満たせないなら、セッションの現在の `acr` を返す | SHOULD | Voluntary（`acr_values` 経由 or `essential` 無し） |

重要なのは A/B の前提条件に **「and the implementation supports the `claims` parameter」** が含まれる点である。本リポジトリは Discovery で `claims_parameter_supported` を出力でき（`packages/core/src/discovery.ts`）、生成 OP は `claims` を実際にパースして `AcrResolver` へ渡しているため、この前提条件を満たす。すなわち A/B は本リポジトリに適用される。

### 2.2 §5.5.1 の一般則と、その但し書き（原文）

> Note that even if the Claims are not available because the End-User did not authorize their release or they are not present, the Authorization Server MUST NOT generate an error when Claims are not returned, whether they are Essential or Voluntary, **unless otherwise specified in the description of the specific claim.**

`acr` は §5.5.1.1 で、`sub` は `value` メンバーの説明（`If the Claim was sub, a mismatch MUST cause the authentication to fail, as described in Section 3.1.2.2`）で、それぞれ **otherwise specified** されている。したがって「Essential でもエラーにしない」は `acr` / `sub` には当てはまらない。

### 2.3 「認証失敗として扱う」とは何を返すことか

§5.5.1.1 は「failed authentication attempt」としか書いておらず、具体的なエラーコードを規定していない。実務上の選択肢は 2 つある。

- **`unmet_authentication_requirements`**: OpenID Foundation の Final 仕様「OpenID Connect Core Error Code `unmet_authentication_requirements` 1.0」が定義し、IANA の *OAuth Extensions Error Registry* に登録済みのエラーコード。「OP が RP の要求した認証要件を満たせなかった」ことを表す。用途がまさにこのケースに一致する
- **`login_required` / `interaction_required`**: §3.1.2.6 の既存コード。`prompt=none` で追加認証ができない場合には意味的に近いが、「認証要件が満たせない」ことは表現できない

なお §3.1.2.6 が列挙する認可エラーコードは `interaction_required` / `login_required` / `account_selection_required` / `consent_required` / `invalid_request_uri` / `invalid_request_object` / `request_not_supported` / `request_uri_not_supported` / `registration_not_supported` の 9 種であり、**`unmet_authentication_requirements` は §3.1.2.6 の列挙には含まれない**（別仕様で追加登録されたコード）。本リポジトリの `AuthorizationErrorCode` にも当然存在しない。

### 2.4 Basic OP 認定との関係

Basic OP の必須機能に「`claims` パラメータ対応」は含まれない（`claims_parameter_supported` は OPTIONAL）。したがって本件は**認定ブロッカーではない**。ただし本リポジトリは `claims` を実装し Discovery でそれを広告できる立場にあるため、**「対応していると広告しながら §5.5.1.1 の MUST を満たさない」**状態は Fidelity（差別化 3 軸の 1 つ）の観点で問題になる。共通の Basic OP 要件索引は `study-material/basic-op-requirement-traceability.md` を参照。

## 3. 参照資料

- **OpenID Connect Core 1.0 §5.5.1.1 Requesting the "acr" Claim** — https://openid.net/specs/openid-connect-core-1_0.html#acrSemantics
  上記 2.1 に引用した原文。MUST 2 つ（A/B）・MAY 1 つ（C）・SHOULD 1 つ（D）の根拠
- **OpenID Connect Core 1.0 §5.5.1 Individual Claims Requests** — https://openid.net/specs/openid-connect-core-1_0.html#IndividualClaimsRequests
  `essential` / `value` / `values` の定義と、「MUST NOT generate an error ... unless otherwise specified in the description of the specific claim」の但し書き
- **OpenID Connect Core 1.0 §3.1.2.6 Authentication Error Response** — https://openid.net/specs/openid-connect-core-1_0.html#AuthError
  認可エラーの返却経路（`redirect_uri` へ `error` / `state` を返す）と、列挙されている 9 種のエラーコード
- **OpenID Connect Core Error Code `unmet_authentication_requirements` 1.0** — https://openid.net/specs/openid-connect-unmet-authentication-requirements-1_0.html
  `unmet_authentication_requirements` の定義。「the Authorization Server is unable to meet the requirements of the Relying Party for authentication」
- **IANA OAuth Extensions Error Registry** — https://www.iana.org/assignments/oauth-parameters/oauth-parameters.xhtml#extensions-error
  `unmet_authentication_requirements` が登録済みであること（Authorization Endpoint / Token Endpoint 両方の使用箇所）の確認先
- **OpenID Connect Core 1.0 §3.1.2.1** — `acr_values` は Voluntary Claim 要求であること（Essential 要求との差の根拠）
- 本リポジトリ内: `study-material/done/claims-parameter-value-values-essential.md`（一般則。本ファイルはその例外を扱う）、`study-material/claims-sub-value-request-binding.md`（`sub` 側の同型の MUST）

## 4. 現在の実装確認

### 4.1 `essential` はパースされるが、どこからも読まれない

- `packages/core/src/userinfo.ts` の `ClaimRequestEntry` は `essential?: boolean` を持つ（型として保持されている）
- `packages/core/src/authorization-request.ts` の `parseClaimsRequestParameter` が `claims` を `ClaimsParameter` へ整形し、`ValidatedAuthorizationRequest.claims` → `AuthTransaction.claims` → `AuthorizationResponseParams.claims` → `AuthorizationCodeData.claims` → `ValidatedAuthorizationCodeRequest.claims` と伝播する
- しかし `essential` を読むコードはリポジトリ全体に存在しない（`packages/core/src` / `packages/cli/src` を `essential` で grep すると、ヒットするのは型定義・コメント・テストのみ）
- `packages/core/src/userinfo.ts` の `matchesRequestedValue` は `value` / `values` のみを評価し、`essential` は明示的に「値制約なし = 一致」として無視している

### 4.2 `acr` の解決は Token Endpoint で行われ、要求値との一致検証が無い

`packages/core/src/token-response.ts` の `resolveAcrAmr`:

```ts
export async function resolveAcrAmr(input: ResolveAcrAmrInput): Promise<ResolvedAcrAmr> {
  const { subject, clientId, acr, amr, requestedAcrValues, claims, acrResolver } = input;

  if (acr !== undefined || amr !== undefined) return { acr, amr };   // refresh 経路（§12.1 保持）
  if (!acrResolver) return { acr: undefined, amr: undefined };       // resolver 未注入 → acr 省略

  // OIDC Core 1.0 §5.5.1.1: claims.id_token.acr.values is equivalent to
  // requesting these acr values. Use it to seed acrResolver ...
  let effectiveRequestedAcrValues = requestedAcrValues;
  if (effectiveRequestedAcrValues === undefined && claims?.id_token) {
    const acrEntry = claims.id_token['acr'];
    if (acrEntry && Array.isArray(acrEntry.values)) { /* values を空白区切りで結合 */ }
  }

  const result = await acrResolver({ userId: subject, clientId, requestedAcrValues: effectiveRequestedAcrValues });

  return { acr: result?.acr, amr: result?.amr };   // ← 一致検証なし・essential 未参照
}
```

- `claims.id_token.acr.values` は resolver への**種**としてのみ使われる
- `acrEntry.essential` は読まれない
- `result?.acr` が `effectiveRequestedAcrValues` のいずれかと一致するかは**検証されない**
- resolver が `undefined` を返せば `acr` クレームは単に省略される

生成 OP（`packages/cli/src/frameworks/hono/templates.ts`、token ルート）も同じ `resolveAcrAmr` を呼び、戻り値をそのまま `buildIdTokenPayload` の `acr` に渡している。

### 4.3 認可エンドポイントでは acr 要件が一切評価されない

- `packages/core/src/authorization-request.ts` の `validateAuthorizationRequest` は `claims` をパースするだけで、acr 要件の充足可否を判断しない
- 生成 OP の `/authorize` は `prompt=none` 経路（`resolvePromptNoneSession` → `validatePromptNoneIdTokenHint` → `validatePromptNoneConsent` → `requiresReauthentication` による `max_age` チェック）を持つが、**`acr_values` / `claims.id_token.acr` を評価するステップは無い**
- 対話経路（ログイン画面）でも、要求された acr に応じて認証方式を切り替える分岐は無い（`AcrResolver` は Token Endpoint でしか呼ばれない）

### 4.4 `unmet_authentication_requirements` は存在しない

`packages/core/src/authorization-request.ts` の `AuthorizationErrorCode` enum に該当値は無い。リポジトリ全体で `unmet_authentication_requirements` を含むのは `study-material/ext-step-up-authentication-rfc9470.md` のみ。

## 5. 現在の実装との差分

### 満たしていること

- `claims.id_token.acr.values` を認可 → 認可コード → Token Endpoint まで欠落なく伝播している（`done/acr-values-request-propagation-to-id-token.md` の成果）
- `AcrResolver` に要求値を渡す接続点は既にある（一致検証を足す場所が確定している）
- `acr_values` パラメータと `claims.id_token.acr.values` の等価性（§5.5.1.1 の Note）は `resolveAcrAmr` のフォールバックで実現されている

### 不足している可能性があること

- 🔴 **規範 A（MUST）未実装**: Essential 要求に対し、返す `acr` が要求値のいずれかに一致することを保証していない。resolver が要求外の acr を返せばそのまま ID Token に載る
- 🔴 **規範 B（MUST）未実装**: 要件を満たせない場合に認証失敗として扱う経路が無い。resolver が `undefined` を返すと `acr` クレームが**黙って省略された ID Token** が発行される
- 🟠 **エラーコード不在**: `unmet_authentication_requirements` が `AuthorizationErrorCode` に無く、返す手段が無い
- 🟡 **規範 D（SHOULD）未実装**: 非 Essential 要求で要求値を満たせないとき「セッションの現在の acr」を返す挙動が無い（resolver 任せ。resolver が `undefined` を返せば省略される）
- 🟡 **`essential` が dead field**: 型に保持されているだけで一度も参照されず、利用者に「解釈される」という誤解を与える

### 実装はあるが仕様上の確認が必要なこと

- 🟠 **判断タイミングが Token Endpoint である**: §5.5.1.1 の「failed authentication attempt」は、素直に読めば**認証（Authorization Endpoint）の失敗**である。現状 acr が確定するのは Token Endpoint なので、そこで検知しても返せるのは `invalid_grant` 系のトークンエラーであり、RP から見ると「認証は成功したがトークン交換で落ちた」ように見える。RP がユーザーを再認証へ誘導する導線としては劣る
- 🟡 **`AcrResolver` は「認証をやり直す」能力を持たない**: §5.5.1.1 の MAY（追加要素での再認証）を実現するには、認可フローの途中で resolver 相当の判断を行い、必要なら追加認証画面へ遷移する必要がある。現在の resolver シグネチャ（`{userId, clientId, requestedAcrValues} => {acr, amr} | undefined`）には「追加認証が必要」を表す戻り値が無い

### セキュリティ上、改善した方がよいこと

- 🔴 **認証強度のダウングレードが検知されない**: RP が「多要素認証（例 `urn:mace:incommon:iap:silver`）でなければならない」と Essential 要求したのに、OP が単要素セッションのまま認可コードを発行し、`acr` を省略した ID Token を返す。RP 側が `acr` の欠落を厳格に検査していなければ、**要求した認証強度を満たさないセッションを受け入れてしまう**。これは Step-up Authentication（RFC 9470）を成立させる前提が壊れることを意味する
- 🟠 **`prompt=none` との組み合わせ**: サイレント認証で Essential acr が満たせない場合、仕様上は認証失敗（エラー）を返すべきだが、現状は成功レスポンスが返る

### 相互運用性の観点で改善した方がよいこと

- 🟡 RP ライブラリの中には `claims={"id_token":{"acr":{"essential":true,...}}}` を送って `acr` の一致を前提にするものがある。`acr` 欠落 ID Token を返すと RP 側の検証で落ちるが、そのときの原因が OP 側にあることが RP に伝わらない（エラーコードが返らないため）
- 🟡 Discovery の `acr_values_supported` を広告するなら（`study-material/discovery-optional-metadata-fields.md`）、そこに載せた値は Essential 要求で満たせることが期待される。広告と実装の整合を取る必要がある

## 6. 改善・追加を検討する理由

### なぜ価値があるのか

- **明示的な MUST 違反を解消できる**。§5.5.1.1 は解釈の余地が小さく、`claims` パラメータをサポートする OP には無条件で適用される。「Fidelity（Conformance 準拠を信頼性のシグナルとして維持する）」を掲げる本リポジトリにとって、既知の MUST 未実装を放置するのはコストが高い
- **認証強度の要求が「効く」ことは、OIDC を PoC で検証する主要動機の 1 つ**。「MFA を要求したら本当に MFA になるか」を試したい利用者にとって、要求が黙って無視される OP は検証材料にならない
- **Step-up Authentication（RFC 9470）の土台になる**。`study-material/ext-step-up-authentication-rfc9470.md` は「既存資産でほぼ実装済み」と評価しているが、その評価は「要求を満たせないときに止まる」経路の存在を前提にしている。本トピックはその前提を実際に用意する作業にあたる

### Basic OP として必要か、拡張機能として有用か

- **Basic OP の必須要件ではない**（`claims` パラメータは OPTIONAL）。ただし「`claims` を実装している OP としての正しさ」の問題であり、単なる拡張機能の追加とは性質が違う
- 選択肢としては「`claims_parameter_supported: false` を広告して `claims` 対応そのものを降りる」も理屈上は成立するが、既に `claims` の伝播・UserInfo 反映まで実装済みである以上、実装を活かす方が自然

### 現在のリポジトリ構成から見た導入しやすさ

- **導入しやすい点**:
  - `resolveAcrAmr` は既に「要求値」と「解決結果」の両方を 1 か所で持っている。一致検証を足す場所が 1 関数に閉じる
  - 認可エンドポイントには `AuthorizationError`（redirect 可能エラー）の送出機構が確立しており、`AuthorizationErrorCode` に値を 1 つ足せば新しいエラーを返せる（`study-material/done/unsupported-request-parameter-registration.md` と同じパターン）
  - `claims` は `AuthTransaction` まで届いているので、認可エンドポイント側で acr 要件を読むこと自体は追加の配線を必要としない
- **導入しにくい点**:
  - 「認可時点で acr 要件を判定する」には、Token Endpoint にしか無い `AcrResolver` を**認可フロー側でも呼べるようにする**必要があり、resolver のシグネチャ or 呼び出し位置の設計変更を伴う
  - `AcrResolver` の戻り値に「満たせない」を表す第 3 の状態を足すのは、既存利用者への破壊的変更になりうる（`undefined` は現在「acr を付けない」を意味しており、「満たせない」と区別できない）

### 既存実装との接続

- `resolveAcrAmr`（`packages/core/src/token-response.ts`）: 一致検証の実装点
- `AuthorizationErrorCode`（`packages/core/src/authorization-request.ts`）: エラーコード追加点
- 生成 OP の `/authorize`（`packages/cli/src/frameworks/hono/templates.ts`）: 認可時点で判定する場合の分岐挿入点。`prompt=none` 経路の `max_age` チェック（`requiresReauthentication`）の直後が構造的に近い
- 各 sample の `conformance.test.ts`: 挙動を契約として固定する場所（生成元は `packages/cli` 側）

### 利用者・開発者・運用者のメリット

- 利用者（PoC 開発者）: 「認証強度の要求が効くか」を実際に観測できる。RP 側の実装検証にも使える
- 開発者: `essential` が dead field でなくなり、型と挙動が一致する
- 運用者: 認証要件を満たさない発行が検知され、ログ・監査で追える（`study-material/audit-logging-and-observability.md` と接続しうる）

### 実装しない場合に残る制約・リスク

- `claims_parameter_supported: true` を広告しながら §5.5.1.1 の MUST を満たさない状態が続く
- RFC 9470 Step-up の「既存資産でほぼ実装済み」という評価が、実際には成立しない
- 認証強度のダウングレードが黙って通るため、MFA 検証の PoC に使えない

## 7. 実装方針の候補

**最終判断は人間が行う。以下は判断材料の整理であり、推奨の決定ではない。**

### 方針 A: Token Endpoint で一致検証のみを行う（最小）

`resolveAcrAmr` に「Essential かつ要求値と不一致 / 未解決なら例外」を足す。

- 変更範囲: `packages/core/src/token-response.ts` の 1 関数 + 呼び出し側のエラー変換
- 利点: 最小の変更で MUST A/B の「黙って発行しない」部分は満たせる。既存の resolver シグネチャを変えない
- 欠点: RP には Token Endpoint のエラーとして返るため、§5.5.1.1 の「failed authentication attempt」という意味づけとはずれる。認可コードは既に発行済み（かつ consume 済み）で、RP は再度認可からやり直す必要がある
- 返すエラー: `invalid_grant` になるが、`error_description` で理由を示す。あるいは Token Endpoint で `unmet_authentication_requirements` を返す（IANA 登録上は Token Endpoint での使用も想定されている）

### 方針 B: 認可エンドポイントで判定し、`unmet_authentication_requirements` を redirect で返す

認可フローの中で acr 要件を評価し、満たせないなら認可エラーとして `redirect_uri` へ返す。

- 変更範囲: `AuthorizationErrorCode` への値追加、認可フローへの判定ステップ追加、acr 判定を認可時点で行うための resolver 呼び出し設計
- 利点: §5.5.1.1 の意味に最も忠実。RP は認可レスポンスでエラーを受け取り、`prompt=login` や追加要素を伴う再要求へ自然に進める。`prompt=none` との組み合わせも正しく表現できる
- 欠点: 設計変更が最大。acr の判定ロジックを認可時点と Token 発行時点の 2 か所で一貫させる必要がある（判定結果を `AuthTransaction` / 認可コードへ持ち回るか、両方で resolver を呼ぶか）
- 論点: `AcrResolver` を認可時点でも呼ぶなら、resolver は「認証がまだ済んでいない状態」でも呼ばれうる。現行シグネチャの `userId` は認証後にしか確定しないため、呼び出し位置（ログイン完了後・同意前）を決める必要がある

### 方針 C: 「追加認証を要求する」戻り値を `AcrResolver` に追加する（§5.5.1.1 の MAY を実装）

resolver が「この acr を満たすには追加認証が必要」を返せるようにし、認可フローが追加認証画面へ遷移する。

- 利点: §5.5.1.1 の MAY（re-authenticate with additional factors）まで満たせる。Step-up の完全な土台になる
- 欠点: 認証 UI の設計（追加要素の入力画面）まで必要になり、`study-material/end-user-authentication-contract-and-credential-handling.md` の範囲に踏み込む。PoC ライブラリとしてどこまで面倒を見るかの方針判断が要る
- 方針 B の上に積む拡張として位置づけられる

### 方針 D: `claims` の acr サポートを降りる

`claims.id_token.acr` を受け取ったら `invalid_request` で拒否し、Discovery で `claims_parameter_supported: false` を広告する。

- 利点: MUST 違反状態は解消する。実装コストは最小
- 欠点: 既に動いている `acr.values` → resolver の連携を捨てることになり、機能後退。`study-material/request-object-rejection-and-discovery-honesty.md` の「対応しないなら正しく拒否する」方針とは整合するが、本件は既に実装が存在する点が異なる

### 横断的な論点（方針を問わず決めるべきこと）

- **`essential: false` / `essential` 省略時の SHOULD（規範 D）をどうするか**: 「セッションの現在の acr を返す」を core が実装するには、core が「セッションの acr」を知っている必要がある。現状 core は認証ポリシーを一切持たないため、resolver に委ねるか、`AcrResolver` の契約として文書化するかの選択になる
- **`acr_values_supported` の広告との整合**: Discovery で広告する値と、Essential 要求で実際に満たせる値を一致させるか（`study-material/discovery-optional-metadata-fields.md` と接続）
- **refresh_token grant での扱い**: §12.1 により refresh 時の ID Token は初回認証の `acr` を保持する。初回に満たしていた要件が refresh 時も満たされているとみなすのが自然だが、`claims` パラメータ自体が refresh 経路で伝播していない（`study-material/refresh-grant-claims-context-not-preserved.md`）ため、そもそも再評価する材料が無い。本トピックの対象を authorization_code grant に限定するかを明示する必要がある

## 8. タスク案

- [ ] **仕様確定**: §5.5.1.1 の MUST A/B と SHOULD D を、本リポジトリのどのレイヤ（core / 生成 OP）で担保するかを決める
- [ ] **エラーコード方針の決定**: `unmet_authentication_requirements` を `AuthorizationErrorCode` に追加するか、既存コードで代替するかを決める。追加する場合は「§3.1.2.6 の列挙外だが IANA 登録済み」であることをコメントに明記する
- [ ] **判定位置の決定**: 方針 A（Token Endpoint）/ 方針 B（認可エンドポイント）のいずれを採るか。B の場合は `AcrResolver` の呼び出し位置と `AuthTransaction` への結果保持の設計を決める
- [ ] **実装（最小合意部分）**: Essential + `values` 要求に対し、解決された `acr` が要求値のいずれかに一致しない場合に**黙って発行しない**（例外を投げる）ようにする
- [ ] **テスト（core）**:
  - [ ] `should reject issuance when an essential acr claim request cannot be satisfied`
  - [ ] `should issue the ID Token when the resolved acr matches one of the requested values`
  - [ ] `should not fail issuance when the acr claim request is voluntary`（`essential` 省略 / `false`）
  - [ ] `should treat claims.id_token.acr.values as equivalent to acr_values when acr_values is absent`（既存挙動の回帰固定）
- [ ] **テスト（生成 OP / conformance）**: `packages/cli` のテンプレート生成コードを更新したうえで、`samples/*/conformance.test.ts` に Essential acr 未充足時の応答（エラーコード・redirect 先・`state` エコー）を固定する
- [ ] **E2E**: 実ブラウザで「Essential acr を要求 → 満たせない → RP がエラーを受け取る」経路を `tests/e2e` に追加できるか検討する
- [ ] **ドキュメント**: `AcrResolver` の JSDoc に「要求値を満たせない場合に何を返すべきか」の契約を明記する
- [ ] **既存ファイルの整合**: `study-material/done/claims-parameter-value-values-essential.md` の「Essential でもエラーにしない」結論に、`acr` / `sub` が例外である旨の注記を追加する
- [ ] **Step-up との接続確認**: `study-material/ext-step-up-authentication-rfc9470.md` の差分表 🟡 行を本ファイルへの参照に置き換える
