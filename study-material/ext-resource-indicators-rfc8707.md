# 拡張: Resource Indicators（RFC 8707）標準 `resource` パラメータ対応

## ステータス

🟢 拡張機能 / 未着手

## 1. このトピックで確認したいこと

現状はアクセストークンの audience を独自の `audience` パラメータ（スペース区切り）で
受け取っている。標準の **RFC 8707 `resource` パラメータ**に対応すべきか、
対応すると相互運用性がどう向上するかを確認する。

> 「JWT access token の `aud` を空配列にしない／既定 audience」という別論点は
> 既存 `tasks/p1-jwt-access-token-aud-default.md` で扱う。本ファイルは **重複を避け**、
> 「標準 `resource` パラメータの受理と複数リソースの aud 制約」という固有差分のみを扱う。
> 本タスクは p1-jwt-access-token-aud-default.md と前後どちらで実装してもよいが、
> 同 aud 既定方針と整合させること。
>
> ⚠️ 「現在すでに出荷されている独自 `audience` パラメータが**無検証**でアクセストークンの `aud` に
> 到達している」というセキュリティ差分は 📌 `study-material/authorization-audience-parameter-unvalidated-token-audience.md`
> が扱う。**本ファイルの方針選択（A/B/C）は、そちらの併存ポリシーと同時に決めること。**
> 片方だけを決めても `audience` と `resource` の関係が確定しないため。

## 2. 関連する仕様・基準

- **RFC 8707（Resource Indicators for OAuth 2.0）**
  - §2: Authorization Request / Token Request に `resource` パラメータ（複数可、絶対 URI、
    fragment 不可）を追加。AS は発行トークンの権限/`aud` を要求リソースに制約する。
  - §2.2: 要求リソースが許可されない場合、`invalid_target` エラーを返す。
- **OAuth 2.1 draft**: `resource` を任意拡張として参照。
- **RFC 9068（JWT Access Token）**: `aud` に resource indicator を入れる
  （`tasks/p1-jwt-access-token-aud-default.md` 参照）。
- Basic OP 必須ではない（拡張）。位置づけは `tasks/basic-op-requirements-baseline.md` 参照。

## 3. 参照資料

- RFC 8707: https://www.rfc-editor.org/rfc/rfc8707
  - §2 Resource Parameter / §2.2 `invalid_target`
- RFC 9068 §3: https://www.rfc-editor.org/rfc/rfc9068#section-3
- OAuth 2.1: https://datatracker.ietf.org/doc/html/draft-ietf-oauth-v2-1

## 4. 現在の実装確認

- 認可リクエスト: `packages/core/src/authorization-request.ts:46-48,572-577`
  - 独自 `audience`（スペース区切り）を受理し `ValidatedAuthorizationRequest.audience: string[]` へ。
  - **標準 `resource` パラメータは未受理**。
- 認可コード→トークン: `audience` が `AuthorizationCodeInfo.audience` →
  `ValidatedAuthorizationCodeRequest.audience` → `generateTokenResponse` の `audience` へ伝播。
- refresh: `RefreshTokenInfo.audience` を保持しローテーション後も同 aud（done T-002）。
- `token-response.ts:222`: `const accessTokenAud = audience ?? [];`
  → リソース指定が無いと空配列（p1-jwt-access-token-aud-default で別途対応予定）。
- `invalid_target` エラーコードは未定義（`TokenErrorCode`/`AuthorizationErrorCode` に無し）。

## 5. 現在の実装との差分

- **満たしていること**: audience を認可〜トークン〜refresh で一貫保持する仕組みは既にある。
  `resource` を `audience` にマッピングすれば中核ロジックは再利用可能。
- **不足している可能性があること**
  - 標準 `resource` パラメータ名を受理しない（RP/SDK は `resource` を送るのが標準）。
  - `resource` の妥当性検証（絶対 URI・fragment 不可）が無い。
  - 許可されないリソースに対する `invalid_target` 経路が無い。
  - 複数リソースを要求された場合の `aud` 配列・`azp` の扱いが未整理
    （ID Token の `azp` は aud 複数時必須: `id-token.ts:105-115`）。
- **相互運用性**: 標準 `resource` 非対応だと、RFC 8707 前提のクライアントと噛み合わない。

## 6. 改善・追加を検討する理由

- 「最新の OIDC/OAuth 仕様を忠実に検証できる」というコンセプトに直結。
  Resource Indicators は API Gateway/マイクロサービスの audience 制約検証で頻出。
- 既存の `audience` 伝播パスがあるため **導入しやすい**（パラメータ受理層の追加が主）。
- 実装しない場合の制約: マルチオーディエンス／リソース別トークンの検証ができず、
  「自分の要件がこの仕様で実現できるか」の検証ブリッジとして弱い。

## 7. 実装方針の候補

### 方針A（標準名へ寄せる）

- `authorization-request.ts` / `token-request.ts` で `resource`（複数値）を受理。
- 既存 `audience` と並存させ、`resource` を優先（または併用時は `invalid_request`）。
- リソース URI 検証（絶対 URI・fragment 不可）を追加。
- 許可リソース判定を **resolver 注入**（`ResourceValidator` 的 callback）で利用者責務化。
  許可外は `invalid_target`。
- `TokenErrorCode`/`AuthorizationErrorCode` に `invalid_target` を追加。
- 複数 aud 時の `azp` は既存 `id-token.ts` のルールに従う。

### 方針B（最小）

- `resource` を受理して内部的に既存 `audience` 配列へ正規化するだけ。
  許可判定や `invalid_target` は将来対応として TODO 化。

### 方針C（非対応の明文化）

- 当面 `audience` 独自パラメータのみとし、README/型 doc に「RFC 8707 非対応」を明記。

## 8. タスク案

- [ ] 方針A/B/C を選択（ユーザー判断）。`audience` 独自パラメータとの併存ポリシー決定
- [ ] `resource` 受理・URI 検証・`invalid_target` のテストを先行作成
- [ ] `authorization-request.ts` / `token-request.ts` に `resource` 受理を実装
- [ ] （方針A）`ResourceValidator` 注入 I/F と `invalid_target` 経路を実装
- [ ] CLI/sample テンプレートの authorize/token ルートを同期
- [ ] p1-jwt-access-token-aud-default.md の既定 aud 方針と矛盾しないことを確認
- [ ] 完了条件: core / cli テストがパス

## 関連トピック

- 📌 `study-material/done/userinfo-access-token-audience-validation.md` — RFC 8707 で aud を絞っても、**受領側（UserInfo / リソースサーバ）が aud を検証しなければ限定効果が無効化される**。本ファイル（発行側の resource 受理）と対になる「受領側の aud 検証」を扱う。
