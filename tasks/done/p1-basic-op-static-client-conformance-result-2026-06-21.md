# [P1] Basic OP static-client Conformance 実行結果と残課題（2026-06-21）

## ステータス

🟢 Done / `samples/hono` を OpenID Foundation Conformance Suite で実行し、Basic OP
static-client profile を確認。実装バグ 1 件（Request Object パラメータの黙殺）を修正。
残りの未 pass module はすべて manual review もしくは optional（SHOULD）であり、OP 実装
ロジック自体の failure は 0 件。

## 概要

`tests/conformance` の OpenID Foundation Conformance Suite を使い、`samples/hono` の
CLI 生成 OpenID Provider が OpenID Connect Basic OP Certification の **static client
profile** を満たすかを確認した。

- テストプラン: `oidcc-basic-certification-test-plan[server_metadata=discovery][client_registration=static_client]`
- 検証対象 OP: `samples/hono`（`OIDC_ALLOW_NON_PKCE_AUTHORIZATION_CODE_FLOW=1` の Basic OP 互換モード）
- Suite image: `registry.gitlab.com/openid/conformance-suite:latest`（export version 5.2.0）

## 実行環境についての注意（restricted-network sandbox）

このリポジトリの標準手順は `pnpm run conformance:basic-op`（`tests/conformance/scripts/run-basic-op.sh`）
で、Docker Compose の `runner` コンテナ内で `run-test-plan.py` を実行する設計になっている。

今回の実行環境（remote sandbox）は egress allowlist proxy 配下にあり、以下の制約があった。

- `dl-cdn.alpinelinux.org` / `deb.debian.org` は `host_not_allowed`（403）でブロックされる。
  そのため `runner.Dockerfile` の `apk add bash ca-certificates curl git` が TLS / fetch
  段階で失敗し、`runner` コンテナをビルドできない。
- Docker Hub の一部 layer（`production.cloudfront.docker.com`）は 403／unauthenticated
  pull rate limit でブロックされた。`mirror.gcr.io/library/*` 経由の pull は許可されていた。
- `gitlab.com`（Suite 本体の clone）・`pypi.org`（`httpx` の取得）・gitlab registry の
  Suite image pull は許可されていた。

このため今回は **Suite runner だけを host 側で実行**する迂回手順で結果を取得した
（OP・Suite・nginx・mongo は通常どおり Docker Compose で起動）。

1. `mongo:6.0.13` / `node:22-bookworm-slim` / `nginx:1.27-alpine` / `python:3.13-alpine3.20`
   を `mirror.gcr.io/library/*` から pull し、Compose が期待する tag に retag。
2. `docker compose ... up -d mongodb conformance-server conformance-nginx op op-tls`
   （`runner` 以外を起動）。
3. host 側 venv に `httpx` / `pyparsing` を入れ、`git clone https://gitlab.com/openid/conformance-suite.git`。
4. host から `python scripts/run-test-plan.py --export-dir <results> --no-parallel <plan> <config>`
   を `CONFORMANCE_SERVER=https://localhost:8443/`・`DISABLE_SSL_VERIFY=1` で実行
   （Suite の host 公開ポート 8443 / OP の op-tls 公開ポート 3443 を利用）。

> この迂回はサンドボックス固有の制約に対する一時対応であり、`runner.Dockerfile` や
> `run-basic-op.sh` は変更していない。egress が緩い環境（CI 含む）では従来どおり
> `pnpm run conformance:basic-op` が正しく動作する。

## 結果サマリ（修正後）

35 module 中:

| 結果 | 数 | 内容 |
|---|---|---|
| PASSED | 29 | 主要フロー（authorization code / token / userinfo / scope / prompt=none / max-age / id_token_hint / refresh_token / code reuse / client_secret_post 等） |
| SKIPPED | 1 | `oidcc-unsigned-request-object-...`（OP が `request_not_supported` で明示拒否 → Suite が「rejected as unsupported は permitted」として skip） |
| WARNING | 1 | `oidcc-ensure-request-with-acr-values-succeeds`（acr は SHOULD） |
| UNKNOWN (manual) | 2 | `oidcc-prompt-login` / `oidcc-max-age-1`（2回目ログイン画面の screenshot 提出待ち） |
| FAILED (manual) | 2 | `oidcc-ensure-registered-redirect-uri` / `oidcc-ensure-request-object-with-redirect-uri`（error page の screenshot 提出待ち。browser automation が callback に到達せず WebRunner timeout） |

OP 実装ロジック由来の FAILURE は **0 件**。FAILED 2 件はいずれも OP が正しく error page を
表示し REVIEW ステップ（`Show redirect URI error page`）に到達したうえで、callback に
到達しないため WebRunner が timeout したもの（manual review 前提の module）。

### 修正前との差分

修正前は `oidcc-unsigned-request-object-supported-correctly-or-rejected-as-unsupported`
が **FAILED**（2 FAILURE）だった。

