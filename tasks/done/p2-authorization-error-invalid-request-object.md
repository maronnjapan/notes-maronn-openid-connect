# [P2] Request Object の検証失敗を `invalid_request_object` で返す（OIDC Core §6.3）

## ステータス

✅ 完了

方針 A（enum への 2 値追加と変換先の差し替え）で実装した。

- core: `AuthorizationErrorCode` に `InvalidRequestUri` / `InvalidRequestObject` を追加し、`resolveRequestObjectParams` の `RequestObjectError` 変換先を `invalid_request_object` に変更した。非リダイレクト挙動（redirect_uri / state を伴わない OP 上のエラー表示）は変更せず、テストで固定した
- 「実装前に人間が確認すること」の項は、次の根拠から意図的な設計ではなく実装漏れと判断して実装に進んだ。enum のコメントが §6.3 を明記しながら 2 コードだけ欠けていたこと、`packages/experimental/src/par/resolve-request-uri.ts` が「closed な enum に `invalid_request_uri` が無い」ことを制約としてコメントに残していたこと
- cli: 生成 conformance テストへ「壊れた Request Object → 非リダイレクトの `invalid_request_object` エラーページ」の契約テストを追加し（`requestObjectValueConformanceBlock`）、4 sample を再生成した
- 一次資料の確認: OIDC Core 1.0 の Authentication Error Response の表で 4 コードの定義文を確認した（`invalid_request_object`: "The request parameter contains an invalid Request Object."）
- semver: core は minor（enum 追加とエラーコードの挙動変更）、cli は patch（生成コードのみの変更）。changeset に `invalid_request` 前提クライアントへの影響を記載
- 検証: core 1170 / cli 868 / experimental 314、hono conformance 210、typecheck、ci-gate / supply-chain / release-contract、E2E 35+16+16+16 すべて green
- 方針 B（experimental PAR の `PushedRequestUriError` を core のエラー型へ統合）は本タスクに含めず、別タスク判断のまま

## 背景

本リポジトリは Request Object by value（`request` パラメータ、OIDC Core 1.0 §6.1）を実装済み
（`tasks/done/p1-basic-op-request-object-by-value.md`）だが、その検証失敗を
**すべて `invalid_request` に潰している**。

OIDC Core §6.3 は Request Object 関連のエラーコードを 4 つ定義しており、本リポジトリは
そのうち 2 つ（`request_not_supported` / `request_uri_not_supported`）しか持たない。
`invalid_request_object` と `invalid_request_uri` が `AuthorizationErrorCode` に存在しない。

影響:

1. **クライアントが対処を判別できない**。`request_not_supported`（Request Object の使用をやめるべき）と
   `invalid_request_object`（Request Object の生成処理を直すべき）は対処が正反対だが、
   後者が `invalid_request` に潰れるため区別がつかない。
2. **拡張パッケージが core のエラー語彙に参加できない**。
   `packages/experimental/src/par/resolve-request-uri.ts:16-25` は
   「`AuthorizationErrorCode` は closed な enum で `invalid_request_uri` を含まないため」という
   理由をコメントに明記したうえで、独自の `PushedRequestUriError` を定義している。
   生成コードの authorize ルートはエラー型を 2 系統捕捉する必要があり、
   拡張を足すたびに同じ回避策が増える構造になっている。

セキュリティ上の劣化は無い（不正な Request Object は現状でも確実に拒否される）。
本タスクは相互運用性・診断性・拡張性の改善。

詳細な検討は
`study-material/done/authorization-error-code-invalid-request-object-and-enum-extensibility.md` を参照。

## 対象ファイル

- `packages/core/src/authorization-request.ts`（`AuthorizationErrorCode` の定義、`RequestObjectError` の変換箇所）
- `packages/core/src/request-object.ts`（`RequestObjectError` の doc コメント）
- `packages/core/src/authorization-request.test.ts`（テスト追加）
- `packages/core/src/request-object.test.ts`（テスト追加）
- （方針 B 採用時）`packages/experimental/src/par/resolve-request-uri.ts`、
  `packages/cli/src/frameworks/*/templates.ts`

