# レビュー記録: dynamic-client-registration

## Review 1

- **日付**: 2026-09-30（仕様作成日をReview 1として実施）
- **観点**: 仕様の完全性（問題・スコープ・非目標の明確さ、一次資料の読み違い、公開API案が subpath export で実装可能か、CLI統合の現実性、依存方向、テスト定義、未解決事項の明示、理解資料の自立性）
- **確認資料**:
  - RFC 7591 §2・§2.1・§3.1・§3.2.1・§3.2.2・§5 を取得して MUST / SHOULD / MAY の別を確認（未知メタデータの MUST ignore、POST + application/json の MUST、オープン登録の SHOULD、201 と登録済み全メタデータ返却の MUST、client_secret_expires_at=0 の意味、エラーコード 4 種のうち software_statement 系 2 種を非目標に落とせること、grant/response 整合の SHOULD、rate-limit の MAY）
  - OpenID Connect Dynamic Client Registration 1.0 §2・§3.1〜§3.3（redirect_uris REQUIRED、initial access token の MAY と「アクセストークンなしの登録を受けるべき」SHOULD、registration_access_token / registration_client_uri の「両方か両方なし」MUST、既定値が RFC 7591 と一致すること）
  - `packages/core/src/authorization-request.ts`（`ClientInfo` の responseTypes / grantTypes / defaultMaxAge / jwks 定義（110〜146 行）、`ClientResolver.findClient`（168 行）、`validateRegisteredRedirectUris` の実装全文（422 行〜。検査規則とエラー形式））
  - `packages/core/src/token-request.ts`（`TokenClientInfo`（72 行〜）: clientSecret optional / grantTypes 既定 ["authorization_code"] / tokenEndpointAuthMethod 既定 client_secret_basic が RFC 7591 の既定値と一致していること）
  - `packages/core/src/client-auth.ts`（209 行〜。登録済み auth method と提示方式の一致検証。`none` 登録クライアントへの credentials 提示拒否）
  - `packages/core/src/crypto-utils.ts`（`generateRandomString`（65 行）は公開（`index.ts:157`）、`timingSafeEqual`（84 行）は非公開であることの確認）
  - `packages/core/src/discovery.ts`（36・95・205-206 行。registrationEndpoint の条件付き出力機構が既にあり、フィールド名が Discovery 1.0 §3 と一致）
  - `packages/cli/src/features.ts`（EXPERIMENTAL_FEATURES の構造（77〜86 行）と resolveFeatures の依存検証パターン（jwt-introspection-response の introspection 依存）。本機能は依存なしで足りること）
  - `packages/cli/src/index.ts`（`withExperimentalPackage`（32〜46 行）の feature チェック列挙）
  - `packages/cli/src/frameworks/hono/templates.ts`（discovery スプレッドマージ（7601 行周辺）に実装済み 8 機能が並ぶ構造）、`packages/cli/src/frameworks/web-standard/templates.ts`（express / fastify / nextjs の共有テンプレートであること）
  - `samples/hono-cloudflare/src/oidc-provider/config.ts`（`RegisteredClient` 型と `createInMemoryClientResolver`（184 行）。静的 Map 解決の現状）、`store.ts`（`ProviderStores`（648 行）/ `defaultProviderStores`（985 行）のストア追加パターン）
  - `study-material/ext-dynamic-client-registration.md`・`extension-dynamic-client-registration.md`・`ext-mcp-authorization-op-readiness.md`・`ext-rich-authorization-requests-rfc9396.md`・`tasks/T-019-dpop.md`（候補評価の重複確認）
