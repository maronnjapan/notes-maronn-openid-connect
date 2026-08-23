# Refresh Token のローテーション時に「元の認可付与スコープ」を保持し、scope 縮小を恒久化しない

## ステータス

🟡 Major（仕様準拠・相互運用性・UX）/ 未着手

## 1. このトピックで確認したいこと

Refresh Token grant で **scope を縮小して要求**したとき、ローテーション後に保存される
**新しい Refresh Token のスコープが「縮小後 scope」になっている**点を確認する。

現状の挙動だと、一度でも `scope` を縮めて refresh すると、その縮小後 scope が**新 RT の上限スコープ**として固定され、
以降の refresh で**元の認可付与スコープまで戻せない（恒久的に grant が痩せる）**。

RFC 6749 §6 は「要求 scope は**元々付与された（originally granted）** scope を超えてはならない」と規定しており、
比較の基準点は「直前の縮小要求」ではなく「**最初の認可付与**」である。
本トピックでは、ローテーション後の RT に保持すべきスコープが
**(A) 元の認可付与スコープ**なのか **(B) 今回の縮小後スコープ**なのかを設計判断するための材料を整理する。

### 既存の関連ファイルとの差分（重複回避）

- `tasks/p1-refresh-scope-offline-access-rotation.md`:
  scope 縮小で `offline_access` を落としたときに**新 RT を発行するか否か（rotation の可否）**を扱う。
  → 本ファイルは「発行する新 RT に**どのスコープを保存するか**（元 grant か縮小後か）」という**別論点**。
  両者は隣接するが、前者は「RT を出すかどうか」、本ファイルは「出す RT のスコープ上限」を扱う。
- `study-material/scope-handling-validation-and-granted-scope.md`:
  scope の検証・未知 scope・付与 scope 通知（RFC 6749 §3.3）を扱う。
  → 本ファイルは **refresh 時の scope 上限の基準点（originally granted の解釈）**に絞る。
- `study-material/refresh-token-rotation-replay-grace.md` /
  `study-material/refresh-token-public-client-rotation-enforcement.md`:
  ローテーションの**再利用検知・public client 強制**を扱う。スコープの保持基準は扱っていない。

## 2. 関連する仕様・基準

- **RFC 6749 §6 Refreshing an Access Token（`scope` パラメータ）**
  - 規範文（逐語）:
    > scope OPTIONAL. The scope of the access request as described by Section 3.3.
    > The requested scope MUST NOT include any scope not originally granted by the resource owner,
    > and if omitted is treated as equal to the scope originally granted by the resource owner.
  - ポイント: 基準は「**originally granted**（最初に付与された scope）」。
    「直前の refresh で縮小した scope」ではない。
    省略時も「originally granted」と等しいとみなす、と明記されている。
  - したがって、縮小要求は**そのとき発行するアクセストークン/ID Token の権限を狭める**ものであって、
    **付与（grant）そのものを恒久的に縮める**ことは規定されていない。
- **OAuth 2.1（draft-ietf-oauth-v2-1）Refreshing an Access Token**
  - RFC 6749 §6 を踏襲。scope 縮小可・拡大不可。基準点は元の付与。
- **OIDC Core 1.0 §12 / §12.1**
  - refresh で再発行する ID Token のクレームは scope に応じてフィルタする（§5.4）。
  - 本リポジトリは「縮小後 scope に応じて ID Token クレームを絞る」を既に実装済み（`filterClaimsByScope`）。
  - 本トピックは「**RT に保存する scope 上限**」の話で、ID Token クレームフィルタとは別レイヤ。

要点（事実と判断の区別）:

- **事実**: RFC 6749 §6 は scope 上限の基準を「originally granted」と定義している。
- **事実**: 現状の実装はローテーション後 RT に「縮小後 scope」を保存するため、基準点が「直前要求」に置き換わる。
- **判断**: §6 の文言に厳密に従うなら、RT には「元の付与 scope」を保持し、
  各 refresh では「元の付与 scope 以下」への縮小だけを許すのが整合的。
  （ただし「縮小を恒久化したい」というセキュリティ方針を取る OP も実在するため、§7 で両論を整理する。）

## 3. 参照資料

- RFC 6749 §6 Refreshing an Access Token:
  https://datatracker.ietf.org/doc/html/rfc6749#section-6
- RFC 6749 §3.3 Access Token Scope:
  https://datatracker.ietf.org/doc/html/rfc6749#section-3.3
- OAuth 2.1（最新 draft）Refreshing an Access Token:
  https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1
- OIDC Core 1.0 §12 Using Refresh Tokens:
  https://openid.net/specs/openid-connect-core-1_0.html#RefreshTokens
- 隣接タスク（重複回避）: `tasks/p1-refresh-scope-offline-access-rotation.md`

