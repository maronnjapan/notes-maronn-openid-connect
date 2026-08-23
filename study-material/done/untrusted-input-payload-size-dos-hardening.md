# 未認証入力のサイズ・深さ上限による DoS ハードニング（`claims` JSON パース等）

## ステータス

🟡 Medium（セキュリティ / 可搬性ランタイム保護）/ 未着手

## 1. このトピックで確認したいこと

認可エンドポイントは**未認証・パブリック**なエンドポイントであり、任意の第三者が任意の入力を送れる。本リポジトリ core は `claims` リクエストパラメータを `JSON.parse` でパースするが、**入力サイズ・ネスト深さ・要素数の上限が無い**。攻撃者が巨大あるいは深くネストした JSON を送ると、CPU/メモリを消費させられる（リクエスト単位のリソース枯渇 = アプリ層 DoS）。

可搬性（Portability）を重視し Cloudflare Workers などのエッジランタイムで動くことを想定する本ライブラリでは、**1リクエストあたりの CPU 時間・メモリが厳しく制限される**環境が多く、単一リクエストの過大パースがそのままワーカーの異常終了・課金増・近隣リクエストの巻き添えにつながりうる。

本ファイルでは、

- core が未認証入力をパースする箇所と、サイズ／深さ上限の有無
- どの入力が「認証前に到達可能」で攻撃面になるか
- サイズ・深さ・要素数上限による安全側のガードレール案

を整理する。

> **重複回避の方針**: リクエスト**頻度**に対するレート制限・ブルートフォース対策は `study-material/rate-limiting-and-brute-force.md` が扱う。本ファイルはそれと重複せず、「**1リクエスト内の入力ペイロードのサイズ・構造**」という直交する攻撃面にのみ絞る。TLS/ヘッダ等は `study-material/http-security-headers-and-tls.md` を参照。JWT のサイズ・アルゴリズム濫用は `study-material/jwt-bcp-rfc8725.md` を参照。

## 2. 関連する仕様・基準

共通の仕様索引は `study-material/basic-op-requirement-traceability.md` を参照。本トピック固有のポイント:

- **OAuth 2.0 Security BCP（RFC 9700）§2.5 / DoS 一般**: 認可サーバは未認証エンドポイントへの濫用に対して堅牢であるべき。リソース消費を伴う処理（暗号演算、パース）は攻撃面として意識する。
- **OWASP（一般原則）**: 信頼できない入力をパースする前に**サイズ上限を課す**こと、再帰的データ構造（JSON）には**深さ上限**を課すことが DoS 緩和の基本（"unrestricted resource consumption" / "deeply nested objects"）。
- **OIDC Core 1.0 §5.5（claims request parameter）**: `claims` は JSON としてシリアライズされて送られる。仕様は構文を定めるが**サイズ上限は規定しない**ため、上限の設定は実装の裁量（＝実装が安全側に決める余地がある）。
- **OIDC Core 1.0 §6（Request Object）/ RFC 9101（JAR）**: `request` / `request_uri` も大きな JSON/JWT を運ぶ攻撃面になりうる（本リポジトリは現状これらを非対応として拒否する方針。`study-material/request-object-rejection-and-discovery-honesty.md` 参照）。本ファイルでは「拒否する場合でも、拒否前に巨大入力を読み切らない」観点で関連する。

> 注: ここでいう上限値（バイト数・深さ・要素数）は**仕様が定める固定値ではなく、実装が安全側に選ぶ運用パラメータ**である。本ファイルでは推測で「正しい値」を断定せず、判断材料と相場観の提示に留める。

## 3. 参照資料

- OAuth 2.0 Security Best Current Practice（RFC 9700）— https://datatracker.ietf.org/doc/html/rfc9700 （未認証エンドポイントの濫用耐性）
- OpenID Connect Core 1.0 §5.5（Requesting Claims using the "claims" Request Parameter）— https://openid.net/specs/openid-connect-core-1_0.html#ClaimsParameter
- OWASP API Security Top 10 — API4:2023 Unrestricted Resource Consumption — https://owasp.org/API-Security/editions/2023/en/0xa4-unrestricted-resource-consumption/
- OWASP — Denial of Service / "Insufficient Resource ... deeply nested JSON" — https://cheatsheetseries.owasp.org/cheatsheets/Denial_of_Service_Cheat_Sheet.html
- 既存 `study-material/rate-limiting-and-brute-force.md`（頻度制御。本ファイルと直交）
- 既存 `study-material/request-object-rejection-and-discovery-honesty.md`（request/request_uri 非対応の方針）

