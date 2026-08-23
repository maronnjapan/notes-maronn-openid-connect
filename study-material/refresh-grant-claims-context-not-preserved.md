# refresh_token grant で `claims` 認可コンテキストが失われ、UserInfo 応答が無言で縮退する

## 1. このトピックで確認したいこと

`claims` リクエストパラメータ（OIDC Core 1.0 §5.5）で要求されたクレームは、authorization_code grant で発行したアクセストークンには metadata として保存されるが、**refresh_token grant で再発行したアクセストークンには保存されない**。

その結果、同一の grant に属するアクセストークンであるにもかかわらず、

- 初回の access token → UserInfo は `claims.userinfo` で要求された属性を返す
- リフレッシュ後の access token → UserInfo は同じ属性を返さない

という**時間経過だけで応答内容が変わる**挙動になる。RP から見れば「昨日は取れた `email` が今日は取れない」という再現性の低い障害になり、エラーも警告も出ない。

本ファイルは「**grant コンテキストのローテーション跨ぎでの継承漏れ**」に限定する。`claims` を返すこと自体の認可（同意）妥当性は `study-material/claims-parameter-consent-authorization-boundary.md` で扱う（重複説明しない）。

**既存ファイルとの切り分け（重複回避）**

| 論点 | 扱っているファイル |
|---|---|
| `claims` を同意なしで返してよいか | `study-material/claims-parameter-consent-authorization-boundary.md` |
| `claims` の `value` / `values` / `essential` の解釈 | `study-material/done/claims-parameter-value-values-essential.md` |
| `claims.id_token` の個別クレームが ID Token に載らない | `tasks/p2-claims-id-token-member-individual-claims.md` |
| refresh 時の **scope** 保持（縮小の恒久化回避） | `study-material/refresh-token-grant-scope-preservation.md` |
| refresh 時の `nonce` の扱い | `tasks/done/p2-refresh-id-token-nonce-omission.md` |
| refresh 時の `acr` / `amr` / `auth_time` / `azp` 保持 | 実装済み（`RefreshTokenInfo` に永続化済み） |

## 2. 関連する仕様・基準（このトピック固有の差分）

### 2.1 OIDC Core 1.0 §12 — refresh は「同じ認可付与」の継続である

§12.1（Refresh Request）/ §12.2（Successful Refresh Response）は、refresh_token grant で再発行する ID Token が初回認証時の `iss` / `sub` / `auth_time` / `azp` / `acr` / `amr` を保持することを定める。これは「**refresh は新しい認可ではなく、既存 grant の継続である**」という前提の表れである。

`claims` パラメータは Authentication Request の一部として End-User の認可判断に含まれる要素であり、同じ前提に立てば **grant に属する属性**として rotation を跨いで保持されるのが一貫している。逆に「refresh すると要求が消える」挙動を正当化する規定は §12 に存在しない。

なお §12 は `claims` の保持を**明示的に列挙していない**（列挙されているのは ID Token クレーム）。したがってこれは MUST 違反ではなく、**仕様が明示していない領域における一貫性の問題**である。

### 2.2 RFC 6749 §6 — refresh は既存 grant のスコープを超えない

> The requested scope MUST NOT include any scope not originally granted by the resource owner.

scope については「元の grant を超えない」という上限だけが定められ、「元の grant の全要素を保持する」とは書かれていない。ただし本リポジトリは既に `scope` / `audience` / `authTime` / `acr` / `amr` / `grantId` / `originalIssuedAt` を `RefreshTokenInfo` に永続化して継承しており、`claims` だけが抜けている状態は**内部設計の非対称**である。

### 2.3 Basic OP との関係

Basic OP certification profile は `claims` パラメータを必須にしていない（Basic OP 要件の全体像は `study-material/basic-op-requirements-baseline.md` を参照）。よって本トピックは Conformance の合否ではなく、**実装の一貫性・相互運用性**の問題として扱う。

