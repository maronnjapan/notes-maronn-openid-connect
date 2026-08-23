# Resolver / Store 契約と OSS 利用者向け実装ガイドライン

## ステータス

🟡 Major（OSS UX / 信頼性）/ 未着手

## 1. このトピックで確認したいこと

本リポジトリの core は、永続化を **resolver / store の注入**で外部化している:

- `ClientResolver`、`TokenClientResolver`
- `AuthorizationCodeResolver`
- `RefreshTokenResolver`
- `SessionResolver`、`AuthTransactionStore`
- `SigningKeyProvider`
- 各 introspection / revocation の resolver

OSS 利用者は **これらを自分のストア（D1 / KV / Postgres / Redis 等）で実装する**必要がある。
ここでは、resolver/store が満たすべき **契約**（同時実行・冪等性・一貫性・TTL・ロック・障害時のフェイルクローズ）と、それを満たさない実装が引き起こす仕様違反 / セキュリティ問題を整理する。
契約の明文化が **個別タスクで散発的にしか触れられておらず**、横断ガイドラインが無いため、本ファイルで集約する。

## 2. 関連する仕様・基準

共通の仕様索引は `study-material/basic-op-requirement-traceability.md` を参照。本トピック固有のポイント:

- **OAuth 2.1 §4.1.3 認可コードの一度限り使用（one-time use）**: 同じ認可コードが 2 回 token endpoint に提出されたら、AS は新規発行を拒否し、その authorization code に紐づく **過去発行トークンを失効**するべき（実装に推奨される）。
  - これは「resolver/store の **`markAsUsed` がアトミックで race-condition なし**」を前提とする。
- **OAuth 2.0 Security BCP / Refresh Token Rotation**:
  - リフレッシュトークン回転で「同じ refresh token が 2 回提示されたら全 grant を失効（cascade revocation）」が推奨。
  - これは store の **CAS（Compare-And-Swap）/ atomic update**が必須。
- **OIDC Core §3.1.3.2**: `code` の重複検出を AS の責務として記載。
- **`SigningKey` rotation**: `signing-key.ts` のキャッシュ TTL（`createCachedSigningKeyProvider`）と、利用者の secret store の更新タイミングが整合しないと「JWKS が古い」「token に古い `kid`」が同時発生し、クライアントの検証が壊れる。
- **`SessionResolver`**: `prompt=none` のセッション検証 / `max_age` 再認証判定が正しく動くため、`SessionResolver` は **少なくとも参照一貫性**（書いたら次の読みで反映）を持つ必要がある。
- **`AuthTransactionStore`**: ログイン → 同意 → token 発行までの中間状態を保持。**他リクエストから書き換え不可**でなければ CSRF / トランザクション hijack の経路になる。

## 3. 参照資料

- OAuth 2.1 draft §4.1.3 / §6（Refresh Token）: https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1
- OAuth 2.0 Security Best Current Practice（RFC 9700 §4.14、refresh token rotation の cascade）: https://www.rfc-editor.org/rfc/rfc9700.html
- OIDC Core 1.0 §3.1.3.2: https://openid.net/specs/openid-connect-core-1_0.html#TokenRequest
- 既存 `study-material/refresh-token-rotation-replay-grace.md`（再利用検知の誤検知緩和、本ファイルの context）

## 4. 現在の実装確認

- `packages/core/src/token-request.ts`:
  - 認可コード一度限り使用 / 再利用時の cascade revocation を実装（`tasks/done/p0-token-revocation-on-code-reuse.md`、`tasks/done/01-refresh-token.md` 等）。
  - 上記の正しさは **resolver の `markAsUsed` / `findByGrantId` / `revokeByGrantId` のアトミック性**に依存（コード内に契約ドキュメントは部分的）。
- `packages/core/src/auth-transaction.ts`:
  - `AuthTransactionStore.create/get/update/delete` を要求。実装は利用者責務。
- `packages/core/src/signing-key.ts`:
  - `createCachedSigningKeyProvider(base, ttlMs)` のキャッシュ層は core 内にある。基底 `SigningKeyProvider` の障害／部分更新時の挙動は実装依存。
- sample 実装（`packages/sample/src/oidc-provider/store.ts`）は Cloudflare D1 / KV 前提。アトミック性は D1（SQLite）に依存。

## 5. 現在の実装との差分

満たしていること:

- 主要 resolver の I/F は型として定義済み、各メソッドの「期待する動作」は JSDoc / 関数コメントに散在する形で記述あり。
- 既存タスクで「ストア依存のリスク」は個別に触れられている（例: `refresh-token-rotation-replay-grace.md` で並行リクエストの問題）。

不足／曖昧:

- 🟡 **横断的な resolver 契約ドキュメント無し**: 利用者は各 resolver のコメントを断片的に読む必要があり、「何が原子的でないと仕様違反になるか」が一覧化されていない。
- 🟡 **CAS / アトミック書き込みの要求**: `markAsUsed`（authorization code）、`rotate`（refresh token）、`update`（auth-transaction）等は **CAS 必須**だが、それが利用者向け契約として明示されていない。KV のような eventually-consistent ストアを安易に使うとセキュリティ要件を満たさない。
- 🟡 **TTL とクリーンアップ**: 認可コード（5 分推奨）、refresh token、auth-transaction の TTL を利用者が誤設定するとリプレイ攻撃面が広がる。`tasks/p2-auth-code-ttl-configurable.md` は TTL 設定面を扱うが、**「TTL 設定の最低値・推奨値の根拠」**が一箇所にまとまっていない。
- 🟡 **障害時のフェイルクローズ**: resolver が例外を投げた場合、core は fail-closed（拒否側に倒す）で動くか、fail-open（許可側に倒す）でないかが利用者にとって自明でない。誤実装で fail-open を作るリスクがある。
- 🟡 **冪等性とリトライ**: クライアントが Token Endpoint を二重送信した場合（ネットワーク再送）、resolver/store の状態がどう振る舞うか（`refresh-token-rotation-replay-grace.md` で grace 提案があるが、契約レベルでは不明示）。
- 🟡 **SigningKey rotation の TTL**: `createCachedSigningKeyProvider(base, ttlMs)` の TTL を長くしすぎると JWKS が古いまま新 token が出る逆転状態が出る。逆に短くすると secret store に負荷がかかる。利用者の推奨設定が無い。

## 6. 改善・追加を検討する理由

価値:

- OSS の最大のハマりどころは「OSS 自体は正しいが、利用者の resolver/store 実装でセキュリティを壊す」パターン。契約を一箇所に集約すれば、コードレビュー・PR・利用者の自己レビューで参照しやすくなる。
- ターゲット層（PoC → 本番移行を見据える開発者）は、ストア選定（KV vs D1 vs Postgres）を比較したい。契約が言語化されていれば「KV では再利用検知が成立しない」と判断できる。
- 既存タスクの「個別改善」を網羅する meta-doc として機能。

導入難易度:

- 🟢 **コード変更不要、ドキュメント中心**で実現できる。
- 🟡 **型コメント補強**: 任意で `ClientResolver` 等の JSDoc に「契約」をリンクする小さな改善を入れると更に良い。

実装しない場合:

- 利用者が KV を採用して再利用検知が race-condition で機能しない、cascade revocation が落ちる、等のシナリオが出る。攻撃面が広がる。

## 7. 実装方針の候補

### 方針A（本ファイルに契約を集約）

- 本ファイル内に **resolver/store ごとの契約表**を作る:

  | I/F | メソッド | 必要保証 | フェイル方針 | TTL 推奨 |
  |---|---|---|---|---|
  | `AuthorizationCodeResolver` | `markAsUsed(code)` | atomic CAS、used=true への状態遷移は一度だけ成功 | 例外時は fail-closed | 5 分以内 |
  | `AuthorizationCodeResolver` / `RefreshTokenResolver` | `revoke*(...)` | **物理削除ではなく used=true へのアトミックな状態更新**。再利用検知時の `revokeTokensByGrantId`（OAuth 2.1 §4.1.2 / §4.3.1 SHOULD）を発火させるため、最低でも元 TTL（RT は absolute lifetime 相当）の間は find/resolve が used:true を返し続ける | 例外時は fail-closed。delete 実装は cascade が黙って無効化される契約違反 | code: 元 TTL、RT: absolute lifetime |
  | `RefreshTokenResolver` | `rotate(oldId, newId)` | atomic、old を used+new を active に同一トランザクションで反映 | 例外時は fail-closed、cascade 適用 | 利用者ポリシー（30〜90 日） |
  | `AuthTransactionStore` | `update(id, patch)` | atomic CAS、ロスト・アップデート防止 | 例外時は authorize 全体を中断 | 認可フロー最大時間（数分） |
  | `SessionResolver` | `getSession()` | 強整合性、または `auth_time` ベースで成立する範囲 | 例外時は `interaction_required` | アプリケーション依存 |
  | `SigningKeyProvider` | `getSigningKey()` | 直近の active key を返す | 例外時は server_error | キャッシュ TTL は数分推奨 |

