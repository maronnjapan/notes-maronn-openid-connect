# 拡張: OAuth 2.0 for Native Apps（RFC 8252）対応観点

## ステータス

🟡 Major（相互運用性 / セキュリティ）/ 未着手

## 1. このトピックで確認したいこと

RFC 8252 はネイティブアプリ（iOS / Android / Desktop）からの OAuth/OIDC フロー実装の Best Current Practice。本リポジトリは Web 中心の OP として設計されているが、**ネイティブアプリを RP として受け入れるための OP 側要件**を確認し、不足を整理する。

`study-material/oauth-browser-based-apps-bcp.md` は SPA（ブラウザ）が対象で、本ファイルとは別軸。

具体的に確認したいこと:

- `redirect_uri` のスキーム判定（カスタム URI スキーム / `https`+universal/app links / loopback IP）に OP がどう対応すべきか
- ネイティブアプリは Public Client が前提。PKCE 必須・client_secret 不可の整合性
- ループバックリダイレクト（`http://127.0.0.1:PORT/...`）における **ポート部分の動的扱い**

## 2. 関連する仕様・基準

### 2.1 RFC 8252 の主要要件（OP 視点）

- **§7 Initiating the Authorization Request from a Native App**: ネイティブアプリは外部システムブラウザ（ASWebAuthenticationSession / Chrome Custom Tabs 等）で認可リクエストを行う必要があり、埋め込み WebView は禁止。OP は埋め込み WebView を強制する設計をしてはならない（例: cookies に SameSite=Strict を必須化しすぎて埋め込み環境を疎外しない）。
- **§7.3 Loopback Interface Redirection**: `http://127.0.0.1:{port}/...` / `http://[::1]:{port}/...` を redirect_uri に許可。**ポート番号はリクエスト毎に異なる**ため、登録は「ホスト・パスのみ一致、ポートは任意」とする MUST。
- **§7.2 Claimed `https` Scheme URI Redirection（Universal Links / App Links）**: クライアントは AS に登録した `https` URI を使うのが推奨。OP は OAuth 2.1 と同じく完全一致で扱える。
- **§7.1 Private-Use URI Scheme Redirection**: `com.example.app:/callback` のようなカスタムスキーム。OP は **登録済みカスタムスキームを `https` と区別なく**完全一致で受け入れる必要がある。スキーム所有権の検証は OP の責務外（アプリストア検証）。
- **§6 PKCE 必須**: ネイティブアプリは全クライアントが PKCE（S256）必須。これは OAuth 2.1 と一致。
- **§8.6 Client Authentication**: ネイティブアプリは Confidential Client になれない（client_secret を保持できない）。Public Client として `none` 認証扱い。

### 2.2 OIDC との整合

- OIDC Core §3.1.2.1: `redirect_uri` は登録済み値と一致する必要があり、`https` / `http://localhost` / カスタムスキーム を区別していない。RFC 8252 はそこにネイティブ特有の判定（loopback のポート可変、カスタムスキームの容認）を追加する位置づけ。

## 3. 参照資料

- RFC 8252 — OAuth 2.0 for Native Apps: https://www.rfc-editor.org/rfc/rfc8252
  - §6 Use of PKCE / §7 Initiating Authorization / §7.1-7.3 Redirect URI 種別 / §8 Security Considerations
- OAuth 2.1 draft §4.1.3 / §10（PKCE / Public Client / Native Apps）
- 関連: `study-material/oauth-browser-based-apps-bcp.md`、`tasks/done/p0-redirect-uri-fragment-rejection.md`、`tasks/p1-public-client-token-endpoint.md`

## 4. 現在の実装確認

- `redirect_uri` の検証: `packages/core/src/authorization-request.ts:226-323` 周辺。`validateRegisteredRedirectUris` で「登録済み配列との完全一致」を行う。fragment 拒否は `done/p0-redirect-uri-fragment-rejection.md` で実装済み。
- **ループバック特例（ポート可変）が無い**: `http://127.0.0.1:PORT/callback` を登録すると、デバッグ用にポートが変わるとマッチしない。
- **カスタム URI スキーム**: 完全一致ロジックなので `com.example.app:/callback` のような値は登録すれば動くはずだが、URL parser（`new URL`）がカスタムスキームをどう扱うかの検証コードパスを確認していない。
- Public Client サポート: `tasks/p1-public-client-token-endpoint.md` で `token_endpoint_auth_method=none` の整備が課題化されている（未着手）。
- PKCE: `S256` 必須・`plain` 拒否を実装済み（`authorization-request.ts:387-427`、`token-request.ts:531-557`）。
- 認可エンドポイントの `prompt=login` / `max_age` / `id_token_hint`: 実装済み（done タスク群）。
- 埋め込み WebView 検出は OP の責務外（クライアント実装側責務）だが、OP が `User-Agent` を見て弾く実装にしていないことの確認は必要。

