# `claims` パラメータによる `sub` 値の要求（OIDC Core §5.5.1 Requesting the "sub" Claim）の未対応

## ステータス

🟡 Medium / 未着手（**方針未決の論点を含む。最終判断は人間**）

## 1. このトピックで確認したいこと

OIDC Core 1.0 §5.5.1 は、`claims` リクエストパラメータで **`sub` を特定の値に固定して要求**できると定める
（例: `claims={"id_token":{"sub":{"value":"248289761001"}}}`）。これはクライアントが
「いま認証されようとしている End-User が、自分の想定するユーザ本人か」を検証するための仕組みである。

本リポジトリはこの `sub` 値要求を **認可時にも発行時にも一切参照していない**。特に UserInfo エンドポイントは
`sub` を明示的にスキップし、要求値と実サブジェクトの不一致を検知しない。この未対応が

- 仕様適合性（§5.5.1）
- セキュリティ（要求と異なるユーザのトークン/クレームを黙って返す＝サブジェクト取り違え）
- 相互運用性（`id_token_hint` と同種の「サブジェクト固定」ユースケースの欠落）

の観点でどの程度問題か、どう対応すべきかを整理する。

### 既存ファイルとの差分

- `claims` パラメータの構造対応・パースは `tasks/done/p0-claims-id-token-support.md`。
- 個別クレームの `value` / `values` / `essential` 解釈（**UserInfo 側の一般クレーム**）は
  `study-material/done/claims-parameter-value-values-essential.md` /
  `tasks/done/p2-claims-parameter-value-values-enforcement.md`。ただし **`sub` は対象外**（後述の実装で除外）。
- `id_token_hint` によるサブジェクト固定（`prompt=none` 時）は
  `tasks/done/p0-id-token-hint-prompt-none.md` / `tasks/done/T-017-id-token-hint-validation.md`。
- `sub` 以外の `id_token` メンバー標準クレームを ID Token に載せる論点は
  `study-material/claims-id-token-member-individual-claims-in-id-token.md`。
- 本ファイルは上記の隙間、すなわち **「`sub` に特定値が要求されたときのバインディング（認可時の本人一致確認）と
  発行時の一貫性」** に絞る。`sub` は他の標準クレームと異なり「値の一致」がセキュリティ意味を持つため独立トピックとする。

## 2. 関連する仕様・基準（このトピック固有の差分）

### 2.1 OIDC Core 1.0 §5.5.1 — 個別クレーム要求と `sub` の値要求

§5.5.1 は個別クレーム要求の例として `sub` を特定値で要求する形を示す。

```json
{
  "id_token": {
    "sub": { "value": "248289761001" }
  }
}
```

§5.5.1 の一般規則:

- `value`: そのクレームを **指定値で返すことを要求**する。
- クレームが返せない場合、Essential であっても **OP はエラーを返してはならない（MUST NOT）**
  （そのクレームの定義で別途規定される場合を除く）。

`sub` は ID Token / UserInfo の **必須クレーム**であり「省略して返さない」という選択肢が無い。したがって
「指定値の `sub` を返せない」状況は、**指定値と異なる `sub` を黙って返す**か、**そもそもその End-User では
認可を成立させない**かの二択になる。前者はサブジェクト取り違えを招くため、実質的に
**認可時に「要求 `sub` = 認証済み End-User の `sub`」を確認する**設計が求められる（`id_token_hint` の
サブジェクト固定と同型）。

### 2.2 `id_token_hint` との関係（§3.1.2.1）

§3.1.2.1 は `id_token_hint` を「以前発行した ID Token を End-User の識別子ヒントとして渡す」ものと定め、
`prompt=none` と併用された場合に「現在のセッションの End-User が hint の `sub` と一致しなければ
`login_required` 等を返す」挙動を要求する。`claims.id_token.sub.value` は**同じ「このユーザ本人であることの要求」**を
別経路で表現したものと解釈でき、`id_token_hint` と整合する扱いが自然である。

### 2.3 現行の値制約実装が `sub` を除外している点

`sub` は §5.5.1 の値制約対象でありながら、本リポジトリの UserInfo 実装は明示的に `sub` をスキップしている
（後述 4.2）。これは「`sub` は常にトークンのサブジェクトで固定」という安全側の実装だが、
**要求値との不一致を検知しない**ため、要求 `sub` と異なるユーザのクレームを返し得る。

## 3. 参照資料

- OpenID Connect Core 1.0, §5.5.1 "Individual Claims Requests"
  https://openid.net/specs/openid-connect-core-1_0.html#IndividualClaimsRequests
  （`sub` を `value` で要求する例。`value` の意味と Essential 時の MUST NOT error）
