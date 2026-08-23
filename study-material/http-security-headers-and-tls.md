# HTTP セキュリティヘッダー / TLS / 本番運用ハードニング

## ステータス

🟡 Major（セキュリティ）/ 未着手

## 1. このトピックで確認したいこと

本リポジトリはコア（純関数ライブラリ）と CLI 生成テンプレート（Hono + Cloudflare Workers）で構成されている。
OAuth 2.1 / OIDC を本番ライクに走らせる場合、HTTP レイヤーで以下が問われる:

- TLS 必須性（HTTPS 強制）と HSTS
- 認可・同意・ログイン UI のクリックジャッキング / XSS 対策（`X-Frame-Options` / `Content-Security-Policy` / `X-Content-Type-Options`）
- セッション Cookie の `Secure` / `HttpOnly` / `SameSite`
- API 系エンドポイント（Token / UserInfo / Discovery / JWKS）の `Cache-Control` / `Pragma`（既存タスク群で個別カバー済み）

本ファイルは「個別エンドポイントの `Cache-Control` 改善」に矮小化されない、**横断的な本番ハードニング指針**を整理する。

既存タスクとの関係:

- `tasks/p0-userinfo-cache-control.md`、`tasks/p0-token-endpoint-error-cache-control.md` 等は **API レスポンスの `Cache-Control`**を扱う
- 本ファイルは **UI（ログイン / 同意ページ）の Frame 防御・CSP・Cookie 属性**および **TLS / HSTS** を扱う（重複しない差分）

## 2. 関連する仕様・基準

共通の仕様索引は `study-material/basic-op-requirement-traceability.md` を参照。本トピック固有のポイント:

- **OAuth 2.1 §1.5 / §8 / Security Considerations**:
  - すべての OAuth エンドポイントは TLS（HTTPS）必須。`http:` での提供は禁止（loopback 開発時の例外を除く）。
  - Authorization Endpoint / Token Endpoint / UserInfo Endpoint のいずれも HTTPS。
- **OIDC Core 1.0 §16**:
  - `issuer` は `https` を要求（loopback / development を除く）。本リポジトリは `discovery.ts:validateIssuer` で強制済み。
- **RFC 6797 HSTS（HTTP Strict Transport Security）**:
  - `Strict-Transport-Security: max-age=31536000; includeSubDomains; preload` を返すことで、ブラウザがプロトコルダウングレード経路を遮断。
- **クリックジャッキング防御**:
  - Authorization / Consent / Login の UI は **iframe 埋め込みを禁止**するのが OIDC OP の慣行。`X-Frame-Options: DENY` または `Content-Security-Policy: frame-ancestors 'none'`。
  - 例外: OIDC Session Management 1.0 の `check_session_iframe` は iframe で動かす設計だが、本リポジトリは未対応（`study-material/ext-rp-initiated-logout.md`）。
- **CSP（Content Security Policy）**:
  - 認可系 UI は最低でも `default-src 'self'`、`script-src 'self'`、`form-action <token endpoint>` を設定。
  - `response_mode=form_post` を実装する場合（`study-material/response-mode-form-post.md`）、auto-submit `<script>` のために `script-src 'self' 'nonce-...'` 等の nonce 戦略が必要。
- **MIME Sniffing 防御**: `X-Content-Type-Options: nosniff`。
- **Referrer Policy**: 認可リクエストの `state` 等が Referer 経由で漏れないよう `Referrer-Policy: no-referrer` または `strict-origin`。
- **Cookie 属性**（Session Cookie / CSRF Cookie）:
  - `Secure`: HTTPS でのみ送信。
  - `HttpOnly`: JS から触れない。
  - `SameSite=Lax`: 認可リダイレクトをまたぐ場合は `Lax`（`Strict` だと Cross-Site から戻ってきた時に Cookie が送られず認可フローが破綻する）。
  - `Path` / `Domain` を OP のホストに絞る。
  - **名前プレフィックス（`__Host-`）によるホスト隔離**は本ファイルの範囲外。
    属性だけでは兄弟ホストからの Cookie 書き込み（RFC 6265 §8.6 Weak Integrity）を防げないため、
    その論点は `study-material/done/op-cookie-host-prefix-and-domain-isolation.md` /
    `tasks/p2-op-cookie-host-prefix.md` が扱う。
