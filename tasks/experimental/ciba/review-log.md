# レビューログ: CIBA (Client-Initiated Backchannel Authentication) Poll Mode

## Review 1

- **日付**: 2026-08-08（仕様作成日を Review 1 として実施）
- **観点**: 仕様の完全性（問題・スコープ・非目標の明確さ / 一次資料の読み違い / 公開API案の subpath export 実装可能性 / CLI統合の現実性 / 依存方向 / テスト定義 / 未解決事項の明示 / 理解資料の自立性）
- **確認資料**:
  - CIBA Core 1.0 本文（openid.net、§4 / §7.1〜§7.3 / §10.1 / §10.3.1 / §11 / §13 / §14 / §15 の規範的文言と目次構成を直接確認）
  - `tasks/experimental/done/device-authorization-grant/`（先例パケット。CIBA を次サイクル候補として残した候補評価の記録）
  - `packages/experimental/src/device-authorization-grant/store.ts`（ストア契約の書式・consume atomic 要件）
  - `packages/cli/src/frameworks/hono/templates.ts:4002` 付近（deviceCodeDispatchStep）/ `:4119`（catch 分岐）/ `:5003`（discovery 追記）/ `:3405`（`authenticateUser` swap point）
  - `packages/core/src/token-request.ts:63-85`（`TokenClientInfo` の `grantTypes` / `tokenEndpointAuthMethod` フィールド）/ `:464`（grantTypes 既定値）
  - `packages/core/src/crypto-utils.ts:65`（`generateRandomString` の Base64URL 出力）
  - `packages/core/src/id-token.ts:276` / 365-372（`validateIdTokenHint` の exp 拒否）
  - `packages/cli/src/features.ts`（`EXPERIMENTAL_FEATURES` / `OidcFeatureConfig` の拡張箇所）
  - `tasks/T-019-dpop.md`（重複回避）
- **指摘**:
  1. **[一次資料の読み違い・修正] セクション番号の誤引用**: user_code の脅威モデルを「§12.2」と引用していたが、目次確認の結果、user_code の定義は §7.1.2、Security Considerations は §14、Privacy Considerations は §15 が正しい。仕様書・理解資料・sources.md の 3 箇所を修正
  2. **[表記・修正] 非目標の署名リクエスト項の行末に表組みの `|` が混入**していた（Markdown 崩れ）。除去
  3. **[完全性・修正] バックチャネル側エラー表の `access_denied` 403 行が「使用しない」とだけ書かれ根拠が無かった**: CIBA §13 は認証エンドポイントでの即時拒否用に定義するが、Poll モードの本 OP は受理後にユーザー判断を待つ設計のため拒否は常にトークン側 `access_denied` で配信される。この理由を表内に明記
  4. **[完全性・修正] `lastPolledAt` の更新タイミングが状態機械に未記載**だった（slow_down 応答時にも更新するのか読み取れない）。「結果によらず全ポーリング試行で更新」を明記
  5. **[実装可能性・確認] 公開クライアント拒否の実装根拠**: `TokenClientInfo.tokenEndpointAuthMethod`（`'none'` を含む）が core 公開型に存在することを確認（`token-request.ts:84`）。`processBackchannelAuthenticationRequest` が core 無変更で auth method `none` を判定できる
  6. **[スコープ判断・記録] `id_token_hint` を初期スコープから外す根拠の確認**: core の `validateIdTokenHint` は exp 切れを拒否する（`id-token.ts:365-372`）。CIBA の再認証ユースケース（期限切れ ID トークンをヒントに使う）とは相容れず、exp 緩和は core 変更を要するため、login_hint 限定は妥当。非対応ヒント単独提示時のエラーコード（`invalid_request` vs `unknown_user_id`）は §13 の両定義を読み比べ、ヒント種別自体の非対応は malformed 系として `invalid_request` を採る設計判断を sources.md「記録」に明記
  7. **[CLI統合の現実性・確認] 全生成物が実証済みパターンに載ることの確認**: バックチャネルエンドポイント（PAR / device_authorization 先例）・grant ディスパッチ（tokenExchange / deviceCode 先例）・承認 UI（/device 先例）・discovery 追記（device 先例）。テンプレート実体は hono 1 系統で web-standard 変換により全フレームワークへ展開される構造も device で確認済み
