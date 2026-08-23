# [P2] 出荷済み `request`（by value）Request Object に `exp`/`aud`/`iss` クレーム検証を追加する

## ステータス

🟠 High / 未着手

## 背景

`request` パラメータ（OIDC Core 1.0 §6.1, by value の signed Request Object）は
`tasks/done/p1-basic-op-request-object-by-value.md` で実装・出荷済みで、Discovery でも
`request_parameter_supported: true` として**広告している**。しかし現在の
`parseRequestObject`（`packages/core/src/request-object.ts`）は JWS 署名と `alg`
ホワイトリストまでしか検証せず、**Request Object（JWT）自身の登録クレーム
（`exp` / `nbf` / `aud` / `iss` / 入れ子 `request`）を一切検証していない**。

このため、

- `exp` 未検証 → 期限の無い signed Request Object（傍受された `request=...` 付き認可 URL）を
  **無期限にリプレイ可能**。
- `aud` 未検証 → 別 AS 宛に署名された Request Object を本 OP に投げ込む
  **オーディエンス混同（cross-AS confusion）** を検知できない。
- `iss` 未検証 → `iss == client_id` を確認しない（JAR の要求）。
- 入れ子の `request`/`request_uri` claim を黙殺（OIDC Core §6.1 は MUST NOT）。

「署名は検証するがクレームは検証しない」状態は、署名付き認可リクエストの目的
（完全性＋文脈束縛）の半分が欠ける。広告済み機能の健全性を担保するため、`exp`/`aud` を
中核にクレーム検証を追加する。

検討根拠: `study-material/done/request-object-claim-validation-replay-and-audience.md`
関連（重複回避）: `study-material/ext-jar-request-object-rfc9101.md`（JAR 実装の是非）、
`study-material/jwt-bcp-rfc8725.md`（汎用 JWT 検証ヘルパー提案）、
`study-material/done/jwt-clock-skew-and-time-tolerance.md`（`exp`/`nbf` 許容誤差の既存方針）。

## 対象ファイル

- `packages/core/src/request-object.ts`（claim 検証の追加）
- `packages/core/src/request-object.test.ts`
- `packages/core/src/authorization-request.ts`（OP issuer / 検証済み client_id を `parseRequestObject` へ渡す経路）
- `packages/core/src/authorization-request.test.ts`
- `packages/cli/src/frameworks/hono/templates.ts` / `packages/cli/src/frameworks/web-standard/templates.ts`
- `packages/cli/src/__tests__/*`（generator テスト）
- `samples/*/src/oidc-provider/conformance.test.ts`（CLI 生成物。修正元は必ず `packages/cli`）

`samples/*/src/oidc-provider` は CLI 生成物なので、修正元は必ず `packages/cli` に置く。

## 仕様参照

- OIDC Core 1.0 §6.1（Passing a Request Object by Value）:
  Request Object は登録 Claim `iss`/`aud` を含めてよい。`request`/`request_uri` は
  Request Object 内に **MUST NOT** 含めてはならない。
  https://openid.net/specs/openid-connect-core-1_0.html#JWTRequests
- RFC 9101（JAR）§6.1（AS 側の Request Object 検証）:
  `iss` があれば `client_id` と一致、`aud` があれば AS の issuer 識別子を含む、`exp` 検証。
  https://www.rfc-editor.org/rfc/rfc9101#section-6.1
- RFC 8725（JWT BCP）§2.1（期限）/ §3.8（iss/sub）/ §3.9（Cross-JWT Confusion）:
  https://www.rfc-editor.org/rfc/rfc8725
- RFC 9700（OAuth 2.0 Security BCP）: https://www.rfc-editor.org/rfc/rfc9700

> 一次資料の逐語・既定厳格度は実装前に再確認すること（本環境では spec サイトへのアクセスが制限されることがある）。

## 現状の実装

```ts
// packages/core/src/request-object.ts (parseRequestObject)
// 署名検証に成功すると payload をそのまま返す。exp/nbf/aud/iss/jti は読まれない。
for (const jwk of candidates) {
  // ... 署名検証 ...
  if (await verify(signingInput, signatureB64, publicKey)) {
    return payload as Record<string, unknown>; // ← claim 検証なし
  }
}
```

```ts
// packages/core/src/authorization-request.ts
// REQUEST_OBJECT_OVERRIDE_KEYS は request / request_uri を含まないため入れ子は黙殺。
// validateAuthorizationRequest は OP issuer を引数で受け取っていない。
```

## 修正方針

