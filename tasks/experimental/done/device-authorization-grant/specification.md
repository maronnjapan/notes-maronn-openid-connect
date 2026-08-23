# Experimental機能仕様書: OAuth 2.0 Device Authorization Grant

- **機能名**: OAuth 2.0 Device Authorization Grant（デバイス認可グラント）
- **feature-id**: `device-authorization-grant`
- **準拠仕様**: RFC 8628 - OAuth 2.0 Device Authorization Grant
- **作成日**: 2026-08-05
- **ステータス**: `state.yaml` を参照

## 概要

ブラウザを持たない・文字入力が困難なデバイス（スマート TV、CLI ツール、IoT 機器等）が、**別のデバイス上のブラウザ**でユーザーに認可してもらい、自分はトークンエンドポイントをポーリングしてトークンを受け取るためのグラント（RFC 8628）を生成 OP に追加する。

追加されるのは次の 3 面:

1. **デバイス認可エンドポイント**（バックチャネル・新規）: `POST /device_authorization`。クライアントが `device_code` / `user_code` / `verification_uri` の組を取得する
2. **検証 UI**（フロントチャネル・新規）: `GET /device` 等。ユーザーが別デバイスのブラウザで `user_code` を入力し、ログインして承認 / 拒否する
3. **トークンエンドポイントの grant ディスパッチ**（既存エンドポイントへの分岐追加）: `grant_type=urn:ietf:params:oauth:grant-type:device_code` を experimental ハンドラへ分岐し、承認状態に応じて `authorization_pending` / `slow_down` / `access_denied` / `expired_token` / トークン発行を返す

このフローには `redirect_uri` が一切登場しないため、リダイレクト起点の攻撃面（open redirect・code 横取り）が構造的に存在せず、既存の Authorization Code Flow と綺麗に直交する。

## 採用理由（候補評価）

前サイクル（JARM, 2026-08-02〜04）の候補評価で「バックチャネルエンドポイント（PAR で実証）＋ grant ディスパッチ（Token Exchange で実証）＋検証 UI と実証済みパターンの比率が上がっており、次サイクルの有力候補として残す」と明示された Device Authorization Grant を選定した。

| 観点 | 評価 |
|---|---|
| プロジェクト関連性 | 「CLI ツール / TV アプリにログインさせたい。Device Flow で自分の要件が実現できるか」は PoC 開発者の典型的検証テーマ。RFC 8628 は 2019年8月発行の Proposed Standard |
| Experimental隔離の妥当性 | 新規エンドポイント 2 面（バックチャネル + UI）は既存ルートに触れず追加でき、トークンエンドポイントは Token Exchange と同型の「core の grant_type 検証より前の分岐」1 箇所のみ。既存 grant のデフォルト挙動を一切変えない |
| core無変更 | 可能。core の `validateGrantTypeSupported`（`packages/core/src/token-request.ts`）は未知 URN を `unsupported_grant_type` で拒否するが、生成コードが分岐を core のこのステップより前に置く（`packages/cli/src/frameworks/hono/templates.ts:3106-3202` の tokenExchangeDispatchStep と同型）。バックチャネルエンドポイントの追加は PAR（`parRouteTemplate`）で実証済みのパターン |
| CLI `--enable` 提供 | 可能。`packages/cli/src/features.ts` の `EXPERIMENTAL_FEATURES` に `device-authorization-grant` を追加する |
| 一次資料の成熟度 | RFC 8628 は Proposed Standard。Google TV / Auth0 / Keycloak / Okta / Microsoft Entra ID 等、主要実装での相互運用実績が極めて豊富 |
| セキュリティ影響 | 新規 UI があるため PAR / Token Exchange より攻撃面は広いが、RFC 8628 §5 が脅威（user_code 総当たり・リモートフィッシング等）と対策を体系的に定義しており、対策を仕様段階で固定できる。`redirect_uri` が無いためリダイレクト系の攻撃面は増えない |
| テスト可能性 | バックチャネルとトークンポーリングは HTTP レベルで完結。UI は既存の login / consent と同じくフォーム POST の HTML なので conformance.test.ts（fetch ベース）と Playwright E2E の両方で検証可能 |
| 実装規模 | 中〜やや大（PAR と同程度以上）。新規ルート 1 + UI ルート 1 + views 追加 + token 分岐 + discovery + conformance。ただし全フレームワークは hono テンプレートを共有（`packages/cli/src/frameworks/web-standard/templates.ts` が hono テンプレートを変換して express / fastify / nextjs に流用）するためテンプレート実体は 1 系統 |
| 将来の昇格 | grant ディスパッチは core の grant ハンドラ追加として、エンドポイントは core のステップ関数群としてそのまま昇格できる。`device_authorization_endpoint` メタデータ（RFC 8628 §4）も既存 discovery 機構に乗る |
| 既存機能との重複 | なし。`tasks/T-019-dpop.md`（DPoP）は sender-constrained token で目的が異なる。PAR は「認可リクエストの事前登録」で、ユーザー対話は通常の authorize フローのまま。CIBA とは「ユーザーが自らコードを入力して承認する（consumption device 起点）」点で役割が異なる |
| 利用者の検証価値 | IdaaS で Device Flow を試すにはプラン・設定の壁があることが多く、「CLI ログインの UX が自分のプロダクトで成立するか」を手元で最速検証できる価値が高い |

CIBA は認証デバイスへの通知チャネル（ping / push）またはポーリング + 帯域外認証のシミュレーションが必要で、隔離規模を超えるため今回も見送り（次サイクル以降の候補として残す）。RAR は authorize / consent / token / introspection の複数層に跨がるため隔離性が劣る判断も前サイクルから変わらない。JAR（Request Object）は core の `request-object.ts` として実装済みであり experimental の対象ではない。

## Experimentalにする理由

- 検証 UI（user_code 入力・承認画面）の画面構成と views 契約（後述の `deviceVerificationPage` 等）が利用者フィードバックで変わり得るため、安定するまで隔離したい
- user_code の文字種・長さ・レート制限の既定値はデプロイ環境（グローバルレート制限の有無）に依存して調整余地があり、設定形状が固まっていない
- トークンエンドポイントの grant ディスパッチ・ストア契約（`DeviceAuthorizationStore`）という公開 API が、将来の core 昇格時に形を変える可能性が高い

## 非目標（Non-goals）

