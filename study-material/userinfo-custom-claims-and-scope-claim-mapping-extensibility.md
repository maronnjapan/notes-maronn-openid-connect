# 非標準（カスタム）クレームとスコープ→クレーム写像の拡張性

## ステータス

🟡 Major（拡張性・利用者体験）/ 未着手（方針 A〜D の選択が未決）

本体（写像の注入可能化）は設計判断待ちのため未タスク化。
ただし §5 で判明した「条件付き代入クレームの spoof 経路」は、
拡張の**前提条件**かつ方針選択と独立に価値があるため先行してタスク化した:

- `tasks/p2-id-token-reserved-claim-denylist.md`

## 1. このトピックで確認したいこと

本リポジトリの UserInfo / ID Token は、**OIDC Core 1.0 §5.1 の標準クレームしか運べない**構造になっている。

- `UserClaims` はインデックスシグネチャを持たない**閉じた interface**
- `SCOPE_CLAIMS_MAP` は `Record<string, (keyof UserClaims)[]>` の**モジュールレベル定数**で、注入・拡張の口が無い
- `filterClaimsByScope` は `SCOPE_CLAIMS_MAP` に載っているクレームだけをコピーする

その結果、PoC 開発者が現実に必要とする `roles` / `groups` / `tenant_id` / `department` のような
**非標準クレームを、UserInfo にも ID Token にも載せられない**。

本ファイルでは以下を確認・整理する。

- 非標準クレームを OP が返すことは仕様上許されるのか（許される場合、どの制約下か）
- 現状の型・実装で何が塞がれているのか（TypeScript 上の制約か、実行時の制約か）
- 利用者が今取り得る回避策と、その回避策が不十分な理由
- カスタムスコープ（例: `roles`）→ カスタムクレームの写像をどう注入させるか

### 既存ファイルとの差分（重複回避）

本トピックは「**どんなクレームを運べるか（クレーム語彙の拡張性）**」に絞る。
以下は別論点として既存ファイルが扱っているため、仕様説明を繰り返さない。

- `claims` パラメータの consent / 認可境界（scope を迂回して claims で取得できてしまう問題）:
  `study-material/claims-parameter-consent-authorization-boundary.md`
- `claims` パラメータで**要求できるクレーム名の集合**（アロウリスト）が定義されていない問題:
  `study-material/done/claims-parameter-claim-name-allowlist.md`、`tasks/p1-claims-parameter-claim-name-allowlist.md`
  → 本ファイルが扱う「語彙を**広げる**」判断の前提として、「語彙を**定義する**」側を先に固定する必要がある
- `claims` パラメータの `value` / `values` / `essential` の判定規則:
  `study-material/done/claims-parameter-value-values-essential.md`
- `claims.id_token` メンバーを ID Token に反映する経路:
  `study-material/done/claims-id-token-member-individual-claims-in-id-token.md`
- 未知 **scope** そのものの検証方針（`invalid_scope` / 無視 / 素通り）:
  `study-material/scope-handling-validation-and-granted-scope.md`
  → 本ファイルは「未知 scope をどう扱うか」ではなく「**受理した scope から
  どのクレームを引けるようにするか**」という写像側の話に限定する。
- Aggregated / Distributed Claims（`_claim_names` / `_claim_sources`）:
  `study-material/distributed-aggregated-claims.md`
  → 本ファイルは Normal Claims の語彙拡張のみを扱う。
- `claim_types_supported` の広告: `study-material/done/discovery-claim-types-supported.md`
- `sub` の一意性・文字種: `study-material/done/userinfo-sub-consistency-enforcement.md` /
  `study-material/done/sub-ascii-charset-enforcement.md`

## 2. 関連する仕様・基準（このトピック固有の差分）

### 2.1 OIDC Core 1.0 §5.1 — 標準クレームは「閉じた集合」ではない

§5.1 は Standard Claims の一覧を定義したうえで、次のように**追加クレームを明示的に許容**している。

> This specification defines a set of standard Claims. (中略)
> Additional Claims MAY be used, and this specification defines a mechanism
> (中略) OpenID Providers MAY choose to define additional Claims.

つまり `roles` のような非標準クレームを UserInfo Response / ID Token に含めることは**仕様違反ではない**。
§5.1.2 は「衝突耐性のあるクレーム名（Collision-Resistant Name、例: URI 形式や
ドメイン修飾された名前）」を使うことを追加クレームに対して規定しており、
非標準クレームを足すこと自体は仕様が想定済みの拡張ポイントである。

