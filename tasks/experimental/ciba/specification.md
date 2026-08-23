# Experimental機能仕様書: OpenID Connect Client-Initiated Backchannel Authentication (CIBA) — Poll Mode

- **機能名**: OpenID Connect Client-Initiated Backchannel Authentication Flow（CIBA）Poll モード
- **feature-id**: `ciba`
- **準拠仕様**: OpenID Connect Client-Initiated Backchannel Authentication Flow - Core 1.0（Final, 2021-09-01）
- **作成日**: 2026-08-08
- **ステータス**: `state.yaml` を参照

## 概要

ユーザーが操作していないデバイス（consumption device: 店頭端末・コールセンターのオペレーター画面・スマートスピーカー等）が、ユーザー識別ヒント（`login_hint`）だけを添えて OP にバックチャネルで認証を依頼し、ユーザーは**自分の手元のデバイス（authentication device）**で承認する。consumption device はトークンエンドポイントをポーリングしてトークンを受け取る（CIBA Core 1.0, Poll モード）。

追加されるのは次の 3 面で、いずれも Device Authorization Grant（実装済み）で実証済みのパターンに載る:

1. **バックチャネル認証エンドポイント**（バックチャネル・新規）: `POST /backchannel_authentication`。クライアントが `login_hint` を提示して `auth_req_id` / `expires_in` / `interval` を取得する（CIBA §7）
2. **認証デバイス UI**（フロントチャネル・新規）: `GET /ciba` 等。ユーザーが自分のブラウザで OP にログインし、自分宛の保留中認証リクエスト（クライアント名・scope・`binding_message`）を確認して承認 / 拒否する。CIBA Core はこのチャネルの実現方法を仕様の対象外としており（§7.1「The mechanism ... is outside the scope」）、本機能は「OP がホストするブラウザ UI」として実装する
3. **トークンエンドポイントの grant ディスパッチ**（既存エンドポイントへの分岐追加）: `grant_type=urn:openid:params:grant-type:ciba` を experimental ハンドラへ分岐し、状態に応じて `authorization_pending` / `slow_down` / `access_denied` / `expired_token` / トークン発行を返す（CIBA §10.1 / §11）

Device Authorization Grant との構造対比: Device Flow は「ユーザーが user_code を書き写して自ら OP に来る」のに対し、CIBA は「クライアントがユーザー識別子を提示し、OP がユーザー側の承認を待つ」。ポーリング型トークン取得・承認 UI・grant ディスパッチという 3 部品は同型で、起点（ユーザー起点 vs クライアント起点）と識別手段（user_code vs login_hint）が異なる。

## 採用理由（候補評価）

JARM サイクル（2026-08-02〜04）と Device Authorization Grant サイクル（2026-08-05〜07）の候補評価で、CIBA は「認証デバイスへの通知チャネル（ping / push）またはポーリング + 帯域外認証のシミュレーションが必要で、隔離規模を超える」として 2 度見送られ、次サイクル以降の候補として明示的に残されてきた。Device Authorization Grant の実装が main に入った現在（`tasks/experimental/done/device-authorization-grant/`）、見送り理由だった 3 部品すべてに実装済みの先例がある:

- ポーリング型 grant ディスパッチ → `packages/cli/src/frameworks/hono/templates.ts:4002`（deviceCodeDispatchStep）
- バックチャネルエンドポイント → PAR / device_authorization エンドポイントで 2 度実証
- 承認 UI（OP セッション + CSRF + views 契約）→ `/device` 検証 UI で実証

Poll モードに限定すれば「帯域外通知チャネル」は不要になり（承認結果はポーリングでのみ伝わる）、残る新規要素は「login_hint → ユーザー解決」の resolver 契約 1 つに絞られる。

| 観点 | 評価 |
|---|---|
| プロジェクト関連性 | 「コールセンター / 店頭端末 / 音声デバイスからユーザーのスマホ承認でログインさせたい。CIBA で自分の要件が実現できるか」は FAPI 文脈も含め PoC 開発者の典型的検証テーマ。CIBA Core 1.0 は OpenID Foundation の Final Specification（2021-09-01） |
| Experimental隔離の妥当性 | 新規エンドポイント 2 面（バックチャネル + UI）は既存ルートに触れず追加でき、トークンエンドポイントは Token Exchange / Device Grant と同型の「core の grant_type 検証より前の分岐」1 箇所のみ。既存 grant のデフォルト挙動を一切変えない |
| core無変更 | 可能。core の `validateGrantTypeSupported` は未知 URN を `unsupported_grant_type` で拒否するが、生成コードが分岐を core のこのステップより前に置く（deviceCodeDispatchStep と同型）。クライアント認証は core の共有パイプライン（`extractClientCredentials` → `resolveAuthenticatedTokenClient` → `validateClientAuthMethod` → `verifyClientSecret`、すべて `packages/core/src/index.ts` 公開済み）をそのまま利用。`auth_req_id` 生成は `generateRandomString`（`packages/core/src/crypto-utils.ts:65`、Base64URL 出力）を再利用 |
| CLI `--enable` 提供 | 可能。`packages/cli/src/features.ts` の `EXPERIMENTAL_FEATURES` に `ciba` を追加する |
| 一次資料の成熟度 | CIBA Core 1.0 は Final。Authlete / Keycloak / ForgeRock 等の実装実績があり、FAPI-CIBA プロファイルによる Conformance テストも存在する |
| セキュリティ影響 | 新規 UI があるが Device Grant で確立した対策（OP セッション必須・CSRF・レコード単位スロットリング）を継承。CIBA 固有の脅威（クライアント起点の未承諾リクエスト送信・login_hint によるユーザー列挙）は §7.1 / §13 / セキュリティ考慮の節で仕様段階から対策を固定する。`redirect_uri` が登場しないためリダイレクト系攻撃面は増えない |
| テスト可能性 | バックチャネルとトークンポーリングは HTTP レベルで完結。UI はフォーム POST の HTML なので conformance.test.ts（fetch ベース）と Playwright E2E の両方で検証可能 |
| 実装規模 | 中〜やや大（Device Grant と同程度）。新規ルート 1 + UI ルート 1 + views 追加 + token 分岐 + discovery + conformance。テンプレート実体は hono 1 系統（web-standard 変換で express / fastify / nextjs に流用） |
| 将来の昇格 | grant ディスパッチは core の grant ハンドラ追加として、エンドポイントは core のステップ関数群としてそのまま昇格できる。`backchannel_authentication_endpoint` 等のメタデータ（CIBA §4）も既存 discovery 機構に乗る |
| 既存機能との重複 | なし。Device Grant とは起点と識別手段が異なる（上記対比）。`tasks/T-019-dpop.md`（DPoP）は sender-constrained token で目的が異なる |
| 利用者の検証価値 | IdaaS で CIBA を試すには FAPI 対応プランや専用設定が必要なことが多く、「クライアント起点の承認 UX が自分のプロダクトで成立するか」「binding_message はどう見えるか」を手元で最速検証できる価値が高い |

