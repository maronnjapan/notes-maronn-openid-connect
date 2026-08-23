# JWT クレームの時刻許容（Clock Skew）ポリシーと設定可能化

## 1. タイトル

OP が発行・検証する JWT（ID Token / JWT Access Token / `id_token_hint` / 将来の Request Object / DPoP）における `iat` / `exp` / `nbf` の取り扱いと、Clock Skew（時刻ずれ）許容の統一ポリシーを整理する。

## 2. このトピックで確認したいこと

- 検証時の Clock Skew 許容秒数（leeway）が、ID Token と `id_token_hint` 検証で**ハードコードされた 60 秒**になっており、設定変更ができない。Basic OP として「OP の発行物を OP 自身が検証する場合は厳密でよい」「外部から渡される JWT は緩める必要がある」という非対称性が整理できているか。
- `iat` の上限（未来日付）を検証していない箇所がないか。`exp` ≤ `iat` のような不整合を OP が誤って発行していないか。
- 関連既存トピック: `study-material/token-lifetime-security-policy.md`（TTL ポリシー）、`tasks/p3-jwt-access-token-nbf.md`（JWT Access Token に `nbf` を含めるか）、`tasks/p2-jwt-header-reject-unsafe-fields.md`（JWT ヘッダ防御）。本ファイルは **`iat`/`exp`/`nbf` の Clock Skew 許容**という横断ポリシーに特化し、TTL や `nbf` 単独タスクとは別軸で扱う。

## 3. 関連する仕様・基準

TTL（有効期間）そのものや refresh の絶対寿命は `study-material/token-lifetime-security-policy.md` を参照。ここでは「時刻検証時の許容」に特化する。

### 3.1 OIDC Core 1.0 §3.1.3.7 (10) — ID Token Validation

- 検証側は `iat` を「too far in the past」として制限できる。許容期間は RP が決めると規定（OP には明示要件なし）。
- `exp` は現在時刻より未来でなければならない。Clock Skew 許容は実装定義。

### 3.2 RFC 7519 §4.1 — JWT Registered Claims

- `iat`（Issued At）: NumericDate。OP は発行時刻を秒精度で記録。
- `exp`（Expiration Time）: NumericDate。検証時に `now > exp` なら拒否。Clock Skew は実装が「small leeway, usually no more than a few minutes」で許容してよい（informational）。
- `nbf`（Not Before）: NumericDate。検証時に `now < nbf` なら拒否。同じく Clock Skew leeway が許容される。

### 3.3 RFC 8725 §3.8 — JWT BCP（既存トピック）

- 検証側は `iat`/`exp`/`nbf` を厳格に確認すること、leeway は「数分以内（a few minutes）」が一般的な目安。
- 大きな leeway は再生攻撃の窓を広げる。

### 3.4 RFC 9068 §2.2.1 — JWT Profile for Access Tokens

- Access Token JWT は `iat` と `exp` を含める MUST。
- `nbf` は OPTIONAL（本リポジトリの `tasks/p3-jwt-access-token-nbf.md` で個別検討中）。

### 3.5 本リポジトリの非対称性

| シナリオ | 検証主体 | 現状の leeway |
|---|---|---|
| ID Token を OP 自身が（テスト・運用デバッグで）検証 | `validatePayload` in `id-token.ts` | **60 秒固定** |
| `id_token_hint` で RP から戻ってきた ID Token を検証 | `verifyIdTokenHint` in `id-token.ts` | **60 秒固定** |
| JWT Access Token を Resource Server が検証 | リポジトリ範囲外（利用者責務） | — |
| DPoP（将来）`iat` 検証 | 未実装（`tasks/T-019-dpop.md`） | 仕様推奨は数秒〜数分 |

## 4. 参照資料

- RFC 7519 §4.1 — https://datatracker.ietf.org/doc/html/rfc7519#section-4.1 （iat / exp / nbf の定義）
- OpenID Connect Core 1.0 §3.1.3.7 — https://openid.net/specs/openid-connect-core-1_0.html#IDTokenValidation （`iat` の "too far in the past" 拒否は実装定義）
- RFC 8725 §3.8 / §3.11 — https://datatracker.ietf.org/doc/html/rfc8725 （JWT BCP、leeway は数分以内推奨）
- RFC 9068 §2.2.1 — https://datatracker.ietf.org/doc/html/rfc9068 （`iat`/`exp` 必須、`nbf` 任意）
- RFC 9449 §4.3 — https://datatracker.ietf.org/doc/html/rfc9449 （DPoP の `iat` 検証、数秒〜数十秒推奨）
- 本リポジトリ該当箇所: `packages/core/src/id-token.ts` の `validatePayload`（"60 second clock skew tolerance" コメント）と `verifyIdTokenHint`（`exp + clockSkewTolerance < now`）

## 5. 現在の実装確認

