# [P2] OSS実装に関係しない資産を notes リポジトリへ集約し、公開規約を README.md に切り出す

## ステータス

✅ Medium / 完了

2026-08-23 にフェーズ0〜3、ローカルリンク、公開アクセス、ビルドおよびテストを確認した。
同日、依頼者の判断により、Claude Code on the Web の環境設定、クラウド固有の検証、ルーティーン2件の更新と実行をスコープから外した。

## 背景

公開リポジトリには OSS 実装に関係するものだけを置きたい。
作業メモ、レビュー資料、エージェント設定、個人用の実装解説は、別リポジトリ（notes）で git 管理する。

ローカルでは OSS実装リポジトリ配下から今までどおり参照したいので、notes 側の実体へシンボリックリンクを張る。

## 決定事項

2026-08-23 に依頼者が判断した内容を設計の前提とする。

1. `CLAUDE.md` の公開してよい部分を `README.md` へ切り出す
2. `tasks/` と `study-material/` を notes リポジトリへ移す。`scripts/experimental-review/` は意義が弱いため削除してよい
3. 本タスク文書自身も notes リポジトリへ移す
4. Claude Code on the Web からも notes の内容を取得できるようにする（決定7で撤回）
5. `.review/` `.claude/` `.agents/` など文書・設定系のディレクトリも公開リポジトリに残さない。OSS 実装に関係しないものは全部外す
6. `docs/implementation-guides/experimental/` は個人用なので notes へ移す
7. Claude Code on the Web の対応とルーティーンの更新は行わない

決定5により、ブートストラップ用のスクリプトも OSS 側には置かない。
リンクを張るスクリプトは notes リポジトリに置き、そこから OSS実装リポジトリへ symlink とフックだけを配る。

## 移す・残す・消すの一覧

notes 側のディレクトリ名は、先頭ドットを外した名前に揃える（notes リポジトリ自体は隠しディレクトリの集合ではないため）。

### notes リポジトリへ移すもの

| 現在の場所 | notes 側 | OSS 側に張るリンク | 容量 |
|---|---|---|---|
| `CLAUDE.md` | `CLAUDE.md` | `CLAUDE.md -> .notes/CLAUDE.md` | 19 KB |
| `AGENTS.md` / `GEMINI.md` | （実体は持たない） | `AGENTS.md -> CLAUDE.md` / `GEMINI.md -> CLAUDE.md` | — |
| `tasks/` | `tasks/` | `tasks -> .notes/tasks` | 2.9 MB |
| `study-material/` | `study-material/` | `study-material -> .notes/study-material` | 3.5 MB |
| `.review/` | `review/` | `.review -> .notes/review` | 36 KB |
| `.claude/`（skills / docs / settings.json） | `claude/` | `.claude -> .notes/claude` | 508 KB |
| `.agents/` | `agents/` | `.agents -> .notes/agents` | 172 KB |
| `.serena/` | `serena/` | `.serena -> .notes/serena` | 20 KB |
| `.mcp.json` | `mcp.json` | `.mcp.json -> .notes/mcp.json` | 339 B |
| `docs/implementation-guides/` | `implementation-guides/` | `docs/implementation-guides -> ../.notes/implementation-guides` | 1.2 MB |

### 削除するもの

| 対象 | 理由 |
|---|---|
| `scripts/experimental-review/`（100 KB） | 決定2。`tasks/experimental/` を読むため移送すると壊れる。生成済みパケットは `tasks/` と一緒に notes へ残る |
| `package.json` の `review:experimental` / `test:experimental-review` | 上と同じ。`test:ci` の連結からも外す |
| `.codex`（0 バイトの空ファイル） | 中身が無く、役割も残っていない |

### 公開リポジトリに残すもの

`packages/` `samples/` `tests/` `docs/library-document/` `scripts/`（`sample-up.sh` と `lib/`）`.github/` `.changeset/` `package.json` `pnpm-lock.yaml` `pnpm-workspace.yaml` `LICENSE` `RELEASE.md`、および新規に作る `README.md`。

## 着手前に確定している事実

2026-08-23 に、main（`65a4956`）と git 2.43.0 で検証した結果を先に置く。

### notes リポジトリは public のまま使い、コミットが 1 つも無い

認証情報なしで `git clone` が成功し、`warning: You appear to have cloned an empty repository.` が返る。
依頼者の追加判断により、リポジトリは public のまま使う。
そのため、クラウドセッションは GitHub App の追加許可なしで notes を clone できる。
Contents API で書き戻すセッションだけは、notes リポジトリへの書き込み権限が必要になる。

### `CLAUDE.md` は追跡されている

`git ls-files CLAUDE.md` はヒットする。
初出は `45df806 first commit`、以後 7 コミット、現在 19,079 バイト。

