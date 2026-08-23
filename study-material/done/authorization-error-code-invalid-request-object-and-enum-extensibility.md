# 認可エンドポイントのエラーコード欠落（`invalid_request_object` / `invalid_request_uri`）と `AuthorizationErrorCode` の拡張性

## ステータス

🟡 Major（仕様準拠・相互運用性・拡張性）/ **タスク化済み**

- 方針 A（enum に 2 値追加＋変換先差し替え）→ `tasks/p2-authorization-error-invalid-request-object.md`
- 方針 B（experimental PAR のエラー型統合）は方針 A 完了後に別途判断する（未タスク化）
- 方針 C（enum を開いた型へ）は拡張が 2〜3 個増えてから再検討する（未タスク化）

## 1. このトピックで確認したいこと

OIDC Core 1.0 §6.3 は、Request Object（`request` / `request_uri` パラメータ）を扱う OP が
返しうるエラーコードを 4 つ定義している。

| エラーコード | 意味 | 本リポジトリでの定義 |
|---|---|---|
| `invalid_request_uri` | `request_uri` が到達不能・不正なデータを返した | ❌ 未定義 |
| `invalid_request_object` | `request` に含まれる Request Object が不正 | ❌ 未定義 |
| `request_not_supported` | OP が `request` パラメータをサポートしない | ✅ 定義済み |
| `request_uri_not_supported` | OP が `request_uri` パラメータをサポートしない | ✅ 定義済み |

本リポジトリは **Request Object by value（`request` パラメータ）を実装済み**
（`tasks/done/p1-basic-op-request-object-by-value.md`）であるにもかかわらず、
その失敗を表す `invalid_request_object` を持たず、**すべて `invalid_request` に潰している**。

さらに `AuthorizationErrorCode` が閉じた enum であることが実際に拡張の障害になっており、
`packages/experimental` の PAR 実装は**独自のエラークラスを別途定義する回避策**を取っている。

本ファイルでは以下を確認・整理する。

- §6.3 の 4 コードのうち 2 つが欠けていることの仕様準拠上・相互運用性上の影響
- 欠落が既に experimental 側の実装をゆがめている実例
- エラーコードの語彙をどう拡張可能にするか（enum を開くか、別の型にするか）

### 既存ファイルとの差分（重複回避）

- エラーレスポンスの形式・`error_description` の扱い・`error_uri`:
  `study-material/error-response-cross-endpoint.md`
  → 本ファイルは「**どのエラーコードが存在すべきか**」という語彙の話に限定し、
  レスポンス形式・サニタイズ・HTTP ステータスの議論は繰り返さない。
- Request Object の署名検証・JWS パースの堅牢化:
  `study-material/done/request-object-jws-parsing-hardening-parity.md` /
  `study-material/done/request-object-claim-validation-replay-and-audience.md`
  → 本ファイルは「検証に失敗したときに**何を返すか**」だけを扱う。
- `request` / `request_uri` の相互排他: `study-material/done/request-and-request-uri-mutual-exclusivity.md`
- Request Object 非対応時の `request_not_supported` 返却と Discovery の整合:
  `study-material/request-object-rejection-and-discovery-honesty.md`
- JAR（RFC 9101）そのものの採用検討: `study-material/ext-jar-request-object-rfc9101.md`
- PAR の採用・設計: `study-material/extension-pushed-authorization-requests-par.md`

## 2. 関連する仕様・基準（このトピック固有の差分）

### 2.1 OIDC Core 1.0 §6.3 Authentication Request Errors

§6.3 は Request Object 関連のエラーコードを次のように定義する（趣旨）。

> **invalid_request_uri**
> The `request_uri` in the Authorization Request returns an error or contains invalid data.
>
> **invalid_request_object**
> The `request` parameter contains an invalid Request Object.
>
> **request_not_supported**
> The OP does not support use of the `request` parameter defined in Section 6.1.
>
> **request_uri_not_supported**
> The OP does not support use of the `request_uri` parameter defined in Section 6.2.

重要な点は、`invalid_request_object` と `request_not_supported` が**別のコードとして
定義されている**こと。前者は「`request` は受け付けるが、中身が壊れている」、
後者は「そもそも `request` を受け付けない」であり、クライアント側の対処が異なる。

