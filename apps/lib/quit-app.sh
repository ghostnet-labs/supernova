#!/usr/bin/env bash
# Sourced by app installers after a successful build, before replacing the bundle.

quit_app() {
  local executable_path="$1" running status=0 _
  # pgrep/pkill take a regex: install paths may contain dots, brackets, or other metacharacters.
  running="^$(printf '%s' "$executable_path" | sed 's/[][\\.^$*+?{}()|]/\\&/g')([[:space:]]|$)"
  pkill -f "$running" || status=$?
  case "$status" in
    0) ;;
    1) return 0 ;; # No running copy.
    *) printf 'error: could not stop %s\n' "$executable_path" >&2; return "$status" ;;
  esac
  for _ in {1..50}; do
    status=0
    pgrep -qf "$running" || status=$?
    case "$status" in
      0) sleep 0.1 ;;
      1) return 0 ;;
      *) printf 'error: could not check %s\n' "$executable_path" >&2; return "$status" ;;
    esac
  done
  printf 'error: app is still running; keeping the installed bundle: %s\n' "$executable_path" >&2
  return 1
}
