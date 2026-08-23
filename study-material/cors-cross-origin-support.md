# CORS（Cross-Origin Resource Sharing）対応

## 1. タイトル

ブラウザベースのクライアントから OIDC エンドポイントを呼び出す際に必要な CORS 対応の確認。本リポジトリには CORS ヘッダーの設定が存在せず、ブラウザ環境での動作が制限されている。

## 2. このトピックで確認したいこと

- どのエンドポイントがブラウザから直接アクセスされる可能性があり、CORS が必要か
- 仕様（OAuth 2.1 for Browser-Based Apps）が CORS についてどのような指針を示しているか
- 現在の実装の CORS 対応状況と、不足している箇所
- OIDC の Basic OP 認定テストが CORS を評価するか

## 3. 関連する仕様・基準

### 3.1 OAuth 2.0 for Browser-Based Apps

OAuth 2.1 for Browser-Based Apps（draft-ietf-oauth-browser-based-apps）は、SPA・ブラウザベースアプリがアクセストークンを取得・利用する際の実装ガイドラインを定める。

当該ドラフトでは、ブラウザから直接 Authorization Server のエンドポイントを呼び出す場合に、AS 側で適切な CORS レスポンスヘッダーを設定することを求める。

- **Token Endpoint**: PKCE + Authorization Code Flow では、SPA がトークンエンドポイントに直接 `POST` する。このとき CORS プリフライトが発生する（メソッドが POST・`Content-Type: application/x-www-form-urlencoded` は simple request に該当するが、`Authorization` ヘッダー使用時はプリフライトが必要）。
- **UserInfo Endpoint**: ブラウザの JS から直接 `fetch` する場合、`Authorization: Bearer` ヘッダーを含むため CORS プリフライトが必要。
- **JWKS Endpoint**: ブラウザ上のクライアントライブラリが ID Token を自己検証するために JWKS をフェッチする場合、CORS が必要。

### 3.2 CORS の基本動作（参考）

ブラウザは異なる Origin への HTTP リクエストを以下のルールで制御する:

- **Simple Request**: `GET`/`POST` + 安全なヘッダーのみ → CORS プリフライトなし、ただし `Access-Control-Allow-Origin` がなければレスポンスを JS から読めない。
- **Preflighted Request**: カスタムヘッダー（`Authorization` 等）を含む場合 → `OPTIONS` プリフライトが先に発生し、AS が `Access-Control-Allow-Origin`・`Access-Control-Allow-Headers` 等を返す必要がある。

### 3.3 CORS とセキュリティ

CORS ヘッダーを広く設定しすぎると、他サイトから AS エンドポイントへのクロスオリジンリクエストが許可されるリスクがある。

推奨される設定:
- `Access-Control-Allow-Origin`: 全ての Origin（`*`）は Token Endpoint に対して不可（`Authorization` ヘッダー付きリクエストに `*` は機能しない）。登録済みクライアントの Origin または設定値で制限する。
- `Access-Control-Allow-Credentials`: Bearer Token の場合は不要（Cookie 認証でなければ）。
- **JWKS Endpoint**: パブリックに公開される性質のため `*` を許容できる。
- **Discovery Endpoint**: 同様にパブリックのため `*` を許容できる。

### 3.4 Basic OP 認定テストとの関係

OIDF の Basic OP Conformance Suite はテスト実行を **サーバーサイドから** 行うため、CORS 自体の合否はテストされない（HTTP レベルの CORS ヘッダーは Suite に影響しない）。

しかし、本ライブラリの利用者がブラウザベース RP と組み合わせる場合、CORS が無効だとすべてのエンドポイントが機能しなくなる。「Fidelity（仕様準拠）」「Portability（どこでも動く）」を掲げる本プロジェクトでは、ブラウザ環境での動作保証が重要。

## 4. 参照資料

- OAuth 2.0 for Browser-Based Apps: https://datatracker.ietf.org/doc/draft-ietf-oauth-browser-based-apps/
  - Section 4（Token Endpoint の CORS ヘッダー要件）
  - Section 8（セキュリティ上の考慮事項）
- Fetch Standard（CORS）: https://fetch.spec.whatwg.org/#http-cors-protocol
- MDN CORS ガイド: https://developer.mozilla.org/en-US/docs/Web/HTTP/CORS
- Hono CORS Middleware: https://hono.dev/docs/middleware/builtin/cors
- OAuth 2.1 draft: https://datatracker.ietf.org/doc/draft-ietf-oauth-v2-1/ （§3.1 Authorization Endpoint, §3.2 Token Endpoint）

## 5. 現在の実装確認

### 5.1 sample ルートの CORS 状態

`packages/sample/src/oidc-provider/apply.ts`（または `index.ts`）を確認すると、Hono の CORS ミドルウェアは設定されていない。

各エンドポイント:

| エンドポイント | ファイル | CORS ヘッダー設定 |
|---|---|---|
| Authorization Endpoint | `routes/authorize.ts` | ❌ 未設定 |
| Token Endpoint | `routes/token.ts` | ❌ 未設定 |
| UserInfo Endpoint | `routes/userinfo.ts` | ❌ 未設定 |
| JWKS Endpoint | `routes/jwks.ts` | ❌ 未設定 |
| Discovery Endpoint | `routes/discovery.ts` | ❌ 未設定 |
| Revocation Endpoint | `routes/revocation.ts` | ❌ 未設定 |
| Introspection Endpoint | `routes/introspection.ts` | ❌ 未設定 |

### 5.2 sample クライアントの構成

`packages/sample/src/client/` が存在し、ブラウザベースのクライアント（`pkce.ts`）を含む。この実装が `fetch` でトークンエンドポイントを呼ぶ場合、両者が同一 Origin（例: `localhost:3000`）に同居しているため **現在は CORS エラーが表面化しない可能性がある**。

しかし:
- OP とクライアントが**異なるポート・ドメイン**に分離された場合は即座に失敗する
- 実際の利用シナリオ（別の Web アプリから本ライブラリの OP を使う）では CORS が必須

### 5.3 CLI 生成テンプレート

`packages/cli/src/frameworks/hono/templates.ts` が生成する Hono ルートにも CORS 設定は含まれていない。CLI ユーザーが生成コードをそのまま使うと CORS 問題に直面する。

## 6. 現在の実装との差分

| 観点 | 状態 |
|---|---|
| Token Endpoint への CORS | ❌ ブラウザ SPA からの直接フェッチ時に失敗 |
| UserInfo Endpoint への CORS | ❌ ブラウザからのアクセストークン検証時に失敗 |
| JWKS Endpoint への CORS | ❌ ブラウザ上クライアントライブラリの自己検証に失敗 |
| Discovery Endpoint への CORS | ❌ ブラウザからのメタデータ取得に失敗 |
| Revocation Endpoint への CORS | ❌ ブラウザからの直接失効呼び出し時に失敗 |
| Authorization Endpoint | 🟡 ブラウザはリダイレクト経由のため CORS 不要だが、POST 対応時はプリフライトが要る |

## 7. 改善・追加を検討する理由

- **Portability（どこでも動く）** が本リポジトリの差別化軸の一つ。ブラウザ環境での動作に CORS 設定が欠かせないため、現状はこの軸に反している。
- **サンプルアプリの即使用性**: sample の OP とクライアントが同一 Origin のため今は問題が潜在化しているが、利用者が OP を別サービスとして立てた瞬間に詰まる。
- **CLI 生成コードの品質**: CLI が生成したコードに CORS がなければ、PoC 体験が破綻する可能性が高い。利用者にとって「なぜ動かないか」の原因特定が難しいため、生成コードにデフォルト CORS 設定を含めることが UX 向上につながる。
- **実装コストが低い**: Hono は `cors()` ミドルウェアを内蔵しており、3〜5 行の追加で全エンドポイントに CORS を適用できる。

## 8. 実装方針の候補

### 方針A（ワイルドカード CORS + 制限）

- Discovery / JWKS: `Access-Control-Allow-Origin: *`（パブリック情報のため任意の Origin から読み取り可）
- Token / UserInfo / Revocation: `Access-Control-Allow-Origin: <設定可能なリスト>`（デフォルトはすべての Origin を許可。本番では許可リストで制限する運用に移行）

```typescript
// apply.ts への追加例（Hono CORS ミドルウェア使用）
import { cors } from 'hono/cors';

app.use('/jwks', cors({ origin: '*' }));
app.use('/discovery', cors({ origin: '*' }));
app.use('/token', cors({
  origin: config.allowedOrigins ?? '*',
  allowHeaders: ['Content-Type', 'Authorization'],
  allowMethods: ['POST', 'OPTIONS'],
}));
app.use('/userinfo', cors({
  origin: config.allowedOrigins ?? '*',
  allowHeaders: ['Authorization', 'Content-Type'],
  allowMethods: ['GET', 'POST', 'OPTIONS'],
}));
```

### 方針B（設定注入型）

`ProviderConfig` に `corsOrigins: string | string[]` を追加し、CLI 生成テンプレートで環境変数からデフォルト設定を行う。`'*'` を PoC 向けデフォルトとし、本番は環境変数で上書く。

### 方針C（ドキュメントのみ）

実装は変更せず、README / CLI 生成テンプレートのコメントに「本番利用時は CORS を設定すること」と注意書きを追加する。PoC 同一 Origin 前提であればブロッカーにならないが、利用者体験の改善にはならない。

## 9. タスク案

- [ ] `packages/cli/src/frameworks/hono/templates.ts` の CLI 生成テンプレートに Hono `cors()` ミドルウェアのデフォルト設定を追加する（方針A/B）
- [ ] `packages/sample/src/oidc-provider/apply.ts` にサンプル用の CORS 設定を追加し、別 Origin のクライアントからもエンドポイントにアクセスできるよう整備する
- [ ] `ProviderConfig` に `allowedOrigins` を追加するか判断する（方針B）
- [ ] Discovery / JWKS は `*`、Token / UserInfo は設定値ベースという区別を CORS 設定ガイドとして文書化する
- [ ] ブラウザから各エンドポイントを呼び出すインテグレーションテストを追加する（CORS プリフライトの確認含む）
