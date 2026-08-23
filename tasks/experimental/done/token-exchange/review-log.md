# レビューログ: OAuth 2.0 Token Exchange

## Review 1

- **日付**: 2026-07-30（仕様作成日を Review 1 として実施）
- **観点**: 仕様の完全性（問題・スコープ・非目標の明確さ / 一次資料の読み違い / 公開API案の subpath export 実装可能性 / CLI統合の現実性 / 依存方向 / テスト定義 / 未解決事項の明示 / 理解資料の自立性）
- **確認資料**:
  - RFC 8693 本文（datatracker、§1.1 / §2.1 / §2.2.1 / §2.2.2 / §3 / §4 / §5 の規範的文言を直接確認）
  - `packages/core/src/token-request.ts`（`validateGrantTypeSupported` の未知 grant_type 拒否 / `TokenClientInfo` の契約）
  - `packages/core/src/token-error.ts:7-49`（`TokenErrorCode` closed enum / `TokenError` の sanitize・statusCode 実装）
  - `packages/core/src/userinfo.ts:52-83, 423-436`（`AccessTokenInfo` / `validateUserInfoAudience`）
  - `packages/core/src/access-token-issuer.ts:26-57` / `packages/core/src/token-response.ts:169-206`（issuer 契約 / `buildAccessTokenAudience` の合成規則）
  - `packages/core/src/index.ts`（依存 core API の公開状況）
  - `packages/cli/src/features.ts`（PAR で確立済みの experimental 機構）
  - `packages/cli/src/frameworks/hono/templates.ts`（`tokenRouteTemplate` 全体: 重複パラメータ拒否 :2752-2775 / 認証パイプライン終端 :2818 / `${grantTypeSupportedStep}` :2825 / config・privateKey 束縛 :2831-2833 / accessTokenIssuer 束縛 :2905-2908 / 発行・保存 :2938-3045 / catch 節 :3048-3066 / discovery `grantTypesSupported` :3415-3418 / response_mode query 固定 :7027-7028）
  - `packages/cli/src/frameworks/web-standard/templates.ts:2163`（token ルートの全ターゲット共有）
  - `tasks/experimental/done/par/`（前サイクルの候補評価・レビュー指摘・実装記録の引き継ぎ）
  - `tasks/T-019-dpop.md`（重複回避）
- **指摘**:
  1. **[生成コード整合・重要・修正] 発行トークンの aud 合成が既存ポリシーと不整合**: 初版は「検証済みの要求対象（または subject 継承値）をそのまま発行トークンの aud にする」形だった。しかし既存トークンルートは core の `buildAccessTokenAudience` で **UserInfo エンドポイントを aud の恒久メンバとして必ず含める**合成を行っており（RFC 9068 §3 の非空要件と「トークンは常に UserInfo で使える」ポリシー）、UserInfo ルートの `validateUserInfoAudience` は aud に UserInfo エンドポイントが含まれることを要求する。初版のままでは本仕様自身のテスト計画「交換後トークンで UserInfo が成功する」が必ず失敗する。`resolveExchangeTarget` の戻り値を「`buildAccessTokenAudience` の `requested` 入力」と再定義し、最終 aud 合成を既存と同じ core 関数へ委譲する形へ修正（`TokenExchangeGrant.audience` → `requestedAudience` へ改名）
  2. **[U2 解決] 分岐内で参照する束縛の宣言位置**: `config` / `privateKey` / `keyId`（`templates.ts:2831-2833`）と `accessTokenIssuer`（`:2905-2908`）はいずれも分岐挿入点（`:2818` 直後）より後で宣言されることを確認。既存宣言の移動はバイト同一検証を複雑にするため行わず、**分岐ブロック内で独自に取得する**方式に確定（分岐は `return` で完結するため二重実行にならない）。スケッチと実装順序へ反映し、U2 を解決済みへ移動
  3. **[一次資料との衝突検出・初稿反映] `resource` / `audience` の複数指定**: RFC 8693 §2.1 は同名パラメータの複数出現を許容するが、生成トークンエンドポイントは RFC 6749 §3.2 に基づき全パラメータの重複を 400 で拒否する（`templates.ts:2752-2775`）。単一値限定を「RFC 8693 が許容する形への意図的な非対応」として非目標・理解資料・sources の記録に明示した（黙って制限しない）
  4. **[一次資料確認・初稿反映] invalid な subject_token のエラーコード**: RFC 8693 §2.2.2 は invalid なトークンに `invalid_request` を指定しており、authorization_code / refresh_token の感覚で `invalid_grant` を使うのは誤り。エラー表に「`invalid_grant` ではない点に注意」と明記し、理解資料の「誤解しやすい点」にも掲載
  5. **[軽微・修正] スケッチの表記**: `buildAccessTokenAudience` 呼び出し例に、テンプレート文字列内でのみ必要なエスケープ（`\`` / `\${`）が markdown コードブロックへ混入していたのを修正
