# `offline_access` の付与判定がクライアント登録 `grant_types` を参照せず、使用不能な Refresh Token を発行しうる

## ステータス

🟢 解決済み / 方針 A（+ 方針 B のシグネチャ拡張）を採用

§7 の「最初の分岐」（独自フラグを独立軸として残すか）は、**残さない**と決着した。
判断の根拠は、独立軸として意味を持つ唯一のケース「refresh_token grant は許すが offline access は許さない」を、
独自フラグではなく **online refresh token** として実装したことにある。
online refresh token は `offline_access` を伴わない付与で発行され、発行元のログインセッションに束縛される。
セッションが終われば使えないので、「セッションを超えるアクセスは許さない」という区別は
`offline_access` の付与の有無だけで表現できる。

採用した内容:

- `ClientInfo` に `grantTypes` を追加し、`OfflineAccessGrantedCallback` の context に `client` を渡す（方針 B のシグネチャ拡張）
- `defaultIsOfflineAccessGranted` を「`prompt=consent` かつ `grant_types` に `refresh_token` を含む」に変更
- 生成コードから `offlineAccessAllowed` と重複フィルタを削除（方針 A）
- 事故 A（使えない RT を発行する）はトークンエンドポイントの発行判定でも塞いだ

移行の告知は破壊的変更として changeset に記載した。実装は
`tasks/done/p1-refresh-token-issuance-requires-refresh-grant-registration.md` を参照。

## 1. このトピックで確認したいこと

本リポジトリでは「クライアントが Refresh Token を使えるか」が**2 つの独立したスイッチ**で
表現されており、両者を人手で同期させる必要がある。

| スイッチ | 定義場所 | 効く場所 | 標準か |
|---|---|---|---|
| `offlineAccessAllowed: boolean` | 生成コードの `config.ts`（`RegisteredClient`） | 認可エンドポイント（同意後の scope フィルタ） | ❌ 本リポジトリ独自 |
| `grantTypes` に `'refresh_token'` を含むか | `TokenClientInfo`（core の型） | トークンエンドポイント（`validateClientGrantType`） | ✅ RFC 7591 §2 / OIDC DCR §2 |

この 2 つがずれると、次の 2 通りの事故が起きる。

- **事故 A**: `offlineAccessAllowed: true` かつ `grantTypes` に `refresh_token` 無し
  → OP は Refresh Token を**発行する**が、その Refresh Token を使った瞬間に
  `unauthorized_client` で拒否される。**発行時点では何のエラーも出ない**（遅延失敗）。
- **事故 B**: `offlineAccessAllowed: false` かつ `grantTypes` に `refresh_token` 有り
  → 登録上は refresh_token grant を許可しているのに、Refresh Token が**一度も発行されない**。
  クライアントには `offline_access` が黙って scope から落とされるだけで、理由が伝わらない。

本ファイルでは以下を確認・整理する。

- 標準のクライアントメタデータ（`grant_types`）で表現できるものを、
  なぜ独自フラグで二重管理しているのか。統合できるか
- 認可エンドポイントが `grant_types` を参照できない構造的理由（core の型に無い）
- 「使えない Refresh Token を発行する」ことが仕様・セキュリティ上どう評価されるか

### 既存ファイルとの差分（重複回避）

- `offline_access` の付与条件そのもの（OIDC Core §11 の `prompt=consent` 要件、
  代替条件の注入）: `study-material/offline-access-scope-grant-policy.md`
  → 本ファイルは「§11 の条件を満たした**後**に、クライアント登録と整合しているか」を扱う。
- クライアント登録メタデータ（`grant_types` / `response_types` /
  `token_endpoint_auth_method`）の**各エンドポイントでの強制**:
  `study-material/done/client-metadata-enforcement.md` / `tasks/done/p1-client-metadata-enforcement.md`
  → 当該タスクは「トークンエンドポイントで `grant_types` を強制する」ところまでを実装済み。
  本ファイルは**認可エンドポイント側が同じメタデータを参照していない**という
  クロスエンドポイントの非整合に絞る。
