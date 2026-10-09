#!/usr/bin/env zsh
# tmux and Zellij: tmux_all_panes, tw, and tkill.
# .zshrc sources every file in dotfiles/functions/.

_tmux_all_panes_help() {
  cat <<'EOF'
Usage:
  tmux_all_panes <command>

Description:
  Send one command followed by Enter to every pane in the current tmux session.

Options:
  -h, --help    Show this help menu.

Examples:
  tmux_all_panes 'git status -sb'
  tmux_all_panes 'source ~/.zshrc'
  tmux_all_panes 'cd ~/dev && git status --short'
EOF
}

# Run a command in all panes of a tmux session.
# toolbox: multiplexer tmux | Send one command to every tmux pane.
# toolbox-args: COMMAND
# toolbox-example: tmux_all_panes 'pwd'
# toolbox-example: tmux_all_panes 'git status --short'
tmux_all_panes() {
  if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    _tmux_all_panes_help
    return 0
  fi

  local cmd="$*"
  if [ -z "$cmd" ]; then
    echo "❌ No command provided."
    echo "Run 'tmux_all_panes --help' for usage." >&2
    return 1
  fi

  for pane in $(tmux list-panes -F '#P'); do
    tmux send-keys -t "$pane" "$cmd" C-m
  done
}

_tw_help() {
  cat <<'EOF'
Usage:
  tw [options] [session-name]
  tw [options] (-p | --projects | projects)
  tw [options] -ls

Description:
  Interactively switch or attach to a tmux or Zellij pane, browse local Git
  projects, or create a named session. The active multiplexer is selected
  automatically; outside one, tmux remains the default.

Options:
  -h, --help       Show this help menu.
  -p, --projects   Open the selected backend's project launcher.
  -ls              List sessions for the selected backend.
  -t, --tmux       Force the tmux backend for this invocation.
  -z, --zellij     Force the Zellij backend for this invocation.

Examples:
  tw
  tw -z
  tw -p
  tw -z projects
  tw validation
  tw -t validation
  tw -ls

Environment:
  TW_BACKEND       Default backend outside a multiplexer: tmux or zellij.
  TW_PROJECT_ROOT  Directory containing projects (default: ~/dev).
EOF
}

_tw_select_backend() {
  local requested="$1"

  if [[ -n "$requested" ]]; then
    :
  elif [[ -n "${ZELLIJ_SESSION_NAME:-}" || -n "${ZELLIJ:-}" ]]; then
    requested="zellij"
  elif [[ -n "${TMUX:-}" ]]; then
    requested="tmux"
  else
    requested="${TW_BACKEND:-tmux}"
  fi

  case "$requested" in
    tmux|zellij) print -r -- "$requested" ;;
    *)
      print -u2 -r -- "tw: TW_BACKEND must be 'tmux' or 'zellij' (got: $requested)"
      return 2
      ;;
  esac
}

_tw_tmux() {
  local navigator="${DOTFILE_DIR:-${SETUP_DIR:-$HOME/dev/supernova}/dotfiles}/.bin/tmux-fzf"
  if [[ "${1:-}" == "-p" || "${1:-}" == "--projects" || "${1:-}" == "projects" ]]; then
    if [[ ! -x "$navigator" ]]; then
      echo "tmux project launcher is unavailable: $navigator" >&2
      return 1
    fi
    "$navigator" projects
    return
  fi

  local change
  [[ -n "${TMUX:-}" ]] && change="switch-client" || change="attach-session"

  if [[ "${1:-}" == "-ls" ]]; then
    tmux list-sessions
    return
  fi

  if [[ -n "${1:-}" ]]; then
    if ! tmux has-session -t "$1" 2>/dev/null; then
      echo "🆕 Creating new session: $1"
      if [[ -n "${TMUX:-}" ]]; then
        # Inside tmux: create detached, then switch
        tmux new-session -d -s "$1" -n "$1" 2>/dev/null
        tmux switch-client -t "$1"
      else
        # Outside tmux: create and attach in one step
        tmux new-session -s "$1" -n "$1" 2>/dev/null
      fi
    else
      tmux $change -t "$1"
    fi
    return
  fi

  if ! tmux list-sessions &>/dev/null; then
    echo "No tmux sessions running. Create one with: tw <session-name>"
    return 1
  fi

  if [[ ! -x "$navigator" ]]; then
    echo "tmux navigator is unavailable: $navigator" >&2
    return 1
  fi
  "$navigator" navigate
}

