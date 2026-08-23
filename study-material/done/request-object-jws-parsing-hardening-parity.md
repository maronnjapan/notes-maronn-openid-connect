# 署名付き Request Object の JWS パース堅牢化を `id_token_hint` 経路と揃える（strict base64url / `crit` / 外部鍵ヘッダ）

## ステータス

🟠 High / 未着手

## 1. このトピックで確認したいこと

本リポジトリには JWS Compact を受信・検証する経路が複数ある。`id_token_hint`（`validateIdTokenHint`）と
`request`（署名付き Request Object, `parseRequestObject`）である。前者に対しては別トピックで
「strict base64url デコード」「`crit` 未知パラメータ拒否」「`jku`/`x5u`/`jwk`/`x5c` の外部鍵ヘッダ拒否」といった
JOSE ヘッダ堅牢化が計画されている。しかし後者（Request Object の JWS 経路）は**別実装**であり、
同じ堅牢化が適用されておらず、テストでも固定されていない。

さらに、署名部（3 番目のセグメント）のデコードは `crypto-utils.ts` の `verify()` が
**非 strict**な `base64UrlToArrayBuffer` を使っており、これは全 JWS 経路（`id_token_hint` を含む）で共通の緩さになっている。

本ファイルは、Request Object の JWS パース堅牢性を `id_token_hint` 経路とパリティにすること、および
署名セグメントの strict デコードを検討する。

> 関連既存ファイル（重複を避けるため、共通の仕様説明はこれらを参照）：
> - `study-material/done/jwt-input-parsing-strictness.md` / `tasks/done/p3-jwt-input-parsing-strictness.md`:
>   base64url strict デコードの必要性と、**`validateIdTokenHint` 経路への適用**を扱う。本ファイルは
>   **Request Object 経路と署名セグメントという未適用箇所**の差分のみを扱う。
> - `study-material/jws-algorithm-policy-and-alg-none-defense.md`: `crit` 未知パラメータ拒否・alg allowlist・
>   key alg pinning を**`validateIdTokenHint` 対象**で扱う。本ファイルは同じ堅牢化を **Request Object 経路にも
>   広げる**という差分を扱う。
> - `tasks/p2-jwt-header-reject-unsafe-fields.md`: `jku`/`x5u`/`jwk`/`x5c` の明示拒否を **`id_token_hint` 対象**で扱う。
>   本ファイルは Request Object 経路への横展開を扱う。
> 本ファイル固有の論点は「**同じ堅牢化契約を全 JWS 受信経路に適用し、経路ごとの実装差を無くす**」こと。

## 2. 関連する仕様・基準

- **RFC 7515 §2 / Appendix C（base64url は無パディング・正規）**: JWS の各セグメントは canonical base64url。
  非正規入力（パディング `=`、`+`/`/`、空白、`len % 4 === 1`）は拒否すべき（RFC 8725 §3.11 strict parsing）。
- **RFC 7515 §4.1.11（`crit`）**:
  > If any of the listed extension Header Parameters are not understood ... then the JWS is invalid.
  - 受信側が理解できない `crit` パラメータがあれば JWS を無効とする（RFC 8725 §3.7）。
- **RFC 7515 §4.1.2/§4.1.3/§4.1.5/§4.1.6（`jku`/`jwk`/`x5u`/`x5c`）**: 外部から鍵を取得しうるヘッダは、
  事前登録 JWKS のみを使う OP では受信時に明示拒否するのが安全（RFC 8725 §3.1）。
- **OpenID Connect Core 1.0 §6.1（Request Object）**: `request` は署名（必要に応じ暗号化）された JWT。
  署名検証の堅牢性は `id_token_hint` と同格で扱うべきで、経路ごとに強度が違うのは Fidelity 上望ましくない。

## 3. 参照資料

- RFC 7515 §2 / Appendix C（base64url canonical）: https://www.rfc-editor.org/rfc/rfc7515
- RFC 7515 §4.1.11（`crit`）: https://www.rfc-editor.org/rfc/rfc7515#section-4.1.11
- RFC 8725 §3.1 / §3.7 / §3.11（JWT BCP）: https://www.rfc-editor.org/rfc/rfc8725
- OpenID Connect Core 1.0 §6.1（Request Object）: https://openid.net/specs/openid-connect-core-1_0.html#JWTRequests

## 4. 現在の実装確認

- `packages/core/src/request-object.ts`
  - `decodeJwtSegment`（`:48-51` 付近）は `base64UrlToArrayBuffer`（**非 strict**）を使ってヘッダ／ペイロードをデコードする
    （`:84`, `:95` で使用）。`id-token.ts` は `base64UrlToArrayBufferStrict` を使うのと非対称。
  - JOSE ヘッダは `alg`（と `alg=none` の扱い）程度しか見ておらず、`crit` の未知パラメータ拒否や
    `jku`/`x5u`/`jwk`/`x5c` の明示拒否は行っていない（`:103-128` 付近）。
