# Experimental機能仕様書: OpenID Connect RP-Initiated Logout 1.0

- **機能名**: RP-Initiated Logout（RP 主導のログアウトエンドポイント）
- **feature-id**: `rp-initiated-logout`
- **準拠仕様**: OpenID Connect RP-Initiated Logout 1.0（Final, 2022-09-12）
- **作成日**: 2026-09-09
- **ステータス**: `state.yaml` を参照

## 概要

生成 OP に `end_session_endpoint`（`GET|POST /logout`）を追加し、RP がユーザーエージェントを遷移させて OP のブラウザセッションを終了できるようにする。
リクエストに有効な `id_token_hint` があり、それが現在のセッションの End-User に一致する場合は即座にログアウトし、それ以外の場合は仕様の MUST（RP-Initiated Logout 1.0 §2）に従って確認画面を挟む。
ログアウト後は、検証済みクライアントに登録された `post_logout_redirect_uri` へ完全一致でのみリダイレクトし、`state` をそのまま返す。
discovery には `end_session_endpoint` を追記する。

追加されるのは次の 3 面で、いずれも実装済み experimental 機能で実証済みのパターンに載る:

1. **新規エンドポイントとユーザー向け画面**: `/logout`（GET / POST）と確認画面・完了画面。Device Authorization Grant の verification UI（`/device` 系）と CIBA の認証デバイス UI（`/ciba` 系）が同型の「新規ルート + views 差し替え可能な画面」を実証済み
2. **discovery への追記**: `end_session_endpoint`。PAR / Device / CIBA / JARM / ID-JAG が実証済みのスプレッドマージ 1 箇所
3. **experimental 設定オブジェクト**: クライアントごとの `post_logout_redirect_uris` を生成コード側の設定に持つ。Token Exchange の `tokenExchangeConfig.allowedTargets` が同型の「experimental 機能専用設定を生成コードに置く」パターンを実証済み

`id_token_hint` の検証は core 公開の `validateIdTokenHint`（`packages/core/src/index.ts:141` でエクスポート済み）をそのまま使い、本機能は「ログアウト要求の解釈とリダイレクト先の確定」だけを experimental に持つ。
セッションの実体（Cookie とストア）は従来から生成コードの責務であり（`templates.ts` の `SESSION_COOKIE_NAME` / browser session store）、本機能はそのストアの既存 `delete` を呼ぶ。

## 採用理由（候補評価）

jwt-introspection-response サイクル（2026-08-24 作成、2026-09-02 承認）までの候補評価で見送られてきた候補の状況は変わっていない。
RAR（RFC 9396)は複数層に跨がる隔離性の問題が変わらず、DPoP は `tasks/T-019-dpop.md` が core 変更前提の別タスクとして存在する。
Native SSO 1.0 は Token Exchange 実装済みで前提が揃ったものの、`ds_hash` クレームを ID Token に入れる必要があり、core の `generateIdToken` に任意クレームの注入点がないため core 無変更で実装できない。
今回は、ログアウト系仕様が一切未実装という機能面の空白（`study-material/ext-rp-initiated-logout.md` が「検証できないのは片手落ち」と評価済み）を埋められ、かつ Device / CIBA で確立した「新規エンドポイント + UI 画面」のテンプレートパターンに載る RP-Initiated Logout 1.0 を選定した。

