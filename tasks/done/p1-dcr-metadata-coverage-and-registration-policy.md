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
- `apps/hono/src/oidc-provider/features/dynamic-client-registration/`（`config.ts`、`store.ts`、`feature.ts`、`endpoints/register/` のステップ）と `apps/hono/src/settings.ts`
- `apps/nextjs/src/app/(dynamic-client-registration)/register/route.ts`、`apps/nextjs/src/app/_oidc-provider/features/dynamic-client-registration/`、`apps/nextjs/src/app/_oidc-provider/feature.ts`（`ProviderContext.clientKeyResolver`）、`provider.ts`、`settings.ts`
- `samples/hono-cloudflare` と `samples/express-flyio` の手書き `app.ts`（`OIDC_DCR_MAX_CLIENTS` だけを読む）、全 sample の再生成
- `tests/e2e/specs/dynamic-client-registration.spec.ts`、`tests/e2e/playwright.config.ts`
- `docs/library-document/src/content/docs/experimental/dynamic-client-registration.md`、`.changeset/cli-dcr-metadata-and-policy.md`
- notes リポジトリ: `implementation-guides/experimental/dynamic-client-registration.{ja,en}.md`、`tasks/experimental/done/dynamic-client-registration/specification.md` の追補

## 仕様参照

- **RFC 7591 §2**: クライアントメタデータの定義。`jwks` と `jwks_uri` は同時に使ってはならない（MUST NOT）
- **RFC 7591 §2.1**: grant_types と response_types の対応（`authorization_code` と `code`、`implicit` と `token`）。矛盾した登録は `invalid_client_metadata` で拒否してよい
- **RFC 7591 §2.3 / §3.1.1**: software statement は発行者が署名した JWT で、`iss` を持ち、主張したメタデータは平文の値に優先する。対応しない AS は無視してよい
- **RFC 7591 §3.2.1**: 登録に使った software statement は応答にそのまま返す（MUST）
- **RFC 7591 §3.2.2**: `invalid_software_statement`（検証できない）、`unapproved_software_statement`（発行者を承認していない）
- **OpenID Connect Dynamic Client Registration 1.0 §2**: response_type ごとに要る grant_type の対応表、`application_type`（既定 `web`）ごとの `redirect_uris` の制約と、登録する全 `redirect_uris` がそれに従うことを AS が確かめる MUST、`default_max_age`、`id_token_signed_response_alg`（既定 `RS256`、`none` の禁止）
- **OpenID Connect Dynamic Client Registration 1.0 §3.2**: AS が適用した既定値は応答に含める（MUST）。`client_id` は他のクライアントに有効であってはならず、`client_secret_expires_at` は `client_secret` を発行したときに必須、`registration_client_uri` と `registration_access_token` は両方返すか両方返さない
- **RFC 6749 §3.3**: scope の構文

## 実装方針

- [x] experimental を「解析」「software statement の検証と適用」「メタデータの検証」「レコードと応答の組み立て」の純関数に分け、登録できる値の一覧（認証方式、grant、response_type、scope、署名アルゴリズム）はすべてオプションで受け取る
- [x] 受理するメタデータを RFC 7591 §2 と OIDC Registration 1.0 §2 のうち OP が解釈または表示用に保持できるものへ広げる（`scope`、`client_uri`、`logo_uri`、`tos_uri`、`policy_uri`、`contacts`、`software_id`、`software_version`、`application_type`、`default_max_age`、`id_token_signed_response_alg`、`userinfo_signed_response_alg`、`jwks`）。URL を取得しに行くメタデータは引き続き無視する
- [x] `grant_types` と `response_types` の整合（RFC 7591 §2.1 / OIDC Registration §2）を検査し、生成コードは OP が答える response_type（`supportedResponseTypes()` / `responseTypesOf(features)`）と grant（`tokenGrantsOf(features)`、implicit を答えるときの `implicit`）を渡す
- [x] 標準外のメタデータを `customMetadata`（名前と検証関数の表）で受理する。値は 201 応答と `RegisteredClient.registrationMetadata` に現れる
- [x] software statement は、設定の省略可能な関数 `verifySoftwareStatement` が検証して返した主張を `applySoftwareStatement` で平文の値へ優先して適用し、`ClientRegistrationError` に 2 つのコードを足す。関数が無い既定では statement を無視し（RFC 7591 §3.1.1）、関数がある OP は `software_statement` の無い登録を `invalid_client_metadata` で断る。statement の中身は RFC 7591 が `iss` 以外の必須項目を定めないため、生成コードは検査しない
- [x] initial access token の判定を設定の省略可能な関数 `verifyInitialAccessToken` に委ねる。関数がある OP は Bearer トークン（RFC 6750 §2.1）の無い登録を 401 で断り、トークンの可否は関数が決める。生成コードに検証の既定実装（固定文字列の定数時間比較、発行者リストによる署名検証）は置かない。信頼の基準は配備ごとに違い、本番の形になり得ないためである。`customClientMetadata` と合わせて `config.ts` の設定にあり、Hono / Express / Fastify は `applyOidc` の `dynamicClientRegistration` オプション、Next.js は `extendDynamicClientRegistrationConfig()` から渡せる
- [x] オプションで渡した一覧（認証方式、grant、`jwks` の用途、信頼する発行者）とカスタムメタデータの表は既定に追加し、数値や文字列と判定関数は置き換える（`extendDynamicClientRegistrationConfig`）。利用者が生成コードの許す値を書き写さずに足せるようにする
- [x] `client_secret` を secret 系の認証方式にだけ発行し、`tokenEndpointAuthMethods` の拡張で `private_key_jwt` などを登録できるようにする
- [x] ストアのレコードを `db/` の `ClientRegistration` と同じ形にし、`jwks` の鍵を用途別に持ち、`withDynamicallyRegisteredClientKeys` で鍵解決に合成する。Next.js の `ProviderContext` に `clientKeyResolver` を加える
- [x] エラーの振り分けを `isClientRegistrationError`（形による判定）にする。Next.js の本番ビルドでは instrumentation と Route Handler が別バンドルになり、`instanceof` では policy が投げたエラーを 500 にしてしまうため
- [x] 実装解説（日英）を `apps/*` の構成に合わせて全文書き直し、利用者向け docs と changeset（cli: minor）を更新する
- [x] RFC 7591 と OIDC Registration 1.0 の MUST 要件を照合し、`application_type` の既定 `web` と省略時の `redirect_uris` の制約検査、`id_token_signed_response_alg` の既定 `RS256` の登録を補う（下記「MUST 要件の照合」）

