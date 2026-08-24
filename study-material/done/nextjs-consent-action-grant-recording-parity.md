# Next.js の consent Server Action が grantId を記録せず、同意撤回によるトークン失効が効かない

## 1. タイトル

同意撤回の失効ループは、「同意時に `recordGrant` で `(subject, clientId) → grantId` を索引し、撤回時に `consentStore.revoke` が返す grantId 群を `revokeTokensByGrantId` へ渡す」構造で実装されている。
hono / express / fastify が使う共通の consent ルートと、prompt=none / SSO の非対話経路はこの索引を記録するが、**Next.js ターゲットの対話同意（consent Server Action）だけが `recordConsent` のみで `recordGrant` を呼ばない**。
その結果、Next.js ターゲットでは対話同意から発行されたトークンが同意撤回で失効しない。

## 2. このトピックで確認したいこと

- Next.js の consent Server Action（`consent/actions.ts` の生成元 `nextJsConsentActionTemplate`）が、共通 consent ルートと同じ副作用（`recordConsent` + `recordGrant`）を持つべきこと
- Next.js ターゲットの conformance テストが共通ルート（`routes/consent.ts`）を駆動しており、実際にデプロイされるページ経路（Server Action）の欠落を検知できていないこと
- 他に Server Action と共通ルートで副作用が食い違っている箇所が無いか（テンプレート派生の網羅確認）

## 3. 関連する仕様・基準

同意撤回とトークン失効の設計は `study-material/done/consent-withdrawal-grant-token-revocation.md` と `tasks/done/p3-consent-withdrawal-grant-token-revocation.md` で確定済みであり、本ファイルはそのターゲット間パリティの欠落だけを扱う。

- **OIDC Core 1.0 §11**: `offline_access` は End-User の同意に根拠を置く。同意を撤回したのに Refresh Token が生き続ける状態は、撤回ループが塞ぐと決めた不整合そのもの
- **RFC 9700**: 長期資格情報（Refresh Token)は失効可能であることが前提

## 4. 参照資料

- OpenID Connect Core 1.0 §11 — https://openid.net/specs/openid-connect-core-1_0.html#OfflineAccess
- RFC 9700 OAuth 2.0 Security Best Current Practice — https://www.rfc-editor.org/rfc/rfc9700.html
- 本リポジトリ内: `study-material/done/consent-withdrawal-grant-token-revocation.md`（撤回ループの設計）、`study-material/done/cli-web-standard-template-derivation-contract.md` と `tasks/p3-web-standard-template-derivation-guard.md`（テンプレート派生のパリティ保証。本件はそのガードの検出範囲外だった事例）

## 5. 現在の実装確認

- 共通 consent ルート（`packages/cli/src/frameworks/hono/templates.ts` の consent ルートテンプレート）: `recordConsent` に続けて `recordGrant?.(session.subject, transaction.clientId, authCodeData.grantId)` を呼ぶ。prompt=none / SSO の非対話経路（同ファイルの authorize ルート内 2 箇所）も同様
- Next.js の Server Action（`packages/cli/src/frameworks/web-standard/templates.ts:1847` 付近、`nextJsConsentActionTemplate`）: `recordConsent` のみで `recordGrant` を呼ばない
- 生成物での確認: `samples/nextjs-vercel/src/app/consent/actions.ts:97` は `recordConsent` のみ。`samples/nextjs-vercel/src/app/_oidc-provider/routes/consent.ts` は両方を呼ぶが、この共通ルートは Next.js ターゲットでは conformance テストからしか駆動されない（デプロイされるページは Server Action を使う）
- 撤回側（`revokeConsentAndTokens`）: `consentStore.revoke(subject, clientId)` が返す grantId 群に対して `revokeTokensByGrantId` を呼ぶ。索引が空なら何も失効しない

## 6. 現在の実装との差分

満たしていること:

- hono / express / fastify の対話同意、および全ターゲットの非対話経路（prompt=none / SSO）では索引が記録され、撤回で失効する
- Next.js ターゲットでも `recordConsent` は記録されるため、同意スキップ（SSO）の判定自体は撤回後に正しく失敗する

不足している可能性があること:

- 🔴 **Next.js の対話同意で grantId 索引が欠落**: `openid offline_access` を承認して発行された Refresh Token / アクセストークンが、「アクセスを取り消す」操作後も有効なまま残る。撤回後に `prompt=none` は失敗し始めるため、利用者からは「撤回は効いたのにトークンは生きている」半端な状態に見える
- 🟡 conformance テストが共通ルートを駆動するため、この欠落を検知しない（テストは green のままデプロイ経路が壊れている）

## 7. 改善・追加を検討する理由

同意撤回の失効ループは実装済み機能であり、その保証が特定ターゲットのデプロイ経路だけで欠けているのは、機能の欠落ではなくパリティのバグである。
修正は Server Action テンプレートに 1 呼び出しを足すだけで、他ターゲットの挙動には触れない。
放置すると、Next.js で生成した OP の利用者だけが「撤回してもトークンが失効しない」ことに気付けない。

## 8. 実装方針の候補

- **方針 A**: `nextJsConsentActionTemplate` に共通ルートと同じ `recordGrant?.(...)` 呼び出しを追加する
- **方針 B**: 方針 A に加え、Server Action と共通ルートの副作用パリティを generator テストで固定する（`recordGrant` を含む主要呼び出しが両方に現れることを文字列で検証）。同型の欠落の再発防止になる
- Server Action 経路を実際に駆動する検証は、Next.js の実行環境を要するため E2E 側での固定を検討する（conformance テストの範囲では方針 B の文字列固定が現実的）

## 9. タスク案

- `tasks/p2-nextjs-consent-action-record-grant.md` として切り出す（方針 A + B）
  - `nextJsConsentActionTemplate` へ `recordGrant` 呼び出しを追加し、`samples/nextjs-vercel` を再生成
  - generator テストで Server Action 生成物に `recordGrant` が含まれることを固定
  - 可能なら E2E（nextjs-vercel ターゲット）で「対話同意 → 撤回 → RT が invalid_grant」を検証
