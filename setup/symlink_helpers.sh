#!/usr/bin/env bash
# Safe managed-link replacement logic. Link inventory lives in dependencies.sh.

# Replace a managed destination without following directory symlinks.
# The caller supplies dry, info, pass, fail, and run_spinner helpers.
link_managed_path() {
  local label="$1"
  local src="$2"
  local dest="$3"
  local backup="$4"
  local backup_dir

  if [[ -L "$dest" && "$(readlink "$dest")" == "$src" ]]; then
    info "$label already linked"
    return 0
  fi

  if [[ -e "$dest" || -L "$dest" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      dry "Backup $dest → $backup"
    else
      backup_dir="$(dirname "$backup")"
      if ! mkdir -p "$backup_dir"; then
        fail "Failed to create backup directory $backup_dir"
        return 1
      fi

      if ! run_spinner "Backing up existing $label" mv "$dest" "$backup"; then
        fail "Failed to back up $label"
        return 1
      fi
      pass "Backed up existing $label to $backup"
    fi
  fi

  if [[ "$DRY_RUN" == true ]]; then
    dry "Link $dest → $src"
    return 0
  fi

  if ! run_spinner "Linking $label" ln -s "$src" "$dest"; then
    fail "Failed to link $label"
    return 1
  fi

  if [[ ! -L "$dest" || "$(readlink "$dest")" != "$src" ]]; then
    fail "Failed to verify $label link"
    return 1
  fi

  pass "Linked $label"
}
