# Hono サンプル OP で OpenID Certification を取得する手順

`samples/hono-cloudflare` の CLI 生成 OpenID Provider を対象に、OpenID Foundation の **OpenID Certification**（Basic OP プロファイル）を実際に取得するまでの手順をまとめる。
ローカルのドライラン、公開デプロイ、公式 Conformance Suite での実行、手動レビュー、申請までを一続きの作業として扱う。

対象読者は、このリポジトリのメンテナである。
「Suite を走らせる仕組み」は `tests/conformance/` に実装済みなので、本書はその先、認定という成果物に到達するまでの段取りを扱う。

既存文書との役割分担は次のとおりで、重複する内容は各文書に委ねる。

- `tests/conformance/README.md`：ローカル実行コマンドと環境変数の一次情報
- `tests/conformance/manual-review-screenshots.md`：手動レビュー module のスクリーンショット提出手順
- `study-material/basic-op-requirement-traceability.md`：Basic OP 要件と実装の対応表
- `study-material/basic-op-conformance-verification-plan.md`：検証をいつ実施するかという戦略判断

## OpenID Certification の仕組み

**OpenID Certification** は、OpenID Foundation が運営する自己認証（self-certification）の制度である。
第三者監査を受けるのではなく、実装者が公式の Conformance Suite でテストを実行し、その結果と適合宣言を提出して認定を得る。
認定されると「OpenID Certified」マークを表示でき、認定実装の一覧に掲載される。

認定は **プロファイル単位** で行う。
OpenID Provider 側のプロファイルには Basic OP、Implicit OP、Hybrid OP、Config OP、Dynamic OP、Form Post OP、3rd Party-Init OP、および各種 Logout 系（Session OP、Front-Channel OP、Back-Channel OP）がある。

本リポジトリが対象にするのは **Basic OP** である。
Authorization Code Flow（`response_type=code`）だけを対象とする最小プロファイルで、根拠仕様は OpenID Connect Core 1.0 の §3.1（Authorization Code Flow）と §15.1（Mandatory to Implement Features for All OPs）にあたる。
Implicit と Hybrid を含まないので、`response_types_supported: ['code']` しか広告しないこの OP と範囲が一致する。

### 合格の判定基準

公式の OP テスト手順は、認定に進める条件を module の最終状態で定義している。

- 提出できる状態：`PASSED` / `REVIEW` / `WARNING` / `SKIPPED`
- 提出できない状態：`FAILED` / `INTERRUPTED`

ここが手順設計の要点になる。
OP の実装が仕様どおりでも、ブラウザ自動化が Suite の callback へ到達せずタイムアウトすると module は `FAILED` や `INTERRUPTED` で終わる。
実装の正しさと module の最終状態は別物なので、認定を目指す実行では「正しく動くこと」ではなく「`FAILED` と `INTERRUPTED` を 0 件にすること」を目標に組み立てる。

### 費用

OpenID Connect の自己認証は、1 デプロイメントあたりメンバーが 700 USD、非メンバーが 3,500 USD である。
1 回の支払いで、同一暦年内の複数プロファイルをカバーする。

オープンソース実装には **費用免除** の制度がある。
2021 年に承認された Open-Source Project Certification Policy に基づき、次の条件を満たす場合に個別審査で免除されうる。

- 通常の認定要件をすべて満たしていること
- 申請者が、認定対象のデプロイメントに責任を持つ立場であること（無関係な第三者による申請は不可）
- プロジェクトの主要メンテナが、そのプロジェクトの作業について雇用主から報酬を受けていないこと

免除は case by case の審査であり、資力があるプロジェクトには通常の費用を支払うよう求められている。
申請は `certification@oidf.org` へ問い合わせる。

金額と制度は変わりうるので、着手時点で公式のフィースケジュールを確認する。

## 取得までの全体像

作業は 5 つのフェーズに分かれる。
フェーズ 0 だけがローカルで完結し、フェーズ 1 以降は公開エンドポイントと OpenID Foundation のホスト環境を使う。

