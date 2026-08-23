# レビューログ: Pushed Authorization Requests (PAR)

## Review 1

- **日付**: 2026-07-27（仕様作成日を Review 1 として実施）
- **観点**: 仕様の完全性（問題・スコープ・非目標の明確さ / 一次資料の読み違い / 公開API案の subpath export 実装可能性 / CLI統合の現実性 / 依存方向 / テスト定義 / 未解決事項の明示 / 理解資料の自立性）
- **確認資料**:
  - RFC 9126 本文（datatracker、規範的文言を直接引用で確認）
  - `packages/core/src/index.ts`（再利用 API の公開状況）
  - `packages/core/src/authorization-request.ts`（`request_uri` 拒否の現状実装）
  - `packages/core/src/crypto-utils.ts:65`（`generateRandomString` シグネチャ）
  - `packages/cli/src/features.ts` / `index.ts` / `generator.ts`（`--enable` 機構）
  - `packages/cli/src/frameworks/hono/templates.ts:1707` 付近（authorize ハンドラの構造と `${requestObjectStep}` 補間パターン）
  - `tasks/T-019-dpop.md`（重複回避）
- **指摘**:
  1. U1（`generateRandomString` のシグネチャ未確認）は仕様確定に不要な保留だった。crypto-utils.ts を確認すれば即解決できる
  2. 前段フックの挿入点が「現実に生成テンプレートへ挿入可能か」の根拠が薄かった。hono テンプレートには既に `${requestObjectStep}` という「パラメータを展開して `effectiveParams` を作る」補間ステップが存在し、PAR 展開はこれと同型のパターンで挿入できることを確認した
  3. 「認可エンドポイントの client_id と pushed レコードの一致検証」を RFC の MUST として書きかけたが、RFC 9126 に明示的 MUST 文言を確認できなかったため、設計判断であることを sources.md の「記録」に明記した（一次資料の読み違い防止）
  4. 認可エンドポイントのクエリに client_id / request_uri 以外のパラメータが混在した場合の挙動が RFC 未規定であることを確認し、「pushed パラメータを正とし他は無視」を本仕様の設計判断として明記した
- **修正**:
  - specification.md: U1 を解決済みに更新（`generateRandomString(32)` = 256bit を明記）、U3 を「hono 確認済み・残 4 テンプレート未確認」に絞り込み
  - sources.md: client_id 一致検証が設計判断である旨を「記録」に追加
- **残リスク**:
  - hono 以外の 4 テンプレートの挿入点未確認（U3）。仕様の成立自体は hono で確認済みのため完全性は満たすが、実装規模の見積り精度に影響
  - RFC 6749 / OIDC Core §3.1.2.6（`invalid_request_uri`）の原文再精読が未実施（sources.md に Review 2 実施と記録）
  - `requirePushedAuthorizationRequests` の初期スコープ判断が未確定（U5、Review 3 で判断）
- **判定**: **Pass with changes**（指摘 1〜4 を同日中に修正反映済み。仕様の完全性の観点で残る事項はすべて未解決事項表に明示されており、Review 2 の観点（セキュリティ・適合性）に引き継ぐ）
- **次回可能日**: 2026-07-28

## Review 2

- **日付**: 2026-07-28
- **観点**: セキュリティと適合性（リプレイ・CSRF・SSRF・インジェクション / 鍵・トークン・シークレットの扱い / ログ禁止情報 / 有効期限 / エラー情報の露出 / package 境界との整合 / CLI 後方互換 / 明示的有効化 / 生成コードの安全性 / 切り出し可能な構造 / セキュリティ要件のテスト検証可能性）。Review 1 の引き継ぎ 5 項目から開始
- **確認資料**:
  - RFC 9126 本文（datatracker、§2.2 / §2.3 / §4 / §5 / §6 / §7 の規範的文言を再確認）
  - OIDC Core 1.0 §3.1.2.6（`invalid_request_uri` 定義と「invalid な Redirection URI へ MUST NOT redirect」の原文）
  - RFC 6749 §3.2.1 / §5.2（クライアント認証・エラー形式の原文再精読）
  - RFC 9700（PAR 言及の全文確認 → §4.1.3 の 1 箇所のみ）
  - `packages/cli/src/frameworks/web-standard/templates.ts` / `{express,fastify,nextjs}/index.ts`（テンプレート委譲構造）
  - `packages/cli/src/frameworks/hono/templates.ts`（authorize ハンドラ全体・catch 節の redirectable 分岐・discovery テンプレート）
  - `packages/core/src/authorization-request.ts`（`AuthorizationError.redirectable` / `rejectUnsupportedRequestParams`）
  - `packages/cli/src/features.ts`（`resolveFeatures` の後方互換性確認）
