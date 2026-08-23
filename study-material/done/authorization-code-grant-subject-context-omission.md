# `authorization_code` グラント検証結果に `subject` / `auth_time` が含まれない（core 契約の非対称）

## ステータス

🟠 High（API 契約 / 堅牢性）/ 未着手

## 1. このトピックで確認したいこと

core の Token Endpoint 検証は、grant ごとに「バリデーション済みリクエスト」を返す判別共用体 `ValidatedTokenRequest` を持つ。

- `ValidatedRefreshTokenRequest` は `subject` / `authTime` / `nonce` / `acr` / `amr` / `azp` を**含む**
- `ValidatedAuthorizationCodeRequest` は `subject` も `authTime` も**含まない**

その結果、生成 OP は認可コードを `consumeAuthorizationCode`（`used=true` 化）した**直後に、同じ認可コードをストアからもう一度読み直して** `subject` / `authTime` を取り出している。core の型が返さない情報を、呼び出し側が消費済みレコードの再取得で補っている状態である。

確認したいのは次の点。

- なぜ 2 つの grant で「呼び出し側が受け取れる認証コンテキスト」が非対称なのか（意図的な設計か、単なる欠落か）
- 消費済み認可コードの再取得に依存する構造が、ストア実装の契約にどんな追加要求を課しているか
- `AuthorizationCodeInfo`（core の resolver 戻り値型）に `subject` / `authTime` が無いことで、`AuthorizationCodeResolver` を独自実装する利用者が何を強いられるか

### 既存ファイルとの関係（重複回避）

| 論点 | 扱っているファイル |
|---|---|
| 認可コードを `used=true` にする契約（物理削除禁止）と再利用時の cascade 失効 | `study-material/done/authorization-code-reuse-cascade-store-semantics.md`、`tasks/done/p1-revoke-mark-used-contract-and-reuse-cascade-regression.md` |
| 「いつ」used=true にするか（発行成功の前か後か）という原子性の非対称 | `study-material/authorization-code-consumption-timing-vs-issuance-atomicity.md` |
| resolver / store インターフェース全般の契約整理 | `study-material/resolver-and-store-contract.md` |
| トークン値の採番抽象が grant 間で非対称であること | `study-material/token-value-minting-abstraction-asymmetry.md` |
| `revokeRefreshToken` の命名衝突と delete セマンティクス | `study-material/done/resolver-revoke-refresh-token-name-collision.md`、`tasks/p2-revocation-resolver-contract-jsdoc-and-delete-semantics-test.md` |

**本ファイル固有の差分**は「`ValidatedAuthorizationCodeRequest` / `AuthorizationCodeInfo` という**型が運ぶ情報**の欠落」である。上記のどのファイルも、消費タイミング・delete セマンティクス・cascade は扱っているが、「検証結果の型に `subject` が無いために再取得が必要になっている」ことは扱っていない（`subject` / `authTime` で grep して該当なし）。

## 2. 関連する仕様・基準

これは特定の RFC 条文の違反ではなく、**仕様が要求する情報を core の API がどこまで運ぶか**という設計契約の問題である。関連する規範は次のとおり。

### 2.1 認可コードが「認証されたエンドユーザー」に紐づくこと

- **RFC 6749 §4.1 / OAuth 2.1 §4.1**: 認可コードは「resource owner の認可」を表す短命な資格情報である。Token Endpoint はコードと引き換えにトークンを発行する。したがってコードから resource owner（OIDC では `sub`）が特定できることが前提になる
- **OIDC Core 1.0 §2（ID Token）**: `sub` は REQUIRED クレーム。authorization_code grant のトークンレスポンスには ID Token が必須（§3.1.3.3）なので、Token Endpoint は必ず `sub` を知らねばならない
- **OIDC Core 1.0 §2 / §3.1.2.1（`auth_time`）**: `auth_time` はエンドユーザー認証が行われた時刻。`max_age` が要求された場合、または `require_auth_time` が登録されている場合は REQUIRED。これも認可時点で確定し、Token Endpoint まで運ぶ必要がある