| 観点 | 評価 |
|---|---|
| プロジェクト関連性 | SSO 導入の検証では「ログインできるか」と同じ重みで「ログアウトが要件どおり動くか」が問われる。本 OP はログイン系のみ実装済みで、シングルログアウト要件の検証が現状不可能。RP-Initiated Logout はログアウト系 4 仕様（RP-Initiated / Session Management / Front-Channel / Back-Channel）の中で最も需要が高く、他 3 仕様の前提にもなる |
| Experimental隔離の妥当性 | 新規エンドポイントの追加のみで、既存エンドポイントの挙動を一切変えない。機能無効時は `/logout` が存在しない（404）。JARM や jwt-introspection-response の「明示された場合のみ」よりさらに強い隔離になる |
| core無変更 | 可能。`id_token_hint` 検証は core 公開の `validateIdTokenHint` を使う。セッションの Cookie とストアは生成コード側にあり、ストア契約（`delete(sessionId)`）も既存。クライアントごとの `post_logout_redirect_uris` は core の `ClientInfo` を拡張せず、Token Exchange の `allowedTargets` と同じく experimental 設定オブジェクトとして生成コードに置く |
| CLI `--enable` 提供 | 可能。`EXPERIMENTAL_FEATURES` に `'rp-initiated-logout'` を追加する。他機能への依存はない（セッション基盤は常に生成される） |
| 一次資料の成熟度 | OpenID Connect RP-Initiated Logout 1.0 は 2022-09-12 の Final。参照する OIDC Core 1.0 / Discovery 1.0 は実装済み |
| セキュリティ影響 | 新規に増える面は「未認証で叩けるログアウトエンドポイント」と「リダイレクト」の 2 つ。前者は仕様自身が確認画面の MUST で DoS を塞ぎ、後者は登録値との完全一致 MUST でオープンリダイレクトを塞ぐ。いずれも仕様の定めをそのまま実装する（セキュリティ要件の節） |
| テスト可能性 | HTTP レベルで完結する。ヒント検証・確認画面分岐・リダイレクト判定は conformance.test.ts（fetch ベース）で固定でき、E2E はログイン済みブラウザでのログアウト全周（セッション消滅の確認まで）が書ける |
| 実装規模 | 中（Device Authorization Grant と同程度）。experimental 新規モジュール 1 + 新規ルートテンプレート + 画面 2 種 + discovery 追記 + conformance。新規ストア契約なし |
| 将来の昇格 | `study-material/ext-rp-initiated-logout.md` の方針 A（core に「ログアウト要求検証」純関数を置く）がそのまま昇格先の形になる。experimental の各関数は純関数として設計するため移植は機械的 |
| 既存機能との重複 | なし。実装済み 6 機能はいずれもトークン発行系で、セッション終了系は初。`tasks/*.md` の既存タスクにもログアウト系はない |
| 利用者の検証価値 | 「id_token_hint なしのログアウト要求がどう扱われるか」「post_logout_redirect_uri の登録と完全一致がどう効くか」「ログアウト後に prompt=none がどう失敗するか」を手元で検証できる。IDaaS ごとに挙動差が大きい領域で、仕様の素の挙動を確認できる環境に価値がある |

jwt-introspection-response（Approved 済み・実装 Routine 対象）とは対象エンドポイントが異なり重複しない。

## Experimentalにする理由

- 確認画面を出す条件（有効なヒントがあれば省略する、という本仕様の既定）は SHOULD の解釈であり、「常に確認する」「確認なしを許す構成値を持つ」のいずれが利用者に必要かはフィードバックで変わり得る
- クライアントごとの `post_logout_redirect_uris` を experimental 設定オブジェクトに持つ形は、将来 core の `ClientInfo` へ寄せる再設計があり得る（昇格時の検討事項）
- Front-Channel / Back-Channel Logout を将来足す場合、RP への通知フェーズの挿入点を本機能のルート構造に作ることになり、公開 API の形が変わり得る

## 非目標（Non-goals）

