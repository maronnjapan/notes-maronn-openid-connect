# CORS `Access-Control-Expose-Headers` 未設定でブラウザクライアントが `WWW-Authenticate` 等を読めない

## 1. タイトル

生成コードの CORS ミドルウェアが `Access-Control-Expose-Headers` を設定していないため、クロスオリジンのブラウザクライアント（SPA）が UserInfo / Token エンドポイント応答の `WWW-Authenticate`（Bearer チャレンジ）など非セーフリストのレスポンスヘッダを JavaScript から読めない問題。

## 2. このトピックで確認したいこと

- 生成コードの CORS 設定は `origin` / `allowMethods` / `allowHeaders` / `maxAge` のみを設定し、`exposeHeaders`（= `Access-Control-Expose-Headers`）を設定していない
- CORS の既定では、レスポンスの「CORS セーフリストレスポンスヘッダ」（`Cache-Control`, `Content-Language`, `Content-Length`, `Content-Type`, `Expires`, `Last-Modified`, `Pragma`）以外はクロスオリジンの `fetch`/`XHR` から読めない。`WWW-Authenticate` はこれに含まれないため、SPA は Bearer エラーチャレンジの内容（`error`, `error_description`, `scope`）をヘッダから取得できない
- 本トピックは既存の CORS ファイルが扱う「リクエスト側（プリフライト・`Access-Control-Allow-Origin`・`Authorization` の許可）」とは別機構である「レスポンス読み取り側（Expose-Headers）」の差分を扱う

## 3. 関連する仕様・基準

共通の CORS（プリフライト・`Allow-Origin`・`*` と `Authorization` の制約）の説明は重複させない。既存の確定事項:

- プリフライト・`Access-Control-Allow-Origin`・`allowHeaders`（`Authorization` を許可すると `*` オリジンが使えない等）: `study-material/cors-cross-origin-support.md`

本トピック固有の差分（レスポンスヘッダの露出）に関する根拠:

- **Fetch Standard（WHATWG）— CORS-exposed header name**: レスポンスのうち JavaScript から読めるのは「CORS セーフリストレスポンスヘッダ」＋`Access-Control-Expose-Headers` に列挙されたヘッダのみ。列挙されないヘッダは `Headers` オブジェクトから読めない
- **RFC 6750 §3（The WWW-Authenticate Response Header Field）**: Bearer トークンのエラー（`invalid_token` / `insufficient_scope` 等）は `WWW-Authenticate` ヘッダで機械可読に返される。UserInfo などのリソースアクセスで、クライアントがこのチャレンジを読めることに意味がある
- **OIDC Core 1.0 §5.3.3（UserInfo Error Response）**: UserInfo のエラーは RFC 6750 の Bearer エラー方式（`WWW-Authenticate`）で返す

留保（事実の切り分け）:

- UserInfo/Token の**エラー本文**（JSON の `error` / `error_description`）は `Content-Type: application/json` のボディに含まれ、ボディはデフォルトで読める。したがって「エラー内容を全く取得できない」わけではない。読めないのは**ヘッダ由来の情報**（`WWW-Authenticate` の `error`/`scope` 属性、`realm`、将来の `DPoP-Nonce` 等）
- `Access-Control-Expose-Headers` を設定するかは相互運用性の hardening であり、Basic OP 認定の MUST ではない（要一次資料確認だが、Basic OP テストはサーバ間/直接 HTTP 前提でブラウザ CORS を主対象にしない）

## 4. 参照資料

- Fetch Standard（WHATWG）— https://fetch.spec.whatwg.org/ （"CORS-exposed header name" / "CORS-safelisted response-header name"）
- MDN: Access-Control-Expose-Headers — https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Access-Control-Expose-Headers
- RFC 6750 §3 WWW-Authenticate Response Header Field — https://www.rfc-editor.org/rfc/rfc6750#section-3
- OpenID Connect Core 1.0 §5.3.3 UserInfo Error Response — https://openid.net/specs/openid-connect-core-1_0.html
- 本リポジトリ内: `study-material/cors-cross-origin-support.md`（リクエスト側 CORS。本ファイルはレスポンス露出側の差分）

## 5. 現在の実装確認

- `packages/cli/src/frameworks/hono/templates.ts:181-187`:
  - `protectedCors = cors({ origin: corsOrigins, allowMethods: ['POST','GET','OPTIONS'], allowHeaders: ['Authorization','Content-Type'], maxAge: 600 })` — `exposeHeaders` 指定なし
  - `publicCors = cors({ origin: '*', allowMethods: ['GET','OPTIONS'], maxAge: 600 })` — 同上
  - `protectedCors` は `/token` `/userinfo`（および introspection/revocation）に適用（`templates.ts:188-190` 付近）
