# クライアント登録メタデータ `request_object_signing_alg` の per-client 強制

## このトピックで確認したいこと

署名付き Request Object（`request` パラメータ）の JWS `alg` を、**OP 全体の許可リスト**だけでなく**そのクライアントが登録した `request_object_signing_alg`** に対して強制できているかを確認する。

現状は OP-wide の `supportedSigningAlgs`（既定 `['RS256']`）に含まれてさえいれば受理してしまい、あるクライアントが「このクライアントの Request Object は必ず ES256 で署名する」と登録していても、RS256 署名（あるいは設定次第で `alg=none`）の Request Object を受け入れてしまう余地がある。この非対称が Basic OP／相互運用上の問題になるかを整理する。

なお、本リポジトリでは Request Object 自体の対応可否・by-value 検証・JWS パース堅牢化は既に扱われている（下記「関連する既存ファイル」参照）。本ファイルはそれらと重複しない **「per-client alg ピン止め」という差分論点のみ** を扱う。

## 関連する仕様・基準

- **OpenID Connect Dynamic Client Registration 1.0 §2**（Client Metadata）
  `request_object_signing_alg`:
  > JWS `alg` algorithm [JWA] that MUST be used for signing Request Objects sent to the OP. **All Request Objects from this Client MUST be rejected, if not signed with this algorithm.**

  つまりクライアントが本メタデータを登録した場合、その `alg` に一致しない Request Object は **MUST reject**。これは OP-wide のサポート集合とは別の、クライアント単位の下限（ピン）である。

- **OpenID Connect Core 1.0 §6.1**（Request Object）／**RFC 9101（JAR）§6.3**
  Request Object の署名検証と `alg` 妥当性は OP の責務。§6.3 は "the `alg` value SHOULD be the default of `RS256`" としつつ、クライアントが特定の alg を登録している場合はそれに従う。

- **RFC 8725（JWT BCP）§3.1 / §3.2**
  受理する `alg` を明示的に固定（allow-list）し、`alg` の混同・ダウングレードを防ぐこと。per-client ピンはこの原則をクライアント単位で厳格化する位置づけ。

### 既存ファイルとの関係（重複回避）

以下は確認済みで、いずれも本論点（per-client ピン）を扱っていない。仕様の一般説明は各ファイルを参照し、本ファイルでは差分のみを述べる。

- `study-material/ext-jar-request-object-rfc9101.md` — JAR 全般。`request_object_signing_alg_values_supported`（OP-wide の Discovery 広告）に言及するが、クライアント登録 alg の強制には触れていない。
- `study-material/done/request-object-claim-validation-replay-and-audience.md` / `request-object-jws-parsing-hardening-parity.md` — クレーム検証・リプレイ・base64url/`crit`/外部鍵ヘッダの堅牢化。alg のクライアント別ピンは対象外。
- `study-material/request-object-rejection-and-discovery-honesty.md` — 非対応時の明示的拒否と Discovery 整合。
- `study-material/done/client-metadata-enforcement.md` — `grant_types` / `response_types` / `token_endpoint_auth_method` / per-client `scope` の強制のみで、暗号 alg メタデータは明示的に対象外。

## 参照資料

- OpenID Connect Dynamic Client Registration 1.0, §2 "Client Metadata"（`request_object_signing_alg` の定義と "MUST be rejected, if not signed with this algorithm"）
  https://openid.net/specs/openid-connect-registration-1_0.html#ClientMetadata
- OpenID Connect Core 1.0, §6 "Passing Request Parameters as JWTs"（§6.1 Request Object）
  https://openid.net/specs/openid-connect-core-1_0.html#JWTRequests
- RFC 9101 "The OAuth 2.0 Authorization Framework: JWT-Secured Authorization Request (JAR)", §6.3
  https://www.rfc-editor.org/rfc/rfc9101#section-6.3
- RFC 8725 "JSON Web Token Best Current Practices", §3.1（Perform Algorithm Verification）, §3.2（Use Appropriate Algorithms）
  https://www.rfc-editor.org/rfc/rfc8725

## 現在の実装確認

- `packages/core/src/request-object.ts` `parseRequestObject`
  - L103-106: `alg` の存在確認。
  - L108-117: `alg=none` は `options.allowUnsigned` のときのみ許可。
  - **L119-121: `if (!options.supportedSigningAlgs.includes(alg))` で拒否。ここが唯一の alg 検証であり、OP-wide のリストのみを見ている。**
  - L128-158: `kid` またはアルゴリズム互換な JWK で署名検証。
- `packages/core/src/authorization-request.ts` `parseRequestObjectClaims`（L702 付近）
  - `supportedSigningAlgs` を `options.requestObject?.supportedSigningAlgs ?? DEFAULT_REQUEST_OBJECT_SIGNING_ALGS`（= `['RS256']`）から供給。
  - `client` オブジェクト（`client.jwks` を含む）はスコープ内にあるが、**クライアント登録の request-object alg は参照していない**。
