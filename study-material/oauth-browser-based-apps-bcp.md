# OAuth 2.0 for Browser-Based Apps（BCP）対応観点

## ステータス

🟡 Major（セキュリティ / 相互運用性）/ 未着手

## 1. このトピックで確認したいこと

`draft-ietf-oauth-browser-based-apps`（OAuth WG BCP）は **SPA / ブラウザベースの OAuth クライアント**に向けた現代的なベストプラクティス。OP 側にも影響する観点として:

- PKCE（S256）必須化（既実装）
- リフレッシュトークンの公衆クライアント向け Rotation / 短命化 / Sender-Constrained 化（既実装の Rotation で部分対応）
- 認可リクエストのリダイレクト URI 完全一致（既実装）
- CORS / プリフライト対応（`study-material/cors-cross-origin-support.md` で扱い済み）
- セッション維持の選択肢（`prompt=none` / silent renew / BFF パターン）
- Token Endpoint / UserInfo Endpoint の CORS 対応（既存トピックと重複しないよう注意）

本ファイルは「散在する SPA 向け考慮点を**統合的に俯瞰する文書**」として、既存ファイル（CORS、Refresh Rotation、PKCE）への差分・追加論点に絞って整理する。

## 2. 関連する仕様・基準

共通の仕様索引は `study-material/basic-op-requirement-traceability.md` を参照。本トピック固有のポイント:

- **draft-ietf-oauth-browser-based-apps（OAuth 2.0 for Browser-Based Apps）**:
  - SPA は public client。PKCE（S256）必須。
  - **3 つのアーキテクチャパターン**:
    1. **BFF（Backend For Frontend）**: SPA は OP と直接対話せず、自分のサーバを経由する。OAuth はサーバ ↔ OP、Cookie はサーバ ↔ SPA。最も安全側で推奨。
    2. **Token-Mediating Backend**: サーバが OP と OAuth、SPA にトークンを部分提供。
    3. **JavaScript Application without Backend**: SPA がブラウザ内で直接トークンを保持。リフレッシュトークン推奨、ただし sender-constrained or rotation 必須、保存場所注意。
  - リフレッシュトークン推奨上限（短命）、Sender-Constrained 化（DPoP / mTLS）、Token Storage は `httpOnly` Cookie / Web Worker / 主記憶。
  - Implicit Flow / Hybrid Flow は使うべきではない（Code + PKCE のみ）。
- **OIDC Core**: 直接の影響は無いが、ID Token の at_hash 検証（既実装）が SPA でも重要。
- **CORS / Cross-Origin**: SPA からの直接呼び出しが必要なエンドポイント:
  - **Token Endpoint**（Pattern 3 のとき）
  - **UserInfo Endpoint**（Pattern 3 のとき）
  - **JWKS / Discovery**（クライアントが ID Token を検証する場合）
  - **Revocation Endpoint**（任意）
  - **Introspection Endpoint**（公衆クライアントは通常呼ばないが、BFF 経由なら可）

## 3. 参照資料

- OAuth 2.0 for Browser-Based Apps（draft）: https://datatracker.ietf.org/doc/html/draft-ietf-oauth-browser-based-apps
- OAuth 2.1: https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1
- OAuth 2.0 Security Best Current Practice（RFC 9700）: https://www.rfc-editor.org/rfc/rfc9700.html

## 4. 現在の実装確認

- PKCE S256 必須化: 実装済み（`authorization-request.ts:387-427`、`token-request.ts:531-557`）。
- Refresh Token Rotation: 実装済み（`tasks/done/01-refresh-token.md`）、誤検知緩和は `study-material/refresh-token-rotation-replay-grace.md` で議論中。
- リダイレクト URI 完全一致 / fragment 拒否: 実装済み。
- CORS: 未対応（`study-material/cors-cross-origin-support.md` で扱い中）。
- DPoP（Sender-Constrained）: 未対応（`tasks/T-019-dpop.md`）。
- BFF パターンを推奨するドキュメントは無い。

## 5. 現在の実装との差分

満たしていること:

- PKCE / Code Flow / Redirect URI 検証 / Refresh Rotation という SPA 向け中核は既に揃う。

