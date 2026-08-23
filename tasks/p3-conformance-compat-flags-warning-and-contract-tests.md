# [P3] Conformance 互換フラグの有効化を可視化し、緩和範囲を契約テストで固定する

## ステータス

🟢 Low / 未着手

## 背景

`allowNonPkceAuthorizationCodeFlow` と `allowUnsignedRequestObject` は、
OIDF Conformance Suite との互換のために仕様上の要件を意図的に緩めるフラグである。

- `allowNonPkceAuthorizationCodeFlow`: OAuth 2.1 §4.1.1 / §7.5 が必須とする PKCE を、
  **confidential client が完全に省略した場合のみ**許容する
- `allowUnsignedRequestObject`: OIDC Core 1.0 §6.1 の署名付き Request Object 要件を緩め、
  `alg=none` を受理する（署名部が空であることは検証する）

どちらも既定は `false` で、緩和範囲も core 側で最小に絞られている（secure by default は満たしている）。
問題は**有効化された状態が実行時にどこにも可視化されない**ことにある。

- 起動時ログに何も出ない
- `/health` は `{ status: 'ok' }` のみ
- `allowNonPkceAuthorizationCodeFlow` は Discovery にも出ない
  （`allowUnsignedRequestObject` は `request_object_signing_alg_values_supported` に `"none"` が出るため間接的に分かる）

環境変数（`OIDC_ALLOW_NON_PKCE_AUTHORIZATION_CODE_FLOW=1` /
`OIDC_ALLOW_UNSIGNED_REQUEST_OBJECT=1`）は Workers / Fly / Vercel いずれもデプロイ設定として残り続けるため、
Conformance 検証後に消し忘れても誰も気づけない。

また、「フラグ ON でも依然として拒否されるもの」（public client の PKCE 省略、`plain`、
片方だけの PKCE パラメータ、署名部が非空の `alg=none`）を固定する回帰テストが無いため、
将来のリファクタで緩和範囲が広がっても検知できない。

検討詳細は `study-material/done/conformance-compatibility-flags-safety-guard.md` を参照。

> 関連（重複記載しない）:
> - PKCE 必須化と `code_challenge` 形式検証: `study-material/done/pkce-code-challenge-format-validation.md`
> - `alg=none` 防御とアルゴリズムポリシー: `study-material/jws-algorithm-policy-and-alg-none-defense.md`
> - Discovery と実装の整合性ガード: `study-material/done/discovery-metadata-basic-op-self-consistency-guard.md`
> - Conformance 実行手順: `study-material/basic-op-conformance-verification-plan.md`
>
> 本タスクは**互換フラグという運用状態の可視化と、緩和範囲の固定**に限定する。
> 各フラグが緩める仕様要件そのものの議論は上記既存ファイルの担当。
> `/health` に構成サマリを出すか（未認証の第三者に情報を与える）は
> study-material 側で方針が分かれているため、本タスクのスコープ外とする。

## 対象ファイル

- `samples/hono-cloudflare/src/app.ts`
- `samples/express-flyio/src/app.ts`
- `samples/fastify-flyio/src/app.ts`
- `samples/nextjs-vercel/src/app/_oidc-provider/runtime.ts`
- `packages/cli/src/frameworks/hono/templates.ts`（`conformance.test.ts` を生成する箇所）
- 再生成される生成物: `samples/*/src/oidc-provider/conformance.test.ts`
- `samples/*/README.md`（環境変数の説明の棚卸し）
- `study-material/basic-op-conformance-verification-plan.md`（実行後にフラグを戻す手順）

## 仕様参照

- **OAuth 2.1 §4.1.1 / §7.5**: authorization code flow を使うクライアントは PKCE を必ず使う。
  `S256` のサポートは必須。
- **RFC 9700 §2.1.1**: 認可コード横取り（authorization code injection）への対策として
  PKCE または nonce を要求する。
- **OIDC Core 1.0 §6.1**: Request Object は署名（JWS）によりリクエストパラメータの完全性を保護する。
- **RFC 8725 §3.1 / §3.2**: アルゴリズム検証を必ず行い、`none` を無条件に受け入れない。
- **RFC 7515 §6**: `none` アルゴリズムは空の署名を使う（本リポジトリは検証済み）。

## 現状の実装

```ts
// samples/hono-cloudflare/src/app.ts:21-22, 50-52（他サンプルも同型）
allowNonPkceAuthorizationCodeFlow: bindings.OIDC_ALLOW_NON_PKCE_AUTHORIZATION_CODE_FLOW === '1',
allowUnsignedRequestObject: bindings.OIDC_ALLOW_UNSIGNED_REQUEST_OBJECT === '1',
```

