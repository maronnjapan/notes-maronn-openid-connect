# Experimental機能仕様書: OAuth 2.0 Rich Authorization Requests（RFC 9396）

- **機能名**: Rich Authorization Requests（RAR）
- **feature-id**: `rar`
- **ステータス**: `state.yaml` を参照
- **作成日**: 2026-10-21

## 概要

**Rich Authorization Requests（RAR）** は、`scope` では粒度が足りない認可要求を、`authorization_details` という JSON 配列パラメータで構造的に表現する OAuth 2.0 拡張である（RFC 9396）。
クライアントは「どの口座の、どの操作を、いくらまで」のような要求を型付きオブジェクトの配列で送り、OP はそれを検証し、同意画面に表示し、承認された内容をトークンレスポンスと introspection で資源サーバーへ伝える。

本機能は、認可コードフローに `authorization_details` の受理、検証、同意表示、保持、応答への反映を追加する。
型（`type`）ごとの意味解釈は OP 運用者が注入する型定義（validator と同意表示文の生成関数）に委ね、experimental パッケージは構造検証と配管だけを持つ。

## 採用理由（候補評価）

- **プロジェクト関連性**: README の差別化軸「Speed（最新仕様への追随）」に合致する。RFC 9396 は 2023 年公開の Proposed Standard で、FAPI 2.0 Security Profile（Final、2025-02）が「`scope` で表現しきれない認可には RAR の使用を推奨する」と非規範ノートで言及している（要件化ではない。`sources.md` 参照）。
- **Experimental隔離の妥当性**: 認可リクエストの追加パラメータとして独立しており、無効時は未知パラメータとして無視される現行挙動と一致する。
- **core無変更で実装できるか**: 可能。認可エンドポイントのパース処理は未知パラメータを保持し（`apps/hono/src/oidc-provider/endpoints/authorize/steps/parse-request.ts` の `collectUniqueParams` は重複キーのみ拒否）、core の `rejectUnsupportedRequestParams` が拒否するのは `request` / `request_uri` / `registration` だけである。保持と伝搬は feature の所有ブロックと副ストアで行う（「配置案」参照）。
- **CLIの `--enable` で提供できるか**: 可能。既存 9 機能と同じ registry 追加と feature ディレクトリで統合する。
- **一次資料の有無と成熟度**: RFC 9396（Proposed Standard、2023-05）。IANA レジストリ（パラメータ、エラーコード、メタデータ、claim）も整備済み。
- **セキュリティ影響**: 機微情報（金額、口座、識別子）を運ぶパラメータであり、ログ禁止、エラーへの非反映、未知 type の fail-closed を要件化する（「セキュリティ要件」参照）。
- **テスト可能性**: 純関数の単体テスト、CLI 生成テスト、デモ型定義を使った Playwright E2E で検証できる。
- **実装規模**: 中。experimental パッケージは純関数と in-memory ストアのみで、apps 側は所有ブロック 5 箇所と小さな base 変更 3 点に収まる。
- **将来coreへ昇格できるか**: 可能。構造検証と型 resolver の形は core の resolver 注入パターン（`study-material/ext-rich-authorization-requests-rfc9396.md` の方針C）へそのまま移せる。
- **既存機能との重複**: なし。実装済み 9 機能のどれとも重複せず、`tasks/T-019-dpop.md`（DPoP）とも領域が異なる。id-jag と token-exchange は `authorization_details` を明示拒否しており（ID-JAG 仕様に従う）、本機能と矛盾しない。
- **利用者の検証価値**: FAPI 2.0 / Open Banking 系の PoC で「scope を超える認可表現」を試す入口になる。

## Experimentalにする理由

- RFC 9396 は型の意味論を API ごとのプロファイルに委ねており、OP 単体では相互運用の形が固まらない。利用者の検証で型定義インタフェースの妥当性を確かめてから core 昇格を判断したい。
- 同意画面の表示、grant への紐付け、introspection への反映は OP の実装責任の範囲が広く、PoC での試行錯誤が前提になる。
- 保持は in-memory の副ストアで始める（PAR / CIBA と同じ割り切り）。

## 非目標（Non-goals）