すなわち **`sub` と `auth_time` は「認可コードに必ず紐づいていなければならない情報」** であり、grant 固有の任意情報ではない。

### 2.2 `refresh_token` グラント側で core が既に採っている設計

`ValidatedRefreshTokenRequest` は `subject` / `authTime` / `nonce` / `acr` / `amr` / `azp` / `originalIssuedAt` / `hadOfflineAccess` を返す。JSDoc は OIDC Core §12.1（refresh で再発行する ID Token は初回認証時の値を保持する）を根拠として挙げている。

つまり core は refresh 側で「呼び出し側が ID Token を組み立てるのに必要な認証コンテキストは、検証結果に含めて返す」という設計判断を既に下している。authorization_code 側だけがその判断から外れている。

### 2.3 認可コードストアの契約

`AuthorizationCodeResolver.revokeAuthorizationCode` の JSDoc は次を要求している（既存ファイルで確定済みの契約）。

> このメソッドはレコードを削除せず `used=true` に更新する（できればアトミックに）。
> `findAuthorizationCode` は**少なくとも元の認可コード TTL の間は、used:true のレコードを返し続ける**（TTL 経過後の eviction は許容）。

この契約は**再利用検知（cascade 失効）のため**に定められている。本トピックが指摘するのは、生成 OP がこの契約に**別の理由でも依存している**点である。すなわち「消費直後に自分自身が読み直すため」であり、この依存は JSDoc のどこにも書かれていない。

## 3. 参照資料

- **RFC 6749 §4.1.2 / §4.1.3** — https://www.rfc-editor.org/rfc/rfc6749#section-4.1.2 （認可コードと resource owner の関係、Token Request の交換）
- **OAuth 2.1 draft §4.1.2 / §4.1.3** — https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1 （single-use 認可コード、再利用時の失効 SHOULD）
- **OpenID Connect Core 1.0 §2 ID Token** — https://openid.net/specs/openid-connect-core-1_0.html#IDToken （`sub` は REQUIRED、`auth_time` は `max_age` 要求時 / `require_auth_time` 登録時に REQUIRED）
- **OpenID Connect Core 1.0 §3.1.3.3 Successful Token Response** — https://openid.net/specs/openid-connect-core-1_0.html#TokenResponse （authorization_code grant は `id_token` を含む）
- **OpenID Connect Core 1.0 §12.1** — https://openid.net/specs/openid-connect-core-1_0.html#RefreshingAccessToken （refresh の ID Token が保持すべきクレーム。refresh 側の設計根拠）
- 本リポジトリ内: `packages/core/src/token-request.ts`（`AuthorizationCodeInfo` / `ValidatedAuthorizationCodeRequest` / `ValidatedRefreshTokenRequest` / `AuthorizationCodeResolver`）、`packages/core/src/authorization-code-grant.ts`（`buildValidatedAuthorizationCodeRequest`）、`packages/core/src/authorization-code.ts`（`AuthorizationCodeData`）

## 4. 現在の実装確認

### 4.1 型の差分

`packages/core/src/authorization-code.ts` の `AuthorizationCodeData`（**発行時**のデータ）は `subject` と `authTime` を持つ。

```ts
export interface AuthorizationCodeData {
  code: string; grantId: string; clientId: string;
  redirectUri: string; redirectUriExplicit: boolean;
  scope: string[];
  subject: string;          // ← 持っている
  codeChallenge?: string; codeChallengeMethod?: 'S256';
  used: boolean; expiresAt: number;
  nonce?: string;
  authTime?: number;        // ← 持っている
  audience?: string[]; acrValues?: string; claims?: ClaimsParameter;
}
```

一方 `packages/core/src/token-request.ts` の `AuthorizationCodeInfo`（**Token Endpoint で resolver が返す**型）には `subject` も `authTime` も存在しない。

