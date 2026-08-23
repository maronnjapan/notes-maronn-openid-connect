# サブジェクト単位のトークン一括失効（パスワード変更 / アカウント無効化 / 侵害時の `valid_after` ウォーターマーク）

## ステータス

🟠 High（セキュリティ・Refresh Token フロー）/ 未着手

## 1. このトピックで確認したいこと

「ユーザー（subject）に紐づく**すべての**有効なトークン（Refresh Token / Access Token / 確立済みセッション）を、ある時点を境に一括で無効化する」仕組みが本リポジトリに無い点を確認する。

典型的に必要になる場面:

- パスワード変更 / リセット（旧クレデンシャルで確立したセッション・RT を全て切りたい）
- アカウントの一時停止・無効化・削除
- 端末紛失・侵害疑い時の「全デバイスからログアウト」
- 管理者によるユーザーの強制サインアウト

既存ファイルとの差分（重複させない）:

- `tasks/done/p0-token-revocation-on-code-reuse.md` / `study-material/refresh-token-rotation-replay-grace.md` が扱う失効は、**`grantId` 単位の cascade revocation**（1 つの認可グラントから派生したトークン群の失効）であり、**subject 単位ではない**。
- `tasks/done/p1-token-revocation.md`（RFC 7009）は **個別トークン 1 本**の失効。クライアントが token を持っていないと呼べない。
- ログアウト系（`study-material/ext-backchannel-logout-oidc.md` 等）は **RP への通知プロトコル**であり、OP 側で RT/AT を実際に無効化する責務とは別レイヤ。
- `study-material/done/consent-grant-persistence-and-management.md` は **client × subject の同意（grant）管理**で、これも grant 粒度。subject 全体に対する「この時刻より前のトークンは全部無効」というウォーターマークは扱っていない。

本ファイルは「**subject 単位 × 時刻ウォーターマーク**による一括無効化」という未カバーの軸に絞る。Refresh Token は寿命が長く、この機構の有無が最も効くため、Refresh Token フロー改善として位置づける。

## 2. 関連する仕様・基準

共通の仕様索引は `study-material/basic-op-requirement-traceability.md` を参照。本トピック固有のポイント:

- **OAuth 2.0 Security BCP（RFC 9700）§4.14 Refresh Token Protection**: Refresh Token は長期間有効になりうるため、AS は「侵害時に無効化できる」こと、リソース所有者がアクセスを取り消せることを求める。subject 単位の一括失効はこの「取り消し可能性」を実効化する実装手段。
- **OAuth 2.1 §6 / RFC 6749 §10.4**: Refresh Token は「リソース所有者がいつでも取り消せる」ことを前提とする。個別 revocation だけでは「クレデンシャル変更に伴う全失効」を表現できない。
- **OIDC Core 1.0 §3.1.3.3 / §2（`auth_time`）**: トークンは認証イベント（`auth_time`）に紐づく。クレデンシャル変更後に**旧認証イベント由来のトークンを無効化**するには、発行時刻 / `auth_time` と subject 単位の「失効基準時刻」を突き合わせる設計が自然。
- **OIDC Back-Channel/Front-Channel Logout / Session Management（既存 ext ファイル）**: これらは「ログアウトを RP に伝える」プロトコル。OP が **自分の発行済み RT/AT を実際に死なせる**バックエンド機構は別途必要で、本ファイルがその土台。ログアウトの `sid` と subject ウォーターマークの双方を持つ設計が望ましい。

注意: 本機構は **Basic OP 認定要件ではない**（拡張的セキュリティ機能）。Conformance テストは subject 単位の一括失効を叩かない。しかし「本番志向 OSS」「セキュリティ最優先」の方針では実運用上ほぼ必須。

## 3. 参照資料

- RFC 9700 OAuth 2.0 Security Best Current Practice §4.14 Refresh Token Protection — https://www.rfc-editor.org/rfc/rfc9700
- OAuth 2.1 draft §6（Refresh Tokens）— https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1
- RFC 6749 §10.4 Refresh Tokens（取り消し可能性）— https://www.rfc-editor.org/rfc/rfc6749#section-10.4
- RFC 7009 OAuth 2.0 Token Revocation（個別失効。本ファイルは subject 単位への拡張差分）— https://www.rfc-editor.org/rfc/rfc7009
- OpenID Connect Core 1.0 §2（`auth_time`）— https://openid.net/specs/openid-connect-core-1_0.html#IDToken
- 本リポジトリ内（重複説明回避のため参照に留める）:
  - `study-material/refresh-token-rotation-replay-grace.md`（grantId 単位 cascade との違い）
  - `study-material/done/consent-grant-persistence-and-management.md`（grant 粒度の管理との違い）
  - `study-material/ext-backchannel-logout-oidc.md` / `study-material/ext-channel-logout-notifications.md`（ログアウト通知レイヤとの分担）
  - `study-material/token-lifetime-security-policy.md`（寿命ポリシー全般）

