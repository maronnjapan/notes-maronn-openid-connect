# JWKS Endpoint 包括的レビュー（RFC 7517 / OIDC Discovery）

## 1. タイトル

JWKS（JSON Web Key Set）Endpoint の実装完全性確認と、鍵管理・パフォーマンス・相互運用性に関する改善検討。

## 2. このトピックで確認したいこと

- JWKS Endpoint が RFC 7517（JWK）と OIDC Discovery 1.0 の要件を満たしているか
- 現在の JWKS 実装（`jwks.ts` と `routes/jwks.ts`）に不足・改善すべき点がないか
- 鍵ローテーション時の JWKS 応答の整合性
- Discovery の `jwks_uri` と JWKS 実態の整合

既存の study-material / tasks には JWKS を包括的に扱うファイルがないため、本ファイルで初めて整理する。

## 3. 関連する仕様・基準

### 3.1 RFC 7517（JSON Web Key）

RFC 7517 は JWK（JSON Web Key）と JWK Set の形式を規定する。

**JWK 必須フィールド:**
- `kty`（Key Type）: REQUIRED。`RSA`、`EC`、`oct` 等
- `use`（Public Key Use）: OPTIONAL だが推奨。`sig`（署名）または `enc`（暗号化）

**JWK 推奨フィールド:**
- `alg`: 鍵が対応するアルゴリズム。指定すると鍵選択が明確になる
- `kid`（Key ID）: 鍵を識別する識別子。複数の鍵を使う場合は特に重要。JWT の `kid` ヘッダーとの照合に使う

**秘密鍵パラメータ:**
- RSA: `d`, `p`, `q`, `dp`, `dq`, `qi` を JWKS に含めてはならない（公開鍵のみ公開）
- EC: `d` を含めてはならない

### 3.2 OIDC Discovery 1.0 での JWKS 要件

- `jwks_uri`: REQUIRED。ID Token を検証するための JWK Set が取得できる URL
- OP は JWKS Endpoint で **有効な署名検証用公開鍵のみ** を公開する
- ローテーション中は新旧の公開鍵を一定期間 JWKS に含める（発行済みトークンが失効するまで）
- OIDC Core §15.1: RS256 鍵が REQUIRED

### 3.3 鍵ローテーション（Key Rollover）

RFC 7517 には直接の鍵ローテーション手順はないが、OIDC の運用慣行として:

1. 新しい鍵ペアを生成
2. 新鍵を JWKS に追加（旧鍵も残す）
3. 新鍵でトークンを署名開始
4. 旧鍵で署名されたトークンの有効期限が切れたら JWKS から旧鍵を削除

本リポジトリの `SigningKeyProvider.getSigningKeys()` インターフェースはこの目的で複数鍵を返せるよう設計されている。

### 3.4 キャッシュと鍵取得の考慮事項

クライアントは JWKS を積極的にキャッシュし（パフォーマンスのため）、未知の `kid` が登場した場合のみ再取得する（lazy refresh パターン）。

OP 側の推奨:
- `Cache-Control: public, max-age=<seconds>` を設定してクライアントのキャッシュを促進する
- ただしローテーション時は短い max-age に変更するか、`cache-busting` の仕組みが必要

## 4. 参照資料

- RFC 7517（JSON Web Key）— https://www.rfc-editor.org/rfc/rfc7517
  - Section 4: JWK フォーマットの定義
  - Section 5: JWK Set フォーマット
- RFC 7518（JSON Web Algorithms）— https://www.rfc-editor.org/rfc/rfc7518
  - Section 6: RSA/EC 鍵のパラメータ
- OIDC Core 1.0 §15.1 — https://openid.net/specs/openid-connect-core-1_0.html#SigEnc （RS256 REQUIRED）
- OIDC Discovery 1.0 §3 — https://openid.net/specs/openid-connect-discovery-1_0.html#ProviderMetadata （`jwks_uri` REQUIRED）
- 本リポジトリ内: `tasks/done/T-022-add-sign-keys.md`（複数鍵対応の実装、完了）

## 5. 現在の実装確認

### 5.1 コアロジック（`packages/core/src/jwks.ts`）

```typescript
export interface Jwk {
  kty: string;
  use: string;      // 常に 'sig'
  alg: string;      // getJwaAlgorithm から取得
  kid?: string;     // optional
  // RSA: n, e
  // EC: crv, x, y
  // d / p / q 等: undefined (型レベルで除外)
}
```

`exportPublicJwk`: 秘密鍵が渡されても公開部分のみエクスポート ✅
`exportJwks`: 複数鍵エントリを JWK Set に変換 ✅

### 5.2 sample ルート（`packages/sample/src/oidc-provider/routes/jwks.ts`）

- 複数の鍵配列（`signingKeys`, `idTokenSigningKeys`, `userinfoSigningKeys`）をフラットに統合
- `kid` 付きの鍵は重複排除（最初の出現を採用）
- `kid` なしの鍵は最後に投入されたものを採用（最新優先）
- `Cache-Control: public, max-age=3600` を設定 ✅
- CORS 未設定 ❌ → `study-material/cors-cross-origin-support.md` 参照

### 5.3 `SigningKeyProvider` インターフェース（`packages/core/src/signing-key.ts`）

- `getSigningKey()`: アクティブな署名鍵（最新）
- `getSigningKeys()`: optional。鍵ローテーション中は旧鍵+新鍵を返せる設計

