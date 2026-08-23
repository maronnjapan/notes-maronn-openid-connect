# 同名 `revokeRefreshToken` が 2 つの resolver で相反する契約を持つ（誤用耐性の欠如）

## ステータス

🟠 Major（誤用によるセキュリティ劣化）/ 未着手

## 1. このトピックで確認したいこと

`revokeRefreshToken(token: string): Promise<void>` という**まったく同じ名前・同じシグネチャ**のメソッドが、
core の 2 つの別インターフェースに存在し、しかも**要求される実装が正反対**である。

| インターフェース | 定義場所 | 要求される実装 | 生成 OP の実配線 |
|---|---|---|---|
| `RefreshTokenResolver.revokeRefreshToken` | `packages/core/src/token-request.ts` | **物理削除は禁止。`used=true` への状態遷移必須** | `refreshTokenStore.consume(token)` |
| `RevocationTokenResolvers.revokeRefreshToken` | `packages/core/src/revocation.ts` | 物理削除でよい（RFC 7009 の明示失効） | `refreshTokenStore.revoke(token)` |

TypeScript の構造的型付けでは両者は完全に交換可能であり、片方をもう片方に差し替えても**型エラーにならない**。
本ファイルは、この「同名・同シグネチャ・逆契約」という API 設計上の落とし穴が、
OSS 利用者が生成コードをカスタマイズする際にどのようなセキュリティ劣化を招くかを整理し、
誤用耐性（misuse resistance）を上げる方針の判断材料を作ることを目的とする。

**このファイルで扱わないこと（重複回避）:**

- 「`revoke*` は物理削除ではなく mark-used である」という契約そのものの説明と JSDoc 明記
  → `study-material/done/authorization-code-reuse-cascade-store-semantics.md` および
    `tasks/done/p1-revoke-mark-used-contract-and-reuse-cascade-regression.md` で確定済み。繰り返さない。
- 生成 store の `consume()` / `delete()` の使い分けコメント
  → `tasks/p3-store-consume-delete-comment.md`。**store 側**のコメント補強であり、
    本ファイルの**resolver インターフェース側の同名衝突**とは別軸。
- Revocation で同 grantId の兄弟 Refresh Token へ cascade しない件
  → `study-material/revocation-refresh-token-family-cascade.md`。
- resolver 全般の原子性 / CAS 契約
  → `study-material/resolver-and-store-contract.md`。

## 2. 関連する仕様・基準

共通の Refresh Token / 再利用検知の仕様説明は上記の既存ファイルを参照し、ここでは
**「2 つの失効経路がなぜ異なる意味を持つのか」**に必要な範囲だけ記載する。

### 2.1 ローテーション経路（`RefreshTokenResolver`）

- **OAuth 2.1 draft §4.3.1**: Refresh Token をローテーションする AS は、無効化済み（ローテーション済み）の
  Refresh Token が提示された場合、それを侵害の兆候として扱い、当該 authorization grant に基づいて
  発行されたすべての Refresh Token を失効させる SHOULD。
- **RFC 9700（OAuth 2.0 Security BCP / BCP 240）§4.14**: 同上。AS は再提示された RT が攻撃者由来か
  正当クライアント由来かを識別できないため、active な RT を失効させる。
- この「再提示の検知」が成立するには、**ローテーション済み RT がストアから消えていてはならない**。
  消えていると `resolve()` が `null` を返し、core は `invalid_grant`（not found）を返すだけで、
  `revokeTokensByGrantId()` を**呼ばない**。結果として、漏洩 RT から派生したトークンファミリーが生き残る。

### 2.2 明示失効経路（`RevocationTokenResolvers`）

- **RFC 7009 §2.1**: クライアントが `token` を提示して明示的に失効を要求するエンドポイント。
  AS は当該トークンを無効化する。同じ authorization grant で発行されたアクセストークンも
  失効させる SHOULD。
- **RFC 7009 §2.2**: 失効済み・存在しないトークンに対しても 200 OK を返す。
  → つまり「消えている」ことがそのまま正しい応答（`{active:false}` / 200 OK）につながる。
  この経路では物理削除が**意味論的に正しい**。

**要点**: 同じ「RT を失効する」でも、
ローテーション経路は「**痕跡を残して再提示を検知する**」ことが目的であり、
明示失効経路は「**単に無効化する**」ことが目的である。目的が違うため実装も逆になる。

## 3. 参照資料