- **修正**（同日反映）:
  - specification.md: 指摘 1（入出力・公開API・バリデーション 10・スケッチ・依存 API 一覧に `buildAccessTokenAudience` 追加）/ 指摘 2（スケッチの分岐内取得・実装順序・U2 解決済み移動）/ 指摘 5
  - understanding-guide.md: データ構造表の audience 行と「誤解しやすい点」4 を aud 合成規則込みの記述へ更新
  - sources.md: `token-response.ts:169-206` / `userinfo.ts:423-436` の参照を追加、「記録」の設計判断に aud 合成の委譲を追加
- **残リスク**:
  - U1: RFC 9700 の Token Exchange 言及有無が未確認（Review 2 で原文確認。確認前は根拠として引用していない）
  - U3: E2E 専用クライアントへの交換呼び出しの組み込み方（`tests/e2e/apps` の構造確認。Review 3）
  - conformance.test.ts テンプレートの具体的な挿入関数の特定は未実施だが、PAR が同機構で追加済みのため実現性リスクは低い（Review 2 で確認）
  - 生成コードの実挙動（条件付き補間後の出力・バイト同一性）は実装時の完了条件 2・3 でのみ最終確認できる（仕様段階の限界として既知）
- **判定**: **Pass with changes**（指摘 1〜5 を同日中に修正反映済み。指摘 1 は放置すれば実装時に conformance テストで必ず露見する整合性欠陥だが、仕様段階で潰せたため Blocked には該当しない。仕様の完全性の観点で残る事項はすべて未解決事項表に明示されており、Review 2 の観点（セキュリティ・適合性）に引き継ぐ）
- **次回可能日**: 2026-07-31

## Review 2

- **日付**: 2026-07-31
- **観点**: セキュリティと適合性（脅威モデルの網羅 / 鍵・トークン・シークレットの扱い / ログ禁止情報 / 有効期限 / エラー情報の露出 / package 境界との整合 / CLI 後方互換 / 明示的有効化 / 生成コードの安全性 / セキュリティ要件のテスト検証可能性）。Review 1 との差分を重視し、仕様完全性の再確認は行わない
- **確認資料**:
  - RFC 9700 原文（datatracker 全文。"token exchange" / "8693" の言及有無を検索 — U1 の解決）
  - RFC 8693 原文（§2.1 の `resource` 定義の規範文言「MUST be an absolute URI ... MAY include a query component and MUST NOT include a fragment component」/ §2.2.2 の `invalid_request` MUST・`invalid_target` SHOULD の正確な文言 / RFC 8707 への参照が informative（draft 段階の OAUTH-RESOURCE）のみであること）
  - `packages/cli/src/frameworks/hono/templates.ts:2740-2835`（Content-Type 検証 → 重複パラメータ拒否 → クライアント認証パイプライン → `authenticatedClientId` 束縛 → `${grantTypeSupportedStep}` の実順序。分岐挿入点が仕様どおり存在することの実地確認）
  - `templates.ts:3048-3066`（catch 節が `TokenError` instanceof 分岐＋500 フォールバックのみで構成され、`TokenExchangeError` 専用分岐の追加が構造上必須であることの再確認）
  - `templates.ts:3022-3045`（既存 `accessTokenStore.set` の保存フィールド。`claims` が保存されていることを発見 → 指摘 2）
  - `templates.ts:3180-3181`（userinfo ルートの `c.get('accessTokenResolver') ?? defaultAccessTokenResolver` パターン。token ルート分岐内で同型取得が可能なことの確認）
  - `templates.ts:6387-6500, 7297` / `web-standard/templates.ts:19-21, 2136`（`parConformanceBlock` の実装と両テンプレートへの補間位置 — Review 1 残リスク「conformance 挿入関数の特定」の解消）
  - `packages/core/src/token-response.ts:169-206`（`buildAccessTokenAudience` の実シグネチャ `{userInfoEndpoint?, requested?, issuer}` がスケッチと一致）
  - `packages/core/src/token-error.ts:19-49`（`TokenError` の sanitize・statusCode・`wwwAuthenticate` が `invalid_client` 限定であること — `TokenExchangeError` が 400 固定で WWW-Authenticate 不要である根拠）
  - `packages/core/src/userinfo.ts:52-98, 415-436`（`AccessTokenInfo` の `nbf` / `claims` フィールド、`AccessTokenResolver.findAccessToken` 契約、`validateUserInfoAudience` の要求）
  - `packages/core/src/token-request.ts:63-85, 389-417`（`TokenClientInfo.tokenEndpointAuthMethod: 'none'` の存在＝public client が認証パイプラインを通過して分岐へ到達し得ること、`grantTypes` 未指定の既定 `['authorization_code']`）
