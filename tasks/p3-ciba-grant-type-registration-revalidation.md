# [P3] CIBA grant の償還時にクライアントの grant 登録を再検証する

## ステータス

🟢 Low / 未着手

## 背景

トークンエンドポイントの CIBA 分岐（`processCibaGrant`）は、レコードの clientId 一致のみを検証し、クライアントの `grantTypes` 登録に CIBA の URN が残っているかを再検証しない。
`auth_req_id` 発行後にクライアント登録から CIBA grant を外しても、既発行レコードは償還できる。
同じ experimental の Device Grant は `validateDeviceCodeGrantAllowed`（登録に URN が無ければ `unauthorized_client`）を必ず呼んでおり、実装パリティを欠く。省略の設計判断も記録されていない。

詳細は `study-material/done/ciba-grant-type-registration-revalidation.md` を参照。

## 対象ファイル

- `packages/experimental/src/ciba/ciba-grant.ts`（`processCibaGrant`）
- `packages/experimental/src/ciba/ciba-grant.test.ts`
- 生成 conformance テストテンプレート（必要なら）
- 実装解説 `implementation-guides/experimental/ciba.{ja,en}.md`（掲載コードの同期）

## 仕様参照

- RFC 6749 §5.2（unauthorized_client: 当該 grant type の使用を許可されていないクライアント）
- CIBA Core 1.0 §11

## 現状の実装

`resolveCibaRecord` は `record.clientId !== client.clientId` のみ検証する。
Device Grant 側には `validateDeviceCodeGrantAllowed` の先例がある。

## 修正方針

- [ ] `processCibaGrant` 冒頭に device と同型の `grantTypes` 検証を追加し、CIBA URN が無ければ `unauthorized_client` を返す
- [ ] experimental は自動 changeset（patch 固定）なので changeset は書かない
- [ ] 実装解説（ja / en）の掲載コードと説明を同じ変更内で更新する

## テスト要件

- [ ] `should reject the ciba grant with unauthorized_client when the client no longer registers the grant`
- [ ] `should redeem the ciba grant when the client registers the grant`（回帰）

## 完了条件

```bash
pnpm --filter @maronn-openid-connect/experimental test
pnpm --filter @maronn-openid-connect/cli test
pnpm typecheck
pnpm test:conformance
```
