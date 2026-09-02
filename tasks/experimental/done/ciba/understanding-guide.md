# 理解資料: CIBA (Client-Initiated Backchannel Authentication) Poll Mode

この資料は、プロジェクト所有者が CIBA を正確に理解し、本リポジトリへの対応付けを把握するためのもの。仕様書（specification.md）の要約ではなく、「なぜそうなっているか」「このリポジトリではどこで起きるか」を説明する。

## 解決する問題

通常の Authorization Code Flow は「ユーザーが操作しているブラウザをリダイレクトで OP に連れて行く」前提に立つ。しかし現実には、**認可が必要なのにユーザーのブラウザがその場に無い**場面がある:

- コールセンターのオペレーターが、電話越しの本人に代わって手続きを進めたい
- 店頭の POS 端末で、店員の画面からユーザー本人の同意を取りたい
- スマートスピーカーへの音声指示で決済を承認したい

CIBA はこの「リダイレクトできない」制約を、**クライアントがユーザーの識別子だけを OP に伝え、ユーザーは自分の手元のデバイスで承認する**ことで解決する。Device Authorization Grant（実装済み）が「ユーザーがコードを書き写して自ら OP に来る」解なのに対し、CIBA は「クライアントがユーザーを指名し、OP がユーザーの承認を待つ」解である。

## 背景標準

- **CIBA Core 1.0**（OpenID Foundation, Final, 2021-09-01）が唯一の規範。トークン受け渡しに Poll / Ping / Push の 3 モードを定義する
- 本機能は **Poll モードのみ**を実装する。Ping / Push は OP からクライアントへの callback 送信（通知チャネル）が必要で、experimental の隔離規模を超える
- FAPI-CIBA（金融グレードプロファイル）は CIBA Core の上に署名必須等を重ねたもので、本機能の対象外

## 基礎概念と登場人物

| 用語 | 意味 | このリポジトリでの対応物 |
|---|---|---|
| Consumption Device (CD) | 認可を必要とするがユーザーが直接操作しないデバイス。OAuth のクライアント | E2E では `tests/e2e/apps` のテストクライアント |
| Authentication Device (AD) | ユーザーが承認操作を行う手元のデバイス。実運用ではスマホアプリが典型 | 生成 OP がホストするブラウザ UI（`GET /ciba`）。ユーザーのブラウザが AD になる |
| `login_hint` | CD が「誰の認証を求めるか」を OP に伝える識別子 | 生成 OP のユーザーフィクスチャの username。`CibaUserResolver` で差し替え可能 |
| `auth_req_id` | 認証リクエスト（トランザクション）の識別子。CD がポーリングに使う | 256bit Base64URL。authorization code 同等の機密として扱う |
| `binding_message` | CD と AD の両画面に表示してトランザクションを目視で紐付ける短文 | 承認画面に表示。HTML エスケープ必須 |
| Poll モード | CD がトークンエンドポイントを一定間隔で叩いて結果を待つ方式 | Device Grant のポーリングと同型。既存 `/token` への分岐 |

## 通常フロー（このリポジトリの生成 OP で起きること）

1. CD が `POST /backchannel_authentication` に `scope=openid&login_hint=user1` をクライアント認証付きで送る
2. 生成コードが core の共有パイプラインでクライアント認証 → experimental の `processBackchannelAuthenticationRequest` がヒント検証・ユーザー解決・レコード保存 → `auth_req_id` / `expires_in` / `interval` を返す
3. CD は `interval` 秒間隔で `POST /token`（`grant_type=urn:openid:params:grant-type:ciba`）を叩き始める。承認前は `authorization_pending`
4. ユーザーが自分のブラウザで `GET /ciba` を開き、OP にログインする（既存の `authenticateUser` 契約 = 資格情報の swap point）
5. 自分宛の保留中リクエスト一覧（クライアント名・scope・binding_message）が表示される。承認すると consent が記録され、レコードが `approved` になる
6. 次のポーリングで OP はレコードを atomic に consume し、アクセストークン + ID トークン（+ 条件付き refresh token）を返す

## 失敗フロー

- **ユーザーが拒否**: 次のポーリングが `access_denied`（HTTP 400）。CD はフローを終了する
- **時間切れ**: `expires_in` 経過後のポーリングは `expired_token`。CD は最初からやり直す
- **ポーリングが速すぎる**: `slow_down`。CD は間隔を 5 秒以上広げる義務がある（以後のすべてのリクエストに適用）
- **ユーザーを特定できない**: バックチャネル認証応答が `unknown_user_id`
- **ヒントが 0 個 / 2 個以上**: `invalid_request`（CIBA §7.2 の明示規定）

## セキュリティモデルと脅威対策

CIBA の攻撃面は「クライアントが任意のユーザーを指名してリクエストを起こせる」ことに集中する。

