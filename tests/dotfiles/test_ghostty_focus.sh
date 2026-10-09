#!/usr/bin/env bash
# setup-test: ghostty-focus

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/assert.sh
source "$repo_root/tests/lib/assert.sh"
command_path="$repo_root/dotfiles/.bin/ghostty-focus"

help="$("$command_path" --help)"
assert_contains "$help" "Usage:"
assert_contains "$help" "--dry-run"
status=0; "$command_path" >/dev/null 2>&1 || status=$?
assert_equals "$status" 2
status=0; "$command_path" --pid 1 --tty /dev/ttys001 >/dev/null 2>&1 || status=$?
assert_equals "$status" 2
status=0; "$command_path" --pid nope >/dev/null 2>&1 || status=$?
assert_equals "$status" 2

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ghostty-focus-test.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/fake"

# A fake process table: env.PID is `ps eww` output, tty.PID is the TTY name.
printf '%s\n' '#!/bin/sh
last=""; for arg in "$@"; do last="$arg"; done
case "$*" in
  "eww -o command= -p "*) cat "$FAKE/env.$last" 2>/dev/null ;;
  "-o tty= -p "*) cat "$FAKE/tty.$last" 2>/dev/null || echo "??" ;;
  "-ax -o pid= -o command=") cat "$FAKE/processes" ;;
esac' >"$tmp/bin/ps"
printf '%s\n' '#!/bin/sh
printf '\''%s\n'\'' "$*" >>"$FAKE/tmux.log"
[ "$2" = /tmp/tmux-501/default ] || exit 1
case "$*" in
  *display-message*) echo work ;;
  *list-clients*) printf '\''100 300\n200 301\n'\'' ;;
esac' >"$tmp/bin/tmux"
chmod +x "$tmp/bin/ps" "$tmp/bin/tmux"
fake="$tmp/fake"
printf 'claude TERM_PROGRAM=ghostty\n' >"$fake/env.10"; echo ttys004 >"$fake/tty.10"
printf 'codex TMUX=/tmp/tmux-501/default,1,0 TMUX_PANE=%%3 TERM_PROGRAM=tmux\n' >"$fake/env.11"
printf 'tmux TERM_PROGRAM=ghostty\n' >"$fake/env.301"; echo ttys009 >"$fake/tty.301"; echo ttys008 >"$fake/tty.300"
printf 'claude ZELLIJ_SESSION_NAME=dev ZELLIJ_PANE_ID=2\n' >"$fake/env.12"
printf 'claude ZELLIJ_SESSION_NAME=random-name\n' >"$fake/env.13"
printf 'claude TERM_PROGRAM=Apple_Terminal\n' >"$fake/env.14"; echo ttys002 >"$fake/tty.14"
printf 'claude TMUX=/tmp/elsewhere,1,0 TMUX_PANE=%%1\n' >"$fake/env.15"
printf '%s\n' '400 /opt/homebrew/bin/zellij --server /tmp/zellij/dev
401 zellij attach other
402 -zellij -s dev
500 zellij' >"$fake/processes"
echo ttys005 >"$fake/tty.401"; echo ttys006 >"$fake/tty.402"; echo ttys007 >"$fake/tty.500"
printf 'zellij TERM_PROGRAM=ghostty\n' >"$fake/env.402"

focus() { PATH="$tmp/bin:$PATH" FAKE="$fake" "$command_path" --pid "$1" --dry-run 2>&1; }

assert_equals "$(focus 10)" /dev/ttys004
assert_equals "$(focus 11)" /dev/ttys009
assert_contains "$(cat "$fake/tmux.log")" "-S /tmp/tmux-501/default display-message -p -t %3"
assert_equals "$(focus 12)" /dev/ttys006
assert_equals "$(focus 13)" /dev/ttys007
status=0; output="$(focus 14)" || status=$?
assert_equals "$status" 1
assert_contains "$output" "not Ghostty"
status=0; output="$(focus 15)" || status=$?
assert_equals "$status" 1
assert_contains "$output" "no attached terminal client"

printf 'PASS: ghostty-focus\n'