- **指摘**:
  1. **[適合性・修正] `resource` の fragment 禁止が仕様書から欠落**: RFC 8693 §2.1 は「MUST be an absolute URI ... **MUST NOT include a fragment component**（query は MAY）」と規定するが、仕様書は「絶対 URI であること」しか要求していなかった。入出力表・エラー表・バリデーション 5・単体テスト計画に fragment 拒否を追加。あわせて「malformed な resource を `invalid_request` とし `invalid_target` をポリシー拒否に限定する」判断の根拠（RFC 8707 §2 は malformed を `invalid_target` に含めるが、RFC 8693 からは informative 参照のみで規範根拠にならないことを原文確認）を仕様書と sources.md に明文化
  2. **[プライバシー・修正] `claims` パラメータの継承有無が未定義**: 既存トークン発行は認可リクエストの `claims` パラメータ（OIDC Core 1.0 §5.5）を store メタデータへ保存し、UserInfo が個別クレーム返却に使う。交換後トークンでの扱いが仕様に書かれておらず、実装者が既存 `set` を流用すると意図せず継承（＝認可時の同意対象が交換先クライアントへ伝播）し得た。「継承しない」を設計判断として明文化（バリデーション 10・スケッチのコメント・プライバシー考慮・理解資料のデータ構造表と誤解しやすい点 7・conformance テスト計画に claims 非継承の契約固定を追加）
  3. **[堅牢性・修正] 残存秒数の丸め規則が未規定**: `computeExchangedTokenLifetime` の残存秒数計算で丸め方向を規定していなかった。`subjectExpiresAt - Math.floor(now/1000)` と規定すれば、期限検証（`expiresAt > now`）通過時に残存が必ず 1 以上になり `expires_in: 0` のトークンが発行され得ないことを確認し、バリデーション 9 に保証条件込みで明記。単体テスト計画に残存 1 秒の境界ケースを追加
  4. **[確認・軽微修正] `grantTypes` 未指定クライアントの扱い**: core の既定は `['authorization_code']`（`token-request.ts:71-77`）のため、`grantTypes` 未指定クライアントは追加実装なしで `unauthorized_client` に落ちる。安全側であることを確認し、バリデーション 4 と単体テスト計画に明記
  5. **[確認のみ・指摘なし] セキュリティ設計の実地確認**: (a) 分岐挿入点・catch 構造・resolver 取得パターン・`buildAccessTokenAudience` シグネチャはすべて実コードと一致 (b) public client（`tokenEndpointAuthMethod: 'none'`）が認証パイプラインを通過して分岐へ到達し得るため、仕様の `'none'` 拒否は必須かつ正しい位置 (c) エラー応答は固定文言＋`sanitizeErrorDescription` 経由でオラクル化・インジェクションなし (d) CSRF（Cookie 不使用）・SSRF（外部フェッチなし）の構造的非該当を確認 (e) 交換の連鎖でも scope 部分集合・寿命 cap により権限が単調に狭まる設計に穴なし (f) 無効時バイト同一（完了条件 3）と明示的有効化（デフォルト無効・client `grantTypes` への URN 明示登録）で CLI 後方互換に問題なし (g) U1 は「RFC 9700 に Token Exchange への言及なし」で解決
