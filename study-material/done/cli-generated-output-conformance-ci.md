# CLI 生成コードの出力検証（生成物の型検査・ビルド・挙動の CI 自動化）

## 1. このトピックで確認したいこと

OIDF Conformance Suite および利用者が実際に動かすのは **CLI が生成したプロバイダ**であって core ライブラリ単体ではない。にもかかわらず、**CLI ジェネレータのテストは「ファイルが生成されること」と「特定の import 文字列が含まれること」しか検証していない**。生成されたコードが**型検査を通るか・ビルドできるか・リクエストに正しく応答するか**は自動検証されていない。

このトピックでは、生成物（テンプレートの出力）に対する **自動検証（最低でも型検査／ビルド、可能なら最小の挙動テスト）を CI に組み込むべきか**を検討する。これは Fidelity 軸（Conformance 準拠を信頼性のシグナルとして維持する）を「生成物レベル」で担保するための話である。

> 既存の `study-material/basic-op-conformance-verification-plan.md` は **OIDF Suite を使った手動・動的検証（公開 HTTPS が前提、v1.0 条件）**を扱う。本ファイルはその前段として、**CI で常時回せる軽量な「生成物が壊れていないこと」の自動検証**に絞る（両者は補完関係で、重複しない）。

## 2. 関連する仕様・基準

- 本トピックは特定の OIDC/OAuth 規定ではなく、**CLAUDE.md の品質基準**に対応する:
  - 「テストコードで主要ケースを網羅し、仕様参照を明記することは必須」
  - 「Fidelity: Conformance 準拠を信頼性のシグナルとして維持する」
- 生成コードが満たすべき HTTP レイヤ要件（`Cache-Control: no-store`、`Content-Type` 検証、`WWW-Authenticate`、エラーレスポンス形）の根拠仕様は、各エンドポイントの既存 study-material（`error-response-cross-endpoint.md` / `userinfo-endpoint-comprehensive.md` / `token-lifetime-security-policy.md` 等）を参照（重複記載回避）。本ファイルは「それらが生成物でも崩れていないことを CI で守る」観点に限定する。

## 3. 参照資料

- 本リポジトリ `packages/cli/src/__tests__/hono-generator.test.ts`（現状のテスト範囲の根拠）
- 本リポジトリ `study-material/basic-op-conformance-verification-plan.md`（動的・手動検証。本ファイルが補完する対象）
- 本リポジトリ `CLAUDE.md`「リリース方針 / 差別化の3軸（Fidelity）」

## 4. （上に統合）

## 5. 現在の実装確認

- `packages/cli/src/__tests__/hono-generator.test.ts` の検証内容:
  - 生成ファイルが存在すること（`files.find(f => f.path === 'app.ts')` 等）
  - 生成ファイル総数（`toHaveLength(15)`）
  - 生成コードに特定の import 文字列が含まれること（`content.toContain('validateAuthorizationRequest')` 等）
- すなわち **文字列レベルの存在チェックのみ**。以下は未検証:
  - 生成された TypeScript が **型検査を通るか**（`tsc --noEmit`）
  - 生成プロジェクトが **ビルド/起動できるか**
  - エンドポイントが **正しいステータス・ヘッダ・JSON 形で応答するか**（Discovery / Token エラー / UserInfo の `Cache-Control`・`WWW-Authenticate` 等）
- core 側は各機能に対し充実したユニットテストがあるが、それらは **生成物に正しく配線されているか**までは保証しない。

## 6. 現在の実装との差分

満たしていること:
- 生成器の入出力（ファイル一覧・主要 import の存在）は回帰検知できる。

不足している可能性があること:
- 🟠 **生成コードの型安全性が未検証**。テンプレート（手書き文字列）に型エラーや API シグネチャの不整合（core の関数シグネチャ変更にテンプレートが追随できていない等）が混入しても、import 文字列チェックでは検知できない。
- 🟠 **挙動の回帰検知がない**。HTTP レイヤ要件（`Cache-Control: no-store`、`Content-Type` 検証、エラー JSON 形、`WWW-Authenticate`）が将来のテンプレ編集で欠落しても CI で気づけない。
- 🟢 **生成物 ↔ core のシグネチャ整合**が「文字列の一致」頼みで、リファクタ耐性が低い。

