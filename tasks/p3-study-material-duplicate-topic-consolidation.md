# [P3] `study-material/` の重複トピック統合とステータス陳腐化の解消

## ステータス

🟢 Low / 未着手（コード変更を伴わないドキュメント整備）

## 背景

`study-material/` は本タスク作成時点で 113 ファイル、`study-material/done/` は 83 ファイル、`tasks/`（`done/` 含む）は
約 150 ファイルという規模に達している。この規模で、次の 2 種類の負債が確認された。

**(1) 同一トピックを扱うファイルが 2 本ずつ並存している（5 組）**

| # | ファイル A | 行数 | ファイル B | 行数 | トピック |
|---|---|---|---|---|---|
| 1 | `audit-logging-and-observability.md` | 134 | `audit-logging-observability.md` | 137 | 監査ログ / 可観測性 |
| 2 | `ext-native-apps-rfc8252.md` | 129 | `ext-oauth-native-apps-rfc8252.md` | 100 | RFC 8252 Native Apps |
| 3 | `ext-dynamic-client-registration.md` | 94 | `extension-dynamic-client-registration.md` | 75 | OIDC DCR 1.0 / RFC 7591 |
| 4 | `ext-pushed-authorization-requests-rfc9126.md` | 95 | `extension-pushed-authorization-requests-par.md` | 75 | PAR / RFC 9126 |
| 5 | `amr-values-guidance-rfc8176.md` | 169 | `amr-values-rfc8176.md` | 124 | RFC 8176 `amr` 値 |

命名パターンから、`ext-*`（現行の命名）と `extension-*` / 接尾辞なし（旧命名）が
別々の調査回で作られ、統合されないまま残ったものと見られる。

さらに RFC 8252 は**三重**になっている: `study-material/done/oauth-native-apps-rfc8252.md`（タスク化済み）が
存在するにもかかわらず、上表の 2 本が直下に残っている。

**(2) 実装済み機能のステータスが「未着手」のまま**

PAR（RFC 9126）は既に実装されている:

- `packages/experimental/src/par/`（`par-request.ts` / `resolve-request-uri.ts` / `store.ts` ＋ 各テスト）
- `packages/cli/src/features.ts` の `EXPERIMENTAL_FEATURES = ['par']`、`ProviderFeatures.par`（既定 `false`）
- `tests/e2e/specs/pushed-authorization-requests.spec.ts`

にもかかわらず `study-material/ext-pushed-authorization-requests-rfc9126.md` のステータス欄は
**「🟢 拡張機能 / 未着手」**のままである。

これらは仕様準拠の問題ではないが、**リポジトリ自身の運用規約に反している**。
CLAUDE.md および継続調査タスクは「新しいトピックファイルを作る前に
`study-material/` / `study-material/done/` / `tasks/` をすべて確認し、同じ論点が既に扱われていないか
確認すること」を求めている。重複ファイルと誤ったステータスは、**この確認手順そのものを機能不全にする**。

放置すると次の調査回で 6 組目・7 組目が生まれ、統合コストは単調増加する。

検討の詳細は `study-material/done/study-material-topic-duplication-and-status-drift.md` を参照。

> **本タスクのスコープ**: 既存 5 組の統合（方針A）とステータス陳腐化の解消・再発防止手順の明文化（方針D）に限定する。
> 重複検出の CI 機械化（方針C）は、既存負債を解消しないと常時赤になるため本タスクには含めず、
> 完了後に別途判断する。

## 対象ファイル

統合対象（`study-material/` 直下）:

- `audit-logging-and-observability.md` / `audit-logging-observability.md`
- `ext-native-apps-rfc8252.md` / `ext-oauth-native-apps-rfc8252.md`
- `ext-dynamic-client-registration.md` / `extension-dynamic-client-registration.md`
- `ext-pushed-authorization-requests-rfc9126.md` / `extension-pushed-authorization-requests-par.md`
- `amr-values-guidance-rfc8176.md` / `amr-values-rfc8176.md`

参照整合の確認対象:

- `study-material/basic-op-requirements-baseline.md`（Basic OP 要件のインデックス）
- `study-material/basic-op-requirement-traceability.md`（要件→実装→テスト→タスクのトレーサビリティ）
- `study-material/current-implementation-documentation-backlog.md`
- `study-material/done/oauth-native-apps-rfc8252.md`（RFC 8252 の正とすべきか確認）

規約追記の対象:

- `CLAUDE.md`

## 仕様参照

本タスクは外部仕様ではなくリポジトリ内部の運用規約に対する準拠を扱う。根拠:

- `CLAUDE.md`「実装におけるルール」および継続調査タスクの「重複記載を避ける方針」
  - 「すでに `study-material/` / `study-material/done/` / `tasks/` のいずれかで扱っている内容については、
    同じ説明を繰り返さないでください」
  - 「既存ファイルの内容を更新した方が自然な場合は、新規ファイルを作成せず、既存ファイルに追記・修正する」
- `study-material/basic-op-requirements-baseline.md`: 「このファイルは**インデックス（地図）**である。
  個別の改善内容は重複記載しない」と自ら宣言している
- `study-material/basic-op-requirement-traceability.md`: 「共通の仕様参照ハブ。他トピックファイルは
  この索引を参照し、同じ説明を繰り返さないこと」と自ら宣言している

