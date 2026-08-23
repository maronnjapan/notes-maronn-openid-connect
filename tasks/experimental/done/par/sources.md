# 参照資料: Pushed Authorization Requests (PAR)

## Normative（規範的一次資料）

| タイトル | 発行元 | URL | 種別 | 参照セクション | 使用内容 | 確認日 | 仕様バージョン |
|---|---|---|---|---|---|---|---|
| RFC 9126: OAuth 2.0 Pushed Authorization Requests | IETF | https://datatracker.ietf.org/doc/html/rfc9126 | RFC (Proposed Standard) | §2.1, §2.2, §2.3, §4, §5, §6, §7.1〜7.5 | エンドポイント入出力・201 MUST・URN 形式・エントロピー MUST・単回使用 SHOULD・メタデータ・脅威モデル。Review 2 で追加確認: §2.2「request_uri MUST be bound to the client」（規範的 MUST）、§2.2 応答例の `Cache-Control: no-cache, no-store`、§4「An expired request_uri MUST be rejected as invalid」、§4 の UA リロード起因の重複許容 MAY（本実装は不採用）、§4 が認可エンドポイント側のエラーコードを規定しないこと | 2026-07-27 / 2026-07-28 | RFC 9126 (2021-09) |
| RFC 6749: The OAuth 2.0 Authorization Framework | IETF | https://datatracker.ietf.org/doc/html/rfc6749 | RFC | §2.3, §3.2.1, §4.1.2.1, §5.2 | PAR エンドポイントのクライアント認証規則（token endpoint と同一）とエラーレスポンス形式（error REQUIRED / error_description OPTIONAL / invalid_client 401）。§4.1.2.1 の「Redirection URI を検証できない場合は MUST NOT redirect」を解決失敗の非リダイレクト方針の根拠として使用。Review 2 で本文再精読済み | 2026-07-27 / 2026-07-28 | RFC 6749 (2012-10) |
| OpenID Connect Core 1.0 | OpenID Foundation | https://openid.net/specs/openid-connect-core-1_0.html | OIDF Final Spec | §3.1.2.6, §6.2, §6.3 | `invalid_request_uri` エラーコードの定義（"The request_uri in the Authorization Request returns an error or contains invalid data."）、「Redirection URI が invalid な場合 MUST NOT redirect」の原文、URL 形式 request_uri（非対応継続）の位置付け。Review 2 で §3.1.2.6 原文確認済み | 2026-07-27 / 2026-07-28 | 1.0 (incorporating errata set 2) |

## Informative（参考一次資料）

| タイトル | 発行元 | URL | 種別 | 参照セクション | 使用内容 | 確認日 | 仕様バージョン |
|---|---|---|---|---|---|---|---|
| RFC 9101: JWT-Secured Authorization Request (JAR) | IETF | https://datatracker.ietf.org/doc/html/rfc9101 | RFC | §10.2(d) | request_uri エントロピー要件の参照先（RFC 9126 §7.1 が参照）。PAR+JAR 併用は非目標のため詳細参照は昇格時 | 未精読（RFC 9126 内の引用のみ確認） | RFC 9101 (2021-08) |
| OAuth 2.0 Security Best Current Practice (RFC 9700) | IETF | https://datatracker.ietf.org/doc/html/rfc9700 | BCP | §4.1.3 | Review 2 で PAR 言及を全文検索して確認: 言及は §4.1.3 の 1 箇所のみで、「クライアント認証を伴う RFC 9101 / RFC 9126 で認可リクエストの出所と完全性を検証できる場合、AS は redirect URI を追加チェックなしで信頼して MAY」という文脈。**PAR の一般的な使用推奨（SHOULD/MUST）は存在しない**ため、採用理由の記述を「BCP でも推奨」から実態に合わせて修正した。規範根拠には使用していない | 2026-07-28 | RFC 9700 (2025-01) |
| FAPI 2.0 Security Profile | OpenID Foundation | https://openid.net/specs/fapi-security-profile-2_0-final.html | OIDF Final Spec | - | PAR 必須化の背景（採用理由・昇格判断の裏付け）。規範根拠には使用していない | 未精読 | 2.0 Final |
| RFC 8414: OAuth 2.0 Authorization Server Metadata | IETF | https://datatracker.ietf.org/doc/html/rfc8414 | RFC | - | `pushed_authorization_request_endpoint` 等のメタデータ登録先の枠組み | 未精読（RFC 9126 §5 経由） | RFC 8414 (2018-06) |

