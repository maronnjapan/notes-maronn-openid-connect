# UserInfo：`insufficient_scope` の `WWW-Authenticate` チャレンジに `scope` 属性が無い（RFC 6750 §3.1）

## ステータス

🟢 Low / 未着手（相互運用性の拡張・Basic OP 必須ではない）

## 1. このトピックで確認したいこと

UserInfo エンドポイント（および Bearer トークンで保護された全リソース）で、
アクセストークンのスコープ不足により `insufficient_scope`（HTTP 403）を返すとき、
`WWW-Authenticate: Bearer` チャレンジに **RFC 6750 §3.1 が推奨する `scope` 属性**が
含まれていないことを確認する。

- OP は「不足しているスコープ（この実装では `openid`）」を正確に把握しているのに、
  それを標準の機械可読な場所（`WWW-Authenticate` の `scope`）で伝えていない。
- 準拠 RP はチャレンジを読んで「どのスコープを追加要求すべきか」を判断できるが、
  現状は `scope` が無いため再要求のヒントを得られない。

> 本トピックは `insufficient_scope` チャレンジの `scope` 属性に限定する。以下とは差分が異なるため重複しない:
> - `realm` 属性の付与（全チャレンジ共通）: `tasks/done/p3-www-authenticate-realm.md`
> - 認証情報欠落時の bare `Bearer` チャレンジ（error なし）: `tasks/done/p3-www-authenticate-realm.md`
> - `error` / `error_description` の基本形: `study-material/userinfo-endpoint-comprehensive.md`
> - UserInfo の access token audience 検証: `study-material/done/userinfo-access-token-audience-validation.md`

## 2. 関連する仕様・基準（このトピック固有の差分）

### 2.1 RFC 6750 §3 / §3.1 WWW-Authenticate Response Header Field

`WWW-Authenticate` チャレンジで使えるパラメータとして `scope` が定義される。

> **scope** — The `scope` attribute is a space-delimited list of case-sensitive scope values
> indicating the required scope of the access token for accessing the requested resource.
> ... a resource server SHOULD include the `scope` attribute (when the `insufficient_scope`
> error code is used).

つまり `insufficient_scope` を返す場合、リソースサーバは**必要なスコープを `scope` 属性で示す
（SHOULD）**。これによりクライアントは何を再要求すべきかを機械的に知れる。

### 2.2 位置づけ（OPTIONAL / SHOULD）

- `scope` 属性は RFC 6750 上 OPTIONAL パラメータだが、`insufficient_scope` に限っては
  「含めるべき（SHOULD）」と明記される。Basic OP 認証の MUST ではない。
- OIDC Core §5.3.3 は UserInfo のエラー返却を RFC 6750 に委ねているため、この推奨がそのまま適用される。

## 3. 参照資料

- RFC 6750 §3 The WWW-Authenticate Response Header Field — https://www.rfc-editor.org/rfc/rfc6750#section-3
- RFC 6750 §3.1 Error Codes（`insufficient_scope`）— https://www.rfc-editor.org/rfc/rfc6750#section-3.1
  （`scope` 属性を SHOULD で含める根拠）
- OpenID Connect Core 1.0 §5.3.3 UserInfo Error Response — https://openid.net/specs/openid-connect-core-1_0.html#UserInfoError

## 4. 現在の実装確認

### 4.1 core：不足スコープの検出

`packages/core/src/userinfo.ts`（387-393 行付近）:

```ts
// --- 2. openidスコープの確認 ---
if (!tokenInfo.scope.includes('openid')) {
  throw new UserInfoError(
    UserInfoErrorCode.InsufficientScope,
    'The openid scope is required'
  );
}
```

- `UserInfoError` は `error` / `errorDescription` / `statusCode`（403）は持つが、
  **「必要なスコープ」を保持するフィールドが無い**。

### 4.2 生成コード：チャレンジ組み立て

`packages/cli/src/frameworks/hono/templates.ts`（1852-1857 行付近。他フレームワークのテンプレートも同様）:

```ts
if (error instanceof UserInfoError) {
  const status = error.statusCode as 401 | 403;
  c.header(
    'WWW-Authenticate',
    `Bearer error="${error.error}", error_description="${error.errorDescription}"`,
  );
  return c.json({ error: error.error, error_description: error.errorDescription }, status);
}
```

