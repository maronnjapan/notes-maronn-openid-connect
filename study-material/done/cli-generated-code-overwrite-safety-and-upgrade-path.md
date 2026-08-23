# CLI 生成コードの上書き安全性と「仕様追随を利用者へ届ける」アップグレード経路

## 1. このトピックで確認したいこと

本リポジトリの利用者入口は「CLI でフロー実装コードを生成し、利用者がそのコードを改造しながら仕様を検証する」（CLAUDE.md）である。
つまり **仕様準拠ロジックの実体は `packages/core` ではなく、利用者のリポジトリにコピーされた生成コード側にも存在する**。
この構造には、他のライブラリ型 OSS には無い 2 つの固有リスクがある。

1. **再生成時の破壊**: 利用者が改造した生成コードの上に、`maronn-oidc generate` を再実行すると無警告で上書きされるか。
2. **仕様修正の到達性**: `packages/cli` のテンプレートに仕様バグ修正が入っても、既に生成済みの利用者にはそれが届く経路があるか。

本ファイルは、この 2 点について現状を確認し、判断材料を整理する。

> 生成物が「壊れていないこと」を CI で守る話は `study-material/done/cli-generated-output-conformance-ci.md` が扱う。
> 本ファイルは **生成物が利用者の手元へ配られた後のライフサイクル**（上書き・アップグレード）に限定し、重複しない。

## 2. 関連する仕様・基準

本トピックは OIDC/OAuth の特定条文ではなく、次の 3 つの基準に対応する。

### 2.1 CLAUDE.md（本リポジトリの設計方針）

- 差別化の 3 軸のうち **Speed**: 「新しい OIDC/OAuth 仕様が出たとき最速で実装・追随する」。
  追随したテンプレート修正が既存利用者へ届かないなら、Speed は「新規生成時にだけ効く」ものに縮退する。
- **Fidelity**: 「Conformance 準拠を信頼性のシグナルとして維持する」。
- 「`samples/*/src/oidc-provider` は `packages/cli` によるコード生成されたものなので、この部分の修正が必要な場合は必ず
  `packages/cli` を修正することで対応すること」——つまり **生成物は上流（テンプレート）を単一の真実とする**という前提が
  リポジトリ内部では採られている。利用者側にはこの前提を強制する仕組みが無い。
- 「利用者は生成コードをカスタマイズしてよいが、`conformance.test.ts` が通らない状態は本リポジトリが担保する
  Basic OP 挙動から外れている可能性がある」——**カスタマイズは公式に許容されている**。つまり
  「上書きしてよいファイル」と「利用者の資産になったファイル」が混在する。

### 2.2 OpenID Certification の運用（Fidelity 軸に効く前提）

OpenID Foundation の認定は「ある実装の、ある版・あるプロファイル」に対して与えられる運用である
（認定申請時に実装名とバージョンを申告する）。生成コードを配る形態では、
**利用者の手元にあるコードが、認定を通した版のテンプレートから生成されたものか**が追跡できないと、
「このライブラリで生成した OP は Basic OP 準拠」という主張の粒度が曖昧になる。

> 不明点として明記する: 生成コード方式の OSS に対して OIDF が具体的にどのような版管理を要求するかは、
> 公開資料からは断定できない。ここでは「認定は版に紐づく」という一般的な運用事実のみを前提にしている。
> 認定を実際に取得するフェーズで `study-material/basic-op-conformance-verification-plan.md` と併せて確認する必要がある。

### 2.3 一般的なコードジェネレータの慣行（相互運用というより利用者期待）

`create-*` 系のスキャフォールダは「初回生成のみ・以後は利用者の資産」、
OpenAPI Generator 等の再生成前提のジェネレータは「`.openapi-generator-ignore` 相当の保護リスト」「生成物ヘッダに
generator バージョンを刻む」といった慣行を持つ。本リポジトリはどちらの慣行も採っていない。

## 3. 参照資料

- 本リポジトリ `CLAUDE.md`「コンセプト / 差別化の3軸 / 利用者の入口 / samples の位置づけ」
- 本リポジトリ `packages/cli/src/index.ts`（`writeGeneratedFiles` / `run`）
- 本リポジトリ `docs/library-document/src/content/docs/guides/cli.md`（現行の CLI ドキュメント。上書き挙動の記載なし）
- OpenID Certification — https://openid.net/certification/ （認定が実装の版に紐づく運用であることの根拠）
- 本リポジトリ `study-material/done/cli-generated-output-conformance-ci.md`（生成物の CI 検証。本ファイルの補完関係）
- 本リポジトリ `study-material/RELEASE-v0.x-scope.md`（v0.x スコープと責務境界）

