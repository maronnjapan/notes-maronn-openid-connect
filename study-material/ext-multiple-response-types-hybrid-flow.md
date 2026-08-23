# Multiple Response Type Encoding Practices / Hybrid Flow / Implicit Flow

## 1. このトピックで確認したいこと

OpenID Connect Core 1.0 が定義する `response_type` のうち、本リポジトリで現状サポートしていない以下の値の扱いを整理する。

- `id_token`（Implicit Flow / OIDC Core §3.2）
- `id_token token`（Implicit Flow / OIDC Core §3.2）
- `code id_token` / `code token` / `code id_token token`（Hybrid Flow / OIDC Core §3.3）

Basic OP 認定では `response_type=code` のみが必須のため、これらは「拡張機能として入れるか／意図的に省くか」の検討対象になる。

加えて、

- OAuth 2.0 Security BCP / OAuth 2.1 が Implicit Flow を非推奨化していること
- フロントチャネルにトークンを流す設計のセキュリティリスク（履歴/Referer 漏洩、`at_hash`/`c_hash` 検証必須化）
- 既存実装の `response_types_supported` Discovery 公開との整合性

を踏まえ、本リポジトリのコンセプト（最新仕様の忠実実装 + セキュリティ第一）から見て採用すべきかを判断材料として整理する。

なお、`response_mode=form_post` 自体は別ファイル（`study-material/response-mode-form-post.md`）で扱っているため重複しない。本ファイルは「`response_type` 多値の **意味論** とフロー」に絞る。

## 2. 関連する仕様・基準

### OAuth 2.0 Multiple Response Type Encoding Practices
- https://openid.net/specs/oauth-v2-multiple-response-types-1_0.html
- `response_type` がスペース区切りの集合になるエンコーディング規約

### OpenID Connect Core 1.0
- §3.1 Authorization Code Flow
- §3.2 Implicit Flow（`response_type=id_token` / `id_token token`）
  - §3.2.2.10 `nonce` 必須
  - §3.2.2.11 `at_hash` 必須（`token` が含まれる場合）
- §3.3 Hybrid Flow（`response_type=code id_token` / `code token` / `code id_token token`）
  - §3.3.2.11 `c_hash` 必須（`code` が含まれる場合）
  - §3.3.2.10 `at_hash` 必須（`token` が含まれる場合）

### OAuth 2.0 Security Best Current Practice
- §2.1.2 Implicit Grant: 「使用してはならない」と明記
- Hybrid Flow は Implicit Flow の問題を完全には解消しないため「Code Flow + PKCE」を推奨

### OAuth 2.1
- Implicit Grant 削除（Hybrid Flow は OIDC 拡張なので残るが、推奨は依然として Code + PKCE）

### Basic OP 認定との関係
- OpenID Connect Conformance Profiles v3.0 Basic OP では `response_type=code` のみテスト対象
- Implicit OP / Hybrid OP プロファイルが別途存在する

## 3. 参照資料

- OAuth 2.0 Multiple Response Type Encoding Practices
  https://openid.net/specs/oauth-v2-multiple-response-types-1_0.html
- OpenID Connect Core 1.0 §3.2 / §3.3
  https://openid.net/specs/openid-connect-core-1_0.html#ImplicitFlowAuth
  https://openid.net/specs/openid-connect-core-1_0.html#HybridFlowAuth
- OAuth 2.0 Security Best Current Practice §2.1.2
  https://www.rfc-editor.org/rfc/rfc9700.html
- OAuth 2.1 draft（Implicit 削除の根拠）
  https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1
- 既存関連: `study-material/basic-op-requirements-baseline.md`, `study-material/oauth-browser-based-apps-bcp.md`, `study-material/response-mode-form-post.md`

## 4. 現在の実装確認

- `packages/core/src/authorization-request.ts`
  - `validateAuthorizationRequest` 内で `if (responseType !== 'code')` として `unsupported_response_type` を返している
  - 現在サポートする値は `'code'` のみ
- `packages/core/src/discovery.ts`
  - `ProviderMetadataConfig.responseTypesSupported` は設定ファイル次第。サンプル設定で何を公開しているかは `packages/sample/src/oidc-provider/config.ts` を確認する必要あり
- `at_hash` / `c_hash` の算出
  - `packages/core/src/id-token.ts` を見る限り Hash 系クレームの算出ヘルパは未実装（grep で `at_hash`/`c_hash` がヒットしない）

つまり Implicit / Hybrid は完全に未実装。

## 5. 現在の実装との差分

