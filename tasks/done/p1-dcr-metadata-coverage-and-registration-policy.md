# [P1] DCR の受理メタデータを広げ、登録の判定（initial access token、software statement、カスタムメタデータ）を差し替え可能にする

## ステータス

✅ Implemented / 実装済み（OSS リポジトリの `claude/dcr-implementation-fixes-izou5e` ブランチ）

## 背景

Dynamic Client Registration（RFC 7591、PR #131）は、理解するメタデータを `redirect_uris`、`token_endpoint_auth_method`、`grant_types`、`response_types`、`client_name` の 5 つに絞り、`response_types` を `["code"]` に固定していた。
`scope` の受理（PR #133）は実装解説には残っていたが、生成元を `apps/*` へ移す再構成の過程でコードから落ちていた。
その後 OP は Implicit Flow と Hybrid Flow を既定で生成するようになり、`code` 以外の response_type を持つクライアントを動的登録できないことが、Implicit OP と Hybrid OP の Conformance プランや MCP クライアントの検証で制約になっていた。
登録の判定は initial access token の固定文字列との照合しかなく、独自の発行や software statement による登録を試す余地が無かった。
エラーコードも RFC 7591 §3.2.2 の 4 種のうち software statement 系の 2 種を持たなかった。

## 対象ファイル

- `packages/experimental/src/dynamic-client-registration/`（`registration-error.ts`、`metadata-values.ts`、`registration-request.ts`、`software-statement.ts`、`registered-client.ts`、`index.ts`、各テスト、`test-helpers.ts`）
- `apps/hono/src/oidc-provider/features/dynamic-client-registration/`（`config.ts`、`policy.ts`、`store.ts`、`feature.ts`、`endpoints/register/` のステップ）と `apps/hono/src/settings.ts`
- `apps/nextjs/src/app/(dynamic-client-registration)/register/route.ts`、`apps/nextjs/src/app/_oidc-provider/features/dynamic-client-registration/`、`apps/nextjs/src/app/_oidc-provider/feature.ts`（`ProviderContext.clientKeyResolver`）、`provider.ts`、`settings.ts`
- `samples/hono-cloudflare` と `samples/express-flyio` の手書き `app.ts`（`OIDC_DCR_TRUSTED_SOFTWARE_PUBLISHERS_JSON`）、全 sample の再生成
- `tests/e2e/specs/dynamic-client-registration.spec.ts`、`tests/e2e/support/software-publisher.ts`、`tests/e2e/playwright.config.ts`
- `docs/library-document/src/content/docs/experimental/dynamic-client-registration.md`、`.changeset/cli-dcr-metadata-and-policy.md`
- notes リポジトリ: `implementation-guides/experimental/dynamic-client-registration.{ja,en}.md`、`tasks/experimental/done/dynamic-client-registration/specification.md` の追補

## 仕様参照

- **RFC 7591 §2**: クライアントメタデータの定義。`jwks` と `jwks_uri` は同時に使ってはならない（MUST NOT）
- **RFC 7591 §2.1**: grant_types と response_types の対応（`authorization_code` と `code`、`implicit` と `token`）。矛盾した登録は `invalid_client_metadata` で拒否してよい
- **RFC 7591 §2.3 / §3.1.1**: software statement は発行者が署名した JWT で、`iss` を持ち、主張したメタデータは平文の値に優先する。対応しない AS は無視してよい
- **RFC 7591 §3.2.1**: 登録に使った software statement は応答にそのまま返す（MUST）
- **RFC 7591 §3.2.2**: `invalid_software_statement`（検証できない）、`unapproved_software_statement`（発行者を承認していない）
- **OpenID Connect Dynamic Client Registration 1.0 §2**: response_type ごとに要る grant_type の対応表、`application_type` ごとの `redirect_uris` の制約、`default_max_age`、`id_token_signed_response_alg`（`none` の禁止）
- **RFC 6749 §3.3**: scope の構文

## 実装方針

