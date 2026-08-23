# [P3] RFC 8707 検討文書の現状整理を訂正する（refresh 時の resource narrowing 未対応・章番号・陳腐化した行参照）

## ステータス

🟢 Low / 未着手

## 背景

`study-material/ext-resource-indicators-rfc8707.md` は RFC 8707（Resource Indicators）の
導入検討文書だが、**現状整理に事実誤認と陳腐化がある**。

検討文書の「満たしていること／不足していること」の整理は、
後続の方針判断（方針A/B/C の選択）の土台になる。
土台が間違っていると、**「refresh は対応済み」という前提のまま方針が選ばれてしまう**。

訂正すべき点は 4 つある。

### (1) refresh 時の resource narrowing が未対応であることが書かれていない

現在の記述:

> - refresh: `RefreshTokenInfo.audience` を保持しローテーション後も同 aud（done T-002）。

> - **満たしていること**: audience を認可〜トークン〜refresh で一貫保持する仕組みは既にある。

RFC 8707 §2.2（Access Token Request）は
**"for all grant types"** と明記したうえで、
`grant_type=refresh_token` に `resource` を付けて
**元 grant と違う resource 向けの狭いアクセストークンを取る例を Figure 5 / 6 で示している**。
これが RFC 8707 の中心的なユースケースである。

つまり「保持する」と「絞れる」は別要件であり、
本 OP は **前者だけを満たし、後者は未対応**である
（`buildValidatedRefreshTokenRequest` は `audience: refreshTokenInfo.audience` を
無条件に複製するだけ。`packages/core/src/refresh-token-grant.ts:181`）。

現在の記述はこれを「満たしていること」に分類してしまっている。

### (2) `invalid_target` の章番号が誤っている

現在の記述:

> - §2.2: 要求リソースが許可されない場合、`invalid_target` エラーを返す。
> - RFC 8707: https://www.rfc-editor.org/rfc/rfc8707
>   - §2 Resource Parameter / §2.2 `invalid_target`

RFC 8707 の実際の構成は次のとおり。

- §2 Resource Parameter（`invalid_target` の記述はここ）
  - §2.1 Authorization Request
  - **§2.2 Access Token Request**（refresh を含む access token request の話）
- §5.2 OAuth Extensions Error Registration（`invalid_target` の IANA 登録）

→ §2.2 は `invalid_target` の節ではなく **Access Token Request の節**である。
この誤りが (1) の見落としと繋がっている可能性が高い。

### (3) 参照 URL が本リポジトリの調査環境から到達できない

`https://www.rfc-editor.org/rfc/...` は、本リポジトリの調査で使う実行環境の
ネットワークポリシーで遮断される（CONNECT tunnel failed / 403）。
`https://datatracker.ietf.org/doc/html/...` は到達できる。

`study-material/basic-op-requirements-baseline.md` も
同種のネットワーク制約を注記している。参照先を到達可能な URL に揃えると、
後から人間・AI のどちらが確認する場合も一次資料に当たれる。

### (4) 行参照が陳腐化している

現在の記述:

> - `token-response.ts:222`: `const accessTokenAud = audience ?? [];`
>   → リソース指定が無いと空配列（p1-jwt-access-token-aud-default で別途対応予定）。

この行は既に存在しない。現在は `buildAccessTokenAudience`
（`packages/core/src/token-response.ts:203-214`）が
UserInfo エンドポイントを恒久メンバとして先頭に含め、
空なら `issuer` へフォールバックすることで RFC 9068 §3（`aud` 非空）を満たしている。
`tasks/done/p1-jwt-access-token-aud-default.md` は **完了済み**である。

> 認可リクエストの行参照（`authorization-request.ts:46-48,572-577`）も現在の
> `parseAudienceParameter`（:1089-1097）とずれている。
> 併せて確認・更新すること。
> なお、リポジトリ全体のパス参照崩れは
> `tasks/p2-doc-path-reference-repair-and-link-check.md` が扱う。
> 本タスクは RFC 8707 文書 1 本の**内容の正確性**に限定する。

## 対象ファイル

- `study-material/ext-resource-indicators-rfc8707.md`

## 仕様参照

- **RFC 8707（Resource Indicators for OAuth 2.0）**
  <https://datatracker.ietf.org/doc/html/rfc8707>
  - **§2 Resource Parameter** — `resource` の構文（絶対 URI、fragment 禁止、
    query は SHOULD NOT だが許容、**複数指定可**）。`invalid_target` の記述もここ
  - **§2.2 Access Token Request** — 逐語:
    > When the `resource` parameter is used on an access token request made to the token endpoint,
    > **for all grant types**, it indicates the target service or protected resource where the
    > client intends to use the requested access token.
    >
    > The resource value(s) that is acceptable to an authorization server in fulfilling an access
    > token request is at its **sole discretion based on local policy or configuration**. In the
    > case of a **`refresh_token` or `authorization_code` grant type request, such policy may limit
    > the acceptable resources to those that were originally granted by the resource owner or a
    > subset thereof.**
    >
    > In the `authorization_code` case where the requested resources are a subset of the set of
    > resources originally granted, the authorization server will issue an access token based on
    > that subset of requested resources, whereas **any refresh token that is returned is bound to
    > the full original grant.**
    - Figure 5 / 6: `grant_type=refresh_token` ＋ `resource=https://contacts.example.com/` で
      元 grant と異なる resource 向けのアクセストークンを得る例
  - **§5.2 OAuth Extensions Error Registration** — `invalid_target` の IANA 登録
