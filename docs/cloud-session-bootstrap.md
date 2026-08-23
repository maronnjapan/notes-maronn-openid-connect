# Claude Codeクラウドセッションでnotesを使う

notes リポジトリは公開されているため、読み取りには GitHub App の追加許可や認証情報が要りません。
セットアップスクリプトはキャッシュされるので、notes の取得はセッションごとに実行します。

## セッション開始時の手順

1. notes リポジトリを `/opt/notes` へ clone する
2. notes 側のスクリプトで OSS 実装リポジトリへシンボリックリンクを張る
3. OSS 実装リポジトリの `README.md` と `.notes/CLAUDE.md` を読む

```bash
git clone https://github.com/maronnjapan/notes-maronn-openid-connect /opt/notes
bash /opt/notes/scripts/link-oss-repo.sh <OSS実装リポジトリのパス>
```

リンクの作成は Claude Code の起動後になるため、`.notes/claude/skills/` がスキルとして自動認識されない場合があります。
その場合は、必要なスキルの `.notes/claude/skills/<name>/SKILL.md` を直接読み、その指示に従います。

## notesへの書き戻し

クラウドセッションで notes を更新するときは、notes リポジトリをセッションへ追加してから GitHub Contents API を使います。
クラウドセッションの GitHub プロキシは、セッションの作業ブランチ以外への `git push` を拒否するためです。
`gh api` または利用可能な GitHub 連携のファイル更新機能で、notes リポジトリの `main` へコミットします。
notes 側には PR を作りません。

読み取りに失敗した場合は、タスクの選定、調査資料の作成、実装解説の作成など、notes の内容に依存する作業を行わず、失敗内容を報告します。
書き戻しに失敗した場合は、変更内容をセッションの出力として残し、ローカル環境から notes へ反映します。

## ローカルでfetchにも追従させる場合

`git pull` では、`post-merge` フックが notes も更新します。
`git fetch` 単体でも追従させたい場合は、次の関数を個人用のシェル設定へ追加します。

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
