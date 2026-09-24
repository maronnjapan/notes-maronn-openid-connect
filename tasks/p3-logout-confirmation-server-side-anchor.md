# [P3] ログアウト確認の照合先をサーバー側ストアへ移し、Cookie にはシークレットだけを載せる

## ステータス

🟢 Low / 未着手

## 背景

RP-Initiated Logout の確認画面は、描画時に CSRF シークレットを発行し、OP が解決したリダイレクト先とともに `oidc_logout_confirm` Cookie の値へ載せる。
`POST /logout/approve` は「Cookie 内のシークレット」と「フォームの hidden `csrf_token`」の一致だけを確認し、サーバー側には照合先を持たない。

同じ生成 OP のデバイス検証束縛（`oidc_device_<user_code>`）と CIBA ログイン束縛（`oidc_ciba_login_<transactionId>`）は逆の形を採っている。
秘密の SHA-256 ハッシュをサーバー側レコードに保存し、Cookie の生値をハッシュ化して突き合わせるため、Cookie を書き込めた攻撃者でも承認を偽造できない。

ログアウト確認がクライアント側比較だけである結果、兄弟ホストから Cookie を書き込める環境（RFC 6265 §8.6）では、攻撃者が自分で選んだシークレットとリダイレクト先を注入し、確認画面を経ずに被害者のセッション削除（強制ログアウト）と、OP オリジンから攻撃者 URL への 302（登録チェックを通らないオープンリダイレクト）を同時に成立させられる。
`tasks/p2-op-cookie-host-prefix.md` の `__Host-` プレフィックスが書き込み自体を防ぐが、本タスクは書き込まれても照合で落とす多層防御として、確認状態をサーバー側へ移す。

検討詳細は `study-material/done/logout-confirmation-cookie-client-side-trust-and-host-prefix-scope-drift.md` を参照。

> 関連（重複しない）：Cookie 名前空間の隔離は `tasks/p2-op-cookie-host-prefix.md` が扱う。
> 本タスクは **承認の照合先をどちら側に置くか** だけを対象とする。

## 対象ファイル

- `packages/cli/src/frameworks/hono/templates.ts`
  - `storeTemplate`：`buildLogoutConfirmationCookie` / `parseLogoutConfirmation`（`:1483-1540` 付近）と、確認レコードを保存するストアの追加
  - `endSessionRouteTemplate`（`:4414` 以降）：確認画面の描画と `POST /logout/approve` の照合
- `packages/cli/src/__tests__/rp-initiated-logout-feature.test.ts`
- 各 sample の `conformance.test.ts` を生成する `packages/cli` 側コード（ログアウト確認の期待値）
- `tests/e2e/specs/rp-initiated-logout.spec.ts`（回帰確認）
- 生成物（直接編集しない・確認用）：`samples/hono-cloudflare/src/oidc-provider/store.ts:378-460`、`samples/hono-cloudflare/src/oidc-provider/routes/logout.ts`

## 仕様参照

- **OpenID Connect RP-Initiated Logout 1.0 §3**：`post_logout_redirect_uri` は登録値と一致しない限り使用してはならない（MUST NOT）。リダイレクト先の決定はサーバー側の解決結果だけを信頼する
- **OpenID Connect RP-Initiated Logout 1.0 §7**：確認画面は有効なヒントのないログアウト要求による DoS への防御であり、承認 POST の偽造はその防御の迂回になる
- **RFC 6265 §8.6 Weak Integrity**：Cookie は兄弟ホストからの書き込みを防がない
- 設計の先例：デバイス検証束縛 Cookie（RFC 8628 §5.4 / §3.3 の考察に基づく実装。ハッシュ手順は `packages/experimental/src/device-authorization-grant/verification.ts`、生成物は `samples/hono-cloudflare/src/oidc-provider/store.ts:1061-1135`）

## 現状の実装

```typescript
// samples/hono-cloudflare/src/oidc-provider/store.ts:388-398
export function buildLogoutConfirmationCookie(confirmation: LogoutConfirmation): string {
  const bytes = new TextEncoder().encode(confirmation.redirectTo ?? '');
  const binary = Array.from(bytes, (byte) => String.fromCharCode(byte)).join('');
  const encodedRedirect = btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  return (
    LOGOUT_CONFIRMATION_COOKIE + '=' + confirmation.csrfSecret + '.' + encodedRedirect +
    '; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=600'
  );
}
```

`POST /logout/approve`（`routes/logout.ts`）は `parseLogoutConfirmation` の返す `csrfSecret` とフォームの `csrf_token` の文字列一致だけで承認し、レコードの参照も削除も行わない。

## 修正方針

- [ ] 生成 store にログアウト確認レコードのストアを追加する（キー：シークレットの SHA-256 ハッシュ。値：`redirectTo` と期限。TTL 600 秒。ハッシュは `packages/experimental/src/device-authorization-grant/verification.ts` と同じ `crypto.subtle.digest('SHA-256', ...)` + Base64URL の手順を使う）
- [ ] 確認画面の描画時に、シークレットのハッシュと `redirectTo` をストアへ保存し、Cookie の値はシークレットだけにする（`.` 区切りの base64url 部分を廃止）
- [ ] `POST /logout/approve` は、フォームの `csrf_token` と Cookie のシークレットの一致に加え、シークレットのハッシュでストアを引き、レコードが無ければ 400 で何も削除しない
- [ ] レコードは承認時に消費（削除）し、同じ確認画面の承認 POST を再送しても 2 度目は 400 になるようにする
- [ ] リダイレクト先はストアのレコードから取り、Cookie の値からは復元しない
- [ ] 生成コードは直接編集せず `packages/cli` テンプレートを修正し、コード生成に対応している全フレームワークへ適用する
- [ ] `conformance.test.ts` の生成側を新しい Cookie 形式と照合手順に追随させる

## テスト要件

- [ ] `should reject the approve POST when the confirmation record is absent` — Cookie とフォームの値が一致していても、ストアにレコードが無ければ 400 でセッションを削除しないこと
- [ ] `should reject a replayed approve POST after the record was consumed` — 一度承認した確認の再送が 400 になること
- [ ] `should carry only the csrf secret in the logout confirmation cookie` — `Set-Cookie` の値にリダイレクト先由来の `.` 区切りセグメントが含まれないこと
- [ ] `should honor the redirect target stored server-side after approval` — 承認後の 302 の `Location` がストアに保存した解決結果と一致すること
- [ ] 既存のログアウト確認フロー（確認画面の表示、承認によるセッション削除、完了画面）が回帰しないこと

## 完了条件

- `pnpm --filter @maronn-openid-connect/cli test` がパスすること
- `pnpm test:conformance` がパスすること
- `pnpm test:e2e` の rp-initiated-logout スペックがパスすること
- `pnpm typecheck` がパスすること
