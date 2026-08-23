# Authorization Response の `state` ラウンドトリップ不変条件（エラー分岐ごとの echo / 非 echo の固定）

## ステータス

🟡 Medium / 未着手

## 1. このトピックで確認したいこと

OAuth の `state` パラメータは、クライアントの CSRF 防御として認可レスポンス（成功・**エラー双方**）で
**そのまま返さ**れなければならない。一方、リダイレクト先が確定できない非リダイレクト系エラー
（client_id 不正、redirect_uri 不正、Request Object パース失敗）では `state` を**返してはならない**
（返す相手＝安全なリダイレクト先が無いため）。

本ファイルは、現状の `validateAuthorizationRequest` が **どのエラー分岐で `state` を返し／返さないか**を整理し、
この「リダイレクト可能エラー＝state echo / 非リダイレクトエラー＝state 非 echo」という不変条件が
**回帰テストで固定されているか**を確認する。

> 関連既存ファイル：
> - `tasks/done/p1-authorization-response-iss.md` は RFC 9207 の `iss` パラメータ付与を扱う（state とは別物）。
> - `tasks/done/p1-authorization-error-description-redirect.md` は redirect エラーへの `error_description` 付与を扱い、
>   `state` の echo 有無そのものは扱っていない。
> - core の `validateCsrfToken`（`auth-transaction.ts`）は **OP 内部の CSRF トークン**で、
>   クライアント向けの `state` ラウンドトリップとは別の機構。
> 本ファイルは **クライアント向け `state` の echo/非 echo 不変条件のテスト固定**という固有差分のみを扱う。

## 2. 関連する仕様・基準

- **RFC 6749 §4.1.2.1（Error Response）**:
  > if a valid `state` parameter was present in the client authorization request, [the value is returned to the client].
  - 成功・エラー双方で `state` を「リクエストにあった値のまま」返す。
- **OpenID Connect Core 1.0 §3.1.2.6（Authentication Error Response）**: 認可エラーでも `state` を返す（リクエストに在れば）。
- **OAuth 2.1（state の CSRF 役割）**: `state` はクライアントの CSRF 防御であり、改変せず返すべき。
- **非リダイレクトエラーの原則（OIDC Core §3.1.2.6 / RFC 6749 §4.1.2.1）**:
  redirect_uri が欠落／不一致、client_id 不明などで**安全なリダイレクト先が確定できない**場合は、
  クライアントへリダイレクトせず（＝ `state` も返さず）OP 上でエラー表示する。

## 3. 参照資料

- RFC 6749 §4.1.2.1（Authorization Error Response, state 返却）: https://www.rfc-editor.org/rfc/rfc6749#section-4.1.2.1
- OpenID Connect Core 1.0 §3.1.2.6: https://openid.net/specs/openid-connect-core-1_0.html#AuthError

## 4. 現在の実装確認

- `packages/core/src/authorization-request.ts`
  - `state` の解決は **Phase 1/2 の後**で行われる（`:752` 付近 `const state = effective.state;`）。
    `effective` は Request Object マージ後の実効パラメータ。
  - 非リダイレクト系エラー（`state` 引数なしで `AuthorizationError` を生成）:
    - client_id 欠落（`:669-672` 付近）
    - 未知 client_id（`:677-681` 付近）
    - clientId 不一致（`:687-692` 付近）
    - Request Object パース失敗（`:714-718` 付近）
  - これらは `state` を付けない＝**非 echo**（妥当）。ただし Request Object のパースが `:714` で throw すると、
    `state` が `:752` で捕捉される前なので、いずれにせよ `state` は確定しない。
- リダイレクト可能エラー（`invalid_scope`、`unsupported_response_type` 等）は `state` 解決後に投げられ、
  echo される設計と読める。
- **不変条件としての回帰テスト**: 「どのエラー分岐で state を返し／返さないか」を**網羅的に固定するテストは見当たらない**。
  マージ／解決順序を将来リファクタした際に、`state` の漏洩（非リダイレクト先に付与）や欠落（リダイレクトエラーで未付与）が
  黙って起こりうる。

## 5. 現在の実装との差分

- **満たしていること**
  - 現状の分岐は概ね正しい（非リダイレクト＝非 echo、リダイレクト可能＝echo）。
- **不足している可能性があること**
  - 上記不変条件を**明示的に固定する回帰テスト群が無い**。
  - `state` 解決が Phase 2 後である前提に依存しており、順序変更で不変条件が崩れるリスクが文書化されていない。
- **セキュリティ／相互運用性**
  - 仮にリダイレクト可能エラーで `state` が落ちると、クライアントの CSRF 照合が失敗し相互運用性を損なう。
  - 仮に非リダイレクトエラーで `state` を付けてしまうと、本来返すべきでない文脈で値を露出する（軽微だが原則違反）。
- **Basic OP として確認すべきこと**
  - Basic OP は `state` のラウンドトリップを重視する。エラー時の `state` echo は認定観点でも確認されうる
    （詳細は `study-material/basic-op-conformance-verification-plan.md` の手順で要確認）。

## 6. 改善・追加を検討する理由

- **回帰防止**: 認可リクエストのマージ／解決順序は本リポジトリで頻繁に触る箇所（Request Object 対応で進化中）。
  `state` 不変条件をテストで固定しておかないと、将来のリファクタで静かに壊れる。
- **Fidelity**: `state` は OAuth の CSRF 防御の要。echo/非 echo の境界を明文化することは仕様忠実性の説明に直結。
- **導入しやすさ**: 既存の `authorization-request.test.ts` に分岐網羅のケースを追加するだけ。実装変更は基本不要
  （現状が正しければテスト追加のみ。誤りが見つかれば最小修正）。
- **実装しない場合のリスク**: `state` の漏洩・欠落が将来のリファクタで混入しても検知できない。

## 7. 実装方針の候補

判断材料の整理（最終判断は人間）。

- 方針A（推奨）: **テスト先行**で、各エラー分岐の `state` echo/非 echo をマトリクスとして固定。
  - リダイレクト可能エラー（`invalid_scope` / `unsupported_response_type` / `invalid_request`（redirect 解決済み）等）→ `state` を含む。
  - 非リダイレクトエラー（client_id 欠落・不明・不一致 / redirect_uri 不正 / Request Object パース失敗）→ `state` を含まない。
  - テストで現状が正しいことを確認。崩れていれば最小修正。
- 方針B: `validateAuthorizationRequest` のドキュメント／コメントに不変条件を明記しつつ、テストで固定。

## 8. タスク案

- [ ] `authorization-request.test.ts` にエラー分岐ごとの `state` echo/非 echo マトリクステストを先行追加
- [ ] テスト結果に基づき、不変条件が崩れている分岐があれば最小修正
- [ ] `validateAuthorizationRequest` のコメントに「state は redirect 解決後に付与、非リダイレクトエラーでは付与しない」を明文化
- [ ] Basic OP conformance 観点でエラー時 `state` echo が検証されるか一次資料で確認（`basic-op-conformance-verification-plan.md` 参照）
- [ ] 完了条件: `pnpm --filter @maronn-openid-connect/core test` がパス
