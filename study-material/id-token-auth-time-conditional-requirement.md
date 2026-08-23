# ID Token `auth_time` クレームの条件付き必須要件と core API 契約

## 1. タイトル

ID Token の `auth_time` クレームが OIDC Core 1.0 上で「条件付き REQUIRED」となるケース（`max_age` 指定時 / `auth_time` を essential claim として要求された時）を、core (`generateTokenResponse`) が API 契約としてどう扱っているかの確認と、堅牢性向上の検討。

## 2. このトピックで確認したいこと

- OIDC Core 1.0 §2 が定める「`max_age` リクエストがあった場合、または `auth_time` が Essential Claim として要求された場合、`auth_time` は REQUIRED」という条件付き必須要件を、core API として満たせる構造になっているか
- `generateTokenResponse` は `authTime` を **任意 (`authTime?: number`)** として受け取り、`max_age` の有無も `claims.id_token.auth_time` の essential 指定も認識しない。そのため「条件を満たすのに `auth_time` が欠落した ID Token」を core が黙って生成しうるか
- CLI 生成コード（`packages/cli/src/frameworks/hono/templates.ts`）は実際には常に `authTime` を渡しているため、生成済みフローでは実害が出にくい。しかし CLAUDE.md が定義する「`core` は高度な組み込みユースケース向けロジック層」という位置づけにおいて、core を直接呼ぶ利用者がこの暗黙の前提を破ると非準拠の ID Token を生成しうる。この**契約の暗黙性**が問題ないかを確認したい
- 既存ファイル／タスクとの関係:
  - `tasks/done/04-max-age-enforcement.md` … `max_age` の**リクエスト側**（再認証強制）ロジックと「ID Token に `auth_time` が含まれることを確認する」受け入れ条件はあるが、**core API 境界での強制／検証**は対象外。本ファイルはその差分を扱う
  - `study-material/done/jwt-clock-skew-and-time-tolerance.md` … 時刻クレームの許容差。`auth_time` の*存在条件*とは別論点
  - `study-material/resolver-and-store-contract.md` … session の `authTime` 保持はそちらの契約。本ファイルは「保持された値を ID Token に出す条件」に絞る
  - 仕様共通索引は `study-material/basic-op-requirements-baseline.md` を参照

## 3. 関連する仕様・基準

共通の Basic OP 仕様索引は `study-material/basic-op-requirements-baseline.md` を参照。本トピック固有の差分のみ記載する。

### 3.1 OIDC Core 1.0 §2（ID Token / `auth_time` の定義）

> `auth_time`: Time when the End-User authentication occurred. ... When a `max_age` request is made or when `auth_time` is requested as an Essential Claim, then this Claim is REQUIRED; otherwise, its inclusion is OPTIONAL.

- すなわち `auth_time` は **デフォルトでは OPTIONAL**。常に含めても準拠違反ではない（過剰包含は許容される）。
- 「`max_age` がリクエストにある」または「`claims` パラメータで `auth_time` が `essential:true` で要求された」場合のみ **REQUIRED** に昇格する。

### 3.2 OIDC Core 1.0 §3.1.2.1（Authentication Request — `max_age`）

> `max_age`: ... If this is requested, the End-User MUST be actively authenticated ... and the `auth_time` Claim in the issued ID Token Value MUST be present and represent the time at which the user was authenticated.

- `max_age` 指定時、ID Token への `auth_time` 包含は **MUST**。

### 3.3 OIDC Core 1.0 §5.5.1（Individual Claims Requests）

- `claims` パラメータの `id_token` メンバに `{"auth_time": {"essential": true}}` が含まれる場合、`auth_time` の包含が REQUIRED になる。
- 本リポジトリは `claims` パラメータの `id_token` メンバ解釈に対応済み（`tasks/done/p0-claims-id-token-support.md`）。ただし現状その解釈結果は `acr` の resolver フォールバック値抽出にのみ使われ（`token-response.ts`）、`auth_time` の essential 判定には使われていない。

### 3.4 OpenID Connect Conformance（Basic OP）での扱い

- Basic OP の Conformance テストには `max_age` を指定して `auth_time` の存在・妥当性を検証するケースが含まれる。`max_age=0` の即時再認証ケースも含む。
- したがって「`max_age` → `auth_time` 必須」は Conformance 観点でも実証が必要な要件であり、本リポジトリの検証計画（`study-material/basic-op-conformance-verification-plan.md`）と連動する。