| フェーズ | 内容 | 場所 |
|---|---|---|
| 0 | セルフホスト Suite でドライランし、実装の不足を潰す | ローカル / CI |
| 1 | OP を公開 HTTPS へデプロイし、認定用の構成を整える | Cloudflare Workers |
| 2 | `certification.openid.net` で Basic OP プランを実行する | OIDF ホスト環境 |
| 3 | 手動レビュー module にスクリーンショットを提出する | OIDF ホスト環境 |
| 4 | 結果を publish し、支払いコードを取得して申請する | OIDF 提出フォーム |

フェーズ 0 は認定そのものには使えない。
セルフホストの Suite は実装確認には十分だが、認定申請に添付できるのは公式ホスト環境で実行した結果である。
それでもフェーズ 0 を先に通しておく価値は大きく、公開デプロイの前に実装側の失敗をすべて洗い出せる。

## Hono サンプルのどこが Basic OP 要件を満たしているか

認定作業に入る前に、対象実装の構造を押さえておく。

`samples/hono-cloudflare/src/app.ts` が唯一の手書きエントリポイントで、`applyOidc()` を呼んで OIDC の全経路を Hono アプリへ載せる。
`src/oidc-provider/` 配下は `packages/cli` の生成物なので、挙動を変える必要が出たら生成物ではなく `packages/cli` のテンプレートを修正する。

エンドポイントの割り当ては `src/oidc-provider/apply.ts` にある。

| パス | メソッド | 役割 |
|---|---|---|
| `/.well-known/openid-configuration` | GET | Discovery メタデータ |
| `/.well-known/jwks.json` | GET | 署名鍵の公開 |
| `/authorize` | GET / POST | 認可エンドポイント |
| `/token` | POST | トークンエンドポイント |
| `/userinfo` | GET / POST | UserInfo エンドポイント |
| `/login` | GET / POST | エンドユーザー認証画面 |
| `/consent` | GET / POST | 同意画面 |

Basic OP が検証する要件と、それを満たしている実装位置の対応は次のとおり。
パスはすべて `samples/hono-cloudflare/` からの相対である。

| 要件 | 実装位置 | 備考 |
|---|---|---|
| `response_type=code` のみ受理 | `src/oidc-provider/routes/authorize.ts`（`validateResponseType`） | Discovery も `['code']` を広告 |
| `response_type` 欠如の拒否 | 同上 | `invalid_request` |
| ID Token を RS256 で署名 | `src/app.ts`（`createEphemeralRs256KeyProvider`）、`src/oidc-provider/routes/token.ts` | `apply.ts` の `validateSigningKeySet(idTokenSigningKeys, true)` が RS256 鍵の存在を強制 |
| `kid` ヘッダと JWKS の整合 | `src/oidc-provider/routes/jwks.ts` | `kid` 重複排除つきで登録鍵をまとめて公開 |
| `nonce` の ID Token 反映 | `src/oidc-provider/routes/token.ts` | 認可リクエストに `nonce` が無くても code flow は成立する |
| `state` の返却 | `src/oidc-provider/routes/authorize.ts`（`buildSuccessRedirect`） | RFC 9207 の `iss` も併せて付与 |
| `scope`（profile / email / address / phone） | `src/oidc-provider/routes/userinfo.ts`（`filterClaimsByScope`）、`src/oidc-provider/store.ts` の `testuser` fixture | fixture に標準クレームが揃っていないと Suite は warning にする |
| `claims` パラメータ | `authorize.ts`（`parseClaimsRequestParameter`）、`userinfo.ts`（`applyRequestedClaims`） | Discovery で `claims_parameter_supported: true` |
| `prompt=none` | `authorize.ts` の prompt=none 分岐 | セッション無しは `login_required`、同意無しは `consent_required` |
| `prompt=login` | `authorize.ts` と `routes/login.ts` | 既存セッションを破棄して再認証させる |
| `display` / `ui_locales` / `claims_locales` | `authorize.ts`（`validateDisplayParameter` ほか） | §15.1 の最低要件はエラーにしないこと |
| `max_age` と `auth_time` | `authorize.ts`（`resolveMaxAge` / `requiresReauthentication`）、`token.ts` | クライアント登録の `defaultMaxAge` もフォールバックとして効く |
| `acr_values` | `src/app.ts` の `sampleAcrResolver` | 要求された最優先値を `acr` として返す。これが無いと SHOULD 未対応の warning になる |
| `id_token_hint` | `authorize.ts`（`validateIdTokenHint`） | 署名、`iss`、`aud`、`exp`、`iat` を全 prompt 経路で検証する |
| `redirect_uri` の厳密一致 | `authorize.ts`（`resolveAuthorizationRedirectUri` / `validateRegisteredRedirectUris`） | 未登録の URI と fragment 付きの URI はリダイレクトせず HTML エラーページ |
| クライアント認証（basic / post） | `src/oidc-provider/routes/token.ts` | Discovery で両方を広告 |
| 認可コード再利用の検知と失効 | `token.ts`、`src/oidc-provider/resolvers.ts`（`revokeTokensByGrantId`） | 再利用時に同一 grant のトークンを失効させる |
| Request Object（`request` by value） | `authorize.ts`（`resolveRequestObjectParams`） | クライアント登録 JWKS で署名検証する |
| トークンエラーの `Cache-Control: no-store` | `token.ts` | RFC 6749 §5.2 |
| UserInfo の Bearer チャレンジ | `userinfo.ts` | RFC 6750 §3 |