- **Session Management 1.0（`check_session_iframe` / `session_state`）**: iframe ベースのセッション監視は対象外。discovery にも関連フィールドを出さない
- **Front-Channel Logout 1.0 / Back-Channel Logout 1.0**: 他 RP への伝播は対象外。`sid` クレームの発行も、伝播仕様を実装する時点まで行わない。RP-Initiated Logout 1.0 が「RP への通知が終わってからリダイレクトする」と定める通知フェーズは、通知対象仕様が非目標のため空である（この帰結は understanding-guide に記載する）
- **期限切れ `id_token_hint` の受理**: 仕様は「RP に現在または最近のセッションがあれば exp を過ぎた ID Token も受理すべき（SHOULD）」とするが、core の `validateIdTokenHint` は exp 超過を拒否する。本機能は期限切れヒントを「無効なヒント」として扱い、確認画面の経路（MUST の側）に落とす。ログアウト自体は確認を経て完了できるため安全側の逸脱であり、core へ leeway 注入点を足す変更はしない（SHOULD の不採用として README に明記する）
- **`logout_hint` / `ui_locales` の解釈**: どちらも受理するが動作を変えない（OPTIONAL）。`logout_hint` はセッション特定に使わず、`ui_locales` による画面の多言語化はしない
- **確認画面の省略設定**: 確認画面の要否は本仕様の判定規則で固定し、構成値を設けない
- **OP セッション以外の後始末**: 発行済みトークンの失効はしない。online refresh token はセッション消滅により `invalid_grant` になる（core の既存挙動。`AuthenticationSessionResolver` が null を返すため）。offline refresh token とアクセストークンは有効なまま残る（RFC 7009 revocation の責務）。この境界は understanding-guide と README に明記する

## ユースケース / 想定利用者

- SSO 構成の PoC で、RP のログアウトボタンから OP セッションまで終了させる全周を検証したい開発者
- `post_logout_redirect_uri` の登録運用と完全一致検証の挙動（未登録 URI・部分一致・クエリ差分で何が起きるか）を手元で確認したい開発者
- ログアウト後の `prompt=none` の失敗（`login_required`）や online refresh token の失効など、セッション終了の波及を検証したい開発者

## プロトコルフロー

```text
RP                                     OP (生成コード + experimental/rp-initiated-logout + core)
 |                                       |
 |-- GET /logout ----------------------->| (1) パラメータ解釈（GET query / POST form の両対応。§2 MUST）
 |   ?id_token_hint=...                  | (2) id_token_hint 検証: core validateIdTokenHint
 |   &post_logout_redirect_uri=...       |     （iss / aud / 署名 / exp。aud は client_id パラメータ、
 |   &state=...                          |       無ければヒント payload の aud から特定）
 |                                       | (3) client_id パラメータがあれば aud との一致を検証（§2 MUST）
 |                                       | (4) セッション照合: ヒントの sub と現在セッションの subject
 |                                       |
 |          [有効なヒント + セッション一致]  | (5a) セッション削除 + Cookie 破棄
 |                                       | (6a) post_logout_redirect_uri が登録値と完全一致
 |<- 302 post_logout_redirect_uri?state= |      → state を付けてリダイレクト（§3）
 |   （不一致・未指定なら完了画面 200）      |
 |                                       |
 |          [ヒントなし / 無効 / 不一致]    | (5b) 確認画面を表示（§2 MUST。この時点では何も消さない）
 |                                       | (6b) ユーザーが確認画面のフォームを POST
 |                                       |      → セッション削除 + 完了画面（リダイレクトはしない）
```

## 入出力

### リクエスト（§2） — `GET|POST /logout`

OP は GET と POST の両方を受理しなければならない（§2 MUST）。
POST は `application/x-www-form-urlencoded` のボディからパラメータを読む。

| パラメータ | 位置づけ | 本機能の扱い |
|---|---|---|
| `id_token_hint` | RECOMMENDED | core の `validateIdTokenHint` で検証。検証に通らない値は「ヒントなし」と同じ扱い（確認画面の経路） |
| `client_id` | OPTIONAL | 指定時はヒントの `aud` と一致しなければならない（§2 MUST）。不一致なら「ヒントなし」と同じ扱い |
| `post_logout_redirect_uri` | OPTIONAL | 検証済みクライアントの登録値と完全一致した場合のみ使用（§3 MUST NOT の裏返し） |
| `state` | OPTIONAL | 解釈せず、リダイレクト時にクエリパラメータ `state` としてそのまま返す（§3） |
| `logout_hint` | OPTIONAL | 受理するが使用しない（非目標の節） |
| `ui_locales` | OPTIONAL | 受理するが使用しない（非目標の節） |

### 判定規則

