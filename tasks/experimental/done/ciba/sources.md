# 参照資料: CIBA (Client-Initiated Backchannel Authentication) Poll Mode

## Normative（規範的一次資料）

| タイトル | 発行元 | URL | 種別 | 参照セクション | 使用内容 | 確認日 | 仕様バージョン |
|---|---|---|---|---|---|---|---|
| OpenID Connect Client-Initiated Backchannel Authentication Flow - Core 1.0 | OpenID Foundation | https://openid.net/specs/openid-client-initiated-backchannel-authentication-core-1_0.html | Final Specification | §4, §7.1, §7.1.1, §7.1.2, §7.2, §7.3, §10.1, §10.3.1, §11, §13, §14, §15 | 認証リクエストのパラメータ定義とヒント規則（one and only one）、auth_req_id のエントロピー（最低 128bit・推奨 160bit）と文字種（A-Z a-z 0-9 . - _）、Poll モードの grant URN と状態機械エラー語彙、slow_down の恒久 +5 秒、discovery/registration メタデータの REQUIRED/OPTIONAL、user_code の脅威モデル、login_hint の PII 性 | 2026-08-08（Review 2 で §7.3 / §11 / §13 / §14 / §15 の規範文言を 2026-08-09 に再確認。§13 のエラー語彙と HTTP ステータス、§11 の invalid_grant「issued to another Client」、§14 の「expired な id_token_hint を受理すべき」勧告が本仕様の記述と一致することを確認） | 1.0 Final (2021-09-01) |
| RFC 6749 - The OAuth 2.0 Authorization Framework | IETF | https://www.rfc-editor.org/rfc/rfc6749 | Proposed Standard | §3.1, §5.1, §5.2 | 未知パラメータの無視規則、エラー応答の JSON 形、トークン応答のキャッシュ禁止 | 2026-08-08 | RFC 6749 |
| OpenID Connect Core 1.0 | OpenID Foundation | https://openid.net/specs/openid-connect-core-1_0.html | Final | §2, §9 | ID トークンのクレーム規則（nonce は認証リクエストが運んだ場合のみ）、クライアント認証方式の語彙 | 2026-08-08 | 1.0 (errata set 2 相当のリポジトリ既存準拠に従う) |

## Informative（参考一次資料）

| タイトル | 発行元 | URL | 種別 | 参照セクション | 使用内容 | 確認日 | 仕様バージョン |
|---|---|---|---|---|---|---|---|
| RFC 8628 - OAuth 2.0 Device Authorization Grant | IETF | https://www.rfc-editor.org/rfc/rfc8628 | Proposed Standard | §3.4, §3.5 | ポーリング状態機械の先例比較（本リポジトリの device-authorization-grant 実装が準拠）。CIBA の規範ではない | 2026-08-08 | RFC 8628 |
| FAPI-CIBA Profile | OpenID Foundation | https://openid.net/specs/openid-financial-api-ciba.html | Final | 全体 | 非目標の境界確認（署名必須等は本機能の対象外）にのみ使用 | 2026-08-08 | 1.0 |

## リポジトリ内参照

