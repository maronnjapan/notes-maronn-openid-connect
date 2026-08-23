# 認可コード／リフレッシュトークン再利用カスケード失効と `revoke*` メソッドの意味論（store 依存フットガン）

## ステータス

🟠 High（セキュリティ正当性 / OSS フットガン）/ 未着手

## 1. このトピックで確認したいこと

OAuth 2.1 は「認可コードまたはリフレッシュトークンが**再利用**されたら、それに紐づく**過去発行トークンをすべて失効**する（SHOULD）」を要求する（カスケード失効）。本リポジトリ core はこれを `revokeTokensByGrantId(grantId)` で実装しているが、その**発火条件が利用者の store 実装の意味論に暗黙的に依存している**。

具体的には、core の `AuthorizationCodeResolver.revokeAuthorizationCode(code)` / `RefreshTokenResolver.revokeRefreshToken(token)` を利用者が「**実際に削除（delete）**」として実装すると、再利用時にカスケード失効が**静かに発火しなくなる**。method 名（`revoke...`）が delete を強く示唆するため、これは典型的なフットガンになっている。

本ファイルでは、

- core API のどの設計がこの暗黙依存を生んでいるか
- なぜ「`revoke*` = mark-used（used=true にして TTL までは引き続き取得可能にする）」でなければ仕様を満たさないか
- TOCTOU（check-then-act）による二重発行の窓
- それを契約・ガードレール・回帰テストでどう塞ぐか

を整理する。

> **重複回避の方針**: store の原子性・CAS・フェイルクローズといった**横断的な store 契約**は `study-material/resolver-and-store-contract.md` が扱う。リフレッシュトークン回転時の誤検知緩和（grace window）は `study-material/refresh-token-rotation-replay-grace.md` が扱う。本ファイルはそれらと重複せず、**「`revoke*` の意味論（delete か mark-used か）が再利用カスケードの発火を左右する」という core API 固有の差分**にのみ絞る。

## 2. 関連する仕様・基準

共通の仕様索引は `study-material/basic-op-requirement-traceability.md` の「3. 関連する仕様・基準」を参照。本トピック固有のポイント:

- **OAuth 2.1 draft §4.1.2（Authorization Code grant）**: 認可コードはワンタイム。コードが2回使われた場合、AS は当該リクエストを拒否し、かつ「そのコードに対して既に発行されたすべてのトークンを失効すべき（SHOULD）」。これは攻撃者がコードを傍受して正規ユーザーより先に交換した／後から再生した場合に、発行済みトークンを無効化して被害を限定するための措置。
- **OAuth 2.1 draft §4.3.1（Refresh Token rotation）**: リフレッシュトークン回転を行う AS は、すでに使用済みのリフレッシュトークンが再提示されたら「そのリフレッシュトークンと、それを基に発行されたすべてのアクセストークンを失効すべき（SHOULD）」。
- **OAuth 2.0 Security BCP（RFC 9700）§4.13 / §4.14**: 認可コード・リフレッシュトークンのリプレイ検知と、検知時の grant 全体失効（automatic revocation of the entire token family）を推奨。
- **OIDC Core 1.0 §3.1.3.2**: Token Request 処理において、AS はコードの重複検出を行う責務を負う。

これらはいずれも「**再利用が検知できること**」を暗黙の前提とする。再利用の検知には「一度使ったコード／トークンの記録が、少なくとも本来の TTL の間は AS から参照可能であり、かつ `used` 状態が見えること」が必要になる。記録を即時削除すると、再提示は「used」ではなく「not found」になり、カスケード失効のトリガーを失う。

## 3. 参照資料

- OAuth 2.1 draft（draft-ietf-oauth-v2-1）§4.1.2 / §4.3.1 — https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1
  - §4.1.2: 認可コード再利用時の「previously issued tokens の失効（SHOULD）」
  - §4.3.1: リフレッシュトークン再利用時の「token family 失効（SHOULD）」
- OAuth 2.0 Security Best Current Practice（RFC 9700）— https://datatracker.ietf.org/doc/html/rfc9700
  - §2.2.4 / §4.13.2: refresh token replay 検知と grant 失効
  - §4.14: authorization code replay の緩和
- OpenID Connect Core 1.0 §3.1.3.2（Token Request Validation）— https://openid.net/specs/openid-connect-core-1_0.html#TokenRequestValidation
- 既存 `study-material/resolver-and-store-contract.md`（store の原子性・CAS・TTL の横断契約。本ファイルはその差分）
- 既存 `study-material/refresh-token-rotation-replay-grace.md`（回転時の誤検知緩和。本ファイルと相補）
- 完了タスク `tasks/done/p0-token-revocation-on-code-reuse.md`（コード再利用時失効の初期実装）

## 4. 現在の実装確認

### core 側 API（`packages/core/src/token-request.ts`）