- `validatePayload` (id-token.ts, exp 検証): `payload.exp < now - 60` で拒否。`iat` は存在チェックのみで上下限の検証は無い。
- `verifyIdTokenHint` (id-token.ts): `exp + 60 < now` で拒否。`iat` の検証は無し（`id_token_hint` は `tasks/done/T-017-id-token-hint-validation.md` で対応済みだが leeway は固定）。
- `packages/core/src/access-token-issuer.ts`: JWT Access Token 発行時に `iat = now`, `exp = now + accessTokenExpiresIn`。`nbf` は未付与（`tasks/p3-jwt-access-token-nbf.md`）。検証ロジックは Resource Server 側責務のため未実装。
- `packages/core/src/token-response.ts`: ID Token 発行時に `iat = now`, `exp = now + idTokenExpiresIn`。`exp ≤ iat` の不整合チェックは無い（`idTokenExpiresIn > 0` は契約として呼び出し側責任）。
- `packages/core/src/discovery.ts`: Discovery JSON に Clock Skew ポリシーを広告するメタデータは無い（標準フィールドも存在しないので不要）。

## 6. 現在の実装との差分

満たしていること:

- ✅ `iat`/`exp` を ID Token / JWT Access Token に正しく付与
- ✅ `id_token_hint` の `exp` 検証で leeway を持たせている（厳格すぎる即時拒否を回避）

不足・確認が必要なこと:

- 🟡 **Clock Skew 許容秒数のハードコード**: 60 秒固定。デプロイ環境（NTP 同期状況、コンテナ環境のドリフト）で大きく変わる値であり、設定で上書き可能にすべき。利用者が「より厳格に」「より緩く」を選べないのは OSS としての柔軟性を欠く。
- 🟡 **`iat` 未来日付の検証が無い**: `id_token_hint` でリプレイ的に未来 `iat` を持つトークンを送られても、`exp` が現在より未来なら通過する。`iat` ≤ `now + leeway` の上限チェックを追加すべき（RFC 8725 §3.8 推奨）。
- 🟡 **発行時の整合性チェックが暗黙**: `idTokenExpiresIn` / `accessTokenExpiresIn` が 0 や負の値で渡されると `exp ≤ iat` の不整合トークンを発行しうる。境界値テスト不在。
- 🟡 **DPoP / Request Object 将来導入時の整合**: それぞれ `iat` を持つ JWT を OP が検証する側になるため、leeway 設定の置き場所を今のうちに決めておくと将来導入が楽。
- 🟢 **JWT Access Token の検証**: 設計上 Resource Server 側責務であり、本リポジトリで検証コードを持たない方針なら問題なし。ただし「推奨 leeway」を README / Discovery 補助ドキュメントで利用者に提示する余地はある。

## 7. 改善・追加を検討する理由

- Basic OP は時刻クレームの正確性に依拠するため、leeway 設定の柔軟性は相互運用性の中核。
- 「ハードコードされた 60 秒」は多くの環境で妥当だが、CI 環境やコンテナでの時刻ドリフトが大きい開発時に過剰拒否、本番で過大許容のリスクを生む。
- 利用者が DPoP / Request Object 拡張を入れた際に、leeway 設定を「都度バラバラに」追加すると保守性が落ちる。今のうちに **1 箇所の設定値**として束ねるか、関数引数として渡せるか、を決めておく価値が大きい。
- 実装しない場合のリスク: `iat` 上限欠落により、`id_token_hint` 経由のセッション固定（未来 `iat` での "永続化"）の隙間が残る。

## 8. 実装方針の候補

- 方針A（最小修正）: `validatePayload` / `verifyIdTokenHint` の 60 秒を共通定数に切り出し、オプション引数で上書きできるようにする。`iat` 上限チェック（`iat > now + leeway` 拒否）を追加。
- 方針B（設定統合）: `OpenIDProviderConfig` 的なオブジェクト（既存があれば利用、無ければ resolver の延長として）に `clockSkewToleranceSec` フィールドを追加し、ID Token 検証・`id_token_hint` 検証・将来の DPoP 検証で共有。
- 方針C（発行側の整合チェック）: `generateIdToken` / `generateAccessToken` 発行時に `expiresIn <= 0` を弾く asserts を入れる（防御的プログラミング、現状の契約違反検知）。
- 方針D（ドキュメント）: `study-material/token-lifetime-security-policy.md` または README に「推奨 leeway: 30–60 秒、最大でも 5 分以内」を明記し、Resource Server 側実装ガイドラインに引用できる形で残す。

最終的にどの方針を採るか（A だけでよいか、B まで作るか）は人間が判断する。

## 9. タスク案

- [ ] `validatePayload` と `verifyIdTokenHint` の `clockSkewTolerance = 60` を共通定数化、オプション引数で上書き可能にする
- [ ] `id_token_hint` 検証で `iat > now + leeway` を拒否（未来 `iat` リプレイ防止）
- [ ] ID Token / JWT Access Token 発行時に `expiresIn <= 0` を弾く境界値テスト追加
- [ ] 設定オブジェクト（あれば）に `clockSkewToleranceSec` を集約することの是非を decision として記録
- [ ] README または `study-material/token-lifetime-security-policy.md` に「推奨 leeway 値」を追記
- [ ] DPoP 拡張タスク `tasks/T-019-dpop.md` のレビューポイントに「`iat` leeway は本ファイル方針と整合させる」を追記