不足／要確認:

- 🟡 **アーキテクチャパターンの推奨が無い**: 利用者が SPA を組むとき、BFF パターンか Pattern 3 かの選択ガイドが無い。SPA 検証 PoC で「どこに何を置くか」の判断材料が抜けている。
- 🟡 **CORS は別タスクで扱われているが**、本ファイルは「**どのエンドポイントを CORS 対象にすべきか**」を SPA パターンと結びつけて整理する差分を持てる。
- 🟡 **DPoP は別タスク**だが、SPA における Sender-Constrained Refresh Token は **DPoP がほぼ唯一の現実解**であり、SPA 文脈で「DPoP 採用を強く推奨」が一文どこにも無い。
- 🟡 **CLI 生成テンプレに SPA 用 client 例が無い**: BFF 例 / SPA 直接例のサンプルがあると検証が早い。

## 6. 改善・追加を検討する理由

価値:

- 現在の Web 開発では SPA が多数派。BFF パターン採用が増えているが「どう構成すれば安全か」の OSS リファレンスが少ない。
- 本リポジトリの差別化軸「Speed（最新仕様に追随）」と整合。BCP は実装者ドラフト中だがほぼ安定。
- 利用者の検証 PoC 入口として、SPA 用のテンプレ存在は採用判断に直結。

導入難易度:

- 🟢 **ドキュメント中心**: 推奨パターンの提示で大半が解決。
- 🟡 **CLI テンプレ拡張**: SPA + BFF 例の追加は **CLI 側の拡張**。core は変更不要。

実装しない場合:

- 利用者が独自に手探りで SPA を組み、Token を localStorage に保存するなどの典型アンチパターンを踏む。

## 7. 実装方針の候補

### 方針A（推奨パターンを文書化）

- 本ファイルに「3 つのアーキテクチャパターン × Token Storage × Refresh の選び方」を表で固定。
- 既存ファイルへのリンク:
  - CORS: `study-material/cors-cross-origin-support.md`
  - Refresh Rotation: `study-material/refresh-token-rotation-replay-grace.md`、`tasks/p1-refresh-token-absolute-lifetime.md`
  - DPoP: `tasks/T-019-dpop.md`
  - 公衆クライアントの Token Endpoint 利用: `tasks/p1-public-client-token-endpoint.md`

### 方針B（CLI テンプレに SPA 系サンプルを追加）

- BFF パターンのサンプル client（Hono + フロント別ディレクトリ）。
- Pattern 3（SPA 直接）の最小サンプル。Token は memory + Refresh Token Rotation 前提。
- 各サンプルに `// SECURITY:` コメントで注意事項を明示。

### 方針C（DPoP + SPA テンプレ）

- DPoP 実装（T-019）完了後、SPA + DPoP のサンプルを提供。Sender-Constrained Refresh Token をブラウザで実演。

判断材料:

- 方針 A は即時可、リターンも大きい。
- 方針 B は手数増だが、利用者の検証速度を劇的に上げる。
- 方針 C は DPoP 実装が前提なので順序的に後段。

## 8. タスク案

- [ ] 方針 A / B / C のどこまでやるかを人間が判断
- [ ] 方針 A 採用時:
  - [ ] 本ファイルに「アーキテクチャパターン × Token Storage × Refresh 戦略」表を固定
  - [ ] 既存関連ファイルへの相互リンクを整備
  - [ ] CLI 生成コードのコメントに本ファイルへの参照を追加（"For SPA, see ..."）
- [ ] 方針 B 採用時:
  - [ ] CLI テンプレに `--frontend bff` / `--frontend spa` のオプションを追加
  - [ ] BFF サンプル: Hono + Cookie session + Code + PKCE
  - [ ] SPA サンプル: フロント側に PKCE 実装、トークンは memory 保持、Refresh Rotation 前提
  - [ ] E2E テスト: 主要フローが両パターンで通ること
- [ ] 方針 C 採用時: T-019（DPoP）後段で SPA + DPoP サンプルを追加
- [ ] `tasks/p1-public-client-token-endpoint.md` および `study-material/cors-cross-origin-support.md` に本ファイルへの参照を追記（重複説明回避）
