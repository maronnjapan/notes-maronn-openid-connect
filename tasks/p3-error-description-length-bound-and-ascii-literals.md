# [P3] `error_description` に長さ上限を課し、保証範囲の明文化と非 ASCII リテラルの排除を行う

## ステータス

🟢 Low / 未着手

## 背景

core の各バリデーション関数は、**リクエスト由来の値をそのまま `error_description` に埋め込む**。
攻撃者が完全に制御できる反射は次の 8 箇所ある。

| ファイル:行 | 埋め込む値 |
|---|---|
| `packages/core/src/authorization-request.ts:541` | `prompt` の各値 |
| `packages/core/src/authorization-request.ts:662` | `code_challenge_method` |
| `packages/core/src/authorization-request.ts:966` | `response_type` |
| `packages/core/src/authorization-request.ts:980` | `response_type` |
| `packages/core/src/authorization-request.ts:1077` | `display` |
| `packages/core/src/refresh-token-grant.ts:160` | 要求 scope の超過分 |
| `packages/core/src/token-request.ts:416` | `grant_type` |
| `packages/core/src/token-request.ts:468` | `grant_type` |

埋め込まれた値は `sanitizeErrorDescription`（`packages/core/src/error-utils.ts:14-26`）を
通ってから、認可エラーの redirect URL クエリ／JSON ボディ／`WWW-Authenticate` ヘッダ／
HTML エラーページの 4 経路へ出る。

`sanitizeErrorDescription` は **文字集合しか制限していない**。ここから 3 つの問題が出る。

### (1) 長さ上限が無い

RFC 6749 Appendix A.8 は `error-description = 1*NQSCHAR` と定めるだけで、
**上限を課していない**。実装側にも上限が無いため、
攻撃者が 100KB の `response_type` を送れば 100KB の `error_description` が返る。

実害:

- **エラーリダイレクトが届かなくなる**。認可エラーは RFC 6749 §4.1.2.1 により
  redirect URI の query に載る。URL が長すぎるとブラウザ・プロキシ・
  RP 側ミドルウェアに拒否され、「エラーを伝える仕組みがエラーを伝えられなくなる」。
- **RP 側ログの増幅**。攻撃者は 1 リクエストで RP のログへ任意 ASCII を大量に書き込める。

### (2) `sanitize` という名前が HTML 安全性を含意する

RFC 6749 §5.2 の許容集合 `%x20-21 / %x23-5B / %x5D-7E` は
`"`（0x22）と `\`（0x5C）を除外するが、
**`<`（0x3C）／`>`（0x3E）／`&`（0x26）／`'`（0x27）はすべて通す**。

既定ビュー `defaultErrorPage` は `escapeHtml` を通しているため
**現状 XSS は成立しない**（`tasks/done/p2-generated-views-html-escaping-consistency.md` の成果）。
しかし本リポジトリはビューの差し替えを明示的に推奨しており、
「core が sanitize しているから安全だろう」と誤解した利用者が
独自ビューでエスケープを省くと即座に XSS になる。
JSDoc にこの限界が書かれていないことが問題である。

### (3) OP 自身の文言に非 ASCII が混ざっている

`packages/core/src/authorization-request.ts:437`:

```ts
`Registered redirect_uri must use https:// or loopback http:// — got ${uri}`
```

この em dash（`—`, U+2014）は非 ASCII なので `?` に置換され、
クライアントには `... loopback http:// ? got ...` が届く。
RFC 6749 §5.2 が "Human-readable ASCII text" と定めている以上、
**非 ASCII を落とすこと自体は正しい**。問題は OP 側がそれを書いてしまっていることで、
これはテストで防げる。

### 本タスクのスコープ

- (1) の **長さ上限の導入**（上限値の決定を含む）
- (2) の **保証範囲の明文化**
- (3) の **非 ASCII リテラルの排除とテストによる固定**

