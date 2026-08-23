# [P3] OAuth 2.0 Security BCP の仕様引用を **RFC 9700** に更新する

## ステータス

✅ 完了（2026-07-21）

## 背景

既存の study-material / tasks の多くは OAuth 2.0 Security BCP を公開前の Internet-Draft 名で参照していた。この仕様は **2025年1月に RFC 9700**（Best Current Practice for OAuth 2.0 Security、BCP 240）として正式公開済み。

引用元を RFC に統一することで:
- 仕様参照の信頼性が上がる（IETF Best Current Practice として確定）
- 将来読み手が古いドラフトを探し回らなくて済む
- Fidelity 軸（仕様準拠を信頼性のシグナルとして保持する）に対するメンテナンスシグナル

詳細は `study-material/done/oauth-security-bcp-rfc9700.md` 参照（同ファイルはセキュリティ論点ごとのカバレッジ監査表として継続運用）。

## 対象ファイル

旧 Internet-Draft 名を含んでいたすべての markdown ファイル。実施時は固定文字列検索で対象を確定した。

現時点で該当しうるファイル（コミット時点での grep 結果に従う）:
- `study-material/audit-logging-and-observability.md`
- `study-material/audit-logging-observability.md`
- `study-material/refresh-token-rotation-replay-grace.md`
- `study-material/token-lifetime-security-policy.md`
- `study-material/security-client-secret-handling.md`
- `study-material/rate-limiting-and-brute-force.md`
- `study-material/ext-pushed-authorization-requests-rfc9126.md`
- `study-material/ext-token-exchange-rfc8693.md`
- `study-material/http-security-headers-and-tls.md`
- `study-material/oauth-browser-based-apps-bcp.md`
- `study-material/ext-device-authorization-grant-rfc8628.md`
- `study-material/ext-third-party-initiated-login.md`
- `study-material/ext-oidc-session-management-1_0.md`
- `study-material/ext-multiple-response-types-hybrid-flow.md`
- `study-material/extension-pushed-authorization-requests-par.md`
- `study-material/resolver-and-store-contract.md`
- `study-material/basic-op-requirement-traceability.md`
- `study-material/done/oauth-security-bcp-rfc9700.md` （本タスクのハブ）
- `tasks/done/p1-redirect-uri-dangerous-scheme-rejection.md`

（実際の対象は実行時の grep 結果で確定する。本リストは参考値）

## 仕様参照

- RFC 9700 — https://www.rfc-editor.org/rfc/rfc9700.html （Best Current Practice for OAuth 2.0 Security、2025年1月）
- RFC 9700 の変更履歴: https://datatracker.ietf.org/doc/rfc9700/history/ （公開前 Internet-Draft を含む）

## 現状の実装

実装コードは変更不要。markdown ドキュメントの引用文字列のみが対象。

## 修正方針

- [x] 固定文字列検索で対象ファイルを洗い出した。
- [x] 各ファイルの旧 Internet-Draft 引用を 1 つずつ確認した。
- [x] **セクション番号は 1:1 で対応しない**ため RFC 9700 の最終章立てと照合した。代表例:
  - redirect URI validation → RFC 9700 §4.1
  - Mix-Up Attacks → RFC 9700 §4.4
  - Authorization Code Injection → RFC 9700 §4.5
  - Refresh Token Protection → RFC 9700 §4.14
  - ROPC の使用禁止 → RFC 9700 §2.4
- [x] URL を `https://www.rfc-editor.org/rfc/rfc9700.html` に統一した。
- [x] 文書名を「OAuth 2.0 Security Best Current Practice (RFC 9700)」に統一した。
- [x] 機械的な `sed` 置換は避け、各ファイルの文脈とセクション番号を確認した。
- [x] `study-material/basic-op-requirement-traceability.md` §3.3 の「Security BCP」行に RFC 9700 を反映した。
- [x] `study-material/done/oauth-security-bcp-rfc9700.md` §5 の監査表を RFC 9700 の最終章立てに更新した。

## テスト要件

- [x] 旧 Internet-Draft 名の固定文字列検索が 0 件になることを確認する。
- [x] 置換後のセクション番号が文脈に合致していることを RFC 9700 本文と照合した。

## 完了条件

- 旧 Internet-Draft 名の固定文字列検索結果が空になる。
- `study-material/done/oauth-security-bcp-rfc9700.md` の監査表が最新化されている。

## 補足

- 本タスクはドキュメントメンテナンスであり、実装コードへの影響は無い。優先度を P3 にしている理由は緊急性が低いため（ドラフトと RFC で実質的な要件は等価）。
- ただし「公開済み RFC を引いている」事実は OSS の信頼性シグナルとして利用者・コントリビュータに伝わる価値がある。
