# Experimental機能仕様書: JWT Response for OAuth Token Introspection (RFC 9701)

- **機能名**: JWT Response for OAuth Token Introspection（署名付き JWT イントロスペクションレスポンス）
- **feature-id**: `jwt-introspection-response`
- **準拠仕様**: RFC 9701 — JWT Response for OAuth Token Introspection（Proposed Standard, 2025-01）
- **作成日**: 2026-08-24
- **ステータス**: `state.yaml` を参照

## 概要

Token Introspection エンドポイント（RFC 7662、core 実装済み・デフォルト生成対象）のレスポンスを、Resource Server の要求に応じて署名付き JWT として返せるようにする。
Resource Server がイントロスペクションリクエストの `Accept` ヘッダに `application/token-introspection+jwt` を指定したとき、OP は RFC 7662 の JSON ボディを `token_introspection` クレームに収め、`iss` / `aud` / `iat` を付けて `typ: token-introspection+jwt` で署名した JWT を返す（RFC 9701 §4 / §5）。
`Accept` の指定がない従来のリクエストへの応答は一切変わらない。

追加されるのは次の 2 面で、いずれも実装済み experimental 機能で実証済みのパターンに載る:

1. **イントロスペクションルートの応答形式分岐**（既存エンドポイントの出口への条件分岐）: `Accept` 判定 → RFC 9701 §3 の呼び出し元 audience 制限 → JWT 化。JARM が authorize ルートの応答出口に条件付き補間で合流した構造と同型
2. **discovery への追記**: `introspection_signing_alg_values_supported: ["RS256"]`（RFC 9701 §7）。PAR / Device / JARM が実証済みのスプレッドマージ 1 箇所

トークンの状態判定・属性構築はすべて core の既存関数（`resolveIntrospectionToken` / `isIntrospectionTokenActive` / `buildIntrospectionResponse`）の出力をそのまま使い、本機能は「JSON を JWT で包む」層だけを experimental に持つ。

## 採用理由（候補評価）

CIBA サイクル（2026-08-08〜10）までの候補評価で繰り返し見送られてきた候補の状況は変わっていない。
RAR（RFC 9396）は authorize / consent / token / introspection の複数層に跨がるため隔離性が劣る判断が前サイクルから変わらず、DPoP は `tasks/T-019-dpop.md` が core 変更前提の別タスクとして存在する。
今回は、JARM の実装（2026-08-04 マージ）で確立した「既存エンドポイントの応答を署名付き JWT に変換する」パターンをイントロスペクションエンドポイントへ適用できる RFC 9701 を選定した。
調査資料 `study-material/ext-jwt-introspection-response-rfc9701.md` が「導入しやすさ: 高」「既存の署名基盤とほぼ同型の関数を 1 つ足し、route で Accept を見て分岐するだけ」と評価済みの候補である。

| 観点 | 評価 |
|---|---|
| プロジェクト関連性 | 署名付きイントロスペクションは FAPI 系・高保証 API の PoC で要求される構成要素で、「イントロスペクション結果の出所と完全性を RS 側で暗号的に検証したい」は本ライブラリの典型的検証テーマ。RFC 9701 は 2025 年 1 月発行の Proposed Standard で、Speed（最新仕様への最速追隨）の実績になる |
| Experimental隔離の妥当性 | `Accept: application/token-introspection+jwt` が明示された場合のみ挙動が変わる。指定がない・`application/json` の場合は完全に従来どおりで、既存イントロスペクションのデフォルト挙動を一切変えない。JARM の「response_mode に JWT 系の値が明示された場合のみ」と同じ隔離構造 |
| core無変更 | 可能。トークン判定・属性構築は core の公開関数の出力をそのまま使う。JWT 署名は JARM の先例（`packages/experimental/src/jarm/response-jwt.ts`）どおり Web Crypto の compact JWS 自前実装で行い、core の非公開ヘルパーに依存しない。鍵は生成コードの既存コンテキスト（`c.set('signingKeys', ...)`、`templates.ts:290`。全ルート共通の `app.use('*')` ミドルウェアで供給）と core 公開の `selectSigningKeyByAlg`（`packages/core/src/index.ts:242`）で得る |
| CLI `--enable` 提供 | 可能。`EXPERIMENTAL_FEATURES` に `'jwt-introspection-response'` を追加する。introspection 機能への依存があるため、`--disable introspection` との組み合わせ検証を新設する（CLIオプション案の節） |
| 一次資料の成熟度 | RFC 9701 は IETF Proposed Standard。参照する RFC 7662 / 7519 / 8414 はいずれも実装済みまたは調査済み |
| セキュリティ影響 | 新規エンドポイントなし。JWT 化に伴う cross-JWT confusion（§8.1）は `typ` 固定と `token_introspection` への封入で仕様自体が対策を定義しており、そのまま実装する。呼び出し元 audience 制限（§3）は JWT 応答経路に閉じて実装する（セキュリティ要件の節） |
| テスト可能性 | HTTP レベルで完結する。`Accept` ヘッダ分岐・JWT 構造・JWKS による署名検証は conformance.test.ts（fetch ベース）で固定でき、E2E は既存のリソースサーバー役アプリからの検証が書ける |
| 実装規模 | 小〜中（JARM より小さい）。experimental 新規モジュール 1 + 既存ルートテンプレートへの条件付き補間 + discovery 追記 + conformance。新規 UI なし・新規エンドポイントなし・ストア契約なし |
| 将来の昇格 | `createIntrospectionResponseJwt` は core の `generateUserInfoJwt`（`packages/core/src/userinfo.ts`）と同型で、そのまま core へ移植できる。調査資料の候補 A も core 実装を想定しており、experimental での検証後に昇格する道筋が明確 |
| 既存機能との重複 | なし。JARM は認可レスポンス（フロントチャネル）、本機能はイントロスペクションレスポンス（バックチャネル）で、対象エンドポイントも媒体も異なる。`tasks/p3-introspection-caller-authorization-hook.md`（core への `canIntrospect` フック追加）とは対象が重なるが、同タスクは JSON 応答を含む全経路の core オプトインフックで、本機能は JWT 応答経路に閉じた RFC 9701 準拠の制限。境界は「coreとの境界」の節に明記する |
| 利用者の検証価値 | 「署名付きイントロスペクションを RS 側でどう検証するか」「typ 検証を怠ると何が起きるか」を手元で最速検証できる。RFC 9701 対応を明示する IDaaS はまだ少なく、検証環境の選択肢自体が少ない |

