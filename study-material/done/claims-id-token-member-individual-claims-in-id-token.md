# `claims` パラメータ `id_token` メンバーの個別標準クレームが ID Token に反映されない（OIDC Core §5.4 / §5.5）

## ステータス

🟡 Medium / 未着手

## 1. このトピックで確認したいこと

OIDC Core 1.0 §5.5 の `claims` リクエストパラメータの `id_token` メンバーで **個別の標準クレーム**
（例: `{"id_token":{"email":null,"name":null}}`）を要求したとき、それらのクレームが実際に
**ID Token に含まれて返るか**を確認する。

現状、`claims.id_token` メンバーは `acr` の seed 用途にしか使われておらず、`email` / `name` などの
標準クレームを `id_token` メンバーで要求しても ID Token には現れない。一方 UserInfo エンドポイントは
`userinfo` メンバーを honor して要求クレームを追加している。この **ID Token 側と UserInfo 側の非対称**が
仕様違反かどうか、また相互運用性・利用者体験にどう影響するかを整理する。

### 既存ファイルとの差分（重複を避けるための整理）

- `claims` パラメータの全体像・パース処理・`acr` seed 連携は
  `tasks/done/p0-claims-id-token-support.md` と `study-material/userinfo-endpoint-comprehensive.md` §3.3 で完了済み。
- 個別クレームの `value` / `values` / `essential` の **値制約の解釈**は
  `study-material/done/claims-parameter-value-values-essential.md` と
  `tasks/done/p2-claims-parameter-value-values-enforcement.md` が扱う（ただし **UserInfo 側のみ**）。
- 本ファイルはその隙間、すなわち **「`id_token` メンバーで要求された非 `acr` 標準クレームを ID Token 本体へ載せる」**
  という論点だけを扱う。共通の仕様説明は上記を参照し、ここでは差分に絞る。

## 2. 関連する仕様・基準（このトピック固有の差分）

### 2.1 OIDC Core 1.0 §5.5 — `claims` パラメータの `id_token` トップレベルメンバー

§5.5 は `claims` リクエストパラメータの JSON オブジェクトのトップレベルメンバーを次のように定義する。

- **`userinfo`**: 列挙した個別クレームを **UserInfo Response** で返すことを要求する。
- **`id_token`**: 列挙した個別クレームを **ID Token** で返すことを要求する。

> The top-level members of the Claims request JSON object are:
> **userinfo** — ... Requests that the listed individual Claims be returned from the UserInfo Endpoint. ...
> **id_token** — ... Requests that the listed individual Claims be returned in the ID Token. ...

つまり `id_token` メンバーで要求されたクレームは、**scope に依存せず** ID Token に含めることが期待される。

### 2.2 OIDC Core 1.0 §5.4 — scope 由来クレームの返却先と `claims` パラメータの上書き

§5.4 は `profile` / `email` / `address` / `phone` scope に対応するクレームは、Access Token が発行される
フロー（＝本リポジトリの Authorization Code Flow）では **UserInfo エンドポイントから返す**のが既定だと述べる。
その上で、`claims` パラメータを使うと**返却先（UserInfo か ID Token か）と対象クレームを個別に指定できる**。

- 既定（scope のみ）: `email` などは UserInfo から取得する。ID Token には載らない。
- `claims={"id_token":{"email":null}}`: `email` を **ID Token に載せて返す**ことを明示要求。

この「ID Token に載せる」経路が実装されていないと、`claims_parameter_supported: true` を広告しているのに
`id_token` メンバーの主要ユースケース（UserInfo を叩かずに ID Token だけで必要クレームを得る）が成立しない。

### 2.3 §5.5.1 の値制約との関係

`id_token` メンバーの各クレームには `null` / `{value}` / `{values}` / `{essential}` が付き得る（§5.5.1）。
値制約の解釈自体は `study-material/done/claims-parameter-value-values-essential.md` が確立済みなので、
本ファイルでは **「ID Token に載せるときにも同じ `matchesRequestedValue` を適用する」**という接続だけを扱う。
`essential` が満たせない場合でもエラーにしない（§5.5.1: MUST NOT return an error）方針は UserInfo 側と同一。

