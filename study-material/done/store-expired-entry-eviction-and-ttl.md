# Store の期限切れエントリ回収（eviction）とメモリ肥大 / TTL ヒント API のポータビリティ

## ステータス

- 🟡 Medium / 未着手
- 区分: 運用（可用性 / 長時間稼働）＋ ポータビリティ（KV / Redis などへの素直な移植性）

## 1. このトピックで確認したいこと

OP が発行・保持する短命アーティファクト（認可コード / アクセストークン / リフレッシュトークン / auth-transaction / ブラウザセッション / consent 記録）について、**期限切れエントリがいつ・どのように回収されるか**を確認する。

具体的には次の 2 点を扱う。

1. **メモリ肥大（slow-burn な可用性リスク）**: 期限切れ・使用済みエントリが回収されず、長時間稼働で無制限に積み上がらないか。
2. **TTL ヒントのポータビリティ**: 利用者が in-memory ストアを Cloudflare Workers KV / Redis / DynamoDB などの「ネイティブ TTL 失効」を持つバックエンドに差し替えるとき、core / 生成コードの store API が **失効期限をバックエンドへ渡せる形になっているか**。

> 本トピックは store 契約の「同時実行・冪等性・TTL=セキュリティ」を扱う `study-material/resolver-and-store-contract.md` とは**別の差分**を扱う。あちらは「TTL を誤設定するとリプレイ面が広がる」という**正しさ／セキュリティ契約**が主題。本ファイルは「**期限切れエントリの物理回収**（可用性）」と「**TTL を保存系へ伝播する API 形状**（ポータビリティ）」が主題であり、同じ TTL でも論点が異なる。重複説明は避け、契約面は同ファイルを参照する。
> また、`study-material/done/untrusted-input-payload-size-dos-hardening.md`（1 リクエスト単位のサイズ DoS）、`study-material/rate-limiting-and-brute-force.md`（リクエスト頻度）、`study-material/operational-health-readiness-endpoints.md`（health 判定）とも論点が異なる（こちらは「時間経過でのエントリ蓄積」）。

## 2. 関連する仕様・基準

このトピックは「これを満たさないと Basic OP 認定に落ちる」という**プロトコル準拠要件ではない**。認定テストは外形的なフロー挙動を見るのであって、サーバ内部のメモリ回収戦略は対象外である。よって本トピックは **Basic OP 必須ではなく、運用品質・ポータビリティの改善**として位置づける。

ただし、以下の仕様は「短命アーティファクトには明確な寿命がある」ことを前提にしており、寿命を過ぎたデータを保持し続ける積極的理由は無いことの根拠になる。

- **OAuth 2.1 / RFC 6749 §4.1.2 / §10.5**: 認可コードは短命（short-lived, 推奨上限 10 分程度）かつワンタイム。寿命後は無効。
- **OAuth 2.1 §4.3.1 / RFC 9700（OAuth Security BCP）§4.14**: リフレッシュトークンのローテーションでは、使用済み（rotated）トークンは再利用検知のためにしばらく追跡する必要があるが、これは「absolute lifetime まで」であり永続ではない。
- **RFC 6819（OAuth Threat Model）§5.1.5.3 / §4.4.1.1**: トークン・コードのライフタイムは可能な限り短く保つこと（保持データ量と漏洩時の露出窓を抑える観点）。
- **可用性（一般原則）**: 無制限に増えるインメモリ状態は、長時間稼働するプロセスのメモリ枯渇＝サービス停止（時間をかけた DoS）につながる。

寿命の定義そのものは既存タスク（`tasks/p1-refresh-token-absolute-lifetime.md`、`tasks/p2-auth-code-ttl-configurable.md`、`tasks/done/05-authorization-code-ttl.md` など）で扱い済みであり、本ファイルでは寿命値の議論は繰り返さない。本ファイルの差分は「**定義された寿命を過ぎたエントリを実際に回収するか**」である。

## 3. 参照資料

- OAuth 2.1 Authorization Framework, draft-ietf-oauth-v2-1: §4.1.2（Authorization Response / コード短命）, §4.3.1（Refresh Token Rotation）, §10.5
  - https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1
- RFC 9700 OAuth 2.0 Security Best Current Practice: §4.14（Refresh Token Protection）
  - https://www.rfc-editor.org/rfc/rfc9700