- **トークンリクエストでの `authorization_details` 再指定（RFC 9396 §6）**: 受理しない。パラメータが来たら `invalid_authorization_details` で明示拒否する（黙殺すると narrowing されたとクライアントに誤認させるため）。§6.1 の型依存のサブセット比較も実装しない。
- **enriched authorization_details（§7.1）**: AS 側で details を拡充しない。承認された内容をそのまま返す。
- **JWT アクセストークンへの `authorization_details` claim（§9.1、RECOMMENDED）**: v1 では introspection だけで資源サーバーへ伝える。AT への claim 追加は base のトークン発行ステップへ踏み込むため、昇格時に検討する。
- **認可コードフロー以外への適用（§3 の device / CIBA への拡張適用）**: device-authorization-grant と ciba の各エンドポイントは本機能を関知せず、従来どおりパラメータを無視する。この挙動は利用者向け Docs の既知の制約に明記する。
- **部分同意**: 同意は要求された details 全体への承認か拒否かの二択とする（§3 の Note はサブセット承認を MAY としている）。
- **クライアントメタデータ `authorization_details_types`（§10）によるクライアント単位の型制限**: 静的クライアント設定にもフィールドを追加しない。dynamic-client-registration との連携も行わない。
- **ID Token への details の反映**: RFC 9396 に要求がなく、行わない。
- **details の資源サーバー別フィルタリング（§9.2 の "potentially filtered"）**: v1 は grant に紐づく details をそのまま introspection へ返す。

## ユースケース / 想定利用者

- 送金額や口座を特定した認可（`payment_initiation` 型など）を試す金融系 PoC 開発者。
- `scope` の荒い粒度を細分化したい API 提供者が、型定義の設計（必須フィールド、同意文言）を検証する用途。
- FAPI 2.0 の推奨構成（PAR + RAR）を組み合わせて確かめる利用者。本機能は PAR と併用できる（PAR のパラメータ検証は未知パラメータを保持する）。

## 関連標準仕様

- RFC 9396: OAuth 2.0 Rich Authorization Requests（Normative）
- RFC 6749 / OIDC Core 1.0（認可コードフロー、エラー応答の土台）
- RFC 7662（introspection への member 追加。§9.2）
- RFC 8414 / OIDC Discovery 1.0（`authorization_details_types_supported` の広告）
- FAPI 2.0 Security Profile（Informative。RAR 使用の推奨文脈）

## プロトコルフロー

```text
Client                                   OP                                    User
  │ GET /authorize?...&authorization_details=[...]                              │
  │────────────────────────────────────▶│                                       │
  │                                     │ 1. パース（未知パラメータとして保持）  │
  │                                     │ 2. RAR 検証（構造 + 型定義 validator） │
  │                                     │    不正 → invalid_authorization_details│
  │                                     │    prompt=none → consent_required      │
  │                                     │ 3. トランザクションへ保持              │
  │                                     │ 4. ログイン                            │
  │                                     │──────────────────────────────────────▶│
  │                                     │ 5. 同意画面に scope と details を併記  │
  │                                     │◀──────────────承認────────────────────│
  │                                     │ 6. grantId へ details を紐付け         │
  │◀─────────── code ──────────────────│                                        │
  │ POST /token (authorization_code)    │                                        │
  │────────────────────────────────────▶│                                        │
  │◀── 200 {..., authorization_details} │ 7. §7: 応答に details を含める（MUST） │
  │ POST /token (refresh_token)         │                                        │
  │────────────────────────────────────▶│ 8. 同じ grant の details を引き継ぐ    │
  │◀── 200 {..., authorization_details} │                                        │
  │ POST /introspect（RS から）          │ 9. §9.2: top-level member で返す       │
```

`authorization_details` が無いリクエストは、本機能の有効・無効にかかわらず従来とまったく同じに処理される。

## 入出力

### 認可リクエスト

- パラメータ名: `authorization_details`（`application/x-www-form-urlencoded` でシリアライズされた JSON 配列。§3）。
- 受理経路と優先順位:
  1. **Request Object（request-object 機能有効時）**: core の `mergeRequestObjectParams` は固定キーしか `effectiveParams` へ写さないため（`packages/core/src/authorization-request.ts` の `REQUEST_OBJECT_OVERRIDE_KEYS` に `authorization_details` は無い）、`requestObjectClaims` から読む。Request Object 内に存在する場合はクエリ値より優先する（OIDC Core 1.0 §6.1 の supersede 規則に合わせる）。
  2. **PAR（par 機能有効時）**: PAR のパラメータ検証は未知パラメータを保持するため、`/par` へ送られた値が `resolve-pushed-request` 後の `params` に現れる。追加の配線は不要。
  3. **クエリパラメータ**: `params['authorization_details']`。