```ts
export interface AuthorizationCodeInfo {
  code: string; grantId: string; clientId: string;
  redirectUri: string; redirectUriExplicit: boolean;
  scope: string[];
  codeChallenge?: string; codeChallengeMethod?: 'S256';
  expiresAt: number; used: boolean;
  nonce?: string; audience?: string[]; acrValues?: string; claims?: ClaimsParameter;
  // subject / authTime は無い
}
```

`buildValidatedAuthorizationCodeRequest`（`packages/core/src/authorization-code-grant.ts`）も、入力の `AuthorizationCodeInfo` に無いものは当然返せない。

```ts
return {
  grantType: 'authorization_code',
  clientId: authenticatedClientId,
  code, grantId: authorizationCode.grantId,
  redirectUri: authorizationCode.redirectUri,
  scope: authorizationCode.scope,
  nonce: authorizationCode.nonce,
  audience: authorizationCode.audience,
  acrValues: authorizationCode.acrValues,
  claims: authorizationCode.claims,
  codeVerified,
};   // subject / authTime を返さない
```

対して `buildValidatedRefreshTokenRequest`（`packages/core/src/refresh-token-grant.ts`）は `subject: refreshTokenInfo.subject` / `authTime: refreshTokenInfo.authTime` を返す。

### 4.2 生成 OP が行っている回避策

`packages/cli/src/frameworks/hono/templates.ts` の token ルートは、検証パイプラインで `consumeAuthorizationCode(code, authorizationCodeResolver)` を呼んだ**後**に、次のコードを実行する。

```ts
let subject: string;
let authTime: number | undefined;
let nonce: string | undefined;

if (validatedRequest.grantType === 'authorization_code') {
  const authCode = await authCodeStore.get(validatedRequest.code);   // ← 消費済みコードを再取得
  if (!authCode?.subject || !authCode.authTime) {
    throw new TokenError(
      TokenErrorCode.InvalidGrant,
      'Authorization code missing required subject context',
    );
  }
  subject = authCode.subject;
  authTime = authCode.authTime;
  nonce = validatedRequest.nonce;
} else {
  subject = validatedRequest.subject;      // ← refresh 側は型から直接取れる
  authTime = validatedRequest.authTime;
  nonce = undefined;
}
```

観察できること。

1. **同じレコードを 2 度読んでいる**。検証パイプラインの `resolveAuthorizationCode` が既に `authorizationCode`（`AuthorizationCodeInfo`）を手に持っているのに、その情報が `validatedRequest` に載らないため、`authCodeStore` から生データを再取得している
2. **読み直しの対象は既に `used=true` にされたレコード**である。`revokeAuthorizationCode` が物理削除で実装されていると `authCode` が `null` になり、`invalid_grant` になる
3. **2 つの抽象を跨いでいる**。検証は `authorizationCodeResolver`（core のインターフェース）経由、再取得は `authCodeStore`（生成コード側の具象ストア）経由。両者が同じレコードを指す保証は生成コードの構成でしか担保されていない
4. **`!authCode.authTime` は 0 を falsy として扱う**。`authTime` は Unix epoch 秒なので実運用で 0 にはならないが、型上は `number | undefined` であり、存在チェックとしては不正確

### 4.3 独自 resolver を書く利用者への影響

core の公開 API だけを使う（CLI 生成コードを使わない）利用者が `validateTokenRequest` を呼ぶ場合、authorization_code grant の戻り値からは `sub` を得られない。ID Token を組み立てるには `sub` が必須（§2）なので、利用者は必然的に次のいずれかを行う。

- `AuthorizationCodeResolver.findAuthorizationCode` を呼ぶ前に、自前で認可コードから `subject` を控えておく
- `validateTokenRequest` の後に自前ストアから読み直す（生成コードと同じ回避策）
- `AuthorizationCodeInfo` を拡張した独自型を返し、`as` でキャストして使う

いずれも「core が返すべき情報を利用者が補う」形であり、`docs`（`packages/core` の README / JSDoc）にはこの手順が明示されていない。

