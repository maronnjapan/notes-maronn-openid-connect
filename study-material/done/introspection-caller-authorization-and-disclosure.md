# Token Introspection の呼び出し元認可とメタデータ開示の最小化（RFC 7662 §2.1 / §4）

## ステータス

🟢 Low-Medium / 未着手（追加フックは非破壊で着手可能、既定挙動の変更は方針未確定 = 検討中）

## 1. このトピックで確認したいこと

Token Introspection エンドポイント（RFC 7662）が、**「認証済みの confidential client であれば、誰でも・どのトークンでも introspect でき、active=true 時にフル属性（`sub` / `scope` / `aud` / `iss` / `exp` / `client_id` など）を返す」** という現実装の開示ポリシーが、相互運用性とプライバシー／セキュリティの観点で妥当かを確認する。

具体的には:

- RFC 7662 が要求する「token scanning 攻撃対策の authorization」を満たしているか（= 単なるクライアント認証で十分か）
- 呼び出し元（caller）が、そのトークンの正当な利用先（resource server / audience）であることを縛る仕組みが必要か
- active=true レスポンスで返す属性を、呼び出し元に応じて最小化（claim minimization）すべきか
- これらを OSS 利用者が選べるよう、core にオプトインの認可フック／開示制御を用意すべきか

> 重複を避けるための関連既存ファイル（同じ説明は繰り返さない）:
> - Introspection の実装そのもの・active 判定: `tasks/done/p1-token-introspection.md`
> - レート制限 / 列挙・スキャン対策の **throttling 側面**: `study-material/rate-limiting-and-brute-force.md`（本ファイルでは throttling は扱わず、authorization と claim 開示に絞る）
> - JWT 形式の introspection レスポンス（RFC 9701）: `study-material/ext-jwt-introspection-response-rfc9701.md`
> - アクセストークンの `aud` 検証（resource 側）: `study-material/done/userinfo-access-token-audience-validation.md`
> - Resolver/Store 契約: `study-material/resolver-and-store-contract.md`

本ファイルは上記と重複せず、**「誰に・何を introspect させるか（caller authorization と claim 開示の最小化）」** という差分のみを扱う。

## 2. 関連する仕様・基準（このトピック固有の差分）

### 2.1 RFC 7662 §2.1 Introspection Request

- 「token scanning 攻撃を防ぐため、エンドポイントは **何らかの形の authorization を要求しなければならない（MUST）**」。手段としてクライアント認証または別途発行されたトークンを挙げる。
  - → 現実装はクライアント認証（confidential）を必須にしており、この MUST 自体は満たす。
- 「introspection エンドポイントを呼ぶ protected resource は、自身に向けて発行されたトークンのみを introspect することが期待される（RECOMMENDED 相当の運用前提）」旨が示唆される。RFC 7662 はトークン所有クライアントと caller の一致を **強制要件にはしていない**（protected resource が他者発行トークンを検証するのが本来のユースケースのため）。

### 2.2 RFC 7662 §4 Security Considerations（本トピックの核心）

- 「introspection エンドポイントが返す値には、トークンに紐づく **privileged information（特権情報）** が含まれ得る。許可されていない当事者へのこれら情報の開示は避けなければならない（MUST be prevented）」。
- 対策として「**introspection を必要とする protected resource にのみアクセスを限定する**」「呼び出し元に応じて **返す情報を必要最小限にする**」「rate limiting」を挙げる。
- つまり RFC 7662 自身が、**「全 confidential client に全トークンのフル属性を返す」設計は §4 が戒める開示**に該当し得ると示している。

### 2.3 OAuth 2.0 Security BCP（RFC 9700）との関係

- RFC 9700 はトークン情報の不要な拡散を避けることを一般原則として求める（既存 `study-material/done/oauth-security-bcp-rfc9700.md` のカバレッジ監査範囲）。本ファイルはその introspection 固有の適用差分を扱う。

## 3. 参照資料