- OAuth 2.1 draft（draft-ietf-oauth-v2-1）§4.3.1 Refresh Token（ローテーションと再利用時の失効）
  — https://datatracker.ietf.org/doc/draft-ietf-oauth-v2-1/
- RFC 9700 OAuth 2.0 Security Best Current Practice §4.14 Refresh Token Protection
  — https://www.rfc-editor.org/rfc/rfc9700.html
- RFC 7009 OAuth 2.0 Token Revocation §2.1（失効要求と関連トークンの失効 SHOULD）／§2.2（無効トークンでも 200 OK）
  — https://www.rfc-editor.org/rfc/rfc7009
- 本リポジトリ内の先行トピック（重複説明を避けるための参照先）:
  - `study-material/done/authorization-code-reuse-cascade-store-semantics.md`（mark-used 契約の確定）
  - `tasks/done/p1-revoke-mark-used-contract-and-reuse-cascade-regression.md`（JSDoc 化と回帰テスト）
  - `study-material/resolver-and-store-contract.md`（resolver 契約全般・CAS）

## 4. 現在の実装確認

### 4.1 core 側のインターフェース定義

`packages/core/src/token-request.ts`（`RefreshTokenResolver`）:

```ts
export interface RefreshTokenResolver {
  resolve(token: string): Promise<RefreshTokenInfo | null>;
  /**
   * リフレッシュトークンを「使用済み」にする。**物理削除ではなく used=true への状態遷移
   * として実装しなければならない。**
   * ...（約 20 行の詳細な契約 JSDoc）...
   */
  revokeRefreshToken(token: string): Promise<void>;
  revokeTokensByGrantId?(grantId: string): Promise<void>;
}
```

`packages/core/src/revocation.ts`（`RevocationTokenResolvers`）:

```ts
export interface RevocationTokenResolvers {
  findAccessToken(token: string): Promise<AccessTokenInfo | null>;
  revokeAccessToken(token: string): Promise<void>;
  findRefreshToken?(token: string): Promise<RefreshTokenInfo | null>;
  revokeRefreshToken?(token: string): Promise<void>;   // ← JSDoc なし
  revokeAccessTokensByGrantId?(grantId: string): Promise<void>;
}
```

- 前者には「削除するな」という強い契約 JSDoc が付いている。
- 後者には**コメントが一切無い**。名前とシグネチャは前者と同一。

### 4.2 生成 OP 側の実配線

`samples/hono-cloudflare/src/oidc-provider/resolvers.ts`（生成元は `packages/cli/src/frameworks/hono/templates.ts`）:

```ts
// L77: RefreshTokenResolver 側 → mark-used（正しい）
async revokeRefreshToken(token) {
  await refreshTokenStore.consume(token);
},

// L114: RevocationTokenResolvers 側 → 物理削除（RFC 7009 としては正しい）
async revokeRefreshToken(token) {
  await refreshTokenStore.revoke(token);
},
```

`samples/hono-cloudflare/src/oidc-provider/store.ts`:

```ts
consume(token: string): void { const e = this.tokens.get(token); if (e) { e.used = true; } }
revoke(token: string): void { this.tokens.delete(token); }   // 物理削除
delete(token: string): void { this.tokens.delete(token); }   // 物理削除（revoke と同義）
```

現状の生成コードは**両方とも正しく配線されている**。問題は「正しさが型でもテストでも守られていない」点にある。

## 5. 現在の実装との差分

### 5.1 満たしていること

- 生成される既定コードの配線は仕様どおり（ローテーション＝`consume`、明示失効＝`revoke`）。
- `RefreshTokenResolver.revokeRefreshToken` 側には詳細な契約 JSDoc がある。
- 再利用カスケードの回帰テストは `conformance.test.ts` に存在する
  （`tasks/done/p1-revoke-mark-used-contract-and-reuse-cascade-regression.md`）。

### 5.2 不足している可能性があること

- 🟠 **型で区別できない**: 2 つの `revokeRefreshToken` は構造的に同一型。片方の実装をもう片方へ
  代入・共有しても TypeScript は何も警告しない。CLAUDE.md が想定する「利用者が生成コードを
  改造する」ユースケースで、**「同じ名前が 2 回出てくるから 1 つにまとめよう」というごく自然な
  リファクタリングが、静かに仕様違反を作る**。