## 3. 参照資料

- OpenID Connect Core 1.0 §12 Using Refresh Tokens（§12.1 Refresh Request / §12.2 Successful Refresh Response）
  — https://openid.net/specs/openid-connect-core-1_0.html#RefreshTokens
- OpenID Connect Core 1.0 §5.5 Requesting Claims using the "claims" Request Parameter
  — https://openid.net/specs/openid-connect-core-1_0.html#ClaimsParameter
- OpenID Connect Core 1.0 §5.3.2 Successful UserInfo Response
  — https://openid.net/specs/openid-connect-core-1_0.html#UserInfoResponse
- RFC 6749 §6 Refreshing an Access Token
  — https://www.rfc-editor.org/rfc/rfc6749#section-6
- OAuth 2.1 draft §4.3 Refresh Token Grant
  — https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1

## 4. 現在の実装確認

### 4.1 authorization_code 経路: claims は保存される

`packages/cli/src/frameworks/hono/templates.ts:2708` 付近（`tokenRouteTemplate`）

```ts
await accessTokenStore.set(tokenResponse.access_token, {
  sub: subject,
  clientId: validatedRequest.clientId,
  scope: validatedRequest.scope,
  ...
  // OIDC Core 1.0 §5.5: persist the authorization request's claims parameter
  claims: validatedRequest.grantType === 'authorization_code' ? validatedRequest.claims : undefined,
});
```

`validatedRequest.claims` は `AuthorizationCodeData.claims`（`packages/core/src/authorization-code.ts:55-56`）→ `AuthorizationCodeInfo.claims`（`packages/core/src/token-request.ts:124-125`）→ `ValidatedAuthorizationCodeRequest.claims`（同 332-333 行）と引き継がれている。

### 4.2 refresh_token 経路: claims は捨てられる

上記の三項演算子が `refresh_token` 側で `undefined` を返す。したがってリフレッシュ後のアクセストークンには `claims` が存在しない。

さらに根本的に、`RefreshTokenInfo`（`packages/core/src/token-request.ts:173-239`）に **`claims` フィールドが存在しない**。保存先が無いため、テンプレート側だけでは修正できない。

```ts
export interface RefreshTokenInfo {
  subject: string;
  clientId: string;
  scope: string[];
  expiresAt: number;
  used: boolean;
  grantId: string;
  iat?: number;
  originalIssuedAt: number;
  issuer?: string;
  lastUsedAt?: number;
  audience?: string[];
  authTime: number;
  nonce?: string;
  acr?: string;
  amr?: string[];
  azp?: string;
  // ← claims が無い
}
```

`ValidatedRefreshTokenRequest`（同 344-381 行）にも `claims` は無い。

### 4.3 UserInfo 側の帰結

生成 UserInfo ルート（例: `samples/hono-cloudflare/src/oidc-provider/routes/userinfo.ts:138-143`）は
`applyRequestedClaims(scopedResponse, userClaims, tokenInfo.claims)` を呼ぶ。`tokenInfo.claims` が
`undefined` なら `getRequestedClaimNames` は空配列を返す（`packages/core/src/userinfo.ts:257-262`）ため、
**scope 由来のクレームだけが返る**。

### 4.4 ID Token 側の帰結

token エンドポイントの `resolveAcrAmr` 呼び出し（`templates.ts:2640` 付近）は
`claims: validatedRequest.grantType === 'authorization_code' ? validatedRequest.claims : undefined`
としており、refresh 時は `claims.id_token.acr.values` を resolver へ渡さない。

ただし refresh 経路では `directAcr` / `directAmr`（保存済みの初回値）が優先されるため（`packages/core/src/token-response.ts:345-347`）、**現状の acr / amr に実害は出ていない**。将来 `claims.id_token` の個別クレーム反映（`tasks/p2-claims-id-token-member-individual-claims.md`）を実装した時点で、ID Token 側にも同じ縮退が現れる。