CIBA（Approved 済み・実装 Routine 引き継ぎ待ち）とは対象エンドポイントが異なり重複しない。
Device Authorization Grant / PAR / Token Exchange とも重複しない。

## Experimentalにする理由

- `Accept` ヘッダによるコンテントネゴシエーションの解釈（ワイルドカードや q 値の扱い）は RFC 9701 が厳密に定めておらず、本仕様の設計判断（完全一致のみ）が利用者フィードバックで変わり得る
- 呼び出し元 audience 制限（§3）の既定ポリシー（発行先クライアント本人または `aud` に含まれる呼び出し元のみ開示）は、利用者のリソースサーバー構成に依存して差し替えたくなる可能性が高く、公開 API の形が固まっていない
- 将来 core の `canIntrospect` フック（`tasks/p3-introspection-caller-authorization-hook.md`）が実装された場合、制限ロジックの置き場所を core 側へ寄せる再設計があり得る

## 非目標（Non-goals）

- **暗号化レスポンス（RFC 9701 §6 の `introspection_encrypted_response_alg` / `enc`、Nested JWT）**: JWE 基盤が本リポジトリに存在せず、`study-material/id-token-and-userinfo-encryption-jwe.md` の方針確定が先。discovery の `introspection_encryption_alg_values_supported` / `introspection_encryption_enc_values_supported` は出力しない（いずれも OPTIONAL）
- **クライアントメタデータ `introspection_signed_response_alg` による alg ネゴシエーション（§6）**: 署名 alg は RS256 固定とする。§6 は「省略時の既定は RS256」と定めており、固定値は既定と一致する。JARM が `authorization_signed_response_alg` を持たず RS256 固定とした判断と同じ。RS256 以外を登録したクライアントの扱いが必要になったら experimental 内の破壊的変更で対応する
- **アクセストークンによる RS 認証（§4）**: §4 はイントロスペクション呼び出しの認証に「client authentication methods または RS に発行された別のアクセストークン」を許すが、本 OP のイントロスペクションエンドポイントは既存どおりクライアント認証（`client_secret_basic` / `client_secret_post`）のみとする。RS はクライアントとして登録する（§3 が RFC 7591 を例示する「RS をクライアントとして扱う」構成そのもの）
- **JSON 応答経路（RFC 7662）の挙動変更**: `Accept` で JWT を要求しないリクエストへの応答は、audience 制限を含め一切変えない。既存利用者のイントロスペクション挙動の互換を維持し、JSON 経路の呼び出し元認可は `tasks/p3-introspection-caller-authorization-hook.md`（core の `canIntrospect` フック）の責務のままとする
- **revocation エンドポイントへの適用**: RFC 9701 はイントロスペクションのみを対象とする
- **`Accept` の q 値・ワイルドカードによる選好解決**: `application/token-introspection+jwt` がメディアタイプとして明示されている場合のみ JWT で応答する。`*/*` や `application/*` は JWT 応答の要求と解釈しない（設計判断: §4 は「Accept HTTP header field set to "application/token-introspection+jwt"」であり、明示要求のみを対象とする。ワイルドカードを JWT と解釈すると、汎用 HTTP クライアントの既定 `Accept: */*` が送る従来型リクエストの応答形式が変わり、後方互換が壊れる）

## ユースケース / 想定利用者

