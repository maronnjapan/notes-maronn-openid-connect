# レビューログ: JWT Secured Authorization Response Mode (JARM)

## Review 1

- **日付**: 2026-08-02（仕様作成日を Review 1 として実施）
- **観点**: 仕様の完全性（問題・スコープ・非目標の明確さ / 一次資料の読み違い / 公開API案の subpath export 実装可能性 / CLI統合の現実性 / 依存方向 / テスト定義 / 未解決事項の明示 / 理解資料の自立性）
- **確認資料**:
  - JARM Final 原文（openid.net。§2.1 のクレーム構造・最大寿命 10 分 RECOMMENDED・成功/エラー実例、§2.3.1 の `response` 単一パラメータ運搬、§2.3.4 の `jwt` 省略形（code のデフォルトは query.jwt）、§2.4 の `alg: none` 拒否 MUST と kid、§3 の未登録時デフォルト RS256、§4 の AS メタデータ、§5.1〜5.4。実例ヘッダーに `typ` が無いことも確認）
  - RFC 9700 原文（datatracker。§2.1 の JARM への言及「or through OAuth 2.0 JARM responses」、§4.4 の mix-up 対策 MUST と 2 方式）
  - `packages/core/src/authorization-request.ts:853-888`（`rejectUnsupportedRequestParams` が response_mode を解釈しないこと = core 無変更の根拠）/ `:105-132`（`ClientInfo` closed = クライアント別 alg 非目標の根拠）
  - `packages/core/src/auth-transaction.ts:96-141`（`AuthTransaction` closed interface / store 契約 get・put・delete）
  - `packages/core/src/signing-key.ts:4-26`（`SigningKey` / `SigningKeyProvider` の形）
  - `packages/core/src/index.ts`（`AuthorizationError` :27 / `sanitizeErrorDescription` :150 / `AuthTransaction` :170 / `SigningKey(Provider)` :229-230 の公開確認。crypto-utils からの公開は `generateRandomString` / `extractAlgorithmParamsFromJwk` / `getJwaAlgorithm` のみで、低レベル署名ヘルパー `sign` / `arrayBufferToBase64Url` は非公開 → JWS 自前実装方針の根拠）
  - `packages/core/src/discovery.ts:56, 104, 242-243`（`responseModesSupported` が既存 `DiscoveryConfig` フィールドであること — 指摘 1）
  - `packages/cli/src/features.ts`（experimental 機構の現状: `EXPERIMENTAL_FEATURES = ['par', 'token-exchange']` :37）
  - `packages/cli/src/frameworks/hono/templates.ts`（`effectiveParams` 束縛 :1650-1660 / `redirectUri`・`state` 確定 :1940-1942 / `buildErrorRedirect` 定義 :1829-1844 と 8 呼び出しサイト :2019-2103 / インライン応答構築 :2133-2138, 2198-2203, 2225-2238, 3953-3961, 4012-4018 / discovery `responseModesSupported: ['query']` :3683-3687 / PAR discovery マージ :3628-3641 / conformance 期待値 :7757-7758）
  - `packages/cli/src/frameworks/web-standard/templates.ts:2169-2185`（全ルートの hono テンプレート共有）/ `:1903-1904`（conformance 期待値）
  - `tasks/experimental/done/par/` / `tasks/experimental/done/token-exchange/`（候補評価の引き継ぎ・条件付き補間/discovery マージ/分岐内取得パターンの実績）
  - `tasks/T-019-dpop.md` / `tasks/p2-signing-alg-ps256.md`（重複回避・alg 拡張タスクとの関係）
