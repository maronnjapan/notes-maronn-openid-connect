# [P2] 受信 JWS 検証で `alg` を持たない JWK を受理する（RFC 7517 §4.4 は OPTIONAL）

## ステータス

🟡 Medium / 未着手

## 背景

本 OP が外部から受け取った JWS を検証する経路は 2 つある。

- `validateIdTokenHint()`（`packages/core/src/id-token.ts`）— `id_token_hint` の署名検証
- `parseRequestObject()`（`packages/core/src/request-object.ts`）— `request` パラメータの署名検証

RFC 7517 §4.4 は JWK の `alg` を **OPTIONAL** と定めるが、現状はどちらの経路でも
`alg` を持たない JWK では署名検証が失敗する。

- `validateIdTokenHint` は候補鍵を `jwks.keys.filter((k) => k.alg === headerAlg)` で選び、
  さらにループ内で `if (jwk.alg !== headerAlg) continue` するため、`alg` 未設定の鍵は
  **`kid` が一致していても必ず除外される**。RSA / EC を問わず検証不能。
- `parseRequestObject` は候補選択では `alg` 欠落を許容している（`if (jwk.alg && jwk.alg !== alg) continue`）が、
  `extractAlgorithmParamsFromJwk` が RSA JWK に `alg` を要求して throw し、
  `catch { continue }` で握り潰されるため、**RSA + `alg` 無しでは結局検証できない**。
  EC は `crv` から導出されるため通る。

結果として「同じ受信 JWS 検証なのに 2 経路で挙動が違う」「仕様上まったく正当な JWK Set を拒否する」
という 2 つの問題が同居している。署名アルゴリズムを決める権威は RFC 7515 §4.1.1 のとおり
**JWS ヘッダの `alg`** であり、JWK の `alg` は任意の制約宣言に過ぎないため、
`alg` が無いことを理由に検証不能にする根拠は無い。

影響範囲: `request` パラメータを使うクライアントが `alg` 無しの JWKS を登録している場合、
Request Object が常に `signature verification failed` になり原因に到達できない。
Discovery で `request_parameter_supported: true` を広告している以上、
「広告した機能が現実の JWKS で動かない」状態は honesty の問題でもある。

Basic OP certification のブロッカーではない（OIDF Conformance Suite が使う鍵は `alg` を含む）。
本タスクは Fidelity と OSS 利用者体験の改善である。

検討詳細は `study-material/done/inbound-jwks-alg-optional-and-key-selection-parity.md` を参照。

追記（2026-09-03 のコードレビューで判明）:
`signingKeysToJwkSet()`（`packages/core/src/jwks.ts`）も `extractAlgorithmParamsFromJwk` を
呼ぶため、`alg` を持たない RSA の `publicJwk` を返す `SigningKeyProvider` では throw する。
生成コードはこの関数を `id_token_hint` 検証の既定 `jwksProvider` として配線しているので、
その構成では正当な hint がすべて検証不能になり、`login_required` へ落ちる。
WebCrypto の `exportKey('jwk')` は RSA 鍵で `alg` を含める（Node 22 で確認済み）ため
既定の鍵生成経路では発生しないが、PEM 変換や外部保管の JWK など `alg` を落とした
`publicJwk` を返す実装で顕在化する。修正時は同関数も対象に含め、
「`SigningKey.publicJwk` は `alg` を含むとは限らない」という同関数の JSDoc と
実装を一致させること。

> 関連（重複回避）:
> - `crit` ヘッダ拒否 / 外部鍵ヘッダ拒否などの**危険な入力の拒否**は
>   `study-material/inbound-jws-verification-crit-and-alg-binding.md`。本タスクは逆に
>   **正当な入力の受理**に限定する。
> - 受け入れ可能な `alg` 集合のポリシーは `study-material/jws-algorithm-policy-and-alg-none-defense.md`。
>   本タスクの緩和はそのポリシーの内側でのみ行い、集合そのものは変更しない。
> - `tasks/p2-signing-alg-ps256.md`（PS256 追加）は本タスクと同じ 2 箇所を触るため、
>   本タスクを先に入れると PS256 側の作業が減る。

## 対象ファイル

- `packages/core/src/crypto-utils.ts`（`extractAlgorithmParamsFromJwk`）
- `packages/core/src/id-token.ts`（`validateIdTokenHint` の候補鍵選択）
- `packages/core/src/request-object.ts`（`parseRequestObject` の候補鍵選択・import 失敗の扱い）
- `packages/core/src/jwks.ts`（`Jwk` 型の `alg` / `use` を optional にするか判断。
  `signingKeysToJwkSet` の `alg` 無し RSA `publicJwk` での throw 解消を含む）
- `packages/core/src/id-token.test.ts`
- `packages/core/src/request-object.test.ts`
- `packages/core/src/crypto-utils.test.ts`

