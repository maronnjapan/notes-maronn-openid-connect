# Refresh Token のアイドル（無操作）タイムアウト = スライディング有効期限の任意提供

## ステータス

🟡 セキュリティ強化（任意・オプトイン）/ 未着手

## 1. このトピックで確認したいこと

現在の Refresh Token（RT）の有効期限は **絶対有効期限（absolute lifetime）のみ**で構成されている。
`p1-refresh-token-absolute-lifetime.md`（実装済み）で「ローテーションを跨いで `originalIssuedAt` を引き継ぎ、
`expiresAt = originalIssuedAt + 絶対有効期限` で固定する（= 無限延長させない）」方針が確定・実装された。

本トピックでは、その絶対有効期限とは **別軸** の制御である
**アイドルタイムアウト（最後に使われてから N 秒で失効する＝スライディング有効期限）** を、
**任意・オプトインの追加ポリシー**として提供すべきかを検討する。

> 関連トピックとの境界:
> - 絶対有効期限の設計判断は `study-material/token-lifetime-security-policy.md` と `tasks/done`/`tasks` の絶対有効期限タスクが扱う（重複記載しない）。
> - ローテーション・再利用検知は `refresh-token-rotation-replay-grace.md` / `refresh-token-public-client-rotation-enforcement.md` が扱う。
> - 本トピックは「**絶対期限内であっても、一定期間 RT が使われなければ失効させる**」という、**未だどのファイルでも扱っていない一軸**のみを扱う。

## 2. 関連する仕様・基準

- **OAuth 2.1（draft-ietf-oauth-v2-1）§4.3 / §6.1**: RT のローテーション、および RT の有効期限を限定すること（sender-constrained でない public client の RT 保護）を求める。アイドルタイムアウトは MUST ではないが、RT の露出時間を縮める一手段。
- **RFC 9700（OAuth 2.0 Security Best Current Practice）§4.14.2「Refresh Token Protection」**
  - public client の RT は **(a) sender-constrained** または **(b) ローテーション** のいずれかで保護すべき（本リポジトリは(b)を採用）。
  - さらに RT の **有効期限制限**を推奨し、その手段として「**最大寿命（absolute）**」と「**最後の利用からの非活動期間（inactivity）**」の双方を挙げている。すなわちアイドルタイムアウトは BCP が明示的に挙げる正規の保護手段。
- **RFC 6749 §10.4**: RT は漏洩時の影響が大きいため、有効期限・失効・ローテーションで露出を抑えるべき、という一般原則。
- 注: OIDC `offline_access`（`offline-access-scope-grant-policy.md` 参照）でRTを長期保持するユースケースと、アイドルタイムアウトは両立する（「長期だが、放置されたら切る」）。

## 3. 参照資料

- RFC 9700 §4.14.2: https://www.rfc-editor.org/rfc/rfc9700#section-4.14.2 （RT 保護手段としての絶対寿命＋非活動期間）
- OAuth 2.1 §4.3 / §6.1: https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1 （RT ローテーション・有効期限）
- RFC 6749 §10.4: https://www.rfc-editor.org/rfc/rfc6749#section-10.4 （RT のセキュリティ考慮）
- 実装上の先行例（一次情報ではないが設計参考）: 主要 IdP の「Inactivity / Idle expiration」と「Absolute / Maximum lifetime」の二軸構成。

## 4. 現在の実装確認

- core: `RefreshTokenInfo`（`packages/core/src/token-request.ts:166-221`）が持つ時間系フィールドは
  `expiresAt` / `iat?` / `originalIssuedAt` のみ。**「最後に使われた時刻（lastUsedAt）」を保持しない**。
- core の `validateTokenRequest()`（同 `token-request.ts:438-443`）の RT 失効判定は
  `refreshTokenInfo.expiresAt < now` の**絶対期限のみ**。非活動期間の判定は無い。
- CLI 生成テンプレート（`packages/cli/src/frameworks/hono/templates.ts`）は、明示コメントで
  「**sliding expiry を持たず、RT の `expiresAt` は initial issuance（`originalIssuedAt`）からの絶対的な期限で固定する**」と設計意図を記述（同ファイル 133 行付近）。
  `refreshTokenExpiresAt = originalIssuedAt + config.refreshTokenAbsoluteLifetime`（同 1399 行付近）で算出。
- つまり **アイドルタイムアウトは現状「意図的に未提供」**。本トピックはその意図を尊重しつつ、**任意機能としての追加**を検討するもの。

## 5. 現在の実装との差分