## 3. 参照資料

- OpenID Connect Core 1.0, §5.4 "Requesting Claims using Scope Values"
  https://openid.net/specs/openid-connect-core-1_0.html#ScopeClaims
  （scope 由来クレームの返却先と、`claims` パラメータでの個別指定）
- OpenID Connect Core 1.0, §5.5 "Requesting Claims using the claims Request Parameter"
  https://openid.net/specs/openid-connect-core-1_0.html#ClaimsParameter
  （`userinfo` / `id_token` トップレベルメンバーの定義。`id_token` メンバー = ID Token に返す）
- OpenID Connect Core 1.0, §5.5.1 "Individual Claims Requests"
  https://openid.net/specs/openid-connect-core-1_0.html#IndividualClaimsRequests
  （`value` / `values` / `essential`。Essential でも取得不可時にエラーを返してはならない）
- 既存リポジトリ内資料（重複説明を避けるための参照先）:
  - `tasks/done/p0-claims-id-token-support.md`（`claims` の構造対応と `acr` seed）
  - `study-material/done/claims-parameter-value-values-essential.md`（値制約の解釈）
  - `tasks/done/p2-claims-parameter-value-values-enforcement.md`（UserInfo 側の value/values 適用）

## 4. 現在の実装確認

### 4.1 ID Token 生成（`packages/core/src/token-response.ts`）

`generateTokenResponse` の ID Token ペイロード組み立てでは、ユーザクレームは
**scope フィルタ結果だけ**が載る。

```ts
// token-response.ts L355-361
// OIDC Core 1.0 §5.4 / §12: scope に応じてユーザクレームを含める。
if (userClaims) {
  const filtered = filterClaimsByScope(userClaims, scope);
  Object.assign(idTokenPayload, filtered);
}
```

`claims.id_token` メンバーは、`acr` の seed としてのみ参照される。

```ts
// token-response.ts L299-311
// claims.id_token.acr.values is equivalent to requesting these acr values.
let effectiveRequestedAcrValues = requestedAcrValues;
if (effectiveRequestedAcrValues === undefined && claims?.id_token) {
  const acrEntry = claims.id_token['acr'];
  if (acrEntry && Array.isArray(acrEntry.values)) { /* ... acr only ... */ }
}
```

型定義のコメントも「`acr.values` 以外の `id_token` メンバーは無視」と明記している。

```ts
// token-response.ts L120-125（TokenResponseOptions.claims の doc コメント）
// `claims.id_token.acr.values` is fed into the acrResolver ... Unknown id_token
// [members] are ignored.
```

### 4.2 対照: UserInfo 側は `userinfo` メンバーを honor している（`packages/core/src/userinfo.ts`）

UserInfo エンドポイントは、scope フィルタに加えて `claims.userinfo` メンバーで要求されたクレームを
値制約付きで追加している。ID Token 側にはこの対応物が無い。

```ts
// userinfo.ts L423-441（handleUserInfoRequest, step 5）
const response = filterClaimsByScope(userClaims, tokenInfo.scope);
const requestedClaims = getRequestedClaimNames(claimsParameter); // claimsParameter.userinfo のキー
for (const claimName of requestedClaims) {
  if (claimName === 'sub') continue;
  const value = userClaims[claimName];
  if (value === undefined || value === null) continue;
  const entry = claimsParameter?.userinfo?.[claimName] ?? null;
  if (!matchesRequestedValue(value, entry)) continue;
  (response as Record<string, unknown>)[claimName] = value;
}
```

`getRequestedClaimNames` は `claimsParameter.userinfo` のみを読む（`userinfo.ts` L256-262）。
`matchesRequestedValue` / `deepEqual` は ID Token 側でも再利用できる純粋関数として既に存在する。

### 4.3 処理の流れ（要約）

