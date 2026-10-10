#!/usr/bin/env python3
# setup-test: Linter versions
"""Checks that every CI job lints with the same pinned Ruff and ShellCheck versions."""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[2]
CI = (ROOT / ".github" / "workflows" / "ci.yml").read_text()


def pinned(variable: str) -> list[str]:
    return re.findall(rf'^  {variable}: "(.*)"$', CI, re.MULTILINE)


class LinterVersionsTest(unittest.TestCase):
    def test_versions_are_pinned_once(self):
        for variable in ("RUFF_VERSION", "SHELLCHECK_VERSION"):
            versions = pinned(variable)
            self.assertEqual(len(versions), 1, f"ci.yml sets {variable} once, in the workflow env")
            self.assertRegex(versions[0], r"^\d+\.\d+\.\d+$")

    def test_every_ruff_install_uses_the_pin(self):
        installs = [line for line in CI.splitlines() if "pip" in line and "install" in line and "ruff" in line]
        self.assertTrue(installs, "ci.yml installs ruff")
        for line in installs:
            self.assertIn('"ruff==$RUFF_VERSION"', line)
        self.assertNotRegex(CI, r"ruff==\d", "pin ruff through RUFF_VERSION, not inline")

    def test_every_linting_job_installs_the_pinned_shellcheck(self):
        ruff_jobs = CI.count('"ruff==$RUFF_VERSION"')
        self.assertEqual(CI.count("- name: Install ShellCheck"), ruff_jobs,
                         "every job that installs ruff also installs the pinned ShellCheck")
        self.assertEqual(CI.count('grep -qx "version: ${SHELLCHECK_VERSION}"'), ruff_jobs)
        self.assertNotRegex(CI, r"shellcheck-v\d", "pin ShellCheck through SHELLCHECK_VERSION, not inline")


if __name__ == "__main__":
    unittest.main()
