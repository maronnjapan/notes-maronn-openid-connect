# レビューログ: device-authorization-grant

## Review 1

- **日付**: 2026-08-05（仕様作成日と同日。運用ルール上 Review 1 として扱う）
- **観点**: 仕様の完全性（問題・スコープ・非目標の明確さ / 一次資料の読み違い / 公開 API 案が subpath export で実装可能か / CLI 統合の現実性 / 依存方向 / テスト定義 / 未解決事項の明示 / 理解資料の自立性）
- **確認資料**:
  - RFC 8628 全文（datatracker、2026-08-05 取得）— §3.1〜3.5 の必須/任意フィールド、エラーコード 4 種、slow_down の +5 秒規則、interval 既定 5 秒、§4 メタデータ名、§6.1 base-20 文字種を仕様書の記載と突き合わせ、読み違いなしを確認
  - `packages/cli/src/frameworks/hono/templates.ts`（tokenExchangeDispatchStep 3106-3216 / loginRouteTemplate 4183-4375 / parStore・views 契約）— 分岐位置・セッション確立手順・store レジストリパターンが実在の構造と一致することを確認
  - `packages/cli/src/frameworks/web-standard/templates.ts` — hono テンプレート変換共有により 4 フレームワークへ展開できることを確認
  - `packages/experimental/package.json` — subpath exports 追加が既存 3 機能と同型で成立することを確認
  - `packages/core/src/authorization-request.ts`（validateAuthorizationScope）— scope/openid 必須プロファイルの根拠を確認
  - `tasks/experimental/done/jarm/specification.md` — 前サイクルが本機能を次サイクル有力候補と明記していることを確認
- **指摘**:
  1. `/device/login` に CSRF 保護が定義されていなかった。フォージされたログイン POST が被害者ブラウザに攻撃者の OP セッションを確立し得る（ログイン CSRF）。既存 login ルートはトランザクション CSRF トークンで同種の防御を持っており、水準が揃っていない
  2. user_code の衝突（pending レコード間の一意性）時の挙動が未定義で、`findByUserCode` の契約が曖昧になる
  3. `GET /device` の user_code 事前入力はクエリ値を HTML に埋め込むため、エスケープ要件が明記されていなかった
- **修正**:
  1. CSRF トークンの発行タイミングを「user_code 照合成功時」に前倒しし、`/device/login` と `/device/approve` の両 POST で照合必須に変更。公開 API に `validateVerificationCsrfToken` を追加し、ストア契約コメント・バリデーション表・セキュリティ要件を整合させた
  2. user_code 生成時に `findByUserCode` で衝突確認し再生成（上限 5 回）する規則を明記
  3. views の既存エスケープ規則に従う旨を検証 UI の表に明記
- **残リスク**:
  - user_code 照合のタイミング差（ストア検索由来）は実在コード推測にわずかに使える可能性が残るが、エントロピー × TTL を主防御とする設計判断としてセキュリティ要件に明記済み。Review 2 で再評価する
  - アプリ内グローバルレート制限を持たない判断（デプロイ基盤責務への切り出し）は Review 2 のセキュリティ観点で再確認する
- **判定**: Pass with changes（指摘 3 件はすべて同日修正済み）
- **次回可能日**: 2026-08-06（Review 2: セキュリティと適合性）

## Review 2

- **日付**: 2026-08-06
- **観点**: セキュリティと適合性（認証認可上の脅威 / 鍵・トークン・シークレットの扱い / ログ禁止情報 / 有効期限 / エラー情報の露出 / package 境界 / CLI 後方互換 / 明示的有効化 / 生成コードの安全性 / セキュリティ要件のテスト検証可能性）。Review 1 と重複する完全性確認は繰り返さず、Review 1 の修正内容（CSRF）と残リスク 2 件の再評価を中心に据えた
- **確認資料**:
  - `packages/cli/src/frameworks/hono/templates.ts:527-600`（transaction-binding Cookie ヘルパーと設計コメント）、同 4234 行・4429 行付近（csrf_token 埋め込み前のバインディング検査）、同 6363-6372 行（「binding cookie 無しでは csrf_token を露出しない」contract テスト）— 既存リポジトリが「識別子を知る第三者が csrf_token を読める」問題をどう解いているかの確認
  - `packages/core/src/auth-transaction.ts`（`computeTransactionBindingHash` / `validateTransactionBinding` が core 公開 API であること）
  - `packages/cli/src/features.ts`（transaction-binding が optional・既定オフである理由のコメント / EXPERIMENTAL_FEATURES の追加位置 / DEFAULT_FEATURES の既定オフ機構）
  - `packages/experimental/package.json`（subpath exports の現況。既存 3 機能と同型で追加可能なこと・package.json が既に存在すること）
  - `packages/experimental/src/par/store.ts`（atomic consume・キーのパラメータ化注意書きの書式）
  - セッション Cookie / トランザクション Cookie の属性（HttpOnly / Secure / SameSite=Lax）の実装値
  - `tasks/p2-login-attempt-throttling-subject-scope.md` / `tasks/p3-csrf-token-constant-time-comparison.md`（未着手の関連セキュリティタスク）
  - RFC 8628 §5.1〜§5.7（脅威対策の再照合）
