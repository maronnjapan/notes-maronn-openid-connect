# 認可コードの「使用済み化」タイミングとトークン発行の原子性（Refresh 側の遅延失効との非対称）

## 1. このトピックで確認したいこと

`validateTokenRequest` は authorization_code グラントで、**トークン生成・保存の前に**認可コードを `revokeAuthorizationCode`（used=true 化）している。一方、同じ関数の refresh_token グラントは「旧 Refresh Token の失効は**新トークンの保存に成功した後**に呼び出し側で行う」と明示的にコメントし、失効を遅延させている。この 2 経路の**設計判断が正反対**であることが、意図的なのか非整合なのかを確認したい。

論点は「どちらが正しいか」を断定することではなく、**なぜ非対称なのかを契約として明文化し、必要なら片方に寄せるか**という判断材料の整理である。

## 2. 関連する仕様・基準

共通の「認可コード single-use・再利用時の cascade 失効・used=true vs 物理削除の契約」の説明は `study-material/done/authorization-code-reuse-cascade-store-semantics.md` および `tasks/done/p1-revoke-mark-used-contract-and-reuse-cascade-regression.md` を参照し繰り返さない。本ファイルは**「いつ used=true にするか」= 発行成功との前後関係**に限定する。

- **OAuth 2.1 §4.1.2 / RFC 6749 §4.1.2**: 認可コードは single-use。再提示は拒否し、SHOULD で発行済みトークンを失効する。ただし「used 化を発行成功の前に行うか後に行うか」の順序までは規定しない（実装裁量）。
- **RFC 9700 (OAuth 2.0 Security BCP) §4.13**: 認可コードのインジェクション/再利用対策として single-use と再利用検知を要求。ここでも消費タイミングと発行成功の原子性は実装に委ねられる。
- **可用性の観点（本リポジトリの Refresh 側が採る論法）**: `token-request.ts:535-538` は「先に失効すると、後続の `generateTokenResponse` / `store.set` が失敗した場合にユーザーが旧 RT も新 RT も持たない状態に陥り再ログインを強いる」ため、失効を保存成功後に遅延させている。認可コードの再取得は**フル再認証**を要するため、同じ可用性論法が当てはまる余地がある。

## 3. 参照資料

- OAuth 2.1 draft §4.1.2 Authorization Code（single-use / 再利用時失効）— https://datatracker.ietf.org/doc/draft-ietf-oauth-v2-1/
- RFC 9700 (OAuth 2.0 Security BCP) §4.13 Authorization Code — https://datatracker.ietf.org/doc/html/rfc9700
- 本リポジトリ内: `packages/core/src/token-request.ts:535-538`（refresh 側の遅延失効の根拠コメント）、`:692-693`（auth code の即時 used 化）
- 既存トピック: `study-material/done/authorization-code-reuse-cascade-store-semantics.md`（used=true 契約と cascade。**消費タイミングは扱っていない**）

## 4. 現在の実装確認

authorization_code グラント（`packages/core/src/token-request.ts`）:

```ts
// PKCE 検証などを通過した後、まだトークンは何も生成していない段階で:
await authCodeResolver.revokeAuthorizationCode(params.code);   // L692-693: used=true 化
return { grantType: 'authorization_code', ... };               // ここで validate 完了
```

- `revokeAuthorizationCode` は `validateTokenRequest` の内部で、返却の直前に実行される。この時点では `generateTokenResponse`（アクセス/ID トークン生成）も、呼び出し側の `accessTokenStore.set` / `refreshTokenStore.set` も**まだ走っていない**。
- したがって、validate 通過後にトークン生成や store 書き込みが失敗すると、認可コードは既に used=true で、クライアントはトークンを 1 つも得られないままコードだけを失う。

refresh_token グラント（同ファイル）:

```ts
// トークンローテーション順序 (OAuth 2.1 Section 4.3.1):
// 旧 RT の失効は呼び出し側が「新トークン保存に成功した後」に行う。
// ここで先に失効すると、... ユーザーが旧 RT も新 RT も持たない状態に陥り...  // L535-538
return { grantType: 'refresh_token', ... };  // 失効は呼び出し側 (routes/token.ts:352-354) に委譲
```

- sample の `routes/token.ts:350-354` は新トークン保存後に `revokeRefreshToken` を呼ぶ（遅延失効）。

## 5. 現在の実装との差分

満たしていること:
- single-use と再利用検知（used=true + cascade）は両経路とも実装済み・仕様準拠。

