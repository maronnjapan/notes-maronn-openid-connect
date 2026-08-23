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

# notes 側に存在するときだけ張る。段階移行の途中でも実行できる。
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
  printf '%s\n' \
    '#!/usr/bin/env sh' \
    '# maronn-notes-sync: notes リポジトリの link-oss-repo.sh が生成。git pull 後に notes を追従させる。' \
    '"$(git rev-parse --show-toplevel)/.notes/scripts/pull.sh" || true' > "${HOOK_PATH}"
  chmod +x "${HOOK_PATH}"
  ok "post-merge フックを設定しました。"
fi

if [ "${BLOCKED}" -gt 0 ]; then
  err "${BLOCKED} 件は実体が残っているためリンクできませんでした。"
  exit 1
fi
ok "リンクを張り終えました。"
