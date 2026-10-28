# レビュー記録: rar

## Review 1

- **日付**: 2026-10-21（仕様作成日をReview 1として実施）
- **観点**: 仕様の完全性（問題・スコープ・非目標の明確さ、一次資料の読み違い、公開API案が subpath export で実装可能か、CLI統合の現実性、依存方向、テスト定義、未解決事項の明示、理解資料の自立性）
- **確認資料**:
  - RFC 9396 全体を datatracker.ietf.org で取得し、MUST / SHOULD / MAY の別をセクション単位で確認（§2 の type REQUIRED と共通フィールドの型、§2 の同一 type 重複 MAY、§3 の単一パラメータとエンコード、§3.1 の merged set 同意表示 MUST、§5 の未知 type MUST refuse と `invalid_authorization_details` の適用条件、§6 / §6.1 のトークンリクエスト指定と型依存比較が仕様外であること、§7 の応答 MUST と §7.1 enrichment MAY、§9 の RS 伝達 MUST と §9.1 JWT claim RECOMMENDED、§9.2 introspection の top-level member MUST、§10 のメタデータ名、§12 の sanitize MUST と RFC 8259 比較、§13 の機微データ、§14.6 のエラーコード登録）
  - FAPI 2.0 Security Profile（Final、2025-02-22）の §5.3.2.2 NOTE 5（RAR への言及が非規範の推奨ノートであることの実測）
  - リポジトリ現状（main = e339644、2026-10-21 取得）。`apps/hono/src/oidc-provider/features/feature.ts`（`Feature` フックの全量、65〜103 行）、`endpoints/authorize/pipeline.ts`（`let params` 58 行と所有ブロックの窓、silent / SSO 経路 105〜117 行）、`endpoints/authorize/steps/parse-request.ts`（`collectUniqueParams` が重複キーのみ拒否）、`endpoints/authorize/steps/reuse-session.ts`（`consentResolver.hasConsent` が scope 単位で details を知らないこと）、`endpoints/consent/steps/describe-consent-screen.ts`（`ConsentScreen` の現在の形）、`endpoints/token/pipeline.ts`（`const tokenResponse` 119 行と `[build-token-response]`→`[respond]` の窓）、`packages/core/src/authorization-request.ts`（`REQUEST_OBJECT_OVERRIDE_KEYS` 1219 行に `authorization_details` が無いこと、`rejectUnsupportedRequestParams` の拒否対象が 3 パラメータだけであること）、`packages/cli/src/registry.ts`（`FEATURE_REGISTRY` と `EXPERIMENTAL_FEATURES` 161 行の追加先）、`packages/experimental/src/id-jag/issue-id-jag.ts` 434 行ほか（id-jag / token-exchange の `authorization_details` 明示拒否）、`features/ciba/config.ts`（config モジュールと `declare module` 拡張の先例）
  - `study-material/ext-rich-authorization-requests-rfc9396.md`、`tasks/T-019-dpop.md`、`tasks/experimental/done/*` の state.yaml（候補の重複確認）
- **指摘**:
  1. 候補評価の元資料（study-material）は「FAPI 2.0 が RAR を要件化」と書いていたが、FAPI 2.0 Final の実測では §5.3.2.2 の非規範ノートによる推奨にとどまる。要件化を採用理由に使うと一次資料の読み違いになる
  2. 初稿では「details があるとき SSO の同意スキップを防ぐ」手段として `consentResolver` のラップを検討していたが、`reuse-session` の実測で `hasConsent` は subject / client / scope しか受けず、トランザクション（details の有無）を知れないことが分かり、この案は成立しない
  3. Request Object 経由の `authorization_details` は、core の `mergeRequestObjectParams` が固定キー（`REQUEST_OBJECT_OVERRIDE_KEYS`）しか写さないため `effectiveParams` に現れない。クエリ値だけを読む設計だと、署名付き Request Object で details を保護する §12 の想定経路が機能しない
  4. core のトランザクション・コード・トークン情報の各ビルダーは固定フィールドしか写さないため、details を「リクエスト → トークン応答」までパラメータの相乗りで運ぶことはできない。この制約を仕様に明記しないと、実装時に core 変更へ誘導されてしまう
  5. トークンリクエストの `authorization_details`（§6）を「無視する」初稿案は、narrowing されたとクライアントに誤認させる。黙殺は fail-closed ではない
