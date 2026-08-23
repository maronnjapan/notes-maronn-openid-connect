# `acr_values` リクエストパラメータの ID Token `acr` 発行への伝播

## ステータス

🟡 改善（実装済み機能の end-to-end 不整合）/ 未着手

## 1. このトピックで確認したいこと

認可リクエストの `acr_values` パラメータが、最終的に ID Token の `acr` クレームを決定する `AcrResolver` まで届いているかを確認する。

具体的には次の一点に絞る:

- `AcrResolver` は「認可リクエストの `acr_values` を `requestedAcrValues` として受け取り、それを根拠に `acr` / `amr` を決定する」ことを型コメントで約束している（`packages/core/src/token-response.ts` L17-20, L90-92）。
- しかし `acr_values` は **認可リクエストのバリデーション後、Auth Transaction には保存されるものの、認可コード → Token Endpoint の経路で脱落**しており、実フローでは `requestedAcrValues` が常に `undefined` になる。
- 結果として、利用者が `AcrResolver` を実装しても **`acr_values` パラメータ単体では resolver に何も伝わらない**（`claims={"id_token":{"acr":{"values":[...]}}}` 経由のみ機能する）。

この「実装はあるが配線が途切れていて約束どおり動かない」状態を、Basic OP 認定要件・セキュリティ・相互運用性・拡張性の観点で整理する。

## 2. 関連する仕様・基準

ID Token / `acr` / `amr` の共通仕様説明は重複させない。共通参照ハブを見ること:

- Basic OP の定義・`acr_values` の §15.1 上の位置づけ・`acr` / `amr` の OIDC Core §2 / §12.1 挙動: `study-material/basic-op-requirement-traceability.md`（特に §3.2「Section 15.1 の MUST 機能」と §6.5 の `OP-Req-acr_values` 行）
- `AcrResolver` 注入機構（T-015）と refresh での `acr` / `amr` 引き継ぎ（T-005）: `tasks/done/oidc-improvements-2026-05.md`
- `amr` の値そのものの標準化ガイド（RFC 8176）: `study-material/amr-values-guidance-rfc8176.md` / `study-material/amr-values-rfc8176.md`
- `claims` パラメータの `value` / `values` / `essential` 一致判定（UserInfo 側）: `study-material/done/claims-parameter-value-values-essential.md`

本トピック固有のポイントのみ以下に記す。

### 2.1 OIDC Core 1.0 §3.1.2.1 `acr_values`

> acr_values
>   OPTIONAL. Requested Authentication Context Class Reference values.
>   Space-separated string that specifies the acr values that the
>   Authorization Server is being requested to use for processing this
>   Authentication Request, with the values appearing in order of
>   preference. ... The acr Claim is requested as a Voluntary Claim by
>   this parameter.

要点: `acr_values` は「この**認証リクエストの処理**に使ってほしい acr の優先順位付きリスト」である。すなわち、認証（authorization）時点の判断材料であると同時に、その結果が ID Token の `acr` クレーム（Voluntary Claim）として反映されることが期待される。`acr_values` を受け取った OP は、満たした acr を ID Token の `acr` に入れて返すのが本来の挙動。

### 2.2 §15.1（全 OP 必須）における `acr_values` の最低要件

OIDC Core §15.1 が全 OP に MUST として課すのは「`acr_values` を受理し、未処理でもエラーにしないこと」までである（共通ハブ §3.2 参照）。**acr を実際に算出して `acr` クレームに反映することは MUST ではない**。

したがって本トピックは「Basic OP 認定の合否を左右する不足」ではなく、**すでに用意されている `AcrResolver` 機能の end-to-end 整合性の問題**として扱う。`AcrResolver` を導入した時点で「`requestedAcrValues` を渡す」という API 契約が生まれており、その契約が実フローで履行されていない点が論点。

### 2.3 §5.5.1.1（`claims` パラメータ経由の acr 要求）との関係

