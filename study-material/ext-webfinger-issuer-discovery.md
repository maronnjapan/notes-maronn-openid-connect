# WebFinger による OpenID Provider Issuer Discovery

## 1. このトピックで確認したいこと

OpenID Connect Discovery 1.0 §2 が定義する「ユーザー入力（メールアドレス／URL／アカウント識別子）から Issuer URL を発見する」ためのプロトコル、すなわち WebFinger（RFC 7033）を、本リポジトリの OP が提供するかどうかを検討する。

具体的には以下:

- `/.well-known/webfinger` エンドポイントの提供
- `rel=http://openid.net/specs/connect/1.0/issuer` への応答
- `acct:` / メールアドレス / URL リソースのパース
- 既存の Discovery メタデータ（`/.well-known/openid-configuration`）との接続

Basic OP 認定との関連、および「OP 利用者が WebFinger なしでも実用上困らないか」を整理する。

なお、Discovery メタデータエンドポイント自体は別ファイル（`study-material/discovery-optional-metadata-fields.md`, `study-material/oauth-authorization-server-metadata-rfc8414.md`）で扱っており、本ファイルはそれより前段の「Issuer URL の発見プロセス」に絞る。

## 2. 関連する仕様・基準

### OpenID Connect Discovery 1.0 §2
- §2.1 Identifier Normalization
  - ユーザーが入力した識別子（メール `joe@example.com`、URL `https://example.com/joe`、アカウント URI `acct:joe@example.com`）を正規化する手順
- §2.2 Non-Normalized Identifiers
- §2.3 OpenID Provider Issuer Discovery
  - WebFinger を使い `rel=http://openid.net/specs/connect/1.0/issuer` で問い合わせると `links[].href` に Issuer URL が返る
- §2.4 例

### RFC 7033 WebFinger
- §4: `/.well-known/webfinger` エンドポイントの一般要件
- §4.4: Response Format（JRD = JSON Resource Descriptor）
- §8: CORS の取り扱い（`Access-Control-Allow-Origin: *` を推奨）

### Basic OP 認定との関係
- OpenID Connect Conformance Profiles v3.0 の Basic OP テストでは WebFinger は **必須テスト項目になっていない**（Discovery は `/.well-known/openid-configuration` の取得のみが必須）
- ただし「Dynamic Client Registration や WebFinger を経由した完全動的フロー」を組む場合は前段に WebFinger が必要

### 主要 OP の対応状況
- Google Identity / Microsoft Entra ID は WebFinger を提供していない
- Keycloak / OneLogin など WebFinger をサポートする実装も存在する
- 「メールアドレスから OP を自動発見する」フローは現代的には事実上使われていないため、デフォルト OFF が現実的

## 3. 参照資料

- OpenID Connect Discovery 1.0 §2
  https://openid.net/specs/openid-connect-discovery-1_0.html#IssuerDiscovery
- RFC 7033 WebFinger
  https://datatracker.ietf.org/doc/html/rfc7033
- OpenID Connect Conformance Profiles v3.0
  https://openid.net/specs/openid-connect-conformance-profiles-3_0.html
- OpenID Connect Core 1.0
  https://openid.net/specs/openid-connect-core-1_0.html

## 4. 現在の実装確認

- Discovery メタデータの公開
  - `packages/core/src/discovery.ts` で `ProviderMetadata` を構築
  - `packages/sample/src/oidc-provider/routes/discovery.ts` で `/.well-known/openid-configuration` を返却
- WebFinger エンドポイント
  - 該当ルートなし（grep で `webfinger` が一切ヒットしない）
- Issuer 値の検証
  - `packages/core/src/discovery.ts` の `validateIssuer` で `https` スキーム・query なし・fragment なしを検査済み（WebFinger 経由でも同じ Issuer 値を返すべき制約は満たせる）

つまり WebFinger 関連は未実装。

## 5. 現在の実装との差分

