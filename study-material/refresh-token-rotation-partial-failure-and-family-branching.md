# Refresh Token ローテーションの部分失敗（旧 RT の失効に失敗）による token family の分岐

## ステータス

🟠 High（セキュリティ / 信頼性）/ 未着手（方針未確定 = 検討中）

## 1. このトピックで確認したいこと

生成 OP の Token Endpoint は、refresh_token grant のローテーションを次の順序で行う。

1. 新しい access token / refresh token を発行する
2. `accessTokenStore.set(newAccessToken, ...)`
3. `refreshTokenStore.set(newRefreshToken, ...)`
4. `refreshTokenResolver.revokeRefreshToken(oldRefreshToken)` ← **旧 RT の失効**
5. HTTP レスポンスを返す

この順序自体は「新トークンの保存に成功してから旧を失効する」という既定方針
（`tasks/done/oidc-improvements-2026-05.md` T-004）に沿っており、**手順 3 で失敗した場合**は
旧 RT が生き残るのでユーザーはロックアウトされない。設計意図どおりである。

本ファイルが確認したいのは **手順 4 で失敗した場合**、すなわち
「新 RT の保存には成功したが、旧 RT の失効に失敗した」ときに何が起きるか、である。
このとき **同一 `grantId` に有効な refresh token が 2 本併存**し、かつ
そのどちらも `used = false` であるため、**ローテーションの中核である再利用検知
（cascade revocation）が発火しない**状態が生まれる。

> **既存ファイルとの切り分け（重複回避）**
>
> | 論点 | 扱っているファイル |
> |---|---|
> | 失効の**順序**（発行前 or 発行後）の是非、認可コード側との非対称 | `study-material/authorization-code-consumption-timing-vs-issuance-atomicity.md` |
> | 正当な二重送信で cascade が**誤発火**する問題（猶予窓 / 冪等回転） | `study-material/refresh-token-rotation-replay-grace.md` |
> | `revoke` が「used=true 化」か「物理削除」かの契約 | `tasks/done/p1-revoke-mark-used-contract-and-reuse-cascade-regression.md` |
> | store の CAS / アトミック性の**契約文書化** | `study-material/resolver-and-store-contract.md` |
> | cascade がクライアント所有権チェックより前に走る問題 | `study-material/token-reuse-cascade-ordering-vs-client-binding.md` |
>
> 上記はいずれも「順序をどう決めるか」「検知が過剰か」「契約をどう書くか」の話である。
> 本ファイルは **順序を守ったうえで、その途中でエラーが起きたときに残る状態**（部分失敗）に限定する。
> `refresh-token-rotation-replay-grace.md` が扱う「レスポンスを取りこぼしてユーザーがロックアウトされる」
> ケースの**鏡像**（旧 RT が生き残り検知不能な family 分岐が起きる）であり、方向が逆である。

## 2. 関連する仕様・基準（このトピック固有の差分）

Refresh Token rotation と cascade revocation の共通説明は
`study-material/refresh-token-rotation-replay-grace.md` および
`tasks/done/oidc-improvements-2026-05.md`（T-003 / T-004）を参照し、ここでは繰り返さない。
本トピックに直接効く条文だけを引く。

### 2.1 OAuth 2.1 draft §4.3.1 — rotation は「旧トークンが無効になること」を含む

> Authorization servers MAY issue a new refresh token ... If a new refresh token is issued,
> the refresh token scope MUST be identical to that of the refresh token included by the client
> in the request. **... the authorization server MAY revoke the old refresh token after issuing
> a new refresh token to the client.** If a new refresh token is issued, the old refresh token
> SHOULD be invalidated ...

rotation の定義そのものが「新を出したら旧を無効にする」ことを含む。旧が無効化されなければ
それは rotation ではなく「単に新しい RT を追加発行した」状態である。

### 2.2 RFC 9700（OAuth 2.0 Security BCP）§4.14.2 — 検知は「無効化済み RT の提示」に依存する

> ... the authorization server ... **if a refresh token is compromised and subsequently used
> by both the attacker and the legitimate client, one of them will present an invalidated
> refresh token, which will inform the authorization server of the breach.**

