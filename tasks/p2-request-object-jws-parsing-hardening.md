# [P2] 署名付き Request Object の JWS パースを strict 化し、署名セグメントの strict デコードを全経路に適用する

## ステータス

🟠 High / 未着手

## 背景

JWS Compact を受信・検証する経路が複数ある。`id_token_hint`（`validateIdTokenHint`）はヘッダ／ペイロードを
strict な base64url デコード（`base64UrlToArrayBufferStrict`）で処理するが、署名付き Request Object の経路
（`parseRequestObject` / `decodeJwtSegment`）は**非 strict** な `base64UrlToArrayBuffer` を使っており、
非正規 base64url（`+`/`/`/`=`/空白、`len % 4 === 1`）を黙って受理する。さらに `crypto-utils.ts` の `verify()` は
署名セグメントを非 strict デコードしており、これは `id_token_hint` を含む全経路に共通の緩さとなっている。

経路ごとにパース強度が違うと、「厳格な検証器が見る JWS」と「本 OP が受理する JWS」の差が生まれ、
ヘッダ／ペイロード smuggling や cross-JWT confusion の温床になる。
検討詳細は `study-material/done/request-object-jws-parsing-hardening-parity.md` を参照。

> 関連：`crit` 未知パラメータ拒否・外部鍵ヘッダ（`jku`/`x5u`/`jwk`/`x5c`）拒否は
> `study-material/jws-algorithm-policy-and-alg-none-defense.md` / `tasks/p2-jwt-header-reject-unsafe-fields.md` が
> `id_token_hint` 対象で扱う。本タスクは同じ堅牢化を **Request Object 経路にも適用**し、
> strict デコードを全 JWS 受信経路（署名セグメント含む）へ広げる。

## 対象ファイル

- `packages/core/src/request-object.ts`（`decodeJwtSegment` / `parseRequestObject`）
- `packages/core/src/crypto-utils.ts`（`verify` の署名セグメントデコード、共通 strict ヘルパ）
- `packages/core/src/request-object.test.ts` / `crypto-utils.test.ts`

## 仕様参照

- RFC 7515 §2 / Appendix C: JWS の各セグメントは canonical base64url（無パディング・正規）
- RFC 8725 §3.11: strict parsing（非正規入力を拒否）
- RFC 7515 §4.1.11 / RFC 8725 §3.7: 未知の `crit` パラメータがあれば JWS を無効とする
- RFC 7515 §4.1.2/§4.1.3/§4.1.5/§4.1.6 / RFC 8725 §3.1: `jku`/`jwk`/`x5u`/`x5c` は事前登録 JWKS のみ使う OP では拒否
- OpenID Connect Core 1.0 §6.1: Request Object は署名 JWT

## 現状の実装

```ts
// packages/core/src/request-object.ts
function decodeJwtSegment(segment: string) {
  const json = new TextDecoder().decode(base64UrlToArrayBuffer(segment)); // ← 非 strict
  return JSON.parse(json);
}
// ヘッダは alg / alg=none 程度しか見ておらず、crit / jku / x5u / jwk / x5c を検査しない

// packages/core/src/crypto-utils.ts
export async function verify(...) {
  const signatureBuffer = base64UrlToArrayBuffer(signature); // ← 署名部も非 strict（全経路共通）
  ...
}
```

対して `id-token.ts` の `validateIdTokenHint` はヘッダ／ペイロードを `base64UrlToArrayBufferStrict` で処理。

## 修正方針

- [ ] strict base64url デコードを Request Object のヘッダ／ペイロード（`decodeJwtSegment`）に適用する
- [ ] `verify()` の署名セグメントデコードを strict 化する（全 JWS 経路に効く。正常系の回帰を必ず先行確認）
- [ ] Request Object の JOSE ヘッダに `crit`（未知パラメータ）／`jku`/`x5u`/`jwk`/`x5c` があれば拒否する
- [ ] 可能なら strict デコードと `assertJwsHeaderAcceptable(header)` を共通ヘルパ化し、
  `validateIdTokenHint` / `parseRequestObject` / 将来の JWS 受信経路で共有する（重複回避）
- [ ] `alg=none` の既存拒否・`allowUnsigned` 経路の空署名要件は維持する

## テスト要件

- [ ] 非正規 base64url（`+`/`/`/`=`/空白、`len % 4 === 1`）のヘッダ／ペイロードを持つ Request Object が**拒否**される
- [ ] 未知の `crit` パラメータを含む Request Object が**拒否**される
- [ ] `jku`/`x5u`/`jwk`/`x5c` を含む Request Object が**拒否**される
- [ ] 署名セグメントが非正規 base64url の JWS を `verify` が**拒否**する
- [ ] 正常な署名 Request Object・正常な JWS 署名検証は従来どおり**成功**する（回帰固定）

## 完了条件

- `pnpm --filter @maronn-openid-connect/core test` がパスすること
- `request_parameter_supported` を有効化する sample がある場合は該当 conformance テストもパスすること
