#!/usr/bin/env zsh
# setup-test: Process functions
# Covers ports, killport, psg, hot, pinfo, and vitals in dotfiles/functions/processes.zsh.
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

ports_help="$(ports --help)" || fail_test "ports help failed"
[[ "${ports_help%%$'\n'*}" == "Usage:" ]] || fail_test "ports help does not begin with Usage"
assert_contains "$ports_help" $'\n\nDescription:'
assert_contains "$ports_help" $'\n\nOptions:'
assert_contains "$ports_help" $'\n\nExamples:'

ports_bin="$tmp_root/ports-bin"
mkdir -p "$ports_bin"
{
  print -r -- '#!/bin/sh'
  print -r -- 'printf "%s\n" '\''tcp LISTEN 0 128 127.0.0.1:8080 0.0.0.0:* users:(("python",pid=123,fd=3))'\'''
  print -r -- 'printf "%s\n" '\''udp UNCONN 0 0 [::]:53 [::]:*'\'''
  print -r -- 'printf "%s\n" '\''tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=42,fd=3))'\'''
} >"$ports_bin/ss"
chmod +x "$ports_bin/ss"

ports_output="$(path=("$ports_bin" "${original_path[@]}"); rehash; ports)" || fail_test "ports report failed"
print -r -- "$ports_output" | command grep -Eq '^PROTO +ADDRESS +PORT +PID +PROCESS$' || fail_test "ports table header is missing"
assert_contains "$ports_output" "127.0.0.1"
assert_contains "$ports_output" "8080"
assert_contains "$ports_output" "123"
assert_contains "$ports_output" "python"
assert_contains "$ports_output" "::"
assert_contains "$ports_output" "53"

ports_filtered="$(path=("$ports_bin" "${original_path[@]}"); rehash; ports 8080)" || fail_test "ports filter failed"
assert_contains "$ports_filtered" "8080"
assert_not_contains "$ports_filtered" "sshd"
assert_not_contains "$ports_filtered" " 53 "

ports_empty="$(path=("$ports_bin" "${original_path[@]}"); rehash; ports 9999)" || fail_test "ports empty filter failed"
assert_contains "$ports_empty" "No listeners found on port 9999."

ports_status=0
ports_error="$(ports 70000 2>&1)" || ports_status=$?
[[ "$ports_status" == 2 ]] || fail_test "ports invalid port returned $ports_status"
assert_contains "$ports_error" "between 1 and 65535"

killport_help="$(killport --help)" || fail_test "killport help failed"
[[ "${killport_help%%$'\n'*}" == "Usage:" ]] || fail_test "killport help does not begin with Usage"
assert_contains "$killport_help" $'\n\nDescription:'
assert_contains "$killport_help" $'\n\nOptions:'
assert_contains "$killport_help" $'\n\nExamples:'

killport_bin="$tmp_root/killport-bin"
killport_state="$tmp_root/killport-state"
killport_signal_log="$tmp_root/killport-signals"
mkdir -p "$killport_bin"
{
  print -r -- '#!/bin/sh'
  print -r -- 'if [ ! -e "$KILLPORT_TEST_STATE" ]; then'
  print -r -- '  printf "%s\n" "tcp LISTEN 0 128 127.0.0.1:8080 0.0.0.0:* users:((\"python\",pid=123,fd=3),(\"worker\",pid=456,fd=4))"'
  print -r -- 'fi'
} >"$killport_bin/ss"
{
  print -r -- '#!/bin/sh'
  print -r -- 'printf "%s\n" "$*" >>"$KILLPORT_TEST_SIGNAL_LOG"'
  print -r -- 'touch "$KILLPORT_TEST_STATE"'
} >"$killport_bin/kill"
{
  print -r -- '#!/bin/sh'
  print -r -- 'exit 0'
} >"$killport_bin/sleep"
chmod +x "$killport_bin/ss" "$killport_bin/kill" "$killport_bin/sleep"

killport_output="$({
  export KILLPORT_TEST_STATE="$killport_state"
  export KILLPORT_TEST_SIGNAL_LOG="$killport_signal_log"
  path=("$killport_bin" "${original_path[@]}")
  rehash
  killport 8080 <<<'yes'
})" || fail_test "killport TERM flow failed"
assert_contains "$killport_output" "Listeners on port 8080:"
assert_contains "$killport_output" "123"
assert_contains "$killport_output" "python"
assert_contains "$killport_output" "456"
assert_contains "$killport_output" "worker"
assert_contains "$killport_output" "Released port 8080."
assert_contains "$(<$killport_signal_log)" "-TERM -- 123"
assert_contains "$(<$killport_signal_log)" "-TERM -- 456"

