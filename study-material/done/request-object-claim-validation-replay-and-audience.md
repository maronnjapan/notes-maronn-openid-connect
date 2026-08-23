# Request Object（`request` by value）の JWT クレーム検証 — リプレイ／オーディエンス混同対策

## ステータス

🟠 High（出荷済みコードのセキュリティ差分）/ 未着手

## 1. このトピックで確認したいこと

`request` パラメータ（OIDC Core 1.0 §6.1, by value の signed Request Object）は
**すでに本実装に出荷済み**（`tasks/done/p1-basic-op-request-object-by-value.md` で
2026-06-22 に実装完了）である。現在の `parseRequestObject`
（`packages/core/src/request-object.ts`）は

- compact JWS の構造検証
- `alg` ホワイトリスト（既定 `RS256`）と `alg:none` の拒否（互換時のみ受理）
- `kid` / 登録 JWKS による署名検証

までは行うが、**Request Object（JWT）自身の登録クレーム（`exp` / `nbf` / `aud` /
`iss` / `jti` / `iat`）を一切検証していない**。

本ファイルは、この出荷済み機能に残る「署名は検証するがクレームを検証しない」という
具体的な差分にだけ絞り、リプレイ攻撃・オーディエンス混同（cross-AS confusion）の
リスクと、Basic OP / 相互運用の観点での対応方針を整理する。

> **重複回避の方針**
> - `study-material/ext-jar-request-object-rfc9101.md` は「JAR を**実装するか**」の
>   検討ファイルで、`request` 未実装を前提に書かれている（現在は by value が出荷済みのため
>   §4「現在の実装確認」が一部陳腐化している）。本ファイルは「実装する/しない」ではなく
>   「**出荷済み実装に残るクレーム未検証**」に絞る。
> - `study-material/jwt-bcp-rfc8725.md` は受信 JWT 全般の汎用ヘルパー
>   （`verifyJwsCompact({ allowedAlgs, allowedTyps, expectedIss, expectedAud, ... })`）を
>   提案する横断ファイルで、§4 で `request` を「未実装」と記載している（こちらも出荷前提）。
>   本ファイルは汎用ヘルパーの設計は繰り返さず、**Request Object 固有のクレーム意味論
>   （`aud=issuer` / `iss=client_id` / 入れ子 `request` 禁止）** の差分のみを書く。
> - `alg:none` 防御は `study-material/jws-algorithm-policy-and-alg-none-defense.md`、
>   `exp`/`nbf` の時刻許容誤差（clock skew）は
>   `study-material/done/jwt-clock-skew-and-time-tolerance.md` を参照し、ここでは再説しない。

## 2. 関連する仕様・基準

共通の仕様索引は `study-material/basic-op-requirement-traceability.md` の
「3. 関連する仕様・基準」を参照。本トピック固有のポイント:

- **OIDC Core 1.0 §6.1（Passing a Request Object by Value）**
  - Request Object は Authorization Request パラメータを Claims に持つ JWT。
  - 「The Request Object MAY be signed or unsigned (plaintext). ... it MAY contain the
    registered Claim Names `iss`, `aud` ...」と規定し、`iss`/`aud` を含めてよいとする。
  - 「The `request` and `request_uri` parameters MUST NOT be included in Request Objects.」
    → **入れ子の `request` / `request_uri` は禁止**。
- **RFC 9101（JWT-Secured Authorization Request, JAR）§6.1**
  - JAR として送る Request Object に対し、AS は次を検証すべきと定める:
    - `iss` Claim が存在する場合、その値は **`client_id` と一致**すること。
    - `aud` Claim が存在する場合、その値は **AS の issuer 識別子（または token endpoint URL）
      を含む**こと（オーディエンス混同＝別 AS 宛の Request Object の使い回し防止）。
    - `exp` が含まれる場合は期限切れを拒否（リプレイ防止）。
  - JAR は Request Object の `exp` を MUST 級で要求する profile（FAPI 等）の前提でもある。
- **RFC 8725（JWT BCP）§3.8 / §3.9 / §2.1（Cross-JWT Confusion / 期限検証）**
  - 受信 JWT は用途ごとに `iss` / `aud` を期待値と完全一致で検証し、有効期限を必ず確認する。
- **OAuth 2.0 Security BCP（RFC 9700）**: 認可リクエストの完全性・リプレイ耐性の文脈。
- **Basic OP 観点**: JAR / Request Object は Basic OP の**必須要件ではない**
  （`study-material/basic-op-requirements-baseline.md`）。ただし本実装は by value を
  すでに**機能として広告**（Discovery `request_parameter_supported: true`）しているため、
  「広告した機能が安全に動く」ことは相互運用・信頼性のシグナルとして担保したい。

## 3. 参照資料

- OIDC Core 1.0 §6.1: https://openid.net/specs/openid-connect-core-1_0.html#JWTRequests
  （`iss`/`aud` を含めてよい旨、`request`/`request_uri` 入れ子禁止）
