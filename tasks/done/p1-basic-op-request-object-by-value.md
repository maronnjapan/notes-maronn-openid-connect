# [P1] Basic OP static-client 向けに signed Request Object by value を実装する

## ステータス

🟢 Done / 実装完了（RS256 signed Request Object by value 本実装・discovery 広告・CLI テンプレート反映・全 sample 再生成まで完了）

> 2026-06-22 実装完了メモ:
> - `packages/core` に `request-object.ts`（compact JWS パース・RS256 署名検証・`alg:none` 互換）を追加し、
>   `validateAuthorizationRequest` で request object claim を展開（§6.1 supersede。state/nonce/scope/prompt/max_age 等は
>   クエリ同様の検証・正規化を通して実際に後続処理の値として使用。response_type/client_id のみ §6.1 の必須要件により
>   一致検証。request object 内 redirect_uri 優先）するよう統合した。
> - `ClientInfo.jwks` / `ValidateAuthorizationRequestOptions.requestObject` を追加。
> - discovery に `request_parameter_supported: true` / `request_uri_parameter_supported: false` /
>   `request_object_signing_alg_values_supported`（`allowUnsignedRequestObject` 時は `["RS256","none"]`）を追加。
> - CLI テンプレート（hono / web-standard）を更新し、全 framework（hono/express/fastify/nextjs）の sample を再生成。
>   生成 `conformance.test.ts` を「signed request object を受理して login へ遷移／discovery 広告／request_uri 拒否」へ更新。
> - `create-basic-op-config` に client JWKS 登録を追加。
> - `pnpm --filter core test`(838) / `--filter cli test`(259) / conformance script test(7) / 全 sample conformance(各12) / 全 typecheck パス。
> - 未実施: `pnpm run conformance:basic-op` の ZIP 取得は OIDF Conformance Suite（docker）が必要で本環境では実行不可。実装機構は上記契約テストで担保。

> 2026-06-21 追記: Basic OP static-client conformance の確認に伴い、`request` /
> `request_uri` を `request_not_supported` / `request_uri_not_supported` で明示拒否する
> 最小対応のみ先行実装した（`AuthorizationRequestParams` への `request?` / `request_uri?`
> 追加、`AuthorizationErrorCode` への error code 追加、`validateAuthorizationRequest` での
> 拒否、生成 `conformance.test.ts` への契約テスト追加）。これにより
> `oidcc-unsigned-request-object-supported-correctly-or-rejected-as-unsupported` は
> FAILED → SKIPPED（permitted）になった。下記チェックリストのうち、署名付き Request
> Object の処理本体・discovery の `request_parameter_supported: true` 化・
> `oidcc-ensure-request-object-with-redirect-uri` の全自動 pass は未着手のまま。
> 詳細は `tasks/done/p1-basic-op-static-client-conformance-result-2026-06-21.md` を参照。

> 2026-06-22 追記: `tests/conformance/results/oidcc-basic-certification-test-plan-discovery-static_client-0zMCWqum8rQnj-21-Jun-2026.zip`
> でも同じ状態を確認した。`oidcc-unsigned-request-object-supported-correctly-or-rejected-as-unsupported`
> は SKIPPED（permitted）だが、全フローを PASSED に揃えるには本タスクの Request Object by
> value 実装により `oidcc-ensure-request-object-with-redirect-uri` を manual error-page
> 経路ではなく authorization code flow として完了させる必要がある。

## 背景

`tests/conformance` の直近実行で request object 系 module が未passになっている。

対象結果:

- `tests/conformance/results/oidcc-basic-certification-test-plan-discovery-static_client-5XeV397bGW050-17-Jun-2026.zip`
- `tests/conformance/results/oidcc-basic-certification-test-plan-discovery-static_client-0zMCWqum8rQnj-21-Jun-2026.zip`
- `oidcc-unsigned-request-object-supported-correctly-or-rejected-as-unsupported`: `FINISHED / FAILED`
  - `request` パラメータを黙殺して通常処理している
  - request object 内の `state` / `nonce` が使われず、`State was passed... missing` と `Nonce values mismatch`
  - `request_parameter_supported` が absent で default false の warning