- **指摘**:
  1. **（重大）Review 1 で導入したレコード紐付き CSRF トークンは、主要脅威に対して無効**。device フローでは攻撃者がフロー開始者として user_code を必ず知っており、`POST /device` を自分で叩けば有効な csrf_token を取得できる。したがって (a) 被害者ブラウザへの `POST /device/approve` フォージ（承認強要 → 攻撃者デバイスへのトークン流出）も (b) `POST /device/login` フォージ（ログイン CSRF。Review 1 がまさに防ごうとした脅威）も、トークンでは防げない。残る防御はセッション Cookie の SameSite=Lax のみで、(b) はセッション Cookie を必要としないため SameSite でも防げない。既存 transaction-binding の設計コメント（templates.ts:534-542）が指摘する「CSRF 防御が識別子の秘匿に還元されてしまう」問題そのものであり、authorize フローでは transaction_id が通常秘匿されるため opt-in ハードニングで足りるが、device フローでは識別子（user_code）が設計上攻撃者に既知のため、ブラウザバインディングが唯一実効的な CSRF 防御になる
  2. **（中）`/device/login` 経由の資格情報総当たりの集計上限が無い**ことが仕様に明記されていなかった。レコード単位 maxLoginAttempts=5 はあるが、攻撃者はレコードを無制限に発行できる。既存 `/login` と同一の残存面（未着手タスク p2-login-attempt-throttling-subject-scope の責務）だが、仕様が無言だと「対策済み」に読める
  3. **（小）CSRF 照合の比較方法が未規定**。既存タスク p3-csrf-token-constant-time-comparison が login / consent の `validateCsrfToken` を対象にしており、本機能の照合の水準と関係を明記すべき
  4. **（小）ポーリングを止めたデバイスの期限切れレコードが削除経路を持たない**（削除はポーリング時のみ）。ストア実装の掃除方針が未規定で、掃除すると `expired_token` でなく `invalid_grant` になる相互作用も未記載
- **修正**（すべて同日反映）:
  1. ブラウザバインディングを常時有効の必須要件として導入: `POST /device` 照合成功時に bindingSecret を発行し、生値を `oidc_device_<正規化user_code>` Cookie（HttpOnly / Secure / SameSite=Lax / Max-Age=残TTL）で、SHA-256 ハッシュのみをレコード（`bindingHash`）で保持。`/device/login` `/device/approve` は Cookie 照合を前提条件とし、完了時に Cookie を削除。公開 API を `issueVerificationBinding`（bindingSecret + csrfToken のペア発行・回転）/ `validateVerificationBinding` に再構成し、csrf_token は多層防御として維持。フロー図・バリデーション表・テスト計画（Set-Cookie 属性固定・Cookie 無し 403・回転・削除の conformance 検証、binding の単体テスト）・完了条件（条件 8 追加）・curl 手順（cookie jar）・理解資料（脅威 4 節と誤解 2 項を追加）を整合させた。transaction-binding が opt-in なのに対し常時有効とする理由（識別子の秘匿に頼れない）も仕様・理解資料の両方に明記
  2. セキュリティ要件に資格情報総当たりの残存面を明記し、p2-login-attempt-throttling-subject-scope 実装時に `/device/login` を対象へ含めることを本仕様の要件として記載
  3. バインディング照合はハッシュ対ハッシュ比較でタイミング攻撃が成立しないこと、csrf_token 直接比較は既存水準に揃え p3 タスクの適用範囲に含めることを明記
  4. ストア契約に期限切れレコードの自主破棄（TTL 相当の猶予後）と、破棄後ポーリングが `invalid_grant` になっても相互運用上問題ない根拠を明記
- **Review 1 残リスクの再評価**:
  - user_code 照合のタイミング差: エントロピー（20^8）× TTL（600 秒）を主防御とする設計判断を維持。タイミング差で得られるのは user_code の実在性のみで、実在を知っても承認操作には至れない（バインディング導入後は承認画面到達に Cookie 発行が伴い観測可能）。判断変更なし
  - アプリ内グローバルレート制限を持たない判断: RFC 8628 §5.1 の対策 3 点（エントロピー・TTL・レート制限）のうちレート制限をデプロイ基盤責務へ切り出す判断を維持。Cloudflare Workers 等でアプリ内カウンタが成立しない根拠は妥当。生成コードコメント・理解資料への明示は仕様済み