`AuthorizationCodeResolver` インターフェース:

```ts
export interface AuthorizationCodeResolver {
  findAuthorizationCode(code: string): Promise<AuthorizationCodeInfo | null>;
  revokeAuthorizationCode(code: string): Promise<void>;
  revokeTokensByGrantId?(grantId: string): Promise<void>; // optional
}
```

`validateTokenRequest`（authorization_code grant）の再利用検知パス（`token-request.ts:525-533`）:

```ts
if (authCode.used) {
  if (authCodeResolver.revokeTokensByGrantId) {
    await authCodeResolver.revokeTokensByGrantId(authCode.grantId);
  }
  throw new TokenError(TokenErrorCode.InvalidGrant, 'Authorization code has already been used');
}
```

成功パスでは末尾で `revokeAuthorizationCode(code)` を呼ぶ（`token-request.ts:619`）。
リフレッシュトークン側も同型で、`refreshTokenInfo.used` が true のとき `revokeTokensByGrantId` を呼ぶ（`token-request.ts:427-435`）。

### sample 側 store（`packages/sample/src/oidc-provider/`）

- `resolvers.ts:48-50` の `revokeAuthorizationCode` は `authCodeStore.consume(code)` を呼ぶ。
- `store.ts:58-63` の `consume()` は **削除せず `entry.used = true` にするだけ**で、`get()` は TTL 内なら used=true のレコードを返し続ける（`store.ts:47-56`）。
- つまり sample は「`revoke*` = mark-used」として**正しく**実装しており、再提示時に `findAuthorizationCode` が `used:true` を返し、カスケード失効が発火する。
- 一方 `store.ts:65-67` には文字どおり削除する `delete(code)` も存在する。

リフレッシュトークン側も同様（`resolvers.ts:76-77` の `revokeRefreshToken` → `refreshTokenStore.consume` → `used=true`）。

## 5. 現在の実装との差分

満たしていること:

- ✅ core はカスケード失効の発火点（`revokeTokensByGrantId`）を実装済み。
- ✅ sample/CLI 生成物の参照実装は「mark-used」を採用しており、デフォルト経路では再利用カスケードが正しく動く。
- ✅ TTL 内の used レコード参照（`store.ts:get`）も参照実装では成立。

不足・曖昧（本トピック固有の差分）:

- 🟠 **`revoke*` の意味論が型・JSDoc で明文化されていない**: `revokeAuthorizationCode` / `revokeRefreshToken` は名前が「削除」を強く示唆するが、**仕様（カスケード失効）を満たすには「used=true にして TTL までは `find`/`resolve` から取得可能であり続ける」必要がある**。この要件が API ドキュメントに無い。利用者が素直に「delete」を実装すると、再提示が `not found`（`invalid_grant`）にはなるものの、`revokeTokensByGrantId` が**呼ばれず**、発行済みトークンが生き残る（OAuth 2.1 §4.1.2 / §4.3.1 SHOULD 違反）。`store.ts` に `delete()` も同居しているため、混同のリスクは実在する。
- 🟠 **TOCTOU（check-then-act）の窓**: `validateTokenRequest` は `findAuthorizationCode`（used 判定）→ … → `revokeAuthorizationCode`（mark-used）を**非原子的**に行う。同一コードでの並行トークンリクエストが両方とも used=false を読んだ場合、両方が PKCE 検証を通過し**二重発行**しうる。core には原子的な consume プリミティブが無く、原子性は完全に store 実装に委ねられている（`resolver-and-store-contract.md` が CAS の必要性を一般論として指摘済みだが、core API がそれを**強制も補助もしていない**点が差分）。
- 🟡 **「使用済みだが TTL 内」の保持期間が未規定**: used レコードをいつまで保持すべきか（最低でも元コードの TTL ＝ 5分、リフレッシュトークンは absolute lifetime まで）が契約として明示されていない。早すぎる物理削除はカスケード窓を縮める。
- 🟡 **回帰テストの非対称**: sample は consume=mark-used を実装しているが、「`revoke*` を delete にするとカスケードが壊れる」ことを示す**負の回帰テスト**や、「used 後も find が used:true を返す」ことを固定するテストが薄い。

## 6. 改善・追加を検討する理由