- **指摘**:
  1. **[生成コード整合・修正] discovery の `response_modes_supported` はスプレッドマージ不要**: 初稿は JARM の 2 メタデータをどちらも「PAR と同じスプレッドマージで追加」としていたが、`response_modes_supported` は core の既存設定フィールド `responseModesSupported`（`discovery.ts:56, 242-243`）から生成されており、テンプレートの固定値 `['query']`（`templates.ts:3687`）を jarm 有効時のみ差し替える方が既存機構に乗る。スプレッドマージが必要なのは core の `DiscoveryConfig` に無い `authorization_signing_alg_values_supported` のみ。CLI オプション案と sources.md を修正
  2. **[実地確認・仕様に反映済み] 応答構築サイトの棚卸しの完全性**: `grep "searchParams.set('error'\|searchParams.set('code'"` の全件が、仕様の棚卸し表（ヘルパー 1 + インライン 5）と一致することを確認（1837 / 2134 / 2199 / 2226 / 3954 / 4013。`buildErrorRedirect` の呼び出しは定義 1 + 8 サイトで、すべて `transaction` がスコープにある prompt=none 系）。内部リダイレクト（login / consent への遷移 :2212, 2220, 3879）は認可レスポンスではないため対象外であることも確認
  3. **[一次資料確認・初稿反映] `typ` ヘッダー・`iss` パラメータ・省略形 `jwt` の扱い**: (a) JARM は応答 JWT の `typ` を規定せず実例ヘッダーにも無い → 付けない設計を明記 (b) §2.3.1 の応答パラメータは `response` のみ → 素の `code` / `state` / `iss` を付けないことをテスト計画の固定検証に含めた (c) `jwt` 省略形は §2.3.4 で code のデフォルトが query.jwt → 同義扱いを仕様化
  4. **[スコープ判断・初稿反映] `.jwt` 系以外の response_mode を従来どおり無視する隔離原則**: 現行 OP は response_mode を全面無視しており、`form_post` 等の非 JWT 値への拒否を追加すると JARM のスコープ外の挙動変更になる。「`.jwt` 系のみ解釈追加・それ以外は現状維持」を非目標＋設計判断として明文化（黙って挙動を変えない）
  5. **[実装可能性確認・指摘なし] 公開 API 案の検証**: (a) subpath export は package.json への `exports["./jarm"]` 追加のみで PAR / token-exchange と同型 (b) `resolveJarmResponseMode` が例外でなく判別共用体を返す設計は、`invalid_request` が core の `AuthorizationErrorCode` に存在するため専用エラークラス不要という帰結と整合（PAR の `PushedRequestUriError` が必要だった理由との対比を仕様に明記済み） (c) 依存する core API はすべて公開済み。JWS 生成は低レベルヘルパー非公開のため experimental 内自前実装（重複許容方針と整合）
- **修正**（同日反映）:
  - specification.md: 指摘 1（CLI オプション案の discovery 記述を「既存 `responseModesSupported` 差し替え＋alg のみスプレッドマージ」へ修正）
  - sources.md: 指摘 1（`discovery.ts` 参照行の追加、discovery/conformance 参照の分離・行番号修正）
  - 指摘 2〜5 は初稿執筆中の実地確認として仕様に反映済み（棚卸し表・非目標・設計判断の記録）
- **残リスク**:
  - U1: `buildErrorRedirect` の 8 サイトすべてで `transaction` がスコープにあることは grep とサイト周辺の目視で確認したが、各サイトの put 前/put 後の別（JARM モードが transaction 保存前に確定しているか）の網羅確認は未実施（Review 2 でテンプレートを通読して確認）
  - U2: 応答 JWT 生成の async 化に伴う `buildErrorRedirect` 呼び出しサイトの `await` 追加を、jarm 無効時バイト同一と両立させる具体的な補間戦略が未確定（Review 2）
  - U3: E2E 専用クライアント（`tests/e2e/apps`)への JARM 検証組み込み方が未確認（Review 3)
  - 生成コードの実挙動（条件付き補間後の出力・バイト同一性）は実装時の完了条件 2・3 でのみ最終確認できる（仕様段階の限界として既知。PAR / Token Exchange と同じ扱い）
- **判定**: **Pass with changes**（指摘 1 を同日中に修正反映済み。仕様の完全性の観点で残る事項はすべて未解決事項表（U1〜U3）に明示されており、いずれもセキュリティ上の未解決事項ではない。Review 2 の観点（セキュリティ・適合性）へ引き継ぐ）
- **次回可能日**: 2026-08-03

## Review 2

