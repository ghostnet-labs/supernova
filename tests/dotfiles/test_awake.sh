#!/usr/bin/env bash
# setup-test: Awake app and installer
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$root/tests/lib/assert.sh"
cmd="$root/dotfiles/.bin/awake"
assert_contains "$("$cmd" --help)" 'Usage:'
status=0
"$cmd" --bogus >/dev/null 2>&1 || status=$?
assert_equals "$status" 2

tmp="$(mktemp -d "${TMPDIR:-/tmp}/awake-test.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/apps/Awake.app"
printf 'old bundle\n' >"$tmp/apps/Awake.app/marker"
export AWAKE_APP_DIR="$tmp/apps" AWAKE_TEST_CALLS="$tmp/calls"
printf '#!/bin/sh\ncase "$1" in -s) echo Darwin ;; -m) echo arm64 ;; esac\n' >"$tmp/bin/uname"
printf '#!/bin/sh\necho 15.0\n' >"$tmp/bin/sw_vers"
printf '#!/bin/sh\ncase "$*" in *--show-sdk-path*) echo /fake/sdk ;; *--show-sdk-version*) echo 15.0 ;; *) exit 42 ;; esac\n' >"$tmp/bin/xcrun"
for tool in open pkill pgrep; do
  printf '#!/bin/sh\necho "%s" >>"$AWAKE_TEST_CALLS"\nexit 1\n' "$tool" >"$tmp/bin/$tool"
done
chmod +x "$tmp/bin/"*
assert_contains "$(PATH="$tmp/bin:$PATH" "$cmd" --status)" 'app: installed'
status=0
PATH="$tmp/bin:$PATH" "$cmd" --install >/dev/null 2>&1 || status=$?
assert_equals "$status" 42
assert_equals "$(cat "$tmp/apps/Awake.app/marker")" 'old bundle'
[[ ! -e "$tmp/calls" ]] || fail_test 'failed build stopped or opened the installed app'
printf '#!/bin/sh\necho 14.0\n' >"$tmp/bin/sw_vers"
status=0
PATH="$tmp/bin:$PATH" "$cmd" --install >/dev/null 2>&1 || status=$?
assert_equals "$status" 1

if [[ "$(uname -s)" == Darwin ]]; then
  plutil -lint "$root/apps/awake/Info.plist" >/dev/null
  sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
  if [[ "${sdk_version%%.*}" -ge 15 ]]; then
    xcrun swiftc -typecheck -parse-as-library -swift-version 5 -target arm64-apple-macosx15.0 \
      -sdk "$(xcrun --sdk macosx --show-sdk-path)" "$root/apps/awake/Sources/Awake.swift"
    AWAKE_BUILD_DIR="$tmp/compiled" bash "$root/apps/awake/build.sh" >/dev/null
  else
    printf 'SKIP: Awake Swift build requires macOS SDK 15 (found %s)\n' "$sdk_version"
  fi
fi
printf 'PASS: Awake app and installer\n'
