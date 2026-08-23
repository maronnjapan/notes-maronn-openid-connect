# エンドポイントごとの HTTP メソッド強制と `405 Method Not Allowed` / `Allow` ヘッダ

## ステータス

🟡 Medium（相互運用性・ハードニング）/ 未着手

## 1. このトピックで確認したいこと

各エンドポイントが仕様で定められた HTTP メソッドのみを受け付け、**許可されないメソッドに対して適切に `405 Method Not Allowed` と `Allow` ヘッダを返すか**を確認する。

エラー応答の「形式・ステータス・本文」は `study-material/error-response-cross-endpoint.md` が横断的に扱っているが、**「そもそも許可されないメソッドが来たときの挙動（405 か 404 か、`Allow` ヘッダの有無）」は未カバー**。本ファイルはその差分のみを扱う。

確認する観点:

- Token / Revocation / Introspection は **POST のみ**（GET 等は拒否すべき）
- UserInfo は **GET と POST の両方を MUST サポート**（OIDC Core §5.3.1）
- Authorization は GET（POST は任意・実装済み）
- JWKS / Discovery は GET
- 許可外メソッドで `404`（経路なし）ではなく `405` + `Allow: <許可メソッド>` を返せているか

## 2. 関連する仕様・基準

共通の仕様索引は `study-material/basic-op-requirement-traceability.md` を参照。本トピック固有のポイント:

- **OIDC Core 1.0 §5.3.1 UserInfo Endpoint**: 「The Client sends ... using either HTTP GET or HTTP POST. ... The UserInfo Endpoint MUST support the use of the HTTP GET and HTTP POST methods」。すなわち UserInfo は **GET と POST の双方が MUST**。
- **RFC 6749 §3.2 Token Endpoint**: 「The client MUST use the HTTP POST method when making access token requests」。Token Endpoint は POST。
- **RFC 7009 §2.1 / RFC 7662 §2.1**: Revocation / Introspection はいずれも **POST**（`application/x-www-form-urlencoded`）。
- **OIDC Core §3.1.2.1 Authorization Endpoint**: GET を MUST サポート、POST は MAY。本リポジトリは GET/POST 両対応済み（`tasks/done/p0-authorization-endpoint-post.md`）。
- **RFC 9110（HTTP Semantics）§15.5.6 / §10.2.1**: サーバが対象リソースで許可しないメソッドを受けた場合、**`405 (Method Not Allowed)` を返し、`Allow` ヘッダで許可メソッドの一覧を提示しなければならない（MUST generate an Allow header）**。これは HTTP の一般要件であり、OAuth/OIDC エンドポイントにも適用される。

注意: Basic OP 認定の Conformance テストは「許可外メソッドへの 405」を主目的には叩かない。本トピックは **認定ブロッカーではなく、HTTP 仕様適合性・相互運用性・ハードニング**。ただし「UserInfo が GET/POST 両対応」は OIDC §5.3.1 の MUST であり、ここは適合性として重要（実装済みであることの回帰固定が目的）。

## 3. 参照資料

- OpenID Connect Core 1.0 §5.3.1 UserInfo Endpoint（GET/POST 必須）— https://openid.net/specs/openid-connect-core-1_0.html#UserInfo
- OpenID Connect Core 1.0 §3.1.2.1 Authorization Endpoint — https://openid.net/specs/openid-connect-core-1_0.html#AuthRequest
- RFC 6749 §3.2 Token Endpoint — https://www.rfc-editor.org/rfc/rfc6749#section-3.2
- RFC 7009 §2.1 Revocation Request — https://www.rfc-editor.org/rfc/rfc7009#section-2.1
- RFC 7662 §2.1 Introspection Request — https://www.rfc-editor.org/rfc/rfc7662#section-2.1
- RFC 9110 §15.5.6（405）/ §10.2.1（Allow）— https://www.rfc-editor.org/rfc/rfc9110#section-15.5.6
- 本リポジトリ内: `study-material/error-response-cross-endpoint.md`（エラー本文・ステータスの横断ハブ。本ファイルは「メソッド不一致時の挙動」差分のみ）

