# Conformance 互換フラグ（PKCE 省略許容 / 署名なし Request Object 許容）の安全側ガード

## 1. タイトル

`allowNonPkceAuthorizationCodeFlow` と `allowUnsignedRequestObject` は
OIDF Conformance Suite との互換のためにセキュリティ要件を意図的に緩めるフラグである。
環境変数 1 つで有効化でき、**有効になっていることがどこにも可視化されない**ため、
検証後に消し忘れたまま稼働し続けるリスクがある。その検出・可視化・記録の仕組みを検討する。

## 2. このトピックで確認したいこと

- 2 つの互換フラグが実際に何を緩めるのか、緩和範囲は最小に絞られているか
- フラグが有効なとき、Discovery メタデータの広告内容と実挙動が整合しているか
- 有効化されていることを運用者・利用者が気づける手段（起動ログ・ヘルスエンドポイント・
  conformance テスト）が必要か
- 「Conformance を通すための構成」と「安全な既定構成」が同一デプロイに同居してよいか

> 既存ファイルで扱っている内容は繰り返さない:
> - PKCE 必須化そのものの根拠と `code_challenge` 形式検証:
>   `study-material/done/pkce-code-challenge-format-validation.md` /
>   `tasks/done/p1-basic-op-pkce-compatibility.md`
> - Request Object の署名検証・クレーム検証・JWS パース堅牢化:
>   `study-material/done/request-object-claim-validation-replay-and-audience.md` /
>   `study-material/done/request-object-jws-parsing-hardening-parity.md` /
>   `study-material/inbound-jws-verification-crit-and-alg-binding.md`
> - `alg=none` 防御と受け入れアルゴリズムのポリシー:
>   `study-material/jws-algorithm-policy-and-alg-none-defense.md`
> - Discovery と実装の整合性ガード:
>   `study-material/done/discovery-metadata-basic-op-self-consistency-guard.md` /
>   `study-material/request-object-rejection-and-discovery-honesty.md`
> - Conformance 実行手順そのもの: `study-material/basic-op-conformance-verification-plan.md`
> - ヘルス／レディネスエンドポイント: `study-material/operational-health-readiness-endpoints.md`
>
> 本ファイルは「**互換フラグという運用上の状態をどう管理・可視化するか**」に限定する。
> 各フラグが緩める仕様要件そのものの議論は上記既存ファイルの担当。

## 3. 関連する仕様・基準（本トピック固有の差分）

### 3.1 `allowNonPkceAuthorizationCodeFlow` が緩める要件

- **OAuth 2.1 §4.1.1 / §7.5**: authorization code flow を使うクライアントは
  PKCE（`code_challenge` / `code_challenge_method`）を**必ず**使う。
  `S256` のサポートは必須で、`plain` の利用条件は厳しく制限される。
- **RFC 9700（OAuth 2.0 Security BCP）§2.1.1**: 認可コード横取り（authorization code injection）への
  対策として PKCE または nonce を要求する。
- 本リポジトリは **`S256` のみ**を受理し、`plain` は常に拒否する（フラグの有無に関わらず）。

一方 OIDF の Basic OP 静的クライアントテストは、PKCE 導入前から存在する
Confidential Client の authorization code flow を前提としたモジュールを含むため、
PKCE を必須にしたままでは一部モジュールが通らない。これがフラグの存在理由である。

core 側の緩和範囲は次のように**最小に絞られている**（`validateAuthorizationCodePkce`）:

```ts
const pkceOmitted = codeChallenge === undefined && codeChallengeMethod === undefined;
if (pkceOmitted && options.allowNonPkceAuthorizationCodeFlow === true
    && client.clientType === 'confidential') {
  return {};   // 完全省略かつ confidential のときだけ許容
}
return validateCodeChallenge(codeChallenge, codeChallengeMethod, redirectUri, state);
```

- public client は対象外（常に PKCE 必須）
- 片方だけ指定・不正値・`plain` はフラグに関係なく拒否
- したがって「PKCE をバイパスできる攻撃」は成立しにくいが、
  **confidential client の認可コード横取りに対する防御が 1 段落ちる**ことは事実。

### 3.2 `allowUnsignedRequestObject` が緩める要件

- **OIDC Core 1.0 §6.1**: Request Object は署名付き（JWS）であることでリクエストパラメータの
  完全性を保証する。`alg=none` の Request Object は署名による保護が無い。
- **RFC 8725（JWT BCP）§3.1 / §3.2**: アルゴリズム検証を必ず行い、
  `none` を無条件に受け入れないこと。
- **RFC 9101（JAR）**: `require_signed_request_object` 等のメタデータで署名必須を強制できる。

