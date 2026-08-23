# [P2] id_token_hint 検証時に JWS Header の `jku` / `x5u` / `jwk` / `x5c` を明示拒否する

## ステータス

🟡 Medium / 未着手

## 背景

`packages/core/src/id-token.ts` の `validateIdTokenHint` は、受信した JWS Compact の Header から `alg` と `kid` だけを読み、それ以外の Header フィールドは**サイレントに無視**している。現在の実装は登録済み JWKS の `kid`/`alg` でしか鍵を選ばないので即時の悪用経路はないが、RFC 8725 §3.1 / OpenID Connect Core §16.18 が推奨する「他オリジンから鍵を取得しうるヘッダパラメータは受信側で明示拒否する」という防御線が引かれていない。

将来このコードが拡張されて Header から鍵情報を解釈するようになった場合、`jku` / `x5u` / `jwk` / `x5c` を経由した SSRF・任意公開鍵差し替え・Cross-JWT confusion を踏みやすくなる。OSS として配布する以上、現時点で「これらは受け取ったら即拒否する」ことを契約として固定したい。

関連: `study-material/jwt-bcp-rfc8725.md`（本タスクの根拠ファイル）、`study-material/jws-algorithm-policy-and-alg-none-defense.md`（alg=none 対策の既存検討）。

## 対象ファイル

- `packages/core/src/id-token.ts`（`validateIdTokenHint`）
- `packages/core/src/id-token.test.ts`

## 仕様参照

- RFC 8725 §3.1 Perform Algorithm Verification
  https://datatracker.ietf.org/doc/html/rfc8725#section-3.1
- RFC 7515 §4.1.2（`jku`） / §4.1.3（`jwk`） / §4.1.5（`x5u`） / §4.1.6（`x5c`）
  https://datatracker.ietf.org/doc/html/rfc7515
- OpenID Connect Core 1.0 §16.18 Need for Signed Requests
  https://openid.net/specs/openid-connect-core-1_0.html#TokenSecurity

各 RFC 7515 のヘッダは「鍵を取得するための情報源」として用意されているが、OP の `id_token_hint` 受信時に外部 URL から鍵を取得することは仕様上想定されていない。本リポジトリは事前登録済み JWKS のみを使うため、これらヘッダの存在自体を明示的なバリデーションエラーにする。

## 現状の実装

```ts
// packages/core/src/id-token.ts:227-231
const headerAlg = typeof header['alg'] === 'string' ? (header['alg'] as string) : undefined;
if (!headerAlg || headerAlg === 'none') {
  throw new IdTokenHintError('id_token_hint alg is missing or "none"');
}
const headerKid = typeof header['kid'] === 'string' ? (header['kid'] as string) : undefined;
```

- `header['jku']` / `header['x5u']` / `header['jwk']` / `header['x5c']` が存在しても素通りする
- 現在のフローでは無視されるだけだが、将来この `header` オブジェクトを他コードが参照する可能性があり、防御線がない

## 修正方針

- [ ] `validateIdTokenHint` 内で `alg` 検査の直後に「危険なヘッダフィールドが含まれていないか」を確認するガードを追加する
- [ ] 拒否対象は `jku` / `x5u` / `jwk` / `x5c`（RFC 7515 §4.1.2 / 4.1.3 / 4.1.5 / 4.1.6）
- [ ] 拒否時は `IdTokenHintError` を投げ、メッセージで具体的なフィールド名を示す
- [ ] 将来 `logout_token` / `request` Object など他の JWS 受信処理を追加する際にも再利用できるよう、`assertNoExternalKeyHeaders(header)` のような小さなヘルパとして括り出すことを検討

実装例:

```ts
const FORBIDDEN_KEY_HEADERS = ['jku', 'x5u', 'jwk', 'x5c'] as const;

function assertNoExternalKeyHeaders(header: Record<string, unknown>): void {
  for (const field of FORBIDDEN_KEY_HEADERS) {
    if (field in header) {
      throw new IdTokenHintError(
        `id_token_hint JOSE header contains unsupported field: ${field}`,
      );
    }
  }
}
```

`validateIdTokenHint` の `alg` 検査直後に呼ぶ。

## テスト要件

- [ ] Header に `jku` を含む id_token_hint が `IdTokenHintError` で拒否される
- [ ] Header に `x5u` を含む id_token_hint が `IdTokenHintError` で拒否される
- [ ] Header に `jwk` を含む id_token_hint が `IdTokenHintError` で拒否される（攻撃者が鍵を埋め込むケース）
- [ ] Header に `x5c` を含む id_token_hint が `IdTokenHintError` で拒否される
- [ ] `alg` と `kid` だけを持つ正常な id_token_hint は従来どおり成功する（リグレッションなし）
- [ ] エラーメッセージに該当ヘッダ名が含まれる（デバッグ容易性）

## 完了条件

- 上記テストがすべて通る
- `pnpm --filter @maronn-openid-connect/core test` がパスする
- `validateIdTokenHint` の既存テストが引き続きパスする（リグレッションなし）
