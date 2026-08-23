# Auth Transaction の CSRF トークン比較を定数時間化する（プロジェクト方針との整合）

## 1. タイトル

`validateCsrfToken` がログイン/同意 POST の CSRF トークンを平文 `!==` で比較しており、本リポジトリが `client_secret` 比較で既に採用している定数時間比較（`timingSafeEqual`）と非対称になっている点の是正検討。

## 2. このトピックで確認したいこと

- Auth Transaction ごとに生成されるランダムな CSRF トークンは、ログイン/同意フォーム POST を守る**秘密のベアラ値**である。にもかかわらず、その比較が `csrfToken !== transaction.csrfToken`（非定数時間）で行われている。
- 本リポジトリは `client_secret` について `study-material/security-client-secret-handling.md` / `tasks/done/p0-client-secret-timing-safe-comparison.md` で「秘密値の比較はタイミング攻撃を防ぐため定数時間で行う」方針を明文化し、`timingSafeEqual` を実装・適用済み。CSRF トークンは「秘密値の比較なのに非定数時間で残っている最後の 1 箇所」であり、プロジェクトの自己方針からの逸脱。
- 短命なランダム CSRF トークンへのタイミング攻撃は現実的脅威としては小さいため、これは Basic OP 必須要件ではなく**ハードニング / 一貫性**の論点であることを確認したい。

## 3. 関連する仕様・基準

共通の「秘密値比較を定数時間で行う理由」の一般論は `study-material/security-client-secret-handling.md` を参照し繰り返さない。本トピック固有の差分に絞る。

- **RFC 9700 (OAuth 2.0 Security Best Current Practice) §2.1**: CSRF 対策を要求。CSRF トークンは推測・漏洩されてはならない one-time／per-session の値であり、その比較にサイドチャネル（タイミング）を残さないことは秘密値一般の扱いに準じる。
- **一般的なセキュア実装原則（OWASP 等）**: シークレット/トークンの等価判定は定数時間比較を用いる。文字列長や先頭一致バイト数がタイミングに漏れると、理論上はオラクルとして悪用され得る。
- 本トピックの位置づけ: `client_secret` に適用済みの方針（`tasks/done/p0-client-secret-timing-safe-comparison.md`）を、同じく秘密値である CSRF トークン比較へ**対称に適用する**という差分。新しい脅威モデルの導入ではない。

## 4. 参照資料

- RFC 9700 (OAuth 2.0 Security BCP) §2.1 CSRF — https://datatracker.ietf.org/doc/html/rfc9700
- 本リポジトリ内の先例: `packages/core/src/crypto-utils.ts`（`timingSafeEqual` 実装、テスト `crypto-utils.test.ts:909+`）、`packages/core/src/client-auth.ts:194-195`（`client_secret` への適用）
- 検討経緯（秘密値比較の方針）: `study-material/security-client-secret-handling.md` / `tasks/done/p0-client-secret-timing-safe-comparison.md`

## 5. 現在の実装確認

`packages/core/src/auth-transaction.ts` `validateCsrfToken`:

```ts
export function validateCsrfToken(
  transaction: AuthTransaction,
  csrfToken: string
): void {
  if (!csrfToken || csrfToken !== transaction.csrfToken) {   // L294: 非定数時間比較
    throw new AuthTransactionError(
      AuthTransactionErrorCode.InvalidCsrfToken,
      'Invalid CSRF token.'
    );
  }
}
```

- 比較は `!==`。空値ガード（`!csrfToken`）と等価判定を同一式で行っている。
- 対照的に `client-auth.ts:195` では `await timingSafeEqual(client.clientSecret ?? '', clientSecret)` を用いており、秘密値比較の作法がモジュール間で不揃い。
- `timingSafeEqual` は既に core に存在するため、追加依存は不要（外部依存禁止方針にも抵触しない）。

## 6. 現在の実装との差分

満たしていること:
- CSRF トークン自体は per-transaction のランダム値として発行・保存されており、CSRF 防御の骨格は成立している（HTML エスケープ整合は `study-material/done/generated-login-consent-html-escaping-consistency.md`、ストア書き込み保護は `study-material/resolver-and-store-contract.md` で別途扱い）。

改善した方がよいこと:
- 🟢 **比較が非定数時間**。`client_secret` と同じ秘密値クラスなのに作法が異なる。脅威度は低いが、プロジェクトの明文化された方針との一貫性が崩れている。

Basic OP として確認すべきこと:
- Basic OP 認定要件に CSRF トークン比較の定数時間性は含まれない。よって**認定の可否には影響しない**。純粋にセキュリティ姿勢の一貫性の問題。

## 7. 改善・追加を検討する理由