確認が必要なこと（契約の非対称）:
- 🟡 **auth code は即時 used 化（発行前）、refresh token は遅延失効（発行後）**という正反対の順序。可用性論法（再ログイン回避）は auth code にも当てはまるのに、判断が分かれている。
- この非対称は**ドキュメント化もテストもされていない**。将来の改変者が「refresh に合わせて auth code も遅延させる」あるいは逆を行った際、意図を判断する根拠が無い。

セキュリティ上の考慮（即時 used 化を擁護する側）:
- auth code は「同一コードの並行二重提示（double-submit / レース）」を受けやすい。**先に used 化する**と、2 本目のリクエストが即座に used 検知経路に入り cascade できるため、レース下での安全側に倒れる。遅延させると、保存完了までのウィンドウで 2 本目も検証を通過し得る懸念がある。
- refresh token はローテーションのリトライ耐性（`study-material/refresh-token-rotation-replay-grace.md` の誤検知緩和）を重視する文脈があり、遅延失効と相性が良い。

つまり「即時 used 化はレース安全性、遅延失効は可用性」というトレードオフで、**必ずしも非対称が誤りとは限らない**。

## 6. 改善・追加を検討する理由

- **なぜ検討するか**: 監査容易性。同一関数内で正反対の順序を採る以上、その理由を契約として固定しないと、後続の変更で片方が意図せず崩れる。
- **Basic OP 必須か拡張か**: どちらでもない。認定要件は single-use と再利用検知であり、消費タイミングは実装裁量。
- **判断が割れる点（タスク化を保留する理由）**: 「auth code も遅延失効に寄せる（可用性重視）」と「現状維持でレース安全性を優先し契約を明文化する」のどちらが望ましいかは、レース耐性 vs 可用性の価値判断であり **AI が単独で決めるべきでない**。したがって本ファイルは検討材料として残し、タスク化しない。
- **実装しない場合のリスク**: 実害は限定的（トークン生成/保存が失敗する頻度は低い）。ただし非対称の理由が暗黙のままだと、将来のリファクタで安全性か可用性のどちらかが静かに劣化し得る。

## 7. 実装方針の候補（判断材料）

最終判断は人間が行う。

- 方針A（現状維持 + 契約の明文化・推奨の一つ）: auth code の即時 used 化を「並行二重提示のレース安全性を優先する意図的な選択」として、`token-request.ts` のコメントと `study-material/done/authorization-code-reuse-cascade-store-semantics.md` に明記。非対称の理由を固定し、テストで順序を保証する。
- 方針B（auth code も遅延失効に寄せる）: `revokeAuthorizationCode` を validate 内から外し、refresh と同様に「新トークン保存成功後」に呼び出し側で実行する。可用性は上がるが、並行二重提示に対する「二重発行」を防ぐ別機構（例: コード単位のロック、条件付き `consume`（compare-and-set）でのアトミックな used 化）が必要になる。store 契約（`study-material/resolver-and-store-contract.md`）への影響を要評価。
- 方針C（アトミック消費に統一）: `consume()` を「used が false のときだけ true にして成功を返す」CAS 的操作にし、コードの used 化とトークン発行を「消費成功 → 発行 → 失敗時ロールバック（used を戻す）」の二相にする。最も堅牢だが store 抽象の要件が上がる。

方針 B/C は store 抽象（`AuthorizationCodeResolver` / sample の `store.ts` の `consume`）の契約変更を伴うため、`conformance.test.ts` 生成元（`packages/cli`）の更新も必要になる点に注意。

## 8. タスク案（タスク化は保留）

順序の是非が未決のためタスク化しない。決定のための調査・議論項目のみ挙げる。

- [ ] 並行二重提示（同一 code の同時 2 リクエスト）に対する現状挙動を統合テストで観察し、即時 used 化がレース安全性にどれだけ寄与しているかを実測する
- [ ] 方針 A（現状維持 + 明文化）/ B（遅延失効）/ C（CAS 二相）を `design-discussion` で比較し、レース耐性 vs 可用性の優先順位を人間が決定する
- [ ] 決定後、`token-request.ts` のコメントと該当 study-material に契約を明記し、順序を固定するテストを追加する

## 関連トピック

- `study-material/done/authorization-code-reuse-cascade-store-semantics.md` — used=true 契約と再利用 cascade。本ファイルは「used 化のタイミング（発行成功との前後）」という別軸を扱う。
- `study-material/refresh-token-rotation-replay-grace.md` — refresh 側の遅延失効・誤検知緩和。auth code との対称/非対称を考える際の対照。
- `study-material/resolver-and-store-contract.md` — 方針 B/C が触れる store 抽象の契約。
