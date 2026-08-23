# [P3] ID Token の単一 audience／`azp` 不付与設計をコメントと回帰テストで固定する

## ステータス

🟢 Minor / 完了（PR #118 レビューで方針変更）

> **追記（PR #118 レビュー反映）**: 当初は「単一 audience 固定・azp 不付与」をコメントと回帰テストで*凍結*する方針だったが、レビューで「元の実装（aud を単一値ハードコード）が間違い。aud は配列も想定すべきなので配列ケースも考えて実装を修正する」方針に変更した。
>
> `token-response.ts` の発行ロジックを `buildIdTokenAudience({ clientId, additional })` ヘルパに置き換え、ID Token の `aud` が配列も取れるようにした。デフォルト（`idTokenAudiences` 未指定）では `aud = clientId`（単一文字列）・`azp` 不付与で従来どおり（Basic OP 挙動は不変）。`TokenResponseOptions.idTokenAudiences` に追加 audience を渡すと `aud = [clientId, ...]` の配列となり、複数値のとき OIDC Core §3.1.3.7 (4-5) に従い `azp = clientId` を自動付与する。これにより「将来 aud を複数化したとき azp 付与を忘れる」事故余地を、凍結ではなく発行ロジック自体で解消した。

## 背景

`packages/core/src/token-response.ts` は ID Token を発行する際に `idTokenPayload.aud = clientId`（単一値文字列）でハードコードしており、`azp` クレームは付与しない。これは OIDC Core 1.0 §2 informational の "SHOULD NOT add azp when single audience equals the authorized party" に整合した意図的な設計判断である。

しかし、現状コード上に**意図のコメントが無く**、将来の改変（例: Resource Indicators 拡張で `aud` を複数化する変更）で `azp` 自動付与を忘れると、OIDC Core §3.1.3.7 (4–5) に違反する ID Token を発行する事故が起きうる。

また、検証側 `validatePayload` は `aud` 複数値のとき `azp` を必須にする厳格な実装になっており、**発行側と検証側の非対称**（発行は単一固定、検証は複数想定）の意図も明文化されていない。

関連: `study-material/done/id-token-azp-claim-policy.md`（本タスクの根拠）、`study-material/ext-resource-indicators-rfc8707.md`（aud 複数化が議論される将来トピック）、`tasks/p1-jwt-access-token-aud-default.md`（別文脈の Access Token aud）。

## 対象ファイル

- `packages/core/src/token-response.ts`（ID Token 発行ブロック）
- `packages/core/src/token-response.test.ts`
- `packages/core/src/id-token.ts`（`validatePayload` の `azp` 検証コメント）

## 仕様参照

- OpenID Connect Core 1.0 §2 — `aud` REQUIRED, `azp` OPTIONAL
  https://openid.net/specs/openid-connect-core-1_0.html#IDToken
  - "aud REQUIRED — Audience(s) that this ID Token is intended for. It MUST contain the OAuth 2.0 client_id of the Relying Party as an audience value. It MAY also contain identifiers for other audiences. ..."
  - "azp OPTIONAL — Authorized party — the party to which the ID Token was issued. If present, it MUST contain the OAuth 2.0 Client ID of this party. ... It is needed when the ID Token has a single audience value and that audience is different than the authorized party. It MAY be included even when the authorized party is the same as the sole audience."
- OpenID Connect Core 1.0 §3.1.3.7 (4–5) — RP 側の `aud` / `azp` 検証要件
  https://openid.net/specs/openid-connect-core-1_0.html#IDTokenValidation

## 現状の実装

```ts
// packages/core/src/token-response.ts（抜粋）
idTokenPayload.iss = issuer;
idTokenPayload.sub = subject;
idTokenPayload.aud = clientId;   // 単一文字列固定。設計コメントなし
idTokenPayload.exp = now + idTokenExpiresIn;
idTokenPayload.iat = now;
// azp は設定しない（設計コメントなし）
```

```ts
// packages/core/src/id-token.ts（validatePayload, 抜粋）
// azp validation: required when aud has multiple values
if (Array.isArray(payload.aud) && payload.aud.length > 1) {
  if (!payload.azp) {
    throw new Error('azp is required when aud contains multiple values');
  }
  // ...
}
```

問題点:

- 「単一 audience 固定」「`azp` 不付与」が設計判断だとコード上から読み取れない
- 検証側のみ複数 audience を想定する非対称性の意図が記録されていない
- 発行 ID Token の `aud`/`azp` 形状を保証する回帰テストが無く、将来の改変で気づかず仕様違反になる余地がある

## 修正方針

- [ ] `token-response.ts` の `idTokenPayload.aud = clientId` の上に、OIDC Core §2 引用付きの設計コメントを追加する（単一 audience 固定、`azp` を出さない理由）
- [ ] `id-token.ts` の `validatePayload` の `azp` 検証ブロックに「発行は単一 audience 固定だが、`id_token_hint` や外部 ID Token 受信は複数 audience を想定」のコメントを追加
- [ ] `token-response.test.ts` に発行 ID Token の `aud`/`azp` 形状を固定する回帰テストを追加
  - `aud` は文字列であり `clientId` と一致する
  - `aud` が配列ではない（`Array.isArray(decoded.aud) === false`）
  - `azp` クレームが存在しない（`'azp' in decoded === false`）

実装例（コメント）:

```ts
// OIDC Core 1.0 §2: ID Token の aud は単一値（clientId）として固定発行する。
// 単一 audience かつ authorized party が同一の場合、azp は SHOULD NOT include 推奨に従い
// 含めない。aud を複数値に拡張する場合（Resource Indicators 等の将来拡張）は
// `study-material/done/id-token-azp-claim-policy.md` に従い azp = clientId を自動付与すること。
idTokenPayload.aud = clientId;
```

```ts
// validatePayload 内
// 発行側は単一 audience（aud = clientId）固定だが、id_token_hint や Federation 経由で
// 受け取る外部 ID Token は複数 audience を持つ可能性があるため、検証側のみ複数値を扱う。
// OIDC Core 1.0 §3.1.3.7 (4–5) 準拠。
if (Array.isArray(payload.aud) && payload.aud.length > 1) {
  // ...
}
```

## テスト要件

- [ ] `token-response.test.ts` に新規 describe `ID Token aud/azp shape (single-audience design)` を追加
- [ ] 発行された ID Token の `decoded.aud` が文字列であり、`clientId` と一致する
- [ ] 発行された ID Token に `azp` クレームが**含まれない**（`Object.prototype.hasOwnProperty.call(decoded, 'azp') === false`）
- [ ] `aud` が `Array.isArray` で false（配列にならない）
- [ ] 既存の `validatePayload` の `azp` テスト群はリグレッションなく通る

## 完了条件

- 上記テストがすべて通る
- `pnpm --filter @maronn-openid-connect/core test` がパスする
- `token-response.ts` および `id-token.ts` の設計コメントが OIDC Core §2 / §3.1.3.7 引用付きで明記されている
- `study-material/done/id-token-azp-claim-policy.md` から本タスクへの参照が辿れる
