# T-023 [Major] CLI の生成コードを apps/ の動くアプリから抽出する構成へ作り直す

## ステータス

🔴 Major / 未着手

## この文書の使い方

この文書は、OSS 実装リポジトリ（maronn-openid-connect）で作業するセッションへの指示書である。
設計の正は notes の設計ドキュメント `claude/docs/design/2026-10-18-cli-generation-from-template-app.md` にあり、この文書はその設計を実装へ落とすための範囲、順序、制約、完了条件を定める。
設計ドキュメントと食い違う記述があれば設計ドキュメントを優先し、食い違いを作業報告に書く。

作業は五つのフェーズに分け、一つのセッションでは一つのフェーズだけを実施する。
一つのフェーズは一つのプルリクエストとして main に入れ、どのフェーズでも main は動く状態を保つ。
どのフェーズを実施するかは起動時のプロンプトで指定する。

起動時のプロンプトの例を示す。

```
tasks/T-023-cli-generate-from-apps.md を読み、そこで参照している設計ドキュメントも読んだうえで、フェーズ 1 だけを実施してください。
フェーズの範囲外には手を付けず、そのフェーズの完了条件をすべて満たしてから push してプルリクエストを作成してください。
```

着手前に次を読む。

- OSS 実装リポジトリの `README.md`（実装におけるルール、ドキュメント作成の規約、テストコードの書き方、ディレクトリの構成）
- notes の `CLAUDE.md`
- 設計ドキュメント。OSS 側からは `.notes/claude/docs/design/2026-10-18-cli-generation-from-template-app.md` で読む。リンクが無いときは `https://raw.githubusercontent.com/maronnjapan/notes-maronn-openid-connect/main/claude/docs/design/2026-10-18-cli-generation-from-template-app.md` を取得する
- `RELEASE.md`（changeset の書き方と bump の方針）
- `samples/README.md`（サンプルの位置づけと命名規則）
- notes の `implementation-guides/experimental/README.md`（実装解説の更新規約）

## 背景

CLI は生成コードを TypeScript の文字列として持っている。
ソースは約 24,500 行、テンプレート内の `features.*` による分岐は 495 箇所ある。
文字列の中では型検査も補完も効かず単体テストも書けないため、第三者が生成コードを直すプルリクエストを出しにくい。
機能をオフにした生成物や `--flow` で並べ替えた生成物は型検査されておらず、検証されている組合せは samples の四つだけである。

設計ドキュメントは、フレームワークごとに全機能オンの動くアプリを `apps/` に置き、CLI はそこからファイルを選んでコピーする構成を定めた。
機能はディレクトリで表し、base 側のコードに `if (features.x)` を書かない。
Next.js は App Router の作法のままに書き、hono と共通化しない。
PKCE は introspection や revocation と同じ stable の機能ディレクトリにする。

## 対象ファイル

新規に作るもの。

- `apps/hono/`（フェーズ 1）と `apps/nextjs/`（フェーズ 4）。private な workspace パッケージ
- `packages/cli/extract.json`、`packages/cli/src/registry.ts`、`packages/cli/src/generate.ts`（フェーズ 2）
- `packages/cli/templates/`（gitignore。build 時に apps の抽出範囲を集めたコピー）
- `tests/e2e` の apps 向けスクリプトと、samples の E2E を nightly で回す workflow
- base と機能の import 境界を検査する lint スクリプト

書き換えるもの。

- `pnpm-workspace.yaml`、ルート `package.json` のスクリプト、`.github/workflows/ci.yml`、`.github/scripts/verify-ci-gate.mjs`
- `README.md`、`packages/cli/README.md`、`samples/README.md`
- `samples/*/src/oidc-provider` と `samples/nextjs-vercel/src/app`（新 CLI で再生成）
- notes の `implementation-guides/experimental/*.ja.md` と `*.en.md` の「CLI が生成コードへ注入するコード」の節
- notes の設計ドキュメントの「未決事項」の節（決めた事項を記録する）

消すもの。

- `packages/cli/src/frameworks/**`（hono 系はフェーズ 2、Next.js はフェーズ 5）
- `packages/cli/src/flow/catalog.ts`（フェーズ 3）
- `packages/cli/src/features.ts`（`registry.ts` へ統合）

