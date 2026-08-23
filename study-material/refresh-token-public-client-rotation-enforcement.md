# パブリッククライアントの Refresh Token ローテーション「強制」（OAuth 2.1 §4.3.1 / RFC 9700 §4.14）

## 1. タイトル

パブリッククライアント（client_secret を持たないクライアント）に発行する Refresh Token について、OAuth 2.1 / RFC 9700 が課す「**ローテーション or sender-constrained を MUST**」という要件と、現在の core 実装が「ローテーションを呼び出し側任せ（任意）」にしている差分の整理。

## 2. このトピックで確認したいこと

`packages/core/src/token-request.ts` の refresh_token grant 処理は、**ローテーションの機構**（`used` フラグによる再利用検知、再利用時の grantId 一括失効）を備えている。しかし「ローテーションを実際に行うか（旧 RT を used にし新 RT を発行するか）」は完全に**呼び出し側（生成された Provider）の実装に委ねられている**。

OAuth 2.1 §4.3.1 / RFC 9700 §4.14.2 は、**パブリッククライアント**に対しては「Refresh Token はローテーションするか sender-constrained にするかの**いずれかが MUST**」と規定する。つまりパブリッククライアントでローテーションも DPoP/mTLS も無い構成は仕様違反となる。

確認したいのは:

- core は「クライアントが public か confidential か」を refresh 経路で判別し、public のときローテーション or sender-constrained を**強制**できる構造になっているか
- 現状は強制が無く、生成テンプレート任せで仕様違反構成を作れてしまうのではないか
- どこに「public client の RT 保護」を担保するガードを置くのが自然か

## 3. 関連する仕様・基準

> ローテーションの**機構・誤検知緩和**は `study-material/refresh-token-rotation-replay-grace.md`、`offline_access` 付与条件は `study-material/offline-access-scope-grant-policy.md`、絶対有効期限は `tasks/p1-refresh-token-absolute-lifetime.md`、public client の Token Endpoint **認証**は `tasks/p1-public-client-token-endpoint.md`、sender-constrained（DPoP）は `tasks/T-019-dpop.md` が扱う。本ファイルはそれらと重複せず、「**public client における rotation/sender-constrained の二者択一 MUST という強制ポリシー**」という差分のみを扱う。

### 3.1 OAuth 2.1 §4.3.1（Refresh Token Grant）/ RFC 9700 §4.14

- パブリッククライアント向け Refresh Token は、**sender-constrained（DPoP/mTLS 等）であるか、または使用ごとにローテーションされるか、のいずれかでなければならない（MUST）**
- ローテーションとは「Refresh Token 使用時に新しい Refresh Token を発行し、旧トークンを無効化する」こと
- 旧 Refresh Token の再利用（rotation 後の旧トークン提示）を検知した場合、認可サーバは当該グラントに紐づく Refresh Token 群を失効する（SHOULD）

この「二者択一 MUST」は **confidential client には課されない**（confidential はクライアント認証で binding が担保されるため、ローテーションは RECOMMENDED に留まる）。したがって **client の種別による分岐**が要件の本質である。

### 3.2 本リポジトリの既存カバレッジとの境界

`study-material/done/oauth-security-bcp-rfc9700.md` のチェックリストには次の行がある:

- 「sender-constrained refresh tokens（public client）🟡 → DPoP 経由 → `tasks/T-019-dpop.md`」
- 「Public client が refresh token を取得する場合の制約 🟡 → `tasks/p1-public-client-token-endpoint.md`」

つまり既存資料は「DPoP（sender-constrained 側）」と「public client の**認証**を可能にする側」をそれぞれ別タスクに割り当てているが、**「DPoP が無い場合に rotation を強制する」という非 DPoP 経路のポリシー**は、いずれのタスクでも正面から扱われていない。`p1-public-client-token-endpoint.md` は「public client が client_id だけで token endpoint を使えるようにする」認証面の話であり、ローテーション強制とは別レイヤである。

## 4. 参照資料

