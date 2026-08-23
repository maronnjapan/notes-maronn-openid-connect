# Refresh Token ローテーション再利用検知の誤検知緩和（リプレイ猶予 / 冪等回転）

## 1. タイトル

Refresh Token ローテーション時の「再利用検知 → 同 grant 全失効（cascade revocation）」が、ネットワーク再送・並行リクエスト等の正当な二重送信で**誤発火**しユーザーをロックアウトする問題の緩和。

## 2. このトピックで確認したいこと

- 現状の再利用検知は `used` フラグ検出で即時に同 `grantId` の全トークンを失効する厳格動作。これは攻撃検知としては正しいが、**正当な二重送信**（モバイルのリトライ、タブ並行、レスポンス取りこぼし後の再試行）でも発火し、利用者を不必要にログアウトさせる
- RFC 9700 は再利用時に攻撃者と正当クライアントを識別できないことを明記するが、短い猶予や冪等応答は規定しない。これらを採る場合は仕様要件ではなく実装上のトレードオフとして評価する
- 本論点は Refresh Token フローの改善であり、既存の Refresh 系タスク（ローテーション順序、cascade revocation の"存在"、絶対寿命、スコープ縮小）とは**別の差分**（誤検知の運用品質）であることを確認

## 3. 関連する仕様・基準

共通の Refresh Token 仕様説明は重複させない。既存の確定事項:

- ローテーション順序（新規保存成功後に旧失効）: `tasks/done/oidc-improvements-2026-05.md` T-004
- 再利用時の cascade revocation の**存在**: `tasks/done/oidc-improvements-2026-05.md` T-003
- 絶対寿命: 📌 `tasks/p1-refresh-token-absolute-lifetime.md`
- スコープ縮小時の挙動: 📌 `tasks/p1-refresh-scope-offline-access-rotation.md` / `tasks/done/T-020-refresh-scope-claims-filter.md`

本トピック固有の差分（誤検知緩和）に関する根拠:

- **OAuth 2.1 §4.3.1 / §6**: refresh token rotation を推奨し、回転後の旧 token 再利用は侵害の兆候として扱う（= cascade revocation の根拠。既存実装は準拠済み）
- **OAuth 2.0 Security Best Current Practice（RFC 9700）§4.14 Refresh Token Protection**: rotation で無効化済み RT が提示された場合、AS は攻撃者と正当クライアントのどちらが提示したかを識別できず、active refresh token を失効させると説明する。**短時間の猶予や後継トークンの冪等再提示は RFC 9700 の推奨ではない**ため、導入する場合はリプレイ検知を弱める独自ポリシーとして明示する
- 重要: 緩和は**侵害検知の無効化ではない**。猶予窓は極短（数秒〜十数秒程度の設計判断）、かつ「猶予外の再利用」「猶予窓内でも別 IP/別proof 等の異常」では従来通り cascade revocation する設計が前提

## 4. 参照資料

- OAuth 2.1 draft §4.3.1, §6 — https://datatracker.ietf.org/doc/draft-ietf-oauth-v2-1/ （refresh token rotation と再利用時の失効）
- OAuth 2.0 Security Best Current Practice（RFC 9700）— https://www.rfc-editor.org/rfc/rfc9700.html （§4.14 Refresh Token Protection、rotation と再利用検知）
- 本リポジトリ内: `tasks/done/oidc-improvements-2026-05.md` T-003 / T-004（cascade revocation・回転順序の確定済み実装。本タスクはその上に乗る差分）

## 5. 現在の実装確認

- `packages/core/src/token-request.ts`: refresh_token grant 検証で `if (refreshTokenInfo.used)` を検出すると `revokeTokensByGrantId(grantId)` を呼び、`invalid_grant` を返す（再利用＝即時 cascade 失効）。猶予窓・冪等回転・直近後継トークンの再提示ロジックは**無い**
- `RefreshTokenInfo` は `used` 真偽と `grantId` を保持。`rotatedAt`（いつ回転したか）や「この RT の後継 RT/AT」を辿るためのリンク情報は保持していない
- sample / CLI テンプレート（`routes/token.ts`）: 新トークン保存成功後に旧 RT を `revoke` する順序（T-004 準拠）。リトライ時に旧 RT が来れば core の `used` 検出経路に入り cascade される

## 6. 現在の実装との差分

満たしていること:

- 攻撃シナリオ（盗難 RT の再利用）に対する cascade revocation は実装済み・仕様準拠（OAuth 2.1）
- 回転順序が安全（失敗時にトークンを失わない、T-004）

不足・確認が必要なこと:

- 🟡 **正当二重送信の誤検知**: レスポンス取りこぼし後の同一 RT 再送（モバイルで頻出）でも `used` 検出 → 全失効。ユーザーは突然サインアウトされ「壊れている」体験になる。本ライブラリの想定ユーザー（PoC 開発者、ID 管理が弱い SME）はこの挙動を「ライブラリの不具合」と誤認しやすい
- 🟡 **冪等性の欠如**: 「直前の回転で発行済みの後継トークン」を辿れないため、安全に冪等応答（同じ後継を返す）する選択肢が取れない
- 🟡 **猶予窓の設計余地が型に無い**: `rotatedAt` や後継リンクが `RefreshTokenInfo` に無く、緩和を入れるにはモデル拡張が必要

## 7. 改善・追加を検討する理由

- 相互運用性・利用者体験: 正当リトライでのロックアウトは、OSS の「素早く仕様を体感する」価値提案を直接損なう。検証中に意図しないログアウトが頻発すると、利用者は仕様の問題かライブラリの問題か切り分けられず離脱する
- セキュリティとのトレードオフ: 「極短猶予 + 異常時は従来通り cascade」は正当リトライを救える一方、猶予中のリプレイを許す。RFC 9700 の要件として扱わず、脅威モデルと観測可能なシグナルを定めた上で選択する必要がある
- 導入接続性: 既存の `grantId` / cascade 機構の上に「`rotatedAt` と後継リンク」を足すだけで、検知判定の分岐点（`token-request.ts` の `used` 検出箇所）に局所追加できる。core はポリシーを持たず、猶予秒数や有効化は resolver/設定で注入する（既存の resolver 注入思想と整合）
- 実装しない場合のリスク: 「rotation 実装済み」を謳いつつ、現実のネットワーク条件下では正当ユーザーを切る挙動が残る。PoC 検証の信頼性低下

## 8. 実装方針の候補

いずれも「猶予は極短・既定で安全側（緩和は明示的にオプトイン or 明確な既定値）」を前提に、判断材料として整理:

- 方針A（直近回転の冪等応答）: 旧 RT に「後継 RT/AT への参照」を持たせ、猶予窓内で旧 RT が再送されたら **同じ後継トークンを冪等に返す**（新規回転しない）。猶予外 or 異常は従来通り cascade。最も体験が良いが状態管理が増える
- 方針B（短い猶予でスルー）: `rotatedAt` を持たせ、回転後 N 秒以内の旧 RT 再送は cascade せず `invalid_grant` を静かに返す（クライアントは現行 RT を保持しているはず）。冪等応答より単純だがクライアント実装次第でリカバリ不能なケースが残る
- 方針C（現状維持 + 文書化）: 緩和は入れず、CLI 生成コード/ドキュメントに「RT 再利用は全失効する。クライアントはレスポンス確実受領まで RT を破棄しない実装にすること」を明記。実装コスト最小だが体験課題は残置
- 方針D（resolver 注入）: 猶予秒数・有効/無効・冪等 or 不可を `RefreshTokenResolver` の設定として外部注入し、core はポリシーを持たない（`RELEASE-v0.x-scope.md` の「責務の境界」と整合）

猶予窓の秒数、A/B のどちらを既定にするか、そもそも v0.x に入れるか後続ロードマップ送りか（`RELEASE-v0.x-scope.md` 準拠で判断）は人間が決定する。

## 9. タスク案

- [ ] 方針（A/B/C/D）と既定挙動・猶予秒数を決定（セキュリティ非劣化を満たすことを条件に）
- [ ] （A/B 採用時）`RefreshTokenInfo` に `rotatedAt`（および A なら後継トークン参照）を追加
- [ ] （TDD）`token-request.test.ts`: 猶予窓内の正当再送 → ロックアウトしない／猶予外の再送 → 従来通り cascade／異常（別文脈）→ cascade のテストを先に追加
- [ ] `token-request.ts` の `used` 検出分岐に猶予/冪等ロジックを実装（攻撃検知能力の非劣化をテストで保証）
- [ ] sample / CLI テンプレートの resolver に猶予設定の注入口を追加（方針D採用時）
- [ ] CLI 生成コードのコメントに「RT を確実受領まで破棄しないクライアント実装」の注意書きを追加（方針Cでも実施）
- [ ] `tasks/basic-op-requirement-traceability.md` の OAuth Behaviors 行に注記（誤検知緩和の有無）

## 関連トピック

- 📌 `study-material/refresh-token-public-client-rotation-enforcement.md` — 本ファイルは rotation の**機構と誤検知緩和**を扱う。パブリッククライアントで rotation（or sender-constrained）を**強制する**という OAuth 2.1 §4.3.1 / RFC 9700 §4.14 のポリシー差分は別ファイルで扱う。