- マイクロサービス間や TLS 終端が多段のゲートウェイ構成で、イントロスペクション結果の改ざん耐性と出所検証を要件に持つ構成を PoC する開発者
- FAPI 系プロファイル・高保証 API の導入を見据え、署名付きイントロスペクションの RS 側検証（`typ` 検証・JWKS 解決・クレーム封入の確認）を手元で理解したい開発者
- イントロスペクション応答に法的責任を持つ構成（RFC 9701 §1 が挙げる、検証済み個人データから証明書を作る等）の要件を検証する開発者

## プロトコルフロー

```text
Resource Server (クライアントとして登録済み)        OP (生成コード + experimental/jwt-introspection-response + core)
  |                                                     |
  |-- POST /introspect ------------------------------->|
  |   Accept: application/token-introspection+jwt      | (1) Content-Type / クライアント認証（既存の共有パイプライン）
  |   Content-Type: application/x-www-form-urlencoded  | (2) token 必須・token_type_hint 解決（core 既存ステップ）
  |   token=...                                        | (3) active 判定・属性構築（core 既存ステップ）
  |                                                    | (4) Accept 判定: JWT 要求あり
  |                                                    | (5) audience 制限: 呼び出し元が発行先本人でも aud 記載先でも
  |                                                    |     なければ { active: false } に落とす（RFC 9701 §3 / §5）
  |                                                    | (6) token_introspection クレームに封入し
  |                                                    |     iss / aud / iat を付けて RS256 署名（§5）
  |<- 200 Content-Type: application/token-introspection+jwt
  |   <compact JWS>                                    |
  |                                                    |
  |   （RS は JWKS で署名検証し typ を確認して利用）      |
  |                                                    |
  |-- POST /introspect （Accept 指定なし） ------------>| (1)〜(3) 同上
  |<- 200 application/json {active: ...}               | 従来どおりの RFC 7662 JSON（本機能は関与しない）
```

## 入出力

### リクエスト（RFC 9701 §4） — 既存 `POST /introspect` への `Accept` 判定追加

リクエストの形は RFC 7662 §2.1 から変わらない（`token` 必須・`token_type_hint` 任意・`application/x-www-form-urlencoded`・クライアント認証必須）。
本機能が追加するのは応答形式の判定だけである。

| Accept ヘッダ | 応答 |
|---|---|
| `application/token-introspection+jwt` を含む（大文字小文字は区別しない。メディアタイプパラメータ・q 値は無視して型の一致だけを見る） | 署名付き JWT（`Content-Type: application/token-introspection+jwt`） |
| ヘッダなし / `application/json` / `*/*` / `application/*` / その他 | 従来どおり JSON（変更なし） |

判定は experimental の `acceptsIntrospectionJwt(acceptHeader)` が行う。
カンマ区切りの各要素からメディアタイプ部分（`;` より前）を取り出し、小文字化して `application/token-introspection+jwt` と完全一致する要素が 1 つでもあれば true。
q 値による選好順位は解決しない（`application/token-introspection+jwt;q=0` のような明示的拒否は考慮せず JWT で応答する。設計判断: §4 に q 値の規定はなく、拒否したい RS はメディアタイプ自体を送らなければよい）。

### 成功応答（RFC 9701 §5）

```text
HTTP/1.1 200 OK
Content-Type: application/token-introspection+jwt
Cache-Control: no-store
Pragma: no-cache

<compact JWS>
```

JOSE ヘッダー:

| パラメータ | 値 | 根拠 |
|---|---|---|
| `typ` | `token-introspection+jwt` | §5 REQUIRED（cross-JWT confusion 対策の要） |
| `alg` | `RS256` | §6 の省略時既定。本機能は固定（非目標の節） |
| `kid` | 署名鍵の keyId | JWKS で検証鍵を特定させる（RFC 8725 §3.10 の実践。JARM と同じ） |

ペイロード（トップレベルクレーム）:

| クレーム | 値 | 根拠 |
|---|---|---|
| `iss` | OP の issuer URL | §5 MUST |
| `aud` | 認証済み呼び出し元の `client_id` | §5 MUST（「introspection response を受け取る RS を識別」。本 OP は RS をクライアントとして登録するため client_id が識別子） |
| `iat` | 応答生成時刻（UNIX 秒） | §5 MUST |
| `token_introspection` | RFC 7662 §2.2 の応答メンバーをそのまま収めた JSON オブジェクト（audience 制限適用後） | §5 MUST |
| `sub` / `exp` | **含めない** | §5 SHOULD NOT（アクセストークンとしての悪用防止。§8.1） |

`token_introspection` の中身は core の `buildIntrospectionResponse` / `INACTIVE_INTROSPECTION_RESPONSE` の出力そのものであり、本機能はメンバーを追加・削除・改変しない（audience 制限で全体を `{ active: false }` に置き換える場合を除く）。
active でないトークンも同じ構造の JWT で返す（§5: active メンバーを false にし、他のメンバーを含めない。`INACTIVE_INTROSPECTION_RESPONSE` がこの形そのもの）。