### 2.2 OIDC Core 1.0 §5.4 — scope とクレームの写像は「標準スコープの下限」を定めるもの

§5.4 は `profile` / `email` / `address` / `phone` の各スコープが要求するクレーム集合を定義する。
これは「これらのスコープが来たら**少なくともこれらのクレームを返す**」という規定であって、
「**これ以外のスコープが存在してはならない**」とは規定していない。§5.4 は続けて次を認めている。

> The Claims requested by the profile, email, address, and phone scope values
> are returned from the UserInfo Endpoint (中略).
> It is also possible to request Claims by using the claims request parameter.

したがって OP が独自スコープ（例: `roles`）を定義し、それに独自クレームを対応づけることは
§5.4 の範囲外＝**OP の裁量**であり、禁止されていない。

### 2.3 OIDC Core 1.0 §5.5 — `claims` パラメータのクレーム名は標準クレームに限定されない

§5.5 の `claims` パラメータは `userinfo` / `id_token` の各メンバーに**任意のクレーム名**を
キーとして並べられる構造として定義されている。標準クレームだけに限定する規定は無い。

> The Claims defined in Section 5.1 can be requested to be returned (中略).
> Other Claims MAY be requested (後略)

### 2.4 Discovery 1.0 §3 — `claims_supported` / `scopes_supported` との整合

`claims_supported` は OP が返しうるクレーム名の一覧、`scopes_supported` はサポートする
スコープ一覧を広告する。非標準クレーム／独自スコープを実装するなら、これらの広告値にも
含めて整合させる必要がある（広告値そのものの設計は
`study-material/discovery-optional-metadata-fields.md` および `tasks/T-021-discovery-metadata.md` を参照）。

### 事実と判断の区別

- **事実**: OIDC Core §5.1 / §5.4 / §5.5 は非標準クレーム・非標準スコープを禁止していない。
  §5.1.2 は追加クレームに衝突耐性のある名前を推奨（Collision-Resistant Name）している。
- **事実**: 現在の実装は `UserClaims` / `SCOPE_CLAIMS_MAP` により、非標準クレームを
  UserInfo / ID Token のどちらにも載せられない（§4 で実装を確認）。
- **判断**: Basic OP の**必須要件ではない**。Basic OP 認定は標準クレームの取り回しのみを見る。
  ただし本リポジトリのコンセプト（PoC 開発者が自分の要件を検証するブリッジ）に照らすと、
  「`roles` を ID Token に載せて RS 側の認可を試す」は最も頻出の検証シナリオであり、
  それができないことは製品価値に直結する。

## 3. 参照資料

- OpenID Connect Core 1.0 §5.1 Standard Claims（Additional Claims MAY be used の規定）:
  https://openid.net/specs/openid-connect-core-1_0.html#StandardClaims
- OpenID Connect Core 1.0 §5.1.2 Additional Claims（Collision-Resistant Name の規定）:
  https://openid.net/specs/openid-connect-core-1_0.html#AdditionalClaims
- OpenID Connect Core 1.0 §5.4 Requesting Claims using Scope Values:
  https://openid.net/specs/openid-connect-core-1_0.html#ScopeClaims
- OpenID Connect Core 1.0 §5.5 Requesting Claims using the "claims" Request Parameter:
  https://openid.net/specs/openid-connect-core-1_0.html#ClaimsParameter
- OpenID Connect Discovery 1.0 §3 ProviderMetadata（`claims_supported` / `scopes_supported`）:
  https://openid.net/specs/openid-connect-discovery-1_0.html#ProviderMetadata
- RFC 9068 §2.2.3.1（JWT access token における独自クレーム／`roles` `groups` `entitlements` の扱い）:
  https://www.rfc-editor.org/rfc/rfc9068#section-2.2.3.1

> ⚠️ 注記: 本調査環境からは openid.net / rfc-editor.org への直接フェッチが遮断されていたため、
> §2 の逐語引用は記載者の知識に基づく。逐語表現の最終確認は §9 のタスクに含めた。
> 引用の**趣旨**（追加クレームが許容されること、§5.4 が標準スコープの写像のみを定めること）は
> 複数箇所で一貫しており、事実として扱ってよい確度が高い。

