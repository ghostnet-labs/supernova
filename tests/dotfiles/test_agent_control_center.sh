#!/usr/bin/env bash
# setup-test: Agent Control Center
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/tests/lib/assert.sh"
command_path="$repo_root/dotfiles/.bin/agent-control-center"
app_dir="$repo_root/apps/agent-control-center"
help="$("$command_path" --help)"
assert_contains "$help" 'Usage:'
assert_contains "$help" '--open'
assert_contains "$help" 'AGENT_CONTROL_CLAUDE_SESSIONS_BIN'
[[ ! -e "$repo_root/dotfiles/.bin/codex-sessions-app" ]] || fail_test 'retired launcher remains'
[[ ! -e "$repo_root/apps/codex-sessions/Info.plist" ]] || fail_test 'retired app manifest remains'
assert_contains "$(cat "$app_dir/Info.plist")" 'agent-control-center'
assert_contains "$(cat "$app_dir/Info.plist")" 'codex-sessions'
if [[ "$(uname -s)" != Darwin ]]; then exit 0; fi
tmp="$(mktemp -d "${TMPDIR:-/tmp}/agent-control-test.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home" "$tmp/build"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$tmp/clang-cache}"
# Keep Launch Services registration out of the isolated installer test.
python3 -c 'import pathlib,shlex,sys; source=pathlib.Path(sys.argv[1]).read_text(); source="\n".join("readonly source_dir="+shlex.quote(sys.argv[3]) if line.startswith("readonly source_dir=") else line for line in source.splitlines()); source=source.replace("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", "/usr/bin/true"); pathlib.Path(sys.argv[2]).write_text(source+"\n")' "$command_path" "$tmp/launcher" "$app_dir"
chmod +x "$tmp/launcher"
command_path="$tmp/launcher"
export AGENT_TEST_STATE="$tmp/launch-state"
# Like launchd, bootout returns before the service is removed; it stays loaded for two more prints.
printf '%s\n' '#!/bin/sh' 'pending="$AGENT_TEST_STATE.removing"' 'case "$1" in' \
  'print) if test -f "$pending"; then left=$(($(cat "$pending") - 1))' \
  '  if test "$left" -le 0; then rm -f "$pending" "$AGENT_TEST_STATE"; exit 1; fi; echo "$left" > "$pending"; fi' \
  '  test -f "$AGENT_TEST_STATE" || exit 1; echo "state = running" ;;' \
  'bootout) test ! -f "$AGENT_TEST_STATE" || echo 3 > "$pending" ;;' \
  'bootstrap|kickstart) test "${AGENT_TEST_FAIL_START:-0}" != 1 || exit 1; test -f "$pending" || touch "$AGENT_TEST_STATE" ;;' \
  '*) exit 2 ;;' 'esac' > "$tmp/bin/launchctl"
printf '%s\n' '#!/bin/sh' 'exit 1' > "$tmp/bin/pkill"
chmod +x "$tmp/bin/"*
env PATH="$tmp/bin:$PATH" HOME="$tmp/home" TMPDIR="$tmp/build" AGENT_CONTROL_APP_DIR="$tmp/Applications" \
  CODEX_HOME="$tmp/codex & home" CLAUDE_CONFIG_DIR="$tmp/claude home" "$command_path" --install > "$tmp/install.log" 2>&1 \
  || { cat "$tmp/install.log"; fail_test 'isolated install'; }
bundle="$tmp/Applications/Agent Control Center.app"
[[ -x "$bundle/Contents/MacOS/AgentControlCenter" ]] || fail_test 'binary missing'
[[ -f "$bundle/Contents/Resources/Octicons-LICENSE" ]] || fail_test 'Octicons license missing'
codesign --verify --deep --strict "$bundle"
python3 "$app_dir/install_support.py" verify "$app_dir" "$bundle"
plist="$tmp/home/Library/LaunchAgents/local.agent-control-center.plist"
assert_contains "$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:CODEX_HOME' "$plist")" 'codex & home'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$plist")" != *'--open'* ]] || fail_test 'login opens a window'
cp "$bundle/Contents/MacOS/AgentControlCenter" "$tmp/compiled"
export AGENT_TEST_COMPILED="$tmp/compiled"
printf '%s\n' '#!/bin/sh' 'while test "$#" -gt 0; do' \
  'if test "$1" = -o; then cp "$AGENT_TEST_COMPILED" "$2"; exit 0; fi' 'shift' 'done' 'exit 1' > "$tmp/bin/swiftc"
chmod +x "$tmp/bin/swiftc"
mkdir -p "$tmp/Applications/Codex Sessions.app/Contents"
printf '%s\n' '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.codex-sessions</string></dict></plist>' \
  > "$tmp/Applications/Codex Sessions.app/Contents/Info.plist"
printf 'previous browser\n' > "$tmp/Applications/Codex Sessions.app/sentinel"
status=0
env PATH="$tmp/bin:$PATH" HOME="$tmp/home" TMPDIR="$tmp/build" AGENT_CONTROL_APP_DIR="$tmp/Applications" AGENT_TEST_FAIL_START=1 \
  "$command_path" --install > "$tmp/rollback.log" 2>&1 || status=$?
[[ "$status" != 0 ]] || fail_test 'failed startup should fail installation'
[[ -f "$tmp/Applications/Codex Sessions.app/sentinel" ]] || fail_test 'rollback lost retired app'
cmp "$tmp/compiled" "$bundle/Contents/MacOS/AgentControlCenter" || fail_test 'rollback lost previous binary'
assert_contains "$(cat "$tmp/rollback.log")" 'restoring previous apps'
env PATH="$tmp/bin:$PATH" HOME="$tmp/home" TMPDIR="$tmp/build" AGENT_CONTROL_APP_DIR="$tmp/Applications" \
  "$command_path" --install > "$tmp/migrate.log" 2>&1 || { cat "$tmp/migrate.log"; fail_test 'migration'; }
[[ ! -e "$tmp/Applications/Codex Sessions.app" ]] || fail_test 'retired bundle remains after migration'
[[ -f "$AGENT_TEST_STATE" && ! -f "$AGENT_TEST_STATE.removing" ]] || fail_test 'migration left the login agent stopped'
[[ -z "$(find "$tmp/build" -mindepth 1 -maxdepth 1 -name 'agent-control-center.*' -print -quit)" ]] || fail_test 'temporary rollback/build bundle remains'
env PATH="$tmp/bin:$PATH" HOME="$tmp/home" TMPDIR="$tmp/build" AGENT_CONTROL_APP_DIR="$tmp/Applications" \
  "$command_path" --install > "$tmp/reinstall.log" 2>&1 || { cat "$tmp/reinstall.log"; fail_test 'reinstall'; }
[[ -f "$AGENT_TEST_STATE" && ! -f "$AGENT_TEST_STATE.removing" ]] || fail_test 'reinstall left the login agent stopped'
printf 'PASS: unified build, signatures, source manifest, quiet login, migration, rollback, and restart\n'