- `request_not_supported` → クライアントは Request Object の使用をやめ、
  通常のクエリパラメータへフォールバックすべき。
- `invalid_request_object` → クライアントは Request Object の生成処理（署名鍵、alg、
  クレーム内容）を修正すべき。フォールバックしても解決しない。

これを両方 `invalid_request` に潰すと、クライアントは**どちらの対処を取るべきか判別できない**。

### 2.2 RFC 9101 (JAR) §5 との関係

RFC 9101 は OIDC Core §6 を IETF 標準化したもので、同じく `invalid_request_object` /
`invalid_request_uri` を使う。将来 JAR を正式サポートする場合
（`study-material/ext-jar-request-object-rfc9101.md`）、これらのコードは必須になる。

### 2.3 RFC 9126 (PAR) §2.3 との関係

PAR のエラーレスポンスも `invalid_request_uri` を使う。本リポジトリの experimental PAR 実装は
まさにこれを必要としたが、core の enum に無いため独自クラスを作っている（§4.3 参照）。

### 事実と判断の区別

- **事実**: OIDC Core §6.3 は `invalid_request_object` / `invalid_request_uri` を定義している。
- **事実**: 本リポジトリの `AuthorizationErrorCode` はこの 2 つを持たず、
  Request Object のパース／署名検証失敗を `invalid_request` に変換している（§4.2）。
- **事実**: `packages/experimental/src/par/resolve-request-uri.ts` は
  この欠落を理由に独自エラー型を定義している（コード中のコメントに明記されている）。
- **判断**: `request` パラメータをサポートすると宣言している以上、
  §6.3 の対応するエラーコードを返せることは Fidelity（仕様忠実性）の一部と考えられる。
  ただし Basic OP 認定の必須要件かどうかは §5 で分けて論じる。

## 3. 参照資料

- OpenID Connect Core 1.0 §6.3 Authentication Request Errors（4 つのエラーコード定義）:
  https://openid.net/specs/openid-connect-core-1_0.html#RequestObject
  （§6 Passing Request Parameters as JWTs 配下。§6.1 by value / §6.2 by reference / §6.3 errors）
- OpenID Connect Core 1.0 §3.1.2.6 Authentication Error Response
  （`interaction_required` 等 OIDC 固有コードの定義。§6.3 はこれに追加する形）:
  https://openid.net/specs/openid-connect-core-1_0.html#AuthError
- RFC 9101 §5 (JWT-Secured Authorization Request) — `invalid_request_object` の使用:
  https://www.rfc-editor.org/rfc/rfc9101#section-5
- RFC 9126 §2.3 (Pushed Authorization Requests) — `invalid_request_uri` の使用:
  https://www.rfc-editor.org/rfc/rfc9126#section-2.3
- RFC 6749 §4.1.2.1 — 基底となる OAuth 2.0 認可エラーコード:
  https://www.rfc-editor.org/rfc/rfc6749#section-4.1.2.1

> ⚠️ 注記: 本調査環境からは openid.net / rfc-editor.org への直接フェッチが遮断されていたため、
> §2.1 の引用は逐語ではなく趣旨要約として記載した。逐語確認は §8 のタスクに含めた。
> 「§6.3 に 4 つのコードがあり、そのうち 2 つが本リポジトリに無い」という事実関係は
> `AuthorizationErrorCode` のコード（§4.1）とコメントから直接確認できる。

## 4. 現在の実装確認

### 4.1 定義されているエラーコード

`packages/core/src/authorization-request.ts:21-42`

```ts
export enum AuthorizationErrorCode {
  // OAuth 2.1 Section 4.1.2.1
  InvalidRequest = 'invalid_request',
  UnauthorizedClient = 'unauthorized_client',
  AccessDenied = 'access_denied',
  UnsupportedResponseType = 'unsupported_response_type',
  InvalidScope = 'invalid_scope',
  ServerError = 'server_error',
  TemporarilyUnavailable = 'temporarily_unavailable',
  // OIDC Core 1.0 Section 3.1.2.6
  InteractionRequired = 'interaction_required',
  LoginRequired = 'login_required',
  AccountSelectionRequired = 'account_selection_required',
  ConsentRequired = 'consent_required',
  // OIDC Core 1.0 Section 6.3
  RequestNotSupported = 'request_not_supported',
  RequestUriNotSupported = 'request_uri_not_supported',
  // OIDC Core 1.0 §3.1.2.6
  RegistrationNotSupported = 'registration_not_supported',
}
```

