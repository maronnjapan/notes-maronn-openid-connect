# GET エンドポイントへの HEAD リクエストが 405 になる問題（HTTP MUST 違反）

## 1. タイトル

Discovery / JWKS / UserInfo(GET) など GET を受け付けるエンドポイントに対する `HEAD` リクエストが、生成コードのメソッド強制ミドルウェアによって `405 Method Not Allowed` で拒否される問題。HTTP の汎用サーバ要件（GET/HEAD MUST サポート）に反する。

## 2. このトピックで確認したいこと

- CLI が生成する OP は、パスごとの許可メソッド許可リスト（`OIDC_ENDPOINT_METHODS`）でメソッドを強制する。GET エンドポイントの許可リストには `'GET'` しか無く、`HEAD` が「GET に含意される」扱いになっていないため、`HEAD` が `405` になる
- HTTP セマンティクス上、`HEAD` は `GET` と同一処理でボディを返さないだけであり、GET を提供するサーバは HEAD も提供する義務がある。監視/ヘルスチェック/キャッシュ再検証（条件付きリクエスト）は HEAD を使うことがあり、405 はこれらを壊す
- 本トピックは既存の「405 + `Allow`」タスクが**明示的にスコープ外**とした HEAD の扱いを、独立トピックとして確定させることが目的

## 3. 関連する仕様・基準

共通の HTTP メソッド強制（405 + `Allow` ヘッダ MUST）の説明は重複させない。既存の確定事項:

- 405 応答時に `Allow` を返す MUST（RFC 9110 §15.5.6 / §10.2.1）と、その OIDC エンドポイントへの適用: `study-material/done/http-method-enforcement-and-allow-header.md` / `tasks/done/p2-http-method-405-and-allow.md`
- 上記ファイルは `HEAD` を「GET エンドポイントへの HEAD は別途考慮が要る」として🟢で**明示的に先送り**している（本ファイルがその先送り分を扱う）
- `OPTIONS`（CORS プリフライト）は CORS ミドルウェアの責務で本ファイルの対象外

本トピック固有の差分（HEAD の含意）に関する根拠:

- **RFC 9110（HTTP Semantics）§9.1**: "All general-purpose servers MUST support the methods GET and HEAD."（汎用サーバは GET と HEAD を必ずサポートしなければならない）
- **RFC 9110 §9.3.2（HEAD）**: HEAD は GET と同一のセマンティクスだが、サーバはレスポンスにコンテンツ（ボディ）を送ってはならない。ヘッダは GET と同一であることが期待される
- **RFC 9110 §15.5.6（405 Method Not Allowed）**: 405 は「対象リソースがそのメソッドをサポートしない」場合。GET を提供するリソースは HEAD をサポートしているとみなされるため、HEAD への 405 は不適切

補足（事実と留保の切り分け）:

- OpenID Connect Conformance の Basic OP テストプランが「Discovery/JWKS への HEAD」を専用に検証するかは要一次資料確認。ただし本件は OIDC 認定の合否以前に、**HTTP 汎用サーバ要件（RFC 9110 の MUST）**として満たすべき事項である
- 一部の実行ランタイム/フレームワークは HEAD を GET ハンドラへ自動ルーティングする場合がある（例: HEAD→GET フォールバック）。本リポジトリの生成コードは自前のメソッド許可リストが GET ハンドラより**手前**で 405 を返すため、ランタイム側のフォールバックが効かない点が問題の本質

## 4. 参照資料

- RFC 9110 HTTP Semantics — https://www.rfc-editor.org/rfc/rfc9110.html
  - §9.1 Overview（"MUST support the methods GET and HEAD"）
  - §9.3.2 HEAD（GET と同一セマンティクス・ボディ無し）
  - §15.5.6 405 Method Not Allowed / §10.2.1 Allow
- 本リポジトリ内: `study-material/done/http-method-enforcement-and-allow-header.md`（HEAD を先送りした根拠。本ファイルはその差分）
- 本リポジトリ内: `study-material/cors-cross-origin-support.md`（OPTIONS の扱い。HEAD とは別機構）

## 5. 現在の実装確認

CLI がフレームワークごとに生成するアプリのメソッド強制ミドルウェアが該当箇所:

- `packages/cli/src/frameworks/hono/templates.ts:15-33`:
  - `OIDC_ENDPOINT_METHODS` が `'/.well-known/openid-configuration': ['GET']`、`'/.well-known/jwks.json': ['GET']`、`'/userinfo': ['GET','POST']` を定義
  - `enforceOidcEndpointMethod` が `if (allowed && !allowed.includes(c.req.method))` で許可外を検出し `return c.body(null, 405)`（`Allow` は許可リストの結合）
  - `HEAD` は `['GET']` に含まれないため 405
  - `app.use('*', enforceOidcEndpointMethod)`（`templates.ts:193`）で全パスに適用
- `packages/cli/src/frameworks/web-standard/templates.ts:260`: 同じく `new Response(null, { status: 405, headers: { Allow: allowedMethods.join(', ') } })` を返す許可リスト方式。HEAD は許可リスト外
- 他フレームワーク（express/fastify/nextjs）テンプレートには同等の `OIDC_ENDPOINT_METHODS` パターンは grep 上ヒットしない（メソッド強制の実装差はタスク着手時に要棚卸し）

## 6. 現在の実装との差分

