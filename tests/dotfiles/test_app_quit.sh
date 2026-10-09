#!/usr/bin/env bash
# setup-test: App installer quit guard
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$root/tests/lib/assert.sh"
source "$root/apps/lib/quit-app.sh"

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
export QUIT_LOG="$tmp/log" QUIT_STATE="$tmp/state"
export QUIT_TARGET='/tmp/Applications [test]+/Some App.app/Contents/MacOS/SomeApp'
export QUIT_OTHER='/tmp/Applications ttt/Some AppXapp/Contents/MacOS/SomeApp-extra'

# Check the actual matching expression, with no real signals or delays.
pkill() {
  printf '%s\n' "$2" >"$QUIT_LOG"
  printf '%s\n' "$QUIT_TARGET" | grep -Eq -- "$2" || return 2
  if printf '%s\n' "$QUIT_OTHER" | grep -Eq -- "$2"; then return 2; fi
  return "${QUIT_PKILL_STATUS:-0}"
}
pgrep() { return "${QUIT_PGREP_STATUS:-1}"; }
sleep() { printf 'wait\n' >>"$QUIT_STATE"; }

quit_app "$QUIT_TARGET" || fail_test 'literal install path did not match'
QUIT_PKILL_STATUS=1 quit_app "$QUIT_TARGET" || fail_test 'absent app should succeed'
status=0
QUIT_PKILL_STATUS=2 quit_app "$QUIT_TARGET" >/dev/null 2>&1 || status=$?
assert_equals "$status" 2
status=0
output="$(QUIT_PGREP_STATUS=0 quit_app "$QUIT_TARGET" 2>&1)" || status=$?
assert_equals "$status" 1
assert_contains "$output" 'keeping the installed bundle'
assert_equals "$(wc -l <"$QUIT_STATE" | tr -d ' ')" 50

if [[ "$(uname -s)" == Darwin ]]; then
  # Exercise all three real installers: a failed quit must leave the old bundle intact.
  mkdir -p "$tmp/bin" "$tmp/apps"
  printf '%s\n' '#!/usr/bin/env bash
while (($#)); do
  if [[ "$1" == -o ]]; then touch "$2"; exit 0; fi
  shift
done
exit 1' >"$tmp/bin/swiftc"
  for stub in codesign pkill pgrep sleep; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$tmp/bin/$stub"
  done
  printf '#!/usr/bin/env bash\necho opened >>"$QUIT_LOG"\n' >"$tmp/bin/open"
  chmod +x "$tmp/bin/"*
  for item in 'worktree-manager|Worktree Manager|WORKTREE_MANAGER_APP_DIR' \
              'setup-doctor|Setup Doctor|SETUP_DOCTOR_APP_DIR'; do
    IFS='|' read -r installer app variable <<<"$item"
    mkdir -p "$tmp/apps/$app.app"
    printf 'old build\n' >"$tmp/apps/$app.app/sentinel"
    : >"$QUIT_LOG"
    status=0
    env PATH="$tmp/bin:$PATH" "$variable=$tmp/apps" "$root/dotfiles/.bin/$installer" --install \
      >"$tmp/installer.log" 2>&1 || status=$?
    assert_equals "$status" 1
    assert_contains "$(cat "$tmp/installer.log")" 'keeping the installed bundle'
    [[ -f "$tmp/apps/$app.app/sentinel" ]] || fail_test "$installer replaced a running bundle"
    [[ ! -s "$QUIT_LOG" ]] || fail_test "$installer reopened the old copy"
    status=0
    env PATH="$tmp/bin:$PATH" "$variable=$tmp/apps" "$root/dotfiles/.bin/$installer" --uninstall \
      >"$tmp/uninstall.log" 2>&1 || status=$?
    assert_equals "$status" 1
    [[ -f "$tmp/apps/$app.app/sentinel" ]] || fail_test "$installer removed a running bundle"
  done
fi
printf 'PASS: App installer quit guard\n'
