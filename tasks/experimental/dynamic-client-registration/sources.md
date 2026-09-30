# 参照資料: dynamic-client-registration

## Normative 一次資料

| タイトル | 発行元 | URL | 種別 | 参照セクション | 使用内容 | 確認日 | 仕様バージョン |
|---|---|---|---|---|---|---|---|
| RFC 7591: OAuth 2.0 Dynamic Client Registration Protocol | IETF | https://datatracker.ietf.org/doc/html/rfc7591 | Normative | §2, §2.1, §3.1, §3.2.1, §3.2.2, §5 | メタデータ語彙と既定値（token_endpoint_auth_method=client_secret_basic / grant_types=["authorization_code"] / response_types=["code"]）、未知メタデータの MUST ignore、POST + application/json の MUST、オープン登録の SHOULD、201 応答と登録済み全メタデータ返却の MUST、client_secret_expires_at=0 の意味、エラーコード（invalid_redirect_uri / invalid_client_metadata）、grant/response 整合の SHOULD、DoS の rate-limit MAY、リダイレクト系 grant の redirect_uris 登録 MUST | 2026-09-30 | Proposed Standard (2015-07) |
| OpenID Connect Dynamic Client Registration 1.0 | OpenID Foundation | https://openid.net/specs/openid-connect-registration-1_0.html | Normative | §2, §3.1, §3.2, §3.3 | redirect_uris REQUIRED、initial access token の MAY と「アクセストークンなしの登録を受けるべき（SHOULD）」、未知フィールドの MUST ignore、201 SHOULD、registration_access_token / registration_client_uri の「両方か両方なし」MUST、400 エラーとエラーコード、TLS 要求 | 2026-09-30 | incorporating errata set 2 |
| OpenID Connect Discovery 1.0 | OpenID Foundation | https://openid.net/specs/openid-connect-discovery-1_0.html | Normative | §3 | `registration_endpoint` メタデータの定義（有効時のみ広告する根拠） | 2026-09-30 | incorporating errata set 2 |
| RFC 6750: Bearer Token Usage | IETF | https://datatracker.ietf.org/doc/html/rfc6750 | Normative | §2.1, §3 | initial access token 構成時の Authorization: Bearer の読み取りと 401 + WWW-Authenticate 応答 | 2026-09-30 | - |

## Informative 一次資料

| タイトル | 発行元 | URL | 種別 | 参照セクション | 使用内容 | 確認日 | 仕様バージョン |
|---|---|---|---|---|---|---|---|
| RFC 7592: OAuth 2.0 Dynamic Client Registration Management Protocol | IETF | https://datatracker.ietf.org/doc/html/rfc7592 | Informative | 全体 | 非目標の確認（登録後の参照・更新・削除と registration_access_token を実装しない判断の根拠） | 2026-09-30 | Experimental (2015-07) |
| RFC 6585: Additional HTTP Status Codes | IETF | https://datatracker.ietf.org/doc/html/rfc6585 | Informative | §4 | U1（登録上限超過時の 429 案）の検討材料 | 2026-09-30 | - |
| RFC 9700: Best Current Practice for OAuth 2.0 Security | IETF | https://datatracker.ietf.org/doc/html/rfc9700 | Informative | §4 | 登録クライアントへの制約面（redirect_uri 検証・PKCE）を狭く保つ判断の背景 | 2026-09-30 | BCP 240 |

## セキュリティガイダンス

| タイトル | 発行元 | URL | 種別 | 使用内容 | 確認日 |
|---|---|---|---|---|---|
| RFC 7591 §5 Security Considerations | IETF | https://datatracker.ietf.org/doc/html/rfc7591#section-5 | Normative 内 | オープン登録の DoS（rate-limit MAY）、TLS 必須、URL 系メタデータの同一ホスト確認 SHOULD（v1 で URL 系を受理しない判断の背景）、同一シークレットを複数インスタンスへ発行しない SHOULD | 2026-09-30 |

## 相互運用性情報

- OIDF Conformance Suite は多くのテストプランで対象 OP への動的クライアント登録を前提とし、DCR 非対応 OP は静的クライアント設定のプランで実行する必要がある（`study-material/extension-dynamic-client-registration.md` と `study-material/ext-dynamic-client-registration.md` の確認結果を参照。仕様確定の根拠は一次資料に置く）。確認日 2026-09-30
- MCP（Model Context Protocol）の authorization 仕様は OAuth 2.1 ベースで、クライアントの接続時登録に DCR を推奨する（`study-material/ext-mcp-authorization-op-readiness.md`）。採用理由の「利用者の検証価値」の裏付けに使用。確認日 2026-09-30

