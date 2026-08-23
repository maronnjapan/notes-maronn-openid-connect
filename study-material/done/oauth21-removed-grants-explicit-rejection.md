# OAuth 2.1 §1.5 で削除されたグラントタイプの明示的拒否と Discovery 整合

## ステータス

🟡 Minor（Fidelity / 相互運用性）/ 未着手

## 1. このトピックで確認したいこと

OAuth 2.1（draft-ietf-oauth-v2-1）§1.5 では、OAuth 2.0 で定義されていた一部のグラントタイプが**削除または非推奨**になっている。本リポジトリは OAuth 2.1 準拠を掲げており、Token Endpoint の `grant_type` 受理ロジックでも `authorization_code` と `refresh_token` 以外は `unsupported_grant_type` で拒否している。だが以下が未確認・未文書化:

- OAuth 2.1 で**削除された各グラントタイプ**（`password`、`implicit`（response_type 経由）、`urn:ietf:params:oauth:grant-type:jwt-bearer`、`urn:ietf:params:oauth:grant-type:saml2-bearer` 等）に対する Token Endpoint の挙動が、テストで個別に保証されていない
- `client_credentials` / `urn:ietf:params:oauth:grant-type:device_code` / `urn:ietf:params:oauth:grant-type:token-exchange` など、OAuth 2.1 で削除ではないが本ライブラリが意図的に非対応とするグラントタイプの扱いが、ポリシーとして文書化されていない
- Discovery の `grant_types_supported` を「実際に対応しているものだけを列挙する（広告ハネスティ）」運用が、本ライブラリで明示されていない

本ファイルは、既存タスク `tasks/T-021-discovery-metadata.md`（Discovery `grant_types_supported` の追加）と接続しつつ、**「OAuth 2.1 で削除されたグラントの拒否方針」というポリシー軸**を扱う。T-021 はメタデータのフィールド充足、本ファイルは挙動・テスト・ポリシーの差分。

## 2. 関連する仕様・基準

共通の仕様索引は `study-material/basic-op-requirement-traceability.md`「3.3」を参照。本トピック固有の根拠:

- **OAuth 2.1 §1.5 Differences from OAuth 2.0**:
  - 「Resource Owner Password Credentials Grant」（`grant_type=password`、RFC 6749 §4.3）は OAuth 2.1 から削除（OMITTED）。理由はセキュリティ（クライアントが平文パスワードを取り扱う必要があり、phishing 耐性・MFA 互換性に劣る）
  - 「Implicit Grant」（`response_type=token` および `response_type=id_token token`）は OAuth 2.1 から削除。理由はアクセストークンが URL フラグメントに露出すること、PKCE と組み合わせた Authorization Code Flow が安全な代替を提供すること
  - これら削除されたグラントを受け取った場合は OAuth 2.1 §3.2.3.1 に従い `unsupported_grant_type`（Token Endpoint）または `unsupported_response_type`（Authorization Endpoint）を返すべき
- **RFC 6749 §5.2 / OAuth 2.1 §3.2.3.1**: Token Endpoint がサポートしないグラントタイプを受けた場合 `unsupported_grant_type` を返す（HTTP 400）。エラーコードはレジストレーション上「authorization server がサポートしない、または当該クライアントの認可に許可されていない」場合に使用
- **RFC 6749 §3.1.1（response_type）**: Authorization Endpoint が受理しない `response_type` 値は `unsupported_response_type` で拒否
- **OAuth 2.1 §1.5 が削除していないが本ライブラリが意図的に非対応とするもの**:
  - `client_credentials`: OAuth 2.1 で削除はされていない（マシン間認可で有効）。だが OIDC Basic OP は人間の認証フローを対象としており、本ライブラリの v0.x スコープ外
  - `urn:ietf:params:oauth:grant-type:device_code` (RFC 8628): 拡張グラント。📌 `study-material/ext-device-authorization-grant-rfc8628.md` で別途検討
  - `urn:ietf:params:oauth:grant-type:token-exchange` (RFC 8693): 拡張グラント。📌 `study-material/ext-token-exchange-rfc8693.md`
  - `urn:ietf:params:oauth:grant-type:jwt-bearer` (RFC 7523): クライアント認証ではなくアサーション grant 方式。OAuth 2.1 で削除はされていないが、本ライブラリは未対応
- **RFC 8414 §2 / OIDC Discovery 1.0 §3**: `grant_types_supported` は authorization server がサポートする grant_type 値のリスト。**実際にサポートするものだけを列挙する**（広告と実装が矛盾しないこと）

## 3. 参照資料