侵害検知は「**無効化済みの RT が提示される**」という事象を検知の起点にしている。
旧 RT が無効化されないまま生き残ると、攻撃者と正当クライアントが**それぞれ別の有効な RT を
持って並行に rotation を続けられる**ため、この検知メカニズムは**永久に発火しない**。
つまり本件は「可用性の問題」ではなく **rotation という対策の前提が壊れる問題**である。

### 2.3 仕様が規定していないこと（＝実装判断が要る範囲）

- 「新 RT の保存に成功し、旧 RT の失効に失敗した」ときにどう回復すべきかは、
  OAuth 2.1 / RFC 9700 のいずれも規定していない。分散ストア前提のトランザクション境界は
  実装の責務であり、**本リポジトリが契約として決める必要がある**。

## 3. 参照資料

- OAuth 2.1 draft §4.3.1 Refresh Token Grant / §6 Refresh Tokens
  — https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1
- RFC 9700 OAuth 2.0 Security Best Current Practice §4.14 Refresh Token Protection
  — https://www.rfc-editor.org/rfc/rfc9700.html#section-4.14
- RFC 6749 §6 Refreshing an Access Token — https://www.rfc-editor.org/rfc/rfc6749#section-6
- 本リポジトリ内:
  - `packages/cli/src/frameworks/hono/templates.ts`（`tokenRouteTemplate`。生成物は
    `samples/*/src/oidc-provider/routes/token.ts`）
  - `packages/core/src/refresh-token-grant.ts`（`validateRefreshTokenUnused`）
  - `study-material/refresh-token-rotation-replay-grace.md`（鏡像ケース）
  - `study-material/resolver-and-store-contract.md`（store 契約の総論）

## 4. 現在の実装確認

### 4.1 生成 OP のローテーション手順

`samples/hono-cloudflare/src/oidc-provider/routes/token.ts`（生成元は `packages/cli`）:

```ts
await accessTokenStore.set(tokenResponse.access_token, { ... });

if (tokenResponse.refresh_token) {
  await refreshTokenStore.set(tokenResponse.refresh_token, {
    subject, clientId, scope: refreshTokenScope, expiresAt: refreshTokenExpiresAt,
    originalIssuedAt, used: false, grantId: validatedRequest.grantId, ...
  });
}

// OAuth 2.1 Section 4.3.1: ローテーションは新トークン保存成功後に旧 RT を失効する。
// 失敗時にユーザーがリフレッシュ不能になることを防ぐため、必ずこの順序にする。
if (validatedRequest.grantType === 'refresh_token' && params.refresh_token) {
  await refreshTokenResolver.revokeRefreshToken(params.refresh_token);
}

c.header('Cache-Control', 'no-store');
c.header('Pragma', 'no-cache');
return c.json(tokenResponse);
```

- `revokeRefreshToken` の失敗は **try/catch で個別にハンドリングされていない**。
  外側の catch に落ちてエラーレスポンス（`server_error` 系）になる。
- 補償処理（新 RT の巻き戻し、再試行、family マーキング）は無い。

### 4.2 部分失敗時に残る状態

`refreshTokenStore.set(new)` が成功し `revokeRefreshToken(old)` が失敗した場合:

| トークン | ストア上の状態 | クライアントの手元 |
|---|---|---|
| 旧 RT | 有効（`used = false`） | **持っている**（レスポンスを受け取れていないため） |
| 新 RT | 有効（`used = false`） | 持っていない（レスポンスが返っていない） |

- クライアントは旧 RT で再試行する。旧 RT は `used = false` なので
  `validateRefreshTokenUnused` を素通りし、**正常に rotation が再実行される**。
- その結果、同一 `grantId` に対して「旧 RT の子」と「最初の失敗で作られた孤児 RT」の
  **2 系統が有効なまま**残る。孤児 RT は誰も持っていないが、絶対寿命
  （`config.refreshTokenAbsoluteLifetime`、既定 90 日相当）まで有効であり続ける。