### `AGENTS.md` と `GEMINI.md` は `CLAUDE.md` を指す追跡済みシンボリックリンク

```
$ git ls-files -s | grep ^120000
120000 681311eb9cf453d0faddf3aacaec7357e97ba8e9 0	AGENTS.md
120000 681311eb9cf453d0faddf3aacaec7357e97ba8e9 0	GEMINI.md
```

`CLAUDE.md` だけを追跡から外すと、この 2 つは公開ツリーで壊れたリンクとして残る。

### `.notes/` という `.gitignore` パターンではシンボリックリンクを無視できない

末尾スラッシュ付きのパターンはディレクトリだけにマッチし、git はシンボリックリンクをディレクトリとして扱わない。

```
$ printf '.notes/\n' > .gitignore
$ ln -sfn ../notesrepo .notes
$ git status --porcelain
?? .notes          # 無視されていない
```

スラッシュを外した `.notes` なら、シンボリックリンクでもディレクトリでも無視される。
先頭スラッシュを付けた `/.notes` にすると、ルート直下だけに限定できる。

### git alias で `pull` と `fetch` は上書きできない

git は組み込みコマンドを隠すエイリアスを無視する。

```
$ git config alias.status '!echo ALIAS_STATUS_RAN'
$ git status
On branch master        # エイリアスは実行されない
```

`git pull` の追従は `.git/hooks/post-merge` で実装する。
git 2.43.0 では fast-forward の pull でも post-merge が動き、フックの cwd はワークツリーのルートになることを実測した。
`git fetch` 単体と `git pull --rebase`（post-merge ではなく post-rewrite が動く）は notes 側の `scripts/pull.sh` を直接叩く。

### `ln -sfn` は宛先が実ディレクトリのとき、その中にリンクを作る

終了コードは 0 で、失敗として検出できない。
移送前のディレクトリが残ったままリンクを張ると静かに壊れるため、スクリプト側で事前判定する。

### 公開ファイルに残る参照

移送すると解決できなくなる参照は次のとおり。

| 参照先 | 参照元 | 件数 |
|---|---|---|
| `CLAUDE.md` | `RELEASE.md` 2 / `docs/implementation-guides/experimental/README.md` 2 / `samples/README.md` 1 / `samples/*/scripts/deploy-*.sh` 2 / `scripts/lib/deploy-fly-node-sample.sh` 1 / `packages/cli/src/frameworks/hono/templates.ts` 2 | 10 |
| `tasks/*.md` `study-material/*.md` | `docs/implementation-guides/experimental/*` 36 / `packages/experimental/src/device-authorization-grant/verification.ts` 2 / `packages/cli/src/frameworks/hono/templates.ts` 2 / `packages/core/src/token-response.ts` 1 / `packages/cli/src/__tests__/hono-generator.test.ts` 1 / `tests/conformance/README.md` 1 / `.github/scripts/verify-ci-gate.mjs` 1 | 44 |
| `docs/implementation-guides/experimental/` | `packages/experimental/README.md:72` | 1 |

`docs/implementation-guides/` 自体が notes へ移るので、そこからの 36 件と `CLAUDE.md` 参照 2 件は一緒に移動する。
公開側に残って直す必要があるのは、`CLAUDE.md` 参照 8 件、メモパス参照 8 件、実装解説への参照 1 件になる。

`packages/cli/src/frameworks/hono/templates.ts` の 2 件は生成コードへ出力され、`samples/*/src/oidc-provider/` の 8 箇所がその実体になっている。
`packages/experimental/src/.../verification.ts` の 2 件は実装解説に全文掲載されているため、直したら解説側も同じ変更で直す。

### ビルドとテストはメモ類を読まない

`.github/workflows/`、`vitest.config.ts`、`pnpm-workspace.yaml` のいずれもメモ類に依存していない。
`pnpm-workspace.yaml` の対象は `packages/*` `samples/*` `tests/*` `docs/*` で、`docs/implementation-guides` には `package.json` が無いためワークスペースには入らない。
`docs/library-document` のサイトも実装解説を参照していない。

例外は昇格レビューツールで、`scripts/experimental-review/lib/repo.mjs:62-63` が `tasks/experimental/<feature-id>` を読む。
`pnpm run test:experimental-review` は `pnpm run test:ci` に含まれており、`tasks/` を移すとここだけが壊れる。
決定2に従って削除する。

`.github/scripts/verify-ci-gate.mjs` が要求するのは `pnpm run build` → `pnpm run typecheck` → `pnpm run test:ci` の順序だけで、`test:ci` の内訳は検査していない。

### クラウド実行の制約

Claude Code のドキュメント（cloud environments / claude-code-on-the-web / hooks）で確認した制約が 4 つある。
どれも設計に直接効く。

