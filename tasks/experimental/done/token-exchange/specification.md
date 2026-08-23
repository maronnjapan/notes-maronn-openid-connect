# Experimental機能仕様書: OAuth 2.0 Token Exchange

- **機能名**: OAuth 2.0 Token Exchange
- **feature-id**: `token-exchange`
- **準拠仕様**: RFC 8693 - OAuth 2.0 Token Exchange
- **作成日**: 2026-07-30
- **ステータス**: `state.yaml` を参照

## 概要

トークンエンドポイントに新しい grant type `urn:ietf:params:oauth:grant-type:token-exchange` を追加し、クライアントが手元のアクセストークン（`subject_token`）を提示して、別の対象（audience / resource）向け・縮小された scope の新しいアクセストークンへ交換できるようにする仕組み。

初期スコープは **impersonation 型の交換**（`actor_token` なし）に限定する。典型ユースケースはマイクロサービス構成で「サービス A がユーザーのトークンを、サービス B 呼び出し専用の audience 制限付きトークンへ交換する」パターンであり、交換後のトークンは:

- `sub` は subject_token と同一（ユーザー本人として振る舞う）
- scope は subject_token の scope の部分集合に縮小できる
- audience は許可リスト内の対象へ差し替えられる
- 有効期限は subject_token の残存期間を超えない

## 採用理由（候補評価）

前サイクル（PAR, 2026-07-27〜29）の候補評価で「次サイクル以降の候補」として明示的に残された Token Exchange / JARM の 2 候補を再評価し、Token Exchange を選定した。

| 観点 | 評価 |
|---|---|
| プロジェクト関連性 | マイクロサービス間の権限委譲・audience 制限は PoC 開発者が「自分の要件がこの仕様で実現できるか」を検証したい典型テーマ。RFC 8693 は Token Exchange の標準仕様（2020年発行 Proposed Standard） |
| Experimental隔離の妥当性 | トークンエンドポイントの grant_type ディスパッチ前段に分岐を 1 つ追加するのみで、既存 grant（authorization_code / refresh_token）のデフォルト挙動を一切変えない |
| core無変更 | 可能。core の `validateGrantTypeSupported` は未知の grant_type を `unsupported_grant_type` で拒否する（`packages/core/src/token-request.ts:389-417`）が、生成コードが core のこのステップより**前に** grant_type URN を検出して experimental ハンドラへ分岐するため、core の変更が不要（PAR が authorize 前段フックで実証したのと同型のパターン） |
| CLI `--enable` 提供 | 可能。既存の experimental 機能カテゴリ（`packages/cli/src/features.ts:36` の `EXPERIMENTAL_FEATURES`）に `token-exchange` を追加する |
| 一次資料の成熟度 | RFC 8693 は 2020年1月発行の Proposed Standard。Keycloak・Auth0・Authlete 等の主要実装で提供されており相互運用実績が豊富 |
| セキュリティ影響 | 新規エンドポイントを追加しない（既存トークンエンドポイントの分岐のみ）。バックチャネル専用でブラウザ UI・Cookie を使わない。交換は「scope 縮小・期限短縮・登録済み対象への audience 差し替え」のみ許すため、権限は単調に狭まる |
| テスト可能性 | 単体・結合（conformance.test.ts）・E2E すべて HTTP レベルで検証可能。UI 不要 |
| 実装規模 | 中規模（PAR より小さい）。新規ルートが不要で、テンプレート変更は共有 `tokenRouteTemplate` 1 箇所＋discovery＋conformance に収まる |
| 将来の昇格 | grant_type ディスパッチは core の `validateTokenRequest` に grant ハンドラを追加する形で自然に昇格できる。`grant_types_supported` の discovery 統合も既存機構に乗る |
| 既存機能との重複 | なし。`tasks/T-019-dpop.md`（DPoP）は sender-constrained token で目的が異なる。refresh_token grant は「同一クライアント・同一 audience の更新」であり、「別 audience への交換」とは役割が異なる |
| 利用者の検証価値 | 「API ゲートウェイで受けたトークンを内部サービス用に縮小して配る」構成の検証は IdaaS でも設定が煩雑で、爆速検証の価値が高い |

JARM は生成 OP のフロントチャネルが `response_mode=query` 固定（`packages/cli/src/frameworks/hono/templates.ts:7027-7028` で discovery も `['query']` に固定）であり、response_mode の解釈・成功/エラー両応答の JWT 化など authorize 応答系全体に手が入るためテンプレート変更面積が大きく、今サイクルは見送り（次サイクル以降の候補として残す）。CIBA・Device Authorization Grant は前サイクルと同じ理由（追加 UI・ポーリングが必要）で見送り。RAR は authorize/token/introspection の複数層に跨がるため隔離性が劣る判断も前サイクルから変わらない。

## Experimentalにする理由

- 交換ポリシー（どのクライアントに・どの対象への交換を許すか）の設定形状（`allowedTargets` の粒度）が実運用フィードバックで変わり得るため、安定するまで隔離したい
- impersonation 限定 → delegation（`actor_token` / `act` claim）対応へ拡張する際に公開 API が変わる可能性が高い
- トークンエンドポイントの grant ディスパッチという入口に手を入れるため、生成コードの分岐パターンとして安定するまで隔離したい

## 非目標（Non-goals）

- **delegation（`actor_token` / `actor_token_type` / `act` claim / `may_act` claim, RFC 8693 §1.1・§4）**: 初期スコープは impersonation のみ。`actor_token` または `actor_token_type` がリクエストに含まれる場合は `invalid_request` で明示的に拒否する（error_description で delegation 未対応を明示）。将来拡張として「将来の昇格考慮」に記録
- **`urn:ietf:params:oauth:token-type:access_token` 以外の `subject_token_type`**（id_token / refresh_token / jwt / saml1 / saml2, RFC 8693 §3）: 本 OP が発行したアクセストークン以外は受け付けない。他の値は `invalid_request`
- **`urn:ietf:params:oauth:token-type:access_token` 以外の `requested_token_type`**: アクセストークン以外は発行しない。他の値は `invalid_request`。省略時はアクセストークンを発行する（RFC 8693 §2.1: 省略時の発行種別は AS の裁量）
- **交換時の refresh_token 発行**: RFC 8693 §2.2.1 も「token exchange のシナリオでは一般に refresh token は適切でない」と述べており、発行しない
- **交換時の ID Token 発行**: 交換応答はアクセストークンのみ。`openid` scope が縮小後 scope に残っていても ID Token は発行しない（UserInfo アクセスは可能なまま）
- **`resource` / `audience` パラメータの複数指定（RFC 8693 §2.1 は複数出現を許容）**: 生成コードのトークンエンドポイントは RFC 6749 §3.2「パラメータは重複してはならない」に基づき重複キーを 400 で拒否する（`packages/cli/src/frameworks/hono/templates.ts:2752-2775`）。本機能は各パラメータ単一値のみ対応とし、**RFC 8693 が許容する複数指定に対応しない制限**として理解資料・生成コードコメントに明示する
- **外部 IdP 発行トークンの受け入れ（クロスドメイン交換, RFC 8693 §1 の STS ユースケースの一部）**: subject_token は本 OP 発行のアクセストークンに限る。信頼設定（外部 issuer の鍵・メタデータ）が必要になり隔離規模を超える

