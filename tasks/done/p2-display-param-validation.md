# [P2] Authorization Endpoint の `display` パラメータ値を検証する

## ステータス

🟡 Minor / 未着手

## 背景

`display` パラメータは OIDC Core §3.1.2.1 で `page` / `popup` / `touch` / `wap` の 4 値のみを定義しているが、現状の `validateAuthorizationRequest` はパラメータをそのまま通過させる。未定義値を受け取った RP が期待と異なる UI を表示するケースや、Conformance テストで未定義値に対する応答が問われる可能性がある。

## 対象ファイル

- `packages/core/src/authorization-request.ts`
- `packages/core/src/authorization-request.test.ts`

## 仕様参照

- OIDC Core 1.0 §3.1.2.1: Authentication Request — `display` parameter

## 現状の実装

```ts
// packages/core/src/authorization-request.ts:555
const display = params.display;  // 値検証なし
```

## 修正方針

- [ ] 有効値の定数 `VALID_DISPLAY_VALUES` を定義する（`prompt` と同様のパターン）
- [ ] `display` が提供され、かつ有効値リストに含まれない場合は `invalid_request` エラー（redirectable）をスローする
- [ ] `display` が未指定または `undefined` の場合はそのまま通過させる（任意パラメータ）

```ts
const VALID_DISPLAY_VALUES = ['page', 'popup', 'touch', 'wap'] as const;

if (display !== undefined && !(VALID_DISPLAY_VALUES as readonly string[]).includes(display)) {
  throw new AuthorizationError(
    AuthorizationErrorCode.InvalidRequest,
    `Unsupported display value: ${display}`,
    redirectUri,
    state,
  );
}
```

## テスト要件

- [ ] `display=page` / `popup` / `touch` / `wap` は有効として通過すること
- [ ] `display=unknown` は `invalid_request` error redirect になること
- [ ] `display` 未指定の場合は影響なく通過すること

## 完了条件

`pnpm --filter @maronn-openid-connect/core test` がパスすること