OIDC Core §5.5.1.1 は `claims={"id_token":{"acr":{"essential":true,"values":["..."]}}}` を `acr_values` と同等の要求とみなす。現実装はこちら（`claims` 経由）だけは `generateTokenResponse` まで届いており、`effectiveRequestedAcrValues` として resolver に渡される（`token-response.ts` L257-269）。つまり **`claims.id_token.acr.values` は機能し、`acr_values` パラメータ単体は機能しない**という非対称が存在する。同じ意味の 2 つの要求方法で挙動が割れるのは相互運用性上わかりにくい。

## 3. 参照資料

- OpenID Connect Core 1.0 incorporating errata set 2 — https://openid.net/specs/openid-connect-core-1_0.html
  - §3.1.2.1 Authentication Request（`acr_values` の定義 = 上記 2.1）
  - §5.5.1.1 Requesting the "acr" Claim（`claims` パラメータ経由の acr 要求 = 上記 2.3）
  - §2 ID Token（`acr` は Voluntary Claim）
  - §15.1 Mandatory to Implement Features for All OPs（`acr_values` は「エラーにしない」が最低要件）
- RFC 8176 Authentication Method Reference Values — https://www.rfc-editor.org/rfc/rfc8176（`amr` 値。詳細は `amr-values-guidance-rfc8176.md` 参照）
- 共通ハブ: `study-material/basic-op-requirement-traceability.md`

## 4. 現在の実装確認

`acr_values` の流れを段階ごとに追うと、Auth Transaction までは保持され、その先で脱落する。

1. **認可リクエストのパース・バリデーション** — `packages/core/src/authorization-request.ts`
   - L44: `AuthorizationRequestParams.acr_values`
   - L667 / L698: `acrValues = params.acr_values` を `ValidatedAuthorizationRequest.acrValues` に格納（保持されている ✅）
2. **Auth Transaction への転記** — `packages/core/src/auth-transaction.ts`
   - L115: `AuthTransaction.acrValues?: string`
   - L221-223: `createAuthTransaction` が `validatedRequest.acrValues` を transaction に転記（保持されている ✅）
3. **Auth Transaction 完了 → 認可レスポンス生成** — `packages/core/src/auth-transaction.ts`
   - L142-155: `AuthorizationResponseParams` の型に **`acrValues` フィールドが存在しない** 🔴
   - L441-474: `completeAuthTransaction` は `state` / `nonce` / `audience` / `claims` のみ転記し、`acrValues` を **転記しない** 🔴（ここで脱落）
4. **認可コードデータ生成** — `packages/core/src/authorization-code.ts`
   - L24-52: `AuthorizationCodeData` に **`acrValues` フィールドが存在しない** 🔴
5. **Token Endpoint の認可コード解決** — `packages/core/src/token-request.ts`
   - L115-139: `AuthorizationCodeInfo` に **`acrValues` フィールドが存在しない** 🔴
   - L256-269: `ValidatedAuthorizationCodeRequest` にも `acrValues` が無い 🔴
6. **トークンレスポンス生成（acr 決定）** — `packages/core/src/token-response.ts`
   - L24-28: `AcrResolver` は `requestedAcrValues` を受け取る契約
   - L342-352: `acrResolver({ userId, clientId, requestedAcrValues: effectiveRequestedAcrValues })`
   - L260-269: `effectiveRequestedAcrValues` は引数 `requestedAcrValues` か `claims.id_token.acr.values` のいずれか。**`acr_values` パラメータ由来の値は供給経路が無い**
7. **生成された Provider のトークンルート** — `packages/sample/src/oidc-provider/routes/token.ts` L237-262 ／ `packages/cli/src/frameworks/hono/templates.ts`（`generateTokenResponse` 呼び出し）
   - `acrResolver`（L256）と `claims`（L261）は渡すが、**`requestedAcrValues` を渡していない** 🔴（渡す材料＝認可コードに保存された `acrValues` がそもそも存在しない）