## ユースケース / 想定利用者

- マイクロサービス構成の PoC で、「フロント API が受けたユーザートークンを、内部サービス専用の audience 制限付きトークンへ交換して渡す」構成を検証する開発者
- 「scope を落としたトークンを下流に配る（least privilege）」設計が自分のクライアント実装で成立するかを最速で確認する
- 交換ポリシー（対象許可リスト・クライアント許可）の設計を、IdaaS 導入前に手元で試す

## プロトコルフロー

```text
Client (confidential)                     OP (生成コード + experimental/token-exchange + core)
  |                                          |
  |  （事前に Authorization Code Flow 等で    |
  |    subject_token = アクセストークンを取得）|
  |                                          |
  |--- POST /token -------------------------->|  (1) クライアント認証（既存の共有パイプライン）
  |    grant_type=urn:ietf:params:oauth:      |  (2) grant_type URN を検出し experimental へ分岐
  |      grant-type:token-exchange            |  (3) パラメータ検証（必須・非対応値の拒否）
  |    subject_token=<access token>           |  (4) クライアント認可（grantTypes に URN 登録済みか、
  |    subject_token_type=urn:ietf:params:    |      confidential か）
  |      oauth:token-type:access_token        |  (5) subject_token を AccessTokenResolver で解決し
  |    [scope=...]                            |      有効性検証（RFC 8693 §2.1 MUST）
  |    [audience=... | resource=...]          |  (6) scope 縮小検証・対象許可リスト検証
  |    [requested_token_type=...]             |  (7) 新アクセストークン発行（期限は subject の残存期間で cap）
  |                                          |      ＋ accessTokenStore へ保存
  |<-- 200 {access_token, issued_token_type,  |  (§2.2.1)
  |         token_type, expires_in, scope} ---|
  |                                          |
  |--- (交換後トークンで下流 API / userinfo) -->|  既存の resolver/store 契約でそのまま検証可能
```

## 入出力

### リクエスト（RFC 8693 §2.1）

- メソッド: `POST`（既存トークンエンドポイント。`application/x-www-form-urlencoded` 必須・重複パラメータ拒否は既存の共通処理をそのまま通過する）
- クライアント認証: token endpoint の通常規則（§2.1「Client authentication to the authorization server is done using the normal mechanisms provided by OAuth 2.0」）。既存の共有認証パイプライン（`extractClientCredentials` → `resolveAuthenticatedTokenClient` → `validateClientAuthMethod` → `verifyClientSecret`）を分岐より前にそのまま利用する

| パラメータ | RFC 8693 上 | 本機能 |
|---|---|---|
| `grant_type` | REQUIRED（URN 固定） | `urn:ietf:params:oauth:grant-type:token-exchange` のとき本機能へ分岐 |
| `subject_token` | REQUIRED | 必須。本 OP 発行のアクセストークン文字列。欠落は `invalid_request` |
| `subject_token_type` | REQUIRED | 必須。`urn:ietf:params:oauth:token-type:access_token` のみ受理。欠落・他の値は `invalid_request` |
| `scope` | OPTIONAL | 任意。指定時は subject_token の scope の部分集合であること（超過は `invalid_scope`）。省略時は subject_token の scope を継承 |
| `audience` | OPTIONAL | 任意。単一値のみ（非目標参照）。`allowedTargets` に含まれない値は `invalid_target` |
| `resource` | OPTIONAL | 任意。単一値のみ。絶対 URI で fragment を含まないこと（§2.1: MUST be absolute URI / MUST NOT include fragment。query は許容）。`allowedTargets` に含まれない値は `invalid_target` |
| `requested_token_type` | OPTIONAL | 省略または `urn:ietf:params:oauth:token-type:access_token` のみ受理。他の値は `invalid_request` |
| `actor_token` / `actor_token_type` | OPTIONAL（actor_token 存在時 actor_token_type は REQUIRED） | 非目標。存在すれば `invalid_request`（delegation 未対応を error_description で明示） |

- `audience` と `resource` の両方が指定された場合: 両方を `allowedTargets` で検証し、両方の値を要求対象とする（§2.1 は併用を許容）
- どちらも省略された場合: subject_token の `audience` を要求対象として継承する（対象変更なしの scope 縮小・期限短縮のみの交換として扱う。本仕様の設計判断）
- **発行トークンの最終的な `aud` は、既存トークンルートと同じ core の `buildAccessTokenAudience`（`packages/core/src/token-response.ts:195-206`）で合成する**。この関数は OP 自身の UserInfo エンドポイントを `aud` の恒久メンバとして必ず含める（RFC 9068 §3 の非空要件と「アクセストークンは常に OP の UserInfo エンドポイントで使用できる」という既存ポリシー）。交換後トークンもこの合成を通すことで、生成 OP の UserInfo ルートの audience 検証（`validateUserInfoAudience`, `packages/core/src/userinfo.ts:423-436`）を既存実装のまま通過できる（テスト計画の「交換後トークンで UserInfo が成功する」の前提）

### 成功レスポンス（RFC 8693 §2.2.1）

- ステータス: `200 OK`、`Content-Type: application/json`、`Cache-Control: no-store` / `Pragma: no-cache`（RFC 6749 §5.1。既存トークン応答と同一）

```json
{
  "access_token": "<新しく発行されたアクセストークン>",
  "issued_token_type": "urn:ietf:params:oauth:token-type:access_token",
  "token_type": "Bearer",
  "expires_in": 300,
  "scope": "api:read"
}
```

