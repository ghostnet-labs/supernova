#!/usr/bin/env python3
"""Install a transparent Claude Code status line wrapper for Codex Balance."""

import json
import os
from pathlib import Path
import shlex
import subprocess
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


def install(wrapper_path: str | None = None) -> None:
    settings_path, backup_path = settings_paths()
    settings = json.loads(settings_path.read_text(encoding="utf-8")) if settings_path.exists() else {}
    if not isinstance(settings, dict):
        raise ValueError(f"Claude settings must contain a JSON object: {settings_path}")

    wrapper = str(Path(wrapper_path or __file__).resolve())
    command = f"{shlex.quote(sys.executable)} {shlex.quote(wrapper)}"
    current = settings.get("statusLine")
    original = None
    if backup_path.exists():
        saved = json.loads(backup_path.read_text(encoding="utf-8"))
        if isinstance(saved, dict):
            current_command = current.get("command") if isinstance(current, dict) else None
            if current_command == saved.get("wrapper"):
                original = saved.get("original")
            elif current is not None:
                raise ValueError("Claude statusLine changed after integration; leaving it unchanged")
    if original is None and current is not None:
        if not isinstance(current, dict) or current.get("type") != "command" or not isinstance(current.get("command"), str):
            raise ValueError("Existing Claude statusLine is not a supported command; leaving it unchanged")
        if current.get("command") != command:
            original = current

    backup = {"wrapper": command, "original": original}
    atomic_json(backup_path, backup)
    active = dict(original or {"type": "command"})
    active["type"] = "command"
    active["command"] = command
    settings["statusLine"] = active
    mode = settings_path.stat().st_mode & 0o777 if settings_path.exists() else 0o600
    atomic_json(settings_path, settings, mode)
    print("✓ Claude Code status line now shares limits with Codex Balance")


def uninstall() -> None:
    settings_path, backup_path = settings_paths()
    if not backup_path.exists():
        return
    saved = json.loads(backup_path.read_text(encoding="utf-8"))
    settings = json.loads(settings_path.read_text(encoding="utf-8")) if settings_path.exists() else {}
    current = settings.get("statusLine") if isinstance(settings, dict) else None
    if not isinstance(current, dict) or current.get("command") != saved.get("wrapper"):
        print("• Claude statusLine changed since Codex Balance installed; leaving it untouched")
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


def run_statusline() -> None:
    _, backup_path = settings_paths()
    data = sys.stdin.buffer.read()
    try:
        saved = json.loads(backup_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        saved = {}
    original = saved.get("original") if isinstance(saved, dict) else None
    if isinstance(original, dict) and isinstance(original.get("command"), str):
        result = subprocess.run(original["command"], shell=True, input=data, stdout=subprocess.PIPE, check=False)
        sys.stdout.buffer.write(result.stdout)
        sys.stdout.buffer.flush()

    capture = Path(__file__).with_name("claude-limits-capture")
    try:
        process = subprocess.Popen(
            [str(capture)], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, start_new_session=True,
        )
        assert process.stdin is not None
        process.stdin.write(data)
        process.stdin.close()
    except OSError:
        pass


def main() -> int:
    try:
        if sys.argv[1:] == ["--install"]:
            install()
        elif len(sys.argv) == 3 and sys.argv[1] == "--install":
            install(sys.argv[2])
        elif sys.argv[1:] == ["--uninstall"]:
            uninstall()
        elif not sys.argv[1:]:
            run_statusline()
        else:
            print(f"Usage: {Path(sys.argv[0]).name} [--install [wrapper-path] | --uninstall]", file=sys.stderr)
            return 2
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
