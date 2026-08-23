# Revocation エンドポイントのレスポンス形状が生む「トークン存在オラクル」と RFC 7009 §5 の対策要件

## ステータス

🟡 方針未確定（RFC 準拠を保つか、情報漏洩を減らすかのトレードオフ判断が必要）

## 1. タイトル

RFC 7009 Token Revocation エンドポイントで、「未知のトークン → `200 OK`」「他クライアントのトークン → `400 invalid_grant`」という**レスポンス形状の差**が、認証済みクライアントに対する**トークン存在オラクル**として機能する点の確認と、RFC 7009 §5 が MUST で要求する対策の適用範囲の整理。

## 2. このトピックで確認したいこと

RFC 7009 は 2 つの規定を同時に置いている。

- §2.2: 無効なトークンでも `200 OK` を返す（＝存在有無を漏らさない）。
- §2.1: トークンがリクエスト元クライアントに発行されたものでなければ拒否し、**クライアントにエラーを通知する**。

現実装はどちらも忠実に実装しており、その結果として**「存在しない」と「存在するが他人のもの」が別のレスポンスになる**。これは RFC の要求どおりだが、副作用として認証済みクライアントは任意のトークン文字列について「この OP に存在するか」を 1 リクエストで判定できる。

本ファイルで確認したいのは以下。

- この差が実際に観測可能か（コード経路の確定）
- RFC 7009 / RFC 7662 がこれをどう扱っているか（許容しているのか、対策を求めているのか）
- 対策として何が MUST で、本リポジトリのどこに実装余地があるか

### 既存ファイルとの差分（重複回避）

- `study-material/rate-limiting-and-brute-force.md`
  → アプリケーション層のレート制限全般（ログイン試行、コード／トークン推測）と、ライブラリ側 vs ホスティング側の責務分界を扱う。
  → **本ファイルは「レート制限が無いこと」ではなく、「レスポンス形状そのものが情報を漏らす」という別の側面**に限定する。スロットリングの設計論は上記ファイルを参照し、本ファイルでは繰り返さない。ただし RFC 7009 §5 が**revocation エンドポイントに対して名指しで MUST を課している**点は、上記ファイルに記載が無いため本ファイルで扱う。
- `study-material/done/introspection-caller-authorization-and-disclosure.md` / `tasks/p3-introspection-caller-authorization-hook.md`
  → Introspection エンドポイントの caller 認可（誰が introspect してよいか）を扱う。
  → 本ファイルは Revocation を主対象とし、Introspection は**対比のため**にのみ触れる（Introspection は `{active:false}` に統一されており形状差が無い、という対照）。
- `study-material/client-auth-unknown-client-timing-oracle.md`
  → クライアント認証における**タイミング**差（未知クライアントの応答時間）。
  → 本ファイルは**レスポンス内容**の差であり、攻撃者の前提（認証済みクライアントであること）も異なる。
- `study-material/done/public-client-token-revocation-rfc7009.md`
  → public client が revoke できないという**機能の欠落**。本ファイルは既に revoke できるクライアントによる情報取得を扱う。

## 3. 関連する仕様・基準（このトピック固有の差分）

### 3.1 RFC 7009 §2.1 — クライアント束縛の検証（形状差の発生源）

逐語:

> The authorization server first validates the client credentials (in case of a confidential client) and then verifies whether the token was issued to the client making the revocation request.

そして検証に失敗した場合について:

> If this validation fails, the request is refused and the client is informed of the error by the authorization server as described below.

つまり**「他クライアントのトークンならエラーを返す」ことは RFC の要求**である。現実装の `invalid_grant` はこの要求に沿っている。

### 3.2 RFC 7009 §2.2 — 無効トークンは 200

逐語:

> The authorization server responds with HTTP status code 200 if the token has been revoked successfully or if the client submitted an invalid token.

理由も明記されている:

> Note: invalid tokens do not cause an error response since the client cannot handle such an error in a reasonable way.

### 3.3 §2.1 と §2.2 の合成が生む観測可能な差

