# [P2] 同意拒否（`access_denied`）フローの E2E / 契約テストを追加する

## ステータス

✅ 完了（2026-07-21）

## 背景

同意画面の「Deny（拒否）」押下時、生成 OP は `error=access_denied` を `redirect_uri` のクエリへ返し、`state` を echo、RFC 9207 の `iss` を付与し、transaction / auth session を破棄する実装を**既に持っている**。しかし検証側に穴がある:

- `tests/e2e/specs/` の E2E は **成功系（Approve）のみ**で、拒否経路の回帰テストが無い。
- 各 sample の `conformance.test.ts` に「拒否時 `access_denied` 返却」の契約アサーションが見当たらない。

CLAUDE.md は「実ブラウザ・実 HTTP フローで検証できる場合は原則 `tests/e2e` に E2E を追加」「`conformance.test.ts` は OP の想定挙動を全網羅」と定めており、拒否はブラウザ操作で再現できる主要分岐であるため、現状の検証カバレッジはこの方針に対して不足している。利用者が同意画面をカスタマイズして deny 分岐や `state` echo を壊しても、テストが緑のまま通り RP のキャンセル検知が静かに壊れる。

検討の詳細は `study-material/done/authorization-access-denied-deny-flow-e2e.md` を参照。

## 対象ファイル

- `tests/e2e/specs/`（拒否経路 spec を追加。既存 `auth-code-flow.spec.ts` の login→consent 導線を流用）
- （方針 B/C 採用時）`packages/cli/src/frameworks/*/templates.ts` 内の `conformance.test.ts` 生成元、および反映先の `samples/{express,hono,fastify,nextjs}/src/oidc-provider/conformance.test.ts`
- 確認用（変更不要・仕様準拠済み）: `packages/cli/src/frameworks/web-standard/templates.ts`（deny ハンドリング L1175 付近）

## 仕様参照

- **RFC 6749 §4.1.2.1 Error Response** — リソースオーナー拒否時は `error=access_denied` を `redirect_uri` のクエリで返し、`state` があれば echo する。
  https://www.rfc-editor.org/rfc/rfc6749#section-4.1.2.1
- **OpenID Connect Core 1.0 §3.1.2.6 Authentication Error Response** — 認可エンドポイントのエラーは RFC 6749 §4.1.2.1 に従う。
  https://openid.net/specs/openid-connect-core-1_0.html#AuthError
- **RFC 9207 §2** — 認可レスポンス（成功・エラー双方）に `iss` を含める。
  https://www.rfc-editor.org/rfc/rfc9207

## 現状の実装

- 拒否ハンドリング（`packages/cli/src/frameworks/web-standard/templates.ts` L1175 付近、4 フレームワーク同等）:
  ```ts
  if (action === 'deny') {
    const denyUrl = new URL(transaction.redirectUri);
    denyUrl.searchParams.set('error', 'access_denied');
    if (transaction.state) denyUrl.searchParams.set('state', transaction.state);
    denyUrl.searchParams.set('iss', issuer); // RFC 9207 §2
    await transactionStore.delete('auth_txn:' + transactionId);
    await authSessionStore.delete(transactionId);
    redirect(denyUrl.toString());
  }
  ```
  → 仕様準拠。**実装変更は不要**。欠けているのは E2E / 契約テストのみ。
- 既存テスト: CLI ジェネレータ単体テストに `deny` 生成の参照はあるが、実フロー（ブラウザ操作・リダイレクト先検証）は無い。

## 修正方針

- [ ] `tests/e2e/specs/` に拒否経路 spec を追加する（既存 `auth-code-flow.spec.ts` の login→consent 部分を流用し、**Approve の代わりに Deny をクリック**）。
- [ ] リダイレクト先 URL を検証する（CLAUDE.md テスト規約: 合格値を一意に固定する）:
  - `redirect_uri` のオリジン＋パスが登録値と完全一致
  - クエリ `error` が `'access_denied'`（`toBe`）
  - クエリ `state` が送信値と完全一致
  - クエリ `iss` が issuer と完全一致
  - フラグメントではなくクエリで返ること（`#` に値が乗らない）
- [ ] 拒否後、認可コードが発行されていない／transaction・auth session が破棄されていることを検証する。
- [ ] （方針 B/C 採用時）cli 側の `conformance.test.ts` 生成元に拒否経路の契約ケースを追加し、4 sample に反映する（直接 sample を編集せず生成元を修正）。
- [ ] 不正 `redirect_uri` 時は拒否レスポンスもリダイレクトしない（UA 直接エラー）ことの確認ケースを検討する。

```ts
// イメージ（tests/e2e/specs/access-denied-flow.spec.ts）
await page.getByRole('button', { name: 'Deny' }).click();
const url = new URL(page.url());
expect(`${url.origin}${url.pathname}`).toBe(redirectUri);
expect(url.searchParams.get('error')).toBe('access_denied');
expect(url.searchParams.get('state')).toBe(sentState);
expect(url.searchParams.get('iss')).toBe(issuer);
expect(url.hash).toBe('');
```

## テスト要件

- [ ] login→consent→Deny の実ブラウザフローで `redirect_uri?error=access_denied&state=...&iss=...` が返ること。
- [ ] `state` が送信値と完全一致で echo されること。
- [ ] `iss` が issuer と完全一致で付与されること（RFC 9207）。
- [ ] エラーがフラグメントでなくクエリで返ること。
- [ ] 拒否後に認可コードが発行されていないこと。
- [ ] （契約テスト追加時）各 sample の `conformance.test.ts` で拒否経路が固定され、生成コード改変時に検知できること。

## 完了条件

- `pnpm test:e2e` がパスし、拒否経路 spec が緑であること。
- （契約テスト追加時）`pnpm --filter @maronn-openid-connect/cli test` および対象 sample の conformance テストがパスすること。
- 拒否時の `error` / `state` / `iss` / 返却方式（クエリ）が一意の期待値で固定されていること。