本リポジトリは既定で署名必須、フラグ有効時のみ `alg=none` を受理し、
そのとき署名部が空文字であることを検証する（`parseRequestObject`）。
また **Discovery の `request_object_signing_alg_values_supported` に `"none"` を追加する**ため、
「広告と実挙動の不整合」は生じていない（＝ Discovery の正直性は保たれている）。

`alg=none` を受理すると、Request Object の中身（`redirect_uri` / `scope` / `claims` 等）が
経路上で改ざんされても検知できない。ただし `redirect_uri` は登録済み URI との照合、
`response_type` / `client_id` はクエリ側との一致検証（`validateRequestObjectConsistency`）を通るため、
被害範囲は「署名で守るべき残りのパラメータの完全性」に限定される。

### 3.3 「安全でない既定を持たない」という原則

- **RFC 9700 §2**: セキュリティ上の推奨は「デフォルトで安全（secure by default）」であること。
- 本リポジトリはどちらのフラグも**既定 false**であり、この原則は満たしている。
  残る論点は「有効化した状態が、意図せず継続しないようにする仕組み」である。

## 4. 参照資料

- OAuth 2.1（draft-ietf-oauth-v2-1）§4.1.1 / §7.5 — https://datatracker.ietf.org/doc/draft-ietf-oauth-v2-1/
  （authorization code flow における PKCE 必須）
- RFC 9700 OAuth 2.0 Security Best Current Practice §2.1.1 —
  https://www.rfc-editor.org/rfc/rfc9700.html
  （認可コード横取りへの PKCE / nonce による対策）
- OpenID Connect Core 1.0 §6.1 Passing a Request Object by Value —
  https://openid.net/specs/openid-connect-core-1_0.html#RequestObject
- RFC 8725 JSON Web Token Best Current Practices §3.1 / §3.2 —
  https://www.rfc-editor.org/rfc/rfc8725#section-3
  （アルゴリズム検証と `none` の扱い）
- RFC 9101 JWT-Secured Authorization Request (JAR) — https://www.rfc-editor.org/rfc/rfc9101.html
- OpenID Connect Discovery 1.0 §3（`request_object_signing_alg_values_supported`）—
  https://openid.net/specs/openid-connect-discovery-1_0.html#ProviderMetadata
- 本リポジトリ内: `study-material/basic-op-conformance-verification-plan.md`（Conformance 実行手順）

## 5. 現在の実装確認

### 5.1 フラグの定義（生成物 `config.ts` / CLI テンプレート）

```ts
export interface ProviderConfig {
  // ...
  allowNonPkceAuthorizationCodeFlow: boolean;   // 既定 false
  allowUnsignedRequestObject: boolean;          // 既定 false
}
```

JSDoc には「Conformance 互換モード」であること、`false` が既定であることが明記されている。

### 5.2 環境変数からの有効化（全サンプル共通）

| サンプル | 該当箇所 |
|---|---|
| hono-cloudflare | `samples/hono-cloudflare/src/app.ts:21-22, 50-52`（`bindings.OIDC_ALLOW_* === '1'`） |
| express-flyio | `samples/express-flyio/src/app.ts:30, 37`（`process.env.OIDC_ALLOW_* === '1'`） |
| fastify-flyio | `samples/fastify-flyio/src/app.ts:30, 37` |
| nextjs-vercel | `samples/nextjs-vercel/src/app/_oidc-provider/runtime.ts`（`readEnv('OIDC_ALLOW_*') === '1'`） |

`'1'` という厳密比較なので誤入力で有効化される事故は起きにくい。

### 5.3 core 側の適用箇所

- `packages/core/src/authorization-request.ts`
  - `validateAuthorizationCodePkce(effectiveParams, client, redirectUri, state, { allowNonPkceAuthorizationCodeFlow })`
  - `resolveRequestObjectParams(params, client, { allowUnsigned })`
- `packages/core/src/request-object.ts`
  - `parseRequestObject` の `alg === 'none'` 分岐（`allowUnsigned` が false なら `RequestObjectError`）

### 5.4 Discovery への反映（生成物 `routes/discovery.ts`）

```ts
requestObjectSigningAlgValuesSupported: config.allowUnsignedRequestObject
  ? ['RS256', 'none']
  : ['RS256'],
```

`allowUnsignedRequestObject` は Discovery に反映される。
一方 `allowNonPkceAuthorizationCodeFlow` は `code_challenge_methods_supported: ['S256']` を変えない
（S256 をサポートしていること自体は真なので、これは不整合ではない）。

### 5.5 可視化の状況

- 起動時ログ: **無し**（フラグが有効でも何も出力されない）
- `/health`: `{ status: 'ok' }` のみ（`samples/hono-cloudflare/src/app.ts:39`）
- Discovery: `allowUnsignedRequestObject` のみ間接的に読み取れる
  （`request_object_signing_alg_values_supported` に `"none"` が出る）