## MUST 要件の照合

software statement がある登録は、statement の主張を平文の値へ優先して適用した結果を登録メタデータにする（RFC 7591 §3.1.1）。
`applySoftwareStatement` が平文のオブジェクトへ検証済みの主張を重ね、`validateClientMetadata` はその結果だけを見る。
statement 自体は `software_statement` としてそのまま応答に返し、statement から使った要素もトップレベルの値として返す（§3.2.1）。

| 要件 | 出典 | 実装 |
|---|---|---|
| 理解しないメタデータは無視する | RFC 7591 §2、OIDC Registration §3.2 | `validateClientMetadata` の allowlist-pick |
| software statement は署名された JWT で `iss` を持つ | RFC 7591 §2.3 | 設定に渡した `verifySoftwareStatement` の責務（生成コードは検証しない。関数が無ければ statement を無視する） |
| statement の値は平文の値に優先する | RFC 7591 §3.1.1 | `applySoftwareStatement` |
| 登録した全メタデータを返し、statement はそのまま、使った要素はトップレベルにも返す | RFC 7591 §3.2.1 | `buildClientRegistrationResponse`（発行値 + `metadata`） |
| `client_secret` を発行したら `client_secret_expires_at` を返す | RFC 7591 §3.2.1、OIDC Registration §3.2 | `buildClientRegistrationResponse`（0 = 無期限） |
| エラー応答は 400 で `error` を持つ | RFC 7591 §3.2.2 | `respondRegistrationError` / Route Handler の catch |
| `redirect_uris` は必須 | OIDC Registration §2 | `validateRedirectUris`（`invalid_redirect_uri`） |
| `application_type` の既定は `web`。web + implicit は https かつ `localhost` 以外、native はカスタムスキームかループバック http。AS は全 `redirect_uris` の適合を確かめる | OIDC Registration §2 | `validateApplicationType`（省略時 `web`）と `validateRedirectUrisForApplicationType`（常に実行） |
| `jwks` に秘密鍵・対称鍵を含めない。`jwks` と `jwks_uri` を併用しない | OIDC Registration §2、RFC 7591 §2 | `validateJwks`（RSA / EC の公開鍵のみ）、併記は `invalid_client_metadata` |
| `id_token_signed_response_alg` の既定は `RS256`、`none` は使わない | OIDC Registration §2 | `validateSigningAlg`（省略時 `RS256`、`none` 拒否、OP の鍵の alg に限る） |
| AS が適用した既定値は応答に含める | OIDC Registration §3.2 | `token_endpoint_auth_method`、`grant_types`、`response_types`、`application_type`、`id_token_signed_response_alg` を `metadata` に書き込む |
| `client_id` は他のクライアントに有効でない。`client_secret` を複数クライアントに割り当てない | OIDC Registration §3.2 | `dcr-` 名前空間 + 128 ビット乱数、256 ビット乱数の secret |
| `registration_client_uri` と `registration_access_token` は両方返すか両方返さない | OIDC Registration §3.2 | どちらも返さない（RFC 7592 は非目標） |
| initial access token は Bearer トークンとして受け付ける | OIDC Registration §3 | `readBearerToken`（RFC 6750 §2.1 の形式）で読み、設定に渡した `verifyInitialAccessToken` が可否を決める |
| 登録エンドポイントとの通信は TLS | RFC 7591 §5、OIDC Registration §9 | 配備側（リバースプロキシ / プラットフォーム）の責務 |

`sector_identifier_uri`（OIDC Registration §5 の登録時検証）は、`subject_types_supported` が `public` だけの OP では効果が無いため理解せず無視する。
`logo_uri` などが「有効な画像 / Web ページを指す」MUST はクライアント側の義務で、OP は取得しに行かず構文だけを検査する。

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