1. **セットアップスクリプトはキャッシュされる**。環境のセットアップスクリプトは初回セッションでだけ走り、その後はファイルシステムのスナップショットが再利用される（スクリプトを変更したときと約 7 日で再実行）。ここで notes を clone しても、次のセッションでは古いまま使われる。毎セッション必要な取得はここに置けない
2. **環境変数に資格情報を置くことは推奨されていない**。cloud environment には専用のシークレットストアが無く、環境を使う人は全員値を読める
3. **`git push` はセッションの作業ブランチにしか通らない**。GitHub プロキシの push protection により、セッションが開いているリポジトリの作業ブランチ以外への push は拒否される。clone / fetch / PR 操作は通る
4. **GitHub API はセッションに attach したリポジトリにしか届かない**。attach していないリポジトリへの API 要求は 403 になる

制約3と4から、クラウドセッションから notes を更新する経路は「notes リポジトリを attach し、Contents API（`gh api` または GitHub MCP の `create_or_update_file` / `push_files`）でコミットする」になる。
`git push` は使えない。

制約1から、毎セッションの notes 取得はセットアップスクリプトではなくセッション側（ルーティーンのプロンプト、または SessionStart フック）で行う。

### SessionStart フックの契約と限界

SessionStart フックは終了コード 0 で次の JSON を出すと、その内容がセッションの文脈に入る。

```json
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "..."
  }
}
```

プレーンテキストの標準出力もそのまま文脈へ入り、フックはセッション開始をブロックできない。

ただしフックは Claude Code の起動後に走るため、フックが作った `CLAUDE.md` や `.claude/skills/` がその場で読み込まれる保証は無い。
さらに今回の構成では `.claude/settings.json` 自体が notes 側へ移るので、notes を取得する前にフック定義が存在しない。
クラウドでは、フックではなく**ルーティーンのプロンプト冒頭の手順**を一次の経路とする（フェーズ4）。

### 影響を受けるルーティーン

アカウントに登録されている 7 件のうち、このリポジトリを対象にしているのは 2 件。

| ID | 名前 | 影響 |
|---|---|---|
| `trig_016iJPrzys767Mh4RKXxZZfv` | リポジトリのコードレビューとタスク実装 | `study-material/` `tasks/` `CLAUDE.md` `.claude/skills/` `docs/implementation-guides/` を読み書きする。全面的に修正が要る |
| `trig_01GjuLdeCrwEQVLisnKh1QXU` | Experimental機能 仕様策定・レビュー・実装 | `tasks/experimental/` `CLAUDE.md` `.claude/skills/` `docs/implementation-guides/experimental/` `pnpm review:experimental` を参照する。全面的に修正が要る |
| `trig_01SXA2TNgjZWWvagYqAdJSWa` | @maronn-openid-connect パッケージ追従（週次） | 対象は `maronnjapan/publish-oidc-app`。公開パッケージの `--help` だけを見るため影響なし |

残る 4 件（AIポートフォリオ 3 件、クイズ作成、トークンリミット調整）は別リポジトリで、影響しない。

## 全体像

| フェーズ | 内容 | 前提 |
|---|---|---|
| 0 | notes リポジトリの初期コミットと公開アクセスを確認する | なし |
| 1 | `README.md` の切り出しと `CLAUDE.md` の分離 | 0 |
| 2 | メモ・設定・実装解説の移送と参照修復 | 1 |
| 3 | 昇格レビューツールの削除 | 2 |
| 4 | クラウド実行からの notes 取得（スコープ外） | 2 |
| 5 | ルーティーン 2 件の修正（スコープ外） | 2〜4 |

## フェーズ0: notes リポジトリの前提整備

- [x] notes リポジトリを public のまま維持する
- [x] 認証なしの `git clone` が成功することを確認する
- [x] `/var/www/notes-maronn-openid-connect` の内容を push し、リモートが空でない状態にする
- [x] `/var/www/maronn-openid-provider` の origin が `https://github.com/maronnjapan/maronn-openid-connect` であることを確認する

## フェーズ1: `README.md` の切り出しと `CLAUDE.md` の分離

### タスク1-1: `README.md` を作る

`CLAUDE.md` の次の節を `README.md` へ移す。
公開ライブラリの読者に向けた文書になるので、移したあとに宛先（開発者向けか利用者向けか）が混ざっていないかを見直す。

| 移す節 | 補足 |
|---|---|
| プロジェクトについて（コンセプト、ターゲットユーザー、差別化の3軸、リリース方針、利用者の入口） | そのまま |
| 実装におけるルール | 実装解説の作成先を notes 側に書き換える |
| ドキュメント作成の規約 | スキルの参照先を notes 側に書き換える |
| テストコードの書き方 | そのまま |
| コマンド | そのまま |
| アーキテクチャ | そのまま |
| 準拠仕様 | そのまま |
| ディレクトリの構成 | `tasks/` `study-material/` の記述を落とす |

