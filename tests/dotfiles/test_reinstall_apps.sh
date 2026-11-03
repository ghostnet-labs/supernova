#!/usr/bin/env bash
# setup-test: Reinstall apps

set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$root/tests/lib/assert.sh"
cmd="$root/dotfiles/.bin/reinstall-apps"

assert_contains "$("$cmd" --help)" "Usage:"

# reinstall-apps relies on every installer replacing a running copy: launch
# agent apps stop their agent, the others quit the app before opening it.
for plist in "$root"/apps/*/Info.plist; do
  name="${plist%/Info.plist}"
  name="${name##*/}"
  installer="$root/dotfiles/.bin/$name-app"
  [[ -x "$installer" ]] || installer="$root/dotfiles/.bin/$name"
  [[ -x "$installer" ]] || fail_test "no installer for apps/$name"
  grep -qE 'stop_agent$|quit_app "\$app_path/Contents/MacOS/\$executable"' "$installer" ||
    fail_test "$name --install does not stop the running app"
done

if [[ "$(uname -s)" != Darwin ]]; then
  printf 'PASS: Reinstall apps (macOS run skipped)\n'
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/dotfiles/.bin" "$tmp/apps/alpha" "$tmp/apps/beta" "$tmp/apps/gamma" "$tmp/apps/plugin"
cp "$cmd" "$tmp/dotfiles/.bin/reinstall-apps"
touch "$tmp/apps/alpha/Info.plist" "$tmp/apps/beta/Info.plist" "$tmp/apps/gamma/Info.plist" "$tmp/apps/plugin/Cargo.toml"
export CALLS="$tmp/calls"
for stub in alpha beta beta-app; do
  printf '#!/usr/bin/env bash\necho "%s $*" >>"$CALLS"\n' "$stub" >"$tmp/dotfiles/.bin/$stub"
done
printf '#!/usr/bin/env bash\necho "error: gamma build broke"\nexit 1\n' >"$tmp/dotfiles/.bin/gamma"
chmod +x "$tmp/dotfiles/.bin/"*
run="$tmp/dotfiles/.bin/reinstall-apps"

status=0
output="$("$run")" || status=$?
assert_equals "$status" 1
assert_contains "$output" "→ Rebuilding 3 apps in parallel"
assert_contains "$output" "✓ alpha ("
assert_contains "$output" "✓ beta ("
assert_contains "$output" "✗ gamma ("
assert_contains "$output" "error: gamma build broke"
assert_contains "$output" "✗ 1 of 3 apps failed: gamma"
assert_not_contains "$output" $'\e['
assert_equals "$(sort "$CALLS")" $'alpha --install\nbeta-app --install'

: >"$CALLS"
output="$("$run" beta alpha)"
assert_contains "$output" "✓ Reinstalled 2 apps in"
assert_equals "$(sort "$CALLS")" $'alpha --install\nbeta-app --install'

status=0
"$run" plugin >/dev/null 2>&1 || status=$?
assert_equals "$status" 2
status=0
"$run" --bogus >/dev/null 2>&1 || status=$?
assert_equals "$status" 2

# --stale rebuilds only apps whose committed source changed since their last
# successful install; outside Git every app counts as stale.
assert_equals "$("$run" --stale --list alpha | cut -f1)" alpha
git -C "$tmp" init -q
git -C "$tmp" add -A
git -C "$tmp" -c user.name=test -c user.email=test@example.com commit -qm "test: fixture"
: >"$CALLS"
output="$("$run" --stale alpha beta)"
assert_contains "$output" "✓ Reinstalled 2 apps in"
assert_equals "$(sort "$CALLS")" $'alpha --install\nbeta-app --install'
[[ -s "$tmp/.local/app-builds/alpha" && -s "$tmp/.local/app-builds/beta" ]] || fail_test "installs were not recorded"

: >"$CALLS"
assert_equals "$("$run" --stale alpha beta)" "All 2 apps match their source"
assert_equals "$("$run" --stale --list alpha beta)" ""
assert_equals "$(cat "$CALLS")" ""

# Only committed source counts: an uncommitted file changes nothing until it lands.
touch "$tmp/apps/alpha/main.swift"
assert_equals "$("$run" --stale --list alpha beta)" ""
git -C "$tmp" add -A
git -C "$tmp" -c user.name=test -c user.email=test@example.com commit -qm "feat: change alpha"
assert_equals "$("$run" --stale --list alpha beta | cut -f1)" "alpha"
mkdir -p "$tmp/apps/lib"
touch "$tmp/apps/lib/shared.swift"
git -C "$tmp" add -A
git -C "$tmp" -c user.name=test -c user.email=test@example.com commit -qm "feat: change shared code"
assert_equals "$("$run" --stale --list alpha beta | cut -f1)" $'alpha\nbeta'

# A failed build records nothing, so the app stays stale.
status=0
"$run" --stale gamma >/dev/null || status=$?
assert_equals "$status" 1
[[ ! -e "$tmp/.local/app-builds/gamma" ]] || fail_test "a failed install was recorded"
assert_equals "$("$run" --stale --list gamma | cut -f1)" "gamma"

# The post-merge hook names stale apps after a pull and never fails it.
mkdir -p "$tmp/.githooks"
cp "$root/.githooks/post-merge" "$tmp/.githooks/post-merge"
output="$("$tmp/.githooks/post-merge" 2>&1)"
assert_contains "$output" "Apps built from older source: alpha beta gamma"
assert_contains "$output" "reinstall-apps --stale"
"$run" alpha beta >/dev/null
rm -f "$tmp/dotfiles/.bin/gamma"
printf '#!/usr/bin/env bash\necho "gamma $*" >>"$CALLS"\n' >"$tmp/dotfiles/.bin/gamma"
chmod +x "$tmp/dotfiles/.bin/gamma"
git -C "$tmp" add -A
git -C "$tmp" -c user.name=test -c user.email=test@example.com commit -qm "fix: repair gamma"
"$run" >/dev/null
assert_equals "$("$tmp/.githooks/post-merge" 2>&1)" ""

printf 'PASS: Reinstall apps\n'