- OAuth 2.1 draft（draft-ietf-oauth-v2-1-15）§4.3.1 — https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1 （Refresh Token Grant。public client は sender-constrained or rotation が MUST）
- RFC 9700（OAuth 2.0 Security BCP）§4.14 — https://www.rfc-editor.org/rfc/rfc9700#section-4.14 （Refresh Token Protection。"refresh tokens for public clients MUST be sender-constrained or use refresh token rotation"）
- RFC 6749 §1.1 / §2.1 — https://www.rfc-editor.org/rfc/rfc6749#section-2.1 （public / confidential クライアントの定義）
- 関連既存資料（本ファイルでは詳細を繰り返さない）:
  - 📌 `study-material/refresh-token-rotation-replay-grace.md`（rotation 機構と誤検知緩和）
  - 📌 `study-material/done/oauth-security-bcp-rfc9700.md`（BCP チェックリスト）
  - 📌 `tasks/T-019-dpop.md`（sender-constrained 経路）
  - 📌 `tasks/p1-public-client-token-endpoint.md`（public client の認証）
  - 📌 `tasks/p1-refresh-token-absolute-lifetime.md`（絶対有効期限）

## 5. 現在の実装確認

### 5.1 refresh 経路（`packages/core/src/token-request.ts`）

- `RefreshTokenInfo`（161–209 行）に `clientId` は持つが、**「public か confidential か」を表すフィールドが無い**
- `TokenClientInfo`（81–98 行）に `tokenEndpointAuthMethod`（`'client_secret_basic' | 'client_secret_post' | 'none'`）はあり、`'none'` が public client を表しうる。ただし refresh 経路（373–469 行）はこの値を**ローテーション要否の判断に一切使っていない**
- 再利用検知（400–408 行）と grantId 一括失効（`revokeTokensByGrantId`）は実装済み。しかし「旧 RT を used にする＝ローテーションを実行する」処理は core の外（呼び出し側）にあり、`validateTokenRequest` のコメント（452–455 行）も「旧 RT の失効は呼び出し側が新トークン保存後に行う」と明記している
- すなわち **core はローテーションの『部品』は提供するが、『public client では必ずローテーションする』という強制はしていない**

### 5.2 帰結

生成された Provider が confidential client と同じコードパスで public client を扱い、ローテーション（旧 RT の used 化）を省略しても、core は何も警告せず通す。この構成はパブリッククライアントで rotation も sender-constrained も無い状態＝ OAuth 2.1 §4.3.1 / RFC 9700 §4.14 違反になりうる。

## 6. 現在の実装との差分

### 6.1 満たしていること

- ローテーション機構（`used` フラグ・再利用検知・grantId 一括失効）✅
- Refresh Token のクライアント binding（`clientId` 不一致拒否、411–416 行）✅
- 再利用検知時の SHOULD 失効 ✅

### 6.2 不足している可能性があること

- 🟠 **client 種別に基づく rotation 強制が無い**: public client（`tokenEndpointAuthMethod === 'none'`）に対して「rotation or sender-constrained のいずれか」を満たすことを core が保証していない
- 🟡 **sender-constrained かどうかを core が知らない**: DPoP/mTLS の binding 情報（`cnf` 等）が `RefreshTokenInfo` に無く、「sender-constrained だからローテーション不要」という分岐も判定できない
- 🟡 **生成テンプレートが仕様違反構成を作れる**: rotation を省いた public client 構成を生成しても検知されない

### 6.3 セキュリティ上の差分

- パブリッククライアント（SPA・ネイティブアプリ）は client_secret を持たないため、盗まれた Refresh Token がそのまま再利用できる。ローテーションが無いと、漏洩 RT が無期限に悪用される
- ローテーションがあれば「盗まれた RT は一度使われると無効化される（または正規ユーザとの競合で再利用検知される）」ため、漏洩の影響を限定できる

### 6.4 Basic OP として確認すべきこと

- Basic OP Conformance は public client の RT 保護を直接テストしないため、**本件は Basic OP 必須ではない**。ただし OAuth 2.1 / RFC 9700 準拠を掲げる以上、public client を扱うなら満たすべき MUST であり、本リポジトリの「Fidelity（仕様忠実性）」軸に直結する。

## 7. 改善・追加を検討する理由