`.notes/CLAUDE.md` に残すのは次の 4 つ。

- `README.md` を先に読むよう促す 1 行
- レビュー内容について（`.review/` の運用）
- `tasks/` と `study-material/` の運用（notes 配下にある旨とパス）
- 実装解説の置き場所（`.notes/implementation-guides/`）と作成規約

「experimental 機能の昇格レビュー」の節は、フェーズ3のツール削除に合わせて消す。

- [x] `README.md` を作成する（`japanese-tech-writing` スキルを使う）
- [x] `.notes/CLAUDE.md` を上記 4 点に絞る

### タスク1-2: `CLAUDE.md` の実体を notes リポジトリへ移す

- [x] `CLAUDE.md` を `/var/www/notes-maronn-openid-connect/CLAUDE.md` へ移してコミットする

### タスク1-3: `.gitignore` の更新

`.gitignore` は用途ごとのコメント見出しで区切られている。
末尾に次の節を追加する。

```
# Personal working set (kept in the notes repository)
/.notes
/CLAUDE.md
/AGENTS.md
/GEMINI.md
/tasks
/study-material
/.review
/.claude
/.agents
/.serena
/.mcp.json
/docs/implementation-guides
```

- [x] 先頭スラッシュ付きで追記する（ルート直下だけを対象にするため）
- [x] `.notes` に末尾スラッシュを付けない（シンボリックリンクにマッチしなくなるため）

### タスク1-4: 追跡を外す

- [x] `git rm --cached CLAUDE.md AGENTS.md GEMINI.md` を実行する
- [x] `.gitignore` と `README.md` の変更と合わせて 1 コミットにする

### タスク1-5: notes リポジトリにリンク用スクリプトを置く

OSS 側にはスクリプトを置かない（決定5）。
notes リポジトリに `scripts/link-oss-repo.sh` と `scripts/pull.sh` を作る。

```bash
#!/usr/bin/env bash
# notes リポジトリを OSS 実装リポジトリのチェックアウトへリンクする。
#
#   bash scripts/link-oss-repo.sh [OSS リポジトリのパス]
#
# 既定は /var/www/maronn-openid-provider。OSS_REPO_PATH でも指定できる。
# OSS 側にはファイルを置かず、symlink と post-merge フックだけを張る。
set -euo pipefail

NOTES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OSS_ROOT="${1:-${OSS_REPO_PATH:-/var/www/maronn-openid-provider}}"
EXPECTED_REPO="maronn-openid-connect"

BLOCKED=0

info() { printf 'ℹ %s\n' "$*"; }
ok()   { printf '✔ %s\n' "$*"; }
err()  { printf '✗ %s\n' "$*" >&2; }

if [ ! -e "${OSS_ROOT}/.git" ]; then
  err "${OSS_ROOT} が git リポジトリではありません。"
  exit 1
fi
remote="$(git -C "${OSS_ROOT}" remote get-url origin 2>/dev/null || echo '')"
case "${remote}" in
  *"${EXPECTED_REPO}"*) ;;
  *)
    err "${OSS_ROOT} の origin が ${EXPECTED_REPO} ではありません: ${remote}"
    exit 1
    ;;
esac
OSS_ROOT="$(cd "${OSS_ROOT}" && pwd)"

# link <OSS 側の相対パス> <リンク先>
link() {
  local dest="${OSS_ROOT}/$1" target="$2"
  if [ -e "${dest}" ] && [ ! -L "${dest}" ]; then
    # ln -sfn は宛先が実ディレクトリのとき、その中にリンクを作って成功扱いになる。
    err "$1 が実体として残っています。notes へ移してから再実行してください。"
    BLOCKED=$((BLOCKED + 1))
    return 0
  fi
  mkdir -p "$(dirname "${dest}")"
  ln -sfn "${target}" "${dest}"
  ok "$1 -> ${target}"
}

# notes 側に存在するときだけ張る（段階移行の途中でも動くように）
link_if_present() {
  local notes_path="$1" oss_path="$2" target="$3"
  if [ -e "${NOTES_ROOT}/${notes_path}" ]; then
    link "${oss_path}" "${target}"
  else
    info "${notes_path} は notes 側に無いのでスキップします。"
  fi
}

link .notes "${NOTES_ROOT}"

link_if_present CLAUDE.md CLAUDE.md .notes/CLAUDE.md
if [ -L "${OSS_ROOT}/CLAUDE.md" ]; then
  link AGENTS.md CLAUDE.md
  link GEMINI.md CLAUDE.md
fi
link_if_present tasks                 tasks                      .notes/tasks
link_if_present study-material        study-material             .notes/study-material
link_if_present review                .review                    .notes/review
link_if_present claude                .claude                    .notes/claude
link_if_present agents                .agents                    .notes/agents
link_if_present serena                .serena                    .notes/serena
link_if_present mcp.json              .mcp.json                  .notes/mcp.json
link_if_present implementation-guides docs/implementation-guides ../.notes/implementation-guides

HOOK_PATH="$(git -C "${OSS_ROOT}" rev-parse --git-path hooks/post-merge)"
case "${HOOK_PATH}" in /*) ;; *) HOOK_PATH="${OSS_ROOT}/${HOOK_PATH}" ;; esac
if [ -e "${HOOK_PATH}" ] && ! grep -q 'maronn-notes-sync' "${HOOK_PATH}"; then
  info "既存の post-merge フックがあるため上書きしません: ${HOOK_PATH}"
  info '次の1行を追記してください: "$(git rev-parse --show-toplevel)/.notes/scripts/pull.sh" || true'
else
  mkdir -p "$(dirname "${HOOK_PATH}")"
  cat > "${HOOK_PATH}" <<'HOOK'
#!/usr/bin/env sh
# maronn-notes-sync: notes リポジトリの link-oss-repo.sh が生成。git pull 後に notes を追従させる。
"$(git rev-parse --show-toplevel)/.notes/scripts/pull.sh" || true
HOOK
  chmod +x "${HOOK_PATH}"
  ok "post-merge フックを設定しました。"
fi

if [ "${BLOCKED}" -gt 0 ]; then
  err "${BLOCKED} 件は実体が残っているためリンクできませんでした。"
  exit 1
fi
ok "リンクを張り終えました。"
```

