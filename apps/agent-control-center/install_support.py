"""Installer metadata helpers; called by the sole public app-management command."""

import hashlib
import json
import os
from pathlib import Path
import plistlib
import sys


def source_hashes(source):
    root = source.parent.parent
    inputs = (
        list(source.glob("*.swift"))
        + list((source.parent / "lib/agents").glob("*.swift"))
        + [source / "Info.plist", source.parent / "agent-control-center/session_stream.py"]
    )
    if source.name == "agent-workspace":
        inputs += list((source.parent / "lib/worktrees").glob("*.swift"))
        inputs.append(source / "sign_app.py")
    inputs += [Path(__file__).resolve(), root / "dotfiles/.bin" / source.name]
    inputs += [
        source.parent / "lib" / name
        for name in (
            "BranchRef.swift",
            "GhosttyLaunch.swift",
            "GitStatus.swift",
            "SessionPresentation.swift",
            "TextLine.swift",
            "octicons/Octicons.swift",
        )
    ]
    inputs += [
        root / "dotfiles/.bin" / name for name in ("codex-sessions", "claude-sessions")
    ]
    return {
        str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(inputs)
    }


def main():
    command, source, bundle, *remaining = sys.argv[1:]
    source, bundle = Path(source).resolve(), Path(bundle)
    manifest = bundle / "Contents/Resources/SourceHashes.json"
    if command == "manifest":
        manifest.write_text(json.dumps(source_hashes(source), indent=2) + "\n")
    elif command == "verify":
        if json.loads(manifest.read_text()) != source_hashes(source):
            raise SystemExit("Installed sources do not match the build manifest")
    elif command == "plist":
        workspace = source.name == "agent-workspace"
        prefix = "AGENT_WORKSPACE" if workspace else "AGENT_CONTROL"
        destination = Path(remaining[0])
        previous = (
            plistlib.loads(destination.read_bytes()).get("EnvironmentVariables", {})
            if destination.exists()
            else {}
        )
        defaults = {
            "PATH": f"{Path.home()}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            prefix + "_INTERVAL": "5",
            prefix + "_SESSIONS_BIN": str(
                source.parent.parent / "dotfiles/.bin/codex-sessions"
            ),
            prefix + "_CLAUDE_SESSIONS_BIN": str(
                source.parent.parent / "dotfiles/.bin/claude-sessions"
            ),
        }
        environment = {
            key: os.environ.get(key) or previous.get(key) or default
            for key, default in defaults.items()
        }
        for key in ("CODEX_HOME", "CLAUDE_CONFIG_DIR", "SETUP_DIR", "AGENT_WORKSPACE_ROOT", "TW_PROJECT_ROOT"):
            value = os.environ.get(key) or previous.get(key)
            if value:
                environment[key] = value
        data = {
            "Label": "local.agent-workspace" if workspace else "local.agent-control-center",
            "ProgramArguments": [str(bundle / "Contents/MacOS" / ("AgentWorkspace" if workspace else "AgentControlCenter"))],
            "EnvironmentVariables": environment,
            "RunAtLoad": True,
            "KeepAlive": {"SuccessfulExit": False},
            "ProcessType": "Interactive",
        }
        destination.write_bytes(plistlib.dumps(data))
    else:
        raise SystemExit("Unknown installer action")


if __name__ == "__main__":
    main()