- 最新結果では上記 module は `FINISHED / SKIPPED` に改善済み（`request_not_supported` による permitted behavior）
- `oidcc-ensure-request-object-with-redirect-uri`: `INTERRUPTED / FAILED`
  - request object 内に有効な `redirect_uri`、通常パラメータに無効な `redirect_uri` があるケース
  - 現状は通常パラメータの無効 `redirect_uri` だけを見て HTTP 400 になり、WebRunner が完了できない

Conformance Suite の Basic OP plan には `OIDCCUnsignedRequestObjectSupportedCorrectlyOrRejectedAsUnsupported` と `OIDCCEnsureRequestObjectWithRedirectUri` が含まれている。前者は `request_not_supported` での明示拒否も許すが、後者を全自動で通すには request object 内の `redirect_uri` を正しく処理できる必要がある。

本タスクでは、Request Object 対応を unsigned (`alg: "none"`) の最小実装に閉じず、署名付き JWS Request Object を標準実装対象にする。Conformance Suite の対象 module が unsigned Request Object を送る場合は、Basic OP conformance 互換として `alg: "none"` も同時に受け付ける。

## 調査根拠

- OIDC Core 1.0 §6: Request Object は Authorization Request パラメータを JWT Claims として渡す仕組み。
- OIDC Core 1.0 §3.1.2.6 / §6: 非対応の場合は `request_not_supported` / `request_uri_not_supported` のエラーが定義されている。
- OIDC Discovery 1.0 §3: `request_parameter_supported` / `request_uri_parameter_supported` / `request_object_signing_alg_values_supported` は OP の対応状況を広告する。
- OIDC Core 1.0 §6.1: Request Object は JWT として表現され、署名付きの場合は JWS により request parameter values の完全性を保護できる。
- OIDF Conformance Suite `OIDCCBasicTestPlan`: Basic OP plan に request object module が含まれる。

## 対象ファイル

- `packages/core/src/authorization-request.ts`
- `packages/core/src/authorization-request.test.ts`
- `packages/core/src/crypto-utils.ts`
- `packages/core/src/crypto-utils.test.ts`
- `packages/core/src/discovery.ts`
- `packages/core/src/discovery.test.ts`
- `packages/core/src/index.ts`
- `packages/cli/src/frameworks/hono/templates.ts`
- `packages/cli/src/frameworks/web-standard/templates.ts`
- `packages/cli/src/__tests__/hono-generator.test.ts`
- `packages/cli/src/__tests__/web-framework-generators.test.ts`
- `tests/conformance/scripts/create-basic-op-config.mjs`
- `tests/conformance/scripts/create-basic-op-config.test.mjs`
- `samples/*/src/oidc-provider/routes/authorize.ts`
- `samples/*/src/oidc-provider/routes/discovery.ts`
- `samples/*/src/oidc-provider/conformance.test.ts`

`samples/*/src/oidc-provider` は CLI 生成物なので、修正元は必ず `packages/cli` に置く。

## 修正方針

Basic OP static-client conformance を満たしつつ仕様忠実性を優先するため、`request` by value は署名付き JWS を主対象として実装する。