### audience 制限（RFC 9701 §3 / §5）

§5 は「アクセストークンが無効・期限切れ・失効済み・**呼び出し元 RS 宛でない**場合、`token_introspection.active` を false にし、他のメンバーを含めてはならない（MUST NOT）」と定める。
§3 も「AS は RS がそのアクセストークンの audience であるかを判定できなければならず（MUST）、判定方法は AS の裁量」とする。
本機能は JWT 応答経路に次の既定ポリシーを適用する:

- `token_introspection` が `active: true` になるのは、呼び出し元の `client_id` が「トークンの発行先（`client_id` メンバー）」または「トークンの `aud` メンバーに含まれる」場合のみ
- どちらにも該当しない場合は `{ active: false }` に置き換える（理由は応答から区別できない。§2.2 の「存在しないトークンと区別させない」原則と同じオラクル防止）

判定は experimental の `restrictIntrospectionResponseToCaller(response, callerClientId)` が行う。
core の `IntrospectionResponse` は `client_id`（`packages/core/src/introspection.ts:135`）と保存されている場合の `aud`（同 143-144 行）を含むため、判定材料は応答オブジェクトだけで揃い、core 変更もストアアクセスも要らない。
JSON 応答経路にはこの制限を適用しない（非目標の節。RFC 7662 の互換維持と、core 側フックタスクとの責務分離）。

**`aud` の意味論と既定運用（U1 の確定、Review 2）**:
生成コードのアクセストークン `aud` は core の `buildAccessTokenAudience`（`packages/core/src/token-response.ts:203`）が合成し、UserInfo エンドポイント URL（`${config.issuer}/userinfo`）を恒久メンバとして必ず含む。
認可リクエストの `audience` パラメータ（空白区切り。`authorization-request.ts:1109`）や Token Exchange の `allowedTargets` にある値は末尾に加わる。
つまり既定の `aud` メンバーはリソース識別子の URI であり、client_id は入らない。
この前提での単純一致は fail-closed に働く。
発行先本人は `client_id` メンバーの一致で開示され、それ以外の RS は、トークンがその RS の client_id を `audience` 値として発行されていない限り `{ active: false }` を受け取る。
第三者の RS へ開示を許すには、その RS の client_id をトークンの `aud` に入れて発行する（クライアントが `audience` パラメータで要求するか、Token Exchange の `allowedTargets` に載せる）。
この運用は README に明記する（ドキュメント要件の節）。
リフレッシュトークンの応答は `aud` メンバーを持たないため（`buildRefreshTokenResponse`）、発行先本人だけに開示される。
本 OP に動的クライアント登録はなく client_id は運用者が割り当てるため、リソース URI と同名の client_id を第三者が自称して開示を得る経路はない。

### エラー応答

エラー応答（クライアント認証失敗・`token` 欠落・Content-Type 不正等）は従来どおり JSON で返し、JWT 化しない。
RFC 9701 はエラー応答の JWT 化を定めておらず、§5 が JWT を定めるのは introspection response 本体のみである。
`Accept` が JWT を要求していても、エラーは RFC 7662 §2.3（RFC 6749 §5.2 の形式）の JSON で返る。

**仕様間の相違の記録**: RFC 9701 §5 の Note は「本仕様に準拠する AS は、呼び出し元を認証しないイントロスペクションリクエストの処理を拒否し HTTP 400 を返さなければならない（MUST）」とする。
一方、既存実装（core の共有クライアント認証パイプライン）は RFC 7662 §2.3 が参照する RFC 6749 §5.2 に従い、認証失敗を `invalid_client` の **401** で拒否する。
この MUST の実質は「認証なしにトークンデータを一切開示しない（§8.2 のダウングレード防止）」であり、本 OP は認証必須の既存挙動でこれを満たしている。
ステータスコードは既存の 401 を維持する（設計判断: 共有パイプラインの挙動を JWT 要求の有無で分岐させると、`Accept` ヘッダの値で認証エラーの形が変わる不自然な API になる。RFC 7662 系の 401 と RFC 9701 の 400 の相違として understanding-guide にも記録し、README に明記する）。

## 公開API案（`@maronn-openid-connect/experimental/jwt-introspection-response`）