- **指摘**:
  1. 初稿は redirect_uris の検査を「core の `validateRegisteredRedirectUris` をそのまま使う」とだけ書いていたが、同関数は設定ミス検知用で、違反 URI をメッセージへ埋め込んだ `server_error` の `AuthorizationError` を投げる（`authorization-request.ts:426` ほか）。そのまま流用すると「`error_description` にリクエスト由来の値を反映しない」という本仕様のエラー方針、および RFC 7591 §3.2.2 のエラーコード（`invalid_redirect_uri`）と衝突する
  2. 動的登録クライアントに `refresh_token` 単独の `grant_types` を許すかが未記述だった。`response_types` を `["code"]` に固定する本仕様では、`code` に対応する `authorization_code` を含まない登録は §2.1 の inconsistent state に当たる
  3. 定数時間比較を core から import する前提で書きかけていたが、`timingSafeEqual` は core の公開 API に含まれない（`index.ts` のエクスポートは `generateRandomString` のみ）。公開 API 以外への依存は作れない
- **修正**:
  1. `AuthorizationError` を捕捉して `invalid_redirect_uri` の `ClientRegistrationError`（URI を含まない固定 ASCII 文言）へ変換する設計をバリデーションの節と入出力の表に明記。検査規則は core と同一、エラー表現だけを登録エンドポイントの契約へ合わせる、という判断として記録
  2. 「`refresh_token` 単独は `invalid_client_metadata`」を入出力の表とテスト計画（異常系）に明記し、根拠を §2.1 の SHOULD に置いた
  3. 定数時間比較は experimental 機能内に持つ（機能間コード重複の許容方針どおり）と公開 API 案に明記し、core の `timingSafeEqual` 公開は将来の昇格考慮に記録
- **確認して問題なしとした項目**: 公開 API 案は純関数のみで subpath export で実装可能。登録レコードは生成コードの `RegisteredClient` 型（`ClientInfo & TokenClientInfo`）へ追加フィールド（clientName / clientIdIssuedAt）だけで適合し、core の型拡張は不要。responseTypes / grantTypes / tokenEndpointAuthMethod の core 側既定値は RFC 7591 の既定値と一致しており、既定値適用を experimental 側で行っても二重定義の矛盾は生じない。CLI 統合は既存 8 機能と同型（EXPERIMENTAL_FEATURES 末尾追加・withExperimentalPackage・スプレッドマージ）で、機能間依存の検証も不要。未知 feature メッセージは列挙から自動生成されるため末尾追加で整合する
- **残リスク**:
  - U1（登録上限超過時の応答）・U2（client_id の形式）・U3（パス名）が未確定（いずれも実装形の選択であり、どちらを選んでもセキュリティ上 fail-closed 側に倒せることは確認済み）
  - 生成コード側のストア追加と resolver 合成は `ProviderStores` パターンの参照に留まり、テンプレートの具体的な補間位置は Review 3 で確定する
  - RFC 7591 の原文は rfc-editor.org がネットワークポリシーで遮断されたため datatracker.ietf.org のミラーで確認した（内容は同一の公式ミラー）
- **判定**: Pass with changes（修正は本レビュー内で反映済み）
- **次回可能日**: 2026-10-01

## Review 2

