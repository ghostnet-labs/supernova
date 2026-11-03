#!/usr/bin/env bash
# setup-test: Agent conversation syntax highlighting
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ "$(uname -s)" != Darwin ]] || ! command -v swiftc >/dev/null 2>&1; then
  printf 'SKIP: Native syntax highlighting requires macOS and Swift\n'
  exit 0
fi
scratch="$(mktemp -d "${TMPDIR:-/tmp}/agent-syntax-tests.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$scratch/module-cache}"
swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  "$root/apps/lib/agents/Theme.swift" "$root/apps/lib/agents/SyntaxHighlighting.swift" \
  "$root/tests/dotfiles/fixtures/agent_syntax.swift" -o "$scratch/check-agent-syntax"
"$scratch/check-agent-syntax"
