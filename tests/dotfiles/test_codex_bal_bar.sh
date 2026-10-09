#!/usr/bin/env bash
# setup-test: Codex Balance menu bar app
# Offline checks for the codex-bal-bar command, the app source, and the Claude
# status line capture.
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
CAPTURE="$REPO_DIR/apps/codex-bal-bar/claude-limits-capture"
STATUSLINE="$REPO_DIR/apps/codex-bal-bar/claude-statusline.py"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codex-bal-bar-test.XXXXXX")"
export CODEX_BAL_BAR_CLAUDE_FILE="$TMP_ROOT/support/claude-rate-limits.json"

cleanup() {
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/assert.sh"

saved() {
  jq -c "$1" "$CODEX_BAL_BAR_CLAUDE_FILE"
}

COMMAND="$REPO_DIR/dotfiles/.bin/codex-bal-bar"

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

bash -n "$CAPTURE" || fail_test "claude-limits-capture has a syntax error"
python3 -c 'import ast,pathlib,sys; ast.parse(pathlib.Path(sys.argv[1]).read_text())' "$STATUSLINE" ||
  fail_test "Claude status line helper has a syntax error"

# Installing the integration wraps an existing status line and uninstall
# restores it without disturbing other Claude settings.
mkdir -p "$TMP_ROOT/claude"
settings="$TMP_ROOT/claude/settings.json"
printf '%s\n' '{"statusLine":{"type":"command","command":"cat","padding":2},"theme":"dark"}' >"$settings"
wrapper="$TMP_ROOT/Applications/Codex Balance.app/Contents/Resources/claude-statusline.py"
wrapper="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve())' "$wrapper")"
CODEX_BAL_BAR_CLAUDE_SETTINGS="$settings" python3 "$STATUSLINE" --install "$wrapper" >/dev/null ||
  fail_test "Claude status line integration install failed"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["theme"] == "dark" and d["statusLine"]["padding"] == 2 and sys.argv[2] in d["statusLine"]["command"]' "$settings" "$wrapper" ||
  fail_test "Claude status line install did not preserve existing settings"
sample='{"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":23.4,"resets_at":1790900000}}}'
forwarded="$(printf '%s' "$sample" | CODEX_BAL_BAR_CLAUDE_SETTINGS="$settings" python3 "$STATUSLINE")" ||
  fail_test "Claude status line wrapper failed"
[[ "$forwarded" == "$sample" ]] || fail_test "Claude status line wrapper changed its output"
if command -v jq >/dev/null 2>&1; then
  for attempt in {1..20}; do
    [[ -f "$CODEX_BAL_BAR_CLAUDE_FILE" ]] &&
      [[ "$(jq -r '.rate_limits.five_hour.used_percentage // empty' "$CODEX_BAL_BAR_CLAUDE_FILE")" == 23.4 ]] && break
    sleep 0.05
  done
  [[ "$(jq -r '.rate_limits.five_hour.used_percentage // empty' "$CODEX_BAL_BAR_CLAUDE_FILE")" == 23.4 ]] ||
    fail_test "Claude status line wrapper did not capture rate limits"
fi
CODEX_BAL_BAR_CLAUDE_SETTINGS="$settings" python3 "$STATUSLINE" --uninstall >/dev/null ||
  fail_test "Claude status line integration uninstall failed"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["theme"] == "dark" and d["statusLine"] == {"type":"command","command":"cat","padding":2}' "$settings" ||
  fail_test "Claude status line uninstall did not restore the original setting"

if ! command -v jq >/dev/null 2>&1; then
  printf '[SKIP] jq not installed; capture checks need it\n'
  exit 0
fi

limits='{"five_hour":{"used_percentage":23.4,"resets_at":1790900000},"seven_day":{"used_percentage":41,"resets_at":1791300000}}'
rm -f -- "$CODEX_BAL_BAR_CLAUDE_FILE"

# A session without limits records only that the hook ran.
printf '%s' '{"model":{"display_name":"Opus"}}' | "$CAPTURE"
[[ "$(saved 'keys')" == '["hook_seen_at"]' ]] || fail_test "hook-only capture wrote $(saved .)"

# Reported limits are saved with their capture time.
printf '{"rate_limits":%s}' "$limits" | "$CAPTURE"
[[ "$(saved '.rate_limits')" == "$limits" ]] || fail_test "limits not saved: $(saved .)"
[[ "$(saved '.captured_at | type')" == '"number"' ]] || fail_test "captured_at missing"

# A new session reports no limits yet; the last reading must survive.
printf '%s' '{"rate_limits":null}' | "$CAPTURE"
[[ "$(saved '.rate_limits')" == "$limits" ]] || fail_test "null rate_limits erased saved limits"
printf '%s' 'not json' | "$CAPTURE"
[[ "$(saved '.rate_limits')" == "$limits" ]] || fail_test "invalid input erased saved limits"

# A corrupt saved file is replaced rather than blocking new readings.
printf 'corrupt' >"$CODEX_BAL_BAR_CLAUDE_FILE"
printf '%s' '{"rate_limits":{"five_hour":{"used_percentage":5,"resets_at":1790900000}}}' | "$CAPTURE"
[[ "$(saved '.rate_limits.five_hour.used_percentage')" == 5 ]] || fail_test "corrupt file was not replaced"

leftovers="$(find "$TMP_ROOT/support" -name '.claude-rate-limits.*')"
[[ -z "$leftovers" ]] || fail_test "temporary files left behind: $leftovers"

printf '[PASS] Codex Balance app checks\n'
