# UserInfo エンドポイントのアクセストークン失効境界が他エンドポイントと不一致（`<` vs `<=`）

## ステータス

🟢 Low / 未着手

## 1. このトピックで確認したいこと

同一 OP 内で「アクセストークンが今失効しているか」を判定する境界演算子が、エンドポイントごとに揃っているかを確認する。

具体的には次の 1 点に絞る。

- **UserInfo エンドポイントだけが `expiresAt < now`（`expiresAt === now` のときはまだ有効扱い）で判定している**一方、
  Token エンドポイント（authorization_code / refresh_token の両方）と Introspection エンドポイントは
  `expiresAt <= now`（`expiresAt === now` のときは失効扱い）で判定している。
  この境界不一致（ちょうど失効秒における 1 秒のズレ）を是正すべきかどうか、方針を整理する。

> 関連既存ファイル（重複回避のため、共通論点はそちらを参照）：
> - `study-material/done/token-expiry-boundary-and-opaque-lifetime-binding.md` /
>   `tasks/done/p3-token-expiry-boundary-consistency.md`
>   … これらは **`validateTokenRequest` 内部**の「authorization_code (`<=`) と refresh_token (`<`) の境界不一致」と、
>   Opaque アクセストークンの `expires_in` / store `expiresAt` バインディングを扱う。
>   本ファイルは **UserInfo エンドポイントという別レイヤの残存 outlier** のみを扱う。
> - `study-material/done/jwt-clock-skew-and-time-tolerance.md` … JWT 検証時の clock skew 許容差。
>   本ファイルは「失効境界そのもの（`<` か `<=` か）」であり、skew の許容幅とは直交する。
>
> **重要な補足（前提の更新）**: 上記 `token-expiry-boundary` 系ファイルが記述していた
> 「refresh_token が `<`」という状態は、現在の `token-request.ts` では既に `<=` に修正済み
> （`packages/core/src/token-request.ts:503` および `:602` で確認）。
> その結果、**残る唯一の outlier は UserInfo の `<`（`packages/core/src/userinfo.ts:361`）** になっており、
> これは既存ファイルのスコープ（`validateTokenRequest` 内部）に含まれていなかった差分である。

## 2. 関連する仕様・基準（このトピック固有の差分）

共通の失効判定・`exp` 慣例の仕様説明は
`study-material/done/token-expiry-boundary-and-opaque-lifetime-binding.md` の「2. 関連する仕様・基準」を参照。
ここでは本トピックに効く条文だけを引く。

- **RFC 7519 §4.1.4（`exp` Claim）**:
  > The `exp` (expiration time) claim identifies the expiration time on or after which the JWT MUST NOT be accepted for processing.
  「on or after（`exp` 以降）」で受理不可、すなわち `now >= exp`（= `exp <= now`）で失効。
  したがって `<=`（`expiresAt === now` を失効扱い）が `exp` 慣例に一致する。
  UserInfo の `<`（`expiresAt === now` を有効扱い）は、ちょうど失効秒のあいだトークンを 1 秒だけ余分に受理する。
- **OIDC Core 1.0 §5.3.1 / §5.3.3（UserInfo Request / Error Response）**:
  UserInfo は「有効な Access Token」を要求し、無効・失効時は `invalid_token`（401）を返す。
  「失効」の秒境界を Token / Introspection と揃えることは MUST ではないが、
  同一 OP 内で「同じトークンが UserInfo では有効・Introspection では失効」と判定が食い違うのは
  相互運用性・監査上のノイズであり、防御的でない。
- **RFC 6749 §5.1 / OAuth 2.1 §3.2.3（`expires_in`）**:
  クライアントに広告する `expires_in` は「有効期間（秒）」。広告した寿命と各エンドポイントの実失効時刻が
  秒単位で一致していることが望ましい。

なお、この不一致は「1 秒だけ UserInfo が甘い」方向であり、**セキュリティ的に致命的ではない**（トークンを早く失効させる方向ではなく、遅く失効させる方向）。ただし「同一 OP で判定がブレる」こと自体が正しさ・保守性の欠陥である。

## 3. 参照資料

- RFC 7519 §4.1.4（`exp` の on-or-after 判定）: https://www.rfc-editor.org/rfc/rfc7519#section-4.1.4
- OpenID Connect Core 1.0 §5.3（UserInfo Endpoint）: https://openid.net/specs/openid-connect-core-1_0.html#UserInfo
- RFC 6749 §5.1 / OAuth 2.1 §3.2.3（`expires_in`）: https://www.rfc-editor.org/rfc/rfc6749#section-5.1 ／ https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1
- RFC 7662 §2.2（Introspection の active 判定）: https://www.rfc-editor.org/rfc/rfc7662#section-2.2

## 4. 現在の実装確認

- `packages/core/src/userinfo.ts:360-366`

  ```ts
  // 有効期限チェック
  const now = Math.floor(Date.now() / 1000);
  if (tokenInfo.expiresAt < now) {
    throw new UserInfoError(
      UserInfoErrorCode.InvalidToken,
      'The access token expired'
    );
  }
  ```

  → `expiresAt === now` のとき条件が偽になり、**まだ有効**として処理を続行する。

