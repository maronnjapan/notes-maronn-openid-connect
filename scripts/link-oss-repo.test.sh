#!/usr/bin/env bash
set -euo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINK_SCRIPT="${SCRIPT_ROOT}/link-oss-repo.sh"
PULL_SCRIPT="${SCRIPT_ROOT}/pull.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

assert_link() {
  local path="$1" expected="$2"
  [ -L "${path}" ] || fail "${path} should be a symbolic link"
  [ "$(readlink "${path}")" = "${expected}" ] || fail "${path} should point to ${expected}"
}

[ -x "${LINK_SCRIPT}" ] || fail 'link-oss-repo.sh should be executable'
[ -x "${PULL_SCRIPT}" ] || fail 'pull.sh should be executable'

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

NOTES_REMOTE="${TEST_ROOT}/notes.git"
OSS_REMOTE="${TEST_ROOT}/maronn-openid-connect.git"
NOTES_ROOT="${TEST_ROOT}/notes"
OSS_ROOT="${TEST_ROOT}/oss"

git init --bare --quiet "${NOTES_REMOTE}"
git clone --quiet "${NOTES_REMOTE}" "${NOTES_ROOT}"
git -C "${NOTES_ROOT}" config user.name test
git -C "${NOTES_ROOT}" config user.email test@example.com
mkdir -p "${NOTES_ROOT}/scripts" \
  "${NOTES_ROOT}/tasks" \
  "${NOTES_ROOT}/study-material" \
  "${NOTES_ROOT}/review" \
  "${NOTES_ROOT}/claude" \
  "${NOTES_ROOT}/agents" \
  "${NOTES_ROOT}/serena" \
  "${NOTES_ROOT}/implementation-guides"
cp "${LINK_SCRIPT}" "${NOTES_ROOT}/scripts/link-oss-repo.sh"
cp "${PULL_SCRIPT}" "${NOTES_ROOT}/scripts/pull.sh"
chmod +x "${NOTES_ROOT}/scripts/link-oss-repo.sh" "${NOTES_ROOT}/scripts/pull.sh"
printf 'notes instructions\n' > "${NOTES_ROOT}/CLAUDE.md"
printf '{}\n' > "${NOTES_ROOT}/mcp.json"
printf 'task\n' > "${NOTES_ROOT}/tasks/example.md"
printf 'study\n' > "${NOTES_ROOT}/study-material/example.md"
printf 'review\n' > "${NOTES_ROOT}/review/example.md"
printf 'skill\n' > "${NOTES_ROOT}/claude/example.md"
printf 'agent\n' > "${NOTES_ROOT}/agents/example.md"
printf 'serena\n' > "${NOTES_ROOT}/serena/example.md"
printf 'guide\n' > "${NOTES_ROOT}/implementation-guides/example.md"
git -C "${NOTES_ROOT}" add .
git -C "${NOTES_ROOT}" commit --quiet -m 'initial notes'
git -C "${NOTES_ROOT}" push --quiet -u origin HEAD:main
git --git-dir="${NOTES_REMOTE}" symbolic-ref HEAD refs/heads/main

git init --bare --quiet "${OSS_REMOTE}"
git clone --quiet "${OSS_REMOTE}" "${OSS_ROOT}"
git -C "${OSS_ROOT}" config user.name test
git -C "${OSS_ROOT}" config user.email test@example.com
mkdir -p "${OSS_ROOT}/packages/core" "${OSS_ROOT}/docs"
printf '%s\n' \
  '/.notes' \
  '/CLAUDE.md' \
  '/AGENTS.md' \
  '/GEMINI.md' \
  '/tasks' \
  '/study-material' \
  '/.review' \
  '/.claude' \
  '/.agents' \
  '/.serena' \
  '/.mcp.json' \
  '/docs/implementation-guides' > "${OSS_ROOT}/.gitignore"
printf 'oss\n' > "${OSS_ROOT}/packages/core/example.txt"
git -C "${OSS_ROOT}" add .
git -C "${OSS_ROOT}" commit --quiet -m 'initial oss'
git -C "${OSS_ROOT}" push --quiet -u origin HEAD:main
git --git-dir="${OSS_REMOTE}" symbolic-ref HEAD refs/heads/main

bash "${NOTES_ROOT}/scripts/link-oss-repo.sh" "${OSS_ROOT}" >/dev/null

assert_link "${OSS_ROOT}/.notes" "${NOTES_ROOT}"
assert_link "${OSS_ROOT}/CLAUDE.md" '.notes/CLAUDE.md'
assert_link "${OSS_ROOT}/AGENTS.md" 'CLAUDE.md'
assert_link "${OSS_ROOT}/GEMINI.md" 'CLAUDE.md'
assert_link "${OSS_ROOT}/tasks" '.notes/tasks'
assert_link "${OSS_ROOT}/study-material" '.notes/study-material'
assert_link "${OSS_ROOT}/.review" '.notes/review'
assert_link "${OSS_ROOT}/.claude" '.notes/claude'
assert_link "${OSS_ROOT}/.agents" '.notes/agents'
assert_link "${OSS_ROOT}/.serena" '.notes/serena'
assert_link "${OSS_ROOT}/.mcp.json" '.notes/mcp.json'
assert_link "${OSS_ROOT}/docs/implementation-guides" '../.notes/implementation-guides'
[ "$(cat "${OSS_ROOT}/CLAUDE.md")" = 'notes instructions' ] || fail 'CLAUDE.md should be readable through the symbolic link'
[ -z "$(git -C "${OSS_ROOT}" status --porcelain)" ] || fail 'symbolic links should not dirty the OSS worktree'
pass 'should create twelve readable ignored symbolic links'