## 仕様参照

- **RFC 7517 §4.4 "alg" (Algorithm) Parameter**: 「Use of this member is OPTIONAL.」
  同 §4.2 `use`、§4.5 `kid` もいずれも OPTIONAL。
  → `{"kty":"RSA","n":"...","e":"AQAB"}` だけの JWK Set は完全に仕様適合。
- **RFC 7515 §4.1.1 "alg" (Algorithm) Header Parameter**: 「This Header Parameter MUST be present
  and MUST be understood and processed by implementations.」
  → 署名アルゴリズムの権威は JWS ヘッダ側にある。
- **RFC 7518 §3.1 / §6.2.1.1**: `alg` 値と鍵種別（`kty` / `crv`）の対応。
  `kty=EC` + `crv=P-256` は ES256 に一意対応するなど、鍵素材から import パラメータが決まる。
- **RFC 8725 §3.1 / §3.2**: ヘッダの `alg` を鵜呑みにせず、鍵に紐づく期待アルゴリズムと突き合わせる。
  ただし「期待アルゴリズム」は JWK の `alg` フィールドに限定されない。
- **OIDC Core 1.0 §6.1**（Request Object の署名）/ **§3.1.2.1**（`id_token_hint`）。

## 現状の実装

```ts
// packages/core/src/id-token.ts（validateIdTokenHint）
const candidates = headerKid
  ? jwks.keys.filter((k) => k.kid === headerKid)
  : jwks.keys.filter((k) => k.alg === headerAlg);   // ← alg 未設定の鍵はここで全滅

for (const jwk of candidates) {
  if (jwk.alg !== headerAlg) {
    continue;                                        // ← kid 一致でも alg 未設定なら skip
  }
  const algParams = extractAlgorithmParamsFromJwk(jwk);
  ...
}
```

```ts
// packages/core/src/request-object.ts（parseRequestObject）
const candidates: Jwk[] = kid
  ? jwks.keys.filter((k) => k.kid === kid)
  : jwks.keys.slice();                     // ← id-token.ts と選択基準が異なる

for (const jwk of candidates) {
  if (jwk.alg && jwk.alg !== alg) continue;          // ← alg があるときだけ突き合わせる（正しい）
  try {
    const algParams = extractAlgorithmParamsFromJwk(jwk);  // ← RSA かつ alg 無しで throw
    publicKey = await crypto.subtle.importKey('jwk', jwk, algParams, false, ['verify']);
  } catch {
    continue;                                        // ← 原因が握り潰される
  }
  ...
}
```

```ts
// packages/core/src/crypto-utils.ts
export function extractAlgorithmParamsFromJwk(jwk) {
  if (jwk.kty === 'RSA') {
    const alg = jwk.alg;
    const hash = alg === 'RS256' ? 'SHA-256' : alg === 'RS384' ? 'SHA-384'
               : alg === 'RS512' ? 'SHA-512' : null;
    if (!hash) throw new Error(`Unsupported RSA alg: ${alg ?? '(missing)'}`);  // ← ここ
    return { name: 'RSASSA-PKCS1-v1_5', hash };
  }
  if (jwk.kty === 'EC') { /* crv から導出。alg 不要 */ }
}
```

`Jwk` 型（`packages/core/src/jwks.ts`）は `use: string` / `alg: string` を**必須**として宣言しており、
発行用（`exportPublicJwk` の戻り値）と受信検証用（`parseRequestObject` / `validateIdTokenHint` の入力）で
同じ型を使い回している。TypeScript 利用者は実データに無いフィールドを捏造して渡すことになる。

問題点:

1. 仕様上正当な `alg` 無し JWK を拒否する（相互運用性 / Fidelity）。
2. 同じ処理が 2 箇所に別実装で存在し、挙動が割れている（保守性）。
3. import 失敗と署名不一致が同じエラーに丸められ、原因が利用者に届かない（体験）。

## 修正方針

- [ ] `extractAlgorithmParamsFromJwk(jwk, headerAlg?)` に JWS ヘッダ `alg` のフォールバック引数を追加する
  - `jwk.alg` があればそれを優先し、`headerAlg` と食い違えば**従来どおり throw**（ダウングレード防止を維持）
  - `jwk.alg` が無い場合のみ `headerAlg` から `hash` を導出する
  - EC は現状どおり `crv` 優先（`headerAlg` と矛盾する場合は WebCrypto の `importKey` が失敗する）
  - 既存の 1 引数呼び出しは挙動不変（後方互換）
- [ ] `validateIdTokenHint` の候補鍵選択を「`k.alg` が未設定、または `headerAlg` と一致」に緩める
  - `kid` 一致で選ばれた鍵に対するループ内の `if (jwk.alg !== headerAlg) continue` も同じ条件に揃える
