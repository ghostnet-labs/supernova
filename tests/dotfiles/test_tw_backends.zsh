#!/usr/bin/env zsh
# setup-test: tw backends
# Regression coverage for tw's tmux and Zellij backend dispatch.
emulate -L zsh
setopt pipefail
exec </dev/null

SCRIPT_DIR="${0:A:h}"
REPO_DIR="${SCRIPT_DIR:A:h:h}"
for functions_file in "$REPO_DIR"/dotfiles/functions/*.zsh; do source "$functions_file"; done

source "${0:A:h:h}/lib/assert.sh"

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/tw-backends-test.XXXXXX")" || exit 1
cleanup() {
  rm -rf -- "$tmp_root"
}
trap cleanup EXIT INT TERM

DOTFILE_DIR="$tmp_root/dotfiles"
navigator_dir="$DOTFILE_DIR/.bin"
call_log="$tmp_root/calls"
mkdir -p "$navigator_dir"
export TW_TEST_CALL_LOG="$call_log"

for backend in tmux zellij; do
  {
    print -r -- '#!/bin/sh'
    print -r -- "printf '%s\\n' \"$backend-fzf \$*\" >>\"\$TW_TEST_CALL_LOG\""
  } >"$navigator_dir/$backend-fzf"
  chmod +x "$navigator_dir/$backend-fzf"
done

tmux() {
  [[ "$1" == "list-sessions" ]] && return 0
  print -r -- "tmux $*" >>"$call_log"
}

zellij() {
  print -r -- "zellij $*" >>"$call_log"
}

assert_call() {
  local expected="$1"
  local actual="$(<$call_log)"
  [[ "$actual" == "$expected" ]] || fail_test "expected '$expected', got '$actual'"
  : >"$call_log"
}

unset TMUX ZELLIJ ZELLIJ_SESSION_NAME TW_BACKEND
tw
assert_call "tmux-fzf navigate"

TW_BACKEND=zellij
tw -p
assert_call "zellij-fzf projects"

TMUX=/tmp/tmux-fixture
tw
assert_call "tmux-fzf navigate"

ZELLIJ_SESSION_NAME=active-zellij
tw
assert_call "zellij-fzf navigate"

tw --tmux projects
assert_call "tmux-fzf projects"

tw -t projects
assert_call "tmux-fzf projects"

tw --zellij -ls
assert_call "zellij list-sessions"

tw -z -ls
assert_call "zellij list-sessions"

tw --zellij validation
assert_call "zellij action switch-session validation"

unset TMUX ZELLIJ ZELLIJ_SESSION_NAME
tw --zellij validation
assert_call "zellij attach -c validation"

help_output="$(tw --zellij --help)" || fail_test "backend-qualified help failed"
[[ "${help_output%%$'\n'*}" == "Usage:" ]] || fail_test "help does not begin with Usage"
assert_contains "$help_output" $'\n\nDescription:'
assert_contains "$help_output" $'\n\nOptions:'
assert_contains "$help_output" $'\n\nExamples:'
assert_contains "$help_output" $'\n\nEnvironment:'
assert_contains "$help_output" "TW_BACKEND"
assert_contains "$help_output" "-t, --tmux"
assert_contains "$help_output" "-z, --zellij"
[[ ! -s "$call_log" ]] || fail_test "help contacted a backend"

TW_BACKEND=invalid
invalid_status=0
invalid_output="$(tw 2>&1)" || invalid_status=$?
[[ "$invalid_status" == 2 ]] || fail_test "invalid backend returned $invalid_status"
assert_contains "$invalid_output" "must be 'tmux' or 'zellij'"

print -r -- "PASS: tw backend dispatch checks"