- **日付**: 2026-10-07
- **観点**: セキュリティと適合性（認証認可上の脅威、鍵・トークン・シークレットの扱い、ログ禁止情報、有効期限、エラー情報の露出、package 境界との整合、CLI 後方互換、明示的有効化、生成コードの安全性、切り出し可能な構造、セキュリティ要件のテスト検証可能性）。Review 1 と重複する完全性の確認は繰り返さず、脅威面と応答契約の穴に絞った
- **確認資料**:
  - RFC 7591 §3.1（`application/json` での POST）・§3.2.2（エラー語彙の射程が「メタデータの不備」であること）・§5（DoS と TLS）
  - RFC 6750 §3.1（`WWW-Authenticate` のエラーコード。認証情報を伴わないリクエストにエラーコードを含めない SHOULD NOT）
  - RFC 6585 §4（429 Too Many Requests）
  - `packages/core/src/index.ts`（公開エクスポートの実測: `validateRegisteredRedirectUris` は 11 行・`generateRandomString` は 219 行で公開、`timingSafeEqual` は非公開。仕様の package 境界の主張どおり）
  - `packages/core/src/crypto-utils.ts`（`generateRandomString` が base64url を返すこと（32 バイト → 43 文字の主張と一致）、`timingSafeEqual` の HMAC 方式（本機能が複製する方式の実体））
  - `packages/core/src/authorization-request.ts` 353〜415 行（`validateRegisteredRedirectUris` の検査規則の実測: フラグメント禁止・危険スキーム `javascript:` `data:` `file:` `vbscript:` `blob:` の拒否・スキーム必須・非ループバック平文 http 拒否。全経路が違反 URI をメッセージへ埋め込んだ `server_error` の `AuthorizationError` を投げることを確認し、エラー変換設計（Review 1 指摘 1 の修正）が必要かつ十分であることを裏取り）
  - `packages/core/src/discovery.ts` 36・95・205-206 行（`registration_endpoint` の条件付き出力が実装済みで、フィールド名が一致）
  - `packages/cli/src/features.ts`（`EXPERIMENTAL_FEATURES` 末尾が `'rp-initiated-logout'` のままで、末尾追加の後方互換が成立すること）
  - `packages/experimental/src`（8 機能のいずれも `timingSafeEqual` を複製していないことの実測。本機能が最初の複製になるため、将来の core 公開 API 昇格の記録（仕様書の将来の昇格考慮）が妥当）
  - `samples/hono-cloudflare/src/oidc-provider/config.ts` 141 行（静的 client_id `example-client` が人間の命名であることの確認。U2 の判断材料）
  - `tasks/p3-generated-scope-policy-prototype-key-guard.md`（プロトタイプ経路キーの懸念が既出であることの確認）
- **指摘**:
  1. **`Content-Type` 検査が未規定**: RFC 7591 §3.1 は `application/json` での POST を定めるが、仕様はボディの中身しか検査していなかった。`text/plain` の HTML フォーム投稿は `name` / `value` の組で有効な JSON ボディを合成でき、CORS プリフライトなしのクロスオリジン POST が通る。オープン登録では攻撃者が直接叩けるため CSRF としての実害はないが、§3.1 適合と面の最小化のため生成ルートで `Content-Type` を検査すべき
  2. **401 応答が RFC 6750 §3.1 と不整合**: ヘッダ欠落時にも `error="invalid_token"` を返す設計は「認証情報を伴わないリクエストにエラーコードを含めない SHOULD NOT」に反する。また「欠落と不一致を区別しない」という要件自体にセキュリティ上の価値がない（要求者は自分が何を送ったかを知っており、区別しても攻撃者への追加情報はゼロ）。守るべき本質は「期待トークンの情報（長さ・部分一致）を応答へ反映しない」ことである
  3. **ボディ長上限の単位が未定義**: 「文字列の最大長」のままでは UTF-16 コード単位数とバイト長のどちらとも読め、多バイト文字を含む境界値テストが非決定的になる
  4. **未知フィールド除去の実装方式が未指定**: パース結果のスプレッドや `Object.assign` でのコピーを許すと、`__proto__` キーを持つ入力の扱いが実装任せになる
- **修正**（いずれも本レビュー内で仕様書へ反映済み）:
  1. 生成ルートの検証順序へ `Content-Type` 検査（`application/json`、パラメータ付き許容。違反は `invalid_client_metadata`）を挿入し、入出力・セキュリティ要件・conformance テスト計画へ追記
  2. 401 応答を「ヘッダ欠落 → `WWW-Authenticate: Bearer`（コードなし）/ 提示して失敗 → `error="invalid_token"`」の 2 形に確定し、「区別しない」要件を「期待トークンの情報を応答へ反映しない」へ置換。単体テスト計画へ分岐の検証を追加
  3. `maxBodyBytes` / `maxRegistrationBodyBytes` を UTF-8 バイト長（TextEncoder 基準）と定義し、多バイト境界のテストを追加
  4. 未知フィールド除去を allowlist-pick 方式（理解する 5 フィールドだけを新オブジェクトへ選び取る）と明記し、`__proto__` / `constructor` キーのテストを追加