- `WWW-Authenticate` を実際に設定している箇所（露出させたい対象）: `packages/cli/src/frameworks/hono/templates.ts` の UserInfo/Token エラー応答（Bearer チャレンジ生成箇所）
- `packages/cli/src/frameworks/web-standard/templates.ts:567-579`: 自前 CORS ヘルパも `allowMethods` を `Access-Control-Allow-Methods` に反映するが `Access-Control-Expose-Headers` を出力しない

## 6. 現在の実装との差分

満たしていること:

- クロスオリジンからの `Authorization` ヘッダ付きリクエスト（プリフライト → 実リクエスト）は許可設定済み（既存 CORS ファイルの成果）
- UserInfo/Token のエラー**本文**（JSON）はボディで返り、デフォルトで読める

不足している可能性があること:

- 🟡 **`WWW-Authenticate` が SPA から読めない**: クロスオリジンの UserInfo 呼び出しで `insufficient_scope` 等が返っても、SPA は `response.headers.get('WWW-Authenticate')` で `null` を得る。増分認可（不足スコープの検出→再認可）のヘッダ駆動フローが組めない
- 🟡 **将来のヘッダ拡張の露出漏れ**: DPoP（`DPoP-Nonce`）や `Deprecation`/`Sunset` などをヘッダで返す拡張を後から入れた場合、Expose-Headers 未設定だと同様に読めない

相互運用性の観点で改善した方がよいこと:

- サンプルの想定デプロイ（Workers/Vercel/Fly）では OP とフロントが別オリジンになる構成が一般的で、ブラウザ CORS が実際に効く。Expose-Headers 未設定は「別オリジン SPA でヘッダ由来のエラー情報が取れない」という実運用の摩擦を生む

## 7. 改善・追加を検討する理由

- **利用者体験・相互運用性**: 本リポジトリは PoC 開発者が SPA + 別オリジン OP でフローを検証するユースケースを想定する。`WWW-Authenticate` を露出できないと、SPA が Bearer エラーをヘッダで解釈できず「なぜ弾かれたか」を JS から判別しづらい
- **導入接続性**: 修正は CORS 設定に `exposeHeaders: ['WWW-Authenticate']`（必要なら `Content-Length` 等も）を足すだけで、既存の CORS ミドルウェアに局所追加できる。core ロジックには無影響
- **Basic OP 必須ではない**: 本件は拡張的な hardening であり、認定合否には直接効かない。ただし「本番導入を見据える開発者」をターゲットにする以上、SPA 相互運用の初期摩擦を減らす価値は高い
- **実装しない場合のリスク**: SPA 検証時に `WWW-Authenticate` が読めず、利用者がライブラリ側の問題と誤認する。増分認可・DPoP などヘッダ駆動の拡張を将来入れる際の下地も欠ける

## 8. 実装方針の候補

- 方針A（`WWW-Authenticate` のみ露出）: `protectedCors` に `exposeHeaders: ['WWW-Authenticate']` を追加。最小差分で Bearer チャレンジを読めるようにする
- 方針B（設定注入）: `createApp` の options に `exposeHeaders?: string[]` を追加し、利用者が露出ヘッダを制御できるようにする（既定は `['WWW-Authenticate']`）。拡張ヘッダを足す将来に強い
- 方針C（現状維持 + 文書化）: 露出は入れず、生成コード/README に「別オリジン SPA では `WWW-Authenticate` を読めない。エラーは JSON ボディを見よ」と明記。コスト最小だが摩擦は残置

露出対象ヘッダの範囲（`WWW-Authenticate` 以外を含めるか）、options 化するか、対象フレームワーク（hono / web-standard）の揃え方は人間が決定する。挙動変更のため CLI テンプレートで実装し、必要なら各 sample の `conformance.test.ts` 生成コードに反映する。

## 9. タスク案

- [ ] 露出対象ヘッダと options 化の要否（方針A/B/C）を決定
- [ ] （TDD）CORS プリフライト/実応答で `Access-Control-Expose-Headers` に `WWW-Authenticate` が含まれることを検証するテストを先に追加
- [ ] `packages/cli` の hono テンプレート `protectedCors`（および必要なら `publicCors`）に `exposeHeaders` を追加
- [ ] `packages/cli` の web-standard テンプレートの自前 CORS ヘルパに `Access-Control-Expose-Headers` 出力を追加
- [ ] （任意）`tests/e2e` の SPA クライアントから UserInfo の `insufficient_scope` チャレンジをヘッダ経由で読めることを検証する E2E を追加
- [ ] 挙動変更が `conformance.test.ts` の想定に関わる場合、生成コード側を更新
