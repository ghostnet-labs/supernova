#!/usr/bin/env zsh
# setup-test: File and disk functions
# Covers space, mounts, compress, and extract in dotfiles/functions/files.zsh.
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

space_help="$(space --help)" || fail_test "space help failed"
[[ "${space_help%%$'\n'*}" == "Usage:" ]] || fail_test "space help does not begin with Usage"
assert_contains "$space_help" $'\n\nDescription:'
assert_contains "$space_help" $'\n\nOptions:'
assert_contains "$space_help" $'\n\nExamples:'
assert_contains "$space_help" "space browse /"

space_dir="$tmp_root/space area"
mkdir -p "$space_dir/nested"
print -rn -- "small" >"$space_dir/small.txt"
print -rn -- "larger file" >"$space_dir/nested/larger.txt"

space_summary="$(space "$space_dir")" || fail_test "space summary failed"
space_first_line="${space_summary%%$'\n'*}"
[[ -z "$space_first_line" ]] || fail_test "space omitted its leading blank row"
assert_not_contains "$space_summary" "System utilization"
assert_contains "$space_summary" "Allocated disk usage (immediate children): ${space_dir:A}"
assert_contains "$space_summary" "$space_dir/nested"
assert_contains "$space_summary" "$space_dir/small.txt"
assert_not_contains "$space_summary" "$space_dir/nested/larger.txt"

# macOS du rejects -a combined with -d; the summary must not depend on it.
space_bsd_du_bin="$tmp_root/space-bsd-du-bin"
mkdir -p "$space_bsd_du_bin"
{
  print -r -- '#!/bin/sh'
  print -r -- 'aflag= dflag='
  print -r -- 'for arg in "$@"; do case "$arg" in --) break ;; -*a*) aflag=1 ;; esac; case "$arg" in --) break ;; -*d*) dflag=1 ;; esac; done'
  print -r -- '[ -n "$aflag" ] && [ -n "$dflag" ] && { echo "usage: du [-a | -s | -d depth]" >&2; exit 64; }'
  print -r -- "exec ${(q)commands[du]} \"\$@\""
} >"$space_bsd_du_bin/du"
chmod +x "$space_bsd_du_bin/du"
space_bsd_summary="$(path=("$space_bsd_du_bin" "${path[@]}"); space "$space_dir")" || fail_test "space summary failed with BSD du"
assert_contains "$space_bsd_summary" "$space_dir/nested"
assert_contains "$space_bsd_summary" "$space_dir/small.txt"
assert_not_contains "$space_bsd_summary" "$space_dir/nested/larger.txt"

space_files="$(space files "$space_dir")" || fail_test "space files failed"
space_files_first_line="${space_files%%$'\n'*}"
[[ -z "$space_files_first_line" ]] || fail_test "space files omitted its leading blank row"
assert_contains "$space_files" $'Filesystem '
assert_contains "$space_files" "Largest individual files (allocated; top 50): ${space_dir:A}"
assert_contains "$space_files" "$space_dir/small.txt"
assert_contains "$space_files" "$space_dir/nested/larger.txt"

space_status=0
space_error="$(space vm "$space_dir" 2>&1)" || space_status=$?
[[ "$space_status" == 2 ]] || fail_test "space invalid vm invocation returned $space_status"
assert_contains "$space_error" "vm does not accept a path"

space_bin="$tmp_root/space-bin"
space_call_log="$tmp_root/space-calls"
mkdir -p "$space_bin"
{
  print -r -- '#!/bin/sh'
  print -r -- 'printf "%s\\n" "$*" >"$SPACE_TEST_CALL_LOG"'
} >"$space_bin/ncdu"
chmod +x "$space_bin/ncdu"
(
  path=("$space_bin" "${path[@]}")
  export SPACE_TEST_CALL_LOG="$space_call_log"
  space browse "$space_dir"
) || fail_test "space browse failed"
[[ "$(<$space_call_log)" == "-x -rr ${space_dir:A}" ]] || fail_test "space browse was not read-only"

