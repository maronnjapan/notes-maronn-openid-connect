# OAuth 2.0 Security Best Current Practice（RFC 9700 / BCP 240）カバレッジ監査

## ステータス

🟢 仕様追随 / 監査ハブ / RFC 9700 引用移行済み（2026-07-21）

## 1. このトピックで確認したいこと

- 既存の study-material / tasks は、公開前の Internet-Draft から **RFC 9700（2025年1月）** へ引用を移行済み（IETF Best Current Practice 240）。
- 本ファイルは「ドラフト → RFC 化」のタイミングで、RFC 9700 のセクション単位で本リポジトリのカバレッジを **監査表として固定** する。同じセキュリティ論点が既存の専用ファイルで扱われている場合は、その既存ファイルへのポインタを保持するだけで、ここでは仕様詳細を繰り返さない。
- 既存の `basic-op-requirement-traceability.md`（Basic OP 認定の監査表）と並ぶ「Security BCP 監査表」として機能させる。

## 2. 関連する仕様・基準

共通の OAuth / OIDC 索引は `study-material/basic-op-requirement-traceability.md` §3.3 を参照。本ファイル固有の差分:

### 2.1 RFC 9700 の構造

RFC 9700（Best Current Practice for OAuth 2.0 Security）は主要セクションが以下:

- §2 Best Practices（横断的な MUST/SHOULD 集約）
- §3 The Updated OAuth 2.0 Attacker Model（脅威の整理）
- §4 Attacks and Mitigations（攻撃シナリオごとの対策）
  - §4.1 Insufficient Redirection URI Validation
  - §4.2 Credential Leakage via Referer Headers
  - §4.3 Credential Leakage via Browser History
  - §4.4 Mix-Up Attacks
  - §4.5 Authorization Code Injection
  - §4.6 Access Token Injection
  - §4.7 Cross-Site Request Forgery
  - §4.8 PKCE Downgrade Attack
  - §4.9 Access Token Leakage at the Resource Server
  - §4.10 Misuse of Stolen Access Tokens
  - §4.11 Open Redirection
  - §4.12 307 Redirect
  - §4.13 TLS Terminating Reverse Proxies
  - §4.14 Refresh Token Protection
  - §4.15 Client Impersonating Resource Owner
  - §4.16 Clickjacking
  - §4.17 Attacks on In-Browser Communication Flows
- §6 Security Considerations

### 2.2 OAuth 2.1 ドラフトとの関係

OAuth 2.1（draft-ietf-oauth-v2-1）は RFC 9700 の主要勧告（PKCE 必須、Implicit/ROPC 削除、redirect_uri 厳密一致、リフレッシュトークン保護等）を**仕様レベルで取り込み済み**。本リポジトリは OAuth 2.1 準拠を掲げているため、RFC 9700 の MUST 級は概ね既存実装で充足。差分は SHOULD / SHOULD NOT レベルに集中する。

### 2.3 ドラフト時期と RFC 9700 の差分（実務的なポイント）

- ドラフト時に「曖昧」だった文言が確定（特に refresh token 保護、redirect URI 検証）。
- `iss` パラメータ（RFC 9207）の言及が強化。
- DPoP（RFC 9449）、JAR（RFC 9101）、PAR（RFC 9126）等の参照が公式化。
- 旧 Internet-Draft と RFC 9700 の章番号は一致しない。既存文書の引用は、単純置換せず RFC 9700 の主題に対応する節へ移行した。

## 3. 参照資料

- RFC 9700 — https://www.rfc-editor.org/rfc/rfc9700.html （Best Current Practice for OAuth 2.0 Security、2025年1月）
- RFC 9700 の変更履歴: https://datatracker.ietf.org/doc/rfc9700/history/ （公開前 Internet-Draft を含む）
- OAuth 2.1 draft — https://datatracker.ietf.org/doc/draft-ietf-oauth-v2-1/ （RFC 9700 の主要勧告を取り込む）
- RFC 9207 — https://www.rfc-editor.org/rfc/rfc9207 （Authorization Response `iss`）
- RFC 9126 — https://www.rfc-editor.org/rfc/rfc9126 （PAR）
- RFC 9101 — https://www.rfc-editor.org/rfc/rfc9101 （JAR）
- RFC 9449 — https://www.rfc-editor.org/rfc/rfc9449 （DPoP）

## 4. 現在の実装確認

実装の全体構成は `basic-op-requirement-traceability.md` §5 を参照。本ファイルは「セキュリティ論点 → 既存ファイル」のマッピングに専念する。