- **修正**（同日反映）: specification.md（指摘 1〜4 と U1 解決の記録、conformance ブロック挿入機構の具体化）/ understanding-guide.md（claims 非継承のデータ構造行・誤解しやすい点 7）/ sources.md（RFC 9700 確認済み化・リポジトリ参照 4 件追加・設計判断 2 件追記）
- **残リスク**:
  - `allowedTargets` がグローバル許可リストでありクライアント単位ではないため、交換を許可された任意のクライアントは、手にした任意の有効トークンを許可リスト内の任意の対象へ交換できる。これは RFC 8693 の impersonation モデルに内在する性質で、クライアント認証＋`grantTypes` 明示登録＋confidential 限定で緩和済み。クライアント単位の許可への発展は仕様の「Experimentalにする理由」「昇格判断の観点 2」に記録済み（PoC 用途の初期スコープとして受容）
  - U3（E2E クライアント構造）は Review 3 の観点（実装着手可否）で確認する
  - 生成コードの実挙動（バイト同一性・条件付き補間の展開結果）は実装時の完了条件でのみ最終確認できる（Review 1 から変わらず、仕様段階の既知の限界）
- **判定**: **Pass with changes**（指摘 1〜4 を同日中に修正反映済み。いずれも仕様文書の欠落・未規定の明文化であり、設計自体の変更を要する重大なセキュリティ問題は発見されなかった。Blocked に該当する未解決のセキュリティ事項はなし）
- **次回可能日**: 2026-08-01

## Review 3

- **日付**: 2026-08-01
- **観点**: 実装着手可否（追加調査なしで着手できるか / 受け入れ条件の客観性 / 対象ファイルと変更範囲 / API・CLI・テスト・Docs・Changeset の一貫性 / 実装順序と検証方法 / Experimental であることの利用者への明示）。Review 1・2 との差分として U3（E2E 組み込み）の解決と、Review 2 以降に main へ入った変更（`f2fc953` setup コマンド / `95c9efe` publish 設定）との整合確認を重視
- **確認資料**:
  - `tests/e2e/playwright.config.ts`（`oidcClientsJson` による E2E クライアント登録（`e2e-client` は confidential / `client_secret_post`）・`webServer` env での `OIDC_CLIENTS_JSON` / `CLIENT_ID` / `CLIENT_SECRET` 注入・OP 起動が `pnpm --filter <sample> start` であること — U3 の資格情報配置の解決）
  - `tests/e2e/apps/client.mjs`（`/start-par` の追加パターン・`formPost` / `fetchJson` ヘルパ・`transactions` Map・`renderResult` の data-testid 描画。`/start` が認可リクエストに `audience=resourceServerUrl` を送ること — U3 の組み込み方の解決）
  - `tests/e2e/apps/resource-server.mjs:45-47`（introspection の `aud` に自 URL を要求する検証 — audience 省略交換（subject 継承）で E2E が成立する根拠）
  - `tests/e2e/specs/pushed-authorization-requests.spec.ts`（discovery 広告に基づく `test.skip` パターン — 共有 spec suite を全サンプルで green に保つ先例）
  - `samples/hono-cloudflare/src/app.ts:27`（登録クライアントが `OIDC_CLIENTS_JSON` env 由来 — E2E のためにサンプル `config.ts` を編集不要である根拠）
  - `samples/hono-cloudflare/src/oidc-provider/conformance.test.ts:1975-2009`（`parConfig.requirePushedAuthorizationRequests` をテスト内で書き換えて復元するパターン — `tokenExchangeConfig.allowedTargets` の conformance 検証手段の先例）
  - `packages/cli/src/frameworks/hono/templates.ts`（`tokenClient`（`resolveAuthenticatedTokenClient` の戻り値。`grantTypes` / `tokenEndpointAuthMethod` を持つ）と `accessTokenStore` が分岐挿入点より前で束縛済みであること — スケッチの `client: tokenClient` が追加束縛なしで成立する確認 / 全アンカーの現存確認: `const authenticatedClientId` :2821・`${grantTypeSupportedStep}` :2828・`grantTypesSupported` :3438・`parConformanceBlock` :6410・conformance 補間列 :7320）
  - `packages/cli/src/frameworks/web-standard/templates.ts:19-31, 2136, 2163`（conformance 補間列と token ルート共有が Review 2 時点から不変）
  - `git log origin/main`（Review 2 以降の変更 `f2fc953`（`packages/cli/src/index.ts` の setup コマンドのみでテンプレート無関係）・`95c9efe` の diff 精査）