## 5. 現在の実装との差分

### 満たしていること

- 認可コード発行時（`createAuthorizationCode`）には `subject` / `authTime` が確実に保存される
- 生成 OP は再取得によって最終的に正しい `sub` / `auth_time` を ID Token に載せている（挙動としては正しい）
- refresh 側は必要な認証コンテキストを型で返せており、あるべき設計の実例が同じファイル内に存在する

### 不足している可能性があること

- 🟠 **`AuthorizationCodeInfo` に `subject` / `authTime` が無い**。core の resolver 契約が「認可コードに紐づく resource owner」を運ばないため、Token Endpoint の検証結果から `sub` を得られない
- 🟠 **`ValidatedAuthorizationCodeRequest` に `subject` / `authTime` が無い**。refresh 側との非対称であり、判別共用体を扱う呼び出し側コードが grant ごとに別経路の実装を強いられる
- 🟡 **契約が文書化されていない**。「消費後に読み直せる」ことに生成コードが依存しているが、`revokeAuthorizationCode` の JSDoc にはその理由が書かれていない（書かれているのは cascade 失効の理由のみ）

### 実装はあるが仕様上の確認が必要なこと

- 🟡 **`AuthorizationCodeData` と `AuthorizationCodeInfo` の役割分担**。`AuthorizationCodeData` の JSDoc は「`AuthorizationCodeInfo` は Token Endpoint で引き当てる**最小情報**」「`AuthorizationCodeData` はそれを包含する完全形」と述べており、非対称は**意図的**である可能性がある。しかしその「最小」の線引きが `sub` を落としているのは、ID Token 発行が必須である OIDC の Token Endpoint としては不自然である。この設計意図が現在も妥当かを確認したい
- 🟡 **`authTime` が optional であること**。`AuthorizationCodeData.authTime?: number` は optional だが、生成 OP は refresh token 発行時に `authTime === undefined` を `invalid_grant` で弾いている。`auth_time` が必須になる条件（`max_age` 要求時 / `require_auth_time`）と、常に保存する現在の実装との関係を整理する余地がある

### セキュリティ上、改善した方がよいこと

- 🟠 **消費済みレコードの再取得への暗黙依存**。利用者が `revokeAuthorizationCode` を「物理削除」で実装すると、cascade 失効が効かなくなる（既存ファイルが指摘済み）だけでなく、**正常なトークン発行そのものが `invalid_grant` で失敗する**。後者は前者と違ってすぐ気付ける失敗ではあるが、「なぜ失敗するか」が JSDoc から辿れない
- 🟡 **TOCTOU の余地**。検証時に読んだ `authorizationCode` と、再取得した `authCode` は別タイミングのスナップショットである。並行リクエストや外部からの失効が挟まると、検証に使ったレコードと `sub` を取ったレコードが一致しない理論上の窓がある。実害の有無はストア実装依存だが、1 回読みなら存在しない窓である

### 相互運用性の観点で改善した方がよいこと

- 🟢 直接の相互運用性（プロトコル上の挙動）への影響は無い。影響するのは core を直接使う開発者体験と、生成コードを改造する利用者の安全性

### Basic OP として提供する上で確認すべきこと

- Basic OP の認定要件そのものには影響しない。ただし CLAUDE.md が掲げる「`core` はロジック層（高度な組み込みユースケース向け）」という位置づけに照らすと、**組み込み利用者が最も必要とする情報（`sub`）を返さないロジック層**は看板と実態がずれている

## 6. 改善・追加を検討する理由

### なぜ価値があるのか

- **core を直接使うユースケースの実用性が上がる**。CLAUDE.md は `core` を「高度な組み込みユースケース向け」と定義している。その利用者が最初に躓くのが「`sub` がどこにもない」であるのは、ライブラリの入口として不親切
- **生成コードから危うい依存を取り除ける**。消費済みレコードの再取得は、動くが説明が要る構造である。1 回読みに統一すれば、利用者が生成コードを改造するときの事故が減る
- **判別共用体の扱いが揃う**。`ValidatedTokenRequest` を `switch (grantType)` で分岐する利用者コードが、どちらの枝でも同じフィールド名で `subject` / `authTime` を取れる

