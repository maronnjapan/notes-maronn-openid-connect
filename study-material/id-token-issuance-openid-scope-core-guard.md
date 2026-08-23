# ID Token 発行の `openid` スコープ不変条件を core API に強制する

## ステータス

🟡 Medium / 未着手

## 1. タイトル

`generateTokenResponse`（core）が ID Token を発行するか否かを呼び出し側の `issueIdToken` フラグだけで決めており、「ID Token は `openid` スコープがある時のみ発行する」という OIDC Core §3.1.3.3 / §12 の不変条件を **core 自身が保証していない**点を確認し、core API レベルでの強制を検討する。

> 注: refresh 時の scope 縮小／保持、`offline_access`、refresh ID Token の nonce 省略などは既存ファイル群（`refresh-token-grant-scope-preservation.md` 他）が扱う。本ファイルは「`openid ∈ scope` を core が ID Token 発行のガードにしていない」という直交する論点のみを扱う。

## 2. このトピックで確認したいこと

- OIDC では ID Token は `openid` スコープを含む認可に対してのみ発行される。`openid` を含まない（純 OAuth 2.0 の）トークンリクエストでは ID Token を返してはならない
- 現状 core の `generateTokenResponse` は `issueIdToken` フラグのみで ID Token を発行し、`scope` に `openid` が含まれるかを独立に検査していない
- 生成 OP（CLI テンプレート）は `issueIdToken: validatedRequest.scope.includes('openid')` と正しく計算して渡しているため**生成 OP は正しい**。しかし `packages/core` を**直接ライブラリとして使う高度ユースケース**（CLAUDE.md が core の役割として明記）では、`issueIdToken: true` を `openid` 無しスコープで渡すと仕様違反の ID Token が出てしまう。この core 契約の隙間を確認する
- 特に refresh 時に scope を縮小して `openid` を落としたケースで、呼び出し側が誤って `issueIdToken: true` を渡す事故の余地を確認する

## 3. 関連する仕様・基準

- **OpenID Connect Core 1.0 §3.1.3.3（Successful Token Response）**: Token Endpoint のレスポンスに `id_token` を含めるのは OpenID Connect 認証（= `openid` スコープを含む認可）の場合。OAuth 2.0 のみのリクエストでは ID Token を返さない。
- **OpenID Connect Core 1.0 §3.1.2.1 / §5.4**: `openid` スコープは OpenID Connect リクエストであることの必須シグナル。`scope` に `openid` が無ければ OIDC ではなく素の OAuth 2.0 であり、ID Token は発行対象外。
- **OpenID Connect Core 1.0 §12（Using Refresh Tokens）/ §12.2**: refresh で ID Token を返す場合の要件（`iss`/`sub`/`aud`/`iat`/`auth_time`/`azp` 等の整合）。前提として「ID Token を返すのは OIDC リクエスト（`openid` あり）の時」。
- **UserInfo §5.3.1 との一貫性**: UserInfo 側は `tokenInfo.scope.includes('openid')` を明示チェックして `openid` 無しを拒否している（`userinfo.ts` 行 369）。ID Token 発行側にも同じ不変条件を core で持たせると一貫する。

## 4. 参照資料

- OpenID Connect Core 1.0 §3.1.3.3 — https://openid.net/specs/openid-connect-core-1_0.html#TokenResponse
- OpenID Connect Core 1.0 §5.4 Requesting Claims using Scope Values — https://openid.net/specs/openid-connect-core-1_0.html#ScopeClaims
- OpenID Connect Core 1.0 §12 Using Refresh Tokens — https://openid.net/specs/openid-connect-core-1_0.html#RefreshTokens
- 関連既存ファイル: `study-material/refresh-token-grant-scope-preservation.md`、`study-material/done/refresh-id-token-nonce-omission.md`、`study-material/resolver-and-store-contract.md`

## 5. 現在の実装確認

- `packages/core/src/token-response.ts` `generateTokenResponse`:
  - 行 306: `if (issueIdToken) { ... idToken = await generateIdToken(...) }` — ID Token 発行は `issueIdToken` フラグのみで分岐。`scope`（同関数の引数）に `openid` が含まれるかの独立検査は無い。
  - `scope` は同関数内でアクセストークンの `scope` クレームやクレームフィルタに使われている（行 293, 317）が、ID Token 発行可否の判定には使われていない。
- 生成 OP（正しい配線）: `packages/cli/src/frameworks/hono/templates.ts`（Token ハンドラ、概ね行 1530 付近）で `issueIdToken: validatedRequest.scope.includes('openid')` を計算して渡している。→ 生成 OP は仕様準拠。
- UserInfo 側の対称な実装: `packages/core/src/userinfo.ts` 行 369 で `if (!tokenInfo.scope.includes('openid')) throw ...`。発行側にはこの対称チェックが無い。

## 6. 現在の実装との差分

満たしていること:

- 生成 OP（CLI テンプレート）は `openid` 有無で `issueIdToken` を正しく計算 → 既定の OP 挙動は仕様準拠。
- refresh 時の scope 縮小・保持ロジック自体は別ファイルで担保済み。