- **日付**: 2026-08-03（Review 1 と異なる暦日 / `next_review_on` 到達を確認して実施）
- **観点**: セキュリティと適合性（認証認可上の脅威: リプレイ・CSRF・SSRF・インジェクション / 鍵・トークン・シークレットの扱い / ログ禁止情報 / 有効期限 / エラー情報の露出 / package 境界との整合 / CLI 後方互換・明示的有効化 / 生成コードの安全性 / 切り出し可能な構造 / セキュリティ要件のテスト検証可能性）。Review 1 との差分として、前回残した U1・U2（テンプレート実地確認）の解決を含む
- **確認資料**:
  - JARM Final 原文（2026-08-03 再アクセス。§5.1〜5.4 の各内容を精読: §5.1 は**クライアント側**の鍵解決 DoS（細工された `iss` → 巨大/低速 JWKS URL。iss 確認を鍵取得より先に行う MUST）、§5.2 は単一メッセージの完全性保護＋PKCE 併用推奨、§5.3 は `iss`/`aud` による mix-up 防御、§5.4 は JWE のみが code 漏えいを解決。`typ` 非定義・最大寿命 10 分 RECOMMENDED も再確認 → Review 1 の読解に読み違いなし）
  - `packages/cli/src/frameworks/hono/templates.ts`（main 45997d8 で通読）: `buildErrorRedirect` 定義 :1829-1844 と 8 呼び出しサイト :2019, 2035, 2048, 2061, 2068, 2095, 2101, 2108 / `createAuthTransaction`〜put :2003-2011 / 成功インライン :2138-2143, 2211-2216 / catch 節 :2236-2251 / consent ルート :3957（`getAuthTransaction`）, 3965-3974, 4024-4031 / context ミドルウェア :227, 257-259 / jwks ルート :3490-3567 / PAR の try 前 `let` 宣言 :1691-1693
  - `packages/core/src/authorization-request.ts:286-313`（`AuthorizationError` コンストラクタのサニタイズ）/ `packages/core/src/error-utils.ts:14-26`（`sanitizeErrorDescription` が RFC 6749 §5.2 文字集合へ強制）
- **指摘と確認結果**:
  1. **[U1 解決] `buildErrorRedirect` 8 サイトの網羅確認**: 8 サイト全件が `createAuthTransaction`（:2003）直後の**ローカル変数** `transaction` を参照しており、トランザクション不在のサイトは無い。put（:2007）は全サイトより前に完了。ローカル変数参照のため authorize ルートの応答（棚卸し #1〜#4）は store round-trip に依存せず、store の未知フィールド保存契約に依存するのは consent ルートの 2 サイト（#5・#6、`getAuthTransaction` :3957 で再読）のみと確定 → 棚卸し表とセキュリティ要件表を更新
  2. **[U2 解決] async 化とバイト同一の両立戦略**: ヘルパー定義の丸ごと条件付き補間＋呼び出しサイトの `${jarmAwait}` / `${jarmTxnArg}` 補間（PAR の `let`/`const` 切り替え :1691-1693 と同じ技法）で確定 → 実装上の必須要件 5 として仕様に追記
  3. **[新規指摘・修正] catch 節から参照する JARM モード変数のスコープ**: サイト 4 の分岐が参照する「ローカル解決結果」は try 内で宣言すると catch から見えない。PAR の `parParamsBinding` と同じく **try 前の `let` 宣言**を必須要件 3 に明記
  4. **[新規指摘・修正] 署名鍵の取得経路の具体化**: authorize / consent ルートには既存の鍵束縛が無いが、全ルート共通 context ミドルウェア（:227, 257-259）が `signingKeyProvider` 由来の `privateKey` / `publicJwk` / `keyId` を公開しており `c.get(...)` で取得できる。この鍵の公開鍵は jwks ルート（:3493-3511）が最優先で公開するため `kid` が jwks_uri で解決可能（クライアント検証可能性の確認）。Review 1 の「サイト内で `getSigningKey()` を呼ぶ」記述を context 取得方式へ差し替え（provider の再呼び出し不要・既存ルートの流儀と一致）
  5. **[インジェクション確認・指摘なし] 攻撃者制御値のエコー**: `unsupported-jwt-mode` エラーは攻撃者制御の `response_mode` 値を error_description にエコーするが、`AuthorizationError` コンストラクタ（:301）と `buildErrorRedirect`（:1839）の双方が `sanitizeErrorDescription`（RFC 6749 §5.2 文字集合強制）を通すため、リダイレクト URL・JWT クレームいずれの経路でも注入は成立しない。JARM クレーム経路のサニタイズは仕様のバリデーション 2 で既に固定済み
  6. **[脅威モデル確認・仕様に追記] DoS の整理**: JARM §5.1 の DoS はクライアント側の脅威で OP 実装には該当しない（一次資料で確定。sources.md 記録 6）。OP 側の署名コスト DoS（未認証リクエストに RSA 署名させる）は JARM 仕様外の観点として評価: 署名は client_id 解決＋登録 redirect_uri 検証通過後のみ発生し、コストは既存の ID Token 署名と同等 → セキュリティ要件表に 2 行追加し、understanding-guide のクライアント検証手順を「iss 確認 → 鍵取得」の順序（§5.1 MUST）へ修正
  7. **[確認・指摘なし] CSRF / SSRF / リプレイ / 鍵・ログ・有効期限**: (a) CSRF: consent の `validateCsrfToken` 経路は不変で新規フォーム・状態変更エンドポイントを追加しない (b) SSRF: OP 側に新規の外部フェッチなし（JWKS 取得はクライアント側の話） (c) リプレイ: `exp`（60 秒デフォルト・上限 600 秒 = §2.1 の 10 分内）＋ code 単回使用・PKCE（core 既存）で仕様の表どおり (d) 鍵: 新規鍵素材なし・秘密鍵ログ禁止は明記済み (e) エラー露出: JWT 化で露出面は増えない（クレームは平文クエリと同一集合）
  8. **[適合性確認・指摘なし] package 境界・後方互換**: core 無変更（response_mode は core が解釈しない）・subpath export・experimental→core の依存方向・デフォルト無効（`EXPERIMENTAL_FEATURES` は resolve 規則でデフォルト false）・jarm 無効時バイト同一（完了条件 3）は Review 1 から変更なく整合。セキュリティ要件は全行に検証方法（単体/結合/コードレビュー/ドキュメントレビュー）が紐づいており検証可能
