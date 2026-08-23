# Token Endpoint の `WWW-Authenticate` チャレンジを、クライアントが実際に使った認証方式/文脈に合わせる

## 1. このトピックで確認したいこと

`invalid_client`（401）応答時、`TokenError.wwwAuthenticate` は**常に** `Basic realm="Client Authentication"` を返す。RFC 6749 §5.2 は「クライアントが Authorization リクエストヘッダで認証を試みた場合に」`WWW-Authenticate` を返し、そのチャレンジは「クライアントが使った認証スキームに一致させる」ことを求めている。`client_secret_post`（ボディ認証）での失敗や、そもそも認証情報を送っていないケースにまで `Basic` チャレンジを返すのは過剰・不正確ではないか、を確認したい。

このトピックは「`WWW-Authenticate: Basic` を**返すこと自体**が正しい」という既存トピック（`study-material/error-response-cross-endpoint.md` / `study-material/security-client-secret-handling.md`）とは別の、**チャレンジをクライアントの認証文脈に合わせる**という差分に限定する。

## 2. 関連する仕様・基準

共通の「Token Endpoint エラー応答形式・`invalid_client` の 401・Cache-Control」の説明は `study-material/error-response-cross-endpoint.md` を参照し繰り返さない。

- **RFC 6749 §5.2 (`invalid_client`)**:
  > "If the client attempted to authenticate via the `Authorization` request header field, the authorization server MUST respond with an HTTP 401 (Unauthorized) status code and include the `WWW-Authenticate` response header field matching the authentication scheme used by the client."

  ポイントは 2 つ:
  1. `WWW-Authenticate` を返す**条件**は「クライアントが Authorization ヘッダで認証を試みたこと」。
  2. チャレンジのスキームは「クライアントが使ったスキームに一致」させる。
- **OAuth 2.1 §5.2 / §3.2.3**: RFC 6749 §5.2 を踏襲。`client_secret_basic` 失敗時は `Basic` チャレンジが妥当だが、`client_secret_post` 失敗や無認証（public client の識別失敗など）では `Basic` チャレンジは文脈に一致しない。
- **RFC 6750 §3**: `WWW-Authenticate` はチャレンジの意味を持つヘッダであり、無関係なスキームを提示するとクライアントの再試行を誤誘導し得る。

## 3. 参照資料

- RFC 6749 §5.2 Error Response — https://datatracker.ietf.org/doc/html/rfc6749#section-5.2
- OAuth 2.1 draft §5.2 / §3.2.3 — https://datatracker.ietf.org/doc/draft-ietf-oauth-v2-1/
- 既存の関連記述（現状挙動を「正」として記録）: `study-material/error-response-cross-endpoint.md`、`study-material/security-client-secret-handling.md`

## 4. 現在の実装確認

`packages/core/src/token-request.ts`:

```ts
get wwwAuthenticate(): string | undefined {
  if (this.error === TokenErrorCode.InvalidClient) {          // L47-52
    return 'Basic realm="Client Authentication"';             // 常に Basic
  }
  return undefined;
}
```

`invalid_client` が投げられる文脈（`packages/core/src/client-auth.ts:136-201`）:
- `client_secret_post` の認証失敗（ボディの `client_secret` 不一致）でも `invalid_client`。
- 認証情報未提示（`client_id` すら無い等）でも `invalid_client`（`:143-148`）。
- public client（`auth_method: none`）に credentials を付けた場合の不一致でも `invalid_client`。

いずれも最終的に `TokenError.wwwAuthenticate` を経て `Basic` チャレンジが付与される（`invalid_client` 以外のエラーでは `undefined` で正しく付かない点は既に妥当）。

## 5. 現在の実装との差分

満たしていること:
- `invalid_client` は 401、それ以外は 400 という区別、および `invalid_client` 以外で `WWW-Authenticate` を付けないことは妥当（`study-material/error-response-cross-endpoint.md` で担保）。
- `client_secret_basic` を使った失敗に対する `Basic` チャレンジは RFC 6749 §5.2 に一致。