- ストア選定ガイドも追加（KV: NG / D1 NG/OK の理由 / Postgres OK 等）。
- core 内のコメントから本ドキュメントへ「参照」リンクを付ける。

### 方針B（型シグネチャに契約コメントを追加）

- `packages/core/src/*.ts` の resolver 型に「@contract」JSDoc を追加し、本ファイルへリンク。
- 利用者の IDE で型ヒントが出る。
- コード変更小規模、PR で固定しやすい。

### 方針C（リファレンス実装 / 適合性テスト）

- core に「resolver 契約適合性テストキット」を追加（`packages/core/src/testing/resolver-conformance.ts`）。
- 利用者は自分の resolver 実装に対してこのキットを走らせれば、契約違反の有無を自動チェックできる。

判断材料:

- 方針 A は即時かつ低コストで最大効用。
- 方針 B は方針 A の延長で IDE 体験を上げる。一緒にやるのが理想。
- 方針 C は OSS 体験として非常に強いが、テストキットの API 設計コストが大きい。中長期投資。

## 8. タスク案

- [ ] 方針 A / B / C をどこまで採るかを人間が判断
- [ ] 方針 A 採用時:
  - [ ] 本ファイルに「resolver/store 契約表」「フェイルモード」「ストア選定ガイド」を表で固定（このファイルが最終形）
  - [ ] `study-material/RELEASE-v0.x-scope.md` に本ファイルへの参照を追加（責務の境界を補強）
- [ ] 方針 B 採用時:
  - [ ] `ClientResolver` / `AuthorizationCodeResolver` / `RefreshTokenResolver` / `AuthTransactionStore` / `SessionResolver` / `SigningKeyProvider` の各 I/F に「`@contract`」JSDoc を追加し本ファイルへリンク
- [ ] 方針 C 採用時:
  - [ ] `packages/core/src/testing/resolver-conformance.ts` の API 設計（黒箱テスト I/F、与えるストア → 期待プロパティ）
  - [ ] sample / CLI テンプレ向けに「自分の store がこのテストにパスするか」サンプルを追加
- [ ] 既存 `tasks/p2-auth-code-ttl-configurable.md` / `tasks/p1-refresh-token-absolute-lifetime.md` 等に本ファイルへの参照を追加（重複説明回避）

## 期限切れ／used エントリの回収責務（store eviction contract）

生成 OP のインメモリ store（`samples/*/oidc-provider/store.ts`、一次ソースは `packages/cli/src/frameworks/hono/templates.ts`）における期限切れエントリの回収責務を以下に固定する。詳細・背景は `study-material/done/store-expired-entry-eviction-and-ttl.md` を参照。

- **下限（保持しなければならない窓）**: 認可コード／リフレッシュトークンは、**absolute lifetime（`expiresAt`）まで** `used=true` でも保持し続けること。これは認可コード／rotated RT の再利用検知（`revokeTokensByGrantId` / `revokeByGrantId` のカスケード）を発火させるために必要（OAuth 2.1 §4.1.2 / §4.3.1, RFC 9700 §4.5 / §4.14）。回収判定に `used` フラグを使ってはならない。
- **上限（回収してよい時点）**: `expiresAt <= now` を超えたエントリは回収してよい。`AuthorizationCodeStore.get` / `InMemoryTransactionStore.get` に加え、`AccessTokenStore.get` / `RefreshTokenStore.get` も read 時に遅延回収する（RFC 6819 §5.1.5.3 / RFC 9700 §4.14: 保持トークンは最小・短命に保つ）。
- **正しさと運用の分離**: 期限切れトークンの**受理拒否**は core 検証層（`userinfo.ts` の `expiresAt` 判定等）で保証されており、store の回収は正しさではなく**保持量（メモリ・露出窓）の上限**を与えるもの。
- 外部 KV/Redis/DynamoDB 等を resolver/store の backing に使う場合は、それぞれのネイティブ TTL 失効に上記の「下限＝カスケード窓」を満たす値を設定すること。

> 注（本タスクのスコープ）: 上記のうち token store（access/refresh）の遅延回収と本契約節を実装した。session 系 store（`AuthSessionInfo` / `BrowserSessionInfo` への `expiresAt` 付与と回収）は発行箇所（`login.ts` 等）の寿命設計を伴うため、別タスクの follow-up とする。