- **修正**（同日反映）:
  - specification.md: 棚卸し表の行番号更新と「JARM モードの取得元」列の追加（指摘 1）/ 必須要件 3 の try 前 `let` 宣言（指摘 3）/ 必須要件 4 の context 取得方式への差し替え（指摘 4）/ 必須要件 5 の新設（指摘 2）/ セキュリティ要件表へ store round-trip 影響範囲の限定・OP 側署名コスト DoS・§5.1 クライアント側 DoS の行を追加（指摘 6）/ 未解決事項から U1・U2 を解決済み表へ移動
  - understanding-guide.md: クライアント検証手順を iss 確認先行の 6 ステップへ修正（指摘 6）/ store 契約の影響範囲を consent 経路のみに限定（指摘 1）
  - sources.md: リポジトリ内参照 5 件追加（U1 通読・ミドルウェア・jwks ルート・AuthorizationError サニタイズ・PAR let 宣言）/ 記録 6・7 を追加（§5.1 の位置付け・原文再確認）
- **残リスク**:
  - U3（E2E クライアントへの JARM 検証組み込み方）が未解決のまま Review 3 へ持ち越し（セキュリティ上の未解決事項ではない）
  - store 実装が未知フィールドを落とす場合の平文フォールバックは、契約明記＋conformance テストで検出可能だが、実装前の仕様段階では実挙動を確認できない（既知の仕様段階の限界）
  - 生成コードのバイト同一性・条件付き補間の実挙動は実装時の完了条件 2・3 でのみ最終確認できる（Review 1 から継続の既知事項）
- **判定**: **Pass with changes**（指摘 3・4・6 を同日中に修正反映済み。セキュリティ上の未解決事項・Blocked 相当の重大問題はなし。U1・U2 は根拠付きで解決。Review 3 の観点（実装着手可否・U3）へ引き継ぐ）
- **次回可能日**: 2026-08-04

## Review 3

