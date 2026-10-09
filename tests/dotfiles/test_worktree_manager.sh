#!/usr/bin/env bash
# setup-test: Worktree Manager
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$root/tests/lib/assert.sh"
cmd="$root/dotfiles/.bin/worktree-manager"
src="$root/apps/lib/worktrees/Worktrees.swift"
[[ "$("$cmd" --help)" == *"Usage:"* ]]
[[ -f "$root/apps/worktree-manager/README.md" ]]
grep -q 'safeToRemove' "$src"
grep -q 'AGENT LIVE' "$src"
grep -q 'worktree.*remove' "$src"
grep -q 'worktree.*prune' "$src"
grep -q -- '--jump' "$src"
grep -q 'exec claude' "$src"
grep -q -- '"pull", "--ff-only"' "$src"
grep -q -- '"rebase", "--abort"' "$src"
grep -q 'struct DiffSheet' "$src"
grep -q -- '--git-common-dir' "$src"
grep -q 'struct RepositoryGroup' "$src"
grep -q 'NSInitialToolTipDelay' "$root/apps/worktree-manager/WorktreeManager.swift"
grep -q 'struct DiffDocument' "$src"
grep -q 'struct DiffTextView: NSViewRepresentable' "$src"
grep -q -- '"--no-index"' "$src"
grep -q 'Clear search' "$src"
grep -q 'struct BranchRecord' "$src"
grep -q '@AppStorage("collapsedRepositories")' "$src"
grep -q 'FocusReleaser.install()' "$root/apps/worktree-manager/WorktreeManager.swift"
grep -q 'List(selection: $model.selection)' "$src"
grep -q 'struct ActionBar: View' "$src"
grep -q 'struct SelectionActions' "$src"
grep -q 'ClickToDeselect.install()' "$root/apps/worktree-manager/WorktreeManager.swift"
grep -q 'struct RefreshControl' "$src"
grep -q 'struct SoftSelection' "$src"
grep -q '@AppStorage("pinnedRepositories")' "$src"
grep -q 'static func webBase' "$src"
grep -q 'liveAgentTimeout' "$src"
grep -q 'var canDelete: Bool { !isDefault' "$src"
grep -q -- '--window-save-state=never' "$src"
grep -q -- '--quit-after-last-window-closed=true' "$src"
grep -q -- '--initial-command=' "$src"
# --command= would rerun the agent in every later window and tab of that Ghostty instance.
if grep -q -- '"--command=' "$src"; then echo 'FAIL: Ghostty must use --initial-command=, not --command=' >&2; exit 1; fi
# Actions live in the shared action bar; the only contextMenu is the empty one that gives double-click to open.
if grep -qE '\.contextMenu \{|"-e"' "$src"; then echo 'FAIL: actions belong in the action bar and Ghostty must not use -e' >&2; exit 1; fi
if [[ "$(uname -s)" == Darwin ]]; then
  plutil -lint "$root/apps/worktree-manager/Info.plist" >/dev/null
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/worktree-test.XXXXXX")"
  trap 'rm -rf -- "$tmp"' EXIT
  # Compile the production declarations with a fixture runner instead of the GUI entry point.
  swiftc "$root/apps/lib/TextLine.swift" -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
    -module-cache-path "${CLANG_MODULE_CACHE_PATH:-$tmp/module-cache}" \
    "$root/apps/lib/worktrees/"*.swift "$root/apps/lib/octicons/Octicons.swift" "$root/apps/lib/BranchRef.swift" "$root/apps/lib/GitStatus.swift" "$root/apps/lib/SessionPresentation.swift" "$root/tests/dotfiles/worktree_manager_cases.swift" -o "$tmp/check"
  printf '%s\n' 'import os
from pathlib import Path
import subprocess
import sys
env = os.environ.copy()
env["WORKTREE_MANAGER_ROOT"] = str(Path(sys.argv[2]).resolve())
env["WORKTREE_MANAGER_SESSIONS_BIN"] = env["WORKTREE_MANAGER_ROOT"] + "/sessions"
env["WORKTREE_MANAGER_CLAUDE_SESSIONS_BIN"] = env["WORKTREE_MANAGER_ROOT"] + "/claude-sessions"
subprocess.run([sys.argv[1]], env=env, check=True, timeout=120)' | python3 - "$tmp/check" "$tmp/root"
fi
printf 'PASS: Worktree Manager\n'
