# [P1] `refresh_token` grant 未登録のクライアントへ使用不能な Refresh Token を発行しない

## ステータス

🟢 完了 / 方針 C ではなく方針 A + online refresh token として実装

本タスクは当初「使えない Refresh Token を配らない安全網」（`study-material/done/offline-access-grant-vs-client-grant-types-consistency.md` の方針 C）だけを対象にしていた。
実装時に、その前提だった「認可エンドポイントは `grant_types` を構造的に参照できない」を解消する方向へ判断が変わり、方針 A（独自フラグ `offlineAccessAllowed` を廃止して標準メタデータへ一本化）を採った。
あわせて online refresh token を実装し、`offline_access` の有無が「セッションに束縛されるか」の違いになるようにした。

実装した内容は次のとおり。

- `ClientInfo` に `grantTypes` を追加し、`OfflineAccessGrantedCallback` の context に `client` を渡す。既定判定を「`prompt=consent` かつ `grant_types` に `refresh_token` を含む」に変更した（`packages/core/src/authorization-request.ts`）
- `grant_types` の既定値（`["authorization_code"]`）の解釈を `packages/core/src/client-grant-types.ts` に集約し、認可エンドポイントとトークンエンドポイントで同じ判定を使うようにした
- 生成コードから `offlineAccessAllowed` と、authorize / consent に重複していた scope フィルタを削除した
- online refresh token を追加した。`offline_access` を伴わない付与では、発行元のログインセッションへ束縛した Refresh Token を発行し、セッションが終われば `invalid_grant` になる（`RefreshTokenInfo.sessionId` / `validateRefreshTokenSession`）
- トークンエンドポイントは `grant_types` に `refresh_token` が無いクライアントへ Refresh Token を発行しない

「発行 scope から `offline_access` を落とすか」は不要になった。
`grant_types` を見た判定が認可エンドポイントで効くため、登録の無いクライアントには `offline_access` がそもそも付与されない。

## 背景

「このクライアントが Refresh Token を使えるか」が**2 つの独立したスイッチ**で表現されており、
両者を人手で同期させる必要がある。

| スイッチ | 定義場所 | 効く場所 | 標準か |
|---|---|---|---|
| `offlineAccessAllowed: boolean` | 生成コードの `config.ts`（`RegisteredClient`） | 認可エンドポイント（同意後の scope フィルタ） | ❌ 本リポジトリ独自 |
| `grantTypes` に `'refresh_token'` | `TokenClientInfo`（core の型） | トークンエンドポイント（`validateClientGrantType`） | ✅ RFC 7591 §2 / OIDC DCR §2 |

`offlineAccessAllowed: true` かつ `grantTypes` 未指定（既定 `['authorization_code']`）という
**最も起きやすい設定ミス**で、OP は Refresh Token を**発行するが、それは一度も使えない**。

再現手順（コードから導かれる帰結）:

1. クライアントを `offlineAccessAllowed: true` / `grantTypes` 未指定で登録する
2. `scope=openid offline_access&prompt=consent` で認可し、同意する
   → OIDC Core §11 の条件を満たすので `offline_access` が残る
   → 生成コードの `offlineAccessAllowed` フィルタも通す
3. `grant_type=authorization_code` でトークン取得
   → `validateClientGrantType` は `authorization_code` を許可（既定に含まれる）
   → **`refresh_token` が発行される。警告もエラーも出ない**
4. その Refresh Token で `grant_type=refresh_token` を叩く
   → `validateClientGrantType`（`packages/core/src/token-request.ts:460-471`）が
     `refresh_token` を既定リストに見つけられず **`unauthorized_client`**

発行時点では何も起きず、クライアントが実際にトークン更新を試みた時点で初めて壊れる
**遅延失敗（silent failure）**であり、PoC のデバッグを著しく困難にする。

セキュリティ境界は破れていない（fail-closed。未許可クライアントが悪用できるわけではない）。
ただし RFC 9700 §4.14 の趣旨に照らすと、使えない長期資格情報をクライアントに保存させるのは
価値ゼロで攻撃面だけを増やす。

本タスクは**症状（使えない RT を配らない）だけを最小コストで潰す安全網**を入れる。
`offlineAccessAllowed` を廃止して標準メタデータへ一本化するかは設計判断が未決のため、
本タスクの対象外とする。

