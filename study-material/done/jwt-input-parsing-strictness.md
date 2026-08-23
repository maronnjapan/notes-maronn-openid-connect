# JWT 入力パースの厳格化と ID Token 発行時のクレーム型検証（検証側と発行側の非対称の解消）

## ステータス

🟡 Medium / 未着手

## 1. このトピックで確認したいこと

ID Token / JWT 周りで、**検証経路（`validateIdTokenHint`）は厳格なのに、発行経路と低レベルデコードは緩い**、
という非対称を確認し、JWT BCP（RFC 8725）の「strict parsing」観点で発行・パースの厳格化が必要かを判断する。

具体的に 3 点：

1. base64url デコード（`base64UrlToArrayBuffer`）が非正規・非 base64url 文字を黙って受理する（`atob` 依存）。
2. `validateIssuer`（発行時）が不正な `iss` で生の `TypeError: Invalid URL` を投げ、ライブラリの明確なエラーにならない。
3. `validatePayload`（発行時）が `exp` / `iat` の**型**（number か）や `aud` 要素の空文字を検査せず、
   構造的に不正な ID Token を発行しうる。検証側 `validateIdTokenHint` は `typeof === 'number'` を課しているのに、発行側はより緩い。

> 関連既存ファイル：
> - `study-material/jwt-bcp-rfc8725.md` は `kid` / `jku` / `typ` / `crit` / JWT サイズ / JSON パーサ強度を扱うが、
>   **JWS セグメントの base64url デコードそのものの厳格性**は扱っていない。
> - `study-material/done/untrusted-input-payload-size-dos-hardening.md` は `claims` JSON のサイズ上限を扱う。
> - `study-material/jws-algorithm-policy-and-alg-none-defense.md` は alg ポリシーを扱う。
> 本ファイルは **デコーダ／発行側の型・形式検査の厳格性**という固有差分のみを扱う。

## 2. 関連する仕様・基準

- **RFC 8725（JSON Web Token Best Current Practices）§3.11**: 「Use Appropriate Algorithms」「strict parsing」。
  入力を寛容に正規化せず、不正な入力は拒否することが望ましい。
- **RFC 7515（JWS）§2 / Appendix C**: base64url は **パディング無し・正規（canonical）**。
  デコーダは非 base64url 文字や不正長を拒否すべき。
- **OpenID Connect Core 1.0 §2 / RFC 7519 §2, §4.1**:
  - `iss`: REQUIRED。https スキームの URL で、クエリ・フラグメントを含まない。
  - `exp` / `iat`: NumericDate（JSON number）。
  - `aud`: StringOrURI もしくはその配列。空文字要素は不正。
  - `sub`: 非空文字列。

## 3. 参照資料

- RFC 8725 §3.11（strict parsing）: https://www.rfc-editor.org/rfc/rfc8725#section-3.11
- RFC 7515 §2 / Appendix C（base64url の正規性）: https://www.rfc-editor.org/rfc/rfc7515
- RFC 7519 §2, §4.1（NumericDate / StringOrURI / 登録クレーム）: https://www.rfc-editor.org/rfc/rfc7519
- OpenID Connect Core 1.0 §2（ID Token）: https://openid.net/specs/openid-connect-core-1_0.html#IDToken

## 4. 現在の実装確認

- **base64url デコード**: `packages/core/src/crypto-utils.ts:147-165`
  ```ts
  export function base64UrlToArrayBuffer(base64url: string): ArrayBuffer {
    const base64 = base64url.replace(/-/g, '+').replace(/_/g, '/'); // 入力文字種の検証なし
    const paddedBase64 = base64 + '='.repeat((4 - (base64.length % 4)) % 4);
    const binary = atob(paddedBase64); // atob は空白等を無視し非正規入力を受理しうる
    ...
    if (byte === undefined) { throw ... } // charCodeAt は範囲内 index で undefined を返さない → 実質デッドコード
  }
  ```
  - `[A-Za-z0-9_-]` 以外（`+` `/` `=` 空白 unicode 等）の混入を検査していない。
  - このデコーダは未認証入力 `id_token_hint` のパース経路（`id-token.ts:243-244` 付近）でも使われる。
- **`validateIssuer`**: `packages/core/src/id-token.ts:43-44`
  ```ts
  function validateIssuer(iss: string): void {
    const url = new URL(iss); // iss が "not a url" だと生の TypeError: Invalid URL を送出
    ...
  }
  ```
  - https / query / fragment の検査はあるが、**URL として不正な場合の明確なエラーが無い**。
  - また発行側でのみ実行され、PoC 利用者には不親切な例外メッセージになる。
