#!/usr/bin/env bash
# Shared one-row terminal status output. Compatible with macOS Bash 3.2.

SETUP_STATUS_ACTIVE=false
SETUP_STATUS_LABEL=""
SETUP_STATUS_SPINNER_PID=""
SETUP_STATUS_INTERVAL="${SETUP_STATUS_INTERVAL:-0.08}"
SETUP_STATUS_COLOR_RESET=$'\033[0m'
SETUP_STATUS_COLOR_GREEN=$'\033[32m'
SETUP_STATUS_COLOR_CYAN=$'\033[36m'
SETUP_STATUS_COLOR_YELLOW=$'\033[33m'
SETUP_STATUS_COLOR_RED=$'\033[31m'
SETUP_STATUS_COLOR_BLUE=$'\033[34m'
SETUP_STATUS_COLOR_BOLD=$'\033[1m'

setup_status_is_interactive() {
  [[ "${TERM:-}" != dumb ]] &&
    [[ "${SETUP_STATUS_FORCE_TTY:-false}" == true || -t 1 ]]
}

setup_status_color_enabled() {
  setup_status_is_interactive && [[ -z "${NO_COLOR+x}" ]]
}

setup_status_stop_animation() {
  [[ -n "$SETUP_STATUS_SPINNER_PID" ]] || return 0
  kill -TERM "$SETUP_STATUS_SPINNER_PID" 2>/dev/null || true
  wait "$SETUP_STATUS_SPINNER_PID" 2>/dev/null || true
  SETUP_STATUS_SPINNER_PID=""
}

setup_status_clear() {
  setup_status_stop_animation
  if [[ "$SETUP_STATUS_ACTIVE" == true ]] && setup_status_is_interactive; then
    printf '\r\033[K'
  fi
  SETUP_STATUS_ACTIVE=false
  SETUP_STATUS_LABEL=""
}

setup_status_start() {
  local label="$1"

  setup_status_clear
  SETUP_STATUS_ACTIVE=true
  SETUP_STATUS_LABEL="$label"
  setup_status_is_interactive || return 0

  (
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local index=0
    local timer_pid=""
    trap '[[ -n "$timer_pid" ]] && kill -TERM "$timer_pid" 2>/dev/null; exit 0' INT TERM
    while true; do
      if setup_status_color_enabled; then
        printf '\r\033[K%s%s%s  %s' "$SETUP_STATUS_COLOR_CYAN" "${frames[$index]}" "$SETUP_STATUS_COLOR_RESET" "$label"
      else
        printf '\r\033[K%s  %s' "${frames[$index]}" "$label"
      fi
      index=$(((index + 1) % ${#frames[@]}))
      sleep "$SETUP_STATUS_INTERVAL" &
      timer_pid=$!
      wait "$timer_pid" 2>/dev/null || true
      timer_pid=""
    done
  ) &
  SETUP_STATUS_SPINNER_PID=$!
}

setup_status_finish() {
  local glyph="$1"
  local message="$2"
  local color="$3"

  setup_status_stop_animation
  if [[ "$SETUP_STATUS_ACTIVE" == true ]] && setup_status_is_interactive; then
    printf '\r\033[K'
  fi
  if setup_status_color_enabled; then
    printf '%s%s%s  %s\n' "$color" "$glyph" "$SETUP_STATUS_COLOR_RESET" "$message"
  else
    printf '%s  %s\n' "$glyph" "$message"
  fi
  SETUP_STATUS_ACTIVE=false
  SETUP_STATUS_LABEL=""
}

setup_status_pass() {
  setup_status_finish '✓' "$1" "$SETUP_STATUS_COLOR_GREEN"
}

setup_status_info() {
  setup_status_finish '•' "$1" "$SETUP_STATUS_COLOR_CYAN"
}

setup_status_warning() {
  setup_status_finish '!' "$1" "$SETUP_STATUS_COLOR_YELLOW"
}

setup_status_fail() {
  setup_status_finish '✗' "$1" "$SETUP_STATUS_COLOR_RED"
}

setup_status_action() {
  setup_status_clear
  if setup_status_color_enabled; then
    printf '%s→%s  %s\n' "$SETUP_STATUS_COLOR_CYAN" "$SETUP_STATUS_COLOR_RESET" "$1"
  else
    printf '→  %s\n' "$1"
  fi
}

setup_status_detail() {
  setup_status_clear
  # Details intentionally carry no semantic marker or color of their own.
  printf '   %s\n' "$1"
}

setup_status_prompt() {
  setup_status_clear
  if setup_status_color_enabled; then
    printf '\n%s→%s  %s' "$SETUP_STATUS_COLOR_CYAN" "$SETUP_STATUS_COLOR_RESET" "$1"
  else
    printf '\n→  %s' "$1"
  fi
}

setup_status_section() {
  setup_status_clear
  if setup_status_color_enabled; then
    printf '\n%s──%s %s\n' "$SETUP_STATUS_COLOR_BLUE" "$SETUP_STATUS_COLOR_RESET" "$1"
  else
    printf '\n── %s\n' "$1"
  fi
}

setup_status_summary() {
  setup_status_clear
  if setup_status_color_enabled; then
    printf '\n%s[SUMMARY]%s %s\n' "$SETUP_STATUS_COLOR_BOLD" "$SETUP_STATUS_COLOR_RESET" "$1"
  else
    printf '\n[SUMMARY] %s\n' "$1"
  fi
}