- **OAuth 2.0 Security BCP（RFC 9700。RFC 6819 を更新）**:
  - フロントチャネル経路（Authorization Endpoint）の HTTPS 必須、リダイレクト URI の厳格一致（実装済み）、`state` のエントロピー、CSRF 防御（`state` または PKCE で代替済み）。
- **OWASP ASVS 4.x**: WebApp として認可サーバを建てるなら、ASVS V3（Session Management）、V7（Errors and Logging）、V14（Config）を参照。

## 3. 参照資料

- OAuth 2.1 draft §1.5 / §8: https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1
- OIDC Core 1.0 §16: https://openid.net/specs/openid-connect-core-1_0.html
- OAuth 2.0 Security Best Current Practice（RFC 9700）: https://www.rfc-editor.org/rfc/rfc9700.html
- RFC 6797 HSTS: https://www.rfc-editor.org/rfc/rfc6797
- MDN: Strict-Transport-Security / X-Frame-Options / CSP / Referrer-Policy / Cookies（一次情報の取り扱いを補強する目的で参照可）

## 4. 現在の実装確認

- TLS / HSTS:
  - `issuer` の `https` 強制は `packages/core/src/discovery.ts:103` の `validateIssuer` で実装済み。
  - HSTS ヘッダーの付与は CLI テンプレート / sample に **無い**。Cloudflare Workers ではプラットフォーム側で HSTS を付与する設定もあるが、ライブラリとしての方針が無い。
- UI（Login / Consent）ページ:
  - `packages/sample/src/oidc-provider/routes/login.ts` / `routes/consent.ts` / `views.ts` は HTML を返す。
  - `X-Frame-Options` / CSP / `X-Content-Type-Options` / `Referrer-Policy` の付与は確認した限り **無い**（grep でヘッダーセット箇所が見当たらない）。
- Cookie / Session:
  - 本リポジトリは「セッションは利用者の `SessionResolver` に注入させる」設計（`packages/core/src/auth-transaction.ts`）。Cookie 設定はサンプル / CLI 利用者の責務。
  - sample で setCookie を呼んでいる箇所は確認できず、セッションは KV / D1 等のストア側で完結している可能性が高い。
- API レスポンスの `Cache-Control`:
  - UserInfo / Token / Token エラーは既存タスクで個別に対応中（`tasks/p0-userinfo-cache-control.md`、`tasks/p0-token-endpoint-error-cache-control.md`）。
  - Discovery / JWKS は public で長寿命キャッシュが許される（短いほうが堅い）。

## 5. 現在の実装との差分

- 🟢 **TLS 強制（issuer URL）は実装済み**: discovery レベルで担保。
- 🔴 **UI ページのセキュリティヘッダー欠如**: ログイン / 同意ページに `X-Frame-Options` / CSP が無いと、フィッシング・クリックジャッキング検証が浮上する。
- 🔴 **HSTS の方針が無い**: Cloudflare Workers / ホスティング層に委ねる方針なら明文化が必要。CLI テンプレートに「HSTS を有効化することを推奨」コメントが無い。
- 🟡 **Cookie 属性のガイドライン不在**: 利用者がセッション Cookie を独自実装するときの推奨属性が文書化されていない。SameSite 設定ミスで認可フローが壊れる典型例を踏みやすい。
- 🟡 **`Referrer-Policy` の方針不在**: `state` 漏洩防止の観点で、Authorization Endpoint からの遷移ページに `Referrer-Policy: no-referrer` 系を付与するのが望ましい。
- 🟢 **`form_post` 等を実装する場合 CSP との衝突を要設計**: `study-material/response-mode-form-post.md` で言及済み。

## 6. 改善・追加を検討する理由

価値:

- ターゲットの「本番導入を見据える開発者」は、セキュリティヘッダーが揃っていない OSS を本番直前で再評価する必要が出る。最初から推奨ヘッダーを CLI テンプレに焼き込むことで、利用者の移行ストレスを減らす。
- ASVS / OWASP / Cloudflare の本番チェックリストで必ず叩かれる項目を、CLI 生成段階でデフォルト ON にすれば「PoC → 本番」の心理的ハードルが下がる。
- 実装コストが小さい（ヘッダー追加と CLI テンプレ更新）。
- セキュリティドキュメントを 1 本に集約することで、利用者が「どこを触ればよいか」を一度で把握できる。

導入難易度:

- 🟢 **CLI テンプレ更新が主**: Hono のミドルウェアで全エンドポイントにヘッダーを付与可能。
- 🟡 **CSP の細部は利用者責務**: 静的アセット配信先、外部分析ツール、フォント等の許容オリジンは環境依存。デフォルトは厳しめにし、利用者が緩める方針が安全側。

実装しない場合:

- 利用者が本番投入直前にハードニング項目を洗い出すコストを負う。
- ターゲットの差別化軸「Fidelity」「本番志向」と整合しない。

## 7. 実装方針の候補

### 方針A（ガイドライン文書化のみ）

- 本ファイル（`study-material/http-security-headers-and-tls.md`）に「推奨ヘッダー一覧」と「ライブラリの責務 vs ホスティング側の責務」を表で固定。
- CLI 生成テンプレに `// SECURITY:` コメントで設定例を残す。
- 実コードは触らない。

### 方針B（最小: CLI テンプレに既定ミドルウェアを追加）

- Hono ミドルウェアで以下を一括設定（全ルート）:
  - `Strict-Transport-Security: max-age=63072000; includeSubDomains` （opt-out 可能に）
  - `X-Content-Type-Options: nosniff`
  - `X-Frame-Options: DENY`（OP UI 全般）
  - `Referrer-Policy: no-referrer`
  - `Content-Security-Policy: default-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'`
- 利用者は config から弱める／追加できる。
- API 系ルート（Token/UserInfo/JWKS/Discovery）の `Cache-Control` は既存タスクで個別対応するため重複しない。

### 方針C（フルセット）

- 上記 + Cookie デフォルト属性ヘルパー（`Set-Cookie` を生成する公式ヘルパー）。
- CSP nonce 戦略を `form_post` 実装と一緒に提供。
- Session Cookie のサンプル実装（Workers KV ベース）も CLI テンプレに追加。

判断材料:

- 方針 A は即時可だが、利用者が手作業で写経することになる。
- 方針 B は CLI 利用者にとって即効性高い。Hono ミドルウェアは取り外し可能。
- 方針 C は便利だが、Cookie 周りに踏み込むと「利用者の I/F 選択を狭める」リスクがある。

## 8. タスク案

- [ ] 方針 A / B / C を人間が選択
- [ ] 方針 A 採用時: 本ファイルに「推奨ヘッダー一覧表」と「利用者責務 vs ライブラリ責務 vs ホスティング責務」を表で固定
- [ ] 方針 B 採用時:
  - [ ] CLI Hono テンプレ（`packages/cli/src/frameworks/hono/templates.ts`）に `securityHeadersMiddleware` を追加
  - [ ] デフォルトヘッダー値の妥当性確認（HSTS の `max-age` が短すぎないか、CSP がログイン UI を壊さないか）
  - [ ] テスト: 主要エンドポイントの応答に推奨ヘッダーが含まれること（CSP の必須ディレクティブ、X-Frame-Options=DENY 等）
  - [ ] sample アプリでも同じミドルウェアを使い、E2E でフォーム送信が壊れないことを確認
- [ ] 方針 C 採用時: 上記 + Cookie ヘルパー / Session ストア例 / CSP nonce 戦略
- [ ] 既存の `tasks/p0-*-cache-control.md` 群と本ファイルの守備範囲（UI ヘッダー / TLS / Cookie）が重複しないようクロスリファレンスを各タスクに追記