| パス | 使用内容 |
|---|---|
| `tasks/experimental/done/device-authorization-grant/` | 直近の先例パケット。仕様書構成・ストア契約の注記（consume atomic・期限切れ掃除）・候補評価で CIBA を次サイクル候補として残した記録 |
| `packages/experimental/src/device-authorization-grant/store.ts` | ストア契約の書式先例（不透明キー注記・consume の atomic 要件・interval +5 の追跡） |
| `packages/experimental/src/device-authorization-grant/device-code-grant.ts:100-165` | ポーリング状態機械の実挙動（denied → access_denied + 即削除 / expired を slow_down より先に評価 / lastPolledAt の更新は slow_down・pending 経路のみ）。U3 確定と `lastPolledAt` 記述修正の根拠 |
| `packages/experimental/src/device-authorization-grant/verification.ts` | binding Cookie 方式（生値は Cookie・レコードは SHA-256 ハッシュ）・「セッションを確立するステップは binding で守る」原則・レコード単位ログイン失敗計数と残存面の注記。CIBA ログイントランザクション設計の直接の先例 |
| `packages/cli/src/frameworks/hono/templates.ts:5262-5335` 付近 | 既存 `/login` の CSRF（auth transaction 単位）と、ログイン成功時に新規 sessionId を発行する先例 |
| `packages/cli/src/frameworks/hono/templates.ts:1131` | セッション Cookie 属性（HttpOnly / Secure / SameSite=Lax）の先例 |
| `packages/cli/src/__tests__/par-feature.test.ts:112` | unknown-feature テストが `'ciba'` を未定義名の例に使っている（実装時に別名へ差し替えが必要になる根拠） |
| `packages/cli/src/frameworks/hono/templates.ts:4002` 付近 | deviceCodeDispatchStep。core の `validateGrantTypeSupported` より前に置く grant ディスパッチの実証済みパターン。catch 分岐は 4119 行付近、discovery 追記は 5003 行付近 |
| `packages/cli/src/frameworks/hono/templates.ts:3405` 付近 | `/device/login` の `authenticateUser` swap point。CIBA の UI ログインが踏襲する契約 |
| `packages/core/src/token-request.ts:464` | `TokenClientInfo.grantTypes` 既定が `['authorization_code']` であること（CIBA URN の明示登録が必要になる根拠） |
| `packages/core/src/crypto-utils.ts:65` | `generateRandomString(byteLength)` が Base64URL を返すこと（auth_req_id の文字種適合の根拠） |
| `packages/core/src/id-token.ts:276` / 365-372 | `validateIdTokenHint` が exp 切れを拒否すること（id_token_hint を初期スコープから外す根拠） |
| `packages/core/src/index.ts` | `extractClientCredentials` / `resolveAuthenticatedTokenClient` / `validateClientAuthMethod` / `verifyClientSecret` / `TokenClientInfo` / `validateIdTokenHint` の公開確認 |
| `packages/cli/src/features.ts` | `EXPERIMENTAL_FEATURES` / `OidcFeatureConfig` の追加箇所 |
| `packages/cli/src/frameworks/hono/templates.ts:511-515` | `RegisteredClient = ClientInfo & TokenClientInfo & { ... }` の既存交差型。`backchannelTokenDeliveryMode` を条件挿入する先（U4 確定の根拠） |
| `packages/experimental/src/par/par-request.test.ts:24` | `ClientInfo & TokenClientInfo` の交差型でクライアント型を拡張する先例（U4 確定の根拠） |
| `packages/experimental/src/token-exchange/token-exchange-request.ts:142-158` | `grantTypes` 未指定→`['authorization_code']` 既定・auth method `none` 拒否の実装先例。CIBA の検証順序 3〜4 が踏襲する形 |
| `packages/cli/src/index.ts:28-38` | `withExperimentalPackage` の feature チェック。`features.ciba` の追加が必要になる変更点（CLI オプション案・実装順序に反映） |
| `tasks/experimental/done/device-authorization-grant/specification.md` | 実装順序の節の構成先例（samples の `generate` スクリプトへの `--enable` 追加・バイト同一 diff の手順を含む） |
| `tasks/T-019-dpop.md` | 重複回避の確認（DPoP は別タスク） |

## 二次資料

なし（仕様の確定はすべて上記一次資料とリポジトリ実装で行った。ブログ記事は根拠に使用していない）。

## 記録（規範と設計判断の区別）

- **規範**: ヒントはちょうど 1 つ（§7.2 で違反は invalid_request の MUST）/ auth_req_id 最低 128bit・文字種制限（§7.3）/ slow_down は当該以後のすべてのリクエストで +5 秒（§11）/ クライアント認証は登録された方式で MUST（§7.1）/ discovery の `backchannel_token_delivery_modes_supported` と `backchannel_authentication_endpoint` は REQUIRED（§4）/ Poll の ID トークンに CIBA 固有クレーム不要（§10.3.1 の要求は Push 限定）
- **設計判断（仕様が余地を残す部分）**: 公開クライアント（auth method `none`）の `unauthorized_client` 拒否 / 非対応ヒント種別への `invalid_request` / `requested_expiry` のクランプ（§7.1 は MAY）/ 過剰ポーリングへ `invalid_request`（§11 の MAY）ではなく slow_down 方式で統一 / `maxPendingPerSubject` 上限と超過時 `invalid_request`（Review 2 で確定: §13 `access_denied` はフロー終端と誤読されるため不採用）/ denied レコードの access_denied 配信時削除（Review 2 で Device Grant 実装との一致を確認し確定）/ `backchannelTokenDeliveryMode` 未設定を poll とみなす / user_code・署名リクエスト・Ping/Push の非対応 / ログインフォームへのログイントランザクション（binding Cookie + CSRF + 失敗計数、TTL 600 秒固定）の常時適用（Review 2 追加。CIBA Core は AD 上のユーザー認証方法を対象外としており、これは仕様の対象外領域の実装判断）/ UI ログイン部品の CIBA 専用複製（U1、Review 3 で確定: バイト同一の完了条件と機能独立性を優先）/ `CibaClientInfo` 交差型と `RegisteredClient` への条件挿入（U4、Review 3 で確定: core 型変更なし）
- **仕様の対象外を実装で埋めた部分**: 認証デバイスへの到達手段と AD 上のユーザー認証方法（§7.1 が明示的に out of scope）→ OP ホストのブラウザ UI + 既存 `authenticateUser` 契約で実装
