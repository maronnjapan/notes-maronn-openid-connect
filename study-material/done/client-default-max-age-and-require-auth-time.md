# クライアント登録メタデータ `default_max_age` / `require_auth_time` の honoring

## 1. タイトル

クライアントが登録できる `default_max_age`（既定の最大認証経過時間）と `require_auth_time`（ID Token への `auth_time` 包含を必須化するフラグ）を、OP が認可リクエスト処理・ID Token 生成で honoring できているかの確認と改善検討。

## 2. このトピックで確認したいこと

- OIDC が定義するクライアント登録メタデータ `default_max_age` / `require_auth_time` を、本リポジトリの `ClientInfo` / 認可リクエスト処理 / ID Token 生成が認識・適用できているか。
- 認可リクエストに `max_age` が**無い**場合に、クライアントが登録した `default_max_age` を再認証強制の既定値としてフォールバック適用できているか。
- `require_auth_time=true` を登録したクライアントに対し、`max_age` の有無に関わらず ID Token へ `auth_time` を必ず含める契約になっているか。
- 既存ファイル／タスクとの関係（重複回避）:
  - `study-material/id-token-auth-time-conditional-requirement.md` … **リクエストパラメータ `max_age`** 指定時 / `claims` の essential 指定時の `auth_time` 条件付き必須を扱う。本ファイルはその**クライアント登録メタデータ側の入口**（`default_max_age` / `require_auth_time`）という別ディメンションの差分に絞る。`auth_time` の §2 定義など共通仕様の再説明はしない。
  - `tasks/done/04-max-age-enforcement.md` … リクエスト `max_age` の再認証強制ロジック。`default_max_age` フォールバックは対象外。
  - `study-material/done/client-metadata-enforcement.md` … `grant_types` / `response_types` / `token_endpoint_auth_method` の強制。認証経過時間系メタデータ（`default_max_age` / `require_auth_time`）は未扱い。
  - `study-material/ext-step-up-authentication-rfc9470.md` … `acr_values` ベースの step-up。`max_age` ベースの認証鮮度とは別軸。

## 3. 関連する仕様・基準

共通の Basic OP 仕様索引は `study-material/basic-op-requirements-baseline.md` を、`auth_time` の条件付き必須の基礎は `study-material/id-token-auth-time-conditional-requirement.md` を参照。本トピック固有の差分のみ記載する。

### 3.1 OpenID Connect Dynamic Client Registration 1.0 §2（Client Metadata）

- **`default_max_age`**:
  > Default Maximum Authentication Age. Specifies that the End-User MUST be actively authenticated if the End-User was authenticated longer ago than the specified number of seconds. The `max_age` request parameter overrides this default value. If omitted, no default Maximum Authentication Age is specified.
  - すなわち、リクエストに `max_age` が無くてもクライアント登録に `default_max_age` があれば、それが再認証強制の既定値になる。`max_age` が来た場合はそちらが優先（上書き）。
- **`require_auth_time`**:
  > Boolean value specifying whether the `auth_time` Claim in the ID Token is REQUIRED. It is REQUIRED when the value is `true`. ... If omitted, the default value is `false`.
  - `true` のクライアントには、`max_age` の有無に関わらず ID Token に `auth_time` を **必ず**含めなければならない。

### 3.2 OIDC Core 1.0 §3.1.2.1（max_age と default_max_age の関係）

- `max_age` リクエストパラメータは `default_max_age` を上書きする。どちらかが有効な場合、End-User はその秒数より前にしか認証されていなければ能動的再認証を要求され、発行 ID Token の `auth_time` は MUST present。

### 3.3 Basic OP / Conformance での位置づけ

- `default_max_age` / `require_auth_time` 自体は **Dynamic Client Registration のメタデータ**であり、DCR を実装していない本リポジトリでは「静的クライアント設定として表現・適用できるか」という観点になる。
- Basic OP Conformance の中核テストはリクエスト `max_age` 起点（`study-material/id-token-auth-time-conditional-requirement.md` §3.4 参照）。`default_max_age` / `require_auth_time` は**必須テスト項目ではない**が、これらを登録した RP との相互運用（Fidelity）に効く。

