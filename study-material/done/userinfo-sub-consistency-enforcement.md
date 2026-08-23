# UserInfo レスポンスの `sub` と アクセストークン `sub` の一致強制（OIDC Core §5.3.2 MUST）

## ステータス

🟡 Medium / 未着手

## 1. タイトル

UserInfo Endpoint が返す `sub` が、アクセストークンに紐づく `sub`（= ID Token の `sub`）と必ず一致することを core 側で強制する。現状は `UserClaimsResolver` が返した `sub` をそのまま返しており、一致検証が存在しない。

> 注: アクセストークンの `aud` 検証は `study-material/done/userinfo-access-token-audience-validation.md` / `tasks/p2-userinfo-access-token-audience-validation.md` が扱う。UserInfo の総合レビューは `study-material/userinfo-endpoint-comprehensive.md`。本ファイルはそれらと直交する「`sub` の一致 MUST」のみを扱い、`aud` 検証・スコープフィルタ等の共通説明は繰り返さない。

## 2. このトピックで確認したいこと

- OIDC Core §5.3.2 は「UserInfo Response の `sub` は ID Token の `sub` と**完全一致を検証しなければならない（MUST be verified to exactly match）**」と定めている。OP 側は一貫した `sub` を返す責任がある
- 現状 `handleUserInfoRequest` は `findUserClaims(tokenInfo.sub)` で取得した `userClaims.sub` をレスポンスの `sub` に設定しており、`userClaims.sub === tokenInfo.sub` の検証が無い
- `UserClaimsResolver` は利用者が実装する拡張点であり、ルックアップキー（`tokenInfo.sub`）と異なる `sub` を返すバグ・カスタマイズがあると、UserInfo の `sub` が ID Token の `sub` と静かに乖離する。これを core が検知・防止できるかを確認する

## 3. 関連する仕様・基準

- **OpenID Connect Core 1.0 §5.3.2（Successful UserInfo Response）**:
  - 「The `sub` (subject) Claim MUST always be returned in the UserInfo Response.」
  - 「The `sub` Claim in the UserInfo Response MUST be verified to exactly match the `sub` Claim in the ID Token; if they do not match, the UserInfo Response values MUST NOT be used.」
  - この MUST は主に RP（クライアント）側の検証義務として書かれているが、**OP が一致しない `sub` を返した時点で RP は応答を破棄する**ため、OP 側は「常に一貫した `sub` を返す」ことが実質的な責任になる。OP が異なる `sub` を返すと、正しく実装された RP からは UserInfo が常に拒否され、相互運用が壊れる。
- **OpenID Connect Core 1.0 §5.3.1（UserInfo Request）/ §5.3.2**: UserInfo はアクセストークンに紐づくエンドユーザーのクレームを返す。アクセストークンが識別する subject 以外のクレームを返してはならない（token substitution / claims confusion の防止）。
- **セキュリティ観点（claims/subject confusion）**: もし resolver がキーと異なる `sub` を返せる構造のままだと、実装ミスやデータ不整合で「トークン A の subject を問い合わせたのに subject B のクレームが返る」事故が起こり得る。core で `sub` を `tokenInfo.sub` にピン留め／不一致を拒否すれば、この事故クラスを構造的に排除できる。

## 4. 参照資料

- OpenID Connect Core 1.0 §5.3.2 — https://openid.net/specs/openid-connect-core-1_0.html#UserInfoResponse （`sub` MUST always be returned / MUST be verified to exactly match）
- OpenID Connect Core 1.0 §5.3.1 — https://openid.net/specs/openid-connect-core-1_0.html#UserInfo
- 関連既存ファイル: `study-material/userinfo-endpoint-comprehensive.md`、`study-material/done/userinfo-access-token-audience-validation.md`

## 5. 現在の実装確認

- `packages/core/src/userinfo.ts` `handleUserInfoRequest`:
  - 行 377: `const userClaims = await userClaimsResolver.findUserClaims(tokenInfo.sub);` — ルックアップキーは正しく `tokenInfo.sub`。
  - 行 386: `const response = filterClaimsByScope(userClaims, tokenInfo.scope);`
- `packages/core/src/userinfo.ts` `filterClaimsByScope`（行 214-234）:
  - 行 218: `const result: Record<string, unknown> = { sub: userClaims.sub };` — レスポンスの `sub` は **resolver が返した** `userClaims.sub` をそのまま採用。
  - `userClaims.sub === tokenInfo.sub` の一致検証は**どこにも無い**。
- `study-material/userinfo-endpoint-comprehensive.md`（§6.2 付近）は「resolver が正しい subject で呼ばれることのテストが必要」とは述べているが、「core が resolver の `sub` を無検証で返している」という enforcement の欠落自体は指摘していない。

## 6. 現在の実装との差分

満たしていること:

- `sub` は常にレスポンスに含まれる（§5.3.2 の「always returned」は満たす）。
- ルックアップは `tokenInfo.sub` をキーに行われる（正しい subject を引いている）。

不足している可能性があること:

- 🟡 **`sub` 一致の未強制**: `filterClaimsByScope` が `tokenInfo.sub` ではなく `userClaims.sub` を返すため、両者が食い違っても検知されない。正しい RP は不一致応答を破棄するので、OP が乖離 `sub` を返すと UserInfo が事実上機能しなくなる。
- 🟡 **resolver 契約の曖昧さ**: 「`findUserClaims(sub)` が返すレコードの `sub` は引数 `sub` と一致しなければならない」という契約が明文化・強制されていない。利用者が DB の別カラムを `sub` にマップするなどのミスを誘発しやすい。
- 🟢 **`sub` 欠落時の挙動**: resolver が `sub` を持たないレコードを返すと `result.sub` が `undefined` になり、§5.3.2 の「always returned」に反する可能性。型上 `UserClaims.sub` は必須だが、ランタイム保証は無い。

相互運用性:

- 🟡 正しく実装された RP（openid-client 等は §5.3.2 の一致検証を行う）に対し、乖離 `sub` を返す OP は UserInfo が常に失敗扱いになる。デバッグが難しい相互運用バグになりやすい。

Basic OP 認定との関係:

- UserInfo は Basic OP の対象。Conformance では OP が生成する `sub` を使うため通常は一致するが、「core が一致を保証する」設計にしておくと回帰耐性が上がる。

## 7. 改善・追加を検討する理由

- §5.3.2 の MUST に対する**構造的な安全側設計**。core が `sub` を `tokenInfo.sub` にピン留め（または不一致を拒否）すれば、利用者がどんな resolver を書いても UserInfo の `sub` は ID Token と必ず一致する。
- 「セキュリティ第一・利用者が使いやすい」方針に合致: resolver 実装ミスによる subject confusion を core が吸収し、利用者の負担を下げる。
- 導入容易性: 🟢 小。`filterClaimsByScope` の呼び出し前後で `sub` を `tokenInfo.sub` に固定するか、不一致時に明示エラーを出す分岐を足すだけ。
- 実装しない場合のリスク: 利用者のカスタム resolver 起因の UserInfo 不整合が「OP のバグ」として顕在化しにくく、相互運用トラブルの温床になる。

拡張か必須か:

- §5.3.2 の MUST 履行という意味で **Basic OP 範囲内の堅牢化**。優先度は中。

## 8. 実装方針の候補

### 方針A（`sub` を `tokenInfo.sub` にピン留め, 推奨筆頭）

- `handleUserInfoRequest` 側で、`filterClaimsByScope` の戻り値に対し `response.sub = tokenInfo.sub` を強制設定する。
  - resolver が何を返しても UserInfo の `sub` は必ず ID Token の `sub` と一致。
  - 利点: シンプル・確実。欠点: resolver が「意図的に別の `sub`」を返すユースケース（pairwise の動的算出など）を core が上書きしてしまう懸念 → ただし pairwise も「アクセストークン subject に対応する PPID」であるべきで、`tokenInfo.sub` 自体が既に PPID であるべき（`study-material/pairwise-subject-identifier.md` 参照）なので、ピン留めが正しい。

### 方針B（不一致を検出してエラー化）

- `userClaims.sub !== tokenInfo.sub` を検知したら `UserInfoError`（500 相当 / server_error）を投げる。
- 利点: resolver 契約違反を「黙って直す」のではなく「明示的に失敗」させ、開発時に気付ける。欠点: 本番で resolver データ不整合があると UserInfo が落ちる。
- 方針 A（ピン留め）+ 開発時 assert（dev のみ warn ログ）の併用も検討可。

### 方針C（resolver 契約のドキュメント化のみ）

- core は変更せず、「`findUserClaims(sub)` は `sub` と一致するレコードを返すこと」を `study-material/resolver-and-store-contract.md` に明記。
- 最小だが強制力が無く、ミスを防げない。方針 A/B との併用が望ましい。

判断材料:

- pairwise/PPID を将来サポートする場合、`sub` の決定箇所を「アクセストークン発行時」に寄せるか「UserInfo 応答時」に寄せるかで方針が変わる。現状は `tokenInfo.sub` が確定値なので方針 A が自然。
- 方針 A と B は排他ではなく、「ピン留めしつつ dev で不一致を warn」も可能。

## 9. タスク案

- [ ] 方針（A/B/C もしくは A+dev warn）を決定（人間が判断）
- [ ] （TDD）`userinfo.test.ts` に以下を先に追加:
  - resolver が `tokenInfo.sub` と異なる `sub` を返しても、UserInfo レスポンスの `sub` が `tokenInfo.sub` と一致する（方針 A）／ 不一致でエラー（方針 B）
  - resolver が `sub` 欠落レコードを返したときの挙動を固定（`tokenInfo.sub` で補完 or エラー）
  - 署名付き UserInfo（JWT）でも `sub` が `tokenInfo.sub` になることを確認
- [ ] `userinfo.ts` で `sub` のピン留め／一致検証を実装
- [ ] `study-material/resolver-and-store-contract.md` に「`findUserClaims(sub)` の戻り `sub` は引数と一致」契約を追記
- [ ] `samples/*/conformance.test.ts`（生成元 `packages/cli`）に UserInfo `sub` 一致の契約テストを追加し、利用者改変時に検知できるようにする