- `access_token` / `issued_token_type` / `token_type`: REQUIRED（§2.2.1）。`token_type` は発行トークンがアクセストークンであるため常に `Bearer`（`N_A` は使用しない）
- `expires_in`: RECOMMENDED。常に含める。値は `min(config.accessTokenExpiresIn, subject_token の残存秒数)`（設計判断: 交換でトークン寿命を延長できないようにする。「セキュリティ要件」参照）
- `scope`: §2.2.1 は「要求 scope と同一なら OPTIONAL、異なるなら REQUIRED」。判定分岐を避けるため**常に含める**（同一時に含めることは仕様違反ではない。本仕様の設計判断）
- `refresh_token`: 発行しない（非目標）

### エラーレスポンス（RFC 8693 §2.2.2 / RFC 6749 §5.2）

既存トークンエンドポイントと同一形式の JSON（`Cache-Control: no-store` / `Pragma: no-cache` 付き）。

| 条件 | HTTP | error |
|---|---|---|
| クライアント認証失敗 | 401 | `invalid_client`（既存の共有認証パイプラインがそのまま処理。分岐より前） |
| クライアントの `grantTypes` に URN が未登録 | 400 | `unauthorized_client`（RFC 6749 §5.2） |
| public client（`tokenEndpointAuthMethod: 'none'`）からの交換要求 | 400 | `unauthorized_client`（本仕様の設計判断。「セキュリティ要件」参照） |
| `subject_token` / `subject_token_type` 欠落 | 400 | `invalid_request` |
| `subject_token_type` / `requested_token_type` が非対応値 | 400 | `invalid_request` |
| `actor_token` / `actor_token_type` の存在 | 400 | `invalid_request`（delegation 未対応を明示） |
| `resource` が絶対 URI でない・fragment を含む | 400 | `invalid_request`（RFC 8693 §2.1 の構文 MUST 違反。`invalid_target` は §2.2.2 の「対象への発行を拒否する」ポリシー判定に限定する。RFC 8707 §2 は malformed を `invalid_target` に含めるが、RFC 8693 は RFC 8707 を informative 参照（draft）しか持たず規範根拠にならないため、構文違反は RFC 6749 §5.2 の `invalid_request` とする設計判断） |
| subject_token が無効（不存在・期限切れ・nbf 未来・失効済み） | 400 | `invalid_request`（RFC 8693 §2.2.2「If the request itself is not valid or if either the subject_token or actor_token are invalid for any reason, or are unacceptable based on policy」→ RFC 6749 §5.2 形式で返す。`invalid_grant` ではない点に注意）。error_description は失敗種別を区別しない固定文言（オラクル化防止。「セキュリティ要件」参照） |
| 要求 scope が subject_token の scope を超過 | 400 | `invalid_scope` |
| `audience` / `resource` が `allowedTargets` に含まれない | 400 | `invalid_target`（RFC 8693 §2.2.2 SHOULD）。error_description は固定文言（許可リスト内容を露出しない） |

## 公開API案（`@maronn-openid-connect/experimental/token-exchange`）

subpath export（`packages/experimental/package.json` の `exports["./token-exchange"]` → `src/token-exchange/index.ts`）で提供する。core・PAR と同様「合成関数＋ステップ関数」の二層構成とし、CLI 生成コードはステップ単位で呼び出す。トークンの**発行と保存は experimental 内で行わず**、core の既存部品（`buildAccessTokenPayload` / `AccessTokenIssuer` / `accessTokenStore`）を生成コード側で組み合わせる（既存トークンルートの発行パイプラインと同じ流儀を保ち、experimental は RFC 8693 固有の検証・導出ロジックに限定する）。

```typescript
// ---- 定数 ----

export const TOKEN_EXCHANGE_GRANT_TYPE =
  'urn:ietf:params:oauth:grant-type:token-exchange';
export const TOKEN_TYPE_ACCESS_TOKEN =
  'urn:ietf:params:oauth:token-type:access_token';

// ---- 合成関数（組み込み利用者向け）----

/** パラメータ検証〜発行素材の導出までを一括実行する。
 *  戻り値の payloadInput を core の buildAccessTokenPayload へ渡し、
 *  発行・保存・応答生成は呼び出し側が行う */
export async function processTokenExchangeRequest(
  context: TokenExchangeRequestContext,
): Promise<TokenExchangeGrant>;

// ---- ステップ関数（processTokenExchangeRequest はこれらの合成）----

/** 必須・非対応パラメータの検証と型付け（§2.1） */
export function parseTokenExchangeParams(
  params: Record<string, string>,
): ParsedTokenExchangeParams;

/** クライアント認可: grantTypes に URN が登録済みか・confidential か */
export function authorizeTokenExchangeClient(client: TokenClientInfo): void;

/** subject_token を解決し有効性（期限・nbf・存在）を検証（§2.1 MUST） */
export async function resolveSubjectToken(options: {
  subjectToken: string;
  accessTokenResolver: AccessTokenResolver; // core の型を再利用
  now?: Date;
}): Promise<AccessTokenInfo>;

/** 要求 scope が subject scope の部分集合であることを検証し、実効 scope を返す */
export function validateExchangeScope(
  requestedScope: string | undefined,
  subjectScope: string[],
): string[];

/** audience / resource を許可リストで検証し、要求対象のリストを返す。
 *  両方省略時は subjectAudience を継承する。
 *  戻り値は最終的な aud ではなく、生成コードが core の buildAccessTokenAudience の
 *  `requested` へ渡す入力（UserInfo エンドポイントの恒久メンバ追加・重複除去・
 *  非空フォールバックは既存トークンルートと同じ合成関数に委ねる） */
export function resolveExchangeTarget(options: {
  audience?: string;
  resource?: string;
  allowedTargets: string[];
  subjectAudience?: string[];
}): string[] | undefined;

/** 発行トークンの有効期間（秒）= min(configured, subject の残存秒数) */
export function computeExchangedTokenLifetime(options: {
  subjectExpiresAt: number;   // Unix epoch 秒
  configuredExpiresIn: number;
  now?: Date;
}): number;

/** §2.2.1 の応答ボディを構築する */
export function buildTokenExchangeResponse(options: {
  accessToken: string;
  expiresIn: number;
  scope: string[];
}): TokenExchangeResponse;

// ---- 型・エラー ----

export interface TokenExchangeRequestContext {
  params: Record<string, string>;
  client: TokenClientInfo;                   // 認証済みクライアント（core の型）
  accessTokenResolver: AccessTokenResolver;  // core の型
  allowedTargets: string[];
  configuredExpiresIn: number;
  now?: Date;
}

export interface ParsedTokenExchangeParams {
  subjectToken: string;
  scope?: string;
  audience?: string;
  resource?: string;
}

/** 発行素材。生成コードはこれを core の buildAccessTokenPayload /
 *  AccessTokenIssuer.issue / accessTokenStore.set へ流す */
export interface TokenExchangeGrant {
  subject: string;            // subject_token の sub を継承（impersonation）
  clientId: string;           // 交換を要求したクライアント
  scope: string[];            // 縮小後の実効 scope
  requestedAudience?: string[]; // 検証済みの要求対象（buildAccessTokenAudience の requested 入力）
  expiresIn: number;          // cap 済みの有効期間（秒）
  grantId?: string;           // subject_token の grantId を継承（失効連動）
}

export interface TokenExchangeResponse {
  access_token: string;
  issued_token_type: typeof TOKEN_TYPE_ACCESS_TOKEN;
  token_type: 'Bearer';
  expires_in: number;
  scope: string;
}

export class TokenExchangeError extends Error {
  readonly code: TokenExchangeErrorCode;
  readonly statusCode: 400;
}

export type TokenExchangeErrorCode =
  | 'invalid_request'
  | 'unauthorized_client'
  | 'invalid_scope'
  | 'invalid_target';
```

