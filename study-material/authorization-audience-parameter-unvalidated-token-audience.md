# 独自 `audience` リクエストパラメータが無検証でアクセストークンの `aud` に載る

## ステータス

🟠 High（セキュリティ・仕様整合）/ 未着手

> RFC 8707 の標準 `resource` パラメータを**採用するかどうか**という拡張機能の論点は
> 📌 `study-material/ext-resource-indicators-rfc8707.md` が扱う。本ファイルはその仕様解説を繰り返さない。
> 本ファイルが扱うのは、**「標準化の可否とは独立に、現在すでに出荷されている無検証の `audience` パラメータが
> 何を許してしまっているか」**という、既存実装のセキュリティ差分に限る。
> 受領側（UserInfo / リソースサーバ）の `aud` 検証は 📌 `study-material/done/userinfo-access-token-audience-validation.md`、
> `aud` の既定値（非空保証）は 📌 `tasks/p1-jwt-access-token-aud-default.md` が扱う。

## 1. このトピックで確認したいこと

認可エンドポイントは独自の `audience` パラメータ（スペース区切り）を受理し、その値が
**一切の検証を経ずに**アクセストークンの `aud` クレームへ到達する。確認したいのは次の 4 点。

1. `audience` の値はどこで検証されているか（結論: どこでも検証されていない）
2. その結果、クライアントは自分に無関係な識別子を自分のアクセストークンの `aud` に入れられるか
3. それが下流のリソースサーバ（`aud` に自分が含まれることを検証する RFC 9068 準拠の RS）に対して
   どのような影響を持つか
4. `audience` を残す／`resource` に寄せる／削除する、のいずれを選ぶにせよ、
   **最低限どこにガードを置くべきか**

## 2. 関連する仕様・基準

RFC 8707 の `resource` パラメータ仕様そのものの説明は
📌 `study-material/ext-resource-indicators-rfc8707.md` に譲る。本トピックに固有の根拠は次のとおり。

### 2.1 「要求された audience は認可対象か」を AS が判断する義務

- **RFC 8707 §2**: `resource` の値は絶対 URI であり、fragment を含んではならない（MUST NOT）。
- **RFC 8707 §2.2**: 要求されたリソースが**無効・不明・認可サーバのポリシーで許可されない**場合、
  認可サーバは `invalid_target` エラーを返さなければならない（MUST）。
  つまり標準の設計では「クライアントが要求した audience をそのまま通す」ことは想定されていない。
  仮に本リポジトリが `resource` を採用しないとしても、
  **同じ意味を持つ独自パラメータには同等のポリシー判断が必要**、というのがこの条文の含意である。

### 2.2 `aud` は「誰が受け取ってよいか」を決めるクレームである

- **RFC 7519 §4.1.3 (`aud`)**: `aud` は JWT の受信者を識別する。
  「その JWT を処理する側は、自分を識別する値が `aud` に含まれていなければ**拒否しなければならない**（MUST）」。
  すなわち `aud` は**受領側の受理判定の入力**であって、発行側が自由に広げてよい装飾ではない。
- **RFC 9068 §3 / §4**: JWT アクセストークンの `aud` はリソースサーバを識別し、
  リソースサーバは自分が `aud` に含まれることを検証しなければならない（MUST）。
  → `aud` を攻撃者が指定できるということは、**受領側の受理判定を発行要求者が操作できる**ことを意味する。

### 2.3 confused deputy の観点

- **RFC 9700（OAuth 2.0 Security BCP）**: トークンの適用範囲（audience）を絞ることが
  漏洩時の被害局所化とリソース間の混同防止に有効であるという前提に立つ。
  audience の値を要求者が自由に決められると、この前提が成立しない。
- **RFC 8707 §1 (Introduction)** も同様に、resource indicator の目的が
  「トークンの適用先を限定すること」であることを述べている。
  限定の対象を限定される側（クライアント）が決めるのでは、目的が反転する。

> なお、この論点は **Basic OP 認定の必須要件ではない**。Basic OP の必須範囲は
> 📌 `study-material/basic-op-requirements-baseline.md` を参照。
> 本件は「Basic OP の外側で本リポジトリが独自に追加した機能に、対応するガードが無い」という差分である。

## 3. 参照資料

- RFC 8707 Resource Indicators for OAuth 2.0 — https://www.rfc-editor.org/rfc/rfc8707
  - §2（`resource` の構文: 絶対 URI・fragment 禁止）／§2.2（許可されないリソースは `invalid_target`）
- RFC 7519 JSON Web Token §4.1.3 `aud` — https://www.rfc-editor.org/rfc/rfc7519#section-4.1.3
  - 受領側が自分を `aud` に見つけられなければ拒否する MUST