これらの契約は `src/oidc-provider/conformance.test.ts` が Hono アプリを直接叩いて固定している。
Suite を回す前に `pnpm --filter @maronn-openid-connect/sample-hono-cloudflare test` を通しておくと、生成物の配線が壊れたまま Docker を起動する無駄を避けられる。

## フェーズ 0：ローカルでドライランする

リポジトリルートで次を実行する。

```bash
pnpm run conformance:basic-op
```

このコマンドは `tests/conformance/scripts/run-basic-op.sh` を通じて次を順に行う。

1. `@maronn-openid-connect/cli` と対象サンプルをビルドする
2. `tests/conformance/scripts/create-basic-op-config.mjs` で Suite 用設定と OP 用クライアント定義を生成する
3. OP を HTTPS 終端するための自己署名証明書を作る
4. Docker Compose で mongodb、Conformance Suite 本体、nginx、OP、OP の TLS プロキシ、runner を起動する
5. runner コンテナ内で公式の `run-test-plan.py` を実行する
6. 結果 ZIP と Compose のログを `tests/conformance/results/` へ出力する

実行するテストプランは次で固定されている。

```text
oidcc-basic-certification-test-plan[server_metadata=discovery][client_registration=static_client]
```

`server_metadata=discovery` は OP の `/.well-known/openid-configuration` からエンドポイントを発見する variant、`client_registration=static_client` は動的登録を使わず Suite 側にクライアント設定を渡す variant である。
この OP は Dynamic Client Registration を実装していないので、後者は選択の余地がない。

対象サンプルは `CONFORMANCE_SAMPLE_APP` で切り替えられ、既定は `hono-cloudflare` である。

### 直近の結果

CI（GitHub Actions の `OpenID Conformance` workflow）で `hono-cloudflare` に対して実行した結果は、35 module のうち次の内訳になっている。

| 状態 | 数 | 内容 |
|---|---|---|
| PASSED | 32 | 主要フロー全般、`acr_values`、Request Object 2 件 |
| WARNING | 0 | |
| SKIPPED | 0 | |
| FAILED | 1 | `oidcc-ensure-registered-redirect-uri` |
| INTERRUPTED | 2 | `oidcc-prompt-login` / `oidcc-max-age-1` |

OP 実装ロジックに由来する failure は 0 件で、残る 3 module はいずれもスクリーンショット提出を待つ手動レビュー対象である。
それでも `FAILED` と `INTERRUPTED` は認定に進めない状態なので、この結果のままでは申請できない。
3 module を `REVIEW` へ落とす方法はフェーズ 3 で扱う。

### 結果の読み方

`tests/conformance/results/*.zip` が Suite のエクスポートである。
module ごとのログに `result` フィールドがあり、`FAILED` の原因が OP の応答（`state` / `nonce` の不一致、署名不正、必須クレーム欠落など）なら実装の問題、`Web Runner Exception: Timed out waiting: submission_complete` ならブラウザ自動化が callback へ到達しなかっただけで OP の問題ではない。
この切り分けを最初に行うと、直すべき対象を間違えずに済む。