rm -f "$killport_state" "$killport_signal_log"
killport_force_output="$({
  export KILLPORT_TEST_STATE="$killport_state"
  export KILLPORT_TEST_SIGNAL_LOG="$killport_signal_log"
  path=("$killport_bin" "${original_path[@]}")
  rehash
  killport 8080 --force <<<'y'
})" || fail_test "killport KILL flow failed"
assert_contains "$(<$killport_signal_log)" "-KILL -- 123"

rm -f "$killport_state" "$killport_signal_log"
killport_status=0
killport_cancel_output="$({
  export KILLPORT_TEST_STATE="$killport_state"
  export KILLPORT_TEST_SIGNAL_LOG="$killport_signal_log"
  path=("$killport_bin" "${original_path[@]}")
  rehash
  killport 8080 <<<'n'
} 2>&1)" || killport_status=$?
[[ "$killport_status" == 1 ]] || fail_test "killport cancellation returned $killport_status"
assert_contains "$killport_cancel_output" "Canceled."
[[ ! -e "$killport_signal_log" ]] || fail_test "killport signaled a process after cancellation"

killport_status=0
killport_error="$(killport 70000 2>&1)" || killport_status=$?
[[ "$killport_status" == 2 ]] || fail_test "killport invalid port returned $killport_status"
assert_contains "$killport_error" "between 1 and 65535"

psg_help="$(psg --help)" || fail_test "psg help failed"
[[ "${psg_help%%$'\n'*}" == "Usage:" ]] || fail_test "psg help does not begin with Usage"
assert_contains "$psg_help" $'\n\nDescription:'
assert_contains "$psg_help" $'\n\nOptions:'
assert_contains "$psg_help" $'\n\nExamples:'

psg_bin="$tmp_root/psg-bin"
mkdir -p "$psg_bin"
{
  print -r -- '#!/bin/sh'
  print -r -- 'printf "%s\n" "101 1 alice 2.1 1.3 01:42:18 python3 server.py"'
  print -r -- 'printf "%s\n" "102 1 bob 0.4 0.8 12:31 PYTHON worker.py --config production"'
  print -r -- 'printf "%s\n" "103 1 root 0.0 0.1 3-00:00:00 sshd -D"'
  print -r -- 'printf "%s %s 0.0 0.0 00:00 ps -eo scanner-noise\n" "$$" "$PPID"'
} >"$psg_bin/ps"
chmod +x "$psg_bin/ps"

psg_output="$(path=("$psg_bin" "${original_path[@]}"); rehash; psg python)" || fail_test "psg search failed"
print -r -- "$psg_output" | command grep -Eq '^ *PID +USER +CPU +MEM +ELAPSED +COMMAND$' || fail_test "psg table header is missing"
assert_contains "$psg_output" "python3 server.py"
assert_contains "$psg_output" "PYTHON worker.py"
assert_not_contains "$psg_output" "sshd -D"
assert_not_contains "$psg_output" "scanner-noise"

psg_phrase="$(path=("$psg_bin" "${original_path[@]}"); rehash; psg python worker)" || fail_test "psg phrase search failed"
assert_contains "$psg_phrase" "PYTHON worker.py"
assert_not_contains "$psg_phrase" "python3 server.py"

psg_dashed="$(path=("$psg_bin" "${original_path[@]}"); rehash; psg -- --config production)" || fail_test "psg dashed search failed"
assert_contains "$psg_dashed" "--config production"

psg_status=0
psg_error="$(path=("$psg_bin" "${original_path[@]}"); rehash; psg missing-process 2>&1)" || psg_status=$?
[[ "$psg_status" == 1 ]] || fail_test "psg missing search returned $psg_status"
assert_contains "$psg_error" "No processes found matching"

psg_status=0
psg_error="$(psg 2>&1)" || psg_status=$?
[[ "$psg_status" == 2 ]] || fail_test "psg empty search returned $psg_status"
assert_contains "$psg_error" "search query is required"

hot_help="$(hot --help)" || fail_test "hot help failed"
[[ "${hot_help%%$'\n'*}" == "Usage:" ]] || fail_test "hot help does not begin with Usage"
assert_contains "$hot_help" $'\n\nDescription:'
assert_contains "$hot_help" $'\n\nOptions:'
assert_contains "$hot_help" $'\n\nExamples:'

