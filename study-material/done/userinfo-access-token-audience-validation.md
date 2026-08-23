# UserInfo / リソースサーバにおけるアクセストークン `aud` 検証

## 1. タイトル

UserInfo エンドポイント（OP 自身が保護リソースとして振る舞う場面）が、提示されたアクセストークンの `aud`（audience）を検証していない問題の整理。`resource` indicator（RFC 8707）と JWT アクセストークン（RFC 9068）を併用した場合の confused deputy / トークンリプレイ耐性を確認する。

## 2. このトピックで確認したいこと

`packages/core/src/userinfo.ts` の `handleUserInfoRequest` は、アクセストークンの「存在・有効期限・`openid` scope」のみを確認し、トークンの `aud` が UserInfo エンドポイント（= OP 自身）向けであることを一切検証していない。

一方で `packages/core/src/token-response.ts` の `buildAccessTokenAudience` は、アクセストークンの `aud` に「UserInfo エンドポイント URL（恒久メンバ）＋要求された `resource` indicator」を合成して載せる設計になっている。つまり aud には **OP 以外のリソース識別子が混入しうる**。

- このとき、別リソース（RFC 8707 `resource=https://api.example.com` 等）向けに発行されたアクセストークンが、UserInfo エンドポイントへ提示されたら現状は通ってしまうのか
- RFC 9068 が要求する「リソースサーバによる `aud` 検証」を UserInfo エンドポイントは満たしているのか
- 満たすべきだとすれば core のどこに検証フックを置くのが自然か

を確認したい。

## 3. 関連する仕様・基準

> 共通仕様の索引（OIDC Core / OAuth 2.1 の章立て）は `study-material/userinfo-endpoint-comprehensive.md` と `study-material/basic-op-requirement-traceability.md` を参照。本ファイルでは「UserInfo を保護リソースとして見たときの aud 検証」という差分のみを扱う。

### 3.1 RFC 9068 §4（Validating JWT Access Tokens）

JWT アクセストークンを受け取ったリソースサーバの検証手順として、**`aud` の検証が MUST** とされている。要点（公式文言の要約）:

- リソースサーバは `aud` クレームに「自分自身を指すリソース識別子」が含まれていることを検証しなければならない（MUST）
- `aud` に当該リソースサーバの識別子が含まれない JWT アクセストークンは拒否しなければならない（MUST reject）
- 検証失敗時のエラーコードは `invalid_token`

UserInfo エンドポイントは OIDC Core §5.3 において **アクセストークンで保護されたリソース**であり、JWT アクセストークン（RFC 9068）を採用した OP では UserInfo もこの検証義務の対象になる。`buildAccessTokenAudience` が UserInfo エンドポイント URL を aud に載せているのは、まさに「UserInfo が自身を aud として期待する識別子」を用意しているためであり、検証側が未実装だと設計意図が片側だけになっている。

### 3.2 RFC 8707（Resource Indicators）との関係

`resource` パラメータを使うと、クライアントは「このトークンはどのリソース向けか」を指定できる。OP は要求された `resource` を aud に反映する（本リポジトリは `buildAccessTokenAudience` で対応済み）。

RFC 8707 の狙いは **audience を絞ることでトークンの濫用範囲を限定する**ことにある。発行側が aud を絞っても、**受領側（UserInfo）が aud を見ない**なら、絞り込みの効果は無効化される。すなわち「API 専用に発行されたトークンで UserInfo を呼べてしまう」状態は、RFC 8707 を導入した意味を損なう。

### 3.3 OAuth 2.1 / OAuth 2.0 Security BCP（RFC 9700）との関係

confused deputy / トークン誤用（あるリソース向けトークンを別リソースに提示）への対策として、リソースサーバ側の audience 検証が推奨される。これは `study-material/done/oauth-security-bcp-rfc9700.md` のチェックリストでは「JWT AT の構造」側で触れられているが、**UserInfo を受領リソースとして見た aud 検証**は同ファイルでも独立論点として展開されていない。

### 3.4 不透明（opaque）トークンの場合

opaque トークンでは aud はトークン文字列に含まれず、`AccessTokenInfo.audience`（`userinfo.ts` 52–72 行）として store に保存された値を参照する。RFC 9068 は JWT 限定の規定だが、opaque でも「保存された audience を UserInfo が検証する」ことで同等の保護が得られる。core は両形式で `AccessTokenInfo.audience` を一様に扱えるため、検証ロジックは形式非依存に書ける。

## 4. 参照資料

