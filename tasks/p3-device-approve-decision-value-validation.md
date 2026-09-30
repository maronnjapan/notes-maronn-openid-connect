# [P3] device 承認 POST の decision 値を検証し不明値を 400 にする

## ステータス

🟢 Low / 未着手

## 背景

生成 OP の `POST /device/approve`（hono テンプレート。web-standard 変換で 4 フレームワークへ展開）は、`decision` フィールドを `String(body['decision'] ?? '')` で受けた後、`decision === 'approve'` の分岐だけを持ち、それ以外のあらゆる値（欠落・空文字・`Approve` のような大文字違い・タイプミス）を else として `denyDeviceAuthorization` に流す。
拒否は `assertPending` により一方向の状態遷移であり、取り消せない。
フォームの不具合や再送で `decision` が欠けた POST が届くと、ユーザーが承認したつもりの保留レコードが黙って denied になり、デバイス側は `access_denied` でフローが死ぬ。

同じテンプレート内の CIBA 承認ルートは不明な `decision` 値を明示的に 400 で拒否し、生成 conformance テストでそのケースを固定している。
device 側だけ検証が無いのは実装パリティを欠き、省略の設計判断も記録されていない。
2026-09-30 の実装レビュー（Phase 2 ルーティーン）で検出した。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`（`deviceVerificationRouteTemplate` の `POST /device/approve`。`decision` が `approve` / `deny` のどちらでもなければ 400 を返す分岐を CIBA ルートに倣って追加する）
- 生成 conformance テストテンプレート（不明 `decision` の 400 ケースを CIBA 側の既存テストに倣って追加し、4 サンプルを再生成する）
- 実装解説 `implementation-guides/experimental/device-authorization-grant.{ja,en}.md`（掲載コードの同期）

## 仕様参照

- RFC 8628 §3.3（verification UI の承認・拒否は End-User の明示の意思で行う）
- 先例: 同テンプレートの CIBA 承認ルート（不明 decision を 400 にする分岐と conformance テスト）

## 現状の実装

```ts
const decision = String(body['decision'] ?? '');
// ...
if (decision === 'approve') {
  // 承認処理
}
await denyDeviceAuthorization({ record, store: deviceStore, csrfToken });
```

`decision` の値検証が無く、`approve` 以外はすべて拒否処理に落ちる。

## 修正方針

- [ ] `decision` が `'approve'` と `'deny'` のどちらでもない場合、レコードを変更せずに 400（エラーページ）を返す
- [ ] 分岐の位置は binding cookie / CSRF 検証の後、状態遷移の前（検証前に値エラーを返すと、未検証の POST に対する応答差が生まれるため）
- [ ] CIBA ルートの同型分岐と文言・応答形式を揃える

## テスト要件

- [ ] `decision=deny` → 従来どおり拒否が確定する（回帰）
- [ ] `decision` 欠落 / 空文字 / `Approve` → 400 が返り、レコードが pending のまま変化しない
- [ ] 生成 conformance テスト（4 フレームワーク）に上記ケースを追加

## 完了条件

- CLI の generator テストと 4 サンプルの conformance テストが通る
- 実装解説（ja / en）の掲載コードが更新されている