## 4. 現在の実装確認

### 4.1 クレーム語彙の定義（閉じた interface）

`packages/core/src/userinfo.ts:111-136`

```ts
export interface UserClaims {
  sub: string;
  // profile scope - OIDC Core 1.0 Section 5.4
  name?: string;
  // ... 標準クレームのみ ...
  phone_number_verified?: boolean;
}
```

- **インデックスシグネチャ（`[key: string]: unknown`）が無い**。
- `UserClaimsResolver.findUserClaims(sub): Promise<UserClaims | null>`
  （`packages/core/src/userinfo.ts:141-143`）の戻り値型がこれなので、
  利用者が `roles` を含むオブジェクトリテラルを返すと TypeScript の
  excess property check でコンパイルエラーになる。

### 4.2 scope → クレーム写像（モジュール定数、注入不可）

`packages/core/src/userinfo.ts:203-223`

```ts
export const SCOPE_CLAIMS_MAP: Record<string, (keyof UserClaims)[]> = {
  profile: ['name', 'family_name', /* ... */ 'updated_at'],
  email: ['email', 'email_verified'],
  address: ['address'],
  phone: ['phone_number', 'phone_number_verified'],
};
```

- 値の型が `(keyof UserClaims)[]` なので、非標準クレーム名を書けない。
- `filterClaimsByScope` はこの定数を直接参照し（引数で受け取らない）、
  写像を差し替える口が無い。

### 4.3 フィルタ本体

`packages/core/src/userinfo.ts:232-252`

```ts
export function filterClaimsByScope(userClaims: UserClaims, scopes: string[]): UserInfoResponse {
  const result: Record<string, unknown> = { sub: userClaims.sub };
  for (const scope of scopes) {
    const claimNames = SCOPE_CLAIMS_MAP[scope];
    if (!claimNames) continue;              // ← 未知スコープは黙って読み飛ばす
    for (const claimName of claimNames) {
      const value = userClaims[claimName];
      if (value !== undefined && value !== null) result[claimName] = value;
    }
  }
  return result as UserInfoResponse;
}
```

- **allowlist 方式**。`SCOPE_CLAIMS_MAP` に載っていないクレームは、
  たとえ `userClaims` に実行時に存在していても**出力に現れない**。
- 未知スコープ（`roles` など）は `continue` で黙って捨てられる。

### 4.4 `claims` パラメータ経路も同じ制約を受ける

`packages/core/src/userinfo.ts:257-262`

```ts
function getRequestedClaimNames(claimsParameter?: ClaimsParameter): (keyof UserClaims)[] {
  if (!claimsParameter?.userinfo) return [];
  return Object.keys(claimsParameter.userinfo) as (keyof UserClaims)[];
}
```

- `Object.keys()` の結果を `keyof UserClaims` へ**アサーション**している。
- `applyRequestedClaims`（`packages/core/src/userinfo.ts:477-497`）は
  `userClaims[claimName]` を引くため、**実行時には** resolver が返した非標準クレームを
  そのまま返せてしまう。つまり claims パラメータ経路だけは「型で塞がれているが実行時は通る」
  という**型と挙動の乖離**がある。

### 4.5 ID Token 側も同じ関数を通る

`packages/core/src/token-response.ts:428-430`

```ts
if (userClaims) {
  Object.assign(payload, filterClaimsByScope(userClaims, scope));
}
```

- ID Token へのユーザークレーム反映も `filterClaimsByScope` 経由なので、
  UserInfo と**まったく同じ制約**を受ける。

### 4.6 公開 API としての露出

`packages/core/src/index.ts` は `SCOPE_CLAIMS_MAP` を**値として** export している（195 行目）。
型は `Record<string, (keyof UserClaims)[]>` で `readonly` でも `as const` でもないため、
実行時には `SCOPE_CLAIMS_MAP['roles'] = ['roles' as never]` のような**モジュール定数の
破壊的ミューテーション**が技術的には可能。ただしこれは共有ミュータブル状態の書き換えであり、
テスト間・テナント間で汚染するため回避策として推奨できる形ではない（§6 で詳述）。

## 5. 現在の実装との差分

### 満たしていること

- 🟢 OIDC Core §5.4 の標準スコープ→標準クレーム写像は**正確に実装されている**
  （`profile` の 14 クレーム、`email` / `address` / `phone` すべて）。
