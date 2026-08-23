# Discovery `code_challenge_methods_supported` を core builder で表現可能にする

## ステータス

🟡 Major / 未着手

## 1. このトピックで確認したいこと

PKCE（S256 必須）に対応しているにもかかわらず、Discovery メタデータの
`code_challenge_methods_supported` を **core の `buildProviderMetadata` が出力できず**、
CLI/sample の Discovery ルートが応答 JSON に後付けしている、という構造的不整合を確認する。

「core を直接使う高度な組み込みユースケース」では、core builder の出力に
`code_challenge_methods_supported` が含まれず、PKCE 対応を advertise できない。

> Discovery メタデータ全般の不足フィールド（`grant_types_supported` 等）は
> 既存 `tasks/T-021-discovery-metadata.md` で扱う。本ファイルは **重複を避け**、
> `code_challenge_methods_supported` に固有の差分のみを扱う（T-021 はこのフィールドを列挙していない）。

## 2. 関連する仕様・基準

- **RFC 8414（OAuth 2.0 Authorization Server Metadata）§2**:
  `code_challenge_methods_supported` を AS メタデータの一フィールドとして定義する。
  → 現コードのコメントは「OIDC Discovery に無く OAuth 2.1/PKCE 由来なので別扱い」とするが、
  正確には **RFC 8414 §2 がこのフィールドを定義**しており、OIDC Discovery 実装は
  RFC 8414 を内包する形で同一ドキュメントに出力するのが一般的。
- **OAuth 2.1 draft §4.1.1 / §7**: PKCE 必須。`S256` を提供する AS は
  `code_challenge_methods_supported` に `S256` を含めるべき。
- **RFC 7636 §4.2**: `S256` / `plain` の定義。本リポジトリは S256 のみ許可
  （`authorization-request.ts:208`）なので advertise も `["S256"]` が正。

Basic OP / OIDC Core の Discovery 一般背景は `tasks/basic-op-requirements-baseline.md` を参照。

## 3. 参照資料

- RFC 8414 §2 Authorization Server Metadata:
  https://www.rfc-editor.org/rfc/rfc8414#section-2 （`code_challenge_methods_supported` の定義）
- RFC 7636 §4.2: https://www.rfc-editor.org/rfc/rfc7636#section-4.2
- OAuth 2.1: https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1
- OpenID Connect Discovery 1.0 §3: https://openid.net/specs/openid-connect-discovery-1_0.html

## 4. 現在の実装確認

- core: `packages/core/src/discovery.ts`
  - `ProviderMetadataConfig` / `ProviderMetadata` に `code_challenge_methods_supported` 相当の
    フィールドが **存在しない**（`discovery.ts:13-95` を確認）。
  - `buildProviderMetadata` も当然出力しない。
- CLI テンプレート: `packages/cli/src/frameworks/hono/templates.ts:1403-1409`
  - `buildProviderMetadata(...)` の戻り値を spread し、応答時に
    `code_challenge_methods_supported: ['S256']` を**手で足している**。
  - コメント: 「OIDC Discovery に無く OAuth 2.1/PKCE 由来なので別扱い」
    → RFC 8414 §2 がこのフィールドを定義している点で説明が不正確。
- sample: `packages/sample/src/oidc-provider/routes/discovery.ts:79-88` も同様に後付け。

## 5. 現在の実装との差分

- **満たしていること**: 生成コード経由の HTTP 応答には `code_challenge_methods_supported: ['S256']`
  が含まれる（クライアントから見た Discovery 応答は概ね正しい）。
- **不足している可能性があること**:
  - core の `buildProviderMetadata` 単体では当フィールドを出力できない
    → core を直接利用する組み込みユースケースで PKCE method を advertise 不能。
  - 「メタデータ生成は core が単一の真実」というアーキテクチャ原則が崩れている
    （CLI/sample 2 箇所で手書きの後付けが重複し、ドリフトの温床）。
- **相互運用性**: 現状 HTTP 応答は出ているので RP 側の致命的問題は起きにくいが、
  値を上書き／拡張したい利用者（将来 `plain` を許可する等）が core 経由で制御できない。
- **Basic OP として確認すべきこと**: Basic OP テストは Discovery を参照するため
  メタデータの一貫性は重要。当フィールド自体の有無で Basic OP が FAIL するかは
  要一次資料確認だが、メタデータが「実態と一致」していることは Conformance の前提。

## 6. 改善・追加を検討する理由

- `tasks/T-021-discovery-metadata.md` が core builder にメタデータ拡張を集約する方針なので、
  `code_challenge_methods_supported` も**同じ場所（core builder）に寄せるのが自然**
  （T-021 と整合する設計差分の埋め合わせ）。
- 2 箇所の手書き後付けを 1 箇所（core）へ寄せることでドリフトを防げる。
- 導入容易性: 既存 `responseModesSupported` 等と同じパターンで追加でき、低リスク・後方互換。
- 実装しない場合のリスク: core 直利用ユーザーが PKCE を advertise できず、
  CLI/sample 側のロジック重複が残る。

## 7. 実装方針の候補

### 方針A（推奨度：T-021 と整合）

- `ProviderMetadataConfig` に `codeChallengeMethodsSupported?: string[]` を追加。
- `ProviderMetadata` に `code_challenge_methods_supported?: string[]` を追加。
- `buildProviderMetadata` で「空配列でなければ出力」（既存フィールドと同じ規約）。
- 既定値の扱いは 2 案を比較し人間が選択:
  - A-1: 既定なし（config 未指定なら出力しない）。CLI/sample 側で `['S256']` を渡す。
  - A-2: 既定 `['S256']`（PKCE 必須の本ライブラリ方針に合致、config で上書き可）。
- CLI/sample の Discovery ルートから手書き後付けを削除し、config 経由に統一。

### 方針B（T-021 に統合）

- 本タスクを独立実装せず、T-021 実装時にフィールド一覧へ `code_challenge_methods_supported`
  を追記する。T-021 はこのフィールドを列挙していないため、その差分追記が必要。

## 8. タスク案

- [ ] 方針A（独立）/ B（T-021へ統合）の選択（ユーザー判断）。既定値 A-1/A-2 も決定
- [ ] `discovery.test.ts` に「`codeChallengeMethodsSupported` を渡すと
      `code_challenge_methods_supported` が出る／未指定時は出ない（または既定値）」テストを先行追加
- [ ] `discovery.ts` に config/output フィールドを追加し `buildProviderMetadata` を更新
- [ ] CLI テンプレート `templates.ts:1403-1409` の手書き後付けを config 渡しへ置換、
      不正確なコメント（RFC 8414 §2 を反映）も修正
- [ ] sample `routes/discovery.ts` も同期（CLI 生成方針に従う）
- [ ] 完了条件:
      `pnpm --filter @maronn-openid-connect/core test` および
      `pnpm --filter @maronn-openid-connect/cli test` がパス
