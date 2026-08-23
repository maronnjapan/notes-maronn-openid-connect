# Token Exchange の audience 縮小が UserInfo エンドポイントに対して効かない（`openid` scope 継承との複合）

## ステータス

🟠 High（縮小モデルの穴 / PII 露出面の拡大）/ 未着手

## 1. このトピックで確認したいこと

`packages/experimental/src/token-exchange` は、モジュール冒頭で自身のセキュリティ設計の中核を
こう宣言している。

> 交換で権限が単調に狭まること（scope は部分集合・audience は許可リスト内・
> 寿命は subject_token の残存期間以下・`sub` は変更不可）が本モジュールの
> セキュリティ設計の中核である。

このうち **audience だけが単調に狭まらない**。クライアントが
`audience=https://downstream.example/api` を明示して「downstream 専用の狭いトークン」を要求しても、
生成コードが `buildAccessTokenAudience()` を通す過程で
**OP 自身の UserInfo エンドポイントが恒久メンバとして無条件に再追加される**。

結果として、交換で得たトークンを渡された downstream サービスは、
そのトークンで **OP の UserInfo エンドポイントを呼びエンドユーザの PII を読める**。

確認したいのは次の 3 点。

1. これは「audience を絞る」という交換の目的に対して意図された挙動か、見落としか
2. `openid` scope の既定継承（scope 省略時は subject の scope をそのまま継承）との複合で
   露出面がどこまで広がるか
3. RFC 8693 / RFC 9068 の観点で、どちらの規則を優先すべきか

> 重複回避:
> - Token Exchange 拡張の導入検討そのものは `study-material/ext-token-exchange-rfc8693.md`（実装前の検討文書）。
> - UserInfo でアクセストークンの `aud` を検証する仕組み自体は
>   `study-material/done/userinfo-access-token-audience-validation.md` /
>   `tasks/done/p2-userinfo-access-token-audience-validation.md`。
>   本ファイルは**その検証が正しく動いた結果として交換トークンが通ってしまう**という逆向きの論点。
> - `aud` 合成ポリシー（`buildAccessTokenAudience`）そのものは
>   `study-material/authorization-audience-parameter-unvalidated-token-audience.md` が
>   「認可リクエストの `audience` パラメータが無検証」という別の問題を扱う。
>   本ファイルは Token Exchange 経路に限定する。
> - 誰が交換してよいかという認可モデルは
>   `study-material/token-exchange-authorization-model-allowed-targets-and-subject-token-binding.md`。

## 2. 関連する仕様・基準（このトピック固有の差分）

### 2.1 RFC 8693 §2.1 — `audience` / `resource` の意味

`audience` と `resource` は、クライアントが
**「発行されるトークンをどこで使いたいか」を AS に伝える**パラメータである。
一次資料の定義（2026-08-06 確認）:

- `resource`: "A URI that indicates the target service or resource where the client
  intends to use the requested security token."
- `audience`: "The logical name of the target service where the client intends to use
  the requested security token."

いずれも **"where the client intends to use"（どこで使うつもりか）** を表明するもので、
AS がこの要求を尊重できない場合は `invalid_target` を返すことになっている。

「要求した対象に加えて OP 自身の PII エンドポイントも常に付いてくる」挙動は、
クライアントが表明した使用先の範囲を AS 側が独断で広げていることになる。

### 2.2 RFC 9068 §3 — `aud` は非空でなければならない

`buildAccessTokenAudience` が UserInfo エンドポイントを恒久メンバにしている直接の動機は
RFC 9068 §3 の「`aud` は非空」要求ではない（それは `issuer` フォールバックで満たせる）。
実際の動機はコード内コメントのとおり、
**「このアクセストークンは常に OP 自身の UserInfo エンドポイントで使用できる」**という
通常のトークン発行経路（authorization_code / refresh_token）の設計方針である。

つまり **RFC 9068 §3 は UserInfo の恒久メンバ化を要求していない**。
これは本 OP の設計判断であり、Token Exchange 経路にも適用すべきかは別途判断が必要になる。

### 2.3 OIDC Core 1.0 §5.3.1 — UserInfo のアクセス条件

UserInfo エンドポイントは `openid` scope を持つアクセストークンでのみ利用できる。
本 OP の `validateUserInfoScope()` はこれを実装している。
したがって **`openid` を落とせば UserInfo アクセスは遮断できる**。
問題は、交換時に `scope` を省略すると subject の scope（通常 `openid` を含む）を
そのまま継承する既定にある。

### 2.4 RFC 8693 §5 Security Considerations

RFC 8693 の Security Considerations は **§5**（§7 ではない）である。
一次資料の文言（2026-08-06 確認）:

