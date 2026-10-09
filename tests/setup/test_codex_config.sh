#!/usr/bin/env bash
# setup-test: Codex config
# Isolated regression checks for portable Codex config merging and backups.
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$REPO_DIR/setup/repair.sh"
HELPER="$REPO_DIR/setup/codex_config_helpers.sh"
SOURCE_CONFIG="$REPO_DIR/dotfiles/codex/config.toml"
BELL_NOTIFIER="$REPO_DIR/dotfiles/.bin/codex-turn-bell"
REAL_YQ="$(command -v yq)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/setup-codex-test.XXXXXX")"
TEST_BIN="$TMP_ROOT/bin"
NO_CODEX_BIN="$TMP_ROOT/no-codex-bin"
INCOMPATIBLE_YQ_BIN="$TMP_ROOT/incompatible-yq-bin"
mkdir -p "$TEST_BIN" "$NO_CODEX_BIN" "$INCOMPATIBLE_YQ_BIN"

cleanup() {
  local exit_status=$?
  rm -rf -- "$TMP_ROOT"
  return "$exit_status"
}
trap cleanup EXIT INT TERM

source "$(dirname -- "${BASH_SOURCE[0]}")/../lib/assert.sh"

assert_yq() {
  local file="$1"
  local expression="$2"
  local expected="$3"
  local actual
  actual="$(yq -r -p=toml -o=tsv "$expression" "$file")"
  [[ "$actual" == "$expected" ]] || fail_test "$expression was '$actual' instead of '$expected'"
}

backup_count() {
  local home_dir="$1"
  [[ -d "$home_dir/.dotfiles-backup/codex" ]] || {
    printf '0\n'
    return
  }
  find "$home_dir/.dotfiles-backup/codex" -mindepth 1 -maxdepth 1 -name 'config.toml.*' | wc -l | tr -d ' '
}

assert_no_atomic_temp() {
  local home_dir="$1"
  local found=""
  [[ -d "$home_dir/.codex" ]] && found="$(find "$home_dir/.codex" -name '.config.toml.setup.*' -print -quit)"
  [[ -z "$found" ]] || fail_test "atomic candidate was not cleaned up: $found"
}

run_sync() {
  local home_dir="$1"
  local platform="$2"
  local dry_run="$3"
  local command_path="${4:-$TEST_BIN:/usr/bin:/bin}"
  TEST_CODEX_CONFIG_STATUS="${TEST_CODEX_CONFIG_STATUS:-ok}" \
    HOME="$home_dir" PATH="$command_path" /bin/bash -c '
    source "$1"
    PLATFORM="$2"
    DRY_RUN="$3"
    SETUP_REPAIR_COMPACT=false
    FAILED_TASKS=()
    sync_codex_config
  ' _ "$INSTALLER" "$platform" "$dry_run"
}

ln -s "$REAL_YQ" "$TEST_BIN/yq"
ln -s "$REAL_YQ" "$NO_CODEX_BIN/yq"
{
  printf '#!/bin/sh\n'
  printf '%s\n' 'for argument in "$@"; do'
  printf '%s\n' '  if [ "$argument" = "-o=toml" ]; then'
  printf '%s\n' '    printf "%s\n" "Error: only scalars are supported for TOML output" >&2'
  printf '%s\n' '    exit 1'
  printf '%s\n' '  fi'
  printf '%s\n' 'done'
  printf '%s\n' 'exec "$REAL_YQ" "$@"'
} >"$INCOMPATIBLE_YQ_BIN/yq"
chmod +x "$INCOMPATIBLE_YQ_BIN/yq"
{
  printf '#!/bin/sh\n'
  printf '%s\n' 'config_status="${TEST_CODEX_CONFIG_STATUS:-ok}"'
  printf '%s\n' 'printf '\''{"checks":{"config.load":{"status":"%s"}}}\n'\'' "$config_status"'
  printf 'exit 1\n'
} >"$TEST_BIN/codex"
chmod +x "$TEST_BIN/codex"