- `scope` との併存: 可能（§3.1）。`openid` scope の必須要件（core の `validateAuthorizationScope`）は変わらない。同意画面では scope と details を併記する（§3.1 の merged set の MUST）。

### バリデーション（実施順）

| # | 検査 | 違反時 |
|---|---|---|
| 1 | パラメータの UTF-8 バイト長が `maxAuthorizationDetailsBytes` 以下（TextEncoder 基準） | `invalid_authorization_details` |
| 2 | JSON としてパースでき、値が配列である | `invalid_authorization_details` |
| 3 | 配列が空でない、要素数が `maxAuthorizationDetailsEntries` 以下 | `invalid_authorization_details` |
| 4 | 各要素がプレーンなオブジェクトである（配列、文字列、null などを拒否） | `invalid_authorization_details` |
| 5 | 各要素の `type` が非空文字列である（§2 REQUIRED） | `invalid_authorization_details` |
| 6 | 共通フィールドの型（§2.2）: `locations` / `actions` / `datatypes` / `privileges` は文字列配列、`identifier` は文字列。存在する場合のみ検査 | `invalid_authorization_details` |
| 7 | `type` が設定済み型定義（`rarTypes`）に含まれる（§5 の未知 type MUST refuse） | `invalid_authorization_details` |
| 8 | 型定義の `validate(detail)` が通る（型固有の必須フィールド、値域） | `invalid_authorization_details` |
| 9 | `prompt` に `none` が含まれない（details には新規同意が必要という本機能のポリシー） | `consent_required` |

- 同じ `type` の要素が複数あってよい（§2 MAY）。
- エラーは `resolve-redirect-uri` 後に投げるため、通常の認可エラー応答としてクライアントへリダイレクトされる。`error_description` は固定 ASCII 文言とし、details の値を反映しない。
- 検査 9 を通過した場合、`prompt` に `consent` を加えて以降のステップへ渡す。これにより prompt=none 以外のすべての経路（SSO の同意スキップを含む）が同意画面を必ず経由する。

### 同意画面

- 要求中の details を、型定義の `describe(detail)` が返す表示行（プレーン文字列の配列）として scope 一覧と併記する。
- 表示文字列のエスケープは view 層（JSX の自動エスケープ）に委ね、`describe` はプレーン文字列だけを返す契約とする。
- ユーザーが承認すると、要求された details 全体が grant に紐づく。拒否は従来どおり `access_denied`。

### トークンレスポンス（authorization_code / refresh_token grant）

- 成功応答の JSON に `authorization_details`（承認された配列そのまま）を含める（§7 MUST）。
- refresh_token grant では、同じ grant に紐づく details を変更せず引き継いで返す。
- トークンリクエストに `authorization_details` パラメータが含まれていた場合、grant の種別を問わず `invalid_authorization_details` で拒否する（非目標の明示拒否。エラー形式は RFC 6749 §5.2 の 400 応答）。
- details を持たない grant のトークン応答は一切変更しない。

### Introspection（introspection 機能有効時）

- `active: true` の応答に `authorization_details` を top-level member として含める（§9.2 MUST の構造要件）。
- jwt-introspection-response 併用時は、署名対象オブジェクトに同 member が含まれたうえで署名される（既存の `restrictIntrospectionResponseToCaller` は member を素通しする）。
- details を持たないトークンの応答は変更しない。

### Discovery

- `authorization_details_types_supported`: 設定済み型定義の `type` 値の配列（§10）。型定義が空のときは member 自体を出さない（広告しない OP に RAR を送るべきでないという §10 の前提に合わせる）。

## 公開API案（`@maronn-openid-connect/experimental/rar`）

