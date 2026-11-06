#!/usr/bin/env bash
# setup-test: Claude settings
# Isolated checks that setup merges only its own keys into ~/.claude/settings.json.
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/setup-claude-test.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT INT TERM

source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/assert.sh"

run_sync() {
  HOME="$1" /bin/bash -c '
    source "$1/setup/repair.sh"
    DRY_RUN="$2"
    SETUP_REPAIR_COMPACT=false
    FAILED_TASKS=()
    sync_claude_settings
  ' _ "$REPO_DIR" "$2"
}

value() {
  jq -r "$2" "$1"
}

# A new machine gets the managed settings, private to the user.
home="$TMP_ROOT/new"
mkdir -p "$home"
run_sync "$home" false >/dev/null
assert_equals "$(value "$home/.claude/settings.json" .outputStyle)" "Proactive" "managed setting on a new machine"
assert_equals "$(stat -f %Lp "$home/.claude/settings.json" 2>/dev/null || stat -c %a "$home/.claude/settings.json")" "600" "settings mode"
[[ ! -e "$home/.dotfiles-backup/claude" ]] || fail_test "backed up a file that was not there"

# Keys setup does not own survive, a changed key is reset, and the old file is kept.
home="$TMP_ROOT/existing"
mkdir -p "$home/.claude"
printf '%s\n' '{"statusLine":{"type":"command","command":"app"},"outputStyle":"default","enabledPlugins":{"other@market":true}}' >"$home/.claude/settings.json"
run_sync "$home" false >/dev/null
assert_equals "$(value "$home/.claude/settings.json" .statusLine.command)" "app" "app-owned key kept"
assert_equals "$(value "$home/.claude/settings.json" .outputStyle)" "Proactive" "managed key reset"
assert_equals "$(value "$home/.claude/settings.json" '.enabledPlugins["other@market"]')" "true" "other plugin kept"
assert_equals "$(value "$home/.claude/settings.json" '.enabledPlugins["swift-lsp@claude-plugins-official"]')" "true" "managed plugin added"
assert_equals "$(find "$home/.dotfiles-backup/claude" -type f | wc -l | tr -d " ")" "1" "one backup"

# A second run changes nothing and makes no backup.
run_sync "$home" false >/dev/null
assert_equals "$(find "$home/.dotfiles-backup/claude" -type f | wc -l | tr -d " ")" "1" "no backup when nothing changes"

# A dry run writes nothing.
home="$TMP_ROOT/dry"
mkdir -p "$home/.claude"
printf '%s\n' '{"theme":"light"}' >"$home/.claude/settings.json"
run_sync "$home" true >/dev/null
assert_equals "$(value "$home/.claude/settings.json" .theme)" "light" "dry run left the file"

# Broken settings are left for a person, and the candidate is cleaned up.
home="$TMP_ROOT/broken"
mkdir -p "$home/.claude"
printf '%s\n' '{not json' >"$home/.claude/settings.json"
if run_sync "$home" false >/dev/null 2>&1; then
  fail_test "merged into broken settings"
fi
assert_equals "$(cat "$home/.claude/settings.json")" "{not json" "broken file left alone"
assert_equals "$(find "$home/.claude" -name ".settings.json.setup.*" | wc -l | tr -d " ")" "0" "candidate cleaned up"

# The check names what differs and accepts extra keys.
source "$REPO_DIR/setup/claude_config_helpers.sh"
source_file="$REPO_DIR/dotfiles/.claude/settings.managed.json"
mismatch="$(setup_claude_list_discrepancies "$TMP_ROOT/dry/.claude/settings.json" "$source_file")"
assert_contains "$mismatch" "Claude setting mismatch: theme" "mismatch named"
assert_equals "$(setup_claude_list_discrepancies "$TMP_ROOT/existing/.claude/settings.json" "$source_file")" "" "extra keys accepted"