- 孤児 RT が第三者に漏れた場合（バックアップ流出、ログ漏洩、ストア侵害）、
  その RT による rotation は「無効化済み RT の提示」を伴わないため
  **cascade revocation が発火せず、侵害が検知されないまま継続する**。

### 4.3 `validateRefreshTokenUnused` は「1 grant に有効 RT は 1 本」を前提にしている

`packages/core/src/refresh-token-grant.ts`:

```ts
export async function validateRefreshTokenUnused(refreshTokenInfo, refreshTokenResolver) {
  if (!refreshTokenInfo.used) {
    return;                                   // ← 有効な RT が何本あっても素通りする
  }
  if (refreshTokenResolver.revokeTokensByGrantId) {
    await refreshTokenResolver.revokeTokensByGrantId(refreshTokenInfo.grantId);
  }
  throw new TokenError(TokenErrorCode.InvalidGrant, 'Refresh token has already been used');
}
```

検知は「提示された **その 1 本** が used か」だけを見ており、
「この grant に有効な RT が何本あるか」は見ていない。したがって family の分岐は
core 側でも検知できない。

### 4.4 再現シナリオ

1. RP が `scope=openid offline_access` + `prompt=consent` で認可し、RT `R1` を得る。
2. RP が `R1` で refresh。OP は `R2` を保存した直後、`revokeRefreshToken(R1)` が
   ストア障害（KV の一時エラー、D1 のロック競合、ネットワーク断など）で失敗。
   OP は 500 系を返す。
3. RP は `R1` を保持したまま再試行。今度は成功し `R3` を得る。
4. ストアには `R2`（孤児・有効）と `R3`（RP が保持・有効）が**同一 `grantId` で併存**する。
5. `R2` が後日漏洩して使われても、`R2` は `used = false` なので cascade は起きず、
   攻撃者は `R2` 系統で rotation を継続できる。RP 側にも OP 側にも異常は観測されない。

## 5. 現在の実装との差分

### 満たしていること

- ✅ rotation 順序（新トークン保存 → 旧失効）は可用性の観点で正しく、手順 3 での失敗は安全に倒れる。
- ✅ `used` 検出時の cascade revocation（`revokeTokensByGrantId`）は実装済み。
- ✅ 絶対寿命（`originalIssuedAt` の引き継ぎ）により、分岐した family も無限には生き残らない。

### 不足している可能性があること

- 🟠 **手順 4 の失敗に対する補償が無い**。旧 RT が生き残ったまま新 RT も有効になり、
  rotation の前提（1 grant につき有効 RT は 1 本）が破れる。
- 🟠 **family の分岐を検知する手段が無い**。`RefreshTokenInfo` は `grantId` を持つが、
  「この grant で現在有効な RT はどれか」を表す情報（世代番号、親子リンク、`currentTokenId` など）が
  無いため、分岐が起きたことを後から検知・是正できない。
- 🟡 **孤児 RT が回収されない**。誰も持っていない RT が絶対寿命まで残り、
  攻撃対象面（ストア侵害時の被害）を無為に広げる。
- 🟡 **観測性が無い**。部分失敗は 500 応答としてしか現れず、
  「rotation が途中で壊れた」ことを運用者が識別できる signal（構造化ログ / メトリクス）が無い。
  `study-material/audit-logging-and-observability.md` の枠組みに載せるべき事象だが、
  当該ファイルは個別事象の列挙まではしていない。

### 実装はあるが仕様上の確認が必要なこと

- そもそも「旧 RT の失効に失敗したら、新 RT も無効化して**トランザクション全体を巻き戻す**」のが
  正しいのか、「旧 RT を失効できるまで**再試行し続ける**」のが正しいのかは仕様に無い。
  前者は可用性を落とし（クライアントは旧 RT で再試行できるので実害は小さい）、
  後者はストア障害時に応答が遅延する。

### セキュリティ上、改善した方がよいこと

- 巻き戻し（新 RT の削除）を選ぶ場合、その削除自体も失敗し得るため、
  「最終的に整合させる」仕組み（世代番号による無効化、grant 単位の有効世代の記録）が
  補償処理より堅牢である可能性がある。これは方針判断の核心。

