# Basic OP 要件トレーサビリティ・マトリクス

> このファイルは **Basic OP 認定要件 → 実装 → テスト → 既存タスク** の対応表（監査ハブ）です。
> 個別の改善内容はここでは詳述せず、既存タスクファイルへのポインタで管理します（重複記載回避）。
> 仕様の共通参照ハブとしても機能させ、他トピックファイルはこのファイルの「3. 関連する仕様・基準」を参照する前提で差分のみ書きます。

## 1. タイトル

OpenID Connect Basic OP（Basic OpenID Provider）認定プロファイルの全要件に対する、本リポジトリ実装の充足状況トレーサビリティ。

## 2. このトピックで確認したいこと

- 「Basic OP」とは何か、対象範囲を一次情報で正しく定義する
- Basic OP 認定（OpenID Connect Conformance Profiles v3.0）の各テスト項目に対し、本リポジトリの実装が満たしているかを一覧で機械的に判定する
- 充足していない／確認が必要な項目について、既存タスクで追跡済みか、未追跡かを明示する
- 未追跡の要件があれば、新しいトピックファイルの作成根拠とする

## 3. 関連する仕様・基準（共通参照ハブ）

### 3.1 Basic OP の定義（補正済み）

「Basic OP」は OpenID Foundation の **OpenID Connect Conformance Profiles** で定義される OpenID Provider 認定プロファイルの一つ。`Basic OP` は **Authorization Code Flow（`response_type=code`）** のみを対象とし、Implicit/Hybrid を含まない最小プロファイル。

- 認定対象の中核仕様: **OpenID Connect Core 1.0 incorporating errata set 2** の Section 3.1（Authorization Code Flow）および **Section 15.1（Mandatory to Implement Features for All OPs）**
- 認定テスト体系: OpenID Connect Conformance Profiles v3.0（Basic OP は計46テスト、うち必須29、Warning/SHOULD 17。本リポジトリ同梱スキル `oidc-basic-op-certification` の集計に準拠）
- Discovery / Dynamic Registration は Basic OP の必須要件ではない（`Config OP` / `Dynamic OP` プロファイルの範疇）。ただし OIDF 公式 Conformance Suite は実運用上 Discovery/DCR を前提にしたテストプランが用意されている（→ `tasks/basic-op-conformance-verification-plan.md` 参照）

### 3.2 Section 15.1 の MUST 機能（全 OP 共通）

OpenID Connect Core 1.0 §15.1 が全 OP に MUST として課す機能:

- ID Token を **RS256** で署名できること（例外: Token Endpoint からのみ ID Token を返し、かつ全クライアントが `alg:none` 登録の場合のみ RS256 不要）
- `prompt` パラメータ（`none` / `login`）の UI 挙動
- `display` パラメータ（最低限: 未知値でもエラーにしない）
- `ui_locales` / `claims_locales`（最低限: エラーにしない）
- `max_age` の強制と `auth_time` の返却
- `acr_values`（最低限: エラーにしない）

### 3.3 参照のための仕様セクション索引

他トピックファイルはこの索引を参照し、同じ説明を繰り返さないこと。

| 領域 | 一次仕様 |
|---|---|
| Authorization Code Flow | OIDC Core 1.0 §3.1.2 / §3.1.3 |
| ID Token | OIDC Core 1.0 §2, §3.1.3.6, §3.1.3.7 |
| UserInfo | OIDC Core 1.0 §5.3 |
| sub / subject identifier | OIDC Core 1.0 §2, §8 |
| Request Object | OIDC Core 1.0 §6 |
| 必須機能 | OIDC Core 1.0 §15.1 |
| Discovery | OpenID Connect Discovery 1.0 §3 / RFC 8414 §2 |
| PKCE | RFC 7636 / OAuth 2.1 §4.1.1, §7.5 |
| Refresh Token | OAuth 2.1 §4.3, §6 / RFC 6749 §6 |
| Bearer Token | RFC 6750 |
| iss authz response | RFC 9207 |
| 認可サーバメタデータ | RFC 8414 |
| Security BCP | RFC 9700（OAuth 2.0 Security Best Current Practice / BCP 240） |

## 4. 参照資料

- OpenID Connect Core 1.0 incorporating errata set 2 — https://openid.net/specs/openid-connect-core-1_0.html （§3.1, §15.1 を Basic OP 要件の根拠とする）
- OpenID Connect Discovery 1.0 — https://openid.net/specs/openid-connect-discovery-1_0.html
- OpenID Certification — https://openid.net/certification/ （Basic OP プロファイルの公式位置づけ）
- OpenID Conformance Suite — https://www.certification.openid.net/ （実行体系）
- 同梱スキル `oidc-basic-op-certification`（`.claude/skills/oidc-basic-op-certification/`、46テストの内訳の出典）
- OAuth 2.1 draft（draft-ietf-oauth-v2-1） — https://datatracker.ietf.org/doc/draft-ietf-oauth-v2-1/

