#!/usr/bin/env zsh
# Codex: token_usage, codex_bal, and codex_sessions.
# .zshrc sources every file in dotfiles/functions/.

_watch_function() {
  emulate -L zsh
  local interval="$1"
  local fn="$2"
  local has_tput=0
  local output frame args_display="" rc cols lines last_cols="" last_lines="" resized=0 first_frame=1
  local line_end=$'\033[K\n'
  shift 2

  if [[ ! "$interval" =~ '^[1-9][0-9]*$' ]]; then
    echo "Error: watch interval must be a positive integer number of seconds"
    return 1
  fi

  [[ -n "${TERM:-}" ]] && command -v tput >/dev/null 2>&1 && has_tput=1

  if (( has_tput )); then
    tput civis 2>/dev/null || true
  else
    printf '\033[?25l'
  fi

  (( $# > 0 )) && printf -v args_display ' %s' "$@"

  {
    while true; do
      resized=0
      if (( has_tput )); then
        cols="${COLUMNS:-0}"
        lines="${LINES:-0}"
        if [[ "$cols" != "$last_cols" || "$lines" != "$last_lines" ]]; then
          last_cols="$cols"
          last_lines="$lines"
          resized=1
        fi
      fi
      if (( first_frame )); then
        resized=1
        first_frame=0
      fi

      output="$(
        COLUMNS="${cols:-${COLUMNS:-0}}"
        LINES="${lines:-${LINES:-0}}"
        "$fn" "$@" 2>&1
      )"
      rc=$?

      # Build the complete refresh before writing it so tmux/Ghostty never
      # render a partially updated table. Mode 2026 is ignored if unsupported.
      frame=$'\033[?2026h\033[H'
      if (( resized )); then
        frame+=$'\033[2J\033[3J'
      else
        frame+=$'\033[2K'
      fi
      frame+="Every ${interval}s: ${fn}${args_display}    $(date)"$'\033[K\n\033[K\n'
      frame+="${output//$'\n'/$line_end}"$line_end
      if (( rc != 0 )); then
        frame+=$'\033[K\n'"Exit status: ${rc}"$'\033[K\n'
      fi
      frame+=$'\033[J\033[?2026l'
      printf '%s' "$frame"
      sleep "$interval"
    done
  } always {
    if (( has_tput )); then
      tput cnorm 2>/dev/null || true
    else
      printf '\033[?25h'
    fi
  }
}


_token_usage_help() {
  cat <<'EOF'
Usage:
  token_usage [options] [--raw | --by-model]

Description:
  Summarize local Codex token usage from the state database and rollout logs.
  The default view includes totals and the top three models by all-time usage.

Options:
  -h, --help                 Show this help menu.
  --raw                      Print only the all-thread token total.
  --by-model                 Print only the per-model usage table.
  -w, --watch                Refresh in a resize-safe terminal screen.
  -n, --interval <seconds>   Watch refresh interval (default: 2).

Examples:
  token_usage
  token_usage --by-model
  token_usage --watch --interval 10

Environment:
  CODEX_HOME                 Override Codex home (default: ~/.codex).
EOF
}

# token_usage - Show local Codex token usage by model and token type
# Args:
#   --raw       Print only the total token count
#   --by-model  Print only the by-model breakdown
#   -w, --watch Re-run in a watch-style screen
#   -n, --interval <seconds>
# Environment Variables:
#   CODEX_HOME - Override Codex home directory (default: ~/.codex)
# Returns:
#   0 on success, 1 on error
# toolbox: codex usage | Show local Codex token usage by model and token type.
# toolbox-args: [--raw | --by-model] [--watch] [--interval SECONDS]
# toolbox-example: token_usage
# toolbox-example: token_usage --by-model
# toolbox-example: token_usage --watch --interval 10
token_usage() {
  emulate -L zsh
  setopt pipefail

  local codex_home="${CODEX_HOME:-$HOME/.codex}"
  local db_path="$codex_home/state_5.sqlite"
  local mode="summary"
  local watch=0
  local interval=2
  local -a watch_args=()

  # Parse arguments first so watch mode can re-enter with only display flags.
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --raw)
        if [[ "$mode" != "summary" ]]; then
          echo "Error: choose only one of --raw or --by-model." >&2
          return 1
        fi
        mode="raw"
        watch_args+=("$1")
        shift
        ;;
      --by-model)
        if [[ "$mode" != "summary" ]]; then
          echo "Error: choose only one of --raw or --by-model." >&2
          return 1
        fi
        mode="by-model"
        watch_args+=("$1")
        shift
        ;;
      -w|--watch)
        watch=1
        shift
        ;;
      -n|--interval)
        if [[ -z "${2:-}" || "$2" == --* ]]; then
          echo "Error: $1 requires a value"
          return 1
        fi
        interval="$2"
        shift 2
        ;;
      -h|--help)
        _token_usage_help
        return 0
        ;;
      *)
        echo "Error: unknown argument: $1" >&2
        echo "Run 'token_usage --help' for usage." >&2
        return 1
        ;;
    esac
  done

  if (( watch )); then
    _watch_function "$interval" token_usage "${watch_args[@]}"
    return
  fi

  # Read Codex's local sqlite state database.
  if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "Error: sqlite3 is not installed or not in PATH"
    return 1
  fi

  if [[ ! -f "$db_path" ]]; then
    echo "Error: Codex state database not found at $db_path"
    return 1
  fi

  local summary_query="
    select
      count(*) as threads,
      coalesce(sum(tokens_used), 0) as total_tokens,
      coalesce(datetime(max(updated_at), 'unixepoch', 'localtime'), 'n/a') as latest_update
    from threads;
  "
  local comma_awk='
    function comma(n, s) {
      s = sprintf("%d", n)
      while (s ~ /^[+-]?[0-9][0-9][0-9][0-9]/) {
        sub(/[0-9][0-9][0-9]($|,)/, ",&", s)
      }
      return s
    }
  '
  local by_model_awk='
    BEGIN {
      max_model = 36
      model_w = length("Model")
      threads_w = length("Threads")
      input_w = length("Input")
      cache_pct_w = length("Cache%")
      output_w = length("Output")
      reason_pct_w = length("Reason%")
      today_w = length("Today")
      seven_w = length("7 Days")
      thirty_w = length("30 Days")
      all_time_w = length("All Time")
    }

    NF == 3 {
      row_count++
      model_name[row_count] = $1
      model[row_count] = fit(model_name[row_count], max_model)
      threads[row_count] = $2
      all_time_value[row_count] = $3
      all_time[row_count] = comma($3)
      model_w = max(model_w, length(model[row_count]))
      threads_w = max(threads_w, length(threads[row_count]))
      all_time_w = max(all_time_w, length(all_time[row_count]))
      next
    }

    NF == 8 {
      input_by_model[$1] += $2
      cached_by_model[$1] += $3
      output_by_model[$1] += $4
      reasoning_by_model[$1] += $5
      today_by_model[$1] += $6
      seven_by_model[$1] += $7
      thirty_by_model[$1] += $8
    }

    END {
      for (i = 1; i < row_count; i++) {
        for (j = i + 1; j <= row_count; j++) {
          if (all_time_value[j] > all_time_value[i]) {
            swap = model_name[i]; model_name[i] = model_name[j]; model_name[j] = swap
            swap = model[i]; model[i] = model[j]; model[j] = swap
            swap = threads[i]; threads[i] = threads[j]; threads[j] = swap
            swap = all_time_value[i]; all_time_value[i] = all_time_value[j]; all_time_value[j] = swap
            swap = all_time[i]; all_time[i] = all_time[j]; all_time[j] = swap
          }
        }
      }

      display_count = row_count < 3 ? row_count : 3
      for (i = 1; i <= display_count; i++) {
        name = model_name[i]
        input[i] = comma(input_by_model[name])
        cache_pct[i] = input_by_model[name] ? sprintf("%.1f%%", 100 * cached_by_model[name] / input_by_model[name]) : "n/a"
        output[i] = comma(output_by_model[name])
        reason_pct[i] = output_by_model[name] ? sprintf("%.1f%%", 100 * reasoning_by_model[name] / output_by_model[name]) : "n/a"
        today[i] = comma(today_by_model[name])
        seven[i] = comma(seven_by_model[name])
        thirty[i] = comma(thirty_by_model[name])
        input_w = max(input_w, length(input[i]))
        cache_pct_w = max(cache_pct_w, length(cache_pct[i]))
        output_w = max(output_w, length(output[i]))
        reason_pct_w = max(reason_pct_w, length(reason_pct[i]))
        today_w = max(today_w, length(today[i]))
        seven_w = max(seven_w, length(seven[i]))
        thirty_w = max(thirty_w, length(thirty[i]))
      }

      printf "%-*s %*s %*s %*s %*s %*s %*s %*s %*s %*s\n", model_w, "Model", threads_w, "Threads", today_w, "Today", seven_w, "7 Days", thirty_w, "30 Days", all_time_w, "All Time", cache_pct_w, "Cache%", input_w, "Input", reason_pct_w, "Reason%", output_w, "Output"
      printf "%-*s %*s %*s %*s %*s %*s %*s %*s %*s %*s\n", model_w, repeat("-", model_w), threads_w, repeat("-", threads_w), today_w, repeat("-", today_w), seven_w, repeat("-", seven_w), thirty_w, repeat("-", thirty_w), all_time_w, repeat("-", all_time_w), cache_pct_w, repeat("-", cache_pct_w), input_w, repeat("-", input_w), reason_pct_w, repeat("-", reason_pct_w), output_w, repeat("-", output_w)
      for (i = 1; i <= display_count; i++) {
        printf "%-*s %*s %*s %*s %*s %*s %*s %*s %*s %*s\n", model_w, model[i], threads_w, threads[i], today_w, today[i], seven_w, seven[i], thirty_w, thirty[i], all_time_w, all_time[i], cache_pct_w, cache_pct[i], input_w, input[i], reason_pct_w, reason_pct[i], output_w, output[i]
      }

      printf "\nCache%% and Reason%% are all-time; Today starts at local midnight; 7/30 Days are rolling windows.\n"
    }

    function fit(value, width) {
      return length(value) > width ? substr(value, 1, width - 3) "..." : value
    }

    function max(a, b) {
      return a > b ? a : b
    }

    function repeat(char, count, out) {
      out = ""
      while (length(out) < count) {
        out = out char
      }
      return out
    }
  '

  # Print the requested view.
  if [[ "$mode" == "raw" ]]; then
    sqlite3 "$db_path" "select coalesce(sum(tokens_used), 0) from threads;"
    return $?
  fi

  if ! command -v rg >/dev/null 2>&1; then
    echo "Error: rg (ripgrep) is required for token-type details"
    return 1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required for token-type details"
    return 1
  fi

  local -a rollout_dirs=() fallback_paths=()
  [[ -d "$codex_home/sessions" ]] && rollout_dirs+=("$codex_home/sessions")
  [[ -d "$codex_home/archived_sessions" ]] && rollout_dirs+=("$codex_home/archived_sessions")

  if (( ${#rollout_dirs[@]} == 0 )); then
    echo "Error: no Codex rollout directories found under $codex_home"
    return 1
  fi

  local usage_rows window_starts fallback_rollouts
  fallback_rollouts="$(sqlite3 -noheader "$db_path" \
    "select rollout_path from threads where rollout_path <> '' and coalesce(length(model), 0) = 0;")" \
    || return 1
  [[ -n "$fallback_rollouts" ]] && fallback_paths=("${(@f)fallback_rollouts}")

  window_starts="$(sqlite3 -separator $'\t' "$db_path" "
    select
      strftime('%Y-%m-%dT%H:%M:%S', 'now', 'localtime', 'start of day', 'utc'),
      strftime('%Y-%m-%dT%H:%M:%S', 'now', '-7 days'),
      strftime('%Y-%m-%dT%H:%M:%S', 'now', '-30 days');
  ")" || return 1

  local today_start seven_start thirty_start
  IFS=$'\t' read -r today_start seven_start thirty_start <<< "$window_starts"

  # Scan all rollouts once. Final events provide the all-time token-type totals;
  # positive changes in cumulative totals provide non-duplicated time windows.
  usage_rows="$(
    {
      sqlite3 -noheader -separator $'\t' "$db_path" \
        "select coalesce(model, ''), tokens_used, rollout_path from threads where rollout_path <> '';" \
        || exit 1
      if (( ${#fallback_paths[@]} > 0 )); then
        command rg --no-config --no-ignore --fixed-strings --color never --no-heading --with-filename \
          '"type":"turn_context"' "${fallback_paths[@]}" \
          || (( $? == 1 ))
      fi
      command rg --no-config --no-ignore --fixed-strings --color never --no-heading --with-filename \
        '"type":"token_count"' "${rollout_dirs[@]}" \
        || (( $? == 1 ))
    } | awk -v today_start="$today_start" -v seven_start="$seven_start" -v thirty_start="$thirty_start" '
      index($0, "\t") {
        separator = index($0, "\t")
        model = substr($0, 1, separator - 1)
        mapping = substr($0, separator + 1)
        separator = index(mapping, "\t")
        tokens = substr(mapping, 1, separator - 1)
        path = substr(mapping, separator + 1)
        models[path] = model
        needs_fallback[path] = model == ""
        thread_tokens[path] = tokens
        next
      }

      {
        separator = index($0, ":{\"timestamp\"")
        if (separator > 0) {
          path = substr($0, 1, separator - 1)
          if (path in models) {
            event = substr($0, separator + 1)

            if (index(event, "\"type\":\"turn_context\"") > 0) {
              if (needs_fallback[path]) {
                context = event
                marker = "\"model\":\""
                model_start = index(context, marker)
                if (model_start > 0) {
                  context = substr(context, model_start + length(marker))
                  models[path] = substr(context, 1, index(context, "\"") - 1)
                }
              }
              next
            }

            latest[path] = event

            timestamp = substr(event, 15, 19)
            usage = event
            marker = "\"total_token_usage\":{"
            usage_start = index(usage, marker)
            if (usage_start > 0) {
              usage = substr(usage, usage_start + length(marker))
              usage = substr(usage, 1, index(usage, "}") - 1)
              total = usage
              sub(/^.*\"total_tokens\":/, "", total)
              sub(/[^0-9].*$/, "", total)

              delta = (path in previous_total) ? total - previous_total[path] : total
              if (delta < 0) {
                delta = total
              }
              previous_total[path] = total

              if (delta > 0) {
                if (timestamp >= today_start) today[path] += delta
                if (timestamp >= seven_start) seven[path] += delta
                if (timestamp >= thirty_start) thirty[path] += delta
              }
            }
          }
        }
      }

      END {
        for (path in thread_tokens) {
          model = models[path] == "" ? "<unknown>" : models[path]
          thread_count[model]++
          model_tokens[model] += thread_tokens[path]
        }
        for (model in thread_count) {
          print "B\t" model "\t" thread_count[model] "\t" model_tokens[model]
        }
        for (path in latest) {
          model = models[path] == "" ? "<unknown>" : models[path]
          print "D\t" model "\t" today[path] + 0 "\t" seven[path] + 0 "\t" thirty[path] + 0 "\t" latest[path]
        }
      }
    ' | jq -Rr '
      if startswith("B\t") then
        ltrimstr("B\t")
      else
        capture("^D\\t(?<model>[^\\t]*)\\t(?<today>[0-9]+)\\t(?<seven>[0-9]+)\\t(?<thirty>[0-9]+)\\t(?<event>.*)$")
        | (.event | fromjson | .payload.info.total_token_usage // {}) as $usage
        | [
            .model,
            ($usage.input_tokens // 0),
            ($usage.cached_input_tokens // 0),
            ($usage.output_tokens // 0),
            ($usage.reasoning_output_tokens // 0),
            (.today | tonumber),
            (.seven | tonumber),
            (.thirty | tonumber)
          ]
        | @tsv
      end
    '
  )" || {
    echo "Error: failed to read Codex rollout token details"
    return 1
  }

  if [[ "$mode" == "by-model" ]]; then
    printf "%s\n" "$usage_rows" \
      | awk -F '\t' "${by_model_awk}${comma_awk}"
    return ${pipestatus[2]}
  fi

  local summary
  summary="$(sqlite3 -separator $'\t' "$db_path" "$summary_query")" || return 1

  local threads total_tokens latest_update
  IFS=$'\t' read -r threads total_tokens latest_update <<< "$summary"

  awk -v total="$total_tokens" -v threads="$threads" -v latest="$latest_update" '
    BEGIN {
      printf "Codex local token usage\n"
      printf "-----------------------\n"
      printf "Total tokens:  %s\n", comma(total)
      printf "Threads:       %s\n", comma(threads)
      printf "Latest update: %s\n", latest
      printf "\n"
    }
  '"$comma_awk"

  printf "%s\n" "$usage_rows" \
    | awk -F '\t' "${by_model_awk}${comma_awk}"
  return ${pipestatus[2]}
}

_codex_bal_help() {
  cat <<'EOF'
Usage:
  codex_bal [options]

Description:
  Show Codex usage limits for the signed-in plan and calendar-month token usage.
  Business plans show credits used and the credit reset; Plus and Pro plans show
  each rolling limit window (for example 5-hour and weekly) and when it resets.

Options:
  -h, --help                 Show this help menu.
  -w, --watch                Refresh in a resize-safe terminal screen.
  -n, --interval <seconds>   Watch refresh interval (default: 2).

Examples:
  codex_bal
  codex_bal --watch
  codex_bal --watch --interval 30
EOF
}

# codex_bal - Print a compact Codex credit-usage and month-to-date token summary.
# Args:
#   -w, --watch                 Re-run in a watch-style screen
#   -n, --interval <seconds>    Refresh interval for watch mode (default: 2)
# Returns:
#   0 on success, 1 when Codex cannot provide individual limit usage
# toolbox: codex usage | Show Codex plan usage limits and month-to-date tokens.
# toolbox-args: [--watch] [--interval SECONDS]
# toolbox-example: codex_bal
# toolbox-example: codex_bal --watch --interval 30
codex_bal() {
  emulate -L zsh

  local watch=0
  local interval=2

  while (( $# > 0 )); do
    case "$1" in
      -w|--watch)
        watch=1
        shift
        ;;
      -n|--interval)
        if [[ -z "${2:-}" || "$2" == --* ]]; then
          print -u2 -r -- "Error: $1 requires a value"
          return 1
        fi
        interval="$2"
        shift 2
        ;;
      -h|--help)
        _codex_bal_help
        return 0
        ;;
      *)
        print -u2 -r -- "Unknown argument: $1"
        print -u2 -r -- "Run 'codex_bal --help' for usage."
        return 1
        ;;
    esac
  done

  if (( watch )); then
    _watch_function "$interval" codex_bal
    return
  fi

  if ! command -v codex >/dev/null 2>&1; then
    print -u2 -r -- "Error: codex is not installed or not in PATH"
    return 1
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    print -u2 -r -- "Error: python3 is required"
    return 1
  fi

  python3 - <<'PY'
import json
import math
import os
import select
import subprocess
import sys
import time
from datetime import datetime
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP

TIMEOUT_SECONDS = 10


def fail(message):
    print(f"Error: {message}", file=sys.stderr)
    raise SystemExit(1)


def error_message(reply):
    error = reply.get("error")
    if error is None:
        return None
    return (error.get("message") if isinstance(error, dict) else None) or "Codex request failed"


def decimal(value):
    if value is None or isinstance(value, bool):
        return None
    try:
        number = Decimal(str(value))
    except InvalidOperation:
        return None
    return number if number.is_finite() else None


def reset_phrase(raw):
    # Short windows count down in hours and minutes; long ones in days.
    if isinstance(raw, bool):
        return None
    try:
        reset_at = float(raw)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(reset_at) or reset_at <= 0:
        return None
    seconds = reset_at - time.time()
    if seconds <= 0:
        return "pending"
    if seconds < 86400:
        hours, minutes = divmod(max(60, int(seconds)) // 60, 60)
        return f"in {hours}h {minutes}m" if hours else f"in {minutes}m"
    days = math.ceil(seconds / 86400)
    return f"in {days} {'day' if days == 1 else 'days'}"


def window_title(minutes, fallback):
    try:
        total = int(minutes)
    except (TypeError, ValueError):
        return fallback
    if total <= 0:
        return fallback
    if total == 10080:
        return "Weekly limit"
    if total == 1440:
        return "Daily limit"
    if total % 1440 == 0:
        return f"{total // 1440}-day limit"
    if total % 60 == 0:
        return f"{total // 60}-hour limit"
    return f"{total}-minute limit"


def format_number(value):
    return f"{value:,.0f}" if value == value.to_integral_value() else f"{value:,.2f}"


process = subprocess.Popen(
    ["codex", "app-server", "--stdio"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
)
# Replies by request id: 2 = rate limits, 3 = token usage, 4 = account.
replies = {}


def send(message):
    process.stdin.write((json.dumps({"jsonrpc": "2.0", **message}) + "\n").encode())
    process.stdin.flush()


try:
    send({
        "id": 1,
        "method": "initialize",
        "params": {"clientInfo": {"name": "codex_bal", "version": "1.0.0"}},
    })

    # Read raw bytes and split lines here: a buffered readline() can hold a
    # second reply where select() cannot see it, stalling until the timeout.
    deadline = time.monotonic() + TIMEOUT_SECONDS
    pending = b""
    while len(replies) < 3:
        if b"\n" not in pending:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                fail("timed out reading Codex rate limits")

            readable, _, _ = select.select([process.stdout], [], [], remaining)
            if not readable:
                fail("timed out reading Codex rate limits")

            chunk = os.read(process.stdout.fileno(), 65536)
            if not chunk:
                fail("Codex app server exited before returning rate limits")
            pending += chunk
            continue

        line, pending = pending.split(b"\n", 1)
        try:
            message = json.loads(line)
        except ValueError:
            continue
        message_id = message.get("id")
        if message_id == 1:
            error = error_message(message)
            if error:
                fail(error)
            send({"method": "initialized", "params": {}})
            send({"id": 2, "method": "account/rateLimits/read", "params": None})
            send({"id": 3, "method": "account/usage/read", "params": None})
            send({"id": 4, "method": "account/read", "params": {"refreshToken": False}})
        elif message_id in (2, 3, 4):
            replies[message_id] = message
finally:
    if process.stdin is not None:
        process.stdin.close()
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        process.terminate()
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            process.kill()

# Explain logins that cannot report limits before surfacing a raw read error.
account_result = replies[4].get("result")
if isinstance(account_result, dict):
    account = account_result.get("account")
    account_type = account.get("type") if isinstance(account, dict) else None
    if account_type is None:
        fail("not signed in to Codex; run 'codex login'")
    if account_type == "apiKey":
        fail("Codex is signed in with an API key; usage limits are only reported for ChatGPT plans")
    if account_type == "amazonBedrock":
        fail("Codex is using Amazon Bedrock; usage limits are only reported for ChatGPT plans")

error = error_message(replies[2])
if error:
    fail(error)
rate_limits_result = replies[2].get("result") or {}
rate_limits_by_id = rate_limits_result.get("rateLimitsByLimitId") or {}
rate_limits = rate_limits_by_id.get("codex") or rate_limits_result.get("rateLimits") or {}
output = []

# Business-style plans meter a credit allowance.
individual_limit = rate_limits.get("individualLimit")
if isinstance(individual_limit, dict):
    limit_value = decimal(individual_limit.get("limit"))
    used_value = decimal(individual_limit.get("used"))
    if limit_value is None or used_value is None:
        fail("Codex returned an invalid credit limit or usage value")
    if limit_value <= 0:
        fail("Codex returned a non-positive credit limit")
    remaining_percent = individual_limit.get("remainingPercent")
    if remaining_percent is None:
        remaining = max(Decimal("0"), limit_value - used_value)
        remaining_percent = int((remaining * 100 / limit_value).quantize(Decimal("1"), rounding=ROUND_HALF_UP))
    used_text = f"{used_value.quantize(Decimal('0.01'), rounding=ROUND_HALF_UP):,.2f}"
    output.append(f"{used_text} / {format_number(limit_value)} credits used ({remaining_percent}% left)")
    phrase = reset_phrase(individual_limit.get("resetsAt"))
    output.append(f"Credits reset {phrase}" if phrase else "Credits reset date unknown")

# Plus/Pro-style plans meter rolling time windows.
for key, fallback in (("primary", "Short-term limit"), ("secondary", "Long-term limit")):
    window = rate_limits.get(key)
    used_percent = decimal(window.get("usedPercent")) if isinstance(window, dict) else None
    if used_percent is None:
        continue
    used = min(100, max(0, int(used_percent.quantize(Decimal("1"), rounding=ROUND_HALF_UP))))
    line = f"{window_title(window.get('windowDurationMins'), fallback)}: {used}% used ({100 - used}% left)"
    phrase = reset_phrase(window.get("resetsAt"))
    output.append(f"{line}, resets {phrase}" if phrase else line)

if not output:
    output.append("No usage limits reported for this plan")

credits = rate_limits.get("credits") or {}
balance = decimal(credits.get("balance"))
if credits.get("unlimited") is True:
    output.append("Credit balance: unlimited")
elif balance is not None:
    output.append(f"Credit balance: {format_number(balance)}")

reached = rate_limits.get("rateLimitReachedType")
if reached == "rate_limit_reached":
    output.append("Usage limit reached")
elif isinstance(reached, str) and reached.endswith("credits_depleted"):
    output.append("Workspace credits used up")
elif reached:
    output.append("Workspace usage limit reached")

month_tokens_text = "n/a"
daily_buckets = None if error_message(replies[3]) else (replies[3].get("result") or {}).get("dailyUsageBuckets")
if daily_buckets is not None:
    try:
        month_prefix = datetime.now().astimezone().strftime("%Y-%m")
        month_tokens = 0
        for bucket in daily_buckets:
            if not isinstance(bucket, dict):
                continue
            start_date = bucket.get("startDate")
            if not isinstance(start_date, str) or not start_date.startswith(month_prefix):
                continue
            month_tokens += int(bucket.get("tokens", 0))
        month_tokens_text = f"{month_tokens:,}"
    except (TypeError, ValueError, OverflowError):
        pass
output.append(f"{month_tokens_text} tokens used MTD")
print("\n".join(output))
PY
}

_codex_sessions_help() {
  cat <<'EOF'
Usage:
  codex_sessions [options]

Description:
  List currently running local Codex CLI processes and app servers. When local
  rollout metadata is available, also show their model, task state, and agents.

Options:
  -h, --help                 Show this help menu.
  --raw                      Print only the number of Codex CLI processes.
  -w, --watch                Refresh in a resize-safe terminal screen.
  -n, --interval <seconds>   Watch refresh interval (default: 2).

Examples:
  codex_sessions
  codex_sessions --raw
  codex_sessions --watch --interval 5

Environment:
  CODEX_HOME                 Override Codex home (default: ~/.codex).
EOF
}

# codex_sessions - Show active Codex CLI sessions and app server processes
# Args:
#   --raw  Print only the active CLI session count
#   -w, --watch Re-run in a watch-style screen
#   -n, --interval <seconds>
# Returns:
#   0 on success, 1 on error
# toolbox: codex process | Show active Codex sessions and app server processes.
# toolbox-args: [--raw] [--watch] [--interval SECONDS]
# toolbox-example: codex_sessions
# toolbox-example: codex_sessions --raw
# toolbox-example: codex_sessions --watch --interval 5
codex_sessions() {
  emulate -L zsh

  local mode="summary"
  local terminal_width="${COLUMNS:-0}"
  local codex_home="${CODEX_HOME:-$HOME/.codex}"
  local db_path="$codex_home/state_5.sqlite"
  local ps_output
  local cli_count=0
  local app_server_count=0
  local subagent_count=0
  local has_lsof=0
  local has_sqlite3=0
  local has_jq=0
  local watch=0
  local interval=2
  local -a watch_args=()
  local thread_id_regex='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

  # Parse arguments and preserve display flags for watch mode.
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --raw)
        mode="raw"
        watch_args+=("$1")
        shift
        ;;
      -w|--watch)
        watch=1
        shift
        ;;
      -n|--interval)
        if [[ -z "${2:-}" || "$2" == --* ]]; then
          echo "Error: $1 requires a value"
          return 1
        fi
        interval="$2"
        shift 2
        ;;
      -h|--help)
        _codex_sessions_help
        return 0
        ;;
      *)
        echo "Error: unknown argument: $1" >&2
        echo "Run 'codex_sessions --help' for usage." >&2
        return 1
        ;;
    esac
  done

  if (( watch )); then
    _watch_function "$interval" codex_sessions "${watch_args[@]}"
    return
  fi

  # Read process state once, then enrich matching Codex processes.
  if ! command -v ps >/dev/null 2>&1; then
    echo "Error: ps is not installed or not in PATH"
    return 1
  fi

  if ! ps_output="$(ps -ax -o pid= -o ppid= -o stat= -o etime= -o command=)"; then
    echo "Error: unable to read the process list"
    return 1
  fi

  command -v lsof >/dev/null 2>&1 && has_lsof=1
  command -v sqlite3 >/dev/null 2>&1 && has_sqlite3=1
  command -v jq >/dev/null 2>&1 && has_jq=1

  # Build tab-delimited rows for a single final formatting pass.
  local -a rows=()
  local -a rollout_paths=()
  local type pid ppid stat etime command
  local rollout_candidates
  local subagent_rows subagent_depth subagent_nickname subagent_path subagent_model subagent_tokens subagent_rollout
  local subagent_last_line subagent_title
  while IFS=$'\t' read -r type pid ppid stat etime command; do
    if [[ "$type" == "cli" ]]; then
      (( cli_count++ ))
    else
      (( app_server_count++ ))
    fi

    if [[ "$mode" == "raw" ]]; then
      continue
    fi

    local state="-"
    [[ "$type" == "cli" ]] && state="idle"

    local model="-" tokens="-" context_left="-" context_used="-" title="-"
    local rollout_path="" rollout_file="" thread_id="" thread_info="" token_info="" latest_event=""
    if [[ "$type" == "cli" && -n "$pid" && "$has_lsof" == "1" ]]; then
      rollout_candidates="$(
        lsof -w -Fn -p "$pid" 2>/dev/null \
          | sed -n 's/^n//p' \
          | awk '/\/\.codex\/sessions\/.*\/rollout-.*\.jsonl$/ {print}'
      )"

      # A process also opens its sub-agent rollouts. Prefer the root CLI
      # thread rather than whichever rollout lsof happens to return first.
      if [[ -n "$rollout_candidates" ]]; then
        rollout_paths=("${(@f)rollout_candidates}")
        rollout_path="$(awk '
          FNR == 1 {
            if (index($0, "\"source\":\"cli\",\"thread_source\":")) {
              print FILENAME
              exit
            }
            nextfile
          }
        ' "${rollout_paths[@]}" 2>/dev/null)"
      fi
      [[ -z "$rollout_path" && -n "$rollout_candidates" ]] && rollout_path="${${(f)rollout_candidates}[1]}"
    fi

    if [[ -n "$rollout_path" ]]; then
      state="busy"
      rollout_file="${rollout_path##*/}"
      thread_id="$(printf "%s\n" "$rollout_file" | sed -E 's/^rollout-[0-9T-]+-([0-9a-fA-F-]{36})\.jsonl$/\1/')"
      if [[ "$thread_id" == "$rollout_file" ]]; then
        thread_id=""
      fi
      if [[ -n "$thread_id" && ! "$thread_id" =~ $thread_id_regex ]]; then
        thread_id=""
      fi

      if [[ -n "$thread_id" && -f "$db_path" && "$has_sqlite3" == "1" ]]; then
        thread_info="$(sqlite3 -separator $'\t' "$db_path" "select coalesce(model, ''), coalesce(nullif(title, ''), substr(id, 1, 8)) from threads where id = '$thread_id';" 2>/dev/null)"
        if [[ -n "$thread_info" ]]; then
          IFS=$'\t' read -r model title <<< "$thread_info"
          [[ -z "$model" ]] && model="-"
          [[ -z "$title" ]] && title="-"
        fi
      fi

      if [[ "$has_jq" == "1" ]]; then
        token_info="$(
          jq -nr '
            reduce inputs as $item (
              {event: "", total: "", input: "", window: ""};
              .event = (
                if $item.type == "event_msg" then
                  ($item.payload.type // .event)
                elif $item.type == "response_item" then
                  ($item.payload.type // .event)
                else
                  .event
                end
              )
              | if $item.type == "event_msg" and $item.payload.type == "token_count" then
                  .total = ($item.payload.info.total_token_usage.total_tokens // "")
                  | .input = ($item.payload.info.last_token_usage.input_tokens // "")
                  | .window = ($item.payload.info.model_context_window // "")
                else
                  .
                end
            )
            | [.event, .total, .input, .window]
            | @tsv' "$rollout_path" 2>/dev/null
        )"
        if [[ -n "$token_info" ]]; then
          local total_tokens="" input_tokens="" context_window=""
          IFS=$'\t' read -r latest_event total_tokens input_tokens context_window <<< "$token_info"
          [[ "$latest_event" == "task_complete" ]] && state="waiting"
          if [[ "$total_tokens" == <-> && "$input_tokens" == <-> && "$context_window" == <-> && "$context_window" -gt 0 ]]; then
            tokens="$total_tokens"
            context_used="$input_tokens"
            context_left="$(( context_window - input_tokens ))"
          fi
        fi
      fi
    fi

    rows+=("${type}"$'\t'"${state}"$'\t'"${pid}"$'\t'"${ppid}"$'\t'"${stat}"$'\t'"${etime}"$'\t'"${model}"$'\t'"${tokens}"$'\t'"${context_used}"$'\t'"${context_left}"$'\t'"${title}")

    # Sub-agents share their parent's Codex process, so discover them through
    # thread metadata instead of looking for additional operating-system PIDs.
    if [[ "$type" == "cli" && -n "$thread_id" && "$has_sqlite3" == "1" ]]; then
      subagent_rows="$(sqlite3 -separator $'\034' "$db_path" "
        with recursive descendants as (
          select
            id,
            coalesce(json_extract(source, '$.subagent.thread_spawn.depth'), 1) as depth,
            coalesce(agent_nickname, json_extract(source, '$.subagent.thread_spawn.agent_nickname'), substr(id, 1, 8)) as nickname,
            coalesce(agent_path, json_extract(source, '$.subagent.thread_spawn.agent_path'), '') as agent_path,
            coalesce(model, '-') as model,
            tokens_used,
            rollout_path
          from threads
          where json_valid(source)
            and json_extract(source, '$.subagent.thread_spawn.parent_thread_id') = '$thread_id'
          union all
          select
            child.id,
            coalesce(json_extract(child.source, '$.subagent.thread_spawn.depth'), descendants.depth + 1),
            coalesce(child.agent_nickname, json_extract(child.source, '$.subagent.thread_spawn.agent_nickname'), substr(child.id, 1, 8)),
            coalesce(child.agent_path, json_extract(child.source, '$.subagent.thread_spawn.agent_path'), ''),
            coalesce(child.model, '-'),
            child.tokens_used,
            child.rollout_path
          from threads child
          join descendants
            on json_valid(child.source)
           and json_extract(child.source, '$.subagent.thread_spawn.parent_thread_id') = descendants.id
        )
        select depth, nickname, agent_path, model, tokens_used, rollout_path
        from descendants
        order by depth, nickname;
      " 2>/dev/null)"

      if [[ -n "$subagent_rows" ]]; then
        while IFS=$'\034' read -r subagent_depth subagent_nickname subagent_path subagent_model subagent_tokens subagent_rollout; do
          [[ -f "$subagent_rollout" ]] || continue
          subagent_last_line="$(tail -n 1 "$subagent_rollout" 2>/dev/null)"
          if [[ "$subagent_last_line" == *'"type":"event_msg","payload":{"type":"task_complete"'* ]]; then
            continue
          fi

          subagent_title="$subagent_nickname"
          [[ -n "$subagent_path" ]] && subagent_title+=" $subagent_path"
          (( subagent_depth > 1 )) && subagent_title+=" (depth $subagent_depth)"
          rows+=("subagent"$'\t'"busy"$'\t'"-"$'\t'"${pid}"$'\t'"-"$'\t'"-"$'\t'"${subagent_model}"$'\t'"${subagent_tokens}"$'\t'"-"$'\t'"-"$'\t'"${subagent_title}")
          (( subagent_count++ ))
        done <<< "$subagent_rows"
      fi
    fi
  done < <(
    printf "%s\n" "$ps_output" \
      | awk '
          {
            pid=$1
            ppid=$2
            stat=$3
            etime=$4
            $1=$2=$3=$4=""
            sub(/^ +/, "")
            command=$0

            if (command == "codex" || command ~ /(^|\/)codex$/) {
              printf "cli\t%s\t%s\t%s\t%s\t%s\n", pid, ppid, stat, etime, command
            } else if (command ~ /(^|\/)codex[[:space:]]+app-server([[:space:]]|$)/) {
              printf "app-server\t%s\t%s\t%s\t%s\t%s\n", pid, ppid, stat, etime, command
            }
          }
        '
  )

  if [[ "$mode" == "raw" ]]; then
    echo "$cli_count"
    return 0
  fi

  # Print a compact process table plus totals.
  if [[ ${#rows[@]} -eq 0 ]]; then
    echo "No Codex processes found."
  else
    printf "%s\n" "${rows[@]}" \
      | awk -F '\t' -v terminal_width="$terminal_width" '
          BEGIN {
            max_model = 24
            max_title = 64
            header[1] = "TYPE"
            header[2] = "STATE"
            header[3] = "PID"
            header[4] = "STAT"
            header[5] = "ELAPSED"
            header[6] = "MODEL"
            header[7] = "TOKENS"
            header[8] = "CTX USED"
            header[9] = "CTX LEFT"
            header[10] = "TITLE"
            for (i = 1; i <= 10; i++) {
              width[i] = length(header[i])
            }
          }

          {
            row_count++
            value[row_count,1] = $1
            value[row_count,2] = $2
            value[row_count,3] = $3
            value[row_count,4] = $5
            value[row_count,5] = $6
            value[row_count,6] = fit($7, max_model)
            value[row_count,7] = comma($8)
            value[row_count,8] = comma($9)
            value[row_count,9] = comma($10)
            value[row_count,10] = fit($11, max_title)
            for (i = 1; i <= 10; i++) {
              width[i] = max(width[i], length(value[row_count,i]))
            }
          }

          END {
            # Keep the table inside the pane so terminal autowrap cannot move
            # rows while the watch display is being refreshed.
            if (terminal_width ~ /^[0-9]+$/ && terminal_width > 1) {
              total_width = 9
              for (i = 1; i <= 10; i++) {
                total_width += width[i]
              }
              overflow = total_width - (terminal_width - 1)
              overflow = shrink(10, length(header[10]), overflow)
              overflow = shrink(6, length(header[6]), overflow)
              overflow = shrink(5, length(header[5]), overflow)
              overflow = shrink(1, length(header[1]), overflow)
              overflow = shrink(2, length(header[2]), overflow)
            }

            printf "%-*s %-*s %*s %-*s %-*s %-*s %*s %*s %*s %s\n",
              width[1], header[1],
              width[2], header[2],
              width[3], header[3],
              width[4], header[4],
              width[5], header[5],
              width[6], header[6],
              width[7], header[7],
              width[8], header[8],
              width[9], header[9],
              header[10]
            printf "%-*s %-*s %*s %-*s %-*s %-*s %*s %*s %*s %s\n",
              width[1], repeat("-", width[1]),
              width[2], repeat("-", width[2]),
              width[3], repeat("-", width[3]),
              width[4], repeat("-", width[4]),
              width[5], repeat("-", width[5]),
              width[6], repeat("-", width[6]),
              width[7], repeat("-", width[7]),
              width[8], repeat("-", width[8]),
              width[9], repeat("-", width[9]),
              repeat("-", width[10])
            for (row = 1; row <= row_count; row++) {
              printf "%-*s %-*s %*s %-*s %-*s %-*s %*s %*s %*s %s\n",
                width[1], value[row,1],
                width[2], value[row,2],
                width[3], value[row,3],
                width[4], value[row,4],
                width[5], value[row,5],
                width[6], value[row,6],
                width[7], value[row,7],
                width[8], value[row,8],
                width[9], value[row,9],
                value[row,10]
            }
          }

          function fit(value, width) {
            return length(value) > width ? substr(value, 1, width - 3) "..." : value
          }

          function max(a, b) {
            return a > b ? a : b
          }

          function shrink(column, minimum, overflow, room, reduction, row) {
            if (overflow <= 0 || width[column] <= minimum) {
              return overflow
            }
            room = width[column] - minimum
            reduction = overflow < room ? overflow : room
            width[column] -= reduction
            for (row = 1; row <= row_count; row++) {
              value[row,column] = fit(value[row,column], width[column])
            }
            return overflow - reduction
          }

          function repeat(char, count, out) {
            out = ""
            while (length(out) < count) {
              out = out char
            }
            return out
          }

          function comma(n, s) {
            if (n == "" || n == "-") {
              return "-"
            }
            s = sprintf("%d", n)
            while (s ~ /^[+-]?[0-9][0-9][0-9][0-9]/) {
              sub(/[0-9][0-9][0-9]($|,)/, ",&", s)
            }
            return s
          }
        '
  fi

  printf "\nCodex CLI sessions: %d\n" "$cli_count"
  printf "Codex app servers:  %d\n" "$app_server_count"
  printf "Active sub-agents:  %d\n" "$subagent_count"
}


_codex_sessions_app_help() {
  printf '%s\n' 'Usage:
  codex_sessions_app [ACTION]

Description:
  Compatibility helper for the Agent Control Center conversation browser.

Options:
  --open          Open the browser (default; --start is an alias here).
  --install       Build and migrate to Agent Control Center.
  --status        Show installation and running state.
  --stop          Stop Agent Control Center.
  --uninstall     Remove Agent Control Center.
  -h, --help      Show this help.

Examples:
  codex_sessions_app
  codex_sessions_app --install
  agent-control-center --open'
}

# toolbox: codex app sessions | Open Agent Control Center (compatibility helper).
# toolbox-args: [--open | --install | --status | --stop | --uninstall]
# toolbox-example: codex_sessions_app
# toolbox-example: codex_sessions_app --status
codex_sessions_app() {
  emulate -L zsh
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    _codex_sessions_app_help
    return 0
  fi
  local launcher="${SETUP_DIR:-}/dotfiles/.bin/agent-control-center"
  if [[ ! -f "$launcher" ]]; then
    echo "Error: Agent Control Center launcher not found: $launcher" >&2
    return 1
  fi
  if (( $# == 0 )) || [[ "${1:-}" == "--start" ]]; then
    bash "$launcher" --open
  else
    bash "$launcher" "$@"
  fi
}
