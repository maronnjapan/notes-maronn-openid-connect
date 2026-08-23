# Refresh Token アイドルタイムアウトが生成 OP から到達不能（`lastUsedAt` 未永続化 / config 未配線）

## 1. このトピックで確認したいこと

core には Refresh Token のアイドル（無操作）タイムアウト判定 `validateRefreshTokenIdleTimeout` が実装済みだが、**CLI が生成する OP からはこの機能に到達できない**。

- 生成テンプレートは `validateRefreshTokenIdleTimeout(refreshTokenInfo, undefined)` と**タイムアウト値を undefined 固定**で呼んでいる。
- 生成テンプレートの `refreshTokenStore.set(...)` は `lastUsedAt` を**一切保存しない**。
- 結果、仮に利用者が第2引数へ秒数を書き換えても `lastUsedAt === undefined` のため判定は常にスキップされる（**二重に無効化**されている）。

`tasks/done/p3-refresh-token-idle-inactivity-timeout.md` は完了扱いだが、その修正方針に含まれていた「テンプレートの `store.set` に `lastUsedAt: issuedAt` を保存」「`refreshTokenIdleTimeout` を config 化」は**未反映**である。本ファイルはこの**実装済み core 機能と生成コードの断絶**という差分に限定して扱う。

**既存ファイルとの切り分け（重複回避）**

| 論点 | 扱っているファイル |
|---|---|
| アイドルタイムアウトを**そもそも導入すべきか**の検討・仕様根拠 | `study-material/done/refresh-token-idle-inactivity-timeout.md` |
| core への判定追加そのもの | `tasks/done/p3-refresh-token-idle-inactivity-timeout.md` |
| Introspection 側の `active` 判定との不整合 | `tasks/p3-introspection-refresh-token-idle-timeout-active-consistency.md` |
| 絶対寿命（`originalIssuedAt` ベース） | `tasks/done/p1-refresh-token-absolute-lifetime.md` |
| ローテーション再利用検知の猶予 | `study-material/refresh-token-rotation-replay-grace.md` |

アイドルタイムアウトの意義・RFC 上の位置づけは上記で説明済みのため繰り返さない。ここでは「**機能が到達不能である**」という実装事実と、その扱い方だけを論じる。

## 2. 関連する仕様・基準（このトピック固有の差分）

### 2.1 アイドルタイムアウトは RFC の MUST ではない

RFC 9700（OAuth 2.0 Security BCP）§4.14 は Refresh Token について、**sender-constrained にするか、rotation を行うこと**を要求し、加えて有効期限を限定することを推奨する。アイドル（無操作）タイムアウトという語自体は RFC の規定ではなく、商用 IdaaS（Auth0 の Inactivity Lifetime 等）で一般的な運用機構である。

したがって本トピックは「仕様違反である」という話ではない。論点は次の2点に絞られる。

1. **実装済みだが到達不能な API を公開していること**（利用者への誤ったシグナル）
2. **`lastUsedAt` を保存しない store 契約が、後から機能を有効化する余地を潰していること**

### 2.2 OSS ライブラリとしての「広告の正直さ」

本リポジトリは Discovery の広告honesty（`study-material/done/discovery-grant-types-supported-implicit-default.md` 等）や resolver 契約の明文化（`study-material/resolver-and-store-contract.md`）を一貫した方針として採ってきた。同じ基準を API 表面にも適用するなら、`RefreshTokenInfo.lastUsedAt` / `TokenRequestContext.refreshTokenIdleTimeoutSeconds` / `validateRefreshTokenIdleTimeout` という3つの公開シンボルが**生成 OP では機能しない**ことは、契約として明示するか、配線して機能させるかのいずれかが必要になる。

### 2.3 Basic OP との関係

Basic OP certification profile はアイドルタイムアウトを要求しない。Basic OP の必須機能一覧は `study-material/basic-op-requirements-baseline.md` を参照（ここでは繰り返さない）。本トピックは**運用機能の品質**の問題である。

