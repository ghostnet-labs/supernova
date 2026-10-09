#!/bin/bash
# setup-test: Agent Control Center managed conversation
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [ "$(uname -s)" != Darwin ]; then
    printf '%s\n' 'SKIP: native conversation fixture requires macOS'
    exit 0
fi
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$TEMP_DIR/cache}"
swiftc -O -swift-version 5 -parse-as-library -lsqlite3 \
    "$ROOT/apps/agent-control-center/AppServerClient.swift" \
    "$ROOT/apps/agent-control-center/AgentDatabase.swift" \
    "$ROOT/apps/agent-control-center/ProjectMemoryModels.swift" \
    "$ROOT/apps/agent-control-center/ManagedConversation.swift" \
    "$ROOT/tests/dotfiles/fixtures/agent_managed_conversation.swift" -o "$TEMP_DIR/test"
"$TEMP_DIR/test" "$TEMP_DIR/state"