`TokenExchangeError` を core の `TokenError` と別クラスにするのは意図的な設計である。core の `TokenErrorCode` は closed な enum（`packages/core/src/token-error.ts:7-13`）で `invalid_target` を含まないため、core 無変更の制約下では `TokenError` で RFC 8693 §2.2.2 の `invalid_target` を表現できない。PAR の `PushedRequestUriError` と同じ帰結として、生成コードの token catch 節には `TokenExchangeError` 用の分岐が必要になる（「CLI生成コードからの利用方法」の必須要件 2 を参照）。`error_description` は core の `sanitizeErrorDescription` を通す（`TokenError` と同じ扱い。`TokenError` 自身がコンストラクタで sanitize している実装に合わせる）。

`statusCode` が 400 固定なのは、401 を返すのはクライアント認証失敗（`invalid_client`）のみで、それは分岐より前の共有パイプライン（core の `TokenError`）が担うため。

依存する core API（すべて `packages/core/src/index.ts` で公開済みであることを確認済み）: `TokenClientInfo` / `AccessTokenResolver` / `AccessTokenInfo` / `sanitizeErrorDescription`。生成コード側でさらに `buildAccessTokenPayload` / `buildAccessTokenAudience` / `createJwtAccessTokenIssuer` / `createOpaqueAccessTokenIssuer`（いずれも公開済み）を既存トークンルートと同様に使う。

## CLIオプション案

- `maronn-oidc generate <framework> --enable token-exchange` で有効化。**デフォルト無効**
- `packages/cli/src/features.ts` の既存 experimental 機構に追加する（PAR で確立済みのため機構自体の変更は不要）:

```typescript
export const EXPERIMENTAL_FEATURES = ['par', 'token-exchange'] as const;
// OidcFeatureConfig に tokenExchange: boolean（デフォルト false）を追加
// EXPERIMENTAL_FEATURE_KEYS に 'token-exchange': 'tokenExchange' を追加
```

- `tokenExchange: true` のとき生成コードに以下を追加（**新規ルートファイルは作らない**）:
  - `routes/token.ts`（共有 `tokenRouteTemplate`）: ファイル冒頭に `tokenExchangeConfig` 定数（`allowedTargets`）を export し、ハンドラ内の**クライアント認証完了直後・`validateGrantTypeSupported` より前**（`packages/cli/src/frameworks/hono/templates.ts:2818` の `const authenticatedClientId = ...` の直後、`:2825` の `${grantTypeSupportedStep}` より前）に grant_type URN の分岐を挿入。catch 節に `TokenExchangeError` 分岐を追加
  - discovery テンプレート: `grantTypesSupported` の配列（`templates.ts:3415-3418`）に URN を条件付きで追加（core の `buildProviderMetadata` は配列をそのまま出力するため core 変更なし）
  - 交換を許可するサンプルクライアント: 生成 `config.ts` の登録クライアント（confidential）の `grantTypes` に URN を追加（`templates.ts:369-375` の既存パターンに条件付き補間で追加）
  - `INSTALL_COMMANDS` 相当の案内に `@maronn-openid-connect/experimental` を追加（PAR 有効時と同じ案内。両方有効時に重複しないこと）
  - `conformance.test.ts` テンプレートへ Token Exchange 契約テストを追加（`token-exchange` 有効時のみ生成）。機構は PAR の `parConformanceBlock(features)`（`packages/cli/src/frameworks/hono/templates.ts:6387`。無効時は空文字列を返す）と同型の `tokenExchangeConformanceBlock(features)` を新設し、hono の `conformanceTestTemplate`（`templates.ts:7297` の連結補間列）と web-standard 側（`packages/cli/src/frameworks/web-standard/templates.ts:2136`）の**両方**に並置して補間する（Review 2 で挿入箇所を確認済み）
  - 生成コード冒頭コメントで **Experimental である旨**（API が破壊的に変わり得る旨）と複数 audience/resource 非対応の制限を明示

## 設定値とデフォルト

| 設定 | デフォルト | 説明 |
|---|---|---|
| `allowedTargets` | `[]` | `audience` / `resource` パラメータで要求可能な対象の許可リスト。空のとき対象指定付き交換はすべて `invalid_target`（scope 縮小・期限短縮のみの交換は可能なまま）。安全側デフォルト |
| 発行トークン有効期間 | `min(config.accessTokenExpiresIn, subject の残存秒数)` | 専用設定は持たず既存の `config.accessTokenExpiresIn`（`templates.ts:429` でデフォルト 3600）を再利用し、subject_token の残存期間で cap する |
| grant URN / token type URN | 固定 | `TOKEN_EXCHANGE_GRANT_TYPE` / `TOKEN_TYPE_ACCESS_TOKEN` 定数。変更不可 |

## バリデーション

**トークンエンドポイント**（順序どおり。1 は既存共通処理、2 は既存共有パイプライン）:

1. Content-Type / 重複パラメータ / `grant_type` 欠落の検証（既存共通処理。変更なし）
2. クライアント認証（既存共有パイプライン。失敗は 401 `invalid_client`）
3. `params.grant_type === TOKEN_EXCHANGE_GRANT_TYPE` のとき本機能へ分岐（不一致なら従来フローへ。ここより下は分岐内）
4. `authorizeTokenExchangeClient`: クライアントの `grantTypes` に URN が未登録 → `unauthorized_client`（`grantTypes` 未指定クライアントは core の既定どおり `['authorization_code']` 扱いのため常に拒否。`packages/core/src/token-request.ts:71-77`）/ `tokenEndpointAuthMethod` が `'none'`（public client） → `unauthorized_client`
5. `parseTokenExchangeParams`: `subject_token`・`subject_token_type` 欠落 → `invalid_request` / `subject_token_type` 非対応値 → `invalid_request` / `requested_token_type` 非対応値 → `invalid_request` / `actor_token`・`actor_token_type` 存在 → `invalid_request` / `resource` が絶対 URI でない・fragment を含む → `invalid_request`（§2.1。query は許容）
6. `resolveSubjectToken`: resolver が null を返す（不存在・失効済み）・`expiresAt <= now`・`nbf > now` → `invalid_request`（固定文言。RFC 8693 §2.1 の「MUST perform the appropriate validation procedures for the indicated token type」を、store メタデータの有効性検証として満たす）。期限比較は `expiresAt <= now.getTime() / 1000`（実時刻）で行う
7. `validateExchangeScope`: 要求 scope に subject scope 外の値 → `invalid_scope`。省略時は subject scope を継承
8. `resolveExchangeTarget`: `audience` / `resource` が `allowedTargets` 外 → `invalid_target`。両方省略時は subject の `audience` を継承
9. `computeExchangedTokenLifetime` で有効期間を算出。残存秒数は `subjectExpiresAt - Math.floor(now.getTime() / 1000)` で計算する（`expiresAt` は整数秒であり、6 の期限検証を通過した時点で `subjectExpiresAt > now` が保証されるため、この丸め規則では残存秒数は必ず 1 以上になり `expires_in: 0` のトークンは発行されない。丸め規則を変える場合はこの保証が崩れることに注意）
10. 生成コード側: core `buildAccessTokenAudience`（UserInfo エンドポイント恒久メンバの合成）→ `buildAccessTokenPayload` → `accessTokenIssuer.issue` → `accessTokenStore.set`（`grantId` は subject の値を継承。**subject_token の `claims`（OIDC Core 1.0 §5.5 の claims パラメータ）は継承しない**。既存トークンルートは認可リクエスト由来の `claims` を store メタデータに保存するが、交換後トークンには伝播せず、UserInfo は scope ベースのクレームのみ返す。プライバシー保守側の設計判断）→ `buildTokenExchangeResponse` を返す

## エラー処理

- すべて JSON（既存トークンエンドポイント形式）。リダイレクトは存在しない（バックチャネルのみ）
- `TokenExchangeError` は生成コードの catch 節の専用分岐で処理し、`Cache-Control: no-store` / `Pragma: no-cache` を付けて `{error, error_description}` を返す（既存 `TokenError` 分岐と同一の応答形）
- subject_token の解決失敗（不存在・期限切れ・nbf 未来・失効済み）は失敗種別を区別しない固定 `error_description` とする（トークンの存在確認・失効状況のオラクル化を避ける。PAR の解決失敗と同じ方針）
- `invalid_target` の `error_description` は固定文言とし、`allowedTargets` の内容・部分一致情報を露出しない

## セキュリティ要件

| 脅威 | 対策 | 検証方法 |
|---|---|---|
| 窃取トークンの STS 経由の増幅（RFC 8693 §2.1 の注記「omitting client authentication allows for a compromised token to be leveraged via an STS into other tokens」） | クライアント認証必須＋public client 拒否（`unauthorized_client`）＋クライアント単位の grant 許可（`grantTypes` への URN 明示登録） | 結合テスト: 未登録クライアント・public client の拒否 |
| 権限昇格（scope 拡大） | 要求 scope は subject scope の部分集合のみ（超過は `invalid_scope`）。省略時も継承であり拡大しない | 単体＋結合テスト: 超過 scope の拒否・実効 scope の固定検証 |
| 対象（audience）の不正拡大 | `allowedTargets` 許可リスト（デフォルト空）外は `invalid_target`。subject の `sub` は変更不可（impersonation でも本人固定） | 単体＋結合テスト: リスト外拒否・`aud` の固定検証 |
| トークン寿命の洗浄（交換の繰り返しによる無期限延命） | `expires_in = min(configured, subject 残存秒数)`。交換を連鎖しても寿命は単調減少し、scope も単調縮小 | 単体テスト: cap 計算の固定検証 / 結合テスト: 残存期間より長い expires_in が返らないこと |
| 失効の回避（失効済み subject からの交換・交換後トークンの残存） | 失効済み subject_token は resolver が null を返し `invalid_request`。発行トークンは subject の `grantId` を継承して保存するため、既存の grant 単位失効（認可コード再利用検知等）が交換後トークンにも波及する | 結合テスト: 失効済み subject の拒否 / grantId 継承の保存内容検証 |
| トークンの存在確認オラクル | 解決失敗の error / error_description を失敗種別で区別しない固定値にする | 結合テスト: 各失敗ケースの応答同一性を固定検証 |
| リプレイ | subject_token は消費しない（RFC 8693 は単回使用を要求せず、有効期間内の再交換は正当な利用形態）。交換要求自体はクライアント認証で保護され、盗聴は TLS 前提（RFC 6749 §3.2） | 仕様レビューで確認（設計判断として理解資料に明記） |
| CSRF / SSRF / インジェクション | バックチャネル POST のみで Cookie 不使用（CSRF 非該当）。外部 URL フェッチなし（SSRF 構造的に不可能）。`resource`/`audience`/`scope` は許可リスト・部分集合検証で通過後も文字列として扱い、error_description は sanitize 済み | 仕様レビュー＋単体テスト |

**ログ禁止情報**: `subject_token`・発行したアクセストークン・`client_secret`・Authorization ヘッダをログに出力しない。ログに出すのは client_id・（あれば）トークンの `jti`・エラーコードのみ。

## プライバシー考慮

- 交換で発行されるトークンの `sub` は subject_token と同一であり、新たな属性情報の露出はない
- `aud` の差し替えにより、下流サービスが受け取るトークンの scope・audience を最小化できるため、過剰な権限・情報の伝播をむしろ抑制する方向に働く
- store に保存される発行トークンのメタデータは既存アクセストークンと同一項目であり、新たな保持情報はない
- subject_token に保存されている `claims` パラメータ（OIDC Core 1.0 §5.5。認可リクエスト時にユーザーが同意した個別クレーム要求）は交換後トークンへ**継承しない**。交換後トークンで UserInfo にアクセスした場合は scope ベースのクレームのみ返る。認可時の同意対象を交換経由で下流クライアントへ広げないためのプライバシー保守側の設計判断（バリデーション 10 参照）