上記 2 条を素直に実装すると、認証済みクライアント C が任意の文字列 T を送ったときの応答は次の 3 通りになる。

| T の状態 | 応答 | C が得る情報 |
|---|---|---|
| どのストアにも無い | `200 OK`（空ボディ） | T は存在しない |
| 存在し、C に発行された | `200 OK`（空ボディ）+ **T は失効する** | T は存在した |
| 存在し、他クライアントに発行された | `400 invalid_grant` | **T は存在する** |

3 行目だけが区別可能なので、C は「T が他クライアントのトークンとして存在するか」を判定できる。1 行目と 2 行目は区別できない（自分のトークンなら失効するので副作用で分かるが、それは自分の情報である）。

**したがって漏れる情報は「他クライアントに発行された有効なトークン文字列を、C が既に知っているかどうかの確認」に限られる。** ゼロから列挙するには当てずっぽうでトークン文字列を生成する必要があり、`generateRandomString(32)`（256 bit CSPRNG、`packages/core/src/crypto-utils.ts:65`）に対しては現実的でない。実害が出るのは、**別経路（ログ流出、リファラ、共有端末、サブドメインの XSS など）で取得した候補トークンの有効性を確認したい**場面である。

### 3.4 RFC 7009 §5 Security Considerations — 対策は MUST

RFC 7009 §5 は、トークン推測を試みる攻撃者が有効なクライアント資格情報を持つ必要があることを指摘したうえで、次を要求する。

> Appropriate countermeasures, which should be in place for the token endpoint as well, MUST be applied to the revocation endpoint.

さらに `token_type_hint` の悪用について:

> ... malicious clients could use the hint to cause additional database lookups, which could be leveraged for denial-of-service attacks.

つまり RFC 7009 は「レスポンス形状は §2.1 / §2.2 のとおりでよい。ただし**revocation エンドポイントにもトークンエンドポイント相当の対策を MUST で適用せよ**」という立て付けになっている。**形状差を許容する代わりに、レート制限等を必須にしている**と読むのが自然である。

### 3.5 RFC 7662 §2.1 / §4 — Introspection との対比

RFC 7662 §2.1 は逆に、形状を統一したうえでアクセス自体を絞る立場を取る。

> To prevent token scanning attacks, the endpoint MUST also require some form of authorization to access this endpoint, such as client authentication as described in OAuth 2.0 ...

§4 Security Considerations:

> If left unprotected and un-throttled, the introspection endpoint could present a means for an attacker to poll a series of possible token values, fishing for a valid token.

> To prevent this, the authorization server MUST require authentication of protected resources that need to access the introspection endpoint and SHOULD require protected resources to be specifically authorized to call the introspection endpoint.

現実装の Introspection は inactive を `{ active: false }` に統一しており（`packages/core/src/introspection.ts:96`）、形状差は無い。一方 caller の**個別認可**（SHOULD）は未実装で、認証済み confidential client なら誰でも introspect できる（`introspection.ts:6-16` に意図として明記）。この点は `tasks/p3-introspection-caller-authorization-hook.md` の担当。

**両エンドポイントを合わせて見ると、「有効なトークンかどうかを知る」経路は Introspection の方が直接的で情報量も多い。** したがって Revocation の形状差だけを塞いでも、Introspection の caller 認可が無い限り全体の露出は減らない。対策は 2 エンドポイントを合わせて設計する必要がある。

## 4. 参照資料

- **RFC 7009 (OAuth 2.0 Token Revocation)**
  - §2.1 Revocation Request（クライアント束縛の検証とエラー通知）— https://datatracker.ietf.org/doc/html/rfc7009#section-2.1
  - §2.2 Revocation Response（無効トークンでも 200）— https://datatracker.ietf.org/doc/html/rfc7009#section-2.2
  - §5 Security Considerations（対策の MUST、`token_type_hint` による DoS）— https://datatracker.ietf.org/doc/html/rfc7009#section-5
