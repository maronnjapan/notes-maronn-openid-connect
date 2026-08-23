# サプライチェーンセキュリティとリリース完全性（provenance / SBOM / 依存監査）

## ステータス

🟠 High（セキュリティ・運用）/ 未着手

## 1. このトピックで確認したいこと

本リポジトリは **OpenID Provider を構築するための OSS ライブラリ**であり、`@maronn-openid-connect/core` / `@maronn-openid-connect/cli` として npm に publish される。
認証・認可の中核を担うライブラリが侵害されると、それを利用する全 PoC / 本番システムのアイデンティティ基盤が一括で危殆化する。したがって、**プロトコル層の正しさ（Basic OP 準拠）とは別軸で、「配布物そのものの完全性」と「依存・CI の健全性」を担保できているか**を確認したい。

具体的には:

- npm publish された成果物が **改ざんされていない／本当に本リポジトリの CI から出たものだ**と第三者が検証できるか（provenance / 来歴証明）
- 配布物の構成（依存ツリー）を **SBOM** として開示し、利用者が脆弱性照合できるか
- CI に **依存監査（`npm audit` / dependency review）・静的解析（CodeQL 等）・依存自動更新（Dependabot/Renovate）** が組み込まれているか
- `pnpm-lock.yaml` の固定とインストール再現性（`--frozen-lockfile`）が一貫して使われているか
- リリースワークフロー（OIDC Trusted Publishing）の権限が最小化されているか

本トピックは**プロトコル仕様（OIDC/OAuth）ではなく、OSS 配布のセキュリティ運用**を扱う。既存の運用系トピック（`study-material/audit-logging-and-observability.md`、`study-material/operational-health-readiness-endpoints.md`、`study-material/http-security-headers-and-tls.md`、`study-material/signing-key-rotation-operations.md`）はいずれも**実行時 OP の運用**を扱っており、**配布物・ビルドパイプラインのサプライチェーン**を扱うファイルは現時点で存在しない（重複なし）。

## 2. 関連する仕様・基準

OIDC/OAuth の仕様ではなく、ソフトウェアサプライチェーンの業界標準・一次資料を根拠とする。正確性のため、各基準が何を要求するかを明記する。

### 2.1 npm provenance（パッケージ来歴証明）

- npm は publish 時に **provenance attestation** を生成できる（`npm publish --provenance`、または OIDC Trusted Publishing 経由で自動付与）。これは「どの GitHub リポジトリの・どの workflow の・どの commit から・どのビルドで生成されたか」を **Sigstore（Fulcio/Rekor）** の透明性ログに署名付きで記録し、npm の各バージョンページに "Built and signed on GitHub Actions" として表示する仕組み。
- provenance は **SLSA（Supply-chain Levels for Software Artifacts）Build Level の証跡**に対応する。利用者は「配布 tarball が、改ざんされずに、宣言されたソースから出たこと」を検証できる。
- 本リポジトリの `.github/workflows/release.yml` 冒頭コメントは「provenance は Trusted Publishing 利用時に自動付与される」と記述しており、`permissions.id-token: write` も設定済み。**実際に provenance が付くかは publish 実行後の npm ページで要確認**（pnpm の Trusted Publishing 経由で provenance が確実に生成・公開されるかの検証が論点）。

### 2.2 SBOM（Software Bill of Materials）

- **CycloneDX** / **SPDX** が代表的な SBOM フォーマット。配布物に含まれる依存コンポーネントと版を機械可読で列挙し、脆弱性データベース（OSV / GHSA / NVD）と照合可能にする。
- 本リポジトリは「production の dependencies に外部ライブラリを使わない」方針（`CLAUDE.md`）のため **prod 依存ツリーは極小**（`packages/core` / `packages/cli` の `dependencies` は実質なし＝内部のみ）。これは SBOM 上の攻撃面が小さいという**強み**だが、「prod 依存ゼロ」を **SBOM という検証可能な形で開示**できていれば、利用者・監査者へのシグナルになる。

### 2.3 CI セキュリティ統制

- **GitHub Dependency Review Action / `npm audit`**: devDependencies を含む依存に既知脆弱性が混入していないかを PR 時に検出。
- **CodeQL（GitHub code scanning）**: ソースの静的解析。認証ライブラリでは特にインジェクション・暗号誤用の検出価値が高い。
- **Dependabot / Renovate**: 依存の自動更新 PR。devDependencies（vitest, playwright, changesets 等）の追従に有効。
- **最小権限の GITHUB_TOKEN**: `permissions: {}` を既定にしジョブ単位で必要権限のみ付与（`release.yml` は既に実践）。
- **lockfile 固定インストール**: `pnpm install --frozen-lockfile`（`ci.yml` / RELEASE.md で実践済み）。

## 3. 参照資料

