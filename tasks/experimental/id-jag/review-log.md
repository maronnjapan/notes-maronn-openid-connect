# レビューログ: id-jag

## Review 1

- **日付**: 2026-08-30（仕様作成日と同日。運用ルール上 Review 1 として扱う）
- **観点**: 仕様の完全性（一次資料の読み違い / 公開 API 案が subpath export で実装可能か / CLI 統合の現実性 / 依存方向 / テスト定義 / 非目標の明確さ / 理解資料の自立性）
- **確認資料**:
  - draft-ietf-oauth-identity-assertion-authz-grant-04 全文（ietf.org アーカイブ、2026-08-30 取得）— §3.1 のクレーム必須性、§4.3 の `audience` REQUIRED、`subject_token_type` の 3 値（id_token / saml2 / refresh_token）、§4.3.4 の `token_type: N_A` と refresh_token SHOULD NOT、§4.4.1 の typ / aud（要素数 1 の配列許容）/ client_id 一致の MUST、§4.4.3 の「同一 ID-JAG の再提示可」、§7 のメタデータ名 2 種、§9.3 / §9.4 の禁止事項を仕様書の記載と突き合わせ、読み違いなしを確認
  - `packages/experimental/src/token-exchange/token-exchange-request.ts` — 合成＋ステップ構成、TokenExchangeError（closed enum 回避）、固定文言の方針が本仕様の設計とそのまま整合することを確認
  - `packages/experimental/src/jarm/response-jwt.ts` — RS256 固定の自前 compact JWS 生成が experimental 内で成立済みであることを確認（ID-JAG 署名が踏襲）
  - `packages/core/src/id-token.ts` — `validateIdTokenHint` が署名 / iss / aud / exp / iat / alg none / 外部鍵ヘッダの全検証を持ち、`JwkSet` を注入できる公開 API であることを確認（発行側 subject_token 検証の委譲先）
  - `samples/hono-cloudflare/src/oidc-provider/routes/token.ts` — 生成済み分岐（token-exchange / device_code）の実物構造と catch 節分岐を確認。ID-JAG の 2 分岐が同型で挿入可能
  - `tests/e2e/playwright.config.ts` — webServer 配列に 2 インスタンス目の OP を追加できる構成であること、`OIDC_CLIENTS_JSON` / ポート / issuer が env で注入されることを確認
- **指摘**:
  1. 当初案では発行側の subject_token 無効を draft §4.3.4.3 の例示どおり `invalid_grant` にしていたが、同じ grant_type（token-exchange URN）を共有する既存 token-exchange 機能が `invalid_request` を使っており、`requested_token_type` の値でエラーコードが変わる契約は混乱を招く
  2. 受領側のアクセストークン寿命を ID-JAG の残存期間で cap する案は、draft §4.4.3（アクセストークン失効後に同じ ID-JAG を再提示する、例示でも grant 300 秒に対しトークン 86400 秒）と矛盾する
  3. E2E を単一 OP の自己信頼で組む案は draft §9.3（同一ドメイン内利用の禁止）に反する
- **修正**:
  1. 発行側の subject_token 検証失敗は `invalid_request`（固定文言）に統一し、draft の例示が非規範であることと設計判断を仕様書のエラー節に明記
  2. 寿命 cap を撤回し、`config.accessTokenExpiresIn` をそのまま使う設計に変更。token-exchange 機能との違いを設計判断として明記
  3. E2E をサンプル OP の 2 インスタンス構成に変更し、同一ドメイン拒否（発行側 / 受領側の二重ガード）を仕様のセキュリティ要件と負のテストに追加
- **残リスク**:
  - draft は -04 であり改版でクレームや必須性が変わり得る（U2 として記録）。experimental 隔離とドキュメントの版数明記で受容する
  - `jwksUri` の fetch を生成コード側に置く判断は、キャッシュ TTL 内の鍵ローテーションで検証失敗が起き得る。PoC 用途の許容範囲としてキャッシュ 300 秒を明記し、理解資料でなくコードコメントで案内する
- **判定**: Pass with changes（指摘 3 件は同日修正済み）
- **次回可能日**: 実装後（実装との整合レビュー）
