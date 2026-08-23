# 理解資料: OAuth 2.0 Device Authorization Grant

この資料は、仕様書（specification.md）の要約ではなく、Device Authorization Grant（RFC 8628）が解決する問題と、それが本リポジトリのどこにどう対応づくかを、プロジェクト所有者が自力で判断できるようになるための説明である。

## 解決する問題

OAuth / OIDC の Authorization Code Flow は「クライアントとブラウザが同じデバイスにある」ことを前提にしている。認可エンドポイントへのリダイレクトと `redirect_uri` への帰還は、どちらもそのデバイス上のブラウザが担うからだ。

ところが次のようなデバイスにはこの前提が成り立たない:

- スマート TV・セットトップボックス（ブラウザが無い / 文字入力が苦痛）
- CLI ツール（`gh auth login` のように、ターミナルにコードと URL を表示したい）
- IoT 機器（画面すら無いことがある）

Device Authorization Grant は、**認可の意思決定だけを「ユーザーが普段使うスマホや PC のブラウザ」へ運ぶ**。デバイスは短いコード（user_code）と URL を表示し、ユーザーは自分のスマホでその URL を開いてコードを入力し、ログインして承認する。デバイス本体はその間、トークンエンドポイントを一定間隔でポーリングして結果を待つ。

## 登場人物

| 役割 | RFC 8628 での呼び名 | 本リポジトリでの対応 |
|---|---|---|
| トークンが欲しいデバイス | device client（consumption device） | E2E では `tests/e2e/apps` に置くポーリングクライアント。利用者の現実では TV アプリや CLI |
| ユーザーが操作するブラウザ | secondary device | Playwright が操作する実ブラウザ |
| 認可サーバー | authorization server | CLI 生成 OP（`samples/*`）＋ `@maronn-openid-connect/experimental/device-authorization-grant` ＋ core |

## 通常フロー（何が起きるか）

1. デバイスが `POST /device_authorization` に `client_id` と `scope` を送る
2. OP が 2 種類のコードを発行する
   - **device_code**: 256bit のランダム値。デバイスだけが知る「引換券」。ユーザーは一切見ない
   - **user_code**: `WDJB-MJHT` のような 8 文字の短いコード。**人間が読み、手で打つためのもの**
3. デバイスは画面に「`http://…/device` を開いて WDJB-MJHT を入力してください」と表示し、以後 5 秒間隔で `POST /token` をポーリングし始める
4. ユーザーがスマホで `/device` を開き、コードを入力 → ログイン → 承認画面で「このデバイス（クライアント名）に、この scope を許可しますか」に答える
5. 承認後、デバイスの次のポーリングでトークン（access_token + id_token）が返る

**2 つのコードの役割分担が本質**である。user_code は「人間が運べる短さ」を優先してエントロピーが低く（約 34.5bit）、その代わり承認の意思決定にしか使えない。device_code は「トークンの引換券」なのでエントロピーが高く（256bit）、その代わり人間は運ばない。片方の性質をもう片方に求めると設計が壊れる（誤解しやすい点の節も参照）。

## 失敗フロー

デバイスのポーリングに対して OP は 4 つの状態を返す（RFC 8628 §3.5）:

| 応答 | 意味 | デバイスの行動 |
|---|---|---|
| `authorization_pending` | ユーザーがまだ承認していない | interval を守って再ポーリング |
| `slow_down` | ポーリングが速すぎる | 間隔を 5 秒増やして再ポーリング |
| `access_denied` | ユーザーが拒否した | フロー終了 |
| `expired_token` | コードの有効期限（既定 10 分）が切れた | 最初からやり直し |

ユーザー側の失敗は「コードが違います」の一種類しか見えない（存在しない・期限切れ・使用済みを区別しない）。これは攻撃者にコードの実在性を教えないための意図的な設計である。

## セキュリティモデルと脅威対策

### この機能の攻撃面はどこか

`redirect_uri` が存在しないため、Authorization Code Flow で常に問題になる open redirect・code 横取り・state 検証は**そもそも登場しない**。代わりに固有の脅威が 3 つある。