- **満たしていること**: 絶対有効期限により RT の無限延長は防げている。ローテーション＋再利用検知で漏洩 RT の連続使用も検知できる。
- **不足している可能性があること**: 「**絶対期限内だが長期間放置された RT**」が、放置後も（漏洩していれば）一度は使えてしまう。アイドルタイムアウトがあれば、放置 RT を自動失効でき露出窓を縮められる。
- **セキュリティ上の改善**: RFC 9700 §4.14.2 が挙げる二軸（absolute + inactivity）のうち inactivity 側が欠けている。高保証用途の利用者が「絶対90日／ただし14日無操作で失効」のような構成を取れない。
- **相互運用性**: アイドルタイムアウトはトークン文字列やレスポンス形式を変えないため、RPからは透過（失効時は通常どおり `invalid_grant`）。互換性影響は無い。
- **Basic OP として**: 要件ではない（Basic OP 定義は `basic-op-requirements-baseline.md` を参照）。**任意のセキュリティ強化**。

## 6. 改善・追加を検討する理由

- **なぜ価値があるか**: 「最新の仕様を忠実に試せる」ことを掲げる本ライブラリで、RFC 9700 が明記する RT 保護の二軸の一方（inactivity）を**設定で再現できる**ことは Fidelity 軸に資する。利用者が自分の要件（例: 金融系の無操作失効ポリシー）を検証できる。
- **拡張機能か必須か**: 拡張（任意）。**既定 OFF** とし、設定したときだけ有効化する。既定挙動（絶対期限のみ）は変えない。
- **導入しやすさ**: `RefreshTokenInfo` は resolver/store 注入型のため、`lastUsedAt`（または `idleExpiresAt`）の付帯は利用者ストア側で素直に持てる。core 側の判定追加も `expiresAt` チェックの隣に1分岐を足すだけで、既存設計と整合する。
- **既存実装との接続**: 既存の絶対期限（`originalIssuedAt`）・ローテーション・再利用検知と独立に積める。失効時のエラーは既存の `invalid_grant` を流用。
- **実装しない場合のリスク**: 放置された長期 RT の露出窓が絶対期限まで残り続ける。利用者は inactivity ポリシーの検証手段を持てず、本番 IdP との差分検証ができない。

## 7. 実装方針の候補（最終判断は人間）

### 方針A: core にオプトインのアイドル判定を足す（推奨検討軸）

- `RefreshTokenInfo` に任意フィールド `lastUsedAt?: number`（または利用者が計算した `idleExpiresAt?: number`）を追加。
- `validateTokenRequest()` の RT 失効判定に、設定された `idleTimeoutSeconds` がある場合のみ
  `now - lastUsedAt > idleTimeoutSeconds` で `invalid_grant` を追加。**未設定なら従来どおり**（後方互換）。
- ローテーション時、新 RT の `lastUsedAt` を「今」に更新（= スライディング）。絶対期限は `originalIssuedAt` 据え置きで二軸を両立。
- 判定主体を core に置くことで、CLI 生成テンプレート以外の利用者も同じロジックを共有できる。

### 方針B: 判定を利用者（store/テンプレート）側に委ね、core は契約とドキュメントのみ提供

- core は `lastUsedAt?` フィールドの定義と「アイドル失効は store/呼び出し側責務」という契約を明文化。
- 利点: core を最小に保てる。欠点: 利用者ごとに実装がぶれ、Fidelity の一貫性が下がる。

### 方針C: 提供しない（現状維持）

- 絶対期限のみで十分とみなし、本トピックは保留。判断材料として現状コメント（templates.ts 133 行）を「意図的非提供」として残す。

### 補足: 既定値の考え方

- 既定は **OFF（`idleTimeoutSeconds` 未設定 = アイドル失効なし）**。有効化時の推奨例は用途依存のため、ドキュメントで「絶対 ≧ アイドル」となるよう注意喚起する（アイドル > 絶対は無意味）。

## 8. タスク案

> 方針A は既存契約に対する**後方互換な追加**であり、既定挙動を変えないため着手可能と判断。`tasks/` 化する（下記タスクファイル参照）。
> 方針B/C を採る場合は本タスクを取り下げる。

- [ ] 方針A/B/C を選択（ユーザー判断）。A の場合 `lastUsedAt` か `idleExpiresAt` のどちらを契約にするか決める
- [ ] core: `RefreshTokenInfo` に任意フィールド追加＋`validateTokenRequest` のアイドル判定（テスト先行・既定 OFF の後方互換を固定）
- [ ] CLI テンプレート: `refreshTokenIdleTimeout`（任意 config・既定 0=無効）と store への `lastUsedAt` 保存／ローテーション時更新
- [ ] ドキュメント: 「絶対有効期限（既実装）」と「アイドルタイムアウト（本機能）」の二軸関係を `token-lifetime-security-policy.md` から参照できるよう追記