### Basic OP として必要か、拡張機能として有用か

- **どちらでもない**。仕様が要求する挙動は既に満たされており、これは**内部 API の契約整備**である。優先度は「MUST 違反の解消」より下、「利用者体験・堅牢性の改善」として位置づけるのが妥当

### 現在のリポジトリ構成から見た導入しやすさ

- **導入しやすい点**:
  - `AuthorizationCodeData`（発行側）には既に `subject` / `authTime` がある。resolver が返す型に足すだけで、データの流れは既に成立している
  - 生成 OP の `authCodeStore.get` は `AuthorizationCodeData` を返しており、`AuthorizationCodeInfo` として渡す際に情報を捨てているだけ。ストア実装の変更は不要
  - `buildValidatedAuthorizationCodeRequest` は純関数で、引数に `authorizationCode` を既に受け取っている
- **導入しにくい点**:
  - `AuthorizationCodeInfo.subject` を **必須**にすると、独自 resolver を実装済みの利用者にとって破壊的変更になる（型エラー）。optional にすると呼び出し側が結局 `undefined` を扱う必要が残り、非対称が完全には解消しない
  - `ValidatedAuthorizationCodeRequest.subject` を必須にする場合、`AuthorizationCodeInfo.subject` が optional だと型が繋がらない。「resolver が返さなかったら何を返すか」を決める必要がある

### 既存実装との接続

- `packages/core/src/token-request.ts`: `AuthorizationCodeInfo` / `ValidatedAuthorizationCodeRequest` の定義変更点
- `packages/core/src/authorization-code-grant.ts`: `buildValidatedAuthorizationCodeRequest` の転記追加点
- `packages/cli/src/frameworks/hono/templates.ts`: 再取得ブロックの削除点（`subject` / `authTime` を `validatedRequest` から取る）
- `samples/*/conformance.test.ts`: 挙動が変わらないことの回帰固定（生成元は `packages/cli`）

### 利用者・開発者・運用者のメリット

- core を直接使う利用者: `sub` を得るための追加手順が不要になる
- 生成コードを改造する利用者: `authCodeStore` への 2 度目のアクセスが消え、ストア差し替え時の考慮点が 1 つ減る
- 保守: refresh / authorization_code で対称なコードになり、token ルートの分岐が縮む

### 実装しない場合に残る制約・リスク

- 独自 resolver を書く利用者が毎回同じ回避策を再発明する
- `revokeAuthorizationCode` を物理削除で実装した利用者が、cascade 失効の欠落（既知）に加えて**トークン発行そのものの失敗**にも遭遇する。原因の説明が JSDoc に無い
- 生成コードを他フレームワークへ移植する際、「なぜ 2 度読むのか」を毎回説明する必要が残る

## 7. 実装方針の候補

**最終判断は人間が行う。以下は判断材料の整理である。**

### 方針 A: `AuthorizationCodeInfo` に `subject: string` / `authTime?: number` を必須・任意で追加する

- 変更: core の型 2 つ（`AuthorizationCodeInfo` / `ValidatedAuthorizationCodeRequest`）と `buildValidatedAuthorizationCodeRequest`。生成 OP の再取得ブロックを削除
- 利点: 最も素直。refresh 側と完全対称になる。データの流れは既に存在するので実装量は小さい
- 欠点: `subject` を必須にすると独自 resolver 実装者に破壊的変更。semver 上は minor か major かの判断が要る（`RELEASE.md` の方針との整合を確認すること）
- 補足: `authTime` を optional のままにするか必須にするかは別途判断。`AuthorizationCodeData.authTime?` が optional である現状と、生成 OP が実質必須として扱っている現状のどちらに寄せるか

### 方針 B: `subject` / `authTime` を optional で追加し、無ければ従来どおり呼び出し側が補う

