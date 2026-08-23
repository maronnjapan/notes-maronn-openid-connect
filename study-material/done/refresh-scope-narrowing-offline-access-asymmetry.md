# Refresh 時の scope 縮小における `offline_access` の非対称性（他 scope は恒久縮小・`offline_access` だけ次回 refresh で復活する）

## 1. タイトル

`refresh_token` grant で `scope` を縮小したとき、**縮小結果が scope ごとに異なる**（`profile` / `email` などは以後永久に戻らないのに、`offline_access` だけは次回の refresh レスポンスに黙って復活する）挙動の確認と、その解消方針の整理。

## 2. このトピックで確認したいこと

生成 OP は refresh 時の scope 縮小に対して、次の 2 つの機構を**同時に**持っている。

1. `ValidatedRefreshTokenRequest.hadOfflineAccess` — 「元 grant が `offline_access` を持っていたか」を運び、rotation 可否を縮小後 scope から切り離す。
2. 永続化する新 refresh token の `scope` に `offline_access` を**書き戻す** — 同じく次回以降の rotation を継続させるため。

この 2 つは同じ目的（rotation の継続）を果たすが、(2) は副作用として **`offline_access` を「次回の refresh で要求されたことになる scope」へ昇格させてしまう**。結果、クライアントから見た scope 縮小の意味が scope ごとに変わる。

本ファイルで確認したいのは以下。

- この非対称が実際に発生するか（コード上の経路を確定させる）
- 仕様上どこまでが許容範囲で、どこからが相互運用上の問題か
- rotation 継続という目的を維持したまま、非対称を消す実装方針は何か

### 既存ファイルとの差分（重複回避）

このトピックは以下と隣接するが、**扱う論点が異なる**。同じ説明は繰り返さない。

- `study-material/refresh-token-grant-scope-preservation.md`
  → 「縮小後 scope を新 RT に保存すべきか、元 grant scope を保存すべきか」という**基準点（originally granted の解釈）**の設計判断。方針 A / B の両論を整理済み。
  → **本ファイルは、その方針判断とは独立に存在する「`offline_access` だけ扱いが違う」という内部不整合**に限定する。方針 A（元 grant 保持）を採れば本件は自動的に消えるが、方針 B（恒久縮小）を採る場合は本件が残る。つまり本件は「方針 B を選んだ場合に別途決着が必要な残タスク」である。
- `tasks/done/p1-refresh-scope-offline-access-rotation.md`
  → 縮小で `offline_access` を落としたときに**新 RT を発行するか（rotation の可否）**。本ファイルは「発行する RT に何を保存し、その結果**次回のレスポンス scope に何が出るか**」を扱う。
- `study-material/offline-access-scope-grant-policy.md`
  → 認可エンドポイントでの `offline_access` 付与条件（OIDC Core §11）。token エンドポイント側の話は扱っていない。
- `study-material/scope-handling-validation-and-granted-scope.md`
  → 未知 scope の扱いと granted scope 通知（RFC 6749 §3.3）の一般論。

## 3. 関連する仕様・基準（このトピック固有の差分）

Basic OP の定義および共通仕様索引は `study-material/basic-op-requirement-traceability.md` を参照。ここでは本件に直接効く条文だけを引く。

### 3.1 RFC 6749 §6 — refresh 時の `scope`

逐語:

> scope
>     OPTIONAL.  The scope of the access request as described by Section 3.3.  The requested scope MUST NOT include any scope not originally granted by the resource owner, and if omitted is treated as equal to the scope originally granted by the resource owner.

ポイントは 2 つ。

- 上限は「**originally granted**」。
- **省略時は「originally granted と等しいものとして扱う」**。

つまり RFC 6749 §6 が想定する状態機械は「grant に紐づく不変の scope 集合が 1 つあり、各リクエストがその部分集合を要求する」という形である。**「前回要求した scope が次の上限になる」とは書かれていない。**

現実装は「新 RT に保存された scope」を上限かつ省略時の既定値として使う。方針 B（恒久縮小）はこの点で §6 の文言から意図的に外れる設計判断であり、その是非は `refresh-token-grant-scope-preservation.md` の担当範囲。**本ファイルが問題にするのは、その「保存された scope」が `offline_access` についてだけ縮小要求を無視する点**である。

### 3.2 RFC 6749 §3.3 / OAuth 2.1 §3.2.3 — 発行 scope の通知

逐語（RFC 6749 §3.3）:

> If the issued access token scope is different from the one requested by the client, the authorization server MUST include the "scope" response parameter to inform the client of the actual scope granted.