## 認定のために緩める 2 つの互換フラグ

Basic OP プランを通すには、通常運転では有効にしていない 2 つのフラグを OP に渡す必要がある。
どちらも既定は `false` で、`pnpm run conformance:basic-op` は conformance 実行時にだけ `1` を渡している。

**`OIDC_ALLOW_NON_PKCE_AUTHORIZATION_CODE_FLOW`**：OAuth 2.1 §4.1.1 / §7.5 が必須とする PKCE を、confidential client が完全に省略した場合にかぎり許容する。
Basic OP プランには PKCE を使わない authorization code flow の module が多数含まれるので、これが無いと大半が失敗する。
緩和範囲は core 側で絞られており、public client の PKCE 省略、`plain` 方式、`code_challenge` と `code_challenge_method` が片方だけのリクエストは引き続き拒否する。

**`OIDC_ALLOW_UNSIGNED_REQUEST_OBJECT`**：OIDC Core 1.0 §6.1 の署名付き Request Object 要件を緩め、`alg=none` の Request Object を受理する。
同時に Discovery の `request_object_signing_alg_values_supported` へ `"none"` が加わる。
Suite は OP が `none` を広告していない場合に Request Object 系 module を skip するので、有効化すると skip されていた 2 module が実際に走って pass する。

どちらも認定対象の挙動を仕様から外す方向の設定である。
認定用デプロイは検証専用として扱い、その環境を PoC やデモの入口として使い回さない。
また、環境変数は Workers の設定として残り続けるので、認定作業が終わったら明示的に外す（フェーズ 4 の後始末を参照）。

## フェーズ 1：公開 HTTPS へデプロイする

公式 Conformance Suite は OpenID Foundation のホスト環境から OP へ HTTP アクセスするので、インターネットから到達できる HTTPS エンドポイントが要る。
`samples/hono-cloudflare` は Cloudflare Workers へのガイド付きデプロイを持っているので、これを使う。

### 署名鍵を先に固定する

デプロイ前に必ず片付けておく前提がひとつある。

`src/app.ts` の `createEphemeralRs256KeyProvider()` は、モジュール評価時にその場で RSA 鍵ペアを生成する。
`kid` は固定文字列なのに鍵素材はインスタンスごとにランダムなので、Cloudflare Workers の別アイソレートが別の鍵で署名する。
RP が JWKS を取得したアイソレートと ID Token を発行したアイソレートが違うと、`kid` は一致するのに署名検証が失敗する。
この失敗はルーティングと負荷に依存して間欠的に現れるため、Suite 上では原因不明の署名検証エラーとして見える。

ローカル起動や `conformance.test.ts` は単一プロセスで完結するので、この問題はフェーズ 0 では顕在化しない。
公開デプロイに対して Suite を回す段になって初めて壊れる。

認定作業のあいだは、鍵を Workers の secret から読み込む形に差し替える。
まず 2048 bit の RSA 秘密鍵を JWK として作る。

```bash
node -e "
const { generateKeyPairSync } = require('node:crypto');
const { privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
process.stdout.write(JSON.stringify(privateKey.export({ format: 'jwk' })));
" > /tmp/oidc-signing-key.jwk
```

`samples/hono-cloudflare/src/app.ts` の鍵プロバイダを次に置き換える。

```typescript
function createStaticRs256KeyProvider(
  privateJwkJson: string,
  keyId: string,
): SigningKeyProvider {
  const keyPromise = importSigningKey(privateJwkJson, keyId);
  return {
    async getSigningKey(): Promise<SigningKey> {
      return keyPromise;
    },
    async getSigningKeys(): Promise<SigningKey[]> {
      return [await keyPromise];
    },
  };
}

async function importSigningKey(privateJwkJson: string, keyId: string): Promise<SigningKey> {
  const jwk = JSON.parse(privateJwkJson) as JsonWebKey;
  const privateKey = await crypto.subtle.importKey(
    'jwk',
    jwk,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const publicJwk: JsonWebKey & { alg?: string; use?: string; kid?: string } = {
    kty: jwk.kty,
    n: jwk.n,
    e: jwk.e,
    alg: 'RS256',
    use: 'sig',
    kid: keyId,
  };
  return { privateKey, publicJwk, keyId };
}
```