- **指摘**:
  1. **[U3 解決・修正] E2E 組み込みの具体化**: `client.mjs` への `/start-exchange` ルート追加（`/start-par` と同型）・資格情報は既存 env 注入をそのまま利用・`oidcClientsJson` の `e2e-client.grantTypes` へ URN 追加（サンプル側編集不要）・audience 省略交換で `allowedTargets: []` のまま E2E が成立・discovery ベースの skip パターン、を E2E テスト計画へ明記。U3 を解決済みへ移動
  2. **[検証手段の具体化・修正] `allowedTargets` の conformance 検証方法**: 生成デフォルトが空配列のため `invalid_target` / 許可成功の両ケースをどう検証するかが未記載だった。PAR の `parConfig` テスト内書き換え・復元パターン（実在確認済み）と同型で `tokenExchangeConfig.allowedTargets` を書き換える方式を結合テスト計画に明記
  3. **[外部ブロッカー検出・記録] main のコンフリクトマーカー混入**: 2026-08-01 の `95c9efe` で `packages/cli/src/frameworks/hono/templates.ts`・`packages/core/src/client-auth.ts`・`packages/cli/src/__tests__/hono-generator.test.ts` に未解決マーカーがコミットされており、リポジトリがコンパイル不能。**本仕様の欠陥ではない**（アンカー全数の現存と構造不変を確認済み。行番号は混入中 +3〜+23 ずれるが解消後に戻る）が、実装 Routine が着手時に必ず衝突するため、実装順序の冒頭に「着手前提」として解消確認（正しい解消側は `Updated upstream` = PAR を含む側）を明記した
  4. **[確認のみ・指摘なし] 実装着手可否の残り観点**: (a) 完了条件 1〜7 はすべてコマンド実行・diff・応答表比較で客観判定できる (b) 変更対象ファイルは仕様内で列挙済みで、Review 3 で実在を確認した範囲と齟齬なし (c) 公開 API（ステップ関数）・CLI スケッチ・テスト計画・ドキュメント要件・changeset（experimental minor / cli minor / core なし）は相互参照が一貫 (d) Experimental 明示は生成コード冒頭コメント・docs ガイド・README 行の 3 箇所で計画済み (e) `f2fc953`（setup コマンド）はテンプレート・features 機構に触れておらず本仕様に影響なし
- **修正**（同日反映）: specification.md（E2E テスト計画の組み込み方 / conformance の `allowedTargets` 書き換えパターン / 実装順序の着手前提 / U3 解決済み移動）/ sources.md（Review 3 のリポジトリ内参照 6 件追加）
- **残リスク**:
  - main のコンフリクトマーカー（指摘 3）が解消されるまで実装は物理的に開始できない。本 Routine はプロダクションコードを変更しない制約のため修復せず、着手前提として記録し所有者へ報告する
  - 生成コードの実挙動（バイト同一性・条件付き補間の展開結果）は実装時の完了条件でのみ最終確認できる（Review 1 から変わらず、仕様段階の既知の限界）
  - `allowedTargets` がグローバル許可リストである初期スコープの性質（Review 2 記録済み。昇格判断の観点 2 で追跡）
- **判定**: **Pass with changes**（指摘 1・2 を同日中に反映。指摘 3 は仕様外の外部ブロッカーであり、仕様自体は 3 観点のレビューを完了し実装着手可能な水準に達したため Approved とする。実装 Routine は着手前提の確認を必須とする）
- **次回可能日**: なし（3 回完了。次はレビューではなく実装 Routine の担当）