- RFC 9068 JWT Profile for OAuth 2.0 Access Tokens — https://www.rfc-editor.org/rfc/rfc9068
  - §3（`aud` はリソースサーバを識別）／§4（受領側の `aud` 検証 MUST）
- RFC 9700 OAuth 2.0 Security Best Current Practice — https://www.rfc-editor.org/rfc/rfc9700.html
  - トークンの適用範囲限定（audience restriction）の位置づけ
- RFC 6749 §3.3 — 要求された scope を AS が縮小・拒否してよいこと（権限要求は要求者の申告どおりに通すものではない、という一般原則）

## 4. 現在の実装確認

`audience` は認可リクエストからアクセストークン、さらにイントロスペクション応答まで、
**検証点を一度も経ずに**伝播する。

### 4.1 受理（認可エンドポイント）

`packages/core/src/authorization-request.ts`

```ts
// L82-83
  // アクセストークンのaudience（スペース区切り）
  audience?: string;
```

```ts
// L1089-1097
export function parseAudienceParameter(
  effectiveParams: AuthorizationRequestParams,
): string[] | undefined {
  const audienceValue = effectiveParams.audience;
  if (audienceValue === undefined) {
    return undefined;
  }
  return audienceValue.split(' ').filter((a) => a.length > 0);
}
```

分割と空要素除去のみ。**絶対 URI 検査も fragment 検査もクライアント別の許可判定も無い。**
`validateAuthorizationRequest`（L1200）はこれをそのまま
`ValidatedAuthorizationRequest.audience`（L272）に載せて返す。

なお `audience` は `REQUEST_OBJECT_OVERRIDE_KEYS`（L1251-1267）にも含まれるため、
署名付き Request Object 経由でも同じ経路に入る。

### 4.2 保持（Auth Transaction → 認可コード → Refresh Token）

- `packages/core/src/auth-transaction.ts` L252-254: `transaction.audience` に保存
- `packages/core/src/token-request.ts` L118（`AuthorizationCodeInfo.audience`）→
  L355（`ValidatedRefreshTokenRequest.audience`）／L207（`RefreshTokenInfo.audience`）

「拡大も欠損も許容しない」というコメントのとおり、**最初に受け取った値が忠実に保持され続ける**。
最初の値が検証されていないため、この忠実さがそのまま問題を固定化する。

### 4.3 アクセストークンへの反映

`packages/core/src/token-response.ts` L195-206

```ts
export function buildAccessTokenAudience(input: AccessTokenAudienceInput): string[] {
  const { userInfoEndpoint, requested, issuer } = input;
  const members: string[] = [];
  if (userInfoEndpoint) {
    members.push(userInfoEndpoint);
  }
  if (requested) {
    members.push(...requested);   // ← クライアント指定値がそのまま aud のメンバになる
  }
  const deduped = [...new Set(members)];
  return deduped.length > 0 ? deduped : [issuer];
}
```

生成 OP（`packages/cli/src/frameworks/hono/templates.ts` L2920-2923）も同じ経路を通る。

```ts
    const effectiveAudience = buildAccessTokenAudience({
      userInfoEndpoint: `${config.issuer}/userinfo`,
      requested: validatedRequest.audience,
      issuer: config.issuer,
    });
```

その結果、`aud = [<OP の UserInfo エンドポイント>, ...クライアントが指定した任意の文字列]` となる。

### 4.4 イントロスペクション応答へのエコー

`packages/core/src/introspection.ts` L143-145 は `info.audience` をそのまま `aud` として返す。
リソースサーバがイントロスペクション結果の `aud` を信頼する構成では、ここでも同じ値が伝わる。

### 4.5 受領側の検証との関係

`packages/core/src/userinfo.ts` L423-436 の `validateUserInfoAudience` は
「UserInfo エンドポイント URL が `aud` に含まれること」だけを見る。
`aud` に**余分なメンバが含まれていても拒否しない**（RFC 7519 §4.1.3 の受領側ルールとしては正しい振る舞い）。
したがって UserInfo 側でこの問題が止まることはない。

> 未確認事項: `aud` メンバの文字列に長さ上限が無いため、極端に長い `audience` を与えたときの
> トークンサイズ・ストア消費の挙動は測定していない。DoS 面の一般論は
> 📌 `study-material/done/untrusted-input-payload-size-dos-hardening.md` が扱っており、本ファイルでは重複させない。

## 5. 現在の実装との差分

- **満たしていること**
  - audience を認可 → トークン → refresh ローテーションにわたって**拡大させずに**保持する仕組みは既にある
    （`buildAccessTokenAudience` にポリシーが集約されており、ガードを差し込む場所は 1 箇所で済む）。
  - 受領側（UserInfo）は `aud` に自分が含まれることを検証している（RFC 9068 §4 準拠）。
  - `aud` が空にならないフォールバック（`issuer`）がある。