## 4. 現在の実装確認

route 登録（sample / CLI テンプレートとも同型）:

| エンドポイント | 登録メソッド | ファイル |
|---|---|---|
| `/authorize` | `get` + `post` | `routes/authorize.ts:379-380`、CLI `templates.ts:1087-1088` |
| `/userinfo` | `get` + `post`（共通 handler） | `routes/userinfo.ts:136-137` |
| `/token` | `post` のみ | `routes/token.ts:58` |
| `/revoke` | `post` のみ | `routes/revocation.ts:26` |
| `/introspect` | `post` のみ | `routes/introspection.ts:23` |
| `/.well-known/jwks.json` | `get` のみ | `routes/jwks.ts:15` |
| `/.well-known/openid-configuration` | `get` のみ | `routes/discovery.ts:11` |

- UserInfo の `extractAccessToken` は `c.req.method === 'POST'` で body 抽出を分岐（`routes/userinfo.ts:36`）。GET/POST 両対応は OIDC §5.3.1 を満たしている ✅。
- Token / Revocation / Introspection は `app.post('/')` のみ登録。Hono の既定では、**パスは一致するがメソッドが一致しない**リクエストは（明示的な `app.on` や `405` ハンドラが無い限り）`404 Not Found` にフォールバックし、`Allow` ヘッダも付かない可能性が高い。
- JWKS / Discovery も同様に GET のみ登録で、POST 等は 404 になる見込み。
- リポジトリ内に「許可外メソッド → 405 + Allow」を保証するミドルウェア/テストは見当たらない。

## 5. 現在の実装との差分

満たしていること:

- OIDC §5.3.1 が MUST とする **UserInfo の GET/POST 両対応は実装済み**。
- Authorization の GET/POST 両対応も実装済み。
- 各エンドポイントは正しいメソッドでは正しく動作する。

不足／曖昧な点:

- 🟡 **許可外メソッドが 404 になる（405 でない）可能性**: 例えば `GET /token` が経路不在の 404 になると、クライアント/プロキシ/モニタリングからは「Token Endpoint が存在しない」と区別がつかない。RFC 9110 §15.5.6 では 405 + `Allow` が正しい。
- 🟡 **`Allow` ヘッダが付かない**: 405 を返す場合でも `Allow: POST` 等を提示しないと、RFC 9110 §10.2.1（405 応答は `Allow` を生成 MUST）に反する。
- 🟢 **回帰固定の不在**: UserInfo の GET/POST 両対応（OIDC §5.3.1 の MUST）を保証するテストが薄い場合、将来のリファクタで片方が落ちても気付けない。
- ✅ **`HEAD` の扱い（対応済み）**: GET エンドポイント（Discovery / JWKS / UserInfo-GET）への `HEAD` は、RFC 9110 §9.1（汎用サーバは GET と HEAD を MUST サポート）・§9.3.2（HEAD は GET と同一セマンティクスでボディを返さない）に従い、GET と同一処理をボディ空で返すよう対応済み。Hono はメソッドガードで HEAD を通過させれば GET ハンドラを実行しボディを自動で落とす。web-standard ルータは `dispatchRoute` で GET ルートを実行しボディを剥がす。詳細は `study-material/done/http-head-method-on-get-endpoints.md` / `tasks/done/p2-http-head-method-on-get-endpoints.md`。
- 🟢 **`OPTIONS` の扱い**: CORS プリフライトの `OPTIONS` は既存の CORS ミドルウェア（`apply.ts:133-138`、`study-material/cors-cross-origin-support.md`）が扱うため、本ファイルでは重複させない。

相互運用性の観点:

- 405 + `Allow` を返すことは、HTTP クライアント・API ゲートウェイ・監視ツールが「エンドポイントは存在するがメソッドが違う」と「エンドポイントが無い」を区別できるようにする。デバッグ体験と運用監視の質を上げる。

## 6. 改善・追加を検討する理由