結論: ステップ 3 で `acr_values` が脱落するため、`AcrResolver` の `requestedAcrValues` は実フローで常に `undefined`。`acr_values` パラメータ単体では resolver に届かない。

## 5. 現在の実装との差分

- **満たしていること**
  - §15.1 最低要件（`acr_values` を受理しエラーにしない）は充足（共通ハブ §6.5）。
  - `claims={"id_token":{"acr":{"values":[...]}}}` 経由の acr 要求は resolver まで届く（§5.5.1.1 相当）。
  - refresh では初回の `acr` / `amr` を直接引き継ぐ（§12.1、T-005 done）。
- **不足している可能性があること**
  - 認可リクエストの `acr_values` パラメータが Token Endpoint まで伝播せず、`AcrResolver` の `requestedAcrValues` 契約が実フローで履行されない（ステップ 3 で脱落）。
- **実装はあるが仕様上の確認が必要なこと**
  - 同義の 2 つの要求方法（`acr_values` と `claims.id_token.acr`）で挙動が割れる非対称。§5.5.1.1 の「equivalent」を踏まえ、両者を同じ `requestedAcrValues` に正規化して resolver へ渡すのが自然か要確認。
  - `acr` が essential（`claims.id_token.acr.essential=true`）で要求され、resolver が満たせなかった場合の扱い（OIDC は best-effort + 満たした acr を返す方針。エラーにはしない）。現状 essential フラグは resolver に伝わらない。
- **セキュリティ上、改善した方がよいこと**
  - 直接の脆弱性ではない。ただし step-up 認証（高 LoA 要求）を `acr_values` で表現する利用者は、`acr_values` が効かないことに気付かず「強い認証を要求したつもりが ID Token の `acr` に反映されない」状態に陥る。これは RP 側の認可判断を誤らせ得る（RP が `acr` を信頼して保護資源へのアクセス可否を決める場合）。
- **相互運用性の観点で改善した方がよいこと**
  - 標準的な RP / Conformance ツールは step-up を `acr_values` パラメータで送るのが一般的。`claims` 経由しか効かないのは相互運用性を損なう。
- **Basic OP として提供する上で確認すべきこと**
  - Basic OP 認定の必須ではない。ただし「`AcrResolver` を提供する」と謳う以上、その入力契約が実フローで成立していることは品質シグナルとして確認すべき。

## 6. 改善・追加を検討する理由

- **なぜこの改善を検討すべきか**: `AcrResolver` は実装・公開済みの機能であり、型コメントで `requestedAcrValues` を受け取ると明記している。にもかかわらず実フローでは常に `undefined` になるため、ドキュメントと挙動が食い違う「サイレントに動かない機能」になっている。OSS 利用者が最も嵌まりやすいタイプの不整合。
- **Basic OP として必要か、拡張か**: Basic OP 認定の必須ではない（§15.1 は「エラーにしない」まで）。位置づけは **既存拡張機能（`AcrResolver`）の整合性改善**。
- **導入しやすさ**: 導入しやすい。脱落しているのは「1 フィールドをデータ構造に追加し、4 箇所の転記に 1 行ずつ足す」配線作業のみ。新しい概念や外部依存は不要で、Web 標準のみで完結する。`claims` 経由が既に同じ resolver 入口（`effectiveRequestedAcrValues`）まで届いているため、合流点も明確。
- **既存実装との接続**: `nonce` / `audience` / `claims` がすでに「authorization → transaction → code → token」を通っている。`acrValues` を同じ経路に 1 本足すだけで、`token-response.ts` の `requestedAcrValues` 引数に渡せる。
- **利用者・開発者・運用者のメリット**: PoC 開発者が `acr_values` による step-up / LoA 要求の検証を、IdaaS に移行する前に本ライブラリで再現できる。`AcrResolver` の型コメントどおりに動くようになり、学習コストとデバッグ時間を削減できる。
- **実装しない場合のリスク**: `acr_values` を使う検証が `claims` 経由に書き換えない限り無言で失敗する。RP が `acr` を信頼する設計だと、要求した認証強度が反映されないことに気付かないまま PoC を進めてしまう。