- npm provenance（公式ドキュメント）— https://docs.npmjs.com/generating-provenance-statements （`--provenance` と Trusted Publishing による来歴証明の付与・検証）
- npm Trusted Publishing — https://docs.npmjs.com/trusted-publishers （OIDC による短命トークン publish。`id-token: write` 要件）
- SLSA（Supply-chain Levels for Software Artifacts）— https://slsa.dev/spec/v1.0/levels （Build Provenance のレベル定義）
- Sigstore — https://www.sigstore.dev/ （Fulcio/Rekor による署名と透明性ログ）
- CycloneDX — https://cyclonedx.org/ / SPDX — https://spdx.dev/ （SBOM フォーマット）
- GitHub Dependency Review Action — https://github.com/actions/dependency-review-action
- GitHub CodeQL — https://codeql.github.com/
- OSV（Open Source Vulnerabilities）— https://osv.dev/
- 本リポジトリ: `.github/workflows/release.yml`（Trusted Publishing / provenance 自動付与の記述）、`.github/workflows/ci.yml`（現状の CI ジョブ）、`RELEASE.md`（初回手動 publish では provenance が付かない旨）、`CLAUDE.md`（prod 依存ゼロ方針）

## 4. 現在の実装確認

- `.github/workflows/release.yml`:
  - Changesets + npm Trusted Publishing(OIDC) で publish。`permissions: {}` を既定にジョブで `id-token: write` / `contents: write` のみ付与（最小権限を実践）。
  - コメント上は provenance 自動付与を前提とするが、**provenance が実際に公開されたかを CI で検証するステップは無い**。
- `.github/workflows/ci.yml`:
  - `pnpm install --frozen-lockfile` でインストール再現性は確保。
  - 実行内容は Unit/Integration テスト・Conformance テスト・Playwright E2E のみ。
  - **`npm audit` / dependency-review / CodeQL / SBOM 生成のステップは無い**。
  - 型チェック・Lint は `# TODO` でコメントアウトされており CI 未適用。
- 依存自動更新: `.github/dependabot.yml` など **設定ファイルは存在しない**（`.github/` 配下は `workflows/` のみ）。
- 依存方針: `packages/core` / `packages/cli` の `package.json` に **prod `dependencies` は無い**（Web 標準 API のみ・内部依存のみ。`CLAUDE.md` の方針通り）。攻撃面は devDependencies に限定される。
- `RELEASE.md`: 初回手動 publish では provenance が付かないと明記。2 回目以降の CI publish に provenance を期待している。

## 5. 現在の実装との差分

満たしていること:

- ✅ prod 依存ゼロ方針により、配布物のサプライチェーン攻撃面が構造的に極小。
- ✅ Trusted Publishing(OIDC) で長期 `NPM_TOKEN` を持たない（トークン漏洩リスクの排除）。
- ✅ `release.yml` の最小権限（`permissions: {}` 既定）。
- ✅ `--frozen-lockfile` によるインストール再現性。

不足／改善余地:

- 🟠 **provenance の検証・可視化が未確認**: 「自動付与される」前提だが、pnpm 経由の Trusted Publishing で provenance が確実に生成・公開されたかを確認する手順／CI チェックが無い。付与されていなければ SLSA 証跡が欠落する。
- 🟠 **依存監査が CI に無い**: devDependencies（vitest / playwright / changesets / tsx 等）の既知脆弱性を検出する `npm audit` / dependency-review が PR フローに無い。OSS 認証ライブラリとして「依存の健全性を継続検査している」シグナルが弱い。
- 🟡 **SBOM 未提供**: 「prod 依存ゼロ」という強みを検証可能な形で開示できていない。利用者・企業監査が機械的に確認する手段が無い。
- 🟡 **静的解析（CodeQL）が無い**: 暗号・パース・リダイレクト処理を含むコードベースに対する自動静的解析の網が無い。
- 🟡 **依存自動更新が無い**: Dependabot/Renovate 不在で、devDependencies の脆弱性追従が手動依存。
- 🟢 **型チェック/Lint が CI 未適用**: `ci.yml` でコメントアウト。サプライチェーン直接の問題ではないが、品質ゲートの欠落として併記。

セキュリティ観点:

- 認証ライブラリの侵害は「下流の全システムの認証バイパス」に直結するため、配布物完全性（provenance）と依存健全性（audit）は **プロトコル準拠と同格の優先度**で扱う価値がある。
- 一方で prod 依存ゼロのため、現実的な攻撃面は CI/ビルド経路と devDependencies に限定される。対策の費用対効果が高い領域。

## 6. 改善・追加を検討する理由

価値:

- **信頼性シグナル（Fidelity 軸の補強）**: 本ライブラリのコンセプトは「Conformance 準拠を信頼のシグナルにする」。provenance / SBOM / 依存監査は、**プロトコル準拠とは別軸の「配布物としての信頼性」**を補強する。「本番導入を見据える開発者」がライブラリ選定で重視する観点。
- **利用者メリット**: 企業利用者は調達・セキュリティレビューで SBOM や provenance を要求することが増えている。これらがあると採用障壁が下がる。
- **低コストで高効果**: prod 依存ゼロのため、SBOM は小さく、audit のノイズも少ない。CI ステップ追加・設定ファイル追加が中心で、既存コードへの影響はほぼ無い。
- **Basic OP 認定との関係**: 本トピックは **Basic OP 認定の要件ではない**（OIDF 認定はプロトコル挙動が対象）。あくまで**配布物・運用のセキュリティ拡張**であり、認定とは独立して価値がある。

導入難易度:

- 🟢 小〜中。CI へのジョブ追加（dependency-review / `npm audit` / CodeQL / SBOM 生成）と、`.github/dependabot.yml` などの設定追加が中心。`release.yml` への provenance 検証ステップ追加も小規模。

実装しない場合のリスク:

- provenance が実は付いていないまま「来歴証明あり」と認識し続ける（証跡欠落の見落とし）。
- devDependencies の既知脆弱性が検知されず、ビルド環境経由のサプライチェーンリスクが残置。
- 企業監査・調達で SBOM/証跡を要求された際に提示できず、採用機会を逸する。

## 7. 実装方針の候補

最終判断は人間が行う前提で、判断材料を整理する。

### 方針A（CI セキュリティゲートの追加）

- `ci.yml` に以下を追加:
  - `npm audit`（または `pnpm audit`）を PR で実行（`--audit-level=high` 等の閾値は要検討）。
  - GitHub `dependency-review-action`（PR で導入される依存の脆弱性・ライセンスを審査）。
  - CodeQL workflow（`github/codeql-action`、JavaScript/TypeScript）。
- 併せて TODO 化されている型チェック/Lint を有効化（別タスクとの整合は要確認）。

### 方針B（SBOM 生成と公開）

- リリース時に CycloneDX 形式の SBOM を生成（`@cyclonedx/cyclonedx-npm` など devDependency）。
- GitHub Release アセットとして添付、または npm パッケージに同梱（サイズと方針次第）。
- 「prod 依存ゼロ」を検証可能な形で示す。

### 方針C（provenance の確証）

- `release.yml` に provenance 公開の検証ステップを追加（publish 後に npm registry の attestation を照会、または `npm publish --provenance` の明示指定が pnpm 経路で必要か検証）。
- RELEASE.md に「provenance が付いていることの確認手順」を追記。

### 方針D（依存自動更新）

- `.github/dependabot.yml`（npm + github-actions エコシステム）を追加。
- もしくは Renovate を導入。更新頻度・グルーピングは運用方針で決定。

### 方針E（現状維持 + 文書化のみ）

- prod 依存ゼロを理由に最小限とし、README に「依存ゼロ・Trusted Publishing 採用」を明記するに留める。
- コスト最小だが、検証可能性（SBOM/audit 証跡）は得られない。

判断材料:

- 効果/コスト比が最も高いのは **方針A（dependency-review + audit）** と **方針D（Dependabot）**。設定追加のみで継続的な健全性監視が得られる。
- 方針C は「provenance あり」という現状認識の真偽確認なので、優先的に実施する価値がある（小コスト）。
- 方針B（SBOM）は調達要件が顕在化してからでも遅くないが、prod 依存ゼロを売りにするなら早期に出すと訴求力が高い。
- v0.x スコープ（`study-material/RELEASE-v0.x-scope.md`）に入れるか後続にするかは人間が判断。

## 8. タスク案

- [ ] 方針 A〜E のうち実施範囲を人間が決定する
- [ ] （方針C）次回 publish 後に npm パッケージページで provenance バッジ／attestation の有無を確認し、欠落していれば `release.yml` を是正する。確認手順を RELEASE.md に追記
- [ ] （方針A）`ci.yml` に `pnpm audit`（閾値設定）と `dependency-review-action` を追加
- [ ] （方針A）CodeQL workflow を追加（言語: JavaScript/TypeScript）
- [ ] （方針D）`.github/dependabot.yml` を追加（npm + github-actions）
- [ ] （方針B）CycloneDX SBOM を CI で生成し、Release アセットに添付するか検討
- [ ] README に「prod 依存ゼロ・Trusted Publishing・provenance」のセキュリティ姿勢を記載
- [ ] 本トピックは Basic OP 認定要件外である旨を `study-material/basic-op-requirement-traceability.md` の運用メモに残す（混同防止）

## 関連トピック

- `study-material/RELEASE-v0.x-scope.md` — v0.x のリリーススコープ判断（本トピックを v0.x に含めるかの判断材料）
- `study-material/audit-logging-and-observability.md` / `study-material/operational-health-readiness-endpoints.md` — いずれも**実行時 OP の運用**。本ファイルは**配布物・ビルドパイプライン**を扱う差分。
