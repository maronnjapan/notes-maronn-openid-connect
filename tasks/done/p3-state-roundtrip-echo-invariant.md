# [P3] Authorization Response の `state` echo/非 echo 不変条件を回帰テストで固定する

## ステータス

🟡 Medium / 未着手

## 背景

OAuth の `state` はクライアントの CSRF 防御として、認可レスポンス（成功・**エラー双方**）でそのまま返す必要がある。
一方、リダイレクト先が確定できない非リダイレクト系エラー（client_id 不正、redirect_uri 不正、Request Object パース失敗）では
`state` を返してはならない。

現状の `validateAuthorizationRequest` の各エラー分岐は概ねこの不変条件に従っているが、
**「どの分岐で state を返し／返さないか」を網羅的に固定する回帰テストが存在しない**。
認可リクエストのマージ／解決順序は Request Object 対応などで頻繁に触る箇所であり、
順序変更で `state` の漏洩（非リダイレクト先に付与）や欠落（リダイレクトエラーで未付与）が静かに混入するリスクがある。

検討の詳細は `study-material/done/state-roundtrip-echo-invariant.md` を参照。

## 対象ファイル

- `packages/core/src/authorization-request.ts`（`state` 解決 L752 付近、非リダイレクトエラー分岐 L669-718 付近）
- `packages/core/src/authorization-request.test.ts`

## 仕様参照

- RFC 6749 §4.1.2.1（Authorization Error Response）— 「リクエストに有効な `state` があれば、その値をクライアントに返す」。
  https://www.rfc-editor.org/rfc/rfc6749#section-4.1.2.1
- OpenID Connect Core 1.0 §3.1.2.6（Authentication Error Response）— エラーでも `state` を返す（リクエストに在れば）。
  https://openid.net/specs/openid-connect-core-1_0.html#AuthError
- 非リダイレクト原則: redirect_uri 不正／client_id 不明など安全なリダイレクト先が確定できない場合は
  クライアントへリダイレクトせず（= `state` も返さず）OP 上でエラー表示する。

## 現状の実装

- `state` は Phase 1/2（client/redirect_uri/Request Object 解決）の後で `effective.state` から解決される（`:752` 付近）。
- 非リダイレクト系エラーは `state` 引数なしで `AuthorizationError` を生成（`:669-672` client_id 欠落、`:677-681` 未知 client_id、
  `:687-692` clientId 不一致、`:714-718` Request Object パース失敗）→ 非 echo（妥当）。
- リダイレクト可能エラー（`invalid_scope` / `unsupported_response_type` 等）は `state` 解決後に投げられ echo される設計。
- ただし上記を**網羅的に固定するテストが無い**。

## 修正方針

- [ ] **テスト先行**で、各エラー分岐の `state` echo/非 echo をマトリクスとして固定する。
  - リダイレクト可能エラー（redirect 解決済みの `invalid_scope` / `unsupported_response_type` / `invalid_request` 等）→ `state` を**含む**。
  - 非リダイレクトエラー（client_id 欠落・不明・不一致 / redirect_uri 不正 / Request Object パース失敗）→ `state` を**含まない**。
- [ ] テストで現状の正しさを確認し、崩れている分岐があれば最小修正する。
- [ ] `validateAuthorizationRequest` のコメントに「`state` は redirect 解決後に付与し、非リダイレクトエラーでは付与しない」を明文化する。

## テスト要件

- [ ] `state=xyz` 付きリクエストで `invalid_scope` が起きたとき、エラーに `state=xyz` が**含まれる**こと（具体値で固定）。
- [ ] `state=xyz` 付きリクエストで `unsupported_response_type` が起きたとき、`state=xyz` が**含まれる**こと。
- [ ] client_id 欠落／未知／不一致・redirect_uri 不正・Request Object パース失敗の各分岐で、
      エラーに `state` が**含まれない**こと（非リダイレクト）。
- [ ] `state` 不在リクエストでは、リダイレクト可能エラーでも `state` が付かないこと。

## 完了条件

- `pnpm --filter @maronn-openid-connect/core test` がパスすること
- 上記マトリクスが回帰テストとして固定されること