> ⚠️ 注記: 本環境からは rfc-editor.org / datatracker / openid.net への直接アクセスが 403 で不可だった。
> §2 の RFC 6749 §6 逐語は記載者の知識に基づく（記憶上は正確）が、
> 最終的には一次資料での再確認を §8 のタスクに含めた。

## 4. 現在の実装確認

### 縮小 scope の決定（core）

- `packages/core/src/token-request.ts` `validateTokenRequest()`:
  - refresh_token grant で `params.scope` が与えられた場合、
    `requestedScopes ⊆ refreshTokenInfo.scope` を検証し、`effectiveScope = uniqueRequestedScopes` とする。
  - `params.scope` 省略時は `effectiveScope = refreshTokenInfo.scope`（その RT が持つ scope）。
  - 返す `ValidatedRefreshTokenRequest.scope = effectiveScope`。
  - **比較対象は `refreshTokenInfo.scope`**（＝その時点の RT のスコープ）であり、
    元の認可付与スコープを別に保持していない。

### ローテーション後 RT への保存（sample / CLI）

- `packages/sample/src/oidc-provider/routes/token.ts`（CLI テンプレ `templates.ts` も同型）:
  ```ts
  await refreshTokenStore.set(tokenResponse.refresh_token, {
    subject,
    clientId: validatedRequest.clientId,
    scope: validatedRequest.scope,   // ← effectiveScope（縮小後）を保存
    ...
  });
  ```
  - 新 RT には **`validatedRequest.scope`（＝縮小後 scope）** が保存される。
  - 次回 refresh では、この新 RT の `scope`（縮小後）が `refreshTokenInfo.scope` として上限になる。

### 帰結

- `openid email profile offline_access` で発行された RT を、
  一度 `scope=openid offline_access` で refresh すると、
  新 RT の scope は `openid offline_access` に**固定**され、
  以降 `profile` / `email` を**二度と再取得できない**（`invalid_scope: Requested scope exceeds original grant` になる）。
- これは RFC 6749 §6 の「originally granted を基準にする」という文言と乖離している可能性が高い。

## 5. 現在の実装との差分

満たしていること:

- 🟢 scope 拡大の拒否（`requestedScopes ⊆ 現 RT scope`）は実装済み。少なくとも「現 RT scope」を超える拡大は防げている。
- 🟢 縮小要求自体は受理できる（その回の AT/ID Token は縮小される）。
- 🟢 ID Token クレームは縮小後 scope に揃える（§5.4）。

不足／曖昧：

- 🟡 **基準点が §6 と乖離**: 上限の基準が「元の認可付与スコープ」ではなく「直前 RT のスコープ」になっている。
  縮小が**ローテーションを跨いで恒久化**する。
- 🟡 **元 grant scope の保存場所が無い**: `RefreshTokenInfo` は「その RT が表す現在 scope」しか持たず、
  「元の認可付与で承認された最大 scope」を別に保持していない。再拡大の判定材料が存在しない。
- 🟡 **相互運用性**: 「縮小しても次回フル scope で取り直せる」前提のクライアント（Google など主要 IdP の挙動に倣う実装）が、
  本 OP では取り直せず想定外の `invalid_scope` を踏む。
- 🟡 **方針未確定**: 「恒久縮小（最小権限を維持したい）」を**意図的に**選ぶ OP もある。
  どちらを既定にするか、設定可能にするかは設計判断が要る（§7）。

## 6. 改善・追加を検討する理由

- **なぜ価値があるか**: refresh 時の scope 縮小は「一時的にトークンの権限を絞りたい」典型ユースケース。
  恒久縮小だと「絞ったら戻せない」ため、クライアントが scope 縮小を怖くて使えない／想定外エラーを踏む。
- **Basic OP として必要か / 拡張か**:
  - Basic OP の必須テストではない（scope 縮小の往復は Basic OP のコア検証対象ではない）。
  - ただし RFC 6749 §6 の**文言準拠（Fidelity）**と**相互運用性**の観点で価値が高い。
- **導入しやすさ**:
  - 🟡 `RefreshTokenInfo` に「元の認可付与スコープ（grantedScope）」を 1 フィールド足し、
    `originalIssuedAt` と同様に**ローテーションを跨いで引き継ぐ**だけで実現できる。
    既存の grantId / originalIssuedAt 引き継ぎ機構と同じパターンで接続できる。
- **既存実装との接続**:
  - `originalIssuedAt`（OAuth 2.1 §6.1 の absolute lifetime 引き継ぎ）と**完全に同じ伝播経路**に
    `grantedScope` を相乗りさせられる。`ValidatedRefreshTokenRequest` に `grantedScope` を足し、
    検証時の上限比較を `effectiveScope ⊆ grantedScope` に変える。