## 4. 現在の実装確認

- `packages/core/src/authorization-request.ts:711-746` `parseClaimsRequest()`:
  - `JSON.parse(raw)` を**無条件**に実行（`:720`）。`raw` の長さ上限・パース後の深さ／キー数の上限チェックは無い。
  - パース後に `userinfo` / `id_token` のみ採用し他を捨てる（`:739-745`）ため、**採用される構造は限定的**だが、**パースそのものは生 JSON 全体に対して走る**ため、巨大／深ネスト入力のコストはパース段階で発生する。
  - `sanitizeClaimsMember`（`:748-764`）は1階層分のキーを走査するが、ここでも要素数上限は無い。
- `packages/core/src/authorization-request.ts:615` `scope` の split、`:675` `audience` の split など、他の文字列パラメータも長さ上限は無い（ただしこれらは線形コストで、JSON ほど増幅しない）。
- core は HTTP リクエストボディ自体を読まない（フレームワーク層が読んでパラメータ化して core に渡す設計）。したがって**ボディ全体のサイズ上限はフレームワーク／ランタイム責務**だが、その期待値はどこにも明記されていない。
- `packages/sample/src/oidc-provider/routes/authorize.ts` 等のルートにも、リクエストボディ／クエリ長の明示的上限は見当たらない。

## 5. 現在の実装との差分

満たしていること:

- ✅ `claims` のパース後に採用するキーを `userinfo` / `id_token` に限定し、想定外の構造を捨てている（攻撃後の影響は限定的）。
- ✅ レート制限（頻度）の検討は別ファイルで進行中。

不足・曖昧（本トピック固有の差分）:

- 🟡 **`claims` の `JSON.parse` 前にサイズ上限が無い**: 未認証で到達できる認可エンドポイントに、巨大な `claims` 文字列を送るとパースコストが青天井。エッジランタイムでは単一リクエストの CPU 上限超過 → ワーカー異常終了の引き金になりうる。
- 🟡 **JSON 深さ／キー数の上限が無い**: `JSON.parse` は深いネストでもパースするため、深ネスト JSON でのリソース消費・スタック圧迫の余地。
- 🟡 **ボディ／クエリ全体サイズの期待値が未文書化**: 「フレームワーク／ランタイム側で N バイト上限を課すべき」という前提が利用者に伝わっていない。生成コード（CLI テンプレート）にも上限ミドルウェアの雛形が無い。
- 🟡 **拒否系入力でも先に読み切る懸念**: request/request_uri を拒否する設計でも、拒否判定の前に巨大入力を受領・保持してしまえば DoS 面は残る（フレームワーク層の上限が無い場合）。

## 6. 改善・追加を検討する理由

- **なぜ価値があるか**: 認可エンドポイントは未認証・公開で、攻撃者がコスト非対称（小さな攻撃コストで大きなサーバ負荷）を作りやすい古典的 DoS 面。サイズ・深さ上限は**極めて低コストで攻撃面を大きく削れる**典型的なハードニング。
- **Basic OP 必須か拡張か**: Basic OP 認定の必須テスト項目ではない（認定は機能適合性が中心）。よって**拡張ではなくセキュリティ・ハードニング**として位置づける。本リポジトリのコンセプト（セキュリティ最優先・どこでも動く）に強く合致する。
- **可搬性ランタイム特有の理由**: Workers / エッジは「1リクエストの CPU 数十ms」級の制限が一般的で、サーバ型より単一リクエストの過大処理の影響が大きい。可搬性を売りにする以上、最も制約の厳しい実行環境を基準に安全側へ倒す価値がある。
- **導入しやすさ**: `parseClaimsRequest` の冒頭に `raw.length` 上限チェックを足すだけで `JSON.parse` 前ガードが入る（🟢 局所的・後方互換）。深さ／キー数上限はパース後に軽量な再帰チェックを足すか、上限付きパーサを使う（🟡 やや設計判断）。ボディ上限はフレームワーク層／生成テンプレートの責務として文書化＋雛形提供。
- **既存実装との接続**: `parseClaimsRequest` は既に `AuthorizationError(invalid_request)` を投げる経路を持つので、上限超過時も同じ経路で `invalid_request` を返せる（一貫性が高い）。
- **利用者・運用者のメリット**: 上限値が明示されれば、利用者は自分のランタイム制約に合わせて調整でき、想定外の高コストリクエストで巻き添え障害を起こすリスクを下げられる。
- **実装しない場合のリスク**: 公開エンドポイントに対する安価な DoS 面が残る。特にエッジ環境では単一の悪意リクエストが課金・可用性に波及しうる。