現実装は常に `scope` を返すため、通知そのものは満たしている。ただし本件では「**クライアントが一度も要求していない `offline_access` が、要求していないリクエストの発行 scope に入って返る**」という状態が起きる。RFC 6749 §3.3 は「requested と異なるなら通知せよ」であって「requested を超えてはならない」とは言っていないため、これ単体は MUST 違反ではない。しかし §6 の「省略時は originally granted」と組み合わせると、返っている値は

- originally granted（`openid profile email offline_access`）でもなく、
- 直前に要求された scope（`openid`）でもなく、
- **その中間の第 3 の値（`openid offline_access`）**

になる。仕様上どの基準にも対応しない値がクライアントへ返る点が、相互運用性上の実害になりうる。

### 3.3 OIDC Core 1.0 §11 — `offline_access` の性質

`offline_access` は「refresh token を得るための scope」であり、UserInfo のクレーム集合には対応しない（`SCOPE_CLAIMS_MAP` にも無い）。したがって `offline_access` がアクセストークンの `scope` に入っても、**OP 内部で追加の権限を意味しない**。実害が出るのは主に OP の外側（リソースサーバのポリシー、監査ログ、クライアント側の scope 差分検知）である。

なお、認可エンドポイントでの付与条件（`prompt=consent` 必須）は `study-material/offline-access-scope-grant-policy.md` の担当。

## 4. 参照資料

- **RFC 6749 (The OAuth 2.0 Authorization Framework)**
  - §3.3 Access Token Scope（発行 scope の通知）— https://datatracker.ietf.org/doc/html/rfc6749#section-3.3
  - §6 Refreshing an Access Token（`scope` の上限と省略時の既定）— https://datatracker.ietf.org/doc/html/rfc6749#section-6
- **OAuth 2.1 (draft-ietf-oauth-v2-1)** Refreshing an Access Token — https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1
- **OpenID Connect Core 1.0** §11 Offline Access — https://openid.net/specs/openid-connect-core-1_0.html#OfflineAccess
- 本リポジトリ内（重複説明を避けるための参照先）
  - `study-material/refresh-token-grant-scope-preservation.md`（縮小の基準点。方針 A / B）
  - `tasks/done/p1-refresh-scope-offline-access-rotation.md`（rotation 可否）
  - `study-material/offline-access-scope-grant-policy.md`（認可時の付与条件）

## 5. 現在の実装確認

### 5.1 core: 縮小の検証と `hadOfflineAccess` の生成

`packages/core/src/refresh-token-grant.ts`

```ts
// L136-165: 要求 scope の検証。省略時は「保存された scope」をそのまま返す。
export function validateRefreshTokenScope(
  requestedScope: string | undefined,
  originalScope: string[],
): string[] {
  if (requestedScope === undefined) {
    return originalScope;          // ← 省略時の既定値は「保存された scope」
  }
  ...
  // originalScope のサブセットであることだけを検証する
}

// L170-192: rotation 可否を縮小後 scope から切り離すためのフラグ
export function buildValidatedRefreshTokenRequest(...) {
  return {
    ...
    scope: effectiveScope,                                    // 縮小後
    hadOfflineAccess: refreshTokenInfo.scope.includes('offline_access'), // 元 grant 由来
  };
}
```

core 単体では非対称は生じない。core は「縮小後 scope」と「元 grant が offline だったか」を**分けて**返しており、設計として正しい。

### 5.2 生成 OP: 永続化時の書き戻し（非対称の発生源）

`packages/cli/src/frameworks/hono/templates.ts` の `refreshTokenPersistenceBlock`
→ 生成物 `samples/hono-cloudflare/src/oidc-provider/routes/token.ts:629-635`

```ts
// RFC 6749 §6: 縮小後 scope（validatedRequest.scope）から offline_access が落ちても、
// grant が offline_access を持つ限り次回以降の rotation を継続できるよう、永続化する
// refresh token の scope には offline_access を保持する。
const refreshTokenScope =
  grantHasOfflineAccess && !validatedRequest.scope.includes('offline_access')
    ? [...validatedRequest.scope, 'offline_access']
    : validatedRequest.scope;
await refreshTokenStore.set(tokenResponse.refresh_token, {
  ...
  scope: refreshTokenScope,   // ← ここに offline_access が書き戻される
});
```

一方 rotation 可否の判定は、同じファイルの `grantHasOfflineAccess`（`token.ts:476-479`）が `validatedRequest.hadOfflineAccess` で既に行っている。**つまり書き戻しは rotation 継続のためには不要**であり、`validateRefreshTokenScope` の「省略時の既定値」経路を通じて次回リクエストへ漏れる。