- RFC 9101 §6.1（Authorization Server side / Request Object 検証）:
  https://www.rfc-editor.org/rfc/rfc9101#section-6.1
  （`iss == client_id`、`aud == issuer`、`exp` 検証）
- RFC 8725 §2.1, §3.8, §3.9:
  https://www.rfc-editor.org/rfc/rfc8725
- RFC 9700（OAuth 2.0 Security BCP）: https://www.rfc-editor.org/rfc/rfc9700
- 既存・相補ファイル:
  - `study-material/ext-jar-request-object-rfc9101.md`（JAR 実装の是非。本ファイルと前後関係）
  - `study-material/jwt-bcp-rfc8725.md`（汎用 JWT 検証ヘルパー提案。本ファイルは固有差分のみ）
  - `study-material/done/jwt-clock-skew-and-time-tolerance.md`（`exp`/`nbf` 許容誤差の既存方針）
  - `tasks/done/p1-basic-op-request-object-by-value.md`（by value 実装の一次記録）

## 4. 現在の実装確認

- `packages/core/src/request-object.ts` `parseRequestObject`:
  - L72-101: 3 セグメント JWS の構造／JSON 検証。
  - L103-121: `alg` 必須・ホワイトリスト・`alg:none`（`allowUnsigned` 時のみ）。
  - L123-160: `kid` / 登録 JWKS による署名検証。
  - **署名検証に成功すると payload（claim 一式）をそのまま返す。`exp`/`nbf`/`aud`/`iss`/
    `jti`/`iat` は読まれも検証もされない。**
- `packages/core/src/authorization-request.ts`:
  - L714-733: `parseRequestObject` を呼び、失敗時は `invalid_request`。
  - L741-812: `response_type`/`client_id` のクエリ一致検証はあるが、`iss`/`aud`/`exp` 検証は無い。
  - L1000-1016 `REQUEST_OBJECT_OVERRIDE_KEYS`: `request` / `request_uri` を含まないため、
    入れ子で送られても**黙殺**される（OIDC Core §6.1 の MUST NOT に対し、拒否はしない）。
  - `validateAuthorizationRequest` は **OP の issuer を引数で受け取っていない**ため、
    `aud == issuer` 検証を入れるには issuer を渡す経路が必要。
- 署名検証基盤（`crypto-utils.ts` の `verify`、`id-token.ts:validateIdTokenHint` の
  `iss`/`aud` 比較）は流用可能。

## 5. 現在の実装との差分

- **満たしていること**
  - 署名付き Request Object の構造・`alg` ホワイトリスト・`alg:none` 拒否・署名検証。
  - クエリと Request Object の `response_type`/`client_id` 一致検証（OIDC Core §6.1 必須）。
- **不足している可能性があること（本ファイルの主眼）**
  - 🔴 `exp` 検証なし → **期限の無い signed Request Object を無期限にリプレイ可能**。
    傍受された認可 URL（`request=...`）が後からそのまま再利用され得る。
  - 🔴 `aud` 検証なし → 別 AS 宛に署名された Request Object を本 OP に投げ込む
    **オーディエンス混同**を検知できない（複数 OP に同一 client が登録される構成で顕在化）。
  - 🟡 `iss` 検証なし → `iss == client_id` を確認しないため、署名鍵を共有する別主体由来の
    Request Object を弾けない（多くの場合は署名鍵で間接的に縛られるが、明示検証が JAR の要求）。
  - 🟡 `nbf`/`iat` の未来時刻・極端な過去の扱いが未定義（時刻許容は既存 clock-skew 方針に合わせる）。
  - 🟡 入れ子 `request`/`request_uri` を黙殺している（§6.1 は MUST NOT。拒否が望ましい）。
  - 🟡 `jti` による単回使用（replay cache）が無い（強い対策だが store 依存。後述のとおり任意）。
- **セキュリティ上、改善した方がよいこと**: 上記 `exp`/`aud` が中核。FAPI 等の上位 profile
  （`study-material/ext-fapi-2-0-security-profile.md`）は Request Object の `exp` 必須・`aud` 検証を前提にする。
- **相互運用性の観点**: Discovery で `request_parameter_supported: true` を広告済みなので、
  RP は「安全に処理される」ことを期待する。クレーム未検証はその期待に反する。
- **Basic OP として確認すべきこと**: Basic OP 認定自体には Request Object 検証は不要だが、
  「広告した機能の健全性」を契約テスト（`conformance.test.ts`）で固定したい。

## 6. 改善・追加を検討する理由

- **なぜ価値があるか**: 署名は「改竄されていない」ことしか保証しない。`exp`/`aud` を見ない限り
  「**いつ・どの AS 宛**に作られたか」を判定できず、傍受したリクエストの使い回し（リプレイ）と
  別 AS 宛トークンの転用（オーディエンス混同）を防げない。これは署名付き認可リクエストを
  使う主目的（リクエスト完全性＋文脈束縛）の半分が欠けている状態。