## 仕様参照

- 設計ドキュメント `claude/docs/design/2026-10-18-cli-generation-from-template-app.md`
- 先行する設計 `claude/docs/design/2026-07-19-cli-feature-options.md`（機能トグルの意味。OFF 時の挙動はこれを引き継ぐ）
- OSS `README.md` の「実装におけるルール」「テストコードの書き方」
- `RELEASE.md` の「changeset の書き忘れは CI が止める」と google-login の節（0.x の bump 方針）

## 現状の実装

- `packages/cli/src/frameworks/hono/` がテンプレートの本体で、express と fastify は `web-standard/templates.ts` が Hono を WebRouter に置換して派生させる。Next.js は `frameworks/nextjs/` に別のテンプレートを持ち、config、store、resolvers、scopes のテンプレートだけを hono から借りている
- hono 系のルートは `frameworks/hono/pipeline.ts` の StepFragment（definition、call、imports、otherwise）を `flow/catalog.ts` のステップ順に組み立てている。生成物のハンドラには `// [step-id] ラベル — 仕様` の行が各呼び出しの上に付く
- `--db` は `frameworks/db/templates.ts`（SQL）と `kv-templates.ts`（KV）で、export 名が種類ごとに違う（`createSqlProviderStores` と `createKvProviderStores`）
- samples は CLI の生成物を `src/oidc-provider` にコミットし、`check:generated` で再生成と一致することを検査している。E2E は `E2E_OP_PACKAGE` のパッケージを `pnpm --filter <pkg> start` で起動し、`PORT` と `ISSUER` などの環境変数を渡す
- conformance は `CONFORMANCE_SAMPLE_APP`（既定 hono-cloudflare）を対象に、`run-conformance` ラベルか手動起動で走る
- CLI の runtime dependencies は空で、`typescript` は devDependency にしかない

## 全フェーズで守る制約

- **CLI の入口を保つ**：`generate`、`setup`、`graph` の各コマンドと、`--enable`、`--disable`、`--scope`、`--db`、`--flow`、`--output`、`--force`、`--dry-run` の各オプションは、名前も意味も変えない。生成物の形は変えてよい
- **CLI の runtime dependencies を空のまま保つ**：所有者付きブロックの除去や `--flow` の並べ替えに TypeScript コンパイラ API を使わない。ブロックは `// [step-id]` 行から次のブロックの直前までの文の並びとして行単位で扱い、import の除去はパスで判定する
- **pipeline.ts の import を制限する**：pipeline.ts（Next.js では route.ts）が持つ import は、同じエンドポイントの `steps/`、`features/<id>/`、base の応答ヘルパーに限る。core の関数はステップ側で import する。これにより、ブロックを消したあとに残る import をパスだけで判定できる
- **所有者付きブロックの参照先を制限する**：機能が所有するブロックが参照する識別子は、その機能ディレクトリからの import に限る。base の識別子を参照したいときは、設計の「任意入力」の形で base のステップに渡す
- **base は features と experimental を import しない**：lint で検査し、CI で強制する。`features/<a>` が `features/<b>` を import できるのは、registry で `requires` を宣言したときだけ
- **フックは 11 種類の固定集合**：routes、discovery、context、config、token の grants と grantValidators と issuers、authorize の requestResolvers と responseModes、introspection の responders、loginMethods。種類を足したいときは作業を止めて作業報告に理由を書く
- **dependencies にはモノレポ内のライブラリだけ**：apps の hono、next、react、@hono/node-server などは samples と同じく devDependencies に置く
- **テストの方針**：apps の実コードには単体テストを書く（README の命名規則に従う）。生成物の文字列やファイル構成を検査するテストは書かない。生成した組合せは型検査だけで確かめる。生成 OP の挙動は E2E と conformance で確かめる
- **テスト駆動**：t_wada の方法で、テストを先に書く
- **changeset**：`packages/cli` の変更は手で changeset を書く。生成物の形が変わるフェーズ 2 とフェーズ 5 は互換性が変わるので、`RELEASE.md` の 0.x の方針に沿って minor 以上を選び、理由を changeset に書く。`packages/experimental/src` は触らない（触ると自動 changeset の対象になる）
- **実装解説**：`--enable <feature-id>` が生成する hono のコードが変わるフェーズでは、notes の `implementation-guides/experimental/` の該当節を同じ変更内で更新する。日本語版は `japanese-tech-writing` スキルに従う
- **CI のゲート**：`pnpm run test:ci-gate`、`pnpm run test:release-contract`、changeset coverage を通す。`verify-ci-gate.mjs` は `packages/*` の typecheck スクリプトを検査するので、apps を加えるときは検査対象の読み方も合わせて直す
- **notes への書き戻し**：クラウドセッションでは GitHub の Contents API で notes の `main` へ直接コミットし、notes にはプルリクエストを作らない（`docs/cloud-session-bootstrap.md`）
- **設計ドキュメントの扱い**：未決事項を決めたときだけ「未決事項」の節を更新する。設計そのものを変えたいときは作業を止め、理由を作業報告に書く
- **フェーズをまたがない**：指定されたフェーズの範囲外は、気付いた点を作業報告に書くにとどめる

