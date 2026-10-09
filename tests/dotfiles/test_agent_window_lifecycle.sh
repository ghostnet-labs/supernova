#!/usr/bin/env bash
# setup-test: Agent app window lifecycle
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$root/tests/lib/assert.sh"
if [[ "$(uname -s)" != Darwin ]] || ! command -v swiftc >/dev/null 2>&1; then
  printf 'SKIP: Agent window lifecycle checks require macOS and Swift\n'
  exit 0
fi
scratch="$(mktemp -d "${TMPDIR:-/tmp}/agent-window-tests.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$scratch/module-cache}"
swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  "$root/apps/lib/agents/"*.swift "$root/apps/lib/"{BranchRef,GitStatus,GhosttyLaunch,SessionPresentation,TextLine}.swift \
  "$root/apps/lib/octicons/Octicons.swift" "$root/tests/dotfiles/fixtures/agent_window_lifecycle.swift" -o "$scratch/check-agent-window-lifecycle"
for mode in early-open workspace legacy; do
  "$scratch/check-agent-window-lifecycle" "$mode" > "$scratch/$mode.log" 2>&1 || { cat "$scratch/$mode.log"; exit 1; }
  cat "$scratch/$mode.log"
  assert_contains "$(cat "$scratch/$mode.log")" "PASS: $mode window lifecycle"
done
