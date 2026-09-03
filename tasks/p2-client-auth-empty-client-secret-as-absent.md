# [P2] 空文字列の `client_secret` を「未提示」として扱う（RFC 6749 §3.2）

## ステータス

🟡 Medium / 未着手

## 背景

`extractClientCredentials` は `params.client_secret !== undefined` で資格情報の提示有無を
判定するため、値の無いフォームフィールド（`client_secret=`）を
「client_secret_post の資格情報あり」と数える。

これにより次の 2 つの誤挙動が起きる。

1. `token_endpoint_auth_method: none` の public client が `client_id=x&client_secret=` を送ると、
   method が `client_secret_post` と判定され、登録方式不一致の invalid_client で拒否される。
2. `Authorization: Basic` と空の `client_secret` フィールドが併存すると、
   「複数認証方式」の invalid_request で拒否される。

RFC 6749 §3.2 は「Parameters sent without a value MUST be treated as if they were
omitted from the request」と定めており、空値の `client_secret` は省略として扱うべきである。
同じファイルの `validateClientAuthMethod` / `verifyClientSecret` は falsy 判定
（空 secret = 未提示）で実装・テスト済みであり、抽出側だけ意味論が割れている。

詳細は `study-material/done/client-auth-empty-string-client-secret-presence.md` を参照。

## 対象ファイル

- `packages/core/src/client-auth.ts`（`extractClientCredentials`）
- `packages/core/src/client-auth-steps.test.ts`（テスト追加）

## 仕様参照

- RFC 6749 §3.2: 値なしで送られたパラメータは省略として扱う（MUST）
- RFC 6749 §2.3: 1 リクエストで複数の認証方式を使ってはならない
  （空値は資格情報を運ばないため「もう一つの方式」に当たらない）
- RFC 6749 §2.3.1: client_secret_post はシークレットをボディに含める方式

## 現状の実装

```typescript
// packages/core/src/client-auth.ts（extractClientCredentials）
const hasPostSecret = params.client_secret !== undefined;   // '' も「提示あり」
if (hasBasicHeader && hasPostSecret) {
  throw new TokenError(TokenErrorCode.InvalidRequest, 'Multiple client authentication methods provided. ...');
}
// ...
const method = hasBasicHeader
  ? 'client_secret_basic'
  : clientSecret !== undefined                              // '' → 'client_secret_post'
    ? 'client_secret_post'
    : 'none';
```

## 修正方針

- [ ] `extractClientCredentials` の冒頭で、空文字列の `client_secret` を undefined に正規化する
      （RFC 6749 §3.2 の「値なしは省略」をこの一箇所で実装し、
      多重方式判定・method 判定・後段検証の意味論を揃える）
- [ ] 正規化の根拠（§3.2）をコメントで明記する
- [ ] `client_id` の空文字列は現状も `!clientId` で「認証必須」に落ちるため挙動を変えない
- [ ] Basic ヘッダ内の空 secret（`base64(client:)`) の扱いは変えない
      （`verifyClientSecret` が従来どおり拒否する）

## テスト要件

- [ ] `should treat an empty client_secret field as absent for a public client`
      （`client_id=x&client_secret=`、登録 none → method 'none' で通過する）
- [ ] `should not reject Basic authentication combined with an empty client_secret field`
      （Basic + `client_secret=` → invalid_request にならず Basic として抽出される）
- [ ] `should still require authentication when a confidential client sends an empty client_secret`
      （登録 client_secret_basic / client_secret_post のクライアント → invalid_client。
      拒否理由が「方式不一致」ではなく「認証必須」になることを固定）
- [ ] 既存の多重方式拒否（Basic + 非空の `client_secret`）が従来どおり invalid_request であること

## 完了条件

```bash
pnpm --filter @maronn-openid-connect/core test
```

- 上記が成功し、追加テストがすべて緑であること
- 生成 OP の挙動が変わるため、`samples/*/conformance.test.ts` への契約テスト追加を検討する
  （追加する場合は `packages/cli` の生成元を変更する）