## 5. 現在の実装確認

実装の全体マップは下記に存在する（領域→ファイル）:

- Authorization Endpoint: `packages/core/src/authorization-request.ts`、`packages/sample/src/oidc-provider/routes/authorize.ts`
- Token Endpoint: `packages/core/src/token-request.ts` / `token-response.ts`、`routes/token.ts`
- Client Authentication: `packages/core/src/client-auth.ts`
- ID Token: `packages/core/src/id-token.ts`
- UserInfo: `packages/core/src/userinfo.ts`、`routes/userinfo.ts`
- JWKS: `packages/core/src/jwks.ts`、`routes/jwks.ts`
- Discovery: `packages/core/src/discovery.ts`、`routes/discovery.ts`
- Refresh/Revocation/Introspection: `token-request.ts` / `revocation.ts` / `introspection.ts`

## 6. 現在の実装との差分（要件トレーサビリティ・マトリクス）

凡例: ✅ 充足 / 🟡 充足だが確認推奨 / 🔴 不足 / 📌 既存タスクで追跡中（ファイル名）/ 🆕 未追跡（新規ファイル化対象）

### 6.1 Response Type & Mode

| テスト | 要件 | 状態 | 根拠 / 追跡 |
|---|---|---|---|
| OP-Response-code | `response_type=code` 対応 | ✅ | `authorization-request.ts`（code のみ許可） |
| OP-Response-Missing | response_type 欠如を拒否 | ✅ | 同上（`invalid_request`） |

### 6.2 ID Token

| テスト | 要件 | 状態 | 根拠 / 追跡 |
|---|---|---|---|
| IdToken.verify() | iss/sub/aud/iat/exp | ✅ | `id-token.ts`、`token-response.ts` |
| OP-IDToken-Signature | 署名済み | ✅ | RS256/ES256 署名実装 |
| OP-IDToken-RS256 | RS256 対応 | ✅ | 📌 `done/T-016-rs256-enforcement.md`（鍵存在検証済） |
| OP-IDToken-kid | kid ヘッダ | ✅ | `id-token.ts`（kid 任意付与）、JWKS と整合 |
| sub の安定性（§2/§8） | sub は安定・再割当不可 | 🟡 | 🆕 `tasks/sub-stability-and-subject-types.md` |

### 6.3 UserInfo

| テスト | 要件 | 状態 | 根拠 / 追跡 |
|---|---|---|---|
| OP-UserInfo-Endpoint | エンドポイント存在 | ✅ | `userinfo.ts` |
| OP-UserInfo-Header | Authorization ヘッダ | ✅ | Bearer 抽出実装 |
| OP-UserInfo-Body | form body | ✅ | 📌 `done/p2-userinfo-post-form-body.md` |
| OpenIDSchema.verify() | sub 必須 | ✅ | 常に sub を返却 |
| OP-UserInfo-RS256 | 署名応答 | ✅ | 📌 `done/p2-userinfo-signed-response.md` 他 |
| Cache-Control | キャッシュ抑止 | 🔴 | 📌 `tasks/p0-userinfo-cache-control.md` |

### 6.4 Nonce / Scope / Display / Prompt

| テスト | 要件 | 状態 | 根拠 / 追跡 |
|---|---|---|---|
| OP-nonce-NoReq-code | nonce 無しでも code flow 可 | ✅ | nonce は任意 |
| OP-nonce-code | nonce を ID Token に反映 | ✅ | `token-response.ts` |
| OP-scope-*（profile/email/address/phone/All） | スコープでエラー無し | ✅ | `userinfo.ts` SCOPE_CLAIMS_MAP |
| OP-display-page/popup | display でエラー無し | ✅ | 受理（無視）。値検証は 📌 `tasks/p2-display-param-validation.md` |
| OP-prompt-login | 再認証強制 | ✅ | 📌 `done/03-prompt-login.md` |
| OP-prompt-none-* | 未ログイン時エラー / ログイン時継続 | ✅ | 📌 `done/02-prompt-none.md` 他 |

### 6.5 Misc Request Params