- per-client の `scope` 登録メタデータ強制:
  `study-material/scope-handling-validation-and-granted-scope.md`（未決事項として保留中）
  → 本ファイルは「任意 scope の per-client 制限」ではなく、
  **`offline_access` と `grant_types` という既に存在する 2 つのフラグの整合**のみを扱う。
- scope 縮小時の rotation 可否: `tasks/done/p1-refresh-scope-offline-access-rotation.md`
- rotation 後の RT に保存する scope: `study-material/refresh-token-grant-scope-preservation.md`
- Discovery の `grant_types_supported` 広告: `tasks/T-021-discovery-metadata.md` /
  `study-material/done/discovery-grant-types-supported-implicit-default.md`

## 2. 関連する仕様・基準（このトピック固有の差分）

### 2.1 RFC 7591 §2 / OIDC Dynamic Client Registration 1.0 §2 — `grant_types`

`grant_types` はクライアントが使用する grant type の配列で、**既定値は `["authorization_code"]`**。
`refresh_token` を使うクライアントは明示的に登録しなければならない。

> **grant_types**
> Array of OAuth 2.0 grant type strings that the client can use at the token endpoint.
> (中略) If omitted, the default is that the client will use only the `authorization_code` Grant Type.

重要なのは、これが**トークンエンドポイントでの使用可否**を定める登録メタデータであること。
「Refresh Token を受け取れるか」ではなく「Refresh Token grant を**使えるか**」を表す。
したがって `refresh_token` を登録していないクライアントに Refresh Token を渡すことは、
仕様上「使えないものを渡す」＝無意味な発行になる。

### 2.2 OIDC Core 1.0 §11 — `offline_access`

§11 は `offline_access` scope を「End-User がオンラインでない状態でも
アクセストークンを取得できるようにする」ための scope として定義し、
付与に `prompt=consent`（または他の条件）を要求する。

> When the `offline_access` scope is requested, (中略)
> The Authorization Server MUST ignore the `offline_access` request unless (中略)
> a `prompt` parameter value of `consent` (後略)

§11 は**エンドユーザーの同意**という軸を規定するもので、
**クライアントの登録上の権限**（`grant_types`）とは直交する。
つまり `offline_access` を付与してよいかの判定には、本来
「§11 のユーザー同意条件」と「クライアント登録上 refresh_token grant が許可されているか」の
**両方**が必要である。現状の実装は前者のみを core が扱い、後者は独自フラグで代替している。

### 2.3 RFC 6749 §5.1 — Refresh Token の発行は任意

> **refresh_token** OPTIONAL. The refresh token, which can be used to obtain new
> access tokens using the same authorization grant as described in Section 6.

Refresh Token を発行しないこと自体は仕様違反ではない。
したがって事故 B（発行されない）は**仕様違反ではなく設定事故**である。
一方、事故 A（使えないものを発行する）も明文の禁止規定は無いが、
RFC 6749 §5.1 が「同じ authorization grant で新しいアクセストークンを得るために使える」と
定義している以上、**使えないと分かっているトークンを発行する**のは定義との齟齬にあたる。

### 2.4 RFC 9700 (OAuth 2.0 Security BCP) — Refresh Token の露出最小化

RFC 9700 は Refresh Token を長期資格情報として扱い、
露出・保存期間を最小化することを一貫して求めている。
「使えない Refresh Token をクライアントに配り、クライアントが保存する」状態は、
価値ゼロのまま攻撃面（保存された長期文字列）だけが増えることを意味する。

### 事実と判断の区別

- **事実**: `grant_types` の既定は `["authorization_code"]`（RFC 7591 §2 / OIDC DCR §2）。
- **事実**: 本リポジトリの認可エンドポイントは `offline_access` の可否を
  `offlineAccessAllowed`（独自フラグ）で判定し、`grant_types` を参照していない（§4）。
