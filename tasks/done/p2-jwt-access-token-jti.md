# [P2] JWT Access Token への `jti` 付与

## ステータス

🟢 完了（2026-08-03）

`tasks/done/p1-token-value-uniqueness-and-refresh-idtoken-iat.md` の実装に統合して完了した。
RFC 9068 §2.2 の `jti` は `buildAccessTokenPayload` が発行ごとに生成し、生成 OP が
ストアへ保存するため Introspection のレスポンスにも現れる。

> **統合先あり**: 本タスクの実装内容は
> `tasks/p1-token-value-uniqueness-and-refresh-idtoken-iat.md` に包含される。
> あちらは同じ `jti` 付与を「同一秒の再発行で JWT アクセストークンがバイト同一になり、
> `accessTokenStore` のキー衝突で grant 単位失効が取りこぼす」というセキュリティ影響を
> 動機として扱う（実測確認済み）。**2 度実装しないよう、P1 側に統合して実施すること。**
> 本タスクは RFC 9068 §2.2 準拠という観点の記録として残す。

## 背景

RFC 9068 の JWT access token profile では `jti` は required claim として定義されている。現状の JWT access token には `jti` が含まれておらず、Introspection 用の `AccessTokenInfo.jti` も活用されていない。

## 対象ファイル

- `packages/core/src/access-token.ts`
- `packages/core/src/token-response.ts`
- `packages/core/src/introspection.ts`
- `packages/core/src/token-response.test.ts`

## 仕様参照

- RFC 9068 §2.2: JWT Access Token Claims
- RFC 7519 §4.1.7: `jti`

## 現状の実装

- Access Token payload 型に `jti` が無い
- `generateTokenResponse()` は JWT 発行時に `jti` を生成していない
- `AccessTokenInfo` には `jti?: string` があるが保存されていない

## 修正方針

- [x] JWT access token 発行時に `jti` を生成する
- [x] payload / ストア metadata / introspection で同じ `jti` を参照できるようにする
- [x] `generateTokenResponse()` の返り値だけでは `jti` を呼び出し側へ返せないため、内部メタデータ伝播方法を見直す
      → `GenerateTokenResponseResult.accessTokenJti` を追加した（`resolvedAcr` / `resolvedAmr` と同じ扱い）
- [x] opaque access token への適用有無は別途切り分け、まず JWT access token を仕様準拠させる
      → opaque は元から 256bit の CSPRNG 文字列で一意なため、トークン値自体の変更は不要。
      `buildAccessTokenPayload` が返す `jti` はストア metadata として保存され、
      opaque でも Introspection が `jti` を返せる

## テスト要件

- [x] JWT access token payload に `jti` が含まれること
- [x] `accessTokenStore.set()` される情報に `jti` が保存されること
- [x] introspection が `jti` を返せること
- [x] 同一発行で `jti` が空にならないこと

## 完了条件

`pnpm --filter @maronn-openid-connect/core test` がパスすること
