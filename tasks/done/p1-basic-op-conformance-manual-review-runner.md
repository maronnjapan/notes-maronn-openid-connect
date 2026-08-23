# [P1] Basic OP Conformance runner で manual review module を完了できるようにする

## ステータス

🟢 High / browser automation の `Verify Complete` を optional 化し、manual review module で WebRunner timeout/INTERRUPTED にならないようにした。手動完了の運用手順を README に追記。Suite API による placeholder 自動完了は本環境で検証不可のため手動運用に倒す

## 背景

`tests/conformance` の直近実行では、OP の主要フローが成功していても manual review が必要な module が完了できず、alias conflict で interrupted になっている。

対象結果:

- `tests/conformance/results/oidcc-basic-certification-test-plan-discovery-static_client-5XeV397bGW050-17-Jun-2026.zip`
- `oidcc-prompt-login`: 2回目の `prompt=login` 認可と token exchange は成功しているが、2回目認可画面の screenshot 提出待ちで `INTERRUPTED`
- `oidcc-max-age-1`: 2回目の `max_age=1` 認可と token exchange は成功しているが、2回目認可画面の screenshot 提出待ちで `INTERRUPTED`
- `oidcc-ensure-registered-redirect-uri`: OP は unregistered `redirect_uri` に redirect せず HTTP 400 を返しているが、Suite は redirect URI error page screenshot 提出を待つため WebRunner timeout
- `oidcc-ensure-request-object-with-redirect-uri`: request object 対応完了までは同様に error page screenshot 経路に落ちる可能性がある

現在の browser automation は callback URL の `submission_complete` を待つ前提になっており、Conformance Suite の placeholder / screenshot 提出を処理できない。そのため、実装が正しくても `run-test-plan.py` の全体 exit code は 0 にならない。

## 調査根拠

- OIDF Conformance Suite `OIDCCPromptLogin`: summary で「2回目認可の screenshot upload」を要求する。
- OIDF Conformance Suite `OIDCCMaxAge1`: summary で「2回目認可の screenshot upload」を要求する。
- OIDF Conformance Suite `OIDCCEnsureRegisteredRedirectUri`: unregistered redirect URI では redirect せず error page screenshot upload を要求する。
- 直近 ZIP の `prompt-login` / `max-age-1` ログでは、認可・Token Endpoint・UserInfo は成功済みで、最後に alias conflict で interrupted になっている。

## 対象ファイル

- `tests/conformance/scripts/create-basic-op-config.mjs`
- `tests/conformance/scripts/create-basic-op-config.test.mjs`
- `tests/conformance/scripts/run-basic-op.sh`
- `tests/conformance/scripts/run-suite-runner.sh`
- `tests/conformance/README.md`
- 必要に応じて `tests/conformance/runner.Dockerfile`
- 必要に応じて生成 OP の error view:
  - `packages/cli/src/frameworks/hono/templates.ts`
  - `samples/*/src/oidc-provider/views.ts`

## 修正方針

- [ ] Conformance Suite の placeholder / screenshot review を runner から完了する方法を調査する。
  - Suite API で placeholder を完了できるか
  - `run-test-plan.py` に manual step 待機や upload option があるか
  - 自動化できない場合、`CONFORMANCE_KEEP_SERVICES=1` で人間が完了する運用手順を確立する
- [ ] Browser automation の `Verify Complete` が error page / manual placeholder module に対して無条件に走らないようにする。
- [ ] manual review が必要な module では、runner が次 module を同じ alias で開始する前に完了待ちする。
- [ ] 自動化できる場合、Playwright または Suite API で screenshot / placeholder submission を行う。
- [ ] 自動化できない場合、`CONFORMANCE_MANUAL_REVIEW=1` のような明示モードを追加し、README に手順を記載する。
- [ ] unregistered redirect URI 用の OP error page は、JSON 400 だけでなく人間が確認できる HTML error page を返す方向も検討する。ただし redirect してはいけない。
- [ ] request object support が完了した後、`oidcc-ensure-request-object-with-redirect-uri` が manual review 対象に残るか再確認する。

## テスト要件

- [ ] `create-basic-op-config.test.mjs`: manual review 対象 module で browser automation が不適切に callback completion を待たないことを固定する。
- [ ] runner script の unit / smoke test が可能なら、manual review mode の環境変数とログ出力を確認する。
- [ ] `CONFORMANCE_KEEP_SERVICES=1 pnpm run conformance:basic-op` で手動完了できる手順が README どおりに成立すること。
- [ ] 自動化する場合、直近で interrupted になった `prompt-login` / `max-age-1` / `ensure-registered-redirect-uri` が interrupted にならないこと。

## 完了条件

- OP 実装の正否と manual review 未完了が区別できる。
- `prompt-login` / `max-age-1` が alias conflict で interrupted にならない。
- `ensure-registered-redirect-uri` が WebRunner timeout ではなく、manual review 完了または明確な手順待ちとして扱われる。
- `tests/conformance/README.md` に自動 / 手動どちらの運用で Basic OP Certification を完了するかが明記されている。