- `conformance.test.ts`: フラグ既定値（false）での挙動は検証しているが、
  「フラグが有効な構成」を明示的に区別するテストは無い

## 6. 現在の実装との差分

満たしていること:

- ✅ どちらのフラグも既定 `false`（secure by default）
- ✅ PKCE 緩和は「confidential client が完全省略した場合のみ」に絞られており、
  public client・部分指定・`plain` はフラグに関係なく拒否される
- ✅ `alg=none` 許容時は Discovery に `"none"` を出しており、広告の正直性が保たれている
- ✅ `alg=none` でも署名部が空であることを検証している（RFC 7515 §6 準拠）
- ✅ JSDoc に「Conformance 互換目的でのみ有効化する」旨が書かれている

不足している可能性があること:

- 🟠 **有効化状態が実行時に可視化されない**: 起動ログにも `/health` にも出ない。
  Conformance 実行後に環境変数を消し忘れても、誰も気づけない。
  Workers / Fly / Vercel のいずれも環境変数はデプロイ設定として残り続ける。
- 🟡 **`allowNonPkceAuthorizationCodeFlow` は外部から観測できない**: Discovery には出ない。
  「この OP は PKCE を必須にしているか」をクライアントが事前に知る手段が無い
  （PKCE を送れば常に検証されるので実害は限定的だが、透明性は下がる）。
- 🟡 **フラグ有効構成の契約テストが無い**: 「フラグ ON のとき何が通り、何が依然として拒否されるか」
  （public client の PKCE 省略は ON でも拒否される、`plain` は ON でも拒否される、
  署名部が空でない `alg=none` は ON でも拒否される）を固定する回帰テストが無い。
  緩和範囲が将来のリファクタで広がっても検知できない。
- 🟡 **2 つのフラグを個別に管理している**: 「Conformance 互換プロファイル」という
  1 つの意図を 2 つの独立したフラグで表現しているため、片方だけ残る状態が作れてしまう。
- 🟢 **README / デプロイガイドへの記載**: 環境変数の一覧としてどこまで説明されているかは要棚卸し。

セキュリティ上、改善した方がよいこと:

- 「意図的な緩和」と「事故による緩和」を区別できる状態を作ること。
  具体的には、有効化されていることが**必ず目に入る**（ログ・ヘルス応答・起動バナー）ようにする。
- 緩和範囲が最小に保たれていることを、テストで固定する。

Basic OP として提供する上で確認すべきこと:

- Conformance を通すために一時的にフラグを有効にする運用そのものは正当である。
  問題は「通した後に戻す」ことが手作業に依存している点。
  `study-material/basic-op-conformance-verification-plan.md` の手順に
  「実行後にフラグを戻す」ステップが明記されているかを確認する必要がある。

## 7. 改善・追加を検討する理由

- **なぜ価値があるか**: 本リポジトリは「Conformance 準拠を信頼性のシグナルとして維持する」ことを
  差別化軸に置いている。その Conformance を通すためのフラグが、逆に
  「準拠していない構成のまま動く OP」を生む経路になっているのは構造的なねじれである。
- **Basic OP として必要か、拡張か**: 認定の要件ではなく**運用上の安全装置**。
  実装コストは小さく、事故の帰結（PKCE 防御の低下・Request Object の完全性喪失）は大きい。
- **導入しやすさ**: 高い。起動時の警告出力はサンプルの `app.ts` に数行、
  契約テストは既存の `conformance.test.ts` 生成コードに追加するだけ。
  core の変更は不要（フラグの意味は変えない）。
- **既存実装との接続**:
  - `/health` は既に存在するので、そこに「有効な互換フラグの一覧」を足すのが最も自然。
    ただし**未認証で公開される情報**なので、出すべきかは判断が要る（§8 方針B の論点）。
  - `assertHasRs256Key` / `assertKeyStrength` のような「起動時アサーション」の前例があるので、
    同じ位置に警告出力を置ける。
- **利用者・運用者のメリット**: PoC からステージングへ持ち上げるときに、
  「この OP は仕様どおりの厳格モードか」を一目で確認できる。
- **実装しない場合のリスク**:
  - Conformance 検証用に立てた環境をそのまま別用途に転用し、PKCE 緩和が残ったまま使われる
  - 緩和範囲がリファクタで広がっても気づけない
  - 「Basic OP 準拠」と説明している OP が、実は互換モードで動いていた、という説明責任の問題

## 8. 実装方針の候補

判断材料の整理（最終判断は人間が行う）。

### 方針A（起動時の警告出力のみ、最小）