1. 認可リクエストで `parseClaimsRequest` が `claims` を `{ userinfo?, id_token? }` にパースする（`authorization-request.ts`）。
2. トークンエンドポイントで `generateTokenResponse` に `claims` が渡る。
3. ID Token: `filterClaimsByScope` のみ → **`id_token` メンバーの個別クレームは反映されない**（`acr` を除く）。
4. UserInfo: `filterClaimsByScope` + `userinfo` メンバー反映 → 個別クレームが反映される。

## 5. 現在の実装との差分

- **満たしていること**
  - `claims` の構造パース（`userinfo` / `id_token`）は完了（`p0-claims-id-token-support`）。
  - `id_token` メンバーの `acr` 要求は resolver に届く（§5.5.1.1 相当）。
  - UserInfo 側は `userinfo` メンバーの個別クレームを値制約付きで返す。
  - 値制約判定（`matchesRequestedValue` / `deepEqual`）は ID Token 側でも流用可能な形で存在。
- **不足している可能性があること**
  - `claims.id_token` の **非 `acr` 標準クレーム**（`email` / `name` / `email_verified` など）が
    ID Token に載らない。§5.5 の `id_token` メンバー定義（ID Token に返す）を満たしていない。
  - `claims_parameter_supported: true` を広告しているため、**広告と実挙動が一部食い違う**
    （`userinfo` メンバーは効くが `id_token` メンバーは `acr` しか効かない、という非対称）。
- **実装はあるが仕様上の確認が必要なこと**
  - どのクレームを ID Token 経由で許可するか。`sub`/`iss`/`aud`/`exp`/`iat`/`at_hash`/`nonce`/`acr`/`amr`/`azp`
    などの **プロトコルクレームは要求で上書きさせてはならない**（後続代入で上書きされる現構造は spoof 防止に有効）。
    → 個別クレーム反映は「標準ユーザクレーム（profile/email/address/phone 系）」に限定する必要がある。
  - `sub` の値要求は別論点（`study-material/claims-sub-value-request-binding.md` 参照）。本ファイルは
    `sub` 以外の標準クレームの反映に限定する。
- **セキュリティ上、改善した方がよいこと**
  - 反映対象を許可リスト（既知の標準クレーム集合）に限定し、`userClaims` に任意キーがあっても
    プロトコルクレームや未知キーを ID Token に注入できないようにする（claim injection 防止）。
- **相互運用性の観点で改善した方がよいこと**
  - 「UserInfo を叩かずに ID Token だけで必要クレームを得たい」クライアント（SPA / モバイルで往復を減らしたい等）が
    他 IdP と同じ `claims={"id_token":{...}}` を送っても本 OP では動かない、という驚きを解消できる。
- **Basic OP として提供する上で確認すべきこと**
  - Basic OP 認定の **必須ではない**（`claims` パラメータ対応は任意機能）。ただし
    `claims_parameter_supported` を `true` で広告する以上、`id_token` メンバーが部分的にしか効かないのは
    Fidelity（忠実性）シグナルとして弱い。広告を正直にするか、実装を揃えるかの二択になる。

## 6. 改善・追加を検討する理由

- **なぜ価値があるか**: `id_token` メンバーは §5.5 が定義する 2 大経路の片方。UserInfo 側だけ対応して
  ID Token 側が未対応だと、`claims` 対応が「半分」であり、他 IdP からの移行検証（本ライブラリのコンセプト）で
  つまずく典型ポイントになる。
- **Basic OP 必須か拡張か**: 必須ではない。位置づけは **既存の `claims` パラメータ対応の整合性改善（Fidelity 向上）**。
- **導入しやすさ**: 値制約判定（`matchesRequestedValue`）と scope フィルタ（`filterClaimsByScope`）が既にあり、
  UserInfo 側に完成形の実装がある。ID Token 側へ同じロジックを移植する形なので **導入は容易**。
- **既存実装との接続**: `token-response.ts` の `if (userClaims)` ブロック直後に、`claims.id_token` の
  非 `acr` 標準クレームを許可リストで反映する処理を足す。プロトコルクレームの代入は現状どおり後段で上書きされるため
  順序を変えなければ安全。