```typescript
// 定数
export const TOKEN_INTROSPECTION_JWT_MEDIA_TYPE = 'application/token-introspection+jwt';
export const TOKEN_INTROSPECTION_JWT_TYP = 'token-introspection+jwt';

// Accept ヘッダ判定（「入出力」の判定規則を実装）
export function acceptsIntrospectionJwt(acceptHeader: string | null | undefined): boolean;

// RFC 9701 §3 / §5 の呼び出し元 audience 制限
// active:false はそのまま返す。active:true は呼び出し元が client_id と一致するか
// aud に含まれる場合のみそのまま返し、それ以外は INACTIVE 相当 { active: false } を返す。
// 入力オブジェクトは変更しない（純関数）
export function restrictIntrospectionResponseToCaller(
  response: IntrospectionResponse,
  callerClientId: string,
): IntrospectionResponse;

// RFC 9701 §5 の応答 JWT 生成
// JOSE ヘッダー { typ: 'token-introspection+jwt', alg: 'RS256', kid }
// ペイロード { iss, aud, iat, token_introspection }（sub / exp は含めない）
// 署名は Web Crypto の compact JWS 自前実装（JARM response-jwt.ts と同じ方式・core 無変更）
export function createIntrospectionResponseJwt(options: {
  issuer: string;                     // iss クレーム
  audience: string;                   // aud クレーム（認証済み呼び出し元 client_id）
  introspection: IntrospectionResponse; // token_introspection クレームに封入
  signingKey: SigningKey;             // RS256 鍵であること（JARM と同じ契約。
                                      // selectSigningKeyByAlg(keys, 'RS256') で選ぶ）
  now?: Date;                         // iat のテスト用注入点。既定は現在時刻
}): Promise<string>;
```

`IntrospectionResponse` / `SigningKey` は core 公開型をそのまま使う（`packages/core/src/index.ts` 公開済み）。
設定オブジェクトは持たない。
RFC 9701 の JWT は `exp` を含めないため寿命設定が不要で、alg は RS256 固定のため（非目標の節）、JARM に存在した設定ファイル相当（`jarm.ts` の lifetime 設定）も生成しない。
エラークラスも追加しない（本機能の各関数は入力が公開 API の契約を満たす限り失敗せず、署名鍵の不一致は Web Crypto の例外がそのまま伝播して route の既存 `server_error` 分岐に落ちる。JARM と同じ扱い）。

## CLIオプション案

- `--enable jwt-introspection-response` で有効化（デフォルト無効）。`packages/cli/src/features.ts` の `EXPERIMENTAL_FEATURES` に `'jwt-introspection-response'` を追加し、`OidcFeatureConfig` に `jwtIntrospectionResponse: boolean` を追加（`EXPERIMENTAL_FEATURE_KEYS` / `DEFAULT_FEATURES` / JSDoc も同時に更新）
- **組み合わせ検証（新設）**: `resolveFeatures` の解決後に `jwtIntrospectionResponse && !introspection` を検査し、`--enable jwt-introspection-response --disable introspection` の組を「jwt-introspection-response requires the introspection feature」の明示エラーで拒否する。既存の enable/disable 重複検査と同じ throw 方式。cross-feature 依存の検証は本機能が初なので、エラーメッセージに依存の理由（イントロスペクションエンドポイントが生成されない）を含める
- `packages/cli/src/index.ts` の `withExperimentalPackage` の feature チェックへ `features.jwtIntrospectionResponse` を追加（experimental パッケージをインストールガイダンスに含める条件。既存 4 機能と同じ 1 行）
- 生成物（hono テンプレート起点・web-standard 変換で全フレームワークへ展開）:
  - `introspectionRouteTemplate`（`packages/cli/src/frameworks/hono/templates.ts:6231`）に `features` 引数を追加し（`loginRouteTemplate(corePkg, features)` と同じ形）、呼び出し 2 箇所（`packages/cli/src/frameworks/hono/index.ts:45` と `packages/cli/src/frameworks/web-standard/templates.ts:2459`）へ `features` を渡す。テンプレートには次を条件付き補間する:
    - experimental subpath からの import（`acceptsIntrospectionJwt` / `restrictIntrospectionResponseToCaller` / `createIntrospectionResponseJwt`）と core からの `selectSigningKeyByAlg` / `type SigningKey` の追加 import
    - 応答構築後の分岐: `acceptsIntrospectionJwt(c.req.header('Accept'))` が true なら、`restrictIntrospectionResponseToCaller` → `c.get('signingKeys')` から `selectSigningKeyByAlg(keys, 'RS256')` → `createIntrospectionResponseJwt` → `c.header('Content-Type', 'application/token-introspection+jwt')` を設定して `c.text(jwt)` で返却（hono の `c.text` も web-standard 変換先の `WebContext.text` も、設定済み `Content-Type` を上書きしない実装であることを確認済み）。false なら従来の `c.json(response)`
    - EXPERIMENTAL である旨のコメント（既存機能と同じ形式）
  - discovery への追記: 最終 `c.json` のスプレッドマージ（`templates.ts:5306` 付近の `${parDiscoveryMetadata}${deviceDiscoveryMetadata}${jarmDiscoveryMetadata}` と同じ場所）へ `introspection_signing_alg_values_supported: ['RS256']` を追加（RFC 9701 §7。introspection と jwt-introspection-response の両方が有効な場合のみ）
  - conformance.test.ts への RFC 9701 シナリオ追加（`packages/cli` の生成テンプレートを変更する。sample を直接編集しない）
