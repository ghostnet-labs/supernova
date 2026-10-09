#!/usr/bin/env bash
# setup-test: Status output
# Regression checks for the shared one-row status renderer.
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
STATUS_OUTPUT="$REPO_DIR/setup/status_output.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/setup-status-output-test.XXXXXX")"

cleanup() {
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/assert.sh"

static_output="$(/bin/bash -c '
  source "$1"
  setup_status_start "Checking static output"
  setup_status_pass "Static output passed"
  setup_status_info "Informational result"
  setup_status_warning "Warning result"
  setup_status_fail "Failure result"
  setup_status_action "Proposed action"
  setup_status_detail "Supporting detail"
  setup_status_section "Section title"
  setup_status_summary "Run complete."
' _ "$STATUS_OUTPUT")"

expected_static="$(printf '%s\n' \
  '✓  Static output passed' \
  '•  Informational result' \
  '!  Warning result' \
  '✗  Failure result' \
  '→  Proposed action' \
  '   Supporting detail' \
  '' \
  '── Section title' \
  '' \
  '[SUMMARY] Run complete.')"
[[ "$static_output" == "$expected_static" ]] || fail_test "redirected status output changed"
[[ "$static_output" != *$'\033'* && "$static_output" != *$'\r'* ]] ||
  fail_test "redirected status output contains terminal control sequences"

prompt_output="$(/bin/bash -c '
  source "$1"
  setup_status_prompt "Continue? "
  printf "yes\n"
' _ "$STATUS_OUTPUT")"
[[ "$prompt_output" == $'\n→  Continue? yes' ]] || fail_test "redirected prompt output changed"

tty_output="$TMP_ROOT/tty-output"
TERM=xterm-256color SETUP_STATUS_FORCE_TTY=true SETUP_STATUS_INTERVAL=0.01 /bin/bash -c '
  unset NO_COLOR
  source "$1"
  setup_status_start "Animated check"
  sleep 0.05
  setup_status_pass "Animated check"
  [[ -z "$SETUP_STATUS_SPINNER_PID" ]]
' _ "$STATUS_OUTPUT" >"$tty_output"

tty_text="$(<"$tty_output")"
[[ "$tty_text" == *$'\033[36m⠋\033[0m  Animated check'* ]] || fail_test "colored spinner frame was not rendered"
[[ "$tty_text" == *$'\033[32m✓\033[0m  Animated check'* ]] || fail_test "spinner row did not finish as a colored pass"
[[ "$(wc -l <"$tty_output" | tr -d ' ')" -eq 1 ]] || fail_test "spinner emitted more than one terminal row"
[[ "$tty_text" != *'[CHECK]'* && "$tty_text" != *'[PASS]'* ]] || fail_test "legacy status labels remain"

color_output="$(TERM=xterm-256color SETUP_STATUS_FORCE_TTY=true /bin/bash -c '
  unset NO_COLOR
  source "$1"
  setup_status_info "Information"
  setup_status_warning "Warning"
  setup_status_fail "Failure"
  setup_status_action "Action"
  setup_status_section "Section"
  setup_status_summary "Summary"
' _ "$STATUS_OUTPUT")"
[[ "$color_output" == *$'\033[36m•\033[0m  Information'* ]] || fail_test "information marker is not cyan"
[[ "$color_output" == *$'\033[33m!\033[0m  Warning'* ]] || fail_test "warning marker is not yellow"
[[ "$color_output" == *$'\033[31m✗\033[0m  Failure'* ]] || fail_test "failure marker is not red"
[[ "$color_output" == *$'\033[36m→\033[0m  Action'* ]] || fail_test "action marker is not cyan"
[[ "$color_output" == *$'\033[34m──\033[0m Section'* ]] || fail_test "section marker is not blue"
[[ "$color_output" == *$'\033[1m[SUMMARY]\033[0m Summary'* ]] || fail_test "summary label is not bold"

color_prompt_output="$(TERM=xterm-256color SETUP_STATUS_FORCE_TTY=true /bin/bash -c '
  unset NO_COLOR
  source "$1"
  setup_status_prompt "Continue? "
  printf "yes\n"
' _ "$STATUS_OUTPUT")"
[[ "$color_prompt_output" == *$'\033[36m→\033[0m  Continue? yes'* ]] || fail_test "prompt marker is not cyan"

no_color_output="$(TERM=xterm-256color NO_COLOR=1 SETUP_STATUS_FORCE_TTY=true /bin/bash -c '
  source "$1"
  setup_status_pass "Color disabled"
  setup_status_prompt "Continue? "
  printf "no\n"
' _ "$STATUS_OUTPUT")"
[[ "$no_color_output" == $'✓  Color disabled\n\n→  Continue? no' ]] || fail_test "NO_COLOR output is not plain"

dumb_output="$(TERM=dumb SETUP_STATUS_FORCE_TTY=true /bin/bash -c '
  unset NO_COLOR
  source "$1"
  setup_status_pass "Dumb terminal"
  setup_status_prompt "Continue? "
  printf "no\n"
' _ "$STATUS_OUTPUT")"
[[ "$dumb_output" == $'✓  Dumb terminal\n\n→  Continue? no' ]] || fail_test "TERM=dumb output is not plain"

printf '[PASS] shared status output checks\n'