```ts
// packages/core/src/authorization-request.ts の validateAuthorizationCodePkce
const pkceOmitted = codeChallenge === undefined && codeChallengeMethod === undefined;
if (pkceOmitted && options.allowNonPkceAuthorizationCodeFlow === true
    && client.clientType === 'confidential') {
  return {};                      // 完全省略かつ confidential のときだけ許容
}
return validateCodeChallenge(codeChallenge, codeChallengeMethod, redirectUri, state);
```

緩和範囲は最小に絞られているが、**その事実がテストで固定されていない**。
また、フラグが有効であることを実行時に知る手段が無い。

## 修正方針

- [ ] 各サンプルの起動処理で、いずれかの互換フラグが `true` のときに警告を出す。
      警告文には「どのフラグが有効か」「何を緩めているか」「本番構成では無効にすること」を含める

  ```ts
  // 例（各サンプルの app.ts / runtime.ts）
  if (config.allowNonPkceAuthorizationCodeFlow || config.allowUnsignedRequestObject) {
    console.warn(
      '[maronn-openid-connect] OIDF conformance compatibility mode is ENABLED. ' +
      'Security requirements are relaxed: ' +
      (config.allowNonPkceAuthorizationCodeFlow
        ? 'PKCE may be omitted by confidential clients (OAuth 2.1 4.1.1/7.5); ' : '') +
      (config.allowUnsignedRequestObject
        ? 'unsigned (alg=none) Request Objects are accepted (OIDC Core 6.1); ' : '') +
      'unset OIDC_ALLOW_* environment variables for a spec-strict deployment.',
    );
  }
  ```

- [ ] `packages/cli` の `conformance.test.ts` 生成コードに、
      **「互換フラグ ON でも依然として拒否されるもの」**の契約テスト群を追加する
- [ ] `samples/*/README.md` に `OIDC_ALLOW_NON_PKCE_AUTHORIZATION_CODE_FLOW` /
      `OIDC_ALLOW_UNSIGNED_REQUEST_OBJECT` の説明（用途・既定値・戻し方）があるか棚卸しし、
      無ければ追記する
- [ ] `study-material/basic-op-conformance-verification-plan.md` に、
      実行後にフラグを戻す手順と、その確認方法
      （Discovery の `request_object_signing_alg_values_supported` に `"none"` が無いこと）を追加する
- [ ] 生成コード（`samples/*/src/oidc-provider/**`）は直接編集せず、
      必ず `packages/cli` のテンプレートを修正して再生成する
      （`samples/*/src/app.ts` / `runtime.ts` は CLI 生成対象外なので直接編集してよい）

## テスト要件

`allowNonPkceAuthorizationCodeFlow = true` の構成で:

- [ ] public client が PKCE を完全に省略した認可リクエスト → `invalid_request` で拒否されること
- [ ] `code_challenge` のみ指定（`code_challenge_method` 欠落）→ `invalid_request` で拒否されること
- [ ] `code_challenge_method` のみ指定（`code_challenge` 欠落）→ `invalid_request` で拒否されること
- [ ] `code_challenge_method=plain` → `invalid_request` で拒否されること
- [ ] confidential client が PKCE を完全に省略 → 認可コードが発行されること（互換モードの意図した挙動）

`allowUnsignedRequestObject = true` の構成で:

- [ ] `alg=none` かつ署名部が非空の Request Object → 拒否されること
- [ ] `alg=none` かつ署名部が空の Request Object → 受理されること（互換モードの意図した挙動）
- [ ] Discovery の `request_object_signing_alg_values_supported` に `"none"` が含まれること

既定構成（両フラグ `false`）で:

- [ ] confidential client の PKCE 省略が `invalid_request` で拒否されること
- [ ] `alg=none` の Request Object が `invalid_request` で拒否されること
- [ ] Discovery の `request_object_signing_alg_values_supported` が `["RS256"]` であること

その他:

- [ ] 互換フラグが有効なときに起動警告が出ること、無効なときは出ないこと

## 完了条件

- `pnpm --filter @maronn-openid-connect/cli test` / `pnpm run test:conformance` /
  `pnpm --filter "./packages/*" test` / `pnpm typecheck` がパスすること
- 生成物を再生成し、`samples/*/src/oidc-provider/conformance.test.ts` の差分が
  テンプレート修正に由来するものだけであること
- 互換フラグを有効にしてサンプルを起動したとき、ログに警告が出ることを手動で確認すること
- `study-material/basic-op-conformance-verification-plan.md` に
  「実行後にフラグを戻す」手順が反映されていること
