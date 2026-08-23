# OAuth 2.0 for Native Apps（RFC 8252）— カスタム URI スキーム / Claimed HTTPS の扱い

## ステータス

🟡 Minor / 未着手

## 1. このトピックで確認したいこと

OAuth 2.0 for Native Apps（RFC 8252, BCP 212）は、モバイル・デスクトップネイティブアプリの redirect_uri 設計と、それを受け入れる AS 側の責務を規定する BCP。

OAuth 2.1 が一部を取り込み、本リポジトリも以下は既に対応済み:

- **PKCE 必須**（RFC 8252 §8.1, OAuth 2.1）→ 実装済（PKCE S256 必須化）
- **ループバックアドレスのポート差異許容**（RFC 8252 §7.3, OAuth 2.1 §10.3.3）→ 実装済（T-013 done, `clientType: 'public'` 限定）

しかし、RFC 8252 が扱う「ネイティブアプリ redirect_uri の他のパターン」、つまり

- **プライベート使用 URI スキーム**（`com.example.app:/oauth2redirect`）
- **Claimed "https" Scheme URI**（App Links / Universal Links）

について、本リポジトリは以下が未整理:

- 受け入れるか / 拒否するか
- 受け入れる場合の検証（スキーム形式・スキーム所有権の確認をしないことの明文化）
- ドキュメントによる利用者ガイド（PoC でネイティブアプリ検証する利用者は典型ターゲット）

本トピックでは、RFC 8252 のループバック以外のパターンに対する本リポジトリの方針を整理する。

## 2. 関連する仕様・基準

共通の redirect_uri 仕様説明は重複させない。既存ファイルを参照のこと:

- redirect_uri 完全一致・fragment 拒否: `tasks/done/p0-redirect-uri-fragment-rejection.md`
- ループバック handling と `clientType: 'public'` 限定: `tasks/done/oidc-improvements-2026-05.md` T-013
- PKCE 必須: `study-material/basic-op-requirement-traceability.md`

本トピック固有のポイント:

### 2.1 RFC 8252 §7 — Native App Redirect URI

RFC 8252 が推奨するネイティブアプリの redirect URI 設計（優先順）:

1. **§7.2 Claimed "https" Scheme URI Redirection（推奨）**: アプリが App Links（Android）/ Universal Links（iOS）で OS と URL の所有権を関連付ける。サーバ側からは普通の HTTPS URL に見える
2. **§7.3 Loopback Interface Redirection**: `http://127.0.0.1:{port}` / `http://[::1]:{port}` / `http://localhost:{port}`。ポート差異を許容（本リポジトリ実装済み）
3. **§7.1 Private-Use URI Scheme Redirection**: `com.example.app:/oauth2redirect` のような逆 DNS スキーム。OS がスキーム → アプリを解決

### 2.2 §8.4 AS の責務

> Authorization servers MUST require clients to register their complete
> redirect URI (including the path component) and reject authorization
> requests that specify a redirect URI that doesn't exactly match the
> one that was registered

完全一致が原則。例外はループバック（§7.3）のポート差異のみ。プライベート URI スキームは「完全一致」の対象であり、形式は AS が自由に決められる（reverse-DNS が推奨）。

### 2.3 §8.5 セキュリティ考慮

- プライベート URI スキームは複数アプリが同じスキームを登録するとハイジャック可能。AS は「reverse-DNS 形式（`com.example.app` のような）」を推奨することが BCP
- Claimed HTTPS は OS が所有権検証するためハイジャック耐性が高いが、AS はその検証に関与しない（クライアント側責務）
- スキーム検証で `javascript:` / `data:` / `file:` などを許容してはならない（XSS / RCE リスク）

### 2.4 OAuth 2.1 との関係

- OAuth 2.1 §10.3 / §10.4 は RFC 8252 を参照しつつ、loopback ポート許容を明示
- カスタムスキームについて OAuth 2.1 は禁止していない（受理可能）
- OAuth 2.0 for Browser-Based Apps（既存ファイル `study-material/oauth-browser-based-apps-bcp.md`）と対象が異なる：本ファイルはネイティブアプリ専用

## 3. 参照資料

- RFC 8252 OAuth 2.0 for Native Apps — https://www.rfc-editor.org/rfc/rfc8252
  - §7（Initiating the Authorization Request from a Native App）
  - §8.4（Registration of Native App Clients）
  - §8.5（Endpoint Authentication）
- OAuth 2.1 §10.3 / §10.4 — https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1
- Android App Links — https://developer.android.com/training/app-links
- iOS Universal Links — https://developer.apple.com/ios/universal-links/

## 4. 現在の実装確認

- `packages/core/src/authorization-request.ts` `matchRedirectUri`:
  - 完全一致（`registeredUris.includes(requestUri)`）が第一
  - ループバックホスト（`localhost` / `127.0.0.1` / `[::1]`）の場合のみポート差異許容（`clientType === 'public'` 限定）
  - **カスタムスキームの特別扱いは無し**: `URL` パースが通れば完全一致比較のみで判定（つまり `com.example.app:/oauth2redirect` を登録時に書いておけば一致する）
  - **危険スキーム（`javascript:` 等）の明示拒否は無し**: 登録済みであれば技術的に通る
- `packages/core/src/authorization-request.ts` `validateRegisteredRedirectUris`:
  - fragment（`#`）を拒否するのみ
  - スキーム種別の検証無し
- `packages/sample/src/oidc-provider/config.ts`: `clientType: 'confidential' | 'public'`、`redirectUris` は文字列配列
- ドキュメント: ネイティブアプリ redirect_uri の推奨形式について README / CLAUDE.md に記載無し

