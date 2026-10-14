# 参照資料: dynamic-client-registration

## Normative 一次資料

| タイトル | 発行元 | URL | 種別 | 参照セクション | 使用内容 | 確認日 | 仕様バージョン |
|---|---|---|---|---|---|---|---|
| RFC 7591: OAuth 2.0 Dynamic Client Registration Protocol | IETF | https://datatracker.ietf.org/doc/html/rfc7591 | Normative | §2, §2.1, §3.1, §3.2.1, §3.2.2, §5 | メタデータ語彙と既定値（token_endpoint_auth_method=client_secret_basic / grant_types=["authorization_code"] / response_types=["code"]）、未知メタデータの MUST ignore、POST + application/json の MUST、オープン登録の SHOULD、201 応答と登録済み全メタデータ返却の MUST、client_secret_expires_at=0 の意味、エラーコード（invalid_redirect_uri / invalid_client_metadata）、grant/response 整合の SHOULD、DoS の rate-limit MAY、リダイレクト系 grant の redirect_uris 登録 MUST、リクエスト例のパスが POST /register であること（Review 3 で U3 を /register に確定した根拠） | 2026-09-30（U3 の確認は 2026-10-14） | Proposed Standard (2015-07) |
| OpenID Connect Dynamic Client Registration 1.0 | OpenID Foundation | https://openid.net/specs/openid-connect-registration-1_0.html | Normative | §2, §3.1, §3.2, §3.3 | redirect_uris REQUIRED、initial access token の MAY と「アクセストークンなしの登録を受けるべき（SHOULD）」、未知フィールドの MUST ignore、201 SHOULD、registration_access_token / registration_client_uri の「両方か両方なし」MUST、400 エラーとエラーコード、TLS 要求 | 2026-09-30 | incorporating errata set 2 |
| OpenID Connect Discovery 1.0 | OpenID Foundation | https://openid.net/specs/openid-connect-discovery-1_0.html | Normative | §3 | `registration_endpoint` メタデータの定義（有効時のみ広告する根拠。完全な URL を広告するためパス名に相互運用要件がないことは U3 の確定材料。Review 3） | 2026-09-30（U3 の確認は 2026-10-14） | incorporating errata set 2 |
| RFC 6750: Bearer Token Usage | IETF | https://datatracker.ietf.org/doc/html/rfc6750 | Normative | §2.1, §3, §3.1 | initial access token 構成時の Authorization: Bearer の読み取りと 401 + WWW-Authenticate 応答。§3.1 の「認証情報を伴わないリクエストにエラーコードを含めない SHOULD NOT」（Review 2 で 401 応答を欠落＝コードなし / 提示失敗＝invalid_token の 2 形に確定した根拠） | 2026-10-07 | - |

## Informative 一次資料