## 5. 現在の実装との差分（RFC 9700 セクション別カバレッジ表）

凡例: ✅ 充足（既存実装 / タスクで対応）/ 🟡 部分的 / 🔴 未対応 / 📌 既存トピックへ委譲

### 5.1 §4.1 Insufficient Redirect URI Validation

| 勧告 | 状態 | 委譲先 |
|---|---|---|
| redirect_uri 厳密一致 | ✅ | `authorization-request.ts` matchRedirectUri / `tasks/done/p0-redirect-uri-fragment-rejection.md` |
| Public client のループバックポート許容 | ✅ | 同上（OAuth 2.1 §10.3.3） |
| カスタムスキーム / Claimed HTTPS の扱い | 🟡 | 📌 `study-material/ext-native-apps-rfc8252.md` / `study-material/done/oauth-native-apps-rfc8252.md` |
| 危険スキーム（javascript:, data:）拒否 | 🟡 | 📌 `tasks/p1-redirect-uri-dangerous-scheme-rejection.md`（未着手） |

### 5.2 §4.5 Authorization Code Injection / §4.7 CSRF / §4.8 PKCE Downgrade

| 勧告 | 状態 | 委譲先 |
|---|---|---|
| PKCE 必須 / S256 のみ | ✅ | `authorization-request.ts` validateCodeChallenge / `tasks/done/pkce-code-challenge-format-validation.md` |
| state 通過保証 | ✅ | `authorize.ts` state を redirect / token response に反映 |
| code 単回使用 + 再利用 cascade revocation | ✅ | `token-request.ts` / `tasks/done/p0-token-revocation-on-code-reuse.md` |

### 5.3 §4.4 Mix-Up Attacks

| 勧告 | 状態 | 委譲先 |
|---|---|---|
| Authorization Response に `iss` を含める | ✅ | `tasks/done/p1-authorization-response-iss.md`（RFC 9207） |
| Discovery に `authorization_response_iss_parameter_supported` を広告 | ✅ | `discovery.ts` |
| クライアント側で `iss` 検証する責務の周知 | 🟡 | CLI 生成コード側のコメントで明示することが望ましい（タスク化候補） |

### 5.4 §4.2–4.3 Credential Leakage（Referer / Browser History）

| 勧告 | 状態 | 委譲先 |
|---|---|---|
| TLS 強制 | 🟡 | 📌 `study-material/http-security-headers-and-tls.md`（localhost 例外あり） |
| `Referrer-Policy` / `Cache-Control` ヘッダの整備 | 🟡 | 📌 `study-material/http-security-headers-and-tls.md` |
| Authorization Code TTL を短く | 🟡 | 📌 `tasks/p2-auth-code-ttl-configurable.md`（未着手） |

### 5.5 §4.9–4.11 Access Token Leakage / Misuse / Open Redirection

| 勧告 | 状態 | 委譲先 |
|---|---|---|
| AT を query parameter で送らせない（RFC 6750 §2.3 廃止） | ✅ | `routes/userinfo.ts` は Authorization ヘッダと form body のみ受理 |
| sender-constrained AT（DPoP / mTLS） | 🟡 | 📌 `tasks/T-019-dpop.md` / `study-material/ext-mtls-rfc8705.md` |
| Open Redirector 防止（state、redirect_uri 厳密一致） | ✅ | 既出 |

### 5.6 §4.14 Refresh Token Protection

| 勧告 | 状態 | 委譲先 |
|---|---|---|
| Refresh Token のクライアントバインディング | ✅ | `token-request.ts` で `refreshTokenInfo.clientId !== authenticatedClientId` 拒否 |
| Refresh Token のローテーション | ✅ | `tasks/done/01-refresh-token.md` 等 |
| 再利用検知 → cascade revocation | ✅ | `tasks/done/p0-token-revocation-on-code-reuse.md` |
| sender-constrained refresh tokens（public client）| 🟡 | DPoP 経由 → 📌 `tasks/T-019-dpop.md` |
| 絶対有効期限（rolling 無限延長禁止） | 🔴 | 📌 `tasks/p1-refresh-token-absolute-lifetime.md`（未着手） |
| ローテーション誤検知緩和 | 🔴 | 📌 `study-material/refresh-token-rotation-replay-grace.md`（検討中） |

### 5.7 §2.5 Client Authentication / §4.15 Client Impersonating Resource Owner

