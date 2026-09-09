# 参照資料: JWT Response for OAuth Token Introspection (RFC 9701)

## Normative（規範的一次資料）

| タイトル | 発行元 | URL | 種別 | 参照セクション | 使用内容 | 確認日 | 仕様バージョン |
|---|---|---|---|---|---|---|---|
| RFC 9701: JWT Response for OAuth Token Introspection | IETF | https://www.rfc-editor.org/rfc/rfc9701 | Normative | §3 / §4 / §5 / §6 / §7 / §8.1 / §8.2 / §9 | 本機能の準拠仕様。要求方法（Accept ヘッダ）・JWT 構造（typ / iss / aud / iat / token_introspection・sub/exp の SHOULD NOT）・audience 判定の MUST・メタデータ・セキュリティ / プライバシー考慮の全て。本文全文を取得して規範文言を直接確認 | 2026-08-24（Review 2 の 2026-08-25 に §3 / §4 / §5 / §8 / §9 の規範文言を datatracker 版で再確認） | RFC 9701 (2025-01) |
| RFC 7662: OAuth 2.0 Token Introspection | IETF | https://www.rfc-editor.org/rfc/rfc7662 | Normative | §2.1 / §2.2 / §2.3 | `token_introspection` クレームに収める応答メンバーの定義。エラー応答形式（401 invalid_client）の既存挙動の根拠 | 2026-08-24 | RFC 7662 (2015-10) |
| RFC 7519: JSON Web Token (JWT) | IETF | https://www.rfc-editor.org/rfc/rfc7519 | Normative | §5.1 / §7.1 | typ ヘッダーの意味論と compact JWS への署名。RFC 9701 §5 が「cryptographically secured as specified in RFC7519」と参照 | 2026-08-24 | RFC 7519 (2015-05) |
| RFC 8414: OAuth 2.0 Authorization Server Metadata | IETF | https://www.rfc-editor.org/rfc/rfc8414 | Normative | §2 | `introspection_signing_alg_values_supported` の広告先（RFC 9701 §7 / §10.2 が登録） | 2026-08-24 | RFC 8414 (2018-06) |

## Informative（参考一次資料）

| タイトル | 発行元 | URL | 種別 | 参照セクション | 使用内容 | 確認日 |
|---|---|---|---|---|---|---|
| RFC 8725: JSON Web Token Best Current Practices | IETF | https://www.rfc-editor.org/rfc/rfc8725 | Informative | §3.10 / §3.11 | typ による明示的型付けと kid の実践。RFC 9701 §8.1 が JWT confusion の対策として参照 | 2026-08-24 |
| RFC 9700: Best Current Practice for OAuth 2.0 Security | IETF | https://www.rfc-editor.org/rfc/rfc9700 | Informative | アクセストークンリプレイ対策 | RFC 9701 §8.1 が RS 側の追加対策として MUST 参照。README の RS 向け注意に反映 | 2026-08-24 |
| RFC 7591: OAuth 2.0 Dynamic Client Registration Protocol | IETF | https://www.rfc-editor.org/rfc/rfc7591 | Informative | RFC 9701 §3 の引用箇所 | 「RS をクライアントとして登録する」構成の根拠（本 OP の採る形） | 2026-08-24 |

## リポジトリ内参照