- **事実**: トークンエンドポイントは `grant_types` を強制する（`validateClientGrantType`）。
- **判断**: 2 つのフラグは同じ意図（このクライアントは Refresh Token を使ってよいか）を
  表しており、**独立に設定できること自体が設計上の負債**と考えられる。
  ただし「同意（§11）」と「クライアント権限（`grant_types`）」を分けて持ちたい、
  という設計意図があるなら別軸として正当化できる余地はある（§7 の方針 D）。
- **判断**: Basic OP 認定の必須要件ではない。

## 3. 参照資料

- RFC 7591 §2 Client Metadata（`grant_types` の定義と既定値）:
  https://www.rfc-editor.org/rfc/rfc7591#section-2
- OpenID Connect Dynamic Client Registration 1.0 §2 Client Metadata:
  https://openid.net/specs/openid-connect-registration-1_0.html#ClientMetadata
- OpenID Connect Core 1.0 §11 Offline Access:
  https://openid.net/specs/openid-connect-core-1_0.html#OfflineAccess
- RFC 6749 §5.1 Successful Response（`refresh_token` は OPTIONAL）:
  https://www.rfc-editor.org/rfc/rfc6749#section-5.1
- RFC 6749 §5.2 Error Response（`unauthorized_client` の定義）:
  https://www.rfc-editor.org/rfc/rfc6749#section-5.2
- RFC 9700 (OAuth 2.0 Security Best Current Practice) §4.14 Refresh Token Protection:
  https://www.rfc-editor.org/rfc/rfc9700#section-4.14

> ⚠️ 注記: 本調査環境からは openid.net / rfc-editor.org への直接フェッチが遮断されていたため、
> §2 の引用は逐語ではなく趣旨要約を含む。逐語確認は §9 のタスクに含めた。
> 実装側の事実関係（どのファイルのどの行が何を参照しているか）はすべてコードから直接確認済み。

## 4. 現在の実装確認

### 4.1 core の認可エンドポイントは `grant_types` を知らない

`packages/core/src/authorization-request.ts:105-133` の `ClientInfo`:

```ts
export interface ClientInfo {
  clientId: string;
  redirectUris: string[];
  clientType?: 'confidential' | 'public';
  responseTypes?: string[];     // ← response_type の per-client 強制はある
  defaultMaxAge?: number;
  jwks?: JwkSet;
}
```

- **`grantTypes` フィールドが無い**。`responseTypes` はあるのに `grantTypes` は無い、という非対称。
- 一方 `packages/core/src/token-request.ts:63-84` の `TokenClientInfo` には `grantTypes` がある。
- つまり core は「認可エンドポイント用のクライアント型」と
  「トークンエンドポイント用のクライアント型」を分けており、
  前者には Refresh Token 可否を判断する材料が**構造的に存在しない**。

### 4.2 core の `offline_access` 付与判定は §11 の条件のみ

`packages/core/src/authorization-request.ts:169-184`

```ts
export type OfflineAccessGrantedCallback = (
  request: AuthorizationRequestParams,
  context: { promptValues: string[] },
) => boolean | Promise<boolean>;

export const defaultIsOfflineAccessGranted: OfflineAccessGrantedCallback = (
  _request,
  { promptValues },
) => promptValues.includes('consent');
```

- コールバックの引数は `request` と `promptValues` のみ。
  **`client` が渡されない**ため、注入する側も `grant_types` を見た判定を書けない
  （クライアントを別途解決すれば書けるが、core の契約としては表現されていない）。
- `applyOfflineAccessPolicy`（`packages/core/src/authorization-request.ts:1039`）は
  このコールバックの結果だけで `offline_access` を残すか落とすかを決める。

### 4.3 生成コードは独自フラグで代替している