## 4. 現在の実装確認

- `packages/core/src/token-request.ts`: refresh_token grant で `RefreshTokenInfo`（`used` / `grantId` / `originalIssuedAt` 等）を resolver から取得し検証。失効判定は「`used` フラグ」「絶対寿命」「grantId 単位 cascade」。**subject 単位の失効基準時刻は参照していない**。
- `packages/core/src/revocation.ts`: RFC 7009 の**個別トークン**失効。token を指定して 1 本ずつ。
- `packages/core/src/access-token-issuer.ts`:
  - **JWT アクセストークン**は自己完結（署名 + `exp`）で検証される設計のため、**発行後は満了まで取り消せない**（subject 単位どころか個別失効も、JWT のままでは introspection/allowlist が無いと効かない）。
  - **Opaque アクセストークン**は store 参照なので、store 側で消せば即時失効できる。
- `packages/sample/src/oidc-provider/store.ts` / `resolvers.ts`: grant は `subject → client → scope` で保持（`store.ts:240-258` 付近）。しかし「subject 単位の失効基準時刻（`tokensValidAfter`）」を持つ構造は無い。
- リポジトリ全体に「subject を指定して当該ユーザーの全 RT/AT/セッションを無効化する」API・resolver・テストは存在しない（grep 確認済み）。

## 5. 現在の実装との差分

満たしていること:

- 個別トークン失効（RFC 7009）✅
- grantId 単位 cascade（再利用検知時）✅
- Refresh Token 絶対寿命 ✅
- grant（client×subject×scope）の記録・管理 ✅（done）

不足／曖昧な点:

- 🟠 **subject 単位の一括失効ができない**: パスワード変更時に「この人の全 RT を無効化」するには、現状は grant を列挙して 1 つずつ失効する実装を利用者が自前で書く必要がある。原子性・網羅性の担保が利用者任せ。
- 🟠 **JWT アクセストークンが取り消せない**: subject ウォーターマークを導入しても、自己完結 JWT AT は満了まで生き続ける。subject 失効を実効化するには「JWT AT を introspection（オンライン検証）対象にする」か「AT 寿命を十分短くして RT 失効で実質的に断つ」かの設計判断が要る（`study-material/jwt-access-token-rfc9068.md` / `study-material/token-lifetime-security-policy.md` と接続）。
- 🟡 **`valid_after` ウォーターマークの不在**: 「subject S について時刻 T 以前に発行されたトークン/認証は無効」という最小状態を持てば、RT 検証時に `originalIssuedAt < validAfter(subject)` なら拒否、という一行判定で網羅的な一括失効が表現できる。この状態とフックが無い。
- 🟡 **ログアウト系との接続点が未定義**: Back-Channel Logout（`sid`）と subject ウォーターマークのどちらを真実とするか、両者の関係（session 単位 vs subject 単位）が設計されていない。

セキュリティ的観点:

- 🔴 クレデンシャル侵害・パスワード変更後に**旧トークンが生き残る**のは重大なリスク。長寿命 Refresh Token があるほど影響が長引く。RFC 9700 §4.14 が求める「取り消し可能性」を運用で満たすには本機構が要。

## 6. 改善・追加を検討する理由

- **価値**: 「パスワード変更したのに古いセッションが生きている」は実運用で最も問い合わせ・インシデントになりやすい。subject 単位ウォーターマークは**最小の状態追加（subject→timestamp）**で網羅的失効を表現でき、費用対効果が高い。Refresh Token フロー改善の本丸。
- **Basic OP として必須か**: 認定要件ではなく拡張的セキュリティ。ただし本番運用 OSS としては実質必須レベル。
- **導入しやすさ**: core はポリシーを持たず、`SubjectInvalidationResolver`（仮）のような**任意注入の resolver**で「`getValidAfter(subject): timestamp | null` と `invalidateSubjectBefore(subject, timestamp)`」を提供し、`token-request.ts` の RT 検証に「`originalIssuedAt < validAfter` なら `invalid_grant`」の 1 分岐を足すだけで接続できる（既存 resolver 注入思想と整合、外部依存も不要）。
- **既存実装との接続**: RT 検証点（`token-request.ts`）に分岐追加 / opaque AT store に同等チェック / JWT AT は寿命短縮 or introspection 化で対応。sample/CLI テンプレに参照実装（KV/D1 で subject→timestamp を 1 レコード持つ）を提供。
- **利用者メリット**: 「全デバイスからログアウト」「アカウント停止」を、grant を全列挙せずに 1 レコード更新で実現できる。運用者は侵害時の封じ込めが速くなる。
- **実装しない場合のリスク**: 利用者が独自に grant 全列挙の失効を書き、原子性・漏れ・JWT AT の生き残りを取りこぼす。RFC 9700 の「取り消し可能性」を実運用で満たせない。

