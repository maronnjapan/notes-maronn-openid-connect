# Discovery メタデータ：相互運用性・透明性向上のためのオプションフィールド

## ステータス

🟡 Minor / 未着手

## 1. このトピックで確認したいこと

OpenID Connect Discovery 1.0 §3 / RFC 8414 §2 が定義する **オプションフィールド**のうち、

- 既存タスク T-021（`grant_types_supported` / `token_endpoint_auth_methods_supported` / `claims_parameter_supported` / `request_parameter_supported` / `request_uri_parameter_supported` / `scopes_supported` / `claims_supported`）
- 既存ファイル `study-material/discovery-code-challenge-methods-supported.md`（`code_challenge_methods_supported`）

で扱われていない、かつ追加するとクライアント側の自動構成・ユーザーへの開示（ToS / Policy）・国際化が改善されるフィールドの導入可否を整理する。

具体的には以下:

- `ui_locales_supported`：OP のログイン UI が対応するロケール一覧
- `claims_locales_supported`：UserInfo / ID Token のクレーム文字列のロケール一覧
- `acr_values_supported`：OP がサポートする `acr_values`
- `display_values_supported`：`display` パラメータでサポートする値（`page`, `popup`, `touch`, `wap`）
- `op_policy_uri` / `op_tos_uri`：OP のプライバシーポリシー / 利用規約 URL
- `service_documentation`：OP の開発者向けドキュメント URL
- `request_object_signing_alg_values_supported` 等の JAR 関連：`study-material/ext-jar-request-object-rfc9101.md` 採用時にあわせて入れる
- `id_token_encryption_alg_values_supported` 等の JWE 関連：`study-material/id-token-and-userinfo-encryption-jwe.md` 採用時にあわせて入れる

本ファイルは T-021 とは「対象フィールドが直交」する差分のみを扱う（重複しない）。

## 2. 関連する仕様・基準

共通の Discovery 仕様説明は重複させない。既存ファイルを参照のこと:

- T-021（追加すべき必須相当フィールド）: `tasks/T-021-discovery-metadata.md`
- `code_challenge_methods_supported`: `study-material/discovery-code-challenge-methods-supported.md`
- AS Metadata（RFC 8414）との二系統広告: `study-material/oauth-authorization-server-metadata-rfc8414.md`

本トピック固有のポイント:

### 2.1 OIDC Discovery 1.0 §3 — 対象フィールドの位置づけ

OIDC Discovery 1.0 §3 が定義する `OPTIONAL` フィールドのうち、本ファイル対象は以下:

- `ui_locales_supported`: BCP47 言語タグ配列。例: `["en", "ja", "fr-CA"]`
- `claims_locales_supported`: 同上、クレーム値（name / address など）の言語タグ
- `acr_values_supported`: `["urn:mace:incommon:iap:silver", "urn:mace:incommon:iap:bronze"]` 等
- `display_values_supported`: `["page", "popup"]` 等
- `op_policy_uri`: `https://op.example.com/policy`
- `op_tos_uri`: `https://op.example.com/tos`
- `service_documentation`: `https://op.example.com/docs`

OIDC Core 1.0 §15.1 は OP に `ui_locales` / `claims_locales` パラメータの受理を MUST 化しており、その対応ロケールを Discovery で広告するのが自然。

### 2.2 RFC 8414 との重複

`op_policy_uri` / `op_tos_uri` / `service_documentation` / `ui_locales_supported` は RFC 8414 にも存在。`/.well-known/oauth-authorization-server` を提供する場合（`study-material/oauth-authorization-server-metadata-rfc8414.md`）にも同じ値を出すのが筋。

### 2.3 OIDC Core 1.0 §3.1.2.1 — `display`

`display` パラメータの値は `page`（既定）/ `popup` / `touch` / `wap`。サポート外は無視（SHOULD）。本リポジトリは現状すべての値を受理（無視）するため、広告は `["page", "popup", "touch", "wap"]` か、または「実際に区別している値だけ」を出す方針が選べる。

## 3. 参照資料

- OpenID Connect Discovery 1.0 §3 — https://openid.net/specs/openid-connect-discovery-1_0.html#ProviderMetadata
- OpenID Connect Core 1.0 §3.1.2.1 — `display` / `ui_locales` / `claims_locales`
- RFC 8414 §2 — https://www.rfc-editor.org/rfc/rfc8414#section-2
- BCP 47 言語タグ — https://www.rfc-editor.org/rfc/bcp47

## 4. 現在の実装確認

- `packages/core/src/discovery.ts` `ProviderMetadataConfig`: 対象フィールドはいずれも未定義
- `packages/core/src/discovery.ts` `ProviderMetadata`: 同上
- `packages/sample/src/oidc-provider/routes/discovery.ts`: 静的に config を組むだけで、上記フィールドへの値配置無し
- `packages/cli/src/frameworks/hono/templates.ts` Discovery テンプレート: 同上
- 実装側で `ui_locales` / `claims_locales` を解釈するロジックは無いが、`acrResolver` を通じて `acr_values` には対応している（T-015 done）

## 5. 現在の実装との差分

満たしていること:

- 必須フィールドは揃っている（issuer / authorization_endpoint / token_endpoint / jwks_uri / response_types_supported / subject_types_supported / id_token_signing_alg_values_supported）
- T-021 で扱われている主要 OPTIONAL フィールドは別タスクで追跡

不足／改善余地:

- 🟡 **`ui_locales_supported` / `claims_locales_supported` が無い**: クライアントが「この OP が日本語ログインに対応しているか」を Discovery 経由で判定できない。実装上は sample のログイン画面が静的に表示しているだけだが、CLI で生成したコードを利用者がカスタマイズして多言語化した場合に整合的に広告する手段が無い。
- 🟡 **`acr_values_supported` が無い**: `AcrResolver` で扱う `acr` 値の候補をクライアントに開示できない。Step-up Authentication（`study-material/ext-step-up-authentication-rfc9470.md`）で `acr_values` を要求する場合、Discovery が広告していると相互運用性が向上する。
- 🟢 **`display_values_supported` が無い**: 仕様上はサポート外を無視すればよいので必須ではないが、`["page", "popup", "touch", "wap"]` を広告すれば「全部受理」と明示できる。`tasks/p2-display-param-validation.md` と連動。
- 🟢 **`op_policy_uri` / `op_tos_uri` / `service_documentation` が無い**: PoC 用途では空のことが多いが、利用者が本番に近づける際に広告できる経路が無いと困る。
- 🟢 **RFC 8414 経路との二重広告**: `/.well-known/oauth-authorization-server` を実装する場合（別タスク）、同じフィールドを再掲する必要がある。core builder を共通化しておくと運用負荷が下がる。

セキュリティ観点:

- これらのフィールドは公開メタデータであり、機密情報は含めない（URL のみ）。
- `op_policy_uri` / `op_tos_uri` は HTTPS であるべき（OIDC Discovery §3）。検証は呼び出し側責務だが、core 側で軽い検証を入れてもよい。

## 6. 改善・追加を検討する理由

価値:

- 相互運用性向上: クライアントライブラリ（`openid-client`, `oidc-client-ts` 等）は Discovery を読んで動作を変える。これらフィールドが無いと「対応していない」と扱われるリスクがある。
- 「Fidelity（仕様準拠）」シグナル: 公開ドキュメント URL や対応ロケールを広告する OP は本番運用に近い印象を与える。
- 国際化: 日本語 PoC を想定している以上、`ui_locales_supported: ["ja", "en"]` を出せると分かりやすい。
- Step-up / acr 系拡張との連動: `acr_values_supported` は将来のステップアップ実装で必須に近い。

導入難易度:

- 🟢 **極小**: `ProviderMetadataConfig` / `ProviderMetadata` にフィールドを追加し、`buildProviderMetadata` で出力するだけ。
- 検証は「配列が空でないなら出力、空なら省略」の既存パターンに従う。
- 既存テストへの影響なし（後方互換）。

実装しない場合のリスク:

- クライアントが Discovery 経由で機能を発見できず、`acr_values` を盲目的に送って失敗するなどのハマりが残る。
- 「OIDC Discovery 完全対応」と謳いにくい。

## 7. 実装方針の候補

### 方針A（全フィールド一括追加）

- `ProviderMetadataConfig` に以下を追加（すべて optional）:
  - `uiLocalesSupported?: string[]`
  - `claimsLocalesSupported?: string[]`
  - `acrValuesSupported?: string[]`
  - `displayValuesSupported?: string[]`
  - `opPolicyUri?: string`
  - `opTosUri?: string`
  - `serviceDocumentation?: string`
- `buildProviderMetadata` で各フィールドを出力（既存の「空配列は省略」パターンに準拠）
- URL フィールドは「`http(s)://` で始まるか」程度の軽い検証

### 方針B（必要なものだけ段階追加）

- 優先度高: `acr_values_supported`（Step-up と連動）、`ui_locales_supported`（国際化）
- 優先度中: `claims_locales_supported`、`display_values_supported`
- 優先度低: `op_policy_uri` / `op_tos_uri` / `service_documentation`
- 必要に応じて 2〜3 リリースに分けて追加

### 方針C（resolver 経由）

- 静的な config ではなく、`MetadataResolver` のような関数を注入できるようにする
- 動的に変わる値（例: 言語サポートが時間で増減する）に対応
- 過剰設計の懸念があるため非推奨

### 方針D（現状維持）

- これらフィールドは PoC 用途では不要との判断で見送り
- ドキュメントだけ整備（利用者が自前で生成 JSON に追加）

判断材料:

- 既存のフィールド追加パターンと同じ形式なので、方針 A の一括追加コストは小さい
- 方針 B の段階追加は将来の差分タスク作成コストが嵩む
- `acr_values_supported` は Step-up / AcrResolver と密接なため早期投入が望ましい

## 8. タスク案

- [ ] 方針 A / B / C / D を選択（人間が判断）
- [ ] TDD で `discovery.test.ts` に各フィールドのケースを追加:
  - 各フィールド未指定 → metadata から省略される
  - 空配列指定 → metadata から省略される（既存パターン）
  - 値指定 → metadata に正しく出力される
  - URL 系フィールドの軽い検証（`http(s)://` で始まること）
- [ ] `ProviderMetadataConfig` / `ProviderMetadata` の型拡張
- [ ] `buildProviderMetadata` で各フィールドを出力
- [ ] `packages/sample/src/oidc-provider/routes/discovery.ts` で `acr_values_supported` 等を実例として配置
- [ ] `packages/cli/src/frameworks/hono/templates.ts` Discovery テンプレートに同様の値を配置
- [ ] `study-material/oauth-authorization-server-metadata-rfc8414.md` と連動して RFC 8414 経路でも同じ値を返すかを検討
- [ ] `study-material/ext-step-up-authentication-rfc9470.md` の `acr_values_supported` 項目を更新