1. **クライアントの特定**: `id_token_hint` の検証に使う期待 `aud` は、`client_id` パラメータがあればその値、なければヒント payload を復号して得た `aud`（文字列ならその値、配列なら `azp` があればその値、なければ要素が 1 つの場合のみその要素）。特定できなければヒントは無効
2. **ヒントの検証**: core `validateIdTokenHint(hint, { expectedIss: issuer, expectedAud, jwks })`。例外はすべて「無効なヒント」に落とし、理由を応答に出さない
3. **即時ログアウトの条件**: ヒントが有効で、かつ現在のブラウザセッションが存在し、ヒントの `sub` がセッションの subject と一致する場合のみ。このとき確認画面を出さずにセッションを削除する（§2 の SHOULD からの逸脱。設計判断: RP のログアウト操作は End-User 自身の操作であり、有効なヒントは RP がその End-User にトークンを発行された当人であることを示す。Keycloak など主要実装も同じ省略をする。逸脱として README に記載する）
4. **確認画面の条件**: 上記以外のすべて（ヒントなし・無効・`client_id` 不一致・セッションなし・`sub` 不一致）。§2 の MUST（「id_token_hint が無い、または供給された ID Token が現在の OP セッションのものでない場合、OP はユーザーに確認しなければならない」）と、§7 のセキュリティ考慮（有効なヒントのないログアウト要求は DoS の手段になり得る）をそのまま実装する
5. **セッションが存在しない場合**: ヒントが有効でも即時ログアウトの条件を満たさない（セッション不一致）ため確認画面に落ちる。確認画面の文言はセッションの有無で変えない（セッション存在のオラクルにしない）。確認の POST は、削除対象が無ければ何も削除せず完了画面を出す
6. **リダイレクトの条件**: 「ヒントが有効」かつ「`post_logout_redirect_uri` がそのクライアントの登録値と完全一致（文字列比較）」の場合のみ。確認画面を経由した場合もこの条件を再評価し、満たせばリダイレクトする。ヒントが無効な要求は登録値に一致してもリダイレクトしない（§3: RP を特定・検証できない場合のリダイレクト禁止）
7. **`state` の返却**: リダイレクト URL のクエリに `state` を付加する（URL API で追加し、既存クエリを保持する）。リダイレクトしない場合、`state` はどこにも出力しない

### 応答

| 経路 | 応答 |
|---|---|
| 即時ログアウト + 登録 URI 完全一致 | `302 Found`、`Location: <post_logout_redirect_uri>[?state=...]` |
| 即時ログアウト + URI 不一致または未指定 | `200 OK`、ログアウト完了画面（HTML） |
| 確認画面 | `200 OK`、確認画面（HTML。approve フォームは POST `/logout/confirm`） |
| 確認画面からの approve POST | セッション削除後、リダイレクト条件を再評価して `302` または完了画面 |
| `/logout/confirm` への不正 POST（CSRF トークン不一致・期限切れ） | `400 Bad Request`（画面にエラー表示。何も削除しない） |

エラーを OAuth 形式の JSON（`error` / `error_description`）で返す経路はない。
ログアウトエンドポイントはユーザーエージェントが直接開く画面であり、機械可読エラーの契約を持たない（Device の verification UI と同じ扱い）。

## 公開API案（`@maronn-openid-connect/experimental/rp-initiated-logout`）