満たしていること:

- 未サポートメソッド（例: GET エンドポイントへの POST）に対する `405 + Allow` は実装済み・RFC 9110 準拠（既存タスクの成果）
- `OPTIONS` プリフライトは CORS ミドルウェアが CORS ミドルウェアの順序で処理（`enforceOidcEndpointMethod` より手前）

不足している可能性があること:

- 🔴 **HEAD の 405**: GET を提供するエンドポイント（Discovery / JWKS / UserInfo-GET）への `HEAD` が 405。RFC 9110 §9.1 の MUST（GET/HEAD サポート）に反する
- 🟡 **HEAD 応答のボディ有無**: 仮に HEAD を GET と同経路で許可した場合、`HEAD` はボディを返してはならない（§9.3.2）。ランタイム/フレームワークが自動でボディを落とすか、明示的に空ボディにするかを確認する必要がある
- 🟡 **`Content-Length` の一貫性**: HEAD は「GET を送っていたら返るであろうヘッダ」を返すことが期待される。`Content-Length` を GET と一致させるか、単に省略するかは実装判断（厳密一致は必須ではない）

Basic OP として提供する上で確認すべきこと:

- 認定テストの合否要件かは要一次資料確認だが、HTTP 汎用サーバ要件として満たすのが望ましい。相互運用性（監視・CDN のキャッシュ再検証・ヘルスチェック）に直接効く

## 7. 改善・追加を検討する理由

- **相互運用性**: 監視ツール・アップタイムチェッカー・CDN のキャッシュ再検証は HEAD を用いることがある。GET エンドポイントが HEAD に 405 を返すと、これらが「エンドポイント異常」と誤判定する。本リポジトリのサンプルは Cloudflare Workers / Vercel / Fly.io など、前段に CDN/プロキシが入る環境を想定しており、HEAD の需要が現実的にある
- **仕様適合（Fidelity）**: RFC 9110 の MUST に反する挙動は、本リポジトリの差別化軸「Fidelity」を損なう。Basic OP フローの正しさとは別レイヤの HTTP 適合性だが、"忠実さ" を掲げる以上は満たす価値が高い
- **導入接続性**: 修正は許可リストに HEAD を含める、または「GET を許可するパスは HEAD も許可し、HEAD はボディを落とす」薄い共通ルールを `enforceOidcEndpointMethod` 相当に足すだけで局所的に導入できる。core のロジックには影響しない（生成コード/アダプタ層の変更）
- **実装しない場合のリスク**: 「HTTP 標準に準拠」を掲げつつ HEAD で 405 を返す不整合が残る。利用者が監視を組んだ時点で顕在化し、ライブラリの不具合と誤認されやすい

## 8. 実装方針の候補

いずれも「GET を許可するエンドポイントは HEAD も許可し、HEAD 応答はボディを持たない」を満たすことを前提に、判断材料として整理:

- 方針A（許可リストに HEAD を含意させる）: `enforceOidcEndpointMethod` で「許可リストに `GET` を含むパスは `HEAD` も許可」と判定を変更。HEAD 通過後は GET ハンドラに委ね、フレームワーク/ランタイムのボディ落としに任せる（Hono/Workers は HEAD で自動的にボディを落とす挙動があるか要確認）
- 方針B（許可リストに明示的に `'HEAD'` を追記）: `OIDC_ENDPOINT_METHODS` の GET エンドポイントに `'HEAD'` を並べる。単純だが「GET があれば HEAD」の含意をリスト重複で表現するため保守性は劣る
- 方針C（HEAD 専用ハンドリング）: HEAD を検出したら GET ハンドラを呼びボディを明示的に破棄して返す薄いラッパを入れる。ボディ非送出（§9.3.2）を実装側で保証できるが実装量が増える
- 方針D（現状維持 + 文書化）: HEAD を非サポートと割り切り、生成コード/README に「HEAD は非対応、監視は GET を使うこと」を明記。実装コスト最小だが RFC 9110 MUST 非充足は残置

方針の選択、HEAD 応答のボディ/`Content-Length` の扱い、対象フレームワーク（hono / web-standard 以外も揃えるか）は人間が決定する。conformance.test.ts への反映が必要な挙動変更のため、CLI テンプレート側で実装し各 sample の契約テストを更新する前提。

## 9. タスク案

- [ ] 方針（A/B/C/D）を決定する（RFC 9110 §9.1 の MUST を満たすことを条件に）
- [ ] （TDD）CLI テンプレート由来の生成コードに対し「GET エンドポイントへの HEAD が 200 かつボディ空」「405 にならない」ことを検証するテストを先に追加
- [ ] `packages/cli` の hono / web-standard テンプレートの `enforceOidcEndpointMethod`（相当）を修正し、GET 許可パスで HEAD を許可（ボディ非送出を保証）
- [ ] 他フレームワーク（express/fastify/nextjs）テンプレートのメソッド強制実装を棚卸しし、HEAD の扱いを統一
- [ ] 各 sample の `conformance.test.ts` を生成するコードを更新し、HEAD の想定挙動を契約テストに反映
- [ ] （任意）`tests/e2e` に Discovery/JWKS への HEAD が 200 になる E2E を追加
- [ ] `study-material/done/http-method-enforcement-and-allow-header.md` の🟢「HEAD 先送り」注記を、本対応で解消した旨に更新