- **OAuth 単体（`openid` scope なし）のデバイス認可**: RFC 8628 §3.1 では `scope` は OPTIONAL だが、本 OP は authorize エンドポイントで `scope` 必須かつ `openid` 必須（`packages/core/src/authorization-request.ts` の `validateAuthorizationScope`）としており、デバイス認可エンドポイントも同じプロファイル制限を課す。**RFC 8628 が許容する scope 省略に対応しない制限**として理解資料・生成コードコメントに明示する
- **`verification_uri_complete` の非テキスト伝達（QR コード等, RFC 8628 §3.3.1）**: `verification_uri_complete` は応答に含める（OPTIONAL の採用）が、QR 画像のレンダリングはクライアント側の責務であり本 OP は関知しない
- **RFC 8707 Resource Indicators（`resource` パラメータ）**: デバイス認可リクエストに `resource` / `audience` を受け付けない。指定されても未知パラメータとして無視する（RFC 6749 §3.1 のパラメータ無視規則に合わせる。Token Exchange の `allowedTargets` のような対象指定は本機能では提供しない）
- **prompt / max_age / login_hint 等の OIDC 認可リクエストパラメータ**: RFC 8628 のデバイス認可リクエストは `client_id` / `scope` のみを定義しており、OIDC の認可パラメータ群は受け付けない。検証 UI は毎回ログイン済みセッションを確認し、無ければログインを要求する（prompt 相当の制御は提供しない）
- **CIBA 的なプッシュ通知**: 承認結果はデバイスのポーリングでのみ伝わる（RFC 8628 のモデル通り）
- **user_code の再発行・延長**: 期限切れはデバイスが最初からやり直す（RFC 8628 §3.5 `expired_token` の想定挙動）
- **接続タイムアウト時の指数バックオフ検証（RFC 8628 §3.5 のクライアント側 MUST）**: クライアント義務でありサーバー側検証対象外。生成する E2E クライアントは単純な interval 遵守ポーリングのみ実装する

## ユースケース / 想定利用者

- CLI ツールのログイン（`gh auth login` 型の UX）が自分の要件で成立するかを検証する開発者
- スマート TV / セットトップボックス向けアプリの認可 UX を PoC する開発者
- 入力デバイスを持たない IoT 機器のプロビジョニングフローを検証する開発者

## プロトコルフロー

```text
Device (client)               OP (生成コード + experimental/device-authorization-grant + core)        User's Browser
  |                                |                                                                    |
  |-- POST /device_authorization ->|  (1) クライアント認証/識別（既存の共有パイプライン）                  |
  |   client_id=..&scope=openid    |  (2) grantTypes に device_code URN 登録済みか検証                    |
  |                                |  (3) scope 検証（openid 必須・offline_access ポリシー適用）          |
  |<- 200 {device_code, user_code, |  (4) device_code(256bit)/user_code(20文字種×8) 生成、レコード保存     |
  |   verification_uri,            |                                                                    |
  |   verification_uri_complete,   |                                                                    |
  |   expires_in, interval} -------|                                                                    |
  |                                |                                                                    |
  |  [user_code と verification_uri|                                                                    |
  |   を画面に表示]                 |<---------------- GET /device[?user_code=XXXX-XXXX] ----------------|
  |                                |  (5) user_code 入力フォーム表示（クエリがあれば事前入力）             |
  |-- POST /token (polling) ------>|<---------------- POST /device (user_code) -------------------------|
  |   grant_type=urn:ietf:params:  |  (6) user_code 正規化・照合。OPセッション無ければログインフォーム     |
  |     oauth:grant-type:          |<---------------- POST /device/login (credentials) -----------------|
  |     device_code                |  (7) 認証成功でOPセッション確立、承認画面表示                         |
  |   device_code=...              |     （client名・scope・user_code 再表示 = §5.4 対策）                |
  |   client_id=...                |<------ POST /device/approve (approve/deny + CSRF + binding cookie)|
  |<- 400 {error:                  |  (8) レコードを approved/denied に更新、consent 記録                  |
  |   authorization_pending} ------|                                                                    |
  |-- POST /token (再ポーリング) -->|  (9) approved を検出、レコードを atomic に consume                    |
  |<- 200 {access_token, id_token, |      アクセストークン + ID トークン（+ 条件付き refresh token）発行    |
  |   token_type, expires_in,      |                                                                    |
  |   scope} ----------------------|                                                                    |
```

## 入出力

### デバイス認可リクエスト（RFC 8628 §3.1） — `POST /device_authorization`

- `Content-Type: application/x-www-form-urlencoded` 必須・重複パラメータ拒否は既存トークンエンドポイントと同じ共通処理を通す
- クライアント認証: RFC 8628 §3.1「The client authentication requirements of Section 3.2.1 of [RFC6749] apply」。既存の共有認証パイプライン（`extractClientCredentials` → `resolveAuthenticatedTokenClient` → `validateClientAuthMethod` → `verifyClientSecret`）をそのまま利用する。public client（`token_endpoint_auth_method: 'none'`）は `client_id` のみで識別される（既存実装が対応済み）

| パラメータ | RFC 8628 上 | 本機能 |
|---|---|---|
| `client_id` | 認証しない場合 REQUIRED | 既存パイプラインの規則に従う（public は body の `client_id`、confidential は Basic / POST 認証） |
| `scope` | OPTIONAL | **必須かつ `openid` を含むこと**（本 OP のプロファイル制限。非目標参照）。欠落は `invalid_request`、`openid` 欠落は `invalid_scope`。空白区切り・重複除去の扱いは authorize エンドポイントの `validateAuthorizationScope` と同じ規則 |

- クライアント認可: 登録済み `grantTypes` に `urn:ietf:params:oauth:grant-type:device_code` が含まれない場合は `unauthorized_client`（RFC 6749 §5.2 のエラー形式・HTTP 400。認証失敗は既存パイプラインの規則で 401）
- `offline_access` の扱い: `refresh-token` feature が無効、またはクライアントの `grantTypes` に `refresh_token` が無い場合は、この時点で scope から `offline_access` を除去する（OIDC Core 1.0 §11 の「許可条件を満たさない offline_access は無視する」を適用。デバイスフローでは検証 UI の承認画面が明示同意そのものであるため、承認された場合の許可条件は「承認画面での明示承認」とする。`prompt=consent` 相当の事前条件は課さない — 本仕様の設計判断）

### デバイス認可レスポンス（RFC 8628 §3.2）