- **修正**: 指摘 1〜4 を同日中に反映（specification.md / understanding-guide.md / sources.md）
- **残リスク**:
  - U1（UI ログイン部品の共通化 or 複製）・U2（保留数超過時のエラーコード）・U3（denied レコードの削除タイミングと Device Grant 実装の整合）・U4（`backchannelTokenDeliveryMode` の型の載せ方）が未解決事項表に残る。いずれも仕様の成立を妨げない
  - `slow_down` 方式（過剰ポーリングへ invalid_request を返さない）は §11 の MAY を採らない設計判断であり、相互運用上の問題は無いが Review 2 でセキュリティ観点（ポーリング DoS）から再確認する
  - 未承諾リクエスト対策を user_code なしで UI 設計 + 保留数上限に寄せた受容コスト（正規クライアント侵害時はユーザーの拒否に依存）の妥当性は Review 2 の主要確認事項
- **判定**: **Pass with changes**（指摘 1〜4 を同日中に修正反映済み。仕様の完全性の観点で残る事項はすべて未解決事項表に明示されており、Review 2 の観点（セキュリティ・適合性）に引き継ぐ）
- **次回可能日**: 2026-08-09

## Review 2

- **日付**: 2026-08-09
- **観点**: セキュリティと適合性（認証認可上の脅威: リプレイ・CSRF・インジェクション / 鍵・トークン・シークレットの扱い / ログ禁止情報 / 有効期限 / エラー情報の露出 / package 境界との整合 / CLI 後方互換 / 明示的有効化 / 生成コードの安全性 / セキュリティ要件のテスト検証可能性）。Review 1 からの引き継ぎ事項（slow_down 方式の再確認・user_code 非対応の受容コスト・U2・U3）を含む。Review 1 と同じ確認の反復は避け、一次資料はセキュリティ関連セクションの規範文言の再確認に限定した
- **確認資料**:
  - CIBA Core 1.0 §7.3 / §11 / §13 / §14 / §15 の規範文言（本文を再取得して確認。§13 のエラー語彙と HTTP ステータス対応・§11 の slow_down「at least 5 seconds for this and all subsequent requests」と invalid_grant「issued to another Client」・§7.3 のエントロピーと文字種・§14 の expired id_token_hint 受理勧告・§15 の static global identifier の文言が仕様書の記述と一致）
  - `packages/experimental/src/device-authorization-grant/device-code-grant.ts`（状態機械の実挙動。denied 即削除・expired の評価順序・lastPolledAt 更新経路・同一文言 invalid_grant によるオラクル防止）
  - `packages/experimental/src/device-authorization-grant/verification.ts`（binding Cookie 方式・CSRF の多層防御・レコード単位ログイン失敗計数と残存面の注記）
  - `packages/cli/src/frameworks/hono/templates.ts`（token ルートの device 分岐がクライアント認証後・core の grant 検証前に置かれること / `/device` UI 3 ルートの防御構成 / 既存 `/login` の transaction CSRF と新規 sessionId 発行 / セッション・binding Cookie の属性 HttpOnly / Secure / SameSite=Lax / 生成コードに `login_hint` 等を出力するログが無いこと）
  - `packages/cli/src/features.ts` / `packages/cli/src/__tests__/par-feature.test.ts`（experimental 機能の明示的有効化機構と unknown-feature エラーメッセージの構成）
