# 参照資料: Device Authorization Grant

## Normative（一次資料・規範）

| タイトル | 発行元 | URL | 種別 | 参照セクション | 使用内容 | 確認日 | 仕様バージョン |
|---|---|---|---|---|---|---|---|
| RFC 8628: OAuth 2.0 Device Authorization Grant | IETF | https://datatracker.ietf.org/doc/html/rfc8628 | Normative | §3.1–3.5, §4, §5.1–5.7, §6.1 | フロー全体・エンドポイント・応答フィールド（device_code / user_code / verification_uri / verification_uri_complete / expires_in / interval）・grant URN・エラーコード 4 種と slow_down の +5 秒規則・interval 省略時の既定 5 秒・discovery メタデータ名 `device_authorization_endpoint`・user_code エントロピーと base-20 文字種・脅威モデル | 2026-08-05 | RFC 8628 (Proposed Standard, 2019-08) |
| RFC 6749: The OAuth 2.0 Authorization Framework | IETF | https://datatracker.ietf.org/doc/html/rfc6749 | Normative | §3.2.1, §5.1, §5.2 | デバイス認可エンドポイントのクライアント認証規則（RFC 8628 §3.1 が参照）・トークン応答の Cache-Control・エラー応答形式 | 2026-08-05 | RFC 6749 |
| OpenID Connect Core 1.0 | OpenID Foundation | https://openid.net/specs/openid-connect-core-1_0.html | Normative | §2, §3.1.3.3, §11 | ID トークンのクレーム規則（nonce は認可リクエストに含まれた場合のみ必須 → 本フローでは省略）・トークンエンドポイント成功応答への ID トークン付与・offline_access の許可条件 | 2026-08-05 | Core 1.0 incorporating errata set 2 |
| RFC 8414: OAuth 2.0 Authorization Server Metadata | IETF | https://datatracker.ietf.org/doc/html/rfc8414 | Normative | §2 | `device_authorization_endpoint` の登録先メタデータ（RFC 8628 §4 が登録） | 2026-08-05 | RFC 8414 |

## Informative（参考）

| タイトル | 発行元 | URL | 種別 | 使用内容 | 確認日 |
|---|---|---|---|---|---|
| OAuth 2.1 draft-ietf-oauth-v2-1 | IETF | https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1 | Informative | Device Grant は OAuth 2.1 本文に含まれず独立 RFC のまま有効であることの確認（削除対象は implicit / ROPC のみ） | 2026-08-05 |

## セキュリティガイダンス

- RFC 8628 §5（Security Considerations）を一次のセキュリティガイダンスとして採用。特に §5.1（user_code brute force と rate limiting）、§5.2（device_code entropy）、§5.4（remote phishing）、§5.6（non-confidential clients）
- OAuth 2.0 Security Best Current Practice（RFC 9700）には Device Grant 固有の追加要件は無いことを確認（2026-08-05）

## 相互運用性情報

- Google（TV and Limited-Input Device apps）、Auth0（Device Authorization Flow）、Keycloak（`urn:ietf:params:oauth:grant-type:device_code` 対応）、Microsoft Entra ID（device code flow）が RFC 8628 準拠実装を提供しており、フィールド名・エラーコードの相互運用実績は十分に成熟している。本仕様は RFC 登録値のみを使うため、これら実装のクライアントライブラリからも原理的に接続可能

## リポジトリ内参照

