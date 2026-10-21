#!/usr/bin/env python3
# setup-test: Claude Code settings
"""Checks that the shared Claude Code settings enable only the reviewed official plugins."""

from __future__ import annotations

import json
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[2]
SETTINGS = json.loads((ROOT / ".claude" / "settings.json").read_text())

# Each plugin's code was read before it was added here. The LSP plugins only
# start a language server already on PATH; claude-md-management adds a skill
# and a command, and no hooks.
REVIEWED_PLUGINS = {
    "claude-md-management@claude-plugins-official",
    "pyright-lsp@claude-plugins-official",
    "swift-lsp@claude-plugins-official",
}


class ClaudeSettingsTest(unittest.TestCase):
    def test_only_plugins_are_configured(self):
        # Hooks, permissions, env, and extra marketplaces would run or allow
        # code in every agent session, so they need their own review.
        self.assertEqual(set(SETTINGS), {"$schema", "enabledPlugins"})

    def test_enabled_plugins_are_the_reviewed_ones(self):
        self.assertEqual(set(SETTINGS["enabledPlugins"]), REVIEWED_PLUGINS)
        self.assertTrue(all(value is True for value in SETTINGS["enabledPlugins"].values()))


if __name__ == "__main__":
    unittest.main()
