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
