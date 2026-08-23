# JWT Profile for OAuth 2.0 Access Tokens（RFC 9068）包括的レビュー

## 1. タイトル

RFC 9068（JWT Profile for OAuth 2.0 Access Tokens）への準拠状況と、個別タスクで追跡されている差分の全体像整理。

## 2. このトピックで確認したいこと

本リポジトリは JWT 形式のアクセストークンを `typ: at+jwt` で発行しており、RFC 9068 に沿った設計意図がある。しかし個別の改善点（`jti`, `nbf`, `aud` のデフォルト等）が複数のタスクに分散しており、全体として RFC 9068 のどこが満たされてどこが不足しているかを俯瞰できる文書がない。

このファイルは **RFC 9068 への準拠マップ**として機能する。個別の実装変更は既存タスクを参照し、本ファイルでは繰り返さない。

## 3. 関連する仕様・基準

### 3.1 RFC 9068 の位置づけ

RFC 9068（JWT Profile for OAuth 2.0 Access Tokens）は、リソースサーバが JWT アクセストークンを自己完結で検証できるよう、JWT の構造・必須クレーム・`typ` ヘッダーを規格化する。

OIDC Core は ID Token の JWT 形式を規定するが、アクセストークンの JWT 形式は規定しない。RFC 9068 はその隙間を埋める仕様として OAuth 2.1 でも参照される。

### 3.2 RFC 9068 Section 2.2 の REQUIRED クレーム

| クレーム | REQUIRED | 説明 |
|---|---|---|
| `iss` | REQUIRED | トークン発行者の識別子。OIDC Core の `iss` 検証要件と一致 |
| `exp` | REQUIRED | 有効期限（NumericDate） |
| `aud` | REQUIRED | 対象リソースサーバ。空配列・省略不可 |
| `sub` | REQUIRED | End-User またはサービスアカウントの Subject |
| `client_id` | REQUIRED | トークンを要求したクライアント識別子 |
| `iat` | REQUIRED | 発行時刻（NumericDate） |
| `jti` | REQUIRED | JWT の一意識別子（リプレイ防止） |

### 3.3 RFC 9068 Section 2.1 の JOSE Header

- `typ` ヘッダーを `at+jwt`（大文字小文字非感度）に**MUST**設定する。これによりリソースサーバが ID Token（`typ: JWT`）との混同を防げる。
- `alg` は `none` を使用してはならない。
- `kid` は推奨（JWKS からの鍵選択に使う）。

### 3.4 RFC 9068 Section 2.2 の OPTIONAL クレーム

| クレーム | OPTIONAL | 説明 |
|---|---|---|
| `nbf` | OPTIONAL | Not Before（この時刻以前は無効） |
| `scope` | 実質 REQUIRED | 付与されたスコープ（スペース区切り文字列） |
| `auth_time` | OPTIONAL | 認証時刻 |
| `acr` | OPTIONAL | Authentication Context Class Reference |
| `amr` | OPTIONAL | Authentication Methods References |
| `cnf` | OPTIONAL | Confirmation Claim（DPoP / mTLS バウンドトークン） |

> `scope` は OAuth 2.1 §3.2.3 および RFC 9068 Section 2.2 の両方で "SHOULD" または事実上必須として扱われる。本リポジトリは実装済み。

### 3.5 `aud` クレームの語義

RFC 9068 Section 2.2 は `aud` を「当該トークンで保護されるリソースサーバの識別子」と定義する。OAuth 2.1 の Resource Indicators（RFC 8707）を使う場合、`aud` にはリソース URI が入る。Resource Indicators を使わない場合の `aud` の値は実装定義だが、空配列や `client_id` のみを入れることは推奨されない（`client_id` は `client_id` クレームが担う）。

> 本リポジトリの現状: 認可リクエストの `audience` パラメータ（非標準拡張として実装）から `aud` を組み立てている。`audience` 未指定時のデフォルト挙動については 📌 `tasks/p1-jwt-access-token-aud-default.md` を参照。

## 4. 参照資料

- RFC 9068 — JWT Profile for OAuth 2.0 Access Tokens: https://www.rfc-editor.org/rfc/rfc9068
  - Section 2.1: Header Parameters（`typ: at+jwt` の MUST）
  - Section 2.2: Claims（必須・任意クレーム一覧）
  - Section 4: Security Considerations（`jti` によるリプレイ防止要件）
- OAuth 2.1 draft §3.2: https://datatracker.ietf.org/doc/draft-ietf-oauth-v2-1/
- RFC 7519（JWT）: https://www.rfc-editor.org/rfc/rfc7519 （基本 JWT クレームの定義）
- RFC 8707（Resource Indicators）: https://www.rfc-editor.org/rfc/rfc8707 （`aud` と `resource` パラメータの関係）

関連する既存タスク（本ファイルでは詳細を繰り返さない）:
- 📌 `tasks/p1-jwt-access-token-aud-default.md` — `aud` デフォルト値
- 📌 `tasks/p2-jwt-access-token-jti.md` — `jti` クレームの付与
- 📌 `tasks/p3-jwt-access-token-nbf.md` — `nbf` クレームの付与
- 📌 `tasks/T-019-dpop.md` — DPoP 対応（`cnf` クレームに関係）

## 5. 現在の実装確認

### 5.1 コアロジック（`packages/core/src/access-token.ts`）

```
AccessTokenPayload {
  iss: string          // REQUIRED ✅
  sub: string          // REQUIRED ✅
  aud: string[]        // REQUIRED ✅（空配列を拒否する検証あり）
  exp: number          // REQUIRED ✅
  iat: number          // REQUIRED ✅
  scope?: string       // 実質 REQUIRED ✅（token-response.ts で付与）
  client_id?: string   // REQUIRED ❌ optional 扱い（必須指定なし）
  [key: string]: unknown  // 拡張クレーム用
}
```

