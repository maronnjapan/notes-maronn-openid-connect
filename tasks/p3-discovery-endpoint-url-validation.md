# [P3] Discovery メタデータの全エンドポイント URL を issuer と同等に検証する

## ステータス

🟢 Low / 未着手

## 背景

`buildProviderMetadata`（`packages/core/src/discovery.ts`）は `issuer` に対してのみ
`validateIssuer` で「有効な URL」「https（localhost 例外）」「クエリ無し」「フラグメント無し」を検証している。
一方で `authorization_endpoint` / `token_endpoint` / `jwks_uri` / `userinfo_endpoint` /
`registration_endpoint` / `introspection_endpoint` / `revocation_endpoint` は **存在チェック（truthy）のみ**で、
URL 妥当性・スキーム・フラグメント有無を検証していない。

その結果、`http://`（非 TLS）の token endpoint や、フラグメント付き・壊れた URL がそのまま
Discovery ドキュメントに公開されうる。OIDC Discovery 1.0 §3 は `jwks_uri` / `userinfo_endpoint` の
**https を MUST** とし、Core 1.0 は Authorization/Token Endpoint の TLS を必須とする。issuer だけ厳格で
他エンドポイントが無検証という非対称は、利用者の設定ミス（localhost → 本番昇格時の http 残存、URL タイポ）を
早期検出できない品質課題。

詳細な検討は `study-material/done/discovery-endpoint-url-validation.md` を参照。

## 対象ファイル

- `packages/core/src/discovery.ts`（`buildProviderMetadata` / 新規 `validateEndpointUrl` ヘルパー）
- `packages/core/src/discovery.test.ts`（テスト追加）
- 必要に応じて `packages/cli` のデフォルト config テンプレート（http を吐かないことの確認）

## 仕様参照

- OpenID Connect Discovery 1.0 §3「OpenID Provider Metadata」
  - `jwks_uri`: 「This URL MUST use the `https` scheme」
  - `userinfo_endpoint`: 「This URL MUST use the `https` scheme and MAY contain port, path, and query parameter components」
  - `authorization_endpoint` / `token_endpoint`: OP のエンドポイント URL（絶対 URL 前提）
- RFC 8414 §2 / §3.2: 各エンドポイントは URL であること
- OpenID Connect Core 1.0 §3.1.2.1 / §3.1.3.1: Authorization/Token Endpoint は TLS（https）必須

## 現状の実装

```ts
// packages/core/src/discovery.ts（buildProviderMetadata 抜粋）
validateIssuer(config.issuer);             // ← issuer のみ厳格に検証

if (!config.authorizationEndpoint) {       // ← 存在チェックのみ
  throw new Error('authorizationEndpoint is required');
}
if (!config.tokenEndpoint) { ... }         // ← 同上
if (!config.jwksUri) { ... }               // ← 同上（https MUST だが未検証）
// userinfo/registration/introspection/revocation はそのまま出力（URL 検証なし）
```

`validateIssuer` は issuer 用にクエリ禁止まで含むため、クエリを許容すべき
`authorization_endpoint` / `userinfo_endpoint` にそのまま流用はできない点に注意。

## 修正方針

- [ ] `validateEndpointUrl(fieldName, value, { requireHttps, forbidQuery, forbidFragment })` を
  `discovery.ts` に新設し、`validateIssuer` のロジック（parse 可能 / https（localhost 例外）/ フラグメント）を再利用する
- [ ] `buildProviderMetadata` で各エンドポイントを検証する
  - `jwks_uri` / `userinfo_endpoint`: `requireHttps: true`, `forbidFragment: true`, `forbidQuery: false`
  - `authorization_endpoint` / `token_endpoint`: `requireHttps: true`, `forbidFragment: true`, `forbidQuery: false`
  - `registration_endpoint` / `introspection_endpoint` / `revocation_endpoint`: 存在時に `requireHttps: true`, `forbidFragment: true`
  - localhost / 127.0.0.1 は既存 `validateIssuer` と同様に https 例外とする
- [ ] 既存テスト・サンプル config に http エンドポイントが含まれていないか確認し、必要なら localhost / https に修正する

```ts
// 例
function validateEndpointUrl(
  name: string,
  value: string,
  opts: { forbidQuery?: boolean } = {},
): void {
  let url: URL;
  try { url = new URL(value); } catch { throw new Error(`${name} must be a valid URL: ${value}`); }
  const isLocal = url.hostname === 'localhost' || url.hostname === '127.0.0.1';
  if (url.protocol !== 'https:' && !isLocal) throw new Error(`${name} must use https scheme (except localhost)`);
  if (opts.forbidQuery && url.search) throw new Error(`${name} must not contain query parameters`);
  if (url.hash) throw new Error(`${name} must not contain a fragment`);
}
```

## テスト要件

- [ ] 非 https の `token_endpoint` / `jwks_uri` / `userinfo_endpoint` を拒否すること
- [ ] フラグメント付きエンドポイント URL を拒否すること
- [ ] クエリ付き `authorization_endpoint` / `userinfo_endpoint` は許容すること
- [ ] `localhost` / `127.0.0.1` のエンドポイントは許容すること
- [ ] パース不能な文字列（相対 URL / 非 URL）を拒否すること
- [ ] 正常な https 設定では従来どおり metadata を構築できること（リグレッション無し）

## 完了条件

`pnpm --filter @maronn-openid-connect/core test` がパスすること