コメントで「OIDC Core 1.0 Section 6.3」と明記しながら、§6.3 の 4 コードのうち
**`request_not_supported` / `request_uri_not_supported` の 2 つしか入っていない**。

### 4.2 Request Object の失敗が `invalid_request` に潰されている

`packages/core/src/request-object.ts:19-24`（型定義側のコメント）

```ts
/**
 * Request Object のパース・署名検証に失敗したことを表すエラー。
 *
 * 呼び出し側（`validateAuthorizationRequest`）はこれを捕捉して
 * `invalid_request`（OAuth 2.1 §4.1.2.1）の `AuthorizationError` に変換する。
 */
export class RequestObjectError extends Error { /* ... */ }
```

`packages/core/src/authorization-request.ts:826-835`（変換箇所）

```ts
} catch (e) {
  if (e instanceof RequestObjectError) {
    throw new AuthorizationError(
      AuthorizationErrorCode.InvalidRequest,   // ← invalid_request_object であるべき箇所
      e.message,
    );
  }
  throw e;
}
```

`parseRequestObject`（`packages/core/src/request-object.ts:64-161`）が投げる
**すべての失敗**がここを通る。具体的には:

- JWS compact serialization でない（セグメント数不正 / JWE）
- header / payload が base64url JSON でない
- `alg` 欠落
- 未対応の `alg`
- `alg: "none"` を非許可構成で受信
- クライアント JWKS 未登録
- `kid` に一致する鍵が無い
- 署名検証失敗

これらはすべて「`request` パラメータが不正な Request Object を含む」＝
§6.3 の `invalid_request_object` の定義そのものだが、`invalid_request` として返される。

### 4.3 欠落が experimental の実装をゆがめている実例

`packages/experimental/src/par/resolve-request-uri.ts:16-25`

```ts
/**
 * `AuthorizationErrorCode` は closed な enum で `invalid_request_uri` を含まないため、
 * (中略)
 */
export class PushedRequestUriError extends Error {
  readonly code: 'invalid_request_uri' | 'invalid_request';
  constructor(code: 'invalid_request_uri' | 'invalid_request', errorDescription: string) { /* ... */ }
}
```

- core の enum を拡張できないため、**PAR だけが別のエラー型**を持つ形になっている。
- 生成コードの authorize ルートは、`AuthorizationError` と `PushedRequestUriError` の
  **2 系統を捕捉して同じレスポンス形へ整形する**必要がある。
- これは「core が唯一のエラー語彙を持つ」という設計が既に破れていることを意味する。
  今後 JAR / JARM / その他拡張を足すたびに同じ分岐が増える。

### 4.4 エラーが redirect されない設計（別論点だが同じコードパス）

`packages/core/src/authorization-request.ts:1136-1157` の順序により、
Request Object のパースは **redirect_uri 解決より前**に実行される。
そのため §4.2 の `AuthorizationError` は `redirectUri` / `state` を伴わずに投げられ、
リダイレクトではなく OP 上のエラー表示になる。

これはコード中のコメントで「redirect 先を信頼できないため」と**意図的な設計として明記**されている。
Request Object 内の `redirect_uri` が優先される仕様（§6.1 supersede）を踏まえると、
壊れた Request Object から redirect 先を取り出して飛ばすのは危険であり、この判断には合理性がある。
**本ファイルはこの挙動の是非を論点にしない**が、エラーコードを直す際に
「非リダイレクトのままコードだけ変える」のか「redirect 可能にするのか」は
セットで判断する必要があるため記録しておく。

## 5. 現在の実装との差分

### 満たしていること

- 🟢 §6.3 の `request_not_supported` / `request_uri_not_supported` は正しく実装され、
  機能トグルと連動している（`rejectUnsupportedRequestParams`、
  `packages/core/src/authorization-request.ts:853-888`）。
- 🟢 §3.1.2.6 の OIDC 固有コード（`interaction_required` / `login_required` /
  `account_selection_required` / `consent_required` / `registration_not_supported`）は
  すべて定義され、実際に使用されている。