## パッケージ配置と境界

```text
packages/experimental/
  package.json          # exports["./token-exchange"] を追加（par と並置）
  src/token-exchange/
    index.ts                     # 公開API
    token-exchange-request.ts    # 合成＋ステップ（parse / authorize / resolve / scope / target / lifetime / response）
    token-exchange-request.test.ts
```

### 依存方向（必須遵守）

```text
packages/core ──X──> packages/experimental（import禁止・coreの必須機能にしない）
packages/cli  ─────> @maronn-openid-connect/experimental（許可・生成コードの依存として明示）
@maronn-openid-connect/experimental ─────> @maronn-openid-connect/core（許可）
```

- core には一切手を入れない。`token-exchange` 無効時の生成コード・既存利用者の挙動は完全に不変
- 機能ごとの subpath export（`@maronn-openid-connect/experimental/token-exchange`）で提供し、ルートからの再エクスポートは作らない
- **PAR（`src/par/`）とコードを共有しない**（重複許容・独立性優先。両機能同時有効の生成も互いに干渉しない）

### CLI生成コードからの利用方法

トークンルートは 5 ターゲット全てが hono の `tokenRouteTemplate` を共有している（`packages/cli/src/frameworks/web-standard/templates.ts:2163` が `toWebRouteTemplate` の文字列変換で再利用し、express / fastify / nextjs は web-standard へ委譲する。PAR の Review 2 で確認済みの構造と同一）ため、**分岐の挿入は単一テンプレートの変更で済む**。次の 3 点を必須要件として実装する:

1. **分岐はクライアント認証完了直後・`validateGrantTypeSupported` より前に挿入する**。core の `validateGrantTypeSupported` は URN を `unsupported_grant_type` で拒否するため、これより後では分岐に到達しない。分岐内で処理を完結させ、応答を `return` する（従来フローへ合流しない）
2. **catch 節に `TokenExchangeError` の分岐を追加する**。応答形は既存 `TokenError` 分岐と同一（`Cache-Control: no-store` / `Pragma: no-cache` / JSON）。`TokenErrorCode` は closed な enum で `invalid_target` を含まない（`packages/core/src/token-error.ts:7-13`）ため、core 無変更の制約下では `TokenError` に相乗りできず、専用クラス＋専用 catch 分岐が構造的に必須
3. **挿入はすべて条件付き補間（`${...}` が無効時に空文字列/現行文字列へ展開される形）とし、`token-exchange` 無効時の生成物を現行とバイト同一に保つ**（完了条件 3 の前提。PAR で実証済みの手法）

```typescript
// （token-exchange 有効時の展開イメージ。無効時は現行どおり）
const authenticatedClientId = presentedCredentials.clientId;

// Experimental: OAuth 2.0 Token Exchange (RFC 8693). The token-exchange grant
// is dispatched before core's validateGrantTypeSupported (which would reject
// the URN with unsupported_grant_type). The whole branch returns its own
// response and never falls through to the standard grants.
if (params.grant_type === TOKEN_EXCHANGE_GRANT_TYPE) {
  // 現行テンプレートの config / privateKey / accessTokenIssuer 束縛は分岐位置より
  // 後（応答パイプライン内）で宣言されるため、分岐内で独自に取得する（既存宣言は
  // 移動せず、無効時の生成物のバイト同一を保つ）。
  const config = c.get('config');
  const privateKey = c.get('privateKey');
  const keyId = c.get('keyId');
  const accessTokenIssuer: AccessTokenIssuer =
    config.accessTokenFormat === 'opaque'
      ? createOpaqueAccessTokenIssuer()
      : createJwtAccessTokenIssuer();

  const grant = await processTokenExchangeRequest({
    params,
    client: tokenClient,
    accessTokenResolver,
    allowedTargets: tokenExchangeConfig.allowedTargets,
    configuredExpiresIn: config.accessTokenExpiresIn,
  });

  // 既存トークンルートと同じ aud 合成ポリシー（UserInfo エンドポイントを恒久メンバ
  // として含める）。交換後トークンが既存 UserInfo ルートの audience 検証を通る前提。
  const effectiveAudience = buildAccessTokenAudience({
    userInfoEndpoint: `${config.issuer}/userinfo`,
    requested: grant.requestedAudience,
    issuer: config.issuer,
  });

  const issuedAt = Math.floor(Date.now() / 1000);
  const accessTokenPayload = buildAccessTokenPayload({
    issuer: config.issuer,
    subject: grant.subject,
    clientId: grant.clientId,
    scope: grant.scope,
    audience: effectiveAudience,
    expiresIn: grant.expiresIn,
    issuedAt,
  });
  const exchangedToken = await accessTokenIssuer.issue({
    payload: accessTokenPayload,
    privateKey,
    keyId,
  });
  await accessTokenStore.set(exchangedToken, {
    sub: grant.subject,
    clientId: grant.clientId,
    scope: grant.scope,
    expiresAt: issuedAt + grant.expiresIn,
    grantId: grant.grantId,   // subject の grant に連なる（失効連動）
    iat: issuedAt,
    nbf: issuedAt,
    audience: effectiveAudience,
    issuer: config.issuer,
    // The subject token's persisted `claims` parameter (OIDC Core 1.0 §5.5) is
    // deliberately NOT inherited: the exchanged token yields scope-based claims
    // only at the UserInfo endpoint.
  });

  c.header('Cache-Control', 'no-store');
  c.header('Pragma', 'no-cache');
  return c.json(buildTokenExchangeResponse({
    accessToken: exchangedToken,
    expiresIn: grant.expiresIn,
    scope: grant.scope,
  }));
}
```

分岐位置はハンドラの `try` ブロック内（クライアント認証パイプラインの直後）であり、`TokenExchangeError` は既存 catch 節に自然に届く（PAR の authorize 前段フックで問題になった「try 外での throw」は本機能の挿入点では構造的に発生しない）。`accessTokenResolver` は userinfo ルートと同じ resolver を token ルートでも取得する必要がある（現行の token ルートは `accessTokenStore` のみ import しており、resolver の追加 import が条件付き補間に含まれる）。