- `packages/core/src/token-request.ts`
  - refresh_token grant: `:499-503`

    ```ts
    // RFC 7519 §4.1.4 convention: expiresAt <= now means expired (on-or-after).
    // ...
    if (refreshTokenInfo.expiresAt <= nowForRefresh) { ... }
    ```
  - authorization_code grant: `:602`

    ```ts
    if (authCode.expiresAt <= now) { ... }
    ```

- `packages/core/src/introspection.ts:94` / `:100`

  ```ts
  if (info.expiresAt <= now) return false; // active = false
  ```

→ Token（両 grant）と Introspection は `<=`、UserInfo だけ `<`。**UserInfo が唯一の outlier**。

## 5. 現在の実装との差分

- **満たしていること**
  - Token / Introspection の失効境界は `<=` で統一済み（RFC 7519 慣例に一致）。
  - UserInfo は失効トークンを（境界ちょうどの 1 秒を除き）正しく `invalid_token`（401）で弾く。
- **不足している可能性があること**
  - `expiresAt === now` の 1 秒だけ、UserInfo が他エンドポイントと異なる判定（有効）を返す。
- **セキュリティ上の観点**
  - 影響は軽微（トークンを早く失効させる方向ではない）。ただし「同一 OP 内で失効判定がブレる」ことは
    防御的設計として望ましくない。
- **相互運用性の観点**
  - 同じアクセストークンを、ちょうど失効秒に UserInfo と Introspection へ同時に投げると、
    UserInfo は 200（クレーム返却）、Introspection は `active:false` を返しうる。
    リソースサーバやモニタリングが「片方は有効・片方は失効」という矛盾を観測しうる。
- **Basic OP として提供する上で確認すべきこと**
  - Basic OP の Conformance は境界 1 秒を直接検査しないが、UserInfo の失効挙動は検査対象。
    境界を揃えておくことで、生成 OP の挙動が説明しやすく、テストでも固定しやすい。

## 6. 改善・追加を検討する理由

- **正しさ・保守性**: `exp` の on-or-after 慣例（RFC 7519）に全エンドポイントを合わせると、
  「失効の意味」が OP 全体で一意になる。将来のリファクタで判定がさらに分岐するのを防ぐ。
- **導入しやすさ**: `userinfo.ts` の 1 行（`<` → `<=`）を変更し、テストで境界を固定するだけ。
  core の他ロジック・生成コードへの波及はない（UserInfo route は core の判定に委譲しているため）。
- **Basic OP / 拡張の別**: これは Basic OP の必須要件ではなく、**内部整合性の改善**。
  ただし OSS 利用者が生成コードを読んだときに「失効境界が揃っている」ことは信頼性のシグナルになる。
- **実装しない場合のリスク**: 残存 outlier がテストで固定されないまま残り、
  既存の `token-expiry-boundary` タスクを「解決済み」と誤認する（実際は UserInfo が未修正）。

## 7. 実装方針の候補

判断材料の整理（最終判断は人間）。

- 方針A（`<=` に統一・推奨）: `userinfo.ts:361` を `tokenInfo.expiresAt <= now` に変更。
  RFC 7519 慣例・他エンドポイントと一致。最小変更。
- 方針B（現状維持＋テスト固定）: UserInfo は `<` のままとし、「境界ちょうどの秒は UserInfo だけ有効」を
  意図的挙動としてテストで固定する。ただし他エンドポイントとの不一致が残るため非推奨。
- 方針C（skew 込みで再設計）: 失効判定に共通の許容差（clock skew）を導入して全エンドポイントで共有する。
  ただし `study-material/done/jwt-clock-skew-and-time-tolerance.md` の別論点に踏み込むため、本トピックの範囲外。
- どの方針でも「失効境界の演算子を OP 全体で一意にする」ことを第一目標にする。

## 8. タスク案

- [ ] 方針を決定（`<=` 統一 / 現状維持＋固定）
- [ ] `packages/core/src/userinfo.test.ts` に先行テスト（Red）:
  - [ ] `expiresAt === now`（ちょうど失効秒）で UserInfo が `invalid_token`（401）を返すこと（方針A採用時）
  - [ ] `expiresAt = now - 1`（明確に失効）で 401、`expiresAt = now + 1`（明確に有効）で 200 を返すこと（回帰固定）
- [ ] `packages/core/src/userinfo.ts:361` を方針に応じて修正
- [ ] Token / Introspection の既存境界テストと突き合わせ、`<=` の意味が OP 全体で一致していることを確認
- [ ] 生成 OP の挙動は変わらない想定（UserInfo route は core に委譲）だが、
      念のため各 sample の `conformance.test.ts` で UserInfo 失効ケースが固定されているか確認し、
      必要なら `packages/cli` のテンプレート生成側テストを更新
- [ ] 完了条件: `pnpm --filter @maronn-openid-connect/core test` がパス