### 5.3 再現シナリオ（コード上で決定的にたどれる）

前提: 認可時の付与 scope = `openid profile email offline_access`、RT1 に同じ scope が保存されている。

| # | リクエスト | `validatedRequest.scope`（= AT / ID Token / レスポンス scope） | 新 RT に保存される scope |
|---|---|---|---|
| 1 | `grant_type=refresh_token`（`scope` 省略） | `openid profile email offline_access` | 同左 |
| 2 | `grant_type=refresh_token&scope=openid` | `openid` | **`openid offline_access`** |
| 3 | `grant_type=refresh_token`（`scope` 省略） | **`openid offline_access`** | `openid offline_access` |

- `profile` / `email` は #2 の縮小以降、**二度と要求できない**（`validateRefreshTokenScope` が `invalid_scope` で拒否する）。
- `offline_access` は #2 で明示的に外したにもかかわらず、#3 のレスポンス `scope` とアクセストークンの `scope` に**クライアントが要求しないまま復活する**。

## 6. 現在の実装との差分

### 満たしていること

- `validateRefreshTokenScope` は要求 scope が保存 scope のサブセットであることを検証しており、**scope の拡大は起きない**（RFC 6749 §6 の MUST NOT は守られている）。
- `hadOfflineAccess` により、縮小で `offline_access` を落としても rotation が止まらない（`tasks/done/p1-refresh-scope-offline-access-rotation.md` の意図どおり）。
- 発行 scope は常にレスポンスへ返る（RFC 6749 §3.3）。

### 不足している可能性があること

- 縮小の意味が scope ごとに異なる。クライアントから見て「`scope=openid` で絞った」の効果が、次のリクエストで部分的に巻き戻る。仕様条文で説明できる挙動ではない（§3.2 参照）。
- rotation 継続という要件と、「grant に保存する scope 集合」という概念が **1 つのフィールドに多重化**している。責務が分離されていないため、片方を直すともう片方が壊れる構造になっている。

### 実装はあるが仕様上の確認が必要なこと

- 「省略時 = originally granted」（RFC 6749 §6）を、現実装は「省略時 = 前回保存された scope」と読み替えている。方針 B を採る場合、この読み替えを README / 生成コードのコメントに**明示的な仕様逸脱として**書くべきか。

### セキュリティ上、改善した方がよいこと

- 直接的な権限昇格ではない（`offline_access` は OP 内部で追加権限を持たず、rotation は元々継続する設計）。ただし**最小権限の原則の観点では、クライアントが明示的に落とした scope が黙って戻るのは望ましくない**。特にアクセストークンの `scope` クレームを見て認可判断するリソースサーバがある場合、OP 側の意図しない差分になる。
- 監査ログ上、「要求 scope」と「発行 scope」の差分が説明できない形で発生する（`study-material/audit-logging-and-observability.md` の観点）。

### 相互運用性の観点で改善した方がよいこと

- クライアントライブラリの中には、トークンレスポンスの `scope` が要求と異なる場合に警告・再認可を促すものがある。要求していない `offline_access` が返ると、誤検知の原因になる。
- 「一度縮めたら戻せない」という方針 B の説明が `offline_access` については成立しないため、ドキュメントで一貫した説明ができない。

### Basic OP として提供する上で確認すべきこと

- Basic OP certification のテストプラン（`oidcc-basic-certification-test-plan`）に、refresh 時の scope 縮小を検証する module は含まれていない（`tasks/p3-basic-op-conformance-module-list-confirmation.md` で一覧を確定中）。したがって**認定合否には影響しない**。本件は認定要件ではなく、ライブラリとしての一貫性・利用者の予測可能性の問題として扱う。

## 7. 改善・追加を検討する理由