- `request`（Request Object by value）パラメータを OP が黙殺し、通常クエリのまま処理。
- request object 内にしか無い `state` / `nonce` が反映されず、
  `State was passed in request, but is missing from response` /
  `Nonce values mismatch` で失敗していた。

## 実装した修正

### 仕様根拠

- OIDC Core 1.0 §6.1 / §6.2: `request` / `request_uri` は Authorization Request パラメータを
  JWT として渡す仕組み。
- OIDC Core 1.0 §6.3 / §3.1.2.6: OP がこれらを **サポートしない場合**、リクエストを黙殺せず
  `request_not_supported` / `request_uri_not_supported` で拒否しなければならない
  （黙殺すると request-object-only の `state` / `nonce` が落ち、応答が壊れる）。
- OIDC Discovery 1.0 §3: 本 OP は `request_parameter_supported` / `request_uri_parameter_supported`
  を広告していない（既定 false）ため、上記の拒否動作が discovery metadata と一致する。

### 変更内容

`packages/core/src/authorization-request.ts`

- `AuthorizationRequestParams` に `request?` / `request_uri?` を追加。
- `AuthorizationErrorCode` に `RequestNotSupported = 'request_not_supported'` /
  `RequestUriNotSupported = 'request_uri_not_supported'` を追加。
- `validateAuthorizationRequest` で、redirect_uri 解決後（=リダイレクト可能）かつ
  response_type / scope / PKCE 検証の前に、`request` / `request_uri` が存在すれば
  上記エラーで拒否する。`response_type` が request object 内にしか無いケースでも、
  「missing response_type」ではなく `request_not_supported` を優先して返す。
- redirect_uri 解決の **後** にチェックするため、top-level redirect_uri が無効な
  `oidcc-ensure-request-object-with-redirect-uri` は従来どおり非リダイレクト error page
  になり、request object 内の redirect_uri を OP が誤って採用することはない。

`packages/cli/src/frameworks/hono/templates.ts`（`reuseFlowConformanceTestBlock`）

- 生成 OP の契約テスト（`conformance.test.ts`）に「Request Object parameters (unsupported)」
  describe を追加。`request` → `request_not_supported`、`request_uri` →
  `request_uri_not_supported` の redirect を全フレームワーク共通で固定。
- これに伴い `samples/{hono,express,fastify,nextjs}` の `conformance.test.ts` を再生成。

## テスト

- `pnpm --filter @maronn-openid-connect/core test`: 817 passed（新規 4 件含む）。
- `pnpm --filter @maronn-openid-connect/cli test`: 259 passed。
- `pnpm --filter "./samples/*" typecheck`: 全 sample 成功。
- Conformance Suite 再実行で当該 module が FAILED → SKIPPED（permitted）へ変化したことを確認。

## 残課題と対応手順（certification を完了させる場合）

いずれも OP の実装は正しく、Conformance Suite 側で **人手の screenshot 提出 / manual review**
が必要なもの、もしくは optional（SHOULD）である。

### 1. manual review（screenshot 提出）— 4 module

`oidcc-ensure-registered-redirect-uri` / `oidcc-ensure-request-object-with-redirect-uri`
（OP の error page）と `oidcc-prompt-login` / `oidcc-max-age-1`（2回目ログイン画面）は、
browser automation だけでは完了せず screenshot 提出が必要。

手順:

```bash
CONFORMANCE_KEEP_SERVICES=1 pnpm run conformance:basic-op
```

runner 終了後も Suite Web UI（`CONFORMANCE_SUITE_PORT`、既定 8443）が残るので、対象 module を
開き、表示された error page / 2回目ログイン画面の screenshot をアップロードして完了させる。
（詳細は `tests/conformance/README.md` の「Manual review が必要な module の扱い」を参照）

### 2. `oidcc-ensure-request-with-acr-values-succeeds`（WARNING / optional）

`acr_values` が要求されたとき OP は acr claim を返す **SHOULD**。現状は返していないため
WARNING（FAILURE ではない）。Basic OP の必須要件ではないが、対応する場合は ID Token に
実際の認証コンテキストを表す `acr` を付与する必要がある（既存タスク
`tasks/p2-acr-values-request-propagation.md` を参照）。

### 3. Request Object の完全対応（任意の上位対応）

`oidcc-ensure-request-object-with-redirect-uri` を manual review ではなく **全自動 pass**
させるには、署名付き Request Object by value を実際に処理し、request object 内の
`redirect_uri` を採用できる必要がある。これは Basic OP certification の必須要件ではなく、
既存タスク `tasks/p1-basic-op-request-object-by-value.md` で別途スコープ化されている。
本対応（reject as unsupported）は、その完全対応への第一歩（`request_uri_not_supported` /
`request_not_supported` の明示拒否）を満たす。

## 出力物（このリポジトリには含まれない gitignore 対象）

- `tests/conformance/results/oidcc-basic-certification-test-plan-discovery-static_client-*.zip`
- `tests/conformance/results/docker-compose.log`