## 7. 実装方針の候補

最終判断は人間が行う。以下は判断材料。

- **方針 A: 配線を最小限つなぐ（推奨度: 検討の中心）**
  - `AuthorizationResponseParams`（auth-transaction.ts）/ `AuthorizationCodeData`（authorization-code.ts）/ `AuthorizationCodeInfo`・`ValidatedAuthorizationCodeRequest`（token-request.ts）に `acrValues?: string` を追加。
  - `completeAuthTransaction` / `createAuthorizationCode` / `validateTokenRequest`（authorization_code 経路）で `acrValues` を順に転記。
  - 生成 Provider のトークンルート（sample + cli テンプレート）で `generateTokenResponse({ ..., requestedAcrValues: validatedRequest.acrValues })` を渡す。
  - 影響範囲が明確で後方互換（optional フィールドの追加のみ）。
- **方針 B: A に加えて `claims.id_token.acr` との正規化を明示**
  - `acr_values` と `claims.id_token.acr.values` の双方が来た場合の優先順位を決める（§5.5.1.1 は equivalent なので「`acr_values` を優先しつつ claims 側を補完」または「両者を結合」）。
  - resolver に渡す `requestedAcrValues` の決定ロジックを `token-response.ts` の `effectiveRequestedAcrValues` に集約済みなので、そこへ `acr_values` 由来値を合流させるだけで済む。
- **方針 C: essential フラグも resolver に渡す（任意・別検討）**
  - `AcrResolver` のコンテキストに `acrEssential?: boolean` を追加し、resolver が essential 要求を区別できるようにする。
  - スコープが広がるため本タスクから切り離し、必要なら別トピック化。
- **方針 D: 何もしない（`claims` 経由のみサポートと割り切る）**
  - `AcrResolver` の型コメントから `requestedAcrValues` の「`acr_values` パラメータ由来」という記述を削り、`claims` 経由のみと明記する（ドキュメントを実態に合わせる）。
  - 機能は増えないが、誤解を生む契約は解消される。最小コストの選択肢。

判断軸: 「`acr_values` パラメータを実際に検証したい利用者がどれだけいるか」「step-up を相互運用的に再現したいか」。step-up を本ライブラリの売り（Speed / Fidelity）として重視するなら A or B、当面 `claims` 経由で十分なら D。

## 8. タスク案

- [ ] 方針 A / B / D のいずれで進めるかを人間が決定する（C は別検討）。
- [ ]（A 採用時）`acrValues?: string` を `AuthorizationResponseParams` / `AuthorizationCodeData` / `AuthorizationCodeInfo` / `ValidatedAuthorizationCodeRequest` に追加する。
- [ ]（A 採用時）`completeAuthTransaction` / `createAuthorizationCode` / `validateTokenRequest`（authorization_code 経路）で `acrValues` を転記する。
- [ ]（A 採用時）sample / cli テンプレートのトークンルートで `requestedAcrValues` を `generateTokenResponse` に渡す。
- [ ]（B 採用時）`acr_values` と `claims.id_token.acr.values` の合流規則を `token-response.ts` の `effectiveRequestedAcrValues` ロジックに実装する。
- [ ] TDD: 「`acr_values=loa2` を送ると `AcrResolver` が `requestedAcrValues='loa2'` を受け取る」テストを `token-response.test.ts`（core）と統合テスト（生成 Provider）に追加する。
- [ ] TDD: 「`acr_values` パラメータと `claims.id_token.acr.values` の両方を送ったときの優先順位」テストを追加する（B 採用時）。
- [ ] refresh_token grant では `requestedAcrValues` を渡さず、保存済み `acr` / `amr` を直接引き継ぐ既存挙動（§12.1）が維持されることをテストで固定する。
