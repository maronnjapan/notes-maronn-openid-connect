# Introspection / Revocation エンドポイントの Content-Type 検証パリティ

## 1. このトピックで確認したいこと

Token Endpoint は、リクエストボディの `Content-Type` が
`application/x-www-form-urlencoded` であることを `isFormUrlEncoded` で検証してからパースしている。
一方、Introspection（RFC 7662）と Revocation（RFC 7009）の各ルートテンプレートは
**Content-Type を検証せず、いきなり `c.req.parseBody()` を呼んでいる**。

このトピックでは、Introspection / Revocation エンドポイントにも Token Endpoint と同等の
`application/x-www-form-urlencoded` 強制を入れるべきか、その方針を整理する。

> 共通の仕様参照ハブは `study-material/basic-op-requirement-traceability.md` を参照。
> Token Endpoint の Content-Type 検証は `tasks/done/p1-token-endpoint-content-type.md`、
> UserInfo POST の Content-Type 正規化は `tasks/done/p2-userinfo-post-content-type-normalize.md` /
> `study-material/done/...`（userinfo-post-form-body 系）で既に扱っている。
> 本ファイルは「Introspection / Revocation が Token と非対称で Content-Type 未検証である」という
> **エンドポイント間パリティの差分のみ**を扱う。

## 2. 関連する仕様・基準（このトピック固有の差分）

- **RFC 7662 (OAuth 2.0 Token Introspection) §2.1**:
  「The protected resource calls the endpoint using an HTTP `POST` ... with the parameters sent as
  `application/x-www-form-urlencoded` ...」。すなわちボディは form-urlencoded であることが規定される。
- **RFC 7009 (OAuth 2.0 Token Revocation) §2.1**:
  「The client requests the revocation of a particular token by making an HTTP `POST` request ...
  The following parameters are included ... in the request body using the
  `application/x-www-form-urlencoded` format ...」。
- **RFC 6749 §5.2 / RFC 7662 §2.3 / RFC 7009 §2.2.1**: 不正なリクエストはエラー応答を返す。
  Content-Type 不一致への専用エラーコードは定義されていないが、Token Endpoint と同様に
  「パース前に弾く」ことで、非 form ペイロード（`application/json` / `multipart/form-data`）が
  パラメータとして誤解釈されることを防げる。
- 本リポジトリの Token Endpoint は既にこの方針（`RFC 6749 §4.1.3 / OIDC Core §3.1.3.1` を根拠に
  非 form を拒否）を採っており、Introspection / Revocation だけが取りこぼしている。

## 3. 参照資料

- RFC 7662 OAuth 2.0 Token Introspection — https://datatracker.ietf.org/doc/html/rfc7662
  - §2.1「Introspection Request」: ボディは `application/x-www-form-urlencoded`
- RFC 7009 OAuth 2.0 Token Revocation — https://datatracker.ietf.org/doc/html/rfc7009
  - §2.1「Revocation Request」: ボディは `application/x-www-form-urlencoded`
  - §2.2「Revocation Response」: 200 OK / エラー時の挙動
- RFC 9110 §8.3.1: メディアタイプは大文字小文字を区別しない（パラメータ `; charset=...` を含みうる）
- 既存実装の根拠コメント: `packages/cli/src/frameworks/hono/templates.ts` `tokenRouteTemplate` 内
  `isFormUrlEncoded`（Token Endpoint で採用済みの方針）

## 4. 現在の実装確認

- 生成元テンプレート: `packages/cli/src/frameworks/hono/templates.ts`
  - `tokenRouteTemplate`（1274行〜）: `isFormUrlEncoded(contentType)` を定義し、POST ハンドラ冒頭で
    `Content-Type` を検証。非 form の場合は `Cache-Control: no-store` を付けてエラー応答（パース前に拒否）。
  - `introspectionRouteTemplate`（2567行〜）: ハンドラ冒頭で **いきなり `const body = await c.req.parseBody();`**。
    Content-Type 検証なし。
  - `revocationRouteTemplate`（2648行〜）: 同様に **いきなり `const body = await c.req.parseBody();`**。
    Content-Type 検証なし。
- web-standard アダプタの `parseBody`（`packages/cli/src/frameworks/web-standard/templates.ts` 73行〜）は、
  `application/x-www-form-urlencoded` と `formData()` のみを処理する実装。`application/json` ボディを
  送られた場合、フォームとして解釈できず空または不定のパラメータになる（明示的な 4xx ではなく、
  `token` 欠如としての挙動にフォールバックする）。
- 生成物（`samples/express/src/oidc-provider/routes/introspection.ts` / `revocation.ts`）も同じ構造。
  ※ CLAUDE.md の規約に従い、修正は **`packages/cli` のテンプレート側**で行い、samples を直接編集しない。

## 5. 現在の実装との差分

