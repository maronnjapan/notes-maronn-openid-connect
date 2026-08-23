# Token Exchange の交換認可モデル — `allowedTargets` のグローバル性と subject_token–クライアント間の非結合

## ステータス

🟡 Medium（拡張機能の認可粒度 / ポリシー注入点の不在）/ 未着手

## 1. このトピックで確認したいこと

`packages/experimental/src/token-exchange` は「誰が交換してよいか」を次の 2 条件だけで判定する。

1. クライアント登録の `grant_types` に token-exchange の URN が含まれること
2. クライアントが public でないこと（`token_endpoint_auth_method !== 'none'`）

これを満たしたクライアントは、**自分が保持している任意の有効なアクセストークン**を、
**設定された `allowedTargets` の任意の値**へ向けて交換できる。ここには 2 つの粒度の粗さがある。

- **`allowedTargets` がクライアント横断のグローバル設定**である。
  交換を許可されたどのクライアントも、同じ許可対象リスト全体にアクセスできる。
- **subject_token と要求クライアントの間に何の関係も要求しない**。
  クライアント A に発行されたトークンを、クライアント B が（入手さえすれば）交換できる。

確認したいのは、これが RFC 8693 の想定どおりの「AS のポリシー裁量」の範囲なのか、
それとも本 OP が提供すべきポリシー注入点を欠いているのか、である。

> 重複回避:
> - Token Exchange 拡張の導入検討そのものは `study-material/ext-token-exchange-rfc8693.md`（実装前の検討文書）。
> - 交換トークンの `aud` が UserInfo を必ず含む問題は
>   `study-material/token-exchange-audience-narrowing-vs-userinfo-permanent-membership.md`。
>   本ファイルは「**誰が**交換してよいか」、あちらは「交換**結果**の権限範囲」を扱う。
> - クライアント登録メタデータ全般の強制は `study-material/done/client-metadata-enforcement.md` /
>   `tasks/done/p1-client-metadata-enforcement.md`。本ファイルは token-exchange 固有の粒度に限る。
> - Introspection の呼び出し元認可フック（`canIntrospect`）は
>   `tasks/p3-introspection-caller-authorization-hook.md`。
>   本ファイルが検討する注入点は、そのフックと同じ設計パターンを取りうる（後述）。

## 2. 関連する仕様・基準（このトピック固有の差分）

### 2.1 RFC 8693 §2.1 — クライアント認証の位置づけ

一次資料の文言（2026-08-06 確認）:

> Client authentication to the authorization server is done using the normal mechanisms
> provided by OAuth 2.0.

> omitting client authentication allows for a compromised token to be leveraged via an
> STS into other tokens by anyone possessing the compromised token.

本実装はこの注記を根拠に **public client を一律拒否**しており、
RFC の懸念に対する対応としては仕様より厳しい（安全側の）判断になっている。
この判断自体は妥当である。

### 2.2 RFC 8693 §2.1 — subject_token の検証範囲

一次資料は subject_token について次だけを要求する。

> the authorization server MUST perform the appropriate validation procedures for the
> indicated token type

**「subject_token と要求クライアントの関係を検証せよ」という要求は無い。**
これは意図的で、STS（Security Token Service）は本来
「あるサービスが受け取ったトークンを別のトークンへ交換する」ための仕組みだからである。
交換を要求するクライアントが subject_token の元の発行先と異なるのは、
むしろ **典型的なユースケース**である。

したがって本実装は**仕様違反ではない**。論点は「AS の裁量に委ねられた部分について、
本 OP が利用者へ十分な制御手段を提供しているか」である。

### 2.3 RFC 8693 §5 Security Considerations

> Any time one principal is delegated the rights of another principal, the potential
> for abuse is a concern.

> The use of the `scope` claim (in addition to other typical constraints such as a
> limited token lifetime) is suggested to mitigate potential for such abuse.

RFC は濫用抑止の責務を AS 側のポリシーに置いている。
`scope` と寿命による抑止は本実装にあるが、**「誰が何を交換できるか」の粒度制御が無い**。

## 3. 参照資料

- RFC 8693 §2.1 Request（クライアント認証、subject_token の検証範囲、`audience` / `resource`）
  — https://www.rfc-editor.org/rfc/rfc8693#section-2.1
- RFC 8693 §2.2.2 Error Response（`invalid_target`）
  — https://www.rfc-editor.org/rfc/rfc8693#section-2.2.2
- RFC 8693 §5 Security Considerations
  — https://www.rfc-editor.org/rfc/rfc8693#section-5