改善した方がよいこと（相互運用性）:
- 🟡 **`client_secret_post` 失敗・無認証ケースにも `Basic` チャレンジ**を返している。RFC 6749 §5.2 の「使ったスキームに一致」「Authorization ヘッダで試みた場合に返す」という条件から見ると過剰・不正確。
- クライアントによっては `WWW-Authenticate: Basic` を受けて Basic 認証で再試行するよう誘導され得る（登録方式が `client_secret_post` なら本来は不一致）。

Basic OP として確認すべきこと:
- Basic OP 認定テスト（OP-ClientAuth-Basic/SecretPost-Static）は認証成功と失敗時のエラーコード（`invalid_client`）を主眼とし、`WWW-Authenticate` のスキーム一致まで厳密に検査するかは要確認。**認定可否に直結する可能性は低い**が、RFC 準拠の精度としては差分。

## 6. 改善・追加を検討する理由

- **なぜ検討するか**: RFC 6749 §5.2 の文言に対する忠実度（Fidelity）の微差。本リポジトリは Fidelity を差別化軸に掲げているため、こうした細部の一致は主張の裏付けになる。
- **Basic OP 必須か拡張か**: どちらでもない微修正（RFC 準拠のハードニング）。認定要件ではない。
- **判断が割れる点**: 現状の「常に `Basic`」は「Token Endpoint の既定認証方式は `client_secret_basic`（OIDC Core §9 / RFC 7591 §2 の既定）だから、迷ったら Basic を提示するのは合理的」という擁護も成り立つ。したがって「変えるべき欠陥」なのか「許容される簡略化」なのかは人間の判断が必要。**本ファイルはタスク化せず検討材料として残す**。
- **実装しない場合のリスク**: 実害は小さい。RFC 文言との微差が残るのみ。

## 7. 実装方針の候補（判断材料）

最終判断は人間が行う。ここでは選択肢の整理に留める。

- 方針A（スキーム一致 + 条件限定）: `TokenError` に「クライアントが使った認証方式（basic/post/none/無し）」の文脈を渡し、`wwwAuthenticate` を次のように分岐する。
  - `client_secret_basic` を使って失敗 → `Basic realm="..."`
  - `client_secret_post` を使って失敗 → `WWW-Authenticate` を付けない（Authorization ヘッダを使っていないため §5.2 の付与条件外）か、あるいはチャレンジ無しの 401
  - 無認証 → §5.2 の付与条件外として付けない
  実装は `client-auth.ts` から `TokenError` へ文脈を伝える必要があり、やや配線が増える。
- 方針B（現状維持 + 文書化）: 「既定認証方式が `client_secret_basic` のため `invalid_client` には常に `Basic` チャレンジを返す」という判断を `error-response-cross-endpoint.md` に明記して割り切る。実装コスト 0。
- 方針C（Basic は basic 失敗時のみ、他は付けない）: 方針 A の簡略版。`hasBasicHeader` だった失敗のみ `Basic` を返し、それ以外は `WWW-Authenticate` を付けない。文脈オブジェクトを増やさず `client-auth.ts` の分岐で throw する `TokenError` を出し分ける。

## 8. タスク案（タスク化は保留）

現時点では「欠陥か許容される簡略化か」の判断が定まっていないため、タスク化しない。判断のための調査項目のみ挙げる。

- [ ] OIDF Conformance Suite の Basic OP テストが `WWW-Authenticate` のスキーム一致まで検査するか確認する（`tasks/basic-op-conformance-verification-plan.md` の実行時に併せて）
- [ ] 主要 IdP（Google / Auth0 等）が `client_secret_post` 失敗時に `WWW-Authenticate` をどう返すか実挙動を調査する
- [ ] 上記を踏まえ、方針 A / B / C を人間が選定する
- [ ] （方針 A/C 採用時）`TokenError` へ認証文脈を渡す最小配線を設計し、`client-auth.test.ts` / `token-request.test.ts` にスキーム別チャレンジのテストを追加してから実装する

## 関連トピック

- `study-material/error-response-cross-endpoint.md` — Token/UserInfo/Introspection/Revocation の横断エラー形式。`WWW-Authenticate` を「返すこと自体」の妥当性はそちらで担保済み。本ファイルは「スキーム/文脈への一致」という差分のみを扱う。
