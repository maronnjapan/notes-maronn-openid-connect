# Basic OP Conformance 検証計画（OIDF Conformance Suite 実行手順の整理）

> **更新履歴 / 現状注記**
> 本ファイルの初版は「OIDF Conformance Suite を走らせる段取りがまだ何も無い」状態を前提に書かれていた。
> その後 `tests/conformance/` に **セルフホスト Suite の実行ハーネスが実装済み**（`pnpm run conformance:basic-op`）であり、
> 初版の §5 / §6 / §8 の記述は現状と食い違っていた。以下は現状に追随させた内容である。
> 旧記述が挙げていた「公開 HTTPS 到達性が無いので実行不可」というブロッカーは、ローカル Docker ネットワーク内で
> TLS 終端する構成によって**ドライランの範囲では解消済み**である。

## 1. タイトル

OpenID Foundation 公式 Conformance Suite を用いて、本リポジトリが Basic OP 認定を実際に通過できるかを検証するための準備・実行計画。

## 2. このトピックで確認したいこと

`study-material/basic-op-requirement-traceability.md` は静的監査（要件 → 実装の机上対応）であるのに対し、本ファイルは **動的検証**（実際に OIDF Conformance Suite を走らせて Pass/Fail を取る）に必要な前提・障害・段取りを整理する。

- どのテストプランを選ぶか
- 現在のハーネス（`tests/conformance/`）でどこまで自動化されており、何が残っているか
- ローカルドライランと、**正式認定申請**（`certification.openid.net` での公開実行 + 申請）の間に残る差分は何か
- 検証を「いつ」やるかは `study-material/RELEASE-v0.x-scope.md`（Conformance は v1.0 条件、v0.x のブロッカーにしない）に従う。本ファイルは「やる時の手順」に限定する

## 3. 関連する仕様・基準

仕様セクションの共通説明は `study-material/basic-op-requirement-traceability.md` の「関連する仕様・基準」を参照（重複記載回避）。本トピック固有の差分のみ記載する。

- OIDF Conformance Suite は **テストプラン単位**で実行する。本リポジトリが選択しているプランは次のとおり（`tests/conformance/README.md` に記載）:

  ```text
  oidcc-basic-certification-test-plan[server_metadata=discovery][client_registration=static_client]
  ```

  - `server_metadata=discovery`: OP の `/.well-known/openid-configuration` を起点にエンドポイントを発見する
  - `client_registration=static_client`: 動的登録（DCR）を使わず、Suite 側にクライアント設定を渡す
- Suite からの **クライアント登録方法**は 2 系統:
  - 動的登録（OpenID Connect Dynamic Client Registration 1.0）— 本リポジトリ **未対応**（`study-material/ext-dynamic-client-registration.md`）
  - 静的登録 — 本リポジトリが採る経路。上記プラン ID の `client_registration=static_client` がこれにあたる
- Suite はテスト対象エンドポイントへ到達する必要があり、**TLS（HTTPS）が必須**。OAuth 2.1 / OIDC Core もエンドポイントの TLS を要求する

## 4. 参照資料

- **OpenID Conformance Suite（公式ホスト）** — https://www.certification.openid.net/ （正式実行環境・テストプラン選択）
- **Conformance Suite ソース** — https://gitlab.com/openid/conformance-suite （セルフホスト実行と `run-test-plan.py` runner の根拠）
- **OpenID Certification 手続き** — https://openid.net/certification/ （正式認定の申請フロー。認定は自己認証 + 申請の形式）
- **OpenID Connect Core 1.0 §3.1 / §15.1** — テスト対象要件（詳細は traceability ファイル参照）
- 本リポジトリ内:
  - `tests/conformance/README.md`（実行手順・選択プラン・対象サンプルの一次情報）
  - `tests/conformance/scripts/run-basic-op.sh`（実行の実体）
  - `tests/conformance/scripts/create-basic-op-config.mjs`（static client 設定の生成）
  - `tests/conformance/docker-compose.yml` / `tests/conformance/nginx/op-tls.conf`（Suite と OP の TLS 終端構成）
  - `study-material/RELEASE-v0.x-scope.md`（検証タイミングの戦略的位置づけ）

## 5. 現在の実装確認

### 5.1 実行ハーネス（実装済み）

