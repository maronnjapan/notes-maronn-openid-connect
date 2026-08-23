# `claims` リクエストパラメータの `value` / `values` / `essential` の解釈

## ステータス

🟡 Medium / 未着手

## 1. このトピックで確認したいこと

OIDC Core 1.0 §5.5 の `claims` リクエストパラメータについて、**個別クレーム要求の値制約**
（`value` / `values` / `essential`）が実装で解釈されているかを確認する。

- `claims` の **構造（`userinfo` / `id_token` メンバー）対応**と `acr.values` の resolver 連携は
  既に完了している（`tasks/done/p0-claims-id-token-support.md`）。本ファイルはその **差分**として、
  「個別クレームに付いた `value` / `values` / `essential` を OP がどう扱うか」だけを扱う。
- 重複記載を避けるため、`claims` パラメータの全体像・パース処理の説明は
  `study-material/userinfo-endpoint-comprehensive.md` §3.3 と `tasks/done/p0-claims-id-token-support.md`
  を参照し、ここでは値制約の解釈に絞る。

## 2. 関連する仕様・基準（このトピック固有の差分）

### 2.1 OIDC Core 1.0 §5.5.1 Individual Claims Requests

各クレームは `null`（デフォルト要求）または以下のメンバーを持つ JSON オブジェクトで要求される:

- **`essential`（boolean）**: そのクレームが End-User にとって必須（Essential）かを示す。
  `true` の場合、OP/クライアントはそのクレームの取得を優先すべき（SHOULD）。
  ただし §5.5.1 は明確に **「Essential であっても、取得できない場合に OP はエラーを返してはならない（MUST NOT）」**
  と定める（クレームの説明で別途規定されない限り）。
- **`value`（任意の型）**: そのクレームを **特定の値で返すことを要求**する。
- **`values`（配列）**: そのクレームを **列挙された値のいずれかで返すことを要求**する。

§5.5.1.1（`acr` の要求）は `value` / `values` の具体例で、`acr.values` は `acr_values` 要求と等価。
この `acr.values` 連携は既に実装済み（`token-response.ts` の `effectiveRequestedAcrValues`）。

### 2.2 値制約の OP 側挙動（仕様の読み方）

- `value` / `values` は「OP が満たせるなら、その値（のいずれか）でクレームを返す」要求。
  満たせない場合の扱いは、`essential` でなければ単に返さない／無視でよい。
- `essential` は「取得を優先せよ」というシグナルであり、**エラー化の根拠にはならない**。
- したがって OP の妥当な実装は: 「要求された `value`/`values` に一致するクレーム値を持つときだけ
  そのクレームを返す。一致しなければ（essential でも）当該クレームを省略し、エラーにはしない」。

## 3. 参照資料

- OpenID Connect Core 1.0 §5.5 Requesting Claims using the "claims" Request Parameter
  — https://openid.net/specs/openid-connect-core-1_0.html#ClaimsParameter
- OpenID Connect Core 1.0 §5.5.1 Individual Claims Requests
  — https://openid.net/specs/openid-connect-core-1_0.html#IndividualClaimsRequests
  （`essential` / `value` / `values` の定義と「Essential でもエラーにしない MUST NOT」）
- OpenID Connect Core 1.0 §5.5.1.1 Requesting the "acr" Claim
  — https://openid.net/specs/openid-connect-core-1_0.html#acrSemantics
- 本リポジトリ内: `tasks/done/p0-claims-id-token-support.md`（構造対応・`acr.values` 連携の確定済み実装）

## 4. 現在の実装確認

### 4.1 パース（`packages/core/src/authorization-request.ts`）

- `parseClaimsRequest` / `sanitizeClaimsMember` が `userinfo` / `id_token` メンバーを取り出し、
  各クレームを `null` または `{ essential?, value?, values?, ... }` 形式で保持する。
- 型 `ClaimRequestEntry`（`userinfo.ts`）は `essential` / `value` / `values` を **保持できる**。
- つまり **「要求された値制約は型として保持されているが、解釈はされていない」**状態。

### 4.2 UserInfo での解釈（`packages/core/src/userinfo.ts`）

```ts
// userinfo.ts:232-237
function getRequestedClaimNames(claimsParameter?: ClaimsParameter): (keyof UserClaims)[] {
  if (!claimsParameter?.userinfo) return [];
  return Object.keys(claimsParameter.userinfo) as (keyof UserClaims)[];
}
```

- `claims.userinfo` からは **クレーム名（キー）だけ**を取り出し、`value` / `values` / `essential` を無視する。
- `handleUserInfoRequest` は要求されたクレーム名を「存在すれば追加」するだけ。
  → `value: "X"` を要求しても、実値が `Y` でも `Y` をそのまま返す（値一致のフィルタが無い）。

### 4.3 ID Token での解釈（`packages/core/src/token-response.ts`）

- `claims.id_token` のうち **`acr.values` だけ**を `acrResolver` への要求値として使う。
- それ以外の `id_token` 個別クレーム（例: `email` を `essential` 要求）や、`value`/`values` 制約は
  **ID Token 生成時に一切参照されない**。

## 5. 現在の実装との差分

満たしていること:

- ✅ `claims` の構造（`userinfo` / `id_token`）対応とパース。
- ✅ `acr.values` → `acrResolver` 連携（§5.5.1.1）。
- ✅ Basic OP の `OP-claims-essential` 系テストが要求する「essential クレームを返す」基本挙動
  （essential email を要求すると email を返す、はクレーム名ベースで成立）。