- **指摘**:
  1. **[適合性・修正] Cache-Control ヘッダの不足**: RFC 9126 §2.2 の応答例は `Cache-Control: no-cache, no-store`。仕様書・理解資料は `no-store` のみを記載していた
  2. **[適合性・格上げ] client_id 紐付けの規範根拠**: §2.2「The request_uri value MUST be bound to the client that posted the authorization request」は規範的 MUST であることを原文確認。Review 1 で「純粋な設計判断」と記録していたのは不正確（紐付け要件は規範、クエリ client_id 比較という強制手段が実装判断）
  3. **[正確性・修正] RFC 9700 の位置付けの過大記載**: 採用理由の「OAuth 2.0 Security BCP でも推奨」は不正確。RFC 9700 の PAR 言及は §4.1.3 の 1 箇所（redirect URI 検証の文脈の MAY）のみで、一般的推奨の規範文言はない
  4. **[生成コード安全性・重要] 前段フックのスケッチに欠陥**: 既存テンプレートの後続ステップ（`resolveClientForAuthorization` / `validateResponseType` / `rejectUnsupportedRequestParams` 等）は `effectiveParams` ではなく `params` を参照する。仕様書初版のスケッチ（`effectiveParams` のみ導入）では元 `params` に `request_uri` が残り、`rejectUnsupportedRequestParams` が `request_uri_not_supported` を投げて PAR フローが常に失敗する。`params` 束縛自体を展開後パラメータへ差し替える形に修正
  5. **[U3 解決] テンプレート挿入点**: express / fastify / nextjs は web-standard へ委譲し、web-standard は hono の `authorizeRouteTemplate` を `toWebRouteTemplate` の文字列変換で再利用している。前段フックは単一テンプレートの変更で 5 ターゲット全てに反映される（実装規模の見積りを下方修正）
  6. **[U4 解決] `invalid_request_uri` のリダイレクト可否**: 既存実装は `AuthorizationError.redirectUri` の有無で redirect / JSON / 内部 303 / HTML を分岐。解決失敗（不存在・使用済み・期限切れ・client_id 不一致）は一律非リダイレクトと決定（不存在・不一致では検証済み redirect_uri が存在せず RFC 6749 §4.1.2.1 の MUST NOT redirect に該当。期限切れのみリダイレクトする混在方針はオラクル化するため不採用）。仕様書初版の「レコードから redirect_uri を復元できればリダイレクト」という記述は不存在ケースと矛盾していたため撤回
  7. **[エラー露出] 解決失敗のオラクル化防止**: 失敗種別を区別しない固定 error_description・単一エラーコード・一律非リダイレクトをセキュリティ要件表に追加し、結合テストで応答同一性を固定検証する項目を追加
  8. **[インジェクション] store キーの扱い**: authorize クエリ由来の `request_uri` は前置詞検証後とはいえ外部入力のまま `consume` に渡る。store 契約に「キーを不透明値として扱い、永続ストアではパラメータ化する」注記を追加
  9. **[確認のみ・問題なし]** CSRF（PAR はクライアント認証付きバックチャネル POST で Cookie 不使用）/ SSRF（URN のみでフェッチ処理が構造的に不存在）/ シークレット（core `authenticateClient` へ委譲、ログ禁止情報の規定済み）/ 有効期限（60 秒デフォルト・5〜600 秒範囲外は起動時エラー）/ package 境界（依存方向の規定どおり、core 無変更を `rejectUnsupportedRequestParams` の現状実装で再確認）/ CLI 後方互換（`resolveFeatures` はデフォルト全有効の既存挙動を変えず、experimental はデフォルト無効の別カテゴリ。完了条件 3 のバイト同一チェックで客観検証可能）/ 明示的有効化（`--enable par` のみ）/ 切り出し可能な構造（subpath export・他機能とのコード共有なし）