- クライアントモデルに該当フィールドが無い
  - `packages/cli/src/frameworks/hono/templates.ts` `RegisteredClient`（L433-437）は `offlineAccessAllowed` / `userinfoSignedResponseAlg` / `idTokenSignedResponseAlg` のみ。`requestObjectSigningAlg` は未定義。
  - `authorization-request.ts` の `ClientInfo` は `jwks` を持つが `requestObjectSigningAlg` を持たない。

## 現在の実装との差分

- **満たしていること**
  - OP-wide の allow-list による `alg` 固定（RFC 8725 §3.1 の最低限）は満たす。
  - `alg=none` の既定拒否、`kid`／alg 互換に基づく鍵選択は堅牢。
- **不足している可能性があること**
  - クライアントが `request_object_signing_alg` を登録していても、それに一致しない `alg` を（OP-wide リストに含まれる限り）受理してしまう。DCR §2 の "MUST be rejected" を満たさない。
- **相互運用性の観点**
  - 将来 ES256 等を OP-wide でサポートした場合、「このクライアントは ES256 固定」という登録を尊重できず、alg 混同耐性が下がる。
- **Basic OP として提供する上で確認すべきこと**
  - Basic OP certification profile 自体は Request Object（`request`/`request_uri`）を**必須要件としていない**（Basic は Authorization Code Flow / PKCE / RS256 ID Token / UserInfo / `prompt` が中核）。したがって本項目は **Basic OP の合否には直接影響しない拡張寄りの厳格化**である。ただし Request Object をサポートすると宣言する（`request_parameter_supported: true`）以上は、DCR §2 の per-client 強制を満たすほうが仕様忠実。

## 改善・追加を検討する理由

- **なぜ価値があるか**：本リポジトリはコンセプトとして Fidelity（仕様忠実）を掲げる。Request Object を「対応する」と広告するなら、DCR §2 の per-client MUST を満たすことが忠実性のシグナルになる。
- **Basic OP 必須か拡張か**：Basic OP の必須要件ではない。Request Object 対応（JAR 系）を進める場合の付随要件。JAR/PAR を将来サポートするときに一緒に入れると自然。
- **導入しやすさ**：`parseRequestObject` は既にクライアント単位の `jwks` を受け取っており、`supportedSigningAlgs` を「OP-wide ∩ クライアント登録 alg」に絞る形で最小差分で実装できる。クライアントモデルに `requestObjectSigningAlg` を追加するだけで接続点が揃う。
- **実装しない場合のリスク**：クライアントが厳格な alg を要求しても OP が緩く受理するため、alg ダウングレード余地が残る。ただし現状 OP-wide が `['RS256']` のみのため実害は限定的（RS256 以外を足したときに顕在化）。

## 実装方針の候補

> 最終判断は人間が行う。以下は判断材料。

1. **クライアント登録 alg で OP-wide リストを絞る（推奨・最小）**
   - `RegisteredClient` に `requestObjectSigningAlg?: string` を追加。
   - `parseRequestObjectClaims` で `effectiveSupportedAlgs = client.requestObjectSigningAlg ? [client.requestObjectSigningAlg] : opWideList` を計算し、`parseRequestObject` に渡す。
   - `alg=none` の扱い：クライアントが `request_object_signing_alg` を登録している場合は `none` を無条件で拒否（登録 alg と不一致）。
2. **`parseRequestObject` に `clientRequestObjectSigningAlg?` を明示引数で追加**
   - core の関数シグネチャに per-client ピンを一級市民として持たせ、CLI テンプレート側で配線。
3. **今は入れない（Request Object 対応が固まるまで保留）**
   - JAR/PAR のタスク（`ext-jar-request-object-rfc9101.md` 等）と合流するまで据え置き、Discovery の `request_object_signing_alg_values_supported` 広告と整合するタイミングで一括実装。

## タスク案

- [ ] `RegisteredClient`（および core の `ClientInfo` 相当）に `requestObjectSigningAlg` を追加し、resolver 契約に反映する。
- [ ] `parseRequestObjectClaims` / `parseRequestObject` で、クライアント登録 alg があるときは受理 alg を当該 1 値に絞る（`alg=none` も不一致として拒否）。
- [ ] 単体テスト：登録 `request_object_signing_alg=ES256` のクライアントが RS256 署名 Request Object を送ると `invalid_request_object`（相当）で拒否されること。登録一致（ES256）なら受理されること。登録なしなら従来どおり OP-wide リストで判定されること。
- [ ] `conformance.test.ts` 生成元（`packages/cli`）を更新し、per-client alg 強制の契約を CLI 生成 OP に反映する。
- [ ] Discovery の `request_object_signing_alg_values_supported`（`discovery-optional-metadata-fields.md` 参照）と広告内容が矛盾しないことを確認する。
- [ ] README／コメントに「Request Object をカスタマイズする利用者は per-client alg 強制の前提を壊しうる」旨を明記する。