- [ ] `AuthorizationRequestParams` に `request?: string` / `request_uri?: string` を追加する。
- [ ] `request_uri` は本タスクでは実装せず、登録済み redirect URI へ `request_uri_not_supported` を返す。
- [ ] `request` は compact JWS の signed JWT を受理し、少なくとも `RS256` を必須対応にする。
- [ ] 署名検証用の公開鍵は client metadata 由来の JWKS / JWK を解決できる形で `validateAuthorizationRequest` に渡す。静的 client 設定では conformance 用 client の鍵も登録できるようにする。
- [ ] JWS header の `alg` / `kid` を検証し、未対応 `alg`、未知の `kid`、署名不一致は `invalid_request` で拒否する。
- [ ] Conformance Suite が unsigned Request Object を送る場合に限り、`alg: "none"` も互換対応として受理する。署名無し対応を入れる場合も、署名付き対応を本タスクの主実装から外さない。
- [ ] JWE、compact JWT として壊れた値、JSON object でない payload は `invalid_request` で拒否する。
- [ ] request object 内の claim を Authorization Request パラメータとして展開する。
- [ ] OIDC Core §6.1 に従い、request object 内の request parameter values は通常の OAuth 2.0 request syntax で渡された値を supersede する。
- [ ] ただし `response_type` と `client_id` は OAuth 2.0 request syntax にも必ず含め、request object 内にもある場合は値が一致しなければ `invalid_request` で拒否する。
- [ ] `scope` は OAuth 2.0 request syntax 側にも必ず含め、`openid` を含むことを既存ロジックで検証する。request object 内にも `scope` がある場合は request object 側を有効値として扱う。
- [ ] `redirect_uri`, `state`, `nonce`, `scope`, `client_id`, `response_type` は request object 由来でも既存検証に通す。
- [ ] `oidcc-ensure-request-object-with-redirect-uri` のため、通常パラメータの `redirect_uri` が無効でも、request object 内の `redirect_uri` が有効であれば request object 側を使って処理できるようにする。
- [ ] Discovery に以下を広告する。
  - `request_parameter_supported: true`
  - `request_uri_parameter_supported: false`（Discovery 省略時の既定は `true` なので必ず明示する）
  - `request_object_signing_alg_values_supported: ["RS256"]`（`alg: "none"` を互換対応する場合は `["RS256", "none"]`）
- [ ] `request` 非対応の明示拒否だけで止める場合は、`oidcc-ensure-request-object-with-redirect-uri` が manual error-page 経路に残るため、本タスクの完了条件を満たさないものとする。

## テスト要件

- [ ] `authorization-request.test.ts`: RS256 signed request object 内の `state` / `nonce` / `redirect_uri` が認可コードと ID Token に反映されること。
- [ ] `authorization-request.test.ts`: 通常パラメータと request object の `nonce` が不一致なら拒否されること。
- [ ] `authorization-request.test.ts`: request object 内の valid `redirect_uri` が top-level invalid `redirect_uri` より優先され、登録済み redirect URI として検証されること。
- [ ] `authorization-request.test.ts`: 署名不一致、未知の `kid`、未対応 `alg` が `invalid_request` になること。
- [ ] `authorization-request.test.ts`: Conformance 互換として `alg: "none"` を受理する場合、unsigned request object 内の `state` / `nonce` / `redirect_uri` も同じ検証を通ること。
- [ ] `authorization-request.test.ts`: `request_uri` が `request_uri_not_supported` になること。
- [ ] `authorization-request.test.ts`: 壊れた request object が `invalid_request` になること。
- [ ] `discovery.test.ts`: request object 関連 metadata が期待値で出ること。
- [ ] CLI generator test: 生成 Discovery / Authorize route に request object 対応が含まれること。
- [ ] sample conformance test: RS256 signed request object by value の authorization code flow が成功すること。
- [ ] `create-basic-op-config.test.mjs`: static client に Request Object 署名検証用の client JWKS / JWK を登録できること。
- [ ] `pnpm --filter @maronn-openid-connect/core test` と `pnpm --filter @maronn-openid-connect/cli test` がパスすること。
- [ ] `pnpm run conformance:basic-op` の ZIP で request object 系 module が pass すること。

## 完了条件

- RS256 signed Request Object by value を処理できる。
- `oidcc-unsigned-request-object-supported-correctly-or-rejected-as-unsupported` が pass する。
- `oidcc-ensure-request-object-with-redirect-uri` が HTTP 400 timeout ではなく pass する。
- Discovery が実装実態と一致している。