```bash
#!/usr/bin/env bash
# notes リポジトリを最新へ追従させる。post-merge フックからも呼ばれる。
set -euo pipefail
NOTES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# フック経由のとき、外側リポジトリの git 環境変数を引き継がない。
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX
if ! git -C "${NOTES_ROOT}" fetch --quiet; then
  printf '⚠ notes の fetch に失敗しました。\n' >&2
  exit 1
fi
if ! git -C "${NOTES_ROOT}" pull --ff-only --quiet; then
  printf '⚠ notes を fast-forward できませんでした。手動で確認してください。\n' >&2
  exit 1
fi
printf '✔ notes を更新しました。\n'
```

- [x] 2 本とも `chmod +x` する
- [x] `pull.sh` は `--ff-only` にする（メモ側にローカル変更があるとき、勝手にマージコミットを作らないため）

### タスク1-6: 動作確認

この 2 本のスクリプトは、notes 側と OSS 側の upstream を模したサンドボックスで実行し、12 本のリンク生成、リンク越しの読み取り、`git status` が汚れないこと、サブディレクトリからの `git pull` での追従、ガード（実体が残っている / origin が別リポジトリ / 既存 post-merge フックあり / 再実行）を確認してある（2026-08-23、git 2.43.0）。
実環境では次を確認する。

- [x] `bash /var/www/notes-maronn-openid-connect/scripts/link-oss-repo.sh` を実行する
- [x] `readlink CLAUDE.md` が `.notes/CLAUDE.md` を返し、`cat CLAUDE.md` で notes 側の中身が読める
- [x] `git status --porcelain` に移送対象が現れない
- [x] `git -C .notes rev-parse HEAD` を控えてから `packages/core` で `git pull` を実行し、notes 側の HEAD も更新される

## フェーズ2: メモ・設定・実装解説の移送と参照修復

### タスク2-1: 移送

- [x] 「移す・残す・消すの一覧」の表に従って notes リポジトリへコピーし、notes 側でコミットする
- [x] OSS 側で `git rm -r` し、`.gitignore` の追加と同じコミットにまとめる
- [x] 本タスク文書も `tasks/` と一緒に移す（決定3）
- [x] `.codex` を削除する
- [x] `bash /var/www/notes-maronn-openid-connect/scripts/link-oss-repo.sh` を再実行し、12 本のリンクが張られることを確認する
- [x] `.claude` がリンク経由でも Claude Code から読めること（スキルとサブエージェントが認識されること）をローカルセッションで確認する

### タスク2-2: 参照修復

パスを書かず、内容で説明する形へ寄せる。

- [x] `RELEASE.md:161` / `:468` の `CLAUDE.md` 参照を `README.md` へ
- [x] `samples/README.md:3`、`samples/nextjs-vercel/scripts/deploy-vercel.sh:7`、`samples/hono-cloudflare/scripts/deploy-cloudflare.sh:7`、`scripts/lib/deploy-fly-node-sample.sh:10` の `CLAUDE.md` 参照を `README.md` へ
- [x] `packages/cli/src/frameworks/hono/templates.ts` の 4 件（`CLAUDE.md` 2 件、メモパス 2 件）。生成コードへ出るので、修正後に `samples/*` を再生成する
- [x] `packages/experimental/src/device-authorization-grant/verification.ts` の 2 件。掲載元の実装解説（notes 側へ移動済み）も同じ変更で直す
- [x] `packages/core/src/token-response.ts` の 1 件、`packages/cli/src/__tests__/hono-generator.test.ts` の 1 件、`tests/conformance/README.md` の 1 件、`.github/scripts/verify-ci-gate.mjs` の 1 件
- [x] `packages/experimental/README.md:72` の実装解説への参照。OSS 実装リポジトリから外す資料なので、参照ごと落とす
- [x] `grep -rnE '(tasks|study-material|docs/implementation-guides)/[A-Za-z0-9._/-]+' --exclude-dir=node_modules .` と `grep -rn 'CLAUDE\.md' --exclude-dir=node_modules .` が 0 件になる

