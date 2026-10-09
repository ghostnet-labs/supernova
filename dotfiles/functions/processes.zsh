#!/usr/bin/env zsh
# Processes and ports: ports, killport, psg, hot, pinfo, vitals, and port.
# .zshrc sources every file in dotfiles/functions/.

_ports_help() {
  cat <<'EOF'
Usage:
  ports [PORT]
  ports -h | --help

Description:
  List listening TCP and UDP sockets on this Linux system. PORT limits the
  report to one exact local port. Process details unavailable to the current
  user are shown as dashes; this command never invokes sudo automatically.

Options:
  -h, --help    Show this help menu.

Examples:
  ports
  ports 22
  ports 8080
EOF
}

# toolbox: network process | Inspect listening TCP and UDP ports.
# toolbox-args: [PORT]
# toolbox-example: ports
# toolbox-example: ports 22
# toolbox-example: ports 8080
ports() {
  emulate -L zsh

  case "${1:-}" in
    -h|--help)
      _ports_help
      return 0
      ;;
    -*)
      print -u2 -r -- "ports: invalid port: $1"
      print -u2 -r -- "Run 'ports --help' for usage."
      return 2
      ;;
  esac
  (( $# <= 1 )) || {
    print -u2 -r -- "ports: at most one port is accepted"
    print -u2 -r -- "Run 'ports --help' for usage."
    return 2
  }

  local port_filter="${1:-}"
  local -i port_number
  if [[ -n "$port_filter" ]]; then
    if [[ "$port_filter" != <-> ]]; then
      print -u2 -r -- "ports: invalid port: $port_filter"
      return 2
    fi
    port_number=$(( 10#$port_filter ))
    if (( port_number < 1 || port_number > 65535 )); then
      print -u2 -r -- "ports: port must be between 1 and 65535"
      return 2
    fi
    port_filter="$port_number"
  fi

  (( $+commands[ss] )) || {
    print -u2 -r -- "ports: ss is required"
    return 1
  }

  local ss_output ss_error
  if ! ss_output="$(command ss -H -lntup 2>&1)"; then
    ss_error="${ss_output%%$'\n'*}"
    [[ -n "$ss_error" ]] || ss_error="unknown error"
    print -u2 -r -- "ports: ss failed: $ss_error"
    return 1
  fi

  local proto state recvq sendq local_endpoint peer_endpoint details
  local address port pid process
  local process_regex='users:\(\("([^"]+)",pid=([0-9]+)'
  local -i row_index=0 proto_width=5 address_width=7 port_width=4 pid_width=3 process_width=7
  local -a protos addresses ports_found pids processes

  while read -r proto state recvq sendq local_endpoint peer_endpoint details; do
    [[ -n "$proto" && -n "$local_endpoint" ]] || continue
    port="${local_endpoint##*:}"
    [[ -z "$port_filter" || "$port" == "$port_filter" ]] || continue
    address="${local_endpoint%:*}"
    address="${address#\[}"
    address="${address%\]}"
    pid="-"
    process="-"
    if [[ "$details" =~ $process_regex ]]; then
      process="${match[1]}"
      pid="${match[2]}"
    fi

    (( row_index++ ))
    protos[$row_index]="$proto"
    addresses[$row_index]="$address"
    ports_found[$row_index]="$port"
    pids[$row_index]="$pid"
    processes[$row_index]="$process"
    (( ${#proto} > proto_width )) && proto_width=${#proto}
    (( ${#address} > address_width )) && address_width=${#address}
    (( ${#port} > port_width )) && port_width=${#port}
    (( ${#pid} > pid_width )) && pid_width=${#pid}
    (( ${#process} > process_width )) && process_width=${#process}
  done <<<"$ss_output"

  if (( row_index == 0 )); then
    if [[ -n "$port_filter" ]]; then
      print -r -- "No listeners found on port $port_filter."
    else
      print -r -- "No listening TCP or UDP sockets found."
    fi
    return 0
  fi

  local row_format="%-${proto_width}s %-${address_width}s %${port_width}s %${pid_width}s %-${process_width}s\n"
  printf "$row_format" "PROTO" "ADDRESS" "PORT" "PID" "PROCESS"
  for (( row_index = 1; row_index <= ${#protos}; row_index++ )); do
    printf "$row_format" \
      "${protos[$row_index]}" "${addresses[$row_index]}" \
      "${ports_found[$row_index]}" "${pids[$row_index]}" \
      "${processes[$row_index]}"
  done
}

_killport_help() {
  cat <<'EOF'
Usage:
  killport [--force] PORT
  killport -h | --help

Description:
  Show the processes listening on PORT, ask for confirmation, and send SIGTERM.
  With --force, send SIGKILL instead. After signaling, briefly wait and report
  whether the port was released. Process ownership must be visible to the
  current user; this command never invokes sudo automatically.

Options:
  -f, --force    Send SIGKILL instead of SIGTERM.
  -h, --help     Show this help menu.

Examples:
  killport 8080
  killport --force 3000
EOF
}

# toolbox: network process | Stop processes listening on a port.
# toolbox-args: [--force] PORT
# toolbox-example: killport 8080
# toolbox-example: killport --force 3000
killport() {
  emulate -L zsh

  local force=false argument
  local -a positional
  while (( $# )); do
    argument="$1"
    shift
    case "$argument" in
      -h|--help)
        _killport_help
        return 0
        ;;
      -f|--force)
        force=true
        ;;
      -*)
        print -u2 -r -- "killport: unknown option: $argument"
        print -u2 -r -- "Run 'killport --help' for usage."
        return 2
        ;;
      *)
        positional+=("$argument")
        ;;
    esac
  done

  if (( ${#positional} != 1 )); then
    print -u2 -r -- "killport: exactly one port is required"
    print -u2 -r -- "Run 'killport --help' for usage."
    return 2
  fi

  local port="${positional[1]}"
  local -i port_number
  if [[ "$port" != <-> ]]; then
    print -u2 -r -- "killport: invalid port: $port"
    return 2
  fi
  port_number=$(( 10#$port ))
  if (( port_number < 1 || port_number > 65535 )); then
    print -u2 -r -- "killport: port must be between 1 and 65535"
    return 2
  fi
  port="$port_number"

  local tool
  for tool in ss kill sleep; do
    if (( ! $+commands[$tool] )); then
      print -u2 -r -- "killport: $tool is required"
      return 1
    fi
  done

  local ss_output ss_error
  if ! ss_output="$("$commands[ss]" -H -lntup "sport = :$port" 2>&1)"; then
    ss_error="${ss_output%%$'\n'*}"
    [[ -n "$ss_error" ]] || ss_error="unknown error"
    print -u2 -r -- "killport: ss failed: $ss_error"
    return 1
  fi
  if [[ -z "$ss_output" ]]; then
    print -r -- "No listeners found on port $port."
    return 0
  fi

  local entry process pid
  local -a pids processes
  local -A seen_pids
  while IFS= read -r entry; do
    process="${entry%%\",pid=*}"
    process="${process#\"}"
    pid="${entry##*pid=}"
    [[ -n "$pid" && -z "${seen_pids[$pid]:-}" ]] || continue
    seen_pids[$pid]=1
    pids+=("$pid")
    processes+=("$process")
  done < <(print -rn -- "$ss_output" | command grep -oE '"[^"]+",pid=[0-9]+')

  if (( ${#pids} == 0 )); then
    print -u2 -r -- "killport: a listener exists on port $port, but its process details are unavailable"
    return 1
  fi

  local -i row_index pid_width=3 process_width=7
  for (( row_index = 1; row_index <= ${#pids}; row_index++ )); do
    (( ${#pids[$row_index]} > pid_width )) && pid_width=${#pids[$row_index]}
    (( ${#processes[$row_index]} > process_width )) && process_width=${#processes[$row_index]}
  done
  local row_format="%${pid_width}s %-${process_width}s\n"
  print -r -- "Listeners on port $port:"
  printf "$row_format" "PID" "PROCESS"
  for (( row_index = 1; row_index <= ${#pids}; row_index++ )); do
    printf "$row_format" "${pids[$row_index]}" "${processes[$row_index]}"
  done

  local signal="TERM" reply
  [[ "$force" == true ]] && signal="KILL"
  if ! read -r "reply?Send SIG${signal} to ${#pids} process(es)? [y/N] "; then
    print -r -- "Canceled."
    return 1
  fi
  case "${reply:l}" in
    y|yes) ;;
    *)
      print -r -- "Canceled."
      return 1
      ;;
  esac

  local -i failure_count=0
  for pid in "${pids[@]}"; do
    if ! "$commands[kill]" "-$signal" -- "$pid"; then
      print -u2 -r -- "killport: could not send SIG${signal} to PID $pid"
      (( failure_count++ ))
    fi
  done
  (( failure_count == 0 )) || return 1

  local remaining
  local -i attempt
  for (( attempt = 1; attempt <= 10; attempt++ )); do
    if ! remaining="$("$commands[ss]" -H -lntup "sport = :$port" 2>/dev/null)"; then
      print -u2 -r -- "killport: could not verify whether port $port was released"
      return 1
    fi
    if [[ -z "$remaining" ]]; then
      print -r -- "Released port $port."
      return 0
    fi
    "$commands[sleep]" 0.1
  done

  print -u2 -r -- "killport: port $port is still in use"
  return 1
}

_psg_help() {
  cat <<'EOF'
Usage:
  psg QUERY...
  psg -- QUERY...
  psg -h | --help

Description:
  Search running processes case-insensitively by full command line. Results
  include resource usage and elapsed time, while the search process itself is
  omitted. This command is read-only.

Options:
  --            Treat all remaining arguments as search text.
  -h, --help    Show this help menu.

Examples:
  psg codex
  psg python worker
  psg -- --config production
EOF
}

# toolbox: process | Search running processes.
# toolbox-args: [--] QUERY...
# toolbox-example: psg codex
# toolbox-example: psg python worker
# toolbox-example: psg -- --config production
psg() {
  emulate -L zsh

  case "${1:-}" in
    -h|--help)
      _psg_help
      return 0
      ;;
    --)
      shift
      ;;
    -*)
      print -u2 -r -- "psg: unknown option: $1"
      print -u2 -r -- "Use 'psg -- QUERY' to search for text beginning with a dash."
      return 2
      ;;
  esac
  (( $# )) || {
    print -u2 -r -- "psg: a search query is required"
    print -u2 -r -- "Run 'psg --help' for usage."
    return 2
  }
  (( $+commands[ps] )) || {
    print -u2 -r -- "psg: ps is required"
    return 1
  }

  local query="$*"
  local query_lower="${query:l}"
  local ps_output ps_error
  if ! ps_output="$(command ps -eo pid=,ppid=,user:32=,%cpu=,%mem=,etime=,args= 2>&1)"; then
    ps_error="${ps_output%%$'\n'*}"
    [[ -n "$ps_error" ]] || ps_error="unknown error"
    print -u2 -r -- "psg: ps failed: $ps_error"
    return 1
  fi

  local pid ppid user cpu mem elapsed command_line executable
  local shell_pid="$$"
  local -i row_index=0 pid_width=3 user_width=4 cpu_width=3 mem_width=3 elapsed_width=7
  local -a pids users cpus mems elapsed_times commands_found

  while read -r pid ppid user cpu mem elapsed command_line; do
    [[ -n "$pid" && -n "$command_line" ]] || continue
    [[ "$pid" == "$shell_pid" ]] && continue
    executable="${command_line%% *}"
    [[ "$ppid" == "$shell_pid" && "${executable:t}" == "ps" ]] && continue
    [[ "${command_line:l}" == *"$query_lower"* ]] || continue

    (( row_index++ ))
    pids[$row_index]="$pid"
    users[$row_index]="$user"
    cpus[$row_index]="$cpu"
    mems[$row_index]="$mem"
    elapsed_times[$row_index]="$elapsed"
    commands_found[$row_index]="$command_line"
    (( ${#pid} > pid_width )) && pid_width=${#pid}
    (( ${#user} > user_width )) && user_width=${#user}
    (( ${#cpu} > cpu_width )) && cpu_width=${#cpu}
    (( ${#mem} > mem_width )) && mem_width=${#mem}
    (( ${#elapsed} > elapsed_width )) && elapsed_width=${#elapsed}
  done <<<"$ps_output"

  if (( row_index == 0 )); then
    print -r -- "No processes found matching: $query"
    return 1
  fi

  local row_format="%${pid_width}s %-${user_width}s %${cpu_width}s %${mem_width}s %${elapsed_width}s %s\n"
  printf "$row_format" "PID" "USER" "CPU" "MEM" "ELAPSED" "COMMAND"
  for (( row_index = 1; row_index <= ${#pids}; row_index++ )); do
    printf "$row_format" \
      "${pids[$row_index]}" "${users[$row_index]}" \
      "${cpus[$row_index]}" "${mems[$row_index]}" \
      "${elapsed_times[$row_index]}" "${commands_found[$row_index]}"
  done
}

_hot_help() {
  cat <<'EOF'
Usage:
  hot [cpu | mem]
  hot -h | --help

Description:
  Show a read-only snapshot of the 15 processes using the most CPU or memory.
  The default sort is memory. CPU and memory values are percentages.

Options:
  cpu           Sort by CPU usage, highest first.
  mem           Sort by memory usage, highest first (default).
  -h, --help    Show this help menu.

Examples:
  hot
  hot cpu
  hot mem
EOF
}

# toolbox: process system | Show the busiest processes by CPU or memory.
# toolbox-args: [cpu | mem]
# toolbox-example: hot
# toolbox-example: hot cpu
# toolbox-example: hot mem
hot() {
  emulate -L zsh

  case "${1:-mem}" in
    -h|--help)
      _hot_help
      return 0
      ;;
    cpu|mem)
      ;;
    -*)
      print -u2 -r -- "hot: unknown option: $1"
      print -u2 -r -- "Run 'hot --help' for usage."
      return 2
      ;;
    *)
      print -u2 -r -- "hot: expected cpu or mem, got: $1"
      print -u2 -r -- "Run 'hot --help' for usage."
      return 2
      ;;
  esac
  if (( $# > 1 )); then
    print -u2 -r -- "hot: at most one sort mode is accepted"
    print -u2 -r -- "Run 'hot --help' for usage."
    return 2
  fi
  (( $+commands[ps] )) || {
    print -u2 -r -- "hot: ps is required"
    return 1
  }

  local mode="${1:-mem}"
  local sort_field="%mem"
  [[ "$mode" == cpu ]] && sort_field="%cpu"

  local ps_output ps_error
  if ! ps_output="$(command ps -eo pid=,ppid=,user:32=,%cpu=,%mem=,etime=,args= --sort="-$sort_field" 2>&1)"; then
    ps_error="${ps_output%%$'\n'*}"
    [[ -n "$ps_error" ]] || ps_error="unknown error"
    print -u2 -r -- "hot: ps failed: $ps_error"
    return 1
  fi

  local pid ppid user cpu mem elapsed command_line executable
  local shell_pid="$$"
  local -i row_index=0 pid_width=3 user_width=4 cpu_width=3 mem_width=3 elapsed_width=7
  local -a pids users cpus mems elapsed_times commands_found

  while read -r pid ppid user cpu mem elapsed command_line; do
    [[ -n "$pid" && -n "$command_line" ]] || continue
    executable="${command_line%% *}"
    [[ "$pid" == "$shell_pid" ]] && continue
    [[ "$ppid" == "$shell_pid" && "${executable:t}" == "ps" ]] && continue

    (( row_index++ ))
    pids[$row_index]="$pid"
    users[$row_index]="$user"
    cpus[$row_index]="$cpu"
    mems[$row_index]="$mem"
    elapsed_times[$row_index]="$elapsed"
    commands_found[$row_index]="$command_line"
    (( ${#pid} > pid_width )) && pid_width=${#pid}
    (( ${#user} > user_width )) && user_width=${#user}
    (( ${#cpu} > cpu_width )) && cpu_width=${#cpu}
    (( ${#mem} > mem_width )) && mem_width=${#mem}
    (( ${#elapsed} > elapsed_width )) && elapsed_width=${#elapsed}
    (( row_index == 15 )) && break
  done <<<"$ps_output"

  if (( row_index == 0 )); then
    print -r -- "No processes found."
    return 1
  fi

  local row_format="%${pid_width}s %-${user_width}s %${cpu_width}s %${mem_width}s %${elapsed_width}s %s\n"
  printf "$row_format" "PID" "USER" "CPU" "MEM" "ELAPSED" "COMMAND"
  for (( row_index = 1; row_index <= ${#pids}; row_index++ )); do
    printf "$row_format" \
      "${pids[$row_index]}" "${users[$row_index]}" \
      "${cpus[$row_index]}" "${mems[$row_index]}" \
      "${elapsed_times[$row_index]}" "${commands_found[$row_index]}"
  done
}

_pinfo_help() {
  cat <<'EOF'
Usage:
  pinfo PID
  pinfo -h | --help

Description:
  Show detailed, read-only information about one Linux process: identity,
  resource usage, timing, command, executable, working directory, open-file
  count, and visible listening sockets. Details hidden from the current user
  are marked unavailable; this command never invokes sudo automatically.

Options:
  -h, --help    Show this help menu.

Examples:
  pinfo 12345
  pinfo $$
EOF
}

# toolbox: process | Inspect one process in detail.
# toolbox-args: PID
# toolbox-example: pinfo 12345
# toolbox-example: pinfo $$
pinfo() {
  emulate -L zsh

  case "${1:-}" in
    -h|--help)
      _pinfo_help
      return 0
      ;;
  esac
  if (( $# != 1 )); then
    print -u2 -r -- "pinfo: exactly one PID is required"
    print -u2 -r -- "Run 'pinfo --help' for usage."
    return 2
  fi

  local requested_pid="$1"
  local -i pid_number
  if [[ "$requested_pid" != <-> ]]; then
    print -u2 -r -- "pinfo: invalid PID: $requested_pid"
    return 2
  fi
  pid_number=$(( 10#$requested_pid ))
  if (( pid_number < 1 )); then
    print -u2 -r -- "pinfo: PID must be greater than zero"
    return 2
  fi
  requested_pid="$pid_number"

  local tool
  for tool in ps readlink; do
    if (( ! $+commands[$tool] )); then
      print -u2 -r -- "pinfo: $tool is required"
      return 1
    fi
  done

  local ps_output ps_error
  if ! ps_output="$(command ps -p "$requested_pid" -o pid=,ppid=,user:32=,stat=,%cpu=,%mem=,etime=,lstart=,args= 2>&1)" ||
      [[ -z "$ps_output" ]]; then
    ps_error="${ps_output%%$'\n'*}"
    if [[ -n "$ps_error" ]]; then
      print -u2 -r -- "pinfo: could not inspect PID $requested_pid: $ps_error"
    else
      print -u2 -r -- "pinfo: process not found: $requested_pid"
    fi
    return 1
  fi

  local pid ppid user state cpu mem elapsed
  local start_day_name start_month start_day start_time start_year command_line
  read -r pid ppid user state cpu mem elapsed start_day_name start_month start_day start_time start_year command_line <<<"$ps_output"
  if [[ "$pid" != "$requested_pid" || -z "$command_line" ]]; then
    print -u2 -r -- "pinfo: could not parse process information for PID $requested_pid"
    return 1
  fi

  local proc_dir="/proc/$requested_pid"
  local executable working_directory
  executable="$(command readlink "$proc_dir/exe" 2>/dev/null)" ||
    executable="unavailable"
  working_directory="$(command readlink "$proc_dir/cwd" 2>/dev/null)" ||
    working_directory="unavailable"

  local open_files="unavailable"
  local -a fd_entries
  if [[ -r "$proc_dir/fd" && -x "$proc_dir/fd" ]]; then
    fd_entries=("$proc_dir"/fd/*(N))
    open_files="${#fd_entries}"
  fi

  local listening="none visible"
  if (( $+commands[ss] )); then
    local ss_output proto socket_state recvq sendq local_endpoint peer_endpoint details
    local listener
    local -a listeners
    local -A seen_listeners
    if ss_output="$(command ss -H -lntup 2>/dev/null)"; then
      while read -r proto socket_state recvq sendq local_endpoint peer_endpoint details; do
        [[ "$details" == *"pid=$requested_pid,"* ]] || continue
        listener="$proto $local_endpoint"
        [[ -z "${seen_listeners[$listener]:-}" ]] || continue
        seen_listeners[$listener]=1
        listeners+=("$listener")
      done <<<"$ss_output"
      (( ${#listeners} )) && listening="${(j:, :)listeners}"
    else
      listening="unavailable (ss failed)"
    fi
  else
    listening="unavailable (ss not installed)"
  fi

  local started="$start_day_name $start_month $start_day $start_time $start_year"
  printf '%-10s %s\n' "FIELD" "VALUE"
  printf '%-10s %s\n' "PID" "$pid"
  printf '%-10s %s\n' "PPID" "$ppid"
  printf '%-10s %s\n' "USER" "$user"
  printf '%-10s %s\n' "STATE" "$state"
  printf '%-10s %s\n' "CPU" "${cpu}%"
  printf '%-10s %s\n' "MEMORY" "${mem}%"
  printf '%-10s %s\n' "STARTED" "$started"
  printf '%-10s %s\n' "ELAPSED" "$elapsed"
  printf '%-10s %s\n' "COMMAND" "$command_line"
  printf '%-10s %s\n' "EXECUTABLE" "$executable"
  printf '%-10s %s\n' "CWD" "$working_directory"
  printf '%-10s %s\n' "OPEN FILES" "$open_files"
  printf '%-10s %s\n' "LISTENING" "$listening"
}

_vitals_help() {
  cat <<'EOF'
Usage:
  vitals
  vitals -h | --help

Description:
  Show a fast, read-only health snapshot for this Linux system: uptime, load
  averages, online CPUs, memory and swap utilization, root-disk usage, and
  process counts.

Options:
  -h, --help    Show this help menu.

Examples:
  vitals
EOF
}

# toolbox: system | Show VM health at a glance.
# toolbox-example: vitals
vitals() {
  emulate -L zsh

  case "${1:-}" in
    -h|--help)
      _vitals_help
      return 0
      ;;
    '')
      ;;
    *)
      print -u2 -r -- "vitals: does not accept arguments"
      print -u2 -r -- "Run 'vitals --help' for usage."
      return 2
      ;;
  esac

  local tool
  for tool in uptime nproc free df ps numfmt; do
    if (( ! $+commands[$tool] )); then
      print -u2 -r -- "vitals: $tool is required"
      return 1
    fi
  done
  [[ -r /proc/loadavg ]] || {
    print -u2 -r -- "vitals: /proc/loadavg is unavailable"
    return 1
  }

  local uptime_output cpu_count free_output df_output ps_output
  uptime_output="$(command uptime -p 2>/dev/null)" || {
    print -u2 -r -- "vitals: could not read system uptime"
    return 1
  }
  cpu_count="$(command nproc 2>/dev/null)" || {
    print -u2 -r -- "vitals: could not read online CPU count"
    return 1
  }
  free_output="$(command free -b 2>/dev/null)" || {
    print -u2 -r -- "vitals: could not read memory utilization"
    return 1
  }
  df_output="$(command df -B1 --output=size,used,pcent / 2>/dev/null)" || {
    print -u2 -r -- "vitals: could not read root-disk utilization"
    return 1
  }
  ps_output="$(command ps -e -o stat= 2>/dev/null)" || {
    print -u2 -r -- "vitals: could not read process counts"
    return 1
  }

  local load_one load_five load_fifteen load_tasks ignored
  read -r load_one load_five load_fifteen load_tasks ignored </proc/loadavg

  local label total_bytes used_bytes free_bytes shared buffers available
  local mem_total mem_used swap_total swap_used
  while read -r label total_bytes used_bytes free_bytes shared buffers available; do
    case "$label" in
      Mem:)
        mem_total="$total_bytes"
        mem_used="$used_bytes"
        ;;
      Swap:)
        swap_total="$total_bytes"
        swap_used="$used_bytes"
        ;;
    esac
  done <<<"$free_output"
  if [[ "$mem_total" != <-> || "$mem_used" != <-> ||
        "$swap_total" != <-> || "$swap_used" != <-> ]]; then
    print -u2 -r -- "vitals: could not parse memory utilization"
    return 1
  fi

  local disk_total disk_used disk_percent
  while read -r total_bytes used_bytes label; do
    if [[ "$total_bytes" == <-> && "$used_bytes" == <-> ]]; then
      disk_total="$total_bytes"
      disk_used="$used_bytes"
      disk_percent="$label"
    fi
  done <<<"$df_output"
  if [[ "$disk_total" != <-> || "$disk_used" != <-> || "$disk_percent" != <->% ]]; then
    print -u2 -r -- "vitals: could not parse root-disk utilization"
    return 1
  fi

  local state
  local -i process_total=0 process_running=0
  while read -r state; do
    [[ -n "$state" ]] || continue
    (( process_total++ ))
    [[ "${state[1]}" == R ]] && (( process_running++ ))
  done <<<"$ps_output"

  local -a sizes
  sizes=("${(@f)$(printf '%s\n' "$mem_total" "$mem_used" "$swap_total" "$swap_used" "$disk_total" "$disk_used" |
    command numfmt --to=iec-i --suffix=B --format='%.1f')}")
  if (( ${#sizes} != 6 )); then
    print -u2 -r -- "vitals: could not format utilization values"
    return 1
  fi

  local -i mem_percent=0 swap_percent=0
  (( mem_total > 0 )) && mem_percent=$(( mem_used * 100 / mem_total ))
  (( swap_total > 0 )) && swap_percent=$(( swap_used * 100 / swap_total ))
  local swap_detail="disabled"
  if (( swap_total > 0 )); then
    swap_detail="${sizes[4]} / ${sizes[3]} (${swap_percent}%)"
  fi

  uptime_output="${uptime_output#up }"
  printf '%-9s %s\n' "METRIC" "VALUE"
  printf '%-9s %s\n' "UPTIME" "$uptime_output"
  printf '%-9s %s\n' "LOAD" "$load_one $load_five $load_fifteen"
  printf '%-9s %s\n' "CPUS" "$cpu_count online"
  printf '%-9s %s\n' "MEMORY" "${sizes[2]} / ${sizes[1]} (${mem_percent}%)"
  printf '%-9s %s\n' "SWAP" "$swap_detail"
  printf '%-9s %s\n' "ROOT DISK" "${sizes[6]} / ${sizes[5]} ($disk_percent)"
  printf '%-9s %s\n' "PROCESSES" "$process_total total, $process_running running"
}

# toolbox: network process | Inspect connections on a port with sudo lsof.
# toolbox-args: PORT
# toolbox-example: port 8080
port() {
    if [ -z "$1" ]; then
        echo "Usage: port <port_number>"
        return 1
    fi
    sudo lsof -i :$1
}
