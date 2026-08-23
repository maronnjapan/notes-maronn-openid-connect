# `email_verified` / `phone_number_verified` の boolean 型保証（クレーム型の出力強制）

## ステータス

🟡 Medium / 未着手

## 1. タイトル

UserInfo / ID Token に出力する `email_verified` / `phone_number_verified` が、OIDC Core §5.1 が要求する **JSON boolean** として発行されることを保証する。現状は `UserClaimsResolver` が返した生値をそのまま透過しており、`"true"`（文字列）や `1`（数値）が混入し得る。

> 注: UserInfo のスコープフィルタ全般・署名付き応答・`aud` 検証などは `study-material/userinfo-endpoint-comprehensive.md` 等が扱う。本ファイルは「boolean 型クレームの型保証」という直交する差分のみを扱う。

## 2. このトピックで確認したいこと

- OIDC Core §5.1 で **boolean** と定義される `email_verified` / `phone_number_verified` が、OP の出力で確実に JSON boolean 型になっているか
- 現状 `filterClaimsByScope` / `claims` パラメータ追加ループ / `generateUserInfoJwt` が resolver の生値を `value !== undefined && value !== null` のガードだけで透過しており、型強制（boolean への coercion / 非 boolean の拒否）が無い差分を確認する
- ID Token 側（`generateTokenResponse` の `filterClaimsByScope` 経由）でも同じ透過が起きるかを確認する

## 3. 関連する仕様・基準

- **OpenID Connect Core 1.0 §5.1（Standard Claims）**:
  - `email_verified`: 「True if the End-User's e-mail address has been verified; otherwise false. ... The value of this Claim is **a boolean value**.」さらに「if this Claim is present, it MUST be a boolean.」相当の扱い。
  - `phone_number_verified`: 同様に boolean と定義。
  - 仕様は明示的に「文字列 `"true"` は boolean `true` とは異なる」ことを前提にしており、型の正確さ（JSON 型として boolean）が相互運用の要件。
- **RFC 7519 / JSON（RFC 8259）**: JWT クレームは JSON。`true`（boolean）と `"true"`（string）は別の JSON 値であり、RP の厳格なパーサは型違いを拒否し得る。
- **相互運用性**: 多くの RP / クライアントライブラリは `email_verified === true` のような厳密比較を行う。`"true"` が返ると常に false 扱いになり、「メール確認済みなのに未確認として扱われる」などの実害が出る。

## 4. 参照資料

- OpenID Connect Core 1.0 §5.1 Standard Claims — https://openid.net/specs/openid-connect-core-1_0.html#StandardClaims （`email_verified` / `phone_number_verified` は boolean）
- RFC 8259 The JavaScript Object Notation (JSON) Data Interchange Format §3 (Values) — https://www.rfc-editor.org/rfc/rfc8259#section-3
- 関連既存ファイル: `study-material/userinfo-endpoint-comprehensive.md`（スコープ→クレームマップ）、`study-material/done/jwt-input-parsing-strictness.md`（発行側のクレーム型検証という同系統の方針）

## 5. 現在の実装確認

- `packages/core/src/userinfo.ts`:
  - 型定義（`UserClaims`）では `email_verified?: boolean` / `phone_number_verified?: boolean`（TypeScript 型のみ。ランタイム保証ではない）。
  - `filterClaimsByScope`（行 214-234）: `const value = userClaims[claimName]; if (value !== undefined && value !== null) { result[claimName] = value; }` — 生値透過。boolean 検証なし。
  - `claims` パラメータ追加ループ（行 392-401）: 同様に生値を透過。
  - `generateUserInfoJwt`（行 461 付近）: レスポンスを JWT ペイロードへそのまま spread。型変換なし。
- `packages/core/src/token-response.ts`（ID Token 経路）:
  - 行 316-319: `if (userClaims) { const filtered = filterClaimsByScope(userClaims, scope); Object.assign(idTokenPayload, filtered); }` — 同じ `filterClaimsByScope` を通すため、ID Token でも boolean 型は保証されない。
- TypeScript の型はコンパイル時のみ。利用者の `UserClaimsResolver` は外部実装であり、JS ランタイムでは `email_verified: "true"` を返しても型エラーにならず透過される。

## 6. 現在の実装との差分

満たしていること:

- TypeScript 型レベルでは `boolean?` と宣言されており、TS で書かれた resolver は型チェックの恩恵を受ける。
- クレームのスコープ単位のフィルタリングは正しく機能。

不足している可能性があること:

- 🟡 **ランタイム型強制が無い**: resolver が `"true"` / `1` / `"1"` を返すと、そのまま UserInfo / ID Token に出力される。JS（非 TS）利用者や、DB から `0/1` を読むコードで容易に発生する典型ミス。
- 🟡 **発行側厳格化方針との非対称**: 本リポジトリは `done/jwt-input-parsing-strictness.md` で「発行側でもクレーム型を検証する」方針を採っている。`email_verified` / `phone_number_verified` の boolean 型はこの方針の射程に入るが未対応。
- 🟢 **エラーにするか coercion するかが未決**: `"true"` を `true` に丸めるか、不正型として拒否するか、ポリシー未定。

相互運用性:

- 🟡 厳格な RP は `"true"` を boolean として受理せず、メール／電話の確認状態を誤判定する。セキュリティ判断（確認済みメールのみ許可等）に直結し得る。

Basic OP 認定との関係:

- これらのクレームは Basic OP の必須クレームではない（email スコープ等はオプション）。本論点は **Fidelity / 相互運用性**の軸で、認定ブロッカーではない。

## 7. 改善・追加を検討する理由

- **相互運用性の実害**: boolean のはずが文字列で出ると、RP が「未確認」と誤判定し、確認済みメール前提の機能が壊れる。発見が難しいバグ。
- **secure-by-default / 利用者の使いやすさ**: 利用者が `0/1` や `"true"` を返しても OP が正しい型に整える（または明示エラーで気付かせる）と、PoC 利用者の事故が減る。
- **既存方針との整合**: 発行側クレーム型検証（`jwt-input-parsing-strictness`）と同じ思想で、対象クレームを boolean に拡張するだけ。
- 導入容易性: 🟢 小。`filterClaimsByScope` に「boolean 型クレームのリスト」を持たせ、coercion or 検証を入れる。
- 実装しない場合のリスク: 型不一致クレームが出荷され続け、相互運用トラブルと「確認状態の誤判定」リスクが残る。

## 8. 実装方針の候補

### 方針A（boolean へ coercion, 寛容側）

- `BOOLEAN_CLAIMS = ['email_verified', 'phone_number_verified']` を定義。
- 出力時、これらのクレームが boolean でなければ truthy 判定（`value === true || value === 'true' || value === 1`）で boolean に正規化。
- 利点: 利用者の軽微なミスを吸収し UserInfo/ID Token が常に正しい型。欠点: 暗黙変換が「OP が勝手に解釈した」挙動になる（`"false"` のような曖昧値の扱いに注意）。

### 方針B（非 boolean を拒否, 厳格側）

- これらのクレームが boolean 以外なら `UserInfoError`（server_error）/ ID Token 発行エラーにする。
- 利点: 仕様逸脱を明示的に検出、開発時に気付ける。欠点: 本番で resolver データ不整合があると応答が落ちる。
- `done/jwt-input-parsing-strictness.md` の「発行側厳格化」とは整合的。

### 方針C（型は触らず resolver 契約のドキュメント化のみ）

- core を変えず、resolver 契約として「boolean クレームは boolean を返すこと」を `resolver-and-store-contract.md` に明記。
- 最小だが強制力なし。方針 A/B との併用が望ましい。

判断材料:

- PoC ツールとしては「黙って直す（A）」より「明確に弾く（B）」方が学びになるが、本番に近づける利用者には A の方が親切。`RELEASE-v0.x-scope.md` の安全側・利用者フレンドリー方針と照らして人間が判断。
- coercion する場合、`"false"` / `0` / `""` のような falsy 値の扱いを明文化する必要がある。

## 9. タスク案

- [ ] 方針（A/B/C）を決定（人間が判断）
- [ ] （TDD）`userinfo.test.ts` / `token-response.test.ts` に以下を先に追加:
  - resolver が `email_verified: "true"` を返す → 出力が boolean `true`（方針 A）／ エラー（方針 B）
  - resolver が `phone_number_verified: 1` を返す → 同様
  - resolver が boolean `true`/`false` を返す → そのまま boolean で出力（回帰固定）
  - ID Token 経路（`generateTokenResponse`）でも同じ型保証が効くこと
- [ ] `userinfo.ts` に boolean クレームの coercion / 検証を実装し、ID Token 経路（共通の `filterClaimsByScope`）にも適用
- [ ] coercion を採る場合、falsy 値（`"false"` / `0` / `""`）の扱いをコメントで明記
- [ ] `study-material/resolver-and-store-contract.md` に boolean クレーム契約を追記
- [ ] `samples/*/conformance.test.ts`（生成元 `packages/cli`）へ型保証の契約テストを追加