- ステータス: `200 OK`、`Content-Type: application/json`
- `Cache-Control: no-store` / `Pragma: no-cache` を付与する（RFC 8628 §3.2 に明示規定は無いが、`device_code` はクレデンシャルであり RFC 6749 §5.1 のトークン応答に倣う — 本仕様の設計判断）

```json
{
  "device_code": "GmRhmhcxhwAzkoEqiMEg_DnyEysNkuNhszIySk9eS",
  "user_code": "WDJB-MJHT",
  "verification_uri": "http://localhost:3000/device",
  "verification_uri_complete": "http://localhost:3000/device?user_code=WDJB-MJHT",
  "expires_in": 600,
  "interval": 5
}
```

| フィールド | RFC 8628 上 | 本機能 |
|---|---|---|
| `device_code` | REQUIRED | `generateRandomString(32)`（`packages/core/src/crypto-utils.ts`）による 256bit・URL-safe 文字列 |
| `user_code` | REQUIRED | RFC 8628 §6.1 推奨の base-20 文字種 `BCDFGHJKLMNPQRSTVWXZ` から 8 文字（約 34.5bit）。表示形式は `XXXX-XXXX`（ハイフン区切り）。生成時に `findByUserCode` で既存レコードとの衝突を確認し、衝突時は再生成する（上限 5 回。全て衝突なら 500 — 実際上到達しない） |
| `verification_uri` | REQUIRED | `<issuer>/device` |
| `verification_uri_complete` | OPTIONAL | `<issuer>/device?user_code=XXXX-XXXX`（採用する） |
| `expires_in` | REQUIRED | 既定 600 秒（`deviceAuthorizationConfig.deviceCodeExpiresIn` で変更可） |
| `interval` | OPTIONAL（省略時クライアントは 5 を使う MUST） | 常に返す。既定 5 秒（`deviceAuthorizationConfig.pollInterval` で変更可） |

### 検証 UI（RFC 8628 §3.3）

| ルート | メソッド | 役割 |
|---|---|---|
| `/device` | GET | user_code 入力フォームを表示。クエリ `user_code` があれば入力欄へ事前入力（§3.3.1 `verification_uri_complete` 対応。値は views の既存エスケープ規則に従い HTML エスケープして埋め込む）。このページは認証不要・状態変更なし |
| `/device` | POST | `user_code` を正規化（大文字化・ハイフンと空白除去）して照合。不一致・期限切れ・非 pending は**同一文言のエラー**（区別不能）でフォーム再表示。一致時: **ブラウザバインディングと CSRF トークンをまとめて発行・回転する**（`issueVerificationBinding`。bindingSecret を生成し SHA-256 ハッシュのみレコードへ保存、生値は `HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=<レコード残TTL>` の Cookie `oidc_device_<正規化user_code>` として応答に付与。csrf_token も同時に再生成しレコードへ保存）。その上で OP セッション（`parseSessionId` + `browserSessionStore`）があれば承認画面、無ければデバイス用ログインフォームを表示（どちらのフォームにも csrf_token を埋め込む。csrf_token を埋め込んだ HTML はバインディング Cookie を発行したこの応答と、Cookie 照合を通過した後続応答にしか現れない） |
| `/device/login` | POST | `username` / `password` + hidden の `user_code` / `csrf_token` を受ける。**バインディング Cookie 照合（`validateVerificationBinding`）→ CSRF 照合 → `authenticateUser`（既存の swap point）** の順で検証する。Cookie 不在・ハッシュ不一致は 403（クロスサイトからフォージされた POST は SameSite=Lax の Cookie を運べず、そもそも被害者ブラウザは Cookie を保持していない — ログイン CSRF 対策）。成功時は login ルートと同じ手順で OP セッションを確立（`browserSessionStore.set` + `buildSessionCookie`）し承認画面を表示。失敗はレコード単位で計数し、`maxLoginAttempts`（既定 5）超過でレコードを `denied` に遷移させる |
| `/device/approve` | POST | `user_code` + `csrf_token` + `decision`（`approve` / `deny`）を受ける。OP セッション必須・バインディング Cookie 照合・CSRF 照合の全てを要求する。`approve` でレコードを `approved`（subject / authTime / approvedScope / grantId を記録）、`deny` で `denied` に更新し、完了画面（「デバイスに戻ってください」）を表示。完了応答でバインディング Cookie を削除する（`Max-Age=0`） |

- 承認画面には **client 名（client_id）・要求 scope・入力された user_code** を再表示する（RFC 8628 §5.4 リモートフィッシング対策: ユーザーがデバイス画面のコードと突き合わせて確認できるようにする）
- **ブラウザバインディングが CSRF 防御の主役である**。user_code はフロー開始者（= 攻撃者になり得る主体）が設計上必ず知っている識別子なので、user_code から辿れるレコードに紐づけただけの CSRF トークンは、攻撃者自身が `POST /device` で取得できてしまい防御にならない（既存 transaction-binding の設計コメントが指摘する「識別子を知るだけの第三者が csrf_token を読める」問題そのもの）。そこで `POST /device` の照合成功時に bindingSecret（`generateRandomString(32)`）を発行し、生値をブラウザだけが持つ HttpOnly Cookie に、SHA-256 ハッシュのみをレコードに保存する（ストア漏洩で Cookie を再構成できない — transaction-binding と同じ性質）。`/device/login` と `/device/approve` は Cookie の生値がレコードのハッシュと一致しない限り実行されない。フォージされたクロスサイト POST は被害者ブラウザの Cookie を運べない（SameSite=Lax）うえ、そもそも被害者ブラウザは当該レコードの Cookie を保持していないため、トークン秘匿に依存せず遮断できる
- **バインディングは feature フラグに依存せず常時有効とする**（optional の `transaction-binding` とは独立）。authorize フローの transaction_id は通常秘匿されるためバインディングは追加ハードニング（opt-in）でよいが、device フローの user_code は開始者に既知であることが前提のため、ブラウザバインディングが唯一実効的な CSRF 防御でありベースライン要件となる。代償として curl での手動フロー実行には UI 3 ステップ（`POST /device` 以降）で cookie jar（`-c` / `-b`）が必要になる。この判断と手順は理解資料・docs に明記する
- bindingSecret と csrf_token は `POST /device` の照合成功ごとにペアで回転する（last-writer-wins）。別ブラウザが同じ user_code で `POST /device` すると先のブラウザのバインディングは無効になるが、user_code を知る者はレコードの承認 / 拒否を左右できるという RFC 8628 のモデルを変えるものではない（機能ではなく制約として理解資料に記載）
- 承認 / 拒否は一方向遷移とする。`approved` / `denied` になったレコードは検証 UI から再度操作できない（user_code 照合の時点で非 pending は「無効なコード」扱い）
- 承認時、既存 consent ルートと同様に `consentStore` へ同意を記録する（subject × clientId × approvedScope）。以後の Authorization Code Flow で同意画面がスキップされる挙動が既存機構のまま成立する
- views 契約に `deviceVerificationPage`（user_code 入力）/ `deviceLoginPage`（デバイス用ログイン）/ `deviceApprovalPage`（承認）/ `deviceCompletedPage`（完了）を追加する。既存の `loginPage` / `consentPage` と同じく `views.ts` テンプレートの差し替え可能な関数として feature 有効時のみ生成する