## 3. 参照資料

- RFC 9700 (BCP 240) OAuth 2.0 Security Best Current Practice §4.14 Refresh Token Protection
  — https://www.rfc-editor.org/rfc/rfc9700
  （sender-constrained または rotation、および有効期限の限定）
- OAuth 2.1 draft §4.3.1 Refresh Token Grant / §6.1 Refresh Token Lifetime
  — https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1
- RFC 6749 §6 Refreshing an Access Token
  — https://www.rfc-editor.org/rfc/rfc6749#section-6
- 本リポジトリ内: `tasks/done/p3-refresh-token-idle-inactivity-timeout.md`（修正方針に `lastUsedAt` 保存が含まれている）、`study-material/done/refresh-token-idle-inactivity-timeout.md`（導入検討）

## 4. 現在の実装確認

### 4.1 core: 判定ロジックは存在する

`packages/core/src/refresh-token-grant.ts:112-128`

```ts
export function validateRefreshTokenIdleTimeout(
  refreshTokenInfo: RefreshTokenInfo,
  idleTimeoutSeconds: number | undefined,
  currentTime: number = Math.floor(Date.now() / 1000),
): void {
  if (
    idleTimeoutSeconds !== undefined &&
    idleTimeoutSeconds > 0 &&
    refreshTokenInfo.lastUsedAt !== undefined &&      // ← ここで必ず undefined になる
    currentTime - refreshTokenInfo.lastUsedAt > idleTimeoutSeconds
  ) {
    throw new TokenError(TokenErrorCode.InvalidGrant, 'Refresh token expired due to inactivity');
  }
}
```

`RefreshTokenInfo.lastUsedAt`（`packages/core/src/token-request.ts:195-201`）の doc は「**ローテーション時に「今」へ更新する（スライディング）**」と契約を明記している。

合成 API 側（`validateRefreshTokenGrant`, 214-247 行）は `context.refreshTokenIdleTimeoutSeconds` を読むので、core を直接使う利用者は機能させられる。

### 4.2 生成 OP: タイムアウト値が undefined 固定

`packages/cli/src/frameworks/hono/templates.ts:2154`

```ts
// Optional inactivity policy. Replace undefined with your timeout in seconds
// to enable it, or remove this step if your experiment has no idle lifetime.
validateRefreshTokenIdleTimeout(refreshTokenInfo, undefined);
```

コメントは「undefined を秒数に置き換えれば有効になる」と読めるが、実際には後述の 4.3 により有効化されない。

### 4.3 生成 OP: `lastUsedAt` を保存していない

`packages/cli/src/frameworks/hono/templates.ts:2303` 以降（`refreshTokenPersistenceBlock`）

```ts
await refreshTokenStore.set(tokenResponse.refresh_token, {
  subject,
  clientId: validatedRequest.clientId,
  scope: refreshTokenScope,
  expiresAt: refreshTokenExpiresAt,
  originalIssuedAt,
  used: false,
  grantId: validatedRequest.grantId,
  iat: issuedAt,
  issuer: config.issuer,
  audience: effectiveAudience,
  authTime: rtAuthTime,
  nonce,
  acr: ...,
  amr: ...,
  azp: ...,
});
// ← lastUsedAt が無い
```

リポジトリ全体で確認しても、`packages/cli` および `samples/*` に `lastUsedAt` / `refreshTokenIdleTimeout` という識別子は**1箇所も存在しない**（`packages/core` のみ）。

### 4.4 帰結

- 生成 OP の利用者がコメント通り `validateRefreshTokenIdleTimeout(refreshTokenInfo, 3600)` へ書き換えても、**何も起きない**（`lastUsedAt` が常に undefined のため早期 return）。
- 利用者は「アイドルタイムアウトを試したが効かない」という形でしか気付けず、原因が store 側にあることは core の型定義を読むまで分からない。
- `ProviderConfig` にも `refreshTokenIdleTimeoutSeconds` 相当の設定項目が無い（`refreshTokenAbsoluteLifetime` のみ存在, `templates.ts:300-320` 付近）。