```typescript
// end_session リクエストの正規化。GET は URL クエリ、POST はフォームボディの
// URLSearchParams を渡す。重複パラメータは最初の値を採用する
export interface EndSessionRequest {
  idTokenHint?: string;
  clientId?: string;
  postLogoutRedirectUri?: string;
  state?: string;
  logoutHint?: string;
  uiLocales?: string;
}
export function parseEndSessionRequest(params: URLSearchParams): EndSessionRequest;

// 判定規則 1 のクライアント特定。署名検証前の payload 復号のみ行う
// （返り値は検証に使う期待 aud であり、信頼はその後の validateIdTokenHint が与える）。
// 復号できない・特定できない場合は null
export function extractIdTokenHintAudience(idTokenHint: string): string | null;

// 判定規則 3・4 の分岐。verifiedHint は core validateIdTokenHint の戻り値
// （検証失敗時は null を渡す）。純関数
export interface LogoutDecision {
  // true: 確認画面を出す。false: 即時ログアウト
  requiresConfirmation: boolean;
  // リダイレクト判定に使う検証済みクライアント（ヒント無効時は null）
  verifiedClientId: string | null;
}
export function decideLogoutFlow(options: {
  verifiedHint: { sub: string; [key: string]: unknown } | null;
  expectedAudience: string | null;   // extractIdTokenHintAudience または client_id パラメータ
  clientIdParam: string | undefined; // §2 MUST の一致検証（expectedAudience との照合）
  sessionSubject: string | null;     // 現在セッションの subject（セッションなしは null）
}): LogoutDecision;

// 判定規則 6・7。完全一致しなければ null。一致すれば state を付加した URL 文字列
export function resolvePostLogoutRedirect(options: {
  postLogoutRedirectUri: string | undefined;
  state: string | undefined;
  verifiedClientId: string | null;
  registeredUris: readonly string[]; // verifiedClientId の登録値（生成コードの設定から引く）
}): string | null;
```

`validateIdTokenHint` / `IdTokenHintError` は core 公開 API をそのまま使う。
設定オブジェクトは experimental 側では持たず、クライアントごとの登録 URI は生成コードの `rpInitiatedLogoutConfig.postLogoutRedirectUris: Record<string, string[]>` から引いて `registeredUris` に渡す（Token Exchange の `allowedTargets` と同じ配置）。
エラークラスは追加しない（各関数は入力が契約を満たす限り失敗せず、判定の否定は戻り値の null / requiresConfirmation で表す）。

## CLIオプション案

- `--enable rp-initiated-logout` で有効化（デフォルト無効）。`packages/cli/src/features.ts` の `EXPERIMENTAL_FEATURES` 末尾に `'rp-initiated-logout'` を追加し、`OidcFeatureConfig` に `rpInitiatedLogout: boolean` を追加（`EXPERIMENTAL_FEATURE_KEYS` / `DEFAULT_FEATURES` / JSDoc も同時に更新）
- 組み合わせ検証は不要（セッション基盤・JWKS・ログイン画面は常に生成されるため、他機能への依存がない）。`--disable` との干渉もない
- `packages/cli/src/index.ts` の `withExperimentalPackage` の feature チェックへ `features.rpInitiatedLogout` を追加
- 生成物（hono テンプレート起点。web-standard 変換で全フレームワークへ展開):
  - 新規 `endSessionRouteTemplate(corePkg)`: `GET|POST /logout` と `POST /logout/confirm`。Device の `deviceVerificationRouteTemplate`（`packages/cli/src/frameworks/hono/templates.ts:3700`）と同じ構造。確認画面の approve POST は Device / CIBA の approve と同じ per-flow CSRF cookie（HttpOnly / Secure / SameSite）で保護する
  - views インターフェースへ `logoutConfirmationPage` / `logoutCompletedPage` を追加（`deviceVerificationPage` と同じ差し替え可能パターン。機能有効時のみ型・既定実装を補間）
  - discovery への追記: 既存スプレッドマージ（`templates.ts:6981` の `${parDiscoveryMetadata}...` の並び）へ `end_session_endpoint: config.issuer + '/logout'` を追加
  - 設定への追記: 生成される設定モジュールへ `rpInitiatedLogoutConfig`（`postLogoutRedirectUris: Record<string, string[]>`、既定は空）を機能有効時のみ追加
  - conformance.test.ts への RP-Initiated Logout シナリオ追加（CLI の生成テンプレートを変更する。sample を直接編集しない）
- 既存機能との干渉なし: `rp-initiated-logout` 無効時の生成出力は現行とバイト同一であること（完了条件で検証）
- 実装時の注意: unknown-feature テスト（`packages/cli/src/__tests__/par-feature.test.ts`）の期待エラーメッセージは `EXPERIMENTAL_FEATURES` の列挙順に依存するため、配列の末尾に追加すること

## 設定値とデフォルト