- **適合性の確認**: エラーコード・応答フィールドは RFC 8628 登録値のみ / 明示的有効化（既定オフ・DEFAULT_FEATURES 機構）と feature 無効時の不変性テストが定義済み / 依存方向は package 境界規約と一致 / experimental 機能間のコード共有なし（バインディングのハッシュは core 公開 API または機能内実装で賄う方針も規約適合）/ ログ禁止情報に bindingSecret を追加
- **残リスク**:
  - リモートフィッシング（§5.4）はプロトコル上完全には防げない（承認画面での user_code 再表示 + 短 TTL の緩和のみ）。RFC 自身が認める限界であり、理解資料に記載済み
  - 資格情報総当たりの集計上限は p2-login-attempt-throttling-subject-scope 実装まで既存 `/login` と同水準のまま（本機能で悪化はしない）
- **判定**: Pass with changes（指摘 4 件はすべて同日修正済み。Blocked 相当の未解決セキュリティ事項なし）
- **次回可能日**: 2026-08-07（Review 3: 実装着手可否）

## Review 3

- **日付**: 2026-08-07（Review 2 と異なる暦日 / `next_review_on` 到達を確認して実施）
- **観点**: 実装着手可否（追加調査なしで着手できるか / 受け入れ条件の客観性 / 対象ファイルと変更範囲 / API・CLI・テスト・Docs・Changeset の一貫性 / 実装順序と検証方法 / Experimental であることの利用者への明示）。Review 2 との差分として、main の移動（db9cbd1 → b69c525）の影響確認と、仕様が参照する実装パターンの実地照合を中心に据えた
- **確認資料**:
  - main b69c525 で `git diff db9cbd1..b69c525 -- packages/` が空であることを確認（Review 2 以降 `packages/` に変更なし。仕様・sources の行番号は全件現行のまま有効: tokenExchangeDispatchStep :3106 / transaction-binding ヘルパー :527-600 / loginRouteTemplate :4183 / `validateAuthorizationScope` :997 / `generateRandomString` :65 を個別に再確認）
  - `packages/experimental/package.json`（exports が jarm / par / token-exchange の 3 subpath で package 名は `@maronn-openid-connect/experimental`。仕様の subpath 追加が同型で成立）
  - `packages/cli/src/features.ts:60-131`（`EXPERIMENTAL_FEATURES` / `EXPERIMENTAL_FEATURE_KEYS` / `DEFAULT_FEATURES` の追加箇所）
  - `packages/cli/src/index.ts:21-31, 55-75`（`withExperimentalPackage` のハードコード feature チェック / CLI コマンドが `generate` / `setup` のみであること / ヘルプの experimental 一覧が自動導出であること）
  - `packages/cli/src/frameworks/hono/templates.ts:24-48`（`OIDC_ENDPOINT_METHODS` + `enforceOidcEndpointMethod`。`parMethod` の feature 条件付き補間が仕様の「許可メソッドマップ追加」の実在パターンであること）、:6358-6360（Set-Cookie 属性の endsWith 固定検証の既存書式）、:7601-7615（405/Allow のケース表）
  - `tests/e2e/apps/client.mjs`（`/start-par` / `/start-exchange` / `/start-jarm` の機能別ルートパターン）/ `tests/e2e/specs/`（jarm.spec.ts 等の配置）/ `samples/hono-cloudflare/package.json:8`（generate スクリプトの `--enable` フラグ列）
  - `docs/library-document/src/content/docs/experimental/`（par.md / token-exchange.md / jarm.md の 3 点構成と有効化手順の記法 `maronn-oidc generate hono --enable par`）
  - `.github/scripts/ensure-experimental-changeset.mjs` の存在と CLAUDE.md / RELEASE.md の changeset 規約（仕様の Changeset 要件「experimental 手書き禁止・CLI のみ minor」が現行 release contract と一致）
  - `tasks/experimental/done/jarm/{specification.md,review-log.md,state.yaml}`（承認済み仕様の「実装順序」節の書式と Review 3 の判定水準）
