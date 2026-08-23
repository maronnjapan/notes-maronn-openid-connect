# `claims` パラメータのクレーム名が任意プロパティ読み出しになっている（クレーム語彙のアロウリスト不在）

## ステータス

🟠 High（セキュリティ・情報開示）/ 未着手

## 1. このトピックで確認したいこと

UserInfo の `applyRequestedClaims`（`packages/core/src/userinfo.ts`）は、
`claims.userinfo` の **キー名をそのまま `userClaims` オブジェクトのプロパティ名として読み出す**。
読み出すキーが OIDC Core 1.0 §5.1 の標準クレームであるか、
そもそも OP が開示対象として宣言したクレームであるかを**一切検査していない**。

一方、scope 由来の経路（`filterClaimsByScope`）は `SCOPE_CLAIMS_MAP` に載っているクレーム名だけをコピーする
**アロウリスト方式**である。つまり同じ `UserClaims` オブジェクトに対して、
**scope 経路はアロウリスト、`claims` 経路は任意キー読み出し**という非対称が存在する。

`UserClaimsResolver.findUserClaims()` は利用者が実装する。PoC 開発者が DB の行オブジェクトや
内部ユーザーモデルをそのまま返す実装は現実的にありふれており、その場合
**`claims={"userinfo":{"<内部フィールド名>":null}}` を送るだけで、scope とは無関係にその値が UserInfo から返る**。

本ファイルで整理するのは以下。

- この挙動が仕様上どう位置づけられるか（`claims` は「scope 外のクレームも要求できる」のが本来の仕様であり、単純な仕様違反ではない）
- それでもアロウリストを置くべき理由（型が防いでいると誤解されやすい構造になっている）
- プロトタイプチェーン上のプロパティを読む経路の実害範囲（過大評価しないための切り分け）
- アロウリストの供給元をどこに置くか（`SCOPE_CLAIMS_MAP` / Discovery `claims_supported` / 注入可能な語彙）

### 既存ファイルとの差分（重複回避）

| 論点 | 扱っているファイル |
|---|---|
| 要求クレームを**返してよいと誰が判断したか**（同意・認可境界の欠落） | `study-material/claims-parameter-consent-authorization-boundary.md` |
| `UserClaims` が閉じた interface で**非標準クレームを運べない**という拡張性の問題と、その解法（写像の注入） | `study-material/userinfo-custom-claims-and-scope-claim-mapping-extensibility.md` |
| ID Token 側で条件付き代入クレームが spoof される経路と denylist | `tasks/p2-id-token-reserved-claim-denylist.md` |
| `value` / `values` / `essential` の**判定規則** | `study-material/done/claims-parameter-value-values-essential.md` |
| `claims` パラメータの**サイズ上限 / DoS** | `study-material/done/untrusted-input-payload-size-dos-hardening.md`、`tasks/done/p2-claims-parameter-payload-size-limit.md` |
| Discovery `claims_supported` / `claims_parameter_supported` の**広告整合** | `study-material/done/discovery-claims-feature-advertisement.md` |

本ファイルは「**読み出してよいキーの集合が定義されていない**」という一点に絞る。

- 同意境界ファイルとの関係: 同意ゲートを実装しても、**同意対象として提示するクレーム名の集合が定義されていなければ**
  同意画面に内部フィールド名がそのまま並ぶことになる。本トピックは同意ゲートの**前提条件**である。
- 拡張性ファイルとの関係: あちらは「語彙を**広げたい**」、本ファイルは「語彙を**定義したい**」。
  語彙が定義されて初めて「広げる」対象が決まるため、両者は同じ設計判断の表裏にあたる。
  実装するなら同時に扱うのが自然だが、**セキュリティ上の緊急度は本ファイルの方が高い**（拡張性は無くても事故らないが、無制限読み出しは事故る）。

## 2. 関連する仕様・基準（このトピック固有の差分）