### トークンリクエスト（RFC 8628 §3.4） — 既存 `POST /token` への分岐

| パラメータ | RFC 8628 上 | 本機能 |
|---|---|---|
| `grant_type` | REQUIRED（URN 固定） | `urn:ietf:params:oauth:grant-type:device_code` のとき本機能へ分岐 |
| `device_code` | REQUIRED | 必須。欠落は `invalid_request` |
| `client_id` | 認証しない場合 REQUIRED | 既存共有パイプラインの規則に従う |

- 分岐位置は Token Exchange と同じく「クライアント認証の後・core の `validateGrantTypeSupported` の前」。分岐内で応答を返し切り、標準 grant へフォールスルーしない
- クライアント認可: 認証済みクライアントの `grantTypes` に URN が無ければ `unauthorized_client`
- `device_code` に対応するレコードが存在しない場合は `invalid_grant`。レコードの `clientId` と認証済みクライアントが一致しない場合も `invalid_grant`（RFC 8628 §3.4: device_code は発行先クライアントに紐づく。エラー文言はどちらも同一とし、他クライアントのコード実在性を漏らさない）

### トークンエンドポイントの状態応答（RFC 8628 §3.5）

分岐内の判定順序（上から評価し、最初に該当したものを返す）:

1. **期限切れ**（`now >= expiresAt`）: `expired_token`。レコードを削除する
2. **ポーリング過速**（前回ポーリングから `interval` 秒未満）: `slow_down`。レコードの `interval` を +5 秒に更新して保存する（RFC 8628 §3.5: 「the interval MUST be increased by 5 seconds for this and all subsequent requests」のサーバー側追随）。`lastPolledAt` を更新する
3. **pending**: `authorization_pending`。`lastPolledAt` を更新する
4. **denied**: `access_denied`。レコードを削除する
5. **approved**: トークン発行。レコードは `consume`（atomic な取得+削除）で回収し、`device_code` を単回使用にする

- エラーは RFC 6749 §5.2 の形式（`{error, error_description}`・HTTP 400・`Cache-Control: no-store` / `Pragma: no-cache`）。`authorization_pending` / `slow_down` / `access_denied` / `expired_token` は RFC 8628 §3.5 が RFC 6749 のエラーレジストリに追加登録した値をそのまま使う

### 成功レスポンス（RFC 8628 §3.5 → RFC 6749 §5.1 / OIDC Core 1.0 §3.1.3.3）

```json
{
  "access_token": "...",
  "id_token": "...",
  "token_type": "Bearer",
  "expires_in": 300,
  "scope": "openid profile"
}
```

- **アクセストークン**: 既存トークンルートと同じ発行系（`accessTokenFormat` 設定に応じ JWT / opaque、`buildAccessTokenPayload` + `buildAccessTokenAudience`）。`aud` は既存ポリシー通り UserInfo エンドポイントを恒久メンバとして含み、発行後 `accessTokenStore` へ保存する。`grantId` はレコード承認時に生成した値を引き継ぐ（revocation の grant 単位失効が既存機構のまま効く）
- **ID トークン**: `approvedScope` は常に `openid` を含む（エンドポイント側で必須化済み）ため常に発行する。組み立ては authorization_code grant と同じヘルパー（`buildIdTokenPayload` / `generateIdToken` / `computeAtHash` / `resolveAcrAmr`）を使い、`auth_time` は承認時に記録した値を用いる。**`nonce` は含めない**（デバイス認可リクエストに nonce パラメータが存在しないため。OIDC Core 1.0 §2 で nonce は「認可リクエストに含まれた場合に必須」のクレームであり、含まれ得ない本フローでは省略が正しい）。`c_hash` も含めない（code が存在しない）
- **リフレッシュトークン**: `refresh-token` feature 有効 かつ `approvedScope` に `offline_access` かつ クライアント `grantTypes` に `refresh_token` がある場合のみ、既存の refresh 発行ヘルパーで発行・保存する。それ以外は発行しない
- ヘッダ: `Cache-Control: no-store` / `Pragma: no-cache`（RFC 6749 §5.1）

## 公開API案（`@maronn-openid-connect/experimental/device-authorization-grant`）

実体は `packages/experimental/src/device-authorization-grant/` に配置し、`packages/experimental/package.json` の `exports` に subpath を追加する。

```text
packages/experimental/src/device-authorization-grant/
  index.ts                              // 再エクスポートのみ
  store.ts                              // DeviceAuthorizationRecord / DeviceAuthorizationStore 契約
  user-code.ts / user-code.test.ts      // 生成・正規化
  device-authorization-request.ts/.test.ts  // バックチャネル処理（ステップ関数 + まとめ関数）
  verification.ts / verification.test.ts    // user_code 照合・承認・拒否・ログイン試行計数
  device-code-grant.ts / device-code-grant.test.ts  // トークン分岐の状態機械
```