- **指摘**:
  1. **[重大・修正] `/ciba/login` のログイン CSRF 防御が未定義だった**: 仕様は資格情報検証と OP セッション確立のみを定めており、CSRF 対策が無かった。既存の生成コードはセッションを確立するすべての POST を守っている（`/login` は auth transaction の CSRF、`/device/login` は binding Cookie + レコード CSRF。テンプレートは「forged POST が被害者ブラウザに OP セッションを確立するステップを binding で守る」と明記）のに対し、`/ciba/login` はどちらの錨も持たないため、攻撃者アカウントのセッションを被害者ブラウザへ植え付けるログイン CSRF（SSO / prompt=none へ波及）が成立し得た。フォーム埋め込みトークンのみでは不足（攻撃者が自分で `GET /ciba` を叩いて有効な対を入手できる）。**修正**: ログイントランザクション（id + CSRF + binding Cookie ハッシュ + 失敗計数、TTL 600 秒固定）を公開 API（`CibaLoginTransactionRecord` / `CibaLoginTransactionStore` / `createCibaLoginTransaction` / `validateCibaLoginSubmission` / `recordCibaLoginFailure` / in-memory 実装）として追加し、UI ルート表・セキュリティ要件表・テスト計画（単体 + conformance）に反映
  2. **[重大・修正] `/ciba/login` の資格情報総当たりに計数の錨が無かった**: 既存 `/login` は auth transaction 単位、`/device/login` はレコード単位で失敗を計数するが、CIBA のログインはレコード特定より前に行われるため、仕様のままでは事実上無制限の資格情報試行面になっていた。**修正**: 指摘 1 のログイントランザクションを計数の錨とし、`maxLoginAttempts` 超過でトランザクション削除 + 429。残存面（トランザクション再発行で集計上は無制限）は既存 2 面と同一であることを仕様に明記し、subject 単位のスロットリングは既存タスク `p2-login-attempt-throttling-subject-scope` の責務のままとする
  3. **[U2 確定] `maxPendingPerSubject` 超過時エラーは `invalid_request` 400 で確定**: §13 の `access_denied` 403（resource owner or OP denied）はクライアントにフロー終端（ユーザー拒否）と解釈される恐れがあり、保留数超過は保留分の処理で解消される一時的状態のため不適。CIBA Core に一時エラーの語彙が無いことも確認
  4. **[U3 確定] denied レコードの即削除は Device Grant 実装と一致**: `device-code-grant.ts:137-143` が denied → `access_denied` 送出と同時に削除し、再ポーリングを同一文言の `invalid_grant` にしている。仕様の記述をそのまま確定
  5. **[正確性・修正] `lastPolledAt`「結果によらず全ポーリング試行で更新」の記述を実挙動に合わせて修正**: Device Grant 実装の更新経路は `slow_down` と `authorization_pending` の 2 つで、他の結果はレコードを削除または consume するため更新対象が残らない。文言どおり実装すると削除直前の無意味な書き込みが生じ、実装が先例と乖離する余地があった
  6. **[CLI 後方互換・記録] `par-feature.test.ts:112` が `'ciba'` を未定義機能名の例に使用**: `EXPERIMENTAL_FEATURES` へ `ciba` を追加すると `resolveFeatures({ enable: ['ciba'] })` が throw しなくなりテストが落ちる。実装時に別の未定義名へ差し替える注意を仕様書 CLI 節に追記
  7. **[確認・変更なし] 以下は問題なしを確認**: slow_down 方式（§11 の MAY を採らない判断は恒久 +5 秒の MUST を満たし、invalid_request の終端セマンティクスを避ける点でも安全）/ auth_req_id 256bit は §7.3 の推奨 160bit を超過し文字種も適合 / トークン分岐がクライアント認証後に置かれる前提は device 分岐の実装と一致 / 承認操作の防御（セッション subject 一致 + セッション必須の一覧でしか得られないレコード CSRF + SameSite=Lax）は binding 不要の設計判断を含めて妥当 / エラー応答のオラクル化防止（同一文言・Cache-Control: no-store）/ ログ禁止情報（生成コードに該当ログ出力なし。仕様の禁止規定で担保）/ package 境界と依存方向は既存 4 機能と同型 / デフォルト無効・バイト同一の完了条件あり / セキュリティ要件は単体・conformance・E2E のいずれかで検証可能
