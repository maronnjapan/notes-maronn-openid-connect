# [P2] `RevocationTokenResolvers` に契約 JSDoc を付け、失効の物理削除セマンティクスを契約テストで固定する

## ステータス

🟠 High / 未着手

## 背景

`revokeRefreshToken(token: string): Promise<void>` という**同じ名前・同じシグネチャ**のメソッドが、
core の 2 つの別インターフェースに存在し、**要求される実装が正反対**である。

| インターフェース | 定義 | 要求される実装 | 生成 OP の配線 |
|---|---|---|---|
| `RefreshTokenResolver.revokeRefreshToken` | `packages/core/src/token-request.ts` | **物理削除禁止。`used=true` へ状態遷移** | `refreshTokenStore.consume(token)` |
| `RevocationTokenResolvers.revokeRefreshToken` | `packages/core/src/revocation.ts` | 物理削除でよい（RFC 7009 の明示失効） | `refreshTokenStore.revoke(token)` |

TypeScript の構造的型付けでは両者は完全に交換可能で、**片方の実装をもう片方に流用しても型エラーにならない**。
そのうえ、

- 前者には約 20 行の強い契約 JSDoc（「物理削除ではなく used=true への状態遷移として実装しなければならない」）がある
- **後者には JSDoc が一切無い**（`revokeRefreshToken?(token: string): Promise<void>;` の 1 行のみ）

本リポジトリの利用者は「生成コードを改造しながら仕様を検証する」ことが前提であり、
その入口が `resolvers.ts` である。そこに同名メソッドが 2 つ並び、片方にだけ強い契約が書かれている状態は、
**「重複しているから 1 つにまとめよう」という自然なリファクタリングが静かに仕様違反を作る**構造になっている。

誤用時の帰結:

| 誤用 | 帰結 | 重大度 |
|---|---|---|
| ローテーション側を物理削除にする | ローテーション済み RT の再提示が `not found` になり `revokeTokensByGrantId` が発火しない。**漏洩 RT から派生したトークンファミリーが生存**（OAuth 2.1 §4.3.1 / RFC 9700 §4.14 の SHOULD 違反） | 🔴 高 |
| 明示失効側を mark-used にする | 失効済み RT が `used:true` で残り、回収時期が TTL 依存になる。直接の情報漏洩は無いがライフサイクルが不透明化 | 🟡 中 |

前者は**壊れても既存テストが通ってしまう**タイプの劣化である点が特に問題。
現在、ローテーション側（`consume` であること）は再利用カスケードの回帰テストで実質的に固定されているが、
**Revocation 側（物理削除であること）を固定するテストは存在しない**。つまり守りが片側だけになっている。

検討の詳細は `study-material/done/resolver-revoke-refresh-token-name-collision.md` を参照。

> **本タスクのスコープ**: 非破壊で確実に効果がある「契約 JSDoc の対称化（方針A）」と
> 「契約テストによる両側固定（方針D）」に限定する。
> メソッド改名による根本解決（方針B: `revokeRefreshToken` → `markRefreshTokenUsed` 等）は
> **破壊的変更**であり、`study-material/RELEASE-v0.x-scope.md` との整合判断が必要なため、
> 本タスクには含めず study-material 側の未決事項として残す。

## 対象ファイル

- `packages/core/src/revocation.ts`（`RevocationTokenResolvers` の型定義）
- `packages/core/src/token-request.ts`（`RefreshTokenResolver.revokeRefreshToken` の JSDoc に相互参照を追記）
- `packages/cli` 内の `conformance.test.ts` 生成コード（契約テストの追加元。**生成物を直接編集しない**）
- `samples/*/src/oidc-provider/conformance.test.ts`（4 本。`packages/cli` 修正後に再生成して同期）
- `study-material/resolver-and-store-contract.md`（resolver 契約表への行追記）

## 仕様参照