- OpenID Connect Core 1.0, §5.5 "Requesting Claims using the claims Request Parameter"
  https://openid.net/specs/openid-connect-core-1_0.html#ClaimsParameter
- OpenID Connect Core 1.0, §3.1.2.1 "Authentication Request"（`id_token_hint` / `prompt=none` の本人一致）
  https://openid.net/specs/openid-connect-core-1_0.html#AuthRequest
- OpenID Connect Core 1.0, §2 "ID Token"（`sub` は必須）
  https://openid.net/specs/openid-connect-core-1_0.html#IDToken
- 既存リポジトリ内資料（重複説明を避けるための参照先）:
  - `tasks/done/p0-id-token-hint-prompt-none.md`（`id_token_hint` × `prompt=none` の本人一致）
  - `tasks/done/p0-claims-id-token-support.md`（`claims` 構造対応）
  - `study-material/done/claims-parameter-value-values-essential.md`（値制約の一般解釈）

## 4. 現在の実装確認

### 4.1 認可エンドポイント（`packages/core/src/authorization-request.ts`）

`claims` は `parseClaimsRequest` で `{ userinfo?, id_token? }` にパースされ、
`ValidatedAuthorizationRequest.claims` として下流に渡る。しかし `sub` の値要求を取り出して
**セッションの End-User と突き合わせる処理は存在しない**（`grep` で `sub` の value 参照なし）。
`prompt=none` 経路（`auth-transaction.ts` の `checkPromptNone`）は `id_token_hint` の `sub` は見るが、
`claims.id_token.sub.value` は見ていない。

### 4.2 UserInfo エンドポイント（`packages/core/src/userinfo.ts`）

要求クレーム反映のループで `sub` を明示的にスキップしている。

```ts
// userinfo.ts L426-441（handleUserInfoRequest, step 5）
for (const claimName of requestedClaims) {
  if (claimName === 'sub') continue;   // ← sub は値要求があっても無視される
  ...
}
```

`sub` はレスポンス冒頭で常にトークンのサブジェクトに固定される（`filterClaimsByScope` の
`const result = { sub: userClaims.sub }`）。要求された `sub.value` との一致・不一致は判定しない。

### 4.3 ID Token 発行（`packages/core/src/token-response.ts`）

`idTokenPayload.sub = subject`（＝認可コードに紐づくサブジェクト）で固定され、`claims.id_token.sub` の
値要求は参照されない。`sub` の値要求が満たせない End-User でも、そのまま別サブジェクトの ID Token を発行する。

### 4.4 まとめ

`claims.id_token.sub.value` は **認可時・ID Token 発行時・UserInfo のいずれでも参照されない**。
結果として「特定ユーザ本人であることを要求する」§5.5.1 のユースケースが機能せず、要求と異なる
サブジェクトのトークン/クレームを黙って返す。

## 5. 現在の実装との差分

- **満たしていること**
  - `id_token_hint` によるサブジェクト固定（`prompt=none` 時）は実装済み。§5.5.1 と同型の別経路がある。
  - `claims` の構造パースは完了。`sub` の value も型上は `ClaimsParameter.id_token['sub']` として保持される。
- **不足している可能性があること**
  - `claims.id_token.sub.value`（および `values`）が **どこでも突き合わせされない**。§5.5.1 の `sub` 値要求が不成立。
  - UserInfo が要求 `sub` と実 `sub` の不一致を検知しない。
- **セキュリティ上、改善した方がよいこと**
  - サブジェクト取り違え防止。特に `prompt=none` のサイレント認証で、クライアントが想定するユーザと
    実セッションのユーザが異なる場合に **黙って別人のトークンを返す**のは避けたい。
    `id_token_hint` と同じく `login_required` / `account_selection_required` で弾くのが安全。
- **相互運用性の観点で改善した方がよいこと**
  - 他 IdP は `claims.id_token.sub.value` を `id_token_hint` 相当に扱うものがある。移行検証で挙動差が出る。
- **Basic OP として提供する上で確認すべきこと**
  - Basic OP 認定の **必須ではない**（`claims` パラメータ・`sub` 値要求とも任意）。ただし
    `claims_parameter_supported: true` を広告する以上、`sub` 値要求を黙殺するのは Fidelity として弱い。

## 6. 改善・追加を検討する理由

- **なぜ価値があるか**: `sub` 値要求は「本人性の検証」という **セキュリティ目的**を持つ数少ない claims 要求。
  黙殺するとサブジェクト取り違えの余地が残る。
- **Basic OP 必須か拡張か**: 必須ではない。位置づけは **セキュリティ強化 + `claims` 対応の整合性改善**。
- **導入しやすさ**: `id_token_hint` × `prompt=none` の本人一致ロジック（`checkPromptNone`）が既にあり、
  「要求 `sub` と実 End-User の一致確認」はそこへ相乗りできる。**部品は揃っている**。
