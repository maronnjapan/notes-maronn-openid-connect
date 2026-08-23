# Revocation Endpoint が Refresh Token ファミリー（同一 grantId の他 RT）を失効しない

## 1. このトピックで確認したいこと

RFC 7009 の Revocation Endpoint で Refresh Token を失効すると、`tryRevokeRefresh` はその 1 レコードを失効し、同 `grantId` の**アクセストークン**へは cascade する（`revokeAccessTokensByGrantId`）。しかし同 `grantId` を共有する**他の Refresh Token**を失効する機構が無い（resolver に `revokeRefreshTokensByGrantId` が存在しない）。通常のローテーションでは生存 RT は 1 本のみのため実害は小さいが、grace-window / 冪等ローテーション（`study-material/refresh-token-rotation-replay-grace.md`）で前身 RT と後継 RT が一時的に併存する設計を入れた場合、「片方の RT を revoke してもファミリーのもう片方が使える」穴が残る。この境界を確認・文書化したい。

## 2. 関連する仕様・基準

共通の Revocation（RFC 7009）の基本挙動・クライアント認証・content-type・所有チェックは以下を参照し繰り返さない。

- `study-material/done/public-client-token-revocation-rfc7009.md`（public client の revocation）
- `study-material/done/introspection-revocation-content-type-enforcement.md`（content-type 強制）
- `study-material/done/consent-withdrawal-grant-token-revocation.md`（同意撤回起点の失効）

本ファイル固有の差分:

- **RFC 7009 §2.1**: リフレッシュトークン失効時、AS は SHOULD で「そのトークンに基づいて発行された**アクセストークン**」を失効する。**他の Refresh Token** の失効までは RFC 7009 は明示要求しない。したがって現状は RFC 7009 の MUST/SHOULD には違反しない。
- **OAuth 2.1 §4.3.1 / RFC 9700 §4.14**: ローテーションでは token family（同一認可付与）という概念を扱う。再利用検知時は family 全体を失効するのが望ましいとされる。Revocation Endpoint 起点で family 内の他 RT を巻き込むかは、rotation の設計（特に grace-window の有無）に依存する。

## 3. 参照資料

- RFC 7009 (OAuth 2.0 Token Revocation) §2.1 — https://datatracker.ietf.org/doc/html/rfc7009#section-2.1
- OAuth 2.1 draft §4.3.1 Refresh Token（rotation / family）— https://datatracker.ietf.org/doc/draft-ietf-oauth-v2-1/
- RFC 9700 (OAuth 2.0 Security BCP) §4.14 Refresh Token Protection — https://datatracker.ietf.org/doc/html/rfc9700
- 本リポジトリ内: `packages/core/src/revocation.ts:62-67`（resolver に access 用 cascade のみ）、`:108-112`（refresh 失効時の access cascade）

## 4. 現在の実装確認

`packages/core/src/revocation.ts`:

```ts
export interface RevocationTokenResolvers {
  findAccessToken(token): Promise<AccessTokenInfo | null>;
  revokeAccessToken(token): Promise<void>;
  findRefreshToken?(token): Promise<RefreshTokenInfo | null>;
  revokeRefreshToken?(token): Promise<void>;
  // RFC 7009 §2.1 SHOULD: refresh 失効時に同 grantId の access を全失効
  revokeAccessTokensByGrantId?(grantId): Promise<void>;   // L62-66
  // ← 同 grantId の「他の refresh token」を失効するメソッドは無い
}

async function tryRevokeRefresh(ctx, token) {
  ...
  await revoke(token);                                    // 対象 RT 1 本のみ失効
  if (ctx.resolvers.revokeAccessTokensByGrantId) {
    await ctx.resolvers.revokeAccessTokensByGrantId(info.grantId);  // L108-111: access のみ cascade
  }
  return true;
}
```

- 失効対象は「指定された RT 1 本」＋「同 grantId の access token 群」。同 grantId の**他 RT** は残る。
- 現状のローテーション実装（`routes/token.ts`）は「新 RT 保存 → 旧 RT を used 化」で、任意時点の生存（used=false）RT は基本 1 本。よって通常運用では穴が顕在化しない。

## 5. 現在の実装との差分

満たしていること:
- RFC 7009 §2.1 の SHOULD（refresh 失効時に access を失効）は実装済み。
- 所有クライアント検証・not-found でも 200 等、RFC 7009 の基本挙動は既存トピックで担保済み。