- **修正**: 指摘 1・2・5・6 と U2/U3 の確定を同日中に specification.md / understanding-guide.md / sources.md へ反映
- **残リスク**:
  - user_code 非対応の受容コスト（正規クライアント侵害時の最終防衛がユーザーの拒否操作）は、クライアント認証必須・保留数上限・pull 型 UI・承認画面の情報表示の 4 層で緩和した上で README 明記を要件とする現仕様を妥当と判断（PoC 検証ライブラリの位置づけと整合）
  - `unknown_user_id` によるユーザー列挙は登録クライアントに限定される仕様上の受容。resolver の応答時間差による列挙も同じ受容範囲に含まれる（固定文言のみ規定。タイミング均一化は要求しない）
  - ログイン失敗計数の集計上の無制限（トランザクション再発行）は既存 `/login`・`/device/login` と同一の残存面で、既存タスクの責務
- **判定**: **Pass with changes**（指摘 1・2 は仕様段階で発見・同日修正済み。セキュリティ未解決事項は残っていない。未解決事項表に残る U1・U4 は実装構成の選択であり、セキュリティに影響しない）
- **次回可能日**: 2026-08-10（Review 3: 実装着手可否）

## Review 3

- **日付**: 2026-08-10
- **観点**: 実装着手可否（追加調査なしで着手できるか / 受け入れ条件の客観性 / 対象ファイルと変更範囲 / API・CLI・テスト・Docs・Changeset の一貫性 / 実装順序と検証方法 / Experimental であることの利用者への明示）。Review 1・2 で確認済みの事項（一次資料の規範文言・セキュリティ対策・状態機械の先例一致）は反復せず、残っていた U1・U4 の確定と、実装 Routine が仕様書だけで作業を完遂できるかの検証に集中した
- **確認資料**:
  - `packages/core/src/token-request.ts:63-85`（`TokenClientInfo` の全フィールド。`grantTypes` は `string[]` で CIBA URN を追加登録でき、交差型拡張を妨げる索引シグネチャ等が無いことを確認）
  - `packages/cli/src/frameworks/hono/templates.ts:511-548`（`RegisteredClient = ClientInfo & TokenClientInfo & { offlineAccessAllowed?; ... }` の既存交差型と `createInMemoryClientResolver`。U4 の挿入先）
  - `packages/experimental/src/par/par-request.test.ts:24` / `packages/experimental/src/token-exchange/token-exchange-request.ts:142-158`（交差型拡張と grantTypes / auth method `none` 検証の実装先例）
  - `packages/cli/src/features.ts` 全文（`EXPERIMENTAL_FEATURES` / `EXPERIMENTAL_FEATURE_KEYS` / `DEFAULT_FEATURES` / `resolveFeatures` の追加箇所が仕様の記述どおりであることを確認）
  - `packages/cli/src/index.ts:28-38`（`withExperimentalPackage` の feature チェック。仕様書に未記載だった変更点）
  - `packages/cli/src/__tests__/par-feature.test.ts:111-113`（`'ciba'` を未定義名に使う unknown-feature テストの現物）
  - `docs/implementation-guides/experimental/`（`<feature-id>.ja.md` / `.en.md` の命名規約と device-authorization-grant の先例）
  - `tasks/experimental/done/device-authorization-grant/specification.md`（実装順序・完了条件の構成先例。samples の `generate` スクリプトへの `--enable` 追加手順を含む）
