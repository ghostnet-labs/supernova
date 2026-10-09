#!/usr/bin/env zsh
# Git: groot, changes, branches, worktrees, repos, and stashes.
# .zshrc sources every file in dotfiles/functions/.

# toolbox: git navigation | Jump to the root of the current Git worktree.
# toolbox-example: groot
groot() {
  (( $# == 0 )) || {
    print -u2 -r -- "groot: this command does not accept arguments"
    return 2
  }

  local root
  root="$(command git rev-parse --show-toplevel 2>/dev/null)" || {
    print -u2 -r -- "groot: not inside a Git worktree"
    return 1
  }
  builtin cd -- "$root"
}

_changes_help() {
  cat <<'EOF'
Usage:
  changes [--stat]
  changes -h | --help

Description:
  Show a fast, read-only preflight for the current Git worktree. The report
  includes the branch and cached upstream divergence, stash count, change
  counts, and every staged, unstaged, untracked, or conflicted path. No remote
  is fetched and no repository state is changed.

Options:
  --stat        Add staged and unstaged diff statistics.
  -h, --help    Show this help menu.

Examples:
  changes
  changes --stat
  cd ~/dev/project && changes
EOF
}

# toolbox: git | Show the current worktree's exact change state.
# toolbox-args: [--stat]
# toolbox-example: changes
# toolbox-example: changes --stat
changes() {
  emulate -L zsh

  local show_stat=false
  while (( $# )); do
    case "$1" in
      -h|--help)
        _changes_help
        return 0
        ;;
      --stat)
        show_stat=true
        ;;
      *)
        print -u2 -r -- "changes: unknown option or argument: $1"
        print -u2 -r -- "Run 'changes --help' for usage."
        return 2
        ;;
    esac
    shift
  done

  local root
  root="$(command git rev-parse --show-toplevel 2>/dev/null)" || {
    print -u2 -r -- "changes: not inside a Git worktree"
    return 1
  }

  local status_snapshot
  status_snapshot="$(GIT_OPTIONAL_LOCKS=0 command git -C "$root" status --porcelain=v2 --branch --ahead-behind 2>/dev/null)" || {
    print -u2 -r -- "changes: could not inspect the Git worktree"
    return 1
  }

  local branch="(detached)" upstream="" oid="" line payload xy file_path
  local -i ahead=0 behind=0 staged=0 unstaged=0 untracked=0 conflicts=0
  local -i field_index
  local -a statuses paths

  while IFS= read -r line; do
    case "$line" in
      '# branch.oid '*)
        oid="${line#\# branch.oid }"
        ;;
      '# branch.head '*)
        branch="${line#\# branch.head }"
        ;;
      '# branch.upstream '*)
        upstream="${line#\# branch.upstream }"
        ;;
      '# branch.ab '*)
        payload="${line#\# branch.ab +}"
        ahead="${payload%% *}"
        behind="${line##* -}"
        ;;
      '1 '*)
        xy="${line[3,4]}"
        payload="${line#1 }"
        for field_index in {1..7}; do
          payload="${payload#* }"
        done
        file_path="$payload"
        statuses+=("$xy")
        paths+=("$file_path")
        [[ "${xy[1]}" != "." ]] && (( staged++ ))
        [[ "${xy[2]}" != "." ]] && (( unstaged++ ))
        ;;
      '2 '*)
        xy="${line[3,4]}"
        payload="${line#2 }"
        for field_index in {1..8}; do
          payload="${payload#* }"
        done
        file_path="$payload"
        statuses+=("$xy")
        paths+=("$file_path")
        [[ "${xy[1]}" != "." ]] && (( staged++ ))
        [[ "${xy[2]}" != "." ]] && (( unstaged++ ))
        ;;
      'u '*)
        xy="${line[3,4]}"
        payload="${line#u }"
        for field_index in {1..9}; do
          payload="${payload#* }"
        done
        statuses+=("$xy")
        paths+=("$payload")
        (( conflicts++ ))
        ;;
      '? '*)
        statuses+=("??")
        paths+=("${line#\? }")
        (( untracked++ ))
        ;;
    esac
  done <<<"$status_snapshot"

  if [[ "$branch" == "(detached)" && -n "$oid" && "$oid" != "(initial)" ]]; then
    branch="detached at ${oid[1,12]}"
  fi

  _compact_home_path "$root"
  print -r -- "Repository: $REPLY"
  if [[ -n "$upstream" ]]; then
    print -r -- "Branch: $branch -> $upstream (ahead $ahead, behind $behind)"
  else
    print -r -- "Branch: $branch (no upstream)"
  fi

  local stash_list=""
  local -i stash_count=0
  local -a stash_entries
  stash_list="$(command git -C "$root" stash list --format='%gd' 2>/dev/null)"
  if [[ -n "$stash_list" ]]; then
    stash_entries=("${(@f)stash_list}")
    stash_count=${#stash_entries[@]}
  fi
  print -r -- "Stashes: $stash_count"
  print -r -- "Changes: $staged staged, $unstaged unstaged, $untracked untracked, $conflicts conflicted"

  local -i row_index
  if (( ${#statuses} )); then
    print
    printf '%-6s %s\n' "STATUS" "PATH"
    for (( row_index = 1; row_index <= ${#statuses}; row_index++ )); do
      printf '  %-4s %s\n' "${statuses[$row_index]}" "${paths[$row_index]}"
    done
  else
    print -r -- "Working tree clean."
  fi

  if [[ "$show_stat" == true ]]; then
    local unstaged_stat staged_stat
    unstaged_stat="$(command git -C "$root" diff --stat -- 2>/dev/null)"
    staged_stat="$(command git -C "$root" diff --cached --stat -- 2>/dev/null)"
    if [[ -n "$staged_stat" ]]; then
      print
      print -r -- "Staged diff:"
      print -r -- "$staged_stat"
    fi
    if [[ -n "$unstaged_stat" ]]; then
      print
      print -r -- "Unstaged diff:"
      print -r -- "$unstaged_stat"
    fi
  fi
}

_branches_help() {
  cat <<'EOF'
Usage:
  branches [--cached]
  branches -h | --help

Description:
  Audit every local branch in the current Git repository. STATE identifies the
  current branch, branches checked out in another worktree, and other local
  branches. MAIN shows whether each branch is merged into the repository's main
  branch. ORIGIN reports exact ahead/behind counts, missing remote branches, and
  deleted configured upstreams.

  By default, origin is fetched with pruning so the report reflects its current
  state. Fetching and pruning update only remote-tracking metadata; local
  branches, commits, staged changes, and working files are not changed.

Options:
  --cached      Skip fetching and use locally cached origin refs.
  -h, --help    Show this help menu.

Examples:
  branches
  branches --cached
  cd ~/dev/project && branches
EOF
}

# toolbox: git | Audit local branches against origin and the main branch.
# toolbox-args: [--cached]
# toolbox-example: branches
# toolbox-example: branches --cached
branches() {
  emulate -L zsh

  local cached=false
  while (( $# )); do
    case "$1" in
      -h|--help)
        _branches_help
        return 0
        ;;
      --cached)
        cached=true
        ;;
      *)
        print -u2 -r -- "branches: unknown option or argument: $1"
        print -u2 -r -- "Run 'branches --help' for usage."
        return 2
        ;;
    esac
    shift
  done

  command git rev-parse --git-common-dir >/dev/null 2>&1 || {
    print -u2 -r -- "branches: not inside a Git repository"
    return 1
  }

  local origin_state="current" fetch_output fetch_line
  if ! command git remote get-url origin >/dev/null 2>&1; then
    origin_state="no-origin"
    print -r -- "Origin: no remote configured."
  elif [[ "$cached" == true ]]; then
    origin_state="cached"
    print -r -- "Origin refs: local cache; run branches without --cached to refresh."
  else
    print -r -- "Refreshing origin metadata..."
    if ! fetch_output="$(command git fetch --quiet --prune origin 2>&1)"; then
      origin_state="fetch-failed"
      print -u2 -r -- "branches: could not fetch origin:"
      if [[ -n "$fetch_output" ]]; then
        while IFS= read -r fetch_line; do
          print -u2 -r -- "  $fetch_line"
        done <<<"$fetch_output"
      else
        print -u2 -r -- "  unknown error"
      fi
    fi
  fi
  print

  local current_branch current_root field worktree_path worktree_branch
  current_branch="$(command git symbolic-ref --quiet --short HEAD 2>/dev/null)"
  current_root="$(command git rev-parse --show-toplevel 2>/dev/null)"
  [[ -n "$current_root" ]] && current_root="${current_root:A}"
  local -A branch_worktrees
  while IFS= read -r -d $'\0' field; do
    case "$field" in
      "worktree "*)
        worktree_path="${field#worktree }"
        ;;
      "branch refs/heads/"*)
        worktree_branch="${field#branch refs/heads/}"
        branch_worktrees[$worktree_branch]="$worktree_path"
        ;;
    esac
  done < <(command git worktree list --porcelain -z 2>/dev/null)

  local main_ref="" main_name=""
  main_ref="$(command git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)"
  if [[ -z "$main_ref" ]] && command git show-ref --verify --quiet refs/remotes/origin/main; then
    main_ref="refs/remotes/origin/main"
  elif [[ -z "$main_ref" ]] && command git show-ref --verify --quiet refs/heads/main; then
    main_ref="refs/heads/main"
  elif [[ -z "$main_ref" ]] && command git show-ref --verify --quiet refs/heads/master; then
    main_ref="refs/heads/master"
  fi
  [[ -n "$main_ref" ]] && main_name="${main_ref:t}"

  local merged_branch
  local -A merged_branches
  if [[ -n "$main_ref" ]]; then
    while IFS= read -r merged_branch; do
      [[ -n "$merged_branch" ]] && merged_branches[$merged_branch]=1
    done < <(command git for-each-ref --merged="$main_ref" --format='%(refname:short)' refs/heads 2>/dev/null)
  fi

  local branch head upstream_ref age state main_relation origin origin_ref divergence
  local behind ahead display_worktree
  local -i row_index=0 state_width=5 main_width=4 origin_width=6 age_width=3 branch_width=6
  local -a branch_names ages states main_relations origins worktree_paths

  while IFS=$'\x1f' read -r branch head upstream_ref age; do
    [[ -n "$branch" ]] || continue
    (( row_index++ ))

    display_worktree="${branch_worktrees[$branch]:--}"
    if [[ "$branch" == "$current_branch" && -n "$current_root" &&
          "${display_worktree:A}" == "$current_root" ]]; then
      state="current"
    elif [[ "$display_worktree" != "-" ]]; then
      state="worktree"
    else
      state="local"
    fi

    if [[ -z "$main_ref" ]]; then
      main_relation="no-ref"
    elif [[ "$branch" == "$main_name" ]]; then
      main_relation="main"
    elif [[ -n "${merged_branches[$branch]:-}" ]]; then
      main_relation="merged"
    else
      main_relation="unique"
    fi

    if [[ "$origin_state" == "no-origin" ]]; then
      origin="no-origin"
    elif [[ "$origin_state" == "fetch-failed" ]]; then
      origin="unavailable"
    else
      origin_ref=""
      if [[ "$upstream_ref" == refs/remotes/origin/* ]]; then
        if command git show-ref --verify --quiet "$upstream_ref"; then
          origin_ref="$upstream_ref"
        else
          origin="gone"
        fi
      elif command git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
        origin_ref="refs/remotes/origin/$branch"
      else
        origin="no-branch"
      fi

      if [[ -n "$origin_ref" ]]; then
        divergence="$(command git rev-list --left-right --count "$origin_ref...$head" 2>/dev/null)"
        if [[ -z "$divergence" ]]; then
          origin="unknown"
        else
          read -r behind ahead <<<"$divergence"
          if (( ahead && behind )); then
            origin="ahead:$ahead/behind:$behind"
          elif (( ahead )); then
            origin="ahead:$ahead"
          elif (( behind )); then
            origin="behind:$behind"
          else
            origin="synced"
          fi
        fi
      fi
    fi

    branch_names[$row_index]="$branch"
    ages[$row_index]="$age"
    states[$row_index]="$state"
    main_relations[$row_index]="$main_relation"
    origins[$row_index]="$origin"
    if [[ "$display_worktree" != "-" ]]; then
      _compact_home_path "$display_worktree"
      display_worktree="$REPLY"
    fi
    worktree_paths[$row_index]="$display_worktree"
    (( ${#state} > state_width )) && state_width=${#state}
    (( ${#main_relation} > main_width )) && main_width=${#main_relation}
    (( ${#origin} > origin_width )) && origin_width=${#origin}
    (( ${#age} > age_width )) && age_width=${#age}
    (( ${#branch} > branch_width )) && branch_width=${#branch}
  done < <(
    command git for-each-ref --sort=-committerdate --format='%(refname:short)%1f%(objectname)%1f%(upstream)%1f%(committerdate:relative)' refs/heads
  )

  if (( row_index == 0 )); then
    print -r -- "No local branches found."
    [[ "$origin_state" != "fetch-failed" ]]
    return
  fi

  local row_format="%-${state_width}s %-${main_width}s %-${origin_width}s %-${age_width}s %-${branch_width}s %s\n"
  printf "$row_format" "STATE" "MAIN" "ORIGIN" "AGE" "BRANCH" "WORKTREE"
  for (( row_index = 1; row_index <= ${#branch_names}; row_index++ )); do
    printf "$row_format" "${states[$row_index]}" "${main_relations[$row_index]}" "${origins[$row_index]}" "${ages[$row_index]}" "${branch_names[$row_index]}" "${worktree_paths[$row_index]}"
  done

  [[ "$origin_state" != "fetch-failed" ]]
}

_worktrees_help() {
  cat <<'EOF'
Usage:
  worktrees [--cached] [--prune]
  worktrees -h | --help

Description:
  Report the state of every worktree registered to the current Git repository.
  CHANGES uses compact counts: M for changed tracked paths, S for the staged
  subset, U for untracked paths, and C for the conflicted subset. Stashes are
  shared by the repository and reported once. By default, origin is fetched once
  so ORIGIN and MAIN reflect its current state. Fetching updates Git metadata,
  but does not change local branches, staged changes, or working files. --prune
  previews and confirms removal of stale registrations, not branches or commits.

Options:
  --cached      Skip fetching and compare against locally cached origin refs.
  --prune       Preview and confirm pruning missing worktree registrations.
  -h, --help    Show this help menu.

Examples:
  worktrees
  worktrees --cached
  worktrees --prune
  worktrees --cached --prune
  cd ~/dev/project && worktrees
EOF
}

# toolbox: git | Inspect registered Git worktrees.
# toolbox-args: [--cached] [--prune]
# toolbox-example: worktrees
# toolbox-example: worktrees --cached
# toolbox-example: worktrees --cached --prune
worktrees() {
  emulate -L zsh

  local cached=false prune_requested=false
  while (( $# )); do
    case "$1" in
      -h|--help)
        _worktrees_help
        return 0
        ;;
      --cached)
        cached=true
        ;;
      --prune)
        prune_requested=true
        ;;
      *)
        print -u2 -r -- "worktrees: unknown option or argument: $1"
        print -u2 -r -- "Run 'worktrees --help' for usage."
        return 2
        ;;
    esac
    shift
  done
  command git rev-parse --git-common-dir >/dev/null 2>&1 || {
    print -u2 -r -- "worktrees: not inside a Git repository"
    return 1
  }

  if [[ "$prune_requested" == true ]]; then
    local prune_preview confirmation
    if ! prune_preview="$(command git worktree prune --dry-run --verbose --expire now 2>&1)"; then
      print -u2 -r -- "$prune_preview"
      return 1
    fi
    if [[ -z "$prune_preview" ]]; then
      print -r -- "No prunable worktree registrations."
      print
    else
      print -r -- "Prunable worktree registrations:"
      print -r -- "$prune_preview"
      print
      read -r "confirmation?Prune these stale registrations? [y/N] " || confirmation=""
      if [[ "${confirmation:l}" != "y" && "${confirmation:l}" != "yes" ]]; then
        print
        print -r -- "Aborted."
        return 1
      fi
      print
      command git worktree prune --verbose --expire now || return $?
      print
    fi
  fi

  local origin_state="current" fetch_output fetch_summary
  if ! command git remote get-url origin >/dev/null 2>&1; then
    origin_state="no-origin"
    print -r -- "Origin: no remote configured."
  elif [[ "$cached" == true ]]; then
    origin_state="cached"
    print -r -- "Origin refs: local cache; run worktrees without --cached to refresh."
  else
    print -r -- "Refreshing origin metadata..."
    if ! fetch_output="$(command git fetch --quiet origin 2>&1)"; then
      origin_state="fetch-failed"
      fetch_summary="${fetch_output%%$'\n'*}"
      [[ -n "$fetch_summary" ]] || fetch_summary="unknown error"
      print -u2 -r -- "worktrees: could not fetch origin: $fetch_summary"
    fi
  fi
  print

  local field worktree_path head branch state changes origin main_relation
  local divergence origin_ref stash_count
  local status_entry x y xy
  local modified staged untracked conflicts behind ahead skip_source
  local -i worktree_index=0
  local -i state_width=5 changes_width=7 origin_width=6 main_width=4 branch_width=6
  local -a paths heads branches prunable_flags locked_flags
  local -a states change_sets origins main_relations display_branches display_paths

  while IFS= read -r -d $'\0' field; do
    case "$field" in
      "worktree "*)
        (( worktree_index++ ))
        paths[$worktree_index]="${field#worktree }"
        heads[$worktree_index]=""
        branches[$worktree_index]=""
        prunable_flags[$worktree_index]=false
        locked_flags[$worktree_index]=false
        ;;
      "HEAD "*)
        heads[$worktree_index]="${field#HEAD }"
        ;;
      "branch refs/heads/"*)
        branches[$worktree_index]="${field#branch refs/heads/}"
        ;;
      locked*)
        locked_flags[$worktree_index]=true
        ;;
      prunable*)
        prunable_flags[$worktree_index]=true
        ;;
    esac
  done < <(command git worktree list --porcelain -z)

  stash_count="$(command git stash list --format='%gd' | command awk 'END { print NR + 0 }')"
  print -r -- "Stashes: $stash_count (shared by repository)"
  print

  for (( worktree_index = 1; worktree_index <= ${#paths}; worktree_index++ )); do
    worktree_path="${paths[$worktree_index]}"
    head="${heads[$worktree_index]}"
    branch="${branches[$worktree_index]}"
    [[ -n "$branch" ]] || branch="@${head[1,12]}"
    modified=0
    staged=0
    untracked=0
    conflicts=0
    skip_source=false

    if [[ "${prunable_flags[$worktree_index]}" == true ]]; then
      state="prunable"
      changes="-"
    elif [[ ! -d "$worktree_path" ]]; then
      state="missing"
      changes="-"
    elif ! command git -C "$worktree_path" status --porcelain=v1 -z --untracked-files=all >/dev/null 2>&1; then
      state="unavailable"
      changes="-"
    else
      while IFS= read -r -d $'\0' status_entry; do
        if [[ "$skip_source" == true ]]; then
          skip_source=false
          continue
        fi
        xy="${status_entry[1,2]}"
        x="${xy[1]}"
        y="${xy[2]}"
        if [[ "$xy" == "??" ]]; then
          (( untracked++ ))
          continue
        fi

        (( modified++ ))
        [[ "$x" != " " ]] && (( staged++ ))
        [[ "$xy" == (DD|AU|UD|UA|DU|AA|UU) ]] && (( conflicts++ ))
        [[ "$x" == (R|C) || "$y" == (R|C) ]] && skip_source=true
      done < <(command git -C "$worktree_path" status --porcelain=v1 -z --untracked-files=all 2>/dev/null)

      if (( conflicts )); then
        state="conflict"
      elif (( modified || untracked )); then
        state="dirty"
      else
        state="clean"
      fi
      changes=""
      (( modified )) && changes+="M$modified "
      (( staged )) && changes+="S$staged "
      (( untracked )) && changes+="U$untracked "
      (( conflicts )) && changes+="C$conflicts "
      changes="${changes% }"
      [[ -n "$changes" ]] || changes="-"
    fi
    [[ "${locked_flags[$worktree_index]}" == true ]] && state+="+locked"

    if [[ "$branch" == @* ]]; then
      origin="detached"
    elif [[ "$origin_state" == "no-origin" ]]; then
      origin="no-origin"
    elif [[ "$origin_state" == "fetch-failed" ]]; then
      origin="unavailable"
    else
      origin_ref="refs/remotes/origin/$branch"
      if ! command git show-ref --verify --quiet "$origin_ref"; then
        origin="no-branch"
      else
        divergence="$(command git rev-list --left-right --count "$origin_ref...$head" 2>/dev/null)"
        if [[ -z "$divergence" ]]; then
          origin="unknown"
        else
          read -r behind ahead <<<"$divergence"
          if (( ahead && behind )); then
            origin="ahead:$ahead/behind:$behind"
          elif (( ahead )); then
            origin="ahead:$ahead"
          elif (( behind )); then
            origin="behind:$behind"
          else
            origin="synced"
          fi
        fi
      fi
    fi

    if [[ "$origin_state" == "fetch-failed" ]]; then
      main_relation="unavailable"
    elif ! command git show-ref --verify --quiet refs/remotes/origin/main; then
      main_relation="no-ref"
    elif command git merge-base --is-ancestor "$head" origin/main; then
      main_relation="merged"
    else
      main_relation="unique"
    fi

    states[$worktree_index]="$state"
    change_sets[$worktree_index]="$changes"
    origins[$worktree_index]="$origin"
    main_relations[$worktree_index]="$main_relation"
    display_branches[$worktree_index]="$branch"
    _compact_home_path "${paths[$worktree_index]}"
    display_paths[$worktree_index]="$REPLY"
    (( ${#state} > state_width )) && state_width=${#state}
    (( ${#changes} > changes_width )) && changes_width=${#changes}
    (( ${#origin} > origin_width )) && origin_width=${#origin}
    (( ${#main_relation} > main_width )) && main_width=${#main_relation}
    (( ${#branch} > branch_width )) && branch_width=${#branch}
  done

  local row_format="%-${state_width}s %-${changes_width}s %-${origin_width}s %-${main_width}s %-${branch_width}s %s\n"
  printf "$row_format" "STATE" "CHANGES" "ORIGIN" "MAIN" "BRANCH" "PATH"
  for (( worktree_index = 1; worktree_index <= ${#paths}; worktree_index++ )); do
    printf "$row_format" \
      "${states[$worktree_index]}" "${change_sets[$worktree_index]}" \
      "${origins[$worktree_index]}" "${main_relations[$worktree_index]}" \
      "${display_branches[$worktree_index]}" "${display_paths[$worktree_index]}"
  done

  [[ "$origin_state" != "fetch-failed" ]]
}

_repos_help() {
  cat <<'EOF'
Usage:
  repos [--cached] [ROOT]
  repos -h | --help

Description:
  Report the state of Git checkouts at ROOT or within two directory levels and
  every worktree registered to those repositories, including worktrees outside
  ROOT. ROOT defaults to $HOME/dev. CHANGES uses compact counts: M for changed
  tracked paths, S for the staged subset, U for untracked paths, and C for the
  conflicted subset. By default, each repository fetches origin once so ORIGIN
  can report an exact current ahead/behind count. Fetching updates Git metadata,
  but does not change local branches, staged changes, or working files.

Options:
  --cached     Skip fetching and compare against locally cached origin refs.
  -h, --help    Show this help menu.

Examples:
  repos
  repos --cached
  repos ~/dev
  repos /tmp/projects

Environment:
  HOME          Supplies the default repository root, $HOME/dev.
EOF
}

# toolbox: git | Inspect repositories and their linked worktrees.
# toolbox-args: [--cached] [ROOT]
# toolbox-example: repos
# toolbox-example: repos --cached
# toolbox-example: repos --cached ~/dev
repos() {
  emulate -L zsh

  local cached=false root=""
  while (( $# )); do
    case "$1" in
      -h|--help)
        _repos_help
        return 0
        ;;
      --cached)
        cached=true
        ;;
      -*)
        print -u2 -r -- "repos: unknown option: $1"
        print -u2 -r -- "Run 'repos --help' for usage."
        return 2
        ;;
      *)
        if [[ -n "$root" ]]; then
          print -u2 -r -- "repos: at most one root path is accepted"
          print -u2 -r -- "Run 'repos --help' for usage."
          return 2
        fi
        root="$1"
        ;;
    esac
    shift
  done

  root="${root:-$HOME/dev}"
  root="${~root:A}"
  [[ -d "$root" ]] || {
    print -u2 -r -- "repos: directory not found: $root"
    return 1
  }

  local dotgit seed common_dir field worktree_path head branch origin_state
  local state changes origin age divergence origin_ref status_entry x y xy
  local fetch_output fetch_summary
  local modified staged untracked conflicts behind ahead skip_source
  local -i seed_index worktree_index row_index=0 repository_index fetch_failure_count=0
  local -i state_width=5 changes_width=7 origin_width=6 age_width=3 branch_width=6
  local -a seeds seed_paths seed_heads seed_branches seed_prunable_flags seed_locked_flags
  local -a repository_roots repository_common_dirs
  local -a paths heads branches prunable_flags locked_flags repo_roots common_dirs
  local -a states change_sets origins ages display_branches display_paths
  local -A seen_common_dirs seen_paths origin_states

  while IFS= read -r -d $'\0' dotgit; do
    seeds+=("${dotgit:h}")
  done < <(
    command find "$root" -mindepth 1 -maxdepth 3 -name .git \
      \( -type d -o -type f \) -print0 2>/dev/null
  )

  for seed in "${seeds[@]}"; do
    common_dir="$(command git -C "$seed" rev-parse --git-common-dir 2>/dev/null)" || continue
    [[ "$common_dir" == /* ]] || common_dir="$seed/$common_dir"
    common_dir="${common_dir:A}"
    [[ -n "${seen_common_dirs[$common_dir]:-}" ]] && continue
    seen_common_dirs[$common_dir]=1
    repository_roots+=("$seed")
    repository_common_dirs+=("$common_dir")

    seed_paths=()
    seed_heads=()
    seed_branches=()
    seed_prunable_flags=()
    seed_locked_flags=()
    worktree_index=0
    while IFS= read -r -d $'\0' field; do
      case "$field" in
        "worktree "*)
          (( worktree_index++ ))
          seed_paths[$worktree_index]="${field#worktree }"
          seed_heads[$worktree_index]=""
          seed_branches[$worktree_index]=""
          seed_prunable_flags[$worktree_index]=false
          seed_locked_flags[$worktree_index]=false
          ;;
        "HEAD "*)
          seed_heads[$worktree_index]="${field#HEAD }"
          ;;
        "branch refs/heads/"*)
          seed_branches[$worktree_index]="${field#branch refs/heads/}"
          ;;
        locked*)
          seed_locked_flags[$worktree_index]=true
          ;;
        prunable*)
          seed_prunable_flags[$worktree_index]=true
          ;;
      esac
    done < <(command git -C "$seed" worktree list --porcelain -z 2>/dev/null)

    for (( seed_index = 1; seed_index <= ${#seed_paths}; seed_index++ )); do
      worktree_path="${seed_paths[$seed_index]}"
      [[ -n "${seen_paths[$worktree_path]:-}" ]] && continue
      seen_paths[$worktree_path]=1
      (( row_index++ ))
      paths[$row_index]="$worktree_path"
      heads[$row_index]="${seed_heads[$seed_index]}"
      branches[$row_index]="${seed_branches[$seed_index]}"
      prunable_flags[$row_index]="${seed_prunable_flags[$seed_index]}"
      locked_flags[$row_index]="${seed_locked_flags[$seed_index]}"
      repo_roots[$row_index]="$seed"
      common_dirs[$row_index]="$common_dir"
    done
  done

  if (( row_index == 0 )); then
    print -r -- "No Git repositories found beneath $root."
    return 0
  fi

  if [[ "$cached" == true ]]; then
    print -r -- "Origin refs: local cache; run repos without --cached to refresh."
  else
    print -r -- "Refreshing origin metadata..."
  fi

  for (( repository_index = 1; repository_index <= ${#repository_roots}; repository_index++ )); do
    seed="${repository_roots[$repository_index]}"
    common_dir="${repository_common_dirs[$repository_index]}"
    if ! command git -C "$seed" remote get-url origin >/dev/null 2>&1; then
      origin_states[$common_dir]="no-origin"
    elif [[ "$cached" == true ]]; then
      origin_states[$common_dir]="cached"
    elif fetch_output="$(command git -C "$seed" fetch --quiet origin 2>&1)"; then
      origin_states[$common_dir]="current"
    else
      origin_states[$common_dir]="fetch-failed"
      (( fetch_failure_count++ ))
      fetch_summary="${fetch_output%%$'\n'*}"
      [[ -n "$fetch_summary" ]] || fetch_summary="unknown error"
      print -u2 -r -- "repos: could not fetch origin for $seed: $fetch_summary"
    fi
  done
  print

  for (( row_index = 1; row_index <= ${#paths}; row_index++ )); do
    worktree_path="${paths[$row_index]}"
    head="${heads[$row_index]}"
    branch="${branches[$row_index]}"
    seed="${repo_roots[$row_index]}"
    common_dir="${common_dirs[$row_index]}"
    [[ -n "$branch" ]] || branch="@${head[1,12]}"
    modified=0
    staged=0
    untracked=0
    conflicts=0
    skip_source=false

    if [[ "${prunable_flags[$row_index]}" == true ]]; then
      state="prunable"
      changes="-"
    elif [[ ! -d "$worktree_path" ]]; then
      state="missing"
      changes="-"
    elif ! command git -C "$worktree_path" status --porcelain=v1 -z --untracked-files=all >/dev/null 2>&1; then
      state="unavailable"
      changes="-"
    else
      while IFS= read -r -d $'\0' status_entry; do
        if [[ "$skip_source" == true ]]; then
          skip_source=false
          continue
        fi
        xy="${status_entry[1,2]}"
        x="${xy[1]}"
        y="${xy[2]}"
        if [[ "$xy" == "??" ]]; then
          (( untracked++ ))
          continue
        fi

        (( modified++ ))
        [[ "$x" != " " ]] && (( staged++ ))
        [[ "$xy" == (DD|AU|UD|UA|DU|AA|UU) ]] && (( conflicts++ ))
        [[ "$x" == (R|C) || "$y" == (R|C) ]] && skip_source=true
      done < <(command git -C "$worktree_path" status --porcelain=v1 -z --untracked-files=all 2>/dev/null)

      if (( conflicts )); then
        state="conflict"
      elif (( modified || untracked )); then
        state="dirty"
      else
        state="clean"
      fi
      changes=""
      (( modified )) && changes+="M$modified "
      (( staged )) && changes+="S$staged "
      (( untracked )) && changes+="U$untracked "
      (( conflicts )) && changes+="C$conflicts "
      changes="${changes% }"
      [[ -n "$changes" ]] || changes="-"
    fi
    [[ "${locked_flags[$row_index]}" == true ]] && state+="+locked"

    origin_state="${origin_states[$common_dir]}"
    if [[ "$branch" == @* ]]; then
      origin="detached"
    elif [[ "$origin_state" == "no-origin" ]]; then
      origin="no-origin"
    elif [[ "$origin_state" == "fetch-failed" ]]; then
      origin="unavailable"
    else
      origin_ref="refs/remotes/origin/$branch"
      if ! command git -C "$seed" show-ref --verify --quiet "$origin_ref"; then
        origin="no-branch"
      else
        divergence="$(command git -C "$seed" rev-list --left-right --count "$origin_ref...$head" 2>/dev/null)"
        if [[ -z "$divergence" ]]; then
          origin="unknown"
        else
          read -r behind ahead <<<"$divergence"
          if (( ahead && behind )); then
            origin="ahead:$ahead/behind:$behind"
          elif (( ahead )); then
            origin="ahead:$ahead"
          elif (( behind )); then
            origin="behind:$behind"
          else
            origin="synced"
          fi
        fi
      fi
    fi

    age="$(command git -C "$seed" show -s --format='%cr' "$head" 2>/dev/null)"
    [[ -n "$age" ]] || age="none"

    states[$row_index]="$state"
    change_sets[$row_index]="$changes"
    origins[$row_index]="$origin"
    ages[$row_index]="$age"
    display_branches[$row_index]="$branch"
    _compact_home_path "${paths[$row_index]}"
    display_paths[$row_index]="$REPLY"
    (( ${#state} > state_width )) && state_width=${#state}
    (( ${#changes} > changes_width )) && changes_width=${#changes}
    (( ${#origin} > origin_width )) && origin_width=${#origin}
    (( ${#age} > age_width )) && age_width=${#age}
    (( ${#branch} > branch_width )) && branch_width=${#branch}
  done

  local row_format="%-${state_width}s %-${changes_width}s %-${origin_width}s %-${age_width}s %-${branch_width}s %s\n"
  printf "$row_format" "STATE" "CHANGES" "ORIGIN" "AGE" "BRANCH" "PATH"
  for (( row_index = 1; row_index <= ${#paths}; row_index++ )); do
    printf "$row_format" \
      "${states[$row_index]}" "${change_sets[$row_index]}" \
      "${origins[$row_index]}" "${ages[$row_index]}" \
      "${display_branches[$row_index]}" "${display_paths[$row_index]}"
  done

  (( fetch_failure_count == 0 ))
}

_stashes_help() {
  cat <<'EOF'
Usage:
  stashes
  stashes -h | --help

Description:
  List Git stashes across repositories beneath $HOME/dev. Linked worktrees are
  deduplicated because their stashes are shared with the primary repository.
  Results are sorted newest first and no repository state is changed.

Options:
  -h, --help    Show this help menu.

Examples:
  stashes

Environment:
  HOME          Supplies the repository root, $HOME/dev.
EOF
}

# toolbox: git | Find stashes across Git repositories.
# toolbox-example: stashes
stashes() {
  emulate -L zsh
  setopt pipefail

  case "${1:-}" in
    -h|--help)
      _stashes_help
      return 0
      ;;
  esac
  (( $# == 0 )) || {
    print -u2 -r -- "stashes: this command does not accept arguments"
    print -u2 -r -- "Run 'stashes --help' for usage."
    return 2
  }

  local root="${HOME}/dev"
  [[ -d "$root" ]] || {
    _compact_home_path "$root"
    print -u2 -r -- "stashes: directory not found: $REPLY"
    return 1
  }

  local dotgit seed common_dir repository_root repository_display
  local timestamp age stash_ref subject details branch message
  local -a records
  local -A seen_common_dirs

  while IFS= read -r -d $'\0' dotgit; do
    seed="${dotgit:h}"
    common_dir="$(command git -C "$seed" rev-parse --git-common-dir 2>/dev/null)" || continue
    [[ "$common_dir" == /* ]] || common_dir="$seed/$common_dir"
    common_dir="${common_dir:A}"
    [[ -n "${seen_common_dirs[$common_dir]:-}" ]] && continue
    seen_common_dirs[$common_dir]=1

    repository_root="$(command git -C "$seed" worktree list --porcelain 2>/dev/null |
      command sed -n 's/^worktree //p' |
      command sed -n '1p')"
    [[ -n "$repository_root" ]] || repository_root="$seed"
    _compact_home_path "$repository_root"
    repository_display="$REPLY"

    while IFS=$'\x1f' read -r timestamp age stash_ref subject; do
      [[ -n "$stash_ref" ]] || continue
      branch="-"
      message="$subject"
      case "$subject" in
        "WIP on "*|"On "*|"index on "*)
          details="${subject#WIP on }"
          details="${details#On }"
          details="${details#index on }"
          if [[ "$details" == *": "* ]]; then
            branch="${details%%: *}"
            message="${details#*: }"
          fi
          ;;
      esac
      [[ -n "$message" ]] || message="-"
      records+=("$timestamp"$'\x1f'"$age"$'\x1f'"$repository_display"$'\x1f'"$stash_ref"$'\x1f'"$branch"$'\x1f'"$message")
    done < <(command git -C "$seed" stash list --format='%ct%x1f%cr%x1f%gd%x1f%gs' 2>/dev/null)
  done < <(
    command find "$root" -mindepth 1 -maxdepth 3 -name .git \
      \( -type d -o -type f \) -print0 2>/dev/null
  )

  if (( ${#records} == 0 )); then
    print -r -- "No stashes found beneath ~/dev."
    return 0
  fi

  local sorted_records
  sorted_records="$(printf '%s\n' "${records[@]}" |
    LC_ALL=C command sort -t $'\x1f' -k1,1nr -k3,3 -k4,4)" || {
    print -u2 -r -- "stashes: could not sort stash records"
    return 1
  }

  local -i row_index=0 age_width=3 repository_width=10 stash_width=5 branch_width=6
  local -a ages repositories stash_refs branches messages
  while IFS=$'\x1f' read -r timestamp age repository_display stash_ref branch message; do
    [[ -n "$stash_ref" ]] || continue
    (( row_index++ ))
    ages[$row_index]="$age"
    repositories[$row_index]="$repository_display"
    stash_refs[$row_index]="$stash_ref"
    branches[$row_index]="$branch"
    messages[$row_index]="$message"
    (( ${#age} > age_width )) && age_width=${#age}
    (( ${#repository_display} > repository_width )) && repository_width=${#repository_display}
    (( ${#stash_ref} > stash_width )) && stash_width=${#stash_ref}
    (( ${#branch} > branch_width )) && branch_width=${#branch}
  done <<<"$sorted_records"

  local row_format="%-${age_width}s %-${repository_width}s %-${stash_width}s %-${branch_width}s %s\n"
  printf "$row_format" "AGE" "REPOSITORY" "STASH" "BRANCH" "MESSAGE"
  for (( row_index = 1; row_index <= ${#ages}; row_index++ )); do
    printf "$row_format" "${ages[$row_index]}" "${repositories[$row_index]}" \
      "${stash_refs[$row_index]}" "${branches[$row_index]}" "${messages[$row_index]}"
  done
}