RAR（RFC 9396）は authorize / consent / token / introspection の複数層に跨がるため隔離性が劣る判断が前々サイクルから変わらない。JAR（Request Object）は core の `request-object.ts` として実装済みであり experimental の対象ではない。

## Experimentalにする理由

- 認証デバイス UI（保留中リクエスト一覧・承認画面）の画面構成と views 契約が利用者フィードバックで変わり得るため、安定するまで隔離したい
- `login_hint` → ユーザー解決の resolver 契約（`CibaUserResolver`）は、利用者のユーザーストア設計（メールアドレス / 電話番号 / 内部 ID）に依存して形が変わる可能性が高い
- Poll モード限定・`login_hint` 限定という初期スコープを、将来 ping モードや `id_token_hint` 対応へ広げるとき、公開 API（`processBackchannelAuthenticationRequest` の引数形状・ストア契約）に破壊的変更が入り得る

## 非目標（Non-goals）

- **Ping / Push モード（CIBA §10.2 / §10.3）**: クライアント通知エンドポイントへの callback 送信（SSRF 面の管理・`client_notification_token` の検証）が必要になり隔離規模を超える。discovery の `backchannel_token_delivery_modes_supported` は `["poll"]` のみを広告し、クライアント登録の `backchannelTokenDeliveryMode` に `poll` 以外が設定されたクライアントのリクエストは `unauthorized_client` で拒否する。`client_notification_token` パラメータは Poll モードでは意味を持たないため、送られてきても無視する（設計判断。CIBA §7.1 では Ping/Push 登録時のみ REQUIRED）
- **`id_token_hint` / `login_hint_token` によるユーザー識別（CIBA §7.1）**: 初期スコープは `login_hint` のみ。`id_token_hint` は core の `validateIdTokenHint`（`packages/core/src/id-token.ts:276`）が exp 切れを拒否する設計（同 365-372 行）で、CIBA の再認証ユースケース（期限切れ ID トークンをヒントに使う）には exp 検証を緩和した別バリアントが必要になるため、将来拡張として記録する。`login_hint_token` は CIBA Core がフォーマットを標準化していない（§7.1「is out of scope of this specification」）。これらのヒントのみが提示された場合は固定文言の `invalid_request` を返す（設計判断: §13 の `unknown_user_id` は「ヒントからユーザーを特定できない」場合の語彙であり、ヒント種別自体の非対応は malformed 系の `invalid_request` として扱う。discovery に対応ヒント種別を広告するメタデータは CIBA Core に存在しないため、README と生成コードコメントに明示する）
- **署名付き認証リクエスト（CIBA §7.1.1 Signed Authentication Request）**: `request` パラメータは受け付けず、送られてきた場合は `invalid_request` を返す。discovery の `backchannel_authentication_request_signing_alg_values_supported` は出力しない（OPTIONAL）
- **`user_code` パラメータ（CIBA §7.1.2 / §14）**: ユーザーごとの秘密コードで未承諾リクエストを抑止する仕組みだが、ユーザーごとの秘密の登録・保管ストアが別途必要になる。discovery の `backchannel_user_code_parameter_supported` は出力しない（省略時 false が仕様の既定値）。リクエストに `user_code` が含まれても無視する。未承諾リクエスト対策は認証デバイス UI 側の設計（後述のセキュリティ要件）で担う
- **FAPI-CIBA プロファイル**: 本機能は CIBA Core 1.0 のみを対象とする。FAPI-CIBA の追加要件（署名必須・JARM 等）は対象外
- **OAuth 単体（`openid` scope なし）のバックチャネル認可**: 本 OP のプロファイル制限（`scope` 必須かつ `openid` 必須）を Device Grant と同様に課す。CIBA は OIDC 拡張であり `openid` scope を含むリクエストが前提（§7.1）
- **acr の強制**: `acr_values` は受理して advisory として扱い、発行 ID トークンの acr/amr は既存の `acrResolver` 機構で解決する（Device Grant と同じ扱い）。要求 acr を満たさない場合の拒否は行わない
- **プッシュ通知による認証デバイスへの能動通知**: 認証デバイス UI はユーザーが自ら訪れる pull 型とする。実運用の CIBA はスマホアプリへのプッシュ通知が典型だが、通知基盤は本ライブラリの範囲外。UI を差し替えれば通知型に載せ替えられる構造（approve / deny のロジックを公開 API として提供）にする

## ユースケース / 想定利用者

- コールセンター・店頭端末で「オペレーターがユーザーの電話番号を入力 → ユーザーのスマホで承認」という UX が自分の要件で成立するかを検証する開発者
- 音声デバイス・キオスク等、ユーザー入力が制約されるデバイスからの認可を PoC する開発者
- FAPI-CIBA 導入を見据え、まず素の CIBA Core のフローを手元で理解・検証したい開発者

## プロトコルフロー

```text
Client (consumption device)     OP (生成コード + experimental/ciba + core)                 User's Browser (authentication device)
  |                                  |                                                        |
  |-- POST /backchannel_authentication ->                                                     |
  |   scope=openid&login_hint=user1  |  (1) クライアント認証（既存の共有パイプライン）          |
  |                                  |  (2) 公開クライアント（auth method none）を拒否          |
  |                                  |  (3) grantTypes に CIBA URN 登録済みか検証               |
  |                                  |  (4) ヒント検証（login_hint のみ・ちょうど 1 つ）        |
  |                                  |  (5) login_hint → subject 解決（CibaUserResolver）       |
  |                                  |  (6) scope / binding_message / requested_expiry 検証     |
  |                                  |  (7) auth_req_id(256bit) 生成、レコード保存              |
  |<- 200 {auth_req_id, expires_in,  |                                                        |
  |   interval} --------------------|                                                        |
  |                                  |                                                        |
  |-- POST /token (polling) -------->|<--------------- GET /ciba ------------------------------|
  |   grant_type=urn:openid:params:  |  (8) OP セッション無ければログインフォーム表示            |
  |     grant-type:ciba              |<--------------- POST /ciba/login (credentials) ---------|
  |   auth_req_id=...                |  (9) 認証成功で OP セッション確立                        |
  |<- 400 {error:                    | (10) セッション subject 宛の保留中リクエスト一覧表示      |
  |   authorization_pending} --------|      （client名・scope・binding_message = §7.1 の対）    |
  |                                  |<------ POST /ciba/approve (auth_req_id + 決定 + CSRF) --|
  |-- POST /token (再ポーリング) ---->| (11) subject 一致検証、approved/denied に更新、consent 記録|
  |<- 200 {access_token, id_token,   | (12) approved を検出、レコードを atomic に consume        |
  |   token_type, expires_in, scope} |      アクセストークン + ID トークン（+ 条件付き RT）発行  |
```