| パス | 使用内容 |
|---|---|
| `packages/cli/src/frameworks/hono/templates.ts:3106-3216` | tokenExchangeDispatchStep / catch 節 — token ルートへの grant 分岐の実証済みパターン（本機能の分岐が踏襲する型） |
| `packages/cli/src/frameworks/hono/templates.ts:4183-4375` | loginRouteTemplate — OP セッション確立（`browserSessionStore` + `buildSessionCookie`）・`authenticateUser` swap point・views 契約の UI ルートパターン |
| `packages/cli/src/frameworks/web-standard/templates.ts` | hono テンプレートの変換共有（express / fastify / nextjs への展開経路） |
| `packages/experimental/src/par/store.ts` | ストア契約の書式・atomic consume・キーのパラメータ化注意書き（DeviceAuthorizationStore が踏襲） |
| `packages/core/src/authorization-request.ts:997-1028` | `validateAuthorizationScope` — scope 必須・openid 必須のプロファイル規則の出典 |
| `packages/core/src/crypto-utils.ts:65` | `generateRandomString` — device_code / CSRF トークンの生成手段 |
| `packages/cli/src/features.ts` | EXPERIMENTAL_FEATURES / OidcFeatureConfig — feature フラグの追加箇所 |
| `tasks/experimental/done/{par,token-exchange,jarm}/` | 過去サイクルの仕様書式・候補評価の経緯（JARM サイクルで本機能が次サイクル有力候補と明記） |
| `tasks/T-019-dpop.md` | DPoP は core 側タスクとして進行中 → experimental 候補から除外する根拠 |
| `packages/cli/src/frameworks/hono/templates.ts:527-600` | transaction-binding Cookie ヘルパー群と設計コメント — 「識別子を知るだけの第三者が csrf_token を読める」問題の既存分析と、生値 Cookie + ハッシュ保存・SameSite=Lax・Max-Age=TTL のパターン（device 検証 UI のバインディングが踏襲。Review 2 で参照） |
| `packages/core/src/auth-transaction.ts` | `computeTransactionBindingHash` / `validateTransactionBinding` — バインディングのハッシュ照合が core 公開 API として確立していることの確認（Review 2 で参照） |
| `tasks/p2-login-attempt-throttling-subject-scope.md` | subject 単位ログイン試行スロットリングの既存タスク — `/device/login` 経由の資格情報総当たりの残存面を既存 `/login` と同一水準として扱い、同タスクの対象に含める根拠（Review 2 で参照） |
| `tasks/p3-csrf-token-constant-time-comparison.md` | CSRF トークン定数時間比較の既存タスク — csrf_token 直接比較の水準を既存 login / consent と揃え、同タスクの適用範囲に本機能を含める根拠（Review 2 で参照） |
| `packages/cli/src/frameworks/hono/templates.ts:24-48` | `OIDC_ENDPOINT_METHODS` と `enforceOidcEndpointMethod` — 許可メソッドマップの実名・feature 条件付き補間（`parMethod`）の実例・405/Allow の conformance ケース表（:7601-7615）（Review 3 で参照） |
| `packages/cli/src/index.ts:21-31` | `withExperimentalPackage` — experimental feature 選択時のみ install guidance へ experimental package を挿入するハードコード feature チェック。本機能追加時の変更必須箇所（Review 3 で参照） |
| `packages/cli/src/index.ts:55-75` | CLI コマンドは `generate` / `setup` の 2 つのみ（`install` は存在しない）。ヘルプの experimental 一覧は `EXPERIMENTAL_FEATURES.join` から自動導出（Review 3 で参照） |
| `tests/e2e/apps/client.mjs` | E2E 専用クライアント — Node 組み込みのみの HTTP サーバーに `/start-par` / `/start-exchange` / `/start-jarm` の機能別ルートを足す既存パターン（`/start-device` が踏襲）（Review 3 で参照） |
| `samples/hono-cloudflare/package.json:8` | `generate` スクリプトの `--enable` フラグ列 — サンプル再生成時に `--enable device-authorization-grant` を追記する箇所と、バイト同一確認に使う既存有効フラグの組み合わせ（Review 3 で参照） |
| `packages/cli/src/frameworks/hono/templates.ts:6358-6360` | transaction-binding conformance テストの Set-Cookie 属性固定検証（`HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=<TTL>` の endsWith 検証）— バインディング Cookie の属性検証が踏襲する書式（Review 3 で参照） |
| `tasks/experimental/done/jarm/specification.md` | 承認済み仕様の「実装順序」節の書式 — 本仕様の実装順序節が踏襲（Review 3 で参照） |

## 二次資料

- なし（本仕様の規範的判断はすべて上記一次資料とリポジトリ実装に基づく。ブログ記事は参照していない）
