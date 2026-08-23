# [P3] `ui_locales` / `claims_locales` を AuthTransaction に保持する

## ステータス

🟢 Minor / 未着手

## 背景

Authorization Request の `ui_locales` / `claims_locales` は `validateAuthorizationRequest` でパースされ `ValidatedAuthorizationRequest` には格納されるが、`createAuthTransaction` が `AuthTransaction` へ転記していないため、後続のログイン UI・同意画面・クレーム生成からこれらの値を参照できない。

同じ OP 側ヒント系の `login_hint` は `AuthTransaction` に保持されており、`ui_locales` / `claims_locales` だけが落ちているのは非対称。OIDC Core 上これらは OPTIONAL（OP は MAY で尊重）だが、Discovery で `ui_locales_supported` を広告する場合（`study-material/discovery-optional-metadata-fields.md`）に「広告はするが実際にはリクエスト値を消費できない」不整合を生む。OSS 利用者が多言語ログイン UI を実装する際の入口を整えるための、低リスクな局所改善。

検討経緯は `study-material/done/ui-claims-locales-auth-transaction-handling.md` を参照（方針 A を採用。`claims_locales` のクレーム値 i18n＝方針 C は別トピックとして本タスク対象外）。

## 対象ファイル

- `packages/core/src/auth-transaction.ts`（`AuthTransaction` 型定義 + `createAuthTransaction` の転記処理）
- `packages/core/src/auth-transaction.test.ts`（テスト追加）

## 仕様参照

- OIDC Core 1.0 §3.1.2.1: `ui_locales`（ログイン/同意 UI 表示言語、OP は MAY で尊重、未対応でもエラーにしない）
- OIDC Core 1.0 §5.2: `claims_locales`（クレーム値の優先言語）

## 現状の実装

```ts
// packages/core/src/auth-transaction.ts（AuthTransaction 型、抜粋）
nonce?: string;       // L95
maxAge?: number;      // L99
acrValues?: string;   // L100
loginHint?: string;   // L101
// uiLocales / claimsLocales は存在しない

// createAuthTransaction の転記（抜粋）
if (validatedRequest.loginHint !== undefined) {   // L209-210
  transaction.loginHint = validatedRequest.loginHint;
}
// uiLocales / claimsLocales の転記が無い
```

`ValidatedAuthorizationRequest` 側には `uiLocales` / `claimsLocales`（`authorization-request.ts` L158-159, L597-598）が既に存在するため、転記するだけでよい。

## 修正方針

- [ ] `AuthTransaction` 型に以下を追加する

  ```ts
  /** OIDC Core 1.0 §3.1.2.1: ログイン/同意 UI の優先言語（BCP47, スペース区切り）。OP は MAY で尊重 */
  uiLocales?: string;
  /** OIDC Core 1.0 §5.2: クレーム値の優先言語（BCP47, スペース区切り） */
  claimsLocales?: string;
  ```

- [ ] `createAuthTransaction` で `login_hint` と同じパターンで転記する

  ```ts
  if (validatedRequest.uiLocales !== undefined) {
    transaction.uiLocales = validatedRequest.uiLocales;
  }
  if (validatedRequest.claimsLocales !== undefined) {
    transaction.claimsLocales = validatedRequest.claimsLocales;
  }
  ```

- [ ] core はパススルーのみとし、実際の言語選択ロジックは利用者の UI に委ねる（値の変形・検証は行わない）。

## テスト要件

- [ ] `ui_locales` / `claims_locales` を含む認可リクエストから `createAuthTransaction` した結果に、当該値がそのまま保持されること
- [ ] `ui_locales` / `claims_locales` 未指定時は `AuthTransaction` の該当フィールドが `undefined` であること
- [ ] 既存の `login_hint` / `acr_values` 等の転記が回帰していないこと

## 完了条件

`pnpm --filter @maronn-openid-connect/core test` がパスすること