## 4. 参照資料

- OpenID Connect Core 1.0 §2 — ID Token（`auth_time` の定義と条件付き REQUIRED 記述）
  https://openid.net/specs/openid-connect-core-1_0.html#IDToken
- OpenID Connect Core 1.0 §3.1.2.1 — Authentication Request（`max_age` 指定時に `auth_time` MUST present）
  https://openid.net/specs/openid-connect-core-1_0.html#AuthRequest
- OpenID Connect Core 1.0 §5.5.1 — Individual Claims Requests（`essential` claim）
  https://openid.net/specs/openid-connect-core-1_0.html#IndividualClaimsRequests
- OpenID Connect Conformance Profiles v3.0 — Basic OP（`max_age` / `auth_time` テスト）
  https://openid.net/wordpress-content/uploads/2020/09/OpenID-Connect-Conformance-Profiles.pdf

## 5. 現在の実装確認

### 5.1 core 層

- `packages/core/src/token-response.ts`
  - `TokenResponseOptions.authTime?: number`（L57）… **任意**パラメータ。`max_age` も `claims` の essential 判定も入力に取らない。
  - L320-322:
    ```ts
    if (authTime !== undefined) {
      idTokenPayload.auth_time = authTime;
    }
    ```
    → `authTime` が渡されたときのみ包含。渡されなければ無言で省略する。
  - `claims?: ClaimsParameter`（L116）は受け取るが、用途は `claims.id_token.acr.values` の acr resolver フォールバックのみ（L110-116, acr 解決ロジック）。`auth_time` の essential 判定には未使用。
- `packages/core/src/id-token.ts`
  - `IdTokenPayload.auth_time?: number`（L21 付近）… 任意。
- `packages/core/src/authorization-request.ts`
  - `ValidatedAuthorizationRequest.maxAge`（解析済み）、`claims`（解析済み）。

### 5.2 CLI 生成コード / sample（呼び出し側）

- `packages/cli/src/frameworks/hono/templates.ts`
  - authorization_code 経路: `authCode.authTime` を必須として取り出し（L1024 で欠落時はエラー）、`authTime` を `generateTokenResponse` に渡す（L1031, L1084）。
  - refresh_token 経路: §12.1 に従い初回 `authTime` を保持して渡す（L1035-1038, L1122-1128）。`authTime` が無ければ refresh token 発行を中断（L1128）。
  - session 生成時に `authTime: Math.floor(Date.now() / 1000)` を設定（L1604）。
- 結果として、**生成済みフローでは `auth_time` が常に ID Token に含まれる**（`max_age` の有無に関わらず）。これは過剰包含であり OIDC 上は準拠（OPTIONAL の常時包含）。

## 6. 現在の実装との差分

| 観点 | 状態 |
|---|---|
| `max_age` 指定時に `auth_time` を含める（生成済みフロー） | ✅ 満たしている（template が常に `authTime` を渡す） |
| `auth_time` を常時包含することの仕様適合 | ✅ §2 上 OPTIONAL の常時包含は許容 |
| core API が条件付き必須要件を**認識・強制**する | ❌ 未対応。`generateTokenResponse` は `max_age` / essential を入力に取らず、`authTime` 欠落を検出しない |
| `claims.id_token.auth_time.essential` の解釈 | ❌ 未対応（`acr` のみ解釈） |
| core を直接利用する高度ユースケースでの堅牢性 | ⚠️ `authTime` を渡し忘れると `max_age` 指定下でも非準拠 ID Token を無言生成しうる。契約が暗黙 |
| Conformance 観点での実証 | ⚠️ 生成済みフローは通る見込みだが、core 単体テストに「`max_age` 相当の条件で `auth_time` 必須」を固定する回帰テストが無い |

要約: **実害は小さい**（CLI 生成コードが常に `authTime` を渡すため）。論点は「core をライブラリとして直接叩く利用者に対し、条件付き必須要件が暗黙の前提として委ねられている」という**契約の明示性・堅牢性**である。

## 7. 改善・追加を検討する理由