## 入出力

### バックチャネル認証リクエスト（CIBA §7.1） — `POST /backchannel_authentication`

- `Content-Type: application/x-www-form-urlencoded` 必須・重複パラメータ拒否は既存トークンエンドポイントと同じ共通処理を通す
- クライアント認証: CIBA §7.1「The Client MUST authenticate to the Backchannel Authentication Endpoint using the authentication method registered for its client_id」。既存の共有認証パイプラインをそのまま利用する。`token_endpoint_auth_method: 'none'` のクライアントは認証を行えないため `unauthorized_client` で拒否する（設計判断: CIBA Core は公開クライアントを明示的に禁止しないが、認証を MUST とする以上 `none` は要件を満たせない）

| パラメータ | CIBA Core 上 | 本機能 |
|---|---|---|
| `scope` | REQUIRED | 必須。`openid` を含まなければ `invalid_scope`。クライアントの許可 scope 検証・`offline_access` ポリシーは既存 authorize / device と同じ規則を適用 |
| `login_hint` | OPTIONAL（3 ヒントのうちちょうど 1 つが REQUIRED） | 対応する唯一のヒント。`CibaUserResolver` で subject へ解決。解決不能なら `unknown_user_id` |
| `id_token_hint` | OPTIONAL（同上） | 非対応。単独で提示されたら固定文言の `invalid_request`（非目標の節を参照） |
| `login_hint_token` | OPTIONAL（同上） | 非対応。同上 |
| `binding_message` | OPTIONAL | 受理。1〜100 文字・制御文字を含まないこと。違反は `invalid_binding_message`。承認画面に表示する（表示時 HTML エスケープ必須） |
| `requested_expiry` | OPTIONAL | 受理。正の整数でなければ `invalid_request`。`[30, authReqIdExpiresIn]` にクランプして採用（CIBA §7.1 は「The server MAY use this value」であり、クランプは設計判断） |
| `acr_values` | OPTIONAL | 受理・advisory（非目標の節を参照）。レコードに保存し承認画面に表示はしない |
| `client_notification_token` | Ping/Push 登録時 REQUIRED | Poll のみ対応のため無視（設計判断） |
| `user_code` | OPTIONAL | 非対応・無視（`backchannel_user_code_parameter_supported` 省略 = false） |
| `request` | 署名リクエスト用 | 非対応。提示されたら `invalid_request` |
| 上記以外 | — | RFC 6749 §3.1 の規則に合わせ無視 |

ヒント規則（CIBA §7.1）: 「it is REQUIRED that the Client provides one (and only one) of the hints」。0 個または 2 個以上は `invalid_request`（§7.2「MUST return an "invalid_request" error」）。

### 検証順序

1. Content-Type / 重複パラメータ（共通処理）
2. クライアント認証（`invalid_client` 401）
3. 認証方式 `none` の拒否（`unauthorized_client` 400）
4. `grantTypes` に `urn:openid:params:grant-type:ciba` が含まれるか（`unauthorized_client` 400）。core の `TokenClientInfo.grantTypes` 既定は `['authorization_code']`（`packages/core/src/token-request.ts:464`）のため、CIBA を使うクライアントは明示登録が必要
5. `backchannelTokenDeliveryMode`（クライアント設定・任意項目）が `poll` 以外なら `unauthorized_client`。未設定は `poll` とみなす（設計判断: 本 OP は poll しか広告しないため、grant 登録を delivery mode 登録と読み替える）
6. `request` パラメータ拒否 → ヒントちょうど 1 つ → 対応ヒント種別（`invalid_request` 400）
7. `scope` 検証（`invalid_scope` 400）
8. `binding_message` 検証（`invalid_binding_message` 400）
9. `requested_expiry` 検証（`invalid_request` 400）
10. `login_hint` → subject 解決（`unknown_user_id` 400）
11. subject の保留中リクエスト数が `maxPendingPerSubject` 以上なら固定文言の `invalid_request`（設計判断: CIBA Core に該当エラーはない。承認 UI の flood 対策）
12. レコード生成・保存 → 200 応答

### 成功応答（CIBA §7.3）

```json
HTTP/1.1 200 OK
Content-Type: application/json
Cache-Control: no-store

{
  "auth_req_id": "<256bit Base64URL>",
  "expires_in": 120,
  "interval": 5
}
```

- `auth_req_id`: REQUIRED。`generateRandomString(32)`（256bit）。CIBA §7.3 のエントロピー要件（最低 128bit・推奨 160bit）を満たし、文字種は Base64URL（`A-Z a-z 0-9 - _`）で許容集合（`A-Z a-z 0-9 . - _`）の部分集合
- `expires_in`: REQUIRED。`requested_expiry` があればクランプ値、なければ `authReqIdExpiresIn`
- `interval`: OPTIONAL だが常に返す（Poll モードの明示）。初期値は `pollingInterval`

### エラー応答（CIBA §13）

RFC 6749 §5.2 の JSON 形。`Cache-Control: no-store` を付す。

| error | HTTP | 発生条件 |
|---|---|---|
| `invalid_request` | 400 | 必須パラメータ欠落・重複・ヒント 0/2 個以上・非対応ヒント種別・`request` 提示・`requested_expiry` 不正・保留数超過 |
| `invalid_scope` | 400 | `openid` 欠落・未許可 scope |
| `unknown_user_id` | 400 | `login_hint` からユーザーを特定できない |
| `unauthorized_client` | 400 | CIBA grant 未登録・認証方式 `none`・delivery mode が poll 以外 |
| `invalid_binding_message` | 400 | `binding_message` の長さ・文字種違反 |
| `invalid_client` | 401 | クライアント認証失敗（core の共有パイプラインが送出） |
| `access_denied` | 403 | 本機能では発生しない（CIBA §13 は認証エンドポイントでの即時拒否用に定義するが、Poll モードの本 OP は受理後にユーザー判断を待つため、拒否は常にトークンエンドポイントの `access_denied` で配信される） |

`expired_login_hint_token` / `missing_user_code` / `invalid_user_code` は対応ヒント・機能が無いため発生しない。`unknown_user_id` の `error_description` は失敗理由（ユーザー不存在 / resolver 例外）を区別しない固定文言とする。

### 認証デバイス UI（CIBA Core 対象外・本機能の設計）

