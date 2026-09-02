# 理解資料: Cross-App Access (XAA) と Identity Assertion Authorization Grant (ID-JAG)

この資料は、仕様書（specification.md）の要約ではなく、XAA が解決する問題と ID-JAG の仕組み、本リポジトリで何を実装するのか、そしてどこにセキュリティ上の注意があるのかを、プロジェクト所有者が自力で判断できるようになるための説明である。

## 解決する問題

企業では、Wiki、チャット、ストレージのような複数の SaaS を、同じ IdP（Okta や Entra ID のような）への SSO で使うのが普通である。
ユーザー認証は IdP に集約されているのに、**アプリ同士の連携**（Wiki がチャットのメッセージを埋め込む、AI エージェントがカレンダーを読む）だけは IdP の外で行われてきた。
アプリ A がアプリ B の API を使うには、ユーザーをアプリ B の認可画面へ連れて行き、同意を取り、アプリ A がアプリ B のトークンを個別に保持する。

この方式には管理上の穴がある。

- IdP の管理者から、どのアプリがどのアプリへアクセスできるのかが見えない。SSO を切ってもアプリ間の接続は生き残る
- ユーザーはアプリのペアごとに同意画面を通過させられる
- 各アプリが他アプリのリフレッシュトークンを長期保持し、漏洩点が増える

**Cross-App Access（XAA）** は、このアプリ間アクセスの許可判断を IdP へ移す。
両アプリがすでに SSO で IdP を信頼しているという既存の信頼関係をそのまま使い、「アプリ A がユーザー X としてアプリ B にアクセスしてよいか」を IdP の管理者ポリシーが決める。
ユーザーの追加同意は出ない。
標準化は IETF OAuth WG のドラフト（draft-ietf-oauth-identity-assertion-authz-grant）で進んでおり、その中核となるトークンが **ID-JAG（Identity Assertion JWT Authorization Grant）** である。

## 登場人物

| 役割 | draft での呼び名 | 本リポジトリでの対応 |
|---|---|---|
| アクセスしたい側のアプリ | Client（Requesting App） | E2E ではブラウザログインを担う既存の E2E クライアントと、バックチャネル呼び出しを行う Playwright spec |
| ユーザー認証を集約する IdP | IdP Authorization Server | CLI 生成 OP の 1 インスタンス目（`--enable id-jag` の発行側の役割） |
| アクセスされる側のアプリの認可サーバー | Resource Authorization Server | CLI 生成 OP の 2 インスタンス目（同じ機能の受領側の役割） |
| アクセスされる側の API | Resource Server | E2E では 2 インスタンス目の UserInfo エンドポイントで代用 |

1 つの生成 OP が発行側と受領側の両方の役割を持つ。
XAA はドメインを跨ぐ仕組みなので、動かして確認するときは OP を 2 インスタンス起動し、互いを設定で信頼させる。

## 通常フロー（何が起きるか）

1. ユーザーがアプリ A に IdP 経由で SSO ログインする。アプリ A は **ID トークン**を手に入れる（ここまでは普通の OIDC）
2. アプリ A は IdP のトークンエンドポイントに Token Exchange（RFC 8693）を送る。「この ID トークンのユーザーとして、アプリ B の認可サーバー向けの grant が欲しい」という要求で、`subject_token` に ID トークン、`audience` にアプリ B の認可サーバーの issuer URL、`requested_token_type` に ID-JAG の URN を入れる
3. IdP はポリシーを評価し、**ID-JAG** を発行する。ID-JAG は IdP が署名した短命（本実装では 300 秒）の JWT で、「ユーザー `sub` の代わりに、クライアント `client_id` が、認可サーバー `aud` でアクセス権を得てよい」という IdP の表明である
4. アプリ A は ID-JAG をアプリ B の認可サーバーのトークンエンドポイントへ **JWT Bearer Grant**（RFC 7523、`grant_type=...jwt-bearer` の `assertion`）として提示し、自分のクライアント資格情報で認証する
5. アプリ B の認可サーバーは ID-JAG の署名を IdP の JWKS で検証し、自分宛て（`aud`）で、提示したクライアント本人宛て（`client_id`）であることを確かめて、**自分の発行するアクセストークン**を返す
6. アプリ A はそのアクセストークンでアプリ B の API を呼ぶ