- 🟢 Request Object のパース失敗自体は**確実に拒否されている**。
  セキュリティ上の穴（不正な Request Object が通る）は無い。問題は返すコードの粒度のみ。

### 不足している可能性があること

- 🟡 **`invalid_request_object` が無い**: `request` パラメータをサポートすると宣言
  （Discovery `request_parameter_supported: true`）しながら、その失敗を §6.3 の
  専用コードで返せない。クライアントは「Request Object をやめるべき」なのか
  「Request Object を直すべき」なのかを判別できない。
- 🟡 **`invalid_request_uri` が無い**: 現状 core は `request_uri` を非サポートとして
  拒否するため直接の実害は無いが、experimental PAR が既に必要としており（§4.3）、
  JAR を正式採用する際にも必須になる。
- 🟡 **エラーコード語彙が閉じている**: `AuthorizationErrorCode` が閉じた enum のため、
  拡張パッケージが core のエラー語彙に参加できない。§4.3 の回避策が既に発生している。

### 実装はあるが仕様上の確認が必要なこと

- 🟡 **`invalid_request` に潰す設計が意図的だったのか**が実装から読み取れない。
  `request-object.ts` のコメントは「`invalid_request` に変換する」と**断定的に**書いており、
  §6.3 の `invalid_request_object` を検討したうえで見送ったのか、単に見落としたのかが不明。
  どちらであれ、**その判断を記録した場所が無い**。
- 🟡 **Discovery との整合**: `request_parameter_supported: true` を広告する構成で
  `invalid_request_object` を返せないことが、OIDF Conformance Suite の
  Request Object 系 module に影響するかは未確認（§7 の不明点参照）。

### セキュリティ上、改善した方がよいこと

- 🟢 **セキュリティ上の劣化は無い**。不正な Request Object は現状でも確実に拒否される。
  本トピックは相互運用性・診断性の改善であり、脆弱性ではない。
- 🟡 ただし `e.message` をそのまま `error_description` に載せている点（§4.2）は、
  `invalid_request_object` 化に合わせて見直す価値がある。
  「どの鍵で検証に失敗したか」を詳細に返すと、登録鍵の探索に使われうる。
  （`error_description` の一般方針は `study-material/error-response-cross-endpoint.md` を参照）

### 相互運用性の観点で改善した方がよいこと

- 🟡 クライアントライブラリの多くは §6.3 のコードを個別にハンドリングする。
  `invalid_request` に潰されると、Request Object 対応のクライアントが
  自動フォールバック判断を誤る。
- 🟡 experimental PAR とのエラー型二重化（§4.3）は、生成コードの
  エラーハンドリングを複雑にし、利用者が改造する際の理解コストを上げている。

### Basic OP として提供する上で確認すべきこと

- 🟢 **Basic OP の必須要件ではない可能性が高い**。Basic OP profile は
  Request Object（§6）を必須機能に含めないため、§6.3 のエラーコードも必須ではないと思われる。
  ただし本リポジトリは Basic OP conformance 互換のために Request Object by value を
  既に実装しており（`tasks/done/p1-basic-op-request-object-by-value.md`）、
  その実装に対応するエラーコードだけが欠けている、という**内部的な非整合**の状態にある。
- 🟡 OIDF Conformance Suite の `oidcc-request-object-*` 系 module が
  返却エラーコードを検証するかは**要一次資料確認**（§7）。

## 6. 改善・追加を検討する理由

### なぜこの改善を検討すべきなのか

1. **Fidelity（仕様忠実性）が差別化軸である**。
   「最新の OIDC/OAuth 仕様を忠実に検証できる」を掲げる以上、
   実装済み機能（Request Object by value）に対応する仕様定義済みエラーコードが
   欠けている状態は、掲げた軸との齟齬になる。
2. **既に実害が出ている**。§4.3 の PAR 回避策は仮説ではなく、
   コード中のコメントで欠落を理由として明記された実在の回避策である。
   放置すると拡張を足すたびに同種の回避策が増える。
3. **修正コストが極めて小さい**。enum への 2 値追加と、変換箇所 1 か所の差し替えで済む。

### Basic OP として必要なのか、それとも拡張機能として有用なのか

