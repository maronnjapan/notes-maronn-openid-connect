# [P2] Discovery `code_challenge_methods_supported` を core の `buildProviderMetadata` で表現可能にする

## ステータス

🟡 Medium / 未着手

## 背景

本 OP は PKCE（S256）に対応しているが、Discovery メタデータの `code_challenge_methods_supported` を
**core の `buildProviderMetadata` が出力できない**。そのため CLI テンプレートと各 sample の
Discovery ルートが、`buildProviderMetadata` の戻り値へ後付けでフィールドを差し込んでいる。

```ts
// packages/cli/src/frameworks/hono/templates.ts:3590-3595（および sample 4 本の routes/discovery.ts）
// code_challenge_methods_supported is defined in OAuth 2.1 / PKCE spec,
// not in OIDC Discovery, so it is added separately.
return c.json({
  ...metadata,
  code_challenge_methods_supported: ['S256'],
});
```

問題は 2 つある。

1. **アーキテクチャ原則の破れ**: 「Provider Metadata の生成は core が単一の真実」という原則が崩れ、
   同じ後付けコードが CLI テンプレート 1 箇所と sample 4 本（`hono-cloudflare` / `express-flyio` /
   `fastify-flyio` / `nextjs-vercel`）に重複している。ドリフトの温床になる。
2. **core 単体利用者が advertise できない**: `packages/core` を直接使う組み込みユースケース
   （CLAUDE.md が想定する「高度な組み込み」）では、PKCE メソッドを一切広告できない。
   将来 `plain` を許可する／`S256` のみに固定するといった制御も core 経由で行えない。

あわせて、上記コメントの「not in OIDC Discovery」という記述は不正確である。
`code_challenge_methods_supported` は **RFC 8414 §2** が定義する Authorization Server Metadata
のフィールドであり、`discovery.ts` が既に `introspection_endpoint` などの RFC 8414 由来フィールドを
「OIDC Discovery 1.0 自体は定義しないが主要 IdP が同じ文書に載せるため」という理由で扱っているのと
同じ扱いにできる。

検討の詳細は `study-material/done/discovery-code-challenge-methods-supported.md` を参照。

> 方針について: 元の検討では「方針A（core に独立した config フィールドを追加）」と
> 「方針B（`T-021-discovery-metadata` へ統合）」の 2 案があったが、**T-021 は既に完了済み**
> （`tasks/done/T-021-discovery-metadata.md`）のため、方針 B は選択肢として成立しない。
> 本タスクは方針 A を前提とする。

## 対象ファイル

- `packages/core/src/discovery.ts`（`ProviderMetadataConfig` / `ProviderMetadata` / `buildProviderMetadata`）
- `packages/core/src/discovery.test.ts`
- `packages/cli/src/frameworks/hono/templates.ts`（Discovery ルート生成部、L3586-3596 付近）
- `packages/cli/src/frameworks/web-standard/templates.ts`（該当する Discovery ルート生成部があれば）
- `samples/*/src/oidc-provider/routes/discovery.ts`（4 本。**生成物なので直接編集せず `packages/cli` を修正して再生成する**）
- `packages/cli` 内の `conformance.test.ts` 生成コード（Discovery 応答の期待値に関わる場合）

## 仕様参照

- **RFC 8414 §2 (OAuth 2.0 Authorization Server Metadata)**:
  `code_challenge_methods_supported` — 「OPTIONAL. JSON array containing a list of PKCE code challenge
  methods supported by this authorization server.」値は IANA
  "PKCE Code Challenge Methods" レジストリの値（`plain` / `S256`）。
  https://www.rfc-editor.org/rfc/rfc8414#section-2
- **RFC 7636 §4.2 / §4.3 (PKCE)**: `code_challenge_method` の値定義（`plain` / `S256`）。
  https://www.rfc-editor.org/rfc/rfc7636#section-4.2
- **OAuth 2.1 draft §7.5.2**: AS は `S256` をサポートしなければならない（`plain` は制約付き）。
  https://datatracker.ietf.org/doc/draft-ietf-oauth-v2-1/
- **OpenID Connect Discovery 1.0 §3**: OP Metadata の定義。`code_challenge_methods_supported` 自体は
  OIDC Discovery 1.0 の定義には含まれないが、OP は追加のメタデータフィールドを載せてよい。
  https://openid.net/specs/openid-connect-discovery-1_0.html

## 現状の実装

`packages/core/src/discovery.ts` は RFC 8414 由来のフィールドを扱う前例を既に持っている。