| 観点 | 仕様 | 現状 | 差分 |
|---|---|---|---|
| `response_type=code` | OIDC Core §3.1 | 実装済 | OK |
| `response_type=id_token` | OIDC Core §3.2 | 未対応 | 仕様上は実装すれば公開できるが OAuth 2.1 で非推奨 |
| `response_type=id_token token` | OIDC Core §3.2 | 未対応 | 同上 + Access Token をフラグメントに置く |
| `response_type=code id_token` | OIDC Core §3.3 | 未対応 | `c_hash` 算出が必須 |
| `response_type=code token` | OIDC Core §3.3 | 未対応 | `at_hash` 算出が必須 |
| `response_type=code id_token token` | OIDC Core §3.3 | 未対応 | `c_hash` + `at_hash` 両方必須 |
| `nonce` 必須化 | §3.2.2.10 / §3.3.2.10 | `code` ではすでに任意。Implicit/Hybrid だけ必須 | 既存ロジックは `nonce` 任意で扱っている可能性高 |
| `at_hash` / `c_hash` 検証 | OIDC Core §3.1.3.7 / §3.2.2.9 / §3.3.2.9 | 未実装 | 算出 + ID Token への組み込み |
| Discovery `response_types_supported` 公開 | OIDC Discovery §3 | サンプル設定次第 | 嘘の宣言にならないよう、サポート値とコードを一致させる |

## 6. 改善・追加を検討する理由

- **入れるメリット**
  - 「最新 OIDC 仕様を忠実に検証できる OSS」というコンセプトを満たすには Hybrid Flow までカバーしておく価値がある
  - レガシー RP（古い SDK）との互換性検証
- **入れるデメリット**
  - OAuth 2.1 / Security BCP が非推奨にしている流れに OP 側で逆行する印象を与える
  - フロントチャネルに ID Token / Access Token を渡す実装は安全に書くのが難しく、Bug が利用者の本番システムに波及するリスク
  - `at_hash` / `c_hash` の算出は地味だが「Access Token / Code の左半分を SHA-256 でハッシュ → Base64URL」の手順を `alg` ごとに正しく書く必要がある
- **対策と判断**
  - 入れる場合でも「デフォルト無効、明示的に `enableImplicitFlow: true` / `enableHybridFlow: true` を渡す」設計を推奨
  - Discovery は実際にサポートする値だけを宣言（嘘公開を防ぐ）

## 7. 実装方針の候補

### 候補 A: 採用しない（Code + PKCE 一本に絞る）
- v0.x ではコンセプトの "Speed" 優先で `code` だけに集中
- README に「Implicit / Hybrid は意図的に未対応。OAuth 2.1 / Security BCP の推奨に従い Code + PKCE を使ってください」と明記
- `unsupported_response_type` を返す現状の挙動をテストで担保

### 候補 B: Hybrid Flow のみ追加（Implicit は不採用）
- `code id_token` / `code id_token token` だけサポート
- `c_hash` / `at_hash` 算出を `core` の `id-token.ts` に追加
- `nonce` 必須を Hybrid Flow 時のみ強制
- `response_mode=fragment` のレスポンス組み立てを追加
- `response_mode=form_post` を併用できるようにする

### 候補 C: Implicit + Hybrid をフル実装
- OpenID Foundation の Conformance プロファイル「Implicit OP」「Hybrid OP」を狙う場合に必要
- 実装量は中規模（フラグメントエンコード、`nonce` 強制、Hash 系クレーム、Discovery 公開）
- v0.x 主要 7〜8 割の流れには該当しないので、後継リリースで検討

## 8. タスク案

候補 A 採用時:

- `unsupported_response_type` を返すケースのテスト整備
- Discovery の `response_types_supported` を `["code"]` 固定にしているか確認
- README / docs に「Implicit / Hybrid 未対応の理由」を明記

候補 B / C を選ぶ場合:

- `core` に `computeAtHash(accessToken, alg)` / `computeCHash(code, alg)` を追加
- `core` の ID Token 生成オプションに `atHash` / `cHash` を追加
- `validateAuthorizationRequest` で許可する `response_type` 集合を設定で差し替え可能に
- `nonce` を Hybrid / Implicit 時に必須化するバリデータ追加
- `response_mode=fragment` 用のレスポンス組み立てヘルパ
- Discovery の `response_types_supported` を「実際にサポートする値だけ」公開するテスト
- `at_hash` / `c_hash` のテストベクトル整備（OIDC Core §16.11 / 仕様の例）

判断材料:

- v0.x で「Basic OP のみ」に注力するなら候補 A
- 「OIDC を最新仕様まで忠実に試せる OSS」という Speed/Fidelity 軸を強く推すなら候補 C
- セキュリティ第一の方針からは候補 A、教育/網羅性なら候補 B/C、というトレードオフ