- **修正**（同日反映）:
  - specification.md: Cache-Control 修正 / client_id 紐付けの規範根拠を §2.2 MUST に更新 / RFC 9700 の記載修正 / 前段フックスケッチを `params` 差し替え形に修正（注意書き付き）/ 解決失敗の一律非リダイレクト方針とその根拠・意図的逸脱の明記 / オラクル化防止行をセキュリティ要件表に追加 / store 契約に不透明キー注記 / U3・U4 を解決済みへ移動 / 完了条件 4 を共有テンプレート前提に更新
  - sources.md: RFC 9126 / RFC 6749 / OIDC Core / RFC 9700 の確認状態を Review 2 実施済みに更新、リポジトリ内参照 5 件追加、「記録」に規範根拠と設計判断の区別を最終化
  - understanding-guide.md: BCP の位置付け修正 / 失敗フローに非リダイレクトを明記 / client_id 検証の規範根拠追記 / Cache-Control 修正 / リロード重複許容の参照セクションを §2.2 → §4 に訂正
- **残リスク**:
  - U2（experimental パッケージのビルド基盤未整備）・U5（`requirePushedAuthorizationRequests` の初期スコープ判断）が Review 3 に残る。いずれもセキュリティ未解決事項ではない
  - 生成コードの実挙動（前段フック挿入後のテンプレート出力）は実装時にしか最終確認できない。完了条件 2・3 のテストで検証する前提
- **判定**: **Pass with changes**（指摘 1〜8 を同日中に修正反映済み。セキュリティ上の未解決事項なし。指摘 4 は実装が始まっていれば必ず初回テストで露見する類の欠陥だが、仕様段階で潰せたため Blocked には該当しない）
- **次回可能日**: 2026-07-29

## Review 3

- **日付**: 2026-07-29
- **観点**: 実装着手可否（追加調査なしで着手できるか / 受け入れ条件の客観性 / 対象ファイルと変更範囲 / API・CLI・テスト・Docs・Changeset の一貫性 / 実装順序と検証方法 / Experimental であることの利用者への明示）。Review 2 の引き継ぎ 5 項目から開始
- **確認資料**:
  - `packages/cli/src/features.ts`（`resolveFeatures` 全体を再読。未知機能名 throw・デフォルト全有効の現状を確認）
  - `packages/cli/src/frameworks/hono/templates.ts`（L1690-1735: authorize ハンドラの `const params = rawParams;` と `try {` の位置関係 / L2030-2095: catch 節の分岐構造 / L1608-1613: store の import 共有パターン / L2450 が token endpoint 側の別ハンドラであることの確認）
  - `packages/core/src/authorization-request.ts`（L21-76: `AuthorizationErrorCode` enum の全メンバー / L286-313: `AuthorizationError` コンストラクタ）
  - `packages/core/src/index.ts`（仕様書が依存する core API 9 件の公開の再確認。`sanitizeErrorDescription` 含む）
  - `packages/cli/src/index.ts`（L8-12, L185: `INSTALL_COMMANDS`）
  - `packages/experimental/README.md` / `.changeset/` / `docs/library-document/` の現状