認可コードもユーザーの同意画面も出てこないことがポイントで、ステップ 3 の IdP のポリシー評価がそれを置き換えている。
またステップ 5 でアクセストークンを発行するのはあくまでアプリ B の認可サーバーであり、IdP がアプリ B のトークンを直接作るわけではない。
各認可サーバーは自分のトークンの発行権を手放さず、IdP は「仲介の判断」だけを担う。

ID-JAG が期限切れになったら、アプリ A は手元の ID トークンでステップ 2 からやり直す。
ID トークン自体も切れていたら、SSO で一緒に受け取っていた **IdP のリフレッシュトークン**をそのまま `subject_token` にして新しい ID-JAG を要求できる（ユーザーを再ログインさせずに済む。draft §4.3.2）。
アプリ B のアクセストークンが切れたときは、ID-JAG がまだ有効なら同じ ID-JAG を再提示すればよい。
つまり ID-JAG は、アプリ B のリフレッシュトークンをアプリ A が長期保持する状態の代替になり、長期資格情報は IdP のリフレッシュトークン 1 本に集約される。

## 本リポジトリで実装すること

実装は 3 層に分かれる。いずれも core パッケージには手を入れない。

**1. experimental パッケージ（`@maronn-openid-connect/experimental/id-jag`）**

- 発行側: Token Exchange リクエストの検証（ID トークンの署名と宛先の検証を含む）、audience と scope のポリシー検証、ID-JAG の組み立てと RS256 署名、応答生成
- 発行側の subject には、設定により **IdP のリフレッシュトークン**も使える（検証は通常の refresh grant と同一で、RT は消費しない）。**actor_token**（別の主体のトークン）を受けて「誰が subject の代理として動くか」を `act` クレームに記録することもできる（既定は無効の opt-in）。受ける actor_token の種別は仕様（RFC 8693）が定義する 6 種を一律に扱い、中身の検証は**デプロイ側が書く検証リゾルバ**（`actorTokenResolver`）が担う
- 受領側: JWT Bearer リクエストの検証、ID-JAG の署名とクレーム（typ / iss / aud / exp / client_id / act など）の検証、アクセストークン発行素材の導出。act は発行するアクセストークンへそのまま引き継ぐ
- 既存機能と同じ「合成関数＋ステップ関数」の二層構成で、生成コードから 1 ステップずつ差し替えられる

**2. CLI（`--enable id-jag`）**

- 生成 OP のトークンエンドポイントに発行分岐と受領分岐を注入する
- discovery に対応メタデータ（`identity_chaining_requested_token_types_supported` と `authorization_grant_profiles_supported`）と grant URN を追加する
- `idJagConfig`（許可 audience、信頼 IdP、ID-JAG 有効期間）を生成コードに export し、conformance テストと環境変数から設定できるようにする
- フラグなし生成の出力は現行とバイト同一に保つ

**3. テストとサンプル**

- 単体テスト（experimental）、conformance テスト（生成 OP の契約）、E2E（生成 OP を 2 インスタンス起動して XAA の 4 ステップを実ブラウザ＋バックチャネルで通す）
- サンプルは環境変数（`XAA_ALLOWED_AUDIENCES` / `XAA_TRUSTED_IDP_ISSUER` など）で 2 インスタンスの信頼関係を組めるようにする

### 既存の Token Exchange 機能で足りない理由

「Token Exchange があるなら ID-JAG もできるのでは」という疑問には、入出力の違いで答えられる。
既存の `token-exchange` 機能は、**自分が発行したアクセストークン**を受け取り、scope や audience を狭めた**別のアクセストークン**を返す。同一ドメイン内の権限縮小である。
ID-JAG に必要なのは、**ID トークン**を受け取り、**別ドメインの認可サーバー宛ての署名付き grant JWT** を返すことと、逆側で**他所の IdP が署名した JWT** を検証して自分のアクセストークンを発行することで、既存実装のどちらの口も合わない。
grant_type の URN（Token Exchange）は共有するので、`requested_token_type` がID-JAG のときだけ新しい分岐へ入るようにディスパッチ順序で分離し、既存機能のコードには触れない。
また、XAA の後半（ID-JAG の受け入れ）に必要な JWT Bearer Grant（RFC 7523）はこれまで生成 OP に存在しなかったので、本機能で追加する。これが「できない場合はできるように修正」の中身である。