| 観点 | 仕様 | 現状 | 差分 |
|---|---|---|---|
| `/.well-known/webfinger` ルート | RFC 7033 §4 | 未対応 | ルート追加が必要 |
| Identifier 正規化 | OIDC Discovery §2.1 | 未対応 | `acct:` / email / URL → URL の変換 |
| `rel` 判定 | OIDC Discovery §2.3 | 未対応 | `rel=http://openid.net/specs/connect/1.0/issuer` のみ応答 |
| CORS | RFC 7033 §8 | n/a | `Access-Control-Allow-Origin: *` |
| Issuer URL 整合性 | OIDC Discovery §2.3 | 既存実装と接続必要 | 既存の Discovery が返す `issuer` と一致させる |
| エラーレスポンス | RFC 7033 §4.5 | 未対応 | 不正な `resource` には 400、未知のリソースには 404 |

## 6. 改善・追加を検討する理由

- **追加するメリット**
  - 「OIDC 仕様を端から端まで素早く検証できる」というコンセプトに合致（Speed / Fidelity 軸）
  - PoC で `joe@example.com` から OP を発見する完全動的フローを試したい開発者にとっては便利
  - 実装規模が小さい（数百行程度、`core` ロジックは正規化と JRD 構築のみ）
- **入れない場合のリスク**
  - Conformance テストの「Dynamic Discovery」系プロファイルが通せない
  - WebFinger 経由の動的フローを試したい利用者がフォークせざるを得ない
- **入れる場合の注意**
  - 任意のリソースに対して OP がレスポンスを返すと「メールアドレス列挙」になりうる → 既知ユーザー判定は返さず、固定の Issuer を返すか 404 を返すかを設計判断
  - 既存の Issuer 値（`https://...`）との完全一致を保証するテストが必要

## 7. 実装方針の候補

### 候補 A: 採用しない（最小スコープ）
- README で「WebFinger は意図的に未実装。Issuer URL は固定値として利用者に告知して使ってもらう」と記述
- Basic OP 必須でないため、v0.x スコープ的に問題なし

### 候補 B: ミニマル実装
- `core` に `buildWebfingerResponse(resource, rel, issuer)` を実装
  - 任意の `resource`（emailアドレス・acct・URL）に対し、`rel=http://openid.net/specs/connect/1.0/issuer` のときだけ JRD を返す
  - それ以外の `rel` には空 `links: []` を返す
- `cli` のテンプレに `/.well-known/webfinger` ルートを追加
- ユーザー列挙対策として「resource が形式不正なら 400、それ以外は常に同じ Issuer を返す」固定挙動を既定にする
- CORS は `Access-Control-Allow-Origin: *` 固定

### 候補 C: フル実装（ユーザー解決込み）
- `resource` が実在ユーザーかどうかを確認した上で JRD を返す
- 実装規模は中、ユーザーストア依存が増える
- Basic OP 範囲を超えるため、v0.x では推奨しない

## 8. タスク案

候補 B を選ぶ場合、以下に分割可能:

- `core` に `parseWebfingerResource`（acct:/mailto:/https の正規化）を実装
- `core` に `buildWebfingerResponse` を実装し、戻り値型を export
- `cli` のテンプレに `/.well-known/webfinger` ルートを生成（HTTP `Accept` の `application/jrd+json` を返却）
- Discovery メタデータの `issuer` と WebFinger が返す Issuer URL が一致することを担保する統合テスト
- README に「WebFinger は OFF をデフォルトとし、有効化するときの注意点」を記載

判断材料:

- OSS 利用者が WebFinger を実装したい場面が現実的にどれくらいあるか
- ユーザー列挙耐性を取るか、特定ユーザーへのバインドを取るかの設計選択
- 関連トピック: `study-material/discovery-optional-metadata-fields.md`（Discovery と同じく「公開して嘘にならない」設計が必要）