- **なぜ価値があるか**: 「秘密値の比較は定数時間」という単一方針をコードベース全体で貫くことで、レビュー時に「なぜここだけ `!==` なのか」という疑問と、将来の改変で緩い比較がコピーされるリスクを消せる。
- **Basic OP 必須か拡張か**: 拡張（ハードニング）。必須ではないが、セキュリティ最優先という本リポジトリの方針に合致。
- **導入しやすさ**: `timingSafeEqual` が既にあり、`validateCsrfToken` を非同期化するか、同期の定数時間比較を用意するかの選択だけ。局所的。
- **注意点（導入しにくさ）**: `timingSafeEqual` は `async`（`crypto.subtle` ベースの HMAC 比較の可能性）。`validateCsrfToken` を `async` 化すると呼び出し側（sample の login/consent ルート）のシグネチャ変更が波及する。長さが異なる入力でのタイミング漏れ（早期 return）を作らない実装にする必要がある。
- **実装しない場合のリスク**: 実害は小さいが、監査上「秘密値比較を定数時間化済み」という主張に例外が残る。

## 8. 実装方針の候補

最終判断は人間が行う前提で整理する。

- 方針A（`timingSafeEqual` を流用・`async` 化）: `validateCsrfToken` を `async` にし、`await timingSafeEqual(transaction.csrfToken, csrfToken)` を使う。既存ヘルパー再利用で最小実装だが、呼び出し側の `await` 対応が必要。
- 方針B（同期の定数時間比較を追加）: 長さに依存しない同期比較関数を `crypto-utils` に追加し `validateCsrfToken` を同期のまま保つ。シグネチャ変更を避けられるが関数が増える。
- 方針C（現状維持 + 文書化）: 「CSRF トークンは短命ランダムでありタイミング攻撃の実効性は極低のため定数時間化しない」と明記して割り切る。実装コスト 0 だが方針の非対称は残置。

`validateCsrfToken` を `async` 化した場合の sample 側（hono/express/fastify/nextjs の login/consent ルート）の波及範囲確認は実装前に行う。

## 9. タスク案

- [ ] `validateCsrfToken` の呼び出し箇所（core + 各 sample のルート）を洗い出し、`async` 化の波及範囲を確認する
- [ ] 方針（A/B/C）を決定する
- [ ] （A/B 採用時・TDD）`auth-transaction.test.ts` に「正しい CSRF トークンで通過」「不一致で `InvalidCsrfToken`」「空値で拒否」のテストが定数時間比較でも維持されることを確認するテストを追加
- [ ] `validateCsrfToken` の比較を定数時間化する（早期 return によるタイミング漏れを作らない）
- [ ] `pnpm --filter @maronn-openid-connect/core test` と sample のテストがパスすること

## 10. 追記: CSRF トークンの束縛先（2026-08-04）

本ファイルは CSRF トークンの**比較方法**（定数時間か）だけを扱っており、CSRF トークンが
**何に束縛されているか**は扱っていなかった。OWASP CSRF Prevention Cheat Sheet が求めるのは
「CSRF トークンをユーザーセッションに束縛し、リクエストパラメータのみから再取得できる状態に
しないこと」であり、比較方法とは独立した論点である。

`tasks/done/p1-auth-transaction-user-agent-binding.md` で、この束縛側を **opt-in 機能**
（`--enable transaction-binding`）として実装した。既定を OFF にしたのは、この束縛を要求する
OIDC Core / OAuth 2.1 の条文が無く、既定生成物は「仕様そのもの」に保ちたいためと、有効時は
Cookie の持ち回りが必要になり curl で OP を手で触る検証フローが止まるため。

- 束縛先は「認可トランザクションを開始した User-Agent」。認可エンドポイントが CSPRNG 由来の
  秘密値を HttpOnly Cookie（`oidc_txn_<transaction_id>`）で配り、トランザクションには
  SHA-256 ハッシュ（`AuthTransaction.bindingHash`）だけを保存する。
- `validateTransactionBinding()` を `validateCsrfToken()` の**直前**、および CSRF トークンを
  HTML に埋めて返す GET `/login`・GET `/consent` の**描画前**に呼ぶ。
- 比較には本ファイルと同じ `timingSafeEqual` を使う。すなわち「秘密値の比較は定数時間」という
  方針は、CSRF トークン本体だけでなく束縛値にも適用済みである。

したがって、CSRF トークンの安全性が `transaction_id`（URL を流れる値）の秘匿性だけに依存する
状態は、**`transaction-binding` を有効化した構成でのみ**解消されている。既定構成では依然として
`transaction_id` の秘匿性に依存しており、これは「検証用ツールであって本番 OP ではない」という
本リポジトリの位置づけを踏まえた意図的なトレードオフである。本ファイルの方針 A/B/C の議論
そのものは変わらない。

## 関連トピック

- `study-material/done/auth-transaction-user-agent-binding.md` / `tasks/done/p1-auth-transaction-user-agent-binding.md` — CSRF トークンの束縛先（User-Agent への束縛）を扱う。本ファイルは比較方法、あちらは束縛先という分担。
- `study-material/security-client-secret-handling.md` / `tasks/done/p0-client-secret-timing-safe-comparison.md` — 秘密値比較を定数時間化する方針の一次記録。本ファイルはその方針を CSRF トークンへ拡張する差分のみを扱う。
- `study-material/rate-limiting-and-brute-force.md` — タイミング系の議論を `client_secret` に限定している（本ファイルはその限定を CSRF に広げる補完）。
