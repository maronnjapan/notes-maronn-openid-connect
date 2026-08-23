# [P1] Essential な `acr` クレーム要求を満たせないときに ID Token を発行しない

## ステータス

🔴 Critical / 未着手

## 背景

OIDC Core 1.0 §5.5.1.1 は、`claims` パラメータをサポートする OP に対して次の 2 つを MUST として課す。

1. `acr` が Essential Claim（`{"essential": true, "values": [...]}`）として要求されたら、要求値のいずれかに一致する `acr` を返さなければならない
2. その要件を満たせない場合、**その結果を「認証失敗」として扱わなければならない**

本リポジトリは `claims.id_token.acr.values` を `AcrResolver` へ「要求値」として渡すところまでは実装済みだが、**resolver が返した `acr` が要求値に一致するかを検証していない**。resolver が要求外の値を返しても、`undefined` を返して `acr` クレームが省略されても、ID Token はそのまま発行される。`essential` フラグはパースされ型にも保持されているが、リポジトリ全体でどこからも参照されていない（dead field）。

影響:

- RP が「多要素認証でなければならない」と Essential 要求しても、OP が単要素セッションのまま認可コード・ID Token を発行する。RP 側が `acr` の欠落を厳格に検査していなければ、**要求した認証強度を満たさないセッションを受け入れてしまう**
- Step-up Authentication（RFC 9470）の前提が成立しない
- `claims_parameter_supported: true` を広告しながら Core の MUST を満たしていない状態になる

詳細な検討・仕様原文の引用・方針比較は `study-material/done/claims-essential-acr-unmet-authentication-failure.md` を参照。

### 本タスクの範囲

study-material の**方針 A（Token Endpoint での一致検証 = 黙って発行しない）を最小実装として入れる**。

方針を問わず「Essential 要求を満たさない ID Token を黙って発行しない」ことは必要であり、ここが最も小さく閉じた変更単位である。
一方、**認可エンドポイントで判定して `unmet_authentication_requirements` を redirect で返す（方針 B）と、追加認証を要求する（方針 C）は本タスクの範囲外**とし、`study-material/done/claims-essential-acr-unmet-authentication-failure.md` に検討として残す。

## 対象ファイル

- `packages/core/src/token-response.ts`（`resolveAcrAmr` / `ResolveAcrAmrInput`）
- `packages/core/src/token-response.test.ts`（テスト追加）
- `packages/cli/src/frameworks/hono/templates.ts`（token ルートのエラーハンドリング。生成 OP が新しい失敗を正しい HTTP レスポンスへ変換すること。`samples/*/src/oidc-provider` を直接編集しないこと）
- `packages/cli/src/frameworks/hono/templates.ts` 内の `conformance.test.ts` 生成コード（契約テストの追加）
- `study-material/done/claims-parameter-value-values-essential.md`（一般則の結論に例外の注記を追加）

## 仕様参照

- **OpenID Connect Core 1.0 §5.5.1.1 Requesting the "acr" Claim** — https://openid.net/specs/openid-connect-core-1_0.html#acrSemantics

  > If the `acr` Claim is requested as an Essential Claim for the ID Token with a `value` or `values` parameter requesting specific Authentication Context Class Reference values and the implementation supports the `claims` parameter, the Authorization Server MUST return an `acr` Claim Value that matches one of the requested values. The Authorization Server MAY ask the End-User to re-authenticate with additional factors to meet this requirement. **If this is an Essential Claim and the requirement cannot be met, then the Authorization Server MUST treat that outcome as a failed authentication attempt.**
  >
  > ... **If the Claim is not Essential and a requested value cannot be provided, the Authorization Server SHOULD return the session's current `acr` as the value of the `acr` Claim.** If the Claim is not Essential, the Authorization Server is not required to provide this Claim in its response.

- **OpenID Connect Core 1.0 §5.5.1 Individual Claims Requests** — https://openid.net/specs/openid-connect-core-1_0.html#IndividualClaimsRequests

  > ... the Authorization Server MUST NOT generate an error when Claims are not returned, whether they are Essential or Voluntary, **unless otherwise specified in the description of the specific claim.**

  `acr`（§5.5.1.1）と `sub`（`value` メンバーの説明）はこの但し書きの**例外**にあたる。すなわち「Essential でもエラーにしない」という一般則は `acr` には適用されない。