- JOSE Header: `typ: 'at+jwt'` ✅（`generateAccessToken` で明示設定）
- `alg`: CryptoKey から自動導出 ✅
- `kid`: optional ✅

`jti` は `AccessTokenPayload` に型定義がなく、token-response.ts でも付与されていない。

`nbf` も型定義・付与なし。

### 5.2 トークン発行（`packages/core/src/token-response.ts`）

`generateTokenResponse` が `generateAccessToken` を呼ぶ際のペイロード構築:

```typescript
// token-response.ts 内（概略）
const accessTokenPayload: AccessTokenPayload = {
  iss: options.issuer,
  sub: options.subject,
  aud: options.audience ?? [],  // ← aud 空配列問題（p1タスク）
  exp: now + options.accessTokenExpiresIn,
  iat: now,
  scope: options.scope.join(' '),
  client_id: options.clientId,
  // jti なし ← p2タスク
  // nbf なし ← p3タスク
};
```

`client_id` は `token-response.ts` で付与されており、`AccessTokenPayload` の型が optional でも実際には必ず設定される。

### 5.3 Opaque トークン（`packages/core/src/access-token-issuer.ts`）

`createOpaqueAccessTokenIssuer` を使う場合、`generateAccessToken` は呼ばれず JWT 構造を持たない。RFC 9068 は JWT AT の仕様であり Opaque AT には適用されない。

## 6. 現在の実装との差分

### 6.1 RFC 9068 必須事項との差分

| RFC 9068 要件 | 状態 | タスク |
|---|---|---|
| `typ: at+jwt` ヘッダー | ✅ 実装済み | — |
| `iss` クレーム | ✅ 実装済み | — |
| `exp` クレーム | ✅ 実装済み | — |
| `aud` クレーム（非空配列） | 🟡 `audience` 未指定時に空配列 | 📌 p1-jwt-access-token-aud-default |
| `sub` クレーム | ✅ 実装済み | — |
| `client_id` クレーム | 🟡 型は optional だが実際には付与 | — |
| `iat` クレーム | ✅ 実装済み | — |
| `jti` クレーム | ❌ 未実装 | 📌 p2-jwt-access-token-jti |

### 6.2 セキュリティ上の確認事項

- **`jti` によるリプレイ防止**: RFC 9068 Section 4 は `jti` を用いたリプレイ攻撃対策を推奨する。`jti` が無いとリソースサーバがトークン再利用を検知できない。
- **`aud` の空配列**: リソースサーバが `aud` 検証する際、空配列は全 RS が対象と同義になるリスク。`audience` 未指定時のデフォルト値ポリシーが要確認。
- **Opaque AT との混在**: JWT AT と Opaque AT が同一アプリで共存する場合、リソースサーバ側の検証フローが複雑化する。Discovery の `access_token_types_supported` 等での広告は RFC 9068 の必須要件ではないが相互運用性に影響する。

### 6.3 相互運用性の観点

- リソースサーバが RFC 9068 準拠検証を行う場合、`jti` なし・`aud` 空の AT は検証を通過しないことがある。
- `nbf` が無いと発行直後から有効（問題なし）だが、クロックスキュー対策として `nbf = iat - skew` の設定が推奨される実装もある。

## 7. 改善・追加を検討する理由

- **相互運用性**: RFC 9068 準拠の AT は「標準的なリソースサーバが署名・クレームを自己検証できる」ことを保証する。`jti` や `aud` の不備は、本ライブラリを使った PoC で外部リソースサーバと接続した際に即座に問題になる。
- **Basic OP 認定**: Basic OP の認定テストはアクセストークンの内部形式を直接検査しないが、`at_hash`（アクセストークンのハッシュ）が ID Token に含まれる。この計算は現実のアクセストークン文字列を使うため、Opaque AT と JWT AT の両方で一貫した実装が必要。現在は実装済み。
- **DPoP 対応（T-019）との接続**: DPoP バウンドトークンは `cnf.jkt` クレームを AT に含める。`jti` も DPoP の `jti` チェックに関係するため、T-019 実装前に `jti` を付与しておく方が自然。

## 8. 実装方針の候補

個別の方針候補は各既存タスクを参照。本ファイルの役割は**全体整合の確認**であり、実装判断は各タスクファイルに委譲する。

全体方針候補:

- **方針A（個別タスク順次消化）**: p1 → p2 → p3 の順で既存タスクを独立して実装する。整合確認は各タスク完了後に本ファイルを更新して追う。
- **方針B（一括 RFC 9068 対応 PR）**: `jti`・`nbf`・`aud` デフォルトを 1 つの PR にまとめる。テスト修正コストは高いが、RFC 9068 の「完全準拠」を一度のコミットで達成できる。

## 9. タスク案

- [ ] 本マップの状態列を各タスク完了後に更新する運用を確立する
- [ ] Opaque AT と JWT AT の混在時に Discovery や resource server ガイドが整合するか確認する（Discovery に `access_token_types_supported` を追加するかは T-021 で扱う）
- [x] `client_id` を `AccessTokenPayload` の必須型フィールドに昇格させる（実態と型の不整合解消。Breaking change ではなく型の厳格化のみ）
      → 📌 タスク化済み: `tasks/p3-jwt-access-token-required-claims-validation.md`
      （`client_id` に加え、同じく RFC 9068 §2.2 で REQUIRED でありながら optional のままである `jti` も
      発行時検証の対象に含める。本ファイルは他の項目が残るため `study-material/` に留める）
- [ ] T-019（DPoP）実装開始前に p2（`jti`）を完了させる依存関係を確認・記録する
- [ ] Opaque AT 使用時の `at_hash` 計算が正しく機能しているかテストで確認する
