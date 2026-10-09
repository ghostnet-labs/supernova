#!/usr/bin/env bash
# setup-test: Agent Control Center task coordination
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
source "$repo_dir/tests/lib/assert.sh"
if [[ "$(uname -s)" != Darwin ]] || ! command -v swiftc >/dev/null; then
  printf '%s\n' 'Skipping native task checks (macOS Swift required).'
  exit 0
fi
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$scratch/clang-cache}"
export SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-$scratch/swift-cache}"
git -c init.defaultBranch=main init "$scratch/repository"
printf '%s\n' 'committed baseline' > "$scratch/repository/README.md"
git -C "$scratch/repository" add README.md
git -C "$scratch/repository" -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.name=Fixture -c user.email=fixture@example.invalid commit -m 'test: disposable worktree baseline'
printf '%s\n' 'uncommitted user edit' >> "$scratch/repository/README.md"
swiftc -O -parse-as-library -swift-version 5 -lsqlite3 \
  "$repo_dir/apps/agent-control-center/AgentDatabase.swift" \
  "$repo_dir/apps/agent-control-center/ProjectMemoryModels.swift" \
  "$repo_dir/apps/agent-control-center/ProjectMemoryStore.swift" \
  "$repo_dir/apps/agent-control-center/AppServerClient.swift" \
  "$repo_dir/apps/agent-control-center/TaskStore.swift" \
  "$repo_dir/apps/agent-control-center/TaskWorktrees.swift" \
  "$repo_dir/apps/agent-control-center/Coordinator.swift" \
  "$repo_dir/tests/dotfiles/fixtures/agent_task_coordinator.swift" -o "$scratch/check"
"$scratch/check" "$scratch" "$scratch/repository"