- **未解決事項の確定**:
  - **U1 → `429 Too Many Requests` + 固定 JSON ボディ**。`invalid_client_metadata`（400）はメタデータの不備を表す語彙であり、流用するとクライアントに「メタデータを直せば通る」と誤認させ、変更再試行ループが DoS 対策を逆に増幅する。`Retry-After` は付けない（在庫の天井であり回復時期を約束できない）。上限値・現在数は応答へ反映しない
  - **U2 → `dcr-` + `generateRandomString(16)`**（128 ビット乱数、乱数部 22 文字）。静的 client_id は人間の命名（実測: `example-client`）のため、固定プレフィックスで名前空間が分かれ、上書き脅威が構造的に消える。`client_id` は秘密情報ではなく、由来の露出に失うものはない
- **確認して問題なしとした項目**: リプレイ（オープン登録では登録の複製しか起きず総数上限で抑止。initial access token は単一静的シークレットで PoC 範囲として文書化済み）/ SSRF（受理 5 フィールドに URL 参照先がなく、`redirect_uris` は保存のみで取得しない）/ シークレット強度（256 ビット・`crypto.getRandomValues`・`Cache-Control: no-store`・ログ禁止が明文化されテストで固定可能）/ 有効期限（`client_secret_expires_at: 0` は in-memory ストアのプロセス寿命で実質的に上限づけられ、誤解しやすい点の節で説明済み）/ package 境界（core の公開 API のみ使用・`timingSafeEqual` 複製の判断は実測と整合）/ CLI 後方互換（末尾追加・既定無効・未指定時バイト同一が完了条件 3 で固定）/ 明示的有効化（`--enable` のみ）/ grant_types 制限による experimental 機能間結合の遮断 / 切り出し可能な構造（純関数群 + 生成コード責務の分離は昇格方針 A と同型）
- **残リスク**:
  - initial access token が生成コード設定内の単一静的文字列であること（ローテーション・複数発行なし）は PoC 向け割り切りとして仕様書に明示済み。本番運用ギャップとして Docs の「本番非推奨」警告に含める
  - 動的登録クライアントはプロセス内で無期限（失効手段が再起動のみ）。RFC 7592 を非目標とする以上は構造上の帰結であり、Docs の既知の制約へ記載する
  - U3（パス名）が Review 3 へ残る（テンプレート一貫性の確認時に確定。セキュリティへの影響なし）
- **判定**: Pass with changes（修正は本レビュー内で反映済み）
- **次回可能日**: 2026-10-08

## Review 3