- **既存実装との接続**:
  - 認可時: `checkPromptNone` / 認可トランザクション確定時に `claims.id_token.sub.value|values` があれば
    確定サブジェクトと突き合わせ、不一致なら `id_token_hint` と同じエラー系（`login_required` /
    `account_selection_required`）を返す。
  - UserInfo/ID Token 発行時: 実サブジェクトが要求値と一致することを前提に、追加の不一致検知（防御的）を置ける。
- **利用者メリット**: クライアントが「このユーザ本人のみ」を安全に要求できる。IdP 移行時の挙動一致。
- **実装しない場合のリスク**: `sub` 値要求のサイレント無視。要求と異なるサブジェクトのトークン発行余地。
  `claims_parameter_supported` の広告と実挙動の乖離。

## 7. 実装方針の候補（最終判断は人間）

> §5.5.1 は「Essential でも取得不可でエラーを返すな」と定める。`sub` は省略不可の必須クレームなので、
> 「要求値で返せない＝その End-User では認可を成立させない（エラー/再認証誘導）」と「サイレントに別 `sub` を返す」の
> どちらを取るかが設計判断の核心。ここを人間が決める。

- **方針 A: 認可時バインディング（`id_token_hint` と対称化。推奨検討）**
  - 認可トランザクション確定時、`claims.id_token.sub`（`value` / `values`）があれば確定サブジェクトと照合。
  - 不一致:
    - `prompt=none` あり → `login_required` または `account_selection_required` を返す（サイレント認証を許さない）。
    - 対話ログインあり → 別アカウントでのログイン/アカウント選択を促す（`select_account` 相当のガイド）、
      または要求 `sub` に一致しないログインを拒否。
  - 一致すれば通常フロー。ID Token / UserInfo の `sub` は自然に要求値と一致する。
  - `id_token_hint` の `sub` と `claims.id_token.sub.value` の両方が来た場合の優先/整合ルールも定義する。
- **方針 B: 発行時ガード（最小・防御的）**
  - 認可時は触らず、ID Token 発行・UserInfo 応答の直前で「実 `sub` == 要求 `sub`」を確認し、
    不一致なら発行拒否（`invalid_request` 相当）／`invalid_token`。
  - 実装は小さいが、UX（どこで弾くか）が悪く、`prompt=none` のサイレント認証面には効きにくい。方針 A の補助向き。
- **方針 C: 明示的に非対応と広告する（消極策）**
  - `sub` 値要求は非対応と README / discovery コメントに明記。実装は変えない。
  - コスト最小だがセキュリティ/Fidelity は上がらない。少なくとも「黙殺」ではなく「明示」にはなる。
- **`values`（複数許容）対応**: `sub.values` は「いずれかの `sub` なら可」。方針 A の照合を集合一致に拡張するだけ。

## 8. タスク案

- [ ] 認可トランザクション確定経路に `claims.id_token.sub`（`value` / `values`）の照合を追加（方針 A 採用時）
  - [ ] 確定サブジェクトが要求値集合に含まれなければ、`prompt=none` 時は `login_required` /
        `account_selection_required` を返す
  - [ ] `id_token_hint.sub` と `claims.id_token.sub.value` が併存する場合の整合ルールを定義・文書化
- [ ] 発行時ガード（方針 B、防御的多層化として併用可）:
  - [ ] ID Token 発行直前に `subject` が要求 `sub` と一致することを確認
  - [ ] UserInfo で要求 `sub` と実 `sub` の不一致を検知（現状の `if (claimName === 'sub') continue` の見直し）
- [ ] 単体/統合テスト:
  - [ ] `claims={"id_token":{"sub":{"value":"U1"}}}` + `prompt=none` + セッションが `U2` → `login_required`
  - [ ] 同上でセッションが `U1` → 正常発行、`sub=U1`
  - [ ] `sub.values=["U1","U2"]` でセッション `U2` → 正常（集合一致）
  - [ ] `id_token_hint`(sub=U1) と `claims.id_token.sub.value=U2` の矛盾入力の扱いを固定
- [ ] discovery / README のコメントを実挙動に合わせて更新（方針 C を併用しない場合は「`sub` 値要求対応」に）
- [ ] OP 挙動が変わるため、`packages/cli` の `conformance.test.ts` 生成テンプレートを更新
      （生成物を直接編集せず生成元を変更する。CLAUDE.md の方針に従う）
- [ ] 余力があれば `tests/e2e` に「要求 `sub` と異なるセッションで `prompt=none` が `login_required` になる」E2E を追加