詳細な検討・他方針の比較は
`study-material/done/offline-access-grant-vs-client-grant-types-consistency.md` を参照。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`（token ルートテンプレート）
- `packages/cli/src/frameworks/web-standard/templates.ts`（同上）
- `packages/cli/src/frameworks/express/templates.ts` / `fastify/templates.ts` / `nextjs/templates.ts`
  （token ルートを持つ系統すべて）
- 再生成対象: `samples/hono-cloudflare` / `samples/express-flyio` / `samples/fastify-flyio` /
  `samples/nextjs-vercel` の `src/**/routes/token.ts` と `conformance.test.ts`
- （方針次第）`packages/core/src/token-request.ts`

> `samples/*/src/oidc-provider` は CLI 生成物のため直接編集しないこと。
> 必ず `packages/cli` のテンプレートを修正して再生成する。

## 仕様参照

- **RFC 7591 §2 Client Metadata / OpenID Connect Dynamic Client Registration 1.0 §2**
  `grant_types` はクライアントがトークンエンドポイントで使用できる grant type の配列。
  **省略時の既定は `["authorization_code"]`** であり、`refresh_token` を使うクライアントは
  明示的に登録しなければならない。
- **OpenID Connect Core 1.0 §11 Offline Access**
  `offline_access` の付与には `prompt=consent`（または他の条件）が必要。
  これは**エンドユーザーの同意**という軸であり、`grant_types`（クライアント登録上の権限）とは直交する。
  本来 `offline_access` の付与判定には両方が必要。
- **RFC 6749 §5.1 Successful Response**
  `refresh_token` は OPTIONAL。「同じ authorization grant で新しいアクセストークンを得るために
  **使える**」トークンとして定義されている。使えないと分かっているトークンの発行は定義と齟齬する。
- **RFC 6749 §5.2 Error Response**
  `unauthorized_client` = 認証済みクライアントがその grant type を使う権限を持たない。
- **RFC 6749 §3.3 Access Token Scope**
  付与 scope が要求と異なる場合、レスポンスに `scope` を含める（本リポジトリは常に返している）。
- **RFC 9700 §4.14 Refresh Token Protection**
  Refresh Token を長期資格情報として扱い、露出・保存期間を最小化することを求める。

> 逐語確認は未実施（調査環境から openid.net / rfc-editor.org へのフェッチが遮断されていたため）。
> 実装前に RFC 7591 §2 の `grant_types` 既定値と OIDC Core §11 の条件文を一次資料で確認すること。

## 現状の実装

### 認可エンドポイント側: `grant_types` を構造的に参照できない

```ts
// packages/core/src/authorization-request.ts:105-133
export interface ClientInfo {
  clientId: string;
  redirectUris: string[];
  clientType?: 'confidential' | 'public';
  responseTypes?: string[];   // ← response_type の per-client 強制はある
  defaultMaxAge?: number;
  jwks?: JwkSet;
}
// ↑ grantTypes フィールドが無い。TokenClientInfo には有るのに非対称
```

```ts
// packages/core/src/authorization-request.ts:169-184
export const defaultIsOfflineAccessGranted: OfflineAccessGrantedCallback = (
  _request,
  { promptValues },
) => promptValues.includes('consent');
// ↑ コールバックに client が渡らないため、注入する側も grant_types を見た判定を書けない
```

### 生成コード側: 独自フラグで代替

```ts
// samples/hono-cloudflare/src/oidc-provider/config.ts:111-115
export type RegisteredClient = ClientInfo & TokenClientInfo & {
  offlineAccessAllowed?: boolean;
  // ...
};
```

```ts
// samples/hono-cloudflare/src/oidc-provider/routes/authorize.ts:401-405（同 475-479 にも再掲）
const clientConfig = await clientResolver.findClient(transaction.clientId);
const grantedScope = transaction.scope.split(' ').filter((s: string) => {
  if (s === 'offline_access' && !clientConfig?.offlineAccessAllowed) return false;
  return Boolean(s);
});
```

同じフィルタが `packages/cli/src/frameworks/hono/templates.ts` の 2114 / 2188 / 3994 行、
`web-standard/templates.ts` の 1562 行に埋め込まれ、
`nextjs-vercel` では `src/app/consent/actions.ts:60-68`（`_oidc-provider/` の外）にある。

### Refresh Token の発行判定: `grant_types` を見ていない

```ts
// samples/hono-cloudflare/src/oidc-provider/routes/token.ts:564
refresh_token: grantHasOfflineAccess ? generateRandomString(32) : undefined,
// ↑ grantHasOfflineAccess（認可時に offline_access が残ったか）のみで決まる
```

同ルート前段の `validateClientGrantType(tokenClient, grantType)` は、
**この時点で提示されている grant_type**（`authorization_code`）を検証するものであり、
「将来 refresh_token grant を使えるか」は見ていない。

## 修正方針

### 発行直前に登録との整合を検証する（安全網）

- [ ] 生成コードの token ルートで、Refresh Token を発行する条件に
      「クライアントの `grantTypes`（既定 `['authorization_code']`）が `refresh_token` を含む」を追加する
  ```ts
  // 例: RFC 7591 §2 — grant_types の既定は ["authorization_code"]。refresh_token grant を
  // 登録していないクライアントに Refresh Token を渡しても、そのトークンは
  // validateClientGrantType で unauthorized_client として拒否されるだけなので発行しない。
  const clientAllowsRefreshGrant =
    (tokenClient.grantTypes ?? ['authorization_code']).includes('refresh_token');

  refresh_token:
    grantHasOfflineAccess && clientAllowsRefreshGrant
      ? generateRandomString(32)
      : undefined,
  ```
- [ ] 発行しなかった場合、token response の `scope` から `offline_access` を落とすかを決める
      — **落とす方を推奨**。RFC 6749 §3.3 に従い「付与されなかった」ことをクライアントへ通知でき、
      「`offline_access` が付与された scope に居るのに `refresh_token` が無い」という
      矛盾したレスポンスを避けられる
- [ ] 既存の `offlineAccessAllowed` フィルタは**本タスクでは削除しない**
      （廃止するかは study-material の方針 A で別途判断する）
- [ ] `packages/cli` のテンプレートを修正し、全 sample を再生成する
- [ ] `packages/cli` 側の `conformance.test.ts` 生成コードを更新する
      （`samples/*/conformance.test.ts` を直接編集しないこと）

### 実装前に人間が確認すること

- [ ] `offline_access` を付与しなかったとき、`scope` から落とすか残すかを決める
      （上記は「落とす」を推奨案として提示。最終判断は人間）
- [ ] エラーにする選択肢（`invalid_scope` / `server_error` で認可自体を落とす）を取るかどうか。
      推奨は「静かに発行しない＋ scope から落とす」。認可フローを落とすと
      設定ミスの影響が大きくなりすぎるため

## テスト要件

TDD で先に Red を作る。テストケース名は「should + 動詞」形式。
テストケース内に `if` を書かず、`toMatchObject` で判別フィールドごと固定する。

各 sample の `conformance.test.ts`（生成元は `packages/cli`）:

- [ ] `should not issue a refresh token when the client does not register the refresh_token grant type`
      （`offlineAccessAllowed: true` かつ `grantTypes: ['authorization_code']` のクライアントで
      `scope=openid offline_access&prompt=consent` → token response に `refresh_token` が無い）
- [ ] `should omit offline_access from the granted scope when the refresh token is withheld`
      （上記と同じ条件で `scope` の具体値を `toBe` で固定する）
- [ ] `should issue a refresh token when the client registers the refresh_token grant type`
      （既存の example client 構成が回帰していないことの確認）
- [ ] `should still drop offline_access when prompt=consent is absent even if refresh_token is registered`
      （OIDC Core §11 の条件が独立に効き続けることを固定する）

`packages/cli/src/__tests__`:

- [ ] 生成された token ルートに `grantTypes` を参照する分岐が含まれることを固定する

アサーションは合格値を一意に固定する（`toContain` / `expect.any` / `stringContaining` は使わない）。

## 完了条件

- [x] 上記テストがすべてパスする
- [x] `grantTypes` に `refresh_token` を含まないクライアントへ Refresh Token が発行されない
- [x] 既存の example client（`grantTypes` に `refresh_token` を含む）の挙動が変わらない
- [x] `samples/*` は CLI 再生成の結果として更新されている（手編集していない）
- [x] 実行コマンド:
  ```bash
  pnpm --filter @maronn-openid-connect/cli test
  pnpm --filter @maronn-openid-connect/core test
  pnpm -r --filter './samples/*' test
  ```
- [x] `packages/cli` の出荷物が変わるため changeset を追加する
