#!/usr/bin/env bash
# setup-test: Agent Workspace
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$root/tests/lib/assert.sh"
command_path="$root/dotfiles/.bin/agent-workspace"
assert_contains "$("$command_path" --help)" 'AGENT_WORKSPACE_ROOT'
status=0
"$command_path" --invalid >/dev/null 2>&1 || status=$?
assert_equals 2 "$status" 'unknown action'
if [[ "$(uname -s)" != Darwin ]] || ! command -v swiftc >/dev/null 2>&1; then
  printf 'SKIP: Agent Workspace requires macOS and Swift\n'
  exit 0
fi
scratch="$(mktemp -d "${TMPDIR:-/tmp}/agent-workspace-tests.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$scratch/module-cache}"
mkdir -p "$scratch/dev/repo/nested" "$scratch/external" "$scratch/bin" "$scratch/home" "$scratch/build"
for repo in "$scratch/dev/repo" "$scratch/external"; do
  git -c init.defaultBranch=main init -q "$repo"
  printf 'fixture\n' > "$repo/tracked"
  git -C "$repo" add tracked
  git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.invalid -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -m 'test: fixture repository'
done
git -C "$scratch/dev/repo" worktree add -b feature "$scratch/dev/linked"
ln -s "$scratch/dev/repo" "$scratch/alias"
swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  "$root/apps/agent-workspace/Workspace.swift" "$root/apps/agent-workspace/WorkspaceViews.swift" "$root/apps/agent-workspace/CreateWorktree.swift" \
  "$root/apps/lib/GhosttyLaunch.swift" "$root/apps/lib/agents/"*.swift "$root/apps/lib/worktrees/"*.swift \
  "$root/apps/lib/"{BranchRef,GitStatus,SessionPresentation,TextLine}.swift "$root/apps/lib/octicons/Octicons.swift" \
  "$root/tests/dotfiles/fixtures/agent_workspace.swift" -o "$scratch/check-agent-workspace"
args=()
if [[ -n "${AGENT_WORKSPACE_TEST_ARTIFACTS:-}" ]]; then args+=(--render); fi
"$scratch/check-agent-workspace" "$scratch" ${args[@]+"${args[@]}"}
if [[ -n "${AGENT_WORKSPACE_TEST_ARTIFACTS:-}" ]]; then
  mkdir -p "$AGENT_WORKSPACE_TEST_ARTIFACTS"
  cp "$scratch/"*.png "$AGENT_WORKSPACE_TEST_ARTIFACTS/"
fi

# Exercise the actual installer in isolation. Only launchctl, application opening, and
# process discovery are stubbed; Swift compilation, manifests and signatures are real.
python3 -c 'import pathlib,shlex,sys; s=pathlib.Path(sys.argv[1]).read_text(); s="\n".join("readonly source_dir="+shlex.quote(sys.argv[3]) if line.startswith("readonly source_dir=") else line for line in s.splitlines()); s=s.replace("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", "/usr/bin/true"); pathlib.Path(sys.argv[2]).write_text(s+"\n")' "$command_path" "$scratch/launcher" "$root/apps/agent-workspace"
# Security.framework and codesign must use the real account's keychain preferences.
# Keep the signing artifacts isolated while removing the installer's fake HOME for this call.
python3 -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); p.write_text(p.read_text().replace("python3 \"$source_dir/sign_app.py\" \"$bundle\"", "env -u HOME python3 \"$source_dir/sign_app.py\" \"$bundle\" --state-dir \"$WORKSPACE_TEST_SIGNING\""))' "$scratch/launcher"
export WORKSPACE_TEST_SIGNING="$scratch/home/Library/Application Support/Agent Workspace/Signing"
chmod +x "$scratch/launcher"
export WORKSPACE_TEST_STATE="$scratch/launch-state"
# Like launchd, bootout returns before the service is removed; it stays loaded for two more prints.
printf '%s\n' '#!/bin/sh' 'pending="$WORKSPACE_TEST_STATE.removing"' 'case "$1" in' \
  'print) if test -f "$pending"; then left=$(($(cat "$pending") - 1))' \
  '  if test "$left" -le 0; then rm -f "$pending" "$WORKSPACE_TEST_STATE"; exit 1; fi; echo "$left" > "$pending"; fi' \
  '  test -f "$WORKSPACE_TEST_STATE" || exit 1; echo "state = running" ;;' \
  'bootout) test ! -f "$WORKSPACE_TEST_STATE" || echo 3 > "$pending" ;;' \
  'bootstrap|kickstart) test "${WORKSPACE_TEST_FAIL_START:-0}" != 1 || exit 1; test -f "$pending" || touch "$WORKSPACE_TEST_STATE" ;;' \
  '*) exit 2 ;;' 'esac' > "$scratch/bin/launchctl"
printf '%s\n' '#!/bin/sh' 'exit 1' > "$scratch/bin/pkill"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$scratch/bin/open"
chmod +x "$scratch/bin/"*
run() {
  env PATH="$scratch/bin:$PATH" HOME="$scratch/home" TMPDIR="$scratch/build" AGENT_WORKSPACE_APP_DIR="$scratch/Applications" \
    AGENT_WORKSPACE_ROOT="$scratch/dev" CODEX_HOME="$scratch/codex & home" CLAUDE_CONFIG_DIR="$scratch/claude home" "$scratch/launcher" "$@"
}
for app in 'Agent Control Center' 'Worktree Manager'; do
  mkdir -p "$scratch/Applications/$app.app"
  printf 'existing app\n' > "$scratch/Applications/$app.app/sentinel"
