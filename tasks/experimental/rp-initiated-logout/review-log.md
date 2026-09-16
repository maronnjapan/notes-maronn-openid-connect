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

## Review 2

- **日付**: 2026-09-16
- **観点**: セキュリティと適合性（認証認可上の脅威、鍵・トークン・シークレットの扱い、ログ禁止情報、有効期限、エラー情報の露出、package 境界との整合、CLI 後方互換、明示的有効化、生成コードの安全性、切り出し可能な構造、セキュリティ要件のテスト検証可能性）。Review 1 と重複する完全性の確認は繰り返さず、未確定だった U1・U2 の確定と、脅威対策の実装先例との突き合わせに絞った
- **確認資料**:
  - OpenID Connect RP-Initiated Logout 1.0 §2・§3・Security Considerations の逐語を再取得（client_id と aud の一致 MUST、確認の MUST、「id_token_hint が post_logout_redirect_uri とともに供給されない場合はリダイレクト MUST NOT」、完全一致 MUST NOT、有効なヒントのない要求の DoS 性）
  - `packages/core/src/token-response.ts` の `buildIdTokenAudience`（239 行〜。単一 audience は文字列 + azp なし、複数 audience は配列 + azp 必須付与）と `packages/core/src/id-token.ts` の `validatePayload` の azp 規則（aud 配列の空・非文字列要素の拒否、複数値時の azp 必須）
  - `packages/core/src/id-token.ts` の `validateIdTokenHint` 署名（`expectedIss` / `expectedAud` / `jwks`、clockSkew leeway、alg=none 拒否、外部鍵ヘッダ拒否）。仕様書の呼び出し想定と一致することを確認
  - `packages/cli/src/frameworks/hono/templates.ts` の Device verification 実装コメント（3745 行〜）。record 保存の CSRF トークン単独では防御にならず、binding cookie を主防御・hidden token を defense in depth とする先例の設計判断
- **指摘**:
  1. U2 の前提「本 OP の ID Token の aud は client_id 単一文字列のはずで、配列ケースは自 OP 発行トークンでは生じない」が誤り。`buildIdTokenAudience` は追加 audience 構成時に aud 配列 + `azp = clientId` を発行するため、azp フォールバックは防御的分岐ではなく必須の経路である
  2. セキュリティ要件の CSRF 行が「per-flow CSRF cookie」とだけ書かれ、Device 先例の実際のモデル（描画時発行の cookie と hidden token の対。token 単独では防御にならない）を特定していなかった
  3. 有効な ID Token を盗まれた場合の「被害者本人のブラウザへのリンク誘導による即時ログアウト」が残存脅威として明文化されていなかった（仕様の信頼モデル上は受容される挙動だが、受容の判断が記録にないと Review 3 で再燃する）
- **修正**:
  1. U1 を確定: 判定規則 6 のまま「有効なヒント + 完全一致なら確認経由でもリダイレクト」を維持。§3 の逐語（リダイレクトの条件はヒントの供給と完全一致であり、確認画面の経由有無ではない）を根拠として未解決事項の表に記録
  2. U2 を確定: azp フォールバックを維持し、根拠を `buildIdTokenAudience` の実装（ファイル・行）で記録。要素 1 フォールバックも「署名検証前の抽出であり信頼は後段が与える」として許容のまま残す
  3. セキュリティ要件の CSRF 行と CLI オプション案・理解資料を binding cookie モデル（cookie + hidden token の対、どちらか単独では通さない）へ具体化
  4. 「他人の ID Token を使ったログアウト強要」行と理解資料に、盗まれた ID Token による本人ブラウザへの強制ログアウトを受容する判断と理由を追記
  5. sources.md へ Review 2 の確認先（token-response.ts / Device binding cookie コメント / §3 逐語の再確認日）を追記
- **確認して問題なしとした項目**: ヒント検証失敗理由の非露出（オラクル防止）とログ禁止（`id_token_hint` / `logout_hint` の値）は仕様書に明記済み。exp は core の検証をそのまま使い期限切れは確認画面へ fail-closed。package 境界（experimental は HTTP にもストアにも触れない純関数群、core 変更なし、機能間コード共有なし）は Review 2 観点でも矛盾なし。CLI は `EXPERIMENTAL_FEATURES` 末尾追加 + 無効時バイト同一の完了条件で後方互換とデフォルト無効が検証可能。セキュリティ要件はいずれも conformance テスト計画の項目（CSRF cookie なし 400、未登録 URI 完了画面、client_id 不一致で確認画面）に対応しており検証可能
- **残リスク**:
  - U3（確認 POST のパス名）が未確定のまま。実装形の選択であり Review 3 の生成テンプレート一貫性確認で確定する
  - 盗難 ID Token による本人ブラウザの強制ログアウト（上記のとおり受容。仕様の信頼モデルの帰結）
  - 応答時間差によるセッション存在オラクルは「削除操作の有無以外の分岐を作らない」方針で最小化するが、完全一定時間は保証しない（確認画面の文言統一が主対策）
- **判定**: Pass with changes
- **次回可能日**: 2026-09-17
