# [P3] `max_age` を 10進非負整数に限定してパースする

## ステータス

🟡 Medium / 未着手

## 背景

Authorization Endpoint の `max_age` バリデーションは `Number(maxAgeValue)` に依存しており、16進 (`0x3c`)、2進 (`0b111100`)、指数表記 (`1e3`)、小数点付き (`60.0`)、前後空白 (`" 60 "`)、先頭 `+` (`+60`) を「非負整数」として受理してしまう。`max_age` は Basic OP 必須の認証リクエストパラメータで、OIDC Core は「Number of seconds」を表す 10進非負整数文字列を想定する。想定外形式を黙って解釈すると、送信側のバグやプロキシ書き換えを検知できない。

詳細な検討は `study-material/done/authorization-max-age-decimal-integer-strictness.md` を参照。`=0` 境界（`study-material/done/max-age-zero-reauthentication-boundary.md`）や DCR フォールバックとは別軸。

## 対象ファイル

- `packages/core/src/authorization-request.ts`（`validateMaxAge`）
- `packages/core/src/authorization-request.test.ts`（テスト追加）

## 仕様参照

- OpenID Connect Core 1.0 §3.1.2.1（`max_age` は「Number of seconds」） : https://openid.net/specs/openid-connect-core-1_0.html#AuthRequest
- ECMAScript `Number()` の文字列変換（16進・指数・空白トリムを受理する根拠）: https://tc39.es/ecma262/#sec-tonumber-applied-to-the-string-type

## 現状の実装

```ts
// packages/core/src/authorization-request.ts
function validateMaxAge(maxAgeValue: string, redirectUri: string, state?: string): number {
  const num = Number(maxAgeValue);                                    // L531
  if (!Number.isFinite(num) || !Number.isInteger(num) || num < 0) {   // L533
    throw new AuthorizationError(AuthorizationErrorCode.InvalidRequest, 'max_age must be a non-negative integer', redirectUri, state);
  }
  return num;
}
```

`0x3c` / `0b111100` / `1e3` / `60.0` / `" 60 "` / `+60` がすべて有限整数に変換され通過する。既存テスト（`authorization-request.test.ts:944-987` 付近）は `'3600'` / `'0'` / `'abc'` / 負値のみ。

## 修正方針

- [ ] `validateMaxAge` の先頭に 10進非負整数の正規表現ガードを追加（study-material 方針A）
  ```ts
  if (!/^\d+$/.test(maxAgeValue)) {
    throw new AuthorizationError(AuthorizationErrorCode.InvalidRequest, 'max_age must be a non-negative integer', redirectUri, state);
  }
  const num = Number(maxAgeValue);
  ```
- [ ] `Number.MAX_SAFE_INTEGER` を超える桁数の扱い（上限を設けるか）を判断する（study-material 方針C。過剰仕様なら見送り）

## テスト要件

- [ ] `0x3c` / `0b111100` / `1e3` / `60.0` / `" 60 "` / `+60` が `invalid_request` になる
- [ ] 既存の `'3600'` / `'0'` が引き続き通る（リグレッション無し）
- [ ] 生成 OP の挙動が変わるため、必要なら `samples/*/conformance.test.ts`（生成元 `packages/cli`）に固定テストを追加

## 完了条件

- `pnpm --filter @maronn-openid-connect/core test` がパスすること
