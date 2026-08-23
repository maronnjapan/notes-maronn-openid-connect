# 同意画面のクライアント識別情報とスコープ開示（`client_name` / `logo_uri` / `policy_uri` / `tos_uri`）

## 1. タイトル

生成 OP の同意画面が **`client_id` の生文字列とスコープ名の生文字列しか表示していない**ため、
エンドユーザーが「誰に」「何を」許可しようとしているのかを判断できない問題。
OIDC Dynamic Client Registration 1.0 §2 が定義する人間可読なクライアントメタデータ
（`client_name` / `logo_uri` / `client_uri` / `policy_uri` / `tos_uri`）を保持・表示する経路が無い。

## 2. このトピックで確認したいこと

- OIDC Core 1.0 §3.1.2.4 が求める「情報を RP へ渡す前に authorization decision を得る」という要件に対し、
  現在の同意画面が**意思決定に足る情報**を提示できているか
- クライアント登録メタデータのうち **表示用（human-readable）フィールド**を
  `ClientInfo` / `RegisteredClient` が保持していないことの影響
- スコープの人間可読な説明（`profile` が何を意味するか）を提示する経路が無いこと
- `logo_uri` を表示に使う場合に生じる新たなリスク（外部画像読み込み・フィッシング・プライバシー）

> 既存ファイルで扱っている内容は繰り返さない:
> - 同意の**記録・永続化・再利用**と grant 管理: `study-material/done/consent-grant-persistence-and-management.md`
> - 同意決定値の fail-open（`action` の扱い）: `study-material/done/consent-decision-fail-open-action-value.md`
> - 同意取り消しとトークン失効: `study-material/done/consent-withdrawal-grant-token-revocation.md`
> - クライアントメタデータの**強制**（`grant_types` / `response_types` / `token_endpoint_auth_method`）:
>   `study-material/done/client-metadata-enforcement.md`
> - 生成ビューの HTML エスケープ: `study-material/done/generated-login-consent-html-escaping-consistency.md`
> - `ui_locales` / `claims_locales` の受理と伝播: `study-material/done/ui-claims-locales-auth-transaction-handling.md`
> - `claims` パラメータで要求されたクレームの同意境界:
>   `study-material/claims-parameter-consent-authorization-boundary.md`
> - スコープの検証・未知スコープ・部分同意: `study-material/scope-handling-validation-and-granted-scope.md`
> - Dynamic Client Registration そのもの: `study-material/ext-dynamic-client-registration.md`
>
> 本ファイルは「**同意画面に何を表示するか**」＝表示用クライアントメタデータの保持と描画に限定する。
> 同意の記録・取消・部分同意といった「同意の意味論」は上記既存ファイルの担当。

## 3. 関連する仕様・基準（本トピック固有の差分）

### 3.1 OIDC Core 1.0 §3.1.2.4 — Authorization Server Obtains End-User Consent/Authorization

> Once the End-User is authenticated, the Authorization Server MUST obtain an authorization
> decision before releasing information to the Relying Party.

「authorization decision を得る」とは、ユーザーが**判断できる状態で**同意することを意味する。
仕様は UI 要件を規定しないが、判断材料が `client_id` の内部識別子だけという状態は
この要件の趣旨を満たしているとは言い難い。

### 3.2 OIDC Dynamic Client Registration 1.0 §2 — 表示用クライアントメタデータ

§2 は登録可能なクライアントメタデータとして次を定義している（いずれも OPTIONAL）。

| フィールド | 用途 |
|---|---|
| `client_name` | エンドユーザーに提示するクライアント名 |
| `logo_uri` | エンドユーザーに提示するロゴ画像の URL |
| `client_uri` | クライアントのホームページ URL |
| `policy_uri` | クライアントのプライバシーポリシー URL |
| `tos_uri` | クライアントの利用規約 URL |
| `contacts` | クライアント担当者の連絡先（管理用途） |

`logo_uri` について §2 は「**エンドユーザーに表示される**」ものであること、
`policy_uri` / `tos_uri` は「クライアントがプロファイルデータをどう扱うかについて
エンドユーザーが読むべきドキュメント」であることを明示している。

### 3.3 OIDC Dynamic Client Registration 1.0 §2.1 — Human Readable Client Metadata