不足している可能性があること:

- 🟡 **core API 契約の隙間**: `generateTokenResponse` は「`issueIdToken=true` かつ `scope` に `openid` 無し」でも ID Token を発行する。core を直接使う利用者（CLAUDE.md が想定する「高度な組み込みユースケース」）がこの組み合わせを渡すと仕様違反 ID Token が出る。
- 🟡 **不変条件の所在が一箇所に集約されていない**: 「ID Token ⇔ openid スコープ」という重要不変条件が core ではなくテンプレート側にだけ存在。テンプレートを改変した利用者や core 直接利用者では失われる。
- 🟢 **UserInfo との非対称**: 受信側（UserInfo）は `openid` を強制するのに、発行側（ID Token）は強制しない。ライブラリ内で対称にしておくと予測可能性が上がる。

セキュリティ／相互運用性:

- 🟢 直接の重大脆弱性ではないが、`openid` 無しで ID Token を出すと RP 側の前提（「ID Token があるなら OIDC フローだった」）を崩し、混乱・誤実装を招く。

Basic OP 認定との関係:

- 生成 OP は正しいため認定ブロッカーではない。本論点は **core ライブラリの堅牢性 / 不変条件の一元化**という Fidelity・保守性の軸。

## 7. 改善・追加を検討する理由

- **core はライブラリの正本**: CLAUDE.md は `core` を「高度な組み込みユースケース向けのロジック層」と位置づける。重要な仕様不変条件はテンプレートではなく core に置くのが筋。
- **不変条件の一元化 = 回帰耐性**: 「ID Token ⇔ openid」を core が保証すれば、テンプレート改変や core 直接利用でも崩れない。
- **UserInfo との対称性**: 受信・発行の両側で `openid` 不変条件を持つと API が一貫し、学習コストが下がる。
- 導入容易性: 🟢 小。`generateTokenResponse` 冒頭で「`issueIdToken && !scope.includes('openid')`」を検出し、(a) ID Token を発行しない、または (b) 明示エラーにする分岐を足すだけ。
- 実装しない場合のリスク: core 直接利用者が `openid` 無し ID Token を発行でき、仕様違反・RP 混乱の余地が残る。テンプレート改変でも同様。

## 8. 実装方針の候補

### 方針A（`openid` 無しなら ID Token を発行しない, 寛容側）

- `generateTokenResponse` で `const shouldIssueIdToken = issueIdToken && scope.includes('openid');` とし、`shouldIssueIdToken` で分岐。
- 利点: 呼び出し側が誤って `issueIdToken: true` を渡しても、`openid` 無しなら自動的に ID Token を出さない（安全側に倒れる）。欠点: 「フラグを true にしたのに出ない」挙動が利用者に分かりにくい場合があるためコメント／ドキュメントで明記。

### 方針B（`issueIdToken=true` かつ `openid` 無しを明示エラー）

- 矛盾入力として `Error`（プログラミングエラー）を投げる。
- 利点: 利用者の誤用を即座に検出。欠点: 既存呼び出し側が万一この組み合わせを使っていると破壊的。生成 OP は `scope.includes('openid')` を渡すので影響無いはず（要確認）。

### 方針C（`issueIdToken` を撤廃し core が `scope` から自動判定）

- フラグを廃し、core が `scope.includes('openid')` で内部的に判定。
- 利点: 不変条件が完全に core に集約され、誤用不能。欠点: API 変更（破壊的）。既存呼び出し側・テンプレートの修正が必要。`issueIdToken` を別目的（例: refresh で ID Token を返さない選択）に使っているケースがあれば両立できない → 要調査。

判断材料:

- まず `issueIdToken` フラグが「openid 判定」以外の意図（例: client_credentials 風の利用、refresh で ID Token を返さないオプション）で使われていないかを grep で確認する必要がある。
- 純粋に openid 判定の代理なら方針 C（撤廃・自動判定）が最もクリーンだが破壊的。非破壊で堅牢化するなら方針 A。

## 9. タスク案

- [ ] `issueIdToken` の全呼び出し箇所を grep し、「openid 判定の代理」以外の用途が無いか確認
- [ ] 方針（A/B/C）を決定（人間が判断）
- [ ] （TDD）`token-response.test.ts` に以下を先に追加:
  - `issueIdToken: true` + `scope` に `openid` 無し → ID Token を発行しない（方針 A）／ エラー（方針 B）
  - `issueIdToken: true` + `scope` に `openid` あり → 従来どおり ID Token 発行（回帰固定）
  - refresh で scope を縮小し `openid` を落としたケースで ID Token が出ないこと
- [ ] `generateTokenResponse` に `openid` ガードを実装
- [ ] UserInfo 側（行 369）と発行側の対称性をコメントで明記
- [ ] `samples/*/conformance.test.ts`（生成元 `packages/cli`）に「openid 無しトークンリクエストでは id_token を返さない」契約テストがあるか確認し、無ければ追加
