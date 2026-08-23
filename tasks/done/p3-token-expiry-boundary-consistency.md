# [P3] トークン有効期限の境界条件を統一し、Opaque トークンの有効期限バインディングを整合させる

## ステータス

🟡 Medium / 未着手

## 背景

トークン有効期限まわりに 2 つの整合性問題がある。

1. **境界演算子の不一致**: 同一関数 `validateTokenRequest` 内で、認可コードは `expiresAt <= now`（同値で失効）、
   リフレッシュトークンは `expiresAt < now`（同値ではまだ有効）と境界が逆。コメントは RFC 7519 慣例（`<=`）を謳うのに
   リフレッシュ側が逆になっており、コードスメル兼タイミング起因リグレッションの温床。
2. **Opaque アクセストークンの有効期限バインディング**: Opaque トークンは自己記述的 `exp` を持たず失効は store 依存。
   一方 `expires_in`（レスポンス）と `expiresAt`（store）が別々の `Date.now()` から計算されており、
   広告した寿命と実失効がドリフトしうる。

検討の詳細は `study-material/done/token-expiry-boundary-and-opaque-lifetime-binding.md` を参照。

## 対象ファイル

- `packages/core/src/token-request.ts`（認可コード失効 L593-595、リフレッシュ失効 L493-496）
- `packages/core/src/token-request.test.ts`
- `packages/core/src/token-response.ts`（`expires_in` 算出 L371 付近、`exp` 算出 L291 付近）
- `packages/core/src/access-token-issuer.ts`（opaque issuer L66 付近）
- 生成テンプレートの token ルート（`packages/cli/src/frameworks/*/templates.ts` の `expiresAt: issuedAt + config.accessTokenExpiresIn`）

## 仕様参照

- RFC 6749 §5.1 / OAuth 2.1 §3.2.3 — `expires_in` は実際の有効期間（秒）を反映する。
  https://www.rfc-editor.org/rfc/rfc6749#section-5.1
- RFC 7519 §4.1.4 — `exp` は on-or-after で失効（`now >= exp` ⇔ `exp <= now`）。
  https://www.rfc-editor.org/rfc/rfc7519#section-4.1.4

## 現状の実装

- 認可コード（`token-request.ts:593-595`）: `if (authCode.expiresAt <= now)`（コメントも RFC 7519 慣例を明記）。
- リフレッシュ（`token-request.ts:493-496`）: `if (refreshTokenInfo.expiresAt < nowForRefresh)`（逆の境界）。
- Opaque issuer（`access-token-issuer.ts:66`）は payload（`exp` 含む）を捨ててランダム文字列のみ返す。
- `expires_in` は `token-response.ts:371` で `accessTokenExpiresIn` から、store の `expiresAt` は生成テンプレートで
  別の `Date.now()` から計算され、両者が独立。

## 修正方針

- [ ] `validateTokenRequest` の認可コード／リフレッシュの失効境界を **`expiresAt <= now`（JWT `exp` 慣例）に統一**し、
      コメントと整合させる。
- [ ] `generateTokenResponse` が算出済みの `exp`（絶対時刻、`token-response.ts:291` 付近で `now + accessTokenExpiresIn`）を
      結果に含めて返し、生成テンプレートの token ルートはその値を store の `expiresAt` として保存する（`Date.now()` 再計算をやめる）。
- [ ] あるいは（最小案）「Opaque は store レコードが有効期限の単一情報源であり、`expires_in` と必ず一致させること」を
      型 doc / 生成コードコメントに契約として明記する。どちらを採るかは実装者判断（コメントで根拠明記）。

## テスト要件

- [ ] 認可コード・リフレッシュとも、`expiresAt === now` のとき同一の判定（推奨: 失効）になることを境界秒で固定する。
- [ ] 統一後、既存の有効/失効テストが壊れないこと。
- [ ] （配線変更を採る場合）Opaque トークンで、レスポンスの `expires_in` から導かれる失効時刻と
      store の `expiresAt` が一致することを回帰で固定する。

## 完了条件

- `pnpm --filter @maronn-openid-connect/core test` がパスすること
- （配線変更時）`pnpm --filter @maronn-openid-connect/cli test` がパスすること
