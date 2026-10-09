#!/usr/bin/env bash
# Shared helpers for rendering and validating the setup-managed Codex config.
# Keep this file compatible with the Bash 3.2 shipped by macOS.

SETUP_CODEX_CONFIG_ERROR=""
SETUP_CODEX_NOTIFY_STATE=""
SETUP_CODEX_VALIDATION_TEMP=""

setup_codex_notifier_path() {
  printf '%s/.codex/computer-use/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient' "$1"
}

setup_codex_bell_notifier_path() {
  local codex_config_dir="${1%/*}"

  printf '%s/.bin/codex-turn-bell' "${codex_config_dir%/*}"
}

setup_codex_validate_toml() {
  local config_file="$1"

  SETUP_CODEX_CONFIG_ERROR=""
  if ! command -v yq >/dev/null 2>&1; then
    SETUP_CODEX_CONFIG_ERROR="yq is required to manage Codex settings"
    return 1
  fi
  if [[ ! -r "$config_file" ]]; then
    SETUP_CODEX_CONFIG_ERROR="Codex config is not readable: $config_file"
    return 1
  fi
  if ! yq -p=toml -o=json '.' "$config_file" >/dev/null 2>&1; then
    SETUP_CODEX_CONFIG_ERROR="Codex config is not valid TOML: $config_file"
    return 1
  fi
}

# Verify the active yq can encode the complete managed document without losing
# nested tables or arrays. Version checks alone do not catch alternate binaries
# or future TOML encoder regressions.
setup_codex_yq_supports_managed_toml() {
  local source_file="$1"
  local roundtrip_file
  local source_fingerprint
  local roundtrip_fingerprint
  local yq_version

  SETUP_CODEX_CONFIG_ERROR=""
  if ! command -v yq >/dev/null 2>&1; then
    SETUP_CODEX_CONFIG_ERROR="yq is required to manage Codex settings"
    return 1
  fi
  setup_codex_validate_toml "$source_file" || return 1
  yq_version="$(yq --version 2>/dev/null || printf 'unknown version')"
  roundtrip_file="$(mktemp "${TMPDIR:-/tmp}/setup-codex-yq-roundtrip.XXXXXX")" || {
    SETUP_CODEX_CONFIG_ERROR="Could not create a temporary Codex TOML capability file"
    return 1
  }

  if ! yq -p=toml -o=toml '.' "$source_file" >"$roundtrip_file" 2>/dev/null; then
    rm -f -- "$roundtrip_file"
    SETUP_CODEX_CONFIG_ERROR="Active yq cannot encode the managed Codex TOML ($yq_version); upgrade Homebrew yq"
    return 1
  fi
  if ! setup_codex_validate_toml "$roundtrip_file"; then
    rm -f -- "$roundtrip_file"
    SETUP_CODEX_CONFIG_ERROR="Active yq produced invalid managed Codex TOML ($yq_version); upgrade Homebrew yq"
    return 1
  fi
  source_fingerprint="$(setup_codex_semantic_fingerprint "$source_file" 2>/dev/null)" || source_fingerprint=""
  roundtrip_fingerprint="$(setup_codex_semantic_fingerprint "$roundtrip_file" 2>/dev/null)" || roundtrip_fingerprint=""
  rm -f -- "$roundtrip_file"
  if [[ -z "$source_fingerprint" || "$source_fingerprint" != "$roundtrip_fingerprint" ]]; then
    SETUP_CODEX_CONFIG_ERROR="Active yq loses managed Codex settings during TOML encoding ($yq_version); upgrade Homebrew yq"
    return 1
  fi
}

setup_codex_render_config() {
  local source_file="$1"
  local existing_file="$2"
  local platform="$3"
  local home_dir="$4"
  local output_file="$5"
  local merge_expression
  local bell_notifier
  local notifier
  local source_expression

  SETUP_CODEX_CONFIG_ERROR=""
  SETUP_CODEX_NOTIFY_STATE="disabled"
  setup_codex_validate_toml "$source_file" || return 1

  if [[ "$platform" == macos ]]; then
    merge_expression='select(fileIndex == 0) * select(fileIndex == 1)'
    source_expression='.'
  else
    merge_expression='select(fileIndex == 0) * (select(fileIndex == 1) | del(.desktop))'
    source_expression='del(.desktop)'
  fi

  if [[ -e "$existing_file" || -L "$existing_file" ]]; then
    if [[ -d "$existing_file" ]]; then
      SETUP_CODEX_CONFIG_ERROR="Codex config path is a directory: $existing_file"
      return 1
    fi
    if [[ -e "$existing_file" ]]; then
      setup_codex_validate_toml "$existing_file" || return 1
      if ! yq eval-all -p=toml -o=toml \
        "$merge_expression" \
        "$existing_file" "$source_file" >"$output_file"; then
        SETUP_CODEX_CONFIG_ERROR="Could not merge managed Codex settings"
        return 1
      fi
    elif ! yq -p=toml -o=toml "$source_expression" "$source_file" >"$output_file"; then
      SETUP_CODEX_CONFIG_ERROR="Could not render managed Codex settings"
      return 1
    fi
  elif ! yq -p=toml -o=toml "$source_expression" "$source_file" >"$output_file"; then
    SETUP_CODEX_CONFIG_ERROR="Could not render managed Codex settings"
    return 1
  fi

  notifier="$(setup_codex_notifier_path "$home_dir")"
  bell_notifier="$(setup_codex_bell_notifier_path "$source_file")"
  if [[ "$platform" == macos && -x "$notifier" ]]; then
    if ! SETUP_CODEX_NOTIFIER="$notifier" yq -i -p=toml -o=toml \
      '.notify = [strenv(SETUP_CODEX_NOTIFIER), "turn-ended"]' "$output_file"; then
      SETUP_CODEX_CONFIG_ERROR="Could not add the macOS Computer Use notifier"
      return 1
    fi
    SETUP_CODEX_NOTIFY_STATE="enabled"
  elif [[ -x "$bell_notifier" ]]; then
    if ! SETUP_CODEX_NOTIFIER="$bell_notifier" yq -i -p=toml -o=toml \
      '.notify = [strenv(SETUP_CODEX_NOTIFIER)]' "$output_file"; then
      SETUP_CODEX_CONFIG_ERROR="Could not add the portable Codex turn bell"
      return 1
    fi
    if [[ "$platform" == macos ]]; then
      SETUP_CODEX_NOTIFY_STATE="fallback"
    else
      SETUP_CODEX_NOTIFY_STATE="enabled"
    fi
  else
    SETUP_CODEX_CONFIG_ERROR="Portable Codex turn bell is unavailable: $bell_notifier"
    return 1
  fi

  setup_codex_validate_toml "$output_file"
}