### 2.1 OIDC Core 1.0 §5.5 — `claims` は「scope 外も要求できる」が「何でも返してよい」ではない

§5.5 は `claims` パラメータを「個別クレームを名指しで要求する」機構として定義し、
`userinfo` / `id_token` の各メンバーの値は「クレーム名 → 要求仕様」の JSON オブジェクトであると規定する。
仕様は**要求できるクレーム名の集合を制限していない**。したがって
「未知のクレーム名を送られること」自体は仕様の想定内であり、実装が拒否する必要はない。

重要なのは §5.5 が続けて規定する扱いである。

> Note that when the `claims` request parameter is supported, ... **the Claims that are returned are those that the OP is willing to release**（要旨）

および §5.5.1 の

> ... the OP **SHOULD** make its best effort to provide it ... （`essential` について）
> ... an OP **MUST NOT** return an error（要求クレームを返せない場合）

すなわち仕様は「**要求されたクレームを返さないこと**」を常に許容している。
逆に「要求されたのだから返さねばならない」とは一切書いていない。
したがって**アロウリストで絞ることは完全に仕様適合**である。

### 2.2 OIDC Core 1.0 §5.1 / §5.1.2 — クレーム名の名前空間

§5.1 は Standard Claims を列挙し、§5.1.2 は追加クレーム（Additional Claims）について
「OP と RP の合意のもとで使ってよい」「衝突回避のため Collision-Resistant Name を推奨」と述べる。
つまりクレーム名は **OP が定義して公開する語彙**であって、RP が任意に指定して OP のデータ構造を探索する空間ではない。

### 2.3 OIDC Discovery 1.0 §3 — `claims_supported` が語彙の宣言場所

Discovery メタデータの `claims_supported` は
「OP が返しうるクレーム名のリスト（網羅的でなくてよい）」として定義される。
仕様上は informative（"This list MAY be incomplete"）だが、
**OP 自身が「開示しうるクレームの語彙」を持っている**ことを前提にした項目である。
現在の実装はこの語彙を**実行時の判断に使っていない**（メタデータとして出力するだけ）。

### 2.4 OWASP / 一般原則 — Mass Assignment の読み取り版

外部入力（`claims` のキー名）が内部オブジェクトのプロパティ名に直結する構造は、
書き込み方向で言う Mass Assignment と同型の読み取り方向の問題である。
防御の定石はアロウリスト（許可キーの明示）であり、denylist（禁止キーの列挙）は
「利用者が返す独自オブジェクトのフィールド名を OP 側が知り得ない」ため本件では機能しない。

## 3. 参照資料

- OpenID Connect Core 1.0 §5.5 Requesting Claims using the "claims" Request Parameter — https://openid.net/specs/openid-connect-core-1_0.html#ClaimsParameter
- OpenID Connect Core 1.0 §5.5.1 Individual Claims Requests（`essential` と「エラーを返してはならない」規定） — https://openid.net/specs/openid-connect-core-1_0.html#IndividualClaimsRequests
- OpenID Connect Core 1.0 §5.1 Standard Claims / §5.1.2 Additional Claims — https://openid.net/specs/openid-connect-core-1_0.html#StandardClaims
- OpenID Connect Core 1.0 §5.4 Requesting Claims using Scope Values — https://openid.net/specs/openid-connect-core-1_0.html#ScopeClaims
- OpenID Connect Discovery 1.0 §3 Provider Metadata（`claims_supported`） — https://openid.net/specs/openid-connect-discovery-1_0.html#ProviderMetadata
- OWASP Cheat Sheet Series: Mass Assignment（アロウリスト方式の根拠） — https://cheatsheetseries.owasp.org/cheatsheets/Mass_Assignment_Cheat_Sheet.html

## 4. 現在の実装確認

### 4.1 scope 経路：アロウリスト方式（安全）

`packages/core/src/userinfo.ts:232-252`