- [x] experimental を「解析」「software statement の検証と適用」「メタデータの検証」「レコードと応答の組み立て」の純関数に分け、登録できる値の一覧（認証方式、grant、response_type、scope、署名アルゴリズム）はすべてオプションで受け取る
- [x] 受理するメタデータを RFC 7591 §2 と OIDC Registration 1.0 §2 のうち OP が解釈または表示用に保持できるものへ広げる（`scope`、`client_uri`、`logo_uri`、`tos_uri`、`policy_uri`、`contacts`、`software_id`、`software_version`、`application_type`、`default_max_age`、`id_token_signed_response_alg`、`userinfo_signed_response_alg`、`jwks`）。URL を取得しに行くメタデータは引き続き無視する
- [x] `grant_types` と `response_types` の整合（RFC 7591 §2.1 / OIDC Registration §2）を検査し、生成コードは OP が答える response_type（`supportedResponseTypes()` / `responseTypesOf(features)`）と grant（`tokenGrantsOf(features)`、implicit を答えるときの `implicit`）を渡す
- [x] 標準外のメタデータを `customMetadata`（名前と検証関数の表）で受理する。値は 201 応答と `RegisteredClient.registrationMetadata` に現れる
- [x] software statement を `verifySoftwareStatement`（core の `parseRequestObject` で署名検証。発行者の承認、`iss`、`exp` / `nbf`）と `applySoftwareStatement` で扱い、`ClientRegistrationError` に 2 つのコードを足す。既定では発行者を承認せず、statement を送る登録は `unapproved_software_statement` になる
- [x] 登録の判定を生成コードの `policy.ts` に関数として生成し（`verifyRegistrationInitialAccessToken`、`verifyRegistrationSoftwareStatement`、`customClientMetadata`）、`config.ts` の既定値として持たせる。Hono / Express / Fastify は `applyOidc` の `dynamicClientRegistration` オプション、Next.js は `extendDynamicClientRegistrationConfig()` から差し込める
- [x] オプションで渡した一覧（認証方式、grant、`jwks` の用途、信頼する発行者）とカスタムメタデータの表は既定に追加し、数値や文字列と判定関数は置き換える（`extendDynamicClientRegistrationConfig`）。利用者が生成コードの許す値を書き写さずに足せるようにする
- [x] `client_secret` を secret 系の認証方式にだけ発行し、`tokenEndpointAuthMethods` の拡張で `private_key_jwt` などを登録できるようにする
- [x] ストアのレコードを `db/` の `ClientRegistration` と同じ形にし、`jwks` の鍵を用途別に持ち、`withDynamicallyRegisteredClientKeys` で鍵解決に合成する。Next.js の `ProviderContext` に `clientKeyResolver` を加える
- [x] エラーの振り分けを `isClientRegistrationError`（形による判定）にする。Next.js の本番ビルドでは instrumentation と Route Handler が別バンドルになり、`instanceof` では policy が投げたエラーを 500 にしてしまうため
- [x] 実装解説（日英）を `apps/*` の構成に合わせて全文書き直し、利用者向け docs と changeset（cli: minor）を更新する

## テスト要件

- experimental: `registration-request.test.ts`（解析、各メタデータ、整合、カスタムメタデータ）、`software-statement.test.ts`（検証成功、`invalid_software_statement` の各経路、`unapproved_software_statement`、適用）、`registered-client.test.ts`、`initial-access-token.test.ts`
- apps/hono: config、policy、store（`toClientRegistration`、鍵解決の合成）、feature、各ステップ、pipeline（OP の response_type、experimental grant の許可、署名アルゴリズム、カスタム判定、software statement、カスタムメタデータ）、settings
- apps/nextjs: config、policy、store、feature、`route.test.ts`、settings、dev-data
- E2E: scope の登録と `invalid_scope`、implicit クライアントのフラグメント応答、情報系メタデータの返却、`jwks` の正規化、grant と response の不整合、software statement の 3 経路（形式不正、未承認、承認済み発行者）、既存の 401 / 429

## 完了条件

- `pnpm --filter @maronn-openid-connect/experimental test`、`pnpm --filter @maronn-openid-connect/app-hono test`、`pnpm --filter @maronn-openid-connect/app-nextjs test`、`pnpm --filter @maronn-openid-connect/cli test` がパスすること
- `pnpm run lint`、`pnpm run typecheck`、`pnpm --filter @maronn-openid-connect/cli test:matrix` がパスすること
- `pnpm run test:e2e`（apps/hono と apps/nextjs）がパスすること
- 全 sample を再生成し、`check:generated` がパスすること
