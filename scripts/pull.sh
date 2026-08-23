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
