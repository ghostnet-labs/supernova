#!/usr/bin/env bash
# setup-test: Agent Control Center project memory
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
source "$repo_dir/tests/lib/assert.sh"
if [[ "$(uname -s)" != Darwin ]] || ! command -v swiftc >/dev/null; then
  printf '%s\n' 'Skipping native project memory checks (macOS Swift required).'
  exit 0
fi
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$scratch/clang-cache}"
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-$scratch/swift-cache}"
swiftc -O -parse-as-library -swift-version 5 -lsqlite3 \
  "$repo_dir/apps/agent-control-center/AgentDatabase.swift" \
  "$repo_dir/apps/agent-control-center/ProjectMemoryModels.swift" \
  "$repo_dir/apps/agent-control-center/ProjectMemoryStore.swift" \
  "$repo_dir/apps/agent-control-center/MemoryIndex.swift" \
  "$repo_dir/apps/agent-control-center/MemoryImport.swift" \
  "$repo_dir/tests/dotfiles/fixtures/agent_project_memory.swift" -o "$scratch/check-agent-project-memory"
"$scratch/check-agent-project-memory" "$scratch"
