#!/usr/bin/env zsh
# setup-test: Network functions
# Covers netrate, netcheck, and sshcheck in dotfiles/functions/network.zsh.
emulate -L zsh
setopt pipefail
exec </dev/null

repo_dir="${0:A:h:h:h}"
source "$repo_dir/tests/lib/assert.sh"
original_path=("${path[@]}")
for functions_file in "$repo_dir"/dotfiles/functions/*.zsh; do source "$functions_file"; done

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/functions-test.XXXXXX")" || exit 1
# Helpers print resolved paths; macOS TMPDIR is a symlink with a trailing slash.
tmp_root="${tmp_root:A}"
cleanup() {
  rm -rf -- "$tmp_root"
}
trap cleanup EXIT INT TERM

# These helpers ran with a scratch HOME before the split; keep them isolated.
HOME="$tmp_root/home"
mkdir -p "$HOME"

netrate_help="$(netrate --help)" || fail_test "netrate help failed"
[[ "${netrate_help%%$'\n'*}" == "Usage:" ]] || fail_test "netrate help does not begin with Usage"
assert_contains "$netrate_help" $'\n\nDescription:'
assert_contains "$netrate_help" $'\n\nOptions:'
assert_contains "$netrate_help" $'\n\nExamples:'

netrate_counter_file="$tmp_root/netrate-dev"
netrate_next_file="$tmp_root/netrate-dev-next"
netrate_bin="$tmp_root/netrate-bin"
mkdir -p "$netrate_bin"
{
  print -r -- 'Inter-|   Receive                                                |  Transmit'
  print -r -- ' face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed'
  print -r -- '    lo: 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0'
  print -r -- '  eth0: 1024 1 0 0 0 0 0 0 2048 1 0 0 0 0 0 0'
  print -r -- 'tailscale0: 1048576 1 0 0 0 0 0 0 2097152 1 0 0 0 0 0 0'
} >"$netrate_counter_file"
{
  print -r -- 'Inter-|   Receive                                                |  Transmit'
  print -r -- ' face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed'
  print -r -- '    lo: 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0'
  print -r -- '  eth0: 3072 2 0 0 0 0 0 0 5120 2 0 0 0 0 0 0'
  print -r -- 'tailscale0: 2097152 2 0 0 0 0 0 0 4194304 2 0 0 0 0 0 0'
} >"$netrate_next_file"
{
  print -r -- '#!/bin/sh'
  print -r -- 'cp "$NETRATE_TEST_NEXT" "$NETRATE_TEST_SOURCE"'
} >"$netrate_bin/sleep"
chmod +x "$netrate_bin/sleep"

# netrate reads Linux /proc counters; elsewhere it reports them unavailable (checked below).
if [[ "$OSTYPE" == linux* ]]; then
  netrate_output="$(
    export _NETRATE_PROC_NET_DEV="$netrate_counter_file"
    export NETRATE_TEST_SOURCE="$netrate_counter_file"
    export NETRATE_TEST_NEXT="$netrate_next_file"
    path=("$netrate_bin" "${original_path[@]}")
    rehash
    netrate
  )" || fail_test "netrate report failed"
  print -r -- "$netrate_output" | command grep -Eq '^INTERFACE +RX/s +TX/s +RECEIVED +SENT$' || fail_test "netrate table header is missing"
  assert_contains "$netrate_output" "eth0"
  assert_contains "$netrate_output" "2.00KiB/s"
  assert_contains "$netrate_output" "3.00KiB/s"
  assert_contains "$netrate_output" "tailscale0"
  assert_contains "$netrate_output" "1.00MiB/s"
  assert_contains "$netrate_output" "2.00MiB/s"
  assert_not_contains "$netrate_output" $'\nlo '
fi

netrate_status=0
netrate_error="$(netrate unexpected 2>&1)" || netrate_status=$?
[[ "$netrate_status" == 2 ]] || fail_test "netrate unexpected argument returned $netrate_status"
assert_contains "$netrate_error" "no arguments are accepted"

netrate_status=0
netrate_error="$(_NETRATE_PROC_NET_DEV="$tmp_root/missing-net-dev" netrate 2>&1)" || netrate_status=$?
[[ "$netrate_status" == 1 ]] || fail_test "netrate missing counters returned $netrate_status"
assert_contains "$netrate_error" "network counters are not available"

netcheck_help="$(netcheck --help)" || fail_test "netcheck help failed"
[[ "${netcheck_help%%$'\n'*}" == "Usage:" ]] || fail_test "netcheck help does not begin with Usage"
assert_contains "$netcheck_help" $'\n\nDescription:'
assert_contains "$netcheck_help" $'\n\nOptions:'
assert_contains "$netcheck_help" $'\n\nExamples:'

netcheck_bin="$tmp_root/netcheck-bin"
mkdir -p "$netcheck_bin"
{
  print -r -- '#!/bin/sh'
  print -r -- 'if [ "$1" = hosts ]; then'
  print -r -- '  if [ "${NETCHECK_PTR_NONE:-0}" = 1 ]; then exit 2; fi'
  print -r -- '  printf "%s\n" "192.0.2.10 reverse.example.test reverse-alias"'
  print -r -- '  exit 0'
  print -r -- 'fi'
  print -r -- 'if [ "${NETCHECK_DNS_FAIL:-0}" = 1 ]; then exit 2; fi'
  print -r -- 'printf "%s\n" "192.0.2.10 STREAM example.test" "192.0.2.10 DGRAM example.test" "2001:db8::10 STREAM example.test"'
} >"$netcheck_bin/getent"
{
  print -r -- '#!/bin/sh'
  print -r -- 'printf "%s\n" "192.0.2.10 via 10.0.0.1 dev eth0 src 10.0.0.2"'
} >"$netcheck_bin/ip"
{
  print -r -- '#!/bin/sh'
  print -r -- 'if [ "${NETCHECK_PING_FAIL:-0}" = 1 ]; then exit 1; fi'
  print -r -- 'printf "%s\n" "64 bytes from 192.0.2.10: time=18.4 ms"'
} >"$netcheck_bin/ping"
{
  print -r -- '#!/bin/sh'
  print -r -- 'for arg do last="$arg"; done'
  print -r -- 'if [ "$last" = 81 ]; then printf "%s\n" "connection refused" >&2; exit 1; fi'
} >"$netcheck_bin/nc"
# macOS has no timeout without GNU coreutils; the probes above are fakes anyway.
{
  print -r -- '#!/bin/sh'
  print -r -- 'shift'
  print -r -- 'exec "$@"'
} >"$netcheck_bin/timeout"
chmod +x "$netcheck_bin/getent" "$netcheck_bin/ip" "$netcheck_bin/ping" "$netcheck_bin/nc" "$netcheck_bin/timeout"

netcheck_output="$(path=("$netcheck_bin" "${original_path[@]}"); rehash; netcheck example.test 443)" || fail_test "netcheck success report failed"
print -r -- "$netcheck_output" | command grep -Eq '^CHECK +RESULT +DETAIL$' || fail_test "netcheck table header is missing"
assert_contains "$netcheck_output" "192.0.2.10, 2001:db8::10"
assert_contains "$netcheck_output" "via 10.0.0.1 dev eth0"
assert_contains "$netcheck_output" "18.4 ms"
assert_contains "$netcheck_output" "example.test:443"
assert_not_contains "$netcheck_output" "PTR"

netcheck_ptr="$(path=("$netcheck_bin" "${original_path[@]}"); rehash; netcheck 192.0.2.10 443)" || fail_test "netcheck reverse DNS report failed"
assert_contains "$netcheck_ptr" "PTR"
assert_contains "$netcheck_ptr" "reverse.example.test, reverse-alias"

netcheck_ptr_none="$(NETCHECK_PTR_NONE=1; export NETCHECK_PTR_NONE; path=("$netcheck_bin" "${original_path[@]}"); rehash; netcheck 192.0.2.10 443)" || fail_test "netcheck treated missing reverse DNS as fatal"
assert_contains "$netcheck_ptr_none" "none"
assert_contains "$netcheck_ptr_none" "no reverse hostname"

netcheck_warn="$(NETCHECK_PING_FAIL=1; export NETCHECK_PING_FAIL; path=("$netcheck_bin" "${original_path[@]}"); rehash; netcheck example.test 443)" || fail_test "netcheck treated blocked ICMP as fatal"
assert_contains "$netcheck_warn" "warn"
assert_contains "$netcheck_warn" "ICMP blocked or host unreachable"

netcheck_status=0
netcheck_error="$(path=("$netcheck_bin" "${original_path[@]}"); rehash; netcheck example.test 81 2>&1)" || netcheck_status=$?
[[ "$netcheck_status" == 1 ]] || fail_test "netcheck failed TCP returned $netcheck_status"
assert_contains "$netcheck_error" "connection refused"

netcheck_status=0
netcheck_error="$(NETCHECK_DNS_FAIL=1; export NETCHECK_DNS_FAIL; path=("$netcheck_bin" "${original_path[@]}"); rehash; netcheck missing.test 2>&1)" || netcheck_status=$?
[[ "$netcheck_status" == 1 ]] || fail_test "netcheck failed DNS returned $netcheck_status"
assert_contains "$netcheck_error" "did not resolve"
assert_contains "$netcheck_error" "no resolved address"

netcheck_status=0
netcheck_error="$(netcheck example.test 70000 2>&1)" || netcheck_status=$?
[[ "$netcheck_status" == 2 ]] || fail_test "netcheck invalid port returned $netcheck_status"
assert_contains "$netcheck_error" "between 1 and 65535"

sshcheck_help="$(sshcheck --help)" || fail_test "sshcheck help failed"
[[ "${sshcheck_help%%$'\n'*}" == "Usage:" ]] || fail_test "sshcheck help does not begin with Usage"
assert_contains "$sshcheck_help" $'\n\nDescription:'
assert_contains "$sshcheck_help" $'\n\nOptions:'
assert_contains "$sshcheck_help" $'\n\nExamples:'
assert_contains "$sshcheck_help" "--auth"

sshcheck_bin="$tmp_root/sshcheck-bin"
sshcheck_auth_log="$tmp_root/sshcheck-auth.log"
mkdir -p "$sshcheck_bin"
{
  print -r -- '#!/bin/sh'
  print -r -- 'if [ "$1" = -G ]; then'
  print -r -- '  if [ "${SSHCHECK_CONFIG_FAIL:-0}" = 1 ]; then printf "%s\n" "bad SSH config" >&2; exit 255; fi'
  print -r -- '  printf "%s\n" "hostname real.example.test" "user setup-user" "port 2222"'
  print -r -- '  printf "%s\n" "proxyjump ${SSHCHECK_PROXY:-none}" "proxycommand none"'
  print -r -- '  printf "%s\n" "identityfile ~/.ssh/id_ed25519" "identityfile ~/.ssh/id_rsa"'
  print -r -- '  exit 0'
  print -r -- 'fi'
  print -r -- 'printf "%s\n" "$*" >"$SSHCHECK_AUTH_LOG"'
  print -r -- 'if [ "${SSHCHECK_AUTH_FAIL:-0}" = 1 ]; then printf "%s\n" "Permission denied" >&2; exit 255; fi'
} >"$sshcheck_bin/ssh"
{
  print -r -- '#!/bin/sh'
  print -r -- 'shift'
  print -r -- 'exec "$@"'
} >"$sshcheck_bin/timeout"
{
  print -r -- '#!/bin/sh'
  print -r -- 'if [ "${SSHCHECK_DNS_FAIL:-0}" = 1 ]; then exit 2; fi'
  print -r -- 'printf "%s\n" "192.0.2.22 STREAM real.example.test" "192.0.2.22 DGRAM real.example.test" "2001:db8::22 STREAM real.example.test"'
} >"$sshcheck_bin/getent"
{
  print -r -- '#!/bin/sh'
  print -r -- 'if [ "${SSHCHECK_TCP_FAIL:-0}" = 1 ]; then printf "%s\n" "connection refused" >&2; exit 1; fi'
} >"$sshcheck_bin/nc"
{
  print -r -- '#!/bin/sh'
  print -r -- 'printf "%s\n" "256 SHA256:first key-one (ED25519)" "256 SHA256:second key-two (ED25519)"'
} >"$sshcheck_bin/ssh-add"
chmod +x "$sshcheck_bin/ssh" "$sshcheck_bin/timeout" "$sshcheck_bin/getent" "$sshcheck_bin/nc" "$sshcheck_bin/ssh-add"

sshcheck_output="$({
  path=("$sshcheck_bin" "${original_path[@]}")
  SSH_AUTH_SOCK="$tmp_root/agent.sock"
  export SSH_AUTH_SOCK
  rehash
  sshcheck build-host
})" || fail_test "sshcheck default report failed"
assert_contains "$sshcheck_output" "Target: build-host"
assert_contains "$sshcheck_output" "Host: real.example.test"
assert_contains "$sshcheck_output" "User: setup-user"
assert_contains "$sshcheck_output" "Port: 2222"
assert_contains "$sshcheck_output" "Identity files: ~/.ssh/id_ed25519, ~/.ssh/id_rsa"
assert_contains "$sshcheck_output" "192.0.2.22, 2001:db8::22"
assert_contains "$sshcheck_output" "real.example.test:2222"
assert_contains "$sshcheck_output" "2 identities"
assert_contains "$sshcheck_output" "use --auth to test"

sshcheck_auth_output="$({
  path=("$sshcheck_bin" "${original_path[@]}")
  SSH_AUTH_SOCK="$tmp_root/agent.sock"
  SSHCHECK_AUTH_LOG="$sshcheck_auth_log"
  export SSH_AUTH_SOCK SSHCHECK_AUTH_LOG
  rehash
  sshcheck --auth build-host
})" || fail_test "sshcheck auth report failed"
assert_contains "$sshcheck_auth_output" "non-interactive authentication succeeded"
assert_contains "$(<$sshcheck_auth_log)" "BatchMode=yes"
assert_contains "$(<$sshcheck_auth_log)" "build-host true"

sshcheck_proxy_output="$({
  path=("$sshcheck_bin" "${original_path[@]}")
  SSHCHECK_PROXY="jump-host"
  export SSHCHECK_PROXY
  unset SSH_AUTH_SOCK
  rehash
  sshcheck private-host
})" || fail_test "sshcheck proxy report failed"
assert_contains "$sshcheck_proxy_output" "Proxy: ProxyJump jump-host"
assert_contains "$sshcheck_proxy_output" "direct probe skipped"
assert_contains "$sshcheck_proxy_output" "SSH_AUTH_SOCK is unset"

sshcheck_status=0
sshcheck_error="$({
  path=("$sshcheck_bin" "${original_path[@]}")
  SSHCHECK_DNS_FAIL=1
  export SSHCHECK_DNS_FAIL
  rehash
  sshcheck missing-host 2>&1
})" || sshcheck_status=$?
[[ "$sshcheck_status" == 1 ]] || fail_test "sshcheck DNS failure returned $sshcheck_status"
assert_contains "$sshcheck_error" "did not resolve"

sshcheck_status=0
sshcheck_error="$({
  path=("$sshcheck_bin" "${original_path[@]}")
  SSHCHECK_TCP_FAIL=1
  export SSHCHECK_TCP_FAIL
  rehash
  sshcheck closed-host 2>&1
})" || sshcheck_status=$?
[[ "$sshcheck_status" == 1 ]] || fail_test "sshcheck TCP failure returned $sshcheck_status"
assert_contains "$sshcheck_error" "connection refused"

sshcheck_status=0
sshcheck_error="$({
  path=("$sshcheck_bin" "${original_path[@]}")
  SSHCHECK_AUTH_FAIL=1
  SSHCHECK_AUTH_LOG="$sshcheck_auth_log"
  export SSHCHECK_AUTH_FAIL SSHCHECK_AUTH_LOG
  rehash
  sshcheck --auth denied-host 2>&1
})" || sshcheck_status=$?
[[ "$sshcheck_status" == 1 ]] || fail_test "sshcheck auth failure returned $sshcheck_status"
assert_contains "$sshcheck_error" "Permission denied"

sshcheck_status=0
sshcheck_error="$({
  path=("$sshcheck_bin" "${original_path[@]}")
  SSHCHECK_CONFIG_FAIL=1
  export SSHCHECK_CONFIG_FAIL
  rehash
  sshcheck broken-host 2>&1
})" || sshcheck_status=$?
[[ "$sshcheck_status" == 1 ]] || fail_test "sshcheck config failure returned $sshcheck_status"
assert_contains "$sshcheck_error" "could not resolve SSH configuration"
assert_contains "$sshcheck_error" "bad SSH config"

sshcheck_status=0
sshcheck_error="$(sshcheck 2>&1)" || sshcheck_status=$?
[[ "$sshcheck_status" == 2 ]] || fail_test "sshcheck missing host returned $sshcheck_status"
assert_contains "$sshcheck_error" "a host is required"

print -r -- "PASS: network functions checks"
