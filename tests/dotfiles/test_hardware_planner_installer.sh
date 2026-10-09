#!/usr/bin/env bash
# setup-test: Hardware Planner installer
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$root/tests/lib/assert.sh"
[[ "$(uname -s)" == Darwin ]] || { printf 'SKIP: Hardware Planner installer requires macOS\n'; exit 0; }
temporary="$(mktemp -d "${TMPDIR:-/tmp}/hardware-installer-tests.XXXXXX")"
trap 'rm -rf -- "$temporary"' EXIT
mkdir -p "$temporary/bin" "$temporary/build" "$temporary/data"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$temporary/cache}"
export HARDWARE_PLANNER_APP_DIR="$temporary/Applications"
export HARDWARE_PLANNER_DATA_DIR="$temporary/data"
export TMPDIR="$temporary/build"
cmd="$root/dotfiles/.bin/hardware-planner"
source_dir="$root/apps/hardware-planner"
bundle="$HARDWARE_PLANNER_APP_DIR/Hardware Planner.app"
if [[ -n "${HARDWARE_PLANNER_TEST_BUNDLE:-}" ]]; then
  mkdir -p "$HARDWARE_PLANNER_APP_DIR"
  cp -R "$HARDWARE_PLANNER_TEST_BUNDLE" "$bundle"
else
  "$cmd" --build "$bundle"
fi
codesign --verify --deep --strict "$bundle"
python3 "$source_dir/install_support.py" verify "$source_dir" "$bundle"
cp "$bundle/Contents/MacOS/HardwarePlanner" "$temporary/compiled"
export HARDWARE_TEST_COMPILED="$temporary/compiled"
printf '%s\n' '#!/bin/sh' 'while test "$#" -gt 0; do' \
  'if test "$1" = -o; then cp "$HARDWARE_TEST_COMPILED" "$2"; exit 0; fi' 'shift' 'done' 'exit 1' > "$temporary/bin/swiftc"
printf '%s\n' '#!/bin/sh' 'test "${HARDWARE_TEST_FAIL_OPEN:-0}" != 1' > "$temporary/bin/open"
printf '%s\n' '#!/bin/sh' 'exit 1' > "$temporary/bin/pkill"
chmod +x "$temporary/bin/"*
export PATH="$temporary/bin:$PATH"
printf 'project data\n' > "$temporary/data/sentinel"
"$cmd" --install > "$temporary/install.log" 2>&1 || { cat "$temporary/install.log"; fail_test 'isolated install'; }
assert_contains "$("$cmd" --status)" 'sources: current'
assert_contains "$("$cmd" --status)" 'signature: valid'
status=0
HARDWARE_TEST_FAIL_OPEN=1 "$cmd" --install > "$temporary/rollback.log" 2>&1 || status=$?
[[ "$status" != 0 ]] || fail_test 'open failure did not fail install'
assert_contains "$(cat "$temporary/rollback.log")" 'restoring the previous bundle'
cmp "$temporary/compiled" "$bundle/Contents/MacOS/HardwarePlanner" || fail_test 'rollback did not preserve previous executable'
codesign --verify --deep --strict "$bundle"
"$cmd" --uninstall > "$temporary/uninstall.log"
[[ ! -e "$bundle" ]] || fail_test 'uninstall left the bundle'
[[ -f "$temporary/data/sentinel" ]] || fail_test 'uninstall removed project data'
assert_contains "$("$cmd" --status)" 'not installed'
status=0
"$cmd" --open > "$temporary/missing.log" 2>&1 || status=$?
[[ "$status" != 0 ]] || fail_test 'open nonexistent bundle passed'
assert_contains "$(cat "$temporary/missing.log")" 'not installed'
printf 'PASS: Hardware Planner isolated build, signature, manifest, install rollback and data-preserving uninstall\n'