## セキュリティ面での注意事項

XAA は「ユーザー同意を IdP のポリシーで置き換える」仕組みなので、守りの要点は認可コードフローとは違う場所にある。

**1. ID-JAG は預金小切手のようなもの（宛先と受取人の固定）**

ID-JAG は Bearer な JWT であり、盗まれること自体は防げない。
その代わり、換金できる場所と人を券面に書いて縛る。
`aud`（どの認可サーバーでだけ使えるか）と `client_id`（どのクライアントが提示したときだけ有効か）の検証が仕様上の MUST で、受領側はクライアント認証と `client_id` クレームの一致まで確認する。
だから ID-JAG を盗んだ第三者は、そのクライアントの資格情報（client_secret）まで持っていない限り何もできない。
本実装はこれに加えて、発行側と受領側の両方を confidential client に限定する（draft も public client には従来の認可コードフローを使えと述べている）。

**2. ID トークンの横流し防止（発行側の入口）**

発行側は「提示された ID トークンの `aud` が、交換を要求している認証済みクライアントと一致すること」を検証する。
これが無いと、別のクライアント向けに発行された ID トークン（たとえば別アプリのログから漏れたもの）を持ち込んで、自分のクライアント名義の ID-JAG に交換できてしまう。

**3. 同一ドメイン内での利用禁止**

draft §9.3 は「IdP は自分が発行した ID-JAG に対して、同じドメイン内でアクセストークンを発行してはならない」と定める。
これを破ると、SSO 用の ID トークンが実質的にその IdP 自身のアクセストークンへ昇格する抜け道になる。
本実装は二重に防ぐ: 発行側は `audience` が自分の issuer と同じ要求を拒否し、受領側は `iss` が自分の issuer と同じ assertion を拒否する。

**4. リプレイを「許す」判断**

ID-JAG は有効期間内なら何度でも再提示できる。
これは手抜きではなく draft §4.4.3 の設計で、ID-JAG がリフレッシュトークンの置き場を代替する（アプリ B の長期資格情報をアプリ A に持たせない）ための性質である。
無制限にならないのは、有効期間が短いこと（本実装のデフォルト 300 秒）と、上記 1 のクライアント認証束縛があるからだ。
`jti` は必須クレームとして構造検証するが、使用済み記録には使わない。

**5. 信頼設定はデフォルト空（fail-safe）**

発行側の「どの認可サーバー宛てに発行してよいか」（`allowedAudiences`）も、受領側の「どの IdP の署名を信じるか」（`trustedIdentityProviders`）も、デフォルトは空リストである。
設定するまで ID-JAG は 1 枚も発行されず、1 枚も受理されない。
受領側の信頼リストは issuer と鍵（JWKS のインライン指定か jwks_uri）の事前登録で、**assertion の中身から鍵の取得先を導出することは決してしない**（`jku` ヘッダなどの外部鍵指定は明示的に拒否する）。
これは偽造と SSRF の両方を塞ぐ。

**6. エラー応答から設定を推測させない**

受領側で「知らない IdP の署名だった」のか「信頼している IdP だが署名が壊れていた」のかを応答で区別すると、外部から信頼 IdP リストを探索できてしまう。
両者は同じ固定文言で返す。
discovery のメタデータにも、対応プロファイルの広告だけを載せ、信頼リストや許可 audience は載せない（draft §9.4 の MUST NOT）。

**7. リフレッシュトークン subject は「同じ主体、同じ関門」**

RT を subject にしても、通れる関門は ID トークン経路と同じである（同じユーザー、同じクライアント束縛、同じ audience / scope ポリシー）。
増えるのは利便性だけで、権限は増えない。
その代わり検証は通常の refresh grant と完全に同じにしてある: rotation 済み RT の再提示は盗難シグナルとして token family ごと失効させ、ログインセッションに束縛された online RT はログアウト後に使えない。
また `openid` を持たない grant の RT は受けない（ID トークンが存在し得ない grant に「Identity Assertion の代替」は成立しない）。