- **なぜ入れる価値があるのか**: 本リポジトリのコンセプトは「仕様を素早く忠実に検証できること」である。scope 縮小のような基本操作の挙動が scope ごとに変わると、利用者は「仕様がそうなのか、このライブラリの都合なのか」を切り分けられない。検証ツールとしての信頼性に直結する。
- **Basic OP として必要か、拡張として有用か**: **どちらでもない**。Basic OP の必須要件ではなく、拡張機能でもない。「既存実装の内部不整合の解消」に分類される。
- **現在の構成から見て導入しやすいか**: 導入しやすい。原因箇所は生成テンプレートの 1 ブロック（`refreshTokenPersistenceBlock`）と、それが依存する `RefreshTokenInfo` の型定義に閉じている。core 側の `hadOfflineAccess` は既に「rotation 可否を scope から切り離す」ための正しい抽象になっているため、それを永続化側にも延長するだけでよい。
- **既存実装との接続**: `RefreshTokenInfo` に rotation 可否を表す独立フィールドを足し、`buildValidatedRefreshTokenRequest` の `hadOfflineAccess` をそこから読むようにすれば、`scope` フィールドは純粋に「この grant で要求可能な scope 集合」だけを表せる。
- **利用者・開発者・運用者のメリット**: 縮小の効果が scope 横断で一貫する。生成コードのコメントとテストで挙動を固定できるため、利用者が生成コードを改造しても回帰に気づける。
- **実装しない場合に残るリスク**: 方針 B（恒久縮小）を選んだ場合、「一度縮めたら戻せない」という説明が `offline_access` については嘘になる。将来 `offline_access` 以外にも「grant 単位の permission scope」（例: 拡張で導入されうる scope）が増えたとき、同じ書き戻しを増やすことになり不整合が拡大する。

## 8. 実装方針の候補

> **最終判断は人間が行う。以下は判断材料の整理であり、推奨の確定ではない。**

### 方針 1: rotation 可否を `scope` から独立したフィールドへ移す（責務分離）

- `RefreshTokenInfo` に `offlineAccessGranted: boolean`（あるいはより一般に `grantScope: string[]`）を追加する。
- 永続化する `scope` は**縮小後 scope をそのまま**保存し、書き戻しをやめる。
- `buildValidatedRefreshTokenRequest` の `hadOfflineAccess` は新フィールドから読む。
- 効果: 非対称が消える。方針 A / B のどちらを選んでも独立に成立する。
- コスト: `RefreshTokenInfo` の型変更（追加フィールドのため後方互換は保てるが、既存ストアのレコードには値が無いので `?? scope.includes('offline_access')` のフォールバックが要る）。CLI テンプレートと 4 sample の生成物、`conformance.test.ts` の更新が必要。

### 方針 2: `refresh-token-grant-scope-preservation.md` の方針 A を採用し、元 grant scope を保存する

- 新 RT には常に「元の認可付与 scope」を保存する。縮小はそのリクエスト限りの効果になる。
- 効果: RFC 6749 §6 の文言に最も忠実。本件の非対称も同時に消える（`offline_access` を含む全 scope が「戻る」ようになるため一貫する）。
- コスト: セキュリティ方針として「縮めても戻せる」ことを受け入れる必要がある。`refresh-token-grant-scope-preservation.md` の方針判断に従属するため、本ファイル単独では決められない。

### 方針 3: 現状維持 + 明文化のみ

- 書き戻しを残し、「`offline_access` は grant 単位の permission であり、リクエスト単位の scope 縮小の対象外」と README・生成コードのコメント・`conformance.test.ts` で明示する。
- 効果: 変更コストが最小。
- コスト: レスポンス `scope` に要求していない値が入る事実は残る。`offline_access` を「リクエスト単位の scope として扱わない」なら、**そもそもレスポンスの `scope` とアクセストークンの `scope` から `offline_access` を除外する**方が一貫するはずで、その場合は方針 3 も実質的な実装変更になる。

### 方針の直交性

方針 1 は方針 A / B のどちらとも組み合わせ可能。方針 2 は `refresh-token-grant-scope-preservation.md` の決着待ち。**先に方針 1 だけを実施して非対称を消し、基準点の議論は別途続ける**という順序が取りうる（本ファイルのタスク案はこの順序を前提にする）。

## 9. タスク案

- [ ] `RefreshTokenInfo` に rotation 可否を表す独立フィールドを追加し、`scope` への `offline_access` 書き戻しを廃止する（方針 1）
- [ ] `buildValidatedRefreshTokenRequest` の `hadOfflineAccess` を新フィールドから導出し、旧レコード向けフォールバックを入れる
- [ ] `packages/cli` の `refreshTokenPersistenceBlock` を更新し、4 sample の生成物を再生成する
- [ ] `samples/*/conformance.test.ts` に「縮小 → 省略で refresh したとき、縮小後 scope が維持され `offline_access` が復活しない」契約テストを追加する（生成元は `packages/cli` 側を修正すること）
- [ ] `packages/core` に `validateRefreshTokenScope` / `buildValidatedRefreshTokenRequest` の単体テストを追加する
- [ ] `refresh-token-grant-scope-preservation.md` の方針 A / B 判断に、本件が「方針 B を選ぶ場合の必須の追加作業」であることを追記する