- 既存機能との干渉なし: `jwt-introspection-response` 無効時の生成出力は現行とバイト同一であること（完了条件で検証）
- 実装時の注意: `packages/cli/src/__tests__/par-feature.test.ts:112-114` の unknown-feature テストは期待エラーメッセージに experimental 機能一覧の部分文字列を含む。`toThrow` は部分一致のため、`EXPERIMENTAL_FEATURES` 末尾への追加では壊れないが、追加位置を配列末尾以外にするとメッセージ列挙順が変わり失敗する。末尾に追加すること（CIBA 実装が先に入った場合も同様に末尾へ追加する）

## 設定値とデフォルト

本機能に設定値はない。

| 項目 | 値 | 根拠 |
|---|---|---|
| 署名 alg | RS256 固定 | RFC 9701 §6 の省略時既定と一致。JARM と同じ固定方針（非目標の節） |
| JWT の寿命（`exp`） | 付与しない | §5 SHOULD NOT（アクセストークン悪用防止）。鮮度は `iat` で表明し、判定は RS の責務 |
| audience 制限ポリシー | 発行先本人または `aud` 記載先のみ（固定） | §3 の MUST を満たす最小の既定。差し替え可能化は昇格時の検討事項（将来の昇格考慮） |

## バリデーション / エラー処理

「入出力」の節の判定規則・エラー応答の節を正とする。実装は次を守る:

- すべての応答（JSON / JWT とも）に既存の `Cache-Control: no-store` / `Pragma: no-cache` を維持する
- `restrictIntrospectionResponseToCaller` の判定結果（制限が働いたか否か）を応答・ログから区別できるようにしない（`{ active: false }` の理由を露出しない）
- トークン値・イントロスペクション結果の属性をログへ出力しない（既存ルートの方針を維持）
- 署名鍵セットに RS256 鍵が存在しない場合、`selectSigningKeyByAlg` の例外が既存の catch に落ちて `server_error` になる（JWT を `alg` 偽装で返すことはない。JARM の「署名偽造の余地は無く、失敗するのは署名処理そのもの」と同じ性質）

## セキュリティ要件

| 脅威 | 対策 |
|---|---|
| cross-JWT confusion: イントロスペクション JWT をアクセストークンや ID トークンとして流用（§8.1） | `typ: token-introspection+jwt` を必ず設定。属性は `token_introspection` クレームに封入しトップレベルへ展開しない。トップレベルに `sub` / `exp` を含めない（§5 SHOULD NOT）。単体テストでヘッダ・クレーム構造を固定検証する |
| 認証なしダウングレード: 匿名呼び出しでトークンデータ取得（§8.2） | 既存ルートのクライアント認証パイプラインは本機能の有無・`Accept` の値によらず必ず通過する（分岐は認証・トークン解決の後の応答構築のみ）。conformance で「認証なし + JWT 要求」が従来どおり拒否されることを検証 |
| 権限外トークンの偵察: 登録クライアントが他 RS 宛トークンの属性を JWT で収集（§3） | audience 制限（発行先本人または `aud` 記載先のみ）。制限に落ちた応答は `{ active: false }` で理由を区別させない。JSON 経路は既存挙動のまま（互換維持）であり、JSON 経路で従来から可能な収集は本機能が新たに作る面ではない（core フックタスクの責務） |
| 署名鍵の取り違え・alg 混乱 | `alg: RS256` 固定・`kid` 必須。鍵選択は `selectSigningKeyByAlg(keys, 'RS256')` で行い、RS256 以外の鍵で署名 JWT が生成されることはない（鍵不一致は Web Crypto が例外を投げる） |
| 応答の改ざん・出所偽装（本機能が解決する脅威そのもの） | RS256 署名 + JWKS 公開鍵配布（既存基盤）。RS 側の検証手順（JWKS 解決 → 署名検証 → `typ` 確認 → `iss` / `aud` 確認）を README と understanding-guide に記載 |
| トークンデータの平文露出 | TLS 前提（§8.2 は BCP 195 を MUST 参照）。本ライブラリは検証用でありデプロイ時の TLS は利用者責務である旨を README の既存方針どおり明記。JWE 暗号化は非目標として明示 |

## プライバシー考慮

- イントロスペクション応答は PII（`sub` 等）を RS へ移転する（RFC 9701 §9）。本 OP は検証用ライブラリであり法的根拠の管理（§9 の legal basis）は利用者責務である旨を README に記載する
- audience 制限は §9 の「RS の identity とトークンデータに基づき受領可能なデータを決定しなければならない（MUST）」の最小実装でもある
- §9 の指摘（イントロスペクションリクエスト自体が「ユーザーがいつ RS を使ったか」を AS に知らせる）は仕様の構造的性質であり、README の注意事項として記載する

## 配置案 / CLI生成コードからの利用方法 / coreとの境界