- **指摘**:
  1. **[着手阻害・修正] 「実装順序」節が無い**: Review 3 の確認項目「実装順序と検証方法」に対し、仕様は変更対象ファイルとテスト計画を持つが着手順が未定義だった（JARM の承認済み仕様は実装順序節を持つ）。experimental 実装 → exports → features → テンプレート → バイト同一確認 → サンプル再生成 + E2E → docs/changeset の 7 ステップを完了条件番号との対応付きで追加
  2. **[修正] 理解資料の CLI コマンドが実在しない**: 「実装後の利用方法」が `npx @maronn-openid-connect/cli install hono` としていたが、CLI のコマンドは `generate` / `setup` のみで `install` は存在しない。docs の記法（`maronn-oidc generate hono --enable par`）に合わせ `maronn-oidc generate hono --enable device-authorization-grant --output ./src/oidc-provider` へ修正
  3. **[変更範囲の欠落・修正] `packages/cli/src/index.ts` の `withExperimentalPackage` が変更対象に無かった**: install guidance へ experimental package を挿入する条件が `!features.par && !features.tokenExchange && !features.jarm` のハードコードで、`deviceAuthorizationGrant` を足さないと `--enable device-authorization-grant` 単独時に依存案内が欠ける。CLI オプション案へ変更必須箇所として追記（ヘルプ文字列は自動導出のため変更不要であることも明記）
  4. **[E2E 組み込み方の確定・修正] E2E 計画が「tests/e2e/apps に擬似クライアントを配置」と新規ファイルを示唆していた**: 既存パターンは `client.mjs` へ `/start-*` ルートを足す方式（par / token-exchange / jarm で実証済み）。`/start-device`（device_authorization 実行 + バックグラウンドポーリング開始）と `/device-result`（終了状態の取得）の 2 ルート追加、spec ファイル `device-authorization-grant.spec.ts` 新設（discovery 自己スキップ踏襲）、`samples/*/package.json` の generate スクリプトへのフラグ追加を確定内容としてテスト計画 E2E 節を全面更新
  5. **[確認・問題なし] 受け入れ条件の客観性と一貫性**: 完了条件 1〜8 はすべて機械的に検証可能（テスト通過・バイト diff・discovery 固定値・`git diff --exit-code packages/core` 相当・ログ検査とテスト保証）。公開 API 案（subpath export・関数シグネチャ）/ CLI オプション案 / ストア契約 / テスト計画 / ドキュメント要件 / Changeset 要件を通し読みし矛盾なし。依存する core 公開 API（`TokenError` / `generateRandomString` / 既存クライアント認証パイプライン）は現行 main で全件公開済み。conformance の Set-Cookie 属性固定検証は既存 transaction-binding テスト（:6358-6360）と同書式で書ける
  6. **[確認・問題なし] Experimental の明示**: 生成コード冒頭コメント（EXPERIMENTAL・API 不安定・レート制限はデプロイ基盤責務）・`docs/library-document` experimental 配下ページ・`packages/experimental/README.md` 機能一覧の 3 点構成が既存 3 機能と揃っている。既定オフ・`--enable` 明示有効化・無効時バイト同一（完了条件 2）も定義済み
  7. **[確認・問題なし] 405/Allow の網羅**: 新規エンドポイント 4 面を `OIDC_ENDPOINT_METHODS` に足す以上、HTTP メソッド強制の conformance ケース表にも feature 有効時のみ追加する必要がある。結合テスト計画へ 1 行追記した（指摘というより整合の補完）
- **修正**（すべて同日反映）:
  - specification.md: 実装順序節の新設（指摘 1）/ `withExperimentalPackage` の変更必須箇所追記（指摘 3）/ E2E 節の確定内容への全面更新（指摘 4）/ 405 ケース表追記と `OIDC_ENDPOINT_METHODS` の実名明記（指摘 7）
  - understanding-guide.md: CLI コマンドの修正（指摘 2）。その他の記述は現行 main でも正確なため変更なし
  - sources.md: リポジトリ内参照 8 件を追加（OIDC_ENDPOINT_METHODS / withExperimentalPackage / CLI コマンド一覧 / client.mjs / samples generate スクリプト / Set-Cookie 検証書式 / JARM 実装順序書式）
- **残リスク**:
  - 生成コードの実挙動（条件付き補間後の出力・バイト同一性・transaction-binding / par / jarm との組み合わせ）は実装時の完了条件 1・2 でのみ最終確認できる（過去 3 機能と同じ、仕様段階の既知の限界）
  - リモートフィッシング（§5.4）と資格情報総当たりの集計上限（p2 タスク待ち）は Review 2 で確定した受容済みリスクのまま変更なし
- **判定**: **Pass with changes**（指摘 1〜4・7 を同日中に修正反映済み。指摘 1〜4 は放置すれば実装時の調査・手戻り要因だったが、修正後は追加調査なしで実装順序ステップ 1 から着手可能。未解決事項ゼロ・セキュリティ未解決ゼロ・受け入れ条件は客観的に検証可能。Review 3 の全確認項目を満たしたため `status: Approved` / `implementation_ready: true` へ更新する）
- **次回可能日**: —（3 回のレビューを完了。次は実装 Routine が「実装順序」ステップ 1 から着手する）
