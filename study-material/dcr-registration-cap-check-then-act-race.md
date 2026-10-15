# DCR 登録総数上限（maxRegisteredClients）の check-then-act 競合

## ステータス

🟡 検討中（ストア契約の設計判断が未決のためタスク化しない）

## 1. このトピックで確認したいこと

Dynamic Client Registration（RFC 7591、PR #131）の登録総数上限 `maxRegisteredClients` が、同時リクエスト下でも守られるかを確認する。
生成される登録ルートは「件数を数えてから保存する」という 2 段階の非アトミックな手順で上限を検査しており、検査と保存のあいだに別リクエストが割り込める。

## 2. 関連する仕様・基準

- **RFC 7591 §5（セキュリティ考慮）**：オープン登録はリソース枯渇の面を開くため、無制限の登録を防ぐ運用上の対策を求める。上限値の厳密さまでは規定しない
- 本リポジトリの実装判断：`tasks/experimental/done/dynamic-client-registration/specification.md` の「リスクと対策」の節。総数上限（既定 100）とボディ長上限を DoS 対策として置き、超過は 429 の固定文言で返す

関連する既存トピック：ストア更新の原子性は `study-material/ciba-store-update-copy-semantics-lost-update.md`（CIBA ストアの lost update）と `tasks/p2-device-ciba-approval-scope-atomic-update.md`（承認処理の原子化）でも扱っている。
本ファイルは、それらと対象ストアと操作（登録件数の検査と保存）が異なるため独立して扱う。

## 3. 参照資料

- RFC 7591 §5 — https://www.rfc-editor.org/rfc/rfc7591#section-5
- 実装時のリスク整理：`tasks/experimental/done/dynamic-client-registration/specification.md`

## 4. 現在の実装確認

生成される登録ルート（`packages/cli/src/frameworks/hono/templates.ts` の `registerRouteTemplate`、4089-4095 行付近。nextjs 版は `packages/cli/src/frameworks/nextjs/endpoints.ts` の `nextJsRegisterRouteTemplate` に同じ手順がある）は、次の順で上限を検査する。

```typescript
if ((await store.count()) >= config.maxRegisteredClients) {
  return c.json(
    { error: 'too_many_registrations', error_description: 'registration limit reached' },
    429,
  );
}
await store.save(client);
```

ストア契約（生成される `store.ts` の `DynamicallyRegisteredClientStore`）は `get` / `save` / `count` の 3 操作で、「上限以下なら保存する」をひとまとめに行う操作を持たない。

## 5. 現在の実装との差分

満たしていること：

- 逐次アクセスでは上限どおりに 429 を返す。E2E（`tests/e2e/specs/dynamic-client-registration.spec.ts`）も逐次の上限到達を検証している

不足している可能性があること：

- `count()` と `save()` が別々の await であるため、単一プロセスの in-memory ストアでも、残り枠 1 の状態へ同時に届いた複数リクエストが全員検査を通過し、上限を超えて保存され得る
- 超過幅は同時リクエスト数に比例する。複数インスタンスが 1 つの永続ストア（`--db` 構成）を共有する場合は、インスタンス数 × 同時数まで広がる

確認が必要なこと：

- この上限は在庫上限（DoS 対策の天井）であり、数件の超過が実害になる性質の値ではない。厳密に守る価値と、ストア契約を変える費用の釣り合いは判断が要る

## 6. 改善・追加を検討する理由

上限は RFC 7591 §5 の DoS 対策として置いた値であり、超過しても直ちに脆弱になるわけではない。
一方で、`store.ts` はユーザーが永続実装へ書き換える前提の契約なので、「この契約では上限が厳密でない」ことが文書化されていないと、書き換えた実装でも同じ競合を引き継ぐ。
同リポジトリでは、静的クライアント登録の同時実行で行が重複する問題を修正した前例（コミット 9dd14ca）があり、同時実行の扱いを揃えておく価値はある。

## 7. 実装方針の候補

- **方針A**：ストア契約へ「上限以下なら保存して true、超過なら保存せず false」を返す操作（例：`saveIfUnder(client, limit)`）を追加し、検査と保存をストア実装の責務にする。in-memory 実装は同期的に判定でき、DB 実装も条件付き INSERT で表現できる。契約の破壊的変更になる
- **方針B**：契約は変えず、生成ルート側で直列化する（プロセス内のミューテックス）。単一プロセスでは閉じるが、複数インスタンス構成では閉じない
- **方針C**：現状維持とし、ストア契約の JSDoc と README に「上限は同時実行下で厳密ではない（天井としての目安）」と明記する

上限の性質（厳密な保証ではなく DoS の天井）を踏まえると方針Cで足りる可能性があるが、契約を変えるなら experimental のうちが安い。
最終判断は人間が行う。

## 8. タスク案

- 方針決定後にタスク化する。方針A の場合：契約変更、in-memory 実装、各フレームワークの生成ルート、E2E（同時登録で上限を超えないこと）までが 1 タスクの粒度
- 方針C の場合：`store.ts` の JSDoc と README への追記のみで、ドキュメントタスクとして切る