| ルート | 内容 |
|---|---|
| `GET /ciba` | OP セッション（`browserSessionStore`）があればセッション subject 宛の保留中リクエスト一覧（クライアント名・scope・`binding_message`・有効期限）と承認/拒否ボタンを表示し、表示時に各レコードの CSRF トークンを発行・保存。セッションが無ければ**ログイントランザクション**（`CibaLoginTransactionRecord`、TTL 600 秒固定）を新規発行し、`login_transaction_id` と CSRF トークンを hidden フィールドに埋めたログインフォームを表示。bindingSecret の生値は HttpOnly / Secure / SameSite=Lax / Max-Age=600 の Cookie で配り、レコードには SHA-256 ハッシュのみ保存する（`/device` の binding と同じ方式） |
| `POST /ciba/login` | `login_transaction_id` + `csrf_token` + 資格情報。ログイントランザクションを解決し、binding Cookie 生値のハッシュ一致 → CSRF 一致の順で検証（失敗は 403。不存在・期限切れ・不一致を文言で区別しない）。資格情報検証は `authenticateUser` 契約（`/device/login` と同じ swap point）。失敗はトランザクション単位で計数し `maxLoginAttempts` 超過でトランザクション削除 + 429。成功でトランザクションを削除し、**新規発行した** sessionId で OP セッションを確立（リクエストが持ち込んだセッション ID を再利用しない）して一覧へ |
| `POST /ciba/approve` | `auth_req_id` + `decision`（approve/deny）+ CSRF トークン。OP セッション必須・レコードの subject とセッション subject の一致必須・CSRF 一致必須。approve でレコードを `approved` に更新し consent 記録（`grant` / `recordGrant`）と `grantId` 発行、deny で `denied` に更新 |

**承認操作**には Device Flow の `bindingSecret` Cookie に相当する仕組みを設けない（設計判断: Device Flow では user_code しかリンクが無いため Cookie 束縛が要ったが、CIBA の承認は認証済み OP セッションの subject 一致で束縛されており、レコードの CSRF トークンもセッション必須の一覧表示でしか得られない。`auth_req_id` を知っていてもセッションが無ければ承認操作は一切できない）。

**ログインフォーム**にはブラウザ束縛を常時設ける（設計判断: ログイン成功は OP セッションという CIBA 外にも及ぶ状態（SSO / `prompt=none`）を作るため、クロスサイトの偽造 POST で攻撃者アカウントのセッションを被害者ブラウザへ植え付けるログイン CSRF を防ぐ必要がある。フォーム埋め込みトークンだけでは、攻撃者が自分で `GET /ciba` を叩いて有効な `login_transaction_id` + CSRF の対を入手し偽造フォームに埋め込めるため足りない。binding Cookie は被害者ブラウザに存在せず、偽造 POST はハッシュ一致で遮断される。`/device/login` の「セッションを確立するステップは binding で守る」原則と同じ）。ログイン失敗の計数はログイントランザクション単位で行う（既存 `/login`（auth transaction 単位）・`/device/login`（レコード単位）と同じ残存面: トランザクションを再発行すれば集計上の試行回数は無制限。subject 単位のスロットリングは `tasks/p2-login-attempt-throttling-subject-scope.md` の責務）。

### トークンリクエスト（CIBA §10.1, Poll モード） — 既存 `POST /token` への分岐

- `grant_type=urn:openid:params:grant-type:ciba`（REQUIRED）
- `auth_req_id`（REQUIRED）
- クライアント認証は既存の共有パイプライン（分岐より前に実行済み）

処理（CIBA §11 / 状態機械）:

1. `auth_req_id` 欠落 → `invalid_request`
2. レコード不存在 → `invalid_grant`
3. レコードの `clientId` と認証済みクライアント不一致 → `invalid_grant`（§11「invalid or was issued to another Client」。レコードは削除しない）
4. 期限切れ → `expired_token` を返しレコード削除
5. 前回ポーリングから `interval` 未満 → `slow_down` を返し、レコードの `interval` を +5 秒して永続化（§11「the interval MUST be increased by at least 5 seconds for this and all subsequent requests」。過剰ポーリングへ `invalid_request` を返す選択肢（§11 の MAY）は採らず、Device Grant と同じ slow_down 方式に統一する設計判断）。`lastPolledAt` の更新は `slow_down` と `authorization_pending` の 2 経路で行う（他の結果はレコードを削除または consume するため更新対象が残らない。Device Grant 実装 `device-code-grant.ts` の実挙動と同じ）
6. `pending` → `authorization_pending`
7. `denied` → `access_denied` を返しレコード削除（再ポーリングは `invalid_grant`。クライアントは §11 によりどちらでもフローを終了する）
8. `approved` → レコードを atomic に `consume`（単回使用強制）し、トークン発行へ

### トークン応答（成功時）

deviceCodeDispatchStep と同じ発行経路（`buildAccessTokenPayload` / `buildIdTokenPayload` / `generateIdToken` / accessTokenStore 登録 / `Cache-Control: no-store`）。

- `access_token` / `token_type: Bearer` / `expires_in` / `scope` / `id_token`
- `refresh_token`: `refresh-token` feature 有効かつ承認 scope に `offline_access` が含まれ、既存ポリシーを満たす場合のみ（Device Grant と同じ規則）
- ID トークン: `openid` 必須プロファイルのため常に発行。`nonce` なし（CIBA §7.1 に nonce パラメータは存在しない）・`c_hash` なし（code が無い）・`at_hash` あり・`auth_time` は承認時刻・acr/amr は `acrResolver` で解決。Poll モードに固有クレームは無い（`urn:openid:params:jwt:claim:auth_req_id` 等は Push モード専用。CIBA §10.3.1）

### トークンエラー応答（CIBA §11）

RFC 6749 §5.2 の JSON 形・HTTP 400。`authorization_pending` / `slow_down` / `expired_token` / `access_denied` / `invalid_grant` / `invalid_request`。401 はクライアント認証（分岐前の core 処理）のみが返す。

## 公開API案（`@maronn-openid-connect/experimental/ciba`）

