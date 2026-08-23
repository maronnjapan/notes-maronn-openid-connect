# 拡張: Dynamic Client Registration Management Protocol（RFC 7592）

## ステータス

🟢 拡張機能 / 未着手（前提となる RFC 7591 登録が未実装のため後続トピック）

## 1. このトピックで確認したいこと

`study-material/ext-dynamic-client-registration.md` は **登録（RFC 7591 / OIDC DCR 1.0）** を扱い、
その方針B/Cで「**RFC 7592 管理プロトコルは対象外**」と明記している。
本トピックはその明示的に切り出された差分、すなわち **登録済みクライアントの「読み取り・更新・削除」（RFC 7592）** を、
将来 DCR を実装する場合にどう設計するかを判断材料として整理する。

確認したいことは以下の3点に絞る（RFC 7591 登録本体の是非は重複するため `ext-dynamic-client-registration.md` を参照）。

- Client Configuration Endpoint（`registration_client_uri`）と `registration_access_token` の認可モデルをどう core で表現するか
- 更新（HTTP PUT）・削除（HTTP DELETE）・参照（HTTP GET）を提供する場合の、既存 `ClientResolver` / `ClientRegistrationStore`（A案）との接続点
- 管理プロトコル特有のセキュリティ論点（登録アクセストークンの漏洩・クライアント乗っ取り・`client_secret` の再発行）

## 2. 関連する仕様・基準

> RFC 7591 の登録メタデータやエラーコードの一般説明は `ext-dynamic-client-registration.md` §2 に記載済み。ここでは **RFC 7592 固有** の差分のみ記す。

- **RFC 7592 §2「Client Configuration Endpoint」**
  - 登録時のレスポンスで返した `registration_client_uri`（このクライアント専用の URL）に対し、
    `registration_access_token`（Bearer）を付けて次の操作を行う。
    - **GET**: 現在のクライアント構成を取得（200 + Client Information Response）。
    - **PUT**: クライアントメタデータを全置換更新（200 + 更新後の構成）。リクエストには全メタデータを含める（部分更新ではない）。
    - **DELETE**: クライアント登録を失効（204 No Content）。以後そのクライアントでの認可・トークン要求は失敗しなければならない。
- **RFC 7592 §2.1「Forming the Read/Update/Delete Request」**
  - `Authorization: Bearer <registration_access_token>` 必須。トークンはそのクライアント1件にのみ有効。
- **RFC 7592 §2.2「Client Read Response」 / §2.3「Client Update」**
  - 更新時、サーバは `client_id` の変更を許さない（MUST NOT change）。
    `client_secret` は再発行してよい（その場合レスポンスに新 secret を含める）。
  - サーバは更新後も `registration_access_token` をローテーションしてよい（新トークンをレスポンスに含める）。
- **RFC 7592 §3「Error Response」**
  - `invalid_redirect_uri` / `invalid_client_metadata` / `invalid_client_id`。
  - 認可されない `registration_access_token` には RFC 6750 の `invalid_token`（401）。
- **RFC 7592 §5「Security Considerations」**
  - 登録アクセストークンは長期有効になりがちで、漏洩すると **クライアント乗っ取り**（redirect_uri 書き換え → 認可コード窃取）に直結する点を明示。

## 3. 参照資料

- RFC 7592（OAuth 2.0 Dynamic Client Registration Management Protocol）:
  https://www.rfc-editor.org/rfc/rfc7592
  - §2（Client Configuration Endpoint / GET・PUT・DELETE）
  - §2.3（更新時の `client_id` 不変・`client_secret`/`registration_access_token` ローテーション）
  - §3（エラーレスポンス）/ §5（セキュリティ考慮）
- RFC 7591（登録本体。メタデータ定義はこちら）: https://www.rfc-editor.org/rfc/rfc7591
- OIDC Dynamic Client Registration 1.0: https://openid.net/specs/openid-connect-registration-1_0.html
- 前提トピック（RFC 7591 登録の是非・方針A/B/C）: `study-material/ext-dynamic-client-registration.md`

## 4. 現在の実装確認

- 登録エンドポイント本体が未実装（`ext-dynamic-client-registration.md` §4 参照）。当然 **管理エンドポイントも無い**。
- クライアント解決は静的登録前提: `ClientResolver.findClient`（`packages/core/src/authorization-request.ts:102-104`）、
  Token 側は `TokenClientResolver.findClient`（`packages/core/src/token-request.ts:108-110`）。
  いずれも **読み取り専用** I/F で、更新・削除の口は無い。