- **OAuth 2.1 draft §4.3.1 Refresh Token**: ローテーションする AS は、無効化済みの Refresh Token が
  提示された場合それを侵害の兆候として扱い、当該 authorization grant に基づいて発行されたすべての
  Refresh Token を失効させる SHOULD。→ **再提示を検知するには、ローテーション済み RT が
  ストアに残っていなければならない**。
  https://datatracker.ietf.org/doc/draft-ietf-oauth-v2-1/
- **RFC 9700 §4.14 Refresh Token Protection**: 同上。AS は再提示された RT が攻撃者由来か
  正当クライアント由来か識別できないため、active な RT を失効させる。
  https://www.rfc-editor.org/rfc/rfc9700.html
- **RFC 7009 §2.1 Revocation Request**: クライアントが明示的に失効を要求する。AS は当該トークンを
  無効化し、同じ authorization grant で発行されたトークンも失効させる SHOULD。
  https://www.rfc-editor.org/rfc/rfc7009#section-2.1
- **RFC 7009 §2.2 Revocation Response**: 失効済み・存在しないトークンに対しても 200 OK を返す。
  → **この経路では「消えている」ことがそのまま正しい応答につながるため、物理削除が意味論的に正しい**。
  https://www.rfc-editor.org/rfc/rfc7009#section-2.2

つまり同じ「RT を失効する」でも、ローテーション経路は「**痕跡を残して再提示を検知する**」ため、
明示失効経路は「**単に無効化する**」ためであり、目的が違うので実装も逆になる。

## 現状の実装

`packages/core/src/revocation.ts` — JSDoc が無い:

```ts
export interface RevocationTokenResolvers {
  findAccessToken(token: string): Promise<AccessTokenInfo | null>;
  revokeAccessToken(token: string): Promise<void>;
  findRefreshToken?(token: string): Promise<RefreshTokenInfo | null>;
  revokeRefreshToken?(token: string): Promise<void>;   // ← 契約の説明なし
  /**
   * RFC 7009 Section 2.1 SHOULD: refresh token 失効時に
   * 同 grantId のアクセストークンも全て失効する。
   */
  revokeAccessTokensByGrantId?(grantId: string): Promise<void>;
}
```

`samples/hono-cloudflare/src/oidc-provider/resolvers.ts` — 配線自体は正しい:

```ts
// L77: RefreshTokenResolver 側 → mark-used（正しい）
async revokeRefreshToken(token) { await refreshTokenStore.consume(token); },

// L114: RevocationTokenResolvers 側 → 物理削除（RFC 7009 として正しい）
async revokeRefreshToken(token) { await refreshTokenStore.revoke(token); },
```

問題は「正しさが型でもテストでも守られていない」点にある。

## 修正方針

### A. 契約 JSDoc の対称化（`packages/core/src/revocation.ts`）

- [ ] `RevocationTokenResolvers.revokeRefreshToken` に JSDoc を追加する。含める内容:
  - RFC 7009 §2.1 / §2.2 に基づく明示失効であること
  - **物理削除で正しい**こと
  - `RefreshTokenResolver.revokeRefreshToken`（`token-request.ts`）とは**契約が逆**であり、
    実装を共有してはならないこと
- [ ] `RevocationTokenResolvers.revokeAccessToken` にも同様に、物理削除でよい旨の JSDoc を追加する
- [ ] `packages/core/src/token-request.ts` の `RefreshTokenResolver.revokeRefreshToken` の JSDoc 末尾に、
      「同名の `RevocationTokenResolvers.revokeRefreshToken`（`revocation.ts`）とは契約が逆である。
      実装を流用しないこと」という相互参照を追記する

実装イメージ:

```ts
// packages/core/src/revocation.ts
export interface RevocationTokenResolvers {
  // ...
  /**
   * RFC 7009 §2.1: クライアントが明示的に指定した Refresh Token を失効させる。
   *
   * **こちらは物理削除でよい。** RFC 7009 §2.2 は失効済み・存在しないトークンに対しても
   * 200 OK を返すと規定しており、「レコードが存在しない」ことがそのまま正しい応答につながる。
   *
   * ⚠️ 同名の {@link RefreshTokenResolver.revokeRefreshToken}（`token-request.ts`）とは
   * **契約が正反対**である。あちらはローテーション経路であり、再提示を検知するために
   * 物理削除ではなく `used=true` への状態遷移で実装しなければならない。
   * 型は構造的に同一なので相互代入しても型エラーにならないが、**実装を共有してはならない**。
   * 誤ってあちらを物理削除にすると、漏洩 Refresh Token から派生したトークンファミリーが
   * 失効されず生き残る（OAuth 2.1 §4.3.1 / RFC 9700 §4.14 の SHOULD 違反）。
   */
  revokeRefreshToken?(token: string): Promise<void>;
}
```

### B. 契約テストによる両側固定（`packages/cli` の `conformance.test.ts` 生成コード）

- [ ] 「RFC 7009 の Revocation で失効させた Refresh Token は、その後 refresh_token grant で提示しても
      `invalid_grant` になり、かつストアから取得できない（物理削除されている）」ことを固定するテストを追加する
- [ ] 既存のローテーション再利用カスケードテスト（`used=true` として残ることを固定）と対になる形にし、
      テスト名で「どちらの経路の契約か」が読み取れるようにする
- [ ] `packages/cli` を修正したうえで `samples/*` 4 本を再生成して同期する（生成物は直接編集しない）

### C. 契約ドキュメントへの反映

- [ ] `study-material/resolver-and-store-contract.md` の resolver 契約表に
      「`RevocationTokenResolvers.revokeRefreshToken` = 物理削除（`RefreshTokenResolver` 側と逆契約）」の行を追記し、
      `study-material/done/resolver-revoke-refresh-token-name-collision.md` へ参照を張る

### D. 本タスクに含めない（未決事項として study-material に残す）

- メソッド改名（`revokeRefreshToken` → `markRefreshTokenUsed`、`revokeAuthorizationCode` →
  `markAuthorizationCodeUsed`）による根本解決。**破壊的変更**のため、実施可否と
  非推奨エイリアス期間の要否を `study-material/RELEASE-v0.x-scope.md` と突き合わせて別途判断する。

## テスト要件

テストケース名は「should + 動詞」形式、アサーションは一意値で固定すること（CLAUDE.md のテスト規約）。

- [ ] （conformance）`should reject a refresh token that was revoked via the revocation endpoint`
      — Revocation で失効させた RT を refresh_token grant に提示すると `invalid_grant` になる
- [ ] （conformance）`should physically remove a refresh token revoked via the revocation endpoint`
      — 失効後に store から当該 RT が取得できない（`undefined` / `null` で一意固定）
- [ ] （conformance・回帰固定）`should keep a rotated refresh token findable as used for reuse detection`
      — ローテーション済み RT は `used: true` として取得可能なまま残る（既存テストがあれば流用・命名整理のみ）
- [ ] （conformance・回帰）`should revoke sibling access tokens when a refresh token is revoked`
      — RFC 7009 §2.1 SHOULD の access token cascade が壊れていない
- [ ] （core）既存の `revocation.test.ts` / `revocation-steps.test.ts` が回帰しない
- [ ] （core）既存の refresh ローテーション再利用カスケードのテストが回帰しない

## 完了条件

- `pnpm --filter @maronn-openid-connect/core test` がパスすること
- `pnpm --filter @maronn-openid-connect/cli test` がパスすること
- `pnpm test` 全体がパスすること
- `samples/*/src/oidc-provider/conformance.test.ts` 4 本が `packages/cli` の再生成結果と一致し、
  すべてパスすること
- `packages/core/src/revocation.ts` を読んだ利用者が、
  「こちらは物理削除でよい」「もう一方とは契約が逆」を JSDoc だけで判断できる状態になっていること
- 誤って `RefreshTokenResolver.revokeRefreshToken` を物理削除実装にした場合、
  既存の再利用カスケード契約テストが失敗すること（＝守りが機能していることの確認）