改善した方がよいこと（条件付き）:
- 🟢 **同 grantId の他 Refresh Token を失効する経路が無い**。通常は生存 RT が 1 本のため無害。ただし以下の設計を導入した場合に境界が問題化する:
  - grace-window / 冪等ローテーション（`refresh-token-rotation-replay-grace.md`）で前身 RT と後継 RT を一時併存させる場合、片方を revoke してももう片方が使え、「revoke したのに family が生きている」直感に反する挙動になる。
- 現状の契約（「RT を 1 本 revoke してもローテーションファミリー全体は死なない」）が**未文書・未テスト**。

Basic OP として確認すべきこと:
- Revocation Endpoint 自体が Basic OP 認定の必須要件ではない（OAuth 2.0 拡張）。したがって**認定可否には影響しない**。純粋にセキュリティ/相互運用のハードニング。

## 6. 改善・追加を検討する理由

- **なぜ検討するか**: grace-window を将来入れる前提に立つと、「revoke = ファミリー全体を止める」という利用者の期待とのギャップが顕在化する。先に境界を文書化しておくと、grace-window 実装時の設計事故を防げる。
- **Basic OP 必須か拡張か**: 拡張（ハードニング）。RFC 7009 の MUST/SHOULD には現状でも準拠。
- **導入しやすさ / しにくさ**: `revokeAccessTokensByGrantId` と対になる `revokeRefreshTokensByGrantId?` を resolver に足し、`tryRevokeRefresh` で呼ぶだけなら局所的。ただし resolver 契約の変更は sample の `store.ts` / `resolvers.ts` と、`conformance.test.ts` の生成元（`packages/cli`）の更新を伴う（`study-material/resolver-and-store-contract.md`）。
- **grace-window との依存**: この改善の実効価値は grace-window（未決トピック）を入れるかどうかに強く依存する。grace-window を入れないなら、生存 RT は常に 1 本で、本改善は「保険」に留まる。
- **実装しない場合のリスク**: 現状運用では小。grace-window 導入時に、family 内の残存 RT を見落とすと revoke の実効性が下がる。

## 7. 実装方針の候補（判断材料）

最終判断は人間が行う。grace-window の採否と併せて判断すべき。

- 方針A（現状維持 + 契約明文化・推奨）: 「Revocation は指定 RT 1 本 + 同 grantId の access を失効する。生存 RT は通常 1 本のため family 全体失効は不要」という契約を `revocation.ts` コメントと本系統の study-material に明記し、テストで固定。grace-window を入れる際に再検討する前提を残す。
- 方針B（`revokeRefreshTokensByGrantId` を追加）: resolver に同 grantId の全 RT 失効メソッドを追加し、`tryRevokeRefresh` で access cascade と併せて呼ぶ。RFC 7009 の SHOULD を超える強い失効。sample の store / cli テンプレート / `conformance.test.ts` 更新が必要。
- 方針C（grace-window 実装時に同梱）: 単独では入れず、`refresh-token-rotation-replay-grace.md` の方針決定時に「family 併存を導入するなら revocation も family cascade する」とセットで設計する。

## 8. タスク案（タスク化は保留）

grace-window（前提トピック）が未決のため、本改善単独ではタスク化しない。前提決定に紐づける。

- [ ] `refresh-token-rotation-replay-grace.md` の方針（grace-window / 冪等ローテーションを入れるか）の決定を待つ
- [ ] grace-window を入れる場合: 本トピックを方針 B としてタスク化し、`revokeRefreshTokensByGrantId` の resolver 追加 + `tryRevokeRefresh` での呼び出し + sample/store/cli/`conformance.test.ts` 更新を含める
- [ ] grace-window を入れない場合: 方針 A として「family 全体失効は不要」の契約を明文化し、`revocation.test.ts` に「同 grantId の他 RT が（通常存在しないこと前提で）どう扱われるか」を固定するテストを追加する

## 関連トピック

- `study-material/refresh-token-rotation-replay-grace.md` — grace-window / 冪等ローテーション。本ファイルの価値はこのトピックの採否に依存する（前提トピック）。
- `study-material/resolver-and-store-contract.md` — 方針 B が触れる resolver/store 契約の変更範囲。
- `study-material/done/consent-withdrawal-grant-token-revocation.md` — grant 単位失効の別入口（同意撤回）。grantId 単位の失効という点で関連。
