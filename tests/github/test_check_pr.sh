#!/usr/bin/env bash
# Runs .github/scripts/check_pr.sh against sample PR titles, descriptions, commit messages, and commits.
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$REPO_DIR/.github/scripts/check_pr.sh"
TEMPLATE="$(cat "$REPO_DIR/.github/pull_request_template.md")"
FILLED=$'## What changed\nTests run faster.\n\n## Why\nCI was slow.\n\n## Checked\n- [x] `./test.sh` passes'
# Git exports GIT_DIR to hooks in linked worktrees; never let it point these fixtures at a real repository.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX

source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/assert.sh"

expect() {
  local want="$1" title="$2" body="$3" output rc=0
  output="$(PR_TITLE="$title" PR_BODY="$body" GITHUB_ACTIONS='' "$CHECK" 2>&1)" || rc=$?
  if [[ "$want" == pass && "$rc" -ne 0 ]]; then
    fail_test "expected \"$title\" to pass: $output"
  elif [[ "$want" == fail && "$rc" -ne 1 ]]; then
    fail_test "expected \"$title\" to fail (exit $rc): $output"
  fi
}

expect pass 'fix: keep SSH sockets short' "$FILLED"
expect pass 'docs(readme): explain --check' "$FILLED"
expect pass 'feat!: drop the old installer' "$FILLED"
expect pass 'ci: bump the actions group' "${FILLED//$'\n'/$'\r\n'}"
expect pass 'test: comments around text' "${TEMPLATE/'## Why'/$'Tests run faster.\n## Why\nCI was slow.'}"

expect fail 'Fix stuff' "$FILLED"
expect fail 'fix:no space' "$FILLED"
expect fail 'feature: wrong type' "$FILLED"
expect fail 'Fix: capital type' "$FILLED"
expect pass "fix: $(printf 'x%.0s' {1..67})" "$FILLED"
expect fail "fix: $(printf 'x%.0s' {1..70})" "$FILLED"
expect fail 'fix: empty body' ''
expect fail 'fix: untouched template' "$TEMPLATE"
expect fail 'fix: missing why' $'## What changed\nSomething.'
expect fail 'fix: only a comment' $'## What changed\n<!-- todo -->\n## Why\nReason.'

# Titles and commit subjects: characters, not bytes, count toward 72; no trailing period or
# placeholder summary; git's revert subject gets a hint.
expect pass "fix: $(printf 'é%.0s' {1..67})" "$FILLED"
expect fail 'fix: trailing period.' "$FILLED"
expect fail 'fix: wip' "$FILLED"
expect fail 'fix: WIP' "$FILLED"
expect fail 'fix: Address review comments' "$FILLED"
expect fail 'fix: trailing space ' "$FILLED"
output="$(PR_TITLE='fix(README): explain --check' PR_BODY="$FILLED" GITHUB_ACTIONS='' "$CHECK" 2>&1)" &&
  fail_test 'a capitalized scope passed'
assert_contains "$output" 'in lowercase'
output="$(PR_TITLE="Revert \"feat: $(printf 'x%.0s' {1..60})\"" PR_BODY="$FILLED" GITHUB_ACTIONS='' "$CHECK" 2>&1)" &&
  fail_test 'a long revert subject passed'
assert_contains "$output" 'in 72 characters or fewer'
# In CI, problems become annotations; a carriage return in a title must not start a command of its own.
output="$(PR_TITLE=$'Bad\r::warning::spoof 100%' PR_BODY="$FILLED" GITHUB_ACTIONS=true "$CHECK" 2>&1)" &&
  fail_test 'a bad title passed in CI mode'
assert_contains "$output" '%0D::warning::spoof 100%25'
[[ "$output" != *$'\r'* ]] || fail_test 'a carriage return reached the CI annotations'
expect fail 'Revert "fix: keep SSH sockets short"' "$FILLED"
expect fail "fix: $(printf 'é%.0s' {1..68})" "$FILLED"