分岐内の `config` / `privateKey` / `keyId` / `accessTokenIssuer` は既存宣言（`templates.ts:2831-2833` / `:2905-2908`）と重複して取得するが、分岐は `return` で完結するため二重実行にはならない（分岐に入らない場合は従来どおり既存宣言のみが実行される）。既存宣言の移動を伴わないため、無効時のバイト同一（必須要件 3）が分岐ブロック単体の条件付き補間で成立する。

## テスト計画

### 単体テスト（packages/experimental/src/token-exchange/*.test.ts）

- **正常系**: `parseTokenExchangeParams` の型付け結果（`toEqual` 固定）/ scope 省略時の継承・部分集合の実効 scope / audience・resource の許可判定と `aud` 導出（併用・省略・継承の各ケース）/ lifetime cap（configured < 残存、configured > 残存の両側を具体値で固定。残存 1 秒の境界で `expires_in` が `1` になること＝丸め規則の固定検証）/ `buildTokenExchangeResponse` の全フィールド固定（`issued_token_type`・`token_type: 'Bearer'` を含む）
- **異常系**: 必須欠落 / 非対応 `subject_token_type`・`requested_token_type` / `actor_token` 存在 / 相対 URI の `resource`・fragment 付き `resource` / resolver null・期限切れ・nbf 未来（エラーコードと固定 error_description を `toEqual` で検証し応答同一性を担保）/ scope 超過 → `invalid_scope` / リスト外 target → `invalid_target` / `grantTypes` 未登録・`grantTypes` 未指定（既定 `['authorization_code']`）・public client → `unauthorized_client`
- CLAUDE.md の規約に従い、`should + 動詞` 命名・合格値一意固定・`it` 内条件分岐なしで記述する

### 結合テスト（conformance.test.ts テンプレート追加、`token-exchange` 有効時のみ生成）

- Authorization Code Flow でトークン取得 → 交換 → 200 応答の全フィールド検証（`issued_token_type` / `token_type` / `expires_in` / `scope`）
- 交換後トークンで UserInfo が成功する（`openid` を残した場合）/ introspection が active を返し `sub`・`client_id`・`aud` が交換内容と一致する
- scope 縮小交換の実効 scope / 超過 scope の `invalid_scope`
- `allowedTargets` 内の audience 指定成功 / リスト外の `invalid_target`（生成デフォルトは空配列のため、conformance テストは PAR の `parConfig` 書き換えと同型のパターン（生成 `conformance.test.ts` の `parConfig.requirePushedAuthorizationRequests` 切り替え、`samples/hono-cloudflare/src/oidc-provider/conformance.test.ts:1975-2009`）で、export された `tokenExchangeConfig.allowedTargets` をテスト内で一時的に書き換え、テスト後に必ず復元して検証する）
- 期限切れ subject_token の `invalid_request` / 存在しない subject_token との応答同一性
- public client の `unauthorized_client` / `grantTypes` 未登録クライアントの `unauthorized_client` / 認証なしの 401
- `actor_token` 付きリクエストの `invalid_request`
- 交換後トークンの `expires_in` が subject 残存期間を超えないこと
- `claims` パラメータ付き認可で取得した subject_token を交換した場合、交換後トークンの UserInfo 応答に claims 由来の個別クレームが含まれない（claims 非継承の契約固定）
- discovery の `grant_types_supported` に URN が含まれる（無効時は含まれず、URN の grant_type が `unsupported_grant_type` で拒否される）

### E2Eテスト（tests/e2e）

- E2E 専用クライアント（`tests/e2e/apps`）にて、実ブラウザで Authorization Code Flow を完走して取得したアクセストークンをバックチャネルで交換し、交換後トークンで UserInfo へアクセスできることを検証
- OP は `samples/*` の CLI 生成アプリ（`--enable token-exchange` で再生成）を使用
- 組み込み方（U3 の解決内容。Review 3 で `tests/e2e` の実構造を確認済み）:
  - **クライアント側**: `tests/e2e/apps/client.mjs` に `/start-exchange` ルートを追加する（PAR の `/start-par` と同型の追加パターン）。認可コードフロー完走後の callback で得た `access_token` を subject_token として、既存の `formPost` ヘルパで `/token` へ交換リクエストを送り、交換後トークンで `/userinfo`（および `aud` 検証確認のため resource server の `/profile`）へアクセスした結果を、既存 `renderResult` と同様に `data-testid` 付き HTML で描画する。Playwright spec はその testid を固定値で検証する
  - **資格情報の配置**: confidential クライアントの資格情報は既存の `CLIENT_ID` / `CLIENT_SECRET` 環境変数（`tests/e2e/playwright.config.ts` の `webServer` env で注入済み）をそのまま使う。新たな配置は不要
  - **クライアント登録**: `tests/e2e/playwright.config.ts` の `oidcClientsJson` にある `e2e-client` の `grantTypes` へ交換 URN を追加する。OP サンプルは登録クライアントを `OIDC_CLIENTS_JSON` 環境変数から読む（`samples/hono-cloudflare/src/app.ts:27`）ため、サンプル側の `config.ts` を E2E のために編集する必要はない
  - **`allowedTargets` との関係**: E2E は audience / resource を省略した交換（subject の audience 継承）で検証する。`client.mjs` の `/start` は認可リクエストに `audience=resourceServerUrl` を送っており、resource server（`tests/e2e/apps/resource-server.mjs:45-47`）は introspection の `aud` に自 URL が含まれることを検証するため、継承交換された トークンがそのまま resource server の aud 検証を通過する。生成デフォルト `allowedTargets: []` のままで E2E が成立し、対象指定付き交換（`invalid_target` を含む）は conformance テストが担う
  - **skip パターン**: PAR の E2E spec と同様、discovery の `grant_types_supported` に交換 URN が含まれない場合は `test.skip` する（`--enable token-exchange` なしのサンプル OP でも共有 spec suite が green を保つ）

### 相互運用性

- RFC 8693 §2.1 / §2.2 の実例（Appendix の例を含む）と生成 OP の要求・応答をフィールド単位で突き合わせるテストを結合テストに含める

## ドキュメント要件

- `docs/library-document` の Experimental セクションに Token Exchange のガイドページを追加（概要・有効化方法・`allowedTargets` の設計・**Experimental であり API が変わり得る旨の明示**・複数 audience/resource 非対応の制限）
- `packages/experimental/README.md` の提供機能表に `token-exchange` 行を追加
- 生成コード内コメントに RFC 8693 のセクション番号を明記（既存生成コードの流儀に合わせる）

## Changeset要件