人間可読フィールドは `#` に続く BCP47 言語タグで多言語化できる
（例: `client_name`, `client_name#ja-Jpan-JP`）。
本リポジトリは `ui_locales` を AuthTransaction に保持する対応を済ませているため
（`study-material/done/ui-claims-locales-auth-transaction-handling.md`）、
表示用メタデータを持てば言語選択と接続できる素地はある。

### 3.4 RFC 7591 §2 — OAuth 2.0 Dynamic Client Registration の同フィールド

RFC 7591 §2 も `client_name` / `client_uri` / `logo_uri` / `tos_uri` / `policy_uri` を
同じ意味で定義しており、静的登録の OP でも「登録メタデータの語彙」として参照できる。
本リポジトリは DCR を実装していないが、**メタデータの名前と意味は RFC 7591 / OIDC Registration に揃えるべき**で、
独自命名にすると将来 DCR を入れたときにマッピングが要る。

### 3.5 RFC 6749 §10.2 Client Impersonation

> The authorization server MUST authenticate the client when possible. ...
> The authorization server SHOULD NOT process repeated authorization requests automatically
> (without active resource owner interaction) without authenticating the client or relying on
> other measures to prevent client impersonation.

クライアントなりすましへの防御は「クライアント認証」と「リソースオーナーの能動的な関与」の
2 本立てで語られている。後者が意味を持つのは、リソースオーナーが**どのクライアントに許可するのかを
識別できる場合のみ**である。`client_id` の生値しか出ていないと、悪意あるクライアントが
正規クライアントに酷似した `client_id`（例: `github-app` に対する `github-app-`）を登録した場合に
ユーザーが見分けられない。

### 3.6 `logo_uri` 表示に伴う新たなリスク（仕様の外側だが判断材料）

- **フィッシング**: 攻撃者が正規サービスのロゴ URL をそのまま `logo_uri` に登録すると、
  同意画面が正規サービスの見た目になる。ロゴを出す OP は登録時の審査が前提になる。
- **外部リソース読み込み**: `<img src="<logo_uri>">` はブラウザから第三者ドメインへの
  リクエストを発生させ、ユーザー IP・User-Agent がクライアント側に漏れる。
  Content-Security-Policy の `img-src` 設計にも影響する。
- **SSRF**: OP が画像をプロキシ／キャッシュする実装にすると SSRF 面が生まれる。
  プロキシしない（ブラウザに直接読ませる）なら SSRF は生じない。

したがって「表示する／しない」は単純な機能追加ではなく、**登録ポリシーとセットの判断**になる。

## 4. 参照資料

- OpenID Connect Core 1.0 §3.1.2.4 Authorization Server Obtains End-User Consent/Authorization —
  https://openid.net/specs/openid-connect-core-1_0.html#Consent
- OpenID Connect Dynamic Client Registration 1.0 §2 Client Metadata —
  https://openid.net/specs/openid-connect-registration-1_0.html#ClientMetadata
  （`client_name` / `logo_uri` / `client_uri` / `policy_uri` / `tos_uri` の定義と「エンドユーザーに提示される」旨）
- OpenID Connect Dynamic Client Registration 1.0 §2.1 Human Readable Client Metadata —
  https://openid.net/specs/openid-connect-registration-1_0.html#LanguagesAndScripts
  （`client_name#ja` 形式の言語タグ）
- RFC 7591 §2 Client Metadata — https://www.rfc-editor.org/rfc/rfc7591#section-2
- RFC 6749 §10.2 Client Impersonation — https://www.rfc-editor.org/rfc/rfc6749#section-10.2
- OpenID Connect Core 1.0 §5.4 Requesting Claims using Scope Values —
  https://openid.net/specs/openid-connect-core-1_0.html#ScopeClaims
  （`profile` / `email` / `address` / `phone` が具体的にどのクレームを含むかの一覧。スコープ説明文の根拠）

## 5. 現在の実装確認

### 5.1 同意画面のパラメータ型（`packages/cli/src/frameworks/hono/templates.ts:4121` 付近）

```ts
export interface ConsentPageParams {
  transactionId: string;
  csrfToken: string;
  scopes: string[];   // スコープ名の生文字列
  clientId: string;   // client_id の生文字列
}
```

表示用のクライアントメタデータを受け取るフィールドが存在しない。