### 4.5 再現シナリオ

1. RP が `scope=openid offline_access` + `claims={"userinfo":{"email":null}}` + `prompt=consent` で認可。
2. token endpoint で access token A と refresh token R1 を取得。A で UserInfo → `sub` と `email` が返る。
3. R1 で refresh。access token B と R2 を取得。
4. B で UserInfo → `sub` のみ。`email` は返らない。エラーも警告も無い。

## 5. 現在の実装との差分

### 満たしていること

- `scope` / `audience` / `authTime` / `acr` / `amr` / `azp` / `grantId` / `originalIssuedAt` は rotation を跨いで正しく継承されている。
- `hadOfflineAccess` により、scope 縮小があっても rotation 可否の判定は元 grant で行われる。
- `claims` を authorization_code 経路で永続化する配線は存在する。

### 不足している可能性があること

- `RefreshTokenInfo` / `ValidatedRefreshTokenRequest` に `claims` フィールドが無い。
- 生成テンプレートが refresh 経路で `claims: undefined` を保存する。
- `resolveAcrAmr` へ渡す `claims` も refresh では undefined。

### 実装はあるが仕様上の確認が必要なこと

- **そもそも継承すべきか**という判断。「refresh は新しい Authentication Request ではないので、Authentication Request 由来のパラメータは引き継がない」という立場も取り得る。ただしその立場を採るなら `acr` / `amr` / `auth_time` を継承していることと整合しない（§12.1 が明示している分だけを継承する、という説明は可能）。
- `claims` の永続化は PII 要求内容をストアに長期保存することを意味する。refresh token の絶対寿命（既定 90 日）に合わせて `claims` を保持することのプライバシー上の妥当性。

### セキュリティ上、改善した方がよいこと

- 直接の脆弱性ではない。ただし逆向きに見ると、現状は「refresh すると開示範囲が自動的に縮小する」ので、**セキュリティ的には安全側に倒れている**。継承を実装する場合はこの安全側の性質を失う点を意識する必要がある。
- 継承する場合、`claims` は grant 単位で固定し、refresh リクエストのパラメータで**上書きできてはならない**（Token Endpoint に `claims` パラメータは存在しないので現状は問題ないが、契約として明記すべき）。

### 相互運用性の観点で改善した方がよいこと

- RP から見た「同じ grant なのに応答が変わる」挙動は、キャッシュや UI の破綻を招く。主要 IdP は refresh 後も同じ属性集合を返すのが通例であり、移行時の挙動差になる。

### Basic OP として提供する上で確認すべきこと

- Basic OP の合否には影響しない。ただし conformance.test.ts が生成 OP の想定挙動を固定する契約テストである以上、**どちらの挙動を正とするかを固定しておく**必要がある（現状は固定されていない）。

## 6. 改善・追加を検討する理由

- **価値**: 「refresh の前後で UserInfo が同じ内容を返すか」は、PoC 開発者が最も踏みやすい落とし穴の一つ。挙動が固定されていれば、利用者は自分の要件（属性をどこまで長期に渡すか）を検証できる。
- **Basic OP 必須か拡張か**: 拡張。ただし `claims` を実装している以上、一貫性の担保は品質要件。
- **導入しやすさ**: `RefreshTokenInfo` / `ValidatedRefreshTokenRequest` への optional フィールド追加は後方互換で、`buildValidatedRefreshTokenRequest` に1行足すだけ。テンプレート側も既存の三項演算子を差し替えるだけで済む。
- **既存実装との接続**: `acr` / `amr` / `nonce` の継承と完全に同じ形（`RefreshTokenInfo` に保存 → `buildValidatedRefreshTokenRequest` で読み出し → テンプレートで store へ再保存）に載せられる。
- **メリット**: 応答の一貫性が保証され、RP 実装が安定する。運用者は grant に紐づく開示範囲を1箇所で把握できる。
- **実装しない場合に残るリスク**: 無言の縮退が残る。少なくとも「refresh 後は `claims` が効かない」ことを README / conformance.test で明示しなければ、利用者は原因不明の挙動差に遭遇する。

