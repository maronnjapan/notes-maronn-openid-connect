# 3rd-Party Initiated Login（OIDC Core §4 / `initiate_login_uri`）

## 1. このトピックで確認したいこと

OpenID Connect Core 1.0 §4 が定義する「第三者が RP に対してログインを開始させる」フロー、いわゆる Third-Party Initiated Login を本リポジトリの OP / クライアント実装でどう扱うかを整理する。

確認したい論点:

- OP 側のクライアント登録メタデータ `initiate_login_uri` の保持と公開
- OP → RP に対して「ログインを開始してね」とリダイレクト/リンクできる導線を OP が提供するかどうか
- `iss` / `login_hint` / `target_link_uri` パラメータの取り扱い
- セキュリティ上の注意（クリックジャッキング / オープンリダイレクター化のリスク）

Basic OP 認定との関係も明確にする。

なお、`prompt=login` / `prompt=none` / `prompt=select_account` などのプロンプト系は別ファイル（`study-material/prompt-select-account.md`、`tasks/done/02-prompt-none.md` 等）で扱い済みのため、本ファイルでは重複しない「RP 起動の入口」だけに絞る。

## 2. 関連する仕様・基準

### OpenID Connect Core 1.0 §4 Initiating Login from a Third Party
- RP が `initiate_login_uri` をクライアント登録時に登録する
- 第三者（OP / IdP-Initiated SSO ポータル / アプリ起動リンクなど）はその URI に対して GET / POST し、RP に認証フローを開始させる
- パラメータ:
  - `iss`（必須）: 認証を開始した OP の Issuer URL。RP は **複数 OP に対応する場合この値で OP を選ぶ**
  - `login_hint`（任意）: ログインさせたいユーザーのヒント
  - `target_link_uri`（任意）: 認証完了後のリダイレクト先（RP 内 URL）

### OpenID Connect Dynamic Client Registration 1.0 §2
- クライアントメタデータ `initiate_login_uri`
  - 「Third Party が RP のログインを初期化するための URI」
  - 任意項目

### Basic OP 認定との関係
- OpenID Connect Conformance Profiles v3.0 Basic OP のテスト項目には Third-Party Initiated Login は含まれていない
- Federation / Provider-Initiated SSO 系のテストプロファイルで扱われる

### セキュリティ
- `target_link_uri` を信用するとオープンリダイレクターになるため、RP は登録済みドメインに限定する必要あり
- `iss` を検証しない RP は IdP-Mix-Up 攻撃の入口になる（OAuth 2.0 Security BCP, §4.4）

## 3. 参照資料

- OpenID Connect Core 1.0 §4
  https://openid.net/specs/openid-connect-core-1_0.html#ThirdPartyInitiatedLogin
- OpenID Connect Dynamic Client Registration 1.0 §2
  https://openid.net/specs/openid-connect-registration-1_0.html#ClientMetadata
  - `initiate_login_uri` 定義
- OAuth 2.0 Security Best Current Practice（RFC 9700）§4.4 / §4.5
  https://www.rfc-editor.org/rfc/rfc9700.html
  - Mix-Up Attack 対策の文脈
- 関連 study-material:
  - `study-material/ext-dynamic-client-registration.md`（クライアントメタデータの登録全般）
  - `study-material/basic-op-requirements-baseline.md`

## 4. 現在の実装確認

- クライアント情報の型定義
  - `packages/core/src/authorization-request.ts` の `ClientInfo`、`ClientResolver`
  - `initiate_login_uri` フィールドは未定義
- OP からの「RP ログイン開始」導線
  - `packages/sample/src/oidc-provider/routes/` に IdP-Initiated SSO 用のルート無し
- Discovery メタデータ
  - `packages/core/src/discovery.ts` の `ProviderMetadata` には `initiate_login_uri` を返すフィールド無し（仕様上も OP のメタデータには含まれない。RP メタデータのみ）

つまり Third-Party Initiated Login 関連の機能は未実装。

## 5. 現在の実装との差分

| 観点 | 仕様 | 現状 | 差分 |
|---|---|---|---|
| `ClientInfo.initiate_login_uri` の保持 | OIDC Reg §2 | 未対応 | 型と Resolver の対応が必要 |
| OP からの IdP-Initiated SSO 導線 | OIDC Core §4（OP 側オプション） | 未対応 | OP が「ログイン開始リンク」を生成する API は未提供 |
| RP 側の受け口 | OIDC Core §4（RP 必須） | 未対応（サンプル RP もなし） | サンプル RP に受け口を用意するか判断 |
| `iss` 検証の RP 側 | OIDC Core §4 | n/a | RP 側課題 |
| クライアント登録時のバリデーション | https URL / HTTPS 強制（loopback 例外） | 未対応 | 登録時の URI 検証が必要 |

## 6. 改善・追加を検討する理由

- **メリット**
  - エンタープライズ SSO（IdP-Initiated）を試したい PoC 開発者には価値が高い
  - 実装規模は OP 側に限れば「クライアントメタデータ 1 フィールド追加 + 任意の SSO ランチャー」程度で済む
- **デメリット / リスク**
  - RP 側の実装責務が大きく、OP の責務は「メタデータ保持」にとどまる
  - サンプル RP が安全な `iss` / `target_link_uri` 検証を行わないと、誤った実装例を OSS として広めてしまう
- **Basic OP 必須か拡張か**
  - 拡張（Basic OP 認定の必須項目ではない）

## 7. 実装方針の候補

### 候補 A: OP 側だけ最小対応（推奨）
- `ClientInfo` に `initiate_login_uri?: string` を追加
- `ClientResolver` が読み込む先で URI バリデーション（`https://` 必須 + loopback 例外）を行う
- OP からの IdP-Initiated SSO ランチャーは未提供。利用者が外部サービスから手動で呼び出すケースだけサポート
- Discovery への変更は不要

### 候補 B: ランチャー UI まで提供
- OP の管理 UI（`packages/sample/src/oidc-provider/views.ts` 系）に「クライアント一覧→ログイン開始」リンクを追加
- 内部的には登録済み `initiate_login_uri` に `iss=<our-issuer>&login_hint=<email>&target_link_uri=<...>` を付けてリダイレクト
- `target_link_uri` を OP 側で再検証する仕組みはなし（RP の責務）

### 候補 C: 採用しない
- `study-material/basic-op-requirements-baseline.md` に「拡張機能として未対応」と明記して終了
- v0.x の主要 7〜8 割の流れに該当しないと判断する場合

## 8. タスク案

候補 A 採用時:

- `ClientInfo` 型に `initiate_login_uri?: string` を追加
- クライアント登録時/解決時の URI バリデーション（`validateInitiateLoginUri` ユーティリティの新設）
- テストケース: 不正スキーム拒否 / loopback 許可 / fragment 拒否
- README / docs に「IdP-Initiated SSO のサポート範囲は OP 側のメタデータ保持のみ」と明記

候補 B 採用時は追加で:

- `cli` のテンプレに `/op/launch/:client_id` のような OP 内ランチャールートを生成
- ランチャールートで `iss` を OP の Issuer に固定し、`login_hint` / `target_link_uri` をクエリで透過
- セキュリティ警告: `target_link_uri` は RP の責任で検証することを README に明記
- 統合テスト: IdP-Initiated SSO で RP の `initiate_login_uri` 経由でフローが回ること

判断材料:

- 利用者層が IdP-Initiated SSO を実際に試したいかどうか
- RP 側の安全実装をどこまで OSS のサンプルで担保するか
- 関連: `study-material/ext-dynamic-client-registration.md`（クライアントメタデータ管理基盤の話）と一緒に進めるか判断