# What GitHub shows is what counts: headings in any case or level, comments and code hidden or ignored.
expect pass 'fix: heading variants' $'## What Changed?\nTests run faster.\n\n### Why:\nCI was slow.'
HINTED="${TEMPLATE/'two. -->'/'two. --> Tests run faster.'}"
HINTED="${HINTED/'for it. -->'/'for it. --> CI was slow.'}"
expect pass 'fix: text after the hint' "$HINTED"
expect pass 'fix: Codex footer under Checked' "$FILLED"$'\n\n------\nhttps://chatgpt.com/codex/tasks/task_e_1'
expect pass 'fix: literal comment marker' $'## What changed\nStrip <!-- comments the way GitHub does.\n\n## Why\n<!-- reason -->\nThe check counted hidden text.'
expect pass 'fix: release-notes heading' $'## What\'s changed\nTests run faster.\n\n## Why\nCI was slow.'
expect pass 'fix: number-led word' $'## What changed\nCaches the hook result.\n\n## Why\n2x faster'
expect fail 'fix: only numbers' $'## What changed\nCaches the hook result.\n\n## Why\n2 3'
expect fail 'fix: placeholders' $'## What changed\nTODO\n\n## Why\nN/A'
expect fail 'fix: see title' $'## What changed\nSee title.\n\n## Why\nSame as title'
expect fail 'fix: one word' $'## What changed\nTests run faster.\n\n## Why\nSpeed.'
expect fail 'fix: Why repeats What' $'## What changed\nTests run faster.\n\n## Why\nTests run faster.'
expect fail 'fix: checklist as Why' $'## What changed\nTests run faster.\n\n## Why\n- [ ] `./test.sh` passes'
expect fail 'fix: footer as Why' $'## What changed\nTests run faster.\n\n## Why\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)'
expect fail 'fix: trailer as Why' $'## What changed\nTests run faster.\n\n## Why\nClaude-Session: https://claude.ai/code/session_01'
expect fail 'fix: link as Why' $'## What changed\nTests run faster.\n\n## Why\nhttps://github.com/ghostnet-labs/supernova/issues/12'
expect fail 'fix: heading in a fence' $'## What changed\nTests run faster.\n```\n## Why\nCI was slow.\n```'
expect fail 'fix: unclosed comment' $'## What changed\nTests run faster.\n\n## Why\n<!-- reason\nCI was slow.'
expect fail 'fix: hint left as text' $'## What changed\nWhat a reader will notice, in a sentence or two.\n\n## Why\nCI was slow.'
expect fail 'fix: Claude Code layout' $'## Summary\n- Tests run faster.\n\n## Test plan\n- [x] `./test.sh`'

# The type list lives in check_pr.sh; the PR template comment and AGENTS.md repeat it.
types="$(sed -n "s/^TYPES='\(.*\)'$/\1/p" "$CHECK")"
[[ -n "$types" ]] || fail_test 'could not read TYPES from check_pr.sh'
assert_contains "$TEMPLATE" "Types: ${types//|/, }."
assert_contains "$(cat "$REPO_DIR/AGENTS.md")" "type is one of \`${types//|/\`, \`}\`"

# Commit messages: build a throwaway repo and check base..HEAD.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
git_() { git -C "$TMP" -c user.name=test -c user.email=test@example.com -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }
git_ init -q -b main
git_ commit -q --allow-empty -m 'chore: start'
base="$(git_ rev-parse HEAD)"

expect_commits() {
  local want="$1" output rc=0
  shift
  git_ checkout -q -B pr "$base"
  for subject in "$@"; do
    git_ commit -q --allow-empty -m "$subject" -m 'Body text.'
  done
  output="$(cd "$TMP" && PR_TITLE='fix: x' PR_BODY="$FILLED" PR_BASE="$base" PR_HEAD=HEAD GITHUB_ACTIONS='' "$CHECK" 2>&1)" || rc=$?
  if [[ "$want" == pass && "$rc" -ne 0 ]]; then
    fail_test "expected commits \"$*\" to pass: $output"
  elif [[ "$want" == fail && "$rc" -ne 1 ]]; then
    fail_test "expected commits \"$*\" to fail (exit $rc): $output"
  fi
  # --commits, which the pre-push hook and CI on main run, agrees with the PR check.
  rc=0
  output="$(cd "$TMP" && GITHUB_ACTIONS='' "$CHECK" --commits "$base..HEAD" 2>&1)" || rc=$?
  if [[ "$want" == pass && "$rc" -ne 0 ]]; then
    fail_test "expected --commits \"$*\" to pass: $output"
  elif [[ "$want" == fail && "$rc" -ne 1 ]]; then
    fail_test "expected --commits \"$*\" to fail (exit $rc): $output"
  fi
}

