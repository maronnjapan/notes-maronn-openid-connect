# 参照資料: rar

## Normative 一次資料

| タイトル | 発行元 | URL | 種別 | 参照セクション | 使用内容 | 確認日 | 仕様バージョン |
|---|---|---|---|---|---|---|---|
| RFC 9396: OAuth 2.0 Rich Authorization Requests | IETF | https://datatracker.ietf.org/doc/html/rfc9396 | Normative | §2, §2.1, §2.2, §3, §3.1, §5, §6, §6.1, §7, §7.1, §9, §9.1, §9.2, §10, §11.3, §11.4, §12, §13, §14 | `type` REQUIRED と共通フィールドの型（§2 / §2.2）、同一 type の重複 MAY（§2）、`application/x-www-form-urlencoded` での単一パラメータ（§3）、scope との併存と merged set の同意表示 MUST（§3.1）、未知 type / 構造違反の MUST refuse と `invalid_authorization_details`（§5）、トークンリクエストでの指定と grant 許可チェック（§6。非目標の根拠）、型依存の比較が仕様外であること（§6.1。非目標の根拠）、トークン応答への MUST（§7）、enrichment は MAY（§7.1。非目標）、RS への伝達 MUST と手段の MAY（§9）、JWT AT claim は RECOMMENDED（§9.1。非目標）、introspection の top-level member MUST（§9.2）、`authorization_details_types_supported` / `authorization_details_types`（§10）、type の非参照解決（§11.3）、長大リクエストへの PAR 示唆（§11.4）、sanitize MUST と改ざん保護・RFC 8259 比較（§12）、機微データの漏えい防止と同意画面（§13）、エラーコードの登録先と使用場所（§14.6） | 2026-10-21 | Proposed Standard (2023-05) |

## Informative 一次資料

| タイトル | 発行元 | URL | 種別 | 参照セクション | 使用内容 | 確認日 | 仕様バージョン |
|---|---|---|---|---|---|---|---|
| FAPI 2.0 Security Profile | OpenID Foundation | https://openid.net/specs/fapi-security-profile-2_0-final.html | Informative | §5.3.2.2 NOTE 5 | RAR の位置づけの確認。「`scope` で表現しきれない認可には RAR の使用を推奨」は非規範ノートであり、要件化ではない（`study-material/ext-rich-authorization-requests-rfc9396.md` の「FAPI 2.0 が要件化」という記述の訂正根拠。採用理由の文言をこの実測に合わせた） | 2026-10-21 | Final (2025-02-22) |
| OpenID Connect Core 1.0 | OpenID Foundation | https://openid.net/specs/openid-connect-core-1_0.html | Informative | §3.1.2.1, §6.1, §6.2 | `prompt=none` と `consent_required` の意味（details に新規同意を課すポリシーの返し方）、Request Object 内パラメータの supersede 規則（`requestObjectClaims` 優先の根拠） | 2026-10-21 | incorporating errata set 2 |
| RFC 6749: The OAuth 2.0 Authorization Framework | IETF | https://datatracker.ietf.org/doc/html/rfc6749 | Informative | §4.1.2.1, §5.2 | 認可エンドポイントのエラーリダイレクト形式とトークンエンドポイントの 400 エラー形式（`invalid_authorization_details` を載せる器） | 2026-10-21 | - |

## セキュリティガイダンス

| タイトル | 発行元 | URL | 種別 | 使用内容 | 確認日 |
|---|---|---|---|---|---|
| RFC 9396 §12 Security Considerations / §13 Privacy Considerations | IETF | https://datatracker.ietf.org/doc/html/rfc9396#section-12 | Normative 内 | sanitize の MUST、改ざん保護に request object / PAR を使う示唆、RFC 8259 準拠の文字列比較（正規化しない）、機微データのログ・リファラ漏えい防止、同意画面でのデータ露出への注意 | 2026-10-21 / 2026-10-28（Review 2 で §12・§13 の MUST / 非規範の別を再確認） |

## 相互運用性情報

- IANA「OAuth Authorization Details Types」レジストリに型が登録されるが、RFC 9396 自体はどの型も定義しない。型の意味論は API プロファイル（Open Banking 等）側にあり、OP は型定義を注入する形にする判断の根拠。確認日 2026-10-21
- `invalid_authorization_details` は IANA OAuth Extensions Error Registry に登録済みで、使用場所は authorization endpoint と token endpoint（RFC 9396 §14.6）。確認日 2026-10-21

## リポジトリ内参照

