# 理解資料: Pushed Authorization Requests (PAR)

この資料は、仕様書（specification.md）の要約ではなく、プロジェクト所有者が PAR という機能そのものと「このリポジトリでどう実現されるか」を正確に理解するためのものです。

## 解決する問題

従来の認可リクエストは、ブラウザのアドレスバー経由（フロントチャネル）で OP に届く:

```text
GET /authorize?client_id=web-app&response_type=code&redirect_uri=...&scope=openid&state=...&code_challenge=...
```

この方式には構造的な弱点がある。

1. **改竄可能**: パラメータはユーザー（と、ユーザー環境内の攻撃者）の手を経由する。OP に届くまで完全性の保証がない
2. **漏洩可能**: クエリ文字列はブラウザ履歴・プロキシログ・Referer に残る。`login_hint` などの PII や `claims` の内容が露出する
3. **誰が送ったか分からない**: 認可エンドポイントにはクライアント認証がない。client_id は自称にすぎず、OP がクライアントの正当性を確認できるのはトークン交換の時点（ユーザーがログイン・同意した後）
4. **サイズ制限**: `claims` パラメータ等を使うと URL が実用限界を超えることがある

PAR はこれを「認可リクエストの内容を先にバックチャネルで OP に預け、ブラウザには預かり証（`request_uri`）だけを通す」ことで解決する。

## 背景標準

- **RFC 9126** (2021, Proposed Standard): PAR 本体
- **RFC 6749**: クライアント認証規則（PAR エンドポイントは token endpoint と同じ規則を使う）
- **RFC 9101 (JAR)**: 認可リクエストを署名付き JWT にする仕様。PAR とは独立だが組み合わせ可能。本リポジトリの既存 `request-object` 機能は JAR の by value 版に相当する
- **OIDC Core 1.0 §6.2**: `request_uri` パラメータの元々の定義（クライアントがホストする URL を OP がフェッチする方式）。PAR はこの「フェッチする」方式を「OP 自身が発行した URN を引く」方式に置き換えたもの
- **FAPI 2.0 Security Profile**: PAR を必須化している上位プロファイル。PAR の実用上の重要性は主にここから来ている。なお OAuth 2.0 Security BCP（RFC 9700）は PAR を §4.1.3 で「クライアント認証と併用すれば認可リクエストの出所・完全性を検証できる手段」として挙げるのみで、一般的な使用推奨の規範文言はない（Review 2 で原文確認）

## 基礎概念

- **フロントチャネル / バックチャネル**: ブラウザのリダイレクトを経由する通信がフロントチャネル、クライアントサーバーと OP が直接 HTTPS で話すのがバックチャネル。バックチャネルは改竄・盗聴のリスクが構造的に低く、クライアント認証もできる
- **request_uri（URN 形式）**: `urn:ietf:params:oauth:request_uri:6esc_11ACC5bwc014ltc14eY22c` のような参照値。URL ではないので誰もフェッチできない。OP 内部のストアを引くキーにすぎない
- **単回使用（one-time use）**: 同じ request_uri は一度しか使えない。盗まれてもリプレイできない

## 登場人物

| 役割 | このリポジトリでの対応物 |
|---|---|
| クライアント | tests/e2e/apps の E2E 専用クライアント（PAR 対応を追加する） |
| 認可サーバー (OP) | `samples/*` の CLI 生成アプリ。PAR エンドポイントは `--enable par` 時のみ生成される |
| PAR エンドポイント | 生成コード `oidc-provider/par.ts`（新規）。中身は `@maronn-openid-connect/experimental/par` のステップ関数 |
| 認可エンドポイント | 既存の生成コード。「URN なら展開する」前段フック（try 内先頭）と、解決失敗（`invalid_request_uri`）を非リダイレクトで描画する catch 分岐が追加される |
| ストア | 利用者が差し替える `PushedAuthorizationRequestStore`。既存の認可コードストア等と同じ resolver/store 契約スタイル |

## 通常フロー