hot_bin="$tmp_root/hot-bin"
mkdir -p "$hot_bin"
{
  print -r -- '#!/bin/sh'
  print -r -- 'case "$*" in'
  print -r -- '  *--sort=-%cpu*) printf "%s\n" "201 1 alice 99.0 1.0 00:10 cpu-heavy" ;;'
  print -r -- '  *) printf "%s\n" "202 1 bob 1.0 50.0 01:20 mem-heavy" ;;'
  print -r -- 'esac'
  print -r -- 'i=1'
  print -r -- 'while [ "$i" -le 15 ]; do'
  print -r -- '  printf "%s\n" "$((300 + i)) 1 user 0.$i 0.$i 02:00 process-$i"'
  print -r -- '  i=$((i + 1))'
  print -r -- 'done'
} >"$hot_bin/ps"
chmod +x "$hot_bin/ps"

hot_mem_output="$(path=("$hot_bin" "${original_path[@]}"); rehash; hot)" || fail_test "hot default memory report failed"
print -r -- "$hot_mem_output" | command grep -Eq '^ *PID +USER +CPU +MEM +ELAPSED +COMMAND$' || fail_test "hot table header is missing"
hot_mem_first="$(print -r -- "$hot_mem_output" | command sed -n '2p')"
assert_contains "$hot_mem_first" "mem-heavy"
[[ "$(print -r -- "$hot_mem_output" | command wc -l)" -eq 16 ]] || fail_test "hot did not limit output to 15 processes"
assert_not_contains "$hot_mem_output" "process-15"

hot_cpu_output="$(path=("$hot_bin" "${original_path[@]}"); rehash; hot cpu)" || fail_test "hot CPU report failed"
hot_cpu_first="$(print -r -- "$hot_cpu_output" | command sed -n '2p')"
assert_contains "$hot_cpu_first" "cpu-heavy"

hot_status=0
hot_error="$(hot disk 2>&1)" || hot_status=$?
[[ "$hot_status" == 2 ]] || fail_test "hot invalid mode returned $hot_status"
assert_contains "$hot_error" "expected cpu or mem"

pinfo_help="$(pinfo --help)" || fail_test "pinfo help failed"
[[ "${pinfo_help%%$'\n'*}" == "Usage:" ]] || fail_test "pinfo help does not begin with Usage"
assert_contains "$pinfo_help" $'\n\nDescription:'
assert_contains "$pinfo_help" $'\n\nOptions:'
assert_contains "$pinfo_help" $'\n\nExamples:'

pinfo_bin="$tmp_root/pinfo-bin"
mkdir -p "$pinfo_bin"
{
  print -r -- '#!/bin/sh'
  print -r -- 'if [ "${PINFO_TEST_MISSING:-0}" = 1 ]; then exit 1; fi'
  print -r -- 'printf "%s\n" "$PINFO_TEST_PID 10 alice Sl 12.5 3.4 01:02:03 Mon Sep 2 12:34:56 2026 python3 server.py --port 8080"'
} >"$pinfo_bin/ps"
{
  print -r -- '#!/bin/sh'
  print -r -- 'case "$1" in'
  print -r -- '  */exe) printf "%s\n" "/usr/bin/python3" ;;'
  print -r -- '  */cwd) printf "%s\n" "/srv/example" ;;'
  print -r -- '  *) exit 1 ;;'
  print -r -- 'esac'
} >"$pinfo_bin/readlink"
{
  print -r -- '#!/bin/sh'
  print -r -- 'printf "%s\n" "tcp LISTEN 0 128 127.0.0.1:8080 0.0.0.0:* users:((\"python3\",pid=$PINFO_TEST_PID,fd=3))"'
  print -r -- 'printf "%s\n" "tcp LISTEN 0 128 [::1]:9090 [::]:* users:((\"python3\",pid=$PINFO_TEST_PID,fd=4))"'
} >"$pinfo_bin/ss"
chmod +x "$pinfo_bin/ps" "$pinfo_bin/readlink" "$pinfo_bin/ss"