## 4. 現在の実装確認

### 4.1 書き込みは無条件上書き

```ts
// packages/cli/src/index.ts:104-115
function writeGeneratedFiles(outputDir: string, files: Array<{ path: string; content: string }>): void {
  for (const file of files) {
    const fullPath = join(outputDir, file.path);
    const dir = dirname(fullPath);
    if (!existsSync(dir)) {
      mkdirSync(dir, { recursive: true });
    }
    writeFileSync(fullPath, file.content, 'utf-8');
    console.log(`  Created: ${file.path}`);   // 既存ファイルを潰した場合も "Created"
  }
}
```

- 既存ファイルの有無を確認しない。差分表示もバックアップも確認プロンプトも無い。
- ログは常に `Created:` であり、**上書きしたことが利用者に伝わらない**。
- `--force` / `--dry-run` / `--diff` 相当のオプションは `parseArgs`（`packages/cli/src/index.ts:60-102`）に存在しない。
  現行オプションは `--output` / `--entry` / `--enable` / `--disable` / `--help` のみ。

### 4.2 生成物にバージョン情報が無い

- 生成される各ファイル（`app.ts` / `routes/*.ts` / `config.ts` / `store.ts` / `conformance.test.ts` 等）に、
  「どの `@maronn-openid-connect/cli` バージョンのどの feature 構成で生成されたか」を示すヘッダやマニフェストは含まれない。
- `packages/cli/src/generator.ts` は `{ framework, files }` を返すだけで、メタ情報ファイルを出力しない。
- 結果として、利用者のリポジトリを見ても、生成元の版・`--enable/--disable` の指定内容は復元できない。

### 4.3 上書き対象には「利用者の資産になりやすいファイル」が含まれる

生成物には次が混在する。

| 種別 | 例 | 利用者が触る前提か |
|---|---|---|
| 仕様準拠ロジック | `routes/token.ts` / `routes/authorize.ts` / `routes/userinfo.ts` | 触ってよい（ステップ関数を消す/足す設計） |
| 環境固有の設定 | `config.ts`（issuer・TTL・クライアント定義） | **ほぼ確実に触る** |
| 永続化の実装 | `store.ts` / `resolvers.ts` | **ほぼ確実に触る**（KV / DB へ差し替え） |
| 契約テスト | `conformance.test.ts` | 原則触らない（上流が正） |

`config.ts` / `store.ts` は「PoC 用のデフォルトを差し替えてください」と CLI の Next steps でも案内される
（`packages/cli/src/index.ts:200-206`）。つまり **上書きされると必ず困るファイルが、無警告上書きの対象**になっている。

## 5. 現在の実装との差分

満たしていること:

- ✅ 生成そのものは決定的（同じ framework / features なら同じ出力）で、テンプレートは `packages/cli` に一元化されている。
- ✅ 生成物の破損検知は CI 側で追跡中（`study-material/done/cli-generated-output-conformance-ci.md`）。
- ✅ experimental feature については「API が壊れる可能性がある」旨の警告を生成時に出している（`index.ts:191-195`）。

不足している可能性があること:

- 🔴 **上書き保護が無い**: 改造済みの `config.ts` / `store.ts` を無警告で失う。CLI の実行ミス（`-o` の指定間違い、
  feature を変えて再実行）で復旧不能になる。Git 管理下なら復旧できるが、CLI 側の安全網としてはゼロ。
- 🔴 **上書きしたことがログに出ない**: `Created:` 固定表示のため、事故が起きた事実にも気づけない。
- 🟠 **アップグレード経路が無い**: `packages/cli` に入った仕様修正（本リポジトリで日常的に発生している）を、
  既存利用者が自分のコードへ取り込む手段が「手で diff を取る」以外に無い。生成元の版が記録されていないため、
  「どこからどこまでの差分を取ればよいか」も分からない。