| 項目 | 値 | 根拠 |
|---|---|---|
| `rpInitiatedLogoutConfig.postLogoutRedirectUris` | `Record<string, string[]>`、既定は空 | §3 の「事前登録された値との完全一致」の登録簿。空ならすべてのリダイレクト要求が完了画面に落ちる（fail-closed） |
| エンドポイントパス | `/logout`（確認 POST は `/logout/confirm`）固定 | Device の `/device` 系と同じくパス構成値は持たない |
| 確認画面の要否 | 判定規則で固定（構成値なし） | 非目標の節 |

## バリデーション / エラー処理

「入出力」の判定規則と応答の表を正とする。実装は次を守る:

- `id_token_hint` の検証失敗の理由（署名不正・期限切れ・aud 不一致など）を応答・画面・ログのいずれにも出さない。すべて同じ確認画面に落とす
- `id_token_hint` の値・`logout_hint` の値をログへ出力しない
- リダイレクト URL の構築は URL API で行い、`state` 以外のパラメータを付加しない
- 確認画面の approve POST は CSRF cookie の照合に失敗したら何も削除しない
- セッション削除は browser session store の既存 `delete` と Cookie の破棄（`Max-Age=0` の Set-Cookie）を両方行う

## セキュリティ要件

| 脅威 | 対策 |
|---|---|
| 未認証ログアウトによる DoS（§7: 有効な id_token_hint のない要求で被害者のセッションを勝手に終了させる） | 有効なヒントが現在セッションに一致する場合以外は必ず確認画面を挟む（§2 MUST）。GET リンクを踏ませるだけではセッションは消えない |
| オープンリダイレクト | リダイレクトは「検証済みクライアント」かつ「登録値と完全一致」の場合のみ（§3 MUST NOT）。ヒントが無効な要求は一致してもリダイレクトしない。完全一致は文字列比較で、正規化・前方一致・クエリ無視をしない |
| 確認画面への CSRF（攻撃者が被害者のブラウザで approve POST を偽造） | Device / CIBA の approve と同じ per-flow CSRF cookie を確認画面発行時に設定し、POST で照合する |
| `state` を介した反射（XSS・ヘッダインジェクション） | `state` は解釈せず URL API のクエリ付加でのみ出力する（URL エンコードされる）。画面へは出力しない |
| セッション存在のオラクル | 確認画面・完了画面の文言をセッションの有無で変えない。応答時間差も、削除操作の有無以外の分岐を作らないことで最小化する |
| 他人の ID Token を使ったログアウト強要 | ヒントの `sub` が現在セッションの subject と一致しない場合は即時ログアウトしない（確認画面に落ちる）。ヒント自体の真正性は署名検証（iss / aud / exp）で担保する |
| トークン値の漏洩 | `id_token_hint` は ID Token そのものであり、値をログ・画面に出さない |

## プライバシー考慮

- `id_token_hint` は End-User の `sub` を含む PII であり、検証以外の用途（記録・転送）に使わない
- `logout_hint` はユーザー識別子であり得るため、使用しない本機能では読み取り後に破棄し、ログに出さない
- 完了画面・確認画面に End-User の識別子を表示しない（画面を見た第三者への漏洩防止。ログイン画面と同じ方針）

## 配置案 / CLI生成コードからの利用方法 / coreとの境界

- 実体: `packages/experimental/src/rp-initiated-logout/`（`request.ts`（parse と aud 抽出）/ `decision.ts` / `redirect.ts` / `index.ts` / 各 `.test.ts`。ファイル分割は実装時に調整してよいが公開 API は本仕様に従う）
- 公開: `@maronn-openid-connect/experimental/rp-initiated-logout` の subpath export のみ。ルート再エクスポートはしない
- 他 experimental 機能とコードを共有しない（base64url 復号など JARM / id-jag と同種のコードになるが、重複を許容する運用方針に従い機能内に持つ）
- core 変更なし。core からの import は公開 API（`validateIdTokenHint` / `IdTokenHintError` の型・関数）のみ
- セッションストア・Cookie・CSRF cookie・画面はすべて生成コード（CLI テンプレート）側にあり、experimental モジュールは HTTP にもストアにも触れない純関数群とする