```ts
export function filterClaimsByScope(userClaims: UserClaims, scopes: string[]): UserInfoResponse {
  const result: Record<string, unknown> = { sub: userClaims.sub };
  for (const scope of scopes) {
    const claimNames = SCOPE_CLAIMS_MAP[scope];   // ← 定義済みの語彙だけ
    if (!claimNames) continue;
    for (const claimName of claimNames) {
      const value = userClaims[claimName];
      if (value !== undefined && value !== null) result[claimName] = value;
    }
  }
  return result as UserInfoResponse;
}
```

`SCOPE_CLAIMS_MAP`（同ファイル :203-223）は `profile` / `email` / `address` / `phone` の
標準クレーム名のみを列挙しており、ここに無いフィールドは決してコピーされない。

### 4.2 `claims` 経路：任意キー読み出し

```ts
function getRequestedClaimNames(claimsParameter?: ClaimsParameter): (keyof UserClaims)[] {
  if (!claimsParameter?.userinfo) return [];
  return Object.keys(claimsParameter.userinfo) as (keyof UserClaims)[];   // ← :261 無検証のキャスト
}

export function applyRequestedClaims(response, userClaims, claimsParameter): UserInfoResponse {
  const result: Record<string, unknown> = { ...response };
  const requestedClaims = getRequestedClaimNames(claimsParameter);
  for (const claimName of requestedClaims) {
    if (claimName === 'sub') continue;
    const value = userClaims[claimName];               // ← :487 任意プロパティ読み出し
    if (value === undefined || value === null) continue;
    const entry = claimsParameter?.userinfo?.[claimName] ?? null;
    if (!matchesRequestedValue(value, entry)) continue;
    result[claimName] = value;                          // ← :493 そのままレスポンスへ
  }
  return result as UserInfoResponse;
}
```

要点:

- `Object.keys(...) as (keyof UserClaims)[]` は **TypeScript の型アサーションであり実行時検査は伴わない**。
  実際には任意の文字列が入る。
- `userClaims[claimName]` は **`hasOwnProperty` 検査を経ていない**ため、
  `userClaims` のプロトタイプチェーン上のプロパティも読める。
- ID Token 側は `filterClaimsByScope` しか通らない（`token-response.ts:453-455`）ため、
  この経路は **UserInfo レスポンスに限定**される。`claims.id_token` 経由の個別クレームは
  `tasks/p2-claims-id-token-member-individual-claims.md` の対象であり、本ファイルの範囲外だが、
  実装時に同じ構造をコピーしないよう注意が必要。

### 4.3 `UserClaims` 型は防御になっていない

`UserClaims`（:111-136）はインデックスシグネチャを持たない閉じた interface である。
しかし TypeScript の構造的部分型では、**変数経由で渡す限り余剰プロパティは検査されない**。
`findUserClaims` の実装が

```ts
async findUserClaims(sub: string) {
  const row = await db.selectUser(sub);   // { sub, name, email, password_hash, internal_role, ... }
  return row;                             // 変数経由なので余剰プロパティエラーにならない
}
```

と書けば、実行時の `userClaims` には型に無いフィールドが乗る。
`claims={"userinfo":{"password_hash":null}}` を送れば、そのフィールドが UserInfo レスポンスに現れる。

**「型で塞がれている」という誤解が生じやすい構造**であることが、本トピックの本質的な危険性である。

### 4.4 プロトタイプチェーン読み出しの実害範囲（過大評価しないための切り分け）

`claimName` に `constructor` / `toString` / `valueOf` などを指定すると、
`userClaims[claimName]` は `Object.prototype` 由来の**関数**を返す。
これは `result[claimName]` に代入されるが、`JSON.stringify` は関数値を持つプロパティを出力しないため、
**JSON レスポンスとしては現れない**。`__proto__` を指定した場合も、
`result['__proto__'] = ...` はプロトタイプ設定として解釈されるため独自プロパティは生えない。