- **不足している可能性があること**
  - `audience` の**構文検証が無い**（絶対 URI か、fragment を含まないか）。
  - `audience` の**認可判定が無い**（このクライアントがその audience を要求してよいか）。
  - 許可されない audience を拒否する**エラー経路が無い**
    （`AuthorizationErrorCode` / `TokenErrorCode` に `invalid_target` が存在しない）。
  - 既定が**オプトアウト型（何でも通る）**であり、オプトイン型（既定で拒否）になっていない。
- **セキュリティ上、改善した方がよいこと**
  - クライアント A は `audience=https://api.example.com/` を指定するだけで、
    その値を `aud` に持つアクセストークンを正規に発行させられる。
    `https://api.example.com/` を自分の識別子とみなす RFC 9068 準拠のリソースサーバは、
    `aud` チェックだけでは**このトークンを拒否できない**。
    実際の可否は RS 側の `iss` 検証・`scope` 検証・`client_id` 認可に依存するが、
    「AS が発行する `aud` を要求者が決められる」状態は、audience restriction という
    防御層そのものを無効化している。
  - 影響は「同一 OP を信頼している複数リソースサーバ」の構成で顕在化する。
    本リポジトリは PoC / 検証用途を想定しており、まさにその構成が典型的に作られる。
  - 攻撃前提: 攻撃者が何らかのクライアント（自分で登録した、あるいは public client）を使えること。
    エンドユーザの認証は必要であり、認証なしにトークンが出るわけではない。
    したがって「即時に他人の権限を奪う」種類の脆弱性ではなく、
    **audience による適用範囲限定が機能しない**という設計上の欠落として評価するのが妥当。
- **相互運用性の観点**
  - パラメータ名が標準（RFC 8707 の `resource`）ではないため、標準準拠クライアントは
    そもそもこの機能を使えず、逆に非標準名を知る者だけが自由に使える、という非対称がある。
  - `invalid_target` が無いため、拒否時のエラー表現も標準と噛み合わない。
- **Basic OP として提供する上で確認すべきこと**
  - Basic OP の必須要件ではない。ただし Basic OP conformance では `audience` を送らないため、
    **conformance が緑でもこの欠落は検出されない**。契約テストで別途固定する必要がある。

## 6. 改善・追加を検討する理由

- **なぜ価値があるか**: 現状は「audience を絞る機能」を提供しているように見えて、
  絞る主体がクライアント自身であるため、セキュリティ機構として機能していない。
  利用者が本リポジトリで multi-resource 構成を PoC したとき、
  **本番 IdaaS へ移行した瞬間に挙動が変わる**（IdaaS は許可されない audience を拒否する）。
  「PoC から本番へのブリッジ」というコンセプトに対し、誤った成功体験を与えてしまう。
- **Basic OP として必要か、拡張として有用か**: Basic OP 必須ではない。
  ただし「既に出荷済みの独自機能にガードが無い」という性質上、
  新機能追加よりも優先度が高い種類の是正である。
- **導入しやすさ**: 合成ポリシーが `buildAccessTokenAudience` と `parseAudienceParameter` の
  2 関数に集約されているため、**ガードの差し込み点が少なく導入しやすい**。
  一方で、既定の挙動を変えると（＝既定で拒否にすると）既存利用者・既存サンプル・
  conformance フィクスチャ（`templates.ts` L7192 付近の `audience: [USERINFO_AUD, 'https://api.example.com']`）に
  影響するため、後方互換の扱いを決める必要がある。
- **既存実装との接続**: `ClientInfo` にクライアント登録メタデータを追加する余地があり
  （`responseTypes` / `defaultMaxAge` / `jwks` と同じ場所）、
  許可 audience の一覧または resolver をここに置ける。
- **利用者・開発者・運用者のメリット**: 「audience を絞ると何が守られるのか」を
  実際に体験できるようになる。現状は絞ったつもりでも守られない。
- **実装しない場合に残る制約・リスク**
  - multi-resource / API Gateway 構成の検証が実態と乖離したまま行われる。
  - RFC 8707 対応（📌 `ext-resource-indicators-rfc8707.md`）を後から入れる際に、
    無検証の `audience` との併存ポリシーを必ず決めることになり、
    そのときに**既存利用者の挙動を壊す変更**が必要になる（先送りするほど高くつく）。

## 7. 実装方針の候補

いずれも**人間の判断が必要**。特に「既定を拒否にするか」は後方互換に直結する。

### 方針A（構文検証のみ追加。認可判定は入れない）

- `parseAudienceParameter` で各値が絶対 URI であること・fragment を含まないことを検証し、
  違反は `invalid_request`（リダイレクト可能エラー）で拒否する。
