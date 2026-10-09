#!/usr/bin/env bash
# setup-test: Hardware Planner
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$root/tests/lib/assert.sh"
cmd="$root/dotfiles/.bin/hardware-planner"
help="$("$cmd" --help)"
for section in Usage Description Options Examples Environment; do assert_contains "$help" "$section:"; done
assert_contains "$help" '--build BUNDLE'
if [[ "$(uname -s)" != Darwin ]]; then printf 'SKIP: native Hardware Planner fixtures require macOS\n'; exit 0; fi
temporary="$(mktemp -d "${TMPDIR:-/tmp}/hardware-planner-tests.XXXXXX")"
trap 'rm -rf -- "$temporary"' EXIT
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$temporary/module-cache}"
src="$root/apps/hardware-planner"
plutil -lint "$src/Info.plist" >/dev/null
swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  "$src/Models.swift" "$src/ProjectFormat.swift" "$src/HardwareStore.swift" \
  "$root/tests/dotfiles/fixtures/hardware_planner.swift" -lsqlite3 -o "$temporary/cases"
"$temporary/cases" "$temporary/data"
swiftc -typecheck -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  "$src"/*.swift "$src/../lib/octicons/Octicons.swift" "$src/../lib/HardwareReport.swift"
printf 'PASS: Hardware Planner help, plist and native UI typecheck\n'