```typescript
// 定数
export const DEVICE_CODE_GRANT_TYPE = 'urn:ietf:params:oauth:grant-type:device_code';
export const USER_CODE_CHARSET = 'BCDFGHJKLMNPQRSTVWXZ'; // RFC 8628 §6.1

// user-code.ts
export function generateUserCode(): Promise<string>;          // 'WDJB-MJHT'（表示形式）
export function normalizeUserCode(input: string): string;     // 'wdjb mjht' -> 'WDJBMJHT'（照合キー）

// device-authorization-request.ts
// クライアント認証は生成コード側（既存共有パイプライン）で済ませてから渡す
export function processDeviceAuthorizationRequest(input: {
  params: Record<string, string>;
  client: { clientId: string; grantTypes?: string[] };
  issuer: string;
  expiresIn: number;        // deviceAuthorizationConfig.deviceCodeExpiresIn
  interval: number;         // deviceAuthorizationConfig.pollInterval
  refreshTokenFeatureEnabled: boolean;
  store: DeviceAuthorizationStore;
}): Promise<DeviceAuthorizationResponse>;
export interface DeviceAuthorizationResponse {
  device_code: string; user_code: string;
  verification_uri: string; verification_uri_complete: string;
  expires_in: number; interval: number;
}

// verification.ts（検証 UI ルートが呼ぶステップ関数群）
export function findPendingRecordByUserCode(userCode: string, store: DeviceAuthorizationStore):
  Promise<DeviceAuthorizationRecord | null>;   // 正規化・期限・pending 判定込み。失敗理由は区別しない
export function issueVerificationBinding(record, store):
  Promise<{ bindingSecret: string; csrfToken: string }>;
  // POST /device の照合成功時に呼ぶ。bindingSecret の SHA-256 ハッシュと csrfToken を
  // レコードへ保存（既存値があれば回転）。bindingSecret の生値は Cookie にのみ載せる
export function validateVerificationBinding(record, bindingSecret: string | null): Promise<void>;
  // Cookie の生値をハッシュ化しレコードの bindingHash と照合。不在・不一致は throw
export function validateVerificationCsrfToken(record, csrfToken: string): void; // 不一致は throw
export function recordDeviceLoginFailure(record, store, maxLoginAttempts): Promise<{ canRetry: boolean }>;
export function approveDeviceAuthorization(input: {
  record; store; csrfToken: string; subject: string; authTime: number;
}): Promise<void>;                             // CSRF 照合込み。grantId 生成・approvedScope 確定
export function denyDeviceAuthorization(input: { record; store; csrfToken: string }): Promise<void>;

// device-code-grant.ts（トークン分岐の状態機械）
export function processDeviceCodeGrant(input: {
  params: Record<string, string>;
  client: { clientId: string; grantTypes?: string[] };
  store: DeviceAuthorizationStore;
  now?: Date;                                  // テスト注入用
}): Promise<DeviceCodeGrantResult>;
export interface DeviceCodeGrantResult {       // approved 時のみ返る。他状態は throw
  subject: string; clientId: string; scope: string[];
  authTime: number; grantId: string;
}
export class DeviceAuthorizationError extends Error {
  code: 'authorization_pending' | 'slow_down' | 'access_denied' | 'expired_token'
      | 'invalid_request' | 'invalid_grant' | 'invalid_scope' | 'unauthorized_client';
  errorDescription: string;
  statusCode: 400;
}
```

### ストア契約（store.ts）

```typescript
export interface DeviceAuthorizationRecord {
  deviceCode: string;            // 256bit ランダム。認可コード同等の機密として扱う
  userCode: string;              // 正規化済み照合キー（例 'WDJBMJHT'）
  userCodeDisplay: string;       // 表示形式（例 'WDJB-MJHT'）
  clientId: string;
  scope: string[];               // 要求 scope（offline_access ポリシー適用後）
  status: 'pending' | 'approved' | 'denied';
  createdAt: Date;
  expiresAt: Date;
  interval: number;              // 現在の要求ポーリング間隔（slow_down で +5 される）
  lastPolledAt: Date | null;
  csrfToken: string | null;      // user_code 照合成功時に発行・回転（login / approve の両 POST が要求）
  bindingHash: string | null;    // bindingSecret の SHA-256 ハッシュ。生値はブラウザの HttpOnly Cookie にのみ存在する
  loginAttempts: number;         // デバイス用ログインの失敗回数
  subject?: string;              // approved 時のみ
  authTime?: number;             // approved 時のみ
  approvedScope?: string[];      // approved 時のみ
  grantId?: string;              // approved 時のみ
}

export interface DeviceAuthorizationStore {
  save(record: DeviceAuthorizationRecord): Promise<void>;
  findByDeviceCode(deviceCode: string): Promise<DeviceAuthorizationRecord | null>;
  findByUserCode(userCode: string): Promise<DeviceAuthorizationRecord | null>; // 正規化済みキーで照合
  update(record: DeviceAuthorizationRecord): Promise<void>;
  delete(deviceCode: string): Promise<void>;
  /**
   * 取得と同時に削除する（トークン発行時の単回使用強制）。
   * 取得と削除は atomic でなければならない。atomic でない実装は同一 device_code の
   * 並行リデンプションを許してしまう（PAR store の consume と同じ要件）。
   */
  consume(deviceCode: string): Promise<DeviceAuthorizationRecord | null>;
}
```

- キー（deviceCode / userCode）は外部入力由来の不透明値として扱い、永続ストア実装ではクエリへ文字列連結せず必ずパラメータ化すること（PAR store と同じ注意書きをコメントで残す）
- `lastPolledAt` / `interval` の read-modify-write が atomic でない場合、並行ポーリングでポーリング間隔の強制が甘くなり得るが、認可状態の遷移（pending → approved / denied）と単回使用（consume）が守られていればセキュリティ特性は保たれる。この性質差はコメントに明記する
- **期限切れレコードの掃除**: 期限切れは原則トークンエンドポイントのポーリング時に `expired_token` 応答とともに削除されるが、ポーリングを止めたデバイスのレコードは残る。ストア実装は `expiresAt` から十分な猶予（目安: TTL と同程度）を置いた後に期限切れレコードを自主的に破棄してよい。破棄後のポーリングは `invalid_grant` になるが、クライアントはどちらのエラーでもフローを終了するため相互運用上の問題はない（この猶予の意図はコメントに明記する）

## CLIオプション案

- `--enable device-authorization-grant` で有効化。既定は無効
- `packages/cli/src/features.ts`: `EXPERIMENTAL_FEATURES` に `'device-authorization-grant'` を追加、`OidcFeatureConfig` に `deviceAuthorizationGrant: boolean` を追加、JSDoc の機能一覧を更新
- `packages/cli/src/index.ts`: `withExperimentalPackage`（:28-31）の feature チェック（現在 `!features.par && !features.tokenExchange && !features.jarm`）へ `deviceAuthorizationGrant` を追加する。忘れると `--enable device-authorization-grant` 単独指定時に install guidance へ experimental package が出ない。ヘルプ文字列の experimental 一覧は `EXPERIMENTAL_FEATURES.join` から自動導出されるため追加変更は不要
- 既存 feature との組み合わせ制約なし（`refresh-token` の有無は offline_access の扱いにのみ影響。上記参照）

