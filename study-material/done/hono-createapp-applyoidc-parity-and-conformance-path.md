# Hono 生成テンプレートの `createApp` / `applyOidc` 機能差と conformance.test の検証経路

## ステータス

🟠 High / 未着手

## 1. このトピックで確認したいこと

Hono フレームワーク用のコード生成テンプレートには、OP を組み立てる 2 系統のエントリポイントがある。

- `createApp`（`app.ts` として生成されるスタンドアロン経路）
- `applyOidc`（既存 Hono アプリに OIDC を後付けする経路）

このうち `applyOidc` は `acrResolver` / `corsOrigins`（CORS + OPTIONS プリフライト）/ 分離署名鍵プロバイダを
サポートするのに対し、`createApp` はこれらを**オプションとして受け付けず、コンテキストにも set しない**。
そのため `createApp` 経由で起動した OP は `acr_values` を honor できず（ID Token に `acr` が載らない）、
CORS/OPTIONS も無いためブラウザ／SPA クライアントから token/userinfo を呼べない。

さらに Hono の `conformance.test.ts` は**この機能不足側の `createApp` を検証しており**、
実際の `samples/hono` が使うのは機能の揃った `applyOidc` である。つまり契約テストが「実デプロイと異なる経路」を
認証してしまっており、ACR/CORS の挙動を一切アサートしていない。

本ファイルは、Hono の 2 エントリポイントの機能差と、conformance.test の検証経路の乖離を整理し、
パリティを取るか検証経路を揃えるかを検討する。

> 関連既存ファイル（重複回避）：
> - `study-material/cors-cross-origin-support.md`: CORS の**一般方針**（どのエンドポイントに何を許可するか）を扱う。
>   本ファイルは **Hono の createApp だけが CORS/acrResolver を欠く framework-parity の乖離**という固有差分。
> - `study-material/cli-framework-portability-and-web-standard-handler.md`: Web 標準ハンドラの移植性を扱う。
> - `study-material/done/cli-generated-output-conformance-ci.md`: 生成物と CI の整合を扱うが、
>   **Hono の createApp/applyOidc 二重テンプレートと conformance の経路乖離**は扱っていない。
> 本ファイル固有の論点は「**Hono の主要スタンドアロン経路（createApp）を他フレームワーク（web-standard の createApp）や
> applyOidc とパリティにし、conformance.test が実デプロイ経路を検証する**」こと。

## 2. 関連する仕様・基準

- **OpenID Connect Core 1.0 §3.1.2.1（`acr_values`）/ §2（`acr`）**: `acr_values` が要求されたら、
  OP は可能な範囲で対応する `acr` を ID Token に反映する。OIDF の conformance モジュール
  `oidcc-ensure-request-with-acr-values-succeeds` はこの挙動を検証する。
- **OpenID Connect Discovery / UserInfo をブラウザから呼ぶ前提（OAuth 2.0 for Browser-Based Apps）**:
  SPA からトークン／UserInfo を呼ぶには CORS（`Access-Control-Allow-Origin`）と OPTIONS プリフライト対応が要る。
- **本リポジトリの契約テスト方針（CLAUDE.md）**:
  > conformance.test.ts はOPの結合テストであり、実際にリクエストがあった際の挙動を全て網羅する。
  > 直接変更せず、`packages/cli` 内の生成コードを変更する。
  - 契約テストが「実デプロイと異なる経路」を検証していると、この方針の目的（利用者が想定挙動から外れたら
    テスト失敗で気付ける）が果たされない。

## 3. 参照資料

- OpenID Connect Core 1.0 §3.1.2.1 / §2（`acr_values` / `acr`）: https://openid.net/specs/openid-connect-core-1_0.html
- OAuth 2.0 for Browser-Based Apps（CORS 前提）: https://datatracker.ietf.org/doc/html/draft-ietf-oauth-browser-based-apps
- OIDF Conformance（Basic OP, `acr_values`）: https://openid.net/certification/conformance-testing-for-openid-connect/
- 本リポジトリ CLAUDE.md「samplesディレクトリの各フレームワークディレクトリ内にあるconformance.test.tsについて」

## 4. 現在の実装確認

- `packages/cli/src/frameworks/hono/templates.ts`
  - `CreateAppOptions`（`:41-78` 付近）: `acrResolver` / `corsOrigins` / 分離署名鍵プロバイダのフィールドが**無い**。
  - `createApp`（`:84-136` 付近）: `c.set('acrResolver', ...)` を呼ばず、`cors()` / OPTIONS も設定しない。
  - token ルート（`:1496` 付近）は `c.get('acrResolver')` を読むが、`createApp` 経路では常に `undefined`。
  - `applyOidc`（`:2465` 付近）: `acrResolver`（`:2426`）・`corsOrigins`（`:2443`, `:2469-2486`）を受け付け wiring する。
