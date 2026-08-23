# [P0] client_secret 比較を constant-time 化する（timing attack 対策）

## ステータス

🔴 Critical / 未着手

## 背景

`authenticateClient()` 内の client_secret 照合が `!==` による通常の文字列比較であるため、timing attack に対して無防備。攻撃者が多数のリクエストを送り応答時間の差異を観測することで、secret を文字単位で漸進的に推測できる。

## 対象ファイル

- `packages/core/src/client-auth.ts`
- `packages/core/src/client-auth.test.ts`

## 仕様参照

- OAuth 2.1 §7.4.1: Security Considerations — credential comparison
- RFC 6749 §10.10: Credentials Guessing Attacks

## 現状の実装

```ts
// packages/core/src/client-auth.ts:155
if (client.clientSecret !== clientSecret) {
  throw new TokenError(TokenErrorCode.InvalidClient, 'Client authentication failed');
}
```

通常の文字列比較は先頭から一致している長さに応じて処理時間が変わる。

## 修正方針

- [ ] constant-time 比較ヘルパー関数を実装する
  - Web Crypto API (`crypto.subtle`) は timingSafeEqual を直接提供しないため、以下の方法で実現する
  - 両文字列を `TextEncoder` で `Uint8Array` に変換し、HMAC 等を使いハッシュで比較する（RFC 6749 §10.10 に準拠）
  - または固定長 HMAC 比較: `HMAC-SHA256(key, a) === HMAC-SHA256(key, b)` で文字列長を隠す
- [ ] `authenticateClient()` の比較箇所をヘルパーに差し替える
- [ ] crypto-utils.ts に `timingSafeEqual(a: string, b: string): Promise<boolean>` を追加する

```ts
// 実装例（crypto-utils.ts）
export async function timingSafeEqual(a: string, b: string): Promise<boolean> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.generateKey({ name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const [sigA, sigB] = await Promise.all([
    crypto.subtle.sign('HMAC', key, enc.encode(a)),
    crypto.subtle.sign('HMAC', key, enc.encode(b)),
  ]);
  const aBytes = new Uint8Array(sigA);
  const bBytes = new Uint8Array(sigB);
  if (aBytes.length !== bBytes.length) return false;
  let diff = 0;
  for (let i = 0; i < aBytes.length; i++) {
    diff |= aBytes[i]! ^ bBytes[i]!;
  }
  return diff === 0;
}
```

## テスト要件

- [ ] 正しい client_secret で認証が成功すること
- [ ] 誤った client_secret で `invalid_client` が返ること（既存テストの維持）
- [ ] `timingSafeEqual` が等価な文字列で true を返すこと
- [ ] `timingSafeEqual` が異なる文字列で false を返すこと

## 完了条件

`pnpm --filter @maronn-openid-connect/core test` がパスすること
