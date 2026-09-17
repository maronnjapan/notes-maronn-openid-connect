# CIBA ストアの全レコード update が、コピーを返す永続ストアで lost update を起こす懸念

## 1. このトピックで確認したいこと

CIBA の一覧表示（`GET /ciba`）が行う CSRF トークン回転と、保留数上限（`maxPendingPerSubject`）の判定が、いずれも「読み出し → 書き戻し」の非 atomic な全レコード `update` で実装されている。同梱のインメモリストア（同一オブジェクト参照を返す）では顕在化しないが、README / JSDoc が推奨する置き換え先（Redis / KV / DB。コピーを返すのが普通）では並行操作を巻き戻し得る。ストア契約をどう定めるべきかを確認する。

## 2. 関連する仕様・基準

- CIBA Core 1.0 §11: pending → approved / denied の一方向遷移。
- 実装自身の契約: `packages/experimental/src/ciba/store.ts` の update JSDoc は「認可状態の遷移と consume の単回使用が守られていればセキュリティ特性は保たれる」と条件を置き、`lastPolledAt` / `interval` の read-modify-write を既知の緩みとして記録している。決定（approved / denied）の巻き戻しと上限判定の TOCTOU は記録されていない。

## 3. 参照資料

- `packages/experimental/src/ciba/verification.ts`（`listPendingCibaRequests` が取得レコードの `csrfToken` を書き換えて `store.update(record)` で丸ごと保存）
- `packages/experimental/src/ciba/backchannel-authentication-request.ts`（`maxPendingPerSubject` 判定の list → save）
- `study-material/done/device-ciba-approval-scope-narrowing-atomicity.md`（同じ update の別問題。あちらは生成コードの 2 段階更新、こちらはストア契約の粒度）

## 4. 現在の実装確認

- タブ A が `GET /ciba` で一覧を読み込み（CSRF 回転のため各レコードを update）、タブ B が並行して承認すると、コピーを返すストアでは stale な `status:'pending'` のコピーが approved レコードを上書きし、`authTime` / `grantId` / 決定そのものを消して、承認済みリクエストを再び操作可能な状態へ戻し得る。
- `maxPendingPerSubject` は list → save の間に並行リクエストが挟まると上限をすり抜けられる。

## 5. 現在の実装との差分

- 🟢 同梱インメモリストアでは参照共有により発生しない。
- 🟠 ストアの差し替えは公式に推奨されている運用であり、その途端に一方向遷移の保証が「update の呼び方」に依存する。契約（JSDoc）はこの依存を明示していない。

## 6. 改善・追加を検討する理由

問題の本質は個々のバグではなく、update 契約の粒度（全レコード上書き）と呼び出し側の用途（1 フィールドの回転、状態遷移、カウンタ）が合っていないことにある。契約を細くすれば呼び出し側の正しさが構造的に決まる。ただし公開契約の変更は experimental とはいえ利用者のストア実装に波及するため、変更の形は人間の判断が要る。

## 7. 実装方針の候補（未確定。タスク化しない理由）

- 案 A: 契約に `rotateCsrfToken(authReqId, token)`（pending の場合のみ更新）を追加し、一覧表示から全レコード update を排除する。
- 案 B: `update` の契約に「status が pending のレコードにのみ適用してよい」等の条件を明記し、実装側で条件付き更新を要求する。
- 案 C: 契約は変えず、JSDoc に既知の緩みとして決定巻き戻し・上限 TOCTOU を追記する（`lastPolledAt` と同じ扱い）。
- 保留数上限は save 側での再カウント、またはストア契約への注記で補う。
- どの案を採るかで experimental の公開 API と実装解説の更新範囲が変わるため、方針決定後にタスク化する。

## 8. タスク案

- [ ] 上記 A〜C の方針決定（人間の判断待ち）
- [ ] 決定後、CSRF 回転の条件付き更新化と保留数上限の再カウントを実装しタスク化する
