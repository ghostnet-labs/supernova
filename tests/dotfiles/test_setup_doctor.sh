#!/usr/bin/env bash
# setup-test: Setup Doctor
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cmd="$root/dotfiles/.bin/setup-doctor"
src="$root/apps/setup-doctor/SetupDoctor.swift"
[[ "$("$cmd" --help)" == *"Usage:"* ]]
grep -q 'fix --dry-run' "$root/apps/setup-doctor/README.md"
grep -q 'previous' "$src"
grep -q 'Fix in Ghostty' "$src"
grep -q 'Preview Repair' "$src"
if [[ "$(uname -s)" == Darwin ]]; then
  plutil -lint "$root/apps/setup-doctor/Info.plist" >/dev/null
  tmp="$(mktemp -d)"
  trap 'rm -rf -- "$tmp"' EXIT
  awk '/^@main$/ { exit } { print }' "$src" >"$tmp/SetupDoctor.swift"
  swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
    "$tmp/SetupDoctor.swift" "$root/apps/lib/GhosttyLaunch.swift" "$root/tests/dotfiles/fixtures/setup_doctor.swift" -o "$tmp/check-setup-doctor"
  "$tmp/check-setup-doctor" "$tmp"
fi
printf 'PASS: Setup Doctor\n'
