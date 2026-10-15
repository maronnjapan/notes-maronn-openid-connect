# [P2] DCR の `scope` メタデータを検証して登録し、動的登録クライアントへクライアント単位のスコープ制限を掛ける

## ステータス

✅ Implemented / 実装済み（PR #133 レビュー待ち）

## 背景

Dynamic Client Registration（RFC 7591、PR #131）は、クライアントメタデータ `scope` を未知フィールドと同じ扱いで黙って捨てる。
core にはクライアント単位のスコープ制限（`ClientInfo.scope`。一覧外の要求は `validateClientScope` が `invalid_scope` で拒否）がすでにあるが、動的登録クライアントは `scope` を持たずに保存されるため常に無制限になり、`--scope` で宣言したカスタムスコープも要求できる。
登録者が `scope` で制限を明示しても応答から結果を観測できない。

`scope` を検証して登録レコードへ積み、201 応答へ反映することで、動的登録クライアントにも最小権限を適用できるようにする（方針の比較は `study-material/done/dcr-scope-metadata-registration-and-least-privilege.md` を参照。本タスクは方針A（一覧外は拒否）を前提とする）。

## 対象ファイル

- `packages/experimental/src/dynamic-client-registration/registration-request.ts`（`validateClientRegistrationRequest` と `ValidatedClientRegistration`）
- `packages/experimental/src/dynamic-client-registration/registration-request.test.ts`
- `packages/experimental/src/dynamic-client-registration/registered-client.ts`（`DynamicallyRegisteredClient` / `buildRegisteredClient` / `buildClientRegistrationResponse`）
- `packages/experimental/src/dynamic-client-registration/registered-client.test.ts`
- `packages/cli/src/frameworks/hono/templates.ts`（`registerRouteTemplate`。web-standard 経由で express / fastify にも適用される）
- `packages/cli/src/frameworks/nextjs/endpoints.ts`（`nextJsRegisterRouteTemplate`）
- `tests/e2e/specs/dynamic-client-registration.spec.ts`
- `samples/*/src/oidc-provider`（CLI 再生成で追随。直接編集しない）
- notes リポジトリ `implementation-guides/experimental/dynamic-client-registration.md` / `.en.md`（掲載コードと説明を同じ変更内で更新する）

## 仕様参照

- **RFC 7591 §2 `scope`**：アクセストークン要求時に使ってよい scope 値のスペース区切り文字列（OPTIONAL）。省略時は既定セットでの登録を MAY で許す
- **RFC 7591 §3.2.1**：応答は登録済みの全メタデータを返す MUST。サーバーが置換・付与した値も含む
- **RFC 7591 §3.2.2**：メタデータ値が不正なときは `invalid_client_metadata` を 400 で返す
- **RFC 6749 §3.3**：scope の構文（`scope = scope-token *( SP scope-token )`、`scope-token = 1*( %x21 / %x23-5B / %x5D-7E )`）
- 既存実装の整合先：`ClientInfo.scope`（`packages/core/src/authorization-request.ts`）と `validateClientScope`

## 現状の実装

- `validateClientRegistrationRequest` は 5 フィールドの allowlist-pick（`registration-request.ts` 108-116 行）で、`scope` は選び取る対象に無い
- `DynamicallyRegisteredClient` に scope フィールドが無く、201 応答にも `scope` が載らない
- 生成される登録ルート（hono の `registerRouteTemplate`、nextjs の `nextJsRegisterRouteTemplate`）は検証関数へ `maxBodyBytes` だけを渡している
- 生成コードの受理可能スコープ一覧は、`--scope` 宣言時に生成される scope ポリシーモジュール（`scopes.ts` の `SUPPORTED_SCOPES` = 標準スコープ + カスタムスコープ）が持つ。未宣言時はこのモジュール自体が生成されない

## 修正方針