1. クライアントが `POST /par` に認可パラメータ一式＋クライアント認証情報を送る
2. OP はクライアントを認証し、パラメータを（認可エンドポイントで行うのと同じ規則で）検証し、ストアに保存して `201 {request_uri, expires_in: 60}` を返す
3. クライアントはブラウザを `GET /authorize?client_id=web-app&request_uri=urn:...` へ誘導する
4. OP は URN をストアから**取り出しつつ削除**（単回使用）し、預かっていたパラメータに展開して、以降は完全に既存の Authorization Code Flow として処理する（ログイン → 同意 → code 発行 → token 交換）

## 失敗フロー

- **PAR 時点で不正**（redirect_uri 未登録、scope 不正など）: その場で 400 JSON。**ユーザーが画面を見る前に失敗が確定する**のが PAR の利点。リダイレクトは発生しない
- **request_uri が期限切れ / 使用済み / 他クライアントの物 / 不存在**: 認可エンドポイントが `invalid_request_uri` を返す。この場合**リダイレクトは発生せず**、OP のエラーページ（または JSON）が表示される。信頼できる redirect_uri が確立していないためで、失敗種別も外部から区別できない固定応答にする（詳細は specification.md「エラー処理」）
- **PAR を使わず直接 /authorize に来た**（PAR 強制モード時）: `invalid_request`

## セキュリティモデルと脅威対策

PAR の安全性は「参照値は推測不能・短命・単回使用・クライアント紐付き」の4点で成り立つ。

| 脅威 | 対策 |
|---|---|
| 参照値の推測 | 暗号論的乱数で生成（RFC 9126 §2.2 MUST）。core の `generateRandomString` を利用 |
| 盗んだ request_uri のリプレイ | 単回使用（consume 時に削除）＋ 60 秒期限 |
| 攻撃者クライアントが他人の request_uri を使う | authorize の client_id と pushed 時の client_id の一致検証（RFC 9126 §2.2「request_uri MUST be bound to the client」の実現） |
| 未認証者が偽リクエストを積む | PAR エンドポイントは token endpoint と同じクライアント認証を要求 |
| SSRF | この実装は request_uri を**一切フェッチしない**（URN のみ）。OIDC Core §6.2 の URL 方式で問題になる SSRF が構造的に存在しない |

重要な理解: PAR は state/nonce/PKCE を**置き換えない**。認可レスポンス側の攻撃（コード横取り等）への対策は従来どおり PKCE 等が担う（RFC 9126 §7.5）。

## リクエスト・レスポンス実例

```http
POST /par HTTP/1.1
Host: op.example.com
Content-Type: application/x-www-form-urlencoded
Authorization: Basic d2ViLWFwcDpzZWNyZXQ=

response_type=code&client_id=web-app&redirect_uri=https%3A%2F%2Fclient.example%2Fcb
&scope=openid%20profile&state=af0ifjsldkj&nonce=n-0S6_WzA2Mj
&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256
```

```http
HTTP/1.1 201 Created
Content-Type: application/json
Cache-Control: no-cache, no-store

{
  "request_uri": "urn:ietf:params:oauth:request_uri:6esc_11ACC5bwc014ltc14eY22c",
  "expires_in": 60
}
```

```http
GET /authorize?client_id=web-app&request_uri=urn%3Aietf%3Aparams%3Aoauth%3Arequest_uri%3A6esc_11ACC5bwc014ltc14eY22c HTTP/1.1
```

## データ構造

ストアに保存されるレコード（`PushedAuthorizationRecord`）:

```typescript
{
  requestUri: 'urn:ietf:params:oauth:request_uri:<乱数参照値>',
  clientId: 'web-app',
  params: { response_type: 'code', redirect_uri: '...', scope: '...', ... }, // 受領時のパラメータをそのまま保持
  createdAt: Date,
  expiresAt: Date,  // createdAt + 60秒（デフォルト）
}
```

ストア契約は `save` と `consume`（取得と同時に削除）の 2 メソッドのみ。`get` を提供しないのは意図的で、「読むだけ」の操作を契約から排除して単回使用を型レベルで強制するため。

## 用語集

| 用語 | 意味 |
|---|---|
| PAR | Pushed Authorization Requests。認可リクエストの事前預け入れ |
| request_uri (URN) | 預けたリクエストへの参照値。`urn:ietf:params:oauth:request_uri:` で始まる |
| request_uri (URL, OIDC §6.2) | クライアントがホストする Request Object の URL。**本機能では非対応のまま**（core が `request_uri_not_supported` で拒否し続ける） |
| Request Object / JAR | 認可リクエストを JWT 化したもの。既存 `request-object` 機能。PAR とは別物 |
| require_pushed_authorization_requests | PAR の使用を強制するモード |

