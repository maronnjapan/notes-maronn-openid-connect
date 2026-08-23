# 拡張: OAuth 2.0 Rich Authorization Requests（RAR, RFC 9396）

## ステータス

🟢 拡張機能 / 未着手

## 1. このトピックで確認したいこと

RFC 9396（2023 年公開）が標準化した「`scope` の限界を超えた、構造化された認可リクエスト」機能。`authorization_details` という JSON 配列パラメータで、リソース別・操作別の詳細な権限要求を表現できる。

- スコープは粒度が荒い（例: `read:transactions`）が、RAR は「特定口座 X の過去 30 日分の取引のみ閲覧」のようなきめ細かい認可を表現可能
- 金融（FAPI 2.0 / Open Banking）、医療、エンタープライズ API で需要が高まっている
- 本リポジトリは未対応

本トピックでは、RAR を導入するべきか、入れる場合の最小スコープ、`scope` との並存・優先順位、Discovery 広告、JAR / PAR / OIDC Federation との関係を整理する。

## 2. 関連する仕様・基準

共通の認可リクエスト処理仕様は重複させない。既存ファイルを参照のこと:

- Authorization Endpoint パラメータ受理: `study-material/basic-op-requirement-traceability.md`
- JAR（Request Object）: `study-material/ext-jar-request-object-rfc9101.md`
- PAR（Pushed Authorization Requests）: `study-material/ext-pushed-authorization-requests-rfc9126.md`

本トピック固有のポイント:

### 2.1 RFC 9396 — `authorization_details` パラメータ

認可リクエストに JSON 配列を追加:

```
GET /authorize?
  response_type=code
  &client_id=...
  &authorization_details=%5B%7B%22type%22%3A%22payment_initiation%22%2C%22actions%22%3A%5B%22initiate%22%5D%2C%22locations%22%3A%5B%22https%3A%2F%2Fbank.example.com%22%5D%2C%22instructedAmount%22%3A%7B%22currency%22%3A%22EUR%22%2C%22amount%22%3A%22123.50%22%7D%7D%5D
  ...
```

JSON は配列で、各要素は以下のフィールドを持つ:

- `type`（必須）: 文字列。`authorization_details` の意味を識別。OP が事前定義したタイプのみ受理する想定
- `actions` / `locations` / `datatypes` / `identifier` / `privileges`（任意）: 共通フィールド。型特有のフィールドは自由に追加可能

### 2.2 OP の責務

- 受信した `authorization_details` を構造的に検証（JSON パース、`type` フィールド存在、未知 type の扱い）
- ユーザー同意画面で「何を認可しようとしているか」をユーザーに表示
- 認可コード・トークンに `authorization_details` を保持し、Token Response に含める（§7）
- Refresh Token grant でもローテーション後のトークンに同じ `authorization_details` を保持
- リソースサーバ側で Introspection レスポンスに含める（§9）
- ID Token / Access Token に同じ JSON 構造で含める（§10）

### 2.3 Discovery 広告

- `authorization_details_types_supported`: OP が受理可能な `type` の配列
- 未広告の場合、クライアントは RAR を使うべきでない

### 2.4 `scope` との関係

- `scope` と `authorization_details` は **共存可能**（RFC 9396 §1）
- 同じ意味を `scope` で表現できる場合 `authorization_details` は冗長
- ユーザー同意の表示・保存方法は OP の実装責任

## 3. 参照資料

- RFC 9396 OAuth 2.0 Rich Authorization Requests — https://www.rfc-editor.org/rfc/rfc9396
  - §2（`authorization_details` パラメータ）
  - §7（Token Response への組み込み）
  - §10（ID Token / Access Token への組み込み）
  - §13（Security Considerations）
- FAPI 2.0 Security Profile — https://openid.net/specs/fapi-security-profile-2_0-ID2.html （RAR を要件化）
- IANA Authorization Details Type Registry（型のレジストリ）

## 4. 現在の実装確認

- `packages/core/src/authorization-request.ts`: `authorization_details` パラメータの受理ロジック無し
- `packages/core/src/auth-transaction.ts` `AuthTransaction` 型: `authorizationDetails` フィールド無し
- `packages/core/src/authorization-code.ts` `AuthorizationCodeData` 型: 同上
- `packages/core/src/token-request.ts` `AccessTokenInfo` / `RefreshTokenInfo`: 同上
- `packages/core/src/token-response.ts`: Token Response に `authorization_details` を含める処理無し
- `packages/core/src/discovery.ts`: `authorization_details_types_supported` フィールド無し
- 既存の同意画面（sample の `consent.ts`）: scope ごとの表示のみ、`authorization_details` 表示ロジック無し

## 5. 現在の実装との差分

満たしていること:

- 認可リクエストパラメータの拡張機構（オプション追加）は `validateAuthorizationRequest` が「未知パラメータを無視」する設計のため、互換性は維持しやすい。
- `AuthTransaction` ストレージ / `AuthorizationCodeData` への JSON 保存は既存パターンで対応可能。

不足:

- 🟡 **全工程未対応**: 認可リクエスト受理 → 同意画面表示 → 認可コード保存 → トークン応答への含有 → refresh ローテーションでの引き継ぎ → イントロスペクションへの含有 のすべてが未実装。
- 🟡 **`type` の検証ポリシー設計**: OP が受理可能な型の管理（許可リスト / プラグイン）方式の選定が必要。本リポジトリは「外部依存なし」「core はロジック層」方針なので、利用者が型を注入する resolver パターンが妥当。
- 🟡 **同意画面 UX**: scope の単純な羅列とは違い、`authorization_details` の中身（金額・期間・口座など）を構造化表示する UI が必要。sample レベルでも一定の参考実装が要る。
- 🟢 **Discovery 広告**: `authorization_details_types_supported` が無い。

セキュリティ観点（RFC 9396 §13）:

- `authorization_details` は機微情報（金額・口座番号など）を含むため、ログ出力・エラーメッセージへの混入に注意
- 同意画面で「ユーザーが何を許可するか」が読み取れること（Phishing 対策）
- `type` を信頼する前に必ず許可リストでフィルタする（任意 type を通すと意味のない / 攻撃的な型を許可してしまう）
- JSON サイズ制限（DoS 対策）

## 6. 改善・追加を検討する理由

価値:

- 「Speed（最新仕様最速）」軸の主力候補。FAPI 2.0 が RAR を要件化しているため、金融 PoC の検証用に強い差別化になる。
- `scope` だけでは表現困難な「特定リソース・特定操作・期間限定」の許認可を試せる。
- 本リポジトリの差別化軸「自分の要件がこの仕様で実現できるか？を素早く検証」の典型ユースケース。

導入難易度:

- 🔴 **中〜高**: パラメータ受理〜トークン保存〜引き継ぎまで横断する。コア構造に `authorization_details` を持たせるための型拡張が広い。
- 同意画面 UX が PoC レベルでも要る。sample の simple な consent.ts に構造化表示を入れるコストが目立つ。
- ただし、core の責務は「JSON を受け取り保持・引き継ぐ」だけにとどめ、型ごとの意味解釈は resolver に委ねる設計にすればコアの実装は限定的。

実装しない場合のリスク:

- 「最新 OAuth 仕様」を謳う上で RAR 非対応はネガティブシグナル。
- FAPI 2.0 / Open Banking 系 PoC を本ライブラリでは検証できない。

## 7. 実装方針の候補

### 方針A（非対応の明文化 / 後回し）

- README / `RELEASE-v0.x-scope.md` に「RAR は後続ロードマップ」と明記
- 既存資産の `scope` でカバー可能な範囲は scope を使う運用ガイド

### 方針B（最小スコープ / コアに JSON 保持のみ）

- `validateAuthorizationRequest` で `authorization_details` を JSON パース・基本検証（配列であること、`type` 必須）
- `ValidatedAuthorizationRequest` / `AuthTransaction` / `AuthorizationCodeData` / `RefreshTokenInfo` / `AccessTokenInfo` に `authorizationDetails?: AuthorizationDetail[]` を追加
- `generateTokenResponse` で Token Response に含める
- 同意画面は scope と同等の「未知 type は名前と必須フィールドを表示するだけ」の最小実装
- Discovery に `authorization_details_types_supported: []` を広告（型は利用者が config で渡す）
- 型ごとの意味解釈は core では行わない（resolver 注入）

### 方針C（B + 型 resolver / 推奨）

- B に加えて、`AuthorizationDetailsResolver` インタフェースを定義:

  ```typescript
  export interface AuthorizationDetailsResolver {
    validate(detail: AuthorizationDetail): Promise<AuthorizationDetail>;
    describeForConsent(detail: AuthorizationDetail): Promise<string>;
  }
  ```

- 利用者が型ごとに validate / 表示文言を定義
- core は resolver の戻り値を信頼

### 方針D（フル / FAPI 2.0 想定）

- C に加えて、JAR / PAR との結合（`authorization_details` を JAR 内に含める）を検証
- Introspection レスポンスへの含有も実装
- Open Banking 互換の参考実装を sample に追加

判断材料:

- v0.x スコープ的には方針 A または B が現実的（`RELEASE-v0.x-scope.md` は先端仕様を後回しと宣言）
- 方針 C は「PoC 利用者にとって価値が高い拡張」と「実装コスト」のバランスが良い
- 方針 D は FAPI 検証フェーズで再検討する

## 8. タスク案

- [ ] 方針 A / B / C / D を選択（人間が判断、`RELEASE-v0.x-scope.md` との整合）
- [ ] （方針 B 以上採用時）TDD でテストを先に追加:
  - `authorization_details` が JSON 配列であること
  - 各要素が `type` を持つこと
  - 不正 JSON / 配列以外 / `type` 欠落 → `invalid_authorization_details` エラー（RFC 9396 §11）
- [ ] `ValidatedAuthorizationRequest` / `AuthTransaction` / `AuthorizationCodeData` / `RefreshTokenInfo` / `AccessTokenInfo` の型拡張
- [ ] `generateTokenResponse` で Token Response に `authorization_details` を含める
- [ ] Refresh での `authorization_details` 引き継ぎ実装
- [ ] `ProviderMetadataConfig` に `authorizationDetailsTypesSupported?: string[]` を追加し Discovery に広告
- [ ] sample の consent ページに `authorization_details` の最小表示を追加
- [ ] （方針 C 採用時）`AuthorizationDetailsResolver` インタフェース定義と利用者向けドキュメント
- [ ] `study-material/basic-op-requirement-traceability.md` に対応状況を追記
