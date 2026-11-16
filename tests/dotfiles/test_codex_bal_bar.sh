#!/usr/bin/env bash
# setup-test: Codex Balance menu bar app
# Offline checks for the codex-bal-bar command, the app source, the installer
# with its build and launchd steps stubbed, and the Claude status line restore.
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
STATUSLINE="$REPO_DIR/apps/codex-bal-bar/claude-statusline.py"
COMMAND="$REPO_DIR/dotfiles/.bin/codex-bal-bar"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codex-bal-bar-test.XXXXXX")"

cleanup() {
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/assert.sh"

status_line() {
  python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])).get("statusLine"), sort_keys=True))' "$1"
}

help_output="$("$COMMAND" --help)" || fail_test "--help failed"
remaining="$help_output"
for section in "Usage:" "Description:" "Options:" "Examples:" "Environment:"; do
  [[ "$remaining" == *"$section"* ]] || fail_test "help is missing or misorders $section"
  remaining="${remaining#*"$section"}"
done

status=0
error_output="$("$COMMAND" --unknown 2>&1)" || status=$?
[[ "$status" == 2 && "$error_output" == *"unknown option"* ]] || fail_test "--unknown returned $status: $error_output"

is_macos=false
[[ "$(uname -s)" == Darwin ]] && is_macos=true

# The app and its install command are macOS only; Linux Swift cannot typecheck
# AppKit code, and codex-bal-bar refuses to run off macOS.
if "$is_macos" && command -v swiftc >/dev/null 2>&1; then
  awk '/^@main$/ { exit } { print }' "$REPO_DIR/apps/codex-bal-bar/CodexBalBar.swift" >"$TMP_ROOT/App.swift"
  swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
    "$TMP_ROOT/App.swift" "$REPO_DIR/tests/dotfiles/fixtures/codex_balance.swift" -o "$TMP_ROOT/check-codex-bal-bar" || fail_test "Codex Balance app does not compile"
  "$TMP_ROOT/check-codex-bal-bar" "$TMP_ROOT" || fail_test "Codex Balance behavior checks"
fi

python3 -c 'import ast,pathlib,sys; ast.parse(pathlib.Path(sys.argv[1]).read_text())' "$STATUSLINE" ||
  fail_test "Claude status line restore has a syntax error"

# Older versions wrapped Claude Code's status line. Restoring puts back the one
# they replaced and keeps other settings, but leaves a status line someone
# changed since alone, and does nothing where nothing was wrapped.
original='{"command": "cat", "padding": 2, "type": "command"}'
wrapper="python3 '/old/Codex Balance.app/Contents/Resources/claude-statusline.py'"
wrap_status_line() {
  local directory="$1"
  mkdir -p "$directory"
  python3 -c 'import json,sys; json.dump({"statusLine": {"type": "command", "command": sys.argv[2]}, "theme": "dark"}, open(sys.argv[1], "w"))' \
    "$directory/settings.json" "$wrapper"
  python3 -c 'import json,sys; json.dump({"wrapper": sys.argv[2], "original": {"type": "command", "command": "cat", "padding": 2}}, open(sys.argv[1], "w"))' \
    "$directory/.codex-bal-bar-statusline.json" "$wrapper"
}
settings="$TMP_ROOT/claude/settings.json"
wrap_status_line "$TMP_ROOT/claude"
CODEX_BAL_BAR_CLAUDE_SETTINGS="$settings" python3 "$STATUSLINE" >/dev/null || fail_test "status line restore failed"
assert_equals "$(status_line "$settings")" "$original"
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["theme"] == "dark"' "$settings" ||
  fail_test "status line restore lost other Claude settings"
[[ ! -e "$TMP_ROOT/claude/.codex-bal-bar-statusline.json" ]] || fail_test "status line restore kept its backup"
CODEX_BAL_BAR_CLAUDE_SETTINGS="$settings" python3 "$STATUSLINE" >/dev/null || fail_test "restore without a backup failed"
assert_equals "$(status_line "$settings")" "$original"
wrap_status_line "$TMP_ROOT/claude"
printf '%s\n' '{"statusLine":{"type":"command","command":"mine"}}' >"$settings"
CODEX_BAL_BAR_CLAUDE_SETTINGS="$settings" python3 "$STATUSLINE" >/dev/null || fail_test "restore of a changed status line failed"
assert_equals "$(status_line "$settings")" '{"command": "mine", "type": "command"}'