## リポジトリ内参照

| パス | 使用内容 |
|---|---|
| `study-material/ext-dynamic-client-registration.md` | 候補評価の元資料。方針 A（core 検証 + 永続化注入)が昇格先の形になるという整理と、resolver 抽象により永続化を利用者責務へ切り出せる確認 |
| `study-material/extension-dynamic-client-registration.md` | Conformance Suite 連携の制約（動的登録前提プラン)と「広告していないし実装もしていない = 整合」の現状確認 |
| `study-material/ext-mcp-authorization-op-readiness.md` | MCP エコシステムでの DCR 需要（採用理由の裏付け） |
| `study-material/ext-dynamic-client-registration-management-rfc7592.md` | RFC 7592 を非目標とする判断の材料 |
| `packages/core/src/authorization-request.ts`（`ClientInfo`、110 行〜 / `validateRegisteredRedirectUris`、422 行〜 / `ClientResolver.findClient`、168 行） | 登録レコードが適合すべき core 型（responseTypes / grantTypes は既に定義済み）と、登録時に再利用する redirect_uri 検査規則（フラグメント・危険スキーム・非ループバック http の拒否）。`validateRegisteredRedirectUris` は `packages/core/src/index.ts:12` でエクスポート済み |
| `packages/core/src/token-request.ts`（`TokenClientInfo`、72 行〜） | clientSecret / grantTypes / tokenEndpointAuthMethod の型と既定の解釈（未指定は client_secret_basic、grant 未登録は unauthorized_client） |
| `packages/core/src/client-auth.ts`（209 行〜） | 登録済み token_endpoint_auth_method と提示方式の一致検証（登録された値が実際に効く場所の確認） |
| `packages/core/src/crypto-utils.ts`（`generateRandomString`、65 行〜 / `timingSafeEqual`、84 行〜） | client_id / client_secret の乱数生成（公開 API、`index.ts:157`）。timingSafeEqual は core 内部限定で公開されていないため、experimental 側に定数時間比較を持つ判断の根拠 |
| `packages/core/src/discovery.ts`（36, 95, 205-206 行） | core メタデータ型に registrationEndpoint / registration_endpoint が定義済みであることの確認（フィールド名の整合。生成コードは discovery スプレッドマージで追記する） |
| `packages/cli/src/features.ts`（`EXPERIMENTAL_FEATURES`、77〜86 行） | feature 追加先。現在の末尾は `'rp-initiated-logout'`（85 行） |
| `packages/cli/src/index.ts`（`withExperimentalPackage`、32〜46 行） | install コマンド案内へ experimental package を足す feature チェックの追加先 |
| `packages/cli/src/frameworks/hono/templates.ts`（discovery スプレッドマージ、7601 行周辺） | `registration_endpoint` 追記の挿入点。実装済み 8 機能が同じパターンを使用 |
| `packages/cli/src/frameworks/web-standard/templates.ts` | express / fastify / nextjs が共有するテンプレート。hono と同じ変更の展開先 |
| `packages/experimental/package.json` | 8 機能の subpath export 構成。`"./dynamic-client-registration"` 追加が既存パターンどおりであること。core は peerDependencies（`>=0.3.0 <1.0.0`） |
| `samples/hono-cloudflare/src/oidc-provider/config.ts`（`RegisteredClient`、184 行の `createInMemoryClientResolver`） | 登録レコードが適合すべき生成コード側の型と、静的 Map 解決の現状（動的ストアとの合成先） |
| `samples/hono-cloudflare/src/oidc-provider/store.ts`（`ProviderStores`、648 行 / `defaultProviderStores`、985 行） | 動的登録クライアント用ストアを追加する際の既存パターン |
| `samples/hono-cloudflare/package.json`（generate スクリプト、8 行） | 全機能有効サンプルへの `--enable dynamic-client-registration` 追加先 |
| `tasks/experimental/done/par/` | 「機械可読 JSON を受ける新規エンドポイント」の先例（実装規模とテンプレート構造の見積り根拠） |
| `tasks/T-019-dpop.md` | DPoP が core 変更前提の別タスクであることの確認（候補評価） |
| `study-material/ext-rich-authorization-requests-rfc9396.md` | RAR の隔離性評価（候補評価で見送る根拠） |

## 二次資料

- なし（仕様の確定はすべて一次資料とリポジトリ実装で行った。ブログ記事は根拠に使っていない）