1. **未承諾リクエスト（spam / 承認疲労）**: 悪意あるクライアントがユーザーの承認一覧を埋める、あるいはユーザーが誤承認するまで送り続ける脅威。CIBA Core はこの対策として `user_code`（ユーザーごとの秘密、§7.1.2）を用意するが、本機能は非対応（秘密の登録・保管ストアが別途要るため）。代わりに (a) クライアント認証必須（匿名からは送れない）、(b) subject あたりの保留数上限、(c) pull 型 UI（プッシュ割り込みが無い）、(d) 承認画面での明示的な情報表示、で緩和する。**正規クライアントが侵害された場合の最終防衛はユーザーの拒否操作**である点が受容コストで、README に明記する
2. **承認の乗っ取り**: `auth_req_id` を知る攻撃者が承認を偽造する脅威。承認操作は「認証済み OP セッションの subject = レコードの subject」でなければ実行できないため、`auth_req_id` の知識だけでは何もできない。Device Flow で必要だった binding Cookie が CIBA の**承認操作**に無いのはこのため（Device Flow は user_code しかリンクが無いが、CIBA はレコード自体がユーザーを指名している）
3. **ログイン CSRF**: 攻撃者のサイトが被害者ブラウザに `POST /ciba/login` を偽造送信し、攻撃者アカウントの OP セッションを植え付ける脅威。CIBA 内では利得が無い（攻撃者の保留リクエストを承認しても攻撃者自身のトークンになるだけ）が、OP セッションは SSO / `prompt=none` に波及するため放置できない。フォーム埋め込みトークンだけでは攻撃者が自分で `GET /ciba` を叩いて有効な対を入手できるため、Device Flow と同じ binding Cookie 方式（生値はブラウザのみ・レコードにはハッシュ）を**ログインフォームには**常時適用する。ログイン失敗の試行回数もこのログイントランザクションを錨に計数する（CIBA リクエストのレコードはログイン時点で特定できないため、計数の錨が別途必要になる）
4. **`auth_req_id` の窃取**: トークン取得にはクライアント認証と「発行先クライアント一致」（`invalid_grant`）が要るため、`auth_req_id` 単独ではトークンを取れない。それでも authorization code と同格の機密として扱い、ログへ出さない
5. **トランザクション取り違え**: オペレーターの画面と本人のスマホで別件を承認してしまう脅威。`binding_message` を両画面に表示する視覚照合が仕様上の対策（§7.1）
6. **ユーザー列挙**: `unknown_user_id` はユーザーの存在有無を登録クライアントに教える。これは仕様が定義する語彙（§13）であり返すが、error_description は固定文言にし、匿名アクセスはクライアント認証で遮断する

## リクエスト・レスポンス実例

```http
POST /backchannel_authentication HTTP/1.1
Content-Type: application/x-www-form-urlencoded
Authorization: Basic czZCaGRSa3F0Mzo3RmpmcDBaQnIxS3REUmJuZlZkbUl3

scope=openid%20profile&login_hint=user1&binding_message=W4SCT-441
```

```http
HTTP/1.1 200 OK
Content-Type: application/json
Cache-Control: no-store

{"auth_req_id":"1c266114-a1be-4252-8ad1-04986c5b9ac1","expires_in":120,"interval":5}
```

（`auth_req_id` の実際の値は 256bit の Base64URL 文字列。上は CIBA 仕様書の例の形式）

```http
POST /token HTTP/1.1
Content-Type: application/x-www-form-urlencoded
Authorization: Basic czZCaGRSa3F0Mzo3RmpmcDBaQnIxS3REUmJuZlZkbUl3

grant_type=urn%3Aopenid%3Aparams%3Agrant-type%3Aciba&auth_req_id=1c266114-...
```

承認前の応答:

```http
HTTP/1.1 400 Bad Request
Content-Type: application/json
Cache-Control: no-store

{"error":"authorization_pending","error_description":"The authorization request is still pending"}
```

承認後の応答は通常のトークン応答（access_token / id_token / token_type / expires_in / scope）。Poll モードの ID トークンに CIBA 固有クレームは無い（`urn:openid:params:jwt:claim:auth_req_id` は Push モード専用）。

## データ構造

中心は `CibaAuthenticationRequestRecord`（specification.md の公開API案を参照）。Device Grant の `DeviceAuthorizationRecord` との差分が CIBA の本質を表す:

- `subject` が**リクエスト受理時点で確定している**（Device は承認時に確定）。CIBA はクライアントがユーザーを指名するフローだから
- `userCode` / `bindingHash` が無い（ユーザーはコードを入力せず、承認操作はセッション subject 一致で束縛する）。ただしログインフォーム側には別レコード `CibaLoginTransactionRecord` が bindingHash を持つ（ログイン CSRF 対策。上記セキュリティモデル 3 を参照）
- `bindingMessage` がある（両画面の視覚照合）

## core 機能・類似機能との違い