**8. actor_token は明示的な opt-in**

draft は actor_token を「運べる」とだけ定め、処理規則を定義していない（§9.7 が拡張の指針を示すのみ）。
規則が無いものを黙って受けると、無関係なトークンの持ち込みで委譲の権威を過大表明され得る。
だから本実装の actor 対応は既定で無効にし、`allowActorTokens` を立てたときだけ actor の `sub` を `act` に記録する。
受領側は act を落とさず自分のアクセストークンへ引き継ぐ。落とすと「誰が代理で動いたか」の記録が消え、委譲がただの impersonation に見えてしまうからだ。

**8-2. actor_token は「構造はライブラリ、中身はあなた」**

actor_token の種別は RFC 8693 §3（と RFC 7519 §9）が定義する 6 種である: access_token、refresh_token、id_token、jwt、saml1、saml2。
本実装はこの一覧を**種別で区別せず一律に受け**、一覧に無い識別子だけを拒否する。ID トークンとそれ以外で経路を分けることはしない。
中身の検証は `idJagConfig.actorTokenResolver` に集約されている。
責務の線引きは固定である: **リクエストの構造がおかしいか**（actor_token と actor_token_type の対応規則、非空、種別が一覧にあるか、opt-in スイッチ）と**リゾルバが返した値の構造**（`sub` 必須、`sub` / `act` 以外の属性は落とす）はライブラリが検証し、**トークンの中身が本物か**（署名・失効・誰のものか）はリゾルバが検証する。
生成コードには既定リゾルバが入っていて、自 OP 発行・自クライアント宛ての ID トークンを検証し、それ以外の種別には「無効」を返す。
受ける種別を増やすなら、この既定を差し替えるか、包んで自分の種別を足す。サンプル（hono-cloudflare の `app.ts`）は後者で、自 OP が発行したアクセストークンを自分のストアで照合し、残りは既定リゾルバへ渡している。
リゾルバを `undefined` にすると、検証手段が無いので actor_token はすべて拒否される。

**9. ユーザー同意が消えることそのものへの注意**

これは実装の欠陥ではなく XAA の性質だが、運用上いちばん意識すべき点である。
ユーザーの画面に「アプリ A がアプリ B のデータにアクセスすることを許可しますか」は二度と出ない。
その判断は全部 IdP のポリシー（本実装では `allowedAudiences` と `allowedScopes`）に移る。
検証時にこのリストへ何かを足すことは、そのアプリ間アクセスをユーザー全員に代わって許可することと同じ意味を持つ。

## 誤解しやすい点

- **ID-JAG はアクセストークンではない**。Token Exchange 応答の `access_token` フィールドに入って返るが（RFC 8693 の歴史的なフィールド名）、`token_type` は `N_A` であり、リソースサーバーの API に直接添えても使えない。使い道は「リソース側認可サーバーのトークンエンドポイントに 1 回提示する」だけである
- **ID-JAG は ID トークンでもない**。似た形の JWT だが、`typ` ヘッダが `oauth-id-jag+jwt` で区別され、宛先（`aud`）はクライアントではなく別ドメインの認可サーバーである。受領側は typ を必ず検証するので、ID トークンを assertion として流用することはできない（RFC 8725 の token confusion 対策）
- **IdP がアプリ B のアクセストークンを作るのではない**。IdP が作るのは grant（発行許可の表明）までで、アクセストークンは常にアプリ B の認可サーバーが自分のポリシーで発行する。scope も受領側でさらに狭められることがある
- **アクセストークンの寿命は ID-JAG の寿命に縛られない**。300 秒の ID-JAG から 3600 秒のアクセストークンが出るのは正常である（grant は発行の瞬間に有効であればよい。認可コードが 5 分で切れても、そこから出たトークンが 1 時間生きるのと同じ関係）

## リクエスト実例

