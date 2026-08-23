# トークン発行時の有効期間の正当性検証（`expires_in` の正整数性 / `exp > iat` の内部整合）

## ステータス

🟠 High / 未着手

## 1. このトピックで確認したいこと

トークン発行時、アクセストークン・ID トークンの有効期間（`expires_in` / `exp`）が
「正の秒数」「`exp > iat`」であることを保証する検証が無い。設定ミス（`accessTokenExpiresIn = 0` や負値・小数）で、
`exp === iat`（実質即時失効）や非整数の `expires_in`、`exp < iat` のトークンがそのまま発行されうる。
`validatePayload`（ID Token / Access Token）は「`exp` が過去すぎない（clock skew 内）」ことは見るが、
「有効期間が正である」「`exp > iat` である」という内部整合は検証していない。

本ファイルは、発行時点で「即時失効トークン」や「負の有効期間」を弾くガードを、
アクセストークンレスポンスと ID トークン／アクセストークン payload の双方で検討する。

> 関連既存ファイル（重複回避）：
> - `study-material/done/token-expiry-boundary-and-opaque-lifetime-binding.md` /
>   `tasks/done/p3-token-expiry-boundary-consistency.md`:
>   **(1) 失効判定の境界演算子（`<` vs `<=`）の一貫性**、**(2) opaque トークンの `expires_in` と store `expiresAt` の
>   バインド（別々の `Date.now()` 由来のドリフト）**を扱う。本ファイルはそこで扱っていない
>   **(3) 有効期間そのものの正当性（正整数性・`exp > iat`）** に絞る。
> 本ファイル固有の論点は「**設定ミス由来のゼロ／負／小数の有効期間を発行時に検出する**」こと。

## 2. 関連する仕様・基準

- **RFC 6749 §5.1（`expires_in`）**:
  > `expires_in` RECOMMENDED. The lifetime in seconds of the access token. For example, the value "3600" ...
  - 「秒単位の有効期間」であり、ゼロ・負・小数は意味を成さない。ゼロ／負なら即時に失効したトークンを
    広告することになる。
- **RFC 9068 §2.2（JWT Access Token の `iat`/`exp`）**: `exp` は失効時刻、`iat` は発行時刻。
  整合的な（`exp > iat` の）値であることが前提。
- **RFC 7519 §4.1.4 / §4.1.6（`exp`/`iat` は NumericDate）**: 数値である必要がある。
  小数秒を許容する余地はあるが、`expires_in` は「秒」の整数表現が一般的で、非整数は相互運用性を損なう。
- **OpenID Connect Core 1.0 §2（ID Token `exp`）**: `exp` を過ぎた ID Token は RP に拒否される。
  発行時に `exp <= iat` になっていれば、正しく検証する RP には常に拒否される無効トークンとなる。

## 3. 参照資料

- RFC 6749 §5.1（Successful Response, `expires_in`）: https://www.rfc-editor.org/rfc/rfc6749#section-5.1
- RFC 9068 §2.2（Data Structure）: https://www.rfc-editor.org/rfc/rfc9068#section-2.2
- RFC 7519 §4.1.4 / §4.1.6（`exp` / `iat`）: https://www.rfc-editor.org/rfc/rfc7519#section-4.1.4
- OpenID Connect Core 1.0 §2（ID Token）: https://openid.net/specs/openid-connect-core-1_0.html#IDToken

## 4. 現在の実装確認

- `packages/core/src/token-response.ts`
  - `generateTokenResponse`（`:231-379` 付近）は `now = Math.floor(Date.now()/1000)` を基準に
    Access Token の `exp = now + accessTokenExpiresIn`、ID Token の `exp = now + idTokenExpiresIn` を計算。
  - レスポンスの `expires_in`（`:371` 付近）は `accessTokenExpiresIn` を**そのまま**出力。正整数性のガードなし。
  - `accessTokenExpiresIn = 0` なら `exp === iat`、負値なら `exp < iat`、小数なら非整数 `expires_in` が発行される。
- `packages/core/src/id-token.ts`
  - `validatePayload`（`:86-162` 付近）: `exp` が数値であること・過去すぎない（clock skew 内）ことは検証するが、
    `exp > iat` の内部整合は検証していない。
- `packages/core/src/access-token.ts`
  - `validatePayload`（JWT Access Token 用）も同様に `exp > iat` を検証していない
    （`exp < now - skew` のみ）。

## 5. 現在の実装との差分

- **満たしていること**
  - `exp` が過去すぎる（clock skew 超過）場合は弾く。数値型チェックはある。
- **不足している可能性があること**
  - `expires_in` / `accessTokenExpiresIn` / `idTokenExpiresIn` の**正整数性**を検証していない。
  - `exp > iat`（発行時の内部整合）を検証していない。
- **セキュリティ／相互運用性**
  - 直接の攻撃経路ではないが、設定ミスで「即時失効トークン」を配ると、RP／RS 側で全リクエストが失敗し、
    原因の特定が難しい運用障害になる。小数 `expires_in` は一部クライアント実装で解釈差を生む。
- **Basic OP として確認すべきこと**
  - `expires_in` は Basic OP のトークンレスポンスに含まれる基本フィールド。値の妥当性は Fidelity に直結。

## 6. 改善・追加を検討する理由

- **堅牢性 / 運用性**: OSS の実行利用者が設定値を触る前提のため、`accessTokenExpiresIn = 0` のような
  設定ミスを「発行時に明確なエラーで気付ける」ことは利用者体験に直結する（黙って壊れたトークンを配らない）。
- **Fidelity**: `exp > iat` は JWT の基本的な内部整合であり、発行側で保証すべき。
- **導入しやすさ**: `generateTokenResponse` の入口と `validatePayload` に数行のガードを足すだけ。
  既存の正常系（正の有効期間）には影響しない。
- **実装しない場合のリスク**: 設定ミスが本番でのみ顕在化し、全トークンが即時失効する障害を静かに引き起こす。

## 7. 実装方針の候補

判断材料の整理（最終判断は人間）。

- 方針A（推奨）: `generateTokenResponse` の入口で `accessTokenExpiresIn` / `idTokenExpiresIn` が
  **正の整数**であることを検証し、違反時は明確なエラーを throw。
  - 併せて `validatePayload`（id-token / access-token）に `exp > iat` チェックを追加し、
    どの発行経路でも即時失効トークンを弾く二重の防御にする。
- 方針B: `validatePayload` 側の `exp > iat` チェックのみ追加（`generateTokenResponse` の入口検証は入れない）。
  - 最小だが、`expires_in` の非整数／負値をレスポンスに載せる経路は塞げない。
- 小数を許容するか（`Number.isInteger` を必須にするか）は判断が必要。相互運用性重視なら整数必須が無難。
  clock skew 検証（既存）とは独立した「発行時整合」チェックとして位置づける。

## 8. タスク案

- [ ] `token-response.test.ts` に先行テスト（Red）:
  - [ ] `accessTokenExpiresIn = 0` / 負値 / 小数で `generateTokenResponse` がエラーになる
  - [ ] 正の整数では従来どおり成功し、`expires_in` が一致する
- [ ] `id-token.test.ts` / `access-token.test.ts` に「`exp <= iat` の payload を `validatePayload` が拒否する」テストを追加
- [ ] `generateTokenResponse` 入口に正整数ガードを追加、`validatePayload` に `exp > iat` チェックを追加（Green）
- [ ] 既存の正常系テストが引き続き通ることを確認
- [ ] 完了条件: `pnpm --filter @maronn-openid-connect/core test` がパス
