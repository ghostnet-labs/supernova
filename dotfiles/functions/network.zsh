#!/usr/bin/env zsh
# Network: netcheck, sshcheck, and netrate.
# .zshrc sources every file in dotfiles/functions/.

_netcheck_help() {
  cat <<'EOF'
Usage:
  netcheck HOST [PORT]
  netcheck -h | --help

Description:
  Diagnose connectivity to HOST with bounded DNS, route, and ICMP checks. When
  HOST is an IP address, also report its reverse-DNS hostname. When PORT is
  provided, test a TCP connection. A failed ping is a warning because ICMP may
  be blocked; DNS, route, and requested TCP failures make the command return
  unsuccessfully. This command is read-only.

Options:
  -h, --help    Show this help menu.

Examples:
  netcheck github.com
  netcheck github.com 443
  netcheck 10.20.30.40 22
EOF
}

_sshcheck_help() {
  cat <<'EOF'
Usage:
  sshcheck [--auth] HOST
  sshcheck -h | --help

Description:
  Diagnose one SSH destination without opening an interactive shell. The
  default report shows effective SSH configuration, bounded DNS and TCP checks,
  and local agent state. Hosts using ProxyJump skip the misleading direct TCP
  probe. --auth follows the configured SSH route and runs only true remotely.

Options:
  --auth        Test non-interactive authentication and run true remotely.
  -h, --help    Show this help menu without reading SSH configuration.

Examples:
  sshcheck github.com
  sshcheck build-host
  sshcheck --auth build-host
EOF
}