Fidelity 観点での確認事項:
- 「core は通るが生成物は壊れている」状態を許容しない仕組みが、Conformance を信頼性シグナルとして掲げる以上は望ましい。

## 7. 改善・追加を検討する理由

- **Fidelity 軸の常時担保**: OIDF Suite 実行（手動・v1.0 条件）を待たずに、CI で「生成物が型検査を通り、主要エンドポイントが規定どおり応答する」ことを常時保証できる。テンプレ編集や core API 変更時のデグレを即検知できる。
- **導入しやすさ**: 生成物の母体である `packages/sample/src/oidc-provider/` が既に存在し、Hono の `app.fetch(new Request(...))` で**実サーバを立てずに**リクエスト/レスポンスを検証できる。最小の挙動テストは比較的低コスト。
- **段階的に進められる**: まず「生成出力を一時ディレクトリへ書き出して `tsc --noEmit`」だけでも価値が高い（型不整合の検知）。次段で `app.fetch` ベースの挙動テストを足せる。
- **実装しない場合のリスク**: テンプレートの編集ミス／core シグネチャ変更が生成物に伝播し、利用者が初回起動で詰まる、または Conformance 検証フェーズで初めて発覚して手戻りになる。

## 8. 実装方針の候補

最終判断は人間が行う前提で、判断材料を整理する。

- **A 案（最小・推奨度: 判断材料）: 生成出力の型検査を CI 化**
  - テストで `generate()` の出力を一時ディレクトリへ書き、`@maronn-openid-connect/core` を解決できる状態で `tsc --noEmit` を実行。型エラーがあれば失敗。
- **B 案: 既存サンプルを「生成物の代理」として挙動テスト**
  - `packages/sample/src/oidc-provider/` は生成物の同型ミラー。Hono の `app.fetch(new Request(...))` で、代表ケース（Discovery が必須フィールドを返す／Token エラーが `Cache-Control: no-store` + JSON エラー形／UserInfo 401 が `WWW-Authenticate` を返す 等）をアサート。生成物そのものではないが、テンプレ ↔ サンプルの乖離を別途検知する前提で実用的。
- **C 案: 生成出力をそのままビルド/起動して挙動テスト**
  - 最も忠実だが、依存解決・ビルドの段取りが重い。CI 時間とのトレードオフ。
- **補足**: テンプレートと生成済みサンプルの **同期ずれ**自体を検知する仕組み（テンプレ出力とサンプルの差分比較）も併せて検討余地あり。

検討ポイント（人間判断）:
- どのレイヤまで自動化するか（型検査のみ / 挙動まで）。
- 生成物実体を使うか、サンプルを代理にするか（サンプルとテンプレの同期保証が別途必要かどうか）。
- CI 実行時間の許容範囲。

## 9. タスク案

- [ ]（A 案・着手可能粒度）CLI テストに「`generate()` 出力を一時ディレクトリへ書き出し `tsc --noEmit` で型検査する」ケースを追加し、生成コードの型不整合を CI で検知できるようにする
- [ ]（B 案・着手可能粒度）`packages/sample/src/oidc-provider/` を対象に `app.fetch(new Request(...))` ベースの最小挙動テストを追加（Discovery 必須フィールド / Token エラーの `Cache-Control: no-store` + エラー JSON 形 / UserInfo 401 の `WWW-Authenticate`）
- [ ]（検討段階）生成出力そのものをビルド/起動する挙動テスト（C 案）を行うかは CI 時間との兼ね合いで人間が判断
- [ ]（検討段階）テンプレート出力と生成済みサンプルの同期ずれ検知の要否を判断