bash "${NOTES_ROOT}/scripts/link-oss-repo.sh" "${OSS_ROOT}" >/dev/null
[ -z "$(git -C "${OSS_ROOT}" status --porcelain)" ] || fail 'rerunning should keep the OSS worktree clean'
pass 'should allow the link script to be rerun'

rm "${OSS_ROOT}/tasks"
mkdir "${OSS_ROOT}/tasks"
if bash "${NOTES_ROOT}/scripts/link-oss-repo.sh" "${OSS_ROOT}" >"${TEST_ROOT}/blocked.out" 2>&1; then
  fail 'the link script should reject a real destination directory'
fi
grep -q '実体として残っています' "${TEST_ROOT}/blocked.out" || fail 'the real-directory guard should explain the failure'
rmdir "${OSS_ROOT}/tasks"
pass 'should reject a real destination directory'

WRONG_ROOT="${TEST_ROOT}/wrong-origin"
git clone --quiet "${OSS_REMOTE}" "${WRONG_ROOT}"
git -C "${WRONG_ROOT}" remote set-url origin "${TEST_ROOT}/different.git"
if bash "${NOTES_ROOT}/scripts/link-oss-repo.sh" "${WRONG_ROOT}" >"${TEST_ROOT}/origin.out" 2>&1; then
  fail 'the link script should reject a different origin'
fi
grep -q 'origin が maronn-openid-connect ではありません' "${TEST_ROOT}/origin.out" || fail 'the origin guard should explain the failure'
pass 'should reject an unrelated OSS repository'

CUSTOM_ROOT="${TEST_ROOT}/custom-hook"
git clone --quiet "${OSS_REMOTE}" "${CUSTOM_ROOT}"
mkdir -p "${CUSTOM_ROOT}/.git/hooks"
printf '#!/usr/bin/env sh\nprintf custom-hook\\n\n' > "${CUSTOM_ROOT}/.git/hooks/post-merge"
chmod +x "${CUSTOM_ROOT}/.git/hooks/post-merge"
bash "${NOTES_ROOT}/scripts/link-oss-repo.sh" "${CUSTOM_ROOT}" >"${TEST_ROOT}/hook.out"
grep -q '既存の post-merge フックがあるため上書きしません' "${TEST_ROOT}/hook.out" || fail 'the existing-hook guard should report the skipped write'
grep -q 'custom-hook' "${CUSTOM_ROOT}/.git/hooks/post-merge" || fail 'the existing hook should remain unchanged'
if grep -q 'maronn-notes-sync' "${CUSTOM_ROOT}/.git/hooks/post-merge"; then
  fail 'the existing hook should not be overwritten'
fi
pass 'should preserve an existing post-merge hook'

NOTES_WRITER="${TEST_ROOT}/notes-writer"
git clone --quiet "${NOTES_REMOTE}" "${NOTES_WRITER}"
git -C "${NOTES_WRITER}" config user.name test
git -C "${NOTES_WRITER}" config user.email test@example.com
printf 'updated notes\n' > "${NOTES_WRITER}/CLAUDE.md"
git -C "${NOTES_WRITER}" add CLAUDE.md
git -C "${NOTES_WRITER}" commit --quiet -m 'update notes'
git -C "${NOTES_WRITER}" push --quiet origin HEAD:main
EXPECTED_NOTES_HEAD="$(git -C "${NOTES_WRITER}" rev-parse HEAD)"

OSS_WRITER="${TEST_ROOT}/oss-writer"
git clone --quiet "${OSS_REMOTE}" "${OSS_WRITER}"
git -C "${OSS_WRITER}" config user.name test
git -C "${OSS_WRITER}" config user.email test@example.com
printf 'updated oss\n' >> "${OSS_WRITER}/packages/core/example.txt"
git -C "${OSS_WRITER}" add packages/core/example.txt
git -C "${OSS_WRITER}" commit --quiet -m 'update oss'
git -C "${OSS_WRITER}" push --quiet origin HEAD:main

git -C "${OSS_ROOT}/packages/core" pull --ff-only --quiet
[ "$(git -C "${NOTES_ROOT}" rev-parse HEAD)" = "${EXPECTED_NOTES_HEAD}" ] || fail 'post-merge should fast-forward notes after a pull from a subdirectory'
[ "$(cat "${OSS_ROOT}/CLAUDE.md")" = 'updated notes' ] || fail 'the updated notes should remain readable through the link'
pass 'should update notes after git pull from an OSS subdirectory'