**スコープ外**: 反射そのものをやめて固定文言化する案
（`study-material/done/error-description-input-reflection-and-length-bound.md` §7 方針C）。
RFC 6749 §5.2 が `error_description` の目的を
"used to assist the client developer in understanding the error that occurred" と
明記しており、反射をやめるとデバッグ体験を大きく損なう。
実害が小さい（同ファイル §4.6）ことも踏まえ、採否は検討段階のまま残す。

## 対象ファイル

- `packages/core/src/error-utils.ts`
- `packages/core/src/error-utils.test.ts`
- `packages/core/src/authorization-request.ts`（:437 の非 ASCII リテラル）
- `packages/cli/src/frameworks/hono/templates.ts`（生成 `views.ts` の `Views` JSDoc）
- `packages/cli/src/__tests__/hono-generator.test.ts`
- `samples/*/conformance.test.ts`（生成物。生成元は `packages/cli`）

## 仕様参照

- **RFC 6749 §5.2 Error Response**
  <https://datatracker.ietf.org/doc/html/rfc6749>
  - 逐語:
    > **error_description** — OPTIONAL. Human-readable ASCII [USASCII] text providing
    > additional information, **used to assist the client developer in understanding the error
    > that occurred.** Values for the "error_description" parameter MUST NOT include characters
    > outside the set %x20-21 / %x23-5B / %x5D-7E.
  - → 目的は **クライアント開発者のデバッグ支援**。文字集合は MUST、**長さ上限は無い**
- **RFC 6749 Appendix A.8 / Appendix A（共通定義）**
  - `error-description = 1*NQSCHAR`
  - `NQSCHAR = %x20-21 / %x23-5B / %x5D-7E`
  - → `<` `>` `&` `'` はすべて許容集合の中にある（HTML 安全性は保証されない）
- **RFC 6749 §4.1.2.1 Error Response**
  - 認可エラーは redirect URI の **query component** に載る → URL 長に直結する
- **RFC 6750 §3 The WWW-Authenticate Response Header Field**
  <https://datatracker.ietf.org/doc/html/rfc6750>
  - `error_description` は quoted-string（RFC 7230 §3.2.6）→ `"` `\` の除外が必要
- **RFC 9700（OAuth 2.0 Security BCP）**
  <https://datatracker.ietf.org/doc/html/rfc9700>
  - 未認証エンドポイントの濫用耐性（反射による増幅の抑制）

## 現状の実装

`packages/core/src/error-utils.ts:14-26`:

```ts
export function sanitizeErrorDescription(value: string): string {
  let result = '';
  for (let i = 0; i < value.length; i++) {
    const code = value.charCodeAt(i);
    const allowed =
      code === 0x20 || code === 0x21 ||
      (code >= 0x23 && code <= 0x5b) ||
      (code >= 0x5d && code <= 0x7e);
    result += allowed ? value[i] : '?';
  }
  return result;
}
```

- 長さ上限が無い（入力 1MB なら出力も 1MB）
- 不許可文字は `?` に**置換**（除去ではない）→ 長さが変わらないため増幅が抑えられない
- `<` `>` `&` `'` は通す

この関数は `AuthorizationError` / `TokenError` / `UserInfoError` / `RevocationError` /
`IntrospectionError` / `ParError` / `TokenExchangeError` の **すべてのコンストラクタ**が
通っているため、**1 箇所の変更で全経路に効く**。

## 修正方針