- RFC 6819 OAuth 2.0 Threat Model and Security Considerations: §5.1.5.3（短命トークン）, §4.4.1.1
  - https://www.rfc-editor.org/rfc/rfc6819
- Cloudflare Workers KV — Expiring keys（`expiration` / `expirationTtl` によるネイティブ失効）
  - https://developers.cloudflare.com/kv/api/write-key-value-pairs/#expiring-keys
- Redis — key expiration（`EX` / `PX` / `EXPIRE`）
  - https://redis.io/docs/latest/commands/set/
- DynamoDB — Time to Live (TTL)
  - https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/TTL.html

> どの内容を根拠にしているか: 「コードは短命・ワンタイム」は OAuth 2.1 §4.1.2、「rotated RT は absolute lifetime まで追跡だが永続ではない」は RFC 9700 §4.14、「保持データは最小・短命に」は RFC 6819 §5.1.5.3。KV/Redis/DynamoDB のドキュメントは「set 時に失効期限を渡せばバックエンドが自動回収する」ことの裏付け。

## 4. 現在の実装確認

### サンプル / CLI 生成プロバイダの store（`samples/hono/src/oidc-provider/store.ts`）

各 store はインメモリ `Map` 実装で、期限切れエントリの扱いに**ばらつき**がある。

| store | TTL/期限フィールド | get 時の遅延回収 | バックグラウンド掃除 | set への TTL 引数 |
|---|---|---|---|---|
| `InMemoryTransactionStore` | `expiresAt`（put の `ttlSeconds` で算出） | ✅ あり（`get` で期限切れを `delete`） | ❌ なし | ✅ `put(key, value, ttlSeconds)` |
| `AuthorizationCodeStore` | `info.expiresAt` | ✅ あり（`get` で期限切れを `delete`） | ❌ なし | ❌ `set(code, info)`（TTL 非伝播） |
| `AccessTokenStore` | `info.expiresAt` | ❌ **なし**（`get` は素通しで返す） | ❌ なし | ❌ `set(token, info)` |
| `RefreshTokenStore` | `info.expiresAt` | ❌ **なし**（`get` は素通し） | ❌ なし | ❌ `set(token, info)` |
| `AuthSessionStore` | **期限なし** | ❌ なし | ❌ なし | ❌ `set(transactionId, info)` |
| `BrowserSessionStore` | **期限なし** | ❌ なし | ❌ なし | ❌ `set(sessionId, info)` |
| `ConsentStore` | **期限なし** | ❌ なし | ❌ なし | ❌ `grant(...)` |

具体的な根拠（`samples/hono/src/oidc-provider/store.ts`）:

- `AccessTokenStore.get`（81–83 行）は `return this.tokens.get(token)` のみで、`expiresAt` を見ない。アクセストークンの期限自体は core 側（`packages/core/src/userinfo.ts` の `tokenInfo.expiresAt < now` 判定、354 行付近）で**検証はされる**ので機能的には正しい。ただし**ストアからエントリは消えない**。
- `RefreshTokenStore.get`（117–119 行）も同様に素通し。`consume`（121–126 行）は `used=true` にするだけで、使用済みエントリは absolute lifetime を過ぎても残り続ける。
- `AuthSessionStore` / `BrowserSessionStore` / `ConsentStore` は `expiresAt` フィールドすら持たず、`delete` を明示的に呼ばない限り回収されない。ブラウザセッションは `login.ts` のログイン時に古い session を `delete` してから新規発行するため**ログインのたびに 1 個は消える**が、放置されたセッション（ログアウトせず離脱）は残る。

### core 側 store インターフェース

`AuthorizationCodeResolver` / `RefreshTokenResolver`（`packages/core/src/token-request.ts`）, `AccessTokenResolver`（`packages/core/src/userinfo.ts`）はいずれも `find`/`resolve`/`revoke` を定義するが、**発行時の保存（`set`）は core の責務外**であり、保存・回収戦略は完全に利用者（生成コード）に委ねられている。すなわち「期限切れ回収」を促す型・契約・既定実装は core 側に存在しない。

## 5. 現在の実装との差分

満たしていること:

- ✅ 短命アーティファクトの寿命（`expiresAt` / TTL）は型・発行ロジックで定義済み。
- ✅ 認可コードと auth-transaction は `get` 時に遅延回収される（最も攻撃面が大きいコードは回収される）。
- ✅ アクセストークン／コードの**期限切れ判定**は core 検証層で正しく行われ、期限切れトークンが受理されることはない（＝**正しさの問題は無い**）。
- ✅ ブラウザセッションはログイン時に旧 ID を破棄・再生成する（セッション固定対策も兼ねる）。

不足・改善余地（本トピック固有の差分）:

- 🟡 **`AccessTokenStore` / `RefreshTokenStore` が期限切れを回収しない**: `get` が遅延回収せず、バックグラウンド掃除も無いため、発行されたトークンは（明示 `revoke`/`revokeByGrantId` されない限り）**期限後も永久にメモリに残る**。長時間稼働の OP では単調増加する。
- 🟡 **`AuthSessionStore` / `BrowserSessionStore` / `ConsentStore` に寿命が無い**: 期限フィールドも回収機構も無く、放置セッション・古い consent が無制限に蓄積する。
- 🟡 **set 系 API が TTL を伝播しない（ポータビリティ）**: トークン／コード／セッションの `set` は `expiresAt` を内包する `info` を渡すだけで、**「このエントリは t 秒後に失効する」という TTL を保存系に直接渡す形になっていない**。Cloudflare KV / Redis / DynamoDB はネイティブ TTL 失効を持つため、`set(key, value, { expiresAt })` のような形があれば**利用者が一行で自動回収を効かせられる**が、現状は利用者が `expiresAt` を自前で TTL 換算してバックエンドへ渡す実装を書く必要がある。セッション・consent に至っては `info` に `expiresAt` すら無いため、ネイティブ TTL を効かせる根拠データが渡らない。
- 🟡 **「使用済み（used）エントリの保持下限／上限」が回収観点で未規定**: 再利用カスケード検知（`study-material/done/authorization-code-reuse-cascade-store-semantics.md`）のために used エントリは「元 TTL（コード）／absolute lifetime（RT）まで」保持すべきだが、**その期限を過ぎたら回収してよい／すべき**という上限が回収戦略として書かれていない。下限はカスケード契約側、上限は本トピック側、という整理ができる。

セキュリティ／可用性の観点:

- 期限切れ・使用済みトークンが永続することは、**漏洩時の露出窓（data-at-rest exposure）を不必要に広げる**（`study-material/credential-at-rest-hashing.md` のハッシュ化と相補的だが別軸：あちらは「保存時の形」、本トピックは「保存し続ける期間」）。
- 無制限のメモリ増加は**時間をかけたサービス停止（slow DoS）**になりうる。`study-material/done/untrusted-input-payload-size-dos-hardening.md`（瞬間的な大入力）とは異なる時間軸のリスク。

相互運用性／ポータビリティの観点:

- このライブラリの差別化軸「Portability（Web 標準のみ・どこでも動く）」を踏まえると、**「in-memory → KV/Redis への差し替えが素直にできる store API 形状」**は中核的な価値。TTL を伝播できない set API は、この差し替えの摩擦になる。

## 6. 改善・追加を検討する理由

- **なぜ価値があるか**: 「正しいが、長時間動かすと太る／移植時に TTL を手で計算させられる」というのは、PoC を超えて本番導入を見据える本ライブラリのターゲットユーザーが最初につまずく運用上の角。プロトコル準拠とは別軸で、OSS の使い勝手・信頼性を底上げする。
- **Basic OP 必須か拡張か**: **必須ではない**（認定テスト対象外）。運用品質・ポータビリティの改善。よってリリースブロッカーではなく、`v0.x` の主要フロー安定後に着手する性質。
- **導入しやすさ**: サンプル store は `Map` ベースで小さく、遅延回収（`get` 時チェック）や任意の定期掃除を足すのは局所的。core を変えず生成テンプレ（`packages/cli/src/frameworks/hono/templates.ts`）と `samples/hono` の同期更新で完結できる（CLAUDE.md: `samples/*/oidc-provider` は CLI 生成物なので修正は CLI 側で行う）。
- **既存実装との接続**: トークン／コードには既に `expiresAt` があるので、遅延回収は `get` に 2〜3 行足すだけ。set API の TTL ヒント化も `expiresAt` から算出できる。
- **利用者・運用者のメリット**: in-memory のまま長時間動かしてもメモリが安定する。KV/Redis へ差し替える際、`expirationTtl` / `EX` に渡す値が API 経由で得られる。
- **実装しない場合のリスク**: 長時間稼働でメモリ単調増加 → 再起動運用が前提化。移植時に各利用者が TTL 換算を自前実装 → バグ・不整合（失効しない KV エントリ＝ゾンビトークン）を生む。