- 利点: 後方互換の影響が小さい（正しい URI を送っている既存利用者は無影響）。
- 欠点: **本質的な問題（誰でも任意の audience を要求できる）は解決しない。**

### 方針B（resolver 注入による許可判定。既定は拒否）

- `ValidateAuthorizationRequestOptions` に許可判定コールバックを追加する
  （`isOfflineAccessGranted` と同じ注入パターンで、リポジトリの既存作法に沿う）。
- 未注入時の既定を「`audience` が指定されたら拒否」または「`audience` を無視して落とす」にする。
  - `offline_access` の既定挙動（許可条件を満たさなければ **scope から除外する**、
    `applyOfflineAccessPolicy`）と揃えるなら「無視して落とす」が一貫する。
  - 明示的に失敗させたいなら `invalid_target` を追加して拒否する。
- 利点: セキュリティ既定が安全側になり、利用者は明示的にポリシーを書くことになる。
- 欠点: 既定の挙動が変わるため破壊的。sample / conformance フィクスチャの更新が必要。

### 方針C（クライアント登録メタデータで許可 audience を宣言する）

- `ClientInfo` に許可 audience の配列を追加し、その部分集合のみ受理する。
- 利点: 静的クライアント登録が前提の Basic OP と相性が良く、resolver 実装が不要。
- 欠点: 動的な許可判定（テナント単位など）には向かない。方針B と併用も可能。

### 方針D（`audience` を廃止し RFC 8707 `resource` に一本化する）

- 📌 `ext-resource-indicators-rfc8707.md` の方針A と統合し、
  独自 `audience` を非推奨化 → 削除する。
- 利点: 標準に寄り、パラメータが 1 系統になる。
- 欠点: 破壊的変更。RFC 8707 対応の実装完了まで、現状の欠落が残り続ける。

### 決めるべき論点（判断材料）

| 論点 | 選択肢 | 影響 |
|---|---|---|
| 既定の挙動 | 通す / 無視して落とす / 拒否する | 後方互換・安全性のトレードオフ |
| 拒否時のエラー | `invalid_request` / 新設 `invalid_target` | 標準準拠度。`invalid_target` は enum 追加が必要 |
| 許可判定の置き場所 | resolver 注入 / クライアント登録メタデータ / 両方 | 静的クライアント前提とのフィット |
| `audience` の将来 | 存置 / 非推奨 / `resource` へ統合 | `ext-resource-indicators-rfc8707.md` と同時に決めるべき |
| 適用範囲 | 認可エンドポイントのみ / トークンエンドポイントにも | RFC 8707 は両方で `resource` を受理する |

## 8. タスク案

> 本トピックは既定挙動の変更（後方互換）と `ext-resource-indicators-rfc8707.md` との統合可否が
> 未決のため、**現時点ではタスク化しない**。下記は方針決定後に切り出す想定の作業単位。

- [ ] 方針A / B / C / D を選択（人間判断）。特に「既定を拒否にするか」を決める
- [ ] 📌 `study-material/ext-resource-indicators-rfc8707.md` と同時に判断する
      （`audience` と `resource` の併存ポリシーは片方だけでは決められない）
- [ ] 決定後: 許可されない audience が拒否される／落とされることのテストを先行作成する
- [ ] 決定後: `parseAudienceParameter` に構文検証を追加する（絶対 URI・fragment 禁止）
- [ ] 決定後: 許可判定の注入点（resolver または `ClientInfo` メタデータ）を実装する
- [ ] 決定後: `invalid_target` を追加する場合は `AuthorizationErrorCode` / `TokenErrorCode` を拡張する
- [ ] 決定後: `packages/cli` のテンプレートを同期し、各 sample の `conformance.test.ts` に
      「許可されない audience が `aud` に載らない」契約を追加する
      （conformance suite では検出されないため、契約テストで固定することが必須）
- [ ] 決定後: refresh ローテーション時に保持される audience が、
      ポリシー変更後も過去の未検証値を引き継がないことを確認する（移行時の注意点）

## 関連トピック

- 📌 `study-material/ext-resource-indicators-rfc8707.md` — 標準 `resource` パラメータ採用の可否。**本ファイルと同時に判断すること**
- 📌 `study-material/done/userinfo-access-token-audience-validation.md` — 受領側の `aud` 検証（発行側の本ファイルと対）
- 📌 `tasks/p1-jwt-access-token-aud-default.md` — `aud` の既定値・非空保証
- 📌 `study-material/jwt-access-token-rfc9068.md` — RFC 9068 全体の充足状況の俯瞰
- 📌 `study-material/done/untrusted-input-payload-size-dos-hardening.md` — 未認証入力のサイズ上限（`audience` の長さ上限もここに接続しうる）