- RFC 7591 §2 Client Metadata（`grant_types` の既定は `["authorization_code"]`）
  — https://www.rfc-editor.org/rfc/rfc7591#section-2
- OIDC Dynamic Client Registration 1.0 §2 Client Metadata
  — https://openid.net/specs/openid-connect-registration-1_0.html#ClientMetadata
- RFC 8707 Resource Indicators for OAuth 2.0（対象ごとの認可という考え方）
  — https://www.rfc-editor.org/rfc/rfc8707

## 4. 現在の実装確認

### 4.1 クライアント認可（2 条件のみ）

`packages/experimental/src/token-exchange/token-exchange-request.ts` の
`authorizeTokenExchangeClient(client)`:

```ts
const grantTypes = client.grantTypes ?? ['authorization_code'];
if (!grantTypes.includes(TOKEN_EXCHANGE_GRANT_TYPE)) {
  throw new TokenExchangeError('unauthorized_client', ...);
}
if (client.tokenEndpointAuthMethod === 'none') {
  throw new TokenExchangeError('unauthorized_client', ...);
}
```

- ✅ 既定拒否（`grant_types` 未指定は `['authorization_code']` 扱い）になっており fail-safe。
- ✅ クライアント認可を **最初に** 行い、未許可クライアントに subject_token の
  有効性判定すらさせない（オラクル回避）。コメントにも明記されている。
- ❌ ここで判定できるのは「交換してよいクライアントか」だけで、
  **「何を」「どこへ」交換してよいかはクライアント単位で表現できない**。

### 4.2 `allowedTargets` はグローバル

`packages/cli/src/frameworks/hono/templates.ts` が生成する設定:

```
export const tokenExchangeConfig = {
  allowedTargets: [] as string[],
};
```

呼び出し側:

```
const grant = await processTokenExchangeRequest({
  params,
  client: tokenClient,
  accessTokenResolver,
  allowedTargets: tokenExchangeConfig.allowedTargets,   // ← client に依存しない
  configuredExpiresIn: exchangeConfig.accessTokenExpiresIn,
});
```

`resolveExchangeTarget` はこのリストに対して単純な包含判定を行う。

```ts
if (!allowedTargets.includes(requested)) {
  throw new TokenExchangeError('invalid_target', ...);
}
```

つまり **クライアント X と Y の両方が交換を許可されていれば、両者とも
`allowedTargets` の全エントリへ交換できる**。
「X は service-a のみ、Y は service-b のみ」という表現ができない。

### 4.3 subject_token とクライアントの非結合

`resolveSubjectToken()` が行う検証は 3 つだけ。

```ts
const info = await options.accessTokenResolver.findAccessToken(options.subjectToken);
if (info === null) throw invalidSubjectToken();          // 存在
if (info.expiresAt <= nowSeconds) throw invalidSubjectToken();   // 期限
if (info.nbf !== undefined && info.nbf > nowSeconds) throw invalidSubjectToken();  // nbf
```

`AccessTokenInfo` は `clientId`（発行先クライアント）を保持しているが、
**`context.client.clientId` との比較は一切行われない**。

`processTokenExchangeRequest` の戻り値でも、
`subject`（= エンドユーザ）と `grantId` は subject_token から継承する一方、
`clientId` は **交換を要求したクライアント**に付け替えられる。

```ts
return {
  subject: subject.sub,          // subject_token 由来（不変）
  clientId: context.client.clientId,   // 要求クライアントへ付け替え
  scope, requestedAudience, expiresIn,
  grantId: subject.grantId,      // subject_token 由来（失効連動）
};
```

この付け替え自体は impersonation の正しい表現である。

### 4.4 緩和されている点（正確に評価するために）

- ✅ `allowedTargets` の既定は空配列。**対象を明示する交換は既定で全て `invalid_target`**。
  利用者が明示的に設定するまで、この経路のリスクは発生しない。
- ✅ 交換されたトークンは subject_token の `grantId` を継承するため、
  grant 単位の失効（認可コード再利用検知など）が交換トークンにも波及する。
- ✅ 寿命は `min(configured, subject の残存)` で単調減少し、交換の連鎖で延命できない。
- ✅ public client は一律拒否されているため、
  「窃取トークン + public client」という最も容易な攻撃経路は塞がれている。
- ✅ 交換には**クライアント認証が必須**なので、subject_token を入手しただけでは交換できない。
  攻撃には「交換許可済みクライアントの資格情報」と「有効な subject_token」の**両方**が要る。

## 5. 現在の実装との差分

### 満たしていること