if "$is_macos"; then
  # The installer, with the Swift build, signing, and launchd stubbed so the
  # real login agent and app are never touched: it records the credit price,
  # keeps it on later installs until it is set empty, shows it in --status,
  # rejects a non-number, and puts back a status line older versions wrapped.
  home="$TMP_ROOT/home"
  stubs="$TMP_ROOT/stubs"
  mkdir -p "$stubs" "$home/Library/Application Support/Codex Balance"
  printf '%s\n' '#!/bin/sh' 'while [ "$#" -gt 0 ]; do' '  if [ "$1" = -o ]; then : >"$2"; chmod +x "$2"; fi' '  shift' 'done' >"$stubs/swiftc"
  printf '%s\n' '#!/bin/sh' 'exit 0' >"$stubs/codesign"
  printf '%s\n' '#!/bin/sh' '[ "$1" = print ] && exit 1' 'exit 0' >"$stubs/launchctl"
  printf '%s\n' '#!/bin/sh' 'exit 0' >"$stubs/codex"
  chmod +x "$stubs"/*
  [[ "$(PATH="$stubs:$PATH" command -v launchctl)" == "$stubs/launchctl" ]] || fail_test "launchctl stub is not first on PATH"
  wrap_status_line "$home/.claude"
  printf '{}\n' >"$home/Library/Application Support/Codex Balance/claude-rate-limits.json"
  installer() {
    env -u CODEX_BAL_BAR_CREDIT_USD -u CODEX_BAL_BAR_CLAUDE_SETTINGS HOME="$home" PATH="$stubs:$PATH" \
      CODEX_BIN="$stubs/codex" CODEX_BAL_BAR_APP_DIR="$home/Applications" "$@"
  }
  plist="$home/Library/LaunchAgents/local.codex-bal-bar.plist"
  app="$home/Applications/Codex Balance.app"
  credit_price() {
    plutil -extract EnvironmentVariables.CODEX_BAL_BAR_CREDIT_USD raw "$plist" 2>/dev/null || true
  }

  installer CODEX_BAL_BAR_CREDIT_USD=0.5 "$COMMAND" --install >/dev/null || fail_test "install with a credit price failed"
  [[ -x "$app/Contents/MacOS/CodexBalBar" ]] || fail_test "install did not place the app"
  assert_equals "$(credit_price)" "0.5"
  assert_equals "$(status_line "$home/.claude/settings.json")" "$original"
  [[ ! -e "$home/Library/Application Support/Codex Balance/claude-rate-limits.json" ]] ||
    fail_test "install kept the old status line capture file"
  [[ -z "$(ls -A "$app/Contents/Resources")" ]] || fail_test "the app still ships status line hook files"

  installer "$COMMAND" --install >/dev/null || fail_test "reinstall failed"
  assert_equals "$(credit_price)" "0.5"
  assert_contains "$(installer "$COMMAND" --status)" 'Credit price: $0.5 per Codex credit'
  installer CODEX_BAL_BAR_CREDIT_USD= "$COMMAND" --install >/dev/null || fail_test "install with an empty credit price failed"
  assert_equals "$(credit_price)" ""
  assert_contains "$(installer "$COMMAND" --status)" 'Credit price: not set'
  status=0
  installer CODEX_BAL_BAR_CREDIT_USD=abc "$COMMAND" --install >/dev/null 2>&1 || status=$?
  assert_equals "$status" "2"

  installer "$COMMAND" --uninstall >/dev/null || fail_test "uninstall failed"
  [[ ! -e "$plist" && ! -e "$app" && ! -e "$home/Library/Application Support/Codex Balance" ]] ||
    fail_test "uninstall left the login agent, app, or saved data behind"
fi

printf '[PASS] Codex Balance app checks\n'
