#!/usr/bin/env zsh
# Reusable Personal command patterns from shell history; sourcing runs nothing.

_history_helpers_help() {
  local usage="$1" description="$2"
  shift 2
  print -rl -- "Usage:" "  $usage" "" "Description:" "  $description" "" \
    "Options:" "  -h, --help    Show this help menu." \
    "  --            End helper options before positional arguments." "" "Examples:"
  local example
  for example in "$@"; do print -r -- "  $example"; done
}

_history_helpers_help_requested() {
  local name="$1"
  shift
  if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    "_${name}_help"
    return 0
  fi
  return 1
}

# reply is a caller-local array: never join arguments into shell source.
_history_helpers_prepare() {
  local name="$1" minimum="$2" maximum="$3"
  shift 3
  if [[ "${1:-}" == -- ]]; then
    shift
  elif [[ "${1:-}" == -* ]]; then
    print -u2 -r -- "$name: unknown option: $1; use -- before a literal argument"
    return 2
  fi
  if (( $# < minimum || (maximum >= 0 && $# > maximum) )); then
    "_${name}_help" >&2
    return 2
  fi
  reply=("$@")
}

_history_helpers_require() {
  local name="$1" executable
  shift
  for executable in "$@"; do
    if ! whence -p -- "$executable" >/dev/null; then
      print -u2 -r -- "$name: required command is unavailable: $executable"
      return 127
    fi
  done
}

_history_helpers_ref() {
  if [[ "$2" == -* ]]; then
    print -u2 -r -- "$1: REF cannot begin with a dash"
    return 2
  fi
}

_gdiff_help() {
  _history_helpers_help 'gdiff [--] [PATH ...]' \
    'Review unstaged changes, optionally limited to literal file paths.' \
    'gdiff' 'gdiff README.md' 'gdiff -- "file with spaces.txt"'
}
# toolbox: git diff history | Review unstaged changes to all or selected files.
# toolbox-args: [PATH ...]
# toolbox-example: gdiff
# toolbox-example: gdiff README.md
gdiff() {
  emulate -L zsh
  _history_helpers_help_requested gdiff "$@" && return 0
  local -a reply
  _history_helpers_prepare gdiff 0 -1 "$@" || return $?
  _history_helpers_require gdiff git || return $?
  command git --literal-pathspecs diff -- "${reply[@]}"
}

_gstaged_help() {
  print -rl -- 'Usage:' '  gstaged [--stat | --check] [--] [PATH ...]' '' \
    'Description:' '  Review staged changes, optionally limited to literal file paths.' '' \
    'Options:' '  --stat        Summarize changes by file.' \
    '  --check       Check for whitespace errors and conflict markers.' \
    '  -h, --help    Show this help menu.' \
    '  --            End helper options before literal file paths.' '' \
    'Examples:' '  gstaged' '  gstaged --stat' '  gstaged --check'
}
# toolbox: git diff staged history | Review or check staged changes before committing.
# toolbox-args: [--stat | --check] [PATH ...]
# toolbox-example: gstaged
# toolbox-example: gstaged --stat
# toolbox-example: gstaged --check
gstaged() {
  emulate -L zsh
  _history_helpers_help_requested gstaged "$@" && return 0
  local -a reply flags
  if [[ "${1:-}" == --stat || "${1:-}" == --check ]]; then
    flags=("$1")
    shift
  fi
  _history_helpers_prepare gstaged 0 -1 "$@" || return $?
  _history_helpers_require gstaged git || return $?
  command git --literal-pathspecs diff --cached "${flags[@]}" -- "${reply[@]}"
}

_glog_help() {
  _history_helpers_help 'glog [COUNT]' \
    'Show recent commits with a graph and branch labels; COUNT defaults to 20.' \
    'glog' 'glog 50'
}
# toolbox: git history | Show recent commits with a graph and branch labels.
# toolbox-args: [COUNT]
# toolbox-example: glog
# toolbox-example: glog 50
glog() {
  emulate -L zsh
  _history_helpers_help_requested glog "$@" && return 0
  local -a reply
  _history_helpers_prepare glog 0 1 "$@" || return $?
  local count="${reply[1]:-20}"
  if [[ "$count" != <-> || ${#count} -gt 5 ]] || (( 10#$count < 1 || 10#$count > 10000 )); then
    print -u2 -r -- 'glog: COUNT must be an integer from 1 through 10000'
    return 2
  fi
  _history_helpers_require glog git || return $?
  command git log --oneline --decorate --graph "--max-count=$count" --
}

_gahead_help() {
  _history_helpers_help 'gahead [REF]' \
    'Show local commits missing from REF (default: cached upstream); never fetch.' \
    'gahead' 'gahead origin/main'
}
# toolbox: git history upstream | List local commits not present in an upstream or ref.
# toolbox-args: [REF]
# toolbox-example: gahead
# toolbox-example: gahead origin/main
gahead() {
  emulate -L zsh
  _history_helpers_help_requested gahead "$@" && return 0
  local -a reply
  _history_helpers_prepare gahead 0 1 "$@" || return $?
  _history_helpers_ref gahead "${reply[1]:-}" || return $?
  _history_helpers_require gahead git || return $?
  local ref="${reply[1]:-}"
  [[ -n "$ref" ]] || ref='@{u}'
  command git log --oneline --decorate "$ref..HEAD" --
}

_gbehind_help() {
  _history_helpers_help 'gbehind [REF]' \
    'Show commits missing locally from REF (default: cached upstream); never fetch.' \
    'gbehind' 'gbehind origin/main'
}
# toolbox: git history upstream | List upstream or ref commits missing locally.
# toolbox-args: [REF]
# toolbox-example: gbehind
# toolbox-example: gbehind origin/main
gbehind() {
  emulate -L zsh
  _history_helpers_help_requested gbehind "$@" && return 0
  local -a reply
  _history_helpers_prepare gbehind 0 1 "$@" || return $?
  _history_helpers_ref gbehind "${reply[1]:-}" || return $?
  _history_helpers_require gbehind git || return $?
  local ref="${reply[1]:-}"
  [[ -n "$ref" ]] || ref='@{u}'
  command git log --oneline --decorate "HEAD..$ref" --
}

_gfiles_help() {
  _history_helpers_help 'gfiles [REF]' \
    'List changed files since the merge base with REF (default: cached upstream).' \
    'gfiles' 'gfiles origin/main'
}
# toolbox: git files diff history | List branch files changed since the merge base.
# toolbox-args: [REF]
# toolbox-example: gfiles
# toolbox-example: gfiles origin/main
gfiles() {
  emulate -L zsh
  _history_helpers_help_requested gfiles "$@" && return 0
  local -a reply
  _history_helpers_prepare gfiles 0 1 "$@" || return $?
  _history_helpers_ref gfiles "${reply[1]:-}" || return $?
  _history_helpers_require gfiles git || return $?
  local ref="${reply[1]:-}"
  [[ -n "$ref" ]] || ref='@{u}'
  command git diff --name-status "$ref...HEAD" --
}

_gfilelog_help() {
  _history_helpers_help 'gfilelog [--] PATH ...' \
    'Show commits and file statistics for the selected literal file paths.' \
    'gfilelog README.md' 'gfilelog dotfiles/functions'
}
# toolbox: git files history | Show commit history and statistics for selected files.
# toolbox-args: PATH ...
# toolbox-example: gfilelog README.md
gfilelog() {
  emulate -L zsh
  _history_helpers_help_requested gfilelog "$@" && return 0
  local -a reply
  _history_helpers_prepare gfilelog 1 -1 "$@" || return $?
  _history_helpers_require gfilelog git || return $?
  command git --literal-pathspecs log --oneline --decorate --stat -- "${reply[@]}"
}

_history_helpers_search() {
  local name="$1" mode="$2"
  shift 2
  local -a reply paths flags
  _history_helpers_prepare "$name" 1 -1 "$@" || return $?
  _history_helpers_require "$name" rg || return $?
  local pattern="$reply[1]"
  paths=("${reply[@]:1}")
  (( ${#paths} )) || paths=(.)
  case "$mode" in
    lines) flags=(--line-number) ;;
    context) flags=(--line-number --context 5) ;;
    count) flags=(--count) ;;
  esac
  command rg --hidden --glob '!.git' --smart-case --no-heading \
    "${flags[@]}" -e "$pattern" -- "${paths[@]}"
}

_rfind_help() {
  _history_helpers_help 'rfind [--] PATTERN [PATH ...]' \
    'Search file contents with line numbers and smart case; PATH defaults to . .' \
    'rfind TODO' 'rfind "connection refused" logs'
}
# toolbox: search files history | Search file contents with smart case and line numbers.
# toolbox-args: PATTERN [PATH ...]
# toolbox-example: rfind TODO
# toolbox-example: rfind 'connection refused' logs
rfind() {
  emulate -L zsh
  _history_helpers_help_requested rfind "$@" && return 0
  _history_helpers_search rfind lines "$@"
}

_rcontext_help() {
  _history_helpers_help 'rcontext [--] PATTERN [PATH ...]' \
    'Search file contents with five surrounding lines; PATH defaults to . .' \
    'rcontext error' 'rcontext timeout logs'
}
# toolbox: search files context history | Search text with five lines of context.
# toolbox-args: PATTERN [PATH ...]
# toolbox-example: rcontext error
rcontext() {
  emulate -L zsh
  _history_helpers_help_requested rcontext "$@" && return 0
  _history_helpers_search rcontext context "$@"
}

_rcount_help() {
  _history_helpers_help 'rcount [--] PATTERN [PATH ...]' \
    'Count matching lines per file with smart case; PATH defaults to . .' \
    'rcount TODO' 'rcount error logs'
}
# toolbox: search files count history | Count matching lines in each file.
# toolbox-args: PATTERN [PATH ...]
# toolbox-example: rcount TODO
rcount() {
  emulate -L zsh
  _history_helpers_help_requested rcount "$@" && return 0
  _history_helpers_search rcount count "$@"
}

_ffind_help() {
  _history_helpers_help 'ffind [--] PATTERN [DIRECTORY]' \
    'Find filenames, ignoring case, including hidden and ignored files except .git.' \
    'ffind readme' 'ffind "\\.zsh$" dotfiles'
}
# toolbox: search files history | Find filenames including hidden and ignored files.
# toolbox-args: PATTERN [DIRECTORY]
# toolbox-example: ffind readme
# toolbox-example: ffind '\.zsh$' dotfiles
ffind() {
  emulate -L zsh
  _history_helpers_help_requested ffind "$@" && return 0
  local -a reply
  _history_helpers_prepare ffind 1 2 "$@" || return $?
  _history_helpers_require ffind fd || return $?
  command fd --hidden --no-ignore --ignore-case --type f --exclude .git \
    -- "$reply[1]" "${reply[2]:-.}"
}

_flines_help() {
  _history_helpers_help 'flines [DIRECTORY]' \
    'Count lines in visible, non-ignored files within five levels; default directory: .' \
    'flines' 'flines dotfiles/functions'
}
# toolbox: files lines count history | Count lines in files within five directory levels.
# toolbox-args: [DIRECTORY]
# toolbox-example: flines
# toolbox-example: flines dotfiles/functions
flines() {
  emulate -L zsh
  _history_helpers_help_requested flines "$@" && return 0
  local -a reply
  _history_helpers_prepare flines 0 1 "$@" || return $?
  _history_helpers_require flines fd wc || return $?
  local directory="${reply[1]:-.}"
  [[ "$directory" == /* ]] || directory="./$directory"
  command fd --type f --max-depth 5 --exclude .git --exclude __pycache__ \
    . "$directory" --exec-batch wc -l
}

_httpstatus_help() {
  _history_helpers_help 'httpstatus URL' \
    'Print an HTTP status code with a 30-second timeout and normal TLS verification.' \
    'httpstatus https://example.com' 'httpstatus http://localhost:8080'
}
# toolbox: network http status history | Print the HTTP status for a URL.
# toolbox-args: URL
# toolbox-example: httpstatus https://example.com
# toolbox-example: httpstatus http://localhost:8080
httpstatus() {
  emulate -L zsh
  _history_helpers_help_requested httpstatus "$@" && return 0
  local -a reply
  _history_helpers_prepare httpstatus 1 1 "$@" || return $?
  _history_helpers_require httpstatus curl || return $?
  command curl --disable --silent --show-error --max-time 30 \
    --proto '=http,https' --output /dev/null --write-out '%{http_code}\n' -- "$reply[1]"
}

_httpjson_help() {
  _history_helpers_help 'httpjson URL' \
    'Fetch and format JSON, failing on HTTP errors; timeout: 30 seconds, TLS verified.' \
    'httpjson https://api.github.com' 'httpjson http://localhost:8080/status'
}
# toolbox: network http json history | Fetch and pretty-print JSON from an HTTP URL.
# toolbox-args: URL
# toolbox-example: httpjson https://api.github.com
httpjson() {
  emulate -L zsh
  setopt localoptions pipefail
  _history_helpers_help_requested httpjson "$@" && return 0
  local -a reply results
  _history_helpers_prepare httpjson 1 1 "$@" || return $?
  _history_helpers_require httpjson curl python3 || return $?
  command curl --disable --fail --silent --show-error --max-time 30 \
    --proto '=http,https' -- "$reply[1]" | command python3 -I -S -m json.tool
  results=("${pipestatus[@]}")
  (( results[1] == 0 )) || return "${results[1]}"
  return "${results[2]}"
}

_history_helpers_port() {
  if [[ "$2" != <-> || ${#2} -gt 5 ]] || (( 10#$2 < 1 || 10#$2 > 65535 )); then
    print -u2 -r -- "$1: port must be an integer from 1 through 65535"
    return 2
  fi
}

_sshproxy_help() {
  _history_helpers_help 'sshproxy HOST [LOCAL_PORT]' \
    'Open a foreground SOCKS proxy on 127.0.0.1 (default port: 1080); stop with Ctrl-C.' \
    'sshproxy example-host' 'sshproxy example-host 1081'
}
# toolbox: network ssh proxy history | Open an SSH SOCKS proxy bound to localhost.
# toolbox-args: HOST [LOCAL_PORT]
# toolbox-example: sshproxy example-host
sshproxy() {
  emulate -L zsh
  _history_helpers_help_requested sshproxy "$@" && return 0
  local -a reply
  _history_helpers_prepare sshproxy 1 2 "$@" || return $?
  local proxy_port="${reply[2]:-1080}"
  _history_helpers_port sshproxy "$proxy_port" || return $?
  _history_helpers_require sshproxy ssh || return $?
  command ssh -o ExitOnForwardFailure=yes -N -D "127.0.0.1:$proxy_port" -- "$reply[1]"
}

_sshtunnel_help() {
  _history_helpers_help 'sshtunnel HOST LOCAL_PORT [REMOTE_PORT] [REMOTE_HOST]' \
    'Forward localhost to a remote port (defaults: LOCAL_PORT, localhost); Ctrl-C stops.' \
    'sshtunnel example-host 8080' 'sshtunnel example-host 8080 80'
}
# toolbox: network ssh tunnel history | Forward a localhost port through SSH.
# toolbox-args: HOST LOCAL_PORT [REMOTE_PORT] [REMOTE_HOST]
# toolbox-example: sshtunnel example-host 8080
# toolbox-example: sshtunnel example-host 8080 80
sshtunnel() {
  emulate -L zsh
  _history_helpers_help_requested sshtunnel "$@" && return 0
  local -a reply
  _history_helpers_prepare sshtunnel 2 4 "$@" || return $?
  local local_port="$reply[2]" remote_port="${reply[3]:-$reply[2]}" remote_host="${reply[4]:-localhost}"
  _history_helpers_port sshtunnel "$local_port" || return $?
  _history_helpers_port sshtunnel "$remote_port" || return $?
  if [[ -z "$remote_host" || "$remote_host" == *[^a-zA-Z0-9_.-]* ]]; then
    print -u2 -r -- 'sshtunnel: REMOTE_HOST must be a hostname or IPv4 address'
    return 2
  fi
  _history_helpers_require sshtunnel ssh || return $?
  command ssh -o ExitOnForwardFailure=yes -N \
    -L "127.0.0.1:$local_port:$remote_host:$remote_port" -- "$reply[1]"
}