- 各サンプルの起動処理で、いずれかの互換フラグが true なら
  `console.warn` に「Conformance 互換モードが有効。仕様上の要件が緩和されている」と出す。
- 出力先はプラットフォームのログ（Workers Tail / Fly logs / Vercel logs）。
- 長所: コスト最小、外部に情報を漏らさない。短所: ログを見ない限り気づけない。

### 方針B（`/health` に構成サマリを出す）

- `/health` の応答に `{ status: 'ok', compatibilityMode: { nonPkceAuthorizationCode: true, unsignedRequestObject: false } }` を含める。
- 長所: 外形監視から検知できる。デプロイ後の確認が容易。
- 短所: **未認証の第三者に「この OP は PKCE を緩めている」と教えることになる**。
  攻撃者への情報提供になり得るため、`/health` を公開しない前提か、
  認証付きの別パスにするかの判断が必要。
  （関連: `study-material/operational-health-readiness-endpoints.md` のエンドポイント設計）

### 方針C（緩和範囲を固定する契約テストを追加）

- 各 sample の `conformance.test.ts` を生成する CLI 側コードに、
  「互換フラグ ON でも依然として拒否されるもの」を列挙したテストを追加する:
  - public client が PKCE を省略 → ON でも `invalid_request`
  - `code_challenge` だけ指定（`code_challenge_method` 欠落）→ ON でも `invalid_request`
  - `code_challenge_method=plain` → ON でも `invalid_request`
  - `alg=none` かつ署名部が非空 → ON でも拒否
  - `alg=none` かつ `allowUnsignedRequestObject=false` → `invalid_request`
- 長所: 緩和範囲の意図しない拡大を機械的に防げる。フラグの意味がテストで文書化される。
- 短所: テストケースが増える（実行時間は軽微）。

### 方針D（1 つの「プロファイル」設定に統合）

- `ProviderConfig` に `securityProfile: 'strict' | 'oidf-conformance-compat'` を導入し、
  2 つのフラグをその派生値にする。
- 長所: 「片方だけ残る」状態を作れなくなる。意図が 1 語で表現される。
- 短所: 破壊的変更（既存の 2 フラグを使っている利用者に影響）。
  Conformance のモジュールによっては片方だけ必要なケースがあり得るため、粒度を落とす副作用がある。

### 方針E（Conformance 実行手順に「戻す」ステップを明記）

- `study-material/basic-op-conformance-verification-plan.md` および
  `tasks/done/p1-basic-op-conformance-manual-review-runner.md` の手順に、
  実行後に環境変数を削除する手順とその確認方法（Discovery の
  `request_object_signing_alg_values_supported` に `"none"` が無いこと）を追加する。
- コスト最小。方針A/C と併用しやすい。

判断のポイント:

- 方針B は「検知しやすさ」と「情報開示」のトレードオフ。`/health` を公開したままにするサンプルの
  性質上、既定では出さない（あるいは `OIDC_HEALTH_VERBOSE=1` のときだけ出す）判断があり得る。
- 方針D は意図の明確化として筋が良いが、破壊的変更なので `RELEASE-v0.x-scope.md` の
  バージョン区切りに合わせる必要がある。
- 方針A＋C＋E の組み合わせが、コストと効果のバランスとしては最も無難と考えられる。

## 9. タスク案

- [ ] 方針 A〜E のどれを採るか（特に方針B で `/health` に出すか）を人間が決定する
- [ ] 方針A採用時:
  - [ ] 各サンプルの起動処理に、互換フラグ有効時の警告出力を追加する
  - [ ] 警告文には「どのフラグが」「何を緩めているか」を含める
- [ ] 方針C採用時:
  - [ ] `packages/cli` の `conformance.test.ts` 生成コードに「ON でも拒否されるもの」の
        テストケース群を追加する（本ファイル §8 方針C の 5 項目）
  - [ ] 既存の生成物（`samples/*/src/oidc-provider/conformance.test.ts`）を再生成して差分を確認する
- [ ] 方針E採用時:
  - [ ] `study-material/basic-op-conformance-verification-plan.md` に
        「実行後にフラグを戻し、Discovery で確認する」手順を追加する
- [ ] 各サンプルの README に `OIDC_ALLOW_NON_PKCE_AUTHORIZATION_CODE_FLOW` /
      `OIDC_ALLOW_UNSIGNED_REQUEST_OBJECT` の説明（用途・既定値・戻し方）が
      記載されているか棚卸しし、無ければ追記する
- [ ] `allowNonPkceAuthorizationCodeFlow` が有効なとき、外部から観測可能にすべきかを判断する
      （Discovery には該当する標準メタデータが無いため、独自フィールドは避けるべきという整理も含めて）