### 5.2 既定の同意画面（同 `templates.ts:4238` 付近 / 生成物 `views.ts`）

```html
<h1>Authorize Application</h1>
<p>Client <strong>{client_id}</strong> is requesting access to the following scopes:</p>
<ul><li>openid</li><li>profile</li><li>email</li></ul>
<button name="action" value="approve">Approve</button>
<button name="action" value="deny">Deny</button>
```

- クライアントは `client_id`（例: `example-client`）としか表示されない
- スコープは `openid` / `profile` のような**プロトコル語彙のまま**表示され、
  「氏名・生年月日・ロケール等のプロフィール情報」といった説明が無い
- プライバシーポリシー / 利用規約へのリンクが無い
- エスケープは全値に適用済み（`escapeHtml`）で、この点は既存タスクで解決済み

### 5.3 クライアント登録メタデータ（`samples/*/src/oidc-provider/config.ts`）

```ts
export type RegisteredClient = ClientInfo & TokenClientInfo & {
  offlineAccessAllowed?: boolean;
  userinfoSignedResponseAlg?: 'RS256' | 'ES256';
  idTokenSignedResponseAlg?: 'RS256' | 'ES256';
};
```

`ClientInfo`（`packages/core/src/authorization-request.ts`）は
`clientId` / `redirectUris` / `clientType` / `responseTypes` / `defaultMaxAge` / `jwks` を持つが、
**表示用フィールドは 1 つも無い**。`TokenClientInfo` も認証・grant 用のフィールドのみ。

### 5.4 同意画面の呼び出し（生成物 `routes/consent.ts`）

```ts
return renderView(views.consentPage({
  transactionId, csrfToken,
  scopes: transaction.scope.split(' ').filter(Boolean),
  clientId: transaction.clientId,
}));
```

`clientResolver.findClient()` を呼んでいないため、クライアント情報を取りに行く経路自体が無い
（POST 側では `offlineAccessAllowed` の判定のために `findClient` を呼んでいる）。

## 6. 現在の実装との差分

満たしていること:

- ✅ 同意画面は存在し、`approve` / `deny` の明示的な意思決定を取っている（§3.1.2.4 の骨格は満たす）
- ✅ 要求スコープは列挙されており、「何を要求されているか」は最低限伝わる
- ✅ すべての補間値が HTML エスケープされている
- ✅ ビューは `createViews()` で差し替え可能なので、利用者が自前 UI を作る余地はある

不足している可能性があること:

- 🟠 **クライアントを人間が識別できない**: `client_name` / `client_uri` / `logo_uri` を
  保持も表示もしていない。ユーザーは `client_id` という内部識別子だけで判断を迫られる。
- 🟠 **プライバシーポリシー / 利用規約への導線が無い**: `policy_uri` / `tos_uri` は
  OIDC Registration §2 が「エンドユーザーが読むべきドキュメント」と位置づけるものだが、保持経路が無い。
  GDPR / 個人情報保護法の観点でも、同意取得時に取扱方針を提示できないのは実運用上の制約になる。
- 🟡 **スコープの人間可読な説明が無い**: `profile` が OIDC Core §5.4 でどの 14 クレームを含むかは
  仕様上確定しているのに、その情報を UI に出す仕組みが無い。
  `SCOPE_CLAIMS_MAP`（`packages/core/src/userinfo.ts`）が既に対応表を持っているので、
  技術的な素材は揃っている。
- 🟡 **`ui_locales` と表示用メタデータの言語タグが接続されていない**: `ui_locales` は
  AuthTransaction に保持されるようになったが、`client_name#ja` を選ぶ機構が無い。
- 🟢 **`contacts` などの管理用メタデータ**: 同意画面には不要。保持するとしても別論点。

セキュリティ上、改善した方がよいこと:

- クライアント識別ができないことは、RFC 6749 §10.2 が想定する
  「リソースオーナーの能動的関与によるなりすまし防止」を機能させない。
- 一方で `logo_uri` を無審査で表示すると**フィッシングを助長する**（§3.6）。
  「表示するなら登録審査が前提」という制約を、実装と同時にドキュメント化する必要がある。