```typescript
// 定数
export const CIBA_GRANT_TYPE = 'urn:openid:params:grant-type:ciba';
export const BINDING_MESSAGE_MAX_LENGTH = 100;

// レコードとストア契約
export type CibaStatus = 'pending' | 'approved' | 'denied';

export interface CibaAuthenticationRequestRecord {
  authReqId: string;          // 256bit Base64URL。auth_code 同等の機密として扱う
  clientId: string;
  subject: string;            // login_hint 解決結果（リクエスト受理時点で確定）
  scope: string[];            // offline_access ポリシー適用後
  bindingMessage?: string;
  acrValues?: string;         // advisory 保存のみ
  status: CibaStatus;
  createdAt: Date;
  expiresAt: Date;
  interval: number;           // slow_down のたびに +5
  lastPolledAt: Date | null;
  csrfToken: string | null;   // 一覧表示時に発行・回転
  authTime?: number;          // 承認時のみ
  approvedScope?: string[];   // 承認時のみ
  grantId?: string;           // 承認時のみ（grant 単位失効に使う）
}

export interface CibaAuthenticationRequestStore {
  save(record: CibaAuthenticationRequestRecord): Promise<void>;
  findByAuthReqId(authReqId: string): Promise<CibaAuthenticationRequestRecord | null>;
  /** 認証デバイス UI の一覧用。期限内・pending のみ返す */
  listPendingBySubject(subject: string): Promise<CibaAuthenticationRequestRecord[]>;
  update(record: CibaAuthenticationRequestRecord): Promise<void>;
  delete(authReqId: string): Promise<void>;
  /** 取得と同時に削除（トークン発行時の単回使用強制）。atomic 必須 */
  consume(authReqId: string): Promise<CibaAuthenticationRequestRecord | null>;
}

// ユーザー解決契約（利用者の swap point）
export type CibaUserResolver = (
  loginHint: string,
) => Promise<{ subject: string } | null> | { subject: string } | null;

// クライアント拡張（core 型変更なし。検証順序 5 の delivery mode 判定に使う）
export type CibaClientInfo = TokenClientInfo & {
  backchannelTokenDeliveryMode?: 'poll' | 'ping' | 'push';
};

// バックチャネル認証エンドポイント処理
export interface CibaConfig {
  authReqIdExpiresIn: number;   // 秒。default 120, 範囲 30–600
  pollingInterval: number;      // 秒。default 5, 範囲 1–60
  maxPendingPerSubject: number; // default 10, 範囲 1–100
}

export function processBackchannelAuthenticationRequest(input: {
  params: Record<string, string>;
  client: CibaClientInfo;        // 認証済み。TokenClientInfo の交差型拡張
  store: CibaAuthenticationRequestStore;
  config: CibaConfig;
  resolveUser: CibaUserResolver;
}): Promise<{ auth_req_id: string; expires_in: number; interval: number }>;
// 失敗時 BackchannelAuthenticationError を throw

// ログイントランザクション（ログイン CSRF 防御 + 試行回数計数の錨。/device の binding と同じ方式）
export const CIBA_LOGIN_TRANSACTION_TTL_SECONDS = 600;

export interface CibaLoginTransactionRecord {
  id: string;             // 256bit Base64URL。hidden フィールドで運ぶ
  csrfToken: string;      // 256bit Base64URL。hidden フィールドで運ぶ
  bindingHash: string;    // bindingSecret（Cookie 生値）の SHA-256 Base64URL。生値は保存しない
  loginAttempts: number;
  expiresAt: Date;
}

export interface CibaLoginTransactionStore {
  save(record: CibaLoginTransactionRecord): Promise<void>;
  findById(id: string): Promise<CibaLoginTransactionRecord | null>;
  update(record: CibaLoginTransactionRecord): Promise<void>;
  delete(id: string): Promise<void>;
}

export function createCibaLoginTransaction(
  store: CibaLoginTransactionStore,
): Promise<{ record: CibaLoginTransactionRecord; bindingSecret: string }>;
// bindingSecret 生値は戻り値のみ（生成コードが Cookie に載せる）

export function validateCibaLoginSubmission(input: {
  transactionId: string;
  csrfToken: string;
  bindingSecret: string | null | undefined; // Cookie から
  store: CibaLoginTransactionStore;
}): Promise<CibaLoginTransactionRecord>;
// 不存在・期限切れ・binding 不一致・CSRF 不一致はすべて CibaVerificationError(403)。理由を区別しない

export function recordCibaLoginFailure(
  record: CibaLoginTransactionRecord,
  store: CibaLoginTransactionStore,
  maxLoginAttempts: number,
): Promise<{ canRetry: boolean; remainingAttempts: number }>;
// 上限到達でトランザクションを削除する

export function createInMemoryCibaLoginTransactionStore(): CibaLoginTransactionStore;

// 認証デバイス UI 用ヘルパー
export function listPendingCibaRequests(input: {
  subject: string;
  store: CibaAuthenticationRequestStore;
}): Promise<CibaAuthenticationRequestRecord[]>; // CSRF トークンを発行・保存して返す

export function approveCibaRequest(input: {
  authReqId: string;
  subject: string;              // セッション subject。レコードと不一致なら拒否
  csrfToken: string;
  authTime: number;
  grantId: string;
  store: CibaAuthenticationRequestStore;
}): Promise<CibaAuthenticationRequestRecord>;

export function denyCibaRequest(input: {
  authReqId: string;
  subject: string;
  csrfToken: string;
  store: CibaAuthenticationRequestStore;
}): Promise<void>;
// 失敗時 CibaVerificationError を throw（不存在・subject 不一致・CSRF 不一致・期限切れ）

// トークン grant 処理
export function processCibaGrant(input: {
  params: Record<string, string>;
  client: TokenClientInfo;
  store: CibaAuthenticationRequestStore;
}): Promise<{
  subject: string;
  clientId: string;
  scope: string[];
  authTime: number;
  grantId: string;
}>;
// 失敗時 CibaGrantError を throw

// エラー
export class BackchannelAuthenticationError extends Error {
  code: 'invalid_request' | 'invalid_scope' | 'unknown_user_id'
      | 'unauthorized_client' | 'invalid_binding_message';
  statusCode: 400;
  errorDescription: string;
}
export class CibaVerificationError extends Error { /* UI 層向け */ }
export class CibaGrantError extends Error {
  code: 'authorization_pending' | 'slow_down' | 'expired_token'
      | 'access_denied' | 'invalid_grant' | 'invalid_request';
  statusCode: 400;
  errorDescription: string;
}

// デフォルト実装
export function createInMemoryCibaAuthenticationRequestStore(): CibaAuthenticationRequestStore;
```

`TokenClientInfo` は core 公開型をそのまま使う。`backchannelTokenDeliveryMode` の載せ方（U4、Review 3 で確定）:

- experimental 側は上記 `CibaClientInfo`（`TokenClientInfo` の交差型）を定義し、`processBackchannelAuthenticationRequest` の引数型に使う。core の型変更は行わない
- 生成コード側は既存の `RegisteredClient = ClientInfo & TokenClientInfo & { offlineAccessAllowed?; userinfoSignedResponseAlg?; idTokenSignedResponseAlg? }`（`packages/cli/src/frameworks/hono/templates.ts:511`）の交差メンバーへ `backchannelTokenDeliveryMode?: 'poll' | 'ping' | 'push'` を **`ciba` 有効時のみ**追加する（`exampleClientGrantFields` と同じ条件挿入。無効時バイト同一の完了条件を守る）
- `RegisteredClient` は構造的部分型として `CibaClientInfo` に代入可能なため、生成コードのクライアント resolver の戻り値をそのまま渡せる。交差型でクライアント型を拡張する形は `par-request.test.ts:24`（`ClientInfo & TokenClientInfo`）と `RegisteredClient` 自身に先例がある