setup_codex_semantic_fingerprint() {
  yq -p=toml -o=json -I=0 'sort_keys(..)' "$1"
}

setup_codex_semantically_equal() {
  local left_fingerprint
  local right_fingerprint

  setup_codex_validate_toml "$1" || return 1
  setup_codex_validate_toml "$2" || return 1
  left_fingerprint="$(setup_codex_semantic_fingerprint "$1")" || return 1
  right_fingerprint="$(setup_codex_semantic_fingerprint "$2")" || return 1
  [[ "$left_fingerprint" == "$right_fingerprint" ]]
}

setup_codex_list_discrepancies() {
  local actual_file="$1"
  local expected_file="$2"
  local actual_json
  local expected_json

  SETUP_CODEX_CONFIG_ERROR=""
  if ! command -v jq >/dev/null 2>&1; then
    SETUP_CODEX_CONFIG_ERROR="jq is required to compare Codex settings"
    return 1
  fi
  actual_json="$(yq -p=toml -o=json '.' "$actual_file" 2>/dev/null)" || {
    SETUP_CODEX_CONFIG_ERROR="Could not read the active Codex config for comparison"
    return 1
  }
  expected_json="$(yq -p=toml -o=json '.' "$expected_file" 2>/dev/null)" || {
    SETUP_CODEX_CONFIG_ERROR="Could not read the expected Codex config for comparison"
    return 1
  }

  jq -nr --argjson actual "$actual_json" --argjson expected "$expected_json" '
    def leaf_entries:
      def walk($path):
        if type == "object" then
          to_entries[] | .key as $key | .value | walk($path + [$key])
        else
          {path: $path, value: .}
        end;
      walk([]);
    def leaf_index:
      reduce leaf_entries as $entry ({}; .[($entry.path | tojson)] = $entry.value);
    ($actual | leaf_index) as $actual_index
    | ($expected | leaf_index) as $expected_index
    | (($actual_index | keys) + ($expected_index | keys) | unique[]) as $key
    | select(
        ($actual_index | has($key)) != ($expected_index | has($key))
        or $actual_index[$key] != $expected_index[$key]
      )
    | ($key | fromjson) as $path
    | "Codex setting mismatch: \($path | join(".")); expected \(
        if $expected_index | has($key) then $expected_index[$key] | tojson else "<missing>" end
      ), actual \(
        if $actual_index | has($key) then $actual_index[$key] | tojson else "<missing>" end
      )"
  ' || {
    SETUP_CODEX_CONFIG_ERROR="Could not compare active and expected Codex settings"
    return 1
  }
}

setup_codex_file_mode() {
  if [[ "$(uname -s)" == Darwin ]]; then
    stat -f '%Lp' "$1" 2>/dev/null
  else
    stat -c '%a' "$1" 2>/dev/null
  fi
}

setup_codex_validate_with_cli() {
  local config_file="$1"
  local check_dir
  local report_file
  local error_file
  local config_status

  SETUP_CODEX_CONFIG_ERROR=""
  command -v codex >/dev/null 2>&1 || return 2
  check_dir="$(mktemp -d "${TMPDIR:-/tmp}/setup-codex-check.XXXXXX")" || {
    SETUP_CODEX_CONFIG_ERROR="Could not create a temporary Codex validation directory"
    return 1
  }
  SETUP_CODEX_VALIDATION_TEMP="$check_dir"
  report_file="$check_dir/doctor.json"
  error_file="$check_dir/doctor.stderr"
  if ! cp "$config_file" "$check_dir/config.toml"; then
    SETUP_CODEX_CONFIG_ERROR="Could not stage the Codex config for strict validation"
    rm -rf -- "$check_dir"
    SETUP_CODEX_VALIDATION_TEMP=""
    return 1
  fi

  CODEX_HOME="$check_dir" codex --strict-config doctor --json \
    >"$report_file" 2>"$error_file" || true
  config_status="$(yq -r -p=json -o=tsv '.checks."config.load".status // ""' "$report_file" 2>/dev/null || true)"
  if [[ "$config_status" != ok ]]; then
    SETUP_CODEX_CONFIG_ERROR="Codex strict config validation failed"
    if [[ -s "$error_file" ]]; then
      SETUP_CODEX_CONFIG_ERROR="$SETUP_CODEX_CONFIG_ERROR: $(sed -n '1p' "$error_file")"
    fi
    rm -rf -- "$check_dir"
    SETUP_CODEX_VALIDATION_TEMP=""
    return 1
  fi

  rm -rf -- "$check_dir"
  SETUP_CODEX_VALIDATION_TEMP=""
  return 0
}