| パス | 使用内容 |
|---|---|
| `study-material/ext-rich-authorization-requests-rfc9396.md` | 候補評価の元資料。方針 B / C の整理と、core 型拡張（昇格時の本筋）の見取り図。「FAPI 2.0 が要件化」の記述は一次資料の実測で訂正した |
| `apps/hono/src/oidc-provider/endpoints/authorize/steps/parse-request.ts` | `collectUniqueParams` が重複キーのみ拒否し未知パラメータを保持することの実測（`authorization_details` が受理経路に乗る根拠） |
| `packages/core/src/authorization-request.ts`（`REQUEST_OBJECT_OVERRIDE_KEYS` 1219 行、`rejectUnsupportedRequestParams`。2026-10-21 時点の main） | Request Object の固定キーに `authorization_details` が無く `effectiveParams` に現れないこと（`requestObjectClaims` から読む設計の根拠）、core が拒否する未知パラメータが `request` / `request_uri` / `registration` だけであること |
| `apps/hono/src/oidc-provider/features/feature.ts`（`Feature` 65〜103 行） | 利用できるフック（routes / discovery / context / config / token.grants / authorize.* / loginMethods）の確認。consent 表示と token 応答のフックが無く、所有ブロックと小さな base 変更で実現する判断の根拠 |
| `apps/hono/src/oidc-provider/endpoints/authorize/pipeline.ts`（`let params` 58 行、silent 経路 105〜117 行） | feature ブロックによる `params` 再代入の先例（PAR）と、prompt=none / SSO が同意を経ずにコードを発行する経路の実測（prompt 制御方式の根拠） |
| `apps/hono/src/oidc-provider/endpoints/authorize/steps/reuse-session.ts` | SSO の同意スキップが `consentResolver.hasConsent`（scope 単位）で決まり details を知らないことの実測（常時同意ポリシーの根拠） |
| `apps/hono/src/oidc-provider/endpoints/consent/steps/describe-consent-screen.ts` | `ConsentScreen` の現在の形（kind / csrfToken / scopes / clientId）。optional フィールド追加という base 変更 1 の対象 |
| `apps/hono/src/oidc-provider/endpoints/token/pipeline.ts`（`const tokenResponse` 119 行） | base 変更 2（`let` 化）の対象の実測 |
| `packages/cli/src/registry.ts`（`FEATURE_REGISTRY` 51〜68 行、`EXPERIMENTAL_FEATURES` 161 行） | CLI 統合の追加先と、既存 9 機能の登録形式 |
| `packages/experimental/src/id-jag/issue-id-jag.ts`（434 行）ほか | id-jag / token-exchange が `authorization_details` を明示拒否していることの実測（本機能との整合確認） |
| `tasks/T-019-dpop.md` / `tasks/experimental/done/*` | 候補の重複確認（DPoP は core タスクとして予約済み、実装済み 9 機能と非重複） |
| `packages/core/src/request-object.ts`（`parseRequestObject` 64〜101 行。2026-10-28 時点の main） | ペイロードを JSON デコードした `Record<string, unknown>` を返すことの実測（U3 の確定根拠） |
| `apps/hono/src/oidc-provider/endpoints/token/pipeline.ts`（dispatch 群 48〜66 行、発行・保存・ローテーション 90〜116 行） | feature grant dispatch と副作用ステップの順序の実測（`[reject-token-request-details]` の配置根拠） |
| `apps/hono/src/oidc-provider/endpoints/token/steps/respond-error.ts` | `TokenEndpointError` が応答全体を運び `respondTokenError` が素通しすることの実測（トークンエンドポイントの `invalid_authorization_details` の器） |
| `apps/hono/src/oidc-provider/features/par/steps/resolve-pushed-request.ts`（64 行） | `error.code as AuthorizationErrorCode` で enum 外コードを投げる先例（認可エンドポイントの `invalid_authorization_details` の投げ方） |
| `apps/hono/src/oidc-provider/features/refresh-token/steps/issue-refresh-token.ts`（73 行）と `config.ts`（`refreshTokenAbsoluteLifetime` 既定 7776000） | 絶対寿命が `originalIssuedAt` 起点で固定されることの実測（U1 の TTL 設計の根拠） |
| `packages/experimental/src/ciba/store.ts`（lazy eviction 133〜197 行） | in-memory ストアの書き込み時 lazy eviction の先例（U1 の掃除方式） |
| `apps/hono/src/oidc-provider/endpoints/login/steps/hand-off-to-consent.ts` / `discard-session-for-fresh-login.ts` | ログイン経路が常に consent へ hand-off し、prompt=consent がセッションを破棄しないことの実測（prompt 制御方式が max_age / 再認証系と干渉しないことの確認） |
| `apps/hono/src/oidc-provider/features/refresh-token/steps/decide-refresh-token-issuance.ts` ほか offline_access 参照箇所（core / apps を grep） | `offline_access` の付与が `prompt=consent` を前提条件にしていないことの確認（`consent` 付与が refresh token 発行条件を広げないことの根拠） |

## 二次資料

なし（仕様の確定はすべて一次資料とリポジトリ実装による）。