`tests/conformance/` に、セルフホスト Suite で Basic OP プランを走らせる一式が存在する。

- **エントリポイント**: リポジトリルートの `pnpm run conformance:basic-op`（= `pnpm --filter @maronn-openid-connect/conformance basic-op` → `bash scripts/run-basic-op.sh`）
- **Suite 本体**: 公式の prebuilt Docker image を使用し、公式の `run-test-plan.py` runner で実行する
- **対象 OP の選択**: `CONFORMANCE_SAMPLE_APP` 環境変数で `hono-cloudflare`（既定）/ `express-flyio` / `fastify-flyio` / `nextjs-vercel` を切り替えられる。すなわち **4 サンプルすべてが検証対象になりうる**
- **TLS**: `nginx/op-tls.conf` によるリバースプロキシで OP を HTTPS 終端する。既定の issuer は `https://op-tls:3443`、Suite は `https://conformance-nginx:8443`。いずれも Docker ネットワーク内のホスト名であり、**公開 HTTPS エンドポイントを用意せずにドライランできる**
- **static client 設定の生成**: `scripts/create-basic-op-config.mjs` が Suite の callback URL に合わせたクライアントメタデータを生成する。この生成ロジックには単体テスト（`create-basic-op-config.test.mjs`）があり、`pnpm --filter @maronn-openid-connect/conformance test` で実行される
- **結果**: `tests/conformance/results/` に結果 ZIP を出力する
- **手動確認事項**: `tests/conformance/manual-review-screenshots.md` に、Suite が要求する手動レビュー項目（スクリーンショット提出など）が整理されている
- **OP ロジックの非混在**: README は「`tests/conformance` 配下には OP ロジックを実装していない」と明記しており、CLAUDE.md の「`samples/*` には OP 以外の役割を混在させない」方針と整合している

### 5.2 CI との関係

- ルートの `test:ci` は `pnpm run test:conformance`（= `@maronn-openid-connect/conformance` の `node --test scripts/*.test.mjs`）を含む。ただしこれは **設定生成スクリプトの単体テスト**であり、**Suite 本体の実行ではない**
- Suite 本体の実行（`conformance:basic-op`）は Docker を要求するため、CI ゲートには含まれていない

### 5.3 生成 OP 側

- Discovery: `packages/cli/src/frameworks/hono/templates.ts` の discovery ルート（`samples/*/src/oidc-provider/routes/discovery.ts` はその生成物）
- 静的クライアント設定: 生成された `config.ts` の `RegisteredClient` 定義
- DCR エンドポイント: **存在しない**（`registration_endpoint` を広告しない）。選択プランが `client_registration=static_client` であるため、これはブロッカーにならない

## 6. 現在の実装との差分（検証実行の観点）

### 満たしていること

- ✅ **Suite をローカルで実行する経路が確立済み**。公開 HTTPS の準備なしにドライランできる
- ✅ **4 サンプル OP すべてを同じプランで検証できる**。フレームワークを跨いだ挙動同一性を Suite レベルで確認する土台がある
- ✅ **static client 設定の生成が自動化され、単体テストで固定されている**
- ✅ Authorization Code Flow / PKCE / RS256 ID Token / UserInfo / prompt 等、Basic OP 中核は実装済み（traceability マトリクス参照）
- ✅ 手動レビュー項目が文書として整理されている

### 不足している可能性があること / 要確認

- 🟡 **ドライラン結果が記録されていない**。`tests/conformance/results/` は実行時の出力先であり、リポジトリには「どのサンプルで、いつ、どのモジュールが Pass / Fail したか」の記録が無い。Fidelity 軸のシグナルにするには結果の要約をどこかに残す運用が要る
- 🟡 **traceability マトリクスへの反映経路が無い**。`study-material/basic-op-requirement-traceability.md` の状態列は静的監査の結果であり、Suite の実行結果と突き合わせる運用が定義されていない
- 🟡 **Basic OP プランのモジュール一覧が確定していない**。どのテストモジュールが含まれ、そのうちどれが手動確認を要するかは `tasks/p3-basic-op-conformance-module-list-confirmation.md` で追跡中。本ファイルはその完了を前提にする
- 🟡 **Suite 実行が CI に載っていない**。Docker 依存のため難しいが、定期実行（nightly / リリース前）にするかは判断事項
- 🟢 **正式認定との差分**: 認定申請には公式ホスト版 Suite（`certification.openid.net`）での実行と、公開到達可能な OP エンドポイントが必要になる。ローカルドライランはその前段であり、置き換えにはならない
- 🟢 **Discovery フィールドの整合**: `study-material/discovery-optional-metadata-fields.md` および `tasks/p3-discovery-*` 系タスクの完了状況は、実行前に確認しておく価値がある

