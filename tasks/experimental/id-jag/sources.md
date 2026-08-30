# 参照資料: Identity Assertion Authorization Grant (ID-JAG) / Cross-App Access (XAA)

## Normative（一次資料・規範）

| タイトル | 発行元 | URL | 種別 | 参照セクション | 使用内容 | 確認日 | 仕様バージョン |
|---|---|---|---|---|---|---|---|
| Identity Assertion Authorization Grant | IETF OAuth WG | https://datatracker.ietf.org/doc/html/draft-ietf-oauth-identity-assertion-authz-grant-04 | Normative | §2.1（役割）、§3.1（ID-JAG クレームと typ）、§4.3（Token Exchange 要求と処理規則）、§4.3.4（応答、token_type N_A、refresh_token SHOULD NOT）、§4.4（jwt-bearer 要求、aud / client_id の MUST、refresh token SHOULD NOT と再提示）、§5（クライアント ID 対応付け）、§7（メタデータ 2 種）、§9.1（confidential 限定）、§9.3（同一ドメイン禁止）、§9.4（メタデータ開示制限）、§9.6（クレーム最小化）、§9.7（actor 拡張の未定義） | プロトコル全体。要求パラメータの必須性（audience REQUIRED を含む）、クレーム表、typ 値 `oauth-id-jag+jwt`、検証規則、メタデータ名と値 | 2026-08-30 | draft-04（2026-05、Expires 2026-11-22） |
| RFC 8693: OAuth 2.0 Token Exchange | IETF | https://datatracker.ietf.org/doc/html/rfc8693 | Normative | §2.1、§2.2.1、§2.2.2、§3 | 交換要求 / 応答の形式、issued_token_type、token_type N_A の由来、invalid_target の使いどころ、token type URN の体系 | 2026-08-30 | RFC 8693 |
| RFC 7523: JWT Profile for OAuth 2.0 Client Authentication and Authorization Grants | IETF | https://datatracker.ietf.org/doc/html/rfc7523 | Normative | §2.1、§3 | jwt-bearer grant の要求形式（grant_type / assertion）、JWT authorization grant の検証基準（iss / sub / aud / exp / 署名） | 2026-08-30 | RFC 7523 |
| RFC 7521: Assertion Framework for OAuth 2.0 | IETF | https://datatracker.ietf.org/doc/html/rfc7521 | Normative | §4.1、§5.2 | assertion 検証失敗時の `invalid_grant` エラー写像、一般処理規則（draft §4.4.1 が参照） | 2026-08-30 | RFC 7521 |
| RFC 8414: OAuth 2.0 Authorization Server Metadata | IETF | https://datatracker.ietf.org/doc/html/rfc8414 | Normative | §2 | issuer identifier の定義（audience パラメータと aud クレームの値）、メタデータ拡張の登録先 | 2026-08-30 | RFC 8414 |
| RFC 8725: JSON Web Token Best Current Practices | IETF | https://datatracker.ietf.org/doc/html/rfc8725 | Normative | §3.1、§3.8、§3.11 | 明示的 typ（`oauth-id-jag+jwt`）検証の根拠、alg none と外部鍵ヘッダの拒否、clock skew の目安（60 秒） | 2026-08-30 | RFC 8725 (BCP 225) |
| RFC 8707: Resource Indicators for OAuth 2.0 | IETF | https://datatracker.ietf.org/doc/html/rfc8707 | Normative | §2 | `resource` パラメータ / クレームの構文（絶対 URI、fragment 禁止） | 2026-08-30 | RFC 8707 |
| OpenID Connect Core 1.0 | OpenID Foundation | https://openid.net/specs/openid-connect-core-1_0.html | Normative | §2、§3.1.3.7 | subject_token として受ける ID トークンのクレーム構造と aud / azp 規則（検証は core の validateIdTokenHint に委譲） | 2026-08-30 | Core 1.0 incorporating errata set 2 |

## Informative（参考）

| タイトル | 発行元 | URL | 種別 | 使用内容 | 確認日 |
|---|---|---|---|---|---|
| Identity and Authorization Chaining Across Domains | IETF OAuth WG | https://datatracker.ietf.org/doc/html/draft-ietf-oauth-identity-chaining | Informative | ID-JAG draft が profile する上位パターン（Token Exchange + JWT Bearer の連鎖）の位置づけ確認。実装は ID-JAG draft の具体化のみに従う | 2026-08-30 |
| Cross-App Access 解説（Okta / Aaron Parecki） | Okta | https://www.okta.com/newsroom/articles/cross-app-access/ | Informative | XAA の名称とユースケース（AI エージェント、エンタープライズ SaaS）の背景理解。規範的判断には使用しない | 2026-08-30 |
| RFC 9396: Rich Authorization Requests | IETF | https://datatracker.ietf.org/doc/html/rfc9396 | Informative | `authorization_details` の非目標判断（本実装では明示拒否）の対象確認 | 2026-08-30 |
| RFC 9470: OAuth 2.0 Step-up Authentication Challenge Protocol | IETF | https://datatracker.ietf.org/doc/html/rfc9470 | Informative | draft §9.2 の step-up 応答の非目標判断の対象確認 | 2026-08-30 |

