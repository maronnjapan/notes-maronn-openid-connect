# Token Endpoint の grant 種別に属さないパラメータの混入（refresh_token grant での `code` / `code_verifier` / `redirect_uri`）

## ステータス

🟡 Medium / 未着手

## 1. このトピックで確認したいこと

Token Endpoint の `refresh_token` grant 処理は、`refresh_token` と `scope` しか参照せず、
`authorization_code` grant 用のパラメータ（`code` / `code_verifier` / `redirect_uri`）が混入していても
**黙って無視**して成功する。逆に `authorization_code` grant でも `refresh_token` パラメータの混入は無視される。
grant 種別に属さないパラメータを無視するのは即座の脆弱性ではないが、パラメータ混同（parameter confusion）に対する
防御線が引かれておらず、テストでも固定されていない。

本ファイルは、grant 種別ごとに「その grant に属さないパラメータを受け取ったらどう扱うか」を整理し、
検出・拒否の是非を検討する。

> 関連既存ファイル（重複回避）：
> - `study-material/request-parameter-hygiene-and-override-contract.md` は**認可エンドポイント**の
>   パラメータ衛生／override 契約を扱う。本ファイルは **Token Endpoint** の grant パラメータ混同という別レイヤ。
> - `tasks/done/p1-duplicate-parameter-rejection.md` は同名パラメータの**重複**（同一キーの複数出現）拒否を扱う。
>   本ファイルは「別 grant のパラメータの混入」という異なる論点。
> 本ファイル固有の論点は「**Token Endpoint で grant 種別に属さないパラメータの取り扱いを明文化・テスト固定する**」こと。

## 2. 関連する仕様・基準

- **RFC 6749 §4.1.3（Access Token Request, authorization_code）**: `grant_type`, `code`, `redirect_uri`,
  `client_id` を定義。
- **RFC 6749 §6（Refreshing an Access Token）**: refresh のリクエストは `grant_type=refresh_token`,
  `refresh_token`, `scope`。`code` 等は grammar に含まれない。
- **OAuth 2.1 §4.3.1（Refresh Token Grant）**: 同上。refresh に `code`/`code_verifier`/`redirect_uri` は不要。
- **一般原則（パラメータ混同への耐性）**: 仕様は「未知／余剰パラメータを無視してよい」と読める箇所も多く、
  混入を必ず拒否せよという MUST は無い。ただし conformance／セキュリティテストでは「grant に属さない
  パラメータへの耐性」を確認することがあり、少なくとも挙動を明示的にテスト固定しておく価値がある。

## 3. 参照資料

- RFC 6749 §4.1.3（Access Token Request）: https://www.rfc-editor.org/rfc/rfc6749#section-4.1.3
- RFC 6749 §6（Refreshing an Access Token）: https://www.rfc-editor.org/rfc/rfc6749#section-6
- OAuth 2.1（draft）§4.3.1（Refresh Token Grant）: https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1

## 4. 現在の実装確認

- `packages/core/src/token-request.ts`
  - `refresh_token` grant 分岐（`:450-554` 付近）: `params.refresh_token` と `params.scope` のみ参照。
    `params.code` / `params.code_verifier` / `params.redirect_uri` が来ても検査・拒否しない。
  - `authorization_code` grant 分岐（`:556-704` 付近）: `params.refresh_token` の混入は参照されず無視される。
- 現状、混入は `invalid_request` にならず、正常なトークン発行が行われる。

## 5. 現在の実装との差分

- **満たしていること**
  - 各 grant の必須パラメータ検証・PKCE・redirect_uri 一致など、grant 本体のロジックは正しい。
- **不足している可能性があること**
  - grant に属さないパラメータの混入に対する明示的な扱い（無視 or 拒否）が**未定義・未テスト**。
- **セキュリティ上の観点**
  - 直接の攻撃経路は薄いが、grant confusion 系の探索に対して「余剰パラメータを黙認する」挙動は
    防御的でない。将来 grant を増やしたときにパラメータ解釈の取り違えが起きやすい。
- **相互運用性**
  - 無視するか拒否するかを明文化しておくことで、利用者が生成コードを改変した際の想定挙動が明確になる。

## 6. 改善・追加を検討する理由

- **セキュリティ（防御的設計）**: 「その grant に属さないパラメータは受け取らない」ことを契約化しておくと、
  パラメータ混同攻撃の探索面を狭められる。
- **明確性 / 保守性**: 挙動をテストで固定すれば、将来 grant（例: 拡張の client_credentials 等）を追加した際に
  パラメータ解釈が交差しないことを担保できる。
- **導入しやすさ**: core の grant 分岐先頭で「属さないパラメータの存在チェック」を足すだけ。
  ただし「無視」を選ぶ場合はテスト固定のみで実装変更不要。
- **実装しない場合のリスク**: 混同耐性がテストされないまま残り、リファクタで意図しないパラメータ解釈が混入しても検知できない。

## 7. 実装方針の候補

判断材料の整理（最終判断は人間）。

- 方針A（拒否）: `refresh_token` grant で `code`/`code_verifier`/`redirect_uri` が存在したら `invalid_request`。
  同様に `authorization_code` grant で `refresh_token` が存在したら `invalid_request`。
  - 最も防御的。ただし「余剰パラメータは無視してよい」という寛容な実装も多く、
    厳しすぎると一部クライアントの実装差で弾く可能性がある点は要判断。
- 方針B（無視＋テスト固定）: 現状の「無視」を正式挙動とし、`token-request.test.ts` で
  「混入しても正しい grant として処理される」ことを固定。実装変更なし、契約の明文化のみ。
- 方針C（限定拒否）: PKCE に関わる `code_verifier` のみ、refresh で来たら拒否する等、
  セキュリティ影響が相対的にある項目だけを対象にする折衷。
- どの方針でも「grant 種別判定 → パラメータ整合」の順序を崩さないこと。

## 8. タスク案

- [ ] 方針を決定（拒否 / 無視＋固定 / 限定拒否）
- [ ] `token-request.test.ts` に先行テスト（Red or 固定）:
  - [ ] `grant_type=refresh_token` + `code`/`code_verifier`/`redirect_uri` 混入時の挙動
  - [ ] `grant_type=authorization_code` + `refresh_token` 混入時の挙動
- [ ] 方針に応じて `validateTokenRequest` を修正（拒否の場合）または挙動を固定（無視の場合）
- [ ] 生成 OP の挙動が変わる場合は `packages/cli` テンプレートと各 sample の `conformance.test.ts` を更新
- [ ] 完了条件: `pnpm --filter @maronn-openid-connect/core test` がパス