- **日付**: 2026-08-04（Review 2 と異なる暦日 / `next_review_on` 到達を確認して実施）
- **観点**: 実装着手可否（追加調査なしで着手できるか / 受け入れ条件の客観性 / 対象ファイルと変更範囲 / API・CLI・テスト・Docs・Changeset の一貫性 / 実装順序と検証方法 / Experimental であることの利用者への明示）。Review 2 からの差分として、main の移動（45997d8 → e3bf2d5）に伴う前提の再検証と、持ち越しの U3 解決を含む
- **確認資料**:
  - `packages/cli/src/frameworks/hono/templates.ts`（main e3bf2d5 で再検証）: transaction-binding の条件付き補間 `bindingSecretStep` :1725-1743 / put サイト :2122-2131 / `buildErrorRedirect` 定義 :1949-1964 と 8 呼び出しサイト :2139, 2155, 2168, 2181, 2188, 2215, 2221, 2228 / 成功インライン :2258-2263, 2331-2336 / catch 節 :2356-2373 / consent 拒否 :4259-4267・承認 :4317-4324（`completeAuthTransaction` :4278 の `responseParams` 使用）/ context ミドルウェア :227, 257-259 と T-022 per-purpose 鍵 / jwks ルート :3609-3660 / discovery :3771-3781, 3828-3830 / conformance 期待値 :8984-8985
  - `packages/core/src/auth-transaction.ts`（transaction-binding 差分: optional `bindingHash?` 追加・`createAuthTransaction` の後方互換 options シグネチャ）/ `packages/cli/src/features.ts`（`OPTIONAL_FEATURES = ['transaction-binding']` :44 / `EXPERIMENTAL_FEATURES` :59）
  - `RELEASE.md`「experimental の bump は常に patch に固定する」/ `.github/scripts/ensure-experimental-changeset.mjs` / `.github/scripts/verify-release-contract.mjs` / CLAUDE.md の同旨規約
  - `tests/e2e/playwright.config.ts`（webServer による sample-hono-cloudflare 起動・e2e-client 定義）/ `tests/e2e/apps/client.mjs` 全文（`/start-par` / `/start-exchange` の機能別ルートパターン・Node 組み込みのみの構成）/ `tests/e2e/specs/pushed-authorization-requests.spec.ts:26`（discovery 自己スキップ）/ `samples/hono-cloudflare/package.json:8`（generate スクリプト）
  - JARM Final §2.2（2026-08-04 再アクセス: 鍵の用途分離を要求する規定が無いことを確認 → 記録 8）