- OAuth 2.1 draft §1.5 — https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1#section-1.5 （OAuth 2.0 からの差分: password / implicit grant の削除）
- OAuth 2.1 draft §3.2.3.1 — https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1#section-3.2.3.1 （Token Endpoint エラー: `unsupported_grant_type`）
- RFC 6749 §5.2 — https://www.rfc-editor.org/rfc/rfc6749#section-5.2 （`unsupported_grant_type` エラー定義）
- RFC 6749 §3.1.1 — https://www.rfc-editor.org/rfc/rfc6749#section-3.1.1 （`response_type` と `unsupported_response_type`）
- RFC 7521 / RFC 7522 / RFC 7523（Assertion Framework, SAML2 Bearer, JWT Bearer）
- RFC 8414 §2 — https://www.rfc-editor.org/rfc/rfc8414#section-2 （`grant_types_supported`）
- OAuth 2.0 Security BCP（RFC 9700）§2.4 — Resource Owner Password Credentials grant の使用禁止

## 4. 現在の実装確認

- `packages/core/src/token-request.ts:324-329`:
  ```ts
  if (params.grant_type !== 'authorization_code' && params.grant_type !== 'refresh_token') {
    throw new TokenError(
      TokenErrorCode.UnsupportedGrantType,
      `Unsupported grant_type: ${params.grant_type}`
    );
  }
  ```
  ホワイトリスト方式で `authorization_code` と `refresh_token` 以外は一律 `unsupported_grant_type`（HTTP 400）で拒否される。**仕様準拠の挙動は実装済み**
- `packages/core/src/authorization-request.ts`: `response_type` は `code` のみ許可。それ以外は `unsupported_response_type` で拒否（Basic OP の `response_type=code` 限定）
- `packages/core/src/token-request.test.ts`:
  - `client_credentials` を渡したケースのみテスト済（行 142, 147）
  - `password` / `urn:ietf:params:oauth:grant-type:jwt-bearer` / `urn:ietf:params:oauth:grant-type:saml2-bearer` / `implicit` 風の文字列 など、**OAuth 2.1 §1.5 削除グラントの個別テストは存在しない**
- `packages/sample/src/oidc-provider/routes/discovery.ts:62`:
  ```ts
  grantTypesSupported: ['authorization_code', 'refresh_token'],
  ```
  サンプルでは正しく広告。だが `buildProviderMetadata` のデフォルト値ではない（呼び出し側で必ず渡す必要がある）
- `packages/core/src/discovery.ts`: `grantTypesSupported` は optional 設定。デフォルト挿入は無し → 利用者が広告を忘れる可能性が残る（T-021 のスコープ）

## 5. 現在の実装との差分

満たしていること:

- ホワイトリスト方式（`authorization_code` / `refresh_token` のみ受理）で、OAuth 2.1 §1.5 削除グラントは**自動的に拒否される**
- エラーコード `unsupported_grant_type` と HTTP 400 は仕様（RFC 6749 §5.2 / OAuth 2.1 §3.2.3.1）準拠
- `client_credentials` の拒否テストは存在
- サンプル Discovery は `grant_types_supported` を実態に合わせて広告

不足・確認が必要なこと:

- 🟡 **OAuth 2.1 §1.5 削除グラントの個別テスト欠落**: `password`、`implicit`、`urn:ietf:params:oauth:grant-type:jwt-bearer`、`urn:ietf:params:oauth:grant-type:saml2-bearer` などが Token Endpoint に来ても `unsupported_grant_type` で返ることは現状ホワイトリストにより事実上担保されているが、**仕様準拠の証跡となる明示的テストが無い**。リファクタで誤ってブラックリスト方式に変えると静かに脆弱化するリスク
- 🟡 **広告の「正直さ」ポリシー文書化不在**: `grant_types_supported` は実装の真実を述べる場であり、OAuth 2.1 が削除したグラントを「広告しない」ことは仕様準拠と相互運用性の両方に効く。だが本ライブラリの設計指針として明文化されていない（T-021 はデフォルト値の足し算、本ファイルは「何を広告しないか」のポリシー軸）
- 🟡 **`response_type` 側の対称性**: OAuth 2.1 §1.5 は `response_type=token`（Implicit Grant）も削除している。本ライブラリは `response_type=code` のみ許可しているため自動的に拒否されるが、`token` / `id_token token` / `code token` などのレガシー Hybrid 形式に対する**明示テスト**は薄い（既存 `study-material/ext-multiple-response-types-hybrid-flow.md` は Hybrid を「拡張として将来検討」の文脈で扱っており、削除側の証跡には特化していない）
- 🟢 **`client_credentials` の扱いは方針要明示**: 仕様削除はされていない（OAuth 2.1 でも引き続き有効）が、本ライブラリの「人間中心の OIDC Basic OP」スコープ外であるため非対応。これも `grant_types_supported` で広告しない方針と整合
- 🟢 **拡張グラント（device_code / token-exchange / jwt-bearer）の方針**: 個別の study-material で「将来拡張候補」として扱われている。本ファイルはそれらの拡張を取り込まない現時点でも、削除グラントとは別レイヤーで拒否されている点を明確化する

