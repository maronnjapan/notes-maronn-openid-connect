# [P1] Basic OP Certification 向けの非PKCE authorization code flow 互換方針を決めて実装する

## ステータス

🟢 High / 方針A実装済み・PKCE起因failure解消確認済み（Basic OP全passは未達）

## 背景

OpenID Foundation Conformance Suite の Basic OP static-client plan を `samples/hono` に対して実行したところ、Conformance runner 自体は完走したが Basic OP Certification は不合格だった。

実行対象:

- Test plan: `oidcc-basic-certification-test-plan[server_metadata=discovery][client_registration=static_client]`
- OP: `samples/hono`
- Result artifact: `tests/conformance/results/oidcc-basic-certification-test-plan-discovery-static_client-er8WhDACYy2mB-17-Jun-2026.zip`

結果:

- 35 modules 中 1 passed / 34 failed
- Passed: `oidcc-ensure-request-with-valid-pkce-succeeds`
- Failed modules の主因: Basic OP plan の多くが `code_challenge` なしの authorization code flow を実行する一方、現在のOPはOAuth 2.1方針でPKCEを必須にしているため、`/authorize` が `invalid_request` を返す

現在のエラー例:

```json
{
  "error": "invalid_request",
  "error_description": "Missing required parameters: client_id, code_challenge, or code_challenge_method"
}
```

## 判断が必要な点

このプロジェクトはOAuth 2.1準拠としてPKCE必須を重視している。一方、OpenID Connect Basic OP Certificationは非PKCEのauthorization code flowも検証対象に含む。

そのため、単にPKCE必須を外すのではなく、以下のどちらを採用するかを決める必要がある。

1. Basic OP Certification互換モードを追加し、Conformance実行時だけ非PKCE requestを許可する
2. Basic OP Certification合格を現時点では目標外とし、PKCE必須による不合格を既知の結果として扱う

## 対象ファイル候補

- `packages/core/src/authorization-request.ts`
- `packages/core/src/authorization-request.test.ts`
- `packages/cli/src/frameworks/*`
- `samples/*/src/app.ts`
- `samples/*/src/oidc-provider/config.ts`
- `tests/conformance/scripts/create-basic-op-config.mjs`
- `tests/conformance/README.md`

`samples/*/src/oidc-provider` はCLI生成物なので、生成物自体を直接直さず、必要な場合は `packages/cli` 側を修正する。

## 仕様参照

- OpenID Connect Core 1.0 Basic OP profile
- OpenID Connect Conformance Profiles v3.0 Basic OP
- OAuth 2.1 authorization code flow and PKCE requirements
- RFC 7636 PKCE

## 修正方針案

### 方針A: Conformance専用互換モードを追加する

- [x] `ProviderConfig` にPKCE必須挙動を制御する明示的な設定を追加する
- [x] デフォルトは現行どおりPKCE必須にする
- [x] `tests/conformance` のsample起動時だけ、環境変数で非PKCE authorization requestを許可する
- [x] Discovery metadata の `code_challenge_methods_supported` は実装実態と矛盾しない形にする
- [x] Conformance用設定が通常のPoC利用・E2E利用へ漏れないことを確認する

採用方針: 方針A。

実装メモ:

- `ProviderConfig.allowNonPkceAuthorizationCodeFlow` を追加し、既定値は `false`。
- coreの認可リクエスト検証は、互換モードが `true` かつ clientが明示的な
  `clientType: 'confidential'` の場合に限り、PKCEパラメータを完全に省略したrequestを許可する。
- public clientの非PKCE request、および不正なPKCE値を含むrequestは互換モードでも拒否する。
- Token Endpointは、認可コードにPKCE bindingがない場合だけ `code_verifier` を要求しない。
- `pnpm run conformance:basic-op` はサンプルOPコンテナにだけ
  `OIDC_ALLOW_NON_PKCE_AUTHORIZATION_CODE_FLOW=1` を渡す。通常起動・E2Eでは未設定のため既定false。
- Discoveryの `code_challenge_methods_supported: ['S256']` は、PKCEを使う場合にサポートする方式の広告として維持する。

Conformance再実行メモ:

- Result artifact:
  `tests/conformance/results/oidcc-basic-certification-test-plan-discovery-static_client-5XeV397bGW050-17-Jun-2026.zip`
- `pnpm run conformance:basic-op` はexit code 1。
- ZIP内のBasic OP modulesは 35件。22 passed / 6 warning / 4 failed / 1 skipped /
  2 interrupted without result。
- 旧主因だった `code_challenge` / `code_verifier` 必須エラーはZIP内ログのerror messageから消えている。
- 残課題はPKCE互換性とは別論点で、主にUserInfo scope claims warning、
  `id_token_hint`、request object系、WebRunnerのmanual review待機、refresh token skipped。

### 方針B: Basic OP CertificationをPKCE必須方針と分離して扱う

- [ ] READMEに「Basic OP planは実行可能だが、PKCE必須方針により現時点では不合格」と明記する
- [ ] CI workflowは合否確認用途として維持し、合格ゲートにはしない
- [ ] Basic OP合格を目指すタイミングで方針Aまたは別設計を再検討する

## テスト要件

方針Aを採用する場合:

- [x] `authorization-request.test.ts`: デフォルトでは `code_challenge` なしを拒否する
- [x] `authorization-request.test.ts`: 互換モードではconfidential static clientの非PKCE requestを許可する
- [x] `authorization-request.test.ts`: 互換モードでも不正なPKCE値は拒否する
- [x] CLI generator test: 設定項目が生成コードへ反映される
- [x] `tests/conformance`: Basic OP設定生成が互換モードを有効化する
- [x] `pnpm run conformance:basic-op` でPKCE起因の34 failuresが解消することを確認する

方針Bを採用する場合:

- [ ] READMEの既知の失敗としてConformance結果と理由を更新する
- [ ] CI workflowの目的が「Certification合否の可視化」であり「必須合格ゲート」ではないことを明記する

## 完了条件

- 採用方針がREADMEまたは設計メモに明記されていること
- 実装する場合はTDDでテストを追加し、`pnpm run test:ci` と関連E2Eが通ること
- Basic OP Certification合格を目指す場合は、`pnpm run conformance:basic-op` の結果zipで全Basic OP modulesがpassしていること
- Basic OP Certification合格を目指さない場合は、不合格理由がREADMEとCI運用手順に明記されていること
