#!/usr/bin/env bash
# setup-test: Git hooks
# Checks the tracked pre-commit, commit-msg, and pre-push hooks in scratch repositories,
# including fail-closed scans and complete staged catalogs, with a fake scanner.
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/setup-hooks-test.XXXXXX")"
# Git exports GIT_DIR to hooks in linked worktrees; never let it point these fixtures at a real repository.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX

cleanup_test() {
  rm -rf -- "$TMP_ROOT"
}
trap cleanup_test EXIT INT TERM

source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/assert.sh"

for hook in pre-commit commit-msg pre-push; do
  [[ -x "$REPO_DIR/.githooks/$hook" ]] || fail_test "$hook is not executable, so Git would skip it"
done

scratch="$TMP_ROOT/repo"
remote="$TMP_ROOT/remote.git"
fake_bin="$TMP_ROOT/bin"
mkdir -p "$scratch" "$fake_bin"
git init -q --bare "$remote"
git -C "$scratch" init -q -b main
git -C "$scratch" config user.email test@example.com
git -C "$scratch" config user.name test
git -C "$scratch" config commit.gpgsign false
git -C "$scratch" config core.hooksPath "$REPO_DIR/.githooks"
git -C "$scratch" remote add origin "$remote"

# Reach git through a wrapper so no other command from git's directory (such
# as a real Homebrew gitleaks) leaks onto the test PATH. With /usr/bin:/bin the
# hooks run check_pr.sh under /bin/bash, which is Bash 3.2 on macOS, as when a
# GUI app starts git.
git_bin="$TMP_ROOT/git-bin"
mkdir -p "$git_bin"
printf '#!/bin/sh\nexec %s "$@"\n' "$(command -v git)" >"$git_bin/git"
chmod +x "$git_bin/git"
base_path="$git_bin:/usr/bin:/bin"

# A failing scanner blocks the commit and receives the staged-scan arguments.
printf '%s\n' '#!/bin/sh
printf '\''%s\n'\'' "$*" >>"$TEST_SCANNER_ARGS_LOG"
while [ "$#" -gt 0 ]; do
  if [ "$1" = --report-path ]; then
    shift
    printf '\''[]\n'\'' >"$1"
  fi
  shift
done
exit "${TEST_SCANNER_STATUS:-0}"' >"$fake_bin/gitleaks"
chmod +x "$fake_bin/gitleaks"
printf 'one\n' >"$scratch/file"
git -C "$scratch" add file
if TEST_SCANNER_STATUS=1 TEST_SCANNER_ARGS_LOG="$TMP_ROOT/args" PATH="$fake_bin:$base_path" \
  git -C "$scratch" commit -qm 'test: blocked by the scan' 2>/dev/null; then
  fail_test "a failing secret scan did not block the commit"
fi
[[ "$(<"$TMP_ROOT/args")" == *"git --pre-commit --staged"* ]] ||
  fail_test "hook did not scan staged changes: $(<"$TMP_ROOT/args")"

# A clean scan allows the commit.
TEST_SCANNER_STATUS=0 TEST_SCANNER_ARGS_LOG="$TMP_ROOT/args" PATH="$fake_bin:$base_path" \
  git -C "$scratch" commit -qm 'test: clean scan' || fail_test "a clean secret scan blocked the commit"

# Without gitleaks, the hook blocks the commit.
printf 'two\n' >"$scratch/file"
git -C "$scratch" add file
if missing_output="$(PATH="$base_path" git -C "$scratch" commit -qm 'test: unscanned' 2>&1)"; then
  fail_test "missing gitleaks allowed an unscanned commit"
fi
[[ "$missing_output" == *"gitleaks is not installed"* ]] ||
  fail_test "missing gitleaks produced no warning"

# Parse complete staged catalogs, even when the working tree is now clean.
mkdir -p "$scratch/dotfiles/toolbox"
printf 'invalid catalog\n' >"$scratch/dotfiles/toolbox/personal.jsonl"
git -C "$scratch" add dotfiles/toolbox/personal.jsonl
printf '{"command":"git status"}\n' >"$scratch/dotfiles/toolbox/personal.jsonl"
if TEST_SCANNER_STATUS=0 TEST_SCANNER_ARGS_LOG="$TMP_ROOT/args" PATH="$fake_bin:$base_path" \
  git -C "$scratch" commit -qm 'test: invalid catalog' 2>/dev/null; then
  fail_test "invalid staged catalog was hidden by a valid working copy"
