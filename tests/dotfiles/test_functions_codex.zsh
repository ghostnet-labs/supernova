#!/usr/bin/env zsh
# setup-test: Codex functions
# Covers codex_bal in dotfiles/functions/codex.zsh.
emulate -L zsh
setopt pipefail
exec </dev/null

repo_dir="${0:A:h:h:h}"
source "$repo_dir/tests/lib/assert.sh"
original_path=("${path[@]}")
for functions_file in "$repo_dir"/dotfiles/functions/*.zsh; do source "$functions_file"; done

saved_setup_dir="${SETUP_DIR-}"
setup_dir_was_set=${+SETUP_DIR}
unset SETUP_DIR
assert_contains "$(codex_sessions_app --help)" "Usage:"
if (( setup_dir_was_set )); then export SETUP_DIR="$saved_setup_dir"; fi

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/functions-test.XXXXXX")" || exit 1
# Helpers print resolved paths; macOS TMPDIR is a symlink with a trailing slash.
tmp_root="${tmp_root:A}"
cleanup() {
  rm -rf -- "$tmp_root"
}
trap cleanup EXIT INT TERM

# These helpers ran with a scratch HOME before the split; keep them isolated.
HOME="$tmp_root/home"
mkdir -p "$HOME"

# codex_bal reads plan-specific limits from a fake Codex app server.
codex_bal_bin="$tmp_root/codex-bal-bin"
mkdir -p "$codex_bal_bin"
cat >"$codex_bal_bin/codex" <<'EOF'
#!/usr/bin/env python3
import json, os, sys, time

now = int(time.time())
plan = os.environ["CODEX_BAL_TEST_PLAN"]
window = lambda used, mins, resets_in: {"usedPercent": used, "windowDurationMins": mins, "resetsAt": now + resets_in}
limits = {"primary": None, "secondary": None, "individualLimit": None, "rateLimitReachedType": None,
          "credits": {"hasCredits": False, "unlimited": False, "balance": None}}
account = {"account": {"type": "chatgpt", "planType": plan}}
if plan == "business":
    limits["individualLimit"] = {"limit": "750000", "used": "125000.5", "remainingPercent": 83, "resetsAt": now + 30 * 86400 + 3600}
elif plan == "plus":
    limits["primary"] = window(38, 300, 2 * 3600 + 14 * 60 + 30)
    limits["secondary"] = window(12, 10080, 5 * 86400 + 3600)
elif plan == "pro":
    limits["primary"] = window(100, 300, 47 * 60 + 30)
    limits["secondary"] = window(40, 10080, 3 * 86400 + 3600)
    limits["credits"] = {"hasCredits": True, "unlimited": False, "balance": "1250"}
    limits["rateLimitReachedType"] = "rate_limit_reached"
elif plan == "apikey":
    account = {"account": {"type": "apiKey"}}
elif plan == "signedout":
    account = {"account": None}
results = {
    "account/rateLimits/read": {"rateLimits": limits, "rateLimitsByLimitId": {"codex": limits}},
    "account/usage/read": {"summary": {}, "dailyUsageBuckets": [{"startDate": time.strftime("%Y-%m-01"), "tokens": 1234567}]},
    "account/read": account,
}
for line in sys.stdin:
    request = json.loads(line)
    if "id" not in request:
        continue
    if plan in ("apikey", "signedout") and request["method"] == "account/rateLimits/read":
        reply = {"id": request["id"], "error": {"message": "authentication required"}}
    else:
        reply = {"id": request["id"], "result": results.get(request["method"], {})}
    print(json.dumps(reply), flush=True)
EOF
chmod +x "$codex_bal_bin/codex"
path=("$codex_bal_bin" "${original_path[@]}")
rehash

assert_equals "$(CODEX_BAL_TEST_PLAN=business codex_bal)" $'125,000.50 / 750,000 credits used (83% left)\nCredits reset in 31 days\n1,234,567 tokens used MTD'
assert_equals "$(CODEX_BAL_TEST_PLAN=plus codex_bal)" $'5-hour limit: 38% used (62% left), resets in 2h 14m\nWeekly limit: 12% used (88% left), resets in 6 days\n1,234,567 tokens used MTD'
assert_equals "$(CODEX_BAL_TEST_PLAN=pro codex_bal)" $'5-hour limit: 100% used (0% left), resets in 47m\nWeekly limit: 40% used (60% left), resets in 4 days\nCredit balance: 1,250\nUsage limit reached\n1,234,567 tokens used MTD'
assert_equals "$(CODEX_BAL_TEST_PLAN=free codex_bal)" $'No usage limits reported for this plan\n1,234,567 tokens used MTD'
for codex_plan codex_error in apikey "signed in with an API key" signedout "not signed in to Codex"; do
  codex_status=0
  codex_output="$(CODEX_BAL_TEST_PLAN=$codex_plan codex_bal 2>&1)" || codex_status=$?
  [[ "$codex_status" == 1 ]] || fail_test "codex_bal $codex_plan returned $codex_status"
  assert_contains "$codex_output" "$codex_error"
done
path=("${original_path[@]}")
rehash

print -r -- "PASS: codex functions checks"
