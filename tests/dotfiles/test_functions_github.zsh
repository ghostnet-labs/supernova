#!/usr/bin/env zsh
# setup-test: GitHub functions
# Covers ghactivity in dotfiles/functions/github.zsh with fake curl and gh.
emulate -L zsh
setopt pipefail
exec </dev/null

repo_dir="${0:A:h:h:h}"
source "$repo_dir/tests/lib/assert.sh"
original_path=("${path[@]}")
for functions_file in "$repo_dir"/dotfiles/functions/*.zsh; do source "$functions_file"; done

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/functions-test.XXXXXX")" || exit 1
cleanup() {
  rm -rf -- "$tmp_root"
}
trap cleanup EXIT INT TERM

export TZ=UTC
unset GHACTIVITY_ORG

fake_bin="$tmp_root/bin"
mkdir -p "$fake_bin"
# Out of order on purpose: ghactivity sorts newest first.
cat >"$tmp_root/events.json" <<'EOF'
[
  {"type":"PushEvent","created_at":"2026-10-02T10:00:00Z","actor":{"login":"alice","display_login":"alice"},"repo":{"name":"acme/rocket"},"payload":{"ref":"refs/heads/main"}},
  {"type":"PullRequestEvent","created_at":"2026-10-02T12:00:00Z","actor":{"login":"bob"},"repo":{"name":"acme/rocket"},"payload":{"action":"opened","number":7,"pull_request":{"number":7}}},
  {"type":"IssueCommentEvent","created_at":"2026-10-02T11:00:00Z","actor":{"login":"carol"},"repo":{"name":"acme/website"},"payload":{"action":"created","issue":{"number":3,"title":"Broken\tlink","pull_request":{}}}},
  {"type":"PullRequestReviewEvent","created_at":"2026-10-01T09:00:00Z","actor":{"login":"bob"},"repo":{"name":"acme/rocket"},"payload":{"review":{"state":"approved"},"pull_request":{"number":7}}},
  {"type":"CreateEvent","created_at":"2026-10-01T08:00:00Z","actor":{"login":"alice"},"repo":{"name":"acme/rocket"},"payload":{"ref_type":"tag","ref":"v1.0"}},
  {"type":"WatchEvent","created_at":"2026-10-01T07:00:00Z","actor":{"login":"dave"},"repo":{"name":"acme/website"},"payload":{"action":"started"}},
  {"type":"SponsorshipEvent","created_at":"2026-10-01T06:00:00Z","actor":{"login":"erin"},"repo":{"name":"acme/rocket"},"payload":{}}
]
EOF
# Search results name repositories in their own case; titles match regardless.
cat >"$tmp_root/search.json" <<'EOF'
{"total_count":1,"items":[{"number":7,"title":"[BUG-12][fix] Retry\tfailed uploads","repository_url":"https://api.github.com/repos/Acme/Rocket"}]}
EOF
# The fake curl answers each "-o FILE URL" pair and logs the URLs it saw.
cat >"$fake_bin/curl" <<EOF
#!/usr/bin/env zsh
out=""
for arg in "\$@"; do
  case "\$arg" in
    -o) out=next ;;
    https://*)
      print -r -- "\$arg" >>"$tmp_root/curl.log"
      case "\$arg" in
        *search/issues\?q=org:empty+*) print -r -- '<html>busy</html>' >"\$out" ;;
        */search/issues*) cat "$tmp_root/search.json" >"\$out" ;;
        */orgs/missing/*) print -r -- '{"message":"Not Found"}' >"\$out" ;;
        */orgs/empty/*) print -r -- '[]' >"\$out" ;;
        */orgs/limited/*|*/orgs/sso/*) print -r -- '{"message":"API rate limit exceeded for 192.0.2.1."}' >"\$out" ;;
        *page=1) cat "$tmp_root/events.json" >"\$out" ;;
        *) print -r -- '[]' >"\$out" ;;
      esac
      ;;
    *) [[ "\$out" == next ]] && out="\$arg" ;;
  esac
done
EOF
cat >"$fake_bin/gh" <<EOF
#!/usr/bin/env zsh
print -r -- "\$*" >>"$tmp_root/gh.log"
# A token without SSO authorization sees an empty feed.
case "\$*" in
  *orgs/sso/*page=1) print -r -- '[]' ;;
  *orgs/sso/*) cat "$tmp_root/events.json" ;;
  *) cat "$tmp_root/events.json" ;;
esac
EOF
chmod +x "$fake_bin/curl" "$fake_bin/gh"
path=("$fake_bin" "${original_path[@]}")
rehash

ghactivity_help="$(ghactivity --help)" || fail_test "ghactivity help failed"
[[ "${ghactivity_help%%$'\n'*}" == "Usage:" ]] || fail_test "ghactivity help does not begin with Usage"
assert_contains "$ghactivity_help" $'\n\nDescription:'
assert_contains "$ghactivity_help" $'\n\nOptions:'
assert_contains "$ghactivity_help" $'\n\nExamples:'
assert_contains "$ghactivity_help" $'\n\nEnvironment:'
[[ ! -e "$tmp_root/curl.log" ]] || fail_test "ghactivity help contacted GitHub"

listing="$(ghactivity acme)" || fail_test "ghactivity listing failed"
listing_lines=("${(@f)listing}")
assert_equals "${listing_lines[1]}" "TIME         ACTOR  REPO     EVENT"
assert_equals "${listing_lines[2]}" "10-02 12:00  bob    rocket   opened PR #7: Retry failed uploads"
assert_equals "${listing_lines[3]}" "10-02 11:00  carol  website  commented on PR #3: Broken link"
assert_equals "${listing_lines[4]}" "10-02 10:00  alice  rocket   pushed to main"
assert_equals "${listing_lines[5]}" "10-01 09:00  bob    rocket   approved PR #7: Retry failed uploads"
assert_equals "${listing_lines[6]}" "10-01 08:00  alice  rocket   created tag v1.0"
assert_equals "${listing_lines[7]}" "10-01 07:00  dave   website  starred"
assert_equals "${listing_lines[8]}" "10-01 06:00  erin   rocket   Sponsorship"
assert_contains "$(<"$tmp_root/curl.log")" "https://api.github.com/orgs/acme/events?per_page=30&page=1"
assert_contains "$(<"$tmp_root/curl.log")" "https://api.github.com/search/issues?q=org:acme+is:pr&sort=updated&order=desc&per_page=100"

limited="$(GHACTIVITY_ORG=acme ghactivity -n 2)" || fail_test "ghactivity with GHACTIVITY_ORG failed"
assert_equals "${#${(@f)limited}}" 3
assert_contains "$(<"$tmp_root/curl.log")" "orgs/acme/events?per_page=2&page=1"

rm -f -- "$tmp_root/curl.log"
summary="$(ghactivity acme --summary)" || fail_test "ghactivity summary failed"
assert_contains "$summary" "acme: 7 public events, 10-01 06:00 to 10-02 12:00"
assert_contains "$summary" $'REPO     EVENTS\nrocket   5\nwebsite  2'
assert_contains "$summary" $'ACTOR  EVENTS\nalice  2\nbob    2'
assert_contains "$summary" "PullRequestReview  1"
curl_log="$(<"$tmp_root/curl.log")"
assert_contains "$curl_log" "per_page=100&page=3"
assert_not_contains "$curl_log" "page=4"
assert_not_contains "$curl_log" "search/issues"

# A search that answers with something other than JSON only loses titles.
assert_equals "$(ghactivity empty)" "empty: no public events in the last 90 days"

[[ ! -e "$tmp_root/gh.log" ]] || fail_test "ghactivity used gh without a rate limit"
fallback="$(ghactivity limited -n 1)" || fail_test "ghactivity did not fall back to gh after a rate limit"
assert_contains "$fallback" "bob    rocket  opened PR #7"
assert_contains "$(<"$tmp_root/gh.log")" "api orgs/limited/events?per_page=1&page=1"

expect_failure() {
  local expected_status="$1" expected_message="$2" output
  shift 2
  local -i actual_status=0
  output="$(ghactivity "$@" 2>&1)" || actual_status=$?
  [[ "$actual_status" == "$expected_status" ]] || fail_test "ghactivity $* returned $actual_status"
  assert_contains "$output" "$expected_message"
}
expect_failure 1 "organization not found: missing" missing
expect_failure 1 "may need SSO authorization for sso" sso
expect_failure 1 "may need SSO authorization for sso" sso -n 300
expect_failure 2 "GHACTIVITY_ORG is unset"
expect_failure 2 "count must be 1-300: 0" acme -n 0
expect_failure 2 "count must be 1-300: 301" acme --limit=301
expect_failure 2 "needs a count" acme -n
expect_failure 2 "invalid organization name: a/b" "a/b"
expect_failure 2 "at most one organization" acme other
expect_failure 2 "unknown option: --bogus" --bogus