- **利用者メリット**: 生成された OP が他 IdP と同じ `claims` セマンティクスで動く。UserInfo 往復削減。
- **実装しない場合のリスク**: `claims_parameter_supported: true` と実挙動の乖離が残り、Conformance/相互運用の
  細部でクライアントが誤動作する（要求したクレームが ID Token に無い）。

## 7. 実装方針の候補（最終判断は人間）

> いずれも「反映対象は標準ユーザクレームのみ」「プロトコルクレームは上書き不可」を前提とする。

- **方針 A: ID Token 側でも `id_token` メンバーを honor する（UserInfo 対称化）**
  - `filterClaimsByScope` の後に、`claims.id_token` の各キー（`acr` 等プロトコルクレームを除く）について
    `userClaims` から値を取り、`matchesRequestedValue` を満たすものを `idTokenPayload` に追加。
  - 追加は必ず「プロトコルクレーム代入（iss/sub/aud/exp/iat/at_hash/nonce/acr/amr/azp）」より **前** に行い、
    後段代入で上書きされる現構造を維持する（spoof 防止）。
  - 反映対象は `SCOPE_CLAIMS_MAP` の値域（既知標準クレーム集合）に限定する許可リスト方式を推奨。
- **方針 B: 広告を実挙動に合わせる（消極策）**
  - `claims_parameter_supported` の意味を「`userinfo` メンバーと `id_token.acr` のみ」と割り切り、
    README / discovery コメントに制約を明記。実装は変えない。
  - コスト最小だが Fidelity は上がらない。移行検証ユースケースでの驚きは残る。
- **方針 C: 反映を CLI 生成テンプレート側のフックにする**
  - core は「要求クレーム集合」を返すだけにし、実際にどのクレームを ID Token に載せるかは
    生成 OP 側のポリシー関数に委ねる。柔軟だが利用者に実装責任が移り、既定挙動が薄くなる。

判断材料: 本リポジトリは UserInfo 側で既に core に honor ロジックを持つため、**対称性の観点では方針 A が自然**。
ただし「ID Token を薄く保ちたい」設計思想があるなら方針 B/C もあり得る。ここは設計判断として人間に委ねる。

## 8. タスク案

- [ ] `token-response.ts` に `claims.id_token` の非 `acr` 標準クレーム反映を追加する（方針 A 採用時）
  - 反映は `filterClaimsByScope` 直後・プロトコルクレーム代入前に行う
  - 反映対象を既知標準クレーム許可リスト（`SCOPE_CLAIMS_MAP` 値域）に限定
  - `value` / `values` 制約は `matchesRequestedValue` を再利用（`sub` は除外）
- [ ] プロトコルクレーム（iss/sub/aud/exp/iat/at_hash/nonce/acr/amr/azp）が `claims.id_token` 経由で
      上書き・注入されないことを保証（順序と許可リストで担保）
- [ ] 単体テスト（`packages/core`）:
  - [ ] `claims={"id_token":{"email":null}}` かつ `userClaims.email` あり → ID Token に `email` が載る
  - [ ] `claims={"id_token":{"email":{"value":"a@example.com"}}}` で値不一致 → `email` は載らない（エラーにしない）
  - [ ] `claims={"id_token":{"iss":null}}` 等プロトコルクレーム要求 → 正規の `iss` のまま（注入不可）
  - [ ] `claims={"id_token":{"unknown_claim":null}}` → 無視される（許可リスト外）
  - [ ] `acr` seed の既存挙動が回帰しない
- [ ] discovery / README のコメントを実挙動に合わせて更新（方針 B を併用しない場合は「`id_token` メンバー対応済み」に）
- [ ] `samples/*/conformance.test.ts` を生成する `packages/cli` 側テンプレートを、OP 挙動変更に合わせて更新
      （`conformance.test.ts` は直接編集せず生成元を変更する。CLAUDE.md の方針に従う）
- [ ] 余力があれば `tests/e2e` に「`claims.id_token` で要求したクレームが ID Token に現れる」E2E を追加
