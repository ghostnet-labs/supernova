#!/usr/bin/env python3
"""Keep a session's working state across Claude Code compaction.

Compaction summarises the conversation and drops detail. PreCompact saves the
last task list and any swarm ledger state; SessionStart prints that back and
points to the project's PROGRESS.md. Where there's nothing to save it does nothing, and
it never fails the hook.
"""

import argparse
import json
import subprocess
import sys
from collections import Counter
from pathlib import Path

SNAPSHOTS = Path.home() / ".claude" / "compact-snapshots"
TASK_TOOLS = ("update_plan", "TodoWrite")


def project_root(cwd):
    """Find the folder with notes: ignored files stay in the main checkout, not a worktree."""
    candidates = [Path(cwd)]
    git = subprocess.run(
        ["git", "-C", cwd, "rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir"],
        capture_output=True,
        text=True,
        timeout=5,
    )
    if git.returncode == 0:
        top, common = git.stdout.split("\n")[:2]
        candidates += [Path(top), Path(common).parent]
    for folder in candidates:
        if (folder / "PROGRESS.md").is_file() or (folder / ".swarm").is_dir():
            return folder
    return None


def last_task_list(transcript):
    """Return the session's last full task list as markdown lines."""
    if not transcript or not Path(transcript).is_file():
        return []
    lines = Path(transcript).read_text(errors="replace").splitlines()
    for line in reversed(lines):
        if not any(tool in line for tool in TASK_TOOLS):
            continue
        content = (json.loads(line).get("message") or {}).get("content")
        for part in reversed(content if isinstance(content, list) else []):
            if not isinstance(part, dict) or part.get("type") != "tool_use":
                continue
            task_input = part.get("input") or {}
            items = task_input.get("items") or task_input.get("todos")
            if items and part.get("name", "").endswith(TASK_TOOLS):
                return [f"- [{item.get('status', '?')}] {item.get('content', '')}" for item in items]
    return []


def ledger_state(root):
    """Return the swarm ledger's issue counts and lock as markdown lines."""
    ledger = root / ".swarm" / "ledger.json"
    if not ledger.is_file():
        return []
    try:
        issues = json.loads(ledger.read_text()).get("issues", [])
    except ValueError as error:
        return [f"Ledger unreadable: {error}"]
    counts = Counter(issue.get("status") for issue in issues)
    lines = [f"{len(issues)} issues: " + ", ".join(f"{name} {count}" for name, count in counts.most_common())]
    if (root / ".swarm" / "lock").exists():
        lines.append(f"Lock held: {root / '.swarm' / 'lock'}")
    return lines


def snapshot_path(event):
    return SNAPSHOTS / f"{Path(event['session_id']).name}.md"


def snapshot(event):
    root = project_root(event["cwd"])
    sections = [
        ("Last task list", last_task_list(event.get("transcript_path"))),
        ("Swarm ledger", ledger_state(root) if root else []),
    ]
    text = "\n\n".join(f"## {title}\n\n" + "\n".join(lines) for title, lines in sections if lines)
    if text:
        SNAPSHOTS.mkdir(parents=True, exist_ok=True)
        snapshot_path(event).write_text(text + "\n")


def restore(event):
    root = project_root(event["cwd"])
    saved = snapshot_path(event)
    parts = []
    if saved.is_file():
        parts.append(saved.read_text())
        saved.unlink()
    # By path, as a long file would push the snapshot past the hook's output cap.
    if root and (root / "PROGRESS.md").is_file():
        parts.append(f"Read {root / 'PROGRESS.md'} before going on.")
    if parts:
        print("Context was just compacted. This was saved on disk; trust it over the summary.\n")
        print("\n".join(parts))


def main():
    parser = argparse.ArgumentParser(description="Keep a session's working state across compaction.")
    parser.add_argument("action", choices=["snapshot", "restore"])
    action = {"snapshot": snapshot, "restore": restore}[parser.parse_args().action]
    try:
        action(json.load(sys.stdin))
    except Exception as error:  # A failed hook must not get in a session's way.
        print(f"compact-hook: {error}", file=sys.stderr)


if __name__ == "__main__":
    main()