fi
git -C "$scratch" add dotfiles/toolbox/personal.jsonl
printf 'invalid working copy\n' >"$scratch/dotfiles/toolbox/personal.jsonl"
TEST_SCANNER_STATUS=0 TEST_SCANNER_ARGS_LOG="$TMP_ROOT/args" PATH="$fake_bin:$base_path" \
  git -C "$scratch" commit -qm 'test: valid catalog' || fail_test "valid index catalog was replaced by working-copy content"
[[ "$(<"$TMP_ROOT/args")" == *"dir "* ]] || fail_test "full decoded catalog scan did not run"
[[ "$(<"$TMP_ROOT/args")" == *"--ignore-gitleaks-allow"* ]] || fail_test "inline suppression was not disabled"

export TEST_SCANNER_ARGS_LOG="$TMP_ROOT/args"

# Before anything is fetched, pre-push can't tell new commits from old ones, so it skips with a note.
output="$(PATH="$base_path" git -C "$scratch" push -q -u origin main 2>&1)" ||
  fail_test "pre-push blocked a push with no remote-tracking branches: $output"
assert_contains "$output" 'run git fetch first'

# commit-msg: "type: summary" first lines pass; anything else is refused.
commit() { PATH="$fake_bin:$base_path" git -C "$scratch" commit -q --allow-empty "$@" 2>&1; }
output="$(commit -m 'Add a thing')" && fail_test "commit-msg accepted \"Add a thing\""
assert_contains "$output" 'should look like "type: summary"'
output="$(commit -m 'fix: wip')" && fail_test "commit-msg accepted a placeholder summary"
assert_contains "$output" 'is a placeholder'
commit -m 'fix: keep SSH sockets short' -m 'Body lines are not checked, however long they are, which suits agent-written paragraphs.' >/dev/null ||
  fail_test "commit-msg refused a valid message"
commit -m "fix: $(printf 'x%.0s' {1..70})" >/dev/null && fail_test "commit-msg accepted a 75-character subject"
# git log %s joins the first paragraph, so a missing blank line counts toward the limit too.
commit -m "fix: short subject"$'\n'"$(printf 'x%.0s' {1..60})" >/dev/null &&
  fail_test "commit-msg accepted a subject that runs on into a second line"
# Characters, not bytes: 72 characters with arrows pass even without a locale.
env -u LANG -u LC_ALL -u LC_CTYPE PATH="$fake_bin:$base_path" git -C "$scratch" commit -q --allow-empty \
  -m "fix: $(printf '→%.0s' {1..67})" >/dev/null 2>&1 || fail_test "commit-msg counted bytes instead of characters"
# fixup!/squash!/amend! commits are allowed locally so --autosquash works; pre-push stops them.
commit --fixup HEAD >/dev/null || fail_test "commit-msg refused a fixup! commit"

# Merge commits keep git's own message.
git -C "$scratch" branch side HEAD~1
git -C "$scratch" checkout -q side
printf 'side\n' >"$scratch/side"
git -C "$scratch" add side
commit -m 'test: side change' >/dev/null || fail_test "commit-msg refused a valid side commit"
git -C "$scratch" checkout -q main
PATH="$fake_bin:$base_path" git -C "$scratch" merge -q --no-ff --no-edit side >/dev/null 2>&1 ||
  fail_test "commit-msg refused git's merge message"

# A linked worktree gets GIT_DIR from git; the hook still finds MERGE_HEAD and checks messages.
git -C "$scratch" worktree add -q "$TMP_ROOT/linked" -b linked HEAD~1 2>/dev/null
output="$(PATH="$fake_bin:$base_path" git -C "$TMP_ROOT/linked" commit -q --allow-empty -m 'bad subject' 2>&1)" &&
  fail_test "commit-msg accepted a bad subject in a linked worktree"
PATH="$fake_bin:$base_path" git -C "$TMP_ROOT/linked" merge -q --no-ff --no-edit side >/dev/null 2>&1 ||
  fail_test "commit-msg refused a merge in a linked worktree"