> Any time one principal is delegated the rights of another principal, the potential
> for abuse is a concern.

> The use of the `scope` claim (in addition to other typical constraints such as a
> limited token lifetime) is suggested to mitigate potential for such abuse.

RFC が濫用抑止の主たる手段として挙げているのは **`scope` の制限とトークン寿命の制限**であり、
`aud` の限定は明示的に挙げられていない。本 OP は寿命の制限を正しく実装し、
scope も部分集合検証を実装しているが、**`openid` の既定継承によって
「scope による濫用抑止」が既定では働かない**構造になっている点が本トピックの核心である。

## 3. 参照資料

- RFC 8693 §2.1 Request（`audience` / `resource` の定義 "where the client intends to use
  the requested security token"、`scope`、`invalid_target`）
  — https://www.rfc-editor.org/rfc/rfc8693#section-2.1
- RFC 8693 §5 Security Considerations（濫用抑止の手段として `scope` 制限とトークン寿命制限を挙げる。
  **Security Considerations は §5 であり §7 ではない**）
  — https://www.rfc-editor.org/rfc/rfc8693#section-5
- RFC 9068 §3 Validating JWT Access Tokens / §2.2（`aud` は非空）
  — https://www.rfc-editor.org/rfc/rfc9068#section-3
- OIDC Core 1.0 §5.3.1 UserInfo Request（`openid` scope が必要）
  — https://openid.net/specs/openid-connect-core-1_0.html#UserInfoRequest
- RFC 8707 Resource Indicators for OAuth 2.0（`resource` による対象限定の考え方）
  — https://www.rfc-editor.org/rfc/rfc8707

## 4. 現在の実装確認

### 4.1 縮小を担う experimental 側

`packages/experimental/src/token-exchange/token-exchange-request.ts`:

- `validateExchangeScope(requestedScope, subjectScope)`
  — 要求 scope が省略／空白のみなら **subject の scope をそのまま継承**する。

  ```ts
  const requested = splitScope(requestedScope);
  if (requested.length === 0) {
    return [...subjectScope];      // openid もそのまま引き継がれる
  }
  ```

- `resolveExchangeTarget({ audience, resource, allowedTargets, subjectAudience })`
  — `audience` / `resource` が指定されたら `allowedTargets` で検証し、**その値だけ**を返す。
    ここまでは正しく縮小している。

  ```ts
  const targets: string[] = [];
  for (const requested of [audience, resource]) { ... targets.push(requested); }
  return [...new Set(targets)];    // ← UserInfo は含まれない
  ```

- `processTokenExchangeRequest()` は `requestedAudience` としてこれを返すだけで、
  **最終的な `aud` は組み立てない**（JSDoc にも「戻り値は最終的な `aud` ではない」と明記）。

### 4.2 恒久メンバを足す生成コード側

`packages/cli/src/frameworks/hono/templates.ts`（token-exchange 分岐）:

```
// Same aud policy as the standard token route: the UserInfo endpoint stays
// a permanent member (RFC 9068 §3), so an exchanged token still passes the
// UserInfo endpoint's audience check.
const exchangeAudience = buildAccessTokenAudience({
  userInfoEndpoint: `${exchangeConfig.issuer}/userinfo`,
  requested: grant.requestedAudience,
  issuer: exchangeConfig.issuer,
});
```

`buildAccessTokenAudience`（`packages/core/src/token-response.ts` L203-214）は
`userInfoEndpoint` を**先頭に必ず push し、取り除かない**:

```ts
if (userInfoEndpoint) {
  members.push(userInfoEndpoint);
}
if (requested) {
  members.push(...requested);
}
```

コメントが示すとおり、これは**意図的な設計**である
（「an exchanged token still passes the UserInfo endpoint's audience check」）。
つまり見落としではなく、**通常経路の方針を Token Exchange にもそのまま適用した判断**である。
本ファイルはその判断の妥当性を論点にする。

### 4.3 実際に発行される値

クライアントが `audience=https://downstream.example/api`、`scope` 省略で交換した場合:

| 項目 | 値 |
|---|---|
| 要求した対象 | `https://downstream.example/api` のみ |
| 実際の `aud` | `["<issuer>/userinfo", "https://downstream.example/api"]` |
| `scope` | subject の scope をそのまま継承（`openid profile email` 等） |
| `sub` | エンドユーザ（不変） |

このトークンを受け取った downstream は、`validateUserInfoScope`（`openid` あり）と
`validateUserInfoAudience`（`aud` に UserInfo が含まれる）の**両方を通過する**ため、
`GET /userinfo` でエンドユーザの `email` / `profile` 等を取得できる。