```text
packages/core ──X──> packages/experimental（import禁止・coreの必須機能にしない）
packages/cli  ─────> @maronn-openid-connect/experimental（許可・生成コードの依存として明示）
@maronn-openid-connect/experimental ─────> @maronn-openid-connect/core（peerDependencies として許可）
```

- デフォルト無効。`--enable rp-initiated-logout` を明示した場合のみ生成物に現れる。core・CLI の既存利用者への破壊的変更なし

## テスト計画

### 単体テスト（`packages/experimental/src/rp-initiated-logout/*.test.ts`、t_wada 流 TDD）

- `parseEndSessionRequest`: 各パラメータの取り出し / 未指定は undefined / 重複時は最初の値 / 空文字の扱い
- `extractIdTokenHintAudience`: aud 文字列 / aud 配列 + azp / aud 配列（要素 1）/ aud 配列（複数・azp なし）は null / 不正な JWS 形式・不正 base64url・不正 JSON は null
- `decideLogoutFlow`: 有効ヒント + sub 一致 → 即時 / ヒント null → 確認 / client_id パラメータと expectedAudience 不一致 → 確認 + verifiedClientId null / セッション null → 確認 / sub 不一致 → 確認 / 確認経路でも有効ヒントなら verifiedClientId を保持
- `resolvePostLogoutRedirect`: 登録値と完全一致 → state 付き URL / state なし → パラメータ付加なし / 部分一致・末尾スラッシュ差・クエリ差 → null / verifiedClientId null → null / uri 未指定 → null / 登録リスト空 → null / 既存クエリを持つ登録 URI に state が追記される

### conformance.test.ts（CLI 生成コードで追加。`--enable rp-initiated-logout` 生成 OP への結合テスト）

- ログイン済みセッションで有効ヒント + 登録 URI → 302 と `state` の返却、セッション Cookie の破棄、以後の authorize が未ログイン挙動
- ヒントなし GET → 200 確認画面（セッションは消えていない）
- 確認画面の approve POST（CSRF cookie あり）→ セッション削除
- CSRF cookie なしの approve POST → 400、セッション維持
- 未登録 `post_logout_redirect_uri` → リダイレクトせず完了画面
- `client_id` パラメータとヒント aud の不一致 → 確認画面
- discovery に `end_session_endpoint` が具体値で出る
- 機能無効時: `/logout` が 404、discovery に `end_session_endpoint` が無い

### E2E（`tests/e2e`、Playwright）

- 認可コードフロー完了 → RP のログアウトリンクで `/logout`（ヒント + 登録 URI + state）→ RP に `state` 付きで戻る → 再度 authorize するとログイン画面が出る（セッション消滅の実挙動確認）
- ヒントなしで `/logout` を開く → 確認画面で承認 → 完了画面 → セッション消滅

## ドキュメント要件

- `docs/library-document/src/content/docs/experimental/rp-initiated-logout.md` に利用者向けページを追加し、`experimental/index.md` の機能一覧を更新する（確認画面の判定規則・登録 URI の設定方法・期限切れヒント SHOULD の不採用・確認省略の設計判断・トークン失効との境界、の明記）
- `packages/experimental/README.md` の「提供機能」表へ `rp-initiated-logout` の行を追加する
- CLI の `--enable` ヘルプ文言（`features.ts` の JSDoc とヘルプ出力）
- 生成コードコメントに Experimental である旨と API 不安定の警告（既存機能と同じ形式）
- `docs/implementation-guides/experimental/rp-initiated-logout.ja.md` / `.en.md` を作成する（CLAUDE.md の規約。実装しきった時点で必須。掲載コードは抜粋ではなく全文）

## Changeset要件

- `packages/experimental/src` の変更に changeset を手で書かない（CI が patch を自動生成。CLAUDE.md / RELEASE.md 準拠）
- `packages/cli` の変更には minor の changeset を書く（新機能フラグ追加）