- **Basic OP 必須か拡張か**: Basic OP の**必須ではない**。しかし「出荷済み機能の
  セキュリティ補完」であり、新規拡張の追加ではなく既存実装のハードニングに当たる。
  本リポジトリのコンセプト（Fidelity = 仕様忠実）に直結する。
- **導入しやすさ**: 署名検証は既に通っており、payload は手元にある。`exp`/`nbf`/`aud`/`iss` の
  比較を `parseRequestObject` の後段（または専用 options）に足すだけで実装でき、
  既存の clock-skew 方針（`done/jwt-clock-skew-and-time-tolerance.md`）と `validateIdTokenHint` の
  `iss`/`aud` 比較パターンを流用できる。導入難度は低〜中。
- **既存実装との接続**: `validateAuthorizationRequest` に `issuer`（と検証済み `client_id`）を
  渡す経路を足し、`parseRequestObject` のオプションへ `expectedIssuer` / `expectedClientId` /
  `requireExp` / `clockSkewSeconds` を追加する形が自然。
- **利用者/運用者メリット**: 生成 OP をそのまま使う利用者が、Request Object のリプレイ・
  オーディエンス混同に自前で気づかなくても安全側に倒れる。
- **実装しない場合のリスク**: 広告済みの `request` 機能にリプレイ／混同の穴が残る。
  FAPI 等の上位 profile 検証にも進めない。

## 7. 実装方針の候補

最終判断（採否・既定値・厳格度）は人間が行う。以下は判断材料。

### 方針A（最小・推奨ベース）: `exp` + `aud` 検証を既定で有効化
- `parseRequestObject` のオプションに `expectedIssuer`（= OP issuer）、`expectedClientId`、
  `requireExp`（既定 true 推奨）、`clockSkewSeconds`（既存方針に合わせる）を追加。
- 検証規則:
  - `exp` が無い、または `exp <= now - skew` → `RequestObjectError`（→ `invalid_request`）。
  - `nbf` があり `nbf > now + skew` → 拒否。
  - `aud` があり OP issuer を含まない → 拒否。`aud` が無い場合の扱い（必須化するか）は要判断。
  - `iss` があり `client_id` と不一致 → 拒否。
- 入れ子 `request`/`request_uri` claim を検知したら拒否（§6.1 MUST NOT）。
- 既定値の厳格度（`aud`/`exp` を「あれば検証」か「必須」か）は、Basic OP conformance 互換
  （`allowUnsigned` 経路）を壊さないかを確認した上で決める。

### 方針B（厳格・FAPI 寄り）: `exp` / `aud` / `iss` をすべて必須化
- 上位 profile を見据え、3 claim 必須。Basic OP の unsigned 互換テストと衝突しないよう
  オプションで段階適用（Basic 互換時は緩める）。

### 方針C（`jti` 単回使用の追加）: replay cache
- `jti` を短期 TTL の store に記録し、再提示を拒否。最も強いリプレイ対策だが
  **store 依存**（`study-material/resolver-and-store-contract.md` の CAS 契約に乗る）。
- 認可エンドポイントは未認証・高頻度のため store 負荷・運用コストが増える。
  `exp` を短く必須化すれば多くのリプレイは塞げるため、`jti` は任意の上積みとして扱う（P3 相当）。

### 方針D（汎用ヘルパーへ寄せる）
- `jwt-bcp-rfc8725.md` が提案する `verifyJwsCompact({ expectedIss, expectedAud, ... })` を
  先に作り、`validateIdTokenHint` / Request Object / 将来の private_key_jwt で共有する。
  設計協議（`/design-discussion`）で「個別実装を先行するか共通化を待つか」を決める。

## 8. タスク案

- [ ] 方針A〜D の採否と既定厳格度（`exp`/`aud`/`iss` を必須化するか）を人間が決定する
- [ ] `parseRequestObject` に claim 検証オプション（`expectedIssuer` / `expectedClientId` /
      `requireExp` / `clockSkewSeconds`）を追加するテストを先行作成（TDD: Red → Green）
- [ ] `validateAuthorizationRequest` に OP issuer を渡す経路を追加（既存呼び出し側の影響調査含む）
- [ ] 入れ子 `request`/`request_uri` claim の拒否テストを追加（OIDC Core §6.1 MUST NOT）
- [ ] Basic OP unsigned 互換（`allowUnsigned` / `oidcc-*` module）を壊さないことを回帰確認
- [ ] CLI テンプレート（`packages/cli`）と各 sample の `conformance.test.ts` を同期
      （生成 OP が Request Object のリプレイ／混同を拒否する契約を固定する）
- [ ] （任意・P3）`jti` replay cache を `resolver-and-store-contract.md` の契約に沿って検討
</content>
</invoke>
