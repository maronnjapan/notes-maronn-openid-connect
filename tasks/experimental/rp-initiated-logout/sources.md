# 参照資料: rp-initiated-logout

## Normative 一次資料

| タイトル | 発行元 | URL | 種別 | 参照セクション | 使用内容 | 確認日 | 仕様バージョン |
|---|---|---|---|---|---|---|---|
| OpenID Connect RP-Initiated Logout 1.0 | OpenID Foundation | https://openid.net/specs/openid-connect-rpinitiated-1_0.html | Normative | §1〜§3, §7 | エンドポイント定義、パラメータ、client_id と aud の一致 MUST、確認画面の MUST、リダイレクト完全一致 MUST NOT、state 返却、GET/POST 両対応 MUST、discovery `end_session_endpoint`、クライアントメタデータ `post_logout_redirect_uris`、DoS 考慮 | 2026-09-09、2026-09-16（Review 2 で §2・§3・Security Considerations の逐語を再取得し、U1 確定とセキュリティ表の照合に使用） | Final (2022-09-12) |
| OpenID Connect Core 1.0 | OpenID Foundation | https://openid.net/specs/openid-connect-core-1_0.html | Normative | §2, §3.1.3.7 | ID Token のクレーム定義（aud / azp / sub）と検証規則。`validateIdTokenHint` の検証根拠 | 2026-09-09 | incorporating errata set 2 |
| OpenID Connect Discovery 1.0 | OpenID Foundation | https://openid.net/specs/openid-connect-discovery-1_0.html | Normative | §3 | メタデータ公表の枠組み（`end_session_endpoint` は RP-Initiated Logout §2.1 が定義） | 2026-09-09 | incorporating errata set 2 |

## Informative 一次資料

| タイトル | 発行元 | URL | 種別 | 参照セクション | 使用内容 | 確認日 | 仕様バージョン |
|---|---|---|---|---|---|---|---|
| OpenID Connect Session Management 1.0 | OpenID Foundation | https://openid.net/specs/openid-connect-session-1_0.html | Informative | 全体 | 非目標の確認（check_session_iframe / session_state を実装しない判断の根拠） | 2026-09-09 | Final |
| OpenID Connect Front-Channel Logout 1.0 | OpenID Foundation | https://openid.net/specs/openid-connect-frontchannel-1_0.html | Informative | 全体 | 非目標の確認（sid クレーム発行を保留する判断の根拠） | 2026-09-09 | Final |
| OpenID Connect Back-Channel Logout 1.0 | OpenID Foundation | https://openid.net/specs/openid-connect-backchannel-1_0.html | Informative | 全体 | 非目標の確認（logout_token 伝播を実装しない判断の根拠） | 2026-09-09 | Final |
| RFC 6749: The OAuth 2.0 Authorization Framework | IETF | https://www.rfc-editor.org/rfc/rfc6749 | Informative | §10.15 | オープンリダイレクタ回避の一般原則（redirect_uri 完全一致と同型の判断） | 2026-09-09 | - |

## セキュリティガイダンス

| タイトル | 発行元 | URL | 種別 | 使用内容 | 確認日 |
|---|---|---|---|---|---|
| RP-Initiated Logout 1.0 §7 Security Considerations | OpenID Foundation | https://openid.net/specs/openid-connect-rpinitiated-1_0.html | Normative 内 | 有効な id_token_hint のないログアウト要求の DoS 性と確認要求 | 2026-09-09 |

## 相互運用性情報

- Keycloak / Auth0 など主要実装は有効な `id_token_hint` があるとき確認画面を省略する。本仕様書の判定規則 3（SHOULD からの逸脱）の妥当性確認に使用（一般に知られた挙動としての参照であり、仕様確定の根拠は一次資料の MUST / SHOULD 構造に置く）。確認日 2026-09-09

## リポジトリ内参照

| パス | 使用内容 |
|---|---|
| `study-material/ext-rp-initiated-logout.md` | 候補評価の元資料。方針 A（段階導入）と既存実装の確認結果 |
| `packages/core/src/id-token.ts`（`validateIdTokenHint`、276 行〜） | ヒント検証の既存 core 公開 API。exp 超過拒否の確認（非目標「期限切れヒント」の根拠） |
| `packages/core/src/authentication-session.ts` | セッション契約と online refresh token の失効機構（非目標「トークン後始末」の境界根拠） |
| `packages/core/src/token-response.ts`（`buildIdTokenAudience`、239 行〜） | ID Token の aud / azp 合成ポリシー。追加 audience 構成時に aud 配列 + azp を発行することの確認（U2 確定の根拠。確認日 2026-09-16） |
| `packages/cli/src/frameworks/hono/templates.ts`（Device verification の binding cookie 設計コメント、3745 行〜） | 確認画面 POST の CSRF 防御モデル（cookie + hidden token の対）の先例（Review 2 で参照） |
| `packages/cli/src/frameworks/hono/templates.ts` | `SESSION_COOKIE_NAME` / browser session store の `delete`（1429・1447 行）、Device verification UI（3700 行〜）、CIBA UI、CSRF cookie 精度、discovery スプレッドマージ（6981 行）、views インターフェース（8313 行〜） |
| `packages/cli/src/features.ts` | `EXPERIMENTAL_FEATURES` の追加先と unknown-feature メッセージの列挙順依存 |
| `tasks/experimental/done/device-authorization-grant/` `tasks/experimental/done/ciba/` | 新規エンドポイント + UI 画面パターンの先例仕様 |
| `tasks/experimental/jwt-introspection-response/specification.md` | 仕様書構成の直近先例 |

## 二次資料

- なし（ブログ記事等は仕様確定の根拠に使用していない）
