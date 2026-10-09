#!/usr/bin/env zsh
# setup-test: Toolbox discovery
# Discovery must stay current without executing helpers or loading work code.
emulate -L zsh
setopt pipefail
repo_dir="${0:A:h:h:h}"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/toolbox-test.XXXXXX")" || exit 1
trap 'rm -rf -- "$tmp_root"' EXIT

source "${0:A:h:h}/lib/assert.sh"

assert_row() {
  print -r -- "$output" | command grep -Eq "^$1 +$2 +" || fail_test "missing $1 from $2"
}
assert_absent() {
  print -r -- "$output" | command grep -Eq "^$1 +" && fail_test "unexpected $1"
  return 0
}

SETUP_DIR="$tmp_root/setup with spaces"
# The work overlay is a separate checkout; .zshrc exports WORK_DIR=WORK_ROOT/JOB.
WORK_DIR="$tmp_root/overlay with spaces/example-job"
mkdir -p "$SETUP_DIR/dotfiles/functions" "$WORK_DIR/bin-example-job" "$WORK_DIR/functions"
# Copy sources only. A copied .zwc that .zshrc compiled before a branch switch
# can end up newer than its source, and zsh would then run the stale code.
cp "$repo_dir"/dotfiles/functions/*.zsh "$SETUP_DIR/dotfiles/functions/"
cp -R "$repo_dir/dotfiles/lib" "$SETUP_DIR/dotfiles/lib"
home_file="$SETUP_DIR/dotfiles/functions/zz-test.zsh"
work_file="$WORK_DIR/bin-example-job/functions-example-job.sh"
overlay_file="$WORK_DIR/functions/widgets.zsh"
cat >"$home_file" <<'EOF'
# toolbox: testing widgets | Tagged home helper for tests.
fresh_home() { print invoked >>"$tmp_root/invocations"; }
if true; then
  # toolbox: testing | Indented helper for tests.
  indented_home () { return 1; }
fi
# toolbox: testing | Tag separated from its definition.

untagged_home() { return 1; }
_private_home() { return 1; }
precmd() { return 1; }
EOF
cat >"$work_file" <<'EOF'
fresh_work() { print invoked >>"$tmp_root/invocations"; }
_private_work() { return 1; }
EOF
cat >"$overlay_file" <<'EOF'
# toolbox: testing | Overlay functions file helper for tests.
overlay_work() { return 1; }
EOF
for functions_file in "$SETUP_DIR"/dotfiles/functions/*.zsh; do source "$functions_file"; done
unrelated() { return 1; }
WORK_ENV=false JOB=example-job
output="$(toolbox)" || fail_test "personal listing failed"
assert_row fresh_home home
assert_row indented_home home
assert_row untagged_home home
print -r -- "$output" | command grep -Eq '^fresh_home +home +Tagged home helper for tests\.$' ||
  fail_test "tag description not shown"
print -r -- "$output" | command grep -Eq '^indented_home +home +Indented helper for tests\.$' ||
  fail_test "indented tag description not shown"
print -r -- "$output" | command grep -Eq '^untagged_home +home +Shell helper from zz-test\.zsh\.$' ||
  fail_test "a tag must sit directly above its definition"
# Every real home helper carries a "# toolbox:" tag.
untagged="$(print -r -- "$output" | command grep -v -e '^untagged_home ' | command grep -F 'Shell helper from')"
[[ -z "$untagged" ]] || fail_test "helpers without a toolbox tag: $untagged"
assert_row homebrew_update home
assert_row pull_repos home
assert_row port home
for name in _private_home precmd chpwd run_spinner unrelated fresh_work; do
  assert_absent "$name"
done

WORK_ENV=true
output="$(toolbox)" || fail_test "unloaded work listing failed"
assert_absent fresh_work
source "$work_file"
source "$overlay_file"
output="$(toolbox)" || fail_test "work listing failed"
assert_row fresh_home home
assert_row fresh_work example-job
assert_row overlay_work example-job
assert_absent _private_work
output="$(toolbox EXAMPLE-JOB)" || fail_test "source filter failed"
assert_row fresh_work example-job
assert_absent fresh_home
output="$(toolbox network)" || fail_test "category filter failed"
assert_row ports home
output="$(toolbox widgets)" || fail_test "tag category filter failed"
assert_row fresh_home home
assert_absent indented_home
output="$(toolbox 'Jump to the root')" || fail_test "description filter failed"
assert_row groot home
output="$(toolbox 'fresh_')" || fail_test "name filter failed"
assert_row fresh_home home
assert_row fresh_work example-job

# Removed and overridden definitions must disappear immediately.
unfunction fresh_home
output="$(toolbox)" || fail_test "listing after removal failed"
assert_absent fresh_home
fresh_work() { return 1; }
output="$(toolbox)" || fail_test "listing after override failed"
assert_absent fresh_work
source "$work_file"
WORK_ENV=false
output="$(toolbox)" || fail_test "disabled work listing failed"
assert_absent fresh_work
WORK_ENV=true JOB=another-job
output="$(toolbox)" || fail_test "different job listing failed"
assert_absent fresh_work
JOB=example-job
unset SETUP_DIR
output="$(toolbox)" || fail_test "root fallback failed"
assert_row fresh_work example-job

SETUP_DIR="$tmp_root/setup with spaces"
source "$home_file"
mkdir -p "$SETUP_DIR/dotfiles/.bin"
personal_bin="$SETUP_DIR/dotfiles/.bin"
work_bin="$WORK_DIR/bin-example-job"
cat >"$personal_bin/managed-command" <<'EOF'
#!/bin/sh
# toolbox: testing binary | Managed executable for tests.
# toolbox-args: [PATH]
# toolbox-example: managed-command 'path with spaces'
# toolbox-example: managed-command '$(touch SHOULD_NOT_EXIST)'
exit 94
EOF
chmod +x "$personal_bin/managed-command"
cp "$personal_bin/managed-command" "$work_bin/work-command"
ln -s managed-command "$personal_bin/linked-command"
ln -s missing-command "$personal_bin/broken-command"
cp "$personal_bin/managed-command" "$personal_bin/unavailable-command"
chmod -x "$personal_bin/unavailable-command"
path=("$personal_bin" "$work_bin" "${path[@]}")
WORK_ENV=false
output="$(toolbox)" || fail_test "managed executable listing failed"
assert_row managed-command home
assert_row linked-command home
assert_absent work-command
assert_absent unavailable-command
assert_absent broken-command
output="$(toolbox --describe managed-command)" || fail_test "describe failed"
assert_contains "$output" 'Arguments: [PATH]'
assert_contains "$output" "managed-command 'path with spaces'"
assert_contains "$output" '$(touch SHOULD_NOT_EXIST)'
[[ ! -e SHOULD_NOT_EXIST ]] || fail_test "description evaluated metadata"

# Resolve aliases and duplicate executables without claiming shadowed metadata
# describes the command that will run.
alias managed-command='print alias'
output="$(toolbox --describe managed-command)" || fail_test "shadowed describe failed"
assert_contains "$output" 'Source: alias (alias)'
assert_contains "$output" 'Shadowed alternatives:'
assert_not_contains "$output" 'path with spaces'
unalias managed-command
cp "$personal_bin/managed-command" "$work_bin/managed-command"
WORK_ENV=true
output="$(toolbox --json managed-command)" || fail_test "JSON listing failed"
print -r -- "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["schema_version"] == 1; r=d["commands"][0]; assert r["source"] == "home"; assert len(r["shadowed"]) == 1; assert r["shadowed"][0]["source"] == "example-job"' || fail_test "JSON resolution was incorrect"
output="$(toolbox --json definitely-no-match)" || fail_test "empty JSON failed"
assert_contains "$output" '"commands": []'
toolbox --describe >/dev/null 2>&1
[[ $? == 2 ]] || fail_test "describe requires a name"
toolbox --describe definitely-no-match >/dev/null 2>&1
[[ $? == 1 ]] || fail_test "unknown description must fail"
toolbox --pick >/dev/null 2>&1
[[ $? == 1 ]] || fail_test "noninteractive pick must fail"

# Current PATH membership is dynamic, including removal while files still exist.
path=("${(@)path:#$personal_bin}")
output="$(toolbox)" || fail_test "listing after PATH removal failed"
assert_row managed-command example-job
assert_absent linked-command
WORK_ENV=false
output="$(toolbox)" || fail_test "Personal listing after PATH removal failed"
assert_absent managed-command
assert_absent work-command

help_output="$(toolbox --help)" || fail_test "help failed"
for section in Usage Description Options Examples Environment; do
  [[ "$help_output" == *"$section:"* ]] || fail_test "missing $section section"
done
toolbox -h >/dev/null || fail_test "short help failed"
toolbox definitely-no-match >/dev/null 2>&1
[[ $? == 1 ]] || fail_test "no matches must return 1"
toolbox --bad >/dev/null 2>&1
[[ $? == 2 ]] || fail_test "unknown option must return 2"
toolbox one two >/dev/null 2>&1
[[ $? == 2 ]] || fail_test "extra argument must return 2"
[[ ! -e "$tmp_root/invocations" ]] || fail_test "listing executed a helper"
print -r -- "PASS: toolbox discovery, scope, filters, help, and errors"
