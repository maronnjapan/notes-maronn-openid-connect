# [P2] Next.js の consent Server Action に `recordGrant` を追加し、同意撤回のトークン失効を全ターゲットで成立させる

## ステータス

🟠 High / 未着手

## 背景

同意撤回の失効ループは「同意時に `recordGrant` で `(subject, clientId) → grantId` を索引し、撤回時に索引された grantId を `revokeTokensByGrantId` へ渡す」構造で実装されている。
共通の consent ルートと prompt=none / SSO の非対話経路は索引を記録するが、Next.js ターゲットで実際にデプロイされる対話同意（consent Server Action）だけが `recordConsent` のみで `recordGrant` を呼ばない。
そのため Next.js ターゲットでは、対話同意から発行された Refresh Token とアクセストークンが同意撤回後も失効しない。

Next.js の conformance テストは共通ルート（`routes/consent.ts`）を駆動しており、この欠落はテスト green のまま残る。
検討詳細は `study-material/done/nextjs-consent-action-grant-recording-parity.md` を参照。

## 対象ファイル

- `packages/cli/src/frameworks/web-standard/templates.ts`（`nextJsConsentActionTemplate`。1847 行付近の `recordConsent` 呼び出しの直後）
- `packages/cli/src/__tests__/web-framework-generators.test.ts`（生成物の固定）
- 生成物（直接編集しない・確認用）: `samples/nextjs-vercel/src/app/consent/actions.ts:97` 付近
- 可能なら `tests/e2e`（nextjs-vercel ターゲットの撤回フロー）

## 仕様参照

- **OpenID Connect Core 1.0 §11** — https://openid.net/specs/openid-connect-core-1_0.html#OfflineAccess
  `offline_access` は End-User の同意に根拠を置く。撤回後もトークンが生きる状態は撤回ループが塞ぐと決めた不整合
- **RFC 9700** — 長期資格情報は失効可能であることが前提
- 実装済みの撤回ループ: `tasks/done/p3-consent-withdrawal-grant-token-revocation.md`

## 現状の実装

共通 consent ルート（全ターゲットの `routes/consent.ts`。Next.js では conformance テスト専用）:

```typescript
await consentResolver.recordConsent?.(session.subject, transaction.clientId, grantedScope);
await consentResolver.recordGrant?.(
  session.subject,
  transaction.clientId,
  authCodeData.grantId,
);
```

Next.js の Server Action（デプロイされるページ経路。生成元 `nextJsConsentActionTemplate`）:

```typescript
await consentResolver.recordConsent?.(
  session.subject,
  transaction.clientId,
  grantedScope,
);
// recordGrant の呼び出しが無い
```

撤回側は `consentStore.revoke(subject, clientId)` が返す grantId 群を失効させるため、索引が無い grant は失効しない。

## 修正方針

- [ ] `nextJsConsentActionTemplate` に、共通ルートと同じ位置・同じ引数の `recordGrant?.(...)` 呼び出しを追加する
- [ ] `samples/nextjs-vercel` を再生成する（生成物は直接編集しない）
- [ ] Server Action と共通 consent ルートの副作用パリティ（`recordConsent` / `recordGrant` / 認可コード保存 / セッション削除）を generator テストで固定し、同型の欠落の再発を防ぐ
- [ ] 他の Server Action（login 等）にも共通ルートとの副作用差分が無いかを確認し、あれば同じ変更内で揃えるか、別タスクとして記録する

## テスト要件

`packages/cli`:

- [ ] `should record the grant id in the generated Next.js consent action`
      — 生成された `consent/actions.ts` に `recordGrant` 呼び出しが含まれることを文字列で固定する
- [ ] 共通ルートとの副作用パリティを検証するテスト（両生成物に同じ resolver 呼び出し列が現れること）

`tests/e2e`（実施可能なら）:

- [ ] nextjs-vercel ターゲットで「対話同意 → `offline_access` 付き発行 → 撤回 → refresh が `invalid_grant`」を検証する

## 完了条件

- `pnpm --filter @maronn-openid-connect/cli test` がパスする
- `samples/nextjs-vercel` を再生成し、`check:generated` が一致する
- `pnpm typecheck` がパスする
- 生成された `consent/actions.ts` に `recordGrant` 呼び出しが存在する
