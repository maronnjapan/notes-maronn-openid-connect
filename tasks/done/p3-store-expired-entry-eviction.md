# [P3] サンプル store の期限切れエントリ遅延回収と回収戦略の契約明文化

## ステータス

🟢 Low / 未着手

## 背景

CLI 生成プロバイダ（`samples/hono/src/oidc-provider/store.ts`）のインメモリ store は、期限切れエントリの回収にばらつきがある。`AuthorizationCodeStore` / `InMemoryTransactionStore` は `get` 時に期限切れを遅延回収するが、`AccessTokenStore` / `RefreshTokenStore` は `get` が素通しで期限切れを回収せず、`AuthSessionStore` / `BrowserSessionStore` / `ConsentStore` は寿命フィールドすら持たない。

その結果、明示 `revoke` されない限り**期限切れ・放置エントリが永久にメモリに残り**、長時間稼働の OP でメモリが単調増加する（時間をかけた可用性低下）。期限切れトークンの**受理**は core 検証層（`userinfo.ts` の `expiresAt` 判定）で防がれているため**正しさの問題は無い**が、保持し続けること自体が漏洩時の露出窓を広げ、運用上の角になる。

検討の詳細・背景は `study-material/done/store-expired-entry-eviction-and-ttl.md` を参照。本タスクは方針が確定している**方針A（遅延回収の統一）＋方針D（契約ドキュメント追記）**のみを切り出す。set API の TTL ヒント化（方針C）や定期掃除フック（方針B）は環境依存・API 形状変更を伴うため本タスクには含めない。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`（store テンプレートの修正元。CLAUDE.md: `samples/*/oidc-provider` は CLI 生成物なので CLI 側を修正）
- `samples/hono/src/oidc-provider/store.ts`（テンプレートと同期）
- `packages/cli/src/__tests__/hono-generator.test.ts`
- `study-material/resolver-and-store-contract.md`（回収戦略の契約節を追記）

## 仕様参照

- OAuth 2.1 §4.1.2 / §10.5: 認可コードは短命・ワンタイム。
- RFC 9700 §4.14: rotated refresh token の追跡は absolute lifetime まで（永続ではない）。
- RFC 6819 §5.1.5.3: 保持トークンは最小・短命に保つ。
- Cloudflare KV / Redis / DynamoDB のネイティブ TTL 失効（参照は study-material 側に記載）。

## 現状の実装

`samples/hono/src/oidc-provider/store.ts`:

- `AccessTokenStore.get`（81–83 行）: `return this.tokens.get(token)` のみ。`expiresAt` を見ず、期限切れを回収しない。
- `RefreshTokenStore.get`（117–119 行）: 同様に素通し。`consume`（121–126 行）は `used=true` にするのみ。
- `AuthSessionStore` / `BrowserSessionStore`（`AuthSessionInfo` / `BrowserSessionInfo`）: `expiresAt` を持たず、遅延回収も無い。
- 対比: `AuthorizationCodeStore.get`（47–56 行）と `InMemoryTransactionStore.get`（17–25 行）は期限切れを遅延 `delete` する実装が既にある。

## 修正方針

- [ ] `AccessTokenStore.get` に遅延回収を追加する（`AuthorizationCodeStore.get` と同形）:
  ```ts
  get(token: string): AccessTokenInfo | undefined {
    const entry = this.tokens.get(token);
    if (!entry) return undefined;
    const now = Math.floor(Date.now() / 1000);
    if (entry.expiresAt <= now) {
      this.tokens.delete(token);
      return undefined;
    }
    return entry;
  }
  ```
- [ ] `RefreshTokenStore.get` に同様の遅延回収を追加する。ただし**再利用カスケード検知（`used=true` のエントリは元 TTL/absolute lifetime まで残す）を壊さないこと**。回収は `expiresAt <= now`（絶対期限超過）でのみ行い、`used` だが期限内のエントリは残す。
- [ ] `AuthSessionInfo` / `BrowserSessionInfo` に `expiresAt`（Unix epoch 秒）を追加し、`get` で遅延回収する。auth-session は短命（数分）、browser-session はセッション寿命（既定例: 数時間〜）を設定。発行箇所（`login.ts` ほか）で `expiresAt` を埋める。
- [ ] 上記は CLI テンプレート（`templates.ts`）を一次ソースとして修正し、`samples/hono` を生成 or 同期で一致させる。

## テスト要件

- [ ] 期限切れアクセストークンを `get` すると `undefined` を返し、内部 Map からも削除される
- [ ] 期限切れリフレッシュトークンを `get` すると `undefined` を返し削除される
- [ ] **used=true かつ期限内**のリフレッシュトークンは `get` で残り続け、再利用検知（`revokeByGrantId`）が引き続き発火する（カスケード回帰）
- [ ] 期限切れ auth-session / browser-session が `get` で回収される
- [ ] `hono-generator.test.ts`: 生成コードに上記回収ロジックが含まれることを固定
- [ ] `study-material/resolver-and-store-contract.md` に「期限切れ／used エントリの回収責務（下限＝カスケード窓、上限＝回収可）」節が追記され、`store-expired-entry-eviction-and-ttl.md` と相互参照されている

## 完了条件

`pnpm --filter @maronn-openid-connect/cli test` がパスし、生成プロバイダ（`samples/hono`）のテスト・ビルドが通ること。回収追加後も既存の再利用カスケード／トークン失効テストが回帰しないこと。
