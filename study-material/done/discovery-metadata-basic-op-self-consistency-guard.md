# Discovery メタデータの Basic OP 自己整合ガード（`response_types_supported` に `code` / `scopes_supported` に `openid` を保証する）

## ステータス

🟢 Low / 未着手

## 1. このトピックで確認したいこと

`buildProviderMetadata` は、OP が実際に満たすべき Basic OP の必須挙動と、広告する Provider Metadata が
**乖離しないようにビルド時ガード**を持つべきか、その範囲と方針を整理する。

具体的には次の 2 点に絞る。

1. **`response_types_supported` に `"code"` が含まれることを保証していない**。
   現状は「非空配列であること」しか検査せず、`["token"]` のような Basic OP 非対応の広告を素通しできる。
2. **`scopes_supported` を広告する場合に `"openid"` が含まれることを保証していない**。
   OIDC Discovery 1.0 §3 は「OP は `openid` scope を MUST support」と定めるため、
   `scopes_supported` を広告するなら `openid` を含めるのが自然だが、現状は任意配列をそのまま出力する。

このガードは、既に存在する `assertHasRs256Key`（署名鍵に RS256 が含まれることをビルド時に強制）と
**同じ設計思想の延長**であり、「広告した能力を OP が実際に持っている」ことを fail-fast で担保する。

> 関連既存ファイル（重複回避）：
> - `study-material/done/discovery-endpoint-url-validation.md` … Discovery の**エンドポイント URL の妥当性**検証。
>   本ファイルは URL ではなく「**必須メンバの内容整合**（`code` / `openid` の存在）」という別の差分。
> - `study-material/discovery-optional-metadata-fields.md` … 任意フィールド（`ui_locales_supported` 等）の**追加**可否。
>   本ファイルは新フィールドの追加ではなく、**既存の必須/推奨フィールドの内容ガード**。
> - `study-material/scope-handling-validation-and-granted-scope.md` … リクエスト時の scope 検証・付与。
>   本ファイルは**広告メタデータの自己整合**であり、リクエスト処理とは別レイヤ。
> - `study-material/done/discovery-token-endpoint-auth-methods-default-fidelity.md`
>   … `token_endpoint_auth_methods_supported` のデフォルト忠実性。auth method の広告整合という近縁論点だが、
>   本ファイルは `response_types_supported` / `scopes_supported` の Basic OP 必須メンバに限定する。

## 2. 関連する仕様・基準（このトピック固有の差分）

共通の Discovery 仕様説明は
`study-material/basic-op-requirement-traceability.md` の「3. 関連する仕様・基準」および
`study-material/discovery-optional-metadata-fields.md` を参照。ここでは本トピックに効く条文だけを引く。

- **OpenID Connect Discovery 1.0 §3（OpenID Provider Metadata）**:
  - `response_types_supported`（REQUIRED）: 「JSON array containing a list of the OAuth 2.0 `response_type` values that this OP supports. **Dynamic OpenID Providers MUST support the `code`, `id_token`, and the `token id_token` Response Type values.**」
    Basic OP は Authorization Code Flow（`response_type=code`）を必須とするため、広告に `code` が含まれないのは自己矛盾。
  - `scopes_supported`（RECOMMENDED）: 「JSON array containing a list of the OAuth 2.0 [RFC6749] `scope` values that this server supports. **The server MUST support the `openid` scope value.** Servers MAY choose not to advertise some supported scope values even when this parameter is used.」
    → `scopes_supported` を**広告する**なら `openid` を含めるべき（`openid` は OP が MUST support する唯一の必須 scope）。
- **OpenID Connect Conformance Profiles v3.0 — Basic OP**:
  Discovery を検査するテストは、`code` を含む `response_types_supported`、`openid` を含む `scopes_supported`（広告時）を期待する。
- **設計上の先例（本リポジトリ内）**: `buildProviderMetadata` は既に
  `assertHasRs256Key(config.idTokenSigningKeys)` で「RS256 署名能力の広告と実態の一致」をビルド時に強制している
  （`packages/core/src/discovery.ts:171`）。本トピックのガードはこの方針の自然な拡張。

なお、これらは「OP 運用者が `buildProviderMetadata` に渡す設定を誤ったとき」に効くガードであり、
リクエスト処理ロジックの変更ではない。**過剰に厳格化して利用者の正当な構成を弾かない**設計が要点。

## 3. 参照資料

- OpenID Connect Discovery 1.0 §3（Provider Metadata / `response_types_supported` / `scopes_supported`）:
  https://openid.net/specs/openid-connect-discovery-1_0.html#ProviderMetadata
  （"MUST support the `code` ..." / "The server MUST support the `openid` scope value."）
- OpenID Connect Core 1.0 §3.1.2（Authorization Code Flow — `response_type=code`）:
  https://openid.net/specs/openid-connect-core-1_0.html#CodeFlowAuth
- RFC 8414 §2（Authorization Server Metadata — `response_types_supported` / `scopes_supported`）:
  https://www.rfc-editor.org/rfc/rfc8414#section-2
- OpenID Connect Conformance Profiles v3.0 — Basic OP:
  https://openid.net/certification/

## 4. 現在の実装確認

- `packages/core/src/discovery.ts:161-166`

  ```ts
  if (!config.responseTypesSupported || config.responseTypesSupported.length === 0) {
    throw new Error('responseTypesSupported must not be empty');
  }
  if (!config.subjectTypesSupported || config.subjectTypesSupported.length === 0) {
    throw new Error('subjectTypesSupported must not be empty');
  }
  ```

  → **非空チェックのみ**。`response_types_supported` に `code` が含まれるかは検査しない。

