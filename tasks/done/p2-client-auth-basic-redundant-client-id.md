# [P2] `client_secret_basic` + ボディ `client_id` 同送を多重認証と誤検知して拒否する問題を修正する

## ステータス

🟠 High / 未着手

## 背景

Token Endpoint のクライアント認証で、`Authorization: Basic` により認証しつつ、リクエストボディにも
`client_id` を（`client_secret` は付けずに）送る正規のクライアントが、現状「複数の認証方式を使用した」として
`invalid_request` で拒否される。

多くの OAuth クライアントライブラリは Basic ヘッダに加えてボディにも `client_id` を無条件付与する実装で、
これらのクライアントが本 OP に対して Token 交換に失敗する。`client_id` の単独送信は RFC 6749 §3.2.1 が
明示的に許容する**識別子**であり、§2.3 が禁ずる「複数の認証方式」ではない。相互運用性（本リポジトリの
差別化軸 Fidelity/Portability）の回帰。

検討詳細は `study-material/done/client-auth-basic-with-redundant-client-id-body.md` を参照。

## 対象ファイル

- `packages/core/src/client-auth.ts`（`authenticateClient` の `hasPostCredential` 判定）
- `packages/core/src/client-auth.test.ts`
- 必要なら各 sample の `conformance.test.ts` を生成する `packages/cli` テンプレート

## 仕様参照

- RFC 6749 §2.3: "The client MUST NOT use more than one **authentication method** in each request."
  （禁止対象は認証方式の併用。`client_id` 単独は認証方式ではない）
- RFC 6749 §3.2.1: "A client MAY use the `client_id` request parameter to identify itself when
  sending requests to the token endpoint." （Basic と併送してよい識別子）
- OAuth 2.1 draft §2.3 / §3.2.1: 同旨

## 現状の実装

```ts
// packages/core/src/client-auth.ts:111-121
const hasBasicHeader = hasAuthScheme(authorizationHeader, 'Basic');
const hasPostCredential =
  params.client_id !== undefined || params.client_secret !== undefined;  // ← 過剰

if (hasBasicHeader && hasPostCredential) {
  throw new TokenError(
    TokenErrorCode.InvalidRequest,
    'Multiple client authentication methods provided. Use either Authorization header or request body, not both.',
  );
}
```

`hasPostCredential` が `client_id` **または** `client_secret` で真になるため、Basic + ボディ `client_id`
（secret なし）が多重認証と誤判定される。

## 修正方針

- [ ] 多重「認証方式」の判定を **ボディの `client_secret` の有無のみ**で行うよう `hasPostCredential` を修正する
- [ ] Basic 使用時にボディ `client_id` が併送された場合は、**Basic 側の `client_id` と一致すること**を要求し、
  不一致なら `invalid_request` を返す（食い違い検出という防御機会を残す）
- [ ] `client_secret_post`（ボディ `client_secret`）単独のパスは従来どおり動作させる（回帰させない）
- [ ] Basic + ボディ `client_secret` の同送は従来どおり多重認証方式として `invalid_request` で拒否する

実装イメージ:

```ts
const hasBasicHeader = hasAuthScheme(authorizationHeader, 'Basic');
// 多重「認証方式」は client_secret の併送でのみ判定する（client_id 単独は識別子）
const hasPostSecret = params.client_secret !== undefined;
if (hasBasicHeader && hasPostSecret) {
  throw new TokenError(TokenErrorCode.InvalidRequest, 'Multiple client authentication methods provided. ...');
}
// Basic 使用時にボディ client_id が併送されていれば一致を要求
if (hasBasicHeader && params.client_id !== undefined && params.client_id !== basic.clientId) {
  throw new TokenError(TokenErrorCode.InvalidRequest, 'client_id in body does not match the Authorization header');
}
```

## テスト要件

- [ ] Basic + ボディ `client_id`（`client_secret` なし・Basic と値一致）→ 認証**成功**し `clientId` を返す
- [ ] Basic + ボディ `client_id`（Basic と不一致）→ `invalid_request` で拒否
- [ ] Basic + ボディ `client_secret` → 従来どおり `invalid_request`（多重認証方式）
- [ ] `client_secret_post` 単独（ボディ `client_id` + `client_secret`）→ 従来どおり認証成功（回帰固定）
- [ ] `client_secret_basic` 単独（ボディに何も無し）→ 従来どおり認証成功（回帰固定）

## 完了条件

- `pnpm --filter @maronn-openid-connect/core test` がパスすること
- 上記テストがすべて追加され通過すること
- 生成 OP の Token Endpoint 挙動が変わる場合は `packages/cli` テンプレートと各 sample の
  `conformance.test.ts` を更新し、`pnpm test` がパスすること
