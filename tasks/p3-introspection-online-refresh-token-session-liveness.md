# [P3] Introspection の `active` 判定に online refresh token のセッション生存を反映する

## ステータス

🟡 Medium / 未着手

## 背景

Token Endpoint は `sessionId` を持つ Refresh Token（online refresh token）について、束縛先セッションが終了していれば `validateRefreshTokenSession` で `invalid_grant` を返す。
一方 Introspection の `isRefreshTokenActive` は `used` と `expiresAt` しか見ず、`IntrospectionRequestContext` にセッションを引く入力も無い。
ログアウト済みで二度と使えない online refresh token が、絶対寿命が尽きるまで `active: true` と報告される。

アイドルタイムアウト軸の同型問題（`tasks/p3-introspection-refresh-token-idle-timeout-active-consistency.md`）はオプトイン設定で顕在化するのに対し、online refresh token は生成 OP の既定（`onlineRefreshTokenEnabled: true`）で発行されるため、既定構成で不整合が生じる。

検討詳細は `study-material/done/introspection-online-refresh-token-session-liveness.md` を参照。
アイドル軸タスクと同時に実装する場合、`active` 判定への入力追加を一度の変更でまとめてよい。

## 対象ファイル

- `packages/core/src/introspection.ts`（`IntrospectionRequestContext`、`isRefreshTokenActive`: 125 行付近）
- `packages/core/src/introspection.test.ts` / `introspection-steps.test.ts`
- `packages/cli/src/frameworks/hono/templates.ts`（introspection ルートへの resolver 配線と conformance ブロック）

## 仕様参照

- **RFC 7662 §2.2** — https://www.rfc-editor.org/rfc/rfc7662#section-2.2
  `active` は "whether or not the presented token is currently active"。OP 自身が受け付けないトークンは "invalid for other reasons" にあたる
- **RFC 9700 §4.14** — 失効状態の観測面での一貫性
- 実装済みの Token Endpoint 側検証: `packages/core/src/refresh-token-grant.ts` の `validateRefreshTokenSession`

## 現状の実装

```typescript
// packages/core/src/introspection.ts:125-129
function isRefreshTokenActive(info: RefreshTokenInfo, now: number): boolean {
  if (info.used) return false;
  if (info.expiresAt <= now) return false;
  return true;
}
```

生成 OP の `introspectionRefreshTokenResolver` はストアのレコードをそのまま返すだけで、セッション状態を見ない。

## 修正方針

- [ ] `IntrospectionRequestContext` に任意の `authenticationSessionResolver?: AuthenticationSessionResolver` を追加する
- [ ] `sessionId` を持つ RT について、resolver が設定されていればセッションを引き、見つからなければ `active: false` とする
- [ ] resolver 未指定かつ `sessionId` 付き RT の扱い（fail-open で従来挙動とするか）を決め、JSDoc に明記する。Token Endpoint 側（fail-closed）との違いを説明できる理由を残すこと
- [ ] 生成 OP の introspection ルートへ、Token Endpoint と同じ `authenticationSessionResolver` を配線する
- [ ] `packages/core` の変更に対する changeset を作成する

## テスト要件

`packages/core`:

- [ ] `should report an online refresh token inactive when its session has ended`
- [ ] `should keep an online refresh token active while its session is alive`
- [ ] `should keep an offline refresh token active without a session resolver`（`sessionId` 無しの RT は従来どおり）
- [ ] resolver 未指定時の挙動を、決めた方針どおりに固定する

生成 OP の `conformance.test.ts`:

- [ ] ログイン → online RT 発行 → ログアウト（セッション削除）後、introspection が `active: false` を返すことを固定する

## 完了条件

- `pnpm --filter @maronn-openid-connect/core test` / `pnpm --filter @maronn-openid-connect/cli test` がパスする
- `samples/*` を再生成し、各 `conformance.test.ts` が通る
- `pnpm typecheck` がパスする
- Token Endpoint が拒否する online RT を Introspection が `active: true` と報告する経路が（resolver 配線済みの構成で）存在しない