- `packages/core/src/discovery.ts:203-208`

  ```ts
  if (config.scopesSupported && config.scopesSupported.length > 0) {
    metadata.scopes_supported = config.scopesSupported;
  }
  if (config.claimsSupported && config.claimsSupported.length > 0) {
    metadata.claims_supported = config.claimsSupported;
  }
  ```

  → `scopesSupported` は渡された配列をそのまま出力。`openid` 包含のチェックは無い。

- 既存の先例ガード: `packages/core/src/discovery.ts:171`
  ```ts
  // OIDC Core 1.0 §15.1: at least one RS256 key must be present.
  assertHasRs256Key(config.idTokenSigningKeys);
  ```

- 生成 OP 側の呼び出し: `packages/cli/src/frameworks/hono/templates.ts:1995`（`buildProviderMetadata({ ... })`）。
  生成テンプレートは `response_types_supported: ['code']` / `scopes_supported: ['openid', ...]` を渡す想定だが、
  利用者が生成コードを改変した場合にガードが無いと、Basic OP 非対応の広告を出力できてしまう。

## 5. 現在の実装との差分

- **満たしていること**
  - RS256 署名能力の広告と実態の一致はビルド時に強制済み（`assertHasRs256Key`）。
  - 必須フィールドの非空チェックは実装済み。
- **不足している可能性があること**
  - `response_types_supported` に `code` が含まれることの保証が無い。
  - `scopes_supported` を広告する場合の `openid` 包含の保証が無い。
- **セキュリティ上の観点**
  - 直接の脆弱性ではないが、「広告と実態の乖離」はクライアントの自動構成を誤らせる（interop 事故）。
- **相互運用性の観点**
  - クライアントは `response_types_supported` / `scopes_supported` を見て利用可否を判断する。
    実態は `code` / `openid` を支えているのに広告が欠けると、RP が接続を諦める／誤った response_type を選ぶ。
- **Basic OP として提供する上で確認すべきこと**
  - Basic OP は `response_type=code` と `openid` scope を必須とする。広告メタデータがそれを反映しているかは
    Conformance の Discovery 検査でも観測される。

## 6. 改善・追加を検討する理由

- **fail-fast な自己整合**: `assertHasRs256Key` と同じく、Basic OP の中核不変条件を**ビルド時に**検出できる。
  誤設定が本番の Discovery レスポンスとして外部に出る前に落とせる。
- **OSS 利用者の安全網**: 利用者は生成コードを改変してよい設計だが、`response_types_supported` から `code` を
  誤って外す／`scopes_supported` から `openid` を落とすと Basic OP から外れる。ガードがあれば
  「conformance.test.ts が通らない状態」と同様に、早期に気づける。
- **Basic OP / 拡張の別**: Basic OP の必須挙動（code flow / openid scope）の**広告整合**であり、
  拡張機能ではなく Basic OP の信頼性シグナル（Fidelity 軸）に属する。
- **導入しやすさ**: `buildProviderMetadata` の先頭に検査を数行追加するだけ。既存の非空チェック・`assertHasRs256Key`
  と同じ場所・同じ throw パターンに揃えられる。
- **実装しない場合のリスク**: 生成コードを改変した利用者が Basic OP 非対応の広告を無自覚に公開し、
  「Conformance を主張できない OP」を作ってしまう。テストでも固定されない。

## 7. 実装方針の候補

判断材料の整理（最終判断は人間）。

- 方針A（必須メンバをビルド時強制・推奨）:
  - `response_types_supported` に `code` が含まれなければ throw。
  - `scopes_supported` を渡した場合に `openid` が含まれなければ throw。
  - `assertHasRs256Key` と同じ throw スタイル（`Error`）で `buildProviderMetadata` 先頭付近に追加。
  - 長所: Basic OP 不変条件の fail-fast。短所: `code` 以外の OP（純 OAuth 用途など）を core で作りたい利用者には過剰。
- 方針B（warn / opt-out 可能なガード）:
  - デフォルトで throw するが、明示フラグ（例: `allowNonBasicOpMetadata: true`）で緩和できる。
  - 長所: Basic OP 逸脱を意図する上級利用者に逃げ道を残す。短所: API 表面が増える。
- 方針C（検査せず、テンプレート側テストで固定）:
  - core は変更せず、生成テンプレートのテストで「`code` / `openid` を広告する」ことだけ固定。
  - 長所: core 非侵襲。短所: 生成コードを改変した利用者は保護されない（本トピックの主眼が薄れる）。
- どの方針でも、`assertHasRs256Key` と整合する「Basic OP の中核不変条件をどこで守るか」の一貫性を崩さないこと。

## 8. タスク案

- [ ] 方針を決定（A: 常時強制 / B: opt-out 付き / C: テンプレートテストのみ）
- [ ] `packages/core/src/discovery.test.ts` に先行テスト（Red）:
  - [ ] `response_types_supported` に `code` を含まない設定でビルドが throw すること（方針A/B）
  - [ ] `scopes_supported` を渡し `openid` を含まない設定でビルドが throw すること（方針A/B）
  - [ ] `code` を含む `response_types_supported` / `openid` を含む `scopes_supported` は正常にビルドできること（回帰固定）
- [ ] `packages/core/src/discovery.ts` の `buildProviderMetadata` にガードを追加（方針に応じて）
- [ ] 生成 OP の Discovery 出力が変わらないこと（テンプレートは既に `code` / `openid` を渡す）を確認し、
      必要なら各 sample の `conformance.test.ts`（Discovery 検査）と `packages/cli` のテンプレート生成側テストを更新
- [ ] 完了条件: `pnpm --filter @maronn-openid-connect/core test` がパス