`samples/hono-cloudflare/src/oidc-provider/config.ts:111-115`

```ts
export type RegisteredClient = ClientInfo & TokenClientInfo & {
  offlineAccessAllowed?: boolean;
  userinfoSignedResponseAlg?: 'RS256' | 'ES256';
  idTokenSignedResponseAlg?: 'RS256' | 'ES256';
};
```

同 `config.ts:128-135`（既定の example client）:

```ts
clientType: 'confidential' as const,
offlineAccessAllowed: true,
// RFC 7591 §2: grant_types default is ["authorization_code"]. This client uses
// offline_access (refresh tokens), so it must explicitly register refresh_token.
grantTypes: ['authorization_code', 'refresh_token', 'urn:ietf:params:oauth:grant-type:token-exchange'],
```

- コメント自体が「offline_access を使うので refresh_token を明示登録せよ」と述べており、
  **2 つを手で同期させる運用**が前提になっていることが読み取れる。

`samples/hono-cloudflare/src/oidc-provider/routes/authorize.ts:401-405`（同意後の経路）:

```ts
// Filter offline_access if the client does not allow it
const clientConfig = await clientResolver.findClient(transaction.clientId);
const grantedScope = transaction.scope.split(' ').filter((s: string) => {
  if (s === 'offline_access' && !clientConfig?.offlineAccessAllowed) return false;
  return Boolean(s);
});
```

同ファイル `475-479` にも**同一のフィルタが再掲**されている（別経路）。

### 4.4 生成元テンプレートでも同じ構造

`packages/cli/src/frameworks/hono/templates.ts` の 2114 / 2188 / 3994 行、
`packages/cli/src/frameworks/web-standard/templates.ts` の 1562 行に
同じ `offlineAccessAllowed` フィルタが埋め込まれている。
`express-flyio` / `fastify-flyio` / `hono-cloudflare` の 3 sample すべてで
`config.ts` に 3 箇所、`authorize.ts` に 2 箇所ずつ出現する。

`nextjs-vercel` にも同じフィルタが存在するが、置き場所が異なる。
`samples/nextjs-vercel/src/app/consent/actions.ts:60-68`（Server Action 側）にあり、
`_oidc-provider/routes/` の外に出ている:

```ts
// Filter offline_access if the client does not allow it.
// (中略) registered-client shape that carries offlineAccessAllowed.
if (s === 'offline_access' && !clientConfig?.offlineAccessAllowed) return false;
```

つまりこの二重管理は**生成コードの構造として全 4 フレームワークに複製されており**、
Next.js では OIDC provider ディレクトリの外にまで漏れ出している。
`offlineAccessAllowed` を廃止する場合、修正対象は
「core 1 箇所」ではなく「テンプレート 4 系統 × 各 1〜3 箇所」になる。

### 4.5 Refresh Token の発行判定

`samples/hono-cloudflare/src/oidc-provider/routes/token.ts:564`

```ts
refresh_token: grantHasOfflineAccess ? generateRandomString(32) : undefined,
```

- 発行可否は `grantHasOfflineAccess`（＝認可時に `offline_access` が残ったか）のみで決まる。
- ここでも `grant_types` は参照されない。
- 一方、同じルートの前段（`token.ts:287` 付近）では
  `validateClientGrantType(tokenClient, grantType)` が呼ばれるが、
  これは**提示された grant_type**（この時点では `authorization_code`）に対する検証であり、
  「将来 refresh_token grant を使えるか」は見ていない。

### 4.6 事故 A の再現手順（コードから導かれる帰結）

1. クライアントを `offlineAccessAllowed: true`、`grantTypes` 未指定（既定 `['authorization_code']`）で登録する。
2. `scope=openid offline_access&prompt=consent` で認可リクエストを送り、同意する。
   → §4.2 の §11 条件を満たすので `offline_access` は残る。
   → §4.3 のフィルタも `offlineAccessAllowed: true` なので通す。