done
security list-keychains -d user > "$scratch/keychains-before"
security default-keychain -d user > "$scratch/default-keychain-before"
run --install > "$scratch/install.log" 2>&1 || { cat "$scratch/install.log"; fail_test 'isolated workspace install'; }
bundle="$scratch/Applications/Agent Workspace.app"
codesign --verify --deep --strict "$bundle"
requirement="$(codesign -d -r- "$bundle" 2>/dev/null)"
assert_contains "$requirement" 'certificate leaf'
assert_not_contains "$requirement" 'cdhash'
signing="$scratch/home/Library/Application Support/Agent Workspace/Signing"
sign_variant() { python3 "$root/apps/agent-workspace/sign_app.py" "$1" --state-dir "$2"; }
cp -R "$bundle" "$scratch/updated.app"
printf 'changed build\n' > "$scratch/updated.app/Contents/Resources/BuildVariant"
sign_variant "$scratch/updated.app" "$signing"
codesign --verify --deep --strict -R "=${requirement#designated => }" "$scratch/updated.app"
assert_equals "$requirement" "$(codesign -d -r- "$scratch/updated.app" 2>/dev/null)" 'identity survives a changed build'
sign_variant "$scratch/updated.app" "$scratch/unrelated-signing"
if codesign --verify -R "=${requirement#designated => }" "$scratch/updated.app" >/dev/null 2>&1; then
  fail_test 'another signing key must not satisfy the saved app identity'
fi
if sign_variant "$scratch/missing.app" "$signing" > "$scratch/signing-failure.log" 2>&1; then
  fail_test 'signing a missing app should fail'
fi
security list-keychains -d user > "$scratch/keychains-after"
security default-keychain -d user > "$scratch/default-keychain-after"
# Another test run may be signing right now; only this run's keychains must be gone.
for list in keychains-before keychains-after; do
  grep -v '/keychain-[^/]*/build.keychain-db' "$scratch/$list" > "$scratch/$list.others" || true
done
cmp "$scratch/keychains-before.others" "$scratch/keychains-after.others" || fail_test 'signing changed keychain search list'
assert_not_contains "$(cat "$scratch/keychains-after")" "$scratch/"
cmp "$scratch/default-keychain-before" "$scratch/default-keychain-after" || fail_test 'signing changed default keychain'
[[ "$(stat -f '%Lp' "$signing/identity/identity.p12")" == 600 ]] || fail_test 'signing identity permissions'
printf 'PASS: persistent signing, changed builds, unrelated-key rejection, and keychain cleanup\n'
python3 "$root/apps/agent-control-center/install_support.py" verify "$root/apps/agent-workspace" "$bundle"
assert_contains "$(run --status)" 'running: yes'
plist="$scratch/home/Library/LaunchAgents/local.agent-workspace.plist"
assert_contains "$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:CODEX_HOME' "$plist")" 'codex & home'
assert_contains "$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:AGENT_WORKSPACE_ROOT' "$plist")" "$scratch/dev"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$plist")" != *'--open'* ]] || fail_test 'login opens window'
assert_contains "$(cat "$bundle/Contents/Resources/SourceHashes.json")" 'apps/lib/agents/Store.swift'
assert_contains "$(cat "$bundle/Contents/Resources/SourceHashes.json")" 'apps/lib/worktrees/Worktrees.swift'
cp "$bundle/Contents/MacOS/AgentWorkspace" "$scratch/compiled"
cp "$plist" "$scratch/previous.plist"
export WORKSPACE_TEST_COMPILED="$scratch/compiled"
printf '%s\n' '#!/bin/sh' 'while test "$#" -gt 0; do' \
  'if test "$1" = -o; then cp "$WORKSPACE_TEST_COMPILED" "$2"; exit 0; fi' 'shift' 'done' 'exit 1' > "$scratch/bin/swiftc"
chmod +x "$scratch/bin/swiftc"
status=0
WORKSPACE_TEST_FAIL_START=1 run --install > "$scratch/rollback.log" 2>&1 || status=$?
[[ "$status" != 0 ]] || fail_test 'failed start should fail installation'
cmp "$scratch/compiled" "$bundle/Contents/MacOS/AgentWorkspace" || fail_test 'rollback changed previous binary'
cmp "$scratch/previous.plist" "$plist" || fail_test 'rollback changed login configuration'
run --start
run --install > "$scratch/reinstall.log" 2>&1 || { cat "$scratch/reinstall.log"; fail_test 'reinstall'; }
[[ -f "$WORKSPACE_TEST_STATE" && ! -f "$WORKSPACE_TEST_STATE.removing" ]] || fail_test 'reinstall left the login agent stopped'
run --open
run --stop
assert_contains "$(run --status)" 'running: no'
run --uninstall
[[ ! -e "$bundle" && ! -e "$plist" ]] || fail_test 'uninstall left app or login agent'
for app in 'Agent Control Center' 'Worktree Manager'; do
  assert_equals 'existing app' "$(cat "$scratch/Applications/$app.app/sentinel")" 'existing app preserved'
done
printf 'PASS: Agent Workspace build, install, rollback, lifecycle, manifest, and coexistence\n'
