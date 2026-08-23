# [P2] 同意画面にクライアント識別情報（`client_name` / `policy_uri` / `tos_uri`）を表示できるようにする

## ステータス

🟡 Medium / 未着手

## 背景

生成 OP の同意画面は `client_id` の生文字列とスコープ名の生文字列しか表示していない。

```html
<p>Client <strong>example-client</strong> is requesting access to the following scopes:</p>
<ul><li>openid</li><li>profile</li><li>email</li></ul>
```

エンドユーザーは「誰に」「何を」許可しようとしているのかを、内部識別子から推測するしかない。

OIDC Core 1.0 §3.1.2.4 は「情報を RP へ渡す前に authorization decision を得なければならない」と
規定しており、判断できる状態での同意が前提になっている。また RFC 6749 §10.2 は、
クライアントなりすましへの防御を「クライアント認証」と「リソースオーナーの能動的な関与」の
2 本立てで語るが、後者はユーザーがクライアントを識別できて初めて機能する。

OIDC Dynamic Client Registration 1.0 §2 / RFC 7591 §2 は、この用途のために
`client_name` / `logo_uri` / `client_uri` / `policy_uri` / `tos_uri` を定義しているが、
本リポジトリの `ClientInfo` / `RegisteredClient` / `ConsentPageParams` は
**これらを 1 つも保持していない**。同意画面の GET ハンドラは `clientResolver.findClient()` すら呼んでいない。

OIDF Basic OP の Conformance テストは同意画面の内容を機械的に検証しない（手動スクリーンショット運用）。
本タスクは**認定要件ではなく、既定 UI の品質とセキュリティ**の問題として扱う。

検討詳細は `study-material/done/consent-screen-client-identification-and-scope-disclosure.md` を参照。

> 関連（重複記載しない）:
> - 同意の記録・永続化・再利用: `study-material/done/consent-grant-persistence-and-management.md`
> - 同意決定値の fail-open: `study-material/done/consent-decision-fail-open-action-value.md`
> - クライアントメタデータの強制: `study-material/done/client-metadata-enforcement.md`
> - 生成ビューの HTML エスケープ: `study-material/done/generated-login-consent-html-escaping-consistency.md`
> - スコープ検証・部分同意: `study-material/scope-handling-validation-and-granted-scope.md`
>
> 本タスクは**表示用メタデータの保持と描画**に限定する。
> `logo_uri` の既定描画（フィッシング面が開く）とスコープ説明辞書、`ui_locales` 連携は
> study-material 側で方針が分かれているため、本タスクのスコープ外とする。

## 対象ファイル

- `packages/core/src/authorization-request.ts`（`ClientInfo` に表示用フィールドを追加）
- `packages/cli/src/frameworks/hono/templates.ts`
  - `viewsTemplate()` 内の `ConsentPageParams` / `defaultConsentPage`
  - `routes/consent.ts` を生成する箇所（GET ハンドラで `findClient()` を呼ぶ）
  - `configTemplate()` 相当の既定クライアント定義
  - `conformance.test.ts` を生成する箇所（契約テストの追加）
- 再生成される生成物: `samples/*/src/oidc-provider/views.ts` / `routes/consent.ts` /
  `config.ts` / `conformance.test.ts`

## 仕様参照

- **OIDC Core 1.0 §3.1.2.4 Authorization Server Obtains End-User Consent/Authorization**:
  「Once the End-User is authenticated, the Authorization Server MUST obtain an authorization
  decision before releasing information to the Relying Party.」
- **OIDC Dynamic Client Registration 1.0 §2 Client Metadata**（すべて OPTIONAL）:
  - `client_name`: エンドユーザーに提示するクライアント名
  - `logo_uri`: エンドユーザーに提示するロゴ画像の URL
  - `client_uri`: クライアントのホームページ URL
  - `policy_uri`: クライアントがプロファイルデータをどう扱うかについてエンドユーザーが読むドキュメント
  - `tos_uri`: 利用規約
- **OIDC Dynamic Client Registration 1.0 §2.1 Human Readable Client Metadata**:
  `client_name#ja-Jpan-JP` のように BCP47 言語タグを付けられる（本タスクでは扱わない）
- **RFC 7591 §2 Client Metadata**: 同じフィールドを同じ意味で定義。
  将来 DCR を実装したときに登録リクエストの JSON をそのまま流し込めるよう、
  **フィールドの意味と名前はこの語彙に揃える**
- **RFC 6749 §10.2 Client Impersonation**:
  「The authorization server SHOULD NOT process repeated authorization requests automatically
  (without active resource owner interaction) without authenticating the client or relying on
  other measures to prevent client impersonation.」

## 現状の実装

```ts
// packages/core/src/authorization-request.ts の ClientInfo
export interface ClientInfo {
  clientId: string;
  redirectUris: string[];
  clientType?: 'confidential' | 'public';
  responseTypes?: string[];
  defaultMaxAge?: number;
  jwks?: JwkSet;
  // 表示用フィールドが 1 つも無い
}
```

