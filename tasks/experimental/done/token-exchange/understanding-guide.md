# 理解資料: OAuth 2.0 Token Exchange (RFC 8693)

この資料は、プロジェクト所有者が Token Exchange 機能を正確に理解し、仕様書（specification.md）のレビューと昇格判断を行えるようにするためのものです。RFC の要約ではなく、**このリポジトリ（maronn-openid-connect）への対応付け**を中心に説明します。

## 解決する問題

サービス間連携で「受け取ったトークンをそのまま下流へ横流しする」構成には 2 つの問題があります。

1. **過剰権限の伝播**: フロント API が受けたトークンはユーザーの全 scope・広い audience を持つ。これを内部サービスへそのまま渡すと、内部サービスが必要以上の権限を持つトークンを扱うことになる
2. **audience 検証の崩壊**: トークンの `aud` がフロント API 向けのままだと、内部サービスは「自分宛でないトークン」を受け入れるか（検証形骸化）、拒否するか（連携不能）の二択になる

Token Exchange は、認可サーバー（本リポジトリの生成 OP）に「交換窓口」を設け、**手元のトークンを、必要最小限の scope・正しい audience を持つ新しいトークンへ交換する**標準手段を提供します。

## 背景標準

- **RFC 8693 (OAuth 2.0 Token Exchange, 2020年1月, Proposed Standard)**: 本機能の準拠仕様。トークンエンドポイントの新 grant type として交換プロトコルを定義する
- 位置づけとして RFC 8693 は WS-Trust の STS（Security Token Service）概念を OAuth 2.0 に持ち込んだもの。SAML や外部 JWT の交換まで視野に入れた汎用仕様だが、本機能は「本 OP 発行のアクセストークン → 本 OP 発行のアクセストークン」の交換に初期スコープを絞る

## 基礎概念

| 用語 | 意味 |
|---|---|
| subject_token | 交換の元手として提示するトークン。「誰の代理として動くか」を表す。本機能では本 OP 発行のアクセストークン限定 |
| actor_token | 「誰が動いているか」を表すトークン。**本機能では非対応**（後述の impersonation / delegation を参照） |
| impersonation | 交換後トークンが subject 本人として振る舞う形態。`sub` は subject のまま、`act` claim なし。**本機能の初期スコープはこれのみ** |
| delegation | 「A の代理として B が動いている」ことをトークン自体に記録する形態。`act` claim に actor が入る。非対応（将来拡張） |
| audience / resource | 交換後トークンを使う先。`audience` は論理名、`resource` は URI。発行トークンの `aud` に反映される |
| issued_token_type | 応答に含まれる「発行したトークンの種別」識別子 URN。本機能は常に `urn:ietf:params:oauth:token-type:access_token` |

## 登場人物とリポジトリ対応

| 登場人物 | RFC 8693 上の役割 | このリポジトリでの実体 |
|---|---|---|
| 認可サーバー（STS） | 交換要求を検証し新トークンを発行 | CLI 生成 OP のトークンエンドポイント（`routes/token.ts`）＋ `@maronn-openid-connect/experimental/token-exchange` のステップ関数 |
| クライアント | subject_token を提示して交換を要求 | confidential client として登録され、`grantTypes` に交換 URN を明示登録したもの（`config.ts`） |
| subject | トークンが代理する本人 | Authorization Code Flow でログインしたユーザー（`sub`） |
| 下流サービス | 交換後トークンを受け取る | 生成 OP の UserInfo / introspection、または利用者の resource server（E2E では `tests/e2e/apps`） |

## 通常フロー（このリポジトリでの動き）

1. クライアントが通常の Authorization Code Flow でアクセストークンを取得する（既存機能のまま）
2. クライアントがトークンエンドポイントへ `grant_type=urn:ietf:params:oauth:grant-type:token-exchange` で POST する。クライアント認証は通常のトークンリクエストと同一（client_secret_basic / client_secret_post）
3. 生成コードは**既存のクライアント認証パイプライン通過後**、core の grant_type 検証（`validateGrantTypeSupported`）より**前**に URN を検出し、experimental の処理へ分岐する。core は URN を知らないままなので core の変更は不要
4. experimental のステップ関数が「クライアントは交換を許可されているか → パラメータは正しいか → subject_token は有効か → scope は縮小か → 対象は許可リスト内か → 有効期間はいくつか」を順に検証・導出する
5. 生成コードが core の既存部品（`buildAccessTokenPayload` → `accessTokenIssuer.issue` → `accessTokenStore.set`）で新トークンを発行・保存し、RFC 8693 §2.2.1 形式の JSON を返す
6. 交換後トークンは通常のアクセストークンとして store に載っているため、UserInfo・introspection・revocation が**既存実装のまま**で機能する

## 失敗フロー

すべてバックチャネルの JSON エラー（リダイレクトは存在しない）。主なもの:

- 交換を許可されていないクライアント（`grantTypes` に URN 未登録、または public client）→ `unauthorized_client`
- subject_token が無効（不存在・期限切れ・失効済み・nbf 未来）→ `invalid_request`（**`invalid_grant` ではない**。RFC 8693 §2.2.2 が invalid なトークンに `invalid_request` を指定している）。失敗種別は error_description からも区別できない固定文言（オラクル化防止）
- scope を subject_token より広げようとした → `invalid_scope`
- `audience` / `resource` が許可リスト（`allowedTargets`）にない → `invalid_target`（RFC 8693 §2.2.2 で新設されたエラーコード。core の `TokenErrorCode` には存在しないため experimental 専用のエラークラスで表現する）
- `actor_token` を付けた（delegation 要求）→ `invalid_request`（未対応の明示）

## セキュリティモデルと脅威対策

本機能のセキュリティ設計は「**交換によって権限が単調に狭まることを保証する**」の一点に集約されます。

1. **誰が交換できるか**: confidential client かつ `grantTypes` に URN を明示登録したクライアントのみ。RFC 8693 §2.1 は「クライアント認証を省くと、窃取されたトークンを STS 経由で別のトークンに増幅できてしまう」と注記しており、本機能はこれを public client 拒否まで強めている（設計判断）
2. **何に交換できるか**: scope は部分集合のみ・audience は許可リスト内のみ・`sub` は変更不可
3. **いつまで使えるか**: 交換後トークンの寿命は元トークンの残存期間を超えない。交換を何度連鎖しても寿命は延びない
4. **失効との関係**: 交換後トークンは元トークンの `grantId` を継承して保存されるため、認可コード再利用検知などで grant 単位の失効が走ると交換後トークンも巻き込まれる
5. **subject_token は消費しない**: PAR の request_uri と違い単回使用にしない。RFC 8693 は単回使用を要求しておらず、有効期間内に同じトークンから複数の下流向けトークンを作るのは正当な利用形態のため（設計判断）

## リクエスト・レスポンス実例

リクエスト（confidential client, client_secret_basic）:

```http
POST /token HTTP/1.1
Host: op.example.com
Authorization: Basic czZCaGRSa3F0Mzo3RmpmcDBaQnIxS3REUmJuZlZkbUl3
Content-Type: application/x-www-form-urlencoded

grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Atoken-exchange
&subject_token=2YotnFZFEjr1zCsicMWpAA
&subject_token_type=urn%3Aietf%3Aparams%3Aoauth%3Atoken-type%3Aaccess_token
&scope=api%3Aread
&audience=internal-api
```

レスポンス:

```http
HTTP/1.1 200 OK
Content-Type: application/json
Cache-Control: no-store
Pragma: no-cache

{
  "access_token": "eyJhbGciOiJSUzI1NiIs...",
  "issued_token_type": "urn:ietf:params:oauth:token-type:access_token",
  "token_type": "Bearer",
  "expires_in": 300,
  "scope": "api:read"
}
```

`expires_in: 300` は「設定値 3600 秒だが subject_token の残存が 300 秒しかない」ケースの例（cap の実演）。

## データ構造

交換後トークンは既存アクセストークンと同じ `AccessTokenInfo`（`packages/core/src/userinfo.ts:52`）として store に保存される。差分は値のみ:

| フィールド | 交換後トークンでの値 |
|---|---|
| `sub` | subject_token の `sub` を継承 |
| `clientId` | **交換を要求したクライアント**（subject_token の clientId ではない） |
| `scope` | 縮小後の実効 scope |
| `audience` | 検証済みの要求対象（または subject からの継承）に、OP の UserInfo エンドポイントを恒久メンバとして加えた合成結果（既存トークンと同じ `buildAccessTokenAudience` の規則） |
| `expiresAt` | `now + min(configured, subject 残存)` |
| `grantId` | subject_token の値を継承（失効連動） |
| `claims` | **継承しない**（未設定）。認可時の claims パラメータ（OIDC Core 1.0 §5.5）は交換後トークンへ伝播せず、UserInfo は scope ベースのクレームのみ返す |

## 用語集

- **STS (Security Token Service)**: トークンを検証して別のトークンを発行するサービス。RFC 8693 では認可サーバーがこの役割を担う
- **token type identifier**: `urn:ietf:params:oauth:token-type:*` 形式の URN。subject_token / 発行トークンの種別を表す（RFC 8693 §3）
- **`invalid_target`**: RFC 8693 §2.2.2 で追加されたエラーコード。resource / audience への発行を拒否するときに使う
- **`act` / `may_act` claim**: delegation の記録・事前許可を表す JWT claim（RFC 8693 §4）。本機能では未使用

## core機能・類似機能との違い

