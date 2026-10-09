#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo "Build on an Apple Silicon Mac (use a native Terminal, not Rosetta)." >&2
    exit 1
fi
sdk="$(xcrun --sdk macosx --show-sdk-path)"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
if [[ "${sdk_version%%.*}" -lt 15 ]]; then
    echo "Install/select Xcode 16 or newer; the selected macOS SDK is $sdk_version." >&2
    exit 1
fi
bundle="${AWAKE_BUILD_DIR:-$PWD/build}/Awake.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
xcrun swiftc -parse-as-library -swift-version 5 -O -target arm64-apple-macosx15.0 -sdk "$sdk" \
    -framework AppKit -framework CoreGraphics -framework IOKit -framework ServiceManagement \
    Sources/Awake.swift -o "$bundle/Contents/MacOS/Awake"
cp Info.plist "$bundle/Contents/Info.plist"
# Ad-hoc signatures default to a cdhash requirement, which voids the Accessibility
# grant on every rebuild; an identifier requirement keeps it across rebuilds.
codesign --force --sign - --identifier local.awake \
    -r='designated => identifier "local.awake"' "$bundle"
codesign --verify --strict "$bundle"
echo "Built: $bundle"
echo "Move Awake.app to /Applications, then launch it. Look for the sun in the menu bar."