### タスク2-3: 動作確認

- [x] `pnpm run build` と `pnpm run typecheck` が通る
- [x] `pnpm --filter "./packages/*" test` が通る
- [x] `pnpm run test:conformance` が通る（`samples/*` を再生成したため）

## フェーズ3: 昇格レビューツールの削除

- [x] `scripts/experimental-review/` を削除する
- [x] `package.json` から `review:experimental` と `test:experimental-review` を削除し、`test:ci` の連結からも外す
- [x] `docs/library-document` 側に昇格レビューへの言及が無いことを確認する（現状は無い）
- [x] notes 側へ移した実装解説（`package-overview.{ja,en}.md` と `README.md`、計 6 箇所）の言及を削除または書き換える
- [x] `pnpm run test:ci` と `pnpm run test:ci-gate` が通る

## フェーズ4: クラウド実行からの notes 取得（スコープ外）

2026-08-23 の依頼者判断により、このフェーズは実施しない。
以下の未チェック項目は残作業ではなく、当初案を記録するために残している。

「クラウド実行の制約」に挙げた 4 点により、経路は次のように分かれる。

| 用途 | 経路 |
|---|---|
| 共通ツールの導入（`gh` など） | 環境のセットアップスクリプト。キャッシュされるので毎回は走らない |
| notes の取得とリンク | セッションごとに実行する。ルーティーンはプロンプト冒頭の手順として持つ |
| notes への書き戻し | notes リポジトリを attach し、Contents API でコミットする。`git push` は通らない |

### タスク4-1: 環境のセットアップスクリプトを整える

現在 `.claude/settings.json` にある SessionStart フック（`npx -y gh-setup-hooks`）は、`.claude` の移送で公開リポジトリから消える。
同じ役目を環境側へ移す。

- [ ] cloud environment（ルーティーンが使う `env_01PiSbws3dCeheBW4X8733eC`）のセットアップスクリプトに `npx -y gh-setup-hooks || true` を入れる
- [ ] セットアップスクリプトで notes を clone しない（キャッシュされて古い内容が固定されるため）
- [ ] 資格情報を環境変数へ置かない（専用のシークレットストアが無く、環境を使う人が全員読める）

### タスク4-2: セッションごとのブートストラップ手順を決める

次の 3 手をルーティーンのプロンプト（フェーズ5）と、手動セッション用の手順書（notes 側）に載せる。

1. `git clone https://github.com/maronnjapan/notes-maronn-openid-connect /opt/notes`
2. `bash /opt/notes/scripts/link-oss-repo.sh <OSS リポジトリのパス>`
3. `.notes/CLAUDE.md` を読む。公開側の規約は OSS リポジトリの `README.md`

- [x] 手順書を notes リポジトリの `docs/cloud-session-bootstrap.md`（仮）に置く
- [x] スキルはリンク作成が Claude Code の起動後になるため、スキルとして自動認識されない場合がある。その場合は `.notes/claude/skills/<name>/SKILL.md` を直接読んで従う旨を手順書に明記する

### タスク4-3: 取得と書き戻しの経路を実地確認する

取得は public clone で行い、書き戻しだけが GitHub App の許可状況とツールの可否に依存する。
移送後にクラウドセッションを 1 つ開いて確かめる。

- [ ] notes リポジトリの追加操作なしで `git clone` が成功する
- [ ] `link-oss-repo.sh` が通り、`cat CLAUDE.md` で notes の内容が読める
- [ ] 書き戻し前に notes リポジトリをセッションへ追加できる
- [ ] Contents API（`gh api` または GitHub MCP の `create_or_update_file`）で notes リポジトリへ 1 ファイルコミットできる
- [ ] `git push` で notes へ push しようとすると拒否されることを確認する（push protection の確認。拒否が正しい挙動）

いずれかが通らない場合の代替を決めておく。

- 取得が通らない → ルーティーンはメモを必要とする作業を行わず、その旨を報告して終了する
- 書き戻しが通らない → ルーティーンは成果物をセッションの出力として残し、人間がローカルで notes へコミットする

## フェーズ5: ルーティーンの修正（スコープ外）