- ✅ RFC 8693 §2.1 のクライアント認証要求を満たし、さらに public client を拒否して強化している。
- ✅ 既定拒否（`grant_types` 未登録・`allowedTargets` 空）で fail-safe。
- ✅ scope 部分集合検証・寿命単調減少・`sub` 不変という RFC 8693 §5 の抑止手段を実装している。
- ✅ 仕様が明示的に要求する検証は**すべて実装されている**（subject_token とクライアントの
  結合検証は仕様の要求ではない）。

### 不足している可能性があること

- 🟡 **クライアント単位の対象制御ができない**。
  複数の下流サービスと複数の交換クライアントが存在する構成で、
  最小権限（クライアントごとに許可対象を絞る）を表現できない。
  現実の STS 運用ではこれが基本要件になる。
- 🟡 **交換ポリシーの注入点が無い**。
  本リポジトリは他の判断ポイントで resolver / callback 注入を一貫して採用している
  （`AcrResolver`、`OfflineAccessGrantedCallback`、`ConsentResolver`、
  検討中の `canIntrospect` など）。token-exchange だけが
  **静的な配列 1 本**で、利用者がロジックを差し込めない。
- 🟢 **subject_token とクライアントの非結合そのもの**は仕様どおりであり、
  「不足」ではなく「ポリシー未定義」と評価するのが正確である。
  ただしそのポリシーを利用者が定義する手段が無い点が上記 2 つに帰着する。

### 実装はあるが仕様上の確認が必要なこと

- 🟡 `authorizeTokenExchangeClient` が public client を拒否する判断は仕様より厳しい。
  RFC 8693 は public client の交換を禁止していないため、
  **将来この制約を緩めたい利用者が現れうる**。ステップ関数として export されているので
  差し替えは可能だが、その旨がドキュメントに書かれていない。

### セキュリティ上、改善した方がよいこと

- 🟡 現状の脅威モデルを明文化する価値がある。
  「交換許可済みクライアントの資格情報が漏れた場合、そのクライアントは
  `allowedTargets` 全体へ、入手できた任意のトークンを交換できる」という影響範囲は、
  利用者が `allowedTargets` を設計する際に知っておくべき前提である。

### Basic OP として提供する上で確認すべきこと

- 🟢 Token Exchange は Basic OP の要件外であり、**Basic OP 認証の合否には影響しない**。

## 6. 改善・追加を検討する理由

- **OSS 利用者の使いやすさ**: 本リポジトリの想定利用者は「自分の要件がこの仕様で実現できるか」を
  検証する PoC 開発者である。STS の PoC で最初に問われるのは
  「サービスごとに交換範囲を分けられるか」であり、現状の静的配列では検証できない。
- **既存の設計パターンとの一貫性**: resolver / callback 注入は本リポジトリの確立された作法である。
  token-exchange だけがそこから外れている理由は、実装の新しさ以外に見当たらない。
- **導入しやすさ**: `resolveExchangeTarget` はすでに独立したステップ関数であり、
  `allowedTargets: string[]` を
  `allowedTargets: string[] | ((ctx) => string[] | Promise<string[]>)` へ広げるか、
  引数に `clientId` を足すだけで per-client 化できる。**core は無変更**。
  experimental は API 不安定を明言しているため破壊的変更も許容しやすい。
- **既存実装との接続**: `TokenClientInfo` は `clientId` / `grantTypes` /
  `tokenEndpointAuthMethod` を持つため、クライアント登録メタデータに
  許可対象リストを足す拡張も自然に接続できる。
- **実装しない場合に残る制約**:
  - 複数下流サービス構成での最小権限を表現できず、PoC の適用範囲が狭いままになる。
  - 交換許可クライアントの資格情報漏洩時の影響範囲が、設定で絞れない。
  - 利用者が独自にポリシーを実装する場合、ステップ関数を自前で組み直す必要がある
    （合成関数 `processTokenExchangeRequest` は使えなくなる）。

## 7. 実装方針の候補（最終判断は人間）

### 方針A: `allowedTargets` をクライアント単位の解決関数にする

```ts
export type ExchangeTargetPolicy =
  | string[]
  | ((context: { clientId: string; subject: string; subjectClientId?: string })
      => string[] | Promise<string[]>);
```

- 配列を渡す既存の使い方はそのまま動く（後方互換）。
- 関数を渡せばクライアント別・ユーザ別のポリシーを表現できる。
- メリット: 本リポジトリの resolver 注入パターンに揃う。段階的に導入できる。
- デメリット: `resolveExchangeTarget` が非同期になり、ステップ関数のシグネチャが変わる。

