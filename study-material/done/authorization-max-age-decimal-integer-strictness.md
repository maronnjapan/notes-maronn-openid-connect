# `max_age` を `Number()` で緩く解釈しており、10進非負整数以外の形式を受理する

## 1. このトピックで確認したいこと

Authorization Endpoint の `max_age` バリデーションは `Number(maxAgeValue)` による数値コアースに依存しており、`Number.isFinite/isInteger/>= 0` しか見ていない。その結果、16進 (`0x3c`)、2進 (`0b111100`)、指数表記 (`1e3`)、小数点付き (`60.0`)、前後空白 (`" 60 "`)、先頭 `+` (`+60`) といった**10進整数文字列でない形式**が通過してしまう。

`max_age` は Basic OP 必須の認証リクエストパラメータであり、OIDC Core は「Number of seconds」を指定する 10進の非負整数文字列を想定する。本ファイルはこの**文字列パースの厳格性**という差分に限定する（`=0` の境界や DCR フォールバックは別トピック）。

## 2. 関連する仕様・基準

`max_age` の意味（再認証要求・`auth_time` 必須化）の共通説明は `study-material/id-token-auth-time-conditional-requirement.md` および `study-material/done/max-age-zero-reauthentication-boundary.md` を参照し繰り返さない。

- **OpenID Connect Core 1.0 §3.1.2.1（Authentication Request）**:
  > "max_age OPTIONAL. Maximum Authentication Age. Specifies the allowable elapsed time in seconds since the last time the End-User was actively authenticated by the OP."

  値は「seconds」を表す文字列であり、10進の非負整数として解釈するのが素直（仕様は明示的な ABNF を与えていないため「10進整数」は妥当な解釈。厳密な文言は §3.1.2.1 を確認）。
- **RFC 3986 / 一般的なクエリパラメータの解釈**: `max_age` は URL クエリ由来の文字列。`0x3c` や `1e3` を「60 秒」と解釈するのは、送信側の意図と乖離するリスクがある（例: クライアントがバグで `0x3c` を送っても OP が黙って 60 と解釈する）。
- **防御的パースの一般原則**: 想定外の数値表現を受理すると、クライアント実装差・ログの読み取り・将来の相互運用で齟齬を生む。厳格な 10進整数パースが安全側。

## 3. 参照資料

- OpenID Connect Core 1.0 §3.1.2.1 Authentication Request — https://openid.net/specs/openid-connect-core-1_0.html#AuthRequest
- ECMAScript `Number()` の変換仕様（16進・指数・空白トリムを受理する挙動の根拠） — https://tc39.es/ecma262/#sec-tonumber-applied-to-the-string-type
- 既存の関連記述（重複回避）: `study-material/done/max-age-zero-reauthentication-boundary.md`、`study-material/id-token-auth-time-conditional-requirement.md`

## 4. 現在の実装確認

`packages/core/src/authorization-request.ts`（`validateMaxAge`）:

```ts
function validateMaxAge(maxAgeValue: string, redirectUri: string, state?: string): number {
  const num = Number(maxAgeValue);                                    // L531
  if (!Number.isFinite(num) || !Number.isInteger(num) || num < 0) {   // L533
    throw new AuthorizationError(
      AuthorizationErrorCode.InvalidRequest,
      'max_age must be a non-negative integer',
      redirectUri, state
    );
  }
  return num;                                                         // L542
}
```

`Number()` は以下をすべて有限整数へ変換するため、現状は受理される:
- `max_age=0x3c` → 60
- `max_age=0b111100` → 60
- `max_age=1e3` → 1000
- `max_age=60.0` → 60
- `max_age=" 60 "` → 60（前後空白トリム）
- `max_age=+60` → 60

テスト（`authorization-request.test.ts:944-987` 付近）は `'3600'` / `'0'` / `'abc'` / 負値のみを固定しており、上記の緩い形式は未検証。

## 5. 現在の実装との差分

- **満たしていること**: 正常系の 10進整数、`abc` などの非数値、負値の拒否は妥当。
- **不足している可能性があること**: 16進・2進・指数・小数点・空白・先頭 `+` を「非負整数」として受理してしまう。仕様の「seconds（10進整数）」想定より緩い。
- **セキュリティ上の観点**: 直接の脆弱性ではないが、`max_age` は再認証の要否を決めるパラメータ。想定外形式を黙って解釈すると、送信側のバグやプロキシによる書き換えを検知できない。
- **相互運用性の観点**: OP が独自に緩い解釈をすると、クライアント/仲介の実装差でズレる。厳格化は相互運用のノイズを減らす。
- **Basic OP として確認すべきこと**: 認定テストがこの緩さを弾くかは不明。認定可否に直結する可能性は低いが、Fidelity の差分。

## 6. 改善・追加を検討する理由

- **なぜ検討するか**: Basic OP 必須パラメータの入力厳格性の穴。修正は 1 箇所で、リスクが低い。
- **Basic OP 必須か拡張か**: 認定必須ではないが、必須パラメータの入力バリデーション厳格化という Fidelity ハードニング。
- **導入しやすさ**: `validateMaxAge` の先頭に「10進非負整数の正規表現一致」を足すだけ。既存の `AuthorizationError` 経路をそのまま使える。
- **実装しない場合のリスク**: 緩い解釈が固定されないまま残り、将来「なぜ `0x3c` が通るのか」という相互運用の混乱や、リファクタ時の退行に気付けない。

## 7. 実装方針の候補（判断材料）

最終判断は人間が行う。

- 方針A（正規表現で 10進非負整数に限定, 推奨）:
  ```ts
  if (!/^\d+$/.test(maxAgeValue)) { throw ... }
  const num = Number(maxAgeValue);
  ```
  `^\d+$` は先頭 `+`・空白・小数点・16進・指数をすべて弾く。`Number.isSafeInteger` 上限を併せて確認するかは要判断（極端に大きい値の扱い）。
- 方針B（現状維持 + テスト固定）: 緩い解釈を「許容仕様」と割り切り、`0x3c` 等が通ることをテストで明示。実装変更なし。ただし仕様の「seconds」意図とは乖離が残る。
- 方針C（上限も導入）: `^\d+$` に加え、`Number.MAX_SAFE_INTEGER` を超える桁数を `invalid_request` にする。過大な `max_age` による論理的な無意味さを避ける。過剰仕様の懸念もあるため要判断。

## 8. タスク案

- [ ] `authorization-request.test.ts` に先行テスト（Red）:
  - [ ] `0x3c` / `0b111100` / `1e3` / `60.0` / `" 60 "` / `+60` が `invalid_request` になる
  - [ ] 既存の `'3600'` / `'0'` が引き続き通る（リグレッション無し）
- [ ] `validateMaxAge` に 10進非負整数の正規表現ガードを追加（方針A）
- [ ] 上限を設けるか（方針C）を判断
- [ ] 生成 OP の挙動が変わるため、必要なら `samples/*/conformance.test.ts`（生成元 `packages/cli`）に固定テストを追加
- [ ] 完了条件: `pnpm --filter @maronn-openid-connect/core test` がパス

## 関連トピック

- `study-material/done/max-age-zero-reauthentication-boundary.md` — `max_age=0` の再認証境界。本ファイルは「文字列パースの厳格性」という別軸。
- `study-material/id-token-auth-time-conditional-requirement.md` — `max_age` 指定時の `auth_time` 必須化。
