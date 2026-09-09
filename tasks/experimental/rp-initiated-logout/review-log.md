# レビュー記録: rp-initiated-logout

## Review 1

- **日付**: 2026-09-09（仕様作成日をReview 1として実施）
- **観点**: 仕様の完全性（問題・スコープ・非目標の明確さ、一次資料の読み違い、公開API案の実装可能性、CLI統合の現実性、依存方向、テスト定義、未解決事項の明示、理解資料の自立性）
- **確認資料**:
  - OpenID Connect RP-Initiated Logout 1.0（Final, 2022-09-12）§1〜§3・§7 を取得して MUST / SHOULD / RECOMMENDED の別を確認（client_id と aud の一致 MUST、確認画面の MUST、完全一致 MUST NOT、GET/POST 両対応 MUST、期限切れ受理 SHOULD、通知後リダイレクトの記述）
  - `packages/core/src/id-token.ts` の `validateIdTokenHint` 実装全文（引数契約・exp 超過拒否・kid/alg 鍵選択・外部鍵ヘッダ拒否）
  - `packages/core/src/authentication-session.ts`（セッション契約と online refresh token の関係）
  - `packages/cli/src/frameworks/hono/templates.ts` の browser session store（`delete` あり）、`SESSION_COOKIE_NAME`、Device / CIBA の UI ルートと CSRF cookie、discovery スプレッドマージ位置、views インターフェース
  - `packages/cli/src/features.ts`（EXPERIMENTAL_FEATURES の構造と unknown-feature メッセージの列挙順依存）
  - `study-material/ext-rp-initiated-logout.md`（候補評価・方針 A）
- **指摘**:
  1. 初稿は期限切れ `id_token_hint` の扱いを未記載のまま「core の validateIdTokenHint を使う」としていたが、同関数は exp 超過を拒否するため、仕様の SHOULD（現在または最近のセッションがあれば期限切れも受理）と暗黙に衝突する
  2. Native SSO を候補比較に挙げる際、`ds_hash` が core 無変更で実装できない根拠（`generateIdToken` に任意クレーム注入点がない）を実装で確認せず書きかけていた
  3. 確認画面経由のリダイレクト可否（U1）、aud 配列時のクライアント特定（U2）、確認 POST のパス名（U3)が設計判断として弱く、確定根拠が仕様書内にない
- **修正**:
  1. 期限切れヒントを非目標に昇格し、「無効なヒントとして確認画面の経路に落とす（安全側の SHOULD 不採用）」を設計判断として明記。将来の昇格考慮に core への leeway 注入点追加を記録
  2. `packages/core/src/id-token.ts` の `generateIdToken` と index.ts のエクスポートを確認したうえで採用理由に記載
  3. U1〜U3 として未解決事項に登録し、それぞれ確定に使う資料（§3 の文言、core の aud 構築実装、既存 UI パス命名）と確定予定レビューを明記
- **残リスク**:
  - U1〜U3 が未確定（いずれも実装形の選択であり、セキュリティ上どちらを選んでも fail-closed 側に倒せることは確認済み）
  - 確認画面まわりの CSRF cookie 実装は Device / CIBA の先例参照に留まり、テンプレートの具体的な補間位置は Review 3 で確定する
- **判定**: Pass with changes
- **次回可能日**: 2026-09-10
