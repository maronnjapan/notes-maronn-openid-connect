# `response_mode=form_post`（OAuth 2.0 Form Post Response Mode）対応

## ステータス

🟡 Major（相互運用性）/ 未着手

## 1. このトピックで確認したいこと

OAuth 2.0 Form Post Response Mode（OpenID Foundation の仕様 / 最終版 2015-04）は、認可レスポンスを **URL クエリでも fragment でもなく、`<form method="POST">` の auto-submit によって RP に POST する**配信モード。`response_mode=form_post` を明示することで RP は受け取れる。

Authorization Code Flow（`response_type=code`）でも `response_mode=form_post` は有効な組合せで、認可コードをクエリ経由でブラウザ履歴 / Referer ヘッダー / プロキシログに残したくないユースケース（厳密な PoC、SAML 互換志向）で重視される。

本リポジトリは現状 **クエリ（query）形式のみ**実装しており、`response_mode` パラメータの解釈・分岐が無い。Basic OP の必須範囲ではないが、相互運用性および「`response_modes_supported` を Discovery で広告する」検討（`tasks/p2-discovery-response-modes-supported.md`）と整合させる必要がある。

## 2. 関連する仕様・基準

共通の仕様索引は `study-material/basic-op-requirement-traceability.md` を参照。本トピック固有のポイント:

- **OAuth 2.0 Form Post Response Mode**（OpenID Foundation, 2015-04-04, Final）:
  - RP が `response_mode=form_post` を Authorization Request に含めると、OP は **HTML フォーム** を返し、`onload` で `redirect_uri` に POST 自動送信。
  - フォームには `action="<redirect_uri>"`、`method="POST"`、各認可パラメータを `<input type="hidden">` で出力。
  - レスポンスは `text/html; charset=UTF-8`。
- **OAuth 2.0 Multiple Response Types Encoding Practices（OpenID Foundation, Final）**:
  - `response_mode` の既定値は `response_type` に依存。`response_type=code` の既定は `query`。`response_mode=form_post` を明示できる。
- **OIDC Discovery 1.0**:
  - `response_modes_supported`（任意）に `["query","fragment","form_post"]` を広告できる。
  - 既存タスク `tasks/p2-discovery-response-modes-supported.md` を参照。
- **OAuth 2.1**: 既存の response_mode 仕様を踏襲。`form_post` の扱いは変更なし。
- **セキュリティ Considerations**:
  - 生成する HTML に **CSP nonce 戦略**を入れる場合の干渉に注意（auto-submit `<script>` を使うため `script-src` 制約と衝突しうる）。
  - エラー応答も `form_post` で返すことが可能（`error` / `error_description` をフォームフィールドに）。
  - `redirect_uri` は厳格一致のため、攻撃者が任意 URL に POST させることはできない（既存実装で担保）。

## 3. 参照資料

- OAuth 2.0 Form Post Response Mode（OpenID Foundation, Final）: https://openid.net/specs/oauth-v2-form-post-response-mode-1_0.html
- OAuth 2.0 Multiple Response Type Encoding Practices: https://openid.net/specs/oauth-v2-multiple-response-types-1_0.html
- OIDC Discovery 1.0 §3（`response_modes_supported`）: https://openid.net/specs/openid-connect-discovery-1_0.html#ProviderMetadata

## 4. 現在の実装確認

- `packages/core/src/authorization-request.ts`:
  - `AuthorizationRequestParams` に `response_mode` フィールド **無し**。
  - クエリ / fragment / form_post の分岐ロジック無し。
- 認可レスポンス組立:
  - sample `packages/sample/src/oidc-provider/routes/consent.ts` 等で `redirect_uri?<params>` の `query` 形式のみで返す前提。
- Discovery:
  - `response_modes_supported` を出力できる（`packages/core/src/discovery.ts:85`）が、**設定する場所が無い**（`tasks/p2-discovery-response-modes-supported.md` で対応予定）。
- エラーレスポンス（authorize 経由のリダイレクト error）も同じく query 形式のみ。

## 5. 現在の実装との差分

満たしていること:

- `response_mode=query` の既定挙動は実装されている（Authorization Code Flow の標準動作）。
- redirect_uri は完全一致検証済みなので、`form_post` を導入してもオープンリダイレクト経路は新規には増えない。