- **利用者メリット**: クライアントが「今回は最小 scope、次回フル scope」を安全に行える。主要 IdP の挙動と揃う。
- **実装しない場合のリスク**: scope 縮小が罠になる（戻せない）。§6 文言と乖離したまま。
  Conformance を「拡張プロファイル」まで広げた際に問題化しうる。

## 7. 実装方針の候補

> 最終判断は人間が行う。**既定をどちらにするかは方針判断**であり、AI 側で確定しない。

### 方針A（§6 準拠: 元 grant scope を保持し再拡大可能にする）— 仕様文言に最も忠実

- `RefreshTokenInfo` / `ValidatedRefreshTokenRequest` に `grantedScope: string[]`（元の認可付与スコープ）を追加。
- authorization_code grant で初回 RT を作るとき `grantedScope = 認可コードの scope`。
- refresh grant では `grantedScope` を**そのまま引き継ぐ**（`originalIssuedAt` と同様）。
- `validateTokenRequest` の上限比較を `refreshTokenInfo.scope` → `refreshTokenInfo.grantedScope` に変更。
- 新 RT には `grantedScope`（不変）を保持。`scope`（今回の effectiveScope）は AT/ID Token 発行用に使う。
- メリット: §6 文言に忠実。縮小→再拡大が可能。
- 注意: 「縮小したのに次回フル scope を取れる」ことが**意図せぬ権限復活**と見なされる運用もある（方針 B と要トレードオフ）。

### 方針B（恒久縮小を維持: 現状踏襲、ただし意図を明文化）

- 現状どおり新 RT に縮小後 scope を保存し、**ローテーションで grant が痩せる**ことを仕様化・ドキュメント化。
- 「最小権限を維持する」というセキュリティ方針として正当化できる。
- メリット: 実装変更ほぼ不要。権限が増える方向の事故が起きない。
- 注意: §6 文言（originally granted 基準）とは乖離。クライアント互換性で不利。

### 方針C（設定可能化）

- `RefreshScopePolicy: 'preserve-original' | 'shrink-permanently'` を設定で選べるようにし、既定を方針 A に。
- メリット: 利用者が要件に合わせて選べる（OSS 検証ツールとしての柔軟性）。
- 注意: 設定面・テスト面のコストが増える。`offline_access` rotation タスクとの整合も要確認。

判断材料:

- 「Fidelity（§6 文言準拠）と相互運用性」を最優先 → 方針 A。
- 「最小権限・権限復活を絶対に避ける」運用前提 → 方針 B。
- OSS 検証ツールとして両方試させたい → 方針 C（既定 A）。
- いずれにせよ **`tasks/p1-refresh-scope-offline-access-rotation.md` と同じ「scope 縮小をどう扱うか」レイヤ**なので、
  両タスクは**一緒に設計・実装**するのが整合的（`grantedScope` を導入すれば offline_access rotation 判定も
  「元 grant に offline_access があったか」で判定でき、両課題を同時に解ける）。

## 8. タスク案

- [ ] RFC 6749 §6 / OAuth 2.1 の `scope` 規範文を一次資料で逐語再確認し、本ファイルの引用を確定
- [ ] 方針 A / B / C のどれを既定にするかを人間が判断（`offline_access` rotation タスクと合わせて決める）
- [ ] 方針 A（または C の既定）採用時:
  - [ ] `RefreshTokenInfo` に `grantedScope: string[]`（元の認可付与スコープ）を追加
  - [ ] `ValidatedRefreshTokenRequest` に `grantedScope` を追加し、refresh 時に引き継ぐ（`originalIssuedAt` と同経路）
  - [ ] `validateTokenRequest` の scope 上限比較を `grantedScope` 基準に変更
  - [ ] sample / CLI テンプレで新 RT 保存時に `grantedScope` を引き継ぐ
  - [ ] `tasks/p1-refresh-scope-offline-access-rotation.md` の rotation 判定を `grantedScope.includes('offline_access')` に寄せて統合
- [ ] テスト要件:
  - [ ] `openid email profile offline_access` で発行 → `scope=openid offline_access` で refresh → 縮小 AT/ID Token が返る
  - [ ] 上記の続きで `scope=openid email profile offline_access` で再 refresh → **元 grant まで再拡大できる**（方針 A）
  - [ ] 元 grant を超える scope は依然 `invalid_scope` で拒否される
  - [ ] `scope` 省略時は元 grant scope と等価（§6）になる
  - [ ] 方針 B を選ぶ場合は逆に「再拡大が拒否される」ことをテストで固定し、ドキュメントに恒久縮小と明記
- [ ] 完了条件: `pnpm --filter @maronn-openid-connect/core test` および cli テストがパスすること
