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