## CLIオプション案

- `--enable ciba` で有効化（デフォルト無効）。`packages/cli/src/features.ts` の `EXPERIMENTAL_FEATURES` に `'ciba'` を追加し、`OidcFeatureConfig` に `ciba: boolean` を追加（`EXPERIMENTAL_FEATURE_KEYS` / `DEFAULT_FEATURES` / JSDoc も同時に更新）
- `packages/cli/src/index.ts:28` の `withExperimentalPackage` の feature チェックへ `features.ciba` を追加（experimental パッケージをインストールガイダンスに含める条件。device-authorization-grant 追加時と同じ 1 行）
- 生成物（hono テンプレート起点・web-standard 変換で全フレームワークへ展開）:
  - `routes/backchannel-authentication.ts`: `POST /backchannel_authentication`。共有クライアント認証 → `processBackchannelAuthenticationRequest`。`c.get('cibaUserResolver')` が無ければ生成ユーザーフィクスチャを username で引くデフォルト resolver
  - `routes/ciba-verification.ts`: `GET /ciba` / `POST /ciba/login` / `POST /ciba/approve`。views 契約に `cibaLoginPage` / `cibaPendingRequestsPage` を追加。ログイントランザクションの binding Cookie の発行・読み取りは生成コードの責務（`/device` の binding Cookie ヘルパーと同じ属性: HttpOnly / Secure / SameSite=Lax / Path 限定 / Max-Age=600）
  - token ルートへの `cibaDispatchStep`（deviceCodeDispatchStep と同型・core の `validateGrantTypeSupported` より前）と `CibaGrantError` の catch 分岐
  - discovery への追記: `backchannel_token_delivery_modes_supported: ['poll']` / `backchannel_authentication_endpoint: `${issuer}/backchannel_authentication``（CIBA §4 の REQUIRED 2 項目。OPTIONAL 項目は出力しない）
  - `grant_types_supported` へ `urn:openid:params:grant-type:ciba` を追加
  - storage context: `cibaAuthenticationRequestStore` / `cibaLoginTransactionStore`（いずれもデフォルト in-memory）
  - `ciba.ts`（設定ファイル）: `CibaConfig` の生成と起動時範囲検証
  - conformance.test.ts への CIBA シナリオ追加（`packages/cli` の生成コードを変更する。直接編集しない）
- 既存機能との干渉なし: `ciba` 無効時の生成出力は現行とバイト同一であること（完了条件で検証）
- 実装時の注意: `packages/cli/src/__tests__/par-feature.test.ts` の unknown-feature テストは `'ciba'` を「存在しない機能名」の例として使っている。`EXPERIMENTAL_FEATURES` へ `ciba` を追加すると `resolveFeatures({ enable: ['ciba'] })` が throw しなくなりこのテストが落ちるため、別の未定義名へ差し替えること

## 設定値とデフォルト

| 設定 | デフォルト | 範囲 | 根拠 |
|---|---|---|---|
| `authReqIdExpiresIn` | 120 秒 | 30–600 | ユーザーが手元デバイスで承認するまでの現実的な待ち時間。範囲外は起動時エラー（PAR / Device と同じ方式） |
| `pollingInterval` | 5 秒 | 1–60 | CIBA §7.3 の interval 省略時既定値と同値 |
| `maxPendingPerSubject` | 10 | 1–100 | 承認 UI flood の抑止（設計判断） |
| `maxLoginAttempts`（UI ログイン） | 既存 `/device` UI と同じ値を共有 | — | 生成コードの既存方針に従う。計数の錨はログイントランザクション |
| ログイントランザクション TTL | 600 秒（固定・非設定項目） | — | 既存 auth transaction の TTL / Cookie Max-Age と同値。設定面を増やさない設計判断 |

## バリデーション / エラー処理

「入出力」の節の検証順序・エラー表を正とする。実装は次を守る:

- すべてのエラー応答に `Cache-Control: no-store` を付す
- `error_description` は失敗種別内で固定文言とし、`login_hint` の値・`auth_req_id` の値・レコード有無の内部理由を含めない
- `auth_req_id` / 資格情報 / `login_hint` はログへ出力しない（`login_hint` は PII。CIBA Privacy Considerations 参照）
- UI 層のエラー（CSRF 不一致・subject 不一致・不存在）は同一の汎用エラーページで応答し、`auth_req_id` の有効性を外部から識別できるオラクルにしない

## セキュリティ要件