## 仕様参照

- **OpenID Connect Core 1.0 §6.3 Authentication Request Errors**
  Request Object を扱う OP が返しうるエラーコードを 4 つ定義する。
  - `invalid_request_uri`: `request_uri` が到達不能、またはエラー／不正なデータを返した
  - `invalid_request_object`: `request` パラメータが不正な Request Object を含む
  - `request_not_supported`: OP が §6.1 の `request` パラメータをサポートしない
  - `request_uri_not_supported`: OP が §6.2 の `request_uri` パラメータをサポートしない
- **OpenID Connect Core 1.0 §3.1.2.6 Authentication Error Response**
  §6.3 のコードはここに定義された OIDC 固有エラーコードへ追加される形で使われる。
- **RFC 9101 §5 (JAR)**: 同じく `invalid_request_object` / `invalid_request_uri` を使用。
  JAR を将来正式サポートする場合に必須になる。
- **RFC 9126 §2.3 (PAR)**: `invalid_request_uri` を使用。experimental PAR が既に必要としている。

> 逐語確認は実装時に実施済み。OIDC Core 1.0 の Authentication Error Response の
> エラーコード表で 4 コードの定義文を確認した
> （`invalid_request_object`: "The request parameter contains an invalid Request Object."）。

## 現状の実装

### エラーコードの定義（2 つ欠落）

```ts
// packages/core/src/authorization-request.ts:21-42
export enum AuthorizationErrorCode {
  // ... OAuth 2.1 §4.1.2.1 の 7 コード ...
  // ... OIDC Core §3.1.2.6 の 4 コード ...
  // OIDC Core 1.0 Section 6.3
  RequestNotSupported = 'request_not_supported',
  RequestUriNotSupported = 'request_uri_not_supported',
  // ↑ §6.3 と明記しながら invalid_request_object / invalid_request_uri が無い
  RegistrationNotSupported = 'registration_not_supported',
}
```

### すべての失敗が `invalid_request` に潰される箇所

```ts
// packages/core/src/authorization-request.ts:826-835
} catch (e) {
  if (e instanceof RequestObjectError) {
    throw new AuthorizationError(
      AuthorizationErrorCode.InvalidRequest,   // ← invalid_request_object であるべき
      e.message,
    );
  }
  throw e;
}
```

`parseRequestObject`（`packages/core/src/request-object.ts:64-161`）が投げる次の失敗が
すべてこの 1 箇所を通る:

- JWS compact serialization でない（セグメント数不正 / JWE の 5 セグメント）
- header / payload が base64url JSON でない、payload が JSON オブジェクトでない
- `alg` 欠落 / 未対応の `alg`
- `alg: "none"` を非許可構成で受信 / `none` なのに署名部が空でない
- クライアント JWKS 未登録
- `kid` に一致する鍵が無い
- 署名検証失敗

### 拡張側の回避策

```ts
// packages/experimental/src/par/resolve-request-uri.ts:16-25
/**
 * `AuthorizationErrorCode` は closed な enum で `invalid_request_uri` を含まないため、
 * (中略)
 */
export class PushedRequestUriError extends Error {
  readonly code: 'invalid_request_uri' | 'invalid_request';
  // ...
}
```

### 併せて確認すべき既存挙動（変更しない）

`packages/core/src/authorization-request.ts:1136-1157` の順序により、
Request Object のパースは **redirect_uri 解決より前**に走る。そのため §4 の
`AuthorizationError` は `redirectUri` / `state` を伴わず、リダイレクトではなく
OP 上のエラー表示になる。これはコード中のコメントで
「壊れた Request Object から redirect 先を信頼できないため」と意図的な設計として明記されている。