## 4. 参照資料

- OpenID Connect Dynamic Client Registration 1.0 §2 — Client Metadata（`default_max_age` / `require_auth_time` の定義）
  https://openid.net/specs/openid-connect-registration-1_0.html#ClientMetadata
- OpenID Connect Core 1.0 §3.1.2.1 — Authentication Request（`max_age` が `default_max_age` を上書き、`auth_time` MUST present）
  https://openid.net/specs/openid-connect-core-1_0.html#AuthRequest
- OpenID Connect Core 1.0 §2 — ID Token（`auth_time` の条件付き REQUIRED。詳細は既存ファイルを参照）
  https://openid.net/specs/openid-connect-core-1_0.html#IDToken

## 5. 現在の実装確認

- `packages/core/src/authorization-request.ts`
  - `ClientInfo`（L70-81）… フィールドは `clientId` / `redirectUris` / `clientType` / `responseTypes` のみ。**`defaultMaxAge` / `requireAuthTime` 相当のフィールドが無い**。
  - `max_age` は `validateMaxAge`（L375 付近）でリクエストパラメータからのみ解析され、`ValidatedAuthorizationRequest.maxAge`（L164）に格納される（L604-608, L643）。**リクエストに `max_age` が無い場合に `client.defaultMaxAge` へフォールバックする経路が無い**。
- `packages/core/src/token-response.ts` / `id-token.ts`
  - ID Token への `auth_time` 包含は `authTime` が渡されたときのみ（既存ファイル §5.1 参照）。`require_auth_time` を入力に取らない。
- `packages/sample/src/oidc-provider/config.ts`
  - `RegisteredClient`（`ClientInfo & TokenClientInfo & { offlineAccessAllowed?, userinfoSignedResponseAlg?, idTokenSignedResponseAlg? }`）にも `defaultMaxAge` / `requireAuthTime` は無い。
- grep 結果: `default_max_age` / `require_auth_time` / `defaultMaxAge` / `requireAuthTime` は **コード・study-material・tasks のいずれにも存在しない**（完全未対応）。

## 6. 現在の実装との差分

| 観点 | 状態 |
|---|---|
| リクエスト `max_age` 起点の再認証強制 | ✅ 対応済み（`tasks/done/04-max-age-enforcement.md`） |
| `max_age` 指定時に ID Token へ `auth_time` を含める（生成済みフロー） | ✅ 対応済み（生成テンプレートが常時 `authTime` を渡す） |
| `default_max_age`（クライアント登録）を `max_age` 不在時のフォールバックに適用 | ❌ 未対応。`ClientInfo` に項目が無く、フォールバック経路も無い |
| `require_auth_time=true` を honoring して `auth_time` を必須化 | ⚠️ 生成済みフローは常時 `auth_time` を含むため**結果的には満たす**が、メタデータとしての表現・強制・契約が無い |
| 静的クライアント設定でこれらを表現する手段 | ❌ 型に無いため利用者が設定できない |
| Conformance / 相互運用 | ⚠️ これらを登録する RP に対し、`default_max_age` を無視すると「再認証されるはず」の前提が崩れる |

要約: **`require_auth_time` は生成済みフローでは実質満たしている**（過剰包含が許容されるため）が、**`default_max_age` の再認証フォールバックは挙動として欠落**している。後者が本トピックの主要論点。

## 7. 改善・追加を検討する理由

