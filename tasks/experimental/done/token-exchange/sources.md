# 一次資料・参照資料: OAuth 2.0 Token Exchange

## Normative（規範）一次資料

| タイトル | 発行元 | URL | 種別 | 参照セクション | 使用内容 | 確認日 | 仕様バージョン |
|---|---|---|---|---|---|---|---|
| RFC 8693: OAuth 2.0 Token Exchange | IETF | https://datatracker.ietf.org/doc/html/rfc8693 | RFC (Proposed Standard) | §1.1, §2.1, §2.2.1, §2.2.2, §3, §4.1, §4.4, §5 | grant type URN・必須/任意パラメータ・応答形式・`invalid_target`/`invalid_request` の使い分け・token type identifier・impersonation/delegation の区別・クライアント認証の注記・subject_token 検証の MUST | 2026-07-30 | RFC 8693 (2020-01) |
| RFC 6749: The OAuth 2.0 Authorization Framework | IETF | https://datatracker.ietf.org/doc/html/rfc6749 | RFC (Proposed Standard) | §3.2, §5.1, §5.2 | トークンエンドポイントのパラメータ重複禁止（複数 resource/audience 非対応の根拠）・成功/エラー応答形式・`unauthorized_client` | 2026-07-30（前サイクル PAR Review 2 で原文精読済み。本サイクルは該当セクションの再参照） | RFC 6749 (2012-10) |
| RFC 9068: JWT Profile for OAuth 2.0 Access Tokens | IETF | https://datatracker.ietf.org/doc/html/rfc9068 | RFC (Proposed Standard) | §2.2 | 発行するアクセストークンのクレーム構成（core の `buildAccessTokenPayload` が準拠。交換後トークンも同じ経路で発行） | 2026-07-30（リポジトリ実装経由の間接参照。core 実装のコメントで準拠を確認） | RFC 9068 (2021-10) |

## Informative（参考）一次資料

| タイトル | 発行元 | URL | 種別 | 参照セクション | 使用内容 | 確認日 | 仕様バージョン |
|---|---|---|---|---|---|---|---|
| RFC 9700: Best Current Practice for OAuth 2.0 Security | IETF | https://datatracker.ietf.org/doc/html/rfc9700 | BCP | 全文検索（"token exchange" / "8693"）、§2.2〜§2.3 | **RFC 8693 / Token Exchange への言及なしを確認（U1 解決）**。sender-constrained token・audience 制限の一般推奨（§2.2〜§2.3）は本仕様の設計と方向が一致するが Token Exchange 固有のガイダンスではないため、セキュリティ要件表の規範根拠には引用しない | 2026-07-31（Review 2 で原文確認） | RFC 9700 (2025-01) |
| RFC 7662: OAuth 2.0 Token Introspection | IETF | https://datatracker.ietf.org/doc/html/rfc7662 | RFC (Proposed Standard) | §2.2 | 交換後トークンが既存 introspection でそのまま検証できることの整合確認（`AccessTokenInfo` のフィールド対応） | 2026-07-30（リポジトリ実装経由の間接参照） | RFC 7662 (2015-10) |

## セキュリティガイダンス

| タイトル | 発行元 | URL | 種別 | 参照セクション | 使用内容 | 確認日 |
|---|---|---|---|---|---|---|
| RFC 8693 Security Considerations | IETF | https://datatracker.ietf.org/doc/html/rfc8693#section-5 | RFC 内セクション | §5, §2.1 注記 | scope 制限・寿命制限の推奨、クライアント認証省略時のトークン増幅リスク（confidential 限定の設計判断の根拠） | 2026-07-30 |

## 相互運用性情報

| 情報 | 内容 | 確認日 |
|---|---|---|
| 主要実装の存在 | Keycloak（token-exchange 機能）・Auth0（Custom Token Exchange）・Authlete が RFC 8693 ベースの交換を提供しており、クライアント側の相互運用検証先が存在する | 2026-07-30（採用理由の成熟度評価に使用。個別実装の挙動を仕様根拠にはしない） |

## リポジトリ内参照

