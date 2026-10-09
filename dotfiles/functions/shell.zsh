#!/usr/bin/env zsh
# Shell basics: SSH agent refresh, PATH upkeep, source_zsh, cd listing, ll,
# why, paths, topcmds, toolbox, and when.
# .zshrc sources every file in dotfiles/functions/.

# Keep long-lived shells on a stable path while SSH replaces its forwarded
# agent socket on each connection. The caller opts in with a machine-local
# SETUP_FORWARDED_SSH_AGENT_LINK value.
_setup_ssh_agent_responds() {
  emulate -L zsh

  local socket_path="$1"
  local ssh_add="${commands[ssh-add]:-}"
  local timeout_command="${commands[timeout]:-${commands[gtimeout]:-}}"
  local probe_status

  [[ -S "$socket_path" && -n "$ssh_add" && -n "$timeout_command" ]] || return 1

  SSH_AUTH_SOCK="$socket_path" "$timeout_command" 1 "$ssh_add" -l >/dev/null 2>&1
  probe_status=$?
  (( probe_status == 0 || probe_status == 1 ))
}

_setup_refresh_forwarded_ssh_agent() {
  emulate -L zsh

  local stable_link="${SETUP_FORWARDED_SSH_AGENT_LINK:-}"
  local forwarded_agent="${SSH_AUTH_SOCK:-}"
  local temporary_link
  local -i forwarded_usable=0

  [[ -n "$stable_link" ]] || return 0

  if [[ -n "${SSH_TTY:-}" &&
        -n "$forwarded_agent" &&
        "$forwarded_agent" != "$stable_link" &&
        -S "$forwarded_agent" ]] &&
      _setup_ssh_agent_responds "$forwarded_agent"; then
    forwarded_usable=1

    # Never replace a real file/socket/directory selected by mistake. Broken
    # symlinks are safe to repair, but symlinks to directories are not safe mv
    # destinations because mv may follow them.
    if [[ ( -e "$stable_link" && ! -L "$stable_link" ) ||
          ( -L "$stable_link" && -d "$stable_link" ) ]]; then
      return 0
    fi

    temporary_link="${stable_link}.tmp.$$.$RANDOM"
    if command ln -s "$forwarded_agent" "$temporary_link" 2>/dev/null; then
      if command mv -f "$temporary_link" "$stable_link" 2>/dev/null; then
        export SSH_AUTH_SOCK="$stable_link"
        return 0
      fi
      command rm -f -- "$temporary_link"
    fi
  fi

  if _setup_ssh_agent_responds "$stable_link"; then
    export SSH_AUTH_SOCK="$stable_link"
    return 0
  fi

  if (( ! forwarded_usable )) &&
      [[ -n "$forwarded_agent" && "$forwarded_agent" != "$stable_link" ]] &&
      _setup_ssh_agent_responds "$forwarded_agent"; then
    forwarded_usable=1
  fi

  if (( forwarded_usable )); then
    export SSH_AUTH_SOCK="$forwarded_agent"
    return 0
  fi

  unset SSH_AUTH_SOCK
  print -u2 -r -- "SSH agent unavailable: $stable_link is not responsive; reconnect with agent forwarding."
  return 1
}

_compact_home_path() {
  local candidate="$1"

  if [[ -n "${HOME:-}" && "$candidate" == "$HOME" ]]; then
    REPLY="~"
  elif [[ -n "${HOME:-}" && "$candidate" == "$HOME/"* ]]; then
    REPLY="~/${candidate#"$HOME"/}"
  else
    REPLY="$candidate"
  fi
}

# Reload zsh configuration without retaining functions removed from managed helpers.
unalias source_zsh 2>/dev/null
_normalize_setup_path() {
  local stale_work_path=""
  local path_entry
  local -a normalized_path

  if [[ "$WORK_ENV" == true && -n "${JOB:-}" && -n "${WORK_DIR:-}" ]]; then
    stale_work_path="$WORK_DIR/bin-$JOB/wtf"
  fi
  [[ -n "$stale_work_path" ]] || return 0

  for path_entry in "${path[@]}"; do
    [[ "$path_entry" == "$stale_work_path" ]] && continue
    normalized_path+=("$path_entry")
  done

  path=("${normalized_path[@]}")
}