mounts_help="$(mounts --help)" || fail_test "mounts help failed"
[[ "${mounts_help%%$'\n'*}" == "Usage:" ]] || fail_test "mounts help does not begin with Usage"
assert_contains "$mounts_help" $'\n\nDescription:'
assert_contains "$mounts_help" $'\n\nOptions:'
assert_contains "$mounts_help" $'\n\nExamples:'

mounts_bin="$tmp_root/mounts-bin"
mounts_call_log="$tmp_root/mounts-call"
mkdir -p "$mounts_bin"
# mounts asks Linux df for filesystem types and exclusions; macOS df has neither.
if [[ "$OSTYPE" == linux* ]]; then
  {
    print -r -- '#!/bin/sh'
    print -r -- 'printf "%s\n" "$*" >"$MOUNTS_TEST_CALL_LOG"'
    print -r -- 'printf "%s\n" \'
    print -r -- '  "Filesystem Type Size Used Avail Use% Mounted on" \'
    print -r -- '  "/dev/root ext4 291G 191G 101G 66% /" \'
    print -r -- '  "server:/volume nfs4 15T 8.7T 5.5T 62% /net/shared data"'
  } >"$mounts_bin/df"
else
  {
    print -r -- '#!/bin/sh'
    print -r -- 'printf "%s\n" "$*" >"$MOUNTS_TEST_CALL_LOG"'
    print -r -- 'printf "%s\n" \'
    print -r -- '  "Filesystem Size Used Avail Capacity Mounted on" \'
    print -r -- '  "/dev/root 291G 191G 101G 66% /" \'
    print -r -- '  "devfs 205K 205K 0B 100% /dev" \'
    print -r -- '  "server:/volume 15T 8.7T 5.5T 62% /net/shared data"'
  } >"$mounts_bin/df"
fi
chmod +x "$mounts_bin/df"

mounts_output="$({
  export MOUNTS_TEST_CALL_LOG="$mounts_call_log"
  path=("$mounts_bin" "${original_path[@]}")
  rehash
  mounts
})" || fail_test "mounts report failed"
print -r -- "$mounts_output" | command grep -Eq '^DEVICE +TYPE +SIZE +USED +AVAIL +USE +MOUNT$' || fail_test "mounts table header is missing"
assert_contains "$mounts_output" "/dev/root"
assert_contains "$mounts_output" "server:/volume"
assert_contains "$mounts_output" "/net/shared data"
if [[ "$OSTYPE" == linux* ]]; then
  assert_contains "$(<$mounts_call_log)" "-x tmpfs"
  assert_contains "$(<$mounts_call_log)" "-x overlay"
else
  [[ "$(<$mounts_call_log)" == "-hP" ]] || fail_test "mounts passed unexpected df arguments on $OSTYPE"
  assert_not_contains "$mounts_output" "devfs"
fi

mounts_status=0
mounts_error="$(mounts unexpected 2>&1)" || mounts_status=$?
[[ "$mounts_status" == 2 ]] || fail_test "mounts with an argument returned $mounts_status"
assert_contains "$mounts_error" "does not accept arguments"

# These helpers ran with a scratch HOME before the split; keep them isolated.
HOME="$tmp_root/home"
mkdir -p "$HOME"

compress_help="$(compress --help)" || fail_test "compress help failed"
[[ "${compress_help%%$'\n'*}" == "Usage:" ]] || fail_test "compress help does not begin with Usage"
assert_contains "$compress_help" $'\n\nDescription:'
assert_contains "$compress_help" $'\n\nOptions:'
assert_contains "$compress_help" $'\n\nExamples:'
assert_contains "$compress_help" "--force"
assert_contains "$compress_help" ".tar.gz"

compress_source="$tmp_root/compress source"
compress_nested="$compress_source/nested"
compress_archive="$tmp_root/compress source.tar.gz"
compress_extract="$tmp_root/compress extract"
mkdir -p "$compress_nested" "$compress_extract"
print -r -- "first payload" >"$compress_source/first.txt"
print -r -- "second payload" >"$compress_nested/second.txt"