| パス | 確認内容 | 確認日 |
|---|---|---|
| `packages/core/src/token-request.ts:389-417, 63-85` | `validateGrantTypeSupported` が未知 grant_type を `unsupported_grant_type` で拒否すること（分岐位置の根拠）/ `TokenClientInfo` の `grantTypes` / `tokenEndpointAuthMethod` フィールド（クライアント認可の判定材料） | 2026-07-30 |
| `packages/core/src/token-error.ts:7-13, 19-49` | `TokenErrorCode` が closed enum で `invalid_target` を含まないこと（`TokenExchangeError` 別クラスの根拠）/ `TokenError` がコンストラクタで `sanitizeErrorDescription` を通すこと | 2026-07-30 |
| `packages/core/src/userinfo.ts:52-83` | `AccessTokenInfo` のフィールド（sub / scope / clientId / expiresAt / grantId / iat / nbf / audience / issuer）。subject_token 解決と交換後トークン保存の両方の契約 | 2026-07-30 |
| `packages/core/src/access-token-issuer.ts:26-57` | `AccessTokenIssuer` / `AccessTokenIssuanceContext` の契約と JWT/opaque issuer の存在（発行は生成コード側で core 部品を使う設計の根拠） | 2026-07-30 |
| `packages/core/src/token-response.ts:169-206` | `buildAccessTokenAudience` の合成規則（UserInfo エンドポイントを aud の恒久メンバとして必ず含める・重複除去・非空フォールバック）。交換後トークンの aud 合成をこの関数へ委ねる設計の根拠（Review 1 指摘 1） | 2026-07-30 |
| `packages/core/src/userinfo.ts:423-436` | `validateUserInfoAudience` が `tokenInfo.audience` に期待値（UserInfo エンドポイント）が含まれることを要求する実装。交換後トークンが UserInfo で使える前提の根拠 | 2026-07-30 |
| `packages/core/src/index.ts` | 依存する core API（`TokenClientInfo` / `AccessTokenResolver` / `AccessTokenInfo` / `sanitizeErrorDescription` / `buildAccessTokenPayload` / `createJwtAccessTokenIssuer` / `createOpaqueAccessTokenIssuer`）の公開状況 | 2026-07-30 |
| `packages/cli/src/features.ts:36-78` | `EXPERIMENTAL_FEATURES` / `EXPERIMENTAL_FEATURE_KEYS` の既存機構（PAR で確立済み。機構変更不要の根拠） | 2026-07-30 |
| `packages/cli/src/frameworks/hono/templates.ts:2435-3070` | `tokenRouteTemplate` の構造: 重複パラメータ拒否（:2752-2775）・クライアント認証パイプライン終端（:2818）・`${grantTypeSupportedStep}`（:2825）・発行パイプライン（:2938-3045）・catch 節の `TokenError` 分岐（:3049-3066）。分岐挿入点と catch 分岐追加の根拠 | 2026-07-30 |
| `packages/cli/src/frameworks/hono/templates.ts:369-375, 429, 3415-3418, 7027-7028` | 登録クライアントの `grantTypes` 生成パターン / `accessTokenExpiresIn` デフォルト 3600 / discovery の `grantTypesSupported` 固定配列 / response_mode が query 固定であること（JARM 見送りの根拠） | 2026-07-30 |
| `packages/cli/src/frameworks/web-standard/templates.ts:2163` | token ルートが `toWebRouteTemplate(tokenRouteTemplate(...))` で全ターゲット共有であること（単一テンプレート変更で済む根拠） | 2026-07-30 |
| `packages/cli/src/frameworks/hono/templates.ts:6387-6500, 7297` | `parConformanceBlock(features)` が無効時に空文字列を返す conformance フラグメントとして実装され、`conformanceTestTemplate` の連結補間列（:7297）で挿入されていること。`tokenExchangeConformanceBlock` を同型・同位置に並置できる根拠（Review 1 残リスクの解消） | 2026-07-31 |
| `packages/cli/src/frameworks/web-standard/templates.ts:19-21, 2136` | web-standard 側の conformance テンプレートも hono の conformance フラグメントを import して同じ補間列で使用していること（token-exchange の conformance ブロックは両テンプレートへの補間が必要） | 2026-07-31 |
| `packages/cli/src/frameworks/hono/templates.ts:3022-3045` | 既存トークン発行の `accessTokenStore.set` が `claims`（OIDC Core 1.0 §5.5 の claims パラメータ）を保存していること。交換後トークンで `claims` を**継承しない**設計判断（Review 2 指摘 2）の比較対象 | 2026-07-31 |
| `packages/core/src/token-request.ts:71-77` | `TokenClientInfo.grantTypes` 未指定時の既定が `['authorization_code']` であること（未指定クライアントが交換 URN で常に `unauthorized_client` になる根拠） | 2026-07-31 |
| `tasks/experimental/done/par/` | 前サイクルの仕様・レビュー・実装記録。experimental 機構（features.ts / subpath export / バイト同一検証 / 専用エラークラス＋catch 分岐パターン）の先例 | 2026-07-30 |
| `tests/e2e/playwright.config.ts` | `oidcClientsJson` による E2E クライアント登録（`e2e-client` は confidential / `client_secret_post` / `grantTypes` 配列を持つ）と `webServer` env（`OIDC_CLIENTS_JSON` / `CLIENT_ID` / `CLIENT_SECRET`）の注入構造。U3（資格情報配置・クライアント登録の場所）の根拠 | 2026-08-01 |
| `tests/e2e/apps/client.mjs` | E2E 専用 confidential クライアントの構造（`/start-par` の追加パターン・`formPost` ヘルパ・`renderResult` の data-testid 描画・`/start` が `audience=resourceServerUrl` を送ること）。`/start-exchange` 追加方式の根拠 | 2026-08-01 |
| `tests/e2e/apps/resource-server.mjs:45-47` | introspection の `aud` に resource server URL が含まれることを要求する検証。audience 省略交換（subject 継承）で E2E が成立する根拠 | 2026-08-01 |
| `tests/e2e/specs/pushed-authorization-requests.spec.ts` | discovery 広告に基づく `test.skip` パターン（`--enable` なしサンプルでも共有 spec suite を green に保つ先例） | 2026-08-01 |
| `samples/hono-cloudflare/src/app.ts:27` | サンプル OP の登録クライアントが `OIDC_CLIENTS_JSON` 環境変数由来であること（E2E のためにサンプル `config.ts` の編集が不要な根拠） | 2026-08-01 |
| `samples/hono-cloudflare/src/oidc-provider/conformance.test.ts:1975-2009` | 生成 conformance テストが export された `parConfig` をテスト内で書き換えて復元するパターン（`tokenExchangeConfig.allowedTargets` の conformance 検証方式の先例） | 2026-08-01 |
| `tasks/T-019-dpop.md` | DPoP タスクとの重複がないことの確認（sender-constrained token であり交換とは直交） | 2026-07-30 |

