# [P3] Token Introspection に呼び出し元認可フック（`canIntrospect`）を追加する

## ステータス

🟢 Low / 未着手

## 背景

Token Introspection（RFC 7662）の現実装は、**認証済みの confidential client であれば、どのトークンでも introspect でき、active=true 時に `sub` / `scope` / `aud` / `iss` / `client_id` などのフル属性を返す**。RFC 7662 §4 Security Considerations は「privileged information の許可されていない当事者への開示を防ぐ」「introspection を必要とする resource server に限定する」「返却情報を最小化する」ことを促しており、マルチクライアントを 1 OP に同居させる検証用途では、あるクライアントが他クライアント／他ユーザーのトークン属性を収集できてしまう。

検討の詳細は `study-material/done/introspection-caller-authorization-and-disclosure.md` を参照。本タスクは、その中で **非破壊・後方互換** に着手できる「オプトインの呼び出し元認可フック」だけを切り出す（既定挙動の変更や claim minimization は本タスク対象外）。

Basic OP 必須要件ではない（OAuth 拡張のセキュリティ・ハードニング）。

## 対象ファイル

- `packages/core/src/introspection.ts`（`IntrospectionRequestContext` / `handleIntrospectionRequest`）
- `packages/core/src/introspection.test.ts`
- `packages/cli/src/frameworks/hono/templates.ts`（有効化例のコメント追加。既定は無効）
- `packages/sample/src/oidc-provider/routes/introspection.ts`（同上）

## 仕様参照

- RFC 7662 §2.1 Introspection Request — https://www.rfc-editor.org/rfc/rfc7662#section-2.1
  （token scanning 防止のための authorization、caller は自分宛トークンを introspect する想定）
- RFC 7662 §4 Security Considerations — https://www.rfc-editor.org/rfc/rfc7662#section-4
  （privileged information の開示防止 / resource server への限定 / 返却情報の最小化）

## 現状の実装

```ts
// packages/core/src/introspection.ts:8-13（設計コメント）
// RFC 7662 §2.1: クライアント認証は必須だが、トークン所有クライアントと
// caller の一致は要件ではない（...）。本実装も同様に所有チェックは行わず、
// authenticated confidential client であればいずれのトークンも introspect 可能。

// introspection.ts:144- handleIntrospectionRequest
// → authenticatedClientId が非空かだけ確認し、caller とトークンの関係は検証しない。
//   active 判定後、buildAccessTokenResponse / buildRefreshTokenResponse でフル属性を返す。
```

- `AccessTokenInfo.audience` / `RefreshTokenInfo.audience` / `clientId` は既に保持済みで、caller との突き合わせに必要なデータは揃っている。

## 修正方針

- [ ] `IntrospectionRequestContext` に任意フィールドを追加する（未指定なら従来挙動を維持）:
  ```ts
  /**
   * 呼び出し元がこのトークンを introspect してよいかを判定する任意フック。
   * false を返した場合は { active: false } を返し、特権情報を一切開示しない（RFC 7662 §4）。
   * 未指定時は従来どおり全 confidential client に開示する（後方互換）。
   */
  canIntrospect?: (ctx: {
    callerClientId: string;
    tokenKind: 'access_token' | 'refresh_token';
    tokenInfo: AccessTokenInfo | RefreshTokenInfo;
  }) => boolean | Promise<boolean>;
  ```
- [ ] `handleIntrospectionRequest` で、トークンを引き当てて active と判定した **直後・レスポンス構築の直前**に `canIntrospect` を評価し、false なら `{ active: false }`（`INACTIVE`）を返す。
- [ ] `canIntrospect` 未指定時は評価をスキップ（既存パス維持）。
- [ ] CLI/sample テンプレートに、resource server 限定ポリシーの実装例をコメントで提示（既定は無効）:
  ```ts
  // 例: 自分が発行先クライアント、または自分が aud（resource server）に含まれる場合のみ許可
  // canIntrospect: ({ callerClientId, tokenInfo }) =>
  //   callerClientId === tokenInfo.clientId ||
  //   (('audience' in tokenInfo && tokenInfo.audience?.includes(callerClientId)) ?? false),
  ```

## テスト要件

- [ ] `canIntrospect` 未指定なら、access/refresh とも従来どおり全属性を返す（後方互換の回帰防止）
- [ ] `canIntrospect` が false を返す場合、active なトークンでも `{ active: false }` を返し、`sub` などを一切含まない
- [ ] `canIntrospect` が true を返す場合は従来どおり active=true のメタデータを返す
- [ ] caller=発行先 clientId、caller=aud に含まれる resource server の両ケースで許可される実装例が機能する
- [ ] `canIntrospect` が Promise を返す（async）場合も正しく await される

## 完了条件

`pnpm --filter @maronn-openid-connect/core test` がパスし、既存の introspection テストが回帰しないこと。