- **RFC 7662 (OAuth 2.0 Token Introspection)**
  - §2.1 Introspection Request（token scanning 防止のための認可要求）— https://datatracker.ietf.org/doc/html/rfc7662#section-2.1
  - §4 Security Considerations（un-throttled なエンドポイントの危険、MUST / SHOULD）— https://datatracker.ietf.org/doc/html/rfc7662#section-4
- **RFC 9700 (OAuth 2.0 Security Best Current Practice)** §2.5 / §4 — https://datatracker.ietf.org/doc/html/rfc9700
- 本リポジトリ内（重複説明を避けるための参照先）
  - `study-material/rate-limiting-and-brute-force.md`（スロットリング設計の一般論と責務分界）
  - `tasks/p3-introspection-caller-authorization-hook.md`（Introspection の caller 認可）
  - `study-material/audit-logging-and-observability.md`（検知のためのログ設計）

## 5. 現在の実装確認

### 5.1 core: 形状差の発生箇所

`packages/core/src/revocation.ts`

```ts
// L168-183: 他クライアントのトークンなら invalid_grant（400）
export function validateRevocationTokenClient(
  resolved: ResolvedRevocationToken,
  authenticatedClientId: string,
): void {
  const clientId = resolved.tokenType === 'access_token'
    ? resolved.accessToken.clientId
    : resolved.refreshToken.clientId;
  if (clientId !== authenticatedClientId) {
    throw new RevocationError(
      RevocationErrorCode.InvalidGrant,
      'Token was not issued to the requesting client',
    );
  }
}

// L234-245: どちらのストアにも無ければ何もせず正常終了（呼び出し側が 200 を返す）
export async function handleRevocationRequest(ctx) {
  ...
  const resolved = await resolveRevocationTarget({...});
  if (resolved === null) return;            // ← 200 OK
  validateRevocationTokenClient(resolved, ctx.authenticatedClientId);  // ← 400 invalid_grant
  ...
}
```

### 5.2 生成 OP: HTTP への写像

`samples/hono-cloudflare/src/oidc-provider/routes/revocation.ts`

```ts
// L105-106: RFC 7009 §2.1: a token issued to another client is refused (invalid_grant).
validateRevocationTokenClient(resolved, authenticatedClientId);
...
// L117: RFC 7009 Section 2.2: empty body, 200 OK
return c.body(null, 200);
```

`RevocationError.statusCode`（`revocation.ts:44-47`）により `invalid_grant` は 400。よって §3.3 の表のとおりの差が HTTP レベルで観測できる。

### 5.3 探索コスト側の実装

- `resolveRevocationTarget`（`revocation.ts:134-157`）は `token_type_hint` が `refresh_token` のときだけ refresh → access の順、それ以外は access → refresh の順で引く。**外れた場合は必ずもう一方も引く**ため、1 リクエストあたり最大 2 回のストア参照が発生する。RFC 7009 §5 が指摘する「hint による追加ルックアップ」の条件に一致する。
- Introspection（`introspection.ts:206-228`）も同じ構造。

### 5.4 対策の実装状況

- レート制限・スロットリング: **core にも生成 OP にも無い**（`study-material/rate-limiting-and-brute-force.md` の記載どおり）。
- 監査ログ／異常検知フック: 無い（`study-material/audit-logging-and-observability.md` の担当範囲）。
- `Retry-After` / 429 応答: 無い。
- Introspection の caller 個別認可: 無い（`tasks/p3-introspection-caller-authorization-hook.md`）。

## 6. 現在の実装との差分

### 満たしていること

- RFC 7009 §2.1 のクライアント束縛検証とエラー通知。
- RFC 7009 §2.2 の「無効トークンでも 200」。
- RFC 7662 §2.1 の「introspection にはクライアント認証を要求する」（MUST）。
- RFC 7662 §2.2 の inactive レスポンス最小化（`{ active: false }` のみ）。
- トークン値の推測困難性（256 bit CSPRNG）。

### 不足している可能性があること