| | Authorization Code Flow (core) | Device Grant (experimental) | CIBA Poll (本機能) |
|---|---|---|---|
| 起点 | ユーザーのブラウザ | デバイス（ユーザー同席） | クライアント（ユーザー不在） |
| ユーザー識別 | ブラウザセッション | ユーザーが user_code を入力 | クライアントが login_hint で指名 |
| redirect_uri | 必須 | 無し | 無し |
| トークン受領 | code 交換 | ポーリング | ポーリング |
| 新規エンドポイント | — | device_authorization + 検証 UI | backchannel_authentication + 承認 UI |
| grant_type | authorization_code | urn:ietf:params:oauth:grant-type:device_code | urn:openid:params:grant-type:ciba |

grant ディスパッチ・ポーリング状態機械・承認 UI という実装部品は Device Grant と同型で、`packages/cli/src/frameworks/hono/templates.ts` の deviceCodeDispatchStep（4002 行付近）・`/device` UI ルートが直接の先例になる。

## Experimental にする理由

- 認証デバイス UI の画面構成・views 契約が利用者フィードバックで変わり得る
- `CibaUserResolver`（login_hint → subject）の契約形状が利用者のユーザーストア設計に依存する
- Poll 限定・login_hint 限定の初期スコープを広げる際、公開 API に破壊的変更が入り得る

## 誤解しやすい点

1. **「CIBA = プッシュ通知」ではない**。通知はトークン受け渡しモード（Ping/Push）や AD への到達手段の話で、Poll モードの CIBA はプッシュ通知なしで完結する。本機能の AD は「ユーザーが自分で開くブラウザページ」であり、これは CIBA Core が AD への到達方法を仕様の対象外としていることの正当な実装である
2. **`login_hint` はログインさせる手段ではない**。誰の承認を待つかを指名するだけで、ユーザー認証そのものは AD 側（本機能では OP のログイン UI）で行われる
3. **`auth_req_id` は access token ではない**。それ自体では何も取得できず、発行先クライアントの認証と組み合わせて初めてトークンに交換できる
4. **Poll モードの ID トークンは普通の ID トークン**。`auth_req_id` クレームや `rt_hash` が要るのは Push モードだけ（CIBA §10.3.1）
5. **`slow_down` は一時的な減速指示ではない**。「このリクエストと以後のすべてのリクエスト」に対して恒久的に +5 秒される（§11）。本 OP はレコードの `interval` を実際に書き換えて追跡する
6. **nonce は存在しない**。CIBA の認証リクエストに nonce パラメータは無く、ID トークンにも nonce は入らない。Authorization Code Flow の感覚で nonce 検証を探さないこと

## 実装後の利用方法

```bash
# CIBA 有効の OP を生成
npx @maronn-openid-connect/cli install hono --enable ciba
```

1. クライアント定義に `grantTypes: [..., 'urn:openid:params:grant-type:ciba']` を追加する（`token_endpoint_auth_method` は `none` 以外）。`backchannelTokenDeliveryMode` は未設定でよい（`poll` とみなされる）。設定するなら `'poll'` のみが受理される
2. `login_hint` を自分のユーザーストアへ引き当てたい場合は context の `cibaUserResolver` を差し替える（デフォルトは生成ユーザーフィクスチャの username 照合）
3. CD 役のアプリから `POST /backchannel_authentication` → ポーリング。ユーザーはブラウザで `/ciba` を開いて承認する
4. discovery（`/.well-known/openid-configuration`）に `backchannel_token_delivery_modes_supported: ["poll"]` と `backchannel_authentication_endpoint` が出ていることが有効化の確認になる

## 一次資料の読み方ガイド

CIBA Core 1.0（https://openid.net/specs/openid-client-initiated-backchannel-authentication-core-1_0.html）は Poll 実装に必要な範囲が限られている。読む順序:

1. **§3 (Overview)** でフロー全体像と 3 モードの違いを掴む
2. **§7.1 (Authentication Request)** — パラメータ定義。ヒント 3 種と「ちょうど 1 つ」規則が最重要
3. **§7.3 (Successful Acknowledgement)** — `auth_req_id` のエントロピー・文字種要件はここ
4. **§10.1 / §11 (Token Request / Error Response, Poll)** — 状態機械のエラー語彙。`slow_down` の恒久 +5 秒はここ
5. **§13 (Authentication Error Response)** — バックチャネル側のエラー語彙と HTTP ステータス
6. **§4 (Registration and Discovery)** — メタデータ。REQUIRED は 2 項目だけ
7. **§14 (Security Considerations) / §15 (Privacy Considerations)** — auth_req_id の扱いと login_hint の PII 性。user_code の意図は §7.1.2 とあわせて読む
8. §10.2 / §10.3（Ping / Push）は非目標の境界を確認する目的でだけ読む

## 昇格判断の観点

- `CibaUserResolver` と views 契約が利用者フィードバックを経て安定したか
- Ping モード（通知チャネル）への拡張要望が実在するか。あるなら昇格前に experimental 内で API 形状を確定させる方が安全
- `id_token_hint` 対応（core の `validateIdTokenHint` への exp 緩和オプション追加）を昇格と同時に行うか
- Device Grant と共通するポーリング状態機械を core の共通部品に括り出す価値が出ているか（experimental 間の重複許容方針は昇格時に再評価される）
