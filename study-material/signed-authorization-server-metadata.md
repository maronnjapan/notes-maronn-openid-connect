# Signed Authorization Server Metadata（RFC 8414 §2.1 / `signed_metadata`）対応の検討

## ステータス

🟢 拡張 / 任意（FAPI 系で重要）/ 未着手

## 1. このトピックで確認したいこと

- RFC 8414 §2.1 が定める **`signed_metadata`** フィールド（AS Metadata を JWT で署名して改ざん耐性を持たせる仕組み）の本リポジトリへの導入可否を整理する。
- 既存の `study-material/oauth-authorization-server-metadata-rfc8414.md` は `/.well-known/oauth-authorization-server` パス提供を扱うが、`signed_metadata` には踏み込んでいない。`study-material/ext-protected-resource-metadata-rfc9728.md` は RS メタデータ側の `signed_metadata` を扱っており、AS メタデータ側を別ファイルとして独立させる。
- 本ファイルは「`signed_metadata` 単独」の差分タスクであり、AS メタデータ全般の論点は重複させない。

## 2. 関連する仕様・基準

共通の Discovery / AS Metadata 仕様説明は `study-material/oauth-authorization-server-metadata-rfc8414.md` を参照。本トピック固有のポイント:

### 2.1 RFC 8414 §2.1 — `signed_metadata`

- AS Metadata 文書の **`signed_metadata`** メンバーは、AS Metadata を JWT で表現した文字列を含む。
- JWT のクレームセットは、AS Metadata の他のメンバーと**同じ値**を含む（重複表現）。
- クライアントは `signed_metadata` の署名を検証することで、メタデータが改ざんされていないことを確認できる。
- 検証時、JWT のクレームと AS Metadata 平文部の値が一致することも検証する MUST。
- 署名アルゴリズム: `alg` は MUST NOT を `none`。実用上は `RS256` / `ES256` が多い。
- 検証鍵の入手元: AS の `jwks_uri` を**そのまま使うのではない**（循環参照になる）。署名鍵は別チャネル（事前合意・トラストアンカー）で配布する想定。
- FAPI 1.0 Part 2 / FAPI 2.0 は `signed_metadata` を MUST 化しているプロファイルがある。

### 2.2 OpenID Connect Discovery 1.0 との関係

- OIDC Discovery 1.0 自体は `signed_metadata` を定義していないが、RFC 8414 の同フィールドを `/.well-known/openid-configuration` レスポンスに含めることは**事実上の慣行**として認められている。
- 商用 IdP（Authlete 等）は OIDC Discovery 経由でも `signed_metadata` を返すケースがある。

### 2.3 鍵管理・ローテーション

- `signed_metadata` の署名鍵は ID Token 署名鍵と**分離**することが望ましい（ID Token 鍵ローテーションでメタデータ署名が突然変わると、クライアントのトラストアンカー設定を破壊する）。
- 既存の `signing-key-rotation-operations.md` の延長で別 purpose key（例: `metadata-signing`）として管理する想定。

### 2.4 既存実装のキャッシュとの関係

- `signed_metadata` の JWT は数 KB 規模になる。Discovery のサイズが増えるためキャッシュ戦略の重要性が増す。
- `study-material/discovery-cache-control-and-etag.md`（新規）の Cache-Control 設定と直交する論点。

## 3. 参照資料

- RFC 8414 §2.1 — https://www.rfc-editor.org/rfc/rfc8414#section-2.1 （`signed_metadata` の定義）
- RFC 8414 §3.4 — https://www.rfc-editor.org/rfc/rfc8414#section-3.4 （署名検証手順）
- FAPI 1.0 Part 2 §5.2.2 — https://openid.net/specs/openid-financial-api-part-2-1_0.html#section-5.2.2 （`signed_metadata` MUST 化プロファイル）
- 本リポジトリ内: `study-material/oauth-authorization-server-metadata-rfc8414.md`（AS Metadata 全般）
- 本リポジトリ内: `study-material/ext-protected-resource-metadata-rfc9728.md`（RS メタデータ側の `signed_metadata`、本ファイルは AS 側）
- 本リポジトリ内: `study-material/signing-key-rotation-operations.md`（鍵ローテーションとの整合）

## 4. 現在の実装確認

- `packages/core/src/discovery.ts` `buildProviderMetadata`: `signed_metadata` フィールドの出力経路は無し。
- `packages/sample/src/oidc-provider/routes/discovery.ts`: 平文 JSON のみ返却。
- `packages/cli/src/frameworks/hono/templates.ts`: 同上。
- `signing-key.ts` / `T-022` 経由で複数 purpose の鍵を扱う基盤はあるが、`metadata-signing` purpose は未定義。

## 5. 現在の実装との差分

満たしていること:

- ✅ AS Metadata の平文 JSON 提供は OIDC Discovery 1.0 / RFC 8414 に準拠。
- ✅ HTTPS 経由で配信される前提なら、TLS が改ざん検知の責務を担う（RFC 8414 §6.2 が「TLS で十分」と明示）。

不足／確認が必要なこと:

- 🟢 **`signed_metadata` 不在**: TLS 配信を前提にすれば仕様違反ではない。MUST ではない。
- 🔴 **FAPI / 高セキュリティ要件には不足**: FAPI 1.0/2.0、銀行業界系のプロファイルでは `signed_metadata` MUST。本リポジトリは PoC 向け OSS なので FAPI 認定は v0.x スコープ外（`RELEASE-v0.x-scope.md`）。
- 🟡 **公開 jwks_uri との鍵分離設計が無い**: `signed_metadata` を後から導入する際、`metadata-signing` purpose の鍵スロットが無い状態だと、ID Token 署名鍵を流用したくなる誘惑が生じる（ローテーション時に問題化）。
- 🟡 **検証鍵配布チャネルの設計が無い**: トラストアンカーをどう配るかは仕様外。本リポジトリのドキュメントで明記が無い。

セキュリティ観点:

- TLS のみで十分なケース（一般的な PoC・SME 用途）と、`signed_metadata` が要件になるケース（FAPI、高保証）を**ユースケース別に明示**することで誤適用を防げる。
- 検証鍵を `jwks_uri` から取得するアンチパターン（循環参照）の禁止を Note 化する価値がある。

## 6. 改善・追加を検討する理由

価値:

- **FAPI 系 PoC の入口**: 本リポジトリは「最新 OIDC/OAuth 仕様を最速で検証」を Speed 軸として掲げている。`signed_metadata` 対応は FAPI 系の前提を満たす最初の一歩。
- **Fidelity 軸**: RFC 8414 を完全実装している OSS は実は多くない（多くが平文 JSON 止まり）。差別化シグナル。
- **後方互換**: `signed_metadata` を返しても平文フィールドは維持されるため、対応していないクライアントへの影響は無い。

導入難易度:

- 🟡 **中**: 既存の JWT 署名ロジック（`id-token.ts` の generateIdToken）を流用できるが、`metadata-signing` purpose の鍵管理 / Discovery レスポンス組み立てフローへの組み込み設計が要る。
- 🟢 **テスト容易**: 「`signed_metadata` を JWT デコードしたクレームと平文フィールドが一致する」というアサーションが明快。

実装しない場合のリスク:

- FAPI / 高保証ユースケースの利用者が他 OSS（Authlete、Keycloak）に流れる。
- `RELEASE-v0.x-scope.md` の v0.x スコープでは「先端仕様は v0.x に含めない」明示があり、当面のリスクは低い。
- ただし v1.0 で Conformance Suite を通す際、FAPI ベース Conformance も視野に入るなら v1.0 ブロッカー候補。

## 7. 実装方針の候補

### 方針A（純関数追加のみ）

- `packages/core/src/discovery.ts` に `signProviderMetadata(metadata, privateKey, keyId): Promise<string>` を追加。
- `ProviderMetadata` を JWT クレームセットとしてそのまま署名する（ヘッダは `{ alg, typ: 'JWT', kid }`）。
- ルート側で signing を選択して `signed_metadata` を組み立てる。
- 利用者は静的設定で「signed metadata を出すか出さないか」を選択。

### 方針B（resolver 経由）

- `MetadataSigner` インターフェースを optional に注入できる経路を作る:
  ```ts
  interface MetadataSigner {
    sign(metadata: ProviderMetadata): Promise<string>;
  }
  ```
- 利用者が独自鍵管理を持っている場合（HSM 等）に対応可能。
- 鍵分離（ID Token 鍵流用禁止）の責務を resolver 実装側に押し付けられる。

### 方針C（フル統合・自動鍵分離）

- 方針 B + `T-022` 風に `metadataSigningKeys` purpose を `SigningKeyProvider` 階層に追加。
- `SigningKey` 型に purpose を持たせる（既存設計と整合）。
- CLI が自動で metadata-signing 鍵を生成する経路を追加。

### 方針D（現状維持 + 警告）

- 実装せず、ドキュメントに「FAPI / 高保証要件では `signed_metadata` が必要。現在は未対応」と明記。
- `RELEASE-v0.x-scope.md` の後続ロードマップに記載。

判断材料:

- 本リポジトリのターゲットユーザー（SME / PoC 開発者）には FAPI は遠い。短期は方針 D が合理的。
- ただし方針 A は実装コストが極小（既存 JWT 署名インフラ流用）で、`signed_metadata` を**返さないが返せる**状態を作っておくと将来のスコープ変更コストが下がる。
- 方針 C は overkill（v0.x 範囲では）。

## 8. タスク案

- [ ] 方針 A / B / C / D のいずれを採るか人間が判断する。
- [ ] 方針A以上を採る場合:
  - [ ] `packages/core/src/discovery.ts` に `signProviderMetadata` を実装（TDD で「JWT decode → 平文と一致」を先行）。
  - [ ] JOSE ヘッダで `alg: 'none'` を禁止（`jws-algorithm-policy-and-alg-none-defense.md` と整合）。
  - [ ] `ProviderMetadata` 型に `signed_metadata?: string` を追加。
- [ ] 方針B以上を採る場合:
  - [ ] `MetadataSigner` インターフェースの定義と `routes/discovery.ts` の組み込み。
- [ ] 方針C採用時:
  - [ ] `metadataSigningKeys` purpose を `T-022` 風に追加。
  - [ ] CLI / sample でデモ鍵を自動生成。
- [ ] 検証鍵配布チャネル（トラストアンカー）について `RELEASE-v0.x-scope.md` の責務境界節と整合するガイドを追記する。
- [ ] 本ファイルと `oauth-authorization-server-metadata-rfc8414.md` を相互参照リンクで結ぶ。
- [ ] FAPI 認定スコープに踏み込む場合のロードマップを `RELEASE-v0.x-scope.md` の v1.0 / 後続ロードマップに反映するか議論する。