compress_output="$(compress "$compress_source")" || fail_test "compress directory default failed"
assert_contains "$compress_output" "Compressed:"
assert_contains "$compress_output" "Files: 2"
print -r -- "$compress_output" | command grep -Eq '^Source size: [0-9].*B$' || fail_test "compress omitted the source size"
print -r -- "$compress_output" | command grep -Eq '^Archive size: [0-9].*B$' || fail_test "compress omitted the archive size"
print -r -- "$compress_output" | command grep -Eq '^Ratio: [0-9.]+% of source$' || fail_test "compress omitted the ratio"
assert_contains "$compress_output" "Elapsed:"
[[ -f "$compress_archive" ]] || fail_test "compress directory omitted the default tar.gz archive"
# Capture listings before matching: with pipefail, grep -q exiting early can SIGPIPE tar.
[[ "$(command tar -tzf "$compress_archive")" == *"compress source/nested/second.txt"* ]] || fail_test "compress tar.gz omitted a nested file"

extract "$compress_archive" "$compress_extract" >/dev/null || fail_test "compress archive did not round-trip through extract"
[[ "$(<"$compress_extract/compress source/first.txt")" == "first payload" ]] || fail_test "compress round-trip changed a payload"

compress_status=0
compress_error="$(compress "$compress_source" 2>&1)" || compress_status=$?
[[ "$compress_status" == 1 ]] || fail_test "compress existing archive returned $compress_status"
assert_contains "$compress_error" "archive already exists"

print -r -- "updated payload" >"$compress_source/first.txt"
compress --force "$compress_source" >/dev/null || fail_test "compress force failed"
force_extract="$tmp_root/compress force extract"
mkdir -p "$force_extract"
extract "$compress_archive" "$force_extract" >/dev/null || fail_test "compress forced archive did not extract"
[[ "$(<"$force_extract/compress source/first.txt")" == "updated payload" ]] || fail_test "compress force did not replace the archive"

compress_file="$tmp_root/single file.log"
print -r -- "single payload" >"$compress_file"
compress "$compress_file" >/dev/null || fail_test "compress file default failed"
[[ -f "$compress_file.gz" ]] || fail_test "compress file omitted the default gzip output"
[[ "$(command gzip -dc "$compress_file.gz")" == "single payload" ]] || fail_test "compress gzip payload is incorrect"

compress_tar="$tmp_root/explicit.tar"
compress "$compress_source" "$compress_tar" >/dev/null || fail_test "compress explicit tar failed"
[[ "$(command tar -tf "$compress_tar")" == *"compress source/first.txt"* ]] || fail_test "compress explicit tar omitted a file"

if (( $+commands[zstd] )); then
  compress_zstd="$tmp_root/explicit.tar.zst"
  compress "$compress_source" "$compress_zstd" >/dev/null || fail_test "compress explicit tar.zst failed"
  [[ "$(command zstd -qdc "$compress_zstd" | command tar -tf -)" == *"compress source/first.txt"* ]] || fail_test "compress tar.zst payload is incorrect"
fi

compress_status=0
compress_error="$(compress "$compress_source" "$tmp_root/directory.gz" 2>&1)" || compress_status=$?
[[ "$compress_status" == 2 ]] || fail_test "compress directory stream returned $compress_status"
assert_contains "$compress_error" "accepts files only"

compress_status=0
compress_error="$(compress "$compress_source" "$compress_source/archive.tar.gz" 2>&1)" || compress_status=$?
[[ "$compress_status" == 2 ]] || fail_test "compress archive inside source returned $compress_status"
assert_contains "$compress_error" "inside its source directory"
[[ ! -e "$compress_source/archive.tar.gz" ]] || fail_test "compress created an archive inside its source"

compress_status=0
compress_error="$(compress "$compress_file" "$tmp_root/archive.rar" 2>&1)" || compress_status=$?
[[ "$compress_status" == 2 ]] || fail_test "compress unsupported format returned $compress_status"
assert_contains "$compress_error" "unsupported archive format"
[[ ! -e "$tmp_root/archive.rar" ]] || fail_test "compress created an unsupported archive"