| タイトル | 発行元 | URL | 種別 | 参照セクション | 使用内容 | 確認日 | 仕様バージョン |
|---|---|---|---|---|---|---|---|
| RFC 7592: OAuth 2.0 Dynamic Client Registration Management Protocol | IETF | https://datatracker.ietf.org/doc/html/rfc7592 | Informative | 全体 | 非目標の確認（登録後の参照・更新・削除と registration_access_token を実装しない判断の根拠） | 2026-09-30 | Experimental (2015-07) |
| RFC 6585: Additional HTTP Status Codes | IETF | https://datatracker.ietf.org/doc/html/rfc6585 | Informative | §4 | 登録上限超過時の 429 応答の根拠（Review 2 で U1 を 429 に確定） | 2026-10-07 | - |
| RFC 9700: Best Current Practice for OAuth 2.0 Security | IETF | https://datatracker.ietf.org/doc/html/rfc9700 | Informative | §4 | 登録クライアントへの制約面（redirect_uri 検証・PKCE）を狭く保つ判断の背景 | 2026-09-30 | BCP 240 |
| RFC 8628: OAuth 2.0 Device Authorization Grant | IETF | https://datatracker.ietf.org/doc/html/rfc8628 | Informative | §3.1 | 例示パス `/device_authorization` が生成テンプレートのルート名にそのまま使われていることの確認（ルート命名慣行の裏付け。Review 3 の U3 確定材料） | 2026-10-14 | - |

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
| `packages/core/src/authorization-request.ts`（`ClientInfo`、111 行〜 / `validateRegisteredRedirectUris`、377 行〜 / `ClientResolver.findClient`、175 行。Review 3 時点） | 登録レコードが適合すべき core 型（responseTypes / grantTypes は既に定義済み）と、登録時に再利用する redirect_uri 検査規則（フラグメント・危険スキーム・非ループバック http の拒否）。`validateRegisteredRedirectUris` は `packages/core/src/index.ts:11` でエクスポート済み |
| `packages/core/src/token-request.ts`（`TokenClientInfo`、30 行〜） | clientSecret / clientSecretHash / grantTypes / tokenEndpointAuthMethod の型と既定の解釈（未指定は client_secret_basic、grant 未登録は unauthorized_client） |
| `packages/core/src/client-auth.ts`（209 行〜） | 登録済み token_endpoint_auth_method と提示方式の一致検証（登録された値が実際に効く場所の確認） |
| `packages/core/src/crypto-utils.ts`（`generateRandomString`、65 行〜 / `timingSafeEqual`、84 行〜） | client_id / client_secret の乱数生成（公開 API、`index.ts:221`）。timingSafeEqual は core 内部限定で公開されていないため、experimental 側に定数時間比較を持つ判断の根拠 |
| `packages/core/src/discovery.ts`（36, 95, 205-206 行） | core メタデータ型に registrationEndpoint / registration_endpoint が定義済みであることの確認（フィールド名の整合。生成コードは discovery スプレッドマージで追記する） |
| `packages/cli/src/features.ts`（`EXPERIMENTAL_FEATURES`、59〜68 行） | feature 追加先。現在の末尾は `'rp-initiated-logout'`（67 行）。feature 名とキーの対応表は 197 行周辺 |
| `packages/cli/src/index.ts`（`withExperimentalPackage`、36〜48 行） | install コマンド案内へ experimental package を足す feature チェックの追加先 |
| `packages/cli/src/frameworks/hono/templates.ts`（discovery スプレッドマージ、7304〜7371 行周辺 / apply テンプレートの基底 clientResolver 配線、443〜453 行） | `registration_endpoint` 追記の挿入点（実装済み 8 機能が同じパターンを使用）と、動的ストア合成で包む基底 resolver（`options.clientResolver ?? ストレージ既定`）の実装位置 |
| `packages/cli/src/frameworks/web-standard/templates.ts` | express / fastify / nextjs が共有するテンプレート。hono のルートテンプレートを import して配線するため、新規ルートは hono 側で定義して web-standard の配線へ加える |
| `packages/cli/src/frameworks/db/`（`names.ts` / `wiring.ts`）と生成コードの `db/clients.ts`（`createSqlClientResolver` / `registerClient()`） | `--db sql` / `--db kv` の基底クライアント解決の実体。`registerClient()` は `hashClientSecret()` でシークレットをハッシュ保存する（昇格時の永続化先の確認。Review 3） |
| `packages/experimental/package.json` | 8 機能の subpath export 構成。`"./dynamic-client-registration"` 追加が既存パターンどおりであること。core は peerDependencies（`>=0.3.0 <1.0.0`） |
| `samples/hono-cloudflare/src/oidc-provider/config.ts`（`RegisteredClient`、133 行 / `createInMemoryClientResolver`、179 行） | 登録レコードが適合すべき生成コード側の型と、`--db` なし生成の静的 Map 解決（動的ストアとの合成先の一つ） |
| `samples/hono-cloudflare/src/oidc-provider/store.ts`（`ProviderStores`、687 行 / `defaultProviderStores`、1024 行 / `InMemoryPushedAuthorizationRequestStore`、1057 行とそのシングルトン登録、1097 行） | core ストア群は `--db` でバックエンドへ差し替わる一方、experimental ストア（PAR / Device / CIBA）は `--db` の有無に関わらず in-memory の globalThis シングルトンである先例（動的登録クライアント用ストアが倫うパターン。Review 3） |
| `samples/hono-cloudflare/src/app.ts`（`XAA_ALLOWED_AUDIENCES` の読み取り、28 / 68 行）と `tests/e2e/playwright.config.ts`（168 行） | sample 手書きコードが env を読んで `applyOidc` オプションへ渡し、E2E が起動時に注入する既存配線（DCR の上限・initial access token を E2E で検証する手段。Review 3） |
| `tests/e2e/specs/pushed-authorization-requests.spec.ts` | discovery ベースのスキップガードで全 sample 共通実行する E2E スペックの先例（DCR スペックの型） |
| コミット cb33342（2026-10-07）と 216b95b | CLI が生成していた契約テスト conformance.test.ts の廃止と、生成コード文字列を検査する CLI テストの削除。テスト計画を E2E 一本化へ改めた根拠（Review 3） |
| コミット 7ebde04 / 705068e（2026-10-10 / 10-11） | `--db sql` / `--db kv` の導入と全 sample の `--db` 化。resolver 合成とストア配置の記述を現行構造へ合わせた根拠（Review 3） |
| `samples/hono-cloudflare/package.json`（generate スクリプト、8 行） | 全機能有効サンプルへの `--enable dynamic-client-registration` 追加先 |
| `tasks/experimental/done/par/` | 「機械可読 JSON を受ける新規エンドポイント」の先例（実装規模とテンプレート構造の見積り根拠） |
| `tasks/T-019-dpop.md` | DPoP が core 変更前提の別タスクであることの確認（候補評価） |
| `tasks/p3-generated-scope-policy-prototype-key-guard.md` | プロトタイプ経路キーの入力を不活性に保つ懸念がプロジェクト内で既出であることの確認（未知フィールド除去を allowlist-pick 方式と定めた背景。Review 2） |
| `samples/hono-cloudflare/src/oidc-provider/config.ts`（`defaultRegisteredClients` の `clientId: 'example-client'`、145〜147 行） | 静的 client_id が人間の命名であることの確認（U2 の `dcr-` プレフィックスで名前空間を分ける判断の根拠。Review 2） |
| `study-material/ext-rich-authorization-requests-rfc9396.md` | RAR の隔離性評価（候補評価で見送る根拠） |

## 二次資料

- なし（仕様の確定はすべて一次資料とリポジトリ実装で行った。ブログ記事は根拠に使っていない）
