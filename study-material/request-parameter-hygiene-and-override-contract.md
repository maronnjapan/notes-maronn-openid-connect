# リクエストパラメータの取り扱い契約（未知パラメータの無視 / グラント別余剰パラメータ / Request Object override 意味論）

## ステータス

🟢 Low / 未着手（**方針未決：人間の判断が必要なため現時点ではタスク化しない**）

## 1. このトピックで確認したいこと

リクエストパラメータの「受理・無視・拒否・上書き」の境界が、**明文化された契約とテストで固定されているか**を確認する。
具体的には次の 3 つの論点。いずれも「どう振る舞うべきか」に設計判断が残るため、本ファイルは判断材料の整理に留める。

1. **未知パラメータの無視契約**: Authorization / Token Endpoint で、未知の追加パラメータは仕様上「無視」すべき。
   現状は読み取らないため実質無視だが、`request_uri` / `registration` のような「明示拒否」パラメータとの
   区別が契約として明文化・テスト化されていない。
2. **グラント別の余剰パラメータ衛生**: Token Endpoint で `refresh_token` グラントに `code` / `code_verifier` /
   `redirect_uri` を混ぜる、あるいは `authorization_code` グラントに `refresh_token` を混ぜる、といった
   「他グラント用パラメータ」が黙って無視される。RFC 6749 は許容的だが、RFC 9700 の入力検証強化の観点で
   拒否すべきかどうかは判断が要る。
3. **Request Object の override 意味論**: signed Request Object 内の `scope` がクエリの `scope` を
   **無言で置換**する（等値チェック無し）一方、`response_type` / `client_id` はクエリ値と**一致必須**で検査される。
   この非対称（一方は match、一方は supersede）が意図どおりか、文書化されているか。

> 関連既存ファイル：
> - `tasks/done/p1-duplicate-parameter-rejection.md` は**重複**パラメータの拒否を扱う（本件の「未知/余剰」とは別）。
> - `tasks/done/p3-registration-param-explicit-rejection.md` / `study-material/request-object-rejection-and-discovery-honesty.md` は
>   特定の名前付きパラメータの明示拒否を扱う。
> - `tasks/done/p1-basic-op-request-object-by-value.md` は signed Request Object by value の**実装**を扱うが、
>   `scope` の supersede 意味論の契約・テストは扱っていない。
> 本ファイルは上記の隙間（**一般的な無視/余剰/override の契約とテスト**）に絞る。

## 2. 関連する仕様・基準

- **OpenID Connect Core 1.0 §3.1.2.1**:「OP は認識しないリクエストパラメータを **MUST ignore**」。
- **OAuth 2.1 §3.1 / RFC 6749 §3.1**: AS は認識しないパラメータを無視する。
- **OpenID Connect Core 1.0 §6.1（Passing a Request Object by Value）**:
  > the `response_type` and `client_id` parameters MUST be included using the OAuth 2.0 request syntax ... they MUST match
  - `response_type` / `client_id` のみ「クエリにも含め、Request Object 内と一致」を要求。
    `scope` 等その他は Request Object 値が優先されてよい（supersede 許容）。
- **RFC 9700（OAuth 2.0 Security Best Current Practice）§2 / §4**: 厳格な入力検証で
  パラメータ注入・リクエスト混同（request confusion）の攻撃面を縮小することを推奨。
- **OAuth 2.1 §3.2.2**: Token Endpoint のグラント別パラメータの定義。

## 3. 参照資料

- OpenID Connect Core 1.0 §3.1.2.1（unrecognized parameters MUST ignore）/ §6.1（Request Object, MUST match）:
  https://openid.net/specs/openid-connect-core-1_0.html
- OAuth 2.1 §3.1 / §3.2.2: https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1
- RFC 9700（OAuth 2.0 Security BCP）§2, §4: https://www.rfc-editor.org/rfc/rfc9700

## 4. 現在の実装確認

- **未知パラメータ**: `validateAuthorizationRequest`（`packages/core/src/authorization-request.ts`）は
  `effective` から名前付きフィールドのみ読み取る。未知キーは脱落＝実質無視（テストでの固定は見当たらない）。
  - 一方 `request_uri` 非対応の明示拒否、`registration` の `registration_not_supported` は実装済み（done）。
- **グラント別余剰パラメータ**: `packages/core/src/token-request.ts`
  - refresh 分岐（`:450-551` 付近）は `params.code` / `params.code_verifier` / `params.redirect_uri` を検査しない。
  - authorization_code 分岐（`:553-700` 付近）は `params.refresh_token` を検査しない。
  - `grant_type` で選ばれた分岐が、他グラント用パラメータを黙って無視する。
