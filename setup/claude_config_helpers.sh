#!/usr/bin/env bash
# Shared helpers for merging the setup-managed Claude Code settings.
# Keep this file compatible with the Bash 3.2 shipped by macOS.
#
# ~/.claude/settings.json is written by Claude Code and Codex Balance too, so
# setup merges only the keys it owns: objects merge key by key, and an array
# such as hooks.PreCompact is replaced whole.

SETUP_CLAUDE_CONFIG_ERROR=""

setup_claude_valid_json() {
  jq -e 'type == "object"' "$1" >/dev/null 2>&1
}

setup_claude_render_settings() {
  local source_file="$1"
  local existing_file="$2"
  local output_file="$3"

  SETUP_CLAUDE_CONFIG_ERROR=""
  if [[ ! -e "$existing_file" ]]; then
    jq . "$source_file" >"$output_file" && return 0
  elif ! setup_claude_valid_json "$existing_file"; then
    SETUP_CLAUDE_CONFIG_ERROR="Claude settings are not a valid JSON object: $existing_file"
    return 1
  elif jq -s '.[0] * .[1]' "$existing_file" "$source_file" >"$output_file"; then
    return 0
  fi
  SETUP_CLAUDE_CONFIG_ERROR="Could not merge managed Claude settings"
  return 1
}

setup_claude_semantically_equal() {
  [[ "$(jq -S . "$1" 2>/dev/null)" == "$(jq -S . "$2" 2>/dev/null)" ]]
}

# Print one line for each managed value the active settings do not match.
setup_claude_list_discrepancies() {
  jq -nr --slurpfile active "$1" --slurpfile managed "$2" '
    $active[0] as $current
    | $managed[0]
    | . as $wanted
    | paths(scalars) as $path
    | select((try ($current | getpath($path)) catch null) != ($wanted | getpath($path)))
    | "Claude setting mismatch: \($path | map(tostring) | join(".")); run ./setup.sh --fix"
  '
}
