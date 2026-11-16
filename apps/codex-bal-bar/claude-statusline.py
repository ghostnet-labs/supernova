#!/usr/bin/env python3
"""Restore the Claude Code status line that older Codex Balance installs wrapped.

Codex Balance used to wrap Claude Code's status line to capture plan limits;
it now reads them from Claude's usage endpoint, so install and uninstall put
back whatever status line the wrapper replaced.
"""

import json
import os
from pathlib import Path
import sys
import tempfile


def atomic_json(path: Path, value: object, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def settings_paths() -> tuple[Path, Path]:
    settings = Path(os.environ.get("CODEX_BAL_BAR_CLAUDE_SETTINGS", "~/.claude/settings.json")).expanduser()
    return settings, settings.with_name(".codex-bal-bar-statusline.json")


def restore() -> None:
    settings_path, backup_path = settings_paths()
    if not backup_path.exists():
        return
    saved = json.loads(backup_path.read_text(encoding="utf-8"))
    settings = json.loads(settings_path.read_text(encoding="utf-8")) if settings_path.exists() else {}
    current = settings.get("statusLine") if isinstance(settings, dict) else None
    if not isinstance(current, dict) or current.get("command") != saved.get("wrapper"):
        print("• Claude statusLine changed since Codex Balance wrapped it; leaving it untouched")
        return
    original = saved.get("original")
    if original is None:
        settings.pop("statusLine", None)
    else:
        settings["statusLine"] = original
    mode = settings_path.stat().st_mode & 0o777 if settings_path.exists() else 0o600
    atomic_json(settings_path, settings, mode)
    backup_path.unlink()
    print("✓ Restored the previous Claude Code status line")


def main() -> int:
    if sys.argv[1:]:
        print(f"Usage: {Path(sys.argv[0]).name}", file=sys.stderr)
        return 2
    try:
        restore()
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