## 設定値とデフォルト（生成コードの config）

```typescript
/**
 * EXPERIMENTAL — Device Authorization Grant settings (RFC 8628).
 */
export const deviceAuthorizationConfig = {
  deviceCodeExpiresIn: 600, // §3.2 expires_in（秒）
  pollInterval: 5,          // §3.2 interval（秒）
  maxLoginAttempts: 5,      // デバイス用ログインの失敗上限（超過でレコード denied）
};
```

- user_code の文字種（base-20）と長さ（8）は設定値にせず定数とする。エントロピー保証を利用者の設定ミスで壊さないため（変更したい場合は experimental の定数を fork する想定。設定化は昇格時に再検討）

## バリデーション / エラー処理まとめ

| 入力 | 検証 | 失敗時 |
|---|---|---|
| `/device_authorization` クライアント認証 | 既存共有パイプライン | 401（既存 TokenError 規則） |
| `/device_authorization` grantTypes | URN 登録済みか | 400 `unauthorized_client` |
| `/device_authorization` scope | 必須・openid 必須 | 400 `invalid_request` / `invalid_scope` |
| `/device` POST user_code | 正規化後、pending かつ未期限のレコードに一致 | 同一文言でフォーム再表示（理由を区別しない） |
| `/device/login` バインディング | Cookie の bindingSecret がレコードの bindingHash と一致 | 403 エラー画面 |
| `/device/login` CSRF | レコード保存値と一致 | 403 エラー画面 |
| `/device/login` 資格情報 | `authenticateUser` | 失敗計数、上限超過でレコード denied + エラー画面 |
| `/device/approve` セッション | OP セッション必須 | 401 エラー画面 |
| `/device/approve` バインディング | Cookie の bindingSecret がレコードの bindingHash と一致 | 403 エラー画面 |
| `/device/approve` CSRF | レコード保存値と一致 | 403 エラー画面 |
| `/token` device_code | 必須・実在・クライアント一致 | 400 `invalid_request` / `invalid_grant` |
| `/token` 状態 | §3.5 状態機械 | 400 `authorization_pending` / `slow_down` / `access_denied` / `expired_token` |

## セキュリティ要件

- **user_code 総当たり（RFC 8628 §5.1）**: エントロピーは 20^8 ≈ 2.6×10^10。TTL 600 秒・レコード単位の一方向遷移・成功/失敗を区別しない応答文言と組み合わせ、オンライン総当たりを非現実化する（毎秒 100 リクエストを TTL いっぱい続けても成功確率は同時セッション数 N に対し約 6×10^4 × N / 2.6×10^10）。**IP 単位・グローバルのレート制限はデプロイ基盤（Cloudflare / 前段プロキシ）の責務**とし、生成コードのコメントと理解資料に明示する（Cloudflare Workers のようにインスタンス間共有メモリが無い環境では、アプリ内レート制限は成立しないため）
- **device_code の機密性（§5.2）**: 256bit ランダム。認可コードと同等の機密として扱い、ログへ出力しない。トークン発行時の `consume` は atomic な単回使用とし、並行リデンプションを防ぐ
- **リモートフィッシング（§5.4）**: 承認画面に user_code を再表示し、デバイス画面のコードとの一致確認をユーザーに促す文言を必ず表示する。TTL を短く保つ（既定 10 分）
- **セッション盗み見（§5.5）**: user_code はワンタイムであり、承認完了後は同じコードで再操作できない
- **CSRF（承認強要・ログイン CSRF）**: 防御の主役は**ブラウザバインディング Cookie**（検証 UI の節参照）。device フローの脅威モデルでは攻撃者が user_code を知っている（自分で発行できる）ため、レコード紐付き CSRF トークンだけでは攻撃者自身が `POST /device` で有効なトークンを取得でき、(a) 被害者ブラウザに `POST /device/approve` をフォージして自デバイスへトークンを流出させる承認強要も、(b) `POST /device/login` をフォージして被害者ブラウザに攻撃者セッションを確立するログイン CSRF も防げない。バインディング Cookie（HttpOnly / Secure / SameSite=Lax・生値はブラウザのみ・レコードにはハッシュのみ）を `/device/login` と `/device/approve` の前提条件にすることで、トークンや識別子の秘匿に依存せずフォージ POST を遮断する。hidden の csrf_token は多層防御として維持する。バインディングは `transaction-binding` feature と独立に常時有効（理由は検証 UI の節に記載）
- **バインディング・CSRF 照合の比較方法**: レコード側はハッシュのみを保持するため、照合は「入力の SHA-256 ハッシュ vs 保存ハッシュ」の比較になり、比較のタイミング差から保存値の前方一致を積み上げる攻撃は原像計算が必要となり成立しない。csrf_token の直接比較は既存 login / consent の `validateCsrfToken` と同じ水準とし、定数時間比較への統一は既存タスク `tasks/p3-csrf-token-constant-time-comparison.md` の適用範囲に本機能の照合も含める（実装時に同タスクが未着手なら現行水準で実装し、タスク側の対象一覧に本機能を追記する）
- **`/device/login` を経由した資格情報総当たり**: レコード単位の `maxLoginAttempts`（既定 5）はあるが、device グラントを許可されたクライアントを持つ攻撃者はレコードを無制限に発行でき、集計上のパスワード試行回数は無制限になる。これは既存 `/login` ルート（auth transaction を無制限に開始できる）と同一の残存面であり、subject 単位のログイン試行スロットリングは既存タスク `tasks/p2-login-attempt-throttling-subject-scope.md` の責務とする。同タスク実装時に `/device/login` も対象に含めることを本仕様の要件とする（`authenticateUser` swap point を共有するため自然に載る想定）
- **クライアント紐付け**: device_code はデバイス認可時のクライアントに紐づき、トークンリクエストのクライアントと不一致なら `invalid_grant`（文言は不存在時と同一にし、実在性を漏らさない）
- **public client**: RFC 8628 §5.6 の通り、認証しないクライアントの `client_id` は自己申告にすぎない。理解資料で「client_id なりすましは検証 UI にクライアント名として現れるだけで、トークンは user_code を承認したユーザーの明示操作なしに出ない」というモデルを説明する
- **ログ禁止情報**: device_code / user_code（有効期間中）/ CSRF トークン / bindingSecret（Cookie 値）/ 資格情報。エラーメッセージ・error_description にもこれらの値を含めない
- **検証 UI の応答一様性**: user_code 不一致・期限切れ・使用済みは全て同一文言。タイミング差の最小化は必須要件にしない（user_code 照合はストア検索であり、実在コードの推測に使える差は残り得るが、エントロピーと TTL が主防御 — 理解資料に明記）
- **エラー露出**: トークンエンドポイントのエラーは RFC 8628 §3.5 の登録値のみ。内部状態（承認者・subject 等）を error_description に含めない

