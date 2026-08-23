# 拡張: RP-Initiated Logout / Session Management 系

## ステータス

🟢 拡張機能 / 未着手

## 1. このトピックで確認したいこと

ログイン系は実装済みだが **ログアウト系の仕様が一切未実装**。
最も需要が高い **OpenID Connect RP-Initiated Logout 1.0** を中心に、
関連する Session Management / Front-Channel / Back-Channel Logout の導入可否を確認する。

このファイルは「ログアウト系」を 1 トピックとして扱う（RP-Initiated を主、他を関連として整理）。

## 2. 関連する仕様・基準

- **OpenID Connect RP-Initiated Logout 1.0**
  - `end_session_endpoint`: RP が `id_token_hint`（必須推奨）/ `post_logout_redirect_uri` /
    `state` / `logout_hint` / `client_id` を付けて OP に遷移。OP は OP セッションを終了し、
    登録済み `post_logout_redirect_uri` に厳格一致すれば redirect。
  - Discovery: `end_session_endpoint`、クライアントメタデータ `post_logout_redirect_uris`。
- **OpenID Connect Session Management 1.0**: `check_session_iframe`、`session_state`。
- **OpenID Connect Front-Channel Logout 1.0** / **Back-Channel Logout 1.0**:
  他 RP へのログアウト伝播（`logout_token`= JWT、`sid`/`events` クレーム）。
- いずれも Basic OP 必須ではない（拡張）。位置づけは `tasks/basic-op-requirements-baseline.md` 参照。

## 3. 参照資料

- RP-Initiated Logout 1.0: https://openid.net/specs/openid-connect-rpinitiated-1_0.html
- Session Management 1.0: https://openid.net/specs/openid-connect-session-1_0.html
- Front-Channel Logout 1.0: https://openid.net/specs/openid-connect-frontchannel-1_0.html
- Back-Channel Logout 1.0: https://openid.net/specs/openid-connect-backchannel-1_0.html

## 4. 現在の実装確認

- ログイン/同意/セッションは実装済み（`auth-transaction.ts`、sample `routes/login.ts`,
  `routes/consent.ts`、`SessionResolver`）。
- **ログアウト関連は皆無**:
  - `end_session_endpoint` ルート無し。
  - Discovery（`discovery.ts`）に `end_session_endpoint` フィールド無し。
  - `post_logout_redirect_uris` のクライアントメタデータ無し（`ClientInfo` は
    `redirectUris` のみ: `authorization-request.ts:70-74`）。
  - `id_token_hint` 検証ヘルパーは存在（`id-token.ts:198` validateIdTokenHint, done T-017）
    → ログアウト時の `id_token_hint` 検証に**再利用可能**。
  - セッション破棄は概念上 `SessionResolver` の裏側にあるが、OP セッション終了 API は無い。

## 5. 現在の実装との差分

- **満たしていること**: `id_token_hint` 検証・セッション解決の部品があり、
  RP-Initiated Logout の中核（hint 検証→セッション終了→post_logout redirect）に流用できる。
- **不足している可能性があること**
  - `end_session_endpoint` 本体（hint 検証・OP セッション終了・post-logout 厳格一致 redirect・state 返却）。
  - クライアント登録に `post_logout_redirect_uris`。redirect_uri と同じく**完全一致**検証が必要。
  - Discovery に `end_session_endpoint`。
  - セッション「終了」を表現する resolver/store I/F（現状 resolve のみ、delete 相当が無い）。
  - Front/Back-Channel は `logout_token`（JWT）発行と RP 通知が必要で規模大。
- **セキュリティ**: `post_logout_redirect_uri` のオープンリダイレクト防止（完全一致）必須。

## 6. 改善・追加を検討する理由

- ログアウトは実運用 PoC で必ず問われる。ログインだけ検証できてログアウトを
  検証できないのは「要件がこの仕様で実現できるか」のブリッジとして片手落ち。
- `id_token_hint` 検証・セッション解決の既存資産があり、RP-Initiated Logout は
  **比較的導入しやすい**。Front/Back-Channel は規模が大きく段階導入が現実的。
- 実装しない場合の制約: SSO のシングルログアウト要件を一切検証できない。

## 7. 実装方針の候補

### 方針A（段階導入・推奨度高）: RP-Initiated Logout のみ先行

- core に「ログアウト要求検証」純関数:
  `id_token_hint` 検証（既存 `validateIdTokenHint` 再利用）→
  `post_logout_redirect_uri` を登録値と**完全一致**検証 → 返却 `state` の echo。
- セッション終了は利用者責務（`SessionTerminator` 的 callback 注入）。
- `ClientInfo` に `postLogoutRedirectUris?: string[]` を追加（任意）。
- Discovery（core builder）に `end_session_endpoint`。
- CLI/sample に `/logout`（end_session）ルート生成（確認画面有無は config）。

### 方針B: + Back-Channel Logout

- `logout_token`（JWT, `sid`/`events`）発行ヘルパーと RP 通知フックを追加。規模大。

### 方針C（非対応の明文化）

- 当面非対応をロードマップ化。

## 8. タスク案

- [ ] 方針A/B/C を選択（ユーザー判断）。RP-Initiated を最小スコープで先行する前提で良いか確認
- [ ] ログアウト要求検証（hint 検証 + post_logout 完全一致 + state echo）のテストを先行作成
- [ ] core ヘルパー実装（`validateIdTokenHint` / `SessionResolver` 資産を再利用）
- [ ] `ClientInfo` に `postLogoutRedirectUris` 追加（後方互換: optional）
- [ ] Discovery に `end_session_endpoint`（core builder へ寄せる方針で他 Discovery タスクと整合）
- [ ] CLI/sample に end_session ルート生成 + セッション終了 callback スタブ
- [ ] 完了条件: core / cli テストがパス