- **指摘**:
  1. **[U4 確定] `backchannelTokenDeliveryMode` の載せ方**: experimental 側に `CibaClientInfo = TokenClientInfo & { backchannelTokenDeliveryMode?: 'poll' | 'ping' | 'push' }` を定義し、生成コード側は `RegisteredClient`（`templates.ts:511` の既存交差型）へ同フィールドを `ciba` 有効時のみ条件挿入する。`RegisteredClient` は構造的部分型として `CibaClientInfo` に代入可能で core 型変更は不要。交差型の先例 2 件（`RegisteredClient` 自身・`par-request.test.ts:24`）を確認
  2. **[API 一貫性・修正] 公開API案が検証順序 5 を型的に実行できなかった**: `processBackchannelAuthenticationRequest` の引数が `client: TokenClientInfo` のままで、検証順序 5（delivery mode 判定）が読むフィールドが型に存在しなかった。`CibaClientInfo` を公開 API に追加し引数型を差し替え
  3. **[U1 確定] UI ログイン部品は CIBA 専用に複製**: (1) `ciba` 無効時バイト同一の完了条件と device 側の既存回帰期待は、CIBA のテンプレートブロックが device のブロックに触れない構成で最も確実に守れる（共通部品への括り出しは device のみ有効な生成出力を変えてしまう） (2) 機能独立性・切り出しやすさ優先の運用方針 (3) views 契約が別エントリで増える設計との整合。experimental パッケージ内もログイントランザクション実装を `ciba/` 内に複製する
  4. **[変更範囲の欠落・修正] `withExperimentalPackage`（`packages/cli/src/index.ts:28`）への `features.ciba` 追加が仕様書に未記載だった**: experimental パッケージのインストールガイダンス挿入条件で、device 追加時にも変更された実証済みの変更点。CLI オプション案と実装順序に追記
  5. **[Docs 一貫性・修正] `docs/implementation-guides/experimental/ciba.ja.md` / `.en.md` の作成要件が漏れていた**: CLAUDE.md は実装完了時に日英の実装解説（コード全文掲載）を必須としており、既存 4 機能すべてに先例がある。ドキュメント要件と完了条件 7 に追加
  6. **[実装順序・修正] 実装順序の節が無かった**: done の device-authorization-grant 仕様書には実装 Routine 向けの実装順序の節があり、samples の `generate` スクリプトへの `--enable` 追加（E2E の前提）とバイト同一 diff の手順を含む。同じ構成で 7 ステップの実装順序を追加し、各ステップを完了条件の番号に対応付けた
  7. **[確認・変更なし] 以下は着手可能を確認**: 完了条件はすべて客観的（テストのグリーン・バイト同一 diff・`--check` 一致・表との一致）/ `features.ts` の変更箇所は仕様の記述と現物が一致 / `par-feature.test.ts` の差し替え注意は現物と一致（`toThrow` の部分一致仕様により `ciba` 追加で throw 自体が消えて確実に落ちる）/ Experimental である旨の明示は README 節・ヘルプ文言・生成コードコメント・実装解説の 4 経路で担保 / Changeset 要件は CLAUDE.md（experimental は自動 patch・手書き禁止、CLI は minor 手書き）と一致 / 依存方向は既存 4 機能と同型
- **修正**: 指摘 1〜6 を同日中に specification.md（公開API案・CLI オプション案・実装順序・ドキュメント要件・完了条件・未解決事項）/ understanding-guide.md（実装後の利用方法）/ sources.md（リポジトリ内参照・記録）へ反映
- **残リスク**: セキュリティ・仕様適合の未解決事項なし。受容済みの残余リスク（user_code 非対応の受容コスト・登録クライアントによるユーザー存在確認・ログイン失敗計数の集計上の無制限）はいずれも README 明記または既存タスクの責務として仕様に固定済み。実装時に判明した齟齬は review-log に追記して扱いを決める
- **判定**: **Pass with changes**（指摘はすべて同日修正済み。未解決事項表に open の項目は無く、追加調査なしで実装に着手できる）
- **次回可能日**: —（3 回完了。以後は実装 Routine が引き継ぐ）