- **OpenID Connect Core 1.0 §3.1.2.1** — `acr_values` は Voluntary Claim としての要求であること（Essential 要求との差）
- **RFC 6749 §5.2** — Token Endpoint のエラーレスポンス形式

## 現状の実装

`packages/core/src/token-response.ts`:

```ts
export async function resolveAcrAmr(input: ResolveAcrAmrInput): Promise<ResolvedAcrAmr> {
  const { subject, clientId, acr, amr, requestedAcrValues, claims, acrResolver } = input;

  if (acr !== undefined || amr !== undefined) return { acr, amr };
  if (!acrResolver) return { acr: undefined, amr: undefined };

  // OIDC Core 1.0 §5.5.1.1: claims.id_token.acr.values is equivalent to
  // requesting these acr values. Use it to seed acrResolver when the request
  // did not provide a separate `acr_values` parameter.
  let effectiveRequestedAcrValues = requestedAcrValues;
  if (effectiveRequestedAcrValues === undefined && claims?.id_token) {
    const acrEntry = claims.id_token['acr'];
    if (acrEntry && Array.isArray(acrEntry.values)) {
      const stringValues = acrEntry.values.filter((v): v is string => typeof v === 'string');
      if (stringValues.length > 0) {
        effectiveRequestedAcrValues = stringValues.join(' ');
      }
    }
  }

  const result = await acrResolver({
    userId: subject,
    clientId,
    requestedAcrValues: effectiveRequestedAcrValues,
  });

  return { acr: result?.acr, amr: result?.amr };   // ← 一致検証なし・essential 未参照
}
```

問題点:

- `acrEntry.essential` が読まれていない
- `result?.acr` が要求値のいずれかと一致するかが検証されていない
- resolver が `undefined` を返すと `acr` が省略された ID Token が発行される
- `claims.id_token.acr.value`（単数形）が考慮されていない。§5.5.1.1 は `value` または `values` と規定しており、`value` 単数のみを送る RP を取りこぼす

## 修正方針

- [ ] **`claims.id_token.acr` の要求を「値制約 + essential フラグ」として取り出すヘルパーを追加する**
  - [ ] `values`（配列）だけでなく `value`（単数）も要求値として扱う
  - [ ] `essential === true` のときだけ強制の対象とする（`essential` 省略 / `false` は従来どおり Voluntary）
  - [ ] `acr_values` リクエストパラメータ由来の要求は Voluntary（§3.1.2.1 の Note）であり、強制の対象にしない。Essential 判定は `claims.id_token.acr.essential` のみを根拠にする
- [ ] **`resolveAcrAmr` に一致検証を追加する**
  - [ ] Essential 要求があり、解決された `acr` が `undefined` の場合はエラーを投げる
  - [ ] Essential 要求があり、解決された `acr` が要求値のいずれとも一致しない場合はエラーを投げる
  - [ ] Essential 要求が無い（Voluntary）場合は従来どおり。値が一致しなくてもエラーにしない（§5.5.1 の一般則）
  - [ ] `acr` / `amr` が直接指定されている経路（refresh_token grant の §12.1 保持）は従来どおり素通しする。`claims` が refresh 経路へ伝播していない現状（`study-material/refresh-grant-claims-context-not-preserved.md`）を前提に、本タスクの対象は authorization_code grant に限定する旨をコメントで明記する
- [ ] **投げるエラーの種別を決めて実装する**
  - [ ] core は既存の `TokenError` を使う。`error` は RFC 6749 §5.2 の `invalid_grant`（付与では要求された認証要件を満たせない）とし、`error_description` に「Essential acr requirement not met」旨を含める
  - [ ] `error_description` に要求値をそのまま反映しない（`study-material/done/error-description-input-reflection-and-length-bound.md` の方針に従う）