- [ ] `packages/core/src/error-utils.ts`
  - [ ] `MAX_ERROR_DESCRIPTION_LENGTH` を定義し、export する
    - **値は実装者が決める。本タスクは 256 を出発点として提示するのみ**
    - 根拠として書くべきこと: redirect URL の実務上の余裕（一般的なミドルウェアの
      4KB〜8KB 上限に対して十分小さい）／`WWW-Authenticate` ヘッダに載せても問題ない大きさ／
      RFC には根拠が無く運用パラメータとして選ぶこと
  - [ ] `sanitizeErrorDescription` の末尾で上限を超えた分を切り詰める
    - 置換で長さは変わらないため、**文字集合の正規化 → 切り詰め**の順にする
    - 切り詰めた印を付けるかは実装者が決める（付ける場合も上限内に収めること）
  - [ ] JSDoc に次を明記する
    - この関数は **RFC 6749 §5.2 の charset 制約のみ**を満たす
    - `<` `>` `&` `'` は許容集合内であり **HTML 安全性は保証しない**。
      HTML 文脈では呼び出し側が別途エスケープすること
    - 不許可文字を `?` に置換するのは「情報が落ちたことを可視にする」意図的な選択であること
    - 長さ上限は仕様由来ではなく、redirect URL 長とログ増幅を抑えるための運用パラメータであること
  - [ ] `ProviderConfig` から上限を変更可能にはしない（利用者が緩めて事故る経路を作らない）
- [ ] `packages/core/src/authorization-request.ts:437`
  - [ ] em dash（`—`）を ASCII（`-` など）に置き換える
- [ ] `packages/cli/src/frameworks/hono/templates.ts`
  - [ ] 生成される `views.ts` の `Views.errorPage` の JSDoc に
        「差し替える場合は `errorDescription` を必ずエスケープすること。
        core の sanitize は RFC 6749 の charset 制約のみで HTML 安全性は保証しない」を追記

## テスト要件

### `packages/core/src/error-utils.test.ts`

- [ ] `should keep angle brackets because RFC 6749 allows them`
      — `'<b>'` が `'<b>'` のまま返ることを `toBe` で固定する（HTML 安全でないことの明示）
- [ ] `should replace a double quote with a question mark`
- [ ] `should replace a backslash with a question mark`
- [ ] `should replace a non-ASCII character with a question mark`
- [ ] `should replace a control character with a question mark`
- [ ] `should truncate a description longer than the maximum length`
      — 長さが `MAX_ERROR_DESCRIPTION_LENGTH` に等しいことを `toBe` で固定する
- [ ] `should keep a description of exactly the maximum length unchanged`
- [ ] `should sanitize characters before truncating`
      — 上限超過かつ不許可文字を含む入力で、出力の長さと内容の両方を具体値で固定する

### `packages/core`（エラークラス横断）

- [ ] `should truncate the error description of an AuthorizationError`
- [ ] `should truncate the error description of a TokenError`
- [ ] `should truncate the error description of a UserInfoError`
- [ ] `should truncate the error description of a RevocationError`
- [ ] `should truncate the error description of an IntrospectionError`
      — すべてが `sanitizeErrorDescription` を通っていることを担保する

### `packages/core`（非 ASCII リテラルの排除）

- [ ] `should not embed non-ASCII characters in error descriptions`
      — `validateRegisteredRedirectUris` に非ループバックの `http://` を渡し、
      投げられた `AuthorizationError.errorDescription` に `?` が含まれないことを固定する

### `packages/experimental`

- [ ] `ParError` / `TokenExchangeError` も同じ上限が効くことを固定する

### `samples/*/conformance.test.ts`（生成元は `packages/cli`）

- [ ] 長大な `response_type` を送っても、エラーリダイレクト URL の
      `error_description` が上限内に収まることを固定する

## 完了条件

- [ ] `pnpm --filter @maronn-openid-connect/core test` が通る
- [ ] `pnpm --filter @maronn-openid-connect/experimental test` が通る
- [ ] `pnpm --filter @maronn-openid-connect/cli test` が通る
- [ ] `pnpm --filter "./packages/*" test` が通る
- [ ] `pnpm run test:conformance` が通る
- [ ] `MAX_ERROR_DESCRIPTION_LENGTH` の値の根拠が JSDoc に書かれている
- [ ] `packages/experimental` に手書きの changeset を **追加していない**
      （CI が patch を自動生成する。`pnpm run test:release-contract` が通ること）
- [ ] `study-material/done/error-description-input-reflection-and-length-bound.md` の
      方針C（反射の固定文言化）／方針D（反射方針の統一）は未着手のまま残り、
      本タスクのスコープ外であることが同ファイルに明記されている