_tw_zellij() {
  local navigator="${DOTFILE_DIR:-${SETUP_DIR:-$HOME/dev/supernova}/dotfiles}/.bin/zellij-fzf"
  if [[ "${1:-}" == "-p" || "${1:-}" == "--projects" || "${1:-}" == "projects" ]]; then
    if [[ ! -x "$navigator" ]]; then
      echo "Zellij project launcher is unavailable: $navigator" >&2
      return 1
    fi
    "$navigator" projects
    return
  fi

  if [[ "${1:-}" == "-ls" ]]; then
    zellij list-sessions
    return
  fi

  if [[ -n "${1:-}" ]]; then
    if [[ -n "${ZELLIJ_SESSION_NAME:-}" || -n "${ZELLIJ:-}" ]]; then
      zellij action switch-session "$1"
    else
      zellij attach -c "$1"
    fi
    return
  fi

  if [[ ! -x "$navigator" ]]; then
    echo "Zellij navigator is unavailable: $navigator" >&2
    return 1
  fi
  "$navigator" navigate
}

# toolbox: multiplexer tmux zellij | Navigate projects and multiplexer sessions.
# toolbox-args: [--tmux | --zellij] [SESSION | --projects | -ls]
# toolbox-example: tw
# toolbox-example: tw -p
# toolbox-example: tw -z projects
# toolbox-example: tw -ls
# toolbox-example: tw validation
tw () {
  local requested_backend=""
  case "${1:-}" in
    -t|--tmux) requested_backend="tmux"; shift ;;
    -z|--zellij) requested_backend="zellij"; shift ;;
  esac

  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    _tw_help
    return 0
  fi

  local backend
  backend="$(_tw_select_backend "$requested_backend")" || return
  if [[ "$backend" == "zellij" ]]; then
    _tw_zellij "$@"
  else
    _tw_tmux "$@"
  fi
}

_tkill_help() {
  cat <<'EOF'
Usage:
  tkill [--all]

Description:
  Interactively choose one or more tmux sessions to kill. --all asks for a
  confirmation before killing every tmux session.

Options:
  -h, --help    Show this help menu.
  --all         Prompt to kill every tmux session.

Examples:
  tkill
  tkill --all
  tmux ls
EOF
}

# toolbox: multiplexer tmux | Interactively stop tmux sessions.
# toolbox-args: [--all]
# toolbox-example: tkill
# toolbox-example: tkill --all
tkill () {
	if [[ "$1" == "-h" || "$1" == "--help" ]]; then
		_tkill_help
		return 0
	fi

	if [[ "$1" == "--all" ]]; then
		read -q "REPLY?⚠️  Kill ALL tmux sessions? [y/N] " || {
			echo "\n❌ Aborted."
			return 1
		}
		echo "\n🔪 Killing all tmux sessions..."
		tmux list-sessions -F '#S' | while read -r session; do
			tmux kill-session -t "$session"
			echo "☠️  Killed $session"
		done
		return
	fi

	local sessions
	sessions="$(tmux ls | fzf --exit-0 --multi)" || return $?

	local i
	for i in "${(f@)sessions}"; do
		[[ $i =~ '([^:]*):.*' ]] && {
			echo "Killing $match[1]"
			tmux kill-session -t "$match[1]"
		}
	done
}