3. `grant_type=authorization_code` でトークンを取得する。
   → `validateClientGrantType` は `authorization_code` を許可する（既定に含まれる）。
   → §4.5 により **`refresh_token` が発行される**。
4. その Refresh Token で `grant_type=refresh_token` を叩く。
   → `validateClientGrantType`（`packages/core/src/token-request.ts:460-471`）が
   `refresh_token` を既定リストに見つけられず **`unauthorized_client`** を返す。

Refresh Token は発行されたが**一度も使えない**。ステップ 3 では警告もエラーも出ない。

## 5. 現在の実装との差分

### 満たしていること

- 🟢 OIDC Core §11 の `prompt=consent` 要件は core で正しく実装され、
  代替条件を注入する口（`OfflineAccessGrantedCallback`）も用意されている。
- 🟢 RFC 7591 §2 の `grant_types` 既定値（`["authorization_code"]`）は
  `validateClientGrantType` で正しく適用され、未登録クライアントの
  refresh_token grant は確実に `unauthorized_client` で拒否される。
  **セキュリティ境界としては破れていない**（使えないトークンが「使えてしまう」わけではない）。
- 🟢 生成コードの example client は 2 つのフラグが正しく同期された状態で提供されている。

### 不足している可能性があること

- 🟠 **標準メタデータで表現できるものを独自フラグで二重管理している**:
  `offlineAccessAllowed` は `grantTypes.includes('refresh_token')` から導出できるはずの情報。
  独自フラグは Dynamic Client Registration（`study-material/ext-dynamic-client-registration.md`）を
  将来導入する際に**登録リクエストで表現できない**（標準の登録メタデータに存在しないため）。
- 🟠 **使えない Refresh Token を発行しうる（事故 A）**: 発行時点で検知されず、
  クライアントが実際に使うまで失敗しない。PoC のデバッグとして最も苦しい種類の失敗。
- 🟡 **`offline_access` が黙って落ちる（事故 B）**: クライアントは token response の
  `scope` から推測するしかない。RFC 6749 §3.3 の「付与 scope を返す」は満たしているので
  検知**可能**だが、理由（クライアント未許可なのか、`prompt=consent` 不足なのか）は分からない。
- 🟡 **`OfflineAccessGrantedCallback` に `client` が渡らない**: 利用者が
  「クライアント登録を見た判定」を注入しようとしても、契約上クライアントを受け取れない。
- 🟡 **フィルタが生成コードに重複している**: 1 sample あたり 2 箇所、
  テンプレートに 4 箇所。片方だけ改造した利用者が経路によって挙動が変わる状態を作りうる。

### 実装はあるが仕様上の確認が必要なこと

- 🟡 `offlineAccessAllowed` と `grantTypes` を**あえて分けている**設計意図があるか。
  例えば「refresh_token grant は許すが、offline_access（＝ユーザー不在時のアクセス）は
  許さない」という区別に意味を見出しているなら、二重管理は正当化される。
  ただし現状のコメント（§4.3）は「offline_access を使うので refresh_token を登録せよ」と
  **一方向の依存**として書かれており、独立した軸としては扱われていないように読める。

### セキュリティ上、改善した方がよいこと

- 🟡 **不要な長期資格情報の配布**（事故 A）: RFC 9700 §4.14 の趣旨に照らすと、
  使えない Refresh Token をクライアントに保存させるのは、
  価値ゼロで攻撃面だけを増やす。漏洩しても悪用できないため実害は小さいが、
  「発行された長期トークンは使える」という運用者の前提を裏切る。
- 🟢 **権限昇格の経路にはならない**: 事故 A は fail-closed（使おうとすると拒否される）なので、
  未許可クライアントが Refresh Token を悪用できるわけではない。

### 相互運用性の観点で改善した方がよいこと

