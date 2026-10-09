#!/usr/bin/env zsh
# GitHub: ghactivity.
# .zshrc sources every file in dotfiles/functions/.

_ghactivity_help() {
  cat <<'EOF'
Usage:
  ghactivity [ORG] [-n COUNT] [--summary]
  ghactivity -h | --help

Description:
  Show recent public activity for a GitHub organization: pushes, pull
  requests, reviews, issues, comments, releases, forks, and stars. GitHub keeps
  at most the 300 newest public events from the last 90 days. ORG defaults to
  $GHACTIVITY_ORG. Requests are unauthenticated so organization SSO rules never
  hide public events; if the anonymous rate limit is hit, gh api is used. The
  feed leaves out pull request titles, so a listing also runs one search, which
  has its own rate limit. gh-activity-bar shows the same feed as a menu bar app.

Options:
  -n, --limit COUNT    Number of events to show, 1-300 (default 30).
  -s, --summary        Count events by repository, actor, and type instead of
                       listing them; uses all 300 events unless -n is given.
  -h, --help           Show this help menu.

Examples:
  ghactivity my-org
  ghactivity my-org -n 100
  ghactivity anthropics --summary
  GHACTIVITY_ORG=my-org ghactivity

Environment:
  GHACTIVITY_ORG       Organization used when ORG is omitted.
EOF
}