不足・確認が必要なこと:

- 🟡 **`value` / `values` の値一致が効かない**: `claims.userinfo.email.value="a@example.com"` を要求しても、
  実際の email が異なってもそのまま返す。`values`（候補集合）にも一致判定が無い。
  → §5.5.1 の「要求した値で返す」意図に沿っていない（ただし SHOULD レベル）。
- 🟡 **`essential` が無処理**: 優先シグナルとしての扱いが無い。エラー化していない点は正しい（MUST NOT を満たす）が、
  「essential なら scope 外でも返す」等の挙動も無い（これは設計判断の余地）。
- 🟡 **`id_token` 個別クレーム（acr 以外）の無視**: `claims.id_token.email` を essential 要求しても
  ID Token に反映されない。scope ベースの `userClaims` フィルタ（`filterClaimsByScope`）に依存しており、
  `claims` パラメータ経由の ID Token クレーム要求は acr 以外で経路が無い。
- 🟢 **エラー非生成は仕様準拠**: 取得不能でもエラーにしない現挙動は §5.5.1 の MUST NOT を満たす。

相互運用性の観点:

- `value`/`values` を尊重しないと、クライアントが「特定値での返却」を期待する高度フロー
  （例: 特定 `acr` の essential 要求でステップアップを期待）で齟齬が出る。
  `acr` は連携済みだが、汎用の `value`/`values` は未対応。

## 6. 改善・追加を検討する理由

- **Fidelity**: `claims_parameter_supported: true` を広告する前提なら（done タスクの完了条件）、
  `value`/`values`/`essential` を「無視する」のか「尊重する」のかを **明示**しておくべき。
  広告だけして値制約を無視すると、忠実性シグナルとして弱い。
- **拡張接続性**: Step-up Authentication（`study-material/ext-step-up-authentication-rfc9470.md`）や
  Identity Assurance（`study-material/ext-identity-assurance-1_0.md`）は `claims` の値制約を多用する。
  汎用の `value`/`values` 解釈を入れておくと、これら拡張の土台になる。
- **実装しない場合のリスク**: `value`/`values` を無視したまま「`claims` 対応」と謳うと、
  値制約を前提に組んだクライアントが「OP がフィルタしていない」ことに気付きにくく、検証の信頼性が下がる。
- **Basic OP 必須ではない**: `OP-claims-essential` はクレーム名ベースで通るため、本差分は
  **認定ブロッカーではなく fidelity 改善**。優先度は中。

## 7. 実装方針の候補（最終判断は人間）

- **方針A（UserInfo の `value`/`values` フィルタ）**: `handleUserInfoRequest` で、要求クレームに
  `value`/`values` がある場合、実値が一致（`value` は等価、`values` は包含）するときだけ返す。
  一致しなければ省略（essential でもエラーにしない）。小さな局所変更で済む。
- **方針B（ID Token への汎用 `claims.id_token` 反映）**: `generateTokenResponse` に
  `userClaims` を渡す経路（既存）と組み合わせ、`claims.id_token` の個別要求も scope 同様に
  ID Token クレームへ反映する。`value`/`values` フィルタも適用する。
  ただし「どのクレームを ID Token に入れてよいか」はプライバシー設計が絡むため要検討。
- **方針C（essential の優先扱い）**: `essential: true` のクレームは scope に含まれなくても
  取得を試みる、等の優先ロジック。設計判断が大きいので慎重に。`essential` の MUST NOT（エラー化禁止）は
  現状維持で守る。
- **方針D（明示的に「未対応」を文書化）**: `value`/`values`/`essential` は構造として受理するが
  値制約は解釈しない旨を型 doc に明記し、`claims_parameter_supported` の広告と整合させる。

判断材料:

- 方針 A は影響範囲が小さく、`value`/`values` の値一致という分かりやすい仕様準拠を満たせる。
- 方針 B/C はプライバシー・設計判断が伴うため、Step-up / Identity Assurance を実装するタイミングで
  まとめて入れる方が手戻りが少ない。
- まず A（UserInfo の値フィルタ）を入れ、ID Token 側（B）は拡張実装時に回すのが現実的。

## 8. タスク案

- [ ] 方針（A / B / C / D）を決定する（人間判断）
- [ ] （方針A・TDD）`userinfo.test.ts` に以下を追加:
  - `claims.userinfo.<claim>.value` が実値と一致 → 返す／不一致 → 省略（エラーにしない）
  - `claims.userinfo.<claim>.values` に実値が含まれる → 返す／含まれない → 省略
  - `essential: true` でも取得不能ならエラーにせず省略する（§5.5.1 MUST NOT）
  - 既存の「クレーム名ベースの追加要求」挙動が壊れない（リグレッションなし）
- [ ] （方針A）`handleUserInfoRequest` の `claims` 適用ロジックに値一致フィルタを実装
- [ ] （方針B採用時）`generateTokenResponse` で `claims.id_token` の個別要求を ID Token に反映する経路を追加
- [ ] 型 doc（`ClaimRequestEntry`）に「`value`/`values`/`essential` の解釈ポリシー」を明記
- [ ] `study-material/userinfo-endpoint-comprehensive.md` の claims 行に対応状況を追記