- **Basic OP 認定としては不要**（§5 参照）。
- **実装済み機能の完成度として必要**。「`request` は実装したが、
  その失敗を仕様どおりに通知できない」という中途半端さの解消。
- **拡張（JAR / PAR）の土台として必要**。`invalid_request_uri` は
  PAR / JAR のいずれを進めても必要になる。

### 現在のリポジトリ構成から見て、なぜ導入しやすいか

- 🟢 **極めて導入しやすい**。`AuthorizationErrorCode` は文字列 enum であり、
  値を 2 つ足すのは後方互換な変更（既存の値・シリアライズ形は不変）。
- 🟢 変換箇所は `packages/core/src/authorization-request.ts:826-835` の 1 か所のみ。
- 🟢 `AuthorizationError` のレスポンス整形ロジック（`error` / `error_description` /
  リダイレクト有無）は既存のまま使えるため、生成コード側の変更は原則不要。

### 既存実装とどのように接続できそうか

- `RequestObjectError` を `AuthorizationErrorCode.InvalidRequestObject` に変換するだけで
  §4.2 は解決する。
- `invalid_request_uri` を enum に足せば、experimental PAR の `PushedRequestUriError` を
  段階的に `AuthorizationError` へ統合できる（§7 の方針 B / C）。

### 利用者・開発者・運用者にどのようなメリットがあるか

- **利用者**: Request Object の検証で失敗したとき、`invalid_request` ではなく
  `invalid_request_object` が返るので「クエリパラメータの問題」ではなく
  「JWT の問題」だと即座に切り分けられる。PoC のデバッグ時間が縮む。
- **開発者**: 拡張パッケージがエラー語彙を自作しなくてよくなり、
  生成コードのエラーハンドリング分岐が 1 系統に収束する。
- **運用者**: ログ・監査上、Request Object 起因の失敗を他の `invalid_request` と
  区別して集計できる（`study-material/audit-logging-and-observability.md` と連動）。

### 実装しない場合にどのような制約やリスクが残るか

- `invalid_request` に潰れたままなので、Request Object 対応クライアントとの
  相互運用で診断困難な状態が残る。
- JAR / PAR を正式採用する際に、同じ欠落を再び回避策で埋めることになる。
- experimental 側のエラー型二重化が固定化し、生成コードの複雑さが恒久化する。

## 7. 実装方針の候補

> 最終判断は人間が行う。

### 方針A（enum に 2 値を追加するだけ）— 最小

- `AuthorizationErrorCode` に `InvalidRequestObject = 'invalid_request_object'` と
  `InvalidRequestUri = 'invalid_request_uri'` を追加。
- `packages/core/src/authorization-request.ts:826-835` の変換先を
  `InvalidRequestObject` に変更。
- experimental PAR は当面そのまま（`PushedRequestUriError` を残す）。
- メリット: 変更が最小。後方互換。今日すぐ入れられる。
- 注意: エラー型二重化（§4.3）は残る。

### 方針B（方針 A ＋ experimental PAR を core のエラー型へ統合）

- 方針 A に加え、`PushedRequestUriError` を廃止し、
  experimental PAR も `AuthorizationError` を投げるようにする。
- 生成コードの authorize ルートから、エラー型の分岐を 1 つ減らせる。
- メリット: エラー語彙が core に一本化される。生成コードが素直になる。
- 注意: experimental は破壊的変更が許容される位置づけだが、
  `RELEASE.md` の experimental 自動 publish 運用（patch 固定）と
  changeset の扱いを確認する必要がある。

### 方針C（エラーコードを enum から開いた型へ変更）

- `AuthorizationErrorCode` を `enum` から
  `type AuthorizationErrorCode = (typeof KNOWN_CODES)[number] | (string & {})` のような
  開いた型に変え、拡張パッケージが任意のコードを投げられるようにする。
- メリット: 将来の拡張（JARM / RAR / CIBA 等）で core を触らずに済む。
- 注意: 型の緩和はタイポ検出を失う。既存の `enum` 参照
  （`AuthorizationErrorCode.InvalidRequest` 形式）は互換のため定数オブジェクトで残す必要がある。
  v0.x の API 安定性方針（`study-material/RELEASE-v0.x-scope.md`）との整合確認が要る。

### 方針D（現状維持＋設計判断の明文化）

