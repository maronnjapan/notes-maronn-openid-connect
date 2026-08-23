# [P3] `registration` リクエストパラメータを `registration_not_supported` で明示的に拒否する

## ステータス

🟢 Low / 未着手

## 背景

OIDC Core §3.1.2.1 は `registration` リクエストパラメータ（Self-Issued OP が RP メタデータを認可リクエストに同梱するためのもの、§7.2.1）を定義している。本実装はこの機能を持たないため、§3.1.2.6 に従い `registration_not_supported` エラーを返すべきだが、現状は**黙殺**している。

これは `request` / `request_uri` → `request_not_supported` / `request_uri_not_supported`（`study-material/request-object-rejection-and-discovery-honesty.md`）と**同じ §3.1.2.6 の「未対応パラメータ明示拒否」パターン**であり、3 兄弟のうち `registration` だけがこれまでの議論から漏れていた。Basic OP の必須テスト対象ではないが、本 OSS の Fidelity 軸（仕様忠実性）とパラメータ汚染の排除に資する。

検討の全体は `study-material/done/unsupported-request-parameter-registration.md` を参照。

## 対象ファイル

- `packages/core/src/authorization-request.ts`
- `packages/core/src/authorization-request.test.ts`

## 仕様参照

- OIDC Core 1.0 §3.1.2.1: `registration` パラメータの定義（SHOULD only be used when ... passed in the request itself）
- OIDC Core 1.0 §3.1.2.6: `registration_not_supported` を含む認可エラー応答（redirect_uri へ state 付きで返す）
- OIDC Core 1.0 §7 / §7.2.1: Self-Issued OP における `registration` の本来のユースケース

## 現状の実装

```ts
// packages/core/src/authorization-request.ts:12
export enum AuthorizationErrorCode {
  // ... request_not_supported / request_uri_not_supported / registration_not_supported はいずれも未定義
}

// AuthorizationRequestParams に registration フィールドは無く、
// validateAuthorizationRequest 本体でも registration を参照していない（= 黙殺）
```

リダイレクト可能エラーの送出区間は確立済み（`authorization-request.ts` 行 566 以降「Phase 3 以降はリダイレクト可能エラー」）。`registration` 検知はこの区間に 1 分岐を足すだけで成立する。

## 修正方針

- [ ] `AuthorizationErrorCode` に `RegistrationNotSupported = 'registration_not_supported'` を追加する
- [ ] redirect_uri 解決後（Phase 3 区間）に `registration` パラメータの存在を検知し、`registration_not_supported`（redirectable, state 付き）を throw する
- [ ] `registration` 未指定時は従来通り影響なく通過させる
- [ ] （推奨）`request` / `request_uri` の拒否（`study-material/request-object-rejection-and-discovery-honesty.md`）と同時実装する場合は、3 兄弟を 1 つの「未対応パラメータ検知ブロック」にまとめる

```ts
// 例: Phase 3 区間（redirect_uri 解決後）
if (params.registration !== undefined) {
  throw new AuthorizationError(
    AuthorizationErrorCode.RegistrationNotSupported,
    'registration parameter is not supported',
    redirectUri,
    state,
  );
}
```

## テスト要件

- [ ] `registration` を含む認可リクエストが `registration_not_supported` の redirect error になること
- [ ] エラー redirect に `state` がそのまま含まれること
- [ ] `registration` 未指定のリクエストは従来通り正常処理されること（リグレッションなし）

## 完了条件

- `pnpm --filter @maronn-openid-connect/core test` がパスすること
- `study-material/basic-op-requirement-traceability.md` §6.5 に `registration` 行が追加され状態が更新されていること