- 🟠 **`conformance.test.ts` の位置づけが利用者側で壊れる**: CLAUDE.md は `conformance.test.ts` を
  「生成 OP が想定挙動を満たすことを利用者に示す契約テスト」と定義するが、利用者が古い版のまま持ち続けると、
  上流の契約が更新されてもテストは古い契約のまま通り続ける（誤った安心）。

セキュリティ上、改善した方がよいこと:

- 🟠 仕様修正の多くはセキュリティ修正（PKCE 検証、リダイレクト検証、トークン再利用カスケード等）である。
  到達経路が無いということは、**セキュリティ修正が既存利用者に届かない**ということに等しい。
  npm の `dependencies`（`@maronn-openid-connect/core`）経由で届く修正と、テンプレート経由でしか届かない修正の
  境界が利用者に見えていない点が特に問題。

相互運用性の観点:

- 🟢 本トピックは OP ↔ RP の相互運用ではなく、ライブラリ ↔ 利用者の運用境界の問題。

Basic OP として提供する上で確認すべきこと:

- 「Basic OP 準拠」と言えるのは上流テンプレートの出力であって、利用者が改造した後のコードではない。
  この線引きは CLAUDE.md に書かれているが、**生成物自体（README ヘッダ等）には書かれていない**。

## 6. 改善・追加を検討する理由

**なぜ価値があるか**

- 本リポジトリのコンセプト（Speed / Fidelity）は「生成コードを配る」形態と本質的に緊張関係にある。
  この緊張を運用で埋めないと、「最速で追随しているのに利用者は古い実装のまま」という状態が常態化する。
- 上書き事故は「一度でも起きると信頼を失う」種類の事故であり、PoC 開発者（ターゲットユーザー）は
  ライブラリ選定段階で離脱する。回避コスト（既存ファイル検出 + 確認）は極めて小さい。

**Basic OP 必須か、拡張か**

- どちらでもない。OIDF 認定要件ではなく、**OSS としての利用者体験と、セキュリティ修正の到達性**の問題。
  ただし Fidelity 軸（認定を信頼のシグナルとする）を実効あるものにする前提条件ではある。

**導入しやすさ**

- 🟢 上書きガード（既存ファイル検出 → 既定は中断、`--force` で上書き）は `writeGeneratedFiles` の局所修正で完結する。
  外部依存は不要（`node:fs` の `existsSync` は既に import 済み）。
- 🟢 生成物へのバージョンスタンプは、テンプレート出力にヘッダコメントを 1 行足すだけで実現できる。
  ただし **全テンプレートの期待出力を固定している既存テストが一斉に壊れる**ため、変更範囲は広い。
- 🟡 「アップグレードコマンド（差分適用）」は難易度が高い。3-way merge を自前実装するのは外部依存禁止の制約下で重い。

**既存実装との接続**

- `packages/cli/src/index.ts` の `run()` に判定を差し込むだけで上書きガードは成立する。
- バージョンスタンプは `packages/cli/package.json` の `version` を生成時に埋め込む形が自然
  （ビルド時に定数化するか、`createRequire` で読むかは実装方針の判断）。

**利用者・運用者のメリット**

- 改造済み設定を失わない。再生成が安全になることで、feature フラグを変えた試行錯誤がしやすくなる
  （＝「爆速で試せる」というコンセプトそのものの強化）。
- 生成元の版が分かることで、リリースノートとの突き合わせが可能になり、セキュリティ修正の取り込み判断ができる。

**実装しない場合に残るリスク**

- 利用者の改造が無警告で消える（データロスに近い体験）。
- 上流のセキュリティ修正が既存利用者に届かず、「maronn-openid-connect で作った OP」が古い脆弱な挙動のまま残る。
- `conformance.test.ts` の版ずれにより、契約テストが「通っているのに実は古い契約」という誤った安心を与える。

## 7. 実装方針の候補（最終判断は人間が行う）

### 方針A: 上書きガードのみ（最小・低リスク）

- `writeGeneratedFiles` で既存ファイルを検出し、1 件でもあれば**書き込まずに中断**してリストを表示。
- `--force` を追加し、明示指定時のみ上書き。ログを `Created:` / `Overwritten:` で出し分ける。
- 影響: `packages/cli/src/index.ts` と `packages/cli/src/__tests__/cli.test.ts` のみ。生成物の内容は変わらない
  （＝既存の生成物固定テストは壊れない）。