- **修正**（いずれも本レビュー内で仕様書へ反映済み）:
  1. 採用理由と理解資料の FAPI 2.0 への言及を「非規範ノートでの推奨」に正し、sources.md に訂正根拠として記録した
  2. 同意の迂回対策を prompt 制御方式（details + `prompt=none` → `consent_required`、それ以外は `prompt` へ `consent` を付与して全経路を同意画面へ通す）に変更した。`let params` の再代入は PAR の先例があり、`prompt=consent` の意味は OIDC Core §3.1.2.1 の「consent MUST re-display」にそのまま乗る
  3. 受理経路の優先順位を「`requestObjectClaims` ＞ params（PAR 経由の値は params に現れる）」と明記し、supersede の根拠を OIDC Core §6.1 に置いた。claim 値の型（パース済み配列か文字列か）は U3 として残した
  4. 保持を grantId / transactionId キーの副ストア（PAR / CIBA と同じ in-memory 契約）とする設計を「配置案」に明記し、必要な base 変更 3 点（同意画面の optional フィールド、token / introspection 応答の `let` 化）を「無効時の挙動不変」の条件つきで列挙した
  5. トークンリクエストの `authorization_details` は `invalid_authorization_details` での明示拒否に変更し、非目標の節に理由（誤認防止）を書いた
- **確認して問題なしとした項目**: 公開 API 案は純関数と in-memory ストアのみで subpath export（`"./rar"`）により実装可能。CLI 統合は既存 9 機能と同型（registry 末尾追加、キー対応、install 案内）で、他機能への `requires` は不要。introspection への反映は introspection パイプライン内の所有ブロックで実現でき、feature 間 import を作らない（パイプラインは lint の例外で、jwt-introspection-response ブロックの先例がある）。依存方向は既存機能と同一。id-jag / token-exchange の `authorization_details` 明示拒否は各仕様の要求であり本機能と矛盾しない。理解資料は仕様書を参照せずに読め、誤解しやすい点を仕様の非目標と対応づけた
- **残リスク**:
  - U1（grantId ストアの掃除方式）、U2（E2E デモ型定義の形）、U3（`requestObjectClaims` 内の値の型）が未確定。いずれも実装形の選択であり、どちらに倒しても fail-closed にできることは確認済み
  - 同意画面と token / introspection 応答への base 変更 3 点は方式の確認にとどまり、生成テンプレートへの具体的な波及（nextjs の route.ts の該当行、generator の `const x = undefined` 化の対象）は Review 3 で実測する
  - prompt 制御方式が `offline_access`（`prompt=consent` 必須）や `max_age` と干渉しないことは論理上の確認のみで、実測は Review 2 のセキュリティ観点で行う
- **判定**: Pass with changes（修正は本レビュー内で反映済み）
- **次回可能日**: 2026-10-22

## Review 2

- **日付**: 2026-10-28
- **観点**: セキュリティと適合性（認証認可上の脅威、トークン・機微データの扱い、ログ禁止情報、有効期限、エラー情報の露出、package 境界との整合、CLI 後方互換、明示的有効化、生成コードの安全性、セキュリティ要件のテスト検証可能性）。Review 1 の残リスク 3 点（prompt 制御の干渉実測、U1、U3）の決着を含む
- **確認資料**:
  - RFC 9396 §12 / §13 を再取得し、MUST（改ざん保護は client 側、AS の sanitize）と非規範（リファラ漏えい防止、同意画面でのデータ露出、need-to-know）の別、§5 の未知 type MUST refuse、§6 のトークンリクエスト拒否時の `invalid_authorization_details`、§14.6 のエラーコード登録（authorization / token 両エンドポイント）を確認
  - リポジトリ現状（main = a5e4f70、2026-10-28 取得）。`packages/core/src/request-object.ts`（`parseRequestObject` がペイロードを JSON デコードして返す。64〜101 行）、`packages/core/src/authorization-request.ts`（`AuthorizationError` / `AuthorizationErrorCode` enum と `sanitizeErrorDescription`、276〜298 行）、`packages/core/src/token-error.ts`（`TokenError` の enum と sanitize）、`apps/hono/src/oidc-provider/endpoints/token/pipeline.ts`（dispatch 群 48〜66 行 → validate → 発行・保存 90〜113 行 → ローテーション失効 116 行 → 応答 119〜122 行の順序）、`endpoints/token/steps/respond-error.ts`（`TokenEndpointError` 素通し）、`features/par/steps/resolve-pushed-request.ts`（`as AuthorizationErrorCode` キャストの先例、64 行）、`endpoints/authorize/pipeline.ts`（rar 検証ステップ位置と `[validate-prompt-combination]` の順序、93〜97 行）、`endpoints/authorize/steps/reuse-session.ts`（`promptValues.includes('consent')` で同意スキップが止まる、87 行）、`steps/authenticate-silently.ts`（prompt=none 経路）、`endpoints/login/steps/hand-off-to-consent.ts` / `discard-session-for-fresh-login.ts`（ログイン経路は常に consent へ進み、prompt=consent はセッションを破棄しない）、`features/refresh-token/steps/decide-refresh-token-issuance.ts` と core / apps の `offline_access` 全参照（prompt を条件にしない）、`features/refresh-token/steps/issue-refresh-token.ts`（絶対寿命が `originalIssuedAt` 起点、73 行）、`config.ts`（`refreshTokenAbsoluteLifetime` 既定 7776000）、`packages/core/src/token-request.ts`（grantId が authorization_code / refresh_token 両 grant を貫通する）、`packages/experimental/src/ciba/store.ts`（lazy eviction の先例）、`endpoints/consent/steps/`（validate-csrf-token / reject-cross-origin-post の既存 CSRF 防御）