- **Request Object override**: `packages/core/src/authorization-request.ts`
  - `response_type`（`:769` 付近）/ `client_id`（`:777` 付近）はクエリ値と一致検査。
  - `scope` はクエリに存在必須（`:824-832` 付近）だが、`:834` 付近 `effective.scope ?? queryScopeValue` で
    Request Object 値が**無言で優先**される（等値チェック無し）。
    → クエリ `scope=openid` ＋ 署名オブジェクト `scope=openid admin` の場合、`admin` が採用される。
  - `REQUEST_OBJECT_OVERRIDE_KEYS`（`:957-973` 付近）には `code_challenge` / `code_challenge_method` も含まれ、
    `allowUnsigned`（conformance 互換、既定 false）時は **unsigned オブジェクト由来の PKCE 値**を採用しうる。

## 5. 現在の実装との差分

- **満たしていること**
  - 未知パラメータの無視は §3.1.2.1 に合致（ただしテスト固定なし）。
  - `response_type`/`client_id` の match は §6.1 に合致。`scope` supersede も §6.1 上許容範囲。
- **不足している可能性があること / 判断が必要なこと**
  - 「無視」と「明示拒否」の境界が契約として明文化・テスト化されていない。
  - グラント別余剰パラメータの扱い（無視のままか、`invalid_request` で拒否するか）が未決。
  - `scope` supersede が意図的か（署名オブジェクトがスコープを拡大できる権限モデルでよいか）が文書化されていない。
  - `allowUnsigned` 時に unsigned オブジェクト由来の PKCE を許す点の安全性注記が無い
    （既定 false なので実害は限定的だが、conformance 専用トグルである旨の明記が望ましい）。
- **セキュリティ**
  - RFC 9700 の観点では、余剰パラメータの拒否は request confusion の攻撃面を縮小する。
    一方、過度な拒否は相互運用性を損なう可能性があり、トレードオフがある。

## 6. 改善・追加を検討する理由

- **Fidelity / 説明責任**: 「無視/拒否/上書き」の境界を契約として固定すれば、利用者は生成コードを
  カスタムする際に安全な前提を持てる。
- **セキュリティ（任意・ハードニング）**: 余剰パラメータ拒否は RFC 9700 の推奨に沿うが、Basic OP 必須ではない。
- **導入のしやすさ／しにくさ**:
  - 未知パラメータ無視の**テスト固定**は容易（実装変更ほぼ不要）。
  - グラント別余剰パラメータの**拒否**は挙動変更を伴い、相互運用性への影響評価が必要 → 判断要。
  - `scope` supersede は「意図の確認」が先。仕様上は許容なので、変更ではなく**明文化＋テスト**が穏当。
- **実装しない場合のリスク**: 契約が暗黙のままで、リファクタ時に無視/拒否/上書きの境界が静かに変わりうる。

## 7. 実装方針の候補

判断材料の整理（最終判断は人間）。**本トピックは方針未決のためタスク化しない。**

- 未知パラメータ:
  - 方針A: 「未知は無視（MUST）、`request_uri`/`registration` は明示拒否」という 3 クラスを doc 化＋テスト固定。
- グラント別余剰パラメータ:
  - 方針A: 現状維持（無視）＋「余剰パラメータは無視する」と明文化。
  - 方針B: `invalid_request` で拒否（RFC 9700 寄り）。相互運用性への影響を評価した上で採用判断。
- Request Object override:
  - 方針A: `scope` supersede は意図的と確認し、「署名オブジェクトの値が優先」契約をテストで固定。
  - 方針B: クエリと署名オブジェクトの `scope` 不一致を警告／拒否（より厳格）。
  - 併せて `allowUnsigned` は conformance 専用・本番非推奨である旨と、unsigned 由来 PKCE の扱いを明記。

## 8. タスク案（方針確定後に着手）

- [ ] （要判断）未知/余剰/override の各論点について方針 A/B を選択
- [ ] 未知パラメータ無視と明示拒否の境界を回帰テストで固定（方針確定後）
- [ ] （採用時）グラント別余剰パラメータの拒否 or 明文化
- [ ] `scope` supersede 意味論の契約化とテスト、`allowUnsigned` の安全性注記
- [ ] 完了条件: 関連テストがパスし、契約がコメント/README に明文化される