## core機能・類似機能との違い

- **`request-object`（既存機能）との違い**: request-object は「パラメータを署名付き JWT にして by value で送る」（完全性＋否認防止）。PAR は「パラメータをバックチャネルで預ける」（完全性＋機密性＋事前クライアント認証）。両者は直交し、RFC 9126 §3 では併用も定義されているが、本実装の初期スコープでは併用は非対応（specification.md 非目標参照）
- **core が `request_uri` を拒否する現状との関係**: core の拒否ロジック（`authorization-request.ts` の `rejectUnsupportedRequestParams`）は変更しない。experimental の前段フックが URN を展開して `request_uri` をパラメータから除去してから core に渡すため、core からは通常の認可リクエストにしか見えない。URN 前置詞に一致しない `request_uri`（URL 等）は前段フックが素通しし、従来どおり core が `request_uri_not_supported` で拒否する

## Experimentalにする理由

認可エンドポイントの入口に前段フックを挿す設計と、新規のストア契約（`consume` セマンティクス）が、実利用のフィードバックなしに固定するには早いため。core を一切変えないので、Experimental のまま出して壊しながら直せる。

## 誤解しやすい点

1. **「PAR = リクエストの暗号化・署名」ではない**。内容保護はバックチャネル TLS によるもの。署名が欲しければ JAR（request-object）
2. **PAR は認可レスポンスを保護しない**。code 横取り対策は引き続き PKCE
3. **`request_uri` の単回使用は RFC 上は SHOULD** だが、本実装は MUST 運用（consume で強制）。ブラウザリロードで再送された場合は失敗するが、これは意図した挙動（RFC 9126 §4 が MAY で許す「UA リロード起因の重複許容」を採らない）
4. **PAR エンドポイントのエラーはリダイレクトされない**。認可エンドポイントのエラー処理（redirect_uri へのエラーリダイレクト）とは別系統で、token endpoint 型の JSON エラー
5. **public client も PAR を使える**。クライアント認証は token endpoint と同一規則なので、public client は client_id の提示のみ（RFC 9126 §2.1）。「PAR = confidential client 専用」ではない

## 実装後の利用方法

```bash
# PAR 有効で OP を生成
maronn-oidc generate hono --enable par
# 生成物: oidc-provider/par.ts が追加され、authorize に前段フック、discovery に
# pushed_authorization_request_endpoint が追加される。@maronn-openid-connect/experimental を依存に追加する
```

利用者は生成された in-memory ストアを Redis 等に差し替える場合、`save`/`consume` の 2 メソッド（consume は atomic な取得＋削除）を満たせばよい。

## 一次資料の読み方ガイド

RFC 9126 は短い（本文 約20ページ）。読む順序:

1. **§1 Introduction**: 解決したい問題（このガイドの「解決する問題」に対応）
2. **§2.1〜2.3**: PAR エンドポイントの入出力。実装の中心。§2.1 の「validate the pushed request as it would an authorization request」が事前検証の根拠
3. **§4**: 認可エンドポイント側の挙動。「MUST validate ... as it would any other authorization request」が「展開後に通常パイプラインへ流す」設計の根拠
4. **§5〜6**: メタデータ 2 種（AS 用・クライアント用）。本実装は AS 用のみ
5. **§7 Security Considerations**: 仕様書のセキュリティ要件表の出典
6. **§3（request パラメータ）は初期スコープでは読み飛ばしてよい**（非目標）

## 昇格判断の観点

- ストア契約（save/consume）が Redis・SQLite 等の実ストア実装で変更なしに成立したか
- 前段フック方式が 5 テンプレートで無理なく維持できているか（コピー起因の不整合が起きていないか）
- FAPI 2.0 対応を本リポジトリのロードマップに載せるか（載せるなら PAR は core 昇格が必須になる）
- 昇格時は core の discovery 型・authorize パイプラインへの正式統合が必要（specification.md「将来の昇格考慮」参照）