- `invalid_request` に潰すのは意図的である旨を `request-object.ts` のコメントと
  README に明記し、`invalid_request_object` を返さない理由を記録する。
- メリット: 実装変更ゼロ。
- 注意: §6 の理由から、Fidelity を掲げる方針との齟齬が残る。
  experimental の回避策も正当化されないまま残る。

### 判断材料

- **方針 A は明確に低コスト・低リスク**で、単独でも価値がある。まず A を入れてから
  B を検討する段階的導入が現実的。
- 方針 C は将来性が高いが、型の緩和というトレードオフがあり、
  拡張が 2〜3 個増えてから判断しても遅くない。
- リダイレクトするかしないか（§4.4）は**本トピックとは独立**に据え置いてよい。
  方針 A は「非リダイレクトのままコードだけ §6.3 準拠にする」変更として実施できる。
- `error_description` に `e.message` をそのまま載せる点の見直しは
  `study-material/error-response-cross-endpoint.md` の方針に従うこと（本ファイルでは決めない）。

## 8. 未確認・不明点

- OIDF Conformance Suite の Basic OP テストプランに、Request Object の
  エラーコードを検証する module が含まれるかは**未確認**。
  含まれない場合、本改善は conformance 通過には影響せず、純粋に品質改善となる。
  （`tasks/p3-basic-op-conformance-module-list-confirmation.md` で確認予定の
  module 一覧と突き合わせるとよい）
- `invalid_request` に潰す判断が意図的だったかは、コミット履歴からは読み取れなかった。
  設計判断であれば方針 D、見落としであれば方針 A が妥当となるため、
  この点は実装者（人間）の記憶で補完してほしい。

## 9. タスク案

- [ ] OIDC Core §6.3 の 4 コードの逐語定義を一次資料で確認し、本ファイルの引用を確定する
- [ ] OIDF Conformance Suite に Request Object のエラーコードを検証する module があるかを確認する
- [ ] 方針 A / B / C / D のいずれを採るかを人間が判断する
- [ ] 方針 A 採用時の実装:
  - [ ] `AuthorizationErrorCode` に `InvalidRequestObject` / `InvalidRequestUri` を追加する
  - [ ] `packages/core/src/authorization-request.ts` の `RequestObjectError` 変換先を
        `InvalidRequestObject` に変更する
  - [ ] `packages/core/src/request-object.ts` の `RequestObjectError` の doc コメントを
        新しい変換先に合わせて更新する
- [ ] テスト要件（TDD で先に Red を作る）:
  - [ ] `should reject a request object with a broken JWS structure with invalid_request_object`
  - [ ] `should reject a request object signed with an unsupported alg with invalid_request_object`
  - [ ] `should reject a request object whose signature does not verify with invalid_request_object`
  - [ ] `should reject a request object when no client JWKS is registered with invalid_request_object`
  - [ ] `should still reject the request parameter with request_not_supported when the feature is disabled`
        （`request_not_supported` と `invalid_request_object` の使い分けを固定する）
  - [ ] `should not redirect when the request object cannot be parsed`（§4.4 の既存挙動を回帰から守る）
- [ ] 方針 B を選ぶ場合の追加タスク:
  - [ ] `packages/experimental/src/par/resolve-request-uri.ts` の `PushedRequestUriError` を
        `AuthorizationError` へ置き換える
  - [ ] 生成コードの authorize ルートからエラー型分岐を 1 つ削減する（CLI テンプレートを修正）
  - [ ] `RELEASE.md` の experimental 自動 changeset 運用（patch 固定）に沿って変更を通す
- [ ] `packages/cli` のテンプレートに影響が出る場合は各 sample の `conformance.test.ts` を再生成する
- [ ] 完了条件: `pnpm --filter @maronn-openid-connect/core test`、
      `pnpm --filter @maronn-openid-connect/experimental test`、`pnpm --filter @maronn-openid-connect/cli test` がパスすること

## 関連トピック

- `study-material/error-response-cross-endpoint.md`（エラーレスポンス形式の共通方針）
- `study-material/request-object-rejection-and-discovery-honesty.md`（非サポート時の広告整合）
- `study-material/ext-jar-request-object-rfc9101.md`（JAR 正式採用の検討）
- `study-material/extension-pushed-authorization-requests-par.md`（PAR の設計）