- **refresh_token grant との違い**: refresh は「同一クライアント・同一権限のトークンを更新する」機構で、offline_access と rotation が中心。exchange は「別 audience・縮小 scope のトークンを新規に作る」機構で、寿命はむしろ元より短くなる。両者は代替関係にない
- **introspection との違い**: introspection はトークンの状態を照会するだけで新しいトークンを作らない。exchange は内部で introspection 相当の検証（store 解決）を行った上で発行まで行う
- **DpoP（tasks/T-019）との違い**: DPoP はトークンを送信者に拘束する仕組みで、トークンの中身（scope/aud）は変えない。直交する機能であり併用も概念上可能
- **PAR（実装済み experimental）との違い**: PAR は認可リクエストの受け渡し方法の改善（authorize 前段）、exchange はトークン発行の新 grant（token 分岐）。挿入点も store 契約も独立

## Experimentalにする理由

- 交換ポリシー設定（`allowedTargets`）の形状が実運用フィードバックで変わり得る（クライアント単位の許可、対象ごとの scope 制限などへの発展余地）
- impersonation → delegation 拡張時に公開 API（parse の拒否解除・`act` claim 導出）が変わる
- トークンエンドポイントの grant ディスパッチという入口の分岐パターンとして、安定するまで隔離したい

## 誤解しやすい点

1. **「invalid な subject_token は `invalid_grant`」ではない**: RFC 8693 §2.2.2 は invalid なトークンに `invalid_request` を指定している。authorization_code や refresh_token の感覚で `invalid_grant` を期待するとテストを誤る
2. **subject_token は消費されない**: 交換後も元トークンは有効なまま。使い捨てになるのは PAR の request_uri であって、こちらは違う
3. **交換はデフォルトで「何も許可されていない」**: `allowedTargets` の空デフォルトでは audience/resource 指定付き交換はすべて `invalid_target`。scope 縮小のみの交換だけが通る。許可リストへの追加は利用者の明示的な設定
4. **`aud` を省略しても自由にはならない**: 省略時は subject_token の audience を**継承**する（無制限になるのではない）。また、どんな交換でも発行トークンの `aud` には OP の UserInfo エンドポイントが恒久メンバとして含まれる（既存トークンと同じ `buildAccessTokenAudience` の合成規則。これにより交換後トークンで UserInfo が使える）
5. **交換後トークンの `client_id` は要求クライアント**: subject_token の発行先クライアントではない。introspection の `client_id` を検証するテストで混同しやすい
6. **複数 audience/resource パラメータは使えない**: RFC 8693 自体は同名パラメータの複数出現を許すが、生成 OP はトークンエンドポイント全体で重複パラメータを拒否している（RFC 6749 §3.2 準拠）ため、本機能では単一値のみ。意図的な制限であり、生成コードコメントにも明示される
7. **交換すると claims パラメータの効果は消える**: 認可時に `claims` パラメータで要求した個別クレームは subject_token のメタデータには保存されているが、交換後トークンには継承されない。交換後トークンで UserInfo を呼ぶと scope ベースのクレームだけが返る。認可時の同意対象を交換経由で広げないための意図的な設計であり、バグではない

## 実装後の利用方法

```bash
maronn-oidc generate hono --enable token-exchange
pnpm add @maronn-openid-connect/experimental
```

生成後、利用者がやることは 2 つ:

1. `routes/token.ts` の `tokenExchangeConfig.allowedTargets` に交換先として許可する audience / resource 値を追加する
2. 交換を許可するクライアントの `grantTypes`（`config.ts`）に `urn:ietf:params:oauth:grant-type:token-exchange` を追加する（confidential client のみ）

## 一次資料の読み方ガイド

RFC 8693 を読む順序の推奨:

1. **§1.1（Delegation vs. Impersonation）**: 本機能が impersonation 限定であることの意味を掴む。ここを飛ばすと actor_token 拒否の意図が読めない
2. **§2.1〜§2.2**: リクエスト/レスポンスのパラメータ表。仕様書の入出力表と 1 対 1 で突き合わせられる
3. **§2.2.2**: エラーコード。`invalid_target`（SHOULD）と invalid トークン→`invalid_request`（MUST）の 2 点が本仕様のエラー表の根拠
4. **§3**: token type identifier の一覧。本機能が受理するのは access_token のみ
5. **§4（act / may_act claim）**: 非対応範囲の理解のため。将来の delegation 拡張の設計材料
6. **§5（Security Considerations）**: scope 制限・寿命制限の推奨。仕様書のセキュリティ要件表の元ネタ
7. §2.1 の「Client authentication」注記: confidential 限定の設計判断の根拠

## 昇格判断の観点

1. 生成 OP の conformance テストが 2 サイクル以上安定しているか
2. `allowedTargets` の設定形状への変更要望が収束しているか（クライアント単位許可などの要望が出ていないか）
3. delegation（actor_token / act claim）対応の要否が決まったか。対応するなら昇格前に experimental 内で先行実装するのが低リスク
4. 昇格時は core の `TokenErrorCode` へ `invalid_target` を追加し、grant ディスパッチへ正式合流する（closed enum の拡張は core 変更として昇格時にのみ行う）