- 対照: `packages/cli/src/frameworks/web-standard/templates.ts` の `createApp`
  （`:375`, `:448-450`, `:389-407`, `:482-499` 付近）は `acrResolver` と CORS/OPTIONS を単一の createApp で wiring 済み。
- `samples/hono/src/app.ts`（`:58`, `:72-73` 付近）は `applyOidc(...)` を `acrResolver` / `corsOrigins` 付きで使用。
- Hono の `conformance.test.ts`（生成元 `hono/templates.ts:3265`, `:3316` 付近）は `createApp` を import して駆動し、
  ACR / CORS / OPTIONS に関するアサーションが 0 件。

## 5. 現在の実装との差分

- **満たしていること**
  - `applyOidc` 経路、および実 `samples/hono` は acr/CORS を含めて機能が揃っている。
  - authorize / token / userinfo / jwks / discovery / introspection / revocation の各エンドポイント wiring 自体は全経路で存在。
- **不足している可能性があること**
  - Hono `createApp`（主要スタンドアロン経路）だけが `acrResolver` と CORS/OPTIONS を欠く（他フレームワークの
    単一 createApp と非対称）。
  - conformance.test が `createApp` を検証しており、実デプロイ経路（`applyOidc`）と乖離。ACR/CORS が未アサート。
- **相互運用性 / Basic OP 観点**
  - `createApp` を採用した利用者は `acr_values` を honor できず、SPA からのクロスオリジン呼び出しもできない。
    OIDF conformance の `acr_values` モジュールや browser CORS 前提で非適合になりうるが、契約テストが検知しない。

## 6. 改善・追加を検討する理由

- **契約テストの信頼性**: 本リポジトリは conformance.test.ts を「利用者が想定挙動から外れたら失敗で気付く契約」と
  位置づけている。検証経路が実デプロイと違うと、その契約が空洞化する。
- **framework parity（移植性）**: 差別化軸の Portability に直結。全フレームワークの標準エントリポイントで
  同じ機能セットが揃っていることが、利用者にとっての一貫性になる。
- **導入しやすさ**: `applyOidc` に既に実装済みの wiring を `createApp` に移す（または `createApp` を
  `applyOidc` の薄いラッパにする）だけで、ロジックの新規実装は不要。
- **実装しない場合のリスク**: `createApp` を採用した利用者が ACR/CORS 非対応の OP を「テストは通っている」状態で
  デプロイし、conformance や本番 SPA 連携で初めて破綻に気付く。

## 7. 実装方針の候補

判断材料の整理（最終判断は人間）。

- 方針A（推奨・パリティ）: Hono `createApp` に `acrResolver` / `corsOrigins`（CORS + OPTIONS）/
  分離署名鍵プロバイダを追加し、web-standard の単一 createApp や applyOidc と機能を揃える。
- 方針B（経路統一）: `createApp` を `applyOidc` の薄いラッパとして再実装し、二重メンテを解消。
  生成 `app.ts` は `createApp` を呼ぶだけにして、実体は `applyOidc` に集約。
- 方針C（検証経路の是正）: conformance.test が実デプロイ経路（`applyOidc` ベース）を検証するよう生成コードを変更し、
  ACR/CORS/OPTIONS のアサーションを追加。方針A/B と併用するのが望ましい。
- いずれも `packages/cli` のテンプレートを変更し、`samples/hono` の再生成・conformance テスト更新を伴う。

## 8. タスク案

- [ ] Hono `conformance.test.ts`（生成元）に ACR（`acr_values` 要求で ID Token に `acr` が載る）と
      CORS/OPTIONS（token/userinfo のプリフライトに `Access-Control-Allow-Origin` が返る）のアサーションを追加（Red）
- [ ] 方針 A または B で Hono `createApp` に `acrResolver` / `corsOrigins` / 分離署名鍵プロバイダを wiring（Green）
- [ ] conformance.test が実デプロイ経路（`applyOidc` 相当）を検証するよう生成コードを是正
- [ ] `samples/hono` を再生成し、`createApp`／`applyOidc` の機能差が無いことを確認
- [ ] 他フレームワーク（express / fastify / nextjs）でも createApp 相当が acr/CORS を wiring しているか横断確認
- [ ] 完了条件: `pnpm --filter @maronn-openid-connect/cli test` と `samples/hono` の conformance テストがパス