- 🟡 標準クライアントライブラリは `offline_access` を要求して Refresh Token を受け取ったら
  「これで長期アクセスができる」と扱う。使えないトークンを返すと、
  ライブラリのトークン更新ロジックが起動した時点で初めて壊れる。
- 🟡 Dynamic Client Registration を導入する場合、`offlineAccessAllowed` は
  標準の登録リクエストに対応するフィールドが無いため、
  登録経由で作られたクライアントは常に `offlineAccessAllowed: undefined`（＝拒否）になる。
  この非互換は DCR 実装時に必ず問題化する。

### Basic OP として提供する上で確認すべきこと

- 🟢 **Basic OP 認定の必須要件ではない**。Basic OP のテストは
  `offline_access` とクライアント登録の整合を検証しない。
- 🟡 ただし各 sample の `conformance.test.ts` は「本リポジトリが想定する挙動」を
  利用者に示す契約テストであり、現状「2 つのフラグが同期されている前提」でしか
  テストされていない。**ずれた状態の挙動が契約として固定されていない**。
  （§4.4 で確認したとおり、テストフィクスチャは常に両方を揃えて設定している）

## 6. 改善・追加を検討する理由

### なぜこの改善を検討すべきなのか

1. **設定事故が silent である**。本リポジトリのターゲットは「PoC 開発者・本番導入を見据える開発者」。
   その層が最初にやることはクライアント登録の書き換えであり、
   `grantTypes` を書き忘れる／`offlineAccessAllowed` を書き忘れるのは
   **最も起きやすい設定ミス**。それが発行時に検知されず、
   数分〜数時間後の token refresh で初めて `unauthorized_client` として現れる。
2. **標準メタデータへの一本化は将来の拡張の前提**。DCR / クライアント管理 API
   （`study-material/ext-dynamic-client-registration-management-rfc7592.md`）を進めるなら、
   独自フラグは必ず障害になる。
3. **core の型の非対称が原因**。`ClientInfo` に `responseTypes` があって `grantTypes` が無いのは
   設計上の抜けに見える。ここを埋めれば独自フラグを廃止できる。

### Basic OP として必要なのか、それとも拡張機能として有用なのか

- **Basic OP 認定としては不要**。
- **本リポジトリの製品品質としては重要**。「使えない Refresh Token が出る」は
  利用者から見れば明確なバグ体験であり、Fidelity を掲げる立場と噛み合わない。
- **DCR 拡張の前提整備**としても価値がある。

### 現在のリポジトリ構成から見て、なぜ導入しやすい／しにくいか

- 🟢 **導入しやすい理由**: `ClientInfo` に `grantTypes?: string[]` を optional で足すのは
  後方互換な変更。`TokenClientInfo` に既に同名・同型のフィールドがあるので、
  `RegisteredClient = ClientInfo & TokenClientInfo` という既存の合成型でも衝突しない。
- 🟡 **注意が要る理由**: `offlineAccessAllowed` を廃止すると、
  既存の生成コードを使っている利用者の `config.ts` が**意味を失う**（無視される）。
  黙って無視すると事故 B と同じ silent failure を作るので、
  移行期は「両方見る」か「`offlineAccessAllowed` が指定されていたら警告」が要る。
- 🟡 CLI テンプレート 4 箇所＋ sample 3 つ分の再生成が必要（`packages/cli` を直して再生成する運用）。

### 既存実装とどのように接続できそうか

- `OfflineAccessGrantedCallback` の第 2 引数（context）に `client: ClientInfo` を追加すれば、
  既定実装を「`prompt=consent` かつ `grantTypes` に `refresh_token` を含む」に変えられる。
  シグネチャ変更は context オブジェクトへのフィールド追加なので**後方互換**。
- 生成コードの `offlineAccessAllowed` フィルタ（§4.3）は、
  core 側で判定するようになれば**まるごと削除**できる。重複も同時に解消する。

### 利用者・開発者・運用者にどのようなメリットがあるか