/bin/bash -n "$HELPER" "$INSTALLER"
/bin/sh -n "$BELL_NOTIFIER"
yq -p=toml -o=json '.' "$SOURCE_CONFIG" >/dev/null || fail_test "tracked Codex config is invalid TOML"
(
  source "$HELPER"
  setup_codex_yq_supports_managed_toml "$SOURCE_CONFIG"
) || fail_test "installed yq cannot round-trip the managed Codex TOML"
incompatible_output="$(REAL_YQ="$REAL_YQ" PATH="$INCOMPATIBLE_YQ_BIN:/usr/bin:/bin" /bin/bash -c '
  source "$1"
  if setup_codex_yq_supports_managed_toml "$2"; then
    exit 1
  fi
  printf "%s\n" "$SETUP_CODEX_CONFIG_ERROR"
' _ "$HELPER" "$SOURCE_CONFIG")"
assert_contains "$incompatible_output" "Active yq cannot encode the managed Codex TOML"
assert_contains "$incompatible_output" "upgrade Homebrew yq"
assert_not_contains "$incompatible_output" "only scalars are supported"
[[ "$(yq -r -p=toml -o=tsv '.hooks | keys | length' "$SOURCE_CONFIG")" == 7 ]] ||
  fail_test "tracked Codex config does not define all seven zj-radar hook events"
for hook_event in PermissionRequest PostToolUse PreToolUse Stop SubagentStart SubagentStop UserPromptSubmit; do
  assert_yq "$SOURCE_CONFIG" ".hooks.$hook_event | length" '1'
  assert_yq "$SOURCE_CONFIG" ".hooks.${hook_event}[0].hooks | length" '1'
  assert_yq "$SOURCE_CONFIG" ".hooks.${hook_event}[0].hooks[0].type" 'command'
  assert_yq "$SOURCE_CONFIG" ".hooks.${hook_event}[0].hooks[0].command" 'ZJ_RADAR_CODEX_HOOK=v1 zj-radar notify codex'
  assert_yq "$SOURCE_CONFIG" ".hooks.${hook_event}[0].hooks[0].timeout" '10'
done
[[ -x "$BELL_NOTIFIER" ]] || fail_test "portable Codex turn bell is not executable"
bell_output="$TMP_ROOT/bell-output"
bell_expected="$TMP_ROOT/bell-expected"
: >"$bell_output"
printf '\a' >"$bell_expected"
CODEX_NOTIFY_TTY="$bell_output" "$BELL_NOTIFIER" '{"type":"agent-turn-complete"}'
cmp -s "$bell_expected" "$bell_output" || fail_test "portable Codex turn bell did not emit one BEL byte"
CODEX_NOTIFY_TTY="$TMP_ROOT/missing/tty" "$BELL_NOTIFIER" '{"type":"agent-turn-complete"}' ||
  fail_test "portable Codex turn bell failed when no writable terminal was available"

fresh_home="$TMP_ROOT/fresh"
notifier="$fresh_home/.codex/computer-use/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient"
mkdir -p "$(dirname "$notifier")"
printf '#!/bin/sh\nexit 0\n' >"$notifier"
chmod +x "$notifier"
fresh_output="$(run_sync "$fresh_home" macos false)"
assert_contains "$fresh_output" "Merged managed Codex settings"
assert_yq "$fresh_home/.codex/config.toml" '.model' 'gpt-5.6-sol'
assert_yq "$fresh_home/.codex/config.toml" '.notify[0]' "$notifier"
assert_yq "$fresh_home/.codex/config.toml" '.tui.status_line | length' '10'
assert_yq "$fresh_home/.codex/config.toml" '.desktop.appearanceTheme' 'dark'
assert_yq "$fresh_home/.codex/config.toml" '.shell_environment_policy.set.LANG' 'en_US.UTF-8'
assert_yq "$fresh_home/.codex/config.toml" '.shell_environment_policy.set.LC_ALL' 'en_US.UTF-8'
assert_yq "$fresh_home/.codex/config.toml" '.hooks.Stop[0].hooks[0].command' 'ZJ_RADAR_CODEX_HOOK=v1 zj-radar notify codex'
[[ "$(source "$HELPER"; setup_codex_file_mode "$fresh_home/.codex/config.toml")" == 600 ]] || fail_test "fresh config mode is not 600"
[[ "$(backup_count "$fresh_home")" == 0 ]] || fail_test "fresh install created a backup"
assert_no_atomic_temp "$fresh_home"