- **RFC 7009 §5 の「revocation エンドポイントにもトークンエンドポイント相当の対策を MUST で適用せよ」に対応する実装・拡張点・ドキュメントが無い。** 現状は「対策はホスティング層でやってください」という方針すら明文化されていない。
- RFC 7662 §4 の「SHOULD require protected resources to be specifically authorized」が未実装（既知・別タスク）。
- `token_type_hint` の外れによる 2 回ルックアップに上限やコスト制御が無い。

### 実装はあるが仕様上の確認が必要なこと

- `invalid_grant` を返す設計は RFC 7009 §2.1 に忠実だが、**この形状差が意図的な設計判断であること**がコードコメント以外に記録されていない。利用者が生成コードを改造して 200 に統一した場合、それが RFC 逸脱であることに気づく手がかりが無い。

### セキュリティ上、改善した方がよいこと

- 認証済みクライアントによる**候補トークンの有効性確認**が無コストで無制限に行える。単体の影響は限定的だが、他の情報漏洩（ログ、URL、共有端末）と組み合わさると被害を拡大させる。
- 同じ理由で、Introspection 側の caller 認可の欠如の方が影響が大きい。**両者を合わせた「トークン有効性を問い合わせられる主体の範囲」を 1 つの設計判断として決めるべき**。

### 相互運用性の観点で改善した方がよいこと

- 形状差を無くす方向（他クライアントのトークンでも 200）へ倒すと RFC 7009 §2.1 の "the client is informed of the error" から外れる。クライアント実装が「revoke に成功した」と誤認する可能性があるため、**相互運用性の観点では現状維持が有利**。

### Basic OP として提供する上で確認すべきこと

- **Revocation / Introspection は Basic OP certification のテスト対象外**（Basic OP は authorization code flow / PKCE / ID Token / UserInfo が対象）。したがって認定合否には影響しない。本件は認定要件ではなく、OSS として配布する OP のセキュリティ品質の問題として扱う。

## 7. 改善・追加を検討する理由

- **なぜ検討する価値があるのか**: 本リポジトリは「PoC 開発者・本番導入を見据える開発者」を対象にしており、生成コードがそのまま検証環境（場合によっては社内公開環境）に置かれる。RFC が MUST を書いている対策が「無い」まま、その事実がどこにも書かれていない状態は、利用者が対策の要否を判断できないことを意味する。**実装するかどうか以前に、責務分界を明文化する価値がある。**
- **Basic OP として必要か、拡張として有用か**: **どちらでもない**。Basic OP の必須要件ではなく、機能拡張でもない。「配布物のセキュリティ既定値と、その責務分界の明示」に分類される。
- **現在の構成から見て導入しやすいか / しにくいか**:
  - **しにくい面**: 本リポジトリは production 依存に外部ライブラリを使わず、Web 標準 API のみで動くことを制約にしている。汎用のレート制限にはカウンタの永続化（KV / Redis / D1 等）が要り、実行環境ごとに実装が異なる。core が具体的な実装を持つのは方針に合わない。
  - **しやすい面**: 一方で**拡張点（フック）を置くこと**は resolver / store の注入と同じパターンで実現でき、既存構成と相性が良い。生成 OP は既に `c.get('...')` で resolver を差し替え可能な形になっている。
- **既存実装との接続**: `study-material/audit-logging-and-observability.md` が提案する監査イベントに「revocation で invalid_grant を返した」を含めれば、レート制限を実装しない利用者でも**検知**はできる。フックの粒度を揃えれば 1 つの仕組みで両方に効く。
- **利用者・開発者・運用者のメリット**: 「この OP はどこまでを自前で守り、どこからをホスティング層に委ねているか」が明示されると、本番導入検討時のリスク評価ができる。
- **実装しない場合に残るリスク**: RFC 7009 §5 の MUST に対して、リポジトリとして満たしているとも満たしていないとも言えない状態が続く。`study-material/basic-op-requirement-traceability.md` のトレーサビリティ表にも空欄が残る。

## 8. 実装方針の候補

> **最終判断は人間が行う。以下は判断材料の整理であり、推奨の確定ではない。**