## 7. 実装方針の候補

最終判断は人間が行う。判断材料として候補を列挙する。

### 方針A（遅延回収の統一：最小・低リスク）
- `AccessTokenStore.get` / `RefreshTokenStore.get` に「`expiresAt <= now` なら `delete` して `undefined` を返す」遅延回収を追加し、`AuthorizationCodeStore` / `InMemoryTransactionStore` と挙動を揃える。
- `AuthSessionStore` / `BrowserSessionStore` に `expiresAt` を持たせ、同様に遅延回収する（auth-session は短命、browser-session はセッション寿命）。
- 長所: 局所的・後方互換・即効。短所: アクセスされないエントリは残る（純粋なアクセス駆動回収の限界）。

### 方針B（任意の定期掃除フック）
- 各 store に `sweep(now?)` メソッドを足し、利用者が任意の周期（`setInterval` / Cron / Durable Object alarm 等）で呼べるようにする。生成テンプレにコメント付きの呼び出し例を添える。
- 長所: アクセスされないエントリも回収できる。短所: 実行環境依存（Workers では `setInterval` 不可など）。「Web 標準のみ」の建前と、環境別の掃除トリガをどう示すかの整理が要る。

### 方針C（set API の TTL ヒント化：ポータビリティ）
- 生成コードの store `set`/`put` を `set(key, info, { expiresAt })`（または `ttlSeconds`）に統一し、in-memory 実装はそれを使って遅延回収、KV/Redis 実装は `expirationTtl`/`EX` にマッピングする、という**差し替え可能な store インターフェース例**をドキュメント化する。
- `AuthSessionInfo` / `BrowserSessionInfo` に `expiresAt`（または `authTime + maxSessionAge`）を持たせ、TTL の根拠データを揃える。
- 長所: ポータビリティ軸に直接効く。短所: API 形状の変更を伴うため、生成物の互換性影響を見極める必要。

### 方針D（ドキュメントのみ：回収戦略ガイド）
- 実装は変えず、`resolver-and-store-contract.md` に「期限切れ／used エントリの回収責務・推奨戦略（遅延回収＋定期掃除＋KV ネイティブ TTL）」の節を追記し、利用者が自前 store で踏み外さないようにする。
- 長所: 最小コスト。短所: サンプル自身の肥大は直らない。

判断材料:
- 最小で効くのは **方針A**（サンプルの肥大を止める）＋**方針D**（自前 store 利用者向けの指針）。
- ポータビリティ価値を重視するなら **方針C** を中期投資として検討。方針B は実行環境差が大きいので「例示」に留めるのが無難。

## 8. タスク案

- [ ] 方針A: `AccessTokenStore.get` / `RefreshTokenStore.get` に `expiresAt` 遅延回収を追加（`packages/cli` テンプレ → `samples/hono` 同期）
- [ ] 方針A: `AuthSessionStore` / `BrowserSessionStore` に寿命（`expiresAt`）と遅延回収を追加
- [ ] 方針A: 回収後も**再利用カスケード（used 検知）を壊さない**ことを回帰テストで固定（used かつ TTL 内は残す／TTL 超で初めて回収）
- [ ] 方針D: `resolver-and-store-contract.md` に「期限切れ／used エントリ回収戦略」節を追記し本ファイルと相互参照（重複説明回避）
- [ ] （検討のみ）方針C: store `set` の TTL ヒント API 化と KV/Redis マッピング例の是非を人間が判断
- [ ] （検討のみ）方針B: 環境別の定期掃除トリガ（Workers/Node）の例示方針を人間が判断

> 上記のうち、**方針A（サンプル store の期限切れ遅延回収）＋方針D（契約ドキュメント追記）は方針が確定しており低リスクで着手可能**なため `tasks/` にタスク化する。方針B / C は環境依存・API 形状変更を伴うため検討段階に留め、本ファイル（→ done）に判断材料として残す。