### 4.4 緩和されている点（正確に評価するために）

- ✅ `claims` パラメータは意図的に継承されない（テンプレートのコメントに明記）。
  したがって取得できるのは **scope 由来のクレームのみ**で、`claims` で個別要求された
  クレームまでは漏れない。
- ✅ クライアントが `scope` を明示して `openid` を除けば、UserInfo アクセスは遮断できる。
  **securable ではあるが、既定では securable でない**。
- ✅ `allowedTargets` の既定は空配列であり、対象を指定する交換は既定で全て `invalid_target`。
  つまり **既定構成ではこの経路は発生しない**。利用者が downstream を allowlist に
  登録して初めて顕在化する。

## 5. 現在の実装との差分

### 満たしていること

- ✅ scope の縮小（部分集合検証）は正しく機能する。
- ✅ 寿命の単調減少（`min(configured, 残存)`）は正しく機能する。
- ✅ `sub` は変更されない（impersonation の範囲を出ない）。
- ✅ `grantId` を継承するため、grant 単位の失効が交換トークンにも波及する。
- ✅ `allowedTargets` 既定空により、fail-safe な初期状態になっている。

### 不足している可能性があること

- 🟠 **audience の単調縮小が成立していない**。
  モジュールが自ら掲げる「audience は許可リスト内」という不変条件は満たすが、
  「要求より広くならない」という不変条件は満たさない。
  設計意図の記述と実挙動の間にギャップがある。
- 🟠 **`openid` の既定継承と複合して PII 露出面が広がる**。
  対象を明示して狭めたつもりのトークンが、常に OP の PII エンドポイントへの鍵を兼ねる。
  下流サービスへトークンを渡すという Token Exchange の主用途において、
  **blast radius を縮められない**。

### 実装はあるが仕様上の確認が必要なこと

- 🟡 **「UserInfo は恒久メンバ」方針の適用範囲**。
  authorization_code / refresh_token 経路でこの方針は妥当である
  （そのトークンはクライアント自身が使うものであり、UserInfo を使えて当然）。
  Token Exchange は**トークンを第三者へ渡すための機構**であり、前提が異なる。
  同じ方針を機械的に適用してよいかは仕様というより設計判断の問題であり、明示的な決定が要る。

### セキュリティ上、改善した方がよいこと

- 🟠 既定を fail-safe 側に倒す余地がある。
  「対象が明示されたら UserInfo を外す」または「対象が明示されたら `openid` を落とす」の
  どちらかを既定にすれば、利用者が意識せずとも縮小が成立する。

### 相互運用性の観点で改善した方がよいこと

- 🟢 相互運用性の問題は無い（RFC 8693 は `aud` の具体的合成を規定しない）。

### Basic OP として提供する上で確認すべきこと

- 🟢 Token Exchange は Basic OP の要件外であり、**Basic OP 認証の合否には影響しない**。
  本件は拡張機能の設計品質の問題である。

## 6. 改善・追加を検討する理由

- **セキュリティ方針との整合**: 本リポジトリの実装方針は「仕様準拠を第一、次にセキュリティ、
  次に OSS 利用者の使いやすさ」である。モジュールが明文で掲げた不変条件が
  一次元だけ破れている状態は、方針の優先順位から見て放置しにくい。
- **利用者の誤解を招く**: `allowedTargets` に downstream を登録した利用者は、
  「このトークンは downstream でしか使えない」と理解するのが自然である。
  実際には OP の UserInfo でも使えることは、コードを読まないと分からない。
- **導入しやすさ**: 修正箇所は生成テンプレートの `buildAccessTokenAudience` 呼び出し
  1 箇所（`userInfoEndpoint` を条件付きで渡す）か、
  experimental 側の `validateExchangeScope` の既定（対象指定時に `openid` を落とす）の
  どちらかに閉じる。**core は無変更で済む**。
- **既存実装との接続**: `buildAccessTokenAudience` は `userInfoEndpoint` を optional
  引数として受けるため、渡さないだけで挙動を変えられる。
  その場合 `requested` が非空なら `aud` は非空になり、RFC 9068 §3 も満たしたままになる。
- **実装しない場合に残るリスク**:
  - 交換トークンを受け取った下流サービスが、意図せず PII 読み取り能力を持つ。
  - 「単調に狭まる」という設計上の売り文句が実装で裏付けられていない状態が残る。
  - PoC 利用者がこの OP の挙動を参考に本番設計を組むと、同じ穴を持ち込む。

## 7. 実装方針の候補（最終判断は人間）

### 方針A: 対象が明示された交換では UserInfo を `aud` に含めない