| 勧告 | 状態 | 委譲先 |
|---|---|---|
| クライアント認証必須（confidential） | ✅ | `client-auth.ts`（basic / post） |
| `client_secret` の安全な保管・比較 | 🟡 | 📌 `study-material/security-client-secret-handling.md` / `tasks/done/p0-client-secret-timing-safe-comparison.md` |
| Public client が refresh token を取得する場合の制約 | 🟡 | 📌 `tasks/p1-public-client-token-endpoint.md` |

### 5.8 §4.16 Clickjacking

| 勧告 | 状態 | 委譲先 |
|---|---|---|
| `X-Frame-Options` / `Content-Security-Policy frame-ancestors` | 🟡 | 📌 `study-material/http-security-headers-and-tls.md` |

### 5.9 §4.12 307 Redirect / §4.13 TLS Terminating Reverse Proxies

| 勧告 | 状態 | 委譲先 |
|---|---|---|
| 認証情報を含む POST 後のリダイレクトで 307 を使わない | ✅ | 生成ルートは 302/303 を使用 |
| TLS 終端プロキシ由来ヘッダのサニタイズ | 🟡 | 📌 `study-material/http-security-headers-and-tls.md`（デプロイ環境の責務） |

### 5.10 §2.4 / §2.1.2 廃止・非推奨の Grant / Flow

| 勧告 | 状態 | 委譲先 |
|---|---|---|
| ROPC（password grant）拒否 | ✅ | `token-request.ts` で `authorization_code`/`refresh_token` 以外 → unsupported_grant_type / `tasks/done/oauth21-removed-grants-explicit-rejection.md` |
| Implicit Grant 拒否 | ✅ | `authorization-request.ts` で `response_type !== 'code'` を拒否 |
| 明示的な失敗テスト | 🟡 | 📌 `tasks/p2-removed-grants-explicit-rejection-tests.md`（テスト粒度） |

### 5.11 §4.17 In-Browser Communication / §6 Security Considerations（横断）

| 勧告 | 状態 | 委譲先 |
|---|---|---|
| HTTPS / TLS 強制 | 🟡 | 📌 `study-material/http-security-headers-and-tls.md` |
| エンドポイントのクレデンシャル推測防止 | ✅ | code / refresh token は CSPRNG ベース |
| エラーメッセージのサニタイズ | ✅ | `error-utils.ts` / `sanitizeErrorDescription` |
| レート制限・ブルートフォース防御 | 🟡 | 📌 `study-material/rate-limiting-and-brute-force.md` |
| 監査ログ | 🟡 | 📌 `study-material/audit-logging-and-observability.md`（および重複ファイル `audit-logging-observability.md`、整理必要） |

## 6. 改善・追加を検討する理由

- 引用先が **RFC として正式公開** されたため、**信頼性のシグナル**としての確度が上がる。仕様参照を RFC 9700 に固定し、章番号の変化も監査表へ反映した。
- 監査表として可視化することで、Conformance 認定とは別軸の「セキュリティ Tier B（本番志向）」の充足度を機械的に追跡できる。
- 本ファイルは新規実装トピックではなく、**既存ファイルの相互参照ハブ**として機能。新しく実装すべきものはなく、各専用ファイルに委譲する。

## 7. 実装方針の候補

### 方針A（参照のみ更新）

- 既存タスクの旧 Internet-Draft 引用を、文脈に対応する RFC 9700 の節へ置換する。
- 本ファイルは固定の監査表として運用する。

### 方針B（リリースノートで明示）

- 引用更新に加え、`RELEASE-v0.x-scope.md` の D 章「Speed シグナル」に「RFC 9700 公開に伴う仕様参照のメンテナンス」を 1 件のシグナルとして追加。

### 方針C（軽量自動化）

- `tools/` 配下に grep ベースの参照チェッカ（draft 引用が残っていないか）を追加。CI で実行。

## 8. タスク案

- [x] 既存 study-material / tasks の旧 Internet-Draft 引用を grep で洗い出した。
- [x] 各引用箇所を RFC 9700 の対応セクションへマッピングして置換した。
- [x] 本ファイルの §5 監査表を RFC 9700 の最終章立てに更新した。既存タスクが done になったら状態列と委譲先を同時に更新する。
- [x] `study-material/basic-op-requirement-traceability.md` §3.3 の引用テーブルに RFC 9700 を追加した。
- [ ] `study-material/audit-logging-and-observability.md` と `audit-logging-observability.md` の **ファイル名重複問題**を整理（本監査表とは別問題だが、参照時の混乱を避けるため別途整理タスク化）。
