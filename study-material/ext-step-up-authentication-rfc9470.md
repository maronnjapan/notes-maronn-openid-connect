# 拡張: OAuth 2.0 Step-up Authentication Challenge Protocol（RFC 9470）

## ステータス

🟢 拡張機能 / 未着手

## 1. このトピックで確認したいこと

リソースサーバ（API）が「現在のアクセストークンでは認証強度が不足。再認証して `acr` を上げて来てほしい」と RP に要求するための標準化プロトコル（RFC 9470 / 2023 年公開）。本リポジトリの実装可否と、入れる場合の最小スコープを確認する。

このプロトコルは:

- **リソースサーバ → クライアント**: `WWW-Authenticate: Bearer error="insufficient_user_authentication"` + `acr_values` / `max_age` 等のチャレンジパラメータで要求
- **クライアント → OP**: 既存の `acr_values` / `max_age` / `prompt=login` パラメータを使って再認証フローを起動
- **OP → クライアント**: 強化された `acr` / 新しい `auth_time` を含む ID Token を発行

OP 側で必要な作業は意外と少なく、本リポジトリは **既存資産（`acr_values`・`max_age`・`AcrResolver`・`prompt=login`）でほぼ実装済み**。本トピックは「Step-up に対応している」と謳う上で残るギャップ（特にチャレンジ応答側ヘッダ）と、利用者向けにどの程度サポートするかを整理する。

## 2. 関連する仕様・基準

共通の `acr` / `amr` / `max_age` / `prompt=login` 仕様説明は重複させない。既存ファイルを参照のこと:

- `acr` / `amr` 注入機構: `tasks/done/oidc-improvements-2026-05.md` T-015
- `max_age` 強制と `auth_time`: `tasks/done/04-max-age-enforcement.md`
- `prompt=login` 強制再認証: `tasks/done/03-prompt-login.md`
- RFC 8176 `amr` 値ガイド: `study-material/amr-values-guidance-rfc8176.md`

本トピック固有のポイント:

### 2.1 RFC 9470 — リソースサーバ側のチャレンジ

リソースサーバが Bearer Token を受け取ったが認証強度不足と判断した場合、

```
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer error="insufficient_user_authentication",
    error_description="A different authentication level is required",
    acr_values="urn:mace:incommon:iap:silver",
    max_age="0"
```

を返す。`acr_values` / `max_age` はオプションで、両方含めることも可能。

### 2.2 クライアント側の挙動

クライアントは `WWW-Authenticate` から `acr_values` / `max_age` を読み、新しい認可リクエストを OP に送る:

```
GET /authorize?
  response_type=code
  &client_id=...
  &acr_values=urn:mace:incommon:iap:silver
  &max_age=0
  ...
```

OP は既存パラメータ（`acr_values` / `max_age`）を使って再認証を実行し、要求された `acr` を満たした ID Token を発行する。

### 2.3 OP 側に要求される挙動（実質的に既存実装でカバー）

| 仕様要件 | 現在の実装状態 |
|---|---|
| `acr_values` を受理 | ✅ 受理して `AcrResolver` に渡す（T-015） |
| `max_age` を強制 | ✅ `requiresReauthentication` で再認証判定（T-004 done） |
| `prompt=login` を強制 | ✅ 認証セッションを破棄して再ログイン（done 03） |
| ID Token に `acr` / `auth_time` を含める | ✅ `acrResolver` の戻り値・`authTime` を含める |
| 要求された `acr_values` を満たせない場合のエラー | 🟡 `AcrResolver` の戻り値次第。明示的なポリシーは無い |
| 要求された `acr_values` を満たさない場合 `acr_values` のいずれかは満たしたいが満たせない場合の挙動 | 🟡 未規定 |

### 2.4 リソースサーバ向けの WWW-Authenticate 補助

本リポジトリは OP / Authorization Server の実装が主体だが、リソースサーバ（API）も同じプロジェクトに混在する PoC ユースケースが多い。OP 側ライブラリで RFC 9470 風 WWW-Authenticate を組み立てるヘルパー（純関数）を提供すると、PoC 利用者が両側を 1 ライブラリで検証できる。

