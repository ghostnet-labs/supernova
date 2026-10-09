#!/usr/bin/env zsh
# Machine upkeep: newdev, homebrew_update, pull_repos, and run_spinner.
# .zshrc sources every file in dotfiles/functions/.

run_spinner() {
  local msg="$1"
  shift
  local output_file

  output_file=$(mktemp)
  printf "[RUNNING] %s\n" "$msg"
  "$@" &> "$output_file"
  run_spinner_status=$?
  run_spinner_output=$(<"$output_file")
  rm -f "$output_file"
}

_newdev_log() {
  local prefix="$1"
  local message="$2"

  printf "[%s] %s\n" "$prefix" "$message"
}

# toolbox: maintenance | Update Homebrew packages and clean up old versions.
# toolbox-example: homebrew_update
homebrew_update() {
  _newdev_log "START" "Updating Homebrew"

  local failures=0
  local reason

  run_spinner "brew update" brew update
  if (( run_spinner_status == 0 )); then
    _newdev_log "COMPLETE" "brew update"
  else
    reason="$(_newdev_summary_line "$run_spinner_output")"
    _newdev_log "FAIL" "brew update — $reason"
    _newdev_record_attention "FAILED" "Homebrew — brew update" "$run_spinner_output" "$reason"
    ((failures++))
  fi

  # Keep formula and cask upgrades separate. A bare `brew upgrade` may also
  # select auto-updating casks, which would repeat the explicit cask pass.
  # --no-ask keeps both calls safe to capture behind the status spinner.
  run_spinner "brew upgrade" brew upgrade --formula --no-ask
  if (( run_spinner_status == 0 )); then
    _newdev_log "COMPLETE" "brew upgrade"
  else
    reason="$(_newdev_summary_line "$run_spinner_output")"
    _newdev_log "FAIL" "brew upgrade — $reason"
    _newdev_record_attention "FAILED" "Homebrew — brew upgrade" "$run_spinner_output" "$reason"
    ((failures++))
  fi

  run_spinner "brew upgrade --cask" brew upgrade --cask --no-ask
  if (( run_spinner_status == 0 )); then
    _newdev_log "COMPLETE" "brew upgrade --cask"
  else
    reason="$(_newdev_summary_line "$run_spinner_output")"
    _newdev_log "FAIL" "brew upgrade --cask — $reason"
    _newdev_record_attention "FAILED" "Homebrew — brew upgrade --cask" "$run_spinner_output" "$reason"
    ((failures++))
  fi

  run_spinner "brew cleanup" brew cleanup
  if (( run_spinner_status == 0 )); then
    _newdev_log "COMPLETE" "brew cleanup"
  else
    reason="$(_newdev_summary_line "$run_spinner_output")"
    _newdev_log "FAIL" "brew cleanup — $reason"
    _newdev_record_attention "FAILED" "Homebrew — brew cleanup" "$run_spinner_output" "$reason"
    ((failures++))
  fi

  if (( failures > 0 )); then
    _newdev_log "FAIL" "Homebrew finished with $failures failure(s)."
    return 1
  fi

  _newdev_log "COMPLETE" "Homebrew updated"
}

_newdev_print_captured_output() {
  local output="$1"
  [[ -n "$output" ]] || return 0
  printf '%s\n' "$output" | sed 's/^/[DETAIL] /'
}