## 実装順序

1. `packages/experimental/src/rp-initiated-logout/` の実装と単体テスト（`request` → `decision` → `redirect` の順。t_wada 流に red → green で進める。完了条件 1）
2. `packages/experimental/package.json` に `exports["./rp-initiated-logout"]` を追加
3. `packages/cli/src/features.ts` へ feature 追加（`EXPERIMENTAL_FEATURES` 末尾）と `packages/cli/src/index.ts` の `withExperimentalPackage` 更新
4. テンプレート追加・変更（共有 `hono/templates.ts`）: `endSessionRouteTemplate` 新設 → views 追加 → discovery スプレッドマージ → 設定オブジェクト → conformance テンプレート → ルート登録 2 箇所（`hono/index.ts` / `web-standard/templates.ts`）
5. `--enable rp-initiated-logout` なし生成のバイト同一確認（完了条件 3）
6. `samples/hono-cloudflare/package.json` の `generate` スクリプトへ `--enable rp-initiated-logout` を追加してサンプル再生成 → `tests/e2e` に検証シナリオを追加（完了条件 4。experimental 機能のフル有効化サンプルは hono-cloudflare のみとする先例に従う）
7. ドキュメント（利用者向けページ・README 節・ヘルプ・実装解説 ja/en）・changeset（CLI のみ minor を手書き）（完了条件 5・7）

## 完了条件

1. `packages/experimental/src/rp-initiated-logout/` の単体テストがすべて通る
2. `--enable rp-initiated-logout` で生成した OP に対する conformance.test.ts（全フレームワーク）が通る
3. `rp-initiated-logout` を有効にしない生成出力が変更前とバイト同一である
4. E2E シナリオ（ログアウト全周 2 本）が通る
5. `pnpm typecheck` / `pnpm build` / `pnpm --filter "./packages/*" test` が通る
6. discovery 出力・確認画面分岐・リダイレクト判定が本仕様の表と一致する
7. ドキュメント要件（実装解説 ja / en を含む）・Changeset要件を満たす

## 未解決事項

| ID | 内容 | 状態 |
|---|---|---|
| U1 | 確認画面から approve したとき、`post_logout_redirect_uri` へのリダイレクトを許すか。本仕様の判定規則 6 は「有効なヒントがあれば確認経由でも許す」とするが、確認画面を挟んだ時点でヒントとセッションの不一致が確定しているケース（別ユーザーのセッション）では、リダイレクトが RP へ「誰かがログアウトした」ことを伝える面がある。許容範囲か、確認経由は常に完了画面とすべきか | 未確定。Review 2 で §3 の文言と突き合わせて確定する |
| U2 | `extractIdTokenHintAudience` の azp フォールバック（aud 配列時）: 本 OP の ID Token の aud は client_id 単一文字列のはずで、配列ケースは自 OP 発行トークンでは生じない。防御的分岐を持つか、単純化するか | 未確定。Review 2 で core の ID Token 発行実装（`buildIdTokenAudience` 相当）を確認して確定する |
| U3 | 確認画面 POST 先のパス（`/logout/confirm` か `/logout` への POST 相乗りか）。`/logout` は end_session の POST 受理（§2 MUST）に使うため別パスとしたが、Device / CIBA の approve パス命名（`/device/approve` / `/ciba/approve`）に合わせて `/logout/approve` とする案もある | 未確定。Review 3 で生成テンプレートの一貫性から確定する |

## 将来の昇格考慮

- `study-material/ext-rp-initiated-logout.md` の方針 A（core にログアウト要求検証の純関数を置き、`ClientInfo` に `postLogoutRedirectUris` を追加する）が昇格先の形。本機能の各純関数はそのまま移植できる
- Front-Channel / Back-Channel Logout を実装する場合、`sid` クレームの発行（core の ID Token 変更）が必要になるため、伝播系は experimental では完結しない。昇格判断と同時に検討する
- 期限切れヒントの受理（SHOULD）を採る場合は、core `validateIdTokenHint` に leeway または exp 検証省略の注入点を足す core 変更として提案する
