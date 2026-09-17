# [P2] device / CIBA の承認確定とスコープ絞り込みを単一の update に統合する

## ステータス

🟡 Medium / 未着手

## 背景

`--scope` 宣言時の生成 OP では、device / CIBA の承認が 2 段階の `store.update()` になっている。

1. `approveDeviceAuthorization` / `approveCibaRequest`（experimental）が `status='approved'`・`approvedScope=[...record.scope]`（絞り込み前）を永続化して return
2. 生成コードの `approveNarrowStep` が `resolveGrantableScopes()` を適用してもう一度 `update`

クライアントは interval（既定 5 秒）で token endpoint をポーリングしているため、1 と 2 の間に `store.consume()` が割り込むと、

- ポリシーが落とすはずの scope を含むトークンが発行される（スコープ昇格ウィンドウ）
- さらに 2 の update（インメモリストアでは upsert）が consume 済みレコードを approved 状態で復活させ、同じ device_code / auth_req_id で 2 本目のトークンが取れる（単回使用違反）

詳細は `study-material/done/device-ciba-approval-scope-narrowing-atomicity.md` を参照。

## 対象ファイル

- `packages/experimental/src/device-authorization-grant/verification.ts`（`approveDeviceAuthorization`）
- `packages/experimental/src/ciba/verification.ts`（`approveCibaRequest`）
- `packages/cli/src/frameworks/hono/templates.ts`（device / CIBA の `approveNarrowStep` を承認関数への引数渡しに変える）
- 各 verification のテスト、generator テスト、生成 conformance テスト
- 実装解説 `implementation-guides/experimental/device-authorization-grant.{ja,en}.md` / `ciba.{ja,en}.md`（掲載コードの同期）

## 仕様参照

- RFC 6749 §3.3（付与 scope はサーバーポリシーで狭められる）
- RFC 8628 §3.4-3.5 / CIBA Core 1.0 §10.1・§11（単回使用・リプレイ防止）

## 現状の実装

`approveCibaRequest` は絞り込み手段を持たず、要求 scope をそのまま `approvedScope` にコピーして即座に永続化する。
生成コードは承認確定後のレコードへ絞り込みを適用して再保存する。
device 側も同形。

## 修正方針

- [ ] `approveDeviceAuthorization` / `approveCibaRequest` に `approvedScope`（絞り込み済み配列）または narrow 関数を渡せる引数を追加する
- [ ] `status='approved'` と絞り込み済み scope を単一の `store.update()` で永続化する
- [ ] 生成コードの `approveNarrowStep` を「承認前に `resolveGrantableScopes` を呼び、結果を承認関数へ渡す」形に変える。承認確定後のレコード update を排除する
- [ ] experimental は自動 changeset（patch 固定）なので changeset は書かない
- [ ] 実装解説（ja / en）の掲載コードと説明を同じ変更内で更新する

## テスト要件

- [ ] `should persist the narrowed scope and the approved status in a single update`（update 呼び出し回数と内容を固定。device / CIBA）
- [ ] `should not resurrect a consumed record after approval`（承認と consume の割り込みを模したストアで検証）
- [ ] `should issue the narrowed scope when the token endpoint polls immediately after approval`
- [ ] 既存の承認・絞り込みテストの更新

## 完了条件

```bash
pnpm --filter @maronn-openid-connect/experimental test
pnpm --filter @maronn-openid-connect/cli test
pnpm typecheck
pnpm test:conformance
pnpm run test:e2e
```

- 上記がすべて成功する
- `--scope` 宣言ありの生成物で、承認後のストア update が 1 回であることがテストで固定されている