| テスト | 要件 | 状態 | 根拠 / 追跡 |
|---|---|---|---|
| OP-Req-max_age | max_age 強制 + auth_time | ✅ | 📌 `done/04-max-age-enforcement.md` |
| OP-Req-NotUnderstood | 未知パラメータ無視 | ✅ | 仕様通り無視 |
| OP-Req-login_hint / ui_locales / claims_locales / acr_values | エラー無し | ✅ | 受理（未処理だがエラー無し＝§15.1 最低要件充足） |
| `acr_values` の `AcrResolver` 伝播（§15.1 超過の拡張整合性） | `acr_values` を ID Token `acr` 発行に反映 | 🟡 | 📌 `tasks/p2-acr-values-request-propagation.md`（検討: `study-material/done/acr-values-request-propagation-to-id-token.md`）。`acr_values` がコード→Token 経路で脱落し `requestedAcrValues` が常に undefined。`claims.id_token.acr.values` 経由のみ機能 |
| OP-Req-id_token_hint | SHOULD | ✅ | 📌 `done/T-017-id-token-hint-validation.md` / `done/p1-id-token-hint-verification-all-prompt-paths.md`。適用範囲は**全 prompt 経路**（prompt 無し / login / consent / select_account / none）。署名・iss・aud・exp・iat の検証は prompt=none 分岐の外で行い、hint の subject と一致しないセッションは SSO 再利用しない（不一致はログイン画面へ誘導、`login_required` 即返しは方針判断として保留） |
| Request Object（§6, request/request_uri） | 非対応なら拒否 + Discovery 明示 | 🔴 | 🆕 `study-material/request-object-rejection-and-discovery-honesty.md` |
| `registration` パラメータ（§3.1.2.1/§7.2.1） | 非対応なら `registration_not_supported` で拒否 | 🔴 | 🆕 `tasks/p3-registration-param-explicit-rejection.md`（検討: `study-material/done/unsupported-request-parameter-registration.md`） |

### 6.6 OAuth Behaviors / Redirect URI / Client Auth / Claims

| テスト | 要件 | 状態 | 根拠 / 追跡 |
|---|---|---|---|
| VerifyState() | state 返却 | ✅ | そのまま透過 |
| OP-OAuth-2nd-* | code 再利用検知 + 失効 | ✅ | 📌 `done/p0-token-revocation-on-code-reuse.md` |
| OP-redirect_uri-*（NotReg/Missing/Query/RegFrag） | 厳密一致・fragment 拒否 | ✅ | 📌 `done/p0-redirect-uri-fragment-rejection.md` |
| OP-ClientAuth-Basic/SecretPost-Static | basic/post 対応 | ✅ | 📌 `done/p0-client-authentication.md`（タイミング安全比較は 📌 `tasks/p0-client-secret-timing-safe-comparison.md`） |
| OP-claims-essential | claims パラメータ | ✅ | 📌 `done/p0-claims-id-token-support.md` |

### 6.7 Pre-Certification（環境要件）

| 項目 | 状態 | 根拠 / 追跡 |
|---|---|---|
| 全エンドポイント TLS | 🟡 | issuer の https 検証は `discovery.ts` にあり。conformance 実行時の公開 HTTPS 要件は 🆕 `tasks/basic-op-conformance-verification-plan.md` で扱う |
| RS256 鍵公開（JWKS） | ✅ | `jwks.ts` |
| クライアント静的登録 | 🟡 | DCR 非対応のため静的設定前提。verification-plan / 🆕 `tasks/extension-dynamic-client-registration.md` |

## 7. 改善・追加を検討する理由

- このマトリクス自体は実装変更ではなく **判断ハブ**。Basic OP 認定可否は散在するタスクではなく本表で機械的に追えるべき（`RELEASE-v0.x-scope.md` は戦略文書であり Conformance を v1.0 送りと宣言しているが、要件→実装の追跡表は別途必要）
- 本表により未追跡（🆕）の3トピック（sub安定性 / Request Object / 検証計画 + DCR）が特定された。これらは個別ファイル化済み

## 8. 実装方針の候補

このファイル自体に実装作業はない。運用方針の候補:

- A 案: 本表を「単一の真実」とし、各タスク完了時に本表の状態列を更新する運用にする
- B 案: 本表は監査スナップショットとして固定し、更新は四半期ごと等のレビュー時のみ

最終判断は人間が行う。

## 9. タスク案

- [ ] 本表の 🆕 行に対応する新規ファイル（4件）の内容をレビューする
- [ ] `RELEASE-v0.x-scope.md` の Tier 定義と本表を突き合わせ、v0.x ブロッカー（Tier A）と v1.0 条件（Tier B = Conformance）に各行を分類する
- [ ] 状態列の更新運用（A 案 / B 案）を決定する
- [ ] Basic OP 認定取得を実際に試みるフェーズで `basic-op-conformance-verification-plan.md` を実行する

## 10. Basic OP 認定外の配布運用メモ

dependency review、`pnpm audit`、Dependabot、npm Trusted Publishing の provenance 検証は、
OIDF Basic OP のプロトコル認定要件ではない。これらは npm 配布物と CI 依存の
サプライチェーン完全性を担保する独立の運用ゲートであり、認定可否の状態表には混在させない。
実装と確認手順は `.github/workflows/ci.yml`、`.github/dependabot.yml`、
`.github/workflows/release.yml`、`RELEASE.md` で管理する。