- **日付**: 2026-10-14
- **観点**: 実装着手可否（追加調査なしで着手できるか、受け入れ条件の客観性、対象ファイルと変更範囲、API・CLI・テスト・Docs・実装解説の一貫性、実装順序と検証方法、Experimental であることの利用者への明示）。Review 1・2 と重複する完全性・セキュリティの確認は繰り返さず、Review 2（2026-10-07）以降に main へ入った変更との整合と、U3 の確定に絞った
- **確認資料**:
  - リポジトリ現状（main = 053e86e、2026-10-14 取得）。Review 2 以降のコミット: cb33342（CLI 生成の契約テスト conformance.test.ts 廃止、2026-10-07）、216b95b（生成コード文字列を検査する CLI テストの削除）、7ebde04（`--db sql` 導入、2026-10-10）、705068e / deb6d96 / 053e86e（`--db kv` 追加と全 sample の `--db` 化、2026-10-11）
  - `packages/cli/src/features.ts`（`EXPERIMENTAL_FEATURES` 59〜68 行、末尾 `'rp-initiated-logout'` 67 行、キー対応表 197 行周辺）、`packages/cli/src/index.ts`（`withExperimentalPackage` 36〜48 行）— CLI 統合案が現行構造にそのまま載ることの実測
  - `packages/cli/src/frameworks/hono/templates.ts`（discovery スプレッドマージ 7304〜7371 行、基底 clientResolver 配線 443〜453 行）、`packages/cli/src/frameworks/web-standard/templates.ts`（hono のルートテンプレートを import して配線する構造）、`packages/cli/src/db.ts`（`--db sql` / `--db kv`）
  - 生成コードの現状（`samples/hono-cloudflare/src/oidc-provider/`）: `db/clients.ts`（`createSqlClientResolver` / `registerClient()` / `hashClientSecret` によるハッシュ保存）、`store.ts`（core ストア群 `ProviderStores` 687 行は `--db` でバックエンド差し替え、experimental ストアは in-memory の globalThis シングルトンのまま。1045〜1097 行の PAR ストアが先例）、`resolvers.ts` / `apply.ts`（`options.clientResolver ?? ストレージ既定` の合成点）、`config.ts`（`RegisteredClient` 133 行・`createInMemoryClientResolver` 179 行・`example-client` 145 行）
  - `packages/core/src/index.ts`（`validateRegisteredRedirectUris` 11 行・`generateRandomString` 221 行・`hashClientSecret` 333 行のエクスポート実測）、`packages/core/src/authorization-request.ts`（`validateRegisteredRedirectUris` 377 行へ移動）、`packages/core/src/token-request.ts`（`TokenClientInfo` 30 行、`clientSecretHash` 対応）
  - テスト基盤の現状: `packages/cli/src/__tests__/cli.test.ts`（CLI 自体の入出力のみ検証する現行方針の実測）、`tests/e2e/specs/`（実装済み 8 機能それぞれの spec と、`pushed-authorization-requests.spec.ts` の discovery ベースのスキップガード）、`samples/*/package.json`（`check:generated` と各 sample の `--db` 種別: express / fastify / hono = sql、nextjs = kv）、`samples/hono-cloudflare/src/app.ts` と `tests/e2e/playwright.config.ts`（`XAA_ALLOWED_AUDIENCES` の env 注入配線）
  - RFC 7591 §3.1（リクエスト例のパスが `POST /register` であること。U3 の確定材料）、OpenID Connect Discovery 1.0 §3（`registration_endpoint` は完全な URL を広告し、パス名に相互運用要件がないこと）
- **指摘**:
  1. **テスト計画が廃止済みの conformance.test.ts 層に依存**: 仕様のテスト計画と完了条件 2・4 は「CLI 生成コードに conformance.test.ts を追加する」前提だったが、cb33342（Review 2 と同日）で同層は廃止され、README のテスト方針も「生成 OP の挙動は tests/e2e と OpenID Conformance Suite で確認する」へ改訂済み。HTTP レベルの検証マトリクスの置き場所が消えていた
  2. **CLI テスト計画が現行方針と矛盾**: 「`/register` ルートが生成され import があること」等の生成コード文字列検査は、216b95b で削除された種類のテストであり追加できない
  3. **resolver 合成の記述が `--db` 以前の構造**: 「静的 `createInMemoryClientResolver` と合成」とあったが、現行の生成コードは `options.clientResolver ?? ストレージ既定`（`--db sql` は SQL resolver、`--db kv` は KV 版、なしは静的 Map）を基底とするため、合成対象は「apply テンプレートが解決した基底 resolver」と書くべきだった。ストア配置の参照（`ProviderStores` へ追加するとも読める書き方）も、experimental ストアは `ProviderStores` 外の in-memory シングルトンという先例（PAR / Device / CIBA）に合わせて明確化が必要だった
  4. **429 / 401 系 E2E の実行手段が未記述**: 生成コードの設定オブジェクトは sample 再生成で固定されるため、E2E から上限や initial access token を変える手段（sample 手書き `app.ts` の env 読み取り → `applyOidc` オプション、という XAA の既存配線）を仕様に書く必要があった。またオープン登録の検証と initial access token の検証は同じ OP で両立しない
  5. **将来の昇格考慮の記述が陳腐化**: 「core の静的クライアント（平文保持）」は、core が `hashClientSecret` / `clientSecretHash` を公開し `--db sql` の `registerClient()` がハッシュ保存する現状と不一致
  6. **行番号参照の広範なずれ**: 31c20a1（core リファクタ）と `--db` 導入で、仕様書・sources の行番号参照が多数ずれていた（features.ts 85→67、templates.ts 7601→7304〜7371、store.ts 648/985→687/1024 ほか）