2026-08-23 の依頼者判断により、このフェーズは実施しない。
以下の未チェック項目は残作業ではなく、当初案を記録するために残している。

対象は 2 件。
どちらも移送が完了してから更新する（先に更新すると、まだ存在しないパスを参照して失敗する）。

### 共通: プロンプト冒頭に足すブロック

```markdown
## 作業メモの取得（最初に必ず実行する）

このリポジトリの作業メモ（CLAUDE.md / tasks / study-material / レビュー資料 / 実装解説 / skills）は
notes リポジトリ `maronnjapan/notes-maronn-openid-connect` にある。
OSS リポジトリを用意したら、次を実行してから作業を始める。

1. `git clone https://github.com/maronnjapan/notes-maronn-openid-connect /opt/notes`
2. `bash /opt/notes/scripts/link-oss-repo.sh <OSS リポジトリのパス>`
3. `.notes/CLAUDE.md` を読む。公開側の規約は OSS リポジトリの README.md

取得できなかった場合は、メモを必要とする作業（tasks の選定、study-material の作成、
実装解説の作成）を行わず、取得できなかったことを報告して終了する。

## メモの書き戻し

notes リポジトリへは `git push` できない（クラウドセッションの GitHub プロキシは、
セッションの作業ブランチ以外への push を拒否する）。
notes 側のファイルを追加・更新するときは GitHub の Contents API を使う
（`gh api` または GitHub MCP の create_or_update_file / push_files）。
書き込み前に notes リポジトリをセッションへ追加し、書き込み権限を有効にする。
コミット先は notes リポジトリの main で、PR は作らない。
OSS リポジトリのコード変更は従来どおりブランチと PR で行う。
```

### `trig_016iJPrzys767Mh4RKXxZZfv`（リポジトリのコードレビューとタスク実装）

| 現在の記述 | 変更後 |
|---|---|
| 「CLAUDE.mdの規約に必ず従う」 | 「OSS リポジトリの `README.md` と `.notes/CLAUDE.md` の規約に必ず従う」 |
| Part 1「`study-material` 配下にファイルとして作成」 | 読むのは `study-material/`（notes へのリンク）、保存は notes リポジトリへ Contents API でコミット |
| Part 1「study-material と tasks の変更をブランチにコミットし、プルリクエストを作成してマージ」 | notes リポジトリの main へ Contents API で直接コミットする。PR は作らない |
| Part 2「tasks/ から優先度最高のファイルを1つ選ぶ」 | 参照先は変えない（リンク経由で読める）。ただしタスクファイルの `tasks/done/` への移動は notes リポジトリ側への操作になる |
| Part 2「Part 1 の PR をマージし、main を最新化してから開始」 | Part 1 は PR を作らないので、この前提を削る |
| Part 3「`docs/implementation-guides/` 配下に解説を作成」 | `.notes/implementation-guides/` 配下に作成し、notes リポジトリへコミットする |
| Part 3「`japanese-tech-writing` スキル（リポジトリの `.claude/skills/` にある）」 | 「`.notes/claude/skills/japanese-tech-writing/`。スキルとして認識されない場合は `SKILL.md` を直接読んで従う」 |
| 終了時報告 | notes へのコミットと OSS の PR を分けて報告させる |

- [ ] 上記を反映したプロンプトへ `update_trigger` で差し替える

### `trig_01GjuLdeCrwEQVLisnKh1QXU`（Experimental機能 仕様策定・レビュー・実装）

| 現在の記述 | 変更後 |
|---|---|
| 「CLAUDE.mdの規約（「ドキュメント作成の規約」を含む）」 | 「`README.md` と `.notes/CLAUDE.md` の規約」 |
| Phase 1「変更は `tasks/experimental/` 配下の仕様関連ファイルのみ」 | 参照は同じ。保存先は notes リポジトリの `tasks/experimental/` |
| Phase 1 の締め「仕様関連ファイルをブランチにコミットし、PR を作成してマージ」 | notes リポジトリの main へ Contents API でコミットする。PR は作らない |
| Phase 2「Phase 1 の PR をマージし、main を最新化してから開始」 | Phase 1 は PR を作らないので、この前提を削る |
| 開始時の確認にある `docs/implementation-guides/experimental/` | `.notes/implementation-guides/experimental/` |
| ドキュメント「`docs/implementation-guides/experimental/` に日英の実装解説を作成」 | `.notes/implementation-guides/experimental/` に作成し、notes リポジトリへコミットする |
| 「機械照合可能な diff は昇格レビューパケット（`pnpm review:experimental` の生成物）が保持する」 | 昇格レビューツールは削除済み。この一文と、パケット再生成の指示（「昇格レビューパケットの再生成が必要な場合は同じコミットに含める」）を削る |
| 「`japanese-tech-writing` スキル（リポジトリの `.claude/skills/` にある）」 | 「`.notes/claude/skills/japanese-tech-writing/`。認識されない場合は `SKILL.md` を直接読む」 |
| state.yaml の更新とタスク移動（`tasks/experimental/done/`） | notes リポジトリ側への操作として明記する |

- [ ] 上記を反映したプロンプトへ `update_trigger` で差し替える

### タスク5-1: 修正後の確認

- [ ] 各ルーティーンを 1 回手動実行し、notes の取得とリンクまで到達することを確認する
- [ ] メモの書き戻し（Contents API でのコミット）が成功することを確認する
- [ ] OSS 側の PR が従来どおり作られることを確認する
- [ ] `trig_01SXA2TNgjZWWvagYqAdJSWa`（週次のパッケージ追従）は変更しない

## 完了条件

- 公開ツリーに残るのが「移す・残す・消すの一覧」の「残すもの」だけになっている
- 公開リポジトリのルートに `README.md` があり、開発規約が読める
- `bash <notes>/scripts/link-oss-repo.sh` の実行だけで、ローカルの OSS チェックアウトが従来どおり使える
- `git pull` を実行すると、サブディレクトリからでも notes が追従する
- 公開ファイルに `CLAUDE.md` / `tasks/` / `study-material/` / `docs/implementation-guides/` への解決できない参照が残っていない
- `pnpm run test:ci` と `pnpm run test:e2e` が緑

過去の履歴に残る `CLAUDE.md` やメモ類は削除しない。
`git rm` が消すのは以後のツリーだけであり、履歴から消すには 218 コミットを書き換えて force push する必要がある。
それは 10 件以上の open PR のブランチを無効化する。

- [x] 移送対象に、公開したままにできない記述（資格情報、他者の非公開情報）が含まれていないかを確認する。含まれる場合は履歴書き換えの要否を別途判断する

## スコープ外

- 履歴からの削除（「完了条件」に理由を記載）
- notes リポジトリと OSS実装リポジトリ間の自動マージとコンフリクト解決
- Claude Code on the Web の環境設定、クラウド固有の取得および書き戻し検証、ルーティーンの更新と実行
- `git fetch` 単体をシェル側で追従させる設定。次のシェル関数を各自の `~/.bashrc` や `~/.zshrc` に置けば実現できるが、リポジトリにコミットできる設定ではないため notes 側の手順書で扱う

  ```bash
  git() {
    command git "$@" || return
    case "${1:-}" in
      fetch|pull)
        local root
        root="$(command git rev-parse --show-toplevel 2>/dev/null)" || return 0
        [ -e "${root}/.notes/scripts/pull.sh" ] && "${root}/.notes/scripts/pull.sh"
        ;;
    esac
  }
  ```

- 他 5 件のルーティーン（AIポートフォリオ 3 件、クイズ作成、トークンリミット調整、週次のパッケージ追従）。対象リポジトリが違うため影響しない

## 元の指示書からの変更点

| 元の記述 | 変更内容 | 理由 |
|---|---|---|
| notes リポジトリは非公開という前提 | public のまま初期 push し、読み取りは認証なしの clone、書き戻しだけ Contents API とする | 依頼者が private 化を不要と判断した |
| 対象は `.notes/` と `CLAUDE.md` | 文書・設定系 10 種の移送、`README.md` 切り出し、昇格レビューツール削除、ルーティーン修正まで拡張 | 依頼者の決定1〜6 |
| `.gitignore` に `.notes/` | `/.notes` ほか 12 行に変更 | 末尾スラッシュ付きパターンはシンボリックリンクにマッチしない。`AGENTS.md` と `GEMINI.md` は追跡済みリンクで、放置すると公開ツリーで壊れる |
| `git config alias.fetch` / `alias.pull` | post-merge フックと notes 側の `pull.sh` に置き換え | git は組み込みコマンドを隠すエイリアスを無視する |
| セットアップスクリプトを OSS 側の `scripts/setup-notes.sh` に置く | notes 側の `scripts/link-oss-repo.sh` に置く | 決定5。OSS 側に実装以外のファイルを増やさない |
| `ln -sfn` を無条件実行 | 実体が残っているときは報告して続行し、最後に非ゼロで終わる | 実ディレクトリ宛てだと、その中にリンクを作って成功扱いになる |
| Claude Code on the Web の対応を含める | 対象外に戻した | 依頼者の追加判断 |
| 参照修復の記載なし | 公開側に残る 17 件の修復をタスク化 | 移送すると公開ツリーから解決できなくなる |
| ルーティーンの記載なし | 対象 2 件の書き換え表を追加 | 依頼者の指示。移送後は参照先と書き戻し先が変わる |
| 受け入れ基準「コミット履歴に一切含まれていない」 | 「以後のツリーに含まれない」へ変更 | 履歴書き換えは 218 コミットの force push と open PR の無効化を伴う |