- `client_uri` / `policy_uri` / `tos_uri` をリンクとして描画する場合、
  `javascript:` などの危険スキームを弾く必要がある。
  `redirect_uri` 側には既に危険スキーム拒否の実装がある（`tasks/done/p1-redirect-uri-dangerous-scheme-rejection.md`）ので、
  同じ判定を再利用できるか検討する。

相互運用性の観点で改善した方がよいこと:

- フィールド名を OIDC Registration 1.0 / RFC 7591 と同じ snake_case 語彙にマッピングしておけば、
  将来 DCR（`study-material/ext-dynamic-client-registration.md`）を実装したときに
  登録リクエストの JSON をそのまま流し込める。独自命名にすると変換層が必要になる。

Basic OP として提供する上で確認すべきこと:

- OIDF Basic OP の Conformance テストは同意画面の**内容**を機械的に検証しない
  （同意画面の存在は手動スクリーンショットで確認する運用。
  `tests/conformance/manual-review-screenshots.md` 参照）。
  したがって認定の必須要件ではなく、**セキュリティ／UX の質**として扱う。

## 7. 改善・追加を検討する理由

- **なぜ価値があるか**: 同意画面は OP がエンドユーザーと直接対話する唯一の場所であり、
  「誰に何を渡すか」の意思決定が行われる地点。ここが `client_id` の生値だけという状態は、
  仕様準拠の議論以前に、認可の正当性の根拠を弱くする。
- **Basic OP として必要か、拡張か**: 認定の必須要件ではない。ただし
  「同意を取っている」と主張するために必要な最低限の情報開示であり、拡張機能というより
  **既定 UI の品質問題**として扱うのが適切。
- **導入しやすさ**: 高い。`ClientInfo` に OPTIONAL フィールドを足し、`ConsentPageParams` を拡張し、
  `routes/consent.ts` の GET 側で `clientResolver.findClient()` を呼ぶだけで成立する。
  すべて OPTIONAL なので、値を登録していない既存クライアントは現行表示のままフォールバックできる
  （後方互換を壊さない）。
- **既存実装との接続**:
  - `ClientInfo` は既に `defaultMaxAge` / `jwks` といった登録メタデータ由来のフィールドを持っており、
    表示用フィールドを足す先として自然。
  - `SCOPE_CLAIMS_MAP` がスコープ→クレームの対応表を持っているので、
    スコープ説明の既定文言はこれを土台にできる。
  - `createViews()` による差し替えがあるので、既定 UI を最小に保ちつつ
    「型としては情報が渡っている」状態にできる（利用者が自前 UI で活用できる）。
- **利用者・開発者・運用者のメリット**: PoC で自社アプリ名とロゴを出した同意画面を見せられるようになる。
  IdaaS（Auth0 / Okta / Keycloak）はいずれも同意画面にアプリ名とロゴを出すため、比較検証の解像度が上がる。
- **実装しない場合のリスク**:
  - 生成 OP の同意画面をそのまま見せると「開発中の画面」に見え、PoC のデモ価値が下がる
  - なりすましクライアントをユーザーが識別できない
  - DCR を後から入れたときに、登録メタデータの表示用フィールドを受け取る先が無く再設計になる

## 8. 実装方針の候補

判断材料の整理（最終判断は人間が行う）。

### 方針A（表示用メタデータの保持と最小表示）

- `ClientInfo` に OPTIONAL フィールドを追加:
  `clientName?` / `clientUri?` / `logoUri?` / `policyUri?` / `tosUri?`
  （core は camelCase、登録メタデータの snake_case とのマッピングをコメントで明示）
- `ConsentPageParams` に同じ値を追加。`routes/consent.ts` の GET で `findClient()` して渡す。
- 既定ビューは `clientName ?? clientId` を見出しに出し、`policyUri` / `tosUri` があればリンクを出す。
- **`logoUri` は型としては渡すが、既定ビューでは描画しない**（フィッシング面を既定で開かない）。
  描画したい利用者は `createViews()` で自前ビューを書く。
- 長所: 後方互換を壊さず、リスクの高い部分だけ opt-in にできる。
- 短所: 「型はあるが既定では出ない」ことの説明が要る。

### 方針B（方針A ＋ ロゴも既定で表示）

- `logoUri` を `<img>` で描画する。合わせて登録時に https スキームのみ許可する検証を入れる。
- ドキュメントに「ロゴを表示する OP は、クライアント登録時に運営者が審査すること」を明記。
- 長所: 商用 IdP と同じ体験になる。短所: 無審査の静的登録で使うとフィッシング面が開く。

