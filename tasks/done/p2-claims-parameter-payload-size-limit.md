# [P2] `claims` リクエストパラメータの `JSON.parse` 前にサイズ上限を課し、未認証 DoS 面を削る

## ステータス

🟡 Medium / 未着手

## 背景

認可エンドポイントは**未認証・公開**で、任意の第三者が任意の入力を送れる。core は OIDC Core §5.5 の `claims` パラメータを `parseClaimsRequest()` で `JSON.parse` するが、**パース前のサイズ上限が無い**。攻撃者が巨大／深ネストの `claims` を送ると、パースで CPU・メモリを消費させられる（リクエスト単位のリソース枯渇 = アプリ層 DoS）。

本ライブラリは可搬性（Web 標準のみ、エッジで動く）を売りにしており、Cloudflare Workers 等では**1リクエストの CPU/メモリ制限が厳しい**。単一の過大リクエストがワーカー異常終了・課金増・近隣リクエストの巻き添えにつながりうるため、最も制約の厳しい実行環境を基準に安全側へ倒す価値が高い。

頻度ベースのレート制限は `study-material/rate-limiting-and-brute-force.md`（直交する別面）で扱う。検討の経緯・判断材料は `study-material/done/untrusted-input-payload-size-dos-hardening.md` を参照。

本タスクは、最小・後方互換で効く「`JSON.parse` 前のサイズ上限」とその回帰テストに限定する。深さ／キー数上限（方針B）・オプション API 化（方針C）・フレームワーク層のボディ上限テンプレート（方針D）は検討段階として study-material に残す。

## 対象ファイル

- `packages/core/src/authorization-request.ts`（`parseClaimsRequest`、必要なら上限定数 or オプション）
- `packages/core/src/authorization-request.test.ts`（サイズ上限の回帰テスト）

## 仕様参照

- OIDC Core 1.0 §5.5 — `claims` は JSON シリアライズで送られる。構文は規定するが**サイズ上限は規定しない**（＝実装が安全側に決めてよい）。
- OAuth 2.0 Security BCP（RFC 9700）§2.5 — 未認証エンドポイントの濫用耐性。
- OWASP API4:2023 Unrestricted Resource Consumption — 信頼できない入力はパース前にサイズ上限を課す。

## 現状の実装

- `authorization-request.ts:711-746` `parseClaimsRequest()`:
  - `:720` で `JSON.parse(raw)` を**無条件**に実行。`raw.length` 上限・深さ／キー数上限が無い。
  - パース後は `userinfo` / `id_token` のみ採用（`:739-745`）するため**採用構造は限定的**だが、パース自体は生 JSON 全体に走るため巨大／深ネスト入力のコストはパース段階で発生する。
- パラメータ系（`scope`/`audience` の split 等）は線形コストで増幅は小さい。JSON パースが最も非対称な攻撃面。
- 上限超過時に使える拒否経路（`AuthorizationError(invalid_request)`）は `parseClaimsRequest` 内に既に存在する。

## 修正方針

- [ ] `parseClaimsRequest` の冒頭、`JSON.parse` の**前**に `raw.length` の上限チェックを追加し、超過時は `AuthorizationError(invalid_request)`（redirectable, state 付き）で拒否する
- [ ] 上限値は定数化（または `validateAuthorizationRequest` オプションで上書き可能化）し、**具体値は本タスク内で人間が確定**する。判断材料: 正規の `claims` は通常数百バイト〜1KB 程度で、数 KB を超える正規利用は稀（推測値は固定せずレビューで決める）
- [ ] 既存の「JSON でない / オブジェクトでない」拒否ロジックは維持する
- [ ] エラー文言はユーザー入力を含めない（`sanitizeErrorDescription` 経路と整合。巨大入力をエコーしない）

## テスト要件

- [ ] 上限を超える長さの `claims` 文字列が `invalid_request` で拒否されること（`JSON.parse` まで到達しないことを意図したテスト）
- [ ] 上限以内で `userinfo` / `id_token` を含む典型的な `claims` は従来どおりパースされ、採用キーが維持されること（回帰）
- [ ] 上限境界値（ちょうど上限／上限+1）の挙動が決定的であること
- [ ] 既存の `claims` 不正系（非 JSON、配列、null）の拒否が回帰しないこと

## 完了条件

`pnpm --filter @maronn-openid-connect/core test` がパスし、上記テストが追加されていること。`parseClaimsRequest` が `JSON.parse` 前にサイズ上限を課し、超過時に `invalid_request` を返すこと。上限値が定数 or オプションとして明示され、レビューで確定されていること。