**1. user_code 総当たり（RFC 8628 §5.1）**
攻撃者が `/device` に片っ端からコードを入れ、誰かの pending セッションを乗っ取ろうとする（乗っ取れても「攻撃者が承認画面を見る」だけで、被害は「勝手に承認 / 拒否される」）。対策はエントロピー × 有効期限 × レート制限の掛け算で、本実装は 20^8 ≈ 260 億通り × 10 分 TTL を持つ。**アプリ内でのグローバルレート制限は実装しない**。Cloudflare Workers のようにインスタンス間で共有メモリが無い環境ではアプリ内カウンタが機能しないためで、IP 単位のレート制限はデプロイ基盤（Cloudflare / 前段プロキシ）の責務として明示的に切り出している。これは手抜きではなく境界の宣言であり、生成コードのコメントにも書かれる。

**2. リモートフィッシング（§5.4）**
攻撃者が自分のデバイスで発行させた user_code を被害者に送りつけ（「このコードを入れて」）、被害者に承認させると攻撃者のデバイスにトークンが渡る。プロトコルだけでは完全に防げない脅威で、緩和策は (a) 承認画面に user_code とクライアント名を再表示し「手元のデバイスの表示と一致するか確認してください」と促すこと、(b) TTL を短く保つこと。本実装は両方を仕様の必須要件にしている。

**3. public client の client_id なりすまし（§5.6）**
デバイスクライアントは大抵 public client なので、`client_id` は自己申告である。攻撃者が他人の client_id でデバイス認可を開始できるが、得られるのは「本物のクライアント名が承認画面に出る」ことだけで、トークンはユーザーが user_code を入力して明示承認しない限り出ない。つまり脅威 2 と同じ土俵に還元される。

**4. フォージされた承認・ログイン（CSRF）**
脅威 2 が「被害者を騙して承認**させる**」なのに対し、こちらは「被害者のブラウザに承認 POST を**勝手に送らせる**」。攻撃者は自分のデバイス認可を開始して user_code を知っているので、罠ページから被害者のブラウザに `POST /device/approve`（攻撃者の user_code + approve）を送らせられれば、被害者のログイン済みセッションで承認が成立し、トークンが攻撃者のデバイスに流れる。ここで重要なのは、**user_code から辿れるレコードに紐づけただけの CSRF トークンはこの攻撃を防げない**ことだ。攻撃者は自分でも `POST /device` を叩けるので、有効なトークンを自力で入手して罠フォームに埋め込める。だから本実装の防御は「トークンの秘匿」ではなく「**ブラウザの同一性**」に置く: user_code を照合したブラウザにだけ HttpOnly Cookie（bindingSecret）を渡し、レコードにはそのハッシュだけを保存して、`/device/login` と `/device/approve` は Cookie を提示できたブラウザからしか受け付けない。罠ページ経由のクロスサイト POST は被害者ブラウザの Cookie を運べない（SameSite=Lax）し、そもそも被害者ブラウザは攻撃者のレコードの Cookie を持っていないので、二重に遮断される。これは既存の `transaction-binding`（optional feature）と同じ仕組みだが、device フローでは **user_code が攻撃者に既知であることが前提**（authorize フローの transaction_id と違い、識別子の秘匿に頼れない）なので、opt-in ではなく常時有効にしている。

### device_code 側の防御

device_code は認可コードと同等の機密として扱う: ログ出力禁止、256bit エントロピー、**atomic な単回使用**（トークン発行時にストアの `consume` で取得と削除を同時に行う）。これは PAR の request_uri で確立したパターンの再利用で、並行リデンプション（同じ device_code で 2 本トークンを取る）を防ぐ。また device_code は発行時のクライアントに紐づき、別のクライアントが使うと `invalid_grant` になる。

## リクエスト・レスポンス実例

