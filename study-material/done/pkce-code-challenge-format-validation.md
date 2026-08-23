# PKCE `code_challenge` 値そのものの形式・長さ検証（Authorization Endpoint）

## ステータス

🟡 Major / 未着手

## 1. このトピックで確認したいこと

OAuth 2.1 / RFC 7636 では PKCE の `code_challenge` 値は **`code_challenge_method` に応じた厳密な形式**を取る必要がある。`S256` の場合、`code_challenge` は `BASE64URL-ENCODE(SHA256(ASCII(code_verifier)))` の結果であり、

- 文字種は base64url unreserved（`[A-Za-z0-9\-._~]`）
- 長さは **43 文字固定**（SHA-256 出力 32 バイトの base64url 表現）

である。

現在の本リポジトリの実装は、**`code_challenge_method` の値検証と `code_challenge` の存在チェックは行うが、`code_challenge` 値の長さ・文字種を Authorization Endpoint では検証していない**。問題は Token Endpoint の比較段階で初めて顕在化する。これは:

- 利用者へのエラーフィードバックが遅延する（同意画面到達後に Token Endpoint で `invalid_grant`）
- 攻撃者・誤実装クライアントが任意文字列を `code_challenge` として登録できる
- Conformance テストや厳格な実装との相互運用で挙動差が出る可能性

本トピックでは、Authorization Endpoint で `code_challenge` の形式・長さを早期検証することの可否と方針を確認する。

なお Token Endpoint 側では `code_verifier` の長さ（43-128）と文字種を検証済み（`token-request.ts:531-557`）。本トピックは「`code_challenge` 側」の同等検証を扱うため重複しない。

## 2. 関連する仕様・基準

共通の PKCE 仕様説明は `study-material/basic-op-requirement-traceability.md` の §3.3（PKCE: RFC 7636 / OAuth 2.1 §4.1.1, §7.5）および `study-material/discovery-code-challenge-methods-supported.md` を参照。本トピック固有のポイントは以下:

### 2.1 RFC 7636 §4.2: Client Creates the Code Challenge

> code_challenge = BASE64URL-ENCODE(SHA256(ASCII(code_verifier)))

`code_verifier` の文字種制約（§4.1）:

> code_verifier = high-entropy cryptographic random STRING
> using the unreserved characters [A-Z] / [a-z] / [0-9] /
> "-" / "." / "_" / "~" from Section 2.3 of RFC 3986,
> with a minimum length of 43 characters and a maximum length of 128 characters.

S256 の `code_challenge` は SHA-256 出力（32 バイト）の base64url-no-padding 表現であり、必ず 43 文字の `[A-Za-z0-9\-._~]` 部分集合（実際は `[A-Za-z0-9\-_]`）になる。

### 2.2 RFC 7636 §4.3: Client Sends the Code Challenge with the Authorization Request

> The client sends the code challenge as part of the OAuth 2.0
> Authorization Request (Section 4.1.1 of [RFC6749]) using the following
> additional parameters:
>
> code_challenge
>    REQUIRED.  Code challenge.
> code_challenge_method
>    OPTIONAL, defaults to "plain" if not present in the request.
>    ...

仕様自体は Authorization Endpoint での厳密検証を明文で MUST 化していない。ただし RFC 7636 §4.4.1 で AS は「Authorization Endpoint が `code_challenge_method` をサポートしない場合、`error=invalid_request` を返す」と規定する。形式不正そのものは明示的に扱われていないが、不正値での認可フロー成立は Token Endpoint で結局 `invalid_grant` になるため、早期拒否が望ましい。

### 2.3 OAuth 2.1 §4.1.1 / §7.5

OAuth 2.1 は PKCE を必須化（plain は禁止 / S256 のみ）。本リポジトリはこれに準拠済み（`VALID_CODE_CHALLENGE_METHODS = ['S256']`）。OAuth 2.1 自体は `code_challenge` 値の形式を AS 側でどこまで検証するかは細かく規定していないが、Security Considerations の文脈で早期不正検出は推奨される。

### 2.4 OAuth 2.0 Security Best Current Practice（RFC 9700 §2.1.1 / §4.8）

PKCE のメリットを最大化するには「実態として高エントロピーな challenge であること」を保証することが望ましい。形式逸脱した `code_challenge` は事実上 PKCE の保護を弱める。

## 3. 参照資料

- RFC 7636 Proof Key for Code Exchange by OAuth Public Clients — https://www.rfc-editor.org/rfc/rfc7636
  - §4.1（`code_verifier` の文字種・長さ）
  - §4.2（S256 における `code_challenge` の導出）
  - §4.3（`code_challenge` パラメータ）
  - §4.4.1（method 未サポート時のエラー）
- OAuth 2.1 draft — https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1
  - §4.1.1（PKCE 必須化）
  - §7.5（PKCE Security Considerations）

## 4. 現在の実装確認

- `packages/core/src/authorization-request.ts:384-427` `validateCodeChallenge`:
  - `code_challenge` 存在チェック（無ければ `invalid_request`）
  - `code_challenge_method` 存在チェック
  - `code_challenge_method` が `['S256']` に含まれるかチェック
  - **`code_challenge` 自体の長さ・文字種は未検証**