`applyOidc` へ渡す側を、`Bindings` に足した `OIDC_SIGNING_KEY_JWK` から読む形にする。

```typescript
signingKeyProvider: createCachedSigningKeyProvider(
  createStaticRs256KeyProvider(
    bindings.OIDC_SIGNING_KEY_JWK ?? '',
    bindings.OIDC_SIGNING_KEY_ID ?? 'hono-cloudflare-rs256-key',
  ),
  60_000,
),
```

鍵の永続化は Basic OP の仕様要件ではない。
実デプロイに対して検証を成立させるための前提条件であり、この扱いは `tasks/p1-signing-key-persistence-in-samples.md` で恒久対応として追跡している。

### Suite 用のクライアント定義と設定を生成する

公式 Suite は 3 つのクライアントを要求する。
`client_secret_basic` のクライアント 2 つ（うち 1 つは認可コードの束縛検証用）と、`client_secret_post` のクライアント 1 つである。
redirect URI はすべて `https://www.certification.openid.net/test/a/<ALIAS>/callback` の形になる。

これらを手で書き起こす必要はない。
`tests/conformance/scripts/create-basic-op-config.mjs` は、Suite 側へ貼り付ける設定 JSON と OP 側へ渡すクライアント定義を、同じ鍵ペアで整合させたまま同時に生成する。
公式ホスト環境向けの値を環境変数で渡せばよい。

```bash
CONFORMANCE_ALIAS=maronn-openid-connect \
CONFORMANCE_OP_ISSUER=https://<worker-name>.<subdomain>.workers.dev \
CONFORMANCE_SUITE_BASE_URL=https://www.certification.openid.net \
CONFORMANCE_OUT_DIR="$(pwd)/tests/conformance/.generated-hosted" \
pnpm --filter @maronn-openid-connect/conformance generate
```

`ALIAS` は Suite 上で一意でなければならず、redirect URI にそのまま埋め込まれる。
出力は次の 2 つで、前者を Suite へ、後者を OP へ渡す。

- `basic-op-config.json`：Suite のテストプラン設定
- `oidc-clients.json`：OP が信頼する静的クライアント定義

生成される設定には Request Object 検証用の RS256 鍵ペアが含まれており、公開鍵側が OP のクライアント登録に、秘密鍵側が Suite のクライアント設定に入る。
両者は同じ鍵ペアでなければ Request Object の module が通らないので、片方だけを手で書き換えない。

### デプロイする

初回は issuer の確定のために 2 回デプロイが走る。

```bash
pnpm deploy:hono-cloudflare
```

Worker は自分の公開 URL を初回デプロイ前に知りようがないので、スクリプトは 1 度デプロイして wrangler が報告した workers.dev の URL を読み、それを `ISSUER` として固定してもう一度デプロイする。
確定した issuer は `samples/hono-cloudflare/.deploy/issuer` に保存され、2 回目以降は 1 回で完了する。
カスタムドメインを使う場合は `--issuer` で明示する。

Worker が存在したら、クライアント定義と署名鍵を secret として登録する。

```bash
cd samples/hono-cloudflare
tr -d '\n' < ../../tests/conformance/.generated-hosted/oidc-clients.json \
  | pnpm exec wrangler secret put OIDC_CLIENTS_JSON --config wrangler.deploy.jsonc
pnpm exec wrangler secret put OIDC_SIGNING_KEY_JWK --config wrangler.deploy.jsonc \
  < /tmp/oidc-signing-key.jwk
```

最後に互換フラグを付けてデプロイし直す。

```bash
pnpm exec wrangler deploy --config wrangler.deploy.jsonc \
  --var OIDC_ALLOW_NON_PKCE_AUTHORIZATION_CODE_FLOW:1 \
  --var OIDC_ALLOW_UNSIGNED_REQUEST_OBJECT:1
```

`wrangler.deploy.jsonc` は `pnpm deploy:hono-cloudflare` が毎回生成し直すファイルである。
`--var` で渡したフラグは設定ファイルには残らないので、あとからガイド付きデプロイをもう一度実行するとフラグが落ちる。
認定作業中に再デプロイするときは、この `--var` 付きコマンドを使う。