```typescript
/** RFC 9396 §2 の authorization details オブジェクト。型固有フィールドは不透明に保持する。 */
export interface AuthorizationDetail {
  readonly type: string;
  readonly locations?: readonly string[];
  readonly actions?: readonly string[];
  readonly datatypes?: readonly string[];
  readonly identifier?: string;
  readonly privileges?: readonly string[];
  readonly [key: string]: unknown;
}

/** OP 運用者が type ごとに注入する定義。 */
export interface AuthorizationDetailTypeDefinition {
  readonly type: string;
  /** 型固有の検証。違反時は RarError('invalid_authorization_details') を投げる。 */
  validate(detail: AuthorizationDetail): void;
  /** 同意画面の表示行（プレーン文字列）。すべての安全上重要なフィールドを文言に含める責任を持つ。 */
  describe(detail: AuthorizationDetail): readonly string[];
}

/** §5 のエラーコードを持つ例外。message は固定 ASCII 文言のみ。 */
export class RarError extends Error {
  readonly code: 'invalid_authorization_details';
}

/** 検査 1〜6（構造検証）。生の文字列から AuthorizationDetail[] を得る。 */
export function parseAuthorizationDetailsParam(
  raw: string,
  limits: { maxBytes: number; maxEntries: number },
): AuthorizationDetail[];

/** 検査 7〜8（型定義との突き合わせ）。未知 type は fail-closed。 */
export function validateAuthorizationDetails(
  details: readonly AuthorizationDetail[],
  types: readonly AuthorizationDetailTypeDefinition[],
): void;

/** 同意画面向けの表示行を組み立てる（type 見出し + describe の行）。 */
export function describeAuthorizationDetails(
  details: readonly AuthorizationDetail[],
  types: readonly AuthorizationDetailTypeDefinition[],
): readonly string[];

/** トランザクション単位の一時保持と grant 単位の保持。PAR / CIBA のストアと同じ in-memory 契約。 */
export interface RarDetailsStore {
  set(key: string, details: readonly AuthorizationDetail[], expiresAt?: number): Promise<void>;
  get(key: string): Promise<readonly AuthorizationDetail[] | undefined>;
  delete(key: string): Promise<void>;
}
export function createInMemoryRarDetailsStore(): RarDetailsStore;

export const AUTHORIZATION_DETAILS_PARAM = 'authorization_details';
```

- すべて純関数とプレーンな in-memory ストアで、Web 標準 API（TextEncoder、JSON）だけを使う。
- details オブジェクトは不透明な JSON 値として扱い、他のオブジェクトへ深いマージをしない（`__proto__` キーを持つ入力でも、JSON.parse が作る own property のまま保持と転記だけを行う）。

## CLIオプション案

- `maronn-oidc generate <framework> --enable rar` でのみ生成する。デフォルト無効。
- `packages/cli/src/registry.ts` の `FEATURE_REGISTRY` と `EXPERIMENTAL_FEATURES` の末尾へ追加する（`id: 'rar'`、`tier: 'experimental'`、`requires: []`、summary は "OAuth 2.0 Rich Authorization Requests (RFC 9396)"）。
- `OidcFeatureConfig` のキー、`EXPERIMENTAL_FEATURE_KEYS`、`DEFAULT_FEATURES`（`false`）、install コマンド案内（`withFeaturePackages` 経由で選択時のみ `@maronn-openid-connect/experimental` を追加）も既存機能と同型に揃える。
- introspection への反映ブロックは introspection 機能のパイプライン内に置くため、introspection 無効時は生成されない。`requires` には introspection を入れない（RAR 単体で成立するため）。

## 設定値とデフォルト

生成コードの feature ディレクトリに `config.ts`（ciba の `cibaConfig` と同型の fail-fast 検査つき）を置く。

| 設定 | 既定値 | 範囲 | 意味 |
|---|---|---|---|
| `maxAuthorizationDetailsBytes` | 16384 | 1024〜65536 | パラメータの UTF-8 バイト長上限（DoS 対策。§11.4 は長大なリクエストに PAR の利用を示唆） |
| `maxAuthorizationDetailsEntries` | 16 | 1〜64 | 配列要素数の上限 |

型定義は `ProviderConfig` の拡張（`declare module`。google-login の config 拡張と同じパターン）として注入する。

```typescript
declare module '../../config.js' {
  interface ProviderConfig {
    /** EXPERIMENTAL (RFC 9396): 受理する authorization details 型。空なら RAR リクエストはすべて拒否される。 */
    rarTypes?: readonly AuthorizationDetailTypeDefinition[];
  }
}
```