- [ ] **生成 OP（`packages/cli`）が新しい失敗を正しく HTTP レスポンスへ変換することを確認する**
  - [ ] token ルートの `catch` は既に `TokenError` を `error` / `error_description` + `Cache-Control: no-store` で返すため、追加の分岐は不要である見込み。実際にそうなることをテストで確認する
- [ ] **`study-material/done/claims-parameter-value-values-essential.md` に注記を追加する**
  - [ ] 「Essential でも取得できなければエラーにしない」という結論は §5.5.1 の但し書き（`unless otherwise specified in the description of the specific claim`）により `acr` / `sub` には適用されないことを明記し、本タスクと `study-material/claims-sub-value-request-binding.md` を参照する

実装例（`resolveAcrAmr` 内）:

```ts
interface EssentialAcrRequest { values: string[]; }

/** OIDC Core 1.0 §5.5.1.1: essential な acr 要求だけを取り出す。Voluntary は null。 */
function extractEssentialAcrRequest(claims?: ClaimsParameter): EssentialAcrRequest | null {
  const entry = claims?.id_token?.['acr'];
  if (!entry || entry.essential !== true) return null;
  const values: string[] = [];
  if (typeof entry.value === 'string') values.push(entry.value);
  if (Array.isArray(entry.values)) {
    for (const v of entry.values) if (typeof v === 'string') values.push(v);
  }
  return values.length > 0 ? { values } : null;
}

// resolveAcrAmr の acrResolver 呼び出し直後:
const essential = extractEssentialAcrRequest(claims);
if (essential && (result?.acr === undefined || !essential.values.includes(result.acr))) {
  // OIDC Core 1.0 §5.5.1.1: MUST treat that outcome as a failed authentication attempt.
  throw new TokenError(
    TokenErrorCode.InvalidGrant,
    'The essential acr claim request could not be satisfied',
  );
}
```

## テスト要件

`packages/core/src/token-response.test.ts`（`describe('resolveAcrAmr')` 配下）:

- [ ] `should throw when an essential acr request is not satisfied by the resolver`（resolver が要求外の acr を返す）
- [ ] `should throw when an essential acr request is made and the resolver returns undefined`
- [ ] `should return the resolved acr when it matches one of the essential requested values`
- [ ] `should accept a single value member for an essential acr request`（`{"essential": true, "value": "..."}`）
- [ ] `should not throw when the acr claim request is voluntary and unmatched`（`essential` 省略）
- [ ] `should not throw when the acr claim request sets essential to false and is unmatched`
- [ ] `should not throw when acr is requested only through the acr_values parameter`（§3.1.2.1 の Note: `acr_values` は Voluntary）
- [ ] `should skip the essential acr check when acr is directly provided`（refresh_token grant の §12.1 保持経路が影響を受けないこと）
- [ ] `should still seed the resolver with claims.id_token.acr.values when acr_values is absent`（既存挙動の回帰固定）

`packages/cli/src/frameworks/hono/templates.ts` が生成する `conformance.test.ts`（生成元を変更すること）:

- [ ] `should reject the token request when an essential acr claim request cannot be satisfied`
  - 認可リクエストに `claims={"id_token":{"acr":{"essential":true,"values":["urn:example:high"]}}}` を付けて認可コードを取得し、Token Endpoint が `invalid_grant` を返すこと
  - レスポンスに `Cache-Control: no-store` が付くこと
- [ ] `should issue an ID Token whose acr matches the essential request when the resolver satisfies it`

## 完了条件

- [ ] 上記テストがすべて通る
- [ ] `pnpm --filter @maronn-openid-connect/core test`
- [ ] `pnpm --filter @maronn-openid-connect/cli test`
- [ ] `pnpm typecheck`
- [ ] `samples/*` を再生成し、`pnpm run test:conformance` 相当（各 sample の `conformance.test.ts`）が通る
- [ ] `study-material/done/claims-parameter-value-values-essential.md` に例外の注記が入っている
- [ ] `study-material/ext-step-up-authentication-rfc9470.md` の差分表にある `unmet_authentication_requirements` の 🟡 行が、本タスクと後続検討（方針 B / C）への参照に更新されている