## 5. 現在の実装との差分

### 満たしていること

- core 側の判定ロジック・境界条件（`>` で境界値は有効）・既定 OFF の後方互換は実装済みでテスト済み。
- 絶対寿命（`originalIssuedAt` + `refreshTokenAbsoluteLifetime`）は生成 OP まで正しく配線されており、スライディング延長も起きない。
- `RefreshTokenInfo` の型契約と doc は明確。

### 不足している可能性があること

- 生成テンプレートの `refreshTokenStore.set` に `lastUsedAt`（= `issuedAt`）が無い。
- `ProviderConfig` にアイドルタイムアウト秒の設定項目が無い。
- 生成コードのコメントが「undefined を置き換えれば有効」と読める一方、実際には有効にならない（**コメントが実装と乖離**）。
- `samples/*/conformance.test.ts` に「アイドルタイムアウトが（既定で）無効であること」「有効化した場合に失効すること」の契約が無い。

### 実装はあるが仕様上の確認が必要なこと

- `lastUsedAt` の意味を「新 RT を発行した時刻」とするか「旧 RT を使った時刻」とするか。ローテーション前提なら実質同じ瞬間だが、rotation を行わない構成（同じ RT を返す実装に改造した場合）では差が出る。core の doc は「直近にトークン化された時刻」としており、`issuedAt` を入れる解釈で整合する。
- Introspection 側の `isRefreshTokenActive` はアイドル判定を行わないため、有効化すると Token Endpoint と Introspection で `active` の解釈がずれる（既存タスク `tasks/p3-introspection-refresh-token-idle-timeout-active-consistency.md` の前提が現実化する）。**本トピックを実装するなら、そのタスクとセットで扱う必要がある**。

### セキュリティ上、改善した方がよいこと

- 直接の脆弱性ではない。ただし「セキュリティ機能が有効だと誤認される API」は運用上のリスクであり、`lastUsedAt` を保存しておくこと自体は失効判断の材料を増やす（監査・侵害時の調査にも有用）。

### 相互運用性の観点で改善した方がよいこと

- 主要 IdaaS はアイドルタイムアウトを標準機能として持つため、移行検証時に「このライブラリでは再現できない」ことになる。PoC → IdaaS 移行というユースケース上、**再現できることに価値がある**。

### Basic OP として提供する上で確認すべきこと

- Basic OP の合否には影響しない。ただし conformance.test.ts が「生成 OP の想定挙動」を固定する契約テストである以上、**アイドル失効が既定で起きないこと**は契約として固定しておくのが望ましい。

## 6. 改善・追加を検討する理由

- **価値**: 「core にあるのに生成コードで動かない」状態は、CLI 生成コードを入口とする本リポジトリの設計思想（`core` はロジック層、利用者は生成コードを改造する）と直接衝突する。利用者が改造して試せることが差別化軸の一つ（Speed）である以上、改造で到達できない機能は価値を失う。
- **Basic OP 必須か拡張か**: 拡張（運用機能）。
- **導入しやすさ**: 極めて容易。`lastUsedAt: issuedAt` の1行追加と、`ProviderConfig` への任意フィールド追加、テンプレート呼び出し箇所の差し替えで済む。破壊的変更は無い（`lastUsedAt` は optional、既定は未設定＝無効）。
- **既存実装との接続**: `refreshTokenAbsoluteLifetime` と同じ場所・同じ流儀で `refreshTokenIdleTimeoutSeconds` を足せる。`issuedAt` は既にトークン発行ブロックで確定している。
- **メリット**: 利用者はアイドル失効の挙動を実機で比較検証できる。運用者は「最終利用時刻」を保持でき、侵害調査に使える。
- **実装しない場合に残るリスク**: 到達不能な公開 API が残り、ドキュメントとコメントが実装と食い違ったままになる。少なくとも「生成 OP では無効」であることを明示しなければ、利用者を誤らせる。