- `packages/core/src/crypto-utils.ts`
  - `verify()`（`:39` 付近）は署名部を `base64UrlToArrayBuffer(signature)`（**非 strict**）でデコード。
    これは `id_token_hint` 経路でヘッダ／ペイロードを strict にしても、署名セグメントは緩いままという不整合。
- `packages/core/src/id-token.ts`
  - `validateIdTokenHint`（`:272-273`）はヘッダ／ペイロードを `base64UrlToArrayBufferStrict` で strict デコード（対照）。

## 5. 現在の実装との差分

- **満たしていること**
  - `alg=none` は各経路で拒否。Request Object の `allowUnsigned` 経路で空署名の要件も担保されている。
  - `id_token_hint` 経路のヘッダ／ペイロードは strict デコード。
- **不足している可能性があること（Request Object 経路）**
  - ヘッダ／ペイロードが**非 strict**デコード（非正規 base64url を黙って受理）。
  - `crit` 未知パラメータの拒否が無い。
  - `jku`/`x5u`/`jwk`/`x5c` の明示拒否が無い。
- **不足している可能性があること（全経路共通）**
  - `verify()` の署名セグメントが非 strict デコード。
- **セキュリティ／相互運用性**
  - 経路ごとにパース強度が違うと、「厳格な検証器が見る JWS」と「本 OP が受理する JWS」の差が生まれ、
    ヘッダ／ペイロードの smuggling や cross-JWT confusion の温床になりうる。将来 `logout_token` 等
    新たな JWS 受信経路を足すたびに同じ堅牢化を再実装する負債にもなる。

## 6. 改善・追加を検討する理由

- **Fidelity / セキュリティ**: JWS 受信の堅牢性は署名検証の信頼性そのもの。経路差を残すと、
  一方で塞いだ穴が他方で開いたままになる。
- **保守性**: 共通ヘルパ（例 `assertJwsHeaderAcceptable(header, allowlist)` と strict base64url デコード）に
  括り出し、全 JWS 受信経路（`id_token_hint` / `request` / 将来の `logout_token`）で共有するのが自然。
  本リポジトリは Web 標準 API のみで JOSE を自前実装しているため、共通化の効果が大きい。
- **導入しやすさ**: strict デコーダ（`jwt-input-parsing-strictness` タスクで追加予定）と `crit`／外部鍵ヘッダ拒否
  （`jws-algorithm-policy` / `jwt-header-reject-unsafe-fields` タスク）が実装されれば、本ファイルは
  それらを Request Object 経路と署名セグメントへ**適用するだけ**で完了する。
- **実装しない場合のリスク**: Request Object を有効化した利用者（`request_parameter_supported=true`）が
  非正規エンコード・未知 `crit`・外部鍵ヘッダを含む JWS を素通しし、`id_token_hint` 経路より弱い検証になる。

## 7. 実装方針の候補

判断材料の整理（最終判断は人間）。

- 方針A（推奨・共通化）: strict base64url デコードと `assertJwsHeaderAcceptable` を共通ヘルパ化し、
  `validateIdTokenHint` / `parseRequestObject` / `verify()`（署名部）で共有する。
  - 依存: `jwt-input-parsing-strictness` の strict デコーダ、`jws-algorithm-policy` の `crit`／allowlist、
    `jwt-header-reject-unsafe-fields` の外部鍵ヘッダ拒否。これらの完了後にまとめて横展開すると重複が少ない。
- 方針B（局所修正）: 依存タスクの完了を待たず、まず `request-object.ts` のデコーダを strict に差し替え、
  `crit`／外部鍵ヘッダ拒否を Request Object 経路に個別実装する。速いが共通化の機会を逃す。
- 署名セグメントの strict 化は影響範囲が全経路に及ぶため、回帰テスト（正常な署名が引き続き検証成功すること）を
  必ず先行させる。

## 8. タスク案

- [ ] `request-object.test.ts` に先行テスト（Red）:
  - [ ] 非正規 base64url（`+`/`/`/`=`/空白、`len % 4 === 1`）のヘッダ／ペイロードで Request Object が**拒否**される
  - [ ] 未知の `crit` パラメータを含む Request Object が**拒否**される
  - [ ] `jku`/`x5u`/`jwk`/`x5c` を含む Request Object が**拒否**される
- [ ] `crypto-utils.test.ts` に「署名セグメントが非正規 base64url の JWS を `verify` が拒否する」テストを追加
- [ ] strict デコード／`assertJwsHeaderAcceptable` を共通ヘルパ化し、`parseRequestObject` と `verify()` へ適用（Green）
- [ ] 正常系の署名検証・Request Object 検証が引き続き通る回帰テストを確認
- [ ] `request_parameter_supported` を有効化する CLI テンプレート／sample がある場合は conformance テストも更新
- [ ] 完了条件: `pnpm --filter @maronn-openid-connect/core test` がパス
