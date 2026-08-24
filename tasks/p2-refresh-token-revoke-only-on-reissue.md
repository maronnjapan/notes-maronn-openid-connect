# [P2] 旧 Refresh Token の失効を後継発行時に限定し、後継無し応答での再利用検知の誤発火を防ぐ

## ステータス

🟠 High / 未着手

## 背景

生成 OP の token ルートは、refresh_token グラント成功時に提示された Refresh Token を無条件に失効（`used=true` 化）する。
一方、後継 RT の発行は `issueRefreshToken` の条件に従うため、`onlineRefreshTokenEnabled` を `false` へ切り替えた OP に発行済みの online refresh token が提示されると、「アクセストークンは返すが後継 RT は返さず、旧 RT だけ失効する」応答になる。

RFC 6749 §6 でクライアントが旧 RT を破棄する義務は「新しい RT を受け取った場合」にだけ生じる。
後継の無い応答を受けたクライアントが旧 RT で再度 refresh するのは仕様準拠の挙動であり、これが `validateRefreshTokenUnused` の再利用検知として扱われ、`revokeTokensByGrantId` が grant 全体（発行直後のアクセストークンを含む）を失効させる。

検討詳細は `study-material/done/refresh-token-revocation-without-reissue.md` を参照。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`（token ルートの旧 RT 失効ブロック。3944 行付近。4 テンプレート共通）
- 生成 conformance テストのブロック（`onlineRefreshTokenConformanceBlock` 付近に追加）
- 生成物（直接編集しない・確認用）: `samples/*/src/oidc-provider/routes/token.ts`

## 仕様参照

- **RFC 6749 §6** — https://www.rfc-editor.org/rfc/rfc6749#section-6
  "The authorization server MAY issue a new refresh token, **in which case** the client MUST discard the old refresh token"
- **OAuth 2.1 §4.3.1** — 旧 RT の失効は "after issuing a new refresh token to the client"
- **RFC 9700 §4.14.2** — 再利用検知は「失効した旧 RT に生きた後継がある」rotation モデルを前提とする

## 現状の実装

発行判定（`issueRefreshToken`）と失効が独立している:

```typescript
const issueRefreshToken =
  clientAllowsRefreshGrant &&
  (grantHasOfflineAccess ||
    (config.onlineRefreshTokenEnabled && boundSessionId !== undefined));
// ...
// 後継の有無を見ずに実行される
if (validatedRequest.grantType === 'refresh_token' && params.refresh_token) {
  await refreshTokenResolver.revokeRefreshToken(params.refresh_token);
}
```

## 修正方針

- [ ] 旧 RT の失効を「後継 RT を保存した場合のみ」（`tokenResponse.refresh_token` が存在する場合のみ）に変更する
- [ ] 後継を発行しない応答では旧 RT を生かしたままにする。旧 RT はセッション終了（online）または絶対寿命で失効することをコメントに明記する
- [ ] 「後継を発行できない refresh 要求を `invalid_grant` で拒否する」方針 B を採らない理由（切り替え後もアクセストークン取得を継続させる）をコミットメッセージまたはコメントに残す。着手時に方針を再確認し、B を採る場合はテスト要件を差し替える
- [ ] 生成コードは直接編集せず `packages/cli` テンプレートを修正する

## テスト要件

生成 OP の `conformance.test.ts`（生成元 `packages/cli`）に追加する。

- [ ] `should keep the presented refresh token usable when no successor is issued`
      — `onlineRefreshTokenEnabled: true` で online RT を発行後、`false` の設定で同じストアを使う OP に refresh を送り、
      (1) 200 でアクセストークンが返り `refresh_token` がレスポンスに無いこと、
      (2) 同じ RT でもう一度 refresh しても 200 が返ること、を固定する
- [ ] `should not fire the reuse cascade after a refresh without a successor`
      — 上記の 2 回目の refresh 後も、1 回目で発行されたアクセストークンが UserInfo で使えること（grant 全体が失効していないこと）を固定する
- [ ] 既存の rotation テスト（後継発行時に旧 RT が失効し、再提示で cascade が発火する）が回帰しないこと

## 完了条件

- `pnpm --filter @maronn-openid-connect/cli test` がパスする
- `samples/*` を再生成し、各 `conformance.test.ts` が通る
- `pnpm typecheck` がパスする
- 後継 RT を含む応答では従来どおり旧 RT が失効することがテストで固定されている