## 7. 実装方針の候補（最終判断は人間が行う）

### 方針A: `claims` を grant コンテキストとして継承する

1. `RefreshTokenInfo` に `claims?: ClaimsParameter` を追加。
2. `ValidatedRefreshTokenRequest` に `claims?: ClaimsParameter` を追加し、`buildValidatedRefreshTokenRequest` で `refreshTokenInfo.claims` を載せる。
3. テンプレートの `accessTokenStore.set` を `claims: validatedRequest.claims`（grant 種別による分岐を撤廃）に変更。
4. テンプレートの `refreshTokenStore.set` に `claims:` を追加（authorization_code 経由は `validatedRequest.claims`、refresh 経由は継承値）。
5. `resolveAcrAmr` にも `claims` を渡す（将来の `claims.id_token` 反映に備える）。

- 長所: 既存の acr / amr 継承と対称。RP から見た一貫性が最大。
- 短所: PII 要求内容を refresh token の寿命だけ保持することになる。方針は
  `study-material/claims-parameter-consent-authorization-boundary.md` の結論（同意ゲートの有無）と整合させる必要がある。

### 方針B: 継承しないことを意図的挙動として固定する

`claims` は Authentication Request 由来のワンショットな要求であり、refresh では効かないと定義する。README / 生成コードコメント / `conformance.test.ts` に明記し、テストで固定する。

- 長所: 実装変更が最小。開示範囲が時間とともに縮小する安全側の性質を維持できる。
- 短所: RP から見ると不便かつ驚きがある。主要 IdP と挙動が異なる。

### 方針C: 継承するが、同意ゲートとセットにする

方針A を実装しつつ、`claims-parameter-consent-authorization-boundary.md` の方針B（同意画面で granted claims を確定）を先に入れる。継承するのは「同意された claims」だけにする。

- 長所: プライバシー上最も筋が良い。
- 短所: 依存タスクが増え、v0.x のリリースには重い。

### 判断材料

- **方針A と方針B は排他**であり、どちらを選んでも「固定する」こと自体に価値がある（現状は未定義）。
- プライバシーを重視するなら方針B、相互運用性を重視するなら方針A。
- 同意ゲート（別トピック）の結論が方針B（granted claims を持つ）に決まるなら、本トピックは自動的に方針C へ寄る。**先に同意ゲートの方針を決めるほうが手戻りが少ない。**

## 8. タスク案

- [ ] 現状（refresh 後に `claims.userinfo` が効かない）を統合テスト／`conformance.test.ts` で**明示的に固定**する
- [ ] 方針A / B / C のいずれを採るかを決定する（人間判断。`claims-parameter-consent-authorization-boundary.md` の結論と併せて判断すること）
- [ ] 方針A/C: `RefreshTokenInfo` と `ValidatedRefreshTokenRequest` に `claims?: ClaimsParameter` を後方互換で追加し、`buildValidatedRefreshTokenRequest` で継承する
- [ ] 方針A/C: `packages/cli/src/frameworks/hono/templates.ts` の `accessTokenStore.set` / `refreshTokenStore.set` を更新する（`web-standard/templates.ts` が再エクスポートするため全フレームワークの生成物に反映される）
- [ ] 方針A/C: `resolveAcrAmr` へ refresh 経路でも `claims` を渡すかを決定する（現状は `directAcr` 優先のため実害なし）
- [ ] 方針B: 「refresh では `claims` が効かない」ことを README・生成コードコメント・`resolver-and-store-contract.md` に明記する
- [ ] いずれの方針でも `samples/*/conformance.test.ts`（生成元は `packages/cli`）に refresh 前後の UserInfo 応答を比較する契約テストを追加する