- **指摘**:
  1. **[実装着手不可能・修正] 前段フックスケッチの位置欠陥**: 挿入点 `const params = rawParams;`（L1725）はハンドラの `try` ブロック（L1727）より**前**にある。Review 2 修正後のスケッチのままこの位置で `resolvePushedRequestUri` を実行すると、`PushedRequestUriError` が catch 節に届かずフレームワークの未処理例外（500）になり、仕様書自身のエラー処理要件（既存の非リダイレクト経路で描画）と矛盾する。解決処理を try 内先頭へ移し、`params` を par 有効時のみ `let` 宣言＋再代入する形にスケッチを修正した
  2. **[実装着手不可能・修正] catch 節の `PushedRequestUriError` 分岐が未規定**: 既存 catch は `instanceof AuthorizationError` のみ分岐し、それ以外は 500 `server_error` に落ちる。さらに core の `AuthorizationErrorCode` は closed な enum で `invalid_request_uri` を含まないため、core 無変更の制約下では `AuthorizationError` への相乗りが型的に不可能（別クラス＋専用 catch 分岐が構造的に必須）。仕様書に必須要件 3 点（try 内実行 / catch 分岐追加 / 条件付き補間によるバイト同一維持）として明文化した
  3. **[U5 解決] `requirePushedAuthorizationRequests` は初期リリースに含める**: ユースケース「PAR 必須時に既存クライアントがどう壊れるか確認」が検証価値の中核で、追加実装はガード 1 関数＋設定値＋discovery 1 フィールド＋結合テスト 1 件と小さい。`assertPushedRequestUsed` を公開 API に残し、認可エンドポイントのバリデーション順序をガード先頭（2-1）へ並べ替え、結合テストの条件付き文言を削除した
  4. **[U2 解決] 実装順序セクションを新設**: 基盤作成（package.json / tsconfig / vitest）を実装 Routine の初手（ステップ 1）として明記し、全 7 ステップを完了条件の番号と対応付けた
  5. **[一貫性・修正] PAR 設定値の置き場所が未規定だった**: `expiresInSeconds` / `requirePushedAuthorizationRequests` を生成コード `par.ts` の `parConfig` 定数として export し authorize 前段フックが import する、と確定
  6. **[テスト計画・追加] catch 分岐の検証テスト**: 解決失敗が非リダイレクト（`Location` ヘッダなしの JSON 400）で返ることを固定検証する結合テスト項目を追加（指摘 1・2 の回帰防止）
  7. **[確認のみ・問題なし]** 受け入れ条件の客観性（完了条件 3 のバイト同一 diff・完了条件 1〜7 とテスト計画・Changeset・Docs の対応）/ 依存 core API 9 件の公開状況（`sanitizeErrorDescription` を依存一覧に追記）/ store 共有パターン（`../store.js` import ＋ `c.get() ?? default` の既存慣行に parStore が適合）/ `INSTALL_COMMANDS` の変更対象箇所の特定 / Experimental の明示（生成コード冒頭コメント・README・docs ガイドの 3 点が仕様に揃っている）/ 実装順序の妥当性（experimental 基盤 → 単体 → CLI → テンプレート → バイト同一確認 → E2E → docs/changeset）
- **修正**（同日反映）:
  - specification.md: 前段フックスケッチを try 内実行＋`let params` 再代入形へ全面改訂し必須要件 3 点を明文化 / `PushedRequestUriError` 別クラスの根拠（enum closed）と catch 分岐要件を公開 API 案に追記 / `assertPushedRequestUsed` の挙動と呼び出し条件を明記 / バリデーション順序を並べ替え（require ガードを 2-1 へ）/ PAR 設定値の置き場所を CLI オプション案に追記 / 結合テスト 2 項目を更新・追加 / 「実装順序」セクション新設 / U2・U5 を解決済みへ移動（未解決事項なし）
  - sources.md: リポジトリ内参照 5 件追加（enum・catch 節・store 共有・INSTALL_COMMANDS・resolveFeatures）、「記録」に enum 制約と前段フック位置修正の 2 項を追加
  - understanding-guide.md: 登場人物表の認可エンドポイント行を catch 分岐込みの記述へ更新
- **残リスク**:
  - 生成コードの実挙動（条件付き補間後のテンプレート出力・バイト同一性）は実装時の完了条件 2・3 でのみ最終確認できる（仕様段階の限界として既知）
  - `isAuthorizationRequestParams` 再ナローイングの型整合は実装時に TypeScript コンパイルで機械的に検証される
- **判定**: **Pass with changes**（指摘 1〜6 を同日中に修正反映済み。指摘 1・2 は放置すれば実装初日に 500 エラーとして露見する着手阻害要因だったが、修正後は追加調査なしで着手可能。未解決事項ゼロ・セキュリティ未解決ゼロ・受け入れ条件は客観的に検証可能。Review 3 の全確認項目を満たしたため `status: Approved` / `implementation_ready: true` へ更新する）
- **次回可能日**: —（3 回のレビューを完了。次は実装 Routine が「実装順序」ステップ 1 から着手する）
