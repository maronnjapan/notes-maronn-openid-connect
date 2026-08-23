# タスク: 署名鍵プロバイダーインターフェースの設計と実装

## 概要

CLIで生成したプロジェクトは起動時に1回だけ RSA 鍵ペアをエフェメラル生成する実装になっていた。
開発用途には十分だが、本番運用では「シークレットストアから鍵を取得する」「ローテーション発生時に再取得する」という要件がある。
ライブラリ側がローテーションのタイミングや再取得処理を担うのは責務が違うため、**取得ロジックを差し込めるインターフェースを提供する**ことを目的とする。

## 影響度

**中（設計）** — `signingKeyProvider` を必須パラメータとして要求することで、鍵管理の責任を明示的に利用者に委ねる。

## 設計方針（確定）

### `SigningKeyProvider` インターフェース

```typescript
// packages/core/src/signing-key.ts に定義
export interface SigningKeyProvider {
  getSigningKey(): Promise<{
    privateKey: CryptoKey;
    publicJwk: JsonWebKey;
    keyId: string;
  }>;
}
```

ローテーション対応は実装者の責任とする。ライブラリはリクエストごとに `getSigningKey()` を呼ぶだけで、「いつ再取得するか」には関与しない。

### 設計決定: `signingKeyProvider` は必須パラメータ

当初の設計ではエフェメラル生成へのフォールバックを検討したが、以下の理由で必須パラメータに変更した:

- エフェメラル鍵はサーバー再起動のたびに変わるため、RPがキャッシュした公開鍵で署名検証が失敗するリスクがある
- 「意図せず本番でエフェメラル鍵を使い続ける」事故を防ぐため、明示的な鍵設定を強制する
- `createEphemeralSigningKeyProvider` をコアに含めないことで、利用者が鍵管理を真剣に検討するよう促す

### キャッシュユーティリティ: `createCachedSigningKeyProvider`

シークレットストアへのリクエスト毎アクセスを避けるため、TTLキャッシュを提供する:

```typescript
export function createCachedSigningKeyProvider(
  base: SigningKeyProvider,
  ttlMs: number,
): SigningKeyProvider
```

### プロダクション実装例（サンプルプロジェクト）

`packages/sample/src/op/key-provider.ts` に以下の実装例を提供:

- `EnvSigningKeyProvider` — 環境変数/Cloudflare Secretsから JWK を読み込む
- `KVSigningKeyProvider` — Cloudflare KV から JWK を読み込む
- `D1SigningKeyProvider` — Cloudflare D1 から JWK を読み込む

### `CreateAppOptions` / `ApplyOidcOptions`

```typescript
export interface CreateAppOptions {
  config?: Partial<ProviderConfig>;
  signingKeyProvider: SigningKeyProvider; // 必須（フォールバックなし）
  clientResolver?: ClientResolver;
  tokenClientResolver?: TokenClientResolver;
}
```

## 実装箇所

| ファイル | 変更内容 |
|---|---|
| `packages/core/src/signing-key.ts` | `SigningKeyProvider` インターフェース、`createCachedSigningKeyProvider` の定義 |
| `packages/core/src/index.ts` | `SigningKeyProvider`、`createCachedSigningKeyProvider` のエクスポート追加 |
| `packages/cli/src/frameworks/hono/templates.ts` | `appTemplate` / `applyTemplate` を `signingKeyProvider` 必須パラメータベースに変更 |
| `packages/sample/src/op/key-provider.ts` | プロダクション向け実装例（Env / KV / D1）を提供 |

## 受け入れ条件

- [x] `SigningKeyProvider` インターフェースが `packages/core` からエクスポートされている
- [x] `createCachedSigningKeyProvider` がTTLキャッシュユーティリティとして提供されている
- [x] 生成した `app.ts` / `apply.ts` が `signingKeyProvider` を必須パラメータとして受け付ける（エフェメラルフォールバックなし）
- [x] サンプルプロジェクトに「環境変数から取得する例」（`EnvSigningKeyProvider`）と「KV/D1ストアから取得する例」が実装されている
- [x] 既存の JWKS エンドポイントおよび ID Token 署名が引き続き正しく動作する

## 参照仕様

- Web Crypto API — `SubtleCrypto.importKey()`, `SubtleCrypto.generateKey()`
- RFC 7517 (JSON Web Key)
- OIDC Core 1.0 Section 10.1 (Signing Keys)