```ts
// packages/cli/src/frameworks/hono/templates.ts:4121 付近（生成物 views.ts）
export interface ConsentPageParams {
  transactionId: string;
  csrfToken: string;
  scopes: string[];
  clientId: string;   // これしかクライアント情報が無い
}
```

```ts
// 生成物 routes/consent.ts の GET ハンドラ
return renderView(views.consentPage({
  transactionId,
  csrfToken: transaction.csrfToken,
  scopes: transaction.scope.split(' ').filter(Boolean),
  clientId: transaction.clientId,
}));
// clientResolver.findClient() を呼んでいない（POST 側では offlineAccessAllowed の判定で呼んでいる）
```

## 修正方針

- [ ] `ClientInfo` に OPTIONAL の表示用フィールドを追加する。
      JSDoc に OIDC Registration 1.0 §2 / RFC 7591 §2 の対応フィールド名（snake_case）を明記する

  ```ts
  export interface ClientInfo {
    // ...既存フィールド
    /** OIDC Registration 1.0 §2 `client_name`: 同意画面でエンドユーザーに提示する名称。 */
    clientName?: string;
    /** OIDC Registration 1.0 §2 `client_uri`: クライアントのホームページ URL。 */
    clientUri?: string;
    /** OIDC Registration 1.0 §2 `logo_uri`: ロゴ画像 URL。既定ビューでは描画しない（下記コメント参照）。 */
    logoUri?: string;
    /** OIDC Registration 1.0 §2 `policy_uri`: プライバシーポリシー URL。 */
    policyUri?: string;
    /** OIDC Registration 1.0 §2 `tos_uri`: 利用規約 URL。 */
    tosUri?: string;
  }
  ```

- [ ] `ConsentPageParams` に同じ値を OPTIONAL で追加する
- [ ] 生成物 `routes/consent.ts` の GET ハンドラで `clientResolver.findClient(transaction.clientId)` を呼び、
      取得した表示用メタデータをビューへ渡す。クライアントが解決できない場合は
      従来どおり `clientId` のみで描画する（フォールバック）
- [ ] 既定の `defaultConsentPage` を更新する:
  - [ ] 見出しのクライアント表記を `clientName ?? clientId` にする。
        `clientName` を出す場合は `clientId` も併記し、名称の詐称だけで識別できない状態を避ける
  - [ ] `policyUri` / `tosUri` があればリンクとして表示する
  - [ ] `clientUri` があればクライアント名にリンクを張るか、別行で表示する
  - [ ] **`logoUri` は `ConsentPageParams` として渡すが、既定ビューでは描画しない**。
        描画するとロゴ詐称によるフィッシング面が既定で開くため、
        自前ビュー（`createViews()`）で明示的に選択させる。この判断理由をコメントに残す
  - [ ] すべての補間値に既存の `escapeHtml` を適用する（現行の全値エスケープを維持）
- [ ] リンクとして描画する URI（`clientUri` / `policyUri` / `tosUri`）は、
      `javascript:` / `data:` などの危険スキームを拒否する。
      既存の redirect_uri 側の危険スキーム判定（`tasks/done/p1-redirect-uri-dangerous-scheme-rejection.md`）と
      同じ規則を再利用できるか確認し、できなければ表示用 URI 検証を追加する
- [ ] `samples/*/src/oidc-provider/config.ts` の既定クライアント（`example-client`）に
      `clientName` の例を入れ、表示が変わることをサンプルで体験できるようにする
- [ ] 生成コードを直接編集せず、必ず `packages/cli` のテンプレートを修正して再生成する

## テスト要件

- [ ] `defaultConsentPage` の単体テスト:
  - [ ] `clientName` 未指定なら `clientId` が見出しに出ること（後方互換）
  - [ ] `clientName` 指定時は `clientName` が出て、`clientId` も併記されること
  - [ ] `policyUri` / `tosUri` 指定時にリンクが出ること、未指定なら出ないこと
  - [ ] `logoUri` を渡しても既定ビューには `<img` が出ないこと
  - [ ] `clientName` に `<script>` を含む値を渡してもエスケープされること（既存エスケープの回帰）
  - [ ] `policyUri` に `javascript:alert(1)` を渡してもリンクとして描画されないこと
- [ ] 契約テスト（`conformance.test.ts` 生成コードに追加）:
  - [ ] `clientName` を登録したクライアントの同意画面に `clientName` が含まれること
  - [ ] `clientName` 未登録のクライアントでは従来どおり `clientId` が表示されること
  - [ ] 同意画面の GET がクライアント未解決時でも 500 にならないこと
- [ ] 既存の同意フロー（approve / deny）と E2E が回帰しないこと

## 完了条件

- `pnpm --filter "./packages/*" test` / `pnpm run test:conformance` / `pnpm run test:e2e` /
  `pnpm typecheck` がすべてパスすること
- 生成物を再生成し、差分がテンプレート修正に由来するものだけであること
- `logo_uri` を既定で描画しない判断の理由（フィッシング面・CSP `img-src`・
  ユーザー IP の第三者への漏洩）が、生成コードのコメントに残っていること
- `study-material/ext-dynamic-client-registration.md` に、
  本タスクで決めたフィールド名を DCR 実装時に流用する旨の相互参照が追記されていること