- 既定は空配列。型定義を注入しない限り、`authorization_details` 付きリクエストはすべて `invalid_authorization_details` になる（fail-closed）。
- discovery フックは `(issuer, config)` を受けるため、`config.rarTypes` から `authorization_details_types_supported` を広告できる。

## バリデーション / エラー処理

- エラーコードは認可エンドポイントで `invalid_authorization_details`（`AuthorizationError` として投げ、リクエストの response mode で返す）と `consent_required`、トークンエンドポイントで `invalid_authorization_details`（`TokenEndpointError`、400）を使う。
- `error_description` は固定 ASCII 文言とし、details の内容（type 名を含む）をエラーへ反映しない。どの要素が落ちたかはクライアント側で再現可能であり、反映による情報価値よりログ・リファラ経由の漏えい面を減らす方を取る。
- 型定義の `validate` が投げた `RarError` 以外の例外は `server_error` として既存のエラーハンドリングに委ねる（握りつぶさない）。

## セキュリティ要件

- **fail-closed**: 未知 type、構造違反、上限超過はすべて拒否する（§5 MUST）。型定義が空なら全拒否。
- **ログ禁止**: `authorization_details` の内容（金額、口座、識別子などの機微情報。§13）をログへ出さない。エラーメッセージにも反映しない。
- **同意の明示**: details を伴うリクエストは常に同意画面を経由する。prompt=none は `consent_required`。SSO の同意スキップ（`reuse-session` の `consentResolver.hasConsent` 経路）は scope 単位の記録しか持たず details を知らないため、`prompt` への `consent` 付与で迂回を塞ぐ。
- **表示の安全**: `describe` はプレーン文字列を返し、HTML を組み立てない。エスケープは view 層の既存機構に委ねる。
- **インジェクション対策（§12 MUST sanitize）**: details は不透明な JSON 値として保持・転記のみ行い、深いマージ、`eval` 相当、動的キーアクセスによる書き込みをしない。
- **DoS**: バイト長と要素数の上限。上限値は応答に反映しない。
- **改ざん（§12）**: パラメータ自体の完全性保護は request object / PAR の既存機構の併用に委ね、本機能では追加しない（Docs に記載）。
- **トランザクション保持の寿命**: transactionId 紐付けの details は認可トランザクションの TTL と同じ寿命で破棄する。

## プライバシー考慮

- details は PII を含みうるため、保存は必要な期間（トランザクション TTL、grant の生存期間）に限定し、ログへ出さない。
- introspection は認証済みの資源サーバーにだけ応答する既存の契約に乗る。資源サーバー別のフィルタリング（§9.2 の filtered）は行わないことを Docs の既知の制約へ記載する。

## 配置案 / CLI生成コードからの利用方法 / coreとの境界

### packages/experimental/src/rar/

```text
packages/experimental/src/rar/
  index.ts                       # Experimental 警告つきヘッダと再エクスポート
  authorization-details.ts       # parse / validate / describe と型定義
  authorization-details.test.ts
  store.ts                       # createInMemoryRarDetailsStore
  store.test.ts
```

`package.json` の `exports` へ `"./rar"` を追加する。ルート `.` からの再エクスポートは追加しない。

### apps/hono/src/oidc-provider/features/rar/

- `feature.ts`: `discovery`（`authorization_details_types_supported`）と `context`（`rarTransactionStore` / `rarGrantStore`）。
- `config.ts`: 上限値と `ProviderConfig` 拡張。
- `steps/validate-authorization-details.ts`: authorize パイプラインの `[validate-authorization-details]`（`validate-request` 後、`create-transaction` 前）。検証、prompt 制御、`authorizationDetails` の produce。`requestObjectClaims` は request-object 無効時 `undefined` になるため optional として consume する。
- `steps/record-authorization-details.ts`: `[record-authorization-details]`（`create-transaction` 後）。transactionId へ details を保持。
- `steps/describe-authorization-details.ts`: consent の `prepareConsent` 内ブロック。表示行を produce。
- `steps/record-granted-details.ts`: `submitConsent` の `[issue-authorization-code]` 後。`authCodeData.grantId` へ details を紐付け、transactionId 側を破棄。
- `steps/append-token-response-details.ts`: token パイプラインの `[build-token-response]` と `[respond]` の間。`validatedRequest.grantId` から details を引き、`tokenResponse` を再構築する。トークンリクエストの `authorization_details` 拒否もここで行う。
- `steps/append-introspection-details.ts`: introspection パイプラインの `[build-response]` と `[sign-response]` の間（`after` / `before` を明示）。

