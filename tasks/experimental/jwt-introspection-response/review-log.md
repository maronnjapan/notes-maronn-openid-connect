# レビューログ: JWT Response for OAuth Token Introspection (RFC 9701)

## Review 1

- **日付**: 2026-08-24（仕様作成日を Review 1 として実施）
- **観点**: 仕様の完全性（問題・スコープ・非目標の明確さ / 一次資料の読み違い / 公開API案の subpath export 実装可能性 / CLI統合の現実性 / 依存方向 / テスト定義 / 未解決事項の明示 / 理解資料の自立性）
- **確認資料**:
  - RFC 9701 本文全文（rfc-editor 由来のテキストを取得し、§3 / §4 / §5 / §6 / §7 / §8.1 / §8.2 / §9 の規範文言を直接確認。§5 の非規範例 JWT のヘッダー・ペイロード構造を仕様書の表と突き合わせ）
  - `study-material/ext-jwt-introspection-response-rfc9701.md`（候補評価の下敷き。候補 A の core 実装案を experimental 隔離へ読み替える差分の確認）
  - `packages/core/src/introspection.ts`（`IntrospectionResponse` の `client_id` / `aud` メンバー: 135 / 143-144 行。audience 制限が応答オブジェクトだけで判定できる根拠）
  - `packages/core/src/index.ts`（`selectSigningKeyByAlg`: 242 行 / `SigningKey`: 246 行 / `INACTIVE_INTROSPECTION_RESPONSE`: 294 行の公開確認）
  - `packages/experimental/src/jarm/response-jwt.ts`（compact JWS 自前実装・RS256 固定・kid・「RS256 鍵であること」の引数契約の先例）
  - `packages/cli/src/frameworks/hono/templates.ts`（`introspectionRouteTemplate`: 6231-6360 行の応答出口と catch 分岐 / `c.set('signingKeys', ...)`: 290 行が全ルート共通ミドルウェアにあること / discovery スプレッドマージ: 5306 行付近 / `loginRouteTemplate(corePkg, features)`: 5314 行の引数追加先例）
  - `packages/cli/src/frameworks/hono/index.ts:45` / `packages/cli/src/frameworks/web-standard/templates.ts:2459`（`introspectionRouteTemplate` の呼び出し 2 箇所）
  - `packages/cli/src/frameworks/web-standard/templates.ts` の `toWebRouteTemplate`（import 置換のみの薄い変換であること）と `WebContext` クラス（`text()` が設定済み Content-Type を上書きしないこと）
  - `packages/cli/src/__tests__/par-feature.test.ts:112-114`（unknown-feature テストの期待メッセージ構造）
  - `tasks/p3-introspection-caller-authorization-hook.md`（core フック提案との責務境界）
  - `tasks/experimental/ciba/`（Approved 済み。対象エンドポイントの重複が無いことの確認）
- **指摘**:
  1. **[一次資料・確認] 401 vs 400 の仕様間相違を明文化**: RFC 9701 §5 Note は認証なし呼び出しへ HTTP 400 の MUST を置くが、既存パイプラインは RFC 7662 §2.3 系の 401 を返す。読み違いではなく両仕様の実際の相違であることを本文で再確認し、仕様書「エラー応答」の節に相違の記録と設計判断（401 維持。MUST の実質は認証必須の既存挙動で満たす）を明記した
  2. **[CLI統合の現実性・修正] `introspectionRouteTemplate` の呼び出し箇所の列挙漏れ**: 初稿は web-standard 側の 1 箇所のみを挙げていたが、実地確認で `hono/index.ts:45` と `web-standard/templates.ts:2459` の 2 箇所であることを確認し、CLI オプション案と実装順序の両方を修正した
  3. **[実装可能性・確定] JWT 応答の返却手段（U2）**: hono の `c.text` と web-standard 変換先の `WebContext.text` がどちらも設定済み `Content-Type` を上書きしない実装であることを現物で確認し、`c.header` → `c.text(jwt)` のパターンで両変換系に展開できることを確定。U2 を open から確定へ更新した
  4. **[実装可能性・確認] 公開 API 案が subpath export で実装可能なこと**: 純関数 3 つのみでストア契約・設定・エラークラスが不要な構成を確認。`exports["./jwt-introspection-response"]` は既存 4 機能と同型で追加できる
  5. **[完全性・確認] unknown-feature テストへの影響**: `par-feature.test.ts` の期待メッセージは experimental 一覧の部分文字列一致であり、`EXPERIMENTAL_FEATURES` 末尾への追加なら壊れない（CIBA のときの「未定義名 'ciba' の差し替え」問題は本機能名では発生しない）。末尾追加の注意を CLI オプション案に記載した
  6. **[スコープ判断・記録] JSON 経路への audience 制限の不適用**: RFC 9701 は RFC 7662 応答を廃止しないこと、JSON 経路の呼び出し元認可は既存タスク `p3-introspection-caller-authorization-hook.md` の責務であることを確認し、JWT 経路限定の設計判断として非目標・sources「記録」に明記した
- **修正**: 指摘 2・3 を同日中に反映（specification.md）。指摘 1・6 は初稿執筆中に確認して本文へ組み込み済み
- **残リスク**:
  - U1（audience 制限に使う `aud` の意味論。生成コードのトークンに `aud` がどう入るかの実地確認）が open。制限既定の妥当性に関わるため Review 2 のセキュリティ観点で確認する
  - U3（conformance テストでの JWT 検証手段。既存 conformance テンプレートの ID トークン検証を流用できるか）が open。Review 3 の実装着手可否で確認する
  - cross-feature 依存の検証（`--enable jwt-introspection-response --disable introspection` の拒否）は本機能が初の仕組みで、`resolveFeatures` への挿入位置と既存テストへの影響を Review 3 で確認する
- **判定**: **Pass with changes**（指摘 2・3 を同日修正済み。仕様の完全性の観点で残る事項は未解決事項表に明示されており、Review 2 の観点（セキュリティ・適合性）に引き継ぐ）
- **次回可能日**: 2026-08-25