- 🟢 allowlist 方式なので、resolver が余計なクレームを返しても**scope 外に漏れない**
  という安全側の性質は満たしている。これは意図的な設計として維持したい性質。
- 🟢 `sub` は常にレスポンス先頭で固定され、ユーザークレーム由来の値で上書きされない。

### 不足している可能性があること

- 🟡 **非標準クレームを返す経路が無い（scope 経由）**: `roles` / `groups` /
  `tenant_id` のような、PoC で最も検証したいクレームを UserInfo にも ID Token にも載せられない。
  OIDC Core §5.1 が明示的に許容している拡張が、実装側で塞がれている。
- 🟡 **カスタムスコープを定義できない**: `SCOPE_CLAIMS_MAP` が注入不可のため、
  `roles` スコープを定義して `roles` クレームに写像する、という OP 設計を表現できない。
- 🟡 **`UserClaimsResolver` の型が拡張を拒否する**: 利用者は自前の DB から
  `roles` を引いてきても、`UserClaims` に代入できない（excess property check）。
  型アサーションで押し込んでも §4.3 のフィルタで落ちる。

### 実装はあるが仕様上の確認が必要なこと

- 🟡 **`claims` パラメータ経路の型と挙動の乖離**（§4.4）: 型では非標準クレームを
  要求できないことになっているが、実行時には resolver が返せば素通りする。
  「claims 経由なら通る／scope 経由なら通らない」という非対称は、意図した設計なのか
  型アサーションの副作用なのかが実装から読み取れない。どちらであれ**テストで固定されていない**。
- 🟢 **`sub` を追加クレームで上書きできないこと**は既に担保されている
  （`applyRequestedClaims` の `if (claimName === 'sub') continue;`、
  `filterClaimsByScope` の `result` 初期値）。拡張時もこの不変条件を壊さないこと。

### セキュリティ上、改善した方がよいこと

- 🔴 **拡張時に allowlist 性を壊さないこと**が最重要。
  「`UserClaims` にインデックスシグネチャを足すだけ」で済ませると、
  resolver が返した**すべての**プロパティが scope 無視で漏れる実装に退行しうる。
  拡張しても「scope（または claims パラメータ）で明示的に許可されたクレームだけを返す」
  という現在の性質を維持する設計にすること。
- 🔴 **プロトコルクレームの spoof は「無条件代入」と「条件付き代入」で保護強度が違う**。
  `buildIdTokenPayload`（`packages/core/src/token-response.ts:423-462`）は
  ユーザークレームを先に `Object.assign` してから protocol クレームを代入するが、
  代入の仕方が 2 種類ある。

  ```ts
  if (userClaims) Object.assign(payload, filterClaimsByScope(userClaims, scope));

  payload.iss = issuer;          // 無条件代入 → 常に上書きされる（保護される）
  payload.sub = subject;         // 無条件
  payload.aud = aud;             // 無条件
  payload.exp = issuedAt + expiresIn;  // 無条件
  payload.iat = issuedAt;        // 無条件
  if (atHash !== undefined)   payload.at_hash = atHash;      // ← 条件付き
  if (nonce !== undefined)    payload.nonce = nonce;         // ← 条件付き
  if (authTime !== undefined) payload.auth_time = authTime;  // ← 条件付き
  if (acr !== undefined)      payload.acr = acr;             // ← 条件付き
  if (amr !== undefined)      payload.amr = amr;             // ← 条件付き
  ```

  条件付きの 5 つ（`at_hash` / `nonce` / `auth_time` / `acr` / `amr`）は、
  **OP 側がその値を持たないとき（`undefined`）に上書きが起きない**。
  今日はカスタムクレームを載せる経路が存在しないため到達不能だが、
  本トピックの拡張を入れた瞬間に**実在の注入経路になる**。

  具体的には、`acr` を返すカスタム写像を利用者が定義し、かつ `acrResolver` を
  設定していない構成では、resolver が返した任意の `acr` 値が
  そのまま ID Token の `acr` として出力される。RP が `acr` を認可判断に使っていれば
  **認証強度の詐称**が成立する。`amr` / `auth_time` も同様。

  したがって「拡張と同時に denylist を入れる」のは望ましいだけでなく、
  **拡張の前提条件**として扱うべき。