## 7. 実装方針の候補（最終判断は人間が行う）

### 方針A: 完全に配線する（推奨候補）

1. `ProviderConfig` に `refreshTokenIdleTimeoutSeconds?: number`（既定 `undefined` = 無効）を追加。
2. テンプレートの `refreshTokenStore.set` に `lastUsedAt: issuedAt` を追加。
3. テンプレートの呼び出しを `validateRefreshTokenIdleTimeout(refreshTokenInfo, config.refreshTokenIdleTimeoutSeconds)` に変更。
4. コメントを「config で秒数を設定すると有効になる。既定は無効」に修正。
5. 修正点は `packages/cli/src/frameworks/hono/templates.ts` の 1 箇所で足りる（`web-standard/templates.ts` が `configTemplate` / `tokenRouteTemplate` を再エクスポートし、express / fastify / nextjs はいずれも `webGeneratedFiles` 経由で同じ生成物を使うため）。
6. `samples/*/conformance.test.ts` に既定 OFF の契約テストを追加。

- 長所: core の意図どおり動く。追加コストが小さい。
- 短所: Introspection との整合（別タスク）を放置すると `active` の解釈がずれる。

### 方針B: `lastUsedAt` の保存だけ先に入れる

config 配線は行わず、`lastUsedAt: issuedAt` の保存のみ追加する。利用者がテンプレートを手で書き換えれば機能する状態にする。

- 長所: 変更が最小。既定挙動は完全に不変。
- 短所: config が無いので「生成コードを直接編集する」前提が残る（それ自体は本リポジトリの想定利用法とは整合する）。

### 方針C: 生成 OP からは提供しないと明記する

core の機能は残しつつ、生成テンプレートのコメントを「この生成 OP はアイドルタイムアウトを配線していない。使う場合は store に `lastUsedAt` を保存する改造が必要」と正確に書き換え、`resolver-and-store-contract.md` にも記載する。

- 長所: 実装変更が最小。誤解だけを解消できる。
- 短所: 機能は使えないまま。

### 方針D: core から `lastUsedAt` / アイドル判定を削除する

到達不能な API を消して表面を小さくする。

- 長所: API 表面の正直さは最大化される。
- 短所: 既に done 扱いのタスクの成果を捨てることになり、Introspection 側タスクの前提も消える。**非推奨**。

### 判断材料

- コスト対効果では方針A が最も良い（追加行数は10行未満、テストは既存の refresh テストに追記できる）。
- ただし方針A を採るなら `tasks/p3-introspection-refresh-token-idle-timeout-active-consistency.md` を**同時にスケジュールする**判断が要る。切り離すと Token / Introspection の不整合が実際に発生する。
- v0.x のリリースを優先するなら方針B または C で止め、方針A を後続に回す選択も合理的。

## 8. タスク案

- [ ] 現状（`lastUsedAt` 未保存によりアイドル判定が到達不能）を回帰テストで固定する
- [ ] 方針A〜C のいずれを採るかを決定する（人間判断）
- [ ] 方針A/B: `packages/cli/src/frameworks/hono/templates.ts` の `refreshTokenStore.set` に `lastUsedAt: issuedAt` を追加する（全フレームワークが同テンプレートを共有する）
- [ ] 方針A: `ProviderConfig` に `refreshTokenIdleTimeoutSeconds?: number` を追加し、テンプレートの `validateRefreshTokenIdleTimeout` 呼び出しへ配線する
- [ ] 生成コードのコメントを実装と一致させる（「undefined を置き換えれば有効」の記述を修正）
- [ ] `samples/*/conformance.test.ts`（生成元は `packages/cli`）に既定 OFF の契約テストを追加する
- [ ] 方針A を採る場合、`tasks/p3-introspection-refresh-token-idle-timeout-active-consistency.md` の実施タイミングを決める
- [ ] `study-material/resolver-and-store-contract.md` に `lastUsedAt` の保存契約を追記する
