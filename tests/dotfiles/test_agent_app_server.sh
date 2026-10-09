#!/bin/bash
# setup-test: Agent Control Center App Server
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [ "$(uname -s)" != Darwin ]; then
    printf '%s\n' 'SKIP: Swift App Server fixture requires macOS'
    exit 0
fi
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
export CLANG_MODULE_CACHE_PATH="$TEMP_DIR/cache"
swiftc -swift-version 5 -parse-as-library "$ROOT/apps/agent-control-center/AppServerClient.swift" "$ROOT/tests/dotfiles/fixtures/agent_app_server.swift" -o "$TEMP_DIR/test"
cp "$ROOT/tests/dotfiles/fixtures/agent_app_server_blocked.py" "$TEMP_DIR/blocked"
chmod +x "$TEMP_DIR/blocked"
"$TEMP_DIR/test" "$TEMP_DIR/blocked"