- **修正**（いずれも本レビュー内で仕様書・理解資料・sources へ反映済み）:
  1. テスト計画を再構成: HTTP 検証マトリクスは `tests/e2e/specs/dynamic-client-registration.spec.ts` へ移し、discovery ベースのスキップガードで全 sample 共通実行とする。完了条件 2・4・5 を E2E 基準へ書き換え
  2. CLI テストをオプション解析・install 案内（CLI 自身の出力）・生成ファイル数・`check:generated` に限定
  3. resolver 合成を「apply テンプレートの基底 resolver を包む」に、ストアを「`--db` の有無に関わらず in-memory の globalThis シングルトン（PAR 先例）、`ProviderStores` へは加えない」に確定。理解資料の静的登録比較と再起動時の挙動も `--db` 込みで更新
  4. `applyOidc` オプションでの設定上書きと env 配線（XAA と同型）を設定値の節へ追記し、オープン登録系は hono-cloudflare・initial access token 系は express-flyio / fastify-flyio のどちらかへ `--enable` を追加して分担する方針を E2E 計画へ明記
  5. 昇格考慮を「昇格時は `registerClient()` 経由の永続化とハッシュ保存へ寄せる」に更新（v1 の in-memory 平文保持は `defaultRegisteredClients` との対称性として維持。Review 2 で受容済みのモデルから変更なし）
  6. 行番号参照を 2026-10-14 時点の実測へ一括更新
- **未解決事項の確定**:
  - **U3 → `/register`**。テンプレートのルート命名は各仕様の例示パスをそのまま使う慣行（`/par` / `/device_authorization` / `/backchannel_authentication` / `/logout`）であり、RFC 7591 §3.1 のリクエスト例が `POST /register`。discovery が完全な URL を広告するためパス名自体に相互運用要件はない
- **確認して問題なしとした項目**: 公開 API 案（純関数 4 つ + エラー型 + 2 型）は現行の subpath export 構成（8 機能で実証済み）へそのまま追加できる / 受け入れ条件は 7 項目すべて客観的に判定可能（テスト成否・バイト同一・エクスポート有無） / 依存方向は現行 package.json（peerDependencies `>=0.3.0 <1.0.0`）と整合 / `RegisteredClient` 型は任意フィールドが増えていた（`userinfoSignedResponseAlg` 等）が登録レコードの適合に影響なし / Experimental の明示は features.ts の JSDoc・unknown-feature メッセージ・Docs の警告の 3 点で担保（既存 8 機能と同じ） / 実装順序 7 段階は現行のテンプレート構造（hono 定義 → web-standard 配線）で実行可能 / セキュリティ要件に未解決事項なし（U3 はパス名のみでセキュリティ影響なし、Review 2 の脅威評価は `--db` 変更の影響を受けない: 登録エンドポイントの面・検証規則・応答契約は不変で、動的ストアは従来どおり in-memory）
- **残リスク**:
  - 生成テンプレートは行番号が大きく動きやすい（今回 7601→7304）。実装時は行番号ではなく「discovery スプレッドマージの実装済み機能群の末尾」「apply の基底 resolver 解決点」というパターン位置で挿入箇所を特定すること
  - E2E の 429 検証は上限 env を小さくした sample で行うが、同一 OP 上の他の DCR テストが登録数を消費するため、実行順に依存しない書き方（上限+1 回まで登録して 429 を確認する等）が要る。実装時の注意として記録
  - initial access token 検証を担う sample（express-flyio / fastify-flyio のどちらか）の最終選択は実装時に決める（どちらでも仕様上の差はない）
- **判定**: Pass with changes（修正は本レビュー内で反映済み）。3 回のレビューを完了し、`status: Approved` / `implementation_ready: true` へ更新
- **次回可能日**: —（レビュー完了。次の更新は実装開始時の `Implementing`）