```bash
# 1. デバイス役: デバイス認可リクエスト（public client）
curl -s -X POST http://localhost:3000/device_authorization \
  -d 'client_id=device-client' -d 'scope=openid profile'
# => {"device_code":"GmRh...", "user_code":"WDJB-MJHT",
#     "verification_uri":"http://localhost:3000/device",
#     "verification_uri_complete":"http://localhost:3000/device?user_code=WDJB-MJHT",
#     "expires_in":600, "interval":5}

# 2. デバイス役: ポーリング（承認前）
curl -s -X POST http://localhost:3000/token \
  -d 'grant_type=urn:ietf:params:oauth:grant-type:device_code' \
  -d 'device_code=GmRh...' -d 'client_id=device-client'
# => 400 {"error":"authorization_pending", ...}

# 3. ユーザー役: ブラウザで verification_uri_complete を開き、
#    ログイン → 承認（curl なら GET /device → POST /device → POST /device/login → POST /device/approve。
#    POST /device の応答がバインディング Cookie を返すので、以降は cookie jar が必須:
#    curl -c jar.txt -b jar.txt ... を各ステップに付ける）

# 4. デバイス役: ポーリング（承認後）
# => 200 {"access_token":"...", "id_token":"...", "token_type":"Bearer",
#         "expires_in":300, "scope":"openid profile"}
```

## データ構造

中心は `DeviceAuthorizationRecord`（仕様書のストア契約参照）。1 レコードが 1 回のデバイス認可セッションで、状態機械は一方向にしか進まない:

```text
pending ──(ユーザー承認)──> approved ──(トークン発行=consume)──> 削除
   │                                                        
   ├──(ユーザー拒否 / ログイン失敗上限)──> denied ──(ポーリング=access_denied)──> 削除
   └──(TTL 満了)──> ポーリング=expired_token ──> 削除
```

subject（誰が承認したか）は approved になって初めてレコードに入る。それまでレコードはユーザーと無関係である。

## 用語集

- **device_code**: デバイスがトークンと引き換えるための高エントロピー値。人間は見ない
- **user_code**: 人間が別デバイスへ手で運ぶ短いコード。承認の意思決定専用
- **verification_uri / verification_uri_complete**: ユーザーが開く URL。complete は user_code をクエリに含み入力を省略させる
- **interval**: デバイスがポーリング間隔として守るべき秒数。破ると `slow_down` で +5 される
- **consumption device / secondary device**: RFC 8628 の用語で、それぞれ「トークンが欲しいデバイス」「ユーザーが操作するブラウザのあるデバイス」

## core 機能・類似機能との違い

- **Authorization Code Flow（core）**: ブラウザリダイレクトで認可を運ぶ。Device Flow はポーリングで運ぶ。PKCE・redirect_uri 検証・state はすべて「リダイレクトがあるから必要」なものであり、Device Flow には登場しない
- **PAR（experimental 実装済み）**: 認可「リクエスト」を事前登録する仕組みで、ユーザー対話は通常の authorize フローのまま。Device Flow はユーザー対話の場所そのものを変える
- **Token Exchange（experimental 実装済み）**: 既にあるトークンを別のトークンに替える。Device Flow は最初のトークンを得る手段
- **CIBA（未実装）**: 同じ「デバイス分離」でも方向が逆で、CIBA はクライアントがユーザーの認証デバイスへ**push**で承認を求める。Device Flow はユーザーがコードを**pull**で運ぶ。CIBA は通知チャネルの実装が必要で隔離規模が大きく、見送り継続中

## このリポジトリでの実装対応（どこに何ができるか）

- **ロジック**: `packages/experimental/src/device-authorization-grant/`（subpath export `@maronn-openid-connect/experimental/device-authorization-grant`）。core は無変更
- **生成コード**: `packages/cli/src/frameworks/hono/templates.ts` に (a) `/device_authorization` ルート、(b) `/device` 系 UI ルート、(c) token ルートの grant 分岐、(d) discovery 追記、(e) `deviceAuthorizationStore`、(f) views 4 ページが feature 有効時のみ生成される。express / fastify / nextjs は web-standard 変換で同じテンプレートを共有する
- **有効化**: `--enable device-authorization-grant`。既定オフなので、有効化しない限り生成物は現状と 1 バイトも変わらないことがテストで保証される
- **分岐の型**: token ルートの分岐は Token Exchange が、バックチャネルエンドポイント追加は PAR が、UI ページは login / consent が、ブラウザバインディングは transaction-binding がそれぞれ確立したパターンの再利用であり、本機能で初めて出る構造は「UI ルートが auth transaction ではなくデバイス認可レコードに紐づく」ことと「バインディングが opt-in でなく常時有効」の 2 点だけ

## Experimental にする理由（この機能固有の事情)