## 6. 改善・追加を検討する理由

- **Fidelity 軸の維持**: 本リポジトリの差別化軸である「Fidelity（Conformance 準拠を信頼性のシグナルに）」は、削除・非推奨グラントを「正しく拒否し、広告しない」という地味だが重要な不変条件で支えられている。テストで証跡化していないと、リファクタやレビュー時に逆方向の変更が紛れ込みやすい
- **セキュリティ非劣化の予防線**: OAuth 2.1 が `password` / `implicit` を削除したのはセキュリティ上の根拠がある。本ライブラリが将来「便利機能」として ROPC 等を足したくなる誘惑への、**設計上のガードレール**として明文化する価値が高い
- **OSS 利用者への教育的価値**: PoC 開発者が「うちは OAuth 2.0 だから password grant を入れたい」と相談してきた時に、本ファイルが「なぜ本ライブラリは入れない方針か」の根拠（仕様＋セキュリティ＋運用）を一次資料リンク付きで示せる
- **実装コストが極小**: 個別テストの追加だけで仕様準拠の証跡が立ち、本コードは変更不要
- **実装しない場合のリスク**:
  - ホワイトリスト方式の保護がリファクタで失われる回帰
  - 削除グラントを「対応していない」と認識せずに広告してしまうクライアント側誤解
  - OSS 利用者が ROPC 等を独自追加する際の根拠不在

## 7. 実装方針の候補

判断材料を整理する（実装方針は人間が決定）:

- 方針A（テスト追加＋ポリシー文書化, 推奨検討筆頭）:
  - `packages/core/src/token-request.test.ts` に「OAuth 2.1 §1.5 削除グラント」「拡張グラント未対応」のカテゴリを追加し、各々が `unsupported_grant_type` で拒否されることをテーブル駆動で検証
  - `packages/core/src/authorization-request.test.ts` に `response_type=token` / `response_type=id_token token` などのレガシー値が `unsupported_response_type` で拒否されることのテストを追加
  - CLI 生成コードのコメントに「`grant_types_supported` は実装の真実を述べる場であり、削除済みグラントを足さないこと」のガイドを記載
- 方針B（ポリシー文書のみ）:
  - 本 study-material と既存 T-021 / 既存 `study-material/ext-*` の関係性を整理し、`oidc-basic-op-certification` スキルおよび README に「OAuth 2.1 削除グラントは恒久非対応」のスタンスを明記。テスト追加は v0.x スコープ外
- 方針C（現状維持）:
  - ホワイトリスト方式が現実装で守られているので追加実装は不要とし、本 study-material を**監査ハブ** (`basic-op-requirement-traceability.md` への注記行) としてのみ機能させる

`RELEASE-v0.x-scope.md` の Tier 定義に照らすと、方針 A はテスト整備（Fidelity の証跡）に該当し、コードコスト極小なため Tier B（Conformance）に効く準備として v0.x 内でも入れやすい。方針 C はリリース判定をブロックしない。

## 8. タスク案

- [ ] 方針 A/B/C を選択する（セキュリティ非劣化と Fidelity 軸の維持を条件に）
- [ ]（方針 A 採用時）`token-request.test.ts` に OAuth 2.1 §1.5 削除グラント＋拡張グラントの拒否テストを追加（テーブル駆動）
- [ ]（方針 A 採用時）`authorization-request.test.ts` にレガシー `response_type` 値の拒否テストを追加
- [ ]（方針 A/B 採用時）CLI テンプレートの `grant_types_supported` 設定にコメントで「実装の真実だけを広告する」ガイドを追記
- [ ] `basic-op-requirement-traceability.md` の OAuth Behaviors 行に「§1.5 削除グラント・レガシー response_type 拒否のテスト証跡」状態を追加（実装後）
- [ ] OAuth 2.0 Security BCP §2.4（ROPC 非推奨）への参照を `security-client-secret-handling.md` 周辺に集約するか、本ファイルで完結させるかの判断