## リポジトリ内参照

| パス | 使用内容 | 確認日 |
|---|---|---|
| `packages/core/src/index.ts` | 再利用する公開 API（`authenticateClient`, `validateAuthorizationRequest`, `generateRandomString`, `ClientResolver`, `ValidateAuthorizationRequestOptions` 等）の公開状況 | 2026-07-27 |
| `packages/core/src/authorization-request.ts` (L36-76, L846-880) | `request_uri` が `request_uri_not_supported` で拒否される現状実装。前段フック設計の前提 | 2026-07-27 |
| `packages/core/src/discovery.ts` (L107, L252) | `request_uri_parameter_supported` の設定駆動と、メタデータへの追加フィールドマージ方針の判断材料 | 2026-07-27 |
| `packages/cli/src/features.ts` | `--enable/--disable` 機構と `AVAILABLE_FEATURES`。experimental カテゴリ追加の設計前提 | 2026-07-27 |
| `packages/cli/src/index.ts` / `generator.ts` | CLI オプション解釈と generator パイプライン | 2026-07-27 |
| `packages/cli/src/frameworks/hono/templates.ts` (L1524-2090 付近) | authorize ルートテンプレートの全体構造。挿入点 `const params = rawParams;`（L1725）、後続ステップが `params` を参照すること（L1745, L1759, L1762）、catch 節の redirectable 分岐（L2035-2089: `error.redirectUri` の有無で redirect / JSON / 内部 303 / HTML を切替）を Review 2 で精読 | 2026-07-27 / 2026-07-28 |
| `packages/cli/src/frameworks/web-standard/templates.ts` (L4-38, L2128) | hono の `authorizeRouteTemplate` を `toWebRouteTemplate`（Hono→WebRouter の文字列変換）で再利用していることの確認（U3 解決の根拠） | 2026-07-28 |
| `packages/cli/src/frameworks/{express,fastify,nextjs}/index.ts` | 各 generator が web-standard のテンプレートへ委譲していることの確認（U3 解決の根拠） | 2026-07-28 |
| `packages/core/src/authorization-request.ts` (L286-313, L853-888) | `AuthorizationError.redirectable`（`redirectUri` の有無）と `rejectUnsupportedRequestParams` が元 `params` の `request_uri` を拒否する挙動（前段フックで `params` 自体を差し替える必要性の根拠） | 2026-07-28 |
| `packages/cli/src/frameworks/hono/templates.ts` (L3065-3230 付近) | discovery テンプレートが `buildProviderMetadata` の戻り値をそのまま返す構造（PAR メタデータのスプレッド追加が core 無変更で可能なことの確認） | 2026-07-28 |
| `tasks/T-019-dpop.md` | 既存タスクとの重複回避の確認（DPoP とは独立） | 2026-07-27 |
| `packages/experimental/README.md` | experimental パッケージの現状（README のみ、package.json 未作成） | 2026-07-27 |
| `CLAUDE.md` | テスト規約・conformance.test.ts の契約テスト方針・依存ポリシー | 2026-07-27 |
| `packages/core/src/authorization-request.ts` (L21-42, L286-313) | `AuthorizationErrorCode` が closed な enum で `invalid_request_uri` を含まないこと（`PushedRequestUriError` を別クラスにし catch 分岐を追加する必要性の根拠）。`AuthorizationError` のコンストラクタが `sanitizeErrorDescription` を通すこと | 2026-07-29 |
| `packages/cli/src/frameworks/hono/templates.ts` (L1725-1727, L2034-2092) | `const params = rawParams;` が `try` ブロックの**前**にあること（前段フックを try 内へ移す必要性の根拠）。catch 節が `AuthorizationError` のみ分岐し、他の例外は 500 `server_error` に落ちること。`const params = rawParams;` は L2450（token endpoint）にもあるが authorize ハンドラ内では一意であること | 2026-07-29 |
| `packages/cli/src/frameworks/hono/templates.ts` (L1608-1613) | 生成コードのストアが `../store.js` からの import ＋ `c.get(...) ?? default` パターンで route 間共有されること（par.ts と authorize 間の parStore 共有パターンの実在確認） | 2026-07-29 |
| `packages/cli/src/index.ts` (L8-12, L185) | `INSTALL_COMMANDS` の構造（フレームワーク別の install 案内に `@maronn-openid-connect/experimental` を追加する対象箇所） | 2026-07-29 |
| `packages/cli/src/features.ts` (L63-105) | `resolveFeatures` が未知の機能名を throw すること（experimental カテゴリを追加しない限り `--enable par` はエラーになる = 現行 CLI との非互換が生じない前提の再確認） | 2026-07-29 |