### 相互運用性の観点

- 本件はクライアント側の実装に依存しない（クライアントは仕様どおり旧 RT で再試行するだけ）。
  相互運用性の問題ではなく、OP 内部の一貫性の問題である。

### Basic OP として提供する上で確認すべきこと

- Basic OP certification に refresh token rotation の障害時挙動を検査するテストは無いため、
  認定のブロッカーではない。ただし本リポジトリは
  「rotation と再利用検知を実装済み」と `study-material/basic-op-requirement-traceability.md` で
  主張しているので、**その主張が障害時にも成り立つか**を明示する価値がある。

## 6. 改善・追加を検討する理由

- **なぜ価値があるか**: rotation は本リポジトリが「実装済み」と明言しているセキュリティ機構であり、
  その前提（有効 RT は 1 本）が静かに破れる経路が残っているのは、機能の有無ではなく
  **主張の正確さ**の問題である。PoC 利用者はここを検証できないまま本番設計に持ち込む。
- **Basic OP に必要か、拡張として有用か**: Basic OP の必須要件ではない。
  ただし OAuth 2.1 / RFC 9700 準拠を掲げる以上、rotation の健全性は品質要件に入る。
- **導入しやすさ**:
  - 🟢 最小案（部分失敗を検知可能にする観測性＋ドキュメント化）は生成テンプレートへの
    `try/catch` 追加とログ出力だけで済む。
  - 🟡 世代管理案は `RefreshTokenInfo` にフィールド追加（後方互換）と
    `validateRefreshTokenUnused` の判定拡張が要る。core の public API に影響する。
- **既存実装との接続**: `grantId` による cascade の仕組みが既にあるので、
  「grant ごとの有効世代」を持たせる案はその延長線上に載る。
  `revokeTokensByGrantId` という resolver も既にあるため、巻き戻し案でも新しい I/F は要らない。
- **利用者・開発者・運用者のメリット**: 運用者は「rotation が壊れた」ことを検知できる。
  利用者は障害時の挙動が契約として書かれていることで、自分のストア実装の要件を判断できる。
- **実装しない場合に残るリスク**: 検知不能な family 分岐が残り、
  「rotation により侵害を検知できる」という前提が障害時に静かに失われる。
  分散ストア（KV など結果整合なストア）を選んだ利用者ほど発生確率が高い。

## 7. 実装方針の候補（最終判断は人間が行う）

### 方針A: 部分失敗を検知可能にする（最小・非破壊）

- 生成テンプレートで `revokeRefreshToken(old)` を個別に `try/catch` し、
  失敗時に「rotation partial failure」を構造化ログへ出す。
  レスポンスは従来どおりエラーにする（クライアントは旧 RT で再試行できる）。
- 長所: 実装が小さく、core に触らない。運用者が分岐の発生を知れる。
- 短所: 分岐そのものは防げない。孤児 RT も残る。

### 方針B: 補償（新 RT の巻き戻し）

- `revokeRefreshToken(old)` が失敗したら、直前に保存した新 RT / 新 AT を削除してから
  エラーを返す。「旧だけが有効」な状態に戻す。
- 長所: 有効 RT が 1 本という不変条件を保てる。既存 resolver で実装できる。
- 短所: 補償自体も失敗し得る（二重障害）。補償が失敗したときの扱いが再帰的に問題になる。

### 方針C: grant 単位の有効世代を持つ（構造的解決）

- `RefreshTokenInfo` に世代（`generation: number`）または親リンク（`parentTokenId`）を持たせ、
  grant 側に「現在の有効世代」を記録する。提示された RT の世代が最新でなければ
  `used` フラグに依存せず**古い世代として拒否＋cascade** する。
- 長所: 部分失敗が起きても、最新世代以外は自動的に無効になるため分岐が成立しない。
  孤児 RT も「最新世代でない」ため自然に無効化される。
- 短所: `RefreshTokenInfo` と resolver 契約の拡張が必要（後方互換だが public API 面が増える）。
  grant 単位の状態を持つストアが要るため、利用者の実装負荷が上がる。
  `study-material/refresh-token-rotation-replay-grace.md` の猶予窓案と設計が競合しうるので、
  **両者を同時に設計する必要がある**。