## プライバシー考慮

- レコードはユーザー承認まで subject を持たない。承認後も TTL 満了またはトークン発行（consume）で消える
- `verification_uri_complete` は user_code を URL クエリに含むため、ユーザー側ブラウザの履歴・中間プロキシのログに残り得る。user_code はワンタイム・短命であること、コード自体は承認操作をした本人以外に価値を持たないことを理解資料に記載する
- UserInfo で返るクレームは既存の scope ベースフィルタのまま（本機能は claims 授受の仕組みを変えない）

## 生成コードからの利用方法 / coreとの境界

- 生成コード（CLI テンプレート）の変更点:
  - `packages/cli/src/frameworks/hono/templates.ts`:
    - 許可メソッドマップ（`OIDC_ENDPOINT_METHODS`）に `/device_authorization: ['POST']`、`/device: ['GET','POST']`、`/device/login: ['POST']`、`/device/approve: ['POST']` を feature 条件付き補間で追加（`parMethod` と同型）
    - `deviceAuthorizationRouteTemplate`（バックチャネル）と `deviceVerificationRouteTemplate`（UI）を新設し、app テンプレートで feature 有効時のみ import / mount。UI テンプレートにはバインディング Cookie の組み立て・削除・抽出ヘルパー（`buildTransactionBindingCookie` 群と同形式。名前は `oidc_device_` プレフィックス）を含める
    - `store.ts` テンプレートに `deviceAuthorizationStore`（in-memory 既定実装 + globalThis レジストリ。`parStore` と同じパターン）を追加
    - token ルートに `deviceCodeDispatchStep` / catch 節（`DeviceAuthorizationError` → RFC 6749 §5.2 形式）を追加（`tokenExchangeDispatchStep` と同型）
    - discovery テンプレートに `device_authorization_endpoint` を追加し、`grant_types_supported` に URN を追加（RFC 8628 §4）
    - `views.ts` テンプレートに device 系 4 ページを追加
    - conformance.test.ts 生成に device フローの契約テストブロックを追加
  - `packages/cli/src/frameworks/web-standard/templates.ts`: hono テンプレート変換への組み込み（express / fastify / nextjs のルート登録。`parRouteTemplate` の組み込みと同じ手順）
- CORS: `/device_authorization` は `/token` `/par` と同じ protectedCors。`/device` 系 UI ルートはブラウザ直接遷移でありCORS 対象外（既存 login / consent と同じ扱い）
- 依存方向（必須遵守）:

```text
packages/core ──X──> packages/experimental（import禁止・coreの必須機能にしない）
packages/cli  ─────> @maronn-openid-connect/experimental（許可・生成コードの依存として明示）
@maronn-openid-connect/experimental ─────> @maronn-openid-connect/core（許可）
```

- core は無変更。experimental は core から `TokenError` / `generateRandomString` 等の公開 API のみを import する
- Experimental 機能間（par / token-exchange / jarm）とコードを共有しない。必要な小物（ランダム生成等）は core 公開 API か機能内実装で賄う（リポジトリ方針: 機能単位の独立性優先・重複許容）

## テスト計画

### 単体テスト（packages/experimental）

- `user-code`: 文字種が `BCDFGHJKLMNPQRSTVWXZ` のみで 8 文字であること / 表示形式が `XXXX-XXXX` であること / `normalizeUserCode` が小文字・空白・ハイフンを吸収すること
- `device-authorization-request`: scope 欠落 `invalid_request` / openid 欠落 `invalid_scope` / grantTypes 未登録 `unauthorized_client` / refresh 無効時に offline_access が除去されること / 応答 6 フィールドの値（verification_uri 組み立て含む）
- `verification`: 未知・期限切れ・非 pending の user_code が null になること / `issueVerificationBinding` が bindingHash と csrfToken をペアで保存し、再発行で両方回転すること / `validateVerificationBinding` が正しい bindingSecret を受理し、不在・不一致・回転前の旧値を拒否すること / CSRF 照合 / ログイン失敗計数と上限超過での denied 遷移 / 承認で subject・authTime・approvedScope・grantId が確定すること / 拒否遷移
- `device-code-grant`: §3.5 状態機械の全分岐（expired_token → 削除 / slow_down → interval+5 / authorization_pending / access_denied → 削除 / approved → 結果返却）/ device_code 欠落・未知・クライアント不一致 / consume 後の再リクエストが invalid_grant / `now` 注入による境界（expiresAt ちょうど・interval ちょうど）

### 結合テスト（conformance.test.ts — packages/cli の生成コードを更新）

- feature 有効時: discovery に `device_authorization_endpoint` と grant URN が現れること（値は具体値で固定）
- `POST /device_authorization` の成功応答（フィールド・Cache-Control）と各エラー
- ハッピーパス通し: device_authorization → `GET /device` → `POST /device` → `POST /device/login` → `POST /device/approve` → `POST /token` 成功（access_token / id_token / scope を検証。id_token の auth_time・aud・nonce 不在を検証）→ そのトークンで UserInfo 成功（UI ステップはバインディング Cookie を持ち回す）
- バインディング: `POST /device` 照合成功応答の Set-Cookie 属性（`HttpOnly; Secure; SameSite=Lax; Path=/` と Max-Age）を固定値で検証 / バインディング Cookie 無しの `POST /device/login`・`POST /device/approve` が 403 になり状態が変化しないこと（有効な csrf_token を添えても通らないこと = トークン単独では防御にならない設計の検証）/ `POST /device` 再実行で旧 bindingSecret・旧 csrf_token が無効化されること / 完了応答で Cookie が `Max-Age=0` で削除されること
- ポーリング系: 承認前 `authorization_pending` / interval 内連打で `slow_down`（以後 interval が +5 されること） / 拒否後 `access_denied` / 期限後 `expired_token` / 発行後の再利用 `invalid_grant`
- 別クライアントの device_code 使用が `invalid_grant`
- HTTP メソッド強制（RFC 9110 §15.5.6）の既存ケース表へ `/device_authorization`（`Allow: POST`）・`/device`（`Allow: GET, POST`）・`/device/login`・`/device/approve`（`Allow: POST`）を feature 有効時のみ追加する（`OIDC_ENDPOINT_METHODS` への登録と対で検証）
- feature 無効時: `/device_authorization` が存在しない（404 系）こと・token の URN が `unsupported_grant_type` のままであること・discovery にメタデータが出ないこと（既存挙動の不変確認）