## 二次資料

なし（仕様の確定に二次資料・ブログ記事は使用していない）。

## 記録

- RFC 9126 の規範的文言（201 MUST / request_uri in body MUST NOT / エントロピー MUST / 単回使用 SHOULD＋クライアント側 MUST / 有効期限「typically 5〜600秒」/ PAR時検証の MAY省略＋authorize時 MUST 検証）は 2026-07-27 に datatracker 本文から直接引用で確認した。
- **client_id 一致検証の規範根拠（Review 2 で最終化）**: RFC 9126 §2.2 に「The request_uri value MUST be bound to the client that posted the authorization request」という規範的 MUST があることを 2026-07-28 に原文で確認した。Review 1 時点の「純粋な設計判断」という記録を更新する: **紐付け要件自体は規範（§2.2 MUST）**であり、認可エンドポイントでクエリ `client_id` とレコードの `client_id` を比較するという**強制手段が実装判断**である（RFC は強制手段を規定しない）。
- **認可エンドポイント側のエラーコード（設計判断）**: RFC 9126 §4 は期限切れ request_uri の拒否を MUST とするが、返すエラーコードを規定しない。本仕様は OIDC Core §3.1.2.6 の `invalid_request_uri` を採用する（設計判断）。
- **解決失敗の非リダイレクト（設計判断）**: OIDC Core §3.1.2.6 は `invalid_request_uri` をリダイレクト返却可能なコードとして定義するが、本仕様は解決失敗を一律非リダイレクトとする。根拠は RFC 6749 §4.1.2.1 の「Redirection URI を検証できない場合 MUST NOT redirect」（不存在・不一致ケース）と、失敗種別によるオラクル化回避（期限切れケース）。意図的な逸脱として specification.md に明記した。
- **Cache-Control（Review 2 修正）**: RFC 9126 §2.2 の応答例は `Cache-Control: no-cache, no-store`。仕様書初版の `no-store` のみは誤りだったため修正した。
- **`invalid_request_uri` と core enum（Review 3 で確定）**: core の `AuthorizationErrorCode` は closed な enum で `invalid_request_uri` を含まない。core 無変更の制約下では `AuthorizationError` に相乗りできないため、`PushedRequestUriError` を専用クラスとし、生成コードの authorize catch 節に専用分岐を追加する（設計判断の帰結。2026-07-29 確認）。
- **前段フックの位置（Review 3 修正）**: 挿入点 `const params = rawParams;` はハンドラの `try` ブロックより前にあるため、Review 2 時点のスケッチ（この位置で解決処理を実行）では `PushedRequestUriError` が catch に届かず未処理例外（500）になる欠陥があった。解決処理を try 内先頭へ移し、`params` を `let` 宣言＋再代入する形へ修正した（2026-07-29）。