## 5. 現在の実装との差分

満たしていること:

- 完全一致 + ループバックポート許容 + fragment 拒否（RFC 8252 が要求する中核セキュリティ）
- カスタムスキーム自体は受理可能（登録時に文字列として書けば動く）
- PKCE 必須でネイティブアプリ用攻撃面が縮小されている

不足／改善余地:

- 🟡 **危険スキームの明示拒否が無い**: 登録時 / 認可リクエスト時に `javascript:` / `data:` / `file:` / `vbscript:` 等を明示拒否したい。設定ミスや内部攻撃で危険スキームが登録される事故を防げる。
- 🟡 **`clientType: 'public'` のカスタムスキーム明示**: ネイティブアプリは `clientType: 'public'` で登録するのが BCP。CLI / sample のドキュメントで明示するとハマりが減る。
- 🟢 **reverse-DNS 形式の推奨ガイド**: RFC 8252 §7.1 が推奨する `com.example.app` 形式を README で案内するとよい。検証は AS では実施不要だが、利用者の知識として提供する価値はある。
- 🟢 **Claimed HTTPS の挙動**: AS 側は普通の HTTPS URL として扱えばよく、本リポジトリは既に対応済み。ドキュメントで「ネイティブアプリでも Claimed HTTPS を推奨」と書くとガイド性が上がる。
- 🟡 **`http://` redirect_uri（loopback 以外）の扱い**: OIDC Core §3.1.2.1 と RFC 8252 §8.4 によりプロダクションでは禁止。ループバック以外の `http://` URL は明示的に拒否すべきだが、現状の実装は完全一致だけで判断するため「登録時に通せば動く」状態。

セキュリティ観点:

- 危険スキームの登録は AS 設定者の責任だが、AS 側でガードレールを入れたほうが安全。
- 設定経路（手動登録）が DCR（`study-material/ext-dynamic-client-registration.md`）に拡張された場合、untrusted な登録元から危険スキームが混入する経路が増える。DCR 実装時に必須化したい。

## 6. 改善・追加を検討する理由

価値:

- ネイティブアプリ PoC はターゲットユーザーの主要シナリオ。Android / iOS から本ライブラリで OIDC 検証するケースは想定される。
- 危険スキームの明示拒否はセキュリティ層の防御線（防御の深さ）。AS 設定者のミスを救う。
- 「Fidelity（仕様準拠）」シグナル: RFC 8252 を実装ガイドにフォローしている OSS は信頼性が高い。

導入難易度:

- 🟢 **低**: `validateRegisteredRedirectUris` に「危険スキーム拒否」「`http://` の loopback 以外拒否」を追加するだけ。
- ドキュメント整備のコストは小さい。

実装しない場合のリスク:

- 利用者が誤って `javascript:` を登録して、OIDC 経由で XSS が起こる経路を作る（極端例だが防御線が薄い）。
- ネイティブアプリ PoC で「どう redirect_uri を設定すればよいか」のガイドが無いと利用者が手探りになる。

## 7. 実装方針の候補

### 方針A（最小強化 / 推奨）

- `validateRegisteredRedirectUris` に以下を追加:
  - 危険スキーム拒否（`javascript:` / `data:` / `file:` / `vbscript:` / `blob:`）
  - `http://` で `localhost` / `127.0.0.1` / `[::1]` 以外を拒否
- ドキュメント追加:
  - README に「ネイティブアプリ向け redirect_uri のベストプラクティス」セクション
  - reverse-DNS 形式 / Claimed HTTPS / loopback を推奨する文言
- `RegisteredClient` 型のコメントで `clientType: 'public'` の使い方を明示

### 方針B（A + Claimed HTTPS 検証）

- 方針 A に加えて、`https://` 形式の redirect_uri に対して「`.well-known/assetlinks.json` 確認」のヘルパーを提供
- 実用性は限定的（OP が外部 HTTP 取得する責務を負うため）
- 非推奨

### 方針C（A + DCR 想定の強化）

- 方針 A に加えて、DCR 経由の登録時にスキーム検証を必須化
- DCR 未実装の現状は将来タスク

### 方針D（現状維持 / ドキュメントのみ）

- コード変更なし
- README にネイティブアプリ向けガイドのみ追加
- 利用者責務として明文化

判断材料:

- 危険スキーム拒否は実装コスト・テストコストともに小さく、デメリットが見当たらない（方針 A）
- Claimed HTTPS の OP 側検証は責務外（クライアント / OS 責務）。方針 B は不要
- DCR は別タスクで扱うため、方針 A で十分

## 8. タスク案

- [ ] 方針 A / B / C / D を選択（人間が判断）
- [ ] （方針 A 採用時）TDD で `authorization-request.test.ts` にケースを追加:
  - `javascript:alert(1)` を登録 → エラー
  - `data:text/html,...` を登録 → エラー
  - `file:///path` を登録 → エラー
  - `http://example.com/cb` を登録 → エラー（loopback 以外）
  - `http://localhost:3000/cb` を登録 → OK
  - `com.example.app:/oauth2redirect` を登録 → OK
- [ ] `validateRegisteredRedirectUris` に危険スキーム / non-loopback http 拒否を追加
- [ ] README にネイティブアプリ redirect_uri のベストプラクティスを追加
- [ ] `packages/cli/src/frameworks/hono/templates.ts` の Client 設定例コメントを更新
- [ ] `study-material/basic-op-requirement-traceability.md` の Redirect URI 行に注記
