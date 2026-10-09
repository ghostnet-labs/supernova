#!/usr/bin/env zsh
# setup-test: Shell functions
# Covers why, paths, topcmds, toolbox, when, the ll/cd hooks, and SSH agent refresh in dotfiles/functions/shell.zsh.
emulate -L zsh
setopt pipefail
exec </dev/null

repo_dir="${0:A:h:h:h}"
source "$repo_dir/tests/lib/assert.sh"
original_path=("${path[@]}")
# The ll function must replace an ll alias defined before loading.
alias ll='ls -alh --color=auto'
for functions_file in "$repo_dir"/dotfiles/functions/*.zsh; do source "$functions_file"; done

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/functions-test.XXXXXX")" || exit 1
# Helpers print resolved paths; macOS TMPDIR is a symlink with a trailing slash.
tmp_root="${tmp_root:A}"
agent_dir=""
cleanup() {
  rm -rf -- "$tmp_root" ${agent_dir:+"$agent_dir"}
}
trap cleanup EXIT INT TERM

(( $+functions[tw] )) || fail_test "pre-existing ll alias prevented tw from loading"
(( $+functions[ll] )) || fail_test "ll function was not loaded"
(( ! $+aliases[ll] )) || fail_test "pre-existing ll alias was not removed"

fallback_status=0
PATH=/usr/bin:/bin zsh -f -c '
  alias ll="ls -alh --color=auto"
  for functions_file in "$1"/*.zsh; do source "$functions_file"; done
  _setup_chpwd_list >/dev/null 2>&1 || exit 1
  (( ${chpwd_functions[(Ie)_setup_chpwd_list]} )) || exit 1
  (( $+functions[ll] && $+functions[tw] && ! $+aliases[ll] ))
' zsh "$repo_dir/dotfiles/functions" || fallback_status=$?
[[ "$fallback_status" == 0 ]] || fail_test "ll fallback did not load as a function"

large_dir="$(mktemp -d)"
for index in {1..501}; do : > "$large_dir/file-$index"; done
large_listing="$(cd -q "$large_dir" && _setup_chpwd_list 2>&1)"
[[ "$large_listing" == "More than 500 entries; run ll to list them." ]] ||
  fail_test "chpwd listing did not cap a large directory: $large_listing"
rm -rf "$large_dir"


why_help="$(why --help)" || fail_test "why help failed"
[[ "${why_help%%$'\n'*}" == "Usage:" ]] || fail_test "why help does not begin with Usage"
assert_contains "$why_help" $'\n\nDescription:'
assert_contains "$why_help" $'\n\nOptions:'
assert_contains "$why_help" $'\n\nExamples:'

alias why_alias='print hello world'
why_alias_output="$(why why_alias)" || fail_test "why alias lookup failed"
assert_contains "$why_alias_output" "Type: alias"
assert_contains "$why_alias_output" "Definition: alias why_alias='print hello world'"

why_fixture() {
  print -r -- "fixture body"
}
why_function_output="$(why why_fixture)" || fail_test "why function lookup failed"
assert_contains "$why_function_output" "Type: function"
assert_contains "$why_function_output" "Source:"
print -r -- "$why_function_output" | grep -Eq '^Source: .+:[0-9]+$' || fail_test "why function source omitted its line"
assert_not_contains "$why_function_output" "fixture body"
assert_not_contains "$why_function_output" "Executables:"
why_body_output="$(why --body why_fixture)" || fail_test "why function body lookup failed"
assert_contains "$why_body_output" "fixture body"

why_bin_one="$tmp_root/why-bin-one"
why_bin_two="$tmp_root/why-bin-two"
mkdir -p "$why_bin_one" "$why_bin_two"
print -r -- '#!/bin/sh' >"$why_bin_one/why-fixture"
print -r -- '#!/bin/sh' >"$why_bin_two/why-fixture"
chmod +x "$why_bin_one/why-fixture" "$why_bin_two/why-fixture"
why_command_output="$(path=("$why_bin_one" "$why_bin_two" "${path[@]}"); rehash; why why-fixture)" || fail_test "why executable lookup failed"
assert_contains "$why_command_output" "Type: executable"
assert_contains "$why_command_output" "Selected: $why_bin_one/why-fixture"
assert_contains "$why_command_output" "Alternates:"
assert_contains "$why_command_output" "$why_bin_two/why-fixture"

why_status=0
why_error="$(why definitely-not-a-command 2>&1)" || why_status=$?
[[ "$why_status" == 1 ]] || fail_test "why missing command returned $why_status"
assert_contains "$why_error" "command not found"

paths_help="$(paths --help)" || fail_test "paths help failed"
[[ "${paths_help%%$'\n'*}" == "Usage:" ]] || fail_test "paths help does not begin with Usage"
assert_contains "$paths_help" $'\n\nDescription:'
assert_contains "$paths_help" $'\n\nOptions:'
assert_contains "$paths_help" $'\n\nExamples:'
assert_contains "$paths_help" $'\n\nEnvironment:'

paths_one="$tmp_root/paths-one"
paths_two="$tmp_root/paths-two"
paths_alias="$tmp_root/paths-alias"
paths_missing="$tmp_root/paths-missing"
paths_file="$tmp_root/paths-file"
paths_no_search="$tmp_root/paths-no-search"
mkdir -p "$paths_one" "$paths_two" "$paths_no_search"
command ln -s "$paths_one" "$paths_alias"
print -r -- "not a directory" >"$paths_file"
chmod 600 "$paths_no_search"

paths_output="$(HOME="$tmp_root/fake-home"; path=("$paths_one" "$paths_two" "$paths_alias" "$paths_missing" "$paths_file" "$paths_no_search" ""); paths)" || fail_test "paths report failed"
print -r -- "$paths_output" | command grep -Eq '^ORDER +STATUS +DUP +PATH$' || fail_test "paths table header is missing"
paths_one_row="$(print -r -- "$paths_output" | command awk -v path="$paths_one" '$NF == path { print }')"
assert_contains "$paths_one_row" "ok"
assert_contains "$paths_one_row" " - "
paths_alias_row="$(print -r -- "$paths_output" | command awk -v path="$paths_alias" '$NF == path { print }')"
assert_contains "$paths_alias_row" "ok"
assert_contains "$paths_alias_row" "#1"
paths_missing_row="$(print -r -- "$paths_output" | command awk -v path="$paths_missing" '$NF == path { print }')"
assert_contains "$paths_missing_row" "missing"
paths_file_row="$(print -r -- "$paths_output" | command awk -v path="$paths_file" '$NF == path { print }')"
assert_contains "$paths_file_row" "not-dir"
paths_no_search_row="$(print -r -- "$paths_output" | command awk -v path="$paths_no_search" '$NF == path { print }')"
assert_contains "$paths_no_search_row" "no-search"
assert_contains "$paths_output" "current-dir"
assert_contains "$paths_output" "empty entry; current directory"

paths_status=0
paths_error="$(paths unexpected 2>&1)" || paths_status=$?
[[ "$paths_status" == 2 ]] || fail_test "paths with an argument returned $paths_status"
assert_contains "$paths_error" "does not accept arguments"

topcmds_help="$(topcmds --help)" || fail_test "topcmds help failed"
[[ "${topcmds_help%%$'\n'*}" == "Usage:" ]] || fail_test "topcmds help does not begin with Usage"
assert_contains "$topcmds_help" $'\n\nDescription:'
assert_contains "$topcmds_help" $'\n\nOptions:'
assert_contains "$topcmds_help" $'\n\nExamples:'
assert_contains "$topcmds_help" $'\n\nEnvironment:'

topcmds_history="$tmp_root/topcmds-history"
{
  print -r -- ': 1788451200:0;git status'
  print -r -- ': 1788451201:1;sudo git fetch'
  print -r -- 'git log --oneline'
  print -r -- 'SETUP_TEST=1 git diff'
  print -r -- 'sudo -u root apt update'
  print -r -- 'sudo --user root rg pattern'
  print -r -- '/usr/bin/python3 script.py'
  print -r -- '# ignored comment'
  print
} >"$topcmds_history"

topcmds_output="$(HISTFILE="$topcmds_history" topcmds)" || fail_test "topcmds report failed"
print -r -- "$topcmds_output" | command grep -Eq '^COUNT +COMMAND$' || fail_test "topcmds table header is missing"
topcmds_first_row="$(print -r -- "$topcmds_output" | command sed -n '2p')"
assert_contains "$topcmds_first_row" "4"
assert_contains "$topcmds_first_row" "git"
assert_not_contains "$topcmds_output" "sudo"

topcmds_limited="$(HISTFILE="$topcmds_history" topcmds 2)" || fail_test "topcmds limited report failed"
(( $(print -r -- "$topcmds_limited" | command wc -l) == 3 )) || fail_test "topcmds did not honor its limit"

topcmds_status=0
topcmds_error="$(HISTFILE="$topcmds_history" topcmds 0 2>&1)" || topcmds_status=$?
[[ "$topcmds_status" == 2 ]] || fail_test "topcmds invalid limit returned $topcmds_status"
assert_contains "$topcmds_error" "positive integer"

topcmds_status=0
topcmds_error="$(HISTFILE="$tmp_root/missing-history" topcmds 2>&1)" || topcmds_status=$?
[[ "$topcmds_status" == 1 ]] || fail_test "topcmds missing history returned $topcmds_status"
assert_contains "$topcmds_error" "history file not found or unreadable"

toolbox_help="$(toolbox --help)" || fail_test "toolbox help failed"
[[ "${toolbox_help%%$'\n'*}" == "Usage:" ]] || fail_test "toolbox help does not begin with Usage"
assert_contains "$toolbox_help" $'\n\nDescription:'
assert_contains "$toolbox_help" $'\n\nOptions:'
assert_contains "$toolbox_help" $'\n\nExamples:'

toolbox_output="$(toolbox)" || fail_test "toolbox report failed"
print -r -- "$toolbox_output" | command grep -Eq '^COMMAND +SOURCE +DESCRIPTION$' || fail_test "toolbox table header is missing"
assert_contains "$toolbox_output" "branches"
assert_contains "$toolbox_output" "mounts"
assert_contains "$toolbox_output" "topcmds"
assert_contains "$toolbox_output" "toolbox"
assert_contains "$toolbox_output" "when"

toolbox_git="$(toolbox git)" || fail_test "toolbox Git filter failed"
assert_contains "$toolbox_git" "branches"
assert_contains "$toolbox_git" "repos"
assert_contains "$toolbox_git" "stashes"
assert_not_contains "$toolbox_git" "mounts"

toolbox_network="$(toolbox network)" || fail_test "toolbox network filter failed"
assert_contains "$toolbox_network" "netcheck"
assert_contains "$toolbox_network" "netrate"
assert_contains "$toolbox_network" "ports"
assert_contains "$toolbox_network" "sshcheck"

toolbox_status=0
toolbox_error="$(toolbox definitely-no-match 2>&1)" || toolbox_status=$?
[[ "$toolbox_status" == 1 ]] || fail_test "toolbox empty filter returned $toolbox_status"
assert_contains "$toolbox_error" "no commands match"

zmodload zsh/net/socket || fail_test "zsh socket module is unavailable"
# Unix socket paths are capped near 104 bytes on macOS and zsocket truncates
# longer ones, so keep the agent fixtures out of the long resolved TMPDIR.
agent_dir="$(mktemp -d /tmp/fh-agent.XXXXXX)" || fail_test "could not create agent fixture directory"
agent_bin="$agent_dir/bin"
mkdir -p "$agent_dir"
mkdir -p "$agent_bin"
forwarded_agent="$agent_dir/forwarded.sock"
replacement_agent="$agent_dir/replacement.sock"
unresponsive_agent="$agent_dir/unresponsive.sock"
stable_agent="$agent_dir/stable.sock"
typeset -a temporary_agent_links
zsocket -l "$forwarded_agent" || fail_test "could not create forwarded agent fixture"
forwarded_fd=$REPLY
zsocket -l "$replacement_agent" || fail_test "could not create replacement agent fixture"
replacement_fd=$REPLY
zsocket -l "$unresponsive_agent" || fail_test "could not create unresponsive agent fixture"
unresponsive_fd=$REPLY

{
  print -r -- '#!/bin/sh'
  print -r -- 'case "$SSH_AUTH_SOCK" in'
  print -r -- '  *unresponsive*.sock) exit 124 ;;'
  print -r -- '  *) [ -S "$SSH_AUTH_SOCK" ] && exit 0 ;;'
  print -r -- 'esac'
  print -r -- 'exit 2'
} >"$agent_bin/timeout"
print -r -- '#!/bin/sh' >"$agent_bin/ssh-add"
chmod +x "$agent_bin/timeout" "$agent_bin/ssh-add"
path=("$agent_bin" "${path[@]}")
rehash

SSH_TTY=/dev/pts/setup-test
unset SETUP_FORWARDED_SSH_AGENT_LINK
SSH_AUTH_SOCK="$forwarded_agent"
_setup_refresh_forwarded_ssh_agent
[[ ! -e "$stable_agent" && ! -L "$stable_agent" ]] || fail_test "unset opt-in created a stable agent link"

SETUP_FORWARDED_SSH_AGENT_LINK="$stable_agent"
SSH_AUTH_SOCK="$agent_dir/missing.sock"
agent_error_file="$agent_dir/error"
agent_status=0
_setup_refresh_forwarded_ssh_agent 2>"$agent_error_file" || agent_status=$?
[[ "$agent_status" == 1 ]] || fail_test "missing forwarded agent returned $agent_status"
[[ ! -e "$stable_agent" && ! -L "$stable_agent" ]] || fail_test "missing forwarded socket created a stable agent link"
[[ -z "${SSH_AUTH_SOCK:-}" ]] || fail_test "missing forwarded agent remained selected"
assert_contains "$(<$agent_error_file)" "reconnect with agent forwarding"

unset SSH_TTY
SSH_AUTH_SOCK="$forwarded_agent"
_setup_refresh_forwarded_ssh_agent
[[ ! -e "$stable_agent" && ! -L "$stable_agent" ]] || fail_test "non-interactive shell created a stable agent link"

SSH_TTY=/dev/pts/setup-test
SSH_AUTH_SOCK="$forwarded_agent"
_setup_refresh_forwarded_ssh_agent
[[ -L "$stable_agent" ]] || fail_test "stable agent link was not created"
[[ "$(readlink "$stable_agent")" == "$forwarded_agent" ]] || fail_test "stable agent link has the wrong target"
[[ "$SSH_AUTH_SOCK" == "$stable_agent" ]] || fail_test "SSH_AUTH_SOCK did not use the stable link"

unset SSH_TTY
SSH_AUTH_SOCK="$replacement_agent"
_setup_refresh_forwarded_ssh_agent
[[ "$(readlink "$stable_agent")" == "$forwarded_agent" ]] || fail_test "non-interactive shell replaced the stable agent link"
[[ "$SSH_AUTH_SOCK" == "$stable_agent" ]] || fail_test "non-interactive shell did not reuse the stable agent link"

SSH_TTY=/dev/pts/setup-test
SSH_AUTH_SOCK="$replacement_agent"
_setup_refresh_forwarded_ssh_agent
[[ "$(readlink "$stable_agent")" == "$replacement_agent" ]] || fail_test "stable agent link was not replaced"
temporary_agent_links=("$stable_agent".tmp.*(N))
(( ${#temporary_agent_links} == 0 )) || fail_test "temporary agent link was retained"

SSH_AUTH_SOCK="$unresponsive_agent"
_setup_refresh_forwarded_ssh_agent
[[ "$(readlink "$stable_agent")" == "$replacement_agent" ]] || fail_test "unresponsive forwarded agent replaced the stable link"
[[ "$SSH_AUTH_SOCK" == "$stable_agent" ]] || fail_test "responsive stable agent was not retained"

broken_agent="$agent_dir/broken-stable.sock"
ln -s "$agent_dir/missing.sock" "$broken_agent"
SETUP_FORWARDED_SSH_AGENT_LINK="$broken_agent"
SSH_AUTH_SOCK="$forwarded_agent"
_setup_refresh_forwarded_ssh_agent
[[ "$(readlink "$broken_agent")" == "$forwarded_agent" ]] || fail_test "broken stable agent link was not repaired"

SETUP_FORWARDED_SSH_AGENT_LINK="$stable_agent"
unset SSH_TTY
SSH_AUTH_SOCK="$stable_agent"
_setup_refresh_forwarded_ssh_agent
[[ "$SSH_AUTH_SOCK" == "$stable_agent" ]] || fail_test "stable agent link did not survive repeated startup"

SSH_AUTH_SOCK="$agent_dir/missing.sock"
_setup_refresh_forwarded_ssh_agent
[[ "$SSH_AUTH_SOCK" == "$stable_agent" ]] || fail_test "live stable agent link was not recovered"

protected_agent="$agent_dir/protected.sock"
print -r -- "keep" >"$protected_agent"
SETUP_FORWARDED_SSH_AGENT_LINK="$protected_agent"
SSH_TTY=/dev/pts/setup-test
SSH_AUTH_SOCK="$forwarded_agent"
_setup_refresh_forwarded_ssh_agent
[[ "$(<"$protected_agent")" == "keep" ]] || fail_test "non-symlink agent path was overwritten"
[[ "$SSH_AUTH_SOCK" == "$forwarded_agent" ]] || fail_test "protected agent path replaced SSH_AUTH_SOCK"

directory_target="$agent_dir/directory"
directory_link="$agent_dir/directory-link"
mkdir "$directory_target"
ln -s "$directory_target" "$directory_link"
SETUP_FORWARDED_SSH_AGENT_LINK="$directory_link"
_setup_refresh_forwarded_ssh_agent
[[ "$(readlink "$directory_link")" == "$directory_target" ]] || fail_test "directory symlink was overwritten"

stale_agent="$agent_dir/unresponsive-stable.sock"
ln -s "$unresponsive_agent" "$stale_agent"
SETUP_FORWARDED_SSH_AGENT_LINK="$stale_agent"
unset SSH_TTY
SSH_AUTH_SOCK="$stale_agent"
agent_status=0
_setup_refresh_forwarded_ssh_agent 2>"$agent_error_file" || agent_status=$?
[[ "$agent_status" == 1 ]] || fail_test "unresponsive stable agent returned $agent_status"
[[ -z "${SSH_AUTH_SOCK:-}" ]] || fail_test "unresponsive stable agent remained selected"
assert_contains "$(<$agent_error_file)" "reconnect with agent forwarding"

exec {forwarded_fd}>&-
exec {replacement_fd}>&-
exec {unresponsive_fd}>&-
path=("${original_path[@]}")
rehash

# These helpers ran with a scratch HOME before the split; keep them isolated.
HOME="$tmp_root/home"
mkdir -p "$HOME"

when_help="$(when --help)" || fail_test "when help failed"
[[ "${when_help%%$'\n'*}" == "Usage:" ]] || fail_test "when help does not begin with Usage"
assert_contains "$when_help" $'\n\nDescription:'
assert_contains "$when_help" $'\n\nOptions:'
assert_contains "$when_help" $'\n\nExamples:'

when_epoch="$(TZ=UTC _WHEN_NOW_EPOCH=1788467400 when 1788460200)" || fail_test "when epoch conversion failed"
assert_contains "$when_epoch" "Mountain: 2026-09-03 12:30:00 MDT"
assert_contains "$when_epoch" "UTC:      2026-09-03 18:30:00 UTC"
assert_contains "$when_epoch" "Relative: 2 hours ago"
assert_contains "$when_epoch" "Epoch:    1788460200"

when_milliseconds="$(TZ=UTC _WHEN_NOW_EPOCH=1788467400 when 1788460200000)" || fail_test "when millisecond conversion failed"
[[ "$when_milliseconds" == "$when_epoch" ]] || fail_test "when milliseconds differ from seconds"

when_iso="$(TZ=UTC _WHEN_NOW_EPOCH=1788467400 when 2026-09-03T18:30:00Z)" || fail_test "when ISO conversion failed"
[[ "$when_iso" == "$when_epoch" ]] || fail_test "when ISO conversion differs from epoch"

when_abbreviation="$(TZ=UTC _WHEN_NOW_EPOCH=1788467400 when "2026-09-03 12:30 MDT")" || fail_test "when timezone abbreviation conversion failed"
[[ "$when_abbreviation" == "$when_epoch" ]] || fail_test "when timezone abbreviation differs from epoch"

when_mountain="$(TZ=UTC _WHEN_NOW_EPOCH=1788467400 when "2026-09-03 12:30")" || fail_test "when implicit Mountain conversion failed"
[[ "$when_mountain" == "$when_epoch" ]] || fail_test "when implicit Mountain time differs from epoch"

when_future="$(TZ=UTC _WHEN_NOW_EPOCH=1788201000 when 1788460200)" || fail_test "when future conversion failed"
assert_contains "$when_future" "Relative: in 3 days"

when_status=0
when_error="$(when definitely-not-a-time 2>&1)" || when_status=$?
[[ "$when_status" == 2 ]] || fail_test "when invalid time returned $when_status"
assert_contains "$when_error" "could not parse time"

when_status=0
when_error="$(when 2>&1)" || when_status=$?
[[ "$when_status" == 2 ]] || fail_test "when missing time returned $when_status"
assert_contains "$when_error" "a time is required"

print -r -- "PASS: shell functions checks"