## 現状の実装

コード変更は伴わない。現状は上記「背景」に記載のとおり。

なお `study-material/done/` 内および `tasks/` / `tasks/done/` 内では重複は確認されなかった。
命名規約自体は `ext-*` に概ね収束しており、**規約の不在ではなく移行の取り残し**が原因と見られる。

## 修正方針

### A. 重複 5 組の統合

各ペアについて、以下の手順を踏むこと。**片方を単純削除しない**——固有の論点が失われる。

- [ ] 1. 両ファイルを読み、**結論・方針・参照資料の差分**を洗い出す
      （特に `amr-*` は 169 行 / 124 行と両方が厚く、単純な包含関係でない可能性が高い）
- [ ] 2. 残すファイルを決める（原則として現行命名 `ext-*` に沿う方、または内容が厚い方）
- [ ] 3. 残さない側の固有情報を残す側へ移植する
- [ ] 4. セキュリティ方針が食い違っている箇所があれば、どちらを採るかを明示的に記録する
- [ ] 5. 残さない側を削除する
- [ ] 各ペアの処理:
  - [ ] `audit-logging-and-observability.md` ↔ `audit-logging-observability.md`
  - [ ] `ext-native-apps-rfc8252.md` ↔ `ext-oauth-native-apps-rfc8252.md`
  - [ ] `ext-dynamic-client-registration.md` ↔ `extension-dynamic-client-registration.md`
  - [ ] `ext-pushed-authorization-requests-rfc9126.md` ↔ `extension-pushed-authorization-requests-par.md`
  - [ ] `amr-values-guidance-rfc8176.md` ↔ `amr-values-rfc8176.md`

### B. RFC 8252 の三重複の整理

- [ ] `study-material/done/oauth-native-apps-rfc8252.md` を正としてよいか確認する
      （対応するタスク `tasks/done/oauth-native-apps-rfc8252.md` 相当が完了しているか）
- [ ] pending 側 2 本の固有論点（done 側でカバーされていない差分）を洗い出す
- [ ] 差分が無ければ pending 側 2 本を削除する。差分があれば done 側へ吸収するか、
      「残課題のみ」の差分ファイル 1 本に集約する

### C. ステータス陳腐化の解消（PAR）

- [ ] PAR の統合後ファイルを、実装済みの現状に合わせて次のいずれかにする:
  - `study-material/done/` へ移動する、または
  - 「実装済み（`packages/experimental/src/par`、CLI feature flag `par`、E2E あり）。
    残課題は X」という差分ファイルへ書き換える
- [ ] 同様のステータス陳腐化が他にないか、`study-material/` 全体を「未着手」表記で走査して確認する
      （実装済みなのに未着手と書かれているものが他にないか）

### D. 参照整合の確認

- [ ] 削除したファイルへの参照が `study-material/` / `tasks/` / `CLAUDE.md` に残っていないことを確認する
      （`grep -rn "<削除したファイル名>" study-material/ tasks/ CLAUDE.md`）
- [ ] `basic-op-requirements-baseline.md` / `basic-op-requirement-traceability.md` の
      参照リンクが有効なままであることを確認する

### E. 再発防止（規約の明文化）

- [ ] `CLAUDE.md` に `study-material/` の命名規約を追記する
  - 拡張機能トピックは `ext-<仕様略称>.md`（例: `ext-mtls-rfc8705.md`）
  - `extension-*` は使わない
- [ ] `CLAUDE.md` に「機能を実装したら、対応する `study-material/` ファイルのステータスを更新するか
      `done/` へ移す」という手順を追記する
- [ ] （任意・完了後に判断）重複検出スクリプトを `scripts/` に追加し CI へ組み込むか検討する。
      ファイル名から `rfc\d+` / 仕様名トークンを抽出して衝突を警告する軽量なもの。外部依存は不要。
      **本タスクには含めない**（既存負債を先に解消する必要があるため）

## テスト要件

コード変更を伴わないため自動テストは追加しないが、以下を機械的に確認すること。

- [ ] `ls study-material/*.md | wc -l` が統合前より 5 減っている（RFC 8252 の追加整理分はさらに減る）
- [ ] `grep -rn "<削除した各ファイル名>" study-material/ tasks/ CLAUDE.md` が 0 件であること
- [ ] `grep -rln "extension-" study-material/` が 0 件であること（旧命名の消滅確認）
- [ ] `study-material/` 内に、実装済み機能を「未着手」と表記したファイルが残っていないこと
      （少なくとも PAR について確認）
- [ ] `pnpm test` がパスすること（ドキュメント変更のみなので影響しないことの確認）

## 完了条件

- 重複 5 組が統合され、`study-material/` 直下に同一トピックの重複ファイルが存在しないこと
- RFC 8252 のトピックが `done/` 側 1 本（＋必要なら残課題ファイル 1 本）に整理されていること
- PAR のファイルが実装済みの現状を正しく反映していること
- 削除したファイルへの参照が repo 内に残っていないこと
- `CLAUDE.md` に `study-material/` の命名規約とステータス更新手順が明記されていること
- 統合の過程で失われた論点が無いこと（統合時に洗い出した差分がすべて残存ファイルに反映されていること）
