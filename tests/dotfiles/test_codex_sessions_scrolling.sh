#!/usr/bin/env bash
# setup-test: Agent Control Center transcript scrolling
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ "$(uname -s)" != Darwin ]] || ! command -v swiftc >/dev/null 2>&1; then
  printf 'SKIP: Agent Control Center scrolling checks require macOS and Swift\n'
  exit 0
fi
scratch="$(mktemp -d "${TMPDIR:-/tmp}/codex-scrolling-tests.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
swiftc -swift-version 5 -o "$scratch/check-scrolling" \
  "$repo_root/apps/lib/agents/TranscriptScrolling.swift" \
  "$repo_root/tests/dotfiles/fixtures/codex_sessions_scrolling.swift"
"$scratch/check-scrolling"
# Conversations, live or closed, open at their latest message in the real view.
app="$repo_root/apps/lib/agents"
sources=()
for source in "$app"/*.swift; do [[ "$source" == */Main.swift ]] || sources+=("$source"); done
swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" -o "$scratch/check-position" "${sources[@]}" \
  "$repo_root/apps/lib/octicons/Octicons.swift" "$repo_root/apps/lib/BranchRef.swift" "$repo_root/apps/lib/GhosttyLaunch.swift" "$repo_root/apps/lib/GitStatus.swift" "$repo_root/apps/lib/TextLine.swift" \
  "$repo_root/apps/lib/SessionPresentation.swift" "$repo_root/apps/lib/HardwareReport.swift" "$repo_root/tests/dotfiles/fixtures/agent_control_transcript_position.swift"
"$scratch/check-position" "$scratch"
