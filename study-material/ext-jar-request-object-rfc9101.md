# 拡張: JWT-Secured Authorization Request（JAR, RFC 9101 / OIDC Core §6）の実装

## ステータス

🟢 拡張機能 / 未着手

## 1. このトピックで確認したいこと

認可リクエストを JWT（Request Object）にカプセル化する `request` /
`request_uri`（JAR）を **実装するか**を確認する。
本ファイルは「実装する場合」の検討に絞る。

> 「JAR を非サポートとして宣言し、`request`/`request_uri` を
> `request_not_supported` / `request_uri_not_supported` で返し、Discovery に
> `request_parameter_supported:false` 等を出す」という**非サポート方向の対応**は、
> `tasks/done/oidc-improvements-2026-05.md` の **T-018** に一次記録がある（未実装）。
> 本ファイルは T-018 と**重複しない**よう、非サポート宣言の話は繰り返さず、
> 「実装する場合の差分・判断材料」のみを扱う。
> 実装方針の前提として、まず T-018（非サポート宣言）か本ファイル（実装）の
> どちらに進むかをユーザーが選ぶ関係にある。

## 2. 関連する仕様・基準

- **OIDC Core 1.0 §6（Passing Request Parameters as JWTs）**:
  `request`（値=Request Object JWT）/ `request_uri`（JWT の参照 URI）。
  Request Object は署名（任意で暗号化）。`client_id`/`response_type` 等は
  クエリと Request Object 双方で整合必須、矛盾時はエラー。
- **RFC 9101（JWT-Secured Authorization Request, JAR）**:
  Request Object の署名検証、`exp`/`aud`（=issuer）/`iss`(=client_id) 検証、
  `request` と `request_uri` 併用禁止、フロントチャネルパラメータの扱い。
- **Discovery**: `request_parameter_supported` / `request_uri_parameter_supported` /
  `request_object_signing_alg_values_supported`（RFC 8414 §2 / OIDC Discovery §3）。
- Basic OP では JAR はオプション（Basic OP テストでは送られない）。
  Basic OP 定義は `tasks/basic-op-requirements-baseline.md` 参照。

## 3. 参照資料

- OIDC Core 1.0 §6: https://openid.net/specs/openid-connect-core-1_0.html#JWTRequests
- RFC 9101: https://www.rfc-editor.org/rfc/rfc9101
- RFC 8414 §2: https://www.rfc-editor.org/rfc/rfc8414#section-2
- 既存記録（非サポート方向）: `tasks/done/oidc-improvements-2026-05.md` T-018

## 4. 現在の実装確認

- `AuthorizationRequestParams`（`authorization-request.ts:32-57`）に
  `request` / `request_uri` は **無い**。`validateAuthorizationRequest` は
  これらを検知も拒否もしない（未知パラメータとして黙殺）。
  → T-018 が指摘する「非サポートなら `request_not_supported` を返す MUST」も未実装。
- JWT 署名検証基盤は存在: `crypto-utils.ts`、`id-token.ts:198`（JWKS 鍵選択＋検証）。
  JAR の Request Object 署名検証に**再利用可能**。
- クライアント登録鍵（`jwks`/`jwks_uri`）の型が無い（`private_key_jwt` と同じ不足。
  `tasks/ext-private-key-jwt-client-auth.md` 参照）。
- PAR（`tasks/ext-pushed-authorization-requests-rfc9126.md`）の `request_uri` とは
  別物だが、認可エンドポイントの `request_uri` 受理で**判別が必要**。

## 5. 現在の実装との差分

- **満たしていること**: JWT 検証・JWKS 選択の基盤があり、Request Object 署名検証に流用可能。
- **不足している可能性があること**
  - `request` / `request_uri` の受理・署名検証・クレーム検証
    （`iss`=client_id, `aud`=issuer, `exp`, 署名 alg ホワイトリスト, `none` 拒否）。
  - クエリと Request Object のパラメータ整合チェック（矛盾時エラー）。
  - `request` と `request_uri` 併用禁止。
  - `request_uri` フェッチのセキュリティ（SSRF 対策・許可リスト・サイズ/タイムアウト）。
  - Discovery メタデータ（実装するなら `true` / 署名 alg を出力）。
  - T-018（非サポート宣言）との二者択一の整理。
- **セキュリティ**: `request_uri` フェッチは SSRF 面が大きい。許可リスト必須。

## 6. 改善・追加を検討する理由

- 「最新仕様を忠実に検証」コンセプト上、FAPI 等は署名付きリクエスト（JAR）を前提にする。
  PAR（RFC 9126）＋ JAR の組み合わせ検証ニーズがある。
- JWT 検証基盤の再利用で**コア処理は導入しやすい**が、`request_uri` フェッチの
  SSRF 対策と Web 標準のみ方針（外部 fetch の制御）で設計判断が必要 → 導入難度は中。
- 実装しない場合の制約: 署名付き認可リクエスト前提のセキュアプロファイル検証ができない。
  ただし T-018 の「非サポートを正しく宣言」だけでも Basic OP/相互運用の最低限は満たせる。

## 7. 実装方針の候補

### 方針X（まず T-018: 非サポートを正しく宣言）— 推奨の先行ステップ

- 本ファイルの実装はせず、T-018（`request_not_supported`/`request_uri_not_supported` を
  返す + Discovery に `false`）を先に片付ける。Basic OP/相互運用の最低限を満たし、
  JAR 実装は後日のオプションにする。詳細は T-018 記録参照（重複記載しない）。

### 方針A（`request`（value）のみ実装、`request_uri` は非サポート維持）

- `request`（埋め込み JWT）だけ署名検証して受理。`request_uri` は T-018 どおり
  `request_uri_not_supported`。SSRF 面を回避しつつ JAR の主要価値を得る。
- クライアント登録鍵型は `ext-private-key-jwt-client-auth.md` と共通化。

### 方針B（`request` + `request_uri` 両対応）

- `request_uri` フェッチに許可リスト・タイムアウト・サイズ上限・スキーム制限を強制。
- PAR の `request_uri`（URN）と JAR の `request_uri` を判別。規模・リスク大。

## 8. タスク案

- [ ] まず方針X（T-018 先行）を採るか、A/B に進むかを決定（ユーザー判断）
- [ ]（A/B採用時）Request Object 検証
      （署名・`iss`/`aud`/`exp`・alg ホワイトリスト・`none`拒否・
      クエリ整合・`request`/`request_uri`併用禁止）のテストを先行作成
- [ ] core: Request Object 検証ヘルパー（`id-token.ts` の JWKS 検証パターン流用）
- [ ] クライアント登録鍵型を `ext-private-key-jwt-client-auth.md` と共通設計（/design-discussion で確定）
- [ ]（B採用時）`request_uri` フェッチの SSRF 対策（許可リスト等）を実装
- [ ] Discovery メタデータを実態に合わせて出力（T-018 と矛盾しないこと）
- [ ] CLI/sample テンプレート同期
- [ ] 完了条件: core / cli テストがパス