_newdev_summary_line() {
  local output="$1"
  local summary
  summary=$(printf '%s\n' "$output" | awk '
    /^Your configuration specifies to merge with the ref / {
      git_ref = $0
      sub(/^Your configuration specifies to merge with the ref /, "", git_ref)
      next
    }
    git_ref != "" && /^from the remote, but no such ref was fetched\.$/ {
      git_tracking_summary = "Tracking " git_ref " was not fetched from the remote."
      next
    }
    /^Error: / { error = $0; sub(/^Error: /, "", error) }
    NF { last = $0 }
    END {
      line = git_tracking_summary != "" ? git_tracking_summary : (error != "" ? error : last)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      print line
    }
  ')
  [[ -n "$summary" ]] || summary="Command failed without diagnostic output."
  print -r -- "$summary"
}

_newdev_record_attention() {
  local level="$1"
  local scope="$2"
  local output="$3"
  local summary="${4:-}"

  [[ -n "$summary" ]] || summary="$(_newdev_summary_line "$output")"

  _newdev_attention_levels+=("$level")
  _newdev_attention_scopes+=("$scope")
  _newdev_attention_summaries+=("$summary")
  _newdev_attention_details+=("$output")
}

_newdev_print_attention_summary() {
  local failure_count=0
  local index level

  for level in "${_newdev_attention_levels[@]}"; do
    if [[ "$level" == "FAILED" ]]; then
      ((failure_count++))
    fi
  done

  (( failure_count > 0 )) || return 0

  echo ""
  _newdev_log "SUMMARY" "$failure_count failure(s)"

  for (( index = 1; index <= ${#_newdev_attention_levels[@]}; index++ )); do
    level="${_newdev_attention_levels[index]}"
    [[ "$level" == "FAILED" ]] || continue
    _newdev_log "FAIL" "${_newdev_attention_scopes[index]}"
    _newdev_log "DETAIL" "${_newdev_attention_summaries[index]}"
    if (( _newdev_verbose )) && [[ -n "${_newdev_attention_details[index]}" ]]; then
      _newdev_log "DETAIL" "Full output:"
      _newdev_print_captured_output "${_newdev_attention_details[index]}"
    fi
  done
}

_newdev_warn_repo() {
  local display_name="$1"
  local reason="$2"

  _newdev_log "SKIP" "$display_name — $reason"
}

# toolbox: maintenance git | Update safe Git repositories.
# toolbox-example: pull_repos
pull_repos() {
  _newdev_log "START" "Pulling repositories"

  local updated=0
  local up_to_date=0
  local skipped=0
  local failed=0
  local discovered=0
  local repo_root="$HOME/dev"
  local repo_status
  local summary
  local reason

  if [[ ! -d "$repo_root" ]]; then
    reason="No Git repositories found beneath $repo_root."
    _newdev_log "SKIP" "Repositories — $reason"
    return 0
  fi

  find "$repo_root" -maxdepth 2 -name .git -type d | while IFS= read -r d; do
    local repo_path=$(dirname "$d")
    local repo_name=$(basename "$repo_path")
    local parent_name=$(basename "$(dirname "$repo_path")")
    local display_name="$parent_name/$repo_name"
    ((discovered++))

    if ! repo_status=$(git -C "$repo_path" status --porcelain --untracked-files=no 2>&1); then
      reason="$(_newdev_summary_line "$repo_status")"
      _newdev_log "FAIL" "$display_name — $reason"
      _newdev_record_attention "FAILED" "$display_name — git status" "$repo_status" "$reason"
      ((failed++))
      continue
    fi

    if [[ -n "$repo_status" ]]; then
      _newdev_warn_repo "$display_name" "tracked local changes"
      ((skipped++))
      continue
    fi

    if ! git -C "$repo_path" symbolic-ref -q HEAD >/dev/null 2>&1; then
      _newdev_warn_repo "$display_name" "detached HEAD"
      ((skipped++))
      continue
    fi

    if ! git -C "$repo_path" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1; then
      _newdev_warn_repo "$display_name" "no upstream branch"
      ((skipped++))
      continue
    fi

    run_spinner "$display_name" git -C "$repo_path" pull --ff-only

    if [ $run_spinner_status -eq 0 ]; then
      if echo "$run_spinner_output" | grep -q "Already up to date"; then
        reason="$(_newdev_summary_line "$run_spinner_output")"
        _newdev_log "SKIP" "$display_name — $reason"
        ((up_to_date++))
      else
        _newdev_log "COMPLETE" "$display_name"
        ((updated++))
      fi
    else
      reason="$(_newdev_summary_line "$run_spinner_output")"
      _newdev_log "FAIL" "$display_name — $reason"
      _newdev_record_attention "FAILED" "$display_name — git pull" "$run_spinner_output" "$reason"
      ((failed++))
    fi

  done

  if (( discovered == 0 )); then
    reason="No Git repositories found beneath $repo_root."
    _newdev_log "SKIP" "Repositories — $reason"
  elif (( updated > 0 || skipped > 0 || failed > 0 )); then
    summary="$updated updated, $up_to_date up to date"
    (( skipped > 0 )) && summary+=", $skipped skipped"
    (( failed > 0 )) && summary+=", $failed failed"
    _newdev_log "INFO" "Repositories: $summary."
  else
    _newdev_log "COMPLETE" "All $up_to_date repositories were already up to date."
  fi

  (( failed == 0 ))
}

_newdev_help() {
  cat <<'EOF'
Usage:
  newdev [--verbose]
  newdev --help

Description:
  Update Homebrew and fast-forward clean, upstream-tracked repositories beneath
  $HOME/dev. Repositories with tracked local changes or unsafe branch state are
  skipped with a reason. Failures receive a concise end-of-run summary.
  Toolbox reads Atuin history directly; no collection or review step is needed.

Options:
  -h, --help       Show this help menu and exit.
  -v, --verbose    Include full captured output for attention items.

Examples:
  newdev
  newdev --verbose
  newdev --help

Environment:
  HOME          Parent directory containing the dev checkout collection.
EOF
}

# toolbox: maintenance git | Update Homebrew and safe Git repositories.
# toolbox-args: [--verbose]
# toolbox-example: newdev
# toolbox-example: newdev --verbose
newdev() {
  local verbose=0
  local failed_groups=0

  while (( $# > 0 )); do
    case "$1" in
      -h|--help)
        _newdev_help
        return 0
        ;;
      -v|--verbose)
        verbose=1
        shift
        ;;
      *)
        printf "[FAIL] Unknown option: %s\n" "$1" >&2
        printf "Run 'newdev --help' for usage.\n" >&2
        return 2
        ;;
    esac
  done

  _newdev_verbose=$verbose
  _newdev_attention_levels=()
  _newdev_attention_scopes=()
  _newdev_attention_summaries=()
  _newdev_attention_details=()

  _newdev_log "START" "Updating all the things"

  homebrew_update || ((failed_groups++))
  pull_repos || ((failed_groups++))
  _newdev_print_attention_summary

  if (( failed_groups > 0 )); then
    _newdev_log "FAIL" "newdev completed with $failed_groups failed update group(s)."
    return 1
  fi

  _newdev_log "COMPLETE" "All the things updated"
}