- RFC 7662 OAuth 2.0 Token Introspection §2.1 Introspection Request
  — https://www.rfc-editor.org/rfc/rfc7662#section-2.1
  （「token scanning 防止のため authorization を MUST」「caller は自分宛トークンを introspect する想定」）
- RFC 7662 §2.2 Introspection Response
  — https://www.rfc-editor.org/rfc/rfc7662#section-2.2
  （`scope` / `client_id` / `username` / `aud` / `iss` / `sub` 等の任意フィールド定義）
- RFC 7662 §4 Security Considerations
  — https://www.rfc-editor.org/rfc/rfc7662#section-4
  （「privileged information の開示を防ぐ」「必要な resource server に限定」「返却情報の最小化」「rate limiting」）
- RFC 9700 OAuth 2.0 Security Best Current Practice
  — https://www.rfc-editor.org/rfc/rfc9700
- 関連: RFC 8707 Resource Indicators（`aud` の意味づけ）
  — https://www.rfc-editor.org/rfc/rfc8707

## 4. 現在の実装確認

- core: `packages/core/src/introspection.ts`
  - 冒頭コメント（`introspection.ts:8-13`）で **「所有チェックは行わず、authenticated confidential client であればいずれのトークンも introspect 可能」** と明示的に設計選択している。
  - `handleIntrospectionRequest`（`introspection.ts:144-198`）は `authenticatedClientId` が非空であることだけを確認し、**caller とトークンの関係（`aud` / `client_id` 一致など）は一切検証しない**。
  - `buildAccessTokenResponse` / `buildRefreshTokenResponse`（`introspection.ts:104-134`）は active=true 時に `sub` / `scope` / `client_id` / `aud` / `iss` / `exp` / `iat` / `jti` を **無条件・最大限**返す。呼び出し元に応じた最小化は無い。
- sample: `packages/sample/src/oidc-provider/routes/introspection.ts`
  - `Confidential client only` と明記。`authenticateClient(...)` で confidential 認証のみ。`Cache-Control: no-store` / `Pragma: no-cache` は付与済み（開示の **キャッシュ**面は対策済み）。

## 5. 現在の実装との差分

- **満たしていること**:
  - RFC 7662 §2.1 の「authorization を MUST」: confidential client 認証で満たす。
  - レスポンスのキャッシュ抑止（`no-store`）: 実装済み。
  - active=false 時は `{ active: false }` のみで、存在情報以上を漏らさない設計。
- **不足している可能性があること（§4 の観点）**:
  - 任意の登録 confidential client が、**自分宛でないトークンの `sub` / `scope` / `aud` などの特権情報**を取得できる。マルチクライアント環境では、あるクライアントが他クライアント／他ユーザーのトークン属性を収集できてしまう（情報開示の過剰）。
  - caller を「そのトークンの `aud`（= 正当な resource server）に含まれる者」へ縛るオプションが無い。
  - 呼び出し元に応じた **claim minimization**（例: caller が aud に含まれない場合は最小限のみ返す／active のみ返す）の手段が無い。
- **セキュリティ上、改善した方がよいこと**:
  - RFC 7662 §4 は「必要な resource server に限定」「返却情報の最小化」を SHOULD 相当で促す。現状は OSS 利用者がこれを実現する拡張点を持たない。
- **相互運用性の観点**:
  - 正規ユースケース（resource server が自分宛トークンを検証）は現状でも動く。縛りを入れても resource server の正規利用は壊れない（aud に自分が含まれるため）。
- **Basic OP として確認すべきこと**:
  - Token Introspection は **Basic OP プロファイルの必須要件ではない**（OAuth 拡張）。よって Conformance への影響は無い。本トピックは「OSS としての安全な既定／拡張性」の観点で扱う。

## 6. 改善・追加を検討する理由

