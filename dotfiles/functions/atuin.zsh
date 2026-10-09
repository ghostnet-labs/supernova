# Local command history. The shell's selected scope, never its cwd, owns the DB.
_setup_atuin_disable() {
  emulate -L zsh
  local keymap binding
  # A reload may occur inside the command being recorded. Cancel that unfinished
  # recording before changing paths; never complete its ID in another scope.
  export ATUIN_HISTORY_ID=''
  preexec_functions=(${preexec_functions:#_atuin_preexec})
  precmd_functions=(${precmd_functions:#_atuin_precmd})
  zshaddhistory_functions=(${zshaddhistory_functions:#_atuin_zshaddhistory})
  for keymap in emacs viins vicmd; do
    binding="$(bindkey -M "$keymap" '^R' 2>/dev/null)"
    if [[ "$binding" == *' atuin-search'* && -n "${_SETUP_ATUIN_CTRL_R[$keymap]-}" ]]; then
      bindkey -M "$keymap" '^R' "${_SETUP_ATUIN_CTRL_R[$keymap]}"
    fi
  done
  typeset -g _SETUP_ATUIN_ACTIVE=''
}

_setup_atuin_init() {
  [[ -o interactive ]] || return 0
  emulate -L zsh
  typeset -gA _SETUP_ATUIN_CTRL_R
  unsetopt bgnice
  _setup_atuin_disable
  [[ "${SETUP_ATUIN_ENABLED:-true}" == true ]] || return 0
  (( ${+commands[atuin]} )) || return 0

  local scope=personal
  if [[ "${WORK_ENV:-false}" == true ]]; then
    # Match setup.sh's job identifiers. Invalid Work scope must not use Personal.
    [[ "${JOB:-}" =~ '^[A-Za-z0-9][A-Za-z0-9._-]*$' ]] || return 0
    scope="work-$JOB"
  fi
  local config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/atuin/scopes/$scope"
  local data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/atuin/scopes/$scope"
  local template="${functions_source[_setup_atuin_init]:A:h:h}/atuin/config.toml"
  [[ -r "$template" ]] || return 0
  (umask 077; command mkdir -p -- "$config_dir" "$data_dir") || return 0
  local marker
  if [[ -e "$config_dir/config.toml" ]]; then
    IFS= read -r marker < "$config_dir/config.toml"
    if [[ "$marker" != '# Managed by setup: local Atuin history.' ]]; then
      print -u2 -r -- "Atuin disabled: $config_dir/config.toml is not setup-managed; move it aside to enable scoped history."
      return 0
    fi
  fi
  if ! command cmp -s -- "$template" "$config_dir/config.toml"; then
    (umask 077; command cp -- "$template" "$config_dir/.config.$$.tmp" &&
      command mv -f -- "$config_dir/.config.$$.tmp" "$config_dir/config.toml") || return 0
  fi

  # Atuin expands these supported variables in the managed config. Do not rely
  # on environment overrides beating config-file values: version 18.23 does not.
  export ATUIN_CONFIG_DIR="$config_dir" ATUIN_DATA_DIR="$data_dir"
  export ATUIN_DB_PATH="$data_dir/history.db" ATUIN_RECORD_STORE_PATH="$data_dir/records.db"
  export ATUIN_KEY_PATH="$data_dir/key"
  export ATUIN_AUTO_SYNC=false ATUIN_UPDATE_CHECK=false ATUIN_ENTER_ACCEPT=false
  export ATUIN_DAEMON__ENABLED=false ATUIN_DAEMON__AUTOSTART=false ATUIN_PTY_PROXY__ENABLED=false
  if [[ "${_SETUP_ATUIN_SCOPE:-}" != "$config_dir" ]]; then
    unset ATUIN_SESSION ATUIN_SHLVL
  fi
  typeset -g _SETUP_ATUIN_SCOPE="$config_dir"

  local keymap binding init
  local -a old_strategy=("${ZSH_AUTOSUGGEST_STRATEGY[@]}")
  local strategy_was_set=${+ZSH_AUTOSUGGEST_STRATEGY}
  for keymap in emacs viins vicmd; do
    binding="$(bindkey -M "$keymap" '^R')"
    _SETUP_ATUIN_CTRL_R[$keymap]="${${(z)binding}[2]}"
  done
  # Let Atuin own its hooks and widgets, but choose only Ctrl+R ourselves. This
  # preserves Up, vi-command '/', fzf file search, and existing autosuggestions.
  init="$(command atuin init zsh --disable-up-arrow --disable-ctrl-r --disable-ai 2>/dev/null)" || return 0
  eval "$init"
  if (( strategy_was_set )); then
    ZSH_AUTOSUGGEST_STRATEGY=("${old_strategy[@]}")
  else
    unset ZSH_AUTOSUGGEST_STRATEGY
  fi
  bindkey -M emacs '^R' atuin-search
  bindkey -M viins '^R' atuin-search-viins
  bindkey -M vicmd '^R' atuin-search-vicmd
  typeset -g _SETUP_ATUIN_ACTIVE="$scope"
}