### 方針C（スコープ説明の既定辞書を core に持つ）

- `SCOPE_CLAIMS_MAP` の隣に `SCOPE_DESCRIPTIONS`（英語の既定文言、OIDC Core §5.4 の内容を要約）を追加し、
  `ConsentPageParams` に `scopeDescriptions?: Record<string, string>` として渡す。
- 未知スコープは説明なしでスコープ名のみ表示にフォールバック。
- 長所: 「何を許可するのか」が最も直接的に改善する。
- 短所: 文言の多言語化をどこまでやるかの線引きが必要（`ui_locales` との接続は方針E）。

### 方針D（クライアント登録メタデータの検証を追加）

- `clientUri` / `policyUri` / `tosUri` / `logoUri` に https（または http でループバック）の
  絶対 URL 検証を入れ、`javascript:` 等を拒否する。
- 既存の `validateRegisteredRedirectUris` と同じく、**設定ミスの早期検知**として起動時／解決時に走らせる。
- 方針A/B と組み合わせる前提。

### 方針E（`ui_locales` と言語タグ付きメタデータの接続）

- `client_name#ja` 形式のフィールドを `ClientInfo` に持たせ、`ui_locales` に応じて選択する。
- 長所: OIDC Registration §2.1 に正面から準拠する。
- 短所: 静的登録での記述が煩雑になる。DCR 実装まで待つ判断もあり得る。

判断のポイント:

- **既定で `logo_uri` を出すか**が最大の分岐。本リポジトリの想定ユーザー（PoC 開発者）が
  静的登録で自分のクライアントだけを登録するなら審査は自明に成立するが、
  生成コードをそのまま多者向けに使うケースを想定するなら既定オフが安全。
- スコープ説明（方針C）は単独でも価値が高く、方針A と独立に実施できる。
- フィールド名を core で camelCase にするか snake_case のまま持つかは、
  DCR 実装時のマッピングコストと既存 `ClientInfo` の命名一貫性のトレードオフ。

## 9. タスク案

- [ ] 方針 A〜E のどれを採るか（特に `logo_uri` を既定で描画するか）を人間が決定する
- [ ] 方針A採用時:
  - [ ] `packages/core/src/authorization-request.ts` の `ClientInfo` に
        `clientName?` / `clientUri?` / `logoUri?` / `policyUri?` / `tosUri?` を追加し、
        OIDC Registration 1.0 §2 の対応フィールド名を JSDoc に明記する
  - [ ] `packages/cli/src/frameworks/hono/templates.ts` の `ConsentPageParams` に同フィールドを追加
  - [ ] 生成 `routes/consent.ts` の GET ハンドラで `clientResolver.findClient()` を呼び、値をビューへ渡す
  - [ ] 既定 `defaultConsentPage` を `clientName ?? clientId` 表示＋`policyUri` / `tosUri` リンクに更新
        （全値エスケープを維持）
  - [ ] `samples/*/src/oidc-provider/config.ts` の既定クライアントに `clientName` の例を入れる
  - [ ] 各 sample の `conformance.test.ts` を生成する CLI 側コードに、
        「`clientName` 未登録なら `clientId` が表示される」「登録済みなら `clientName` が表示される」
        契約テストを追加する
- [ ] 方針C採用時:
  - [ ] `SCOPE_DESCRIPTIONS` を `packages/core/src/userinfo.ts`（`SCOPE_CLAIMS_MAP` の隣）に追加
  - [ ] 未知スコープのフォールバック挙動を単体テストで固定
- [ ] 方針D採用時:
  - [ ] 表示用 URI の検証関数を追加し、`javascript:` / `data:` 等を拒否する単体テストを書く
  - [ ] `validateRegisteredRedirectUris` と同じ「設定ミスは server_error」の方針で揃えるか判断
- [ ] `logo_uri` を描画する場合の注意（登録審査が前提・CSP `img-src`・IP 漏洩）を
      生成コードのコメントまたは README に明記する
- [ ] `study-material/ext-dynamic-client-registration.md` に、
      本ファイルで決めた表示用メタデータのフィールド名を DCR 実装時に流用する旨の相互参照を追記する
