# [P3] Discovery の `token_endpoint_auth_methods_supported` を OP の実サポート方式に一致させる

## ステータス

✅ 完了（2026-07-21）

## 背景

`buildProviderMetadata` は `tokenEndpointAuthMethodsSupported` が未設定だと Discovery 文書から
`token_endpoint_auth_methods_supported` を省略する。RFC 8414 §2 / OIDC Discovery §3 では省略時の**既定値は
`client_secret_basic` のみ**と解釈される。しかし本 OP の Token Endpoint（`client-auth.ts`）は
`client_secret_basic` / `client_secret_post` / `none` の 3 方式を受理するため、省略すると実サポートを過少広告し、
`client_secret_post` / `none` で登録したクライアントが Discovery からその方式の利用可否を判断できない。

Discovery は「広告した方式 == 実際に使える方式」であることが望ましい（Fidelity）。
検討詳細は `study-material/done/discovery-token-endpoint-auth-methods-default-fidelity.md` を参照。

## 対象ファイル

- `packages/cli` 内の生成テンプレート（Discovery 用の `ProviderMetadataConfig` を組み立てる箇所）
- `packages/core/src/discovery.ts`（挙動確認。基本は変更不要）
- `packages/core/src/discovery.test.ts` / 各 sample の Discovery 期待値（conformance.test.ts 生成元）

## 仕様参照

- RFC 8414 §2: `token_endpoint_auth_methods_supported` を省略した場合の既定は `client_secret_basic`
- OpenID Connect Discovery 1.0 §3: 同上
- OpenID Connect Core 1.0 §9: クライアント認証方式（basic / post / none）

## 現状の実装

```ts
// packages/core/src/discovery.ts
if (config.tokenEndpointAuthMethodsSupported && config.tokenEndpointAuthMethodsSupported.length > 0) {
  metadata.token_endpoint_auth_methods_supported = config.tokenEndpointAuthMethodsSupported;
}
// 未設定なら省略 → RFC 8414 の既定 client_secret_basic のみと解釈される

// client-auth.ts は client_secret_basic / client_secret_post / none を受理（既定は client_secret_basic）
```

## 修正方針

- [ ] CLI 生成テンプレート（各フレームワーク）が Discovery 用 config に
  `tokenEndpointAuthMethodsSupported: ['client_secret_basic', 'client_secret_post', 'none']`（実サポートに一致）を
  明示設定しているか確認し、していなければ設定する
- [ ] `none` を広告する場合、public client の前提（PKCE 必須等）が崩れないことを確認する
- [ ] core 側は基本変更不要（未設定時に実サポートへ補完する責務は core に持たせない方針）

## テスト要件

- [ ] Discovery 出力の `token_endpoint_auth_methods_supported` が実サポート 3 方式と一致すること
- [ ] 各 sample の Discovery（conformance.test.ts 生成元を更新）で広告方式が実サポートと一致することを固定
- [ ] `client_secret_post` / `none` で登録したクライアントの Token Endpoint 認証が引き続き成功すること（回帰）

## 完了条件

- `pnpm test`（core および該当 sample）がパスすること
