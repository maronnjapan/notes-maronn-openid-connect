# CIBA grant のトークンエンドポイント分岐がクライアントの grant 登録を再検証しない非対称

## 1. このトピックで確認したいこと

トークンエンドポイントの CIBA 分岐（`urn:openid:params:grant-type:ciba`）が、償還時にクライアントの `grantTypes` 登録を再検証していない。同じ experimental の Device Grant は再検証している。この非対称をどう扱うかを確認する。

## 2. 関連する仕様・基準

- RFC 6749 §5.2 `unauthorized_client`: 当該 grant type の使用を許可されていないクライアント。
- CIBA Core 1.0 §11: トークンエンドポイントのエラーには OAuth の語彙を用いる。

## 3. 参照資料

- `packages/experimental/src/ciba/ciba-grant.ts`（`resolveCibaRecord` は `record.clientId !== client.clientId` のみ検証）
- `packages/experimental/src/device-authorization-grant/device-code-grant.ts`（`validateDeviceCodeGrantAllowed` が `grantTypes` に URN が無ければ `unauthorized_client` を投げ、`processDeviceCodeGrant` が必ず呼ぶ）
- `tasks/experimental/done/ciba/specification.md`（トークン処理手順にこの検証は無く、省略の設計判断も記録されていない）

## 4. 現在の実装確認

CIBA のバックチャネル認証エンドポイントは発行時に grant 登録を検証する。しかしトークンエンドポイント側の `processCibaGrant` は、レコードの clientId 一致のみを見て償還を許す。

## 5. 現在の実装との差分

- 🟠 `auth_req_id` 発行後にクライアント登録から CIBA grant を外しても、既発行レコードはそのまま償還できる。登録失効の即時性を欠く。
- 🟢 実害は限定的（レコードの取得には発行時点の正当な登録とクライアント認証が必要）。
- 🟠 Device Grant との実装パリティを欠き、省略が設計判断として記録されていない。

## 6. 改善・追加を検討する理由

同一リポジトリ内に「償還時に grant 登録を再検証する」先例（device）が既にあり、CIBA だけ欠けているのは意図の読めない差になる。修正は device と同型の 1 ステップ追加で済む。

## 7. 実装方針の候補

- `processCibaGrant` 冒頭に device と同型の `grantTypes` 検証を追加し、欠けていれば `unauthorized_client` を返す。単体テストと生成 conformance テストで固定する。
- 実装解説（ciba.ja.md / ciba.en.md）の掲載コードを同じ変更内で更新する。

## 8. タスク案

- [ ] `processCibaGrant` への grant 登録再検証の追加とテスト

→ `tasks/p3-ciba-grant-type-registration-revalidation.md` としてタスク化済み。