- RFC 9068 §4 — https://www.rfc-editor.org/rfc/rfc9068#section-4 （Validating JWT Access Tokens。リソースサーバは `aud` に自分を指す識別子が含まれることを検証 MUST、含まれなければ `invalid_token` で拒否）
- RFC 8707 — https://www.rfc-editor.org/rfc/rfc8707 （Resource Indicators for OAuth 2.0。`resource` による audience 限定の意図）
- OIDC Core 1.0 §5.3 — https://openid.net/specs/openid-connect-core-1_0.html#UserInfo （UserInfo はアクセストークンで保護された保護リソース）
- RFC 6750 §3 — https://www.rfc-editor.org/rfc/rfc6750#section-3 （`invalid_token` の `WWW-Authenticate` 応答形式）
- RFC 9700（OAuth 2.0 Security BCP）— https://www.rfc-editor.org/rfc/rfc9700 （audience 制限とトークン誤用対策。`study-material/done/oauth-security-bcp-rfc9700.md` 参照）

## 5. 現在の実装確認

### 5.1 aud を生成する側（実装済み）

- `packages/core/src/token-response.ts` `buildAccessTokenAudience`（185–196 行）: `userInfoEndpoint`（恒久メンバ）＋ `requested`（RFC 8707 resource）を合成し、空なら `issuer` をフォールバック
- `packages/core/src/access-token.ts`（40–47 行）: RFC 9068 §3 に従い `aud` 非空配列を強制
- すなわち発行側は「UserInfo を含む aud」を確かに載せている

### 5.2 aud を検証すべき側（未実装）

`packages/core/src/userinfo.ts` `handleUserInfoRequest`（253–319 行）の検証は以下のみ:

1. `accessToken` の存在チェック（264–269 行）
2. `accessTokenResolver.findAccessToken` で解決、null なら `invalid_token`（271–277 行）
3. `expiresAt < now` で期限切れ判定（280–286 行）
4. `tokenInfo.scope.includes('openid')` で scope 確認（289–294 行）

`AccessTokenInfo.audience`（67 行に定義）は **introspection（`introspection.ts` 114–115 行）でしか参照されておらず**、UserInfo の検証経路では一度も読まれていない。つまり aud 検証フックが存在しない。

### 5.3 影響の具体例

`resource=https://api.example.com` のみを指定し、OP が UserInfo エンドポイントを aud に含めない構成（または将来 `userInfoEndpoint` 未設定で resource のみを載せる構成）でアクセストークンを発行した場合、そのトークンを `Authorization: Bearer` で UserInfo に提示すると、現状の `handleUserInfoRequest` は通してしまう。`buildAccessTokenAudience` が常に UserInfo URL を載せる現行デフォルトでは表面化しにくいが、**resource indicator を本格採用した瞬間に保護が崩れる**潜在バグである。

## 6. 現在の実装との差分

### 6.1 満たしていること

- 発行側で aud に UserInfo エンドポイントを含める仕組み（`buildAccessTokenAudience`）✅
- JWT AT の aud 非空強制（RFC 9068 §3）✅
- introspection 応答での aud 反映 ✅

### 6.2 不足している可能性があること

- 🟠 **UserInfo 受領時の aud 検証が無い**: RFC 9068 §4 が MUST とする「リソースサーバによる aud 検証」を UserInfo が実施していない（`handleUserInfoRequest` に検証なし）
- 🟡 **検証に必要な「UserInfo 自身の識別子」を core が受け取る口が無い**: `UserInfoRequestContext` に「期待する audience（= UserInfo エンドポイント URL / issuer）」を渡す引数が無いため、検証したくても比較対象を与えられない

### 6.3 セキュリティ上の差分

- resource indicator（RFC 8707）を使う相互運用シナリオで confused deputy が成立しうる（API 専用トークンで UserInfo の PII を取得）
- aud 検証が無いと、aud を絞るという RFC 8707 の設計意図が受領側で無効化される

### 6.4 相互運用性の差分

- RFC 9068 準拠を期待する RP / 監査ツールから見て、UserInfo が aud を無視するのは「準拠していないリソースサーバ」と判定されうる
- 逆に厳格化しすぎると、UserInfo URL を aud に載せていない既存トークンが弾かれる後方互換リスクがある（既定で UserInfo URL を含める現行設計とのすり合わせが必要）

### 6.5 Basic OP として確認すべきこと

- Basic OP Conformance のコアテストは「UserInfo が正しいトークンを受理する」ことを見るもので、aud 不一致トークンを弾く挙動は **Basic OP の必須項目ではない**（aud 検証は RFC 9068 / RFC 8707 を採用した拡張構成での要件）。よって本件は **Basic OP 必須ではなく、resource indicator / JWT AT を使う場合のセキュリティ強化**として位置づけるのが正確。

## 7. 改善・追加を検討する理由