- チャレンジは `error` / `error_description` のみで組み立てられ、`scope` 属性は付かない。
- `insufficient_scope`（403）でも `Bearer error="insufficient_scope", error_description="..."` となり、
  `scope="openid"` が出力されない。

## 5. 現在の実装との差分

満たしていること:

- ✅ `insufficient_scope` の 403 ステータスと `error` / `error_description` の返却。
- ✅ `invalid_token` の 401、audience 不一致の拒否など主要な RFC 6750 挙動。

不足・確認が必要なこと:

- 🟢 **`scope` 属性の欠落**: `insufficient_scope` チャレンジに RFC 6750 §3.1 が SHOULD とする
  `scope` 属性（この実装では `scope="openid"`）が無い。RP が再要求すべきスコープを機械的に取得できない。
- 🟡 **core にスコープ情報を運ぶ経路が無い**: `UserInfoError` が必要スコープを保持していないため、
  生成コード側でチャレンジに埋め込むには型/フィールド追加が要る。

## 6. 改善・追加を検討する理由

- **Fidelity / 相互運用性**: OP は不足スコープ（`openid`）を確実に知っているのに、標準の機械可読な
  場所で伝えていない。RFC 6750 §3.1 の SHOULD を満たすことで、準拠 RP が自動でスコープ再要求できる。
- **将来拡張への布石**: 現状 `insufficient_scope` の原因は `openid` 欠如のみだが、将来スコープベースの
  クレーム制御や step-up（`study-material/ext-step-up-authentication-rfc9470.md`）を入れる際、
  「必要スコープをチャレンジで返す」機構が土台になる。
- **導入しやすさ**: `UserInfoError` に `requiredScope?`（string[]）を持たせ、生成テンプレートの
  チャレンジ組み立てで存在時に `scope="..."` を追記するだけ。局所的。
- **実装しない場合のリスク**: 大きな実害はないが、RFC 6750 の推奨を満たさず Fidelity シグナルが一段弱い。

## 7. 実装方針の候補（最終判断は人間）

- **方針A（`UserInfoError` に必要スコープを持たせる）**: `UserInfoError` に `requiredScope?: string[]` を
  追加し、`insufficient_scope` を投げる箇所で `['openid']` を設定。生成テンプレートの `WWW-Authenticate`
  組み立てで、`insufficient_scope` かつ `requiredScope` があるとき `scope="openid"` を付す。
- **方針B（生成テンプレート側の定数）**: core は変えず、生成コードのチャレンジ組み立てで
  `error === 'insufficient_scope'` のとき固定で `scope="openid"` を付す。実装は最小だが、
  UserInfo が `openid` 以外のスコープを要求するように将来拡張したとき破綻する（拡張性が低い）。
- **方針C（現状維持）**: RFC 6750 上 OPTIONAL/SHOULD であることを理由に対応しない。Fidelity 差分は残置。

判断材料:

- 方針 A が拡張性・忠実性ともに優れる。core の `UserInfoError` へ 1 フィールド追加する影響範囲は小さい。
- チャレンジ文字列に値を埋め込むため、`scope` 値は既存の `sanitizeErrorDescription` と同様に
  制御文字・引用符が混入しない安全な文字集合であることを保証する（`openid` は問題ないが、将来値のため一般化時に注意）。
- 生成コードは直接編集せず、必ず `packages/cli` のテンプレートを修正し、各 sample の
  `conformance.test.ts`（`WWW-Authenticate` に `scope="openid"` を含む検証）を生成側で更新する。

## 8. タスク案

- [ ] 方針（A `UserInfoError` 拡張 / B テンプレート定数 / C 見送り）を決定する（推奨: A）
- [ ] （方針A・TDD）`userinfo.test.ts` に「`insufficient_scope` の `UserInfoError` が `requiredScope=['openid']` を持つ」テストを追加
- [ ] `UserInfoError` に `requiredScope?: string[]` を追加し、`insufficient_scope` 送出箇所で設定
- [ ] `packages/cli` の各フレームワークテンプレート（web-standard / hono / express / fastify / nextjs）の
  `WWW-Authenticate` 組み立てを、`insufficient_scope` 時に `scope="openid"` を追記するよう修正
- [ ] 各 sample の `conformance.test.ts` 生成コードに「`insufficient_scope` チャレンジが `scope="openid"` を含む」検証を追加（生成コードは直接編集しない）