## 7. 改善・追加を検討する理由

- traceability の机上監査だけでは「実際に通る」保証にならない。ハーネスが既にある以上、**実行して結果を残すコストは低い**
- 「Fidelity（Conformance 準拠を信頼性のシグナルとして維持する）」を差別化軸に掲げる以上、**結果の記録が無い状態は主張の裏付けとして弱い**
- 4 サンプルすべてで同じプランを走らせられるため、フレームワーク派生（`study-material/done/cli-web-standard-template-derivation-contract.md`）が挙動を壊していないことの最上位の検証にもなる
- 実施しない場合のリスク: 生成 OP に仕様逸脱が入っても、`conformance.test.ts`（自前の契約テスト）が見ていない範囲は誰も検知しない

## 8. 実装方針の候補

**最終判断は人間が行う。以下は判断材料の整理である。**

### 方針 A: ドライランを実行し、結果の要約をリポジトリに残す

- 内容: `pnpm run conformance:basic-op` を 4 サンプル分実行し、Pass / Fail / 手動確認待ちのモジュール数と、Fail したモジュール名を要約ファイルとして記録する
- 利点: コストが最も低く、現状把握が一気に進む。Fail が出れば具体的なタスクに落とせる
- 欠点: 結果は実行時点のスナップショットであり、放置すると陳腐化する（記録に日付とコミットハッシュを添える運用が要る）
- 記録先の候補: `tests/conformance/results/`（gitignore 対象か要確認）/ `study-material/` 配下 / `docs/` 配下。どこに置くかは判断事項

### 方針 B: 定期実行の仕組みを作る

- 内容: nightly もしくはリリース前ジョブとして Suite 実行を回す
- 利点: 退行を継続的に検知できる
- 欠点: Docker + Suite image のダウンロードで実行時間・リソースを消費する。CI 環境の制約次第

### 方針 C: 正式認定申請に進む

- 内容: 公式ホスト版 Suite で実行し、OIDF に認定を申請する
- 利点: 「Basic OP 認定済み」と正式に表明できる
- 依存: 公開到達可能な OP エンドポイントが必要。`study-material/RELEASE-v0.x-scope.md` の v1.0 条件に該当するため、時期の判断が先
- 欠点: 申請には手動レビュー項目の提出（`manual-review-screenshots.md`）が伴い、準備コストがある

### 方針 D: 現状維持（ハーネスは持つが実行しない）

- 利点: コストゼロ
- 欠点: 「Suite を走らせる仕組みはあるが、走らせた結果は誰も知らない」状態が続く

## 9. タスク案

- [ ] **ドライランの実行**: `pnpm run conformance:basic-op` を 4 サンプル（`hono-cloudflare` / `express-flyio` / `fastify-flyio` / `nextjs-vercel`）で実行し、結果を取得する
- [ ] **結果記録の運用決定**: 結果要約をどこに、どの粒度で残すかを決める（実行日・対象コミット・サンプル名・Pass/Fail/手動待ちのモジュール数・Fail モジュール名）
- [ ] **Fail の棚卸し**: Fail したモジュールがあれば、`tasks/` 配下に個別タスクとして切り出す
- [ ] **traceability との突き合わせ**: `study-material/basic-op-requirement-traceability.md` の状態列に「Suite で検証済み」を表現する列 or 記法を追加するか決める
- [ ] **モジュール一覧の確定**: `tasks/p3-basic-op-conformance-module-list-confirmation.md` の完了を待ち、本ファイルの前提として参照する
- [ ] **CI 方針の決定**: 方針 B（定期実行）を採るかを決める。採る場合はトリガー（nightly / リリース前 / 手動）を決める
- [ ] **正式認定の時期判断**: `study-material/RELEASE-v0.x-scope.md` の v1.0 条件と照らして、方針 C に進む時期を決める
