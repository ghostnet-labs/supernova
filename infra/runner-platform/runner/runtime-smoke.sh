#!/usr/bin/env bash
# Check the candidate image as UID 1001, with no elevated capabilities or network.
set -euo pipefail
test "$(id -u)" -eq 1001
test "$(uname -m)" = aarch64
test "$RUNNER_TOOL_CACHE" = /opt/hostedtoolcache
test "$AGENT_TOOLSDIRECTORY" = "$RUNNER_TOOL_CACHE"
python_root="$RUNNER_TOOL_CACHE/Python/3.8.20/arm64"
test -f "$python_root.complete"
test -w "$python_root"
test "$(stat -c %u "$python_root")" -eq 1001
test "$(stat -c %u "$python_root.complete")" -eq 1001
test "$GOFLAGS" = -p=1
test "$GOMAXPROCS" = 1
test "$GOMEMLIMIT" = 1400MiB
test "$CODEQL_THREADS" = 1
test "$CODEQL_RAM" = 2048
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
"$python_root/bin/python" -c '
import bz2, ctypes, hashlib, lzma, platform, sqlite3, ssl, sys, uuid, zlib
assert sys.version_info[:3] == (3, 8, 20), sys.version
assert platform.machine() == "aarch64", platform.machine()
assert ssl.OPENSSL_VERSION
assert sqlite3.connect(":memory:").execute("select 1").fetchone() == (1,)
assert zlib.decompress(zlib.compress(b"runtime probe")) == b"runtime probe"
print(sys.version)
'
"$python_root/bin/python3" -m venv "$work/venv"
"$work/venv/bin/python" -c 'import ssl, sys; assert sys.version_info[:3] == (3, 8, 20)'
"$work/venv/bin/python" -m pip --version
# Installing the legacy cache must not replace the image's normal Python tools.
python3 -c 'import rich, textual'
echo 'Python 3.8 toolcache, isolated venv, and pilot runtime defaults passed.'