# toolbox: git github | Show recent public activity for a GitHub organization.
# toolbox-args: [ORG] [-n COUNT] [--summary]
# toolbox-example: ghactivity my-org -n 100
# toolbox-example: ghactivity anthropics --summary
ghactivity() {
  emulate -L zsh

  local org="" limit="" summary=false
  while (( $# )); do
    case "$1" in
      -h|--help)
        _ghactivity_help
        return 0
        ;;
      -n|--limit)
        (( $# >= 2 )) || {
          print -u2 -r -- "ghactivity: $1 needs a count"
          return 2
        }
        limit="$2"
        shift
        ;;
      --limit=*)
        limit="${1#--limit=}"
        ;;
      -s|--summary)
        summary=true
        ;;
      -*)
        print -u2 -r -- "ghactivity: unknown option: $1"
        print -u2 -r -- "Run 'ghactivity --help' for usage."
        return 2
        ;;
      *)
        if [[ -n "$org" ]]; then
          print -u2 -r -- "ghactivity: at most one organization is accepted"
          print -u2 -r -- "Run 'ghactivity --help' for usage."
          return 2
        fi
        org="$1"
        ;;
    esac
    shift
  done

  org="${org:-${GHACTIVITY_ORG:-}}"
  [[ -n "$org" ]] || {
    print -u2 -r -- "ghactivity: no organization given and GHACTIVITY_ORG is unset"
    print -u2 -r -- "Run 'ghactivity --help' for usage."
    return 2
  }
  [[ "$org" =~ '^[A-Za-z0-9][A-Za-z0-9-]*$' ]] || {
    print -u2 -r -- "ghactivity: invalid organization name: $org"
    return 2
  }
  if [[ -z "$limit" ]]; then
    $summary && limit=300 || limit=30
  fi
  [[ "$limit" == <1-300> ]] || {
    print -u2 -r -- "ghactivity: count must be 1-300: $limit"
    return 2
  }

  local -i per_page=$(( limit < 100 ? limit : 100 ))
  local -i pages=$(( (limit + 99) / 100 )) page
  local tmp_dir
  tmp_dir="$(command mktemp -d "${TMPDIR:-/tmp}/ghactivity.XXXXXX")" || return 1
  {
    local -a files curl_args
    for (( page = 1; page <= pages; page++ )); do
      files+=("$tmp_dir/$page.json")
      curl_args+=(-o "$tmp_dir/$page.json" "https://api.github.com/orgs/$org/events?per_page=$per_page&page=$page")
    done
    # The feed leaves out PR titles; the org's 100 most recently updated PRs
    # cover nearly every PR in it. A failed search only leaves titles out.
    print -r -- '{}' >"$tmp_dir/titles.json"
    $summary || curl_args+=(-o "$tmp_dir/titles.json" "https://api.github.com/search/issues?q=org:$org+is:pr&sort=updated&order=desc&per_page=100")
    (( ${#curl_args} > 3 )) && curl_args=(--parallel "${curl_args[@]}")
    command curl -sSL --max-time 20 -H 'Accept: application/vnd.github+json' "${curl_args[@]}" || {
      print -u2 -r -- "ghactivity: could not reach api.github.com"
      return 1
    }

    # Error bodies are objects; event pages are arrays.
    local api_error used_gh=false
    api_error="$(command jq -rs 'map(select(type == "object") | .message // "unexpected response") | first // empty' "${files[@]}" 2>/dev/null)" || api_error="invalid JSON response"
    if [[ "$api_error" == *"rate limit"* ]] && (( $+commands[gh] )); then
      used_gh=true
      for (( page = 1; page <= pages; page++ )); do
        command gh api "orgs/$org/events?per_page=$per_page&page=$page" >"${files[$page]}" 2>/dev/null
      done
      api_error="$(command jq -rs 'map(select(type == "object") | .message // "unexpected response") | first // empty' "${files[@]}" 2>/dev/null)" || api_error="invalid JSON response"
    fi
    case "$api_error" in
      "") ;;
      "Not Found")
        print -u2 -r -- "ghactivity: organization not found: $org"
        return 1
        ;;
      *)
        print -u2 -r -- "ghactivity: GitHub API error: $api_error"
        return 1
        ;;
    esac
    # A gh token without SSO authorization for an org gets an empty first
    # page, though later pages may hold a stray event or two.
    if $used_gh && [[ "$(command jq 'length' "${files[1]}")" == 0 ]]; then
      print -u2 -r -- "ghactivity: GitHub's anonymous rate limit is used up, and your gh login sees no events for $org; it may need SSO authorization for $org"
      return 1
    fi

    local -i width=0
    [[ -t 1 ]] && width=${COLUMNS:-0}
    command jq -rs --arg org "$org" --argjson limit "$limit" --argjson width "$width" \
      --argjson summary "$summary" --rawfile search "$tmp_dir/titles.json" '
      def pad($n): tostring | . + (" " * ([$n - length, 0] | max));
      def clean: tostring | gsub("[\\t\\r\\n]+"; " ");
      def when: .created_at | fromdateiso8601 | strflocaltime("%m-%d %H:%M");
      # "[https://bugs.example.com/123][fix] Restore X" reads as "Restore X".
      def untagged: sub("^(\\s*\\[[^\\]]*\\])+[\\s:-]*"; "") as $t | if $t == "" then . else $t end;
      def titled($t): if $t then ": \($t | clean | untagged)" else "" end;
      # PR titles by "owner/repo#12" in lower case, as gh-activity-bar keys them.
      (($search | try fromjson catch {}) | .items? // [] | map(select(type == "object" and .number and .title)
        | {key: ("\(.repository_url | split("/") | .[-2:] | join("/"))#\(.number)" | ascii_downcase), value: .title})
        | from_entries) as $titles
      | def describe:
        .payload as $p
        | ($p.pull_request.title // $titles["\(.repo.name)#\($p.number // $p.pull_request.number)" | ascii_downcase]) as $pr_title
        | if .type == "PushEvent" then "pushed to \($p.ref // "" | sub("^refs/heads/"; ""))"
          elif .type == "PullRequestEvent" then "\($p.action) PR #\($p.number // $p.pull_request.number)" + titled($pr_title)
          elif .type == "PullRequestReviewEvent" then
            "\({approved: "approved", changes_requested: "requested changes on"}[$p.review.state // ""] // "reviewed")"
            + " PR #\($p.pull_request.number)" + titled($pr_title)
          elif .type == "PullRequestReviewCommentEvent" then "commented on PR #\($p.pull_request.number)" + titled($pr_title)
          elif .type == "IssuesEvent" then "\($p.action) issue #\($p.issue.number)" + titled($p.issue.title)
          elif .type == "IssueCommentEvent" then
            "commented on \(if $p.issue.pull_request then "PR" else "issue" end) #\($p.issue.number)" + titled($p.issue.title)
          elif .type == "CreateEvent" then "created \($p.ref_type)" + (if $p.ref then " \($p.ref)" else "" end)
          elif .type == "DeleteEvent" then "deleted \($p.ref_type) \($p.ref)"
          elif .type == "ReleaseEvent" then "\($p.action) release \($p.release.tag_name)"
          elif .type == "ForkEvent" then "forked to \($p.forkee.full_name)"
          elif .type == "WatchEvent" then "starred"
          elif .type == "MemberEvent" then "\($p.action) member \($p.member.login)"
          elif .type == "PublicEvent" then "made public"
          elif .type == "GollumEvent" then "edited wiki"
          elif .type == "CommitCommentEvent" then "commented on commit \($p.comment.commit_id // "" | .[:7])"
          else .type | sub("Event$"; "")
          end
        | clean;
      def fit($text; $used): if $width > 0 and ($text | length) > ([$width - $used, 20] | max)
        then $text[:([$width - $used, 20] | max) - 1] + "…" else $text end;
      def top($label; f):
        (group_by(f) | map({key: (.[0] | f), count: length}) | sort_by(-.count, .key) | .[:10]) as $rows
        | ([$rows[].key | length, ($label | length)] | max) as $w
        | "", "\($label | pad($w))  EVENTS", ($rows[] | "\(.key | pad($w))  \(.count)");

      (add // [] | sort_by(.created_at) | reverse | .[:$limit] | map(. + {
        actor_name: (.actor.display_login // .actor.login // "?" | clean),
        repo_name: (.repo.name // "?" | sub("^[^/]+/"; "") | clean)
      })) as $events
      | if ($events | length) == 0 then "\($org): no public events in the last 90 days"
        elif $summary then
          "\($org): \($events | length) public events, \($events[-1] | when) to \($events[0] | when)",
          ($events | top("REPO"; .repo_name)),
          ($events | top("ACTOR"; .actor_name)),
          ($events | top("TYPE"; .type | sub("Event$"; "")))
        else
          ([$events[].actor_name | length, 5] | max) as $aw
          | ([$events[].repo_name | length, 4] | max) as $rw
          | ("TIME         \("ACTOR" | pad($aw))  \("REPO" | pad($rw))  EVENT"),
            ($events[] | "\(when)  \(.actor_name | pad($aw))  \(.repo_name | pad($rw))  \(fit(describe; 17 + $aw + $rw))")
        end
    ' "${files[@]}"
  } always {
    command rm -rf -- "$tmp_dir"
  }
}