- 🟠 **`RevocationTokenResolvers.revokeRefreshToken` に契約コメントが無い**: 利用者はもう一方の
  強い JSDoc（「削除するな」）を読んだ後にこちらを見るため、**こちらでも `consume` を使うべきだと
  誤解する**動機がある。逆向きの誤用（RFC 7009 側で `consume`）は即座に破綻はしないが、
  「失効したはずの RT が used:true として残り続ける」状態になり、store の回収責務が曖昧になる。
- 🟡 **誤用を検知するテストが片側しかない**: 再利用カスケードの回帰テストは
  「ローテーション側が `consume` である」ことを実質的に固定するが、
  「Revocation 側が物理削除である」ことを固定するテストは見当たらない
  （→ 実装確認タスクに含める）。
- 🟡 **`store.revoke()` と `store.delete()` が同一実装で併存**: どちらも `this.tokens.delete(token)`。
  名前が 2 つあることで「使い分けがあるはず」と誤読させるが、実体は同じ。

### 5.3 セキュリティ上の観点

誤用が起きた場合の帰結:

| 誤用パターン | 帰結 | 重大度 |
|---|---|---|
| ローテーション側を物理削除にする | ローテーション済み RT の再提示が `not found` になり、`revokeTokensByGrantId` が発火しない。**漏洩 RT から派生したトークンファミリーが生存**（OAuth 2.1 §4.3.1 / RFC 9700 §4.14 の SHOULD 違反） | 🔴 高 |
| 明示失効側を mark-used にする | 失効済み RT が `used:true` でストアに残る。introspection は `active:false` を返すので直接の情報漏洩は無いが、失効エントリの回収時期が TTL 依存になり、ストア肥大とライフサイクルの不透明化を招く | 🟡 中 |

前者は「**壊れても何も起きない（テストが通ってしまう）**」タイプの劣化であり、
PoC 開発者が本番移行前に気付ける保証がない点が特に問題。

### 5.4 相互運用性の観点

外部から観測される挙動には影響しない（正しく配線されている限り）。相互運用性の論点ではなく、
**API 設計の誤用耐性**の論点である。

### 5.5 Basic OP として確認すべきこと

Refresh Token のローテーション・失効は Basic OP 認定テストの対象外。
本件は Basic OP 認定可否には**影響しない**。ただしリポジトリが掲げる
Fidelity（仕様忠実性）と、OSS 利用者の安全な改造可能性に直結する。

## 6. 改善・追加を検討する理由

- **なぜ価値があるか**: 本リポジトリの利用者は「生成コードを改造しながら仕様を検証する」ことが前提
  （CLAUDE.md「利用者の入口」）。改造の入口にあるのが `resolvers.ts` であり、そこに
  「同名・同型・逆契約」という地雷が置かれている。コメントによる注意喚起は
  `tasks/p3-store-consume-delete-comment.md` で store 側に入る予定だが、
  **resolver 側の同名衝突そのものは解消されない**。
- **Basic OP 必須か拡張か**: どちらでもない。**既存実装の誤用耐性向上（hardening）**。
- **導入しやすさ**: 契約 JSDoc の追記だけなら極めて容易（破壊的変更なし）。
  型レベルの分離（branded type / メソッド改名）は破壊的変更を伴うため、
  リリース方針（`study-material/RELEASE-v0.x-scope.md`）との整合判断が要る。
- **既存実装との接続**: `packages/core/src/revocation.ts` の型定義と、
  `packages/cli` のテンプレート（`resolvers.ts` 生成部）、および各 sample の
  `conformance.test.ts` 生成コードが接続先。
- **利用者のメリット**: 「どちらを実装しているのか」がコードを読んだ瞬間に分かる。
  誤用したときにテストが落ちる。
- **実装しない場合のリスク**: 利用者が善意のリファクタリングで再利用検知を無効化し、
  それに気付かないまま本番相当の検証を進める。ライブラリ側は仕様準拠を主張しているため、
  「ライブラリを使ったのに安全でなかった」という信頼毀損につながりうる。

## 7. 実装方針の候補

> 最終判断は人間が行う。以下は判断材料の整理。

### 方針A: 契約 JSDoc の対称化のみ（非破壊・最小）

`RevocationTokenResolvers.revokeRefreshToken` に、
「**こちらは物理削除でよい。ローテーション経路の `RefreshTokenResolver.revokeRefreshToken` とは
契約が逆であり、実装を共有してはならない**」旨の JSDoc を追加する。
両方の JSDoc から相互参照を張る。

- 利点: 破壊的変更ゼロ。即日入る。既存の JSDoc 方針（`tasks/done/p1-revoke-mark-used-...`）と一貫。
- 欠点: 型では守れない。JSDoc を読まない利用者には効かない。