# toolbox: network shell | Diagnose SSH configuration, connectivity, and authentication.
# toolbox-args: [--auth] HOST
# toolbox-example: sshcheck github.com
# toolbox-example: sshcheck build-host
# toolbox-example: sshcheck --auth build-host
sshcheck() {
  emulate -L zsh

  local test_auth=false
  local target=""
  while (( $# )); do
    case "$1" in
      -h|--help)
        _sshcheck_help
        return 0
        ;;
      --auth)
        test_auth=true
        ;;
      -*)
        print -u2 -r -- "sshcheck: unknown option: $1"
        print -u2 -r -- "Run 'sshcheck --help' for usage."
        return 2
        ;;
      *)
        if [[ -n "$target" ]]; then
          print -u2 -r -- "sshcheck: exactly one host is required"
          print -u2 -r -- "Run 'sshcheck --help' for usage."
          return 2
        fi
        target="$1"
        ;;
    esac
    shift
  done

  [[ -n "$target" ]] || {
    print -u2 -r -- "sshcheck: a host is required"
    print -u2 -r -- "Run 'sshcheck --help' for usage."
    return 2
  }
  (( $+commands[ssh] )) || {
    print -u2 -r -- "sshcheck: ssh is required"
    return 1
  }

  local config config_detail
  config="$(command ssh -G "$target" 2>&1)"
  if (( $? )); then
    config_detail="${config%%$'\n'*}"
    print -u2 -r -- "sshcheck: could not resolve SSH configuration for $target"
    [[ -n "$config_detail" ]] && print -u2 -r -- "  $config_detail"
    return 1
  fi

  local key value
  local effective_host="" user="" port="22" proxy_jump="none" proxy_command="none"
  local -a identity_files
  while IFS=' ' read -r key value; do
    case "$key" in
      hostname) effective_host="$value" ;;
      user) user="$value" ;;
      port) port="$value" ;;
      proxyjump) proxy_jump="$value" ;;
      proxycommand) proxy_command="$value" ;;
      identityfile) identity_files+=("$value") ;;
    esac
  done <<<"$config"
  [[ -n "$effective_host" ]] || effective_host="$target"
  [[ -n "$user" ]] || user="-"
  [[ -n "$proxy_jump" ]] || proxy_jump="none"
  [[ -n "$proxy_command" ]] || proxy_command="none"

  local proxy="none"
  if [[ "$proxy_jump" != "none" ]]; then
    proxy="ProxyJump $proxy_jump"
  elif [[ "$proxy_command" != "none" ]]; then
    proxy="ProxyCommand $proxy_command"
  fi

  print -r -- "Target: $target"
  print -r -- "Host: $effective_host"
  print -r -- "User: $user"
  print -r -- "Port: $port"
  print -r -- "Proxy: $proxy"
  if (( ${#identity_files} )); then
    print -r -- "Identity files: ${(j:, :)identity_files}"
  else
    print -r -- "Identity files: -"
  fi
  print

  local timeout_command="${commands[timeout]:-${commands[gtimeout]:-}}"
  local dns_output="" dns_detail="" tcp_output="" tcp_detail=""
  local agent_output="" agent_detail="" auth_output="" auth_detail="use --auth to test"
  local dns_result="skip" tcp_result="skip" agent_result="skip" auth_result="skip"
  local dns_checked=false
  local -i failure_count=0 agent_status=0 auth_status=0

  if [[ -z "$timeout_command" ]]; then
    dns_detail="timeout command unavailable"
  elif (( $+commands[getent] )); then
    dns_checked=true
    dns_output="$("$timeout_command" 4 getent ahosts "$effective_host" 2>/dev/null)"
    dns_detail="$(print -r -- "$dns_output" | command awk '!seen[$1]++ { if (count++) printf ", "; printf "%s", $1; if (count == 4) exit } END { print "" }')"
  elif (( $+commands[dscacheutil] )); then
    dns_checked=true
    dns_output="$("$timeout_command" 4 dscacheutil -q host -a name "$effective_host" 2>/dev/null)"
    dns_detail="$(print -r -- "$dns_output" | command awk '$1 == "ip_address:" && !seen[$2]++ { if (count++) printf ", "; printf "%s", $2; if (count == 4) exit } END { print "" }')"
  elif (( $+commands[dig] )); then
    dns_checked=true
    dns_output="$("$timeout_command" 4 dig +short "$effective_host" 2>/dev/null)"
    dns_detail="$(print -r -- "$dns_output" | command awk 'NF && !seen[$1]++ { if (count++) printf ", "; printf "%s", $1; if (count == 4) exit } END { print "" }')"
  else
    dns_detail="no supported DNS lookup command"
  fi

  if [[ -n "$dns_output" && -n "$dns_detail" ]]; then
    dns_result="ok"
  elif [[ "$proxy" != "none" && "$dns_checked" == true ]]; then
    dns_result="warn"
    dns_detail="not locally resolved; proxy may resolve it"
  elif [[ "$dns_checked" == true ]]; then
    dns_result="fail"
    dns_detail="$effective_host did not resolve"
    (( failure_count++ ))
  fi

  if [[ "$proxy" != "none" ]]; then
    tcp_detail="direct probe skipped; $proxy configured"
  elif [[ -z "$timeout_command" ]]; then
    tcp_detail="timeout command unavailable"
  elif (( ! $+commands[nc] )); then
    tcp_detail="nc unavailable"
  else
    tcp_output="$("$timeout_command" 4 nc -z -w 3 "$effective_host" "$port" 2>&1)"
    if (( $? == 0 )); then
      tcp_result="ok"
      tcp_detail="$effective_host:$port"
    else
      tcp_result="fail"
      tcp_detail="${tcp_output%%$'\n'*}"
      [[ -n "$tcp_detail" ]] || tcp_detail="connection refused or timed out"
      (( failure_count++ ))
    fi
  fi

  if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
    agent_result="none"
    agent_detail="SSH_AUTH_SOCK is unset"
  elif (( ! $+commands[ssh-add] )); then
    agent_detail="ssh-add unavailable"
  elif [[ -z "$timeout_command" ]]; then
    agent_detail="timeout command unavailable"
  else
    agent_output="$("$timeout_command" 2 ssh-add -l 2>&1)"
    agent_status=$?
    if (( agent_status == 0 )); then
      local -a agent_keys
      agent_keys=("${(@f)agent_output}")
      agent_result="ok"
      agent_detail="${#agent_keys[@]} identities"
    elif (( agent_status == 1 )); then
      agent_result="none"
      agent_detail="no identities loaded"
    else
      agent_result="warn"
      agent_detail="${agent_output%%$'\n'*}"
      [[ -n "$agent_detail" ]] || agent_detail="agent unavailable"
    fi
  fi

  if [[ "$test_auth" == true ]]; then
    auth_output="$(command ssh -o BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=1 "$target" true 2>&1)"
    auth_status=$?
    if (( auth_status == 0 )); then
      auth_result="ok"
      auth_detail="non-interactive authentication succeeded"
    else
      auth_result="fail"
      auth_detail="${auth_output%%$'\n'*}"
      [[ -n "$auth_detail" ]] || auth_detail="authentication or connection failed"
      (( failure_count++ ))
    fi
  fi

  local -a checks results details
  checks=(CONFIG DNS TCP AGENT AUTH)
  results=(ok "$dns_result" "$tcp_result" "$agent_result" "$auth_result")
  details=("effective configuration loaded" "$dns_detail" "$tcp_detail" "$agent_detail" "$auth_detail")
  local -i row_index
  printf '%-6s %-6s %s\n' "CHECK" "RESULT" "DETAIL"
  for (( row_index = 1; row_index <= ${#checks}; row_index++ )); do
    printf '%-6s %-6s %s\n' "${checks[$row_index]}" "${results[$row_index]}" "${details[$row_index]}"
  done

  (( failure_count == 0 ))
}

_netrate_help() {
  cat <<'EOF'
Usage:
  netrate
  netrate -h | --help

Description:
  Sample Linux network-interface byte counters for one second. RX/s and TX/s
  show current throughput; RECEIVED and SENT are totals since each interface
  was created or reset. Idle loopback is omitted. This command is read-only.

Options:
  -h, --help    Show this help menu.

Examples:
  netrate
EOF
}

# toolbox: network system | Show live network throughput by interface.
# toolbox-example: netrate
netrate() {
  emulate -L zsh

  case "${1:-}" in
    -h|--help)
      _netrate_help
      return 0
      ;;
    -*)
      print -u2 -r -- "netrate: unknown option: $1"
      print -u2 -r -- "Run 'netrate --help' for usage."
      return 2
      ;;
  esac
  if (( $# != 0 )); then
    print -u2 -r -- "netrate: no arguments are accepted"
    print -u2 -r -- "Run 'netrate --help' for usage."
    return 2
  fi

  local counter_file="${_NETRATE_PROC_NET_DEV:-/proc/net/dev}"
  if [[ "$OSTYPE" != linux* || ! -r "$counter_file" ]]; then
    print -u2 -r -- "netrate: Linux network counters are not available"
    return 1
  fi

  local first_snapshot second_snapshot report
  first_snapshot="$(<"$counter_file")" || {
    print -u2 -r -- "netrate: could not read network counters"
    return 1
  }
  command sleep 1
  second_snapshot="$(<"$counter_file")" || {
    print -u2 -r -- "netrate: could not read network counters"
    return 1
  }

  report="$(command awk '
    function human(value,    units, unit_count, unit_index) {
      unit_count = split("B KiB MiB GiB TiB PiB", units, " ")
      unit_index = 1
      while (value >= 1024 && unit_index < unit_count) {
        value /= 1024
        unit_index++
      }
      if (unit_index == 1) {
        return sprintf("%.0f%s", value, units[unit_index])
      }
      if (value >= 100) {
        return sprintf("%.0f%s", value, units[unit_index])
      }
      if (value >= 10) {
        return sprintf("%.1f%s", value, units[unit_index])
      }
      return sprintf("%.2f%s", value, units[unit_index])
    }

    $0 == "__NETRATE_SECOND__" {
      sample = 2
      next
    }

    index($0, ":") {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      separator = index(line, ":")
      interface = substr(line, 1, separator - 1)
      payload = substr(line, separator + 1)
      sub(/^[[:space:]]+/, "", payload)
      fields = split(payload, counters, /[[:space:]]+/)
      if (fields < 9) {
        next
      }

      if (sample != 2) {
        first_rx[interface] = counters[1] + 0
        first_tx[interface] = counters[9] + 0
        next
      }

      second_rx[interface] = counters[1] + 0
      second_tx[interface] = counters[9] + 0
      order[++interface_count] = interface
    }

    END {
      headers[1] = "INTERFACE"
      headers[2] = "RX/s"
      headers[3] = "TX/s"
      headers[4] = "RECEIVED"
      headers[5] = "SENT"
      for (column = 1; column <= 5; column++) {
        widths[column] = length(headers[column])
      }

      for (index_number = 1; index_number <= interface_count; index_number++) {
        interface = order[index_number]
        if (!(interface in first_rx)) {
          continue
        }
        rx_delta = second_rx[interface] - first_rx[interface]
        tx_delta = second_tx[interface] - first_tx[interface]
        if (rx_delta < 0) rx_delta = 0
        if (tx_delta < 0) tx_delta = 0
        if (interface == "lo" && rx_delta == 0 && tx_delta == 0) {
          continue
        }

        row_count++
        values[row_count, 1] = interface
        values[row_count, 2] = human(rx_delta) "/s"
        values[row_count, 3] = human(tx_delta) "/s"
        values[row_count, 4] = human(second_rx[interface])
        values[row_count, 5] = human(second_tx[interface])
        for (column = 1; column <= 5; column++) {
          if (length(values[row_count, column]) > widths[column]) {
            widths[column] = length(values[row_count, column])
          }
        }
      }

      if (row_count == 0) {
        print "No active network interfaces found."
        exit
      }

      printf "%-*s  %*s  %*s  %*s  %*s\n", widths[1], headers[1], \
        widths[2], headers[2], widths[3], headers[3], \
        widths[4], headers[4], widths[5], headers[5]
      for (row = 1; row <= row_count; row++) {
        printf "%-*s  %*s  %*s  %*s  %*s\n", widths[1], values[row, 1], \
          widths[2], values[row, 2], widths[3], values[row, 3], \
          widths[4], values[row, 4], widths[5], values[row, 5]
      }
    }
  ' <<<"${first_snapshot}"$'\n__NETRATE_SECOND__\n'"${second_snapshot}")" || {
    print -u2 -r -- "netrate: could not calculate network rates"
    return 1
  }

  print -r -- "$report"
}

# toolbox: network | Diagnose DNS, routing, ping, and TCP connectivity.
# toolbox-args: HOST [PORT]
# toolbox-example: netcheck github.com
# toolbox-example: netcheck github.com 443
# toolbox-example: netcheck 10.20.30.40 22
netcheck() {
  emulate -L zsh

  case "${1:-}" in
    -h|--help)
      _netcheck_help
      return 0
      ;;
    -*)
      print -u2 -r -- "netcheck: unknown option: $1"
      print -u2 -r -- "Run 'netcheck --help' for usage."
      return 2
      ;;
  esac
  if (( $# < 1 || $# > 2 )); then
    print -u2 -r -- "netcheck: a host and optional port are required"
    print -u2 -r -- "Run 'netcheck --help' for usage."
    return 2
  fi

  local host="$1"
  local port="${2:-}"
  if [[ "$host" == \[*\] ]]; then
    host="${host#\[}"
    host="${host%\]}"
  fi
  local -i port_number
  if [[ -n "$port" ]]; then
    if [[ "$port" != <-> ]]; then
      print -u2 -r -- "netcheck: invalid port: $port"
      return 2
    fi
    port_number=$(( 10#$port ))
    if (( port_number < 1 || port_number > 65535 )); then
      print -u2 -r -- "netcheck: port must be between 1 and 65535"
      return 2
    fi
    port="$port_number"
  fi

  local tool
  local -a required_tools=(timeout getent ip ping)
  [[ -n "$port" ]] && required_tools+=(nc)
  for tool in "${required_tools[@]}"; do
    if (( ! $+commands[$tool] )); then
      print -u2 -r -- "netcheck: $tool is required"
      return 1
    fi
  done

  local ptr_output ptr_detail dns_output dns_detail first_address route_output ping_output ping_detail
  local tcp_output tcp_detail
  local -i failure_count=0
  local -a checks check_results details

  if [[ "$host" == <->.<->.<->.<-> || "$host" == *:* ]]; then
    checks+=("PTR")
    if ptr_output="$(command timeout 4 getent hosts "$host" 2>/dev/null)" && [[ -n "$ptr_output" ]]; then
      ptr_detail="$(print -r -- "$ptr_output" | command awk '
        NR == 1 {
          for (field = 2; field <= NF; field++) {
            if (field > 2) printf ", "
            printf "%s", $field
          }
          print ""
          exit
        }
      ')"
    fi
    if [[ -n "$ptr_detail" ]]; then
      check_results+=("ok")
      details+=("$ptr_detail")
    else
      check_results+=("none")
      details+=("no reverse hostname")
    fi
  fi

  if dns_output="$(command timeout 4 getent ahosts "$host" 2>/dev/null)" && [[ -n "$dns_output" ]]; then
    first_address="$(print -r -- "$dns_output" | command awk 'NR == 1 { print $1; exit }')"
    dns_detail="$(print -r -- "$dns_output" | command awk '
      !seen[$1]++ {
        if (count++) printf ", "
        printf "%s", $1
        if (count == 4) exit
      }
      END { print "" }
    ')"
    checks+=("DNS")
    check_results+=("ok")
    details+=("$dns_detail")
  else
    checks+=("DNS")
    check_results+=("fail")
    details+=("$host did not resolve")
    (( failure_count++ ))
  fi

  checks+=("ROUTE")
  if [[ -z "$first_address" ]]; then
    check_results+=("skip")
    details+=("no resolved address")
  elif route_output="$(command timeout 4 ip route get "$first_address" 2>/dev/null)" && [[ -n "$route_output" ]]; then
    check_results+=("ok")
    details+=("${route_output%%$'\n'*}")
  else
    check_results+=("fail")
    details+=("no route to $first_address")
    (( failure_count++ ))
  fi

  checks+=("PING")
  if ping_output="$(command timeout 4 ping -n -c 1 -W 2 "$host" 2>/dev/null)"; then
    ping_detail="$(print -r -- "$ping_output" | command sed -n 's/.*time[=<]\([^ ]*\) ms.*/\1 ms/p' | command sed -n '1p')"
    [[ -n "$ping_detail" ]] || ping_detail="reply received"
    check_results+=("ok")
    details+=("$ping_detail")
  else
    check_results+=("warn")
    details+=("ICMP blocked or host unreachable")
  fi

  if [[ -n "$port" ]]; then
    checks+=("TCP")
    if tcp_output="$(command timeout 4 nc -z -w 3 "$host" "$port" 2>&1)"; then
      check_results+=("ok")
      details+=("$host:$port")
    else
      tcp_detail="${tcp_output%%$'\n'*}"
      [[ -n "$tcp_detail" ]] || tcp_detail="connection refused or timed out"
      check_results+=("fail")
      details+=("$host:$port — $tcp_detail")
      (( failure_count++ ))
    fi
  fi

  local -i row_index check_width=5 result_width=6
  for (( row_index = 1; row_index <= ${#checks}; row_index++ )); do
    (( ${#checks[$row_index]} > check_width )) && check_width=${#checks[$row_index]}
    (( ${#check_results[$row_index]} > result_width )) && result_width=${#check_results[$row_index]}
  done

  local row_format="%-${check_width}s %-${result_width}s %s\n"
  printf "$row_format" "CHECK" "RESULT" "DETAIL"
  for (( row_index = 1; row_index <= ${#checks}; row_index++ )); do
    printf "$row_format" \
      "${checks[$row_index]}" "${check_results[$row_index]}" "${details[$row_index]}"
  done

  (( failure_count == 0 ))
}
