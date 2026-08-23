# [P2] CI サプライチェーンセキュリティゲートと provenance 確証

## ステータス

🟠 High（セキュリティ・運用）/ ローカル実装・検証済み、外部確認待ち（2026-07-22）

> CI 設定、Dependabot 設定、publish 後の正確な name/version に対する SLSA provenance 検証、
> 検証スクリプトの単体・正負統合テスト、手順書は実装済み。
> ただし npm 上で core / cli が未公開（E404）のため provenance 実績をまだ確認できず、
> Dependabot の有効化確認と CI の負のテストも本変更の merge 後に行う必要がある。

### 外部状態監査（2026-07-22）

- GitHub のリモート `main` には本変更の `.github/dependabot.yml` がまだ存在せず、リポジトリの vulnerability alerts も無効だったため、Dependabot の認識・稼働は未確認。
- リモート `main` の現行 HEAD には、本変更を含む PR CI 実行履歴がないため、追加した dependency-review / audit ジョブの GitHub Actions 上の正負確認は未実施。
- npm registry では `@maronn-openid-connect/core` / `@maronn-openid-connect/cli` が E404 のため、対象パッケージ自身の publish 後 provenance は確認不能。
- 以上はローカルコードでは解消できない merge・リポジトリ設定・初回 publish 後の確認事項であり、完了条件を満たすまでは `tasks/done` へ移動しない。

> Basic OP 認定要件ではなく、OSS 配布物の完全性・依存健全性を担保する運用タスク。
> 検討の全体像は `study-material/done/supply-chain-security-and-release-integrity.md` を参照。
> 本タスクは、方針が確定している**加算的かつ相互排他でない**サブセット（provenance 確証 / 依存監査 / 依存自動更新）に限定する。SBOM 生成（CycloneDX）と CodeQL は方針未確定のため本タスクには含めず study-material に残す。

## 背景

`@maronn-openid-connect/core` / `cli` は認証・認可の中核ライブラリであり、配布物が侵害されると下流の全システムのアイデンティティ基盤が一括で危殆化する。プロトコル準拠（Basic OP）とは別軸で、配布物の完全性と依存の健全性を継続検査する必要がある。

現状:

- `release.yml` は npm Trusted Publishing(OIDC) を利用し、コメント上は provenance 自動付与を前提とするが、**実際に provenance が公開されたかを確認・検証する手順／ステップが無い**。
- `ci.yml` は Unit/Integration/Conformance/E2E のみで、**`pnpm audit` / dependency-review が無い**。
- **`.github/dependabot.yml` が無い**（依存自動更新が未設定。`.github/` 配下は `workflows/` のみ）。

prod 依存ゼロ方針のため攻撃面は小さいが、対策コストも低く費用対効果が高い。

## 対象ファイル

- `.github/workflows/ci.yml`（依存監査・dependency-review ステップ追加）
- `.github/workflows/release.yml`（provenance 確証ステップ／コメント追記）
- `.github/dependabot.yml`（新規作成: npm + github-actions エコシステム）
- `RELEASE.md`（provenance 確認手順の追記）
- `README`（セキュリティ姿勢の記載。任意）

## 仕様参照

- npm provenance — https://docs.npmjs.com/generating-provenance-statements
- npm Trusted Publishing — https://docs.npmjs.com/trusted-publishers
- SLSA Build Provenance — https://slsa.dev/spec/v1.0/levels
- GitHub Dependency Review Action — https://github.com/actions/dependency-review-action
- GitHub Dependabot 設定 — https://docs.github.com/code-security/dependabot
- 関連分析: `study-material/done/supply-chain-security-and-release-integrity.md`

## 現状の実装

