# `request` と `request_uri` の同時指定の禁止（OIDC Core §6 MUST NOT、処理順序の是正）

## ステータス

🟡 Medium / 未着手

## 1. タイトル

認可リクエストに `request`（by value）と `request_uri`（by reference）が**同時に**含まれた場合、OIDC Core §6 の「MUST NOT be used together」に従って `invalid_request` で拒否すること。現状は `request` を先に**パース・マージしてから** `request_uri` を `request_uri_not_supported` で弾いており、(a) 同時指定という §6 違反を診断していない、(b) 誤ったエラーコードを返す、(c) 信頼できない入力（request object）を不要に処理する、という差分を是正する。

> 注: `request_uri` 単体の非対応拒否と Discovery 整合（`request_parameter_supported` / `request_uri_parameter_supported` の明示）は既存ファイル `study-material/request-object-rejection-and-discovery-honesty.md` が扱う。本ファイルはそれと直交する「**両方同時に来た場合の相互排他ルールと処理順序**」のみを扱い、非対応広告・単体拒否の説明は繰り返さない。

## 2. このトピックで確認したいこと

- OIDC Core §6 が定める「`request` と `request_uri` を同一リクエストで併用してはならない」MUST NOT を、本実装が満たしているか
- 本実装は `request`（署名付き by value）を**サポート**し、`request_uri`（by reference）を**非サポート**としている。この非対称ゆえに「両方同時」が来た時、現状は `request` を信頼処理した後で `request_uri` 側のみを理由に弾く。結果として:
  - 返るエラーコードが §6 の `invalid_request` ではなく `request_uri_not_supported` になる
  - `request` object（攻撃者が制御し得る JWT）を先にパース・マージしてしまう（無駄な信頼処理）
  という挙動を確認する

## 3. 関連する仕様・基準

- **OpenID Connect Core 1.0 §6（Passing Request Parameters as JWTs）/ §6.2**:
  - 「The `request` and `request_uri` parameters MUST NOT both be used in the same request.」（同時併用禁止の MUST NOT）
  - 併用された場合は不正リクエストであり、`invalid_request` 系のエラーで拒否すべき。
- **OpenID Connect Core 1.0 §6.1（Request Object by Value）/ §6.2（by Reference）**: `request` は JWT を直接、`request_uri` は JWT の参照 URL を渡す。両者は同じ「Request Object を渡す」機構の二系統であり、二重指定は曖昧（どちらが優先か不定）になるため禁止されている。
- **OpenID Connect Core 1.0 §3.1.2.6（Authentication Error Response）**: 認可エラー応答経路。redirect_uri / client_id が信頼できる段階に達していれば、エラーは登録済み redirect_uri へ返し得る。
- **セキュリティ観点（信頼境界）**: 両方同時という時点で「壊れた／攻撃的なリクエスト」の可能性が高い。`request` object をパース・マージ（redirect_uri / scope 等を supersede し得る）する前に弾く方が、信頼できない入力の処理面を減らせる。現実装は `resolveRedirectUri` が登録済み URI と exact match するため open-redirect には至らないが、「先にパースしてから弾く」順序は防御的とは言えない。

## 4. 参照資料

- OpenID Connect Core 1.0 §6 — https://openid.net/specs/openid-connect-core-1_0.html#JWTRequests （"The `request` and `request_uri` parameters MUST NOT both be used in the same request."）
- OpenID Connect Core 1.0 §6.2 — https://openid.net/specs/openid-connect-core-1_0.html#RequestUriParameter
- OpenID Connect Core 1.0 §3.1.2.6 — https://openid.net/specs/openid-connect-core-1_0.html#AuthError
- 関連既存ファイル: `study-material/request-object-rejection-and-discovery-honesty.md`、`study-material/done/request-object-claim-validation-replay-and-audience.md`、`tasks/done/p1-basic-op-request-object-by-value.md`

## 5. 現在の実装確認

- `packages/core/src/authorization-request.ts` `validateAuthorizationRequest`:
  - 行 714-733: `if (params.request !== undefined) { roClaims = await parseRequestObject(...) }` — `request` object を**先にパース**（失敗時のみ `invalid_request`）。
  - 行 749-751: `const effective = roClaims ? mergeRequestObjectParams(params, roClaims) : {...params};` — request object の claim を認可パラメータへ**マージ**（redirect_uri / scope / state / nonce / prompt 等を supersede し得る）。
  - 行 756-760: `resolveRedirectUri(effective.redirect_uri, client.redirectUris, client.clientType)` — マージ後の redirect_uri を登録済み URI と exact match で再検証（open-redirect は防げている）。
  - 行 772-779: `if (params.request_uri !== undefined) { throw new AuthorizationError(AuthorizationErrorCode.RequestUriNotSupported, ...) }` — `request_uri` を**ここで初めて**非対応として拒否。
  - **`params.request !== undefined && params.request_uri !== undefined` を §6 違反として診断する分岐は存在しない。**
- 結果として両方同時のリクエストは:
  1. `request` object がパース・マージされる（信頼処理が走る）
  2. その後 `request_uri` を理由に `request_uri_not_supported` で拒否される
  - 最終的に拒否はされるが、**エラーコードが §6 の `invalid_request` ではない**し、`request` の信頼処理が先に走る。

## 6. 現在の実装との差分

満たしていること:

- 両方同時のリクエストは最終的に**拒否される**（`request_uri` 非対応のため）。open-redirect は `resolveRedirectUri` の exact match で防止済み。

