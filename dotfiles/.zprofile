# Set UTF-8 locale (required for Powerlevel10k on Linux)
if [[ -z "$LANG" || "$LANG" == "C" || "$LANG" == "POSIX" ]]; then
    export LANG=en_US.UTF-8
fi

# Only fill in terminal details that are missing. TERM=dumb is a deliberate
# "no color" signal, and Apple Terminal before macOS 26 has no truecolor.
if [[ -z "$TERM" || "$TERM" == "xterm" ]]; then
    export TERM=xterm-256color
fi
if [[ -z "$COLORTERM" && "$TERM" != "dumb" && "${TERM_PROGRAM:-}" != "Apple_Terminal" ]]; then
    export COLORTERM=truecolor
fi

# Initialize Homebrew from the supported macOS or Linux locations.
for brew_command in /opt/homebrew/bin/brew /usr/local/bin/brew /home/linuxbrew/.linuxbrew/bin/brew; do
    if [[ -x "$brew_command" ]]; then
        eval "$("$brew_command" shellenv)"
        break
    fi
done
unset brew_command

# Work overlay login setup: WORK_ROOT/JOB/zprofile.zsh, when the local setup
# environment enables a work overlay. A missing file is skipped.
() {
    local env_file="${SETUP_LOCAL_ENV_FILE:-${${${:-$HOME/.zprofile}:A}:h:h}/.local/.env.zsh}"
    local WORK_ENV JOB WORK_ROOT
    [[ -r "$env_file" ]] && source "$env_file"
    [[ "${WORK_ENV:-}" == true && -n "${JOB:-}" && -n "${WORK_ROOT:-}" ]] || return 0
    [[ -r "$WORK_ROOT/$JOB/zprofile.zsh" ]] && source "$WORK_ROOT/$JOB/zprofile.zsh"
}
