#!/usr/bin/env bash
# setup-test: Claude compact hook
# Isolated checks that compaction state is saved and restored, and that the
# hook does nothing where there is nothing to save.
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_DIR/dotfiles/.claude/compact-hook.py"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/compact-hook-test.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT INT TERM

source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/assert.sh"

hook() {
  local action="$1"
  local cwd="$2"
  local transcript="${3:-}"
  printf '{"session_id":"s1","cwd":"%s","transcript_path":"%s"}' "$cwd" "$transcript" |
    HOME="$TMP_ROOT/home" "$HOOK" "$action"
}

mkdir -p "$TMP_ROOT/home" "$TMP_ROOT/plain" "$TMP_ROOT/project/.swarm"

# A folder with nothing to save writes and prints nothing.
hook snapshot "$TMP_ROOT/plain"
assert_equals "$(hook restore "$TMP_ROOT/plain")" "" "nothing to restore"
[[ ! -e "$TMP_ROOT/home/.claude/compact-snapshots" ]] || fail_test "wrote a snapshot with nothing to save"

# The last task list, ledger counts, lock and PROGRESS.md come back once.
printf '%s\n' 'Where things stand' >"$TMP_ROOT/project/PROGRESS.md"
printf '%s\n' '{"issues":[{"status":"fixed"},{"status":"fixed"},{"status":"approved"}]}' >"$TMP_ROOT/project/.swarm/ledger.json"
: >"$TMP_ROOT/project/.swarm/lock"
printf '%s\n' '{"message":{"content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"status":"pending","content":"old task"}]}}]}}' \
  '{"message":{"content":[{"type":"tool_use","name":"mcp__turn__update_plan","input":{"items":[{"status":"in_progress","content":"new task"}]}}]}}' \
  '{"message":{"content":"plain text"}}' >"$TMP_ROOT/transcript.jsonl"
hook snapshot "$TMP_ROOT/project" "$TMP_ROOT/transcript.jsonl"
restored="$(hook restore "$TMP_ROOT/project")"
assert_contains "$restored" "Where things stand" "progress restored"
assert_contains "$restored" "- [in_progress] new task" "last task list restored"
assert_not_contains "$restored" "old task" "older task list left out"
assert_contains "$restored" "3 issues: fixed 2, approved 1" "ledger counts restored"
assert_contains "$restored" "Lock held" "lock restored"
assert_not_contains "$(hook restore "$TMP_ROOT/project")" "new task" "snapshot used once"

# Ignored notes stay in the main checkout, so a worktree session finds them there.
git -C "$TMP_ROOT/project" init -q
git -C "$TMP_ROOT/project" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m first
git -C "$TMP_ROOT/project" worktree add -q "$TMP_ROOT/worktree"
assert_contains "$(hook restore "$TMP_ROOT/worktree")" "Where things stand" "progress found from a worktree"

# Bad input never fails the hook.
printf 'not json' | HOME="$TMP_ROOT/home" "$HOOK" snapshot 2>/dev/null || fail_test "bad input failed the hook"
