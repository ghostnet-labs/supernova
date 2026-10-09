#!/usr/bin/env bash
# setup-test: Shared swiftc cache
# The cache in tests/lib/swiftc-cache replays a compile from another checkout of
# the same sources, compiles again when anything that matters changes, never
# keeps a failure, and stays under its size limit.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$root/tests/lib/assert.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/swiftc-cache-test.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

# A fake compiler that logs each real compile and "builds" by concatenating.
mkdir -p "$tmp/bin" "$tmp/a" "$tmp/b"
printf '%s\n' '#!/usr/bin/env bash' \
  '[[ "$1" == --version ]] && { echo "fake swiftc ${FAKE_VERSION:-1}"; exit 0; }' \
  'echo compiled >>"$FAKE_LOG"; echo "warning: from the compiler" >&2' \
  'out=""; prev=""; for arg in "$@"; do' \
  '  [[ "$prev" == -o ]] && out="$arg"; [[ "$arg" == *.swift ]] && { cat "$arg" || exit 1; } >>"$FAKE_OUT"; prev="$arg"' \
  'done' \
  '[[ "${FAKE_FAIL:-0}" == 1 ]] && exit 7' \
  '[[ -z "$out" ]] || cp "$FAKE_OUT" "$out"' >"$tmp/bin/swiftc"
chmod +x "$tmp/bin/swiftc"
export PATH="$root/tests/lib/swiftc-cache:$tmp/bin:$PATH" SDKROOT=/fake/sdk
export SETUP_SWIFTC_CACHE="$tmp/cache" FAKE_LOG="$tmp/log"
printf 'let a = 1\n' >"$tmp/a/App.swift"
printf 'let a = 1\n' >"$tmp/b/App.swift"

compile() {
  local dir="$1"
  shift
  export FAKE_OUT="$dir/raw"
  : >"$FAKE_OUT"
  swiftc -O "$@" "$dir/App.swift" -o "$dir/app" 2>"$dir/stderr"
}
compiles() { wc -l <"$FAKE_LOG" | tr -d ' '; }

compile "$tmp/a"
assert_equals "$(compiles)" 1
compile "$tmp/b"
assert_equals "$(compiles)" 1
assert_equals "$(cat "$tmp/b/app")" 'let a = 1'
assert_contains "$(cat "$tmp/b/stderr")" 'warning: from the compiler'

# Changed sources, flags, or compiler each compile again.
printf 'let a = 2\n' >"$tmp/b/App.swift"
compile "$tmp/b"
assert_equals "$(compiles)" 2
assert_equals "$(cat "$tmp/b/app")" 'let a = 2'
compile "$tmp/b" -wmo
assert_equals "$(compiles)" 3
FAKE_VERSION=2 compile "$tmp/b"
assert_equals "$(compiles)" 4

# Failures are not cached, and compiles without -o or -typecheck pass through.
status=0
FAKE_FAIL=1 compile "$tmp/b" -Onone || status=$?
assert_equals "$status" 7
FAKE_FAIL=1 compile "$tmp/b" -Onone || true
assert_equals "$(compiles)" 6
FAKE_OUT="$tmp/raw" swiftc -typecheck "$tmp/a/App.swift" 2>/dev/null
FAKE_OUT="$tmp/raw" swiftc -typecheck "$tmp/a/App.swift" 2>/dev/null
assert_equals "$(compiles)" 7
FAKE_OUT="$tmp/raw" swiftc -emit-module "$tmp/a/App.swift" 2>/dev/null
FAKE_OUT="$tmp/raw" swiftc -emit-module "$tmp/a/App.swift" 2>/dev/null
assert_equals "$(compiles)" 9

# Without SETUP_SWIFTC_CACHE the wrapper only runs swiftc.
SETUP_SWIFTC_CACHE='' compile "$tmp/a"
assert_equals "$(compiles)" 10

# Over the limit, the least recently used entries go first.
touch -t 202001010000 "$tmp/cache/entries/"*
compile "$tmp/a"
head -c 3000000 /dev/zero >"$tmp/a/App.swift"
SETUP_SWIFTC_CACHE_MB=1 compile "$tmp/a"
entries=("$tmp/cache/entries/"*)
assert_equals "${#entries[@]}" 1
[[ "$(wc -c <"${entries[0]}/output" | tr -d ' ')" == 3000000 ]] || fail_test 'the newest entry was pruned'
[[ -z "$(find "$tmp/cache/entries" -name '.new.*')" ]] || fail_test 'a staging directory was left behind'
printf 'PASS: Shared swiftc cache\n'