- **RFC 9068 §3 Data Structure**
  <https://datatracker.ietf.org/doc/html/rfc9068> — JWT アクセストークンの `aud` は非空必須

## 現状の実装

訂正の根拠となる現在のコード。

### refresh は audience を複製するだけで、絞れない

`packages/core/src/refresh-token-grant.ts:170-192`:

```ts
export function buildValidatedRefreshTokenRequest(refreshTokenInfo, authenticatedClientId, effectiveScope) {
  return {
    grantType: 'refresh_token',
    ...
    scope: effectiveScope,                  // ← scope には縮小の仕組みがある
    audience: refreshTokenInfo.audience,    // ← audience は無条件に複製
    ...
  };
}
```

`scope` 側には `validateRefreshTokenScope`（同 :136-165）があるが、
`audience` に対応する関数は無い。

### トークンエンドポイントは `resource` を受け取れない

`packages/core/src/token-request.ts:45-58` の `TokenRequestParams` に
`resource` / `audience` は無い。

### `buildAccessTokenAudience` は現在の実装

`packages/core/src/token-response.ts:203-214`:

```ts
export function buildAccessTokenAudience(input: AccessTokenAudienceInput): string[] {
  const { userInfoEndpoint, requested, issuer } = input;
  const members: string[] = [];
  if (userInfoEndpoint) members.push(userInfoEndpoint);
  if (requested) members.push(...requested);
  const deduped = [...new Set(members)];
  return deduped.length > 0 ? deduped : [issuer];
}
```

→ 「リソース指定が無いと空配列」という現在の記述は誤り。既に非空フォールバックがある。

## 修正方針

- [ ] `study-material/ext-resource-indicators-rfc8707.md` の §2（関連する仕様・基準）
  - [ ] `§2.2: 要求リソースが許可されない場合、invalid_target エラーを返す。` を訂正する
    - `invalid_target` の記述は §2、IANA 登録は §5.2 であることを明記
    - **§2.2 は Access Token Request の節**であり、
      "for all grant types"／refresh 時のポリシー裁量／Figure 5-6 の例を要約して追記する
- [ ] 同 §3（参照資料）
  - [ ] `https://www.rfc-editor.org/rfc/rfc8707` → `https://datatracker.ietf.org/doc/html/rfc8707`
  - [ ] `https://www.rfc-editor.org/rfc/rfc9068#section-3` →
        `https://datatracker.ietf.org/doc/html/rfc9068`（§3 を本文で示す）
  - [ ] 到達性の注記を 1 行入れる（`basic-op-requirements-baseline.md` と同様の書き方に揃える）
- [ ] 同 §4（現在の実装確認）
  - [ ] `refresh: ... 保持しローテーション後も同 aud` の行に、
        **「ただし RFC 8707 §2.2 が主眼とする refresh 時の narrowing（`resource` 指定による
        aud 縮小）は未対応」**を追記する
  - [ ] `token-response.ts:222` の行を削除し、
        `buildAccessTokenAudience`（`packages/core/src/token-response.ts:203-214`）の
        現在の挙動に置き換える。`tasks/done/p1-jwt-access-token-aud-default.md` が
        完了済みであることを明記する
  - [ ] 認可リクエストの行参照（`authorization-request.ts:46-48,572-577`）を
        現在の `parseAudienceParameter`（:1089-1097）へ更新する
- [ ] 同 §5（現在の実装との差分）
  - [ ] 「満たしていること」から「refresh で一貫保持」を **そのまま残しつつ**、
        「不足している可能性があること」に
        **「refresh 時の resource 指定による audience 縮小が未対応（RFC 8707 §2.2）」**を追加する
- [ ] 同「関連トピック」
  - [ ] `study-material/done/refresh-grant-resource-parameter-audience-narrowing-rfc8707.md` への
        参照を追加する（refresh 経路の差分を扱う子トピックであること）
  - [ ] `study-material/token-exchange-audience-narrowing-vs-userinfo-permanent-membership.md` への
        参照を追加する（narrowing を入れても UserInfo が aud に残る問題は共通）

## テスト要件

本タスクは文書の訂正のみで、コードは変更しない。
したがって自動テストは追加しないが、次を人手で確認する。

- [ ] 訂正後の §2 の記述が、RFC 8707 の実際の節構成
      （§2 / §2.1 / §2.2 / §5.2）と一致していること
- [ ] 訂正後の §4 に記載したすべてのファイルパスと行番号が、
      現在の `HEAD` のコードと一致していること
- [ ] 訂正後の §3 のすべての URL が到達可能であること
      （`curl -sS -o /dev/null -w "%{http_code}" <url>` が 200 を返す）
- [ ] `study-material/done/refresh-grant-resource-parameter-audience-narrowing-rfc8707.md` と
      記述が矛盾していないこと（同じ仕様説明を重複させないこと）

## 完了条件

- [ ] 上記の 4 点（refresh narrowing / 章番号 / URL / 行参照）がすべて訂正されている
- [ ] `pnpm --filter "./packages/*" test` が通る（コード変更が無いことの確認）
- [ ] 方針A/B/C の選択そのものは **本タスクでは行わない**
      （`study-material/done/refresh-grant-resource-parameter-audience-narrowing-rfc8707.md` §7 と
      `study-material/authorization-audience-parameter-unvalidated-token-audience.md` の
      併存ポリシーと同時に人間が決める）