### 方針B: クライアント登録メタデータへ許可対象を持たせる

- `TokenClientInfo` に token-exchange 用の許可対象リストを追加し、
  `authorizeTokenExchangeClient` / `resolveExchangeTarget` がそれを参照する。
- メリット: 「クライアントに何を許すか」がクライアント登録に集約され、
  `client-metadata-enforcement` の既存方針と一貫する。
- デメリット: core の `TokenClientInfo` に experimental 由来のフィールドが入る
  （`study-material/done/discovery-metadata-experimental-features-core-expressibility.md` と同種の
  境界問題が発生する）。experimental 側で交差型として持つ回避策はある。

### 方針C: 交換可否の判定コールバックを 1 本足す

```ts
/** 交換を許可するか。false / throw で invalid_target または unauthorized_client。 */
canExchange?: (context: {
  client: TokenClientInfo;
  subjectToken: AccessTokenInfo;   // 発行先 clientId・scope・grantId を含む
  requestedTargets: string[];
}) => boolean | Promise<boolean>;
```

- 対象制御と subject_token–クライアント結合の**両方**を利用者が一箇所で表現できる。
- `tasks/p3-introspection-caller-authorization-hook.md` の `canIntrospect` と同じ設計。
- メリット: 表現力が最も高く、追加 API が 1 つで済む。
- デメリット: 既定実装を用意しないと「何もしないフック」になり、
  既定の安全性は現状から変わらない。既定を決める判断が別途必要。

### 方針D: 現状維持＋脅威モデルの明文化

- 実装は変えず、生成される `tokenExchangeConfig` のコメントと
  `docs/library-document` の Experimental セクションに次を明記する。
  - `allowedTargets` は全交換クライアントで共有されること
  - subject_token の発行先クライアントは検証されないこと（仕様どおりだが AS ポリシー未定義であること）
  - 交換クライアントの資格情報漏洩時の影響範囲
- メリット: 変更ゼロ。仕様違反ではない以上、明文化だけでも筋は通る。
- デメリット: 最小権限を必要とする PoC は実施できないままになる。

### 判断材料

- **仕様違反ではない**ため、優先度は「セキュリティ欠陥の修正」ではなく
  「拡張機能の表現力・実用性の向上」として評価するのが正確である。
- 既定構成（`allowedTargets` が空）では顕在化しないため、緊急度は低い。
- 方針 C は表現力が最も高いが、既定ポリシーをどうするかという判断が残る。
  方針 A は最小の変更で「クライアント別の対象制御」という最も需要が高い一点を解決する。
- experimental の API 不安定宣言により、A / B / C いずれも破壊的変更として導入可能。
  導入するなら **API が広く使われる前の今**が最もコストが低い。
- 方針 D を単独で採る場合でも、A / B / C のいずれかを将来入れる前提で
  ステップ関数のシグネチャを設計しておくと移行が楽になる。

## 8. タスク案

- [ ] 方針 A / B / C / D のどれを採るかを人間が判断する
- [ ] 先に脅威モデルを文書化する（方針にかかわらず有用）
  - [ ] `allowedTargets` の共有範囲・subject_token の非検証・資格情報漏洩時の影響範囲を
        `docs/library-document` の Experimental セクションに記述する
  - [ ] `authorizeTokenExchangeClient` が public client を拒否するのは
        RFC 8693 より厳しい設計判断であり、差し替え可能である旨を JSDoc に追記する
- [ ] 方針 A 採用時:
  - [ ] `resolveExchangeTarget` の `allowedTargets` を配列または解決関数の受け入れに広げる
  - [ ] `TokenExchangeRequestContext` と生成テンプレートの `tokenExchangeConfig` を追随させる
  - [ ] 配列を渡す既存経路が挙動を変えないことを回帰テストで固定する
- [ ] 方針 C 採用時:
  - [ ] `canExchange` フックを `TokenExchangeRequestContext` に追加する
  - [ ] 未指定時の既定挙動（現状維持か、subject_token の発行先一致を要求するか）を決める
- [ ] テスト要件:
  - [ ] クライアント A に発行された subject_token をクライアント B が交換する経路の
        現在の挙動（成功する）を契約テストとして明示的に固定する
        — 意図した挙動であることをテストで可視化し、将来の変更が無自覚に起きないようにする
  - [ ] `allowedTargets` に無い対象を要求したときの `invalid_target` を固定する
  - [ ] 方針採用後は、クライアント別に許可対象が分離されることを検証するテストを追加する