## セキュリティガイダンス

- ID-JAG draft §9（Security Considerations）を一次のセキュリティガイダンスとして採用。特に §9.1（confidential client 限定）、§9.3（同一ドメイン内利用の禁止）、§9.4（信頼関係のメタデータ開示禁止）、§9.6（subject 識別子の最小化）
- RFC 8725 §3.1 / §3.11 を JWS 受け入れ側の防御（alg none、外部鍵ヘッダ、typ による token confusion 対策）の根拠として採用
- draft §4.4.3 の「ID-JAG の再提示はリフレッシュトークンの代替」という設計を、jti リプレイストアを持たない判断の根拠として採用（specification.md のセキュリティ要件に記載）

## 相互運用性情報

- Okta が XAA（Cross App Access）として実装を発表しており（2025）、MCP / AI エージェント連携のデモが公開されている。draft は IETF OAuth WG の adopted document で、-04 まで改版が続いている。フィールド名は RFC 8693 / RFC 7523 の登録値を再利用しているため、これらに準拠する既存クライアントライブラリから原理的に接続可能
- draft 段階のため、実装間の相互運用実績は RFC 群（8693 / 7523）ほど成熟していない。experimental 隔離の根拠として specification.md に記載

## リポジトリ内参照

| パス | 使用内容 |
|---|---|
| `packages/experimental/src/token-exchange/token-exchange-request.ts` | 合成関数＋ステップ関数の構成、TokenExchangeError の設計（closed enum 回避）、オラクル排除の固定文言、public client 拒否の先例 |
| `packages/experimental/src/jarm/response-jwt.ts` | experimental 内での自前 compact JWS 署名（RS256 固定、SigningKey 契約、core 低レベル API 非依存）の先例 |
| `packages/core/src/id-token.ts`（`validateIdTokenHint` / `IdTokenHintError`） | 受信 JWS 検証の再利用元（署名、iss / aud / exp / iat、alg none、外部鍵ヘッダ拒否）。発行側の subject_token 検証はこれに委譲する |
| `packages/core/src/index.ts` | 依存する公開 API（validateIdTokenHint / generateRandomString / extractAlgorithmParamsFromJwk / selectSigningKeyByAlg など）の公開状況の確認 |
| `packages/cli/src/features.ts` | EXPERIMENTAL_FEATURES / OidcFeatureConfig / EXPERIMENTAL_FEATURE_KEYS の追加箇所 |
| `packages/cli/src/index.ts`（`withExperimentalPackage`） | experimental package の install 案内へ追加する箇所 |
| `packages/cli/src/frameworks/hono/templates.ts` | tokenExchangeDispatchStep（分岐挿入位置とバイト同一の条件付き補間）、tokenExchangeConformanceBlock / deviceAuthorizationConformanceBlock（conformance ブロックの書式）、discovery テンプレートの grantTypesSupported と experimental メタデータの追加位置 |
| `packages/cli/src/frameworks/web-standard/templates.ts` | toWebRouteTemplate によるトークンルート共有（分岐は hono テンプレート 1 箇所の変更で 5 ターゲットに反映）と conformance ブロックの並置箇所 |
| `samples/hono-cloudflare/src/oidc-provider/routes/token.ts` | 生成済みトークンルートの実物（分岐と catch 節の展開結果の確認） |
| `samples/hono-cloudflare/src/app.ts` | サンプル手書きエントリの env 読み込みパターン（ISSUER / OIDC_CLIENTS_JSON）。XAA env 追加の挿入先 |
| `tests/e2e/playwright.config.ts` | webServer 複数起動の構成（2 インスタンス目の OP 追加先）、OIDC_CLIENTS_JSON の組み立て |
| `tests/e2e/specs/token-exchange.spec.ts` | 「実ブラウザでトークン取得＋spec からバックチャネル交換」のパターン（delegation テスト）。XAA spec が踏襲 |
| `tasks/experimental/done/token-exchange/specification.md` | 仕様書式、エラー表の書式、subject_token 無効時の invalid_request 写像の先例 |
| `study-material/ext-token-exchange-rfc8693.md` / `study-material/ext-jwt-bearer-authorization-grant-rfc7523.md` / `study-material/ext-oauth-identity-chaining-across-domains.md` | 関連仕様の既存調査メモ（候補評価の背景） |

## 二次資料

- Okta の XAA 解説記事は背景理解のみに使用した。本仕様の規範的判断はすべて draft-04 と上記 RFC 群、リポジトリ実装に基づく
