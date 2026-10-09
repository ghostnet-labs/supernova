#!/usr/bin/env bash
# setup-test: Agent Control Center store and provider lifecycle
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/tests/lib/assert.sh"
if [[ "$(uname -s)" != Darwin ]] || ! command -v swiftc >/dev/null 2>&1; then
  printf 'SKIP: Native store checks require macOS and Swift\n'
  exit 0
fi
tmp="$(mktemp -d "${TMPDIR:-/tmp}/agent-store-tests.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$tmp/clang-cache}"
app="$repo_root/apps/lib/agents"
swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" -o "$tmp/check" \
  "$app/Models.swift" "$app/Projects.swift" "$app/Timeline.swift" "$app/MarkdownBlocks.swift" \
  "$app/Data.swift" "$app/ClaudeData.swift" "$app/Store.swift" "$app/Providers.swift" \
  "$repo_root/apps/lib/GhosttyLaunch.swift" "$repo_root/apps/lib/GitStatus.swift" "$repo_root/apps/lib/TextLine.swift" "$repo_root/tests/dotfiles/fixtures/agent_control_store.swift"
CODEX_HOME="$tmp/codex" CLAUDE_CONFIG_DIR="$tmp/claude" "$tmp/check" "$tmp"