- `registration_client_uri` / `registration_access_token` を表現する型・ストアは存在しない。

## 5. 現在の実装との差分

- **満たしていること**: クライアント解決が resolver 抽象なので、登録ストアを足す場合も core を汚さずに済む（RFC 7591 と共通の利点）。
- **不足している可能性があること（RFC 7592 固有）**
  - Client Configuration Endpoint（GET/PUT/DELETE）と、その入力（`registration_access_token`）の検証ヘルパー。
  - `registration_access_token` → 対象 `client_id` の対応付けと、**1トークン1クライアント**のスコープ制約。
  - 更新時の不変条件（`client_id` 不変）・`client_secret` 再発行・トークンローテーションの状態遷移。
  - 削除後にそのクライアントの既存トークン／認可コードを失効させる連携（既存の `revokeTokensByGrantId` 系と接続するか要検討）。
- **セキュリティ上の確認点**
  - 登録アクセストークンの**保存時ハッシュ化**（`study-material/credential-at-rest-hashing.md` の対象に `registration_access_token` を追加すべきか）。
  - 削除（DELETE）が**冪等**で、かつ削除済みクライアントの再利用を確実に拒否できること。
- **Basic OP として**: RFC 7592 は **Basic OP の要件ではない**（Basic OP 定義は `basic-op-requirements-baseline.md` を参照、重複記載しない）。あくまで DCR を実装した場合の付随機能。

## 6. 改善・追加を検討する理由

- **なぜ価値があるか**: 動的登録を試す PoC では「登録 → メタデータ修正（redirect_uri 追加など）→ 削除」を繰り返す。管理プロトコルが無いと、修正のたびにストアを手で書き換える必要があり、DCR の利便性が半減する。
- **Basic OP として必要か**: 不要。**拡張機能**。RFC 7591 登録を実装して初めて意味を持つ。
- **導入しやすさ / しにくさ**: RFC 7591 登録（`ClientRegistrationStore` 注入＝方針A）が前提。これが未確定なので、本トピックは**単独では着手できない**。登録基盤が決まれば、管理は同じストアに対する CRUD として比較的素直に乗る。
- **既存実装との接続**: 削除時のトークン失効は既存の grant 単位失効（`token-request.ts` の `revokeTokensByGrantId`）と概念が近く、クライアント単位失効へ一般化する余地がある。
- **利用者メリット**: 認定テスト／IdP 移行検証で、クライアント設定の試行錯誤がAPI経由で完結する。
- **実装しない場合のリスク**: DCR を入れても運用面が片肺になり、「登録はできるが直せない／消せない」状態になる。登録アクセストークンの設計を後付けすると破壊的変更になりやすい。

## 7. 実装方針の候補（最終判断は人間）

### 方針A: RFC 7591 と同時に管理まで設計する

- `ClientRegistrationStore` に `get` / `update` / `delete` を含め、`registration_access_token` をストアのキー付帯情報として持つ。
- core には「登録アクセストークン検証 → 対象 client 解決 → メタデータ全置換検証」の純関数を置き、永続化は注入。
- 利点: 後付けの破壊的変更を避けられる。欠点: 初期実装スコープが膨らむ。

### 方針B: 登録（7591）のみ先行し、管理（7592）は明示的に非対応

- `ext-dynamic-client-registration.md` の方針B相当。`registration_client_uri` を返さない／返しても 405/501 を返す。
- 利点: 最小で出せる。欠点: のちに管理を足すとき `registration_access_token` 設計を遡及追加する必要。

### 方針C: 当面 DCR 全体を非対応

- `ext-dynamic-client-registration.md` の方針C。Discovery から `registration_endpoint` を出さない。本トピックは保留。

## 8. タスク案

> 本トピックは前提（RFC 7591 登録の方針A/B/C）が未確定のため、**現時点では `tasks/` 化しない**。
> 下記は登録基盤の方針が「方針A（管理込み）」に決まった場合に着手する候補。

- [ ] RFC 7591 登録の方針決定を待つ（依存：`ext-dynamic-client-registration.md` §8）
- [ ] `registration_access_token` の認可モデル（1トークン1クライアント・保存時ハッシュ化）を design-discussion で確定
- [ ] core: 管理リクエスト検証ヘルパー（GET/PUT/DELETE の入力検証・`client_id` 不変・`invalid_client_metadata`）をテスト先行で実装
- [ ] DELETE 時の既存トークン／認可コード失効の連携設計（grant 単位失効の一般化）
- [ ] CLI/sample に Client Configuration Endpoint ルートと in-memory ストアのスタブ生成