- [ ] `parseRequestObject` は候補選択条件を `validateIdTokenHint` と同じ規則に揃える
  - `kid` 無しのとき「全鍵」ではなく「`alg` 互換の鍵」に絞り、2 経路の挙動を一致させる
- [ ] （任意・要判断）候補鍵選択を共有ヘルパ（例 `selectVerificationKeys(jwks, { kid, alg })`）へ抽出し、
      両経路から呼ぶ。PS256 / EdDSA 追加時の作業を 1 箇所に集約する
- [ ] （任意・要判断）`Jwk` 型の `alg` / `use` を optional にする、または受信検証用の型を分離する。
      public API 面が増えるため `RELEASE-v0.x-scope.md` と要すり合わせ
- [ ] `parseRequestObject` の `catch { continue }` について、全候補が import 失敗した場合は
      「署名検証失敗」ではなく「検証鍵をロードできなかった」旨のメッセージにするか判断する

実装イメージ:

```ts
// crypto-utils.ts
export function extractAlgorithmParamsFromJwk(
  jwk: webcrypto.JsonWebKey,
  headerAlg?: string,
): webcrypto.RsaHashedImportParams | webcrypto.EcKeyImportParams {
  if (jwk.kty === 'RSA') {
    // RFC 7517 §4.4: JWK の alg は OPTIONAL。RFC 7515 §4.1.1 のとおり署名アルゴリズムの
    // 権威は JWS ヘッダ側にあるため、jwk.alg が無いときは headerAlg から hash を導出する。
    // jwk.alg がある場合は従来どおりそれを使い、headerAlg との一致検証は呼び出し側が行う。
    const alg = jwk.alg ?? headerAlg;
    const hash = alg === 'RS256' ? 'SHA-256'
               : alg === 'RS384' ? 'SHA-384'
               : alg === 'RS512' ? 'SHA-512' : null;
    if (!hash) throw new Error(`Unsupported RSA alg: ${alg ?? '(missing)'}`);
    return { name: 'RSASSA-PKCS1-v1_5', hash };
  }
  ...
}
```

```ts
// id-token.ts / request-object.ts 共通の候補判定
// RFC 7517 §4.4: alg は OPTIONAL。未設定の鍵は「どの alg にも紐づいていない」ため候補に残し、
// 設定されている場合のみ JWS ヘッダの alg と一致を要求する（RFC 8725 §3.1 のダウングレード防止）。
const isAlgCompatible = (jwk: Jwk) => jwk.alg === undefined || jwk.alg === headerAlg;
```

## テスト要件

`id-token.test.ts`:

- [ ] `alg` を持たない RSA JWK（`kid` あり）で署名した `id_token_hint` が検証を通る
- [ ] `alg` を持たない RSA JWK（`kid` なし）でも検証を通る
- [ ] `alg` を持たない EC JWK（`crv=P-256`）で署名した `id_token_hint` が検証を通る
- [ ] `alg` を持つ JWK で JWS ヘッダの `alg` と食い違う場合は従来どおり拒否される（回帰固定）
- [ ] `alg=none` は従来どおり拒否される（回帰固定）
- [ ] `kty=EC` / `crv=P-256` の JWK に `RS256` ヘッダの JWS を提示した場合は拒否される

`request-object.test.ts`:

- [ ] `alg` を持たない RSA JWK（`kid` あり / なし の両方）で署名した Request Object が検証を通る
- [ ] `alg` を持たない EC JWK で署名した Request Object が検証を通る（回帰固定）
- [ ] `alg` を持つ JWK で JWS ヘッダの `alg` と食い違う場合は拒否される（回帰固定）
- [ ] `supportedSigningAlgs` に含まれない `alg` は、JWK の `alg` の有無に関わらず拒否される（回帰固定）

`crypto-utils.test.ts`:

- [ ] `extractAlgorithmParamsFromJwk({kty:'RSA', n, e}, 'RS256')` が
      `{name:'RSASSA-PKCS1-v1_5', hash:'SHA-256'}` を返す
- [ ] `extractAlgorithmParamsFromJwk({kty:'RSA', n, e, alg:'RS256'})`（第 2 引数なし）が従来どおり動く
- [ ] `extractAlgorithmParamsFromJwk({kty:'RSA', n, e})`（第 2 引数なし）は従来どおり throw する
- [ ] `extractAlgorithmParamsFromJwk({kty:'RSA', n, e, alg:'RS256'}, 'RS512')` は `jwk.alg` を優先する

## 完了条件

- `pnpm --filter @maronn-openid-connect/core test` がパスすること
- `alg` を持たない JWK Set で `id_token_hint` と Request Object の双方が検証できること
- `alg` を持つ JWK に対するアルゴリズム束縛（ダウングレード防止）の既存テストが回帰しないこと
- 2 経路の候補鍵選択条件が同一になっていること（コードまたはテストで確認できる形にする）