- **なぜ価値があるか**: マルチクライアントを 1 つの OP に同居させる検証用途（本ライブラリの主目的）では、「クライアント A がクライアント B のトークン属性を introspect で覗ける」状態は、PoC 段階でも誤解を生む。RFC 7662 §4 が明示的に戒める開示であり、安全側の選択肢を **利用者が選べる**ことに価値がある。
- **Basic OP として必要か / 拡張か**: Basic OP の必須ではない。**セキュリティ・ハードニング（拡張）** として位置づける。
- **導入しやすさ**: `handleIntrospectionRequest` は純関数で、`IntrospectionRequestContext` にオプション項目を 1 つ足すだけで非破壊に拡張できる（既存の `acrResolver` 等と同じ inject パターン）。既定を「現挙動を維持」にすれば後方互換。
- **既存実装との接続**: トークン情報（`AccessTokenInfo.audience` / `RefreshTokenInfo.audience` / `clientId`）は既に保持済みなので、caller と `aud` の突き合わせに必要なデータは揃っている。
- **利用者メリット**: 「resource server だけが自分宛トークンを introspect」という現実的なポリシーを数行で有効化でき、誤った情報拡散を防げる。
- **実装しない場合のリスク**: マルチクライアント検証時に他クライアント／他ユーザーのトークン特権情報が漏れる前提のまま。RFC 7662 §4 非対応のシグナルが残る。

## 7. 実装方針の候補（最終判断は人間）

### 方針A（推奨度：高 / 非破壊・最小）: オプトインの caller authorization フック

- `IntrospectionRequestContext` に任意の `canIntrospect?` を追加:
  ```ts
  // 戻り値 false なら active=false 相当（{ active: false }）を返し、情報を一切開示しない
  canIntrospect?: (ctx: {
    callerClientId: string;
    token: { kind: 'access_token' | 'refresh_token'; info: AccessTokenInfo | RefreshTokenInfo };
  }) => boolean | Promise<boolean>;
  ```
- 既定（未指定時）は **現挙動を完全維持**（誰でも introspect 可）。
- 典型実装例（利用者が選択）: `callerClientId === info.clientId || (info.audience?.includes(callerClientId) ?? false)`。
  - 「自分が発行先クライアント」または「自分が aud に含まれる resource server」のみ許可。
- 不許可時は `{ active: false }` を返す（存在の有無すら漏らさない安全側）。エラーにはしない。

### 方針B: claim minimization フック（方針Aと併用可）

- `canIntrospect` の代わり／追加で、`filterIntrospectionClaims?(caller, response)` を提供し、active=true レスポンスから caller に不要な属性（`sub` / `username` など）を落とせるようにする。
- 「active は返すが privileged info は最小化」という RFC 7662 §4 の中間ポリシーを表現できる。

### 方針C: ドキュメント・ガイドのみ

- core は変更せず、`study-material/resolver-and-store-contract.md` / README に「introspection を resource server 限定にする運用」を記載する。実装は利用者責務。

> 判断材料: 方針A は非破壊で効果が大きく、本ライブラリの inject 設計に最も馴染む。既定挙動を変える（=デフォルトで aud 縛り）かどうかは別判断（破壊的になり得るため、まずはオプトインが無難）。

## 8. タスク案

- [ ] 方針A（オプトイン `canIntrospect` フック）を採用するか、方針B/C にするかをユーザー判断
- [ ] 方針A採用時: `introspection.test.ts` に先行テスト追加
      - `canIntrospect` 未指定なら従来どおり全属性を返す（後方互換）
      - `callerClientId` がトークンの `clientId` でも `aud` でもない場合に `{ active: false }` を返す
      - resource server（`aud` に含まれる caller）は active=true でメタデータを取得できる
- [ ] `introspection.ts` の `IntrospectionRequestContext` に `canIntrospect?` を追加し、active 判定の直前に評価
- [ ] sample/CLI テンプレートに「resource server 限定ポリシー」の有効化例をコメントで提示（既定は無効＝後方互換）
- [ ] 完了条件: `pnpm --filter @maronn-openid-connect/core test` がパスし、既存 introspection テストが回帰しないこと