```ts
// packages/core/src/discovery.ts:71-77
// RFC 8414 (OAuth 2.0 Authorization Server Metadata) — advertised here
// because the major IdPs put them on this same document even though
// OIDC Discovery 1.0 itself does not define them.
introspectionEndpoint?: string;
introspectionEndpointAuthMethodsSupported?: string[];
revocationEndpoint?: string;
revocationEndpointAuthMethodsSupported?: string[];
```

`code_challenge_methods_supported` だけがこの扱いから漏れており、ルート側の後付けになっている。

## 修正方針

- [ ] `ProviderMetadataConfig` に `codeChallengeMethodsSupported?: string[]` を追加する
      （RFC 8414 由来フィールドのブロックに置き、既存の `introspectionEndpoint` 等と同じコメント方針に揃える）
- [ ] `ProviderMetadata` に `code_challenge_methods_supported?: string[]` を追加する
- [ ] `buildProviderMetadata` で、値が渡され、かつ非空配列のときのみ出力する
      （既存の「空配列は省略する」方針に合わせる）
- [ ] 値の検証を入れるか判断する。**推奨**: IANA 登録値（`plain` / `S256`）以外を拒否する。
      理由は `claimTypesSupported` で既に採っている「実装していない能力を広告させない」方針との一貫性
      （`discovery.ts:215-226`）。ただし将来の新メソッド追加を塞ぐため、拒否ではなく許容とする選択肢もある
      → **どちらを採るかはレビュー時に確定する**
- [ ] CLI テンプレート（`packages/cli/src/frameworks/hono/templates.ts` ほか）の後付け
      `code_challenge_methods_supported: ['S256']` を削除し、`buildProviderMetadata` への
      config 渡し（`codeChallengeMethodsSupported: ['S256']`）へ置き換える
- [ ] 不正確なコメント（"not in OIDC Discovery"）を RFC 8414 §2 を根拠とする記述に修正する
- [ ] `samples/*` の 4 本は `packages/cli` を修正したうえで再生成して同期する（直接編集しない）
- [ ] PAR 有効時に付与される追加メタデータ（`parDiscoveryMetadata`）の合流位置が
      壊れていないことを確認する

実装イメージ:

```ts
// packages/core/src/discovery.ts
export interface ProviderMetadataConfig {
  // ...
  // RFC 8414 §2: PKCE code challenge methods supported by this AS.
  // OAuth 2.1 §7.5.2 requires S256 support, so the generated OP advertises ["S256"].
  codeChallengeMethodsSupported?: string[];
}

// buildProviderMetadata 内
if (
  config.codeChallengeMethodsSupported &&
  config.codeChallengeMethodsSupported.length > 0
) {
  metadata.code_challenge_methods_supported = config.codeChallengeMethodsSupported;
}
```

## テスト要件

TDD で、実装より先に `packages/core/src/discovery.test.ts` へ追加すること。

- [ ] `should include code_challenge_methods_supported when codeChallengeMethodsSupported is provided`
      — `['S256']` を渡すと出力が `['S256']` に一致する（`toEqual` で一意固定）
- [ ] `should omit code_challenge_methods_supported when codeChallengeMethodsSupported is not provided`
      — 未指定時にキー自体が存在しない
- [ ] `should omit code_challenge_methods_supported when an empty array is provided`
      — 空配列は省略する（既存の配列フィールドと同じ方針）
- [ ] （値検証を入れる場合）`should reject unsupported code challenge method values`
      — `['S512']` のような未登録値で `Error` を throw する
- [ ] （CLI）生成された Discovery ルートが `buildProviderMetadata` の config 経由でフィールドを出力し、
      レスポンス JSON の `code_challenge_methods_supported` が `['S256']` に一致する
- [ ] （CLI）PAR 有効時にも Discovery 応答が壊れないこと（既存 PAR メタデータのテストが回帰しない）
- [ ] 既存の Discovery テスト（`Cache-Control` / ETag / 各フィールドの有無）が回帰しない

## 完了条件

- `pnpm --filter @maronn-openid-connect/core test` がパスすること
- `pnpm --filter @maronn-openid-connect/cli test` がパスすること
- `pnpm test` 全体がパスすること
- `samples/*/src/oidc-provider/routes/discovery.ts` 4 本から後付けコードが消え、
  `packages/cli` の再生成結果と一致していること
- 各 sample の `conformance.test.ts` がパスし、Discovery 応答の
  `code_challenge_methods_supported` が従来どおり `['S256']` であること（外部から見た挙動は不変）