**本タスクではこの非リダイレクト挙動を変更しない**。エラーコードのみを §6.3 準拠にする。
回帰させないようテストで固定する（テスト要件参照）。

## 修正方針

### 方針 A（本タスクのスコープ）: enum に 2 値を追加し、変換先を差し替える

- [x] `AuthorizationErrorCode` に以下を追加する（既存の値・シリアライズ形は不変＝後方互換）
  ```ts
  // OIDC Core 1.0 §6.3
  InvalidRequestUri = 'invalid_request_uri',
  InvalidRequestObject = 'invalid_request_object',
  ```
- [x] `packages/core/src/authorization-request.ts:826-835` の変換先を
      `AuthorizationErrorCode.InvalidRequestObject` に変更する
- [x] `packages/core/src/request-object.ts:19-24` の `RequestObjectError` の doc コメントを
      「呼び出し側は `invalid_request_object`（OIDC Core §6.3）へ変換する」に更新する
- [x] `request_not_supported`（機能トグル無効時）との使い分けが変わっていないことを確認する
      — `rejectUnsupportedRequestParams`（`authorization-request.ts:853-888`）は無変更

### 方針 B（別タスクとして検討）: experimental PAR を core のエラー型へ統合

本タスクでは実施しない。方針 A 完了後に、
`PushedRequestUriError` を `AuthorizationError` へ置き換えて生成コードの
エラー型分岐を 1 系統に減らすかを別途判断する
（`RELEASE.md` の experimental 自動 changeset 運用に沿う必要があるため）。

### 実装前に人間が確認すること

- [x] `invalid_request` に潰していたのが**意図的な設計判断**だったかを確認する。
      意図的であれば本タスクは取り下げ、その理由をコメントに明記する方向へ切り替える
      （study-material の方針 D）。コミット履歴からは判断できなかった。

## テスト要件

TDD で先に Red を作る。テストケース名は「should + 動詞」形式。

`packages/core/src/authorization-request.test.ts`:

- [x] `should reject a request object with a broken JWS structure with invalid_request_object`
- [x] `should reject a request object with an unsupported signing alg with invalid_request_object`
- [x] `should reject a request object whose signature does not verify with invalid_request_object`
- [x] `should reject a request object when no client JWKS is registered with invalid_request_object`
- [x] `should reject an unsigned request object with invalid_request_object when allowUnsigned is false`
- [x] `should reject the request parameter with request_not_supported when the feature is disabled`
      （`invalid_request_object` と `request_not_supported` の使い分けを固定する）
- [x] `should throw without a redirect uri when the request object cannot be parsed`
      （§現状の実装 の非リダイレクト挙動を回帰から守る。`AuthorizationError` の
      `redirectUri` / `state` が `undefined` であることを具体値で固定する）

`packages/core/src/request-object.test.ts`:

- [x] 既存の `RequestObjectError` を投げるケース一覧が網羅されていることを確認し、
      不足があれば追加する（変換先が変わっても投げる条件は不変であることの担保）

アサーションは合格値を一意に固定する（`expect(error.error).toBe('invalid_request_object')` の形。
`toContain` / `expect.any` は使わない）。

## 完了条件

- [x] 上記テストがすべてパスする
- [x] `AuthorizationErrorCode` に `invalid_request_object` / `invalid_request_uri` が存在する
- [x] Request Object のパース／署名検証失敗が `invalid_request_object` で返る
- [x] 非リダイレクト挙動が変わっていない（テストを更新のうえパスする。§6.3 対応でエラーコードのみ変更）
- [x] 実行コマンド:
  ```bash
  pnpm --filter @maronn-openid-connect/core test
  pnpm --filter @maronn-openid-connect/experimental test
  pnpm --filter @maronn-openid-connect/cli test
  ```
- [x] `packages/core` の出荷物が変わるため changeset を追加する
      （`packages/experimental/src` の変更は含めないこと。含める場合は
      `RELEASE.md` の「experimental の自動 publish」に従い手書き changeset を作らない）