`createCachedSigningKeyProvider` で TTL ベースのキャッシュが可能 ✅

### 5.4 `assertHasRs256Key`

`buildProviderMetadata` 内で呼ばれ、RS256 鍵が少なくとも1つあることを強制 ✅

## 6. 現在の実装との差分

### 6.1 満たしていること

- 秘密鍵パラメータを公開しない（型レベルで `d` = `undefined`）✅
- RSA と EC の両アルゴリズム対応 ✅
- `use: 'sig'` を常に設定 ✅
- `alg` を鍵から自動導出 ✅
- OIDC Core §15.1 の RS256 REQUIRED を `assertHasRs256Key` で強制 ✅
- キャッシュヘッダー（`Cache-Control: public, max-age=3600`）✅
- 複数鍵対応（T-022 完了）✅

### 6.2 不足・確認が必要なこと

- 🟡 **`kid` の省略可能性**: 複数の鍵が存在する場合、`kid` がない鍵は JWT ヘッダーの `kid` と照合できない。クライアントライブラリによっては `kid` なし鍵を「すべての候補を試す」ために使うが、非効率であり相互運用性が低下する。実装コメントでは「最新 1 件のみ採用」としているが、運用上は全鍵に `kid` を付与する方が堅牢。
- 🟡 **CORS 未設定**: ブラウザ上のクライアントライブラリが JWKS をフェッチできない → `study-material/cors-cross-origin-support.md` 参照
- 🟡 **ローテーション時のキャッシュ整合**: `max-age=3600` は固定値。ローテーション直後は古い鍵でキャッシュしているクライアントが未知の `kid` に遭遇する。ローテーションフェーズに応じた `max-age` の動的調整ロジックが存在しない（運用的な欠如だが、PoC 範囲では許容される可能性）。
- 🟡 **`kid` 重複排除の方向性**: `kid` 付き鍵は「最初の出現を採用」としているが、複数の目的（ID Token 署名用・UserInfo 署名用）で同じ `kid` の鍵が重複登録された場合、片方が隠れる。目的別の配列が `signingKeys / idTokenSigningKeys / userinfoSigningKeys` と分かれているが、`kid` が被った場合の挙動がコメントのみで、テストが不足している可能性がある。
- 🔴 **`key_ops` フィールドの不在**: RFC 7517 §4.3 では `key_ops`（`sign`, `verify`）による鍵用途の明示が可能。`use: sig` で代替できるが、一部の厳格な JWT 検証ライブラリが `key_ops` を期待する場合がある。現状は問題なし（`use` で代替）だが、拡張性の観点で記録しておく。

### 6.3 `ExportPublicJwk` の `alg` フィールド

`alg` フィールドは RFC 7517 で OPTIONAL だが、本実装では `getJwaAlgorithm(key)` から導出して常に設定する。これにより:
- クライアントライブラリは `alg` ヘッダーのミスマッチを検出しやすい ✅
- Discovery の `id_token_signing_alg_values_supported` と JWKS の `alg` が整合する ✅

## 7. 改善・追加を検討する理由

- **Portability**: CORS がないとブラウザ上のクライアントライブラリが JWKS をフェッチできない。ID Token の自己検証（`alg=RS256`, `kid` 照合）が失敗する。
- **相互運用性**: `kid` のない鍵は一部のライブラリで `kid` 不一致エラーになる。全鍵に `kid` を付与する運用ガイドをドキュメント化することで利用者の落とし穴を減らせる。
- **鍵ローテーションの運用品質**: `Cache-Control: public, max-age=3600` は JWKS 変更が1時間以内にクライアントに伝わらないことを意味する。本番 IdaaS 移行を見据える開発者にとって、ローテーション時の `max-age` 短縮が推奨事項として知られていると移行コストを削減できる。

## 8. 実装方針の候補

### 方針A（`kid` 必須化）

`exportPublicJwk` / `JwksKeyEntry` で `keyId` を必須フィールドに変更する。`SigningKey.keyId` も必須化する。Breaking change だが、型の厳格化により「`kid` なし鍵」による相互運用性問題を予防できる。

### 方針B（CLI テンプレートのコメント強化）

コア API は変えず、CLI 生成コードのコメントに「全ての鍵に `kid` を付与する。ローテーション時は旧鍵を JWKS に残し、トークン有効期限切れ後に削除する」ガイドを追加する。

### 方針C（CORS + `max-age` 短縮 API）

CORS 対応（`cors-cross-origin-support.md` の方針）に加え、`ProviderConfig` に `jwksCacheMaxAge: number` を追加し、ローテーション時に外部から短縮できるようにする。

## 9. タスク案

- [ ] CORS ヘッダーを `routes/jwks.ts` に追加する（`Access-Control-Allow-Origin: *` が適切）
- [ ] `kid` のない鍵の相互運用性リスクをドキュメントおよび CLI テンプレートコメントで案内する
- [ ] `kid` なし複数鍵の重複排除ロジック（最後の1件のみ採用）をテストで明示的に保証する
- [ ] ローテーション時の `Cache-Control: max-age` 動的調整の要否を判断し、必要であれば `ProviderConfig.jwksCacheMaxAge` を追加する
- [ ] JWKS の `kid` が対応する ID Token の `kid` ヘッダーと一致することをインテグレーションテストで確認する