### E2E（tests/e2e — Playwright）

デバイス役は新規アプリファイルではなく、既存の E2E 専用クライアント `tests/e2e/apps/client.mjs`（Node 組み込みのみの HTTP サーバー。experimental 機能ごとに `/start-*` ルートを足す既存パターン: `/start-par` / `/start-exchange` / `/start-jarm`）へルートを追加して実装する:

- `/start-device`: `POST /device_authorization` を実行し、`user_code` / `verification_uri_complete` をテストへ返しつつ、バックグラウンドで `interval` を遵守した `POST /token` ポーリングを開始する
- `/device-result`: ポーリングの終了状態（トークン取得 / `access_denied` / `expired_token` / 進行中）をテストが取得するためのルート
- spec ファイルは `tests/e2e/specs/device-authorization-grant.spec.ts` を新設する（`pushed-authorization-requests.spec.ts:26` の discovery 自己スキップパターンを踏襲）
- 前提: `samples/*/package.json` の `generate` スクリプトへ `--enable device-authorization-grant` を追加してサンプルを再生成する（`playwright.config.ts` の webServer が生成済みサンプル OP を起動する既存構成のまま）
- シナリオ:
  - Playwright の実ブラウザで `verification_uri_complete` を開き、事前入力された user_code で照合 → ログイン → 承認 → デバイス役がトークン取得 → UserInfo 到達
  - ブラウザで拒否 → デバイス役が `access_denied` を受ける

### 相互運用性

- 応答フィールド名・エラーコードは RFC 8628 の登録値のみを使い、curl での手動フロー実行手順を docs に記載する（検証 UI の 3 ステップは cookie jar `-c` / `-b` を使う手順として記載する。外部クライアントライブラリとの接続検証は実装フェーズの任意項目とし、完了条件にしない）

## ドキュメント要件

- `packages/experimental/README.md` の機能一覧表に `device-authorization-grant` 行を追加
- `docs/library-document/src/content/docs/experimental/device-authorization-grant.md` を新規作成（par.md / token-exchange.md と同じ構成: 概要・有効化方法・エンドポイント・設定値・curl での試し方・制限事項）
- CLI の `--enable` 一覧（README / ヘルプ文字列）を更新
- 生成コード内コメントに「EXPERIMENTAL・API 不安定・レート制限はデプロイ基盤の責務」を明示

## Changeset要件

- `packages/experimental/src` の変更に changeset を**手で書かない**（CI が patch を自動生成する。CLAUDE.md / RELEASE.md の規約）
- `packages/cli` の変更には minor の changeset を手で追加する（新 feature フラグの追加）
- `packages/core` は無変更のため changeset 不要

## 実装順序

実装 Routine は次の順で進める。各ステップの検証方法は「完了条件」の対応番号を参照する:

1. `packages/experimental/src/device-authorization-grant/` の実装と単体テスト（`user-code` → `store` → `device-authorization-request` → `verification` → `device-code-grant` の順。完了条件 3 の単体分）
2. `packages/experimental/package.json` に `exports["./device-authorization-grant"]` を追加（既存 3 機能と同型）
3. `packages/cli/src/features.ts` へ feature 追加・`packages/cli/src/index.ts` の `withExperimentalPackage` の feature チェックへ追加（CLI オプション案の節参照）
4. テンプレート変更（共有 `hono/templates.ts`）: `OIDC_ENDPOINT_METHODS` エントリ → `deviceAuthorizationStore` → バインディング Cookie ヘルパー → `deviceAuthorizationRouteTemplate` / `deviceVerificationRouteTemplate` → views 4 ページ → token ルートの `deviceCodeDispatchStep` → discovery → conformance テンプレート（完了条件 1・5・7・8）。続けて `web-standard/templates.ts` への組み込み（express / fastify / nextjs のルート登録。`parRouteTemplate` の組み込みと同じ手順）
5. `--enable device-authorization-grant` なし生成のバイト同一確認（完了条件 2。変更前後の CLI で同一設定の生成物を diff する。サンプルが使う `--enable par --enable token-exchange --enable transaction-binding --enable jarm` の組み合わせでも確認する）
6. `samples/*/package.json` の `generate` スクリプトへ `--enable device-authorization-grant` を追加してサンプル再生成 → E2E（tests/e2e。完了条件 3 の E2E 分）
7. ドキュメント・changeset（changeset は CLI のみ minor を手書き。experimental は CI 自動生成のため作らない。完了条件 6）

## 完了条件

1. `--enable device-authorization-grant` で生成した OP（hono / express / fastify / nextjs）が本仕様のフローを完走し、生成された conformance.test.ts が全て通る
2. feature 無効で生成した OP の出力・挙動が本機能追加前と完全に一致する（既定オフの不変性）
3. 上記テスト計画の単体・結合・E2E が実装され、`pnpm test` と E2E がグリーンである
4. `packages/core` に差分がない
5. discovery・エラーコード・応答フィールドが RFC 8628 の登録値と一致する
6. ドキュメント要件・Changeset要件を満たす
7. ログに device_code / user_code / CSRF トークン / bindingSecret が出力されない
8. バインディング Cookie 無しでは `/device/login` `/device/approve` のいかなる状態変更も起きないことがテストで保証される

## 未解決事項

- なし（設定値の既定・UI ページ構成・ID トークンのクレーム方針は本仕様で確定済み。実装時に判明した齟齬は review-log に追記して扱いを決める）

## 将来の昇格考慮

- grant ディスパッチは core `validateTokenRequest` の grant ハンドラ追加として自然に昇格できる（Token Exchange と同じ経路）
- `DeviceAuthorizationStore` は core の resolver / store 契約群への編入時に、`update` を細分化した意図明示メソッド（`markApproved` 等）へ再設計する余地がある
- user_code の文字種・長さの設定化、`verification_uri_complete` の QR 提示、CIBA との UI 共通化は昇格検討時の論点として残す