compress_fail_bin="$tmp_root/compress-fail-bin"
compress_preserved="$tmp_root/preserved.gz"
mkdir -p "$compress_fail_bin"
{
  print -r -- '#!/bin/sh'
  print -r -- 'printf "%s" "partial archive"'
  print -r -- 'exit 9'
} >"$compress_fail_bin/gzip"
chmod +x "$compress_fail_bin/gzip"
print -r -- "keep existing archive" >"$compress_preserved"
compress_status=0
compress_error="$({
  path=("$compress_fail_bin" "${original_path[@]}")
  rehash
  compress --force "$compress_file" "$compress_preserved" 2>&1
})" || compress_status=$?
[[ "$compress_status" == 9 ]] || fail_test "compress failure returned $compress_status"
assert_contains "$compress_error" "compression failed"
[[ "$(<$compress_preserved)" == "keep existing archive" ]] || fail_test "compress failure replaced the existing archive"
compress_temp_dirs=("$tmp_root"/.compress.*(N))
(( ${#compress_temp_dirs} == 0 )) || fail_test "compress failure retained temporary output"

compress_status=0
compress_error="$(compress "$tmp_root/missing-source" 2>&1)" || compress_status=$?
[[ "$compress_status" == 1 ]] || fail_test "compress missing source returned $compress_status"
assert_contains "$compress_error" "source not found"

extract_help="$(extract --help)" || fail_test "extract help failed"
[[ "${extract_help%%$'\n'*}" == "Usage:" ]] || fail_test "extract help does not begin with Usage"
assert_contains "$extract_help" $'\n\nDescription:'
assert_contains "$extract_help" $'\n\nOptions:'
assert_contains "$extract_help" $'\n\nExamples:'

extract_source="$tmp_root/extract-source"
extract_workspace="$tmp_root/extract workspace"
extract_archive="$tmp_root/bundle.tar.gz"
extract_destination="$tmp_root/extract destination"
mkdir -p "$extract_source" "$extract_workspace"
print -r -- "archive payload" >"$extract_source/payload.txt"
command tar -czf "$extract_archive" -C "$extract_source" payload.txt || fail_test "could not create extract tar fixture"

extract_output="$(cd "$extract_workspace" && extract "$extract_archive")" || fail_test "extract default destination failed"
assert_contains "$extract_output" "Extracted:"
[[ "$(<"$extract_workspace/bundle/payload.txt")" == "archive payload" ]] || fail_test "extract tar payload is incorrect"

mkdir -p "$extract_destination"
print -r -- "keep" >"$extract_destination/existing.txt"
extract_status=0
extract_error="$(extract "$extract_archive" "$extract_destination" 2>&1)" || extract_status=$?
[[ "$extract_status" == 1 ]] || fail_test "extract nonempty destination returned $extract_status"
assert_contains "$extract_error" "destination is not empty"
[[ "$(<"$extract_destination/existing.txt")" == "keep" ]] || fail_test "extract changed a refused destination"

extract --force "$extract_archive" "$extract_destination" >/dev/null || fail_test "extract force failed"
[[ "$(<"$extract_destination/payload.txt")" == "archive payload" ]] || fail_test "extract force omitted the payload"
[[ "$(<"$extract_destination/existing.txt")" == "keep" ]] || fail_test "extract force removed an unrelated file"

extract_gzip="$tmp_root/payload.txt.gz"
command gzip -c "$extract_source/payload.txt" >"$extract_gzip" || fail_test "could not create extract gzip fixture"
(cd "$extract_workspace" && extract "$extract_gzip" >/dev/null) || fail_test "extract gzip failed"
[[ "$(<"$extract_workspace/payload.txt")" == "archive payload" ]] || fail_test "extract gzip payload is incorrect"

extract_unknown="$tmp_root/archive.rar"
print -r -- "unknown" >"$extract_unknown"
extract_status=0
extract_error="$(extract "$extract_unknown" "$tmp_root/unsupported-output" 2>&1)" || extract_status=$?
[[ "$extract_status" == 2 ]] || fail_test "extract unsupported format returned $extract_status"
assert_contains "$extract_error" "unsupported archive format"
[[ ! -e "$tmp_root/unsupported-output" ]] || fail_test "extract created a destination for an unsupported format"

extract_status=0
extract_error="$(extract "$tmp_root/missing.tar.gz" 2>&1)" || extract_status=$?
[[ "$extract_status" == 1 ]] || fail_test "extract missing archive returned $extract_status"
assert_contains "$extract_error" "archive not found or unreadable"

print -r -- "PASS: file and disk functions checks"