- **指摘**:
  1. **[着手阻害・修正] Changeset 要件が release contract と矛盾**: 仕様書は「experimental: minor」としていたが、現行 main は experimental の手書き changeset を禁止し、CI が patch の changeset を自動生成する（`ensure-experimental-changeset.mjs`）。minor を書くと `pnpm run test:release-contract` が失敗し、実装 Routine が最終ステップで詰まる。Changeset 要件を「experimental は手書きしない・CLI のみ minor 手書き」へ修正し、実装順序 7 にも明記
  2. **[着手阻害・修正] main 移動による棚卸し表・行番号の陳腐化と transaction-binding との合成未規定**: Review 2 以降に transaction-binding（`OPTIONAL_FEATURES`・サンプルでは有効）がマージされ、テンプレートが約 1,100 行増加。`const transaction` の作成文が binding の条件付き補間 `bindingSecretStep` 内へ移動したため、旧必須要件 2（「transaction に合成してから put」）のままでは JARM が binding の補間に変種を追加することになり、binding × jarm の 4 通り分岐が生じる。**put 呼び出しの第 2 引数でのマージへ改訂**し（2 機能の補間が直交。無効時バイト同一維持）、authorize ルートの応答サイト 1〜4 の JARM モード取得元を「try 前の `let` 変数」へ統一（棚卸し表・必須要件 2・3 を更新）。8 呼び出しサイト・6 応答サイトの数と構造は現行 main でも不変であることを通読で再確認し、全行番号を e3bf2d5 基準に更新
  3. **[設計判断・追記] T-022 per-purpose 鍵との整合**: ミドルウェアが `idToken*` / `userinfo*` 鍵も公開するようになったため、応答 JWT の鍵選択が多義的になった。JARM §2.2 は鍵の用途分離を要求しない（原文再確認）ため**汎用 `signingKeyProvider` の active key を使う**と確定（必須要件 4・記録 8）。jwks ルートは T-022 後も汎用 `signingKeys` 配列を公開しており kid 解決可能
  4. **[U3 解決] E2E 組み込み方の確定**: `client.mjs` は Node 組み込みのみの HTTP サーバーで、experimental 機能ごとに `/start-*` ルートを足す既存パターンを持つ。`/start-jarm` ルート＋`/callback` の JARM 分岐（iss 先行確認（§5.1 の MUST 順序）→ jwks 取得 → `node:crypto` の `createPublicKey`/`verify` で RS256 検証 → aud/exp 確認 → state 照合・code 抽出 → 既存トークン交換へ合流）で組み込める。spec は discovery 自己スキップパターンを踏襲した `jarm.spec.ts` を新設。サンプル再生成（`generate` スクリプトへ `--enable jarm` 追加）を実装順序 6 に明記。テスト計画 E2E 節を確定内容へ全面更新
  5. **[確認・問題なし] 受け入れ条件の客観性と一貫性**: 完了条件 1〜7 はすべて機械的に検証可能（テスト通過・バイト diff・discovery 応答の固定値）。完了条件 3 のバイト同一確認に transaction-binding 有効・無効の両組み合わせを追記。公開 API 案 / CLI オプション案 / テスト計画 / ドキュメント要件 / 修正後 Changeset 要件の間に矛盾がないことを通し読みで確認。依存する core 公開 API（`SigningKey` / `AuthorizationError` / `sanitizeErrorDescription` / `AuthTransaction` 等）は e3bf2d5 でも全件公開済み（`core/src/index.ts` は 4 行の追加のみで該当 export に変更なし）
  6. **[確認・問題なし] Experimental の明示**: 生成コード冒頭コメント・`docs/library-document` の experimental 配下ページ・`packages/experimental/README.md` の 3 点が仕様に揃っている（PAR / Token Exchange と同構成）。デフォルト無効・`--enable jarm` の明示的有効化・jarm 無効時バイト同一も維持
- **修正**（同日反映）:
  - specification.md: Changeset 要件の全面修正（指摘 1）/ 棚卸し表・必須要件 2〜5 の改訂と全行番号の e3bf2d5 更新（指摘 2・3）/ テスト計画 E2E 節の確定内容への更新と実装順序 5〜7 の補強（指摘 4・5）/ U3 を解決済み表へ移動（未解決事項ゼロ）
  - understanding-guide.md: 登場人物表の署名鍵行に per-purpose 鍵設定時も汎用鍵で署名する旨を追記（指摘 3）。その他の記述は現行 main でも正確なため変更なし
  - sources.md: リポジトリ内参照の行番号を e3bf2d5 基準へ全面更新、新規参照 8 件（bindingSecretStep / put サイト / auth-transaction 差分 / RELEASE.md / release contract スクリプト / playwright.config / client.mjs / PAR spec 自己スキップ / サンプル generate スクリプト）を追加、記録 8・9 を追加
- **残リスク**:
  - 生成コードの実挙動（条件付き補間後の出力・バイト同一性・transaction-binding との組み合わせ）は実装時の完了条件 2・3 でのみ最終確認できる（Review 1 から継続の既知事項。PAR / Token Exchange と同じ扱い）
  - store 実装が未知フィールドを落とす場合の平文フォールバックは契約明記＋conformance テストで検出可能（Review 2 から継続の既知事項）
- **判定**: **Pass with changes**（指摘 1〜4 を同日中に修正反映済み。指摘 1・2 は放置すれば実装時に release contract 違反・補間分岐の設計迷いとして露見する着手阻害要因だったが、修正後は追加調査なしで着手可能。未解決事項ゼロ・セキュリティ未解決ゼロ・受け入れ条件は客観的に検証可能。Review 3 の全確認項目を満たしたため `status: Approved` / `implementation_ready: true` へ更新する）
- **次回可能日**: —（3 回のレビューを完了。次は実装 Routine が「実装順序」ステップ 1 から着手する）
