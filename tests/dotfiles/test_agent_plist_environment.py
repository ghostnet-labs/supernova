#!/usr/bin/env python3
# setup-test: Agent launch agent environment
"""Checks that reinstalling Agent Workspace keeps custom settings but drops another checkout's paths."""

from __future__ import annotations

import os
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[2]
SUPPORT = ROOT / "apps" / "agent-workspace" / "install_support.py"


def write_plist(source: str, previous: dict[str, str] | None, env: dict[str, str] | None = None) -> dict[str, str]:
    with tempfile.TemporaryDirectory() as tmp:
        destination = Path(tmp) / "agent.plist"
        if previous is not None:
            destination.write_bytes(plistlib.dumps({"EnvironmentVariables": previous}))
        environment = {key: value for key, value in os.environ.items() if not key.startswith("AGENT_")}
        environment.update(env or {})
        subprocess.run(
            ["python3", str(SUPPORT), "plist", str(ROOT / "apps" / source), f"{tmp}/App.app", str(destination)],
            check=True,
            env=environment,
        )
        return plistlib.loads(destination.read_bytes())["EnvironmentVariables"]


class AgentPlistEnvironmentTest(unittest.TestCase):
    def test_defaults_point_at_this_checkout(self):
        environment = write_plist("agent-workspace", None)
        self.assertEqual(environment["AGENT_WORKSPACE_SESSIONS_BIN"], str(ROOT / "dotfiles/.bin/codex-sessions"))
        self.assertEqual(environment["AGENT_WORKSPACE_CLAUDE_SESSIONS_BIN"], str(ROOT / "dotfiles/.bin/claude-sessions"))

    def test_another_checkouts_paths_are_replaced(self):
        old = "/Users/example/dev/old-clone/dotfiles/.bin"
        environment = write_plist("agent-workspace", {
            "AGENT_WORKSPACE_SESSIONS_BIN": f"{old}/codex-sessions",
            "AGENT_WORKSPACE_CLAUDE_SESSIONS_BIN": f"{old}/claude-sessions",
            "AGENT_WORKSPACE_INTERVAL": "9",
        })
        self.assertEqual(environment["AGENT_WORKSPACE_SESSIONS_BIN"], str(ROOT / "dotfiles/.bin/codex-sessions"))
        self.assertEqual(environment["AGENT_WORKSPACE_CLAUDE_SESSIONS_BIN"], str(ROOT / "dotfiles/.bin/claude-sessions"))
        self.assertEqual(environment["AGENT_WORKSPACE_INTERVAL"], "9", "other custom settings are kept")

    def test_custom_paths_outside_a_checkout_are_kept(self):
        environment = write_plist("agent-workspace", {"AGENT_WORKSPACE_SESSIONS_BIN": "/opt/tools/codex-sessions"})
        self.assertEqual(environment["AGENT_WORKSPACE_SESSIONS_BIN"], "/opt/tools/codex-sessions")

    def test_the_environment_wins_over_everything(self):
        environment = write_plist(
            "agent-workspace",
            {"AGENT_WORKSPACE_SESSIONS_BIN": "/opt/tools/codex-sessions"},
            {"AGENT_WORKSPACE_SESSIONS_BIN": "/elsewhere/dotfiles/.bin/codex-sessions"},
        )
        self.assertEqual(environment["AGENT_WORKSPACE_SESSIONS_BIN"], "/elsewhere/dotfiles/.bin/codex-sessions")


if __name__ == "__main__":
    unittest.main()