| 脅威 | 対策 |
|---|---|
| `auth_req_id` の推測・総当たり | 256bit CSPRNG（§7.3 の最低 128bit を超過）。ストアはキーを不透明値として扱い、永続実装ではパラメータ化問い合わせを使う（PAR / Device store と同じ注記） |
| `auth_req_id` 漏洩によるトークン窃取 | トークン取得にはクライアント認証 + レコードの `clientId` 一致が必要（§11 invalid_grant）。`auth_req_id` 単独では何もできない |
| 承認の乗っ取り（他人のリクエストを承認） | 承認操作は認証済み OP セッションの subject とレコード subject の一致が必須。`auth_req_id` を知っていても他人は承認できない |
| CSRF による意図しない承認 | レコード単位 CSRF トークン（一覧表示時発行・使用時検証）。トークンはセッション必須の一覧表示でしか得られないため攻撃者は入手できない。OP セッション Cookie は既存生成コードの属性（HttpOnly / Secure / SameSite=Lax）に従い、クロスサイト POST にはそもそも載らない |
| ログイン CSRF（偽造 POST で攻撃者アカウントの OP セッションを被害者ブラウザに植え付け、以後の SSO / `prompt=none` を汚染） | ログイントランザクションの binding Cookie（生値はブラウザのみ・レコードはハッシュ）+ CSRF トークン。攻撃者が自分で入手した `login_transaction_id` + CSRF の対を偽造フォームに埋めても、被害者ブラウザに binding Cookie が無いため 403（「入出力」の認証デバイス UI の節を参照） |
| `/ciba/login` への資格情報総当たり | ログイントランザクション単位で失敗を計数し `maxLoginAttempts` で打ち切り（トランザクション削除 + 429）。残存面（トランザクション再発行による集計上の無制限）は既存 `/login`・`/device/login` と同一で、subject 単位のスロットリングは既存タスクの責務 |
| 未承諾リクエストによる承認 UI flood・疲労攻撃（§7.1.2 の user_code が想定する脅威） | (1) クライアント認証必須で匿名からは送れない (2) `maxPendingPerSubject` で保留数を制限 (3) UI は pull 型でプッシュ通知が無く、割り込みが発生しない (4) 承認画面にクライアント名・scope・`binding_message` を必ず表示し、拒否ボタンを承認と同等の視認性で置く。残余リスク: 正規登録クライアントの侵害時はユーザーの明示的拒否に依存する（user_code 非対応の受容コスト。README に明記） |
| consumption device と認証デバイスの取り違い（別トランザクションの承認） | `binding_message` を承認画面に表示（§7.1 の視覚的照合）。表示時 HTML エスケープを views 契約の要件とし、conformance テストでエスケープを固定検証 |
| ユーザー列挙（`unknown_user_id` オラクル） | エラーコード自体は仕様の語彙（§13）であり返す。`error_description` は固定文言とし、resolver 例外と不存在を区別しない。クライアント認証必須のため匿名列挙は不可。残余リスク: 登録クライアントは存在確認が可能（仕様上の受容。プライバシー考慮に記載） |
| `binding_message` 経由の UI インジェクション | 長さ・制御文字検証（`invalid_binding_message`）+ 表示時エスケープの二層 |
| ポーリング DoS | `interval` 強制と `slow_down`（+5 秒累積・永続化）。`lastPolledAt` / `interval` の read-modify-write が atomic でない場合の緩みは Device store と同じ注記（認可状態遷移と consume の atomic 性が保たれれば安全特性は維持） |
| `auth_req_id` 再利用（リプレイ） | `consume` の atomic 単回使用。発行後の再ポーリングは `invalid_grant` |
| 期限切れレコードの滞留 | ポーリング時に `expired_token` + 削除。ポーリングが止まったレコードはストア実装が TTL 猶予後に自主破棄してよい（Device store と同じ注記。破棄後は `invalid_grant` になるが相互運用上問題ない） |

## プライバシー考慮

- `login_hint` はユーザー識別子（メール・電話番号・ユーザー名）そのものであり PII。ログ・エラー応答へ含めない。CIBA Privacy Considerations の「static global identifier ... clear privacy implications」を README で利用者に注意喚起する
- `unknown_user_id` による存在確認は登録クライアントに限定される（上記セキュリティ要件）。PoC 用途を超えて運用する場合は resolver 側でレート制限を検討するよう README に記載
- `binding_message` はユーザー環境の画面に表示されるため、機微情報を入れない運用をクライアント側ガイダンスとして README に記載

## 配置案 / CLI生成コードからの利用方法 / coreとの境界

- 実体: `packages/experimental/src/ciba/`（`store.ts` / `backchannel-authentication-request.ts` / `verification.ts` / `ciba-grant.ts` / `errors.ts` / `index.ts` / 各 `.test.ts`）
- 公開: `@maronn-openid-connect/experimental/ciba` の subpath export のみ。ルート再エクスポートはしない
- 他 experimental 機能とコードを共有しない（device-authorization-grant と類似ロジックがあっても重複を許容する方針に従う）
- core 変更なし。core からの import は公開 API（`TokenClientInfo` / `generateRandomString` / エラー基盤等）のみ

```text
packages/core ──X──> packages/experimental（import禁止・coreの必須機能にしない）
packages/cli  ─────> @maronn-openid-connect/experimental（許可・生成コードの依存として明示）
@maronn-openid-connect/experimental ─────> @maronn-openid-connect/core（許可）
```

- デフォルト無効。`--enable ciba` を明示した場合のみ生成物に現れる。core・CLI の既存利用者への破壊的変更なし

## テスト計画

### 単体テスト（`packages/experimental/src/ciba/*.test.ts`、t_wada 流 TDD）

- `processBackchannelAuthenticationRequest`: 正常系（最小 / binding_message / requested_expiry クランプ / acr_values 保存）・ヒント 0/2 個・非対応ヒント種別・`request` 拒否・scope 検証・`openid` 欠落・grant 未登録・auth method none・delivery mode 不一致・binding_message 境界（100 文字 OK / 101 文字 NG / 制御文字 NG）・requested_expiry 非整数/0/負・保留数超過・`auth_req_id` の文字種と長さ
- `approveCibaRequest` / `denyCibaRequest` / `listPendingCibaRequests`: subject 一致・CSRF 検証・期限切れ・状態遷移・consent 記録前提の grantId 受け渡し
- `createCibaLoginTransaction` / `validateCibaLoginSubmission` / `recordCibaLoginFailure`: binding 不一致・CSRF 不一致・不存在・期限切れがすべて同一エラー（403）になること・生値がレコードに保存されないこと・失敗計数と上限到達時のトランザクション削除
- `processCibaGrant`: 状態機械全遷移（pending → authorization_pending、interval 内再ポーリング → slow_down と +5 の永続化、denied → access_denied + 削除、期限切れ → expired_token + 削除、approved → 発行データ返却）・`auth_req_id` 欠落・不存在・クライアント不一致・consume 後の再要求 → invalid_grant
- in-memory store: consume の単回性（並行 consume で 1 つだけ non-null）

### conformance.test.ts（CLI 生成コードで追加。`--enable ciba` 生成 OP への結合テスト）

- discovery に REQUIRED 2 項目と grant_types_supported が出ること（値は具体値で固定）
- バックチャネル認証 → UI ログイン → 承認 → ポーリングでトークン取得の全周
- authorization_pending → slow_down（interval 違反）→ 承認 → 成功の時系列
- 拒否 → access_denied、期限切れ → expired_token
- 別クライアントによるポーリング → invalid_grant、応答の同一性（オラクル化防止）
- binding_message の HTML エスケープ
- ログイン CSRF 防御: binding Cookie を持たない `POST /ciba/login`（有効な `login_transaction_id` + CSRF を持っていても）が 403 になり、セッション Cookie が発行されないこと
- ログイン失敗の計数: 上限到達で 429 になり、同じログイントランザクションで再試行できないこと
- `ciba` 無効時: `/backchannel_authentication` が 404、grant URN が `unsupported_grant_type`、discovery に CIBA 項目が無いこと

### E2E（`tests/e2e`、Playwright）

- consumption device 役のテストクライアント（`tests/e2e/apps` に配置。`samples/*` には置かない）がバックチャネル認証を開始し、Playwright がブラウザで `/ciba` ログイン → 承認、クライアントがポーリングで ID トークンを取得して検証する全周シナリオ
- 拒否シナリオ（access_denied 受領）

## ドキュメント要件