```ts
const exchangeAudience = buildAccessTokenAudience({
  // 対象が明示された交換は「下流専用トークン」の要求なので UserInfo を含めない。
  userInfoEndpoint: grant.requestedAudience === undefined
    ? `${exchangeConfig.issuer}/userinfo`
    : undefined,
  requested: grant.requestedAudience,
  issuer: exchangeConfig.issuer,
});
```

- 対象未指定（scope 縮小・寿命短縮のみの交換）では従来どおり UserInfo を含める。
- 対象指定時は `requested` が非空なので `aud` も非空を維持できる（RFC 9068 §3 は満たす）。
- メリット: 「要求より広くならない」を実装で保証できる。変更は 1 箇所。
- デメリット: 「対象を指定しつつ UserInfo も使いたい」ユースケースは
  UserInfo エンドポイントを明示的に `audience` に含めて要求する必要がある
  （`allowedTargets` に UserInfo URL を登録すれば表現できる）。

### 方針B: 対象が明示された交換では `openid` を実効 scope から落とす

- `validateExchangeScope` の呼び出し側で、対象指定時に `openid` を除外する。
- メリット: UserInfo だけでなく、`openid` を前提とする他の OIDC 機能からも一律に切り離せる。
- デメリット: `aud` は依然として UserInfo を含むため「aud が要求より広い」状態は残り、
  不変条件の記述と実装のギャップは解消しない。scope と aud のどちらで守るかが曖昧になる。

### 方針C: 両方（A + B）

- 対象指定時は UserInfo を `aud` から外し、かつ `openid` を落とす。
- メリット: 多層防御。どちらか一方の実装を将来壊しても縮小が保たれる。
- デメリット: 挙動の変化が大きく、既存利用者（いれば）への影響が読みにくい。
  experimental であることを踏まえれば許容範囲とも言える。

### 方針D: 現状維持＋明文化

- 挙動は変えず、生成コードの `tokenExchangeConfig` コメントと
  `docs/library-document` の Experimental セクションに
  「交換トークンは常に UserInfo を呼べる。下流へ渡す場合は `scope` から `openid` を
  明示的に除くこと」と警告を書く。
- メリット: 変更ゼロ。既存の挙動に依存する利用者を壊さない。
- デメリット: 既定が安全でない状態が残る。ドキュメントを読まない利用者は守られない。

### 判断材料

- **既定構成では顕在化しない**（`allowedTargets` が空）ため、緊急度は中程度と評価できる。
  一方、`allowedTargets` を設定した瞬間に静かに顕在化するため、
  「設定したら安全でなくなる」という性質は望ましくない。
- experimental パッケージは API 不安定を明言しているため、
  **破壊的変更を入れやすいタイミングである**ことは方針 A / C に有利。
- 方針 A は「UserInfo を使いたければ明示的に要求する」という
  RFC 8707 / RFC 8693 の対象指定モデルに素直で、仕様の思想と整合する。
- 方針 D を採るなら、モジュール冒頭の「audience は許可リスト内」という記述を
  「要求より狭くなるとは限らない」と正確に書き直す必要がある
  （現状の記述は読み手に単調縮小を期待させる）。

## 8. タスク案

- [ ] 方針 A / B / C / D のどれを採るかを人間が判断する
- [ ] 方針 A / C 採用時:
  - [ ] 生成テンプレートの token-exchange 分岐で、`grant.requestedAudience` の有無により
        `userInfoEndpoint` を渡すか切り替える
  - [ ] `resolveExchangeTarget` の JSDoc に、対象指定が `aud` の縮小要求である旨を追記する
  - [ ] `accessTokenStore.set` に保存する `audience` も同じ値になることを確認する
        （UserInfo の `validateUserInfoAudience` は保存値を見るため）
- [ ] 方針 B / C 採用時:
  - [ ] 対象指定時に `openid` を落とす規則を experimental 側のステップ関数として実装する
  - [ ] 落とした結果 scope が空になる場合の挙動を決める
- [ ] テスト要件:
  - [ ] 対象を明示した交換トークンで `GET /userinfo` を呼び、方針に応じた結果
        （401 `invalid_token` / 403 `insufficient_scope` / 200）を固定する
  - [ ] 対象未指定の交換トークンでは従来どおり UserInfo が使えることを回帰テストで固定する
  - [ ] 発行された `aud` の要素と順序を `toEqual` で固定する
  - [ ] `conformance.test.ts`（token-exchange 有効時）に上記を追加する
- [ ] 方針 D 採用時: モジュール冒頭のセキュリティ設計の記述を実装に合わせて正確に書き直す