- **なぜ価値があるか**: CLAUDE.md は `core` を「高度な組み込みユースケース向けロジック層」と位置づける。core を直接呼ぶ利用者がこの暗黙契約を破ると、`max_age` を要求した RP に対し `auth_time` 欠落の非準拠 ID Token を返してしまう。Fidelity（Conformance 準拠）を差別化軸に掲げる以上、API 境界での guard / 契約明示は価値がある。
- **Basic OP として必須か / 拡張か**: 要件そのもの（`max_age`→`auth_time`）は **Basic OP 必須**。ただし生成済みフローでは既に満たしているため、本トピックは「core API の堅牢性・契約明示」という**品質改善**寄り（必須機能の欠落ではない）。
- **導入しやすさ**: `generateTokenResponse` は既に `claims` と（呼び出し側経由で）`maxAge` 相当の情報に近接している。任意の guard を足すのは局所的変更で済む。一方で「core が throw すべきか / 黙って許容すべきか」は API 設計判断であり、後方互換に影響しうる。
- **既存実装との接続**: `authorization-request.ts` の `maxAge` / `claims` 解析結果を token endpoint まで運ぶ動線は既にある（auth-transaction → token-request）。essential 判定を足すなら `claims` パーサ（`parseClaimsRequest`）の結果を再利用できる。
- **メリット**: core 直叩き利用者が「`max_age` を扱うなら `authTime` 必須」を型・実行時 guard・ドキュメントのいずれかで早期に気付ける。
- **実装しない場合のリスク**: core 利用者が `authTime` を渡し忘れた場合に Conformance 非準拠 ID Token を黙って生成し、原因究明が困難になる（無言の省略のため）。

## 8. 実装方針の候補（最終判断は人間）

判断材料の整理に留める。AI 側で確定しない。

- **方針 A: ドキュメント契約のみ**
  - `TokenResponseOptions.authTime` の JSDoc に「`max_age` 指定時 / `auth_time` essential 要求時は呼び出し側で必ず渡すこと」を明記。
  - 長所: 後方互換完全維持、最小コスト。短所: 実行時 guard 無し（気付けない）。

- **方針 B: 任意の検証フラグ／コンテキストを追加**
  - `generateTokenResponse` に `maxAgeRequested?: boolean`（または `authTimeRequired?: boolean`）を追加し、`true` かつ `authTime` 未指定なら例外を投げる。
  - `claims.id_token.auth_time.essential` を core が解釈して `authTimeRequired` を内部導出する案も併用可。
  - 長所: 条件付き必須を core が強制（fail-closed）。短所: 新 API 面、利用者が新フラグを渡さなければ従来通り（guard が効かない）。

- **方針 C: CLI 生成テンプレート側の回帰テスト強化のみ**
  - core は変えず、生成済みフロー（または sample 統合テスト）で「`max_age` 指定時に発行 ID Token に `auth_time` が存在し妥当」を固定する回帰テストを追加。
  - 長所: Conformance 観点を実証として固定、低リスク。短所: core 直叩き利用者は依然 guard なし。

- 方針の組み合わせ（A + C を先行、B は API 設計合意後）も検討余地あり。**方針 B は後方互換と API 面の設計判断が必要なため、現時点では「検討段階」**。

## 9. タスク案

> 注: 本トピックは方針 B（core API への guard 追加）に API 設計判断が残るため、現時点では明確なタスクとして切り出さず study-material に留める。下記は方針合意後に着手しやすいよう粒度を整理したもの。

- [ ] **（A）契約明示**: `TokenResponseOptions.authTime` の JSDoc に「`max_age` 指定時・`auth_time` essential 要求時は呼び出し側が必ず渡す MUST」「core は欠落を検出しない」を追記する。
- [ ] **（C）回帰テスト**: sample または CLI 生成フローの統合テストに「`max_age` を含む認可リクエスト → トークン交換で発行された ID Token に `auth_time` が存在し、`exp`/`iat` と矛盾しない」ケースを追加する。`max_age=0` の即時再認証ケースも含める。
- [ ] **（B・要合意）core guard**: API 設計合意後、`generateTokenResponse` に `authTimeRequired`（または `maxAgeRequested`）入力を足し、`true` かつ `authTime` 未指定で例外を投げる実装と単体テストを追加するか検討する。あわせて `claims.id_token.auth_time.essential` を core が解釈して内部導出するかも検討する。
- [ ] **調査**: OIDF Conformance Suite の Basic OP プロファイルにおける `max_age` / `auth_time` 関連テストケース ID を `study-material/basic-op-conformance-verification-plan.md` に追記し、本トピックの検証範囲を確定する。