### 方針B: メソッド名で意味を分離（破壊的）

`RefreshTokenResolver.revokeRefreshToken` を `markRefreshTokenUsed`（または `consumeRefreshToken`）へ改名する。
名前が実際の意味（used 化）を表すようになり、`RevocationTokenResolvers.revokeRefreshToken`（削除）と
名前レベルで区別される。

- 利点: 誤用耐性が最も高い。`study-material/done/authorization-code-reuse-cascade-store-semantics.md` が
  指摘する「`revoke...` という名前が delete を強く示唆するフットガン」を根本から解消する。
- 欠点: **破壊的変更**。`AuthorizationCodeResolver.revokeAuthorizationCode` も同じ理由で
  `markAuthorizationCodeUsed` へ揃えるべきで、影響範囲が広い（core / cli テンプレート / 全 sample /
  全 `conformance.test.ts`）。v0.x のうちに行うか、非推奨エイリアス期間を置くかの判断が要る。

### 方針C: 型で分離（branded type / 名目型）

各メソッドの戻り値や引数に区別用の brand を付け、構造的型付けによる相互代入を型エラーにする。

```ts
// 例（イメージ）
declare const MarkUsed: unique symbol;
type MarkUsedFn = ((token: string) => Promise<void>) & { readonly [MarkUsed]?: true };
```

- 利点: 非破壊のまま（実装側は関数を書くだけ）誤代入だけを弾ける可能性がある。
- 欠点: 単純な関数リテラルを代入する通常の書き方では brand が付かないため、
  **実効性が薄い**（TypeScript の構造的型付けでは optional な brand は素通りする）。
  実効性を出すにはファクトリ関数の強制などが必要で、API が重くなる。**推奨度は低い**。

### 方針D: 契約テストで固定（方針 A / B と併用可）

各 sample の `conformance.test.ts`（生成元は `packages/cli`）に、
「RFC 7009 で失効した RT はその後 `resolve()` から取得できない（物理削除されている）」
という契約テストを追加し、Revocation 側の意味論を固定する。
ローテーション側（used として残る）は既存テストで固定済みのため、これで**両側が対称に固定**される。

- 利点: 誤用したら CI が落ちる。CLAUDE.md の `conformance.test.ts` 方針とも合致。
- 欠点: 単体では名前の紛らわしさは解消しない（A または B との併用が前提）。

### 組み合わせの目安

- 最小コストで効果を出す: **A + D**
- 根本解決を狙う: **B + D**（v0.x のうちに実施できるかがポイント）
- C は実効性が低く、単独採用は非推奨

## 8. タスク案

- [ ] 方針（A / B / C / D、および組み合わせ）を人間が決定する
- [ ] （方針 A）`packages/core/src/revocation.ts` の `RevocationTokenResolvers.revokeRefreshToken` /
      `revokeAccessToken` に契約 JSDoc を追加し、`token-request.ts` 側の JSDoc から相互参照を張る
- [ ] （方針 D・先行可能）`packages/cli` の `conformance.test.ts` 生成コードに
      「Revocation で失効した Refresh Token は以後 `resolve()` から取得できない」契約テストを追加する
- [ ] （方針 D）同テストが `samples/*` 全フレームワークで生成・実行されることを確認する
- [ ] （方針 B 採用時）改名対象（`revokeRefreshToken` / `revokeAuthorizationCode`）と
      非推奨エイリアス期間の要否を `study-material/RELEASE-v0.x-scope.md` と突き合わせて決める
- [ ] （方針 B 採用時）core / `packages/cli` テンプレート / 全 sample / 全 `conformance.test.ts` を更新する
      （生成物を直接編集せず、必ず `packages/cli` を修正する — CLAUDE.md の方針）
- [ ] `study-material/resolver-and-store-contract.md` の resolver 契約表に
      「同名メソッドの逆契約」の行を追記し、本ファイルへ参照を張る

## 関連トピック

- `study-material/done/authorization-code-reuse-cascade-store-semantics.md` — `revoke*` の mark-used 契約（確定済み）。本ファイルは**同名衝突**という別軸。
- `tasks/p3-store-consume-delete-comment.md` — 生成 store 側のコメント補強。本ファイルは resolver インターフェース側。
- `study-material/resolver-and-store-contract.md` — resolver 契約全般・CAS・TTL。
- `study-material/revocation-refresh-token-family-cascade.md` — Revocation の兄弟 RT 到達性。