expect_commits pass 'fix: keep SSH sockets short' 'docs(readme): explain --check'
expect_commits fail 'fix: keep SSH sockets short' 'fix: review comments'
expect_commits fail '   fix: leading spaces'
expect_commits fail 'fixup! fix: keep SSH sockets short'
expect_commits fail 'WIP'
expect_commits fail "feat: $(printf 'x%.0s' {1..70})"
expect_commits fail 'Revert "fix: keep SSH sockets short"'

# log.showSignature prints signature checks next to the subjects; they are not commits.
if command -v ssh-keygen >/dev/null 2>&1; then
  ssh-keygen -q -t ed25519 -N '' -f "$TMP/key" >/dev/null
  git_ checkout -q -B pr "$base"
  git_ -c gpg.format=ssh -c user.signingkey="$TMP/key" commit -q -S --allow-empty -m 'fix: signed commit'
  output="$(cd "$TMP" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=log.showSignature GIT_CONFIG_VALUE_0=true \
    GITHUB_ACTIONS='' "$CHECK" --commits "$base..HEAD" 2>&1)" || fail_test "signature lines were checked as commits: $output"
fi

# Merge commits are skipped.
git_ checkout -q -B side "$base"
git_ commit -q --allow-empty -m 'test: side change'
git_ checkout -q -B pr "$base"
git_ commit -q --allow-empty -m 'fix: main change'
git_ merge -q --no-ff -m "Merge branch 'side'" side
output="$(cd "$TMP" && PR_TITLE='fix: x' PR_BODY="$FILLED" PR_BASE="$base" PR_HEAD=HEAD GITHUB_ACTIONS='' "$CHECK" 2>&1)" ||
  fail_test "merge commits should be skipped: $output"

# --message reads a message file the way git records it, as the commit-msg hook passes it.
expect_message() {
  local want="$1" message="$2" output rc=0
  printf '%s' "$message" >"$TMP/message"
  output="$(cd "$TMP" && GITHUB_ACTIONS='' "$CHECK" --message "$TMP/message" 2>&1)" || rc=$?
  if [[ "$want" == pass && "$rc" -ne 0 ]]; then
    fail_test "expected message \"$message\" to pass: $output"
  elif [[ "$want" == fail && "$rc" -ne 1 ]]; then
    fail_test "expected message \"$message\" to fail (exit $rc): $output"
  fi
}

expect_message pass $'fix: keep SSH sockets short\n\nA body line can be as long as it needs to be, because only the subject is checked.'
# git commit -v: the subject, git's comments, the scissors line, then the diff.
expect_message pass $'fix: keep SSH sockets short\n# Please enter the commit message.\n# ------------------------ >8 ------------------------\n# Do not modify or remove the line above.\ndiff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new'
expect_message pass 'fixup! fix: keep SSH sockets short'
expect_message pass 'squash! fix: keep SSH sockets short'
expect_message fail 'Keep SSH sockets short'
# An empty message is left for git to abort, as when the editor quits without saving.
expect_message pass $'# Please enter the commit message.\n'
expect_message fail '   fix: leading spaces'
expect_message fail 'wip'
expect_message fail $'fix: a subject that git joins\nwith this second line because no blank line separates them'
git_ config core.commentChar ';'
expect_message pass $'; Please enter the commit message.\nfix: keep SSH sockets short'
expect_message fail $'; fix: only a comment\nBad subject'
git_ config --unset core.commentChar
git_ config core.commentString '//'
expect_message pass $'fix: keep SSH sockets short\n// Please enter the commit message.\n// Lines starting with // are ignored.'
git_ config --unset core.commentString
# During a merge, the message is not checked.
git_ rev-parse HEAD >"$TMP/.git/MERGE_HEAD"
expect_message pass 'Any text while a merge is in progress'
rm "$TMP/.git/MERGE_HEAD"
expect_message fail 'Any text while a merge is in progress'
# Amending a merge commit has no MERGE_HEAD, so git's merge subjects pass on their own.
expect_message pass "Merge branch 'side'"

# Capture, then match: piping into grep -q can SIGPIPE the writer, which pipefail reports as a failure.
help_output="$("$CHECK" --help)" || fail_test '--help exited non-zero'
[[ "$help_output" == Usage:* || "$help_output" == *$'\n'Usage:* ]] || fail_test '--help prints usage'
if "$CHECK" --bogus >/dev/null 2>&1; then fail_test 'unknown option should fail'; fi
if "$CHECK" --message >/dev/null 2>&1; then fail_test '--message without a file should fail'; fi
if "$CHECK" --commits >/dev/null 2>&1; then fail_test '--commits without revisions should fail'; fi

echo '[PASS] PR format check'