### 方針 1: 形状は RFC どおり維持し、責務分界をドキュメント化するだけ

- README / 生成コードのコメント / `study-material/basic-op-requirement-traceability.md` に「RFC 7009 §5 の対策はホスティング層（WAF / API Gateway / Cloudflare Rate Limiting 等）で行う前提」と明記する。
- メリット: 実装コストがゼロ。外部依存ゼロの制約と完全に整合する。
- コスト: 利用者が自分で対策を入れる必要があり、入れ忘れても何も起きない。RFC の MUST を「委譲した」と主張できるかは解釈に依存する。

### 方針 2: core に「呼び出し回数の監視／拒否」フックを追加する

- Revocation / Introspection の各ステップ関数と同じ粒度で、`onSuspiciousLookup` のようなフック（またはミドルウェア用の型）を core が定義する。実装は利用者が注入する。
- 生成 OP には no-op の実装とコメント（「ここに KV ベースのカウンタを入れてください」）を出力する。
- メリット: 外部依存を増やさずに拡張点を提供できる。既存の resolver 注入パターンと同型。
- コスト: フックの粒度設計が必要（クライアント単位か IP 単位か、両エンドポイント共通か個別か）。空のフックは `study-material/done/cli-setup-entry-placeholder-silent-noop.md` が指摘する「黙って何もしないプレースホルダ」になりうるので、その回避策（起動時警告など）も併せて設計する必要がある。

### 方針 3: 監査イベントとして記録する（検知に振る）

- `study-material/audit-logging-and-observability.md` の設計に「revocation の invalid_grant」「introspection の inactive 応答」をイベントとして含める。
- メリット: 拒否の判断を利用者に押し付けず、まず可視化する。方針 1 との併用が自然。
- コスト: ログ設計そのものが未着手のため、本件単独では進められない（依存関係がある）。

### 方針 4: 形状差を無くす（他クライアントのトークンでも 200 を返す）

- メリット: オラクルが消える。
- コスト: **RFC 7009 §2.1 の "the client is informed of the error" から外れる**。Fidelity を掲げる本リポジトリの方針と衝突する。採る場合は「意図的な逸脱」として `conformance` 互換フラグ（`tasks/p3-conformance-compat-flags-warning-and-contract-tests.md` の枠組み）に載せ、既定は RFC 準拠にすべき。
- **単独では推奨しにくい**。Introspection の caller 認可が無い限り効果も限定的（§3.5 参照）。

### 検討順序についての観察

方針 1 は他のどれとも併用でき、かつ単独で完結する。方針 2 / 3 は互いに依存し、Introspection の caller 認可（既存タスク）とも設計を揃える必要がある。**まず方針 1 で責務分界を確定させ、方針 2 / 3 は Introspection の caller 認可と一括で設計するのが、依存関係の少ない順序である。**

## 9. タスク案

- [ ] RFC 7009 §5 / RFC 7662 §4 の対策について、ライブラリ側とホスティング層の責務分界を決め、README・生成コードのコメント・`study-material/basic-op-requirement-traceability.md` に反映する（方針 1）
- [ ] `packages/core/src/revocation.ts` の `validateRevocationTokenClient` に、`invalid_grant` を返す設計が RFC 7009 §2.1 に基づく意図的なものであること、およびその副作用（存在オラクル）を JSDoc として記録する
- [ ] Introspection の caller 認可（`tasks/p3-introspection-caller-authorization-hook.md`）と合わせて、「トークン有効性を問い合わせられる主体の範囲」を 1 つの設計判断として整理する
- [ ] 監査ログ設計（`study-material/audit-logging-and-observability.md`）に revocation の `invalid_grant` / introspection の inactive をイベントとして含めるか判断する
- [ ] `token_type_hint` が外れたときの 2 回ルックアップについて、コスト上限を設けるかを判断する（RFC 7009 §5 の DoS 記述への対応）

> **本ファイルは方針未確定のため、現時点ではタスク化しない。** 上記タスク案は、方針 1 〜 4 のいずれを採るかが決まった後に `tasks/` へ切り出す。