merge_home="$TMP_ROOT/merge"
merge_config="$merge_home/.codex/config.toml"
mkdir -p "$merge_home/.codex"
printf '%s\n' "model = \"old-model\"
notify = [\"/old/notifier\", \"turn-ended\"]

[projects.\"$merge_home/project\"]
trust_level = \"trusted\"

[notice]
fast_default_opt_out = true

[marketplaces.local]
source = \"$merge_home/marketplace\"

[tui.model_availability_nux]
\"gpt-test\" = 4

[desktop.open-in-target-preferences.perPath]
\"$merge_home/project\" = \"fileManager\"" >"$merge_config"
cp "$merge_config" "$merge_home/original.toml"
merge_output="$(run_sync "$merge_home" macos false)"
assert_contains "$merge_output" "Backed up the existing Codex config"
assert_yq "$merge_config" '.model' 'gpt-5.6-sol'
assert_yq "$merge_config" ".projects.\"$merge_home/project\".trust_level" 'trusted'
assert_yq "$merge_config" '.notice.fast_default_opt_out' 'true'
assert_yq "$merge_config" '.marketplaces.local.source' "$merge_home/marketplace"
assert_yq "$merge_config" '.tui.model_availability_nux."gpt-test"' '4'
assert_yq "$merge_config" ".desktop.open-in-target-preferences.perPath.\"$merge_home/project\"" 'fileManager'
merge_backup="$(find "$merge_home/.dotfiles-backup/codex" -name 'config.toml.*' -type f -print -quit)"
cmp -s "$merge_home/original.toml" "$merge_backup" || fail_test "backup does not exactly match the original config"
[[ "$(backup_count "$merge_home")" == 1 ]] || fail_test "managed drift did not create exactly one backup"

before_hash="$(cksum "$merge_config")"
run_sync "$merge_home" macos false >/dev/null
[[ "$(cksum "$merge_config")" == "$before_hash" ]] || fail_test "idempotent sync rewrote the config"
[[ "$(backup_count "$merge_home")" == 1 ]] || fail_test "idempotent sync created another backup"
chmod 644 "$merge_config"
run_sync "$merge_home" macos false >/dev/null
[[ "$(source "$HELPER"; setup_codex_file_mode "$merge_config")" == 600 ]] || fail_test "idempotent sync did not repair config permissions"
[[ "$(backup_count "$merge_home")" == 1 ]] || fail_test "permission-only repair created a backup"
assert_no_atomic_temp "$merge_home"

comparison_actual="$TMP_ROOT/comparison-actual.toml"
comparison_expected="$TMP_ROOT/comparison-expected.toml"
cp "$merge_config" "$comparison_actual"
TEST_CODEX_PROJECT="$merge_home/another-local-project" yq -i -p=toml -o=toml \
  '.model = "drifted-model" |
   del(.service_tier) |
   .notify = ["/mac-only/notifier", "turn-ended"] |
   .tui.status_line = ["git-branch"] |
   .projects[strenv(TEST_CODEX_PROJECT)].trust_level = "trusted"' \
  "$comparison_actual"
comparison_output="$(/bin/bash -c '
  source "$1"
  setup_codex_render_config "$2" "$3" ubuntu "$4" "$5"
  setup_codex_list_discrepancies "$3" "$5"
' _ "$HELPER" "$SOURCE_CONFIG" "$comparison_actual" "$merge_home" "$comparison_expected")"
assert_contains "$comparison_output" 'Codex setting mismatch: model; expected "gpt-5.6-sol", actual "drifted-model"'
assert_contains "$comparison_output" "Codex setting mismatch: notify; expected [\"$BELL_NOTIFIER\"], actual [\"/mac-only/notifier\",\"turn-ended\"]"
assert_contains "$comparison_output" 'Codex setting mismatch: service_tier; expected "default", actual <missing>'
assert_contains "$comparison_output" 'Codex setting mismatch: tui.status_line; expected ["model-with-reasoning","current-dir","context-remaining","used-tokens","project-name","git-branch","pull-request-number","branch-changes","run-state","task-progress"], actual ["git-branch"]'
[[ "$(grep -c '^Codex setting mismatch:' <<<"$comparison_output")" -eq 4 ]] ||
  fail_test "Codex discrepancy output did not contain exactly four managed differences"
assert_not_contains "$comparison_output" "$merge_home/another-local-project"
equal_comparison_output="$(/bin/bash -c 'source "$1"; setup_codex_list_discrepancies "$2" "$2"' \
  _ "$HELPER" "$comparison_expected")"
[[ -z "$equal_comparison_output" ]] || fail_test "equal Codex configs reported discrepancies"

linux_home="$TMP_ROOT/linux"
mkdir -p "$linux_home/.codex"
printf '%s\n' "notify = [\"/mac-only/notifier\", \"turn-ended\"]
[projects.\"$linux_home/project\"]
trust_level = \"trusted\"
[desktop.open-in-target-preferences.perPath]
\"$linux_home/project\" = \"fileManager\"" >"$linux_home/.codex/config.toml"
run_sync "$linux_home" ubuntu false >/dev/null
assert_yq "$linux_home/.codex/config.toml" '.notify[0]' "$BELL_NOTIFIER"
assert_yq "$linux_home/.codex/config.toml" ".projects.\"$linux_home/project\".trust_level" 'trusted'
assert_yq "$linux_home/.codex/config.toml" ".desktop.open-in-target-preferences.perPath.\"$linux_home/project\"" 'fileManager'
assert_yq "$linux_home/.codex/config.toml" '.desktop.appearanceTheme' 'null'

fresh_linux_home="$TMP_ROOT/fresh-linux"
run_sync "$fresh_linux_home" ubuntu false >/dev/null
assert_yq "$fresh_linux_home/.codex/config.toml" '.desktop' 'null'
assert_yq "$fresh_linux_home/.codex/config.toml" '.notify[0]' "$BELL_NOTIFIER"
assert_yq "$fresh_linux_home/.codex/config.toml" '.tui.notifications' 'true'
assert_yq "$fresh_linux_home/.codex/config.toml" '.tui.notification_condition' 'always'

unavailable_home="$TMP_ROOT/unavailable"
unavailable_output="$(run_sync "$unavailable_home" macos false)"
assert_contains "$unavailable_output" "Computer Use notifier is unavailable; using the terminal bell fallback"
assert_yq "$unavailable_home/.codex/config.toml" '.notify[0]' "$BELL_NOTIFIER"

dry_home="$TMP_ROOT/dry"
dry_output="$(run_sync "$dry_home" macos true)"
assert_contains "$dry_output" "Atomically merge managed settings"
[[ ! -e "$dry_home/.codex/config.toml" ]] || fail_test "dry-run created a Codex config"
[[ "$(backup_count "$dry_home")" == 0 ]] || fail_test "dry-run created a backup"

dry_existing_home="$TMP_ROOT/dry-existing"
mkdir -p "$dry_existing_home/.codex"
printf 'model = "keep-me"\n' >"$dry_existing_home/.codex/config.toml"
cp "$dry_existing_home/.codex/config.toml" "$dry_existing_home/original.toml"
run_sync "$dry_existing_home" ubuntu true >/dev/null
cmp -s "$dry_existing_home/original.toml" "$dry_existing_home/.codex/config.toml" || fail_test "dry-run changed an existing config"
[[ "$(backup_count "$dry_existing_home")" == 0 ]] || fail_test "dry-run backed up an existing config"

malformed_home="$TMP_ROOT/malformed"
mkdir -p "$malformed_home/.codex"
printf 'model = [\n' >"$malformed_home/.codex/config.toml"
cp "$malformed_home/.codex/config.toml" "$malformed_home/original.toml"
malformed_status=0
malformed_output="$(run_sync "$malformed_home" ubuntu false 2>&1)" || malformed_status=$?
[[ "$malformed_status" -ne 0 ]] || fail_test "malformed existing config unexpectedly passed"
assert_contains "$malformed_output" "Codex config is not valid TOML"
cmp -s "$malformed_home/original.toml" "$malformed_home/.codex/config.toml" || fail_test "malformed config was changed"
[[ "$(backup_count "$malformed_home")" == 0 ]] || fail_test "malformed config was backed up"
assert_no_atomic_temp "$malformed_home"

strict_home="$TMP_ROOT/strict-failure"
strict_status=0
strict_output="$(TEST_CODEX_CONFIG_STATUS=error run_sync "$strict_home" ubuntu false 2>&1)" || strict_status=$?
[[ "$strict_status" -ne 0 ]] || fail_test "strict Codex validation failure unexpectedly passed"
assert_contains "$strict_output" "Codex strict config validation failed"
[[ ! -e "$strict_home/.codex/config.toml" ]] || fail_test "strict validation failure installed a config"
[[ "$(backup_count "$strict_home")" == 0 ]] || fail_test "strict validation failure created a backup"
assert_no_atomic_temp "$strict_home"

no_codex_home="$TMP_ROOT/no-codex"
no_codex_output="$(run_sync "$no_codex_home" ubuntu false "$NO_CODEX_BIN:/usr/bin:/bin")"
assert_contains "$no_codex_output" "Codex CLI is not installed"
[[ -f "$no_codex_home/.codex/config.toml" ]] || fail_test "TOML-only fallback did not install the config"

symlink_home="$TMP_ROOT/symlink"
mkdir -p "$symlink_home/.codex"
printf 'model = "symlink-target"\n[projects."local"]\ntrust_level = "trusted"\n' >"$symlink_home/target.toml"
target_hash="$(cksum "$symlink_home/target.toml")"
ln -s "$symlink_home/target.toml" "$symlink_home/.codex/config.toml"
run_sync "$symlink_home" ubuntu false >/dev/null
[[ ! -L "$symlink_home/.codex/config.toml" && -f "$symlink_home/.codex/config.toml" ]] || fail_test "managed config remained a symlink"
[[ "$(cksum "$symlink_home/target.toml")" == "$target_hash" ]] || fail_test "symlink target was changed"
symlink_backup="$(find "$symlink_home/.dotfiles-backup/codex" -name 'config.toml.*' -type l -print -quit)"
[[ -n "$symlink_backup" ]] || fail_test "symlink config was not backed up as a symlink"
[[ "$(readlink "$symlink_backup")" == "$symlink_home/target.toml" ]] || fail_test "symlink backup target changed"

broken_home="$TMP_ROOT/broken"
mkdir -p "$broken_home/.codex"
ln -s "$broken_home/missing.toml" "$broken_home/.codex/config.toml"
run_sync "$broken_home" ubuntu false >/dev/null
[[ ! -L "$broken_home/.codex/config.toml" && -f "$broken_home/.codex/config.toml" ]] || fail_test "broken symlink was not replaced"
broken_backup="$(find "$broken_home/.dotfiles-backup/codex" -name 'config.toml.*' -type l -print -quit)"
[[ -n "$broken_backup" ]] || fail_test "broken symlink was not backed up"
[[ "$(readlink "$broken_backup")" == "$broken_home/missing.toml" ]] || fail_test "broken symlink backup target changed"

invalid_source="$TMP_ROOT/invalid-source.toml"
invalid_output="$TMP_ROOT/invalid-output.toml"
printf 'model = [\n' >"$invalid_source"
if /bin/bash -c 'source "$1"; setup_codex_render_config "$2" "$3" ubuntu "$4" "$5"' \
  _ "$HELPER" "$invalid_source" "$SOURCE_CONFIG" "$TMP_ROOT" "$invalid_output"; then
  fail_test "malformed tracked source unexpectedly rendered"
fi

printf '[PASS] Codex config merge, backup, and validation checks\n'