### デプロイの確認

Suite を触る前に、公開エンドポイントが期待どおりかを確認する。

```bash
ISSUER=https://<worker-name>.<subdomain>.workers.dev
curl -s "$ISSUER/.well-known/openid-configuration" | jq '{
  issuer,
  response_types_supported,
  request_object_signing_alg_values_supported,
  scopes_supported,
  token_endpoint_auth_methods_supported
}'
curl -s "$ISSUER/.well-known/jwks.json" | jq '.keys[] | {kid, alg, kty}'
```

確認すべき点は 4 つある。

- `issuer` が実際の公開 URL と一致すること（不一致は Suite が最初に落とす）
- `request_object_signing_alg_values_supported` に `"none"` が含まれること（互換フラグが効いている証拠）
- JWKS が RS256 の鍵を返し、複数回叩いても同じ `kid` と同じ `n` を返すこと（鍵の固定が効いている証拠）
- `/authorize` をブラウザで開いてログイン画面が表示されること

エンドユーザーは `store.ts` の fixture にある `testuser` / `password` を使う。
このアカウントは Suite の browser automation の既定値と一致している。

## フェーズ 2：公式 Suite で Basic OP プランを実行する

`https://www.certification.openid.net/` を開き、Google または GitLab アカウントで認証する。

新しいテストプランを作成し、「Test an OpenID Provider」から Basic OP のプランを選ぶ。
variant はローカルと同じく `server_metadata=discovery` と `client_registration=static_client` を選択する。

設定はフォームから入力できるが、フェーズ 1 で生成した `basic-op-config.json` を JSON として貼り付けるのが確実である。
`alias`、`server.discoveryUrl`、`client` / `client2` / `client_secret_post` の 3 クライアント、Request Object 用の JWKS と `request_object_signing_alg` が、OP 側の登録内容と一致した状態で入る。

### browser automation を外す

貼り付ける前に、設定から `browser` ブロックを削除する。

ローカルのドライランでは、`browser` ブロックが login と consent の入力を自動化し、最後に Suite の callback ページが表示されるのを待つ。
ところが Basic OP には、そもそも callback へ到達しない module がある。
未登録 `redirect_uri` のテストでは OP がリダイレクトせずエラーページを出すのが正しい挙動であり、`prompt=login` と `max_age=1` のテストでは 2 回目のログイン画面のスクリーンショット提出待ちで止まる。
その結果、実装が正しくてもブラウザ自動化のタイムアウトで module が `FAILED` や `INTERRUPTED` になる。
これがフェーズ 0 の結果に残っていた 3 件の正体である。

公式手順が想定しているのは、各テストの青いボックスに出る指示に従って人間がブラウザを操作する進め方である。
`browser` ブロックを外すと WebRunner が動かないので、callback 待ちのタイムアウトそのものが起こらない。
module は「操作待ち」ないし「レビュー待ち」で止まり、スクリーンショットを提出すれば完了できる状態に落ちる。
`REVIEW` は認定に提出できる状態なので、フェーズ 0 で詰まっていた 3 件はここで解ける。

自動化の便利さより、最終状態が認定条件を満たすことを優先する。
それでも `FAILED` で止まる module があれば、原因は OP 側にあるので実装を直す。

### 実行する

module を順に実行する。
提示されたリンクを新しいタブで開き、`testuser` / `password` でログインし、同意画面で Approve を押すと、Suite の callback に戻って module が完了する。

途中で失敗した module があれば、Suite のログ詳細を開いて原因を確認する。
OP の応答が原因なら実装を直し、`packages/cli` のテンプレート側を修正してサンプルを再生成し、再デプロイしてからその module だけ再実行する。

すべての module が `PASSED` / `REVIEW` / `WARNING` / `SKIPPED` のいずれかになるまで繰り返す。

## フェーズ 3：手動レビュー module にスクリーンショットを提出する

`REVIEW` で止まっている module は、Suite が視覚的な証跡を待っている。
対象と、撮るべき画面は次の 3 つである。