### 方針D: 現状維持＋契約の明文化

- 「旧 RT の失効に失敗した場合、有効 RT が一時的に 2 本になり得る。
  resolver の `revokeRefreshToken` は冪等かつ高信頼であること」を
  `study-material/resolver-and-store-contract.md` と生成コードコメントに明記する。
- 長所: コスト最小。実際、責務を resolver 側に寄せるのは本リポジトリの設計思想と整合する。
- 短所: 利用者のストア実装品質に全面依存する。

### 判断材料

- 方針A は他のどの方針とも併用でき、単独でも価値がある（まず観測できるようにする）。
- 方針C は `refresh-token-rotation-replay-grace.md`（猶予窓 / 冪等回転）と
  **同じデータモデル拡張を要求する**。両トピックを別々に実装すると `RefreshTokenInfo` を
  二度拡張することになるため、**設計を合わせるか、順序を決める価値が高い**。
- `RELEASE-v0.x-scope.md` の「core はポリシーを持ちすぎない」方針では、
  方針 A + D の組み合わせが v0.x に収まりやすい。方針C は v0.x 後のロードマップ候補。

## 8. タスク案

- [ ] 方針（A / A+B / A+C / A+D）を決定する。特に方針C を採る場合は
      `study-material/refresh-token-rotation-replay-grace.md` と**同時に**データモデルを設計する
- [ ] （TDD・方針共通）`packages/cli` の生成テンプレートに対する回帰テストとして、
      `revokeRefreshToken` が reject する状況を注入し、以下を固定する:
  - [ ] 旧 RT が有効なまま残り、クライアントが旧 RT で再試行できること（現状挙動の明示）
  - [ ] 部分失敗が観測可能な形（ログ / 戻り値）で表面化すること（方針A）
  - [ ] 新 RT が巻き戻されること（方針B 採用時）
  - [ ] 旧世代 RT の提示が cascade を伴って拒否されること（方針C 採用時）
- [ ] 方針A: 生成テンプレートの `revokeRefreshToken` 呼び出しを個別 `try/catch` にし、
      partial failure を構造化ログへ出す。`study-material/audit-logging-and-observability.md` の
      イベント一覧に「rotation partial failure」を追加する
- [ ] 方針B: 補償処理（新 AT / 新 RT の削除）を追加し、補償自体が失敗したときの挙動を決める
- [ ] 方針C: `RefreshTokenInfo` に世代 / 親リンクを追加し、`validateRefreshTokenUnused` を
      「最新世代でなければ cascade」へ拡張する。`RefreshTokenResolver` の契約も更新する
- [ ] 方針D: `study-material/resolver-and-store-contract.md` に
      「`revokeRefreshToken` は冪等かつ高信頼であること」「失敗時に有効 RT が 2 本になり得ること」を追記する
- [ ] `study-material/basic-op-requirement-traceability.md` の Refresh Token 行に、
      障害時の不変条件（有効 RT は 1 本か否か）の注記を追加する
- [ ] `samples/*/conformance.test.ts`（生成元は `packages/cli`）へ、決定した挙動を契約テストとして追加する

## 関連トピック

- 📌 `study-material/refresh-token-rotation-replay-grace.md` — 本ファイルの**鏡像**。
  あちらは「レスポンス取りこぼし → 旧 RT が失効済み → ロックアウト」、
  本ファイルは「失効に失敗 → 旧 RT が有効なまま → 検知不能な family 分岐」。
  方針C（世代管理）は両者を同時に解く可能性があるため、設計は連動させること。
- 📌 `study-material/authorization-code-consumption-timing-vs-issuance-atomicity.md` — 失効「順序」の是非。
  本ファイルは順序を所与として、その途中の失敗を扱う。
- 📌 `study-material/resolver-and-store-contract.md` — store 契約の総論。方針D の受け皿。
- 📌 `study-material/token-reuse-cascade-ordering-vs-client-binding.md` — cascade の発火条件そのものの論点。