- `@maronn-openid-connect/experimental`: minor（新規機能追加）
- `@maronn-openid-connect/cli`: minor（`--enable token-exchange` の追加。既存デフォルト挙動は不変のため breaking ではない）
- core: 変更なし（changeset 不要）

## 実装順序

**着手前提（Review 3, 2026-08-01 記録）**: main のコミット `95c9efe`（experimentalのpublish設定, 2026-08-01）に未解決の git コンフリクトマーカー（`<<<<<<< Updated upstream` / `>>>>>>> Stashed changes`）が混入しており、`packages/cli/src/frameworks/hono/templates.ts`（:1658-1735 の PAR authorize ブロック周辺・:3203-3239 の userinfo ブロック周辺）・`packages/core/src/client-auth.ts`（:192-202）・`packages/cli/src/__tests__/hono-generator.test.ts`（:313-349）の 3 ファイルがコンパイル不能である。実装 Routine は着手前にこの解消（いずれも `Updated upstream` 側＝PAR 機能を含む側が既存テスト・ドキュメントと整合する）を確認し、未解消なら本機能の実装より先にマーカー解消を行うこと。本仕様書のテンプレート行番号参照はマーカー混入前のものであり、混入中は +3（token ルート周辺）〜+23（discovery / conformance 周辺）ずれるが、Review 3 で全アンカー（`const authenticatedClientId` :2821 / `${grantTypeSupportedStep}` :2828 / `grantTypesSupported` :3438 / `parConformanceBlock` :6410 / 補間列 :7320）の存在と構造の不変を確認済みで、マーカー解消後は概ね元の行番号へ戻る。

実装 Routine は次の順で進める（`packages/experimental` のビルド基盤は PAR 実装で整備済みのため、PAR のようなステップ 1 は不要）:

1. `src/token-exchange/` の実装と単体テスト、`package.json` への subpath export 追加（完了条件 1）
2. `packages/cli` の `EXPERIMENTAL_FEATURES` / `OidcFeatureConfig.tokenExchange` / `EXPERIMENTAL_FEATURE_KEYS` 追加
3. テンプレート変更: `tokenRouteTemplate` の分岐（分岐内で config / issuer 束縛を独自取得）＋catch 分岐＋`tokenExchangeConfig`（共有テンプレート 1 箇所）・discovery の `grantTypesSupported`・`config.ts` のサンプルクライアント `grantTypes`・`INSTALL_COMMANDS`・conformance テンプレート（完了条件 2・4・6）
4. `--enable token-exchange` なし生成のバイト同一確認（完了条件 3。変更前後の CLI で同一設定の生成物を diff する）
5. E2E（tests/e2e。完了条件 5）
6. ドキュメント・changeset（完了条件 7）

## 完了条件

1. `pnpm --filter @maronn-openid-connect/experimental test` で本仕様のテスト計画（単体）が全て通る
2. `maronn-oidc generate hono --enable token-exchange` の生成コードで conformance.test.ts（Token Exchange ケース含む）が通る
3. `--enable token-exchange` なしの生成コードが現行とバイト単位で同一（後方互換の客観的確認）。`--enable par` のみ・`--enable par --enable token-exchange` の組み合わせでも par 部分の生成物が単独時と一致する
4. 4フレームワーク（hono / express / fastify / nextjs）＋ web-standard で分岐入りの token ルートが生成される（共有テンプレート 1 箇所の変更で全ターゲットに反映される）
5. tests/e2e に Token Exchange フローの Playwright テストが追加され通過する
6. discovery / エラー応答が本仕様の表と一致する
7. changeset・ドキュメントが追加されている

## 未解決事項

なし（セキュリティ上の未解決事項もなし）。

解決済みの事項:

- U3（2026-08-01 Review 3 解決）: `tests/e2e` の実構造（`apps/client.mjs` の `/start-par` 追加パターン・`formPost` ヘルパ・`renderResult` の testid 描画 / `playwright.config.ts` の `oidcClientsJson` と `webServer` env による資格情報注入 / `resource-server.mjs` の aud 検証 / サンプル OP の `OIDC_CLIENTS_JSON` 読み込み）を確認し、E2E テスト計画の「組み込み方」として具体化した。生成デフォルト `allowedTargets: []` のままで E2E が成立する（audience 省略交換が subject の audience を継承し resource server の aud 検証を通過する）ことも確認済み

- U1（2026-07-31 Review 2 解決）: RFC 9700（OAuth 2.0 Security BCP, 2025-01）の原文を確認し、**RFC 8693 / Token Exchange への言及は一切ない**ことを確認した。RFC 9700 §2.2〜§2.3 の sender-constrained token・audience 制限の一般推奨は本仕様の設計（audience 許可リスト・scope 縮小）と方向が一致するが、Token Exchange 固有のガイダンスではないためセキュリティ要件表の根拠には引用しない（sources.md に「言及なし」を記録済み）
- U2（2026-07-30 Review 1 解決）: 現行 `tokenRouteTemplate` の `config` / `privateKey` / `keyId`（`templates.ts:2831-2833`）と `accessTokenIssuer`（`:2905-2908`）の束縛はいずれも分岐挿入点（`:2818` 直後）より後で宣言されることを確認した。既存宣言は移動せず、**分岐ブロック内で独自に取得する**（分岐は `return` で完結するため二重実行にならず、無効時のバイト同一が分岐ブロック単体の条件付き補間で成立する）。「CLI生成コードからの利用方法」のスケッチに反映済み

## 将来の昇格考慮

- 昇格条件の目安: (1) conformance テストが 2 サイクル以上安定 (2) `allowedTargets` の設定形状への変更要望が収束 (3) delegation（`actor_token` / `act` claim）対応の要否判断が済んだ時点で core の grant ディスパッチへの正式追加を検討
- 昇格時の作業: core `validateTokenRequest` の grant ディスパッチに token-exchange ハンドラを追加し、`ProviderMetadata` の `grant_types_supported` 統合、`TokenErrorCode` への `invalid_target` 追加（closed enum の拡張は core 変更として昇格時にのみ行う）
- delegation 対応（`actor_token` / `act` claim / `may_act`）は昇格とは独立の拡張として、`parseTokenExchangeParams` の拒否を解除し `act` claim を `buildAccessTokenPayload` 拡張で埋める形で追加可能
- 複数 `resource` / `audience` 対応は、トークンエンドポイントの重複パラメータ拒否（RFC 6749 §3.2 由来）との整合を再設計する必要があり、対応する場合は生成コードのボディ解析の変更を伴う（本仕様では非目標として明示済み）