- 実体: `packages/experimental/src/jwt-introspection-response/`（`accept.ts` / `audience.ts` / `response-jwt.ts` / `index.ts` / 各 `.test.ts`）
- 公開: `@maronn-openid-connect/experimental/jwt-introspection-response` の subpath export のみ。ルート再エクスポートはしない
- 他 experimental 機能とコードを共有しない（JARM の compact JWS 実装と同種のコードになるが、重複を許容する運用方針に従い `jwt-introspection-response/` 内に持つ）
- core 変更なし。core からの import は公開 API（`IntrospectionResponse` / `SigningKey` / `selectSigningKeyByAlg` の型・関数）のみ
- `tasks/p3-introspection-caller-authorization-hook.md`（core の `canIntrospect` フック）との境界: 同タスクは JSON 応答を含む全経路の任意フックを core に足す提案で未着手。本機能の audience 制限は JWT 応答経路限定・experimental 内完結で、core のフックが将来入っても JSON 経路の既定挙動を変えない本機能とは競合しない。フック実装後に制限ロジックを寄せる再設計は昇格時の検討事項とする

```text
packages/core ──X──> packages/experimental（import禁止・coreの必須機能にしない）
packages/cli  ─────> @maronn-openid-connect/experimental（許可・生成コードの依存として明示）
@maronn-openid-connect/experimental ─────> @maronn-openid-connect/core（peerDependencies として許可）
```

- デフォルト無効。`--enable jwt-introspection-response` を明示した場合のみ生成物に現れる。core・CLI の既存利用者への破壊的変更なし

## テスト計画

### 単体テスト（`packages/experimental/src/jwt-introspection-response/*.test.ts`、t_wada 流 TDD）

- `acceptsIntrospectionJwt`: 完全一致 / 大文字小文字 / 複数要素中の一致 / パラメータ付き（`;q=0.9` 等）/ ヘッダなし・空文字 / `*/*` と `application/*` が false / `application/json` が false / 前後空白
- `restrictIntrospectionResponseToCaller`: active:false はそのまま / 発行先本人は開示 / `aud`（配列・文字列）に含まれる呼び出し元は開示 / どちらでもない呼び出し元は `{ active: false }` のみ（他メンバーが 1 つも無いこと）/ `aud` なしトークンは発行先本人のみ / 入力オブジェクト非破壊
- `createIntrospectionResponseJwt`: JOSE ヘッダーの `typ` / `alg` / `kid` を具体値で固定 / ペイロードの `iss` / `aud` / `iat` / `token_introspection` を具体値で固定 / トップレベルに `sub` / `exp` が無い / active:false 応答の JWT 化 / 署名が公開鍵で検証できる / `now` 注入で `iat` が決定的

### conformance.test.ts（CLI 生成コードで追加。`--enable jwt-introspection-response` 生成 OP への結合テスト）

- `Accept: application/token-introspection+jwt` で `Content-Type: application/token-introspection+jwt` の JWT が返り、JWKS の公開鍵で署名検証でき、`typ` / `iss` / `aud` / `iat` / `token_introspection.active: true` が具体値で一致
- `Accept` 指定なしの応答が従来の JSON のまま（回帰）
- 無効トークンの JWT 応答が `token_introspection: { active: false }` のみ
- 発行先と異なる登録クライアントによる JWT 要求が `active: false` に制限される
- 認証なしリクエストが `Accept` の値によらず従来どおり拒否される（ダウングレード防止）
- discovery に `introspection_signing_alg_values_supported: ['RS256']` が出る（値は具体値で固定）
- 機能無効時: JWT の `Accept` を送っても JSON で返る・discovery に `introspection_signing_alg_values_supported` が無い

### E2E（`tests/e2e`、Playwright）

- 既存のリソースサーバー役アプリ（`tests/e2e` 配下）が認可コードフロー完了後のアクセストークンを `Accept: application/token-introspection+jwt` でイントロスペクトし、JWKS で署名検証・`typ` 確認・`token_introspection.active: true` 確認まで行う全周シナリオ
- 実 HTTP フローとしての検証価値はヘッダネゴシエーションと JWT 検証チェーンにあり、ブラウザ操作は既存フローの再利用で足りる

## ドキュメント要件

- `packages/experimental/README.md` に `jwt-introspection-response` の節を追加（Accept 明示のみ・RS256 固定・audience 制限の既定・第三者 RS へ開示するにはその client_id を `audience` 値としてトークンへ入れる運用・JSON 経路は不変・401/400 の相違・TLS と PII の利用者責務、の明記）
- CLI の `--enable` ヘルプ文言（`features.ts` の JSDoc とヘルプ出力）
- 生成コードコメントに Experimental である旨と API 不安定の警告（既存機能と同じ形式）
- `docs/implementation-guides/experimental/jwt-introspection-response.ja.md` / `.en.md` を作成する（CLAUDE.md の規約。実装しきった時点で必須。掲載コードは抜粋ではなく全文）

## Changeset要件

- `packages/experimental/src` の変更に changeset を手で書かない（CI が patch を自動生成。CLAUDE.md / RELEASE.md 準拠）
- `packages/cli` の変更には minor の changeset を書く（新機能フラグ追加）