- **なぜ価値があるか**: 再利用カスケード失効は、コード傍受・リフレッシュトークン漏洩という現実的な攻撃に対する中核的な被害限定策。これが「利用者の store 実装の一行（delete か mark-used か）」で静かに無効化されるのは、OSS として最も危険な「正しく見えて壊れている」クラスのフットガン。
- **Basic OP 必須か拡張か**: カスケード失効自体は OAuth 2.1 / Security BCP の **SHOULD**であり、Basic OP 認定の必須テスト項目そのものではない。しかし本リポジトリのコンセプト（Fidelity ＝ 仕様忠実 / セキュリティ最優先）からは、**デフォルトで安全側に倒れる契約**を提供することが強く望ましい。よって「拡張機能」ではなく「**契約の明文化＋ガードレール**」として位置づける。
- **導入しやすさ**: core のロジック変更は不要。型 JSDoc の追記・参照実装の据え置き・回帰テスト追加が中心で、後方互換を壊さない。`resolver-and-store-contract.md` の方針B（型に `@contract` を付与）と整合する形で着手できる。
- **既存実装との接続**: `revokeTokensByGrantId` の発火点は既にあるので、その**前提条件（used レコードが find/resolve から見えること）**を契約として固定するだけで接続できる。
- **利用者・運用者のメリット**: store を KV / D1 / Postgres / Redis のどれで実装しても、「revoke* は mark-used、最低保持期間は TTL」という一文があれば、コードレビュー・自己レビューで踏み外しを検出できる。
- **実装しない場合のリスク**: 利用者が `revoke*` を delete 実装にした瞬間、漏洩コード・トークンの再生に対して発行済みトークンが失効されず、攻撃者のセッションが生き延びる。検知も困難（正常系テストは通る）。

## 7. 実装方針の候補

最終判断は人間が行う。判断材料として候補を列挙する。

### 方針A（契約の明文化：JSDoc / ドキュメント）

- `AuthorizationCodeResolver.revokeAuthorizationCode` / `RefreshTokenResolver.revokeRefreshToken` の JSDoc に「これは**物理削除ではなく used 状態への遷移**であり、再利用カスケード失効（`revokeTokensByGrantId`）を発火させるため、`find`/`resolve` は**少なくとも元の TTL の間は used:true のレコードを返し続けなければならない**」と明記する。
- `resolver-and-store-contract.md` の契約表へ本要件を1行追加し相互参照する。
- 低コスト・後方互換・即効性が高い。

### 方針B（命名の是正／別名追加）

- `revokeAuthorizationCode` を `markAuthorizationCodeUsed`（または `consumeAuthorizationCode`）に**改名 or 別名追加**して意味論を名前に込める。
- 破壊的変更になるため、別名を足して旧名を deprecated にする移行が現実的。OSS の利用者影響が大きいので慎重に判断。

### 方針C（core に原子的 consume プリミティブを導入）

- インターフェースに `consumeAuthorizationCode(code): Promise<AuthorizationCodeInfo | { reused: true; grantId } | null>` のような**原子的 compare-and-set**メソッド（任意）を追加し、提供されていれば core はそれを使って TOCTOU 窓を排除する。未提供なら現行の find→revoke にフォールバック。
- TOCTOU を core レベルで塞げるが、API 設計コストと利用者の実装負担が増える。中長期投資。

### 方針D（負の回帰テスト＋参照実装の据え置き）

- sample の consume=mark-used を据え置きつつ、(1)「used 後も find が used:true を返す」(2)「used コード再提示で `revokeTokensByGrantId` が呼ばれる」ことを core/sample の回帰テストで固定する。
- 方針 A と組み合わせると、契約と検証が揃う。

判断材料:

- 最小で効くのは **A + D**（契約明文化＋回帰固定）。後方互換で安全側に倒せる。
- B は UX 改善だが破壊的。C は堅牢だが重い。まず A+D を確定し、B/C は別途検討が無難。

## 8. タスク案

- [ ] 方針 A: `revokeAuthorizationCode` / `revokeRefreshToken` の JSDoc に「mark-used 意味論」「TTL 内は find/resolve から used:true を返し続ける義務」を追記する（`packages/core/src/token-request.ts`）
- [ ] 方針 A: `resolver-and-store-contract.md` の契約表に本要件（`revoke*` = atomic mark-used、最低保持＝元 TTL）を1行追加し相互参照
- [ ] 方針 D: core/sample に回帰テストを追加
  - [ ] used 後も `findAuthorizationCode` / `resolve` が `used:true` を返すこと
  - [ ] used コード／トークンの再提示で `revokeTokensByGrantId(grantId)` が呼ばれること（spy で検証）
  - [ ] `revoke*` を delete 実装にしたフェイク store では再提示が `not found` になり cascade が**呼ばれない**ことを示し、契約違反の症状をテストで可視化する
- [ ] （検討のみ）方針 B（命名是正 / 別名）の是非を人間が判断
- [ ] （検討のみ）方針 C（原子的 consume プリミティブ）で TOCTOU を core レベルに引き上げるかを人間が判断

> 上記のうち、方針 A（JSDoc 契約明文化）＋方針 D（回帰テスト）は**方針が確定しており低リスクで着手可能**なため、`tasks/` にタスク化する。方針 B / C は破壊的変更・API 設計を伴うため検討段階に留め、本ファイル（→ done）に判断材料として残す。