したがってプロトタイプチェーン経路は、
**プレーンオブジェクトを返す resolver に対しては直接の情報漏洩にならない**。
ただし resolver がクラスインスタンスやプロキシ、getter を持つオブジェクトを返す場合は
シリアライズ可能な値が返る可能性があり、`hasOwnProperty` 検査を入れない理由は無い。

実害が確実に成立するのは §4.3 の「resolver が余剰の独自フィールドを返す」経路である。

## 5. 現在の実装との差分

### 満たしていること

- scope 由来のクレーム開示はアロウリスト方式で厳密。
- `sub` は上書き対象外（`applyRequestedClaims` が明示的に `continue`）。
- `value` / `values` の一致判定は深い等価で実装済み。
- ID Token 側には `claims` 由来の任意キーが流れ込まない。

### 不足している可能性があること

- **要求可能なクレーム名の集合が定義されていない**。OP が「開示しうるクレームの語彙」を持っていない。
- `claims.userinfo` のキーに対する **`hasOwnProperty` 検査が無い**。
- Discovery の `claims_supported` が実行時判断に使われておらず、**広告と挙動が独立**している
  （広告に無いクレームも返る）。

### セキュリティ上、改善した方がよいこと

- resolver の戻り値が「そのまま外に出る可能性のある面」であることが、`UserClaimsResolver` の
  JSDoc にも `study-material/resolver-and-store-contract.md` にも書かれていない。
  最低限、**契約として明文化**する必要がある（実装を変えない場合でも必須）。

### 相互運用性の観点

- アロウリストを導入すると「OP が知らないクレームは返らない」ことになるが、
  §5.5.1 が「返せない場合もエラーにしてはならない」と定めているため、**相互運用性は損なわれない**。
  RP は元々「要求しても返らないことがある」前提で実装する義務がある。

### Basic OP として提供する上で確認すべきこと

- Basic OP 認定は `claims` パラメータの網羅的な検査を行わない（`claims_parameter_supported` の広告整合は
  `study-material/done/discovery-claims-feature-advertisement.md` の範囲）。**認定ブロッカーではない**。
- ただしアロウリストを厳しくしすぎて `profile` / `email` / `address` / `phone` の標準クレームが
  `claims` 経由で取れなくなると、`claims` 対応を謳う意味が失われる。既定の語彙は §5.1 の標準クレームを含めること。

## 6. 改善・追加を検討する理由

- **「安全な既定」が OSS の価値**: 利用者は `findUserClaims` を自分で書く。
  DB 行をそのまま返すのは PoC で最も自然な書き方であり、それが即座に情報漏洩になる設計は
  「セキュリティ最優先・利用者が使いやすい」という方針と両立しない。
- **型が守っていると誤解される**: `UserClaims` という閉じた interface と
  `as (keyof UserClaims)[]` というキャストが並んでいるため、コードを読むと守られているように見える。
  実際には両方とも実行時の防御ではない。この種の「見た目の安全性」は最も危険な部類。
- **修正が小さく、既存構造に素直に接続する**: `SCOPE_CLAIMS_MAP` から導出した既定語彙を作り、
  `applyRequestedClaims` にアロウリストを渡すだけで成立する。core の公開 API を壊さない形（optional 引数）で入れられる。
- **他トピックの前提条件になる**: 同意境界（同意画面に何を表示するか）も、カスタムクレーム拡張（何を語彙に加えるか）も、
  「語彙の定義」が無いと設計できない。本トピックはその土台。
- **実装しない場合に残るリスク**: 利用者側の実装次第で任意の内部フィールドが露出する経路が残り、
  その危険性がドキュメントにも型にも現れない。

## 7. 実装方針の候補

### 方針 A：既定語彙 ＝ `SCOPE_CLAIMS_MAP` の全クレーム ＋ `sub` でアロウリスト

`applyRequestedClaims` に `allowedClaimNames?: ReadonlySet<string>` を追加し、
未指定時は `SCOPE_CLAIMS_MAP` の全値 ＋ `sub` を既定とする。