pinfo_test_pid="$$"
pinfo_output="$({
  export PINFO_TEST_PID="$pinfo_test_pid"
  path=("$pinfo_bin" "${original_path[@]}")
  rehash
  pinfo "$pinfo_test_pid"
})" || fail_test "pinfo report failed"
print -r -- "$pinfo_output" | command grep -Eq '^FIELD +VALUE$' || fail_test "pinfo table header is missing"
assert_contains "$pinfo_output" "alice"
assert_contains "$pinfo_output" "12.5%"
assert_contains "$pinfo_output" "3.4%"
assert_contains "$pinfo_output" "Mon Sep 2 12:34:56 2026"
assert_contains "$pinfo_output" "python3 server.py --port 8080"
assert_contains "$pinfo_output" "/usr/bin/python3"
assert_contains "$pinfo_output" "/srv/example"
assert_contains "$pinfo_output" "tcp 127.0.0.1:8080, tcp [::1]:9090"

pinfo_status=0
pinfo_error="$({
  export PINFO_TEST_MISSING=1
  export PINFO_TEST_PID="$pinfo_test_pid"
  path=("$pinfo_bin" "${original_path[@]}")
  rehash
  pinfo "$pinfo_test_pid"
} 2>&1)" || pinfo_status=$?
[[ "$pinfo_status" == 1 ]] || fail_test "pinfo missing process returned $pinfo_status"
assert_contains "$pinfo_error" "process not found"

pinfo_status=0
pinfo_error="$(pinfo 0 2>&1)" || pinfo_status=$?
[[ "$pinfo_status" == 2 ]] || fail_test "pinfo invalid PID returned $pinfo_status"
assert_contains "$pinfo_error" "greater than zero"

vitals_help="$(vitals --help)" || fail_test "vitals help failed"
[[ "${vitals_help%%$'\n'*}" == "Usage:" ]] || fail_test "vitals help does not begin with Usage"
assert_contains "$vitals_help" $'\n\nDescription:'
assert_contains "$vitals_help" $'\n\nOptions:'
assert_contains "$vitals_help" $'\n\nExamples:'

vitals_bin="$tmp_root/vitals-bin"
mkdir -p "$vitals_bin"
{
  print -r -- '#!/bin/sh'
  print -r -- 'printf "%s\n" "up 2 days, 3 hours"'
} >"$vitals_bin/uptime"
{
  print -r -- '#!/bin/sh'
  print -r -- 'printf "%s\n" "8"'
} >"$vitals_bin/nproc"
{
  print -r -- '#!/bin/sh'
  print -r -- 'printf "%s\n" "Mem: 1000 400 100 0 500 600" "Swap: 200 50 150"'
} >"$vitals_bin/free"
{
  print -r -- '#!/bin/sh'
  print -r -- 'printf "%s\n" "1B-blocks Used Use%" "2000 1500 75%"'
} >"$vitals_bin/df"
{
  print -r -- '#!/bin/sh'
  print -r -- 'printf "%s\n" "S" "R+" "R"'
} >"$vitals_bin/ps"
{
  print -r -- '#!/bin/sh'
  print -r -- 'while IFS= read -r value; do printf "%sB\n" "$value"; done'
} >"$vitals_bin/numfmt"
chmod +x "$vitals_bin/uptime" "$vitals_bin/nproc" "$vitals_bin/free" "$vitals_bin/df" "$vitals_bin/ps" "$vitals_bin/numfmt"

# vitals reads Linux /proc; elsewhere it must say so instead of printing a report.
if [[ -r /proc/loadavg ]]; then
  vitals_output="$(path=("$vitals_bin" "${original_path[@]}"); rehash; vitals)" || fail_test "vitals report failed"
  print -r -- "$vitals_output" | command grep -Eq '^METRIC +VALUE$' || fail_test "vitals table header is missing"
  assert_contains "$vitals_output" "2 days, 3 hours"
  assert_contains "$vitals_output" "8 online"
  assert_contains "$vitals_output" "400B / 1000B (40%)"
  assert_contains "$vitals_output" "50B / 200B (25%)"
  assert_contains "$vitals_output" "1500B / 2000B (75%)"
  assert_contains "$vitals_output" "3 total, 2 running"
else
  vitals_status=0
  vitals_error="$(path=("$vitals_bin" "${original_path[@]}"); rehash; vitals 2>&1)" || vitals_status=$?
  [[ "$vitals_status" == 1 ]] || fail_test "vitals without /proc returned $vitals_status"
  assert_contains "$vitals_error" "/proc/loadavg is unavailable"
fi

vitals_status=0
vitals_error="$(vitals unexpected 2>&1)" || vitals_status=$?
[[ "$vitals_status" == 2 ]] || fail_test "vitals with an argument returned $vitals_status"
assert_contains "$vitals_error" "does not accept arguments"

print -r -- "PASS: process functions checks"