```ts
// 仮の API（提案）
buildStepUpChallenge({ acrValues: 'urn:mace:incommon:iap:silver', maxAge: 0 })
// => 'Bearer error="insufficient_user_authentication", acr_values="urn:mace:incommon:iap:silver", max_age="0"'
```

## 3. 参照資料

- RFC 9470 OAuth 2.0 Step Up Authentication Challenge Protocol — https://www.rfc-editor.org/rfc/rfc9470
  - §3（Authentication Required Response — Resource Server側）
  - §4（Required Acr Values）
- OIDC Core 1.0 §3.1.2.1 — `acr_values` / `max_age` / `prompt` の OP 側仕様
- IANA OAuth Error Registry — `insufficient_user_authentication`

## 4. 現在の実装確認

- `acr_values` 受理: `packages/core/src/authorization-request.ts`（パラメータ受理・`ValidatedAuthorizationRequest.acrValues`）
- `AcrResolver` で `acr` / `amr` を決定: `packages/core/src/token-response.ts`（T-015）
- `max_age` 強制: `packages/core/src/auth-transaction.ts` `requiresReauthentication`、`packages/sample/src/oidc-provider/routes/authorize.ts`
- `prompt=login` 処理: `packages/sample/src/oidc-provider/routes/login.ts`
- ID Token への `acr` / `auth_time` 反映: `packages/core/src/token-response.ts`
- `AcrResolver` が「要求された acr を満たせない」場合のエラー型は無し
- リソースサーバ向け WWW-Authenticate ヘルパーは無し（UserInfo の Bearer challenge は `userinfo.ts` にあるが、Step-up 用途のチャレンジは別物）

## 5. 現在の実装との差分

満たしていること:

- Step-up の OP 側挙動（`acr_values` / `max_age` / `prompt=login` 受理 → 再認証 → ID Token に `acr` 反映）は既存資産で実質完成。
- 「Step-up に対応している」と謳うために必要な OP 側の仕様要件は OIDC Core ベースで揃っている。

不足／要確認:

- 🟡 **`AcrResolver` が「要求された acr を満たせない」場合の標準的なエラーパス**: 現在は `undefined` を返すと `acr` クレームが ID Token から落ちるだけ。要求された acr を満たせない場合に明示的にフローを止める経路が無い。
  → **本論点は OIDC Core §5.5.1.1 の MUST（Essential な `acr` 要求を満たせない場合は認証失敗として扱う）そのものであり、RFC 9470 とは独立した Core 準拠の論点として `study-material/done/claims-essential-acr-unmet-authentication-failure.md` に分離した。** 最小実装（黙って発行しない）は `tasks/p1-essential-acr-claim-unmet-issuance-guard.md`、認可エンドポイントでの `unmet_authentication_requirements` 返却と追加認証要求は同 study-material の方針 B / C として検討中。なお `unmet_authentication_requirements` は §3.1.2.6 の列挙には含まれず、別仕様（OpenID Connect Core Error Code `unmet_authentication_requirements` 1.0）が定義し IANA に登録されたコードである。
- 🟡 **リソースサーバ向け WWW-Authenticate ヘルパーが無い**: Step-up を「OP + RS 一式で検証したい」PoC ユーザーは自前で WWW-Authenticate を組み立てる必要がある。
- 🟡 **Discovery の `acr_values_supported`** が広告されていない: クライアントが「この OP に Step-up を要求できる acr_values 候補」を見られない。本論点は `study-material/discovery-optional-metadata-fields.md` 側と連動。
- 🟡 **`max_age=0` のエッジケース**: 0 は「常に再認証要求」を意味するが、`requiresReauthentication(0, authTime)` が正しく true を返すかは要テスト。
- 🟢 **ドキュメント**: 「Step-up Authentication をこのライブラリでどう実現するか」の利用例が無い。

セキュリティ観点:

- Step-up はセキュリティ向上の機能（リソース毎に要求認証レベルを変えられる）。実装しても侵害リスクは増えない。
- `acr_values` の信頼境界に注意: クライアントが送る `acr_values` は要求値であり、OP は実認証で達成された `acr` を返すべき（成りすまし禁止）。本実装は `AcrResolver` が実認証ベースで決めるため正しい。

## 6. 改善・追加を検討する理由

価値:

- 「Speed（最新仕様最速）」軸を体現する分かりやすい機能。Step-up はモダンな API 設計（FAPI、銀行API、医療API）でほぼ必須化しつつある。
- 本リポジトリは OP 側仕様要件のほとんどを既に満たしており、**ドキュメント整備＋小さなヘルパー追加**で「Step-up 対応」を主張できる。
- PoC ユーザーが「お金関連 API では追加認証を要求したい」というユースケースを検証できる。

導入難易度:

- 🟢 **低**: 主要な仕様準拠は既存実装でカバー済み。新規追加は
  1. リソースサーバ向け `buildStepUpChallenge` ヘルパー
  2. `AcrResolver` が「要求 acr を満たせない」シグナルを返せる型拡張
  3. Discovery の `acr_values_supported` 広告
  4. ドキュメント / sample

実装しない場合のリスク:

- 「OAuth 2.1 / 最新仕様」を謳う上で、Step-up 非対応は古めかしさのシグナルになる。
- PoC ユーザーが Step-up を試したい場合に他ライブラリへ移行する。

## 7. 実装方針の候補

### 方針A（最小実装 / 既存資産の明文化）: ドキュメントのみ

- README / CLAUDE.md に「Step-up Authentication は `acr_values` + `max_age` + `prompt=login` で実現可能」と明記
- sample に Step-up シナリオの参考実装（コメント・スニペット）を追加
- core 変更なし

### 方針B（A + ヘルパー追加 / 推奨）

- `packages/core/src/access-token.ts` または新規モジュールに `buildStepUpChallenge` を追加:

  ```typescript
  export function buildStepUpChallenge(options: {
    acrValues?: string;
    maxAge?: number;
    errorDescription?: string;
  }): string;
  ```

- 純関数として実装、副作用なし
- `AcrResolver` の戻り値型に「要求 `acr_values` を満たせない」を表す `'unmet_authentication_requirements'` シグナルを追加（オプション、既存利用者には後方互換）

### 方針C（B + Discovery 広告）

- B に加えて、`ProviderMetadataConfig` の `acr_values_supported` フィールドを使って Step-up 可能な acr 候補を広告（`discovery-optional-metadata-fields.md` と連動）

### 方針D（フルスコープ）

- C に加え、UserInfo endpoint で「要求 `acr_values` を満たさないアクセストークン」を弾く検証ヘルパーを提供（RFC 9470 §4）

判断材料:

- 方針 D は OP の責務を超えがち（RS 側の判断）。
- 方針 B が最も費用対効果が高い: ヘルパー 1 つで「Step-up に対応している」と謳える状態になる。
- Discovery 広告（C）は他のトピックと一緒に進めると効率的。

## 8. タスク案

- [ ] 方針 A / B / C / D を選択（人間が判断）
- [ ] （方針 B 採用時）TDD で `buildStepUpChallenge` のテストを先に追加:
  - `acr_values` のみ → ヘッダ文字列の組み立て
  - `max_age` のみ → 同上
  - 両方指定 → 同上
  - `error_description` の `sanitizeErrorDescription` 経由
- [ ] `buildStepUpChallenge` 実装（純関数）
- [ ] `AcrResolver` 戻り値に `'unmet_authentication_requirements'` シグナルを追加するかの設計検討（既存呼び出し側に影響）
- [ ] `max_age=0` のエッジケーステスト追加（`auth-transaction.test.ts`）
- [ ] sample / CLI テンプレートに Step-up リソースサーバ参考実装を追加（コメント or 別ファイル）
- [ ] `study-material/basic-op-requirement-traceability.md` の関連行に Step-up 対応状況を反映
