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

printf 'PASS: Reinstall apps\n'