- **指摘**:
  1. **（重大）トークンリクエスト拒否の位置が fail-closed でない**: 仕様書は `authorization_details` 付きトークンリクエストの拒否を `[build-token-response]` 後の `append-token-response-details` で行うとしていたが、token パイプラインの実測ではその時点でアクセストークンの発行・保存、ID トークン発行、リフレッシュトークンの発行、提示トークンのローテーション失効がすべて完了している。応答直前の拒否は、拒否したリクエストの副作用（保存済みトークン、失効済みリフレッシュトークン）を残す
  2. 検査 9（prompt=none → `consent_required`）が `none` と他値の不正な組み合わせにも先に発火し、base の `[validate-prompt-combination]` が返すべき `invalid_request`（OIDC Core 1.0 §3.1.2.1）を覆い隠す。どちらもエラーで fail-closed は保たれるが、RAR 無関係の既存エラー意味論を変えるべきでない
  3. `invalid_authorization_details` は core の `AuthorizationErrorCode` / `TokenErrorCode` enum に無く、仕様書が投げ方を特定していなかった（core 変更へ誘導されるリスク）。PAR の `as AuthorizationErrorCode` キャストと `TokenEndpointError`（応答全体を運ぶ）という既存の器で実現できることを実測で確認
- **修正**（いずれも本レビュー内で仕様書・理解資料へ反映済み）:
  1. 拒否を専用ステップ `[reject-token-request-details]` として feature grant dispatch 群の後・`[validate-grant-type]` の前に移動。他機能（id-jag / token-exchange）の既存拒否が先に効く順序を保ちつつ、すべての副作用に先行させる。セキュリティ要件に「副作用前の拒否」を追加し、reject ステップのテストに「トークンが保存されず提示リフレッシュトークンが失効していないこと」を追加
  2. 検査 9 を「`none` 単独のときだけ `consent_required`、`none` が他値と組む場合はスキップして prompt も変更しない（base が `invalid_request` で拒否）」に修正
  3. バリデーション / エラー処理の節に PAR のキャスト先例と `TokenEndpointError` の器、`sanitizeErrorDescription` の通過を明記
- **U1 の確定**: grantId 紐付けストアは `expiresAt = 発行時刻 + refreshTokenAbsoluteLifetime` の TTL と書き込み時 lazy eviction（ciba の先例）とする。ローテーションが絶対寿命を `originalIssuedAt` 起点で固定するため、有効なリフレッシュトークンが存在する間にエントリは消えず §7 MUST と両立。リフレッシュトークン非発行 grant の TTL までの過剰保持は Docs の既知の制約に記載
- **U3 の確定**: `parseRequestObject` はペイロードを JSON デコードした `Record<string, unknown>` を返すため、Request Object 経由の値はパース済み JSON 配列、クエリ / PAR 経由は文字列。公開 API を `parseAuthorizationDetailsInput(input: unknown, limits)` に変更し、文字列は生文字列でバイト長検査後にパース、パース済み値は `JSON.stringify` でバイト長を測る入口に統一
- **確認して問題なしとした項目**: prompt への `consent` 付与は `offline_access` の発行条件を広げない（発行判断は grant の scope と client の grant_types のみで、prompt を参照する箇所が core / apps に無い）。`max_age` の鮮度検査は silent / SSO 両経路で prompt と独立しており干渉しない。ログイン経路は常に consent へ hand-off するため、同意スキップは silent / SSO の 2 経路だけで、どちらも prompt 制御で塞がる。同意画面への details 表示は既存の CSRF 防御（validate-csrf-token / reject-cross-origin-post）と JSX エスケープの上に乗る。grantId は authorization_code / refresh_token 両 grant を貫通するため、ローテーション後も details の紐付けが保たれる。エラー文言は両エラークラスの `sanitizeErrorDescription` と固定 ASCII 文言の要件で入力値の反映を防ぐ。package 境界・明示的有効化・CLI 後方互換は Review 1 の確認から変更なし（仕様の変更はステップ分割のみで境界に影響しない）
- **残リスク**:
  - U2（E2E デモ型定義の形）が未確定。Review 3 までに確定する
  - base 変更 3 点（同意画面 optional フィールド、token / introspection 応答の `let` 化）の生成テンプレートへの具体的な波及（nextjs の route.ts 該当行、generator の対象）は Review 3 で実測する
  - `[reject-token-request-details]` の nextjs 側の配置（route.ts のどの位置に入れるか）は Review 3 の実装着手可否確認で特定する
- **判定**: Pass with changes（修正は本レビュー内で反映済み。重大指摘 1 は仕様段階で解消したため Blocked にしない）
- **次回可能日**: 2026-10-29
