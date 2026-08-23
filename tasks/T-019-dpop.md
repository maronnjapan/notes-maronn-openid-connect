# T-019 [Major] DPoP (RFC 9449) sender-constrained トークン実装

## ステータス

🔴 Major / 未着手

## 背景

OAuth 2.1 では public client の refresh token に対して「ローテーション or sender-constrained」が MUST。本ライブラリはローテーションを実装済みだが、DPoP による sender-constrained 化を行うことで、トークン漏洩時の不正利用をアプリケーション層で防止できるようになる。

## 対象ファイル

- `packages/core/src/crypto-utils.ts`（JWK thumbprint 計算ヘルパー追加）
- `packages/core/src/access-token.ts`（DPoP Proof 検証・`cnf` クレーム対応）
- `packages/core/src/token-request.ts`（DPoP-bound AT 発行）
- `packages/core/src/discovery.ts`（メタデータ追加）
- `packages/cli/src/frameworks/hono/templates.ts`（Token / UserInfo エンドポイント更新）

## 仕様調査結果

**RFC 9449 - OAuth 2.0 Demonstrating Proof of Possession (DPoP)**

### DPoP の仕組み（概要）

1. クライアントが非対称鍵ペアを生成し、リクエスト毎に DPoP Proof JWT を生成する
2. Token endpoint に `DPoP: <proof_jwt>` ヘッダを付与してリクエストする
3. 認可サーバーは DPoP Proof を検証し、AT に `cnf.jkt`（公開鍵の JWK thumbprint）を埋め込む
4. Resource server は AT の `cnf.jkt` と DPoP proof の公開鍵 thumbprint が一致することで正当な所持者であることを確認する

### DPoP Proof JWT の検証（§4.3）

**ヘッダー**:
- `typ`: `dpop+jwt` であること
- `alg`: `none` 以外の非対称アルゴリズム（例: `ES256`, `PS256`）であること
- `jwk`: 送信者の公開鍵（JWK 形式）が含まれること

**ペイロード必須クレーム**:
- `jti`: リプレイ防止。短時間（推奨: ±数分）以内でユニークであること。使用済み `jti` をストアで管理し重複拒否する
- `htm`: リクエストの HTTP メソッド（Token endpoint では `POST`）と一致すること
- `htu`: リクエストの HTTP URI（Token endpoint の完全 URL）と一致すること
- `iat`: 発行時刻。サーバー時刻との許容ずれは ±60 秒推奨
- `ath`: **Resource Server 側でのみ検証**（AT のハッシュ）。Token endpoint へのリクエストでは不要

### AT の `cnf` クレーム形式（§6）

```json
{
  "cnf": {
    "jkt": "<base64url(SHA-256 of JWK canonical form)>"
  }
}
```

JWK thumbprint の計算は RFC 7638 に従う。

### Refresh Token + DPoP（§5）

refresh_token grant 時も DPoP Proof を必須とする。新しく発行する AT は新 proof の公開鍵に紐付ける。クライアントは鍵をローテーションできる。

### Discovery メタデータ

```json
{
  "dpop_signing_alg_values_supported": ["ES256", "PS256"]
}
```

### DPoP Nonce（推奨）

- DPoP Proof に `nonce` クレームがない・無効な場合、サーバーは `400 Bad Request` + `DPoP-Nonce` ヘッダーで新しい nonce を返す
- クライアントは受け取った nonce を DPoP Proof の `nonce` クレームに含めて再送する
- 本実装では初期フェーズとして nonce サポートはオプション（設定で有効化）とする

## 修正方針

### Phase 1: Core 実装

- [ ] `packages/core/src/crypto-utils.ts` に JWK thumbprint 計算ヘルパーを追加する（RFC 7638）

  ```typescript
  export async function computeJwkThumbprint(jwk: JsonWebKey): Promise<string>;
  ```

- [ ] `packages/core/src/access-token.ts` に DPoP Proof 検証関数を追加する

  ```typescript
  export async function validateDpopProof(
    proof: string,
    options: {
      htm: string;
      htu: string;
      maxClockSkewSeconds?: number;
      jtiStore: DpopJtiStore;
    }
  ): Promise<{ jwkThumbprint: string }>;

  export interface DpopJtiStore {
    has(jti: string): Promise<boolean>;
    add(jti: string, expiresAt: number): Promise<void>;
  }
  ```

  検証内容:
  1. JWT デコード
  2. `typ === 'dpop+jwt'` チェック
  3. `alg` が `none` 以外の非対称アルゴリズムチェック
  4. `jwk` ヘッダーから公開鍵を取り出し署名検証
  5. `jti` のリプレイチェック（jtiStore で管理）
  6. `htm` / `htu` の一致確認
  7. `iat` の有効期限確認
  8. JWK thumbprint を計算して返す

- [ ] `generateAccessToken` の options に `cnf?: { jkt: string }` を追加する

- [ ] `validateTokenRequest` で `dpopJwkThumbprint` オプションが渡されたとき、AT に `cnf.jkt` を付与する

- [ ] `validateTokenRequest` の refresh_token grant でも DPoP proof を検証できるよう `dpopJwkThumbprint` を受け入れる

### Phase 2: Discovery

- [ ] `ProviderMetadataConfig` に `dpopSigningAlgValuesSupported?: string[]` を追加する
- [ ] `buildProviderMetadata` で `dpop_signing_alg_values_supported` を出力する

### Phase 3: CLI テンプレート

- [ ] Token endpoint テンプレートで `DPoP` リクエストヘッダーを読み取り、存在すれば `validateDpopProof` を呼び出して thumbprint を `validateTokenRequest` に渡す
- [ ] `DpopJtiStore` の in-memory 実装をテンプレートに含め、本番は差し替え可能にする
- [ ] UserInfo endpoint テンプレートで DPoP-bound トークンの `cnf.jkt` と `DPoP` ヘッダーの public key thumbprint 一致確認を追加する

## テスト要件

- [ ] 有効な DPoP Proof 付きトークンリクエスト → `cnf.jkt` を含む AT が発行されること
- [ ] `jti` 重複 → エラーになること
- [ ] `htm` 不一致 → エラーになること
- [ ] `htu` 不一致 → エラーになること
- [ ] `iat` が古すぎる → エラーになること
- [ ] DPoP Proof なし → 通常 Bearer AT が発行されること（DPoP は optional）
- [ ] refresh_token grant で DPoP Proof 付き → 新 AT に新しい `cnf.jkt` が設定されること
- [ ] Discovery に `dpop_signing_alg_values_supported` が含まれること

## 完了条件

`pnpm --filter @maronn-openid-connect/core test` および `pnpm --filter @maronn-openid-connect/cli test` がパスすること