## 修正方針

### フェーズ 1: apps/hono を起こし、E2E をそこへ向ける

CLI と samples には触らない。
`samples/hono-cloudflare/src/oidc-provider` にある現在の生成物（全機能オン、`--db sql`）を出発点にして、設計のレイアウトへ組み替える。

1. `pnpm-workspace.yaml` に `apps/*` を足し、`apps/hono` を `@maronn-openid-connect/app-hono`（private）として作る。スクリプトは `dev`（tsx の watch で `src/server.ts` を起動）、`build`、`start`、`test`（vitest）、`typecheck` を持つ。`start` は E2E の契約を満たす。`PORT` と `ISSUER` で待ち受け先を決め、`/.well-known/openid-configuration` が応答し、E2E が渡すそのほかの環境変数（`tests/e2e/playwright.config.ts` を参照）を express サンプルと同じ名前で受ける
2. `src/server.ts` はメモリ DB で起動し、開発用のクライアントとユーザーを登録する。E2E が使うクライアントは `tests/e2e` 側の期待値に合わせる
3. `src/oidc-provider/` を設計のレイアウトに組み替える。`endpoints/<endpoint>/pipeline.ts` と `steps/*.ts`、`features/<id>/feature.ts`、`db/memory/` と `db/sql/` と `db/kv/`、`features/enabled.ts`（全機能）、`db/index.ts`（memory）。各ステップに `meta`（id、endpoint、feature、kind、spec、consumes、produces、removable）を付ける
4. 機能ディレクトリは 15 個作る。stable の pkce、introspection、revocation、refresh-token、request-object、experimental の 9 個、extension の google-login。refresh-token を機能ディレクトリにするか config に倒すかは設計の未決事項なので、まず機能ディレクトリで作り、フックの数が増えすぎるなら config に倒して理由を記録する
5. 所有者付きブロックの印を決める。既定案は、base のブロックが `// [step-id] ラベル — 仕様` のまま、機能のブロックが `// [step-id] (feature: <id>) ラベル — 仕様` である。採用したら設計ドキュメントの未決事項を更新する
6. `db/sql/` と `db/kv/` は `db/memory/` と同じ export 名（`createProviderStores`、`createClientResolver`）に揃え、`app.ts` の配線を db の種類に依存させない
7. steps と features の単体テストを書く。`steps/<id>.ts` の隣に `<id>.test.ts` を置く
8. import 境界の lint を `.github/scripts/` の Node スクリプトで実装し、`pnpm run lint` から呼ぶ。README にある「lint が未導入」の TODO と `verify-ci-gate.mjs` の lint 検査を整合させる
9. `tests/e2e` に `test:e2e:app-hono` を足し、`ci.yml` の E2E をこれに切り替える。samples 四つの E2E は `e2e-samples.yml`（schedule と workflow_dispatch）へ移す
10. `README.md` を更新する。「ディレクトリの構成」に `apps/` を足し、「テストコードの書き方」を本文書の方針に書き換え、「実装におけるルール」の E2E の対象に apps を加える。「samples/* には OP 以外の役割を混在させない」は apps にも適用する

完了条件。

- [ ] `pnpm --filter @maronn-openid-connect/app-hono dev` で全機能オンの OP が起動し、`pnpm --filter @maronn-openid-connect/app-hono test` が通る
- [ ] `pnpm run test:e2e:app-hono` が既存の E2E スペックすべてで通る
- [ ] lint が base から features と experimental への import、requires 無しの features 間 import を検出する
- [ ] `pnpm run build`、`pnpm run typecheck`、`pnpm run test:ci`、`pnpm run test:ci-gate` が通る
- [ ] README の更新が済み、設計ドキュメントの未決事項（印の構文、refresh-token の扱い）が更新されている

### フェーズ 2: hono 系の生成を apps/hono からの抽出へ置き換える

hono、express、fastify の生成を新しい生成器に切り替え、hono 系の旧テンプレートを消す。
Next.js の旧テンプレートはこのフェーズでは残す。
Next.js が hono から借りている config、store、resolvers、scopes、jarm のテンプレートは `frameworks/nextjs/` 配下へ移して残す。

1. `packages/cli/extract.json` に hono の抽出範囲（`apps/hono/src/oidc-provider/**`）を書き、CLI の build で `templates/hono/` へ集める。`templates/` は gitignore し、`package.json` の `files` に加える
2. `src/features.ts` を `src/registry.ts` に作り直す。各機能の id、tier、requires、必要パッケージ、対応フレームワーク、対応ランタイムを持つ
3. `src/generate.ts` を設計の五つの手順で書く。registry でフラグを解決し、base と `features/<id>/**` と `db/<kind>/**` を選び、manifest、`features/enabled.ts`、`scopes.ts`、`db/index.ts` の四つを描画し、core のパッケージ名だけ import 指定子を書き換え、オフの機能の所有者付きブロックとその機能からの import を消す。後続のブロックが読む値は `meta` の consumes と produces から判定し、`const <name> = undefined;` を置く
4. `meta` を CLI の build で集めて `catalog.json` に焼く。このフェーズでは id、endpoint、feature、consumes、produces、removable があればよい
5. express と fastify は、抽出した hono のファイルに今と同じ WebRouter 置換を掛けて出す
6. 生成マトリクスの型検査を `packages/cli` の `test:matrix` として書き、ルートの `test:ci` から呼ぶ。組合せは、既定、全オフ、各機能単独、`--db` の三種、hono と express と fastify の三フレームワーク。生成先は一時ディレクトリで、`tsconfig` の paths で workspace の dist を解決する
7. hono 系の旧テンプレートを消す。`frameworks/hono/**`、`web-standard/**`、`db/**`、`express/`、`fastify/` のうち新生成器が引き継いだもの
8. `samples/hono-cloudflare`、`samples/express-flyio`、`samples/fastify-flyio` を新 CLI で再生成し、`check:generated` と typecheck を通す。`db/instance.ts` は各 sample が書くものなので保つ
9. `packages/cli/README.md` の「生成されるもの」以降を新しいレイアウトで書き直す
10. notes の `implementation-guides/experimental/` の 9 機能について、「CLI が生成コードへ注入するコード」の節を `features/<id>/` の全ファイルに差し替える
11. `packages/cli` の changeset を書く

完了条件。

- [ ] `maronn-oidc generate hono` の既定、`--disable` の全指定、`--enable` の各 experimental、`--enable google-login`、`--db sql` と `--db kv` が生成でき、`test:matrix` が通る
- [ ] 三つの samples の `check:generated` と `test:e2e` が通る（E2E はローカルか手動起動の `e2e-samples.yml` で確認する）
- [ ] `run-conformance` ラベルで conformance が通る
- [ ] 旧 hono 系テンプレートが消え、CLI の runtime dependencies が空のままである
- [ ] 実装解説 9 本の日本語版と英語版が更新され、notes にコミットされている
- [ ] changeset があり、`pnpm run test:release-contract` と changeset coverage が通る

### フェーズ 3: graph と --flow を meta 由来の catalog.json へ載せ替える

1. `catalog.json` に label、kind、spec、edges、after、before、calledFrom、fallback、エンドポイントのメタデータ（path、methods、layer、group、rearrangeable、initial）を加える。`flow/catalog.ts` が持っていた情報はすべて `meta` とエンドポイントの定義ファイルへ移す
2. `graph` を `catalog.json` から描く。Mermaid と JSON の出力は今と同じ形を保つ
3. `--flow` の検証（消したステップの produces を残るステップが読んでいないか、after と before の順序）を `catalog.json` で行う
4. `--flow` の並べ替えを pipeline.ts の所有者付きブロックの並べ替えとして実装する。消したステップの import はパスで消し、fallback が true のステップの produces には `const <name> = undefined;` を置く
5. `flow/catalog.ts` を消し、`flow/` のテストを `catalog.json` 前提に書き直す
6. Next.js は今まで通り並べ替えを拒否する

完了条件。

- [ ] `maronn-oidc graph` と `graph --detail steps --endpoint token` の出力が、フェーズ 2 以前の出力と同じ箱と矢印を持つ
- [ ] `test:matrix` に「並べ替えた flow 文書」の組合せが加わり、通る
- [ ] `flow/catalog.ts` が消え、`packages/cli` のテストが通る

### フェーズ 4: apps/nextjs を起こし、E2E をそこへ向ける

1. 現在の CLI で `maronn-oidc generate nextjs` を Next.js が対応するすべての機能と `--db kv` で生成し、その出力を `apps/nextjs/src/app/` の出発点にする。Next.js が対応していない機能があれば作業報告に列挙する
2. `apps/nextjs` を `@maronn-openid-connect/app-nextjs`（private）として作る。`dev` は `next dev`、`start` は `next build` 後の `next start` で、`PORT` と `ISSUER` を受ける
3. ルートを持つ機能は route group `(<feature-id>)/` の下へ、ルートを持たない機能ロジックは `_oidc-provider/features/<id>/` へ移す。`_oidc-provider/features.ts` が有効な機能を列挙する
4. route.ts のハンドラに所有者付きブロックの印を付け、`meta` を置く
5. 単体テストを書き、`tests/e2e` に `test:e2e:app-nextjs` を足して `ci.yml` に加える
6. `README.md` の「ディレクトリの構成」を更新する

完了条件。

- [ ] `pnpm --filter @maronn-openid-connect/app-nextjs dev` で OP が起動し、`test:e2e:app-nextjs` が Next.js 対象の E2E スペックで通る
- [ ] lint が apps/nextjs にも効く

### フェーズ 5: Next.js の生成を apps/nextjs からの抽出へ置き換え、旧 generator を消す

1. `extract.json` に nextjs の抽出範囲（`apps/nextjs/src/app/**`）と除外（`layout.tsx` などアプリ側の土台）を書く
2. `generate.ts` を Next.js に対応させる。ファイル選択は `(<id>)/**` と `_oidc-provider/features/<id>/**`、描画は `_oidc-provider/features.ts` と manifest と scopes と db、import の書き換えは無し、所有者付きブロックの除去は hono と同じ
3. `packages/cli/src/frameworks/**` を消す
4. `samples/nextjs-vercel` を再生成し、`check:generated` と typecheck を通す
5. `test:matrix` に nextjs を加える
6. `packages/cli/README.md` の「Next.js の生成物」を書き直し、`README.md` と `samples/README.md` を最終形に揃える
7. `packages/cli` の changeset を書く

完了条件。

- [ ] `packages/cli/src/frameworks/` が存在しない
- [ ] 四つの samples の `check:generated` と、手動起動の `e2e-samples.yml` が通る
- [ ] `run-conformance` ラベルで conformance が通る
- [ ] changeset があり、CI のゲートがすべて通る

## テスト要件

- apps の単体テストは README の命名規則（`should` で始まる、関数名の `describe`）に従い、`it` の中に `if` を書かず、合格値を一意に固定する
- `test:matrix` は型検査だけを行い、生成物の内容を文字列で検査しない
- E2E は PR ごとに apps を対象に走り、samples は nightly と手動起動で走る
- conformance はフェーズ 2 とフェーズ 5 で `run-conformance` ラベルを付けて走らせる

## 完了条件

- [ ] フェーズ 1 から 5 がそれぞれ別のプルリクエストで main に入っている
- [ ] CLI の生成コードが文字列リテラルとして存在しない
- [ ] 第三者が生成コードを直すとき、`apps/` の実コードと隣のテストを変えるだけで済む
- [ ] 設計ドキュメントの未決事項がすべて決まり、記録されている