- **なぜ価値があるか**: 本リポジトリは既に JWT AT（RFC 9068）と aud 合成（`buildAccessTokenAudience`）を実装しており、発行側だけが RFC 9068 に沿って受領側が沿っていない「片側実装」状態。受領側の検証を足すことで「OP 自身のリソースサーバ実装」が仕様として一貫する。
- **Basic OP 必須か拡張か**: Basic OP の必須項目ではなく、**resource indicator / JWT AT 採用時のセキュリティ拡張**。OSS 利用者が RFC 8707 を試した瞬間に意味を持つため、検証を試せる土台があることに価値がある。
- **導入しやすさ**: 検証に必要な `AccessTokenInfo.audience` は既に存在し、introspection で読まれている実績がある。`handleUserInfoRequest` に「期待 audience」を渡して `includes` 比較する程度の小改修で済む。
- **既存実装との接続**: `buildAccessTokenAudience` の出力（UserInfo URL を含む aud）と、検証側が期待する「UserInfo URL」は同じ値であるべき。両者を同じ設定値から導出すれば設定の二重管理を避けられる。
- **利用者メリット**: PoC 開発者が「resource を絞ったトークンが他リソースで使えないこと」を実際に観測できる。confused deputy の挙動を手元で検証できるのは本ライブラリのコンセプト（仕様を素早く検証）に合致する。
- **実装しない場合のリスク**: resource indicator を導入した利用者の構成で、API 専用トークンによる UserInfo 不正アクセスが成立する。サンプル / 生成コードがそのまま本番参考にされると事故につながる。

## 8. 実装方針の候補

> 最終判断は人間が行う。以下は判断材料。

- **方針A（オプトイン検証フック）**: `UserInfoRequestContext` に `expectedAudience?: string`（UserInfo エンドポイント URL）を追加。指定時のみ `tokenInfo.audience` に当該値が含まれるか検証し、無ければ `invalid_token`。未指定なら従来どおり検証スキップ（完全後方互換）。
  - 利点: 後方互換・段階導入が容易。Basic OP のみの利用者に影響なし。
  - 欠点: 「検証する/しない」が呼び出し側任せで、デフォルトが緩い。
- **方針B（aud があるときだけ厳格化）**: `tokenInfo.audience` が設定されている場合に限り、`expectedAudience` 必須かつ照合する。opaque で audience 未保存のトークンは従来どおり通す。
  - 利点: 「aud を載せ始めた利用者」に対してのみ自動で保護が効く。
  - 欠点: 挙動が条件分岐的で、利用者が把握しづらい。
- **方針C（検証を別ユーティリティに切り出す）**: `validateAccessTokenAudience(tokenInfo, expected)` を core の共有関数として用意し、UserInfo / 将来の他リソースサーバ実装から再利用。RFC 9068 §4 の他項目（`iss` 一致、`typ=at+jwt` 等）と同じ「リソースサーバ検証」群としてまとめる。
  - 利点: 拡張性が高く、RFC 9068 §4 の検証群を一箇所に集約できる。
  - 欠点: 設計範囲が広がるため、まず方針A/Bで最小実装してから一般化する方が無難。
- **設定の単一化**: いずれの方針でも、`buildAccessTokenAudience({ userInfoEndpoint })` に渡す URL と、検証側 `expectedAudience` を **同じ設定値**から導出するヘルパー / ドキュメントを用意し、不一致による誤検知（自前トークンを弾く）を防ぐ。

## 9. タスク案

- [ ] RFC 9068 §4 の「UserInfo を保護リソースとして見たときの aud 検証」を方針A〜Cのどれで入れるか方針決定する
- [ ] `UserInfoRequestContext` に `expectedAudience`（UserInfo エンドポイント URL）を渡せるようにする
- [ ] `handleUserInfoRequest` で `tokenInfo.audience` に `expectedAudience` が含まれない場合 `invalid_token`（401）を返す
- [ ] `buildAccessTokenAudience` の `userInfoEndpoint` と検証側 `expectedAudience` を同一設定から導出するヘルパー or ドキュメントを用意する
- [ ] テスト: aud に UserInfo URL を含むトークンは受理されること
- [ ] テスト: `resource` 専用（UserInfo URL を含まない）aud のトークンは `invalid_token` で拒否されること
- [ ] テスト: `expectedAudience` 未指定時は従来どおり検証スキップ（後方互換）であること
- [ ] テスト: opaque トークンで `AccessTokenInfo.audience` 未設定の場合の挙動を方針に沿って固定する
- [ ] CLI 生成テンプレートの UserInfo ルートに検証フックの配線を反映するか判断する
- [ ] `study-material/ext-resource-indicators-rfc8707.md` から本ファイルへ「受領側検証」として相互参照を張る