apps/nextjs は route group `(rar)` を持たず、`_oidc-provider/features/rar/` と各 route.ts への同名の所有ブロックで同じ流れを実装する（authorize / consent decision / token / introspect の各 route）。nextjs の `context` はストアを差し替えられないため、ストアは feature ディレクトリのモジュールシングルトンとして持つ（par の nextjs 配線と同型）。

### 必要となる base 変更（packages/core は変更しない）

いずれも rar 無効時の生成物の挙動を変えない形で行い、既存テストと conformance で裏を取る。

1. **同意画面の表示項目**: `ConsentScreen`（hono `endpoints/consent/screen.ts`）と `ConsentPageParams`（`views.tsx`）、nextjs の consent ページに optional な `authorizationDetails?: readonly string[]` を追加し、存在時のみ一覧表示する。値は rar の所有ブロックが produce し、無効時は generator の仕組みで `undefined` になる。
2. **トークン応答の可変化**: hono `endpoints/token/pipeline.ts` の `const tokenResponse` を `let` にする（PAR が `let params` を再代入する既存パターンと同型）。nextjs の token route も同様。
3. **introspection 応答の可変化**: `features/introspection/endpoints/introspection/pipeline.ts` の `const introspection` を `let` にする。nextjs の introspect route も同様。

### 依存方向

```text
packages/core ──X──> packages/experimental（import禁止・coreの必須機能にしない）
packages/cli  ─────> @maronn-openid-connect/experimental（許可・生成コードの依存として明示）
@maronn-openid-connect/experimental ─────> @maronn-openid-connect/core（peerDependencies として許可）
```

- apps の base は feature ディレクトリと experimental パッケージを import しない（`lint-import-boundaries` の既存規則のまま）。rar のコードは feature ディレクトリと所有ブロックにのみ置く。
- 他の experimental 機能への `requires` は無し。introspection への反映は introspection パイプライン内の所有ブロックで実現し、rar 単体でも成立する。

## テスト計画

### 単体テスト（`packages/experimental/src/rar/*.test.ts`、t_wada 流 TDD）

正常系:

- 単一要素、複数要素、同一 type の重複要素のパース
- 共通フィールドが揃った要素の検証通過
- `describe` の表示行の組み立て（要素順を固定して `toEqual`）
- ストアの set / get / delete と expiresAt 経過後の get

異常系・境界値:

- 非 JSON、JSON だが配列でない、空配列、要素がオブジェクトでない（文字列、配列、null）
- `type` 欠落、空文字列、非文字列
- 共通フィールドの型違反（`locations` が文字列、`identifier` が配列、配列内に非文字列）
- 未知 type（型定義が空、型定義にない type）
- 型定義 `validate` の失敗が `RarError` のまま伝わること
- バイト長上限の境界（多バイト文字を含む UTF-8 基準の on / over）
- 要素数上限の境界
- `__proto__` / `constructor` キーを持つ要素が own property のまま保持され、プロトタイプを汚染しないこと
- エラー message が固定 ASCII 文言で、入力値を含まないこと

### apps の単体テスト（steps の隣に配置）

- validate ステップ: 検証順序、prompt=none で `consent_required`、通過時に `prompt` へ `consent` が加わること、request object 値の優先、パラメータ無しで何もしないこと
- token ステップ: grantId に details があるとき応答へ含まれ、無いとき応答が不変であること、トークンリクエストの `authorization_details` 拒否
- introspection ステップ: member 追加と不変ケース

### CLIテスト（`packages/cli/src/__tests__`）

- `--enable rar` のオプション解析と registry の整合（features.test.ts のキー列挙に追加）
- 選択時: feature ディレクトリが生成され、import が `@maronn-openid-connect/experimental/rar` を指すこと
- 未選択時: rar のブロック、ステップ、feature ディレクトリが生成されず、install コマンド案内に experimental パッケージが現れないこと（他の experimental 機能も未選択の場合）
- 生成後の型検査と build の通過