- **価値**: 純粋な HTTP 仕様適合性（RFC 9110）と OIDC §5.3.1 適合性の回帰固定。利用者が生成コードをそのまま本番に使う前提のため、HTTP セマンティクスが正しいほど相手システムとの噛み合わせが良い。
- **Basic OP として必須か**: 405 自体は拡張的ハードニング。ただし **UserInfo の GET/POST 両対応は OIDC の MUST** であり、その回帰テストは適合性として価値が高い。
- **導入しやすさ**: Hono は `app.all('*', ...)` や route 定義に対する 405 ハンドラ、あるいは各エンドポイントを `app.on(['POST'], ...)` + 明示的な 405 フォールバックで容易に表現できる。CLI テンプレートと sample の両方に同型で入れられる。**core のロジック変更は不要**（ルーティング層の話）。CLAUDE.md の方針上、生成コードの修正は `packages/cli` を直す。
- **既存実装との接続**: `apply.ts` / `templates.ts` のルート登録部にミドルウェアを 1 つ足すか、各 `*.post('/')` を `*.on(['POST'], '/')` に統一しつつ 405 フォールバックを共通化する。
- **実装しない場合のリスク**: 軽微だが、HTTP 適合性の穴として残る。監視・デバッグ時に「404 か 405 か」で混乱を生む。

## 7. 実装方針の候補

最終判断は人間が行う。

- **方針A（共通 405 ミドルウェア）**: 各エンドポイントのパスに対し、許可メソッド表（`/token: [POST]`、`/userinfo: [GET,POST]`、…）を持つ薄いミドルウェアを `apply.ts` / `templates.ts` に追加し、メソッド不一致なら `405` + `Allow` を返す。一箇所で表現でき設定漏れに強い。
- **方針B（各ルートで明示）**: 各 route ファイルで `app.on(['POST'], '/', handler)` を使い、`app.all('/', methodNotAllowed(['POST']))` をフォールバックに置く。ローカルで完結するが各ファイルに重複。
- **方針C（UserInfo 回帰テストのみ先行）**: 405/Allow は後回しにし、まず OIDC §5.3.1 の MUST（UserInfo GET/POST 両対応）を固定するテストだけ追加する。最小スコープで適合性の要を守る。
- **方針D（現状維持＋文書化）**: 405 は導入せず、「許可外メソッドは 404 になる」ことを既知の制約としてドキュメント化。コスト最小だが HTTP 適合性の穴は残置。

Hono の正確な「パス一致・メソッド不一致」時の既定挙動（404 か 405 か、`Allow` 付与の有無）は、着手前に実機テストで確認することを推奨（バージョン差異がありうるため）。

## 8. タスク案

- [ ] Hono の「パス一致・メソッド不一致」時の実際の応答（404/405、`Allow` の有無）を実機テストで確定する
- [ ]（TDD）`GET /token` / `GET /revoke` / `GET /introspect` が `405` + `Allow: POST` を返すテストを先に追加（方針A/B採用時）
- [ ]（TDD・適合性）`GET /userinfo` と `POST /userinfo` の両方が成功するテストを追加し、OIDC §5.3.1 の MUST を回帰固定（方針C は最低限これを実施）
- [ ] 方針A採用時: `packages/cli/src/frameworks/hono/templates.ts` と `packages/sample/src/oidc-provider/apply.ts` に許可メソッド表ベースの 405 ミドルウェアを追加（生成コードは cli 側を修正）
- [ ] `OPTIONS`（CORS プリフライト）が 405 ミドルウェアと競合しないことを確認（既存 CORS ミドルウェアとの順序）
- [ ] `study-material/error-response-cross-endpoint.md` に「メソッド不一致時の挙動は本ファイルを参照」とリンクを追加

## 関連トピック

- `study-material/error-response-cross-endpoint.md` — エラー本文・ステータス・ヘッダの横断ハブ（本ファイルは「メソッド不一致時の 405/Allow」差分）
- `study-material/cors-cross-origin-support.md` — `OPTIONS` プリフライトの扱い（本ファイルでは重複させない）
- `tasks/done/p0-authorization-endpoint-post.md` — Authorization の POST 対応（実装済み）