採用する厳格度（`exp`/`aud`/`iss` を「あれば検証」か「必須」か）は人間が選択する。
推奨は **方針A**（`exp` 必須 + `aud`/`iss` は「あれば一致」）を既定にし、Basic OP の
unsigned 互換（`allowUnsigned` 経路 / `oidcc-*` module）を壊さないことを回帰確認する。

- [ ] **方針A（最小・推奨）**: `parseRequestObject` のオプションに以下を追加する
  - `expectedIssuer?: string`（= OP issuer。`aud` 検証に使う）
  - `expectedClientId?: string`（`iss` 検証に使う）
  - `requireExp?: boolean`（既定 true 推奨）
  - `clockSkewSeconds?: number`（既存 clock-skew 方針に合わせる）
  - 検証規則:
    - `exp` が無い（かつ `requireExp`）／ `exp <= now - skew` → `RequestObjectError`
    - `nbf` があり `nbf > now + skew` → 拒否
    - `aud` があり `expectedIssuer` を含まない → 拒否
    - `iss` があり `expectedClientId` と不一致 → 拒否
    - payload に `request` / `request_uri` claim があれば拒否（§6.1 MUST NOT）
- [ ] `validateAuthorizationRequest` に OP issuer を渡す経路を追加し、検証済み `client_id` と
  ともに `parseRequestObject` のオプションへ渡す
- [ ] **方針B（任意・FAPI 寄り）**: `aud`/`iss` も必須化するモードをオプションで段階適用
- [ ] **方針C（任意・P3 別タスク化可）**: `jti` replay cache は store 依存のため本タスクでは扱わず、
  `study-material/resolver-and-store-contract.md` の CAS 契約に沿って別途検討する

実装例（方針A・claim 検証部）:

```ts
const now = Math.floor(Date.now() / 1000);
const skew = options.clockSkewSeconds ?? 0;
const exp = typeof payload['exp'] === 'number' ? payload['exp'] : undefined;
if (options.requireExp !== false && exp === undefined) {
  throw new RequestObjectError('request object is missing exp');
}
if (exp !== undefined && exp <= now - skew) {
  throw new RequestObjectError('request object has expired');
}
const nbf = typeof payload['nbf'] === 'number' ? payload['nbf'] : undefined;
if (nbf !== undefined && nbf > now + skew) {
  throw new RequestObjectError('request object is not yet valid (nbf)');
}
if (options.expectedClientId !== undefined && typeof payload['iss'] === 'string'
    && payload['iss'] !== options.expectedClientId) {
  throw new RequestObjectError('request object iss does not match client_id');
}
if (options.expectedIssuer !== undefined && payload['aud'] !== undefined) {
  const aud = payload['aud'];
  const ok = Array.isArray(aud) ? aud.includes(options.expectedIssuer)
                                 : aud === options.expectedIssuer;
  if (!ok) throw new RequestObjectError('request object aud does not include this issuer');
}
if (payload['request'] !== undefined || payload['request_uri'] !== undefined) {
  throw new RequestObjectError('request object must not contain request/request_uri');
}
```

## テスト要件

- [ ] `exp` が無い signed Request Object（`requireExp` 既定）→ `invalid_request` で拒否
- [ ] `exp` が過去（skew 超過）→ 拒否、`exp` が将来 → 通過
- [ ] `nbf` が未来（skew 超過）→ 拒否
- [ ] `aud` が OP issuer を含まない → 拒否、含む（文字列／配列の両形式）→ 通過
- [ ] `iss` が `client_id` と不一致 → 拒否、一致 → 通過
- [ ] payload に入れ子 `request` / `request_uri` がある → 拒否（OIDC Core §6.1 MUST NOT）
- [ ] 既存の署名検証・`response_type`/`client_id` 一致検証にリグレッションが無い
- [ ] Basic OP unsigned 互換（`allowUnsigned`）経路と `oidcc-*` module 相当のフローが壊れない
- [ ] CLI generator / sample `conformance.test.ts`: 生成 OP がリプレイ／オーディエンス混同を拒否する契約が固定される
- [ ] `pnpm --filter @maronn-openid-connect/core test` と `pnpm --filter @maronn-openid-connect/cli test` がパスする

## 完了条件

- 上記テストがすべて通る
- 出荷済みの `request`（by value）が `exp`/`aud`/`iss` を検証し、リプレイ／オーディエンス混同を拒否する
- 入れ子 `request`/`request_uri` を拒否する
- Basic OP の signed/unsigned 互換フローにリグレッションが無い
- Discovery の広告（`request_parameter_supported: true`）と実装挙動が整合する
</content>