## 二次資料

なし（ブログ記事等は仕様確定の根拠に使用していない）。

## 記録（規範根拠と設計判断の区別）

- **規範（RFC 8693）**: subject_token / subject_token_type は REQUIRED（§2.1）/ actor_token 存在時の actor_token_type は REQUIRED（§2.1）/ subject_token の検証は MUST（§2.1）/ invalid なトークンへのエラーは `invalid_request`（§2.2.2）/ resource・audience 拒否は `invalid_target` SHOULD（§2.2.2）/ 応答の access_token・issued_token_type・token_type は REQUIRED、expires_in は RECOMMENDED、scope は「要求と異なれば REQUIRED」（§2.2.1）
- **設計判断（本仕様）**: confidential client 限定（§2.1 の注記を根拠に RFC より強めた）/ scope 応答を常に含める / 交換後トークンの寿命を subject 残存期間で cap する / `grantId` 継承による失効連動 / subject_token を消費しない / audience・resource 省略時は subject の audience を継承 / 発行トークンの aud は既存トークンと同じ `buildAccessTokenAudience` で合成し UserInfo エンドポイントを恒久メンバとして含める / 解決失敗の固定 error_description（オラクル化防止）/ `allowedTargets` の空デフォルト / subject_token の `claims` パラメータメタデータを交換後トークンへ継承しない（認可時の同意対象を交換経由で広げない。Review 2 で明文化）/ 残存秒数の丸めは `subjectExpiresAt - Math.floor(now/1000)`（期限検証通過時に必ず 1 以上になる規則。Review 2 で明文化）
- **エラーコードの設計判断（Review 2 で明文化）**: 絶対 URI でない・fragment を含む `resource` は RFC 8693 §2.1 の構文 MUST 違反として `invalid_request` とし、`invalid_target` は §2.2.2 の「対象への発行を拒否する」ポリシー判定に限定する。RFC 8707 §2 は malformed な resource も `invalid_target` と定義するが、RFC 8693 は RFC 8707 を informative（draft 段階の OAUTH-RESOURCE）としてしか参照しておらず規範根拠にならないことを原文で確認した（2026-07-31）
- **RFC からの意図的制限**: `resource` / `audience` の複数指定非対応（RFC 8693 §2.1 は複数出現を許容するが、生成コードの重複パラメータ拒否（RFC 6749 §3.2 準拠）と両立しないため単一値限定。非目標として明示）
- **注意**: RFC 8693 §2.1 の複数出現許容と RFC 6749 §3.2 の重複禁止は、RFC 8693 が §2.1 で resource パラメータについて RFC 8707 (Resource Indicators) と同様の複数指定を想定していることに由来する。本リポジトリのトークンエンドポイントは全パラメータ一律で重複拒否しており、この一律拒否を token-exchange のためだけに緩めるのは既存エンドポイントの挙動変更（core 契約違反ではないが conformance 変更）になるため行わない