## 実装順序

実装 Routine は次の順で進める。各ステップの検証方法は「完了条件」の対応番号を参照する:

1. `packages/experimental/src/jwt-introspection-response/` の実装と単体テスト（`accept` → `audience` → `response-jwt` の順。t_wada 流に red → green で進める。完了条件 1）
2. `packages/experimental/package.json` に `exports["./jwt-introspection-response"]` を追加（既存 4 機能と同型）
3. `packages/cli/src/features.ts` へ feature 追加（`EXPERIMENTAL_FEATURES` 末尾）と `resolveFeatures` の組み合わせ検証・`packages/cli/src/index.ts` の `withExperimentalPackage` へ `features.jwtIntrospectionResponse` を追加
4. テンプレート変更（共有 `hono/templates.ts`）: `introspectionRouteTemplate` への `features` 引数追加と条件付き補間 → discovery スプレッドマージ → conformance テンプレート（完了条件 2・6）。続けて呼び出し 2 箇所（`hono/index.ts:45` / `web-standard/templates.ts:2459`）へ `features` を渡す変更（他フレームワークへの展開は既存の `toWebRouteTemplate` 変換で完結する）
5. `--enable jwt-introspection-response` なし生成のバイト同一確認（完了条件 3。変更前後の CLI で同一設定の生成物を diff する。サンプルが使う既存の `--enable` 組み合わせでも確認する）
6. `samples/*/package.json` の `generate` スクリプトへ `--enable jwt-introspection-response` を追加してサンプル再生成 → `tests/e2e` に検証シナリオを追加（完了条件 4）
7. ドキュメント（README 節・ヘルプ・実装解説 ja/en）・changeset（CLI のみ minor を手書き）・`pnpm review:experimental jwt-introspection-response` でパケット生成（完了条件 5・7）

## 完了条件

1. `packages/experimental/src/jwt-introspection-response/` の単体テストがすべて通る
2. `--enable jwt-introspection-response` で生成した OP に対する conformance.test.ts（全フレームワーク）が通る
3. `jwt-introspection-response` を有効にしない生成出力が変更前とバイト同一である
4. E2E シナリオ（JWT イントロスペクション全周）が通る
5. `pnpm review:experimental jwt-introspection-response` でパケットが生成され `--check` が通る
6. discovery 出力・応答の `Content-Type` / JWT 構造が本仕様の表と一致する
7. ドキュメント要件（`docs/implementation-guides/experimental/jwt-introspection-response.ja.md` / `.en.md` を含む）・Changeset要件を満たす

## 未解決事項

| ID | 内容 | 状態 |
|---|---|---|
| U1 | audience 制限の判定に使う `aud` の意味論: 本 OP の `AccessTokenInfo.audience` に client_id 以外（リソース URI 等）が入る運用で、呼び出し元 client_id との単純一致が §3 の意図（RS の識別）と一致するか。既定の一致規則で十分か、識別子の対応表を持つべきか | **確定（Review 2）**: 生成コードの `aud` は UserInfo エンドポイント URL と要求リソース値で構成され、client_id を含まないことを実地確認。単純一致は fail-closed で §3 の MUST を満たし、識別子の対応表は持たない。開示したい RS の client_id を `audience` 値として発行する運用を「audience 制限」の節と README に記載する |
| U2 | JWT 応答の返却手段 | **確定（Review 1）**: `c.header('Content-Type', ...)` を設定した上で `c.text(jwt)` を使う。hono の `c.text` と web-standard 変換先の `WebContext.text`（`web-standard/templates.ts` 内 `WebContext` クラス）はどちらも設定済み `Content-Type` を上書きしない実装で、既存の `Cache-Control` / `Pragma` ヘッダもそのまま載る |
| U3 | conformance テストでの JWT 検証の実装手段: 生成アプリの conformance.test.ts が JWKS から公開鍵を組み立てて RS256 検証するユーティリティを既に持つか（ID トークン検証の既存実装を流用できるか） | open（Review 3 で既存 conformance テンプレートを確認して確定する） |

## 将来の昇格考慮

- `createIntrospectionResponseJwt` は core の `generateUserInfoJwt`（`packages/core/src/userinfo.ts`）と同型であり、調査資料の候補 A（core 実装）の形へそのまま移植できる
- audience 制限は core の `canIntrospect` フック（`tasks/p3-introspection-caller-authorization-hook.md`）が実装された時点で、フックの一実装として提供し直す再設計があり得る（experimental 内の破壊的変更で完結）
- 暗号化レスポンス（§6）対応は JWE 基盤（`study-material/id-token-and-userinfo-encryption-jwe.md`）の方針確定後に別提案として起こす
- クライアントごとの `introspection_signed_response_alg`（§6）対応は、per-client alg を持つ最初の機能になるため、クライアントメタデータ拡張の設計提案として別途記録する