検証 UI の views 契約（4 ページ分の関数シグネチャ）と `DeviceAuthorizationStore` 契約は、利用者が差し替える公開 API になる。この形が最初から正解である自信はなく、フィードバックで壊す可能性が高い。core に入れると壊せなくなるため、experimental の「API 不安定」の看板の下で出す。

## 誤解しやすい点

- **「user_code のエントロピーが低くて危険では」**: user_code で得られるのは承認画面の閲覧と承認/拒否の操作だけで、トークンは device_code が無いと出ない。低エントロピーは「人間が手で運ぶ」ための意図的なトレードオフで、TTL とレート制限（基盤側）で補う設計が RFC 8628 §5.1 そのもの
- **「slow_down はエラーなので中断すべき」**: 中断しない。`authorization_pending` と `slow_down` は「継続してよい」ことを伝える特殊なエラーコードで、RFC 8628 §3.5 が明示的に定義している
- **「ID トークンに nonce が無いのはバグでは」**: nonce は認可リクエストに含めた場合に ID トークンへの反映が必須になるクレームで、デバイス認可リクエストには nonce パラメータ自体が存在しない。省略が仕様準拠である
- **「デバイスは confidential client にできないのか」**: できる（client_secret を持つ CLI サーバー等）。本実装は既存のクライアント認証パイプラインをそのまま通すため、public / confidential 両方が動く
- **「approve 後にもう一度 /device でコードを入れたら」**: 非 pending のレコードは「無効なコード」と同じ扱いになる。承認済みセッションを後から拒否に変える操作は存在しない（取り消したい場合はトークン失効 = revocation の領分）
- **「hidden の CSRF トークンがあるのに、なぜ Cookie バインディングまで要るのか」**: このフローの CSRF トークンは user_code から辿れるレコードに保存されており、user_code は攻撃者（フロー開始者）に既知なので、攻撃者はトークンを自力で取得できる。トークンが防御になるのは「攻撃者がトークンを知らない」ときだけで、その前提がこのフローでは崩れている。ブラウザだけが持つ HttpOnly Cookie は罠ページから読むことも送らせることもできないため、こちらが実効的な防御になる（トークンは多層防御として残している）
- **「curl でフローを一周できなくなったのでは」**: できる。cookie jar（`-c` / `-b`）を付ければよい。authorize フローの `transaction-binding` が「curl の手軽さ」を優先して opt-in なのに対し、device フローは識別子（user_code）の秘匿に頼れないためバインディングを常時有効にしている — このトレードオフの違いは意図的である

## 実装後の利用方法（利用者視点）

```bash
maronn-oidc generate hono --enable device-authorization-grant --output ./src/oidc-provider
pnpm sample:hono-cloudflare   # 生成 OP を起動
# 上記「リクエスト・レスポンス実例」の curl で手動フローを一周できる
```

クライアント登録（生成された config）で `grantTypes` に `urn:ietf:params:oauth:grant-type:device_code` を追加したクライアントだけがこのグラントを使える。

## 一次資料の読み方ガイド

- **RFC 8628 本文は短い（§3 がフロー全部）**。まず §3.1〜§3.5 を上から順に読むと、本仕様書の「入出力」節と 1:1 対応していることが分かる
- §5（Security Considerations）は §5.1（user_code 総当たり）と §5.4（リモートフィッシング）だけ精読すれば、本実装のセキュリティ要件の根拠が全て追える
- §6.1 は user_code の文字種の出典（base-20 `BCDFGHJKLMNPQRSTVWXZ`）
- §4 は discovery メタデータ名 `device_authorization_endpoint` の出典（RFC 8414 への登録）
- OIDC との関係は RFC 8628 には書かれていない（OAuth の仕様であるため）。ID トークン発行は「トークンエンドポイントの成功応答に OIDC Core §3.1.3.3 を適用する」という本 OP のプロファイル判断であり、その根拠は仕様書の「成功レスポンス」節にある

## 昇格判断の観点

- views 契約・ストア契約が 2〜3 リリース安定して破壊的変更が出ないこと
- 利用者からの需要シグナル（issue / 利用報告）があること
- core 昇格時は grant ハンドラ機構（Token Exchange と共通の昇格経路）の設計とセットで行うこと。単独昇格より「experimental の grant 系 2 機能をまとめて core の拡張点にする」判断が自然
