# [P1] `revoke*` は物理削除ではなく使用済み状態として保持し、再利用時の全トークン失効をテストする

## ステータス

🟢 High / revoke* の used 化契約を JSDoc 明文化＋core 回帰テスト（consume vs delete で cascade 発火差を可視化）＋study-material 契約表更新＋sample conformance.test.ts の実 HTTP 再利用フローテストまで実装済み。

## 背景

OAuth 2.1 §4.1.2 / §4.3.1 は「認可コード・リフレッシュトークンの再利用を検知したら、それに紐づく発行済みトークンをすべて失効する（SHOULD）」を求める。core はこれを `revokeTokensByGrantId(grantId)` で実装している。

要点は、**一度使った認可コードやリフレッシュトークンが再利用されたとき、漏洩の可能性を見て同じ grant に紐づく発行済みトークンをすべて失効したいが、使用済みレコードを物理削除してしまうと再利用として検知できなくなる**ということ。core は resolver/store を利用者が注入する設計なので、`revokeAuthorizationCode` / `revokeRefreshToken` が「物理削除」なのか「`used=true` への更新」なのかをライブラリ側だけでは強制できない。

再利用時の全トークン失効を発火させるには、`AuthorizationCodeResolver.revokeAuthorizationCode(code)` / `RefreshTokenResolver.revokeRefreshToken(token)` は**削除ではなく `used=true` への状態更新**として実装し、`find`/`resolve` が少なくとも元の TTL の間は `used:true` のレコードを返し続ける必要がある。利用者がこれを物理削除で実装すると、再提示は `not found`（`invalid_grant`）にはなるが `revokeTokensByGrantId` が**呼ばれず**、漏洩したコード／トークンから発行済みのトークンが生き残る（SHOULD 違反）。`store.ts` には `consume()`（使用済み化）と `delete()`（物理削除）が同居しており、混同のリスクは実在する。

検討の経緯・判断材料は `study-material/done/authorization-code-reuse-cascade-store-semantics.md` を参照。store の横断的な原子性／CAS 契約は `study-material/resolver-and-store-contract.md`、回転時の誤検知緩和は `study-material/refresh-token-rotation-replay-grace.md` を参照（本タスクはそれらと重複せず、`revoke*` を削除ではなく使用済み化として扱う責務に絞る）。

本タスクは破壊的変更を伴わない範囲（JSDoc での責務明記＋回帰テスト）に限定する。命名是正（別名追加）・原子的 consume プリミティブ導入は検討段階として study-material 側に残す。

なお、利用者が生成コードを自分の要件に合わせてカスタマイズすること自体は許容する。ただし、このライブラリが想定する Basic OP の安全な挙動から外れたことを利用者が認識できるように、`samples/*` の `conformance.test.ts` には生成 OP の期待挙動を固定するテストを追加する。`revoke*` を物理削除に差し替えた場合は conformance test が落ちる状態にし、「カスタマイズは可能だが、その状態は本リポジトリが担保する挙動ではない」と分かるようにする。

## 対象ファイル

- `packages/core/src/token-request.ts`（`AuthorizationCodeResolver` / `RefreshTokenResolver` の JSDoc 追記）
- `packages/core/src/token-request.test.ts`（再利用時の全トークン失効に関する正・負の回帰テスト）
- `packages/cli/src/**/templates.ts`（生成される `conformance.test.ts` に再利用時の失効テストを追加）
- `samples/*/src/**/conformance.test.ts`（生成 OP の期待挙動として再利用時の失効を固定）
- `samples/*/src/**/resolvers.ts` / `store.ts`（必要なら used 保持の挙動を固定するテスト）
- `study-material/resolver-and-store-contract.md`（契約表に1行追加し相互参照）
- `CLAUDE.md` / `AGENTS.md`（生成 OP の conformance test を想定挙動の担保として維持する規約を追記）

## 仕様参照

- OAuth 2.1 draft §4.1.2 — 認可コード再利用時に previously issued tokens を失効（SHOULD）。
- OAuth 2.1 draft §4.3.1 — リフレッシュトークン再利用時に token family を失効（SHOULD）。
- OAuth 2.0 Security BCP（RFC 9700）§2.2.4 / §4.13 / §4.14 — replay 検知と grant 失効。
- OIDC Core 1.0 §3.1.3.2 — Token Request におけるコード重複検出の責務。