# pre-push: only commits that are not on a remote-tracking branch are checked.
push() { PATH="$fake_bin:$base_path" git -C "$scratch" push -q "$@" 2>&1; }
output="$(push origin main)" && fail_test "pre-push accepted a fixup! commit"
assert_contains "$output" 'work-in-progress or fixup commit'
# Fold the fixup away, keeping the merge.
git -C "$scratch" -c core.hooksPath=/dev/null reset -q --hard HEAD^1
git -C "$scratch" -c core.hooksPath=/dev/null reset -q --hard HEAD~1
PATH="$fake_bin:$base_path" git -C "$scratch" merge -q --no-ff --no-edit side >/dev/null 2>&1
push origin main >/dev/null || fail_test "pre-push refused valid commits"
# revert never runs commit-msg, so git's "Revert ..." subject is caught on the way out.
git -C "$scratch" revert --no-edit HEAD^2 >/dev/null 2>&1 || fail_test "could not revert in the fixture"
output="$(push origin main)" && fail_test "pre-push accepted git's default revert subject"
assert_contains "$output" 'as "revert: test: side change"'
git -C "$scratch" -c core.hooksPath=/dev/null commit -q --amend -m 'revert: test: side change'
push origin main >/dev/null || fail_test "pre-push refused a reworded revert"
git -C "$scratch" -c core.hooksPath=/dev/null commit -q --allow-empty -m 'wip'
output="$(push origin main)" && fail_test "pre-push accepted a wip commit"
assert_contains "$output" '"wip"'
push --no-verify origin main >/dev/null || fail_test "push --no-verify was blocked"
# Commits a remote-tracking branch already has are not checked again.
commit -m 'fix: on top of a pushed wip' >/dev/null
push origin main >/dev/null || fail_test "pre-push re-checked commits the remote already has"
# Nothing new to push still runs the hook, with empty stdin.
push origin main >/dev/null || fail_test "an up-to-date push failed"
# A push by URL moves no remote-tracking branch, so the remote's old tip marks what it has.
git -C "$scratch" -c core.hooksPath=/dev/null commit -q --allow-empty -m 'wip'
push --no-verify "$remote" HEAD:refs/heads/byurl >/dev/null || fail_test "could not push by URL"
commit -m 'fix: on top of a wip pushed by URL' >/dev/null
push "$remote" HEAD:refs/heads/byurl >/dev/null || fail_test "pre-push re-checked the remote's old tip"
git -C "$scratch" -c core.hooksPath=/dev/null reset -q --hard origin/main
# Tags and deletions aren't checked.
git -C "$scratch" -c core.hooksPath=/dev/null commit -q --allow-empty -m 'wip'
git -C "$scratch" tag v1
push origin v1 >/dev/null || fail_test "pre-push refused a tag"
git -C "$scratch" -c core.hooksPath=/dev/null reset -q --hard origin/main
push origin side >/dev/null || fail_test "pre-push refused a valid branch"
push origin --delete side >/dev/null || fail_test "pre-push refused a branch deletion"

# The untracked .local/denylist keeps private terms out of commits and pushes;
# .local/denylist.allow accepts lines that also match it.
[[ -x "$REPO_DIR/.githooks/check-denylist" ]] || fail_test "check-denylist is not executable"
mkdir -p "$scratch/.local"
printf '%s\n' '.local/' >"$scratch/.git/info/exclude"
printf '%s\n' '# private terms' '' 'Zorblax' >"$scratch/.local/denylist"
printf 'about zorblax\n' >"$scratch/private"
git -C "$scratch" add private
output="$(commit -m 'docs: mention a private term')" && fail_test "pre-commit accepted a denylisted term"
assert_contains "$output" 'private: about zorblax'
# Binary content is still checked.
printf 'bin\0zorblax\n' >"$scratch/blob"
git -C "$scratch" add blob
output="$(commit -m 'docs: add a binary with a private term')" && fail_test "pre-commit accepted a denylisted term in binary content"
assert_contains "$output" 'blob: '
git -C "$scratch" rm -q --cached blob
rm "$scratch/blob"
printf '%s\n' 'about zorblax' >"$scratch/.local/denylist.allow"
commit -m 'docs: mention an allowed term' >/dev/null || fail_test "pre-commit refused an allowed line"
output="$(cd "$scratch" && PATH="$base_path" "$REPO_DIR/.githooks/check-denylist" --tree 2>&1)" ||
  fail_test "check-denylist --tree refused an allowed line: $output"
rm "$scratch/.local/denylist.allow"
output="$(cd "$scratch" && PATH="$base_path" "$REPO_DIR/.githooks/check-denylist" --tree 2>&1)" &&
  fail_test "check-denylist --tree missed a tracked term"
assert_contains "$output" 'private:1:about zorblax'
output="$(push origin main)" && fail_test "pre-push accepted a commit adding a denylisted term"
assert_contains "$output" 'private: about zorblax'
rm "$scratch/.local/denylist"
push origin main >/dev/null || fail_test "pre-push refused a push with no denylist"

printf '[PASS] Git hook checks\n'