- `packages/experimental/README.md` に `ciba` の節を追加（Poll のみ・login_hint のみ・非目標・残余リスク（user_code 非対応の受容コスト・`unknown_user_id` の存在確認・`login_hint` の PII 性）の明記）
- CLI の `--enable` ヘルプ文言（`features.ts` の JSDoc とヘルプ出力）
- 生成コードコメントに Experimental である旨と API 不安定の警告（既存機能と同じ形式）
- `docs/implementation-guides/experimental/ciba.ja.md` / `ciba.en.md` を作成する（CLAUDE.md の規約。実装しきった時点で必須。掲載コードは抜粋ではなく全文。`device-authorization-grant.ja.md` / `.en.md` の構成を基準とする）

## Changeset要件

- `packages/experimental/src` の変更に changeset を手で書かない（CI が patch を自動生成。CLAUDE.md / RELEASE.md 準拠）
- `packages/cli` の変更には minor の changeset を書く（新機能フラグ追加）

## 実装順序

実装 Routine は次の順で進める。各ステップの検証方法は「完了条件」の対応番号を参照する:

1. `packages/experimental/src/ciba/` の実装と単体テスト（`store` → `errors` → `backchannel-authentication-request` → `verification`（ログイントランザクション含む）→ `ciba-grant` の順。t_wada 流に red → green で進める。完了条件 1）
2. `packages/experimental/package.json` に `exports["./ciba"]` を追加（既存 4 機能と同型）
3. `packages/cli/src/features.ts` へ feature 追加・`packages/cli/src/index.ts:28` の `withExperimentalPackage` へ `features.ciba` を追加。同時に `packages/cli/src/__tests__/par-feature.test.ts:112` の未定義機能名 `'ciba'` を別の未定義名へ差し替える（CLI オプション案の節参照）
4. テンプレート変更（共有 `hono/templates.ts`）: `RegisteredClient` への `backchannelTokenDeliveryMode` 条件追加とクライアントフィクスチャ → storage context（`cibaAuthenticationRequestStore` / `cibaLoginTransactionStore`）→ `ciba.ts` 設定 → `routes/backchannel-authentication.ts` → `routes/ciba-verification.ts` と views 2 ページ → token ルートの `cibaDispatchStep` と catch 分岐 → discovery → conformance テンプレート（完了条件 2・6）。続けて `web-standard/templates.ts` への組み込み（express / fastify / nextjs のルート登録。device の組み込みと同じ手順）
5. `--enable ciba` なし生成のバイト同一確認（完了条件 3。変更前後の CLI で同一設定の生成物を diff する。サンプルが使う既存の `--enable` 組み合わせでも確認する）
6. `samples/*/package.json` の `generate` スクリプトへ `--enable ciba` を追加してサンプル再生成 → `tests/e2e` に承認・拒否シナリオと CD 役テストクライアント（`tests/e2e/apps`）を追加（完了条件 4）
7. ドキュメント（README 節・ヘルプ・実装解説 ja/en）・changeset（CLI のみ minor を手書き。experimental は CI 自動生成のため作らない）・`pnpm review:experimental ciba` でパケット生成（完了条件 5・7）

## 完了条件

1. `packages/experimental/src/ciba/` の単体テストがすべて通る
2. `--enable ciba` で生成した OP に対する conformance.test.ts（全フレームワーク）が通る
3. `ciba` を有効にしない生成出力が変更前とバイト同一である
4. E2E シナリオ（承認・拒否）が通る
5. `pnpm review:experimental ciba` でパケットが生成され `--check` が通る
6. discovery 出力・エラー応答が本仕様の表と一致する
7. ドキュメント要件（`docs/implementation-guides/experimental/ciba.ja.md` / `.en.md` を含む）・Changeset要件を満たす

## 未解決事項

| ID | 内容 | 状態 |
|---|---|---|
| U1 | 認証デバイス UI のログインを既存 `/device` UI のログイン部品と共通化するか、CIBA 専用に複製するか | **確定（Review 3）**: CIBA 専用に複製する。根拠: (1) 完了条件 3（`ciba` 無効時のバイト同一）と device 側の既存回帰期待は、CIBA のテンプレートブロックが device のブロックに一切触れない構成で最も確実に守れる。共通部品への括り出しは device のみ有効な生成出力を変えてしまう (2) 機能単位の独立性と将来の切り出しやすさを優先し、重複排除だけを目的とした共通化はしない方針（experimental の運用方針）に従う (3) views 契約も `cibaLoginPage` / `cibaPendingRequestsPage` として device と別エントリで増える設計であり、テンプレート側だけ共有しても契約は分かれる。experimental パッケージ内も同様に、ログイントランザクション実装を `device-authorization-grant` から import せず `ciba/` 内に持つ（「他 experimental 機能とコードを共有しない」の既定どおり） |
| U2 | `maxPendingPerSubject` 超過時のエラーコード | **確定（Review 2）**: `invalid_request` 400 + 固定文言を採用。§13 の `access_denied` 403 は「resource owner or OP denied」の語彙で、クライアント実装がフロー全体の終端（ユーザー拒否）と解釈する恐れがある。保留数超過は保留分の処理で解消される一時的状態であり、終端を示唆しない `invalid_request` を採る。CIBA Core に一時エラーの語彙（`temporarily_unavailable` 相当）は存在しない |
| U3 | denied レコードの削除タイミング | **確認済み（Review 2）**: Device Grant 実装は denied → `access_denied` 送出と同時に削除する（`packages/experimental/src/device-authorization-grant/device-code-grant.ts:137-143`）。本仕様の「即削除・再ポーリングは `invalid_grant`」は実装済み先例と一致 |
| U4 | `TokenClientInfo` への `backchannelTokenDeliveryMode` の載せ方 | **確定（Review 3）**: experimental 側に `CibaClientInfo = TokenClientInfo & { backchannelTokenDeliveryMode?: 'poll' \| 'ping' \| 'push' }` を定義し、生成コード側は `RegisteredClient`（`templates.ts:511` の既存交差型）へ同フィールドを `ciba` 有効時のみ条件挿入する。`RegisteredClient` は構造的部分型として `CibaClientInfo` に代入可能で、core の型変更は不要（「公開API案」の節に反映済み） |

## 将来の昇格考慮

- `processBackchannelAuthenticationRequest` / `processCibaGrant` は core のステップ関数群（`*-steps.ts`）と同じ形状にしてあり、そのまま core へ移植できる
- Ping モード対応時は `client_notification_token` の保存と通知送信層が加わるが、ストア契約は `record` へのフィールド追加で吸収できる（破壊的変更は experimental 内で完結）
- `id_token_hint` 対応時は core の `validateIdTokenHint` に exp 検証を緩和するオプションを追加する提案を別タスクとして起こす（core 変更を伴うため本機能のスコープ外）