| module | Suite が求める画面 | OP が表示するもの |
|---|---|---|
| `oidcc-ensure-registered-redirect-uri` | 未登録 `redirect_uri` に対するエラーページ | HTTP 400 / `text/html` の `<h1>Error</h1>` に OAuth エラーコードを表示 |
| `oidcc-prompt-login` | 2 回目のログイン画面 | `prompt=login` で再認証を強制した `<h1>Login</h1>` のフォーム |
| `oidcc-max-age-1` | 2 回目のログイン画面 | `max_age=1` の経過で再認証を強制した同じフォーム |

いずれも OP の挙動そのものは正しい。
未登録 `redirect_uri` へリダイレクトすればオープンリダイレクトになるので、リダイレクトせずエラーページを出すのが仕様どおりの応答である。
`prompt=login` と `max_age=1` は、2 回目の認可とトークン交換まで自動で成功したうえで、「確かにログイン画面が再表示された」ことの証跡を求められている。

手順は次のとおり。

1. 対象 module のログ詳細（`log-detail.html?log=<id>`）を開く
2. REVIEW ステップに記録された URL を新しいタブで開き、該当画面を表示させる
3. URL バーと本文が入るようにスクリーンショットを撮る
4. ログ詳細画面のアップロード欄（`Upload an image`）へ画像を上げ、コメントを添えて提出する

提出すると module は手動レビュー完了として扱われる。

ローカルでこの手順を練習したい場合は、サービスを残したまま実行する。

```bash
CONFORMANCE_KEEP_SERVICES=1 pnpm run conformance:basic-op
```

runner 終了後も Suite の Web UI（既定 `https://localhost:8443/`）が残るので、同じ操作を試せる。
確認が済んだら `docker compose -f tests/conformance/docker-compose.yml down -v --remove-orphans` で停止する。

画面ごとの詳細は `tests/conformance/manual-review-screenshots.md` にある。

## フェーズ 4：認定を申請する

提出は 3 段階に分かれる。

### 結果を publish する

テストプランの画面から **Publish for certification** を押すと、テストログ一式を含む ZIP が得られる。
複数プロファイルを同時に認定する場合はプロファイルごとに ZIP を作る。

この ZIP が申請の証拠になるので、リポジトリの記録としても保管する。
実行日、対象コミット、対象サンプル、issuer、module ごとの結果を添えておくと、次回の再認定で差分を追える。

### 支払いコードを取得する

`https://openid.net/foundation/members/certifications/new` で次を入力する。

- Entity Name（認定を受ける主体の名称）
- Deployment Name と Version
- Implementer's Email

PayPal で支払うとコードが即時に発行され、請求書を選ぶと 2 日以内に発行される。
オープンソースの費用免除を申請する場合は、この段階の前に `certification@oidf.org` へ問い合わせる。

### 提出フォームを送る

`https://submissions.openid.net/` のフォームに次を入力する。

- 連絡先メールアドレスと Entity 情報
- 支払いコード
- Declaration of Conformance に署名する担当者の情報
- 権限を持つ連絡先の情報
- エクスポートした結果 ZIP

送信すると、署名担当者に DocuSign のメールが届く。
Declaration of Conformance に署名すると申請が処理待ちの列に入り、以降の連絡は登録した連絡先メールに届く。

認定されると、OpenID Foundation の認定実装一覧に掲載され、「OpenID Certified」マークを使えるようになる。

## 認定取得後の後始末

認定作業のために入れた設定は、そのままにしない。

**互換フラグを外す。**
`OIDC_ALLOW_NON_PKCE_AUTHORIZATION_CODE_FLOW` と `OIDC_ALLOW_UNSIGNED_REQUEST_OBJECT` は、有効になっていても起動ログにも `/health` にも現れない。
`OIDC_ALLOW_NON_PKCE_AUTHORIZATION_CODE_FLOW` は Discovery にも出ないので、消し忘れても誰も気づけない。
認定用の Worker を残すなら `--var` 無しで再デプロイし、残さないなら Worker ごと削除する。

```bash
cd samples/hono-cloudflare
pnpm exec wrangler delete --config wrangler.deploy.jsonc
pnpm exec wrangler d1 delete maronn-openid-connect-sample
```

