#!/usr/bin/env bash
# setup-test: Agent Control Center project grouping
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ "$(uname -s)" != Darwin ]] || ! command -v swiftc >/dev/null 2>&1; then
  printf 'SKIP: Agent Control Center project checks require macOS and Swift\n'
  exit 0
fi
scratch="$(mktemp -d "${TMPDIR:-/tmp}/codex-project-tests.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
swiftc -swift-version 5 -o "$scratch/check-projects" \
  "$repo_root/apps/lib/agents/Models.swift" \
  "$repo_root/apps/lib/TextLine.swift" \
  "$repo_root/apps/lib/agents/Projects.swift" \
  "$repo_root/tests/dotfiles/fixtures/codex_sessions_projects.swift"
"$scratch/check-projects" "$scratch"
