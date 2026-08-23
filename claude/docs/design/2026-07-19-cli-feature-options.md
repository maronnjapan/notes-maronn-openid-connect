# CLI 機能オプション（feature toggles）+ core 機能分割 設計

- 日付: 2026-07-19
- 依頼: CLIのテンプレート生成でPKCEやその他機能をオプションで設定できるようにする。デフォルト構成から機能を付け足したり減らしたりできるようにする。あわせてcoreの一枚岩関数を機能ごとに分割する。

## 目的

`maronn-oidc generate <framework>` に機能トグルを導入し、生成されるOPコードを
「デフォルト（現行の全部入り）」から機能単位で増減できるようにする。
これを支えるため、coreの `validateTokenRequest` / `validateAuthorizationRequest` を
機能（grant / パラメータ）単位に分割し、機能の有効・無効を core オプションとして表現できるようにする。

## 機能セット（v1）

| feature名 | 既定 | OFF時の生成コードの挙動 |
|---|---|---|
| `pkce` | ON | PKCEを任意化する。生成 `config.ts` の既定を `allowNonPkceAuthorizationCodeFlow: true` にする（core仕様どおり、confidential client の「完全な非PKCEリクエスト」のみ許可。public client と不正PKCE値は引き続き拒否）。S256サポート自体は維持・広告し続ける |
| `refresh-token` | ON | token endpoint が `refresh_token` grant を `unsupported_grant_type` で拒否（core新オプション `supportedGrantTypes`）。authorize は `isOfflineAccessGranted: () => false` で offline_access 要求を無視（OIDC Core §11の「無視」挙動）。`issueRefreshToken` は常に false。RT永続化ブロック・refreshTokenResolver 配線を生成しない。discovery は `grant_types_supported: ['authorization_code']`、`scopes_supported` から `offline_access` を除去 |
| `introspection` | ON | `routes/introspection.ts` を生成しない。`app.ts` のマウント・apply系のエンドポイント列から `/introspect` を除去。resolvers.ts から introspection 用 resolver を除去。discovery から `introspection_endpoint` 系を除去 |
| `revocation` | ON | `routes/revocation.ts` を生成しない。`/revoke` マウント除去。resolvers.ts から revocationResolvers を除去。discovery から `revocation_endpoint` 系を除去 |
| `request-object` | ON | authorize が `request` パラメータを `request_not_supported` で拒否（OIDC Core §6.3、core新オプション）。discovery `request_parameter_supported: false`、`request_object_signing_alg_values_supported` 除去。`config.ts` から `allowUnsignedRequestObject` を除去 |

トグル対象外（Basic OP必須のため常に生成）: authorize / token / userinfo / discovery / jwks / login / consent。

### 設計上の割り切り

- `store.ts` は feature に関わらず現行のまま生成する（`RefreshTokenStore` 含む）。
  ストアは汎用インフラであり、refresh-token OFF でも introspection / revocation の resolver が
  RTストアを一様に参照できる方が feature 間の組合せ爆発を防げる。RTが発行されないので実害はない。
- デフォルト（全機能ON）の生成出力は現行と**完全一致**させる。samples / E2E / conformance の
  既存資産に差分を出さないことを保証する。

## CLIインターフェース

```
maronn-oidc generate hono --disable refresh-token,introspection
maronn-oidc setup express --disable request-object --disable revocation
maronn-oidc generate hono --enable pkce   # 明示有効化（将来のデフォルトOFF機能にも対応）
```

- `--enable <list>` / `--disable <list>`: カンマ区切り、複数回指定可。
- 未知の機能名 → エラー（利用可能な機能一覧を表示）。
- 同一機能を enable と disable の両方に指定 → エラー。
- 生成完了サマリに有効/無効の機能一覧を表示する。

## ファイル構成

### packages/cli

- `src/features.ts`（新規）: `AVAILABLE_FEATURES`, `FeatureName`, `OidcFeatureConfig`（camelCaseのboolean群）, `DEFAULT_FEATURES`, `resolveFeatures({enable, disable})`
- `src/generator.ts`: `GenerateOptions.features?: OidcFeatureConfig` を追加（未指定は DEFAULT_FEATURES）
- `src/frameworks/types.ts`: `GeneratorOptions.features: OidcFeatureConfig` を追加
- `src/index.ts`: `--enable` / `--disable` のパース、usage更新、サマリ表示
- `src/frameworks/hono/templates.ts`: 各テンプレート関数に features を渡し条件分岐
- `src/frameworks/hono/index.ts`: introspection / revocation ファイルの条件付き生成
- `src/frameworks/web-standard/templates.ts`: 同上（webApp / apply / nextjs route一覧 / webConformanceTestTemplate）
- `src/frameworks/express/index.ts`, `fastify/index.ts`, `nextjs/index.ts`: features伝播
- `README.md`: 機能オプションの説明を追加

### packages/core（機能分割）