不足／要確認:

- 🟡 **`response_mode` の解釈が無い**: 仕様上、未対応の `response_mode` 値を受け取ったら **`unsupported_response_mode`** エラーを返すべき。現状は黙って無視される（query で返却）。
- 🟡 **Discovery 広告の整合性**: `response_modes_supported` を出さないことで「対応していない」を暗黙に示している状態。クライアントが `form_post` を要求する PoC では事前に判別不能。
- 🟢 **Basic OP プロファイル必須要件ではない**: 仕様違反ではない。

## 6. 改善・追加を検討する理由

価値:

- 認可コード／state を **URL に出さない PoC**で必須。Referer 漏れ / プロキシログ漏れ / ブラウザ履歴漏れを嫌うエンタープライズ要件で頻出。
- SAML 連携（HTTP-POST Binding）からのマイグレーション層 PoC で「form_post による配送」を試したい層が一定数いる。
- 実装規模が小さく（HTML テンプレート生成と response_mode 分岐のみ）、コスト対効果が良い。

導入難易度:

- 🟢 **小規模**:
  - response_mode のパース・バリデーション（`query` / `form_post`）と `unsupported_response_mode` エラー応答。
  - HTML テンプレート（必要パラメータの hidden input、auto-submit script）。
  - 既存の認可応答 / 認可エラー応答の両方を分岐させる必要がある。

実装しない場合:

- ブラウザ履歴 / Referer に認可コードが残るリスクを嫌う検証は不可。Basic OP プロファイル外なので仕様準拠としては差分なし。

## 7. 実装方針の候補

### 方針A（非対応の明文化）

- 受け取った `response_mode=form_post` を `unsupported_response_mode` エラーで明示拒否。
- Discovery の `response_modes_supported` には `query` のみを広告（`tasks/p2-discovery-response-modes-supported.md` と整合）。

### 方針B（最小: query + form_post）

- core に `buildAuthorizationResponse(redirectUri, params, mode)` 純関数を追加（mode は `'query' | 'form_post'`）。
- `form_post` の HTML 生成は core のヘルパーとして提供（テンプレ文字列、auto-submit `<form onload>`）。
- Discovery `response_modes_supported: ['query','form_post']` を広告。
- 認可成功 / 認可エラー（redirect で返す系）の両経路で対応。
- `fragment` は Authorization Code Flow では使わないため広告しない。
- 既存の `state` echo、`iss`（`tasks/p1-authorization-response-iss.md`）、`error` / `error_description` も form_post に乗せる。

### 方針C（フルセット: + Web Message Response Mode / OIDC 4.1）

- `response_mode=web_message`（OAuth 2.0 Web Message Response Mode、postMessage 経由）も追加。
- SPA 同一オリジン PoC 向け。

判断材料:

- 方針 B は実装規模小さく、PoC ニーズと相性が良い。OSS 利用者の検証範囲を大きく広げる。
- 方針 C は SPA 連携の検証幅を広げるが、CSP / postMessage 周りの注意点が多い。後続で良い。

## 8. タスク案

- [ ] 方針 A / B / C のどれを採用するかを人間が判断
- [ ] 方針 B 採用時:
  - [ ] `AuthorizationRequestParams` に `response_mode?: string` を追加し、`form_post` / `query` のみ許容、それ以外は `unsupported_response_mode`
  - [ ] core ヘルパー `buildAuthorizationResponse(redirectUri, params, mode)` を追加（HTML 安全エスケープ、auto-submit）
  - [ ] sample / CLI テンプレの consent 完了経路を `form_post` に応じて切り替える
  - [ ] `response_modes_supported` 設定を `tasks/p2-discovery-response-modes-supported.md` と統合（広告値: `["query","form_post"]`）
  - [ ] テスト: form_post レスポンスの HTML 構造（`<form action=`、`<input>` 列挙、自動送信）、各認可パラメータの XSS エスケープ、エラー時の form_post 配送
  - [ ] CSP / inline script を使う際の注意（`<script>document.forms[0].submit()</script>`）を生成テンプレでコメント化、利用者が自分の CSP に合わせて調整できるよう案内
- [ ] 方針 A の場合: `unsupported_response_mode` エラーを返すテストを追加し、Discovery の `response_modes_supported` を `["query"]` のみで広告