- **利用者**: 設定箇所が 1 つになる。`grantTypes: ['authorization_code', 'refresh_token']` と
  書けば Refresh Token が使える、という標準どおりの直感が通る。
- **開発者**: 生成コードから重複フィルタが 2〜4 箇所消える。
  DCR 実装時に独自フラグの互換問題を抱えずに済む。
- **運用者**: 「発行されたのに使えない Refresh Token」という問い合わせが構造的に消える。

### 実装しない場合にどのような制約やリスクが残るか

- 事故 A / B が残り続ける。特に事故 A は PoC のデバッグを著しく困難にする。
- DCR を導入した時点で、登録経由クライアントが `offline_access` を一切使えなくなる。
- 生成コードのフィルタ重複が残り、利用者の改造で経路ごとに挙動が割れるリスクが残る。

## 7. 実装方針の候補

> 最終判断は人間が行う。特に「独自フラグを廃止するか残すか」は後方互換の判断を伴う。

### 方針A（`ClientInfo` に `grantTypes` を追加し、core で判定する）— 標準メタデータへ一本化

- `ClientInfo` に `grantTypes?: string[]`（既定 `['authorization_code']`）を追加。
- `OfflineAccessGrantedCallback` の context に `client` を追加。
- `defaultIsOfflineAccessGranted` を
  「`promptValues.includes('consent')` **かつ** `grantTypes` に `refresh_token` を含む」に変更。
- 生成コードから `offlineAccessAllowed` とフィルタを削除。
- メリット: 設定が 1 箇所に集約。DCR と自然に接続。重複が消える。
- 注意: 既定判定を厳しくするので、`grantTypes` 未指定のまま `offline_access` を
  使っていた利用者の挙動が変わる（＝事故 A の状態が「発行されない」に変わる）。
  これは**望ましい方向の変更**だが、破壊的変更として告知が要る。

### 方針B（両方を見る移行モード）

- 方針 A を入れつつ、`offlineAccessAllowed` が明示的に指定されていれば
  それを優先し、同時に「非推奨。`grantTypes` に `refresh_token` を追加してください」と警告する。
- メリット: 既存利用者の挙動を壊さない。
- 注意: 二重管理が当面残る。警告をどこに出すか（生成コードの起動時 console など）の設計が要る。

### 方針C（発行時に不整合を検知してエラーにする）— 最小の安全網

- 型・フラグ構造は変えず、Refresh Token を発行する直前に
  「クライアントの `grantTypes` に `refresh_token` が無ければ発行しない（または server_error）」
  というガードを 1 つ入れる。
- メリット: 変更が最小。事故 A の silent failure だけを潰せる。
- 注意: 二重管理は残る。ただし「使えないトークンを配らない」という
  最重要の症状は消えるため、方針 A への繋ぎとして有効。

### 方針D（現状維持＋明文化）

- `offlineAccessAllowed` と `grantTypes` は独立した軸であると定義し、
  両方の設定が必要であることを README / テンプレートコメント / `conformance.test.ts` で明示する。
- 不整合時の挙動（事故 A / B）を契約テストで固定する。
- メリット: 実装変更ゼロ。設計意図を残せる。
- 注意: 事故 A の silent failure は残る。DCR 導入時に再検討が必要になる。

### 判断材料

- 症状の深刻さ（silent に使えないトークンが出る）に対して、
  **方針 C は極めて低コストで最も効く**。まず C を入れて A を計画するのが現実的。
- 方針 A は「設定を標準に寄せる」という筋の良い方向だが、
  既定判定を厳しくするため v0.x の破壊的変更ポリシー
  （`study-material/RELEASE-v0.x-scope.md` / `RELEASE.md`）との整合確認が要る。
- `offlineAccessAllowed` を独立軸として残す意味があるか（§5 の確認事項）を
  先に決めないと、A と D のどちらが正しいかが決まらない。**ここが最初の分岐**。