- 🟡 **既存テストは `sub` しか固定していない**。
  `packages/core/src/token-response.test.ts:813-825`
  （`should not let user claims override required ID Token claims`）は
  `sub` の上書き防止のみを検証しており、条件付き代入の 5 クレームは対象外。
  拡張前に回帰テストの範囲を広げる必要がある。
- 🟡 **PII の露出範囲**: 非標準クレームは往々にして内部識別子（`tenant_id`, 社員番号など）。
  scope に紐づけずに常時返す設計にすると、最小権限の原則から外れる。

### 相互運用性の観点で改善した方がよいこと

- 🟡 **`claims_supported` / `scopes_supported` との整合**: 独自クレーム／独自スコープを
  実装するなら Discovery の広告値にも出せる必要がある。広告できないと、
  クライアントライブラリの自動構成が独自スコープを「未サポート」と判断しうる。
- 🟢 **Collision-Resistant Name の案内**（§5.1.2）: 利用者が `roles` のような短い名前を
  使うと、将来 OIDC が同名の標準クレームを定義した際に衝突する。
  URI 形式（`https://example.com/claims/roles`）を推奨する案内をどこかに置きたい。

### Basic OP として提供する上で確認すべきこと

- 🟢 **Basic OP 認定には影響しない**。Basic OP のテストは標準クレームのみを対象とし、
  追加クレームの有無は判定に含まれない。
- 🟡 ただし拡張の入れ方によっては**既存の conformance 挙動を壊しうる**
  （例: 常時全クレームを返す実装に退行すると `oidcc-scope-*` 系のテストが落ちる）。
  拡張時は各 sample の `conformance.test.ts` で「scope 外クレームが返らないこと」を
  改めて固定する必要がある。

## 6. 改善・追加を検討する理由

### なぜこの機能を入れる価値があるのか

本リポジトリのコンセプトは「自分の要件がこの仕様で実現できるかを素早く検証するためのブリッジ」。
PoC で最も頻出する検証シナリオのひとつが、

> 「ID Token / アクセストークンに `roles` を載せて、リソースサーバ側で
>  ロールベース認可が成立するかを確認したい」

である。現状これができないため、利用者は次のいずれかに追い込まれる。

1. `packages/core` を fork して `UserClaims` を書き換える（アップグレード経路を失う）
2. 生成コードの UserInfo ルートを書き換え、`filterClaimsByScope` の戻り値に手で足す
   （core のフィルタを迂回するので、scope による絞り込みが効かなくなる）
3. `SCOPE_CLAIMS_MAP` をモジュールレベルで破壊的に書き換える（共有状態の汚染）
4. 標準クレーム（`profile` など）に無理やり詰め込む（意味論が壊れる）

いずれも「Portability（どこでも動く）」「利用者が生成コードを改造しながら検証する」という
本リポジトリの前提と噛み合わない。特に 2 は、
`study-material/claims-parameter-consent-authorization-boundary.md` が問題視している
「scope による絞り込みが後段で無効化される」構造を利用者の手で再生産することになる。

### Basic OP として必要なのか、それとも拡張機能として有用なのか

- **Basic OP としては不要**。認定要件に含まれない。
- **拡張機能として非常に有用**。かつ「拡張性」は本リポジトリの差別化 3 軸のうち
  Portability / Speed を支える土台であり、コンセプト文書が掲げる
  「core はロジック層（高度な組み込みユースケース向け）」という位置づけとも合致する。

### 現在のリポジトリ構成から見て、なぜ導入しやすい／しにくいか

- 🟢 **導入しやすい理由**: core は既に「ポリシーを注入する」設計パターンを多数持っている
  （`AcrResolver`、`OfflineAccessGrantedCallback`、`AccessTokenIssuer`、`SigningKeyProvider`）。
  scope→クレーム写像も同じパターンに素直に乗る。
- 🟡 **注意が要る理由**: `filterClaimsByScope` は UserInfo と ID Token の**両方**から
  呼ばれる共有関数であり、CLI が生成する 4 フレームワーク分のテンプレートからも呼ばれる。
  シグネチャを変える場合は後方互換（オプション引数）で入れないと破壊的変更になる。

### 既存実装とどのように接続できそうか

- `filterClaimsByScope(userClaims, scopes)` に**第 3 引数（省略可）**で写像を渡せるようにすれば、
  既存の全呼び出し箇所は無変更で動く。