**署名鍵の差し替えを本流へ戻すか決める。**
フェーズ 1 で `src/app.ts` に入れた変更は認定作業のための一時対応である。
恒久対応として取り込むなら `tasks/p1-signing-key-persistence-in-samples.md` の設計に沿わせ、戻すなら作業ブランチごと破棄する。

**結果を記録に残す。**
認定の有無にかかわらず、実行結果の要約を残す運用は `tasks/p3-conformance-basic-op-dry-run-and-result-record.md` で追跡している。
認定は取得時点のスナップショットなので、実装が変わったら再実行して差分を確認する。

## チェックリスト

### 着手前

- [ ] `pnpm --filter @maronn-openid-connect/sample-hono-cloudflare test` が通る
- [ ] `pnpm run conformance:basic-op` を実行し、OP 実装由来の failure が 0 件である
- [ ] 残る未 pass module が手動レビュー 3 件だけであることを結果 ZIP で確認した

### 公開デプロイ

- [ ] 署名鍵を secret から読む形に差し替え、JWKS が安定した `kid` と鍵素材を返す
- [ ] `certification.openid.net` 向けの ALIAS で設定とクライアント定義を生成した
- [ ] `OIDC_CLIENTS_JSON` と `OIDC_SIGNING_KEY_JWK` を secret として登録した
- [ ] 互換フラグ 2 つを付けてデプロイした
- [ ] Discovery の `issuer` が公開 URL と一致し、`request_object_signing_alg_values_supported` に `"none"` がある
- [ ] ブラウザで `/authorize` を開き、`testuser` / `password` でログインから同意まで通る

### Suite 実行

- [ ] Basic OP プランを `server_metadata=discovery` / `client_registration=static_client` で作成した
- [ ] 設定から `browser` ブロックを外した
- [ ] 全 module が `PASSED` / `REVIEW` / `WARNING` / `SKIPPED` のいずれかで、`FAILED` と `INTERRUPTED` が 0 件である

### 申請

- [ ] 手動レビュー 3 module にスクリーンショットを提出した
- [ ] Publish for certification で ZIP を取得し、記録として保管した
- [ ] 支払いコードを取得した（またはオープンソース免除を申請した）
- [ ] 提出フォームを送信し、Declaration of Conformance に署名した

### 取得後

- [ ] 互換フラグを外した、または認定用 Worker を削除した
- [ ] 署名鍵の一時変更の扱いを決めた
- [ ] 実行結果の要約をリポジトリへ記録した

## 参照

### OpenID Foundation

- OpenID Certification — https://openid.net/certification/
- 認定の進め方 — https://openid.net/certification/how-to-certify-your-implementation/
- 申請手順 — https://openid.net/how-to-submit-your-certification-request/
- OP テスト手順 — https://openid.net/certification/connect_op_testing/
- フィースケジュール — https://openid.net/certification/fees/
- オープンソース免除方針 — https://openid.net/certification/open-source-project-certification-policy/
- 認定実装一覧 — https://openid.net/certification/all-certified-implementations/
- 公式 Conformance Suite — https://www.certification.openid.net/
- Suite ソース — https://gitlab.com/openid/conformance-suite

### 仕様

- OpenID Connect Core 1.0（§3.1 Authorization Code Flow / §15.1 Mandatory to Implement Features） — https://openid.net/specs/openid-connect-core-1_0.html
- OpenID Connect Discovery 1.0 — https://openid.net/specs/openid-connect-discovery-1_0.html

### リポジトリ内

- `tests/conformance/README.md`
- `tests/conformance/manual-review-screenshots.md`
- `tests/conformance/scripts/create-basic-op-config.mjs`
- `samples/hono-cloudflare/README.md`
- `samples/hono-cloudflare/scripts/deploy-cloudflare.sh`
- `study-material/basic-op-requirement-traceability.md`
- `study-material/basic-op-conformance-verification-plan.md`
- `claude/skills/oidc-basic-op-certification/SKILL.md`
- `tasks/p1-signing-key-persistence-in-samples.md`
- `tasks/p3-conformance-compat-flags-warning-and-contract-tests.md`
- `tasks/p3-conformance-basic-op-dry-run-and-result-record.md`