```bash
# (2) IdP へ: ID トークンを ID-JAG に交換する
curl -s -X POST http://127.0.0.1:3010/token \
  -d 'grant_type=urn:ietf:params:oauth:grant-type:token-exchange' \
  -d 'requested_token_type=urn:ietf:params:oauth:token-type:id-jag' \
  -d 'audience=http://127.0.0.1:3040' \
  -d 'scope=openid profile' \
  -d "subject_token=${ID_TOKEN}" \
  -d 'subject_token_type=urn:ietf:params:oauth:token-type:id_token' \
  -d 'client_id=e2e-client' -d 'client_secret=e2e-client-secret'
# => {"issued_token_type":"urn:ietf:params:oauth:token-type:id-jag",
#     "access_token":"<ID-JAG>","token_type":"N_A","expires_in":300,"scope":"openid profile"}

# (3) リソース側 AS へ: ID-JAG をアクセストークンに引き換える
curl -s -X POST http://127.0.0.1:3040/token \
  -d 'grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer' \
  -d "assertion=${ID_JAG}" \
  -d 'client_id=e2e-client' -d 'client_secret=e2e-client-secret'
# => {"access_token":"...","token_type":"Bearer","expires_in":3600,"scope":"openid profile"}

# (2') ID トークンが切れているとき: リフレッシュトークンを subject にする
#      subject_token_type を refresh_token に変えるだけで、応答は (2) と同じ形
curl -s -X POST http://127.0.0.1:3010/token \
  -d 'grant_type=urn:ietf:params:oauth:grant-type:token-exchange' \
  -d 'requested_token_type=urn:ietf:params:oauth:token-type:id-jag' \
  -d 'audience=http://127.0.0.1:3040' \
  -d 'scope=openid profile' \
  -d "subject_token=${REFRESH_TOKEN}" \
  -d 'subject_token_type=urn:ietf:params:oauth:token-type:refresh_token' \
  -d 'client_id=e2e-client' -d 'client_secret=e2e-client-secret'

# (2'') 代理実行を記録するとき: actor_token を追加する（allowActorTokens 有効時のみ）
#       発行される ID-JAG に act = {"sub":"<actor の sub>"} が入り、
#       redemption 後のアクセストークンにも同じ act が引き継がれる
curl -s -X POST http://127.0.0.1:3010/token \
  -d 'grant_type=urn:ietf:params:oauth:grant-type:token-exchange' \
  -d 'requested_token_type=urn:ietf:params:oauth:token-type:id-jag' \
  -d 'audience=http://127.0.0.1:3040' \
  -d "subject_token=${ID_TOKEN}" \
  -d 'subject_token_type=urn:ietf:params:oauth:token-type:id_token' \
  -d "actor_token=${ACTOR_ID_TOKEN}" \
  -d 'actor_token_type=urn:ietf:params:oauth:token-type:id_token' \
  -d 'client_id=e2e-client' -d 'client_secret=e2e-client-secret'

# (2''') actor_token が ID トークン以外のとき: actor_token_type を変えるだけ。
#        受理は仕様定義の 6 種すべてに開いており、通るかどうかは
#        actorTokenResolver が「有効」と判断するかで決まる（サンプルは
#        XAA_ACTOR_TOKEN_RESOLVER=access-token でアクセストークンを足したデモ入り）
curl -s -X POST http://127.0.0.1:3010/token \
  -d 'grant_type=urn:ietf:params:oauth:grant-type:token-exchange' \
  -d 'requested_token_type=urn:ietf:params:oauth:token-type:id-jag' \
  -d 'audience=http://127.0.0.1:3040' \
  -d "subject_token=${ID_TOKEN}" \
  -d 'subject_token_type=urn:ietf:params:oauth:token-type:id_token' \
  -d "actor_token=${ACTOR_ACCESS_TOKEN}" \
  -d 'actor_token_type=urn:ietf:params:oauth:token-type:access_token' \
  -d 'client_id=e2e-client' -d 'client_secret=e2e-client-secret'
```

## 参照

- 仕様の全文と実装要件: `specification.md`
- 一次資料の対応表: `sources.md`
- draft-ietf-oauth-identity-assertion-authz-grant-04（2026-05）