- **なぜ価値があるか**: 本リポジトリは public client 認証（`tokenEndpointAuthMethod: 'none'`）と rotation 機構の両方を既に持つ。あとは「public のとき rotation or sender-constrained を要求する」という**ポリシーの結節点**が欠けているだけで、ここを埋めると OAuth 2.1 §4.3.1 の MUST を実際に担保できる。
- **Basic OP 必須か拡張か**: Basic OP 必須ではないが、OAuth 2.1 準拠（とりわけ SPA/ネイティブ向け）として MUST。拡張というより「public client を正式サポートするなら必須の付帯条件」。
- **導入しやすさ**: `tokenEndpointAuthMethod === 'none'` で public を判別でき、rotation 機構も既存。判定と「rotation 未実施なら警告/エラー」を足す程度で接続できる。
- **既存実装との接続**: `tasks/p1-public-client-token-endpoint.md`（public client 認証）と同時に設計すると整合が良い。sender-constrained 例外は `tasks/T-019-dpop.md` の `cnf`/binding 情報が入った段階で分岐に組み込める。
- **利用者メリット**: PoC 開発者が SPA を試すとき、デフォルトで安全側（rotation 強制）になる。「public client は rotation しないと弾かれる」挙動を観測でき、仕様学習にもなる。
- **実装しない場合のリスク**: 生成コードをベースに本番化した利用者が、気付かず OAuth 2.1 違反かつ漏洩 RT が無期限悪用される構成を作る。OSS の参考実装としての信頼性を損なう。

## 8. 実装方針の候補

> 最終判断は人間が行う。以下は判断材料。

- **方針A（発行時ガード）**: Refresh Token を**発行する**ヘルパー側で、client が public かつ sender-constrained でない場合に「rotation を有効化する」ことを必須化する。`issueRefreshToken` 系のオプションで `rotation: 'required'` を public client に強制。
  - 利点: 「発行された時点で rotation 前提」が保証される。
  - 欠点: 実際の rotation 実行は依然 store 操作（呼び出し側）に依存。
- **方針B（消費時アサーション）**: refresh grant の検証で、client が public かつ binding 情報が無い（sender-constrained でない）のに、呼び出し側が「旧 RT を used にしない（rotation しない）」運用を選んでいることを検出する手段を core が持つのは難しい。よって core では「public client の RT は rotation 必須である」という**契約（型 or ドキュメント）を明示**し、`RefreshTokenInfo` に `senderConstrained?: boolean` を追加して、public かつ未 sender-constrained の RT を非ローテーション運用したときに lint/テストで気付ける形にする。
  - 利点: 仕様の意図を型・契約として残せる。
  - 欠点: 実行時強制ではなく開発時の気付き寄り。
- **方針C（生成テンプレート側で担保）**: core は機構提供に徹し、CLI 生成 Provider のテンプレートで「public client は rotation 必須」を実装・テスト化する（`study-material/cli-framework-portability-and-web-standard-handler.md` の方針に沿う）。
  - 利点: core の責務（純ロジック）を保てる。利用者が触る生成コードに正しい既定が入る。
  - 欠点: core 単体利用者（高度ユースケース）には強制が効かない。
- **sender-constrained 例外の扱い**: いずれの方針でも、DPoP/mTLS（`tasks/T-019-dpop.md`）で sender-constrained な RT は rotation 免除できる。`RefreshTokenInfo` に binding 有無を表すフィールドを用意し、「sender-constrained なら rotation 強制をスキップ」の分岐を将来差し込めるようにしておく。

## 9. タスク案

- [ ] refresh 経路で client 種別（`tokenEndpointAuthMethod === 'none'` = public）を判別できるよう `RefreshTokenInfo` / 検証 context を見直す
- [ ] `RefreshTokenInfo` に sender-constrained 有無を表すフィールド（例: `senderConstrained?: boolean`）を追加するか判断する
- [ ] public client かつ非 sender-constrained の RT について「rotation 必須」を方針A〜Cのどれで担保するか決定する
- [ ] 決定方針に沿って core もしくは生成テンプレートにガード/契約を実装する
- [ ] テスト: public client が rotation 無しで RT を再利用しようとした構成を検知/拒否できること
- [ ] テスト: confidential client は rotation 任意（RECOMMENDED）で従来どおり動くこと
- [ ] テスト: sender-constrained（将来 DPoP）な public client RT は rotation 強制から除外されること（DPoP 実装後）
- [ ] `tasks/p1-public-client-token-endpoint.md` と本件の設計を整合させ、必要なら相互参照を張る
- [ ] `study-material/done/oauth-security-bcp-rfc9700.md` のチェックリスト該当行から本ファイルへ参照を追記する