- `.github/workflows/ci.yml`: `pnpm install --frozen-lockfile` 後に test:ci / E2E を実行。依存脆弱性チェックは無し。型チェック・Lint は `# TODO` でコメントアウト。
- `.github/workflows/release.yml`: `permissions: {}` 既定、ジョブで `id-token: write` / `contents: write`。`pnpm run ci:publish`（`changeset publish`）で OIDC publish。provenance 検証ステップは無し。
- `.github/` 配下に `dependabot.yml` は存在しない。
- `packages/core` / `packages/cli` に prod `dependencies` は無い（攻撃面は devDependencies に限定）。

問題: 「provenance あり」が未確認のまま運用され得る／devDependencies の既知脆弱性が CI で検知されない／依存追従が手動。

## 修正方針

- [ ] **provenance 確証（方針C）**: 次回 publish 後に npm パッケージページ（core / cli）で provenance バッジ・attestation の有無を確認する。`release.yml` は Changesets が返した正確な name/version を一時環境へインストールし、`npm audit signatures --json --include-attestations` の結果に各 package/version の SLSA v1 provenance があることを明示検証する。初回 publish 前のため npm 上の実績確認のみ未完了。
- [x] `RELEASE.md` に「provenance が付いていることの確認手順」を追記する。
- [x] **依存監査（方針A）**: `ci.yml` の PR ジョブに `pnpm audit --audit-level=high` を追加する。
- [x] **dependency-review（方針A）**: PR に `actions/dependency-review-action` を追加し、新規導入依存の高重大度脆弱性を審査する（`pull_request` トリガ、`permissions.contents: read`）。
- [x] **依存自動更新（方針D）**: `.github/dependabot.yml` を新規作成し、`npm`（ルート + 各 workspace）と `github-actions` エコシステムを対象に週次更新を設定する。
- [ ] README にセキュリティ姿勢（prod 依存ゼロ・Trusted Publishing・provenance・依存監査）を記載する（任意）。
- [x] 本タスクが Basic OP 認定要件外である旨を `study-material/basic-op-requirement-traceability.md` の運用メモに残す（混同防止）。

実装例（`.github/dependabot.yml` の骨子）:

```yaml
version: 2
updates:
  - package-ecosystem: "npm"
    directory: "/"
    schedule:
      interval: "weekly"
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
```

実装例（`ci.yml` への dependency-review 追加の骨子）:

```yaml
  dependency-review:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@v6
      - uses: actions/dependency-review-action@v4
        with:
          fail-on-severity: high
```

## テスト要件

CI 設定変更のため、テストは「ワークフローが期待通り発火・成功/失敗すること」の確認が中心になる。

- [x] provenance 判定の単体テストで、全 package/version の SLSA v1 attestation を受理し、署名のみ・別 version・非 SLSA attestation を拒否すること。
- [x] 公開済みパッケージを使ったローカル統合テストで、provenance なし（registry signature のみ）が失敗し、SLSA provenance ありが成功すること。
- [x] `pnpm audit --audit-level=high` が High 以上の既知脆弱性なしで成功すること。
- [ ] `dependabot.yml` が GitHub に認識され、Dependabot 設定エラーが出ないこと（リポジトリの Insights → Dependency graph → Dependabot で確認）。
- [ ] 既知の高深刻度脆弱性を持つ依存を一時的に追加した PR で `dependency-review` / `pnpm audit` ジョブが**失敗する**こと（負のテスト）。
- [ ] 通常の PR では新ジョブがすべて成功すること（誤検知でグリーンを妨げないこと）。
- [ ] publish 実行後、core / cli の npm ページに provenance が表示されること（手動確認・スクリーンショットを PR/Issue に残す）。

## 完了条件

- `.github/dependabot.yml` が追加され、Dependabot が有効。
- `ci.yml` に依存監査（`pnpm audit`）と `dependency-review` ジョブが追加され、PR で実行される。
- provenance の有無が確認され、欠落していれば是正済み。確認手順が `RELEASE.md` に記載されている。
- 既存の `pnpm run test:ci` / `pnpm run test:e2e` が引き続きパスすること。