## 7. 実装方針の候補

最終判断は人間が行う。上限の**具体値は人間が運用要件に合わせて決定**する前提で、候補を整理する。

### 方針A（`JSON.parse` 前のサイズ上限）

- `parseClaimsRequest` 冒頭で `raw.length` が上限（例: 数 KB オーダー、要検討）を超えたら `invalid_request` で拒否。
- 局所的・後方互換・最小コスト。まず入れる価値が高い。

### 方針B（パース後の深さ／キー数上限）

- パース結果に対し、軽量な再帰で「最大深さ」「総キー数」を検査し、上限超過なら `invalid_request`。
- または上限付き JSON パーサ（外部依存は不可方針のため自前の軽量バリデータ）を検討。
- A より設計判断が要るが、深ネスト攻撃に対して堅い。

### 方針C（上限を設定可能オプションに）

- `validateAuthorizationRequest` のオプションに `limits?: { maxClaimsBytes?; maxClaimsDepth?; maxClaimsKeys? }` を追加し、デフォルトは安全側の固定値。利用者がランタイム制約に応じて上書き可能。
- 可搬性ライブラリとして筋が良い（環境ごとに最適値が違うため）。

### 方針D（フレームワーク層のボディ／クエリ上限の文書化＋テンプレート雛形）

- 「core に渡す前に、フレームワーク／ランタイムでリクエストボディ・クエリ長の上限ミドルウェアを置くこと」を `resolver-and-store-contract.md` 同様の利用者向けガイドとして明文化。
- CLI 生成テンプレート（`packages/cli/src/frameworks/*`）に上限ミドルウェアの雛形を入れるかを検討。
- core 変更不要。利用者の取りこぼしを防ぐ。

判断材料:

- 最小で効くのは **A**（parse 前サイズ上限）。次点で **B/C**（深さ・設定化）。**D** は責務境界の明文化として並行で価値がある。
- 上限の数値は仕様が定めないため、**推測で固定せず**、相場（典型的な `claims` は数百バイト〜1KB程度、正規利用で数 KB を超えることは稀）を判断材料として人間が決める。

## 8. タスク案

- [ ] 方針 A: `parseClaimsRequest`（`packages/core/src/authorization-request.ts`）の `JSON.parse` 前に `raw.length` 上限チェックを追加し、超過時 `invalid_request`（redirectable）で拒否する。上限値はオプション化 or 定数化（値は人間が決定）
- [ ] 方針 B: パース後の最大深さ・総キー数の軽量検査を追加（外部依存なしの自前実装）
- [ ] 方針 C（検討）: `validateAuthorizationRequest` のオプションに上限の上書き口を追加するか判断
- [ ] 方針 D: フレームワーク層でのボディ／クエリ長上限の必要性を利用者ガイドに明文化し、CLI テンプレートへ雛形を入れるか判断
- [ ] テスト: 上限超過の `claims`（巨大文字列／深ネスト）が `invalid_request` で拒否され、正規サイズの `claims`（`userinfo`/`id_token` を含む典型ケース）は従来どおり通ること、を回帰固定

> 上記のうち、方針 A（parse 前サイズ上限）＋対応テストは**低リスク・後方互換で着手可能**なため `tasks/` にタスク化する。方針 C（オプション API 追加）・方針 D（テンプレート雛形）は API/テンプレート設計判断を伴うため検討段階に留め、本ファイル（→ done）に判断材料として残す。上限の**具体値**はタスク内で人間が確定する。