- **なぜ価値があるか**: `default_max_age` を登録した RP は「リクエストに毎回 `max_age` を付けなくても、OP 側で認証鮮度を担保してくれる」ことを期待する。これを無視すると、古いセッションのまま ID Token が発行され、RP のセキュリティ前提（最大認証経過時間）が破られる。
- **Basic OP 必須か / 拡張か**: メタデータ自体は DCR 由来で **Basic OP の必須テスト項目ではない**。本トピックは「相互運用性 + セキュリティ（認証鮮度）」の品質改善であり、必須機能の欠落ではない。
- **導入しやすさ**: `ClientInfo` への任意フィールド追加と、`validateAuthorizationRequest` 内の「`max_age` 不在時に `client.defaultMaxAge` を採用」する局所分岐で実現でき、後方互換を壊さない（未設定なら従来通り）。`require_auth_time` は ID Token 生成側に「真なら `authTime` 必須」の guard を足すだけ（既存の auth_time 動線を再利用）。
- **既存実装との接続**: `max_age` の解析・再認証強制ロジック（`validateMaxAge` / 04-max-age-enforcement）に `default_max_age` フォールバックを差し込むのが自然。`require_auth_time` は `study-material/id-token-auth-time-conditional-requirement.md` 方針 B（core guard）と同じ強制点を共有できる。
- **メリット**: RP が `default_max_age` で認証鮮度ポリシーを宣言でき、OP がそれを一貫適用する。利用者は静的クライアント設定で表現できる。
- **実装しない場合のリスク**: `default_max_age` を宣言した RP に対し OP が再認証を行わず、RP の想定より古い認証で ID Token が出る。原因が「OP がメタデータを無視している」ことに気付きにくい。

## 8. 実装方針の候補（最終判断は人間）

判断材料の整理に留める。

- **方針 A: `ClientInfo` に任意フィールド追加 + フォールバック適用**
  - `ClientInfo` に `defaultMaxAge?: number` / `requireAuthTime?: boolean` を追加。
  - `validateAuthorizationRequest` で「リクエスト `max_age` が undefined かつ `client.defaultMaxAge` が定義済みなら、`maxAge = client.defaultMaxAge` を採用」。`max_age` 明示時はそちらを優先（仕様の上書き規則）。
  - 長所: 仕様の上書き規則に忠実、後方互換維持。短所: 再認証強制は呼び出し側のセッション照合に依存するため、効果は既存 `max_age` 動線の完成度に従う。
- **方針 B: `require_auth_time` を ID Token 生成の guard に接続**
  - `study-material/id-token-auth-time-conditional-requirement.md` 方針 B と統合し、`requireAuthTime===true` かつ `authTime` 未指定なら例外を投げる。
  - 長所: 条件付き必須を fail-closed で強制。短所: API 面追加・後方互換の設計判断が必要（既存ファイルでも「要合意」扱い）。
- **方針 C: ドキュメント + 回帰テストのみ先行**
  - `default_max_age` フォールバックの単体テスト（`max_age` 不在 + `defaultMaxAge` 設定 → `maxAge` が採用される）と、`require_auth_time` の過剰包含が崩れないことの回帰テストを追加し、実装は方針 A を最小で入れる。
- 推奨の出発点は **方針 A（`default_max_age` フォールバック）+ 回帰テスト**。`require_auth_time` の core guard（方針 B）は既存 auth_time ファイルの API 設計合意とセットで進めるのが整合的。

## 9. タスク案

- [ ] **（A）型拡張**: `ClientInfo` に `defaultMaxAge?: number`（非負整数）/ `requireAuthTime?: boolean` を追加し、JSDoc に DCR §2 由来であること・既定の挙動を明記する。
- [ ] **（A）フォールバック適用**: `validateAuthorizationRequest` で、リクエスト `max_age` が無く `client.defaultMaxAge` がある場合に `maxAge` として採用する分岐を追加する。`max_age` 明示時の上書き優先も保持する。
- [ ] **（A）単体テスト**: 「`max_age` 不在 + `defaultMaxAge=600` → `validated.maxAge===600`」「`max_age` 明示 + `defaultMaxAge` 両方あり → リクエスト値優先」「両方不在 → `maxAge` undefined」を固定する。
- [ ] **（B・要合意）`require_auth_time` guard**: 既存 `study-material/id-token-auth-time-conditional-requirement.md` 方針 B と統合し、`requireAuthTime===true` で `authTime` 未指定なら ID Token 生成を fail-closed にする実装・テストを検討する（API 設計合意後）。
- [ ] **CLI/sample**: `RegisteredClient` に同フィールドを通し、`default_max_age` を設定した例を 1 つ用意して挙動確認する（生成テンプレート修正は CLAUDE.md の方針に従い `packages/cli` 側で行う）。
