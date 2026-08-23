# [P3] `request` と `request_uri` の同時指定を `invalid_request` で拒否する

## ステータス

🟡 Medium / 未着手

## 背景

OIDC Core §6.2 は「`request` と `request_uri` を同一リクエストで併用してはならない（MUST NOT）」と定める。本実装は `request`（署名付き by value）をサポートし、`request_uri`（by reference）を非サポートとしている。この非対称ゆえに、両方が同時に来ると現状は:

1. `request` object を**先にパース・マージ**（redirect_uri / scope / state 等を supersede し得る）
2. その後 `request_uri` を理由に `request_uri_not_supported` で拒否

という流れになる。最終的に拒否はされるが、(a) §6 違反である「併用」を診断していない、(b) 返るエラーコードが `invalid_request` ではなく `request_uri_not_supported` で誤誘導、(c) 信頼できない `request` object を不要に先行処理する、という問題がある。将来 `request_uri` をサポートした場合、併用チェックが無いと両方同時が**通って**しまう（優先順位不定）危険もある。

`request_uri` 単体の非対応拒否・Discovery 整合は別トピック（`study-material/request-object-rejection-and-discovery-honesty.md`）。本タスクは「併用禁止と処理順序」のみを対象とする。詳細な検討は `study-material/done/request-and-request-uri-mutual-exclusivity.md` を参照。

## 対象ファイル

- `packages/core/src/authorization-request.ts`（`validateAuthorizationRequest`）
- `packages/core/src/authorization-request.test.ts`（テスト追加）

## 仕様参照

- OpenID Connect Core 1.0 §6 / §6.2 — 「The `request` and `request_uri` parameters MUST NOT both be used in the same request.」
- OpenID Connect Core 1.0 §3.1.2.6「Authentication Error Response」

## 現状の実装

```ts
// packages/core/src/authorization-request.ts（validateAuthorizationRequest 抜粋）
// 行 714: request を先にパース
if (params.request !== undefined) {
  roClaims = await parseRequestObject(params.request, { ... });
}
// 行 749: request object claim を認可パラメータへマージ
const effective = roClaims ? mergeRequestObjectParams(params, roClaims) : { ...params };
// 行 756: マージ後の redirect_uri を登録済み URI と exact match で再検証（open-redirect は防止済み）
const redirectUri = resolveRedirectUri(effective.redirect_uri, client.redirectUris, client.clientType);
// 行 772: ここで初めて request_uri を非対応として拒否
if (params.request_uri !== undefined) {
  throw new AuthorizationError(AuthorizationErrorCode.RequestUriNotSupported, ...);
}
```

`params.request !== undefined && params.request_uri !== undefined` を §6 違反として診断する分岐が存在しない。

## 修正方針

- [ ] `request` のパース（行 714）より**前**に、併用検出分岐を追加する:
  ```ts
  // OIDC Core 1.0 §6.2: request と request_uri は同一リクエストで併用不可。
  if (params.request !== undefined && params.request_uri !== undefined) {
    throw new AuthorizationError(
      AuthorizationErrorCode.InvalidRequest,
      'request and request_uri must not be used together',
    );
  }
  ```
- [ ] state echo の有無は既存の非リダイレクトエラー方針（redirect 先が信頼できる段階に達する前は state を echo しない）に合わせる。併用は「壊れたリクエスト」寄りであり非リダイレクト invalid_request で妥当
- [ ] 併用検出を `request` パース前に置くことで、信頼できない request object の先行処理を回避する
- [ ] `study-material/request-object-rejection-and-discovery-honesty.md` に「併用禁止」を相互参照として追記
- [ ] `study-material/ext-jar-request-object-rfc9101.md` に「将来 `request_uri` 実装時は併用チェックが前提」と注記

## テスト要件

- [ ] `request` と `request_uri` の両方を指定 → `invalid_request`（メッセージ "must not be used together"）で拒否され、`request_uri_not_supported` ではない
- [ ] 併用時に不正な（パース不能な）`request` object を入れても、併用チェックが先に弾く（request object のパースエラーにならない）
- [ ] `request` のみ指定 → 従来どおり処理される（リグレッション固定）
- [ ] `request_uri` のみ指定 → 従来どおり `request_uri_not_supported`（リグレッション固定）

## 完了条件

- `pnpm --filter @maronn-openid-connect/core test` がパスすること