- `src/token-error.ts`（新規）: `TokenErrorCode`, `TokenError`（循環import回避のため分離）
- `src/token-request.ts`: 型定義 + `validateTokenRequest`（共通検証: grant_type / supportedGrantTypes / クライアント認証 / クライアント別grant認可 → 各grant関数へディスパッチ）。`TokenError` 等は再exportして互換維持
- `src/authorization-code-grant.ts`（新規）: `validateAuthorizationCodeGrant(context)` — code存在/再利用/クライアント一致/期限/redirect_uri/PKCE検証
- `src/refresh-token-grant.ts`（新規）: `validateRefreshTokenGrant(context)` — RT存在/再利用/クライアント一致/絶対寿命/アイドル/scope縮小
- `src/token-request.ts` 新オプション: `TokenRequestContext.supportedGrantTypes?: string[]`（既定 `['authorization_code','refresh_token']`、非対応grantは `unsupported_grant_type`）
- `src/authorization-request.ts`:
  - 新オプション `requestObject.supported?: boolean`（既定 true。false かつ `request` 提示 → redirect解決後に `request_not_supported` を redirectable で送出）
  - 内部を機能単位の関数へ分割（`resolveClientForAuthorization` / `processRequestObject` / `validateResponseTypeForClient` / `validateScopeParam` 等）。公開シグネチャと挙動は不変
- `src/index.ts`: `validateAuthorizationCodeGrant` / `validateRefreshTokenGrant` をexport追加

## データの流れ

```
CLI引数 (--enable/--disable)
  → resolveFeatures() → OidcFeatureConfig
  → generate({ framework, outputDir, corePackageName, features })
  → generator.generate({ ..., features })
  → 各テンプレート関数(corePkg, features)
      - ルートファイルの生成有無（introspection / revocation）
      - config既定値（pkce / request-object）
      - core関数へ渡すオプション（supportedGrantTypes / requestObject.supported / isOfflineAccessGranted）
      - discoveryメタデータの構成
      - conformance.test.ts のテストブロック構成
```

## conformance.test.ts の生成方針

feature OFF のときは「その機能が無効であること」を固定するテストを生成する（利用者が意図せず想定挙動から外れたことを検知できるようにする）。

- `refresh-token` OFF: `grant_type=refresh_token` → `unsupported_grant_type`（400）を固定。reuse-cascadeブロックはコード再利用（AT失効カスケード）のみの変種に差し替え。discovery の `grant_types_supported: ['authorization_code']` と `scopes_supported`（offline_accessなし）を固定
- `introspection` OFF: `/introspect` → 404 を固定。discovery `introspection_endpoint` undefined を固定。nbfブロックは生成しない
- `revocation` OFF: `/revoke` → 404 を固定。discovery `revocation_endpoint` undefined を固定
- `request-object` OFF: `request` パラメータ → `request_not_supported` redirect を固定。discovery `request_parameter_supported: false` を固定。RO署名セットアップは生成しない（request_uri拒否テストは維持）
- `pkce` OFF: code_challenge なしの authorize（confidential client）がエラーにならず /login へ302すること、非PKCEのフル認可フロー（authorize→login→consent→token）が成功することを固定

## テスト計画（TDD）

1. core: `supportedGrantTypes` / `requestObject.supported: false` / 分割後grant関数の単体テスト（既存テストは全て無変更で通ることが分割の回帰保証）
2. cli: `features.ts` の resolveFeatures 単体テスト（既定・enable/disable・未知名エラー・競合エラー）
3. cli: generator/framework テストで feature別のファイル一覧・生成内容マーカー（例: disable introspection → `routes/introspection.ts` なし、app.tsにマウントなし、discoveryにendpointなし、conformanceに404テストあり）
4. cli: デフォルト生成が現行スナップショットと一致（既存テストが担保）
5. samples: `pnpm run generate` 再実行で差分ゼロ（check-generated）
6. E2E: デフォルト出力不変のため既存E2Eで担保（新規E2Eは追加しない。理由は完了レポートに記載）

## 設計協議の結果（確定設計メモ）

Codex CLI が実行環境に存在しなかったため（`codex` コマンド不在）、/design-discussion の
Codex協議は実施できず、Claudeによる批判的セルフレビューで代替した。主な論点と判断:

- [ALTERNATIVE検討] 「コードは常に全部生成し、configフラグだけで無効化する」案 → 不採用。
  依頼の主旨は生成コードから機能を「減らせる」ことであり、無効な機能のエンドポイントが
  マウントされたまま残るのは feature removal の意味論に反する。
- [CONCERN] feature間の組合せ（refresh-token OFF × introspection ON 等）で resolver が
  壊れる懸念 → store.ts を不変とする割り切りで解消（RTストアは空のまま一様に参照可能）。
- [CONCERN] 公開する grant 単位関数がクライアント別 grant 認可を含まない点 → JSDocで
  「フルの検証経路は validateTokenRequest」と明記して解消。
- [CONCERN] 巨大テンプレート文字列への条件挿入で可読性悪化 → 条件断片をヘルパー関数化。

## 懸念点・トレードオフ

1. hono/web-standard のテンプレートが巨大な文字列関数のため、条件分岐の挿入は文字列組み立ての可読性を悪化させる。→ 条件断片を小さなヘルパー関数（`introspectionImportFragment(features)` 等）に切り出して抑制する
2. refresh-token OFF でも store.ts に RefreshTokenStore が残る。→ 上記「設計上の割り切り」参照
3. 非デフォルト構成の生成コードはこのリポジトリのCIでは実行されない（samplesは常にデフォルト）。→ 生成内容のマーカー検証と、生成された conformance.test.ts 自体が利用者側で契約テストとして機能することで担保
4. `--enable` は現状すべて既定ONのため実質no-op。→ 将来のデフォルトOFF機能（例: DPoP）への布石として対称性を維持
