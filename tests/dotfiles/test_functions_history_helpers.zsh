#!/usr/bin/env zsh
# setup-test: History helpers
# Verify reusable command arguments, safe defaults, and dependency failures.
emulate -L zsh
setopt pipefail
exec </dev/null

repo_dir="${0:A:h:h:h}"
source "$repo_dir/tests/lib/assert.sh"
real_python="$(whence -p python3)"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/history-helpers.XXXXXX")" || exit 1
tmp_root="${tmp_root:A}"
trap 'rm -rf -- "$tmp_root"' EXIT INT TERM
mkdir -p "$tmp_root/bin" "$tmp_root/empty"
export HISTORY_HELPER_TRACE="$tmp_root/trace.json" HISTORY_HELPER_EXIT=0
printf '%s\n' \
  "#!$real_python" \
  'import json, os, pathlib, sys' \
  'name = pathlib.Path(sys.argv[0]).name' \
  'pathlib.Path(os.environ["HISTORY_HELPER_TRACE"]).write_text(json.dumps([name, *sys.argv[1:]]))' \
  'if name == "curl": print(os.environ.get("HISTORY_HELPER_CURL_BODY", "{\"ok\": true}"))' \
  'sys.exit(int(os.environ.get("HISTORY_HELPER_EXIT", "0")))' \
  >"$tmp_root/bin/stub"
chmod +x "$tmp_root/bin/stub"
for executable in git rg fd curl ssh wc; do
  ln -s stub "$tmp_root/bin/$executable"
done
original_path=("${path[@]}")
path=("$tmp_root/bin" "${path[@]}")
source "$repo_dir/dotfiles/functions/history_helpers.zsh"
[[ ! -e "$HISTORY_HELPER_TRACE" ]] || fail_test 'sourcing invoked an external command'

expect_call() {
  "$real_python" -c 'import json,sys; actual=json.load(open(sys.argv[1])); expected=sys.argv[2:]; assert actual == expected, (actual,expected)' \
    "$HISTORY_HELPER_TRACE" "$@" || fail_test 'forwarded arguments differ'
}
expect_status() {
  local expected="$1" result=0
  shift
  "$@" >"$tmp_root/output" 2>&1 || result=$?
  assert_equals "$result" "$expected"
}

# Help works without dependencies, is inert, and uses the standard layout.
helpers=(gdiff gstaged glog gahead gbehind gfiles gfilelog rfind rcontext rcount ffind flines httpstatus httpjson sshproxy sshtunnel)
for helper in "${helpers[@]}"; do
  path=("$tmp_root/empty")
  help_output="$("$helper" --help)" || fail_test "$helper help failed"
  assert_contains "$help_output" $'Usage:\n'
  for heading in Description: Options: Examples:; do
    assert_contains "$help_output" $'\n'"$heading"$'\n'
  done
  [[ ! -e "$HISTORY_HELPER_TRACE" ]] || fail_test "$helper help invoked a command"
done
path=("$tmp_root/bin" "${original_path[@]}")

gdiff || fail_test 'gdiff failed'
expect_call git --literal-pathspecs diff --
literal='file $(touch NEVER) ; *.txt'
gdiff -- "$literal" '-leading-dash' || fail_test 'literal gdiff failed'
expect_call git --literal-pathspecs diff -- "$literal" '-leading-dash'
gstaged --stat README.md || fail_test 'gstaged failed'
expect_call git --literal-pathspecs diff --cached --stat -- README.md
gstaged --check || fail_test 'gstaged check failed'
expect_call git --literal-pathspecs diff --cached --check --
glog || fail_test 'glog default failed'
expect_call git log --oneline --decorate --graph --max-count=20 --
glog 08 || fail_test 'decimal count failed'
expect_call git log --oneline --decorate --graph --max-count=08 --
gahead || fail_test 'gahead failed'
expect_call git log --oneline --decorate '@{u}..HEAD' --
gbehind 'origin/branch with spaces' || fail_test 'gbehind failed'
expect_call git log --oneline --decorate 'HEAD..origin/branch with spaces' --
gfiles || fail_test 'gfiles failed'
expect_call git diff --name-status '@{u}...HEAD' --
gfilelog "$literal" README.md || fail_test 'gfilelog failed'
expect_call git --literal-pathspecs log --oneline --decorate --stat -- "$literal" README.md

rfind 'TODO|FIXME' || fail_test 'rfind failed'
expect_call rg --hidden --glob '!.git' --smart-case --no-heading --line-number -e 'TODO|FIXME' -- .
rcontext -- '-error; $(touch NEVER)' 'logs with spaces' || fail_test 'rcontext failed'
expect_call rg --hidden --glob '!.git' --smart-case --no-heading --line-number --context 5 -e '-error; $(touch NEVER)' -- 'logs with spaces'
rcount TODO README.md dotfiles || fail_test 'rcount failed'
expect_call rg --hidden --glob '!.git' --smart-case --no-heading --count -e TODO -- README.md dotfiles
ffind '.*\.zsh$' 'directory with spaces' || fail_test 'ffind failed'
expect_call fd --hidden --no-ignore --ignore-case --type f --exclude .git -- '.*\.zsh$' 'directory with spaces'
flines || fail_test 'flines failed'
expect_call fd --type f --max-depth 5 --exclude .git --exclude __pycache__ . ./. --exec-batch wc -l
flines -- '-directory' || fail_test 'literal flines failed'
expect_call fd --type f --max-depth 5 --exclude .git --exclude __pycache__ . ./-directory --exec-batch wc -l