- 生成コードの UserInfo / Token ルートは既に `filterClaimsByScope` を明示的に呼んでいるため、
  利用者は「その 1 行に自分の写像を足す」だけでカスタムクレームを有効化できる。
  これは CLI 生成コードの「ステップ関数を並べて利用者が改造する」思想とそのまま一致する。

### 利用者・開発者・運用者にどのようなメリットがあるか

- **利用者（PoC 開発者）**: fork なしで `roles` / `groups` を検証できる。
  RS 側の認可設計まで含めた End-to-End の検証が本リポジトリだけで完結する。
- **開発者（本リポジトリ）**: 「カスタムクレームを足したい」という頻出要望に対して、
  core の改修ではなく**設定で答えられる**ようになる。
- **運用者**: allowlist 性が維持されるので、resolver に余計なカラムが増えても
  勝手に外部へ漏れない、という安全性を保ったまま拡張できる。

### 実装しない場合にどのような制約やリスクが残るか

- 「OIDC を検証するツール」を名乗りながら、OIDC が明示的に許容する拡張
  （§5.1 Additional Claims）を試せない、という機能上の欠落が残る。
- 利用者が回避策 2（生成コードでフィルタを迂回）を選ぶと、
  scope による最小権限が壊れた OP が「本リポジトリで作った OP」として本番に近づく。
  これはセキュリティ上の実害になりうる。
- 型（`UserClaims`）と実行時挙動（claims パラメータ経路は通る）の乖離が残り続け、
  利用者が「なぜか claims パラメータ経由だけ動く」という再現しにくい挙動に遭遇する。

## 7. 実装方針の候補

> 最終判断は人間が行う。ここでは判断材料の整理に徹する。

### 方針A（写像を注入可能にする）— core の既存パターンに最も忠実

- `filterClaimsByScope(userClaims, scopes, scopeClaimsMap?)` の第 3 引数を追加。
  省略時は現行の `SCOPE_CLAIMS_MAP` を使う（完全な後方互換）。
- `UserClaims` に `[key: string]: unknown` を追加、または
  `type ExtendedUserClaims = UserClaims & Record<string, unknown>` を新設。
- 写像に載ったクレームだけを返す **allowlist 性は維持**される。
- 生成コードは `filterClaimsByScope(userClaims, tokenInfo.scope, MY_SCOPE_CLAIMS)` の形になる。
- メリット: 既存呼び出しを壊さない。allowlist 性が保たれる。注入パターンが core 全体と揃う。
- 注意: 写像を UserInfo ルートと Token ルートの**2 箇所**に渡す必要があり、
  片方だけ渡すと ID Token と UserInfo でクレームが食い違う。
  → 生成コードでは写像を `config.ts` の 1 箇所に置き、両ルートが import する形にすると防げる。

### 方針B（`ClaimsPolicy` オブジェクトとして注入）

- 写像だけでなく「予約クレーム名の denylist」「Collision-Resistant Name の検証」なども
  まとめた `ClaimsPolicy` を定義し、`filterClaimsByScope` に渡す。
- メリット: §5 で挙げたプロトコルクレーム spoof 防止を型で表現できる。
- 注意: 方針 A より API 面が大きくなる。v0.x の API 安定性方針
  （`study-material/RELEASE-v0.x-scope.md`）との兼ね合いを確認する必要がある。

### 方針C（resolver 側で完結させる）

- `UserClaimsResolver` を「scope を受け取ってフィルタ済みクレームを返す」責務に変え、
  core は写像を持たない。
- メリット: core が最小になる。
- 注意: **標準スコープ（§5.4）の写像まで利用者責務になる**ため、
  §5.4 準拠が利用者実装の品質に依存する。Fidelity を掲げる本リポジトリの方針と逆行し、
  Basic OP conformance の再現性も落ちるため推奨しにくい。

### 方針D（現状維持＋ドキュメント化）

- 「core は標準クレームのみを扱う。非標準クレームは利用者が生成コードで足す」と明記する。
- メリット: 実装変更ゼロ。
- 注意: 利用者が回避策 2 を取ることを追認する形になり、
  scope による絞り込みが壊れた OP を生みやすい。§6 のリスクがそのまま残る。

### 判断材料

