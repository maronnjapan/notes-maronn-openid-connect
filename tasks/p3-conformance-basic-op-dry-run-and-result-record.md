# [P3] Basic OP Conformance のドライランを 4 サンプルで実行し、結果を記録する運用を作る

## ステータス

🟡 Medium / 未着手

## 背景

`tests/conformance/` には OIDF Conformance Suite を **セルフホストで実行するハーネスが実装済み**である。

- `pnpm run conformance:basic-op` で、公式 prebuilt Docker image と公式 `run-test-plan.py` runner を使って Basic OP プランを実行できる
- 選択プランは `oidcc-basic-certification-test-plan[server_metadata=discovery][client_registration=static_client]`
- `CONFORMANCE_SAMPLE_APP` で `hono-cloudflare`（既定）/ `express-flyio` / `fastify-flyio` / `nextjs-vercel` を切り替えられる
- nginx リバースプロキシで OP を HTTPS 終端するため、**公開 HTTPS エンドポイントを用意せずにドライランできる**
- 結果 ZIP は `tests/conformance/results/` に出力される

しかし **実行した結果がリポジトリのどこにも記録されていない**。「Fidelity（Conformance 準拠を信頼性のシグナルとして維持する）」を差別化 3 軸の 1 つに掲げている以上、走らせる仕組みがあるのに結果が残っていない状態は主張の裏付けとして弱い。

また、`study-material/basic-op-requirement-traceability.md` の状態列は静的監査の結果であり、Suite の実行結果と突き合わせる運用が定義されていない。

本タスクは `study-material/basic-op-conformance-verification-plan.md` の**方針 A（ドライランを実行し、結果の要約をリポジトリに残す）**を実施する。方針 B（CI での定期実行）と方針 C（正式認定申請）は範囲外とする。

## 対象ファイル

- `tests/conformance/results/`（実行時の出力先。`.gitignore` 対象かを確認すること）
- 結果要約の記録先（新規。配置は下記「修正方針」で決める）
- `study-material/basic-op-requirement-traceability.md`（Suite 検証済みであることを表す記法の追加）
- `tests/conformance/README.md`（結果記録の運用手順の追記）

## 仕様参照

- **OpenID Conformance Suite** — https://www.certification.openid.net/ （公式実行環境）
- **Conformance Suite ソース** — https://gitlab.com/openid/conformance-suite （セルフホスト実行と `run-test-plan.py` runner）
- **OpenID Certification** — https://openid.net/certification/ （正式認定の申請フロー。本タスクは申請の前段）
- **OpenID Connect Core 1.0 §15.1 Mandatory to Implement Features for All OpenID Providers** — https://openid.net/specs/openid-connect-core-1_0.html#ServerMTI （Basic OP テストが検証する要件の一次情報）
- 本リポジトリ内: `tests/conformance/README.md`、`tests/conformance/scripts/run-basic-op.sh`、`tests/conformance/manual-review-screenshots.md`、`study-material/basic-op-conformance-verification-plan.md`

## 現状の実装

`tests/conformance/` の構成:

```
tests/conformance/
├── README.md                          # 実行手順・選択プラン・対象サンプル
├── docker-compose.yml                 # Suite + OP + nginx
├── nginx/op-tls.conf                  # OP の HTTPS 終端
├── runner.Dockerfile
├── manual-review-screenshots.md       # 手動レビュー項目
└── scripts/
    ├── run-basic-op.sh                # 実行の実体
    ├── create-basic-op-config.mjs     # static client 設定の生成
    ├── create-basic-op-config.test.mjs
    └── ensure-op-tls-cert.sh
```

ルートの `test:ci` は `pnpm run test:conformance` を含むが、これは `create-basic-op-config.mjs` の**単体テスト**であり、Suite 本体の実行ではない（Docker を要求するため）。

問題:

- 実行結果が記録されていないため、「今どのモジュールが通っていて、どれが落ちているか」を誰も把握していない
- 4 サンプル間で結果が一致するかも未確認。フレームワーク派生（`study-material/done/cli-web-standard-template-derivation-contract.md`）が挙動を壊していないことの最上位の検証になりうるのに、活用されていない

## 修正方針

- [ ] **前提の確認**
  - [ ] `tasks/p3-basic-op-conformance-module-list-confirmation.md` の完了状況を確認する（プランに含まれるモジュール一覧と、手動確認を要するモジュールの識別）
  - [ ] `tests/conformance/results/` が `.gitignore` されているかを確認する。結果 ZIP 自体はコミットせず、**要約テキストのみ**を残す方針とする
- [ ] **ドライランの実行**
  - [ ] `pnpm run conformance:basic-op`（既定 = `hono-cloudflare`）
  - [ ] `CONFORMANCE_SAMPLE_APP=express-flyio pnpm run conformance:basic-op`
  - [ ] `CONFORMANCE_SAMPLE_APP=fastify-flyio pnpm run conformance:basic-op`
  - [ ] `CONFORMANCE_SAMPLE_APP=nextjs-vercel pnpm run conformance:basic-op`
- [ ] **結果要約の記録先を決めて作成する**
  - 候補: `tests/conformance/` 配下に `RESULTS.md` を新規作成する / `docs/` 配下 / `study-material/` 配下。**`tests/conformance/` 配下が最も近い**（実行手順と同じ場所で追える）
  - [ ] 記録項目: 実行日 / 対象コミットハッシュ / サンプル名 / Suite image のタグ or バージョン / プラン ID / Pass 数 / Fail 数 / Warning 数 / 手動レビュー待ち数 / Fail したモジュール名の一覧
  - [ ] 4 サンプル分を 1 つの表にまとめ、サンプル間で結果が割れている場合はそれが分かるようにする
- [ ] **Fail の棚卸し**
  - [ ] Fail したモジュールがあれば、原因を特定して `tasks/` 配下に個別タスクとして切り出す（本タスクでは修正まで行わない）
  - [ ] 既存の study-material / tasks で既に扱っている論点であれば、そのファイルへの参照を要約に添える
- [ ] **traceability との突き合わせ**
  - [ ] `study-material/basic-op-requirement-traceability.md` のマトリクスに、「Suite で検証済み」を表す記法（列の追加 or 記号）を導入するかを決め、導入する場合は反映する
- [ ] **README への運用追記**
  - [ ] `tests/conformance/README.md` に「実行したら結果要約を更新すること」と、要約の記載項目を追記する

## テスト要件

本タスクは実行と記録が主であり、コード変更を伴わない可能性が高い。確認項目は次のとおり。

- [ ] 4 サンプルすべてでハーネスが最後まで完走する（Suite の Pass/Fail とは別に、**ハーネス自体が落ちない**こと）
- [ ] 完走しないサンプルがある場合、その原因（ビルド失敗 / 起動失敗 / TLS / ポート衝突）を要約に記録する
- [ ] `pnpm --filter @maronn-openid-connect/conformance test`（設定生成スクリプトの単体テスト）が通る
- [ ] 記録した要約に、上記「記録項目」がすべて含まれている

## 完了条件

- [ ] 4 サンプル分のドライラン結果要約がリポジトリに記録されている（実行日・コミットハッシュ付き）
- [ ] Fail したモジュールがあれば、`tasks/` に個別タスクとして切り出されている（0 件なら「Fail なし」と要約に明記）
- [ ] `tests/conformance/README.md` に結果記録の運用が追記されている
- [ ] `study-material/basic-op-conformance-verification-plan.md` の §9 タスク案のうち、本タスクが担当する項目にチェックが入っている