### E2E（`tests/e2e/specs/rar.spec.ts`、Playwright）

apps/hono と apps/nextjs の開発サーバーにデモ型定義（U2 参照）を登録して検証する。

- 正常系: `authorization_details` 付き認可リクエスト → 同意画面に details の表示行が出る → 承認 → トークン応答に `authorization_details` が入る → refresh で引き継がれる → introspection に member が出る
- discovery に `authorization_details_types_supported` が出る
- 異常系: 未知 type がエラーリダイレクト（`error=invalid_authorization_details`）で返る、prompt=none が `consent_required` で返る
- 無効時（discovery の member 欠如で `test.skip`）: パラメータ付きリクエストが従来どおり details 無しで完走する

## ドキュメント要件

- **利用者向け**: `docs/library-document/src/content/docs/experimental/rar.md` を追加し、index の機能一覧を更新する。概要、Experimental 警告、対応仕様、ユースケース、`--enable rar` とインストール、型定義の書き方（validate / describe の契約と例）、フロー、エラー処理、セキュリティ注意（ログ禁止、完全性保護は PAR / request object 併用）、既知の制約（in-memory 保持、token request での再指定不可、device / CIBA 非対応、資源サーバー別フィルタ無し）、core 機能との違い、トラブルシューティング、参考資料。
- **実装解説（必須）**: notes リポジトリの `implementation-guides/experimental/` に日本語版と英語版を作成する（`.notes/CLAUDE.md` の規約に従い、全ファイル掲載）。

## Changeset要件

`packages/experimental/src` の変更に changeset を手書きしない。main への push 後に CI が patch の changeset を自動生成する（`RELEASE.md` の「experimental の自動 publish」）。

## 実装順序

1. experimental パッケージの純関数とストア（TDD）
2. apps/hono の feature ディレクトリと所有ブロック、base 変更 3 点（同意表示、token / introspection の可変化）
3. apps/nextjs の同等実装
4. CLI registry とテスト
5. E2E スペックとデモ型定義
6. 利用者向け Docs と実装解説（日英）

## 完了条件

- 単体、CLI、E2E の全テストがパスし、`pnpm run lint`（import 境界検査を含む）と型検査、build が通る。
- `--enable rar` なしの生成物の挙動が従来と変わらない（既存テストと conformance がグリーンのまま）。
- `authorization_details` 付きの認可コードフローが E2E で完走し、トークン応答と introspection に details が現れる。
- core から experimental への import が無い。
- 実装解説（日英）が notes リポジトリへコミットされている。

## 未解決事項

- **U1: grant 紐付けストアの掃除**: `rarGrantStore` のエントリは grant の失効（refresh token の revoke、ローテーション連鎖の終端）を自動では知れない。容量上限つき in-memory（最古破棄）とするか、TTL を持たせるか。どちらも fail-closed（details が消えたら応答に含めない）で、セキュリティ上の懸念はないが、§7 の MUST との兼ね合いで Review 2 で確定する。
- **U2: E2E 用デモ型定義の形**: apps の開発サーバー（`apps/hono/src/server.ts`、`apps/nextjs/src/instrumentation.ts`）へ登録するデモ型の名前とフィールド。RFC 9396 §2 の例（`payment_initiation`）に寄せるか、リポジトリ固有の名前空間にするかを Review 3 までに確定する。
- **U3: `requestObjectClaims` 内の値の型**: request object の claim として届く `authorization_details` が JSON 配列（パース済み）か文字列かを実装で確認し、パース関数の入口を確定する（Review 2 で実測する）。

## 将来の昇格考慮

- 型定義インタフェース（validate / describe）は core の resolver 注入パターンへそのまま移せる。昇格時は `ValidatedAuthorizationRequest` / `AuthTransaction` / `AuthorizationCodeData` / トークン情報への `authorizationDetails` フィールド追加（`study-material/ext-rich-authorization-requests-rfc9396.md` の方針C）が本筋になり、副ストアは不要になる。
- JWT アクセストークンへの claim 追加（§9.1 RECOMMENDED）と資源サーバー別フィルタリングは昇格時に再評価する。
- token request での narrowing（§6）をサポートする場合、型依存の比較関数を型定義インタフェースへ追加する形が考えられる。