### 方針B: 方針A + 生成物へのバージョンスタンプ

- 各生成ファイル先頭に
  `// Generated by @maronn-openid-connect/cli vX.Y.Z (framework=hono, features=pkce,refresh-token,...). Do not edit if you plan to regenerate.`
  のようなヘッダを付ける。または `oidc-provider/.maronn-openid-connect.json` に版・framework・features を書き出す。
- 影響: 全テンプレートの期待出力テストの更新が必要。マニフェストファイル方式ならヘッダ変更を避けられるため影響が小さい
  （生成ファイル数を固定しているテストのみ更新）。

### 方針C: 方針B + 選択的上書き（保護リスト）

- 「上流が正」のファイル（`routes/*` / `app.ts` / `conformance.test.ts`）と
  「利用者の資産」（`config.ts` / `store.ts` / `resolvers.ts`）を CLI が区別し、
  後者は既存があればスキップ、前者は `--force` で更新可能にする。
- 利点: 「仕様修正だけ取り込む」が現実的になる。
- 欠点: 分類が本当に固定できるかの検証が要る。利用者が `routes/token.ts` を改造することは公式に許容されているため、
  「上流が正」という分類は必ずしも正しくない。分類を誤ると方針A より危険。

### 方針D: `upgrade` コマンド（差分提示）

- 生成元の版が記録されている前提で、`maronn-oidc upgrade` が「旧版の生成出力」と「新版の生成出力」を
  メモリ上で作り、その差分（unified diff）を**表示するだけ**にする（適用はしない）。
- 利点: 3-way merge を実装せずにアップグレード経路を提供できる。外部依存も不要（旧版テンプレートを保持する方法は要検討）。
- 欠点: 旧版テンプレートを CLI が保持し続けるのは非現実的。実際には「リリースノート + 生成物 diff は利用者が git で見る」
  という運用ドキュメント（方針E）に落ちる可能性が高い。

### 方針E: ドキュメントのみ（コード変更なし）

- `docs/library-document/src/content/docs/guides/cli.md` に
  「生成物は必ず生成直後にコミットしてから改造すること」「再生成は上書きなので別ディレクトリへ出して diff を取ること」
  「上流のセキュリティ修正はリリースノートを見て手で取り込むこと」を明記する。
- 利点: ゼロコスト。
- 欠点: 事故は防げない。ドキュメントを読まずに `-o` を間違える経路は残る。

**判断材料の要約**

- 方針A は費用対効果が最も高く、他方針の前提にもなる（単独で採用可能）。
- 方針B のマニフェスト方式は、方針D/Eいずれに進む場合も必要になる基盤。
- 方針C は分類の妥当性が担保できないうちは採るべきでない。
- 方針D は「旧版テンプレートをどう持つか」が未解決。現状は判断材料が不足している。

## 8. タスク案

- [ ] 方針A（上書きガード + `--force`）を実装する。既定は「既存ファイルがあれば中断」、`--force` で上書き、ログを出し分ける
- [ ] `--dry-run`（書き込まず出力予定ファイル一覧を表示）を同時に入れるか判断する
- [ ] 方針B のうち「マニフェスト方式（`.maronn-openid-connect.json`）」を採るか「ヘッダコメント方式」を採るかを決める
- [ ] 生成物に「このコードは Basic OP 準拠の出発点であり、改造後の準拠は `conformance.test.ts` で確認すること」を明記する場所
      （生成される README か、各 route ファイルのヘッダ）を決める
- [ ] `docs/library-document/src/content/docs/guides/cli.md` に上書き挙動とアップグレード手順を追記する（方針E は他方針と併用する）
- [ ] 方針D（`upgrade` コマンド）の実現可能性——旧版テンプレートの保持方法——を別途調査する

## 関連トピック

- `study-material/done/cli-generated-output-conformance-ci.md` — 生成物が壊れていないことの CI 検証。本ファイルは配布後のライフサイクルを扱う。
- `study-material/basic-op-conformance-verification-plan.md` — OIDF Suite による動的検証。認定と版の紐付けはこちらと併せて判断する。
- `study-material/done/cli-setup-entry-placeholder-silent-noop.md` — 同じ CLI の別の欠陥（`setup` の silent success）。
- `study-material/RELEASE-v0.x-scope.md` — 責務境界（どこまでが OP の責務か）の宣言。