- いずれの方針でも、`conformance.test.ts` に「不整合設定時の挙動」を追加して
  契約として固定する価値がある（CLAUDE.md の conformance テスト方針に沿う）。

## 8. 未確認・不明点

- `offlineAccessAllowed` を独自フラグとして導入した当初の設計意図は、
  コードとコメントからは「`grant_types` の代替」としか読み取れなかった。
  意図的に独立軸として設計したのであれば方針 D が正しくなるため、
  この点は実装者（人間）の判断が必要。
- Next.js テンプレートだけフィルタが `_oidc-provider/` の外（`src/app/consent/actions.ts`）に
  置かれている理由は、Server Action で同意処理を実装している構造上の都合と思われるが、
  意図的な配置かは未確認。`offlineAccessAllowed` を廃止する際は、
  この 4 系統目の置き場所を見落とさないこと。

## 9. タスク案

- [ ] RFC 7591 §2 / OIDC DCR §2 の `grant_types` 逐語定義と既定値を一次資料で確認する
- [ ] OIDC Core §11 の `offline_access` 逐語を一次資料で確認する
- [ ] `offlineAccessAllowed` を `grantTypes` と独立した軸として残すかを人間が判断する（最初の分岐）
- [ ] `offlineAccessAllowed` を廃止する場合、Next.js テンプレートのフィルタが
      `_oidc-provider/` の外（`src/app/consent/actions.ts`）にある点を修正対象に含める
- [ ] 方針 A / B / C / D のいずれを採るかを人間が判断する
- [ ] 方針 C（安全網）を採る場合の実装:
  - [ ] Refresh Token 発行直前に `grantTypes` に `refresh_token` が含まれることを検証する
  - [ ] 含まれない場合の挙動（発行しない / server_error）を決めてテストで固定する
  - [ ] `packages/cli` のテンプレートに反映し、全 sample を再生成する
- [ ] 方針 A（標準メタデータへ一本化）を採る場合の実装:
  - [ ] `ClientInfo` に `grantTypes?: string[]` を追加する（既定 `['authorization_code']`）
  - [ ] `OfflineAccessGrantedCallback` の context に `client` を追加する（後方互換）
  - [ ] `defaultIsOfflineAccessGranted` を `prompt=consent` かつ `refresh_token` 登録済みに変更する
  - [ ] 生成コードから `offlineAccessAllowed` とフィルタ（1 sample あたり 2 箇所）を削除する
  - [ ] `RegisteredClient` 型から `offlineAccessAllowed` を削除する
  - [ ] 破壊的変更として changeset と `RELEASE.md` の移行手順を用意する
- [ ] テスト要件（TDD で先に Red を作る）:
  - [ ] `should not issue a refresh token when the client does not register the refresh_token grant type`
  - [ ] `should issue a refresh token when the client registers refresh_token and prompt=consent is present`
  - [ ] `should still drop offline_access when prompt=consent is absent even if refresh_token is registered`
        （§11 の条件が独立に効くことを固定する）
  - [ ] `should return the granted scope without offline_access when the client is not authorized`
        （RFC 6749 §3.3 の付与 scope 通知）
  - [ ] 各 sample の `conformance.test.ts` に「不整合設定時に使えない RT を発行しない」ケースを追加する
- [ ] 完了条件: `pnpm --filter @maronn-openid-connect/core test`、`pnpm --filter @maronn-openid-connect/cli test`、
      および全 sample の `conformance.test.ts` がパスすること

## 関連トピック

- `study-material/offline-access-scope-grant-policy.md`（§11 の付与条件そのもの）
- `study-material/done/client-metadata-enforcement.md`（トークンエンドポイント側の `grant_types` 強制）
- `study-material/ext-dynamic-client-registration.md`（独自フラグが障害になる将来の拡張）
- `study-material/refresh-token-grant-scope-preservation.md`（rotation 後の scope 保持）
