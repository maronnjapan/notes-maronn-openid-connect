# 空文字列の `client_secret` を「資格情報あり」と判定している問題

## ステータス

🟡 Medium / タスク化済み（`tasks/p2-client-auth-empty-client-secret-as-absent.md`）

## 1. このトピックで確認したいこと

Token Endpoint のクライアント認証で、値の無いパラメータ（`client_secret=`）を
「client_secret_post の資格情報が提示された」と扱ってよいかを確認する。

`extractClientCredentials` は `client_secret !== undefined` で提示有無を判定するため、
空文字列を資格情報として数える。
一方、同じファイルの `validateClientAuthMethod` と `verifyClientSecret` は
falsy 判定（`!presented.clientSecret`）で「空の secret は未提示」と扱っており、
提示有無の意味論がモジュール内で割れている。

## 2. 関連する仕様・基準

- RFC 6749 §3.2（Token Endpoint）
  - 「Parameters sent without a value MUST be treated as if they were omitted from the request.」
  - 値なしで送られたパラメータは、リクエストに含まれなかったものとして扱わなければならない。
- RFC 6749 §2.3
  - 「The client MUST NOT use more than one authentication method in each request.」
  - 空の `client_secret` は資格情報を運ばないため、「もう一つの認証方式」には当たらない。
- RFC 6749 §2.3.1
  - client_secret_post は「リクエストボディにクライアントシークレットを含める」方式であり、
    空値はシークレットを含めたことにならない。

## 3. 参照資料

- RFC 6749 §2.3 / §2.3.1 / §3.2
- `study-material/done/client-auth-basic-with-redundant-client-id-body.md`
  （Basic + ボディ `client_id` の冗長送信。本トピックは `client_secret` の空値が対象で別論点）

## 4. 現在の実装確認

`packages/core/src/client-auth.ts` の `extractClientCredentials`:

```typescript
const hasPostSecret = params.client_secret !== undefined;   // '' も「提示あり」
if (hasBasicHeader && hasPostSecret) {
  throw new TokenError(
    TokenErrorCode.InvalidRequest,
    'Multiple client authentication methods provided. ...',
  );
}
// ...
const method: PresentedClientCredentials['method'] = hasBasicHeader
  ? 'client_secret_basic'
  : clientSecret !== undefined                              // '' → 'client_secret_post'
    ? 'client_secret_post'
    : 'none';
```

対して後段は falsy 判定で統一されている:

```typescript
// validateClientAuthMethod
if (!presented.clientSecret) {
  throw new TokenError(TokenErrorCode.InvalidClient, 'Client authentication required');
}
```

`client-auth-steps.test.ts` の
`should reject a confidential client that presents an empty secret` が
後段の falsy 意味論（空 secret = 未提示）をテストで固定済みである。

## 5. 現在の実装との差分

- 発生する誤挙動 1（public client）
  - `token_endpoint_auth_method: none` で登録した public client が
    `client_id=x&client_secret=` を送ると、method が `client_secret_post` と判定され、
    `validateClientAuthMethod` が「登録方式と不一致」の invalid_client で拒否する。
    資格情報を何も提示していないクライアントが、方式不一致として弾かれる。
- 発生する誤挙動 2（Basic 併用）
  - `Authorization: Basic` を使うクライアントの HTTP スタックがボディに空の
    `client_secret` フィールドを残すと、「複数認証方式」の invalid_request で拒否される。
    実際に使われた認証方式は一つである。
- いずれも RFC 6749 §3.2 の「値なしは省略として扱う」に反する。
- エラーメッセージが方式不一致・多重方式を指すため、原因（余分な空フィールド）へ
  たどり着きにくく、設定ミスの調査コストが上がる。

## 6. 改善・追加を検討する理由

設定オブジェクト全体をフォームボディへ直列化するクライアント実装では、
未設定のシークレットが空文字列フィールドとして送出されることがある。
この形のリクエストを出すクライアントは、現状この OP からトークンを一切取得できない。

修正はセキュリティを弱めない。
空 secret を「未提示」に正規化しても、confidential client は
`validateClientAuthMethod` の `!presented.clientSecret` で従来どおり invalid_client になる。
変わるのはエラーの種類（方式不一致 → 認証必須）と、public client が正しく通ることだけである。

## 7. 実装方針の候補

1. **抽出時に正規化する（推奨）**
   `extractClientCredentials` の冒頭で、空文字列の `client_secret` を undefined として扱う
   （RFC 6749 §3.2 の「値なしは省略」をこの一箇所で実装する）。
   多重方式判定・method 判定・後段の検証すべてが同じ意味論に揃う。
2. **判定箇所ごとに falsy 判定へ揃える**
   `hasPostSecret` と method 判定を `!== undefined` から truthy 判定に変える。
   結果は 1 と同じだが、意味論の宣言（値なし = 省略）が実装に現れにくい。

`client_id=`（空文字列）は現状も `!clientId` で「認証必須」に落ちるため対象外とする。

## 8. タスク案

方針 1 で `tasks/p2-client-auth-empty-client-secret-as-absent.md` としてタスク化済み。