不足している可能性があること:

- 🟡 **§6 MUST NOT の未診断**: 「同時併用」という違反そのものを検出していない。仕様準拠としては `invalid_request`（"request and request_uri MUST NOT be used together"）を返すべき。
- 🟡 **エラーコードの不正確さ**: 現状 `request_uri_not_supported` が返るため、クライアントは「request_uri が非対応」と解釈する。実際の違反は「併用禁止」であり、診断メッセージが誤誘導。
- 🟡 **処理順序（信頼できない入力の先行処理）**: 併用は不正リクエストの強いシグナルだが、`request` object（署名付きとはいえ攻撃者が組み立て得る JWT）を先にパース・マージしてから弾く。先に併用を検出して弾けば、不要な信頼処理を回避できる（防御的プログラミング）。
- 🟢 **将来 `request_uri` をサポートした場合のリグレッション**: いまは `request_uri` が常に非対応なので「結果的に弾かれる」が、将来 `request_uri` を実装（`study-material/ext-jar-request-object-rfc9101.md` 等）したら、併用チェックが無いと両方同時が**通って**しまう（どちらを優先するか不定）。先に明示チェックを入れておくと将来の穴を塞げる。

Basic OP 認定との関係:

- Request Object 関連は Basic OP の必須テスト対象ではない（`request-object-rejection-and-discovery-honesty.md` と同じ位置づけ）。本論点は **Fidelity / 予測可能性 / 将来の安全性**の軸。

## 7. 改善・追加を検討する理由

- 「最新の OIDC/OAuth 仕様を忠実に」を掲げる以上、§6 の MUST NOT を正しいエラーコードで履行することは Fidelity シグナル。
- **将来の安全性**: JAR/`request_uri` を実装する計画（先端仕様）がある以上、併用チェックを今のうちに入れておくと、機能拡張時に「どちらを優先するか不定」という危険な状態を作らずに済む。
- **防御的順序**: 不正リクエストの強いシグナルである併用を、信頼できない `request` object のパース前に弾くのは健全。
- 導入容易性: 🟢 極小。`validateAuthorizationRequest` の `request` パース前に `if (params.request !== undefined && params.request_uri !== undefined) throw invalid_request` を 1 分岐足すだけ。redirect_uri / client_id 検証が済んでいる段階で投げれば state echo も整合。
- 実装しない場合のリスク: 仕様非準拠のエラーコード継続、将来 `request_uri` 実装時の併用穴、信頼できない入力の先行処理。

## 8. 実装方針の候補

### 方針A（`request` パース前に併用を検出して `invalid_request`, 推奨筆頭）

- `validateAuthorizationRequest` で、`request` のパース（行 714）より**前**に:
  ```ts
  // OIDC Core 1.0 §6.2: request と request_uri は同一リクエストで併用不可。
  if (params.request !== undefined && params.request_uri !== undefined) {
    throw new AuthorizationError(
      AuthorizationErrorCode.InvalidRequest,
      'request and request_uri must not be used together',
      // redirect_uri / state は未確定段階なら付けない（既存の非リダイレクトエラー方針に合わせる）
    );
  }
  ```
- redirect_uri / client_id 検証との順序: 既存方針（信頼できる redirect 先が確定するまで state を echo しない）に合わせ、どの段階で投げるか（state を付けるか）を決める。併用は「壊れたリクエスト」寄りなので非リダイレクト invalid_request でも妥当。

### 方針B（`request_uri` 非対応拒否の前に併用だけ特別扱い）

- いまの `request_uri_not_supported` 分岐の手前で併用を検出して `invalid_request` を優先。
- `request` を先にパースする点は残るため、防御的順序の改善は限定的。方針 A の方が良い。

### 方針C（`request_uri` サポート実装時に合わせて対応）

- 現状は「結果的に拒否」されるので放置し、JAR/`request_uri` 実装（先端仕様、`RELEASE-v0.x-scope.md` で v0.x 非対象）と同時に対応。
- 当面の Fidelity / 順序問題は残る。

判断材料:

- `request-object-rejection-and-discovery-honesty.md` が `request_uri` 単体拒否を扱うため、本タスクはその**直前**（併用チェック）として接続するのが自然。両タスクを同時に実装すると整合的。
- 将来 `request_uri` をサポートする方針があるかで方針 A/C の優先度が変わる（人間が判断）。

## 9. タスク案

- [ ] 方針（A/B/C）を決定（人間が判断、A 推奨）
- [ ] （TDD）`authorization-request.test.ts` に以下を先に追加:
  - `request` と `request_uri` の両方を指定 → `invalid_request`（メッセージ "must not be used together"）で拒否され、`request_uri_not_supported` ではない
  - 併用時に `request` object がパース・マージされていない（不正な request object を入れても、併用チェックが先に弾く）ことを確認
  - `request` のみ → 従来どおり処理（回帰固定）、`request_uri` のみ → 従来どおり `request_uri_not_supported`（回帰固定）
- [ ] `authorization-request.ts` の `request` パース前に併用検出分岐を実装
- [ ] エラーの state echo 有無を既存の非リダイレクトエラー方針に合わせる
- [ ] `study-material/request-object-rejection-and-discovery-honesty.md` の §6 説明に「併用禁止」項目を相互参照として追記
- [ ] `study-material/ext-jar-request-object-rfc9101.md` に「将来 `request_uri` を実装する際は併用チェックが前提」と注記
