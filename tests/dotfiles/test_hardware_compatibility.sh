#!/usr/bin/env bash
# setup-test: Hardware compatibility and change impact
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/tests/lib/assert.sh"
if [[ "$(uname -s)" != Darwin ]] || ! command -v swiftc >/dev/null 2>&1; then
  printf 'SKIP: Native hardware checks require macOS and Swift\n'
  exit 0
fi
tmp="$(mktemp -d "${TMPDIR:-/tmp}/hardware-compatibility.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$tmp/clang-cache}"
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-$tmp/swift-cache}"
app="$repo_root/apps/hardware-planner"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" -o "$tmp/check-hardware-compatibility" \
  "$app/Models.swift" "$app/ProjectFormat.swift" "$app/CompatibilityEngine.swift" "$app/ChangeImpact.swift" \
  "$repo_root/tests/dotfiles/fixtures/hardware_compatibility.swift"
"$tmp/check-hardware-compatibility"
swiftc -typecheck -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  "$app/Models.swift" "$app/ProjectFormat.swift" "$app/CompatibilityEngine.swift" "$app/ChangeImpact.swift" "$app/CompatibilityView.swift"