- `packages/core/src/token-request.ts:521-558` PKCE 検証:
  - Token Endpoint で `code_verifier` の長さ（43-128）と文字種（`[A-Za-z0-9\-._~]`）を検証
  - 不正なら `invalid_grant`
- 関連テスト: `packages/core/src/authorization-request.test.ts` で `code_challenge` の長さ・文字種を網羅するケースは未確認（要再確認だが grep 上は不存在）

## 5. 現在の実装との差分

満たしていること:

- `code_challenge_method` が S256 限定であること（plain 拒否）。OAuth 2.1 準拠。
- Token Endpoint で `code_verifier` 形式を検証している。
- PKCE の比較ロジック自体は正しい（`verifyCodeChallenge` で SHA-256 → base64url を計算し一致判定）。

不足／改善余地:

- 🟡 **`code_challenge` 値の早期検証が無い**: Authorization Endpoint で任意文字列を受け取り、Token Endpoint で初めて不一致として返す。攻撃を許容するわけではないが、利用者へのエラーフィードバックが遅延し、Conformance 観点でも形式違反を早期に弾くほうがクリーン。
- 🟡 **`code_challenge` の 43 文字制約と文字種制約はクライアント側責務だが、AS 側で確認すれば誤実装クライアントを即座に検知できる**: 利用者（PoC 開発者）が自前クライアントを書く際の「ハマりどころ」を一つ減らせる。
- 🟡 **`code_challenge_method` 既定値の扱い**: RFC 7636 では `code_challenge_method` を省略すると `plain`。本実装は省略を `invalid_request` として拒否しており、これは OAuth 2.1 準拠（plain 禁止）として意図的だが、エラーメッセージで「OAuth 2.1 では `S256` が必須」と明示するとさらに親切。

セキュリティ観点:

- 早期検証は「攻撃の検知」ではなく「誤実装の早期発見」目的。攻撃シナリオ自体は Token Endpoint 比較で阻止できているため、現状でセキュリティ侵害には繋がらない。
- 形式違反を許容しても、別の `code_verifier` で偽造される攻撃は SHA-256 衝突困難性で阻止される。早期検証は **DoS 耐性（不正リクエストを Authorize 前段で弾く）** と **相互運用性** の論点。

## 6. 改善・追加を検討する理由

- 利用者（PoC 開発者）にとって、形式違反の `code_challenge` が Token Endpoint で初めて見えると「PKCE のどこで失敗したか」が分かりにくい。Authorization Endpoint で明示的に `invalid_request` を返すと、`code_verifier` 生成側の問題か `code_challenge` 計算側の問題か切り分けやすい。
- 本リポジトリの差別化軸「Fidelity（仕様準拠）」観点で、`code_challenge` 形式違反を黙って受理する挙動は Conformance Suite の厳格テストで指摘される可能性がある。
- 実装コストが小さい: `validateCodeChallenge` 内に 5 行程度のチェックを追加するだけ。
- 既存実装の責務分離（authz は形式検証 / token は意味検証）と整合する。
- 実装しないリスク: 利用者が PKCE 計算ミスを Token Endpoint まで気付けず、サポート問い合わせ的なノイズが増える。

## 7. 実装方針の候補

### 方針A（推奨度: 高）: S256 厳格検証

- `validateCodeChallenge` で `code_challenge_method === 'S256'` の場合、以下を検証:
  - 長さが 43 文字であること
  - 文字種が `[A-Za-z0-9\-_]`（base64url-no-padding）であること
- 違反時は `invalid_request` を返す（redirect 可能なエラー、`error_description` に「`code_challenge` must be a 43-character base64url-encoded SHA-256 hash」など明示）。

### 方針B（推奨度: 中）: 文字種のみ検証、長さは緩い範囲

- 文字種だけ `[A-Za-z0-9\-._~]`（RFC 7636 §4.1 の unreserved 全集合）に絞り、長さは「43 以上」程度の下限のみ。
- S256 では実際は 43 文字固定だが、将来 method が拡張された場合の柔軟性を残す。本リポジトリは現状 S256 のみなので方針 A で十分。

### 方針C（現状維持）

- Authorization Endpoint では検証しない。Token Endpoint の比較で十分とみなす。
- Conformance テストで指摘されたら対応するスタンスにする。

### 方針D（resolver / 設定で切替）

- 厳格検証をオプション化（既定オフ）。PoC 用途で多少緩めたい利用者を想定。本リポジトリの差別化軸（Fidelity）に反するため非推奨。

## 8. タスク案

- [ ] 方針 A / B / C / D の選択（人間が判断）
- [ ] （方針 A 採用時）TDD でテストを先に追加:
  - `code_challenge` 長さ違反（< 43 / > 43）→ `invalid_request`
  - `code_challenge` 文字種違反（記号・スペース等）→ `invalid_request`
  - 正常な 43 文字 base64url-no-padding 値 → 通過
- [ ] `validateCodeChallenge` 内に長さ・文字種チェックを追加
- [ ] `error_description` を「`code_challenge` must be a base64url-encoded SHA-256 hash (43 characters)」相当に
- [ ] `tasks/basic-op-requirement-traceability.md` の PKCE 行にメモ追記（早期検証有り / 無し）
- [ ] CLI / sample テンプレートは core で完結するため変更不要だが、テスト追加で生成コードの挙動回帰を確認