- **`validatePayload`（発行時）**: `packages/core/src/id-token.ts:79-133`
  - `sub`: 真偽 + 長さ（255）チェックあり。
  - `exp`: `undefined`/`null` と `< now - leeway` のみ。**非 number（例 `"abc"`）を弾かない**。
  - `iat`: 存在チェックのみ。**number 型検査なし**。
  - `aud`: 配列長 0 は弾くが、`["clientA", ""]` の空文字要素は弾かない。
- **検証側の厳格さ（対比）**: `validateIdTokenHint` は `typeof exp === 'number'` / `typeof iat === 'number'` を課す
  （`id-token.ts:307, 319` 付近）。→ 発行側だけ緩いという非対称。

## 5. 現在の実装との差分

- **満たしていること**
  - 検証経路（`id_token_hint`）の時刻クレームは型チェック済み。
  - 署名検証が最終的な信頼ゲートなので、デコーダの緩さが即座に致命的ではない。
- **不足している可能性があること**
  - base64url デコーダが非正規入力を黙って受理（RFC 8725 §3.11 の strict parsing に対して緩い）。
  - 発行側 `validatePayload` が `exp`/`iat` の型・`aud` 空文字を検査せず、構造不正な ID Token を発行しうる。
  - `iss` 不正時の例外が不親切（PoC 利用者＝本リポジトリのターゲットにとって DX 低下）。
- **セキュリティ上**
  - デコーダの緩さは「署名検証で守られる」ものの、JWT BCP 準拠の多層防御としては厳格化が望ましい。
- **相互運用性**
  - 構造不正な ID Token を発行すると、RP 側ライブラリが拒否し、原因が OP 側にあると気づきにくい。
- **Basic OP として確認すべきこと**
  - これらは Basic OP の必須テスト項目ではないが、Fidelity / セキュリティの観点で改善余地。

## 6. 改善・追加を検討する理由

- **Fidelity / セキュリティ多層防御**: 「検証は厳しいが発行は緩い」非対称は、仕様忠実を掲げる本リポジトリで
  説明しづらい。発行物が構造的に正しいことを早期に保証する方が、利用者の信頼に資する。
- **導入しやすさ**: いずれも局所的（デコーダに検証ガード追加 / `new URL` を try-catch / `validatePayload` に型チェック追加）。
  既存の `validateIdTokenHint` の厳格チェックを発行側へミラーするだけで一貫性が取れる。
- **利用者メリット**: `iss` 設定ミスや不正クレームを早期かつ明確なメッセージで検知でき、PoC のデバッグが速くなる。
- **実装しない場合のリスク**: 構造不正トークンの発行・不親切な例外・JWT BCP の strict parsing 未達が残る。

## 7. 実装方針の候補

判断材料の整理（最終判断は人間）。

- base64url:
  - 方針A: `[A-Za-z0-9_-]` 以外を含む / 長さ `len % 4 === 1` を拒否する `base64UrlDecodeStrict` を追加し、
    `validateIdTokenHint` のヘッダ/ペイロードデコードに適用。実質デッドコードの `byte === undefined` 分岐は削除。
  - 方針B: 既存デコーダに検証ガードを追加（新関数を増やさない）。
- `validateIssuer`:
  - `new URL(iss)` を try-catch し `Error('Issuer must be a valid URL')` に正規化。
- `validatePayload`:
  - `typeof exp === 'number'` / `typeof iat === 'number'` を必須化。
  - `aud` 配列の空文字・非文字列要素を拒否。`validateIdTokenHint` の厳格チェックと整合させる。

## 8. タスク案

- [ ] base64url strict デコード（不正文字・不正長の拒否）のテストを先行作成 → 実装 → `validateIdTokenHint` 経路へ適用
- [ ] `validateIssuer` の `new URL` を try-catch し明確なエラーメッセージに正規化（テスト含む）
- [ ] `validatePayload` に `exp`/`iat` の number 型検査・`aud` 空文字/非文字列要素の拒否を追加（テスト含む）
- [ ] 発行側と検証側の時刻クレーム型チェックが一致していることを回帰で固定
- [ ] 完了条件: `pnpm --filter @maronn-openid-connect/core test` がパス