# toolbox: shell | Reload managed Zsh configuration and functions.
# toolbox-example: source_zsh
source_zsh() {
  local helper_path function_name
  local -a managed_helpers stale_functions

  managed_helpers=("$DOTFILE_DIR"/functions/*.zsh(N))
  if [[ "$WORK_ENV" == true && -n "${JOB:-}" && -n "${WORK_DIR:-}" ]]; then
    managed_helpers+=("$WORK_DIR/bin-$JOB/functions-$JOB.sh" "$WORK_DIR"/functions/*.zsh(N))
  fi

  for helper_path in "${managed_helpers[@]}"; do
    [[ -r "$helper_path" ]] || continue
    for function_name in ${(k)functions_source}; do
      [[ "${functions_source[$function_name]:A}" == "${helper_path:A}" ]] &&
        stale_functions+=("$function_name")
    done
  done

  (( ${#stale_functions} )) && unfunction -- "${stale_functions[@]}"
  source "$HOME/.zshrc" || return $?
  _normalize_setup_path
  rehash
}

# List the new directory after cd. Registered as a hook so other chpwd hooks
# keep working; very large directories get a count instead of a slow listing.
_setup_chpwd_list() {
  local -a entries
  entries=( *(DN[1,501]) )
  if (( ${#entries} > 500 )); then
    print -r -- "More than 500 entries; run ll to list them."
  else
    ll
  fi
}
autoload -Uz add-zsh-hook
add-zsh-hook chpwd _setup_chpwd_list

# ll: use eza if available, otherwise fall back to ls
unalias ll 2>/dev/null
if command -v eza &>/dev/null; then
    # toolbox: filesystem | List directory contents with useful metadata.
    # toolbox-args: [OPTIONS] [PATH ...]
    # toolbox-example: ll
    # toolbox-example: ll ~/dev
    ll() {
        if [[ "$PWD" == "$HOME" ]]; then
            eza -almh --icons=always --no-user --git --git-repos "$@"
        else
            eza -almh --icons=always --no-user --git --git-repos --total-size "$@"
        fi
    }
else
    # toolbox: filesystem | List directory contents with useful metadata.
    # toolbox-args: [OPTIONS] [PATH ...]
    # toolbox-example: ll
    # toolbox-example: ll ~/dev
    ll() {
        if [[ "$OSTYPE" == "darwin"* ]]; then
            command ls -alhG "$@"
        else
            command ls -alh --color=auto "$@"
        fi
    }
fi

_why_help() {
  cat <<'EOF'
Usage:
  why [--body] COMMAND
  why -h | --help

Description:
  Explain how Zsh resolves COMMAND. Aliases are always printed in full;
  functions show their source and include their definition with --body.
  Same-named executables found later on PATH are also listed.

Options:
  --body        Print a shell function's complete definition.
  -h, --help    Show this help menu.

Examples:
  why ll
  why fd
  why --body space
  why python
EOF
}

_why_print_executables() {
  local name="$1"
  local executable_output
  local -a executable_paths

  executable_output="$(whence -pa -- "$name" 2>/dev/null)"
  [[ -n "$executable_output" ]] || return 0
  executable_paths=("${(@f)executable_output}")

  print -r -- "Executables:"
  printf '  %s\n' "${executable_paths[@]}"
}

_why_function_source() {
  local name="$1"
  local source="${functions_source[$name]:-interactive shell}"
  local source_line

  [[ "$source" == "zsh" ]] && source="interactive shell"
  if [[ -r "$source" ]]; then
    source_line="$(command awk -v name="$name" '
      BEGIN {
        gsub(/[][\\.^$*+?(){}|]/, "\\\\&", name)
        declaration = "^[[:space:]]*" name "[[:space:]]*\\(\\)[[:space:]]*\\{"
        keyword = "^[[:space:]]*function[[:space:]]+" name "([[:space:]]*\\(\\))?[[:space:]]*\\{"
      }
      $0 ~ declaration || $0 ~ keyword { print NR; exit }
    ' "$source")"
  fi
  print -r -- "${source}${source_line:+:$source_line}"
}

# toolbox: shell | Explain how Zsh resolves a command.
# toolbox-args: [--body] COMMAND
# toolbox-example: why git
# toolbox-example: why --body toolbox
why() {
  emulate -L zsh

  local show_body=false
  local name kind source
  local -a executable_paths

  case "${1:-}" in
    -h|--help)
      _why_help
      return 0
      ;;
    --body)
      show_body=true
      shift
      ;;
    --)
      shift
      ;;
    -*)
      print -u2 -r -- "why: unknown option: $1"
      print -u2 -r -- "Run 'why --help' for usage."
      return 2
      ;;
  esac

  (( $# == 1 )) || {
    print -u2 -r -- "why: exactly one command is required"
    print -u2 -r -- "Run 'why --help' for usage."
    return 2
  }
  name="$1"

  if (( ${+aliases[$name]} )); then
    print -r -- "Type: alias"
    print -n -r -- "Definition: alias "
    builtin alias "$name"
    _why_print_executables "$name"
    return 0
  fi

  if (( ${+galiases[$name]} )); then
    print -r -- "Type: global alias"
    print -n -r -- "Definition: alias -g "
    builtin alias -g "$name"
    _why_print_executables "$name"
    return 0
  fi

  if (( ${+saliases[$name]} )); then
    print -r -- "Type: suffix alias"
    print -n -r -- "Definition: alias -s "
    builtin alias -s "$name"
    _why_print_executables "$name"
    return 0
  fi

  kind="$(whence -w -- "$name" 2>/dev/null)"
  kind="${kind#*: }"
  case "$kind" in
    function)
      source="$(_why_function_source "$name")"
      print -r -- "Type: function"
      print -r -- "Source: $source"
      if [[ "$show_body" == true ]]; then
        print -r -- "Definition:"
        functions "$name"
      fi
      _why_print_executables "$name"
      ;;
    builtin)
      print -r -- "Type: shell builtin"
      _why_print_executables "$name"
      ;;
    reserved)
      print -r -- "Type: reserved word"
      ;;
    command)
      executable_paths=("${(@f)$(whence -pa -- "$name" 2>/dev/null)}")
      print -r -- "Type: executable"
      print -r -- "Selected: ${executable_paths[1]}"
      if (( ${#executable_paths} > 1 )); then
        print -r -- "Alternates:"
        printf '  %s\n' "${executable_paths[@]:1}"
      fi
      ;;
    *)
      print -u2 -r -- "why: command not found: $name"
      return 1
      ;;
  esac
}

_paths_help() {
  cat <<'EOF'
Usage:
  paths
  paths -h | --help

Description:
  Audit PATH entries in command-resolution order. STATUS identifies missing
  paths, non-directories, directories that cannot be searched, and empty entries
  that resolve to the current directory. DUP points to the first equivalent
  entry, including directories reached through different symlink paths.

Options:
  -h, --help    Show this help menu.

Examples:
  paths
  PATH="$HOME/.local/bin:/usr/bin:/usr/bin" paths

Environment:
  PATH          Ordered list of directories to inspect.
EOF
}

# toolbox: shell | Audit command search paths and duplicates.
# toolbox-example: paths
paths() {
  emulate -L zsh

  case "${1:-}" in
    -h|--help)
      _paths_help
      return 0
      ;;
  esac
  (( $# == 0 )) || {
    print -u2 -r -- "paths: this command does not accept arguments"
    print -u2 -r -- "Run 'paths --help' for usage."
    return 2
  }

  if (( ${#path} == 0 )); then
    print -r -- "PATH is empty."
    return 0
  fi

  local entry resolved display entry_status duplicate
  local -i entry_index=0 order_width=5 status_width=6 duplicate_width=3
  local -a statuses duplicates displays
  local -A first_positions

  for entry in "${path[@]}"; do
    (( entry_index++ ))
    if [[ -z "$entry" ]]; then
      resolved="${PWD:A}"
      _compact_home_path "$PWD"
      display="(empty entry; current directory: $REPLY)"
      entry_status="current-dir"
    else
      resolved="${entry:A}"
      _compact_home_path "$entry"
      display="$REPLY"

      if [[ ! -e "$entry" ]]; then
        entry_status="missing"
      elif [[ ! -d "$entry" ]]; then
        entry_status="not-dir"
      elif [[ ! -x "$entry" ]]; then
        entry_status="no-search"
      else
        entry_status="ok"
      fi
    fi

    if [[ -n "${first_positions[$resolved]:-}" ]]; then
      duplicate="#${first_positions[$resolved]}"
    else
      first_positions[$resolved]="$entry_index"
      duplicate="-"
    fi

    statuses[$entry_index]="$entry_status"
    duplicates[$entry_index]="$duplicate"
    displays[$entry_index]="$display"
    (( ${#entry_index} > order_width )) && order_width=${#entry_index}
    (( ${#entry_status} > status_width )) && status_width=${#entry_status}
    (( ${#duplicate} > duplicate_width )) && duplicate_width=${#duplicate}
  done

  local row_format="%${order_width}s %-${status_width}s %${duplicate_width}s %s\n"
  printf "$row_format" "ORDER" "STATUS" "DUP" "PATH"
  for (( entry_index = 1; entry_index <= ${#statuses}; entry_index++ )); do
    printf "$row_format" \
      "$entry_index" "${statuses[$entry_index]}" \
      "${duplicates[$entry_index]}" "${displays[$entry_index]}"
  done
}

_topcmds_help() {
  cat <<'EOF'
Usage:
  topcmds [LIMIT]
  topcmds -h | --help

Description:
  Summarize the most frequently recorded commands in Zsh history. Commands run
  through sudo are counted under the command sudo launched. History is read
  without flushing or modifying the current shell's history.

Options:
  LIMIT         Number of commands to show (default: 15).
  -h, --help    Show this help menu.

Examples:
  topcmds
  topcmds 25

Environment:
  HISTFILE      History file to inspect (default: $HOME/.zsh_history).
EOF
}

# toolbox: shell history | Summarize frequently used shell commands.
# toolbox-args: [LIMIT]
# toolbox-example: topcmds
# toolbox-example: topcmds 25
topcmds() {
  emulate -L zsh
  setopt pipefail

  case "${1:-}" in
    -h|--help)
      _topcmds_help
      return 0
      ;;
  esac

  (( $# <= 1 )) || {
    print -u2 -r -- "topcmds: expected at most one limit"
    print -u2 -r -- "Run 'topcmds --help' for usage."
    return 2
  }

  local limit="${1:-15}"
  if [[ "$limit" != <1-> ]]; then
    print -u2 -r -- "topcmds: limit must be a positive integer"
    return 2
  fi

  local history_file="${HISTFILE:-$HOME/.zsh_history}"
  history_file="${~history_file}"
  [[ -f "$history_file" && -r "$history_file" ]] || {
    _compact_home_path "$history_file"
    print -u2 -r -- "topcmds: history file not found or unreadable: $REPLY"
    return 1
  }

  local ranking
  ranking="$(
    command awk '
      function is_assignment(value) {
        return value ~ /^[[:alpha:]_][[:alnum:]_]*=/
      }
      function sudo_option_has_value(value) {
        return value ~ /^-(u|g|h|p|C|R|T)$/ ||
          value ~ /^--(user|group|host|prompt|close-from|chdir|role|type|other-user|command-timeout)$/
      }
      {
        line = $0
        sub(/\r$/, "", line)
        sub(/^: [0-9]+:[0-9]+;/, "", line)
        sub(/^[[:space:]]+/, "", line)
        if (line == "" || line ~ /^#/) {
          next
        }

        field_count = split(line, fields, /[[:space:]]+/)
        field_index = 1
        while (field_index <= field_count && is_assignment(fields[field_index])) {
          field_index++
        }

        if (fields[field_index] == "sudo") {
          field_index++
          while (field_index <= field_count && fields[field_index] ~ /^-/) {
            if (fields[field_index] == "--") {
              field_index++
              break
            }
            if (sudo_option_has_value(fields[field_index])) {
              field_index += 2
            } else {
              field_index++
            }
          }
          while (field_index <= field_count && is_assignment(fields[field_index])) {
            field_index++
          }
        }

        command_name = fields[field_index]
        sub(/^\\/, "", command_name)
        sub(/^.*\//, "", command_name)
        sub(/[;&|]+$/, "", command_name)
        if (command_name != "" && command_name !~ /^[(){}]/) {
          counts[command_name]++
        }
      }
      END {
        for (command_name in counts) {
          printf "%d\t%s\n", counts[command_name], command_name
        }
      }
    ' "$history_file" |
      LC_ALL=C command sort -t $'\t' -k1,1nr -k2,2 |
      command sed -n "1,${limit}p"
  )" || {
    print -u2 -r -- "topcmds: could not read command history"
    return 1
  }

  if [[ -z "$ranking" ]]; then
    print -r -- "No commands found in history."
    return 0
  fi

  local count command_name
  printf '%5s  %s\n' "COUNT" "COMMAND"
  while IFS=$'\t' read -r count command_name; do
    printf '%5d  %s\n' "$count" "$command_name"
  done <<<"$ranking"
}

_toolbox_help() {
  cat <<'EOF'
Usage:
  toolbox [FILTER]
  toolbox --pick [FILTER]
  toolbox --describe NAME
  toolbox --json [FILTER]
  toolbox --collect-history [--limit N] [--scope S]
  toolbox --pending [--json] [--scope S]
  toolbox --review [--scope S]
  toolbox --save COMMAND --description TEXT [--tag TAG] [--scope S]
  toolbox --accept ID --description TEXT [--command TEXT] [--tag TAG] [--scope S]
  toolbox --reject ID [--scope S]
  toolbox -h | --help

Description:
  List currently loaded managed functions, usable managed commands on PATH,
  reviewed catalogs, and every distinct command in scoped local Atuin history.
  Helpers appear first, then catalogs and history. Work requires the active Work
  environment. History is read live; no collection or review is needed to search.
  FILTER matches names, sources, descriptions, categories, and full command text.
  Metadata is read
  from comments; discovery never executes a helper. Shadowed alternatives are
  flagged in the table and detailed by --describe and --json.

Options:
  FILTER              Show only matching commands.
  --pick [FILTER]     Pick an example with fzf and insert it for editing, never run it.
  --describe NAME     Show source, argument hints, examples, and shadowed alternatives.
  --json [FILTER]     Emit schema_version 1 with a commands array (empty on no match).
  --collect-history  Collect catalog candidates; not needed for history search.
  --pending          Show pending candidates; --json emits structured output.
  --review           Review local candidates interactively; requires a terminal.
  --save COMMAND     Scan and save literal command text with --description TEXT.
  --accept ID        Scan and accept a candidate with --description TEXT.
  --reject ID        Dismiss a candidate without adding it to a catalog.
  --scope S          Catalog operations: personal or the active work-JOB scope.
  -h, --help          Show this help menu.

Examples:
  toolbox
  toolbox git
  toolbox --pick network
  toolbox --describe toolbox
  toolbox --json home
  toolbox --collect-history --limit 200
  toolbox --review
  toolbox --save 'git log -5 --oneline' --description 'Review recent commits' --tag git

Environment:
  WORK_ENV         Include work commands only when set to true.
  JOB              Active job; selects $WORK_DIR/bin-$JOB.
  WORK_DIR         Work overlay directory ($WORK_ROOT/$JOB) set by .zshrc.
  SETUP_DIR        Repository root (defaults to the one holding dotfiles/functions/).
  XDG_CONFIG_HOME  Catalog location overrides in toolbox/config.json.
  XDG_DATA_HOME    Atuin history under atuin/scopes/SCOPE/; catalogs under toolbox/.
  Catalog writes require gitleaks and secret screening; no automatic commits.
  Ctrl+X Ctrl+T opens the picker in ZLE when that key is unbound. Escape keeps the
  original buffer. --pick needs an interactive shell; it pushes a selection onto
  the next editable prompt. Python 3 renders metadata; fzf is required for picking.
EOF
}

_toolbox_snapshot() {
  emulate -L zsh
  local home_dir="${functions_source[toolbox]:A:h}"
  local setup_root="${SETUP_DIR:-${home_dir:h:h}}"
  local work_file='' work_dir='' candidate command_name source_path source_name kind effective location
  local -a candidates
  local -A path_dirs
  for candidate in "${path[@]}"; do
    candidate="${candidate:-.}"
    path_dirs[${candidate:A}]=1
  done
  if [[ "${WORK_ENV:-false}" == true && -n "${JOB:-}" && -n "${WORK_DIR:-}" ]]; then
    work_dir="${WORK_DIR:A}"
    work_file="$work_dir/bin-${JOB}/functions-${JOB}.sh"
  fi
  # Loaded definitions are authoritative. Merely finding a function in a file
  # never admits it to the inventory or sources another environment.
  for command_name in ${(ok)functions_source}; do
    case "$command_name" in
      _*|chpwd|precmd|preexec|periodic|zshaddhistory|zshexit|zsh_directory_name|TRAP*|run_spinner) continue ;;
    esac
    source_path="${functions_source[$command_name]:A}"
    if [[ "$source_path" == "$home_dir"/* ]]; then
      source_name=home
    elif [[ -n "$work_file" && ( "$source_path" == "$work_file" || "$source_path" == "$work_dir"/functions/*.zsh ) ]]; then
      source_name="$JOB"
    else
      continue
    fi
    candidates+=("$command_name" "$source_name" function "$source_path")
  done
  local -a directories=("$setup_root/dotfiles/.bin") groups=(home)
  if [[ -n "$work_file" ]]; then
    directories+=("$work_dir/bin-$JOB") groups+=("$JOB")
  fi
  local -i index
  for (( index=1; index<=${#directories}; index++ )); do
    candidate="${directories[$index]:A}"
    (( ${+path_dirs[$candidate]} )) || continue
    for source_path in "$candidate"/*(N.); do
      [[ -x "$source_path" ]] || continue
      candidates+=("${source_path:t}" "${groups[$index]}" executable "${source_path:A}")
    done
    # Include executable symlinks too, while rejecting dangling links/directories.
    for source_path in "$candidate"/*(N@); do
      [[ -f "$source_path" && -x "$source_path" ]] || continue
      candidates+=("${source_path:t}" "${groups[$index]}" executable "${source_path:A}")
    done
  done
  for (( index=1; index<=${#candidates}; index+=4 )); do
    command_name="${candidates[$index]}"
    if (( ${+aliases[$command_name]} )); then
      effective=alias location="${aliases[$command_name]}"
    elif (( ${+galiases[$command_name]} )); then
      effective=alias location="${galiases[$command_name]}"
    elif (( ${+functions[$command_name]} )); then
      effective=function location="${functions_source[$command_name]:-interactive shell}"
      [[ "$location" == zsh ]] && location='interactive shell'
      [[ -f "$location" ]] && location="${location:A}"
    elif (( ${+builtins[$command_name]} )); then
      effective=builtin location="$command_name"
    else
      effective=executable location="${commands[$command_name]:A}"
      [[ -f "$location" && -x "$location" ]] || continue
    fi
    printf '%s\0' "${candidates[$index]}" "${candidates[$index+1]}" \
      "${candidates[$index+2]}" "${candidates[$index+3]}" "$effective" "$location"
  done
}

_toolbox_render() {
  local helper="${functions_source[toolbox]:A:h:h}/lib/toolbox.py"
  local setup_root="${SETUP_DIR:-${functions_source[toolbox]:A:h:h:h}}"
  (( ${+commands[python3]} )) || { print -u2 'toolbox: python3 is required'; return 1; }
  # Options go before the mode: Python 3.12.3 (Ubuntu 24.04) rejects
  # "MODE --option VALUE -- FILTER" as unrecognized arguments.
  _toolbox_snapshot | WORK_ENV="${WORK_ENV:-false}" JOB="${JOB:-}" SETUP_DIR="$setup_root" \
    command python3 -I -S "$helper" "${@:3}" "$1" -- "$2"
}

_toolbox_catalog() {
  local helper="${functions_source[toolbox]:A:h:h}/lib/toolbox_catalog.py"
  local setup_root="${SETUP_DIR:-${functions_source[toolbox]:A:h:h:h}}"
  (( ${+commands[python3]} )) || { print -u2 'toolbox: python3 is required'; return 1; }
  [[ -f "$helper" ]] || { print -u2 'toolbox: catalog support is not installed'; return 1; }
  WORK_ENV="${WORK_ENV:-false}" JOB="${JOB:-}" SETUP_DIR="$setup_root" \
    command python3 -I -S "$helper" "$@"
}

_toolbox_select() {
  emulate -L zsh
  setopt localoptions pipefail
  (( ${+commands[fzf]} )) || { print -u2 'toolbox: fzf is required for --pick'; return 1; }
  local directory selection number
  local helper="${functions_source[toolbox]:A:h:h}/lib/toolbox.py"
  local python="${commands[python3]}"
  directory="$(umask 077; command mktemp -d "${TMPDIR:-/tmp}/toolbox.XXXXXXXX")" || return 1
  {
    _toolbox_render pick "$1" --directory "$directory" >"$directory/rows" || return $?
    # Ignore inherited fzf actions (execute/become/accept bindings). Only the
    # numeric row ID enters the preview shell; source/example text is inert.
    selection="$(FZF_DEFAULT_OPTS='' FZF_DEFAULT_OPTS_FILE=/dev/null command fzf \
      --delimiter=$'\t' --with-nth=2.. --layout=reverse --height=80% \
      --prompt='toolbox> ' --header='Enter: insert example for editing • Esc: cancel' \
      --preview="${(q)python} -I -S ${(q)helper} preview {1} --directory ${(q)directory}" \
      --preview-window=right:55%:wrap \
      <"$directory/rows")" || return $?
    number="${selection%%$'\t'*}"
    [[ "$number" == <-> ]] || return 1
    command "$python" -I -S "$helper" select "$number" --directory "$directory"
  } always {
    command rm -rf -- "$directory"
  }
}

_toolbox_widget() {
  local selected
  # A sentinel keeps command substitution from trimming significant newlines.
  selected="$(_toolbox_select '' && print -rn -- .)" || { zle redisplay; return 0; }
  selected="${selected%.}"
  BUFFER="$selected"
  CURSOR=${#BUFFER}
  zle redisplay
}

_toolbox_init() {
  [[ -o interactive ]] || return 0
  zle -N toolbox-pick _toolbox_widget
  local binding
  binding="$(bindkey '^X^T')"
  [[ "$binding" == *' undefined-key' || "$binding" == *' toolbox-pick' ]] &&
    bindkey '^X^T' toolbox-pick
  return 0
}

# toolbox: shell history | Search available commands, catalogs, and local Atuin history.
# toolbox-args: [FILTER] | --pick [FILTER] | --describe NAME | --json [FILTER]
# toolbox-example: toolbox --pick git
# toolbox-example: toolbox --describe toolbox
toolbox() {
  emulate -L zsh
  setopt localoptions pipefail
  local mode=table selected
  case "${1:-}" in
    -h|--help) _toolbox_help; return 0 ;;
    --collect-history) shift; _toolbox_catalog collect "$@"; return $? ;;
    --review|--pending|--accept|--reject)
      mode="${1#--}"; shift; _toolbox_catalog "$mode" "$@"; return $? ;;
    --save)
      shift
      if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
        _toolbox_catalog save --help; return $?
      fi
      (( $# )) || { print -u2 'toolbox: --save requires COMMAND and --description TEXT'; return 2; }
      _toolbox_catalog save "--command=$1" "${@:2}"; return $? ;;
    --pick|--describe|--json) mode="${1#--}"; shift ;;
    --) shift ;;
    -*) print -u2 -r -- "toolbox: unknown option: $1"; return 2 ;;
  esac
  if (( $# > 1 )) || [[ "$mode" == describe && $# != 1 ]]; then
    print -u2 -r -- 'toolbox: --describe requires NAME; other modes accept one optional FILTER; see --help'
    return 2
  fi
  if [[ "$mode" == pick ]]; then
    [[ -o interactive && -o zle && -t 0 ]] || {
      print -u2 'toolbox: --pick requires an interactive Zsh prompt (use --describe or --json)'
      return 1
    }
    selected="$(_toolbox_select "$1" && print -rn -- .)" || return $?
    selected="${selected%.}"
    # -r preserves backslashes; -z pushes onto ZLE's input stack without executing.
    print -rz -- "$selected"
  else
    _toolbox_render "$mode" "$1"
  fi
}

_when_help() {
  cat <<'EOF'
Usage:
  when TIME
  when -h | --help

Description:
  Convert epoch seconds, epoch milliseconds, ISO-8601 timestamps, and common
  date strings into Mountain time (America/Denver), UTC, relative age, and
  epoch seconds. Times without a timezone are interpreted as Mountain time.

Options:
  -h, --help    Show this help menu.

Examples:
  when 1788460200
  when 1788460200000
  when 2026-09-03T18:30:00Z
  when "2026-09-03 12:30 MDT"
  when now
EOF
}

# toolbox: shell time | Convert timestamps and show their relative age.
# toolbox-args: TIME
# toolbox-example: when now
# toolbox-example: when '2026-10-07 12:30 MDT'
when() {
  emulate -L zsh

  case "${1:-}" in
    -h|--help)
      _when_help
      return 0
      ;;
    -*)
      print -u2 -r -- "when: unknown option: $1"
      print -u2 -r -- "Run 'when --help' for usage."
      return 2
      ;;
  esac
  if (( $# == 0 )); then
    print -u2 -r -- "when: a time is required"
    print -u2 -r -- "Run 'when --help' for usage."
    return 2
  fi
  if (( ! $+commands[python3] )); then
    print -u2 -r -- "when: python3 is required"
    return 1
  fi

  command python3 - "$*" <<'PY'
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
import os
import re
import sys
import time
from zoneinfo import ZoneInfo


TIMEZONES = {
    "UTC": 0,
    "GMT": 0,
    "EST": -5,
    "EDT": -4,
    "CST": -6,
    "CDT": -5,
    "MST": -7,
    "MDT": -6,
    "PST": -8,
    "PDT": -7,
}
MOUNTAIN = ZoneInfo("America/Denver")


def as_timestamp(parsed):
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=MOUNTAIN)
    return parsed.timestamp()


def parse_time(text):
    if text.lower() == "now":
        return now_epoch

    if re.fullmatch(r"[0-9]+(?:\.[0-9]+)?", text):
        value = float(text)
        if value >= 100_000_000_000:
            value /= 1000
        return value

    timezone_match = re.fullmatch(r"(.+?)\s+([A-Za-z]{2,4})", text)
    if timezone_match and timezone_match.group(2).upper() in TIMEZONES:
        date_text, abbreviation = timezone_match.groups()
        parsed = datetime.fromisoformat(date_text)
        offset = timedelta(hours=TIMEZONES[abbreviation.upper()])
        return as_timestamp(parsed.replace(tzinfo=timezone(offset)))

    iso_text = text[:-1] + "+00:00" if text.endswith(("Z", "z")) else text
    try:
        parsed = datetime.fromisoformat(iso_text)
    except ValueError:
        parsed = parsedate_to_datetime(text)
    return as_timestamp(parsed)


def relative_time(delta):
    absolute = abs(delta)
    if absolute < 1:
        return "now"

    units = (
        (365 * 86400, "year"),
        (30 * 86400, "month"),
        (7 * 86400, "week"),
        (86400, "day"),
        (3600, "hour"),
        (60, "minute"),
        (1, "second"),
    )
    for scale, name in units:
        if absolute >= scale:
            count = max(1, int(absolute / scale + 0.5))
            label = name if count == 1 else f"{name}s"
            phrase = f"{count} {label}"
            return f"{phrase} ago" if delta < 0 else f"in {phrase}"


text = sys.argv[1].strip()
if not text:
    print("when: a time is required", file=sys.stderr)
    raise SystemExit(2)

try:
    now_epoch = float(os.environ.get("_WHEN_NOW_EPOCH", time.time()))
    epoch = parse_time(text)
    mountain_time = datetime.fromtimestamp(epoch, MOUNTAIN)
    utc_time = datetime.fromtimestamp(epoch, timezone.utc)
except (OverflowError, OSError, TypeError, ValueError):
    print(f"when: could not parse time: {text}", file=sys.stderr)
    raise SystemExit(2)

epoch_text = f"{epoch:.6f}".rstrip("0").rstrip(".")
print(f"Mountain: {mountain_time:%Y-%m-%d %H:%M:%S %Z}")
print(f"UTC:      {utc_time:%Y-%m-%d %H:%M:%S UTC}")
print(f"Relative: {relative_time(epoch - now_epoch)}")
print(f"Epoch:    {epoch_text}")
PY
}