## 7. 実装方針の候補

最終判断（resolver 形・JWT AT をどう扱うか・既定で有効化するか）は人間が行う。

- **方針A（subject ウォーターマーク resolver）**: `getSubjectValidAfter(subject)` を任意注入。RT 検証時に `originalIssuedAt`（および opaque AT の発行時刻）と突き合わせ、古ければ `invalid_grant` / 失効。状態は subject ごとに timestamp 1 つで最小。一括失効は `validAfter = now` を書くだけ。
- **方針B（grant 全列挙 cascade）**: subject に紐づく grant を列挙し、各 grantId に既存 cascade revocation を適用。新しい状態は不要だが、store に「subject→grantId 一覧」の索引と原子性が要る。網羅性は store 実装品質に依存。
- **方針C（セッション連動）**: Back-Channel Logout / Session Management（既存 ext）と統合し、`sid` 失効 → 当該セッション由来トークン失効。session 単位は表現できるが、「subject の全 session」を切るには結局 subject 索引が要る。
- **JWT AT の扱い（横断課題）**: (i) AT 寿命を短くして RT 失効で実質封じ込め、(ii) JWT AT も introspection（オンライン検証）対象にして allowlist/denylist を引く、(iii) opaque AT を既定にする。`study-material/token-lifetime-security-policy.md` / `study-material/jwt-access-token-rfc9068.md` と合わせて判断。

方針A（ウォーターマーク）+ AT 寿命短縮の組み合わせが、状態最小・実装局所・セキュリティ実効性のバランスが良いと考えられるが、最終決定は人間が行う。

## 8. タスク案

- [ ] subject 単位失効の表現方法（方針A: ウォーターマーク / B: grant 全列挙 / C: session 連動）を人間が決定
- [ ] JWT アクセストークンを subject 失効の対象にするか（寿命短縮 / introspection 化 / opaque 既定）の方針決定
- [ ]（方針A採用時）core に `SubjectInvalidationResolver`（`getValidAfter` / `invalidateSubjectBefore`）の I/F を定義（任意注入・未注入時は従来通り）
- [ ]（TDD）`token-request.test.ts`: `validAfter` 以後に発行された RT は通る / それ以前の RT は `invalid_grant` で拒否される / resolver 未注入なら従来通り、のテストを先に追加
- [ ] `token-request.ts` の RT 検証に subject ウォーターマーク分岐を追加（fail-closed、resolver 例外時は拒否側）
- [ ] opaque AT 検証経路にも同等チェックを追加（JWT AT は別方針に従う）
- [ ] sample / CLI テンプレに subject→timestamp を 1 レコードで持つ参照 resolver と「全デバイスログアウト」例を追加（生成コードは cli 側を修正）
- [ ] ログアウト系 ext（`ext-backchannel-logout-oidc.md` 等）と本ウォーターマークの関係（session 単位 vs subject 単位）を各ファイルに相互注記
- [ ] `study-material/token-lifetime-security-policy.md` に「subject 失効を実効化するための AT 寿命方針」への参照を追加

## 関連トピック

- `study-material/refresh-token-rotation-replay-grace.md` — grantId 単位 cascade（本ファイルは subject 単位ウォーターマーク）
- `study-material/done/consent-grant-persistence-and-management.md` — grant（client×subject）管理（本ファイルは subject 全体の時刻ウォーターマーク）
- `study-material/ext-backchannel-logout-oidc.md` / `study-material/ext-channel-logout-notifications.md` — ログアウト通知レイヤ（本ファイルは OP 側の実失効バックエンド）
- `study-material/token-lifetime-security-policy.md` / `study-material/jwt-access-token-rfc9068.md` — JWT AT を失効可能にするための寿命・検証方針
