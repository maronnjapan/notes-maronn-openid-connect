# 後継を発行しない refresh_token グラントでも旧トークンを失効させている（正当なリトライが再利用検知を誤発火させる）

## 1. タイトル

生成 OP の token ルートは、refresh_token グラントが成功すると `params.refresh_token` を無条件に `used=true` へ失効させる。
一方、新しい Refresh Token の発行は `issueRefreshToken` の条件（`grant_types` 登録、`offline_access` の有無、`onlineRefreshTokenEnabled`、セッション束縛の有無）に従うため、**レスポンスに後継 RT が無いのに提示 RT だけが失効する**組み合わせが存在する。
このときクライアントの仕様準拠の挙動（旧 RT を使い続ける）が、次回のリクエストで再利用検知として扱われ、`revokeTokensByGrantId` が grant 全体を失効させる。

## 2. このトピックで確認したいこと

- RFC 6749 §6 / OAuth 2.1 §4.3.1 は、旧 RT の破棄・失効を「新しい RT を発行した場合」に結び付けている。後継無しの応答で旧 RT を失効させる現実装が、この規定と整合するか
- `onlineRefreshTokenEnabled` を `true` から `false` へ切り替えた運用で、切り替え前に発行済みの online refresh token がどう振る舞うべきか
- 再利用検知 cascade（盗難対応）が、盗難ではない正当なリトライで発火する経路を塞げるか

## 3. 関連する仕様・基準

- **RFC 6749 §6**: "The authorization server MAY issue a new refresh token, in which case the client MUST discard the old refresh token and replace it with the new refresh token."。クライアントが旧 RT を破棄する義務は、新 RT を受け取った場合にだけ生じる
- **OAuth 2.1 §4.3.1**: "The authorization server MAY revoke the old refresh token after issuing a new refresh token to the client."。サーバ側の失効も後継発行後の操作として書かれている
- **RFC 9700 §4.14.2**: rotation と再利用検知のモデルは「失効した旧 RT には生きた後継がある」ことを前提とする。後継の無い失効は、このモデルの外で cascade を誤発火させる

rotation の部分的失敗（保存に失敗した場合の順序）は `study-material/refresh-token-rotation-partial-failure-and-family-branching.md`、rotation 二重送信の猶予は `study-material/refresh-token-rotation-replay-grace.md` が扱う。
本トピックは「そもそも後継を発行しない応答で旧 RT を失効させてよいか」という別の論点である。

## 4. 参照資料

- RFC 6749 The OAuth 2.0 Authorization Framework §6 — https://www.rfc-editor.org/rfc/rfc6749#section-6
- OAuth 2.1 draft §4.3.1（Refresh Token Grant）
- RFC 9700 OAuth 2.0 Security Best Current Practice §4.14 — https://www.rfc-editor.org/rfc/rfc9700.html
- 本リポジトリ内: `tasks/done/p1-refresh-scope-offline-access-rotation.md`（scope 縮小起因の同型問題を修正済み。本ファイルは設定トグル起因の残存経路）

## 5. 現在の実装確認

生成元は `packages/cli/src/frameworks/hono/templates.ts` の token ルート（4 テンプレート共通）。

- 発行判定（templates.ts 3867 付近）:

```typescript
const issueRefreshToken =
  clientAllowsRefreshGrant &&
  (grantHasOfflineAccess ||
    (config.onlineRefreshTokenEnabled && boundSessionId !== undefined));
```

- 旧 RT の失効（templates.ts 3944 付近）。`issueRefreshToken` を見ずに実行される:

```typescript
if (validatedRequest.grantType === 'refresh_token' && params.refresh_token) {
  await refreshTokenResolver.revokeRefreshToken(params.refresh_token);
}
```

- 再利用検知: `packages/core/src/refresh-token-grant.ts` の `validateRefreshTokenUnused` が `used=true` の RT の再提示で `revokeTokensByGrantId`（grant 全体の失効）を発火する

具体的な発火経路: `onlineRefreshTokenEnabled: true` で発行済みの online refresh token が残った状態で設定を `false` に切り替える。
次の refresh は全検証を通過し（セッションは生存）、アクセストークンを返すが `issueRefreshToken` は false なので後継 RT を含まない。
それでも旧 RT は失効済みになり、クライアントが旧 RT で再度 refresh すると盗難扱いになる。
生成 conformance テストは `onlineRefreshTokenEnabled: false` の新規発行経路のみ検証しており、切り替え前に発行済みの RT の経路は固定されていない。

## 6. 現在の実装との差分

満たしていること:

- 後継を発行する通常の rotation では、新 RT 保存成功後に旧 RT を失効させる順序が守られている
- scope 縮小で `offline_access` が落ちても rotation が継続する問題は `hadOfflineAccess` で修正済み

不足している可能性があること:

- 🟡 **後継無し応答での旧 RT 失効**: RFC 6749 §6 の "in which case" と噛み合わない。仕様準拠クライアントの次回リクエストが grant 全体の失効（発行直後のアクセストークンを含む）に化ける
- 🟡 この経路の conformance テストが無い

## 7. 改善・追加を検討する理由

再利用検知 cascade は盗難対応の機構であり、正当な操作で発火させてはならない。
発火すると、ユーザー影響（突然の全トークン失効）とセキュリティ監視のノイズ（偽陽性の盗難シグナル）の両方が生じる。
修正自体は失効の条件を後継発行に揃える小さな変更で、rotation の既存挙動には触れない。

## 8. 実装方針の候補

- **方針 A**: 旧 RT の失効を `tokenResponse.refresh_token` が存在する場合に限定する。後継が無ければ旧 RT は生かしたままにする（RFC 6749 §6 に忠実。旧 RT はセッション終了か絶対寿命で自然に失効する）
- **方針 B**: 後継を発行できない refresh 要求自体を `invalid_grant` で拒否する（online RT を「もう受け付けない」ことを明示する）。ただし切り替え後もアクセストークン取得は継続させたい運用では過剰
- **方針 C**: `onlineRefreshTokenEnabled` の切り替え時に発行済み online RT を一括失効する運用手順を文書化する（コード変更なし。ただし手順を踏まない運用では問題が残る）

方針 A が仕様の文言と一致し、影響範囲も最小である。B / C を併用するかは人間が判断する。

## 9. タスク案

- `tasks/p2-refresh-token-revoke-only-on-reissue.md` として切り出す（方針 A ベース）
  - 生成テンプレートの失効ブロックを「後継 RT を保存した場合のみ」へ変更
  - conformance テスト: `onlineRefreshTokenEnabled: false` へ切り替えた OP で、発行済み online RT による refresh が (1) アクセストークンを返し後継 RT を含まない、(2) 旧 RT が失効せず再度 refresh できる、(3) 再利用検知が誤発火しない、を固定
  - 方針 B / C を採る場合の差分はタスク内で再検討