- 方針 A は既存の注入パターン（`AcrResolver` / `AccessTokenIssuer` 等）と同型で、
  学習コストがほぼゼロ。後方互換も自然に保てる。**最有力**。
- 方針 B は安全性の表現力が高いが、v0.x の API 面を広げる判断が要る。
  方針 A で入れて、denylist が必要と分かった時点で B へ発展させる段階的導入も可能。
- 「Collision-Resistant Name を推奨するか、強制するか」は別の設計判断。
  PoC 用途では短い名前（`roles`）を使いたい需要が強いため、
  **推奨（ドキュメント／コメント）に留め、強制はしない**のが現実的と思われるが、人間が判断する。
- 独自スコープを定義する場合、`scopes_supported` / `claims_supported` の広告も
  同時に整合させる必要がある（`tasks/T-021-discovery-metadata.md` と歩調を合わせる）。

## 8. 未確認・不明点

- OIDF の Basic OP テストプランが「広告外クレームが返らないこと」を検証するかは未確認。
  （§5.4 の標準スコープ写像は検証対象だが、追加クレームの扱いは規定されていないと思われる）
- `SCOPE_CLAIMS_MAP` を実行時にミューテートしている利用者が既にいるかは不明。
  もし公開 API として意図的にミュータブルにしていたのであれば、
  方針 A への移行時に非推奨化の告知が要る（`RELEASE.md` の方針を確認すること）。

## 9. タスク案

- [ ] OIDC Core §5.1 / §5.1.2 / §5.4 / §5.5 の逐語を一次資料で確認し、本ファイルの引用を確定する
- [ ] 方針 A / B / C / D のいずれを採るかを人間が判断する
- [ ] 方針 A（または B）採用時の実装:
  - [ ] `filterClaimsByScope` に省略可能な写像引数を追加する（既存呼び出しは無変更で通ること）
  - [ ] 非標準クレームを表現できる型（`UserClaims` のインデックスシグネチャ、または派生型）を定義する
  - [ ] `getRequestedClaimNames` の `as (keyof UserClaims)[]` アサーションを解消し、
        型と実行時挙動の乖離（§4.4）を閉じる
  - [ ] 予約クレーム名の denylist を実装する。特に**条件付き代入の 5 クレーム**
        （`at_hash` / `nonce` / `auth_time` / `acr` / `amr`）は §5 のとおり
        OP 側が値を持たないときに上書きされないため、拡張の前提条件として先に塞ぐ
        → `tasks/p2-id-token-reserved-claim-denylist.md` として切り出し済み
  - [ ] CLI テンプレート（4 フレームワーク分）で写像を `config.ts` に 1 箇所定義し、
        UserInfo ルートと Token ルートの両方から参照させる
  - [ ] `packages/cli` のテンプレートを更新し、各 sample の `conformance.test.ts` を再生成する
- [ ] テスト要件（TDD で先に Red を作る）:
  - [ ] `should return a custom claim when a custom scope maps to it`
  - [ ] `should not return a custom claim when its scope is absent`（allowlist 性の固定）
  - [ ] `should not allow user claims to overwrite the iss claim in an ID Token`（予約名の保護）
  - [ ] `should keep standard scope-to-claim mapping unchanged when no custom map is provided`（後方互換）
  - [ ] `should return the same custom claims from both UserInfo and the ID Token`（両経路の一致）
  - [ ] 既存の `conformance.test.ts` が「scope 外クレームを返さない」ことを引き続き固定していること
- [ ] Discovery の `scopes_supported` / `claims_supported` に独自値を載せる経路を
      `tasks/T-021-discovery-metadata.md` と整合させる
- [ ] README またはテンプレートのコメントに、追加クレーム名は Collision-Resistant Name
      （§5.1.2）が推奨であることを案内する
- [ ] 完了条件: `pnpm --filter @maronn-openid-connect/core test` および `pnpm --filter @maronn-openid-connect/cli test` がパスすること

## 関連トピック

- `study-material/claims-parameter-consent-authorization-boundary.md`（claims パラメータの認可境界）
- `study-material/scope-handling-validation-and-granted-scope.md`（未知スコープの検証方針）
- `study-material/distributed-aggregated-claims.md`（Normal 以外のクレーム型）
- `study-material/discovery-optional-metadata-fields.md` / `tasks/T-021-discovery-metadata.md`（広告値の整合）