- [x] `validateClientRegistrationRequest` のオプションに `supportedScopes?: readonly string[]` を追加し、`scope` を検証する
  - [x] 文字列以外は `invalid_client_metadata`（固定 ASCII 文言。リクエスト値を反映しない）
  - [x] RFC 6749 §3.3 の構文で分解する。空文字列、連続スペース等の構文違反、scope-token に使えない文字は拒否する
  - [x] `supportedScopes` 指定時、一覧外の値は拒否する
  - [x] `supportedScopes` 未指定時は構文検証のみで受理する（scope ポリシーモジュールを生成しない構成では OP 自体が受理一覧を持たないため）
  - [x] 重複する値は 1 つへ正規化する（出現順を保つ）
  - [x] 省略時は `ValidatedClientRegistration` に scope キー自体を出さない（`client_name` の `pickClientName` と同じ exactOptionalPropertyTypes 互換の形）
- [x] `DynamicallyRegisteredClient` に `scope?: string[]` を追加し、`buildRegisteredClient` で引き継ぐ（配列はコピーする）
- [x] `buildClientRegistrationResponse` で、scope が登録されているときだけスペース区切り文字列の `scope` を応答へ載せる（RFC 7591 §3.2.1 の「登録済み全メタデータ」）
- [x] hono の `registerRouteTemplate`：検証呼び出しへ `supportedScopes` を渡す。カスタムスコープ宣言時は `../scopes.js` の `SUPPORTED_SCOPES` を import し、未宣言時は渡さない（デバイス認可ルートの `findUnsupportedScopes` と同じ条件付き生成の形）
- [x] nextjs の `nextJsRegisterRouteTemplate`：同様に `_oidc-provider/scopes` の `SUPPORTED_SCOPES` を条件付きで配線する
- [x] CLI を修正するため、コード生成に対応している全フレームワーク（hono / express / fastify / web-standard / nextjs）で同じ挙動になることを確認する
- [x] notes リポジトリの実装解説（日英）の掲載コードと説明を更新する

## テスト要件

TDD で、実装より先にテストを書くこと。テストケース名は「should + 動詞」形式。

`packages/experimental/src/dynamic-client-registration/registration-request.test.ts`：

- [x] `should register the scope values from a space-delimited scope string`
      — `'openid profile'` が `['openid', 'profile']` になる（`toEqual` で一意固定）
- [x] `should omit the scope key when scope is not provided`
      — 省略時に scope キー自体が存在しない
- [x] `should reject a non-string scope with invalid_client_metadata`
- [x] `should reject an empty scope string with invalid_client_metadata`
- [x] `should reject a scope string with invalid syntax with invalid_client_metadata`
      — 連続スペースや scope-token 外の文字（例：制御文字、`"` や `\`）
- [x] `should reject a scope value outside supportedScopes with invalid_client_metadata`
- [x] `should accept any syntactically valid scope when supportedScopes is not provided`
- [x] `should deduplicate repeated scope values`
      — `'openid openid profile'` が `['openid', 'profile']` になる

`packages/experimental/src/dynamic-client-registration/registered-client.test.ts`：

- [x] `should carry the registered scope values into the client record`
- [x] `should include scope as a space-delimited string in the registration response when registered`
- [x] `should omit scope from the registration response when not registered`

`tests/e2e/specs/dynamic-client-registration.spec.ts`：

- [x] scope 付きで登録したクライアントの 201 応答に登録した `scope` がそのまま返ること
- [x] 登録した scope の範囲内の認可リクエストが成功すること
- [x] 登録していない scope を含む認可リクエストが `invalid_scope` で拒否されること

既存テストの回帰が無いこと（未知フィールド無視、5 フィールドの既定値適用、応答の形）。

## 完了条件

- `pnpm --filter @maronn-openid-connect/experimental test` がパスすること → 692 件パス
- `pnpm --filter @maronn-openid-connect/cli test` がパスすること → 65 件パス
- `pnpm test` 全体がパスすること → `pnpm --filter "./packages/*" test` 全パッケージパス、`pnpm typecheck`（packages / samples / tests）パス
- E2E（`tests/e2e` の dynamic-client-registration スペック）がパスすること → hono-cloudflare と express-flyio の両サンプルで 15 件パス
