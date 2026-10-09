#!/usr/bin/env zsh
# setup-test: Login shell status
# Covers a new login shell starting with status 0, so the prompt does not show
# an error before the first command, with and without a work overlay.
emulate -L zsh
setopt pipefail

repo_dir="${0:A:h:h:h}"
source "$repo_dir/tests/lib/assert.sh"

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/login-status-test.XXXXXX")" || exit 1
tmp_root="${tmp_root:A}"
cleanup() {
  # Atuin's init may still be writing its search index from a detached process.
  local attempt
  for attempt in {1..20}; do
    rm -rf -- "$tmp_root" 2>/dev/null && return
    sleep 0.05
  done
  rm -rf -- "$tmp_root"
}
trap cleanup EXIT INT TERM

# start_status NAME ENV_LINES...: the status the first prompt sees in a login
# shell whose setup environment holds ENV_LINES.
start_status() {
  local name="$1" home="$tmp_root/$1"
  shift
  mkdir -p "$home/.cache"
  ln -s "$repo_dir/dotfiles/.zshrc" "$home/.zshrc"
  ln -s "$repo_dir/dotfiles/.zprofile" "$home/.zprofile"
  print -rl -- "$@" >"$home/env.zsh"
  # The system zlogin of some distributions runs after .zshrc and would hide
  # its status, so only the user's startup files run.
  print -r -- 'print -r -- "STATUS:$?"' |
    HOME="$home" SETUP_LOCAL_ENV_FILE="$home/env.zsh" ZDOTDIR="$home" TERM=dumb \
      zsh -o no_global_rcs -li 2>&1 | grep -ao 'STATUS:[0-9]*'
}

assert_equals "$(start_status personal WORK_ENV=false)" "STATUS:0"

# A work overlay that has no zshrc.zsh or zprofile.zsh of its own.
mkdir -p "$tmp_root/overlay/acme"
assert_equals "$(start_status work WORK_ENV=true JOB=acme "WORK_ROOT=$tmp_root/overlay")" "STATUS:0"

printf 'PASS: login shell status\n'