## 5. 現在の実装との差分

- **満たしていること**: PKCE S256 必須、redirect_uri 完全一致＋fragment 拒否、ID Token RS256、OIDC Core §3.1.2.1 の prompt/max_age。
- **不足している可能性があること**
  - ループバック redirect_uri における **ポート任意マッチ**ロジック。RFC 8252 §7.3 MUST。
  - Public Client（`token_endpoint_auth_method=none`）の Token Endpoint 取り扱い → 既存 `tasks/p1-public-client-token-endpoint.md` で追跡中。重複しない。
  - カスタムスキーム redirect_uri を URL parser が受け入れるかの動作確認テスト。
  - `redirect_uri` 完全一致比較ロジックを Loopback / カスタムスキーム / `https` の3カテゴリで分岐するヘルパー化（読みやすさと相互運用性のため）。
  - Discovery の `code_challenge_methods_supported: ["S256"]` 表現 → 既存 `study-material/discovery-code-challenge-methods-supported.md` で追跡。重複しない。
- **セキュリティ観点**
  - Loopback の **`http://` を許容する**点は OAuth 2.1 が再確認している。本実装の issuer 検証ロジック（discovery.ts）と混同しないこと（issuer は `https` 必須／redirect_uri 側は別）。
  - カスタムスキームの「スキーム所有権」は OP 検証不能。OS の URL handler 競合（複数アプリが同一スキームを宣言）はクライアント側の問題。ドキュメントで利用者に注意喚起すべき。

## 6. 改善・追加を検討する理由

- 「PoC 用ライブラリ」として、Web SPA / モバイルアプリの両ユースケースに対応できないと利用者が限定される。
- ループバックポート可変対応は **モバイル開発者には自明だが OP 実装者には盲点**になりやすい。本実装が「登録 URI と完全一致」を守りすぎて Loopback で動かないと、ネイティブ系 PoC が成立しない。
- Public Client Token Endpoint 対応（既存 P1 タスク）と合わせて RFC 8252 全体を Conformant にできれば、本ライブラリの応用範囲が大きく広がる。
- 実装しない場合の制約: モバイル / Desktop の AppAuth-iOS / AppAuth-Android / Electron 系 PoC で動作しない。

## 7. 実装方針の候補

### 方針A（推奨）: Loopback 特例 + 検証ヘルパー整理

- `validateRegisteredRedirectUris` のロジックを 3 種に分岐:
  1. `http://127.0.0.1:*/path` / `http://[::1]:*/path` → ホスト＋パス一致で MUST、ポートはリクエスト値を許容
  2. カスタムスキーム（`http`/`https` 以外） → 完全一致
  3. `https://...` → 完全一致
- 設定で「Loopback 特例を有効にするか」（既定 true、OAuth 2.1 既定に従う）をオプション化。
- `ClientInfo.redirectUris` の登録値で `http://127.0.0.1/callback`（ポート省略）を「ポート可変」と解釈するか、`http://127.0.0.1:0/callback` のような明示プレースホルダを使うかは要設計判断。RFC 8252 §7.3 の例は省略パスでマッチ判定を示している。
- ドキュメント: Loopback / カスタムスキーム / Universal Links の登録例を README に追記。

### 方針B（最小）: ドキュメント追記のみ

- 既存ロジックは変えず、「カスタムスキームを完全一致で登録する場合の注意」「ループバックは現状ポート完全一致なので開発時には任意ポートが使えない旨」をドキュメント化。
- Loopback 対応は将来課題。

### 方針C: 非対応の明文化

- Web 中心の OP として割り切り、ネイティブはサポート外とする。リリース戦略と合致するかは要判断。

## 8. タスク案

- [ ] 方針A/B/C を選択する（ユーザー判断）。`tasks/p1-public-client-token-endpoint.md`、`study-material/discovery-code-challenge-methods-supported.md` と組み合わせて RFC 8252 充足度をマイルストーンとして定義
- [ ] 方針A 採用時: Loopback redirect_uri マッチング仕様を設計（プレースホルダ書式、IPv4/IPv6 両対応）
- [ ] テスト先行: `http://127.0.0.1:54321/callback` が登録 `http://127.0.0.1/callback` にマッチすることを確認するテスト
- [ ] テスト先行: カスタムスキーム redirect_uri の `new URL` パース耐性（`com.example.app:/callback` / `com.example.app://callback` の差異）
- [ ] core: `validateRegisteredRedirectUris` 内部分岐実装
- [ ] ドキュメント: Loopback / Universal Links / カスタムスキーム登録ガイド
- [ ] 完了条件: core テストで 3 種類の redirect_uri パターンが期待どおりに分岐すること