httpstatus 'https://example.com/?a=b&c=$(touch NEVER)' >/dev/null || fail_test 'httpstatus failed'
expect_call curl --disable --silent --show-error --max-time 30 --proto '=http,https' --output /dev/null --write-out '%{http_code}\n' -- 'https://example.com/?a=b&c=$(touch NEVER)'
json_output="$(httpjson https://example.com/status)" || fail_test 'httpjson failed'
assert_contains "$json_output" '"ok": true'
expect_call curl --disable --fail --silent --show-error --max-time 30 --proto '=http,https' -- https://example.com/status
sshproxy example-host || fail_test 'sshproxy failed'
expect_call ssh -o ExitOnForwardFailure=yes -N -D 127.0.0.1:1080 -- example-host
sshproxy 'user@example-host' 1081 || fail_test 'sshproxy port failed'
expect_call ssh -o ExitOnForwardFailure=yes -N -D 127.0.0.1:1081 -- 'user@example-host'
sshtunnel example-host 8080 || fail_test 'sshtunnel defaults failed'
expect_call ssh -o ExitOnForwardFailure=yes -N -L 127.0.0.1:8080:localhost:8080 -- example-host
sshtunnel example-host 8080 80 service.internal || fail_test 'sshtunnel target failed'
expect_call ssh -o ExitOnForwardFailure=yes -N -L 127.0.0.1:8080:service.internal:80 -- example-host

# Native failures remain failures, including curl errors before JSON parsing.
HISTORY_HELPER_EXIT=23
expect_status 23 gdiff
expect_status 23 rfind TODO
expect_status 23 httpjson https://example.com/status
expect_status 23 sshproxy example-host
HISTORY_HELPER_EXIT=0
export HISTORY_HELPER_CURL_BODY='not json'
expect_status 1 httpjson https://example.com/status
unset HISTORY_HELPER_CURL_BODY

# Reject invalid input before calling a dependency.
rm -f "$HISTORY_HELPER_TRACE"
for helper in "${helpers[@]}"; do expect_status 2 "$helper" --unknown; done
for helper in gfilelog rfind rcontext rcount ffind httpstatus httpjson sshproxy sshtunnel; do
  expect_status 2 "$helper"
  assert_contains "$(<"$tmp_root/output")" Usage:
done
for count in 0 -1 10001 999999999999999999999 '1+1' '2; touch NEVER'; do expect_status 2 glog "$count"; done
for helper in gahead gbehind gfiles; do expect_status 2 "$helper" -- '--output=unsafe'; done
for port in 0 65536 -1 999999999999999999 '1+1' '80; touch NEVER'; do
  expect_status 2 sshproxy example-host "$port"
  expect_status 2 sshtunnel example-host 8080 "$port"
done
expect_status 2 sshtunnel example-host 8080 80 'host:22'
expect_status 2 sshtunnel example-host 8080 80 'host $(touch NEVER)'
expect_status 2 glog 10 unexpected
expect_status 2 ffind x . unexpected
[[ ! -e "$HISTORY_HELPER_TRACE" ]] || fail_test 'invalid arguments invoked a command'

path=("$tmp_root/empty")
expect_status 127 gdiff
assert_contains "$(<"$tmp_root/output")" 'required command is unavailable: git'
expect_status 127 rfind TODO
expect_status 127 ffind readme
expect_status 127 httpstatus https://example.com
expect_status 127 httpjson https://example.com
expect_status 127 sshproxy example-host
path=("${original_path[@]}")

# A real Git fixture verifies that -- does not accidentally leave glob pathspecs.
(
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME='Fixture' GIT_AUTHOR_EMAIL='fixture@example.com'
  export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
  mkdir -p "$tmp_root/literal-repo"
  builtin cd -- "$tmp_root/literal-repo" || exit 1
  command git init -q || exit 1
  print -r -- original >'[ab].txt'
  print -r -- original >a.txt
  command git add --all || exit 1
  command git -c commit.gpgsign=false commit -m 'test: seed literal path fixture' || exit 1
  print -r -- literal-target-change >>'[ab].txt'
  print -r -- other-file-change >>a.txt
  diff_output="$(gdiff '[ab].txt')" || exit 1
  assert_contains "$diff_output" literal-target-change
  assert_not_contains "$diff_output" other-file-change
  command git add --all || exit 1
  staged_output="$(gstaged '[ab].txt')" || exit 1
  assert_contains "$staged_output" literal-target-change
  assert_not_contains "$staged_output" other-file-change
  log_output="$(gfilelog '[ab].txt')" || exit 1
  assert_contains "$log_output" '[ab].txt'
  assert_not_contains "$log_output" ' a.txt '
) || fail_test 'Git helpers did not preserve literal path selection'

print -r -- 'PASS: history helpers (16 commands, argument forwarding, errors, and inert help)'