## 現状の実装

- `token-request.ts:525-533`（authz code）/ `:427-435`（refresh token）: `used` が true のとき `revokeTokensByGrantId(grantId)` を呼ぶ。
- `token-request.ts:619`: 成功時に `revokeAuthorizationCode(code)` を呼ぶ。この呼び出しが使用済み化になるか物理削除になるかは、利用者が注入する resolver/store 実装に依存する。
- 参照実装は正しい: `resolvers.ts:48-50` → `store.ts:58-63` の `consume()` が `entry.used = true`（削除しない）、`store.get` は TTL 内なら used:true を返す。
- しかし `revokeAuthorizationCode` / `revokeRefreshToken` の JSDoc に「削除ではなく使用済み化すること」「TTL 内は find/resolve から used:true を返し続けること」が**書かれていない**。利用者が delete 実装にすると、再利用時の全トークン失効が静かに無効化される。

## 修正方針

- [x] `AuthorizationCodeResolver.revokeAuthorizationCode` の JSDoc に明記する:
  - これは**物理削除ではなく `used=true` への状態遷移**であること
  - 再利用時の全トークン失効（`revokeTokensByGrantId`）を発火させるため、`findAuthorizationCode` は**少なくとも元の認可コード TTL の間は used:true のレコードを返し続けなければならない**こと
  - 物理削除実装は OAuth 2.1 §4.1.2 SHOULD（再利用時のトークン失効）を満たさないこと
- [x] `RefreshTokenResolver.revokeRefreshToken` にも同趣旨（保持期間は refresh token の absolute lifetime 相当まで）を明記する
- [x] `study-material/resolver-and-store-contract.md` の契約表に「`revoke*` = 原子的な used 更新、最低保持＝元 TTL、フェイルクローズ」の行を追加し、本タスク・本 study-material を相互参照する
- [ ] （任意・小）`store.ts` の `delete()` と `consume()` の使い分けコメントを補強し、resolver からは `consume()` を使う旨を明示する
- [x] `samples/*` の `conformance.test.ts`（生成元である `packages/cli` の template を含む）に、認可コードまたはリフレッシュトークンの再利用時に関連トークンが失効することを実 HTTP フローで検知するテストを追加する
- [x] `CLAUDE.md` / `AGENTS.md` に、生成 OP の挙動を変更する場合は `conformance.test.ts` を充実させ、利用者が生成コードを改変しても想定挙動から外れたことをテスト失敗で認識できるようにする方針を追記する

## テスト要件

- [x] **正の回帰**: 認可コードを一度交換した後、`findAuthorizationCode` が同コードを `used:true` で返すこと（削除されていないこと）
- [x] **正の回帰**: used:true の認可コードを再提示すると `invalid_grant` で拒否され、かつ `revokeTokensByGrantId(grantId)` が**呼ばれる**こと（spy / フェイクで検証）
- [x] **正の回帰**: リフレッシュトークン側も同様（used:true 再提示で `revokeTokensByGrantId` が呼ばれる）
- [x] **負の回帰（契約違反の可視化）**: `revokeAuthorizationCode` を物理削除で実装したフェイク store では、再提示が `not found`（`invalid_grant`）になり `revokeTokensByGrantId` が**呼ばれない**ことをテストで明示し、これが契約違反の症状であるとコメントで記す
- [x] **sample conformance**: `samples/*` の `conformance.test.ts` で、生成 OP に対して一度成功した認可コードまたはリフレッシュトークンを再提示し、同一 grant のアクセストークンが UserInfo 等で使えなくなることを確認する
- [x] 既存の正常系（初回交換成功・PKCE 検証）が回帰しないこと

## 完了条件

`pnpm --filter @maronn-openid-connect/core test`（および sample の `conformance.test.ts`）がパスし、上記テストが追加されていること。`revokeAuthorizationCode` / `revokeRefreshToken` の JSDoc に「物理削除ではなく used 更新として扱うこと」と最低保持期間が明記され、`resolver-and-store-contract.md` の契約表に反映されていること。生成 OP をカスタマイズして `conformance.test.ts` が落ちる場合は、その状態が本リポジトリの想定挙動から外れていることを README またはコメントで明示できていること。