| パス | 使用内容 |
|---|---|
| `study-material/ext-jwt-introspection-response-rfc9701.md` | 候補評価の下敷き。「導入しやすさ: 高」「JSON を JWT で包む差分に絞る」の評価と、候補 A（署名のみ・core 実装案）の記録。本仕様は候補 A の構成を experimental 隔離（core 無変更）へ読み替えた |
| `packages/core/src/introspection.ts` | `IntrospectionResponse` の形（`client_id`: 135 行 / `aud`: 143-144 行）。audience 制限が応答オブジェクトだけで判定できる根拠。`INACTIVE_INTROSPECTION_RESPONSE` の形 |
| `packages/core/src/index.ts:242` / `:246` / `:294` | `selectSigningKeyByAlg` / `SigningKey` / `INACTIVE_INTROSPECTION_RESPONSE` が公開 API であることの確認（core 無変更の根拠） |
| `packages/core/src/token-response.ts:203` / `packages/core/src/authorization-request.ts:1109-1119` | `buildAccessTokenAudience` の合成規則（UserInfo エンドポイント URL の恒久メンバ化と `audience` パラメータ値の追加）。U1（`aud` の意味論）を確定した実地確認（Review 2） |
| `packages/cli/src/frameworks/hono/templates.ts:4993` 付近 | JWKS ルート（T-022）が `signingKeys` の公開鍵を kid 付き重複排除で公開する現物。RS がイントロスペクション JWT を JWKS で検証できる根拠（Review 2） |
| `packages/experimental/src/jarm/response-jwt.ts` | Web Crypto による compact JWS 自前実装・RS256 固定・kid 付与・「RS256 鍵であること」の引数契約の直接の先例。本機能の `createIntrospectionResponseJwt` はこの構造を踏襲する |
| `packages/cli/src/frameworks/hono/templates.ts:6231-6360` | `introspectionRouteTemplate` の現物。クライアント認証パイプライン → core ステップ群 → `c.json(response)` の応答出口（本機能の分岐挿入点）と catch 分岐（`server_error` への伝播先） |
| `packages/cli/src/frameworks/hono/templates.ts:290` | `c.set('signingKeys', ...)` が全ルート共通の `app.use('*')` ミドルウェアにあり、イントロスペクションルートから鍵セットを取得できる根拠 |
| `packages/cli/src/frameworks/hono/templates.ts:5306` 付近 | discovery 最終応答の `${parDiscoveryMetadata}${deviceDiscoveryMetadata}${jarmDiscoveryMetadata}` スプレッドマージ（`introspection_signing_alg_values_supported` の挿入点） |
| `packages/cli/src/frameworks/hono/index.ts:45` / `packages/cli/src/frameworks/web-standard/templates.ts:2459` | `introspectionRouteTemplate` の呼び出し 2 箇所（`features` 引数を渡す変更対象）。web-standard 側の `toWebRouteTemplate` が import 置換のみの薄い変換であること、`WebContext.text` が設定済み Content-Type を上書きしないことも同ファイルで確認 |
| `packages/cli/src/features.ts` | `EXPERIMENTAL_FEATURES` / `EXPERIMENTAL_FEATURE_KEYS` / `DEFAULT_FEATURES` / `resolveFeatures` の追加箇所。cross-feature 検証（introspection 依存）の挿入点 |
| `packages/cli/src/__tests__/par-feature.test.ts:112-114` | unknown-feature テストの期待メッセージが experimental 機能一覧の部分文字列を含む現物（`EXPERIMENTAL_FEATURES` へは末尾追加が安全である根拠） |
| `tasks/p3-introspection-caller-authorization-hook.md` | core への `canIntrospect` フック提案（未着手）。JSON 経路の呼び出し元認可はこのタスクの責務とし、本機能は JWT 経路に閉じる境界の根拠 |
| `tasks/experimental/done/jarm/` | 「既存応答の JWT 化」を experimental で実装した先例パケット。条件付き補間・バイト同一の完了条件・RS256 固定の設計判断の構成基準 |

## 二次資料

なし（ブログ記事等は使用していない。仕様確定はすべて上記の一次資料とリポジトリ実装による）。

## 記録（規範と設計判断の区別）

- **401 vs 400**: RFC 9701 §5 Note は認証なし呼び出しへ HTTP 400 を返す MUST を置くが、既存の共有クライアント認証パイプラインは RFC 7662 §2.3（RFC 6749 §5.2）に従い 401 を返す。両仕様の相違として仕様書「エラー応答」の節に明記し、本 OP は「認証なしにデータを開示しない」という MUST の実質を既存挙動で満たした上で 401 を維持する設計判断を採った
- **Accept のワイルドカード**: RFC 9701 §4 は「Accept ヘッダを application/token-introspection+jwt に設定する」とだけ定め、コンテントネゴシエーションの選好解決を規定しない。`*/*` を JWT と解釈しないのは後方互換（汎用クライアントの既定 Accept で応答形式が変わらないこと）を優先した設計判断
- **audience 制限の既定**: RFC 9701 §3 は判定方法を AS の裁量とする（「The AS has the discretion of how to fulfill this requirement」）。「発行先本人または aud 記載先」の既定は本仕様の設計判断で、`IntrospectionResponse` の既存メンバーだけで判定できる最小構成を選んだ
- **JSON 経路を変えない**: RFC 9701 は既存の RFC 7662 応答を廃止しない。audience 制限を JWT 経路に閉じるのは、既存利用者の互換維持と core フックタスクとの責務分離のための設計判断
- **RS256 固定**: RFC 9701 §6 の `introspection_signed_response_alg` 省略時既定が RS256。per-client alg 対応を持たない現状では固定値が既定と一致するため、クライアントメタデータ拡張を非目標とした