- **満たしていること**
  - Token Endpoint は Content-Type を検証済み（パリティの基準が既にある）。
  - Introspection / Revocation はクライアント認証・`Cache-Control: no-store` 等は実装済み。
- **不足している可能性があること**
  - Introspection / Revocation が Content-Type を検証せず、非 form ボディをパースに通している。
  - 非 form ペイロード時のエラー応答が Token Endpoint と非対称（一貫した 400 にならない）。
- **セキュリティ/堅牢性の観点**
  - 直接的な脆弱性ではないが、`application/json` などを受理しようとして誤ったパラメータ解釈に陥る余地がある。
    入力経路の厳格化（パース前バリデーション）は OAuth エンドポイントの基本的なハードニング。
- **相互運用性の観点**
  - RFC 7662 / 7009 は form-urlencoded を前提とする。誤った Content-Type を黙って受けると、
    クライアント実装側のバグ（JSON 送信など）を顕在化させられず、デバッグを困難にする。
- **Basic OP として確認すべきこと**
  - Introspection / Revocation は Basic OP 必須ではない（RFC 7662/7009 は拡張）。本件は
    「実装済み拡張エンドポイントの仕様適合性・エンドポイント間パリティ」の品質課題。

## 6. 改善・追加を検討する理由

- **なぜ価値があるか**: Token Endpoint だけ厳格で Introspection / Revocation が緩いという非対称は、
  レビューや conformance で「片方だけ通る」混乱を生む。同じ `application/x-www-form-urlencoded` を要求する
  3 エンドポイントで挙動を揃えることは、ライブラリとしての一貫性・予測可能性に直結する。
- **Basic OP 必須か拡張か**: 拡張（RFC 7662/7009）エンドポイントの品質改善。Basic OP 認定の合否には
  直接影響しないが、ライブラリの「Fidelity（忠実性）」という差別化軸（CLAUDE.md）に沿う。
- **導入しやすさ**: Token Endpoint に既に `isFormUrlEncoded` があるため、同じ判定を Introspection /
  Revocation テンプレートにも適用するだけ。ロジックの新規発明は不要。重複を避けるなら共通ヘルパー化も可。
- **接続先**: 各ルートテンプレートのハンドラ冒頭、`parseBody()` の前に Content-Type ガードを挿入。
  エラー時は既存のエラー応答スタイル（`c.json({ error: ... }, 400)` + `Cache-Control: no-store`）に合わせる。
- **メリット**: 利用者＝3 エンドポイントで一貫した入力検証。開発者＝レビュー時の認知負荷低減。
  運用者＝誤った Content-Type のリクエストを明確な 4xx で観測できる。
- **実装しない場合のリスク**: 非 form ボディが黙って `token` 欠如等にフォールバックし、クライアントの
  バグが見えにくい。エンドポイント間の挙動差がドキュメント化されないまま残る。

## 7. 実装方針の候補（人間が最終判断）

- **方針 A（推奨度: 高 / 共通化）**: `isFormUrlEncoded` を 1 箇所（例: 共通ユーティリティ文字列、または
  各テンプレートが共有する小ヘルパー）に定義し、token / introspection / revocation の 3 テンプレートで再利用。
  非 form の場合は `400` + `error: 'invalid_request'` + `Cache-Control: no-store` を返す。
- **方針 B（最小 / 重複許容）**: 各テンプレートに `isFormUrlEncoded` 相当をインラインで複製。共通化の
  リファクタを避けたい場合の最小変更。CLAUDE.md の「重複を避ける」観点では A が望ましいが、テンプレートは
  文字列生成のため共通化に一手間かかる点が判断材料。
- **エラー応答の粒度（判断材料）**: RFC 7662/7009 は Content-Type 不一致の専用エラーを定義しない。
  - 案 1: Token Endpoint と同じく `invalid_request`（400）。一貫性が高い。
  - 案 2: HTTP `415 Unsupported Media Type`。HTTP セマンティクス的には正確だが、OAuth エラー JSON 体裁から外れる。
  - 既存 Token Endpoint の挙動に合わせるなら案 1 を推奨。

## 8. タスク案

- [ ] `isFormUrlEncoded`（または共通ヘルパー）を introspection / revocation の各ルートテンプレートに適用し、
  `parseBody()` 前に Content-Type を検証する（`packages/cli/src/frameworks/hono/templates.ts`）。
- [ ] 非 form Content-Type 時に `400` + `{ error: 'invalid_request', ... }` + `Cache-Control: no-store` を返す。
- [ ] web-standard / 各フレームワークの生成物に反映されること、および `samples/*` の生成結果を確認。
- [ ] 該当 sample の `conformance.test.ts`（生成元: `packages/cli` 内のテスト生成コード）を更新し、
  Introspection / Revocation に `application/json` を送ると 400 になり、`application/x-www-form-urlencoded`
  では従来どおり処理されることを検証するケースを追加する。
- [ ] Token Endpoint の既存 Content-Type テストと挙動が一致していること（パリティ）を確認する。