- 利点: 非破壊。既存 resolver はそのまま動く
- 欠点: 呼び出し側の `undefined` 分岐が残り、非対称は「型の上では」解消しない。生成 OP から再取得を消せない（`undefined` のときのフォールバックが要る）
- 補足: 移行期間を置いて A へ進む中間状態としては成立する

### 方針 C: 型は変えず、契約を文書化するだけ

- 変更: `AuthorizationCodeResolver.revokeAuthorizationCode` / `AuthorizationCodeInfo` の JSDoc に「Token Endpoint は消費後に `subject` を再取得する前提である」ことを明記。`packages/core` の README にも追記
- 利点: 破壊的変更ゼロ。実装リスク最小
- 欠点: 構造上の非対称と 2 度読みは残る。core 直接利用者の負担は変わらない

### 方針 D: `validateTokenRequest` が resolver の生データも一緒に返す

- 変更: 戻り値を `{ validated, raw }` のような形にする、あるいは `ValidatedAuthorizationCodeRequest` に `authorizationCode: AuthorizationCodeInfo` を丸ごと載せる
- 利点: 将来 `AuthorizationCodeInfo` にフィールドが増えても型追従が不要
- 欠点: 「バリデーション済みリクエスト」という型の意味が曖昧になる。refresh 側との対称性はむしろ崩れる

### 横断的な論点

- **`AuthorizationCodeData` と `AuthorizationCodeInfo` を統合すべきか**。2 つの型が「発行時」「検証時」で分かれている設計意図（`AuthorizationCodeData` の JSDoc に記載）を維持するか、1 つにまとめるかは、本トピックの範囲を超える大きめの判断になる。まとめる場合は `study-material/resolver-and-store-contract.md` と併せて検討する
- **破壊的変更の扱い**。`packages/core` は experimental ではないため、changeset の bump 種別（minor / major）を `RELEASE.md` の方針に照らして決める必要がある

## 8. タスク案

- [ ] **設計判断**: 方針 A / B / C / D のいずれを採るかを決める。A・B を採る場合は `subject` を必須にするか optional にするかも決める
- [ ] **`AuthorizationCodeInfo` の拡張**: `subject` / `authTime` を追加し、JSDoc に「発行時に確定した認証コンテキスト。ID Token の `sub` / `auth_time` の源」であることを明記する
- [ ] **`buildValidatedAuthorizationCodeRequest` の更新**: `subject` / `authTime` を `ValidatedAuthorizationCodeRequest` へ転記する
- [ ] **生成テンプレートの更新**: `packages/cli/src/frameworks/hono/templates.ts` の token ルートから `authCodeStore.get(validatedRequest.code)` による再取得を削除し、`validatedRequest` から直接取るようにする（`packages/cli` を変更すること。`samples/*/src/oidc-provider` を直接編集しない）
- [ ] **テスト（core）**:
  - [ ] `should return the subject stored on the authorization code`
  - [ ] `should return the auth_time stored on the authorization code`
  - [ ] `should expose subject on both grant types of ValidatedTokenRequest`（判別共用体の対称性を型と実行時の両方で固定）
- [ ] **テスト（生成 OP / conformance）**: `samples/*/conformance.test.ts` に、authorization_code grant の ID Token の `sub` / `auth_time` が認可時の値と一致することを固定するケースを追加（生成元は `packages/cli`）
- [ ] **回帰確認**: `revokeAuthorizationCode` を物理削除で実装したストアでも、トークン発行が成功する（= 再取得依存が消えている）ことをテストで確認する。cascade 失効が効かなくなる点は従来どおり別テストで検知される
- [ ] **ドキュメント**: `AuthorizationCodeResolver` の JSDoc から「消費後の再取得が必要」という暗黙の前提が消えたことを反映する
- [ ] **リリース**: 破壊的変更を含む場合は changeset の bump 種別を `RELEASE.md` の方針に照らして決め、CHANGELOG に移行手順を書く