- 利点: 追加設定なしで安全側になる。標準クレームは従来どおり `claims` 経由で取れるため、既存の適合テストは通る。
- 欠点: 非標準クレームを `claims` で要求する運用が既定でできなくなる（拡張性ファイルの方針決定と衝突しうる）。

### 方針 B：`hasOwnProperty` 検査のみを追加（最小変更）

`Object.prototype.hasOwnProperty.call(userClaims, claimName)` を条件に加える。

- 利点: 変更が 1 行。プロトタイプチェーン経路を塞ぐ。
- 欠点: §4.3 の「resolver が余剰フィールドを返す」経路（実害が確実に成立する方）は**塞げない**。
  単独では不十分で、方針 A の補助として位置づけるべき。

### 方針 C：語彙を注入可能にする（拡張性ファイルと統合）

`UserInfoRequestContext` に `supportedClaims?: readonly string[]` を追加し、
利用者が Discovery の `claims_supported` と同じ配列を渡す設計にする。

- 利点: 広告（`claims_supported`）と挙動が 1 つの真実の情報源に揃う。
  `study-material/userinfo-custom-claims-and-scope-claim-mapping-extensibility.md` の方針決定と同時に解決できる。
- 欠点: 利用者が渡し忘れたときの既定挙動を別途決める必要がある（渡し忘れ＝無制限、では意味が無い）。

### 方針 D：契約の明文化のみ（実装は変更しない）

`UserClaimsResolver` の JSDoc と `study-material/resolver-and-store-contract.md` に
「`findUserClaims` の戻り値は `claims` パラメータ経由で任意のフィールドが開示されうる面である。
標準クレーム以外を含めてはならない」と明記し、`conformance.test.ts` でその契約を固定する。

- 利点: 挙動変更ゼロ。拡張性の方針が決まるまでの暫定策として有効。
- 欠点: 利用者が読まなければ意味が無い。OSS の既定としては弱い。

**判断材料**: 方針 A ＋ B の組み合わせが最小の労力で実害を塞ぐ。
方針 C は拡張性トピックの結論待ちだが、A の `allowedClaimNames` を optional 引数として先に用意しておけば、
C はその引数へ値を渡すだけで到達できる（A は C の下位互換になる）。方針 D は単独では採らず、
いずれの方針でも契約明文化は併せて行うのが望ましい。最終判断は人間が行う。

## 8. タスク案

- [ ] `applyRequestedClaims` に `hasOwnProperty` 検査を追加し、プロトタイプチェーン由来のプロパティを読まないようにする
- [ ] 「要求可能なクレーム名」のアロウリストを `applyRequestedClaims` に導入する（既定は `SCOPE_CLAIMS_MAP` の全クレーム ＋ `sub`）
- [ ] アロウリストを optional 引数として設計し、将来 `claims_supported` を注入できる形にしておく（拡張性トピックへの接続点）
- [ ] `userinfo.test.ts` に以下のケースを追加し、期待値を一意に固定する
      - `claims.userinfo` に標準クレーム名を指定 → 返る
      - `claims.userinfo` に `userClaims` に存在する非標準フィールド名を指定 → **返らない**
      - `claims.userinfo` に `constructor` / `toString` / `__proto__` を指定 → レスポンスに現れない
      - アロウリストを明示指定したとき、その集合外のクレームが返らない
- [ ] `UserClaimsResolver.findUserClaims` の JSDoc に「戻り値は外部開示されうる面である」旨の契約を追記する
- [ ] `study-material/resolver-and-store-contract.md` に同契約を追記する
- [ ] 挙動変更が生成 OP に及ぶため、`packages/cli` のテンプレートと各 sample の `conformance.test.ts` を更新する
- [ ] `study-material/userinfo-custom-claims-and-scope-claim-mapping-extensibility.md` と
      `study-material/claims-parameter-consent-authorization-boundary.md` に、本トピックが前提条件である旨の相互参照を追記する
